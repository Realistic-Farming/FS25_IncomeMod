--!load: tools/test/lua/f282_environment_model.lua, src/settings/Settings.lua, src/IncomeSystem.lua
-- RSF-F282, IncomeMod half: a clock set backwards inside one day is not elapsed time.
-- Before this repair countElapsedHours read a same-day rewind from hour 20 to hour 10
-- as fourteen transitions ((10 - 20) % 24) and paid them. Now a lower hour on an
-- unchanged monotonic day, or a lower monotonic day, is a rewind: nothing is paid,
-- the markers re-baseline, the event is logged, and the next ordinary transition
-- settles once.
--
-- THE ENTRY-POINT BAR IS GROUP A: the REAL Settings and the REAL IncomeSystem,
-- initialized from the environment as production does (IncomeSystem:initialize), then
-- driven through IncomeSystem:update(dt) as the manager drives it each frame, against
-- the engine's own clock (f282_environment_model.lua: updateTimeValues and
-- setEnvironmentTime verbatim from Environment.lua, consoleCommandSetDayTime through its
-- arithmetic with the brief's reading of its empty lower-time branch). No marker, count or
-- payment is written by hand; the only mocks are the mission's money sink and the
-- log sink.
--
-- Groups:
--   A  hourly mode: a forward hour pays once; a same-day rewind through the console
--      setter pays nothing and re-baselines; the next hour pays once; a forward set
--      catches up as before; midnight settles once; a multi-day jump keeps the ceiling
--   R  the reload case only IncomeMod has: persisted markers ahead of the environment
--   D  daily mode: a backward day pays nothing; a same-day rewind never fires
--   L  without the monotonic counter the modulo path is unchanged (said, not hidden)
--   S  a rewind while sleeping re-baselines and logs no skipped payment
--   G  the log line, once per rewind event

local HOUR, DAY = F282Env.HOUR, F282Env.DAY
-- The manager checks once per game minute (IncomeSystem:update throttles on the minute).
-- A real day of frames crosses 1,440 minute boundaries; the fixture's single day-long tick
-- must land on a different minute too, or the throttle hides the day it just crossed.
local DAY_AND_A_MINUTE = DAY + 60000
local MINUTE = 60000

local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end

