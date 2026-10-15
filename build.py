# -*- coding: utf-8 -*-
"""Build the Homing Stim release ZIP with Bingus Shared Loader's own packer.

Using the loader's `scripts/build_addon.py` rather than hand-rolling the archive
is deliberate: it is the same code the loader's discovery reads, so the resource
name, the seed-zero MurmurHash64A id, the Lua envelope and the manager manifest
are guaranteed to match what the game expects.
"""
import io, json, sys, zipfile
from pathlib import Path

ROOT = Path(r'D:\新建文件夹 (2)')
LOADER = ROOT / 'BingusSharedLoader-source-v19'
OUT = ROOT / 'Homing-Stim' / 'dist'

sys.path.insert(0, str(LOADER / 'scripts'))
from build_addon import build_addon          # noqa: E402
from archive import resource_hash            # noqa: E402

MODULE = 'mods/cancan2333/homing_stim'
GUID = 'b7f3c1a4-5d2e-4c88-9f61-0a1e2d3c4b59'
VERSION = '1.0.12'

SRC = ROOT / 'Homing-Stim' / 'src' / 'addon.lua'
ADDON_MD = ROOT / 'Homing-Stim' / 'docs' / 'README.md'
CFG_MD = ROOT / 'Homing-Stim' / 'docs' / 'homing_stim.cfg.example'

OUT.mkdir(parents=True, exist_ok=True)
zip_path = OUT / ('Homing-Stim-v%s.zip' % VERSION)

source = SRC.read_bytes()

# The build helper writes its own generic manifest; we want a real description
# and the bilingual blurb the other mods in this workspace carry, so build to a
# temp path and then rewrite the manifest entry in place.
build_addon(MODULE, source, GUID, zip_path, 'Homing Stim v%s' % VERSION)

DESC = (
    '把 P-11 治疗剂手枪改造成制导武器，锁定友方单位：潜兵与 SEAF AI NPC。'
    '锁定优先度为残血潜兵 > 满血潜兵 > 残血 SEAF > 满血 SEAF。'
    '带子弹穿墙、满血目标过滤、锁定范围锥角、范围环、锁定标记、锁定部位、'
    '掩体判断、自己绑定目标等选项，全部可在游戏内 MODS 菜单实时调整。'
    '需要 Bingus Shared Loader v15+ 与 HD2Runtime；游戏内菜单需要 Mod Options Menu v1+。'
    '  |  Converts the P-11 Stim Pistol into a guided weapon that locks onto '
    'FRIENDLY units: Helldivers and SEAF AI NPCs, wounded first. Options: piercing '
    'shot, ignore full health, lock cone, range ring, lock markers, target box, '
    'requires line of sight and bind-target-ourselves, all tunable from the in-game '
    'MODS tab. Requires Bingus Shared Loader v15+ and HD2Runtime; the in-game menu '
    'needs Mod Options Menu v1+.'
)

manifest = {
    'Version': VERSION,
    'Guid': GUID,
    'Name': 'Homing Stim v%s' % VERSION,
    'Description': DESC,
    'Options': [{
        'Name': 'Homing Stim v%s - cancan2333' % VERSION,
        'Description': DESC,
        'Include': ['Addon'],
        'Image': '',
    }],
}

# rewrite the archive: keep the Addon payload the builder produced, replace the
# manifest, and add the docs the other packages in this workspace also ship
with zipfile.ZipFile(zip_path, 'r') as z:
    files = {n: z.read(n) for n in z.namelist()}

files['manifest.json'] = (json.dumps(manifest, indent=2, ensure_ascii=False) + '\n').encode('utf-8')
files['README.md'] = ADDON_MD.read_bytes()
files['Source/addon.lua'] = source
if CFG_MD.exists():
    files['Source/homing_stim.cfg'] = CFG_MD.read_bytes()
# The licence and the attribution chain travel with the package: this project is
# a derivative of community work, so the credits should not live only on GitHub.
for extra, name in ((ROOT / 'Homing-Stim' / 'NOTICE.md', 'NOTICE.md'),
                    (ROOT / 'Homing-Stim' / 'LICENSE', 'LICENSE'),
                    (ROOT / 'Homing-Stim' / 'docs' / 'WORKSHOP_BBCODE.txt',
                     'Source/workshop-description.bbcode.txt')):
    if extra.exists():
        files[name] = extra.read_bytes()

with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for name, data in sorted(files.items()):
        info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        z.writestr(info, data)

print('built   : %s' % zip_path)
print('resource: %s' % MODULE)
print('reshash : 0x%016X' % resource_hash(MODULE))
print('guid    : %s' % GUID)
print('bytes   : %d' % zip_path.stat().st_size)
