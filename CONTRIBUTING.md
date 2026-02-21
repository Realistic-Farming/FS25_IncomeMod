# Contributing to FS25 Income Mod

Thank you for your interest in contributing. This document covers everything you need to know before submitting code.

---

## Branching Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Stable releases only — never commit directly here |
| `development` | Active development — all work goes here |

**Workflow:**
1. Fork the repository (or work on a feature branch off `development`).
2. Make your changes on `development` or a branch off it.
3. Open a pull request targeting `development`.
4. Once reviewed and merged, releases are promoted from `development` → `main` via PR.

---

## Project Structure

```
FS25_IncomeMod/
├── gui/
│   └── IncomeReportDialog.xml      # Full-screen report dialog layout
├── src/
│   ├── main.lua                    # Entry point, hooks, source() order
│   ├── IncomeManager.lua           # Central coordinator
│   ├── IncomeSystem.lua            # Payment logic and history
│   ├── settings/
│   │   ├── Settings.lua            # Settings object and constants
│   │   ├── SettingsManager.lua     # XML save/load
│   │   ├── SettingsGUI.lua         # Console commands
│   │   └── SettingsUI.lua          # In-game settings panel injection
│   └── ui/
│       ├── IncomeHUD.lua           # On-screen HUD overlay
│       └── IncomeReportDialog.lua  # Full-screen report dialog
├── modDesc.xml                     # Mod descriptor, l10n, key bindings
├── README.md
└── CONTRIBUTING.md
```

**Module load order matters** (enforced in `main.lua`):
```
SettingsManager → Settings → SettingsGUI → UIHelper → SettingsUI
→ IncomeHUD → IncomeReportDialog → IncomeSystem → IncomeManager
```

Settings must be available before UI, and all UI must be available before IncomeManager wires everything together.

---

## FS25 Lua Constraints

FS25 runs **Lua 5.1** in a sandboxed environment. Several standard patterns are unavailable:

| Pattern | Problem | Solution |
|---------|---------|----------|
| `goto` / labels | Not in Lua 5.1 | Use `if/else` or early `return` |
| `continue` | Not in Lua 5.1 | Use guard clauses |
| `os.time()` / `os.date()` | Sandboxed away | Use `g_currentMission.environment.currentDay/currentHour` |
| `Slider` widgets | Unreliable events | Use `MultiTextOption` or binary options |
| Raw function as `onClickCallback` | FS25 requires `target` object | Use a bridge table with a method string (see `UIHelper.createBinaryOption`) |

---

## Code Style

- **Classes**: PascalCase (`IncomeManager`, `IncomeSystem`)
- **Variables and fields**: camelCase (`paymentHistory`, `lastHour`)
- **Methods**: camelCase (`giveMoney()`, `getSeasonalMultiplier()`)
- **Constants**: UPPER_SNAKE_CASE (`PAY_MODE_HOURLY`, `MAX_HISTORY`)
- File header: include the copyright block and version comment matching the other files
- Keep files under **1,500 lines** — split into modules if needed

---

## Key Patterns

### Server Guard (Multiplayer)
Always gate money operations server-side to prevent duplicate payouts:
```lua
if not g_currentMission:getIsServer() then return false end
```

### Per-Farm Payment Loop
```lua
for _, farm in pairs(g_farmManager.farms) do
    if farm and farm.farmId and farm.farmId ~= 0 then
        g_currentMission:addMoney(amount, farm.farmId, MoneyType.INCOME, true)
    end
end
```
`farmId == 0` is the spectator farm — always skip it. The fourth argument `true` syncs the financial log to all clients.

### Key Binding Registration
Register input actions via the `PlayerInputComponent.registerActionEvents` hook — this is the only race-condition-safe pattern:
```lua
PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
    originalRegisterActionEvents(inputComponent, ...)
    if not (inputComponent.player and inputComponent.player.isOwner) then return end
    if g_IncomeManager and g_IncomeManager.someEventId then return end
    g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)
    local ok, id = g_inputBinding:registerActionEvent(InputAction.MY_ACTION, ...)
    g_inputBinding:endActionEventsModification()
end
```

### Dialog Pattern (ScreenElement)
Full-screen dialogs extend `ScreenElement` and are loaded once via `g_gui:loadGui`, then shown with `g_gui:showDialog`. See `IncomeReportDialog.lua` and `gui/IncomeReportDialog.xml` for the reference implementation.

---

## Adding Settings

1. Add the field and default in `Settings.lua` (`resetToDefaults()` and `validateSettings()`).
2. Add save/load in `SettingsManager.lua` (`saveSettings()`, `loadSettings()`, and the `defaultConfig` table).
3. Add a UI control in `SettingsUI.lua` (binary option or multi-option via `UIHelper`).
4. Add a console command in `SettingsGUI.lua`.
5. Add l10n strings to `modDesc.xml` for all 10 languages: `en`, `de`, `fr`, `pl`, `es`, `it`, `cz`, `br`, `uk`, `ru`.

---

## Adding Localization Strings

All l10n strings live in `modDesc.xml` under `<l10n>`. Add entries in all 10 languages. Strings referenced from XML use the `$l10n_key_name` prefix. Strings fetched from Lua use `g_i18n:getText("key_name")`.

---

## Testing

There is no automated test suite. Test manually:

1. Copy the mod folder (or its zip) to `Documents/My Games/FarmingSimulator2025/mods`.
2. Launch FS25 and load a save.
3. Open the developer console (`~`) and run:
   - `income` — verify all commands are listed
   - `IncomeShowSettings` — verify settings display correctly
   - `IncomeTestPayment` — verify a $1 test payment fires
   - `IncomeHistory` — verify history records are written
   - `IncomeNext` — verify next payment countdown shows
4. Press **I** — verify HUD toggles on/off.
5. Press **U** — verify Income Report dialog opens and shows correct data.
6. Open pause menu → Settings — verify all Income Mod options appear and toggles work.
7. Save and reload the game — verify settings and timer state are preserved.
8. Check `Documents/My Games/FarmingSimulator2025/log.txt` for any Lua errors.

---

## Pull Request Requirements

- Target `development`, never `main` directly.
- Describe what changed and why.
- If adding a feature, update README.md and add l10n strings for all 10 languages.
- If adding console commands, document them in the README table.
- No `Co-Authored-By` AI tool credits in commit messages or PR descriptions.
- All code must be compatible with Lua 5.1 — no `goto`, no `continue`, no `os.time()`.
