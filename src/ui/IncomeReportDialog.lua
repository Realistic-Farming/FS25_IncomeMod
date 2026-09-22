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

---@class IncomeReportDialog
IncomeReportDialog = IncomeReportDialog or {}
local IncomeReportDialog_mt = Class(IncomeReportDialog, ScreenElement)

IncomeReportDialog.MAX_ROWS = 10
IncomeReportDialog.instance = nil
IncomeReportDialog.xmlPath  = nil

-- =========================================================
-- Singleton Constructor
-- =========================================================

function IncomeReportDialog.getInstance(modDirectory)
    if IncomeReportDialog.instance == nil then
        if IncomeReportDialog.xmlPath == nil then
            IncomeReportDialog.xmlPath = modDirectory .. "gui/IncomeReportDialog.xml"
        end

        IncomeReportDialog.instance = IncomeReportDialog.new()
        g_gui:loadGui(IncomeReportDialog.xmlPath, "IncomeReportDialog", IncomeReportDialog.instance)
    end

    return IncomeReportDialog.instance
end

function IncomeReportDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or IncomeReportDialog_mt)

    self.histRows    = {}
    self.isBackAllowed = true

    return self
end

-- =========================================================
-- Lifecycle
-- =========================================================

function IncomeReportDialog:onCreate()
    -- Cache all 10 history row element groups
    for i = 0, IncomeReportDialog.MAX_ROWS - 1 do
        local rowId = "histRow" .. i
        self.histRows[i] = {
            row    = self[rowId],
            day    = self[rowId .. "Day"],
            time   = self[rowId .. "Time"],
            payType = self[rowId .. "Type"],
            amount = self[rowId .. "Amount"],
            season = self[rowId .. "Season"],
        }
    end
end

--- Show the dialog if no other GUI is open.
function IncomeReportDialog:show()
    if g_gui.currentGui ~= nil then return end

    if not g_IncomeManager or not g_IncomeManager.incomeSystem then
        Logging.warning("im: IncomeReportDialog:show() — income system not available")
        return
    end

    self:updateDisplay()
    g_gui:showDialog("IncomeReportDialog")
end

--- Called by the FS25 GUI system when the dialog becomes visible (maps to XML onOpen="onOpen").
--- Refreshes data so the report is always current, even if the dialog is opened by means
--- other than the show() helper (e.g., direct g_gui:showDialog calls from other mods).
function IncomeReportDialog:onOpen()
    IncomeReportDialog:superClass().onOpen(self)
    if g_IncomeManager and g_IncomeManager.incomeSystem then
        self:updateDisplay()
        self:requestLoanView()
    end
end

--- [C3/F130] Ask the host for this farm's loan view. On SP / a listen host the manager
--- answers locally and the band is already current; on a pure client the VIEW request
--- goes over the owner Event and onLoanViewArrived redraws the band when it returns.
--- Without this a client only ever saw "no loan" because nothing asked.
function IncomeReportDialog:requestLoanView()
    local mgr = g_IncomeManager
    if mgr == nil or mgr.refreshEmergencyLoanView == nil then return end
    pcall(function() mgr:refreshEmergencyLoanView() end)
end

--- Called by the manager when an authoritative reply lands while this report is open.
function IncomeReportDialog:onLoanViewArrived()
    if self.isOpen == false then return end
    self:updateLoanSection()
end

-- =========================================================
-- Display Update
-- =========================================================

function IncomeReportDialog:updateDisplay()
    self:updateSummary()
    self:updateStats()
    self:updateHistoryRows()
    self:updateLoanSection()
end

