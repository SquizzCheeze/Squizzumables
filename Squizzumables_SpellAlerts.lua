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
    -- The buff images live on the same entries and must follow every place
    -- this is called from (login, profile load, every Kelerts edit). Ahead of
    -- the availability check: images do not need AddAuraSound.
    if self.RefreshBuffImages then self:RefreshBuffImages() end
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
-- Buff images (V1.95)
--
-- The image half of a custom Kelert, which reading the aura could never do in
-- combat. Each buff in the grid can carry an image that is on screen exactly
-- while that buff is up -- different buffs, different images. The aura
-- engine shows and hides it (BH.cdm.native:BuildBuffImage), so it works in
-- combat; nothing here reads the aura.
--
-- Stored on the same entry as the buff's sounds, BuffSounds()[spellID]:
--   image        a BUNDLED_IMAGES key ("vignette", "flames_u", ...) |
--                "custom" | nil
--   imageTexture custom: a game atlas name, a texture path, or a file name in
--                the addon's Media folder
--   imageFrames/imageCols/imageRows/imageFrameW/imageFrameH/imageFps/imageLoop
--                custom only: the texture is a FLIPBOOK sheet when imageFrames
--                > 1 (frame size in pixels; 0 = work it out, atlases only)
--   imageColor   { r, g, b } tint (the glow is white, so this is its colour)
--   imageAlpha   0..1
--   imageFill    true = over the whole screen, behind the interface;
--                false = imageSize square at its own position
--   imageSize    pixels, when not filling the screen
--   imageX/Y     its own position, offset from the screen's centre
--
-- ANIMATION IS A FLIPBOOK, never a texture swap. The lust alert animates by
-- SetTexture-ing the next numbered file every frame; that cannot work here,
-- because nothing on the engine's button may be touched after it is built.
-- A FlipBook animation is set up ONCE, inside initializeFrame, and the client
-- steps through the sheet itself. A child frame of ours restarts it on every
-- show (OnShow), so a buff re-applied later does not come back frozen on
-- whatever frame it stopped at -- whether that restart is needed at all, and
-- whether the client allows it once the aura is secret, is UNVERIFIED; it is
-- pcall'd so a refusal costs nothing.
-- ============================================================================

local ALERTS = KEL_MEDIA_PATH .. "Alerts\\"
local VIGNETTE = ALERTS .. "vignette.png"

-- The flame sheets' layout, as .claude/make-flames.ps1 draws them: 32 frames
-- of 512x256, 4 columns x 8 rows, on 2048x2048. Change both together.
local FLAME_SHEET = { frames = 32, cols = 4, rows = 8, w = 512, h = 256, fps = 16, loop = true }

-- Images that ship with the addon, offered in the editor's Image dropdown.
local BUNDLED_IMAGES = {
    vignette      = { file = VIGNETTE },
    flames_u      = { file = ALERTS .. "flames_u.png",      sheet = FLAME_SHEET, blend = "ADD" },
    flames_sides  = { file = ALERTS .. "flames_sides.png",  sheet = FLAME_SHEET, blend = "ADD" },
    flames_bottom = { file = ALERTS .. "flames_bottom.png", sheet = FLAME_SHEET, blend = "ADD" },
    flames_ring   = { file = ALERTS .. "flames_ring.png",   sheet = FLAME_SHEET, blend = "ADD" },
}
BH.KEL_BUNDLED_IMAGES = BUNDLED_IMAGES

local imageHosts = {}     -- [spellID] = our frame the image is placed by (reused)
local builtImageSig = {}  -- [spellID] = signature of the image last built
local imagesPending = false

-- What to draw: atlas or file, the flipbook layout if it animates, and the
-- blend mode.
local function ImageSource(entry)
    local bundled = BUNDLED_IMAGES[entry.image]
    if bundled then return nil, bundled.file, bundled.sheet, bundled.blend or "BLEND" end
    local name = strtrim(tostring(entry.imageTexture or ""))
    if name == "" then return nil, VIGNETTE, nil, "BLEND" end
    local sheet
    local frames = tonumber(entry.imageFrames) or 1
    if frames > 1 then
        sheet = {
            frames = frames,
            cols = math.max(1, tonumber(entry.imageCols) or 1),
            rows = math.max(1, tonumber(entry.imageRows) or 1),
            w = tonumber(entry.imageFrameW) or 0,
            h = tonumber(entry.imageFrameH) or 0,
            fps = math.max(1, tonumber(entry.imageFps) or 12),
            loop = entry.imageLoop ~= false,
        }
    end
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) then return name, nil, sheet, "BLEND" end
    if name:find("[\\/]") then return nil, name, sheet, "BLEND" end
    return nil, KEL_MEDIA_PATH .. name, sheet, "BLEND"
