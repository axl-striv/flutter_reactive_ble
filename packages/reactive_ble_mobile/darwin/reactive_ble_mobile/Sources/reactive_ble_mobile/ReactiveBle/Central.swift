import CoreBluetooth
#if os(iOS)
import UIKit
#endif

typealias RSSI = Int

typealias PeripheralID = UUID
typealias ServiceID = CBUUID
typealias ServiceInstanceID = String
typealias CharacteristicID = CBUUID
typealias CharacteristicInstanceID = String

typealias ServiceData = [ServiceID: Data]
typealias AdvertisementData = [String: Any]

final class Central {

    // Optional, process-local diagnostics. No names, advertisement payloads,
    // characteristic values, or NSError userInfo leave this layer.
    private let diagnosticID = UUID().uuidString
    private func trace(_ event: String, device: UUID? = nil, error: Error? = nil,
                       fields: [String: Any] = [:]) {
        var data = fields
        data["source"] = "corebluetooth"
        data["event"] = event
        data["central_id"] = diagnosticID
        data["native_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
        data["uptime_ms"] = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        data["device_id"] = device?.uuidString
        if let error = error as NSError? {
            data["error_domain"] = error.domain
            data["error_code"] = error.code
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                data["underlying_error_domain"] = underlying.domain
                data["underlying_error_code"] = underlying.code
            }
        }
        NotificationCenter.default.post(name: Notification.Name("striv.ble.nativeDiagnostic"),
                                        object: nil, userInfo: data)
    }

    typealias StateChangeHandler = (Central, CBManagerState) -> Void
    typealias DiscoveryHandler = (Central, CBPeripheral, AdvertisementData, RSSI) -> Void
    typealias ConnectionChangeHandler = (Central, CBPeripheral, ConnectionChange) -> Void
    typealias ServicesWithCharacteristicsDiscoveryHandler = (Central, CBPeripheral, [Error]) -> Void
    typealias CharacteristicNotifyCompletionHandler = (Central, Error?) -> Void
    typealias CharacteristicValueUpdateHandler = (Central, CharacteristicInstance, Data?, Error?) -> Void
    typealias CharacteristicWriteCompletionHandler = (Central, CharacteristicInstance, Error?) -> Void

    private let onServicesWithCharacteristicsInitialDiscovery: ServicesWithCharacteristicsDiscoveryHandler

    private var peripheralDelegate: PeripheralDelegate!
    private var centralManagerDelegate: CentralManagerDelegate!
    private var centralManager: CBCentralManager!

    private(set) var isScanning = false
    private(set) var activePeripherals = [PeripheralID: CBPeripheral]()
    private(set) var connectRegistry = PeripheralTaskRegistry<ConnectTaskController>()
    // Native cancellation is asynchronous; keep ownership until its terminal callback.
    private var retiringConnections = Set<PeripheralID>()
    private var pendingConnections = [PeripheralID: () -> Void]()
    private let servicesWithCharacteristicsDiscoveryRegistry = PeripheralTaskRegistry<ServicesWithCharacteristicsDiscoveryTaskController>()
    private let characteristicNotifyRegistry = PeripheralTaskRegistry<CharacteristicNotifyTaskController>()
    private let characteristicWriteRegistry = PeripheralTaskRegistry<CharacteristicWriteTaskController>()
    private let readRssiRegistry = PeripheralTaskRegistry<ReadRssiTaskController>()
    private let onConnectionChange: ConnectionChangeHandler
    private var pendingRecovery = [PeripheralID: PendingConnectionRecovery]()

