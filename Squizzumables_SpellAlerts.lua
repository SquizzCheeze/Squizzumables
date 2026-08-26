-- Squizzumables_SpellAlerts.lua
-- "Just For Kel" tab: shows a texture (or animated frame sequence) and plays
-- a sound when a configured spell aura is applied to the player.

local addonName, ns = ...
local BH = ns.BH

-- Shared theme and UI constructors, defined in Squizzumables.lua which loads
-- before this file.
local SQ_COLORS        = ns.SQ_COLORS
local CreateSQButton   = ns.CreateSQButton
local CreateSQEditBox  = ns.CreateSQEditBox
local CreateSQSlider   = ns.CreateSQSlider
local CreateSQCheckbox = ns.CreateSQCheckbox
local CreateSQDropdown = ns.CreateSQDropdown
local CreateSQDivider  = ns.CreateSQDivider

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
    f:EnableMouse(false)
    f:Hide()

    f:SetScript("OnMouseDown", function(self, btn)
        -- Unlock Frames overrides the per-frame lock, so this can be positioned
        -- alongside everything else without unticking its own checkbox first.
        if btn == "LeftButton"
            and (BH.unlockMode or not (BH.settings and BH.settings.kelAlertLocked)) then
            self:StartMoving()
        end
    end)
    f:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
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

-- ============================================================================
-- Buff sounds  (C_UnitAuras.AddAuraSound, 12.1)
--
-- Since 12.1 the client hides nearly every aura from addons in combat -- only a
-- very short allowlist (the lust debuffs among them) stays readable. So any
-- alert built on reading an aura fires out in the world and goes silent in the
-- pull it was made for, and no amount of addon-side wiring changes that.
--
-- AddAuraSound inverts who does the watching. We hand the client a spell ID and
-- a sound file up front; it plays the sound when the aura is applied or
-- removed. No value ever crosses into addon code, so there is nothing for
-- secrecy to withhold. Verified on retail against Tyr's Deliverance (200654):
-- secret, unreadable, sound still played in combat.
--
-- What it costs is the image. The client plays the sound and reports nothing
-- back, so there is no moment at which we could draw anything -- which is why
-- these are "buff sounds" and not alerts, and why the lust alert (readable, so
-- still watchable the old way) keeps its picture and lives elsewhere.
--
-- Two constraints come from the API rather than from preference:
--   * one fixed sound per trigger. There is nothing to re-roll at play time; a
--     random pool would be resolved once here and then repeat forever.
--   * a real file path. The __builtin_* sounds are sound kit IDs and
--     soundFileName wants a file, so those cannot be delegated.
-- ============================================================================

-- [spellID .. ":" .. trigger] = auraSoundID handed back by the client.
local registeredAuraSounds = {}

local function AuraSoundsAvailable()
    return C_UnitAuras and C_UnitAuras.AddAuraSound and C_UnitAuras.RemoveAuraSound
        and Enum and Enum.UnitAuraSoundTrigger
end
BH.AuraSoundsAvailable = AuraSoundsAvailable

-- The player's configured buff sounds: { [spellID] = { added, removed, channel } }
local function BuffSounds()
    if not BH.settings then return {} end
    BH.settings.buffSounds = BH.settings.buffSounds or {}
    return BH.settings.buffSounds
end
BH.BuffSounds = BuffSounds

local function ClearAuraSoundRegistrations()
    if not AuraSoundsAvailable() then return end
    for key, soundID in pairs(registeredAuraSounds) do
        pcall(C_UnitAuras.RemoveAuraSound, soundID)
        registeredAuraSounds[key] = nil
    end
end

-- Rebuild every registration from current settings.
--
-- Wholesale rather than incremental on purpose: a spell's sounds can change
-- from several places, and a stale registration is worse than a missing one --
-- it plays a sound the player has stopped asking for, with nothing on screen
-- explaining where it came from.
local function ApplyAuraSoundRegistrations(self)
    if not AuraSoundsAvailable() then return end
    ClearAuraSoundRegistrations()
    if not self.settings then return end

    local triggers = {
        added   = Enum.UnitAuraSoundTrigger.Added,
        removed = Enum.UnitAuraSoundTrigger.Removed,
    }

    local wanted, got = 0, 0
    for spellID, entry in pairs(BuffSounds()) do
        local id = tonumber(spellID)
        if id and type(entry) == "table" then
            for field, trigger in pairs(triggers) do
                local path = self.ResolveSoundPath and self:ResolveSoundPath(entry[field])
                if path then
                    wanted = wanted + 1
                    local ok, soundID = pcall(C_UnitAuras.AddAuraSound, trigger, {
                        unitToken     = "player",
                        spellID       = id,
                        soundFileName = path,
                        outputChannel = entry.channel or "Master",
                    })
                    -- A nil ID means the client declined it (AddAuraSound is
                    -- flagged HasRestrictions). The pcall does not catch that:
                    -- a refusal raises ADDON_ACTION_BLOCKED, which is a client
                    -- event and not a Lua error, so `ok` is true either way.
                    -- The missing ID is the only tell we get.
                    if ok and soundID then
                        got = got + 1
                        registeredAuraSounds[id .. ":" .. field] = soundID
                    end
                end
            end
        end
    end
    return wanted, got
end

-- Public entry point, deliberately deferred onto a timer.
--
-- AddAuraSound is protected -- that is what HasRestrictions means on it -- and
-- calling it from a chain that began at the chat edit box trips
-- ADDON_ACTION_BLOCKED. Typing /sq config is exactly such a chain: SendText ->
-- the slash handler -> CreateOptionsPanel -> RefreshJustForKelTab -> here.
-- Reported by a user on 1.63.
--
-- The pcall meant no Lua error, which made it look cosmetic. It was not:
-- ClearAuraSoundRegistrations runs first and succeeds, then every re-register
-- is blocked, so opening the options by slash command silently unregistered
-- every buff sound until the next login.
--
-- A C_Timer callback runs with none of that lineage, so the same call is
-- allowed. Debounced with a flag because several refreshes arrive together
-- while the panel is being built, and there is no point doing the work more
-- than once per frame.
local registrationPending = false
local registrationQueued  = false

