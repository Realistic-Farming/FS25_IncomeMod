-- c3_payoff_confirm_test.lua - C3/RSF-F130: Pay Off confirms the server's exact sum.
--
-- Bound to the REAL functions: IncomeReportDialog.onClickPayoff / onRepayQuote /
-- acceptRepayQuote / onRepayResult, IncomeManager.uiPayoffQuote / uiAcceptQuote and
-- IncomeManager.handleEmergencyLoanRequest (PAYOFF_QUOTE + ACCEPT_QUOTE).
--
-- Subject: before this repair the Pay Off button called uiPayoff, which quoted and
-- accepted in one step, so the whole debt left the farm on the click with no
-- confirmation and no display of the figure being paid. The brief requires that a
-- manual payoff goes through the owner quote and an explicit confirmation of the
-- server-bound amount. resolveActor and the dialogs (YesNoDialog / InfoDialog) are
-- stubbed; render and native transport remain in-game observations.
--
--!load: src/ReleaseGate.lua, src/settings/SettingsManager.lua, src/settings/Settings.lua, src/EmergencyLoan.lua, src/EmergencyLoanEvent.lua, src/IncomeManager.lua, src/ui/IncomeReportDialog.lua

local OP = EmergencyLoanController.OP
local FARM = 7

g_currentMission.environment = { currentMonotonicDay = 100, dayTime = 64800000,
    currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 3 }

local function newLoan(principal, interest)
    local loan = EmergencyLoan.new()
    loan.settings = { difficulty = Settings.DIFFICULTY_NORMAL }
    loan.incomeSystem = { settings = { enabled = false, getPaymentAmount = function() return 0 end } }
    loan:setReadiness(EmergencyLoan.READINESS.READY)
    if principal ~= nil then
        loan.debts[FARM] = { principal = principal, accruedInterest = interest or 0,
                             drawCount = 1, active = true, revision = 3 }
    end
    return loan
end

