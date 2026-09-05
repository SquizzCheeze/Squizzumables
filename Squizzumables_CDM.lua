--[[
    Squizzumables Cooldown Manager Module
    Creates proxy icon frames driven by Blizzard's Cooldown Viewer spell data.
    Does NOT reparent or modify Blizzard's CDM frames â€” avoids taint entirely.

    Inspired by ArcUI's CDM Module.

    Architecture (WoW Midnight 12.0+):
    - Discovers cooldowns via pure C_CooldownViewer API â€” never touches Blizzard CDM frame state.
    - Creates our own proxy frames with icon textures and cooldown sweep widgets.
    - Drives cooldown sweeps via SetCooldownFromDurationObject(C_Spell.GetSpellCooldownDuration()).
    - Tracks active buff state by hooking Blizzard CDM buff frames (read-only via hooksecurefunc â€” taint-safe).
    - Reads active buff state from each viewer item's IsActive(), which is real aura state.
      Never IsShown() -- see the note on ScanBlizzardBuffState for why that was wrong.
    - Queues container mutations during InCombatLockdown(), flushes on PLAYER_REGEN_ENABLED.
]]
---@diagnostic disable: undefined-global

local addonName, ns = ...
local BH = ns.BH

-- Shared UI constructors, defined in Squizzumables.lua which loads before this.
local CreateSQButton   = ns.CreateSQButton
local CreateSQEditBox  = ns.CreateSQEditBox
local CreateSQSlider   = ns.CreateSQSlider
local CreateSQCheckbox = ns.CreateSQCheckbox
local CreateSQDropdown = ns.CreateSQDropdown
local CreateSQDivider  = ns.CreateSQDivider
local CreateSQColorPicker = ns.CreateSQColorPicker

-- ============================================================================
-- Constants
-- ============================================================================

local CDM_VIEWERS = {
    { global = "EssentialCooldownViewer",  category = 0, viewerType = "cooldown" },
    { global = "UtilityCooldownViewer",    category = 1, viewerType = "utility" },
}

local DEFAULT_ICON_SIZE = 36
local DEFAULT_SPACING = 4
local DEFAULT_PER_ROW = 8
local RECONCILE_DEBOUNCE = 0.15
local SPEC_CHANGE_DEBOUNCE = 1.0

-- Group defaults for new settings
local DEFAULT_ORIENTATION = "horizontal"   -- "horizontal" or "vertical"
local DEFAULT_GROW_DIRECTION = "rightdown" -- "rightdown", "leftdown", "rightup", "leftup"
local DEFAULT_ALPHA = 1.0
local DEFAULT_SORT = "assignment"          -- "assignment", "name", "cooldown"

-- Icon look. These were hardcoded into CreateProxyIcon until 1.69: a 1px black
-- edge, a fixed 0.07 texture crop and no background at all. They are per-group
-- so one group can be a chunky class-coloured row of cooldowns and another a
-- small plain one, which is the point of having groups.
-- The three groups that exist without the player making anything, mirroring
-- Blizzard's own Cooldown Manager categories.
--
-- Before 1.69 every group was user-made and a cooldown showed nothing at all
-- unless it had been explicitly assigned to one, so a fresh install had no
-- groups, nothing on screen, and nothing to style. These are created per spec,
-- cannot be renamed or deleted, and every discovered cooldown falls back to the
-- one matching its viewer type. Custom groups are unchanged and still take
-- priority: an explicit assignment always wins over this fallback.
local BUILTIN_GROUPS = {
    { name = "Essential", viewerType = "cooldown", defaultY = -140 },
    { name = "Utility",   viewerType = "utility",  defaultY = -185 },
    { name = "Buffs",     viewerType = "buff",     defaultY = -230 },
}

local BUILTIN_FOR_VIEWERTYPE = {}
for _, b in ipairs(BUILTIN_GROUPS) do BUILTIN_FOR_VIEWERTYPE[b.viewerType] = b.name end

local DEFAULT_BORDER_THICKNESS = 1
local DEFAULT_BORDER_COLOR     = { 0, 0, 0, 0.9 }
local DEFAULT_ICON_ZOOM        = 0.07   -- fraction cropped from each edge
local DEFAULT_BG_COLOR         = { 0.08, 0.08, 0.08, 0.6 }

-- Combat state tracking
local isInCombat = InCombatLockdown()

-- ============================================================================
-- Module State
-- ============================================================================

local cdmModule = {}
BH.cdm = cdmModule

-- Runtime group data: { [groupName] = { container, members = { [cdID] = proxy } } }
cdmModule.groups = {}
-- Free icons: { [cooldownID] = proxy }
cdmModule.freeIcons = {}
-- Registry: { [cooldownID] = { spellID, viewerType, managed } }
cdmModule.registry = {}
-- Proxy frames we created: { [cooldownID] = proxyFrame }
cdmModule.proxyFrames = {}
-- Pending container mutations (combat-deferred)
cdmModule.pendingMutations = {}
-- Active buff cooldown tracking (populated by hooking Blizzard CDM buff frames)
cdmModule.activeBuffCooldowns = {}
-- Every cooldown the Blizzard buff viewers carry, active or not. Distinguishing
-- "the viewer says this is inactive" from "the viewer has never heard of this"
-- is what lets the sound alerts tell a real aura-removed transition from an
-- unreadable one in combat.
cdmModule.knownBuffCooldowns = {}
-- Per-cooldown sound state trackers for spells NOT in a named group
cdmModule.soundTrackers = {}

-- Spec key for per-spec saves
local function GetSpecKey()
    local _, _, classID = UnitClass("player")
    local specIndex = GetSpecialization() or 1
    return classID .. "_" .. specIndex
end

-- ============================================================================
-- Saved Data Access
-- ============================================================================

-- Get or create the CDM saved data for the current spec
local function GetSpecData()
    if not SquizzumablesDB then return nil end
    if not SquizzumablesDB.cdmData then
        SquizzumablesDB.cdmData = {}
    end
    local key = GetSpecKey()
    if not SquizzumablesDB.cdmData[key] then
        SquizzumablesDB.cdmData[key] = {
            groups = {},            -- { [groupName] = { cooldownIDs = {}, position = {x,y}, iconSize = 36, perRow = 8, locked = false } }
            freeIcons = {},         -- { [cooldownID] = { x, y, iconSize } }
            assignments = {},       -- { [cooldownID] = groupName or "FREE" }
        }
    end
    return SquizzumablesDB.cdmData[key]
end

-- Get or create the per-spec CDM per-spell sound alerts table.
local function GetCDMSoundAlerts()
    if not SquizzumablesDB then return {} end
    if not SquizzumablesDB.cdmData then SquizzumablesDB.cdmData = {} end
    local key = GetSpecKey()
    if not SquizzumablesDB.cdmData[key] then
        SquizzumablesDB.cdmData[key] = { groups = {}, freeIcons = {}, assignments = {} }
    end
    local sd = SquizzumablesDB.cdmData[key]
    if not sd.soundAlerts then sd.soundAlerts = {} end
    -- Fold any cooldownID-keyed leftovers onto spellIDs before handing the
    -- table out, so every caller sees one entry per spell. Defined further
    -- down (it needs SpellIDForCooldown), hence the module-table lookup.
    if cdmModule.MigrateSoundAlerts then cdmModule.MigrateSoundAlerts(sd) end
    return sd.soundAlerts
end

-- ============================================================================
-- Active Buff Tracking â€” Hook Blizzard's CDM buff frames (read-only, taint-safe)
-- Follows the same approach as CooldownManagerCentered:
-- hooksecurefunc on OnActiveStateChanged / OnUnitAuraAddedEvent / OnUnitAuraRemovedEvent
-- ============================================================================

-- Forward declarations (defined later in the file)
local UpdateAllProxyCooldowns
-- Forward-declared: LayoutBorrowedBuffIcons calls these well above the point
-- where they are defined, and a plain `local function` further down would be
-- nil there rather than an error at load. That is not something the linter can
-- catch -- a nil upvalue is valid Lua until it is called -- so anything used by
-- the borrowed-buff layout belongs in this list.
local GroupAlpha
local ApplyBarBackground
local ApplyKeybindText

-- The two buff-type CDM viewers: category 2 = buff icons, category 3 = tracked bars
local BUFF_VIEWERS = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

-- Populate activeBuffCooldowns from the Blizzard buff viewers.
--
-- Active state comes from the viewer item's IsActive(), which reports real aura
-- state, and NEVER from IsShown(). A buff viewer item stays shown while the aura
-- is inactive unless the player has turned on Blizzard's "Hide When Inactive"
-- edit-mode option, and that is off by default -- so reading IsShown() made every
-- tracked buff look permanently active for most players. That is why the CDM
-- sound alerts never fired correctly: the "buff applied" and "buff removed"
-- transitions could never happen, because the state never changed.
--
-- IsShown() is kept only as a fallback for a client that does not expose
-- IsActive at all.
local function ScanBlizzardBuffState()
    wipe(cdmModule.activeBuffCooldowns)
    wipe(cdmModule.knownBuffCooldowns)
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            if ok and children then
                for _, child in ipairs(children) do
                    if child and child.cooldownID then
                        cdmModule.knownBuffCooldowns[child.cooldownID] = true
                        -- SECRET PROBE FIRST. Not just comparisons: a plain
                        -- truthiness test on a secret is a hard error too, so
                        -- `gotState and state or false` threw the moment
                        -- IsActive went secret -- which is in combat, and takes
                        -- the whole scan down with it. That is why tracked
                        -- buffs only appeared once combat ended.
                        local active = false
                        if child.IsActive then
                            local gotState, state = pcall(child.IsActive, child)
                            if gotState and not BH.Secrets.IsSecret(state) then
                                active = state and true or false
                            end
                        else
                            active = child:IsShown() and true or false
                        end
                        if active then
                            cdmModule.activeBuffCooldowns[child.cooldownID] = true
                        end
                    end
                end
            end
        end
    end
end


-- ============================================================================
-- Blizzard alert-event hook
--
-- The right way to know a cooldown changed state, and the reason the poll-based
-- detection below could never work in combat.
--
-- Blizzard's Cooldown Manager already computes exactly the transitions we care
-- about -- see CooldownViewerItemMixin in Blizzard_CooldownViewer. Every one of
-- them funnels through a single method:
--
--     function CooldownViewerItemMixin:TriggerAlertEvent(event)
--         if self.alertsByEvent then ... play the player's configured alert ...
--
-- Two properties make it the correct hook point:
--
--  1. It is called whenever the transition happens, not only when the player
--     has configured a Blizzard alert. The gating lives *inside* the function
--     (`self.alertsByEvent[event]`), so a hook sees every event even for a
--     cooldown the player has set no Blizzard alert on. The upstream condition
--     is real cooldown state -- for Available:
--         self.allowAvailableAlert = ... not self.isOnGCD
--             and spellCooldownInfo.duration > MIN_GLOBAL_RECOVERY_TIME
--             and self.cooldownEnabled
--
--  2. Blizzard's code is not subject to the secret-value restrictions that
--     apply to ours. C_Spell.GetSpellCooldown returns secret start/duration to
--     an addon in combat, which is why polling could not see a utility spell
--     come off cooldown until combat ended -- and then fired the backlog all at
--     once. Blizzard's own timers have no such problem.
--
-- So this hook replaces the poll for any cooldown that appears in one of the
-- viewers. The poll stays as the fallback for cooldowns the player has not
-- added to Blizzard's Cooldown Manager, since those have no item frame to hook.
-- ============================================================================

-- Blizzard's alert event -> the `when` value stored in our own alert entries.
local ALERT_EVENT_TO_WHEN = {}
-- Exposed so the settings UI can turn Blizzard's GetValidAlertTypes list
-- into the option values used here.
cdmModule.AlertEventToWhen = ALERT_EVENT_TO_WHEN
do
    local e = Enum and Enum.CooldownViewerAlertEventType
    if e then
        ALERT_EVENT_TO_WHEN[e.Available]     = "available"
        ALERT_EVENT_TO_WHEN[e.OnCooldown]    = "start"
        ALERT_EVENT_TO_WHEN[e.OnAuraApplied] = "applied"
        ALERT_EVENT_TO_WHEN[e.OnAuraRemoved] = "removed"
        ALERT_EVENT_TO_WHEN[e.ChargeGained]  = "chargegained"
        ALERT_EVENT_TO_WHEN[e.PandemicTime]  = "pandemic"
    end
end

-- Cooldowns whose events arrive via the hook. The poll skips these so a single
-- transition cannot play the sound twice.
cdmModule.hookDrivenCooldowns = {}
-- The same set expressed as spell IDs. Stored alerts are keyed by whatever
-- cooldownID was current when they were created, which may not be the one the
-- live viewer reports, so the poll has to ask "is this spell hook-driven?"
-- rather than "is this cooldownID hook-driven?" -- otherwise it runs alongside
-- the hook and plays the sound twice.
cdmModule.hookDrivenSpellIDs = {}
-- cooldownID -> the live Blizzard viewer item frame.
cdmModule.viewerItems = {}
-- spellID -> the buff-viewer item for it, when one exists. Kept apart from
-- cooldownForSpell because IsActive() means different things on the two: on a
-- buff item it is overridden to report the aura, but the base version is just
-- `self.cooldownID ~= nil`, i.e. permanently true.
cdmModule.buffItemForSpell = {}

-- spellID -> the cooldownID the live viewer currently uses for it. The inverse
-- of SpellIDForCooldown, and what lets code holding a spell-keyed alert find
-- the cooldown it belongs to.
cdmModule.cooldownForSpell = {}

-- cooldownID is not a stable key; spellID is.
--
-- The same spell turns up under different cooldownIDs -- between the category
-- sets, and between game builds -- so an alert saved against one ID silently
-- stops matching when the viewer reports another. /sq cdm caught exactly this:
-- alerts stored on 19409 "Hammer of Justice" and 92819 "Avenging Wrath" while
-- the live viewer items were 29350 and 29266. The same output showed Avenging
-- Wrath configured twice under two IDs, which is the same drift accumulating
-- across sessions.
--
-- So both sides are resolved to a spellID before matching. Memoised because
-- this runs from the alert hook, and the mapping does not change within a
-- session for a given ID.
local cooldownSpellIDCache = {}

local function SpellIDForCooldown(cdID)
    if not cdID then return nil end
    local cached = cooldownSpellIDCache[cdID]
    if cached ~= nil then return cached or nil end
    local info = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
               and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
    local spellID = info and BH.Secrets.SafeNumber(info.spellID, nil)
    cooldownSpellIDCache[cdID] = spellID or false
    return spellID
end
cdmModule.SpellIDForCooldown = SpellIDForCooldown

-- The key alerts are stored under: the spell, not the cooldown.
local function AlertKey(cdID)
    return SpellIDForCooldown(cdID) or cdID
end
cdmModule.AlertKey = AlertKey

-- Fold alerts stored under old cooldownIDs onto their spellID.
--
-- Alerts were originally keyed by cooldownID, which is not stable: the same
-- spell appears under different IDs between category sets and between builds.
-- The result was the same alert accumulating under several keys -- one player
-- had Avenging Wrath filed under 92819, 68661 and 29266, and Blessing of
-- Freedom under 22390 and 61107, from adding them at different times.
--
-- Reading through a resolver made those fire again but left the duplicates in
-- place, so the UI and diagnostics reported four alerts where the player had
-- created two. This consolidates them for real, dropping exact duplicates
-- (same when + type + sound).
--
-- Runs per spec, on the spec's own data, the first time that spec's alerts are
-- touched -- a cooldownID belonging to a spec you are not currently in may not
-- resolve, and marking it migrated then would strand it.
local function MigrateSoundAlerts(specStore)
    if not specStore or specStore.soundAlertsBySpell then return end
    local old = specStore.soundAlerts
    if not old then
        specStore.soundAlertsBySpell = true
        return
    end

    local merged, unresolved = {}, false
    for storedID, list in pairs(old) do
        local resolved = SpellIDForCooldown(storedID)
        if not resolved then unresolved = true end
        local key = resolved or storedID
        merged[key] = merged[key] or {}
        for _, alert in ipairs(list) do
            local dup = false
            for _, existing in ipairs(merged[key]) do
                if existing.when == alert.when and existing.type == alert.type
                   and existing.sound == alert.sound then
                    dup = true
                    break
                end
            end
            if not dup then table.insert(merged[key], alert) end
        end
    end

    -- All-or-nothing, deliberately.
    --
    -- Writing a partial result back and leaving the store un-flagged meant the
    -- next call would migrate again -- but over keys that are now spellIDs. If
    -- a spellID also happens to be a valid cooldownID it resolves to a
    -- different spell entirely, and the alerts are silently remapped or merged
    -- onto the wrong entry. A migration that can run twice over its own output
    -- has to be idempotent, and this one is not.
    --
    -- So if anything failed to resolve, leave the original data completely
    -- untouched and try again later, when the cooldown info is available.
    if unresolved then return end

    specStore.soundAlerts = merged
    specStore.soundAlertsBySpell = true
end
cdmModule.MigrateSoundAlerts = MigrateSoundAlerts

