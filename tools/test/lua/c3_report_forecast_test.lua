-- c3_report_forecast_test.lua - C3/RSF-F130: the report band shows the certified minimum
-- surface, and a pure client receives enough over the wire to render the same band.
--
-- Bound to the REAL functions: EmergencyLoan.getView, IncomeManager._viewReply,
-- EmergencyLoanEvent.writeStream/readStream (with the forecast tail), and
-- IncomeReportDialog.buildForecastLines / updateForecastLines / updateLoanSection.
--
-- Subject: before this change the band rendered only outstanding/principal/interest/
-- rate or the offer, and the reply wire carried none of minimumBalance, forecastStatus,
-- horizonEnd, expected income, costs or missingInputs, so a client could not show
-- the shortage warning or the coverage gaps the brief requires (section 2, :31/:176).
--
--!load: src/ReleaseGate.lua, src/settings/SettingsManager.lua, src/settings/Settings.lua, src/EmergencyLoan.lua, src/EmergencyLoanEvent.lua, src/IncomeManager.lua, src/ui/IncomeReportDialog.lua

local FARM = 7

-- ── i18n stub with the shipped English strings + hasText, so rows read like the game ──
local EN = {
    im_loan_none = "No emergency loan",
    im_loan_offer_available = "Emergency loan available:",
    im_loan_outstanding = "Outstanding", im_loan_principal = "Principal", im_loan_interest = "Interest",
    im_loan_fc_income = "Expected regular income", im_loan_fc_net = "net",
    im_loan_fc_bills = "Known bills", im_loan_fc_estimates = "Recent-spending estimate",
    im_loan_fc_minimum = "Projected lowest balance", im_loan_fc_shortage = "Shortage warning",
    im_loan_fc_status = "Forecast", im_loan_fc_ok = "OK", im_loan_fc_partial = "Partial",
    im_loan_fc_unavailable = "Unavailable", im_loan_fc_horizon = "Horizon", im_loan_fc_days = "%d days",
    im_loan_fc_missing = "Not covered", im_loan_fc_basis = "Working cash",
    im_loan_fc_basis_half = "half a period's regular income", im_loan_fc_basis_fallback = "10,000 fallback",
    im_loan_miss_invalid_clock = "game clock unavailable",
    im_loan_miss_sleep_skips_regular_payments = "payments skipped while sleeping are not guaranteed",
    im_loan_miss_no_operating_history = "no operating-cost history",
    im_loan_miss_income_disabled = "regular income disabled",
    im_loan_miss_payroll_absent = "payroll mod not installed",
    im_loan_miss_tax_absent = "tax mod not installed",
}
g_i18n = {
    getText = function(_self, key) return EN[key] or key end,
    hasText = function(_self, key) return EN[key] ~= nil end,
}

local function newWidget()
    local w = { text = nil, visible = nil, disabled = nil, color = nil }
    function w:setText(t) self.text = t end
    function w:setVisible(v) self.visible = v end
    function w:setDisabled(v) self.disabled = v end
    function w:setTextColor(r, g, b, a) self.color = { r, g, b, a } end
    return w
end

local function newDialog()
    local dlg = setmetatable({}, { __index = IncomeReportDialog })
    dlg.loanStatusText = newWidget()
    dlg.loanForecastIncomeText = newWidget()
    dlg.loanForecastBalanceText = newWidget()
    dlg.loanForecastMissingText = newWidget()
    dlg.loanBorrowButton = newWidget()
    dlg.loanPayoffButton = newWidget()
    dlg.loanRepayAmountButton = newWidget()
    return dlg
end

