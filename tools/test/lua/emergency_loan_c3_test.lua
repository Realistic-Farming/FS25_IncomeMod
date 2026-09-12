-- emergency_loan_c3_test.lua - EMERGENCY LOAN (C3 / RSF-F130), repaired host.
--
-- Real-source coverage of the F130 repairs: TOTAL-outstanding compounding (not
-- principal-only), the release-gate cost lock with NO fail-open, half-period-gross
-- sizing, the interest-first payment helper with exact fractional payoff, the native
-- clock-pair contract, grant/redraw/never-stacked, and the MP->SP pooling remap.
--
--!load: src/settings/SettingsManager.lua, src/settings/Settings.lua, src/ReleaseGate.lua, src/EmergencyLoan.lua

local NORMAL = Settings.DIFFICULTY_NORMAL

-- Cost-ready environment: Time Guard present + release lock opted in.
local function costReadyOn()
    g_timeGuard = {}
    ReleaseGate.isReleased = function(_id, optIn) return optIn == true end
    ReleaseGate.liveOptIn = function() return true end
end
local function costReadyOff() g_timeGuard = nil end

local function newLoan(difficulty, incomeSystem)
    local loan = EmergencyLoan.new()
    loan.settings = { difficulty = difficulty or NORMAL }
    loan.incomeSystem = incomeSystem or { settings = { enabled = false, getPaymentAmount = function() return 0 end } }
    return loan
end

-- ── C1: difficulty scales the COST, never the availability ──────────────────
do
    T.eq("C1 easy interest is 0", EmergencyLoan.INTEREST_RATE_MONTHLY[Settings.DIFFICULTY_EASY], 0.0)
    T.eq("C1 normal interest 8%", EmergencyLoan.INTEREST_RATE_MONTHLY[NORMAL], 0.08)
    T.eq("C1 hard interest 15%", EmergencyLoan.INTEREST_RATE_MONTHLY[Settings.DIFFICULTY_HARD], 0.15)
end

-- ── Interest: TOTAL outstanding compounds by (1+rate)^N (the repair) ─────────
do
    costReadyOn()
    g_server = {}
    local rate = EmergencyLoan.INTEREST_RATE_MONTHLY[NORMAL]
    -- A line with PRIOR interest: this is where principal-only and total-outstanding differ.
    local function line() return { principal = 10000, accruedInterest = 250, drawCount = 1, active = true } end

    local serial = newLoan(NORMAL); serial.debts[1] = line()
    serial:onInterestSettle(1, { boundariesCrossed = 1 })
    serial:onInterestSettle(1, { boundariesCrossed = 1 })
    local batch = newLoan(NORMAL); batch.debts[1] = line()
    batch:onInterestSettle(1, { boundariesCrossed = 2 })

    T.near("two 1-month settles equal one 2-month settle (total-outstanding)",
        serial:getOutstanding(1), batch:getOutstanding(1), 1e-6)
    T.near("prior interest participates in growth", batch:getOutstanding(1), 10250 * (1 + rate) ^ 2, 1e-6)
    T.ok("total-outstanding compounding exceeds principal-only",
        batch:getOutstanding(1) > 10000 + 2 * 10000 * rate)
    g_server = nil; costReadyOff()
end

-- ── Release gate: NO fail-open ───────────────────────────────────────────────
do
    local loan = newLoan(NORMAL)
    g_timeGuard = nil
    T.ok("no Time Guard => cost not ready", not loan:isCostReady())
    g_timeGuard = {}
    ReleaseGate.isReleased = function() error("unreadable") end
    T.ok("a throwing release decision => cost not ready", not loan:isCostReady())
    ReleaseGate.isReleased = function() return "true" end
    T.ok("a truthy non-boolean => cost not ready", not loan:isCostReady())
    ReleaseGate.isReleased = function(_id, optIn) return optIn == true end
    ReleaseGate.liveOptIn = function() return false end
    T.ok("released but opted out => cost not ready", not loan:isCostReady())
    ReleaseGate.liveOptIn = function() return true end
    T.ok("released + opted in + Time Guard => cost ready", loan:isCostReady())

    -- onInterestSettle charges NOTHING when cost is not ready (debt still stands).
    g_server = {}
    g_timeGuard = nil
    local l2 = newLoan(NORMAL); l2.debts[1] = { principal = 10000, accruedInterest = 0, drawCount = 1, active = true }
    l2:onInterestSettle(1, { boundariesCrossed = 3 })
    T.eq("locked cost accrues no interest; posted debt stands", l2:getOutstanding(1), 10000)
    g_server = nil; costReadyOff()
end

