-- =========================================================
-- FS25 Income Mod (version 2.1.6.0)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================

---@class SettingsGUI
SettingsGUI = {}
local SettingsGUI_mt = Class(SettingsGUI)

function SettingsGUI.new()
    return setmetatable({}, SettingsGUI_mt)
end

function SettingsGUI:registerConsoleCommands()
    addConsoleCommand("IncomeSetDifficulty",    "Set difficulty (1=Easy, 2=Normal, 3=Hard)",          "consoleCommandSetDifficulty",    self)
    addConsoleCommand("IncomeEnable",            "Enable Income Mod",                                   "consoleCommandIncomeEnable",     self)
    addConsoleCommand("IncomeDisable",           "Disable Income Mod",                                  "consoleCommandIncomeDisable",    self)
    addConsoleCommand("IncomeSetPayMode",        "Set pay mode (1=Hourly, 2=Daily)",                    "consoleCommandSetPayMode",       self)
    addConsoleCommand("IncomeSetNotifications",  "Enable/disable notifications (true/false)",           "consoleCommandSetNotifications", self)
    addConsoleCommand("IncomeSetCustomAmount",   "Set custom payment amount (0 = use difficulty)",      "consoleCommandSetCustomAmount",  self)
    addConsoleCommand("IncomeSetDebug",          "Toggle debug mode (true/false)",                      "consoleCommandSetDebug",         self)
    addConsoleCommand("IncomeTestPayment",       "Test payment system",                                 "consoleCommandTestPayment",      self)
    addConsoleCommand("IncomeShowSettings",      "Show current settings",                               "consoleCommandShowSettings",     self)
    addConsoleCommand("IncomeResetSettings",     "Reset all settings to defaults",                      "consoleCommandResetSettings",    self)
    addConsoleCommand("IncomeHistory",           "Show last 10 payment records",                        "consoleCommandHistory",          self)
    addConsoleCommand("IncomeNext",              "Show when the next payment fires",                    "consoleCommandNext",             self)
    addConsoleCommand("IncomeToggleHUD",         "Show/hide the income HUD overlay (true/false)",       "consoleCommandToggleHUD",        self)
    addConsoleCommand("income",                  "Show all income commands",                            "consoleCommandHelp",             self)

    Logging.info("Income Mod console commands registered")
end

-- =========================================================
-- Help
-- =========================================================

function SettingsGUI:consoleCommandHelp()
    print("=== Income Mod v2.0 Console Commands ===")
    print("income                        - Show this help")
    print("IncomeToggleHUD true|false    - Show/hide the income HUD")
    print("IncomeEnable / IncomeDisable  - Toggle mod on/off")
    print("IncomeSetDifficulty 1|2|3     - Easy / Normal / Hard")
    print("IncomeSetPayMode 1|2          - Hourly / Daily")
    print("IncomeSetNotifications t|f    - Toggle notifications")
    print("IncomeSetCustomAmount <n>     - Override amount (0 = difficulty)")
    print("IncomeSetDebug true|false     - Toggle debug logging")
    print("IncomeTestPayment             - Trigger $1 test payment")
    print("IncomeShowSettings            - Show all current settings")
    print("IncomeResetSettings           - Reset to defaults")
    print("IncomeHistory                 - Last 10 payment records")
    print("IncomeNext                    - Time until next payment")
    print("=========================================")
    return "Type 'income' for this list"
end

-- =========================================================
-- Enable / Disable
-- =========================================================

function SettingsGUI:consoleCommandIncomeEnable()
    if g_IncomeManager and g_IncomeManager.settings then
        g_IncomeManager.settings.enabled = true
        g_IncomeManager.settings:save()
        if g_IncomeManager.incomeSystem then
            g_IncomeManager.incomeSystem:initialize()
        end
        return "Income Mod enabled"
    end
    return "Error: Income Mod not initialized"
end

function SettingsGUI:consoleCommandIncomeDisable()
    if g_IncomeManager and g_IncomeManager.settings then
        g_IncomeManager.settings.enabled = false
        g_IncomeManager.settings:save()
        return "Income Mod disabled"
    end
    return "Error: Income Mod not initialized"
end

