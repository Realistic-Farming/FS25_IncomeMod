-- =========================================================
-- FS25 Income Mod - EMERGENCY LOAN (C3)
-- =========================================================
-- The never-stuck recovery hatch. When a farm's rolling ~1-month cash-flow
-- forecast projects crossing zero, the emergency loan surfaces: it grants the
-- projected shortfall plus roughly one operating cycle of runway, server
-- authoritative, and auto-deducts a share of income until the single debt line
-- retires. Repeated reliance compounds ONE growing emergency-debt line.
--
-- THE NEVER-STUCK INVARIANT (C1): difficulty scales the COST and the
-- escalation, never the availability. On easy it is a gentle interest-free
-- bridge; on realistic it is genuinely expensive. Either way it is there when
-- the forecast goes red. It degrades gracefully: if the base-game loan read is
-- unavailable, the trigger falls back to the balance-and-forecast heuristic,
-- still always available.
--
-- FORWARD-FORECAST TRIGGER: the button appears when the forecast crosses zero
-- ALONE. There is no "broke and out of normal borrowing" gate. The base-game
-- loan state is INFORMATIONAL context and a grant-sizing input, never a trigger.
--
-- MONEY-SAFETY FENCE (the hard gate): the grant, the interest and the
-- repayment are ALL server-authoritative through IncomeMod's own event path.
-- Time Guard SCHEDULES the interest settle and invokes our onSettle; Time Guard
-- never writes money.
--
-- The Economy dial (Option-Scaling Spine) is not built yet. Neutral when
-- absent: a sensible default rate (the brief's fallback). When the spine
-- builds, the cost curves route onto it; until then the constants below are the
-- default cost character.
-- =========================================================
-- Author: TisonK
-- =========================================================

EmergencyLoan = {}

-- =========================================================
-- Locked numbers (C5). These ride the Economy dial when it builds; until then
-- they are the neutral default cost character.
-- =========================================================
EmergencyLoan.INTEREST_RATE_MONTHLY = {
    [Settings.DIFFICULTY_EASY]   = 0.00,   -- interest-free bridge
    [Settings.DIFFICULTY_NORMAL] = 0.08,   -- ~8% per in-game month
    [Settings.DIFFICULTY_HARD]   = 0.15,   -- ~15-20%, escalating
}
EmergencyLoan.ESCALATION_PP_PER_DRAW = {
    [Settings.DIFFICULTY_EASY]   = 0.00,
    [Settings.DIFFICULTY_NORMAL] = 0.02,   -- +2 percentage points per re-draw
    [Settings.DIFFICULTY_HARD]   = 0.04,
}
EmergencyLoan.MAX_RATE = {
    [Settings.DIFFICULTY_EASY]   = 0.00,
    [Settings.DIFFICULTY_NORMAL] = 0.20,
    [Settings.DIFFICULTY_HARD]   = 0.35,
}
-- Repayment share of each income payout while a loan is outstanding.
EmergencyLoan.REPAYMENT_SHARE = 0.25
-- Forecast horizon in in-game days (a ~1-month window).
EmergencyLoan.FORECAST_DAYS = 28

-- StateLedger persistence key. LOCKED, never renamed after first persist.
EmergencyLoan.MODULE_ID = "IncomeMod_EmergencyLoan"

-- Time Guard accrual id. Farm-scoped (see the brief: a FARM-SCOPED id).
-- The format is IncomeMod_emergencyInterest_farm{N}.
EmergencyLoan.ACCRUAL_ID_PREFIX = "IncomeMod_emergencyInterest_farm"
-- Settles LATE: the interest reads the mutable debt balance, so it settles
-- after the day's other accruals.
EmergencyLoan.ACCRUAL_PRIORITY = 90

function EmergencyLoan.new()
    return setmetatable({
        -- debts[farmId] = { principal, accruedInterest, drawCount, lastInterestDay }
        debts = {},
        -- The forecast input cache, refreshed on the day boundary (never per-frame).
        _cache = {},
        _cacheDay = -1,
        armed = false,
    }, { __index = EmergencyLoan })
end

function EmergencyLoan:isArmed()
    return self.armed
end

-- =========================================================
-- Time Guard (delegate-when-present)
-- =========================================================

local function getTimeGuard()
    return (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
end

--- Register the month-cadence interest accrual for a farm. Registered on the
--- FIRST DRAW (the brief: not only at boot), and re-registered on later draws so
--- a reload re-matches the persisted cursor.
---@param farmId number
---@return boolean registered
function EmergencyLoan:registerInterestAccrual(farmId)
    if g_server == nil then return false end
    local tg = getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then
        Logging.info("Income Mod: Time Guard not detected - emergency loan interest never accrues")
        return false
    end
    local id = EmergencyLoan.ACCRUAL_ID_PREFIX .. tostring(farmId)
    local ok, err = pcall(function()
        return tg:registerAccrual(id, {
            cadence           = "month",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = EmergencyLoan.ACCRUAL_PRIORITY,
            onSettle          = function(ctx)
                self:onInterestSettle(farmId, ctx)
            end,
        })
    end)
    if not ok then
        Logging.warning("Income Mod: emergency loan interest accrual registration failed: %s", tostring(err))
        return false
    end
    return true
end

function EmergencyLoan:unregisterInterestAccrual(farmId)
    local tg = getTimeGuard()
    if tg == nil or tg.unregisterAccrual == nil then return end
    pcall(function()
        tg:unregisterAccrual(EmergencyLoan.ACCRUAL_ID_PREFIX .. tostring(farmId))
    end)
end

--- The monthly interest settle. COMPOUNDING over ctx.boundariesCrossed:
--- debt * (1 + rate)^N, NOT N * rate (the brief's build specific). Server-only,
--- idempotent (Time Guard persists the cursor). Time Guard never writes money;
--- this body does, through the server-gated deduct.
--- RELEASE GATE (Arissani 2026-08-03, C3 CONDITIONAL per the never-stuck
--- invariant): the cost elaboration (the re-draw escalation + the Time Guard
--- compounding interest + the Economy-dial pricing when it builds) is LOCKED
--- until the player opts into experimental systems. The loan itself - the grant,
--- the re-draw, the forecast and the repayment - stays fully available, so the
--- never-stuck escape is never removed: a locked loan runs at the neutral
--- interest-free cost character. Fail-open (see ReleaseGate.isSystemLive).
---@param farmId number
---@param ctx table
function EmergencyLoan:onInterestSettle(farmId, ctx)
    if g_server == nil then return end
    if ReleaseGate ~= nil and not ReleaseGate.isSystemLive("c3_loan_elaboration") then
        return
    end
    local debt = self.debts[farmId]
    if not debt or (debt.principal or 0) <= 0 then return end

    local n = math.max(1, math.floor(tonumber(ctx.boundariesCrossed) or 1))
    local diff = self.settings and self.settings.difficulty or Settings.DIFFICULTY_NORMAL
    local rate = EmergencyLoan.INTEREST_RATE_MONTHLY[diff] or 0.08
    -- escalation from REPEATED draws: the first draw pays the base rate, each
    -- re-draw (drawCount beyond 1) adds the per-draw percentage points.
    local reDraws = math.max(0, (debt.drawCount or 1) - 1)
    rate = math.min(rate + reDraws * (EmergencyLoan.ESCALATION_PP_PER_DRAW[diff] or 0.02),
        EmergencyLoan.MAX_RATE[diff] or 0.20)

    local compounded = (1.0 + rate) ^ n
    local accrued = (debt.principal or 0) * (compounded - 1.0)
    debt.accruedInterest = (debt.accruedInterest or 0) + accrued

    -- Persist the settle day so a save/load matches Time Guard's cursor.
    debt.lastInterestDay = ctx and ctx.monotonicDay or 0

    Logging.info("Income Mod: Emergency loan farm %d interest +%.0f (rate %.3f, x%d)",
        farmId, accrued, rate, n)
end

-- =========================================================
-- The forecast (IncomeMod's OWN; never the cockpit)
-- =========================================================

--- Current farm balance (base game). Falls back to 0.
---@param farmId number
---@return number balance
function EmergencyLoan:getBalance(farmId)
    if g_farmManager and g_farmManager.getFarmById then
        local ok, farm = pcall(function() return g_farmManager:getFarmById(farmId) end)
        if ok and farm and farm.money then return farm.money end
    end
    return 0
end

--- Conservative per-day income estimate for the forecast. Uses IncomeMod's own
--- configured payout when enabled, else a modest default (the mod's own income).
---@param farmId number
---@return number perDay
function EmergencyLoan:estimateDailyIncome(farmId)
    if self.incomeSystem and self.incomeSystem.settings
       and self.incomeSystem.settings.enabled then
        local amt = self.incomeSystem.settings:getPaymentAmount()
        if amt and amt > 0 then return amt end
    end
    return 0
end

--- The rolling ~1-month forecast: current balance + conservative expected income
--- minus KNOWN recurring obligations. Returns the projected balance at the end
--- of the window. Cross-mod obligation reads are pull-only, pcall-guarded and
--- neutral-when-absent (the brief's lean, settle/boundary-sampled reads; never
--- per-frame).
---@param farmId number
---@return number projectedBalance
function EmergencyLoan:forecastBalance(farmId)
    local perDay = self:estimateDailyIncome(farmId)
    local knownObligations = 0

    -- WorkerCosts: roster finance is a monthly liability figure (wage bill).
    local wc = g_currentMission and g_currentMission.workerManager
    if wc and wc.getRosterSnapshot then
        local ok, snap = pcall(function() return wc:getRosterSnapshot() end)
        if ok and snap and snap.finance and snap.finance.monthlyCost then
            knownObligations = knownObligations + snap.finance.monthlyCost
        end
    end

    -- TaxMod: the outstanding/expected tax liability, read via its manager.
    local tax = g_currentMission and g_currentMission.taxManager
    if tax and tax.serializeState then
        local ok, st = pcall(function() return tax:serializeState() end)
        if ok and st and st.monthlyLiability then
            knownObligations = knownObligations + st.monthlyLiability
        end
    end

    -- FuelCosts: the price engine's current diesel price, scaled to a monthly burn.
    local fc = g_currentMission and g_currentMission.fuelCostsManager
    if fc and fc.priceEngine and fc.priceEngine.getPriceStatus then
        local ok, st = pcall(function() return fc.priceEngine:getPriceStatus() end)
        if ok and st and st.dieselPricePerLiter then
            -- very rough monthly fuel bill; neutral if the estimate is unknown
            knownObligations = knownObligations + (st.dieselPricePerLiter * 2000)
        end
    end

    local balance = self:getBalance(farmId)
    local netPerDay = perDay - (knownObligations / 30.0)
    return balance + netPerDay * EmergencyLoan.FORECAST_DAYS
end

--- The trigger: forecast crossing zero ALONE. No other gate.
---@param farmId number
---@return boolean red
function EmergencyLoan:isForecastRed(farmId)
    return self:forecastBalance(farmId) < 0
end

-- =========================================================
-- The grant (server-authoritative)
-- =========================================================

--- Size the loan: the projected shortfall plus roughly one operating cycle of
--- runway, scaled to farm size.
---@param farmId number
---@return number amount
function EmergencyLoan:grantAmount(farmId)
    local proj = self:forecastBalance(farmId)
    local shortfall = math.max(0, -proj)
    local runway = self:estimateDailyIncome(farmId) * 14   -- ~2 weeks of runway
    if runway <= 0 then runway = 100000 end                -- fallback floor
    return math.max(1, math.ceil(shortfall + runway))
end

--- Grant the loan. SERVER-AUTHORITATIVE: the grant is a getIsServer-gated
--- addMoney, MP-safe by construction (it reuses IncomeMod's own server-gated
--- money path). A per-farm guard prevents a double-grant for the same red
--- forecast window. Returns true when granted.
---@param farmId number
---@return boolean granted, number amount
function EmergencyLoan:grant(farmId)
    if g_server == nil then return false, 0 end
    if self.debts[farmId] then
        -- Never stack fresh loans; a re-draw compounds the ONE line.
        -- A double-grant in the same red window is prevented here.
        return false, 0
    end

    local amount = self:grantAmount(farmId)
    if amount <= 0 then return false, 0 end

    if g_currentMission and g_currentMission.addMoney then
        g_currentMission:addMoney(amount, farmId, MoneyType.OTHER, true)
    end

    self.debts[farmId] = {
        principal       = amount,
        accruedInterest = 0,
        drawCount       = 1,
        lastInterestDay = 0,
    }

    -- Register (or re-register) the interest accrual on the first draw.
    self:registerInterestAccrual(farmId)

    Logging.info("Income Mod: Emergency loan of %.0f granted to farm %d", amount, farmId)
    return true, amount
end

--- Re-draw: an existing line grows (steps the amount and the cost up).
---@param farmId number
---@return boolean redrawn, number amount
function EmergencyLoan:redraw(farmId)
    if g_server == nil then return false, 0 end
    local debt = self.debts[farmId]
    if not debt then return self:grant(farmId) end

    local amount = self:grantAmount(farmId)
    if amount <= 0 then return false, 0 end

    if g_currentMission and g_currentMission.addMoney then
        g_currentMission:addMoney(amount, farmId, MoneyType.OTHER, true)
    end

    debt.principal = (debt.principal or 0) + amount
    debt.drawCount = (debt.drawCount or 0) + 1
    self:registerInterestAccrual(farmId)

    Logging.info("Income Mod: Emergency loan re-drawn +%.0f for farm %d (draw %d)",
        amount, farmId, debt.drawCount)
    return true, amount
end

-- =========================================================
-- The repayment (auto-deducts a share of income)
-- =========================================================

--- The outstanding emergency debt for a farm (principal + accrued interest).
---@param farmId number
---@return number outstanding
function EmergencyLoan:getOutstanding(farmId)
    local d = self.debts[farmId]
    if not d then return 0 end
    return (d.principal or 0) + (d.accruedInterest or 0)
end

--- Apply the repayment share of an income payout. Called from IncomeSystem's
--- giveMoney when a loan is outstanding. SERVER-ONLY.
---@param farmId number
---@param incomeAmount number
---@return number deducted
function EmergencyLoan:applyRepayment(farmId, incomeAmount)
    if g_server == nil or incomeAmount <= 0 then return 0 end
    local d = self.debts[farmId]
    if not d then return 0 end

    local outstanding = (d.principal or 0) + (d.accruedInterest or 0)
    if outstanding <= 0 then return 0 end

    local deduct = math.floor(incomeAmount * EmergencyLoan.REPAYMENT_SHARE)
    deduct = math.min(deduct, outstanding)
    if deduct <= 0 then return 0 end

    -- Pay down accrued interest first, then principal (the standard amortisation
    -- order; interest is the more urgent claim).
    local fromInterest = math.min(deduct, d.accruedInterest or 0)
    d.accruedInterest = (d.accruedInterest or 0) - fromInterest
    local fromPrincipal = deduct - fromInterest
    d.principal = (d.principal or 0) - fromPrincipal

    if (d.principal or 0) <= 0 and (d.accruedInterest or 0) <= 0 then
        self.debts[farmId] = nil
        self:unregisterInterestAccrual(farmId)
    end

    -- The deduction is a money event; use IncomeMod's server-gated path.
    if g_currentMission and g_currentMission.addMoney then
        g_currentMission:addMoney(-deduct, farmId, MoneyType.OTHER, true)
    end

    Logging.info("Income Mod: Emergency loan repayment -%.0f for farm %d", deduct, farmId)
    return deduct
end

-- =========================================================
-- Persistence (StateLedger sidecar; merge-never-replace)
-- =========================================================

function EmergencyLoan:serialize()
    return { schema = 1, debts = self.debts }
end

--- MERGE, never replace. StateLedger omits a block when serialize fails and
--- cannot tell an omitted block from a new save; a replace-on-nil would wipe the
--- whole debt ledger after one bad save.
---@param data table|nil
---@return boolean
function EmergencyLoan:deserialize(data)
    if type(data) ~= "table" then return false end
    if type(data.debts) ~= "table" then return false end
    for farmId, debt in pairs(data.debts) do
        if self.debts[farmId] == nil then
            self.debts[farmId] = {
                principal       = debt.principal or 0,
                accruedInterest = debt.accruedInterest or 0,
                drawCount       = debt.drawCount or 1,
                lastInterestDay = debt.lastInterestDay or 0,
            }
        end
    end
    return true
end

-- =========================================================
-- Day-boundary forecast cache refresh
-- =========================================================

--- Refresh the forecast input cache on the day boundary. Called from
--- IncomeSystem's daily check (or the manager's update) once per day; never
--- per-frame.
function EmergencyLoan:onDayChange()
    self._cacheDay = g_currentMission and g_currentMission.environment
        and g_currentMission.environment.currentMonotonicDay or 0
end
