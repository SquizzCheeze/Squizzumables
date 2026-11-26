-- Chat/Chat.lua
-- Squizzumables' chat, replacing ElvUI's for the user (stage 1: panels and
-- look). Like ElvUI's, it restyles and arranges Blizzard's own chat windows
-- rather than replacing the chat engine: the windows, tabs, docking, edit box
-- and every message stay Blizzard's.
--
-- ElvUI's licence forbids publishing its code, so nothing here is copied from
-- it: ElvUI was read for WHAT its chat options do. One deliberate difference:
-- ElvUI rewrites Blizzard's whole chat message handler. On 12.x a message can
-- arrive SECRET (in encounters and keys), where any Lua edit of it throws, so
-- this stage never touches message text at all. Timestamps use Blizzard's
-- own (local time, the same formats), set from here.
--
-- What this stage covers:
--   * two panels (left and right), sized, backgrounds on either or both, a tab
--     strip background, placed in Edit Mode; the main chat window sits in the
--     left one and any window you pick in the right one
--   * Blizzard's chat art, scroll bar, buttons and tab art cleared
--   * chat font and outline (each window keeps its own size), tab font, the
--     selected tab's text colour
--   * the edit box above or below the chat, inside or outside the panel
--   * fading, how long lines stay, how many lines are kept, scrolling back to
--     the newest line after a while, timestamps
--
-- COEXISTENCE: does nothing while ElvUI's chat module is on (General > Chat in
-- ElvUI, E.private.chat.enable). Turning this off needs a reload, since the
-- art it cleared does not come back otherwise.

local addonName, ns = ...
local BH = ns.BH

local CH = {}
ns.Chat = CH

local function ElvUI()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

function CH.ElvUIChatOn()
    local E = ElvUI()
    if not E then return false end
    local p = E.private and E.private.chat
    return not (p and p.enable == false)
end

function CH.Wanted()
    return BH.settings and BH.settings.chEnabled and not CH.ElvUIChatOn() and true or false
end

local hider = CreateFrame("Frame")
hider:Hide()

-- ============================================================================
-- Settings
-- ============================================================================

local function Apply() if CH.Apply then CH.Apply() end end

local OUTLINES = {
    { text = "None", value = "NONE" },
    { text = "Shadow", value = "SHADOW" },
    { text = "Outline", value = "OUTLINE" },
    { text = "Thick outline", value = "THICKOUTLINE" },
}
local BACKDROPS = {
    { text = "Both panels", value = "SHOWBOTH" },
    { text = "Left panel only", value = "LEFT" },
    { text = "Right panel only", value = "RIGHT" },
    { text = "Neither", value = "HIDEBOTH" },
}
local EDITBOX = {
    { text = "Below the chat", value = "BELOW_CHAT" },
    { text = "Below the chat, inside the panel", value = "BELOW_CHAT_INSIDE" },
    { text = "Above the chat", value = "ABOVE_CHAT" },
    { text = "Above the chat, inside the panel (under the tabs)", value = "ABOVE_CHAT_INSIDE" },
}

