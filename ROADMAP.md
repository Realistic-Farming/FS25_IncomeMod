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
