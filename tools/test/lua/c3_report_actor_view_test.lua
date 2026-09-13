-- c3_report_actor_view_test.lua - C3/RSF-F130: the report can reach its own actions.
--
-- Bound to the REAL functions: IncomeManager.getEmergencyLoanView (server branch),
-- IncomeManager.refreshEmergencyLoanView, IncomeManager.onEmergencyLoanReply and
-- IncomeReportDialog.updateLoanSection / onOpen / requestLoanView / onLoanViewArrived.
--
-- Subject: before this repair the report asked the host for a view with NO actor
-- (getEmergencyLoanView(nil) -> loan:getView(farm, nil)), which the loan answers with
-- NO_ACTOR_CONTEXT, canBorrow=false, canRepay=false. The dialog then hid every money
-- button, so Borrow, Pay Off and Repay Amount could never be clicked on SP or a listen
-- host. On a pure client nothing ever sent a VIEW request, so the cache stayed empty
-- and the report showed "no loan" forever. The engine actor resolution itself
-- (userManager / farm manager rights) is stubbed; it is not the subject here.
--
--!load: src/ReleaseGate.lua, src/settings/SettingsManager.lua, src/settings/Settings.lua, src/EmergencyLoan.lua, src/EmergencyLoanEvent.lua, src/IncomeManager.lua, src/ui/IncomeReportDialog.lua

local OP = EmergencyLoanController.OP
local FARM = 7

-- A valid native clock, or the forecast reports UNAVAILABLE with no cash and canRepay
-- can never be true regardless of actor rights.
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

local function newManager(loan)
    local mgr = setmetatable({}, { __index = IncomeManager })
    mgr.emergencyLoan = loan
    mgr.incomeSystem = loan.incomeSystem
    mgr._loanSessions = {}
    mgr._loanSeq = 0
    mgr.saveEmergencyDebt = function() end
    return mgr
end

--- A widget stub that records the last visibility/text it was given.
local function newWidget()
    local w = { visible = nil, disabled = nil, text = nil }
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
    dlg.isOpen = true
    return dlg
end

--- Server (SP / listen host) with a local player who manages FARM and `cash` in the bank.
local function asHost(cash, isManager)
    g_server = {}
    g_client = nil
    g_currentMission.getIsServer = function() return true end
    g_currentMission.getFarmId = function() return FARM end
    g_currentMission.addMoney = function() end
    g_localPlayer = { userId = 1, farmId = FARM }
    g_farmManager = {
        getFarmById = function(_self, id)
            if id ~= FARM then return nil end
            return { money = cash, isUserFarmManager = function() return isManager == true end }
        end,
    }
end

-- ── host: nil farmId is the local PLAYER's view, with real rights ────────────
do
    local loan = newLoan(1000, 200)
    asHost(5000, true)
    local mgr = newManager(loan)

    local view = mgr:getEmergencyLoanView(nil)
    T.ok("host view resolves", type(view) == "table")
    T.eq("host view is for the local player's farm", view.farmId, FARM)
    T.eq("a managing host player may repay their own debt", view.canRepay, true)
    T.ok("and is no longer told NO_ACTOR_CONTEXT", view.repayReason ~= "NO_ACTOR_CONTEXT")
end

-- ── host: a non-manager on the farm still gets no money rights ───────────────
do
    local loan = newLoan(1000, 200)
    asHost(5000, false)
    local mgr = newManager(loan)
    local view = mgr:getEmergencyLoanView(nil)
    T.eq("a non-manager host player cannot repay", view.canRepay, false)
    T.eq("a non-manager host player cannot borrow", view.canBorrow, false)
end

-- ── host: an explicit farmId stays a pure actor-less sample ──────────────────
do
    local loan = newLoan(1000, 200)
    asHost(5000, true)
    local mgr = newManager(loan)
    local view = mgr:getEmergencyLoanView(FARM)
    T.eq("explicit farmId sample carries no actor rights", view.canRepay, false)
    T.eq("explicit farmId sample says why", view.repayReason, "NO_ACTOR_CONTEXT")
end

-- ── dedicated server: no local player falls back to the pure sample ──────────
do
    local loan = newLoan(1000, 200)
    asHost(5000, true)
    g_localPlayer = nil
    local mgr = newManager(loan)
    local view = mgr:getEmergencyLoanView(nil)
    T.ok("no local player still yields a view (not an error)", type(view) == "table")
    T.eq("and that view offers no money action", view.canRepay, false)
end

-- ── the report shows the buttons on a host that can act ──────────────────────
do
    local loan = newLoan(1000, 200)
    asHost(5000, true)
    local mgr = newManager(loan)
    g_IncomeManager = mgr
    local dlg = newDialog()
    dlg:updateLoanSection()
    T.eq("Pay Off is visible for the managing host", dlg.loanPayoffButton.visible, true)
    T.eq("Repay Amount is visible for the managing host", dlg.loanRepayAmountButton.visible, true)
    T.ok("the band shows the outstanding debt, not 'no loan'",
        dlg.loanStatusText.text ~= "im_loan_none")
end

-- ── pure client: opening the report asks the host for a view ─────────────────
do
    local loan = newLoan(1000, 200)
    g_server = nil
    g_localPlayer = nil
    g_currentMission.getIsServer = function() return false end
    g_currentMission.getFarmId = function() return FARM end
    local sentOps = {}
    g_client = { getServerConnection = function()
        return { sendEvent = function(_self, ev) sentOps[#sentOps + 1] = ev.operation end }
    end }

    local mgr = newManager(loan)
    g_IncomeManager = mgr
    local dlg = newDialog()
    mgr.incomeReportDialog = dlg
    dlg.updateDisplay = function(selfRef) selfRef:updateLoanSection() end
    IncomeReportDialog.superClass = function() return { onOpen = function() end } end

    dlg:onOpen()
    T.eq("opening the report sends exactly one request", #sentOps, 1)
    T.eq("and that request is a VIEW (no money moves)", sentOps[1], OP.VIEW)
    T.eq("until the reply lands the band says no loan", dlg.loanStatusText.text, "im_loan_none")
    T.eq("and Pay Off stays hidden", dlg.loanPayoffButton.visible, false)

    -- The host answers: the band redraws itself without the player reopening the report.
    mgr:onEmergencyLoanReply({ status = "OK", sequence = mgr._loanSeq, outstanding = 1200,
        cash = 5000, offer = 0, canBorrow = false, canRepay = true })
    T.eq("the reply is cached as the local view", mgr:getEmergencyLoanView(nil).outstanding, 1200)
    T.eq("the open report redraws and shows Pay Off", dlg.loanPayoffButton.visible, true)
    T.eq("and Repay Amount", dlg.loanRepayAmountButton.visible, true)

    -- A closed report is left alone.
    dlg.isOpen = false
    dlg.loanPayoffButton.visible = "untouched"
    mgr:onEmergencyLoanReply({ status = "OK", sequence = 99, outstanding = 1200,
        cash = 5000, offer = 0, canBorrow = false, canRepay = true })
    T.eq("a reply after the report closed does not redraw it", dlg.loanPayoffButton.visible, "untouched")
end
