-- Maps/Minimap.lua
-- The minimap, ElvUI-style: square (or round), its size and scale, placed in
-- Edit Mode, with a thin edge; Blizzard's header, zoom buttons and compass
-- cleared; the zone name on top (always, on mouseover, or never), coloured by
-- the zone's PvP status; the icons round it (tracking, mail, crafting orders,
-- instance difficulty, the expansion summary, calendar, event, add-on list)
-- each placed, sized or hidden; right-click for tracking, middle-click (or
-- Shift-right) for a menu of the game's windows; zoom that resets itself.
--
-- ElvUI's code was read for behaviour only. The frames moved here are all
-- Blizzard's own and none is protected, so moving them changes nothing about
-- how they work. The data text strip (DataTexts/Panel.lua) anchors to the
-- Minimap itself, so it follows.
--
-- Works on retail and WoW Forever: the pieces differ a little (Forever has a
-- day/night dial and a compass underlay, retail an event button), so every
-- one is looked up and skipped when missing.
--
-- Waits while ElvUI's minimap is on. Turning this off needs a /reload to put
-- Blizzard's minimap back as it was.

local addonName, ns = ...
local BH = ns.BH

local MM = {}
ns.MinimapFrame = MM

local function Elv()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

function MM.ElvUIOn()
    local E = Elv()
    local p = E and E.private and E.private.general and E.private.general.minimap
    return p and p.enable and true or false
end

-- Reads fall back to the registered defaults: BH.settings only holds what
-- has been set.
local settingsView = setmetatable({}, { __index = function(_, k)
    local s = BH.settings
    local v = s and s[k]
    if v == nil and BH.defaultSettings then v = BH.defaultSettings[k] end
    return v
end })
local function Settings() return settingsView end
local function Active() return BH.settings and BH.settings.mmEnabled and not MM.ElvUIOn() and Minimap ~= nil end
local function Apply() if MM.Apply then MM.Apply() end end

-- ============================================================================
-- Settings
-- ============================================================================

local POINTS = {
    { text = "Top left", value = "TOPLEFT" }, { text = "Top", value = "TOP" }, { text = "Top right", value = "TOPRIGHT" },
    { text = "Left", value = "LEFT" }, { text = "Centre", value = "CENTER" }, { text = "Right", value = "RIGHT" },
    { text = "Bottom left", value = "BOTTOMLEFT" }, { text = "Bottom", value = "BOTTOM" },
    { text = "Bottom right", value = "BOTTOMRIGHT" },
}
local OUTLINES = {
    { text = "None", value = "NONE" }, { text = "Shadow", value = "SHADOW" },
    { text = "Outline", value = "OUTLINE" }, { text = "Thick outline", value = "THICKOUTLINE" },
}
local function Fonts() return BH:BuildFontDropdownItems() end

-- The icons round the minimap, with ElvUI's default places.
local function Cluster() return MinimapCluster end
local ICONS = {
    { key = "Tracking", label = "Tracking", point = "BOTTOMLEFT", x = 3, y = 3, scale = 1.2, hide = false,
      get = function() local c = Cluster(); return c and c.Tracking end, offscreen = true },
    { key = "Mail", label = "Mail", point = "TOPRIGHT", x = 3, y = 4, scale = 1, hide = false,
      get = function() local c = Cluster(); local i = c and c.IndicatorFrame; return i and i.MailFrame end },
    { key = "Crafting", label = "Crafting Orders", point = "TOPRIGHT", x = -23, y = -3, scale = 1, hide = false,
      get = function() local c = Cluster(); local i = c and c.IndicatorFrame; return i and i.CraftingOrderFrame end },
    { key = "Difficulty", label = "Instance Difficulty", point = "TOPLEFT", x = 10, y = 1, scale = 1, hide = false,
      get = function() local c = Cluster(); return (c and c.InstanceDifficulty) or _G.MiniMapInstanceDifficulty end },
    { key = "Expansion", label = "Expansion Summary", point = "BOTTOMLEFT", x = 0, y = 0, scale = 0.8, hide = false,
      get = function() return _G.ExpansionLandingPageMinimapButton end },
    { key = "Calendar", label = "Calendar", point = "TOPRIGHT", x = 0, y = 0, scale = 1.2, hide = true,
      get = function() return _G.GameTimeFrame end },
    { key = "Event", label = "Event Link", point = "TOPLEFT", x = 0, y = 0, scale = 0.8, hide = false,
      get = function() return _G.MinimapBackdrop and rawget(_G.MinimapBackdrop, "ExternalEventURLButton") end },
    { key = "Addons", label = "Add-on List", point = "BOTTOMRIGHT", x = 0, y = 0, scale = 1, hide = false,
      get = function() return _G.AddonCompartmentFrame end },
}

