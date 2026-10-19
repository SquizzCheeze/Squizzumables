-- Cooldowns/RotationIcon.lua
-- The rotation helper's suggestion on an icon of our own, plus a "ready now"
-- row of the player's chosen spells beside it (2.2; design notes in CLAUDE.md).
--
-- MAIN ICON: Blizzard's choice -- C_AssistedCombat.GetNextCastSpell, polled
-- the way Blizzard's own action-bar highlight polls it, at the
-- assistedCombatIconUpdateRate CVar. Nothing here decides what to cast.
-- Confirmed in game 2026-10-19 (matches the bars, no swipe flicker, procs).
--
-- READY NOW ROW: the player's own list, per spec, in their order. Blizzard
-- gives no second or third pick and the cooldowns are secret, so the row is
-- not a queue: each icon FADES while its spell is cooling, and the fade is
-- decided engine-side -- the cooldown's duration object is evaluated against a
-- step curve and the (secret) result handed straight to SetAlpha, which
-- /sq rotprobe measured as accepted under a restriction.
--
-- Everything else drawn here was measured readable in combat under a
-- restriction (/sq rotprobe, the Labyrinth, 2026-10-19): IsSpellUsable,
-- IsSpellInRange, IsSpellOverlayed. Each read still goes through Plain(): a
-- restriction we have not measured (a boss, a key) must degrade to "no tint",
-- never to an error.
--
-- Placed like every other movable frame: POSITION_PAIRS ("rotationFrame",
-- "rotationPosition") generates Save/LoadRotationPosition, MOVABLE_FRAMES puts
-- it in Unlock Frames / Edit Mode. The row is a CHILD of the main icon, so it
-- moves, shows and hides with it and needs no position of its own.

local _, ns = ...
local BH = ns.BH
if not BH then return end

local Rotation = {}
BH.Rotation = Rotation

local PLACEHOLDER_ICON = 134400   -- question mark, for Unlock Frames
local MIN_INTERVAL = 0.05         -- the CVar allows 0 ("every frame")
local IDLE_INTERVAL = 0.25        -- hidden and not in combat: nothing to chase

local function IsSecret(v) return BH.Secrets.IsSecret(v) end

-- A value we may act on: not secret, else nil.
local function Plain(v)
    if IsSecret(v) then return nil end
    return v
end

