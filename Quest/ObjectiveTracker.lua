-- Quest/ObjectiveTracker.lua
-- Blizzard's objective tracker restyled: the fonts of the section headers and
-- of the quest text, colours for headers, quest titles and objectives (your
-- own or your class colour, each with its mouse-over colour), a bar under each
-- section header (solid, two-colour gradient or class colour), objectives
-- without the leading dash, and "3/10" coloured from red to green as it fills,
-- with the percentage if you like.
--
-- WindTools' Objective Tracker was read for behaviour only. The tracker holds
-- secure quest item buttons, so nothing here writes into Blizzard's tracker
-- tables or replaces a method:
--   * fonts go through the tracker's own two font objects
--     (ObjectiveTrackerHeaderFont / ObjectiveTrackerLineFont), so Blizzard
--     measures every line in our font and nothing overlaps;
--   * colours are post-hooks on SetTextColor that set ours straight after,
--     guarded against re-entry;
--   * the header bars are textures of our own.
-- One font object serves quest titles and objectives alike, so they share a
-- font and size (WindTools sizes them apart by a point).
--
-- Works on retail and WoW Forever. Waits while WindTools' Objective Tracker is
-- on. Turning this off needs a /reload to put Blizzard's look back.

local addonName, ns = ...
local BH = ns.BH

local OT = {}
ns.ObjectiveTrackerStyle = OT

local function Elv()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

local function WTTracker()
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") then return nil end
    local E = Elv()
    local q = E and E.private and E.private.WT and E.private.WT.quest
    return q and type(q.objectiveTracker) == "table" and q.objectiveTracker or nil
end

function OT.ElvUIOn()
    local t = WTTracker()
    return t and t.enable and true or false
end

local settingsView = setmetatable({}, { __index = function(_, k)
    local s = BH.settings
    local v = s and s[k]
    if v == nil and BH.defaultSettings then v = BH.defaultSettings[k] end
    return v
end })
local function Settings() return settingsView end
local function Active()
    return BH.settings and BH.settings.otEnabled and not OT.ElvUIOn() and _G.ObjectiveTrackerFrame ~= nil
end
local function Apply() if OT.Apply then OT.Apply() end end

local OUTLINES = {
    { text = "None", value = "NONE" }, { text = "Shadow", value = "SHADOW" },
    { text = "Outline", value = "OUTLINE" }, { text = "Thick outline", value = "THICKOUTLINE" },
}
local function Fonts() return BH:BuildFontDropdownItems() end

-- ============================================================================
-- Settings
-- ============================================================================