-- Blizzard's own timestamp formats (Options > Social), shown as today's time.
local function TimestampItems()
    local items = { { text = "Blizzard's setting", value = "__blizzard" }, { text = "None", value = "none" } }
    for _, key in ipairs({ "TIMESTAMP_FORMAT_HHMM", "TIMESTAMP_FORMAT_HHMMSS", "TIMESTAMP_FORMAT_HHMM_AMPM",
        "TIMESTAMP_FORMAT_HHMMSS_AMPM", "TIMESTAMP_FORMAT_HHMM_24HR", "TIMESTAMP_FORMAT_HHMMSS_24HR" }) do
        local fmt = _G[key]
        if type(fmt) == "string" then
            local shown = (TimeUtil and TimeUtil.BetterDate or date)(fmt, time())
            items[#items + 1] = { text = shown, value = fmt }
        end
    end
    return items
end

local function RightWindowItems()
    local items = { { text = "None", value = 0 } }
    for i = 2, (Constants and Constants.ChatFrameConstants and Constants.ChatFrameConstants.MaxChatWindows) or 10 do
        local name = FCF_GetChatWindowInfo and FCF_GetChatWindowInfo(i)
        if name and name ~= "" then items[#items + 1] = { text = i .. ". " .. name, value = i } end
    end
    return items
end

local reloadAsked
local function AskReload()
    if reloadAsked then return end
    reloadAsked = true
    StaticPopupDialogs["SQUIZZUMABLES_CHAT_RELOAD"] = StaticPopupDialogs["SQUIZZUMABLES_CHAT_RELOAD"] or {
        text = "Blizzard's chat look comes back after a reload.",
        button1 = "Reload now", button2 = "Later",
        OnAccept = function() ReloadUI() end,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }
    StaticPopup_Show("SQUIZZUMABLES_CHAT_RELOAD")
end

local function Backdrops(s) return s.chPanelBackdrop ~= "HIDEBOTH" end
local function DataOn(s) return s.chDataTexts ~= false end
local function DataItems()
    local DT = ns.DataTexts
    return DT and DT.SlotItems() or { { text = "None", value = "None" } }
end

CH.SETTINGS = ns.Settings.Describe({
    master = "chEnabled",
    apply = Apply,
    pages = {
        { key = "general", label = "General", rows = {
            { key = "chEnabled", type = "check", default = false,
              label = "Use Squizzumables Chat",
              tip = "Restyle and arrange the chat windows: panels, fonts, tabs, the edit box and timestamps.\n\n"
                .. "It stays off while ElvUI's chat is on: turn that off in ElvUI (General > Chat > Enable) and "
                .. "/reload first. Your ElvUI chat settings were copied the first time Squizzumables ran.",
              apply = function(v)
                  if v and CH.ElvUIChatOn() then
                      print("|cff33cc99Squizzumables:|r ElvUI's chat is still on. Turn it off in ElvUI "
                          .. "(General > Chat > Enable), /reload, and this takes over.")
                  elseif not v and CH.active then
                      AskReload()
                  end
              end },
            { type = "header", label = "TEXT" },
            { key = "chFont", type = "dropdown", default = "__default",
              items = function() return BH:BuildFontDropdownItems() end,
              label = "Chat Font", tip = "Font of the chat lines and the edit box. Each window keeps its own size "
                .. "(right-click its tab > Font Size)." },
            { key = "chFontOutline", type = "dropdown", default = "SHADOW", items = OUTLINES,
              label = "Chat Font Outline", tip = "An outline or a shadow round the letters." },
            { key = "chTimestamps", type = "dropdown", default = "__blizzard", items = TimestampItems,
              label = "Timestamps", tip = "The time in front of each line, in your local time." },
            { type = "header", label = "TABS" },
            { key = "chTabFont", type = "dropdown", default = "__default",
              items = function() return BH:BuildFontDropdownItems() end,
              label = "Tab Font", tip = "Font of the tab names." },
            { key = "chTabFontSize", type = "slider", default = 12, min = 6, max = 24, step = 1,
              label = "Tab Font Size", tip = "Size of the tab names." },
            { key = "chTabFontOutline", type = "dropdown", default = "SHADOW", items = OUTLINES,
              label = "Tab Font Outline", tip = "An outline or a shadow round the tab names." },
            { key = "chTabSelectedColored", type = "check", default = true,
              label = "Colour the Selected Tab", tip = "The tab you are looking at gets its own text colour." },
            { key = "chTabSelectedColor", type = "color", default = { r = 1, g = 1, b = 1 },
              label = "Selected Tab Colour", tip = "Text colour of the selected tab.",
              when = function(s) return s.chTabSelectedColored ~= false end },
            { type = "header", label = "LINES" },
            { key = "chFade", type = "check", default = true,
              label = "Fade Old Lines", tip = "Lines fade out after a while without new ones; scroll to see them again." },
            { key = "chInactivity", type = "slider", default = 100, min = 5, max = 300, step = 5,
              label = "Seconds Before Fading", tip = "How long a line stays before it fades.",
              when = function(s) return s.chFade ~= false end },
            { key = "chMaxLines", type = "slider", default = 100, min = 10, max = 5000, step = 10,
              label = "Lines Kept", tip = "How many lines each window keeps to scroll back through. Changing "
                .. "this clears the windows." },
            { key = "chScrollDown", type = "slider", default = 15, min = 0, max = 120, step = 5,
              label = "Back to Newest After", tip = "Seconds after you scroll up before the window jumps back to "
                .. "the newest line. 0 to stay where you scrolled." },
        } },
        { key = "panels", label = "Panels", rows = {
            { key = "chPanelWidth", type = "slider", default = 412, min = 150, max = 1000, step = 1,
              label = "Panel Width", tip = "Width of the chat panels (the left one, with Separate Sizes)." },
            { key = "chPanelHeight", type = "slider", default = 180, min = 80, max = 800, step = 1,
              label = "Panel Height", tip = "Height of the chat panels (the left one, with Separate Sizes)." },
            { key = "chSeparateSizes", type = "check", default = false,
              label = "Separate Sizes", tip = "Give the right panel its own width and height." },
            { key = "chPanelWidthRight", type = "slider", default = 412, min = 150, max = 1000, step = 1,
              label = "Right Panel Width", tip = "Width of the right panel.",
              when = function(s) return s.chSeparateSizes end },
            { key = "chPanelHeightRight", type = "slider", default = 180, min = 80, max = 800, step = 1,
              label = "Right Panel Height", tip = "Height of the right panel.",
              when = function(s) return s.chSeparateSizes end },
            { key = "chRightWindow", type = "dropdown", default = 0, items = RightWindowItems,
              label = "Right Panel Window",
              tip = "A chat window to show in the right panel. It has to be pulled out of the dock first (drag "
                .. "its tab away)." },
            { type = "header", label = "BACKGROUND" },
            { key = "chPanelBackdrop", type = "dropdown", default = "SHOWBOTH", items = BACKDROPS,
              label = "Panel Backgrounds", tip = "Which panels draw a background." },
            { key = "chPanelColor", type = "color", default = { r = 0.06, g = 0.06, b = 0.06 },
              label = "Background Colour", tip = "Colour of the panel backgrounds.", when = Backdrops },
            { key = "chPanelAlpha", type = "slider", default = 80, min = 0, max = 100, step = 5,
              label = "Background Opacity", tip = "How solid the backgrounds are, in percent.", when = Backdrops },
            { key = "chTabBackdrop", type = "check", default = false,
              label = "Tab Strip Background", tip = "A background behind the row of tabs." },
            { key = "chTabTransparent", type = "check", default = false,
              label = "See-through Tab Strip", tip = "The tab strip's background takes the panel opacity.",
              when = function(s) return s.chTabBackdrop end },
            { type = "header", label = "EDIT BOX" },
            { key = "chEditBoxPosition", type = "dropdown", default = "BELOW_CHAT", items = EDITBOX,
              label = "Edit Box Position", tip = "Where you type." },
            { type = "header", label = "BUTTONS" },
            { key = "chChatButtons", type = "check", default = true, label = "Chat Menu and Voice Buttons",
              tip = "Blizzard's chat menu (emotes, languages), channels and voice mute/deafen buttons, in a row at "
                .. "the top right of the left panel." },
            { key = "chToggles", type = "check", default = true, label = "Hide/Show Buttons",
              tip = "A small arrow at the outer end of each data text strip hides or shows that chat panel. The "
                .. "edit box still opens while a panel is hidden.", when = DataOn },
            { type = "header", label = "ELVUI" },
            { key = "chHideElvUIPanels", type = "check", default = true,
              label = "Hide ElvUI's Chat Panels",
              tip = "ElvUI still draws its empty chat panels (and the data texts under them) after its chat is "
                .. "off. Hide them so they don't sit behind these." },
        } },
        { key = "datatexts", label = "Data Texts", rows = {
            { key = "chDataTexts", type = "check", default = true,
              label = "Data Texts Under the Panels",
              tip = "A strip of three live readouts under each chat panel, like ElvUI's. Font and colours come "
                .. "from Interface > Data Texts." },
            { key = "chDataHeight", type = "slider", default = 22, min = 14, max = 40, step = 1,
              label = "Strip Height", tip = "Height of the data text strips.", when = DataOn },
            { type = "header", label = "LEFT PANEL" },
            { key = "chDataLeft1", type = "dropdown", default = "Talent/Loot Specialization", items = DataItems,
              label = "Left", when = DataOn },
            { key = "chDataLeft2", type = "dropdown", default = "Durability", items = DataItems,
              label = "Middle", when = DataOn },
            { key = "chDataLeft3", type = "dropdown", default = "Currencies", items = DataItems,
              label = "Right", when = DataOn },
            { type = "header", label = "RIGHT PANEL" },
            { key = "chDataRight1", type = "dropdown", default = "System", items = DataItems,
              label = "Left", when = DataOn },
            { key = "chDataRight2", type = "dropdown", default = "Time", items = DataItems,
              label = "Middle", when = DataOn },
            { key = "chDataRight3", type = "dropdown", default = "Gold", items = DataItems,
              label = "Right", when = DataOn },
        } },
        unpack(ns.ChatMessages.PAGES),   -- Messages, Edit Box (Chat/Messages.lua)
    },
})

function BH:BuildChatTab(parent)
    ns.Settings.Build(CH.SETTINGS, parent)
end

-- ============================================================================
-- Fonts
-- ============================================================================

local function ResolveFont(name)
    if name and name ~= "__default" then
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        local path = lsm and lsm:Fetch("font", name, true)
        if path then return path end
    end
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

-- Font flags for an outline choice, plus whether it wants a drop shadow.
local function Outline(o)
    if o == "OUTLINE" or o == "THICKOUTLINE" then return o, false end
    return "", o == "SHADOW"
end

local function SetFont(obj, path, size, outline)
    if not (obj and obj.SetFont) then return end
    local flags, shadow = Outline(outline)
    obj:SetFont(path, size, flags)
    if obj.SetShadowOffset then
        obj:SetShadowOffset(shadow and 1 or 0, shadow and -1 or 0)
        obj:SetShadowColor(0, 0, 0, shadow and 1 or 0)
    end
end

-- ============================================================================
-- Panels
-- ============================================================================

local panels = {}

local function Box(parent, layer)
    local t = {}
    t.bg = parent:CreateTexture(nil, layer or "BACKGROUND", nil, -8)
    t.bg:SetAllPoints()
    t.edges = {}
    for i = 1, 4 do t.edges[i] = parent:CreateTexture(nil, layer or "BACKGROUND", nil, -7) end
    local e = t.edges
    e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT"); e[1]:SetHeight(1)
    e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT"); e[2]:SetHeight(1)
    e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT"); e[3]:SetWidth(1)
    e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT"); e[4]:SetWidth(1)
    function t:Paint(r, g, b, a, shown)
        self.bg:SetColorTexture(r, g, b, a)
        self.bg:SetShown(shown)
        for _, edge in ipairs(self.edges) do
            edge:SetColorTexture(0, 0, 0, 1)
            edge:SetShown(shown)
        end
    end
    return t
end

local function DefaultPosition(side)
    if side == "Left" then return { point = "BOTTOMLEFT", relPoint = "BOTTOMLEFT", x = 4, y = 4 } end
    return { point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT", x = -4, y = 4 }
end

-- Saved at the panel's outer bottom corner, so a size change grows it inwards
-- and upwards and never pushes it off the screen edge.
local function SavePosition(side)
    local f, s = panels[side], BH.settings
    if not (f and s and f:GetLeft()) then return end
    local scale = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if side == "Left" then
        s.chLeftPosition = { point = "BOTTOMLEFT", relPoint = "BOTTOMLEFT",
            x = math.floor(f:GetLeft() * scale + 0.5), y = math.floor(f:GetBottom() * scale + 0.5) }
    else
        s.chRightPosition = { point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT",
            x = math.floor(f:GetRight() * scale - UIParent:GetWidth() + 0.5), y = math.floor(f:GetBottom() * scale + 0.5) }
    end
    BH:SaveSettings()
end

local function Panel(side)
    if panels[side] then return panels[side] end
    local f = CreateFrame("Frame", "SquizzumablesChatPanel" .. side, UIParent)
    f:SetFrameStrata("BACKGROUND")
    f:SetFrameLevel(1)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:EnableMouse(false)
    f:SetScript("OnDragStart", function(self)
        if InCombatLockdown() or not BH.unlockMode then return end
        BH:GridStartMoving(self)
    end)
    f:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(self)
        SavePosition(side)
        CH.Apply()
    end)
    f.box = Box(f)
    f.tabStrip = CreateFrame("Frame", nil, f)
    f.tabStrip:SetPoint("TOPLEFT", 3, -3)
    f.tabStrip:SetPoint("TOPRIGHT", -3, -3)
    f.tabStrip:SetHeight(22)
    f.tabStrip.box = Box(f.tabStrip)
    -- The data text strip hangs under the panel.
    f.data = CreateFrame("Frame", nil, f)
    f.data:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -1)
    f.data:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -1)
    f.data.box = Box(f.data)
    f.data.slots = {}
    local DT = ns.DataTexts
    if DT then
        for i = 1, 3 do f.data.slots[i] = DT.CreateSlot(f.data) end
    end
    panels[side] = f
    BH["chatPanel" .. side] = f
    return f
