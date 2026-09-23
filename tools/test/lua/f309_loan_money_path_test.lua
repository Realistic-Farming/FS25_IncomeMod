-- f309_loan_money_path_test.lua - RSF-F309 v0.3 items 2 to 6, the emergency loan money
-- path, driven from production's own entry point: the manager is built by the REAL
-- IncomeManager.new (which installs the connection-teardown hook), every owner request
-- goes through the REAL EmergencyLoanEvent writeStream -> readStream -> run ->
-- handleEmergencyLoanRequest -> connection:sendEvent(reply) path with the #76 stream
-- tape, and the actor is resolved by the REAL resolveActor from the engine world the
-- fixture supplies (a dedicated server, a user manager, one farm with money and a
-- manager flag). Nothing pre-populates a session, a quote, a token or a debt record
-- the code under test is supposed to create; where a row starts from an existing debt
-- it says so.
--
-- Test-side substitutions, all persistence or UI, none in the code under test:
-- SettingsManager (XML I/O), IncomeSystem (the income timer; the loan reads only its
-- settings), SettingsGUI (console commands), EmergencyLoanDebtStorage (the save file,
-- counted), the StateLedger bridge (delivers the reload snapshot), FSBaseMission
-- (the engine function the teardown hook appends to) and Utils.appendedFunction.
--
--!load: src/ReleaseGate.lua, src/settings/SettingsManager.lua, src/settings/Settings.lua, src/EmergencyLoan.lua, src/EmergencyLoanEvent.lua, src/IncomeManager.lua

local C  = EmergencyLoanController
local OP = C.OP
local FARM = 7
local NORMAL = Settings.DIFFICULTY_NORMAL

-- ── engine surface the constructor and the loan touch ────────────────────────
getfenv = getfenv or function() return _G end
Utils = Utils or {}
Utils.appendedFunction = Utils.appendedFunction or function(old, new)
    if old == nil then return new end
    return function(...) old(...); return new(...) end
end
SettingsManager.new = function()
    return { loadSettings = function() end, saveSettings = function() end,
             saveTimerState = function() end, loadTimerState = function() return nil end }
end
IncomeSystem = { new = function(settings) return { settings = settings } end }
SettingsGUI  = { new = function() return { registerConsoleCommands = function() end } end }
local saves = 0
EmergencyLoanDebtStorage = { save = function() saves = saves + 1 end }
local engineClosed = { calls = 0, last = nil }
local engineOnConnectionClosed = function(_mission, connection, _reason)
    engineClosed.calls = engineClosed.calls + 1
    engineClosed.last = connection
end
FSBaseMission = { onConnectionClosed = engineOnConnectionClosed }

