-- =========================================================
-- Income Field Guide - Field Guide
-- =========================================================
-- BUILD 19:15 (George CLOSED DESIGN 18:55 item 5): every Realistic Farming Esc page gets its own
-- guide, in its own mod, opened from the shared Help footer through this guest's onOpenHelp. The
-- chrome is SoilGuideDialog's so all of them read as one family; only the words differ.
-- Rows are { t = "H" | "B" | "S" | "COL", v = "text" }: header, body, spacer, column break.
-- =========================================================

---@class ImGuideDialog
ImGuideDialog = ImGuideDialog or {}
local ImGuideDialog_mt = Class(ImGuideDialog, ScreenElement)

local GUIDE_MOD_DIR = (IncomeModModDirectory or g_currentModDirectory)

ImGuideDialog.INSTANCE = nil
ImGuideDialog.GUI_NAME = "ImGuideDialog"

ImGuideDialog.SUBTITLES = {
    "Overview - what Income Mod does and where to see it",
    "Payments - the pay modes, the amounts and the timing",
    "Payment Table - reading the Esc payment history",
    "HUD & Report - the on-screen panel and the report",
    "Settings - options, saving and common questions",
}

ImGuideDialog.PAGE1 = {
    { t="H", v="WHAT INCOME MOD DOES" },
    { t="B", v="Income Mod pays your farm a set sum of money" },
    { t="B", v="on a timer, without you doing anything for it." },
    { t="B", v="It is passive income for early cash flow or" },
    { t="B", v="for a relaxed playthrough." },
    { t="S", v=" " },
    { t="B", v="You choose how often you are paid and how much" },
    { t="B", v="each payment is worth. The mod then pays out on" },
    { t="B", v="its own as game time passes." },
    { t="S", v=" " },
    { t="H", v="WHERE YOU SEE IT" },
    { t="B", v="Three places tell the same story." },
    { t="B", v="1. The Realistic Farming page in the pause" },
    { t="B", v="menu, the page in front of you now." },
    { t="B", v="2. The Income HUD, a small panel on screen" },
    { t="B", v="while you play." },
    { t="B", v="3. The Income Report, a full screen dialog" },
    { t="B", v="with a longer payment table." },
    { t="COL", v="" },
    { t="H", v="THE PAUSE PAGE" },
    { t="B", v="Press Escape and pick the Realistic Farming" },
    { t="B", v="tab. The left strip lists the modules. Choose" },
    { t="B", v="Income there, or step through the modules with" },
    { t="B", v="the arrows at the top of that strip." },
    { t="S", v=" " },
    { t="B", v="The main area is a payment table with four" },
    { t="B", v="columns: Day, Time, Type and Amount." },
    { t="S", v=" " },
    { t="B", v="Below the table sit a next payment line and a" },
    { t="B", v="summary line showing whether Income is on, your" },
    { t="B", v="pay mode and the payment amount." },
    { t="S", v=" " },
    { t="H", v="GOOD TO KNOW" },
    { t="B", v="This page only reports. Nothing on it moves" },
    { t="B", v="money in or out of your account." },
    { t="S", v=" " },
    { t="B", v="In multiplayer only the host pays out, so" },
    { t="B", v="nobody is paid twice. Every active farm on the" },
    { t="B", v="server earns its own income." },
}

ImGuideDialog.PAGE2 = {
    { t="H", v="THE TWO PAY MODES" },
    { t="B", v="Hourly pays once every in-game hour, so twenty" },
    { t="B", v="four times an in-game day." },
    { t="B", v="Daily pays once when the in-game day rolls" },
    { t="B", v="over." },
    { t="S", v=" " },
    { t="B", v="Hourly is the starting mode. It gives small" },
    { t="B", v="steady drips and earns far more over a day." },
    { t="B", v="Daily gives one larger lump and much less" },
    { t="B", v="across the same day." },
    { t="S", v=" " },
    { t="H", v="HOW MUCH EACH PAYMENT IS" },
    { t="B", v="Difficulty sets the base payment. Easy pays" },
    { t="B", v="5000, Normal pays 2400 and Hard pays 1100." },
    { t="B", v="Normal is the starting choice." },
    { t="S", v=" " },
    { t="B", v="The income multiplier then scales that base by" },
    { t="B", v="one, two, five or ten times. It starts at one." },
    { t="COL", v="" },
    { t="B", v="If seasonal effects are on, the season scales" },
    { t="B", v="it once more. Spring is 0.8 times, summer is" },
    { t="B", v="1.0, autumn is 1.2 and winter is 0.7. Seasonal" },
    { t="B", v="effects start switched off." },
    { t="S", v=" " },
    { t="B", v="So the payment is the difficulty base, times" },
    { t="B", v="the multiplier, times the season." },
    { t="S", v=" " },
    { t="H", v="WHEN PAYMENTS ARE SKIPPED" },
    { t="B", v="Nothing is paid while you are sleeping. Those" },
    { t="B", v="hours or days are passed over, not stored up." },
    { t="S", v=" " },
    { t="B", v="The mod remembers when it last paid and saves" },
    { t="B", v="that with your game, so reloading does not pay" },
    { t="B", v="you twice for the same hour or day." },
    { t="S", v=" " },
    { t="B", v="If a lot of game time passes at once, say at" },
    { t="B", v="high time speed, the missed rounds are paid" },
    { t="B", v="together in one larger transfer. There is a" },
    { t="B", v="ceiling on how many it will pay at once, as a" },
    { t="B", v="safety limit." },
}

