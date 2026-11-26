-- Tooltip/Tooltip.lua
-- The game's tooltip, ElvUI-style (stage 1): a flat dark look with a thin
-- edge, your fonts, where it sits (an Edit Mode spot, above the right chat
-- panel, or at the cursor), hiding in combat, a health bar with text, and the
-- unit lines: names in class or reaction colours, titles, guild ranks, level
-- in its difficulty colour, role, and who the unit is targeting.
--
-- Only Blizzard's tooltip is changed; ElvUI's code was read for behaviour.
--
-- 12.x hides a lot from add-ons, and a tooltip is where it shows: a unit's
-- identity is secret in many instances, and so can each line's text be. So
-- every read is checked with canaccessvalue first, a player whose identity
-- is secret (C_Secrets.ShouldUnitIdentityBeSecret) keeps Blizzard's lines
-- untouched, and values only ever handed to a setter (SetText, the health
-- text) go straight through without being compared. Our own look is plain
-- textures pinned to the tooltip's edges, never a Backdrop: that does sums on
-- the tooltip's size, which can be secret too.
--
-- Waits while ElvUI's tooltip is on.

local addonName, ns = ...
local BH = ns.BH

local TT = {}
ns.Tooltip = TT

local function Elv()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

function TT.ElvUIOn()
    local E = Elv()
    local p = E and E.private and E.private.tooltip
    return p and p.enable and true or false
end

local function Settings() return BH.settings or {} end
local function Active() return BH.settings and BH.settings.ttEnabled and not TT.ElvUIOn() end
local function Apply() if TT.Apply then TT.Apply() end end

local function Readable(...)
    for i = 1, select("#", ...) do
        if not canaccessvalue(select(i, ...)) then return false end
    end
    return true
end

-- ============================================================================
-- Settings
-- ============================================================================

local OUTLINES = {
    { text = "None", value = "NONE" }, { text = "Shadow", value = "SHADOW" },
    { text = "Outline", value = "OUTLINE" }, { text = "Thick outline", value = "THICKOUTLINE" },
}
local MODIFIERS = {
    { text = "Always show", value = "SHOW" }, { text = "Hide", value = "HIDE" },
    { text = "Show with Shift", value = "SHIFT" }, { text = "Show with Ctrl", value = "CTRL" },
    { text = "Show with Alt", value = "ALT" },
}
local ANCHORS = {
    { text = "Above the right chat panel", value = "CHAT" },
    { text = "Where you place it (Edit Mode)", value = "MOVER" },
    { text = "At the cursor", value = "CURSOR" },
}
local CURSOR_TYPES = {
    { text = "On the cursor", value = "ANCHOR_CURSOR" }, { text = "Left of the cursor", value = "ANCHOR_CURSOR_LEFT" },
    { text = "Right of the cursor", value = "ANCHOR_CURSOR_RIGHT" },
}
local BAR_POS = {
    { text = "Below the tooltip", value = "BOTTOM" }, { text = "Above the tooltip", value = "TOP" },
    { text = "Hidden", value = "HIDE" },
}
local function Fonts() return BH:BuildFontDropdownItems() end

