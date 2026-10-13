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

---@class SettingsUI
SettingsUI = SettingsUI or {}
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

    -- Pay Mode: Hourly / Daily. IM-6: the host previews the change, the player
    -- confirms, and the host applies it; the option never writes the mode itself.
    local payModeOpt = UIHelper.createMultiOption(
        layout, "im_paymode", "im_paymode",
        { UIHelper.getText("im_paymode_1"), UIHelper.getText("im_paymode_2") },
        self:acceptedPayMode() or Settings.PAY_MODE_HOURLY,
        function(val)
            self:onPayModeSelected(val)
        end
    )
    -- A client that has no host view yet cannot choose: the option waits, greyed.
    if payModeOpt ~= nil and payModeOpt.setDisabled ~= nil then
        payModeOpt:setDisabled(self:acceptedPayMode() == nil)
    end

    -- IM-6 typed amount control, LOCKED behind im6_income_schedule (brief 3.4, 3.7). Any
    -- arrow press opens the typed entry; the host previews, the player confirms.
    local amountOpt = nil
    if IncomeSchedule.explanationReleased() then
        amountOpt = UIHelper.createMultiOption(
            layout, "im6_amount", "im6_amount",
            { self:acceptedAmountText() },
            1,
            function()
                self:onAmountSelected()
            end
        )
    end

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
    self.amountOption        = amountOpt
    self:refreshAmountOption()
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
    local acceptedMode = self:acceptedPayMode()
    if acceptedMode ~= nil then setMulti(self.payModeOption, acceptedMode) end
    if self.payModeOption ~= nil and self.payModeOption.setDisabled ~= nil then
        self.payModeOption:setDisabled(acceptedMode == nil)
    end
    self:refreshAmountOption()
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
                -- IM-6: the host previews every default, the player confirms, the host
                -- resets (and rebases the live payout markers).
                if g_IncomeManager and g_IncomeManager.settingsUI then
                    g_IncomeManager.settingsUI:onResetSelected()
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

-- =========================================================
-- IM-6: the host's schedule behind the Esc pay mode and Reset
-- =========================================================

local function text(key, fallback)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return fallback or key
end

local function money(v)
    if v == nil then return "--" end
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        return g_i18n:formatMoney(v, 0, true, true)
    end
    return string.format("$%d", math.floor(v))
end

