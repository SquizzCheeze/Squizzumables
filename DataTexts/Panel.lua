-- DataTexts/Panel.lua
-- Data texts: a strip of short live readouts ("Guild: 12", "Friends: 5") that
-- list the people behind the number on hover and offer Invite / Whisper on a
-- right click. Built to replace ElvUI's data texts for the user, starting
-- with its minimap panel (Guild + Friends under the minimap).
--
-- ElvUI's licence forbids publishing any of its code, so nothing here is
-- copied from it: ElvUI was only read to see WHAT each text shows and does,
-- and everything is written fresh against Blizzard's API.
--
-- PIECES
--   * the registry: DT.Register(key, def) -- each text is its own file
--     (Guild.lua, Friends.lua) describing its label, events, the number it
--     shows, its tooltip and its clicks
--   * one panel frame of 1-3 slots, each slot showing one registered text.
--     Attached under the minimap by default (as ElvUI's is), or free-standing
--     and moved in Edit Mode. Its free position lives in the profile's
--     settings (dtPosition), not in a posKey: an attached panel is anchored to
--     the Minimap, and the generic posKey save would store that as a UIParent
--     offset and put it in the wrong place on the next load
--   * the shared helpers every text needs: tooltip anchoring, class / level /
--     zone colours, invite and whisper
--
-- ElvUI's settings are copied once per profile (dtSeededFromElvUI) the first
-- time this runs with ElvUI loaded -- font, size, outline, value colour, the
-- panel's two texts, the combat options -- so switching over looks the same.
-- The panel itself stays off until switched on: while ElvUI's own minimap
-- panel is showing, ours would sit on top of it.

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

local DT = {}
ns.DataTexts = DT

local S = BH.Secrets
local MAX_SLOTS = 3

-- ============================================================================
-- Registry
-- ============================================================================

local registry, order = {}, {}

--- def = {
---   label   = "Guild",                  -- shown in the slot dropdowns
---   events  = { "GUILD_ROSTER_UPDATE", ... },
---   onEvent = function(event, ...) end, -- optional, before the slots refresh
---   text    = function() return "Guild: 12" end,
---   onEnter = function(slot, tooltip) end,
---   onClick = function(slot, button) end,
---   onShow  = function() end,           -- optional, when a slot first shows it
--- }
function DT.Register(key, def)
    def.key = key
    registry[key] = def
    order[#order + 1] = key
end

function DT.SlotItems()
    local items = { { text = "None", value = "None" } }
    for _, key in ipairs(order) do
        items[#items + 1] = { text = registry[key].label, value = key }
    end
    return items
end

-- ============================================================================
-- Shared helpers
-- ============================================================================

function DT.Hex(r, g, b)
    return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

function DT.ValueHex()
    local c = BH.settings and BH.settings.dtValueColor or {}
    return DT.Hex(c.r or 1, c.g or 0.82, c.b or 0)
end

--- "Label: |cff..value|r", the shape every text uses.
function DT.Format(label, value)
    return label .. ": " .. DT.ValueHex() .. tostring(value) .. "|r"
end

-- Localised class name -> class file, for the friend APIs, which only give
-- the localised name.
local classFileOf = {}
for file, name in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do classFileOf[name] = file end
for file, name in pairs(LOCALIZED_CLASS_NAMES_FEMALE or {}) do classFileOf[name] = file end

function DT.ClassFile(localisedOrFile)
    if not localisedOrFile then return nil end
    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[localisedOrFile] then return localisedOrFile end
    return classFileOf[localisedOrFile]
end

function DT.ClassColor(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return 0.9, 0.9, 0.9
end

function DT.LevelColor(level)
    local c = level and level > 0 and GetQuestDifficultyColor and GetQuestDifficultyColor(level)
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- Green for the zone you are in, grey for anywhere else (ElvUI's two colours).
function DT.ZoneColor(zone)
    local here = S.SafeString(GetRealZoneText and GetRealZoneText())
    if zone and here and zone == here then return 0.3, 1.0, 0.3 end
    return 0.65, 0.65, 0.65
end

function DT.InGroup(name)
    if not name then return false end
    local inParty = UnitInParty(name)
    local inRaid = UnitInRaid(name)
    if S.IsSecret(inParty) or S.IsSecret(inRaid) then return false end
    return (inParty or inRaid) and true or false
end

--- Invite a character by name. With a GUID the game says whether we invite
--- them or ask them for an invite to their group (they lead one we're not in).
function DT.Invite(name, guid)
    if not name or name == "" then return end
    local kind = guid and GetDisplayedInviteType and GetDisplayedInviteType(guid)
    if kind == "REQUEST_INVITE" and C_PartyInfo.RequestInviteFromUnit then
        C_PartyInfo.RequestInviteFromUnit(name)
    else
        C_PartyInfo.InviteUnit(name)
    end
end

function DT.InviteBNet(gameAccountID, guid)
    if not gameAccountID then return end
    local kind = guid and GetDisplayedInviteType and GetDisplayedInviteType(guid)
    if kind == "REQUEST_INVITE" and BNRequestInviteFriend then
        BNRequestInviteFriend(gameAccountID)
    else
        BNInviteFriend(gameAccountID)
    end
end

function DT.Whisper(name)
    if name and name ~= "" then ChatFrameUtil.SendTell(name) end
end

function DT.WhisperBNet(accountName)
    if accountName then ChatFrameUtil.SendBNetTell(accountName) end
end

function DT.TooltipBlocked()
    return BH.settings and BH.settings.dtNoCombatHover and InCombatLockdown()
end

function DT.ClickBlocked()
    return BH.settings and BH.settings.dtNoCombatClick and InCombatLockdown()
end

-- Opens away from the nearer screen edge: below a panel in the top half (the
-- minimap is top left for the user), above one in the bottom half.
function DT.AnchorTooltip(slot)
    local tt = GameTooltip
    tt:SetOwner(slot, "ANCHOR_NONE")
    tt:ClearAllPoints()
    local _, cy = slot:GetCenter()
    local half = UIParent:GetHeight() / 2
    if cy and cy * slot:GetEffectiveScale() / UIParent:GetEffectiveScale() > half then
        tt:SetPoint("TOP", slot, "BOTTOM", 0, -4)
    else
        tt:SetPoint("BOTTOM", slot, "TOP", 0, 4)
    end
    return tt
end

-- ============================================================================
-- Settings
-- ============================================================================

local function Apply() if DT.Apply then DT.Apply() end end
local function Detached(s) return not s.dtAttachMinimap end
local function Attached(s) return s.dtAttachMinimap end
local function BackdropOn(s) return s.dtBackdrop end
local function BorderOn(s) return s.dtBorder end
local function SlotShown(n) return function(s) return (s.dtSlots or 2) >= n end end

local OUTLINES = {
    { text = "None",               value = "NONE" },
    { text = "Outline",            value = "OUTLINE" },
    { text = "Thick outline",      value = "THICKOUTLINE" },
    { text = "Shadow",             value = "SHADOW" },
    { text = "Shadow and outline", value = "SHADOWOUTLINE" },
}
local STRATAS = {
    { text = "Background", value = "BACKGROUND" },
    { text = "Low",        value = "LOW" },
    { text = "Medium",     value = "MEDIUM" },
    { text = "High",       value = "HIGH" },
}

DT.SETTINGS = ns.Settings.Describe({
    master = "dtEnabled",
    apply = Apply,
    pages = {
        { key = "panel", label = "Panel", rows = {
            { key = "dtEnabled", type = "check", default = false,
              label = "Show Data Texts",
              tip = "A strip of live readouts, such as how many guild members and friends are online. Hover one "
                .. "for the list, click it to open the window, right-click it to invite or whisper.\n\nIf "
                .. "ElvUI's own minimap data texts are still showing, turn those off in ElvUI (DataTexts > "
                .. "Panels > MinimapPanel) so the two don't sit on top of each other." },
            { key = "dtSlots", type = "slider", default = 2, min = 1, max = MAX_SLOTS, step = 1,
              label = "Number of Texts", tip = "How many readouts the panel holds, side by side." },
            { key = "dtSlot1", type = "dropdown", default = "Guild", items = DT.SlotItems,
              label = "Text 1", tip = "What the first (left) readout shows." },
            { key = "dtSlot2", type = "dropdown", default = "Friends", items = DT.SlotItems,
              label = "Text 2", tip = "What the second readout shows.", when = SlotShown(2) },
            { key = "dtSlot3", type = "dropdown", default = "None", items = DT.SlotItems,
              label = "Text 3", tip = "What the third readout shows.", when = SlotShown(3) },
            { type = "header", label = "POSITION" },
            { key = "dtAttachMinimap", type = "check", default = true,
              label = "Attach Under the Minimap",
              tip = "Sits under the minimap at its width, like ElvUI's minimap panel. Untick to place it "
                .. "anywhere in Edit Mode; it starts where it is now.",
              apply = function(v) if not v and DT.Detach then DT.Detach() end end },
            { key = "dtAttachOffsetX", type = "slider", default = 0, min = -50, max = 50, step = 1,
              label = "Offset X", tip = "Moves the attached panel left or right of the minimap.", when = Attached },
            { key = "dtAttachOffsetY", type = "slider", default = 0, min = -50, max = 50, step = 1,
              label = "Offset Y", tip = "Moves the attached panel up or down from the minimap's bottom edge.",
              when = Attached },
            { key = "dtWidth", type = "slider", default = 200, min = 50, max = 800, step = 1,
              label = "Width", tip = "The panel's width when it isn't attached to the minimap.", when = Detached },
            { key = "dtHeight", type = "slider", default = 22, min = 12, max = 48, step = 1,
              label = "Height", tip = "The panel's height." },
            { key = "dtStrata", type = "dropdown", default = "MEDIUM", items = STRATAS,
              label = "Frame Strata", tip = "How far in front of other frames the panel sits." },
            { type = "header", label = "BACKGROUND" },
            { key = "dtBackdrop", type = "check", default = true,
              label = "Background", tip = "A solid background behind the texts." },
            { key = "dtBackdropColor", type = "color", default = { r = 0.1, g = 0.1, b = 0.1 },
              label = "Background Colour", tip = "Colour of the background.", when = BackdropOn },
            { key = "dtBackdropAlpha", type = "slider", default = 100, min = 0, max = 100, step = 5,
              label = "Background Opacity", tip = "How solid the background is, in percent.", when = BackdropOn },
            { key = "dtBorder", type = "check", default = true,
              label = "Border", tip = "A one-pixel border round the panel." },
            { key = "dtBorderColor", type = "color", default = { r = 0, g = 0, b = 0 },
              label = "Border Colour", tip = "Colour of the border.",
              when = function(s) return BorderOn(s) and not s.dtBorderClassColor end },
            { key = "dtBorderClassColor", type = "check", default = false,
              label = "Class Colour Border",
              tip = "Colour the border with your class colour instead of the Border Colour above.",
              when = BorderOn },
        } },

        { key = "text", label = "Text", rows = {
            { key = "dtFont", type = "dropdown", default = "__default",
              items = function() return BH:BuildFontDropdownItems() end,
              label = "Font", tip = "The texts' font. Fonts from other addons (LibSharedMedia) are listed too." },
            { key = "dtFontSize", type = "slider", default = 12, min = 6, max = 24, step = 1,
              label = "Font Size", tip = "Size of the texts." },
            { key = "dtFontOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES,
              label = "Font Outline", tip = "An outline or shadow round the letters, so they read on any background." },
            { key = "dtLabelColor", type = "color", default = { r = 1, g = 1, b = 1 },
              label = "Label Colour", tip = "Colour of the words, such as \"Guild:\"." },
            { key = "dtValueColor", type = "color", default = { r = 1, g = 0.82, b = 0 },
              label = "Value Colour", tip = "Colour of the numbers." },
            { type = "header", label = "IN COMBAT" },
            { key = "dtNoCombatHover", type = "check", default = false,
              label = "No Tooltips in Combat", tip = "Hovering a text in combat shows nothing." },
            { key = "dtNoCombatClick", type = "check", default = false,
              label = "No Clicks in Combat", tip = "Clicking a text in combat does nothing." },
        } },

        { key = "guild", label = "Guild", rows = {
            { key = "dtGuildMaxLines", type = "slider", default = 30, min = 0, max = 100, step = 1,
              label = "Members Listed",
              tip = "How many online members the tooltip lists before \"and N more\". 0 lists everyone." },
            { key = "dtGuildShowMOTD", type = "check", default = true,
              label = "Show Message of the Day", tip = "The guild's message of the day at the top of the tooltip." },
            { key = "dtGuildLabel", type = "editbox", default = "Guild",
              label = "Label", tip = "The word in front of the number. Leave empty for the number alone." },
        } },

        { key = "friends", label = "Friends", rows = {
            { key = "dtFriendsHideAFK", type = "check", default = false,
              label = "Hide Away Friends", tip = "Leave friends who are away (AFK) out of the list." },
            { key = "dtFriendsHideDND", type = "check", default = false,
              label = "Hide Busy Friends", tip = "Leave friends set to busy (DND) out of the list." },
            { key = "dtFriendsHideApp", type = "check", default = false,
              label = "Hide Battle.net App and Mobile",
              tip = "Leave Battle.net friends who are only on the desktop app or the mobile app out of the list." },
            { key = "dtFriendsHideOtherGames", type = "check", default = false,
              label = "Hide Other Games",
              tip = "Leave Battle.net friends playing something other than World of Warcraft out of the list." },
            { key = "dtFriendsLabel", type = "editbox", default = "Friends",
              label = "Label", tip = "The word in front of the number. Leave empty for the number alone." },
        } },
    },
})

function BH:BuildDataTextsTab(parent)
    ns.Settings.Build(DT.SETTINGS, parent)
end

--- "Label: value", or the value alone when the label is set empty.
function DT.Labelled(labelKey, fallback, value)
    local label = BH.settings and BH.settings[labelKey]
    if label == nil then label = fallback end
    if label == "" then return DT.ValueHex() .. tostring(value) .. "|r" end
    return DT.Format(label, value)
end

-- ============================================================================
-- The panel
-- ============================================================================

local panel
local slots = {}
local ShareWidth   -- below; the panel's OnSizeChanged calls it

local function ResolveFont(name)
    if name and name ~= "__default" then
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        local path = lsm and lsm:Fetch("font", name, true)
        if path then return path end
    end
    return STANDARD_TEXT_FONT
end

local function StyleText(fs)
    local s = BH.settings
    local outline = s.dtFontOutline or "OUTLINE"
    local flags = (outline == "OUTLINE" or outline == "SHADOWOUTLINE") and "OUTLINE"
        or (outline == "THICKOUTLINE" and "THICKOUTLINE") or ""
    fs:SetFont(ResolveFont(s.dtFont), s.dtFontSize or 12, flags)
    if outline == "SHADOW" or outline == "SHADOWOUTLINE" then
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
    else
        fs:SetShadowOffset(0, 0)
    end
    local c = s.dtLabelColor or {}
    fs:SetTextColor(c.r or 1, c.g or 1, c.b or 1)
end

local function RefreshSlot(slot)
    local def = slot.key and registry[slot.key]
    if not def then
        slot.text:SetText("")
        return
    end
    local ok, text = pcall(def.text)
    slot.text:SetText(ok and text or def.label)
end

function DT.Refresh(key)
    for _, slot in ipairs(slots) do
        if slot:IsShown() and (key == nil or slot.key == key) then RefreshSlot(slot) end
    end
end

local function SlotEnter(slot)
    local def = slot.key and registry[slot.key]
    if not def or not def.onEnter or DT.TooltipBlocked() then return end
    slot.hovered = true
    local tt = DT.AnchorTooltip(slot)
    tt:ClearLines()
    def.onEnter(slot, tt)
    if tt:NumLines() > 0 then tt:Show() else tt:Hide() end
end

local function SlotLeave(slot)
    slot.hovered = nil
    if GameTooltip:IsOwned(slot) then GameTooltip:Hide() end
end

-- Holding or letting go of Shift while hovering redraws the tooltip, which is
-- how the Guild and Friends lists show their extra details.
local modWatch = CreateFrame("Frame")
modWatch:RegisterEvent("MODIFIER_STATE_CHANGED")
modWatch:SetScript("OnEvent", function()
    for _, slot in ipairs(slots) do
        if slot.hovered and slot:IsMouseOver() then SlotEnter(slot) end
    end
end)

--- Redraw an open tooltip after its data arrives (the guild roster comes in
--- a moment after it is asked for).
function DT.RefreshTooltip(key)
    for _, slot in ipairs(slots) do
        if slot.hovered and slot.key == key and slot:IsMouseOver() then SlotEnter(slot) end
    end
end

local function CreateSlot(i)
    local b = CreateFrame("Button", nil, panel)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetPoint("LEFT", 2, 0)
    b.text:SetPoint("RIGHT", -2, 0)
    b.text:SetJustifyH("CENTER")
    b.text:SetWordWrap(false)
    b:SetScript("OnEnter", SlotEnter)
    b:SetScript("OnLeave", SlotLeave)
    b:SetScript("OnClick", function(self, button)
        local def = self.key and registry[self.key]
        if not def or not def.onClick or DT.ClickBlocked() then return end
        GameTooltip:Hide()
        def.onClick(self, button)
    end)
    slots[i] = b
    return b
end

local function SavePosition()
    if not panel or not BH.settings then return end
    local cx, cy = panel:GetCenter()
    if not cx then return end
    local scale = panel:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    BH.settings.dtPosition = { x = cx * scale - ux, y = cy * scale - uy }
    BH:SaveSettings()
end

local function CreatePanel()
    if panel then return panel end
    panel = CreateFrame("Frame", "SquizzumablesDataTextPanel", UIParent, "BackdropTemplate")
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self)
        -- Edit Mode only: the panel keeps the mouse after it (its slots want
        -- hover and clicks), and a stray drag should not move it.
        if InCombatLockdown() or not BH.unlockMode or (BH.settings and BH.settings.dtAttachMinimap) then return end
        BH:GridStartMoving(self)
    end)
    panel:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(self)
        SavePosition()
        DT.Apply()
    end)
    -- An attached panel follows the minimap's width, so the slots are shared
    -- out again whenever its size changes.
    panel:SetScript("OnSizeChanged", function() ShareWidth() end)
    panel:Hide()
    for i = 1, MAX_SLOTS do CreateSlot(i) end
    BH.dataTextFrame = panel
    return panel
end

local function Place()
    local s = BH.settings
    panel:ClearAllPoints()
    if s.dtAttachMinimap and Minimap then
        local x, y = s.dtAttachOffsetX or 0, s.dtAttachOffsetY or 0
        panel:SetPoint("TOPLEFT", Minimap, "BOTTOMLEFT", x, y)
        panel:SetPoint("TOPRIGHT", Minimap, "BOTTOMRIGHT", x, y)
    else
        local pos = s.dtPosition or { x = 0, y = -200 }
        panel:SetPoint("CENTER", UIParent, "CENTER", pos.x, pos.y)
        panel:SetWidth(s.dtWidth or 200)
    end
    panel:SetHeight(s.dtHeight or 22)
end

local function Style()
    local s = BH.settings
    panel:SetFrameStrata(s.dtStrata or "MEDIUM")
    if s.dtBackdrop or s.dtBorder then
        panel:SetBackdrop({
            bgFile = s.dtBackdrop and "Interface\\Buttons\\WHITE8X8" or nil,
            edgeFile = s.dtBorder and "Interface\\Buttons\\WHITE8X8" or nil,
            edgeSize = 1,
        })
        local bc = s.dtBackdropColor or {}
        panel:SetBackdropColor(bc.r or 0.1, bc.g or 0.1, bc.b or 0.1, (s.dtBackdropAlpha or 100) / 100)
        local er, eg, eb
        if s.dtBorderClassColor then
            er, eg, eb = DT.ClassColor(select(2, UnitClass("player")))
        else
            local ec = s.dtBorderColor or {}
            er, eg, eb = ec.r or 0, ec.g or 0, ec.b or 0
        end
        panel:SetBackdropBorderColor(er, eg, eb, 1)
    else
        panel:SetBackdrop(nil)
    end
end

local function LayoutSlots()
    local s = BH.settings
    local n = math.max(1, math.min(MAX_SLOTS, s.dtSlots or 2))
    for i, slot in ipairs(slots) do
        if i <= n then
            local key = s["dtSlot" .. i]
            slot.key = (key and registry[key]) and key or nil
            slot.index, slot.count = i, n   -- ShareWidth places it
            StyleText(slot.text)
            slot:Show()
            local def = slot.key and registry[slot.key]
            if def and def.onShow then pcall(def.onShow) end
        else
            slot.key = nil
            slot:Hide()
        end
    end
end

-- Equal shares: placed on every size change, since anchors cannot express
-- "a third of the parent".
ShareWidth = function()
    if not panel then return end
    local w = panel:GetWidth()
    if not w or w <= 0 then return end
    for _, slot in ipairs(slots) do
        if slot:IsShown() and slot.index then
            local each = w / slot.count
            slot:ClearAllPoints()
            slot:SetPoint("TOPLEFT", panel, "TOPLEFT", each * (slot.index - 1), 0)
            slot:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT", each * slot.index, 0)
        end
    end
end

function DT.Apply()
    local s = BH.settings
    if not s then return end
    if not s.dtEnabled then
        if panel then panel:Hide() end
        return
    end
    CreatePanel()
    Place()
    Style()
    LayoutSlots()
    panel:Show()
    ShareWidth()
    DT.Refresh()
end

--- Unticking Attach: keep the panel exactly where it is, now free-standing.
function DT.Detach()
    if not panel or not panel:IsShown() then return end
    BH.settings.dtWidth = math.floor(panel:GetWidth() + 0.5)
    SavePosition()
end

-- Edit Mode's arrow-key nudge (MOVABLE_FRAMES in Squizzumables.lua).
function BH:DataTextNudge(dx, dy)
    local s = self.settings
    if not s or s.dtAttachMinimap then return end
    local pos = s.dtPosition or { x = 0, y = -200 }
    s.dtPosition = { x = pos.x + dx, y = pos.y + dy }
    self:SaveSettings()
    DT.Apply()
end

-- ============================================================================
-- Copying ElvUI's look, once per profile
-- ============================================================================

local OUTLINE_FROM_ELV = {
    NONE = "NONE", OUTLINE = "OUTLINE", THICKOUTLINE = "THICKOUTLINE",
    MONOCHROMEOUTLINE = "OUTLINE", SHADOW = "SHADOW", SHADOWOUTLINE = "SHADOWOUTLINE",
}

local function CopyColor(c)
    if type(c) ~= "table" or not c.r then return nil end
    return { r = c.r, g = c.g, b = c.b }
end

local function SeedFromElvUI()
    local s = BH.settings
    if not s or s.dtSeededFromElvUI then return end
    if not (C_AddOns.IsAddOnLoaded("ElvUI")) then return end
    local elv = _G["ElvUI"]
    local E = type(elv) == "table" and elv[1]
    local db = E and E.db
    local g = E and E.global
    if not (db and db.datatexts) then return end
    s.dtSeededFromElvUI = true

    local d = db.datatexts
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    if d.font and lsm and lsm:IsValid("font", d.font) then s.dtFont = d.font end
    if tonumber(d.fontSize) then s.dtFontSize = tonumber(d.fontSize) end
    if d.fontOutline and OUTLINE_FROM_ELV[d.fontOutline] then s.dtFontOutline = OUTLINE_FROM_ELV[d.fontOutline] end
    s.dtNoCombatHover = d.noCombatHover and true or false
    s.dtNoCombatClick = d.noCombatClick and true or false
    s.dtValueColor = CopyColor(db.general and db.general.valuecolor) or s.dtValueColor
    s.dtBackdropColor = CopyColor(db.general and db.general.backdropcolor) or s.dtBackdropColor

    local mp = d.panels and d.panels.MinimapPanel
    if type(mp) == "table" then
        local n = 0
        for i = 1, MAX_SLOTS do
            local key = mp[i]
            if key and key ~= "" then
                n = i
                s["dtSlot" .. i] = registry[key] and key or "None"
            end
        end
        if n > 0 then s.dtSlots = math.min(MAX_SLOTS, tonumber(mp.numPoints) or n) end
        if mp.backdrop ~= nil then s.dtBackdrop = mp.backdrop and true or false end
        if mp.border ~= nil then s.dtBorder = mp.border and true or false end
    end

    local per = g and g.datatexts and g.datatexts.settings
    if per and per.Guild and tonumber(per.Guild.maxLimit) then s.dtGuildMaxLines = tonumber(per.Guild.maxLimit) end
    if per and per.Friends then
        s.dtFriendsHideAFK = per.Friends.hideAFK and true or false
        s.dtFriendsHideDND = per.Friends.hideDND and true or false
    end
    BH:SaveSettings()
end

-- After a profile switch or reset too, so a profile that has never had
-- ElvUI's look copied in gets it the first time it is used.
function BH:ApplyDataTexts()
    SeedFromElvUI()
    DT.Apply()
end

-- ============================================================================
-- Events: one frame for every registered text's events
-- ============================================================================

local ev = CreateFrame("Frame")
local listeners = {}   -- event -> { key, ... }

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        for key, def in pairs(registry) do
            for _, e in ipairs(def.events or {}) do
                if not listeners[e] then
                    listeners[e] = {}
                    pcall(ev.RegisterEvent, ev, e)
                end
                table.insert(listeners[e], key)
            end
        end
        BH:ApplyDataTexts()
        return
    end
    for _, key in ipairs(listeners[event] or {}) do
        local def = registry[key]
        if def.onEvent then pcall(def.onEvent, event, ...) end
        DT.Refresh(key)
    end
end)
ev:RegisterEvent("PLAYER_LOGIN")
