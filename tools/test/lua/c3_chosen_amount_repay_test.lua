-- c3_chosen_amount_repay_test.lua - C3/RSF-F130 chosen-amount repayment player path.
--
-- Bound to the REAL repaired functions: EmergencyLoanController.encodeAmount/parseAmount,
-- EmergencyLoanEvent write/readStream, IncomeManager.handleEmergencyLoanRequest and
-- IncomeManager.onEmergencyLoanReply. The subject is the seam the delivered brief still
-- required: a player names an amount, the SERVER binds its own exact amount after
-- clamping to real cash and debt, and only an explicit confirmation of THAT sum moves
-- money. The typed value is never a money instruction.
--
-- resolveActor is overridden here: actor resolution needs the native user/farm managers
-- and is not this bench's subject. GUI render, native Event transport and the real money
-- path remain in-game observations.
--
--!load: src/ReleaseGate.lua, src/settings/SettingsManager.lua, src/settings/Settings.lua, src/EmergencyLoan.lua, src/EmergencyLoanEvent.lua, src/IncomeManager.lua

local OP = EmergencyLoanController.OP

-- ── harness ──────────────────────────────────────────────────────────────────
local FARM = 7

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

--- A manager-on-this-farm server with `cash` in the bank and a recording addMoney.
local function newServer(loan, cash)
    g_server = {}
    local moved = {}
    g_farmManager = { getFarmById = function(_self, id) return id == FARM and { money = cash } or nil end }
    g_currentMission.addMoney = function(_self, amount, farmId, moneyType, _force)
        moved[#moved + 1] = { amount = amount, farmId = farmId, moneyType = moneyType }
    end
    EmergencyLoanController.resolveActor = function(_connection)
        return { userId = 1, farmId = FARM, farm = { money = cash }, isManager = true }, nil
    end

    local mgr = setmetatable({}, { __index = IncomeManager })
    mgr.emergencyLoan = loan
    mgr._loanSessions = {}
    mgr._loanSeq = 0
    mgr.saves = 0
    mgr.saveEmergencyDebt = function(selfRef) selfRef.saves = selfRef.saves + 1 end
    return mgr, moved
end

local function request(mgr, op, amountText, token)
    return mgr:handleEmergencyLoanRequest(
        EmergencyLoanEvent.newRequest(mgr:_nextLoanSequence(), op, amountText, token), nil)
end

-- ── encodeAmount: unknown stays unknown, never a confident zero ───────────────
do
    local enc = EmergencyLoanController.encodeAmount
    T.eq("encode nil is empty (unknown, not 0)", enc(nil), "")
    T.eq("encode inf is empty", enc(math.huge), "")
    T.eq("encode -inf is empty", enc(-math.huge), "")
    T.eq("encode nan is empty", enc(0 / 0), "")
    -- Huge values: the encoder may legitimately produce either "" (over-length, so
    -- UNKNOWN) or exact text, and the two Lua builds format them differently. What must
    -- hold on both is the contract: never over-length, and never a truncated wrong sum.
    local huge = enc(1e300)
    T.ok("encode of a huge value never exceeds MAX_AMOUNT_LEN",
        #huge <= EmergencyLoanController.MAX_AMOUNT_LEN)
    T.ok("encode of a huge value is either unknown or exactly reversible",
        huge == "" or EmergencyLoanController.parseAmount(huge) == 1e300)
    T.eq("encode a normal amount", enc(1234.5), "1234.500000")
    T.near("encode->parse round trip keeps the value",
        EmergencyLoanController.parseAmount(enc(987.65)), 987.65, 1e-6)
    T.eq("parse of the empty encoding is nil, not 0",
        EmergencyLoanController.parseAmount(enc(nil)), nil)
end

-- ── reply wire carries the bound amount ──────────────────────────────────────
do
    local s = _sfMockStream()
    local out = EmergencyLoanEvent.newReply({ status = "OK", sequence = 12, cash = 500,
        outstanding = 1200, offer = 0, canBorrow = false, canRepay = true,
        token = "q1", quoteAmount = 500 })
    out:writeStream(s, nil)

    -- Read through the REAL readStream so write and read order are proven symmetric
    -- (run() is a no-op here: no manager is installed to dispatch to).
    g_IncomeManager = nil
    local back = EmergencyLoanEvent.emptyNew()
    back:readStream(s, nil)
    T.eq("wire: no type mismatch", s.typeErrors, 0)
    T.eq("wire: no underflow (write and read agree on the field count)", s.underflows, 0)
    T.eq("wire: the queue drained exactly", s.r, #s.q + 1)
    T.eq("wire: it is a reply", back.isReply, true)
    T.eq("wire: status survives", back.payload.status, "OK")
    T.eq("wire: sequence survives", back.payload.sequence, 12)
    T.near("wire: cash survives", back.payload.cash, 500, 1e-6)
    T.eq("wire: canRepay survives", back.payload.canRepay, true)
    T.eq("wire: token survives", back.payload.token, "q1")
    T.near("wire: the bound amount survives", back.payload.quoteAmount, 500, 1e-6)

    local s2 = _sfMockStream()
    EmergencyLoanEvent.newReply({ status = "OK", token = "" }):writeStream(s2, nil)
    local back2 = EmergencyLoanEvent.emptyNew()
    back2:readStream(s2, nil)
    T.eq("wire: a reply with no quote reads back nil, not 0", back2.payload.quoteAmount, nil)
    T.eq("wire: reading the unquoted reply stayed in step", s2.typeErrors, 0)
    T.eq("wire: the unquoted reply drained exactly", s2.r, #s2.q + 1)
end

-- ── the server binds ITS amount: clamped to cash ─────────────────────────────
do
    local loan = newLoan(1000, 200)          -- outstanding 1200
    local mgr = newServer(loan, 500)         -- only 500 in the bank
    local reply = request(mgr, OP.MANUAL_AMOUNT_QUOTE, "900")

    T.ok("quote with cash short of the ask still returns a token", (reply.token or "") ~= "")
    T.near("quote binds the CASH limit, not the typed 900", reply.quoteAmount, 500, 1e-6)
    T.eq("quoting alone moves no money", loan:getOutstanding(FARM), 1200)
end

-- ── the server binds ITS amount: clamped to the debt ─────────────────────────
do
    local loan = newLoan(1000, 200)
    local mgr = newServer(loan, 50000)
    local reply = request(mgr, OP.MANUAL_AMOUNT_QUOTE, "5000")
    T.near("quote binds the DEBT limit when cash is ample", reply.quoteAmount, 1200, 1e-6)
end

-- ── a malformed typed amount never becomes a quote ───────────────────────────
do
    local loan = newLoan(1000, 200)
    local mgr = newServer(loan, 50000)
    for _, bad in ipairs({ "0", "-250", "abc", "", "1/2", string.rep("9", 40) }) do
        local reply = request(mgr, OP.MANUAL_AMOUNT_QUOTE, bad)
        T.ok("refused amount text: " .. (bad == "" and "<empty>" or bad:sub(1, 12)),
            reply.status == "INVALID_AMOUNT" and (reply.token or "") == "")
    end
    T.eq("no refused entry moved money", loan:getOutstanding(FARM), 1200)
end

-- ── accepting the quote moves exactly the bound amount, once ─────────────────
do
    local loan = newLoan(1000, 200)
    local mgr, moved = newServer(loan, 500)
    local quote = request(mgr, OP.MANUAL_AMOUNT_QUOTE, "900")
    local accepted = request(mgr, OP.ACCEPT_QUOTE, nil, quote.token)

    T.eq("accept is acknowledged", accepted.status, "ACCEPTED")
    T.near("interest first, then principal: 1200 - 500", loan:getOutstanding(FARM), 700, 1e-6)
    T.eq("exactly one native money call", #moved, 1)
    T.near("the farm is debited the BOUND amount", moved[1].amount, -500, 1e-6)
    T.eq("debited on the acting farm", moved[1].farmId, FARM)
    T.eq("an accepted payment is persisted once", mgr.saves, 1)

    local again = request(mgr, OP.ACCEPT_QUOTE, nil, quote.token)
    T.eq("the token is consumed: a repeat confirmation is refused", again.status, "STALE_QUOTE")
    T.near("a repeat confirmation moves nothing more", loan:getOutstanding(FARM), 700, 1e-6)
    T.eq("and makes no second money call", #moved, 1)
end

-- ── a quote awaiting confirmation is delivered, never auto-accepted ──────────
do
    local mgr = setmetatable({}, { __index = IncomeManager })
    local delivered = {}
    mgr._pendingAccept = true      -- the old fire-and-forget path must NOT win
    mgr._pendingQuote = { sequence = 7, callback = function(p) delivered[#delivered + 1] = p end }

    mgr:onEmergencyLoanReply({ sequence = 9, token = "qX", quoteAmount = 400 })
    T.eq("a reply for another sequence resolves nothing", #delivered, 0)
    T.ok("and leaves the confirmation still waiting", mgr._pendingQuote ~= nil)

    mgr:onEmergencyLoanReply({ sequence = 7, token = "q1", quoteAmount = 500 })
    T.eq("the matching reply is delivered to the confirming UI", #delivered, 1)
    T.near("carrying the server's bound amount", delivered[1].quoteAmount, 500, 1e-6)
    T.eq("the pending quote is cleared once", mgr._pendingQuote, nil)
    T.ok("a quote is never auto-accepted on arrival", mgr._pendingAccept == true)
end

-- ── an accept result resolves its own wait, once ─────────────────────────────
do
    local mgr = setmetatable({}, { __index = IncomeManager })
    local got = {}
    mgr._pendingResult = { sequence = 4, callback = function(p) got[#got + 1] = p end }

    mgr:onEmergencyLoanReply({ sequence = 4, status = "ACCEPTED" })
    T.eq("the accept result reaches the UI", #got, 1)
    T.eq("success is read from the host status", got[1].status, "ACCEPTED")

    mgr:onEmergencyLoanReply({ sequence = 4, status = "ACCEPTED" })
    T.eq("a duplicated reply cannot resolve it twice", #got, 1)
end

-- ── teardown releases waits without resolving them ───────────────────────────
do
    local mgr = setmetatable({}, { __index = IncomeManager })
    local fired = 0
    mgr._pendingQuote  = { sequence = 1, callback = function() fired = fired + 1 end }
    mgr._pendingResult = { sequence = 2, callback = function() fired = fired + 1 end }
    mgr._pendingAccept = true

    mgr:clearEmergencyLoanUiState()
    T.eq("teardown drops the pending quote", mgr._pendingQuote, nil)
    T.eq("teardown drops the pending result", mgr._pendingResult, nil)
    T.eq("teardown drops the auto-accept flag", mgr._pendingAccept, false)
    T.eq("and resolves no confirmation on the way out", fired, 0)
end
