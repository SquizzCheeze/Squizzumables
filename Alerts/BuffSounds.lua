-- Alerts/BuffSounds.lua
-- Buff sounds: registering C_UnitAuras.AddAuraSound for the configured buffs
-- (deferred through BH.Gate while blocked), the grid-ID to aura-ID aliases,
-- merging and unmerging the CDM's buff entries, and /sq buffsounds.
--
-- Moved out of Squizzumables_SpellAlerts.lua unchanged in 2.0 phase 2; see
-- Alerts/Kelerts.lua for how the Alerts/ files share names.

local addonName, ns = ...
local BH = ns.BH

local A = ns.Alerts

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

-- ----------------------------------------------------------------------------
-- Aura ID aliases. A grid icon is ONE spell ID, but the buff it stands for can
-- arrive under another: the Cooldown Manager hands every tracked buff over
-- with an overrideSpellID and linkedSpellIDs, and the aura really is often one
-- of those (the CDM's own buff swipe needed exactly this, see
-- Squizzumables_CDM.lua). buffAliases[gridID] = { [auraID] = true, ... },
-- always including gridID itself; aliasOwner is the reverse. Filled by
-- ScanCDMBuffs and used by the images, the sounds and the Blizzard-art hiding,
-- so all three match whichever ID the buff turns up under.
-- ----------------------------------------------------------------------------
local buffAliases, aliasOwner = {}, {}
-- [CDM entry spellID] = the IDs that entry ITSELF reports (spellID, override,
-- linked) -- as opposed to buffAliases, which also holds IDs folded in or
-- learned from Blizzard's alerts. What UnmergeSeparateBuffs keeps.
local cdmOwnIDs = {}

-- A NEW alias must reach the images and sounds already built, or they keep
-- matching only the IDs known when they were built. That was the bug: images
-- built at login, before the Cooldown Manager had its data, watched only the
-- talent IDs (Infusion of Light 53576, aura 54149) and never showed, while
-- Blizzard's alert -- matched later, against the learned alias -- read
-- "hidden" (user report 2026-10-06). So a new alias schedules one full
-- re-registration, a second later; the images rebuild out of combat only,
-- and RefreshBuffImages defers that itself.
local aliasRefreshQueued = false
local function QueueAliasRefresh()
    if aliasRefreshQueued then return end
    aliasRefreshQueued = true
    C_Timer.After(1, function()
        aliasRefreshQueued = false
        if BH.RefreshAuraSoundRegistrations then BH:RefreshAuraSoundRegistrations("aura IDs learned") end
    end)
end

local seeding = false
local function AddAlias(gridID, auraID)
    if not (gridID and auraID) then return end
    local set = buffAliases[gridID]
    if not set then set = { [gridID] = true }; buffAliases[gridID] = set end
    if set[auraID] then return end
    set[auraID] = true
    aliasOwner[auraID] = aliasOwner[auraID] or gridID
    -- Only an ID that adds something to an entry already in use.
    local entry = auraID ~= gridID and BH.settings and BH.settings.buffSounds and BH.settings.buffSounds[gridID]
    if type(entry) == "table" then
        -- Remembered with the buff's settings, so after a /reload it is known
        -- before the first proc rather than learned a second into it (the
        -- one-second flash of Blizzard's art on the first proc of a session,
        -- user report 2026-10-06).
        entry.auraIDs = type(entry.auraIDs) == "table" and entry.auraIDs or {}
        entry.auraIDs[auraID] = true
        if not seeding then QueueAliasRefresh() end
    end
end