-- ── the world: a dedicated server with one farm ──────────────────────────────
local world
local function newWorld(cash)
    world = { cash = cash, moved = {}, users = {}, managers = {} }
    g_server = {}
    g_client = nil
    g_localPlayer = nil
    g_timeGuard = { registered = {}, unregistered = {} }
    function g_timeGuard:registerAccrual(id, spec)
        self.registered[#self.registered + 1] = id; self.spec = spec; return true
    end
    function g_timeGuard:unregisterAccrual(id) self.unregistered[#self.unregistered + 1] = id end
    ReleaseGate.isReleased = function(_id, optIn) return optIn == true end
    ReleaseGate.liveOptIn = function() return true end
    local farm = { money = cash }
    function farm:isUserFarmManager(userId) return world.managers[userId] == true end
    world.farm = farm
    g_farmManager = {
        SPECTATOR_FARM_ID = 0, GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15,
        getFarmById = function(_self, id)
            if id ~= FARM then return nil end
            farm.money = world.cash
            return farm
        end,
    }
    g_currentMission = {
        time = 1000, missionInfo = {},
        environment = { currentMonotonicDay = 5, dayTime = 0, currentYear = 1, currentPeriod = 3,
                        currentDayInPeriod = 1, daysPerPeriod = 3 },
        getIsServer = function() return true end,
        getIsClient = function() return false end,
        getFarmId = function(_self, connection)
            if connection ~= nil and world.users[connection] ~= nil then return FARM end
            return nil
        end,
        userManager = { getUserIdByConnection = function(_self, connection) return world.users[connection] end },
        addMoney = function(_self, amount, farmId, _moneyType, _force)
            world.moved[#world.moved + 1] = { amount = amount, farmId = farmId }
            world.cash = world.cash + amount
        end,
    }
    return world
end

--- A client connection of `userId`, a farm manager unless `manager` is false.
local function connect(userId, manager)
    local conn = { id = userId, sent = {} }
    function conn:sendEvent(ev) self.sent[#self.sent + 1] = ev end
    world.users[conn] = userId
    world.managers[userId] = manager ~= false
    return conn
end

--- The production manager, built the way main.lua builds it, made READY the way
--- loadEmergencyDebt makes a brand-new save READY.
local function newManager()
    local mgr = IncomeManager.new(g_currentMission, "./", "FS25_IncomeMod")
    mgr.emergencyLoan:setReadiness(EmergencyLoan.READINESS.READY)
    g_IncomeManager = mgr
    return mgr, mgr.emergencyLoan
end

--- One owner request over the wire: the client's event written to the tape, the
--- server's event read from it (which runs it), the reply the server sent to THIS
--- connection. Returns the reply payload and the tape.
local function send(mgr, conn, seq, op, amountText, token)
    g_IncomeManager = mgr
    local s = _sfMockStream()
    EmergencyLoanEvent.newRequest(seq, op, amountText, token):writeStream(s, nil)
    local before = #conn.sent
    EmergencyLoanEvent.emptyNew():readStream(s, conn)
    T.eq("wire: exactly one reply went to the requesting connection", #conn.sent, before + 1)
    T.eq("wire: the tape carried the request without a fault", _sfStreamFaults(s), 0)
    local ev = conn.sent[#conn.sent]
    return ev and ev.payload or nil, s
end

local function moved() return #world.moved end

-- ══════════════════════════════════════════════════════════════════════════════
-- A. retirement keeps the record; the next draw inherits the history (items 2, 3)
-- ══════════════════════════════════════════════════════════════════════════════
do
    newWorld(-500)
    saves = 0
    local mgr, loan = newManager()
    local A = connect(1)

    -- draw 1 through the wire
    local q = send(mgr, A, 1, OP.BORROW_QUOTE)
    T.ok("A1 borrow quote minted a token", type(q.token) == "string" and q.token ~= "")
    T.ok("A2 the quote carries the bound sum", type(q.quoteAmount) == "number" and q.quoteAmount > 0)
    local r = send(mgr, A, 2, OP.ACCEPT_QUOTE, nil, q.token)
    T.eq("A3 accept moved money once", moved(), 1)
    T.eq("A4 status ACCEPTED", r.status, "ACCEPTED")
    T.near("A5 exactly the quoted sum was credited", world.moved[1].amount, q.quoteAmount, 1e-9)
    T.eq("A6 a fresh farm's first draw is draw 1", loan.debts[FARM].drawCount, 1)
    T.eq("A7 its revision is 1", loan.debts[FARM].revision, 1)
    T.eq("A8 accrual registered for the farm", #g_timeGuard.registered, 1)
    T.eq("A9 the accepted draw was saved", saves, 1)
    local rev1 = loan.debts[FARM].revision

    -- income arrives, the player pays the line off through the wire
    world.cash = world.cash + 50000
    local pq = send(mgr, A, 3, OP.PAYOFF_QUOTE)
    T.near("A10 payoff quote binds the whole outstanding", pq.quoteAmount, loan:getOutstanding(FARM), 1e-9)
    local pr = send(mgr, A, 4, OP.ACCEPT_QUOTE, nil, pq.token)
    T.eq("A11 payoff ACCEPTED", pr.status, "ACCEPTED")
    T.eq("A12 payoff moved money", moved(), 2)
    local d = loan.debts[FARM]
    T.ok("A13 the record is KEPT after payoff (item 2)", d ~= nil)
    T.eq("A14 it is inactive", d.active, false)
    T.eq("A15 principal is zero", d.principal, 0)
    T.eq("A16 accrued interest is zero", d.accruedInterest, 0)
    T.eq("A17 the draw history is kept", d.drawCount, 1)
    T.ok("A18 retirement advanced the revision", d.revision > rev1)
    T.eq("A19 only the accrual subscription was dropped", #g_timeGuard.unregistered, 1)
    T.eq("A20 outstanding reads 0", loan:getOutstanding(FARM), 0)

    -- the completed line publishes a neutral view, on the host and over the wire
    local v = loan:getView(FARM, { isManager = true })
    T.eq("A21 completed view: no draws shown", v.drawCount, 0)
    T.eq("A22 completed view: no rate shown", v.effectiveMonthlyRate, 0)
    T.eq("A23 completed view: nothing outstanding", v.outstanding, 0)
    T.eq("A24 the wire reply after payoff shows no draws", pr.drawCount, 0)

    -- automatic repayment retires the same way
    local loan2 = EmergencyLoan.new()
    loan2.settings = { difficulty = NORMAL }
    loan2.incomeSystem = { settings = { enabled = false, getPaymentAmount = function() return 0 end } }
    loan2:setReadiness(EmergencyLoan.READINESS.READY)
    loan2.debts[FARM] = { principal = 100, accruedInterest = 0, drawCount = 3, revision = 9, active = true, pendingEligibility = {} }
    loan2:applyRepayment(FARM, 100000)
    T.ok("A25 automatic payoff keeps the record", loan2.debts[FARM] ~= nil and loan2.debts[FARM].active == false)
    T.eq("A26 automatic payoff keeps the draw count", loan2.debts[FARM].drawCount, 3)
    T.ok("A27 automatic payoff advances the revision", loan2.debts[FARM].revision > 9)

    -- save, reload through the production load path, reborrow
    local snap = loan:serialize()
    T.eq("A28 the retired record is saved", snap.debts[FARM] and snap.debts[FARM].active, false)
    local oldToken = pq.token
    local mgr2, loan2b = newManager()
    IncomeEmergencyLoanBridge = { hasState = function() return true end, pendingState = snap }
    g_timeGuard.registered = {}
    mgr2:loadEmergencyDebt()
    IncomeEmergencyLoanBridge = nil
    local rd = loan2b.debts[FARM]
    T.ok("A29 reload restores the retired record", rd ~= nil)
    T.eq("A30 restored as inactive", rd.active, false)
    T.eq("A31 the load registers accrual only for active debt", #g_timeGuard.registered, 0)
    T.eq("A32 readiness READY after the load", loan2b:getReadiness(), EmergencyLoan.READINESS.READY)
    local revSaved = rd.revision
    local B = connect(2)
    local movedBefore = moved()
    local stale = send(mgr2, B, 1, OP.ACCEPT_QUOTE, nil, oldToken)
    T.eq("A33 a token from before the reload is STALE after it", stale.status, "STALE_QUOTE")
    T.eq("A34 while the debt revision persisted across the reload", rd.revision, revSaved)
    T.eq("A35 no money moved on the stale token", moved(), movedBefore)

    world.cash = -500
    local q2 = send(mgr2, B, 2, OP.BORROW_QUOTE)
    T.ok("A36 reborrow quoted", type(q2.token) == "string" and q2.token ~= "")
    local r2 = send(mgr2, B, 3, OP.ACCEPT_QUOTE, nil, q2.token)
    T.eq("A37 reborrow ACCEPTED", r2.status, "ACCEPTED")
    local nd = loan2b.debts[FARM]
    T.eq("A38 the new draw inherits the history: draw 2, never 1 (item 3)", nd.drawCount, 2)
    T.ok("A39 the revision advanced over the retained value", nd.revision > revSaved)
    local base = EmergencyLoan.INTEREST_RATE_MONTHLY[NORMAL]
    local inc  = EmergencyLoan.ESCALATION_PP_PER_DRAW[NORMAL]
    T.near("A40 the rate is escalated by one re-draw", loan2b:effectiveRate(nd), math.min(base + inc, EmergencyLoan.MAX_RATE[NORMAL]), 1e-9)
    T.eq("A41 the report shows the history", r2.drawCount, 2)
    T.near("A42 the wire reply shows the escalated rate", r2.effectiveMonthlyRate, loan2b:effectiveRate(nd), 1e-9)
    T.eq("A43 accrual re-registered for the new draw", #g_timeGuard.registered, 1)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- B. a settle that grows the debt is a revision (item 4)
-- ══════════════════════════════════════════════════════════════════════════════
do
    newWorld(1000)
    local loan = EmergencyLoan.new()
    loan.settings = { difficulty = NORMAL }
    loan.incomeSystem = { settings = { enabled = false, getPaymentAmount = function() return 0 end } }
    loan.debts[FARM] = { principal = 10000, accruedInterest = 0, drawCount = 1, revision = 5, active = true, pendingEligibility = {} }
    loan:onInterestSettle(FARM, { boundariesCrossed = 1 })
    T.ok("B1 interest grew", loan.debts[FARM].accruedInterest > 0)
    T.eq("B2 the settle advanced the revision", loan.debts[FARM].revision, 6)
    ReleaseGate.isReleased = function() return false end   -- cost locked: no growth
    loan:onInterestSettle(FARM, { boundariesCrossed = 1 })
    T.eq("B3 a settle that grew nothing left the revision alone", loan.debts[FARM].revision, 6)
    ReleaseGate.isReleased = function(_id, optIn) return optIn == true end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- C. the accepted quote pays the bound sum or refuses (item 5)
-- ══════════════════════════════════════════════════════════════════════════════
do
    newWorld(-500)
    local mgr, loan = newManager()
    local A = connect(1)
    local seq = 0
    local function next() seq = seq + 1; return seq end

    -- an active line to re-draw against
    local q0 = send(mgr, A, next(), OP.BORROW_QUOTE)
    send(mgr, A, next(), OP.ACCEPT_QUOTE, nil, q0.token)
    T.eq("C0 the first draw is in", loan.debts[FARM].drawCount, 1)
    world.cash = -500

    -- C1: a settle between quote and accept makes the quote stale
    local q1 = send(mgr, A, next(), OP.BORROW_QUOTE)
    T.ok("C1a re-draw quoted", q1.token ~= "" and q1.quoteAmount > 0)
    local before = moved()
    loan:onInterestSettle(FARM, { boundariesCrossed = 1 })
    local r1 = send(mgr, A, next(), OP.ACCEPT_QUOTE, nil, q1.token)
    T.eq("C1b accept after a settle is STALE_QUOTE", r1.status, "STALE_QUOTE")
    T.eq("C1c no money moved", moved(), before)
    T.eq("C1d the draw count did not move", loan.debts[FARM].drawCount, 1)

    -- C2: cash moved between quote and accept (and with it the offer)
    local q2 = send(mgr, A, next(), OP.BORROW_QUOTE)
    world.cash = world.cash + 100
    local r2 = send(mgr, A, next(), OP.ACCEPT_QUOTE, nil, q2.token)
    T.eq("C2a accept after cash moved is STALE_QUOTE", r2.status, "STALE_QUOTE")
    T.eq("C2b no money moved", moved(), before)
    world.cash = world.cash - 100

    -- C3: the period length (a term computeOffer depends on) changed
    local q3 = send(mgr, A, next(), OP.BORROW_QUOTE)
    g_currentMission.environment.daysPerPeriod = 4
    local r3 = send(mgr, A, next(), OP.ACCEPT_QUOTE, nil, q3.token)
    T.eq("C3a accept after the period length changed is STALE_QUOTE", r3.status, "STALE_QUOTE")
    T.eq("C3b no money moved", moved(), before)
    g_currentMission.environment.daysPerPeriod = 3

    -- C4: nothing changed: the BOUND sum is paid, through redraw, as the bound amount
    local seen = {}
    local realRedraw, realGrant = loan.redraw, loan.grant
    loan.redraw = function(self, farmId, boundAmount) seen[#seen + 1] = { "redraw", boundAmount }; return realRedraw(self, farmId, boundAmount) end
    loan.grant  = function(self, farmId, boundAmount) seen[#seen + 1] = { "grant", boundAmount };  return realGrant(self, farmId, boundAmount) end
    local q4 = send(mgr, A, next(), OP.BORROW_QUOTE)
    local r4 = send(mgr, A, next(), OP.ACCEPT_QUOTE, nil, q4.token)
    T.eq("C4a unchanged assumptions: ACCEPTED", r4.status, "ACCEPTED")
    T.eq("C4b money moved once", moved(), before + 1)
    T.near("C4c the credited sum is the quoted sum", world.moved[#world.moved].amount, q4.quoteAmount, 1e-9)
    T.eq("C4d an active line went through redraw, not grant", seen[1] and seen[1][1], "redraw")
    T.eq("C4e redraw received the BOUND amount, not a recomputation", seen[1] and seen[1][2], q4.quoteAmount)
    T.eq("C4f grant was not called", #seen, 1)
    T.eq("C4g draw 2", loan.debts[FARM].drawCount, 2)

    -- C5: a refused redraw is REFUSED and never falls through into grant
    seen = {}
    world.cash = -500
    local q5 = send(mgr, A, next(), OP.BORROW_QUOTE)
    T.ok("C5a quoted", q5.token ~= "")
    local addMoney = g_currentMission.addMoney
    g_currentMission.addMoney = nil          -- the native money door is shut: redraw refuses
    local r5 = send(mgr, A, next(), OP.ACCEPT_QUOTE, nil, q5.token)
    g_currentMission.addMoney = addMoney
    T.eq("C5b a refused redraw answers REFUSED", r5.status, "REFUSED")
    T.eq("C5c redraw was tried", seen[1] and seen[1][1], "redraw")
    T.eq("C5d grant was NOT reached (no and-or fall-through)", #seen, 1)
    T.eq("C5e no money moved", moved(), before + 1)
    T.eq("C5f the line is unchanged", loan.debts[FARM].drawCount, 2)
    loan.redraw, loan.grant = nil, nil       -- back to the class methods

    -- C6: one outstanding quote per session: a newer quote drops the older token
    local qa = send(mgr, A, next(), OP.BORROW_QUOTE)
    local qb = send(mgr, A, next(), OP.BORROW_QUOTE)
    T.ok("C6a two tokens differ", qa.token ~= qb.token)
    local ra = send(mgr, A, next(), OP.ACCEPT_QUOTE, nil, qa.token)
    T.eq("C6b the superseded token is STALE_QUOTE", ra.status, "STALE_QUOTE")
    local rb = send(mgr, A, next(), OP.ACCEPT_QUOTE, nil, qb.token)
    T.eq("C6c the latest token is ACCEPTED", rb.status, "ACCEPTED")
    T.eq("C6d money moved once for the two tokens", moved(), before + 2)

    -- C7: a missing line is granted, explicitly
    newWorld(-500)
    local mgr7, loan7 = newManager()
    local A7 = connect(1)
    local seen7 = {}
    local rr, rg = loan7.redraw, loan7.grant
    loan7.redraw = function(self, f, b) seen7[#seen7 + 1] = "redraw"; return rr(self, f, b) end
    loan7.grant  = function(self, f, b) seen7[#seen7 + 1] = "grant";  return rg(self, f, b) end
    local q7 = send(mgr7, A7, 1, OP.BORROW_QUOTE)
    local r7 = send(mgr7, A7, 2, OP.ACCEPT_QUOTE, nil, q7.token)
    T.eq("C7a a missing line is ACCEPTED", r7.status, "ACCEPTED")
    T.eq("C7b through grant", seen7[1], "grant")
    T.eq("C7c and only grant", #seen7, 1)
    loan7.redraw, loan7.grant = nil, nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- D. the session discipline on the live handler (item 6)
-- ══════════════════════════════════════════════════════════════════════════════
do
    newWorld(-500)
    local mgr, loan = newManager()
    local A = connect(1)

    -- D1: an exact retry of an accepted command is answered from the record, money once
    local q = send(mgr, A, 10, OP.BORROW_QUOTE)
    local r = send(mgr, A, 11, OP.ACCEPT_QUOTE, nil, q.token)
    T.eq("D1a ACCEPTED", r.status, "ACCEPTED")
    T.eq("D1b money once", moved(), 1)
    local again = send(mgr, A, 11, OP.ACCEPT_QUOTE, nil, q.token)
    T.eq("D1c the exact retry returns the cached ACCEPTED, not STALE_QUOTE", again.status, "ACCEPTED")
    T.eq("D1d the retry carries its sequence", again.sequence, 11)
    T.eq("D1e money still once", moved(), 1)
    T.eq("D1f the draw count did not move", loan.debts[FARM].drawCount, 1)

    -- D2: an older sequence is refused
    local old = send(mgr, A, 5, OP.PAYOFF_QUOTE)
    T.eq("D2a older sequence refused", old.status, "OLD_SEQUENCE")
    T.eq("D2b nothing minted for it", old.token == nil or old.token == "", true)

    -- D3: the same sequence with a different payload is refused
    local ch = send(mgr, A, 11, OP.BORROW_QUOTE)
    T.eq("D3a changed payload refused", ch.status, "CHANGED_PAYLOAD")
    T.eq("D3b no token minted", ch.token == nil or ch.token == "", true)
    T.eq("D3c money still once", moved(), 1)

    -- D4: rights are established before the cached result is disclosed
    world.managers[1] = false
    local lost = send(mgr, A, 11, OP.ACCEPT_QUOTE, nil, q.token)
    T.eq("D4a a non-manager's exact retry gets NOT_MANAGER, not the cached ACCEPTED", lost.status, "NOT_MANAGER")
    world.managers[1] = true

    -- D5: another connection has its own session (tokens are per session, so B first
    -- presents A's token and sequence with no quote of its own)
    local B = connect(2)
    world.cash = -500
    local rb = send(mgr, B, 11, OP.ACCEPT_QUOTE, nil, q.token)
    T.eq("D5b A's token and sequence in B's session: STALE_QUOTE, never A's cached reply", rb.status, "STALE_QUOTE")
    T.eq("D5c money still once", moved(), 1)
    local qb = send(mgr, B, 12, OP.BORROW_QUOTE)
    T.ok("D5a B's own quote is processed in B's session", qb.status ~= "OLD_SEQUENCE" and qb.token ~= "")

    -- D6: VIEW is outside the command discipline
    local v = send(mgr, A, 1, OP.VIEW)
    T.ok("D6a a low-sequence VIEW is answered as a view", v.status ~= "OLD_SEQUENCE" and v.status ~= "CHANGED_PAYLOAD")
    T.eq("D6b and does not move the session", mgr:_loanSession(A).highest, 11)

    -- D7: a sequence the wire cannot carry is refused (handler called directly: the
    -- tape would flag the out-of-range write, so these two never travel)
    local bad0 = mgr:handleEmergencyLoanRequest(EmergencyLoanEvent.newRequest(0, OP.PAYOFF_QUOTE), A)
    T.eq("D7a sequence 0 is BAD_SEQUENCE", bad0.status, "BAD_SEQUENCE")
    local badHi = mgr:handleEmergencyLoanRequest(EmergencyLoanEvent.newRequest(C.MAX_SEQUENCE + 1, OP.PAYOFF_QUOTE), A)
    T.eq("D7b a sequence past MAX is BAD_SEQUENCE", badHi.status, "BAD_SEQUENCE")
    T.eq("D7c neither moved the session", mgr:_loanSession(A).highest, 11)

    -- D8: a refusal is a recorded result too: its exact retry is answered from the
    -- record even when a fresh evaluation would now succeed
    world.cash = world.cash + 100000
    local nq = send(mgr, B, 13, OP.PAYOFF_QUOTE)  -- B manages the same farm A drew for
    T.ok("D8a B can quote a payoff on the shared farm", nq.token ~= "")
    local pay = send(mgr, B, 14, OP.ACCEPT_QUOTE, nil, nq.token)
    T.eq("D8b B paid the line off", pay.status, "ACCEPTED")
    local nd = send(mgr, B, 15, OP.PAYOFF_QUOTE)
    T.eq("D8c with nothing owed the quote is NO_DEBT", nd.status, "NO_DEBT")
    world.cash = -500
    local qq = send(mgr, A, 12, OP.BORROW_QUOTE)   -- A, on its own session, draws again
    send(mgr, A, 13, OP.ACCEPT_QUOTE, nil, qq.token)
    T.eq("D8d a new line exists again", loan.debts[FARM].active, true)
    local retry = send(mgr, B, 15, OP.PAYOFF_QUOTE)  -- B's exact retry of its last command
    T.eq("D8e the exact retry of the refused quote is still NO_DEBT (recorded), not a fresh quote", retry.status, "NO_DEBT")
    T.eq("D8f and minted nothing", retry.token == nil or retry.token == "", true)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- E. the client never wraps its sequence, and holds one command at a time (item 6)
-- ══════════════════════════════════════════════════════════════════════════════
do
    newWorld(-500)
    local mgr = newManager()
    mgr._loanSeq = C.MAX_SEQUENCE - 1
    T.eq("E1 the last sequence is MAX itself", mgr:_nextLoanSequence(), C.MAX_SEQUENCE)
    T.eq("E2 past MAX the session refuses (nil), it does not wrap", mgr:_nextLoanSequence(), nil)
    T.eq("E3 the counter stays at MAX, not 1", mgr._loanSeq, C.MAX_SEQUENCE)
    T.eq("E4 and keeps refusing", mgr:_nextLoanSequence(), nil)

    -- a pure client: exhausted, nothing is sent and the UI hears nil
    g_currentMission.getIsServer = function() return false end
    local sentCount = 0
    g_client = { getServerConnection = function() return { sendEvent = function() sentCount = sentCount + 1 end } end }
    local heard = "unset"
    local ok, why = mgr:_uiQuoteOnly(OP.BORROW_QUOTE, nil, function(reply) heard = reply end)
    T.eq("E5 exhausted client refuses to send", ok, false)
    T.eq("E5b with the reason", why, "SEQUENCE_EXHAUSTED")
    T.eq("E6 nothing went out", sentCount, 0)
    T.eq("E7 the UI was told nil", heard, nil)
    T.eq("E8 nothing left pending", mgr._pendingQuote, nil)
    local ok2 = mgr:uiAcceptQuote("q1", function() end)
    T.eq("E9 exhausted accept refuses too", ok2, false)
    T.eq("E10 still nothing out", sentCount, 0)

    -- one outstanding owner-UI command: a second command while one is in flight is refused
    mgr._loanSeq = 0
    local ok3 = mgr:_uiQuoteOnly(OP.BORROW_QUOTE, nil, function() end)
    T.eq("E11 a fresh client sends", ok3, true)
    T.eq("E12 one request out", sentCount, 1)
    T.eq("E13 it is pending with sequence 1", mgr._pendingQuote and mgr._pendingQuote.sequence, 1)
    local ok4, why4 = mgr:uiAcceptQuote("q1", function() end)
    T.eq("E14 a second command while one is in flight is refused", ok4, false)
    T.eq("E15 as BUSY", why4, "BUSY")
    T.eq("E16 nothing more went out", sentCount, 1)
    T.eq("E17 the first command is still the pending one", mgr._pendingQuote and mgr._pendingQuote.sequence, 1)
    mgr:clearEmergencyLoanUiState()
    local ok5 = mgr:uiAcceptQuote("q1", function() end)
    T.eq("E18 after the slot clears a command sends again", ok5, true)
    T.eq("E19 two out in total", sentCount, 2)

    -- a double-clicked Borrow (quote-then-accept) on a pure client: the second click is
    -- BUSY while the first flow's auto-accept is still pending, so neither is lost
    mgr:clearEmergencyLoanUiState()
    local okb1 = mgr:_uiQuoteThenAccept(OP.BORROW_QUOTE)
    T.eq("E22 the first Borrow click sends its quote", okb1, true)
    T.eq("E23 and arms the auto-accept", mgr._pendingAccept, true)
    local okb2, whyb2 = mgr:_uiQuoteThenAccept(OP.BORROW_QUOTE)
    T.eq("E24 the second click is refused", okb2, false)
    T.eq("E25 as BUSY", whyb2, "BUSY")
    T.eq("E26 only the first quote went out", sentCount, 3)
    local okq, whyq = mgr:_uiQuoteOnly(OP.PAYOFF_QUOTE, nil, function() end)
    T.eq("E27 a manual quote during the armed flow is BUSY too", whyq, "BUSY")
    T.eq("E28 nothing more went out", sentCount, 3)
    mgr:clearEmergencyLoanUiState()
    T.eq("E29 clearing disarms the auto-accept", mgr._pendingAccept, false)

    -- the host path refuses at exhaustion as well
    g_currentMission.getIsServer = function() return true end
    g_client = nil
    mgr._loanSeq = C.MAX_SEQUENCE
    local okh, whyh = mgr:_uiQuoteThenAccept(OP.BORROW_QUOTE)
    T.eq("E20 the host path refuses at exhaustion", okh, false)
    T.eq("E21 with the reason", whyh, "SEQUENCE_EXHAUSTED")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- F. sessions die with their connection and with the manager (item 6), from the
--    real install: IncomeManager.new appends to FSBaseMission:onConnectionClosed
-- ══════════════════════════════════════════════════════════════════════════════
do
    T.eq("F1 the constructor installed the teardown hook once", IncomeManager._f309ConnHook.installed, true)
    T.ok("F2 FSBaseMission.onConnectionClosed is wrapped", FSBaseMission.onConnectionClosed ~= engineOnConnectionClosed)
    local wrapped = FSBaseMission.onConnectionClosed
    newWorld(-500)
    local mgr = newManager()                      -- a second manager: no second wrapper
    T.ok("F3 a second manager does not wrap again", FSBaseMission.onConnectionClosed == wrapped)

    local A, B = connect(1), connect(2)
    send(mgr, A, 1, OP.BORROW_QUOTE)
    send(mgr, B, 1, OP.BORROW_QUOTE)
    T.ok("F4 A has a session", mgr._loanSessions[A] ~= nil)
    T.ok("F5 B has a session", mgr._loanSessions[B] ~= nil)
    T.ok("F6 A holds a quote", mgr._loanSessions[A].quote ~= nil)

    engineClosed.calls = 0
    FSBaseMission.onConnectionClosed(g_currentMission, A, 1)   -- what the server resolves and calls
    T.eq("F7 the engine's own function still ran", engineClosed.calls, 1)
    T.eq("F8 and ran for that connection", engineClosed.last, A)
    T.eq("F9 A's session is gone with its quote and sequence", mgr._loanSessions[A], nil)
    T.ok("F10 B's session is untouched", mgr._loanSessions[B] ~= nil and mgr._loanSessions[B].quote ~= nil)

    -- A reconnects: a fresh session, sequence 1 is not OLD, the old token is dead
    local A2 = connect(1)
    local q = send(mgr, A2, 1, OP.BORROW_QUOTE)
    T.ok("F11 a reconnected player starts a fresh session", q.status ~= "OLD_SEQUENCE" and q.token ~= "")

    -- teardown drops every session
    g_inputBinding = nil
    mgr:delete()
    T.eq("F12 delete() drops all sessions", mgr._loanSessions, nil)
    T.ok("F13 the wrapper stays installed for the next manager (class-latched)", FSBaseMission.onConnectionClosed == wrapped)
    -- a close arriving after teardown, with no live manager, is harmless
    g_IncomeManager = nil
    engineClosed.calls = 0
    FSBaseMission.onConnectionClosed(g_currentMission, B, 1)
    T.eq("F14 the engine function ran with no manager live", engineClosed.calls, 1)
end
