-- =========================================================
-- FS25 Income Mod (version 2.1.6.1)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================

---@class IncomeSystem
IncomeSystem = {}
local IncomeSystem_mt = Class(IncomeSystem)

IncomeSystem.MAX_HISTORY = 10

-- Catch-up limits: how many missed interval payments a single check may pay out.
-- Protects against a corrupted or mismatched state file paying a fortune on load.
IncomeSystem.MAX_CATCHUP_HOURLY = 24
IncomeSystem.MAX_CATCHUP_DAILY  = 7

function IncomeSystem.new(settings)
    local self = setmetatable({}, IncomeSystem_mt)
    self.settings         = settings
    self.lastHour         = -1
    self.lastDay          = -1
    self.lastMonotonicDay = -1
    self.lastMinuteCheck  = -1
    self.isInitialized    = false
    self.paymentHistory   = {}
    return self
end

-- =========================================================
-- Initialization
-- =========================================================

function IncomeSystem:initialize()
    if self.isInitialized then
        return
    end

    if not g_currentMission or not g_currentMission.environment then
        return
    end

    local env = g_currentMission.environment
    self.lastHour         = env.currentHour
    self.lastDay          = env.currentDay
    self.lastMonotonicDay = env.currentMonotonicDay or -1
    self.lastMinuteCheck  = math.floor(env.dayTime / 60000)
    self.isInitialized    = true

    self:log("Income System initialized (Day %d, Hour %d)", self.lastDay, self.lastHour)
    self:log("Mode: %s, Amount: $%d, Multiplier: %s",
        self.settings:getPayModeName(),
        self.settings:getPaymentAmount(),
        self.settings:getMultiplierName()
    )
end

-- =========================================================
-- Logging
-- =========================================================

function IncomeSystem:log(msg, ...)
    if self.settings.debugMode then
        Logging.info("[Income Mod] " .. msg, ...)
    end
end

-- =========================================================
-- Notifications
-- =========================================================

function IncomeSystem:showNotification(message)
    if not self.settings.showNotifications then
        return
    end
    -- Only show on clients (not dedicated servers with no local player)
    if not g_currentMission or not g_currentMission:getIsClient() then
        return
    end
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, message)
end

-- =========================================================
-- Seasonal Multiplier
-- =========================================================

---@return number  seasonal multiplier (1.0 if seasonal effects disabled)
function IncomeSystem:getSeasonalMultiplier()
    if not self.settings.seasonalEffects then
        return 1.0
    end

    local season = 1  -- Default to Summer (1.0x) if unknown
    if g_currentMission and g_currentMission.environment then
        local ok, result = pcall(function()
            return g_currentMission.environment.currentSeason
        end)
        if ok and result ~= nil then
            season = result
        end
    end

    return Settings.SEASON_MULTIPLIERS[season] or 1.0
end

-- =========================================================
-- Payment History
-- =========================================================

function IncomeSystem:recordPayment(payType, amount, seasonMult, count)
    if not g_currentMission or not g_currentMission.environment then
        return
    end
    local env = g_currentMission.environment
    table.insert(self.paymentHistory, 1, {
        day        = env.currentDay,
        hour       = env.currentHour,
        amount     = amount,
        payType    = payType,
        seasonMult = seasonMult,
        count      = count or 1,
    })
    if #self.paymentHistory > IncomeSystem.MAX_HISTORY then
        table.remove(self.paymentHistory)
    end
end

-- =========================================================
-- Money Distribution
-- =========================================================