-- Alerts configured for this cooldown. Post-migration this is a plain lookup;
-- the spell-resolving fallback stays for a store that has not migrated yet.
local function CollectAlertsFor(cdID)
    local stored = GetCDMSoundAlerts()
    local key = AlertKey(cdID)
    local out = {}
    for _, a in ipairs(stored[key] or {}) do out[#out + 1] = a end
    if key ~= cdID then
        for _, a in ipairs(stored[cdID] or {}) do out[#out + 1] = a end
    end
    return out
end
cdmModule.CollectAlertsFor = CollectAlertsFor

-- Two paths can notice the same transition: the Blizzard alert hook and the
-- poll. Having one suppress the other is fragile -- it goes completely silent
-- whenever the favoured path is the one not working, which is precisely what
-- happened when the hook was assumed to cover cooldowns it had not attached to.
--
-- So both paths stay live and whichever notices first claims the alert; the
-- loser is dropped inside a short window. Keyed on spellID because the two
-- paths reach the same spell through different cooldownIDs.
local recentAlertPlays = {}
local ALERT_DEDUPE_WINDOW = 0.6

local function ClaimAlert(spellID, when)
    if not spellID or not when then return true end
    local key = spellID .. ":" .. when
    local now = GetTime()
    local last = recentAlertPlays[key]
    if last and (now - last) < ALERT_DEDUPE_WINDOW then return false end
    recentAlertPlays[key] = now
    return true
end
cdmModule.ClaimAlert = ClaimAlert

local function PlayAlertsFor(cdID, when)
    local matched = nil
    for _, alert in ipairs(CollectAlertsFor(cdID)) do
        -- Only ever one sound per event, even if the same spell ended up with
        -- alerts filed under two cooldownIDs.
        if not matched and alert.when == when and alert.type == "Sound"
           and alert.sound and alert.sound ~= "None" then
            matched = alert
        end
    end
    if not matched or not BH.PlaySound then return end
    -- Claim only once something would actually be played, so a cooldown with no
    -- alert configured never occupies the dedupe slot.
    if not ClaimAlert(SpellIDForCooldown(cdID) or cdID, when) then return end
    BH:PlaySound(matched.sound)
end

-- Hook TriggerAlertEvent on every cooldown item in every viewer.
--
-- Idempotent: items are recycled and new ones appear on spec change, so this is
-- re-run on the same events that re-run the buff hooks, and each item is tagged
-- once.
-- A spell can appear in two viewers at once: the Essential/Utility one that
-- tracks its cooldown, and the buff one that tracks the aura it applies.
-- Blessing of Freedom is both 61107 (utility) and 92824 (buff icon).
--
-- Only the cooldown-type item computes cooldown state; a buff item leaves
-- isOnActualCooldown and friends nil forever. Conflating them meant asking a
-- buff item whether its spell was on cooldown, getting nil, and reading that
-- as "unreadable" -- which is what kept the available alert silent.
local ALL_VIEWERS = {
    { name = "EssentialCooldownViewer", tracksCooldown = true  },
    { name = "UtilityCooldownViewer",   tracksCooldown = true  },
    { name = "BuffIconCooldownViewer",  tracksCooldown = false },
    { name = "BuffBarCooldownViewer",   tracksCooldown = false },
}

-- Walk a viewer's item frames.
--
-- Blizzard drives its own per-item work from `itemFramePool:EnumerateActive()`
-- (see CooldownViewerMixin:OnUpdate), and that is the authoritative set. Item
-- frames are pooled and created lazily, so a single GetChildren() sweep at load
-- can easily run before the Essential/Utility viewers have acquired any -- which
-- is why the buff alerts worked while "available" on a utility spell never did.
-- GetChildren is kept as a fallback for a client that does not expose the pool.
local function ForEachViewerItem(viewer, fn)
    if viewer.itemFramePool and viewer.itemFramePool.EnumerateActive then
        local ok = pcall(function()
            for item in viewer.itemFramePool:EnumerateActive() do fn(item) end
        end)
        if ok then return end
    end
    local ok, children = pcall(function() return { viewer:GetChildren() } end)
    if ok and children then
        for _, child in ipairs(children) do fn(child) end
    end
end

local function HookBlizzardAlertEvents()
    if not (Enum and Enum.CooldownViewerAlertEventType) then return end
    for _, viewerInfo in ipairs(ALL_VIEWERS) do
        local viewer = _G[viewerInfo.name]
        if viewer then
            ForEachViewerItem(viewer, function(child)
                if child and child.cooldownID and child.TriggerAlertEvent
                   and not child._sqzAlertHooked then
                    child._sqzAlertHooked = true
                    hooksecurefunc(child, "TriggerAlertEvent", function(item, event)
                        -- Read the ID off the item rather than closing over it:
                        -- pooled frames get recycled onto other cooldowns.
                        local cdID = item and item.cooldownID
                        local when = ALERT_EVENT_TO_WHEN[event]
                        if not cdID or not when then return end
                        if BH.suppressBuffSounds then return end
                        PlayAlertsFor(cdID, when)
                    end)
                end
                -- Refreshed every sweep, not just when the hook is first
                -- installed: a recycled frame carries _sqzAlertHooked with it
                -- onto a different cooldown, so recording ownership only at
                -- hook time left the new cooldown looking poll-driven.
                if child and child.cooldownID and child._sqzAlertHooked then
                    cdmModule.hookDrivenCooldowns[child.cooldownID] = true
                    -- Keep a handle on the live item frame. Blizzard writes its
                    -- own computed cooldown state onto these (cooldownIsActive,
                    -- availableAlertTriggerTime), and that is state we can read
                    -- when C_Spell.GetSpellCooldown gives us only secrets.
                    cdmModule.viewerItems[child.cooldownID] = child
                    do
                        local s2 = SpellIDForCooldown(child.cooldownID)
                        -- Only a cooldown-type viewer item carries usable
                        -- cooldown state. Letting a buff item claim this slot
                        -- is what made Blessing of Freedom resolve to 92824
                        -- (buff icon) rather than 61107 (utility), and every
                        -- cooldown field on a buff item is nil.
                        if s2 and viewerInfo.tracksCooldown then
                            cdmModule.cooldownForSpell[s2] = child.cooldownID
                        end
                        -- Buff items are the only ones whose IsActive()
                        -- reports aura state, so keep them separately.
                        if s2 and not viewerInfo.tracksCooldown then
                            cdmModule.buffItemForSpell[s2] = child
                        end
                    end
                    local sid = SpellIDForCooldown(child.cooldownID)
                    if sid then cdmModule.hookDrivenSpellIDs[sid] = true end
                end
            end)
        end
    end
end

-- Forget everything we worked out about which cooldownID belongs to which
-- spell, and about which item frame holds it.
--
-- These maps are caches over Blizzard's viewer pool, and every one of them goes
-- stale the moment the pool is rebuilt for a different set of cooldowns -- a
-- spec change, a talent swap, a loadout swap. They were only ever added to:
-- HookBlizzardAlertEvents refreshes the entries for frames that currently
-- exist, so the *new* spec's spells appear within a sweep, but the previous
-- spec's entries are never removed.
--
-- That is what made the sound alerts need a reload. A stale
-- cooldownForSpell[spellID] hands FireCDSounds a cooldownID the viewer has
-- since recycled onto some other spell, so the assignment lookup and the
-- viewer-item cooldown read both answer for the wrong cooldown. The entry looks
-- perfectly valid; it is just describing the spec you are no longer in.
--
-- Deliberately does NOT clear the _sqzAlertHooked / _sqzBuffHooked frame tags.
-- hooksecurefunc cannot be undone, so a frame that has been hooked stays hooked
-- for the session; clearing the tag would hook it a second time and play every
-- sound twice. The hooks read cooldownID off the item at call time precisely so
-- that recycling is safe.
--
-- soundTrackers goes too. It holds the previous on/off state per alert, and
-- carrying the old spec's state into the new one makes the next readable pass
-- treat a spell that never moved as a fresh transition -- the same spurious
-- edge the absence guards elsewhere exist to prevent.
function cdmModule:ResetResolutionMaps()
    wipe(self.cooldownForSpell)
    wipe(self.buffItemForSpell)
    wipe(self.viewerItems)
    wipe(self.hookDrivenCooldowns)
    wipe(self.hookDrivenSpellIDs)
    wipe(self.activeBuffCooldowns)
    wipe(self.knownBuffCooldowns)
    wipe(self.soundTrackers)
end

-- Mirror Blizzard's own duration object onto our matching proxy icon.
--
-- A buff's remaining time cannot be FETCHED in combat. /sq cdmbuff settled
-- that: with a perfectly readable auraInstanceID (1583) and unit ("player"),
-- C_UnitAuras.GetAuraDuration still THREW once auras went secret, because the
-- instance-id APIs hard-error on a restricted unit. There is no lookup route.
--
-- But Blizzard hands its OWN Cooldown widget a duration object every time it
-- refreshes one, and that object is opaque -- nothing has to be read out of it.
-- Catching it on the way past and passing the same object to our widget
-- reproduces the sweep exactly, with no value entering Lua. EllesmereUI hooks
-- these same two setters for the same reason.
--
-- Separate from the buff-state hooks below, and re-tried on every sweep,
-- because these frames are pooled and Blizzard builds their regions on its own
-- schedule: child.Cooldown is frequently absent the first time a frame is seen.
-- Installing this inside the one-shot _sqzBuffHooked gate meant such a frame
-- was tagged as hooked, skipped, and never given another chance -- which is
-- why the swipes were still missing after the first attempt. Idempotent via its
-- own tag, so repeating it is free.
local function MirrorBlizzardCooldown(child)
    local cdw = child.Cooldown or (child.GetCooldownFrame and child:GetCooldownFrame())
    if not cdw or cdw._sqMirrorHooked then return end
    cdw._sqMirrorHooked = true

    -- cooldownID is read at call time rather than closed over: these frames are
    -- pooled and get recycled onto other cooldowns.
    local function MirrorTo(fn)
        return function(_, ...)
            local id = child.cooldownID
            local p = id and cdmModule.proxyFrames[id]
            if p and p.Cooldown then fn(p.Cooldown, ...) end
        end
    end

    if cdw.SetCooldownFromDurationObject then
        hooksecurefunc(cdw, "SetCooldownFromDurationObject",
            MirrorTo(function(target, durObj, ...)
                if durObj and target.SetCooldownFromDurationObject then
                    target:SetReverse(true)
                    target:SetCooldownFromDurationObject(durObj, ...)
                end
            end))
    end

    hooksecurefunc(cdw, "SetCooldown",
        MirrorTo(function(target, start, duration, ...)
            -- Passed straight through: widget setters accept secret values,
            -- and it is comparing or doing arithmetic on them that throws.
            target:SetReverse(true)
            target:SetCooldown(start, duration, ...)
        end))
end
cdmModule.MirrorBlizzardCooldown = MirrorBlizzardCooldown

-- Are we borrowing Blizzard's buff icons rather than proxying them?
local function BorrowBuffIcons()
    return not (BH.settings and BH.settings.cdmProxyBuffIcons)
end

-- Lay Blizzard's own buff item frames out inside one of our group containers.
--
-- This is the whole point of the borrowed approach: the frames stay parented to
-- Blizzard's viewer and Blizzard keeps driving their cooldown, icon, stacks and
-- active state, so everything works in combat exactly as it does for Blizzard.
-- All we own is where they sit. Growth direction, spacing, per-row and icon
-- size come from the group, so the layout options still apply.
--
-- Re-applied from the poll, because Blizzard re-anchors these on its own layout
-- pass and would otherwise pull them back to its bar.
-- A stand-in icon for a tracked buff that is not currently up.
--
-- Ours, not Blizzard's: Blizzard's frame is hidden because it has no aura bound
-- to it, so showing it would draw whatever stale state it last held. One per
-- cooldownID, kept on the group and reused.
function cdmModule:GetBuffPlaceholder(group, cdID, groupData)
    group.placeholders = group.placeholders or {}
    local ph = group.placeholders[cdID]
    if not ph then
        ph = CreateFrame("Frame", nil, group.container)
        ph:SetFrameStrata("MEDIUM")
        ph.isPlaceholder = true
        ph.cooldownID = cdID
        local tex = ph:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        ph.Icon = tex
        group.placeholders[cdID] = ph
    end

    -- Texture resolved lazily and remembered: it can be unavailable or secret
    -- early in a login, the same way proxy icons could come up blank.
    if not ph._iconSet then
        local sid = SpellIDForCooldown(cdID)
        local t = sid and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
        if t and not BH.Secrets.IsSecret(t) then
            ph.Icon:SetTexture(t)
            ph._iconSet = true
        end
    end

    local zoom = groupData.iconZoom or DEFAULT_ICON_ZOOM
    ph.Icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
    ph.Icon:SetDesaturated(groupData.desaturateInactiveBuffs ~= false)
    ph:SetAlpha(groupData.inactiveBuffAlpha or 0.45)
    ph:Show()
    return ph
end

-- Hide any placeholder not used by this pass: a buff that has just come up, or
-- the whole set when Always Show Buffs is switched off.
function cdmModule:ReleaseUnusedPlaceholders(group, slots)
    if not group.placeholders then return end
    local used = {}
    for _, f in ipairs(slots) do
        if f.isPlaceholder then used[f.cooldownID] = true end
    end
    for cdID, ph in pairs(group.placeholders) do
        if not used[cdID] then ph:Hide() end
    end
end

function cdmModule:LayoutBorrowedBuffIcons(groupName)
    local group = self.groups[groupName]
    local specData = GetSpecData()
    local groupData = specData and specData.groups[groupName]
    if not group or not group.container or not groupData then return end

    local iconSize = groupData.iconSize or DEFAULT_ICON_SIZE
    local spacing  = groupData.spacing or DEFAULT_SPACING
    local perRow   = groupData.perRow or DEFAULT_PER_ROW
    local growDir  = groupData.growDirection or DEFAULT_GROW_DIRECTION

    -- Blizzard hides an inactive tracked buff itself, so the row packs down to
    -- what is really up without any active-state logic of ours -- which is the
    -- part that kept breaking before buffs were borrowed.
    --
    -- "Always Show Buffs" wants the opposite: a slot held for every tracked
    -- buff whether or not it is up. That cannot be done by un-hiding Blizzard's
    -- frame -- it is hidden precisely because it has no aura bound, so it would
    -- draw whatever stale state it last held. So an inactive buff gets a
    -- placeholder of OURS in the slot instead, which is also how EllesmereUI
    -- does it.
    local showInactive = groupData.showInactiveBuffs and true or false
    local shown, inactive = {}, {}
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            if ok and children then
                for _, child in ipairs(children) do
                    if child and child.cooldownID then
                        if child:IsShown() then
                            shown[#shown + 1] = child
                        elseif showInactive then
                            inactive[#inactive + 1] = child.cooldownID
                        end
                    end
                end
            end
        end
    end
    table.sort(shown, function(a, b) return a.cooldownID < b.cooldownID end)
    table.sort(inactive)

    -- Active first, then the placeholders, each in a stable order. Keeping the
    -- live ones together stops an icon jumping across the row every time an
    -- unrelated buff further along expires.
    local slots = {}
    for _, child in ipairs(shown) do slots[#slots + 1] = child end
    if showInactive then
        for _, cdID in ipairs(inactive) do
            slots[#slots + 1] = self:GetBuffPlaceholder(group, cdID, groupData)
        end
    end
    self:ReleaseUnusedPlaceholders(group, slots)
    shown = slots

    local centered   = (growDir == "centereddown" or growDir == "centeredup")
    local centeredUp = (growDir == "centeredup")
    local colMul, rowMul = 1, -1
    if not centered then
        if growDir == "leftdown" then colMul, rowMul = -1, -1
        elseif growDir == "rightup" then colMul, rowMul = 1, 1
        elseif growDir == "leftup" then colMul, rowMul = -1, 1 end
    end

    local cols = math.max(1, math.min(#shown, perRow))
    local rows = math.max(1, math.ceil(math.max(#shown, 1) / perRow))
    local fullW = cols * (iconSize + spacing) - spacing
    local fullH = rows * (iconSize + spacing) - spacing

    local col, row = 0, 0
    for _, child in ipairs(shown) do
        child:SetSize(iconSize, iconSize)
        child:ClearAllPoints()
        -- Works on a borrowed Blizzard frame as well as a placeholder: adding a
        -- font string to one is an ordinary region write, not a protected call.
        ApplyKeybindText(child, SpellIDForCooldown(child.cooldownID), groupData)
        if centered then
            local itemsThisLine = math.min(#shown - row * perRow, perRow)
            local rowW = itemsThisLine * iconSize + (itemsThisLine - 1) * spacing
            local x = -rowW / 2 + col * (iconSize + spacing) + iconSize / 2
            local y = (iconSize / 2 + row * (iconSize + spacing)) * (centeredUp and 1 or -1)
            child:SetPoint("CENTER", group.container,
                centeredUp and "BOTTOM" or "TOP", x, y)
        else
            local anchor = "TOPLEFT"
            if colMul < 0 and rowMul < 0 then anchor = "TOPRIGHT"
            elseif colMul > 0 and rowMul > 0 then anchor = "BOTTOMLEFT"
            elseif colMul < 0 and rowMul > 0 then anchor = "BOTTOMRIGHT" end
            child:SetPoint(anchor, group.container, anchor,
                col * (iconSize + spacing) * colMul,
                row * (iconSize + spacing) * rowMul)
        end
        col = col + 1
        if col >= perRow then col = 0; row = row + 1 end
    end

    if not InCombatLockdown() then
        group.container:SetSize(fullW, fullH)
    end
    group.container:SetShown(#shown > 0)
    ApplyBarBackground(group, groupData)
    group.container:SetAlpha(GroupAlpha(groupData))
end

-- Re-anchor every borrowed group. Cheap, and driven from the poll so Blizzard's
-- own layout pass cannot leave the icons back on its bar.
function cdmModule:LayoutAllBorrowedBuffIcons()
    for groupName, group in pairs(self.groups) do
        if group.usesBlizzardIcons then
            self:LayoutBorrowedBuffIcons(groupName)
        end
    end
end

-- Install the mirror on every buff item frame that currently exists.
--
-- Deliberately separate from HookBlizzardBuffFrames and much cheaper: it only
-- walks children and tags, with no closures created for already-hooked frames.
-- Driven from the 0.2s poll so a frame the viewer acquires mid-fight is picked
-- up within a fifth of a second, rather than waiting for a reconcile that will
-- not happen until combat ends.
local function MirrorAllBuffCooldowns()
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            if ok and children then
                for _, child in ipairs(children) do
                    if child and child.cooldownID then
                        MirrorBlizzardCooldown(child)
                    end
                end
            end
        end
    end
end

-- Hook Blizzard CDM buff frames (both viewers) to track active state changes
local function HookBlizzardBuffFrames()
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            if ok and children then
                for _, child in ipairs(children) do
                    if child and child.cooldownID then
                        if not child._sqzBuffHooked then
                            child._sqzBuffHooked = true
                            local function OnBuffStateChanged()
                                ScanBlizzardBuffState()
                                UpdateAllProxyCooldowns()
                            end
                            if child.OnActiveStateChanged then
                                hooksecurefunc(child, "OnActiveStateChanged", OnBuffStateChanged)
                            end
                            if child.OnUnitAuraAddedEvent then
                                hooksecurefunc(child, "OnUnitAuraAddedEvent", OnBuffStateChanged)
                            end
                            if child.OnUnitAuraRemovedEvent then
                                hooksecurefunc(child, "OnUnitAuraRemovedEvent", OnBuffStateChanged)
                            end
                        end
                        MirrorBlizzardCooldown(child)
                    end
                end
            end
        end
    end
end

-- Is the player currently carrying this cooldown's aura?
--
-- The Blizzard buff viewer alone is not enough. It contains only the cooldowns
-- the player has chosen to show in it, while alerts are configured from the full
-- category set -- so a buff that is trackable but toggled off in Blizzard's
-- Cooldown Manager never appears in activeBuffCooldowns and its alerts could
-- never fire. Reading the player's aura directly covers that, and also covers
-- Blizzard's known bind-miss where a freshly applied aura leaves the viewer
-- item's IsActive stuck false.
--
-- Viewer first because it is a plain table lookup, and because it keeps working
-- in combat when aura reads turn secret and GetAuraBySpellID returns nothing.
-- Returns: isActive, isReadable.
--
-- The second return matters in combat. An aura that cannot be read looks
-- identical to one that is absent, and "absent" is what drives the "removed"
-- alert -- so a caller that cannot tell the two apart either fires a removal
-- alert for a buff that never went anywhere, or (if it plays safe and skips
-- everything) goes silent for the whole fight. Both have happened here.
-- Is this cooldown running, according to Blizzard's own viewer item?
--
-- Returns: isOnCooldown, isReadable.
--
-- C_Spell.GetSpellCooldown hands an addon secret startTime/duration in combat,
-- so we cannot compute this ourselves -- comparing them throws. But Blizzard's
-- CooldownViewerItemMixin already did the comparison, in untainted code, and
-- cached the answer on the item frame:
--
--     self.cooldownIsActive = endTime > timeNow;
--     self.isOnActualCooldown = not self.isOnGCD and self.cooldownIsActive;
--
-- Reading a plain boolean it left behind is not the same as doing arithmetic on
-- secrets. Whether the client marks those derived fields secret too is exactly
-- what the readability check below establishes -- if it does, we degrade to
-- "cannot tell" and nothing is worse than before.
local function CooldownActiveFromViewer(cdID, spellID)
    -- Always go through the spell's cooldown-type item. The cooldownID an alert
    -- arrives with may belong to the buff viewer's copy of the same spell, and
    -- a buff item leaves every cooldown field nil forever.
    local item
    local sid = spellID or (cdID and SpellIDForCooldown(cdID))
    local cooldownID = sid and cdmModule.cooldownForSpell[sid]
    if cooldownID then item = cdmModule.viewerItems[cooldownID] end
    if not item and cdID then item = cdmModule.viewerItems[cdID] end
    if not item then return false, false end

    local active = item.isOnActualCooldown
    if active == nil then active = item.cooldownIsActive end
    if active == nil then return false, false end

    -- A secret value here *is* the answer.
    --
    -- Blizzard computes `cooldownIsActive = endTime > timeNow`, where endTime
    -- comes from startTime + duration. While a cooldown is running those are
    -- secret, so the derived boolean is secret too. When the spell is ready
    -- there is no running cooldown to derive from and the field reads as a
    -- plain false.
    --
    -- Observed directly, in combat, in the same pass:
    --     Hammer of Justice   (ready)       isOnActualCooldown = false
    --     Blessing of Freedom (on cooldown) isOnActualCooldown = SECRET
    --
    -- So "unreadable" and "on cooldown" coincide, and the secret->false
    -- transition is exactly the moment the spell becomes available. Treating
    -- secret as "not readable" instead threw that signal away and was why the
    -- available alert could never fire in combat.
    --
    -- Failure direction is safe: if a value were ever secret for some unrelated
    -- reason while the spell was ready, the alert would be late, never spurious.
    if BH.Secrets.IsSecret(active) then return true, true end

    return active and true or false, true
end
cdmModule.CooldownActiveFromViewer = CooldownActiveFromViewer

local function CooldownAuraActive(cdID, spellID)
    if cdID and cdmModule.activeBuffCooldowns[cdID] then return true, true end

    -- Only a *buff* item's IsActive() reports the aura.
    --
    -- CooldownViewerBuffItemMixin overrides ShouldBeActive to check the aura,
    -- but the base CooldownViewerItemMixin version is just
    --     return self.cooldownID ~= nil;
    -- so on an Essential/Utility item IsActive() is permanently true. Reading it
    -- there made hasAura always true, which made isActive always true, which
    -- meant the "available" alert could never fire -- in or out of combat.
    local sid = spellID or (cdID and SpellIDForCooldown(cdID))
    local buffItem = sid and cdmModule.buffItemForSpell[sid]
    if buffItem and buffItem.IsActive then
        -- IsSecret before `~= nil`, not after: testing a secret against nil is
        -- itself a hard error, so the old order threw in exactly the case the
        -- guard was written to handle.
        local ok, active = pcall(buffItem.IsActive, buffItem)
        if ok and not BH.Secrets.IsSecret(active) and active ~= nil then
            -- Blizzard tracks these on "player" and "target", so this covers a
            -- buff placed on the current target as well as on the player.
            return active and true or false, true
        end
    end

    -- The viewer is authoritative for anything it carries, and it keeps working
    -- in combat because it reads Blizzard's own frame state, not the aura API.
    -- So "the viewer knows this cooldown and did not mark it active" is a real
    -- negative, not a failed read.
    if cdID and cdmModule.knownBuffCooldowns[cdID] then return false, true end
    -- Not in the viewer: the only source left is a direct aura read, which
    -- returns nothing once auras go secret. Say so rather than reporting a
    -- confident "not active".
    if BH.Secrets.AurasAreSecret() then return false, false end
    if spellID and BH.Secrets.GetAuraBySpellID("player", spellID) then return true, true end
    return false, true
end

-- ============================================================================
-- Cooldown Discovery â€” Pure C_CooldownViewer API, no frame interaction.
-- ============================================================================

-- What reconcile walks. Wider than CDM_VIEWERS, which is only the two
-- cooldown-type viewers: the buff categories have to be here too, or the
-- built-in Buffs group has nothing to hold and sits permanently empty.
-- Categories 2 and 3 both map to "buff" -- 2 is the buff icons, 3 is the
-- tracked bars (procs like Beast Cleave), and Blizzard splits them across two
-- viewers while this addon treats them as one group.
local DISCOVER_CATEGORIES = {
    { category = 0, viewerType = "cooldown" },
    { category = 1, viewerType = "utility"  },
    { category = 2, viewerType = "buff"     },
    { category = 3, viewerType = "buff"     },
}

local function DiscoverCooldowns()
    local discovered = {}
    -- One ability, two categories.
    --
    -- The same ability is listed under a cooldown category for its cooldown and
    -- a buff category for the aura it applies, under DIFFERENT cooldownIDs AND
    -- different spellIDs -- Blessing of Freedom is 61107 in Utility and 92824
    -- in BuffIcon. Nothing keyed on either ID catches that, so the buff pass
    -- brought a second copy of half the Essential and Utility abilities into
    -- the Buffs group. Name is the only thing they share, which is why
    -- GetAvailableBuffCooldowns has always deduplicated on it too.
    --
    -- DISCOVER_CATEGORIES is ordered cooldowns first, so the cooldown-type
    -- entry wins and the buff duplicate is dropped: the cooldown item is the
    -- one that carries the cooldown fields, and a buff item leaves them nil
    -- forever.
    -- Only across the cooldown/buff divide, NEVER within a category.
    --
    -- A spec legitimately tracks several variants of one ability under the same
    -- name: a hunter has four separate "Howl of the Pack Leader" buff entries
    -- (cooldownIDs 9712, 9713, 9714, 169029). Deduplicating on name across the
    -- board collapsed all four into one and silently dropped most of the buffs
    -- the player was tracking. Only a buff entry that duplicates a
    -- cooldown-type entry is a real duplicate.
    local seenCdSpell, seenCdName = {}, {}
    for _, viewerInfo in ipairs(DISCOVER_CATEGORIES) do
        local isCooldownType = (viewerInfo.viewerType ~= "buff")
        local catIDs = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
            and C_CooldownViewer.GetCooldownViewerCategorySet(viewerInfo.category)
        if catIDs then
            for _, cdID in ipairs(catIDs) do
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if info and info.isKnown then
                    local name = C_Spell.GetSpellName and C_Spell.GetSpellName(info.spellID)
                    name = BH.Secrets.SafeString(name, nil)
                    local isDuplicate = (not isCooldownType)
                        and (seenCdSpell[info.spellID] or (name and seenCdName[name]))
                    if not isDuplicate then
                        if isCooldownType then
                            seenCdSpell[info.spellID] = true
                            if name then seenCdName[name] = true end
                        end

                        -- Which spell IDs might carry this cooldown's aura.
                        --
                        -- A tracked buff's aura is very often NOT info.spellID:
                        -- the API hands the alternatives over as overrideSpellID
                        -- and linkedSpellIDs. Reading only spellID is why buff
                        -- icons drew no duration swipe -- the aura lookup missed
                        -- and it fell through to a spell cooldown that a
                        -- buff-only entry does not have.
                        local auraIDs = { info.spellID }
                        if info.overrideSpellID then
                            auraIDs[#auraIDs + 1] = info.overrideSpellID
                        end
                        if type(info.linkedSpellIDs) == "table" then
                            for _, lid in ipairs(info.linkedSpellIDs) do
                                auraIDs[#auraIDs + 1] = lid
                            end
                        end

                        discovered[cdID] = {
                            cooldownID = cdID,
                            spellID = info.spellID,
                            viewerType = viewerInfo.viewerType,
                            auraIDs = auraIDs,
                            hasAura = info.hasAura,
                        }
                    end
                end
            end
        end
    end
    return discovered
end

-- ============================================================================
-- Proxy Frame Creation â€” Our own frames that mirror the cooldown icon + sweep.
-- We NEVER write to Blizzard's CDM frame tables to avoid taint.
-- ============================================================================

local function CreateProxyIcon(cooldownID, spellID, iconSize)
    local proxy = CreateFrame("Frame", nil, UIParent)
    proxy:SetSize(iconSize, iconSize)
    proxy:SetFrameStrata("MEDIUM")
    proxy.spellID = spellID
    proxy.cooldownID = cooldownID

    -- Background, behind the icon. Shows through wherever the icon does not
    -- cover it, and gives a group a visible footprint when its icons are
    -- hidden-until-active. Off unless the group turns it on.
    local bgTex = proxy:CreateTexture(nil, "BACKGROUND")
    bgTex:SetAllPoints()
    bgTex:SetColorTexture(DEFAULT_BG_COLOR[1], DEFAULT_BG_COLOR[2],
                          DEFAULT_BG_COLOR[3], DEFAULT_BG_COLOR[4])
    bgTex:Hide()
    proxy.Bg = bgTex

    -- Icon texture
    local iconTex = proxy:CreateTexture(nil, "ARTWORK")
    iconTex:SetAllPoints()
    local texture = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)
    if texture and not BH.Secrets.IsSecret(texture) then
        iconTex:SetTexture(texture)
        proxy._iconSet = true
    end
    local z = DEFAULT_ICON_ZOOM
    iconTex:SetTexCoord(z, 1 - z, z, 1 - z)
    proxy.Icon = iconTex

    -- Border (1px edge using BackdropTemplate â€” does NOT cover the icon)
    -- Thickness and colour are per group, applied in ApplyProxyVisuals. What
    -- is set here is only how it looks before the first pass runs.
    local borderFrame = CreateFrame("Frame", nil, proxy, "BackdropTemplate")
    borderFrame:SetPoint("TOPLEFT", -DEFAULT_BORDER_THICKNESS, DEFAULT_BORDER_THICKNESS)
    borderFrame:SetPoint("BOTTOMRIGHT", DEFAULT_BORDER_THICKNESS, -DEFAULT_BORDER_THICKNESS)
    borderFrame:SetBackdrop({
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = DEFAULT_BORDER_THICKNESS,
    })
    borderFrame:SetBackdropBorderColor(DEFAULT_BORDER_COLOR[1], DEFAULT_BORDER_COLOR[2],
                                       DEFAULT_BORDER_COLOR[3], DEFAULT_BORDER_COLOR[4])
    proxy.Border = borderFrame

    -- Cooldown sweep widget
    local cd = CreateFrame("Cooldown", nil, proxy, "CooldownFrameTemplate")
    cd:SetAllPoints()
    cd:SetDrawSwipe(true)
    cd:SetDrawEdge(true)
    proxy.Cooldown = cd

    -- Stack count text (bottom-right, like Blizzard buff frames)
    local countText = proxy:CreateFontString(nil, "OVERLAY")
    countText:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    countText:SetPoint("BOTTOMRIGHT", proxy, "BOTTOMRIGHT", -1, 1)
    countText:SetJustifyH("RIGHT")
    countText:SetText("")
    proxy.Count = countText

    -- Glow frame (ActionButton glow)
    local glow = CreateFrame("Frame", nil, proxy)
    glow:SetAllPoints()
    proxy.GlowFrame = glow
    proxy._glowShowing = false

    return proxy
end

local function UpdateProxyCooldown(proxy)
    if not proxy or not proxy.spellID or not proxy.Cooldown then return end

    -- Buff duration, the only way that survives combat.
    --
    -- An aura's remaining time cannot be computed in combat: the fields are
    -- secret, and it cannot even be looked up, because GetPlayerAuraBySpellID
    -- returns nil for a secret aura and no aura filter accepts a spell ID
    -- (checked against the current generated docs, not just the local copy).
    --
    -- The way through is not to look the aura up at all. Blizzard's own buff
    -- viewer item frame records which aura instance it bound, as
    -- auraInstanceID + auraDataUnit, and those are ordinary fields on a frame
    -- we already track. Hand that instance to C_UnitAuras.GetAuraDuration and
    -- it returns a duration object -- an opaque handle the Cooldown widget
    -- consumes without any value ever entering Lua. Same trick as
    -- GetSpellCooldownDuration on the cooldown side.
    --
    -- This is how EllesmereUI's bars keep working in combat; it reads
    -- blzChild.auraInstanceID off the same frames.
    --
    -- The instance ID can itself be secret on an actively updating frame, so it
    -- is checked before use rather than assumed.
    if proxy.Cooldown.SetCooldownFromDurationObject and C_UnitAuras
       and C_UnitAuras.GetAuraDuration then
        for _, sid in ipairs(proxy.auraSpellIDs or { proxy.spellID }) do
            local item = cdmModule.buffItemForSpell[sid]
            local iid = item and item.auraInstanceID
            local aunit = item and item.auraDataUnit
            if iid and aunit and not BH.Secrets.HasAnySecret(iid, aunit) then
                local ok, durObj = pcall(C_UnitAuras.GetAuraDuration, aunit, iid)
                if ok and durObj then
                    proxy.Cooldown:SetReverse(true)
                    proxy.Cooldown:SetCooldown(0, 0)
                    proxy.Cooldown:SetCooldownFromDurationObject(durObj)
                    if proxy.Count and C_UnitAuras.GetAuraApplicationDisplayCount then
                        -- Returns a preformatted string, so the stack count
                        -- needs no comparison either.
                        local sok, txt = pcall(C_UnitAuras.GetAuraApplicationDisplayCount,
                                               aunit, iid, 2)
                        proxy.Count:SetText((sok and type(txt) == "string") and txt or "")
                    end
                    return
                end
            end
        end
    end

    -- Check if this spell has an active buff on the player.
    --
    -- Try every ID the cooldown might carry its aura under, not just spellID:
    -- for a tracked buff the aura is frequently a different spell entirely, and
    -- the API says so via overrideSpellID and linkedSpellIDs. Missing that is
    -- why buff icons drew no swipe -- the lookup found nothing and fell through
    -- to a spell cooldown that a buff-only entry does not have.
    local auraData
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        for _, sid in ipairs(proxy.auraSpellIDs or { proxy.spellID }) do
            auraData = C_UnitAuras.GetPlayerAuraBySpellID(sid)
            if auraData then break end
        end
    end

    -- Every field on that table can itself be secret, and this runs per proxy
    -- per pass -- in combat, which is exactly when auras go secret. Comparing
    -- or doing arithmetic on a secret value throws rather than misbehaving,
    -- which is the v1.58 crash (see CLAUDE.md). Resolve each field once through
    -- BH.Secrets; nil means unreadable, and an unreadable aura falls through to
    -- the spell-cooldown path below instead of erroring. That is the safe
    -- direction: a sweep that shows the cooldown rather than the buff.
    local auraDur = auraData and BH.Secrets.SafeAuraDuration(auraData)
    local auraExp = auraData and BH.Secrets.SafeAuraExpiration(auraData)

    if auraDur and auraExp and auraDur > 0 then
        -- Buff is active â€” show buff duration sweep instead of spell cooldown
        local startTime = auraExp - auraDur
        proxy.Cooldown:SetReverse(true)
        proxy.Cooldown:SetCooldown(startTime, auraDur)

        -- Show stack count
        if proxy.Count then
            local stacks = BH.Secrets.SafeAuraStacks(auraData)
            if stacks and stacks > 1 then
                proxy.Count:SetText(stacks)
            else
                proxy.Count:SetText("")
            end
        end
        return
    end

    -- A tracked buff's sweep belongs to the mirror; do not touch it here.
    --
    -- /sq cdmbuff showed the mirror installed and a proxy present for the
    -- active buffs, so the hook was fine -- this pass was overwriting it. It
    -- runs on a ticker, and for a buff proxy it fell through to the spell
    -- cooldown below, whose SetCooldown(0, 0) wiped the mirrored sweep within
    -- a fraction of a second of Blizzard setting it. That is why the swipe
    -- looked absent in combat and reappeared afterwards, when the readable
    -- aura path above started answering again.
    --
    -- A buff-only entry has no spell cooldown to show anyway, so there is
    -- nothing lost by leaving the widget alone.
    if proxy.viewerType == "buff" then return end

    -- No active buff â€” show normal spell cooldown
    proxy.Cooldown:SetReverse(false)
    if proxy.Count then
        -- Show spell charges if applicable.
        --
        -- Through Secrets: these fields go secret in combat like any other, and
        -- `maxCharges > 1` on a secret value throws rather than misbehaving --
        -- the same crash class as the aura reads above. Unreadable means no
        -- number rather than an error.
        local spellCharges = C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(proxy.spellID)
        local maxCharges = spellCharges and BH.Secrets.SafeNumber(spellCharges.maxCharges, nil)
        local curCharges = spellCharges and BH.Secrets.SafeNumber(spellCharges.currentCharges, nil)
        if maxCharges and curCharges and maxCharges > 1 then
            proxy.Count:SetText(curCharges)
        else
            proxy.Count:SetText("")
        end
    end

    local durationObj = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(proxy.spellID)
    if durationObj then
        proxy.Cooldown:SetCooldown(0, 0)
        proxy.Cooldown:SetCooldownFromDurationObject(durationObj)
    end
end

-- ============================================================================
-- Text placement, shared by the keybind, the charge count and the cooldown
-- countdown so all three offer the same nine positions and the same offsets.
-- ============================================================================

local TEXT_POSITION_ITEMS = {
    { text = "Top Left",      value = "TOPLEFT" },
    { text = "Top",           value = "TOP" },
    { text = "Top Right",     value = "TOPRIGHT" },
    { text = "Left",          value = "LEFT" },
    { text = "Centre",        value = "CENTER" },
    { text = "Right",         value = "RIGHT" },
    { text = "Bottom Left",   value = "BOTTOMLEFT" },
    { text = "Bottom",        value = "BOTTOM" },
    { text = "Bottom Right",  value = "BOTTOMRIGHT" },
}

-- A backdrop behind the whole group, distinct from the per-icon background.
--
-- Sized to the container plus padding, so it grows and shrinks with the row --
-- including as a Hide Until Active group packs down.
ApplyBarBackground = function(group, groupData)
    if not group or not group.container then return end
    local on = groupData.barBgEnabled and true or false
    if not on then
        if group.barBg then group.barBg:Hide() end
        return
    end
    if not group.barBg then
        local t = group.container:CreateTexture(nil, "BACKGROUND", nil, -1)
        group.barBg = t
    end
    local c = groupData.barBgColor or { 0, 0, 0, 0.4 }
    local pad = groupData.barBgPadding or 2
    group.barBg:ClearAllPoints()
    group.barBg:SetPoint("TOPLEFT", group.container, "TOPLEFT", -pad, pad)
    group.barBg:SetPoint("BOTTOMRIGHT", group.container, "BOTTOMRIGHT", pad, -pad)
    group.barBg:SetColorTexture(c[1], c[2], c[3], c[4])
    group.barBg:Show()
end

-- Anchor point to itself, so a corner tucks into that corner and the offsets
-- read the same way whichever corner is chosen.
local function PlaceText(region, frame, point, ox, oy)
    if not region then return end
    region:ClearAllPoints()
    region:SetPoint(point or "CENTER", frame, point or "CENTER", ox or 0, oy or 0)
end

-- Blizzard's countdown numbers live on a font string the C widget creates, with
-- no accessor for it, so it has to be found among the regions. Cached per
-- widget; best-effort by nature, and the position option simply does nothing if
-- a future build stops exposing it rather than erroring.
local function CooldownCountdownText(cd)
    if not cd then return nil end
    if cd._sqCountdownFS ~= nil then return cd._sqCountdownFS or nil end
    local found = false
    for _, region in ipairs({ cd:GetRegions() }) do
        if region:GetObjectType() == "FontString" then
            cd._sqCountdownFS = region
            found = true
            break
        end
    end
    if not found then cd._sqCountdownFS = false end
    return cd._sqCountdownFS or nil
end

-- Round icons. Blizzard's portrait alpha mask is the usual circular mask and
-- ships with the client, so this needs no art of our own.
local ICON_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local function ApplyIconShape(proxy, shape)
    local wantRound = (shape == "round")
    if wantRound then
        if not proxy._sqMask then
            local m = proxy:CreateMaskTexture()
            m:SetAllPoints(proxy.Icon)
            m:SetTexture(ICON_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            proxy._sqMask = m
            proxy.Icon:AddMaskTexture(m)
        end
        proxy._sqMask:Show()
    elseif proxy._sqMask then
        -- RemoveMaskTexture rather than just hiding it: a hidden mask still
        -- clips on some builds, which showed up as icons staying round after
        -- the option was switched back off.
        proxy.Icon:RemoveMaskTexture(proxy._sqMask)
        proxy._sqMask:Hide()
        proxy._sqMask = nil
    end
end

-- ============================================================================
-- Keybind text
--
-- Which key casts this spell. Harder than it sounds, and the reason this was
-- left until last.
--
-- Action slots do not carry bindings; the BUTTONS do, and which button owns a
-- slot depends on the bar. So a slot number has to be mapped back to a binding
-- command, which is the table below. Slots 13-24 are deliberately absent: that
-- is action bar page 2, which has no bindings of its own -- it borrows
-- ACTIONBUTTON1-12 when the page is active. Claiming those would report a key
-- that does nothing on the page you are actually looking at.
--
-- The map is also rebuilt on binding and action-bar changes only, never on a
-- page change, and prefers the LOWEST matching slot. That is this addon's
-- version of EllesmereUI's "stable keybinds": stealth, druid forms, dragonriding
-- and vehicles all swap the visible page underneath you, and a keybind that
-- rewrites itself every time you shapeshift is worse than one that is
-- occasionally a page out of date.
-- ============================================================================

local KEYBIND_BARS = {
    { first = 1,  cmd = "ACTIONBUTTON%d" },
    { first = 25, cmd = "MULTIACTIONBAR3BUTTON%d" },
    { first = 37, cmd = "MULTIACTIONBAR4BUTTON%d" },
    { first = 49, cmd = "MULTIACTIONBAR2BUTTON%d" },
    { first = 61, cmd = "MULTIACTIONBAR1BUTTON%d" },
    { first = 73, cmd = "MULTIACTIONBAR5BUTTON%d" },
    { first = 85, cmd = "MULTIACTIONBAR6BUTTON%d" },
    { first = 97, cmd = "MULTIACTIONBAR7BUTTON%d" },
}

local keybindForSpell = {}
local keybindMapBuilt = false

-- Shorten a key for an icon corner. "SHIFT-BUTTON4" is longer than the icon.
local function AbbrevKey(key)
    if not key or key == "" then return nil end
    local out = key
    out = out:gsub("SHIFT%-", "s"):gsub("CTRL%-", "c"):gsub("ALT%-", "a")
    out = out:gsub("BUTTON", "m")
    out = out:gsub("MOUSEWHEELUP", "mwu"):gsub("MOUSEWHEELDOWN", "mwd")
    out = out:gsub("NUMPAD", "n")
    out = out:gsub("SPACE", "sp")
    return out
end

local function RebuildKeybindMap()
    wipe(keybindForSpell)
    keybindMapBuilt = true
    for _, bar in ipairs(KEYBIND_BARS) do
        for i = 1, 12 do
            local slot = bar.first + i - 1
            local actionType, id, subType = GetActionInfo(slot)
            local spellID
            if actionType == "spell" then
                spellID = id
            elseif actionType == "macro" then
                -- A macro that casts something still deserves the key.
                spellID = GetMacroSpell and GetMacroSpell(id)
            end
            -- Lowest slot wins, so a spell on several bars reports the one on
            -- the main bar rather than whichever was scanned last.
            if spellID and not keybindForSpell[spellID] then
                local key = GetBindingKey(bar.cmd:format(i))
                key = AbbrevKey(key)
                if key then keybindForSpell[spellID] = key end
            end
        end
    end
end

local function KeybindForSpell(spellID)
    if not spellID then return nil end
    if not keybindMapBuilt then RebuildKeybindMap() end
    local key = keybindForSpell[spellID]
    if key then return key end
    -- Talents replace a spell's ID on the bars while the cooldown viewer still
    -- lists the base one, so ask what this spell is currently overridden by.
    if C_SpellBook and C_SpellBook.FindSpellOverrideByID then
        local ovr = C_SpellBook.FindSpellOverrideByID(spellID)
        if ovr and ovr ~= spellID then return keybindForSpell[ovr] end
    end
    return nil
end
cdmModule.InvalidateKeybinds = function() keybindMapBuilt = false end

-- One reusable font string per icon, for a proxy or a borrowed Blizzard frame
-- alike. Created on demand and remembered on the frame.
ApplyKeybindText = function(frame, spellID, groupData)
    if not frame then return end
    local want = groupData and groupData.showKeybind
    if not want then
        if frame._sqKeybind then frame._sqKeybind:Hide() end
        return
    end

    local fs = frame._sqKeybind
    if not fs then
        fs = frame:CreateFontString(nil, "OVERLAY")
        frame._sqKeybind = fs
    end
    fs:SetFont("Fonts\\FRIZQT__.TTF", groupData.keybindSize or 10, "OUTLINE")
    PlaceText(fs, frame, groupData.keybindPosition or "TOPRIGHT",
        groupData.keybindOffsetX or -1, groupData.keybindOffsetY or -1)
    local c = groupData.keybindColor or { 1, 1, 1, 0.9 }
    fs:SetTextColor(c[1], c[2], c[3], c[4])
    fs:SetText(KeybindForSpell(spellID) or "")
    fs:Show()
end

-- Apply per-group visual settings to a proxy frame
local function ApplyProxyVisuals(proxy, groupData)
    if not proxy or not groupData then return end

    -- Fill in an icon that was not available when the proxy was built.
    --
    -- CreateProxyIcon reads the spell texture exactly once. If it came back nil
    -- or secret at that moment the icon stayed blank forever, and since the
    -- frame still takes up its slot the result is a correctly sized, correctly
    -- positioned group full of invisible icons -- which looks like a stray
    -- empty box floating next to the groups that did render. The buff
    -- categories are the ones that hit this, being discovered earlier in login
    -- than their spell data settles.
    if not proxy._iconSet and proxy.Icon and proxy.spellID then
        local tex = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(proxy.spellID)
        if tex and not BH.Secrets.IsSecret(tex) then
            proxy.Icon:SetTexture(tex)
            proxy._iconSet = true
        end
    end

    -- Alpha
    local alpha = groupData.alpha or DEFAULT_ALPHA
    proxy:SetAlpha(alpha)

    -- Border visibility
    local showBorder = groupData.showBorder ~= false
    if proxy.Border then proxy.Border:SetShown(showBorder) end

    ApplyKeybindText(proxy, proxy.spellID, groupData)
    ApplyIconShape(proxy, groupData.iconShape)

    -- Charge count: visibility and placement.
    if proxy.Count then
        proxy.Count:SetShown(groupData.showCount ~= false)
        proxy.Count:SetFont("Fonts\\FRIZQT__.TTF", groupData.countSize or 12, "OUTLINE")
        PlaceText(proxy.Count, proxy, groupData.countPosition or "BOTTOMRIGHT",
            groupData.countOffsetX or -1, groupData.countOffsetY or 1)
    end

    -- Cooldown countdown placement, when the widget exposes its font string.
    if proxy.Cooldown and groupData.cooldownTextPosition
       and groupData.cooldownTextPosition ~= "CENTER" then
        PlaceText(CooldownCountdownText(proxy.Cooldown), proxy,
            groupData.cooldownTextPosition,
            groupData.cooldownTextOffsetX or 0, groupData.cooldownTextOffsetY or 0)
    end

    -- Border thickness/colour, icon zoom and background.
    --
    -- ApplyProxyVisuals runs on every update pass, and SetBackdrop and
    -- SetTexCoord are far too heavy for that -- SetBackdrop rebuilds the
    -- backdrop's textures. So the style values are folded into a signature and
    -- the work only happens when one of them actually changed, which is when
    -- the player moves a slider. Any new style field must join the signature or
    -- editing it will appear to do nothing until a reload.
    local thickness = groupData.borderThickness or DEFAULT_BORDER_THICKNESS
    local zoom      = groupData.iconZoom or DEFAULT_ICON_ZOOM
    local bc        = groupData.borderColor or DEFAULT_BORDER_COLOR
    local bg        = groupData.bgColor or DEFAULT_BG_COLOR
    local bgOn      = groupData.bgEnabled and true or false
    local classCol  = groupData.borderClassColor and true or false

    local sig = ("%d|%.3f|%.2f,%.2f,%.2f,%.2f|%s|%.2f,%.2f,%.2f,%.2f|%s"):format(
        thickness, zoom, bc[1], bc[2], bc[3], bc[4],
        tostring(classCol), bg[1], bg[2], bg[3], bg[4], tostring(bgOn))

    if proxy._styleSig ~= sig then
        proxy._styleSig = sig

        if proxy.Icon then
            proxy.Icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
        end

        if proxy.Border then
            proxy.Border:ClearAllPoints()
            proxy.Border:SetPoint("TOPLEFT", -thickness, thickness)
            proxy.Border:SetPoint("BOTTOMRIGHT", thickness, -thickness)
            proxy.Border:SetBackdrop({
                edgeFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeSize = thickness,
            })
            local r, g, b, a = bc[1], bc[2], bc[3], bc[4]
            if classCol then
                local _, class = UnitClass("player")
                local cc = class and C_ClassColor and C_ClassColor.GetClassColor
                    and C_ClassColor.GetClassColor(class)
                if cc then r, g, b = cc.r, cc.g, cc.b end
            end
            proxy.Border:SetBackdropBorderColor(r, g, b, a)
        end

        if proxy.Bg then
            proxy.Bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
            proxy.Bg:SetShown(bgOn)
        end
    end

    -- Cooldown text visibility
    if proxy.Cooldown then
        proxy.Cooldown:SetHideCountdownNumbers(not (groupData.showCooldownText ~= false))
    end

    -- Desaturation: greyscale icon when spell is NOT on cooldown
    if proxy.Icon and proxy.spellID then
        local onCD = false
        local cdInfo = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(proxy.spellID)
        if cdInfo then
            local start = cdInfo.startTime
            local dur = cdInfo.duration
            if start and dur then
                -- Ask the readable booleans, do not infer from the timestamps.
                --
                -- SpellCooldownInfo carries isActive and isOnGCD, and they stay
                -- readable when startTime/duration have gone secret. That is
                -- strictly better than deriving state from the numbers: it
                -- needs no secret arithmetic, and isOnGCD separates a real
                -- cooldown from the global, which no amount of inference from a
                -- secret duration can do -- every GCD used to read as "on
                -- cooldown".
                --
                -- isActive is not in the generated API docs, but it is present
                -- and is what EllesmereUI reads in four separate places, which
                -- is the evidence it works on a live 12.1 client. The old
                -- derivation is kept as a fallback for a client without it.
                if not BH.Secrets.IsSecret(cdInfo.isActive) and cdInfo.isActive ~= nil then
                    onCD = cdInfo.isActive and not cdInfo.isOnGCD
                elseif BH.Secrets.IsSecret(start) or BH.Secrets.IsSecret(dur) then
                    -- Secret means on cooldown, not "unreadable, give up": these
                    -- fields are only secret while there is something to derive
                    -- them from, so a ready spell reads plainly. Same fact the
                    -- CDM available alert depends on.
                    onCD = true
                elseif dur > 1.5 then
                    onCD = true
                end
            end
        end

        local hasAura, auraReadable = CooldownAuraActive(proxy.cooldownID, proxy.spellID)

        -- What "active" means depends on which kind of entry this is.
        --
        -- A tracked buff is interesting while its AURA is up; whether the spell
        -- that applies it happens to be on cooldown says nothing about whether
        -- to show it. Folding onCD in made every tracked buff active the moment
        -- combat started, because a secret cooldown now correctly reads as "on
        -- cooldown" -- so Hide Until Active showed the entire buff list instead
        -- of the two or three actually running.
        --
        -- CooldownAuraActive reads the Blizzard buff item's IsActive(), which
        -- is real aura state and keeps working in combat, so this stays correct
        -- there rather than falling back to a guess.
        local isActive
        if proxy.viewerType == "buff" then
            isActive = hasAura
        else
            isActive = onCD or hasAura
        end

        if groupData.desaturateReady then
            proxy.Icon:SetDesaturated(not isActive)
        else
            proxy.Icon:SetDesaturated(false)
        end

        -- Hide until active: only show when on cooldown or buff is active
        if groupData.hideUntilActive then
            proxy:SetShown(isActive)
        end

        -- Detect state transitions this frame
        local justBecameReady  = not isActive and proxy._wasOnCD
        local justBecameActive = hasAura and not proxy._wasHasAura
        local justStartedCD    = isActive and not proxy._wasOnCD

        -- Glow when CD finishes (group setting).
        --
        -- Through ns.Glow rather than ActionButton_ShowOverlayGlow directly:
        -- that function is deprecated, and this routes to the modern
        -- ActionButtonSpellAlertManager where the client has it.
        if justBecameReady and groupData.glowOnReady then
            local target = proxy.GlowFrame or proxy
            ns.Glow.Show(target)
            proxy._glowShowing = true
            C_Timer.After(2, function()
                if proxy._glowShowing then
                    ns.Glow.Hide(target)
                    proxy._glowShowing = false
                end
            end)
        end

        -- Per-cooldown sound alerts (CDM Sounds tab settings)
        -- Absence-driven, so it needs the readability guard; the presence-driven
        -- transitions above are safe either way. Same rule as the tracker path.
        local justAuraRemoved = auraReadable and not hasAura and proxy._wasHasAura
        -- Not skipped when the Blizzard alert hook also covers this cooldown:
        -- both paths run and ClaimAlert drops whichever is second, so a
        -- cooldown the hook failed to attach to is still caught here.
        if justBecameReady or justBecameActive or justStartedCD or justAuraRemoved then
            local alerts = CollectAlertsFor(proxy.cooldownID)
            if alerts then
                for _, alert in ipairs(alerts) do
                    local fire = (alert.when == "available" and justBecameReady)
                              or (alert.when == "active"    and justBecameActive)
                              or (alert.when == "start"     and justStartedCD)
                              or (alert.when == "applied"   and justBecameActive)
                              or (alert.when == "removed"   and justAuraRemoved)
                    if fire and alert.type == "Sound" and alert.sound
                       and alert.sound ~= "None" and BH.PlaySound
                       and not BH.suppressBuffSounds
                       and ClaimAlert(proxy.spellID or proxy.cooldownID, alert.when) then
                        BH:PlaySound(alert.sound)
                    end
                end
            end
        end

        proxy._wasOnCD    = isActive
        -- Never record an unreadable aura pass over the real state.
        if auraReadable then proxy._wasHasAura = hasAura end
    end

    -- Tooltip setup
    if groupData.showTooltip ~= false then
        if not proxy._tooltipSetup then
            proxy._tooltipSetup = true
            proxy:EnableMouse(true)
            proxy:SetScript("OnEnter", function(self)
                if self.spellID then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetSpellByID(self.spellID)
                    GameTooltip:Show()
                end
            end)
            proxy:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end
    end
end

-- Fire sound alerts for CDM spells that are NOT in a named group.
-- Spells IN a named group are already handled by ApplyProxyVisuals.
-- This covers free icons and spells configured in CDM Sounds but not placed in CDM.
local function FireCDSounds()
    local soundAlerts = GetCDMSoundAlerts()
    if not next(soundAlerts) then return end
    local specData = GetSpecData()
    for alertKey, alerts in pairs(soundAlerts) do
        repeat
            if not alerts or #alerts == 0 then break end

            -- Alerts are stored keyed by spellID (see MigrateSoundAlerts), so
            -- the key is not a cooldownID and must not be handed to
            -- GetCooldownViewerCooldownInfo. Doing that returned nil and broke
            -- out of the loop for every alert, which is what "tracked: no
            -- (never evaluated)" meant.
            --
            -- A legacy store that has not migrated yet still holds cooldownID
            -- keys, so both readings are tried.
            local spellID, cdID
            local asSpell = SpellIDForCooldown(alertKey)
            if asSpell then
                cdID, spellID = alertKey, asSpell        -- legacy cooldownID key
            else
                spellID = alertKey
                cdID    = cdmModule.cooldownForSpell[alertKey]
            end
            if not spellID then break end

            -- Deliberately NOT skipped when the Blizzard alert hook also covers
            -- this cooldown. Both paths run and ClaimAlert drops whichever is
            -- second, so a cooldown the hook silently failed to attach to is
            -- still caught here instead of going quiet.
            -- Skip if in a named group — ApplyProxyVisuals handles it there
            local assignment = cdID and specData and specData.assignments[cdID]
            if assignment and assignment ~= "FREE" then break end

            if not cdmModule.soundTrackers[alertKey] then
                cdmModule.soundTrackers[alertKey] = { spellID = spellID }
            end
            local tracker = cdmModule.soundTrackers[alertKey]
            -- Current cooldown state
            local onCD = false
            -- Blizzard's viewer item first. It holds the answer already worked
            -- out from values we are not allowed to compare, and it is the only
            -- source that survives combat -- /sq cdm reports
            -- "GetSpellCooldown secret? startTime: true, duration: true" there,
            -- which is why the "available" alert could never fire in combat
            -- from the API path no matter what drove the poll.
            local cdReadable
            onCD, cdReadable = CooldownActiveFromViewer(cdID, spellID)

            if not cdReadable then
                -- No viewer item (spell not in Blizzard's Cooldown Manager), or
                -- it gave us a secret. Fall back to the API, which works fine
                -- out of combat.
                cdReadable = true
                local cdInfo = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(tracker.spellID)
                if cdInfo then
                    local start, dur = cdInfo.startTime, cdInfo.duration
                    if start and dur then
                        if BH.Secrets.HasAnySecret(start, dur) then
                            cdReadable = false
                        elseif dur > 1.5 then
                            onCD = true
                        end
                    end
                end
            end
            local hasAura, auraReadable = CooldownAuraActive(cdID, tracker.spellID)
            local isActive = onCD or hasAura

            -- Each transition is gated on the readability of the thing it
            -- actually depends on, rather than one blanket bail-out.
            --
            -- This used to `break` whenever the cooldown was unreadable, which
            -- silenced every alert for that cooldown -- including the aura ones,
            -- which do not depend on the cooldown at all. In combat the
            -- cooldown is routinely unreadable, so in practice no CDM sound
            -- fired in combat at all.
            --
            -- The rule (see CLAUDE.md): alerts that fire on *presence* are safe
            -- when data is unreadable, because they simply stay quiet. Alerts
            -- that fire on *absence* are not, because unreadable looks exactly
            -- like gone.
            -- Aura readability only matters for a cooldown that actually has an
            -- aura dimension. Most utility cooldowns do not: they are a plain
            -- timer with no associated buff, so `isActive` is just `onCD` and
            -- whether auras happen to be secret is irrelevant to them.
            --
            -- Requiring auraReadable unconditionally is what broke "available"
            -- in combat. AurasAreSecret() is true in combat, and a non-buff
            -- cooldown is absent from knownBuffCooldowns, so CooldownAuraActive
            -- correctly reported "cannot tell" -- and that answer, about an aura
            -- the cooldown does not even have, vetoed the transition. The alert
            -- then sat pending until combat ended and auras became readable
            -- again, which is precisely the reported behaviour.
            local auraRelevant = cdmModule.knownBuffCooldowns[cdID]
                              or hasAura or tracker._wasHasAura
            local auraUsable   = auraReadable or not auraRelevant

            local justBecameActive = hasAura and not tracker._wasHasAura            -- presence
            local justStartedCD    = cdReadable and isActive and not tracker._wasOnCD  -- presence
            local justBecameReady  = cdReadable and auraUsable                      -- absence
                                     and not isActive and tracker._wasOnCD
            local justAuraRemoved  = auraReadable                                   -- absence
                                     and not hasAura and tracker._wasHasAura
            if (justBecameReady or justBecameActive or justStartedCD or justAuraRemoved) and BH.PlaySound then
                for _, alert in ipairs(alerts) do
                    local fire = (alert.when == "available" and justBecameReady)
                              or (alert.when == "active"    and justBecameActive)
                              or (alert.when == "start"     and justStartedCD)
                              or (alert.when == "applied"   and justBecameActive)
                              or (alert.when == "removed"   and justAuraRemoved)
                    if fire and alert.type == "Sound" and alert.sound
                       and alert.sound ~= "None"
                       and not BH.suppressBuffSounds
                       and ClaimAlert(tracker.spellID or cdID, alert.when) then
                        BH:PlaySound(alert.sound)
                    end
                end
            end
            -- Only record state that was actually read. Writing back an
            -- unreadable pass overwrites the real state, and the next readable
            -- pass then sees a transition on something that never moved.
            if cdReadable then tracker._wasOnCD = isActive end
            if auraUsable then tracker._wasHasAura = hasAura end
        until true
    end
end

-- Diagnostics for the CDM sound alerts, reachable as /sq cdm.
--
-- The alert chain has several places it can quietly stop -- the Blizzard buff
-- viewers not existing, cooldown IDs not lining up between the viewer that
-- reports aura state and the one alerts were configured against, or an alert
-- being attached to a spell that is in a named group and therefore handled on a
-- different path. This prints each of those so a failure can be identified
-- rather than guessed at.
function cdmModule:PrintSoundDiagnostics()
    print("Squizzumables CDM sound diagnostics:")
    print("  CDM enabled:", tostring(BH.settings and BH.settings.cdmEnabled))
    print("  auras secret right now:", tostring(BH.Secrets.AurasAreSecret()))
    print("  in combat:", tostring(InCombatLockdown()))
    do
        local hooked = 0
        for _ in pairs(cdmModule.hookDrivenCooldowns) do hooked = hooked + 1 end
        print(string.format("  cooldowns driven by Blizzard alert hook: %d", hooked))
        -- Name them: "is it hooked?" is the first question whenever an alert
        -- does not fire, and a bare count cannot answer it for one spell.
        for cdID in pairs(cdmModule.hookDrivenCooldowns) do
            local info = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
                       and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
            local spellID = info and info.spellID
            local name = spellID and C_Spell.GetSpellName(spellID)
            local nAlerts = #CollectAlertsFor(cdID)
            print(string.format("      [%s] %s -- %d sound alert(s) configured",
                tostring(cdID), BH.Secrets.SafeString(name, "?"), nAlerts))
        end
        print("    (these fire from Blizzard's own state machine and work in combat;")
        print("     anything not listed falls back to polling, which cannot see a")
        print("     cooldown come up in combat -- add it to Blizzard's Cooldown Manager)")
    end

    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        local kids, active, withIsActive = 0, 0, 0
        local childIDs = {}
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            if ok and children then
                for _, child in ipairs(children) do
                    if child and child.cooldownID then
                        kids = kids + 1
                        childIDs[#childIDs + 1] = tostring(child.cooldownID)
                        if child.IsActive then
                            withIsActive = withIsActive + 1
                            local gotState, state = pcall(child.IsActive, child)
                            if gotState and state then active = active + 1 end
                        end
                    end
                end
            end
        end
        print(string.format("  %s: %s, %d tracked child(ren), %d expose IsActive, %d active now",
            viewerName, viewer and "found" or "MISSING", kids, withIsActive, active))
        if #childIDs > 0 then
            print("      contains cooldownIDs: " .. table.concat(childIDs, ", "))
        end
    end

    local soundAlerts = GetCDMSoundAlerts()
    local specData = GetSpecData()
    local n = 0
    for alertKey, alerts in pairs(soundAlerts) do
        n = n + #alerts
        local tracker = cdmModule.soundTrackers[alertKey]
        -- Keys are spellIDs post-migration; resolve back to the live
        -- cooldownID for the viewer-state lookups below.
        local sid, cdID
        local asSpell = cdmModule.SpellIDForCooldown(alertKey)
        if asSpell then cdID, sid = alertKey, asSpell
        else sid, cdID = alertKey, cdmModule.cooldownForSpell[alertKey] end
        local spellName = sid and C_Spell.GetSpellName(sid)
        local assignment = specData and specData.assignments and specData.assignments[cdID]
        -- Report the two aura signals separately. The viewer only knows about
        -- cooldowns the player has chosen to show in it, so the case where a
        -- direct aura read disagrees with it is exactly what needs to be seen.
        local viewerSays = cdmModule.activeBuffCooldowns[cdID] and true or false
        local auraSays   = (sid and BH.Secrets.GetAuraBySpellID("player", sid)) and true or false
        print(string.format("  %s (spellID %s, live cooldownID %s): %d alert(s), group: %s, tracked: %s",
            tostring(BH.Secrets.SafeString(spellName, "?")),
            tostring(sid),
            tostring(cdID or "none"),
            #alerts,
            assignment or "FREE",
            tracker and "yes" or "no (never evaluated)"))
        do
            -- The question this whole block exists to answer: is this stored
            -- alert actually reachable, or filed under a cooldownID the live
            -- viewer no longer uses?
            local hookedByID    = cdmModule.hookDrivenCooldowns[cdID] and true or false
            local hookedBySpell = sid and cdmModule.hookDrivenSpellIDs[sid] and true or false
            print(string.format("      delivery -- hook by ID: %s, hook by spell: %s, else poll",
                tostring(hookedByID), tostring(hookedBySpell)))
            if not hookedByID and hookedBySpell then
                print("      note: stored under a stale cooldownID; matched by spellID instead")
            end
        end
        do
            -- Proof of why the poll cannot work in combat: report whether the
            -- cooldown fields we would have to compare are secret right now.
            -- Run this out of combat and in combat -- if these flip to true,
            -- any addon doing `spellCooldownInfo.duration == 0` throws there.
            local cdi = sid and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(sid)
            if cdi then
                print(string.format("      GetSpellCooldown secret? startTime: %s, duration: %s",
                    tostring(BH.Secrets.IsSecret(cdi.startTime)),
                    tostring(BH.Secrets.IsSecret(cdi.duration))))
            else
                print("      GetSpellCooldown returned nothing")
            end
            -- The alternative source: state Blizzard already computed and left
            -- on its own item frame. If this reads true/false rather than
            -- "unreadable", the available alert can work in combat.
            local vActive, vReadable = CooldownActiveFromViewer(cdID, sid)
            -- Report the cooldown-type item, which is the one actually
            -- consulted -- not whatever item the alert key happened to name.
            local cdItemID = sid and cdmModule.cooldownForSpell[sid]
            local item = cdItemID and cdmModule.viewerItems[cdItemID]
            print(string.format("      viewer item: %s, onCooldown: %s",
                item and ("yes (cooldownID " .. tostring(cdItemID) .. ")")
                    or "NO cooldown-type item (spell not in Essential/Utility CDM)",
                vReadable and tostring(vActive) or "unreadable"))
            if item then
                -- Break out each field: "unreadable" was conflating two very
                -- different causes -- the value being secret, versus Blizzard
                -- never having computed it for this item at all.
                local function describe(v)
                    if v == nil then return "nil (never set)" end
                    if BH.Secrets.IsSecret(v) then return "SECRET" end
                    return tostring(v)
                end
                print(string.format("        isOnActualCooldown=%s cooldownIsActive=%s",
                    describe(item.isOnActualCooldown), describe(item.cooldownIsActive)))
                print(string.format("        allowAvailableAlert=%s availableAlertTriggerTime=%s isOnGCD=%s",
                    describe(item.allowAvailableAlert), describe(item.availableAlertTriggerTime),
                    describe(item.isOnGCD)))
            end
        end
        print(string.format("      aura active now -- viewer: %s, direct read: %s",
            tostring(viewerSays), tostring(auraSays)))
        if tracker then
            print(string.format("      last seen -- hasAura: %s, active: %s",
                tostring(tracker._wasHasAura and true or false),
                tostring(tracker._wasOnCD and true or false)))
        end
        for _, alert in ipairs(alerts) do
            print(string.format("      when=%s type=%s sound=%s",
                tostring(alert.when), tostring(alert.type), tostring(alert.sound)))
        end
    end
    if n == 0 then
        print("  No sound alerts configured. Add one from /squizz CDMS.")
    end
end

UpdateAllProxyCooldowns = function()
    for _, proxy in pairs(cdmModule.proxyFrames) do
        UpdateProxyCooldown(proxy)
    end
    -- Also update visuals (desaturation state changes with cooldown)
    local specData = GetSpecData()
    if not specData then return end

    local repack = {}
    for cdID, proxy in pairs(cdmModule.proxyFrames) do
        -- Resolve the group the same way reconcile does. Reading
        -- specData.assignments alone stopped being enough when the built-in
        -- groups arrived: a spell with no explicit assignment falls back to the
        -- group for its viewer type, so most proxies had no assignment entry
        -- and silently never had their visuals refreshed outside a layout pass
        -- -- desaturation, hide-until-active and the icon retry all stalled.
        local entry = cdmModule.registry[cdID]
        local assignment = specData.assignments[cdID]
            or (entry and BUILTIN_FOR_VIEWERTYPE[entry.viewerType])
        if assignment and assignment ~= "FREE" then
            local groupData = specData.groups[assignment]
            if groupData then
                local wasShown = proxy:IsShown()
                ApplyProxyVisuals(proxy, groupData)
                if groupData.hideUntilActive and proxy:IsShown() ~= wasShown then
                    repack[assignment] = true
                end
            end
        end
    end

    -- Re-pack a group whose visible set just changed, so Hide Until Active
    -- closes the gap as buffs come and go instead of waiting for the next
    -- reconcile and leaving a newly shown icon at a stale slot.
    for groupName in pairs(repack) do
        cdmModule:LayoutGroup(groupName)
    end

    FireCDSounds()
end

local function GetOrCreateProxy(cooldownID, spellID, iconSize)
    local proxy = cdmModule.proxyFrames[cooldownID]
    if proxy then
        proxy:SetSize(iconSize, iconSize)
        proxy.Icon:SetAllPoints()
        proxy.Cooldown:SetAllPoints()
        proxy:Show()
        return proxy
    end
    proxy = CreateProxyIcon(cooldownID, spellID, iconSize)
    cdmModule.proxyFrames[cooldownID] = proxy
    UpdateProxyCooldown(proxy)
    return proxy
end

local function DestroyProxy(cooldownID)
    local proxy = cdmModule.proxyFrames[cooldownID]
    if proxy then
        proxy:Hide()
        proxy:SetParent(nil)
        cdmModule.proxyFrames[cooldownID] = nil
    end
end


-- ============================================================================
-- Group Container Creation & Management
-- ============================================================================

-- Every reason a group might be hidden, in one place.
--
-- Two copies of this existed and had already drifted: LayoutGroup knew about
-- the Enable Group tick and UpdateCombatVisibility did not, so a disabled group
-- came back the moment combat ended. Same failure the text reminders had before
-- their gates were centralised -- see the reminder gate table in
-- Squizzumables.lua. Add a new condition here and both paths get it.
--
-- Returns a container alpha rather than a boolean because per-icon alpha is
-- applied separately in ApplyProxyVisuals; this is only the on/off.
GroupAlpha = function(groupData)
    if not groupData then return 1 end
    if groupData.enabled == false then return 0 end
    if groupData.hideOutOfCombat and not isInCombat then return 0 end
    if groupData.hideMounted and IsMounted() then return 0 end
    if groupData.onlyInInstances and not IsInInstance() then return 0 end
    if groupData.hideInHousing and C_Housing and C_Housing.IsInsideHouseOrPlot
       and C_Housing.IsInsideHouseOrPlot() then return 0 end
    if groupData.hideNoTarget and not UnitExists("target") then return 0 end
    if groupData.hideNoEnemy
       and not (UnitExists("target") and UnitCanAttack("player", "target")) then
        return 0
    end
    return 1
end

-- Group containers, kept for the whole session and reused.
--
-- Deliberately NOT cleared by ReleaseAll or a spec change. These frames are
-- named globals (SQZ_CDMGroup_Essential and friends) and are the documented
-- anchor point for other addons, so their identity has to be permanent. WoW
-- cannot destroy a frame: building a second one under the same name leaves the
-- first alive and orphaned, and anything anchored to it silently stops
-- tracking. So a group's frame is created once and re-pointed thereafter.
local containerCache = {}

local function CreateGroupContainer(groupName, position, iconSize)
    local cached = containerCache[groupName]
    if cached then
        cached:ClearAllPoints()
        cached:SetPoint("CENTER", UIParent, "CENTER", position.x or 0, position.y or 0)
        cached:Show()
        return cached
    end

    local container = CreateFrame("Frame", "SQZ_CDMGroup_" .. groupName, UIParent)
    containerCache[groupName] = container
    container:SetSize(DEFAULT_ICON_SIZE, DEFAULT_ICON_SIZE) -- Will be resized on layout
    container:SetPoint("CENTER", UIParent, "CENTER", position.x or 0, position.y or 0)
    container:SetFrameStrata("MEDIUM")
    container:SetMovable(true)
    container:SetClampedToScreen(true)
    container:EnableMouse(true)
    container:RegisterForDrag("LeftButton")

    container:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then return end
        -- An anchored group is positioned by the group it follows, so dragging
        -- it would move it for one frame and snap straight back on the next
        -- reconcile. Change or clear the anchor in the settings instead.
        local sd = GetSpecData()
        local gd = sd and sd.groups[groupName]
        if gd and gd.anchorTo and gd.anchorTo ~= "" then return end
        self:StartMoving()
        self:SetUserPlaced(false)
    end)
    container:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Save position
        local specData = GetSpecData()
        if specData and specData.groups[groupName] then
            local point, _, relativePoint, x, y = self:GetPoint()
            specData.groups[groupName].position = { x = x, y = y }
        end
    end)

    return container
end

-- Would anchoring `groupName` to `targetName` form a loop?
--
-- WoW raises a hard "circular dependency" error on a cycle rather than
-- ignoring it, and it takes the frame's layout down with it, so the chain is
-- walked before anything is anchored. Bounded by the group count as well as by
-- the visited set, because a corrupt saved chain should not be able to spin.
local function WouldAnchorLoop(specData, groupName, targetName)
    local seen = { [groupName] = true }
    local at = targetName
    local guard = 0
    while at do
        if seen[at] then return true end
        seen[at] = true
        guard = guard + 1
        if guard > 64 then return true end
        local gd = specData.groups[at]
        at = gd and gd.anchorTo
        if at == "" then at = nil end
    end
    return false
end

-- Place a group: against another group if it is anchored to one, otherwise at
-- its own saved position. Split out of CreateGroupContainer so an anchor change
-- can be applied without rebuilding the frame.
function cdmModule:PositionGroup(groupName)
    local group = self.groups[groupName]
    local specData = GetSpecData()
    local gd = specData and specData.groups[groupName]
    if not group or not group.container or not gd then return end

    local container = group.container
    local targetName = gd.anchorTo
    if targetName == "" then targetName = nil end

    local target = targetName and targetName ~= groupName
                   and not WouldAnchorLoop(specData, groupName, targetName)
                   and self.groups[targetName] and self.groups[targetName].container
                   or nil

    container:ClearAllPoints()
    if target then
        local where = gd.anchorPoint or "below"
        local ox, oy = gd.anchorX or 0, gd.anchorY or 0
        if where == "above" then
            container:SetPoint("BOTTOM", target, "TOP", ox, oy)
        elseif where == "left" then
            container:SetPoint("RIGHT", target, "LEFT", ox, oy)
        elseif where == "right" then
            container:SetPoint("LEFT", target, "RIGHT", ox, oy)
        else
            container:SetPoint("TOP", target, "BOTTOM", ox, oy)
        end
    else
        local p = gd.position or { x = 0, y = 0 }
        container:SetPoint("CENTER", UIParent, "CENTER", p.x or 0, p.y or 0)
    end
end

-- ============================================================================
-- Group Layout â€” Position icons within a group container
-- ============================================================================

function cdmModule:LayoutGroup(groupName)
    local group = self.groups[groupName]
    if not group or not group.container then return end

    -- A borrowed group holds Blizzard's frames, not proxies of ours, so it has
    -- its own layout pass. Running both would have them fighting each other.
    if group.usesBlizzardIcons then
        self:LayoutBorrowedBuffIcons(groupName)
        return
    end

    local specData = GetSpecData()
    if not specData then return end
    local groupData = specData.groups[groupName]
    if not groupData then return end

    local iconSize = groupData.iconSize or DEFAULT_ICON_SIZE
    local spacing = groupData.spacing or DEFAULT_SPACING
    local perRow = groupData.perRow or DEFAULT_PER_ROW
    local orientation = groupData.orientation or DEFAULT_ORIENTATION
    local growDir = groupData.growDirection or DEFAULT_GROW_DIRECTION
    local sortBy = groupData.sortBy or DEFAULT_SORT

    -- Get ordered members (proxy frames)
    local members = {}
    for cdID, proxy in pairs(group.members) do
        table.insert(members, { cdID = cdID, proxy = proxy })
    end

    -- Sort members
    if sortBy == "name" then
        table.sort(members, function(a, b)
            local nameA = C_Spell.GetSpellName and C_Spell.GetSpellName(a.proxy.spellID) or ""
            local nameB = C_Spell.GetSpellName and C_Spell.GetSpellName(b.proxy.spellID) or ""
            if BH.Secrets.HasAnySecret(nameA, nameB) then
                return a.cdID < b.cdID
            end
            return nameA < nameB
        end)
    elseif sortBy == "cooldown" then
        table.sort(members, function(a, b)
            local cdA = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(a.proxy.spellID)
            local cdB = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(b.proxy.spellID)
            local remA, remB = 0, 0
            if cdA and cdA.startTime and cdA.duration then
                local sOk = not BH.Secrets.IsSecret(cdA.startTime)
                local dOk = not BH.Secrets.IsSecret(cdA.duration)
                if sOk and dOk then remA = math.max(0, (cdA.startTime + cdA.duration) - GetTime()) end
            end
            if cdB and cdB.startTime and cdB.duration then
                local sOk = not BH.Secrets.IsSecret(cdB.startTime)
                local dOk = not BH.Secrets.IsSecret(cdB.duration)
                if sOk and dOk then remB = math.max(0, (cdB.startTime + cdB.duration) - GetTime()) end
            end
            return remA > remB  -- Longest CD first
        end)
    else
        -- "assignment" = order by cooldownID (stable)
        table.sort(members, function(a, b) return a.cdID < b.cdID end)
    end

    -- Determine growth multipliers from growDirection
    local centered = (growDir == "centereddown" or growDir == "centeredup")
    local centeredUp = (growDir == "centeredup")
    local colMul, rowMul = 1, -1  -- Default: rightdown
    if not centered then
        if growDir == "leftdown" then colMul, rowMul = -1, -1
        elseif growDir == "rightup" then colMul, rowMul = 1, 1
        elseif growDir == "leftup" then colMul, rowMul = -1, 1
        end
    end

    -- Hide Until Active packs the row: only the icons actually showing take a
    -- slot, so they sit together instead of being stranded at fixed positions
    -- with gaps where the inactive ones would be. With a Centered growth
    -- direction that means they grow out from the middle, which is the point.
    --
    -- ApplyProxyVisuals is what decides shown/hidden, so it has to run for
    -- every member BEFORE anything is measured or placed -- it used to run
    -- after each icon was positioned, which is why the slot stayed reserved.
    if groupData.hideUntilActive then
        for _, member in ipairs(members) do
            if member.proxy then
                member.proxy:SetParent(group.container)
                member.proxy:SetSize(iconSize, iconSize)
                ApplyProxyVisuals(member.proxy, groupData)
            end
        end
        local shown = {}
        for _, member in ipairs(members) do
            if member.proxy and member.proxy:IsShown() then
                shown[#shown + 1] = member
            end
        end
        members = shown
    end

    -- Pre-calculate container dimensions for centered mode
    local totalColsCalc = math.min(#members, perRow)
    local totalRowsCalc = math.ceil(math.max(#members, 1) / perRow)
    if totalColsCalc < 1 then totalColsCalc = 1 end
    if totalRowsCalc < 1 then totalRowsCalc = 1 end
    local fullW, fullH
    if orientation == "vertical" then
        fullW = totalRowsCalc * (iconSize + spacing) - spacing
        fullH = totalColsCalc * (iconSize + spacing) - spacing
    else
        fullW = totalColsCalc * (iconSize + spacing) - spacing
        fullH = totalRowsCalc * (iconSize + spacing) - spacing
    end

    -- Position each proxy
    local col, row = 0, 0
    for _, member in ipairs(members) do
        local proxy = member.proxy
        if proxy then
            proxy:SetParent(group.container)
            proxy:SetSize(iconSize, iconSize)
            proxy.Icon:SetAllPoints()
            proxy.Cooldown:SetAllPoints()
            proxy:ClearAllPoints()

            local xOff, yOff
            if centered then
                -- Centred growth: the offsets below are measured from the
                -- middle of an edge, so they must be anchored to the middle of
                -- that edge.
                --
                -- They were anchored to TOPLEFT/BOTTOMLEFT, which put a
                -- centred row of icons around the container's LEFT EDGE rather
                -- than its centre -- half the row hanging outside the frame --
                -- and with no half-icon inset the first row straddled the top
                -- edge too. For five 36px icons that is the container sitting
                -- ~98px right and ~18px below its own icons: dragging the group
                -- moved icons that were nowhere near the drag region, and
                -- clicking the icons hit nothing. TOP/BOTTOM (and LEFT/RIGHT
                -- when vertical) are the edge midpoints these offsets assume.
                local sign = centeredUp and 1 or -1
                local itemsThisLine = math.min(#members - row * perRow, perRow)
                if orientation == "vertical" then
                    -- Columns march sideways; icons centre vertically.
                    local colH = itemsThisLine * iconSize + (itemsThisLine - 1) * spacing
                    xOff = (iconSize / 2 + row * (iconSize + spacing)) * -sign
                    yOff = colH / 2 - col * (iconSize + spacing) - iconSize / 2
                    proxy:SetPoint("CENTER", group.container,
                        centeredUp and "RIGHT" or "LEFT", xOff, yOff)
                else
                    -- Rows march up or down; icons centre horizontally.
                    local rowW = itemsThisLine * iconSize + (itemsThisLine - 1) * spacing
                    xOff = -rowW / 2 + col * (iconSize + spacing) + iconSize / 2
                    yOff = (iconSize / 2 + row * (iconSize + spacing)) * sign
                    proxy:SetPoint("CENTER", group.container,
                        centeredUp and "BOTTOM" or "TOP", xOff, yOff)
                end
            else
                if orientation == "vertical" then
                    xOff = row * (iconSize + spacing) * colMul
                    yOff = col * (iconSize + spacing) * rowMul
                else
                    xOff = col * (iconSize + spacing) * colMul
                    yOff = row * (iconSize + spacing) * rowMul
                end

                local anchor = "TOPLEFT"
                if colMul < 0 and rowMul < 0 then anchor = "TOPRIGHT"
                elseif colMul > 0 and rowMul > 0 then anchor = "BOTTOMLEFT"
                elseif colMul < 0 and rowMul > 0 then anchor = "BOTTOMRIGHT"
                end

                proxy:SetPoint(anchor, group.container, anchor, xOff, yOff)
            end
            proxy:Show()

            -- Forward drag from proxy icon to the group container
            if not proxy._groupDragSetup or proxy._groupDragSetup ~= groupName then
                proxy:EnableMouse(true)
                if groupData.locked then
                    proxy:SetPassThroughButtons("LeftButton", "RightButton", "MiddleButton", "Button4", "Button5")
                else
                    proxy:SetPassThroughButtons()
                end
                proxy:RegisterForDrag("LeftButton")
                proxy:SetScript("OnDragStart", function()
                    if InCombatLockdown() then return end
                    if groupData.locked then return end
                    group.container:StartMoving()
                    group.container:SetUserPlaced(false)
                end)
                proxy:SetScript("OnDragStop", function()
                    group.container:StopMovingOrSizing()
                    local sd = GetSpecData()
                    if sd and sd.groups[groupName] then
                        local _, _, _, gx, gy = group.container:GetPoint()
                        sd.groups[groupName].position = { x = gx, y = gy }
                    end
                end)
                proxy._groupDragSetup = groupName
            end

            -- Apply visual settings
            ApplyProxyVisuals(proxy, groupData)

            col = col + 1
            if col >= perRow then
                col = 0
                row = row + 1
            end
        end
    end

    -- Resize container to fit all icons.
    --
    -- An empty group is clamped to one icon's worth above (totalColsCalc and
    -- totalRowsCalc are floored at 1), so its container is a 36x36 box sitting
    -- at the group's saved position with nothing in it. Invisible in play, but
    -- in unlock mode it gets the green drag overlay like any other group -- a
    -- stray green square floating away from the icons you can see, which reads
    -- as a group's drag region being misaligned with its own contents. Now that
    -- Essential/Utility/Buffs all exist by default, most people will have at
    -- least one empty one. Hide the container instead.
    local isEmpty = (#members == 0)
    group.container:SetShown(not isEmpty)

    if not InCombatLockdown() then
        group.container:SetSize(fullW, fullH)
    else
        table.insert(self.pendingMutations, function()
            if group.container then
                group.container:SetSize(fullW, fullH)
            end
        end)
    end

    -- Group enable, then combat visibility.
    --
    -- The enable toggle matters now that the built-in groups fill themselves:
    -- before 1.69 an unwanted group was emptied by simply never assigning
    -- anything to it, and that is no longer possible for Essential/Utility/
    -- Buffs. Alpha rather than Hide, matching hideOutOfCombat, so the container
    -- is never shown or hidden during combat lockdown.
    ApplyBarBackground(group, groupData)
    group.container:SetAlpha(GroupAlpha(groupData))
end

-- ============================================================================
-- Free Icon Positioning
-- ============================================================================

function cdmModule:PositionFreeIcon(cooldownID)
    local proxy = self.freeIcons[cooldownID]
    if not proxy then return end

    local specData = GetSpecData()
    if not specData then return end
    local savedFree = specData.freeIcons[cooldownID]
    if not savedFree then return end

    local iconSize = savedFree.iconSize or DEFAULT_ICON_SIZE

    proxy:SetParent(UIParent)
    proxy:SetSize(iconSize, iconSize)
    proxy.Icon:SetAllPoints()
    proxy.Cooldown:SetAllPoints()
    proxy:ClearAllPoints()
    proxy:SetPoint("CENTER", UIParent, "BOTTOMLEFT", savedFree.x, savedFree.y)
    proxy:SetFrameStrata("MEDIUM")
    proxy:Show()

    -- Make free proxy icons draggable (safe â€” this is OUR frame, not Blizzard's)
    if not proxy._sqzFreeDrag then
        proxy._sqzFreeDrag = true
        proxy:SetMovable(true)
        proxy:RegisterForDrag("LeftButton")
        proxy:SetScript("OnDragStart", function(self)
            if InCombatLockdown() then return end
            self:StartMoving()
            self:SetUserPlaced(false)
        end)
        proxy:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local sd = GetSpecData()
            if sd and sd.freeIcons[cooldownID] then
                local cx = self:GetCenter()
                local cy = select(2, self:GetCenter())
                sd.freeIcons[cooldownID].x = cx
                sd.freeIcons[cooldownID].y = cy
            end
        end)
    end

    -- Apply lock state: click-through when locked, interactive when unlocked
    local sd = GetSpecData()
    local isLocked = sd and sd.freeIcons[cooldownID] and sd.freeIcons[cooldownID].locked
    proxy:EnableMouse(true)
    if isLocked then
        proxy:SetPassThroughButtons("LeftButton", "RightButton", "MiddleButton", "Button4", "Button5")
    else
        proxy:SetPassThroughButtons()
    end
end

-- ============================================================================
-- Reconcile â€” Main loop: discover frames, assign to groups/free
-- ============================================================================

local reconcileTimer = nil

function cdmModule:Reconcile()
    -- SetPassThroughButtons (and other protected calls) are banned in combat
    if InCombatLockdown() then
        self:ScheduleReconcile(0)  -- will re-fire, but next check will bail until combat ends
        return
    end

    local specData = GetSpecData()
    if not specData then return end

    if not BH.settings or not BH.settings.cdmEnabled then
        self:ReleaseAll()
        return
    end

    local discovered = DiscoverCooldowns()

    -- Before the container pass, so the built-ins get containers on the very
    -- first reconcile of a fresh spec rather than one pass late.
    self:EnsureBuiltinGroups(specData)

    -- Ensure all saved groups have containers
    for groupName, groupData in pairs(specData.groups) do
        if not self.groups[groupName] then
            local container = CreateGroupContainer(groupName, groupData.position or { x = 0, y = 0 }, groupData.iconSize or DEFAULT_ICON_SIZE)
            self.groups[groupName] = {
                container = container,
                members = {},
            }
            -- Apply lock state: click-through when locked
            if groupData.locked then
                container:EnableMouse(false)
                -- Proxies created later will also be disabled via LayoutGroup
            end
        end
    end

    -- Process each discovered cooldown (pure API data, no frame references)
    for cdID, cdData in pairs(discovered) do
        local existing = self.registry[cdID]
        if existing then
            existing.spellID = cdData.spellID
            existing.viewerType = cdData.viewerType
            existing.auraIDs = cdData.auraIDs
            existing.hasAura = cdData.hasAura
        else
            self.registry[cdID] = {
                spellID = cdData.spellID,
                cooldownID = cdID,
                viewerType = cdData.viewerType,
                auraIDs = cdData.auraIDs,
                hasAura = cdData.hasAura,
                managed = false,
            }
        end

        local entry = self.registry[cdID]

        -- Check assignment.
        --
        -- An explicit assignment always wins, so moving a spell into a custom
        -- group (or setting it FREE) still does exactly what it did. Only when
        -- there is none does it fall back to the built-in group for its viewer
        -- type -- which is what makes Essential/Utility/Buffs populate
        -- themselves instead of the CDM showing nothing until the player has
        -- assigned every spell by hand.
        local assignment = specData.assignments[cdID]
            or BUILTIN_FOR_VIEWERTYPE[cdData.viewerType]
        -- Tracked buffs use Blizzard's own icons, not a proxy of them.
        --
        -- Every attempt to reproduce a buff's sweep on our own icon failed in
        -- combat, and the reason is structural rather than a bug to find: the
        -- duration cannot be read (secret), cannot be fetched (the instance-id
        -- APIs hard-error on a restricted unit), and catching the value in
        -- flight only works if the hook is on the frame before Blizzard uses
        -- it -- which pooling makes unreliable for a buff applied mid-fight.
        --
        -- EllesmereUI does not solve any of that. It re-anchors Blizzard's own
        -- item frames into its bars and lets Blizzard keep driving them, which
        -- is why its swipes are flawless in combat: they ARE Blizzard's swipes,
        -- rendered C-side with no addon involvement. Same approach here for the
        -- buff group. LayoutBorrowedBuffIcons does the positioning.
        --
        -- No reparenting: the frames stay children of Blizzard's viewer, which
        -- keeps this taint-free. Only their anchors are ours.
        if assignment and entry.viewerType == "buff" and BorrowBuffIcons() then
            entry.managed = true
            local group = self.groups[assignment]
            if group then group.usesBlizzardIcons = true end
        elseif assignment and entry.spellID then
            entry.managed = true

            if assignment == "FREE" then
                local proxy = GetOrCreateProxy(cdID, entry.spellID, DEFAULT_ICON_SIZE)
                proxy.auraSpellIDs = entry.auraIDs
                proxy.viewerType = entry.viewerType
                self.freeIcons[cdID] = proxy
                self:PositionFreeIcon(cdID)
            else
                -- Assign to group
                local group = self.groups[assignment]
                if group then
                    local groupData = specData.groups[assignment]
                    local iconSize = groupData and groupData.iconSize or DEFAULT_ICON_SIZE
                    local proxy = GetOrCreateProxy(cdID, entry.spellID, iconSize)
                    proxy.auraSpellIDs = entry.auraIDs
                    proxy.viewerType = entry.viewerType
                    group.members[cdID] = proxy
                end
            end
        else
            -- Not assigned â€” clean up if previously managed
            if entry.managed then
                DestroyProxy(cdID)
                entry.managed = false
            end
        end
    end

    -- Position, then lay out. Positioning first means an anchored group is
    -- already attached to its target before sizes are computed, so nothing
    -- jumps on the frame a chain is rebuilt.
    for groupName, _ in pairs(self.groups) do
        self:PositionGroup(groupName)
    end

    -- Layout all groups
    for groupName, _ in pairs(self.groups) do
        self:LayoutGroup(groupName)
    end

    -- After the containers exist AND have been laid out, not before.
    --
    -- This used to run above, before either. "Keep Blizzard's frames on our
    -- groups" looks up the group frame to follow, got nil every single time
    -- because no container had been built yet, and silently fell back to
    -- parking offscreen -- so the option appeared to do nothing and anything
    -- anchored to a Blizzard viewer still ended up clamped in a screen corner.
    -- It has to be after LayoutGroup too, since the follow anchors to the
    -- container's rect and that rect is only correct once the icons are placed.
    --
    -- Re-applied every reconcile rather than once at login for the original
    -- reason as well: these are Edit Mode managed frames, and Edit Mode, a
    -- layout pass or a spec change can put their alpha back.
    self:ApplyBlizzardVisibility()

    -- Hook Blizzard buff frames and scan active state (CMC-style)
    HookBlizzardBuffFrames()
    HookBlizzardAlertEvents()
    ScanBlizzardBuffState()

    -- Blizzard's viewers acquire item frames from a pool, lazily and on their
    -- own schedule -- a spec change, an edit-mode change, or simply the first
    -- time a category is populated. A one-shot sweep at init therefore misses
    -- items that do not exist yet, which is exactly how the utility cooldowns
    -- ended up unhooked. Re-sweeping is idempotent (each frame is tagged) and
    -- costs a short walk of already-hooked frames, so run it on a slow ticker
    -- rather than trying to guess every event that could grow the pool.
    if not cdmModule.alertHookTicker then
        cdmModule.alertHookTicker = C_Timer.NewTicker(2, function()
            if BH.settings and BH.settings.cdmEnabled ~= false then
                HookBlizzardAlertEvents()
                -- Item frames are pooled and acquired as Blizzard needs them,
                -- so a newly acquired one arrives mouse-enabled and starts
                -- showing tooltips over a viewer that is meant to be gone.
                -- Same reason this sweep re-runs at all.
                cdmModule:MuteSuppressedViewerItems()
                -- Same argument as the sweep itself, applied to the cooldown
                -- set rather than the frame pool: rather than trusting that we
                -- named every event that can change which cooldowns exist, look
                -- at the set and notice. Events only make the response quicker.
                if cdmModule.CheckCooldownSetChanged then
                    cdmModule.CheckCooldownSetChanged()
                end
            end
        end)
    end

    -- Drive the sound pass on its own clock.
    --
    -- FireCDSounds used to run only from UpdateAllProxyCooldowns, which is
    -- called on buff-state-change hooks and on rebuilds -- and nothing else. In
    -- combat, with no buff changing state, it simply never ran, so a cooldown
    -- coming off cooldown was never noticed. The transition stayed pending and
    -- then flushed at the next thing that happened to call it: another spell's
    -- buff alert, or the end of combat. That is exactly the reported symptom --
    -- "it plays when combat ends, or when some other spell's sound fires".
    --
    -- A cooldown finishing is a clock event, not a state-change event: nothing
    -- fires when a timer merely runs out. So it needs polling on a timer, at a
    -- resolution fine enough that the alert is not audibly late.
    if not cdmModule.soundPollTicker then
        cdmModule.soundPollTicker = C_Timer.NewTicker(0.2, function()
            if BH.settings and BH.settings.cdmEnabled ~= false then
                FireCDSounds()
                -- Catch item frames Blizzard has only just acquired.
                --
                -- The viewers pool their item frames and take one out when a
                -- buff needs it, so a buff applied DURING a fight lands on a
                -- frame that has never been seen before. The buff hooks and the
                -- swipe mirror were installed only from reconcile, which does
                -- not run mid-fight -- so exactly those buffs got no sweep,
                -- while ones already up before the pull kept theirs. That is
                -- the "no swipe on anything applied in combat" report.
                --
                -- Idempotent per frame, and only walks the two buff viewers'
                -- children, so running it at poll rate is cheap.
                MirrorAllBuffCooldowns()
                -- Borrowed icons are Blizzard's, and Blizzard re-anchors them
                -- on its own layout passes -- which would drag them back to its
                -- bar. Re-asserting our anchors at poll rate keeps them in the
                -- group, and picks up frames the pool hands out mid-fight.
                cdmModule:LayoutAllBorrowedBuffIcons()
            end
        end)
    end

    -- Update all proxy cooldown sweeps
    UpdateAllProxyCooldowns()

    -- Handle spells that disappeared (talent/spec change removed a spell)
    for cdID, entry in pairs(self.registry) do
        if not discovered[cdID] and entry.managed then
            local assignment = specData.assignments and specData.assignments[cdID]
            if assignment and assignment ~= "FREE" then
                local group = self.groups[assignment]
                if group then
                    group.members[cdID] = nil
                end
            end
            self.freeIcons[cdID] = nil
            DestroyProxy(cdID)
            entry.managed = false
        end
    end
end

function cdmModule:ScheduleReconcile(delay)
    if reconcileTimer then reconcileTimer:Cancel() end
    reconcileTimer = C_Timer.NewTimer(delay or RECONCILE_DEBOUNCE, function()
        self:Reconcile()
    end)
end

-- ============================================================================
-- Release â€” Return all frames to Blizzard's CDM
-- ============================================================================

-- ============================================================================
-- Public anchor API
--
-- For other addons that want to position something against a cooldown group.
--
--     local f = Squizzumables_GetCDMGroupFrame("Essential")
--     if f then myFrame:SetPoint("TOP", f, "BOTTOM", 0, -4) end
--
-- The group names are "Essential", "Utility" and "Buffs" for the built-ins, or
-- whatever the player called a custom group. The frames are also reachable as
-- the globals SQZ_CDMGroup_<name>, but go through this: the accessor is the
-- supported contract and the name is not.
--
-- Do NOT anchor to Blizzard's EssentialCooldownViewer expecting to follow these
-- icons. This module proxies rather than reparenting, so Blizzard's viewer is a
-- separate frame at its own position -- and with "Hide Blizzard's Cooldown
-- Manager" on it is parked far offscreen, which would drag anything anchored to
-- it off with it.
--
-- A frame is created once and reused for the rest of the session, so a
-- reference taken here stays valid across spec changes and across the module
-- being switched off and on. It may be sized 0-ish or hidden when its group is
-- empty; anchoring still works, visibility is not inherited.
-- ============================================================================
function cdmModule:GetGroupFrame(groupName)
    return groupName and containerCache[groupName] or nil
end

function Squizzumables_GetCDMGroupFrame(groupName)
    return cdmModule:GetGroupFrame(groupName)
end

-- Every Blizzard cooldown viewer, for the "hide Blizzard's" option.
local BLIZZARD_VIEWERS = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

-- Suppress (or restore) Blizzard's own cooldown viewers.
--
-- ALPHA, NEVER Hide(). Two independent reasons, both of which bite:
--
--   1. This module reads live buff state off the viewers' item frames, and
--      Blizzard drives those from CooldownViewerMixin:OnUpdate. OnUpdate does
--      not run on a hidden frame, so Hide() freezes the item state we depend on
--      -- our own icons would stop tracking buffs. Alpha 0 keeps it updating.
--
--   2. They are Edit Mode systems and managed frames (isManagedFrame,
--      layoutParent = UIParentBottomManagedFrameContainer). Hiding one fights
--      the managed-frame layout, which reflows the other frames in that
--      container into the gap and re-shows ours on the next layout pass.
--
-- Only ever restores what it dimmed, tracked per frame: another addon may be
-- suppressing these too (this addon's own notes record TriggerAlertEvent not
-- firing when the viewers were alpha-suppressed by something else), and
-- stamping alpha 1 over that would fight it.
--
-- SetAlpha and EnableMouse are not protected, so no combat queueing is needed.
--
-- SETTING THE ALPHA ONCE IS NOT ENOUGH. Edit Mode owns alpha on these frames:
-- EditModeCooldownViewerSystemMixin:UpdateSystemSettingOpacity does
-- `self:SetAlpha(opacitySetting / 100)`, and re-asserts it whenever the system
-- refreshes -- which is why the viewers came back about a second after being
-- dimmed. So rather than set the value, hold it: a post-hook on the frame's own
-- SetAlpha puts it back to 0 whenever anything raises it while we are dimming.
--
-- Hooking SetAlpha itself rather than UpdateSystemSettingOpacity on purpose --
-- it catches every source, not just the Edit Mode path we happened to find.
-- hooksecurefunc cannot be undone, so the hook is installed once per frame and
-- made inert by clearing _sqDimmed; _sqApplying breaks the recursion from our
-- own SetAlpha call inside the hook.
local function HoldAlphaZero(f)
    if f._sqAlphaHooked then return end
    f._sqAlphaHooked = true
    hooksecurefunc(f, "SetAlpha", function(self, a)
        if self._sqDimmed and a ~= 0 and not self._sqApplying then
            self._sqApplying = true
            self:SetAlpha(0)
            self._sqApplying = nil
        end
    end)
end

-- Alpha 0 alone was not enough: an invisible frame still takes the mouse, so
-- Blizzard's cooldown tooltips kept appearing over empty screen where the
-- hidden bars were. EnableMouse(false) on the viewer does not cover it either,
-- because the tooltips come from its pooled item frames, which are created and
-- recycled on Blizzard's schedule and would need chasing forever.
--
-- Parking the viewer far offscreen solves it at the root -- nothing to hover --
-- and, unlike Hide(), keeps the frame shown so CooldownViewerMixin:OnUpdate
-- still runs and our buff-state reads keep working.
local PARK_X, PARK_Y = -10000, 10000
local parkPending = false

-- Which of our groups each Blizzard viewer sits on top of when "Follow our
-- groups" is on. Both buff viewers map to the one Buffs group, matching how
-- DISCOVER_CATEGORIES folds categories 2 and 3 together.
local VIEWER_TO_GROUP = {
    EssentialCooldownViewer = "Essential",
    UtilityCooldownViewer   = "Utility",
    BuffIconCooldownViewer  = "Buffs",
    BuffBarCooldownViewer   = "Buffs",
}

-- Mute Blizzard's pooled item frames.
--
-- This is what parking offscreen was really buying: the cooldown tooltips come
-- from the item frames, not the viewer, so EnableMouse on the viewer alone left
-- them live. They are pooled and acquired on Blizzard's own schedule, so this
-- has to be re-run rather than done once -- the existing 2s hook sweep is
-- already there for exactly that reason and calls this too.
local function MuteViewerItems(viewer, muted)
    if not viewer then return end
    local ok, children = pcall(function() return { viewer:GetChildren() } end)
    if not ok or not children then return end
    for _, child in ipairs(children) do
        if child and child.EnableMouse then
            child:EnableMouse(not muted)
            if child.EnableMouseMotion then child:EnableMouseMotion(not muted) end
        end
    end
end

local function SaveOrigPoints(f)
    if f._sqOrigPoints then return end
    local pts = {}
    for i = 1, f:GetNumPoints() do pts[i] = { f:GetPoint(i) } end
    f._sqOrigPoints = pts
end

-- Where a suppressed viewer goes.
--
-- Two options, and the difference matters to other addons:
--
--   parked   -- far offscreen. Nothing can reach it.
--   follow   -- sat exactly on top of the group that replaced it, invisible.
--
-- "follow" exists because it is the property that makes anchoring work in
-- EllesmereUI: they never move the primary viewers, so EssentialCooldownViewer
-- stays where the icons visibly are and anchoring to it lands on them. Parking
-- ours offscreen broke that, and the obvious frame to anchor to became the
-- wrong one. Following puts the guarantee back without adopting their
-- architecture -- their re-anchoring is a 2,100-line function that replaces our
-- icons with Blizzard's, and with them the per-group styling.
--
-- The reason parking was chosen first still has to be handled either way:
-- an invisible viewer's item frames still take the mouse. MuteViewerItems does
-- that, on the sweep that already exists for pooled frames.
local function ParkFrame(f, groupFrame)
    if InCombatLockdown() then
        -- These are Edit Mode managed frames; moving them is not worth
        -- attempting under lockdown. Flushed on PLAYER_REGEN_ENABLED.
        parkPending = true
        return
    end
    f._sqParkGuard = true
    f:ClearAllPoints()
    if groupFrame then
        -- Match position and size, so the viewer's rect is the group's rect and
        -- an addon anchored to either gets the same answer.
        f:SetPoint("TOPLEFT", groupFrame, "TOPLEFT", 0, 0)
        f:SetPoint("BOTTOMRIGHT", groupFrame, "BOTTOMRIGHT", 0, 0)
    else
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", PARK_X, PARK_Y)
    end
    f._sqParkGuard = nil
end

local function RestoreFramePoints(f)
    if not f._sqOrigPoints or InCombatLockdown() then return end
    f._sqRestoring = true
    f:ClearAllPoints()
    for _, p in ipairs(f._sqOrigPoints) do
        f:SetPoint(p[1], p[2], p[3], p[4], p[5])
    end
    f._sqOrigPoints = nil
    f._sqRestoring = nil
end

-- Blizzard re-anchors these during Edit Mode layout passes, which would drag
-- them back on screen. Re-park when that happens -- but NEVER inline.
--
-- That layout pass goes on to move protected systems (the action bars), so
-- re-anchoring from inside it carries this addon's taint into the rest of the
-- pass. A C_Timer.After(0) runs with none of that lineage. It also coalesces
-- the ClearAllPoints + SetPoint burst into a single re-park, and one frame of a
-- stray bar is not visible.
local function HoldParked(f)
    if f._sqPointHooked then return end
    f._sqPointHooked = true
    local function QueueRepark(self)
        if not self._sqDimmed or self._sqParkGuard or self._sqRestoring
           or self._sqParkQueued then return end
        self._sqParkQueued = true
        C_Timer.After(0, function()
            self._sqParkQueued = nil
            -- Re-park to the same place it was, following or offscreen.
            if self._sqDimmed then ParkFrame(self, self._sqFollowFrame) end
        end)
    end
    hooksecurefunc(f, "SetPoint", QueueRepark)
    hooksecurefunc(f, "ClearAllPoints", QueueRepark)
end

-- /sq cdmbuff -- ground truth for tracked-buff state, in and out of combat.
--
-- Written because three attempts at reasoning about which of these reads
-- survives combat were all wrong. Run it out of combat and again during a
-- pull with buffs up; the difference between the two is the answer.
--
-- For every child of the buff viewers it reports what this module actually
-- depends on: whether IsActive answers and whether that answer is secret,
-- whether the frame carries a usable auraInstanceID, and whether
-- GetAuraDuration yields a duration object from it.
function cdmModule:PrintBuffDiagnostics()
    print("|cFF00FF00Squizzumables CDM buff state|r")
    print(("  in combat: %s   auras secret: %s"):format(
        tostring(InCombatLockdown()), tostring(BH.Secrets.AurasAreSecret())))

    local n = 0
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if not viewer then
            print(("  %s: |cFFFF5555missing|r"):format(viewerName))
        else
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            print(("  %s: %d child(ren)"):format(viewerName, (ok and children) and #children or -1))
            if ok and children then
                for _, child in ipairs(children) do
                    if child and child.cooldownID then
                        n = n + 1
                        local cdID = child.cooldownID
                        local sid  = SpellIDForCooldown(cdID)
                        local name = sid and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
                        name = BH.Secrets.SafeString(name, "?")

                        local activeTxt = "no IsActive"
                        if child.IsActive then
                            local gotState, state = pcall(child.IsActive, child)
                            if not gotState then
                                activeTxt = "|cFFFF5555threw|r"
                            elseif BH.Secrets.IsSecret(state) then
                                activeTxt = "|cFFFFD100SECRET|r"
                            else
                                activeTxt = tostring(state)
                            end
                        end

                        local iid = child.auraInstanceID
                        local iidTxt
                        if iid == nil then iidTxt = "nil"
                        elseif BH.Secrets.IsSecret(iid) then iidTxt = "|cFFFFD100SECRET|r"
                        else iidTxt = tostring(iid) end

                        local durTxt = "-"
                        if iid and child.auraDataUnit and not BH.Secrets.HasAnySecret(iid, child.auraDataUnit)
                           and C_UnitAuras and C_UnitAuras.GetAuraDuration then
                            local dok, dobj = pcall(C_UnitAuras.GetAuraDuration, child.auraDataUnit, iid)
                            durTxt = (dok and dobj) and "|cFF33FF33object|r" or (dok and "nil" or "threw")
                        end

                        -- Is the swipe mirror actually installed on this frame,
                        -- and is there one of our icons for it to drive?
                        local cdw = child.Cooldown
                            or (child.GetCooldownFrame and child:GetCooldownFrame())
                        local mirrorTxt
                        if not cdw then mirrorTxt = "|cFFFF5555no Cooldown widget|r"
                        elseif cdw._sqMirrorHooked then mirrorTxt = "|cFF33FF33hooked|r"
                        else mirrorTxt = "|cFFFF5555NOT hooked|r" end
                        local proxyTxt = cdmModule.proxyFrames[cdID] and "yes" or "|cFFFF5555none|r"

                        print(("    %s (cd %s, spell %s) IsActive=%s auraInstanceID=%s unit=%s dur=%s tracked=%s mirror=%s proxy=%s"):format(
                            name, tostring(cdID), tostring(sid), activeTxt, iidTxt,
                            tostring(child.auraDataUnit),
                            durTxt,
                            tostring(sid and cdmModule.buffItemForSpell[sid] ~= nil),
                            mirrorTxt, proxyTxt))
                    end
                end
            end
        end
    end
    if n == 0 then
        print("|cFFFF5555  no buff viewer children at all -- the viewers have not built their item frames.|r")
    end
end

-- Re-mute the item frames of any viewer currently suppressed. Cheap, and it has
-- to keep happening: see MuteViewerItems.
function cdmModule:MuteSuppressedViewerItems()
    for _, name in ipairs(BLIZZARD_VIEWERS) do
        local f = _G[name]
        if f and f._sqDimmed then MuteViewerItems(f, true) end
    end
end

-- Flush a park that combat postponed. Called from PLAYER_REGEN_ENABLED.
function cdmModule:FlushPendingPark()
    if not parkPending then return end
    parkPending = false
    self:ApplyBlizzardVisibility()
end

-- Is Blizzard's Edit Mode open right now?
local function EditModeActive()
    return EditModeManagerFrame and EditModeManagerFrame.IsEditModeActive
       and EditModeManagerFrame:IsEditModeActive()
end

-- Follow Edit Mode in and out, so the dim lifts the moment it opens and comes
-- back the moment it closes, rather than waiting for whatever happens to
-- trigger the next reconcile. Only reacts; never drives Edit Mode.
--
-- Retried from ApplyBlizzardVisibility rather than installed once at login,
-- because Blizzard_EditMode is not guaranteed to be loaded that early and a
-- single attempt that lost the race would leave this silently unhooked.
local editModeHooked = false
local function HookEditMode()
    if editModeHooked then return end
    if not (EditModeManagerFrame and EditModeManagerFrame.EnterEditMode) then return end
    editModeHooked = true
    hooksecurefunc(EditModeManagerFrame, "EnterEditMode", function()
        cdmModule:ApplyBlizzardVisibility()
    end)
    hooksecurefunc(EditModeManagerFrame, "ExitEditMode", function()
        cdmModule:ApplyBlizzardVisibility()
    end)
end

function cdmModule:ApplyBlizzardVisibility()
    -- Never dim while Edit Mode is open.
    --
    -- Edit Mode still draws its selection region for a dimmed viewer, so the
    -- player got an empty box they could not see the contents of, sitting
    -- wherever Blizzard's frame really is -- while the icons on screen were our
    -- proxies at the group's own position. That reads as the region being
    -- misaligned, and it makes Blizzard's own cooldown bars impossible to
    -- position while this option is on.
    --
    -- Releasing for the duration of Edit Mode costs nothing: it is not a
    -- situation anyone is playing through, and ApplyBlizzardVisibility is
    -- called again on exit.
    HookEditMode()

    local hide = BH.settings and BH.settings.cdmEnabled and BH.settings.cdmHideBlizzard
                 and not EditModeActive()
    for _, name in ipairs(BLIZZARD_VIEWERS) do
        local f = _G[name]
        -- Never suppress a viewer whose icons we are borrowing.
        --
        -- Those icons are children of the viewer and inherit its alpha, so
        -- dimming it would hide the very things the group is now made of, and
        -- parking it offscreen would take them with it. The viewer frame itself
        -- draws nothing, so leaving it alone costs nothing visually -- it just
        -- becomes an invisible shell whose children we have re-anchored. This
        -- is exactly how EllesmereUI leaves the primary viewers alone.
        local borrowed = BorrowBuffIcons()
            and (name == "BuffIconCooldownViewer" or name == "BuffBarCooldownViewer")
        if borrowed then f = nil end
        if f then
            if hide then
                SaveOrigPoints(f)
                f._sqDimmed = true
                HoldAlphaZero(f)
                HoldParked(f)
                f:SetAlpha(0)
                -- Follow the group that replaced it when there is one and the
                -- option is on, so this viewer stays a valid anchor target.
                local follow = BH.settings.cdmViewersFollowGroups ~= false
                local groupFrame = follow and self:GetGroupFrame(VIEWER_TO_GROUP[name]) or nil
                f._sqFollowFrame = groupFrame
                ParkFrame(f, groupFrame)
                if f.EnableMouse then f:EnableMouse(false) end
                if f.EnableMouseMotion then f:EnableMouseMotion(false) end
                MuteViewerItems(f, true)
            elseif f._sqDimmed then
                -- Clear the flag first: the hook reads it, and leaving it set
                -- would have our own restore immediately undone.
                --
                -- Restores to 1 rather than to whatever the player set in Edit
                -- Mode, because reading that back means calling into Edit Mode's
                -- own mixin and this module does not write to or drive Blizzard
                -- frames. It is self-correcting: the same opacity refresh that
                -- caused this whole problem re-asserts the real value on its
                -- next pass, so a viewer set to e.g. 80% returns there shortly.
                f._sqDimmed = nil
                f._sqFollowFrame = nil
                RestoreFramePoints(f)
                f:SetAlpha(1)
                if f.EnableMouse then f:EnableMouse(true) end
                if f.EnableMouseMotion then f:EnableMouseMotion(true) end
                MuteViewerItems(f, false)
            end
        end
    end
end

function cdmModule:ReleaseAll()
    -- Destroy all proxy frames
    for cdID, _ in pairs(self.proxyFrames) do
        DestroyProxy(cdID)
    end

    -- Mark all registry entries as unmanaged
    for cdID, entry in pairs(self.registry) do
        entry.managed = false
    end

    -- Hide group containers
    for groupName, group in pairs(self.groups) do
        if group.container then group.container:Hide() end
    end
    self.groups = {}
    self.freeIcons = {}
    self.soundTrackers = {}

    -- Give Blizzard's viewers back. Switching this module off must not leave
    -- the player with no cooldown display at all -- that reads as the addon
    -- having broken the game UI, and there is nothing on screen to undo it
    -- from. Reads cdmEnabled, which is already false by the time we get here.
    self:ApplyBlizzardVisibility()
end

-- ============================================================================
-- Group Management API â€” Used by settings UI
-- ============================================================================

-- Create the three built-in groups for this spec if they are not there yet.
--
-- Idempotent and safe to call on every reconcile: it only fills gaps, so a
-- player who has restyled or repositioned Essential keeps their settings, and
-- one who deleted its contents does not get them silently rebuilt.
function cdmModule:EnsureBuiltinGroups(specData)
    specData = specData or GetSpecData()
    if not specData then return end
    for _, b in ipairs(BUILTIN_GROUPS) do
        if not specData.groups[b.name] then
            self:CreateGroup(b.name)
            local gd = specData.groups[b.name]
            if gd then
                gd.builtin = true
                gd.position = { x = 0, y = b.defaultY }
                -- Centred, like Blizzard's own bars. It also matters more here
                -- than for a custom group: with Hide Until Active the row packs
                -- down to whatever is active, and centred growth keeps that
                -- shrinking row anchored in place instead of having it crawl
                -- sideways as buffs come and go.
                gd.growDirection = "centereddown"
            end
        else
            -- Re-stamp the flag: groups made before 1.69 could share a name
            -- with a built-in, and the tab needs to know not to offer delete.
            specData.groups[b.name].builtin = true
        end
    end
end

function cdmModule:CreateGroup(groupName)
    local specData = GetSpecData()
    if not specData then return end
    if specData.groups[groupName] then return end -- Already exists

    specData.groups[groupName] = {
        cooldownIDs = {},
        enabled = true,
        position = { x = 0, y = 0 },
        iconSize = DEFAULT_ICON_SIZE,
        perRow = DEFAULT_PER_ROW,
        locked = false,
        scale = 1.0,
        orientation = DEFAULT_ORIENTATION,
        growDirection = DEFAULT_GROW_DIRECTION,
        spacing = DEFAULT_SPACING,
        alpha = DEFAULT_ALPHA,
        sortBy = DEFAULT_SORT,
        showTooltip = true,
        showBorder = true,
        showCooldownText = true,
        desaturateReady = false,
        glowOnReady = false,
        hideOutOfCombat = false,
        -- Icon look. Absent on groups made before 1.69, which is why every
        -- read is `or DEFAULT_x` rather than assuming these exist.
        borderThickness = DEFAULT_BORDER_THICKNESS,
        borderColor = { DEFAULT_BORDER_COLOR[1], DEFAULT_BORDER_COLOR[2],
                        DEFAULT_BORDER_COLOR[3], DEFAULT_BORDER_COLOR[4] },
        borderClassColor = false,
        iconZoom = DEFAULT_ICON_ZOOM,
        bgEnabled = false,
        bgColor = { DEFAULT_BG_COLOR[1], DEFAULT_BG_COLOR[2],
                    DEFAULT_BG_COLOR[3], DEFAULT_BG_COLOR[4] },
        -- Visibility conditions (all off: the group shows everywhere unless
        -- told otherwise) and group-to-group anchoring.
        hideMounted = false,
        onlyInInstances = false,
        hideInHousing = false,
        hideNoTarget = false,
        hideNoEnemy = false,
        anchorTo = "",
        anchorPoint = "below",
        anchorX = 0,
        anchorY = -4,
        -- Tracked buffs only: hold a slot for a buff that is not up.
        showInactiveBuffs = false,
        desaturateInactiveBuffs = true,
        inactiveBuffAlpha = 0.45,
        -- Keybind text
        showKeybind = false,
        keybindSize = 10,
        keybindPosition = "TOPRIGHT",
        keybindOffsetX = -1,
        keybindOffsetY = -1,
        keybindColor = { 1, 1, 1, 0.9 },
        -- Charge / stack count
        showCount = true,
        countSize = 12,
        countPosition = "BOTTOMRIGHT",
        countOffsetX = -1,
        countOffsetY = 1,
        -- Cooldown countdown placement. CENTER means "leave Blizzard's own
        -- placement alone", which is why it is the default.
        cooldownTextPosition = "CENTER",
        cooldownTextOffsetX = 0,
        cooldownTextOffsetY = 0,
        -- Whole-group backdrop, distinct from the per-icon background
        barBgEnabled = false,
        barBgColor = { 0, 0, 0, 0.4 },
        barBgPadding = 2,
        -- "none" or "round"
        iconShape = "none",
    }

    self:ScheduleReconcile()
end

function cdmModule:DeleteGroup(groupName)
    local specData = GetSpecData()
    if not specData then return end
    -- Belt and braces alongside the hidden Delete button: EnsureBuiltinGroups
    -- would put it straight back, so deleting one only churns frames.
    if specData.groups[groupName] and specData.groups[groupName].builtin then return end

    -- Unassign all cooldowns in this group
    if specData.groups[groupName] then
        for _, cdID in ipairs(specData.groups[groupName].cooldownIDs or {}) do
            specData.assignments[cdID] = nil
        end
    end
    specData.groups[groupName] = nil

    -- Destroy container and clean up proxies
    local group = self.groups[groupName]
    if group then
        if group.container then
            -- Destroy proxy frames
            for cdID, _ in pairs(group.members) do
                DestroyProxy(cdID)
                local entry = self.registry[cdID]
                if entry then entry.managed = false end
            end
            group.container:Hide()
        end
    end
    self.groups[groupName] = nil

    self:ScheduleReconcile()
end

function cdmModule:AssignToGroup(cooldownID, groupName)
    local specData = GetSpecData()
    if not specData then return end

    -- Remove from previous assignment
    local prev = specData.assignments[cooldownID]
    if prev and prev ~= "FREE" and self.groups[prev] then
        self.groups[prev].members[cooldownID] = nil
    end
    if prev == "FREE" then
        self.freeIcons[cooldownID] = nil
    end

    specData.assignments[cooldownID] = groupName

    -- Add to group's cooldownID list
    if specData.groups[groupName] then
        local found = false
        for _, id in ipairs(specData.groups[groupName].cooldownIDs) do
            if id == cooldownID then found = true break end
        end
        if not found then
            table.insert(specData.groups[groupName].cooldownIDs, cooldownID)
        end
    end

    self:ScheduleReconcile()
    C_Timer.After(0.2, function() if BH.RebuildCDMTabContent then BH:RebuildCDMTabContent() end end)
end

function cdmModule:AssignFree(cooldownID)
    local specData = GetSpecData()
    if not specData then return end

    -- Remove from previous group
    local prev = specData.assignments[cooldownID]
    if prev and prev ~= "FREE" and self.groups[prev] then
        self.groups[prev].members[cooldownID] = nil
    end

    specData.assignments[cooldownID] = "FREE"

    -- Default position: screen center
    if not specData.freeIcons[cooldownID] then
        local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
        specData.freeIcons[cooldownID] = {
            x = sw / 2,
            y = sh / 2,
            iconSize = DEFAULT_ICON_SIZE,
        }
    end

    self:ScheduleReconcile()
    C_Timer.After(0.2, function() if BH.RebuildCDMTabContent then BH:RebuildCDMTabContent() end end)
end

function cdmModule:UnassignCooldown(cooldownID)
    local specData = GetSpecData()
    if not specData then return end

    local prev = specData.assignments[cooldownID]
    if prev and prev ~= "FREE" then
        -- Remove from group's cooldownID list
        if specData.groups[prev] then
            local ids = specData.groups[prev].cooldownIDs
            for i, id in ipairs(ids) do
                if id == cooldownID then
                    table.remove(ids, i)
                    break
                end
            end
        end
        if self.groups[prev] then
            self.groups[prev].members[cooldownID] = nil
        end
    end
    if prev == "FREE" then
        self.freeIcons[cooldownID] = nil
    end
    specData.freeIcons[cooldownID] = nil
    specData.assignments[cooldownID] = nil

    -- Destroy proxy frame
    DestroyProxy(cooldownID)
    local entry = self.registry[cooldownID]
    if entry then entry.managed = false end
    C_Timer.After(0.2, function() if BH.RebuildCDMTabContent then BH:RebuildCDMTabContent() end end)

    self:ScheduleReconcile()
end

-- ============================================================================
-- Get Available Cooldowns â€” List all CDM cooldowns for the settings UI
-- ============================================================================

function cdmModule:GetAvailableCooldowns()
    local cooldowns = {}
    local seenSpells = {}  -- Deduplicate by spellID across categories
    local seenNames = {}   -- Deduplicate by spell name (same spell, different IDs)
    for _, viewerInfo in ipairs(CDM_VIEWERS) do
        local catIDs = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet and
            C_CooldownViewer.GetCooldownViewerCategorySet(viewerInfo.category)
        if catIDs then
            for _, cdID in ipairs(catIDs) do
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if info and info.isKnown then
                    -- Skip if we already have this spellID from another category
                    local spellName = C_Spell.GetSpellName and C_Spell.GetSpellName(info.spellID)
                    if not seenSpells[info.spellID] and not (spellName and seenNames[spellName]) then
                        seenSpells[info.spellID] = true
                        if spellName then seenNames[spellName] = true end
                        local spellName = C_Spell.GetSpellName and C_Spell.GetSpellName(info.spellID)
                        local spellIcon = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(info.spellID)
                        -- Guard against secrets
                        if spellName and BH.Secrets.IsSecret(spellName) then
                            spellName = "Spell " .. cdID
                        end
                        if spellIcon and BH.Secrets.IsSecret(spellIcon) then
                            spellIcon = nil
                        end
                        cooldowns[cdID] = {
                            cooldownID = cdID,
                            spellID = info.spellID,
                            name = spellName or ("Spell " .. cdID),
                            icon = spellIcon,
                            viewerType = viewerInfo.viewerType,
                            category = info.category,
                        }
                    end
                end
            end
        end
    end
    return cooldowns
end

-- Discover buff-type cooldowns via C_CooldownViewer:
--   category 2 = BuffIconCooldownViewer (buff icons)
--   category 3 = BuffBarCooldownViewer  (tracked bars — procs like Beast Cleave, Barbed Shot)
-- Uses GetCooldownViewerCategorySet (same as Essential/Utility) so all known entries are
-- included even when not currently displayed.  Falls back to scanning viewer children if
-- the category API returns nothing.
function cdmModule:GetAvailableBuffCooldowns()
    local buffs = {}
    local seenSpells = {}
    local seenNames  = {}

    local function AddFromCategory(catID)
        local catIDs = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet and
            C_CooldownViewer.GetCooldownViewerCategorySet(catID)
        if not catIDs or #catIDs == 0 then return false end
        for _, cdID in ipairs(catIDs) do
            local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
            if info and info.isKnown then
                local spellName = C_Spell.GetSpellName and C_Spell.GetSpellName(info.spellID)
                if not seenSpells[info.spellID] and not (spellName and seenNames[spellName]) then
                    seenSpells[info.spellID] = true
                    if spellName then seenNames[spellName] = true end
                    local spellIcon = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(info.spellID)
                    if spellName and BH.Secrets.IsSecret(spellName) then spellName = "Buff " .. cdID end
                    if spellIcon and BH.Secrets.IsSecret(spellIcon) then spellIcon = nil end
                    buffs[cdID] = {
                        cooldownID = cdID,
                        spellID    = info.spellID,
                        name       = spellName or ("Buff " .. cdID),
                        icon       = spellIcon,
                        viewerType = "buff",
                    }
                end
            end
        end
        return true
    end

    local cat2ok = AddFromCategory(2)
    local cat3ok = AddFromCategory(3)

    if cat2ok or cat3ok then return buffs end

    -- Fallback: scan both viewer children
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            if ok and children then
                for _, child in ipairs(children) do
                    if child and child.cooldownID then
                        local cdID = child.cooldownID
                        local info = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
                                   and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                        if info and info.spellID and not seenSpells[info.spellID] then
                            seenSpells[info.spellID] = true
                            local spellName = C_Spell.GetSpellName and C_Spell.GetSpellName(info.spellID)
                            local spellIcon = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(info.spellID)
                            if spellName and BH.Secrets.IsSecret(spellName) then spellName = "Buff " .. cdID end
                            if spellIcon and BH.Secrets.IsSecret(spellIcon) then spellIcon = nil end
                            buffs[cdID] = {
                                cooldownID = cdID,
                                spellID    = info.spellID,
                                name       = spellName or ("Buff " .. cdID),
                                icon       = spellIcon,
                                viewerType = "buff",
                            }
                        end
                    end
                end
            end
        end
    end
    return buffs
end

-- ============================================================================
-- Event Handling
-- ============================================================================

local eventFrame = CreateFrame("Frame")
-- Exported only so Squizzumables_StackDiag.lua can wrap this handler from
-- outside; nothing else reads it. Remove alongside that file.
cdmModule.eventFrame = eventFrame

eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("UNIT_AURA")

-- Talent and loadout changes.
--
-- PLAYER_SPECIALIZATION_CHANGED does not fire for a talent swap inside the same
-- spec, which is why changing talents needed a reload before the sound alerts
-- matched the new build. TRAIT_CONFIG_UPDATED is the event Blizzard's own
-- CooldownViewerSettingsDataProvider listens to for exactly this
-- (SwitchToBestLayoutForSpec + SaveLayouts), and it covers spec changes too,
-- since switching spec activates a different trait config.
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("PLAYER_PVP_TALENT_UPDATE")

-- Drive the per-group visibility conditions. Cheap: each only re-evaluates
-- GroupAlpha, it does not reconcile.
-- Keybind map invalidation. Deliberately NOT ACTIONBAR_PAGE_CHANGED or the
-- form/stance events: see the note on KEYBIND_BARS about why a keybind that
-- rewrites itself every time you shapeshift is worse than a stable one.
eventFrame:RegisterEvent("UPDATE_BINDINGS")
eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- A fingerprint of which cooldowns exist right now, across all four categories.
--
-- This exists because the signals that say "the cooldown data changed" are far
-- noisier than the thing they describe. Blizzard's data provider fires
-- CooldownViewerSettings.OnDataChanged from SPELLS_CHANGED, which goes off
-- repeatedly during ordinary combat -- an aura that grants a spell is enough.
-- Resetting on every one of those is not merely wasteful: it wipes
-- soundTrackers, which is where the previous on/off state per alert lives, so
-- the next pass re-baselines against current state and detects no transition.
-- The alerts then go silent for as long as the spam continues, which is exactly
-- "plays out of combat, never in combat".
--
-- Comparing the actual set instead makes the noise harmless. The frequent
-- signals still arrive; they just do not reset anything unless the set really
-- moved, which is what a spec change, a talent swap or a loadout change does.
local function CooldownSetSignature()
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet) then
        return nil
    end
    local parts = {}
    -- 0 Essential, 1 Utility, 2 TrackedBuff, 3 TrackedBar.
    for category = 0, 3 do
        local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category)
        if ok and ids then
            local sorted = {}
            for i = 1, #ids do sorted[i] = ids[i] end
            table.sort(sorted)
            parts[#parts + 1] = category .. ":" .. table.concat(sorted, ",")
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "|")
end

local lastCooldownSignature

-- The cooldown set has changed and everything cached about it is now suspect.
--
-- Ordering matters. The maps have to be emptied before the sweep repopulates
-- them, or a stale entry that the new spec happens not to overwrite survives
-- and keeps answering for a cooldown that no longer exists.
local function OnCooldownSetChanged(debounce, force)
    local signature = CooldownSetSignature()
    -- No signature means the API is unavailable; fall through and reset rather
    -- than never resetting at all.
    if not force and signature and signature == lastCooldownSignature then return end
    lastCooldownSignature = signature

    cdmModule:ResetResolutionMaps()
    cdmModule:ScheduleReconcile(debounce or SPEC_CHANGE_DEBOUNCE)

    -- Blizzard repopulates its viewer pool on its own schedule, so one sweep
    -- right now catches whatever already exists and the standing 2s alert-hook
    -- ticker picks up the rest as the pool fills.
    HookBlizzardBuffFrames()
    HookBlizzardAlertEvents()
    ScanBlizzardBuffState()

    -- The Cooldowns tab is built per-spec (groups, assignments and the sound
    -- alert list all come from GetSpecData/GetCDMSoundAlerts, both keyed on the
    -- live spec), so leaving it up after a spec change shows the previous
    -- spec's configuration. It was only ever rebuilt by its own controls.
    if BH.RebuildCDMTabContent then
        -- Deliberately after the reconcile rather than on a fixed short delay.
        -- SPEC_CHANGE_DEBOUNCE is 1.0 because the client keeps reporting the
        -- outgoing spec's category set for a moment after
        -- PLAYER_SPECIALIZATION_CHANGED; rebuilding the grid before that
        -- redraws it from the spec being left behind, which looks identical to
        -- not rebuilding it at all.
        C_Timer.After((debounce or SPEC_CHANGE_DEBOUNCE) + 0.2, function()
            if InCombatLockdown() then return end
            BH:RebuildCDMTabContent()
            -- PopulateCDMSoundsLeft draws the spell icon grid, and it ran only
            -- when the tab was first built. Rebuilding just the right-hand pane
            -- refreshed the details of a selection while the list beside it
            -- still showed the previous spec's spells -- which is precisely the
            -- "spec changed and nothing updated" report, since the grid is the
            -- part you look at.
            if BH.PopulateCDMSoundsLeft then BH:PopulateCDMSoundsLeft() end
            if BH.RebuildCDMSoundsRight then BH:RebuildCDMSoundsRight() end
        end)
    end
end

-- Published for the alert-hook ticker, which is installed further up the file
-- and so cannot see the local above.
function cdmModule.CheckCooldownSetChanged()
    OnCooldownSetChanged(RECONCILE_DEBOUNCE)
end

-- Blizzard's own "the cooldown data changed, relayout" signal: its viewers
-- rebuild from this callback (CooldownViewerMixin:OnShow registers it to call
-- RefreshLayout), and its data provider fires it on COOLDOWN_VIEWER_TABLE_HOTFIXED,
-- PLAYER_PVP_TALENT_UPDATE and SPELLS_CHANGED. Hooking the same signal means we
-- rebuild when the viewers do rather than guessing at the game events behind it.
if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
        if BH.settings and BH.settings.cdmEnabled ~= false then
            OnCooldownSetChanged(RECONCILE_DEBOUNCE)
        end
    end, cdmModule)
end

-- Update combat visibility for all groups
local function UpdateCombatVisibility()
    local specData = GetSpecData()
    if not specData then return end
    for groupName, group in pairs(cdmModule.groups) do
        if group.container then
            group.container:SetAlpha(GroupAlpha(specData.groups[groupName]))
        end
    end
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "UPDATE_BINDINGS" or event == "ACTIONBAR_SLOT_CHANGED" then
        cdmModule.InvalidateKeybinds()
        UpdateAllProxyCooldowns()
        cdmModule:LayoutAllBorrowedBuffIcons()
        return
    end
    if event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_MOUNT_DISPLAY_CHANGED"
       or event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        UpdateCombatVisibility()
        return
    end
    if event == "SPELL_UPDATE_COOLDOWN" then
        -- Update proxy cooldown sweeps immediately
        UpdateAllProxyCooldowns()
    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then
            ScanBlizzardBuffState()
            HookBlizzardBuffFrames()
            HookBlizzardAlertEvents()
            UpdateAllProxyCooldowns()
        end
    elseif event == "SPELLS_CHANGED" then
        cdmModule:ScheduleReconcile(RECONCILE_DEBOUNCE)
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Spec changed - release all, reload for new spec.
        -- Forced: the category sets can still report the outgoing spec at the
        -- moment this fires, so a signature comparison would see no change and
        -- skip. The ticker's comparison catches the real set a moment later.
        cdmModule:ReleaseAll()
        OnCooldownSetChanged(SPEC_CHANGE_DEBOUNCE, true)
    elseif event == "TRAIT_CONFIG_UPDATED" or event == "PLAYER_PVP_TALENT_UPDATE" then
        -- A talent or loadout swap keeps the spec but can change which spells
        -- exist and which cooldownIDs the viewer uses for them, so the caches
        -- are just as stale as after a spec change. The proxies are left alone:
        -- Reconcile re-derives them, and ReleaseAll would make every icon
        -- visibly flicker on a change that often alters nothing on screen.
        OnCooldownSetChanged(SPEC_CHANGE_DEBOUNCE)
    elseif event == "PLAYER_REGEN_DISABLED" then
        isInCombat = true
        UpdateCombatVisibility()
    elseif event == "PLAYER_REGEN_ENABLED" then
        isInCombat = false
        UpdateCombatVisibility()
        -- A park that combat postponed. Without this, a Blizzard viewer that
        -- Blizzard re-anchored mid-fight stays on screen until something else
        -- happens to trigger a reconcile.
        cdmModule:FlushPendingPark()
        -- Flush pending mutations
        for _, fn in ipairs(cdmModule.pendingMutations) do
            fn()
        end
        cdmModule.pendingMutations = {}
        -- Run a full reconcile now that protected calls are allowed again
        cdmModule:ScheduleReconcile(0.1)
    end
end)

-- ============================================================================
-- Initialize â€” Called from PLAYER_LOGIN
-- ============================================================================

function cdmModule:Initialize()
    -- Ahead of the enabled checks: the hooks have to exist even when the module
    -- is off, or turning it on inside Edit Mode leaves them uninstalled.
    HookEditMode()

    -- Immediately, not via the reconcile below.
    --
    -- The reconcile is deliberately delayed half a second to let Blizzard's CDM
    -- finish setting itself up, and hiding from inside it meant Blizzard's bars
    -- were drawn on screen for that half second on every login and reload --
    -- the flash. Suppressing them is not part of the work that needs the delay.
    self:ApplyBlizzardVisibility()

    if not BH.settings or not BH.settings.cdmEnabled then return end

    -- Check if CDM is enabled
    if not GetCVarBool("cooldownViewerEnabled") then
        return
    end

    -- Delay initial reconcile to let CDM finish setup
    self:ScheduleReconcile(0.5)
end

-- ============================================================================
-- Preview Mode Integration
-- ============================================================================

function cdmModule:ShowPreview()
    for groupName, group in pairs(self.groups) do
        if group.container then
            group.container:Show()
            group.container:EnableMouse(true)
            if not group.previewOverlay then
                local ov = group.container:CreateTexture(nil, "OVERLAY")
                ov:SetAllPoints()
                ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
                group.previewOverlay = ov
            end
            group.previewOverlay:Show()

            -- Name the drag region.
            --
            -- Three built-in groups plus any custom ones means several green
            -- boxes on screen at once, and an unlabelled one is impossible to
            -- attribute -- is that Utility's region, or Essential's misplaced?
            -- Working that out from a screenshot is genuinely ambiguous, so the
            -- box says which group it is.
            if not group.previewLabel then
                -- On its own TOOLTIP-strata frame, not straight onto the
                -- container: groups overlap each other and the reminder frames,
                -- and a label drawn at the container's own strata gets covered
                -- by whatever sits on top -- which is exactly what happened to
                -- the Essential label, hidden under the Buffs group's box.
                local holder = CreateFrame("Frame", nil, group.container)
                holder:SetFrameStrata("TOOLTIP")
                holder:SetPoint("BOTTOMLEFT", group.container, "TOPLEFT", 0, 2)
                holder:SetSize(200, 14)
                local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                fs:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
                fs:SetJustifyH("LEFT")
                fs:SetTextColor(0.3, 1, 0.3)
                group.previewLabelHolder = holder
                group.previewLabel = fs
            end
            group.previewLabelHolder:Show()
            group.previewLabel:SetText(groupName)
            group.previewLabel:Show()
        end
    end
end

function cdmModule:HidePreview()
    for groupName, group in pairs(self.groups) do
        if group.previewOverlay then
            group.previewOverlay:Hide()
        end
        if group.previewLabelHolder then
            group.previewLabelHolder:Hide()
        end
        -- Restore click-through state based on lock
        if group.container then
            local specData = GetSpecData()
            local groupData = specData and specData.groups[groupName]
            if groupData and groupData.locked then
                group.container:EnableMouse(false)
                for _, proxy in pairs(group.members or {}) do
                    proxy:EnableMouse(true)
                    proxy:SetPassThroughButtons("LeftButton", "RightButton", "MiddleButton", "Button4", "Button5")
                end
            else
                group.container:EnableMouse(true)
                for _, proxy in pairs(group.members or {}) do
                    proxy:EnableMouse(true)
                    proxy:SetPassThroughButtons()
                end
            end
        end
    end
end

-- ============================================================================
-- Lock All Integration
-- ============================================================================

function cdmModule:LockAll()
    local specData = GetSpecData()
    if not specData then return end
    for groupName, groupData in pairs(specData.groups) do
        groupData.locked = true
        local group = self.groups[groupName]
        if group and group.container then
            group.container:EnableMouse(false)
            for _, proxy in pairs(group.members or {}) do
                proxy:EnableMouse(true)
                proxy:SetPassThroughButtons("LeftButton", "RightButton", "MiddleButton", "Button4", "Button5")
            end
        end
    end
end

-- ============================================================================
-- Reset Positions Integration
-- ============================================================================

function cdmModule:ResetPositions()
    local specData = GetSpecData()
    if not specData then return end

    local yOff = 0
    for groupName, groupData in pairs(specData.groups) do
        groupData.position = { x = 0, y = yOff }
        yOff = yOff - 80
        local group = self.groups[groupName]
        if group and group.container and not InCombatLockdown() then
            group.container:ClearAllPoints()
            group.container:SetPoint("CENTER", UIParent, "CENTER", groupData.position.x, groupData.position.y)
        end
    end

    for cdID, freeData in pairs(specData.freeIcons) do
        local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
        freeData.x = sw / 2
        freeData.y = sh / 2
    end

    self:ScheduleReconcile()
end

-- ============================================================================
-- Settings Tab â€” BuildCDMTab (called from Squizzumables.lua)
-- ============================================================================

-- Fallback accent, used only where a region is built and thrown away often
-- enough that registering it for live recolouring would grow the registry
-- without bound. Anything long-lived should use ns.ApplyAccent instead so it
-- follows the class-colour toggle.
local ACCENT_R, ACCENT_G, ACCENT_B = 0.87, 0.73, 0.37
local TEXT_R, TEXT_G, TEXT_B = 0.90, 0.90, 0.90
local DIM_R, DIM_G, DIM_B = 0.55, 0.55, 0.58

-- Width of the spell list beside the alert editor on the CDM Sounds tab.
local LEFT_PANEL_W = 210

-- Reference to the currently displayed group editor (for refresh)
-- Two pages share one builder.
--
--   "manager" -- the Cooldown Manager proper: the master switch and the three
--                built-in groups (Essential, Utility, Buffs) with their styling.
--   "custom"  -- custom cooldown icons: making your own groups, and assigning
--                individual spells into them or setting them loose.
--
-- Split because they are different jobs. Styling the three standard groups is
-- what most people want and was buried under a group-creation form and a long
-- list of every spell; making custom groups is a deliberate, occasional thing.
-- Parameterised rather than copied so the group section, the reconcile hooks
-- and the refresh path stay single-sourced.
local cdmTabState = {}
local cdmCustomTabState = {}

local function BuildCDMScroller(parent, state)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    state.content = content
    state.scrollFrame = scrollFrame
    state.parent = parent
end

function BH:BuildCDMTab(parent)
    BuildCDMScroller(parent, cdmTabState)
    self:RebuildCDMTabContent()
end

function BH:BuildCustomCooldownsTab(parent)
    BuildCDMScroller(parent, cdmCustomTabState)
    self:RebuildCDMTabContent()
end

-- Rebuilds whichever pages have been built. Callers throughout the module just
-- say "refresh the CDM settings" and should not have to know which tab the
-- player is looking at.
function BH:RebuildCDMTabContent()
    self:RebuildCDMPage(cdmTabState, "manager")
    self:RebuildCDMPage(cdmCustomTabState, "custom")
end

function BH:RebuildCDMPage(state, mode)
    local content = state.content
    if not content then return end

    -- Clear existing children (frames)
    for _, child in pairs({content:GetChildren()}) do
        child:Hide()
        child:SetParent(nil)
    end
    -- Clear existing regions (FontStrings, Textures from headers/dividers)
    for _, region in pairs({content:GetRegions()}) do
        region:Hide()
        region:SetParent(nil)
    end

    local leftPad = 14
    local yOffset = -14

    -- ===== HEADER =====
    local header = content:CreateFontString(nil, "OVERLAY")
    header:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    header:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
    header:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    header:SetText(mode == "custom" and "CUSTOM COOLDOWN ICONS" or "COOLDOWN MANAGER")
    yOffset = yOffset - 16

    -- Spec profile info note
    local specNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    specNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    specNote:SetWidth(380)
    specNote:SetJustifyH("LEFT")
    local _, specName = GetSpecializationInfo(GetSpecialization() or 1)
    local _, className = UnitClass("player")
    specNote:SetText("Spec profile: " .. (className or "?") .. " - " .. (specName or "?") .. " (shared across all characters)")
    specNote:SetTextColor(DIM_R, DIM_G, DIM_B)
    yOffset = yOffset - 20

    -- ===== ENABLE CHECKBOX =====
    -- Master switch, on the manager page only. It governs both pages, and two
    -- copies of one setting on two tabs is how they end up disagreeing.
    if mode ~= "custom" then
        local enableCB = CreateSQCheckbox(content, "Enable Cooldown Manager", function(checked)
            BH.settings.cdmEnabled = checked
            BH:SaveSettings()
            if checked then
                BH.cdm:Initialize()
            else
                BH.cdm:ReleaseAll()
            end
            -- Refresh the tab content to show/hide sections
            C_Timer.After(0.1, function() BH:RebuildCDMTabContent() end)
        end)
        enableCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        ns.Rows.AddTooltip(enableCB, "Enable Cooldown Manager", "Master switch for the Cooldown Manager proxy. It mirrors Blizzard's Cooldown Viewer into its own icons without touching Blizzard's frames, so it stays taint-free.")
        enableCB:SetChecked(BH.settings and BH.settings.cdmEnabled)
        yOffset = yOffset - 24

        local hideBlizzCB = CreateSQCheckbox(content, "Hide Blizzard's Cooldown Manager", function(checked)
            BH.settings.cdmHideBlizzard = checked
            BH:SaveSettings()
            BH.cdm:ApplyBlizzardVisibility()
        end)
        hideBlizzCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        ns.Rows.AddTooltip(hideBlizzCB, "Hide Blizzard's Cooldown Manager",
            "Fade out Blizzard's own cooldown bars so only these icons show. They are faded rather than hidden, "
         .. "on purpose: this addon reads live buff state from those frames, and the game stops updating a frame "
         .. "once it is hidden. Unticking brings them straight back, as does switching the Cooldown Manager off.")
        hideBlizzCB:SetChecked(BH.settings and BH.settings.cdmHideBlizzard)
        yOffset = yOffset - 24

        local followCB = CreateSQCheckbox(content, "Keep Blizzard's frames on our groups", function(checked)
            BH.settings.cdmViewersFollowGroups = checked
            BH:SaveSettings()
            BH.cdm:ApplyBlizzardVisibility()
        end)
        followCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        ns.Rows.AddTooltip(followCB, "Keep Blizzard's frames on our groups",
            "Parks each hidden Blizzard bar invisibly on top of the group that replaced it, instead of "
         .. "throwing it off screen.\n\nOnly matters if another addon anchors to EssentialCooldownViewer "
         .. "or one of its siblings: with this on those frames stay where the icons actually are, so such "
         .. "an anchor still lands correctly. Off, they go off screen and anything anchored to them goes too.")
        followCB:SetChecked(BH.settings and BH.settings.cdmViewersFollowGroups ~= false)
        yOffset = yOffset - 28
    end

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    desc:SetWidth(380)
    desc:SetJustifyH("LEFT")
    desc:SetText(mode == "custom"
        and "Make your own groups and choose which spells go in them. Anything you do not assign stays in one of the three standard groups on the Cooldowns tab."
        or "Essential, Utility and Buffs mirror Blizzard's own Cooldown Manager categories and fill themselves. Style each one below. Requires the Cooldown Manager to be enabled in Edit Mode.")
    desc:SetTextColor(DIM_R, DIM_G, DIM_B)
    yOffset = yOffset - 42

    if not (BH.settings and BH.settings.cdmEnabled) then
        content:SetHeight(math.abs(yOffset) + 20)
        return
    end

    -- ===== DIVIDER =====
    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- ===== CREATE GROUP SECTION =====
    -- Custom page only. This form is the reason the manager page used to open
    -- on a name box instead of the groups the player actually wanted to style.
    if mode == "custom" then
    local groupHeader = content:CreateFontString(nil, "OVERLAY")
    groupHeader:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    groupHeader:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
    groupHeader:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    groupHeader:SetText("GROUPS")
    yOffset = yOffset - 22

    -- New Group input row.
    --
    -- This used to be a hand-rolled backdrop frame with a borderless EditBox
    -- floated inside it, repeating the kit's control/border colours as literals.
    -- CreateSQEditBox draws exactly that, so it is one widget now and picks up
    -- the focus highlight the rest of the panel has.
    local inputBox = CreateSQEditBox(content, 220, 24, {
        maxLetters = 20, fontObject = GameFontNormal,
    })
    inputBox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)

    -- Placeholder text
    local placeholder = inputBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    placeholder:SetPoint("LEFT", inputBox, "LEFT", 6, 0)
    placeholder:SetText("Group name...")
    placeholder:SetTextColor(DIM_R, DIM_G, DIM_B, 0.6)

    inputBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then
            placeholder:Hide()
        else
            placeholder:Show()
        end
    end)

    local addBtn = CreateSQButton(content, "Create", 80, 24)
    addBtn:SetPoint("LEFT", inputBox, "RIGHT", 6, 0)
    addBtn:SetScript("OnClick", function()
        local name = strtrim(inputBox:GetText())
        if name == "" then return end
        -- Sanitize: only alphanumeric and spaces
        name = name:gsub("[^%w ]", "")
        if name == "" then return end
        BH.cdm:CreateGroup(name)
        inputBox:SetText("")
        inputBox:ClearFocus()
        C_Timer.After(0.1, function() BH:RebuildCDMTabContent() end)
    end)
    inputBox:SetScript("OnEnterPressed", function(self)
        addBtn:GetScript("OnClick")()
    end)

    yOffset = yOffset - 34
    end -- mode == "custom"

    -- ===== LIST EXISTING GROUPS =====
    local specData = GetSpecData()
    if specData then
        -- Also here, not just in reconcile: reconcile returns early when the
        -- Cooldown Manager is switched off, and someone opening this tab to
        -- turn it on should still find the three groups waiting rather than an
        -- empty page.
        BH.cdm:EnsureBuiltinGroups(specData)

        -- Each page lists only its own kind: the manager page shows the three
        -- built-ins in their declared order, the custom page shows everything
        -- else, alphabetically. pairs() alone gave an order that changed
        -- between openings, so a group moved around the page on every rebuild.
        local ordered = {}
        if mode == "custom" then
            local builtin = {}
            for _, b in ipairs(BUILTIN_GROUPS) do builtin[b.name] = true end
            for groupName, gd in pairs(specData.groups) do
                if not builtin[groupName] and not gd.builtin then
                    ordered[#ordered + 1] = groupName
                end
            end
            table.sort(ordered)
        else
            for _, b in ipairs(BUILTIN_GROUPS) do
                if specData.groups[b.name] then ordered[#ordered + 1] = b.name end
            end
        end

        if #ordered == 0 and mode == "custom" then
            local none = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            none:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            none:SetWidth(380)
            none:SetJustifyH("LEFT")
            none:SetText("No custom groups yet. Create one above, then assign spells to it below.")
            none:SetTextColor(DIM_R, DIM_G, DIM_B)
            yOffset = yOffset - 24
        end

        for _, groupName in ipairs(ordered) do
            yOffset = self:BuildGroupSection(content, leftPad, yOffset,
                groupName, specData.groups[groupName], specData)
        end
    end

    -- ===== DIVIDER =====
    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- ===== UNASSIGNED COOLDOWNS =====
    -- Custom page only. This is the long per-spell list, and it is only
    -- meaningful when there is somewhere custom to move a spell to.
    if mode == "custom" then
    local unassignedHeader = content:CreateFontString(nil, "OVERLAY")
    unassignedHeader:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    unassignedHeader:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
    unassignedHeader:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    unassignedHeader:SetText("AVAILABLE COOLDOWNS")
    yOffset = yOffset - 22

    local availDesc = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    availDesc:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    availDesc:SetWidth(380)
    availDesc:SetJustifyH("LEFT")
    availDesc:SetText("Assign cooldowns to a group or set as Free to position independently.")
    availDesc:SetTextColor(DIM_R, DIM_G, DIM_B)
    yOffset = yOffset - 22

    local cooldowns = BH.cdm:GetAvailableCooldowns()

    -- Group by category
    local categories = {
        { key = "cooldown", label = "ESSENTIAL" },
        { key = "utility",  label = "UTILITY" },
    }
    local byCat = {}
    for _, cat in ipairs(categories) do byCat[cat.key] = {} end
    for cdID, cdInfo in pairs(cooldowns) do
        local cat = cdInfo.viewerType or "cooldown"
        if not byCat[cat] then byCat[cat] = {} end
        table.insert(byCat[cat], cdInfo)
    end
    for _, list in pairs(byCat) do
        table.sort(list, function(a, b) return a.name < b.name end)
    end

    -- Build dropdown items for groups
    local groupItems = { { text = "-- Unassigned --", value = "__NONE__" }, { text = "Free Position", value = "__FREE__" } }
    if specData then
        for gName, _ in pairs(specData.groups) do
            table.insert(groupItems, { text = gName, value = gName })
        end
    end

    local totalCDs = 0
    for _, cat in ipairs(categories) do
        local list = byCat[cat.key]
        if list and #list > 0 then
            totalCDs = totalCDs + #list

            -- Category sub-header
            local catLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            catLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            catLabel:SetText(cat.label)
            catLabel:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
            yOffset = yOffset - 18

            for _, cdInfo in ipairs(list) do
                local row = CreateFrame("Frame", nil, content)
                row:SetSize(380, 36)
                row:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)

                local currentAssignment = specData and specData.assignments[cdInfo.cooldownID]
                local dd = CreateSQDropdown(row, "", 150, groupItems, function(val)
                    if val == "__NONE__" then
                        BH.cdm:UnassignCooldown(cdInfo.cooldownID)
                    elseif val == "__FREE__" then
                        BH.cdm:AssignFree(cdInfo.cooldownID)
                    else
                        BH.cdm:AssignToGroup(cdInfo.cooldownID, val)
                    end
                end)
                dd:SetPoint("TOPLEFT", row, "TOPLEFT", 192, 0)

                -- Icon
                if cdInfo.icon then
                    local icon = row:CreateTexture(nil, "ARTWORK")
                    icon:SetSize(22, 22)
                    icon:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -7)
                    icon:SetTexture(cdInfo.icon)
                    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                end

                -- Spell name
                local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 28, -11)
                nameText:SetWidth(160)
                nameText:SetJustifyH("LEFT")
                nameText:SetText(cdInfo.name)
                nameText:SetTextColor(TEXT_R, TEXT_G, TEXT_B)

                if currentAssignment == "FREE" then
                    dd:SetSelectedValue("__FREE__")
                elseif currentAssignment then
                    dd:SetSelectedValue(currentAssignment)
                else
                    dd:SetSelectedValue("__NONE__")
                end

                yOffset = yOffset - 38
            end

            yOffset = yOffset - 4
        end
    end

    if totalCDs == 0 then
        local noneText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        noneText:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        noneText:SetWidth(380)
        noneText:SetJustifyH("LEFT")
        noneText:SetText("No cooldowns found. Enable the Cooldown Manager in Edit Mode and ensure you have known abilities.")
        noneText:SetTextColor(DIM_R, DIM_G, DIM_B)
        yOffset = yOffset - 22
    end
    end -- mode == "custom"

    -- ===== DIVIDER =====
    yOffset = yOffset - 6
    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- ===== REFRESH BUTTON =====
    local refreshBtn = CreateSQButton(content, "Refresh Cooldowns", 160, 26)
    refreshBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    refreshBtn:SetScript("OnClick", function()
        BH.cdm:ScheduleReconcile(0)
        C_Timer.After(0.3, function() BH:RebuildCDMTabContent() end)
    end)
    yOffset = yOffset - 40

    content:SetHeight(math.abs(yOffset) + 20)
end

-- ===== Build a single group's settings section =====
function BH:BuildGroupSection(content, leftPad, yOffset, groupName, groupData, specData)
    local indent = leftPad + 10

    -- Group name header row with delete button
    local groupRow = CreateFrame("Frame", nil, content)
    groupRow:SetSize(380, 24)
    groupRow:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)

    local gLabel = groupRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gLabel:SetPoint("LEFT", 4, 0)
    gLabel:SetText(groupName)
    gLabel:SetTextColor(TEXT_R, TEXT_G, TEXT_B)

    -- Assigned count
    local countLabel = groupRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countLabel:SetPoint("LEFT", gLabel, "RIGHT", 8, 0)
    local assignedCount = groupData.cooldownIDs and #groupData.cooldownIDs or 0
    countLabel:SetText("(" .. assignedCount .. " assigned)")
    countLabel:SetTextColor(DIM_R, DIM_G, DIM_B)

    -- The frame name other addons anchor to.
    --
    -- Shown because the alternative is asking: an addon that anchors by typing
    -- a frame name cannot call our Lua accessor, and the obvious guess --
    -- EssentialCooldownViewer -- is Blizzard's frame, which this addon parks
    -- offscreen when "Hide Blizzard's Cooldown Manager" is on. Anchoring to
    -- that drags the anchored frame off with it, which is a confusing way to
    -- find out you picked the wrong frame.
    local anchorLabel = groupRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    anchorLabel:SetPoint("LEFT", countLabel, "RIGHT", 8, 0)
    anchorLabel:SetText("SQZ_CDMGroup_" .. groupName)
    anchorLabel:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
    ns.Rows.AddTooltip(anchorLabel, "Anchor name",
        "The frame name to give another addon that anchors to this group.\n\n"
     .. "Do not use Blizzard's EssentialCooldownViewer or similar: those are separate frames, "
     .. "and with Hide Blizzard's Cooldown Manager on they are parked far offscreen, which "
     .. "takes anything anchored to them along too.")

    -- Delete button. Not offered for the three built-in groups: they are
    -- recreated on the next reconcile anyway, so a Delete that visibly does
    -- nothing is worse than no button. Their contents can still be emptied by
    -- reassigning spells elsewhere.
    if not groupData.builtin then
        local delBtn = CreateSQButton(groupRow, "Delete", 60, 20, {0.75, 0.25, 0.25, 1})
        delBtn:SetPoint("RIGHT", groupRow, "RIGHT", 0, 0)
        delBtn:SetScript("OnClick", function()
            BH.cdm:DeleteGroup(groupName)
            C_Timer.After(0.1, function() BH:RebuildCDMTabContent() end)
        end)
    end

    yOffset = yOffset - 28

    -- ===== ROW 1: Icon Size + Spacing =====
    local sizeSlider = CreateSQSlider(content, "Icon Size", 170, 20, 80, 2)
    sizeSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(sizeSlider, "Icon Size", "Width and height of each cooldown icon in this group, in pixels.")
    sizeSlider:SetValue(groupData.iconSize or DEFAULT_ICON_SIZE)
    sizeSlider:SetAfterValueChanged(function(value)
        groupData.iconSize = value
        BH.cdm:ScheduleReconcile()
    end)

    local spacingSlider = CreateSQSlider(content, "Spacing", 170, 0, 20, 1)
    spacingSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(spacingSlider, "Spacing", "Gap between icons in this group, in pixels.")
    spacingSlider:SetValue(groupData.spacing or DEFAULT_SPACING)
    spacingSlider:SetAfterValueChanged(function(value)
        groupData.spacing = value
        BH.cdm:ScheduleReconcile()
    end)
    yOffset = yOffset - 50

    -- ===== ROW 2: Per Row + Alpha =====
    local rowSlider = CreateSQSlider(content, "Per Row", 170, 1, 20, 1)
    rowSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(rowSlider, "Per Row", "How many icons before wrapping to the next row or column.")
    rowSlider:SetValue(groupData.perRow or DEFAULT_PER_ROW)
    rowSlider:SetAfterValueChanged(function(value)
        groupData.perRow = value
        BH.cdm:ScheduleReconcile()
    end)

    local alphaSlider = CreateSQSlider(content, "Opacity", 170, 10, 100, 5)
    alphaSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(alphaSlider, "Opacity", "Transparency of this group of icons.")
    alphaSlider:SetValue(math.floor((groupData.alpha or DEFAULT_ALPHA) * 100))
    alphaSlider:SetAfterValueChanged(function(value)
        groupData.alpha = value / 100
        BH.cdm:ScheduleReconcile()
    end)
    yOffset = yOffset - 50

    -- ===== ROW 3: Orientation + Growth Direction =====
    local orientItems = {
        { text = "Horizontal", value = "horizontal" },
        { text = "Vertical",   value = "vertical" },
    }
    local orientDD = CreateSQDropdown(content, "Orientation", 170, orientItems, function(val)
        groupData.orientation = val
        BH.cdm:ScheduleReconcile()
    end)
    orientDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(orientDD, "Orientation", "Whether this group lays out horizontally or vertically.")
    orientDD:SetSelectedValue(groupData.orientation or DEFAULT_ORIENTATION)

    local growItems = {
        { text = "Right & Down", value = "rightdown" },
        { text = "Left & Down",  value = "leftdown" },
        { text = "Right & Up",   value = "rightup" },
        { text = "Left & Up",    value = "leftup" },
        { text = "Centered & Down", value = "centereddown" },
        { text = "Centered & Up",   value = "centeredup" },
    }
    local growDD = CreateSQDropdown(content, "Growth", 170, growItems, function(val)
        groupData.growDirection = val
        BH.cdm:ScheduleReconcile()
    end)
    growDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(growDD, "Growth", "Which way the group extends from its anchor as icons are added.")
    growDD:SetSelectedValue(groupData.growDirection or DEFAULT_GROW_DIRECTION)
    yOffset = yOffset - 50

    -- ===== ROW 4: Sort By =====
    local sortItems = {
        { text = "Assignment Order", value = "assignment" },
        { text = "Spell Name",      value = "name" },
        { text = "Cooldown Left",    value = "cooldown" },
    }
    local sortDD = CreateSQDropdown(content, "Sort By", 170, sortItems, function(val)
        groupData.sortBy = val
        BH.cdm:ScheduleReconcile()
    end)
    sortDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(sortDD, "Sort By", "Order the icons within this group.")
    sortDD:SetSelectedValue(groupData.sortBy or DEFAULT_SORT)
    yOffset = yOffset - 50

    -- ===== ROW 5: Checkboxes (2 columns) =====
    local lockCB = CreateSQCheckbox(content, "Lock (click-through)", function(checked)
        groupData.locked = checked
        local group = BH.cdm.groups[groupName]
        if group and group.container then
            group.container:EnableMouse(not checked)
            -- Keep proxies mouse-enabled for tooltips; use pass-through buttons for click-through
            for _, proxy in pairs(group.members or {}) do
                proxy:EnableMouse(true)
                if checked then
                    proxy:SetPassThroughButtons("LeftButton", "RightButton", "MiddleButton", "Button4", "Button5")
                else
                    proxy:SetPassThroughButtons()
                end
            end
        end
    end)
    lockCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(lockCB, "Lock (click-through)", "Stops the group being dragged and lets mouse clicks pass through to whatever is behind it. Tooltips still work.")
    lockCB:SetChecked(groupData.locked)

    local tooltipCB = CreateSQCheckbox(content, "Show Tooltip", function(checked)
        groupData.showTooltip = checked
        BH.cdm:ScheduleReconcile()
    end)
    tooltipCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(tooltipCB, "Show Tooltip", "Show the spell tooltip when hovering an icon in this group.")
    tooltipCB:SetChecked(groupData.showTooltip ~= false)
    yOffset = yOffset - 24

    local borderCB = CreateSQCheckbox(content, "Show Border", function(checked)
        groupData.showBorder = checked
        BH.cdm:ScheduleReconcile()
    end)
    borderCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(borderCB, "Show Border", "Draw a border around each icon in this group.")
    borderCB:SetChecked(groupData.showBorder ~= false)

    local cdTextCB = CreateSQCheckbox(content, "Cooldown Text", function(checked)
        groupData.showCooldownText = checked
        BH.cdm:ScheduleReconcile()
    end)
    cdTextCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(cdTextCB, "Cooldown Text", "Show the remaining cooldown as a number on the icon.")
    cdTextCB:SetChecked(groupData.showCooldownText ~= false)
    yOffset = yOffset - 24

    local desatCB = CreateSQCheckbox(content, "Desaturate When Ready", function(checked)
        groupData.desaturateReady = checked
        BH.cdm:ScheduleReconcile()
    end)
    desatCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(desatCB, "Desaturate When Ready", "Grey the icon out when the ability is ready, rather than when it is on cooldown.")
    desatCB:SetChecked(groupData.desaturateReady)

    local glowCB = CreateSQCheckbox(content, "Glow On Ready", function(checked)
        groupData.glowOnReady = checked
        BH.cdm:ScheduleReconcile()
    end)
    glowCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(glowCB, "Glow On Ready", "Highlight the icon when the ability comes off cooldown.")
    glowCB:SetChecked(groupData.glowOnReady)
    yOffset = yOffset - 24

    local enableCB = CreateSQCheckbox(content, "Enable Group", function(checked)
        groupData.enabled = checked
        BH.cdm:ScheduleReconcile()
    end)
    enableCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(enableCB, "Enable Group",
        "Show this group at all. Unticking hides it without unassigning anything, which is how you switch off one of the built-in groups you do not want.")
    enableCB:SetChecked(groupData.enabled ~= false)
    yOffset = yOffset - 24

    local combatCB = CreateSQCheckbox(content, "Hide Out of Combat", function(checked)
        groupData.hideOutOfCombat = checked
        BH.cdm:ScheduleReconcile()
    end)
    combatCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(combatCB, "Hide Out of Combat", "Only show this group while you are in combat.")
    combatCB:SetChecked(groupData.hideOutOfCombat)

    local activeOnlyCB = CreateSQCheckbox(content, "Hide Until Active", function(checked)
        groupData.hideUntilActive = checked
        BH.cdm:ScheduleReconcile()
    end)
    activeOnlyCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(activeOnlyCB, "Hide Until Active", "Only show an icon once its ability is on cooldown or its buff is active.")
    activeOnlyCB:SetChecked(groupData.hideUntilActive)
    yOffset = yOffset - 28

    -- Icon look. Border thickness/colour, icon crop and background were all
    -- hardcoded before 1.69; they are per group so two groups can look
    -- completely different, which is most of the point of having groups.
    local thickSlider = CreateSQSlider(content, "Border Thickness", 220, 0, 4, 1)
    thickSlider:SetValue(groupData.borderThickness or DEFAULT_BORDER_THICKNESS)
    thickSlider:SetAfterValueChanged(function(value)
        groupData.borderThickness = value
        BH.cdm:ScheduleReconcile()
    end)
    thickSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(thickSlider, "Border Thickness",
        "How heavy the border around each icon is, in pixels. 0 removes it without unticking Show Border.")
    yOffset = yOffset - 46

    local zoomSlider = CreateSQSlider(content, "Icon Zoom %", 220, 0, 20, 1)
    zoomSlider:SetValue(math.floor(((groupData.iconZoom or DEFAULT_ICON_ZOOM) * 100) + 0.5))
    zoomSlider:SetAfterValueChanged(function(value)
        groupData.iconZoom = value / 100
        BH.cdm:ScheduleReconcile()
    end)
    zoomSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(zoomSlider, "Icon Zoom %",
        "How much is cropped from each edge of the icon art. Higher values trim the default border off the artwork.")
    yOffset = yOffset - 46

    local bcInit = groupData.borderColor or DEFAULT_BORDER_COLOR
    local borderColorPicker = CreateSQColorPicker(content, "Border Colour",
        bcInit[1], bcInit[2], bcInit[3], bcInit[4], function(r, g, b, a)
            groupData.borderColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    borderColorPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(borderColorPicker, "Border Colour", "Colour of the icon border for this group.")

    local classColorCB = CreateSQCheckbox(content, "Use Class Colour", function(checked)
        groupData.borderClassColor = checked
        BH.cdm:ScheduleReconcile()
    end)
    classColorCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(classColorCB, "Use Class Colour",
        "Colour the border with your class colour, overriding the colour picked above.")
    classColorCB:SetChecked(groupData.borderClassColor)
    yOffset = yOffset - 28

    local bgCB = CreateSQCheckbox(content, "Icon Background", function(checked)
        groupData.bgEnabled = checked
        BH.cdm:ScheduleReconcile()
    end)
    bgCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(bgCB, "Icon Background",
        "Draw a filled square behind each icon. Mainly useful with Hide Until Active, so the group keeps a visible footprint while its icons are hidden.")
    bgCB:SetChecked(groupData.bgEnabled)

    local bgInit = groupData.bgColor or DEFAULT_BG_COLOR
    local bgColorPicker = CreateSQColorPicker(content, "Background Colour",
        bgInit[1], bgInit[2], bgInit[3], bgInit[4], function(r, g, b, a)
            groupData.bgColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    bgColorPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(bgColorPicker, "Background Colour", "Colour and opacity of the icon background.")
    yOffset = yOffset - 28

    -- Icon shape and the whole-group backdrop.
    local shapeDD = CreateSQDropdown(content, "Icon Shape", 160, {
        { text = "Square", value = "none" },
        { text = "Round",  value = "round" },
    }, function(val)
        groupData.iconShape = val
        BH.cdm:ScheduleReconcile()
    end)
    shapeDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    shapeDD:SetSelectedValue(groupData.iconShape or "none")
    ns.Rows.AddTooltip(shapeDD, "Icon Shape",
        "Round crops each icon to a circle. Does not apply to tracked buffs, which are the game's own icons.")
    yOffset = yOffset - 50

    local barBgCB = CreateSQCheckbox(content, "Group Background", function(checked)
        groupData.barBgEnabled = checked
        BH.cdm:ScheduleReconcile()
    end)
    barBgCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(barBgCB, "Group Background",
        "A panel behind the whole group rather than behind each icon. It grows and shrinks with the row, "
     .. "including as a Hide Until Active group packs down.")
    barBgCB:SetChecked(groupData.barBgEnabled)

    local barBgInit = groupData.barBgColor or { 0, 0, 0, 0.4 }
    local barBgPicker = CreateSQColorPicker(content, "Group Background Colour",
        barBgInit[1], barBgInit[2], barBgInit[3], barBgInit[4], function(r, g, b, a)
            groupData.barBgColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    barBgPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(barBgPicker, "Group Background Colour", "Colour and opacity of the group panel.")
    yOffset = yOffset - 28

    local barBgPad = CreateSQSlider(content, "Group Background Padding", 220, 0, 20, 1)
    barBgPad:SetValue(groupData.barBgPadding or 2)
    barBgPad:SetAfterValueChanged(function(value)
        groupData.barBgPadding = value
        BH.cdm:ScheduleReconcile()
    end)
    barBgPad:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(barBgPad, "Group Background Padding", "How far the panel extends past the icons.")
    yOffset = yOffset - 46

    -- Text placement. One helper for all three, so they behave identically.
    local function AddTextPlacement(label, posKey, oxKey, oyKey, defPos, defX, defY, tip)
        local dd = CreateSQDropdown(content, label .. " Position", 160, TEXT_POSITION_ITEMS, function(val)
            groupData[posKey] = val
            BH.cdm:ScheduleReconcile()
        end)
        dd:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        dd:SetSelectedValue(groupData[posKey] or defPos)
        ns.Rows.AddTooltip(dd, label .. " Position", tip)
        yOffset = yOffset - 50

        local sx = CreateSQSlider(content, label .. " Offset X", 220, -30, 30, 1)
        sx:SetValue(groupData[oxKey] or defX)
        sx:SetAfterValueChanged(function(v) groupData[oxKey] = v; BH.cdm:ScheduleReconcile() end)
        sx:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(sx, label .. " Offset X", "Nudge it sideways from that position.")
        yOffset = yOffset - 46

        local sy = CreateSQSlider(content, label .. " Offset Y", 220, -30, 30, 1)
        sy:SetValue(groupData[oyKey] or defY)
        sy:SetAfterValueChanged(function(v) groupData[oyKey] = v; BH.cdm:ScheduleReconcile() end)
        sy:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(sy, label .. " Offset Y", "Nudge it up or down from that position.")
        yOffset = yOffset - 46
    end

    -- Charge / stack count.
    local countCB = CreateSQCheckbox(content, "Show Charges", function(checked)
        groupData.showCount = checked
        BH.cdm:ScheduleReconcile()
    end)
    countCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(countCB, "Show Charges",
        "Show the charge or stack number on icons that have one.")
    countCB:SetChecked(groupData.showCount ~= false)
    yOffset = yOffset - 24

    local countSize = CreateSQSlider(content, "Charge Text Size", 220, 6, 24, 1)
    countSize:SetValue(groupData.countSize or 12)
    countSize:SetAfterValueChanged(function(v) groupData.countSize = v; BH.cdm:ScheduleReconcile() end)
    countSize:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(countSize, "Charge Text Size", "Font size of the charge number.")
    yOffset = yOffset - 46

    AddTextPlacement("Charges", "countPosition", "countOffsetX", "countOffsetY",
        "BOTTOMRIGHT", -1, 1, "Where the charge number sits on the icon.")

    AddTextPlacement("Cooldown Text", "cooldownTextPosition",
        "cooldownTextOffsetX", "cooldownTextOffsetY", "CENTER", 0, 0,
        "Where the countdown sits on the icon. Centre leaves the game's own placement alone; "
     .. "any other choice moves the countdown the game draws, which it does not officially "
     .. "support, so it is ignored rather than erroring if a patch stops exposing it.")

    -- Keybind text.
    local kbCB = CreateSQCheckbox(content, "Show Keybind", function(checked)
        groupData.showKeybind = checked
        BH.cdm:ScheduleReconcile()
    end)
    kbCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(kbCB, "Show Keybind",
        "Show the key that casts each ability on its icon.\n\n"
     .. "Read from your action bars, so an ability that is not on a bar has no key to show. "
     .. "It deliberately does not follow bar swaps from stealth, druid forms or dragonriding: "
     .. "a keybind that rewrites itself every time you shapeshift is less use than a steady one.")
    kbCB:SetChecked(groupData.showKeybind)

    local kbColor = groupData.keybindColor or { 1, 1, 1, 0.9 }
    local kbPicker = CreateSQColorPicker(content, "Keybind Colour",
        kbColor[1], kbColor[2], kbColor[3], kbColor[4], function(r, g, b, a)
            groupData.keybindColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    kbPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(kbPicker, "Keybind Colour", "Colour of the keybind text.")
    yOffset = yOffset - 28

    local kbSize = CreateSQSlider(content, "Keybind Text Size", 220, 6, 20, 1)
    kbSize:SetValue(groupData.keybindSize or 10)
    kbSize:SetAfterValueChanged(function(value)
        groupData.keybindSize = value
        BH.cdm:ScheduleReconcile()
    end)
    kbSize:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(kbSize, "Keybind Text Size", "Font size of the keybind text.")
    yOffset = yOffset - 46

    AddTextPlacement("Keybind", "keybindPosition", "keybindOffsetX", "keybindOffsetY",
        "TOPRIGHT", -1, -1, "Where the keybind sits on the icon.")

    -- Tracked-buff options. Only meaningful for a group holding buffs, so they
    -- are only offered on one: on any other group they would be dead controls.
    local grp = BH.cdm.groups[groupName]
    local holdsBuffs = (grp and grp.usesBlizzardIcons)
        or groupName == BUILTIN_FOR_VIEWERTYPE["buff"]
    if holdsBuffs then
        local alwaysCB = CreateSQCheckbox(content, "Always Show Buffs", function(checked)
            groupData.showInactiveBuffs = checked
            BH.cdm:ScheduleReconcile()
        end)
        alwaysCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(alwaysCB, "Always Show Buffs",
            "Keep a slot for every tracked buff, showing a dimmed placeholder while it is not up, "
         .. "instead of the row shrinking to only the active ones.")
        alwaysCB:SetChecked(groupData.showInactiveBuffs)

        local desatBuffCB = CreateSQCheckbox(content, "Grey Out Inactive", function(checked)
            groupData.desaturateInactiveBuffs = checked
            BH.cdm:ScheduleReconcile()
        end)
        desatBuffCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
        ns.Rows.AddTooltip(desatBuffCB, "Grey Out Inactive",
            "Draw those placeholders in greyscale. Untick to keep them in colour and rely on the "
         .. "dimming alone.")
        desatBuffCB:SetChecked(groupData.desaturateInactiveBuffs ~= false)
        yOffset = yOffset - 24

        local phAlpha = CreateSQSlider(content, "Inactive Buff Opacity %", 220, 5, 100, 5)
        phAlpha:SetValue(math.floor(((groupData.inactiveBuffAlpha or 0.45) * 100) + 0.5))
        phAlpha:SetAfterValueChanged(function(value)
            groupData.inactiveBuffAlpha = value / 100
            BH.cdm:ScheduleReconcile()
        end)
        phAlpha:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(phAlpha, "Inactive Buff Opacity %",
            "How visible the placeholder for a buff that is not up should be.")
        yOffset = yOffset - 46
    end

    -- Visibility conditions. All default off, so a group shows everywhere
    -- unless told otherwise.
    local visRows = {
        { key = "hideMounted",     label = "Hide While Mounted",
          tip = "Hide this group while you are on a mount." },
        { key = "onlyInInstances", label = "Only In Instances",
          tip = "Only show this group in a dungeon, raid, delve, scenario or battleground." },
        { key = "hideInHousing",   label = "Hide In Housing",
          tip = "Hide this group while you are inside your house or on your plot." },
        { key = "hideNoTarget",    label = "Hide Without A Target",
          tip = "Hide this group whenever you have nothing targeted." },
        { key = "hideNoEnemy",     label = "Hide Without An Enemy",
          tip = "Hide this group unless your target is something you can attack." },
    }
    for i, row in ipairs(visRows) do
        local cb = CreateSQCheckbox(content, row.label, function(checked)
            groupData[row.key] = checked
            BH.cdm:ScheduleReconcile()
        end)
        -- Two columns, same as the toggles above.
        local col = ((i - 1) % 2 == 0) and indent or (indent + 190)
        cb:SetPoint("TOPLEFT", content, "TOPLEFT", col, yOffset)
        ns.Rows.AddTooltip(cb, row.label, row.tip)
        cb:SetChecked(groupData[row.key])
        if (i % 2) == 0 or i == #visRows then yOffset = yOffset - 24 end
    end
    yOffset = yOffset - 4

    -- Anchor this group to another, so a stack of bars can be positioned by
    -- moving only the one at the top of the chain.
    local anchorItems = { { text = "Screen (free)", value = "" } }
    for otherName in pairs(specData.groups) do
        if otherName ~= groupName then
            anchorItems[#anchorItems + 1] = { text = otherName, value = otherName }
        end
    end
    table.sort(anchorItems, function(a, b) return a.value < b.value end)

    local anchorDD = CreateSQDropdown(content, "Anchor To", 160, anchorItems, function(val)
        groupData.anchorTo = val
        BH.cdm:ScheduleReconcile()
    end)
    anchorDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    anchorDD:SetSelectedValue(groupData.anchorTo or "")
    ns.Rows.AddTooltip(anchorDD, "Anchor To",
        "Attach this group to another one, so moving that group moves this with it. "
     .. "An anchored group cannot be dragged -- it is positioned by whatever it follows. "
     .. "Anchoring two groups to each other is ignored rather than allowed to break the layout.")

    local sideItems = {
        { text = "Below", value = "below" },
        { text = "Above", value = "above" },
        { text = "Left",  value = "left"  },
        { text = "Right", value = "right" },
    }
    local sideDD = CreateSQDropdown(content, "Side", 110, sideItems, function(val)
        groupData.anchorPoint = val
        BH.cdm:ScheduleReconcile()
    end)
    sideDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    sideDD:SetSelectedValue(groupData.anchorPoint or "below")
    ns.Rows.AddTooltip(sideDD, "Side", "Which side of the anchor group this one sits on.")
    yOffset = yOffset - 50

    local axSlider = CreateSQSlider(content, "Anchor Offset X", 220, -200, 200, 1)
    axSlider:SetValue(groupData.anchorX or 0)
    axSlider:SetAfterValueChanged(function(value)
        groupData.anchorX = value
        BH.cdm:ScheduleReconcile()
    end)
    axSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(axSlider, "Anchor Offset X", "Nudge this group sideways from its anchor.")
    yOffset = yOffset - 46

    local aySlider = CreateSQSlider(content, "Anchor Offset Y", 220, -200, 200, 1)
    aySlider:SetValue(groupData.anchorY or -4)
    aySlider:SetAfterValueChanged(function(value)
        groupData.anchorY = value
        BH.cdm:ScheduleReconcile()
    end)
    aySlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(aySlider, "Anchor Offset Y", "Nudge this group up or down from its anchor.")
    yOffset = yOffset - 46

    -- Thin separator
    local sep = content:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    sep:SetPoint("TOPRIGHT", content, "TOPRIGHT", -10, yOffset)
    sep:SetColorTexture(0.25, 0.25, 0.30, 0.5)
    yOffset = yOffset - 10

    return yOffset
end

-- ============================================================================
-- CDM Sounds Tab — per-cooldown sound alert configuration
-- Replicates the layout of Blizzard's New Alert panel: icon grid on the left,
-- When / Sound Alert dropdowns + Add Alert button on the right.
-- ============================================================================

local cdmSoundsState = {
    selectedCooldownID = nil,
    selectedCDInfo     = nil,
    newAlertType       = "Sound",
    newAlertWhen       = "available",
    newAlertSound      = "None",
    iconButtons        = {},
}

local CDM_SOUND_WHEN_LABELS = {
    available = "Available",
    active    = "Active (buff up)",
    start     = "On Cooldown",
    applied   = "On Aura Applied",
    removed   = "On Aura Removed",
}

function BH:BuildCDMSoundsTab(parent)
    cdmSoundsState.parent      = parent
    cdmSoundsState.iconButtons = {}

    -- ── Left panel (scrollable spell icon grid) ───────────────────────────
    local leftPanel = CreateFrame("Frame", nil, parent)
    leftPanel:SetPoint("TOPLEFT",    parent, "TOPLEFT",    0, 0)
    leftPanel:SetWidth(LEFT_PANEL_W)
    leftPanel:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)

    local leftHdr = leftPanel:CreateFontString(nil, "OVERLAY")
    leftHdr:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    ns.ApplyAccent(leftHdr, "text")
    leftHdr:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 8, -10)
    leftHdr:SetText("COOLDOWNS")

    local leftScroll = CreateFrame("ScrollFrame", nil, leftPanel, "UIPanelScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT",     leftHdr,   "BOTTOMLEFT", 0,   -6)
    leftScroll:SetPoint("BOTTOMRIGHT", leftPanel,  "BOTTOMRIGHT", -22, 4)

    local leftContent = CreateFrame("Frame", nil, leftScroll)
    leftContent:SetWidth(LEFT_PANEL_W - 30)
    leftScroll:SetScrollChild(leftContent)
    cdmSoundsState.leftContent = leftContent

    -- ── Vertical divider ──────────────────────────────────────────────────
    local divider = parent:CreateTexture(nil, "ARTWORK")
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT",    parent, "TOPLEFT",    LEFT_PANEL_W + 2, -4)
    divider:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", LEFT_PANEL_W + 2,  4)
    divider:SetColorTexture(0.25, 0.25, 0.30, 0.8)

    -- ── Right panel (alert editor) ────────────────────────────────────────
    local rightPanel = CreateFrame("Frame", nil, parent)
    rightPanel:SetPoint("TOPLEFT",     parent, "TOPLEFT",     LEFT_PANEL_W + 8, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT",  -1, 0)

    local rightScroll = CreateFrame("ScrollFrame", nil, rightPanel, "UIPanelScrollFrameTemplate")
    rightScroll:SetPoint("TOPLEFT",     rightPanel, "TOPLEFT",     0,   0)
    rightScroll:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -22, 4)

    local rightContent = CreateFrame("Frame", nil, rightScroll)
    rightScroll:SetScrollChild(rightContent)
    cdmSoundsState.rightContent = rightContent

    -- The editor stretches to whatever width the panel has, rather than sitting
    -- at a fixed 240 as it did when the options window was 460 wide. The rows
    -- inside anchor to both edges of this frame, so following a resize is just
    -- a width change -- no rebuild, which matters because OnSizeChanged fires
    -- continuously while the resize grip is being dragged.
    local function SizeRightContent()
        local w = rightScroll:GetWidth()
        if w and w > 0 then rightContent:SetWidth(w) end
    end
    rightScroll:HookScript("OnSizeChanged", SizeRightContent)
    rightContent:SetWidth(math.max(240, rightScroll:GetWidth() or 240))

    self:PopulateCDMSoundsLeft()
    self:RebuildCDMSoundsRight()
end

function BH:PopulateCDMSoundsLeft()
    local content = cdmSoundsState.leftContent
    if not content then return end

    -- Drop a selection the new spell set no longer contains.
    --
    -- The selection is a cooldownID, and a spec or talent change can retire it
    -- entirely. Leaving it set meant the right-hand pane kept rendering the
    -- details of a spell that is no longer in the list on the left, with no
    -- icon highlighted to explain where it came from.
    local stillPresent = false
    local selected = cdmSoundsState.selectedCooldownID
    if selected and BH.cdm and BH.cdm.GetAvailableCooldowns then
        for _, cdInfo in ipairs(BH.cdm:GetAvailableCooldowns() or {}) do
            if cdInfo.cooldownID == selected then stillPresent = true break end
        end
    end
    if selected and not stillPresent then
        cdmSoundsState.selectedCooldownID = nil
        cdmSoundsState.selectedCDInfo     = nil
    end

    -- Clear existing children and regions
    cdmSoundsState.iconButtons = {}
    for _, child in ipairs({content:GetChildren()}) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({content:GetRegions()}) do
        region:Hide()
        region:SetParent(nil)
    end

    if not (BH.cdm and BH.cdm.GetAvailableCooldowns) then
        local hint = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -10)
        hint:SetWidth(140)
        hint:SetText("Enable CDM to configure per-spell alerts.")
        hint:SetTextColor(DIM_R, DIM_G, DIM_B)
        content:SetHeight(50)
        return
    end

    local ICON_SIZE    = 28
    local ICON_PAD     = 3
    local ICONS_PER_ROW = 4
    local leftPad      = 4
    local yOffset      = -4

    local cooldowns     = BH.cdm:GetAvailableCooldowns()
    local buffCooldowns = BH.cdm:GetAvailableBuffCooldowns()

    -- Split into Essential / Utility / Buff buckets
    local categories = {
        { key = "cooldown", label = "ESSENTIAL" },
        { key = "utility",  label = "UTILITY"   },
        { key = "buff",     label = "BUFFS"     },
    }
    -- One entry per spell, not per cooldownID.
    --
    -- A spell can appear in two viewers at once -- Blessing of Freedom is in
    -- Utility (its cooldown) and in Buffs (the buff it applies) -- and since
    -- alerts are keyed by spell, both entries edited the same alert list while
    -- each offered only its own viewer's subset of triggers.
    --
    -- So list each spell once, placed under its cooldown-type entry where it
    -- has one, and keep the alternate cooldownIDs as `siblings` so the trigger
    -- list can be the union of what all of them support.
    local byCat = { cooldown = {}, utility = {}, buff = {} }
    local bySpell = {}

    local function AddEntry(cdInfo, cat)
        local sid = cdInfo.spellID
        local existing = sid and bySpell[sid]
        if existing then
            existing.siblings = existing.siblings or {}
            table.insert(existing.siblings, cdInfo.cooldownID)
            return
        end
        if sid then bySpell[sid] = cdInfo end
        table.insert(byCat[cat], cdInfo)
    end

    -- Cooldown-type viewers first, so they win the placement.
    for _, cdInfo in pairs(cooldowns) do
        local cat = cdInfo.viewerType or "cooldown"
        if byCat[cat] then AddEntry(cdInfo, cat) end
    end
    for _, buffInfo in pairs(buffCooldowns) do
        AddEntry(buffInfo, "buff")
    end
    for _, list in pairs(byCat) do
        table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    end

    for _, catInfo in ipairs(categories) do
        local list = byCat[catInfo.key]
        if list and #list > 0 then
            -- Category label
            local lbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            lbl:SetText(catInfo.label)
            lbl:SetTextColor(ns.GetAccentColor())
            yOffset = yOffset - 16

            local col = 0
            for _, cdInfo in ipairs(list) do
                local btn = CreateFrame("Button", nil, content)
                btn:SetSize(ICON_SIZE, ICON_SIZE)
                btn:SetPoint("TOPLEFT", content, "TOPLEFT",
                    leftPad + col * (ICON_SIZE + ICON_PAD), yOffset)

                if cdInfo.icon then
                    local iconTex = btn:CreateTexture(nil, "ARTWORK")
                    iconTex:SetAllPoints()
                    iconTex:SetTexture(cdInfo.icon)
                    iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                    btn.iconTex = iconTex
                end

                -- Hover highlight
                local hl = btn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(1, 1, 1, 0.25)

                -- Selection border (accent-coloured overlay)
                local sel = btn:CreateTexture(nil, "OVERLAY")
                sel:SetPoint("TOPLEFT",     -1,  1)
                sel:SetPoint("BOTTOMRIGHT",  1, -1)
                do local ar, ag, ab = ns.GetAccentColor(); sel:SetColorTexture(ar, ag, ab, 0.75) end
                sel:SetDrawLayer("OVERLAY", 1)
                if cdmSoundsState.selectedCooldownID == cdInfo.cooldownID then
                    sel:Show()
                    -- Rebuilding the panel makes fresh cdInfo tables, so
                    -- re-point the selection at the new one -- the old one
                    -- still carries last build's siblings list.
                    cdmSoundsState.selectedCDInfo = cdInfo
                else
                    sel:Hide()
                end
                btn.selIndicator = sel

                -- Tooltip
                btn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetSpellByID(cdInfo.spellID)
                    GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                -- Badge for "this spell has alerts configured", so the panel can
                -- be read at a glance instead of clicking every icon in turn.
                local configured = #(cdmModule.CollectAlertsFor(cdInfo.cooldownID)) > 0
                if configured then
                    local edge = btn:CreateTexture(nil, "BACKGROUND")
                    edge:SetPoint("TOPLEFT",     -2,  2)
                    edge:SetPoint("BOTTOMRIGHT",  2, -2)
                    edge:SetColorTexture(0.15, 0.85, 0.35, 1)
                    btn.configuredEdge = edge

                    local dot = btn:CreateTexture(nil, "OVERLAY")
                    dot:SetSize(10, 10)
                    dot:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 3, 3)
                    dot:SetTexture("Interface\\Common\\VoiceChat-Speaker")
                    dot:SetDrawLayer("OVERLAY", 2)
                    btn.configuredDot = dot
                elseif btn.iconTex then
                    -- Dim the ones with nothing on them, so the configured
                    -- entries carry the eye.
                    btn.iconTex:SetDesaturated(true)
                    btn.iconTex:SetAlpha(0.55)
                end

                btn.cdID   = cdInfo.cooldownID
                btn.cdInfo = cdInfo

                btn:SetScript("OnClick", function(self)
                    -- Deselect all icons
                    for _, b in ipairs(cdmSoundsState.iconButtons) do
                        if b.selIndicator then b.selIndicator:Hide() end
                    end
                    self.selIndicator:Show()
                    cdmSoundsState.selectedCooldownID = self.cdID
                    cdmSoundsState.selectedCDInfo     = self.cdInfo
                    BH:RebuildCDMSoundsRight()
                end)

                table.insert(cdmSoundsState.iconButtons, btn)

                col = col + 1
                if col >= ICONS_PER_ROW then
                    col = 0
                    yOffset = yOffset - (ICON_SIZE + ICON_PAD)
                end
            end
            if col > 0 then yOffset = yOffset - (ICON_SIZE + ICON_PAD) end
            yOffset = yOffset - 10
        end
    end

    content:SetHeight(math.abs(yOffset) + 10)
end

function BH:RebuildCDMSoundsRight()
    local content = cdmSoundsState.rightContent
    if not content then return end

    -- Clear existing children and regions
    for _, child in ipairs({content:GetChildren()}) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({content:GetRegions()}) do
        region:Hide()
        region:SetParent(nil)
    end

    local lp     = 8
    local yOff   = -10
    local cdID   = cdmSoundsState.selectedCooldownID
    local cdInfo = cdmSoundsState.selectedCDInfo

    -- No spell selected
    if not cdID or not cdInfo then
        local hint = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
        hint:SetWidth(220)
        hint:SetText("← Select a spell to configure sound alerts")
        hint:SetTextColor(DIM_R, DIM_G, DIM_B)
        content:SetHeight(40)
        return
    end

    -- ── Spell header: icon + name + "New Alert" subtitle ─────────────────
    if cdInfo.icon then
        local iconTex = content:CreateTexture(nil, "ARTWORK")
        iconTex:SetSize(32, 32)
        iconTex:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
        iconTex:SetTexture(cdInfo.icon)
        iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    local spellName = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    spellName:SetPoint("TOPLEFT", content, "TOPLEFT", lp + 38, yOff)
    spellName:SetWidth(185)
    spellName:SetJustifyH("LEFT")
    spellName:SetText(cdInfo.name)
    spellName:SetTextColor(TEXT_R, TEXT_G, TEXT_B)

    local subLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subLabel:SetPoint("TOPLEFT", content, "TOPLEFT", lp + 38, yOff - 16)
    subLabel:SetText("New Alert")
    subLabel:SetTextColor(ns.GetAccentColor())

    yOff = yOff - 44

    -- ── Divider ───────────────────────────────────────────────────────────
    local div1 = content:CreateTexture(nil, "ARTWORK")
    div1:SetHeight(1)
    div1:SetPoint("TOPLEFT",  content, "TOPLEFT",  lp,  yOff)
    div1:SetPoint("TOPRIGHT", content, "TOPRIGHT", -lp, yOff)
    div1:SetColorTexture(0.3, 0.3, 0.35, 0.8)
    yOff = yOff - 10

    -- ── Type ──────────────────────────────────────────────────────────────
    -- No "Type" control: it offered exactly one value, Sound, so it was a
    -- dropdown that could not be changed. Alerts are still stored with
    -- type = "Sound" so a second kind can be added later without a migration.
    cdmSoundsState.newAlertType = "Sound"

    -- ── When ──────────────────────────────────────────────────────────────
    local whenLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    whenLbl:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
    whenLbl:SetText("When")
    whenLbl:SetTextColor(ns.GetAccentColor())
    yOff = yOff - 2

    local isBuff = cdInfo.viewerType == "buff"
    -- Which triggers this cooldown can actually produce.
    --
    -- Ask Blizzard rather than inferring from which viewer the cooldown came
    -- from. C_CooldownViewer.GetValidAlertTypes(cooldownID) returns exactly the
    -- events that are meaningful for that spell, and it is the same list
    -- Blizzard builds its own alert UI from.
    --
    -- The old split was "buff viewer gets the aura options, everything else
    -- gets the cooldown options", which offered "Active" on every
    -- Essential/Utility cooldown. But Active fires on the buff appearing, so on
    -- a spell with no buff at all -- Hammer of Justice, Cleanse -- it could
    -- never fire, and nothing told the player that.
    local WHEN_ORDER = { "available", "start", "active", "applied", "removed" }
    local WHEN_TEXT = {
        available = "Available",
        start     = "On Cooldown",
        active    = "Active (buff up)",
        applied   = "On Aura Applied",
        removed   = "On Aura Removed",
    }

    -- Union the valid triggers across every cooldownID this spell has.
    --
    -- The left panel now lists a spell once, but Blessing of Freedom is 61107
    -- in Utility and 92824 in BuffIcon, and GetValidAlertTypes answers per
    -- cooldownID: the utility copy offers Available and On Cooldown, the buff
    -- copy offers the aura ones. Asking only the entry that happened to be
    -- listed is why the same spell showed different options depending on which
    -- of its two icons you clicked.
    local allowed = {}
    local anyAnswer = false

    local idsToAsk = { cdID }
    if cdInfo.siblings then
        for _, siblingID in ipairs(cdInfo.siblings) do
            idsToAsk[#idsToAsk + 1] = siblingID
        end
    end

    for _, askID in ipairs(idsToAsk) do
        local validTypes = C_CooldownViewer and C_CooldownViewer.GetValidAlertTypes
                           and C_CooldownViewer.GetValidAlertTypes(askID)
        if validTypes and #validTypes > 0 then
            anyAnswer = true
            for _, alertEvent in ipairs(validTypes) do
                local when = cdmModule.AlertEventToWhen[alertEvent]
                if when then allowed[when] = true end
            end
        end
    end

    if anyAnswer then
        -- "Active" is our own name for "the buff is up", which Blizzard
        -- expresses as OnAuraApplied, so offer it wherever that is valid.
        if allowed.applied then allowed.active = true end
    else
        -- No answer from the API: fall back to the previous behaviour rather
        -- than offering nothing at all.
        if isBuff then
            allowed.applied, allowed.removed = true, true
        else
            allowed.available, allowed.start, allowed.active = true, true, true
        end
    end

    local whenItems = {}
    for _, when in ipairs(WHEN_ORDER) do
        if allowed[when] then
            whenItems[#whenItems + 1] = { text = WHEN_TEXT[when], value = when }
        end
    end

    -- Keep the previous selection if this cooldown supports it, otherwise
    -- take the first option it does support. Falling back to a fixed value
    -- could select something absent from the list for this spell.
    local defaultWhen = allowed[cdmSoundsState.newAlertWhen]
                        and cdmSoundsState.newAlertWhen
                        or (whenItems[1] and whenItems[1].value)
    local whenDD = CreateSQDropdown(content, "", 200, whenItems, function(val)
        cdmSoundsState.newAlertWhen = val
    end)
    whenDD:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff - 4)
    ns.Rows.AddTooltip(whenDD, "Alert when", "Which transition fires the sound -- the ability becoming ready, going on cooldown, or its buff being applied or removed.")
    whenDD:SetSelectedValue(defaultWhen)
    cdmSoundsState.newAlertWhen = defaultWhen
    yOff = yOff - 34

    -- ── Sound Alert ───────────────────────────────────────────────────────
    local soundLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    soundLbl:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
    soundLbl:SetText("Sound Alert")
    soundLbl:SetTextColor(ns.GetAccentColor())
    yOff = yOff - 2

    local soundDD = CreateSQDropdown(content, "", 200, BH:BuildSoundDropdownItems(), function(val)
        cdmSoundsState.newAlertSound = val
    end)
    soundDD:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff - 4)
    ns.Rows.AddTooltip(soundDD, "Alert sound", "Sound played when this alert fires. Includes the bundled sounds and any registered on the Sounds tab.")
    soundDD:SetSelectedValue(cdmSoundsState.newAlertSound or "None")

    -- Speaker preview, matching every other sound dropdown in the addon. This
    -- tab was the only one without one, so there was no way to hear a sound
    -- before committing it to an alert.
    local sndPreviewBtn = CreateFrame("Button", nil, content)
    sndPreviewBtn:SetSize(22, 22)
    sndPreviewBtn:SetPoint("LEFT", soundDD, "RIGHT", 6, 0)
    local sndNorm = sndPreviewBtn:CreateTexture(nil, "BACKGROUND")
    sndNorm:SetAllPoints()
    sndNorm:SetTexture("Interface\\Common\\VoiceChat-Speaker")
    local sndHi = sndPreviewBtn:CreateTexture(nil, "HIGHLIGHT")
    sndHi:SetAllPoints()
    sndHi:SetTexture("Interface\\Common\\VoiceChat-Speaker")
    sndHi:SetAlpha(0.6)
    sndPreviewBtn:SetScript("OnEnter", function() sndNorm:SetAlpha(0.7) end)
    sndPreviewBtn:SetScript("OnLeave", function() sndNorm:SetAlpha(1.0) end)
    sndPreviewBtn:SetScript("OnClick", function()
        local snd = cdmSoundsState.newAlertSound or "None"
        if snd ~= "None" then BH:PlaySound(snd) end
    end)
    yOff = yOff - 34

    -- ── Add Alert button ──────────────────────────────────────────────────
    -- Accent, not the red danger colour it used to use: adding an alert is not
    -- a destructive action, and red is reserved for the remove buttons below.
    local addBtn = CreateSQButton(content, "Add Alert", 110, 24)
    addBtn:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
    addBtn:SetScript("OnClick", function()
        local alertType  = cdmSoundsState.newAlertType  or "Sound"
        local alertWhen  = cdmSoundsState.newAlertWhen  or "available"
        local alertSound = cdmSoundsState.newAlertSound or "None"
        if not alertSound or alertSound == "None" then return end

        local soundAlerts = GetCDMSoundAlerts()
        -- Keyed by spell, not cooldownID: cooldownIDs drift between builds and
        -- category sets, which is how the same alert ended up stored several times.
        local akey = cdmModule.AlertKey(cdID)
        if not soundAlerts[akey] then soundAlerts[akey] = {} end
        table.insert(soundAlerts[akey], {
            type  = alertType,
            when  = alertWhen,
            sound = alertSound,
        })
        -- Repopulate the left panel too: the configured badge on this
        -- spell just changed.
        BH:PopulateCDMSoundsLeft()
        BH:RebuildCDMSoundsRight()
    end)
    yOff = yOff - 34

    -- ── Divider ───────────────────────────────────────────────────────────
    local div2 = content:CreateTexture(nil, "ARTWORK")
    div2:SetHeight(1)
    div2:SetPoint("TOPLEFT",  content, "TOPLEFT",  lp,  yOff)
    div2:SetPoint("TOPRIGHT", content, "TOPRIGHT", -lp, yOff)
    div2:SetColorTexture(0.3, 0.3, 0.35, 0.8)
    yOff = yOff - 10

    -- ── Existing alerts for this spell ────────────────────────────────────
    local soundAlerts = GetCDMSoundAlerts()
    local alerts = soundAlerts[cdmModule.AlertKey(cdID)] or {}

    if #alerts == 0 then
        local noAlertsTxt = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        noAlertsTxt:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
        noAlertsTxt:SetText("No alerts added yet.")
        noAlertsTxt:SetTextColor(DIM_R, DIM_G, DIM_B)
        yOff = yOff - 20
    else
        for idx, alert in ipairs(alerts) do
            local rowBG = CreateFrame("Frame", nil, content, "BackdropTemplate")
            rowBG:SetHeight(28)
            -- Anchored to both edges so the row follows the panel width instead
            -- of staying at the 200px the old 460-wide window allowed.
            rowBG:SetPoint("TOPLEFT",  content, "TOPLEFT",   lp,  yOff)
            rowBG:SetPoint("TOPRIGHT", content, "TOPRIGHT", -lp,  yOff)
            rowBG:SetBackdrop({
                bgFile   = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeSize = 1,
            })
            rowBG:SetBackdropColor(0.14, 0.14, 0.17, 1)
            rowBG:SetBackdropBorderColor(0.25, 0.25, 0.30, 1)

            -- Speaker icon (Sound type)
            local typeIco = rowBG:CreateTexture(nil, "ARTWORK")
            typeIco:SetSize(16, 16)
            typeIco:SetPoint("LEFT", rowBG, "LEFT", 4, 0)
            typeIco:SetTexture("Interface\\Common\\VoiceChat-Speaker")

            -- When label
            local whenTxt = rowBG:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            whenTxt:SetPoint("LEFT", typeIco, "RIGHT", 4, 0)
            whenTxt:SetWidth(56)
            whenTxt:SetJustifyH("LEFT")
            whenTxt:SetText(CDM_SOUND_WHEN_LABELS[alert.when] or alert.when)
            whenTxt:SetTextColor(TEXT_R, TEXT_G, TEXT_B)

            -- Sound name (truncated)
            local sndTxt = rowBG:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            sndTxt:SetPoint("LEFT", whenTxt, "RIGHT", 2, 0)
            sndTxt:SetWidth(78)
            sndTxt:SetJustifyH("LEFT")
            sndTxt:SetText(alert.sound or "?")
            sndTxt:SetTextColor(DIM_R, DIM_G, DIM_B)

            -- Remove button
            local remBtn = CreateSQButton(rowBG, "x", 22, 20, { 0.55, 0.15, 0.15, 1 })
            remBtn:SetPoint("RIGHT", rowBG, "RIGHT", -2, 0)
            local capturedIdx = idx
            remBtn:SetScript("OnClick", function()
                local sa = GetCDMSoundAlerts()
                local akey = cdmModule.AlertKey(cdID)
                if sa[akey] then
                    table.remove(sa[akey], capturedIdx)
                    if #sa[akey] == 0 then sa[akey] = nil end
                end
                -- Repopulate the left panel too: the configured badge on this
                -- spell just changed.
                BH:PopulateCDMSoundsLeft()
                BH:RebuildCDMSoundsRight()
            end)

            yOff = yOff - 32
        end
    end

    content:SetHeight(math.abs(yOff) + 20)
end
