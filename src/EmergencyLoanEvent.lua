-- =========================================================
-- FS25 Income Mod - EMERGENCY LOAN owner Event + controller (C3 / RSF-F130)
-- =========================================================
-- The private request/reply path: a farm asks the host for its own view/quote and,
-- only via ACCEPT_QUOTE, moves money. The server derives the farm from the authenticated
-- connection, checks farm-manager rights for mutating ops, and keeps a bounded per-
-- connection session (highest processed sequence + last result) so a lost/duplicated
-- reply never double-charges. No private debt, command token or arbitrary-farm record is
-- broadcast through a general state stream.
--
-- The money-safety DECISION logic lives in EmergencyLoanController.evaluateManual, a pure
-- function over an abstract account/session/actor/command (unit-tested offline). The Event
-- classes below are thin wire glue that resolve the actor from the connection and call it.
-- Native bindings (verified): UserManager:getUserIdByConnection (users/UserManager.lua:90),
-- FSBaseMission:getFarmId (FSBaseMission.lua:1067), Farm:isUserFarmManager (Farm.lua:419).
-- =========================================================

EmergencyLoanController = EmergencyLoanController or {}

-- Whitelisted operation codes (positive small ints on the wire).
EmergencyLoanController.OP = {
    VIEW                = 1,
    BORROW_QUOTE        = 2,
    MANUAL_AMOUNT_QUOTE = 3,
    PAYOFF_QUOTE        = 4,
    ACCEPT_QUOTE        = 5,
}
EmergencyLoanController.OP_NAME = {}
for name, code in pairs(EmergencyLoanController.OP) do EmergencyLoanController.OP_NAME[code] = name end

EmergencyLoanController.MAX_SEQUENCE = 2147483647  -- positive 31-bit
EmergencyLoanController.MAX_TOKEN_LEN = 64
EmergencyLoanController.MAX_AMOUNT_LEN = 32
-- [C3/F130] bounds for the forecast part of the reply wire.
EmergencyLoanController.MAX_CODE_LEN     = 32   -- status / reason / basis / sourceId text
EmergencyLoanController.MAX_COST_ENTRIES = 8    -- known or estimated cost rows per reply
EmergencyLoanController.MAX_MISSING_LEN  = 255  -- comma-joined missingInputs codes

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- Validate a decimal-text amount (<=32 ASCII, finite). Returns the number or nil.
function EmergencyLoanController.parseAmount(text)
    if type(text) ~= "string" or #text == 0 or #text > EmergencyLoanController.MAX_AMOUNT_LEN then return nil end
    if text:find("[^0-9eE%.%+%-]") ~= nil then return nil end
    local n = tonumber(text)
    if not finite(n) then return nil end
    return n
end

--- Encode a money value as the same finite decimal text the wire accepts back.
--- nil/non-finite/over-length encodes as "" so an UNKNOWN amount stays unknown on the
--- far side instead of arriving as a confident zero. Never truncates a number to fit.
function EmergencyLoanController.encodeAmount(v)
    if v == nil then return "" end
    local n = tonumber(v)
    if not finite(n) then return "" end
    local text = string.format("%.6f", n)
    if #text > EmergencyLoanController.MAX_AMOUNT_LEN then return "" end
    return text
end

--- Bounded code text for the wire ("" carries nil).
function EmergencyLoanController.encodeCode(v)
    if v == nil then return "" end
    return tostring(v):sub(1, EmergencyLoanController.MAX_CODE_LEN)
end

--- "" reads back as nil (unknown), never as an empty reason.
function EmergencyLoanController.decodeCode(text)
    if type(text) ~= "string" or text == "" then return nil end
    return text
end

--- Non-negative whole day/ms values; -1 carries nil so unknown never reads as day 0.
function EmergencyLoanController.encodeOptInt(v)
    local n = tonumber(v)
    if n == nil or n ~= n or n < 0 or n > EmergencyLoanController.MAX_SEQUENCE then return -1 end
    return math.floor(n)
end

function EmergencyLoanController.decodeOptInt(n)
    if type(n) ~= "number" or n < 0 then return nil end
    return n
end

