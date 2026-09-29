--!load: tools/test/lua/f282_environment_model.lua, src/ReleaseGate.lua, src/settings/SettingsManager.lua, src/settings/Settings.lua, src/IncomeSystem.lua, src/EmergencyLoan.lua, src/EmergencyLoanEvent.lua, src/IncomeSchedule.lua, src/settings/SettingsHubBridge.lua, src/settings/SettingsGUI.lua, src/settings/SettingsUI.lua, src/IncomeManager.lua
-- IM6-A-host_authority_test.lua - R17 / IM-6 PR A: the income schedule's host authority.
--
-- THE ENTRY-POINT BAR IS GROUP A, and every later group stands on it: the REAL
-- IncomeManager.new and IncomeManager:onMissionLoaded on a dedicated host and on its
-- clients. From there production itself reaches the REAL SettingsGUI console registration
-- (IncomeManager.new), the REAL IncomeSettingsHubBridge.register (onMissionLoaded), the
-- client's first VIEW request (onMissionLoaded), the REAL IncomeScheduleEvent
-- writeStream -> readStream -> run path over the #76 stream tape in both directions
-- (request to the host, reply to the requesting connection only, the view broadcast to
-- every client), and the REAL payout poll (IncomeManager:update -> IncomeSystem:update)
-- against the engine's clock (f282_environment_model.lua). Nothing pre-populates a view,
-- a revision, a payout marker, a pending callback or a registration the code under test
-- is supposed to produce. The Esc door enters through the REAL SettingsUI:inject and
-- SettingsUI:ensureResetButton and fires the option and button callbacks they install.
--
-- The world the fixture supplies (engine, GUI and persistence only): the missions, the
-- clock, the user manager (master user or not, per connection), two farms and the money
-- sink, the server's broadcast sink and each client's server connection, a SettingsHub
-- instance (registerModule), addConsoleCommand, the GUI (the UIHelper option factory,
-- the in-game settings page, YesNoDialog, InfoDialog) and SettingsManager's XML I/O (each
-- machine's settings file; saves counted).
--
-- Groups:
--   A  load: a client is WAITING until the host's view arrives, never its own default,
--      then holds the host's values; SettingsHub registered without the retired rows
--   B  a non-admin is refused at every door and nothing changes
--   C  an admin amount change over the wire; a second admin's stale preview refused
--   D  the console door: no confirm changes nothing; exponent, decimal, sign and grouping
--      refused; a new amount above 999999 refused
--   E  a mid-day mode change through the real poll: nothing paid at the switch, the next
--      interval pays once, the live instance rebased, the class table never written
--   F  Reset at the console, over the wire and at Esc: unconfirmed changes nothing;
--      confirmed restores every default and rebases mid-day with no switch payment
--   G  the Esc pay-mode door: a pick changes nothing until the host preview is
--      confirmed; a refusal is shown; a waiting client cannot choose
--   H  SettingsHub: the retired keys no-op through the registered callback; other rows write
--   I  display estimate: DISABLED keeps a hypothetical month; UNAVAILABLE carries none
--   J  a legacy amount above the cap is kept on a mode-only change, refused as a new amount
--   K  the wire: no tape faults; the host never takes a view from a connection; a
--      broadcast keeps each client's own capability; the throttled republish

local HOUR, MINUTE = F282Env.HOUR, 60000
local OP = IncomeSchedule.OP
local HOURLY, DAILY = Settings.PAY_MODE_HOURLY, Settings.PAY_MODE_DAILY

-- ── engine, GUI and persistence surface ──────────────────────────────────────
getfenv = getfenv or function() return _G end
Utils = Utils or {}
Utils.appendedFunction = Utils.appendedFunction or function(old, new)
    if old == nil then return new end
    return function(...) old(...); return new(...) end
end
FSBaseMission = { onConnectionClosed = function() end, INGAME_NOTIFICATION_OK = 1 }
EmergencyLoanDebtStorage = { save = function() end, load = function() return nil end }
g_i18n.formatMoney = function(_, v) return string.format("$%d", math.floor(v)) end
InputAction = { MENU_EXTRA_1 = 1 }
InGameMenu = {}
g_gui = nil
g_sleepManager = nil

-- SettingsManager's XML I/O: the settings file of the machine being built; saves counted.
local settingsFile, saves = nil, 0
SettingsManager.new = function()
    local file = settingsFile or {}
    return {
        loadSettings = function(_self, s) for k, v in pairs(file) do s[k] = v end end,
        saveSettings = function() saves = saves + 1 end,
        saveTimerState = function() end,
        loadTimerState = function() return nil end,
    }
end

-- addConsoleCommand: each machine's own console registry.
local console = nil
addConsoleCommand = function(name, _desc, funcName, target)
    console[name] = function(...) return target[funcName](target, ...) end
end

