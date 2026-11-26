-- Auras/BuffFrame.lua
-- Buffs and debuffs, ElvUI-style, by restyling Blizzard's own buff and debuff
-- frames rather than replacing them.
--
-- Why restyle: on 12.1 the secure aura header is gone, and Blizzard's frames
-- already do everything that is hard now: secret auras in encounters, right-
-- click to cancel a buff, weapon enchants, private auras, and a full Edit Mode
-- layout (size, direction, icons per row, padding, limit). What ElvUI changed
-- was the look, so that is what this changes: square icons with a thin edge
-- (coloured by debuff type on debuffs), and the duration and stack fonts and
-- positions.
--
-- Blizzard re-anchors the icon and duration text on every layout pass
-- (AuraContainerMixin:UpdateGridLayout), so ours goes back on straight after
-- each one. Nothing here writes a field on Blizzard's buttons (a weak table
-- remembers which are done), and private aura anchors are left alone.
--
-- Waits while ElvUI's own Buffs and Debuffs module is on (it hides Blizzard's).

local addonName, ns = ...
local BH = ns.BH

local AU = {}
ns.BuffFrame = AU

local function Elv()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

function AU.ElvUIOn()
    local E = Elv()
    local p = E and E.private and E.private.auras
    return p and p.enable and true or false
end

local function Active()
    return BH.settings and BH.settings.auEnabled and not AU.ElvUIOn()
end

local function Apply() if AU.Apply then AU.Apply() end end

-- ============================================================================
-- Settings
-- ============================================================================

local OUTLINES = {
    { text = "None", value = "NONE" }, { text = "Shadow", value = "SHADOW" },
    { text = "Outline", value = "OUTLINE" }, { text = "Thick outline", value = "THICKOUTLINE" },
}
local DURATION_POS = {
    { text = "Blizzard's (beside the icon)", value = "BLIZZARD" },
    { text = "Inside, at the bottom", value = "BOTTOM" },
    { text = "Inside, in the middle", value = "CENTER" },
    { text = "Inside, at the top", value = "TOP" },
}
local COUNT_POS = {
    { text = "Bottom right", value = "BOTTOMRIGHT" }, { text = "Top right", value = "TOPRIGHT" },
    { text = "Top left", value = "TOPLEFT" }, { text = "Bottom left", value = "BOTTOMLEFT" },
    { text = "Middle", value = "CENTER" },
}

