import CoreBluetooth

struct CharacteristicNotifyTaskController: PeripheralTaskController {

    typealias TaskSpec = CharacteristicNotifyTaskSpec

    private let task: SubjectTask

    init(_ task: SubjectTask) {
        self.task = task
    }

    func start(characteristic: CBCharacteristic) -> SubjectTask {
        return start(isNotifying: characteristic.isNotifying) { isOn in
            guard let peripheral = characteristic.service?.peripheral
            else { return false }

            peripheral.setNotifyValue(isOn, for: characteristic)
            return true
        }
    }

    /// Starts this task unless one is already applying its state: a second
    /// `setNotifyValue` would repeat that state, and its callback would then
    /// complete a queued task that never reached the radio.
    func start(isNotifying: Bool, apply: (Bool) -> Bool) -> SubjectTask {
        guard case .pending = task.state
        else { return task }

        // Already in this state: no callback to wait for.
        guard isNotifying != task.params.state.isOn
        else { return task.with(state: task.state.finished(nil)) }

        guard apply(task.params.state.isOn)
        else { return task.with(state: task.state.finished(CharacteristicNotifyError.unExpected)) }

        return task.with(state: task.state.processing(.applying))
    }

    func cancel(error: Error) -> SubjectTask {
        return task.with(state: task.state.finished(error))
    }

    func complete(error: Error?) -> SubjectTask {
        guard case .processing = task.state
        else { return task }

        return task.with(state: task.state.finished(error))
    }

    private enum CharacteristicNotifyError: Error {
            case unExpected
            }
}