end

-- Paint `tex`, and if the image is a flipbook give it (or reconfigure) its
-- animation and play it. Returns the animation group, or nil for a still.
local function PaintImage(tex, entry)
    local atlas, file, sheet, blend = ImageSource(entry)
    if atlas then tex:SetAtlas(atlas) else tex:SetTexture(file) end
    tex:SetBlendMode(blend)
    local c = entry.imageColor or {}
    tex:SetVertexColor(c.r or 1, c.g or 1, c.b or 1, entry.imageAlpha or 0.8)

    local ag = tex._sqAnim
    if not sheet then
        if ag then ag:Stop() end
        if not atlas then tex:SetTexCoord(0, 1, 0, 1) end
        return nil
    end
    if not ag then
        ag = tex:CreateAnimationGroup()
        ag._sqFlip = ag:CreateAnimation("FlipBook")
        tex._sqAnim = ag
    end
    local fb = ag._sqFlip
    ag:Stop()
    fb:SetFlipBookFrameWidth(sheet.w)
    fb:SetFlipBookFrameHeight(sheet.h)
    fb:SetFlipBookRows(sheet.rows)
    fb:SetFlipBookColumns(sheet.cols)
    fb:SetFlipBookFrames(sheet.frames)
    fb:SetDuration(sheet.frames / sheet.fps)
    ag:SetLooping(sheet.loop and "REPEAT" or "NONE")
    ag:Play()
    return ag
end

-- Place a frame where an image for `entry` goes: the whole screen, behind the
-- interface, or a square at the image's OWN position (imageX/imageY, offset
-- from the screen's centre), above it. Its own, not the lust alert's: each
-- buff's image is placed independently (user decision 2026-10-05), with the
-- editor's Move button.
local function PlaceImageFrame(f, entry)
    f:ClearAllPoints()
    if entry.imageFill ~= false then
        f:SetFrameStrata("BACKGROUND")
        f:SetAllPoints(UIParent)
    else
        f:SetFrameStrata("HIGH")
        local size = entry.imageSize or 200
        f:SetSize(size, size)
        f:SetPoint("CENTER", UIParent, "CENTER", entry.imageX or 0, entry.imageY or 0)
    end
end

local function ImageSignature(entry)
    local c = entry.imageColor or {}
    return table.concat({
        tostring(entry.image), tostring(entry.imageTexture),
        table.concat({ tostring(entry.imageFrames), tostring(entry.imageCols), tostring(entry.imageRows),
            tostring(entry.imageFrameW), tostring(entry.imageFrameH), tostring(entry.imageFps),
            tostring(entry.imageLoop) }, ","),
        ("%.3f,%.3f,%.3f,%.3f"):format(c.r or 1, c.g or 1, c.b or 1, entry.imageAlpha or 0.8),
        tostring(entry.imageFill ~= false), tostring(entry.imageSize or 200),
        entry.imageFill == false and (tostring(entry.imageX or 0) .. "," .. tostring(entry.imageY or 0)) or "",
    }, "|")
end

--- Build every buff image from settings. Only images whose settings changed
--- are rebuilt: an aura container can never be destroyed, only switched off,
--- so rebuilding them all on every edit would leak one per image per edit.
--- In combat, the work waits for combat to end (containers are built out of
--- combat only).
function BH:RefreshBuffImages()
    local native = self.cdm and self.cdm.native
    if not (native and native.BuildBuffImage) then return end
    if InCombatLockdown() then imagesPending = true return end
    imagesPending = false

    local wanted = {}
    for spellID, entry in pairs(BuffSounds()) do
        local id = tonumber(spellID)
        if id and type(entry) == "table" and entry.image then
            wanted[id] = entry
        end
    end
    for id in pairs(builtImageSig) do
        if not wanted[id] then
            native:ReleaseBuffImage(id)
            builtImageSig[id] = nil
            if imageHosts[id] then imageHosts[id]:Hide() end
        end
    end
    for id, entry in pairs(wanted) do
        local sig = ImageSignature(entry)
        if builtImageSig[id] ~= sig then
            local host = imageHosts[id]
            if not host then
                host = CreateFrame("Frame", nil, UIParent)
                host:EnableMouse(false)
                imageHosts[id] = host
            end
            PlaceImageFrame(host, entry)
            host:Show()
            local ok = native:BuildBuffImage(id, id, host, function(button, watcher)
                local tex = button:CreateTexture(nil, "ARTWORK")
                tex:SetAllPoints(button)
                local ag = PaintImage(tex, entry)
                if ag and watcher then
                    -- Restart the flipbook each time the engine shows the
                    -- button again (see the section header). `watcher` is
                    -- our own child frame of the button (BuildBuffImage).
                    watcher.onShow = function() ag:Restart() end
                end
            end)
            builtImageSig[id] = ok and sig or nil
        end
    end
