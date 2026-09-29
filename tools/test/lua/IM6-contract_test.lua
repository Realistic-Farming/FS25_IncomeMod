--!load: src/settings/Settings.lua, src/IncomeSystem.lua, src/EmergencyLoan.lua, src/EmergencyLoanEvent.lua, src/IncomeSchedule.lua
-- IM6-contract_test.lua - the IM-6 design contract test, updated to call production.
--
-- The brief (IM-6 implementation brief v1.0, section 6) says: "Update the IM-6 contract
-- test to call production parser/preview/apply helpers once built." This is that test.
-- Its source is Office Tyson/DESIGN-WAVE-IM6-2026-09-27/tests/IM-6-roleplay_income_contract_test.lua
-- in the tracking repo. Every row it held is kept, in its order, with the proposed helpers
-- (the local parseWholeAmount, applyConfirmedMode, preview, applyPreview and consoleReset)
-- replaced by IncomeSchedule.parseWholeAmount, IncomeSchedule.validate and
-- IncomeSchedule.serve over the real Settings and a real IncomeSystem instance. The one
-- row that witnessed the old defect ("current setter misses the live instance") is turned
-- round: Settings:setPayMode now writes no marker anywhere, and the host path rebases the
-- live instance.
--
-- This is the arithmetic and validator contract. The entry-point bar (the real manager,
-- the event over the tape, the real poll) is IM6-A-host_authority_test.lua.

local OP = IncomeSchedule.OP
local CAP = IncomeSchedule.CAP

Logging.info = function() end
local function newSettings(amount, mode, multiplier, seasonal)
    local s = Settings.new({ saveSettings = function() end })
    s.customAmount = amount
    s.payMode = mode
    s.difficulty = Settings.DIFFICULTY_NORMAL
    s.incomeMultiplier = multiplier or 1
    s.seasonalEffects = seasonal ~= false
    return s
end

local env = { currentHour = 13, currentDay = 8, currentMonotonicDay = 30, daysPerPeriod = 3, dayTime = 13 * 3600000 }
g_currentMission = { environment = env, getIsServer = function() return true end }

--- The manager shape IncomeSchedule.serve reads: settings, the live system, a revision.
local function newHost(settings, revision, markers)
    local sys = IncomeSystem.new(settings)
    sys.lastHour, sys.lastDay, sys.lastMonotonicDay = markers[1], markers[2], markers[3]
    return { settings = settings, incomeSystem = sys, scheduleRevision = revision }
end

--- The view a season's factor produces, through the payment path's own getter.
local function viewAt(settings, season)
    env.currentSeason = season
    local v = IncomeSchedule.buildView(settings, IncomeSystem.new(settings), 1, true)
    env.currentSeason = nil
    return v
end
local AUTUMN, SPRING = 2, 0

-- The Esc/console parser receives text. It does not guess signs, decimals, exponent
-- notation or grouping punctuation.
for _, case in ipairs({ { "0", 0 }, { "7", 7 }, { "007", 7 }, { " 5000 ", 5000 }, { tostring(CAP), CAP } }) do
    T.eq("whole amount accepts " .. case[1], IncomeSchedule.parseWholeAmount(case[1]), case[2])
end
for _, text in ipairs({ "", "-1", "+5", "1.5", "1e3", "5,000", "abc" }) do
    T.eq("whole amount refuses " .. text, select(2, IncomeSchedule.parseWholeAmount(text)), "NOT_WHOLE_NUMBER")
end
local bound = newHost(newSettings(0, Settings.PAY_MODE_DAILY), 1, { 13, 8, 30 })
T.eq("whole amount refuses the bound plus one",
    IncomeSchedule.validate(bound.settings, 1, true, { operation = OP.PREVIEW, amountText = tostring(CAP + 1), mode = 0, revision = 0 }).status,
    "OUT_OF_RANGE")

local daily = newSettings(5000, Settings.PAY_MODE_DAILY)
T.eq("chosen amount is one daily base payment", daily:getPaymentAmount(), 5000)
T.eq("three-day autumn estimate uses the real loan period helper", viewAt(daily, AUTUMN).monthEstimate, 18000)

