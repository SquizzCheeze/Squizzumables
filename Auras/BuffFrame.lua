-- Auras/BuffFrame.lua
-- Your buffs and debuffs in two frames of our own, laid out the way ElvUI's
-- are: icon size, growth direction, icons per row, rows, spacing, sorting,
-- timer and stack text, placed in Edit Mode. Optionally hides Blizzard's.
--
-- Built on Blizzard's AuraContainer (12.1.5), the only way left to show
-- auras that are secret in encounters: the client fills the buttons itself,
-- and nothing here ever reads an aura. ElvUI does the same, and was read for
-- behaviour only.
--
-- Rules this file keeps (the AuraContainer's, learned the hard way in
-- SquizzFrames and the Cooldown Manager here):
--   * Everything on a button is built and registered in initializeFrame,
--     the one time the button may be touched while its aura can be secret.
--   * The button must be sized there too; the group layout's element size
--     only feeds the flow maths.
--   * Groups are declared before SetUnit, or UNIT_AURA is never registered.
--   * A setting change that has to touch existing buttons (size, crop) only
--     runs out of combat, in a pcall, and waits for the end of combat if not.
--   * Pieces we need to switch on and off (the debuff-type edge, the timer)
--     sit on a plain host frame we own, because their Shown aspect is the
--     engine's once registered.
--
-- Waits while ElvUI's own Buffs and Debuffs are on.

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

local function Settings() return BH.settings or {} end

local function Active()
    return BH.settings and BH.settings.auEnabled and not AU.ElvUIOn()
end

local function Apply() if AU.Apply then AU.Apply() end end

-- ============================================================================
-- Settings
-- ============================================================================

local GROWTH = {
    { text = "Left, then down", value = "LEFT_DOWN" }, { text = "Left, then up", value = "LEFT_UP" },
    { text = "Right, then down", value = "RIGHT_DOWN" }, { text = "Right, then up", value = "RIGHT_UP" },
    { text = "Down, then left", value = "DOWN_LEFT" }, { text = "Down, then right", value = "DOWN_RIGHT" },
    { text = "Up, then left", value = "UP_LEFT" }, { text = "Up, then right", value = "UP_RIGHT" },
}
local SORTS = {
    { text = "Time left", value = "TIME" }, { text = "Order gained", value = "INDEX" },
    { text = "Name", value = "NAME" },
}
local DIRS = { { text = "Ascending", value = "+" }, { text = "Descending", value = "-" } }
local OUTLINES = {
    { text = "None", value = "NONE" }, { text = "Shadow", value = "SHADOW" },
    { text = "Outline", value = "OUTLINE" }, { text = "Thick outline", value = "THICKOUTLINE" },
}
local TEXT_POS = {
    { text = "Middle", value = "CENTER" }, { text = "Inside, top", value = "TOP" },
    { text = "Inside, bottom", value = "BOTTOM" }, { text = "Above the icon", value = "ABOVE" },
    { text = "Below the icon", value = "BELOW" },
}
local CORNERS = {
    { text = "Bottom right", value = "BOTTOMRIGHT" }, { text = "Top right", value = "TOPRIGHT" },
    { text = "Top left", value = "TOPLEFT" }, { text = "Bottom left", value = "BOTTOMLEFT" },
    { text = "Middle", value = "CENTER" },
}

-- Defaults are ElvUI's own, so a first look without ElvUI to copy from is
-- still the familiar one.
local KINDS = {
    { id = "B", key = "buffs", label = "Buffs", filter = "HELPFUL", frameName = "SquizzumablesBuffs",
      field = "auraBuffs", maxWraps = 3,
      pos = { point = "TOPRIGHT", relPoint = "TOPRIGHT", x = -215, y = -8 } },
    { id = "D", key = "debuffs", label = "Debuffs", filter = "HARMFUL", frameName = "SquizzumablesDebuffs",
      field = "auraDebuffs", maxWraps = 1,
      pos = { point = "TOPRIGHT", relPoint = "TOPRIGHT", x = -215, y = -160 } },
}
AU.KINDS = KINDS

