-- HD2-Addon: mods/cancan2333/homing_stim
-- Homing Stim v1.0.0 - P-11 Stim Pistol guided rounds for FRIENDLY units.
-- Author: cancan2333   (derived from Guided Rounds v1.8.0 by cancan2333 & SoS2430)
--
-- WHAT THIS IS
--   Guided Rounds v1.8.0 gives a long list of weapons the P-92 Warrant's own
--   guidance, and locks ENEMIES.  This addon keeps that machinery and changes
--   exactly two things:
--
--     1. The weapon is FIXED to the P-11 Stim Pistol (0xD6B1FB05B9109353).
--        There is no weapon list and no per-weapon menu page.
--     2. The candidates are FRIENDLY: Helldivers (the local avatar's own entity
--        type, so no external hash list can go stale) and the SEAF AI NPCs
--        (whitelisted by resource hash, taken from the community ID workbook).
--
--   Everything else - the leased P-92 seeker, the +0x28 projectile_entity
--   write, the seeking-manager binding by publish(FIELD_TARGET), the aim cone,
--   the range ring, the lock marker, the target box, the cover raycast - is the
--   reference implementation, unchanged in behaviour.
--
-- PRIORITY (highest first)
--   wounded Helldiver > full-health Helldiver > wounded SEAF > full-health SEAF
--   Inside one tier the target closest to the aim axis still wins, and a target
--   must be inside the cone and the range to be a candidate at all.
--
-- OPTIONS (MODS tab, one category)
--   ENABLE, HEAL YOURSELF WHEN FIRING, IGNORE FULL HEALTH, LOCK ANGLE, LOCK RANGE,
--   RANGE RING, LOCK MARKERS, TARGET BOX, REQUIRES LINE OF SIGHT,
--   BIND TARGET OURSELVES
--
-- The cfg file stays the single source of truth, exactly as in Guided Rounds:
-- the menu is handed the file's values when it appears, a change writes straight
-- through to the file, and whatever the menu snaps a value to is written back.
--
-- REQUIRES  Bingus Shared Loader v15+ (API 1) and optionally
--           CowboyBingus Mod Options Menu v1+ for the in-game MODS tab.

local KEY = 'Hd2HomingStim'
local REVISION = 'homing-stim-v1.0.12'
-- This addon's own resource name.  The runtime wants it as the `owner` of the
-- actions this mod causes (the self-heal), so that a mod-caused heal is
-- attributed to the right addon.
local MODULE_ID = 'mods/cancan2333/homing_stim'
if rawget(_G, KEY) then return end
local state = { frame = 0, writes = 0, binds = 0, armed = false, leased = false,
                failures = 0 }
rawset(_G, KEY, state)

local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi or not ffi then return end
pcall(ffi.cdef, [[
    void *GetModuleHandleA(const char *name);
    void *GetProcAddress(void *module, const char *name);
]])

-- ---------------------------------------------------------------- files
-- A fresh install has no folder under LOCALAPPDATA and io.open(...,'w') on a
-- missing folder fails silently, so the folder is made through CreateDirectoryA
-- (never os.execute - a shell out is what once made the game start to a black
-- screen).
local CD = nil
local function ensure_dir(path)
    if not path or not CD then return false end
    local ok = pcall(CD, path, nil)
    return ok == true
end

local OUT_DIR, CFG_PATH, LOG_PATH, APP_DIR
do
    local b = os.getenv('LOCALAPPDATA')
    if b then
        APP_DIR = b
        OUT_DIR = b .. '\\HomingStim'
        CFG_PATH = OUT_DIR .. '\\homing_stim.cfg'
        LOG_PATH = OUT_DIR .. '\\HomingStim.log'
    end
end
local function use_flat_dir()
    if not APP_DIR then return false end
    OUT_DIR = APP_DIR
    CFG_PATH = APP_DIR .. '\\homing_stim.cfg'
    LOG_PATH = APP_DIR .. '\\HomingStim.log'
    return true
end

local lines = 0
local log_dir_ok = nil
local function log(line)
    if not LOG_PATH then return end
    lines = lines + 1
    if lines > 20000 then return end
    if log_dir_ok ~= true then
        if CD then ensure_dir(OUT_DIR) end
        local probe = LOG_PATH and io.open(LOG_PATH, 'a') or nil
        if probe then probe:close(); log_dir_ok = true else return end
    end
    pcall(function()
        local f = io.open(LOG_PATH, 'a')
        if f then f:write(os.date('%H:%M:%S') .. ' ' .. line .. '\n'); f:close() end
    end)
end

-- ---------------------------------------------------------------- memory API
local kernel = ffi.C.GetModuleHandleA('kernel32')
local RPM, WPM, VP, VQ, KS
if kernel ~= nil then
    local p = ffi.C.GetProcAddress(kernel, 'ReadProcessMemory')
    if p ~= nil then RPM = ffi.cast('int (*)(void *, const void *, void *, size_t, void *)', p) end
    p = ffi.C.GetProcAddress(kernel, 'WriteProcessMemory')
    if p ~= nil then WPM = ffi.cast('int (*)(void *, void *, const void *, size_t, void *)', p) end
    p = ffi.C.GetProcAddress(kernel, 'VirtualProtect')
    if p ~= nil then VP = ffi.cast('int (*)(void *, size_t, uint32_t, void *)', p) end
    p = ffi.C.GetProcAddress(kernel, 'VirtualQuery')
    if p ~= nil then VQ = ffi.cast('size_t (*)(const void *, void *, size_t)', p) end
    p = ffi.C.GetProcAddress(kernel, 'CreateDirectoryA')
    if p ~= nil then CD = ffi.cast('int (*)(const char *, void *)', p) end
end
local user = ffi.C.GetModuleHandleA('user32')
if user ~= nil then
    local p = ffi.C.GetProcAddress(user, 'GetAsyncKeyState')
    if p ~= nil then KS = ffi.cast('int16_t (*)(int)', p) end
end
if not RPM or not WPM or not VP then log('memory API unavailable - abort'); return end
if OUT_DIR then
    ensure_dir(OUT_DIR)
    local probe = io.open(LOG_PATH, 'a')
    if probe then
        probe:close()
    elseif use_flat_dir() then
        log_dir_ok = nil
        log('NOTE: could not use ' .. tostring(APP_DIR) .. '\\HomingStim, writing '
            .. 'the cfg and the log straight into ' .. tostring(APP_DIR))
    end
end

local PROC = ffi.cast('void *', -1)
local got = ffi.new('size_t[1]')
local oldp = ffi.new('uint32_t[1]')
local backp = ffi.new('uint32_t[1]')

local base, exe_base
do
    local m = ffi.C.GetModuleHandleA('game.dll')
    if m ~= nil then base = tonumber(ffi.cast('uintptr_t', m)) end
    local e = ffi.C.GetModuleHandleA(nil)
    if e ~= nil then exe_base = tonumber(ffi.cast('uintptr_t', e)) end
end
if not base then log('game.dll not found - abort'); return end
log(('Homing Stim %s loading  game.dll=0x%X exe=0x%X'):format(REVISION, base, exe_base or 0))

local function rd(a, n)
    if type(a) ~= 'number' or a < 65536 or a >= 0x800000000000 then return nil end
    local b = ffi.new('uint8_t[?]', n)
    if RPM(PROC, ffi.cast('void *', a), b, n, got) == 0 then return nil end
    if tonumber(got[0]) ~= n then return nil end
    return ffi.string(b, n)
end
local function u32(s, o) if not s or #s < o + 4 then return nil end
    local a, b, c, d = s:byte(o + 1, o + 4) return a + b * 256 + c * 65536 + d * 16777216 end
local function i32(s, o) local v = u32(s, o) if not v then return nil end
    if v >= 0x80000000 then v = v - 4294967296 end return v end
local function u64(s, o)
    if not s or #s < o + 8 then return nil end
    local lo, hi = u32(s, o), u32(s, o + 4)
    if not lo or not hi then return nil end
    return lo + hi * 4294967296
end
-- IEEE-754 single out of a byte string.  One shared 4-byte buffer, because this
-- runs for every bone of every candidate every scan.
local fbuf = ffi.new('uint8_t[4]')
local fcast = ffi.cast('float *', fbuf)
local function f32(s, o)
    if not s or #s < o + 4 then return nil end
    fbuf[0], fbuf[1], fbuf[2], fbuf[3] = s:byte(o + 1, o + 4)
    return tonumber(fcast[0])
end
local f32b = f32
local function finite(v)
    return type(v) == 'number' and v == v and v <= 1e7 and v >= -1e7
end
local function ptr8(a)
    local s = rd(a, 8)
    if not s then return nil end
    local v = u64(s, 0)
    if not v or v < 65536 or v >= 0x800000000000 then return nil end
    return v
