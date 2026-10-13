# Changelog

All notable changes to FS25_IncomeMod will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

## [2.3.0.0] - 2026-10-12

> **This is not a final release.** It gives everyone, testers and players, new or returning, everything we have built so far, so nobody has to wait on an old version any longer. The Realistic Farming suite is far from done: we are still building and expanding every mod, and completing it could take months, possibly a year. Expect changes and rough edges along the way, and please report anything that looks wrong.

### Changed
- Income schedule (multiplayer): the pay amount and pay mode now change only on the host, after a preview you confirm. Switching mode or pressing Reset pays nothing at the moment of the switch, a non-administrator is refused, and Settings Hub no longer lists or writes the pay mode or amount.
- The HUD, the income report and the Esc Realistic Farming page show the host's income schedule in multiplayer (not the joining player's own settings), say they are waiting until it arrives, and name the current seasonal adjustment. With Experimental Systems on, they also explain the month at this rate and that the amount applies to every active farm.

### Fixed
- Emergency loans: an amount the game does not know yet shows as Unavailable instead of 0, and the buttons only act on known amounts. Paying a loan off keeps its history, so the next loan's rate and quote are worked out correctly, and accepting a Borrow quote checks that it still fits your current cash instead of refusing over small cash changes.
- Setting the clock backwards within a day no longer pays out the "missed" hours; the next real hour pays normally.
- Multiplayer: a settings change made through Settings Hub is saved only by the host.
- With Master HUD installed, Income Mod no longer logs a false "HUD toggle registration failed" warning at load.
- Translations: the settings labels, help pages, pay-mode options, title and description no longer show garbled characters in eleven languages, and the mod manager shows Income Mod's own name in nine languages that had carried another mod's name. The Esc page legend shows a plain dot between page names.

### Fixed
- RSF-F282 follow-up: the code and test comments now say that the console setter holding the day is the design brief's reading of an engine branch that decompiles empty. No change to payments. (MAINTENANCE row 102.)

## [2.2.0.0] - 2026-09-18

### Added
- **Emergency Loan (C3/RSF-F130):** a usable, truthful, durable recovery loan for a farm in trouble. Chosen-amount repayment lets a player pay back any amount they choose, not just the full balance. The loan report now shows a forecast surface: expected regular income, known bills, a separately labelled recent-spending estimate, the projected lowest cash balance (a negative number is a shortage warning), a forecast status, the horizon it covers, and which inputs the forecast could not account for. All new strings ship in all 26 mod languages.
- Income HUD hide/show toggle added to the suite Control Center (requires SettingsHub).

### Fixed
- modDesc.xml was missing a closing `</text>` before the Emergency Loan forecast's l10n block and carried a stray extra one 756 lines later; the two cancelled out, so the file stayed well-formed XML, but the 27 forecast keys parsed as nested children instead of direct children of `<l10n>`, and the game's loader only reads direct children. Every forecast string would have shown as a missing-key placeholder in every language. This never shipped: `main` never carried the Emergency Loan forecast feature, so no player saw it. Fixed before this release.
- RSF-F201 PLAYER-lifetime companion: the IM_TOGGLE_HUD and IM_HUD_EDIT handles are now stored (two shadowed captures fixed), the edit handle is removed on teardown, the standalone failure line no longer prints for a working control, and the wrapper installs once per session instead of being restored on every delete.

## [2.1.8.0] - 2026-08-26

### Added
- Changelog file established (suite ruling 2026-08-22).
- Playtest fixes: IM_TOGGLE_HUD (RShift+I) and IM_HUD_EDIT (RShift+J) chords, HUD/settings alignment, IM_INCOME_REPORT in Control Center.
- Control Center action: IM_INCOME_REPORT opens the income report from the suite Control Center (requires SettingsHub).

## [2.1.7.34] - 2026-08-22

- First entry under changelog tracking.
