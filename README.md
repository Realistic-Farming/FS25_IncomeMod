<div align="center">

# 💰 FS25 Income Mod
### *Passive Income & Earnings Tracker*

[![Downloads](https://img.shields.io/github/downloads/TheCodingDad-TisonK/FS25_IncomeMod/total?style=for-the-badge&logo=github&color=4caf50&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_IncomeMod/releases)
[![Release](https://img.shields.io/github/v/release/TheCodingDad-TisonK/FS25_IncomeMod?style=for-the-badge&logo=tag&color=76c442&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_IncomeMod/releases/latest)
[![License](https://img.shields.io/badge/license-CC%20BY--NC--ND%204.0-lightgrey?style=for-the-badge&logo=creativecommons&logoColor=white)](https://creativecommons.org/licenses/by-nc-nd/4.0/)
<a href="https://paypal.me/TheCodingDad">
  <img src="https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif" alt="Donate via PayPal" height="50">
</a>

<br>

> *"My farm runs better when the bills aren't piling up while I sleep. A small passive income keeps things moving without feeling like a cheat."*

<br>

**FS25's economy stops the moment you stop working. This mod keeps the money flowing.**

Automatic hourly or daily payments to every farm on the map — scaled by difficulty, boosted by multiplier, adjusted by season. A live HUD tracks your earnings at a glance. A full income report shows you the history. And in multiplayer, every farm gets paid independently, server-side, no duplicates.

`Singleplayer` • `Multiplayer (server-authoritative)` • `Persistent saves` • `10 Languages`

</div>

> [!TIP]
> Want to be part of our community? Share tips, report issues, and chat with other farmers on the **[FS25 Modding Community Discord](https://discord.gg/Th2pnq36)**!

---

## ✨ Features

### 💵 Passive Income System

Automatic payments that fit your playstyle — hourly for steady trickle, daily for bigger lump sums.

| | Feature | Description |
|---|---|---|
| ⏱️ | **Hourly or Daily payments** | Choose your cadence — same total, different rhythm |
| 🎚️ | **Difficulty presets** | Easy · Normal · Hard base amounts |
| 🔢 | **Income multiplier** | 1x · 2x · 5x · 10x on top of the base |
| 🌿 | **Custom amount** | Override presets with any value you want |
| 🌸 | **Seasonal modifiers** | Spring/Summer/Autumn/Winter each adjust the payout |
| 🌐 | **Multiplayer** | Every farm paid independently, server-side only |
| 💾 | **Full persistence** | Settings and timer state saved per-savegame |

### 📊 Income HUD

Press `I` to toggle the live earnings overlay. Right-click the panel to enter **Edit Mode** — drag it anywhere on screen, drag a corner to resize, right-click again to lock it in.

Shows at a glance:
- Current income mode and amount
- Recent payment history (last entries)
- Seasonal multiplier when active

### 📋 Income Report Dialog

Press `U` to open the full income report. Includes:
- Settings summary (mode, difficulty, multiplier)
- Total and average earnings
- Complete payment history with day, time, type, amount, and seasonal modifier

---

## ⚙️ Settings

Open via **ESC → Settings → Game Settings → Income Mod**.

| Setting | Default | Description |
|---|---|---|
| **Enable Mod** | On | Master on/off switch |
| **Pay Mode** | Hourly | Hourly or Daily payments |
| **Difficulty** | Normal | Sets the base payment amount |
| **Income Multiplier** | 1x | Multiplies the base payment |
| **Custom Amount** | 0 | Overrides difficulty amount (0 = use difficulty preset) |
| **Seasonal Effects** | Off | Applies seasonal multipliers to each payment |
| **Notifications** | On | Pop-up message on each payment |
| **Show HUD** | On | Enable or disable the HUD overlay |

> [!NOTE]
> In multiplayer, settings are **server-authoritative** — the host's configuration applies to all players.

---

## 💡 Income Calculation

```
finalAmount = baseAmount × incomeMultiplier × seasonalMultiplier

baseAmount = customAmount > 0 ? customAmount : difficultyAmount
```

| Difficulty | Base Amount |
|---|---|
| Easy | $5,000 |
| Normal | $2,400 |
| Hard | $1,100 |

| Season | Multiplier |
|---|---|
| 🌱 Spring | 0.8x |
| ☀️ Summer | 1.0x |
| 🍂 Autumn | 1.2x |
| ❄️ Winter | 0.7x |

---

## 🛠️ Installation

**1. Download** `FS25_IncomeMod.zip` from the [latest release](https://github.com/TheCodingDad-TisonK/FS25_IncomeMod/releases/latest).

**2. Copy** the ZIP (do not extract) to your mods folder:

| Platform | Path |
|---|---|
| 🪟 Windows | `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\` |
| 🍎 macOS | `~/Library/Application Support/FarmingSimulator2025/mods/` |

**3. Enable** *Income Mod* in the in-game mod manager.

**4. Load** any career save — income starts automatically.

---

## 🎮 Quick Start

```
1. Load your farm — payments begin immediately
2. Press I          → open the Income HUD overlay
3. Press U          → open the full Income Report
4. ESC → Settings   → configure difficulty, mode, and multiplier
5. Right-click HUD  → enter Edit Mode to drag and resize the panel
6. Right-click again → lock position and save
```

---

## ⌨️ Key Bindings

| Key | Action |
|---|---|
| `I` | Toggle Income HUD overlay |
| `U` | Open Income Report dialog |
| `RMB` *(on HUD)* | Toggle Edit Mode — drag with `LMB` to reposition, corner to resize |

Both keys can be rebound in the game's control settings.

---

## 🖥️ Console Commands

Open the developer console with the **`~`** key:

| Command | Arguments | Description |
|---|---|---|
| `income` | — | List all Income Mod commands |
| `incomeStatus` | — | Show current settings and status |
| `incomeEnable` / `incomeDisable` | — | Toggle mod on or off |
| `IncomeShowSettings` | — | Display all current settings |
| `IncomeSetDifficulty` | `1\|2\|3` | Set difficulty (1=Easy, 2=Normal, 3=Hard) |
| `IncomeSetPayMode` | `1\|2` | Set Hourly (1) or Daily (2) payments |
| `IncomeSetNotifications` | `true\|false` | Toggle payment notifications |
| `IncomeSetCustomAmount` | `<n>` | Set custom payment amount (0 = use difficulty) |
| `IncomeToggleHUD` | `true\|false` | Show or hide the HUD overlay |
| `IncomeTestPayment` | — | Trigger a $1 test payment immediately |
| `IncomeResetSettings` | — | Reset all settings to defaults |
| `IncomeHistory` | — | Show last 10 payment records |
| `IncomeNext` | — | Show when the next payment fires |

---

## 🌐 Multiplayer

- Payments are processed **server-side only** — no duplicate payouts.
- Every farm (except the spectator farm) receives its payment independently.
- Money is synced to all clients automatically.
- Notifications appear on clients only, never on dedicated servers.

---

## 💾 Save Files

Settings and timer state are saved per-savegame to prevent missed or double payments on reload.

| File | Contents |
|---|---|
| `{savegame}/FS25_IncomeMod.xml` | All settings |
| `{savegame}/FS25_IncomeMod_state.xml` | Timer state (lastHour, lastDay) |

---

## 🤝 Contributing

Found a bug? [Open an issue](https://github.com/TheCodingDad-TisonK/FS25_IncomeMod/issues/new/choose) — the template will guide you through what information is needed.

---

## 📋 Changelog

- **2.1.7.0** - Release gate. Experimental systems ship locked until deliberately released. Turn them on under the mod's settings, independent of difficulty. The C3 loan elaboration (escalation and Time Guard compounding) stays locked until released; the interest-free bridge loan and the floor escape remain available.

---

## 📝 License

This mod is licensed under **[CC BY-NC-ND 4.0](https://creativecommons.org/licenses/by-nc-nd/4.0/)**.

You may share it in its original form with attribution. You may not sell it, modify and redistribute it, or reupload it under a different name or authorship. Contributions via pull request are explicitly permitted and encouraged.

**Author:** TisonK · **Version:** 2.1.7.0

© 2026 TisonK — See [LICENSE](LICENSE) for full terms.

---

<div align="center">

*Farming Simulator 25 is published by GIANTS Software. This is an independent fan creation, not affiliated with or endorsed by GIANTS Software.*

*Your farm never sleeps. Neither does the income.* 💰

</div>
