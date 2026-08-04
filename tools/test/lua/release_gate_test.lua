-- release_gate_test.lua - the release gate (STABLE vs experimental-LOCKED).
--
-- The gate is orthogonal to difficulty and mirrors the bypass lock, but on the
-- release axis. Arissani's certification (2026-08-03): the C3 emergency loan is
-- CONDITIONAL per the never-stuck invariant (C1). The loan itself stays
-- available; only its cost elaboration (the re-draw escalation + the Time Guard
-- compounding interest + the Economy-dial pricing when it builds) locks. A
-- locked IncomeMod still lets a broke farm reach the base-game loan at the
-- neutral interest-free cost character.
--!load: src/ReleaseGate.lua, src/settings/Settings.lua, src/settings/SettingsManager.lua, src/EmergencyLoan.lua

-- Sanity: the certified row exists.
T.ok("c3_loan_elaboration registered", ReleaseGate.EXPERIMENTAL.c3_loan_elaboration ~= nil)

-- isReleased: a non-experimental system is always released regardless of opt-in.
T.ok("stable system released with no opt-in", ReleaseGate.isReleased("incomeSystem", nil) == true)
T.ok("stable system released with opt-in off", ReleaseGate.isReleased("incomeSystem", false) == true)

-- isReleased: the elaboration is LOCKED until the explicit opt-in.
T.ok("elaboration LOCKED by default", ReleaseGate.isReleased("c3_loan_elaboration", nil) == false)
T.ok("elaboration LOCKED with opt-in off", ReleaseGate.isReleased("c3_loan_elaboration", false) == false)
T.ok("elaboration released when opt-in on", ReleaseGate.isReleased("c3_loan_elaboration", true) == true)

-- lockMessage: nil when released, a refusal string when locked.
T.eq("no lock message for a stable system", ReleaseGate.lockMessage("incomeSystem", nil), nil)
T.eq("no lock message when opted in", ReleaseGate.lockMessage("c3_loan_elaboration", true), nil)
local msg = ReleaseGate.lockMessage("c3_loan_elaboration", false)
T.ok("lock message when locked", msg ~= nil)
T.ok("message names the not-released state", string.find(msg, "not released", 1, true) ~= nil)

-- status: player-friendly, short, one line per system.
local st = ReleaseGate.status(false)
T.ok("status says OFF when not opted in", string.find(st, "OFF", 1, true) ~= nil)
T.ok("status lists LOCKED systems", string.find(st, "LOCKED", 1, true) ~= nil)
local stOn = ReleaseGate.status(true)
T.ok("status says ON when opted in", string.find(stOn, "ON", 1, true) ~= nil)

-- ── SIM-WIRING GATE: the compounding interest settle respects the live opt-in ──
local function newLoan()
    local loan = EmergencyLoan.new()
    loan.settings = setmetatable({ difficulty = Settings.DIFFICULTY_NORMAL }, {
        __index = function() return Settings.DIFFICULTY_NORMAL end,
    })
    return loan
end

local function withOptIn(optIn, fn)
    local prev = g_IncomeManager
    g_IncomeManager = { settings = { experimentalSystems = optIn,
        allowsExperimentalSystems = function(self) return self.experimentalSystems end } }
    local ok, res = pcall(fn)
    g_IncomeManager = prev
    if not ok then error(res, 0) end
    return res
end

g_server = {}

-- Opt-in OFF: the compounding interest path is locked, so no interest accrues.
T.ok("interest settle no-ops when opt-in off", withOptIn(false, function()
    local loan = newLoan()
    loan.debts[1] = { principal = 100000, accruedInterest = 0, drawCount = 1, lastInterestDay = 0 }
    loan:onInterestSettle(1, { boundariesCrossed = 1, monotonicDay = 30 })
    return loan.debts[1].accruedInterest == 0
end))

-- Opt-in ON: interest accrues exactly as before (8% on 100k = 8000).
T.near("interest settles when opt-in on", withOptIn(true, function()
    local loan = newLoan()
    loan.debts[1] = { principal = 100000, accruedInterest = 0, drawCount = 1, lastInterestDay = 0 }
    loan:onInterestSettle(1, { boundariesCrossed = 1, monotonicDay = 30 })
    return loan.debts[1].accruedInterest
end), 8000, 1)

-- Fail-open: no manager means the gate cannot be read, so the settle behaves as
-- before the gate (the never-stuck escape must never be removed by a lock it
-- cannot read).
local function settleWithNoManager()
    local loan = newLoan()
    loan.debts[1] = { principal = 100000, accruedInterest = 0, drawCount = 1, lastInterestDay = 0 }
    loan:onInterestSettle(1, { boundariesCrossed = 1, monotonicDay = 30 })
    return loan.debts[1].accruedInterest
end
T.near("interest settles with no manager (fail-open)", settleWithNoManager(), 8000, 1)

-- The escape itself is never gated: the grant stays reachable regardless of the
-- opt-in state.
T.ok("grant reachable with opt-in off", withOptIn(false, function()
    g_currentMission = { addMoney = function() end }
    g_farmManager = { getFarmById = function() return { money = -20000 } end }
    local loan = newLoan()
    local ok = loan:grant(1)
    g_currentMission = {}
    g_farmManager = nil
    return ok
end))

g_server = nil
