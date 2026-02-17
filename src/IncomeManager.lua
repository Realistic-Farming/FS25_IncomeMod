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

---@class IncomeManager
IncomeManager = {}
local IncomeManager_mt = Class(IncomeManager)

function IncomeManager.new(mission, modDirectory, modName)
    local self = setmetatable({}, IncomeManager_mt)

    self.mission      = mission
    self.modDirectory = modDirectory
    self.modName      = modName

    self.settingsManager = SettingsManager.new()
    self.settings        = Settings.new(self.settingsManager)
    self.incomeSystem    = IncomeSystem.new(self.settings)

    -- UI injection: client-side only
    if mission:getIsClient() and g_gui then
        self.settingsUI = SettingsUI.new(self.settings)

        InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
            InGameMenuSettingsFrame.onFrameOpen,
            function()
                self.settingsUI:inject()
            end
        )

        InGameMenuSettingsFrame.updateButtons = Utils.appendedFunction(
            InGameMenuSettingsFrame.updateButtons,
            function(frame)
                if self.settingsUI then
                    self.settingsUI:ensureResetButton(frame)
                end
            end
        )
    end

    self.settingsGUI = SettingsGUI.new()
    self.settingsGUI:registerConsoleCommands()

    self.settings:load()

    return self
end

-- =========================================================
-- Called after map load is complete
-- =========================================================

function IncomeManager:onMissionLoaded()
    if self.incomeSystem then
        self.incomeSystem:initialize()
    end

    -- Restore timer state from previous save (prevents double-payment on reload)
    self:loadState()

    -- Single startup notification (client-side only, notification is now in
    -- IncomeSystem:showNotification which guards getIsClient internally)
    if self.settings.enabled and self.settings.showNotifications then
        if g_currentMission and g_currentMission:getIsClient() then
            if g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
                g_currentMission.hud:showBlinkingWarning(
                    "Income Mod Active - Type 'income' for commands", 4000
                )
            end
        end
    end
end

-- =========================================================
-- Per-frame update
-- =========================================================

function IncomeManager:update(dt)
    if self.incomeSystem then
        self.incomeSystem:update(dt)
    end
end

-- =========================================================
-- Save (called from saveToXMLFile hook and on delete)
-- =========================================================

function IncomeManager:save()
    if self.settings then
        self.settings:save()
    end

    -- Persist timer state so reloads don't cause missed/double payments
    if self.incomeSystem and self.settingsManager then
        self.settingsManager:saveTimerState(
            self.incomeSystem.lastHour,
            self.incomeSystem.lastDay
        )
    end
end

-- =========================================================
-- Load Timer State
-- =========================================================

function IncomeManager:loadState()
    if self.incomeSystem and self.settingsManager then
        local state = self.settingsManager:loadTimerState()
        if state then
            self.incomeSystem:loadState(state)
        end
    end
end

-- =========================================================
-- Cleanup
-- =========================================================

function IncomeManager:delete()
    self:save()
    Logging.info("Income Mod: Shut down cleanly")
end