local reloadAsked
TT.SETTINGS = ns.Settings.Describe({
    master = "ttEnabled",
    apply = Apply,
    pages = {
        { key = "general", label = "General", rows = {
            { key = "ttEnabled", type = "check", default = false, label = "Restyle the Tooltip",
              tip = "The game's tooltip with a flat look, your fonts, a health bar with text and more on players "
                .. "and creatures.\n\nWaits while ElvUI's tooltip is on (ElvUI > Tooltip > Enable, then /reload).",
              apply = function(v)
                  if v and TT.ElvUIOn() then
                      print("|cff33cc99Squizzumables:|r ElvUI's tooltip is still on. Turn it off in ElvUI, /reload, "
                          .. "and this takes over.")
                  elseif not v and TT.styled and not reloadAsked then
                      reloadAsked = true
                      print("|cff33cc99Squizzumables:|r the game's tooltip look comes back after a /reload.")
                  end
              end },
            { key = "ttCombat", type = "dropdown", default = "SHOW", items = MODIFIERS, label = "In Combat",
              tip = "Tooltips for units and things in the world while you are in combat." },
            { type = "header", label = "PLACEMENT" },
            { key = "ttAnchor", type = "dropdown", default = "CHAT", items = ANCHORS, label = "Where It Shows",
              tip = "Above the right chat panel falls back to the Edit Mode spot while that panel is off or hidden. "
                .. "Tooltips that belong to a button or frame still show beside it." },
            { key = "ttOffsetX", type = "slider", default = 0, min = -100, max = 100, step = 1, label = "Offset X",
              when = function(s) return s.ttAnchor ~= "CURSOR" end },
            { key = "ttOffsetY", type = "slider", default = 18, min = -100, max = 100, step = 1, label = "Offset Y",
              when = function(s) return s.ttAnchor ~= "CURSOR" end },
            { key = "ttCursorType", type = "dropdown", default = "ANCHOR_CURSOR", items = CURSOR_TYPES,
              label = "Cursor Position", when = function(s) return s.ttAnchor == "CURSOR" end },
            { key = "ttCursorX", type = "slider", default = 0, min = -100, max = 100, step = 1, label = "Cursor Offset X",
              when = function(s) return s.ttAnchor == "CURSOR" end },
            { key = "ttCursorY", type = "slider", default = 0, min = -100, max = 100, step = 1, label = "Cursor Offset Y",
              when = function(s) return s.ttAnchor == "CURSOR" end },
        } },
        { key = "look", label = "Look", rows = {
            { key = "ttAlpha", type = "slider", default = 0.8, min = 0, max = 1, step = 0.05, label = "Background Opacity" },
            { type = "header", label = "TEXT" },
            { key = "ttFont", type = "dropdown", default = "__default", items = Fonts, label = "Font" },
            { key = "ttOutline", type = "dropdown", default = "SHADOW", items = OUTLINES, label = "Outline" },
            { key = "ttTextSize", type = "slider", default = 12, min = 6, max = 32, step = 1, label = "Text Size" },
            { key = "ttSmallSize", type = "slider", default = 12, min = 6, max = 32, step = 1, label = "Comparison Text Size",
              tip = "The tooltips comparing an item with what you wear." },
            { type = "header", label = "TITLE LINE" },
            { key = "ttHeaderFont", type = "dropdown", default = "__default", items = Fonts, label = "Font" },
            { key = "ttHeaderOutline", type = "dropdown", default = "SHADOW", items = OUTLINES, label = "Outline" },
            { key = "ttHeaderSize", type = "slider", default = 13, min = 6, max = 32, step = 1, label = "Size" },
            { type = "header", label = "HEALTH BAR" },
            { key = "ttBarPos", type = "dropdown", default = "BOTTOM", items = BAR_POS, label = "Position" },
            { key = "ttBarHeight", type = "slider", default = 12, min = 2, max = 30, step = 1, label = "Height" },
            { key = "ttBarText", type = "check", default = true, label = "Health Text" },
            { key = "ttBarShort", type = "check", default = false, label = "Current / Max Instead of Percent",
              when = function(s) return s.ttBarText ~= false end },
            { key = "ttBarFont", type = "dropdown", default = "__default", items = Fonts, label = "Font",
              when = function(s) return s.ttBarText ~= false end },
            { key = "ttBarFontSize", type = "slider", default = 12, min = 6, max = 24, step = 1, label = "Font Size",
              when = function(s) return s.ttBarText ~= false end },
            { key = "ttBarOutline", type = "dropdown", default = "SHADOW", items = OUTLINES, label = "Outline",
              when = function(s) return s.ttBarText ~= false end },
        } },
        { key = "units", label = "Players and Creatures", rows = {
            { key = "ttTitles", type = "check", default = true, label = "Player Titles" },
            { key = "ttGuildRanks", type = "check", default = true, label = "Guild Ranks" },
            { key = "ttRealm", type = "check", default = false, label = "Always Show the Realm",
              tip = "Off: hold Shift to see it." },
            { key = "ttRole", type = "check", default = true, label = "Group Role" },
            { key = "ttTarget", type = "check", default = true, label = "Their Target" },
            { key = "ttHidePvP", type = "check", default = true, label = "Hide the PvP Line" },
            { key = "ttHideFaction", type = "check", default = true, label = "Hide the Faction Line" },
        } },
    },
})