-- A refusal is recoverable, and until 1.67 nothing recovered it.
--
-- ApplyAuraSoundRegistrations tears every registration down before building the
-- new ones, on the reasoning that a stale sound is worse than a missing one.
-- That holds, but it means a refused rebuild does not leave things as they were:
-- the removals succeed, the adds are blocked, and the player is left with every
-- buff sound off until something else happens to trigger a rebuild -- in
-- practice, until relog. Reported from LFR on 1.67, out of combat and from
-- inside the deferral, so neither of the two guards above explains it.
--
-- Rather than theorise about which protected path was poisoned, just retry: the
-- refusals seen so far are transient, tied to whatever else the client was busy
-- refusing at the time. Bounded, because a registration can also fail for
-- reasons no amount of retrying fixes (a sound file that has gone missing), and
-- a silent forever-loop is its own bug.
local RETRY_LIMIT   = 5
local RETRY_DELAY   = 3
local retryCount    = 0
local retryScheduled = false

-- Last refusal, for /sq buffsounds. Nil once a rebuild fully succeeds.
BH.auraSoundRefusal = nil
-- What asked for the most recent rebuild. The traceback cannot show this: the
-- stack ends at the C_Timer closure, so by the time the call fails the caller
-- is long gone, which is exactly what made the 1.67 report hard to place.
local lastTrigger = "startup"

local function RunRegistration()
    -- Never in combat.
    --
    -- AddAuraSound is protected, and protected calls are refused in combat the
    -- same way SetAttribute on a secure frame is -- registration succeeds at
    -- login and is blocked mid-fight. The C_Timer.After below does not help
    -- with this: the timer still fires in combat, which is why deferring alone
    -- left ADDON_ACTION_BLOCKED tracebacks coming out of the timer callback.
    --
    -- Queued and flushed on PLAYER_REGEN_ENABLED, the same pattern the CDM
    -- module uses for its container mutations. Nothing is lost by waiting:
    -- these registrations only change when settings change, and settings do
    -- not change mid-pull.
    if InCombatLockdown() then
        registrationQueued = true
        return
    end
    registrationQueued = false
    local wanted, got = ApplyAuraSoundRegistrations(BH)

    if wanted and got and got < wanted then
        BH.auraSoundRefusal = {
            wanted   = wanted,
            got      = got,
            attempt  = retryCount + 1,
            trigger  = lastTrigger,
            when     = GetTime(),
        }
        if retryCount < RETRY_LIMIT and not retryScheduled then
            retryCount = retryCount + 1
            retryScheduled = true
            C_Timer.After(RETRY_DELAY, function()
                retryScheduled = false
                RunRegistration()
            end)
        end
    else
        BH.auraSoundRefusal = nil
        retryCount = 0
    end

    -- The editor draws "active" / "not registered" from the results, so it
    -- would otherwise show the state from before this ran. Only the editor is
    -- redrawn, not the whole tab: RefreshJustForKelTab calls back into this
    -- and would loop.
    if BH.kelBuffEditor and BH.RebuildBuffSoundEditor then
        BH:RebuildBuffSoundEditor()
    end
end

---@param trigger string? label for /sq buffsounds, naming what asked for this
function BH:RefreshAuraSoundRegistrations(trigger)
    if not AuraSoundsAvailable() then return end
    lastTrigger = trigger or "unknown"
    -- A fresh request is a fresh budget: the retries below belong to the
    -- rebuild that was refused, not to every rebuild for the rest of the
    -- session.
    retryCount = 0
    if registrationPending then return end
    registrationPending = true
    C_Timer.After(0, function()
        registrationPending = false
        RunRegistration()
    end)
end

-- Flush a registration that combat postponed. Called from PLAYER_REGEN_ENABLED.
function BH:FlushQueuedAuraSoundRegistrations()
    if registrationQueued then RunRegistration() end
end

-- Did the client accept this spell's registration? Read by the tab, so a
-- refusal is visible rather than silently doing nothing.
function BH.BuffSoundRegistered(spellID, field)
    return registeredAuraSounds[tonumber(spellID) .. ":" .. field] ~= nil
end

-- /sq buffsounds -- what the client actually accepted, and what it refused.
--
-- Exists because the ADDON_ACTION_BLOCKED traceback cannot answer the two
-- questions that matter: which call site asked for the rebuild, and whether the
-- refusal stuck or a retry recovered it. Run it after a blocked-call report.
function BH:PrintBuffSoundDiagnostics()
    if not AuraSoundsAvailable() then
        print("Squizzumables: AddAuraSound not available on this client.")
        return
    end
    print("|cFF00FF00Squizzumables buff sounds|r")
    print(("  last rebuild asked for by: %s"):format(lastTrigger))
    print(("  in combat now: %s"):format(tostring(InCombatLockdown())))

    local n = 0
    for key, soundID in pairs(registeredAuraSounds) do
        n = n + 1
        local id, field = key:match("^(%d+):(.+)$")
        -- Through Secrets: this command gets run in precisely the tainted
        -- moments where a spell name comes back secret, and printing one
        -- directly is how that turns a diagnostic into a second error report.
        local name = id and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(tonumber(id))
        name = BH.Secrets and BH.Secrets.SafeString(name, "?") or "?"
        print(("    %s (%s) %s -> auraSoundID %s"):format(
            name, tostring(id), tostring(field), tostring(soundID)))
    end
    print(("  %d registration(s) active"):format(n))

    local r = BH.auraSoundRefusal
    if r then
        print(("|cFFFF5555  REFUSED: %d of %d registered on attempt %d (trigger: %s, %.0fs ago)|r")
            :format(r.got, r.wanted, r.attempt, tostring(r.trigger), GetTime() - (r.when or GetTime())))
        print("|cFFFF5555  Retrying automatically. If this persists, another addon is likely")
        print("  tainting the protected path -- check a BugGrabber traceback for the addon named.|r")
    else
        print("  no refusals since the last successful rebuild")
    end
end

-- ============================================================================
-- The player's own buffs, from the spellbook
--
-- Built from the spellbook rather than from Blizzard's Cooldown Manager
-- categories, which is what frees this from the CDM entirely: AddAuraSound
-- takes a raw spell ID and does not care whether Blizzard filed the spell in a
-- viewer. isOffSpec is exactly "not in the spec and talents you have selected",
-- so the list maintains itself across every respec with nothing hardcoded.
--
-- IsSelfBuff narrows it to spells that put an aura on the player, which is what
-- an aura sound can actually fire on. It is not perfect -- a spell whose cast ID
-- differs from the ID of the aura it applies will register a sound that never
-- plays (Blessing of Freedom is 61107 to cast and 92824 as the buff) -- which is
-- why the tab also takes a spell ID by hand.
-- ============================================================================