--- A hand-built view in the version-1 shape (what both getView and the wire produce).
local function sampleView(overrides)
    local v = {
        version = 1, farmId = FARM, revision = 3, readiness = "READY",
        asOf = { monotonicDay = 100, timeOfDayMs = 1000 },
        horizonEnd = { monotonicDay = 103, timeOfDayMs = 1000 },
        cash = 2000, nativeLoan = 50000, principal = 1000, accruedInterest = 200, outstanding = 1200,
        drawCount = 1, effectiveMonthlyRate = 0.02, costLockReason = nil, automaticRepaymentShare = 0.25,
        forecastStatus = "PARTIAL", minimumBalance = 450, shortfall = 0,
        expectedGrossIncome = 7200, expectedNetIncome = 5400,
        workingCashBasis = "HALF_PERIOD_GROSS", workingCashAmount = 3600,
        knownCosts = {
            { sourceId = "payroll", amount = 300, basis = "PAYROLL", dueDay = 102, dueTimeMs = 0 },
            { sourceId = "tax", amount = 200, basis = "TAX", dueDay = 103, dueTimeMs = 0 },
        },
        estimatedCosts = { { sourceId = "operating", amount = 150, basis = "LAST_PERIOD_OPERATING" } },
        missingInputs = { "SLEEP_SKIPS_REGULAR_PAYMENTS", "NO_OPERATING_HISTORY" },
        offer = nil, canBorrow = false, borrowReason = "NO_SHORTFALL",
        canRepay = true, repayReason = nil,
    }
    for k, val in pairs(overrides or {}) do v[k] = val end
    return v
end

-- ── band rows: PARTIAL with a non-negative minimum stays PARTIAL, no shortage ──
do
    local dlg = newDialog()
    local rows = dlg:buildForecastLines(sampleView())
    T.ok("income row names expected regular income", rows.income:find("Expected regular income: $7200", 1, true) ~= nil)
    T.ok("income row shows the net figure when the automatic share applies", rows.income:find("(net $5400)", 1, true) ~= nil)
    T.ok("income row sums the known bills", rows.income:find("Known bills: $500", 1, true) ~= nil)
    T.ok("income row labels the recent-spending estimate separately", rows.income:find("Recent-spending estimate: $150", 1, true) ~= nil)
    T.ok("balance row shows the projected lowest balance", rows.balance:find("Projected lowest balance: $450", 1, true) ~= nil)
    T.eq("a non-negative minimum is not a shortage", rows.shortage, false)
    T.ok("and carries no shortage warning text", rows.balance:find("Shortage warning", 1, true) == nil)
    T.ok("PARTIAL stays visible with a non-negative minimum", rows.balance:find("Forecast: Partial", 1, true) ~= nil)
    T.ok("horizon shows the period length", rows.balance:find("Horizon: 3 days", 1, true) ~= nil)
    T.ok("missing inputs are localized", rows.missing:find("Not covered: payments skipped while sleeping are not guaranteed; no operating-cost history", 1, true) ~= nil)
end

-- ── band rows: a negative minimum is the shortage warning ──
do
    local dlg = newDialog()
    local rows = dlg:buildForecastLines(sampleView({ minimumBalance = -800, shortfall = 800, forecastStatus = "OK", missingInputs = {} }))
    T.eq("a negative minimum flags the shortage", rows.shortage, true)
    T.ok("the shortage warning is spelled out", rows.balance:find("(Shortage warning)", 1, true) ~= nil)
    T.ok("status OK renders OK", rows.balance:find("Forecast: OK", 1, true) ~= nil)
    T.eq("no missing inputs means no coverage row", rows.missing, "")
end

-- ── band rows: UNAVAILABLE never renders a confident zero ──
do
    local dlg = newDialog()
    local rows = dlg:buildForecastLines({ forecastStatus = "UNAVAILABLE", missingInputs = { "INVALID_CLOCK" } })
    T.ok("unknown income is --", rows.income:find("Expected regular income: --", 1, true) ~= nil)
    T.ok("unknown bills are --", rows.income:find("Known bills: --", 1, true) ~= nil)
    T.ok("unknown estimate is --", rows.income:find("Recent-spending estimate: --", 1, true) ~= nil)
    T.ok("unknown minimum is --", rows.balance:find("Projected lowest balance: --", 1, true) ~= nil)
    T.ok("status reads Unavailable", rows.balance:find("Forecast: Unavailable", 1, true) ~= nil)
    T.ok("unknown horizon is --", rows.balance:find("Horizon: --", 1, true) ~= nil)
    T.eq("no false shortage on unknown", rows.shortage, false)
    T.ok("the clock reason is localized", rows.missing:find("game clock unavailable", 1, true) ~= nil)
end