--- [C3/F130] Populate the emergency-loan band + borrow/payoff buttons from the owner
--- view. On a listen host the view is the rich authoritative one; on a pure client it
--- is the compact cached reply (outstanding/offer/canBorrow/canRepay), so fields are
--- guarded. Buttons show only for a farm manager with a valid borrow/repay decision.
function IncomeReportDialog:updateLoanSection()
    local statusEl  = self.loanStatusText
    if statusEl == nil then return end
    local borrowBtn = self.loanBorrowButton
    local payoffBtn = self.loanPayoffButton
    local amountBtn = self.loanRepayAmountButton
    local pending   = self.loanPending == true
    local function setBtn(btn, vis)
        if btn == nil then return end
        if btn.setVisible then btn:setVisible(vis == true) end
        -- A request in flight disables every money action until the host answers, so a
        -- second click cannot open a second confirmation over the same debt.
        if btn.setDisabled then btn:setDisabled(pending) end
    end

    local mgr = g_IncomeManager
    local view = (mgr and mgr.getEmergencyLoanView) and mgr:getEmergencyLoanView(nil) or nil
    if type(view) ~= "table" then
        statusEl:setText(g_i18n:getText("im_loan_none"))
        setBtn(borrowBtn, false); setBtn(payoffBtn, false); setBtn(amountBtn, false)
        self:updateForecastLines(nil)
        return
    end

    local function money(v) return self:formatLoanMoney(v) end
    -- RSF-F309 item 1: an UNKNOWN amount is nil here (the wire carries "" for it,
    -- parseAmount keeps it nil), and nil is "unavailable", never 0. A pure client
    -- mid-load used to read "no emergency loan" and see a Pay Off button keyed on
    -- a zero it had invented. No money button keys on an unknown amount.
    local outstanding = view.outstanding
    local known = type(outstanding) == "number"
    local offerKnown = type(view.offer) == "number"
    if known and outstanding > 0 then
        local principal = view.principal or outstanding
        local interest  = view.accruedInterest or (outstanding - (view.principal or outstanding))
        local ratePct   = (view.effectiveMonthlyRate or 0) * 100
        statusEl:setText(string.format("%s %s   (%s %s · %s %s)   %.1f%%/mo",
            g_i18n:getText("im_loan_outstanding"), money(outstanding),
            g_i18n:getText("im_loan_principal"), money(principal),
            g_i18n:getText("im_loan_interest"), money(interest), ratePct))
    elseif not known then
        statusEl:setText(g_i18n:getText("im_loan_fc_unavailable"))
    elseif view.canBorrow == true and offerKnown then
        statusEl:setText(string.format("%s %s%s",
            g_i18n:getText("im_loan_offer_available"), money(view.offer),
            self:formatWorkingCashBasis(view)))
    else
        statusEl:setText(g_i18n:getText("im_loan_none"))
    end
    self:updateForecastLines(view)
    setBtn(borrowBtn, view.canBorrow == true and offerKnown)
    setBtn(payoffBtn, view.canRepay == true and known and outstanding > 0)
    setBtn(amountBtn, view.canRepay == true and known and outstanding > 0)
end

-- =========================================================
-- [C3/F130] Forecast rows of the loan band (brief section 2, minimum surface)
-- =========================================================
-- The band shows what the offer was computed from: expected regular income, known
-- bills, the separately labelled recent-spending estimate, the projected lowest cash
-- balance (negative = shortage warning), the forecast status (PARTIAL stays visible
-- even when the minimum is non-negative), the horizon length and the localized list of
-- inputs the forecast could not cover. nil is shown as "--", never as a confident zero.
-- Both the host's rich view and a pure client's cached reply carry these field names.

IncomeReportDialog.UNKNOWN_TEXT = "--"

local function fcText(key) return g_i18n and g_i18n:getText(key) or key end

--- Localize one missingInputs code through im_loan_miss_<code>; an unknown code shows
--- itself so a new reason is never silently hidden.
function IncomeReportDialog.missingInputText(code)
    local key = "im_loan_miss_" .. tostring(code):lower()
    if g_i18n == nil then return tostring(code) end
    if g_i18n.hasText ~= nil and not g_i18n:hasText(key) then return tostring(code) end
    local text = g_i18n:getText(key)
    if text == nil or text == key then return tostring(code) end
    return text
end

--- Sum of a copied cost list, or nil when the list itself is unknown.
function IncomeReportDialog.sumCosts(list)
    if type(list) ~= "table" then return nil end
    local total = 0
    for _, e in ipairs(list) do total = total + (tonumber(type(e) == "table" and e.amount or nil) or 0) end
    return total
end

--- " (Working cash: ...)" for an offer line, or "" when the basis is unknown.
function IncomeReportDialog:formatWorkingCashBasis(view)
    local basis = type(view) == "table" and view.workingCashBasis or nil
    if basis == "HALF_PERIOD_GROSS" then
        return string.format(" (%s: %s)", fcText("im_loan_fc_basis"), fcText("im_loan_fc_basis_half"))
    elseif basis == "FALLBACK_10000" then
        return string.format(" (%s: %s)", fcText("im_loan_fc_basis"), fcText("im_loan_fc_basis_fallback"))
    end
    return ""
