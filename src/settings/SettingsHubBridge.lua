-- =========================================================
-- FS25 Income Mod (version 2.1.5.0)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_SettingsHub. Safe if SettingsHub is not
-- installed (register() just no-ops). Purpose: let the FarmTablet
-- System Settings app list Income Mod's settings.
--
-- Scope, deliberately narrow for this pass:
--   - IncomeMod's own Settings.lua / SettingsManager.lua remain the
--     source of truth and keep saving to their own XML exactly as
--     before. Nothing about the existing in-game menu or console
--     commands changes.
--   - SettingsHub is registered with the CURRENT values at mission
--     load, so the FarmTablet display starts correct.
--   - Edits made *through* SettingsHub (e.g. a future FarmTablet
--     editor -- the app is read-only for now per its own help text)
--     flow back into Settings via applyChange() below and get saved
--     through the normal Settings:save() path.
--   - Changes made through the existing ESC-menu settings screen or
--     console commands do NOT currently push back into SettingsHub's
--     cached copy, so the FarmTablet display can lag behind those
--     until the next mission load. That's an intentional, disclosed
--     limitation for this pass -- closing the loop means touching
--     every existing callback site in a live mod, which is a
--     separate, verifiable change of its own.
-- =========================================================

IncomeSettingsHubBridge = {}

local function applyChange(key, value)
    local im = g_IncomeManager
    if im == nil or im.settings == nil then return end
    local s = im.settings

    if key == "difficulty" then
        s:setDifficulty(value)
    elseif key == "payMode" then
        s:setPayMode(value)
    elseif key == "showHUD" then
        s.showHUD = value
        if im.incomeHUD then im.incomeHUD.visible = value end
    else
        s[key] = value
    end

    s:save()
    if im.settingsUI then im.settingsUI:refreshUI() end
end

function IncomeSettingsHubBridge.register(im)
    -- The reliable cross-mod handle is g_currentMission.settingsHub (the same one
    -- FarmTablet reads). The bare g_settingsHub global is only visible inside
    -- SettingsHub's own mod environment, so it reads back nil from here.
    local hub = (g_currentMission ~= nil and g_currentMission.settingsHub) or g_settingsHub
    if hub == nil then return end
    if im == nil or im.settings == nil then return end
    local s = im.settings

    local defs = {
        { id = "enabled",           type = "bool", default = s.enabled,           adminOnly = true,  label = "Income Mod Enabled" },
        { id = "payMode",           type = "enum", default = s.payMode,           adminOnly = true,  values = { 1, 2 },       label = "Pay Mode (1=Hourly, 2=Daily)" },
        { id = "difficulty",        type = "enum", default = s.difficulty,        adminOnly = true,  values = { 1, 2, 3 },    label = "Difficulty (1=Easy, 2=Normal, 3=Hard)" },
        { id = "incomeMultiplier",  type = "enum", default = s.incomeMultiplier,  adminOnly = true,  values = { 1, 2, 3, 4 }, label = "Income Multiplier Index (1x/2x/5x/10x)" },
        { id = "customAmount",      type = "int",  default = s.customAmount,      adminOnly = true,  min = 0, max = 999999, label = "Custom Payment Amount" },
        { id = "seasonalEffects",   type = "bool", default = s.seasonalEffects,   adminOnly = true,  label = "Seasonal Effects" },
        { id = "showNotifications", type = "bool", default = s.showNotifications, adminOnly = false, label = "Show Notifications" },
        { id = "showHUD",           type = "bool", default = s.showHUD,           adminOnly = false, label = "Show HUD" },
        { id = "debugMode",         type = "bool", default = s.debugMode,         adminOnly = false, label = "Debug Mode" },
        { id = "experimentalSystems", type = "bool", default = s.experimentalSystems, adminOnly = true, label = "Experimental Systems" },
    }

    local ok, err = pcall(function()
        hub:registerModule("IncomeMod", {
            adminSettings = defs,
            onChange      = function(key, value, playerId) applyChange(key, value) end,
            -- We own our persistence (Settings.lua / SettingsManager.lua save to our own
            -- XML) and load it before this registration runs, so the hub must mirror-for-
            -- display only: never restore its own stale copy and replay it back through
            -- onChange on load. Without this the hub can push a stale value over our real
            -- setting every load (the SoilFertilizer `enabled=false` reset-on-load bug class).
            selfPersisted = true,
        })
    end)

    if ok then
        Logging.info("Income Mod: Registered with SettingsHub (%d setting(s))", #defs)
    else
        Logging.warning("Income Mod: SettingsHub registration failed: %s", tostring(err))
    end
end