-- =========================================================
-- Difficulty
-- =========================================================

function SettingsGUI:consoleCommandSetDifficulty(difficulty)
    local diff = tonumber(difficulty)
    if not diff or diff < 1 or diff > 3 then
        return "Invalid difficulty. Use 1 (Easy), 2 (Normal), or 3 (Hard)"
    end
    if g_IncomeManager and g_IncomeManager.settings then
        g_IncomeManager.settings:setDifficulty(diff)
        g_IncomeManager.settings:save()
        return string.format("Difficulty set to: %s ($%d base)",
            g_IncomeManager.settings:getDifficultyName(),
            g_IncomeManager.settings:getDifficultyAmount())
    end
    return "Error: Income Mod not initialized"
end

-- =========================================================
-- Pay Mode
-- =========================================================

function SettingsGUI:consoleCommandSetPayMode(mode)
    local payMode = tonumber(mode)
    if not payMode or (payMode ~= 1 and payMode ~= 2) then
        return "Invalid pay mode. Use 1 (Hourly) or 2 (Daily)"
    end
    if g_IncomeManager and g_IncomeManager.settings then
        g_IncomeManager.settings:setPayMode(payMode)
        g_IncomeManager.settings:save()
        return string.format("Pay mode set to: %s", g_IncomeManager.settings:getPayModeName())
    end
    return "Error: Income Mod not initialized"
end

-- =========================================================
-- Notifications
-- =========================================================

function SettingsGUI:consoleCommandSetNotifications(enabled)
    if enabled == nil then
        return "Usage: IncomeSetNotifications true|false"
    end
    local enable = enabled:lower()
    if enable ~= "true" and enable ~= "false" then
        return "Invalid value. Use 'true' or 'false'"
    end
    if g_IncomeManager and g_IncomeManager.settings then
        g_IncomeManager.settings.showNotifications = (enable == "true")
        g_IncomeManager.settings:save()
        return string.format("Notifications %s",
            g_IncomeManager.settings.showNotifications and "enabled" or "disabled")
    end
    return "Error: Income Mod not initialized"
end

-- =========================================================
-- Custom Amount
-- =========================================================

function SettingsGUI:consoleCommandSetCustomAmount(amount)
    local customAmount = tonumber(amount)
    if not customAmount or customAmount < 0 then
        return "Invalid amount. Use a positive number or 0 to use difficulty setting"
    end
    if g_IncomeManager and g_IncomeManager.settings then
        g_IncomeManager.settings.customAmount = math.floor(customAmount)
        g_IncomeManager.settings:save()
        if customAmount > 0 then
            return string.format("Custom amount set to: $%d", math.floor(customAmount))
        else
            return "Custom amount disabled, using difficulty setting"
        end
    end
    return "Error: Income Mod not initialized"
end

-- =========================================================
-- Debug Toggle
-- =========================================================

function SettingsGUI:consoleCommandSetDebug(value)
    if value == nil then
        return "Usage: IncomeSetDebug true|false"
    end
    local v = value:lower()
    if v ~= "true" and v ~= "false" then
        return "Invalid value. Use 'true' or 'false'"
    end
    if g_IncomeManager and g_IncomeManager.settings then
        g_IncomeManager.settings.debugMode = (v == "true")
        g_IncomeManager.settings:save()
        return string.format("Debug mode %s", g_IncomeManager.settings.debugMode and "enabled" or "disabled")
    end
    return "Error: Income Mod not initialized"
end

-- =========================================================
-- HUD Toggle
-- =========================================================

function SettingsGUI:consoleCommandToggleHUD(value)
    if value == nil then
        return "Usage: IncomeToggleHUD true|false"
    end
    local v = value:lower()
    if v ~= "true" and v ~= "false" then
        return "Invalid value. Use 'true' or 'false'"
    end
    if g_IncomeManager and g_IncomeManager.settings then
        local show = (v == "true")
        g_IncomeManager.settings.showHUD = show
        g_IncomeManager.settings:save()
        -- Sync the runtime I-key visibility flag so both gates agree with the
        -- console command's intent. Without this, pressing I to hide then calling
        -- IncomeToggleHUD true would leave the HUD stuck hidden.
        if g_IncomeManager.incomeHUD then
            g_IncomeManager.incomeHUD.visible = show
        end
        return string.format("Income HUD %s", show and "shown" or "hidden")
    end
    return "Error: Income Mod not initialized"
