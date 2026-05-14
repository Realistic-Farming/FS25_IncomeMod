-- =========================================================
-- FS25 Income Mod (version 2.1.5.0)
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

local modDirectory = g_currentModDirectory
local modName      = g_currentModName

-- Load order matters: Settings before UI, UI before Core
source(modDirectory .. "src/settings/SettingsManager.lua")
source(modDirectory .. "src/settings/Settings.lua")
source(modDirectory .. "src/settings/SettingsGUI.lua")
source(modDirectory .. "src/utils/UIHelper.lua")
source(modDirectory .. "src/settings/SettingsUI.lua")
source(modDirectory .. "src/ui/IncomeHUD.lua")
source(modDirectory .. "src/ui/IncomeReportDialog.lua")
source(modDirectory .. "src/IncomeSystem.lua")
source(modDirectory .. "src/IncomeManager.lua")

local im  -- local handle, also exposed as g_IncomeManager

-- =========================================================
-- Lifecycle
-- =========================================================

local function load(mission)
    if im == nil then
        Logging.info("Income Mod v2.0.0.5: Initializing...")
        im = IncomeManager.new(mission, modDirectory, modName)
        getfenv(0)["g_IncomeManager"] = im
        -- Attach to g_currentMission for cross-mod access (getfenv(0) is per-mod scoped)
        mission.incomeManager = im
        Logging.info("Income Mod v2.0.0.5: Initialized successfully")
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
FSBaseMission.delete        = Utils.appendedFunction(FSBaseMission.delete, unload)

-- Per-frame update
FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)
    if im then
        im:update(dt)
    end
end)

-- Per-frame draw: Income HUD overlay (client-side only)
FSBaseMission.draw = Utils.appendedFunction(FSBaseMission.draw, function(mission)
    if im and im.incomeHUD then
        im.incomeHUD:draw()
    end
end)

-- Route mouse events to IncomeHUD (RMB over panel = toggle; fixed position, no drag)
local incomeMouseHandler = {}
function incomeMouseHandler:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
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
print("    FS25 Income Mod v2.0.0.5 LOADED        ")
print("    Hourly/Daily income | Seasonal mods    ")
print("    Per-farm MP support | Type 'income'    ")
print("============================================")