-- ── the world: the engine's clock, a mission that records money, a log sink ────
local paid, logs = {}, {}
local function world(opts)
    local env = F282Env.new(opts)
    paid, logs = {}, {}
    -- A singleplayer mission: the server and a client at once, so the payment path runs
    -- to its notification (the HUD sink is the mock, as the money sink is).
    g_currentMission = {
        environment = env,
        getIsServer = function() return true end,
        getIsClient = function() return true end,
        getFarmId = function() return 1 end,
        addMoney = function(_, amount, farmId, moneyType, notify) paid[#paid + 1] = { amount = amount, farmId = farmId } end,
        addIngameNotification = function() end,
    }
    FSBaseMission = FSBaseMission or { INGAME_NOTIFICATION_OK = 1 }
    g_i18n.formatMoney = g_i18n.formatMoney or function(_, v) return tostring(v) end
    g_farmManager = nil
    g_sleepManager = nil
    g_IncomeManager = nil
    -- The log sink never crashes the bar: a mutation that logs a nil counter must fail
    -- by assertion, not by a format error (a crash is an unattributable kill).
    Logging.info = function(msg, ...)
        local ok, line = pcall(string.format, msg, ...)
        logs[#logs + 1] = ok and line or tostring(msg)
    end
    return env
end
local function paidSummary()
    local total = 0
    for _, p in ipairs(paid) do total = total + p.amount end
    return #paid .. ":" .. num(total)
end
local function rewindLines()
    local n = 0
    for _, l in ipairs(logs) do if l:find("Clock moved backwards", 1, true) then n = n + 1 end end
    return n
end
local function skippedLines()
    local n = 0
    for _, l in ipairs(logs) do if l:find("Skipped", 1, true) then n = n + 1 end end
    return n
end
--- The real system, as the manager builds it: settings with a fixed amount and no
--- seasonal effect, initialized from the environment.
local function system(payMode)
    local settings = Settings.new(nil)
    settings.enabled = true
    settings.debugMode = true
    settings.seasonalEffects = false
    settings.customAmount = 100
    settings.multiplier = settings.multiplier or 1
    settings.payMode = payMode or Settings.PAY_MODE_HOURLY
    local sys = IncomeSystem.new(settings)
    sys:initialize()
    return sys
end
local function markers(sys) return sys.lastDay .. "[" .. sys.lastMonotonicDay .. "]:" .. sys.lastHour end
--- One frame after the clock moved: the update the manager calls each frame.
local function frame(sys, env, ms)
    if ms then F282Env.tick(env, ms) end
    sys:update(16)
end

-- ══════════════════════════════════════════════════════════════════════════
-- A. HOURLY MODE, THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
do
    local env = world({ day = 3, hour = 8 })
    local sys = system()
    T.eq("A1 [reached] the real system initialized its markers from the environment", markers(sys) .. "/" .. tostring(sys.isInitialized), "3[3]:8/true")
    T.eq("A1b [world] the fixed payment amount is 100", num(sys.settings:getPaymentAmount()), "100")
    frame(sys, env, HOUR)
    T.eq("A2 [world then system] one forward hour pays once", env.currentHour .. " " .. paidSummary(), "9 1:100")
    F282Env.consoleCommandSetDayTime(env, 20)
    frame(sys, env)
    T.eq("A3 a forward set to 20:00 catches up the eleven hours it skipped, as before", env.currentHour .. " " .. paidSummary() .. " " .. markers(sys), "20 2:1200 3[3]:20")
    -- THE REWIND: gsSetDayTime 10 at 20:00 on the same day.
    F282Env.consoleCommandSetDayTime(env, 10)
    frame(sys, env)
    T.eq("A4 [world] the console setter held the day and the monotonic day and lowered the hour", env.currentDay .. "[" .. env.currentMonotonicDay .. "]:" .. env.currentHour, "3[3]:10")
    T.eq("A5 the rewind pays NOTHING (before: fourteen hours), the markers re-baseline to 10:00, and the event is logged once",
        paidSummary() .. " " .. markers(sys) .. " " .. rewindLines(), "2:1200 3[3]:10 1")
    frame(sys, env, HOUR)
    T.eq("A6 the next ordinary hour settles once from the new position", env.currentHour .. " " .. paidSummary(), "11 3:1300")
    F282Env.consoleCommandSetDayTime(env, 23)
    frame(sys, env)
    frame(sys, env, HOUR)
    T.eq("A7 a genuine midnight crossing still settles exactly once (day 4, hour 0)", env.currentDay .. "[" .. env.currentMonotonicDay .. "]:" .. env.currentHour .. " " .. paidSummary(), "4[4]:0 5:2600")
    F282Env.setEnvironmentTime(env, env.currentMonotonicDay + 2, env.currentDay + 2, env.dayTime + MINUTE, env.daysPerPeriod)
    frame(sys, env)
    T.eq("A8 a two-day forward jump catches up under the existing ceiling (48 hours clamped to 24), unchanged", env.currentMonotonicDay .. " " .. paidSummary(), "6 6:5000")
    T.eq("A9 no rewind was read into any forward movement", rewindLines(), 1)
end

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE RELOAD CASE ONLY INCOMEMOD HAS: PERSISTED MARKERS AHEAD OF THE CLOCK
-- ══════════════════════════════════════════════════════════════════════════
do
    local env = world({ day = 4, hour = 0 })
    local sys = system()
    sys:loadState({ lastHour = 20, lastDay = 9, lastMonotonicDay = 9 })
    T.eq("R1 [world] the persisted markers sit five days ahead of the loaded environment", markers(sys), "9[9]:20")
    frame(sys, env, MINUTE)
    T.eq("R2 the first check reads that as a rewind: nothing paid, markers re-baselined to the environment, logged",
        paidSummary() .. " " .. markers(sys) .. " " .. rewindLines(), "0:0 4[4]:0 1")
    frame(sys, env, HOUR)
    T.eq("R3 the next hour pays once", paidSummary(), "1:100")
end

-- ══════════════════════════════════════════════════════════════════════════
-- D. DAILY MODE
-- ══════════════════════════════════════════════════════════════════════════
do
    local env = world({ day = 3, hour = 20 })
    local sys = system(Settings.PAY_MODE_DAILY)
    frame(sys, env, DAY_AND_A_MINUTE)
    T.eq("D1 [world then system] a forward day pays once", env.currentDay .. " " .. paidSummary(), "4 1:100")
    F282Env.consoleCommandSetDayTime(env, 10)
    frame(sys, env)
    T.eq("D2 a same-day rewind fires no daily check at all: nothing paid, nothing logged", paidSummary() .. " " .. rewindLines(), "1:100 0")
    frame(sys, env, DAY_AND_A_MINUTE)
    T.eq("D3 the next day pays once", paidSummary(), "2:200")
    sys:loadState({ lastHour = 10, lastDay = 9, lastMonotonicDay = 9 })
    frame(sys, env, HOUR)
    T.eq("D4 markers ahead of the clock in daily mode: nothing paid, re-baselined, logged", paidSummary() .. " " .. markers(sys) .. " " .. rewindLines(), "2:200 5[5]:11 1")
    frame(sys, env, DAY_AND_A_MINUTE)
    T.eq("D5 and the next day pays once", paidSummary(), "3:300")
end

-- ══════════════════════════════════════════════════════════════════════════
-- L. WITHOUT THE MONOTONIC COUNTER
-- ══════════════════════════════════════════════════════════════════════════
do
    local env = world({ day = 3, hour = 20 })
    env.currentMonotonicDay = nil
    local sys = system()
    T.eq("L1 [world] no counter: the marker is -1", sys.lastMonotonicDay, -1)
    F282Env.consoleCommandSetDayTime(env, 10)
    env.currentMonotonicDay = nil
    frame(sys, env)
    T.eq("L2 without the counter a rewind cannot be told from a wrap: the modulo path is UNCHANGED and still pays fourteen hours (the brief's item 5, the discriminator needs the counter)",
        paidSummary() .. " " .. rewindLines(), "1:1400 0")
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. A REWIND WHILE SLEEPING
-- ══════════════════════════════════════════════════════════════════════════
do
    local env = world({ day = 3, hour = 20 })
    local sys = system()
    g_sleepManager = { getIsSleeping = function() return true end }
    F282Env.consoleCommandSetDayTime(env, 10)
    frame(sys, env)
    T.eq("S1 asleep, a rewind re-baselines and logs the rewind, not a skipped payment", paidSummary() .. " " .. markers(sys) .. " " .. rewindLines() .. " " .. skippedLines(), "0:0 3[3]:10 1 0")
    g_sleepManager = nil
    frame(sys, env, HOUR)
    T.eq("S2 awake, the next hour pays once", paidSummary(), "1:100")
end

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE LOG LINE
-- ══════════════════════════════════════════════════════════════════════════
do
    local env = world({ day = 3, hour = 20 })
    local sys = system()
    F282Env.consoleCommandSetDayTime(env, 15)
    frame(sys, env)
    F282Env.consoleCommandSetDayTime(env, 10)
    frame(sys, env)
    T.eq("G1 two rewinds, two lines, each naming the positions", rewindLines() .. " " .. tostring(logs[#logs]:find("Hour 15 back to Day 3%[3%] Hour 10") ~= nil), "2 true")
    frame(sys, env, HOUR)
    frame(sys, env, HOUR)
    T.eq("G2 forward hours add no rewind line", rewindLines() .. " " .. paidSummary(), "2 2:200")
end