---@param paymentType string  "hourly", "daily", or "test"
---@param count number|nil  number of interval payments to pay at once (catch-up), default 1
---@return boolean  true if payment was executed
function IncomeSystem:giveMoney(paymentType, count)
    if not g_currentMission then
        self:log("Cannot give money: No mission")
        return false
    end

    -- Only the server distributes money to prevent duplicate payments in MP
    if not g_currentMission:getIsServer() then
        return false
    end

    count = math.max(1, math.floor(count or 1))

    local amount   = 1
    local typeText = "Test Payment"
    local seasonMult = 1.0

    if paymentType ~= "test" then
        amount   = self.settings:getPaymentAmount()
        typeText = paymentType == "hourly" and "Hourly Income" or "Daily Income"

        seasonMult = self:getSeasonalMultiplier()
        if seasonMult ~= 1.0 then
            amount = math.max(1, math.floor(amount * seasonMult))
            self:log("Seasonal multiplier %.1fx applied -> $%d", seasonMult, amount)
        end

        -- Multi-interval catch-up: N missed transitions pay N intervals in one
        -- transfer. The current season's multiplier is applied to the whole batch.
        if count > 1 then
            amount = amount * count
            typeText = string.format("%s (x%d)", typeText, count)
            self:log("Catch-up: paying %d %s intervals at once -> $%d", count, paymentType, amount)
        end
    end

    -- Pay every active farm (skipping spectator farm 0)
    local paidCount = 0
    if g_farmManager and g_farmManager.farms then
        for _, farm in pairs(g_farmManager.farms) do
            if farm and farm.farmId and farm.farmId ~= 0 then
                -- [C3] EMERGENCY LOAN repayment: auto-deduct a share of this
                -- payout toward any outstanding emergency loan, server-only.
                -- The deduction rides IncomeMod's own server-gated money path
                -- (same addMoney gate as the grant), so it is MP-safe.
                local emergencyLoan = g_IncomeManager and g_IncomeManager.emergencyLoan
                if emergencyLoan and emergencyLoan:getOutstanding(farm.farmId) > 0 then
                    emergencyLoan:applyRepayment(farm.farmId, amount)
                end
                g_currentMission:addMoney(amount, farm.farmId, MoneyType.OTHER, true)
                paidCount = paidCount + 1
                self:log("%s: $%d -> farm %d", typeText, amount, farm.farmId)
            end
        end
    end

    -- Fallback for single-player or if farm iteration returned nothing
    if paidCount == 0 then
        local farmId = g_currentMission:getFarmId()
        if farmId then
            g_currentMission:addMoney(amount, farmId, MoneyType.OTHER, true)
            paidCount = 1
            self:log("%s: $%d -> farm %d (fallback)", typeText, amount, farmId)
        else
            self:log("Cannot give money: No farm ID found")
            return false
        end
    end

    -- Record to history
    if paymentType ~= "test" then
        self:recordPayment(paymentType, amount, seasonMult, count)
    end

    -- Show notification (client-side only)
    if self.settings.showNotifications then
        local formattedAmount = g_i18n:formatMoney(amount, 0, true, true)
        local msg = string.format("%s: %s", typeText, formattedAmount)
        self:showNotification(msg)
        self:log("Notification: %s", msg)
    end

    return true
end

-- =========================================================
-- Hourly / Daily Check
-- =========================================================
-- Multi-interval catch-up: at high game speed or after a frame hitch more than
-- one hour/day transition can pass between two checks. Each check counts how
-- many transitions elapsed and pays them all, instead of collapsing them into
-- a single payment. Day arithmetic uses environment.currentMonotonicDay (the
-- counter the base game uses for day math in AbstractMission); currentDay is
-- only a change-detection trigger because its monotonicity is not guaranteed.

---@return boolean  true if the monotonic day counter moved since the last check
function IncomeSystem:hasMonotonicDayChanged(env)
    local monoDay = env.currentMonotonicDay
    return monoDay ~= nil and self.lastMonotonicDay >= 0 and monoDay ~= self.lastMonotonicDay
end

---@return number  elapsed hour transitions since the last check (>= 1, clamped)
function IncomeSystem:countElapsedHours(env)
    -- A change was already detected, so at least one transition happened
    local count = 1
    if self.lastHour >= 0 and self.lastHour <= 23 then
        count = (env.currentHour - self.lastHour) % 24
        if count == 0 then
            count = 1
        end
        -- Fold in full days when the monotonic day counter is available
        local monoDay = env.currentMonotonicDay
        if monoDay ~= nil and self.lastMonotonicDay >= 0 then
            local total = (monoDay - self.lastMonotonicDay) * 24 + (env.currentHour - self.lastHour)
            if total > count then
                count = total
            end
        end
    end
    if count > IncomeSystem.MAX_CATCHUP_HOURLY then
        self:log("Hourly catch-up clamped: %d transitions -> %d", count, IncomeSystem.MAX_CATCHUP_HOURLY)
        count = IncomeSystem.MAX_CATCHUP_HOURLY
    end
    return count
end

---@return number  elapsed day transitions since the last check (>= 1, clamped)
function IncomeSystem:countElapsedDays(env)
    local count = 1
    local monoDay = env.currentMonotonicDay
    if monoDay ~= nil and self.lastMonotonicDay >= 0 then
        local dayDelta = monoDay - self.lastMonotonicDay
        if dayDelta > 1 then
            count = dayDelta
        end
    elseif self.lastDay >= 0 then
        local dayDelta = env.currentDay - self.lastDay
        if dayDelta > 1 then
            count = dayDelta
        end
    end
    if count > IncomeSystem.MAX_CATCHUP_DAILY then
        self:log("Daily catch-up clamped: %d transitions -> %d", count, IncomeSystem.MAX_CATCHUP_DAILY)
        count = IncomeSystem.MAX_CATCHUP_DAILY
    end
    return count