end

-- =========================================================
-- Test Payment
-- =========================================================

function SettingsGUI:consoleCommandTestPayment()
    if g_IncomeManager and g_IncomeManager.incomeSystem then
        local success = g_IncomeManager.incomeSystem:giveMoney("test")
        if success then
            return "Test payment executed ($1)"
        else
            return "Test payment failed (check log — server-only in MP)"
        end
    end
    return "Error: Income Mod not initialized"
end

-- =========================================================
-- Show Settings
-- =========================================================

function SettingsGUI:consoleCommandShowSettings()
    if g_IncomeManager and g_IncomeManager.settings then
        local s = g_IncomeManager.settings
        local seasonNote = s.seasonalEffects and " (seasonal effects active)" or ""
        local info = string.format(
            "=== Income Mod v2.0 Settings ===\n"
            .. "Enabled:          %s\n"
            .. "Debug Mode:       %s\n"
            .. "Pay Mode:         %s\n"
            .. "Difficulty:       %s\n"
            .. "Income Multiplier:%s\n"
            .. "Payment Amount:   $%d%s\n"
            .. "Custom Amount:    $%d\n"
            .. "Notifications:    %s\n"
            .. "Seasonal Effects: %s\n"
            .. "Show HUD:         %s\n"
            .. "=================================",
            tostring(s.enabled),
            tostring(s.debugMode),
            s:getPayModeName(),
            s:getDifficultyName(),
            s:getMultiplierName(),
            s:getPaymentAmount(), seasonNote,
            s.customAmount,
            tostring(s.showNotifications),
            tostring(s.seasonalEffects),
            tostring(s.showHUD)
        )
        print(info)
        return info
    end
    return "Error: Income Mod not initialized"
end

-- =========================================================
-- Reset Settings
-- =========================================================

function SettingsGUI:consoleCommandResetSettings()
    if g_IncomeManager and g_IncomeManager.settings then
        g_IncomeManager.settings:resetToDefaults()

        if g_IncomeManager.incomeSystem then
            g_IncomeManager.incomeSystem:initialize()
        end

        if g_IncomeManager.settingsUI then
            g_IncomeManager.settingsUI:refreshUI()
        end

        return "Income Mod settings reset to defaults!"
    end
    return "Error: Income Mod not initialized"
end

-- =========================================================
-- Payment History
-- =========================================================

function SettingsGUI:consoleCommandHistory()
    if not g_IncomeManager or not g_IncomeManager.incomeSystem then
        return "Error: Income Mod not initialized"
    end

    local history = g_IncomeManager.incomeSystem.paymentHistory
    if not history or #history == 0 then
        print("Income Mod: No payment history yet")
        return "No history"
    end

    print("=== Income Mod - Payment History (most recent first) ===")
    for i, entry in ipairs(history) do
        local seasonInfo = ""
        if entry.seasonMult and entry.seasonMult ~= 1.0 then
            seasonInfo = string.format(" [x%.1f seasonal]", entry.seasonMult)
        end
        print(string.format(
            "  %2d. Day %-3d  %02d:00  $%-6d  %-6s%s",
            i, entry.day, entry.hour, entry.amount, entry.payType, seasonInfo
        ))
    end
    print("========================================================")
    return string.format("%d record(s) shown", #history)
end

-- =========================================================
-- Next Payment
-- =========================================================

function SettingsGUI:consoleCommandNext()
    if not g_IncomeManager or not g_IncomeManager.incomeSystem then
        return "Error: Income Mod not initialized"
    end

    local sys = g_IncomeManager.incomeSystem
    if not sys.isInitialized then
        return "Income system not initialized yet"
    end

    if not g_IncomeManager.settings.enabled then
        return "Income Mod is currently disabled"
    end

    local info  = sys:getNextPaymentInfo()
    local amount = g_IncomeManager.settings:getPaymentAmount()
    local msg = string.format("Next payment: %s | Amount: $%d", info, amount)
    print(msg)
    return msg
end