local function KindRows(k)
    local p = "au" .. k.id
    local function Fonts() return BH:BuildFontDropdownItems() end
    local rows = {
        { type = "header", label = "ICONS" },
        { key = p .. "Size", type = "slider", default = 32, min = 12, max = 64, step = 1, label = "Icon Size" },
        { key = p .. "KeepRatio", type = "check", default = true, label = "Square Icons",
          tip = "Off: give the icons a height of their own." },
        { key = p .. "Height", type = "slider", default = 32, min = 8, max = 64, step = 1, label = "Icon Height",
          when = function(s) return s[p .. "KeepRatio"] == false end },
        { key = p .. "Growth", type = "dropdown", default = "LEFT_DOWN", items = GROWTH, label = "Growth Direction",
          tip = "Which way new icons go, then which way a new row goes." },
        { key = p .. "WrapAfter", type = "slider", default = 12, min = 1, max = 32, step = 1, label = "Icons per Row" },
        { key = p .. "MaxWraps", type = "slider", default = k.maxWraps, min = 1, max = 32, step = 1, label = "Rows" },
        { key = p .. "HSpacing", type = "slider", default = 6, min = 0, max = 50, step = 1, label = "Spacing Between Icons" },
        { key = p .. "VSpacing", type = "slider", default = 16, min = 0, max = 50, step = 1, label = "Spacing Between Rows" },
        { key = p .. "Sort", type = "dropdown", default = "TIME", items = SORTS, label = "Sort By" },
        { key = p .. "SortDir", type = "dropdown", default = "-", items = DIRS, label = "Sort Direction" },
        { key = p .. "Swipe", type = "check", default = true, label = "Cooldown Swipe",
          tip = "The dark sweep across the icon as the aura runs down." },
        { type = "header", label = "TIMER" },
        { key = p .. "DurShow", type = "check", default = true, label = "Show the Timer" },
        { key = p .. "DurPos", type = "dropdown", default = "CENTER", items = TEXT_POS, label = "Position" },
        { key = p .. "DurX", type = "slider", default = 0, min = -30, max = 30, step = 1, label = "Offset X" },
        { key = p .. "DurY", type = "slider", default = 0, min = -30, max = 30, step = 1, label = "Offset Y" },
        { key = p .. "DurFont", type = "dropdown", default = "__default", items = Fonts, label = "Font" },
        { key = p .. "DurSize", type = "slider", default = 16, min = 6, max = 32, step = 1, label = "Font Size" },
        { key = p .. "DurOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES, label = "Outline" },
        { type = "header", label = "STACKS" },
        { key = p .. "CountPos", type = "dropdown", default = "BOTTOMRIGHT", items = CORNERS, label = "Position" },
        { key = p .. "CountX", type = "slider", default = 0, min = -30, max = 30, step = 1, label = "Offset X" },
        { key = p .. "CountY", type = "slider", default = 0, min = -30, max = 30, step = 1, label = "Offset Y" },
        { key = p .. "CountFont", type = "dropdown", default = "__default", items = Fonts, label = "Font" },
        { key = p .. "CountSize", type = "slider", default = 10, min = 6, max = 32, step = 1, label = "Font Size" },
        { key = p .. "CountOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES, label = "Outline" },
    }
    if k.id == "B" then
        table.insert(rows, 2, { key = "auBEnchants", type = "check", default = true, label = "Weapon Enchants",
            tip = "Your weapon oils and poisons, before your buffs." })
    else
        table.insert(rows, 2, { key = "auDColorType", type = "check", default = true, label = "Colour by Debuff Type",
            tip = "The edge takes the debuff's type colour: magic blue, curse purple, poison green, disease brown." })
    end
    return rows
end

local reloadAsked
AU.SETTINGS = ns.Settings.Describe({
    master = "auEnabled",
    apply = Apply,
    pages = {
        { key = "general", label = "General", rows = {
            { key = "auEnabled", type = "check", default = false, label = "Enable Buffs and Debuffs",
              tip = "Your buffs and debuffs in two frames of their own, placed in Edit Mode, with the layout on the "
                .. "Buffs and Debuffs tabs. Right-click a buff to cancel it.\n\nWaits while ElvUI's Buffs and "
                .. "Debuffs are on (ElvUI > Buffs and Debuffs > Enable, then /reload).",
              apply = function(v)
                  if v and AU.ElvUIOn() then
                      print("|cff33cc99Squizzumables:|r ElvUI's Buffs and Debuffs are still on. Turn them off in "
                          .. "ElvUI, /reload, and these take over.")
                  elseif not v and AU.built and not reloadAsked then
                      reloadAsked = true
                      print("|cff33cc99Squizzumables:|r the buff and debuff frames go away fully after a /reload.")
                  end
              end },
            { key = "auHideBlizzard", type = "check", default = true, label = "Hide Blizzard's Buffs and Debuffs",
              tip = "The game's own buff and debuff frames by the minimap. Untick to keep both." },
        } },
        { key = "buffs", label = "Buffs", rows = KindRows(KINDS[1]) },
        { key = "debuffs", label = "Debuffs", rows = KindRows(KINDS[2]) },
    },
})

function BH:BuildBuffFrameTab(parent)
    ns.Settings.Build(AU.SETTINGS, parent)
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function Get(k, name)
    local key = "au" .. k.id .. name
    local v = Settings()[key]
    if v ~= nil then return v end
    return BH.defaultSettings and BH.defaultSettings[key]
end

local function ResolveFont(name)
    if name and name ~= "__default" then
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        local path = lsm and lsm:Fetch("font", name, true)
        if path then return path end
    end
    return STANDARD_TEXT_FONT
end

local function SetFont(fs, font, size, outline)
    local flags = (outline == "OUTLINE" or outline == "THICKOUTLINE") and outline or ""
    fs:SetFont(ResolveFont(font), size, flags)
    local shadow = outline == "SHADOW"
    fs:SetShadowOffset(shadow and 1 or 0, shadow and -1 or 0)
    fs:SetShadowColor(0, 0, 0, shadow and 1 or 0)
end

local function Dims(k)
    local w = Get(k, "Size")
    local h = Get(k, "KeepRatio") == false and Get(k, "Height") or w
    return w, h
end

-- The icon cropped to fill a non-square button without stretching.
local function Crop(w, h)
    local l, r, t, b = 0.08, 0.92, 0.08, 0.92
    if w > h then
        local cut = (1 - h / w) * (b - t) / 2
        t, b = t + cut, b - cut
    elseif h > w then
        local cut = (1 - w / h) * (r - l) / 2
        l, r = l + cut, r - cut
    end
    return l, r, t, b
end

local FLOW = {}
do
    local A = AnchorUtil
    local ax, d = A and A.FlowLayoutAxis, A and A.FlowDirection
    if ax and d then
        local H, V = ax.Horizontal, ax.Vertical
        FLOW.LEFT_DOWN  = { H, d.Left,  d.Down, "TOPRIGHT" }
        FLOW.LEFT_UP    = { H, d.Left,  d.Up,   "BOTTOMRIGHT" }
        FLOW.RIGHT_DOWN = { H, d.Right, d.Down, "TOPLEFT" }
        FLOW.RIGHT_UP   = { H, d.Right, d.Up,   "BOTTOMLEFT" }
        FLOW.DOWN_LEFT  = { V, d.Left,  d.Down, "TOPRIGHT" }
        FLOW.DOWN_RIGHT = { V, d.Right, d.Down, "TOPLEFT" }
        FLOW.UP_LEFT    = { V, d.Left,  d.Up,   "BOTTOMRIGHT" }
        FLOW.UP_RIGHT   = { V, d.Right, d.Up,   "BOTTOMLEFT" }
    end
end
local function IsHorizontal(growth) return growth:match("^LEFT") or growth:match("^RIGHT") end

local function SortOf(k)
    local M, D = AuraContainerSortMethod, AuraContainerSortDirection
    if not (M and D) then return nil, nil end
    local sort = Get(k, "Sort")
    local method = (sort == "INDEX" and M.AuraInstanceIDOnly) or (sort == "NAME" and M.Name) or M.Expiration
    return method, Get(k, "SortDir") == "-" and D.Reverse or D.Normal
end

-- ============================================================================
-- Buttons
-- ============================================================================


local state = {}   -- kind id -> { holder, container, buttons = {button = pieces} }

local function PlaceDuration(k, d)
    local fs, icon = d.dur, d.icon
    local pos, x, y = Get(k, "DurPos"), Get(k, "DurX"), Get(k, "DurY")
    fs:ClearAllPoints()
    if pos == "TOP" then fs:SetPoint("TOP", icon, "TOP", x, -1 + y)
    elseif pos == "BOTTOM" then fs:SetPoint("BOTTOM", icon, "BOTTOM", x, 1 + y)
    elseif pos == "ABOVE" then fs:SetPoint("BOTTOM", icon, "TOP", x, 2 + y)
    elseif pos == "BELOW" then fs:SetPoint("TOP", icon, "BOTTOM", x, -2 + y)
    else fs:SetPoint("CENTER", icon, "CENTER", x, y) end
end

-- Everything here touches only the pieces we own, never the button, so it
-- is safe at any time.
local function StylePieces(k, d)
    SetFont(d.dur, Get(k, "DurFont"), Get(k, "DurSize"), Get(k, "DurOutline"))
    PlaceDuration(k, d)
    d.durHost:SetShown(Get(k, "DurShow") ~= false)
    SetFont(d.count, Get(k, "CountFont"), Get(k, "CountSize"), Get(k, "CountOutline"))
    local cp = Get(k, "CountPos")
    d.count:ClearAllPoints()
    d.count:SetPoint(cp, d.icon, cp, Get(k, "CountX"), Get(k, "CountY"))
    d.count:SetJustifyH(cp:find("LEFT") and "LEFT" or (cp:find("RIGHT") and "RIGHT" or "CENTER"))
    if d.typeHost then d.typeHost:SetShown(Settings().auDColorType ~= false) end
    pcall(d.cooldown.SetDrawSwipe, d.cooldown, Get(k, "Swipe") ~= false)
end

-- Size and crop: on the button and the registered icon, so out of combat only.
local function SizeButton(k, button, d)
    local w, h = Dims(k)
    button:SetSize(w, h)
    d.icon:SetTexCoord(Crop(w, h))
end

local function MakeInitializer(k)
    return function(button)
        local st = state[k.id]
        local d = {}
        local w, h = Dims(k)
        button:SetSize(w, h)

        local bg = button:CreateTexture(nil, "BACKGROUND", nil, -8)
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 1)

        if k.id == "D" then
            -- The debuff-type edge: a full-size texture behind the icon, the
            -- client colours it. Its Shown is the engine's, so a host of ours
            -- carries the on/off switch.
            local host = CreateFrame("Frame", nil, button)
            host:SetAllPoints()
            host:SetFrameLevel(button:GetFrameLevel())
            local tex = host:CreateTexture(nil, "BACKGROUND", nil, -7)
            tex:SetAllPoints()
            tex:SetColorTexture(1, 1, 1, 1)
            local style = Enum.CustomAuraButtonDispelTypeTextureStyle
            pcall(button.AddDispelTypeTexture, button, tex, { style = style and style.PreserveAsset or 3 })
            d.typeHost = host
        end

        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
        icon:SetTexCoord(Crop(w, h))
        d.icon = icon
        pcall(button.SetIcon, button, icon)

        local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        cd:SetAllPoints(icon)
        cd:SetReverse(true)
        cd:SetDrawEdge(false)
        cd:SetHideCountdownNumbers(true)
        d.cooldown = cd
        pcall(button.SetDurationCooldown, button, cd)

        local text = CreateFrame("Frame", nil, button)
        text:SetAllPoints()
        text:SetFrameLevel(cd:GetFrameLevel() + 2)
        local durHost = CreateFrame("Frame", nil, text)
        durHost:SetAllPoints()
        d.durHost = durHost
        local dur = durHost:CreateFontString(nil, "OVERLAY")
        dur:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
        d.dur = dur
        local count = text:CreateFontString(nil, "OVERLAY")
        count:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
        d.count = count
        StylePieces(k, d)

        if not pcall(button.SetApplicationCount, button, count, {}) then
            pcall(button.SetApplicationCount, button, count)
        end
        local native = BH.cdm and BH.cdm.native
        local fmt = native and native.DurationFormatter and native.DurationFormatter()
        if not (fmt and pcall(button.SetDurationText, button, dur, { textFormatter = fmt })) then
            pcall(button.SetDurationText, button, dur, {})
        end

        if k.id == "B" then pcall(button.SetCancelAuraButtons, button, "RightButtonUp") end
        pcall(button.SetTooltipAnchorPoint, button, "ANCHOR_BOTTOMLEFT", -5, -5)

        st.buttons[button] = d
    end
end

-- ============================================================================
-- Frames
-- ============================================================================

local function Place(f, pos, default)
    pos = pos or default
    f:ClearAllPoints()
    f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
end

-- Saved at the growth corner, so changing icons per row or rows grows the
-- frame away from where it was put, as ElvUI's do.
local function SaveCorner(f, k)
    local point = (FLOW[Get(k, "Growth")] or {})[4] or "TOPRIGHT"
    local scale = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not (l and r and t and b) then return end
    local x = (point:find("LEFT") and l or r) * scale
    local y = (point:find("TOP") and t or b) * scale
    local ux = point:find("LEFT") and 0 or UIParent:GetWidth()
    local uy = point:find("TOP") and UIParent:GetHeight() or 0
    BH.settings["au" .. k.id .. "Position"] = { point = point, relPoint = point,
        x = math.floor(x - ux + 0.5), y = math.floor(y - uy + 0.5) }
    BH:SaveSettings()
end

function AU.Nudge(id, dx, dy)
    local k = id == "B" and KINDS[1] or KINDS[2]
    local st = state[k.id]
    if not (st and st.holder) then return end
    st.holder:AdjustPointsOffset(dx, dy)
    SaveCorner(st.holder, k)
    Apply()
end

local function LoadEngine()
    if C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then return true end
    if InCombatLockdown() then return false end
    pcall(C_AddOns.LoadAddOn, "Blizzard_AuraContainer")
    return C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer")
end

local function Layout(k)
    local w, h = Dims(k)
    return { elementSpacing = Get(k, "HSpacing"), lineSpacing = Get(k, "VSpacing"),
             elementWidth = w, elementHeight = h }
end

-- Container-level layout: direction, row length, and the holder's size
-- (the whole grid, so Edit Mode shows the space it will fill).
local function ApplyFlow(k, st)
    local c, holder = st.container, st.holder
    local growth = Get(k, "Growth")
    local flow = FLOW[growth] or FLOW.LEFT_DOWN
    local w, h = Dims(k)
    local per, rows = Get(k, "WrapAfter"), Get(k, "MaxWraps")
    local hs, vs = Get(k, "HSpacing"), Get(k, "VSpacing")
    local horiz = IsHorizontal(growth)
    local along = horiz and (w + hs) or (h + hs)
    if horiz then
        holder:SetSize(per * w + (per - 1) * hs, rows * h + (rows - 1) * vs)
    else
        holder:SetSize(rows * w + (rows - 1) * vs, per * h + (per - 1) * hs)
    end
    pcall(function()
        c:SetFlowLayoutAxis(flow[1])
        c:SetFlowLayoutAnchorPoint(flow[4])
        c:SetFlowLayoutGrowthDirection(flow[2], flow[3])
        c:SetFlowLayoutMaximumLineSize(along * per)
    end)
end

local function Build(k)
    local st = state[k.id]
    if st then return st end
    if not LoadEngine() then return nil end
    st = { buttons = setmetatable({}, { __mode = "k" }) }
    state[k.id] = st

    local holder = CreateFrame("Frame", k.frameName, UIParent)
    holder:SetFrameStrata("LOW")
    holder:SetClampedToScreen(true)
    holder:SetMovable(true)
    holder:RegisterForDrag("LeftButton")
    holder:SetScript("OnDragStart", function(self)
        if InCombatLockdown() or not BH.unlockMode then return end
        BH:GridStartMoving(self)
    end)
    holder:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(self)
        SaveCorner(self, k)
        Apply()
    end)
    st.holder = holder
    BH[k.field] = holder

    local ok, c = pcall(CreateFrame, "AuraContainer", nil, holder, "CustomAuraContainerTemplate")
    if not (ok and c and c.AddAuraGroup) then
        print("|cff33cc99Squizzumables:|r the game's aura engine did not load, so the " .. k.label:lower()
            .. " frame can't be built.")
        return st
    end
    c:SetAllPoints(holder)
    st.container = c
    ApplyFlow(k, st)

    local method, dir = SortOf(k)
    local okGroup, err = pcall(c.AddAuraGroup, c, "sq" .. k.key, k.filter, {
        initializeFrame = MakeInitializer(k),
        maxFrameCount = Get(k, "WrapAfter") * Get(k, "MaxWraps"),
        sortMethod = method, sortDirection = dir,
        layout = Layout(k),
    })
    if not okGroup then print("|cff33cc99Squizzumables:|r " .. tostring(err)) end

    local slots = rawget(_G, "AuraContainerItemEnchantmentSlot")
    if k.id == "B" and slots and c.AddItemEnchantment then
        for _, slot in ipairs({ slots.MainHand, slots.OffHand }) do
            pcall(c.AddItemEnchantment, c, slot, { initializeFrame = MakeInitializer(k) })
        end
        local placement = rawget(_G, "CustomAuraContainerItemEnchantmentPlacement")
        local layout = Layout(k)
        layout.placement = placement and placement.BeforeAuraGroups
        pcall(c.SetItemEnchantmentLayout, c, layout)
        st.enchants = true
    end

    -- Unit last.
    pcall(function()
        c:SetUnit("player")
        c:SetEnabled(true)
        c:Show()
        c:UpdateAllAuras()
    end)
    AU.built = true
    return st
