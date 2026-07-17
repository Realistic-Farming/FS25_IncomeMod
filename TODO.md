# TODO: FS25_IncomeMod

> Ecosystem role: **Markets and Economy** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [ ] Remove the ESC-menu settings injection: `InGameMenuSettingsFrame.onFrameOpen` and `.updateButtons` hooks, plus SettingsUI.lua + UIHelper.lua. SettingsHub owns settings now.
- [ ] Decide whether the console reset command should also push `SETTINGS_CHANGED` via NetworkSync.

## Bugs
- [ ] None from the audit: payments are already server-gated (getIsServer in giveMoney), so no MP double-pay.

## Features / enhancements
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