-- Load the remembered aura IDs, once, before anything matches against them,
-- and ask the client to cache the buffs' spell data so the name fallback in
-- OverlayHidden works on the very first alert of the session too.
local aliasesSeeded = false
local function SeedAliases()
    if aliasesSeeded or not (BH.settings and BH.settings.buffSounds) then return end
    aliasesSeeded = true
    seeding = true
    for gridID, entry in pairs(BH.settings.buffSounds) do
        local id = tonumber(gridID)
        if id and type(entry) == "table" then
            if type(entry.auraIDs) == "table" then
                for auraID in pairs(entry.auraIDs) do AddAlias(id, tonumber(auraID)) end
            end
            if C_Spell.RequestLoadSpellData then pcall(C_Spell.RequestLoadSpellData, id) end
        end
    end
    seeding = false
end

-- Every aura ID a grid icon matches, as a set.
-- "Also show for" (user request 2026-10-09): buffs the player has merged into
-- an icon, entry.mergedIDs = { [spellID] = true }. Blizzard lists the three
-- Howl of the Pack Leader variants (471878 / 472324 / 472325) as separate,
-- unlinked Cooldown Manager entries, and a fourth, unrelated Howl shares the
-- name, so nothing in the data can group them -- the player does. A merged
-- buff's IDs are unioned in at lookup time below rather than written into
-- buffAliases, so UnmergeSeparateBuffs (which keeps separately listed buffs
-- apart) never fights a merge the player asked for.
local function MergedInto()
    local map = {}
    for gridID, entry in pairs(BH.settings and BH.settings.buffSounds or {}) do
        local id = tonumber(gridID)
        if id and type(entry) == "table" and type(entry.mergedIDs) == "table" then
            for m in pairs(entry.mergedIDs) do map[tonumber(m)] = id end
        end
    end
    return map
end
BH.BuffMergedInto = MergedInto

local function AuraIDsFor(gridID)
    SeedAliases()
    local base = buffAliases[gridID] or { [gridID] = true }
    local entry = BH.settings and BH.settings.buffSounds and BH.settings.buffSounds[gridID]
    if not (type(entry) == "table" and type(entry.mergedIDs) == "table" and next(entry.mergedIDs)) then
        return base
    end
    local set = {}
    for a in pairs(base) do set[a] = true end
    for m in pairs(entry.mergedIDs) do
        m = tonumber(m)
        if m then
            for a in pairs(buffAliases[m] or { [m] = true }) do set[a] = true end
        end
    end
    return set
end