end

local pendingCombat
local function Restyle(k, st)
    for _, d in pairs(st.buttons) do StylePieces(k, d) end
    if not st.container then return end
    if InCombatLockdown() then pendingCombat = true return end
    local c = st.container
    ApplyFlow(k, st)
    local method, dir = SortOf(k)
    pcall(c.SetAuraGroupMaxFrameCount, c, "sq" .. k.key, Get(k, "WrapAfter") * Get(k, "MaxWraps"))
    if method then pcall(c.SetAuraGroupSortMethod, c, "sq" .. k.key, method, dir) end
    pcall(c.SetAuraGroupLayout, c, "sq" .. k.key, Layout(k))
    if st.enchants then
        local layout = Layout(k)
        local placement = rawget(_G, "CustomAuraContainerItemEnchantmentPlacement")
        layout.placement = placement and placement.BeforeAuraGroups
        pcall(c.SetItemEnchantmentLayout, c, layout)
        local slots = rawget(_G, "AuraContainerItemEnchantmentSlot")
        local on = Settings().auBEnchants ~= false
        for _, slot in ipairs({ slots.MainHand, slots.OffHand }) do
            pcall(c.SetItemEnchantmentEnabled, c, slot, on)
        end
    end
    local unlocked = BH.unlockMode and true or false
    for button, d in pairs(st.buttons) do
        pcall(SizeButton, k, button, d)
        -- In Edit Mode the icons let a drag through to the frame.
        pcall(button.EnableMouse, button, not unlocked)
    end