-- Spells the walk below misses, added by hand.
--
-- IsSelfBuff is the filter, and it does not agree that everything which puts an
-- aura on you is a self-buff. Tyr's Deliverance (200654) is the case that found
-- this: a Holy Paladin cooldown that visibly buffs the paladin, absent from
-- IsSelfBuff and absent from all four of Blizzard's cooldown categories even
-- with allowUnlearned. There is no data source that knows about it, so the list
-- is the honest answer rather than a workaround for one.
--
-- Gated on class, not on IsSpellKnown. These are *aura* IDs, and an aura is not
-- a known spell -- IsSpellKnown answers about things you can cast, so it can
-- return false for an ID you visibly have on you, which is what kept this list
-- from showing up at all on the first attempt.
--
-- Add entries when a buff that should obviously be in the grid is not.
local BUFF_SOUND_EXTRAS = {
    { spellID = 200654, class = "PALADIN" },  -- Tyr's Deliverance
}

function BH.GetKnownBuffSpells()
    local out = {}
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then return out end

    local seen = {}
    local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local numLines = C_SpellBook.GetNumSpellBookSkillLines() or 0

    for lineIndex = 1, numLines do
        local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(lineIndex)
        if lineInfo and lineInfo.numSpellBookItems then
            local first = (lineInfo.itemIndexOffset or 0) + 1
            local last  = (lineInfo.itemIndexOffset or 0) + lineInfo.numSpellBookItems
            for slot = first, last do
                local info = C_SpellBook.GetSpellBookItemInfo(slot, bank)
                -- isOffSpec covers the whole "current spec and talents" question.
                -- Passives cannot be alerted on usefully, and a flyout is a
                -- container rather than a spell.
                if info and not info.isPassive and not info.isOffSpec then
                    local spellID = info.spellID or info.actionID
                    if spellID and not seen[spellID] then
                        local isBuff = C_Spell.IsSelfBuff and C_Spell.IsSelfBuff(spellID)
                        if isBuff then
                            seen[spellID] = true
                            out[#out + 1] = {
                                spellID = spellID,
                                name    = info.name or C_Spell.GetSpellName(spellID),
                                icon    = info.iconID or C_Spell.GetSpellTexture(spellID),
                            }
                        end
                    end
                end
            end
        end
    end

    local _, playerClass = UnitClass("player")
    for _, extra in ipairs(BUFF_SOUND_EXTRAS) do
        if not seen[extra.spellID] and (not extra.class or extra.class == playerClass) then
            seen[extra.spellID] = true
            out[#out + 1] = {
                spellID = extra.spellID,
                name    = C_Spell.GetSpellName(extra.spellID) or ("Spell " .. extra.spellID),
                icon    = C_Spell.GetSpellTexture(extra.spellID),
            }
        end
    end

    table.sort(out, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)
    return out
end

-- ============================================================================
-- Buff sounds UI
-- ============================================================================

-- Which icon the editor below the grid is editing.
local selectedBuffSpellID

function BH.SelectBuffSpell(spellID)
    selectedBuffSpellID = tonumber(spellID)
end