--- missingInputs as one bounded comma-joined string (codes are [A-Z_] words).
function EmergencyLoanController.encodeMissing(list)
    if type(list) ~= "table" then return "" end
    local parts = {}
    for _, code in ipairs(list) do
        local c = tostring(code):gsub("[^%w_]", "")
        if c ~= "" then parts[#parts + 1] = c end
    end
    return table.concat(parts, ","):sub(1, EmergencyLoanController.MAX_MISSING_LEN)
end

function EmergencyLoanController.decodeMissing(text)
    local list = {}
    if type(text) ~= "string" then return list end
    for code in text:gmatch("[^,]+") do list[#list + 1] = code end
    return list
end

--- Core money-safety decision for a manual repay/payoff command against one account.
--- Pure: mutates only the passed `state` and `session` (which stand in for the real
--- debt snapshot and the per-connection session cache). Mirrors the session-cache and
--- rights rules exactly so the owner can never double-charge or move a stale amount.
---@param state table   { farmId, cash, principal, interest, revision, terms, ready }
---@param session table { id, highest, lastCommand, lastResult }
---@param actor table   { farmId, manager, session }
---@param cmd table      { sequence, operation, farmId, amount, revision, terms, quote, session }
---@param apply fun(state, amount)  applies an approved payment (interest-first) to state
---@return table result
function EmergencyLoanController.evaluateManual(state, session, actor, cmd, apply)
    local function debtTotal(s) return (s.principal or 0) + (s.interest or 0) end

    if actor.farmId ~= state.farmId or cmd.farmId ~= state.farmId then
        return { status = "WRONG_FARM" }
    end
    if actor.session ~= session.id or cmd.session ~= session.id then
        return { status = "WRONG_SESSION" }
    end
    if cmd.sequence < session.highest then return { status = "OLD_SEQUENCE" } end
    if cmd.sequence == session.highest then
        -- Exact retry of the last command returns its cached result; a different payload
        -- on the same reserved sequence is refused (never silently moves a new sum).
        if EmergencyLoanController._samePayload(cmd, session.lastCommand) then
            return session.lastResult
        end
        return { status = "CHANGED_PAYLOAD" }
    end

    if actor.manager ~= true then return { status = "NOT_MANAGER" } end

    local result
    if not state.ready then
        result = { status = "UNAVAILABLE" }
    elseif cmd.operation ~= "repay" then
        result = { status = "WRONG_OPERATION" }
    elseif cmd.revision ~= state.revision or cmd.terms ~= state.terms then
        result = { status = "STALE_QUOTE" }
    elseif not finite(cmd.amount) or cmd.amount <= 0 or cmd.amount > debtTotal(state) then
        result = { status = "INVALID_AMOUNT" }
    elseif cmd.amount > state.cash then
        result = { status = "INSUFFICIENT_CASH" }
    else
        -- Reserve the sequence BEFORE applying the financial action.
        session.highest = cmd.sequence
        apply(state, cmd.amount)
        result = { status = "ACCEPTED", amount = cmd.amount, revision = state.revision }
    end

    session.highest = cmd.sequence
    session.lastCommand = EmergencyLoanController._copyCommand(cmd)
    session.lastResult = result
    return result
end

function EmergencyLoanController._samePayload(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.operation == b.operation and a.farmId == b.farmId and a.amount == b.amount
        and a.revision == b.revision and a.terms == b.terms and a.quote == b.quote
        and a.session == b.session
end

function EmergencyLoanController._copyCommand(cmd)
    local c = {}
    for k, v in pairs(cmd) do c[k] = v end
    return c
end

-- =========================================================
-- Actor resolution (server, from the authenticated connection)
-- =========================================================

--- Resolve { userId, farmId, farm, isManager } from a connection, or nil + reason.
--- Rejects nil / the native -1 userId sentinel and the spectator/invalid farm. For the
--- local host requires the real g_localPlayer; a dedicated nil connection is not an actor.
function EmergencyLoanController.resolveActor(connection)
    local mission = g_currentMission
    if mission == nil then return nil, "NO_MISSION" end

    local userId
    if connection ~= nil and mission.userManager ~= nil and mission.userManager.getUserIdByConnection ~= nil then
        userId = mission.userManager:getUserIdByConnection(connection)
    elseif g_localPlayer ~= nil then
        userId = g_localPlayer.userId
    end
    if type(userId) ~= "number" or userId < 0 or userId == -1 then
        return nil, "NO_ACTOR"
    end

    local farmId
    if connection ~= nil and mission.getFarmId ~= nil then
        local ok, fid = pcall(function() return mission:getFarmId(connection) end)
        if ok then farmId = fid end
    end
    if farmId == nil and g_localPlayer ~= nil then farmId = g_localPlayer.farmId end

    local fm = g_farmManager
    local farm = nil
    if fm ~= nil and fm.getFarmById ~= nil and type(farmId) == "number" then
        local ok, f = pcall(function() return fm:getFarmById(farmId) end)
        if ok then farm = f end
    end
    if farm == nil or not EmergencyLoanController._isRealFarm(fm, farmId) then
        return nil, "INVALID_FARM"
    end

    local isManager = false
    if farm.isUserFarmManager ~= nil then
        local ok, m = pcall(function() return farm:isUserFarmManager(userId) end)
        if ok then isManager = m == true end
    end
    return { userId = userId, farmId = farmId, farm = farm, isManager = isManager }, nil
end

function EmergencyLoanController._isRealFarm(fm, farmId)
    if type(farmId) ~= "number" or farmId <= 0 then return false end
    local spectator = (fm ~= nil and fm.SPECTATOR_FARM_ID) or 0
    local tour      = (fm ~= nil and fm.GUIDED_TOUR_FARM_ID) or 14
    local invalid   = (fm ~= nil and fm.INVALID_FARM_ID) or 15
    return farmId ~= spectator and farmId ~= tour and farmId ~= invalid
end

-- =========================================================
-- Owner request/reply Events (thin wire glue)
-- =========================================================
-- A single class carries both directions via an isReply flag. The request is sent by a
-- client to the server (g_client:getServerConnection():sendEvent); the reply is sent back
-- only to the requesting connection. Registered via InitEventClass so the net id resolves.

EmergencyLoanEvent = EmergencyLoanEvent or {}
local EmergencyLoanEvent_mt = Class(EmergencyLoanEvent, Event)
InitEventClass(EmergencyLoanEvent, "EmergencyLoanEvent")

function EmergencyLoanEvent.emptyNew()
    return Event.new(EmergencyLoanEvent_mt)
end

--- Build a client->server request.
function EmergencyLoanEvent.newRequest(sequence, operation, amountText, token)
    local self = EmergencyLoanEvent.emptyNew()
    self.isReply   = false
    self.sequence  = sequence or 1
    self.operation = operation or EmergencyLoanController.OP.VIEW
    self.amountText = amountText or ""
    self.token     = token or ""
    return self
end

--- Build a server->client reply (compact: status + the essential view numbers). The
--- rich view is held server-side; the client caches this reply for its local farm.
function EmergencyLoanEvent.newReply(payload)
    local self = EmergencyLoanEvent.emptyNew()
    self.isReply = true
    self.payload = payload or {}
    return self
end

function EmergencyLoanEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isReply == true)
    if not self.isReply then
        streamWriteUIntN(streamId, math.max(1, math.min(self.sequence, EmergencyLoanController.MAX_SEQUENCE)), 31)
        streamWriteUInt8(streamId, self.operation or 1)
        streamWriteString(streamId, (self.amountText or ""):sub(1, EmergencyLoanController.MAX_AMOUNT_LEN))
        streamWriteString(streamId, (self.token or ""):sub(1, EmergencyLoanController.MAX_TOKEN_LEN))
    else
        local p = self.payload or {}
        streamWriteString(streamId, tostring(p.status or "UNAVAILABLE"))
        streamWriteUIntN(streamId, math.max(0, math.min(tonumber(p.sequence) or 0, EmergencyLoanController.MAX_SEQUENCE)), 31)
        -- Essential money fields as validated decimal text (coercion-proof on the wire).
        streamWriteString(streamId, string.format("%.6f", tonumber(p.cash) or 0))
        streamWriteString(streamId, string.format("%.6f", tonumber(p.outstanding) or 0))
        streamWriteString(streamId, string.format("%.6f", tonumber(p.offer) or 0))
        streamWriteBool(streamId, p.canBorrow == true)
        streamWriteBool(streamId, p.canRepay == true)
        streamWriteString(streamId, tostring(p.token or ""):sub(1, EmergencyLoanController.MAX_TOKEN_LEN))
        -- The EXACT amount this quote binds, so the client confirms the server's sum
        -- rather than the one the player typed. "" when no quote is attached.
        streamWriteString(streamId, EmergencyLoanController.encodeAmount(p.quoteAmount))
        EmergencyLoanEvent.writeForecast(streamId, p)
    end
end

-- [C3/F130] The forecast/debt detail of the version-1 view, appended AFTER the compact
-- fields above so the read side stays in step. Money is nil-preserving decimal text
-- (encodeAmount), codes are bounded strings, day counters carry -1 for unknown, and
-- the two cost lists are capped at MAX_COST_ENTRIES rows. Read order mirrors write order.
function EmergencyLoanEvent.writeForecast(streamId, p)
    local C = EmergencyLoanController
    streamWriteUInt8(streamId, math.max(0, math.min(tonumber(p.version) or 0, 255)))
    streamWriteUInt8(streamId, math.max(0, math.min(tonumber(p.farmId) or 0, 255)))
    streamWriteUIntN(streamId, math.max(0, math.min(tonumber(p.revision) or 0, C.MAX_SEQUENCE)), 31)
    streamWriteString(streamId, C.encodeCode(p.readiness))
    streamWriteString(streamId, C.encodeAmount(p.principal))
    streamWriteString(streamId, C.encodeAmount(p.accruedInterest))
    streamWriteString(streamId, C.encodeAmount(p.nativeLoan))
    streamWriteUInt8(streamId, math.max(0, math.min(tonumber(p.drawCount) or 0, 255)))
    streamWriteString(streamId, C.encodeAmount(p.effectiveMonthlyRate))
    streamWriteString(streamId, C.encodeCode(p.costLockReason))
    streamWriteString(streamId, C.encodeAmount(p.automaticRepaymentShare))
    streamWriteString(streamId, C.encodeCode(p.forecastStatus))
    streamWriteInt32(streamId, C.encodeOptInt(type(p.asOf) == "table" and p.asOf.monotonicDay or nil))
    streamWriteInt32(streamId, C.encodeOptInt(type(p.horizonEnd) == "table" and p.horizonEnd.monotonicDay or nil))
    streamWriteString(streamId, C.encodeAmount(p.minimumBalance))
    streamWriteString(streamId, C.encodeAmount(p.shortfall))
    streamWriteString(streamId, C.encodeAmount(p.expectedGrossIncome))
    streamWriteString(streamId, C.encodeAmount(p.expectedNetIncome))
    streamWriteString(streamId, C.encodeCode(p.workingCashBasis))
    streamWriteString(streamId, C.encodeAmount(p.workingCashAmount))
    EmergencyLoanEvent.writeCostList(streamId, p.knownCosts)
    EmergencyLoanEvent.writeCostList(streamId, p.estimatedCosts)
    streamWriteString(streamId, C.encodeMissing(p.missingInputs))
    streamWriteString(streamId, C.encodeCode(p.borrowReason))
    streamWriteString(streamId, C.encodeCode(p.repayReason))
end

function EmergencyLoanEvent.readForecast(streamId, p)
    local C = EmergencyLoanController
    p.version                 = streamReadUInt8(streamId)
    local farmId              = streamReadUInt8(streamId)
    p.farmId                  = (farmId ~= nil and farmId > 0) and farmId or nil
    p.revision                = streamReadUIntN(streamId, 31)
    p.readiness               = C.decodeCode(streamReadString(streamId))
    p.principal               = C.parseAmount(streamReadString(streamId))
    p.accruedInterest         = C.parseAmount(streamReadString(streamId))
    p.nativeLoan              = C.parseAmount(streamReadString(streamId))
    p.drawCount               = streamReadUInt8(streamId)
    p.effectiveMonthlyRate    = C.parseAmount(streamReadString(streamId))
    p.costLockReason          = C.decodeCode(streamReadString(streamId))
    p.automaticRepaymentShare = C.parseAmount(streamReadString(streamId))
    p.forecastStatus          = C.decodeCode(streamReadString(streamId))
    local asOfDay             = C.decodeOptInt(streamReadInt32(streamId))
    local horizonDay          = C.decodeOptInt(streamReadInt32(streamId))
    p.asOf                    = asOfDay and { monotonicDay = asOfDay } or nil
    p.horizonEnd              = horizonDay and { monotonicDay = horizonDay } or nil
    p.minimumBalance          = C.parseAmount(streamReadString(streamId))
    p.shortfall               = C.parseAmount(streamReadString(streamId))
    p.expectedGrossIncome     = C.parseAmount(streamReadString(streamId))
    p.expectedNetIncome       = C.parseAmount(streamReadString(streamId))
    p.workingCashBasis        = C.decodeCode(streamReadString(streamId))
    p.workingCashAmount       = C.parseAmount(streamReadString(streamId))
    p.knownCosts              = EmergencyLoanEvent.readCostList(streamId)
    p.estimatedCosts          = EmergencyLoanEvent.readCostList(streamId)
    p.missingInputs           = C.decodeMissing(streamReadString(streamId))
    p.borrowReason            = C.decodeCode(streamReadString(streamId))
    p.repayReason             = C.decodeCode(streamReadString(streamId))
    return p
end

--- A bounded list of { sourceId, amount, basis, dueDay, dueTimeMs } rows. A nil list
--- writes 0 rows; the reader always returns a table so the band can sum it.
function EmergencyLoanEvent.writeCostList(streamId, list)
    local C = EmergencyLoanController
    local n = 0
    if type(list) == "table" then n = math.min(#list, C.MAX_COST_ENTRIES) end
    streamWriteUInt8(streamId, n)
    for i = 1, n do
        local e = type(list[i]) == "table" and list[i] or {}
        streamWriteString(streamId, C.encodeCode(e.sourceId))
        streamWriteString(streamId, C.encodeAmount(e.amount))
        streamWriteString(streamId, C.encodeCode(e.basis))
        streamWriteInt32(streamId, C.encodeOptInt(e.dueDay))
        streamWriteInt32(streamId, C.encodeOptInt(e.dueTimeMs))
    end
end

function EmergencyLoanEvent.readCostList(streamId)
    local C = EmergencyLoanController
    local n = streamReadUInt8(streamId) or 0
    local list = {}
    for i = 1, n do
        list[i] = {
            sourceId  = C.decodeCode(streamReadString(streamId)),
            amount    = C.parseAmount(streamReadString(streamId)),
            basis     = C.decodeCode(streamReadString(streamId)),
            dueDay    = C.decodeOptInt(streamReadInt32(streamId)),
            dueTimeMs = C.decodeOptInt(streamReadInt32(streamId)),
        }
    end
    return list
end

function EmergencyLoanEvent:readStream(streamId, connection)
    self.isReply = streamReadBool(streamId)
    if not self.isReply then
        self.sequence   = streamReadUIntN(streamId, 31)
        self.operation  = streamReadUInt8(streamId)
        self.amountText = streamReadString(streamId)
        self.token      = streamReadString(streamId)
    else
        self.payload = {
            status      = streamReadString(streamId),
            sequence    = streamReadUIntN(streamId, 31),
            cash        = tonumber(streamReadString(streamId)),
            outstanding = tonumber(streamReadString(streamId)),
            offer       = tonumber(streamReadString(streamId)),
            canBorrow   = streamReadBool(streamId),
            canRepay    = streamReadBool(streamId),
            token       = streamReadString(streamId),
            quoteAmount = EmergencyLoanController.parseAmount(streamReadString(streamId)),
        }
        EmergencyLoanEvent.readForecast(streamId, self.payload)
    end
    self:run(connection)
end

function EmergencyLoanEvent:run(connection)
    local mgr = g_IncomeManager
    if mgr == nil then return end
    if not self.isReply then
        -- Server: handle the request and reply to THIS connection only.
        if g_server == nil then return end
        local reply = mgr:handleEmergencyLoanRequest(self, connection)
        if connection ~= nil then
            connection:sendEvent(EmergencyLoanEvent.newReply(reply))
        end
    else
        -- Client: cache the reply as this farm's last authoritative view.
        mgr:onEmergencyLoanReply(self.payload)
    end
end
