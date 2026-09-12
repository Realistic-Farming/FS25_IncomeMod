-- =========================================================
-- FS25 Income Mod - EMERGENCY LOAN (C3 / RSF-F130)
-- =========================================================
-- The never-stuck recovery hatch. When a farm's one-period cash forecast projects
-- crossing zero, a farm manager may voluntarily borrow the projected shortfall plus
-- working cash, see ONE real debt line, and repay it through the automatic income
-- deduction or a manual payment / exact payoff. Server-authoritative throughout.
--
-- THE NEVER-STUCK INVARIANT (C1): difficulty scales the COST and the escalation, never
-- the availability. The recovery is reachable whenever the forecast is red; only the
-- cost elaboration (compounding interest) is gated by the release lock.
--
-- F130 repairs over the early version: the forecast reads the REAL provider contracts
-- (WorkerCosts payroll + TaxMod tax) instead of guessed fields; sizing is half a
-- period's expected gross (or 10000), not 14 literal days; interest compounds TOTAL
-- outstanding (not principal-only); the cost lock is read through ReleaseGate.isReleased
-- (no fail-open); debt persists standalone via an own debt XML; and a player request /
-- quote / accept path with farm-manager rights replaces the old unguarded grant.
-- The owner Event lives in EmergencyLoanEvent.lua; own-XML persistence in
-- EmergencyLoanDebtStorage.lua; this file owns the debt model, forecast and money math.
-- =========================================================
-- Author: TisonK
-- =========================================================

EmergencyLoan = EmergencyLoan or {}

-- =========================================================
-- Locked cost character (C5). Rates are fractions per eligible in-game month.
-- =========================================================
EmergencyLoan.INTEREST_RATE_MONTHLY = {
    [Settings.DIFFICULTY_EASY]   = 0.00,   -- interest-free bridge
    [Settings.DIFFICULTY_NORMAL] = 0.08,
    [Settings.DIFFICULTY_HARD]   = 0.15,
}
EmergencyLoan.ESCALATION_PP_PER_DRAW = {
    [Settings.DIFFICULTY_EASY]   = 0.00,
    [Settings.DIFFICULTY_NORMAL] = 0.02,
    [Settings.DIFFICULTY_HARD]   = 0.04,
}
EmergencyLoan.MAX_RATE = {
    [Settings.DIFFICULTY_EASY]   = 0.00,
    [Settings.DIFFICULTY_NORMAL] = 0.20,
    [Settings.DIFFICULTY_HARD]   = 0.35,
}
-- Automatic repayment share of each scheduled income payout while debt stands.
EmergencyLoan.REPAYMENT_SHARE = 0.25
-- Working-cash fallback when no reliable regular-income basis exists.
EmergencyLoan.FALLBACK_BUFFER = 10000

-- StateLedger persistence key. LOCKED, never renamed after first persist.
EmergencyLoan.MODULE_ID = "IncomeMod_EmergencyLoan"
-- Time Guard accrual id prefix (farm-scoped).
EmergencyLoan.ACCRUAL_ID_PREFIX = "IncomeMod_emergencyInterest_farm"
EmergencyLoan.ACCRUAL_PRIORITY = 90
-- The release-gate system id for the cost elaboration (interest/escalation).
EmergencyLoan.COST_LOCK_SYSTEM = "c3_loan_elaboration"
-- Public view contract version.
EmergencyLoan.VIEW_VERSION = 1
EmergencyLoan.READINESS = { LOADING = "LOADING", READY = "READY", UNAVAILABLE = "UNAVAILABLE" }
EmergencyLoan.MS_PER_DAY = 86400000

function EmergencyLoan.new()
    return setmetatable({
        -- debts[farmId] = {
        --   principal, accruedInterest, drawCount, revision, active,
        --   lastSettledMonth, interestEligibleFromMonth,
        --   pendingEligibility = { {principal, accruedInterest, eligibleFromMonth}, ... } }
        debts = {},
        -- Debt-owner readiness: LOADING until a snapshot is installed, then READY;
        -- UNAVAILABLE if a malformed primary blocks mutation.
        readiness = EmergencyLoan.READINESS.LOADING,
        _cache = {},
        _cacheDay = -1,
        armed = false,
    }, { __index = EmergencyLoan })
end

function EmergencyLoan:isArmed() return self.armed end
function EmergencyLoan:getReadiness() return self.readiness or EmergencyLoan.READINESS.LOADING end
function EmergencyLoan:setReadiness(r) self.readiness = r end

-- =========================================================
-- Month counter (Time Guard epoch: year*12 + period - 1). Never monotonic days.
-- =========================================================
function EmergencyLoan._periodsInYear()
    if Environment ~= nil and Environment.PERIODS_IN_YEAR ~= nil then
        return Environment.PERIODS_IN_YEAR
    end
    return 12
end

--- The current native month counter, or nil if the calendar is unavailable.
function EmergencyLoan:currentMonthCounter()
    local env = g_currentMission and g_currentMission.environment
    if env == nil or type(env.currentYear) ~= "number" or type(env.currentPeriod) ~= "number" then
        return nil
    end
    return env.currentYear * EmergencyLoan._periodsInYear() + env.currentPeriod - 1
end

-- =========================================================
-- Time Guard (delegate-when-present)
-- =========================================================

