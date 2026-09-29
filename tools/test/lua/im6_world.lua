-- im6_world.lua - the IM-6 bench world: a dedicated host and its clients, each built by
-- the REAL IncomeManager.new and onMissionLoaded, with IncomeScheduleEvent carried over
-- the #76 stream tape in both directions. The same world IM6-A-host_authority_test.lua
-- builds inline, shared here for the reader bars.
--
-- The fixture supplies the engine, GUI and persistence only: the missions, the clock
-- (f282_environment_model.lua), the user manager, two farms and the money sink, the
-- server's broadcast sink and each client's server connection, a SettingsHub instance,
-- addConsoleCommand, the dialogs, the UIHelper option factory and SettingsManager's XML I/O.

IM6 = {}
local W = IM6

-- The engine's Class also gives a class its superClass (the report's onOpen calls it);
-- the prelude's stub does not. Loaded before the GUI modules.
local preludeClass = Class
function Class(members, baseClass)
    local mt = preludeClass(members)
    if baseClass ~= nil then setmetatable(members, { __index = baseClass }) end
    members.superClass = function() return baseClass end
    return mt
end
ScreenElement = ScreenElement or {
    new = function(_target, mt) return setmetatable({}, mt) end,
    onOpen = function() end,
}

W.HOUR, W.MINUTE = F282Env.HOUR, 60000

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
W.saves = 0
local settingsFile = nil
SettingsManager.new = function()
    local file = settingsFile or {}
    return {
        loadSettings = function(_self, s) for k, v in pairs(file) do s[k] = v end end,
        saveSettings = function() W.saves = W.saves + 1 end,
        saveTimerState = function() end,
        loadTimerState = function() return nil end,
    }
end

local console = nil
addConsoleCommand = function(name, _desc, funcName, target)
    console[name] = function(...) return target[funcName](target, ...) end
end

