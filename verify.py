# -*- coding: utf-8 -*-
"""Verify the built ZIP the way Bingus Shared Loader's discovery will read it.

Checks, in the order the loader does them:
  1. the ZIP layout and the manager manifest;
  2. the patch archive magic, type table and resource table;
  3. that the resource's own murmur hash matches the resource NAME (discovery
     keys the declaration by this hash, so a mismatch means the entry is never
     started);
  4. that the Lua envelope is `body length` + version 2 + source, and that the
     source begins with the exact `-- HD2-Addon:` declaration within 256 bytes;
  5. that the embedded source is byte-identical to the file we built from.
"""
import json, struct, sys, zipfile
from pathlib import Path

ROOT = Path(r'D:\新建文件夹 (2)')
LOADER = ROOT / 'BingusSharedLoader-source-v19'
sys.path.insert(0, str(LOADER / 'scripts'))
from archive import resource_hash, read_resource, ARCHIVE   # noqa: E402

ZIP = ROOT / 'Homing-Stim' / 'dist' / 'Homing-Stim-v1.0.12.zip'
MODULE = 'mods/cancan2333/homing_stim'
SRC = ROOT / 'Homing-Stim' / 'src' / 'addon.lua'

fail = []
def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        fail.append(msg)

print('== ZIP layout ==')
z = zipfile.ZipFile(ZIP)
names = sorted(z.namelist())
print('   entries:', names)
check('manifest.json' in names, 'manifest.json present')
check(('Addon/' + ARCHIVE) in names, 'Addon/%s present' % ARCHIVE)
check(('Addon/' + ARCHIVE + '.stream') in names, 'stream sidecar present')
check(('Addon/' + ARCHIVE + '.gpu_resources') in names, 'gpu_resources sidecar present')
bad = z.testzip()
check(bad is None, 'every entry passes its CRC (bad=%s)' % bad)

print('== manifest ==')
man = json.loads(z.read('manifest.json').decode('utf-8'))
print(json.dumps(man, indent=2, ensure_ascii=False)[:600])
check(man.get('Version') == '1.0.12', 'Version is 1.0.12')
check(bool(man.get('Guid')), 'Guid present')
check('Homing Stim' in man.get('Name', ''), 'Name names the mod')
inc = man.get('Options', [{}])[0].get('Include')
check(inc == ['Addon'], 'Options[0].Include == ["Addon"]')

print('== patch archive ==')
data = z.read('Addon/' + ARCHIVE)
magic, types, count = struct.unpack_from('<III', data)
check(magic == 0xF0000011, 'archive magic 0xF0000011 (got 0x%X)' % magic)
check(count == 1, 'exactly one resource (got %d)' % count)

want_hash = resource_hash(MODULE)
body = read_resource(data, want_hash)
check(body is not None, 'resource found under its murmur hash 0x%016X' % want_hash)
if body is None:
    print('RESULT: FAIL'); sys.exit(1)

print('== Lua envelope ==')
blen, ver = struct.unpack_from('<II', body, 0)
check(ver == 2, 'envelope version 2 (got %d)' % ver)
payload = body[8:]
check(len(payload) == blen, 'declared body length %d matches payload %d' % (blen, len(payload)))
check(payload[:1] != b'\x1b', 'payload is PLAINTEXT, not bytecode')

print('== declaration ==')
decl = ('-- HD2-Addon: ' + MODULE + '\n').encode()
check(payload.startswith(decl), 'payload starts with the exact declaration')
first_nl = payload.find(b'\n')
check(0 <= first_nl < 256, 'declaration fits in the first 256 bytes (ends at %d)' % first_nl)

print('== content ==')
# The builder rewrites the FIRST line (the declaration) to end with a bare LF -
# AUTHORING.md requires the declaration to be LF or CRLF terminated, and the
# helper normalises it.  So compare from the second line on, and separately
# assert the declaration itself.
src_now = SRC.read_bytes()
src_tail = src_now.split(b'\n', 1)[1]
emb_tail = payload.split(b'\n', 1)[1]
check(emb_tail == src_tail, 'embedded source matches src/addon.lua from line 2 on')
check(b'P-11' in payload, 'mentions the P-11')
check(b'0xD6B1FB05B9109353' in payload, 'carries the P-11 resource hash')

# every SEAF hash must appear as the little-endian byte list we generated
seaf = {
    'SEAF MK1': 11530114387757953774, 'SEAF MK2': 6089208603239816028,
    'Backpack': 7719924637775600975, 'Wireless MK1': 13617855600110100742,
    'Wireless MK2': 8708480032737395252, 'Medical MK1': 1460639142923993241,
    'Medical MK2': 8048468262572802857, 'Medical MK3': 14155525937218621891,
    'Mg/AT MK1': 13814167941378577880, 'Mg/AT MK2': 12023698573119337990,
}
print('== SEAF whitelist, encoded the way the game stores it ==')
for label, h in seaf.items():
    le = h.to_bytes(8, 'little')
    needle = ', '.join('0x%02X' % b for b in le).encode()
    check(needle in payload, '%-12s 0x%016X present as %s' % (label, h, needle.decode()))

print()
if fail:
    print('RESULT: FAIL (%d checks failed)' % len(fail))
    sys.exit(1)
print('RESULT: PASS - the package matches what the loader will read')
