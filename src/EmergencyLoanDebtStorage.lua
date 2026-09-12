-- =========================================================
-- FS25 Income Mod - EMERGENCY LOAN debt storage (C3 / RSF-F130)
-- =========================================================
-- The host-owned debt XML: an isolated savegame file so the emergency debt persists
-- STANDALONE (no StateLedger required). This fixes the standalone debt loss - the early
-- version kept debt only via StateLedger, so without that bedrock a reload dropped the
-- whole ledger. Written in the active save window (FSCareerMissionInfo.saveToXMLFile)
-- alongside the timer/settings work, never as a delete-only fallback.
--
-- Money is stored as CANONICAL NUMERIC STRINGS and validated on read: the core number
-- serializer coerces an invalid number to zero, which would silently forgive debt. The
-- reader parses + validates before converting; counts/months/flags use typed ints/bools.
-- =========================================================

EmergencyLoanDebtStorage = EmergencyLoanDebtStorage or {}

EmergencyLoanDebtStorage.FILE = "FS25_IncomeMod_emergencyDebt.xml"
EmergencyLoanDebtStorage.ROOT = "emergencyDebt"

local function finiteNonNeg(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v >= 0
end

--- Write the loan's debts to the isolated XML. Server-only; no-op without a save dir.
---@param loan EmergencyLoan
---@param missionInfo table
---@return boolean written
function EmergencyLoanDebtStorage.save(loan, missionInfo)
    if loan == nil then return false end
    local dir = missionInfo and missionInfo.savegameDirectory
    if not dir then return false end
    local path = dir .. "/" .. EmergencyLoanDebtStorage.FILE
    local xml = XMLFile.create("im_emergencyDebt", path, EmergencyLoanDebtStorage.ROOT)
    if xml == nil then
        Logging.warning("Income Mod: emergency debt save failed to create %s", path)
        return false
    end
    local root = EmergencyLoanDebtStorage.ROOT
    xml:setInt(root .. "#schema", EmergencyLoan.SCHEMA or 2)

    local i = 0
    for farmId, d in pairs(loan.debts or {}) do
        if type(farmId) == "number" then
            local key = string.format("%s.farm(%d)", root, i)
            xml:setInt(key .. "#farmId", farmId)
            -- Money as canonical strings (full precision, coercion-proof).
            xml:setString(key .. "#principal", string.format("%.6f", d.principal or 0))
            xml:setString(key .. "#accruedInterest", string.format("%.6f", d.accruedInterest or 0))
            xml:setInt(key .. "#drawCount", d.drawCount or 1)
            xml:setInt(key .. "#revision", d.revision or 1)
            xml:setBool(key .. "#active", d.active ~= false)
            if d.lastSettledMonth ~= nil then xml:setInt(key .. "#lastSettledMonth", d.lastSettledMonth) end
            if d.interestEligibleFromMonth ~= nil then xml:setInt(key .. "#interestEligibleFromMonth", d.interestEligibleFromMonth) end
            local pj = 0
            for _, p in ipairs(d.pendingEligibility or {}) do
                local pkey = string.format("%s.pending(%d)", key, pj)
                xml:setString(pkey .. "#principal", string.format("%.6f", p.principal or 0))
                xml:setString(pkey .. "#accruedInterest", string.format("%.6f", p.accruedInterest or 0))
                if p.eligibleFromMonth ~= nil then xml:setInt(pkey .. "#eligibleFromMonth", p.eligibleFromMonth) end
                pj = pj + 1
            end
            i = i + 1
        end
    end

    xml:save()
    xml:delete()
    return true
end

--- Load a validated snapshot (the serialize()-shaped table) from the isolated XML.
--- Returns:
---   table  a valid snapshot (possibly explicitly empty) to install, OR
---   nil    when no file exists (a brand-new career / pre-C3 save), OR
---   false  when a file exists but is malformed/unsupported (caller => UNAVAILABLE,
---          retain and block mutation; never treat as fresh debt-free state).
---@param missionInfo table
---@return table|nil|false
function EmergencyLoanDebtStorage.load(missionInfo)
    local dir = missionInfo and missionInfo.savegameDirectory
    if not dir then return nil end
    local path = dir .. "/" .. EmergencyLoanDebtStorage.FILE
    local xml = XMLFile.loadIfExists("im_emergencyDebt", path, EmergencyLoanDebtStorage.ROOT)
    if xml == nil then return nil end  -- no file: nothing to restore

    local root = EmergencyLoanDebtStorage.ROOT
    local schema = xml:getInt(root .. "#schema", 0)
    if schema <= 0 or schema > (EmergencyLoan.SCHEMA or 2) then
        xml:delete()
        return false  -- unknown/future schema: malformed/unsupported, not empty
    end

    local debts = {}
    local ok = true
    xml:iterate(root .. ".farm", function(_, key)
        local farmId = xml:getInt(key .. "#farmId")
        local principal = tonumber(xml:getString(key .. "#principal"))
        local accrued = tonumber(xml:getString(key .. "#accruedInterest"))
        if type(farmId) ~= "number" or farmId <= 0
            or not finiteNonNeg(principal) or not finiteNonNeg(accrued) then
            ok = false
            return
        end
        local pending = {}
        xml:iterate(key .. ".pending", function(_, pkey)
            local pp = tonumber(xml:getString(pkey .. "#principal")) or 0
            local pi = tonumber(xml:getString(pkey .. "#accruedInterest")) or 0
            pending[#pending + 1] = {
                principal = finiteNonNeg(pp) and pp or 0,
                accruedInterest = finiteNonNeg(pi) and pi or 0,
                eligibleFromMonth = xml:getInt(pkey .. "#eligibleFromMonth"),
            }
        end)
        debts[farmId] = {
            principal = principal,
            accruedInterest = accrued,
            drawCount = xml:getInt(key .. "#drawCount", 1),
            revision = xml:getInt(key .. "#revision", 1),
            active = xml:getBool(key .. "#active", (principal + accrued) > 0),
            lastSettledMonth = xml:getInt(key .. "#lastSettledMonth"),
            interestEligibleFromMonth = xml:getInt(key .. "#interestEligibleFromMonth"),
            pendingEligibility = pending,
        }
    end)
    xml:delete()

    if not ok then return false end  -- a malformed row: the whole primary is unavailable
    return { schema = schema, debts = debts }  -- valid (explicit-empty is authoritative)
end