-- Every spell the grid should show: this spec's own buffs, plus anything
-- already configured that is not among them.
--
-- The second half matters because a spell ID added by hand -- or one kept from
-- a spec you have since left -- would otherwise vanish from the UI while its
-- sound carried on playing, which is the worst of both.
local function BuffGridEntries()
    local entries = BH.GetKnownBuffSpells()
    local seen = {}
    for _, e in ipairs(entries) do seen[e.spellID] = true end

    local extra = {}
    for spellID in pairs(BH.BuffSounds()) do
        local id = tonumber(spellID)
        if id and not seen[id] then
            extra[#extra + 1] = {
                spellID = id,
                name    = C_Spell.GetSpellName(id) or ("Spell " .. id),
                icon    = C_Spell.GetSpellTexture(id),
                manual  = true,
            }
        end
    end
    table.sort(extra, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    for _, e in ipairs(extra) do entries[#entries + 1] = e end
    return entries
end

local BUFF_ICON_SIZE = 30
local BUFF_ICON_GAP  = 4
local BUFF_PER_ROW   = 10

function BH:RebuildBuffSoundGrid()
    local grid = self.kelBuffGrid
    if not grid then return end

    for _, child in ipairs({ grid:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({ grid:GetRegions() }) do
        region:Hide()
        region:SetParent(nil)
    end

    local entries = BuffGridEntries()
    if #entries == 0 then
        local none = grid:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        none:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, 0)
        none:SetText("No self-buffs found for this spec.")
        none:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        grid:SetHeight(20)
        return
    end

    -- Drop a selection this spec no longer offers, so the editor below never
    -- describes a spell missing from the grid above it.
    local stillPresent = false
    for _, e in ipairs(entries) do
        if e.spellID == selectedBuffSpellID then stillPresent = true break end
    end
    if not stillPresent then selectedBuffSpellID = entries[1].spellID end

    local store = BH.BuffSounds()
    local rows = 0
    for i, entry in ipairs(entries) do
        local col = (i - 1) % BUFF_PER_ROW
        local row = math.floor((i - 1) / BUFF_PER_ROW)
        rows = row + 1

        local btn = CreateFrame("Button", nil, grid, "BackdropTemplate")
        btn:SetSize(BUFF_ICON_SIZE, BUFF_ICON_SIZE)
        btn:SetPoint("TOPLEFT", grid, "TOPLEFT",
            col * (BUFF_ICON_SIZE + BUFF_ICON_GAP),
            -row * (BUFF_ICON_SIZE + BUFF_ICON_GAP))

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexture(entry.icon)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        ns.ApplySQBackdrop(btn, { 0, 0, 0, 0 }, SQ_COLORS.border)

        -- Three states worth telling apart at a glance: selected, has a sound,
        -- and neither. A configured spell keeps an accent border once the
        -- selection moves on, or there is no way to see what is already set up
        -- without clicking every icon in turn.
        local configured = store[entry.spellID] ~= nil
        if entry.spellID == selectedBuffSpellID then
            local r, g, b = ns.GetAccentColor()
            btn:SetBackdropBorderColor(r, g, b, 1)
        elseif configured then
            local r, g, b = ns.GetAccentColor("dim")
            btn:SetBackdropBorderColor(r, g, b, 0.8)
        else
            btn:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2],
                                       SQ_COLORS.border[3], 1)
            icon:SetDesaturated(true)
            icon:SetAlpha(0.7)
        end

        btn:SetScript("OnClick", function()
            BH.SelectBuffSpell(entry.spellID)
            BH:RebuildBuffSoundGrid()
            BH:RebuildBuffSoundEditor()
        end)
        btn:SetScript("OnEnter", function(s)
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetText(entry.name or ("Spell " .. entry.spellID))
            GameTooltip:AddLine("Spell ID " .. entry.spellID, 0.7, 0.7, 0.7, false)
            if entry.manual then
                GameTooltip:AddLine("Added by spell ID.", 0.7, 0.7, 0.7, true)
            end
            if configured then
                GameTooltip:AddLine("Has a sound.", 0.7, 0.7, 0.7, true)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    grid:SetHeight(rows * (BUFF_ICON_SIZE + BUFF_ICON_GAP))
end

function BH:RebuildBuffSoundEditor()
    local editor = self.kelBuffEditor
    if not editor then return end

    for _, child in ipairs({ editor:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({ editor:GetRegions() }) do
        region:Hide()
        region:SetParent(nil)
    end

    local spellID = selectedBuffSpellID
    if not spellID then editor:SetHeight(1) return end

    local store = BH.BuffSounds()
    local entry = store[spellID]
    local name  = C_Spell.GetSpellName(spellID) or ("Spell " .. spellID)
    local y     = 0

    local title = editor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
    title:SetText(tostring(BH.Secrets.SafeString(name, "?")) .. "  (" .. spellID .. ")")
    ns.ApplyAccent(title, "text")
    y = y - 22

    -- Two triggers, one row each. Choosing "None" clears that half rather than
    -- needing its own delete; the Remove button clears the spell outright.
    local function SoundRow(label, field, tooltip)
        local lbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y - 4)
        lbl:SetWidth(60)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(label)
        lbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

        local drop = CreateSQDropdown(editor, "", 200, BH:BuildSoundDropdownItems(), function(val)
            local s = BH.BuffSounds()
            s[spellID] = s[spellID] or { channel = "Master" }
            s[spellID][field] = (val ~= "None") and val or nil
            BH:SaveSettings()
            BH:RefreshAuraSoundRegistrations("sound changed")
            BH:RebuildBuffSoundGrid()
            BH:RebuildBuffSoundEditor()
        end)
        drop:SetPoint("TOPLEFT", editor, "TOPLEFT", 64, y)
        drop:SetSelectedValue((entry and entry[field]) or "None")
        ns.Rows.AddTooltip(drop, label, tooltip)

        local test = CreateSQButton(editor, "Test", 46, 22)
        test:SetPoint("LEFT", drop.btn, "RIGHT", 6, 0)
        test:SetScript("OnClick", function()
            local e = BH.BuffSounds()[spellID]
            BH:PlaySound(e and e[field] or "None", (e and e.channel) or "Master")
        end)

        -- Whether the client took the registration. A refusal is otherwise
        -- indistinguishable from a sound that simply has not fired yet.
        if entry and entry[field] then
            local state = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            state:SetPoint("LEFT", test, "RIGHT", 6, 0)
            if BH.BuffSoundRegistered(spellID, field) then
                state:SetText("active")
                state:SetTextColor(0.4, 0.8, 0.4)
            else
                state:SetText("not registered")
                state:SetTextColor(SQ_COLORS.danger[1], SQ_COLORS.danger[2], SQ_COLORS.danger[3])
            end
        end
        y = y - 28
    end

    SoundRow("Applied:", "added",
        "Played when this buff lands on you. The game plays it, which is why it still works in combat.")
    SoundRow("Removed:", "removed",
        "Played when this buff drops off you. Also played by the game, which is the only reliable way to know an aura has ended.")

    local chanLbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chanLbl:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y - 4)
    chanLbl:SetText("Channel:")
    chanLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local chanDrop = CreateSQDropdown(editor, "", 130, {
        { text = "Master",   value = "Master"   },
        { text = "SFX",      value = "SFX"      },
        { text = "Music",    value = "Music"    },
        { text = "Ambience", value = "Ambience" },
        { text = "Dialog",   value = "Dialog"   },
    }, function(val)
        local s = BH.BuffSounds()
        s[spellID] = s[spellID] or {}
        s[spellID].channel = val
        BH:SaveSettings()
        BH:RefreshAuraSoundRegistrations("channel changed")
    end)
    chanDrop:SetPoint("TOPLEFT", editor, "TOPLEFT", 64, y)
    chanDrop:SetSelectedValue((entry and entry.channel) or "Master")
    ns.Rows.AddTooltip(chanDrop, "Sound channel",
        "Which audio channel these play on. Master ignores your in-game sound sliders.")

    if entry then
        local rm = CreateSQButton(editor, "Remove", 68, 22, SQ_COLORS.danger)
        rm:SetPoint("LEFT", chanDrop.btn, "RIGHT", 8, 0)
        rm:SetScript("OnClick", function()
            BH.BuffSounds()[spellID] = nil
            BH:SaveSettings()
            BH:RefreshAuraSoundRegistrations("buff sound removed")
            BH:RebuildBuffSoundGrid()
            BH:RebuildBuffSoundEditor()
        end)
        ns.Rows.AddTooltip(rm, "Remove", "Clear both sounds for this spell.")
    end
    y = y - 30

    editor:SetHeight(math.abs(y) + 4)
end

-- Previous trigger state, per alert id, for edge detection.
local alertWasActive = {}

-- Returns a writable randomSounds table for the alert being edited, creating
-- one if missing. Existing profiles that predate this feature get the default
-- settings' (shared) empty table filled in by the generic deep-merge in
-- LoadSettings — writing into that shared table directly would corrupt the
-- default for every other profile and every other alert, so swap in a fresh
-- table on first write.
local function GetOrCreateRandomSoundsTable()
    local alert = CurrentAlert()
    local rs = alert.randomSounds
    if type(rs) ~= "table" or rs == BH.defaultSettings.alerts.lust.randomSounds then
        rs = {}
        alert.randomSounds = rs
    end
    return rs
end


-- Edge-detect the image alerts.
--
-- Only built-ins reach here now. A user-made alert on an arbitrary aura used to
-- run through this too, and could not work: the trigger reads the aura, and the
-- client hides nearly every aura in combat. Those became buff sounds, which the
-- client plays without us reading anything. What is left is the lust alert,
-- watchable the old way because its debuffs stay readable -- and therefore the
-- only alert that can still carry an image.
function BH:CheckKelAlerts(unit)
    if unit ~= "player" then return end
    if not self.settings then return end

    for id, alert in pairs(AllAlerts()) do
        if type(alert) == "table" and alert.enabled ~= false then
            local now = TriggerActive(alert)
            if now and not alertWasActive[id] and not BH.playerZoning then
                ShowAlert(alert)
            end
            alertWasActive[id] = now
        else
            -- A disabled alert resets, so switching one on while its trigger is
            -- already up fires once straight away -- which doubles as proof the
            -- alert is wired up correctly.
            alertWasActive[id] = false
        end
    end
end





-- ============================================================================
-- Settings tab: "Just For Kel"
-- ============================================================================

function BH:BuildJustForKelTab(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    local leftPad = 14
    local yOffset = -14

    -- Section header
    local hdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    hdr:SetText("KELERTS")
    ns.ApplyAccent(hdr, "text")
    yOffset = yOffset - 20

    local lustNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lustNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    lustNote:SetWidth(372)
    lustNote:SetJustifyH("LEFT")
    lustNote:SetWordWrap(true)
    lustNote:SetText("A full-screen image and a sound when any lust effect wears off. For a sound on your own buffs, see Buff Sounds below.")
    lustNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 34

    -- Alert enable
    local lustEnableCb = CreateSQCheckbox(content, "Enable this alert", function(val)
        CurrentAlert().enabled = val
        BH:SaveSettings()
    end)
    lustEnableCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelLustEnableCb = lustEnableCb
    ns.Rows.AddTooltip(lustEnableCb, "Enable this alert", "Show the image and play the sound when this alert's trigger appears on you.")
    yOffset = yOffset - 26

    -- Lust row 1: Texture · Frames · FPS
    local lTexLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lTexLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    lTexLbl:SetText("Texture:")
    lTexLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lTexEdit = CreateSQEditBox(content, 120, 20, { maxLetters = 128 })
    lTexEdit:SetPoint("LEFT", lTexLbl, "RIGHT", 4, 0)
    local function SaveLustTex(self)
        CurrentAlert().texture = self:GetText()
        BH:SaveSettings()
    end
    lTexEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustTex(self) end)
    lTexEdit.onFocusLost = SaveLustTex
    self.kelLustTexEdit = lTexEdit
    ns.Rows.AddTooltip(lTexEdit, "Alert image", "Base file name of the image in the addon Media folder, without the extension. For an animated sequence use the base name shared by the numbered frames.")

    local lFramesLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lFramesLbl:SetPoint("LEFT", lTexEdit, "RIGHT", 8, 0)
    lFramesLbl:SetText("Frames:")
    lFramesLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lFramesEdit = CreateSQEditBox(content, 34, 20, { numeric = true, justifyH = "CENTER" })
    lFramesEdit:SetPoint("LEFT", lFramesLbl, "RIGHT", 4, 0)
    local function SaveLustFrames(self)
        CurrentAlert().frameCount = math.max(0, tonumber(self:GetText()) or 0)
        BH:SaveSettings()
    end
    lFramesEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustFrames(self) end)
    lFramesEdit.onFocusLost = SaveLustFrames
    self.kelLustFramesEdit = lFramesEdit
    ns.Rows.AddTooltip(lFramesEdit, "Frame count", "How many numbered image files make up the animation. Leave at 1 for a still image.")

    local lFpsLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lFpsLbl:SetPoint("LEFT", lFramesEdit, "RIGHT", 8, 0)
    lFpsLbl:SetText("FPS:")
    lFpsLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lFpsEdit = CreateSQEditBox(content, 28, 20, { numeric = true, justifyH = "CENTER" })
    lFpsEdit:SetPoint("LEFT", lFpsLbl, "RIGHT", 4, 0)
    local function SaveLustFPS(self)
        CurrentAlert().fps = math.max(1, tonumber(self:GetText()) or 10)
        BH:SaveSettings()
    end
    lFpsEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustFPS(self) end)
    lFpsEdit.onFocusLost = SaveLustFPS
    self.kelLustFpsEdit = lFpsEdit
    ns.Rows.AddTooltip(lFpsEdit, "Frames per second", "Playback speed of the animation.")
    yOffset = yOffset - 28

    -- Lust row 2: Duration · Loop
    local lDurLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lDurLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    lDurLbl:SetText("Dur(s):")
    lDurLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lDurEdit = CreateSQEditBox(content, 34, 20, { numeric = true, justifyH = "CENTER" })
    lDurEdit:SetPoint("LEFT", lDurLbl, "RIGHT", 4, 0)
    local function SaveLustDur(self)
        CurrentAlert().duration = math.max(1, tonumber(self:GetText()) or 5)
        BH:SaveSettings()
    end
    lDurEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustDur(self) end)
    lDurEdit.onFocusLost = SaveLustDur
    self.kelLustDurEdit = lDurEdit
    ns.Rows.AddTooltip(lDurEdit, "Duration", "How many seconds the alert stays on screen.")

    local lLoopCb = CreateSQCheckbox(content, "Loop", function(val)
        CurrentAlert().loop = val
        BH:SaveSettings()
    end)
    lLoopCb:SetPoint("LEFT", lDurEdit, "RIGHT", 14, 0)
    self.kelLustLoopCb = lLoopCb
    ns.Rows.AddTooltip(lLoopCb, "Loop", "Repeat the animation for the whole duration instead of playing through once and holding on the last frame.")
    yOffset = yOffset - 28

    -- Lust row 2b: Sound loop
    local lSndLoopCb = CreateSQCheckbox(content, "Loop sound", function(val)
        CurrentAlert().soundLoop = val
        BH:SaveSettings()
    end)
    lSndLoopCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelLustSndLoopCb = lSndLoopCb
    ns.Rows.AddTooltip(lSndLoopCb, "Loop sound", "Repeat the alert sound while the alert is on screen.")

    local lSndLoopIntervalLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lSndLoopIntervalLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 95, yOffset + 3)
    lSndLoopIntervalLbl:SetText("every:")
    lSndLoopIntervalLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lSndLoopIntervalEdit = CreateSQEditBox(content, 34, 20, { justifyH = "CENTER" })
    lSndLoopIntervalEdit:SetPoint("LEFT", lSndLoopIntervalLbl, "RIGHT", 4, 0)
    local function SaveLustSndInterval(self)
        CurrentAlert().soundLoopInterval = math.max(0.5, tonumber(self:GetText()) or 2.0)
        BH:SaveSettings()
    end
    lSndLoopIntervalEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustSndInterval(self) end)
    lSndLoopIntervalEdit.onFocusLost = SaveLustSndInterval
    self.kelLustSndLoopIntervalEdit = lSndLoopIntervalEdit
    ns.Rows.AddTooltip(lSndLoopIntervalEdit, "Sound loop interval", "Seconds between repeats of the looped sound.")

    local lSndLoopSecLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lSndLoopSecLbl:SetPoint("LEFT", lSndLoopIntervalEdit, "RIGHT", 4, 0)
    lSndLoopSecLbl:SetText("sec")
    lSndLoopSecLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 26

    -- Lust row 3: Sound dropdown (full width) · Test
    local lSndLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lSndLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset - 13)
    lSndLbl:SetText("Sound:")
    lSndLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lSndDrop = CreateSQDropdown(content, "", 260, BH:BuildSoundDropdownItems(), function(val)
        CurrentAlert().sound = val
        BH:SaveSettings()
    end)
    lSndDrop:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 62, yOffset - 4)
    self.kelLustSndDrop = lSndDrop
    ns.Rows.AddTooltip(lSndDrop, "Alert sound", "Sound played when the alert fires. Includes the bundled sounds and any you have registered on the Sounds tab.")
    yOffset = yOffset - 30

    -- Lust row 3b: Channel selector + Test button
    local lChanLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lChanLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset - 13)
    lChanLbl:SetText("Channel:")
    lChanLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lChanDrop  -- forward-declared so the Test button closure below can capture it as an upvalue
    local lTestBtn = CreateSQButton(content, "Test", 50, 20)
    lTestBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 372 - 50 + 12, yOffset - 4)
    lTestBtn:SetScript("OnClick", function()
        ShowAlert({
            texture           = lTexEdit:GetText(),
            sound             = lSndDrop:GetSelectedValue() or "None",
            soundChannel      = lChanDrop:GetSelectedValue() or "Master",
            duration          = math.max(1, tonumber(lDurEdit:GetText()) or 5),
            frameCount        = math.max(0, tonumber(lFramesEdit:GetText()) or 0),
            fps               = math.max(1, tonumber(lFpsEdit:GetText()) or 10),
            loop              = lLoopCb:GetChecked(),
            opacity           = (BH.settings and CurrentAlert() and CurrentAlert().opacity) or 1.0,
            soundLoop         = lSndLoopCb:GetChecked(),
            soundLoopInterval = math.max(0.5, tonumber(lSndLoopIntervalEdit:GetText()) or 2.0),
        })
    end)

    lChanDrop = CreateSQDropdown(content, "", 130, {
        { text = "Master",   value = "Master"   },
        { text = "SFX",      value = "SFX"      },
        { text = "Music",    value = "Music"    },
        { text = "Ambience", value = "Ambience" },
        { text = "Dialog",   value = "Dialog"   },
    }, function(val)
        CurrentAlert().soundChannel = val
        BH:SaveSettings()
    end)
    lChanDrop:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 62, yOffset - 4)
    self.kelLustSndChannelDrop = lChanDrop
    ns.Rows.AddTooltip(lChanDrop, "Sound channel", "Which audio channel the alert plays on. Master ignores your in-game sound sliders.")
    yOffset = yOffset - 36

    -- ── RANDOMIZE SOUND ────────────────────────────────────────────────────
    do
        local div = CreateSQDivider(content, yOffset)
        div:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        yOffset = yOffset - 18
    end

    local rsHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rsHdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    rsHdr:SetText("RANDOMIZE SOUND")
    ns.ApplyAccent(rsHdr, "text")
    yOffset = yOffset - 20

    local rsNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rsNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    rsNote:SetWidth(372)
    rsNote:SetJustifyH("LEFT")
    rsNote:SetWordWrap(true)
    rsNote:SetText("Check any sounds below to have this alert play a random pick from them instead of the Sound above. Leave all unchecked (default) to just use the Sound above.")
    rsNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 34

    local rsItems = BH:BuildSoundDropdownItems()
    self.kelLustRandomSoundCbs = {}

    local rsSelectAllBtn = CreateSQButton(content, "Select All", 90, 20)
    rsSelectAllBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    rsSelectAllBtn:SetScript("OnClick", function()
        local rs = GetOrCreateRandomSoundsTable()
        for _, item in ipairs(rsItems) do
            if item.value ~= "None" then
                rs[item.value] = true
                local cb = self.kelLustRandomSoundCbs[item.value]
                if cb then cb:SetChecked(true) end
            end
        end
        BH:SaveSettings()
    end)

    local rsSelectNoneBtn = CreateSQButton(content, "Select None", 90, 20)
    rsSelectNoneBtn:SetPoint("LEFT", rsSelectAllBtn, "RIGHT", 8, 0)
    rsSelectNoneBtn:SetScript("OnClick", function()
        wipe(GetOrCreateRandomSoundsTable())
        for _, cb in pairs(self.kelLustRandomSoundCbs) do
            cb:SetChecked(false)
        end
        BH:SaveSettings()
    end)
    yOffset = yOffset - 28

    for _, item in ipairs(rsItems) do
        if item.value ~= "None" then
            local soundName = item.value
            local cb = CreateSQCheckbox(content, item.text, function(checked)
                local rs = GetOrCreateRandomSoundsTable()
                rs[soundName] = checked and true or nil
                BH:SaveSettings()
            end)
            cb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            self.kelLustRandomSoundCbs[soundName] = cb
            yOffset = yOffset - 20
        end
    end
    yOffset = yOffset - 8

    -- ── ALERT FRAME ────────────────────────────────────────────────────────
    do
        local div = CreateSQDivider(content, yOffset)
        div:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        yOffset = yOffset - 18
    end

    local afHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    afHdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    afHdr:SetText("ALERT FRAME")
    ns.ApplyAccent(afHdr, "text")
    yOffset = yOffset - 20

    local scaleSlider = CreateSQSlider(content, "Alert Image Scale %", 220, 50, 300, 1)
    scaleSlider:SetAfterValueChanged(function(val)
        BH.settings.kelAlertScale = val / 100
        BH:SaveSettings()
        if BH.kelAlertFrame then BH.kelAlertFrame:SetScale(val / 100) end
    end)
    scaleSlider:SetValue((BH.settings and BH.settings.kelAlertScale or 1.0) * 100)
    scaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelScaleSlider = scaleSlider
    ns.Rows.AddTooltip(scaleSlider, "Alert Image Scale %", "Size of the alert image, as a percentage.")
    yOffset = yOffset - 50

    local opacitySlider = CreateSQSlider(content, "Alert Opacity %", 220, 0, 100, 1)
    opacitySlider:SetAfterValueChanged(function(val)
        CurrentAlert().opacity = val / 100
        BH:SaveSettings()
    end)
    opacitySlider:SetValue(math.floor(((BH.settings and CurrentAlert() and CurrentAlert().opacity) or 1.0) * 100 + 0.5))
    opacitySlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelOpacitySlider = opacitySlider
    ns.Rows.AddTooltip(opacitySlider, "Alert Opacity %", "Transparency of the alert image.")
    yOffset = yOffset - 50

    local lockCb = CreateSQCheckbox(content, "Lock alert image position", function(val)
        BH.settings.kelAlertLocked = val
        BH:SaveSettings()
        if BH.kelAlertFrame then BH.kelAlertFrame:EnableMouse(not val) end
    end)
    lockCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelLockCb = lockCb
    ns.Rows.AddTooltip(lockCb, "Lock alert image position", "Stops the alert image being dragged.")
    yOffset = yOffset - 28

    -- ── BUFF SOUNDS ───────────────────────────────────────────────────────
    --
    -- A sound when one of your own buffs lands or drops, with no image. That is
    -- not a design choice -- see the buff sounds section at the top of this
    -- file. The client plays these, which is the only way they can fire in
    -- combat, and it reports nothing back for us to draw from.
    do
        local bsHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bsHdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        bsHdr:SetText("BUFF SOUNDS")
        ns.ApplyAccent(bsHdr, "text")
        yOffset = yOffset - 20

        local bsNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bsNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        bsNote:SetWidth(372)
        bsNote:SetJustifyH("LEFT")
        bsNote:SetWordWrap(true)
        bsNote:SetText("Your spec's buffs. Click one to give it a sound when it lands or drops. These play in combat, where the game hides auras from addons \226\128\148 so they are sound only, no image.")
        bsNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        yOffset = yOffset - 44

        if not BH.AuraSoundsAvailable() then
            local nope = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            nope:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            nope:SetWidth(372)
            nope:SetJustifyH("LEFT")
            nope:SetWordWrap(true)
            nope:SetText("This client has no C_UnitAuras.AddAuraSound, so buff sounds are unavailable.")
            nope:SetTextColor(SQ_COLORS.danger[1], SQ_COLORS.danger[2], SQ_COLORS.danger[3])
            yOffset = yOffset - 30
        else
            -- The icon grid. Held in a container so the whole thing can be
            -- rebuilt on a spec or talent change without disturbing the rest of
            -- the tab's layout -- which is exactly the bug the CDM sounds tab
            -- had, where the grid was drawn once and never again.
            local grid = CreateFrame("Frame", nil, content)
            grid:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            grid:SetSize(372, 40)
            self.kelBuffGrid = grid
            self:RebuildBuffSoundGrid()
            yOffset = yOffset - (grid:GetHeight() + 10)

            -- Manual entry, because the grid is built from cast spell IDs and
            -- AddAuraSound wants the ID of the aura that lands. They usually
            -- match for a self-buff and sometimes do not (Blessing of Freedom
            -- casts as 61107 and applies 92824), so there has to be a way to
            -- name the aura directly rather than discovering it does not work.
            local manLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            manLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            manLbl:SetText("Add by spell ID:")
            manLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

            local manEdit = CreateSQEditBox(content, 80, 20, { numeric = true, maxLetters = 9 })
            manEdit:SetPoint("LEFT", manLbl, "RIGHT", 6, 0)
            self.kelBuffManualEdit = manEdit
            ns.Rows.AddTooltip(manEdit, "Add by spell ID",
                "The spell ID of the aura itself, from its Wowhead URL. Use this for a buff that is not in the list above, or one whose cast and aura have different IDs.")

            local manBtn = CreateSQButton(content, "Add", 50, 22)
            manBtn:SetPoint("LEFT", manEdit, "RIGHT", 6, 0)
            manBtn:SetScript("OnClick", function()
                local id = tonumber(manEdit:GetText())
                if not id then return end
                local store = BH.BuffSounds()
                store[id] = store[id] or { channel = "Master" }
                manEdit:SetText("")
                manEdit:ClearFocus()
                BH.SelectBuffSpell(id)
                BH:SaveSettings()
                BH:RefreshJustForKelTab()
            end)
            yOffset = yOffset - 30

            -- Editor for whichever icon is selected.
            local editor = CreateFrame("Frame", nil, content)
            editor:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            editor:SetSize(372, 40)
            self.kelBuffEditor = editor
            self:RebuildBuffSoundEditor()
            yOffset = yOffset - (editor:GetHeight() + 12)
        end
    end

    -- ── M+ DEATH TALLY ────────────────────────────────────────────────────
    do
        local div = CreateSQDivider(content, yOffset)
        div:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        yOffset = yOffset - 18
    end

    local dtHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dtHdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    dtHdr:SetText("M+ DEATH TALLY")
    ns.ApplyAccent(dtHdr, "text")
    yOffset = yOffset - 22

    local dtEnableCb = CreateSQCheckbox(content, "Enable M+ Death Tally", function(checked)
        BH.settings.deathTallyEnabled = checked
        BH:SaveSettings()
        if BH.deathTallyFrame then BH:UpdateDeathTallyDisplay() end
    end)
    dtEnableCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelDeathTallyEnableCb = dtEnableCb
    ns.Rows.AddTooltip(dtEnableCb, "Enable M+ Death Tally", "Counts deaths per player for the current Mythic+ key. Starts and resets when a key begins, and can be dismissed with its close button.")
    yOffset = yOffset - 34

    local dtScaleSlider = CreateSQSlider(content, "M+ Death Tally Scale", 300, 50, 200, 5)
    dtScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    dtScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.deathTallyScale = value / 100
        BH:SaveSettings()
        if userInput and BH.deathTallyFrame then
            BH.deathTallyFrame:SetScale(value / 100)
        end
    end)
    self.kelDeathTallyScaleSlider = dtScaleSlider
    ns.Rows.AddTooltip(dtScaleSlider, "M+ Death Tally Scale", "Size of the death tally frame, as a percentage.")
    yOffset = yOffset - 50

    local dtTitleFontSlider = CreateSQSlider(content, "Title Font Size", 300, 8, 24, 1)
    dtTitleFontSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    dtTitleFontSlider:SetAfterValueChanged(function(value)
        BH.settings.deathTallyTitleFontSize = value
        BH:SaveSettings()
        if BH.deathTallyFrame then BH:UpdateDeathTallyDisplay() end
    end)
    self.kelDeathTallyTitleFontSlider = dtTitleFontSlider
    ns.Rows.AddTooltip(dtTitleFontSlider, "Title Font Size", "Size of the death tally heading text.")
    yOffset = yOffset - 50

    local dtRowFontSlider = CreateSQSlider(content, "Row Font Size", 300, 8, 20, 1)
    dtRowFontSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    dtRowFontSlider:SetAfterValueChanged(function(value)
        BH.settings.deathTallyRowFontSize = value
        BH:SaveSettings()
        if BH.deathTallyFrame then BH:UpdateDeathTallyDisplay() end
    end)
    self.kelDeathTallyRowFontSlider = dtRowFontSlider
    ns.Rows.AddTooltip(dtRowFontSlider, "Row Font Size", "Size of the per-player rows in the death tally.")
    yOffset = yOffset - 50

    local dtClassColorCb = CreateSQCheckbox(content, "Class color names", function(checked)
        BH.settings.deathTallyClassColorNames = checked
        BH:SaveSettings()
        if BH.deathTallyFrame then BH:UpdateDeathTallyDisplay() end
    end)
    dtClassColorCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelDeathTallyClassColorCb = dtClassColorCb
    ns.Rows.AddTooltip(dtClassColorCb, "Class color names", "Colour each name in the death tally by that player class.")
    yOffset = yOffset - 26

    local dtHideRealmCb = CreateSQCheckbox(content, "Hide realm names", function(checked)
        BH.settings.deathTallyHideRealm = checked
        BH:SaveSettings()
        if BH.deathTallyFrame then BH:UpdateDeathTallyDisplay() end
    end)
    dtHideRealmCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelDeathTallyHideRealmCb = dtHideRealmCb
    ns.Rows.AddTooltip(dtHideRealmCb, "Hide realm names", "Strip the -Realm suffix from names in the death tally, for cross-realm groups.")
    yOffset = yOffset - 34

    local dtLockCb = CreateSQCheckbox(content, "Lock M+ Death Tally", function(checked)
        BH.settings.deathTallyLocked = checked
        BH:SaveSettings()
        if BH.deathTallyFrame then
            BH.deathTallyFrame:SetMovable(not checked)
            BH.deathTallyFrame:EnableMouse(not checked)
        end
    end)
    dtLockCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelLockDeathTallyCheckbox = dtLockCb
    ns.Rows.AddTooltip(dtLockCb, "Lock M+ Death Tally", "Stops the death tally frame being dragged.")
    yOffset = yOffset - 28

    self.kelTabContent = content
    content:SetHeight(math.abs(yOffset) + 20)

    self:RefreshJustForKelTab()
