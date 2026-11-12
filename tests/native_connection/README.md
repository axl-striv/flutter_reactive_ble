# Native connection handoff and recovery

From the repository root, run:

```sh
python3 tests/native_connection/run.py /absolute/path/to/build-output
python3 tests/native_timeout_test.py /absolute/path/to/timeout-output
```

The handoff fixture is retained from Flutter #1645's validation commit
`0a8d43d669139302c88ed30bf903c93976c63d87`. It compiles this checkout's actual
Central, delegates and task controllers against deterministic CoreBluetooth and
application lifecycle boundaries. The runner selects Central's iOS conditional
blocks on macOS; production statements are unchanged. Swift debug assertions are
enabled for the fixed version.

It covers cancel/replace ordering, replacement timeout, late connection success,
queued cancellation, peer isolation, disconnect-all, radio power cycling, restored
links and discovery retirement. Integration cases cover recovery joining a
cancellation, queued replacements winning ownership, delayed terminal callbacks,
watchdog failure with ownership retained,
late native success, background timeout deferral/resume and radio loss.

To reproduce the pre-integration release stall:

```sh
python3 tests/native_connection/run.py /absolute/path/to/before-output --source-ref fdd3be2 --expect-stall
```

That mode selects release assertions: the old debug build instead asserts when it
tries to start the queued replacement through the old task controller. Neither
mode represents an actual iPhone suspension or physical pod radio test.
