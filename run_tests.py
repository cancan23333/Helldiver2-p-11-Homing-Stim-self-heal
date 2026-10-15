# -*- coding: utf-8 -*-
"""Run every check on the Homing Stim addon and report one verdict.

The checks, in order:
  1. lua_parse.py    - delimiters, block depth and operators are balanced
  2. smoke_test.py   - the chunk compiles and LOADS in a real Lua runtime, the
                       update hook installs, the frame clock advances, and the
                       previous global `update` is still chained
  3. test_priority.py- the friendly priority order, the in-tier aim tie-break,
                       and the cone / range / full-health filters
  4. test_menu.py    - every MODS row registers within ModOptionsMenu's limits
  5. build + verify  - the release ZIP matches what Bingus discovery reads
"""
import subprocess, sys, io
from pathlib import Path

# The console on this machine is GBK; the checks print Chinese labels, so force
# UTF-8 on the way out rather than crashing the runner on the report itself.
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

ROOT = Path(r'D:\新建文件夹 (2)')
RECON = ROOT / '_recon'

STEPS = [
    ('Lua structure',      [sys.executable, str(RECON / 'lua_parse.py'),
                            str(ROOT / 'Homing-Stim' / 'src' / 'addon.lua')]),
    ('load + update hook', [sys.executable, str(RECON / 'smoke_test.py')]),
    ('lock UI wiring',     [sys.executable, str(RECON / 'test_ui_wiring.py')]),
    ('target gates',       [sys.executable, str(RECON / 'test_target_gates.py')]),
    ('lease + assets',     [sys.executable, str(RECON / 'test_lease_assets.py')]),
    ('target box drop',    [sys.executable, str(RECON / 'test_box_drop.py')]),
    ('cfg migration',      [sys.executable, str(RECON / 'test_cfg_migration.py')]),
    ('priority + filters', [sys.executable, str(RECON / 'test_priority.py')]),
    ('SEAF whitelist',     [sys.executable, str(RECON / 'test_seaf_table.py')]),
    ('self-heal logic',    [sys.executable, str(RECON / 'test_selfheal.py')]),
    ('MODS menu rows',     [sys.executable, str(RECON / 'test_menu.py')]),
    ('menu language',      [sys.executable, str(RECON / 'test_language.py')]),
    ('build package',      [sys.executable, str(ROOT / 'Homing-Stim' / 'build.py')]),
    ('verify package',     [sys.executable, str(ROOT / 'Homing-Stim' / 'verify.py')]),
]

results = []
for label, cmd in STEPS:
    print('=' * 70)
    print('== %s' % label)
    print('=' * 70)
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    out = (p.stdout or '') + (p.stderr or '')
    print(out.rstrip())
    # Trust the EXIT CODE, which every check sets on failure, plus the explicit
    # verdict line.  Do NOT scan for the bare word "FAIL": a check's own heading
    # can legitimately contain it (one says "the pellet write FAILED: only one
    # round in flight"), and matching that reported a passing test as broken.
    ok = p.returncode == 0 and 'RESULT: FAIL' not in out
    results.append((label, ok))
    print()

print('=' * 70)
print('SUMMARY')
print('=' * 70)
for label, ok in results:
    print('  %s  %s' % ('PASS' if ok else 'FAIL', label))
bad = [l for l, ok in results if not ok]
print()
if bad:
    print('OVERALL: FAIL (%d step(s))' % len(bad))
    sys.exit(1)
print('OVERALL: PASS - every check green')