-- The GUI: dialogs recorded, answered by the test as a player would.
local dialogs, infos = {}, {}
YesNoDialog = { show = function(callback, target, text, title)
    dialogs[#dialogs + 1] = { callback = callback, target = target, text = text, title = title }
end }
InfoDialog = { show = function(text) infos[#infos + 1] = text end }
local function answer(yes)
    local d = dialogs[#dialogs]
    if d == nil then T.ok("a confirm was open to answer", false); return end
    dialogs[#dialogs] = nil
    d.callback(yes)
end

-- UIHelper: the settings page's option factory. Each option records its callback the
-- way UIHelper's onClickCallback delivers it (the 1-based index).
local options = {}
UIHelper = {
    createSection = function() return {} end,
    createBinaryOption = function(_layout, id, _text, state, callback)
        local o = { id = id, checked = state, callback = callback }
        function o:setIsChecked(v) self.checked = v end
        options[id] = o
        return o
    end,
    createMultiOption = function(_layout, id, _text, texts, state, callback)
        local o = { id = id, texts = texts, state = state, callback = callback, disabled = false }
        function o:setState(v) self.state = v end
        function o:setDisabled(v) self.disabled = v end
        options[id] = o
        return o
    end,
    getText = function(key) return key end,
}
local function click(id, index)
    local o = options[id]
    o.state = index
    o.callback(index)
end

-- ── the machines ─────────────────────────────────────────────────────────────
local host, clients = nil, {}
local users = {}                       -- the host's user manager: connection -> master user
local paid, broadcasts, hubModules = {}, {}, {}
local tapeFaults, replyErrors = 0, 0

local function asHost()
    g_currentMission = host.mission
    g_server = host.server
    g_client = nil
    g_IncomeManager = host.mgr
    g_farmManager = host.farmManager
end

local function asClient(c)
    g_currentMission = c.mission
    g_server = nil
    g_client = c.client
    g_IncomeManager = c.mgr
    g_farmManager = nil
end

local function newHost(file, opts)
    opts = opts or {}
    clients, users, paid, broadcasts, hubModules = {}, {}, {}, {}, {}
    dialogs, infos, options = {}, {}, {}
    saves = 0
    host = { console = {}, delivered = 0 }
    host.env = F282Env.new({ day = 3, hour = 8 })
    host.env.daysPerPeriod = opts.daysPerPeriod or 3
    host.server = { broadcastEvent = function(_self, ev, sendLocal)
        broadcasts[#broadcasts + 1] = { ev = ev, sendLocal = sendLocal }
    end }
    host.farmManager = { farms = { [1] = { farmId = 1 }, [2] = { farmId = 2 } } }
    host.mission = {
        environment = host.env, missionInfo = {},
        getIsServer = function() return true end,
        getIsClient = function() return opts.listen == true end,
        getFarmId = function() return nil end,
        addMoney = function(_, amount, farmId) paid[#paid + 1] = { amount = amount, farmId = farmId } end,
        addIngameNotification = function() end,
        userManager = { getUserByConnection = function(_self, conn)
            local master = users[conn]
            if master == nil then return nil end
            return { getIsMasterUser = function() return master end }
        end },
        settingsHub = { registerModule = function(_self, name, spec) hubModules[name] = spec end },
    }
    asHost()
    console, settingsFile = host.console, file
    host.mgr = IncomeManager.new(host.mission, "./", "FS25_IncomeMod")
    g_IncomeManager = host.mgr
    host.mgr:onMissionLoaded()
    saves = 0   -- loading is not an accepted change
    return host
end

local function newClient(name, master)
    local c = { name = name, outbox = {}, console = {} }
    c.conn = { sent = {} }            -- the host's connection object for this client
    function c.conn:sendEvent(ev) self.sent[#self.sent + 1] = ev end
    users[c.conn] = master
    c.env = F282Env.new({ day = 3, hour = 8 })
    c.env.daysPerPeriod = 3
    c.mission = {
        environment = c.env, missionInfo = {},
        getIsServer = function() return false end,
        getIsClient = function() return true end,
        getFarmId = function() return 1 end,
        addMoney = function() c.moneyWritten = true end,
        addIngameNotification = function() end,
    }
    c.client = { getServerConnection = function()
        return { sendEvent = function(_self, ev) c.outbox[#c.outbox + 1] = ev end }
    end }
    clients[#clients + 1] = c
    asClient(c)
    console, settingsFile = c.console, {}      -- a client's own file holds the defaults
    local savesBefore = saves
    c.mgr = IncomeManager.new(c.mission, "./", "FS25_IncomeMod")
    g_IncomeManager = c.mgr
    c.mgr:onMissionLoaded()
    saves = savesBefore
    return c
end

-- One event across the tape: written on one side, read (and run) on the other.
local function carry(ev, fromConn, toConn)
    local s = _sfMockStream()
    ev:writeStream(s, fromConn)
    IncomeScheduleEvent.emptyNew():readStream(s, toConn)
    tapeFaults = tapeFaults + _sfStreamFaults(s)
    if s.r ~= #s.q + 1 then tapeFaults = tapeFaults + 1 end
end

local function deliverBroadcasts()
    for i = host.delivered + 1, #broadcasts do
        for _, c in ipairs(clients) do
            asClient(c)
            carry(broadcasts[i].ev, nil, nil)
        end
    end
    host.delivered = #broadcasts
end

--- Everything the client has sent: each request read on the host (which serves it and
--- replies to that connection only), the broadcasts delivered, the reply read back on
--- the client. A reply handler that sends again is pumped too.
local function pump(c)
    while #c.outbox > 0 do
        local req = table.remove(c.outbox, 1)
        asHost()
        local before = #c.conn.sent
        carry(req, nil, c.conn)
        if #c.conn.sent ~= before + 1 then replyErrors = replyErrors + 1 end
        deliverBroadcasts()
        for i = before + 1, #c.conn.sent do
            asClient(c)
            carry(c.conn.sent[i], nil, nil)
        end
    end
    asClient(c)
end

-- Money crosses the wire as decimal text and reads back as a float. Lua 5.1 prints
-- 5000.0 as "5000"; the bench's Lua 5.3 prints "5000.0". Whole values are read back as
-- whole numbers here so a row compares what the game would show.
local function whole(view)
    if type(view) ~= "table" then return view end
    for k, v in pairs(view) do
        if type(v) == "number" and v == math.floor(v) then view[k] = math.floor(v) end
    end
    return view
end

local function ask(c, op, amountText, mode, revision, confirm)
    asClient(c)
    local got
    c.mgr:requestIncomeSchedule(op, amountText, mode, revision, confirm, function(r) got = r end)
    pump(c)
    if got ~= nil then whole(got.view) end
    return got
end

local function hostState()
    local s = host.mgr.settings
    return string.format("mode=%d amount=%s rev=%d saves=%d", s.payMode, tostring(s.customAmount),
        host.mgr.scheduleRevision, saves)
end

local function viewOf(c)
    asClient(c)
    return whole(c.mgr:getIncomeScheduleView())
end

-- The real poll, one frame after the clock moved.
local function hostFrame(ms)
    asHost()
    if ms then F282Env.tick(host.env, ms) end
    host.mgr:update(16)
end
local function hours(n) for _ = 1, n do hostFrame(HOUR) end end

local function paidSince(mark)
    local n, total = 0, 0
    for i = mark + 1, #paid do n = n + 1; total = total + paid[i].amount end
    return n .. ":" .. total
end

local function markers()
    local sys = host.mgr.incomeSystem
    return sys.lastDay .. "[" .. sys.lastMonotonicDay .. "]:" .. sys.lastHour
end
local function now() return host.env.currentDay .. "[" .. host.env.currentMonotonicDay .. "]:" .. host.env.currentHour end

local function classMarkers()
    return tostring(rawget(IncomeSystem, "lastHour")) .. " " .. tostring(rawget(IncomeSystem, "lastDay"))
        .. " " .. tostring(rawget(IncomeSystem, "lastMonotonicDay"))
end

-- ══════════════════════════════════════════════════════════════════════════════
-- A. LOAD: WAITING, THEN THE HOST'S VALUES (the entry-point bar)
-- ══════════════════════════════════════════════════════════════════════════════
do
    newHost({ payMode = DAILY, customAmount = 5000 })
    T.eq("A1 [world] the host loaded its saved schedule", hostState(), "mode=2 amount=5000 rev=1 saves=0")
    T.ok("A2 [reached] IncomeManager.new registered the three schedule commands on the host console",
        host.console.IncomeSetPayMode ~= nil and host.console.IncomeSetCustomAmount ~= nil and host.console.IncomeResetSettings ~= nil)
    local v = host.mgr:getIncomeScheduleView()
    T.eq("A3 the host's view is its own settings", v.unit .. " " .. v.amount .. " " .. v.payment .. " " .. v.paymentState,
        "PER_DAY 5000 5000 SCHEDULED")
    T.eq("A4 a full 3-day month pays 3 times, 15000 gross", v.daysThisMonth .. " " .. v.paymentsThisMonth .. " " .. v.monthEstimate,
        "3 3 15000")

    local admin = newClient("admin", true)
    T.eq("A5 [reached] the client's onMissionLoaded asked the host for its view", #admin.outbox, 1)
    local waiting = viewOf(admin)
    local extra = {}
    for k in pairs(waiting) do if k ~= "paymentState" then extra[#extra + 1] = k end end
    T.eq("A6 before the host answers the client is WAITING and carries nothing of its own",
        waiting.paymentState .. " [" .. table.concat(extra, ",") .. "]", "WAITING []")
    T.eq("A7 [world] the client's own settings file holds the defaults, not the host's", admin.mgr.settings.payMode .. " " .. admin.mgr.settings.customAmount, "1 0")
    pump(admin)
    local cv = viewOf(admin)
    T.eq("A8 after the reply the client holds the host's values",
        cv and (cv.unit .. " " .. cv.amount .. " " .. cv.payment .. " " .. cv.monthEstimate .. " " .. cv.revision), "PER_DAY 5000 5000 15000 1")
    T.eq("A9 an administrator is told it may edit", cv and cv.canEdit, true)
    local player = newClient("player", false)
    pump(player)
    T.eq("A10 a non-admin is told it may not edit", viewOf(player).canEdit, false)
    T.eq("A11 the client never wrote its own settings from the view", admin.mgr.settings.payMode .. " " .. admin.mgr.settings.customAmount, "1 0")
    T.eq("A12 a view request changed nothing on the host", hostState(), "mode=2 amount=5000 rev=1 saves=0")
    T.eq("A13 a view request broadcast nothing", #broadcasts, 0)

    local mod = hubModules.IncomeMod
    T.ok("A14 [reached] onMissionLoaded registered IncomeMod with SettingsHub", mod ~= nil)
    local ids, seen = {}, {}
    for _, d in ipairs(mod and mod.adminSettings or {}) do ids[#ids + 1] = d.id; seen[d.id] = true end
    T.eq("A15 the pay mode and amount rows are not declared", tostring(seen.payMode) .. " " .. tostring(seen.customAmount), "nil nil")
    T.eq("A16 every other row is kept", table.concat(ids, ","),
        "enabled,difficulty,incomeMultiplier,seasonalEffects,showNotifications,showHUD,debugMode,experimentalSystems")

    local gate = ReleaseGate.EXPERIMENTAL.im6_income_schedule
    T.eq("A17 the IM-6 surface is registered with the brief's status", gate and gate.status,
        "awaiting live multiplayer, player-surface and balance observations")
    T.eq("A18 it is LOCKED without the opt-in, while the host authority above runs in every build",
        tostring(ReleaseGate.isReleased("im6_income_schedule", false)) .. " " .. tostring(host.mgr.settings.experimentalSystems), "false false")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- B. A NON-ADMIN IS REFUSED AND NOTHING CHANGES
-- ══════════════════════════════════════════════════════════════════════════════
do
    newHost({ payMode = DAILY, customAmount = 5000 })
    local player = newClient("player", false)
    pump(player)
    local p = ask(player, OP.PREVIEW, "7000", DAILY, 0, false)
    T.eq("B1 a non-admin preview is refused NOT_ADMIN", p and p.status, "NOT_ADMIN")
    T.eq("B2 the refusal carries the unchanged view", p.view.amount .. " " .. p.view.unit, "5000 PER_DAY")
    local r = ask(player, OP.APPLY, "7000", HOURLY, host.mgr.scheduleRevision, false)
    T.eq("B3 a non-admin apply at the current revision is refused NOT_ADMIN", r and r.status, "NOT_ADMIN")
    T.eq("B4 nothing changed on the host", hostState(), "mode=2 amount=5000 rev=1 saves=0")
    T.eq("B5 nothing was broadcast", #broadcasts, 0)
    local rr = ask(player, OP.RESET_APPLY, "", 0, host.mgr.scheduleRevision, true)
    T.eq("B6 a non-admin confirmed reset is refused and changes nothing", rr.status .. " " .. hostState(), "NOT_ADMIN mode=2 amount=5000 rev=1 saves=0")
    asClient(player)
    T.eq("B7 a client's console sends the request and says so", player.console.IncomeSetCustomAmount("7000"),
        "Asked the host; the answer prints here when it arrives.")
    pump(player)
    T.eq("B8 the host refused the client console's request", hostState(), "mode=2 amount=5000 rev=1 saves=0")
    T.eq("B9 the client wrote no money and no local setting", tostring(player.moneyWritten) .. " " .. player.mgr.settings.customAmount, "nil 0")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- C. AN ADMIN AMOUNT CHANGE; A SECOND ADMIN'S STALE PREVIEW
-- ══════════════════════════════════════════════════════════════════════════════
do
    newHost({ payMode = DAILY, customAmount = 5000 })
    local a = newClient("a", true); pump(a)
    local b = newClient("b", true); pump(b)
    local pa = ask(a, OP.PREVIEW, "7000", 0, 0, false)
    T.eq("C1 preview OK with the resulting view", pa.status .. " " .. pa.view.amount .. " " .. pa.view.monthEstimate, "OK 7000 21000")
    T.eq("C2 [wire] the preview's revision crossed the wire", pa.revision, 1)
    T.eq("C3 a preview wrote nothing", hostState(), "mode=2 amount=5000 rev=1 saves=0")
    local pb = ask(b, OP.PREVIEW, "9000", 0, 0, false)
    local ra = ask(a, OP.APPLY, "7000", 0, pa.revision, false)
    T.eq("C4 the first admin's apply is accepted", ra.status, "OK")
    T.eq("C5 applied, saved once, revision advanced", hostState(), "mode=2 amount=7000 rev=2 saves=1")
    T.eq("C6 the accepted view was broadcast once, and not to the host itself", #broadcasts .. " " .. tostring(broadcasts[1] and broadcasts[1].sendLocal), "1 false")
    T.eq("C7 both clients now hold revision 2 and the new amount",
        viewOf(a).revision .. " " .. viewOf(a).amount .. " " .. viewOf(b).revision .. " " .. viewOf(b).amount, "2 7000 2 7000")
    local rb = ask(b, OP.APPLY, "9000", 0, pb.revision, false)
    T.eq("C8 the second admin's stale preview is refused", rb.status, "STALE_PREVIEW")
    T.eq("C9 the refusal carries the fresh view", rb.view.revision .. " " .. rb.view.amount, "2 7000")
    T.eq("C10 the stale apply changed nothing", hostState(), "mode=2 amount=7000 rev=2 saves=1")
    local r0 = ask(b, OP.APPLY, "9000", 0, 0, false)
    T.eq("C11 an amount-only apply without the current revision is refused", r0.status .. " " .. hostState(), "STALE_PREVIEW mode=2 amount=7000 rev=2 saves=1")
    local pb2 = ask(b, OP.PREVIEW, "9000", 0, 0, false)
    local rb2 = ask(b, OP.APPLY, "9000", 0, pb2.revision, false)
    T.eq("C12 a fresh preview then applies", rb2.status .. " " .. hostState(), "OK mode=2 amount=9000 rev=3 saves=2")
    local rx = ask(a, 9, "", 0, host.mgr.scheduleRevision, false)
    T.eq("C13 an unknown operation is refused and changes nothing", rx.status .. " " .. hostState(), "UNKNOWN_OPERATION mode=2 amount=9000 rev=3 saves=2")
    local rm = ask(a, OP.APPLY, "", 7, host.mgr.scheduleRevision, false)
    T.eq("C14 an unknown pay mode is refused and changes nothing", rm.status .. " " .. hostState(), "UNKNOWN_PAY_MODE mode=2 amount=9000 rev=3 saves=2")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- D. THE CONSOLE DOOR (a dedicated server's console is the server actor)
-- ══════════════════════════════════════════════════════════════════════════════
do
    newHost({ payMode = DAILY, customAmount = 5000 })
    asHost()
    local out = host.console.IncomeSetPayMode("1")
    T.ok("D1 without confirm the console prints the consequence and how to apply",
        out:find("Pay mode: Hourly, one payment every in-game hour", 1, true) ~= nil
        and out:find("Nothing changed. To apply: IncomeSetPayMode 1 confirm", 1, true) ~= nil, out)
    T.ok("D2 the consequence shows the unchanged number and 24 payments a day",
        out:find("Amount: $5000 per payment", 1, true) ~= nil and out:find("pays 72 times", 1, true) ~= nil, out)
    T.eq("D3 nothing changed", hostState(), "mode=2 amount=5000 rev=1 saves=0")
    host.console.IncomeSetPayMode("1", "yes")
    T.eq("D4 any word but confirm changes nothing", hostState(), "mode=2 amount=5000 rev=1 saves=0")
    local o3 = host.console.IncomeSetPayMode("1", "confirm")
    T.ok("D5 with confirm the host applies", o3:find("Applied.", 1, true) == 1, o3)
    T.eq("D6 applied through the host path: the number kept, the unit changed", hostState(), "mode=1 amount=5000 rev=2 saves=1")
    T.eq("D7 an unknown mode is refused", host.console.IncomeSetPayMode("3", "confirm"),
        SettingsGUI.SCHEDULE_REFUSAL.UNKNOWN_PAY_MODE .. " Nothing changed.")
    for _, bad in ipairs({ "1e3", "1.5", "-1", "+5", "5,000", "abc", "0x10", "5 000", "1E3", "5." }) do
        T.eq("D8 the console refuses '" .. bad .. "' as not a whole number", host.console.IncomeSetCustomAmount(bad),
            SettingsGUI.SCHEDULE_REFUSAL.NOT_WHOLE_NUMBER .. " Nothing changed.")
    end
    T.eq("D9 none of them changed anything", hostState(), "mode=1 amount=5000 rev=2 saves=1")
    T.eq("D10 a new amount above 999999 is refused", host.console.IncomeSetCustomAmount("1000000"),
        SettingsGUI.SCHEDULE_REFUSAL.OUT_OF_RANGE .. " Nothing changed.")
    T.eq("D11 still nothing changed", hostState(), "mode=1 amount=5000 rev=2 saves=1")
    host.console.IncomeSetCustomAmount(" 999999 ")
    T.eq("D12 surrounding spaces and the bound itself are accepted", hostState(), "mode=1 amount=999999 rev=3 saves=2")
    host.console.IncomeSetCustomAmount("007")
    T.eq("D13 leading zeros read as the number", host.mgr.settings.customAmount, 7)
    local o0 = host.console.IncomeSetCustomAmount("0")
    local v0 = host.mgr:getIncomeScheduleView()
    T.eq("D14 0 returns to the difficulty default", tostring(v0.usesDifficultyDefault) .. " " .. v0.payment, "true 2400")
    T.ok("D15 and the console says so", o0:find("(the difficulty default)", 1, true) ~= nil, o0)
    T.eq("D16 an empty amount prints the usage and changes nothing", host.console.IncomeSetCustomAmount(nil),
        "Usage: IncomeSetCustomAmount <amount>, 0 to 999999 (0 uses the difficulty default)")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- E. A MID-DAY MODE CHANGE THROUGH THE REAL POLL
-- ══════════════════════════════════════════════════════════════════════════════
do
    newHost({ payMode = DAILY, customAmount = 100 })
    local a = newClient("a", true); pump(a)
    hours(30)                                   -- day 3 08:00 -> day 4 14:00, Daily
    T.eq("E1 [world] Daily paid the one midnight it crossed, to both farms", now() .. " " .. paidSince(0), "4[4]:14 2:200")
    T.eq("E2 [world] Daily leaves the hour marker where it was", markers(), "4[4]:8")
    local mark = #paid
    local p = ask(a, OP.PREVIEW, "", HOURLY, 0, false)
    local r = ask(a, OP.APPLY, "", HOURLY, p.revision, false)
    T.eq("E3 the admin's mode change is accepted", r.status .. " " .. hostState(), "OK mode=1 amount=100 rev=2 saves=1")
    T.eq("E4 the live instance's markers moved to now", markers(), "4[4]:14")
    T.eq("E5 the IncomeSystem class table was never written", classMarkers(), "nil nil nil")
    hostFrame(MINUTE)
    T.eq("E6 the switch itself pays nothing (no catch-up of the six stale hours)", paidSince(mark), "0:0")
    hours(1)
    T.eq("E7 the next hour pays once, the unchanged number, to each farm", paidSince(mark), "2:200")
    hours(20)                                   -- day 4 15:00 -> day 5 11:00, Hourly
    T.eq("E8 [world] Hourly leaves the day marker where it was", markers(), "4[5]:11")
    mark = #paid
    local p2 = ask(a, OP.PREVIEW, "", DAILY, 0, false)
    local r2 = ask(a, OP.APPLY, "", DAILY, p2.revision, false)
    T.eq("E9 back to Daily is accepted", r2.status .. " " .. hostState(), "OK mode=2 amount=100 rev=3 saves=2")
    T.eq("E10 the live markers moved to now again", markers(), "5[5]:11")
    hostFrame(MINUTE)
    T.eq("E11 the switch back pays nothing (no day paid for the stale day marker)", paidSince(mark), "0:0")
    hours(12)                                   -- day 5 11:00 -> day 5 23:00
    T.eq("E12 nothing more until the next day", paidSince(mark), "0:0")
    hours(1)
    T.eq("E13 the next midnight pays one day once, to each farm", paidSince(mark), "2:200")
    T.eq("E14 the class table is still untouched", classMarkers(), "nil nil nil")
    T.eq("E15 a client never wrote money", tostring(a.moneyWritten), "nil")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- F. RESET: CONSOLE, WIRE AND ESC
-- ══════════════════════════════════════════════════════════════════════════════
local CUSTOM = { payMode = DAILY, customAmount = 5000, difficulty = Settings.DIFFICULTY_HARD, enabled = true,
                 seasonalEffects = true, incomeMultiplier = 2, showNotifications = false, showHUD = false,
                 debugMode = true, experimentalSystems = true }
local function allTen()
    local s = host.mgr.settings
    return table.concat({ tostring(s.enabled), s.difficulty, s.payMode, s.incomeMultiplier, s.customAmount,
        tostring(s.seasonalEffects), tostring(s.showNotifications), tostring(s.showHUD), tostring(s.debugMode),
        tostring(s.experimentalSystems) }, " ")
end
local CUSTOM_TEN = "true 3 2 2 5000 true false false true true"
local DEFAULT_TEN = "true 2 1 1 0 false true true false false"
do
    newHost(CUSTOM)
    T.eq("F1 [world] the host runs a customised schedule", allTen(), CUSTOM_TEN)
    asHost()
    local out = host.console.IncomeResetSettings()
    T.ok("F2 without confirm the console lists every default",
        out:find("Income on, Difficulty: Normal, Pay mode: Hourly, Multiplier: 1x, Amount: the difficulty default, Seasonal effects: off, Notifications: on, HUD: on, Debug: off, Experimental systems: off", 1, true) ~= nil, out)
    T.ok("F3 and the resulting payment and month", out:find("Amount: $2400 per payment (the difficulty default)", 1, true) ~= nil
        and out:find("pays 72 times, about $172800", 1, true) ~= nil, out)
    T.ok("F4 and says nothing changed", out:find("Nothing changed. To apply: IncomeResetSettings confirm", 1, true) ~= nil, out)
    T.eq("F5 an unconfirmed console Reset changes nothing", allTen() .. " " .. hostState(), CUSTOM_TEN .. " mode=2 amount=5000 rev=1 saves=0")
    host.console.IncomeResetSettings("please")
    T.eq("F6 any word but confirm changes nothing", allTen(), CUSTOM_TEN)

    local a = newClient("a", true); pump(a)
    local rp = ask(a, OP.RESET_PREVIEW, "", 0, 0, false)
    T.eq("F7 a reset preview returns the resulting view and writes nothing", rp.status .. " " .. rp.view.unit .. " " .. rp.view.payment .. " " .. allTen(),
        "OK PER_HOUR 2400 " .. CUSTOM_TEN)
    local rn = ask(a, OP.RESET_APPLY, "", 0, rp.revision, false)
    T.eq("F8 a reset apply over the wire without the confirmation is refused", rn.status .. " " .. allTen(), "CONFIRM_REQUIRED " .. CUSTOM_TEN)
    local rs = ask(a, OP.RESET_APPLY, "", 0, rp.revision - 1, true)
    T.eq("F9 a confirmed reset at an old revision is refused as stale", rs.status .. " " .. allTen(), "STALE_PREVIEW " .. CUSTOM_TEN)

    -- mid-day: Daily with a stale hour marker, reset to Hourly by the console
    hours(30)
    T.eq("F10 [world] day 4 14:00 in Daily, the hour marker stale", now() .. " " .. markers(), "4[4]:14 4[4]:8")
    local mark = #paid
    asHost()
    local done = host.console.IncomeResetSettings("confirm")
    T.ok("F11 the confirmed console Reset reports it", done:find("Income Mod settings reset to defaults.", 1, true) == 1, done)
    T.eq("F12 every default restored", allTen(), DEFAULT_TEN)
    T.eq("F13 saved once, revision advanced, broadcast once", hostState() .. " " .. #broadcasts, "mode=1 amount=0 rev=2 saves=1 1")
    T.eq("F14 the live markers moved to now", markers(), "4[4]:14")
    hostFrame(MINUTE)
    T.eq("F15 the Reset itself pays nothing", paidSince(mark), "0:0")
    hours(1)
    T.eq("F16 the next hour pays the default once to each farm", paidSince(mark), "2:4800")
    T.eq("F17 the class table was never written", classMarkers(), "nil nil nil")
    deliverBroadcasts()
    T.eq("F18 the client holds the reset view", viewOf(a).unit .. " " .. viewOf(a).revision, "PER_HOUR 2")
end

-- Esc Reset on an admin client, through the button the settings frame installs.
do
    newHost(CUSTOM)
    local a = newClient("a", true); pump(a)
    asClient(a)
    local ui = SettingsUI.new(a.mgr.settings)
    a.mgr.settingsUI = ui
    local frame = { menuButtonInfo = {} }
    function frame:setMenuButtonInfoDirty() self.dirty = true end
    ui:ensureResetButton(frame)
    local button = frame.menuButtonInfo[1]
    T.ok("F19 [reached] the Esc Reset button is installed on the settings frame", button ~= nil and button.inputAction == InputAction.MENU_EXTRA_1)
    button.callback()
    T.eq("F20 pressing Reset asks the host first: nothing shown, nothing changed yet", #dialogs .. " " .. #a.outbox .. " " .. allTen(), "0 1 " .. CUSTOM_TEN)
    pump(a)
    local d = dialogs[#dialogs]
    T.ok("F21 the confirm lists every default and the result",
        d ~= nil and d.text:find("income on, Normal difficulty, Hourly, 1x, the difficulty amount, seasonal effects off, notifications on, HUD on, debug off, experimental systems off", 1, true) ~= nil
        and d.text:find("Amount per payment: $2400 (the difficulty default).", 1, true) ~= nil, d and d.text)
    T.eq("F22 the confirm is in closure form (no target)", d and tostring(d.target), "nil")
    answer(false)
    pump(a)
    T.eq("F23 No changes nothing", allTen() .. " " .. hostState(), CUSTOM_TEN .. " mode=2 amount=5000 rev=1 saves=0")
    button.callback()
    pump(a)
    answer(true)
    pump(a)
    T.eq("F24 Yes resets every default on the host", allTen() .. " " .. hostState(), DEFAULT_TEN .. " mode=1 amount=0 rev=2 saves=1")
    T.eq("F25 the client's own settings file was never written", a.mgr.settings.payMode .. " " .. a.mgr.settings.customAmount, "1 0")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- G. THE ESC PAY-MODE DOOR
-- ══════════════════════════════════════════════════════════════════════════════
local function injectOn(c)
    local layout = { invalidateLayout = function() end }
    g_gui = { screenControllers = { [InGameMenu] = { pageSettings = { generalSettingsLayout = layout } } } }
    local ui = SettingsUI.new(c.mgr.settings)
    c.mgr.settingsUI = ui
    ui:inject()
    g_gui = nil
    return ui
end
do
    newHost({ payMode = DAILY, customAmount = 5000 })
    -- a client whose view has not arrived
    local w = newClient("w", true)
    asClient(w)
    injectOn(w)
    T.eq("G1 [reached] inject built the pay-mode option; a waiting client's option is disabled",
        tostring(options.im_paymode ~= nil) .. " " .. tostring(options.im_paymode.disabled), "true true")
    local sentBefore = #w.outbox
    click("im_paymode", 2)
    T.eq("G2 a waiting client's pick sends nothing and changes nothing", (#w.outbox - sentBefore) .. " " .. hostState(), "0 mode=2 amount=5000 rev=1 saves=0")
    pump(w)
    T.eq("G3 once the view arrives the option shows the host's mode and is enabled",
        options.im_paymode.state .. " " .. tostring(options.im_paymode.disabled), "2 false")

    -- the admin picks Hourly
    click("im_paymode", 1)
    T.eq("G4 the pick sends one preview and changes nothing before confirm",
        #w.outbox .. " " .. hostState() .. " " .. w.mgr.settings.payMode, "1 mode=2 amount=5000 rev=1 saves=0 1")
    pump(w)
    local d = dialogs[#dialogs]
    T.ok("G5 the confirm shows the new unit, the unchanged number and the 24-to-1 month",
        d ~= nil and d.text:find("Pay mode: Hourly, one payment every in-game hour.", 1, true) ~= nil
        and d.text:find("Amount per payment: $5000.", 1, true) ~= nil
        and d.text:find("Month of 3 days: 72 payments, about $360000 gross", 1, true) ~= nil
        and d.text:find("Nothing is paid at the moment of a change.", 1, true) ~= nil, d and d.text)
    T.eq("G6 still nothing changed while the confirm is open", hostState(), "mode=2 amount=5000 rev=1 saves=0")
    answer(false)
    T.eq("G7 No puts the option back on the host's mode and changes nothing", options.im_paymode.state .. " " .. hostState(), "2 mode=2 amount=5000 rev=1 saves=0")
    click("im_paymode", 1)
    pump(w)
    answer(true)
    pump(w)
    T.eq("G8 Yes applies on the host", hostState(), "mode=1 amount=5000 rev=2 saves=1")
    T.eq("G9 the option follows the accepted view", options.im_paymode.state, 1)
    T.eq("G10 the client's own settings were never written", w.mgr.settings.payMode .. " " .. w.mgr.settings.customAmount, "1 0")

    -- a non-admin pick is refused and shown
    local player = newClient("player", false)
    pump(player)
    asClient(player)
    injectOn(player)
    click("im_paymode", 2)
    pump(player)
    T.eq("G11 a non-admin pick is refused with a message and no confirm", #infos .. " " .. #dialogs .. " " .. tostring(infos[#infos]),
        "1 0 Only a server administrator can change the income schedule. Nothing changed.")
    T.eq("G12 and changes nothing", options.im_paymode.state .. " " .. hostState(), "1 mode=1 amount=5000 rev=2 saves=1")
end

-- The listen host's own Esc: the local server actor, served at once.
do
    newHost({ payMode = DAILY, customAmount = 5000 }, { listen = true })
    asHost()
    injectOn(host)
    T.eq("G13 [reached] the host's option shows its own mode", options.im_paymode.state .. " " .. tostring(options.im_paymode.disabled), "2 false")
    click("im_paymode", 1)
    T.eq("G14 the host's own pick opens the confirm and changes nothing yet", #dialogs .. " " .. hostState(), "1 mode=2 amount=5000 rev=1 saves=0")
    answer(true)
    T.eq("G15 Yes applies through the same host path", hostState(), "mode=1 amount=5000 rev=2 saves=1")
    T.eq("G16 and rebases the live markers", markers(), now())
end

-- ══════════════════════════════════════════════════════════════════════════════
-- H. SETTINGSHUB: THE RETIRED KEYS NO-OP
-- ══════════════════════════════════════════════════════════════════════════════
do
    newHost({ payMode = DAILY, customAmount = 5000 })
    asHost()
    local mod = hubModules.IncomeMod
    mod.onChange("payMode", HOURLY, 3)
    mod.onChange("customAmount", 123, 3)
    T.eq("H1 a stale mirror or ledger restore of the two retired keys changes nothing", hostState(), "mode=2 amount=5000 rev=1 saves=0")
    T.eq("H2 no view was published for them", #broadcasts, 0)
    mod.onChange("seasonalEffects", true, 3)
    T.eq("H3 another row still writes through the same callback", tostring(host.mgr.settings.seasonalEffects) .. " " .. saves, "true 1")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- I. DISPLAY ESTIMATE: DISABLED AND UNAVAILABLE
-- ══════════════════════════════════════════════════════════════════════════════
do
    newHost({ payMode = DAILY, customAmount = 5000, enabled = false })
    local a = newClient("a", true); pump(a)
    local v = viewOf(a)
    T.eq("I1 income off: DISABLED with the hypothetical full month, never 0",
        v.paymentState .. " " .. tostring(v.paymentsThisMonth) .. " " .. tostring(v.monthEstimate), "DISABLED 3 15000")
    T.eq("I2 and the next payment it would make", v.paymentThisSeason, 5000)
end
do
    newHost({ payMode = HOURLY, customAmount = 5000 }, { daysPerPeriod = 0 })
    local a = newClient("a", true); pump(a)
    local v = viewOf(a)
    T.eq("I3 an unusable month length: UNAVAILABLE, and no count or estimate crosses as 0",
        v.paymentState .. " " .. tostring(v.daysThisMonth) .. " " .. tostring(v.paymentsThisMonth) .. " " .. tostring(v.monthEstimate),
        "UNAVAILABLE nil nil nil")
    T.eq("I4 the next payment is still known", v.paymentThisSeason, 5000)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- J. A LEGACY AMOUNT ABOVE THE CAP
-- ══════════════════════════════════════════════════════════════════════════════
do
    newHost({ payMode = DAILY, customAmount = 2000000 })
    local a = newClient("a", true); pump(a)
    T.eq("J1 [world] an old save above the cap loads exactly", tostring(viewOf(a).legacyOverCap) .. " " .. viewOf(a).amount, "true 2000000")
    local p = ask(a, OP.PREVIEW, "", HOURLY, 0, false)
    local r = ask(a, OP.APPLY, "", HOURLY, p.revision, false)
    T.eq("J2 a mode-only change keeps it exactly", r.status .. " " .. hostState(), "OK mode=1 amount=2000000 rev=2 saves=1")
    local n = ask(a, OP.PREVIEW, "2000001", 0, 0, false)
    T.eq("J3 a different amount above the cap is refused", n.status, "OUT_OF_RANGE")
    local m = ask(a, OP.PREVIEW, "1000000", 0, 0, false)
    T.eq("J4 the first amount above the cap is refused", m.status, "OUT_OF_RANGE")
    local p5 = ask(a, OP.PREVIEW, "5000", 0, 0, false)
    ask(a, OP.APPLY, "5000", 0, p5.revision, false)
    T.eq("J5 a new amount inside the range replaces it", hostState() .. " " .. tostring(viewOf(a).legacyOverCap), "mode=1 amount=5000 rev=3 saves=2 false")
    local back = ask(a, OP.PREVIEW, "2000000", 0, 0, false)
    T.eq("J6 once replaced, the old amount is a new over-cap amount and refused", back.status, "OUT_OF_RANGE")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- K. THE WIRE
-- ══════════════════════════════════════════════════════════════════════════════
do
    newHost({ payMode = DAILY, customAmount = 5000 })
    local a = newClient("a", true); pump(a)
    local player = newClient("player", false); pump(player)
    -- a connection sends the host a forged view and a forged reply
    asHost()
    carry(IncomeScheduleEvent.newView({ revision = 99, unit = "PER_HOUR", amount = 1, payment = 1, paymentState = "SCHEDULED" }), nil, a.conn)
    carry(IncomeScheduleEvent.newReply({ sequence = 1, operation = OP.APPLY, status = "OK",
        view = { revision = 99, unit = "PER_HOUR", amount = 1, payment = 1, paymentState = "SCHEDULED" } }), nil, a.conn)
    T.eq("K1 the host never takes a view from a connection", tostring(host.mgr.scheduleView) .. " " .. host.mgr:getIncomeScheduleView().unit .. " " .. hostState(),
        "nil PER_DAY mode=2 amount=5000 rev=1 saves=0")
    -- an accepted change broadcasts a view that states no capability
    local p = ask(a, OP.PREVIEW, "6000", 0, 0, false)
    ask(a, OP.APPLY, "6000", 0, p.revision, false)
    T.eq("K2 the broadcast reached the non-admin client", viewOf(player).amount .. " " .. viewOf(player).revision, "6000 2")
    T.eq("K3 a broadcast keeps each client's own capability", tostring(viewOf(player).canEdit) .. " " .. tostring(viewOf(a).canEdit), "false true")
    -- the throttled republish: only a view that moved is sent
    hostFrame(); host.mgr:update(1000)
    local base = #broadcasts
    host.mgr:update(1000)
    T.eq("K4 an unchanged view is not sent again", #broadcasts - base, 0)
    host.env.daysPerPeriod = 4                  -- the season boundary applies a new month length
    host.mgr:update(500)
    T.eq("K5 the check runs at most once a second", #broadcasts - base, 0)
    host.mgr:update(500)
    T.eq("K6 a view that moved is sent once", #broadcasts - base, 1)
    deliverBroadcasts()
    T.eq("K7 the client follows the new month length", viewOf(a).daysThisMonth .. " " .. viewOf(a).monthEstimate, "4 24000")
    T.eq("K8 every event crossed the tape without a fault", tapeFaults, 0)
    T.eq("K9 every request got exactly one reply, to its own connection", replyErrors, 0)
end
