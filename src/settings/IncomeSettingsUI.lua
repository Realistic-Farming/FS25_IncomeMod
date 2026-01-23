---@class IncomeSettingsUI
IncomeSettingsUI = {}
local IncomeSettingsUI_mt = Class(IncomeSettingsUI)

function IncomeSettingsUI.new(settings)
    local self = setmetatable({}, IncomeSettingsUI_mt)
    self.settings = settings
    self.injected = false
    return self
end

function IncomeSettingsUI:inject()
    if self.injected then 
        return false
    end
    
    local page = g_gui.screenControllers[InGameMenu].pageSettings
    if not page then
        print("[Income Mod] Settings page not found - cannot inject settings!")
        return false
    end
    
    local layout = page.generalSettingsLayout
    if not layout then
        print("[Income Mod] Settings layout not found!")
        return false
    end
    
    -- Add Income Mod section
    local section = UIHelper.createSection(layout, "INCOME_MOD_SETTINGS")
    if not section then
        print("[Income Mod] Failed to create settings section!")
        return false
    end
    
    -- Add description
    UIHelper.createDescription(layout, "INCOME_MOD_DESCRIPTION")
    
    -- Add enabled toggle (Binary)
    local enabledOpt = UIHelper.createBinaryOption(
        layout,
        "income_enabled",
        "income_enabled",
        self.settings.enabled,
        function(val)
            self.settings.enabled = val
            self.settings:save()
            print(string.format("[Income Mod] Enabled: %s", tostring(val)))
        end
    )
    
    -- Add mode selection (Multi)
    local modeOptions = {
        g_i18n:getText("income_mode_hourly") or "Hourly",
        g_i18n:getText("income_mode_daily") or "Daily"
    }
    
    -- Convert mode string to index
    local modeIndex = 1
    if self.settings.mode == "daily" then
        modeIndex = 2
    end
    
    local modeOpt = UIHelper.createMultiOption(
        layout,
        "income_mode",
        "income_mode",
        modeOptions,
        modeIndex,
        function(val)
            self.settings.mode = (val == 1) and "hourly" or "daily"
            self.settings:save()
            print(string.format("[Income Mod] Mode set to: %s", self.settings.mode))
        end
    )
    
    -- Add difficulty selection (Multi)
    local difficultyOptions = {
        g_i18n:getText("income_difficulty_easy") or "Easy ($5,000)",
        g_i18n:getText("income_difficulty_normal") or "Normal ($2,400)",
        g_i18n:getText("income_difficulty_hard") or "Hard ($1,100)"
    }
    
    -- Convert difficulty string to index
    local diffIndex = 2  -- Default to normal
    if self.settings.difficulty == "easy" then
        diffIndex = 1
    elseif self.settings.difficulty == "hard" then
        diffIndex = 3
    end
    
    local diffOpt = UIHelper.createMultiOption(
        layout,
        "income_difficulty",
        "income_difficulty",
        difficultyOptions,
        diffIndex,
        function(val)
            local diffMap = {[1] = "easy", [2] = "normal", [3] = "hard"}
            self.settings.difficulty = diffMap[val] or "normal"
            self.settings.useCustomAmount = false
            self.settings:save()
            print(string.format("[Income Mod] Difficulty set to: %s", self.settings.difficulty))
        end
    )
    
    -- Add notifications toggle (Binary)
    local notificationOpt = UIHelper.createBinaryOption(
        layout,
        "income_notifications",
        "income_notifications",
        self.settings.showNotification,
        function(val)
            self.settings.showNotification = val
            self.settings:save()
            print(string.format("[Income Mod] Notifications: %s", tostring(val)))
        end
    )
    
    -- Save references to UI elements for refreshing
    self.enabledOption = enabledOpt
    self.modeOption = modeOpt
    self.difficultyOption = diffOpt
    self.notificationOption = notificationOpt
    
    self.injected = true
    
    -- Force layout update
    if layout.invalidateLayout then
        layout:invalidateLayout()
    end
    
    print("[Income Mod] Settings UI injected successfully")
    return true
end

--- Refresh UI elements after settings changes
function IncomeSettingsUI:refreshUI()
    if not self.injected or not self.settings then
        return
    end
    
    -- Update enabled toggle
    if self.enabledOption and self.enabledOption.setIsChecked then
        self.enabledOption:setIsChecked(self.settings.enabled)
    end
    
    -- Update mode selection
    if self.modeOption and self.modeOption.setState then
        local modeIndex = (self.settings.mode == "daily") and 2 or 1
        self.modeOption:setState(modeIndex)
    end
    
    -- Update difficulty selection
    if self.difficultyOption and self.difficultyOption.setState then
        local diffIndex = 2  -- normal
        if self.settings.difficulty == "easy" then
            diffIndex = 1
        elseif self.settings.difficulty == "hard" then
            diffIndex = 3
        end
        self.difficultyOption:setState(diffIndex)
    end
    
    -- Update notifications toggle
    if self.notificationOption and self.notificationOption.setIsChecked then
        self.notificationOption:setIsChecked(self.settings.showNotification)
    end
    
    print("[Income Mod] UI refreshed")
end