--- The mode the host accepted, from the host's view; nil on a client still waiting
--- for it (never this machine's own setting).
function SettingsUI:acceptedPayMode()
    local mgr = g_IncomeManager
    local view = mgr ~= nil and mgr.getIncomeScheduleView ~= nil and mgr:getIncomeScheduleView() or nil
    if view == nil or view.unit == nil then return nil end
    return view.unit == "PER_DAY" and Settings.PAY_MODE_DAILY or Settings.PAY_MODE_HOURLY
end

--- The consequence of a view, in the player's language, one line per fact.
function SettingsUI.describeSchedule(view)
    if view == nil or view.paymentState == "WAITING" then
        return text("im6_waiting", "Waiting for the host's income settings.")
    end
    -- The disabled note, the month at this rate and the every-farm line are the same
    -- lines the gated readers show (IncomeSchedule.explanationLines); the confirm always
    -- shows them, since the Esc mode change and Reset are active in every build.
    local explanation = IncomeSchedule.explanationLines(view)
    local lines = {}
    if view.paymentState == "DISABLED" then
        lines[#lines + 1] = table.remove(explanation, 1)
    end
    if view.unit == "PER_DAY" then
        lines[#lines + 1] = text("im6_line_daily", "Pay mode: Daily, one payment every in-game day.")
    else
        lines[#lines + 1] = text("im6_line_hourly", "Pay mode: Hourly, one payment every in-game hour.")
    end
    if view.usesDifficultyDefault then
        lines[#lines + 1] = string.format(text("im6_line_amount_default", "Amount per payment: %s (the difficulty default)."), money(view.payment))
    else
        lines[#lines + 1] = string.format(text("im6_line_amount", "Amount per payment: %s."), money(view.payment))
    end
    if view.legacyOverCap then
        lines[#lines + 1] = text("im6_line_legacy", "The saved amount is above 999999 and is kept exactly until a new amount is set.")
    end
    lines[#lines + 1] = string.format(text("im6_line_next", "Next payment with the current seasonal adjustment: %s."), money(view.paymentThisSeason))
    for _, line in ipairs(explanation) do lines[#lines + 1] = line end
    return table.concat(lines, "\n")
end

--- A refused request: say why. Nothing changed on the host.
function SettingsUI.showRefusal(reply)
    local status = reply ~= nil and reply.status or "UNAVAILABLE"
    local msg
    if status == "NOT_ADMIN" then
        msg = text("im6_refused_not_admin", "Only a server administrator can change the income schedule. Nothing changed.")
    elseif status == "STALE_PREVIEW" then
        msg = text("im6_refused_stale", "The schedule changed on the host meanwhile. Nothing changed; please try again.")
    elseif status == "NOT_WHOLE_NUMBER" then
        msg = text("im6_refused_not_whole", "Not a whole number. Use digits only, for example 5000. Nothing changed.")
    elseif status == "OUT_OF_RANGE" then
        msg = text("im6_refused_out_of_range", "Out of range. Use 0 to 999999; 0 uses the difficulty default. Nothing changed.")
    else
        msg = string.format(text("im6_refused", "The host refused the change (%s). Nothing changed."), tostring(status))
    end
    if InfoDialog ~= nil and InfoDialog.show ~= nil then InfoDialog.show(msg) end
end

--- The player picked a pay mode in Esc. Nothing changes until the host has previewed
--- it and the player has confirmed the consequence.
function SettingsUI:onPayModeSelected(mode)
    local mgr = g_IncomeManager
    if mgr == nil or mgr.requestIncomeSchedule == nil then self:refreshUI() return end
    local accepted = self:acceptedPayMode()
    if accepted == nil then self:refreshUI() return end
    if mode == accepted then return end
    local OP = IncomeSchedule.OP
    mgr:requestIncomeSchedule(OP.PREVIEW, "", mode, 0, false, function(preview)
        if preview.status ~= "OK" then
            SettingsUI.showRefusal(preview)
            self:refreshUI()
            return
        end
        YesNoDialog.show(function(yes)
            if yes then
                mgr:requestIncomeSchedule(OP.APPLY, "", mode, preview.revision, false, function(applied)
                    if applied.status ~= "OK" then SettingsUI.showRefusal(applied) end
                    self:refreshUI()
                end)
            else
                self:refreshUI()
            end
        end, nil,
        SettingsUI.describeSchedule(preview.view) .. "\n\n" .. text("im6_mode_question", "Change the pay mode?"),
        text("im6_title", "Income schedule"))
    end)
end

--- The player pressed Reset in Esc. The host lists every default; the player confirms.
function SettingsUI:onResetSelected()
    local mgr = g_IncomeManager
    if mgr == nil or mgr.requestIncomeSchedule == nil then return end
    local OP = IncomeSchedule.OP
    mgr:requestIncomeSchedule(OP.RESET_PREVIEW, "", 0, 0, false, function(preview)
        if preview.status ~= "OK" then
            SettingsUI.showRefusal(preview)
            return
        end
        YesNoDialog.show(function(yes)
            if not yes then return end
            mgr:requestIncomeSchedule(OP.RESET_APPLY, "", 0, preview.revision, true, function(applied)
                if applied.status ~= "OK" then SettingsUI.showRefusal(applied) end
                self:refreshUI()
            end)
        end, nil,
        text("im6_reset_list", "A full Reset returns every Income Mod setting to its default: income on, Normal difficulty, Hourly, 1x, the difficulty amount, seasonal effects off, notifications on, HUD on, debug off, experimental systems off.")
            .. "\n\n" .. text("im6_reset_after", "Afterwards:") .. "\n" .. SettingsUI.describeSchedule(preview.view)
            .. "\n\n" .. text("im6_reset_question", "Reset every setting now?"),
        text("im6_title", "Income schedule"))
    end)
end

-- =========================================================
-- IM-6: the typed amount (LOCKED behind im6_income_schedule)
-- =========================================================

--- The saved amount exactly as the host holds it (a legacy value above the cap too),
--- or the difficulty default's payment when the amount is 0.
function SettingsUI:acceptedAmountText()
    local view = IncomeSchedule.readerView()
    if view.paymentState == IncomeSchedule.STATE.WAITING or view.amount == nil then return "--" end
    if view.usesDifficultyDefault then
        return string.format(text("im6_amount_value_default", "%s (difficulty default)"), money(view.payment))
    end
    return money(view.amount)
end

--- The amount row follows the host: its value, and usable only with a host view and
--- when the host did not say this player may not edit (the host decides regardless).
function SettingsUI:refreshAmountOption()
    local opt = self.amountOption
    if opt == nil then return end
    if opt.setTexts ~= nil then opt:setTexts({ self:acceptedAmountText() }) end
    local view = IncomeSchedule.readerView()
    local usable = view.paymentState ~= IncomeSchedule.STATE.WAITING and view.canEdit ~= false
    if opt.setDisabled ~= nil then opt:setDisabled(not usable) end
end

--- Type a whole number; the host previews it; the player confirms the consequence; the
--- host applies it. The entry starts from the host's exact amount and holds any legacy
--- value, so nothing is lowered unasked.
function SettingsUI:onAmountSelected()
    local mgr = g_IncomeManager
    if mgr == nil or mgr.requestIncomeSchedule == nil or not IncomeSchedule.explanationReleased() then return end
    local view = IncomeSchedule.readerView()
    if view.paymentState == IncomeSchedule.STATE.WAITING or view.canEdit == false then
        self:refreshUI()
        return
    end
    if TextInputDialog == nil or TextInputDialog.show == nil then return end
    local current = view.amount ~= nil and tostring(math.floor(view.amount)) or ""
    local prompt = text("im6_amount_prompt", "Amount per payment: a whole number from 0 to 999999 (0 uses the difficulty default).")
    TextInputDialog.show(function(entered, clickOk)
        if clickOk ~= true then return end
        self:previewAmount(tostring(entered or ""), view)
    end, nil, current, prompt, prompt, IncomeSchedule.MAX_TEXT, text("button_ok", "OK"))
end

function SettingsUI:previewAmount(amountText, before)
    local mgr = g_IncomeManager
    local OP = IncomeSchedule.OP
    mgr:requestIncomeSchedule(OP.PREVIEW, amountText, 0, 0, false, function(preview)
        if preview.status ~= "OK" then
            SettingsUI.showRefusal(preview)
            self:refreshUI()
            return
        end
        local body = SettingsUI.describeSchedule(preview.view)
        if before ~= nil and before.legacyOverCap and preview.view ~= nil and preview.view.amount ~= before.amount then
            body = text("im6_legacy_permanent", "The saved amount is above 999999. Once a new amount is set, it cannot be set back above 999999.")
                .. "\n\n" .. body
        end
        YesNoDialog.show(function(yes)
            if not yes then
                self:refreshUI()
                return
            end
            mgr:requestIncomeSchedule(OP.APPLY, amountText, 0, preview.revision, false, function(applied)
                if applied.status ~= "OK" then SettingsUI.showRefusal(applied) end
                self:refreshUI()
            end)
        end, nil,
        body .. "\n\n" .. text("im6_amount_question", "Set this amount per payment?"),
        text("im6_title", "Income schedule"))
    end)
end
