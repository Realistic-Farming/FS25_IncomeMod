---@class IncomeSettings
-- Settings system for Income Mod
IncomeSettings = {}
local IncomeSettings_mt = Class(IncomeSettings)

function IncomeSettings.new()
    local self = setmetatable({}, IncomeSettings_mt)
    
    -- Default values for Income Mod
    self.enabled = true
    self.mode = "hourly"  -- "hourly" or "daily"
    self.difficulty = "normal"  -- "easy", "normal", "hard"
    self.useCustomAmount = false
    self.customAmount = 2400
    self.showNotification = true
    self.debugLevel = 1  -- 0=none, 1=basic, 2=verbose
    
    -- Difficulty values
    self.DIFFICULTY_VALUES = {
        easy = 5000,
        normal = 2400,
        hard = 1100
    }
    
    return self
end

--- Get income amount based on current settings
--- @return number Amount in dollars
function IncomeSettings:getIncomeAmount()
    if self.useCustomAmount then
        return self.customAmount
    end
    
    return self.DIFFICULTY_VALUES[self.difficulty] or 2400
end

--- Get human-readable mode name
--- @return string Mode name
function IncomeSettings:getModeName()
    if self.mode == "hourly" then
        return "Hourly"
    elseif self.mode == "daily" then
        return "Daily"
    end
    return "Hourly"
end

--- Get human-readable difficulty name
--- @return string Difficulty name
function IncomeSettings:getDifficultyName()
    if self.difficulty == "easy" then
        return "Easy"
    elseif self.difficulty == "normal" then
        return "Normal"
    elseif self.difficulty == "hard" then
        return "Hard"
    end
    return "Normal"
end

--- Load settings from XML file
function IncomeSettings:load()
    local xmlPath = self:getSettingsPath()
    
    if xmlPath and fileExists(xmlPath) then
        local xml = XMLFile.load("incomeModSettings", xmlPath)
        if xml then
            self.enabled = xml:getBool("incomeSettings.enabled", true)
            self.mode = xml:getString("incomeSettings.mode", "hourly")
            self.difficulty = xml:getString("incomeSettings.difficulty", "normal")
            self.useCustomAmount = xml:getBool("incomeSettings.useCustomAmount", false)
            self.customAmount = xml:getInt("incomeSettings.customAmount", 2400)
            self.showNotification = xml:getBool("incomeSettings.showNotification", true)
            self.debugLevel = xml:getInt("incomeSettings.debugLevel", 1)
            xml:delete()
            
            print(string.format("[Income Mod] Settings loaded. Enabled: %s, Mode: %s, Difficulty: %s",
                tostring(self.enabled), self.mode, self.difficulty))
            return
        end
    end
    
    -- Use defaults if no settings file exists
    print("[Income Mod] No settings file found, using defaults")
end

--- Save settings to XML file
function IncomeSettings:save()
    local xmlPath = self:getSettingsPath()
    
    if not xmlPath then
        print("[Income Mod] Cannot save settings: No savegame directory")
        return
    end
    
    local xml = XMLFile.create("incomeModSettings", xmlPath, "incomeSettings")
    if xml then
        xml:setBool("incomeSettings.enabled", self.enabled)
        xml:setString("incomeSettings.mode", self.mode)
        xml:setString("incomeSettings.difficulty", self.difficulty)
        xml:setBool("incomeSettings.useCustomAmount", self.useCustomAmount)
        xml:setInt("incomeSettings.customAmount", self.customAmount)
        xml:setBool("incomeSettings.showNotification", self.showNotification)
        xml:setInt("incomeSettings.debugLevel", self.debugLevel)
        xml:save()
        xml:delete()
        
        print(string.format("[Income Mod] Settings saved. Enabled: %s, Mode: %s, Difficulty: %s",
            tostring(self.enabled), self.mode, self.difficulty))
    else
        print("[Income Mod] Failed to create XML file for saving settings")
    end
end

--- Get path to settings XML file
--- @return string|nil Path to settings file or nil if not available
function IncomeSettings:getSettingsPath()
    if g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.savegameDirectory then
        local basePath = g_currentMission.missionInfo.savegameDirectory .. "/modSettings"
        createFolder(basePath)
        return basePath .. "/FS25_IncomeMod.xml"
    end
    return nil
end

--- Reset settings to defaults
function IncomeSettings:resetToDefaults()
    self.enabled = true
    self.mode = "hourly"
    self.difficulty = "normal"
    self.useCustomAmount = false
    self.customAmount = 2400
    self.showNotification = true
    self.debugLevel = 1
    
    self:save()
    print("[Income Mod] Settings reset to defaults")
end

--- Get available mode options for UI
--- @return table List of mode options
function IncomeSettings:getModeOptions()
    return {
        "hourly",
        "daily"
    }
end

--- Get available difficulty options for UI
--- @return table List of difficulty options
function IncomeSettings:getDifficultyOptions()
    return {
        "easy",
        "normal", 
        "hard"
    }
end