end

--- Pure: build the three forecast rows from a view. Returns
--- { income = text, balance = text, missing = text, shortage = bool, status = code }.
--- A nil view yields empty rows; unknown numbers render as UNKNOWN_TEXT.
function IncomeReportDialog:buildForecastLines(view)
    local U = IncomeReportDialog.UNKNOWN_TEXT
    if type(view) ~= "table" then
        return { income = "", balance = "", missing = "", shortage = false, status = nil }
    end
    local function money(v)
        if type(v) ~= "number" or v ~= v then return U end
        return self:formatLoanMoney(v)
    end

    -- Row 1: expected regular income (gross; net after the automatic share when a debt
    -- makes them differ), known bills and the separately labelled estimate.
    local gross, net = view.expectedGrossIncome, view.expectedNetIncome
    local incomeText = money(gross)
    if type(gross) == "number" and type(net) == "number" and net ~= gross then
        incomeText = string.format("%s (%s %s)", incomeText, fcText("im_loan_fc_net"), money(net))
    end
    local income = string.format("%s: %s   %s: %s   %s: %s",
        fcText("im_loan_fc_income"), incomeText,
        fcText("im_loan_fc_bills"), money(IncomeReportDialog.sumCosts(view.knownCosts)),
        fcText("im_loan_fc_estimates"), money(IncomeReportDialog.sumCosts(view.estimatedCosts)))

    -- Row 2: projected lowest balance (+ shortage warning), status, horizon.
    local minimum = view.minimumBalance
    local shortage = type(minimum) == "number" and minimum < 0
    local status = view.forecastStatus
    local statusKey = "im_loan_fc_unavailable"
    if status == "OK" then statusKey = "im_loan_fc_ok"
    elseif status == "PARTIAL" then statusKey = "im_loan_fc_partial" end
    local days = U
    local asOfDay = type(view.asOf) == "table" and tonumber(view.asOf.monotonicDay) or nil
    local endDay  = type(view.horizonEnd) == "table" and tonumber(view.horizonEnd.monotonicDay) or nil
    if asOfDay ~= nil and endDay ~= nil and endDay >= asOfDay then
        local ok, text = pcall(string.format, fcText("im_loan_fc_days"), math.floor(endDay - asOfDay + 0.5))
        days = ok and text or tostring(math.floor(endDay - asOfDay + 0.5))
    end
    local balance = string.format("%s: %s%s   %s: %s   %s: %s",
        fcText("im_loan_fc_minimum"), money(minimum),
        shortage and (" (" .. fcText("im_loan_fc_shortage") .. ")") or "",
        fcText("im_loan_fc_status"), fcText(statusKey),
        fcText("im_loan_fc_horizon"), days)

    -- Row 3: coverage the forecast could not model, localized per code.
    local missing = ""
    local codes = view.missingInputs
    if type(codes) == "table" and #codes > 0 then
        local parts = {}
        for _, code in ipairs(codes) do parts[#parts + 1] = IncomeReportDialog.missingInputText(code) end
        missing = string.format("%s: %s", fcText("im_loan_fc_missing"), table.concat(parts, "; "))
    end

    return { income = income, balance = balance, missing = missing, shortage = shortage, status = status }
end

--- Push the built rows into the band's Text elements (each optional so an older XML
--- without the rows still renders the status line).
function IncomeReportDialog:updateForecastLines(view)
    local rows = self:buildForecastLines(view)
    local function put(el, text)
        if el ~= nil and el.setText ~= nil then el:setText(text or "") end
    end
    put(self.loanForecastIncomeText, rows.income)
    put(self.loanForecastBalanceText, rows.balance)
    put(self.loanForecastMissingText, rows.missing)
    local el = self.loanForecastBalanceText
    if el ~= nil and el.setTextColor ~= nil then
        if rows.shortage then el:setTextColor(1.0, 0.45, 0.4, 1) else el:setTextColor(0.85, 0.85, 0.85, 1) end
    end
    self.loanForecastRows = rows
end

