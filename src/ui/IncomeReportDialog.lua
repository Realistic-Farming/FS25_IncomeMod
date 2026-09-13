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
        return
    end

    local function money(v) return self:formatLoanMoney(v) end
    local outstanding = view.outstanding or 0
    if outstanding and outstanding > 0 then
        local principal = view.principal or outstanding
        local interest  = view.accruedInterest or (outstanding - (view.principal or outstanding))
        local ratePct   = (view.effectiveMonthlyRate or 0) * 100
        statusEl:setText(string.format("%s %s   (%s %s · %s %s)   %.1f%%/mo",
            g_i18n:getText("im_loan_outstanding"), money(outstanding),
            g_i18n:getText("im_loan_principal"), money(principal),
            g_i18n:getText("im_loan_interest"), money(interest), ratePct))
    elseif view.canBorrow == true then
        statusEl:setText(string.format("%s %s",
            g_i18n:getText("im_loan_offer_available"), money(view.offer)))
    else
        statusEl:setText(g_i18n:getText("im_loan_none"))
    end
    setBtn(borrowBtn, view.canBorrow == true)
    setBtn(payoffBtn, view.canRepay == true and outstanding > 0)
    setBtn(amountBtn, view.canRepay == true and outstanding > 0)
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
    local mgr = g_IncomeManager
    local sent = mgr:uiManualRepayQuote(enteredText, function(reply) self:onRepayQuote(reply) end)
    if sent ~= true then self:onRepayQuote(nil) end
end

--- Step 3: confirm the SERVER's amount. When the host bound less than was asked for
--- (only this much cash or this much debt left), the confirmation says so rather than
--- quietly moving a different sum.
function IncomeReportDialog:onRepayQuote(reply)
    local token = type(reply) == "table" and reply.token or nil
    local quoted = type(reply) == "table" and reply.quoteAmount or nil
    if token == nil or token == "" or quoted == nil or quoted <= 0 then
        self:setLoanPending(false)
        self:showLoanReason(reply)
        self:updateDisplay()
        return
    end

    local requested = self.loanRequestedAmount
    local message = string.format("%s %s", loanText("im_loan_confirm_text"), self:formatLoanMoney(quoted))
    if requested ~= nil and quoted < requested then
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
    end, nil, message, loanText("im_loan_confirm_title"))
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

-- [C3/F130] Borrow / payoff. Routed through the owner (server re-checks manager rights,
-- acting farm, cash and the quote revision before any money moves). The button is the
-- player's explicit confirmation of intent; the host re-quotes and accepts atomically.
function IncomeReportDialog:onClickBorrow()
    local mgr = g_IncomeManager
    if mgr and mgr.uiBorrow then mgr:uiBorrow() end
    self:updateDisplay()
end

function IncomeReportDialog:onClickPayoff()
    local mgr = g_IncomeManager
    if mgr and mgr.uiPayoff then mgr:uiPayoff() end
    self:updateDisplay()
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
    local mgr = g_IncomeManager
    if mgr ~= nil and mgr.clearEmergencyLoanUiState ~= nil then mgr:clearEmergencyLoanUiState() end
end