local hourly = newSettings(200, Settings.PAY_MODE_HOURLY)
T.eq("three-day hourly autumn estimate counts 72 real payments", viewAt(hourly, AUTUMN).monthEstimate, 17280)
T.eq("hourly and daily use the same amount as one payment", viewAt(hourly, AUTUMN).paymentsThisMonth, 72)
T.eq("daily counts one payment per day", viewAt(daily, AUTUMN).paymentsThisMonth, 3)

local rounded = newSettings(101, Settings.PAY_MODE_DAILY)
T.eq("seasonal reduction floors each payment before month multiplication", viewAt(rounded, SPRING).paymentThisSeason, 80)
T.eq("month estimate keeps the payout floor rather than multiplying then flooring", viewAt(rounded, SPRING).monthEstimate, 240)
T.eq("zero retains the normal difficulty base", newSettings(0, Settings.PAY_MODE_DAILY):getPaymentAmount(), 2400)
T.eq("existing multiplier still applies to the chosen base", newSettings(5000, Settings.PAY_MODE_DAILY, 2):getPaymentAmount(), 10000)

-- A mode switch keeps the number, through the host path, onto the LIVE instance.
local s = newSettings(5000, Settings.PAY_MODE_DAILY)
local host1 = newHost(s, 1, { 6, 8, 30 })
local accepted = IncomeSchedule.serve(host1, true, { operation = OP.APPLY, amountText = "", mode = Settings.PAY_MODE_HOURLY, revision = 1 })
T.eq("confirmed daily-to-hourly change is accepted", accepted.status, "OK")
T.eq("the stored number is kept", s.customAmount, 5000)
T.eq("the same number now means one hourly payment", s:getPaymentAmount(), 5000)
T.eq("live hour marker is rebaselined", host1.incomeSystem.lastHour, 13)
T.eq("live day marker is rebaselined", host1.incomeSystem.lastDay, 8)
T.eq("live monotonic marker is rebaselined", host1.incomeSystem.lastMonotonicDay, 30)
T.eq("a three-day month now has 24 times the payment count", accepted.view.paymentsThisMonth, 24 * 3)
T.eq("the new hourly month estimate follows the preserved number", accepted.view.monthEstimate, 360000)

local before = s.payMode
local unknown = IncomeSchedule.serve(host1, true, { operation = OP.APPLY, amountText = "", mode = 99, revision = host1.scheduleRevision })
T.eq("unknown pay mode is refused", unknown.status, "UNKNOWN_PAY_MODE")
T.eq("refusal keeps the accepted mode", s.payMode, before)

-- Source witness, turned round: the setter no longer writes any marker, on the class
-- table or anywhere else. The schedule writer is the host path above.
local legacy = newSettings(5000, Settings.PAY_MODE_DAILY)
local legacyInstance = IncomeSystem.new(legacy)
legacyInstance.lastHour, legacyInstance.lastDay, legacyInstance.lastMonotonicDay = 6, 8, 30
legacy:setPayMode(Settings.PAY_MODE_HOURLY)
T.eq("the setter changes the mode", legacy.payMode, Settings.PAY_MODE_HOURLY)
T.eq("the setter writes no class-table hour marker", rawget(IncomeSystem, "lastHour"), nil)
T.eq("the setter writes no class-table day marker", rawget(IncomeSystem, "lastDay"), nil)
T.eq("the setter writes no class-table monotonic marker", rawget(IncomeSystem, "lastMonotonicDay"), nil)
T.eq("the setter leaves the instance to the host path", legacyInstance.lastHour, 6)

