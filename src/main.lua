-- =========================================================
-- FS25 Income Mod (version 2.1.6.1)
-- =========================================================
-- Passive hourly/daily income with difficulty tiers,
-- seasonal modifiers, multiplier, and per-farm MP support.
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================

-- Hot-reload latch (FuelCosts reference): g_currentModDirectory and
-- g_currentModName are nil on a live re-source, so they are latched into
-- module globals on first load, with a g_modsDirectory loose-folder fallback.
IncomeModModDirectory = IncomeModModDirectory
    or g_currentModDirectory
    or (g_modsDirectory ~= nil and (g_modsDirectory .. "FS25_IncomeMod/") or nil)
IncomeModModName = IncomeModModName or g_currentModName or "FS25_IncomeMod"
local modDirectory = IncomeModModDirectory
local modName = IncomeModModName

-- Load order matters: Settings before UI, UI before Core
source(modDirectory .. "src/integrations/OptionScalingResolver.lua")
source(modDirectory .. "src/settings/SettingsManager.lua")
source(modDirectory .. "src/settings/Settings.lua")
source(modDirectory .. "src/settings/SettingsGUI.lua")
source(modDirectory .. "src/ReleaseGate.lua")
source(modDirectory .. "src/utils/UIHelper.lua")
source(modDirectory .. "src/settings/SettingsUI.lua")
source(modDirectory .. "src/settings/SettingsHubBridge.lua")
source(modDirectory .. "src/integrations/IncomeStateLedgerBridge.lua")  -- bedrock: optional StateLedger timer-state bridge
source(modDirectory .. "src/integrations/IncomeEmergencyLoanBridge.lua") -- [C3] optional StateLedger emergency-loan debt bridge
source(modDirectory .. "src/integrations/IncomeMasterHUDBridge.lua")    -- bedrock: optional MasterHUD draw bridge
source(modDirectory .. "src/ui/IncomeHUD.lua")
source(modDirectory .. "src/ui/IncomeReportDialog.lua")
source(modDirectory .. "src/EmergencyLoan.lua")
source(modDirectory .. "src/IncomeSystem.lua")
source(modDirectory .. "src/IncomeManager.lua")

-- Esc RF PDA framework joiner (NO-HOST).
source((IncomeModModDirectory or g_currentModDirectory) .. "src/gui/RfEscModules.lua")
source((IncomeModModDirectory or g_currentModDirectory) .. "src/gui/RfPdaMenuPage.lua")
source((IncomeModModDirectory or g_currentModDirectory) .. "src/gui/RfEscBootstrap.lua")
source((IncomeModModDirectory or g_currentModDirectory) .. "src/gui/RfEscUiDebugger.lua")
source((IncomeModModDirectory or g_currentModDirectory) .. "src/gui/ImRfPdaGuest.lua")

local im  -- local handle, also exposed as g_IncomeManager

-- =========================================================
-- Lifecycle
-- =========================================================

local function load(mission)
    if im == nil then
        Logging.info("Income Mod v2.1.6.1: Initializing...")
        im = IncomeManager.new(mission, modDirectory, modName)
        getfenv(0)["g_IncomeManager"] = im
        -- Attach to g_currentMission for cross-mod access (getfenv(0) is per-mod scoped)
        mission.incomeManager = im
        Logging.info("Income Mod v2.1.6.1: Initialized successfully")
    end
end

local function loadedMission(mission, node)
    if im == nil then return end
    if mission.cancelLoading then return end
    im:onMissionLoaded()
end

local function unload()
    if im ~= nil then
        im:delete()
        im = nil
        getfenv(0)["g_IncomeManager"] = nil
        if g_currentMission then g_currentMission.incomeManager = nil end
    end
end

Mission00.load              = Utils.prependedFunction(Mission00.load, load)
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, loadedMission)

-- ---------------------------------------------------------
-- Realistic Farming Control Center: publish a runnable delegate.
--
-- IM_TOGGLE_HUD and IM_HUD_EDIT are deliberately absent: MasterHUD owns the
-- suite HUD keys. Both keep their directory row and live key readout.
-- ---------------------------------------------------------
local function registerControlCenterActions()
    local registry = g_currentMission ~= nil and g_currentMission.rfActionRegistry or nil
    if registry == nil then return end

    registry.registerAction({
        action     = "IM_INCOME_REPORT",
        button     = "Open",
        -- The report is a dialog of its own and cannot open behind this one.
        closeFirst = true,
        run = function()
            local mgr = g_IncomeManager
            if mgr ~= nil and mgr.onIncomeReportInput ~= nil then
                mgr:onIncomeReportInput()
            end
        end,
    })