function BH:BuildTooltipTab(parent)
    ns.Settings.Build(TT.SETTINGS, parent)
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

local function SetFont(obj, font, size, outline)
    if not obj then return end
    local flags = (outline == "OUTLINE" or outline == "THICKOUTLINE") and outline or ""
    obj:SetFont(ResolveFont(font), size, flags)
    local shadow = outline == "SHADOW"
    obj:SetShadowOffset(shadow and 1 or 0, shadow and -1 or 0)
    obj:SetShadowColor(0, 0, 0, shadow and 1 or 0)
end

local function ModDown(mode)
    return mode == "SHOW" or (mode == "SHIFT" and IsShiftKeyDown()) or (mode == "CTRL" and IsControlKeyDown())
        or (mode == "ALT" and IsAltKeyDown())
end

local function Hex(r, g, b)
    return string.format("ff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5))
end

local function Wrap(text, color)
    return "|c" .. Hex(color.r, color.g, color.b) .. text .. "|r"
end

local GREY = { r = 0.6, g = 0.6, b = 0.6 }
local TAPPED = { r = 0.6, g = 0.6, b = 0.6 }

local function ClassColor(class)
    if not (class and canaccessvalue(class)) then return nil end
    return C_ClassColor and C_ClassColor.GetClassColor(class) or RAID_CLASS_COLORS[class]
end

local function ReactionColor(unit)
    local reaction = UnitReaction(unit, "player")
    if not (reaction and canaccessvalue(reaction)) then return nil end
    return FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
end

-- ============================================================================
-- The look
-- ============================================================================

local skins = setmetatable({}, { __mode = "k" })   -- tooltip -> our textures

local function Skin(tt)
    if not tt or tt:IsForbidden() or tt.IsEmbedded then return end
    local sk = skins[tt]
    if not sk then
        sk = {}
        sk.bg = tt:CreateTexture(nil, "BACKGROUND", nil, -8)
        sk.bg:SetAllPoints()
        local function Edge(a1, a2, horizontal)
            local e = tt:CreateTexture(nil, "BORDER", nil, 7)
            e:SetColorTexture(0, 0, 0, 1)
            e:SetPoint(a1)
            e:SetPoint(a2)
            if horizontal then e:SetHeight(1) else e:SetWidth(1) end
            return e
        end
        sk.edges = { Edge("TOPLEFT", "TOPRIGHT", true), Edge("BOTTOMLEFT", "BOTTOMRIGHT", true),
                     Edge("TOPLEFT", "BOTTOMLEFT"), Edge("TOPRIGHT", "BOTTOMRIGHT") }
        skins[tt] = sk
    end
    sk.bg:SetColorTexture(0.06, 0.06, 0.06, Settings().ttAlpha or 0.8)
    sk.bg:Show()
    for _, e in ipairs(sk.edges) do e:Show() end
    if tt.NineSlice then tt.NineSlice:SetAlpha(0) end
    TT.styled = true
end

local function Unskin(tt)
    local sk = skins[tt]
    if not sk then return end
    sk.bg:Hide()
    for _, e in ipairs(sk.edges) do e:Hide() end
    if tt.NineSlice then tt.NineSlice:SetAlpha(1) end
end

local TOOLTIPS = { "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2",
                   "ItemRefShoppingTooltip1", "ItemRefShoppingTooltip2", "EmbeddedItemTooltip" }

local function ApplyFonts()
    local s = Settings()
    SetFont(GameTooltipText, s.ttFont, s.ttTextSize or 12, s.ttOutline or "SHADOW")
    SetFont(GameTooltipHeaderText, s.ttHeaderFont, s.ttHeaderSize or 13, s.ttHeaderOutline or "SHADOW")
    SetFont(GameTooltipTextSmall, s.ttFont, s.ttSmallSize or 12, s.ttOutline or "SHADOW")
end

-- ============================================================================
-- Health bar
-- ============================================================================

local barText, barBG
local function StyleBar()
    local bar = GameTooltipStatusBar
    if not bar then return end
    local s = Settings()
    if not barText then
        barBG = bar:CreateTexture(nil, "BACKGROUND", nil, -8)
        barBG:SetPoint("TOPLEFT", -1, 1)
        barBG:SetPoint("BOTTOMRIGHT", 1, -1)
        barBG:SetColorTexture(0, 0, 0, 1)
        barText = bar:CreateFontString(nil, "OVERLAY")
        barText:SetPoint("CENTER")
    end
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    bar:SetHeight(s.ttBarHeight or 12)
    local pos = s.ttBarPos or "BOTTOM"
    bar:SetAlpha(pos == "HIDE" and 0 or 1)
    bar:ClearAllPoints()
    if pos == "TOP" then
        bar:SetPoint("BOTTOMLEFT", GameTooltip, "TOPLEFT", 1, 3)
        bar:SetPoint("BOTTOMRIGHT", GameTooltip, "TOPRIGHT", -1, 3)
    else
        bar:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 1, -3)
        bar:SetPoint("TOPRIGHT", GameTooltip, "BOTTOMRIGHT", -1, -3)
    end
    SetFont(barText, s.ttBarFont, s.ttBarFontSize or 12, s.ttBarOutline or "SHADOW")
    barText:SetShown(s.ttBarText ~= false)