end
CH.panels = panels

-- ============================================================================
-- Blizzard's chat windows
-- ============================================================================

local styled = setmetatable({}, { __mode = "k" })   -- chat frame -> true
local editBoxes = setmetatable({}, { __mode = "k" }) -- edit box -> our Box
local scrollTokens = setmetatable({}, { __mode = "k" }) -- chat frame -> last wheel turn

local function Frames()
    local list = {}
    for _, name in ipairs(CHAT_FRAMES or {}) do
        local f = _G[name]
        if f then list[#list + 1] = f end
    end
    return list
end

local function Clear(tex)
    if tex and tex.SetTexture then tex:SetTexture(nil) end
end

local function IsUndocked(chat)
    local primary = GeneralDockManager and GeneralDockManager.primary or ChatFrame1
    return chat ~= primary and not chat.isDocked
end

local function StyleTab(tab, s)
    if not tab then return end
    for _, key in ipairs({ "Left", "Middle", "Right", "ActiveLeft", "ActiveMiddle", "ActiveRight",
        "HighlightLeft", "HighlightMiddle", "HighlightRight" }) do
        Clear(tab[key])
    end
    local text = tab.Text or (tab.GetFontString and tab:GetFontString())
    if text then
        SetFont(text, ResolveFont(s.chTabFont), s.chTabFontSize or 12, s.chTabFontOutline or "SHADOW")
    end
end

local function StyleEditBox(eb, s)
    if not eb then return end
    local name = eb:GetName()
    if name then
        Clear(_G[name .. "Left"]); Clear(_G[name .. "Right"]); Clear(_G[name .. "Mid"])
    end
    Clear(eb.focusLeft); Clear(eb.focusRight); Clear(eb.focusMid)
    if not editBoxes[eb] then editBoxes[eb] = Box(eb) end
    local c = s.chPanelColor or {}
    editBoxes[eb]:Paint(c.r or 0.06, c.g or 0.06, c.b or 0.06, 0.9, true)
    local path = ResolveFont(s.chFont)
    local _, size = eb:GetFont()
    size = size or 12
    for _, fs in ipairs({ eb, eb.header, eb.headerSuffix, eb.languageHeader, eb.prompt, eb.NewcomerHint }) do
        SetFont(fs, path, size, s.chFontOutline or "SHADOW")
    end
end

local function StyleChat(chat, s)
    local name = chat:GetName()
    local id = chat:GetID()

    -- Each window keeps the size picked from its tab menu.
    local _, size = FCF_GetChatWindowInfo(id)
    SetFont(chat, ResolveFont(s.chFont), (size and size > 0) and size or 14, s.chFontOutline or "SHADOW")

    chat:SetFading(s.chFade ~= false)
    chat:SetTimeVisible(s.chInactivity or 100)
    local maxLines = s.chMaxLines or 100
    if chat.GetMaxLines and chat:GetMaxLines() ~= maxLines then chat:SetMaxLines(maxLines) end

    for _, suffix in ipairs(CHAT_FRAME_TEXTURES or {}) do
        if suffix ~= "Background" then Clear(_G[name .. suffix]) end
    end
    -- Docked windows sit on our panel; an undocked one keeps Blizzard's
    -- background so it can still be seen.
    local bg = _G[name .. "Background"] or chat.Background
    if bg then bg:SetShown(IsUndocked(chat) and true or false) end

    StyleTab(_G[name .. "Tab"], s)
    StyleEditBox(chat.editBox, s)
    ns.ChatMessages.StyleChat(chat, s)

    if styled[chat] then return end
    styled[chat] = true

    if chat.buttonFrame then chat.buttonFrame:SetParent(hider) end
    if chat.ScrollBar then chat.ScrollBar:SetParent(hider) end
    if chat.ScrollToBottomButton then chat.ScrollToBottomButton:SetParent(hider) end
    chat:SetClampRectInsets(0, 0, 0, 0)

    -- Tabs stay visible instead of fading out when the mouse leaves.
    local tab = _G[name .. "Tab"]
    if tab then
        local busy
        hooksecurefunc(tab, "SetAlpha", function(t, a)
            if busy or a == 1 or not CH.active then return end
            busy = true
            t:SetAlpha(1)
            busy = false
        end)
    end

    -- Back to the newest line a while after scrolling up.
    chat:HookScript("OnMouseWheel", function(self)
        local delay = BH.settings and BH.settings.chScrollDown or 15
        if not CH.active or delay <= 0 then return end
        local token = (scrollTokens[self] or 0) + 1
        scrollTokens[self] = token
        C_Timer.After(delay, function()
            if scrollTokens[self] == token and self.AtBottom and not self:AtBottom() then self:ScrollToBottom() end
        end)
    end)
end

-- ============================================================================
-- Arrangement
-- ============================================================================

local function PanelSize(s, side)
    if side == "Right" and s.chSeparateSizes then
        return s.chPanelWidthRight or 412, s.chPanelHeightRight or 180
    end
    return s.chPanelWidth or 412, s.chPanelHeight or 180
end

local placing
local function PlaceWindow(chat, panel, w, h)
    placing = true
    -- Edit Mode clamps the window by its selection box, which reaches over
    -- the (hidden) button column on the left: near the screen edge that
    -- pushed the window right and its text out past the panel. The panel is
    -- clamped instead.
    chat:SetClampedToScreen(false)
    chat:ClearAllPoints()
    chat:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 5, 5)
    chat:SetSize(w - 10, h - 32)
    placing = false
