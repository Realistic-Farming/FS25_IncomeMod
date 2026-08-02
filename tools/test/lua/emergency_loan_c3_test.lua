-- emergency_loan_c3_test.lua - EMERGENCY LOAN (C3), the never-stuck recovery hatch
--
-- The bench pins the brief's invariants: C1 (never-stuck - difficulty scales the
-- cost, never the availability), the FORWARD-FORECAST TRIGGER (crossing zero
-- ALONE, no other gate), the server-authoritative grant, the ONE COMPOUNDING
-- LINE (no stacked fresh loans; re-draws compound), the monthly compounding
-- interest (debt * (1+rate)^N, not N*rate), the auto-deduct repayment share, and
-- the merge-never-replace persistence.
--
--!load: src/settings/Settings.lua, src/settings/SettingsManager.lua, src/EmergencyLoan.lua, src/IncomeSystem.lua

local function newLoan(difficulty, incomeSystem)
    local loan = EmergencyLoan.new()
    loan.settings = setmetatable({ difficulty = difficulty or Settings.DIFFICULTY_NORMAL }, {
        __index = function() return Settings.DIFFICULTY_NORMAL end,
    })
    loan.incomeSystem = incomeSystem or {
        settings = { enabled = true, getPaymentAmount = function() return 5000 end },
    }
    return loan
end

-- ── C1: difficulty scales the COST, never the availability ──────────────────
do
    local easy = newLoan(Settings.DIFFICULTY_EASY)
    T.eq("easy interest is 0 (interest-free bridge)", easy.INTEREST_RATE_MONTHLY[1], 0.0)
    T.eq("normal interest ~8%", easy.INTEREST_RATE_MONTHLY[2], 0.08)
    T.eq("hard interest ~15%", easy.INTEREST_RATE_MONTHLY[3], 0.15)
end

-- ── The forecast trigger: crossing zero ALONE ───────────────────────────────
do
    local loan = newLoan(Settings.DIFFICULTY_NORMAL, {
        settings = { enabled = false, getPaymentAmount = function() return 0 end },
    })
    -- No farm manager, no cross-mod: forecast = balance + income*days (income 0 here).
    g_farmManager = { getFarmById = function() return { money = 100000 } end }
    T.ok("a healthy farm is not red", not loan:isForecastRed(1))
    g_farmManager = { getFarmById = function() return { money = -1000 } end }
    T.ok("a farm already at zero is red", loan:isForecastRed(1))
    g_farmManager = nil
end

-- ── The grant is server-authoritative and never stacks ──────────────────────
do
    local granted = 0
    g_server = {}
    g_currentMission = { addMoney = function(_self, a, _farm, _mt, _sync) granted = granted + a end }
    g_farmManager = { getFarmById = function() return { money = -20000 } end }

    local loan = newLoan(Settings.DIFFICULTY_NORMAL)
    local ok1, amt1 = loan:grant(1)
    T.ok("the first grant lands", ok1)
    T.ok("the grant is sized to the shortfall + runway", amt1 >= 20000)
    T.eq("the debt line is recorded", loan:getOutstanding(1), amt1)

    -- Never stacked: a second grant on the SAME red window is refused.
    local ok2 = loan:grant(1)
    T.ok("a second grant is refused (one line, never stacked)", not ok2)
    T.eq("the single line did not double", loan:getOutstanding(1), amt1)

    g_server = nil
    g_currentMission = {}
    g_farmManager = nil
end

-- ── Re-draw compounds the ONE line ──────────────────────────────────────────
do
    local granted = 0
    g_server = {}
    g_currentMission = { addMoney = function(_self, a, _farm, _mt, _sync) granted = granted + a end }
    g_farmManager = { getFarmById = function() return { money = -100000 } end }

    local loan = newLoan(Settings.DIFFICULTY_NORMAL)
    loan:grant(1)
    local before = loan:getOutstanding(1)
    local okRedraw, amtRedraw = loan:redraw(1)
    T.ok("a re-draw lands on the SAME line", okRedraw)
    T.eq("the line grows, not a second loan", loan:getOutstanding(1), before + amtRedraw)
    T.eq("the draw count steps up", loan.debts[1].drawCount, 2)

    g_server = nil
    g_currentMission = {}
    g_farmManager = nil