-- =========================================================
-- [C3/F130] Chosen-amount repayment
-- =========================================================
-- The player path the host brief requires: type an amount, see the amount the SERVER
-- bound after clamping it to real cash and debt, and confirm that exact sum. The typed
-- value is never a money instruction; every step below re-enters the owner controller,
-- which re-checks rights, farm, cash and the debt revision before anything moves.

--- Gate every money action while one request is in flight.
function IncomeReportDialog:setLoanPending(pending)
    self.loanPending = pending == true
    self:updateLoanSection()
end

local function loanText(key) return g_i18n and g_i18n:getText(key) or key end

function IncomeReportDialog:formatLoanMoney(value)
    if g_i18n and g_i18n.formatMoney then return g_i18n:formatMoney(value or 0, 0, true, true) end
    return "$" .. tostring(math.floor((value or 0) + 0.5))
end

--- Step 1: ask for the amount. Uses the closure form of TextInputDialog (target nil),
--- which is the branch that hands the callback the real entered text.
function IncomeReportDialog:onClickRepayAmount()
    if self.loanPending then return end
    local mgr = g_IncomeManager
    if mgr == nil or mgr.uiManualRepayQuote == nil then return end
    if TextInputDialog == nil or TextInputDialog.show == nil then return end

    local maxChars = (EmergencyLoanController and EmergencyLoanController.MAX_AMOUNT_LEN) or 32
    TextInputDialog.show(function(enteredText, clickOk)
        if clickOk ~= true then return end
        self:onRepayAmountEntered(enteredText)
    end, nil, "", loanText("im_loan_amount_prompt"), loanText("im_loan_amount_prompt"),
        maxChars, loanText("button_ok"))
end

--- Step 2: local sanity only (the same finite decimal grammar the wire accepts), then
--- ask the host to quote it. A malformed entry is refused here instead of travelling.
function IncomeReportDialog:onRepayAmountEntered(enteredText)
    local parse = EmergencyLoanController and EmergencyLoanController.parseAmount
    local requested = parse and parse(enteredText) or nil
    if requested == nil or requested <= 0 then
        if InfoDialog and InfoDialog.show then
            InfoDialog.show(loanText("im_loan_amount_invalid"))
        end
        return
    end

    self:setLoanPending(true)
    self.loanRequestedAmount = requested
    self.loanQuoteKind = "amount"
    local mgr = g_IncomeManager
    local sent = mgr:uiManualRepayQuote(enteredText, function(reply) self:onRepayQuote(reply) end)
    if sent ~= true then self:onRepayQuote(nil) end
end

--- Step 3: confirm the SERVER's amount. When the host bound less than was asked for
--- (only this much cash or this much debt left), the confirmation says so rather than
--- quietly moving a different sum. A payoff quote confirms the exact outstanding under
--- its own wording; it has no requested amount, so it is never "clamped".
function IncomeReportDialog:onRepayQuote(reply)
    local token = type(reply) == "table" and reply.token or nil
    local quoted = type(reply) == "table" and reply.quoteAmount or nil
    if token == nil or token == "" or quoted == nil or quoted <= 0 then
        self:setLoanPending(false)
        self:showLoanReason(reply)
        self:updateDisplay()
        return
    end

    local isPayoff = self.loanQuoteKind == "payoff"
    local textKey  = isPayoff and "im_loan_payoff_confirm_text"  or "im_loan_confirm_text"
    local titleKey = isPayoff and "im_loan_payoff_confirm_title" or "im_loan_confirm_title"
    local requested = self.loanRequestedAmount
    local message = string.format("%s %s", loanText(textKey), self:formatLoanMoney(quoted))
    if not isPayoff and requested ~= nil and quoted < requested then
        message = message .. "\n" .. loanText("im_loan_confirm_clamped")
    end

    if YesNoDialog == nil or YesNoDialog.show == nil then
        self:setLoanPending(false)
        return
    end
    YesNoDialog.show(function(confirmed)
        if confirmed ~= true then
            self:setLoanPending(false)
            self:updateDisplay()
            return
        end
        self:acceptRepayQuote(token)
    end, nil, message, loanText(titleKey))
end