end

-- The tooltip's unit, as a token we may use. nil when it is secret.
local function TooltipUnit(tt)
    if not tt or tt:IsForbidden() then return nil end
    local data = tt.GetPrimaryTooltipData and tt:GetPrimaryTooltipData()
    local guid = data and data.guid
    if guid and canaccessvalue(guid) then
        local token = UnitTokenFromGUID(guid)
        if token and canaccessvalue(token) and UnitExists(token) then return token end
    end
    if UnitExists("mouseover") then return "mouseover" end
    return nil
end

local lastBarUpdate = 0
local function UpdateBarText()
    if not (barText and Active()) or Settings().ttBarText == false then return end
    local now = GetTime()
    if now - lastBarUpdate < 0.1 then return end
    lastBarUpdate = now
    local unit = TooltipUnit(GameTooltip)
    if not unit then barText:SetText("") return end
    local dead = UnitIsDeadOrGhost(unit)
    if canaccessvalue(dead) and dead then barText:SetText(DEAD) return end
    if Settings().ttBarShort then
        -- Possibly secret: straight into the string and the setter.
        barText:SetText(AbbreviateNumbers(UnitHealth(unit)) .. " / " .. AbbreviateNumbers(UnitHealthMax(unit)))
    else
        local pct = UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)
        if pct then barText:SetFormattedText("%d%%", pct --[[@as number]]) else barText:SetText("") end
    end
end

-- ============================================================================
-- Placement
-- ============================================================================

local anchorFrame
local ANCHOR_DEFAULT = { point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT", x = -50, y = 230 }

local function SaveAnchor(f)
    local cx, cy = f:GetCenter()
    if not cx then return end
    local scale = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    BH.settings.ttPosition = { point = "CENTER", relPoint = "CENTER",
        x = math.floor(cx * scale - ux + 0.5), y = math.floor(cy * scale - uy + 0.5) }
    BH:SaveSettings()
end

local function AnchorFrame()
    if anchorFrame then return anchorFrame end
    local f = CreateFrame("Frame", "SquizzumablesTooltipAnchor", UIParent)
    f:SetSize(130, 20)
    f:SetFrameStrata("TOOLTIP")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if InCombatLockdown() or not BH.unlockMode then return end
        BH:GridStartMoving(self)
    end)
    f:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(self)
        SaveAnchor(self)
        Apply()
    end)
    anchorFrame = f
    BH.tooltipAnchor = f
    return f
