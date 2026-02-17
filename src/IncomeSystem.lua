-- =========================================================
-- FS25 Income Mod (version 2.0.0.0)
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

function IncomeSystem.new(settings)
    local self = setmetatable({}, IncomeSystem_mt)
    self.settings         = settings
    self.lastHour         = -1
    self.lastDay          = -1
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
    self.lastHour        = env.currentHour
    self.lastDay         = env.currentDay
    self.lastMinuteCheck = math.floor(env.dayTime / 60000)
    self.isInitialized   = true

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

function IncomeSystem:recordPayment(payType, amount, seasonMult)
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
    })
    if #self.paymentHistory > IncomeSystem.MAX_HISTORY then
        table.remove(self.paymentHistory)
    end
end

-- =========================================================
-- Money Distribution
-- =========================================================

---@param paymentType string  "hourly", "daily", or "test"
---@return boolean  true if payment was executed
function IncomeSystem:giveMoney(paymentType)
    if not g_currentMission then
        self:log("Cannot give money: No mission")
        return false
    end

    -- Only the server distributes money to prevent duplicate payments in MP
    if not g_currentMission:getIsServer() then
        return false
    end

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
    end

    -- Pay every active farm (skipping spectator farm 0)
    local paidCount = 0
    if g_farmManager and g_farmManager.farms then
        for _, farm in pairs(g_farmManager.farms) do
            if farm and farm.farmId and farm.farmId ~= 0 then
                g_currentMission:addMoney(amount, farm.farmId, MoneyType.INCOME, true)
                paidCount = paidCount + 1
                self:log("%s: $%d -> farm %d", typeText, amount, farm.farmId)
            end
        end
    end

    -- Fallback for single-player or if farm iteration returned nothing
    if paidCount == 0 then
        local farmId = g_currentMission:getFarmId()
        if farmId then
            g_currentMission:addMoney(amount, farmId, MoneyType.INCOME, true)
            paidCount = 1
            self:log("%s: $%d -> farm %d (fallback)", typeText, amount, farmId)
        else
            self:log("Cannot give money: No farm ID found")
            return false
        end
    end

    -- Record to history
    if paymentType ~= "test" then
        self:recordPayment(paymentType, amount, seasonMult)
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

function IncomeSystem:checkHourly()
    if not g_currentMission or not g_currentMission.environment then
        return false
    end
    local currentHour = g_currentMission.environment.currentHour
    if currentHour ~= self.lastHour then
        self.lastHour = currentHour
        self:giveMoney("hourly")
        return true
    end
    return false
end

function IncomeSystem:checkDaily()
    if not g_currentMission or not g_currentMission.environment then
        return false
    end
    local currentDay = g_currentMission.environment.currentDay
    if currentDay ~= self.lastDay then
        self.lastDay = currentDay
        self:giveMoney("daily")
        return true
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
        lastHour = self.lastHour,
        lastDay  = self.lastDay,
    }
end

function IncomeSystem:loadState(state)
    if state then
        self.lastHour = state.lastHour or -1
        self.lastDay  = state.lastDay  or -1
        self:log("Timer state restored: lastHour=%d, lastDay=%d", self.lastHour, self.lastDay)
    end
end
