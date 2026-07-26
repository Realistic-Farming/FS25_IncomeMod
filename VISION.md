# Vision: FS25_IncomeMod

> Ecosystem role: **Markets and Economy** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit (Point 1-5, ecosystem-map, notes).
> Last updated: 2026-07-08

## 1. One-line purpose
A configurable recurring income: it pays the farm a periodic amount (hourly or daily cadence, pay modes, seasonal multiplier) so there is a steady baseline income alongside crop sales.

## 2. Problem it solves
Vanilla FS25 farm income is entirely sale-driven. There is no baseline income, subsidy, or salary, so early-game and diversified play have no cushion between harvests. IncomeMod adds a tunable recurring payment that fits an economy playthrough without touching how sales work.

## 3. Design pillars
- **Pure producer.** IncomeMod only pays money out. It reads no other mod and owns no shared state beyond its own.
- **Multiplayer-correct.** Payments are server-authoritative (getIsServer gate in giveMoney), so a payment fires once per cadence, never once per client.
- **Cadence integrity.** Timer state persists so a save/reload mid-cycle never double-pays or skips.
- **Configurable, not intrusive.** Pay amount, mode, and seasonal scaling are all settings; defaults stay gentle.

## 4. Role in the ecosystem
- Public handle on `g_currentMission.incomeManager` (getfenv alias `g_IncomeManager`). Set in `Mission00.load` prepend.
- Reads from (consumes): nothing cross-mod. The seasonal multiplier reads `g_currentMission.environment.currentSeason` (base-game API, pcall-guarded). Pure producer.
- Read by (consumers): FarmTablet IncomeApp, via five companion read functions (isActive, getCurrentPaymentAmount, getPayMode, getSeasonalMultiplier, getPaymentHistory).
- Core-API registration status (specced in Point 1-5, not yet wired):
  - StateLedger (save/load): planned, modules `IncomeMod_Settings` + `IncomeMod_State` (timer state). Replaces the own XML files.
  - NetworkSync (MP state): planned, channel `IncomeMod_Sync` (settings broadcast + payment-notification display on clients).
  - MasterHUD (overlays): planned, `IncomeMod_HUD`.
  - SettingsHub (admin settings): planned, 9 settings. Replaces the ESC-menu settings injection (SettingsUI/UIHelper to be removed).

## 5. Explicit non-goals
- Not a markets or sales system (that is MarketDynamics). IncomeMod does not touch crop prices or contracts.
- Does not read or depend on any peer mod. The HUD layout file stays client-local.
- Does not gate payments on player activity or work done (it is a baseline income, not a wage; wages are WorkerCosts/ProStaff).

## 6. Success criteria
- The configured income arrives exactly once per cadence, correct across reload and in multiplayer.
- Clients see the payment notification and the current amount/mode without desync.
- Settings changes are admin-gated and broadcast; no ESC-menu injection remains after the SettingsHub move.

## 7. Open questions for the audit
- Should the console reset command (`resetToDefaults`) also push `SETTINGS_CHANGED` via NetworkSync, or is that redundant with the settings broadcast?
- Confirm the five companion read functions are the complete surface FarmTablet's IncomeApp needs.