local function getTimeGuard()
    return (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
end

function EmergencyLoan:registerInterestAccrual(farmId)
    if g_server == nil then return false end
    local tg = getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then
        Logging.info("Income Mod: Time Guard not detected - emergency loan interest never accrues")
        return false
    end
    local id = EmergencyLoan.ACCRUAL_ID_PREFIX .. tostring(farmId)
    local ok, registered = pcall(function()
        return tg:registerAccrual(id, {
            cadence           = "month",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = EmergencyLoan.ACCRUAL_PRIORITY,
            onSettle          = function(ctx) self:onInterestSettle(farmId, ctx) end,
        })
    end)
    if not ok then
        Logging.warning("Income Mod: emergency loan interest accrual registration failed: %s", tostring(registered))
        return false
    end
    return registered ~= false
end

function EmergencyLoan:unregisterInterestAccrual(farmId)
    local tg = getTimeGuard()
    if tg == nil or tg.unregisterAccrual == nil then return end
    pcall(function()
        tg:unregisterAccrual(EmergencyLoan.ACCRUAL_ID_PREFIX .. tostring(farmId))
    end)
end

-- =========================================================
-- Cost readiness (release gate) - NO fail-open
-- =========================================================

--- The cost elaboration (compounding interest) charges only when the release lock is
--- released/opted-in AND Time Guard is present. An unknown/throwing release decision,
--- unreadable settings, or absent Time Guard => NO new interest (never fail-open). The
--- loan grant / redraw / forecast / repayment stay available regardless.
---@return boolean
function EmergencyLoan:isCostReady()
    if getTimeGuard() == nil then return false end
    if ReleaseGate == nil or type(ReleaseGate.isReleased) ~= "function" then return false end
    local optIn = nil
    if type(ReleaseGate.liveOptIn) == "function" then
        local ok, value = pcall(ReleaseGate.liveOptIn)
        if ok then optIn = value end
    end
    local ok, released = pcall(ReleaseGate.isReleased, EmergencyLoan.COST_LOCK_SYSTEM, optIn)
    return ok and released == true
end

--- A short reason code for the current cost state (for the view's costLockReason).
function EmergencyLoan:costLockReason()
    if getTimeGuard() == nil then return "NO_TIME_GUARD" end
    if not self:isCostReady() then return "COST_LOCKED" end
    return nil
end

-- =========================================================
-- Interest: compound TOTAL outstanding by (1+rate)^N
-- =========================================================

local function difficultyOf(self)
    return (self.settings and self.settings.difficulty) or Settings.DIFFICULTY_NORMAL
end

--- Effective monthly rate for a debt: base + per-redraw escalation, capped. The
--- cost-readiness rule may still make the CHARGED rate 0, but this is the posted rate.
function EmergencyLoan:effectiveRate(debt)
    local diff = difficultyOf(self)
    local base = EmergencyLoan.INTEREST_RATE_MONTHLY[diff] or 0.08
    local inc  = EmergencyLoan.ESCALATION_PP_PER_DRAW[diff] or 0.02
    local cap  = EmergencyLoan.MAX_RATE[diff] or 0.20
    local reDraws = math.max(0, ((debt and debt.drawCount) or 1) - 1)
    return math.min(base + reDraws * inc, cap)
end

--- The monthly interest settle (server-only, idempotent via Time Guard's cursor).
--- Compounds the TOTAL outstanding (principal + prior interest) by (1+rate)^N over the
--- N eligible months crossed - NOT principal-only. Locked/absent cost readiness means
--- no new interest. When a month counter and eligibility marker are both known, months
--- before interestEligibleFromMonth are not charged (the first-period exemption).
---@param farmId number
---@param ctx table  { boundariesCrossed, monthCounter? }
function EmergencyLoan:onInterestSettle(farmId, ctx)
    if g_server == nil then return end
    if not self:isCostReady() then return end
    local debt = self.debts[farmId]
    if not debt then return end
    local outstanding = (debt.principal or 0) + (debt.accruedInterest or 0)
    if outstanding <= 0 then return end

    local n = math.max(1, math.floor(tonumber(ctx and ctx.boundariesCrossed) or 1))

    -- When a month counter is available, cap N to the unprocessed eligible months so a
    -- locked/absent-service gap or a not-yet-eligible first period is never back-charged.
    local nowMonth = ctx and tonumber(ctx.monthCounter)
    if nowMonth ~= nil then
        local from = math.max(tonumber(debt.lastSettledMonth) or (nowMonth - n),
                              (tonumber(debt.interestEligibleFromMonth) or 0) - 1)
        local eligible = math.max(0, nowMonth - from)
        n = math.min(n, eligible)
        debt.lastSettledMonth = nowMonth
        if n <= 0 then return end
    end

    local rate = self:effectiveRate(debt)
    if rate <= 0 then return end
    local grown = outstanding * ((1.0 + rate) ^ n - 1.0)
    debt.accruedInterest = (debt.accruedInterest or 0) + grown

    Logging.info("Income Mod: Emergency loan farm %s interest +%.2f (rate %.3f, x%d)",
        tostring(farmId), grown, rate, n)
end

-- =========================================================
-- Payout units (exactly the giveMoney rule) and period gross
-- =========================================================

--- One payout's gross under the current seasonal multiplier, matching IncomeSystem's
--- giveMoney: S==1 -> A; else max(1, floor(A*S)).
function EmergencyLoan.payoutGross(amount, seasonMult)
    local a = tonumber(amount) or 0
    local s = tonumber(seasonMult) or 1
    if s == 1 then return a end
    return math.max(1, math.floor(a * s))
end

--- Payouts per period for a mode: hourly = 24*D, daily = D.
function EmergencyLoan.payoutsPerPeriod(payMode, daysPerPeriod)
    local d = tonumber(daysPerPeriod) or 0
    if payMode == Settings.PAY_MODE_HOURLY then return 24 * d end
    return d
end

--- Nominal full-period gross = payoutGross * payoutsPerPeriod.
function EmergencyLoan.periodGross(amount, seasonMult, payMode, daysPerPeriod)
    return EmergencyLoan.payoutGross(amount, seasonMult) * EmergencyLoan.payoutsPerPeriod(payMode, daysPerPeriod)
end

-- =========================================================
-- Sizing: half a period's expected gross, or the 10000 fallback
-- =========================================================

--- Working-cash buffer + basis for a reliable/enabled income stream, else fallback.
---@return number buffer, string basis
function EmergencyLoan.workingCash(periodGross, incomeReliable, incomeEnabled)
    if incomeReliable and incomeEnabled and type(periodGross) == "number"
        and periodGross == periodGross and periodGross > 0 then
        return periodGross / 2, "HALF_PERIOD_GROSS"
    end
    return EmergencyLoan.FALLBACK_BUFFER, "FALLBACK_10000"
end

--- The offered amount from a supported projected minimum. Returns nil + status when
--- unavailable or no shortfall. offer = ceil(shortfall + buffer).
---@return number|nil amount, number|nil buffer, string status/basis
function EmergencyLoan.offerFromMinimum(minimum, periodGross, incomeReliable, incomeEnabled)
    if type(minimum) ~= "number" or minimum ~= minimum
        or minimum == math.huge or minimum == -math.huge then
        return nil, nil, "UNAVAILABLE"
    end
    if minimum >= 0 then return nil, nil, "NO_SHORTFALL" end
    local buffer, basis = EmergencyLoan.workingCash(periodGross, incomeReliable, incomeEnabled)
    return math.ceil(-minimum + buffer), buffer, basis
end

-- =========================================================
-- Native clock pair (shared date contract)
-- =========================================================

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
EmergencyLoan._finite = finite

--- Copy native Environment into {monotonicDay, timeOfDayMs, year, period, dayInPeriod,
--- daysPerPeriod}, validating the shared contract. nil if the clock is not usable.
function EmergencyLoan:clockPair()
    local env = g_currentMission and g_currentMission.environment
    if env == nil then return nil end
    local day = env.currentMonotonicDay
    local ms  = env.dayTime
    if not finite(day) or day < 0 or day % 1 ~= 0 then return nil end
    if not finite(ms) or ms < 0 or ms >= EmergencyLoan.MS_PER_DAY then return nil end
    return {
        monotonicDay = day, timeOfDayMs = ms,
        year = env.currentYear, period = env.currentPeriod,
        dayInPeriod = env.currentDayInPeriod, daysPerPeriod = env.daysPerPeriod,
    }
end

-- =========================================================
-- Outstanding / balance reads
-- =========================================================

function EmergencyLoan:getOutstanding(farmId)
    local d = self.debts[farmId]
    if not d then return 0 end
    return (d.principal or 0) + (d.accruedInterest or 0)
end

function EmergencyLoan:getBalance(farmId)
    if g_farmManager and g_farmManager.getFarmById then
        local ok, farm = pcall(function() return g_farmManager:getFarmById(farmId) end)
        if ok and farm and farm.money ~= nil then return farm.money end
    end
    return nil
end

-- =========================================================
-- Regular-income estimate (IncomeMod's own), in per-period terms
-- =========================================================

--- { reliable, enabled, periodGross, payMode } for the current settings, or a
--- disabled/zero result. Used for both the forecast receipts and the working-cash basis.
function EmergencyLoan:incomeBasis(asOf)
    local sys = self.incomeSystem
    local st  = sys and sys.settings
    if st == nil then
        return { enabled = false, reliable = false, periodGross = 0, payMode = nil }
    end
    local enabled = st.enabled == true
    local amount = (st.getPaymentAmount and st:getPaymentAmount()) or 0
    local seasonMult = (sys.getSeasonalMultiplier and sys:getSeasonalMultiplier()) or 1.0
    local payMode = st.payMode
    local d = (asOf and asOf.daysPerPeriod) or (g_currentMission and g_currentMission.environment
        and g_currentMission.environment.daysPerPeriod)
    local reliable = enabled and finite(amount) and amount > 0 and finite(d or 0) and (d or 0) > 0
    local periodGross = reliable and EmergencyLoan.periodGross(amount, seasonMult, payMode, d) or 0
    return { enabled = enabled, reliable = reliable, periodGross = periodGross, payMode = payMode,
             payoutGross = EmergencyLoan.payoutGross(amount, seasonMult) }
end

-- =========================================================
-- Provider reads (guarded, neutral-when-absent)
-- =========================================================

--- Build the horizon descriptor the providers expect from the shared date contract.
function EmergencyLoan:horizonFor(asOf)
    if asOf == nil or not finite(asOf.daysPerPeriod or 0) then return nil end
    local d = asOf.daysPerPeriod
    return {
        asOf = { monotonicDay = asOf.monotonicDay, timeOfDayMs = asOf.timeOfDayMs },
        horizonEnd = { monotonicDay = asOf.monotonicDay + d, timeOfDayMs = asOf.timeOfDayMs },
        daysPerPeriod = d, dayInPeriod = asOf.dayInPeriod,
        year = asOf.year, period = asOf.period,
    }
end

--- WorkerCosts payroll obligations (colon). Returns the snapshot or nil + a missing code.
function EmergencyLoan:readPayroll(farmId, horizon)
    local wc = g_currentMission and g_currentMission.workerCostsManager
    if wc == nil or type(wc.getPayrollObligations) ~= "function" then
        return nil, "PAYROLL_ABSENT"
    end
    local ok, snap = pcall(function() return wc:getPayrollObligations(farmId, horizon) end)
    if not ok or type(snap) ~= "table" then return nil, "PAYROLL_UNAVAILABLE" end
    return snap, nil
end

--- TaxMod tax projection (DOT). Returns the snapshot or nil + a missing code.
function EmergencyLoan:readTax(farmId, scenario)
    local tax = g_currentMission and g_currentMission.taxManager
    if tax == nil or type(tax.getLoanTaxProjection) ~= "function" then
        return nil, "TAX_ABSENT"
    end
    local ok, snap = pcall(function() return tax.getLoanTaxProjection(farmId, scenario) end)
    if not ok or type(snap) ~= "table" then return nil, "TAX_UNAVAILABLE" end
    return snap, nil
end

-- =========================================================
-- The cash projection (one rolling in-game period)
-- =========================================================

--- Relative ms from asOf to a (dueDay, dueTimeMs), clamped to 0; the common axis.
local function relMs(asOf, dueDay, dueTimeMs)
    return (dueDay - asOf.monotonicDay) * EmergencyLoan.MS_PER_DAY + (dueTimeMs or 0) - asOf.timeOfDayMs
end

--- Build the farm's projected cash path over one period and return the view pieces:
--- { forecastStatus, minimumBalance, shortfall, horizonEnd, expectedGrossIncome,
---   expectedNetIncome, workingCashBasis, workingCashAmount, knownCosts, estimatedCosts,
---   missingInputs }. A failed balance/clock read is UNAVAILABLE, never a false zero.
function EmergencyLoan:buildForecast(farmId)
    local asOf = self:clockPair()
    local missing = {}
    local function miss(code) missing[#missing + 1] = code end

    if asOf == nil then
        return { forecastStatus = "UNAVAILABLE", missingInputs = { "INVALID_CLOCK" } }
    end
    local cash = self:getBalance(farmId)
    if cash == nil then
        return { forecastStatus = "UNAVAILABLE", missingInputs = { "NO_BALANCE" }, asOf = asOf }
    end

    local horizon = self:horizonFor(asOf)
    local horizonEnd = horizon.horizonEnd
    local horizonMs = horizon.daysPerPeriod * EmergencyLoan.MS_PER_DAY

    local basis = self:incomeBasis(asOf)

    -- Collect dated outflow events { atMs, amount<0 }. Known bills first.
    local events = {}
    local knownCosts, estimatedCosts = {}, {}

    -- Payroll bills (known).
    local payroll, pmiss = self:readPayroll(farmId, horizon)
    if pmiss then miss(pmiss) else
        if payroll.status == "PARTIAL" or payroll.status == "UNAVAILABLE" then miss("PAYROLL_PARTIAL") end
        for _, e in ipairs(payroll.events or {}) do
            local amt = (tonumber(e.fixedAmount) or 0) + (tonumber(e.estimatedAmount) or 0)
            if amt > 0 then
                local at = relMs(asOf, e.dueDay, e.dueTimeMs)
                if at <= horizonMs then
                    events[#events + 1] = { atMs = math.max(0, at), amount = -amt }
                    knownCosts[#knownCosts + 1] = { sourceId = e.sourceKey or "payroll",
                        amount = amt, basis = e.basis or "PAYROLL", dueDay = e.dueDay, dueTimeMs = e.dueTimeMs }
                end
            end
        end
    end

    -- Tax bill (known). Scenario = the remaining future daily samples on the tax-free
    -- baseline; TaxMod maps its own March and returns one event.
    local scenario = self:buildTaxScenario(asOf, cash)
    local tax, tmiss = self:readTax(farmId, scenario)
    if tmiss then miss(tmiss) else
        if tax.status == "PARTIAL" then miss("TAX_PARTIAL") end
        for _, e in ipairs((tax and tax.cashEvents) or {}) do
            local amt = tonumber(e.amount) or 0
            if amt > 0 then
                local at = relMs(asOf, e.dueDay, e.dueTimeMs)
                if at <= horizonMs then
                    events[#events + 1] = { atMs = math.max(0, at), amount = -amt }
                    knownCosts[#knownCosts + 1] = { sourceId = "tax", amount = amt,
                        basis = e.basis or "TAX", dueDay = e.dueDay, dueTimeMs = e.dueTimeMs }
                end
            end
        end
    end

    -- Operating-spend estimate (last completed period), spread across the horizon.
    local opSpend = self:estimateOperatingSpend(farmId)
    if opSpend == nil then
        miss("NO_OPERATING_HISTORY")
    elseif opSpend > 0 then
        -- Spread evenly as a daily estimate across the horizon days.
        local perDay = opSpend / math.max(1, horizon.daysPerPeriod)
        for day = 1, horizon.daysPerPeriod do
            events[#events + 1] = { atMs = day * EmergencyLoan.MS_PER_DAY, amount = -perDay, estimate = true }
        end
        estimatedCosts[#estimatedCosts + 1] = { sourceId = "operating", amount = opSpend,
            basis = "LAST_PERIOD_OPERATING" }
    end

    -- Regular income receipts (NET while debt stands: simulate the 25% auto-repay).
    local tempDebt = self:getOutstanding(farmId)
    local expectedGross, expectedNet = 0, 0
    if basis.reliable then
        local perPayout = basis.payoutGross
        local payouts = EmergencyLoan.payoutsPerPeriod(basis.payMode, horizon.daysPerPeriod)
        local stepMs = (payouts > 0) and (horizonMs / payouts) or horizonMs
        for i = 1, payouts do
            local gross = perPayout
            expectedGross = expectedGross + gross
            local net = gross
            if tempDebt > 0 then
                local deduct = math.min(math.floor(gross * EmergencyLoan.REPAYMENT_SHARE), tempDebt)
                tempDebt = tempDebt - deduct
                net = gross - deduct
            end
            expectedNet = expectedNet + net
            events[#events + 1] = { atMs = math.min(horizonMs, i * stepMs), amount = net, estimate = true }
        end
        miss("SLEEP_SKIPS_REGULAR_PAYMENTS")
    else
        if not basis.enabled then miss("INCOME_DISABLED") else miss("INCOME_UNRELIABLE") end
    end

    -- Native daily bank-loan interest (the one live-calculated charge).
    -- (Represented only if a native loan is present; neutral otherwise.)

    -- Walk the timeline in time order; track the lowest balance WITHIN the horizon.
    table.sort(events, function(a, b) return a.atMs < b.atMs end)
    local running, minimum = cash, cash
    for _, e in ipairs(events) do
        running = running + e.amount
        if running < minimum then minimum = running end
    end

    local forecastStatus = (#missing > 0) and "PARTIAL" or "OK"
    -- A present but negative current cash is itself a real shortage even if some inputs
    -- are missing (the reliable native balance qualifies).
    return {
        forecastStatus     = forecastStatus,
        asOf               = asOf,
        horizonEnd         = horizonEnd,
        cash               = cash,
        minimumBalance     = minimum,
        shortfall          = math.max(0, -minimum),
        expectedGrossIncome = expectedGross,
        expectedNetIncome  = expectedNet,
        workingCashBasis   = nil,   -- filled by the offer computation
        workingCashAmount  = nil,
        knownCosts         = knownCosts,
        estimatedCosts     = estimatedCosts,
        missingInputs      = missing,
        _incomeBasis       = basis,
    }
end

--- The ascending future-daily scenario C3 submits to TaxMod (pre-tax baseline). Each
--- sample carries the native day coords + the projected pre-tax balance; TaxMod maps
--- its own March. Kept to the one-period horizon.
function EmergencyLoan:buildTaxScenario(asOf, startingCash)
    local scenario = {}
    local d = asOf.daysPerPeriod
    if not finite(d) or d < 1 then return scenario end
    for i = 1, d do
        scenario[#scenario + 1] = {
            isFuture     = true,
            monotonicDay = asOf.monotonicDay + i,
            timeOfDayMs  = 0,
            year         = asOf.year,
            period       = asOf.period,
            balance      = startingCash,  -- pre-tax baseline (TaxMod owns the tax math)
        }
    end
    return scenario
end

--- Last completed period's approved operating spend (native), or nil if unknown. Reads
--- FarmStats categories; excludes capital/sale/proceeds/historical loan interest and any
--- category already covered by a known forward owner bill (wages -> payroll provider).
function EmergencyLoan:estimateOperatingSpend(farmId)
    local stats = self:farmStats(farmId)
    if stats == nil then return nil end
    local categories = { "propertyMaintenance", "productionCosts", "purchaseFuel", "vehicleRunningCost" }
    -- If WorkerCosts is the payroll owner, native wage/lease is replaced by its bill.
    local wcPresent = (g_currentMission and g_currentMission.workerCostsManager) ~= nil
    if not wcPresent then
        categories[#categories + 1] = "wagePayment"
        categories[#categories + 1] = "leasingCost"
    end
    local total, any = 0, false
    for _, cat in ipairs(categories) do
        local v = stats[cat]
        if finite(v or 0) then
            total = total + math.abs(v or 0)
            any = true
        end
    end
    if not any then return nil end
    return total
end

--- Last-completed-period FarmStats expense map for a farm, or nil. Guarded; reads the
--- native finance stats only (no mutation).
function EmergencyLoan:farmStats(farmId)
    local fm = g_farmManager
    if fm == nil or fm.getFarmById == nil then return nil end
    local ok, farm = pcall(function() return fm:getFarmById(farmId) end)
    if not ok or farm == nil or farm.stats == nil then return nil end
    local stats = farm.stats
    local out = {}
    local getter = stats.getHistory or stats.getLastPeriodValue
    -- The engine exposes period expense history; when the precise getter is unavailable
    -- offline, fall back to any flat fields present. Neutral (nil) when nothing is read.
    if type(stats.getTotal) == "function" then
        for _, cat in ipairs({ "propertyMaintenance", "productionCosts", "purchaseFuel",
                               "vehicleRunningCost", "wagePayment", "leasingCost" }) do
            local ok2, v = pcall(function() return stats:getTotal(cat) end)
            if ok2 and finite(v or 0) then out[cat] = v end
        end
        if next(out) ~= nil then return out end
    end
    return nil
end

--- The trigger: the supported projected minimum is below zero.
function EmergencyLoan:isForecastRed(farmId)
    local f = self:buildForecast(farmId)
    if f.forecastStatus == "UNAVAILABLE" then
        -- A reliable negative native balance still qualifies.
        local cash = self:getBalance(farmId)
        return finite(cash or 0) and (cash or 0) < 0
    end
    return (f.minimumBalance ~= nil) and f.minimumBalance < 0
end

-- =========================================================
-- Offer / grant / redraw
-- =========================================================

--- The offered loan amount for a farm (shortfall + working cash), or 0 when not red /
--- unavailable. Also returns the basis/amount for the view.
function EmergencyLoan:computeOffer(farmId)
    local f = self:buildForecast(farmId)
    local basis = f._incomeBasis or self:incomeBasis(f.asOf)
    local amount, buffer, status = EmergencyLoan.offerFromMinimum(
        f.minimumBalance, basis.periodGross, basis.reliable, basis.enabled)
    return amount, buffer, status, f
end

--- Grant a fresh loan (server-authoritative). A per-farm guard prevents stacking a
--- second fresh loan; a re-draw grows the ONE line via redraw().
function EmergencyLoan:grant(farmId)
    if g_server == nil then return false, 0 end
    if self.readiness == EmergencyLoan.READINESS.UNAVAILABLE then return false, 0 end
    if self.debts[farmId] and self.debts[farmId].active then return false, 0 end

    local amount = self:computeOffer(farmId)
    if not amount or amount <= 0 then return false, 0 end

    if g_currentMission and g_currentMission.addMoney then
        g_currentMission:addMoney(amount, farmId, MoneyType.OTHER, true)
    else
        return false, 0
    end

    local drawMonth = self:currentMonthCounter()
    self.debts[farmId] = {
        principal       = amount,
        accruedInterest = 0,
        drawCount       = 1,
        revision        = 1,
        active          = true,
        lastSettledMonth = drawMonth,
        interestEligibleFromMonth = drawMonth and (drawMonth + 2) or nil,
        pendingEligibility = {},
    }
    self:registerInterestAccrual(farmId)
    Logging.info("Income Mod: Emergency loan of %.0f granted to farm %s", amount, tostring(farmId))
    return true, amount
end

--- Re-draw: grow the existing line (steps amount + cost). Falls back to grant if none.
function EmergencyLoan:redraw(farmId)
    if g_server == nil then return false, 0 end
    local debt = self.debts[farmId]
    if not debt or not debt.active then return self:grant(farmId) end

    local amount = self:computeOffer(farmId)
    if not amount or amount <= 0 then return false, 0 end

    if g_currentMission and g_currentMission.addMoney then
        g_currentMission:addMoney(amount, farmId, MoneyType.OTHER, true)
    else
        return false, 0
    end

    debt.principal = (debt.principal or 0) + amount
    debt.drawCount = (debt.drawCount or 0) + 1
    debt.revision  = (debt.revision or 0) + 1
    self:registerInterestAccrual(farmId)
    Logging.info("Income Mod: Emergency loan re-drawn +%.0f for farm %s (draw %d)",
        amount, tostring(farmId), debt.drawCount)
    return true, amount
end

-- =========================================================
-- The ONE payment helper: interest first, then principal
-- =========================================================

--- Allocate an approved payment to accrued interest first, then principal (proportional
--- across eligible and not-yet-eligible principal portions, with the final portion taking
--- the exact arithmetic remainder). Returns the amount actually applied. Pure state math;
--- the cash move is the caller's (server-gated) responsibility.
function EmergencyLoan:allocatePayment(debt, amount)
    if not debt then return 0 end
    local outstanding = (debt.principal or 0) + (debt.accruedInterest or 0)
    local pay = math.min(amount, outstanding)
    if pay <= 0 then return 0 end

    local fromInterest = math.min(pay, debt.accruedInterest or 0)
    debt.accruedInterest = (debt.accruedInterest or 0) - fromInterest
    local fromPrincipal = pay - fromInterest
    debt.principal = (debt.principal or 0) - fromPrincipal

    -- Reduce pendingEligibility portions proportionally (interest first, then principal).
    self:_reducePending(debt, fromInterest, fromPrincipal)

    debt.revision = (debt.revision or 0) + 1
    if (debt.principal or 0) <= 1e-6 and (debt.accruedInterest or 0) <= 1e-6 then
        debt.principal, debt.accruedInterest = 0, 0
        debt.active = false
    end
    return pay
end

function EmergencyLoan:_reducePending(debt, fromInterest, fromPrincipal)
    local portions = debt.pendingEligibility
    if type(portions) ~= "table" or #portions == 0 then return end
    local totalP, totalI = 0, 0
    for _, p in ipairs(portions) do totalP = totalP + (p.principal or 0); totalI = totalI + (p.accruedInterest or 0) end
    for i, p in ipairs(portions) do
        local last = (i == #portions)
        if totalI > 0 and fromInterest > 0 then
            local share = last and p.accruedInterest or (fromInterest * ((p.accruedInterest or 0) / totalI))
            p.accruedInterest = math.max(0, (p.accruedInterest or 0) - share)
        end
        if totalP > 0 and fromPrincipal > 0 then
            local share = last and p.principal or (fromPrincipal * ((p.principal or 0) / totalP))
            p.principal = math.max(0, (p.principal or 0) - share)
        end
    end
    -- Retire emptied portions.
    local kept = {}
    for _, p in ipairs(portions) do
        if (p.principal or 0) > 1e-6 or (p.accruedInterest or 0) > 1e-6 then kept[#kept + 1] = p end
    end
    debt.pendingEligibility = kept
end

--- Automatic repayment from a scheduled income payout (server-only). Deducts the ruled
--- 25% share of the gross, allocates it, moves the cash, and retires a paid line.
function EmergencyLoan:applyRepayment(farmId, incomeAmount)
    if g_server == nil or incomeAmount <= 0 then return 0 end
    local d = self.debts[farmId]
    if not d or not d.active then return 0 end
    local outstanding = (d.principal or 0) + (d.accruedInterest or 0)
    if outstanding <= 0 then return 0 end

    local deduct = math.min(math.floor(incomeAmount * EmergencyLoan.REPAYMENT_SHARE), outstanding)
    if deduct <= 0 then return 0 end

    self:allocatePayment(d, deduct)
    if g_currentMission and g_currentMission.addMoney then
        g_currentMission:addMoney(-deduct, farmId, MoneyType.OTHER, true)
    end
    if not d.active then
        self.debts[farmId] = nil
        self:unregisterInterestAccrual(farmId)
    end
    Logging.info("Income Mod: Emergency loan repayment -%.0f for farm %s", deduct, tostring(farmId))
    return deduct
end

--- The exact remaining payoff amount (principal + all accrued interest), full precision.
function EmergencyLoan:payoffAmount(farmId)
    return self:getOutstanding(farmId)
end

--- Apply a manual payment / payoff (server-only). `amount` is the server-quoted value;
--- a payoff passes the exact outstanding. Creates no income/history entry. Returns the
--- applied amount (0 if nothing owed / invalid). The caller verified cash and rights.
function EmergencyLoan:applyManualPayment(farmId, amount)
    if g_server == nil then return 0 end
    local d = self.debts[farmId]
    if not d or not d.active then return 0 end
    if not finite(amount) or amount <= 0 then return 0 end
    local applied = self:allocatePayment(d, amount)
    if applied <= 0 then return 0 end
    if g_currentMission and g_currentMission.addMoney then
        g_currentMission:addMoney(-applied, farmId, MoneyType.OTHER, true)
    end
    if not d.active then
        self.debts[farmId] = nil
        self:unregisterInterestAccrual(farmId)
    end
    Logging.info("Income Mod: Emergency loan manual payment -%.2f for farm %s", applied, tostring(farmId))
    return applied
end

-- =========================================================
-- The public view (exact C3 version 1 shape)
-- =========================================================

--- Build the authoritative view for a farm. actorContext (optional) carries whether the
--- requesting actor may borrow/repay; a pure server sample passes nil => NO_ACTOR_CONTEXT.
function EmergencyLoan:getView(farmId, actorContext)
    local f = self:buildForecast(farmId)
    local debt = self.debts[farmId]
    local readiness = self:getReadiness()
    local offer, buffer, offerStatus = nil, nil, nil
    if f.minimumBalance ~= nil then
        local basis = f._incomeBasis or self:incomeBasis(f.asOf)
        offer, buffer, offerStatus = EmergencyLoan.offerFromMinimum(
            f.minimumBalance, basis.periodGross, basis.reliable, basis.enabled)
    end
    local basis = f._incomeBasis or {}
    local wcBasis = buffer and (offerStatus == "HALF_PERIOD_GROSS" and "HALF_PERIOD_GROSS" or "FALLBACK_10000") or nil

    local principal = debt and debt.principal or (readiness == EmergencyLoan.READINESS.READY and 0 or nil)
    local accrued   = debt and debt.accruedInterest or (readiness == EmergencyLoan.READINESS.READY and 0 or nil)
    local outstanding = (principal ~= nil and accrued ~= nil) and (principal + accrued) or nil

    local canBorrow, borrowReason = false, nil
    local canRepay, repayReason = false, nil
    if actorContext == nil or actorContext.isManager ~= true then
        borrowReason = "NO_ACTOR_CONTEXT"
        repayReason  = "NO_ACTOR_CONTEXT"
    else
        if readiness ~= EmergencyLoan.READINESS.READY then
            borrowReason, repayReason = "DEBT_LOADING", "DEBT_LOADING"
        else
            if offer and offer > 0 then canBorrow = true else borrowReason = offerStatus or "NO_SHORTFALL" end
            if (outstanding or 0) > 0 and (f.cash ~= nil and f.cash > 0) then canRepay = true
            else repayReason = ((outstanding or 0) > 0) and "NO_CASH" or "NO_DEBT" end
        end
    end

    return {
        version = EmergencyLoan.VIEW_VERSION,
        farmId = farmId,
        revision = debt and debt.revision or 0,
        readiness = readiness,
        asOf = f.asOf,
        cash = f.cash,
        nativeLoan = self:nativeLoan(farmId),
        principal = principal,
        accruedInterest = accrued,
        outstanding = outstanding,
        drawCount = debt and debt.drawCount or 0,
        effectiveMonthlyRate = self:isCostReady() and (debt and self:effectiveRate(debt) or 0) or 0,
        costLockReason = self:costLockReason(),
        automaticRepaymentShare = EmergencyLoan.REPAYMENT_SHARE,
        forecastStatus = f.forecastStatus,
        horizonEnd = f.horizonEnd,
        minimumBalance = f.minimumBalance,
        shortfall = f.shortfall,
        expectedGrossIncome = f.expectedGrossIncome,
        expectedNetIncome = f.expectedNetIncome,
        workingCashBasis = wcBasis,
        workingCashAmount = buffer,
        knownCosts = f.knownCosts,
        estimatedCosts = f.estimatedCosts,
        missingInputs = f.missingInputs,
        offer = offer,
        canBorrow = canBorrow, borrowReason = borrowReason,
        canRepay = canRepay, repayReason = repayReason,
    }
end

--- Native bank-loan principal for context (read-only), or nil.
function EmergencyLoan:nativeLoan(farmId)
    local fm = g_farmManager
    if fm == nil or fm.getFarmById == nil then return nil end
    local ok, farm = pcall(function() return fm:getFarmById(farmId) end)
    if not ok or farm == nil then return nil end
    return finite(farm.loan or 0) and farm.loan or nil
end

-- =========================================================
-- Persistence snapshot (StateLedger twin + own-XML shape)
-- =========================================================

EmergencyLoan.SCHEMA = 2

function EmergencyLoan:serialize()
    local debts = {}
    for farmId, d in pairs(self.debts) do
        debts[farmId] = {
            principal = d.principal or 0, accruedInterest = d.accruedInterest or 0,
            drawCount = d.drawCount or 1, revision = d.revision or 1,
            active = d.active ~= false,
            lastSettledMonth = d.lastSettledMonth, interestEligibleFromMonth = d.interestEligibleFromMonth,
            pendingEligibility = d.pendingEligibility or {},
        }
    end
    return { schema = EmergencyLoan.SCHEMA, debts = debts }
end

--- Install a validated snapshot ONCE. A valid new-format empty snapshot is authoritative
--- empty (not a merge). Never resurrect paid lines on a late callback; preserve current
--- session debt for a farm already present (merge-never-replace at the farm level).
function EmergencyLoan:deserialize(data)
    if type(data) ~= "table" or type(data.debts) ~= "table" then return false end
    for farmId, d in pairs(data.debts) do
        if self.debts[farmId] == nil and type(d) == "table" then
            self.debts[farmId] = {
                principal = tonumber(d.principal) or 0,
                accruedInterest = tonumber(d.accruedInterest) or 0,
                drawCount = tonumber(d.drawCount) or 1,
                revision = tonumber(d.revision) or 1,
                active = d.active ~= false and ((tonumber(d.principal) or 0) + (tonumber(d.accruedInterest) or 0) > 0),
                lastSettledMonth = tonumber(d.lastSettledMonth),
                interestEligibleFromMonth = tonumber(d.interestEligibleFromMonth),
                pendingEligibility = type(d.pendingEligibility) == "table" and d.pendingEligibility or {},
            }
        end
    end
    if self.readiness == EmergencyLoan.READINESS.LOADING then
        self.readiness = EmergencyLoan.READINESS.READY
    end
    return true
end

-- =========================================================
-- Native MP-to-SP farm conversion remap
-- =========================================================

--- Pool each mapped origin's debt into the surviving farm: sum principal + posted
--- interest, take the MAX draw count (no new draw), keep the earliest unelapsed
--- eligibility as a pendingEligibility portion. Applied once before READY; a repeat map
--- cannot double-pool because the origin is consumed.
function EmergencyLoan:remapMergedFarms(mergedFarms)
    if type(mergedFarms) ~= "table" then return end
    for oldId, target in pairs(mergedFarms) do
        if target ~= nil and target ~= oldId and self.debts[oldId] ~= nil then
            local src = self.debts[oldId]
            self.debts[oldId] = nil
            local dst = self.debts[target]
            if dst == nil then
                src.revision = (src.revision or 1) + 1
                self.debts[target] = src
            else
                dst.principal = (dst.principal or 0) + (src.principal or 0)
                dst.accruedInterest = (dst.accruedInterest or 0) + (src.accruedInterest or 0)
                dst.drawCount = math.max(dst.drawCount or 1, src.drawCount or 1)
                dst.revision = (dst.revision or 1) + 1
                dst.active = ((dst.principal or 0) + (dst.accruedInterest or 0)) > 0
                dst.pendingEligibility = dst.pendingEligibility or {}
                for _, p in ipairs(src.pendingEligibility or {}) do
                    dst.pendingEligibility[#dst.pendingEligibility + 1] = p
                end
            end
        end
    end
end

-- =========================================================
-- Day-boundary forecast cache refresh
-- =========================================================

function EmergencyLoan:onDayChange()
    self._cacheDay = g_currentMission and g_currentMission.environment
        and g_currentMission.environment.currentMonotonicDay or 0
end
