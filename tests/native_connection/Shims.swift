import CoreBluetooth
// Plugin serialization types are irrelevant to the connection lifecycle under test.
typealias Failable<T> = Result<T, Error>
enum PluginError: Error { case connectionLost; case internalInconcictency(details: String?) }
struct CharacteristicInstance: Equatable {
    var peripheralID: UUID, serviceID = CBUUID(string: "service"), serviceInstanceID = "0", id = CBUUID(string: "characteristic"), instanceID = "0"
    init(_ characteristic: CBCharacteristic) throws { peripheralID = characteristic.service?.peripheral?.identifier ?? UUID() }
}
