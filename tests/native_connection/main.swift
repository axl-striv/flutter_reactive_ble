import Foundation
import CoreBluetooth
import UIKit
let base = CommandLine.arguments.contains("base")
var events = [String](), discoveryResults = [Int]()
let central = Central(onStateChange: { _, _ in }, onDiscovery: { _, _, _, _ in }, onConnectionChange: { _, p, event in
    switch event { case .connected: events.append("connected"); case .disconnected: events.append("disconnected"); case .failedToConnect: events.append("failed") }
}, onServicesWithCharacteristicsInitialDiscovery: { _, _, errors in discoveryResults.append(errors.count) }, onCharacteristicValueUpdate: { _, _, _, _ in })
let manager = CBCentralManager.latest!
let right = CBPeripheral(), left = CBPeripheral()
manager.peripherals[right.identifier] = right; manager.peripherals[left.identifier] = left
func connect(_ p: CBPeripheral, _ timeout: TimeInterval = 2) { try! central.connect(to: p.identifier, discover: .all, timeout: timeout) }
func wait(_ duration: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(duration)) }
connect(right)
central.disconnect(from: right.identifier)
connect(right, 0.03)
precondition(manager.connects.count == 1, "Replacement started before old cancellation completed")
manager.disconnected(right)
if base {
    wait(0.08)
    precondition(manager.connects.count == 1 && manager.cancels.count == 1)
    print("BASE: replacement never issued a second native connect; its timeout never fired")
} else {
    precondition(manager.connects.count == 2 && right.delegate != nil && central.activePeripherals[right.identifier] === right)
    precondition(events.isEmpty, "Old terminal callback reached replacement subscription")
    wait(0.08)
    precondition(manager.cancels.count == 2, "Replacement timer was not armed")
    manager.disconnected(right)
    connect(right); manager.connected(right)
    precondition(right.discoveryCalls == 1 && right.delegate != nil)
    print("FIXED: replacement starts once after old cleanup; timer fires; success starts service discovery")
}
if !base {
    // Each row exercises the same ownership handoff, without an alternative model.
    for variant in ["cancel-queued", "late-connected", "peer", "disconnect-all", "power-cycle", "failure", "restored-link", "restored-natural-terminal", "initial-discovery-retirement"] {
        let initialConnects = manager.connects.count
        switch variant {
        case "cancel-queued":
            central.disconnect(from: right.identifier); connect(right)
            central.disconnect(from: right.identifier); manager.disconnected(right)
            precondition(manager.connects.count == initialConnects && central.activePeripherals[right.identifier] == nil)
            connect(right); manager.connected(right)
        case "late-connected":
            let discovery = right.discoveryCalls, cancels = manager.cancels.count
            central.disconnect(from: right.identifier); connect(right)
            manager.connected(right)
            precondition(right.discoveryCalls == discovery && manager.cancels.count == cancels + 2)
            manager.disconnected(right)
            precondition(manager.connects.count == initialConnects + 1)
            manager.connected(right)
            precondition(right.discoveryCalls == discovery + 1 && right.delegate != nil)
        case "peer":
            connect(left)
            central.disconnect(from: right.identifier); connect(right)
            manager.connected(left); manager.disconnected(right)
            precondition(left.discoveryCalls == 1 && left.delegate != nil && central.activePeripherals[left.identifier] === left)
            manager.connected(right)
        case "disconnect-all":
            central.disconnectAll(); connect(right); central.disconnectAll()
            manager.disconnected(right); manager.disconnected(left)
            precondition(manager.connects.count == initialConnects && central.activePeripherals.isEmpty)
        case "power-cycle":
            connect(right); central.disconnect(from: right.identifier); connect(right)
            manager.powered(.poweredOff)
            precondition(central.activePeripherals.isEmpty)
            manager.powered(.poweredOn); connect(right)
            precondition(manager.connects.count == initialConnects + 2 && right.delegate != nil)
            manager.connected(right)
        case "failure":
            central.disconnect(from: right.identifier); manager.disconnected(right)
            connect(right); manager.failed(right)
            precondition(central.activePeripherals[right.identifier] == nil && right.delegate == nil)
            connect(right); manager.connected(right)
            precondition(right.delegate != nil)
        case "restored-link":
            central.disconnect(from: right.identifier); manager.disconnected(right)
            right.state = .connected
            (manager.delegate as! CentralManagerDelegate).centralManager(manager, willRestoreState: [CBCentralManagerRestoredStatePeripheralsKey: [right]])
            central.disconnect(from: right.identifier); connect(right)
            precondition(manager.connects.count == initialConnects)
            manager.disconnected(right)
            precondition(manager.connects.count == initialConnects + 1 && right.delegate != nil)
            manager.connected(right)
        case "restored-natural-terminal":
            central.disconnect(from: right.identifier); manager.disconnected(right)
            right.state = .connected
            (manager.delegate as! CentralManagerDelegate).centralManager(manager, willRestoreState: [CBCentralManagerRestoredStatePeripheralsKey: [right]])
            manager.disconnected(right)
            central.disconnect(from: right.identifier); connect(right)
            precondition(manager.connects.count == initialConnects + 1, "Stale restored ownership stranded a fresh connection")
            manager.connected(right)
        case "initial-discovery-retirement":
            let publications = discoveryResults.count
            central.disconnect(from: right.identifier); connect(right)
            manager.disconnected(right)
            precondition(discoveryResults.count == publications, "Old discovery cancellation reached replacement subscription")
            precondition(manager.connects.count == initialConnects + 1)
            manager.connected(right)
            right.delegate!.peripheral(right, didDiscoverServices: nil)
            precondition(discoveryResults.count == publications + 1 && discoveryResults.last == 0)
            central.disconnect(from: right.identifier); manager.disconnected(right)
            connect(right); manager.connected(right)
            right.delegate!.peripheral(right, didDiscoverServices: NSError(domain: "test-discovery", code: 1))
            precondition(discoveryResults.count == publications + 2 && discoveryResults.last == 1, "Current discovery error was suppressed")
        default: fatalError()
        }
        print("PASS ownership variant: \(variant)")
    }
}