end

Mission00.loadMission00Finished = Utils.appendedFunction(
    Mission00.loadMission00Finished, registerControlCenterActions)
FSBaseMission.delete        = Utils.appendedFunction(FSBaseMission.delete, unload)

-- Per-frame update
FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)
    if im then
        im:update(dt)
    end
end)

-- Per-frame draw: Income HUD overlay (client-side only).
-- When FS25_MasterHUD is installed it owns our draw (its single suspend-aware loop
-- calls IncomeMasterHUDBridge.drawStack), so this hook stands down to avoid double
-- drawing. When MasterHUD is absent this hook runs the exact same body. The draw body
-- lives in IncomeMasterHUDBridge.drawStack so the two paths can never diverge.
FSBaseMission.draw = Utils.appendedFunction(FSBaseMission.draw, function(mission)
    if IncomeMasterHUDBridge and IncomeMasterHUDBridge.active then return end
    if IncomeMasterHUDBridge then
        IncomeMasterHUDBridge.drawStack()
    end
end)

-- Route mouse events to IncomeHUD (RMB over panel = toggle; fixed position, no drag)
local incomeMouseHandler = {}
function incomeMouseHandler:mouseEvent(posX, posY, isDown, isUp, button, eventUsed, isAux)
    if eventUsed then return eventUsed end
    if im and im.incomeHUD then
        return im.incomeHUD:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    end
    return false
end
addModEventListener(incomeMouseHandler)

-- Auto-save timer state on every game save (prevents missed/double payments on reload)
Mission00.saveToXMLFile = Utils.appendedFunction(Mission00.saveToXMLFile, function(mission, xmlFilename)
    if im then
        im:save()
        if im.incomeHUD then im.incomeHUD:saveLayout() end
    end
end)

-- =========================================================
-- Console Helper Functions
-- =========================================================

local function getGUI()
    return g_IncomeManager and g_IncomeManager.settingsGUI
end

local function getSettings()
    return g_IncomeManager and g_IncomeManager.settings
end

function income()
    local gui = getGUI()
    if gui then
        return gui:consoleCommandHelp()
    end
    print("=== Income Mod v2.0 Commands ===")
    print("Type 'income' for full command list after the mod loads.")
    return "Income Mod commands"
end

function incomeStatus()
    local s = getSettings()
    if s then
        print(string.format(
            "Enabled: %s | Mode: %s | Difficulty: %s | Amount: $%d | Notifications: %s",
            tostring(s.enabled),
            s:getPayModeName(),
            s:getDifficultyName(),
            s:getPaymentAmount(),
            tostring(s.showNotifications)
        ))
    else
        print("Income Mod not initialized")
    end
end

getfenv(0)["income"]        = income
getfenv(0)["incomeStatus"]  = incomeStatus

function incomeRelease()
    local s = getSettings()
    if s then
        print(ReleaseGate and ReleaseGate.status(s:allowsExperimentalSystems()) or "Release gate not loaded")
    else
        print("Income Mod not initialized")
    end
end

getfenv(0)["incomeRelease"] = incomeRelease

getfenv(0)["incomeEnable"]  = function()
    local gui = getGUI()
    return gui and gui:consoleCommandIncomeEnable() or "Income Mod not initialized"
end

getfenv(0)["incomeDisable"] = function()
    local gui = getGUI()
    return gui and gui:consoleCommandIncomeDisable() or "Income Mod not initialized"
end

getfenv(0)["incomeTest"]    = function()
    local gui = getGUI()
    return gui and gui:consoleCommandTestPayment() or "Income Mod not initialized"
end

-- =========================================================
-- Load Banner
-- =========================================================

print("============================================")
print("    FS25 Income Mod v2.1.6.1 LOADED        ")
print("    Hourly/Daily income | Seasonal mods    ")
print("    Per-farm MP support | Type 'income'    ")
print("============================================")


local function _rfEscTryRegister()
    if ImRfPdaGuest ~= nil and type(ImRfPdaGuest.tryRegister) == "function" then
        pcall(ImRfPdaGuest.tryRegister)
    end
end

-- Esc RF PDA: register module after mission/door ready (retry-safe).
if Mission00 ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function()
        _rfEscTryRegister()
    end)
end
if FSBaseMission ~= nil then
    FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, function()
        _rfEscTryRegister()
    end)
end

if FSBaseMission ~= nil then
    FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, function()
        if ImRfPdaGuest ~= nil and type(ImRfPdaGuest.reset) == "function" then
            ImRfPdaGuest.reset()
        end
    end)
end
