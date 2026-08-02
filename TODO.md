# TODO: FS25_IncomeMod

> Ecosystem role: **Markets and Economy** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [ ] Remove the ESC-menu settings injection: `InGameMenuSettingsFrame.onFrameOpen` and `.updateButtons` hooks, plus SettingsUI.lua + UIHelper.lua. SettingsHub owns settings now.
- [ ] Decide whether the console reset command should also push `SETTINGS_CHANGED` via NetworkSync.

## Bugs
- [x] 2026-07-26 bug sweep: IncomeMod bugs fixed and merged to main. IM-001 (`setPayMode()` resets both mode timers to prevent catch-up exploit), IM-002 (added missing `isAux` parameter to `mouseEvent` signature), IM-003 (version strings consolidated to match modDesc.xml). All closed.

## Features / enhancements
- [x] Emergency Loan (C3): the never-stuck recovery hatch. `EmergencyLoan.lua` owns the per-farm debt ledger; server-authoritative grant sized to the forecast shortfall + runway; Time Guard month-cadence compounding interest (debt*(1+rate)^N, LATE priority, farm-scoped id, escalation per re-draw); auto-deduct repayment (25% share) at the income payout; forecast-crossing-zero trigger alone (no other gate). C1 holds: difficulty scales the cost, never the availability. StateLedger sidecar (`IncomeEmergencyLoanBridge`), merge-never-replace. Economy dial (spine) not built; neutral default rates used. 27 assertions in emergency_loan_c3_test.lua. The base-game loan confirm was answered from the decompile: `Farm:getLoan()`, `Farm.loanMax`, 4% `LOAN_INTEREST_RATE`.
- [ ] Companion read API: isActive, getCurrentPaymentAmount, getPayMode, getSeasonalMultiplier, getPaymentHistory (for FarmTablet IncomeApp).

## Cross-mod integration
- [x] StateLedger: `IncomeMod_Settings` + `IncomeMod_State` bridge live (delegate-when-present; own XML kept as the safety copy).
- [ ] NetworkSync: `IncomeMod_Sync` channel (settings broadcast + payment notification display). Not built yet.
- [x] MasterHUD: `IncomeMod_HUD` registered (delegate-when-present).
- [x] SettingsHub: 9 settings registered (selfPersisted). ESC injection retained as the standalone fallback.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [~] Bedrock 3/4 done (StateLedger + MasterHUD + SettingsHub, delegate-when-present); NetworkSync remaining.
