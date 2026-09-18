-- c3_loan_money_contract_test.lua - RSF-F130 money contract, retargeted at the REAL
-- repaired host functions. The delivered draft's SOURCE witnesses asserted the pre-repair
-- defects (principal-only interest; grant that installs debt with no cash); per the draft's
-- instruction they are re-pointed to assert the fix. REFERENCE contracts are bound to the
-- real pure helpers (offerFromMinimum, periodGross, clockPair, isCostReady, evaluateManual,
-- allocatePayment). Snapshot/native-event/XML behavior remains an in-game observation.
--
--!load: src/ReleaseGate.lua, src/settings/SettingsManager.lua, src/settings/Settings.lua, src/EmergencyLoan.lua, src/EmergencyLoanEvent.lua

local NORMAL = Settings.DIFFICULTY_NORMAL
local function costReadyOn()
    g_timeGuard = {}
    ReleaseGate.isReleased = function(_id, optIn) return optIn == true end
    ReleaseGate.liveOptIn = function() return true end
end

local function newLoan()
    local loan = EmergencyLoan.new()
    loan.settings = { difficulty = NORMAL }
    loan.incomeSystem = { settings = { enabled = false, getPaymentAmount = function() return 0 end } }
    return loan
end

-- ── SOURCE->REPAIRED: total-outstanding compounding (not principal-only) ─────
do
    costReadyOn(); g_server = {}
    local rate = EmergencyLoan.INTEREST_RATE_MONTHLY[NORMAL]
    local function line() return { principal = 10000, accruedInterest = 250, drawCount = 1, active = true } end
    local monthly, batched = newLoan(), newLoan()
    monthly.debts[7] = line(); batched.debts[7] = line()
    monthly:onInterestSettle(7, { boundariesCrossed = 1 })
    monthly:onInterestSettle(7, { boundariesCrossed = 1 })
    batched:onInterestSettle(7, { boundariesCrossed = 2 })
    T.near("REPAIRED callback partitions agree (total-outstanding)",
        monthly:getOutstanding(7), batched:getOutstanding(7), 1e-6)
    T.near("REPAIRED prior interest participates in growth",
        batched:getOutstanding(7), 10250 * (1 + rate) ^ 2, 1e-6)
    T.ok("REPAIRED compounding exceeds old principal-only N*rate",
        batched:getOutstanding(7) > 10000 + 2 * 10000 * rate)
    g_server = nil; g_timeGuard = nil
end

-- ── SOURCE->REPAIRED: a grant with no native money function refuses BEFORE debt ─
do
    g_server = {}
    g_currentMission = {  -- valid red forecast, but NO addMoney
        environment = { currentMonotonicDay = 5, dayTime = 0, currentYear = 1, currentPeriod = 3, currentDayInPeriod = 1, daysPerPeriod = 3 },
    }
    g_farmManager = { getFarmById = function() return { money = -500 } end }
    local loan = newLoan(); loan:setReadiness(EmergencyLoan.READINESS.READY)
    local granted = loan:grant(7)
    T.eq("REPAIRED grant with no native money function refuses", granted, false)
    T.eq("REPAIRED no debt is installed without a cash credit", loan:getOutstanding(7), 0)
    g_server = nil; g_currentMission = {}; g_farmManager = nil
end

-- ── REAL sizing: half-period gross or the 10000 fallback ─────────────────────
do
    T.eq("three-day period uses half its gross, not 14 days",
        (select(2, EmergencyLoan.offerFromMinimum(-450, 3 * 1000, true, true))), 1500)
    T.eq("approved offer covers path shortfall plus half-period cash",
        (EmergencyLoan.offerFromMinimum(-450, 3 * 1000, true, true)), 1950)
    T.eq("view identifies the usable income basis",
        (select(3, EmergencyLoan.offerFromMinimum(-450, 3000, true, true))), "HALF_PERIOD_GROSS")
    T.eq("disabled income uses the approved fallback",
        (select(2, EmergencyLoan.offerFromMinimum(-450, 3000, true, false))), 10000)
    T.eq("disabled-income offer retains the shortfall",
        (EmergencyLoan.offerFromMinimum(-450, 3000, true, false)), 10450)
    T.eq("unreliable positive estimate takes fallback",
        (EmergencyLoan.offerFromMinimum(-450, 3000, false, true)), 10450)
    T.eq("reliable zero income takes fallback",
        (EmergencyLoan.offerFromMinimum(-450, 0, true, true)), 10450)
    T.eq("reliable small income is not raised to a 10000 floor",
        (select(2, EmergencyLoan.offerFromMinimum(-0.25, 100, true, true))), 50)
    T.eq("offer rounds the final total upward",
        (EmergencyLoan.offerFromMinimum(-0.25, 100, true, true)), 51)
    T.eq("zero shortfall does not offer a loan", (EmergencyLoan.offerFromMinimum(0, 3000, true, true)), nil)
    T.eq("failed balance read is UNAVAILABLE, not an invented zero",
        (select(3, EmergencyLoan.offerFromMinimum(nil, 3000, true, true))), "UNAVAILABLE")
