# Homing Stim

**P-11 治疗剂手枪 · 制导治疗弹 · 射击自我恢复** — 把 P-11 变成一把会自己找队友、开枪还能治自己的治疗枪。
**P-11 Stim Pistol · guided healing darts · heal yourself when you fire.**

**[English](#english)** · **[中文](#中文)**

v1.0.12 · by **cancan2333** · **MIT** · [GitHub](https://github.com/cancan23333/Helldiver2-p-11-Homing-Stim-self-heal)

---

## 中文

### 它是什么

把 **P-11 治疗剂手枪**变成一把**会自己找队友的治疗枪**：扣下扳机，弹丸出膛后自动转向，追踪索敌范围内**残血的友军**，
并且**开枪的同时也治疗你自己**。

它锁定的是**友军**，不是敌人：潜兵和 SEAF AI NPC。锁定优先度固定为：

1. **残血潜兵**
2. **满血潜兵**
3. **残血 SEAF**
4. **满血 SEAF**

上一档永远压过下一档；同一档内，离准心最近的胜出。

### 亮点

- **只改 P-11** —— 固定为 P-11 治疗剂手枪，不碰任何其他武器，也不改它的伤害、初速或弹道。
- **锁定友军，四档优先度** —— 潜兵用「本地玩家自己的实体类型」判定（不需要外部哈希表，游戏更新也不会失效）；
  SEAF 按**完整的 20 个身体白名单**放行。
- **射击时自我恢复** —— 真实开枪就给自己回血。挂的是运行时的 `player_fired` 事件（游戏自己的 `projectiles_fired`
  统计），所以**换弹、拔枪、空扳机都不会回血**；回血走游戏自己的 `AddHealthFraction`，**自动封顶到最大血量**，
  倒地或死亡时会被拒绝。还能**顺便修复部位损伤**（头/胸/双手/双膝）。**不写内存、不改游戏数据。**
- **屏幕锁定 UI** —— 索敌**范围圆环**、目标身上的**锁定标记**（锁定完成时旋转收拢）、目标外面的**锁定部位方框**，
  三者各自独立开关。
- **掩体判断** —— 你和目标之间有实体挡住时不锁定。射线**从枪口发出**，判的就是子弹这条路，而不是相机的视线。
- **自己绑定目标** —— 引擎没锁上时由 mod 在瞄准锥里挑一个绑上去，建议保持开启。
- **菜单自动双语** —— **简体中文和繁体中文显示中文，其它任何语言显示英文**，游戏内改语言**不用重启**就会跟着变。
- **实时可调** —— 12 个选项全部在游戏内 MODS 菜单里，只占 **1 个分类**，不会挤掉别的 mod 的分类按钮。
- **F7 一键复位** —— 偶发「锁不上」时按 F7：把写过的值全部还原再重新武装，不用重开游戏。

### 依赖项

三个都需要，而且都必须启用。本 mod 会在启动时自行 require 前两个，**不需要手动排序**。

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| [Bingus Shared Loader](https://ayakamods.com/mods/bingus-shared-loader.3861/) | v15+ / API 1 | 加载器 |
| [HD2Runtime](https://ayakamods.com/mods/hd2runtime.4260/) | v0.40.0+ | 资源包加载、`player_fired` 事件与治疗函数 |
| [Vanilla Plus Megapack](https://ayakamods.com/mods/vanilla-plus-megapack.3913/) | — | 提供游戏内的 MODS 页签（没有它就只能在 cfg 里改设置） |

### 安装与使用

1. 用管理器导入本压缩包 → 启用 → **purge & redeploy** → 重启游戏。
2. 确认上面三个依赖都启用。
3. 带上 **P-11 治疗剂手枪**。
4. 逃生菜单 → **MODS** 页签 → **HOMING STIM** 分类改设置；改完按提示 **APPLY** 才会生效。
5. 对着队友方向扣扳机，弹丸会自己转向他。
6. 锁不上时按 **F7**。

### 选项

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| 启用 / ENABLE | 开 | 总开关。关闭会把所有写过的内存还原成出厂值 |
| 锁定范围锥角（度） | 15 | 友军偏离准心多少度仍会被锁定，**同时决定范围环的大小** |
| 锁定距离（米） | 120 | 弹丸接受目标的最远距离 |
| 射击时自我恢复 | 关 | 真实开枪就给自己回血 |
| 自我恢复量（最大血量%） | 35 | 约等于一针兴奋剂的量 |
| 自我恢复冷却（秒） | 0.5 | 两次治疗之间至少隔多少秒 |
| 满血目标过滤 | 关 | 开启后不锁定满血的友军，只锁真正受伤的目标 |
| 显示范围环 / 显示锁定标记 / 显示锁定部位 | 开 | 三个锁定 UI 元素，各自独立开关 |
| 掩体判断 | 开 | 有实体挡住时不锁定 |
| 自己绑定目标 | 开 | 引擎没锁上时由 mod 兜底绑定，**建议保持开启** |

> **提示**：范围环的屏幕半径是 `tan(锥角) × (屏高/2) ÷ tan(视场角/2)`，所以**锥角只有小于当前视场角的一半时，
> 圆环才留在屏幕内**。出厂值 15° 在所有视场角下都看得见；调到 30° 左右，开镜时圆环就会跑出屏幕。

#### 只在 cfg 里的设置

`%LOCALAPPDATA%\HomingStim\homing_stim.cfg`（首次运行自动写出）

| 键 | 说明 |
| --- | --- |
| `heal_amount` | 改用绝对血点；0 = 用上面的百分比 |
| `heal_limbs` | 是否顺便修复部位损伤（需要 HD2Runtime 0.30+） |
| `heal_per_event` | 一个已射击事件最多付几次（连射想回得更快就调 2–3） |
| `debug`、`los_debug`、`los_foliage`、`bind_delay`、`cone_fallback` | 排查用 |

### 已知问题

- **主机视角下，别人看你射击会出现粉色问号。**
  本 mod 必须把弹丸换成带制导组件的实体，而**这个实体由射手生成并同步给其他人**，所以**每台机器都必须自己备好它的资源包**。
  **没装本 mod 的机器上没有这个资源包，就会把你的弹丸画成一个粉色问号。**
  这是游戏机制（资源加载是本机的），**无法从本机修复**，也不是本 mod 的 bug。
  缓解办法：让队友也装本 mod；或队里有人**带着 P-92 法令手枪**（那样该资源包会常驻）。
- **做为客机时可能不会出现问号。** **推荐以客机身份加入别人的房间**：房主（主机）通常已经带着把他的弹丸资源包
  加载好了，所以你看到的弹丸模型多半是正常的。
- **可能会出现个别 SEAF 无法锁定。** SEAF 是按**实体类型哈希白名单**放行的。如果游戏版本更新后出现新的 SEAF 型号、
  或者某个单位的实体类型不在名单里，它就会**完全进不了候选**。遇到时请把日志里的
  `SCAN not-admitted entity types` 那行发出来，那一行会直接打出被拒绝的实体哈希，加进名单即可。
- **和 Guided Rounds 同时启用会冲突。** 两者都会抢 P-11 的设置行，请**只启用其中一个**。
- **SEAF 不一定每次都测得到。** SEAF 只在**带对应词条的星球**上出现；没有词条时呼叫 SEAF 增援会让游戏在鹈鹕
  落地后崩溃。潜兵那条路在双人游戏里随时可测。
- **不开加速/耐力。** 一针兴奋剂做三件事：回血、修部位、给几秒加速。本 mod 做到**前两件**；加速属于状态效果，
  运行时**明确不支持**施加 stim 类状态。

### 日志与排查

`%LOCALAPPDATA%\HomingStim\HomingStim.log`

| 日志行 | 含义 |
| --- | --- |
| `READY - P-11 Stim Pistol located` | 枪认出来了、租约已生效 |
| `SCAN not-admitted entity types` | **被拒绝的实体类型及次数**——锁不上的单位会在这里显示它自己的哈希 |
| `SCAN ... seek active=...` | 制导管理器里的弹丸数 |
| `LEASE ok` / `RESTORE` | 租约的取得与归还 |
| `BIND #n -> ...` | 一次成功的目标绑定，含名称、距离和档位 |
| `SELF-HEAL subscribed to player_fired` | 自我恢复挂上了事件 |
| `ASSET resident` / `ASSET rejected` | 弹丸资源包在本机的加载结果 |

### 制作与致谢

- 本 mod 由 **[DIY Your Weapon to Shoot Like Donk APW-1（反器材锁头 mod / DIY-able）](https://ayakamods.com/mods/diy-your-weapon-to-shoot-like-donk-apw-1-%E5%8F%8D%E5%99%A8%E6%9D%90%E9%94%81%E5%A4%B4mod-diy-able.4226/)** 修改而来。
- 制导机制、内存偏移与大部分实现在 **Guided Rounds v1.8.0 / v1.8.5**（作者 cancan2333 & SoS2430）的成果之上完成，
  本 mod 也从其中移植了锁定 UI、专属设置行与方框释放的修复。
- **潜兵与 SEAF 的资源哈希**取自社区的《绝地潜兵2资源ID》表。
- **Bingus Shared Loader** 与 **HD2Runtime** 由 CowboyBingus / skyeshade 开发。
- 游戏素材与商标版权属于 **Arrowhead Game Studios**。

详见 [NOTICE.md](NOTICE.md)。

### 许可

[MIT](LICENSE)。

---

## English

### What it is

Turns the **P-11 Stim Pistol** into a stim gun that **finds your teammates for you**: pull the trigger and the dart steers
itself in flight toward a **wounded friendly** inside your lock cone — and **heals you as you fire**.

It locks **friendlies**, never enemies: Helldivers and SEAF AI NPCs. The priority order is fixed:

1. **Wounded Helldiver**
2. **Full-health Helldiver**
3. **Wounded SEAF**
4. **Full-health SEAF**

A higher tier always beats a lower one; inside a tier, whichever unit is closest to your crosshair wins.

### Highlights

- **P-11 only.** No other weapon is touched, and the P-11 keeps its own damage, muzzle velocity and ballistics.
- **Friendly-only locking with the four-tier priority above.** Helldivers are recognised by the local avatar's own entity
  type (no external hash list, so it cannot go stale); SEAF are admitted from a **complete 20-entry whitelist** of every
  SEAF body.
- **Heal yourself when you fire.** A **real** shot heals you. It hooks the runtime's `player_fired` event (the game's own
  `projectiles_fired` stat), so reloading, drawing the pistol or dry-firing heals nothing; the heal is the game's own
  `AddHealthFraction` — it clamps at maximum health and is refused while you are downed or dead. It also repairs
  **limb damage** (head / chest / hands / knees). **Nothing is written to memory and no game data is patched.**
- **On-screen lock UI.** A **range ring**, the stock **lock markers** on the target (they spin in as the lock completes)
  and a **wire box** on the locked unit — each with its own switch.
- **Cover check.** A unit with no line of sight is not locked. The ray is fired **from the muzzle**, so it tests the path
  the dart would actually take rather than the camera's.
- **Bind the target ourselves** when the engine does not lock by itself. Recommended to leave on.
- **The MODS tab follows your language.** Chinese for Simplified and Traditional Chinese, **English for every other
  language**, and it follows a language change in game **without a restart**.
- **Tune it live.** All 12 options live in the in-game MODS tab (including two sliders) and use **one single category**,
  so no other mod's category button is pushed off the tab.
- **F7 to reset.** If it occasionally stops locking, press F7: everything written is restored and re-armed, with no need
  to restart the game.

### Requirements

All three are required and must be enabled. The mod requires the first two itself at startup, so **no manual load order
is needed**.

| Dependency | Version | Why |
| --- | --- | --- |
| [Bingus Shared Loader](https://ayakamods.com/mods/bingus-shared-loader.3861/) | v15+ / API 1 | the loader |
| [HD2Runtime](https://ayakamods.com/mods/hd2runtime.4260/) | v0.40.0+ | package loading, the `player_fired` event and the heal |
| [Vanilla Plus Megapack](https://ayakamods.com/mods/vanilla-plus-megapack.3913/) | — | provides the in-game MODS tab (without it you can only edit the cfg file) |

### Install and use

1. Import the zip with your mod manager, enable it, **purge & redeploy**, then restart the game.
2. Check that all three dependencies above are enabled.
3. Equip the **P-11 Stim Pistol**.
4. Escape menu → **MODS** tab → **HOMING STIM** to tune it. Changes take effect when you **APPLY** them.
5. Pull the trigger toward a teammate; the dart steers itself into them.
6. If it stops locking, press **F7**.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| ENABLE | on | Master switch. Turning it off restores everything it wrote |
| LOCK ANGLE (deg) | 15 | How far off the crosshair a friendly may sit; it also sizes the range ring |
| LOCK RANGE (m) | 120 | Furthest friendly the dart will accept |
| HEAL YOURSELF WHEN FIRING | off | A real shot heals you |
| SELF-HEAL AMOUNT (% max HP) | 35 | About what a stim gives back |
| SELF-HEAL COOLDOWN (s) | 0.5 | Least time between two heals |
| IGNORE FULL HEALTH | off | When on, a full-health friendly is never locked |
| RANGE RING / LOCK MARKERS / TARGET BOX | on | The three lock-UI elements, each with its own switch |
| REQUIRES LINE OF SIGHT | on | Do not lock through solid cover |
| BIND TARGET OURSELVES | on | Pick a target when the engine does not; recommended on |

> **Tip:** the ring's radius is `tan(angle) × (screen height / 2) ÷ tan(fov / 2)`, so it stays on screen only while the
> angle is narrower than **half your current FOV**. 15 degrees stays visible at every FOV; around 30 it leaves the screen
> when you aim down the sights.

#### Settings that live only in the cfg file

`%LOCALAPPDATA%\HomingStim\homing_stim.cfg` (written on first run)

| Key | Meaning |
| --- | --- |
| `heal_amount` | Use absolute health points instead of the percentage above |
| `heal_limbs` | Also repair limb damage (needs HD2Runtime 0.30+) |
| `heal_per_event` | Most heals one fired event may pay for (2-3 heals faster on auto) |
| `debug`, `los_debug`, `los_foliage`, `bind_delay`, `cone_fallback` | diagnostics |

### Known issues

- **Pink question mark on other players' screens when YOU are the host.**
  The mod has to swap the projectile for an entity that carries the guidance component, and **that entity is spawned by
  the shooter and replicated**, so **every machine must already have its package loaded**. A machine that does not run
  this mod has no such package and draws your dart as a pink question mark. This is game behaviour (asset loading is per
  machine), it **cannot be fixed from your side**, and it is not a bug in this mod. Mitigation: have your teammates
  install this mod too, or have someone in the lobby **carry a P-92 Warrant** (which keeps the package resident).
- **As a client the question mark may not appear.** **Joining someone else's lobby as a client is recommended:** the host
  has usually already loaded the package for their own dart, so the model you see is most likely correct.
- **A few individual SEAF may not lock.** SEAF are admitted from a **whitelist of entity-type hashes**. If a game update
  adds a new SEAF variant, or a unit's entity type is not in the list, it **cannot enter the candidate list at all**. If
  you hit one, send the `SCAN not-admitted entity types` line from the log — it prints the refused hash directly.
- **Conflicts with Guided Rounds.** Both claim the P-11's settings row. Enable **only one**.
- **SEAF may not always be testable.** SEAF only spawn on **planets with the right modifier**; calling SEAF
  reinforcements without it crashes the game after the Pelican lands. The Helldiver path is testable any time in a
  two-player game.
- **No speed or stamina buff.** A stim does three things: heals, repairs limbs, and grants a few seconds of speed. This
  mod does the **first two**; the speed part is a status effect and the runtime **does not support** applying stim-type
  statuses.

### Log and troubleshooting

`%LOCALAPPDATA%\HomingStim\HomingStim.log`

| Line | Meaning |
| --- | --- |
| `READY - P-11 Stim Pistol located` | the gun was found and the lease is in place |
| `SCAN not-admitted entity types` | **the entity types that were refused** — an un-lockable unit shows its own hash here |
| `SCAN ... seek active=...` | how many rounds are in the seeking manager |
| `LEASE ok` / `RESTORE` | the lease being taken and given back |
| `BIND #n -> ...` | one successful target binding, with name, range and tier |
| `SELF-HEAL subscribed to player_fired` | the self-heal hooked the fired event |
| `ASSET resident` / `ASSET rejected` | the dart package's load result on this machine |

### Credits

- Derived from **[DIY Your Weapon to Shoot Like Donk APW-1 (DIY-able)](https://ayakamods.com/mods/diy-your-weapon-to-shoot-like-donk-apw-1-%E5%8F%8D%E5%99%A8%E6%9D%90%E9%94%81%E5%A4%B4mod-diy-able.4226/)**.
- The guidance mechanism, memory offsets and much of the implementation build on **Guided Rounds v1.8.0 / v1.8.5** by
  cancan2333 & SoS2430, from which the lock UI, the private settings row and the box-release fix are ported.
- The **Helldiver and SEAF resource hashes** come from the community Helldivers 2 resource-ID workbook.
- **Bingus Shared Loader** and **HD2Runtime** are by CowboyBingus / skyeshade.
- Game assets and trademarks belong to **Arrowhead Game Studios**.

See [NOTICE.md](NOTICE.md).

### License

[MIT](LICENSE).