local iconRows = {}
for _, icon in ipairs(ICONS) do
    local k = "mmIcon" .. icon.key
    local function Shown(s) return not s[k .. "Hide"] end
    iconRows[#iconRows + 1] = { type = "header", label = icon.label:upper() }
    iconRows[#iconRows + 1] = { key = k .. "Hide", type = "check", default = icon.hide, label = "Hide" }
    iconRows[#iconRows + 1] = { key = k .. "Point", type = "dropdown", default = icon.point, items = POINTS,
                                label = "Corner", when = Shown }
    iconRows[#iconRows + 1] = { key = k .. "Scale", type = "slider", default = icon.scale, min = 0.4, max = 2,
                                step = 0.05, label = "Scale", when = Shown }
    iconRows[#iconRows + 1] = { key = k .. "X", type = "slider", default = icon.x, min = -50, max = 50, step = 1,
                                label = "Offset X", when = Shown }
    iconRows[#iconRows + 1] = { key = k .. "Y", type = "slider", default = icon.y, min = -50, max = 50, step = 1,
                                label = "Offset Y", when = Shown }
end

local reloadAsked
MM.SETTINGS = ns.Settings.Describe({
    master = "mmEnabled",
    apply = Apply,
    pages = {
        { key = "general", label = "General", rows = {
            { key = "mmEnabled", type = "check", default = false, label = "Restyle the Minimap",
              tip = "A square minimap you size and place in Edit Mode, with Blizzard's header and buttons cleared "
                .. "and the icons round it placed your way.\n\nWaits while ElvUI's minimap is on (ElvUI > Maps > "
                .. "Minimap > Enable, then /reload).",
              apply = function(v)
                  if v and MM.ElvUIOn() then
                      print("|cff33cc99Squizzumables:|r ElvUI's minimap is still on. Turn it off in ElvUI, /reload, "
                          .. "and this takes over.")
                  elseif not v and MM.styled and not reloadAsked then
                      reloadAsked = true
                      print("|cff33cc99Squizzumables:|r Blizzard's minimap comes back after a /reload.")
                  end
              end },
            { key = "mmSize", type = "slider", default = 175, min = 100, max = 400, step = 1, label = "Size" },
            { key = "mmScale", type = "slider", default = 1, min = 0.5, max = 2, step = 0.05, label = "Scale",
              tip = "Scales the icons round it too." },
            { key = "mmRound", type = "check", default = false, label = "Round Instead of Square" },
            { key = "mmRotate", type = "check", default = false, label = "Rotate With You",
              tip = "The game's Rotate Minimap option." },
            { key = "mmEdge", type = "check", default = true, label = "Border" },
            { key = "mmEdgeSize", type = "slider", default = 1, min = 1, max = 6, step = 1, label = "Border Size",
              when = function(s) return s.mmEdge ~= false end },
            { key = "mmEdgeClass", type = "check", default = false, label = "Border in Your Class Colour",
              when = function(s) return s.mmEdge ~= false end },
            { key = "mmEdgeColor", type = "color", default = { r = 0, g = 0, b = 0 }, label = "Border Colour",
              when = function(s) return s.mmEdge ~= false and not s.mmEdgeClass end },
            { type = "header", label = "MOUSE" },
            { key = "mmRightClick", type = "check", default = true, label = "Right-Click for Tracking" },
            { key = "mmMenu", type = "check", default = true, label = "Middle-Click for the Game Menu",
              tip = "Or Shift-right-click. Your character, spellbook, talents, collections and the rest. "
                .. "Not in combat." },
            { key = "mmResetZoom", type = "check", default = false, label = "Zoom Back Out by Itself" },
            { key = "mmResetZoomTime", type = "slider", default = 3, min = 1, max = 15, step = 1,
              label = "After (Seconds)", when = function(s) return s.mmResetZoom end },
            { type = "header", label = "CLOCK" },
            { key = "mmClock", type = "check", default = false, label = "Show Blizzard's Clock",
              tip = "Under the minimap. ElvUI hides it with the rest of the header; the Time data text shows the "
                .. "same." },
            { key = "mmClockFont", type = "dropdown", default = "__default", items = Fonts, label = "Font",
              when = function(s) return s.mmClock end },
            { key = "mmClockSize", type = "slider", default = 14, min = 6, max = 30, step = 1, label = "Size",
              when = function(s) return s.mmClock end },
            { key = "mmClockOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES, label = "Outline",
              when = function(s) return s.mmClock end },
        } },
        { key = "zone", label = "Zone Name", rows = {
            { key = "mmZone", type = "dropdown", default = "MOUSEOVER", label = "Zone Name",
              items = { { text = "Always", value = "SHOW" }, { text = "On mouseover", value = "MOUSEOVER" },
                        { text = "Never", value = "HIDE" } } },
            { key = "mmZoneFont", type = "dropdown", default = "__default", items = Fonts, label = "Font" },
            { key = "mmZoneSize", type = "slider", default = 14, min = 6, max = 30, step = 1, label = "Size" },
            { key = "mmZoneOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES, label = "Outline" },
        } },
        { key = "icons", label = "Icons", rows = iconRows },
    },
})

function BH:BuildMinimapTab(parent)
    ns.Settings.Build(MM.SETTINGS, parent)
end

-- ============================================================================
-- Helpers
-- ============================================================================

local hidden = CreateFrame("Frame")
hidden:Hide()

local function ResolveFont(name)
    if name and name ~= "__default" then
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        local path = lsm and lsm:Fetch("font", name, true)
        if path then return path end
    end
    return STANDARD_TEXT_FONT
end

local function SetFont(fs, font, size, outline)
    if not fs then return end
    local flags = (outline == "OUTLINE" or outline == "THICKOUTLINE") and outline or ""
    fs:SetFont(ResolveFont(font), size, flags)
    local shadow = outline == "SHADOW"
    fs:SetShadowOffset(shadow and 1 or 0, shadow and -1 or 0)
    fs:SetShadowColor(0, 0, 0, shadow and 1 or 0)
end

local function Stash(frame)
    if frame and frame.GetParent and frame:GetParent() ~= hidden then
        frame:SetParent(hidden)
    end
end

-- ============================================================================
-- Holder, mover, edge
-- ============================================================================

local SQUARE_MASK = 130937  -- a plain white square
local ROUND_MASK = 186178   -- the game's round minimap mask, by file ID (the old path no longer resolves)

local holder, mover, edge, zoneText
local DEFAULT_POS = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 4, y = -4 }

local function SavePosition()
    local left, top = holder:GetLeft(), holder:GetTop()
    if not left then return end
    BH.settings.mmPosition = { point = "TOPLEFT", relPoint = "TOPLEFT",
        x = math.floor(left + 0.5), y = math.floor(top - UIParent:GetHeight() + 0.5) }
    BH:SaveSettings()
end

local function Build()
    if holder then return end
    holder = CreateFrame("Frame", "SquizzumablesMinimapHolder", UIParent)
    holder:SetMovable(true)
    holder:SetClampedToScreen(true)

    -- Edit Mode drags this; it sits over the minimap only while unlocked.
    mover = CreateFrame("Frame", "SquizzumablesMinimapMover", UIParent)
    mover:SetAllPoints(holder)
    mover:SetFrameStrata("MEDIUM")
    mover:SetFrameLevel(50)
    mover:RegisterForDrag("LeftButton")
    mover:SetScript("OnDragStart", function()
        if InCombatLockdown() or not BH.unlockMode then return end
        BH:GridStartMoving(holder)
    end)
    mover:SetScript("OnDragStop", function()
        BH:GridStopMoving(holder)
        SavePosition()
        Apply()
    end)
    mover:Hide()
    BH.minimapMover = mover

    edge = CreateFrame("Frame", nil, holder)
    edge:SetFrameStrata("BACKGROUND")
    local bg = edge:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 1)
    edge.bg = bg
    -- The round map's border: the same mask as the map, on a slightly larger
    -- square, so only a ring shows round the map.
    local mask = edge:CreateMaskTexture()
    mask:SetAllPoints()
    mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    edge.mask = mask

    zoneText = Minimap:CreateFontString(nil, "OVERLAY")
    zoneText:SetPoint("TOP", Minimap, "TOP", 0, -3)
    zoneText:SetJustifyH("CENTER")
    zoneText:SetWordWrap(false)
    zoneText:Hide()
end

function MM.Nudge(dx, dy)
    local s = BH.settings
    if not s then return end
    local pos = s.mmPosition or DEFAULT_POS
    s.mmPosition = { point = pos.point, relPoint = pos.relPoint, x = (pos.x or 0) + dx, y = (pos.y or 0) + dy }
    BH:SaveSettings()
    Apply()
end

-- ============================================================================
-- Zone name
-- ============================================================================

local PVP_COLORS = {
    arena = { 0.84, 0.03, 0.03 }, friendly = { 0.05, 0.85, 0.03 }, contested = { 0.9, 0.85, 0.05 },
    hostile = { 0.84, 0.03, 0.03 }, sanctuary = { 0.035, 0.58, 0.84 }, combat = { 0.84, 0.03, 0.03 },
}

local function UpdateZone()
    if not (zoneText and Active()) then return end
    local s = Settings()
    if s.mmZone == "HIDE" then zoneText:Hide() return end
    local pvp = (C_PvP and C_PvP.GetZonePVPInfo or GetZonePVPInfo)()
    local c = (canaccessvalue(pvp) and pvp and PVP_COLORS[pvp]) or { 0.9, 0.85, 0.05 }
    zoneText:SetTextColor(c[1], c[2], c[3])
    zoneText:SetText(GetMinimapZoneText() or "")
    if s.mmZone ~= "MOUSEOVER" then zoneText:Show() end
end

-- ============================================================================
-- Icons and Blizzard's pieces
-- ============================================================================

local origParent = {}
local placing

local function PlaceIcons()
    if placing or not Active() or InCombatLockdown() then return end
    placing = true
    local s = Settings()
    for _, icon in ipairs(ICONS) do
        local f = icon.get()
        if f then
            if origParent[f] == nil then origParent[f] = f:GetParent() end
            local k = "mmIcon" .. icon.key
            local hide = s[k .. "Hide"]
            if hide == nil then hide = icon.hide end
            f:ClearAllPoints()
            if hide and icon.offscreen then
                -- The tracking menu errors when its button's parent is hidden.
                f:SetPoint("BOTTOM", UIParent, "TOP", 0, 5000)
            elseif hide then
                f:SetParent(hidden)
            else
                if origParent[f] and f:GetParent() ~= origParent[f] then f:SetParent(origParent[f]) end
                local point = s[k .. "Point"] or icon.point
                f:SetPoint(point, Minimap, point, s[k .. "X"] or icon.x, s[k .. "Y"] or icon.y)
                f:SetScale(s[k .. "Scale"] or icon.scale)
            end
        end
    end
    placing = false
end

local function Clock()
    local clock = _G.TimeManagerClockButton
    if not clock then return end
    local s = Settings()
    if s.mmClock then
        if origParent[clock] then clock:SetParent(origParent[clock]) end
        clock:ClearAllPoints()
        clock:SetPoint("BOTTOM", Minimap, "BOTTOM", 0, 2)
        for _, r in ipairs({ clock:GetRegions() }) do
            if r:IsObjectType("Texture") then r:SetAlpha(0) end
        end
        SetFont(_G.TimeManagerClockTicker, s.mmClockFont, s.mmClockSize or 14, s.mmClockOutline or "OUTLINE")
    else
        if origParent[clock] == nil then origParent[clock] = clock:GetParent() end
        Stash(clock)
    end
end

local function ClearBlizzard()
    local c = Cluster()
    if c then
        Stash(c.BorderTop)
        Stash(c.ZoneTextButton)
        Stash(rawget(c, "DielFrame"))   -- Forever's day/night dial
        c:EnableMouse(false)
        local container = c.MinimapContainer
        if container and container.PlayerCoords then Stash(container.PlayerCoords) end
        -- The mail and crafting icons are placed one by one; stop their row
        -- from laying them out again.
        local ind = c.IndicatorFrame
        if ind and ind.Layout and not ind.sqOrigLayout then
            ind.sqOrigLayout = ind.Layout
            ind.Layout = function() end
        end
    end
    Stash(Minimap.ZoomIn)
    Stash(Minimap.ZoomOut)
    Stash(_G.MinimapZoomIn)
    Stash(_G.MinimapZoomOut)
    if _G.MinimapCompassTextureUnderlay then _G.MinimapCompassTextureUnderlay:SetAlpha(0) end
    for _, fn in ipairs({ "SetArchBlobRingAlpha", "SetArchBlobRingScalar", "SetQuestBlobRingAlpha",
                          "SetQuestBlobRingScalar", "SetTaskBlobRingAlpha", "SetTaskBlobRingScalar" }) do
        if Minimap[fn] then Minimap[fn](Minimap, 0) end
    end
end

-- ============================================================================
-- Shape
-- ============================================================================

local function Shape()
    local round = Settings().mmRound
    Minimap:SetMaskTexture(round and ROUND_MASK or SQUARE_MASK)
    -- Blizzard's compass ring never shows: the round map wears our own border,
    -- the edge drawn through the same round mask (see Apply).
    local compass = _G.MinimapCompassTexture
    if compass then compass:Hide() end
    if edge and edge.mask then
        if round and not edge.masked then
            edge.bg:AddMaskTexture(edge.mask)
            edge.masked = true
        elseif not round and edge.masked then
            edge.bg:RemoveMaskTexture(edge.mask)
            edge.masked = false
        end
    end
    -- Other add-ons place their minimap buttons by this.
    _G.GetMinimapShape = function() return round and "ROUND" or "SQUARE" end
    local hybrid = _G.HybridMinimap
    if hybrid and hybrid.MapCanvas and not round then
        pcall(hybrid.MapCanvas.SetMaskTexture, hybrid.MapCanvas)
        if hybrid.CircleMask then hybrid.CircleMask:SetAlpha(0) end
    end
end

-- ============================================================================
-- Mouse
-- ============================================================================

local MENU = {
    { "CharacterMicroButton", "CHARACTER_BUTTON" }, { "ProfessionMicroButton", "PROFESSIONS_BUTTON" },
    { "PlayerSpellsMicroButton", "PLAYERSPELLS_BUTTON" }, { "SpellbookMicroButton", "SPELLBOOK_ABILITIES_BUTTON" },
    { "TalentMicroButton", "TALENTS_BUTTON" }, { "AchievementMicroButton", "ACHIEVEMENT_BUTTON" },
    { "QuestLogMicroButton", "QUESTLOG_BUTTON" }, { "HousingMicroButton", "HOUSING_MICRO_BUTTON" },
    { "GuildMicroButton", "GUILD_AND_COMMUNITIES" }, { "LFDMicroButton", "DUNGEONS_BUTTON" },
    { "CollectionsMicroButton", "COLLECTIONS" }, { "EJMicroButton", "ADVENTURE_JOURNAL" },
    { "StoreMicroButton", "BLIZZARD_STORE" }, { "HelpMicroButton", "HELP_BUTTON" },
}

local function GameMenu()
    if InCombatLockdown() then
        print("|cff33cc99Squizzumables:|r the game menu can't open in combat.")
        return
    end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(Minimap, function(_, root)
        for _, m in ipairs(MENU) do
            local b = _G[m[1]]
            if b and b.Click and b:IsEnabled() then
                local label = rawget(_G, m[2]) or b.tooltipText or (m[1]:gsub("MicroButton", ""))
                root:CreateButton(label, function() b:Click() end)
            end
        end
        if ToggleCalendar then root:CreateButton(rawget(_G, "CALENDAR") or "Calendar", function() ToggleCalendar() end) end
    end)
end

local function OnMouseUp(_, button)
    if not Active() then return end
    local s = Settings()
    if (button == "MiddleButton" or (button == "RightButton" and IsShiftKeyDown())) and s.mmMenu ~= false then
        GameMenu()
    elseif button == "RightButton" and s.mmRightClick ~= false then
        local c = Cluster()
        local b = c and c.Tracking and c.Tracking.Button
        if b and b.OpenMenu then b:OpenMenu() end
    end
end

local resetting
local function OnZoom()
    local s = Settings()
    if resetting or not (Active() and s.mmResetZoom) then return end
    resetting = true
    C_Timer.After(s.mmResetZoomTime or 3, function()
        Minimap:SetZoom(0)
        resetting = false
    end)
end

-- ============================================================================
-- Apply
-- ============================================================================

local hooked
local function Hook()
    if hooked then return end
    hooked = true
    Minimap:HookScript("OnMouseUp", OnMouseUp)
    Minimap:HookScript("OnEnter", function()
        if Active() and Settings().mmZone == "MOUSEOVER" then zoneText:Show() end
    end)
    Minimap:HookScript("OnLeave", function()
        if Active() and Settings().mmZone == "MOUSEOVER" then zoneText:Hide() end
    end)
    hooksecurefunc(Minimap, "SetZoom", OnZoom)
    local c = Cluster()
    if c then
        -- Edit Mode's minimap size, header and icon options put things back.
        for _, fn in ipairs({ "SetHeaderUnderneath", "SetIconScale", "SetShowPlayerCoords" }) do
            if c[fn] then hooksecurefunc(c, fn, function() if Active() then MM.Apply() end end) end
        end
        local container = c.MinimapContainer
        if container then
            hooksecurefunc(container, "SetScale", function(self, scale)
                if Active() and scale ~= 1 then self:SetScale(1) end
            end)
        end
    end
    if _G.MiniMapIndicatorFrame_UpdatePosition then
        hooksecurefunc("MiniMapIndicatorFrame_UpdatePosition", PlaceIcons)
    end
    local exp = _G.ExpansionLandingPageMinimapButton
    if exp and exp.UpdateIcon then hooksecurefunc(exp, "UpdateIcon", PlaceIcons) end

    local ev = CreateFrame("Frame")
    for _, e in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD",
                         "ADDON_LOADED", "PLAYER_REGEN_ENABLED" }) do
        ev:RegisterEvent(e)
    end
    ev:SetScript("OnEvent", function(_, event, arg)
        if not Active() then return end
        if event == "ADDON_LOADED" then
            if arg == "Blizzard_TimeManager" then Clock()
            elseif arg == "Blizzard_HybridMinimap" then Shape() end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if MM.pending then MM.pending = nil MM.Apply() end
        else
            UpdateZone()
            if event == "PLAYER_ENTERING_WORLD" then PlaceIcons() end
        end
    end)
