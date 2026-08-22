-- =========================================================
-- FS25 Income Mod (version 2.1.5.0)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================

---@class IncomeManager
IncomeManager = IncomeManager or {}
local IncomeManager_mt = Class(IncomeManager)

function IncomeManager.new(mission, modDirectory, modName)
    local self = setmetatable({}, IncomeManager_mt)

    self.mission      = mission
    self.modDirectory = modDirectory
    self.modName      = modName

    self.settingsManager = SettingsManager.new()
    self.settings        = Settings.new(self.settingsManager)
    self.incomeSystem    = IncomeSystem.new(self.settings)
    -- [C3] EMERGENCY LOAN: the never-stuck recovery hatch. Owns the per-farm
    -- debt ledger; server-authoritative grant + Time Guard interest + income
    -- repayment. Armed in onMissionLoaded.
    self.emergencyLoan = EmergencyLoan.new()
    self.emergencyLoan.settings     = self.settings
    self.emergencyLoan.incomeSystem = self.incomeSystem

    -- UI injection and HUD: client-side only
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

        -- Income HUD overlay
        self.incomeHUD = IncomeHUD.new(self.incomeSystem, self.settings)

        -- Income Report Dialog (singleton; loaded once, shown on demand)
        self.incomeReportDialog = IncomeReportDialog.getInstance(self.modDirectory)

        -- Register key actions via PlayerInputComponent hook (proven race-condition-safe pattern)
        if PlayerInputComponent and PlayerInputComponent.registerActionEvents then
            local originalRegisterActionEvents = PlayerInputComponent.registerActionEvents
            self._inputHookOriginal = originalRegisterActionEvents
            PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
                originalRegisterActionEvents(inputComponent, ...)

                -- Only register for the local owning player, not networked players
                if not (inputComponent.player and inputComponent.player.isOwner) then return end
                -- Guard against double-registration on level reloads
                if g_IncomeManager and g_IncomeManager.toggleHUDEventId then return end
                if not g_IncomeManager or not g_IncomeManager.incomeHUD then return end

                g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

                -- HUD toggle: I key
                local hudOk, hudId = g_inputBinding:registerActionEvent(
                    InputAction.IM_TOGGLE_HUD,
                    g_IncomeManager,
                    g_IncomeManager.onToggleHUDInput,
                    false,  -- triggerUp
                    true,   -- triggerDown
                    false,  -- triggerAlways
                    true    -- startActive
                )
                if hudOk and hudId then
                    g_IncomeManager.toggleHUDEventId = hudId
                    Logging.info("Income Mod: HUD toggle (I) registered")
                else
                    Logging.warning("Income Mod: HUD toggle (I) registration failed")
                end

                -- Income Report: U key
                local repOk, repId = g_inputBinding:registerActionEvent(
                    InputAction.IM_INCOME_REPORT,
                    g_IncomeManager,
                    g_IncomeManager.onIncomeReportInput,
                    false,  -- triggerUp
                    true,   -- triggerDown
                    false,  -- triggerAlways
                    true    -- startActive
                )
                if repOk and repId then
                    g_IncomeManager.incomeReportEventId = repId
                    Logging.info("Income Mod: Income Report (U) registered")
                else
                    Logging.warning("Income Mod: Income Report (U) registration failed")
                end

                g_inputBinding:endActionEventsModification()
            end
        end
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
    -- Register with SettingsHub (if installed) so FarmTablet's System
    -- Settings app can list Income Mod's settings. No-ops safely if
    -- SettingsHub isn't present.
    IncomeSettingsHubBridge.register(self)

    -- StateLedger (bedrock, delegate-when-present): when installed, the shared master
    -- save file becomes the load source of truth for the income timer state;
    -- FS25_IncomeMod_state.xml stays the standalone safety copy. Registered BEFORE
    -- self:loadState() below so the ledger's deserialize has delivered when we read
    -- (register() forces the parse, since we load in the same phase StateLedger parses).
    if IncomeStateLedgerBridge then
        IncomeStateLedgerBridge.register(self)
    end

    -- [C3] EMERGENCY LOAN: register the debt-ledger sidecar with StateLedger
    -- (delegate-when-present) so the ledger's deserialize has delivered before
    -- the loan reads its state. No-ops when StateLedger is absent (the loan is
    -- then session-only, which is the graceful degrade for a recovery hatch).
    if IncomeEmergencyLoanBridge then
        IncomeEmergencyLoanBridge.register(self)
    end

    -- MasterHUD (bedrock, delegate-when-present): when installed, the income HUD draw
    -- folds into MasterHUD's single suspend-aware loop and our own FSBaseMission.draw
    -- hook stands down. No-ops when MasterHUD is absent (own hook draws it).
    if IncomeMasterHUDBridge then
        IncomeMasterHUDBridge.register(self)
    end

    if self.incomeSystem then
        self.incomeSystem:initialize()
    end

    -- Restore HUD layout (position/scale) saved by the player
    if self.incomeHUD then
        self.incomeHUD:loadLayout()
    end

    -- Restore timer state from previous save (prevents double-payment on reload)
    self:loadState()

    -- Single startup notification (client-side only, notification is now in
    -- IncomeSystem:showNotification which guards getIsClient internally)
    if self.settings.enabled and self.settings.showNotifications then
        if g_currentMission and g_currentMission:getIsClient() then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, "Income Mod Active - Type 'income' for commands")
        end
    end