-- ── Sizing: half a period's gross, or the 10000 fallback ─────────────────────
do
    T.eq("hourly 100 at D3 => period gross 7200", EmergencyLoan.periodGross(100, 1, Settings.PAY_MODE_HOURLY, 3), 7200)
    T.eq("daily 100 at D3 => period gross 300", EmergencyLoan.periodGross(100, 1, Settings.PAY_MODE_DAILY, 3), 300)
    T.eq("seasonal floor is per payout before multiplication", EmergencyLoan.periodGross(101, 0.8, Settings.PAY_MODE_HOURLY, 1), 80 * 24)

    local amount, buffer, basis = EmergencyLoan.offerFromMinimum(-450, 3 * 1000, true, true)
    T.eq("three-day period uses half its gross", buffer, 1500)
    T.eq("offer covers shortfall plus half-period cash", amount, 1950)
    T.eq("basis names the reliable income basis", basis, "HALF_PERIOD_GROSS")

    local fb, fbBuf, fbBasis = EmergencyLoan.offerFromMinimum(-450, 3000, true, false)
    T.eq("disabled income uses the 10000 fallback", fbBuf, 10000)
    T.eq("disabled-income offer retains the shortfall", fb, 10450)
    T.eq("fallback basis is explicit", fbBasis, "FALLBACK_10000")

    T.eq("unreliable positive estimate takes fallback", (EmergencyLoan.offerFromMinimum(-450, 3000, false, true)), 10450)
    T.eq("reliable zero income takes fallback", (EmergencyLoan.offerFromMinimum(-450, 0, true, true)), 10450)
    local small, smallBuf = EmergencyLoan.offerFromMinimum(-0.25, 100, true, true)
    T.eq("reliable small income is not raised to a 10000 floor", smallBuf, 50)
    T.eq("offer rounds the final total upward", small, 51)
    T.eq("zero shortfall does not offer a loan", (EmergencyLoan.offerFromMinimum(0, 3000, true, true)), nil)
    T.eq("failed minimum read is UNAVAILABLE, not an invented zero",
        select(3, EmergencyLoan.offerFromMinimum(nil, 3000, true, true)), "UNAVAILABLE")
end

-- ── Payment helper: interest first, exact fractional payoff ──────────────────
do
    g_server = {}
    g_currentMission = { addMoney = function(_self, a) _G._paid = (_G._paid or 0) + a end }
    _G._paid = 0
    local loan = newLoan(NORMAL)
    loan.debts[1] = { principal = 1000, accruedInterest = 125, drawCount = 1, active = true, pendingEligibility = {} }
    local applied = loan:applyManualPayment(1, 200)
    T.eq("manual payment applies the accepted amount", applied, 200)
    T.eq("interest is paid first", loan.debts[1].accruedInterest, 0)
    T.eq("only the remainder reduces principal", loan.debts[1].principal, 925)
    T.eq("the cash move used IncomeMod's path", _G._paid, -200)

    -- Exact fractional payoff leaves explicit zero and retires the line.
    local loan2 = newLoan(NORMAL)
    loan2.debts[1] = { principal = 100, accruedInterest = 0.375, drawCount = 1, active = true, pendingEligibility = {} }
    local payoff = loan2:payoffAmount(1)
    T.near("payoff includes the undisplayed fraction", payoff, 100.375, 1e-9)
    loan2:applyManualPayment(1, payoff)
    T.eq("fractional payoff leaves no residue", loan2:getOutstanding(1), 0)
    T.ok("the paid line is retired", loan2.debts[1] == nil)

    -- Automatic repayment floors the 25% share.
    local loan3 = newLoan(NORMAL)
    loan3.debts[1] = { principal = 1000, accruedInterest = 0, drawCount = 1, active = true, pendingEligibility = {} }
    T.eq("auto repayment floors 25% of the gross", loan3:applyRepayment(1, 403), 100)
    g_server = nil; g_currentMission = {}
end

-- ── The native clock pair contract ───────────────────────────────────────────
do
    local loan = newLoan(NORMAL)
    g_currentMission = { environment = { currentMonotonicDay = 100, dayTime = 64800000, currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 3 } }
    T.eq("clock uses native monotonic day", loan:clockPair().monotonicDay, 100)
    T.eq("clock uses dayTime milliseconds", loan:clockPair().timeOfDayMs, 64800000)
    g_currentMission.environment.dayTime = 86400000
    T.eq("the transient day boundary defers the quote", loan:clockPair(), nil)
    g_currentMission.environment.dayTime = -1
    T.eq("a negative clock is unavailable", loan:clockPair(), nil)
    g_currentMission.environment.dayTime = 0 / 0
    T.eq("a nonfinite clock is unavailable", loan:clockPair(), nil)
    g_currentMission.environment.dayTime = 0
    T.eq("native midnight is valid", loan:clockPair().timeOfDayMs, 0)
    g_currentMission.environment.currentMonotonicDay = 100.5
    T.eq("a fractional day axis is rejected", loan:clockPair(), nil)
    g_currentMission = {}
