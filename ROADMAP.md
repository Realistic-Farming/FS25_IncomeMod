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
- [x] SettingsHub: 9 settings registered (selfPersisted). ESC injection (SettingsUI.lua + UIHelper.lua, InGameMenuSettingsFrame hooks) retained as the standalone fallback; full removal is a later cleanup.
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