-- The Cooldown Manager's two buff categories (buff icons, buff bars) for the
-- current spec: what the CDM tracks, passives and procs included -- Demonic
-- Core comes from a passive and so is not in the spellbook walk below. Only
-- entries whose aura lands on the player (selfAura not false), and only real
-- spells (equip-slot trinket entries have no spellID of their own).
local function ScanCDMBuffs()
    SeedAliases()
    local out = {}
    local CV = C_CooldownViewer
    if not (CV and CV.GetCooldownViewerCategorySet and CV.GetCooldownViewerCooldownInfo) then return out end
    local cats = Enum.CooldownViewerCategory
    if not cats then return out end
    for _, cat in ipairs({ cats.TrackedBuff, cats.TrackedBar }) do
        local ok, ids = pcall(CV.GetCooldownViewerCategorySet, cat)
        if ok and type(ids) == "table" then
            for _, cdID in ipairs(ids) do
                local info = CV.GetCooldownViewerCooldownInfo(cdID)
                local spellID = info and info.spellID
                if spellID and info.isKnown and info.selfAura ~= false then
                    local own = cdmOwnIDs[spellID] or {}
                    cdmOwnIDs[spellID] = own
                    own[spellID] = true
                    AddAlias(spellID, spellID)
                    if info.overrideSpellID then
                        own[info.overrideSpellID] = true
                        AddAlias(spellID, info.overrideSpellID)
                    end
                    if type(info.linkedSpellIDs) == "table" then
                        for _, lid in ipairs(info.linkedSpellIDs) do
                            own[lid] = true
                            AddAlias(spellID, lid)
                        end
                    end
                    out[#out + 1] = spellID
                end
            end
        end
    end
    return out
end
BH.ScanCDMBuffs = ScanCDMBuffs

-- /sq cdmbuffs [name] -- unlisted; the Cooldown Manager's buff entries as it
-- reports them (category, entry, spell, override, linked IDs), filtered by
-- name. What Buff Alerts builds its icons from; written to settle whether
-- buffs that share a name are one entry or several (Howl of the Pack Leader,
-- 2026-10-09). A /run version does not fit chat's 255 characters.
function BH:PrintCDMBuffEntries(filter)
    local ok, err = pcall(function()
        local CV, cats = C_CooldownViewer, Enum.CooldownViewerCategory
        if not (CV and cats) then print("  no Cooldown Manager API") return end
        filter = filter and filter:lower() or ""
        print("|cFF00FF00Squizzumables CDM buff entries|r" .. (filter ~= "" and (" matching \"" .. filter .. "\"") or ""))
        local n = 0
        for _, cat in ipairs({ cats.TrackedBuff, cats.TrackedBar }) do
            local okS, ids = pcall(CV.GetCooldownViewerCategorySet, cat, true)
            for _, cdID in ipairs(okS and ids or {}) do
                local i = CV.GetCooldownViewerCooldownInfo(cdID)
                local name = i and i.spellID and BH.Secrets.SafeString(C_Spell.GetSpellName(i.spellID), "?") or "?"
                if i and (filter == "" or name:lower():find(filter, 1, true)) then
                    n = n + 1
                    local linked = type(i.linkedSpellIDs) == "table" and table.concat(i.linkedSpellIDs, ",") or "-"
                    print(("  %s  entry %s  spell %s  override %s  linked %s  known %s  selfAura %s"):format(
                        cat == cats.TrackedBuff and "buff" or "bar", tostring(cdID), tostring(i.spellID),
                        tostring(i.overrideSpellID), linked, tostring(i.isKnown), tostring(i.selfAura)))
                    print("      " .. name)
                end
            end
        end
        if n == 0 then print("  none") end
    end)
    if not ok then print("  |cffff4444failed:|r " .. tostring(err)) end
    print("  -- end of cdmbuffs --")
end

-- Undo name-folds that should never have happened: before 2026-10-08 two
-- Cooldown Manager buffs sharing a name were folded into one icon, and the
-- second's IDs were saved on the first's image (entry.auraIDs), so the image
-- kept answering for both. For each buff now listed separately, take its own
-- IDs back off every other icon -- except IDs that other icon's own CDM entry
-- also reports, which it may legitimately share.
local function UnmergeSeparateBuffs(ids)
    local changed = false
    local store = BH.settings and BH.settings.buffSounds or {}
    for _, x in ipairs(ids) do
        local own = cdmOwnIDs[x]
        if own then
            for g, set in pairs(buffAliases) do
                if g ~= x then
                    local keep = cdmOwnIDs[g] or {}
                    for a in pairs(own) do
                        if a ~= g and set[a] and not keep[a] then
                            set[a] = nil
                            if aliasOwner[a] == g then aliasOwner[a] = x end
                            local e = store[g]
                            if type(e) == "table" and type(e.auraIDs) == "table" then e.auraIDs[a] = nil end
                            changed = true
                        end
                    end
                end
            end
        end
    end
    if changed then QueueAliasRefresh() end
end

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
    ScanCDMBuffs()   -- fresh aliases before registering against them
    for spellID, entry in pairs(BuffSounds()) do
        local id = tonumber(spellID)
        if id and type(entry) == "table" then
            for field, trigger in pairs(triggers) do
                local path = self.ResolveSoundPath and self:ResolveSoundPath(entry[field])
                -- One registration per aura ID the icon matches: an aura has
                -- exactly one spell ID, so only one of them can ever fire.
                for auraID in pairs(path and AuraIDsFor(id) or {}) do
                    wanted = wanted + 1
                    local ok, soundID = pcall(C_UnitAuras.AddAuraSound, trigger, {
                        unitToken     = "player",
                        spellID       = auraID,
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
                        registeredAuraSounds[id .. ":" .. field .. ":" .. auraID] = soundID
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

local Gate = BH.Gate
local GATE_KEY = "buffsounds"

-- When registration has to wait: combat, or any addon restriction except
-- Map. A delve carries the Map restriction out of combat, and there the game
-- ACCEPTED every registration (`/sq buffsounds try`, user, 2026-10-15), so
-- waiting it out only left the player with no buff sounds after a /reload
-- until they left the delve. The labyrinth refusals that started all this
-- were the stuck state a relog cleared, not the map.
local function SoundsBlocked()
    if InCombatLockdown() then return "Combat" end
    local r = Gate.Restriction()
    if r ~= "Map" then return r end
end

local function DoRegistration()
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
                Gate.Defer(GATE_KEY, DoRegistration, SoundsBlocked)
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

-- Never in combat or under an addon restriction (2.0: through the Gate, which
-- holds the request and runs it once the way is clear).
--
-- Combat: AddAuraSound is protected and refused mid-fight, and the
-- C_Timer.After deferral below does not help -- timers still fire in combat
-- (1.66). Restrictions: Encounter / ChallengeMode / PvPMatch / Map refuse it
-- out of combat too, and the rebuild tears working registrations down before
-- re-adding, so a refused rebuild left no buff sounds until relog (1.67, then
-- the 12.1.5 labyrinth on 1.99). Not even with nothing registered: every
-- /reload inside the labyrinth was refused once per sound, so trying only
-- produced the error.
--
-- Not Map: see SoundsBlocked above.
local function RunRegistration()
    Gate.Defer(GATE_KEY, DoRegistration, SoundsBlocked)
end

-- /sq buffsounds try: register now, ignoring an addon restriction, and say
-- what the game made of it. Exists because which restrictions actually refuse
-- AddAuraSound is not documented: the 12.1.5 labyrinth refused it, but a Map
-- restriction elsewhere may not (user report 2026-10-15). Never in combat,
-- which certainly refuses. A refusal here raises ADDON_ACTION_BLOCKED once
-- per sound -- the price of finding out, and the player asked for it.
function BH:TryAuraSoundRegistrationNow()
    if not AuraSoundsAvailable() then return end
    if InCombatLockdown() then
        print("|cFFFF5555Squizzumables:|r not in combat -- try again once it ends.")
        return
    end
    print("Squizzumables: registering buff sounds now (" .. Gate.Describe() .. ")")
    lastTrigger = "/sq buffsounds try"
    retryCount = RETRY_LIMIT   -- one honest attempt, no automatic retries
    local wanted, got = ApplyAuraSoundRegistrations(BH)
    if not wanted or wanted == 0 then
        print("  nothing to register.")
    elseif got == wanted then
        print(("|cFF55FF55  accepted: %d of %d.|r The game allows them here; tell Claude which map this is."):format(got, wanted))
    else
        print(("|cFFFF5555  refused: %d of %d accepted.|r This map really does block them; they will come back when you leave it."):format(got or 0, wanted))
    end
    if BH.kelBuffEditor and BH.RebuildBuffSoundEditor then BH:RebuildBuffSoundEditor() end
end

-- 2.0: buff events leave Cooldown Alerts (user decision 2026-10-15).
--
-- The old CDM Sounds page could also play a sound when a buff was applied or
-- removed ("Active", "On Aura Applied", "On Aura Removed"), which is exactly
-- what Buff Alerts does -- for any of your buffs, not only those in the
-- Cooldown Manager. Each such entry becomes the buff's Applied / Removed
-- sound here, once per spec's alert list (flag `buffEventsMoved`), and never
-- over a sound already set in Buff Alerts. An entry that cannot be placed
-- (no spell ID, no sound) stays where it was, and still fires.
--
-- CDM alerts are per spec, buff sounds per profile, so a moved sound now
-- plays on every spec of the profile; spell IDs are class-specific anyway.
local function MigrateBuffEventAlerts()
    if not (SquizzumablesDB and type(SquizzumablesDB.cdmData) == "table" and BH.settings) then return end
    local store = BuffSounds()
    local FIELD = { active = "added", applied = "added", removed = "removed" }
    local moved = 0
    for _, sd in pairs(SquizzumablesDB.cdmData) do
        local pending = type(sd) == "table" and type(sd.soundAlerts) == "table" and not sd.buffEventsMoved
        -- Keys onto spell IDs first (older stores used cooldownIDs). If that
        -- could not finish -- the keys may still be cooldownIDs -- leave this
        -- spec for a later login rather than guess.
        if pending and BH.cdm and BH.cdm.MigrateSoundAlerts then BH.cdm.MigrateSoundAlerts(sd) end
        if pending and sd.soundAlertsBySpell then
            for key, list in pairs(sd.soundAlerts) do
                local id = tonumber(key)
                if type(list) == "table" and id then
                    for i = #list, 1, -1 do
                        local a = list[i]
                        local field = type(a) == "table" and FIELD[a.when]
                        if field and a.sound and a.sound ~= "None" then
                            local e = store[id] or { channel = "Master" }
                            store[id] = e
                            if not e[field] then e[field] = a.sound end
                            table.remove(list, i)
                            moved = moved + 1
                        end
                    end
                    if #list == 0 then sd.soundAlerts[key] = nil end
                end
            end
            sd.buffEventsMoved = true
        end
    end
    if moved > 0 then
        BH:SaveSettings()
        print(("|cFF00FF00Squizzumables:|r moved %d buff sound%s to their buff in CDM Alerts.")
            :format(moved, moved == 1 and "" or "s"))
    end
end

---@param trigger string? label for /sq buffsounds, naming what asked for this
function BH:RefreshAuraSoundRegistrations(trigger)
    MigrateBuffEventAlerts()
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


-- Reminder buttons hold their state while blocked too (BH:UpdateButtons);
-- rebuild them as soon as the way is clear rather than on the next aura change.
Gate.OnChange(function()
    if not Gate.Blocked() and BH.ScheduleUpdateButtons then BH:ScheduleUpdateButtons() end
end)

-- Did the client accept this spell's registration? Read by the tab, so a
-- refusal is visible rather than silently doing nothing.
function BH.BuffSoundRegistered(spellID, field)
    -- Keys are "<grid ID>:<field>:<aura ID>"; any alias accepted counts.
    local prefix = tonumber(spellID) .. ":" .. field .. ":"
    for key in pairs(registeredAuraSounds) do
        if key:sub(1, #prefix) == prefix then return true end
    end
    return false
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
    print("  now: " .. Gate.Describe())
    if Gate.IsDeferred(GATE_KEY) then
        print("  a rebuild is waiting for combat or the restriction to end")
    end

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
            :format(r.got, r.wanted, r.attempt, tostring(r.trigger),
                GetTime() - (r.when or GetTime())))
        print("|cFFFF5555  Retrying automatically. If this persists, another addon is likely")
        print("  tainting the protected path -- check a BugGrabber traceback for the addon named.|r")
    else
        print("  no refusals since the last successful rebuild")
    end
end

-- For the later Alerts/ files (see Alerts/Kelerts.lua).
A.BuffSounds           = BuffSounds
A.aliasOwner           = aliasOwner
A.cdmOwnIDs            = cdmOwnIDs
A.AddAlias             = AddAlias
A.SeedAliases          = SeedAliases
A.MergedInto           = MergedInto
A.AuraIDsFor           = AuraIDsFor
A.ScanCDMBuffs         = ScanCDMBuffs
A.UnmergeSeparateBuffs = UnmergeSeparateBuffs
