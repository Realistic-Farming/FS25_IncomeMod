--!load: tools/test/lua/f201_model_binding.lua, src/IncomeManager.lua
-- RSF-F201 (items 11, 12, detail 8), IncomeMod PLAYER-lifetime companion, run
-- against the REAL src/IncomeManager.lua: standalone stores both HUD handles and
-- the edit label, the report handle, no failure log; a second callback trips the
-- existing guard; delete removes all three and restores nothing; a second manager
-- re-arms the same wrapper. Model binding, not the native InputBinding.

local noop = function() end
getfenv = getfenv or function() return _G end
Utils = Utils or {}
Utils.appendedFunction = Utils.appendedFunction or function(old, new)
    if old == nil then return new end
    return function(...) old(...); return new(...) end
end
g_gui = g_gui or {}
InGameMenuSettingsFrame = InGameMenuSettingsFrame or { onFrameOpen = noop, updateButtons = noop }
SettingsManager = { new = function() return {} end }
Settings = { new = function() return { load = noop, save = noop } end }
IncomeSystem = { new = function() return {} end }
EmergencyLoan = { new = function() return {} end }
SettingsUI = { new = function() return { inject = noop, ensureResetButton = noop } end }
IncomeHUD = { new = function() return { saveLayout = noop, delete = noop } end }
IncomeReportDialog = { getInstance = function() return {} end }
SettingsGUI = { new = function() return { registerConsoleCommands = noop } end }

local warnings = 0
Logging.warning = function() warnings = warnings + 1 end

local b = F201Model.installEngine({ "IM_TOGGLE_HUD", "IM_HUD_EDIT", "IM_INCOME_REPORT" })
local nativeCalls = 0
PlayerInputComponent.registerActionEvents = function() nativeCalls = nativeCalls + 1 end
local native = PlayerInputComponent.registerActionEvents

local mission = { getIsClient = function() return true end, getIsServer = function() return true end, missionInfo = {} }
g_currentMission = mission
g_masterHUD = nil

-- GROUP A: construction installs one wrapper and arms it
local im = IncomeManager.new(mission, "./", "FS25_IncomeMod")
g_IncomeManager = im
local w = PlayerInputComponent.registerActionEvents
T.ok("F201 Income A1 constructor wraps registerActionEvents", w ~= native)
T.eq("F201 Income A2 install latch on the class table", IncomeManager._f201Input.installed, true)
T.eq("F201 Income A3 predecessor held on the class table", IncomeManager._f201Input.original, native)
T.eq("F201 Income A4 armed", IncomeManager._f201Input.active, true)

-- GROUP B: standalone (no MasterHUD) stores all three handles, no failure line
local ic = { player = { isOwner = true } }
w(ic)
T.eq("F201 Income B1 predecessor called", nativeCalls, 1)
T.eq("F201 Income B2 three registrations", b.attempts, 3)
T.ok("F201 Income B3 toggle handle stored (unshadowed)", im.toggleHUDEventId ~= nil)
T.ok("F201 Income B4 edit handle stored (unshadowed)", im.hudEditEventId ~= nil)
T.eq("F201 Income B5 edit label set", b.events[im.hudEditEventId].text, "input_IM_HUD_EDIT")
T.ok("F201 Income B6 report handle stored", im.incomeReportEventId ~= nil)
T.eq("F201 Income B7 no failure warning standalone", warnings, 0)
w(ic)
T.eq("F201 Income B8 second callback trips the existing guard", b.attempts, 3)
w({ player = { isOwner = false } })
T.eq("F201 Income B9 non-owner registers nothing", b.attempts, 3)

-- GROUP C: delete removes all three, retires, restores nothing
im.save = noop
im:delete()
T.eq("F201 Income C1 toggle handle cleared", im.toggleHUDEventId, nil)
T.eq("F201 Income C2 edit handle cleared", im.hudEditEventId, nil)
T.eq("F201 Income C3 report handle cleared", im.incomeReportEventId, nil)
T.eq("F201 Income C4 nothing left in the PLAYER lists", b:totalIn("PLAYER"), 0)
T.eq("F201 Income C5 wrapper NOT restored", PlayerInputComponent.registerActionEvents, w)
T.eq("F201 Income C6 disarmed", IncomeManager._f201Input.active, false)
w(ic)
T.eq("F201 Income C7 predecessor still called while disarmed", nativeCalls, 4)
T.eq("F201 Income C8 disarmed wrapper registers nothing", b.attempts, 3)

-- GROUP D: a second manager re-arms the same wrapper, no stacking
local im2 = IncomeManager.new(mission, "./", "FS25_IncomeMod")
g_IncomeManager = im2
T.eq("F201 Income D1 no second wrapper", PlayerInputComponent.registerActionEvents, w)
T.eq("F201 Income D2 re-armed", IncomeManager._f201Input.active, true)
w(ic)
T.eq("F201 Income D3 registers for the new owner", b.attempts, 6)
T.ok("F201 Income D4 new owner holds the toggle handle", im2.toggleHUDEventId ~= nil)
T.eq("F201 Income D5 old owner untouched", im.toggleHUDEventId, nil)

-- GROUP E: with MasterHUD present the two HUD keys do not register, the report does
im2.save = noop
im2:delete()
g_masterHUD = {}
local im3 = IncomeManager.new(mission, "./", "FS25_IncomeMod")
g_IncomeManager = im3
warnings = 0
w(ic)
T.eq("F201 Income E1 only the report registers under MasterHUD", b:totalIn("PLAYER"), 1)
T.ok("F201 Income E2 report handle stored", im3.incomeReportEventId ~= nil)
T.eq("F201 Income E3 toggle skipped", im3.toggleHUDEventId, nil)
T.eq("F201 Income E4 the pre-existing gated failure line still prints (unchanged by F201)", warnings, 1)