end

function BH:RefreshJustForKelTab()
    -- Every edit in this tab routes back through here, so this is the one place
    -- that catches all of them. Deliberately ahead of the early return: the
    -- registrations must follow the settings even when the tab has never been
    -- built.
    self:RefreshAuraSoundRegistrations("Kelerts tab refresh")

    local content = self.kelTabContent
    if not content then return end

    -- The buff grid is spec- and talent-derived, so it has to be redrawn rather
    -- than left as it was built. This is the mistake the CDM sounds tab made:
    -- its grid was populated once at construction and never again, so a spec
    -- change left it showing spells the player no longer had.
    self:RebuildBuffSoundGrid()
    self:RebuildBuffSoundEditor()

    -- The lust alert is the only one left, so CurrentAlert() always resolves to
    -- it and there is no selector, name or trigger to keep in sync.
    local la = (BH.settings and CurrentAlert()) or {}

    if self.kelLustEnableCb   then self.kelLustEnableCb:SetChecked(la.enabled ~= false) end
    if self.kelLustTexEdit    then self.kelLustTexEdit:SetText(la.texture or "") end
    if self.kelLustFramesEdit then self.kelLustFramesEdit:SetText(tostring(la.frameCount or 0)) end
    if self.kelLustFpsEdit    then self.kelLustFpsEdit:SetText(tostring(la.fps or 10)) end
    if self.kelLustDurEdit    then self.kelLustDurEdit:SetText(tostring(la.duration or 5)) end
    if self.kelLustLoopCb     then self.kelLustLoopCb:SetChecked(la.loop ~= false) end
    if self.kelLustSndDrop              then self.kelLustSndDrop:SetSelectedValue(la.sound or "None") end
    if self.kelLustSndChannelDrop       then self.kelLustSndChannelDrop:SetSelectedValue(la.soundChannel or "Master") end
    if self.kelLustSndLoopCb            then self.kelLustSndLoopCb:SetChecked(la.soundLoop or false) end
    if self.kelLustSndLoopIntervalEdit  then self.kelLustSndLoopIntervalEdit:SetText(tostring(la.soundLoopInterval or 2.0)) end
    if self.kelLustRandomSoundCbs then
        local rs = la.randomSounds
        for soundName, cb in pairs(self.kelLustRandomSoundCbs) do
            cb:SetChecked(type(rs) == "table" and rs[soundName] or false)
        end
    end

    -- Alert frame controls
    if self.kelScaleSlider then
        self.kelScaleSlider:SetValue(math.max(50, math.min(300, (BH.settings and BH.settings.kelAlertScale or 1.0) * 100)))
    end
    if self.kelOpacitySlider then
        self.kelOpacitySlider:SetValue(math.floor(((la.opacity) or 1.0) * 100 + 0.5))
    end
    if self.kelLockCb then
        self.kelLockCb:SetChecked(BH.settings and BH.settings.kelAlertLocked or false)
    end

    -- M+ Death Tally controls
    if self.kelDeathTallyEnableCb then
        self.kelDeathTallyEnableCb:SetChecked(BH.settings and BH.settings.deathTallyEnabled ~= false)
    end
    if self.kelDeathTallyScaleSlider then
        self.kelDeathTallyScaleSlider:SetValue((BH.settings and BH.settings.deathTallyScale or 1.0) * 100)
    end
    if self.kelDeathTallyTitleFontSlider then
        self.kelDeathTallyTitleFontSlider:SetValue((BH.settings and BH.settings.deathTallyTitleFontSize) or 13)
    end
    if self.kelDeathTallyRowFontSlider then
        self.kelDeathTallyRowFontSlider:SetValue((BH.settings and BH.settings.deathTallyRowFontSize) or 12)
    end
    if self.kelDeathTallyClassColorCb then
        self.kelDeathTallyClassColorCb:SetChecked(BH.settings and BH.settings.deathTallyClassColorNames ~= false)
    end
    if self.kelDeathTallyHideRealmCb then
        self.kelDeathTallyHideRealmCb:SetChecked(BH.settings and BH.settings.deathTallyHideRealm ~= false)
    end
    if self.kelLockDeathTallyCheckbox then
        self.kelLockDeathTallyCheckbox:SetChecked(BH.settings and BH.settings.deathTallyLocked or false)
    end

end


