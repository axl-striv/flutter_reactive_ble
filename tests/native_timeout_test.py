"""Run the real registry against delayed timeout/connection ordering on macOS."""
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
source = root / 'packages/reactive_ble_mobile/darwin/reactive_ble_mobile/Sources/reactive_ble_mobile'
out = pathlib.Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
parts = ['''import Foundation
typealias PeripheralID = UUID
enum PluginError: Error { case internalInconcictency(details: String) }
''']
for name in ['PeripheralTask.swift', 'PeripheralTaskController.swift', 'PeripheralTaskRegistry.swift']:
    text = (source / 'ReactiveBle/Tasks/PeripheralTaskRegistry' / name).read_text()
    parts.append(re.sub(r'#if os\(iOS\).*?#endif', '', text, flags=re.S))
parts.append((source / 'Prelude/papply.swift').read_text())
parts.append((source / 'ReactiveBle/PendingConnectionRecovery.swift').read_text())
parts.append('''
struct Spec: PeripheralTaskSpec {
    typealias Key = Int; typealias Group = Int
    typealias Params = Int; typealias Stage = Int; typealias Result = Int
    static let tag = "test"
    static func isMember(_ key: Int, of group: Int) -> Bool { key == group }
}
struct Controller: PeripheralTaskController {
    typealias TaskSpec = Spec
    let task: SubjectTask
    init(_ task: SubjectTask) { self.task = task }
}
let registry = PeripheralTaskRegistry<Controller>()
var allowed = false, expired = 0, completed = 0
registry.registerTask(key: 1, params: 0, timeout: (0.01, { expired += 1 }),
    timeoutAllowed: { allowed }, completion: { _ in completed += 1 })
registry.updateTask(key: 1) { $0.task.with(state: $0.task.state.processing(0)) }
RunLoop.current.run(until: Date().addingTimeInterval(0.04))
precondition(expired == 0 && completed == 0, "suspension/connected guard must retain task")
registry.updateTask(key: 1) { $0.task.with(state: $0.task.state.finished(1)) }
allowed = true
RunLoop.current.run(until: Date().addingTimeInterval(0.04))
precondition(expired == 0 && completed == 1, "late success must complete and invalidate timer")
registry.registerTask(key: 1, params: 0, timeout: (0.01, { expired += 1 }), completion: { _ in completed += 1 })
registry.updateTask(key: 1) { $0.task.with(state: $0.task.state.processing(0)) }
RunLoop.current.run(until: Date().addingTimeInterval(0.04))
precondition(expired == 1, "a real foreground timeout must still expire")
for _ in 0..<2 {
    registry.registerTask(key: 2, params: 0, completion: { _ in completed += 1 })
}
registry.updateTask(key: 2) { $0.task.with(state: $0.task.state.processing(0)) }
registry.updateTasks(in: 2) { $0.task.with(state: $0.task.state.finished(0)) }
precondition(completed == 3, "retirement must clear both running and queued old tasks")
var outcomes: [Bool] = []
let first = PendingConnectionRecovery { outcomes.append($0) }
first.finish(true)
let second = PendingConnectionRecovery { outcomes.append($0) }
first.finish(false) // The first watchdog fires after a new request started.
precondition(outcomes == [true])
second.finish(false) // Central teardown, followed by its delayed watchdog.
second.finish(false)
precondition(outcomes == [true, false], "each request must complete exactly once")
print("Native timeout regression checks passed")
''')
(out / 'main.swift').write_text('\n'.join(parts))
subprocess.run(['swiftc', '-module-cache-path', str(out / 'modules'), str(out / 'main.swift'), '-o', str(out / 'check')], check=True)
subprocess.run([str(out / 'check')], check=True)
