# FS25 Income Mod

![Downloads](https://img.shields.io/github/downloads/TheCodingDad-TisonK/FS25_IncomeMod/total?style=for-the-badge)
![Release](https://img.shields.io/github/v/release/TheCodingDad-TisonK/FS25_IncomeMod?style=for-the-badge)
![License](https://img.shields.io/badge/license-All%20Rights%20Reserved-red?style=for-the-badge)

A configurable passive income system for **Farming Simulator 25**. Earn automatic hourly or daily payments across all farms, with difficulty tiers, seasonal modifiers, income multipliers, and full multiplayer support.

Mod page: https://www.kingmods.net/en/fs25/mods/74020/income-mod

---

## Features

- **Passive Income** — Automatic hourly or daily payments to every farm.
- **Difficulty Presets** — Easy ($5,000), Normal ($2,400), or Hard ($1,100) base amounts.
- **Income Multiplier** — Boost payments by 1x, 2x, 5x, or 10x.
- **Seasonal Effects** — Optional income variation by season (Spring 0.8x · Summer 1.0x · Autumn 1.2x · Winter 0.7x).
- **Custom Amount** — Override any difficulty with your own payout value.
- **HUD Overlay** — On-screen panel showing current income, mode, and recent payment history. Toggle with **I**.
- **Income Report Dialog** — Full-screen report with settings summary, earnings stats, and complete payment history. Open with **U**.
- **In-game Settings Panel** — Configure everything from the pause menu without using console commands.
- **Payment Notifications** — Optional pop-up messages when income arrives.
- **Payment History** — Tracks your last 10 payments with day, time, type, amount, and seasonal multiplier.
- **Singleplayer & Multiplayer** — Per-farm payments in MP; server-side guard prevents duplicate payouts.
- **Persistent Settings** — All settings saved per-savegame; timer state saved to prevent missed or double payments on reload.

---

## Installation

1. Download the mod `.zip` file.
2. Place the `.zip` into your FS25 mods folder:
   `Documents/My Games/Farming Simulator 25/mods`
3. Launch the game and enable the mod in the Mod Manager.
4. Load your save — income starts automatically.

---

## Keybindings

| Key | Action |
|-----|--------|
| `I` | Toggle Income HUD overlay |
| `U` | Open Income Report dialog |

Both keys can be rebound in the game's control settings.

---

## Settings

Access settings from the **pause menu → Settings** tab, or use console commands (press `~`).

| Setting | Default | Description |
|---------|---------|-------------|
| Enable Mod | On | Master on/off switch |
| Pay Mode | Hourly | Hourly or Daily payments |
| Difficulty | Normal | Sets the base payment amount |
| Income Multiplier | 1x | Multiplies the base payment |
| Custom Amount | 0 | Overrides difficulty amount (0 = use difficulty) |
| Seasonal Effects | Off | Applies seasonal income multipliers |
| Notifications | On | Pop-up message on each payment |
| Show HUD | On | Enable/disable the HUD overlay |

---

## Console Commands

Type `income` in the developer console (`~` key) to see all commands.

| Command | Description |
|---------|-------------|
| `income` | Show all available commands |
| `IncomeShowSettings` | Display all current settings |
| `IncomeEnable` / `IncomeDisable` | Toggle mod on or off |
| `IncomeSetDifficulty 1\|2\|3` | Set difficulty (1=Easy, 2=Normal, 3=Hard) |
| `IncomeSetPayMode 1\|2` | Set Hourly (1) or Daily (2) payments |
| `IncomeSetNotifications true\|false` | Toggle payment notifications |
| `IncomeSetCustomAmount <n>` | Set a custom payment amount (0 = use difficulty) |
| `IncomeSetDebug true\|false` | Toggle debug logging |
| `IncomeToggleHUD true\|false` | Show or hide the HUD overlay |
| `IncomeTestPayment` | Trigger a $1 test payment immediately |
| `IncomeResetSettings` | Reset all settings to defaults |
| `IncomeHistory` | Show last 10 payment records |
| `IncomeNext` | Show when the next payment fires |

---

## Income Calculation

```
finalAmount = baseAmount × incomeMultiplier × seasonalMultiplier

baseAmount = customAmount > 0 ? customAmount : difficultyAmount
```

| Difficulty | Base Amount |
|------------|-------------|
| Easy | $5,000 |
| Normal | $2,400 |
| Hard | $1,100 |

| Season | Multiplier |
|--------|-----------|
| Spring | 0.8x |
| Summer | 1.0x |
| Autumn | 1.2x |
| Winter | 0.7x |

---

## Save Files

Settings and timer state are saved per-savegame to prevent missed or double payments on reload.

| File | Contents |
|------|----------|
| `{savegame}/FS25_IncomeMod.xml` | All settings |
| `{savegame}/FS25_IncomeMod_state.xml` | Timer state (lastHour, lastDay) |

---

## Multiplayer

- Payments are processed server-side only — no duplicate payouts in MP.
- Every farm (except the spectator farm) receives its payment independently.
- Money is synced to all clients via `addMoney(..., true)`.
- Notifications are shown on clients only, never on dedicated servers.

---

## Localization

Supports 10 languages: English, German, French, Polish, Spanish, Italian, Czech, Brazilian Portuguese, Ukrainian, Russian.

---

## Changelog

### v2.0.0.1
- Fixed binary option callbacks (Enable Mod, Seasonal Effects toggles) not firing correctly in the settings panel.
- Added Income HUD overlay (toggle with I key): shows current income, pay mode, and recent history.
- Added Income Report dialog (open with U key): full settings summary, total/average earnings, and complete payment history.
- Added Show HUD toggle to the settings panel and `IncomeToggleHUD` console command.

### v2.0.0.0 — Major Rewrite
- Complete rewrite for stability and maintainability.
- Added income multiplier (1x / 2x / 5x / 10x).
- Added seasonal income effects.
- Added payment history tracking (last 10 payments).
- Added `IncomeHistory` and `IncomeNext` console commands.
- Added per-savegame settings persistence.
- Added timer state save/load to prevent missed or double payments on reload.
- Full localization in 10 languages.
- Settings panel integrated into the pause menu.

### v1.1.0.0
- Complete code rewrite for stability.
- Added settings panel in the pause menu.
- Updated notification style.
- Localization support added.

---

## License

All rights reserved. Unauthorized redistribution, copying, or claiming this mod as your own is strictly prohibited.
Original author: **TisonK**

---

## Support

Report bugs or request features via [GitHub Issues](https://github.com/TheCodingDad-TisonK/FS25_IncomeMod/issues) or in the comments on the mod page.