--- Step 4: accept exactly that quote. The token is consumed once by the host, so a
--- repeated confirmation cannot repeat a completed payment.
function IncomeReportDialog:acceptRepayQuote(token)
    local mgr = g_IncomeManager
    if mgr == nil or mgr.uiAcceptQuote == nil then
        self:setLoanPending(false)
        return
    end
    local sent = mgr:uiAcceptQuote(token, function(result) self:onRepayResult(result) end)
    if sent ~= true then self:onRepayResult(nil) end
end

--- Step 5: success is shown only on the host's acknowledgement, never on the click.
function IncomeReportDialog:onRepayResult(result)
    self.loanRequestedAmount = nil
    self.loanQuoteKind = nil
    self:setLoanPending(false)
    local status = type(result) == "table" and result.status or nil
    if status == "ACCEPTED" then
        if InfoDialog and InfoDialog.show then InfoDialog.show(loanText("im_loan_repaid")) end
    else
        self:showLoanReason(result)
    end
    self:updateDisplay()
end

--- Report why the host refused, using its own status code when it supplied one.
function IncomeReportDialog:showLoanReason(reply)
    if InfoDialog == nil or InfoDialog.show == nil then return end
    local status = type(reply) == "table" and reply.status or nil
    local key = "im_loan_repay_failed"
    if status == "INSUFFICIENT_CASH" then key = "im_loan_insufficient_cash"
    elseif status == "NOT_MANAGER" then key = "im_loan_not_manager"
    elseif status == "NO_DEBT" then key = "im_loan_no_debt"
    elseif status == "STALE_QUOTE" then key = "im_loan_stale_quote"
    elseif status == "INVALID_AMOUNT" then key = "im_loan_amount_invalid" end
    InfoDialog.show(loanText(key))
end

--- Fill the three summary rows with live settings values.
function IncomeReportDialog:updateSummary()
    local s = g_IncomeManager and g_IncomeManager.settings
    if not s then return end

    -- Row 1: Status / Mode / Difficulty
    if self.statusText then
        local label = s.enabled
            and g_i18n:getText("im_report_enabled")
            or  g_i18n:getText("im_report_disabled")
        self.statusText:setText(label)
        if s.enabled then
            self.statusText:setTextColor(0.3, 1.0, 0.3, 1)
        else
            self.statusText:setTextColor(1.0, 0.4, 0.4, 1)
        end
    end

    if self.modeText then
        self.modeText:setText(s:getPayModeName())
        self.modeText:setTextColor(0.8, 0.9, 1, 1)
    end

    if self.difficultyText then
        self.difficultyText:setText(s:getDifficultyName())
        self.difficultyText:setTextColor(0.8, 0.9, 1, 1)
    end

    -- Row 2: Amount / Multiplier / Seasonal
    if self.amountText then
        self.amountText:setText(string.format("$%d", s:getPaymentAmount()))
        self.amountText:setTextColor(0.8, 0.9, 1, 1)
    end

    if self.multiplierText then
        self.multiplierText:setText(s:getMultiplierName())
        self.multiplierText:setTextColor(0.8, 0.9, 1, 1)
    end

    if self.seasonalText then
        if s.seasonalEffects then
            self.seasonalText:setText(g_i18n:getText("im_report_enabled"))
            self.seasonalText:setTextColor(0.3, 1.0, 0.3, 1)
        else
            self.seasonalText:setText(g_i18n:getText("im_report_disabled"))
            self.seasonalText:setTextColor(0.6, 0.6, 0.6, 1)
        end
    end
end

--- Fill the stats row: total earned, average, and next payment time.
--- Note: history is a ring buffer capped at MAX_HISTORY (10) entries, so total
--- and average reflect only the most recent payments, not all-time earnings.
function IncomeReportDialog:updateStats()
    local sys = g_IncomeManager and g_IncomeManager.incomeSystem
    if not sys then return end

    local history = sys.paymentHistory or {}
    local total   = 0
    local count   = #history

    for _, entry in ipairs(history) do
        total = total + (entry.amount or 0)
    end

    if self.totalEarnedText then
        self.totalEarnedText:setText(string.format("$%d", total))
    end

    if self.avgPaymentText then
        if count > 0 then
            self.avgPaymentText:setText(string.format("$%d", math.floor(total / count)))
        else
            self.avgPaymentText:setText("--")
        end
    end

    if self.nextPaymentText then
        if sys.isInitialized and g_IncomeManager.settings.enabled then
            self.nextPaymentText:setText(sys:getNextPaymentInfo())
        else
            self.nextPaymentText:setText("--")
        end
    end