-- A talent can replace a spell with another (a different ID); the cooldown,
-- usability and proc live on the replacement, and asking the base returns
-- nothing (the CDM's LiveSpellID note).
local function LiveSpellID(id)
    local ok, live = pcall(C_Spell.GetOverrideSpell, id)
    live = ok and Plain(live)
    return (type(live) == "number" and live > 0) and live or id
end

-----------------------------------------------------------------------
-- An icon: shared by the main icon and the row
-----------------------------------------------------------------------

-- Dragging any icon moves the main one, which carries the row.
local function StartDrag()
    if InCombatLockdown() then return end
    BH:GridStartMoving(BH.rotationFrame)
end

local function StopDrag()
    BH:GridStopMoving(BH.rotationFrame)
    BH:SaveRotationPosition()
end

local function NewIcon(parent, name)
    local f = CreateFrame("Frame", name, parent)
    -- A 1px black edge behind the icon, as on the CDM icons.
    local edge = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    edge:SetAllPoints()
    edge:SetColorTexture(0, 0, 0, 1)

    local icon = f:CreateTexture(nil, "BACKGROUND")
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon = icon

    local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    cd:SetAllPoints(icon)
    cd:SetDrawEdge(false)
    cd:SetHideCountdownNumbers(true)
    f.cooldown = cd

    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", StartDrag)
    f:SetScript("OnDragStop", StopDrag)
    return f
end

local function SetGlow(f, on)
    on = on and true or false
    if on == (f.sqRotGlow or false) then return end
    f.sqRotGlow = on
    ns.Glow.Set(f, on)
end

-- Red out of range; grey when it can't be cast; blue when only short on
-- resources -- the action bars' own conventions.
local function Tint(f, s, spellID)
    local r, g, b, desat = 1, 1, 1, false
    if s.rotationDimUnusable ~= false then
        local ok, usable, noPower = pcall(C_Spell.IsSpellUsable, spellID)
        if not ok then usable, noPower = nil, nil end   -- unknown, not unusable
        usable, noPower = Plain(usable), Plain(noPower)
        if usable == false then
            if noPower then
                r, g, b = 0.5, 0.5, 1
            else
                r, g, b, desat = 0.6, 0.6, 0.6, true
            end
        end
    end
    if s.rotationRangeTint ~= false and UnitExists("target") then
        local ok, inRange = pcall(C_Spell.IsSpellInRange, spellID, "target")
        if ok and Plain(inRange) == false then r, g, b = 1, 0.3, 0.3 end
    end
    f.icon:SetVertexColor(r, g, b)
    f.icon:SetDesaturated(desat)
end

local function ProcGlow(f, s, spellID)
    if s.rotationProcGlow == false or not spellID then
        SetGlow(f, false)
        return
    end
    local ok, on = pcall(C_SpellActivationOverlay.IsSpellOverlayed, spellID)
    SetGlow(f, ok and Plain(on) == true)
end

local function UpdateCooldown(f, spellID, show, ignoreGCD)
    if not show or not spellID then
        f.cooldown:Clear()
        return
    end
    local dur = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(spellID, ignoreGCD)
    if dur then
        f.cooldown:SetCooldownFromDurationObject(dur)
    else
        f.cooldown:Clear()
    end
end

local function ResetLook(f)
    f.icon:SetVertexColor(1, 1, 1)
    f.icon:SetDesaturated(false)
    f.icon:SetAlpha(1)
    f.cooldown:SetAlpha(1)
    f.cooldown:Clear()
    SetGlow(f, false)
end

-----------------------------------------------------------------------
-- The main icon
-----------------------------------------------------------------------

function BH:BuildRotationFrame()
    if self.rotationFrame then return self.rotationFrame end

    local f = NewIcon(UIParent, "SquizzumablesRotationIcon")
    f:SetSize(56, 56)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:Hide()

    -- The row's host: a child, so it moves and hides with the main icon.
    f.row = CreateFrame("Frame", nil, f)
    f.row:SetSize(1, 1)
    f.row:SetPoint("CENTER")
    f.row.icons = {}

    self.rotationFrame = f
    return f
end

-----------------------------------------------------------------------
-- The "ready now" row
-----------------------------------------------------------------------

local readySpells = {}   -- this spec's list, resolved to spell IDs, in order
local unknownTokens = {} -- what could not be resolved, for the options print
local readyCurve         -- remaining cooldown -> alpha (1 ready, dim cooling)

local function ParseSpells(text)
    local ids, unknown = {}, {}
    for token in (text or ""):gmatch("[^,;\n]+") do
        token = strtrim(token)
        if token ~= "" then
            local id = tonumber(token)
            if not id then
                local ok, info = pcall(C_Spell.GetSpellInfo, token)
                id = ok and info and Plain(info.spellID)
            end
            if id and C_Spell.GetSpellTexture(id) then
                ids[#ids + 1] = id
            else
                unknown[#unknown + 1] = token
            end
        end
    end
    return ids, unknown
end

-- This spec's list, from settings. Called on apply and on spec change.
local function LoadReadySpells()
    local map = (BH.settings or {}).rotationReadySpells
    local text = type(map) == "table" and map[ns.Settings.SpecKey()] or ""
    readySpells, unknownTokens = ParseSpells(text)
end

local function BuildReadyCurve(s)
    if not (C_CurveUtil and C_CurveUtil.CreateCurve) then
        readyCurve = nil
        return
    end
    local dim = s.rotationReadyDimAlpha or 0.3
    readyCurve = C_CurveUtil.CreateCurve()
    readyCurve:SetType(Enum.LuaCurveType.Step)
    readyCurve:AddPoint(0, 1)
    readyCurve:AddPoint(0.05, dim)
    readyCurve:AddPoint(100000, dim)
end

-- Icon i's anchor, for each side the row can sit on.
local function PlaceRowIcon(icon, f, side, i, size, gap)
    local along = (i - 1) * (size + gap)
    if side == "LEFT" then
        icon:SetPoint("RIGHT", f, "LEFT", -(gap + along), 0)
    elseif side == "BELOW" then
        icon:SetPoint("TOPLEFT", f, "BOTTOMLEFT", along, -gap)
    elseif side == "ABOVE" then
        icon:SetPoint("BOTTOMLEFT", f, "TOPLEFT", along, gap)
    else
        icon:SetPoint("LEFT", f, "RIGHT", gap + along, 0)
    end
end

-- How many placeholders Edit Mode shows while this spec's list is empty, so
-- the row can be placed (and seen to exist) before any spell is chosen. The
-- first version drew nothing at all until the list was filled, which read as
-- "the row is broken" (user report 2026-10-19).
local EMPTY_PREVIEW = 3

local function LayoutRow(f, s)
    local row = f.row
    local n = #readySpells
    if n == 0 then n = EMPTY_PREVIEW end
    local size = s.rotationReadySize or 40
    local gap = s.rotationReadySpacing or 4
    for i = #row.icons + 1, n do row.icons[i] = NewIcon(row) end
    for i, icon in ipairs(row.icons) do
        icon:ClearAllPoints()
        if i <= n then
            icon:SetSize(size, size)
            ns.Glow.Resize(icon)
            PlaceRowIcon(icon, f, s.rotationReadySide, i, size, gap)
            icon.spellID, icon.liveID = readySpells[i], nil
            icon.icon:SetTexture(readySpells[i] and C_Spell.GetSpellTexture(LiveSpellID(readySpells[i]))
                or PLACEHOLDER_ICON)
            ResetLook(icon)
            icon.cdDirty = true
            icon:Show()
        else
            icon.spellID = nil
            SetGlow(icon, false)
            icon:Hide()
        end
    end
end

local function UpdateRow(f, s)
    local row = f.row
    if not s.rotationReadyEnabled then
        row:Hide()
        return
    end
    -- An empty list shows only in Edit Mode, as placeholders (LayoutRow).
    local count = #readySpells
    if count == 0 then
        if not BH.unlockMode then
            row:Hide()
            return
        end
        count = EMPTY_PREVIEW
    end
    row:Show()
    local ignoreGCD = s.rotationReadyIgnoreGCD ~= false
    for i = 1, count do
        local icon = row.icons[i]
        icon:EnableMouse(BH.unlockMode and true or false)
        if BH.unlockMode then
            ResetLook(icon)
        else
            local id = LiveSpellID(icon.spellID)
            if icon.cdDirty or id ~= icon.liveID then
                icon.cdDirty, icon.liveID = false, id
                icon.icon:SetTexture(C_Spell.GetSpellTexture(id) or PLACEHOLDER_ICON)
                UpdateCooldown(icon, id, s.rotationReadySwipe ~= false, ignoreGCD)
            end
            -- The fade: the cooldown's remaining time through the curve,
            -- straight to SetAlpha. Never read, never compared.
            local alpha = 1
            if readyCurve and C_Spell.GetSpellCooldownDuration then
                local dur = C_Spell.GetSpellCooldownDuration(id, ignoreGCD)
                if dur then
                    local ok, result = pcall(dur.EvaluateRemainingDuration, dur, readyCurve)
                    if ok and (IsSecret(result) or result ~= nil) then alpha = result end
                end
            end
            icon.icon:SetAlpha(alpha)
            icon.cooldown:SetAlpha(alpha)
            Tint(icon, s, id)
            ProcGlow(icon, s, id)
        end
    end
end

-----------------------------------------------------------------------
-- Updating
-----------------------------------------------------------------------

local shownSpell        -- the spell on the main icon now
local cooldownDirty = true

local function ShouldShow(s, spellID)
    if BH.unlockMode then return true end
    if not spellID then return false end
    local mode = s.rotationVisibility or "target"
    if mode == "always" then return true end
    if InCombatLockdown() then return true end
    if mode == "combat" then return false end
    -- "target": in combat, or with something attackable targeted.
    return UnitExists("target") and UnitCanAttack("player", "target")
        and not UnitIsDeadOrGhost("target") and true or false
end

function Rotation.Update()
    local f = BH.rotationFrame
    if not f then return end
    local s = BH.settings or {}

    -- Mouse only while being positioned, re-asserted every pass (see the
    -- same note in Core/TargetDistance.lua: leaving unlock mode does not
    -- restore it for frames outside BH.REMINDERS).
    f:EnableMouse(BH.unlockMode and true or false)

    if not s.rotationEnabled then
        f:Hide()
        return
    end

    local spellID
    if not BH.unlockMode then
        local ok, id = pcall(C_AssistedCombat.GetNextCastSpell, false)
        if ok then spellID = Plain(id) end
    end

    if not ShouldShow(s, spellID) then
        f:Hide()
        SetGlow(f, false)
        return
    end
    f:Show()
    UpdateRow(f, s)

    -- Unlock Frames: a placeholder, so it can be placed with no suggestion.
    if not spellID then
        if shownSpell ~= false then
            shownSpell = false
            f.icon:SetTexture(PLACEHOLDER_ICON)
            ResetLook(f)
        end
        return
    end

    if spellID ~= shownSpell then
        shownSpell = spellID
        f.icon:SetTexture(C_Spell.GetSpellTexture(spellID) or PLACEHOLDER_ICON)
        cooldownDirty = true
    end
    if cooldownDirty then
        cooldownDirty = false
        UpdateCooldown(f, spellID, s.rotationSwipe ~= false, false)
    end
    Tint(f, s, spellID)
    ProcGlow(f, s, spellID)
end

-- One driver, at Blizzard's own rate while it matters.
local driver = CreateFrame("Frame")
driver:Hide()
local wait = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    wait = wait - elapsed
    if wait > 0 then return end
    Rotation.Update()
    local f = BH.rotationFrame
    if (f and f:IsShown()) or InCombatLockdown() then
        local rate = tonumber(GetCVar("assistedCombatIconUpdateRate")) or 0.1
        wait = math.max(MIN_INTERVAL, rate)
    else
        wait = IDLE_INTERVAL
    end
end)

--- Size, position, the row and the driver, from settings. The options page,
--- login and a spec change.
function BH:ApplyRotation()
    local s = self.settings or {}
    if not s.rotationEnabled then
        driver:Hide()
        if self.rotationFrame then
            SetGlow(self.rotationFrame, false)
            self.rotationFrame:Hide()
        end
        return
    end
    local f = self:BuildRotationFrame()
    self:LoadRotationPosition()
    local size = s.rotationSize or 56
    f:SetSize(size, size)
    ns.Glow.Resize(f)
    LoadReadySpells()
    BuildReadyCurve(s)
    LayoutRow(f, s)
    shownSpell, cooldownDirty = nil, true
    wait = 0
    driver:Show()
    Rotation.Update()
end

-- Fills this spec's list from the rotation helper's spells that have a real
-- cooldown or charges -- the fillers are always ready, so a row of them says
-- nothing. Out of combat only: the base cooldown is read, not drawn.
local function FillFromHelper()
    if InCombatLockdown() then
        print("Squizzumables: fill the Ready Now list out of combat.")
        return
    end
    local ids = {}
    local ok, list = pcall(C_AssistedCombat.GetRotationSpells)
    for _, id in ipairs(ok and type(list) == "table" and list or {}) do
        id = Plain(id)
        if id then
            -- GetSpellBaseCooldown is a legacy global, missing from the
            -- generated docs but still live (BliZzi_Interrupts uses it on
            -- 12.x). If it is ever gone, list everything rather than nothing.
            local okB, cdMS = false, nil
            if GetSpellBaseCooldown then okB, cdMS = pcall(GetSpellBaseCooldown, id) end
            cdMS = okB and Plain(cdMS) or nil
            local okC, charges = pcall(C_Spell.GetSpellCharges, id)
            local maxCharges = okC and charges and Plain(charges.maxCharges)
            if not GetSpellBaseCooldown or (cdMS and cdMS > 1500) or (maxCharges and maxCharges > 1) then
                ids[#ids + 1] = tostring(id)
            end
        end
    end
    if #ids == 0 then
        print("Squizzumables: the rotation helper has no spells with cooldowns for this spec.")
        return
    end
    local s = BH.settings
    local map = type(s.rotationReadySpells) == "table" and s.rotationReadySpells or {}
    map[ns.Settings.SpecKey()] = table.concat(ids, ", ")
    s.rotationReadySpells = map
    BH:SaveSettings()
    BH:ApplyRotation()
    ns.Rows.RefreshAll()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("SPELL_UPDATE_COOLDOWN")
ev:RegisterEvent("SPELL_UPDATE_CHARGES")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(2, function() BH:ApplyRotation() end)
        return
    end
    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        if unit and unit ~= "player" then return end
        -- The new spec's list, and the options row showing it.
        BH:ApplyRotation()
        ns.Rows.RefreshAll()
        return
    end
    cooldownDirty = true
    local f = BH.rotationFrame
    for _, icon in ipairs(f and f.row.icons or {}) do icon.cdDirty = true end
end)

-----------------------------------------------------------------------
-- Options: Cooldowns > Rotation Helper
-----------------------------------------------------------------------

local VISIBILITY = {
    {text = "In combat or with an enemy targeted", value = "target"},
    {text = "Only in combat", value = "combat"},
    {text = "Always", value = "always"},
}

local SIDES = {
    {text = "Right of the icon", value = "RIGHT"},
    {text = "Left of the icon", value = "LEFT"},
    {text = "Below the icon", value = "BELOW"},
    {text = "Above the icon", value = "ABOVE"},
}

local function ReadyOn(s) return s.rotationReadyEnabled end

local ROTATION = ns.Settings.Describe({
    master = "rotationEnabled",
    apply = function() BH:ApplyRotation() end,
    pages = {
        { key = "icon", label = "Main Icon", rows = {
            { type = "header", label = "ROTATION HELPER" },
            { key = "rotationEnabled", type = "check", default = false,
              label = "Show Rotation Icon",
              tip = "Shows the spell Blizzard's rotation helper suggests next, on an icon you can put "
                .. "anywhere with Unlock Frames. The choice is Blizzard's; this shows it where you want it." },
            { type = "text",
              label = "Blizzard's rotation helper only ever suggests one spell at a time, so this is one icon. "
                .. "The suggestion itself comes from the game's Assisted Combat (Single-Button Assistant)." },
            { type = "divider" },
            { key = "rotationSize", type = "slider", default = 56, min = 24, max = 128, step = 2,
              label = "Icon Size", tip = "Width and height of the icon, in pixels." },
            { key = "rotationVisibility", type = "dropdown", default = "target", width = 240,
              items = VISIBILITY,
              label = "Show",
              tip = "When the icon is on screen. It is always hidden when the game has nothing to suggest." },
            { type = "divider" },
            { type = "header", label = "ON THE ICONS" },
            { key = "rotationSwipe", type = "check", default = true,
              label = "Cooldown Swipe",
              tip = "Draws the global cooldown and the spell's own cooldown over the main icon." },
            { key = "rotationRangeTint", type = "check", default = true,
              label = "Red When Out of Range",
              tip = "Tints an icon red while your target is out of range of its spell." },
            { key = "rotationDimUnusable", type = "check", default = true,
              label = "Dim When Unusable",
              tip = "Greys an icon while its spell can't be cast, and tints it blue when you are only short "
                .. "on resources -- the same as the action bars." },
            { key = "rotationProcGlow", type = "check", default = true,
              label = "Glow On Procs",
              tip = "Glows when a spell is lit up by a proc, as it would on your action bars." },
        } },
        { key = "ready", label = "Ready Now", rows = {
            { type = "header", label = "READY NOW ROW" },
            { key = "rotationReadyEnabled", type = "check", default = false,
              label = "Show Ready Now Row",
              tip = "A row of spells you choose beside the main icon. Each one is bright when it is ready and "
                .. "fades while it is on cooldown.",
              apply = function(on)
                  local map = BH.settings.rotationReadySpells
                  local text = type(map) == "table" and map[ns.Settings.SpecKey()] or ""
                  if on and strtrim(text) == "" then
                      print("Squizzumables: the Ready Now row has no spells for this spec yet -- press "
                          .. "Fill From Rotation Helper, or type spell names below.")
                  end
              end },
            { type = "text",
              label = "Not a queue: the game gives addons only the one suggestion, and hides the cooldowns "
                .. "themselves in combat. The row shows which of your spells are ready, in the order you list "
                .. "them; the game works out the fading." },
            { key = "rotationReadySpells", type = "editbox", perSpec = true, default = {},
              label = "Spells (this spec)",
              tip = "Spell IDs or names, separated by commas, in the order you want them. Each spec has its "
                .. "own list.",
              when = ReadyOn,
              apply = function()
                  LoadReadySpells()
                  if #unknownTokens > 0 then
                      print("Squizzumables: Rotation Helper couldn't find: " .. table.concat(unknownTokens, ", "))
                  end
              end },
            { type = "button", label = "Fill From Rotation Helper", width = 200, height = 24,
              tip = "Replaces this spec's list with the rotation helper's spells that have a cooldown of their "
                .. "own or charges. Edit it afterwards to taste.",
              onClick = FillFromHelper },
            { type = "divider" },
            { key = "rotationReadySide", type = "dropdown", default = "RIGHT", width = 200,
              items = SIDES, label = "Position", tip = "Which side of the main icon the row sits on.",
              when = ReadyOn },
            { key = "rotationReadySize", type = "slider", default = 40, min = 16, max = 96, step = 2,
              label = "Icon Size", tip = "Width and height of each icon in the row, in pixels.",
              when = ReadyOn },
            { key = "rotationReadySpacing", type = "slider", default = 4, min = 0, max = 20, step = 1,
              label = "Spacing", tip = "Gap between the icons, and between the row and the main icon.",
              when = ReadyOn },
            { key = "rotationReadyDimAlpha", type = "slider", default = 0.3, scale = 100,
              min = 0, max = 100, step = 5,
              label = "Opacity While Cooling",
              tip = "How visible an icon stays while its spell is on cooldown, as a percentage. 0 hides it "
                .. "until it is ready.",
              when = ReadyOn },
            { key = "rotationReadySwipe", type = "check", default = true,
              label = "Cooldown Swipe On The Row",
              tip = "Draws each spell's cooldown over its icon in the row.",
              when = ReadyOn },
            { key = "rotationReadyIgnoreGCD", type = "check", default = true,
              label = "Ignore the Global Cooldown",
              tip = "Leaves the global cooldown out of the row, so casting anything doesn't fade every icon "
                .. "for a moment.",
              when = ReadyOn },
        } },
    },
})

function BH:BuildRotationTab(parent)
    ns.Settings.Build(ROTATION, parent)
end
