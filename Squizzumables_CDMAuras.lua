-- Squizzumables_CDMAuras.lua
-- Tracked buffs and buff bars drawn as our own icons and bars, filled in by the
-- client through Blizzard_AuraContainer (12.1).
--
-- WHY THIS EXISTS
--
-- A tracked buff's duration, stacks and even which aura instance it is are
-- secret in combat, so an icon of ours could never draw its sweep (1.69 proved
-- that three ways -- see the Taint safety notes in CLAUDE.md). The answer until
-- now was to borrow Blizzard's own buff frames and only re-anchor them, which
-- works in combat but leaves them looking like Blizzard's: none of a group's
-- border, zoom, shape, background or text settings could reach them.
--
-- AuraContainer inverts who reads the aura. We build every piece of a button --
-- icon texture, cooldown, font strings, status bar -- style it, and hand each
-- one to the button (SetIcon, SetDurationCooldown, SetApplicationCount,
-- SetDurationText, SetDurationBar, SetSpellName). From then on the CLIENT
-- writes the live values into our pieces, C-side, so nothing secret ever
-- reaches this addon's Lua, and it keeps working in combat. The look is ours.
--
-- HOW IT FITS THE EXISTING LAYOUT
--
-- One AuraSlot per tracked buff: a slot shows at most one aura, in a place we
-- choose. We choose it through a chain the client cannot object to:
--
--   group frame (ours)
--     cell (ours)          <- LayoutBorrowedBuffIcons moves this like any slot
--       host (ours, DisableUntrustedLayoutScriptsTemplate)
--   AuraContainer (ours, child of the group frame)
--     slot button          <- SetAllPoints(host), inside initializeFrame only
--
-- Blizzard's own frame for the buff still decides WHETHER it is up: IsShown is
-- a plain flag, readable in combat, and it is what the layout already packs by.
-- So the row packs, the placeholders and the unlock-mode mock all work exactly
-- as before; the only change is that the slot holds our cell instead of
-- Blizzard's frame, which is parked off screen (never hidden -- Blizzard stops
-- updating a hidden item, and the sound alerts read its state).
--
-- RULES, learned the hard way by SquizzFrames, EnhanceQoL and EllesmereUI:
--
--   * Aura buttons are forbidden objects once their aura is secret. Every call
--     on the BUTTON happens inside initializeFrame. Afterwards only the pieces
--     we created are touched, and only out of combat (Style).
--   * Style every piece before registering it: registering a font string with
--     no font hard-errors inside the engine and aborts the whole batch. Every
--     registration is pcall'd for the same reason.
--   * Anchor the host BEFORE AddAuraSlot: the slot makes the button-to-host
--     relationship immutable. Hosts are therefore new for every build.
--   * Declare the slots before SetUnit, or UNIT_AURA is never registered.
--   * Containers only out of combat. Reconcile already refuses to run in
--     combat, and everything here is reached from it.
--   * Do NOT define CustomAuraButtonTemplate. Early 12.1 builds needed an
--     addon to supply it (SquizzFrames still ships an empty one); live
--     Blizzard_AuraContainer ships its own, with the mixins the button needs.
--   * A slot locks onto the first aura instance it matched and does not always
--     notice a refresh, so every container gets UpdateAllAuras on a ticker.
--   * Spell-ID candidate filters are ignored for a HARMFUL aura on an
--     assistable unit. The player is always assistable, so the player side is
--     HELPFUL only: a HARMFUL slot there would show every debuff you have.
--
-- WHAT STAYS ON BLIZZARD'S FRAMES
--
-- A buff whose Blizzard item is up because of a totem rather than an aura
-- (totemData set, no auraInstanceID): its slot has nothing to show, so for as
-- long as that lasts Blizzard's frame takes the slot. Decided per layout pass
-- from the item, because nothing in the cooldown info says in advance which
-- entries those are. And any entry whose slot failed to build, which stays on
-- the borrowed path entirely. Either way a buff never goes missing because of
-- this file.

local addonName, ns = ...
local BH = ns.BH
if not BH or not BH.cdm then return end
local cdm = BH.cdm

local Native = {}
cdm.native = Native

local SH = cdm.shared or {}

local AURA_ADDON          = "Blizzard_AuraContainer"
local CONTAINER_TEMPLATE  = "CustomAuraContainerTemplate"
local HOST_TEMPLATE       = "DisableUntrustedLayoutScriptsTemplate"
local REFRESH_INTERVAL    = 1.5
local FONT                = "Fonts\\FRIZQT__.TTF"
local BAR_TEXTURE         = "Interface\\TargetingFrame\\UI-StatusBar"
local SQUARE_SWIPE        = "Interface\\Buttons\\WHITE8X8"
local DEFAULT_BAR_COLOR   = { 1.0, 0.7, 0.0, 1 }

-- [groupName] = {
--   sig, styleSig      structure / style signatures last applied
--   groupData          the group's settings, for the initializer
--   cells              [cooldownID] = cell frame, reused across builds
--   active             [cooldownID] = true, slots that registered
--   containers         the AuraContainers of the current build
--   buttons            weak [button] = our pieces, for restyling
--   buttonCount        how many times initializeFrame ran (diagnostics)
-- }
local groups = {}
-- [cooldownID] = groupName, only for slots that really registered. This is what
-- the layout asks, so a failed build falls back to the borrowed path by itself.
local nativeCooldowns = {}

