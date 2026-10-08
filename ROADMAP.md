# Roadmap: FS25_IncomeMod

> Ecosystem role: **Markets and Economy** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline.
> Forward-looking only. Shipped history lives in CHANGELOG.md and the releases.

## How to use this file
- Populate the milestones below from the audit baseline once it lands.
- Each item should be small enough to map to a `TODO.md` entry.
- Keep it honest: near-term is committed, mid-term is intended, long-term is aspirational.

## Current baseline
- Version at baseline: v2.1.6.0
- Audit reference: ecosystem-dev-tracking Point 1-5 (FS25_IncomeMod, 2026-06-30)
- Baseline date: 2026-06-30

## Near-term (next release cycle)

- [x] Esc framework table freeze (Income guest, #49, 2026-08-15): the shared 4-bay column grid is restated on every show so the guest does not inherit the previous module's geometry in the shared Esc door. Merged; 2.1.7.34.
- [x] Release gate (2026-08-04): wired per Arissani's 2026-08-03 lock set. C3 is CONDITIONAL - the loan itself stays available, only its cost elaboration (the re-draw escalation, the Time Guard compounding, the Economy-dial pricing) locks until the experimentalSystems opt-in is on. `ReleaseGate.lua` + `incomeRelease` status command + `IncomeSetExperimental`. 44 assertions green.
- [x] Emergency Loan (C3): the never-stuck recovery hatch. Forecast-crossing-zero trigger (alone), server-authoritative grant, Time Guard compounding monthly interest, auto-deduct repayment, one compounding debt line. C1 holds (difficulty scales cost, never availability). 27 assertions. PR to main pending. The base-game loan confirm was answered from the decompile (`Farm:getLoan()`, `loanMax`, 4% rate).
- [x] SettingsHub: 10 settings registered (selfPersisted). ESC injection (SettingsUI.lua + UIHelper.lua, InGameMenuSettingsFrame hooks) retained as the standalone fallback; full removal is a later cleanup.
- [x] StateLedger: `IncomeMod_Settings` + `IncomeMod_State` bridge live (delegate-when-present); own XML kept as the safety copy.
- [x] 2026-07-26 bug sweep: IM-001 (setPayMode timer reset), IM-002 (mouseEvent isAux param), IM-003 (version strings) fixed and merged to main.

## Mid-term (this season)
- [ ] NetworkSync channel `IncomeMod_Sync` for settings broadcast and client-side payment notifications. Not built yet.
- [x] MasterHUD `IncomeMod_HUD` registered (delegate-when-present; own hook stays as fallback).
- [ ] Expose the five companion read functions for FarmTablet IncomeApp.

## Long-term / aspirational
- [ ] Richer income models (subsidy tiers, contract-linked bonuses) without becoming a markets system.

## Cross-mod / ecosystem dependencies
- [~] Bedrock 3/4 done (StateLedger + MasterHUD + SettingsHub); NetworkSync remaining.
- [ ] FarmTablet IncomeApp (blocks on: the five read functions being exposed).

## Deferred / parked
- Activity-gated pay (a wage rather than a baseline income): parked; wages are WorkerCosts/ProStaff territory.

## 2026-10-04 (Fred): the shared RF Esc door at the suite's STOCK page set (Wizard, #95)

- [x] The four shared Esc door files (`xml/gui/RfPdaMenuPage.xml`, `src/gui/RfPdaMenuPage.lua`, `src/gui/RfEscModules.lua`, `xml/gui/rfEscProfiles.xml`) are at the set every door mod carries, byte-same in all ten (Wizard's STOCK page chain build, #95, merged at 1751e5d4): wider sheet cells, the explanation band at up to four lines, the ids and callbacks StockGuard's STOCK page uses (inert without StockGuard), the hidden ids and profiles of DairyCore's herd-advisory panel, ProStaff in the closed-module list, and Soil Fertilizer's AUTO target card kept.
- The door's in-game check is TESTING row 414. Docs by Fred's catch-up, on Tyson's word of 2026-10-04.

## 2026-10-05 (Fred): the Esc side panel's info box clear of the selected tab (Wizard, #97)

- [x] The shared Esc door file `xml/gui/RfPdaMenuPage.xml`, byte-same in all ten door mods (Wizard, #97, merged at b31d20c3): the side info boxes (`rfSideInfoShell`, `wcSideInfoShell`, `mdSideInfoShell`, `csSideInfoShell`) take an explicit position and size, 16 px further right and 16 px narrower (384 to 368 px), so the dark box starts clear of the selected tab's lime edge and its right edge stays where it was. The side text bodies narrow by the same 16 px, to 352 px (the main side text, from 368) and 348 px (the Worker Costs and Market Dynamics side help, from 364), so the text starts 16 px further right and each line ends where it did.
- The change's in-game check is TESTING row 451. Docs by Fred's catch-up, on Tyson's word of 2026-10-05.

## 2026-10-08 (Fred): the SettingsHub bridge saves on the server only (MAINTENANCE row 253)

- [x] The bridge's `applyChange` ended in `s:save()` on every peer, so a client reached through its own SettingsHub would write its own unsynced settings file (a joined client's savegame directory is set). It now applies the value on every peer and saves only on the server. SettingsHub #24 already calls a selfPersisted module's onChange on the server only; this keeps the bridge safe on its own. Design origin none.
- The in-game check is TESTING row 513.
