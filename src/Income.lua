-- =========================================================
-- FS25 Income Mod (version 1.0.1.0)
-- =========================================================
-- Hourly or daily income for players
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================

FS25IncomeMod = {}
FS25IncomeMod.modDir = g_currentModDirectory
FS25IncomeMod.modName = "FS25_IncomeMod"
FS25IncomeMod.settings = nil
FS25IncomeMod.settingsUI = nil
FS25IncomeMod.Debug = false

source(modDirectory .. "src/settings/IncomeSettingsManager.lua")
source(modDirectory .. "src/settings/IncomeSettings.lua")
source(modDirectory .. "src/settings/IncomeSettingsGUI.lua")
source(modDirectory .. "src/utils/UIHelper.lua")
source(modDirectory .. "src/settings/IncomeSettingsUI.lua")

-- Keep DIFFICULTY_VALUES for backward compatibility or reference
local DIFFICULTY_VALUES = {
    easy = 5000,
    normal = 2400,
    hard = 1100
}

local lastHour = -1
local lastDay = -1
local lastMinuteCheck = -1
local isInitialized = false

-- =====================
-- UTILITY FUNCTIONS
-- =====================
local function log(msg, level)
    level = level or 1
    -- Use settings from the new settings object if available
    if FS25IncomeMod.settings then
        if FS25IncomeMod.settings.debugLevel >= level then
            print("[" .. FS25IncomeMod.modName .. "] " .. tostring(msg))
        end
    else
        -- Fallback for initialization period
        print("[" .. FS25IncomeMod.modName .. "] " .. tostring(msg))
    end
end

local function debug(msg)
    if FS25IncomeMod.Debug then
        print("[" .. FS25IncomeMod.modName .. " DEBUG] " .. tostring(msg))
    end
end

function getDynamicIncome()
    if not g_currentMission then
        return 2400
    end
    
    if FS25IncomeMod.settings then
        return FS25IncomeMod.settings:getIncomeAmount()
    end
    
    return DIFFICULTY_VALUES.normal or 2400
end

-- =====================
-- SETTINGS SYSTEM - UPDATED
-- =====================
local function getSettingsPath()
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        local base = g_currentMission.missionInfo.savegameDirectory .. "/modSettings"
        createFolder(base)
        return base .. "/FS25_IncomeMod.xml"
    end
    return nil
end

function loadSettings()
    -- This function is now handled by IncomeSettings:load()
    if FS25IncomeMod.settings then
        FS25IncomeMod.settings:load()
    end
end

function saveSettings()
    -- This function is now handled by IncomeSettings:save()
    if FS25IncomeMod.settings then
        FS25IncomeMod.settings:save()
    end
end

-- =====================
-- CONSOLE COMMANDS - UPDATED
-- =====================
function FS25IncomeMod:consoleCommandIncome()
    print("========================================")
    print("         Income Mod Commands            ")
    print("========================================")
    print("income         - Show this help          ")
    print("incomeStatus   - Show current settings   ")
    print("incomeEnable   - Enable mod              ")
    print("incomeDisable  - Disable mod             ")
    print("incomeTest     - Test payment ($1)       ")
    print("incomeMode [hourly/daily]                ")
    print("incomeDifficulty [easy/normal/hard]      ")
    print("incomeCustom [amount]                    ")
    print("========================================")
end

function FS25IncomeMod:consoleIncomeStatus()
    if self.settings then
        print("=== Income Mod Status ===")
        print("Enabled: " .. tostring(self.settings.enabled))
        print("Mode: " .. self.settings:getModeName())
        print("Difficulty: " .. self.settings:getDifficultyName())
        print("Notifications: " .. tostring(self.settings.showNotification))
        print("Custom Amount: " .. tostring(self.settings.useCustomAmount))
        
        if self.settings.useCustomAmount then
            print("Amount: $" .. self.settings.customAmount)
        else
            print("Amount: $" .. self.settings:getIncomeAmount())
        end
        
        print("Debug Level: " .. self.settings.debugLevel)
        print("========================")
    else
        print("[Income Mod] Error: Settings not initialized")
    end