end

-- =========================================================
-- Key Action Callback
-- =========================================================

function IncomeManager:onToggleHUDInput()
    if self.incomeHUD then
        self.incomeHUD:toggleVisibility()
    end
end

function IncomeManager:onIncomeReportInput()
    if self.incomeReportDialog then
        self.incomeReportDialog:show()
    end
end

-- =========================================================
-- Per-frame update
-- =========================================================

function IncomeManager:update(dt)
    if self.incomeSystem then
        self.incomeSystem:update(dt)
    end
    if self.emergencyLoan then
        -- [C3] refresh the forecast cache on the day boundary, never per-frame.
        local env = g_currentMission and g_currentMission.environment
        local mono = env and env.currentMonotonicDay or -1
        if mono ~= -1 and mono ~= self._emergencyLoanDay then
            self._emergencyLoanDay = mono
            self.emergencyLoan:onDayChange()
        end
    end
    if self.incomeHUD then
        self.incomeHUD:update(dt)
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
            self.incomeSystem.lastDay,
            self.incomeSystem.lastMonotonicDay
        )
    end
end

-- =========================================================
-- Load Timer State
-- =========================================================

function IncomeManager:loadState()
    if not self.incomeSystem then return end
    -- StateLedger is the load source of truth when present and it delivered a state
    -- block; otherwise read the standalone FS25_IncomeMod_state.xml (also the first-load
    -- path right after installing the ledger onto an existing save). The state file is
    -- written every save regardless, as a safety copy.
    if IncomeStateLedgerBridge and IncomeStateLedgerBridge.hasState() then
        IncomeStateLedgerBridge.applyState(self.incomeSystem)
        return
    end
    if self.settingsManager then
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
    -- Remove action events for I key (HUD) and U key (Report)
    if self.toggleHUDEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.toggleHUDEventId)
        self.toggleHUDEventId = nil
    end

    if self.incomeReportEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.incomeReportEventId)
        self.incomeReportEventId = nil
    end

    -- Restore the PlayerInputComponent hook if we patched it
    if self._inputHookOriginal and PlayerInputComponent then
        PlayerInputComponent.registerActionEvents = self._inputHookOriginal
        self._inputHookOriginal = nil
    end

    -- Destroy HUD overlay
    if self.incomeHUD then
        self.incomeHUD:saveLayout()
        self.incomeHUD:delete()
        self.incomeHUD = nil
    end

    -- Release singleton dialog reference (the FS25 GUI system owns the element tree;
    -- we just drop our handle so it can be GC'd if the session ends)
    self.incomeReportDialog = nil

    self:save()
    Logging.info("Income Mod: Shut down cleanly")
end