ImGuideDialog.PAGE3 = {
    { t="H", v="THE FOUR COLUMNS" },
    { t="B", v="Day is the in-game day the payment landed." },
    { t="B", v="Time is the hour it landed, always shown on" },
    { t="B", v="the hour." },
    { t="B", v="Type says which mode paid it, hourly or daily." },
    { t="B", v="Amount is the money that went to your farm for" },
    { t="B", v="that payment." },
    { t="S", v=" " },
    { t="B", v="The newest payment sits at the top. When the" },
    { t="B", v="list is longer than the box, it scrolls." },
    { t="S", v=" " },
    { t="H", v="WHEN THE LIST IS EMPTY" },
    { t="B", v="A short note says there are no payments yet." },
    { t="B", v="That is normal on a fresh save, and also right" },
    { t="B", v="after loading a game." },
    { t="S", v=" " },
    { t="B", v="The list of recent payments is not saved. It" },
    { t="B", v="starts empty every time you load and fills" },
    { t="B", v="again as new payments land. Only the payment" },
    { t="B", v="timer itself is saved with your game." },
    { t="COL", v="" },
    { t="H", v="THE LINES BELOW THE TABLE" },
    { t="B", v="One line gives the next payment. In hourly" },
    { t="B", v="mode it names the hour that is due and roughly" },
    { t="B", v="how many game minutes are left. In daily mode" },
    { t="B", v="it names the day." },
    { t="S", v=" " },
    { t="B", v="The same line adds the total and the average" },
    { t="B", v="of the payments still on file, how many are" },
    { t="B", v="held, and a reminder that only the last ten" },
    { t="B", v="are kept." },
    { t="S", v=" " },
    { t="B", v="Under that is a short line with your" },
    { t="B", v="difficulty, your multiplier and whether" },
    { t="B", v="seasonal effects are on." },
    { t="S", v=" " },
    { t="B", v="The bottom line is the summary: Income on or" },
    { t="B", v="off, your pay mode, and the payment amount." },
    { t="S", v=" " },
    { t="H", v="BUTTONS" },
    { t="B", v="Income adds no buttons of its own here. The" },
    { t="B", v="footer offers Back and Help. Help opens this" },
    { t="B", v="guide. Nothing on this page changes your" },
    { t="B", v="money." },
}

