-- Alerts/Kelerts.lua
-- Kelerts (the "Just For Kel" alerts): the alert display frame, its saved
-- position, and the UNIT_AURA side that decides when a configured alert fires.
--
-- Squizzumables_SpellAlerts.lua was split into Alerts/ in 2.0 phase 2, moved
-- unchanged. The four files load in order -- Kelerts, BuffSounds, CDMAlerts,
-- KelTab -- and each later file only uses names from earlier ones, handed
-- over through ns.Alerts (created here) and re-declared under the same names.

local addonName, ns = ...
local BH = ns.BH

local A = {}
ns.Alerts = A

-- ============================================================================
-- Alert display frame
-- ============================================================================

local KEL_MEDIA_PATH = "Interface\\AddOns\\Squizzumables\\Media\\"

local alertFrame
local alertTimer
local alertSoundTicker

local function EnsureAlertFrame()
    if alertFrame then return alertFrame end

    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(200, 200)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    -- Click-through except while positioning it.
    --
    -- This is a big image parked in the middle of the screen at the exact
    -- moment the fight is busiest, so anything it swallows is swallowed at the
    -- worst possible time. It used to take the mouse whenever "Lock alert image
    -- position" was unticked, which was the default, so out of the box the
    -- alert ate every click underneath it for as long as it was up.
    --
    -- Nothing is lost by never taking the mouse here. Outside Unlock Frames the
    -- frame is hidden unless an alert is firing, so the only window in which it
    -- could ever be dragged was during a real lust -- and Unlock Frames already
    -- positions it properly, with a labelled placeholder at the same size and
    -- anchor (BH:UpdateKelAlertUnlockState, which turns the mouse back on).
    f:EnableMouse(false)
    f:Hide()

    f:SetScript("OnMouseDown", function(self, btn)
        -- Only reachable in Unlock Frames: nothing else enables the mouse on
        -- this frame, so no lock check is needed here.
        if btn == "LeftButton" then
            BH:GridStartMoving(self)
        end
    end)
    f:SetScript("OnMouseUp", function(self)
        BH:GridStopMoving(self)
        BH:SaveKelAlertPosition()
    end)

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    f.tex = tex

    -- Animation state (set by ShowAlert when frameCount > 1)
    f.anim = {
        active     = false,
        baseName   = "",
        frameCount = 0,
        fps        = 10,
        loop       = true,
        current    = 1,
        elapsed    = 0,
    }

    f:SetScript("OnUpdate", function(self, dt)
        local a = self.anim
        if not a.active then return end
        a.elapsed = a.elapsed + dt
        local frameDur = 1 / math.max(1, a.fps)
        if a.elapsed >= frameDur then
            a.elapsed = a.elapsed - frameDur
            a.current = a.current + 1
            if a.current > a.frameCount then
                if a.loop then
                    a.current = 1
                else
                    -- played through once — stop on last frame
                    a.current = a.frameCount
                    a.active  = false
                    return
                end
            end
            local path = KEL_MEDIA_PATH .. a.baseName
                         .. string.format("_%03d", a.current) .. ".png"
            self.tex:SetTexture(path)
        end
    end)

    alertFrame = f
    BH.kelAlertFrame = f
    return f
end

