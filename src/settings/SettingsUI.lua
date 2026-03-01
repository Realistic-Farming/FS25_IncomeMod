-- =========================================================
-- FS25 Income Mod (version 2.0.0.5)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================

---@class SettingsUI
SettingsUI = {}
local SettingsUI_mt = Class(SettingsUI)

function SettingsUI.new(settings)
    local self = setmetatable({}, SettingsUI_mt)
    self.settings = settings
    self.injected = false
    return self
end

-- =========================================================
-- Inject into In-Game Settings
-- =========================================================

function SettingsUI:inject()
    if self.injected then
        return
    end

    local page = g_gui.screenControllers[InGameMenu].pageSettings
    if not page then
        Logging.error("im: Settings page not found - cannot inject settings!")
        return
    end

    local layout = page.generalSettingsLayout
    if not layout then
        Logging.error("im: Settings layout not found!")
        return
    end

    -- Section header
    local section = UIHelper.createSection(layout, "im_section")
    if not section then
        Logging.error("im: Failed to create settings section!")
        return
    end

    -- Enable toggle
    local enabledOpt = UIHelper.createBinaryOption(
        layout, "im_enabled", "im_enabled",
        self.settings.enabled,
        function(val)
            self.settings.enabled = val
            self.settings:save()
        end
    )

    -- Debug toggle
    local debugOpt = UIHelper.createBinaryOption(
        layout, "im_debug", "im_debug",
        self.settings.debugMode,
        function(val)
            self.settings.debugMode = val
            self.settings:save()
        end
    )

    -- Pay Mode: Hourly / Daily
    local payModeOpt = UIHelper.createMultiOption(
        layout, "im_paymode", "im_paymode",
        { UIHelper.getText("im_paymode_1"), UIHelper.getText("im_paymode_2") },
        self.settings.payMode,
        function(val)
            self.settings.payMode = val
            self.settings:save()
        end
    )

    -- Difficulty: Easy / Normal / Hard
    local diffOpt = UIHelper.createMultiOption(
        layout, "im_diff", "im_difficulty",
        {
            UIHelper.getText("im_diff_1"),
            UIHelper.getText("im_diff_2"),
            UIHelper.getText("im_diff_3"),
        },
        self.settings.difficulty,
        function(val)
            self.settings.difficulty = val
            self.settings:save()
        end
    )

    -- Income Multiplier: 1x / 2x / 5x / 10x
    local multOpt = UIHelper.createMultiOption(
        layout, "im_multiplier", "im_multiplier",
        {
            UIHelper.getText("im_mult_1"),
            UIHelper.getText("im_mult_2"),
            UIHelper.getText("im_mult_3"),
            UIHelper.getText("im_mult_4"),
        },
        self.settings.incomeMultiplier,
        function(val)
            self.settings.incomeMultiplier = val
            self.settings:save()
        end
    )

    -- Notifications toggle
    local notificationsOpt = UIHelper.createBinaryOption(
        layout, "im_notifications", "im_notifications",
        self.settings.showNotifications,
        function(val)
            self.settings.showNotifications = val
            self.settings:save()
        end
    )

    -- Seasonal Effects toggle
    local seasonalOpt = UIHelper.createBinaryOption(
        layout, "im_seasonal", "im_seasonal",
        self.settings.seasonalEffects,
        function(val)
            self.settings.seasonalEffects = val
            self.settings:save()
        end
    )

    -- Show HUD toggle
    local showHUDOpt = UIHelper.createBinaryOption(
        layout, "im_show_hud", "im_show_hud",
        self.settings.showHUD,
        function(val)
            self.settings.showHUD = val
            self.settings:save()
        end
    )

    self.enabledOption       = enabledOpt
    self.debugOption         = debugOpt
    self.payModeOption       = payModeOpt
    self.difficultyOption    = diffOpt
    self.multiplierOption    = multOpt
    self.notificationsOption = notificationsOpt
    self.seasonalOption      = seasonalOpt
    self.showHUDOption       = showHUDOpt

    self.injected = true
    layout:invalidateLayout()

    Logging.info("Income Mod: Settings UI injected successfully")
end

-- =========================================================
-- Refresh (called after reset or external settings change)
-- =========================================================

function SettingsUI:refreshUI()
    if not self.injected then
        return
    end

    local function setCheck(opt, val)
        if opt then
            if opt.setIsChecked then
                opt:setIsChecked(val)
            elseif opt.setState then
                opt:setState(val and 2 or 1)
            end
        end
    end

    local function setMulti(opt, val)
        if opt and opt.setState then
            opt:setState(val)
        end
    end

    setCheck(self.enabledOption,       self.settings.enabled)
    setCheck(self.debugOption,         self.settings.debugMode)
    setMulti(self.payModeOption,       self.settings.payMode)
    setMulti(self.difficultyOption,    self.settings.difficulty)
    setMulti(self.multiplierOption,    self.settings.incomeMultiplier)
    setCheck(self.notificationsOption, self.settings.showNotifications)
    setCheck(self.seasonalOption,      self.settings.seasonalEffects)
    setCheck(self.showHUDOption,       self.settings.showHUD)

    Logging.info("Income Mod: UI refreshed")
end

-- =========================================================
-- Reset Button in Footer (X key)
-- =========================================================

function SettingsUI:ensureResetButton(settingsFrame)
    if not settingsFrame or not settingsFrame.menuButtonInfo then
        return
    end

    if not self._resetButton then
        self._resetButton = {
            inputAction   = InputAction.MENU_EXTRA_1,
            text          = g_i18n:getText("im_reset") or "Reset Settings",
            callback      = function()
                if g_IncomeManager and g_IncomeManager.settings then
                    g_IncomeManager.settings:resetToDefaults()
                    if g_IncomeManager.settingsUI then
                        g_IncomeManager.settingsUI:refreshUI()
                    end
                end
            end,
            showWhenPaused = true,
        }
    end

    for _, btn in ipairs(settingsFrame.menuButtonInfo) do
        if btn == self._resetButton then
            return
        end
    end

    table.insert(settingsFrame.menuButtonInfo, self._resetButton)
    settingsFrame:setMenuButtonInfoDirty()
end