--- Listen host with a managing player on FARM and `cash` in the bank; addMoney is
--- recorded so the bench can prove exactly what moved and when.
local function newHost(loan, cash)
    g_server = {}
    g_client = nil
    g_currentMission.getIsServer = function() return true end
    g_currentMission.getFarmId = function() return FARM end
    local moved = {}
    g_currentMission.addMoney = function(_self, amount, farmId)
        moved[#moved + 1] = { amount = amount, farmId = farmId }
    end
    g_farmManager = { getFarmById = function(_self, id) return id == FARM and { money = cash } or nil end }
    EmergencyLoanController.resolveActor = function(_connection)
        return { userId = 1, farmId = FARM, farm = { money = cash }, isManager = true }, nil
    end

    local mgr = setmetatable({}, { __index = IncomeManager })
    mgr.emergencyLoan = loan
    mgr.incomeSystem = loan.incomeSystem
    mgr._loanSessions = {}
    mgr._loanSeq = 0
    mgr.saves = 0
    mgr.saveEmergencyDebt = function(selfRef) selfRef.saves = selfRef.saves + 1 end
    g_IncomeManager = mgr
    return mgr, moved
end

local function newWidget()
    local w = {}
    function w:setVisible(v) self.visible = v end
    function w:setDisabled(v) self.disabled = v end
    function w:setText(t) self.text = t end
    return w
end

local function newDialog()
    local dlg = setmetatable({}, { __index = IncomeReportDialog })
    dlg.loanStatusText = newWidget()
    dlg.loanBorrowButton = newWidget()
    dlg.loanPayoffButton = newWidget()
    dlg.loanRepayAmountButton = newWidget()
    dlg.updateDisplay = function(selfRef) selfRef:updateLoanSection() end
    return dlg
end

--- Capture the confirmation the dialog would show instead of rendering one.
local shown
YesNoDialog = { show = function(callback, _target, text, title)
    shown = { callback = callback, text = text, title = title }
end }
local infos = {}
InfoDialog = { show = function(text) infos[#infos + 1] = text end }

-- ── clicking Pay Off quotes, shows the bound sum, and moves NOTHING yet ──────
do
    shown = nil; infos = {}
    local loan = newLoan(1000, 234.5)          -- outstanding 1234.5
    local mgr, moved = newHost(loan, 50000)
    local dlg = newDialog()

    dlg:onClickPayoff()
    T.eq("the click moves no money", #moved, 0)
    T.near("the debt is untouched by the click", loan:getOutstanding(FARM), 1234.5, 1e-6)
    T.ok("a confirmation is shown", shown ~= nil)
    T.eq("under the payoff title", shown and shown.title, "im_loan_payoff_confirm_title")
    T.ok("the confirmation names the SERVER's exact outstanding",
        shown and shown.text:find(dlg:formatLoanMoney(1234.5), 1, true) ~= nil
            and shown.text:find("im_loan_payoff_confirm_text", 1, true) ~= nil)
    T.ok("a payoff is never labelled clamped", shown and shown.text:find("im_loan_confirm_clamped", 1, true) == nil)
    T.eq("money buttons are disabled while the quote is pending", dlg.loanPayoffButton.disabled, true)

    -- Declining leaves everything as it was.
    if shown then shown.callback(false) end
    T.eq("declining moves no money", #moved, 0)
    T.near("declining leaves the debt", loan:getOutstanding(FARM), 1234.5, 1e-6)
    T.eq("declining releases the pending gate", dlg.loanPending, false)
    T.eq("declining persists nothing", mgr.saves, 0)
end

-- ── confirming moves exactly the bound sum, once ─────────────────────────────
do
    shown = nil; infos = {}
    local loan = newLoan(1000, 234.5)
    local mgr, moved = newHost(loan, 50000)
    local dlg = newDialog()

    dlg:onClickPayoff()
    local cb = shown and shown.callback or function() end
    cb(true)
    T.eq("confirming makes exactly one money call", #moved, 1)
    T.near("for the exact outstanding, principal plus interest", moved[1].amount, -1234.5, 1e-6)
    T.eq("on the acting farm", moved[1].farmId, FARM)
    T.near("the debt is cleared to the last fraction", loan:getOutstanding(FARM), 0, 1e-9)
    T.eq("the payoff is persisted once", mgr.saves, 1)
    T.eq("success is reported from the host status", infos[#infos], "im_loan_repaid")
    T.eq("the pending gate is released", dlg.loanPending, false)
    T.eq("the quote kind is cleared for the next action", dlg.loanQuoteKind, nil)

    -- A second confirmation of the same quote (double click, replayed callback) is refused.
    cb(true)
    T.eq("a replayed confirmation makes no second money call", #moved, 1)
    T.eq("and the host reports the quote as stale", infos[#infos], "im_loan_stale_quote")
end

-- ── a second click while a quote is pending is ignored ───────────────────────
do
    shown = nil; infos = {}
    local loan = newLoan(1000, 200)
    local mgr = newHost(loan, 50000)
    local dlg = newDialog()
    dlg:onClickPayoff()
    local first = shown
    dlg:onClickPayoff()
    T.ok("the second click opens no second confirmation", shown == first)
    T.eq("only one quote was minted", mgr._loanSeq, 1)
end

-- ── no cash: the host refuses at accept, nothing moves ───────────────────────
do
    shown = nil; infos = {}
    local loan = newLoan(1000, 200)
    local mgr, moved = newHost(loan, 50000)
    local dlg = newDialog()
    dlg:onClickPayoff()
    -- Cash drains between quote and confirmation (a bill lands while the box is open).
    g_farmManager.getFarmById = function(_self, id) return id == FARM and { money = 10 } or nil end
    if shown then shown.callback(true) end
    T.eq("a payoff the farm can no longer afford moves nothing", #moved, 0)
    T.eq("and the player is told why", infos[#infos], "im_loan_insufficient_cash")
    T.near("the debt is untouched", loan:getOutstanding(FARM), 1200, 1e-6)
end

-- ── no debt: the click reports instead of opening a confirmation ─────────────
do
    shown = nil; infos = {}
    local loan = newLoan(nil)
    local mgr, moved = newHost(loan, 50000)
    local dlg = newDialog()
    dlg:onClickPayoff()
    T.ok("no confirmation without a debt", shown == nil)
    T.eq("the player is told there is nothing to repay", infos[#infos], "im_loan_no_debt")
    T.eq("nothing moved", #moved, 0)
    T.eq("the pending gate is released", dlg.loanPending, false)
end

-- ── the dialog never takes the old one-step path ─────────────────────────────
do
    shown = nil
    local loan = newLoan(1000, 200)
    local mgr, moved = newHost(loan, 50000)
    local dlg = newDialog()
    local oneStep = 0
    mgr.uiPayoff = function() oneStep = oneStep + 1 end
    dlg:onClickPayoff()
    T.eq("Pay Off no longer calls the quote-and-accept helper", oneStep, 0)
    T.eq("and no money moved before a confirmation", #moved, 0)
end