-- Active-state overlays, keyed by cooldownID. Deliberately NOT part of
-- `groups`: an overlay belongs to one cooldown icon rather than to a group's
-- layout, it is built from a different trigger, and keeping it separate means
-- the buff path cannot be disturbed by it. Declared up here so EnsureTicker,
-- below, can refresh these containers too.
local activeOverlays = {}

local availability     -- nil = not checked yet
local refreshTicker
Native.lastError = nil

local function Note(err)
    Native.lastError = tostring(err)
end

-- ============================================================================
-- Availability
-- ============================================================================

-- Load Blizzard_AuraContainer and prove the widget works, once.
--
-- LoadAddOn is not documented as combat-safe, so in combat an unloaded addon is
-- "not available yet" rather than a failure: the borrowed path covers until the
-- next out-of-combat reconcile. Preload runs it at login for that reason.
function Native:IsAvailable()
    if availability ~= nil then return availability end
    if not (C_AddOns and C_AddOns.IsAddOnLoaded and CreateFrame) then
        availability = false
        return false
    end
    if not C_AddOns.IsAddOnLoaded(AURA_ADDON) then
        if InCombatLockdown() then return false end
        local ok, err = pcall(C_AddOns.LoadAddOn, AURA_ADDON)
        if not (ok and C_AddOns.IsAddOnLoaded(AURA_ADDON)) then
            Note(ok and "Blizzard_AuraContainer did not load" or err)
            availability = false
            return false
        end
    end
    local ok, probe = pcall(CreateFrame, "AuraContainer", nil, UIParent, CONTAINER_TEMPLATE)
    if not (ok and probe and type(probe.AddAuraSlot) == "function"
            and type(probe.SetUnit) == "function"
            and type(probe.UpdateAllAuras) == "function") then
        Note(ok and "AuraContainer is missing AddAuraSlot/SetUnit/UpdateAllAuras" or probe)
        availability = false
        return false
    end
    pcall(probe.SetEnabled, probe, false)
    pcall(probe.Hide, probe)
    availability = true
    return true
end

function Native:Preload()
    if not InCombatLockdown() then self:IsAvailable() end
end

function Native:IsEnabled()
    local s = BH.settings
    if not s or s.cdmProxyBuffIcons or s.cdmNativeBuffs == false then return false end
    return self:IsAvailable()
end