    /// Called on the central's main queue. A queued didConnect must win over
    /// timeout recovery; never cancel a link that the OS already established.
    func recoverPendingConnection(_ id: PeripheralID, completion: @escaping (Bool) -> Void) {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else {
            completion(false)
            return
        }
        #endif
        guard pendingRecovery[id] == nil,
              let peripheral = try? resolve(known: id) else {
            completion(false)
            return
        }
        if peripheral.state == .connected && !retiringConnections.contains(id) {
            connectRegistry.updateTask(key: id, action: { $0.handleConnectionChange(.connected) })
            completion(false)
            return
        }
        if peripheral.state == .disconnected && activePeripherals[id] == nil &&
            restoredPeripherals[id] == nil && !retiringConnections.contains(id) {
            // This Central has no outstanding owner; terminal cleanup already ran.
            completion(true)
            return
        }
        let request = PendingConnectionRecovery(completion)
        pendingRecovery[id] = request
        // Join an existing cancellation; it remains the sole owner until its
        // terminal callback. Do not cancel or clean up a second time.
        if !retiringConnections.contains(id) {
            disconnect(from: id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            // No acknowledgement means no permission to start a competing attempt.
            if self?.pendingRecovery[id] === request {
                self?.pendingRecovery.removeValue(forKey: id)
            }
            request.finish(false)
        }
    }

    private func finishRetiringConnection(_ peripheral: CBPeripheral, change: ConnectionChange) {
        let id = peripheral.identifier
        // Retire tasks without another radio cancellation: the old link is terminal.
        connectRegistry.updateTasks(in: id) { $0.retire(error: PluginError.connectionLost) }
        eject(peripheral, error: PluginError.connectionLost)
        retiringConnections.remove(id)
        let recovery = pendingRecovery.removeValue(forKey: id)
        if let restart = pendingConnections.removeValue(forKey: id), state == .poweredOn {
            restart()
            // A normal replacement now owns the link; Dart must not replace it again.
            recovery?.finish(false)
        } else {
            onConnectionChange(self, peripheral, change)
            recovery?.finish(true)
        }
    }

    // Peripherals iOS handed back on a state-restoration relaunch. Held only so
    // CoreBluetooth keeps their links until Dart connects to them again.
    private var restoredPeripherals = [PeripheralID: CBPeripheral]()

    // iOS relaunches a terminated app for a pending connect only if the
    // central opted into state restoration, which requires the
    // bluetooth-central background mode.
    private static var restoreOptions: [String: Any]? {
        #if os(iOS)
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        guard modes.contains("bluetooth-central") else { return nil }
        return [CBCentralManagerOptionRestoreIdentifierKey: "reactive_ble_mobile.central"]
        #else
        return nil
        #endif
    }

    init(
        onStateChange: @escaping StateChangeHandler,
        onDiscovery: @escaping DiscoveryHandler,
        onConnectionChange: @escaping ConnectionChangeHandler,
        onServicesWithCharacteristicsInitialDiscovery: @escaping ServicesWithCharacteristicsDiscoveryHandler,
        onCharacteristicValueUpdate: @escaping CharacteristicValueUpdateHandler
    ) {
        self.onConnectionChange = onConnectionChange
        self.onServicesWithCharacteristicsInitialDiscovery = onServicesWithCharacteristicsInitialDiscovery
        self.centralManagerDelegate = CentralManagerDelegate(
            onStateChange: papply(weak: self) { central, state in
                central.trace("state_changed", fields: ["state": state.rawValue])
                if state != .poweredOn {
                    central.finishPendingRecoveries()
                    central.pendingConnections.removeAll()
                    central.restoredPeripherals.removeAll()
                    central.activePeripherals.forEach { id, peripheral in
                        let error = Failure.notPoweredOn(actualState: state)
                        central.connectRegistry.updateTask(key: id) {
                            $0.handleConnectionChange(.disconnected(error))
                        }
                        central.eject(peripheral, error: error)
                        onConnectionChange(central, peripheral, .disconnected(error))
                    }
                    central.retiringConnections.removeAll()
                }
                onStateChange(central, state)
            },
            onDiscovery: papply(weak: self, onDiscovery),
            onConnectionChange: papply(weak: self) { central, peripheral, change in
                // Record BEFORE task completion starts discovery. Flutter's
                // connected event is deliberately delayed until discovery ends.
                switch change {
                case .connected:
                    central.trace("did_connect", device: peripheral.identifier)
                case .failedToConnect(let error):
                    central.trace("did_fail_to_connect", device: peripheral.identifier, error: error)
                case .disconnected(let error):
                    central.trace("did_disconnect", device: peripheral.identifier, error: error)
                }
                if central.retiringConnections.contains(peripheral.identifier) {
                    if case .connected = change {
                        // A connection can win the race with cancellation. It is still retired.
                        central.centralManager.cancelPeripheralConnection(peripheral)
                        return
                    }
                    central.finishRetiringConnection(peripheral, change: change)
                    return
                }
                central.connectRegistry.updateTask(
                    key: peripheral.identifier,
                    action: { $0.handleConnectionChange(change) }
                )

                switch change {
                case .connected:
                    break
                case .failedToConnect(let error), .disconnected(let error):
                    central.eject(peripheral, error: error ?? PluginError.connectionLost)
                }

                onConnectionChange(central, peripheral, change)
            },
            onRestore: papply(weak: self) { central, peripherals in
                central.trace("state_restored", fields: ["peripheral_count": peripherals.count])
                peripherals.forEach { central.restoredPeripherals[$0.identifier] = $0 }
            }
        )
        self.peripheralDelegate = PeripheralDelegate(
            onServicesDiscovery: papply(weak: self) { central, peripheral, error in
                central.servicesWithCharacteristicsDiscoveryRegistry.updateTask(
                    key: peripheral.identifier,
                    action: { $0.handleServicesDiscovery(peripheral: peripheral, error: error) }
                )
            },
            onCharacteristicsDiscovery: papply(weak: self) { central, service, error in
                central.servicesWithCharacteristicsDiscoveryRegistry.updateTask(
                    key: service.peripheral!.identifier,
                    action: { $0.handleCharacteristicsDiscovery(service: service, error: error) }
                )
            },
            onCharacteristicNotificationStateUpdate: papply(weak: self) { central, characteristic, error in
                guard let q = try? CharacteristicInstance(characteristic)
                else {
                    return
                }

                central.characteristicNotifyRegistry.updateTask(
                    key: q,
                    action: { $0.complete(error: error) }
                )
                central.characteristicNotifyRegistry.updateTasksUntilRunning(
                    key: q,
                    action: { $0.start(characteristic: characteristic) }
                )
            },
            onCharacteristicValueUpdate: papply(weak: self) { central, characteristic, error in
                guard let q = try? CharacteristicInstance(characteristic)
                else {
                    return
                }

                onCharacteristicValueUpdate(central, q, characteristic.value, error)
            },
            onCharacteristicValueWrite: papply(weak: self) { central, characteristic, error in
                guard let q = try? CharacteristicInstance(characteristic)
                else {
                    return
                }

                central.characteristicWriteRegistry.updateTask(
                    key: q,
                    action: { $0.handleWrite(error: error) }
                )
            },
            onReadRssi: papply(weak: self) { central, peripheral, rssi, error in
                central.readRssiRegistry.updateTask(
                    key: peripheral.identifier,
                    action: { $0.handleReadRssi(rssi: rssi, error: error) }
                )
            }
        )
        self.centralManager = CBCentralManager(
            delegate: centralManagerDelegate,
            queue: nil,
            options: Central.restoreOptions
        )
        trace("central_created")
    }

    deinit {
        finishPendingRecoveries()
        trace("central_released")
    }

    private func finishPendingRecoveries() {
        let requests = Array(pendingRecovery.values)
        pendingRecovery.removeAll()
        requests.forEach { $0.finish(false) }
    }

    var state: CBManagerState { return centralManager.state }

    func scanForDevices(with services: [ServiceID]?) {
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning = false
    }

    func connect(to peripheralID: PeripheralID, discover servicesWithCharacteristicsToDiscover: ServicesWithCharacteristicsToDiscover, timeout: TimeInterval?) throws {
        trace("connect_requested", device: peripheralID,
              fields: ["timeout_ms": Int((timeout ?? 0) * 1000)])
        let peripheral = try resolve(known: peripheralID)

        if activePeripherals[peripheralID] != nil || retiringConnections.contains(peripheralID) {
            // Record the replacement before cancellation can deliver terminal cleanup.
            pendingConnections[peripheralID] = { [weak self] in
                self?.startConnection(to: peripheral, discover: servicesWithCharacteristicsToDiscover, timeout: timeout)
            }
            beginRetiringConnection(peripheral)
            return
        }
        startConnection(to: peripheral, discover: servicesWithCharacteristicsToDiscover, timeout: timeout)
    }

    private func startConnection(to peripheral: CBPeripheral, discover servicesWithCharacteristicsToDiscover: ServicesWithCharacteristicsToDiscover, timeout: TimeInterval?) {
        let peripheralID = peripheral.identifier
        peripheral.delegate = peripheralDelegate
        activePeripherals[peripheral.identifier] = peripheral
        restoredPeripherals[peripheral.identifier] = nil

        connectRegistry.registerTask(
            key: peripheralID,
            params: .init(),
            timeout: timeout.map { timeout in (
                duration: timeout,
                handler: papply(weak: self) { (central: Central) -> Void in
                    central.disconnect(from: peripheralID)
                }
            )},
            timeoutAllowed: { [weak peripheral] in
                #if os(iOS)
                guard UIApplication.shared.applicationState == .active else { return false }
                #endif
                return peripheral?.state != .connected
            },
            completion: papply(weak: self) { central, connectionChange in
                switch connectionChange {
                case .connected:
                    peripheral.delegate = central.peripheralDelegate

                    central.discoverServicesWithCharacteristics(
                        for: peripheral,
                        discover: servicesWithCharacteristicsToDiscover,
                        completion: { [weak central] _, peripheral, errors in
                            guard let central = central,
                                  !central.retiringConnections.contains(peripheral.identifier)
                            else { return }
                            central.onServicesWithCharacteristicsInitialDiscovery(central, peripheral, errors)
                        }
                    )
                case .failedToConnect, .disconnected:
                    break
                }
            }
        )

        connectRegistry.updateTask(
            key: peripheralID,
            action: { $0.connect(centralManager: centralManager, peripheral: peripheral) }
        )
    }

    func disconnect(from peripheralID: PeripheralID) {
        trace("disconnect_requested", device: peripheralID)
        pendingConnections.removeValue(forKey: peripheralID)
        guard let peripheral = try? resolve(known: peripheralID) else { return }
        beginRetiringConnection(peripheral)
    }

    private func beginRetiringConnection(_ peripheral: CBPeripheral) {
        let peripheralID = peripheral.identifier
        guard !retiringConnections.contains(peripheralID) else { return }
        if peripheral.state == .disconnected && activePeripherals[peripheralID] == nil &&
            restoredPeripherals[peripheralID] == nil { return }
        retiringConnections.insert(peripheralID)
        // Even .disconnected can precede a queued terminal delegate callback.
        // Only that callback releases ownership and authorizes a replacement.
        var cancelledTask = false
        connectRegistry.updateTask(key: peripheralID) {
            cancelledTask = true
            return $0.cancel(centralManager: centralManager, peripheral: peripheral, error: nil)
        }
        if !cancelledTask { centralManager.cancelPeripheralConnection(peripheral) }
    }

    func disconnectAll() {
        finishPendingRecoveries()
        pendingConnections.removeAll()
        Set(activePeripherals.keys).union(restoredPeripherals.keys).forEach { id in
            trace("disconnect_all_requested", device: id)
            disconnect(from: id)
        }
    }

    func discoverServicesWithCharacteristics(
        for peripheralID: PeripheralID,
        discover servicesWithCharacteristicsToDiscover: ServicesWithCharacteristicsToDiscover,
        completion: @escaping ServicesWithCharacteristicsDiscoveryHandler
    ) throws {
        let peripheral = try resolve(connected: peripheralID)

        discoverServicesWithCharacteristics(
            for: peripheral,
            discover: servicesWithCharacteristicsToDiscover,
            completion: completion
        )
    }

    func peripheral(for peripheralID: PeripheralID) throws -> CBPeripheral {
        return try resolve(connected: peripheralID)
    }

    private func discoverServicesWithCharacteristics(
        for peripheral: CBPeripheral,
        discover servicesWithCharacteristicsToDiscover: ServicesWithCharacteristicsToDiscover,
        completion: @escaping ServicesWithCharacteristicsDiscoveryHandler
    ) {
        trace("discovery_started", device: peripheral.identifier)
        servicesWithCharacteristicsDiscoveryRegistry.registerTask(
            key: peripheral.identifier,
            params: .init(servicesWithCharacteristicsToDiscover: servicesWithCharacteristicsToDiscover),
            completion: papply(weak: self) { central, result in
                central.trace("discovery_completed", device: peripheral.identifier,
                              error: result.first, fields: ["error_count": result.count])
                completion(central, peripheral, result)
            }
        )
        servicesWithCharacteristicsDiscoveryRegistry.updateTask(
            key: peripheral.identifier,
            action: { $0.start(peripheral: peripheral) }
        )
    }

    func turnNotifications(_ state: OnOff, for characteristicInstance: CharacteristicInstance, completion: @escaping CharacteristicNotifyCompletionHandler) throws {
        let characteristic = try resolve(characteristic: characteristicInstance)

        guard [CBCharacteristicProperties.notify, .notifyEncryptionRequired, .indicate, .indicateEncryptionRequired]
                .contains(where: characteristic.properties.contains)
        else { throw Failure.notificationsNotSupported(characteristicInstance) }

        characteristicNotifyRegistry.registerTask(
            key: characteristicInstance,
            params: .init(state: state),
            completion: papply(weak: self) { central, result in
                completion(central, result)
            }
        )

        characteristicNotifyRegistry.updateTasksUntilRunning(
            key: characteristicInstance,
            action: { $0.start(characteristic: characteristic) }
        )
    }

    func read(characteristic characteristicInstance: CharacteristicInstance) throws {
        let characteristic = try resolve(characteristic: characteristicInstance)

        guard characteristic.properties.contains(.read)
        else { throw Failure.notReadable(characteristicInstance) }

        guard let peripheral = characteristic.service?.peripheral
        else { throw Failure.peripheralIsUnknown(characteristicInstance.peripheralID) }

        peripheral.readValue(for: characteristic)
    }

    func writeWithResponse(
        value: Data,
        characteristic characteristicInstance: CharacteristicInstance,
        completion: @escaping CharacteristicWriteCompletionHandler
    ) throws {
        let characteristic = try resolve(characteristic: characteristicInstance)

        guard characteristic.properties.contains(.write)
        else { throw Failure.notWritable(characteristicInstance) }

        let qualifiedChar = try CharacteristicInstance(characteristic)

        characteristicWriteRegistry.registerTask(
            key: qualifiedChar,
            params: .init(value: value),
            completion: papply(weak: self) { central, error in
                completion(central, qualifiedChar, error)
            }
        )

        guard let peripheral = characteristic.service?.peripheral
        else { throw Failure.peripheralIsUnknown(qualifiedChar.peripheralID) }

        characteristicWriteRegistry.updateTask(
            key: qualifiedChar,
            action: { $0.start(peripheral: peripheral) }
        )
    }

    func writeWithoutResponse(
        value: Data,
        characteristic characteristicInstance: CharacteristicInstance
    ) throws {
        let characteristic = try resolve(characteristic: characteristicInstance)

        guard characteristic.properties.contains(.writeWithoutResponse)
        else { throw Failure.notWritable(characteristicInstance) }

        guard let response = characteristic.service?.peripheral?.writeValue(value, for: characteristic, type: .withoutResponse)
        else { throw Failure.characteristicNotFound(characteristicInstance) }

        return response
    }

    func maximumWriteValueLength(for peripheral: PeripheralID, type: CBCharacteristicWriteType) throws -> Int {
        let peripheral = try resolve(connected: peripheral)
        return peripheral.maximumWriteValueLength(for: type)
    }

    
    func readRssi(for peripheralId: PeripheralID, completion: @escaping (Failable<Int>) -> Void) throws {
        let peripheral = try resolve(connected: peripheralId)

        readRssiRegistry.registerTask(
            key: peripheralId,
            params: .init(),
            completion: completion
        )

        readRssiRegistry.updateTask(
            key: peripheralId,
            action: {
                $0.start(peripheral: peripheral)
            }
        )
    }

    private func eject(_ peripheral: CBPeripheral, error: Error) {
        peripheral.delegate = nil
        activePeripherals[peripheral.identifier] = nil
        restoredPeripherals[peripheral.identifier] = nil

        servicesWithCharacteristicsDiscoveryRegistry.updateTasks(
            in: peripheral.identifier,
            action: { $0.cancel(error: error) }
        )
        characteristicNotifyRegistry.updateTasks(
            in: peripheral.identifier,
            action: { $0.cancel(error: error) }
        )
        characteristicWriteRegistry.updateTasks(
            in: peripheral.identifier,
            action: { $0.cancel(error: error) }
        )
        readRssiRegistry.updateTasks(
            in: peripheral.identifier,
            action: { $0.cancel(error: error) }
        )
    }

    private func resolve(known peripheralID: PeripheralID) throws -> CBPeripheral {
        guard let peripheral = centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first
        else { throw Failure.peripheralIsUnknown(peripheralID) }

        return peripheral
    }

    private func resolve(connected peripheralID: PeripheralID) throws -> CBPeripheral {
        guard let peripheral = activePeripherals[peripheralID]
        else { throw Failure.peripheralIsUnknown(peripheralID) }

        guard peripheral.state == .connected
        else { throw Failure.peripheralIsNotConnected(peripheralID) }

        return peripheral
    }

    private func resolve(characteristic characteristicInstance: CharacteristicInstance) throws -> CBCharacteristic {
        let peripheral = try resolve(connected: characteristicInstance.peripheralID)

        let filteredServices = peripheral.services?.filter { $0.uuid == characteristicInstance.serviceID } ?? []
        let serviceIndex = Int(characteristicInstance.serviceInstanceID) ?? 0

        guard serviceIndex >= 0, serviceIndex < filteredServices.count
        else { throw Failure.serviceNotFound(characteristicInstance.serviceID, characteristicInstance.peripheralID) }

        let service = filteredServices[serviceIndex]

        let filteredCharacteristics = service.characteristics?.filter {$0.uuid == characteristicInstance.id} ?? []
        let characteristicsIndex = Int(characteristicInstance.instanceID) ?? 0

        guard characteristicsIndex >= 0, characteristicsIndex < filteredCharacteristics.count
        else { throw Failure.characteristicNotFound(characteristicInstance) }

        return filteredCharacteristics[characteristicsIndex]
    }

    private enum Failure: Error, CustomStringConvertible {

        case notPoweredOn(actualState: CBManagerState)
        case peripheralIsUnknown(PeripheralID)
        case peripheralIsNotConnected(PeripheralID)
        case serviceNotFound(ServiceID, PeripheralID)
        case characteristicNotFound(CharacteristicInstance)
        case notificationsNotSupported(CharacteristicInstance)
        case notReadable(CharacteristicInstance)
        case notWritable(CharacteristicInstance)

        var description: String {
            switch self {
            case .notPoweredOn(let actualState):
                return "Bluetooth is not powered on (the current state code is \(actualState.rawValue))"
            case .peripheralIsUnknown(let peripheralID):
                return "A peripheral \(peripheralID.uuidString) is unknown (make sure it has been discovered)"
            case .peripheralIsNotConnected(let peripheralID):
                return "The peripheral \(peripheralID.uuidString) is not connected"
            case .serviceNotFound(let serviceID, let peripheralID):
                return "A service \(serviceID) is not found in the peripheral \(peripheralID) (make sure it has been discovered)"
            case .characteristicNotFound(let characteristicInstance):
                return "A characteristic \(characteristicInstance.id) is not found in the service \(characteristicInstance.serviceID) of the peripheral \(characteristicInstance.peripheralID) (make sure it has been discovered)"
            case .notificationsNotSupported(let characteristicInstance):
                return "The characteristic \(characteristicInstance.id) of the service \(characteristicInstance.serviceID) of the peripheral \(characteristicInstance.peripheralID) does not support either notifications or indications"
            case .notReadable(let characteristicInstance):
                return "The characteristic \(characteristicInstance.id) of the service \(characteristicInstance.serviceID) of the peripheral \(characteristicInstance.peripheralID) is not readable"
            case .notWritable(let characteristicInstance):
                return "The characteristic \(characteristicInstance.id) of the service \(characteristicInstance.serviceID) of the peripheral \(characteristicInstance.peripheralID) is not writable"
            }
        }
    }
}