end

function IncomeSystem:checkHourly()
    if not g_currentMission or not g_currentMission.environment then
        return false
    end
    local env = g_currentMission.environment
    local currentHour = env.currentHour
    -- The monotonic day check also catches an exact multiple-of-24h jump,
    -- where currentHour lands back on the same value
    if currentHour ~= self.lastHour or self:hasMonotonicDayChanged(env) then
        local count = self:countElapsedHours(env)
        local isSleeping = g_sleepManager and g_sleepManager:getIsSleeping()
        self.lastHour = currentHour
        self.lastMonotonicDay = env.currentMonotonicDay or self.lastMonotonicDay

        if not isSleeping then
            self:giveMoney("hourly", count)
            return true
        else
            self:log("Skipped %d hourly payment(s) due to sleeping (Hour %d)", count, currentHour)
        end
    end
    return false
end

function IncomeSystem:checkDaily()
    if not g_currentMission or not g_currentMission.environment then
        return false
    end
    local env = g_currentMission.environment
    local currentDay = env.currentDay
    -- The monotonic day check keeps daily mode firing even if currentDay
    -- wraps back to the same value (short-month settings)
    if currentDay ~= self.lastDay or self:hasMonotonicDayChanged(env) then
        local count = self:countElapsedDays(env)
        local isSleeping = g_sleepManager and g_sleepManager:getIsSleeping()
        self.lastDay = currentDay
        self.lastMonotonicDay = env.currentMonotonicDay or self.lastMonotonicDay

        if not isSleeping then
            self:giveMoney("daily", count)
            return true
        else
            self:log("Skipped %d daily payment(s) due to sleeping (Day %d)", count, currentDay)
        end
    end
    return false
end

-- =========================================================
-- Update (called every frame via FSBaseMission.update hook)
-- =========================================================

function IncomeSystem:update(dt)
    if not self.settings.enabled or not self.isInitialized then
        return
    end

    if not g_currentMission or not g_currentMission.environment then
        return
    end

    -- Throttle to one check per game-minute to keep overhead minimal
    local currentMinute = math.floor(g_currentMission.environment.dayTime / 60000)
    if currentMinute == self.lastMinuteCheck then
        return
    end
    self.lastMinuteCheck = currentMinute

    if self.settings.payMode == Settings.PAY_MODE_HOURLY then
        self:checkHourly()
    else
        self:checkDaily()
    end
end

-- =========================================================
-- Next Payment Info
-- =========================================================

---@return string  human-readable description of next payment trigger
function IncomeSystem:getNextPaymentInfo()
    if not g_currentMission or not g_currentMission.environment then
        return "Unknown (no mission)"
    end
    local env = g_currentMission.environment

    if self.settings.payMode == Settings.PAY_MODE_HOURLY then
        local nextHour = (env.currentHour + 1) % 24
        local msIntoHour = env.dayTime % 3600000
        local minsRemaining = math.ceil((3600000 - msIntoHour) / 60000)
        return string.format("Hour %02d:00 (~%d game-minute(s) remaining)", nextHour, minsRemaining)
    else
        local msIntoDayRemainder = 86400000 - env.dayTime
        local minsRemaining = math.ceil(msIntoDayRemainder / 60000)
        return string.format("Day %d midnight (~%d game-minute(s) remaining)", env.currentDay, minsRemaining)
    end
end

-- =========================================================
-- State Persistence
-- =========================================================

function IncomeSystem:saveState()
    return {
        lastHour         = self.lastHour,
        lastDay          = self.lastDay,
        lastMonotonicDay = self.lastMonotonicDay,
    }
end

function IncomeSystem:loadState(state)
    if state then
        self.lastHour = state.lastHour or -1
        self.lastDay  = state.lastDay  or -1
        -- Older state files have no monotonic day; keep the value picked up
        -- from the environment in initialize() instead of stomping it
        if state.lastMonotonicDay and state.lastMonotonicDay >= 0 then
            self.lastMonotonicDay = state.lastMonotonicDay
        end
        self:log("Timer state restored: lastHour=%d, lastDay=%d, lastMonotonicDay=%d",
            self.lastHour, self.lastDay, self.lastMonotonicDay)
    end
end
