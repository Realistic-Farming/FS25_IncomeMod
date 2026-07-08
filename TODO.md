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
- [ ] StateLedger: `IncomeMod_Settings` + `IncomeMod_State` (timer state exact across reload); retire the own XML save files.
- [ ] NetworkSync: `IncomeMod_Sync` channel (settings broadcast + payment notification display).
- [ ] MasterHUD: register `IncomeMod_HUD` (delegate-when-present).
- [ ] SettingsHub: register the 9 settings.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [!] All four bedrock migrations (waits on: the bedrock engines being adopted here; SoilFertilizer is the reference pattern).