end

function MM.Apply()
    if not Active() then
        if mover then mover:Hide() end
        return
    end
    if InCombatLockdown() then MM.pending = true return end
    Build()
    Hook()
    MM.styled = true
    local s = Settings()
    local size, scale = s.mmSize or 175, s.mmScale or 1

    local c = Cluster()
    if c then
        c:SetScale(scale)
        if c.MinimapContainer and c.MinimapContainer:GetScale() ~= 1 then c.MinimapContainer:SetScale(1) end
    end
    local pos = s.mmPosition or DEFAULT_POS
    holder:ClearAllPoints()
    holder:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    local border = s.mmEdge ~= false and (s.mmEdgeSize or 1) or 1
    holder:SetSize(size * scale + border * 2, size * scale + border * 2)

    Minimap:ClearAllPoints()
    Minimap:SetPoint("TOPRIGHT", holder, "TOPRIGHT", -border / scale, -border / scale)
    Minimap:SetSize(size, size)
    -- Nudge the map canvas so it redraws at the new size.
    local zoom = Minimap:GetZoom()
    Minimap:SetZoom(zoom > 0 and 0 or 1)
    Minimap:SetZoom(zoom)

    edge:ClearAllPoints()
    edge:SetAllPoints(holder)
    edge:SetShown(s.mmEdge ~= false)
    local ec = s.mmEdgeColor or { r = 0, g = 0, b = 0 }
    if s.mmEdgeClass then
        local _, class = UnitClass("player")
        ec = (C_ClassColor and C_ClassColor.GetClassColor(class)) or RAID_CLASS_COLORS[class] or ec
    end
    edge.bg:SetColorTexture(ec.r, ec.g, ec.b, 1)

    SetFont(zoneText, s.mmZoneFont, s.mmZoneSize or 14, s.mmZoneOutline or "OUTLINE")
    zoneText:SetWidth(size - 8)
    zoneText:SetShown(s.mmZone == "SHOW")

    pcall(SetCVar, "rotateMinimap", s.mmRotate and "1" or "0")

    ClearBlizzard()
    Shape()
    PlaceIcons()
    Clock()
    UpdateZone()

    mover:SetShown(BH.unlockMode and true or false)
    mover:EnableMouse(BH.unlockMode and true or false)
