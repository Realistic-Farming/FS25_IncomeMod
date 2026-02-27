-- =========================================================
-- FS25 Income Mod (version 2.0.0.2)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================

---@class SettingsManager
SettingsManager = {}
local SettingsManager_mt = Class(SettingsManager)

SettingsManager.MOD_NAME = g_currentModName
SettingsManager.XMLTAG   = "IncomeManager"

SettingsManager.defaultConfig = {
    difficulty        = 2,
    enabled           = true,
    debugMode         = false,
    payMode           = 1,
    showNotifications = true,
    customAmount      = 0,
    seasonalEffects   = false,
    incomeMultiplier  = 1,
    showHUD           = true,
}

function SettingsManager.new()
    return setmetatable({}, SettingsManager_mt)
end

-- =========================================================
-- File Paths
-- =========================================================

function SettingsManager:getSavegameXmlFilePath()
    if g_currentMission.missionInfo and g_currentMission.missionInfo.savegameDirectory then
        return ("%s/%s.xml"):format(
            g_currentMission.missionInfo.savegameDirectory,
            SettingsManager.MOD_NAME
        )
    end
    return nil
end

function SettingsManager:getStateXmlFilePath()
    if g_currentMission.missionInfo and g_currentMission.missionInfo.savegameDirectory then
        return ("%s/%s_state.xml"):format(
            g_currentMission.missionInfo.savegameDirectory,
            SettingsManager.MOD_NAME
        )
    end
    return nil
end

-- =========================================================
-- Settings Load / Save
-- =========================================================

function SettingsManager:loadSettings(settingsObject)
    local xmlPath = self:getSavegameXmlFilePath()
    if xmlPath and fileExists(xmlPath) then
        local xml = XMLFile.load("im_Config", xmlPath)
        if xml then
            local t = self.XMLTAG
            settingsObject.difficulty        = xml:getInt (t .. ".difficulty",        self.defaultConfig.difficulty)
            settingsObject.enabled           = xml:getBool(t .. ".enabled",            self.defaultConfig.enabled)
            settingsObject.debugMode         = xml:getBool(t .. ".debugMode",          self.defaultConfig.debugMode)
            settingsObject.payMode           = xml:getInt (t .. ".payMode",            self.defaultConfig.payMode)
            settingsObject.showNotifications = xml:getBool(t .. ".showNotifications",  self.defaultConfig.showNotifications)
            settingsObject.customAmount      = xml:getInt (t .. ".customAmount",       self.defaultConfig.customAmount)
            settingsObject.seasonalEffects   = xml:getBool(t .. ".seasonalEffects",   self.defaultConfig.seasonalEffects)
            settingsObject.incomeMultiplier  = xml:getInt (t .. ".incomeMultiplier",  self.defaultConfig.incomeMultiplier)
            settingsObject.showHUD           = xml:getBool(t .. ".showHUD",           self.defaultConfig.showHUD)
            xml:delete()
            return
        end
    end
    -- No file found — apply defaults
    local d = self.defaultConfig
    settingsObject.difficulty        = d.difficulty
    settingsObject.enabled           = d.enabled
    settingsObject.debugMode         = d.debugMode
    settingsObject.payMode           = d.payMode
    settingsObject.showNotifications = d.showNotifications
    settingsObject.customAmount      = d.customAmount
    settingsObject.seasonalEffects   = d.seasonalEffects
    settingsObject.incomeMultiplier  = d.incomeMultiplier
    settingsObject.showHUD           = d.showHUD
end

function SettingsManager:saveSettings(settingsObject)
    local xmlPath = self:getSavegameXmlFilePath()
    if not xmlPath then return end

    local xml = XMLFile.create("im_Config", xmlPath, self.XMLTAG)
    if xml then
        local t = self.XMLTAG
        xml:setInt (t .. ".difficulty",        settingsObject.difficulty)
        xml:setBool(t .. ".enabled",           settingsObject.enabled)
        xml:setBool(t .. ".debugMode",         settingsObject.debugMode)
        xml:setInt (t .. ".payMode",           settingsObject.payMode)
        xml:setBool(t .. ".showNotifications", settingsObject.showNotifications)
        xml:setInt (t .. ".customAmount",      settingsObject.customAmount)
        xml:setBool(t .. ".seasonalEffects",   settingsObject.seasonalEffects)
        xml:setInt (t .. ".incomeMultiplier",  settingsObject.incomeMultiplier)
        xml:setBool(t .. ".showHUD",           settingsObject.showHUD)
        xml:save()
        xml:delete()
    end
end

-- =========================================================
-- Timer State Load / Save (prevents double-payment on reload)
-- =========================================================

---@param lastHour number  last hour a payment was made
---@param lastDay  number  last day a payment was made
function SettingsManager:saveTimerState(lastHour, lastDay)
    local xmlPath = self:getStateXmlFilePath()
    if not xmlPath then return end

    local xml = XMLFile.create("im_State", xmlPath, "IncomeState")
    if xml then
        xml:setInt("IncomeState.lastHour", lastHour)
        xml:setInt("IncomeState.lastDay",  lastDay)
        xml:save()
        xml:delete()
    end
end

---@return table|nil  {lastHour, lastDay} or nil if no state file exists
function SettingsManager:loadTimerState()
    local xmlPath = self:getStateXmlFilePath()
    if not xmlPath or not fileExists(xmlPath) then
        return nil
    end

    local xml = XMLFile.load("im_State", xmlPath)
    if xml then
        local lastHour = xml:getInt("IncomeState.lastHour", -1)
        local lastDay  = xml:getInt("IncomeState.lastDay",  -1)
        xml:delete()
        return { lastHour = lastHour, lastDay = lastDay }
    end
    return nil
end