end

-- ============================================================================
-- Blizzard's frames
-- ============================================================================

local hiddenParent, hidBlizzard
local function HideBlizzard(hide)
    if InCombatLockdown() then pendingCombat = true return end
    for _, name in ipairs({ "BuffFrame", "DebuffFrame" }) do
        local f = _G[name]
        if f then
            if hide then
                hiddenParent = hiddenParent or CreateFrame("Frame")
                hiddenParent:Hide()
                f:SetParent(hiddenParent)
            elseif hidBlizzard then
                f:SetParent(UIParent)
            end
        end
    end
    hidBlizzard = hide
end

-- ============================================================================
-- Apply
-- ============================================================================

function AU.Apply()
    if not Active() then
        for _, st in pairs(state) do if st.holder then st.holder:Hide() end end
        if hidBlizzard then HideBlizzard(false) end
        return
    end
    local s = Settings()
    for _, k in ipairs(KINDS) do
        local st = Build(k)
        if st and st.holder then
            if not InCombatLockdown() then
                Place(st.holder, s["au" .. k.id .. "Position"], k.pos)
                st.holder:EnableMouse(BH.unlockMode and true or false)
            end
            st.holder:Show()
            Restyle(k, st)
        end
    end
    local hide = s.auHideBlizzard ~= false
    if hide or hidBlizzard then HideBlizzard(hide) end