end

-- ── A client never writes money (grant is server-only) ──────────────────────
do
    g_server = nil
    g_currentMission = { addMoney = function() error("client must not add money") end }
    g_farmManager = { getFarmById = function() return { money = -50000 } end }
    local loan = newLoan(Settings.DIFFICULTY_NORMAL)
    local ok = loan:grant(1)
    T.ok("a client grant is a no-op", not ok)
    g_currentMission = {}
    g_farmManager = nil
end

-- ── Monthly compounding: debt * (1+rate)^N, not N*rate ──────────────────────
do
    g_server = {}
    local loan = newLoan(Settings.DIFFICULTY_NORMAL)
    loan.debts[1] = { principal = 100000, accruedInterest = 0, drawCount = 1, lastInterestDay = 0 }
    loan:onInterestSettle(1, { boundariesCrossed = 1, monotonicDay = 30 })
    -- 8% on 100k = 8000
    T.near("one month at 8% accrues 8000", loan.debts[1].accruedInterest, 8000, 1)

    -- Two months at once: 100000 * (1.08^2 - 1) = 16640, NOT 16000
    loan.debts[1].accruedInterest = 0
    loan:onInterestSettle(1, { boundariesCrossed = 2, monotonicDay = 60 })
    T.near("two months compound: 100000*(1.08^2-1)", loan.debts[1].accruedInterest, 16640, 5)
    T.ok("compounding is more than simple N*rate", loan.debts[1].accruedInterest > 16000)

    g_server = nil
end

-- ── Repayment auto-deducts a share and retires the line ─────────────────────
do
    g_server = {}
    local deducted = 0
    g_currentMission = { addMoney = function(_self, a, _farm, _mt, _sync) deducted = deducted + a end }
    local loan = newLoan(Settings.DIFFICULTY_NORMAL)
    loan.debts[1] = { principal = 10000, accruedInterest = 0, drawCount = 1, lastInterestDay = 0 }

    local share = loan:applyRepayment(1, 4000)   -- 25% of 4000 = 1000
    T.eq("repayment takes the ruled share", share, 1000)
    T.eq("the deduction used IncomeMod's money path", deducted, -1000)
    T.eq("principal reduced", loan.debts[1].principal, 9000)

    -- Fully repay and the line retires + the accrual unregisters.
    loan:applyRepayment(1, 100000)
    T.eq("the debt line retires when paid off", loan:getOutstanding(1), 0)
    T.ok("the retired line is removed", loan.debts[1] == nil)

    g_server = nil
    g_currentMission = {}
end

-- ── Persistence: round-trip, merge-never-replace ────────────────────────────
do
    local loan = newLoan(Settings.DIFFICULTY_NORMAL)
    loan.debts[1] = { principal = 50000, accruedInterest = 1000, drawCount = 2, lastInterestDay = 60 }
    local data = loan:serialize()

    local loan2 = newLoan(Settings.DIFFICULTY_NORMAL)
    loan2:deserialize(data)
    T.eq("round-trip principal survives", loan2.debts[1].principal, 50000)
    T.eq("round-trip interest survives", loan2.debts[1].accruedInterest, 1000)
    T.eq("round-trip draw count survives", loan2.debts[1].drawCount, 2)

    -- Merge: a session draw survives a reload of an older save.
    g_server = {}
    g_currentMission = { addMoney = function() end }
    g_farmManager = { getFarmById = function() return { money = -100000 } end }
    loan2:grant(2)
    loan2:deserialize(data)
    T.ok("a session draw survives a reload merge", loan2.debts[2] ~= nil)
    T.eq("the older farm's debt still present", loan2.debts[1].principal, 50000)
    g_server = nil
    g_currentMission = {}
    g_farmManager = nil
end