end

-- For controls that fire continuously while dragged (colour picker, sliders):
-- one rebuild after the dragging stops, not one per step, since every rebuild
-- strands a container.
local imageRefreshTimer
function BH:RefreshBuffImagesSoon()
    if imageRefreshTimer then imageRefreshTimer:Cancel() end
    imageRefreshTimer = C_Timer.NewTimer(0.4, function()
        imageRefreshTimer = nil
        BH:RefreshBuffImages()
    end)
end

-- /sq buffimages -- unlisted; see CLAUDE.md. Every link from setting to
-- screen, so "nothing shows" can be pinned to one of them: is the engine
-- there, did the image build, did the engine make its button, and -- the
-- usual one -- is the configured ID really the ID of the aura on you? The
-- buff grid lists CAST spell IDs; the slot matches AURA IDs. The aura list
-- needs to be run out of combat (aura data is hidden in it).
local function PrintBuffImageDiagnosticsBody()
    local P = function(s) print("  " .. s) end
    print("|cFF00FF00Squizzumables buff images|r")
    local native = BH.cdm and BH.cdm.native
    if not native then P("CDM aura module not loaded -- images cannot build.") return end
    P(("aura engine available: %s   in combat: %s   images waiting for combat to end: %s")
        :format(tostring(native:IsAvailable()), tostring(InCombatLockdown()), tostring(imagesPending)))
    P("last engine error: " .. tostring(native.lastError or "none"))

    local configured = {}
    for spellID, entry in pairs(BuffSounds()) do
        local id = tonumber(spellID)
        if id and type(entry) == "table" and entry.image then
            configured[id] = true
            local name = C_Spell.GetSpellName and C_Spell.GetSpellName(id)
            local c, info = native:BuffImageInfo(id)
            P(("%s (%d): image=%s  built=%s  container=%s  buttons made=%s")
                :format(tostring(BH.Secrets.SafeString(name, "?")), id, tostring(entry.image),
                    builtImageSig[id] and "yes" or "NO",
                    c and (c:IsVisible() and "visible" or "hidden") or "none",
                    info and tostring(info.inits) or "-"))
            -- The engine showing the button is what puts the image up. 0 shows
            -- with the buff on = the aura never matched the slot.
            if info then
                P(("    engine showed the image %d time(s), hid it %d time(s)")
                    :format(info.shows or 0, info.hides or 0))
            end
            local host = imageHosts[id]
            if host then
                P(("    host: shown=%s  size=%dx%d  strata=%s")
                    :format(tostring(host:IsShown()), host:GetWidth(), host:GetHeight(), host:GetFrameStrata()))
            end
        end
    end
    if not next(configured) then P("no buff has an image set") end

    if InCombatLockdown() then
        P("buffs on you: run this again OUT of combat -- the game hides aura data in combat")
        return
    end
    P("buffs on you now (name: aura ID) -- an image needs the AURA ID:")
    local n = 0
    for i = 1, 60 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok or not a then break end
        local id = BH.Secrets.SafeNumber(a.spellId, nil)
        local nm = BH.Secrets.SafeString(a.name, "?")
        n = n + 1
        P(("    %s: %s%s"):format(tostring(nm), tostring(id or "hidden"),
            (id and configured[id]) and "  <- has an image" or ""))
    end
    if n == 0 then P("    none") end
end

function BH:PrintBuffImageDiagnostics()
    local ok, err = pcall(PrintBuffImageDiagnosticsBody)
    if not ok then print("  |cffff4444diagnostics failed:|r " .. tostring(err)) end
    print("  -- end of buffimages --")
end