end

-- ============================================================================
-- ElvUI's layout, copied once per profile
-- ============================================================================

local function MapOutline(o)
    if o == "OUTLINE" or o == "THICKOUTLINE" or o == "NONE" or o == "SHADOW" then return o end
    if type(o) == "string" and o:find("OUTLINE") then return "OUTLINE" end
    return nil
end

-- A mover string ("POINT,Parent,RELPOINT,x,y") turned into a position on
-- UIParent. Most are relative to ElvUIParent, which covers the screen as
-- UIParent does; the others (the buffs sit beside ElvUI's minimap by default)
-- are measured off the live frame they name.
local function PositionFrom(str, k, w, h)
    if type(str) ~= "string" then return nil end
    local pt, rel, relPt, x, y = strsplit(",", str)
    x, y = tonumber(x), tonumber(y)
    if not (pt and rel and relPt and x and y) then return nil end
    if rel == "ElvUIParent" or rel == "UIParent" then
        return { point = pt, relPoint = relPt, x = x, y = y }
    end
    local target = _G[rel]
    if not (target and target.GetLeft and target:GetLeft()) then return nil end
    local probe = CreateFrame("Frame", nil, UIParent)
    probe:SetSize(w, h)
    probe:SetPoint(pt, target, relPt, x, y)
    local l = probe:GetLeft()
    if not l then probe:Hide() return nil end
    local saved = BH.settings["au" .. k.id .. "Position"]
    SaveCorner(probe, k)
    local pos = BH.settings["au" .. k.id .. "Position"]
    BH.settings["au" .. k.id .. "Position"] = saved
    probe:Hide()
    return pos
end

local function Seed()
    local s = BH.settings
    if not s or s.auLayoutSeededFromElvUI then return end
    local E = Elv()
    local db = E and E.db and E.db.auras
    if type(db) ~= "table" or type(db.buffs) ~= "table" then return end
    s.auLayoutSeededFromElvUI = true
    if E.private and E.private.auras and E.private.auras.enable then s.auEnabled = true end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local function Font(name) return type(name) == "string" and lsm and lsm:IsValid("font", name) and name or nil end
    local cd = E.db.cooldown and E.db.cooldown.auras
    local movers = E.db.movers or {}
    for _, k in ipairs(KINDS) do
        local e, p = db[k.key], "au" .. k.id
        if type(e) == "table" then
            local function Num(v, key) if tonumber(v) then s[p .. key] = tonumber(v) end end
            Num(e.size, "Size")
            Num(e.height, "Height")
            if e.keepSizeRatio ~= nil then s[p .. "KeepRatio"] = e.keepSizeRatio and true or false end
            if FLOW[e.growthDirection] then s[p .. "Growth"] = e.growthDirection end
            Num(e.wrapAfter, "WrapAfter")
            Num(e.maxWraps, "MaxWraps")
            Num(e.horizontalSpacing, "HSpacing")
            Num(e.verticalSpacing, "VSpacing")
            if e.sortMethod == "TIME" or e.sortMethod == "INDEX" or e.sortMethod == "NAME" then
                s[p .. "Sort"] = e.sortMethod
            end
            if e.sortDir == "+" or e.sortDir == "-" then s[p .. "SortDir"] = e.sortDir end
            s[p .. "CountFont"] = Font(e.countFont) or s[p .. "CountFont"]
            Num(e.countFontSize, "CountSize")
            s[p .. "CountOutline"] = MapOutline(e.countFontOutline) or s[p .. "CountOutline"]
            Num(e.countXOffset, "CountX")
            Num(e.countYOffset, "CountY")
            if type(cd) == "table" then
                s[p .. "DurFont"] = Font(cd.font) or s[p .. "DurFont"]
                Num(cd.fontSize, "DurSize")
                s[p .. "DurOutline"] = MapOutline(cd.fontOutline) or s[p .. "DurOutline"]
                if cd.position == "CENTER" or cd.position == "TOP" or cd.position == "BOTTOM" then
                    s[p .. "DurPos"] = cd.position
                end
                Num(cd.offsetX, "DurX")
                Num(cd.offsetY, "DurY")
                if cd.hideNumbers then s[p .. "DurShow"] = false end
            end
            local w, h = Dims(k)
            local per, rows = Get(k, "WrapAfter"), Get(k, "MaxWraps")
            local hs, vs = Get(k, "HSpacing"), Get(k, "VSpacing")
            local horiz = IsHorizontal(Get(k, "Growth"))
            local fw = horiz and (per * w + (per - 1) * hs) or (rows * w + (rows - 1) * vs)
            local fh = horiz and (rows * h + (rows - 1) * vs) or (per * h + (per - 1) * hs)
            local mover = movers[k.id == "B" and "BuffsMover" or "DebuffsMover"]
            if not mover then
                mover = k.id == "B" and "TOPRIGHT,ElvUI_MinimapHolder,TOPLEFT,-7,0"
                    or "BOTTOMRIGHT,ElvUI_MinimapHolder,BOTTOMLEFT,-7,0"
            end
            local ok, pos = pcall(PositionFrom, mover, k, fw, fh)
            if ok and pos then s[p .. "Position"] = pos end
        end
    end
    if db.colorDebuffs == false then s.auDColorType = false end
    BH:SaveSettings()
end

function BH:ApplyBuffFrame()
    Seed()
    AU.Apply()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if pendingCombat then pendingCombat = nil AU.Apply() end
        return
    end
    BH:ApplyBuffFrame()
end)
