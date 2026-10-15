# NOTICE / 声明

Homing Stim v1.0.12
Copyright (c) 2026 cancan2333 · MIT (see [LICENSE](LICENSE))

This project is **not** an original work from scratch. It is a derivative of
community work, and the lineage is set out in full below so that every author
keeps the credit they are owed.

本项目**不是**从零原创，而是社区成果的衍生作品。下面把完整的来源链条列清楚，
以确保每一位作者都得到应有的署名。

---

## 1. Upstream / 上游来源

**Homing Stim is derived from:**

> **DIY Your Weapon to Shoot Like Donk APW-1（反器材锁头 mod / DIY-able）**
> https://ayakamods.com/mods/diy-your-weapon-to-shoot-like-donk-apw-1-%E5%8F%8D%E5%99%A8%E6%9D%90%E9%94%81%E5%A4%B4mod-diy-able.4226/

**本 mod 由以下作品修改而来：**

> **DIY Your Weapon to Shoot Like Donk APW-1（反器材锁头 mod / DIY-able）**
> https://ayakamods.com/mods/diy-your-weapon-to-shoot-like-donk-apw-1-%E5%8F%8D%E5%99%A8%E6%9D%90%E9%94%81%E5%A4%B4mod-diy-able.4226/

That addon introduced the core technique this mod is built on: swapping a
weapon's projectile for the **P-92 Warrant** projectile entity (written into
`+0x28` of the weapon's `ProjectileWeaponComponentData` row) so the round
carries the game's own `SeekingMissileComponentData`, and then binding a target
through the game's seeking manager with `publish(FIELD_TARGET)`.

那个 addon 奠定了本 mod 的核心技术：把武器的弹丸换成 **P-92 法令**的弹丸实体
（写进武器 `ProjectileWeaponComponentData` 行的 `+0x28`），让弹丸带上游戏自己的
`SeekingMissileComponentData`，再通过 `publish(FIELD_TARGET)` 往游戏的制导管理器里绑目标。

## 2. Direct development base / 直接开发基础

**Guided Rounds v1.8.0 / v1.8.5** — cancan2333 & SoS2430

<https://github.com/cancan23333>

Code **ported** from it into this project (not merely inspired by):

- the aim-cone / camera-axis acquisition and the `best_for()` scoring model;
- the muzzle-origin line-of-sight raycast and its per-frame ray budget;
- `resolve_settings()` — the **private per-weapon settings row** (the forward and
  reverse maps plus the count), so the shared resource row is never written;
- the **lock reticle module** — range ring, lock markers, world-space target box,
  and the camera pose that feeds the acquisition cone;
- the **target-box release fix** (hide through `reset` + a transparent line +
  `dispatch`, release the handle only on a real destroy) and the `target_at`
  freshness stamp from **v1.8.5** items 25 and 26;
- the **asset watch** handling for the leased projectile's package.

从其中**移植**进本项目的代码（不只是「受启发」）：

- 瞄准锥 / 相机轴索敌与 `best_for()` 评分模型；
- 以枪口为起点的视线射线检测及其每帧射线预算；
- `resolve_settings()` —— **专属的每武器设置行**（前向表、反向表与计数），
  因此**共享资源行从头到尾不会被写入**；
- **锁定 UI 模块** —— 范围环、锁定标记、世界空间的目标方框，以及为索敌锥提供
  相机姿态的部分；
- **目标方框释放的修复**（先用 `reset` + 全透明线 + `dispatch` 隐藏，只在真的销毁
  成功时才放掉句柄）与 `target_at` 新鲜度帧戳，来自 **v1.8.5 第 25、26 条**；
- 租用弹丸资源包的 **asset watch** 处理。

## 3. Data / 数据

**Helldiver and SEAF resource hashes** are taken from the community
*Helldivers 2 Resource ID* workbook (《绝地潜兵2资源ID》表). The SEAF whitelist is
derived from every row whose model path is `cha_seaf/...`, with the SEAF's own
weapons, backpacks and other *items* excluded by name.

**潜兵与 SEAF 的资源哈希**取自社区的《绝地潜兵2资源ID》表。SEAF 白名单由所有模型路径为
`cha_seaf/...` 的行推导而来，并按名称排除了 SEAF 自己的武器、背包等**装备**。

## 4. Required third-party software / 必需的第三方软件

Not bundled with this mod, but required to run it. All credit to their authors.

本 mod 不包含它们，但运行必需。版权与功劳归其作者。

| Component | Author | Source |
| --- | --- | --- |
| Bingus Shared Loader | CowboyBingus | <https://ayakamods.com/mods/bingus-shared-loader.3861/> |
| HD2Runtime | skyeshade | <https://ayakamods.com/mods/hd2runtime.4260/> |
| Vanilla Plus Megapack (provides the MODS tab) | CowboyBingus | <https://ayakamods.com/mods/vanilla-plus-megapack.3913/> |

## 5. Game assets / 游戏素材

Helldivers 2, its assets, names and trademarks belong to **Arrowhead Game
Studios** and **Sony Interactive Entertainment**. This project ships **no game
art, models, audio or data**; it manipulates the running game from Lua and
references resources that are already installed. It is unofficial and is not
endorsed by or affiliated with Arrowhead Game Studios.

《绝地潜兵2》及其素材、名称与商标归 **Arrowhead Game Studios** 与
**Sony Interactive Entertainment** 所有。本项目**不包含任何游戏美术、模型、音频或数据**；
它只是用 Lua 操作运行中的游戏，并引用已安装的资源。本项目为非官方作品，
与 Arrowhead Game Studios 无隶属关系，也未获其背书。

---

## Note on licensing / 关于许可的说明

This repository is licensed **MIT** (see [LICENSE](LICENSE)). That covers the
original code written here.

本仓库以 **MIT** 协议开源（见 [LICENSE](LICENSE)），覆盖的是本项目自行编写的代码。

The upstream works above are **third-party projects with their own terms**, and
this project does not relicense them. In particular:

- **DIY Your Weapon to Shoot Like Donk APW-1 (DIY-able)** — the mod this project
  is derived from. Its distribution terms were not stated in the material
  available here.
- **Guided Rounds** — by cancan2333 & SoS2430. Note that this project's author is
  also a Guided Rounds author, and the code ported from it is used with that
  author's knowledge.

If you intend to redistribute this project, **check those upstream terms first**
and honour them; if any upstream author objects to something here, contact the
maintainer and it will be corrected or removed.

上述上游作品是**拥有各自条款的第三方项目**，本项目**不会**替它们重新授权。特别是：

- **DIY Your Weapon to Shoot Like Donk APW-1（DIY-able）** —— 本项目的上游来源，
  可在手头资料中未见到其分发条款说明。
- **Guided Rounds** —— 作者 cancan2333 & SoS2430。需说明的是，本项目作者本身也是
  Guided Rounds 的作者之一，从其中移植的代码在该作者知情的情况下使用。

如果你打算**再分发**本项目，请**先确认上述上游条款**并遵守；若任何上游作者对这里的
内容有异议，请联系维护者，我们会更正或移除。