-- Picks one random sound name from alert.randomSounds ([name] = true), or nil
-- if that pool is missing/empty (in which case ShowAlert falls back to
-- alert.sound unchanged). Chosen once per ShowAlert call, not re-rolled on
-- sound-loop repeats, so a single alert instance stays consistent.
local function PickRandomSound(alert)
    local pool = alert and alert.randomSounds
    if type(pool) ~= "table" then return nil end
    local names = {}
    for name, checked in pairs(pool) do
        if checked then table.insert(names, name) end
    end
    if #names == 0 then return nil end
    return names[math.random(#names)]
end

local function ShowAlert(alert)
    local f = EnsureAlertFrame()

    -- Stop any running animation
    f.anim.active = false

    local texBase = alert and alert.texture or ""
    local frames  = tonumber(alert and alert.frameCount) or 0

    if texBase ~= "" then
        if frames > 1 then
            -- Animated: start from frame 1
            local path = KEL_MEDIA_PATH .. texBase
                         .. string.format("_%03d", 1) .. ".png"
            f.tex:SetTexture(path)
            f.tex:Show()
            f.anim.baseName   = texBase
            f.anim.frameCount = frames
            f.anim.fps        = math.max(1, tonumber(alert.fps) or 10)
            f.anim.loop       = alert.loop ~= false
            f.anim.current    = 1
            f.anim.elapsed    = 0
            f.anim.active     = true
        else
            -- Static: texture field may include extension or not
            f.tex:SetTexture(KEL_MEDIA_PATH .. texBase)
            f.tex:Show()
        end
    else
        f.tex:Hide()
    end

    local scale = (BH.settings and BH.settings.kelAlertScale) or 1.0
    f:SetScale(scale)
    local opacity = tonumber(alert and alert.opacity)
    f:SetAlpha(opacity and math.max(0, math.min(1, opacity)) or 1.0)

    local snd = PickRandomSound(alert) or (alert and alert.sound) or "None"
    local ch  = (alert and alert.soundChannel) or "Master"
    if alertSoundTicker then alertSoundTicker:Cancel(); alertSoundTicker = nil end
    -- Played by us, not by the client. Only the lust alert reaches here, and it
    -- is watchable the old way because its debuffs stay readable in combat --
    -- which is also why it can still have an image. Buff sounds are a separate
    -- mechanism entirely; see the buff sounds section below.
    if BH.PlaySound then BH:PlaySound(snd, ch) end
    if alert and alert.soundLoop and snd ~= "None" then
        local loopInterval = math.max(0.5, tonumber(alert.soundLoopInterval) or 2.0)
        alertSoundTicker = C_Timer.NewTicker(loopInterval, function()
            if BH.PlaySound then BH:PlaySound(snd, ch) end
        end)
    end

    f:Show()
    local dur = math.max(1, tonumber(alert and alert.duration) or 3)
    if alertTimer then alertTimer:Cancel() end
    alertTimer = C_Timer.NewTimer(dur, function()
        f.anim.active = false
        f:Hide()
        alertTimer = nil
        if alertSoundTicker then alertSoundTicker:Cancel(); alertSoundTicker = nil end
    end)
end

-- Expose so the Test button can call it
BH.ShowKelAlert = ShowAlert

-- ============================================================================
-- Position persistence
-- ============================================================================

function BH:SaveKelAlertPosition()
    if not self.kelAlertFrame then return end
    local point, _, relPoint, x, y = self.kelAlertFrame:GetPoint()
    SquizzumablesDB.kelAlertPosition = { point = point, relPoint = relPoint, x = x, y = y }
end

function BH:LoadKelAlertPosition()
    local f = EnsureAlertFrame()
    local pos = SquizzumablesDB and SquizzumablesDB.kelAlertPosition
    if pos then
        f:ClearAllPoints()
        f:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or "CENTER", pos.x or 0, pos.y or 100)
    end
end

-- ============================================================================
-- UNIT_AURA: detect configured spell auras applied to the player
-- Called by the existing UNIT_AURA handler in Squizzumables.lua
-- ============================================================================

-- Sated-like debuffs that are applied to the player after any lust effect.
local LUST_DEBUFF_IDS = {
    [57724]  = true,  -- Sated                   (Heroism)
    [57723]  = true,  -- Exhaustion              (Bloodlust)
    [80354]  = true,  -- Temporal Displacement   (Time Warp)
    [95809]  = true,  -- Insanity                (Ancient Hysteria / Hunter pet)
    [160455] = true,  -- Fatigued                (Hunter pet, variant 1)
    [264689] = true,  -- Fatigued                (Hunter pet, variant 2)
    [390435] = true,  -- Exhaustion              (Evoker Fury / Primal Rage)
    [206151] = true,  -- Temporal Displacement   (Fury of the Aspects)
}


-- Which alert the settings tab is editing. Not persisted: it is a cursor in the
-- UI, not a preference.
local selectedAlertID = "lust"

local function AllAlerts()
    BH.settings.alerts = BH.settings.alerts or {}
    return BH.settings.alerts
end
BH.AllAlerts = AllAlerts

--- The alert currently being edited.
---
--- Falls back rather than returning nil: deleting an alert leaves the selection
--- dangling until the tab rebuilds, and every control in that tab would error
--- on a nil record.
local function CurrentAlert()
    local all = AllAlerts()
    local a = all[selectedAlertID]
    if not a then
        selectedAlertID = next(all) or "lust"
        a = all[selectedAlertID]
    end
    if not a then
        a = CopyTable(BH.defaultSettings.alerts.lust)
        all.lust = a
        selectedAlertID = "lust"
    end
    return a
end
BH.CurrentAlert = CurrentAlert

function BH.SelectAlert(id) selectedAlertID = id end
function BH.SelectedAlertID() return selectedAlertID end

-- Check each known sated-like debuff by spellID directly instead of scanning
-- all auras by index. As of 12.1.0, GetAuraDataByIndex throws a taint error
-- ("Auras cannot be accessed when secret") when auras are secret (in combat,
-- encounters, M+, PvP) — GetUnitAuraBySpellID does not have this problem.
local function HasLustDebuff()
    if C_UnitAuras and C_UnitAuras.GetUnitAuraBySpellID then
        for spellID in pairs(LUST_DEBUFF_IDS) do
            -- Presence check only — nothing is read off the returned table, so
            -- there is no secret field to trip over.
            if BH.Secrets.GetAuraBySpellID("player", spellID) then
                return true
            end
        end
    else
        -- Legacy fallback for clients without C_UnitAuras. UnitDebuff was
        -- removed in 12.x, so this branch is unreachable on any client that can
        -- run this addon; kept only so the function degrades rather than errors.
        for i = 1, 40 do
            local _, _, _, _, _, _, _, _, _, spellId = UnitDebuff("player", i)
            spellId = BH.Secrets.SafeNumber(spellId, nil)
            if not spellId then break end
            if LUST_DEBUFF_IDS[spellId] then return true end
        end
    end
    return false
end

--- Is this alert's trigger currently true?
---
--- Aura triggers only so far. The built-in lust alert carries no spell of its
--- own because it watches every variant of the exhaustion debuff at once; an
--- alert the player adds names one spell.
local function TriggerActive(alert)
    local t = alert.trigger or {}
    if t.type ~= nil and t.type ~= "aura" then return false end

    if alert.builtin and not t.spellID then
        return HasLustDebuff()
    end

    local spellID = tonumber(t.spellID)
    if not spellID then return false end
    -- No filter: the lookup is by spell ID, and a spell ID is either a buff or a
    -- debuff, so there is nothing for a HELPFUL/HARMFUL split to disambiguate.
    -- t.harmful is still stored on the trigger, but only the UI reads it.
    -- Presence check only, so there is no secret field to read off the result.
    return BH.Secrets.GetAuraBySpellID("player", spellID) ~= nil
end
BH.AlertTriggerActive = TriggerActive

-- How long ago the trigger aura was APPLIED, in seconds, or nil when that
-- cannot be told.
--
-- Presence alone is the wrong signal for "lust just went out". The alert fires
-- on its trigger going false -> true, and that edge also happens with the SAME
-- Sated still on you: after a /reload (alertWasActive is plain Lua state and
-- starts empty), and across a loading screen, where auras briefly read absent
-- and then come back -- which is how leaving a dungeon replayed the sound in
-- the city (user report 2026-09-26). The 3 second playerZoning window caught
-- only the fast cases; a slow city load, or a zone change some time after a
-- reload, slipped past it.
--
-- The lust debuffs are readable in combat, so their application time is known
-- (expiration - duration), and an alert now fires only for an aura applied
-- within FRESH_TRIGGER_WINDOW. Anything unreadable -- a user trigger on an
-- aura that goes secret -- answers nil and keeps the old behaviour, so this
-- can only ever remove a replay, never a real alert.
local FRESH_TRIGGER_WINDOW = 5

local function TriggerAge(alert)
    local t = alert.trigger or {}
    local ids
    if alert.builtin and not t.spellID then
        ids = LUST_DEBUFF_IDS
    else
        local spellID = tonumber(t.spellID)
        if not spellID then return nil end
        ids = { [spellID] = true }
    end
    local youngest
    for spellID in pairs(ids) do
        local aura = BH.Secrets.GetAuraBySpellID("player", spellID)
        if aura then
            local dur = BH.Secrets.SafeAuraDuration(aura)
            local exp = BH.Secrets.SafeAuraExpiration(aura)
            if not (dur and exp and dur > 0) then return nil end
            local age = GetTime() - (exp - dur)
            if not youngest or age < youngest then youngest = age end
        end
    end
    return youngest
end

-- For the later Alerts/ files (see the header).
A.KEL_MEDIA_PATH       = KEL_MEDIA_PATH
A.ShowAlert            = ShowAlert
A.AllAlerts            = AllAlerts
A.CurrentAlert         = CurrentAlert
A.TriggerActive        = TriggerActive
A.FRESH_TRIGGER_WINDOW = FRESH_TRIGGER_WINDOW
A.TriggerAge           = TriggerAge