end

-- ── REAL payout units (exact giveMoney rule) ─────────────────────────────────
do
    T.eq("hourly three-day gross has 72 payouts", EmergencyLoan.periodGross(100, 1, Settings.PAY_MODE_HOURLY, 3), 7200)
    T.eq("hourly three-day buffer is half period gross", EmergencyLoan.periodGross(100, 1, Settings.PAY_MODE_HOURLY, 3) / 2, 3600)
    T.eq("daily three-day buffer is distinct", EmergencyLoan.periodGross(100, 1, Settings.PAY_MODE_DAILY, 3) / 2, 150)
    T.eq("seasonal floor is per payout before multiplication", EmergencyLoan.periodGross(101, 0.8, Settings.PAY_MODE_HOURLY, 1), 80 * 24)
    T.eq("28-day hourly buffer is not fourteen payout amounts", EmergencyLoan.periodGross(100, 1, Settings.PAY_MODE_HOURLY, 28) / 2, 33600)
end

-- ── REAL clock pair (shared date contract) ───────────────────────────────────
do
    local loan = newLoan()
    g_currentMission = { environment = { currentMonotonicDay = 100, dayTime = 64800000, currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 3 } }
    T.eq("clock uses native monotonic day", loan:clockPair().monotonicDay, 100)
    T.eq("clock uses dayTime milliseconds not hour", loan:clockPair().timeOfDayMs, 64800000)
    g_currentMission.environment.dayTime = 86400000
    T.eq("transient day boundary defers the quote", loan:clockPair(), nil)
    g_currentMission.environment.dayTime = -1
    T.eq("negative clock is unavailable", loan:clockPair(), nil)
    g_currentMission.environment.dayTime = 0 / 0
    T.eq("nonfinite clock is unavailable", loan:clockPair(), nil)
    g_currentMission.environment.dayTime = 0
    T.eq("native midnight is valid", loan:clockPair().timeOfDayMs, 0)
    g_currentMission.environment.currentMonotonicDay = 100.5
    T.eq("fractional day axis is rejected", loan:clockPair(), nil)
    g_currentMission = {}
end

-- ── REAL cost readiness: NO fail-open ────────────────────────────────────────
do
    local loan = newLoan()
    g_timeGuard = nil
    T.ok("absent Time Guard prevents new interest", not loan:isCostReady())
    g_timeGuard = {}
    ReleaseGate.isReleased = function() error("unavailable") end
    T.ok("unread release predicate prevents costs", not loan:isCostReady())
    ReleaseGate.isReleased = function() return "true" end
    T.ok("a truthy string cannot authorize interest", not loan:isCostReady())
    ReleaseGate.isReleased = function(_id, optIn) return optIn == true end
    ReleaseGate.liveOptIn = function() return false end
    T.ok("explicit opt-out costs remain off", not loan:isCostReady())
    ReleaseGate.liveOptIn = function() return true end
    T.ok("explicit opt-in + Time Guard can enable costs", loan:isCostReady())
    g_timeGuard = nil
end

