# Changelog

All notable changes to FS25_IncomeMod will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

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