end

-- ============================================================================
-- ElvUI's minimap, copied once per profile
-- ============================================================================

local ICON_KEYS = { tracking = "Tracking", mail = "Mail", crafting = "Crafting", difficulty = "Difficulty",
                    classHall = "Expansion", calendar = "Calendar", externalEvent = "Event" }
local PRIVATE_HIDE = { hideTracking = "Tracking", hideCalendar = "Calendar", hideClassHallReport = "Expansion",
                       hideExternalEvent = "Event" }

local function MapOutline(o)
    if o == "OUTLINE" or o == "THICKOUTLINE" or o == "NONE" or o == "SHADOW" then return o end
    if type(o) == "string" and o:find("OUTLINE") then return "OUTLINE" end
    return nil
end

local function Seed()
    local s = BH.settings
    if not s or s.mmSeededFromElvUI then return end
    local E = Elv()
    local db = E and E.db and E.db.general and E.db.general.minimap
    if type(db) ~= "table" then return end
    s.mmSeededFromElvUI = true
    if MM.ElvUIOn() then s.mmEnabled = true end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local function Font(name) return type(name) == "string" and lsm and lsm:IsValid("font", name) and name or nil end
    local function Num(v, key) if tonumber(v) then s[key] = tonumber(v) end end
    Num(db.size, "mmSize")
    Num(db.scale, "mmScale")
    if db.circle ~= nil then s.mmRound = db.circle and true or false end
    if db.rotate ~= nil then s.mmRotate = db.rotate and true or false end
    if db.locationText == "SHOW" or db.locationText == "MOUSEOVER" or db.locationText == "HIDE" then
        s.mmZone = db.locationText
    end
    s.mmZoneFont = Font(db.locationFont) or s.mmZoneFont
    Num(db.locationFontSize, "mmZoneSize")
    s.mmZoneOutline = MapOutline(db.locationFontOutline) or s.mmZoneOutline
    s.mmClockFont = Font(db.timeFont) or s.mmClockFont
    Num(db.timeFontSize, "mmClockSize")
    s.mmClockOutline = MapOutline(db.timeFontOutline) or s.mmClockOutline
    if db.clusterDisable == false then s.mmClock = true end
    if type(db.resetZoom) == "table" then
        if db.resetZoom.enable ~= nil then s.mmResetZoom = db.resetZoom.enable and true or false end
        Num(db.resetZoom.time, "mmResetZoomTime")
    end
    if type(db.icons) == "table" then
        for elvKey, ours in pairs(ICON_KEYS) do
            local i = db.icons[elvKey]
            if type(i) == "table" then
                local k = "mmIcon" .. ours
                Num(i.scale, k .. "Scale")
                Num(i.xOffset, k .. "X")
                Num(i.yOffset, k .. "Y")
                if type(i.position) == "string" then s[k .. "Point"] = i.position end
                if i.hide ~= nil then s[k .. "Hide"] = i.hide and true or false end
            end
        end
    end
    local p = E.private and E.private.general and E.private.general.minimap
    if type(p) == "table" then
        for elvKey, ours in pairs(PRIVATE_HIDE) do
            if p[elvKey] ~= nil then s["mmIcon" .. ours .. "Hide"] = p[elvKey] and true or false end
        end
    end
    local m = E.db.movers and E.db.movers.MinimapMover
    if type(m) == "string" then
        local pt, rel, relPt, x, y = strsplit(",", m)
        if (rel == "ElvUIParent" or rel == "UIParent") and tonumber(x) and tonumber(y) then
            s.mmPosition = { point = pt, relPoint = relPt, x = tonumber(x), y = tonumber(y) }
        end
    end
    BH:SaveSettings()
end

function BH:ApplyMinimap()
    Seed()
    MM.Apply()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function() BH:ApplyMinimap() end)