end

function FS25IncomeMod:consoleIncomeEnable()
    if self.settings then
        self.settings.enabled = true
        self.settings:save()
        
        -- Refresh UI if available
        if self.settingsUI then
            self.settingsUI:refreshUI()
        end
        
        print("[Income Mod] ENABLED")
        if g_currentMission then
            g_currentMission:addIngameNotification({0.0, 0.5, 1.0, 1.0}, "Income Mod ENABLED")
        end
    else
        print("[Income Mod] Error: Settings not initialized")
    end
end

function FS25IncomeMod:consoleIncomeDisable()
    if self.settings then
        self.settings.enabled = false
        self.settings:save()
        
        -- Refresh UI if available
        if self.settingsUI then
            self.settingsUI:refreshUI()
        end
        
        print("[Income Mod] DISABLED")
        if g_currentMission then
            g_currentMission:addIngameNotification({0.0, 0.5, 1.0, 1.0}, "Income Mod DISABLED")
        end
    else
        print("[Income Mod] Error: Settings not initialized")
    end
end

function FS25IncomeMod:consoleIncomeTest()
    if self.settings then
        -- Store original amount for test
        local testAmount = 1
        local farmId = g_currentMission:getFarmId()
        if farmId then
            g_currentMission:addMoney(
                testAmount,
                farmId,
                MoneyType.INCOME,
                false
            )
        end
        
        print("[Income Mod] Test payment executed ($1)")

        if g_currentMission then
            g_currentMission:addIngameNotification({0.0, 0.5, 1.0, 1.0}, "You received a test payment ($1)")
        end
    else
        print("[Income Mod] Error: Settings not initialized")
    end
end

function FS25IncomeMod:consoleIncomeMode(mode)
    if mode == nil then
        print("Usage: incomeMode hourly|daily")
        return
    end

    mode = tostring(mode):lower()
    if mode ~= "hourly" and mode ~= "daily" then
        print("Invalid mode. Use 'hourly' or 'daily'")
        return
    end

    if self.settings then
        self.settings.mode = mode
        self.settings:save()
        
        -- Refresh UI if available
        if self.settingsUI then
            self.settingsUI:refreshUI()
        end
        
        print("[Income Mod] Mode set to " .. mode)

        if g_currentMission then
            g_currentMission:addIngameNotification({0.0, 0.5, 1.0, 1.0}, "Mode set to " .. mode)
        end
    else
        print("[Income Mod] Error: Settings not initialized")
    end
end

function FS25IncomeMod:consoleIncomeDifficulty(diff)
    if diff == nil then
        print("Usage: incomeDifficulty easy|normal|hard")
        return
    end
    
    diff = tostring(diff):lower()
    
    -- Check if valid difficulty
    if diff ~= "easy" and diff ~= "normal" and diff ~= "hard" then
        print("Invalid difficulty. Use 'easy', 'normal', or 'hard'")
        return
    end

    if self.settings then
        self.settings.difficulty = diff
        self.settings.useCustomAmount = false
        self.settings:save()
        
        -- Refresh UI if available
        if self.settingsUI then
            self.settingsUI:refreshUI()
        end
        
        print("[Income Mod] Difficulty set to " .. diff)
        if g_currentMission then
            g_currentMission:addIngameNotification({0.0, 0.5, 1.0, 1.0}, "Difficulty set to " .. diff)
        end
    else
        print("[Income Mod] Error: Settings not initialized")
    end
end

function FS25IncomeMod:consoleIncomeCustom(amount)
    local value = tonumber(amount)
    if value == nil or value <= 0 then
        print("Usage: incomeCustom <amount> (positive number)")
        return
    end
    
    -- Optional: Set a reasonable maximum
    if value > 1000000 then
        print("Warning: Custom amount capped at $1,000,000")
        value = 1000000
    end

    if self.settings then
        self.settings.useCustomAmount = true
        self.settings.customAmount = value
        self.settings:save()
        
        -- Refresh UI if available
        if self.settingsUI then
            self.settingsUI:refreshUI()
        end
        
        print("[Income Mod] Custom income set to $" .. value)
        if g_currentMission then
            g_currentMission:addIngameNotification({0.0, 0.5, 1.0, 1.0}, "Custom income set to $" .. g_i18n:formatMoney(value, 0, true, true))
        end
    else
        print("[Income Mod] Error: Settings not initialized")
    end