end

local function PlaceEditBoxes(s, panel, chat)
    local pos = s.chEditBoxPosition or "BELOW_CHAT"
    for _, f in ipairs(Frames()) do
        local eb = f.editBox
        if eb then
            eb:ClearAllPoints()
            local onPanel = f == chat or f.isDocked
            local anchor = onPanel and panel or f
            -- Below the chat means below the data texts too.
            if onPanel and pos == "BELOW_CHAT" and panel.data:IsShown() then anchor = panel.data end
            if pos == "ABOVE_CHAT_INSIDE" then
                -- Just under the tab strip (3px in, 22px of tabs, 2px gap).
                eb:SetPoint("TOPLEFT", anchor, "TOPLEFT", 3, -27)
                eb:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -3, -27)
            elseif pos == "ABOVE_CHAT" then
                eb:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
                eb:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 2)
            elseif pos == "BELOW_CHAT_INSIDE" then
                eb:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 3, 3)
                eb:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -3, 3)
            else
                eb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
                eb:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
            end
            eb:SetHeight(22)
        end
    end
end

local function Arrange(s)
    local left, right = Panel("Left"), Panel("Right")
    local c = s.chPanelColor or {}
    local r, g, b = c.r or 0.06, c.g or 0.06, c.b or 0.06
    local a = (s.chPanelAlpha or 80) / 100
    local which = s.chPanelBackdrop or "SHOWBOTH"

    for side, f in pairs({ Left = left, Right = right }) do
        local w, h = PanelSize(s, side)
        local pos = s["ch" .. side .. "Position"] or DefaultPosition(side)
        f:ClearAllPoints()
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
        f:SetSize(w, h)
        f:EnableMouse(BH.unlockMode and true or false)
        f:SetFrameStrata(BH.unlockMode and "HIGH" or "BACKGROUND")
        local shown = which == "SHOWBOTH" or which == (side == "Left" and "LEFT" or "RIGHT")
        f.box:Paint(r, g, b, a, shown)
        f.tabStrip.box:Paint(r, g, b, s.chTabTransparent and a or 1, s.chTabBackdrop and true or false)

        local DT = ns.DataTexts
        local data = f.data
        local dh = s.chDataHeight or 22
        if DT and s.chDataTexts ~= false then
            data:SetHeight(dh)
            data.box:Paint(r, g, b, 1, true)
            -- Room for the hide/show arrow at the outer end.
            local toggle = s.chToggles ~= false and 16 or 0
            local x0 = side == "Left" and toggle or 0
            local each = (w - toggle) / 3
            for i, slot in ipairs(data.slots) do
                slot:ClearAllPoints()
                slot:SetPoint("TOPLEFT", data, "TOPLEFT", x0 + each * (i - 1), 0)
                slot:SetPoint("BOTTOMRIGHT", data, "BOTTOMLEFT", x0 + each * i, 0)
                slot:Show()
                DT.SetSlot(slot, s["chData" .. side .. i])
            end
            data:Show()
            f:SetClampRectInsets(0, 0, 0, -(dh + 1))
        else
            for _, slot in ipairs(data.slots) do DT.SetSlot(slot, nil) end
            data:Hide()
            f:SetClampRectInsets(0, 0, 0, 0)
        end
        f:Show()
    end

    local primary = GeneralDockManager and GeneralDockManager.primary or ChatFrame1
    local lw, lh = PanelSize(s, "Left")
    if primary then PlaceWindow(primary, left, lw, lh) end

    local rightChat = (s.chRightWindow or 0) > 0 and _G["ChatFrame" .. s.chRightWindow]
    if rightChat and rightChat ~= primary and not rightChat.isDocked and rightChat:IsShown() then
        local rw, rh = PanelSize(s, "Right")
        PlaceWindow(rightChat, right, rw, rh)
    end

    local dock = GeneralDockManager
    if dock and primary then
        dock:ClearAllPoints()
        dock:SetPoint("BOTTOMLEFT", primary, "TOPLEFT", 0, 3)
        -- Tabs stop short of the copy button and the chat menu/voice row.
        local inset = (s.chCopyButton ~= false and 22 or 0) + (s.chChatButtons ~= false and 88 or 0)
        dock:SetPoint("BOTTOMRIGHT", primary, "TOPRIGHT", -inset, 3)
        dock:SetHeight(22)
    end

    PlaceEditBoxes(s, left, primary)