end

--- Fill history rows (most recent first).
function IncomeReportDialog:updateHistoryRows()
    local sys = g_IncomeManager and g_IncomeManager.incomeSystem
    local history = (sys and sys.paymentHistory) or {}
    local count   = #history

    local hasData = count > 0

    if self.noHistoryText then
        self.noHistoryText:setVisible(not hasData)
    end

    for i = 0, IncomeReportDialog.MAX_ROWS - 1 do
        local row = self.histRows[i]
        if row and row.row then
            -- history[1] is the most recent (inserted at front); show in that order
            local dataIndex = i + 1
            if dataIndex <= count then
                local entry = history[dataIndex]
                row.row:setVisible(true)

                if row.day then
                    row.day:setText(string.format("Day %d", entry.day or 0))
                end

                if row.time then
                    row.time:setText(string.format("%02d:00", entry.hour or 0))
                end

                if row.payType then
                    row.payType:setText(entry.payType or "?")
                end

                if row.amount then
                    row.amount:setText(string.format("$%d", entry.amount or 0))
                end

                if row.season then
                    local mult = entry.seasonMult
                    if mult and mult ~= 1.0 then
                        row.season:setText(string.format("x%.1f", mult))
                        if mult > 1.0 then
                            row.season:setTextColor(0.3, 1.0, 0.3, 1)
                        else
                            row.season:setTextColor(1.0, 0.6, 0.3, 1)
                        end
                    else
                        row.season:setText("--")
                        row.season:setTextColor(0.6, 0.6, 0.6, 1)
                    end
                end
            else
                row.row:setVisible(false)
            end
        end
    end
end

-- =========================================================
-- Button Callbacks
-- =========================================================

function IncomeReportDialog:onCloseDialog()
    g_gui:closeDialogByName("IncomeReportDialog")
end

function IncomeReportDialog:onClickBack()
    g_gui:closeDialogByName("IncomeReportDialog")
end

-- [C3/F130] Borrow. Routed through the owner (server re-checks manager rights, acting
-- farm, cash and the quote revision before any money moves). The button is the player's
-- explicit confirmation of intent; the host re-quotes and accepts atomically.
function IncomeReportDialog:onClickBorrow()
    local mgr = g_IncomeManager
    if mgr and mgr.uiBorrow then mgr:uiBorrow() end
    self:updateDisplay()
end

-- [C3/F130] Pay Off is a quote-then-confirm like the chosen amount: the host binds the
-- exact outstanding (principal + all accrued interest, which grows while the report is
-- open) and the player confirms THAT sum before it leaves the farm. A stale figure then
-- changes the confirmation instead of silently moving a different one.
function IncomeReportDialog:onClickPayoff()
    if self.loanPending then return end
    local mgr = g_IncomeManager
    if mgr == nil or mgr.uiPayoffQuote == nil then return end
    self:setLoanPending(true)
    self.loanRequestedAmount = nil
    self.loanQuoteKind = "payoff"
    local sent = mgr:uiPayoffQuote(function(reply) self:onRepayQuote(reply) end)
    if sent ~= true then self:onRepayQuote(nil) end
end

-- =========================================================
-- Input / Close Events
-- =========================================================

function IncomeReportDialog:inputEvent(action, value, eventUsed)
    eventUsed = IncomeReportDialog:superClass().inputEvent(self, action, value, eventUsed)

    if not eventUsed and action == InputAction.MENU_BACK and value > 0 then
        g_gui:closeDialogByName("IncomeReportDialog")
        eventUsed = true
    end

    return eventUsed
end

function IncomeReportDialog:onClose()
    IncomeReportDialog:superClass().onClose(self)
    -- Drop any in-flight confirmation with the dialog: a reply arriving after the
    -- report is gone must not resolve a payment nobody is looking at.
    self.loanPending = false
    self.loanRequestedAmount = nil
    self.loanQuoteKind = nil
    local mgr = g_IncomeManager
    if mgr ~= nil and mgr.clearEmergencyLoanUiState ~= nil then mgr:clearEmergencyLoanUiState() end
end