if !base {
    func scenario(_ name: String, _ body: (Central, CBCentralManager, CBPeripheral) -> Void) {
        UIApplication.shared.applicationState = .active
        let c = Central(onStateChange: { _, _ in }, onDiscovery: { _, _, _, _ in },
            onConnectionChange: { _, _, _ in events.append("scenario-event") }, onServicesWithCharacteristicsInitialDiscovery: { _, _, _ in },
            onCharacteristicValueUpdate: { _, _, _, _ in })
        let m = CBCentralManager.latest!, p = CBPeripheral()
        m.peripherals[p.identifier] = p
        body(c, m, p)
        print("PASS integrated recovery: \(name)")
    }
    scenario("queue replacement before terminal cleanup on an already-disconnected link") { c, m, p in
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        m.connected(p)
        p.state = .disconnected
        let publications = events.count
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        precondition(m.connects.count == 1 && events.count == publications)
        m.disconnected(p)
        precondition(m.connects.count == 2 && events.count == publications,
            "Old terminal event must not close the replacement stream")
        m.connected(p)
        precondition(p.discoveryCalls == 2)
    }
    scenario("recovery joins cancellation, acknowledges only after cleanup") { c, m, p in
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        c.disconnect(from: p.identifier)
        var results = [Bool]()
        c.recoverPendingConnection(p.identifier) { results.append($0) }
        precondition(m.cancels.count == 1 && results.isEmpty)
        m.disconnected(p)
        precondition(results == [true] && c.activePeripherals.isEmpty && p.delegate == nil)
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        m.connected(p)
        precondition(m.connects.count == 2 && p.discoveryCalls == 1)
    }
    scenario("queued replacement wins over recovery acknowledgement") { c, m, p in
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        var result: Bool?
        c.recoverPendingConnection(p.identifier) { result = $0 }
        try! c.connect(to: p.identifier, discover: .all, timeout: 0.03)
        m.connected(p) // Old connection wins the race with cancellation.
        precondition(p.discoveryCalls == 0 && result == nil)
        m.disconnected(p)
        precondition(result == false && m.connects.count == 2 && p.delegate != nil)
        m.connected(p)
        wait(0.08)
        precondition(m.cancels.count == 2 && p.discoveryCalls == 1)
    }
    scenario("raw disconnected does not bypass a delayed terminal callback") { c, m, p in
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        c.disconnect(from: p.identifier)
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        p.state = .disconnected // State becomes visible before the callback.
        var result: Bool?
        c.recoverPendingConnection(p.identifier) { result = $0 }
        precondition(result == nil && m.cancels.count == 1 && m.connects.count == 1)
        m.disconnected(p) // Delayed OLD callback must run before replacement.
        precondition(result == false && m.connects.count == 2)
        m.connected(p)
        precondition(p.discoveryCalls == 1)
    }
    scenario("missing terminal callback fails closed; a late callback still releases handoff") { c, m, p in
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        p.state = .disconnected
        var results = [Bool]()
        c.recoverPendingConnection(p.identifier) { results.append($0) }
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        wait(5.1)
        precondition(results == [false] && m.connects.count == 1)
        m.disconnected(p)
        precondition(results == [false] && m.connects.count == 2)
        m.connected(p)
        precondition(p.discoveryCalls == 1)
    }
    scenario("late native success is preserved before its delegate callback") { c, m, p in
        try! c.connect(to: p.identifier, discover: .all, timeout: 0.02)
        p.state = .connected
        wait(0.06)
        var result: Bool?
        c.recoverPendingConnection(p.identifier) { result = $0 }
        precondition(result == false && m.cancels.isEmpty && p.discoveryCalls == 1)
        m.connected(p)
        precondition(p.discoveryCalls == 1)
    }
    scenario("background timeout defers, resume recovery receives terminal acknowledgement") { c, m, p in
        try! c.connect(to: p.identifier, discover: .all, timeout: 0.02)
        UIApplication.shared.applicationState = .background
        wait(0.06)
        var results = [Bool]()
        c.recoverPendingConnection(p.identifier) { results.append($0) }
        precondition(results == [false] && m.cancels.isEmpty)
        UIApplication.shared.applicationState = .active
        c.recoverPendingConnection(p.identifier) { results.append($0) }
        precondition(m.cancels.count == 1 && results == [false])
        m.disconnected(p)
        precondition(results == [false, true])
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        m.connected(p)
        precondition(m.connects.count == 2 && p.discoveryCalls == 1)
    }
    scenario("radio power loss ends recovery without allowing a replacement") { c, m, p in
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        var results = [Bool]()
        c.recoverPendingConnection(p.identifier) { results.append($0) }
        m.powered(.poweredOff)
        precondition(results == [false] && c.activePeripherals.isEmpty)
        m.disconnected(p)
        precondition(results == [false])
        m.powered(.poweredOn)
        try! c.connect(to: p.identifier, discover: .all, timeout: 2)
        precondition(m.connects.count == 2)
    }
    UIApplication.shared.applicationState = .active
}