end

-- ── Grant / redraw: server-authoritative, one line, never stacked ────────────
do
    g_server = {}
    local added = 0
    g_currentMission = {
        addMoney = function(_self, a) added = added + a end,
        environment = { currentMonotonicDay = 10, dayTime = 0, currentYear = 1, currentPeriod = 5, currentDayInPeriod = 1, daysPerPeriod = 3 },
    }
    g_farmManager = { getFarmById = function(_self, _id) return { money = -20000 } end }
    local loan = newLoan(NORMAL)  -- income disabled => fallback buffer
    loan:setReadiness(EmergencyLoan.READINESS.READY)

    local ok1, amt1 = loan:grant(1)
    T.ok("the first grant lands on a red forecast", ok1)
    T.eq("offer = shortfall + 10000 fallback", amt1, 30000)
    T.eq("the debt line is recorded", loan:getOutstanding(1), 30000)
    T.eq("first eligibility is drawMonth+2", loan.debts[1].interestEligibleFromMonth, (1 * 12 + 5 - 1) + 2)

    local ok2 = loan:grant(1)
    T.ok("a second fresh grant is refused (one line, never stacked)", not ok2)
    T.eq("the single line did not double", loan:getOutstanding(1), 30000)

    local before = loan:getOutstanding(1)
    local okR, amtR = loan:redraw(1)
    T.ok("a re-draw lands on the SAME line", okR)
    T.eq("the line grows, not a second loan", loan:getOutstanding(1), before + amtR)
    T.eq("the draw count steps up", loan.debts[1].drawCount, 2)
    g_server = nil; g_currentMission = {}; g_farmManager = nil
end

-- ── A client never writes money; grant without addMoney refuses before debt ──
do
    g_server = nil
    g_currentMission = { addMoney = function() error("client must not add money") end,
        environment = { currentMonotonicDay = 1, dayTime = 0, currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 3 } }
    g_farmManager = { getFarmById = function() return { money = -50000 } end }
    local loan = newLoan(NORMAL); loan:setReadiness(EmergencyLoan.READINESS.READY)
    T.ok("a client grant is a no-op", not (loan:grant(1)))
    T.eq("no debt installed on the client", loan:getOutstanding(1), 0)
    g_currentMission = {}; g_farmManager = nil
end

-- ── Persistence round-trip + farm-level merge-never-replace ──────────────────
do
    local loan = newLoan(NORMAL)
    loan.debts[1] = { principal = 50000, accruedInterest = 1000, drawCount = 2, revision = 3, active = true, pendingEligibility = {} }
    local data = loan:serialize()
    T.eq("snapshot carries the schema", data.schema, EmergencyLoan.SCHEMA)

    local loan2 = newLoan(NORMAL)
    T.ok("a fresh owner starts LOADING", loan2:getReadiness() == EmergencyLoan.READINESS.LOADING)
    loan2:deserialize(data)
    T.eq("round-trip principal survives", loan2.debts[1].principal, 50000)
    T.eq("round-trip interest survives", loan2.debts[1].accruedInterest, 1000)
    T.ok("install flips readiness to READY", loan2:getReadiness() == EmergencyLoan.READINESS.READY)

    -- A current session draw for another farm survives a late re-deliver (no resurrect).
    g_server = {}; g_currentMission = { addMoney = function() end,
        environment = { currentMonotonicDay = 1, dayTime = 0, currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 3 } }
    g_farmManager = { getFarmById = function() return { money = -100000 } end }
    loan2:grant(2)
    loan2:deserialize(data)
    T.ok("a session draw survives a reload merge", loan2.debts[2] ~= nil)
    T.eq("the older farm's debt still present", loan2.debts[1].principal, 50000)
    g_server = nil; g_currentMission = {}; g_farmManager = nil
end

-- ── MP->SP remap: pool into the surviving farm, max draw count, no new draw ──
do
    local loan = newLoan(NORMAL)
    loan.debts[1] = { principal = 1000, accruedInterest = 80, drawCount = 2, revision = 1, active = true, pendingEligibility = {} }
    loan.debts[2] = { principal = 2000, accruedInterest = 40, drawCount = 4, revision = 1, active = true, pendingEligibility = {} }
    loan:remapMergedFarms({ [2] = 1 })
    T.eq("pooled principal", loan.debts[1].principal, 3000)
    T.eq("pooled posted interest", loan.debts[1].accruedInterest, 120)
    T.eq("max existing draw count, no new draw", loan.debts[1].drawCount, 4)
    T.eq("no orphan debt at the merged origin", loan.debts[2], nil)
    -- A repeated map cannot double-pool (origin already consumed).
    loan:remapMergedFarms({ [2] = 1 })
    T.eq("repeated map does not double the debt", loan.debts[1].principal + loan.debts[1].accruedInterest, 3120)
end