end

-- =====================
-- MONEY HANDLING - UPDATED
-- =====================
function giveMoney(paymentType)
    if not g_currentMission then
        log("Cannot give money: No mission", 2)
        return false
    end
    
    local amount = 1
    local typeText = "Test Payment"
    
    if paymentType ~= "test" then
        amount = getDynamicIncome()
        if paymentType == "hourly" then
            typeText = "Hourly Income"
        else
            typeText = "Daily Income"
        end
    end
    
    local farmId = g_currentMission:getFarmId()
    if not farmId then
        log("Cannot give money: No farm ID", 2)
        return false
    end
    
    g_currentMission:addMoney(
        amount,
        farmId,
        MoneyType.INCOME,
        false
    )
    
    -- Check notifications setting from new settings object
    local showNotification = true
    if FS25IncomeMod.settings then
        showNotification = FS25IncomeMod.settings.showNotification
    end
    
    if showNotification and paymentType ~= "test" then
        local message = string.format("%s: $%s", typeText, g_i18n:formatMoney(amount, 0, true, true))
        
        if g_currentMission then
            g_currentMission:addIngameNotification({0.0, 0.5, 1.0, 1.0}, message)
        end
    end

    
    log(string.format("%s: $%d to farm %d", typeText, amount, farmId), 2)
    return true
end

-- =====================
-- TIME CHECKING FUNCTIONS - UPDATED
-- =====================
local function checkHourly()
    if not g_currentMission or not g_currentMission.environment then
        return false
    end
    
    local env = g_currentMission.environment
    local currentHour = env.currentHour
    
    if currentHour ~= lastHour then
        lastHour = currentHour
        
        -- Check if mod is enabled
        local enabled = true
        if FS25IncomeMod.settings then
            enabled = FS25IncomeMod.settings.enabled
        end
        
        if enabled then
            giveMoney("hourly")
            saveSettings()
            return true
        end
    end
    
    return false
end

local function checkDaily()
    if not g_currentMission or not g_currentMission.environment then
        return false
    end
    
    local env = g_currentMission.environment
    local currentDay = env.currentDay
    
    if currentDay ~= lastDay then
        lastDay = currentDay
        
        -- Check if mod is enabled
        local enabled = true
        if FS25IncomeMod.settings then
            enabled = FS25IncomeMod.settings.enabled
        end
        
        if enabled then
            giveMoney("daily")
            saveSettings()
            return true
        end
    end
    
    return false
end

-- =====================
-- UPDATE SYSTEM - UPDATED
-- =====================
local function createUpdateable()
    local updateable = {
        update = function(dt)
            if not isInitialized then
                return
            end
            
            -- Check if mod is enabled
            local enabled = true
            if FS25IncomeMod.settings then
                enabled = FS25IncomeMod.settings.enabled
            end
            
            if not enabled then
                return
            end
            
            if g_currentMission and g_currentMission.environment then
                local currentMinute = math.floor(g_currentMission.environment.dayTime / 60000)
                
                if currentMinute ~= lastMinuteCheck then
                    lastMinuteCheck = currentMinute
                    
                    -- Get mode from settings
                    local mode = "hourly"
                    if FS25IncomeMod.settings then
                        mode = FS25IncomeMod.settings.mode
                    end
                    
                    if mode == "hourly" then
                        checkHourly()
                    else
                        checkDaily()
                    end
                end
            end
        end,
        
        delete = function()
            log("Updateable removed")
        end
    }
    
    return updateable
end