-- Should this registry entry be drawn natively? Decided in Reconcile, before
-- anything is built; whether it actually WAS is IsNative.
function Native:Handles(entry)
    if not entry then return false end
    if entry.viewerType ~= "buff" and entry.viewerType ~= "buffbar" then return false end
    -- Deliberately NOT gated on cooldownInfo.hasAura. That looked like the way
    -- to spot totem-style entries up front, but Blizzard's own viewer code
    -- never reads it, so it says nothing we can rely on -- and gating on it is
    -- the likely reason the first in-game test drew every buff on Blizzard's
    -- frames. Totem-style entries are caught per pass instead, from the item
    -- itself (ItemDrivenByTotem in Squizzumables_CDM.lua).
    if not entry.spellID and not (entry.auraIDs and #entry.auraIDs > 0) then return false end
    return self:IsEnabled()
end

function Native:IsNative(cdID)
    return nativeCooldowns[cdID] ~= nil
end

function Native:GetCell(groupName, cdID)
    local st = groups[groupName]
    if not (st and st.active[cdID]) then return nil end
    return st.cells[cdID]
end

-- ============================================================================
-- Spell IDs and signatures
-- ============================================================================

-- Every ID the aura might be filed under -- Blizzard's own buff item matches the
-- linked spells, then the tooltip override, then the override, then the base
-- spell (CooldownViewerItemDataMixin:GetAssociatedAuraSpellPriority). A slot
-- takes a set, so all of them go in.
local function AuraSpellIDs(entry)
    local ids, list = {}, {}
    local function add(v)
        local id = BH.Secrets.SafeNumber(v, nil)
        if id and id > 0 and not ids[id] then
            ids[id] = true
            list[#list + 1] = id
        end
    end
    add(entry.spellID)
    add(entry.tooltipSpellID)
    for _, id in ipairs(entry.auraIDs or {}) do add(id) end
    table.sort(list)
    return ids, table.concat(list, ",")
end

local function UnitFor(entry)
    return entry.selfAura == false and "target" or "player"
end

-- The player side is HELPFUL only: see the header about candidate filters and
-- assistable units. The target side is ours only (PLAYER), both polarities, to
-- cover a debuff on an enemy and a buff on a friend alike.
local FILTERS = {
    player = { "HELPFUL" },
    target = { "HARMFUL|PLAYER", "HELPFUL|PLAYER" },
}

local function StructureSignature(groupData, entries)
    local parts = {
        groupData.isBarGroup and "bar" or "icon",
        groupData.showTooltip ~= false and "tip" or "notip",
    }
    for _, entry in ipairs(entries) do
        local _, idSig = AuraSpellIDs(entry)
        parts[#parts + 1] = tostring(entry.cooldownID) .. ":" .. UnitFor(entry) .. ":" .. idSig
    end
    return table.concat(parts, "|")
end

local function ColorSig(c)
    if type(c) ~= "table" then return "-" end
    return ("%.3f,%.3f,%.3f,%.3f"):format(c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 1)
end

-- Everything Style reads. Anything new that Style reads has to join this, or
-- changing it will appear to do nothing until the next rebuild.
local function StyleSignature(gd)
    return table.concat({
        tostring(gd.iconZoom), tostring(gd.iconShape), tostring(gd.iconSize),
        tostring(gd.borderThickness), ColorSig(gd.borderColor),
        tostring(gd.borderClassColor), tostring(gd.showBorder),
        tostring(gd.bgEnabled), ColorSig(gd.bgColor),
        tostring(gd.showCount), tostring(gd.countSize), tostring(gd.countPosition),
        tostring(gd.countOffsetX), tostring(gd.countOffsetY),
        tostring(gd.showCooldownText), tostring(gd.cooldownTextPosition),
        tostring(gd.cooldownTextOffsetX), tostring(gd.cooldownTextOffsetY),
        tostring(gd.barHeight), ColorSig(gd.barColor),
    }, "|")
end

-- ============================================================================
-- Duration text
-- ============================================================================

-- The remaining time is secret, so the client formats it: SetDurationText takes
-- a formatter object that is evaluated engine-side. Same look as Blizzard's own
-- cooldown numbers -- bare seconds, then 2m / 1h / 1d.
--
-- Schema per SquizzFrames' working formatter: every breakpoint carries a
-- TOP-LEVEL step and rounding (rounding is non-nilable and a table without it
-- is rejected whole), added one at a time, ascending. nil falls back to the
-- engine's own formatting, which is still a readable countdown.
local formatter, formatterTried
local function DurationFormatter()
    if formatterTried then return formatter end
    formatterTried = true
    if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter
            and Enum and Enum.NumericRuleFormatRounding) then
        return nil
    end
    local ok, f = pcall(function()
        local Up = Enum.NumericRuleFormatRounding.Up
        local Down = Enum.NumericRuleFormatRounding.Down
        local fmt = C_StringUtil.CreateNumericRuleFormatter()
        local points = {
            { threshold = 0,     step = 1, rounding = Up,   min = 1, format = "%d" },
            { threshold = 60,    step = 1, rounding = Down, min = 1, format = "%dm",
              components = { { div = 60, rounding = Down } } },
            { threshold = 3600,  step = 1, rounding = Down, min = 1, format = "%dh",
              components = { { div = 3600, rounding = Down } } },
            { threshold = 86400, step = 1, rounding = Down, min = 1, format = "%dd",
              components = { { div = 86400, rounding = Down } } },
        }
        if fmt.ClearBreakpoints then fmt:ClearBreakpoints() end
        for i = 1, #points do fmt:AddBreakpoint(points[i]) end
        return fmt
    end)
    if ok then formatter = f else Note(f) end
    return formatter
end

-- ============================================================================
-- Button pieces
-- ============================================================================

local function BorderColor(gd)
    local bc = gd.borderColor or SH.DEFAULT_BORDER_COLOR or { 0, 0, 0, 0.9 }
    local r, g, b, a = bc[1], bc[2], bc[3], bc[4]
    if gd.borderClassColor then
        local _, class = UnitClass("player")
        local cc = class and C_ClassColor and C_ClassColor.GetClassColor
            and C_ClassColor.GetClassColor(class)
        if cc then r, g, b = cc.r, cc.g, cc.b end
    end
    return r, g, b, a
end

local function NewFontString(parent)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    -- A font before anything else: see the header.
    fs:SetFont(FONT, 12, "OUTLINE")
    return fs
end

local function BuildIconPieces(button)
    local d = { isBar = false }
    d.bg = button:CreateTexture(nil, "BACKGROUND")
    d.bg:SetAllPoints(button)
    -- Below the background and the icon: only the rim that sticks out past
    -- them shows. Same trick as a shaped proxy's ShapeBorder.
    d.shapeBorder = button:CreateTexture(nil, "BACKGROUND", nil, -8)
    d.icon = button:CreateTexture(nil, "ARTWORK")
    d.icon:SetAllPoints(button)
    d.mask = button:CreateMaskTexture()
    d.mask:SetAllPoints(d.icon)

    d.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    d.cooldown:SetAllPoints(button)
    d.cooldown:SetDrawEdge(false)
    d.cooldown:SetDrawBling(false)
    d.cooldown:SetReverse(true)
    -- An engine-bound cooldown draws no countdown of its own; the time is the
    -- duration text below, which is also the one we can place.
    d.cooldown:SetHideCountdownNumbers(true)
    if d.cooldown.SetUseAuraDisplayTime then d.cooldown:SetUseAuraDisplayTime(true) end

    d.border = CreateFrame("Frame", nil, button, "BackdropTemplate")
    d.border:SetFrameLevel(d.cooldown:GetFrameLevel() + 1)
    d.text = CreateFrame("Frame", nil, button)
    d.text:SetAllPoints(button)
    d.text:SetFrameLevel(d.border:GetFrameLevel() + 1)
    d.count = NewFontString(d.text)
    d.duration = NewFontString(d.text)
    return d
end

local function BuildBarPieces(button)
    local d = { isBar = true }
    d.iconHolder = CreateFrame("Frame", nil, button)
    d.iconHolder:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    d.iconHolder:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    d.icon = d.iconHolder:CreateTexture(nil, "ARTWORK")
    d.icon:SetAllPoints(d.iconHolder)

    d.bar = CreateFrame("StatusBar", nil, button)
    d.bar:SetPoint("TOPLEFT", d.iconHolder, "TOPRIGHT", 1, 0)
    d.bar:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    d.bar:SetStatusBarTexture(BAR_TEXTURE)
    d.barBg = d.bar:CreateTexture(nil, "BACKGROUND")
    d.barBg:SetAllPoints(d.bar)
    d.barBg:SetColorTexture(0, 0, 0, 0.5)

    d.border = CreateFrame("Frame", nil, button, "BackdropTemplate")
    d.border:SetFrameLevel(d.bar:GetFrameLevel() + 1)
    d.text = CreateFrame("Frame", nil, button)
    d.text:SetAllPoints(button)
    d.text:SetFrameLevel(d.border:GetFrameLevel() + 1)
    d.duration = NewFontString(d.text)
    d.duration:SetPoint("RIGHT", d.bar, "RIGHT", -4, 0)
    d.name = NewFontString(d.text)
    d.name:SetPoint("LEFT", d.bar, "LEFT", 4, 0)
    d.name:SetPoint("RIGHT", d.duration, "LEFT", -4, 0)
    d.name:SetJustifyH("LEFT")
    d.name:SetWordWrap(false)
    d.count = NewFontString(d.text)
    return d
end

local function StyleBorder(d, gd, shapeFile)
    local thickness = gd.borderThickness or SH.DEFAULT_BORDER_THICKNESS or 1
    local show = gd.showBorder ~= false
    local r, g, b, a = BorderColor(gd)
    local anchor = d.isBar and d.border:GetParent() or d.icon

    if shapeFile and d.shapeBorder then
        d.shapeBorder:SetTexture(shapeFile)
        d.shapeBorder:ClearAllPoints()
        d.shapeBorder:SetPoint("TOPLEFT", d.icon, "TOPLEFT", -thickness, thickness)
        d.shapeBorder:SetPoint("BOTTOMRIGHT", d.icon, "BOTTOMRIGHT", thickness, -thickness)
        d.shapeBorder:SetVertexColor(r, g, b, a)
        d.shapeBorder:SetShown(show)
        d.border:Hide()
        return
    end
    if d.shapeBorder then d.shapeBorder:Hide() end
    d.border:ClearAllPoints()
    d.border:SetPoint("TOPLEFT", anchor, "TOPLEFT", -thickness, thickness)
    d.border:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", thickness, -thickness)
    d.border:SetBackdrop({ edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = thickness })
    d.border:SetBackdropBorderColor(r, g, b, a)
    d.border:SetShown(show)
end

-- Style our pieces from the group's settings. Touches nothing but regions we
-- created, so it is legal after the button has gone restricted -- but only out
-- of combat, which is where every caller is.
local function Style(d, gd)
    local zoom = gd.iconZoom or SH.DEFAULT_ICON_ZOOM or 0.07
    d.icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)

    local countSize = gd.countSize or 12
    d.count:SetFont(FONT, countSize, "OUTLINE")
    d.count:SetAlpha(gd.showCount ~= false and 1 or 0)
    -- Hidden by alpha, never unregistered: registration can only happen in
    -- initializeFrame, so turning the text back on must not need a rebuild.
    d.duration:SetAlpha(gd.showCooldownText ~= false and 1 or 0)

    if d.isBar then
        local barH = gd.barHeight or 20
        d.iconHolder:SetWidth(barH)
        local c = gd.barColor or DEFAULT_BAR_COLOR
        d.bar:SetStatusBarColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
        local textSize = math.max(8, math.floor(barH * 0.55 + 0.5))
        d.name:SetFont(FONT, textSize, "OUTLINE")
        d.duration:SetFont(FONT, textSize, "OUTLINE")
        if SH.PlaceText then
            SH.PlaceText(d.count, d.iconHolder, gd.countPosition or "BOTTOMRIGHT",
                gd.countOffsetX or -1, gd.countOffsetY or 1)
        end
        StyleBorder(d, gd, nil)
        return
    end

    -- Shape: the same one image a shaped proxy uses, as mask, swipe and rim.
    local shapeFile = SH.SHAPE_FILE and SH.SHAPE_FILE[gd.iconShape or "none"]
    if shapeFile then
        d.mask:SetTexture(shapeFile, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        if not d.maskOn then
            d.icon:AddMaskTexture(d.mask)
            d.bg:AddMaskTexture(d.mask)
            d.maskOn = true
        end
    elseif d.maskOn then
        d.icon:RemoveMaskTexture(d.mask)
        d.bg:RemoveMaskTexture(d.mask)
        d.maskOn = false
    end
    -- A white texture tinted by the swipe colour draws the same as the
    -- template's own square swipe.
    d.cooldown:SetSwipeTexture(shapeFile or SQUARE_SWIPE)

    local bg = gd.bgColor or SH.DEFAULT_BG_COLOR or { 0.08, 0.08, 0.08, 0.6 }
    d.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    d.bg:SetShown(gd.bgEnabled and true or false)

    local iconSize = gd.iconSize or SH.DEFAULT_ICON_SIZE or 36
    d.duration:SetFont(FONT, math.max(8, math.floor(iconSize * 0.4 + 0.5)), "OUTLINE")
    if SH.PlaceText then
        SH.PlaceText(d.count, d.text, gd.countPosition or "BOTTOMRIGHT",
            gd.countOffsetX or -1, gd.countOffsetY or 1)
        SH.PlaceText(d.duration, d.text, gd.cooldownTextPosition or "CENTER",
            gd.cooldownTextOffsetX or 0, gd.cooldownTextOffsetY or 0)
    end
    StyleBorder(d, gd, shapeFile)
end

-- Hand the pieces to the button. Each registration is pcall'd: an error inside
-- one aborts the engine's whole frame batch, taking the slot with it.
local function Register(button, d)
    pcall(button.SetIcon, button, d.icon)
    if d.isBar then
        local dir = Enum and Enum.StatusBarTimerDirection
            and Enum.StatusBarTimerDirection.RemainingTime
        if not pcall(button.SetDurationBar, button, d.bar, { direction = dir }) then
            pcall(button.SetDurationBar, button, d.bar, {})
        end
        pcall(button.SetSpellName, button, d.name)
    else
        pcall(button.SetDurationCooldown, button, d.cooldown)
    end
    if not pcall(button.SetApplicationCount, button, d.count, {}) then
        pcall(button.SetApplicationCount, button, d.count)
    end
    local fmt = DurationFormatter()
    if not (fmt and pcall(button.SetDurationText, button, d.duration, { textFormatter = fmt })) then
        pcall(button.SetDurationText, button, d.duration, {})
    end
end

-- Called by the engine, once per button it creates for a slot. The ONLY place
-- the button itself may be touched.
local function MakeInitializer(st, host, isBar)
    return function(button)
        st.buttonCount = (st.buttonCount or 0) + 1
        button:ClearAllPoints()
        button:SetAllPoints(host)
        local gd = st.groupData or {}
        if button.SetMouseClickEnabled then button:SetMouseClickEnabled(false) end
        -- Hover shows the aura's tooltip (the button template's own), and a
        -- motion-only frame lets clicks through to the group underneath, so
        -- dragging in unlock mode still works.
        if button.SetMouseMotionEnabled then
            button:SetMouseMotionEnabled(gd.showTooltip ~= false)
        end
        local d = isBar and BuildBarPieces(button) or BuildIconPieces(button)
        Style(d, gd)
        Register(button, d)
        st.buttons[button] = d
    end
end

-- ============================================================================
-- Building
-- ============================================================================

local function NewContainer(groupFrame)
    local ok, c = pcall(CreateFrame, "AuraContainer", nil, groupFrame, CONTAINER_TEMPLATE)
    if not ok or not c then
        Note(c)
        return nil
    end
    -- A renderable rect from the start: the engine drains its work from an
    -- OnUpdate that only runs while visible. pcall'd like every other call on
    -- the container: it is a Blizzard secure-environment object, and a refusal
    -- here must fall back rather than abort the whole reconcile.
    local placed, err = pcall(c.SetAllPoints, c, groupFrame)
    if not placed then
        Note(err)
        pcall(c.Hide, c)
        return nil
    end
    pcall(c.SetFrameLevel, c, groupFrame:GetFrameLevel() + 5)
    return c
end

local function NewHost(cell)
    local ok, host = pcall(CreateFrame, "Frame", nil, cell, HOST_TEMPLATE)
    if not ok or not host then host = CreateFrame("Frame", nil, cell) end
    host:SetAllPoints(cell)
    return host
end

local function GetCellFrame(st, groupFrame, cdID)
    local cell = st.cells[cdID]
    if not cell then
        cell = CreateFrame("Frame", nil, groupFrame)
        cell.isNativeCell = true
        cell.cooldownID = cdID
        cell:EnableMouse(false)
        cell:SetSize(1, 1)
        cell:SetPoint("CENTER", groupFrame, "CENTER")
        st.cells[cdID] = cell
    end
    -- Above the buttons, which sit under the AuraContainer: the keybind text
    -- the layout puts on the cell has to draw over the icon.
    cell:SetFrameLevel(groupFrame:GetFrameLevel() + 30)
    cell:Show()
    return cell
end

-- Take a build down. Containers cannot be destroyed, only switched off.
local function Retire(st, groupName)
    for _, c in ipairs(st.containers or {}) do
        pcall(c.SetEnabled, c, false)
        pcall(c.Hide, c)
    end
    st.containers = {}
    for cdID in pairs(st.active or {}) do
        if nativeCooldowns[cdID] == groupName then nativeCooldowns[cdID] = nil end
    end
    st.active = {}
end

local function EnsureTicker()
    if refreshTicker then return end
    -- UpdateAllAuras is a container method, not a button one, and is legal in
    -- combat -- SquizzFrames has run the same ticker through every fight since
    -- it found slots sticking to a stale instance.
    refreshTicker = C_Timer.NewTicker(REFRESH_INTERVAL, function()
        for _, st in pairs(groups) do
            for _, c in ipairs(st.containers) do
                if c:IsVisible() then pcall(c.UpdateAllAuras, c) end
            end
        end
        -- Active overlays need this for the same reason and more so: a big
        -- cooldown is reapplied rather than refreshed, and a slot that has
        -- locked onto the previous instance would show nothing the second time
        -- the ability was pressed.
        for _, st in pairs(activeOverlays) do
            local c = st.container
            if c and c:IsVisible() then pcall(c.UpdateAllAuras, c) end
        end
    end)
end

local function Build(groupName, st, entries, groupFrame)
    Retire(st, groupName)
    st.buttons = setmetatable({}, { __mode = "k" })
    local isBar = st.groupData.isBarGroup and true or false

    local byUnit, members = {}, {}
    for _, entry in ipairs(entries) do
        local ids, idSig = AuraSpellIDs(entry)
        if idSig ~= "" then
            local unit = UnitFor(entry)
            if byUnit[unit] == nil then
                byUnit[unit] = NewContainer(groupFrame) or false
                members[unit] = {}
            end
            local c = byUnit[unit]
            if c then
                local cdID = entry.cooldownID
                local cell = GetCellFrame(st, groupFrame, cdID)
                local added = false
                for i, filter in ipairs(FILTERS[unit]) do
                    local host = NewHost(cell)
                    local ok, slot = pcall(c.AddAuraSlot, c, "sq" .. cdID .. "_" .. i, filter, {
                        candidateFilters = { includeSpellIDs = ids },
                        initializeFrame = MakeInitializer(st, host, isBar),
                    })
                    if ok and slot then
                        added = true
                    else
                        Note(ok and ("AddAuraSlot returned nothing for " .. cdID) or slot)
                    end
                end
                if added then table.insert(members[unit], cdID) end
            end
        end
    end

    -- Unit LAST: see the header.
    for unit, c in pairs(byUnit) do
        if c then
            local ok, err = pcall(function()
                c:SetUnit(unit)
                c:SetEnabled(true)
                c:Show()
                c:UpdateAllAuras()
            end)
            if ok then
                st.containers[#st.containers + 1] = c
                for _, cdID in ipairs(members[unit]) do
                    st.active[cdID] = true
                    nativeCooldowns[cdID] = groupName
                end
            else
                Note(err)
                pcall(c.SetEnabled, c, false)
                pcall(c.Hide, c)
            end
        end
    end

    -- Cells whose buff is no longer here.
    for cdID, cell in pairs(st.cells) do
        if not st.active[cdID] then cell:Hide() end
    end
    if #st.containers > 0 then EnsureTicker() end
end

-- ============================================================================
-- Active-state overlays -- Essential/Utility "Show While Active"
-- ============================================================================
--
-- The same engine and the same one-slot shape as a tracked buff, with a
-- different host: the button covers a COOLDOWN proxy's icon, and the engine
-- shows it only while that ability's own buff is on the player. So the aura's
-- swipe and countdown are drawn C-side for exactly as long as the ability is
-- running, and the moment it drops the button goes with it, leaving the
-- proxy's real cooldown -- which was being drawn underneath the whole time --
-- as what remains. Nothing has to switch the two over.
--
-- This is the ONLY route that survives combat, and the reason is worth
-- recording. Blizzard's own active icons cache values taken from the aura, so
-- those numbers are AURA-aspect secrets; every numeric cooldown setter
-- (SetCooldown, SetCooldownFromExpirationTime, SetCooldownUNIX) accepts a
-- secret from tainted code only when it carries the COOLDOWN aspect. So the
-- values can neither be read nor passed on -- forwarding them is what produced
-- "Secret values are only allowed during untainted execution", ~114 times a
-- fight. Handing the slot to the engine sidesteps the question entirely: the
-- duration object never enters Lua.
--
-- EllesmereUI arrived at the same shape for the same problem, for the same
-- reason (EllesmereUICdmFakeActive.lua, its "engine-slot driver").
local function ReleaseOverlay(cdID)
    local st = activeOverlays[cdID]
    if not st then return end
    -- Containers cannot be destroyed, only switched off -- as in Retire.
    if st.container then
        pcall(st.container.SetEnabled, st.container, false)
        pcall(st.container.Hide, st.container)
    end
    activeOverlays[cdID] = nil
end

local function BuildOverlay(cdID, proxy, gd, ids)
    local c = NewContainer(proxy)
    if not c then return nil end
    -- Above everything the proxy draws -- its icon, its swipe and its countdown
    -- text -- because while the buff is up this stands in for all three.
    pcall(c.SetFrameLevel, c, proxy:GetFrameLevel() + 10)

    local st = { groupData = gd, buttons = setmetatable({}, { __mode = "k" }) }
    -- A fresh host every build: the slot makes the button-to-host binding
    -- immutable, so a reused one would still be anchored to the old proxy.
    local host = NewHost(proxy)
    -- HELPFUL only, and on the player, which is what lets includeSpellIDs work
    -- at all: identity filtering is permitted for a helpful aura on an
    -- assistable unit, and the player always is -- regardless of whether the
    -- spell itself is secret.
    local ok, slot = pcall(c.AddAuraSlot, c, "sqactive" .. tostring(cdID), FILTERS.player[1], {
        candidateFilters = { includeSpellIDs = ids },
        initializeFrame = MakeInitializer(st, host, false),
    })
    if not (ok and slot) then
        Note(ok and ("AddAuraSlot returned nothing for active " .. tostring(cdID)) or slot)
        pcall(c.Hide, c)
        return nil
    end

    -- Unit LAST: before the slot exists, UNIT_AURA is never registered.
    local okU, err = pcall(function()
        c:SetUnit("player")
        c:SetEnabled(true)
        c:Show()
        c:UpdateAllAuras()
    end)
    if not okU then
        Note(err)
        pcall(c.SetEnabled, c, false)
        pcall(c.Hide, c)
        return nil
    end

    st.container, st.host, st.proxy = c, host, proxy
    return st
end

--- wanted: [cooldownID] = { proxy = frame, groupData = table, entry = registry entry }
function Native:SyncActiveOverlays(wanted)
    if InCombatLockdown() then return end
    for cdID in pairs(activeOverlays) do
        if not (wanted and wanted[cdID]) then ReleaseOverlay(cdID) end
    end
    if not (wanted and self:IsEnabled()) then return end

    for cdID, w in pairs(wanted) do
        -- One overlay at a time, each pcall'd: a failure drops that icon back
        -- to showing only its cooldown rather than escaping into Reconcile.
        local ok, err = pcall(function()
            local ids, idSig = AuraSpellIDs(w.entry)
            if idSig == "" then ReleaseOverlay(cdID) return end

            -- Rebuild only when WHAT is shown changes, or when the proxy itself
            -- has been replaced -- the button is bound to a host anchored to
            -- that exact frame, so a new proxy needs a new overlay. Every
            -- rebuild strands its container for the session, so this matters.
            local st = activeOverlays[cdID]
            if st and (st.sig ~= idSig or st.proxy ~= w.proxy) then
                ReleaseOverlay(cdID)
                st = nil
            end
            if not st then
                st = BuildOverlay(cdID, w.proxy, w.groupData, ids)
                if not st then return end
                st.sig = idSig
                activeOverlays[cdID] = st
            end

            st.groupData = w.groupData
            local styleSig = StyleSignature(w.groupData)
            if styleSig ~= st.styleSig then
                for _, d in pairs(st.buttons) do Style(d, w.groupData) end
                st.styleSig = styleSig
            end
        end)
        if not ok then
            Note(err)
            ReleaseOverlay(cdID)
        end
    end

    if next(activeOverlays) then EnsureTicker() end
end

function Native:ReleaseAllActiveOverlays()
    for cdID in pairs(activeOverlays) do ReleaseOverlay(cdID) end
end

-- ============================================================================
-- Entry points (all from Reconcile, which only runs out of combat)
-- ============================================================================

local function Release(groupName)
    local st = groups[groupName]
    if not st then return end
    Retire(st, groupName)
    st.sig, st.styleSig = nil, nil
    for _, cell in pairs(st.cells) do cell:Hide() end
end

-- nativeByGroup: [groupName] = { registry entry, ... } -- what Handles accepted.
function Native:SyncAll(nativeByGroup)
    if InCombatLockdown() then return end
    for groupName in pairs(groups) do
        if not nativeByGroup[groupName] then Release(groupName) end
    end
    if not self:IsEnabled() then return end

    local specData = SH.GetSpecData and SH.GetSpecData()
    for groupName, entries in pairs(nativeByGroup) do
        local g = cdm.groups[groupName]
        local gd = specData and specData.groups[groupName]
        -- One group at a time, each pcall'd: a failure is recorded for
        -- /sq cdmnative and that group falls back to Blizzard's frames, instead
        -- of an error escaping into Reconcile and stopping the whole pass.
        local ok, err = pcall(function()
        if g and g.container and gd then
            table.sort(entries, function(a, b) return a.cooldownID < b.cooldownID end)
            local st = groups[groupName]
            if not st then
                st = { cells = {}, active = {}, containers = {},
                       buttons = setmetatable({}, { __mode = "k" }) }
                groups[groupName] = st
            end
            st.groupData = gd

            -- Rebuild only when WHAT is shown changes. Sizes need nothing: the
            -- buttons follow their hosts, which follow the cells the layout
            -- sizes. Style changes only restyle, because every rebuild strands
            -- its containers for the session (WoW never frees a frame).
            local sig = StructureSignature(gd, entries)
            if sig ~= st.sig then
                Build(groupName, st, entries, g.container)
                st.sig = sig
                st.styleSig = nil
            end

            local styleSig = StyleSignature(gd)
            if styleSig ~= st.styleSig then
                for _, d in pairs(st.buttons) do Style(d, gd) end
                st.styleSig = styleSig
            end

            for _, c in ipairs(st.containers) do
                c:SetAlpha(gd.alpha or SH.DEFAULT_ALPHA or 1)
            end
        end
        end)
        if not ok then
            Note(err)
            Release(groupName)
        end
    end
end

-- The group frame was hidden (nothing up), and a hidden container stops
-- listening. Re-scan the moment it is shown again so a buff that came up
-- meanwhile appears at once rather than at the next ticker pass.
function Native:Refresh(groupName)
    local st = groups[groupName]
    if not st then return end
    for _, c in ipairs(st.containers) do pcall(c.UpdateAllAuras, c) end
end

function Native:ReleaseAll()
    for groupName in pairs(groups) do Release(groupName) end
    self:ReleaseAllActiveOverlays()
end

-- /sq cdmnative -- unlisted; see CLAUDE.md.
local function PrintDiagnosticsBody(self)
    local s = BH.settings or {}
    print("|cff00ccffSquizzumables|r native buffs (Draw Buffs Ourselves):")
    print(("  setting: %s   proxy-icon override: %s   Blizzard_AuraContainer loaded: %s")
        :format(tostring(s.cdmNativeBuffs ~= false), tostring(s.cdmProxyBuffIcons and true or false),
            tostring(C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(AURA_ADDON))))
    print(("  available: %s   enabled: %s   last error: %s")
        :format(tostring(availability), tostring(self:IsEnabled()), self.lastError or "none"))
    local any = false
    for groupName, st in pairs(groups) do
        any = true
        local active, visible = 0, 0
        for _ in pairs(st.active) do active = active + 1 end
        for _, c in ipairs(st.containers) do if c:IsVisible() then visible = visible + 1 end end
        -- buttons: how many times the engine ran our initializer. Slots but no
        -- buttons means the engine never created them; buttons but nothing on
        -- screen points at sizing or anchoring instead.
        print(("  [%s] slots: %d   containers: %d (%d visible)   buttons: %d   built: %s")
            :format(groupName, active, #st.containers, visible, st.buttonCount or 0,
                st.sig and "yes" or "no"))

        -- A container that is BUILT BUT NOT VISIBLE stops listening for aura
        -- events altogether -- the engine's ShouldRegisterForDynamicEvents is
        -- IsVisible() and IsEnabled() -- and EnsureTicker's refresh skips it
        -- for the same reason. The row then only redraws when something else
        -- happens to poke it, which reads in game as icons that flicker while
        -- you move and vanish while you stand still.
        --
        -- The container itself is never the culprit (it is SetAllPoints to its
        -- group frame and explicitly Show()n), so walk UP and name the first
        -- ancestor that is hidden or has no size. These frames are anonymous,
        -- so the chain is the only way to identify which one.
        for i, c in ipairs(st.containers) do
            if not c:IsVisible() then
                local chain, f, depth = {}, c, 0
                while f and depth < 8 do
                    local okS, shown = pcall(f.IsShown, f)
                    local okW, w = pcall(f.GetWidth, f)
                    local okH, h = pcall(f.GetHeight, f)
                    -- Sizes can come back SECRET (a frame sized off aura
                    -- layout), and math.floor on a secret throws -- that took
                    -- this whole command down mid-print (2026-09-22).
                    local function Readable(ok, v)
                        return ok and v ~= nil and not BH.Secrets.IsSecret(v)
                    end
                    ---@param v any
                    local function SizeText(ok, v)
                        if not Readable(ok, v) or type(v) ~= "number" then return "?" end
                        return tostring(math.floor(v))
                    end
                    chain[#chain + 1] = ("%s[shown=%s %sx%s]"):format(
                        (f.GetName and f:GetName()) or "<anon>",
                        Readable(okS, shown) and tostring(shown) or "?",
                        SizeText(okW, w), SizeText(okH, h))
                    local okP, parent = pcall(f.GetParent, f)
                    f = okP and parent or nil
                    depth = depth + 1
                end
                print(("    container %d NOT visible: %s"):format(i, table.concat(chain, " < ")))
            end
        end
    end
    if not any then print("  no group has been built yet") end

    -- Every item on Blizzard's buff bars that is NOT drawn by us, by name. The
    -- first thing to read when some buffs look like ours and some Blizzard's.
    for _, viewerName in ipairs({ "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
        local viewer = _G[viewerName]
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            local total, ours, missing = 0, 0, {}
            if ok and children then
                for _, child in ipairs(children) do
                    local cdID = child and child.cooldownID
                    if cdID then
                        total = total + 1
                        if nativeCooldowns[cdID] then
                            ours = ours + 1
                        else
                            local sid = cdm.SpellIDForCooldown and cdm.SpellIDForCooldown(cdID)
                            local name = sid and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
                            missing[#missing + 1] = ("%s (%s)")
                                :format(BH.Secrets.SafeString(name, "?"), tostring(cdID))
                        end
                    end
                end
            end
            print(("  %s: %d items, %d drawn by us"):format(viewerName, total, ours))
            if #missing > 0 then
                print("    still Blizzard's: " .. table.concat(missing, ", "))
            end
        end
    end

    -- "Show While Active" overlays: one per Essential/Utility icon that asked
    -- for one. No line for an icon means no overlay was built for it at all.
    print("  Show While Active overlays:")
    local anyOverlay = false
    for cdID, st in pairs(activeOverlays) do
        anyOverlay = true
        local okV, vis = pcall(function() return st.container and st.container:IsVisible() end)
        print(("    cd %s: ids {%s}   container visible: %s   buttons: %d")
            :format(tostring(cdID), tostring(st.sig),
                (okV and not BH.Secrets.IsSecret(vis)) and tostring(vis) or "?",
                st.buttonCount or 0))
    end
    if not anyOverlay then print("    none built") end

    -- Equip-slot entries (trinkets): what discovery handed us, and what the
    -- running check reads. The aura IDs are what an overlay matches the buff by.
    print("  Equip-slot entries:")
    local anyEquip = false
    for cdID, e in pairs(cdm.registry or {}) do
        if e.equipSlot then
            anyEquip = true
            local proxy = cdm.proxyFrames and cdm.proxyFrames[cdID]
            local item = cdm.viewerItems and cdm.viewerItems[cdID]
            local auraFlag = item and item.cooldownUseAuraDisplayTime
            print(("    cd %s: slot %s  type %s  spellID %s  selfAura %s  auraIDs {%s}")
                :format(tostring(cdID), tostring(e.equipSlot), tostring(e.viewerType),
                    tostring(e.spellID), tostring(e.selfAura),
                    table.concat(e.auraIDs or {}, ",")))
            print(("      proxy: %s  showActive: %s  activeNow: %s  Blizzard aura flag: %s")
                :format(proxy and "yes" or "no",
                    tostring(proxy and proxy._sqShowActiveBuff),
                    tostring(proxy and proxy._sqActiveNow),
                    BH.Secrets.IsSecret(auraFlag) and "secret" or tostring(auraFlag)))
        end
    end
    if not anyEquip then print("    none") end
end

-- Wrapped so a failure part-way is reported rather than silently cutting the
-- output short, and ends with a terminator so a truncated dump is obvious.
function Native:PrintDiagnostics()
    local ok, err = pcall(PrintDiagnosticsBody, self)
    if not ok then print("  |cffff4444diagnostics failed:|r " .. tostring(err)) end
    print("  -- end of cdmnative --")
end
