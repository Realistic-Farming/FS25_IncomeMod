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

---@class SettingsGUI
SettingsGUI = SettingsGUI or {}
local SettingsGUI_mt = Class(SettingsGUI)

function SettingsGUI.new()
    return setmetatable({}, SettingsGUI_mt)
end

function SettingsGUI:registerConsoleCommands()
    addConsoleCommand("IncomeSetDifficulty",    "Set difficulty (1=Easy, 2=Normal, 3=Hard)",          "consoleCommandSetDifficulty",    self)
    addConsoleCommand("IncomeEnable",            "Enable Income Mod",                                   "consoleCommandIncomeEnable",     self)
    addConsoleCommand("IncomeDisable",           "Disable Income Mod",                                  "consoleCommandIncomeDisable",    self)
    addConsoleCommand("IncomeSetPayMode",        "Set pay mode (1=Hourly, 2=Daily); add 'confirm' to apply", "consoleCommandSetPayMode",  self)
    addConsoleCommand("IncomeSetNotifications",  "Enable/disable notifications (true/false)",           "consoleCommandSetNotifications", self)
    addConsoleCommand("IncomeSetCustomAmount",   "Set the payment amount, 0 to 999999 (0 = use difficulty)", "consoleCommandSetCustomAmount", self)
    addConsoleCommand("IncomeSetDebug",          "Toggle debug mode (true/false)",                      "consoleCommandSetDebug",         self)
    addConsoleCommand("IncomeTestPayment",       "Test payment system",                                 "consoleCommandTestPayment",      self)
    addConsoleCommand("IncomeShowSettings",      "Show current settings",                               "consoleCommandShowSettings",     self)
    addConsoleCommand("IncomeResetSettings",     "Reset all settings to defaults; add 'confirm' to apply", "consoleCommandResetSettings", self)
    addConsoleCommand("IncomeHistory",           "Show last 10 payment records",                        "consoleCommandHistory",          self)
    addConsoleCommand("IncomeNext",              "Show when the next payment fires",                    "consoleCommandNext",             self)
    addConsoleCommand("IncomeToggleHUD",         "Show/hide the income HUD overlay (true/false)",       "consoleCommandToggleHUD",        self)
    addConsoleCommand("IncomeSetExperimental",   "Enable/disable experimental systems (true/false)",     "consoleCommandSetExperimental",  self)
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
    print("IncomeSetPayMode 1|2 [confirm] - Hourly / Daily; shows the result, applies only with 'confirm'")
    print("IncomeSetNotifications t|f    - Toggle notifications")
    print("IncomeSetCustomAmount <n>     - Amount per payment, 0 to 999999 (0 = difficulty), digits only")
    print("IncomeSetDebug true|false     - Toggle debug logging")
    print("IncomeTestPayment             - Trigger $1 test payment")
    print("IncomeShowSettings            - Show all current settings")
    print("IncomeResetSettings [confirm] - Lists every default; resets only with 'confirm'")
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

-- IM-6: the pay mode, the amount and a full Reset go through the host's income
-- schedule (IncomeSchedule): one validator, a preview before anything changes, and the
-- live payout markers rebased on the host. On a dedicated server this console is the
-- server actor; on a client the command asks the host and prints its answer when it
-- arrives. Without the literal word `confirm`, a mode change or a Reset only shows what
-- would happen.

SettingsGUI.SCHEDULE_REFUSAL = {
    NOT_ADMIN         = "Only a server administrator can change the income schedule.",
    UNKNOWN_OPERATION = "Unknown request.",
    UNKNOWN_PAY_MODE  = "Invalid pay mode. Use 1 (Hourly) or 2 (Daily).",
    NOT_WHOLE_NUMBER  = "Not a whole number. Use digits only, for example 5000 (no sign, decimal point or exponent).",
    OUT_OF_RANGE      = "Out of range. Use 0 to 999999 (0 uses the difficulty default).",
    STALE_PREVIEW     = "The schedule changed on the host meanwhile. Run the command again.",
    CONFIRM_REQUIRED  = "Not confirmed.",
}

local function money(v)
    if v == nil then return "not available" end
    return string.format("$%d", math.floor(v))
end