end

function TT.Nudge(dx, dy)
    local s = BH.settings
    if not s then return end
    local pos = s.ttPosition or ANCHOR_DEFAULT
    s.ttPosition = { point = pos.point, relPoint = pos.relPoint, x = (pos.x or 0) + dx, y = (pos.y or 0) + dy }
    BH:SaveSettings()
    Apply()
end

local function ChatPanel()
    local panel = BH.chatPanelRight
    local chat = ns.Chat
    if not (panel and panel:IsShown() and chat and chat.Wanted and chat.Wanted()) then return nil end
    if Settings().chRightHidden then return nil end
    return panel
end

local function OnDefaultAnchor(tt, parent)
    if not Active() or not tt or tt:IsForbidden() then return end
    if not tt.GetAnchorType or tt:GetAnchorType() ~= "ANCHOR_NONE" then return end
    local s = Settings()
    if InCombatLockdown() and not ModDown(s.ttCombat or "SHOW") then
        tt:Hide()
        return
    end
    if s.ttAnchor == "CURSOR" then
        if parent and not parent:IsForbidden() then
            tt:SetOwner(parent, s.ttCursorType or "ANCHOR_CURSOR", s.ttCursorX or 0, s.ttCursorY or 0)
        end
        return
    end
    local target = (s.ttAnchor ~= "MOVER" and ChatPanel()) or AnchorFrame()
    local x, y = s.ttOffsetX or 0, s.ttOffsetY or 18
    tt:ClearAllPoints()
    if target == anchorFrame then
        -- Grow away from the nearest screen side, as ElvUI does.
        local cx = target:GetCenter()
        local left = cx and cx < UIParent:GetWidth() / 2
        local point = left and "BOTTOMLEFT" or "BOTTOMRIGHT"
        tt:SetPoint(point, target, left and "TOPLEFT" or "TOPRIGHT", x, y)
    else
        tt:SetPoint("BOTTOMRIGHT", target, "TOPRIGHT", x, y)
    end
end

-- ============================================================================
-- Unit lines
-- ============================================================================

local LEVEL_WORD = strlower(LEVEL or "Level")

local function Lines(tt)
    local data = tt:GetTooltipData()
    return data and data.lines
end

local function HideTrash(tt)
    local s = Settings()
    local lines = Lines(tt)
    if not (lines and lines[3]) then return end
    for i = 3, #lines do
        local text = lines[i] and lines[i].leftText
        if text and canaccessvalue(text) then
            if text == "" then break end
            if (s.ttHidePvP ~= false and text == PVP)
                    or (s.ttHideFaction ~= false and (text == FACTION_ALLIANCE or text == FACTION_HORDE)) then
                local fs = _G["GameTooltipTextLeft" .. i]
                if fs then fs:SetText("") fs:Hide() end
            end
        end
    end
end

-- The "Level 80 ..." line and the one after it.
local function LevelLine(tt, from)
    local lines = Lines(tt)
    if not lines then return end
    for i = from, #lines do
        local text = lines[i] and lines[i].leftText
        if text and canaccessvalue(text) then
            if text == "" then return end
            if strlower(text):find(LEVEL_WORD, 1, true) then
                return _G["GameTooltipTextLeft" .. i], _G["GameTooltipTextLeft" .. (i + 1)], lines[i + 1]
            end
        end
    end
end

local function DiffColor(level)
    if not (level and canaccessvalue(level)) then return GREY end
    local c = GetCreatureDifficultyColor and GetCreatureDifficultyColor(level)
    return c or GREY
end