-- A built image's state, for the editor: "active", "waiting" (combat) or nil.
function BH.BuffImageState(spellID)
    if builtImageSig[tonumber(spellID)] then return "active" end
    if imagesPending then return "waiting" end
    return nil
end

do
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:SetScript("OnEvent", function()
        if imagesPending then BH:RefreshBuffImages() end
    end)
end

-- The Test button: the image as it will look, for a few seconds. A plain
-- frame of ours -- the real one only ever shows for a real buff. The same
-- frame is the Move handle (BH:MoveBuffImage), so what you drag is exactly
-- what will show.
local previewFrame, previewTimer
local movingSpellID     -- the image being placed with Move, or nil

local function PreviewFrame()
    if previewFrame then return previewFrame end
    local f = CreateFrame("Frame", nil, UIParent)
    f:EnableMouse(false)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    -- Shown only while moving: a box and a label, so a faint image -- or one
    -- the colour of the scene behind it -- can still be found and grabbed.
    f.box = f:CreateTexture(nil, "BACKGROUND")
    f.box:SetAllPoints()
    f.box:SetColorTexture(0.1, 0.4, 0.8, 0.25)
    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.label:SetPoint("CENTER")
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) BH:GridStartMoving(self) end)
    f:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(self)
        local entry = movingSpellID and BuffSounds()[movingSpellID]
        if not entry then return end
        -- Saved as an offset from the screen's centre. Both centres are read
        -- in UIParent's space (this frame is its child at scale 1).
        local fx, fy = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if fx and ux then
            entry.imageX = math.floor(fx - ux + 0.5)
            entry.imageY = math.floor(fy - uy + 0.5)
            BH:SaveSettings()
            BH:RefreshBuffImages()
        end
    end)
    previewFrame = f
    return f
end

function BH:PreviewBuffImage(spellID)
    local entry = BuffSounds()[tonumber(spellID)]
    if not (entry and entry.image) or movingSpellID then return end
    local f = PreviewFrame()
    PlaceImageFrame(f, entry)
    PaintImage(f.tex, entry)
    f.box:Hide()
    f.label:SetText("")
    f:Show()
    if previewTimer then previewTimer:Cancel() end
    previewTimer = C_Timer.NewTimer(3, function()
        f:Hide()
        if f.tex._sqAnim then f.tex._sqAnim:Stop() end
        previewTimer = nil
    end)
end

--- Start or finish placing a buff's image by dragging it. Its own position,
--- independent of every other image and of the lust alert.
function BH:MoveBuffImage(spellID)
    local id = tonumber(spellID)
    local f = PreviewFrame()
    if movingSpellID then
        -- Done (or switching to another buff): put the handle away.
        local wasSame = movingSpellID == id
        movingSpellID = nil
        f:EnableMouse(false)
        f:Hide()
        if wasSame then return end
    end
    local entry = id and BuffSounds()[id]
    if not (entry and entry.image) or entry.imageFill ~= false then return end
    if previewTimer then previewTimer:Cancel(); previewTimer = nil end
    movingSpellID = id
    PlaceImageFrame(f, entry)
    -- Above everything while being placed, whatever the image sits at.
    f:SetFrameStrata("DIALOG")
    PaintImage(f.tex, entry)
    f.box:Show()
    f.label:SetText("Drag me")
    f:EnableMouse(true)
    f:Show()
end