local reloadAsked
AU.SETTINGS = ns.Settings.Describe({
    master = "auEnabled",
    apply = Apply,
    pages = {
        { key = "general", label = "General", rows = {
            { key = "auEnabled", type = "check", default = false, label = "Restyle Buffs and Debuffs",
              tip = "Blizzard's buff and debuff frames with square icons, a thin edge and your fonts. Their size, "
                .. "direction, icons per row and spacing stay in Edit Mode (Buff Frame, Debuff Frame), and "
                .. "right-click still cancels a buff.\n\nWaits while ElvUI's Buffs and Debuffs are on (ElvUI > "
                .. "Buffs and Debuffs > Enable, then /reload).",
              apply = function(v)
                  if v and AU.ElvUIOn() then
                      print("|cff33cc99Squizzumables:|r ElvUI's Buffs and Debuffs are still on. Turn them off in "
                          .. "ElvUI, /reload, and this takes over.")
                  elseif not v and AU.styledAny and not reloadAsked then
                      reloadAsked = true
                      print("|cff33cc99Squizzumables:|r Blizzard's buff look comes back after a /reload.")
                  end
              end },
            { key = "auSquare", type = "check", default = true, label = "Square Icons with a Thin Edge",
              tip = "Icons cropped square with a 1px edge: black on buffs, the debuff type's colour on debuffs." },
            { key = "auHideCollapse", type = "check", default = true, label = "Hide the Collapse Arrow",
              tip = "The small arrow beside your buffs that folds them away." },
            { type = "header", label = "DURATION" },
            { key = "auDurPos", type = "dropdown", default = "BOTTOM", items = DURATION_POS, label = "Position" },
            { key = "auDurFont", type = "dropdown", default = "__default",
              items = function() return BH:BuildFontDropdownItems() end, label = "Font" },
            { key = "auDurSize", type = "slider", default = 12, min = 6, max = 24, step = 1, label = "Size" },
            { key = "auDurOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES, label = "Outline" },
            { key = "auDurY", type = "slider", default = 0, min = -20, max = 20, step = 1, label = "Nudge Up/Down",
              when = function(s) return s.auDurPos ~= "BLIZZARD" end },
            { type = "header", label = "STACKS" },
            { key = "auCountPos", type = "dropdown", default = "BOTTOMRIGHT", items = COUNT_POS, label = "Position" },
            { key = "auCountFont", type = "dropdown", default = "__default",
              items = function() return BH:BuildFontDropdownItems() end, label = "Font" },
            { key = "auCountSize", type = "slider", default = 12, min = 6, max = 24, step = 1, label = "Size" },
            { key = "auCountOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES, label = "Outline" },
        } },
    },
})

function BH:BuildBuffFrameTab(parent)
    ns.Settings.Build(AU.SETTINGS, parent)
end

-- ============================================================================
-- Styling
-- ============================================================================

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

local edges = setmetatable({}, { __mode = "k" })   -- button -> our black backdrop texture

local function StyleButton(b, s)
    if b.isAuraAnchor or not b.Icon then return end   -- private aura anchors: Blizzard's secure code
    AU.styledAny = true
    local icon = b.Icon

    if s.auSquare ~= false then
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local bg = edges[b]
        if not bg then
            bg = b:CreateTexture(nil, "BACKGROUND", nil, -8)
            bg:SetColorTexture(0, 0, 0, 1)
            edges[b] = bg
        end
        bg:ClearAllPoints()
        bg:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
        bg:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        bg:Show()
        -- Blizzard's debuff-type border (and the weapon enchant one) shrunk
        -- to sit just behind the icon, so only a 1px coloured edge shows.
        for _, border in ipairs({ b.DebuffBorder, b.TempEnchantBorder }) do
            if border then
                border:ClearAllPoints()
                border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
                border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
                border:SetDrawLayer("BACKGROUND", -7)
            end
        end
    end

    SetFont(b.Duration, s.auDurFont, s.auDurSize or 12, s.auDurOutline or "OUTLINE")
    local pos = s.auDurPos or "BOTTOM"
    if pos ~= "BLIZZARD" and b.Duration then
        local y = s.auDurY or 0
        b.Duration:ClearAllPoints()
        if pos == "TOP" then
            b.Duration:SetPoint("TOP", icon, "TOP", 0, -1 + y)
        elseif pos == "CENTER" then
            b.Duration:SetPoint("CENTER", icon, "CENTER", 0, y)
        else
            b.Duration:SetPoint("BOTTOM", icon, "BOTTOM", 0, 1 + y)
        end
        b.Duration:SetDrawLayer("OVERLAY", 7)
    end

    SetFont(b.Count, s.auCountFont, s.auCountSize or 12, s.auCountOutline or "OUTLINE")
    if b.Count then
        local cp = s.auCountPos or "BOTTOMRIGHT"
        local x = cp:find("LEFT") and 1 or (cp:find("RIGHT") and -1 or 0)
        local y = cp:find("TOP") and -1 or (cp:find("BOTTOM") and 1 or 0)
        b.Count:ClearAllPoints()
        b.Count:SetPoint(cp, icon, cp, x, y)
        b.Count:SetDrawLayer("OVERLAY", 7)
    end
end

local function StyleFrame(frame)
    if not (frame and frame.auraFrames) then return end
    local s = BH.settings
    for _, b in ipairs(frame.auraFrames) do StyleButton(b, s) end
    local collapse = frame.CollapseAndExpandButton
    if collapse then
        local hide = s.auHideCollapse ~= false
        collapse:SetAlpha(hide and 0 or 1)
        collapse:EnableMouse(not hide)
    end
end

local FRAMES = { "BuffFrame", "DebuffFrame" }
local hooked = {}

function AU.Apply()
    if not Active() then return end
    for _, name in ipairs(FRAMES) do
        local frame = _G[name]
        local container = frame and frame.AuraContainer
        if container and not hooked[name] and container.UpdateGridLayout then
            hooked[name] = true
            hooksecurefunc(container, "UpdateGridLayout", function(self)
                if Active() then StyleFrame(self:GetParent()) end
            end)
        end
        StyleFrame(frame)
    end
end

-- ============================================================================
-- ElvUI's look, copied once per profile
-- ============================================================================

local function MapOutline(o)
    if o == "OUTLINE" or o == "THICKOUTLINE" or o == "NONE" or o == "SHADOW" then return o end
    if o == "SHADOWOUTLINE" or o == "SHADOWTHICKOUTLINE" or o == "MONOCHROMEOUTLINE" then return "OUTLINE" end
    return nil
end

local function Seed()
    local s = BH.settings
    if not s or s.auSeededFromElvUI then return end
    local E = Elv()
    local db = E and E.db and E.db.auras and E.db.auras.buffs
    if type(db) ~= "table" then return end
    s.auSeededFromElvUI = true
    if E.private and E.private.auras and E.private.auras.enable then s.auEnabled = true end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local function Font(name) return name and lsm and lsm:IsValid("font", name) and name or nil end
    s.auDurFont = Font(db.timeFont) or s.auDurFont
    s.auCountFont = Font(db.countFont) or s.auCountFont
    if tonumber(db.timeFontSize) then s.auDurSize = tonumber(db.timeFontSize) end
    if tonumber(db.countFontSize) then s.auCountSize = tonumber(db.countFontSize) end
    s.auDurOutline = MapOutline(db.timeFontOutline) or s.auDurOutline
    s.auCountOutline = MapOutline(db.countFontOutline) or s.auCountOutline
    BH:SaveSettings()
end

function BH:ApplyBuffFrame()
    Seed()
    AU.Apply()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function() BH:ApplyBuffFrame() end)