local function PlayerLines(tt, unit)
    local s = Settings()
    local name, realm = UnitName(unit)
    local _, class = UnitClass(unit)
    if not Readable(name, realm, class) then return nil end
    local color = ClassColor(class) or GREY

    local display = name
    local pvpName = s.ttTitles ~= false and UnitPVPName(unit)
    if pvpName and canaccessvalue(pvpName) and pvpName ~= "" then display = pvpName end
    if realm and canaccessvalue(realm) and realm ~= "" then
        if IsShiftKeyDown() or s.ttRealm then
            display = display .. "-" .. realm
        else
            local rel = UnitRealmRelationship(unit)
            if canaccessvalue(rel) then
                if rel == LE_REALM_RELATION_COALESCED then display = display .. FOREIGN_SERVER_LABEL
                elseif rel == LE_REALM_RELATION_VIRTUAL then display = display .. INTERACTIVE_SERVER_LABEL end
            end
        end
    end
    local away = ""
    local afk, dnd = UnitIsAFK(unit), UnitIsDND(unit)
    if canaccessvalue(afk) and afk then away = " |cffffffff[|r|cffff3333" .. AFK .. "|r|cffffffff]|r"
    elseif canaccessvalue(dnd) and dnd then away = " |cffffffff[|r|cffff3333" .. DND .. "|r|cffffffff]|r" end
    GameTooltipTextLeft1:SetText(Wrap(display, color) .. away)

    local guild, rank = GetGuildInfo(unit)
    if not Readable(guild, rank) then guild, rank = nil, nil end
    local levelLine, specLine = LevelLine(tt, guild and 2 or 1)
    if guild then
        local text = "<|cff00ff10" .. guild .. "|r>"
        if s.ttGuildRanks ~= false and rank then text = text .. " [|cff00ff10" .. rank .. "|r]" end
        if levelLine == GameTooltipTextLeft2 then
            tt:AddLine(text, 1, 1, 1)
        else
            GameTooltipTextLeft2:SetText(text)
        end
    end
    if levelLine then
        local race = UnitRace(unit)
        if not Readable(race) then race = nil end
        local real, eff = UnitLevel(unit), UnitEffectiveLevel(unit)
        if Readable(real, eff) then
            local hex = Hex(DiffColor(eff).r, DiffColor(eff).g, DiffColor(eff).b)
            local shown = eff > 0 and tostring(eff) or "??"
            local text = "|c" .. hex .. shown .. "|r"
            if eff < real then text = text .. " |cffffffff(" .. real .. ")|r" end
            levelLine:SetText(text .. " " .. (race or ""))
        end
        local specText = specLine and specLine:GetText()
        if specText and canaccessvalue(specText) and specText ~= "" then
            specLine:SetText(Wrap(specText, color))
        end
    end
    return color
end

local CLASSIFICATION = {
    worldboss = { text = BOSS or "Boss", color = { r = 1, g = 0.2, b = 0.2 } },
    rareelite = { text = (ELITE and ITEM_QUALITY3_DESC) and (ITEM_QUALITY3_DESC .. " " .. ELITE) or "Rare Elite",
                  color = { r = 1, g = 0.6, b = 1 } },
    elite = { text = ELITE or "Elite", color = { r = 1, g = 0.82, b = 0 } },
    rare = { text = ITEM_QUALITY3_DESC or "Rare", color = { r = 0.8, g = 0.8, b = 1 } },
}

local function CreatureLines(tt, unit)
    local name = UnitName(unit)
    local color = ReactionColor(unit) or GREY
    local levelLine, classLine, classData = LevelLine(tt, 1)
    if levelLine then
        local level = UnitEffectiveLevel(unit)
        local kind = UnitClassification(unit)
        local ctype = UnitCreatureType(unit)
        if Readable(level, kind, ctype) then
            local c = DiffColor(level)
            local text = Wrap(level > 0 and tostring(level) or "??", c)
            local cls = CLASSIFICATION[kind]
            if cls then text = text .. " " .. Wrap(cls.text, cls.color) end
            if ctype and canaccessvalue(ctype) and ctype ~= "" then text = text .. " " .. ctype end
            local pvp = UnitIsPVP(unit)
            if canaccessvalue(pvp) and pvp then text = text .. " (" .. PVP_ENABLED .. ")" end
            levelLine:SetText(text)
            local classText = classData and classData.leftText
            if classLine and classText and canaccessvalue(classText) and classText == ctype then
                classLine:SetText("")
                classLine:Hide()
            end
        end
    end
    if name and canaccessvalue(name) then GameTooltipTextLeft1:SetText(Wrap(name, color)) end
    local tapped = UnitIsTapDenied(unit)
    if canaccessvalue(tapped) and tapped then return TAPPED end
    return color