end
local function word(n)
    n = math.floor(n) % 4294967296
    return string.char(n % 256, math.floor(n / 256) % 256,
                       math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
local function intersects(a, b)
    local bit = 1
    while bit <= 0x80000000 do
        if a % (bit * 2) >= bit and b % (bit * 2) >= bit then return true end
        bit = bit * 2
    end
    return false
end
local function hexs(s)
    if type(s) ~= 'string' then return '?' end
    local t = {}
    for i = 1, #s do t[i] = string.format('%02X', s:byte(i)) end
    return table.concat(t)
end
local function hexa(a)
    return type(a) == 'number' and string.format('0x%X', a) or '?'
end
local function write_bytes(a, bytes)
    if type(a) ~= 'number' or type(bytes) ~= 'string' or #bytes < 1 then return false end
    oldp[0] = 0
    if VP(ffi.cast('void *', a), #bytes, 0x40, oldp) == 0 then
        return false
    end
    local ok = (WPM(PROC, ffi.cast('void *', a), bytes, #bytes, got) ~= 0)
        and (tonumber(got[0]) == #bytes)
    VP(ffi.cast('void *', a), #bytes, oldp[0], backp)
    if not ok then return false end
    if rd(a, #bytes) ~= bytes then return false end
    state.writes = state.writes + 1
    return true
end

-- ---------------------------------------------------------------- constants
-- All of these are Guided Rounds v1.8.0's reviewed values, unchanged.
local R = {
    entity = 0x346bf98, weapon = 0x33266d8, attach = 0x3326dc0,
    health = 0x3326688, faction = 0x3326cb8, player = 0x3326468,
    pose = 0x3326ce0, mission = 0x33266a0, seeking = 0x3326df0,
    publish = 0xfd97e0,
}

local FIELD_TARGET = 0xAC08FE53
local FIELD_NODE = 0x69A47345
local GUIDANCE_NODE = 16
local UNBOUND = 0x7fff
-- The unit registry is in the executable, not in game.dll.
local EXE_UNIT_REGISTRY = 0x1a100f0

local ROW_SIZE = 616
local SET_TBL_OFF = 0xf12e80
local SET_ROW_OFF = 0x21e0
local SET_ENTRIES = 542

-- The per-run state that every helper below shares.  Declared HERE, above the
-- helpers, on purpose: the reference once shipped a bug where a cfg loader wrote
-- ctx.* before `local ctx` existed, so the writes landed on a GLOBAL ctx and the
-- whole addon failed to load.
local ctx = {
    frame = 0, targets = {}, self_mask = nil, avatar_id = nil,
    avatar_resource = nil, held = nil,
}

-- The weapon this addon is FOR.  P-11 Stim Pistol, from the community ID
-- workbook: 15470422196992643923 == 0xD6B1FB05B9109353 (the same hash the
-- published P-11 Stim Homing addon uses).
local STIM_HEX = '0xD6B1FB05B9109353'
local STIM_B = string.char(0x53, 0x93, 0x10, 0xB9, 0x05, 0xFB, 0xB1, 0xD6)

-- The P-92 Warrant projectile entity: the thing that actually carries the
-- SeekingMissileComponentData whose targeting_mode is TargetLock.  Writing it
-- over the P-11's own projectile_entity (+0x28 of the 616-byte
-- ProjectileWeaponComponentData row) is what makes the stim round home.
local P92_ENTITY_B = string.char(0x92, 0x13, 0x97, 0x58, 0x43, 0xDA, 0x53, 0x80)
local P92_HEX = '0x8053DA4358971392'
local LEASE = { bytes = P92_ENTITY_B, txt = P92_HEX }
local ZERO8 = string.rep('\0', 8)

-- SEAF AI NPCs, from the community ID workbook (column 4 of the SEAF block).
-- These are FRIENDLY.  The enemy path necessarily rejects them (same faction
-- mask as us), so - like Guided Rounds v1.8.0's enemy whitelist - they are
-- admitted by resource hash instead.
-- Every SEAF AI NPC, one entry per actor the resource workbook lists.
--
-- BUILT FROM THE WHOLE WORKBOOK, not from one block of it: an earlier version
-- took ten rows from a single block, so the SEAF whose rows live elsewhere -
-- the MK3..MK8 bodies, plain `SEAF`, `SEAF (City)`, the machine gunner, and a
-- second `SEAF MK2` hash - could never be admitted and therefore never locked.
-- That was the "individual SEAF do not lock" report.
--
-- Names come from the sheet and are only ever used in the log.  The SEAF ITEMS
-- (its Liberator, SMG, MG-43, EAT-17, stim pistol, grenades and backpacks) are
-- deliberately absent: an item hash is not a unit entity type.
local SEAF = {
    [string.char(0xDC, 0x67, 0xA2, 0x4C, 0xCF, 0xAE, 0x1E, 0x02)] = 'SEAF (City)',
    [string.char(0x99, 0x00, 0x04, 0xCB, 0x8F, 0x3B, 0x45, 0x14)] = 'Medical SEAF MK1',
    [string.char(0xE0, 0x5B, 0x23, 0x9A, 0x67, 0x34, 0xA1, 0x4E)] = 'SEAF MK7',
    [string.char(0x5C, 0x9B, 0x5C, 0x6F, 0xF6, 0x36, 0x81, 0x54)] = 'SEAF MK2',
    [string.char(0x4F, 0x9D, 0x66, 0x5F, 0x8E, 0xAE, 0x22, 0x6B)] = 'SEAF With Backpack',
    [string.char(0x29, 0x43, 0xA8, 0x00, 0x3E, 0xE7, 0xB1, 0x6F)] = 'Medical SEAF MK2',
    [string.char(0x73, 0xC4, 0xD1, 0xB0, 0x13, 0x08, 0x07, 0x76)] = 'SEAF MK5',
    [string.char(0x5B, 0xEB, 0xE6, 0x1C, 0x79, 0x2C, 0xAC, 0x76)] = 'SEAF MK3',
    [string.char(0x34, 0x02, 0xE5, 0x44, 0x73, 0xBC, 0xDA, 0x78)] = 'SEAF With Wireless MK2',
    [string.char(0x4C, 0x4E, 0xA5, 0x33, 0xCD, 0x37, 0x36, 0x7A)] = 'SEAF',
    [string.char(0x74, 0xE7, 0x5E, 0xDB, 0xA9, 0x64, 0xB9, 0x7B)] = 'SEAF MK2',
    [string.char(0x3D, 0x54, 0xD1, 0x40, 0xD0, 0x27, 0x59, 0x97)] = 'SEAF MK8',
    [string.char(0xBF, 0x58, 0xB1, 0xBC, 0x53, 0xEA, 0xCF, 0x9E)] = 'SEAF MK4',
    [string.char(0x5C, 0xA4, 0x4C, 0x41, 0xAA, 0x45, 0x02, 0x9F)] = 'SEAF MG',
    [string.char(0xEE, 0xF2, 0xEE, 0x4D, 0xF2, 0x31, 0x03, 0xA0)] = 'SEAF MK1',
    [string.char(0x06, 0x36, 0x26, 0xE1, 0x25, 0xC2, 0xDC, 0xA6)] = 'Mg/Anti-Tank SEAF MK2',
    [string.char(0x06, 0x61, 0x20, 0x8F, 0x84, 0x57, 0xFC, 0xBC)] = 'SEAF With Wireless MK1',
    [string.char(0xD8, 0x95, 0x75, 0x55, 0x8D, 0xC8, 0xB5, 0xBF)] = 'Mg/Anti-Tank SEAF MK1',
    [string.char(0xC3, 0x91, 0xBE, 0x38, 0xD7, 0x87, 0x72, 0xC4)] = 'Medical SEAF MK3',
    [string.char(0x4B, 0x7D, 0xB4, 0x2B, 0x23, 0x59, 0x69, 0xEA)] = 'SEAF MK6',
}

-- ---------------------------------------------------------------- cfg
local CFGVER = 2
local cfg = {
    enable = 1, autostart = 1, key = 118,
    -- 15 degrees, not the reference's 12, and NOT a wider 30.
    --
    -- The range ring's on-screen radius is tan(cone) * (h/2) / tan(fov/2), so a
    -- cone is only visible while it is narrower than HALF the current FOV.  At
    -- 30 degrees the ring sits exactly on the screen edge at hipfire (FOV ~60)
    -- and, once you aim down the sights (FOV ~30), projects to about 1160 px on
    -- a 1080p screen - more than twice the half-height, i.e. entirely off
    -- screen.  "The range ring does not show when I right-click" is that
    -- arithmetic.  15 degrees stays on screen at every FOV, and at 10 m it
    -- still covers a 2.7 m radius, which is plenty for a teammate standing
    -- next to you.  Raise it if you want a wider net, but expect the ring to
    -- leave the screen once the cone passes half your FOV.
    cone_deg = 15, max_dist = 120,
    -- do not lock a unit that is at full health.
    ignore_full = 0,
    -- ---------------------------------------------------------------- self-heal
    -- Heal the shooter on a REAL P-11 shot.  This is NOT done with the rounds:
    -- it hooks the runtime's `player_fired` event and calls the game's own heal.
    -- The earlier attempt tried to fire a second pellet and steer it back into
    -- the shooter, which could not work (the seeker turns about 30 deg/s, so a
    -- round cannot come back, and the engine drops the shooter from its own
    -- projectile's collisions).  See the self-heal section for the full story.
    self_heal = 0,
    heal_percent = 35,     -- percent of MAXIMUM health per real shot
    heal_amount = 0,       -- absolute health points instead; 0 = use the percent
    heal_limbs = 1,        -- also repair limb damage, when the runtime can
    heal_cooldown = 0.5,   -- seconds between heals
    heal_per_event = 1,    -- most heals one fired event may pay for
    -- inherited, same meaning as Guided Rounds
    lua_bind = 1, bind_delay = 0.2, debug = 0,
    cone_fallback = 0,
    require_assets = 1,
    seek_speed = 0, seek_accel = 0, seek_ptr = 0,
    los_check = 1, los_debug = 0, los_foliage = 1, los_desc = 0,
    scan_ms = 4, target_interval = 20,
    lock_reticle = 1, range_ring = 1, target_box = 1,
    seek_entity = 0,
}

local function write_default_cfg()
    if not CFG_PATH then return end
    ensure_dir(OUT_DIR)
    local w = io.open(CFG_PATH, 'w')
    if not w then
        ensure_dir(OUT_DIR)
        w = io.open(CFG_PATH, 'w')
        if not w then return end
    end
    w:write(table.concat({
        'cfgver=' .. tostring(CFGVER),
        '# Homing Stim v1.0.0 - P-11 Stim Pistol guided rounds for FRIENDLY units',
        '# (Helldivers and SEAF AI).  Derived from Guided Rounds v1.8.0.',
        '#',
        '# The weapon is FIXED to the P-11 Stim Pistol.  There is no weapons=',
        '# list: nothing else is touched by this addon.',
        '',
        '# enable      1 = on. Off puts every value it wrote back.',
        'enable=1',
        '# autostart   1 = arm by itself as soon as the game starts.',
        'autostart=1',
        '# key         F7 = restart the addon (restore everything, then re-arm).',
        'key=118',
        '',
        '# ignore_full 1 = a unit at FULL health is never locked, so the stim',
        '#             only ever flies at somebody who is actually hurt.',
        'ignore_full=0',
        '',
        '# ------------------------- SELF-HEAL (heal yourself when you shoot) -----',
        '# self_heal   1 = a REAL P-11 shot heals you.  This does NOT use the rounds:',
        '#             it hooks the runtime player_fired event and calls the game\'s',
        '#             own heal (AddHealthFraction), so it clamps at max health and',
        '#             is refused while you are downed or dead.  Needs HD2Runtime.',
        'self_heal=0',
        '# heal_percent  percent of your MAXIMUM health per real shot. 35 is about',
        '#             what a stim gives back.  The log prints the amount and the',
        '#             maximum it was scaled from, so this can be dialled exactly.',
        'heal_percent=35',
        '# heal_amount  absolute health points instead; 0 = use the percent above.',
        'heal_amount=0',
        '# heal_limbs  1 = also repair limb damage (head/chest/hands/knees) on each',
        '#             heal.  Needs hd2.actions.heal_limbs (HD2Runtime 0.30+); when',
        '#             the runtime has no such call it is skipped and the log says so.',
        'heal_limbs=1',
        '# heal_cooldown seconds that must pass between two heals.',
        'heal_cooldown=0.5',
        '# heal_per_event  most heals one fired event may pay for.  The runtime polls',
        '#             the fired stat ten times a second, so a burst arrives as ONE',
        '#             event with a count; raise this to 2-3 to heal faster on auto.',
        'heal_per_event=1',
        '',
        '# cone_deg    aim-cone half angle, and the size of the range ring.',
        '#             The ring radius is tan(cone) * (h/2) / tan(fov/2), so the',
        '#             ring only stays on screen while this is less than HALF the',
        '#             current FOV.  30 looks fine at hipfire but leaves the screen',
        '#             the moment you aim down the sights; 15 stays visible at every',
        '#             FOV and still covers a 2.7 m radius at 10 m.  0 = no cone.',
        'cone_deg=15',
        '# max_dist    furthest target the round accepts, in metres.',
        'max_dist=120',
        '',
        '# PRIORITY (fixed, not configurable here):',
        '#   wounded Helldiver > full-health Helldiver',
        '#   > wounded SEAF > full-health SEAF',
        '# Inside one tier the target nearest the aim axis wins.',
        '',
        '# lua_bind    1 = bind a target ourselves when the engine has not.',
        'lua_bind=1',
        '# bind_delay  seconds after the muzzle before binding is allowed.',
        'bind_delay=0.2',
        '# cone_fallback 1 = lock the nearest candidate when the muzzle forward',
        '#             vector cannot be read (last resort).',
        'cone_fallback=0',
        '',
        '# require_assets 1 = ask the runtime to load the P-92 package, which is',
        '#             where the seeker lives.  Keep this on.',
        'require_assets=1',
        '',
        '# seek_speed  speed of the guided round, m/s. 0 = leave the game value',
        '#             (the warrant seeker ships at 90 m/s, which crawls).',
        'seek_speed=0',
        '# seek_accel  optional seeker acceleration. 0 = leave the game value.',
        'seek_accel=0',
        'seek_ptr=0',
        '',
        '# los_check   1 = do not lock through solid cover.',
        'los_check=1',
        '# los_foliage 1 = leaves do not count as cover.',
        'los_foliage=1',
        '# los_desc    which of the engine\'s 35 collision profiles (0-34) the',
        '#             sight test uses. 0 already recognises ground and solid',
        '#             cover; only raise it if cover is being missed.',
        'los_desc=0',
        '# los_debug   1 = log every ray and every hit (cfg only, not in the menu).',
        'los_debug=0',
        '',
        'scan_ms=4',
        'target_interval=20',
        '',
        '# lock_reticle 1 = draw the lock markers on the target.',
        'lock_reticle=1',
        '# range_ring   1 = draw the aim-cone range ring.',
        'range_ring=1',
        '# target_box   1 = draw the wire box on the locked target.',
        'target_box=1',
        '',
        '# debug       1 = verbose log (cfg only, not in the menu).',
        'debug=0',
        '',
        '# seek_entity 0 = the P-92 Warrant round (default and recommended).',
        'seek_entity=0',
    }, '\n') .. '\n')
    w:close()
end

local function parse_cfg()
    if not CFG_PATH then return end
    local f = io.open(CFG_PATH, 'r')
    if not f then return end
    for line in f:lines() do
        local k, v = line:match('^%s*([%a_]+)%s*=%s*(.-)%s*$')
        if k and v then
            if k == 'seek_entity' then
                local n = tonumber(v)
                if n and n ~= 0 then cfg.seek_entity = n else cfg.seek_entity = 0 end
            elseif k == 'cfgver' then
                state.cfgver_loaded = tonumber(v) or 0
            else
                local n = tonumber(v)
                if n then cfg[k] = n end
            end
        end
    end
    f:close()
end

-- One migration, and it is deliberately narrow.
--
-- v1 shipped cone_deg=30, which is wider than half of every FOV in the game, so
-- its range ring was off-screen whenever the player aimed down the sights.  The
-- v2 default is 15.  A cfg already on disk keeps whatever it holds - the loader
-- never overwrites it - so without this the people who hit the bug would keep
-- the very value that caused it.
--
-- It only rewrites the value when it is EXACTLY the old shipped default (30) and
-- the file predates v2, so a deliberately chosen angle (25, 40, whatever) is
-- left alone.  The change is logged with the old and new value.
local function migrate_cfg()
    if not CFG_PATH then return end
    local ver = state.cfgver_loaded
    if ver == nil or ver >= 2 then return end
    if tonumber(cfg.cone_deg) ~= 30 then return end
    local old = cfg.cone_deg
    cfg.cone_deg = 15
    state.save_cfg_key('cone_deg', '15')
    state.save_cfg_key('cfgver', '2')
    state.cfgver_loaded = 2
    log(('MIGRATE cone_deg %s -> 15: 30 is wider than half the FOV, so the range '
        .. 'ring was off-screen while aiming. Change it back in the MODS tab if '
        .. 'you wanted the wide cone.'):format(tostring(old)))
end

function state.save_cfg_key(key, value)
    if not CFG_PATH then return false end
    local ok = pcall(function()
        local f = io.open(CFG_PATH, 'r')
        if not f then return end
        local all = {}
        for line in f:lines() do all[#all + 1] = line end
        f:close()
        local pat = '^%s*' .. key .. '%s*='
        local hit = false
        for i = 1, #all do
            if all[i]:find(pat) then all[i] = key .. '=' .. tostring(value); hit = true end
        end
        if not hit then all[#all + 1] = key .. '=' .. tostring(value) end
        local w = io.open(CFG_PATH, 'w')
        if not w then return end
        w:write(table.concat(all, '\n') .. '\n')
        w:close()
    end)
    return ok
end

-- read it once at load, like the reference does
do
    local f = io.open(CFG_PATH or '', 'r')
    if f then f:close(); parse_cfg(); migrate_cfg() else write_default_cfg() end
end

-- ---------------------------------------------------------------- helpers
-- Guided Rounds' own hash map.  NOTE the layout: the header is 20 bytes, the
-- keys and values are packed into ONE 8-byte row (key +0, value +4), and the
-- empty marker is a separate field at +12 - not a linked list of 16-byte
-- entries.  This is copied from the reference verbatim because every map in the
-- game (factions, attachments, pose) is read through it.
local function mul32(a, b)
    local p = ffi.new('uint64_t', a) * ffi.new('uint64_t', b)
    return tonumber(ffi.cast('uint32_t', p))
end
local function slot(map, key, limit)
    local h = rd(map, 20)
    if not h then return nil, nil, nil, 'map_unreadable' end
    local b = u64(h, 0)
    local n, empty, mult = u32(h, 8), u32(h, 12), u32(h, 16)
    if not b or b < 65536 or b >= 0x800000000000 then return nil, nil, nil, 'map_base' end
    if not n or n == 0 or n > limit then return nil, nil, nil, 'map_size' end
    if key == empty then return nil, nil, nil, 'empty_key' end
    local product = mul32(key, mult)
    local probes = n
    if probes > 128 then probes = 128 end
    for probe = 0, probes - 1 do
        local a = b + 8 * ((product + probe) % n)
        local row = rd(a, 8)
        if not row then return nil, nil, nil, 'map_row_unreadable' end
        local k = u32(row, 0)
        if k == key then
            local v = u32(row, 4)
            return a, row, (v ~= 0xffffffff) and v or nil, n
        end
        if k == empty then return a, row, nil, n end
    end
    return nil, nil, nil, 'probe_limit'
end

-- 24 bytes: resource (8), then id / unit / net / flags as four u32.
local function entity(a)
    local b = rd(a, 24)
    if not b then return nil end
    local id, unit, net, flags = u32(b, 8), u32(b, 12), u32(b, 16), u32(b, 20)
    if not id or not unit or not net or not flags then return nil end
    if id == 0 and unit == 0 and net == 0 then return nil end
    return { address = a, resource = b:sub(1, 8), id = id, unit = unit,
             net = net, flags = flags }
end

-- The unit registry lives in the EXE, not in game.dll, and a unit handle is
-- index + 0x400000 * generation rather than a plain index.  Both of those are
-- what the reference uses.
local function bone(unit, node)
    if not exe_base or type(unit) ~= 'number' or type(node) ~= 'number' then return nil end
    if node < 0 or node >= 1024 then return nil end
    local reg = ptr8(exe_base + EXE_UNIT_REGISTRY)
    if not reg then return nil end
    local index = unit % 0x400000
    local generation = math.floor(unit / 0x400000) % 256
    local cb = rd(reg + 0x98, 4)
    if not cb then return nil end
    local count = u32(cb, 0)
    if not count or count > 0x400000 or index >= count then return nil end
    local ga = ptr8(reg + 0xa0)
    if not ga then return nil end
    local gb = rd(ga + index, 1)
    if not gb or gb:byte(1) ~= generation then return nil end
    local oa = ptr8(reg + 0x88)
    if not oa then return nil end
    local object = ptr8(oa + 8 * index)
    if not object then return nil end
    local ib = rd(object + 8, 4)
    if not ib or u32(ib, 0) ~= unit then return nil end
    local bb = rd(object + 0x70, 4)
    if not bb then return nil end
    local bones = u32(bb, 0)
    if not bones or bones < 1 or bones > 1024 or node >= bones then return nil end
    local ba = ptr8(object + 0x88)
    if not ba then return nil end
    local b = rd(ba + node * 64, 64)
    if not b then return nil end
    local x, y, z = f32b(b, 48), f32b(b, 52), f32b(b, 56)
    if not (finite(x) and finite(y) and finite(z)) then return nil end
    local fx, fy, fz = f32b(b, 16), f32b(b, 20), f32b(b, 24)
    if not (finite(fx) and finite(fy) and finite(fz)) then return x, y, z end
    return x, y, z, fx, fy, fz
end

local function pose_of(wid, unit)
    if not wid then return nil end
    local wd = ptr8(base + R.pose)
    if not wd then return nil end
    local _, _, wi = slot(wd + 48, wid, 32768)
    if not wi or wi >= 16384 then return nil end
    local arr = ptr8(wd + 88)
    if not arr then return nil end
    local wb = rd(arr + 1008 * wi, 228)
    if not wb then return nil end
    local count, index = u32(wb, 216), u32(wb, 220)
    if not count or not index or count < 1 or count > 24 or index >= count then return nil end
    local node = u32(wb, 120 + 4 * index)
    if not node then return nil end
    local x, y, z, fx, fy, fz = bone(unit, node)
    if not x then return nil end
    local pose = { origin = { x, y, z }, forward = { 0, 0, 1 }, valid = false }
    if fx then
        local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
        if fl >= 0.5 and fl <= 1.5 then
            pose.forward = { fx, fy, fz }
            pose.valid = true
        end
    end
    return pose
end

local function resource_row(want)
    local em = ctx.em
    if not em then return nil, nil end
    want = want or STIM_B
    local tb = ptr8(em + SET_TBL_OFF)
    if not tb then return nil, nil end
    for first = 0, SET_ENTRIES - 1, 512 do
        local cnt = math.min(512, SET_ENTRIES - first)
        local rows = rd(tb + 16 * first, 16 * cnt)
        if rows then
            for k = 0, cnt - 1 do
                if rows:sub(k * 16 + 1, k * 16 + 8) == want then
                    local idx = u32(rows, k * 16 + 8)
                    if idx and idx < 272 then
                        local addr = tb + SET_ROW_OFF + ROW_SIZE * idx
                        local row = rd(addr, ROW_SIZE)
                        if row then return addr, row end
                    end
                end
            end
        end
    end
    return nil, nil
end

-- ---------------------------------------------------------------- lease
-- A PRIVATE per-weapon settings row, copied from the shared resource row.
--
-- The resource row `resource_row()` finds is the game's own definition of the
-- P-11: every P-11 THIS PROCESS reads, including a shot this machine simulates
-- for somebody else.  Writing the seeker into +0x28 of that row therefore
-- changes the weapon definition rather than this player's instance of it.
--
-- (The `SEAF's Stim Pistol` the resource workbook lists is NOT affected:
-- ProjectileCompositionCapabilities.json gives it its own settings record, so it
-- is a separate consumer of projectile 318 rather than a reader of this row.)
--
-- And the effect is REPLICATED even though the write is local: the spawned
-- entity travels to the other machines, which must already have its package
-- resident (docs/support-weapon-api.md:372-374).
--
-- Guided Rounds solves this by cloning: it copies the resource row into a free
-- slot of the weapon manager's settings array and registers that slot in the
-- forward (weapon id -> slot) and reverse (slot -> weapon id) maps.  Only the
-- private copy is then edited, and only eight bytes of it (`+40`).
--
-- The maps and arrays (all offsets from the reference, unchanged):
--   +0x30 capacity   +0x90 forward map   +0xb0 reverse map
--   +0xc8 count      +0xd0 row array     rows are ROW_SIZE bytes
local WSET = {}

local function resolve_settings(wid, res, txt)
    if not ctx.wm or not wid then return nil, nil, 'no_weapon' end
    -- already created for this weapon instance?  (the game recycles slots, so a
    -- cached address is re-read rather than trusted blind)
    local rec = WSET[wid]
    if rec then
        local row = rd(rec.addr, ROW_SIZE)
        if row and f32(row, 8) and f32(row, 8) > 0 and f32(row, 8) < 5000 then
            return rec.addr, row, rec.kind
        end
        WSET[wid] = nil
    end
    local data = ptr8(ctx.wm + 0xd0)
    if not data then return nil, nil, 'settings_array_missing' end
    local count_b, cap_b = rd(ctx.wm + 0xc8, 4), rd(ctx.wm + 0x30, 4)
    if not count_b or not cap_b then return nil, nil, 'settings_count_unreadable' end
    local count, scap = u32(count_b, 0), u32(cap_b, 0)
    if not count or not scap or scap < 1 or scap > 4096 or count > scap then
        return nil, nil, 'settings_bounds'
    end
    local faddr, fbytes, findex, fcap = slot(ctx.wm + 0x90, wid, 8192)
    if findex then
        local addr = data + ROW_SIZE * findex
        local row = rd(addr, ROW_SIZE)
        if row then
            WSET[wid] = { addr = addr, kind = 'instance' }
            return addr, row, 'instance'
        end
    end
    if not faddr or not fbytes then return nil, nil, 'forward_map_unavailable' end
    if count >= scap then return nil, nil, 'settings_full' end
    local _, rrow = resource_row(res)
    if not rrow then return nil, nil, 'resource_row_missing' end
    -- the row was found by the weapon's own resource hash, so a sane
    -- rounds-per-minute is enough to trust it (the reference's old "rpm must be
    -- 400" test was APW-1 specific)
    local rpm = f32(rrow, 8)
    if not rpm or rpm <= 0 or rpm >= 5000 then return nil, nil, 'resource_row_rpm_bad' end
    -- a weapon with an ALTERNATE fire mode keeps the index of its second row at
    -- +576; copying such a row would take both fire modes with it
    if u32(rrow, 576) ~= 0 then return nil, nil, 'alternate_settings_not_zero' end
    local addr = data + ROW_SIZE * count
    if not rd(addr, ROW_SIZE) then return nil, nil, 'slot_unreadable' end
    local raddr2, rbytes = slot(ctx.wm + 0xb0, count, 8192)
    if not raddr2 or not rbytes then return nil, nil, 'reverse_map_unavailable' end
    if u32(rbytes, 0) == count then return nil, nil, 'reverse_slot_occupied' end
    if fcap and (count + 1) * 2 >= fcap then return nil, nil, 'map_load_limit' end
    if not write_bytes(addr, rrow) then return nil, nil, 'copy_failed' end
    if not write_bytes(raddr2, word(count) .. word(wid)) then return nil, nil, 'reverse_write_failed' end
    if not write_bytes(ctx.wm + 0xc8, word(count + 1)) then return nil, nil, 'count_write_failed' end
    if not write_bytes(faddr, word(wid) .. word(count)) then return nil, nil, 'forward_write_failed' end
    local row = rd(addr, ROW_SIZE)
    if not row then return nil, nil, 'created_row_unreadable' end
    WSET[wid] = { addr = addr, kind = 'created' }
    log(('SETTINGS made a private row for %s at %s (slot %d, rpm=%.0f) - the SHARED '
        .. 'resource row is never written'):format(tostring(txt), hexa(addr), count, rpm))
    return addr, row, 'created'
end

-- Take or give back the lease: eight bytes at +40 of THIS weapon's private row.
--
-- On is true:  +40 = the P-92 Warrant projectile entity (that is what makes the
--              round carry a TargetLock seeker).
-- On is false: +40 = 0, the shipped value.
-- Anything already at +40 that is neither is somebody else's and is left alone.
function lease(on, wid, res, txt)
    wid = wid or ctx.weapon_id
    res = res or ctx.weapon_res
    txt = txt or ctx.weapon_txt
    if not wid then return false, 'no_weapon' end
    local addr, row, kind = resolve_settings(wid, res, txt)
    if not addr then
        if state.lease_warned ~= kind then
            state.lease_warned = kind
            log(('LEASE cannot take a private row for %s (%s) - this weapon keeps its '
                .. 'own settings and is left alone'):format(tostring(txt), tostring(kind)))
        end
        return false, kind
    end
    local cur = row:sub(41, 48)
    if on then
        if cur == LEASE.bytes then state.leased = true; return true end
        if cur ~= ZERO8 then
            log(('LEASE %s +40 already holds %s - another mod owns it, not touching it')
                :format(tostring(txt), hexs(cur)))
            return false, 'owned_by_other'
        end
        if write_bytes(addr + 40, LEASE.bytes) then
            state.leased = true
            log(('LEASE ok %s (id=%s) row=%s kind=%s  +40 -> %s')
                :format(tostring(txt), tostring(wid), hexa(addr), tostring(kind), LEASE.txt))
            return true
        end
        log('LEASE failed at ' .. hexa(addr + 40))
        return false, 'write_failed'
    end
    if cur == ZERO8 then state.leased = false; return true end
    if cur ~= LEASE.bytes then return false, 'not_ours' end
    if write_bytes(addr + 40, ZERO8) then
        state.leased = false
        log(('RESTORE %s row=%s  +40 -> 0'):format(tostring(txt), hexa(addr)))
        return true
    end
    return false, 'write_failed'
end

-- ---------------------------------------------------------------- avatar
local function resolve_avatar()
    local pm = ptr8(base + R.player)
    if not pm then return false, 'no_player_manager' end
    local ar = u32(rd(pm + 0x3a8, 4) or '', 0)
    if not ar or ar == 0 or ar == 0xffffffff then return false, 'no_avatar_ref' end
    local em = ptr8(base + R.entity)
    if not em then return false, 'no_entity_manager' end
    ctx.em = em
    local _, _, ei = slot(em + 0xf22ec8, ar, 1048576)
    if not ei then return false, 'avatar_not_registered' end
    if ei >= 262144 then return false, 'avatar_index_out_of_range' end
    local av = entity(em + 0xf32f18 + 24 * ei)
    if not av then return false, 'avatar_unreadable' end
    if av.net ~= ar or av.flags % 4 ~= 1 then return false, 'avatar_not_local' end
    ctx.avatar_id = av.id
    -- Also kept for the wielder lookup: that manager's hash is keyed by an
    -- entity, and the SDK's description does not say WHICH identity of the
    -- wielder it uses, so the lookup tries all three rather than betting on one.
    ctx.avatar_net, ctx.avatar_unit = av.net, av.unit
    -- The local avatar's OWN entity resource is the reference for every other
    -- Helldiver, so no external hash list is needed and no game update can
    -- stale it.
    ctx.avatar_resource = av.resource
    local fm = ptr8(base + R.faction)
    if fm then
        ctx.fm = fm
        local _, _, fi = slot(fm + 0x12050, av.id, 131072)
        if fi and fi < 16384 then
            local ma = ptr8(fm + 0x12078)
            if ma then ctx.self_mask = u32(rd(ma + 4 * fi, 4) or '', 0) end
        end
    end
    return true
end

local function faction_of(id)
    if not ctx.fm then return nil, nil end
    local _, _, fi = slot(ctx.fm + 0x12050, id, 131072)
    if not fi or fi >= 16384 then return nil, nil end
    local ma, ca = ptr8(ctx.fm + 0x12078), ptr8(ctx.fm + 0x12070)
    if not ma or not ca then return nil, nil end
    return u32(rd(ma + 4 * fi, 4) or '', 0), u32(rd(ca + 96 * fi, 4) or '', 0)
end

local function whitelisted(res)
    if res == STIM_B then return STIM_HEX end
    return nil
end

-- ---------------------------------------------------------------- held weapon
local function collect_held(am, pa, total)
    local parent_base = ptr8(am + 0x40)
    local held = {}
    for n = 0, total - 1 do
        local obj = u64(pa, 8 * n)
        if obj and obj >= 65536 and obj < 0x800000000000 then
            local w = entity(obj)
            local hit = w and whitelisted(w.resource)
            if hit and w.flags % 4 == 1 then
                local _, _, ai = slot(am + 0x20, w.id, 32768)
                if ai and ai < 16384 and parent_base then
                    local att = rd(parent_base + 48 * ai, 20)
                    if att and u32(att, 4) == ctx.avatar_id then
                        local dup = false
                        for _, h in ipairs(held) do
                            if h.id == w.id then dup = true; break end
                        end
                        if not dup then
                            held[#held + 1] = { id = w.id, unit = w.unit,
                                                res = w.resource, txt = hit }
                        end
                    end
                end
            end
        end
    end
    return held
end

local function apply_held(held)
    if #held == 0 then
        if ctx.held then log('WEAPON the P-11 is no longer carried') end
        ctx.held = held
        ctx.weapon_id, ctx.weapon_unit = nil, nil
        ctx.weapon_res, ctx.weapon_txt = nil, nil
        return false, 'stim_not_in_hands'
    end
    local changed = (not ctx.held) or (#ctx.held ~= #held)
    if not changed then
        for i, h in ipairs(held) do
            if ctx.held[i].id ~= h.id then changed = true; break end
        end
    end
    if changed then
        for _, h in ipairs(held) do
            log('WEAPON carried: ' .. tostring(h.txt) .. ' id=' .. tostring(h.id))
        end
    end
    ctx.held = held
    ctx.weapon_id, ctx.weapon_unit = held[1].id, held[1].unit
    ctx.weapon_res, ctx.weapon_txt = held[1].res, held[1].txt
    return true
end

-- The entity IN HAND, or nil when that cannot be determined.
--
-- 0 means "nothing is held" (the game writes 0 on unwield); a non-zero u32 is the
-- entity id of the item in hand.  Returns nil only when the manager or the hash
-- cannot be read, which the caller treats as "unknown" and falls back on.
local function find_stim_weapon()
    local wm = ptr8(base + R.weapon)
    if not wm then return false, 'no_weapon_manager' end
    ctx.wm = wm
    local am = ptr8(base + R.attach)
    if not am then return false, 'no_attachment_manager' end
    ctx.am = am
    local nb = rd(wm + 0x38, 4)
    if not nb then return false, 'weapon_count_unreadable' end
    local total = u32(nb, 0)
    if not total or total < 1 then return false, 'no_weapons' end
    if total > 1024 then total = 1024 end
    local we = ptr8(wm + 0x68)
    if not we then return false, 'no_weapon_array' end
    local pa = rd(we, 8 * total)
    if not pa then return false, 'weapon_array_unreadable' end
    return apply_held(collect_held(am, pa, total))
end

local function weapon_pose()
    if not ctx.weapon_id then return false, 'no_weapon' end
    local pose = (ctx.held and #ctx.held > 1) and ctx.aim_pose or nil
    if not pose then pose = pose_of(ctx.weapon_id, ctx.weapon_unit) end
    if not pose then return false, 'muzzle_pose_unavailable' end
    ctx.origin, ctx.forward, ctx.forward_valid = pose.origin, pose.forward, pose.valid
    if not ctx.forward_valid and ctx.warned_forward ~= true then
        ctx.warned_forward = true
        log('NOTE muzzle bone carries no usable forward vector - using the '
            .. 'nearest candidate instead of a cone')
    end
    return true
end

-- ---------------------------------------------------------------- seeking
local PUBLISH_PREFIX = '\x48\x8B\xC4\x48\x89\x58\x10'
local PUBLISH_OK = (rd(base + R.publish, #PUBLISH_PREFIX) == PUBLISH_PREFIX)
if not PUBLISH_OK then
    log('WARNING: publish signature at game.dll+0xFD97E0 does not match - binding disabled')
end
local PUBLISH = ffi.cast('void (*)(uint32_t, uint32_t, const void *)', base + R.publish)
local pub_buffers = {}
local function publish(net, field, value)
    if not PUBLISH_OK then return false end
    if type(net) ~= 'number' or net == UNBOUND then return false end
    if #pub_buffers >= 8192 then table.remove(pub_buffers, 1) end
    local b = ffi.new('uint32_t[1]', math.floor(value) % 4294967296)
    pub_buffers[#pub_buffers + 1] = b
    return pcall(function() PUBLISH(net, field, b) end)
end

-- ---------------------------------------------------------------- aiming
-- Is this candidate a FRIENDLY Helldiver?  The local avatar's own entity type
-- decides, so no hash list is involved and it cannot go stale.
local function is_helldiver(e)
    if not ctx.avatar_resource then return false end
    if e.id == ctx.avatar_id then return false end
    if e.resource ~= ctx.avatar_resource then return false end
    local mask = faction_of(e.id)
    if mask and ctx.self_mask then
        -- friendly means it shares our faction mask; an unknown mask is accepted
        -- because the entity resource already matched the local avatar's own
        return intersects(mask, ctx.self_mask)
    end
    return true
end

local function is_seaf(e)
    return SEAF[e.resource] ~= nil
end

-- ---------------------------------------------------------------- LOS
local LOS = (function()
    local fn
    local okbind = pcall(function()
        if not exe_base then return end
        local want = ('488bc44889581048897018574883ec708bd9')
            :gsub('..', function(x) return string.char(tonumber(x, 16)) end)
        local gotb = rd(exe_base + 0x77DEC0, #want)
        if gotb ~= want then
            log('LOS raycast signature does not match at exe_base+0x77DEC0')
            return
        end
        fn = ffi.cast('uint32_t (*)(uint32_t, const float *, const float *,'
            .. ' float, uint32_t, void *, uint32_t)', exe_base + 0x77DEC0)
        log(('LOS raycast bound at exe_base+0x77DEC0 (game.dll 0x%X)')
            :format(base or 0))
    end)
    if not okbind or fn == nil then return nil end
    -- 16384, the size the reference probe uses: a buffer sized from maxhits is
    -- too small, because the engine writes its records past the first 1728.
    local MAXHITS, OUT = 8, 16384
    local out = ffi.new('uint8_t[' .. OUT .. ']')
    local o = ffi.new('float[3]')
    local d = ffi.new('float[3]')
    local api = { calls = 0, rays = 0, refused = 0 }
    local SKIP = 0x800000
    local function limited(n)
        return type(n) == 'number' and n == n and n <= 1e7 and n >= -1e7
    end
    function api.ray(desc, ox, oy, oz, dx, dy, dz, dist)
        if not (limited(ox) and limited(oy) and limited(oz) and limited(dx)
            and limited(dy) and limited(dz) and limited(dist)) then
            api.refused = api.refused + 1
            return 0, nil, nil
        end
        o[0], o[1], o[2] = ox, oy, oz
        d[0], d[1], d[2] = dx, dy, dz
        ffi.fill(out, OUT, 0)
        api.rays = api.rays + 1
        local hits = tonumber(fn(desc or 0, o, d, dist, 0xFFFFFFFF, out, MAXHITS)) or 0
        if hits == 0 then return 0, nil, nil end
        local p = ffi.cast('uint8_t *', out)
        for i = 0, hits - 1 do
            local rec = p + i * 44
            local flags = ffi.cast('uint32_t *', rec + 32)[0]
            -- leaves stop sight but not a bullet
            local passable = cfg.los_foliage == 1 and flags % 0x1000000 >= SKIP
            if not passable then
                return hits, ffi.cast('float *', rec + 24)[0],
                    ffi.cast('uint32_t *', rec + 28)[0]
            end
        end
        return hits, nil, nil
    end
    function api.trace(tag, desc, ox, oy, oz, dx, dy, dz, dist)
        if not (limited(ox) and limited(oy) and limited(oz) and limited(dx)
            and limited(dy) and limited(dz) and limited(dist)) then return end
        o[0], o[1], o[2] = ox, oy, oz
        d[0], d[1], d[2] = dx, dy, dz
        ffi.fill(out, OUT, 0)
        local hits = tonumber(fn(desc or 0, o, d, dist, 0xFFFFFFFF, out, MAXHITS)) or 0
        local p = ffi.cast('uint8_t *', out)
        local n = hits
        if n > 8 then n = 8 end
        for i = 0, n - 1 do
            local rec = p + i * 44
            local flags = ffi.cast('uint32_t *', rec + 32)[0]
            local skipped = cfg.los_foliage == 1 and flags % 0x1000000 >= SKIP
            log(('LOS %s %d/%d dist=%.1f flags=0x%X mat=0x%X unit=%d %s')
                :format(tag, i + 1, hits, ffi.cast('float *', rec + 24)[0],
                    flags, ffi.cast('uint32_t *', rec + 36)[0],
                    ffi.cast('uint32_t *', rec + 28)[0],
                    skipped and 'SKIPPED-AS-FOLIAGE' or 'counts-as-cover'))
        end
    end

    -- At most this many rays per frame.  best_for walks every candidate, and it
    -- is called several times a frame, so without a ceiling a busy frame would
    -- hand the physics engine hundreds of queries.  When the budget runs out the
    -- test fails OPEN (returns "not blocked"), so a heavy frame can never make
    -- the mod refuse to lock anything at all.
    local PER_FRAME = 64
    local budget_frame, budget_left = -1, 0
    function api.blocked(desc, fx, fy, fz, tx, ty, tz)
        api.calls = api.calls + 1
        if not (limited(fx) and limited(fy) and limited(fz)
            and limited(tx) and limited(ty) and limited(tz)) then
            api.refused = api.refused + 1
            return false
        end
        if budget_frame ~= state.frame then
            budget_frame, budget_left = state.frame, PER_FRAME
        end
        if budget_left <= 0 then return false end
        budget_left = budget_left - 1
        local dx, dy, dz = tx - fx, ty - fy, tz - fz
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        -- written so nan falls through to the refusal, unlike a
        -- `dist < 1 or dist > 400` guard, which nan passes
        if not (dist >= 1.0 and dist <= 400) then return false end
        local hits, hitd = api.ray(desc, fx, fy, fz, dx / dist, dy / dist, dz / dist, dist)
        if hits == 0 or hitd == nil or not finite(hitd) then return false end
        return hitd < dist - 0.5
    end
    return api
end)()

-- true when something solid sits between the muzzle and the unit.  Returns
-- false (NOT blocked) when the cover test is switched off or unavailable, which
-- is the fail-open behaviour the reference relies on: a missing raycast module
-- must never make the mod refuse to lock everything.
--
-- The caller passes the MUZZLE as the origin (the reference's P14 fix): the cone
-- and the ranking use the camera axis so the ring and the marker agree, but the
-- sight test has to start where the round starts - in third person the camera is
-- metres behind and above the muzzle, so a camera ray never sees the bush the
-- bullet actually hits.
local function blocked(ox, oy, oz, tx, ty, tz)
    if cfg.los_check ~= 1 or not LOS then return false end
    return LOS.blocked(cfg.los_desc, ox, oy, oz, tx, ty, tz)
end

-- ---------------------------------------------------------------- targets
-- Score a candidate for the priority order.  Lower is better.
--   tier 1 = wounded Helldiver
--   tier 2 = full-health Helldiver
--   tier 3 = wounded SEAF
--   tier 4 = full-health SEAF
local PRIO_NAME = { 'wounded Helldiver', 'Helldiver', 'wounded SEAF', 'SEAF' }
local function tier_of(is_hd, hurt)
    if is_hd then return hurt and 1 or 2 end
    return hurt and 3 or 4
end

local function scan_targets()
    local hm = ptr8(base + R.health)
    if not hm then return false, 'no_health_manager' end
    -- The candidate block hangs off the health manager at +0x1008; the header is
    -- then at +8 and the list count is its +12.  Reading the header straight off
    -- the manager (an earlier draft did) yields a garbage count.
    hm = hm + 0x1008
    ctx.hm = hm
    local hh = rd(hm + 8, 16)
    if not hh then return false, 'health_header_unreadable' end
    local hcount = u32(hh, 12)
    if not hcount or hcount < 1 then return false, 'no_entities' end
    if hcount > 1024 then hcount = 1024 end
    local he, hd, hn = ptr8(hm + 0x40), ptr8(hm + 0x50), ptr8(hm + 0x58)
    if not he or not hd or not hn then return false, 'health_arrays_missing' end
    local pa = rd(he, 8 * hcount)
    if not pa then return false, 'health_array_unreadable' end
    local list = {}
    -- DIAGNOSTIC CENSUS (debug=1 only).
    --
    -- "Other players cannot be locked" is not answerable from the outside: the
    -- unit may never reach the list, or it may be filtered by the faction mask,
    -- the health gate or the bone read, and every one of those looks identical
    -- in game.  So the scan counts where each live entity is lost and prints the
    -- resource hashes it saw, which makes the actual gate visible instead of
    -- guessed at.  The `rej` table is the interesting one: a player avatar whose
    -- entity RESOURCE differs from the local avatar's shows up here as a hash
    -- repeating once per scan.
    -- ALWAYS collected, not just under debug: this is the only thing that says
    -- WHICH entity type was refused at WHICH gate, and "some units do not lock"
    -- is not answerable without it.  It is a handful of counters per scan, and
    -- the report below is rate-limited to one line every ten seconds.
    local census = { seen = 0, live = 0, ident = 0, health = 0, faction = 0,
                     bone = 0, hd = 0, seaf = 0, idrej = {} }
    local rej = {}
    for n = 0, hcount - 1 do
        local obj = u64(pa, 8 * n)
        if obj and obj >= 65536 and obj < 0x800000000000 then
            local e = entity(obj)
            -- NOTE the flags test that is deliberately NOT here.
            --
            -- `flags % 4 == 1` (descriptor flag bit 0) means "owned by THIS
            -- peer" - the reference uses it for the local avatar ("avatar_not_local")
            -- and for weapons and seeking entities, which really must be ours.
            -- An earlier build of this addon copied it into the CANDIDATE scan,
            -- where it is simply wrong: it keeps only entities this machine
            -- simulates, which is exactly why other players could never be
            -- locked (their avatars are not ours) while enemies in a solo game
            -- still were.  The reference's own target scan has no such test.
            census.seen = census.seen + 1
            if e and e.id ~= ctx.avatar_id and e.net ~= UNBOUND then
                census.live = census.live + 1
                -- STAGE 1 - identity.  Two independent admissions, never the
                -- faction mask on its own: sentries, emplacements and exosuits
                -- share our mask too, so a mask test would happily lock a turret.
                --   * a Helldiver, recognised by the local avatar's OWN entity
                --     type (no hash table, cannot go stale)
                --   * a SEAF NPC, by resource hash from the community workbook
                local is_hd = is_helldiver(e)
                local seaf_name = (not is_hd) and SEAF[e.resource] or nil
                if not (is_hd or seaf_name) then
                    -- Rejected at the IDENTITY gate.  This histogram is the one
                    -- that answers "is a remote player's avatar in this list at
                    -- all, under an entity type that differs from the local
                    -- avatar's?" - it prints the hashes of everything we refused
                    -- for not being the P-11's idea of a Helldiver or a SEAF.
                    local k = hexs(e.resource)
                    census.idrej[k] = (census.idrej[k] or 0) + 1
                end
                if is_hd or seaf_name then
                    census.ident = census.ident + 1
                    if is_hd then census.hd = census.hd + 1 else census.seaf = census.seaf + 1 end
                    local hpb = rd(hd + 440 * n + 20, 4)
                    local mxb = rd(hn + 28 * n + 20, 4)
                    local stb = rd(hd + 440 * n + 412, 4)
                    if hpb and mxb and stb then
                        local hp, mx, st = i32(hpb, 0), i32(mxb, 0), u32(stb, 0)
                        if hp and mx and st and hp > 0 and mx > 0 and hp <= mx and st == 0 then
                            census.health = census.health + 1
                            local hurt = hp < mx
                            -- NEW: "ignore full health" is a FILTER here at the
                            -- health gate, not a scoring term: a unit at full
                            -- health simply never becomes a candidate, so it can
                            -- never be picked as a last resort either.
                            if not (cfg.ignore_full == 1 and not hurt) then
                                local mask, pose_node = faction_of(e.id)
                                -- STAGE 2 - faction, as an independent second
                                -- opinion.  For a SEAF a nil mask is a REJECT (the
                                -- hash list is the only thing vouching for it);
                                -- for a Helldiver it is accepted, because the
                                -- resource already matched the avatar's own.
                                -- A missing faction row is NOT evidence of
                                -- hostility: `faction_of` misses while a unit is
                                -- not yet in the faction map, so rejecting on it
                                -- threw away good SEAF.  The whitelist is the
                                -- identity test; the mask only confirms.
                                local accepted = true
                                if mask and ctx.self_mask then
                                    accepted = intersects(mask, ctx.self_mask)
                                end
                                if accepted then
                                    census.faction = census.faction + 1
                                elseif rej then
                                    local why = (not mask) and 'no_faction_row' or 'mask_mismatch'
                                    rej[why] = (rej[why] or 0) + 1
                                    if not mask then
                                        local k = 'res:' .. hexs(e.resource)
                                        rej[k] = (rej[k] or 0) + 1
                                    end
                                end
                                if accepted and pose_node and pose_node < 1024 then
                                    local x, y, z = bone(e.unit, pose_node)
                                    if not x and pose_node ~= 0 then
                                        x, y, z = bone(e.unit, 0)
                                    end
                                    if x then
                                        census.bone = census.bone + 1
                                        list[#list + 1] = {
                                            id = e.id, net = e.net, unit = e.unit,
                                            name = is_hd and 'Helldiver' or seaf_name,
                                            position = { x, y, z },
                                            res = e.resource,
                                            node = pose_node,
                                            hp = hp, mx = mx, hurt = hurt,
                                            helldiver = is_hd,
                                        }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    ctx.targets = list
    -- The report.  Every ten seconds, always - not gated on debug - because the
    -- question it answers ("which unit could not be locked, and why") is the one
    -- that keeps coming back, and a cfg with debug=0 used to make it unanswerable.
    -- The first three prints are unconditional so a short session still yields
    -- the answer; after that it is one line per ten seconds.
    ctx.census_n = (ctx.census_n or 0) + 1
    if ctx.census_n <= 3 or (state.frame % 600) == 0 then
        local parts = {}
        for k, v in pairs(rej) do parts[#parts + 1] = k .. '=' .. v end
        table.sort(parts)
        log(('SCAN seen=%d live=%d -> identity=%d (helldiver=%d seaf=%d) -> health=%d '
            .. '-> faction=%d -> usable=%d | refused: %s')
            :format(census.seen, census.live, census.ident, census.hd, census.seaf,
                census.health, census.faction, census.bone,
                #parts > 0 and table.concat(parts, ' ') or 'none'))
        log(('SCAN local avatar resource=%s self_mask=%s | candidates=%d | seek active=%s '
            .. 'bound(period)=%d')
            :format(hexs(ctx.avatar_resource), tostring(ctx.self_mask), #list,
                tostring(ctx.seek_active), (state.binds or 0) - (state.binds_mark or 0)))
        state.binds_mark = state.binds or 0
        -- the entity types the IDENTITY gate refused, most common first: an
        -- un-lockable SEAF shows up here as its own hash repeating
        local ir = {}
        for k, v in pairs(census.idrej) do ir[#ir + 1] = { k, v } end
        table.sort(ir, function(a, b) return a[2] > b[2] end)
        local top = {}
        for i = 1, math.min(#ir, 8) do
            top[#top + 1] = ('%s x%d'):format(ir[i][1], ir[i][2])
        end
        if #top > 0 then
            log('SCAN not-admitted entity types: ' .. table.concat(top, ' '))
        end
    end
    return true
end

-- Rank every candidate against ONE aim axis and return the best.
--
-- The scoring is Guided Rounds v1.8.0's, with the friendly priority folded in:
--
--   * TIER carries a factor of a million, exactly the way the reference makes
--     MAX HEALTH dominate there.  Wounded Helldiver (1) > Helldiver (2) >
--     wounded SEAF (3) > SEAF (4), so the tier decides on its own and the aim
--     angle only ever breaks a tie INSIDE one tier.
--   * Inside a tier, (1 - cos) keeps the reference's shape: the unit closest to
--     the aim axis wins, with distance as a far weaker tiebreak.
--
-- The cone is tested with a cos limit rather than acos, and the SIGHT TEST
-- starts at the MUZZLE (ctx.origin) even though the cone and the ranking use
-- the camera axis.  That split is the reference's P14 fix and it matters: in
-- third person the camera sits metres behind and above the muzzle, so a camera
-- ray never sees the bush the bullet actually hits.
local function best_for(o, f, valid, want)
    if not o or not f then return nil end
    local cone = (valid == true)
    local fl = math.sqrt(f[1] * f[1] + f[2] * f[2] + f[3] * f[3])
    if fl < 0.5 or fl > 1.5 then cone = false end
    -- cone_deg 0 means "no cone", which is how the reference treats a disabled
    -- ring: everything inside max_dist is a candidate.
    local cos_limit = (cfg.cone_deg <= 0) and -1 or math.cos(math.rad(cfg.cone_deg))
    local best, best_score
    local acc
    if want and want > 1 then acc = {} end
    for _, c in ipairs(ctx.targets) do
        local p = c.position
        local dx, dy, dz = p[1] - o[1], p[2] - o[2], p[3] - o[3]
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if dist >= 0.01 and dist <= cfg.max_dist then
            local score
            if cone then
                local cos = (dx * f[1] + dy * f[2] + dz * f[3]) / (dist * fl)
                if cos >= cos_limit then
                    local tier = tier_of(c.helldiver, c.hurt)
                    -- tier dominates; (1-cos) is 0..2 and dist/1000 is tiny
                    score = tier * 1000000 + (1 - cos) * 1000 + dist / 1000
                end
            else
                local tier = tier_of(c.helldiver, c.hurt)
                score = tier * 1000000 + dist / 1000
            end
            -- the sight test runs from the muzzle, not from the cone's apex
            local sx, sy, sz = o[1], o[2], o[3]
            if ctx.origin then
                sx, sy, sz = ctx.origin[1], ctx.origin[2], ctx.origin[3]
            end
            if score and not blocked(sx, sy, sz, p[1], p[2], p[3]) then
                if acc then acc[#acc + 1] = { c = c, s = score }
                elseif (not best_score or score < best_score) then
                    best, best_score = c, score
                end
            end
        end
    end
    if not acc then return best end
    table.sort(acc, function(p, q) return p.s < q.s end)
    local out = {}
    for i = 1, math.min(#acc, want) do out[i] = acc[i].c end
    return out[1], out
end

-- ---------------------------------------------------------------- binding
local function aim_axis()
    -- Prefer the camera axis (what the crosshair and the range ring use).  The
    -- reference found that the muzzle axis and the camera axis differ by about
    -- 5 degrees in third person - wider than a narrow whole cone - which put
    -- markers on one unit and rounds into another.  One axis for both.
    if ctx.cam_origin and ctx.cam_forward then
        return ctx.cam_origin, ctx.cam_forward
    end
    if ctx.origin and ctx.forward then return ctx.origin, ctx.forward end
    return nil, nil
end

local function pick_target()
    local o, f = aim_axis()
    if not o or not f then return nil end
    -- `valid` is what tells best_for whether it may build a cone at all: the
    -- camera pose is always a unit forward, the muzzle bone may not be.  Pass
    -- the vector itself, not a normalised copy - best_for checks its length to
    -- decide, exactly as the reference does.
    local valid = true
    if o == ctx.origin then valid = (ctx.forward_valid == true) end
    local best = best_for(o, f, valid)
    if not best and cfg.cone_fallback == 1 then
        best = best_for(o, f, false)
    end
    return best
end

local function bind_projectiles()
    local sm = ptr8(base + R.seeking)
    if not sm then return false, 'no_seeking_manager' end
    local h = rd(sm, 24)
    if not h then return false, 'seeking_header_unreadable' end
    local count, active, authority = u32(h, 8), u32(h, 12), u32(h, 16)
    if not count or not active or not authority then return false, 'seeking_counts_unreadable' end
    -- THE host/client diagnostic.
    --
    -- Every write this addon makes is to its OWN process, so taking the lease needs
    -- no host authority: the weapon row it leases and the seeking manager it binds
    -- are this machine's copies, and the SDK confirms each machine simulates its
    -- own copy of its own shots and that the FIRING machine's hit is the one that
    -- damages.  (That says nothing about what OTHER machines then render: the
    -- spawned entity is replicated, so they need its package themselves.)  The one thing that could still make a CLIENT fail is this header's
    -- `authority` field at +16, which the reference reads and then only ever
    -- prints - it never gates on it.  If guidance turns out to be driven by the
    -- authority peer rather than locally, a client's target write would be
    -- ignored, and this line is how that becomes visible instead of mysterious.
    ctx.seek_authority = authority
    ctx.seek_active = active
    if active < 1 or count < 1 then return true end
    local limit = active
    if limit > 128 then limit = 128 end
    local entries, runtime, net = ptr8(sm + 0x38), ptr8(sm + 0x48), ptr8(sm + 0x50)
    if not entries or not runtime or not net then return false, 'seeking_arrays_missing' end
    local bulk = rd(runtime, 192 * limit)
    if not bulk then return false, 'seeking_runtime_unreadable' end
    local bound, natively_bound, not_ready, too_young = 0, 0, 0, 0
    local delay = tonumber(cfg.bind_delay) or 0.2
    local aim
    if cfg.lua_bind == 1 then aim = pick_target() end
    for i = 0, limit - 1 do
        local o = 192 * i
        local payload, age, src = u32(bulk, o + 0x34), f32(bulk, o + 0x24), u32(bulk, o + 0x84)
        if payload then
            -- "is this one of mine?" - the source weapon slot carries our own
            -- weapon id once the round is in the manager
            local mine = (ctx.weapon_id == nil) or (src == ctx.weapon_id)
            if mine then
                local nb = rd(net + 56 * i, 56)
                if nb then
                    local tgt = u32(nb, 0)
                    if tgt and tgt ~= UNBOUND and tgt ~= 0xffffffff then
                        natively_bound = natively_bound + 1
                    else
                        if aim and (age == nil or age >= delay) then
                            -- +0x36 is the "ready to be given a target" byte; a
                            -- round still being set up refuses the binding
                            if nb:byte(0x35 + 1) ~= 1 then
                                not_ready = not_ready + 1
                            else
                                local ep = u64(rd(entries + 8 * i, 8) or '', 0)
                                if ep and ep >= 65536 and ep < 0x800000000000 then
                                    local e = entity(ep)
                                    if e and e.resource == LEASE.bytes and e.flags % 4 == 1 then
                                        local addr = net + 56 * i
                                        local bytes = word(aim.net) .. word(GUIDANCE_NODE)
                                        if write_bytes(addr, bytes) then
                                            publish(e.net, FIELD_NODE, GUIDANCE_NODE)
                                            publish(e.net, FIELD_TARGET, aim.net)
                                            bound = bound + 1
                                            state.binds = state.binds + 1
                                            ctx.engine_lock_at = state.frame
                                            log(('BIND #%d -> %s (net=%u, %s, %.1f m, tier=%s)')
                                                :format(state.binds, tostring(aim.name),
                                                    aim.net,
                                                    aim.hurt and 'wounded' or 'full',
                                                    ctx.last_dist or -1,
                                                    PRIO_NAME[tier_of(aim.helldiver,
                                                        aim.hurt)] or '?'))
                                        else
                                            log('BIND failed to write target at ' .. hexa(addr))
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if cfg.debug == 1 and (bound + natively_bound + not_ready + too_young) > 0
        and (state.frame % 60) == 0 then
        log(('SEEK active=%d mine=%d bound=%d engine_bound=%d not_ready=%d too_young=%d '
            .. 'candidates=%d'):format(active, limit, bound, natively_bound, not_ready,
            too_young, #ctx.targets))
    end
    return true
end

-- PER FRAME.  Everything that decides whether the weapon is in hand, plus the
-- reticle's permission slip.
--
-- This runs every frame on purpose.  The reference splits its work the same way
-- and for the same reason: the lock UI refuses to draw unless `ctx.weapon_at`
-- was stamped within the last TWO frames, so stamping it only on the throttled
-- candidate scan would make the ring and the markers blink on 3 frames out of
-- every 20.  The expensive part (walking every entity and reading a bone) is
-- what gets throttled, in frame_step below - not this.
local function weapon_step()
    local ok = find_stim_weapon()
    if ok then
        -- the reticle's permission slip; stamped BEFORE the pose probe so a pose
        -- failure still leaves the ring and the markers up.
        --
        -- Stamped on "the P-11 is carried", exactly as the reference does.  The
        -- P-11 is a sidearm, so this stays true when it is holstered - that is
        -- fine and by design: the reticle's own `hand_guided` gate is what takes
        -- the lock UI down, and a box that somehow outlives it is caught by the
        -- target_at freshness stamp instead.  (An earlier build tried to decide
        -- "in hand" here from the wielder manager; that was aimed at the wrong
        -- cause and could hide a working reticle, so it is gone.)
        ctx.weapon_at = state.frame        -- which weapon types the lock UI may appear for.  The gate asks the
        -- runtime what is in hand and compares its type string against this set,
        -- which is what keeps the UI off every weapon except the P-11.  Both
        -- byte orders are listed because the runtime may print either.
        if not ctx.guided then
            local rev, fwd = {}, {}
            for i = 1, #STIM_B do
                rev[#rev + 1] = string.format('%02X', STIM_B:byte(#STIM_B + 1 - i))
                fwd[#fwd + 1] = string.format('%02X', STIM_B:byte(i))
            end
            ctx.guided = { [table.concat(rev)] = true, [table.concat(fwd)] = true }
        end
        -- (the muzzle pose was already probed while deciding in-hand above;
        -- probing it twice per frame would be wasted reads)
        -- a pose for every weapon carried: the UI module uses these to decide
        -- which weapon's muzzle the aim cone should start from when more than
        -- one is held
        ctx.pose = {}
        for _, h in ipairs(ctx.held or {}) do
            local pose = pose_of(h.id, h.unit)
            if pose then ctx.pose[h.id] = pose end
        end
        if not ctx.doc_seen then
            ctx.doc_seen = true
            log(('READY - P-11 Stim Pistol located (id=%s), guidance armed. '
                .. 'Locking FRIENDLY units: Helldivers then SEAF.'):format(tostring(ctx.weapon_id)))
        end
        lease(true, ctx.weapon_id, ctx.weapon_res, ctx.weapon_txt)
    else
        lease(false)
        ctx.doc_seen = nil
    end
    return ok
end

-- ============================================================================
-- The per-frame pipeline, and why it is split into three
-- ============================================================================
--   resolve_avatar()      EVERY FRAME.  The local avatar's entity id and type
--                         are the reference for every other Helldiver, and its
--                         faction mask is the second opinion on friendliness.
--                         A respawn changes them, so they cannot be cached once.
--   weapon_step()         EVERY FRAME.  Whether the P-11 is in hand, the lease,
--                         and the reticle's permission slip (`ctx.weapon_at`),
--                         which the UI module requires to be no older than two
--                         frames.  Throttling this is what made the ring and the
--                         markers blink out.
--   scan_targets()        THROTTLED to `target_interval` frames.  Walking every
--                         entity in the health list and reading a pose bone for
--                         each is the one genuinely expensive pass.  The locked
--                         target's own bone is re-read every frame afterwards,
--                         which is what keeps the marker on a moving unit.
local function frame_step()
    if not resolve_avatar() then return false end
    if cfg.avatar_note ~= ctx.avatar_resource then
        cfg.avatar_note = ctx.avatar_resource
        log(('AVATAR local entity type %s - every Helldiver is recognised by this')
            :format(hexs(ctx.avatar_resource)))
    end
    local in_hand = weapon_step()
    local every = tonumber(cfg.target_interval) or 20
    if every < 1 then every = 1 end
    if (state.frame % every) == 0 or not ctx.targets then
        scan_targets()
    end
    return in_hand
end

-- ---------------------------------------------------------------- ui
-- The reticle (range ring, lock markers, target box) and the camera pose that
-- feeds the acquisition cone.  Copied VERBATIM from Guided Rounds v1.8.0, where
-- all three are proven live.  It needs cfg.*, ctx.*, state.* and log() - all of
-- which exist above - and nothing else from this file.
-- P3: lock reticle - range ring + lock markers
-- ===================================================================
-- THREE elements, TWO screen GUIs, and the split is load bearing:
--
--   GUI A - the RANGE RING (hand-built triangles). Triangles cannot be updated
--           in place: rebuilding them at a colour change is what makes a ring
--           vanish. So the ring lives on its own GUI and that GUI is rebuilt
--           only when its quantised radius, colour or the resolution changes.
--           Its screen radius is the aim cone half angle projected through the
--           camera's vertical FOV, so it follows LOCK ANGLE and the camera zoom.
--
--   GUI B - the LOCK MARKERS (stock Warrant bitmap quads) and, in world space,
--           the TARGET BOX. This GUI is created once and never rebuilt: the
--           quads are updated in place, which is the whole point of separating
--           it. Sharing one GUI with the ring was a bug: zooming a scope moves
--           the FOV, the ring rebuilt every frame, and the markers were
--           destroyed and recreated with it often enough to look absent.
--
-- Engine queries and GUI calls only: nothing here reads or writes process
-- memory. The ring needs no game assets, so it works before the leased Warrant
-- package is resident; the markers simply skip until it is.
local reticle_step = (function()
    local R = { status = 'idle', error = nil, last_status = nil,
                frames = 0, locked = false, marks = 0, projected = false,
                -- GUI B: lock markers
                gui = nil, world = nil, ids = {}, quads = {}, started = nil,
                markers = false, markers_reason = nil,
                -- GUI A: range ring
                ringu = nil, ringw = nil, ring_key = nil, ring_radius = nil, ring_fov = nil,
                -- world space: the target box
                line = nil, line_dirty = false, marker_reason = nil,
                lock_seen = nil, diag_at = -1, diag_tx = nil, diag_ty = nil }
    -- sr.Color takes (a, r, g, b)
    local RING_UNLOCKED, RING_LOCKED = { 255, 255, 180, 32 }, { 255, 64, 255, 64 }
    local RING_HALF = 0.5              -- half of a one-pixel-wide line
    local RING_SEGMENTS = 96           -- enough that the polygon reads as a circle
    local RING_LEVEL = 100             -- same band the reference reticles draw in
    local LOCK_SECONDS = 0.05
    local BOX_HALF = 0.7
    -- frames a lock stays fresh: the box is drawn only while the addon is
    -- still tracking the target, so it can never outlive its own lock
    local BOX_STALE = 60
    local FALLBACK_FOV = 1.0471975511965976   -- 60 degrees, when the camera is unknown
    -- The lock flickers by design: the aim cone is deliberately tight, so
    -- pick_target loses and regains the target from one frame to the next. The
    -- ring colour follows a short memory of it rather than the instantaneous
    -- state, because every colour change rebuilds the ring's GUI.
    local LOCK_MEMORY = 18                    -- frames, 0.3 s at 60 Hz
    local RING_QUANTISE = 4                   -- rebuild the ring in 4 px steps
    -- Stock image widgets bind this texture slot explicitly; Gui.material alone
    -- does not reproduce their texture initialization.
    local TEXTURE_SLOT = '3aa8b87e00000000'
    -- The marker sprite only. The outline circle in the same atlas is deliberately
    -- not used: it cannot be sized to the cone or thinned to a hairline.
    local MARKER = { material = '5af18dfb697cfef2', texture = 'f9a3f22a93eedcbd',
                     uv = { 0.5712890625, 0.0078125, 0.03125, 0.0625 } }

    local function engine()
        local s = rawget(_G, 'stingray')
        if type(s) ~= 'table' or type(s.Application) ~= 'table'
            or type(s.World) ~= 'table' or type(s.Gui) ~= 'table'
            or type(s.Script) ~= 'table' then return nil end
        -- Vector3 and Color are callables; the engine may expose either as a
        -- function or as a callable table, so accept both and never assume.
        if type(s.Vector3) ~= 'function' and type(s.Vector3) ~= 'table' then return nil end
        if type(s.Color) ~= 'function' and type(s.Color) ~= 'table' then return nil end
        if type(s.World.create_screen_gui) ~= 'function'
            or type(s.World.destroy_gui) ~= 'function'
            or type(s.Gui.resolution) ~= 'function'
            or type(s.Gui.triangle) ~= 'function' then return nil end
        return s
    end

    -- The engine's namespaces are not all the same shape: some are tables, some
    -- are callable tables, some are userdata. Ask for the field rather than
    -- assuming a type, which is exactly what makes a type check here a trap.
    local function has(ns, field)
        if ns == nil then return false end
        local ok, f = pcall(function() return ns[field] end)
        return ok and type(f) == 'function'
    end

    local function listed(s, w)
        if w == nil then return false end
        for _, x in pairs(s.Application.worlds() or {}) do if x == w then return true end end
        return false
    end

    -- GUI B: the markers
    local function drop_markers(s)
        if R.gui and R.world and s and listed(s, R.world) then
            pcall(s.World.destroy_gui, R.world, R.gui)
        end
        R.gui, R.world, R.markers = nil, nil, false
        R.ids, R.quads, R.started = {}, {}, nil
    end

    -- GUI A: the ring
    local function drop_ring(s)
        if R.ringu and R.ringw and s and listed(s, R.ringw) then
            pcall(s.World.destroy_gui, R.ringw, R.ringu)
        end
        R.ringu, R.ringw, R.ring_key = nil, nil, nil
    end

    -- Make the box invisible through the one path that is known to work:
    -- reset, a zero-length fully transparent line, dispatch.  Returns false when
    -- there is nothing to clear or the line API is unavailable.
    local function clear_line(s, w)
        if not (R.line and R.line_dirty and w) then return false end
        if not (has(s.LineObject, 'reset') and has(s.LineObject, 'add_line')
            and has(s.LineObject, 'dispatch')) then return false end
        local z = s.Vector3(0, 0, 0)
        local ok = pcall(function()
            s.LineObject.reset(R.line)
            s.LineObject.add_line(R.line, s.Color(0, 0, 0, 0), z, z)
            s.LineObject.dispatch(w, R.line)
        end)
        if ok then R.line_dirty = false end
        return ok
    end

    -- Drop the box.  Ported from Guided Rounds v1.8.5, where this was the actual
    -- cause of "the green box stays after switching weapons":
    --
    --   1. HIDE it first, so a destroy that silently does nothing cannot leave a
    --      visible box behind;
    --   2. only then hand the object back, and only FORGET the handle when the
    --      engine really took it.  Keeping it costs nothing (the next target
    --      reuses the object) and it is the only way to clear a box that is still
    --      being drawn.
    local function drop_lines(s)
        if not R.line then return end
        local w = s.Application.main_world and s.Application.main_world() or nil
        clear_line(s, w)
        local gone = false
        if w and has(s.World, 'destroy_line_object') then
            gone = pcall(s.World.destroy_line_object, w, R.line)
        end
        if gone then
            R.line, R.line_dirty, R.line_fails = nil, false, 0
            return
        end
        R.line_fails = (R.line_fails or 0) + 1
        -- by now the object is invisible, so letting go cannot strand a box; this
        -- only stops a broken destroy call from being retried for ever
        if not R.line_dirty and R.line_fails > 120 then
            R.line, R.line_dirty, R.line_fails = nil, false, 0
        end
    end

    -- HD2 draws screen overlays in the UI world, never in the mission world.
    local function ui_world(s)
        local main = s.Application.main_world and s.Application.main_world() or nil
        for _, w in pairs(s.Application.worlds() or {}) do if w ~= main then return w end end
        return nil
    end

    -- ---------------------------------------------------------------- project
    -- The render camera is not handed to a mod, so it is found the way the game's
    -- own HUD addons do it: the camera unit closest to the mission camera pose,
    -- cached and re-checked once a second.
    local CAM = { camera = nil, unit = nil, next_scan = 0, reason = nil }

    local function render_camera(s, world, now)
        if CAM.unit then
            local ok, alive = pcall(s.Unit.alive, CAM.unit)
            if not ok or alive ~= true then CAM.camera, CAM.unit = nil, nil end
        end
        if CAM.camera then return CAM.camera end
        if now < CAM.next_scan then return nil end
        CAM.next_scan = now + 1
        if not (has(s.World, 'units') and has(s.World, 'debug_camera_pose')
            and has(s.Unit, 'num_cameras') and has(s.Unit, 'camera')
            and has(s.Camera, 'world_position') and has(s.Matrix4x4, 'translation')
            and has(s.Vector3, 'x')) then
            CAM.reason = 'camera_api_missing'
            return nil
        end
        local okp, pose = pcall(s.World.debug_camera_pose, world)
        if not okp or pose == nil then CAM.reason = 'no_camera_pose' return nil end
        local oko, origin = pcall(s.Matrix4x4.translation, pose)
        if not oko or origin == nil then CAM.reason = 'no_camera_origin' return nil end
        local ox, oy, oz = s.Vector3.x(origin), s.Vector3.y(origin), s.Vector3.z(origin)
        local okw, units = pcall(s.World.units, world)
        if not okw or type(units) ~= 'table' then CAM.reason = 'no_units' return nil end
        local best, best_unit, best_cam = 0.25, nil, nil
        for _, u in pairs(units) do
            local okn, n = pcall(s.Unit.num_cameras, u)
            if okn and type(n) == 'number' and n > 0 then
                local okc, cam = pcall(s.Unit.camera, u, 1)
                if okc and cam then
                    local okpos, p = pcall(s.Camera.world_position, cam)
                    if okpos and p then
                        local dx = s.Vector3.x(p) - ox
                        local dy = s.Vector3.y(p) - oy
                        local dz = s.Vector3.z(p) - oz
                        local d = dx * dx + dy * dy + dz * dz
                        if d < best then best, best_unit, best_cam = d, u, cam end
                    end
                end
            end
        end
        CAM.unit, CAM.camera = best_unit, best_cam
        CAM.reason = best_cam and nil or 'camera_not_found'
        return CAM.camera
    end

    local function camera_fov(s, camera)
        if camera and has(s.Camera, 'vertical_fov') then
            local ok, v = pcall(s.Camera.vertical_fov, camera)
            if ok and type(v) == 'number' and v > 0.05 and v < 3 then return v end
        end
        return nil
    end

    -- Screen radius of the aim cone's half angle. A cone projects to a fixed
    -- screen radius, so this is (h/2)/tan(fov/2) * tan(cone) - independent of how
    -- far away the target is.
    local function ring_radius(s, h, world, now)
        local fov = camera_fov(s, render_camera(s, world, now))
        local k = (h / 2) / math.tan((fov or FALLBACK_FOV) / 2)
        local cone = cfg.cone_deg or 12
        if type(cone) ~= 'number' or cone <= 0 then return nil end
        local r = math.tan(math.rad(cone)) * k
        if type(r) ~= 'number' or r ~= r or r < 2 then return nil end
        return math.min(r, h * 4), fov
    end

    -- world position -> screen pixels, or nil when the camera or the binding is
    -- not available. The caller falls back to the screen centre on nil.
    local function raw_project(s, world, pos, w, h, now)
        if not has(s.Camera, 'world_to_screen') then return nil end
        local camera = render_camera(s, world, now)
        if not camera then return nil end
        local ok, p = pcall(s.Camera.world_to_screen, camera,
            s.Vector3(pos[1], pos[2], pos[3]), nil, s.Vector2(w, h))
        if not ok or p == nil then return nil end
        local okx, x = pcall(s.Vector3.x, p)
        local oky, y = pcall(s.Vector3.y, p)
        if not okx or not oky or type(x) ~= 'number' or type(y) ~= 'number'
            or x ~= x or y ~= y then return nil end
        -- a point behind the camera projects to nonsense; reject it rather than
        -- dragging the markers across the screen
        if math.abs(x) > w * 4 or math.abs(y) > h * 4 then return nil end
        return x, y
    end

    -- THE PROJECTION SLIP, measured and corrected (P15c).
    --
    -- The lock markers are PROJECTED; the range ring is DRAWN at the screen centre.
    -- The camera axis - the direction the player looks down - has to land on the
    -- crosshair, which is the screen centre, so the projection of that axis is the
    -- error term of the whole projection. Measured live it is ZERO in most
    -- sessions (then nothing here changes anything) and was 130 px right and
    -- 154 px above the centre in one, where the markers sat that far off the enemy
    -- while the ring stayed on the crosshair - the "sometimes good, sometimes bad"
    -- report, and the reason no targeting change ever fixed it.
    --
    -- So the offset is measured from the axis every frame and subtracted. A slip
    -- larger than a quarter of the screen is not a slip but a broken camera pose,
    -- and is ignored rather than dragging the markers across the screen.
    local OFF = { frame = -1, x = 0, y = 0 }

    local function axis_offset(s, world, w, h, now)
        if OFF.frame == state.frame then return OFF.x, OFF.y end
        OFF.frame, OFF.x, OFF.y = state.frame, 0, 0
        if world and ctx.cam_origin and ctx.cam_forward then
            local ax, ay = raw_project(s, world,
                { ctx.cam_origin[1] + ctx.cam_forward[1] * 50,
                  ctx.cam_origin[2] + ctx.cam_forward[2] * 50,
                  ctx.cam_origin[3] + ctx.cam_forward[3] * 50 }, w, h, now)
            if ax and ay then
                local dx, dy = ax - w / 2, ay - h / 2
                if math.abs(dx) <= w * 0.25 and math.abs(dy) <= h * 0.25 then
                    OFF.x, OFF.y = dx, dy
                end
            end
        end
        return OFF.x, OFF.y
    end

    -- what the reticle draws with: the raw projection with that slip removed
    local function project(s, world, pos, w, h, now)
        local x, y = raw_project(s, world, pos, w, h, now)
        if not x then return nil end
        local ox, oy = axis_offset(s, world, w, h, now)
        return x - ox, y - oy
    end

    -- ------------------------------------------------------------------- ring
    -- one hairline quad, drawn as the two triangles Gui.triangle wants
    local function seg(s, gui, ax, ay, bx, by, half, colour)
        local dx, dy = bx - ax, by - ay
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 1e-6 then return end
        local nx, ny = -dy / len * half, dx / len * half
        local V = s.Vector3
        s.Gui.triangle(gui, V(ax + nx, 0, ay + ny), V(bx + nx, 0, by + ny),
            V(bx - nx, 0, by - ny), RING_LEVEL, colour)
        s.Gui.triangle(gui, V(ax + nx, 0, ay + ny), V(bx - nx, 0, by - ny),
            V(ax - nx, 0, ay - ny), RING_LEVEL, colour)
    end

    local function ring_draw(s, w, h, radius, rgba)
        local gui = R.ringu
        if not gui then return false, 'no_gui' end
        local colour = s.Color(rgba[1], rgba[2], rgba[3], rgba[4])
        local cx, cy = w / 2, h / 2
        local px, py = cx + radius, cy
        for i = 1, RING_SEGMENTS do
            local a = i * 2 * math.pi / RING_SEGMENTS
            local qx, qy = cx + radius * math.cos(a), cy + radius * math.sin(a)
            seg(s, gui, px, py, qx, qy, RING_HALF, colour)
            px, py = qx, qy
        end
        return true
    end

    -- ---------------------------------------------------------------- markers
    local function markers_setup(s, gui)
        if s.Vector2 == nil then return false, 'marker_api_missing' end
        if not (has(s.IdString64, 'from_hex') and has(s.Material, 'set_texture')
            and has(s.Gui, 'material') and has(s.Gui, 'bitmap_3d_uv')
            and has(s.Gui, 'update_bitmap_3d_uv') and has(s.Quaternion, 'axis_angle')
            and has(s.Matrix4x4, 'from_quaternion_position')) then
            return false, 'marker_api_missing'
        end
        -- the leased Warrant package has to be resident for this sprite; when it
        -- is not, the markers simply skip and the ring is unaffected
        if has(s.Application, 'can_get') then
            local ok, got = pcall(s.Application.can_get, 'material',
                s.IdString64.from_hex(MARKER.material))
            if not ok or got ~= true then return false, 'material_not_loaded' end
            ok, got = pcall(s.Application.can_get, 'texture',
                s.IdString64.from_hex(MARKER.texture))
            if not ok or got ~= true then return false, 'texture_not_loaded' end
        end
        local ok, material = pcall(s.Gui.material, gui, s.IdString64.from_hex(MARKER.material))
        if not ok or material == nil then return false, 'material_unavailable' end
        ok = pcall(s.Material.set_texture, material, s.IdString64.from_hex(TEXTURE_SLOT),
            s.IdString64.from_hex(MARKER.texture))
        if not ok then return false, 'texture_bind_failed' end
        return true
    end

    -- One atlas quad. `angle` is in degrees; the transform centres the quad in
    -- its own frame, because Gui.bitmap_3d_uv's origin differs from
    -- Gui.triangle's (a negative Z origin left it half a quad above centre).
    local function quad(s, index, x, y, size, angle, alpha, state, tint)
        local old = R.quads[index]
        if old and ((alpha == 0 and old.alpha == 0)
            or (old.x == x and old.y == y and old.size == size
                and old.angle == angle and old.alpha == alpha and old.state == state)) then
            return
        end
        local material = s.IdString64.from_hex(MARKER.material)
        local uv = MARKER.uv
        local uv0, uv1 = s.Vector2(uv[1], uv[2]), s.Vector2(uv[1] + uv[3], uv[2] + uv[4])
        local radians = math.rad(angle)
        local rotation = s.Quaternion.axis_angle(s.Vector3(0, 1, 0), radians)
        local half = size / 2
        local sine, cosine = math.sin(radians), math.cos(radians)
        local pose = s.Matrix4x4.from_quaternion_position(rotation,
            s.Vector3(x - half * (cosine + sine), 0, y - half * (cosine - sine)))
        local pos = s.Vector3(0, 0, 0)
        local use = (alpha == 0) and s.Color(0, 0, 0, 0) or tint
        if R.ids[index] then
            s.Gui.update_bitmap_3d_uv(R.gui, R.ids[index], material, uv0, uv1, pose, pos,
                RING_LEVEL, s.Vector2(size, size), use)
        else
            R.ids[index] = s.Gui.bitmap_3d_uv(R.gui, material, uv0, uv1, pose, pos,
                RING_LEVEL, s.Vector2(size, size), use)
        end
        old = old or {}
        R.quads[index] = old
        old.x, old.y, old.size, old.angle, old.alpha, old.state = x, y, size, angle, alpha, state
    end

    local function markers_draw(s, w, h, locked, now, world)
        local progress = 0
        if locked then
            if R.started == nil then R.started = now end
            progress = math.min(1, math.max(0, (now - R.started) / LOCK_SECONDS))
        else
            R.started = nil
        end
        local confirmed = locked and progress >= 1
        local state = confirmed and 'locked' or (locked and 'acquiring' or 'idle')
        -- sr.Color takes (a, r, g, b); these are the stock Warrant colours.
        local colour = confirmed and s.Color(255, 0, 255, 0)
            or (locked and s.Color(255, 255, 193.8, 7.65)
                or s.Color(255, 255, 233.07, 0))
        -- The markers orbit the LOCKED TARGET on screen, which is what makes the
        -- reticle read as "that one". Centre only when there is no target or the
        -- projection is unavailable.
        local tx, ty
        if locked then
            local p = ctx.target and ctx.target.position
            if type(p) == 'table' and type(p[1]) == 'number' and world then
                tx, ty = project(s, world, p, w, h, now)
                R.projected = (tx ~= nil)
            end
        else
            R.projected = false
        end
        local bx, by = tx or w / 2, ty or h / 2
        R.diag_tx, R.diag_ty = tx, ty
        -- three markers 120 degrees apart, spinning once and contracting from
        -- radius 24 to 10 over the lock; hidden until there is a target
        local scale = h / 1080
        local radius = (24 * (1 - progress) + 10 * progress) * scale
        local alpha = locked and 1 or 0
        for i = 0, 2 do
            local angle = progress * 360 + i * 120
            local radians = math.rad(angle)
            quad(s, i + 1, bx + math.sin(radians) * radius,
                by + math.cos(radians) * radius, 48 * scale, angle, alpha, state, colour)
        end
        R.status = confirmed and 'drawn_locked' or (locked and 'drawn_acquiring' or 'drawn')
    end

    -- ------------------------------------------------------------ world marker
    local EDGES = { {1,2},{3,4},{5,6},{7,8},{1,3},{2,4},{5,7},{6,8},{1,5},{2,6},{3,7},{4,8} }
    local function marker(s)
        local world = s.Application.main_world and s.Application.main_world() or nil
        if not world or not (has(s.World, 'create_line_object')
            and has(s.World, 'destroy_line_object') and has(s.LineObject, 'reset')
            and has(s.LineObject, 'add_line')
            and has(s.LineObject, 'dispatch')) then
            R.marker_reason = 'line_api_missing'
            return
        end
        local t = ctx.target
        local p = t and t.position
        -- the lock must be FRESH: a stale ctx.target (the weapon was switched, the
        -- addon stopped tracking) hides the box instead of drawing it where the
        -- target used to be
        local fresh = (state.frame - (ctx.target_at or -1e9)) <= BOX_STALE
        if type(p) ~= 'table' or type(p[1]) ~= 'number' or not fresh then
            clear_line(s, world)
            return
        end
        if not R.line then
            R.line = s.World.create_line_object(world, true)
            if not R.line then R.marker_reason = 'line_create_failed' return end
        end
        local c = {}
        for i = 0, 7 do
            c[i + 1] = { p[1] + ((i % 2 == 0) and -BOX_HALF or BOX_HALF),
                         p[2] + ((math.floor(i / 2) % 2 == 0) and -BOX_HALF or BOX_HALF),
                         p[3] + ((math.floor(i / 4) % 2 == 0) and -BOX_HALF or BOX_HALF) }
        end
        local colour, V = s.Color(255, 64, 255, 64), s.Vector3
        s.LineObject.reset(R.line)
        for i = 1, #EDGES do
            local a, b = c[EDGES[i][1]], c[EDGES[i][2]]
            s.LineObject.add_line(R.line, colour, V(a[1], a[2], a[3]), V(b[1], b[2], b[3]))
        end
        s.LineObject.dispatch(world, R.line)
        R.line_dirty = true
        R.marks = R.marks + 1
    end

    -- One line a second while a target is held. This is what turns "the position
    -- is wrong" into numbers: the camera, the FOV, the target's world position and
    -- where it projected to, next to the screen centre.
    local function diag(s, w, h, locked, now)
        if not locked then return end
        local sec = math.floor(now)
        if R.diag_at == sec then return end
        R.diag_at = sec
        local p = ctx.target and ctx.target.position
        -- P15: where the camera axis itself lands on screen. The ring is drawn
        -- about the screen centre; if the game's projection is off centre (a lens
        -- shift, which third person cameras often use) the axis lands somewhere
        -- else, and then it is the RING that is drawn in the wrong place while the
        -- marker - which is projected - is right.
        local ax, ay, mx, my
        local mw = s.Application.main_world and s.Application.main_world() or nil
        if mw and ctx.cam_origin and ctx.cam_forward then
            -- raw on purpose: this is the measurement of the slip itself
            ax, ay = raw_project(s, mw, { ctx.cam_origin[1] + ctx.cam_forward[1] * 50,
                ctx.cam_origin[2] + ctx.cam_forward[2] * 50,
                ctx.cam_origin[3] + ctx.cam_forward[3] * 50 }, w, h, now)
        end
        -- P15b: and the MUZZLE axis, for the same reason. Three things can be the
        -- aim direction here - the debug camera pose (what the cone is built on),
        -- the render camera the points are projected with, and the weapon in hand -
        -- and the crosshair is wherever the game puts it. If the muzzle axis lands
        -- on the screen centre while the camera axis does not, the camera pose is
        -- the odd one out and the cone is aimed 6 degrees off the crosshair.
        if mw and ctx.origin and ctx.forward then
            mx, my = raw_project(s, mw, { ctx.origin[1] + ctx.forward[1] * 50,
                ctx.origin[2] + ctx.forward[2] * 50,
                ctx.origin[3] + ctx.forward[3] * 50 }, w, h, now)
        end
        log(('RETICLE DIAG cam=%s fov=%s screen=%dx%d centre=%.0f,%.0f world=%s,%s,%s '
            .. 'screenpos=%s,%s axis=%s,%s muz=%s,%s ring=%s r=%s box=%s')
            :format(tostring(CAM.camera ~= nil),
                R.ring_fov and string.format('%.1fdeg', math.deg(R.ring_fov)) or 'fallback',
                w, h, w / 2, h / 2,
                p and string.format('%.1f', p[1]) or '-',
                p and string.format('%.1f', p[2]) or '-',
                p and string.format('%.1f', p[3]) or '-',
                R.diag_tx and string.format('%.0f', R.diag_tx) or '-',
                R.diag_ty and string.format('%.0f', R.diag_ty) or '-',
                ax and string.format('%.0f', ax) or '-',
                ay and string.format('%.0f', ay) or '-',
                mx and string.format('%.0f', mx) or '-',
                my and string.format('%.0f', my) or '-',
                tostring(R.ring_radius), tostring(cfg.range_ring == 1),
                tostring(R.line ~= nil)))
    end

    -- ------------------------------------------------ which weapon is aiming
    -- P4. APW drives its aim cone from held[1], which is usually the primary
    -- slung on the player's back. Whenever the weapon in hand is the second one -
    -- a support weapon - the cone started behind the player, so the target it
    -- picked was wrong and everything drawn from it (the markers, the box) did
    -- not appear. The weapon in hand points where the player looks and the slung
    -- one does not, so the pose best aligned with the camera forward is the one
    -- in hand. The choice is published as ctx.aim_pose and APW's weapon_pose()
    -- prefers it on the next frame, which fixes the cone and the display together.
    local AIM = { id = nil, score = nil }

    -- The camera's own pose. It is published so the ACQUISITION cone can be built
    -- on it: a cone whose apex is the camera projects to exactly a circle about
    -- the screen centre, radius tan(half angle) * (h/2)/tan(fov/2), at every depth
    -- - which is precisely the ring drawn below. Building the cone on the muzzle
    -- instead makes the two disagree by several degrees in third person, more than
    -- the whole cone at a tight LOCK ANGLE, and enemies outside the ring were
    -- acquired because of it.
    local function camera_pose(s, world)
        if not world or not has(s.Matrix4x4, 'forward') or not has(s.Matrix4x4, 'translation')
            or not has(s.World, 'debug_camera_pose') or not has(s.Vector3, 'x') then
            return nil
        end
        local ok, pose = pcall(s.World.debug_camera_pose, world)
        if not ok or pose == nil then return nil end
        local okf, f = pcall(s.Matrix4x4.forward, pose)
        local okt, o = pcall(s.Matrix4x4.translation, pose)
        if not okf or f == nil or not okt or o == nil then return nil end
        local okx, fx = pcall(s.Vector3.x, f)
        local _, fy = pcall(s.Vector3.y, f)
        local _, fz = pcall(s.Vector3.z, f)
        local _, ox = pcall(s.Vector3.x, o)
        local _, oy = pcall(s.Vector3.y, o)
        local _, oz = pcall(s.Vector3.z, o)
        if not okx or type(fx) ~= 'number' or type(fy) ~= 'number' or type(fz) ~= 'number'
            or type(ox) ~= 'number' or type(oy) ~= 'number' or type(oz) ~= 'number' then
            return nil
        end
        return { ox, oy, oz }, { fx, fy, fz }
    end

    local function update_aim_pose(s, world)
        -- published first and unconditionally: the acquisition cone depends on it
        local cam_o, cam_f = camera_pose(s, world)
        ctx.cam_origin, ctx.cam_forward = cam_o, cam_f
        local held = ctx.held
        if not cam_f or not held or #held < 2 or not ctx.pose then
            ctx.aim_pose, ctx.aim_txt, AIM.id, AIM.score = nil, nil, nil, nil
            return
        end
        local cx, cy, cz = cam_f[1], cam_f[2], cam_f[3]
        local best_id, best_score
        for i = 1, #held do
            local p = ctx.pose[held[i].id]
            if p then
                local f = p.forward
                local score = f[1] * cx + f[2] * cy + f[3] * cz
                if not best_score or score > best_score then
                    best_id, best_score = held[i].id, score
                end
            end
        end
        -- the two poses can be almost equally aligned; require a clear win before
        -- switching so the choice cannot flicker from one frame to the next
        if AIM.id and AIM.id ~= best_id and ctx.pose[AIM.id]
            and best_score <= (AIM.score or -2) + 0.08 then
            best_id, best_score = AIM.id, AIM.score
        end
        if not best_id then ctx.aim_pose, ctx.aim_txt = nil, nil return end
        if AIM.id ~= best_id then
            AIM.id, AIM.score = best_id, best_score
            log(('AIM the aim cone now starts at the weapon in hand (id=%s, '
                .. 'camera-aligned score %.2f), not at the first one carried')
                :format(tostring(best_id), best_score))
        else
            AIM.score = best_score
        end
        ctx.aim_pose = ctx.pose[best_id]
        -- P10: the hash of the weapon in hand, so the targeting order can follow
        -- it. This is the same weapon pick the aim cone uses, which is what makes
        -- the reticle agree with whatever the round does.
        for i = 1, #held do
            if held[i].id == best_id then ctx.aim_txt = held[i].txt break end
        end
    end

    -- ------------------------------------------- is the weapon in hand guided?
    -- P11. The lock UI belongs to a GUIDED weapon. The runtime reports the entity
    -- in hand and its type (docs/player-equipment.md), and the addon publishes the
    -- set of guided types as ctx.guided. Whatever is off the list - a weapon whose
    -- guidance is switched off in the MODS tab, a stratagem ball, anything that is
    -- not the list's weapon resource at all - drops the marker, the ring and the
    -- box instead of drawing a lock that can never bind. The test is the list, not
    -- a category: throwables and melee weapons are on it and are guidable when
    -- they are switched on, so they keep the UI.
    --
    -- It fails OPEN on purpose. When the runtime cannot be asked at all (no
    -- runtime module, no player, a runtime without the call) the UI is drawn
    -- exactly as it was before this existed, rather than silently disappearing.
    local HAND = { at = -1e9, type = nil, ok = true, reason = nil, logged = nil,
                   rt = nil, next_try = -1e9 }
    local HAND_EVERY = 6                  -- frames between queries, 0.1 s at 60 Hz

    -- The shared runtime is NOT a global. This addon already asks for it by name
    -- for its asset leases, and that is the only path that is known to work:
    -- rawget(_G, 'hd2') is nil in a Bingus addon, which is exactly what the first
    -- build of this gate hit - it saw "no_hd2" on every query and therefore drew
    -- the UI everywhere. A global is still accepted first, in case a runtime ever
    -- publishes one. A miss is retried once a second, not once a frame.
    local function hand_runtime()
        if HAND.rt then return HAND.rt end
        -- the global costs nothing to re-check, so it is checked every time
        local g = rawget(_G, 'hd2')
        if type(g) == 'table' and type(g.local_player) == 'function' then
            HAND.rt = g
            return g
        end
        -- require is the expensive one, miss or not, so a miss waits a second
        if state.frame < HAND.next_try then return nil end
        HAND.next_try = state.frame + 60
        local ok, mod = pcall(require, 'mods/skyeshade/hd2runtime')
        if ok and type(mod) == 'table' then HAND.rt = mod end
        return HAND.rt
    end

    local function hand_guided()
        if (state.frame - HAND.at) < HAND_EVERY then return HAND.ok end
        HAND.at = state.frame
        local hd2 = hand_runtime()
        local pok, text, why, via = pcall(function()
            if type(hd2) ~= 'table' then return nil, 'no_runtime' end
            if type(hd2.local_player) ~= 'function' then
                return nil, 'no_local_player'
            end
            local p = hd2.local_player()
            if p == nil then return nil, 'no_player' end
            -- equipped_weapon re-reads the wielder slot on every call and is the
            -- newest name for this; held_weapon and loadout().held are older ones
            local w, wwhy, how
            if type(p.equipped_weapon) == 'function' then
                w, wwhy, how = p:equipped_weapon(), nil, 'equipped_weapon'
            elseif type(p.held_weapon) == 'function' then
                w, wwhy, how = p:held_weapon(), nil, 'held_weapon'
            elseif type(p.loadout) == 'function' then
                local lo = p:loadout()
                w, how = (type(lo) == 'table') and lo.held or nil, 'loadout'
            else
                return nil, 'no_hand_api'
            end
            if w == nil then return nil, tostring(wwhy or 'nothing_in_hand') end
            if type(w.type) ~= 'string' then return nil, 'no_type' end
            -- the runtime prints the weapon resource as hex digits, with or
            -- without the 0x the cfg and the SDK catalogs use
            local t = w.type:upper():gsub('^0X', '')
            return t, nil, how .. (w.slot and ('/' .. tostring(w.slot)) or '')
        end)
        if not pok then
            HAND.ok, HAND.type = true, nil
            HAND.reason = 'call failed: ' .. tostring(text)
        elseif text == nil then
            HAND.ok, HAND.type, HAND.reason, via = true, nil, tostring(why), nil
        else
            HAND.type = text
            if ctx.guided == nil then
                -- the addon has not published the list yet: fail open, exactly as
                -- for a runtime that cannot be asked
                HAND.ok, HAND.reason = true, 'no_list'
            else
                HAND.ok, HAND.reason = ctx.guided[text] == true, nil
            end
        end
        -- one line per change, so "the ring never came back" is answerable: the
        -- reason word says which piece of the query failed, and `via` which call
        -- answered when it did
        local key = (HAND.ok and 'guided:' or 'not:')
            .. tostring(HAND.type or HAND.reason)
        if key ~= HAND.logged then
            HAND.logged = key
            -- the one failure that is worth spelling out: with no runtime there is
            -- no way to know what is in hand, the gate fails OPEN, and the lock UI
            -- comes back for every weapon - which reads as "the feature broke
            -- again" unless the log says why
            local note = (HAND.reason == 'no_runtime')
                and ('  <-- HD2Runtime is not installed or not enabled: the lock UI '
                     .. 'cannot tell which weapon is in hand, so it is drawn for all '
                     .. 'of them. Install/enable HD2Runtime and restart.') or ''
            log(('RETICLE hand weapon: type=%s in the guided list=%s -> lock UI %s%s%s')
                :format(tostring(HAND.type or HAND.reason),
                    tostring(ctx.guided ~= nil
                        and ctx.guided[HAND.type or ''] == true),
                    HAND.ok and 'ON' or 'OFF',
                    via and (' (via ' .. via .. ')') or '', note))
        end
        return HAND.ok
    end

    -- -------------------------------------------------------------------- draw
    local function draw()
        local s = engine()
        if not s then R.status = 'no_stingray' return end
        local mworld = s.Application.main_world and s.Application.main_world() or nil
        -- published before the toggle checks: the aim cone must start from the
        -- weapon in hand whether or not anything is being drawn
        if cfg.enable == 1 and state.armed then update_aim_pose(s, mworld) end
        local want_ring = cfg.range_ring == 1
        local want_markers = cfg.lock_reticle == 1
        if cfg.enable ~= 1 or not state.armed or not (want_ring or want_markers
            or cfg.target_box == 1) then
            drop_markers(s) drop_ring(s) drop_lines(s)
            R.locked = false R.status = 'off' return
        end
        -- the reticle belongs to the weapon in hand
        if (state.frame - (ctx.weapon_at or -99999)) > 2 then
            drop_markers(s) drop_ring(s) drop_lines(s)
            R.locked = false R.status = 'idle' return
        end
        -- P11: and only while that weapon is one of the guided ones. Holding a
        -- weapon whose guidance is off, or one that cannot be guided at all,
        -- shows no lock UI at all.
        if not hand_guided() then
            drop_markers(s) drop_ring(s) drop_lines(s)
            R.locked = false R.status = 'hand_not_guided' return
        end
        local ok, w, h = pcall(s.Gui.resolution)
        if not ok or type(w) ~= 'number' or type(h) ~= 'number'
            or w < 320 or h < 200 or w > 16384 or h > 16384 then
            R.status = 'no_resolution' return
        end
        local locked = ctx.target ~= nil
        R.locked = locked
        if locked then R.lock_seen = state.frame end
        -- what the RING shows: the lock with a short memory, so a flickering
        -- acquisition cannot rebuild the ring on every frame
        local ring_locked = R.lock_seen ~= nil and (state.frame - R.lock_seen) <= LOCK_MEMORY
        local now = state.frame / 60

        -- ---- GUI A: the range ring, on its own, rebuilt only when it changes.
        -- The radius depends on the camera FOV, so a scoped rifle zooming in and
        -- out changes it continuously; it is quantised and, critically, isolated
        -- from the markers so a rebuild can never disturb them.
        local ring_key
        if want_ring and mworld then
            local r, fov = ring_radius(s, h, mworld, now)
            if r then
                R.ring_radius = math.floor(r / RING_QUANTISE + 0.5) * RING_QUANTISE
                R.ring_fov = fov
                ring_key = (ring_locked and 'L' or 'U') .. '|' .. w .. '|' .. h
                    .. '|' .. R.ring_radius
            end
        end
        if R.ringu and not listed(s, R.ringw) then drop_ring(s) end
        if R.ringu and ring_key ~= R.ring_key then drop_ring(s) end
        if not R.ringu and ring_key then
            local world = ui_world(s)
            if not world then R.status = 'no_ui_world' return end
            local gui = s.World.create_screen_gui(world, 'scale', 1, 1)
            if not gui then R.status = 'ring_gui_failed' return end
            R.ringu, R.ringw = gui, world
            ring_draw(s, w, h, R.ring_radius, ring_locked and RING_LOCKED or RING_UNLOCKED)
        end
        R.ring_key = ring_key

        -- ---- GUI B: the lock markers. Created once, never rebuilt.
        if want_markers then
            if R.gui and not listed(s, R.world) then drop_markers(s) end
            if not R.gui then
                local world = ui_world(s)
                if not world then R.status = 'no_ui_world' return end
                local gui = s.World.create_screen_gui(world, 'scale', 1, 1)
                if not gui then R.status = 'marker_gui_failed' return end
                R.gui, R.world = gui, world
                R.ids, R.quads = {}, {}
                local ready, why = markers_setup(s, gui)
                R.markers = ready
                R.markers_reason = ready and nil or why
            end
            if R.markers then
                markers_draw(s, w, h, locked, now, mworld)
            end
        else
            if R.gui then drop_markers(s) end
            R.projected = false
        end

        -- ---- the box is its own switch: it is the only thing in world space
        if cfg.target_box == 1 then
            marker(s)
        else
            drop_lines(s)
        end
        R.frames = R.frames + 1
        diag(s, w, h, locked, now)
    end

    return function(stop)
        local s = engine()
        if not s then return end
        if stop then
            -- hand the aim cone back to the file's own choice before going away
            ctx.aim_pose, ctx.cam_origin, ctx.cam_forward = nil, nil, nil
            pcall(drop_markers, s) pcall(drop_ring, s) pcall(drop_lines, s)
            R.status = 'stopped' return
        end
        if type(s.Script.temp_byte_count) ~= 'function'
            or type(s.Script.set_temp_byte_count) ~= 'function' then return end
        -- every call must run inside the engine's temporaries ring
        local counted, saved = pcall(s.Script.temp_byte_count)
        if not counted then return end
        local ok, err = pcall(draw)
        if not ok then
            R.error = tostring(err)
            R.status = 'error'
            pcall(drop_markers, s) pcall(drop_ring, s)
        end
        pcall(s.Script.set_temp_byte_count, saved)
        -- one line per change, so a reticle that never appears says why in the log
        if R.last_status ~= R.status then
            R.last_status = R.status
            if R.status ~= 'idle' and R.status ~= 'off' then
                log(('RETICLE %s (ring=%s r=%s markers=%s proj=%s box=%s frames=%d marks=%d)%s%s%s')
                    :format(R.status, tostring(cfg.range_ring == 1),
                        tostring(R.ring_radius), tostring(R.markers), tostring(R.projected),
                        tostring(R.line ~= nil), R.frames, R.marks,
                        R.markers_reason and (' marker=' .. R.markers_reason) or '',
                        R.marker_reason and (' box=' .. R.marker_reason) or '',
                        R.error and (' error=' .. R.error) or ''))
            end
        end
    end
end)()
-- the addon's own per-frame UI hook is just a forwarder
local function ui_step(stop) return reticle_step(stop) end


-- ---------------------------------------------------------------- language
-- The MODS tab is shown in the client's own language: Chinese for the two
-- Chinese text languages, English for every other one.
--
-- WHY THIS READS MEMORY INSTEAD OF ASKING THE RUNTIME
--   `hd2.text.language()` only exists from HD2Runtime 0.31.2 and
--   `hd2.ui.language()` from 0.31.1, but this addon supports older runtimes
--   (0.28.x is confirmed on the author's machine), so neither can be required.
--   The offsets below are the ones ModOptionsMenu's own bingus_text.lua uses to
--   follow the game's Text Language - the same setting the game's Options menu
--   writes - so they are known-good on this build:
--
--     settings object at game.dll+0x3326340; its +705500+212 holds an index into
--     the table of 15 language records at game.dll+0x37C5650; each record's code
--     string is at +8.
--
--   Five reads, and an implausible value means "unknown" rather than a guess.
local LANG_SETTINGS = 0x3326340
local LANG_INDEX = 705500 + 212
local LANG_TABLE = 0x37C5650
local LANG_COUNT = 15

-- The codes that mean "this client reads Chinese".  'cn' is Simplified; 'tw' and
-- 'tc' are both spellings the game's tables use for Traditional.
local ZH_CODES = {
    cn = true, zh = true, zhs = true, ['zh-cn'] = true, ['zh-hans'] = true,
    tw = true, tc = true, zht = true, ['zh-tw'] = true, ['zh-hant'] = true,
}

-- The game's Text Language code, or nil when it cannot be read.
local function read_language_code()
    local settings = ptr8(base + LANG_SETTINGS)
    if not settings then return nil end
    local ib = rd(settings + LANG_INDEX, 4)
    if not ib then return nil end
    local index = u32(ib, 0)
    if not index or index >= LANG_COUNT then return nil end
    local record = ptr8(base + LANG_TABLE + 8 * index)
    if not record then return nil end
    local text = ptr8(record + 8)
    if not text then return nil end
    local bytes = rd(text, 16)
    if not bytes then return nil end
    local code = bytes:match('^(%a[%a%-]*)%z')
    if code and #code <= 12 then return code:lower() end
    return nil
end

-- Asked once per frame at most: the menu calls a text function several times
-- while it opens, and this costs five memory reads.
local LANG_CACHE = { frame = -1, zh = nil, code = nil, how = nil }
local function client_is_chinese()
    if LANG_CACHE.frame == state.frame then
        return LANG_CACHE.zh, LANG_CACHE.code, LANG_CACHE.how
    end
    local zh, code, how
    -- the runtime's own answer first, when this runtime is new enough to have it
    local ok, hd2 = pcall(require, 'mods/skyeshade/hd2runtime')
    if ok and type(hd2) == 'table' and type(hd2.text) == 'table'
        and type(hd2.text.language) == 'function' then
        local okc, value = pcall(hd2.text.language)
        if okc and type(value) == 'string' and value ~= '' then
            code, how = value:lower(), 'hd2.text'
            zh = ZH_CODES[code] == true
        end
    end
    if zh == nil then
        code = read_language_code()
        if code then
            how = 'memory'
            zh = ZH_CODES[code] == true
        end
    end
    LANG_CACHE.frame, LANG_CACHE.zh, LANG_CACHE.code, LANG_CACHE.how = state.frame, zh, code, how
    return zh, code, how
end

-- The text for this client.  An UNREADABLE language is treated as "not
-- Chinese", because the rule is "Chinese only for the two Chinese text
-- languages" - so an English client on a runtime we cannot read still gets
-- English instead of being handed Chinese it cannot read.
local function T(en, zh)
    if client_is_chinese() == true then return zh end
    return en
end

-- The menu wants a function when the text must follow a language change.
local function Tf(en, zh)
    return function() return T(en, zh) end
end

-- UTF-8 aware truncation to a BYTE budget.  The menu counts limits in
-- characters in v1.2 and in bytes in v1.0, so bytes is the safe reading for
-- both - but cutting a multi-byte character in half would produce invalid UTF-8,
-- which is worse than a shorter label, so the cut is moved back to a character
-- boundary.
local function utf8_clip(s, limit)
    if type(s) ~= 'string' or #s <= limit then return s end
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2 end
        if i + len - 1 > limit then break end
        i = i + len
    end
    return s:sub(1, i - 1)
end

-- A menu text may be a string or a function; apply the budget to whatever comes
-- back, so a translated string is measured too and not just the one at load.
local function clamp_text(t, limit)
    if type(t) == 'function' then
        return function()
            local s = t()
            if type(s) ~= 'string' then return s end
            return utf8_clip(s, limit)
        end
    end
    return utf8_clip(t, limit)
end

-- ---------------------------------------------------------------- menu
local menu_step = (function()
    local done, MOM = false, nil
    local MOD = 'HOMING STIM'
    -- texts now come from the language-aware T/Tf above
    local SLIDERS = {
        { k = 'cone_deg', min = 0, max = 90, step = 1,
          en = 'LOCK ANGLE (deg)', zh = '锁定范围锥角（度）',
          de = 'How far off the aim axis a friendly unit may sit and still be '
            .. 'picked up. It also sizes the range ring on screen, and the ring '
            .. 'only stays on screen while the angle is narrower than HALF your '
            .. 'current field of view - so a large angle makes the ring leave the '
            .. 'screen when you aim down the sights. 15 is the shipped value. '
            .. '0 = no cone at all (everything in range is a candidate).',
          dz = '友军单位偏离准心多少度仍会被锁定。它同时决定屏幕上范围环的大小：'
            .. '只有角度小于当前视场角的一半时，圆环才留在屏幕内——所以角度调大后，'
            .. '开镜时圆环会跑出屏幕。出厂值 15。设为 0 表示没有锥角限制。' },
        { k = 'max_dist', min = 0, max = 500, step = 5,
          en = 'LOCK RANGE (m)', zh = '锁定距离（米）',
          de = 'Furthest friendly unit the round will accept, in metres.',
          dz = '弹丸接受目标的最远距离，单位是米。' },
        { k = 'heal_percent', min = 0, max = 100, step = 1,
          en = 'SELF-HEAL AMOUNT (% max HP)', zh = '自我恢复量（最大血量%）',
          de = 'Health one real P-11 shot gives back, as a percentage of your '
            .. 'MAXIMUM health. 35 is about what a stim gives. It is a percentage '
            .. 'because health points have no obvious scale: the same number can be '
            .. 'a third of a Helldiver or a fortieth. The log prints the amount and '
            .. 'the maximum it was scaled from, so it can be dialled exactly.',
          dz = '开一枪 P-11 回多少血，按**最大血量的百分比**算。35 约等于一针兴奋剂。'
            .. '用百分比是因为血点没有直观单位：同一个数字可能是三分之一血，也可能是'
            .. '四十分之一。日志会打出实际回血量与最大血量，可以照着调。' },
        { k = 'heal_cooldown', min = 0, max = 10, step = 0.1,
          en = 'SELF-HEAL COOLDOWN (s)', zh = '自我恢复冷却（秒）',
          de = 'Least time between two self-heals. 0.5 is the shipped value; raise '
            .. 'it if a burst heals you faster than you want.',
          dz = '两次自我恢复之间至少隔多少秒。出厂值 0.5；连射回血太快就调大。' },
    }
    local TOGGLES = {
        { k = 'ignore_full', en = 'IGNORE FULL HEALTH', zh = '满血目标过滤',
          de = 'ON: a Helldiver or SEAF at FULL health is never locked. Only '
            .. 'somebody who is actually hurt can be picked up.',
          dz = '开启后不锁定满血的潜兵和 SEAF，只会锁定真正受伤的目标。' },
        { k = 'self_heal', en = 'HEAL YOURSELF WHEN FIRING', zh = '射击时自我恢复',
          de = 'ON: a REAL P-11 shot heals you. It hooks the runtime\'s player_fired '
            .. 'event (the game\'s own projectiles_fired stat), so reloading, drawing '
            .. 'the pistol or dry-firing heals nothing, and the heal is the game\'s own '
            .. 'AddHealthFraction - it clamps at maximum health and is refused while '
            .. 'you are downed or dead. Needs HD2Runtime. It fires NO extra rounds.',
          dz = '开启后**真实开枪**就给自己回血。挂的是运行时的 player_fired 事件'
            .. '（游戏自己的 projectiles_fired 统计），所以换弹、拔枪、空扳机都不回血；'
            .. '回血走游戏自己的 AddHealthFraction，**自动封顶到最大血量**，'
            .. '倒地或死亡时会被拒绝。需要 HD2Runtime。**不会**多射出弹头。' },
        { k = 'range_ring', en = 'RANGE RING', zh = '显示范围环',
          de = 'Draw the thin aim-cone range ring in the middle of the screen.',
          dz = '在屏幕中央画出索敌范围圆环。' },
        { k = 'lock_reticle', en = 'LOCK MARKERS', zh = '显示锁定标记',
          de = 'Draw the stock lock markers on the locked unit; they spin in as '
            .. 'the lock completes.',
          dz = '在锁定的单位身上画出锁定标记，锁定完成时会旋转收拢。' },
        { k = 'target_box', en = 'TARGET BOX', zh = '显示锁定部位',
          de = 'Draw the wire box on the locked unit (the only element drawn in '
            .. 'world space).',
          dz = '在锁定单位外面画线框，这是唯一画在世界空间的元素。' },
        { k = 'los_check', en = 'REQUIRES LINE OF SIGHT', zh = '掩体判断',
          de = 'ON (default): a unit you have no line of sight to is not locked. '
            .. 'The ray is fired from the muzzle, so it tests the path the round '
            .. 'would actually take.',
          dz = '默认开启：你和目标之间有实体挡住时不锁定。射线从枪口发出，'
            .. '判的就是子弹这条路。' },
        { k = 'lua_bind', en = 'BIND TARGET OURSELVES', zh = '自己绑定目标',
          de = 'ON (default): when the engine does not lock by itself, pick a '
            .. 'target in the aim cone and bind it. Recommended.',
          dz = '默认开启：引擎没锁上时由 mod 在瞄准锥里挑一个绑上去。建议保持开启。' },
    }
    return function()
        if done then return end
        local M = rawget(_G, 'ModOptionsMenu')
        if not M or M.api ~= 1 then return end
        done, MOM = true, M
        local ok, err = pcall(function()
            local function row(id, spec)
                -- labels are capped at 64 and descriptions at 400; the cap is
                -- applied to whatever the (possibly translated) text returns, and
                -- clipped on a UTF-8 boundary so a Chinese label is never cut in
                -- half.  A description over the cap is clipped rather than
                -- dropped, so a long translation still says something.
                spec.label = clamp_text(spec.label, 64)
                if spec.description ~= nil then
                    spec.description = clamp_text(spec.description, 400)
                end
                local good, why = M.register_option(id, spec)
                if not good then log(('menu: %s refused - %s'):format(id, tostring(why))) end
                return good
            end
            local ID_ENABLE = 'homing_stim_enable'
            row(ID_ENABLE, {
                type = 'toggle', mod = MOD, mod_id = 'cancan2333.homing_stim',
                label = Tf('ENABLE', '启用'), default = cfg.enable == 1,
                description = Tf('Turns the whole addon on and off.',
                    '整个 mod 的总开关。关闭会把所有改过的数值还原成出厂值。'),
            })
            for _, s in ipairs(SLIDERS) do
                local id = 'homing_stim_' .. s.k
                local val = cfg[s.k]
                if type(val) ~= 'number' or val < s.min or val > s.max then val = s.min end
                row(id, {
                    type = 'slider', mod = MOD, mod_id = 'cancan2333.homing_stim',
                    label = Tf(s.en, s.zh), min = s.min, max = s.max, step = s.step,
                    default = val, description = Tf(s.de, s.dz),
                })
                M.set(id, val)
                local kept = M.get(id)
                if type(kept) == 'number' and kept ~= cfg[s.k] then
                    cfg[s.k] = kept
                    state.save_cfg_key(s.k, string.format('%g', kept))
                end
                if type(M.on_change) == 'function' then
                    M.on_change(id, function(value)
                        cfg[s.k] = value
                        state.save_cfg_key(s.k, string.format('%g', value))
                        log(('menu: %s = %s'):format(s.k, tostring(value)))
                    end)
                end
            end
            for _, t in ipairs(TOGGLES) do
                local id = 'homing_stim_' .. t.k
                local val = cfg[t.k] == 1
                row(id, {
                    type = 'toggle', mod = MOD, mod_id = 'cancan2333.homing_stim',
                    label = Tf(t.en, t.zh), default = val, description = Tf(t.de, t.dz),
                })
                M.set(id, val)
                local kept = M.get(id)
                local as01 = kept and 1 or 0
                if as01 ~= cfg[t.k] then
                    cfg[t.k] = as01
                    state.save_cfg_key(t.k, tostring(as01))
                end
                if type(M.on_change) == 'function' then
                    M.on_change(id, function(value)
                        cfg[t.k] = value and 1 or 0
                        state.save_cfg_key(t.k, tostring(cfg[t.k]))
                        log(('menu: %s = %d'):format(t.k, cfg[t.k]))
                    end)
                end
            end
            M.set(ID_ENABLE, cfg.enable == 1)
            if type(M.on_change) == 'function' then
                M.on_change(ID_ENABLE, function(value)
                    cfg.enable = value and 1 or 0
                    state.save_cfg_key('enable', tostring(cfg.enable))
                    if cfg.enable == 0 then
                        pcall(lease, false)
                    else
                        state.armed = true
                    end
                    log('menu: enable = ' .. tostring(cfg.enable))
                end)
            end
        end)
        if not ok then
            log('options menu: could not publish the options - ' .. tostring(err))
        else
            log(('options menu: %s published on the MODS tab (%d options)')
                :format(MOD, 1 + #SLIDERS + #TOGGLES))
        end
    end
end)()

-- ---------------------------------------------------------------- assets
-- Load the P-92 package, which is where the leased projectile's MESH AND
-- MATERIALS live.  Without it the round renders as HD2's missing-asset
-- placeholder - the pink question mark.
--
-- The request is retried in case the runtime was not up yet on the first try.
--
-- WHAT THIS DOES *NOT* DO - corrected after checking the SDK, because an earlier
-- version of this comment claimed the opposite:
--   It does NOT need a per-frame tick.  `hd2.require_assets` returns a watch
--   handle, and in SDK 0.31.3 that handle has no `tick` member at all
--   (metadata.json -> api.classes.HD2Watch = status / result / error / cancel /
--   attempts / max_attempts / last_transient); Runtime polls the engine's
--   package list itself every 0.25 s (docs/asset-loading.md:67-69).  Guided
--   Rounds' `aw.tick` call is guarded, defensive code for an older API - it is
--   kept below for the same reason (it costs nothing and helps an older
--   runtime), but it is not what loads the package.
--   It also CANNOT fix another machine's placeholder.  Loading is per machine
--   ("Loading is local ... A host with the mod loads the package for itself
--   only. Clients without the mod still see whatever their own game resolves,
--   and may still see a missing asset for an object whose authority is the
--   host", docs/asset-loading.md:161-166).
local function asset_start()
    if cfg.require_assets ~= 1 then return false end
    if state.asset_watch then return true end
    local ok, hd2 = pcall(require, 'mods/skyeshade/hd2runtime')
    if not ok or type(hd2) ~= 'table' or not hd2.require_assets then
        if not state.asset_note then
            state.asset_note = true
            log('ASSET the shared HD2Runtime is not installed - the leased projectile '
                .. 'will keep showing the missing-material icon')
        end
        return false
    end
    local ok2, watch = pcall(function()
        local w = hd2.weapon('P-92 Warrant')
        return hd2.require_assets({ id = 'homing-stim-lease', targets = { w } })
    end)
    if not ok2 or type(watch) ~= 'table' then
        log('ASSET require_assets refused: ' .. tostring(watch))
        return false
    end
    state.asset_watch = watch
    log(('ASSET asked the runtime to load the P-92 package (status=%s) - the '
        .. 'runtime polls it itself; the local mesh and materials arrive when it '
        .. 'reports complete.  This does not and cannot fix another machine\'s '
        .. 'placeholder: that machine needs the package resident, which only its '
        .. 'own game can arrange.'):format(tostring(watch.status)))
    return true
end

-- Poll the asset watch.  Current SDKs advance it themselves; the guarded tick is
-- for an older runtime whose handle really did have one.  Either way this only
-- ever reports, and a no-op is the normal case.
local function asset_tick()
    local aw = state.asset_watch
    if not aw then return end
    if type(aw.tick) == 'function' then pcall(aw.tick, aw, 0.016) end
    local status = aw.status
    if status == 'complete' then
        state.asset_watch = nil
        log('ASSET resident - the leased projectile has its mesh and materials now')
    elseif status == 'rejected' then
        state.asset_watch = nil
        log('ASSET rejected: ' .. tostring(aw.error)
            .. ' - on THIS machine the leased round will show the '
            .. 'missing-material icon')
    elseif status == 'cancelled' then
        state.asset_watch = nil
        log('ASSET cancelled')
    end
end

-- ---------------------------------------------------------------- self-heal
-- Heal yourself when you actually fire the P-11.
--
-- WHY THIS IS NOT DONE WITH THE ROUNDS
--   The first attempt made the stim fire a second pellet (the engine's shotgun
--   field, projectile.pellet_count) and steered it back into the shooter.  It
--   could not work, for two independent reasons found later:
--
--     * the leased P-92 seeker turns at about 30 degrees per second and flies at
--       about 90 m/s, so a round that leaves the muzzle pointing forward needs
--       seconds and hundreds of metres to come back - "curve round and stab me"
--       is not physically reachable at that turn rate; and
--     * the engine drops the firing entity from its own projectile's collisions,
--       so a round cannot hit the person who fired it.
--
--   Both of those are engine facts, not bugs to work around, so this uses the
--   mechanism the working P-11 self-heal mod uses instead: a REAL shot is the
--   trigger, and the heal is the game's own.  Nothing is written to process
--   memory and no game data is patched.
--
-- HOW IT WORKS
--   * `player_fired` is the runtime's event over the game's own projectiles_fired
--     mission stat, and it carries the shot count PER WEAPON SOURCE.  So
--     reloading, drawing the pistol or dry-firing heals nothing, and no memory
--     scanning is needed to notice a shot.
--   * the heal is `Player:heal(amount)`, which goes through the game's own
--     AddHealthFraction: it clamps to maximum health and refuses while the
--     avatar is downed or dead.
--   * the runtime polls the stat ten times a second, so a burst arrives as ONE
--     event carrying a count; heal_per_event and heal_cooldown are what stop a
--     held trigger from being a full heal.
--
-- HOW MUCH is a percentage of MAXIMUM health by default, because health is not
-- in a unit anybody can guess: Player:heal takes health points, and a fixed 25 of
-- them is a third of a Helldiver's health or a fortieth of it depending on the
-- scale the game uses.  heal_percent (35, about what a stim gives back) is the
-- knob; heal_amount overrides it with an absolute number when above zero.  The
-- log prints both the amount asked for and the maximum, so the scale is visible
-- instead of guessed at.
--
-- LIMBS are a separate path.  A stim repairs limb damage; AddHealthFraction does
-- not.  The runtime exposes it as hd2.actions.heal_limbs(player) from 0.30 on, so
-- it is called when it is there and skipped, once, with a log line when it is not.

-- The P-11 Stim Pistol as the runtime prints a shot source.  It names the source
-- as 16 hex digits and which byte order it uses is not worth assuming, so both
-- readings of the same 8 bytes are accepted, along with the plain name.
local P11_SOURCES = {
    D6B1FB05B9109353 = true,
    ['539310B905FBB1D6'] = true,
    ['P-11 Stim Pistol'] = true,
    ['P-11'] = true,
}

local HEAL = { sub = nil, tried = false, next_at = -1e9, heals = 0,
               limb_fn = nil, limb_how = nil, limb_said = false, why = nil }

local function source_is_p11(source)
    if type(source) ~= 'table' then return false end
    local t = source.type
    if type(t) == 'string' then
        local norm = t:upper():gsub('^0X', '')
        if P11_SOURCES[norm] then return true end
    end
    return type(source.name) == 'string' and P11_SOURCES[source.name] == true
end

-- One heal, with the cooldown applied.  Returns true when it happened.
local function heal_once()
    local now = os.clock()
    if now < HEAL.next_at then return false end
    local ok, hd2 = pcall(require, 'mods/skyeshade/hd2runtime')
    if not ok or type(hd2) ~= 'table' or type(hd2.local_player) ~= 'function' then
        return false
    end
    local okp, player = pcall(hd2.local_player)
    if not okp or player == nil then return false end

    local maximum
    if cfg.heal_amount <= 0 and type(player.max_health) == 'function' then
        local read, value = pcall(player.max_health, player)
        if read and type(value) == 'number' and value > 0 then maximum = value end
    end
    local amount = tonumber(cfg.heal_amount) or 0
    if amount <= 0 then
        if not maximum then
            -- no maximum to scale by: fall back to a fixed number rather than
            -- healing nothing at all
            amount = 25
        else
            amount = math.floor(maximum * (tonumber(cfg.heal_percent) or 0) / 100 + 0.5)
            if amount < 1 then amount = 1 end
        end
    end

    -- Player:heal(amount, opts) -> applied, reason.  opts.owner names the mod the
    -- action is credited to; the runtime needs it to attribute a mod-caused heal.
    local called, applied, why = pcall(player.heal, player, amount,
        { owner = MODULE_ID })
    if not called then
        if HEAL.refused ~= 'call' then
            HEAL.refused = 'call'
            log('SELF-HEAL the heal call failed: ' .. tostring(applied))
        end
        return false
    end
    -- applied is the health actually restored: 0 when already at full health,
    -- nil with a reason when the game refused (downed, dead, not a Helldiver).
    HEAL.next_at = now + (tonumber(cfg.heal_cooldown) or 0)

    local limbs = 'not asked'
    if cfg.heal_limbs == 1 then
        limbs = HEAL.limb_how or 'unsupported'
        if HEAL.limb_fn then
            local lok, lres, lwhy = pcall(HEAL.limb_fn, player, { owner = MODULE_ID })
            if lok and type(lres) == 'table' then
                local healed = lres.healed
                if type(healed) == 'table' and #healed > 0 then
                    limbs = table.concat(healed, '+')
                elseif lres.code then
                    limbs = tostring(lres.code) .. ': ' .. tostring(lres.reason)
                else
                    limbs = 'none damaged'
                end
            else
                limbs = 'refused: ' .. tostring(lwhy or lres)
            end
        end
    end

    if applied and applied > 0 then
        HEAL.heals = HEAL.heals + 1
        if cfg.debug == 1 then
            log(('SELF-HEAL +%s of %s max (asked %s), limbs %s (%d heals)')
                :format(tostring(applied), tostring(maximum or '?'), tostring(amount),
                    limbs, HEAL.heals))
        end
    elseif cfg.debug == 1 and why then
        log(('SELF-HEAL did nothing (%s; asked %s of %s max)')
            :format(tostring(why), tostring(amount), tostring(maximum or '?')))
    end
    return true
end

-- The fired event: {shots = n, sources = { {type, name, shots}, ... },
-- unattributed = n}.  Only a source that IS the P-11 counts.
local function on_fired(event)
    if cfg.enable ~= 1 or cfg.self_heal ~= 1 then return end
    local sources = type(event) == 'table' and event.sources or nil
    if type(sources) ~= 'table' then return end
    local shots = 0
    for _, source in ipairs(sources) do
        if source_is_p11(source) then shots = shots + (tonumber(source.shots) or 0) end
    end
    if shots <= 0 then return end
    local per = tonumber(cfg.heal_per_event) or 1
    local paid = 0
    while paid < per and paid < shots do
        if not heal_once() then break end
        paid = paid + 1
    end
end

-- The limb repair, when this runtime has one.  hd2.actions.heal_limbs(player) is
-- the documented shape (HD2Runtime 0.30+); older runtimes have hd2.actions but no
-- limb call in it, and that is worth one line in the log rather than a silent
-- no-op.
local function detect_limbs()
    if HEAL.limb_fn then return end
    local ok, hd2 = pcall(require, 'mods/skyeshade/hd2runtime')
    if not ok or type(hd2) ~= 'table' or type(hd2.actions) ~= 'table' then return end
    local fn = hd2.actions.heal_limbs
    if type(fn) == 'function' then
        HEAL.limb_fn, HEAL.limb_how = fn, 'hd2.actions.heal_limbs'
        log('SELF-HEAL limb repair available: ' .. HEAL.limb_how)
    elseif not HEAL.limb_said then
        HEAL.limb_said = true
        log('SELF-HEAL this runtime has no limb repair (hd2.actions.heal_limbs is '
            .. 'missing): main health heals, limb damage does not')
    end
end

-- Subscribe to player_fired.  Retried from the update loop, because the runtime
-- may load after this addon does.
local function subscribe_fired()
    if HEAL.sub or HEAL.tried then return end
    local ok, hd2 = pcall(require, 'mods/skyeshade/hd2runtime')
    if not ok or type(hd2) ~= 'table' then
        HEAL.why = 'HD2Runtime is not installed or not enabled'
        return
    end
    if type(hd2.events) ~= 'table' then
        HEAL.why = 'hd2.events is ' .. type(hd2.events)
        return
    end
    -- What a MOD calls is `hd2.events.on(name, cb, opts)`.  `subscribe` is the
    -- event engine's own internal function and is not on the api table - asking
    -- for only that name is exactly what made the reference's first build do
    -- nothing at all.  Both are tried, `on` first.
    local fn = hd2.events.on
    if type(fn) ~= 'function' then fn = hd2.events.subscribe end
    if type(fn) ~= 'function' then
        HEAL.why = 'hd2.events has neither on nor subscribe'
        return
    end
    HEAL.tried = true
    local id = 'homing_stim_self_heal'          -- keeps the subscription idempotent
    local okc, sub, a, b = pcall(fn, 'player_fired', on_fired,
        { owner = MODULE_ID, id = id })
    if not okc or type(sub) ~= 'table' then
        -- an explicit owner can be refused; let the runtime work it out instead
        local ok2, sub2, a2, b2 = pcall(fn, 'player_fired', on_fired, { id = id })
        if ok2 and type(sub2) == 'table' then
            HEAL.sub = sub2
            log('SELF-HEAL subscribed to player_fired (owner inferred by the runtime)')
            return
        end
        HEAL.why = tostring(a or b or a2 or b2 or sub)
        log('SELF-HEAL could not subscribe to player_fired: ' .. tostring(HEAL.why))
        return
    end
    HEAL.sub = sub
    log('SELF-HEAL subscribed to player_fired as ' .. MODULE_ID)
end

-- ---------------------------------------------------------------- camera
-- ---------------------------------------------------------------- main step
-- The addon installs ONE update hook.  That is deliberate: the reference split
-- its work between an update wrapper and a separate reticle hook and had to keep
-- their orderings straight, and a single entry point makes the per-frame order
-- explicit - clock, key, work.  The previous global `update` is preserved and
-- called at the very end, so another mod's hook is never swallowed.
local prev_update = rawget(_G, 'update')

-- F7 restarts the addon: everything it wrote is put back, then it arms again.
-- Two frames, because "release and take them again in the same frame" crashed
-- the live entity rotation in the reference's early versions.
local restart_at = nil
local function key_step()
    if not KS then return end
    local k = tonumber(cfg.key) or 118
    local down = KS(k) % 32768 >= 32768
    if down and not state.key_was_down then
        restart_at = state.frame
        log('F7 - restarting the addon')
    end
    state.key_was_down = down
    if restart_at and state.frame == restart_at + 1 then
        pcall(lease, false)
    elseif restart_at and state.frame == restart_at + 2 then
        restart_at = nil
        pcall(function() lease(true, ctx.weapon_id, ctx.weapon_res, ctx.weapon_txt) end)
        log('restart complete')
    end
end

local function homing_update(dt)
    -- the clock first: key_step and the throttles below both read state.frame,
    -- so incrementing it inside the protected block (as an earlier draft did)
    -- left the frame counter frozen whenever the block returned early
    state.frame = state.frame + 1
    ctx.frame = state.frame
    local ok, err = pcall(function()
        key_step()
        menu_step()
        -- SELF-HEAL attaches to the runtime's fired event, and the runtime may
        -- load after this addon does, so keep trying - once every five seconds,
        -- not once a frame.  It also picks up the option being switched on
        -- mid-session.
        if cfg.enable == 1 and cfg.self_heal == 1 and not HEAL.sub
            and (state.frame % 300) == 0 then
            HEAL.tried = false
            subscribe_fired()
            detect_limbs()
        end
        if cfg.enable ~= 1 then return end
        ctx.enable = true
        -- the package that gives the leased round its model and materials is
        -- loaded asynchronously: it only advances while its watch is ticked
        asset_tick()
        if cfg.require_assets == 1 and not state.asset_watch
            and not state.asset_done and (state.frame % 300) == 0 then
            -- retry every five seconds until it lands, in case the runtime was
            -- still starting when the first request went out
            if state.asset_ok then state.asset_done = true
            else state.asset_ok = asset_start() end
        end
        -- avatar (every frame) -> weapon in hand + lease + the reticle's
        -- permission slip (every frame) -> the candidate scan (throttled)
        local in_hand = frame_step()
        -- The UI draws from the weapon-in-hand state, NOT from a successful
        -- acquisition, so the ring stays up while you simply hold the P-11 and
        -- look around.  It also has to run whether or not a target exists.
        ui_step()
        if not in_hand then return end
        local tgt = pick_target()
        -- The reticle reads this stamp to tell "the addon is still tracking this
        -- target" from "this is the last position it ever saw".  Stamped here,
        -- where the step actually re-selects, so it goes stale by itself the
        -- moment this loop stops running for the weapon - which is the second,
        -- independent reason a box cannot outlive its lock.
        ctx.target_at = state.frame
        if tgt then
            ctx.target = tgt
            -- re-read the bone the scan already chose, so the marker and the
            -- round follow a walking unit instead of a third-of-a-second-old
            -- position (the reference's P15 fix)
            local node = tgt.node
            if node then
                local x, y, z = bone(tgt.unit, node)
                if not x and node ~= 0 then x, y, z = bone(tgt.unit, 0) end
                if x then tgt.position = { x, y, z } end
            end
            local px, py, pz = tgt.position[1], tgt.position[2], tgt.position[3]
            if ctx.origin then
                local dx = px - ctx.origin[1]
                local dy = py - ctx.origin[2]
                local dz = pz - ctx.origin[3]
                ctx.last_dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            end
            if cfg.debug == 1 and (state.frame % 120) == 0 then
                log(('LOCK %s (%s) %.1f m hp=%d/%d tier=%d candidates=%d')
                    :format(tgt.name, tgt.hurt and 'wounded' or 'full',
                        ctx.last_dist or -1, tgt.hp, tgt.mx,
                        tier_of(tgt.helldiver, tgt.hurt), #ctx.targets))
            end
        else
            ctx.target = nil
        end
        bind_projectiles()
        ui_step()
    end)
    if not ok then
        state.failures = state.failures + 1
        if state.failures < 5 or (state.frame % 600) == 0 then
            log('step error: ' .. tostring(err))
        end
    end
    if type(prev_update) == 'function' then return prev_update(dt) end
end
rawset(_G, 'update', homing_update)

-- A read-only surface for diagnosis and for the offline test suite.  It exposes
-- the pure decision functions - the tier order and the scorer - which is where
-- the friendly priority lives and the one part that can be tested without the
-- game.  Nothing here writes memory and nothing calls it at runtime.
state.test = {
    tier_of = tier_of,
    PRIO_NAME = PRIO_NAME,
    -- score a candidate list through the SAME best_for the addon uses, with the
    -- aim axis, cone, range and cover test supplied by the caller
    best = function(cands, cone, maxd, los_check)
        local tc, td, tl, ct = cfg.cone_deg, cfg.max_dist, cfg.los_check, ctx.targets
        cfg.cone_deg, cfg.max_dist, cfg.los_check = cone, maxd, los_check or 0
        ctx.targets = cands or {}
        -- origin at the world origin looking down +X, so a candidate's Y offset
        -- is what sets its aim angle
        local best = best_for({ 0, 0, 0 }, { 1, 0, 0 }, true)
        cfg.cone_deg, cfg.max_dist, cfg.los_check = tc, td, tl
        ctx.targets = ct
        return best
    end,
    -- the scan's "ignore full health" predicate, so the filter can be tested
    keeps_full = function(hp, mx, ignore_full)
        local hurt = hp < mx
        if ignore_full == 1 and not hurt then return false end
        return true
    end,
    -- SELF-HEAL's two pure decisions, exposed for the offline tests: whether a
    -- fired-event source is the P-11, and how many points a heal asks for.
    source_is_p11 = source_is_p11,
    -- the language decision, and a way to force it so the offline tests can
    -- check every language without a game to read the setting from
    language = function()
        local zh, code, how = client_is_chinese()
        return zh, code, how
    end,
    force_language = function(zh, code)
        LANG_CACHE.frame = state.frame
        LANG_CACHE.zh, LANG_CACHE.code, LANG_CACHE.how = zh, code, 'forced'
    end,
    zh_codes = ZH_CODES,
    utf8_clip = utf8_clip,    heal_points = function(percent, amount, maximum)
        if (tonumber(amount) or 0) > 0 then return tonumber(amount) end
        if not maximum then return 25 end
        local n = math.floor(maximum * (tonumber(percent) or 0) / 100 + 0.5)
        if n < 1 then n = 1 end
        return n
    end,
}

if cfg.autostart == 1 then
    state.armed = true
    state.asset_ok = asset_start()
    -- self-heal attaches to the runtime's fired event once, here; the update
    -- loop retries if the runtime is not up yet
    if cfg.self_heal == 1 then pcall(subscribe_fired) pcall(detect_limbs) end
end

-- Release the self-heal subscription on shutdown.  The memory writes need no
-- teardown (the game drops them with the process), but an event subscription
-- belongs to the runtime and outliving this addon would leave a callback running
-- against a dead module.
local prev_shutdown = rawget(_G, 'shutdown')
local function homing_shutdown(...)
    pcall(function()
        if HEAL.sub and type(HEAL.sub) == 'table'
            and type(HEAL.sub.unsubscribe) == 'function' then
            HEAL.sub:unsubscribe()
        end
    end)
    log(('Homing Stim shutting down (%d bind(s), %d self-heal(s))')
        :format(state.binds or 0, HEAL.heals or 0))
    if type(prev_shutdown) == 'function' then return prev_shutdown(...) end
end
rawset(_G, 'shutdown', homing_shutdown)

log(('Homing Stim %s ready  cfg=%s  log=%s'):format(REVISION, tostring(CFG_PATH), tostring(LOG_PATH)))
log('Homing Stim: P-11 Stim Pistol only. Targets FRIENDLY units - Helldivers and '
    .. 'SEAF AI. Priority: wounded Helldiver > Helldiver > wounded SEAF > SEAF.')