-- ── REAL command cache (EmergencyLoanController.evaluateManual) ──────────────
do
    local function account(cash, principal, interest)
        return { farmId = 7, cash = cash, principal = principal, interest = interest,
            revision = 1, terms = "terms-A", ready = true, incomeHistory = 0, retirements = 0 }
    end
    local function debtTotal(s) return s.principal + s.interest end
    local function apply(state, amount)
        local before = debtTotal(state)
        local fromInterest = math.min(amount, state.interest)
        state.interest = state.interest - fromInterest
        state.principal = state.principal - (amount - fromInterest)
        state.cash = state.cash - amount
        state.revision = state.revision + 1
        if amount == before then state.principal, state.interest = 0, 0; state.retirements = state.retirements + 1 end
    end
    local function command(state, sequence, amount, token)
        return { sequence = sequence, operation = "repay", farmId = state.farmId, amount = amount,
            revision = state.revision, terms = state.terms, quote = token, session = "session-A" }
    end
    local manager = { farmId = 7, manager = true, session = "session-A" }
    local function newSession() return { id = "session-A", highest = 0 } end

    local state, session = account(2000, 1000, 125), newSession()
    local cashBefore, debtBefore = state.cash, debtTotal(state)
    local req = command(state, 1, 200, "quote-1")
    local result = EmergencyLoanController.evaluateManual(state, session, manager, req, apply)
    T.eq("approved own-farm manager repayment accepted", result.status, "ACCEPTED")
    T.eq("manual payment reduces cash by the accepted amount", cashBefore - state.cash, 200)
    T.eq("same payment reduces debt by that exact amount", debtBefore - debtTotal(state), 200)
    T.eq("interest is paid first", state.interest, 0)
    T.eq("only payment remainder reduces principal", state.principal, 925)
    -- Exact retry = the ORIGINAL payload (revision 1), not one rebuilt from advanced state.
    local retry = EmergencyLoanController.evaluateManual(state, session, manager, req, apply)
    T.eq("exact retry returns the original result despite advanced revision", retry.status, result.status)
    T.eq("exact retry does not debit twice", state.principal, 925)
    local altered = command(state, 1, 201, "quote-1")
    T.eq("sequence reused with changed amount is refused",
        EmergencyLoanController.evaluateManual(state, session, manager, altered, apply).status, "CHANGED_PAYLOAD")
    T.eq("deliberate fresh quote and sequence can pay again",
        EmergencyLoanController.evaluateManual(state, session, manager, command(state, 2, 25, "quote-2"), apply).status, "ACCEPTED")
    T.eq("older sequence cannot execute after a newer command",
        EmergencyLoanController.evaluateManual(state, session, manager, req, apply).status, "OLD_SEQUENCE")

    -- Refusals leave money untouched.
    local s2 = account(50, 1000, 100)
    T.eq("insufficient cash refuses", EmergencyLoanController.evaluateManual(s2, newSession(), manager, command(s2, 1, 100, "q"), apply).status, "INSUFFICIENT_CASH")
    T.eq("insufficient cash moves nothing", s2.cash, 50)
    local s3 = account(2000, 1000, 100)
    local otherFarm = { farmId = 8, manager = true, session = "session-A" }
    T.eq("different acting farm refused", EmergencyLoanController.evaluateManual(s3, newSession(), otherFarm, command(s3, 1, 100, "q"), apply).status, "WRONG_FARM")
    local s4 = account(2000, 1000, 100)
    local member = { farmId = 7, manager = false, session = "session-A" }
    T.eq("ordinary member refused", EmergencyLoanController.evaluateManual(s4, newSession(), member, command(s4, 1, 100, "q"), apply).status, "NOT_MANAGER")
    -- Exact fractional payoff.
    local s5 = account(500, 100, 0.375)
    local payoff = command(s5, 1, debtTotal(s5), "payoff")
    T.eq("exact fractional payoff accepted", EmergencyLoanController.evaluateManual(s5, newSession(), manager, payoff, apply).status, "ACCEPTED")
    T.near("fractional payoff spends the undisplayed fraction", s5.cash, 399.625, 1e-9)
    T.eq("fractional payoff leaves no residue", s5.principal + s5.interest, 0)
end

-- ── REAL allocatePayment: interest-first, exact fractional payoff ────────────
do
    local loan = newLoan()
    local debt = { principal = 1000, accruedInterest = 125, drawCount = 1, active = true, pendingEligibility = {} }
    loan.debts[7] = debt
    T.eq("allocate pays interest first", loan:allocatePayment(debt, 200), 200)
    T.eq("interest cleared first", debt.accruedInterest, 0)
    T.eq("remainder reduces principal", debt.principal, 925)
    local d2 = { principal = 100, accruedInterest = 0.375, drawCount = 1, active = true, pendingEligibility = {} }
    loan.debts[8] = d2
    loan:allocatePayment(d2, 100.375)
    T.eq("exact payoff leaves no residue", (d2.principal + d2.accruedInterest), 0)
    T.ok("payoff marks the line inactive", d2.active == false)
end

-- ── REAL MP->SP native merge: pool, max draw, no double on repeat ────────────
do
    local loan = newLoan()
    loan.debts[1] = { principal = 1000, accruedInterest = 80, drawCount = 2, revision = 1, active = true, pendingEligibility = {} }
    loan.debts[2] = { principal = 2000, accruedInterest = 40, drawCount = 4, revision = 1, active = true, pendingEligibility = {} }
    loan:remapMergedFarms({ [2] = 1 })
    T.eq("native merge pools principal", loan.debts[1].principal, 3000)
    T.eq("native merge preserves posted interest", loan.debts[1].accruedInterest, 120)
    T.eq("owner chooses maximum existing draw count", loan.debts[1].drawCount, 4)
    T.eq("no orphan debt remains at the merged id", loan.debts[2], nil)
    loan:remapMergedFarms({ [2] = 1 })
    T.eq("remapping already-normalized state does not double debt",
        loan.debts[1].principal + loan.debts[1].accruedInterest, 3120)
end

-- ── REFERENCE: an interim shortage precedes a later receipt (endpoint is wrong) ─
do
    local cash, lowest = 250, 250
    for _, d in ipairs({ -700, 1000 }) do cash = cash + d; lowest = math.min(lowest, cash) end
    T.eq("REFERENCE later income makes endpoint positive", cash, 550)
    T.eq("REFERENCE a bill before later income still makes a shortage", lowest, -450)
    -- Total-debt presentation keeps native loan distinct.
    local native, emergency = 100, 900
    T.eq("REFERENCE total debt includes emergency outstanding", native + emergency, 1000)
    T.eq("REFERENCE native loan read is not redefined", native, 100)
end