function BH.MovingBuffImage(spellID) return movingSpellID ~= nil and movingSpellID == tonumber(spellID) end

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
    -- A Move handle belongs to the buff it was opened for; picking another
    -- buff puts it away rather than leaving it to move the wrong image.
    if movingSpellID and movingSpellID ~= tonumber(spellID) then BH:MoveBuffImage(movingSpellID) end
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
                GameTooltip:AddLine("Has a sound or an image.", 0.7, 0.7, 0.7, true)
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
        ns.Rows.AddTooltip(rm, "Remove", "Clear this spell's sounds and image.")
    end
    y = y - 30

    -- ── IMAGE ─────────────────────────────────────────────────────────────
    -- Shown while the buff is up, by the game's aura engine, so it works in
    -- combat (see "Buff images" above).
    local function Entry()
        local s = BH.BuffSounds()
        s[spellID] = s[spellID] or { channel = "Master" }
        return s[spellID]
    end
    local function Changed(rebuildEditor)
        BH:SaveSettings()
        BH:RefreshBuffImages()
        BH:RebuildBuffSoundGrid()
        if rebuildEditor then BH:RebuildBuffSoundEditor() end
    end

    local imgLbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    imgLbl:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y - 4)
    imgLbl:SetWidth(60)
    imgLbl:SetJustifyH("LEFT")
    imgLbl:SetText("Image:")
    imgLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local imgDrop = CreateSQDropdown(editor, "", 200, {
        { text = "None",                      value = "none" },
        { text = "Screen edge glow",          value = "vignette" },
        { text = "Flames: bottom and sides",  value = "flames_u" },
        { text = "Flames: both sides",        value = "flames_sides" },
        { text = "Flames: bottom",            value = "flames_bottom" },
        { text = "Flames: all round",         value = "flames_ring" },
        { text = "Your own texture",          value = "custom" },
    }, function(val)
        Entry().image = (val ~= "none") and val or nil
        Changed(true)
    end)
    imgDrop:SetPoint("TOPLEFT", editor, "TOPLEFT", 64, y)
    imgDrop:SetSelectedValue((entry and entry.image) or "none")
    ns.Rows.AddTooltip(imgDrop, "Image",
        "An image on screen for exactly as long as this buff is up, in combat too -- the game's aura engine "
        .. "shows and hides it. Each buff can have its own. Screen edge glow is a coloured vignette round the "
        .. "edge of the screen; the Flames are animated fire along the edges you pick (leave the colour white "
        .. "for natural fire, or tint them).")

    if entry and entry.image then
        local test = CreateSQButton(editor, "Test", 46, 22)
        test:SetPoint("LEFT", imgDrop.btn, "RIGHT", 6, 0)
        test:SetScript("OnClick", function() BH:PreviewBuffImage(spellID) end)
        ns.Rows.AddTooltip(test, "Test", "Show the image for a few seconds, as it will look.")

        local state = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        state:SetPoint("LEFT", test, "RIGHT", 6, 0)
        local st = BH.BuffImageState(spellID)
        if st == "active" then
            state:SetText("active")
            state:SetTextColor(0.4, 0.8, 0.4)
        elseif st == "waiting" then
            state:SetText("after combat")
            state:SetTextColor(1, 0.8, 0.3)
        else
            state:SetText("not built")
            state:SetTextColor(SQ_COLORS.danger[1], SQ_COLORS.danger[2], SQ_COLORS.danger[3])
        end
    end
    y = y - 30

    if entry and entry.image then
        if entry.image == "custom" then
            local texLbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            texLbl:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y - 4)
            texLbl:SetText("Texture:")
            texLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
            local texEdit = CreateSQEditBox(editor, 200, 20, { maxLetters = 200 })
            texEdit:SetPoint("TOPLEFT", editor, "TOPLEFT", 64, y)
            texEdit:SetText(entry.imageTexture or "")
            local function SaveTex(box)
                Entry().imageTexture = strtrim(box:GetText() or "")
                Changed(false)
            end
            texEdit:SetScript("OnEnterPressed", function(box) box:ClearFocus(); SaveTex(box) end)
            texEdit.onFocusLost = SaveTex
            ns.Rows.AddTooltip(texEdit, "Texture",
                "A game atlas name (for example \"bags-glow-flash\"), a texture path, or the name of an image "
                .. "file in Squizzumables' Media folder. Press Enter to apply. Empty uses the screen edge glow.")
            y = y - 28

            -- Flipbook: the texture is a sheet of frames in a grid, played by
            -- the game. A numbered sequence (name_001.png ...) can be packed
            -- into one with .claude/make-flipbook.ps1, which prints the values
            -- to enter here.
            local function NumBox(label, key, default, x, width, tip)
                local l = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                l:SetPoint("TOPLEFT", editor, "TOPLEFT", x, y - 4)
                l:SetText(label)
                l:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
                local box = CreateSQEditBox(editor, width, 20, { numeric = true, justifyH = "CENTER", maxLetters = 4 })
                box:SetPoint("LEFT", l, "RIGHT", 4, 0)
                box:SetText(tostring(entry[key] or default))
                local function Save(b)
                    Entry()[key] = tonumber(b:GetText()) or default
                    Changed(false)
                end
                box:SetScript("OnEnterPressed", function(b) b:ClearFocus(); Save(b) end)
                box.onFocusLost = Save
                ns.Rows.AddTooltip(box, label, tip)
            end
            NumBox("Frames", "imageFrames", 1, 0, 30,
                "How many frames the sheet holds. 1 is a still image; more makes it a flipbook animation.")
            NumBox("Cols", "imageCols", 1, 86, 26, "How many frames across the sheet.")
            NumBox("Rows", "imageRows", 1, 158, 26, "How many frames down the sheet.")
            NumBox("FPS", "imageFps", 12, 232, 26, "Frames per second.")
            y = y - 26
            NumBox("Frame W", "imageFrameW", 0, 0, 36,
                "Width of one frame in the sheet, in pixels. 0 works it out for a game atlas; give it for your own file.")
            NumBox("H", "imageFrameH", 0, 98, 36, "Height of one frame in the sheet, in pixels.")
            local loopCb = CreateSQCheckbox(editor, "Loop", function(checked)
                Entry().imageLoop = checked
                Changed(false)
            end)
            loopCb:SetPoint("TOPLEFT", editor, "TOPLEFT", 190, y + 2)
            loopCb:SetChecked(entry.imageLoop ~= false)
            ns.Rows.AddTooltip(loopCb, "Loop", "Repeat the animation for as long as the buff is up, instead of playing it once.")
            y = y - 30
        end

        local c = entry.imageColor or {}
        local picker = ns.CreateSQColorPicker(editor, "Colour", c.r or 1, c.g or 1, c.b or 1, 1,
            function(r, g, b)
                Entry().imageColor = { r = r, g = g, b = b }
                BH:SaveSettings()
                BH:RefreshBuffImagesSoon()
            end)
        picker:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
        ns.Rows.AddTooltip(picker, "Colour", "Tint for the image. The screen edge glow is white, so this is its colour.")

        local fillCb = CreateSQCheckbox(editor, "Fill the screen", function(checked)
            Entry().imageFill = checked
            if checked and BH.MovingBuffImage(spellID) then BH:MoveBuffImage(spellID) end
            Changed(true)
        end)
        fillCb:SetPoint("TOPLEFT", editor, "TOPLEFT", 190, y)
        fillCb:SetChecked(entry.imageFill ~= false)
        ns.Rows.AddTooltip(fillCb, "Fill the screen",
            "Stretch the image over the whole screen, behind your interface -- right for an edge glow. Unticked, "
            .. "it is a square with its own position and size, above the interface; place it with Move.")
        y = y - 30

        local alpha = CreateSQSlider(editor, "Opacity %", 200, 5, 100, 5)
        alpha:SetValue(math.floor((entry.imageAlpha or 0.8) * 100 + 0.5))
        alpha:SetAfterValueChanged(function(v)
            Entry().imageAlpha = v / 100
            BH:SaveSettings()
            BH:RefreshBuffImagesSoon()
        end)
        alpha:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
        y = y - 46

        if entry.imageFill == false then
            local size = CreateSQSlider(editor, "Size", 200, 50, 800, 10)
            size:SetValue(entry.imageSize or 200)
            size:SetAfterValueChanged(function(v)
                Entry().imageSize = v
                BH:SaveSettings()
                BH:RefreshBuffImagesSoon()
                -- Resize the Move handle too, if it is out.
                if BH.MovingBuffImage(spellID) and previewFrame then previewFrame:SetSize(v, v) end
            end)
            size:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
            y = y - 46

            local move = CreateSQButton(editor, BH.MovingBuffImage(spellID) and "Done" or "Move", 70, 22)
            move:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
            move:SetScript("OnClick", function()
                BH:MoveBuffImage(spellID)
                BH:RebuildBuffSoundEditor()
            end)
            ns.Rows.AddTooltip(move, "Move",
                "Show this image as a box you can drag into place, then click Done. Each image has its own "
                .. "position, separate from the others and from the lust alert.")
            y = y - 30
        end
    end

    editor:SetHeight(math.abs(y) + 4)
    if self.kelBuffPage and self.kelBuffEditorTop then
        self.kelBuffPage:SetHeight(self.kelBuffEditorTop + editor:GetHeight() + 32)
    end
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
                -- Only for a freshly applied aura -- see TriggerAge. nil means
                -- the age is unknowable, and fires as it always did.
                local age = TriggerAge(alert)
                if age == nil or age <= FRESH_TRIGGER_WINDOW then
                    ShowAlert(alert)
                end
            end
            alertWasActive[id] = now
        else
            -- A disabled alert resets. Switching one on while its trigger is
            -- already up used to fire it straight away; with the freshness
            -- check it only does so if that aura is new. The Test button is
            -- the way to check an alert is wired up.
            alertWasActive[id] = false
        end
    end
