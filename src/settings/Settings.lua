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

---@class Settings
Settings = Settings or {}
local Settings_mt = Class(Settings)

Settings.DIFFICULTY_EASY   = 1
Settings.DIFFICULTY_NORMAL = 2
Settings.DIFFICULTY_HARD   = 3

Settings.PAY_MODE_HOURLY = 1
Settings.PAY_MODE_DAILY  = 2

-- Income multiplier lookup: index -> actual multiplier value
Settings.MULTIPLIER_AMOUNTS = { 1, 2, 5, 10 }

-- Seasonal income multipliers indexed by FS25 season value.
-- FS25 uses 0-indexed seasons: 0=Spring, 1=Summer, 2=Autumn, 3=Winter.
-- Index 4 provided as fallback for any 1-indexed API variant.
Settings.SEASON_MULTIPLIERS = {
    [0] = 0.8,  -- Spring: planting costs, lower income
    [1] = 1.0,  -- Summer: baseline
    [2] = 1.2,  -- Autumn: harvest season bonus
    [3] = 0.7,  -- Winter: off-season penalty
    [4] = 0.7,  -- Fallback for 1-indexed Winter
}

function Settings.new(manager)
    local self = setmetatable({}, Settings_mt)
    self.manager = manager
    self:resetToDefaults(false)
    Logging.info("Income Mod: Settings initialized")
    return self
end

-- =========================================================
-- Difficulty
-- =========================================================

---@param difficulty number
function Settings:setDifficulty(difficulty)
    if difficulty >= Settings.DIFFICULTY_EASY and difficulty <= Settings.DIFFICULTY_HARD then
        self.difficulty = difficulty
        Logging.info("Income Mod: Difficulty changed to: %s", self:getDifficultyName())
    end
end

---@return string
function Settings:getDifficultyName()
    if self.difficulty == Settings.DIFFICULTY_EASY then
        return "Easy"
    elseif self.difficulty == Settings.DIFFICULTY_HARD then
        return "Hard"
    else
        return "Normal"
    end
end

---@return number
function Settings:getDifficultyAmount()
    if self.difficulty == Settings.DIFFICULTY_EASY then
        return 5000
    elseif self.difficulty == Settings.DIFFICULTY_HARD then
        return 1100
    else
        return 2400
    end
end

-- =========================================================
-- Pay Mode
-- =========================================================

---@param mode number
function Settings:setPayMode(mode)
    if mode == Settings.PAY_MODE_HOURLY or mode == Settings.PAY_MODE_DAILY then
        local changed = mode ~= self.payMode
        self.payMode = mode
        Logging.info("Income Mod: Pay mode changed to: %s", self:getPayModeName())
        if changed and IncomeSystem then
            local now = g_currentMission and g_currentMission.environment
            if now then
                IncomeSystem.lastHour         = now.currentHour
                IncomeSystem.lastDay          = now.currentDay
                IncomeSystem.lastMonotonicDay = now.currentMonotonicDay or -1
            end
        end
    end
end

---@return string
function Settings:getPayModeName()
    if self.payMode == Settings.PAY_MODE_HOURLY then
        return "Hourly"
    else
        return "Daily"
    end
end

-- =========================================================
-- Income Multiplier
-- =========================================================

---@return number  actual multiplier value (1, 2, 5, or 10)
function Settings:getMultiplierValue()
    return Settings.MULTIPLIER_AMOUNTS[self.incomeMultiplier] or 1
end

---@return string  display name e.g. "2x"
function Settings:getMultiplierName()
    local val = self:getMultiplierValue()
    if val == 1 then
        return "1x (Normal)"
    else
        return tostring(val) .. "x"
    end
end

-- =========================================================
-- Payment Amount
-- =========================================================

---@return number  final base payment (difficulty or custom) times multiplier
function Settings:getPaymentAmount()
    local base = self.customAmount > 0 and self.customAmount or self:getDifficultyAmount()
    return base * self:getMultiplierValue()
end

-- =========================================================
-- Release Gate
-- =========================================================

--- Release-gate opt-in. True when the player has explicitly enabled experimental
--- (LOCKED) systems. Orthogonal to difficulty: the two locks stack, see ReleaseGate.lua.
---@return boolean
function Settings:allowsExperimentalSystems()
    return self.experimentalSystems == true
end

-- =========================================================
-- Load / Save / Validate
-- =========================================================

function Settings:load()
    self.manager:loadSettings(self)
    self:validateSettings()
    Logging.info(
        "Income Mod: Settings loaded. Enabled=%s, Mode=%s, Difficulty=%s, Amount=$%d, Seasonal=%s",
        tostring(self.enabled),
        self:getPayModeName(),
        self:getDifficultyName(),
        self:getPaymentAmount(),
        tostring(self.seasonalEffects)
    )
end

function Settings:validateSettings()
    if self.difficulty < Settings.DIFFICULTY_EASY or self.difficulty > Settings.DIFFICULTY_HARD then
        Logging.warning("Income Mod: Invalid difficulty %d, resetting to Normal", self.difficulty)
        self.difficulty = Settings.DIFFICULTY_NORMAL
    end

    if self.payMode ~= Settings.PAY_MODE_HOURLY and self.payMode ~= Settings.PAY_MODE_DAILY then
        Logging.warning("Income Mod: Invalid pay mode %d, resetting to Hourly", self.payMode)
        self.payMode = Settings.PAY_MODE_HOURLY
    end

    if self.incomeMultiplier < 1 or self.incomeMultiplier > #Settings.MULTIPLIER_AMOUNTS then
        Logging.warning("Income Mod: Invalid incomeMultiplier %d, resetting to 1", self.incomeMultiplier)
        self.incomeMultiplier = 1
    end

    self.enabled            = not not self.enabled
    self.debugMode          = not not self.debugMode
    self.showNotifications  = not not self.showNotifications
    self.seasonalEffects    = not not self.seasonalEffects
    self.showHUD            = not not self.showHUD
    self.experimentalSystems = not not self.experimentalSystems

    self.customAmount = tonumber(self.customAmount) or 0
    if self.customAmount < 0 then
        self.customAmount = 0
    end
end

function Settings:save()
    self.manager:saveSettings(self)
    Logging.info(
        "Income Mod: Settings saved. Mode=%s, Difficulty=%s, Multiplier=%s",
        self:getPayModeName(),
        self:getDifficultyName(),
        self:getMultiplierName()
    )
end

---@param saveImmediately boolean  pass false to skip the immediate save (used during init)
function Settings:resetToDefaults(saveImmediately)
    saveImmediately = saveImmediately ~= false

    self.difficulty        = Settings.DIFFICULTY_NORMAL
    self.enabled           = true
    self.debugMode         = false
    self.payMode           = Settings.PAY_MODE_HOURLY
    self.showNotifications = true
    self.customAmount      = 0
    self.seasonalEffects   = false
    self.incomeMultiplier  = 1
    self.showHUD           = true
    self.experimentalSystems = false

    if saveImmediately then
        self:save()
        Logging.info("Income Mod: Settings reset to defaults")
    end
end