ImGuideDialog.PAGE4 = {
    { t="H", v="THE INCOME HUD" },
    { t="B", v="A small panel on screen while you play. Its" },
    { t="B", v="title row reads INCOME MOD with an ON or OFF" },
    { t="B", v="marker." },
    { t="S", v=" " },
    { t="B", v="The next row shows your pay mode, your" },
    { t="B", v="difficulty and the payment amount." },
    { t="B", v="A multiplier row appears only when the" },
    { t="B", v="multiplier is above one." },
    { t="B", v="A season row appears only when seasonal" },
    { t="B", v="effects are on." },
    { t="S", v=" " },
    { t="B", v="Then comes the next payment line and a Recent" },
    { t="B", v="Payments block listing up to five payments," },
    { t="B", v="newest first." },
    { t="S", v=" " },
    { t="H", v="MOVING AND HIDING THE HUD" },
    { t="B", v="Right Shift and I hides or shows the panel." },
    { t="B", v="Right Shift and J starts move mode." },
    { t="S", v=" " },
    { t="B", v="In move mode, drag the panel to move it, drag" },
    { t="B", v="a corner to resize it, drag a side edge to" },
    { t="B", v="make it wider or narrower, and right click" },
    { t="B", v="when you are done. Your layout is remembered." },
    { t="COL", v="" },
    { t="B", v="If you also run the Master HUD mod, that mod" },
    { t="B", v="takes over hiding and moving panels and these" },
    { t="B", v="two keys are not used." },
    { t="S", v=" " },
    { t="H", v="THE INCOME REPORT" },
    { t="B", v="A full screen dialog. The top rows give your" },
    { t="B", v="status, pay mode, difficulty, payment amount," },
    { t="B", v="multiplier and whether seasonal is on." },
    { t="S", v=" " },
    { t="B", v="Under that come the total earned, the average" },
    { t="B", v="per payment, and the next payment." },
    { t="S", v=" " },
    { t="B", v="Then a table of up to ten payments with day," },
    { t="B", v="time, type, amount and the season factor that" },
    { t="B", v="was applied to each one." },
    { t="S", v=" " },
    { t="B", v="It has no key set for it out of the box. Look" },
    { t="B", v="for Open Income Report under Options, then" },
    { t="B", v="Controls, and give it the key you want." },
}

ImGuideDialog.PAGE5 = {
    { t="H", v="WHERE THE SETTINGS ARE" },
    { t="B", v="Pause the game, open Settings, and scroll the" },
    { t="B", v="general list down to the Income Mod section." },
    { t="S", v=" " },
    { t="B", v="Enable Mod turns all payments on or off." },
    { t="B", v="Pay Mode picks hourly or daily." },
    { t="B", v="Difficulty picks the base payment." },
    { t="B", v="Income Multiplier scales it by one, two, five" },
    { t="B", v="or ten times." },
    { t="B", v="Seasonal Effects turns the season change on or" },
    { t="B", v="off." },
    { t="B", v="Notifications shows a pop up each time you are" },
    { t="B", v="paid." },
    { t="B", v="Show Income HUD keeps the panel on screen." },
    { t="B", v="DEBUG Mode only adds extra log messages." },
    { t="S", v=" " },
    { t="B", v="A Reset Income Settings button sits in the" },
    { t="B", v="button bar at the bottom of the Settings page." },
    { t="B", v="It puts everything back to the starting values" },
    { t="B", v="and cannot be undone." },
    { t="COL", v="" },
    { t="H", v="WHAT IS SAVED WHERE" },
    { t="B", v="Settings are stored with the savegame, so each" },
    { t="B", v="save can be set up differently. The HUD" },
    { t="B", v="position and size are stored with your game" },
    { t="B", v="profile and follow you between saves." },
    { t="S", v=" " },
    { t="H", v="COMMON QUESTIONS" },
    { t="B", v="No money is arriving. Check that Enable Mod is" },
    { t="B", v="on, and remember nothing is paid while you" },
    { t="B", v="sleep. In multiplayer only the host pays." },
    { t="S", v=" " },
    { t="B", v="The payment list is empty after loading. That" },
    { t="B", v="is expected. Only the timer is saved, so the" },
    { t="B", v="list fills again from the next payment on." },
    { t="S", v=" " },
    { t="B", v="Can I set my own amount? Yes, but only from" },
    { t="B", v="the developer console, with the custom amount" },
    { t="B", v="command. Zero returns to the difficulty" },
    { t="B", v="amount, and the multiplier still applies." },
    { t="S", v=" " },
    { t="B", v="Handy console commands: IncomeNext," },
    { t="B", v="IncomeHistory and IncomeShowSettings. Type" },
    { t="B", v="income on its own for the full list." },
}

ImGuideDialog.PAGE_CONTENT = { ImGuideDialog.PAGE1, ImGuideDialog.PAGE2, ImGuideDialog.PAGE3, ImGuideDialog.PAGE4, ImGuideDialog.PAGE5 }

-- -- Constructor ------------------------------------------

function ImGuideDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or ImGuideDialog_mt)
    self._contentLineEls = {}
    self._currentPage = 1
    return self
end