end





-- ============================================================================
-- Settings tab: "Just For Kel"
-- ============================================================================

function BH:BuildJustForKelTab(parent)
    -- Three unrelated things shared this page: the lust alert, the buff sound
    -- grid and the death tally. `content` is reassigned at each boundary below.
    --
    -- The alert and its frame are one sub-tab, not two. They are the same
    -- feature -- what fires and what it looks like -- and separating them meant
    -- setting up one alert across two tabs.
    local pages = ns.SubTabs.Create(parent, {
        { key = "alerts",     label = "Lust Alert" },
        { key = "buffsounds", label = "Buff Alerts" },
        { key = "deaths",     label = "Death Tally" },
    })

    local content = pages.alerts
    ns.Rows.currentSection = content.section

    local leftPad = 14
    local yOffset = -14

    local lustNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lustNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    lustNote:SetWidth(372)
    lustNote:SetJustifyH("LEFT")
    lustNote:SetWordWrap(true)
    lustNote:SetText("A full-screen image and a sound when any lust effect wears off. For a sound or an image on your own buffs, see Buff Alerts.")
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
    ns.Rows.AddTooltip(lSndLoopCb, "Loop sound",
        "Repeat the alert sound while the alert is on screen.\n\n"
     .. "Only for SHORT sounds. Each repeat starts a new copy of the sound on top of the ones "
     .. "still playing, so a long track (the bundled lust tracks run about 40 seconds) stacks "
     .. "up many copies at once. That drowns everything out, and in a busy fight the game "
     .. "runs out of sound channels and starts cutting sounds off, the alert's included.")

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
    yOffset = yOffset - 24

    -- Always shown rather than only while the box is ticked: the warning is
    -- most useful BEFORE someone turns it on with a 40 second track.
    local lSndLoopWarn = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lSndLoopWarn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 4, yOffset)
    lSndLoopWarn:SetWidth(372)
    lSndLoopWarn:SetJustifyH("LEFT")
    lSndLoopWarn:SetTextColor(1, 0.7, 0.3)
    lSndLoopWarn:SetText("Loop short sounds only - looping a long track stacks copies of it and can get sounds cut off in busy fights.")
    yOffset = yOffset - 28

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
    --
    -- A subsection of Lust Alert rather than a sub-tab of its own: it is how
    -- that one alert looks, so splitting them put two halves of the same
    -- setting behind different tabs.
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

    -- "Lock alert image position" used to live here. The alert is click-through
    -- unconditionally now, so the checkbox had nothing left to control: it is
    -- Unlock Frames that makes the image draggable, and it always did override
    -- this setting anyway. Removed rather than left as a control that does
    -- nothing, and settings.kelAlertLocked went with it. Old profiles may still
    -- carry the key; nothing reads it, which is harmless, so there is nothing
    -- for a migration to repair.

    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.buffsounds
    ns.Rows.currentSection = content.section
    yOffset = -14
    do
        -- No heading here any more: the sub-tab is called Buff Sounds, and
        -- naming the section twice on the same screen is what this tidy-up was
        -- getting rid of.
        local bsNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bsNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        bsNote:SetWidth(372)
        bsNote:SetJustifyH("LEFT")
        bsNote:SetWordWrap(true)
        bsNote:SetText("Your spec's buffs. Click one to give it a sound when it lands or drops, and an image that shows for as long as it is up. Both are handled by the game itself, so they work in combat too.")
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
            -- The editor's height follows what the selected buff has turned
            -- on (the image options add rows), so it resizes this page itself
            -- after every rebuild -- sized once here, the new rows were cut off.
            self.kelBuffPage = content
            self.kelBuffEditorTop = math.abs(yOffset)
            self:RebuildBuffSoundEditor()
            yOffset = yOffset - (editor:GetHeight() + 12)
        end
    end

    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.deaths
    ns.Rows.currentSection = content.section
    yOffset = -14

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

    content:SetHeight(math.abs(yOffset) + 20)
    ns.Rows.currentSection = nil

    -- Only ever read as "has this tab been built yet", so which page it points
    -- at does not matter -- but the first one is the honest answer, and leaving
    -- it as whatever `content` happened to be at the end of the function would
    -- silently follow any future re-ordering of the sub-tabs.
    self.kelTabContent = pages.alerts

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