-- =====================
-- MOD INITIALIZATION
-- =====================
function FS25IncomeMod:loadMap(name)
    log("Loading Income Mod for map: " .. (name or "unknown"))
    
    -- Initialize new settings system
    self.settings = IncomeSettings.new()
    self.settings:load()
    
    -- Initialize settings UI
    self.settingsUI = IncomeSettingsUI.new(self.settings)
    
    self:setupMissionIntegration()
    
    self:injectSettingsUI()
    return true
end

function FS25IncomeMod:setupMissionIntegration()
    if isInitialized then
        return
    end
    
    local initializationStarted = false
    
    local initUpdateable = {
        update = function(dt)
            if isInitialized or initializationStarted then
                return false
            end
            
            initializationStarted = true
            
            if g_currentMission and g_currentMission.environment and g_currentMission.addUpdateable then
                local env = g_currentMission.environment
                lastHour = env.currentHour
                lastDay = env.currentDay
                lastMinuteCheck = math.floor(env.dayTime / 60000)
                
                self.updateable = createUpdateable()
                g_currentMission:addUpdateable(self.updateable)
                
                isInitialized = true
                
                log(string.format("Income Mod initialized successfully (Day %d, Hour %d)", lastDay, lastHour))
                
                -- Get settings from new settings object
                local mode = "hourly"
                local amount = 2400
                if self.settings then
                    mode = self.settings:getModeName()
                    amount = self.settings:getIncomeAmount()
                end
                
                log("Mode: " .. mode .. ", Amount: $" .. amount)
                
                -- Check if notifications should be shown
                local showNotification = true
                if self.settings then
                    showNotification = self.settings.showNotification
                end
                
                if showNotification then
                    if g_currentMission.hud ~= nil and g_currentMission.hud.showBlinkingWarning ~= nil then
                        g_currentMission.hud:showBlinkingWarning(
                            "Income Mod Active - Type 'income' in console (~)",
                            4000
                        )
                    end
                end
                
                registerConsoleCommands()
                
                return true
            end
            
            return false
        end,
        
        delete = function()
            log("Init updateable removed")
        end
    }
    
    if g_currentMission and g_currentMission.addUpdateable then
        g_currentMission:addUpdateable(initUpdateable)
        log("Init updateable registered - waiting for mission to be ready...")
    else
        log("Warning: Could not register init updateable - mission not ready yet")
    end
end

function FS25IncomeMod:deleteMap()
    log("Income Mod shutting down")
    
    if self.updateable and g_currentMission then
        g_currentMission:removeUpdateable(self.updateable)
    end
    
    saveSettings()
    
    isInitialized = false
    log("Income Mod unloaded")
end

-- =====================
-- UI FUNCTIONS
-- =====================
function FS25IncomeMod:injectSettingsUI()
    if not self.settingsUI then
        return
    end
    
    -- Create the updateable with proper self reference
    self.uiInjectTimer = 0
    self.uiInjectAttempts = 0
    
    -- Store a reference to self for the closure
    local modSelf = self
    
    if not self.uiInjectionUpdateable then
        self.uiInjectionUpdateable = {
            update = function(dt)
                modSelf.uiInjectTimer = modSelf.uiInjectTimer + dt
                modSelf.uiInjectAttempts = modSelf.uiInjectAttempts + 1
                
                -- Wait for GUI to be ready
                if modSelf.uiInjectTimer > 5.0 or modSelf.uiInjectAttempts > 300 then
                    -- Timeout after 5 seconds or 300 attempts
                    if g_currentMission and modSelf.uiInjectionUpdateable then
                        g_currentMission:removeUpdateable(modSelf.uiInjectionUpdateable)
                    end
                    modSelf.uiInjectionUpdateable = nil
                    print("[Income Mod] UI injection timed out after " .. modSelf.uiInjectAttempts .. " attempts")
                    return true
                end
                
                -- Try to inject when GUI is ready
                if g_gui and g_gui.screenControllers then
                    if modSelf.settingsUI then
                        local success = modSelf.settingsUI:inject()
                        if success then
                            if g_currentMission and modSelf.uiInjectionUpdateable then
                                g_currentMission:removeUpdateable(modSelf.uiInjectionUpdateable)
                            end
                            modSelf.uiInjectionUpdateable = nil
                            print("[Income Mod] Settings UI injected successfully after " .. modSelf.uiInjectAttempts .. " attempts")
                            return true
                        end
                    end
                end
                
                return false
            end,
            
            delete = function()
                -- Cleanup
                modSelf.uiInjectionUpdateable = nil
            end
        }
        
        if g_currentMission then
            g_currentMission:addUpdateable(self.uiInjectionUpdateable)
        end
        print("[Income Mod] Started UI injection process")
    end
