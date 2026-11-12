// One completion belongs to one native cancellation, even when a later
// cancellation reuses the same peripheral identifier.
final class PendingConnectionRecovery {
    private var completion: ((Bool) -> Void)?
    init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
    func finish(_ retired: Bool) {
        let callback = completion
        completion = nil
        callback?(retired)
    }
}