-- ── an unknown reason code is shown, never hidden ──
do
    local dlg = newDialog()
    local rows = dlg:buildForecastLines(sampleView({ missingInputs = { "BRAND_NEW_REASON" } }))
    T.ok("an unlocalized code still appears", rows.missing:find("BRAND_NEW_REASON", 1, true) ~= nil)
    T.eq("a nil view yields empty rows", dlg:buildForecastLines(nil).income, "")
end

-- ── updateLoanSection pushes the rows into the band and colours the shortage ──
do
    local dlg = newDialog()
    local view = sampleView({ minimumBalance = -800, shortfall = 800, offer = 4400, canBorrow = true,
        outstanding = 0, principal = 0, accruedInterest = 0, workingCashBasis = "FALLBACK_10000" })
    g_IncomeManager = { getEmergencyLoanView = function() return view end }
    dlg:updateLoanSection()
    T.ok("the offer line names the working-cash basis", dlg.loanStatusText.text:find("Working cash: 10,000 fallback", 1, true) ~= nil)
    T.ok("the income row reached its element", dlg.loanForecastIncomeText.text:find("Known bills", 1, true) ~= nil)
    T.ok("the balance row reached its element", dlg.loanForecastBalanceText.text:find("Shortage warning", 1, true) ~= nil)
    T.ok("the coverage row reached its element", dlg.loanForecastMissingText.text:find("Not covered", 1, true) ~= nil)
    T.ok("a shortage row is coloured red", dlg.loanForecastBalanceText.color ~= nil and dlg.loanForecastBalanceText.color[1] == 1.0)
    T.eq("borrow shows for the offer", dlg.loanBorrowButton.visible, true)

    g_IncomeManager = { getEmergencyLoanView = function() return nil, "NO_VIEW_YET" end }
    dlg:updateLoanSection()
    T.eq("no view clears the income row", dlg.loanForecastIncomeText.text, "")
    T.eq("no view clears the coverage row", dlg.loanForecastMissingText.text, "")
end

-- ── the wire carries the whole forecast, in matching order, nil preserved ──
local function roundTrip(payload)
    local s = _sfMockStream()
    EmergencyLoanEvent.newReply(payload):writeStream(s, nil)
    g_IncomeManager = nil
    local back = EmergencyLoanEvent.emptyNew()
    back:readStream(s, nil)
    return back.payload, s
end