end

function FS25IncomeMod:scheduleUIInjection()
    if not self.uiInjectionUpdateable then
        self.uiInjectionUpdateable = {
            update = function(dt)
                if g_gui and g_gui.screenControllers and g_gui.screenControllers[InGameMenu] then
                    -- Try to inject
                    if FS25IncomeMod.settingsUI then
                        FS25IncomeMod.settingsUI:inject()
                        
                        -- If successful, remove this updateable
                        if FS25IncomeMod.settingsUI.injected then
                            if g_currentMission then
                                g_currentMission:removeUpdateable(FS25IncomeMod.uiInjectionUpdateable)
                            end
                            FS25IncomeMod.uiInjectionUpdateable = nil
                            print("[Income Mod] Settings UI injection completed")
                            return true
                        end
                    end
                    
                    -- Limit attempts
                    FS25IncomeMod.uiInjectAttempts = (FS25IncomeMod.uiInjectAttempts or 0) + 1
                    if FS25IncomeMod.uiInjectAttempts > 100 then -- Give up after 100 frames
                        if g_currentMission then
                            g_currentMission:removeUpdateable(FS25IncomeMod.uiInjectionUpdateable)
                        end
                        FS25IncomeMod.uiInjectionUpdateable = nil
                        print("[Income Mod] Settings UI injection failed after 100 attempts")
                        return true
                    end
                end
                return false
            end,
            
            delete = function()
                -- Cleanup
            end
        }
        
        if g_currentMission then
            g_currentMission:addUpdateable(self.uiInjectionUpdateable)
        end
    end
end

-- =====================
-- CONSOLE COMMAND REGISTRATION
-- =====================
function registerConsoleCommands()
    print("[Income Mod] Registering console commands (FS25)")

    addConsoleCommand(
        "income",
        "Show income mod help",
        "consoleCommandIncome",
        FS25IncomeMod
    )

    addConsoleCommand(
        "incomeStatus",
        "Show income settings",
        "consoleIncomeStatus",
        FS25IncomeMod
    )

    addConsoleCommand(
        "incomeEnable",
        "Enable income mod",
        "consoleIncomeEnable",
        FS25IncomeMod
    )

    addConsoleCommand(
        "incomeDisable",
        "Disable income mod",
        "consoleIncomeDisable",
        FS25IncomeMod
    )

    addConsoleCommand(
        "incomeTest",
        "Test income payment",
        "consoleIncomeTest",
        FS25IncomeMod
    )

    addConsoleCommand(
        "incomeMode",
        "Set income mode",
        "consoleIncomeMode",
        FS25IncomeMod
    )

    addConsoleCommand(
        "incomeDifficulty",
        "Set difficulty",
        "consoleIncomeDifficulty",
        FS25IncomeMod
    )

    addConsoleCommand(
        "incomeCustom",
        "Set custom income",
        "consoleIncomeCustom",
        FS25IncomeMod
    )

    print("[Income Mod] Console commands registered")
end

-- =====================
-- REMOVE DUPLICATE GLOBAL FUNCTIONS
-- =====================
-- Remove these duplicate functions as they're already defined above
-- function consoleCommandIncome() ...
-- function income() ...
-- etc.

-- =====================
-- MOD REGISTRATION
-- =====================
addModEventListener(FS25IncomeMod)

log("========================================")
log("     FS25 Income Mod v1.0.1.0 LOADED    ")
log("     Author: TisonK                 ")
log("     Type 'income' in console for help  ")
log("========================================")