local reloadAsked
OT.SETTINGS = ns.Settings.Describe({
    master = "otEnabled",
    apply = Apply,
    pages = {
        { key = "general", label = "General", rows = {
            { key = "otEnabled", type = "check", default = false, label = "Restyle the Objective Tracker",
              tip = "Fonts, colours and a bar under each section of the quest tracker.\n\nWaits while WindTools' "
                .. "Objective Tracker is on (WindTools > Quest > Objective Tracker, then /reload).",
              apply = function(v)
                  if v and OT.ElvUIOn() then
                      print("|cff33cc99Squizzumables:|r WindTools' Objective Tracker is still on. Turn it off there, "
                          .. "/reload, and this takes over.")
                  elseif not v and OT.styled and not reloadAsked then
                      reloadAsked = true
                      print("|cff33cc99Squizzumables:|r the objective tracker is back to Blizzard's after a /reload.")
                  end
              end },
            { key = "otNoDash", type = "check", default = true, label = "No Dash Before Objectives" },
            { key = "otColorProgress", type = "check", default = true, label = "Colour Progress by How Far Along",
              tip = "\"3/10\" from red to green as it fills." },
            { key = "otPercent", type = "check", default = false, label = "Add the Percentage",
              tip = "\"3/10 (30%)\"." },
            { type = "header", label = "SECTION HEADERS" },
            { key = "otHeadFont", type = "dropdown", default = "__default", items = Fonts, label = "Font" },
            { key = "otHeadSize", type = "slider", default = 14, min = 8, max = 24, step = 1, label = "Size" },
            { key = "otHeadOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES, label = "Outline" },
            { key = "otHeadClass", type = "check", default = false, label = "Class Colour" },
            { key = "otHeadColor", type = "color", default = { r = 1, g = 1, b = 1 }, label = "Colour",
              when = function(s) return not s.otHeadClass end },
            { key = "otTitleClass", type = "check", default = false, label = "Tracker Title in Class Colour",
              tip = "\"All Objectives\" at the top." },
            { key = "otTitleColor", type = "color", default = { r = 0, g = 0.659, b = 1 }, label = "Tracker Title Colour",
              when = function(s) return not s.otTitleClass end },
        } },
        { key = "quests", label = "Quest Text", rows = {
            { key = "otLineFont", type = "dropdown", default = "__default", items = Fonts, label = "Font",
              tip = "Quest titles and objectives share it." },
            { key = "otLineSize", type = "slider", default = 12, min = 8, max = 22, step = 1, label = "Size" },
            { key = "otLineOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES, label = "Outline" },
            { type = "header", label = "QUEST TITLES" },
            { key = "otQuestColors", type = "check", default = true, label = "Colour Quest Titles" },
            { key = "otQuestClass", type = "check", default = false, label = "Class Colour",
              when = function(s) return s.otQuestColors end },
            { key = "otQuestColor", type = "color", default = { r = 0, g = 0.659, b = 1 }, label = "Colour",
              when = function(s) return s.otQuestColors and not s.otQuestClass end },
            { key = "otQuestHighlight", type = "color", default = { r = 0.282, g = 0.859, b = 0.984 },
              label = "Mouse-Over Colour", when = function(s) return s.otQuestColors and not s.otQuestClass end },
            { type = "header", label = "OBJECTIVES" },
            { key = "otObjColors", type = "check", default = true, label = "Colour Objectives" },
            { key = "otObjColor", type = "color", default = { r = 0.842, g = 0.815, b = 0.677 }, label = "Colour",
              when = function(s) return s.otObjColors end },
            { key = "otObjHighlight", type = "color", default = { r = 0.992, g = 0.965, b = 0.827 },
              label = "Mouse-Over Colour", when = function(s) return s.otObjColors end },
        } },
        { key = "bar", label = "Header Bar", rows = {
            { key = "otBar", type = "check", default = true, label = "Bar Under Each Section Header" },
            { key = "otBarMode", type = "dropdown", default = "GRADIENT", label = "Colour",
              items = { { text = "Gradient", value = "GRADIENT" }, { text = "Solid", value = "SOLID" },
                        { text = "Class colour", value = "CLASS" } },
              when = function(s) return s.otBar end },
            { key = "otBarColor1", type = "color", default = { r = 0.329, g = 0.522, b = 0.933 }, label = "Left Colour",
              when = function(s) return s.otBar and s.otBarMode ~= "CLASS" end },
            { key = "otBarColor2", type = "color", default = { r = 0.259, g = 0.843, b = 0.867 }, label = "Right Colour",
              when = function(s) return s.otBar and s.otBarMode == "GRADIENT" end },
            { key = "otBarWidth", type = "slider", default = 250, min = 40, max = 400, step = 1, label = "Width",
              when = function(s) return s.otBar end },
            { key = "otBarHeight", type = "slider", default = 2, min = 1, max = 10, step = 1, label = "Height",
              when = function(s) return s.otBar end },
            { key = "otBarX", type = "slider", default = 0, min = -50, max = 50, step = 1, label = "Offset X",
              when = function(s) return s.otBar end },
            { key = "otBarY", type = "slider", default = -12, min = -40, max = 20, step = 1, label = "Offset Y",
              when = function(s) return s.otBar end },
        } },
    },
})

function BH:BuildObjectiveTrackerTab(parent)
    ns.Settings.Build(OT.SETTINGS, parent)
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function ResolveFont(name)
    if name and name ~= "__default" then
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        local path = lsm and lsm:Fetch("font", name, true)
        if path then return path end
    end
    return STANDARD_TEXT_FONT
end

local function Flags(outline)
    return (outline == "OUTLINE" or outline == "THICKOUTLINE") and outline or ""
end

local function ClassRGB()
    local _, class = UnitClass("player")
    local c = (C_ClassColor and C_ClassColor.GetClassColor(class)) or RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function RGB(c, r, g, b)
    if type(c) == "table" and c.r then return c.r, c.g, c.b end
    return r, g, b
end

local function Same(a, r, g, b)
    return a and math.abs(a.r - r) < 0.01 and math.abs(a.g - g) < 0.01 and math.abs(a.b - b) < 0.01
end

-- ============================================================================
-- Fonts (the tracker's own font objects)
-- ============================================================================

local function ApplyFonts()
    local s = Settings()
    local line, head = _G.ObjectiveTrackerLineFont, _G.ObjectiveTrackerHeaderFont
    if line then
        line:SetFont(ResolveFont(s.otLineFont), s.otLineSize or 12, Flags(s.otLineOutline or "OUTLINE"))
        local shadow = s.otLineOutline == "SHADOW"
        line:SetShadowOffset(shadow and 1 or 0, shadow and -1 or 0)
    end
    if head then
        head:SetFont(ResolveFont(s.otHeadFont), s.otHeadSize or 14, Flags(s.otHeadOutline or "OUTLINE"))
        local shadow = s.otHeadOutline == "SHADOW"
        head:SetShadowOffset(shadow and 1 or 0, shadow and -1 or 0)
    end
end

-- ============================================================================
-- Colours
-- ============================================================================

-- What Blizzard just set -> ours, or nil to leave it (failed, complete, timers).
local function QuestTitleColour(r, g, b)
    local s = Settings()
    if not s.otQuestColors then return end
    local C = OBJECTIVE_TRACKER_COLOR
    if not C then return end
    local hi
    if Same(C.Header, r, g, b) then hi = false elseif Same(C.HeaderHighlight, r, g, b) then hi = true else return end
    if s.otQuestClass then
        local cr, cg, cb = ClassRGB()
        if hi then return math.min(cr + 0.2, 1), math.min(cg + 0.2, 1), math.min(cb + 0.2, 1) end
        return cr, cg, cb
    end
    if hi then return RGB(s.otQuestHighlight, 0.282, 0.859, 0.984) end
    return RGB(s.otQuestColor, 0, 0.659, 1)
end

local function ObjectiveColour(r, g, b)
    local s = Settings()
    if not s.otObjColors then return end
    local C = OBJECTIVE_TRACKER_COLOR
    if not C then return end
    if Same(C.Normal, r, g, b) then return RGB(s.otObjColor, 0.842, 0.815, 0.677) end
    if Same(C.NormalHighlight, r, g, b) then return RGB(s.otObjHighlight, 0.992, 0.965, 0.827) end
end

local recolouring
local function HookColour(fs, pick)
    hooksecurefunc(fs, "SetTextColor", function(self, r, g, b)
        if recolouring or not Active() then return end
        local nr, ng, nb = pick(r, g, b)
        if nr then
            recolouring = true
            self:SetTextColor(nr, ng, nb)
            recolouring = false
        end
    end)
end

-- ============================================================================
-- Objective lines
-- ============================================================================

local function Progress(text)
    local s = Settings()
    if not (s.otColorProgress or s.otPercent) or type(text) ~= "string" then return text end
    local a, b = text:match("(%d+)%s*/%s*(%d+)")
    a, b = tonumber(a), tonumber(b)
    if not (a and b) or b == 0 then return text end
    local ratio = math.min(a / b, 1)
    local piece = a .. "/" .. b
    if s.otPercent then piece = piece .. (" (%d%%)"):format(math.floor(ratio * 100 + 0.5)) end
    if s.otColorProgress then
        local r = ratio < 0.5 and 1 or (1 - ratio) * 2
        local g = ratio < 0.5 and ratio * 2 or 1
        piece = ("|cff%02x%02x%02x%s|r"):format(math.floor(r * 230 + 25), math.floor(g * 230 + 25), 40, piece)
    end
    local s1, e1 = text:find("%d+%s*/%s*%d+")
    if not s1 then return text end
    return text:sub(1, s1 - 1) .. piece .. text:sub(e1 + 1)
end

-- The objective text is rewritten ONLY from Blizzard's own text, kept in
-- original[fs] as Blizzard sets it. Rewriting whatever the string holds now
-- fed our own output back in: the digits of a colour code matched "%d+/%d+"
-- and every refresh nested another one (V2.8 testing, 2026-11-27).
-- The SetText post-hook runs before Blizzard measures the line, so a line
-- that wraps because of the percentage is given its real height.
local original = {}
local rewriting

local function Rewrite(fs)
    local base = original[fs]
    if not base then return end
    local new = Active() and Progress(base) or base
    if fs:GetText() ~= new then
        rewriting = true
        fs:SetText(new)
        rewriting = false
    end
end

local hookedLines = {}
local function StyleLine(line)
    local fs = line.Text
    if fs and not hookedLines[line] then
        hookedLines[line] = true
        HookColour(fs, ObjectiveColour)
        hooksecurefunc(fs, "SetText", function(self, text)
            if rewriting then return end
            if type(text) == "string" and (not canaccessvalue or canaccessvalue(text)) then
                original[self] = text
                Rewrite(self)
            else
                original[self] = nil
            end
        end)
        -- Set before the hook existed, so still Blizzard's own text.
        local text = fs:GetText()
        if type(text) == "string" and (not canaccessvalue or canaccessvalue(text)) then original[fs] = text end
    end
    local dash = line.Dash
    if dash then
        if Settings().otNoDash and Active() then
            dash:Hide()
            dash:SetText(nil)
        elseif line.dashStyle == OBJECTIVE_DASH_STYLE_SHOW and not dash:IsShown() then
            dash:SetText(QUEST_DASH)
            dash:Show()
        end
    end
    if fs then Rewrite(fs) end
end

local hookedBlocks = {}
local function StyleBlock(block)
    if not hookedBlocks[block] then
        hookedBlocks[block] = true
        if block.HeaderText then HookColour(block.HeaderText, QuestTitleColour) end
        if block.AddObjective then
            hooksecurefunc(block, "AddObjective", function(self, key)
                if not Active() then return end
                local line = self.usedLines and self.usedLines[key]
                if line then StyleLine(line) end
            end)
        end
    end
    if block.HeaderText then
        local r, g, b = block.HeaderText:GetTextColor()
        local nr, ng, nb = QuestTitleColour(r, g, b)
        if nr then
            recolouring = true
            block.HeaderText:SetTextColor(nr, ng, nb)
            recolouring = false
        end
    end
    for _, line in pairs(block.usedLines or {}) do StyleLine(line) end
end

-- ============================================================================
-- Section headers and their bars
-- ============================================================================

local bars = {}
local function StyleHeader(header)
    local fs = header and header.Text
    if not fs then return end
    local s = Settings()
    if s.otHeadClass then
        fs:SetTextColor(ClassRGB())
    else
        fs:SetTextColor(RGB(s.otHeadColor, 1, 1, 1))
    end
    local bar = bars[header]
    if not bar then
        bar = header:CreateTexture(nil, "ARTWORK")
        bar:SetTexture("Interface\\Buttons\\WHITE8x8")
        bars[header] = bar
    end
    if not s.otBar then bar:Hide() return end
    bar:ClearAllPoints()
    bar:SetPoint("LEFT", fs, "LEFT", s.otBarX or 0, s.otBarY or -12)
    bar:SetSize(s.otBarWidth or 250, s.otBarHeight or 2)
    local mode = s.otBarMode or "GRADIENT"
    if mode == "CLASS" then
        bar:SetGradient("HORIZONTAL", CreateColor(ClassRGB()), CreateColor(ClassRGB()))
    elseif mode == "SOLID" then
        local r, g, b = RGB(s.otBarColor1, 0.329, 0.522, 0.933)
        bar:SetGradient("HORIZONTAL", CreateColor(r, g, b, 1), CreateColor(r, g, b, 1))
    else
        local r1, g1, b1 = RGB(s.otBarColor1, 0.329, 0.522, 0.933)
        local r2, g2, b2 = RGB(s.otBarColor2, 0.259, 0.843, 0.867)
        bar:SetGradient("HORIZONTAL", CreateColor(r1, g1, b1, 1), CreateColor(r2, g2, b2, 1))
    end
    bar:Show()
end

local MODULE_NAMES = {
    "ScenarioObjectiveTracker", "UIWidgetObjectiveTracker", "CampaignQuestObjectiveTracker",
    "QuestObjectiveTracker", "AdventureObjectiveTracker", "AchievementObjectiveTracker",
    "MonthlyActivitiesObjectiveTracker", "ProfessionsRecipeTracker", "BonusObjectiveTracker",
    "WorldQuestObjectiveTracker", "InitiativeTasksObjectiveTracker",
}

local function Modules()
    local list, seen = {}, {}
    local frame = _G.ObjectiveTrackerFrame
    for _, m in ipairs(frame and frame.modules or {}) do
        if not seen[m] then seen[m] = true list[#list + 1] = m end
    end
    for _, name in ipairs(MODULE_NAMES) do
        local m = _G[name]
        if m and not seen[m] then seen[m] = true list[#list + 1] = m end
    end
    return list
end

local hookedModules = {}
local function StyleModule(m)
    if not hookedModules[m] then
        hookedModules[m] = true
        if m.AddBlock then
            hooksecurefunc(m, "AddBlock", function(_, block)
                if Active() and block then StyleBlock(block) end
            end)
        end
        if m.Update then
            hooksecurefunc(m, "Update", function(self)
                if Active() then StyleHeader(self.Header) end
            end)
        end
    end
    StyleHeader(m.Header)
    if m.EnumerateActiveBlocks then
        m:EnumerateActiveBlocks(StyleBlock)
    end
end

local function StyleTitle()
    local frame = _G.ObjectiveTrackerFrame
    local fs = frame and frame.Header and frame.Header.Text
    if not fs then return end
    local s = Settings()
    if s.otTitleClass then
        fs:SetTextColor(ClassRGB())
    else
        fs:SetTextColor(RGB(s.otTitleColor, 0, 0.659, 1))
    end
end

-- ============================================================================
-- Apply
-- ============================================================================

local hookedSize
function OT.Apply()
    if not Active() then
        for _, bar in pairs(bars) do bar:Hide() end
        return
    end
    OT.styled = true
    ApplyFonts()
    if not hookedSize and ObjectiveTrackerManager and ObjectiveTrackerManager.SetTextSize then
        hookedSize = true
        -- Edit Mode's text size swaps the font objects back; put ours on again.
        hooksecurefunc(ObjectiveTrackerManager, "SetTextSize", function() if Active() then ApplyFonts() end end)
    end
    for _, m in ipairs(Modules()) do StyleModule(m) end
    StyleTitle()
end

-- ============================================================================
-- WindTools' Objective Tracker, copied once per profile
-- ============================================================================

local function MapOutline(o)
    if o == "OUTLINE" or o == "THICKOUTLINE" or o == "NONE" or o == "SHADOW" then return o end
    if type(o) == "string" and o:find("OUTLINE") then return "OUTLINE" end
    return nil
end

local function Colour(c)
    if type(c) == "table" and tonumber(c.r) then
        return { r = tonumber(c.r), g = tonumber(c.g) or 0, b = tonumber(c.b) or 0 }
    end
end

local function Seed()
    local s = BH.settings
    if not s or s.otSeededFromWT then return end
    local t = WTTracker()
    if not t then return end
    s.otSeededFromWT = true
    if t.enable then s.otEnabled = true end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local function Font(f, prefix)
        if type(f) ~= "table" then return end
        if type(f.name) == "string" and lsm and lsm:IsValid("font", f.name) then s[prefix .. "Font"] = f.name end
        if tonumber(f.size) then s[prefix .. "Size"] = tonumber(f.size) end
        s[prefix .. "Outline"] = MapOutline(f.style) or s[prefix .. "Outline"]
    end
    if t.noDash ~= nil then s.otNoDash = t.noDash and true or false end
    if t.colorfulProgress ~= nil then s.otColorProgress = t.colorfulProgress and true or false end
    if t.percentage ~= nil then s.otPercent = t.percentage and true or false end
    if type(t.header) == "table" then
        Font(t.header, "otHead")
        if t.header.classColor ~= nil then s.otHeadClass = t.header.classColor and true or false end
        s.otHeadColor = Colour(t.header.color) or s.otHeadColor
    end
    Font(t.info, "otLine")
    if type(t.titleColor) == "table" then
        if t.titleColor.enable ~= nil then s.otQuestColors = t.titleColor.enable and true or false end
        if t.titleColor.classColor ~= nil then s.otQuestClass = t.titleColor.classColor and true or false end
        s.otQuestColor = Colour(t.titleColor.customColorNormal) or s.otQuestColor
        s.otQuestHighlight = Colour(t.titleColor.customColorHighlight) or s.otQuestHighlight
    end
    if type(t.infoColor) == "table" then
        if t.infoColor.enable ~= nil then s.otObjColors = t.infoColor.enable and true or false end
        s.otObjColor = Colour(t.infoColor.customColorNormal) or s.otObjColor
        s.otObjHighlight = Colour(t.infoColor.customColorHighlight) or s.otObjHighlight
    end
    if type(t.menuTitle) == "table" then
        if t.menuTitle.classColor ~= nil then s.otTitleClass = t.menuTitle.classColor and true or false end
        s.otTitleColor = Colour(t.menuTitle.color) or s.otTitleColor
    end
    local b = t.cosmeticBar
    if type(b) == "table" then
        if b.enable ~= nil then s.otBar = b.enable and true or false end
        if tonumber(b.width) then s.otBarWidth = tonumber(b.width) end
        if tonumber(b.height) then s.otBarHeight = tonumber(b.height) end
        if tonumber(b.offsetX) then s.otBarX = tonumber(b.offsetX) end
        if tonumber(b.offsetY) then s.otBarY = tonumber(b.offsetY) end
        local c = b.color
        if type(c) == "table" then
            if c.mode == "CLASS" then s.otBarMode = "CLASS"
            elseif c.mode == "NORMAL" then
                s.otBarMode = "SOLID"
                s.otBarColor1 = Colour(c.normalColor) or s.otBarColor1
            else
                s.otBarMode = "GRADIENT"
                s.otBarColor1 = Colour(c.gradientColor1) or s.otBarColor1
                s.otBarColor2 = Colour(c.gradientColor2) or s.otBarColor2
            end
        end
    end
    BH:SaveSettings()
end

function BH:ApplyObjectiveTracker()
    Seed()
    OT.Apply()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        BH:ApplyObjectiveTracker()
    else
        -- The tracker builds its blocks on entering the world; style them.
        C_Timer.After(1, function() if Active() then OT.Apply() end end)
    end
end)