end

-- ElvUI's own chat panels, left behind (empty) when its chat is off.
local ELV_PANELS = { "LeftChatPanel", "RightChatPanel", "LeftChatToggleButton", "RightChatToggleButton" }
local elvHidden = {}
local function ElvPanels(hide)
    for _, name in ipairs(ELV_PANELS) do
        local f = _G[name]
        if f then
            if hide and not elvHidden[name] then
                elvHidden[name] = f:GetParent()
                f:SetParent(hider)
            elseif not hide and elvHidden[name] then
                f:SetParent(elvHidden[name])
                elvHidden[name] = nil
            end
        end
    end
end

-- ============================================================================
-- Chat menu / voice row, and hiding a panel
-- ============================================================================

local VOICE = { "ChatFrameMenuButton", "ChatFrameChannelButton", "ChatFrameToggleVoiceDeafenButton",
    "ChatFrameToggleVoiceMuteButton" }

local function ChatButtons(s, left)
    local prev
    for _, name in ipairs(VOICE) do
        local b = _G[name]
        if b then
            if s.chChatButtons ~= false then
                b:SetParent(left)
                b:SetFrameStrata("MEDIUM")
                b:SetScale(0.7)
                b:ClearAllPoints()
                -- Scaled 0.7, so offsets are in its own units (/0.7).
                if prev then
                    b:SetPoint("RIGHT", prev, "LEFT", -2, 0)
                else
                    local copy = s.chCopyButton ~= false and 22 or 0
                    b:SetPoint("TOPRIGHT", left, "TOPRIGHT", -(5 + copy) / 0.7, -4 / 0.7)
                end
                prev = b
            else
                b:SetParent(hider)
            end
        end
    end