-- R2 fold: host preview/revision, legacy-over-cap preservation and every Reset use the
-- same host transition.
local host = newHost(newSettings(2000000, Settings.PAY_MODE_DAILY), 5, { 2, 7, 40 })
local keepLegacy = IncomeSchedule.serve(host, true, { operation = OP.PREVIEW, amountText = "", mode = Settings.PAY_MODE_HOURLY, revision = 0 })
T.ok("mode-only change may keep the exact legacy amount", keepLegacy.status == "OK")
T.eq("missing season follows the built 1.0 payment fallback", keepLegacy.view.paymentThisSeason, 2000000)
T.eq("hourly preview publishes 24 payments per full day", keepLegacy.view.paymentsThisMonth / keepLegacy.view.daysThisMonth, 24)
T.eq("legacy hourly preview uses the active three-day month", keepLegacy.view.monthEstimate, 144000000)
T.eq("a new over-cap amount is refused",
    IncomeSchedule.serve(host, true, { operation = OP.PREVIEW, amountText = "2000001", mode = Settings.PAY_MODE_DAILY, revision = 0 }).status,
    "OUT_OF_RANGE")

local stale = IncomeSchedule.serve(host, true, { operation = OP.APPLY, amountText = "0", mode = Settings.PAY_MODE_DAILY, revision = 4 })
T.eq("stale preview is refused", stale.status, "STALE_PREVIEW")
T.eq("stale preview leaves the legacy amount unchanged", host.settings.customAmount, 2000000)
T.eq("fresh confirmed preview applies",
    IncomeSchedule.serve(host, true, { operation = OP.APPLY, amountText = "", mode = Settings.PAY_MODE_HOURLY, revision = keepLegacy.revision }).status, "OK")
T.eq("confirmed preview advances settings revision", host.scheduleRevision, 6)
T.eq("confirmed legacy mode switch rebases live hour", host.incomeSystem.lastHour, 13)

host.settings.difficulty = Settings.DIFFICULTY_HARD
host.settings.enabled = false
host.settings.debugMode = true
host.settings.showNotifications = false
host.settings.seasonalEffects = true
host.settings.incomeMultiplier = 4
host.settings.showHUD = false
host.settings.experimentalSystems = true
host.incomeSystem.lastHour = 2
local amountBeforeUnconfirmedReset = host.settings.customAmount
local resetPreview = IncomeSchedule.serve(host, true, { operation = OP.RESET_PREVIEW, revision = 0 })
T.eq("console Reset without confirm is refused",
    IncomeSchedule.serve(host, true, { operation = OP.RESET_APPLY, revision = resetPreview.revision, confirm = false }).status, "CONFIRM_REQUIRED")
T.eq("unconfirmed Reset keeps the amount", host.settings.customAmount, amountBeforeUnconfirmedReset)
T.eq("unconfirmed Reset keeps enabled off", host.settings.enabled, false)
T.ok("confirmed console Reset applies through the same contract",
    IncomeSchedule.serve(host, true, { operation = OP.RESET_APPLY, revision = resetPreview.revision, confirm = true }).status == "OK")
T.eq("Reset restores zero as difficulty default", host.settings.customAmount, 0)
T.eq("confirmed Reset rebases the live hour", host.incomeSystem.lastHour, 13)
T.eq("Reset restores Hourly mode", host.settings.payMode, Settings.PAY_MODE_HOURLY)
T.eq("Reset restores Normal difficulty", host.settings.difficulty, Settings.DIFFICULTY_NORMAL)
T.eq("Reset restores enabled on", host.settings.enabled, true)
T.eq("Reset restores debug off", host.settings.debugMode, false)
T.eq("Reset restores notifications on", host.settings.showNotifications, true)
T.eq("Reset restores seasonal effects off", host.settings.seasonalEffects, false)
T.eq("Reset restores multiplier 1x", host.settings.incomeMultiplier, 1)
T.eq("Reset restores HUD on", host.settings.showHUD, true)
T.eq("Reset restores experimental systems off", host.settings.experimentalSystems, false)

-- The SettingsHub rows are the registered definitions, read in the entry-point bar
-- (IM6-A-host_authority_test.lua A15, A16 and group H), not a local table.

local disabled = newSettings(5000, Settings.PAY_MODE_DAILY)
disabled.enabled = false
local dv = viewAt(disabled, AUTUMN)
T.eq("disabled schedule still shows an at-this-rate gross", dv.paymentState .. " " .. dv.monthEstimate, "DISABLED 18000")
