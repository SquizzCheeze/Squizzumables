-- Cooldowns/RotationIcon.lua
-- The rotation helper's suggestion on an icon of our own (2.2, first step of
-- the "rotation helper plus" feature; design notes in CLAUDE.md).
--
-- What it shows is Blizzard's choice -- C_AssistedCombat.GetNextCastSpell,
-- polled the way Blizzard's own action-bar highlight polls it, at the
-- assistedCombatIconUpdateRate CVar. Nothing here decides what to cast.
--
-- Everything drawn on it was measured readable in combat under a restriction
-- before this was written (/sq rotprobe, the Labyrinth, 2026-10-19): the next
-- spell, IsSpellUsable, IsSpellInRange and IsSpellOverlayed all came back
-- plain. The cooldown itself is secret, so the swipe is drawn from the
-- DURATION OBJECT (SetCooldownFromDurationObject) and never read -- the same
-- route as the CDM proxies. Each read still goes through BH.Secrets: a
-- restriction we have not measured (a boss, a key) must degrade to "no tint",
-- never to an error.
--
-- Placed like every other movable frame: POSITION_PAIRS ("rotationFrame",
-- "rotationPosition") generates Save/LoadRotationPosition, MOVABLE_FRAMES puts
-- it in Unlock Frames / Edit Mode, and the Cooldowns > Rotation Helper page is
-- described below.

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

-----------------------------------------------------------------------
-- The frame
-----------------------------------------------------------------------

function BH:BuildRotationFrame()
    if self.rotationFrame then return self.rotationFrame end

    local f = CreateFrame("Frame", "SquizzumablesRotationIcon", UIParent)
    f:SetSize(56, 56)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self2)
        if InCombatLockdown() then return end
        BH:GridStartMoving(self2)
    end)
    f:SetScript("OnDragStop", function(self2)
        BH:GridStopMoving(self2)
        BH:SaveRotationPosition()
    end)
    f:Hide()

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

    self.rotationFrame = f
    return f
end

-----------------------------------------------------------------------
-- Updating
-----------------------------------------------------------------------

local shownSpell        -- the spell on the icon now
local cooldownDirty = true
local glowing = false

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

local function SetGlow(f, on)
    on = on and true or false
    if on == glowing then return end
    glowing = on
    ns.Glow.Set(f, on)
end

-- Red out of range; grey when it can't be cast; blue when only short on
-- resources -- the action bars' own conventions.
local function Tint(f, s, spellID)
    local icon = f.icon
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
    icon:SetVertexColor(r, g, b)
    icon:SetDesaturated(desat)
end

local function UpdateCooldown(f, s, spellID)
    if s.rotationSwipe == false or not spellID then
        f.cooldown:Clear()
        return
    end
    local dur = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(spellID)
    if dur then
        f.cooldown:SetCooldownFromDurationObject(dur)
    else
        f.cooldown:Clear()
    end
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

    -- Unlock Frames: a placeholder, so it can be placed with no suggestion.
    if not spellID then
        if shownSpell ~= false then
            shownSpell = false
            f.icon:SetTexture(PLACEHOLDER_ICON)
            f.icon:SetVertexColor(1, 1, 1)
            f.icon:SetDesaturated(false)
            f.cooldown:Clear()
            SetGlow(f, false)
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
        UpdateCooldown(f, s, spellID)
    end
    Tint(f, s, spellID)

    if s.rotationProcGlow ~= false then
        local ok, on = pcall(C_SpellActivationOverlay.IsSpellOverlayed, spellID)
        SetGlow(f, ok and Plain(on) == true)
    else
        SetGlow(f, false)
    end
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

--- Size, position and the driver, from settings. The options page and login.
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
    shownSpell, cooldownDirty = nil, true
    wait = 0
    driver:Show()
    Rotation.Update()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("SPELL_UPDATE_COOLDOWN")
ev:RegisterEvent("SPELL_UPDATE_CHARGES")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(2, function() BH:ApplyRotation() end)
        return
    end
    cooldownDirty = true
end)

-----------------------------------------------------------------------
-- Options: Cooldowns > Rotation Helper
-----------------------------------------------------------------------

local VISIBILITY = {
    {text = "In combat or with an enemy targeted", value = "target"},
    {text = "Only in combat", value = "combat"},
    {text = "Always", value = "always"},
}

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
            { type = "header", label = "ON THE ICON" },
            { key = "rotationSwipe", type = "check", default = true,
              label = "Cooldown Swipe",
              tip = "Draws the global cooldown and the spell's own cooldown over the icon." },
            { key = "rotationRangeTint", type = "check", default = true,
              label = "Red When Out of Range",
              tip = "Tints the icon red while your target is out of range of the suggested spell." },
            { key = "rotationDimUnusable", type = "check", default = true,
              label = "Dim When Unusable",
              tip = "Greys the icon while the spell can't be cast, and tints it blue when you are only short "
                .. "on resources -- the same as the action bars." },
            { key = "rotationProcGlow", type = "check", default = true,
              label = "Glow On Procs",
              tip = "Glows when the suggested spell is lit up by a proc, as it would on your action bars." },
        } },
    },
})

function BH:BuildRotationTab(parent)
    ns.Settings.Build(ROTATION, parent)
end