-- ── the revision clamp, doing its actual job ─────────────────────────────────
-- Every other fixture sends a revision the clamp never has to touch, so dropping
-- `math.min(..., MAX_SEQUENCE)` from writeForecast would change nothing and no test
-- would notice. The clamp was guarded by nothing.
--
-- This sends a revision ABOVE the 31-bit ceiling and asserts it arrives clamped TO
-- the ceiling with no range fault. That pins the clamp as a clamp, and it is what
-- lets the dropped-clamp mutation be the realistic edit (just remove the math.min)
-- rather than one that manufactures its own overflow. (Bob, PR #76 review.)
do
    local mgr = setmetatable({}, { __index = IncomeManager })
    local reply = mgr:_viewReply(sampleView(), 9)
    -- 2 ^ 31 rather than MAX_SEQUENCE + 1, and the reason is structural rather than a
    -- quirk of the number chosen.
    --
    -- THE BENCH'S INTEGER TYPE IS 32-BIT. Probed directly in fengari: _VERSION is
    -- Lua 5.3 but math.maxinteger is 2147483647, not standard Lua 5.3's 2^63-1. So
    -- MAX_SEQUENCE and math.maxinteger are THE SAME NUMBER, and no integer
    -- expression can produce a value above this mod's wire ceiling that is still
    -- representable: MAX_SEQUENCE + 1000 evaluates to -2147482649. A fixture built
    -- that way sends a NEGATIVE revision while appearing to test the upper bound,
    -- and the clamp catches it on the wrong side.
    --
    -- Reaching over-ceiling therefore REQUIRES a float. A literal at or below
    -- 2147483647 is an integer and wraps; above it the literal is already a float
    -- and does not. So `MAX + n` can never work here and `2 ^ n` always can.
    --
    -- WHETHER THE GAME'S LUA BEHAVES THIS WAY IS UNVERIFIED. The decompiled scripts
    -- never use math.maxinteger and never reference an integer ceiling, so this is a
    -- property of the BENCH with no checked correspondence to the engine. Do not
    -- read it as a statement about the game. The float sidesteps the question
    -- entirely, since 2 ^ 31 is a float in either world, which is why it is the
    -- right fixture regardless of how that divergence resolves.
    local overCeiling = 2 ^ 31
    T.ok("clamp: the fixture value really is above the ceiling",
        overCeiling > EmergencyLoanController.MAX_SEQUENCE,
        "fixture value " .. tostring(overCeiling) .. " did not exceed the ceiling")
    reply.revision = overCeiling
    local got, s = roundTrip(reply)
    T.eq("clamp: an over-ceiling revision arrives clamped to the ceiling",
        got.revision, EmergencyLoanController.MAX_SEQUENCE)
    T.eq("clamp: and the clamp keeps it inside its declared width", s.rangeErrors, 0)
    T.eq("clamp: no width mismatch", s.widthErrors, 0)
end

do
    local mgr = setmetatable({}, { __index = IncomeManager })
    local reply = mgr:_viewReply(sampleView(), 9)
    T.eq("reply copies minimumBalance", reply.minimumBalance, 450)
    T.eq("reply copies forecastStatus", reply.forecastStatus, "PARTIAL")
    T.eq("reply copies the horizon end", reply.horizonEnd.monotonicDay, 103)
    T.eq("reply copies missing inputs", #reply.missingInputs, 2)
    T.ok("reply does not alias the view's cost list", reply.knownCosts ~= sampleView().knownCosts)

    local got, s = roundTrip(reply)
    T.eq("wire: no type mismatch", s.typeErrors, 0)
    T.eq("wire: no underflow", s.underflows, 0)
    T.eq("wire: no UIntN width mismatch", s.widthErrors, 0)
    T.eq("wire: no value exceeds its declared width", s.rangeErrors, 0)
    T.eq("wire: drained exactly", s.r, #s.q + 1)
    T.eq("wire: version", got.version, 1)
    T.eq("wire: farmId", got.farmId, FARM)
    T.eq("wire: revision", got.revision, 3)
    T.eq("wire: readiness", got.readiness, "READY")
    T.near("wire: principal", got.principal, 1000, 1e-6)
    T.near("wire: accrued interest", got.accruedInterest, 200, 1e-6)
    T.near("wire: native loan", got.nativeLoan, 50000, 1e-6)
    T.eq("wire: draw count", got.drawCount, 1)
    T.near("wire: effective monthly rate", got.effectiveMonthlyRate, 0.02, 1e-6)
    T.eq("wire: nil cost-lock reason stays nil", got.costLockReason, nil)
    T.near("wire: automatic share", got.automaticRepaymentShare, 0.25, 1e-6)
    T.eq("wire: forecast status", got.forecastStatus, "PARTIAL")
    T.eq("wire: asOf day", got.asOf.monotonicDay, 100)
    T.eq("wire: horizon end day", got.horizonEnd.monotonicDay, 103)
    T.near("wire: minimum balance", got.minimumBalance, 450, 1e-6)
    T.near("wire: shortfall", got.shortfall, 0, 1e-6)
    T.near("wire: expected gross", got.expectedGrossIncome, 7200, 1e-6)
    T.near("wire: expected net", got.expectedNetIncome, 5400, 1e-6)
    T.eq("wire: working-cash basis", got.workingCashBasis, "HALF_PERIOD_GROSS")
    T.near("wire: working-cash amount", got.workingCashAmount, 3600, 1e-6)
    T.eq("wire: known cost rows", #got.knownCosts, 2)
    T.eq("wire: known cost source", got.knownCosts[2].sourceId, "tax")
    T.near("wire: known cost amount", got.knownCosts[1].amount, 300, 1e-6)
    T.eq("wire: known cost due day", got.knownCosts[1].dueDay, 102)
    T.eq("wire: estimate rows", #got.estimatedCosts, 1)
    T.eq("wire: estimate with no due pair reads nil, not day 0", got.estimatedCosts[1].dueDay, nil)
    T.eq("wire: missing inputs count", #got.missingInputs, 2)
    T.eq("wire: missing inputs order", got.missingInputs[1], "SLEEP_SKIPS_REGULAR_PAYMENTS")
    T.eq("wire: borrow reason", got.borrowReason, "NO_SHORTFALL")
    T.eq("wire: nil repay reason stays nil", got.repayReason, nil)

    -- The client renders the SAME band from the decoded reply as the host from its view.
    local dlg = newDialog()
    local hostRows = dlg:buildForecastLines(sampleView())
    local clientRows = dlg:buildForecastLines(got)
    T.eq("client income row matches the host", clientRows.income, hostRows.income)
    T.eq("client balance row matches the host", clientRows.balance, hostRows.balance)
    T.eq("client coverage row matches the host", clientRows.missing, hostRows.missing)
end

-- ── an UNAVAILABLE reply keeps every unknown unknown ──
do
    local mgr = setmetatable({}, { __index = IncomeManager })
    local got, s = roundTrip(mgr:_viewReply({ forecastStatus = "UNAVAILABLE", readiness = "LOADING",
        missingInputs = { "INVALID_CLOCK" } }, 2))
    T.eq("wire: unavailable drained exactly", s.r, #s.q + 1)
    T.eq("wire: unknown principal is nil", got.principal, nil)
    T.eq("wire: unknown minimum is nil", got.minimumBalance, nil)
    T.eq("wire: unknown gross is nil", got.expectedGrossIncome, nil)
    T.eq("wire: unknown horizon is nil", got.horizonEnd, nil)
    T.eq("wire: unknown basis is nil", got.workingCashBasis, nil)
    T.eq("wire: unknown farm is nil", got.farmId, nil)
    T.eq("wire: unknown cost list reads as empty", #got.knownCosts, 0)
    T.eq("wire: the clock reason survives", got.missingInputs[1], "INVALID_CLOCK")
    T.eq("wire: readiness survives", got.readiness, "LOADING")
end

-- ── the cost lists are bounded on the wire ──
do
    local many = {}
    for i = 1, 20 do many[i] = { sourceId = "bill" .. i, amount = i } end
    local got, s = roundTrip({ knownCosts = many, estimatedCosts = {} })
    T.eq("wire: known costs capped at MAX_COST_ENTRIES", #got.knownCosts, EmergencyLoanController.MAX_COST_ENTRIES)
    T.eq("wire: bounded list still drains exactly", s.r, #s.q + 1)
end

-- ── the real host view carries the fields the band reads ──
do
    g_currentMission.environment = { currentMonotonicDay = 100, dayTime = 64800000,
        currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 3 }
    g_currentMission.getIsServer = function() return true end
    g_farmManager = { getFarmById = function(_self, id)
        if id ~= FARM then return nil end
        return { money = 2500, isUserFarmManager = function() return true end }
    end }
    local loan = EmergencyLoan.new()
    loan.settings = { difficulty = Settings.DIFFICULTY_NORMAL }
    loan.incomeSystem = { settings = { enabled = false, getPaymentAmount = function() return 0 end } }
    loan:setReadiness(EmergencyLoan.READINESS.READY)
    loan.debts[FARM] = { principal = 1000, accruedInterest = 200, drawCount = 1, active = true, revision = 3 }

    local view = loan:getView(FARM, { isManager = true })
    T.eq("host view status is PARTIAL when providers are absent", view.forecastStatus, "PARTIAL")
    T.eq("host view horizon spans one period", view.horizonEnd.monotonicDay - view.asOf.monotonicDay, 3)
    local dlg = newDialog()
    local rows = dlg:buildForecastLines(view)
    T.ok("host rows name the absent payroll provider", rows.missing:find("payroll mod not installed", 1, true) ~= nil)
    T.ok("host rows name the disabled income", rows.missing:find("regular income disabled", 1, true) ~= nil)
    T.ok("host rows show the cash as the projected minimum", rows.balance:find("Projected lowest balance: $2500", 1, true) ~= nil)

    local mgr = setmetatable({}, { __index = IncomeManager })
    local got = roundTrip(mgr:_viewReply(view, 4))
    T.eq("client rows from the real view match the host", dlg:buildForecastLines(got).balance, rows.balance)
    T.eq("client coverage from the real view matches the host", dlg:buildForecastLines(got).missing, rows.missing)
end