--- The consequence of a schedule view, in plain lines.
function SettingsGUI.describeSchedule(view)
    local lines = {}
    if view == nil or view.paymentState == "WAITING" then
        lines[#lines + 1] = "Waiting for the host's income settings."
        return lines
    end
    local hourly = view.unit == "PER_HOUR"
    lines[#lines + 1] = hourly and "Pay mode: Hourly, one payment every in-game hour"
                                or "Pay mode: Daily, one payment every in-game day"
    if view.usesDifficultyDefault then
        lines[#lines + 1] = string.format("Amount: %s per payment (the difficulty default)", money(view.payment))
    else
        lines[#lines + 1] = string.format("Amount: %s per payment", money(view.payment))
    end
    if view.legacyOverCap then
        lines[#lines + 1] = "The saved amount is above 999999 and is kept exactly until you set a new one."
    end
    lines[#lines + 1] = string.format("Next payment with the current seasonal adjustment: %s", money(view.paymentThisSeason))
    if view.paymentState == "UNAVAILABLE" then
        lines[#lines + 1] = "Month estimate: not available (the month length is not known)"
    else
        local prefix = view.paymentState == "DISABLED" and "If income were enabled, a" or "A"
        lines[#lines + 1] = string.format("%s full %d-day month pays %d times, about %s gross before any Emergency Loan repayment",
            prefix, view.daysThisMonth or 0, view.paymentsThisMonth or 0, money(view.monthEstimate))
    end
    lines[#lines + 1] = "The amount applies to every active farm. Nothing is paid at the moment of a change."
    return lines
end

--- Run `ask(done)` against the host; `done(text)` collects the answer. On the host the
--- answer is ready before this returns and becomes the command's result; on a client
--- it prints when it arrives.
local function answer(ask)
    local text
    local sync = true
    ask(function(t)
        if sync then text = t else print(t) end
    end)
    sync = false
    if text ~= nil then return text end
    return "Asked the host; the answer prints here when it arrives."
end

local function refusal(reply)
    local reason = SettingsGUI.SCHEDULE_REFUSAL[reply and reply.status] or ("Refused: " .. tostring(reply and reply.status))
    return reason .. " Nothing changed."
end

function SettingsGUI:consoleCommandSetPayMode(mode, confirmWord)
    local mgr = g_IncomeManager
    if not (mgr and mgr.requestIncomeSchedule) then return "Error: Income Mod not initialized" end
    local payMode = tonumber(mode)
    if payMode == nil or payMode ~= math.floor(payMode) or payMode < 0 or payMode > 255 then payMode = 255 end
    local OP = IncomeSchedule.OP
    return answer(function(done)
        mgr:requestIncomeSchedule(OP.PREVIEW, "", payMode, 0, false, function(preview)
            if preview.status ~= "OK" then done(refusal(preview)) return end
            local text = table.concat(SettingsGUI.describeSchedule(preview.view), "\n")
            if confirmWord ~= "confirm" then
                done(text .. string.format("\nNothing changed. To apply: IncomeSetPayMode %d confirm", payMode))
                return
            end
            mgr:requestIncomeSchedule(OP.APPLY, "", payMode, preview.revision, false, function(applied)
                if applied.status ~= "OK" then done(refusal(applied)) return end
                done("Applied.\n" .. table.concat(SettingsGUI.describeSchedule(applied.view), "\n"))
            end)
        end)
    end)
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
    local mgr = g_IncomeManager
    if not (mgr and mgr.requestIncomeSchedule) then return "Error: Income Mod not initialized" end
    if amount == nil or amount == "" then
        return "Usage: IncomeSetCustomAmount <amount>, 0 to 999999 (0 uses the difficulty default)"
    end
    local OP = IncomeSchedule.OP
    return answer(function(done)
        mgr:requestIncomeSchedule(OP.PREVIEW, amount, 0, 0, false, function(preview)
            if preview.status ~= "OK" then done(refusal(preview)) return end
            mgr:requestIncomeSchedule(OP.APPLY, amount, 0, preview.revision, false, function(applied)
                if applied.status ~= "OK" then done(refusal(applied)) return end
                done("Applied.\n" .. table.concat(SettingsGUI.describeSchedule(applied.view), "\n"))
            end)
        end)
    end)
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
-- Experimental Systems (release gate opt-in)
-- =========================================================

function SettingsGUI:consoleCommandSetExperimental(value)
    if value == nil then
        return "Usage: IncomeSetExperimental true|false"
    end
    local v = value:lower()
    if v ~= "true" and v ~= "false" then
        return "Invalid value. Use 'true' or 'false'"
    end
    if g_IncomeManager and g_IncomeManager.settings then
        local on = (v == "true")
        g_IncomeManager.settings.experimentalSystems = on
        g_IncomeManager.settings:save()
        return string.format("Experimental systems %s", on and "enabled (at your own risk)" or "disabled")
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

SettingsGUI.RESET_LINES = {
    "Income on", "Difficulty: Normal", "Pay mode: Hourly", "Multiplier: 1x",
    "Amount: the difficulty default", "Seasonal effects: off", "Notifications: on",
    "HUD: on", "Debug: off", "Experimental systems: off",
}

function SettingsGUI:consoleCommandResetSettings(confirmWord)
    local mgr = g_IncomeManager
    if not (mgr and mgr.requestIncomeSchedule) then return "Error: Income Mod not initialized" end
    local OP = IncomeSchedule.OP
    return answer(function(done)
        mgr:requestIncomeSchedule(OP.RESET_PREVIEW, "", 0, 0, false, function(preview)
            if preview.status ~= "OK" then done(refusal(preview)) return end
            local text = "A full Reset restores: " .. table.concat(SettingsGUI.RESET_LINES, ", ") .. ".\nAfterwards:\n"
                .. table.concat(SettingsGUI.describeSchedule(preview.view), "\n")
            if confirmWord ~= "confirm" then
                done(text .. "\nNothing changed. To apply: IncomeResetSettings confirm")
                return
            end
            mgr:requestIncomeSchedule(OP.RESET_APPLY, "", 0, preview.revision, true, function(applied)
                if applied.status ~= "OK" then done(refusal(applied)) return end
                done("Income Mod settings reset to defaults.\n" .. table.concat(SettingsGUI.describeSchedule(applied.view), "\n"))
            end)
        end)
    end)
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