end

local function TargetLine(tt, unit)
    local target = unit .. "target"
    if unit == "player" or not UnitExists(target) then return end
    local name = UnitName(target)
    if not name then return end
    local color
    local isPlayer = UnitIsPlayer(target)
    if canaccessvalue(isPlayer) and isPlayer then
        local _, class = UnitClass(target)
        color = ClassColor(class)
    else
        color = ReactionColor(target)
    end
    color = color or { r = 1, g = 1, b = 1 }
    -- The name may be secret: straight into the string and the setter.
    pcall(tt.AddDoubleLine, tt, TARGET .. ":", "|c" .. Hex(color.r, color.g, color.b) .. name .. "|r")
end

local ROLES = {
    TANK = { "Tank", 0.16, 0.31, 0.61 }, HEALER = { "Healer", 0, 1, 0.59 }, DAMAGER = { "DPS", 0.77, 0.12, 0.24 },
}
local function RoleLine(tt, unit)
    if not IsInGroup() then return end
    local inRaid, inParty = UnitInRaid(unit), UnitInParty(unit)
    if not Readable(inRaid, inParty) or not (inRaid or inParty) then return end
    local role = UnitGroupRolesAssigned(unit)
    local r = canaccessvalue(role) and ROLES[role]
    if r then tt:AddDoubleLine(ROLE .. ":", r[1], nil, nil, nil, r[2], r[3], r[4]) end
end

local function OnUnit(tt)
    if tt ~= GameTooltip or tt:IsForbidden() or not Active() then return end
    local unit = TooltipUnit(tt)
    if not unit then return end
    local s = Settings()
    HideTrash(tt)
    local isPlayer = UnitIsPlayer(unit)
    local color
    if canaccessvalue(isPlayer) and isPlayer then
        local secret = C_Secrets and C_Secrets.ShouldUnitIdentityBeSecret
            and C_Secrets.ShouldUnitIdentityBeSecret(unit)
        if not (canaccessvalue(secret) and secret) then color = PlayerLines(tt, unit) end
    elseif canaccessvalue(isPlayer) then
        color = CreatureLines(tt, unit)
    end
    if s.ttTarget ~= false and not IsShiftKeyDown() and not IsControlKeyDown() then TargetLine(tt, unit) end
    if s.ttRole ~= false then RoleLine(tt, unit) end
    color = color or GREY
    GameTooltipStatusBar:SetStatusBarColor(color.r, color.g, color.b)
end

-- ============================================================================
-- Apply
-- ============================================================================

local hooked
local function Hook()
    if hooked then return end
    hooked = true
    hooksecurefunc("SharedTooltip_SetBackdropStyle", function(tt, _, embedded)
        if Active() and not embedded then Skin(tt) end
    end)
    hooksecurefunc("GameTooltip_SetDefaultAnchor", OnDefaultAnchor)
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnit)
    end
    if GameTooltipStatusBar and GameTooltipStatusBar.UpdateUnitHealth then
        hooksecurefunc(GameTooltipStatusBar, "UpdateUnitHealth", UpdateBarText)
    end
end

function TT.Apply()
    local f = AnchorFrame()
    if not InCombatLockdown() then
        local pos = Settings().ttPosition or ANCHOR_DEFAULT
        f:ClearAllPoints()
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
        f:EnableMouse(BH.unlockMode and true or false)
    end
    if not Active() then
        for _, name in ipairs(TOOLTIPS) do if _G[name] then Unskin(_G[name]) end end
        return
    end
    Hook()
    f:Show()
    ApplyFonts()
    StyleBar()
    for _, name in ipairs(TOOLTIPS) do if _G[name] then Skin(_G[name]) end end
end

-- ============================================================================
-- ElvUI's tooltip, copied once per profile
-- ============================================================================