--- Loads the dialog into g_gui once. Safe to call twice, and safe to call when some other path has
--- already registered the same name.
function ImGuideDialog.register(modDirectory)
    if g_gui == nil then return end
    if g_gui.guis ~= nil and g_gui.guis[ImGuideDialog.GUI_NAME] ~= nil then return end
    if modDirectory ~= nil then GUIDE_MOD_DIR = modDirectory end
    if GUIDE_MOD_DIR == nil then return end
    ImGuideDialog.INSTANCE = ImGuideDialog.new()
    local ok, err = pcall(function()
        g_gui:loadGui(GUIDE_MOD_DIR .. "xml/gui/ImGuideDialog.xml", ImGuideDialog.GUI_NAME, ImGuideDialog.INSTANCE)
    end)
    if not ok then
        print("[Income] ImGuideDialog: loadGui failed: " .. tostring(err))
        ImGuideDialog.INSTANCE = nil
    end
end

function ImGuideDialog.show()
    if g_gui == nil then return end
    local loaded = g_gui.guis ~= nil and g_gui.guis[ImGuideDialog.GUI_NAME] ~= nil
    if not loaded then
        ImGuideDialog.register(GUIDE_MOD_DIR)
        loaded = g_gui.guis ~= nil and g_gui.guis[ImGuideDialog.GUI_NAME] ~= nil
    end
    if not loaded then return end
    g_gui:showDialog(ImGuideDialog.GUI_NAME)
end

-- -- Lifecycle --------------------------------------------

function ImGuideDialog:onGuiSetupFinished()
    ImGuideDialog:superClass().onGuiSetupFinished(self)
    self._elCol1 = self:getDescendantById("imGuide_col1")
    self._elCol2 = self:getDescendantById("imGuide_col2")
    self._elSubtitle = self:getDescendantById("imGuide_subtitle")
end

function ImGuideDialog:onOpen()
    ImGuideDialog:superClass().onOpen(self)
    self._currentPage = 1
    self:_selectPage(1)
end

function ImGuideDialog:onClose()
    ImGuideDialog:superClass().onClose(self)
    self:_clearContent()
    self._currentPage = 1
end

-- -- Tabs -------------------------------------------------

function ImGuideDialog:onClickTab1() self:_selectPage(1) end
function ImGuideDialog:onClickTab2() self:_selectPage(2) end
function ImGuideDialog:onClickTab3() self:_selectPage(3) end
function ImGuideDialog:onClickTab4() self:_selectPage(4) end
function ImGuideDialog:onClickTab5() self:_selectPage(5) end

function ImGuideDialog:_selectPage(pageNum)
    if self._currentPage == pageNum and #self._contentLineEls > 0 then return end
    self:_clearContent()
    self._currentPage = pageNum
    if self._elSubtitle ~= nil then
        self._elSubtitle:setText(ImGuideDialog.SUBTITLES[pageNum] or "")
    end
    self:_buildContent(pageNum)
end

-- -- Content ----------------------------------------------

function ImGuideDialog:_buildContent(pageNum)
    local profileH = g_gui:getProfile("imGuide_colHeader")
    local profileB = g_gui:getProfile("imGuide_colBody")
    local profileS = g_gui:getProfile("imGuide_colSpacer")
    if not profileH or not profileB then
        print("[Income] ImGuideDialog: column profiles not found")
        return
    end
    local content = ImGuideDialog.PAGE_CONTENT[pageNum]
    if content == nil then return end
    local currentBox = self._elCol1
    for _, row in ipairs(content) do
        if row.t == "COL" then
            if self._elCol1 ~= nil then self._elCol1:invalidateLayout() end
            currentBox = self._elCol2
        elseif currentBox ~= nil then
            local profile = (row.t == "H") and profileH
                         or (row.t == "S") and profileS
                         or profileB
            if profile ~= nil then
                local el = TextElement.new()
                el:loadProfile(profile, true)
                el:setText(row.v or "")
                currentBox:addElement(el)
                el:onGuiSetupFinished()
                table.insert(self._contentLineEls, { box = currentBox, el = el })
            end
        end
    end
    if self._elCol2 ~= nil then self._elCol2:invalidateLayout() end
end

function ImGuideDialog:_clearContent()
    for _, entry in ipairs(self._contentLineEls or {}) do
        if entry.box ~= nil then
            entry.box:removeElement(entry.el)
        end
    end
    self._contentLineEls = {}
    if self._elCol1 ~= nil then self._elCol1:invalidateLayout() end
    if self._elCol2 ~= nil then self._elCol2:invalidateLayout() end
end

-- -- Button -----------------------------------------------

function ImGuideDialog:onClickClose()
    g_gui:closeDialogByName(ImGuideDialog.GUI_NAME)
end