end

local toggles = {}

local function WindowsOn(side, s)
    local list = {}
    if side == "Left" then
        for _, f in ipairs(Frames()) do
            if f == (GeneralDockManager and GeneralDockManager.primary or ChatFrame1) or f.isDocked then
                list[#list + 1] = f
            end
        end
        if GeneralDockManager then list[#list + 1] = GeneralDockManager end
    else
        local w = (s.chRightWindow or 0) > 0 and _G["ChatFrame" .. s.chRightWindow]
        if w and not w.isDocked then list[#list + 1] = w end
    end
    return list
end

local function Toggles(s)
    for side, f in pairs(panels) do
        local key = "ch" .. side .. "Hidden"
        local shown = s.chToggles ~= false and s.chDataTexts ~= false and ns.DataTexts ~= nil
        local hidden = shown and s[key] and true or false

        local t = toggles[side]
        if not t then
            t = CreateFrame("Button", nil, f.data)
            t:SetWidth(16)
            t.text = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            t.text:SetPoint("CENTER")
            t:SetScript("OnClick", function()
                BH.settings[key] = not BH.settings[key]
                BH:SaveSettings()
                CH.Apply()
            end)
            t:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(BH.settings[key] and "Show the chat panel" or "Hide the chat panel")
                GameTooltip:Show()
            end)
            t:SetScript("OnLeave", GameTooltip_Hide)
            toggles[side] = t
        end
        t:ClearAllPoints()
        if side == "Left" then
            t:SetPoint("TOPLEFT", f.data, "TOPLEFT")
            t:SetPoint("BOTTOMLEFT", f.data, "BOTTOMLEFT")
            t.text:SetText(hidden and ">" or "<")
        else
            t:SetPoint("TOPRIGHT", f.data, "TOPRIGHT")
            t:SetPoint("BOTTOMRIGHT", f.data, "BOTTOMRIGHT")
            t.text:SetText(hidden and "<" or ">")
        end
        t:SetShown(shown)

        -- Hidden: the panel's background, tabs, buttons and windows go
        -- see-through; the edit box still shows when you type.
        if hidden then
            f.box:Paint(0, 0, 0, 0, false)
            f.tabStrip.box:Paint(0, 0, 0, 0, false)
        end
        for _, child in ipairs({ f:GetChildren() }) do
            if child ~= f.data then child:SetAlpha(hidden and 0 or 1) end
        end
        for _, w in ipairs(WindowsOn(side, s)) do
            w:SetAlpha(hidden and 0 or 1)
            local eb = rawget(w, "editBox")
            if eb then eb:SetIgnoreParentAlpha(hidden) end
        end
    end
end

-- ============================================================================
-- Apply
-- ============================================================================

local function ApplyTimestamps(s)
    local fmt = s.chTimestamps
    if not fmt or fmt == "__blizzard" then return end
    if GetCVar("showTimestamps") ~= fmt then SetCVar("showTimestamps", fmt) end
end

function CH.Apply()
    local s = BH.settings
    if not s then return end
    if CH.Wanted() then
        CH.active = true
    elseif CH.active then
        CH.active = false   -- the look goes on reload
    end
    if not CH.active then
        for _, f in pairs(panels) do f:Hide() end
        ElvPanels(false)
        return
    end
    if CH.Hook then CH.Hook() end
    for _, chat in ipairs(Frames()) do StyleChat(chat, s) end
    if QuickJoinToastButton then QuickJoinToastButton:SetParent(hider) end
    if TextToSpeechButtonFrame then TextToSpeechButtonFrame:SetParent(hider) end
    Arrange(s)
    ns.ChatMessages.Apply(s, panels, function(side)
        if side == "Left" then
            return FCFDock_GetSelectedWindow and FCFDock_GetSelectedWindow(GeneralDockManager) or ChatFrame1
        end
        local w = (s.chRightWindow or 0) > 0 and _G["ChatFrame" .. s.chRightWindow]
        return w and not w.isDocked and w:IsShown() and w or nil
    end)
    ChatButtons(s, panels.Left)
    Toggles(s)
    ElvPanels(s.chHideElvUIPanels ~= false)
    ApplyTimestamps(s)
end

-- Blizzard re-places and restyles its windows (Edit Mode, docking, a font size
-- picked from a tab, a new whisper window): put ours back straight after.
local queued
local function Queue()
    if queued or not CH.active then return end
    queued = true
    C_Timer.After(0, function()
        queued = false
        if CH.active then CH.Apply() end
    end)
end

local function Hook()
    if CH.hooked then return end
    CH.hooked = true
    for _, fn in ipairs({ "FCF_DockUpdate", "FCF_OpenTemporaryWindow", "FCF_SetChatWindowFontSize",
        "FCF_RestorePositionAndDimensions", "FCF_DockFrame", "FCF_UnDockFrame" }) do
        if _G[fn] then hooksecurefunc(fn, Queue) end
    end
    if FCFTab_UpdateColors then
        hooksecurefunc("FCFTab_UpdateColors", function(tab, selected)
            local s = BH.settings
            if not (CH.active and s and selected and s.chTabSelectedColored ~= false) then return end
            local c = s.chTabSelectedColor or {}
            local text = tab.Text or tab:GetFontString()
            if text then text:SetTextColor(c.r or 1, c.g or 1, c.b or 1) end
        end)
    end
    local primary = ChatFrame1
    for _, method in ipairs({ "UpdateSystem", "ApplySystemAnchor", "OnSystemPositionChange" }) do
        if primary and primary[method] then
            hooksecurefunc(primary, method, function() if not placing then Queue() end end)
        end
    end
    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("EditMode.Exit", Queue, CH)
    end
end

CH.Hook = Hook

-- ============================================================================
-- ElvUI's settings, copied once per profile
-- ============================================================================

local function MapOutline(o)
    if o == "OUTLINE" or o == "THICKOUTLINE" or o == "NONE" then return o end
    if o == "SHADOWOUTLINE" or o == "SHADOWTHICKOUTLINE" then return "OUTLINE" end
    if o == "SHADOW" then return "SHADOW" end
    return nil
end

local function SeedFromElvUI()
    local s = BH.settings
    if not s or s.chSeededFromElvUI then return end
    local E = ElvUI()
    local db = E and E.db and E.db.chat
    if type(db) ~= "table" then return end
    s.chSeededFromElvUI = true
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local function Font(name) return name and lsm and lsm:IsValid("font", name) and name or nil end

    s.chFont = Font(db.font) or s.chFont
    s.chFontOutline = MapOutline(db.fontOutline) or s.chFontOutline
    s.chTabFont = Font(db.tabFont) or s.chTabFont
    s.chTabFontOutline = MapOutline(db.tabFontOutline) or s.chTabFontOutline
    if tonumber(db.tabFontSize) then s.chTabFontSize = tonumber(db.tabFontSize) end
    if db.tabSelectedTextEnabled ~= nil then s.chTabSelectedColored = db.tabSelectedTextEnabled and true or false end
    local tc = db.tabSelectedTextColor
    if type(tc) == "table" and tc.r then s.chTabSelectedColor = { r = tc.r, g = tc.g, b = tc.b } end
    if db.fade ~= nil then s.chFade = db.fade and true or false end
    if tonumber(db.inactivityTimer) then s.chInactivity = tonumber(db.inactivityTimer) end
    if tonumber(db.maxLines) then s.chMaxLines = tonumber(db.maxLines) end
    if tonumber(db.scrollDownInterval) then s.chScrollDown = tonumber(db.scrollDownInterval) end
    if tonumber(db.panelWidth) then s.chPanelWidth = tonumber(db.panelWidth) end
    if tonumber(db.panelHeight) then s.chPanelHeight = tonumber(db.panelHeight) end
    if db.separateSizes ~= nil then s.chSeparateSizes = db.separateSizes and true or false end
    if tonumber(db.panelWidthRight) then s.chPanelWidthRight = tonumber(db.panelWidthRight) end
    if tonumber(db.panelHeightRight) then s.chPanelHeightRight = tonumber(db.panelHeightRight) end
    if tonumber(db.panelSnapRightID) then s.chRightWindow = tonumber(db.panelSnapRightID) end
    if type(db.panelBackdrop) == "string" then s.chPanelBackdrop = db.panelBackdrop end
    local pc = db.panelColor
    if type(pc) == "table" and pc.r then
        s.chPanelColor = { r = pc.r, g = pc.g, b = pc.b }
        if tonumber(pc.a) then s.chPanelAlpha = math.floor(pc.a * 100 + 0.5) end
    end
    if db.panelTabBackdrop ~= nil then s.chTabBackdrop = db.panelTabBackdrop and true or false end
    if db.panelTabTransparency ~= nil then s.chTabTransparent = db.panelTabTransparency and true or false end
    if type(db.editBoxPosition) == "string" then s.chEditBoxPosition = db.editBoxPosition end
    local ts = db.timeStampFormat
    if ts == "NONE" then
        s.chTimestamps = "none"
    elseif type(ts) == "string" then
        for _, item in ipairs(TimestampItems()) do
            if item.value == ts then s.chTimestamps = ts end
        end
    end

    -- Where the panels sit now: the live frames, else ElvUI's saved movers.
    for side, elv in pairs({ Left = "LeftChatPanel", Right = "RightChatPanel" }) do
        local f = _G[elv]
        local key = "ch" .. side .. "Position"
        if f and f.GetLeft and f:GetLeft() then
            local scale = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
            if side == "Left" then
                s[key] = { point = "BOTTOMLEFT", relPoint = "BOTTOMLEFT",
                    x = math.floor(f:GetLeft() * scale + 0.5), y = math.floor(f:GetBottom() * scale + 0.5) }
            else
                s[key] = { point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT",
                    x = math.floor(f:GetRight() * scale - UIParent:GetWidth() + 0.5), y = math.floor(f:GetBottom() * scale + 0.5) }
            end
        else
            local mover = E.db.movers and E.db.movers[side .. "ChatMover"]
            if type(mover) == "string" then
                local pt, _, rel, x, y = strsplit(",", mover)
                if pt and rel and tonumber(x) and tonumber(y) then
                    s[key] = { point = pt, relPoint = rel, x = tonumber(x), y = tonumber(y) }
                end
            end
        end
    end
    BH:SaveSettings()
end

-- After a profile switch, reset or Edit Mode change too.
-- The chat panels' data texts, copied on their own (they came a release later).
local function SeedDataFromElvUI()
    local s = BH.settings
    if not s or s.chDataSeededFromElvUI then return end
    local E = ElvUI()
    local p = E and E.db and E.db.datatexts and E.db.datatexts.panels
    if type(p) ~= "table" then return end
    s.chDataSeededFromElvUI = true
    local known = {}
    for _, item in ipairs(DataItems()) do known[item.value] = true end
    for side, elv in pairs({ Left = "LeftChatDataPanel", Right = "RightChatDataPanel" }) do
        local t = p[elv]
        if type(t) == "table" then
            for i = 1, 3 do
                local key = t[i]
                if type(key) == "string" then s["chData" .. side .. i] = known[key] and key or "None" end
            end
            if t.enable == false then s.chDataTexts = false end
        end
    end
    BH:SaveSettings()
end

function BH:ApplyChat()
    SeedFromElvUI()
    SeedDataFromElvUI()
    ns.ChatMessages.Seed(ElvUI())
    CH.Apply()
end

-- Edit Mode's arrow-key nudge (MOVABLE_FRAMES in Squizzumables.lua).
function CH.Nudge(side, dx, dy)
    local s = BH.settings
    if not s then return end
    local key = "ch" .. side .. "Position"
    local pos = s[key] or DefaultPosition(side)
    s[key] = { point = pos.point, relPoint = pos.relPoint, x = (pos.x or 0) + dx, y = (pos.y or 0) + dy }
    BH:SaveSettings()
    CH.Apply()
end

-- A Data Texts font or colour change restyles our strips too.
if ns.DataTexts then
    table.insert(ns.DataTexts.applyHooks, function() if CH.active then CH.Apply() end end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("UPDATE_CHAT_WINDOWS")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        BH:ApplyChat()
    else
        Queue()
    end
end)