local function MapOutline(o)
    if o == "OUTLINE" or o == "THICKOUTLINE" or o == "NONE" or o == "SHADOW" then return o end
    if type(o) == "string" and o:find("OUTLINE") then return "OUTLINE" end
    return nil
end

local function Seed()
    local s = BH.settings
    if not s or s.ttSeededFromElvUI then return end
    local E = Elv()
    local db = E and E.db and E.db.tooltip
    if type(db) ~= "table" then return end
    s.ttSeededFromElvUI = true
    if E.private and E.private.tooltip and E.private.tooltip.enable then s.ttEnabled = true end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local function Font(name) return type(name) == "string" and lsm and lsm:IsValid("font", name) and name or nil end
    local function Num(v, key) if tonumber(v) then s[key] = tonumber(v) end end
    local function Bool(v, key) if v ~= nil then s[key] = v and true or false end end
    s.ttFont = Font(db.font) or s.ttFont
    s.ttOutline = MapOutline(db.fontOutline) or s.ttOutline
    Num(db.textFontSize or db.fontSize, "ttTextSize")
    Num(db.smallTextFontSize, "ttSmallSize")
    s.ttHeaderFont = Font(db.headerFont) or Font(db.font) or s.ttHeaderFont
    s.ttHeaderOutline = MapOutline(db.headerFontOutline) or s.ttHeaderOutline
    Num(db.headerFontSize, "ttHeaderSize")
    Num(db.colorAlpha, "ttAlpha")
    Num(db.xOffset, "ttOffsetX")
    Num(db.yOffset, "ttOffsetY")
    if db.cursorAnchor then s.ttAnchor = "CURSOR" end
    if db.cursorAnchorType == "ANCHOR_CURSOR" or db.cursorAnchorType == "ANCHOR_CURSOR_LEFT"
            or db.cursorAnchorType == "ANCHOR_CURSOR_RIGHT" then
        s.ttCursorType = db.cursorAnchorType
    end
    Num(db.cursorAnchorX, "ttCursorX")
    Num(db.cursorAnchorY, "ttCursorY")
    Bool(db.playerTitles, "ttTitles")
    Bool(db.guildRanks, "ttGuildRanks")
    Bool(db.alwaysShowRealm, "ttRealm")
    Bool(db.role, "ttRole")
    Bool(db.targetInfo, "ttTarget")
    if db.allowTagPVP ~= nil then s.ttHidePvP = not db.allowTagPVP end
    if db.allowTagFaction ~= nil then s.ttHideFaction = not db.allowTagFaction end
    local vis = db.visibility
    local combat = type(vis) == "table" and vis.combatOverride
    if combat == "SHOW" or combat == "HIDE" or combat == "SHIFT" or combat == "CTRL" or combat == "ALT" then
        s.ttCombat = combat
    end
    local hb = db.healthBar
    if type(hb) == "table" then
        Bool(hb.text, "ttBarText")
        Bool(hb.short, "ttBarShort")
        Num(hb.height, "ttBarHeight")
        s.ttBarFont = Font(hb.font) or s.ttBarFont
        Num(hb.fontSize, "ttBarFontSize")
        s.ttBarOutline = MapOutline(hb.fontOutline) or s.ttBarOutline
        if hb.statusPosition == "TOP" or hb.statusPosition == "BOTTOM" then s.ttBarPos = hb.statusPosition
        elseif hb.statusPosition == "DISABLED" then s.ttBarPos = "HIDE" end
    end
    local mover = E.db.movers and E.db.movers.TooltipMover
    if type(mover) == "string" then
        local pt, rel, relPt, x, y = strsplit(",", mover)
        if (rel == "ElvUIParent" or rel == "UIParent") and tonumber(x) and tonumber(y) then
            s.ttPosition = { point = pt, relPoint = relPt, x = tonumber(x), y = tonumber(y) }
            if not db.cursorAnchor then s.ttAnchor = "MOVER" end
        end
    end
    BH:SaveSettings()
end

function BH:ApplyTooltip()
    Seed()
    TT.Apply()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function() BH:ApplyTooltip() end)
