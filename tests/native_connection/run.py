"""Run production Central/delegates/tasks against deterministic OS boundaries.

Select the iOS conditional blocks in Central on macOS so lifecycle guards run too.
No production statements are replaced. UIKit/CoreBluetooth are test boundaries;
this does not claim real iOS suspension or radio validation.
"""
import argparse
from pathlib import Path
import subprocess

here = Path(__file__).resolve().parent
repo = here.parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('out', type=Path)
parser.add_argument('--source-ref', help='Replay an older committed plugin source')
parser.add_argument('--expect-stall', action='store_true')
args = parser.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
src = repo / 'packages/reactive_ble_mobile/darwin/reactive_ble_mobile/Sources/reactive_ble_mobile'

def run(argv):
    subprocess.run([str(a) for a in argv], check=True)

def contents(path):
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:{path.relative_to(repo)}'], cwd=repo).decode()
    return path.read_text()

flags = ['-module-cache-path', out / 'modules']
# The old release build stalls; its debug build asserts on the same invalid handoff.
assertions = ['-assert-config', 'Release'] if args.expect_stall else []
for module in ['CoreBluetooth', 'FlutterMacOS', 'UIKit']:
    run(['swiftc', *flags, '-emit-module', '-emit-library', '-module-name', module,
         here / f'{module}.swift', '-o', out / f'lib{module}.dylib',
         '-emit-module-path', out / f'{module}.swiftmodule'])
sources = []
for path in sorted((src / 'ReactiveBle').rglob('*.swift')):
    target = out / path.relative_to(src)
    target.parent.mkdir(parents=True, exist_ok=True)
    text = contents(path)
    if path.name == 'Central.swift':
        text = text.replace('#if os(iOS)', '#if STRIV_TEST_IOS')
    target.write_text(text)
    sources.append(target)
run(['swiftc', *flags, *assertions, '-D', 'STRIV_TEST_IOS', '-Onone', '-whole-module-optimization',
     '-I', out, '-L', out, '-lCoreBluetooth', '-lUIKit', '-Xlinker', '-rpath', '-Xlinker', out,
     here / 'Shims.swift', *sources, src / 'Prelude/papply.swift', here / 'main.swift', '-o', out / 'test'])
run([out / 'test', 'base' if args.expect_stall else 'fixed'])