-- The GUI: dialogs recorded, answered as a player would.
W.dialogs, W.infos, W.inputs = {}, {}, {}
YesNoDialog = { show = function(callback, target, text, title)
    W.dialogs[#W.dialogs + 1] = { callback = callback, target = target, text = text, title = title }
end }
InfoDialog = { show = function(text) W.infos[#W.infos + 1] = text end }
TextInputDialog = { show = function(callback, target, defaultText, prompt, imePrompt, maxCharacters, confirmText)
    W.inputs[#W.inputs + 1] = { callback = callback, target = target, defaultText = defaultText,
                                prompt = prompt, maxCharacters = maxCharacters }
end }
function W.answer(yes)
    local d = W.dialogs[#W.dialogs]
    if d == nil then T.ok("a confirm was open to answer", false); return end
    W.dialogs[#W.dialogs] = nil
    d.callback(yes)
end
function W.type(text, ok)
    local d = W.inputs[#W.inputs]
    if d == nil then T.ok("an entry was open to type into", false); return end
    W.inputs[#W.inputs] = nil
    d.callback(text, ok ~= false)
end

-- UIHelper: the settings page's option factory.
W.options = {}
UIHelper = {
    createSection = function() return {} end,
    createBinaryOption = function(_layout, id, _text, state, callback)
        local o = { id = id, checked = state, callback = callback }
        function o:setIsChecked(v) self.checked = v end
        W.options[id] = o
        return o
    end,
    createMultiOption = function(_layout, id, _text, texts, state, callback)
        local o = { id = id, texts = texts, state = state, callback = callback, disabled = false }
        function o:setState(v) self.state = v end
        function o:setTexts(t) self.texts = t end
        function o:setDisabled(v) self.disabled = v end
        W.options[id] = o
        return o
    end,
    getText = function(key) return key end,
}
function W.click(id, index)
    local o = W.options[id]
    o.state = index
    o.callback(index)
end

function W.injectOn(machine)
    local layout = { invalidateLayout = function() end }
    g_gui = { screenControllers = { [InGameMenu] = { pageSettings = { generalSettingsLayout = layout } } } }
    local ui = SettingsUI.new(machine.mgr.settings)
    machine.mgr.settingsUI = ui
    ui:inject()
    g_gui = nil
    return ui
end

-- ── the machines ─────────────────────────────────────────────────────────────
W.host, W.clients = nil, {}
W.users, W.paid, W.broadcasts, W.hubModules = {}, {}, {}, {}
W.tapeFaults, W.replyErrors = 0, 0

function W.asHost()
    local h = W.host
    g_currentMission = h.mission
    g_server = h.server
    g_client = nil
    g_IncomeManager = h.mgr
    g_farmManager = h.farmManager
end

function W.asClient(c)
    g_currentMission = c.mission
    g_server = nil
    g_client = c.client
    g_IncomeManager = c.mgr
    g_farmManager = nil
end

function W.newHost(file, opts)
    opts = opts or {}
    W.clients, W.users, W.paid, W.broadcasts, W.hubModules = {}, {}, {}, {}, {}
    W.dialogs, W.infos, W.inputs, W.options = {}, {}, {}, {}
    W.saves = 0
    local h = { console = {}, delivered = 0 }
    W.host = h
    h.env = F282Env.new({ day = 3, hour = 8 })
    h.env.daysPerPeriod = opts.daysPerPeriod or 3
    if opts.season ~= nil then h.env.currentSeason = opts.season end
    h.server = { broadcastEvent = function(_self, ev, sendLocal)
        W.broadcasts[#W.broadcasts + 1] = { ev = ev, sendLocal = sendLocal }
    end }
    h.farmManager = { farms = { [1] = { farmId = 1 }, [2] = { farmId = 2 } } }
    h.mission = {
        environment = h.env, missionInfo = {},
        getIsServer = function() return true end,
        getIsClient = function() return opts.listen == true end,
        getFarmId = function() return nil end,
        addMoney = function(_, amount, farmId) W.paid[#W.paid + 1] = { amount = amount, farmId = farmId } end,
        addIngameNotification = function() end,
        userManager = { getUserByConnection = function(_self, conn)
            local master = W.users[conn]
            if master == nil then return nil end
            return { getIsMasterUser = function() return master end }
        end },
        settingsHub = { registerModule = function(_self, name, spec) W.hubModules[name] = spec end },
    }
    W.asHost()
    console, settingsFile = h.console, file
    h.mgr = IncomeManager.new(h.mission, "./", "FS25_IncomeMod")
    g_IncomeManager = h.mgr
    h.mgr:onMissionLoaded()
    W.saves = 0
    return h
end

--- A client; `ownFile` is its own settings file (its local defaults unless given).
function W.newClient(name, master, ownFile)
    local c = { name = name, outbox = {}, console = {} }
    c.conn = { sent = {} }
    function c.conn:sendEvent(ev) self.sent[#self.sent + 1] = ev end
    W.users[c.conn] = master
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
    W.clients[#W.clients + 1] = c
    W.asClient(c)
    console, settingsFile = c.console, ownFile or {}
    local before = W.saves
    c.mgr = IncomeManager.new(c.mission, "./", "FS25_IncomeMod")
    g_IncomeManager = c.mgr
    c.mgr:onMissionLoaded()
    W.saves = before
    return c
end

function W.carry(ev, fromConn, toConn)
    local s = _sfMockStream()
    ev:writeStream(s, fromConn)
    IncomeScheduleEvent.emptyNew():readStream(s, toConn)
    W.tapeFaults = W.tapeFaults + _sfStreamFaults(s)
    if s.r ~= #s.q + 1 then W.tapeFaults = W.tapeFaults + 1 end
end

function W.deliverBroadcasts()
    local h = W.host
    for i = h.delivered + 1, #W.broadcasts do
        for _, c in ipairs(W.clients) do
            W.asClient(c)
            W.carry(W.broadcasts[i].ev, nil, nil)
        end
    end
    h.delivered = #W.broadcasts
end

function W.pump(c)
    while #c.outbox > 0 do
        local req = table.remove(c.outbox, 1)
        W.asHost()
        local before = #c.conn.sent
        W.carry(req, nil, c.conn)
        if #c.conn.sent ~= before + 1 then W.replyErrors = W.replyErrors + 1 end
        W.deliverBroadcasts()
        for i = before + 1, #c.conn.sent do
            W.asClient(c)
            W.carry(c.conn.sent[i], nil, nil)
        end
    end
    W.asClient(c)
end

function W.hostState()
    local s = W.host.mgr.settings
    return string.format("mode=%d amount=%s rev=%d saves=%d", s.payMode, tostring(s.customAmount),
        W.host.mgr.scheduleRevision, W.saves)
end
