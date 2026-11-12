// Deterministic radio boundary; production Central, delegates and tasks are compiled unchanged.
@_exported import Foundation
public enum CBManagerState: Int { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
public enum CBPeripheralState { case disconnected, connecting, connected, disconnecting }
public enum CBCharacteristicWriteType { case withResponse, withoutResponse }
public struct CBUUID: Hashable { public let uuidString: String; public init(string: String) { uuidString = string } }
public struct CBCharacteristicProperties: OptionSet {
    public let rawValue: Int; public init(rawValue: Int) { self.rawValue = rawValue }
    public static let notify = Self(rawValue: 1), notifyEncryptionRequired = Self(rawValue: 2), indicate = Self(rawValue: 4), indicateEncryptionRequired = Self(rawValue: 8), read = Self(rawValue: 16), write = Self(rawValue: 32), writeWithoutResponse = Self(rawValue: 64)
}
public let CBCentralManagerOptionRestoreIdentifierKey = "restoreID"
public let CBCentralManagerScanOptionAllowDuplicatesKey = "duplicates"
public let CBCentralManagerRestoredStatePeripheralsKey = "peripherals"
public protocol CBCentralManagerDelegate: AnyObject {
    func centralManagerDidUpdateState(_ central: CBCentralManager)
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)
}
public protocol CBPeripheralDelegate: AnyObject {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)
}
public final class CBService {
    public var uuid = CBUUID(string: "service"), characteristics: [CBCharacteristic]? = []
    public weak var peripheral: CBPeripheral?
}
public final class CBCharacteristic {
    public var uuid = CBUUID(string: "characteristic"), properties: CBCharacteristicProperties = [], isNotifying = false, value: Data?
    public weak var service: CBService?
}
public final class CBPeripheral {
    public let identifier: UUID
    public var state: CBPeripheralState = .disconnected
    public weak var delegate: CBPeripheralDelegate?
    public var services: [CBService]? = []
    public var discoveryCalls = 0
    public init(identifier: UUID = UUID()) { self.identifier = identifier }
    public func discoverServices(_ services: [CBUUID]?) { discoveryCalls += 1 }
    public func discoverCharacteristics(_ characteristics: [CBUUID]?, for service: CBService) {}
    public func setNotifyValue(_ value: Bool, for characteristic: CBCharacteristic) {}
    public func readValue(for characteristic: CBCharacteristic) {}
    public func writeValue(_ value: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
    public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 20 }
    public func readRSSI() {}
}
public final class CBCentralManager {
    public static var latest: CBCentralManager!
    public weak var delegate: CBCentralManagerDelegate?
    public var state: CBManagerState = .poweredOn
    public var peripherals = [UUID: CBPeripheral]()
    public var connects = [UUID](), cancels = [UUID]()
    public init(delegate: CBCentralManagerDelegate?, queue: DispatchQueue?, options: [String: Any]?) { self.delegate = delegate; Self.latest = self }
    public func retrievePeripherals(withIdentifiers ids: [UUID]) -> [CBPeripheral] { ids.compactMap { peripherals[$0] } }
    public func connect(_ peripheral: CBPeripheral) { connects.append(peripheral.identifier); peripheral.state = .connecting }
    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancels.append(peripheral.identifier); peripheral.state = .disconnecting }
    public func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) {}
    public func stopScan() {}
    public func connected(_ peripheral: CBPeripheral) { peripheral.state = .connected; delegate?.centralManager(self, didConnect: peripheral) }
    public func disconnected(_ peripheral: CBPeripheral) { peripheral.state = .disconnected; delegate?.centralManager(self, didDisconnectPeripheral: peripheral, error: nil) }
    public func failed(_ peripheral: CBPeripheral) { peripheral.state = .disconnected; delegate?.centralManager(self, didFailToConnect: peripheral, error: nil) }
    public func powered(_ value: CBManagerState) { state = value; delegate?.centralManagerDidUpdateState(self) }
}
