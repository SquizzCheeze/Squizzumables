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
--
-- "Buff Bars" is separate from "Buffs" because Blizzard draws those two
-- categories differently: category 2 is square icons, category 3 is bars with a
-- name and a timer. Both were folded into Buffs until 1.74 and laid out on the
-- icon grid, which sized a bar down to an icon's width and left it unreadable.
-- Since these are Blizzard's own frames (see BorrowBuffIcons), the bar keeps its
-- real appearance as soon as it is given bar-shaped dimensions.
local BUILTIN_GROUPS = {
    { name = "Essential", viewerType = "cooldown", defaultY = -140 },
    { name = "Utility",   viewerType = "utility",  defaultY = -185 },
    { name = "Buffs",     viewerType = "buff",     defaultY = -230 },
    { name = "Buff Bars", viewerType = "buffbar",  defaultY = -275, bars = true },
}

local BUILTIN_FOR_VIEWERTYPE = {}
for _, b in ipairs(BUILTIN_GROUPS) do BUILTIN_FOR_VIEWERTYPE[b.viewerType] = b.name end

-- Which Blizzard viewer each borrowing group takes its frames from.
--
-- Before 1.74 the layout pass walked BOTH buff viewers for ANY borrowing group,
-- so the Buffs group collected the tracked bars as well as the icons. Splitting
-- the two groups is only half the fix; without this they would both still show
-- everything. A custom group falls back to both viewers, because the player
-- assigned to it explicitly and may well have mixed the two on purpose.
local BORROW_VIEWERS = {
    [BUILTIN_FOR_VIEWERTYPE["buff"]]    = { "BuffIconCooldownViewer" },
    [BUILTIN_FOR_VIEWERTYPE["buffbar"]] = { "BuffBarCooldownViewer"  },
}

local DEFAULT_BAR_WIDTH   = 200
local DEFAULT_BAR_HEIGHT  = 20

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

-- ============================================================================
-- Per-frame state for BLIZZARD-OWNED frames.
--
-- NEVER write a field onto a Blizzard frame. Assigning to its table from addon
-- code taints the table, and from then on Blizzard's own scripts running on
-- that frame execute tainted -- which is fatal now rather than merely risky,
-- because 12.1 gave those frames secure members that refuse tainted access.
--
-- The symptom is a Blizzard-side error naming us with no Squizzumables frame in
-- the traceback at all:
--
--   CooldownViewer.lua:1865: attempted to index a table that cannot be accessed
--   while tainted (execution tainted by 'Squizzumables')
--       in function 'CheckAuraAddedAlertTriggers'
--
-- That is Blizzard's UNIT_AURA handler failing to read its own
-- auraInstanceIDToItemFramesMap, which OnLoad builds with
-- CreateSecureAuraInstanceMap(). Nothing of ours is on the stack; the taint came
-- from a dozen `viewer._sqDimmed = true`-style bookkeeping fields written
-- earlier by the viewer-hiding code. Buff alerts on the tracked-buff viewer
-- break for the rest of the session.
--
-- So the bookkeeping lives here instead, keyed by frame. Weak keys, so a frame
-- Blizzard drops is not held alive by our table.
--
-- Our OWN frames are unaffected and keep their fields directly -- proxy._sqMask
-- and the rest are on tables we created and already own.
-- ============================================================================
local blizzFrameState = setmetatable({}, { __mode = "k" })

local function BS(frame)
    local t = blizzFrameState[frame]
    if not t then
        t = {}
        blizzFrameState[frame] = t
    end
    return t
end

-- Spec key for per-spec saves
local function GetSpecKey()
    local _, _, classID = UnitClass("player")
    local specIndex = GetSpecialization() or 1
    return classID .. "_" .. specIndex
end

-- ============================================================================
-- Saved Data Access
-- ============================================================================

-- Where the CDM layout lives, and why it is split in two.
--
-- Groups -- their names, positions, sizes and every styling option -- belong to
-- the PROFILE, and are shared by every spec and every character using that
-- profile. That is what makes "set it up once on Default, and make a new
-- profile when you want something different" work. Before 1.70 they were keyed
-- by class and spec instead and lived outside profiles entirely, so saving a
-- profile did not capture the Cooldown Manager layout at all and every spec
-- started from nothing.
--
-- Assignments and free icons stay per spec, and cannot sensibly do otherwise:
-- both are keyed by cooldownID, which is a per-class, per-spec number. Sharing
-- them across a Paladin and a Shaman would map one class's spells onto whatever
-- happened to share an ID on the other. Group NAMES are what crosses over, so
-- an assignment made on one spec still points at the same shared group -- a
-- custom group simply sits empty on a spec that has assigned nothing to it, and
-- an empty group hides itself.
local function GetProfileGroups()
    -- Every one of these guards is load order, not paranoia.
    --
    -- This module's event frame registers SPELLS_CHANGED at file scope, and that
    -- fires BEFORE PLAYER_LOGIN -- so a reconcile can reach here before the
    -- profile system has been set up. `BH:GetActiveProfile` walks
    -- GetActiveProfileName -> GetCharKey, which builds `name .. "-" .. realm`
    -- from `UnitName("player")`; that is nil that early and the concatenation is
    -- a hard error, not a nil return. Before 1.70 GetSpecData touched no profile
    -- code at all, so this path did not exist.
    if not (SquizzumablesDB and SquizzumablesDB.profiles) then return nil end
    if not UnitName("player") then return nil end
    if type(BH.GetActiveProfile) ~= "function" then return nil end

    local ok, profile = pcall(BH.GetActiveProfile, BH)
    if not ok or type(profile) ~= "table" then return nil end

    if not profile.cdmGroups then
        profile.cdmGroups = {}

        -- Seed from the pre-1.70 per-spec store, so an existing layout survives
        -- the move rather than the player finding their groups gone.
        --
        -- The current spec supplies the seed: it is the layout they are looking
        -- at, and it has to be one of them now that there is a single shared
        -- set. The other specs' old tables are deliberately left on disk rather
        -- than deleted -- they are no longer read, but collapsing several
        -- per-spec layouts into one is not something to do destructively.
        local legacy = SquizzumablesDB and SquizzumablesDB.cdmData
            and SquizzumablesDB.cdmData[GetSpecKey()]
        if legacy and type(legacy.groups) == "table" and next(legacy.groups) then
            profile.cdmGroups = CopyTable(legacy.groups)
        end
    end

    return profile.cdmGroups
end

-- Get or create the CDM saved data for the current spec.
--
-- Returns a view, not a stored table: `groups` is the profile's shared table
-- while `assignments` and `freeIcons` are this spec's. Every field is handed
-- over by reference, so the ~35 existing `specData.groups[...] = x` call sites
-- keep working untouched and write straight through to the profile.
--
-- The view is cached rather than rebuilt per call because this runs from the
-- reconcile pass and from every settings row. It is rebuilt whenever the spec
-- or the active profile changes, which is exactly when the underlying tables
-- become different objects.
local specDataView
local function GetSpecData()
    if not SquizzumablesDB then return nil end
    if not SquizzumablesDB.cdmData then
        SquizzumablesDB.cdmData = {}
    end
    local key = GetSpecKey()
    local perSpec = SquizzumablesDB.cdmData[key]
    if not perSpec then
        perSpec = {
            freeIcons = {},         -- { [cooldownID] = { x, y, iconSize } }
            assignments = {},       -- { [cooldownID] = groupName or "FREE" }
        }
        SquizzumablesDB.cdmData[key] = perSpec
    end
    perSpec.assignments = perSpec.assignments or {}
    perSpec.freeIcons = perSpec.freeIcons or {}

    -- Nil rather than a scratch table when profiles are not up yet (very early
    -- login). Every caller already guards on nil, and handing back a throwaway
    -- table would silently accept edits that could never be saved.
    local groups = GetProfileGroups()
    if not groups then return nil end

    -- Keyed on table identity rather than on a spec/profile name string.
    --
    -- It is exactly as precise and allocates nothing: a different profile has a
    -- different `cdmGroups` table and a different spec a different
    -- `assignments` table, so comparing the two references catches every case a
    -- composite name key would, without building a string on a path that runs
    -- from the reconcile ticker.
    if not specDataView
       or specDataView.groups ~= groups
       or specDataView.assignments ~= perSpec.assignments
       or specDataView.freeIcons ~= perSpec.freeIcons then
        specDataView = {
            groups = groups,
            assignments = perSpec.assignments,
            freeIcons = perSpec.freeIcons,
        }
    end
    return specDataView
end

-- Drop the cached view. Called on a profile switch, where the profile's group
-- table is a different object and anything still holding the old view would go
-- on writing into the profile the player just left.
function cdmModule:InvalidateSpecData()
    specDataView = nil
end

-- Get or create the per-spec CDM per-spell sound alerts table.
local function GetCDMSoundAlerts()
    if not SquizzumablesDB then return {} end
    if not SquizzumablesDB.cdmData then SquizzumablesDB.cdmData = {} end
    local key = GetSpecKey()
    if not SquizzumablesDB.cdmData[key] then
        -- No `groups` here: those live on the profile as of 1.70, and seeding a
        -- second empty one would leave a dead table on disk that looks live.
        SquizzumablesDB.cdmData[key] = { freeIcons = {}, assignments = {} }
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

-- Borrowed frames currently masked to a group's icon shape, so they can be put
-- back square when we let go of them. WEAK KEYS: Blizzard pools these item
-- frames and we must never be the reason one stays alive.
local shapedBorrowed = setmetatable({}, { __mode = "k" })
local ApplyShapeToBorrowedChild

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

-- The spell the player CASTS right now, following any talent override.
--
-- A talent can replace a spell with another, and the cooldown then lives on
-- the replacement. Lay on Hands (633) with Empyreal Ward talented becomes
-- 471195: 633 answers isActive=false, duration=0 forever while the spellbook
-- shows a ten minute cooldown running (user report, confirmed by dump
-- 2026-09-17). Reading the base ID is reading a spell nobody is casting, so
-- the icon never greyed, never swept and never showed cooldown text.
--
-- Blizzard's own viewer does not hit this: it tracks the override at runtime,
-- registering COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED and handing what that
-- event carries to SetOverrideSpell.
--
-- NOT CACHED, deliberately. The override moves with talents, spec and
-- loadout, so a cache would need invalidating on at least three events -- and
-- this file already carries one permanently-poisoned cache
-- (cooldownSpellIDCache above, which stores `false` on a single bad read and
-- never retries). This is a plain C call returning a number; making it per
-- pass is cheaper than being wrong until the next reload.
--
-- Documented to return the ID it was given when there is no override, so the
-- ordinary case needs no branch. Guarded regardless: anything unreadable
-- falls back to the spell we were asked about.
local function LiveSpellID(spellID)
    if not spellID then return nil end
    if not (C_Spell and C_Spell.GetOverrideSpell) then return spellID end
    local ok, override = pcall(C_Spell.GetOverrideSpell, spellID)
    if not ok then return spellID end
    return BH.Secrets.SafeNumber(override, nil) or spellID
end
cdmModule.LiveSpellID = LiveSpellID

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
                   and not BS(child).alertHooked then
                    BS(child).alertHooked = true
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
                -- installed: a recycled frame carries its hooked tag with it
                -- onto a different cooldown, so recording ownership only at
                -- hook time left the new cooldown looking poll-driven.
                if child and child.cooldownID and BS(child).alertHooked then
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
-- Deliberately does NOT clear the alertHooked / buffHooked tags in BS().
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

-- Is Blizzard's item frame currently drawing an AURA rather than a cooldown?
--
-- cooldownUseAuraDisplayTime is the flag Blizzard sets alongside the values it
-- caches (CooldownViewerCooldownItemMixin:CheckCacheCooldownValuesFromAura sets
-- it true; every cooldown/charge path sets it false), and it is assigned from
-- plain `true`/`false` literals rather than derived from the aura, so unlike
-- almost everything else here it is NEVER secret. That makes it the one
-- readable "the buff is up" signal that survives combat on a cooldown icon.
local function AuraDisplayActive(child)
    if not child then return false end
    local v = child.cooldownUseAuraDisplayTime
    if BH.Secrets.IsSecret(v) then return false end
    return v and true or false
end

-- Does Blizzard's own item frame drive this proxy's sweep, rather than us?
--
-- Tracked buffs only. A buff has no spell cooldown of its own to draw, so
-- there is nothing to give up, and this is how V1.85 made buff sweeps survive
-- combat at all.
--
-- An Essential/Utility icon was briefly included here, under "Show While
-- Active", and it could not work: Blizzard hands a COOLDOWN item plain
-- start/duration numbers, and in combat those are aura-derived secrets that a
-- numeric setter refuses from tainted code. That display is an engine-drawn
-- overlay now instead (Native:SyncActiveOverlays), which needs nothing from
-- this mirror -- the proxy simply keeps drawing its cooldown underneath.
local function MirrorOwnsProxy(proxy)
    if not proxy then return false end
    return proxy.viewerType == "buff" or proxy.viewerType == "buffbar"
end
cdmModule.MirrorOwnsProxy = MirrorOwnsProxy
cdmModule.AuraDisplayActive = AuraDisplayActive

-- The active glow's colour, with its fallback in ONE place.
--
-- Deliberately not a field in CreateGroup's defaults: a profile is a deep copy
-- of those, so a colour added there would reach nobody who has already run the
-- addon, and making it reach them would need a migration. An absent field that
-- resolves here needs neither -- existing groups get the new colour, and any
-- group that has picked one keeps it.
--
-- Teal rather than the shared glow colour (gold), because the whole point of
-- this glow is to NOT read as the proc glow. Whoever wants them to match can
-- say so with the picker.
local DEFAULT_ACTIVE_GLOW_COLOR = { 0.2, 0.9, 1.0, 1 }
local function ActiveGlowColor(groupData)
    return (groupData and groupData.activeGlowColor) or DEFAULT_ACTIVE_GLOW_COLOR
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
-- Installing this inside the one-shot buffHooked gate meant such a frame
-- was tagged as hooked, skipped, and never given another chance -- which is
-- why the swipes were still missing after the first attempt. Idempotent via its
-- own tag, so repeating it is free.
local function MirrorBlizzardCooldown(child)
    local cdw = child.Cooldown or (child.GetCooldownFrame and child:GetCooldownFrame())
    if not cdw or BS(cdw).mirrorHooked then return end
    BS(cdw).mirrorHooked = true

    -- cooldownID is read at call time rather than closed over: these frames are
    -- pooled and get recycled onto other cooldowns.
    local function MirrorTo(fn)
        return function(_, ...)
            local id = child.cooldownID
            local p = id and cdmModule.proxyFrames[id]
            if p and p.Cooldown and MirrorOwnsProxy(p) then fn(p, ...) end
        end
    end

    if cdw.SetCooldownFromDurationObject then
        hooksecurefunc(cdw, "SetCooldownFromDurationObject",
            MirrorTo(function(p, durObj, ...)
                if durObj and p.Cooldown.SetCooldownFromDurationObject then
                    p.Cooldown:SetReverse(true)
                    p.Cooldown:SetCooldownFromDurationObject(durObj, ...)
                end
            end))
    end

    -- SECRET NUMBERS CANNOT BE FORWARDED HERE.
    --
    -- Not a guard that could be written more cleverly -- it is a hard rule.
    -- Handing a secret to SetCooldown from our own (tainted) code raises
    -- "Secret values are only allowed during untainted execution for this
    -- argument", once per refresh, which is ~114 errors a fight.
    --
    -- The duration-object hook above has no such limit, because an opaque
    -- handle is not a value. That asymmetry is the whole story of why tracked
    -- buffs mirror perfectly in combat and this does not: Blizzard hands a
    -- BUFF item a duration object, and a COOLDOWN item plain start/duration
    -- numbers (CooldownFrame_Set), which in combat are derived from secret
    -- data and therefore arrive secret.
    --
    -- Only tracked buffs reach this hook now (MirrorOwnsProxy), and Blizzard
    -- drives those through the duration-object setter above, so in practice
    -- this one either fires with readable numbers or does not fire at all.
    -- The guard stays regardless: the cost of being wrong once is an error
    -- every time Blizzard refreshes the frame, for the rest of the fight.
    hooksecurefunc(cdw, "SetCooldown",
        MirrorTo(function(p, start, duration, ...)
            if BH.Secrets.HasAnySecret(start, duration) then return end
            p.Cooldown:SetReverse(true)
            p.Cooldown:SetCooldown(start, duration, ...)
        end))

    -- Blizzard clears rather than re-setting when an item expires
    -- (RefreshSpellCooldownInfo -> CooldownFrame_Clear), so without this our
    -- widget keeps drawing the last sweep it was handed. Invisible on a buff,
    -- where something else is along shortly; very visible on a cooldown icon,
    -- which would sit at a full sweep while the spell was ready.
    if cdw.Clear then
        hooksecurefunc(cdw, "Clear", MirrorTo(function(p)
            if p.Cooldown.Clear then p.Cooldown:Clear() end
        end))
    end

    -- Carried across so the countdown NUMBER agrees with the sweep: aura
    -- display time and cooldown time are different clocks to the widget.
    if cdw.SetUseAuraDisplayTime then
        hooksecurefunc(cdw, "SetUseAuraDisplayTime",
            MirrorTo(function(p, use, ...)
                if p.Cooldown.SetUseAuraDisplayTime then
                    p.Cooldown:SetUseAuraDisplayTime(use, ...)
                end
            end))
    end
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
--
-- Also the unlock-mode mock: previewing fills every slot with one of these, so
-- a buff group can be positioned with its full row visible instead of only
-- whatever happens to be up while standing in town.

-- The bar-shaped parts, for a placeholder in a bar group. Before these, a bar
-- placeholder was the square icon texture stretched to the full bar size by
-- the stacking layout -- a 200x20 smear of spell art.
--
-- Returned as a table rather than set as fields here, so they are assigned in
-- GetBuffPlaceholder where the frame is built -- the linter types the frame as
-- a plain Frame everywhere else and reports every field added from outside.
-- Matching the native bars' look (Squizzumables_CDMAuras.lua's FONT and
-- DEFAULT_BAR_COLOR). A placeholder can sit in the same row as a natively drawn
-- bar, so it has to wear the same font, size rule and colour or the row shows
-- two styles.
local PLACEHOLDER_BAR_FONT  = "Fonts\\FRIZQT__.TTF"
local PLACEHOLDER_BAR_COLOR = { 1.0, 0.7, 0.0, 1 }

-- Is there a StatusBar of Blizzard's here worth mirroring?
local function CanMirrorBlizzardBar(child)
    local src = child and child.Bar
    if src == nil or BH.Secrets.IsSecret(src) then return false end
    local ok, objType = pcall(src.GetObjectType, src)
    return ok and objType == "StatusBar"
end

-- Copy Blizzard's own bar onto one of ours.
--
-- THE VALUES ARE NEVER TOUCHED IN LUA. They go straight from Blizzard's getter
-- into our setter, because a tracked bar's remaining time is SECRET in
-- instanced combat: a secret survives SetMinMaxValues/SetValue untouched, while
-- any arithmetic or comparison on one is a hard error. That single property is
-- what makes this work at all, and it is how EllesmereUI draws every tracked
-- bar (EllesmereUICdmBuffBars.lua, "reads min/max/value from Blizzard's Bar,
-- zero duration computation").
--
-- It also means we never have to know WHAT drives the bar. A totem-driven entry
-- (Consecration) has no aura for an AuraSlot of ours to bind to, but Blizzard's
-- bar already holds the right fill -- which is why Ellesmere handles those
-- without reading the totem API at all, and why this needs no totem code.
local function MirrorBlizzardBar(sb, child)
    local src = child and child.Bar
    if not src then return false end
    -- Interpolated when the client offers it: the layout pass that drives this
    -- runs on the 0.2s poll, and easing between ticks is what keeps a fill that
    -- updates five times a second from stepping visibly.
    local smooth = Enum and Enum.StatusBarInterpolation
        and Enum.StatusBarInterpolation.ExponentialEaseOut
    return (pcall(function()
        sb:SetMinMaxValues(src:GetMinMaxValues())
        if smooth then sb:SetValue(src:GetValue(), smooth)
        else sb:SetValue(src:GetValue()) end
    end))
end

-- Mirror Blizzard's own countdown onto one of our FontStrings.
--
-- THE STRING IS NEVER INSPECTED. It goes straight from their getter into our
-- setter, for exactly the reason the fill does (see MirrorBlizzardBar): the
-- rendered time is SECRET in instanced combat, and a secret survives SetText
-- untouched while ANY test on it turns it into nothing -- laundering it through
-- SafeString included.
--
-- That laundering was the first attempt here, and it is precisely why the
-- mirrored bar drew its fill correctly and left its countdown blank: SafeString
-- nil'd the secret, the helper returned nothing, and the caller had nothing to
-- write (user report 2026-09-17, "not displaying the same info as our own
-- bars"). EllesmereUI does the whole thing in one expression for this reason
-- (EllesmereUICdmBuffBars.lua:5528) -- which is the shape to copy, not just the
-- idea.
--
-- Blizzard's bar owns two FontStrings: the first is the spell name, the second
-- the countdown (their GetBlizzBarFontStrings discovers them the same way).
local function MirrorBlizzardBarText(dest, child)
    local src = child and child.Bar
    if not (src and dest) then return false end
    local ok, regions = pcall(function() return { src:GetRegions() } end)
    if not ok then return false end
    local seen = 0
    for _, rgn in ipairs(regions) do
        local okType, objType = pcall(rgn.GetObjectType, rgn)
        if okType and objType == "FontString" then
            seen = seen + 1
            if seen == 2 then
                -- One expression, no local: nothing here may look at the value.
                return (pcall(function() dest:SetText(rgn:GetText()) end))
            end
        end
    end
    return false
end

-- The border colour a group asks for, matching the native bars' BorderColor in
-- Squizzumables_CDMAuras.lua -- which is a file-local there, so this is a second
-- copy rather than a call. Keep the two reading the SAME keys: a placeholder can
-- share a row with a natively drawn bar, and two different answers show up as
-- two different borders side by side.
local function PlaceholderBorderColor(gd)
    local bc = gd.borderColor or DEFAULT_BORDER_COLOR or { 0, 0, 0, 0.9 }
    local r, g, b, a = bc[1], bc[2], bc[3], bc[4]
    if gd.borderClassColor then
        local _, class = UnitClass("player")
        local cc = class and C_ClassColor and C_ClassColor.GetClassColor
            and C_ClassColor.GetClassColor(class)
        if cc then r, g, b = cc.r, cc.g, cc.b end
    end
    return r, g, b, a
end

local function BuildPlaceholderBar(ph, icon)
    -- A real StatusBar, not a texture stretched with SetWidth.
    --
    -- SetWidth needs the remaining time as a NUMBER, and that number is secret
    -- in instanced combat -- so a width-driven fill could never show a live bar
    -- there. A StatusBar takes the secret straight from Blizzard's bar (see
    -- MirrorBlizzardBar) and renders it without ever exposing it to Lua.
    local sb = CreateFrame("StatusBar", nil, ph)
    sb:SetPoint("TOPLEFT", icon, "TOPRIGHT", 1, 0)
    sb:SetPoint("BOTTOMRIGHT", ph, "BOTTOMRIGHT", 0, 0)
    sb:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)

    local bg = sb:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(sb)
    bg:SetColorTexture(0, 0, 0, 0.5)

    local timer = sb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timer:SetPoint("RIGHT", sb, "RIGHT", -4, 0)

    local name = sb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", sb, "LEFT", 4, 0)
    name:SetPoint("RIGHT", timer, "LEFT", -4, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)

    -- The border a native bar gets from StyleBorder, which a placeholder never
    -- had -- so a mirrored bar sat in the row with no outline while the bar
    -- beside it had one (user report 2026-09-17). Anchored to PH, not to the
    -- StatusBar: a bar's border wraps the whole button, icon included, which is
    -- what StyleBorder's `d.border:GetParent()` resolves to on that side.
    local border = CreateFrame("Frame", nil, ph, "BackdropTemplate")
    border:SetFrameLevel(sb:GetFrameLevel() + 1)

    return { sb = sb, bg = bg, timer = timer, name = name, border = border }
end

-- `mirrorSource`, when given, is Blizzard's item frame whose bar this
-- placeholder stands in for: the slot is LIVE and its fill and countdown are
-- mirrored from that frame rather than left empty. Used for a tracked bar that
-- cannot be drawn natively because nothing bound an aura to it -- a totem-driven
-- one like Consecration. Absent, the placeholder behaves as it always has.
function cdmModule:GetBuffPlaceholder(group, cdID, groupData, mirrorSource)
    group.placeholders = group.placeholders or {}
    local ph = group.placeholders[cdID]
    if not ph then
        ph = CreateFrame("Frame", nil, group.container)
        ph:SetFrameStrata("MEDIUM")
        ph.isPlaceholder = true
        ph.cooldownID = cdID
        local tex = ph:CreateTexture(nil, "ARTWORK")
        ph.Icon = tex
        group.placeholders[cdID] = ph
    end

    local sid = SpellIDForCooldown(cdID)

    -- Texture resolved lazily and remembered: it can be unavailable or secret
    -- early in a login, the same way proxy icons could come up blank.
    if not ph._iconSet then
        local t = sid and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
        if t and not BH.Secrets.IsSecret(t) then
            ph.Icon:SetTexture(t)
            ph._iconSet = true
        end
    end

    -- Icon on the left and a bar beside it for a bar group; the icon fills the
    -- frame otherwise. Re-anchored only when the shape changes.
    local isBar = groupData.isBarGroup and true or false
    if ph._isBar ~= isBar then
        ph._isBar = isBar
        ph.Icon:ClearAllPoints()
        if isBar then
            ph.Icon:SetPoint("TOPLEFT", ph, "TOPLEFT", 0, 0)
            ph.Icon:SetPoint("BOTTOMLEFT", ph, "BOTTOMLEFT", 0, 0)
            if not ph.bar then ph.bar = BuildPlaceholderBar(ph, ph.Icon) end
        else
            ph.Icon:SetAllPoints()
        end
    end

    local preview = self.previewMode
    local bar = ph.bar
    if isBar and bar then
        local barH = groupData.barHeight or DEFAULT_BAR_HEIGHT
        ph.Icon:SetWidth(barH)
        if not ph._nameSet then
            local n = sid and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
            n = BH.Secrets.SafeString(n)
            if n then
                bar.name:SetText(n)
                ph._nameSet = true
            end
        end
        bar.sb:Show()
        bar.name:Show()

        -- Dressed like the native bars it shares a row with, not like itself.
        local textSize = math.max(8, math.floor(barH * 0.55 + 0.5))
        bar.name:SetFont(PLACEHOLDER_BAR_FONT, textSize, "OUTLINE")
        bar.timer:SetFont(PLACEHOLDER_BAR_FONT, textSize, "OUTLINE")
        local c = groupData.barColor or PLACEHOLDER_BAR_COLOR
        bar.sb:SetStatusBarColor(c[1] or 1, c[2] or 0.7, c[3] or 0, c[4] or 1)

        -- Same rectangle StyleBorder draws for a native bar: the whole frame,
        -- icon included, grown by the thickness on every side.
        if bar.border then
            local thickness = groupData.borderThickness or DEFAULT_BORDER_THICKNESS or 1
            local br, bgc, bb, ba = PlaceholderBorderColor(groupData)
            bar.border:ClearAllPoints()
            bar.border:SetPoint("TOPLEFT", ph, "TOPLEFT", -thickness, thickness)
            bar.border:SetPoint("BOTTOMRIGHT", ph, "BOTTOMRIGHT", thickness, -thickness)
            bar.border:SetBackdrop({ edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = thickness })
            bar.border:SetBackdropBorderColor(br, bgc, bb, ba)
            bar.border:SetShown(groupData.showBorder ~= false)
        end

        if mirrorSource then
            -- Live: Blizzard's bar drives ours, values untouched.
            MirrorBlizzardBar(bar.sb, mirrorSource)
            -- Shown only when the countdown actually mirrored: a bar with no
            -- FontString to read would otherwise sit there with stale text.
            bar.timer:SetShown(MirrorBlizzardBarText(bar.timer, mirrorSource))
        elseif preview then
            -- A running bar in the preview, so the fill and timer are part of
            -- what is being positioned.
            bar.sb:SetMinMaxValues(0, 1)
            bar.sb:SetValue(0.65)
            bar.timer:SetText("12s")
            bar.timer:Show()
        else
            -- Empty, for Always Show Buffs: this one stands for a buff that is
            -- not up.
            bar.sb:SetMinMaxValues(0, 1)
            bar.sb:SetValue(0)
            bar.timer:Hide()
        end
    elseif bar then
        bar.sb:Hide()
        bar.name:Hide()
        bar.timer:Hide()
        if bar.border then bar.border:Hide() end
    end

    local zoom = groupData.iconZoom or DEFAULT_ICON_ZOOM
    ph.Icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)

    -- Cut to the group's shape, like the native buff icons it stands in for.
    -- Read through the module table: SHAPE_FILE is a local declared further
    -- down this file, and so is not in scope here.
    local shapeFile = not isBar and cdmModule.shapeFiles
        and cdmModule.shapeFiles[groupData.iconShape or "none"] or nil
    if shapeFile then
        if not ph.mask then
            ph.mask = ph:CreateMaskTexture()
            ph.mask:SetAllPoints(ph.Icon)
        end
        ph.mask:SetTexture(shapeFile, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        if not ph._maskOn then
            ph.Icon:AddMaskTexture(ph.mask)
            ph._maskOn = true
        end
    elseif ph._maskOn then
        ph.Icon:RemoveMaskTexture(ph.mask)
        ph._maskOn = false
    end
    -- Drawn as a live buff while previewing: the point is to show how the
    -- group will look when it is up. Dimmed and greyed only when it stands for
    -- a buff that is genuinely not there.
    if preview or mirrorSource then
        ph.Icon:SetDesaturated(false)
        ph:SetAlpha(1)
    else
        ph.Icon:SetDesaturated(groupData.desaturateInactiveBuffs ~= false)
        ph:SetAlpha(groupData.inactiveBuffAlpha or 0.45)
    end
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

-- Move a Blizzard buff frame whose buff we draw natively out of sight.
--
-- Parked, not hidden: Blizzard stops updating a hidden item, and both the row
-- packing (IsShown) and the sound alerts read its live state. Re-applied on
-- every pass, because Blizzard re-anchors its items on its own layout passes.
-- SetPoint is the only kind of write this module makes to Blizzard's frames.
local HoldBorrowedParked  -- defined just below; ParkBorrowedFrame installs it

local function ParkBorrowedFrame(child)
    BS(child).borrowParked = true
    BS(child).borrowParkGuard = true
    child:ClearAllPoints()
    child:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", -2000, -2000)
    -- ALPHA IS THE ONE THAT ACTUALLY HOLDS. Position can only ever be put back
    -- a frame AFTER Blizzard moves it, so while its aura is up and its own
    -- layout keeps running, chasing SetPoint leaves a one-frame ghost every
    -- time -- which is the flicker this was meant to stop and did not.
    -- Alpha survives any amount of re-anchoring.
    --
    -- Faded rather than hidden, deliberately, for the same reason the whole
    -- viewers are (see HoldAlphaZero): the game stops updating a HIDDEN frame,
    -- and this module reads live buff state from these very frames.
    child:SetAlpha(0)
    BS(child).borrowParkGuard = nil
    HoldBorrowedParked(child)
end

--- Give a borrowed frame back: fully visible, and no longer chased.
---
--- Restores alpha to 1 rather than to whatever it was, matching how
--- ApplyBlizzardVisibility restores a dimmed viewer -- Blizzard's own next
--- refresh re-asserts the real value if it differs.
local function UnparkBorrowedFrame(child)
    if not BS(child).borrowParked then return end
    BS(child).borrowParked = nil
    BS(child).borrowParkGuard = true
    child:SetAlpha(1)
    BS(child).borrowParkGuard = nil
end

--- Keep a parked frame parked BETWEEN poll ticks.
---
--- Re-parking from the 0.2s layout pass is enough while nothing else moves the
--- frame. Blizzard does: the moment its aura goes active it shows and
--- re-anchors the item, which then draws at the viewer's real position until
--- our next tick. On a buff that toggles quickly -- a movement aura, say --
--- that reads as a SECOND copy of the bar flickering behind Blizzard's viewer,
--- which is exactly what it is (user report 2026-09-16: a stray buff bar
--- appearing behind the Essential bar, but only while moving).
---
--- Same shape as HoldParked, which solves the identical problem for whole
--- viewers. Borrowed CHILDREN never reach that path, because
--- ApplyBlizzardVisibility deliberately exempts both buff viewers -- their
--- children are the icons we borrow, so dimming the parent would hide our own
--- row -- and the exemption takes the re-park hook with it.
---
--- Three rules carried across, each load-bearing:
---   * NEVER re-anchor inline. That layout pass goes on to move protected
---     systems, so re-anchoring from inside it carries this addon's taint into
---     the rest of it. C_Timer.After(0) runs with none of that lineage and
---     coalesces the ClearAllPoints + SetPoint burst into a single re-park.
---   * Gate on a flag that can be CLEARED. hooksecurefunc cannot be undone, so
---     a hook that always re-parks would strand a frame offscreen forever once
---     it stops being ours -- worse than the bug it fixes. borrowParked is set
---     here and cleared by the layout the moment it uses the frame as a real
---     slot again.
---   * Ignore our own writes, via borrowParkGuard.
function HoldBorrowedParked(child)
    if BS(child).borrowPointHooked then return end
    BS(child).borrowPointHooked = true

    local function QueueRepark(self)
        if not BS(self).borrowParked or BS(self).borrowParkGuard
           or BS(self).borrowParkQueued then
            return
        end
        BS(self).borrowParkQueued = true
        C_Timer.After(0, function()
            BS(self).borrowParkQueued = nil
            if BS(self).borrowParked then ParkBorrowedFrame(self) end
        end)
    end

    hooksecurefunc(child, "SetPoint", QueueRepark)
    hooksecurefunc(child, "ClearAllPoints", QueueRepark)

    -- The one that does the real work. Blizzard raises this frame's alpha
    -- whenever its aura goes active; put it straight back while it is ours.
    -- Inline is safe here, unlike the re-anchor above: SetAlpha touches no
    -- protected system, and applying it a frame late is what would show.
    hooksecurefunc(child, "SetAlpha", function(self, a)
        if BS(self).borrowParked and a ~= 0 and not BS(self).borrowParkGuard then
            BS(self).borrowParkGuard = true
            self:SetAlpha(0)
            BS(self).borrowParkGuard = nil
        end
    end)
end

-- Is this Blizzard buff item up because of a totem rather than an aura?
--
-- Then a native slot has nothing to show -- slots match auras -- so Blizzard's
-- frame keeps the slot for that pass. Read from the fields Blizzard's own item
-- data sets (CooldownViewerItemDataMixin: SetAuraInstanceInfo writes
-- auraInstanceID, SetTotemData writes totemData, both cleared to nil). Plain
-- field reads, which taint nothing.
--
-- Secret probes first, always: auraInstanceID is secret in instanced combat,
-- and a secret ID is still an aura that is there -- so it means "aura".
local function ItemDrivenByTotem(child)
    local aura = child.auraInstanceID
    if BH.Secrets.IsSecret(aura) or aura ~= nil then return false end
    local totem = child.totemData
    if BH.Secrets.IsSecret(totem) then return true end
    return totem ~= nil
end

-- Finish the native cells after a layout pass.
--
-- A cell in a slot of its own is a buff that is up: fully visible, keybind and
-- all. One riding on a placeholder is a buff that is not up, kept invisible so
-- only the placeholder's keybind draws -- and if the buff comes up before the
-- next pass, its button appears in exactly that slot. Idle cells (not up, no
-- placeholder) wait invisibly in the middle of the group.
function cdmModule:SettleNativeCells(groupName, group, slots, idle)
    for _, f in ipairs(slots) do
        if f.isNativeCell then
            f:SetAlpha(1)
        elseif f._sqCell then
            local cell = f._sqCell
            cell:ClearAllPoints()
            cell:SetAllPoints(f)
            cell:SetAlpha(0)
        end
    end
    for _, cell in ipairs(idle) do
        cell:ClearAllPoints()
        cell:SetPoint("CENTER", group.container, "CENTER")
        cell:SetAlpha(0)
    end

    -- A hidden group frame hides its AuraContainer too, and a hidden container
    -- stops listening for aura changes. Re-scan once when the group reappears.
    local visible = #slots > 0 or self.previewMode
    if visible and not group._sqWasVisible and self.native then
        self.native:Refresh(groupName)
    end
    group._sqWasVisible = visible
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
    -- Unlock mode forces it on, as the mock of the full group: see
    -- GetBuffPlaceholder.
    local showInactive = (groupData.showInactiveBuffs or self.previewMode) and true or false

    -- Buffs drawn natively (Squizzumables_CDMAuras.lua) take their slot as a
    -- cell of ours instead of Blizzard's frame.
    --
    -- Blizzard's frame still says WHETHER the buff is up: IsShown is a plain
    -- flag, readable in combat, and it is what already drives the packing
    -- below. So the row packs exactly as before; only what sits in each slot
    -- changes, and Blizzard's frame is parked (ParkBorrowedFrame).
    --
    -- A buff native in ANOTHER group is parked and skipped here. A buff whose
    -- slot failed to build is not native at all, so it falls straight back to
    -- being borrowed and cannot go missing.
    local native = self.native
    local nativeOn = native and native:IsEnabled() or false
    local shown, inactive, idle = {}, {}, {}
    for _, viewerName in ipairs(BORROW_VIEWERS[groupName] or BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            if ok and children then
                for _, child in ipairs(children) do
                    local cdID = child and child.cooldownID
                    if cdID then
                        local isNative = nativeOn and native:IsNative(cdID)
                        -- Up because of a totem: the slot has no aura for a
                        -- cell of ours to bind to.
                        local byTotem = isNative and child:IsShown()
                            and ItemDrivenByTotem(child)
                        -- ... but Blizzard's own bar still holds the right
                        -- fill, so a BAR group draws one of ours and mirrors
                        -- that bar instead of handing the slot back. Without
                        -- this, one row shows two different looks: Consecration
                        -- (totem-driven) in Blizzard's style beside Shield of
                        -- the Righteous in ours (user report 2026-09-17).
                        --
                        -- Bar groups only. An icon group has nothing to mirror
                        -- -- Bar is nil on those children, confirmed by
                        -- /sq cdmbuff -- so those keep the old behaviour.
                        local mirrorTotem = byTotem and groupData.isBarGroup
                            and CanMirrorBlizzardBar(child) and true or false
                        local useCell = isNative and not byTotem
                        local cell = (useCell or mirrorTotem)
                            and native:GetCell(groupName, cdID) or nil
                        if useCell or mirrorTotem then
                            ParkBorrowedFrame(child)
                        else
                            -- Blizzard's frame is the slot again (not native,
                            -- or driven by a totem with no bar to mirror), so
                            -- it must stop being chased AND get its alpha back
                            -- -- the layout below is about to place it in the
                            -- group for real.
                            UnparkBorrowedFrame(child)
                        end
                        local slotFrame
                        if mirrorTotem then
                            -- A live placeholder: its fill and countdown come
                            -- from the frame we just parked.
                            local ph = self:GetBuffPlaceholder(group, cdID, groupData, child)
                            -- The (permanently empty) native cell rides along
                            -- invisibly, exactly as it does for an inactive
                            -- buff -- see SettleNativeCells.
                            ph._sqCell = cell
                            slotFrame = ph
                        else
                            -- NEVER DROP A CHILD WE CANNOT PLACE.
                            --
                            -- This was `cell or ((not useCell) and child) or nil`,
                            -- which is nil when useCell is true and the cell is
                            -- missing -- and a nil slotFrame is skipped
                            -- entirely below, so the buff vanished while
                            -- Blizzard was plainly still drawing it.
                            --
                            -- That combination is reachable: IsNative reads
                            -- `nativeCooldowns[cdID]`, which is GLOBAL, while
                            -- GetCell only answers for the group that claimed
                            -- it (`st.active[cdID]`). Retire clears the claim
                            -- only when it matches its own group name, so a
                            -- claim left by another group strands the entry --
                            -- IsNative true everywhere, cell nil here.
                            --
                            -- Bone Shield on a Death Knight is the reported
                            -- case (2026-09-20): active, present in
                            -- BuffIconCooldownViewer, tracked, and invisible,
                            -- while Blood Debt beside it drew fine -- the
                            -- difference being that Bone Shield is a same-name
                            -- duplicate of its own cooldown and so travels via
                            -- buffExtras rather than discovered.
                            --
                            -- Blizzard's frame is the floor. If we have no cell
                            -- of our own for a child, show Blizzard's: the
                            -- group then looks like Blizzard's until our cell
                            -- turns up, instead of losing the buff outright.
                            slotFrame = cell or child
                            if not cell then
                                -- It may have been parked a few lines above on
                                -- the strength of useCell. Placing a parked
                                -- frame puts it in the row at alpha 0, which
                                -- looks identical to the bug being unfixed.
                                UnparkBorrowedFrame(child)
                            end
                        end
                        if slotFrame then
                            if child:IsShown() then
                                shown[#shown + 1] = slotFrame
                            elseif showInactive then
                                inactive[#inactive + 1] = cdID
                            elseif cell then
                                idle[#idle + 1] = cell
                            end
                        end
                        -- Its cell waits out of sight while Blizzard's frame
                        -- stands in. Not needed when we mirror instead: the
                        -- placeholder carries the cell itself.
                        if byTotem and not mirrorTotem then
                            local standby = native:GetCell(groupName, cdID)
                            if standby then idle[#idle + 1] = standby end
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
    for _, f in ipairs(shown) do slots[#slots + 1] = f end
    if showInactive then
        for _, cdID in ipairs(inactive) do
            local ph = self:GetBuffPlaceholder(group, cdID, groupData)
            -- Reset every pass: the placeholder is reused, and a buff that has
            -- stopped being native must not leave its old cell attached.
            ph._sqCell = nativeOn and native:GetCell(groupName, cdID) or nil
            slots[#slots + 1] = ph
        end
    end
    self:ReleaseUnusedPlaceholders(group, slots)
    shown = slots

    -- Bars stack; icons grid.
    --
    -- A tracked bar is Blizzard's own bar frame -- a fill, a spell name and a
    -- timer -- so it only needs bar-shaped dimensions to look like one. Laying
    -- it out on the icon grid is what made it unreadable before 1.74: the grid
    -- gives every slot iconSize x iconSize, which squashes a 200-wide bar into a
    -- 32px square.
    --
    -- One per row always. perRow is an icon idea, and side-by-side bars are not
    -- how Blizzard draws these or how anyone reads them.
    if groupData.isBarGroup then
        local barW    = groupData.barWidth  or DEFAULT_BAR_WIDTH
        local barH    = groupData.barHeight or DEFAULT_BAR_HEIGHT
        local up      = (growDir == "centeredup" or growDir == "rightup" or growDir == "leftup")
        local fullH   = math.max(#shown, 1) * (barH + spacing) - spacing

        for i, child in ipairs(shown) do
            child:SetSize(barW, barH)
            child:ClearAllPoints()
            ApplyKeybindText(child, SpellIDForCooldown(child.cooldownID), groupData)
            local offset = (i - 1) * (barH + spacing)
            child:SetPoint(up and "BOTTOM" or "TOP", group.container,
                up and "BOTTOM" or "TOP", 0, up and offset or -offset)
        end

        if not InCombatLockdown() then
            group.container:SetSize(barW, fullH)
        end
        self:SettleNativeCells(groupName, group, shown, idle)
        group.container:SetShown(#shown > 0 or self.previewMode)
        ApplyBarBackground(group, groupData)
        group.container:SetAlpha(GroupAlpha(groupData))
        return
    end

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
        -- ONE STYLING PASS OVER WHATEVER IS IN THE SLOT, which is the whole
        -- point: a Blizzard item, a placeholder of ours and a native cell all
        -- take the group's shape here, so the row cannot come out half round
        -- and half square depending on which renderer won each slot.
        -- Bar groups are deliberately excluded (see the branch above) -- a
        -- shape is an icon idea and a bar has no silhouette to cut.
        ApplyShapeToBorrowedChild(child, groupData.iconShape or "none",
            groupData.iconZoom or DEFAULT_ICON_ZOOM)
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
    -- Empty but previewing still has to be draggable. See the note on
    -- cdmModule.previewMode: this pass runs on a 0.2s poll, so hiding an empty
    -- borrowed group here un-does what ShowPreview just did.
    self:SettleNativeCells(groupName, group, shown, idle)
    group.container:SetShown(#shown > 0 or self.previewMode)
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

-- Install the mirror on every viewer item frame that currently exists.
--
-- Deliberately separate from HookBlizzardBuffFrames and much cheaper: it only
-- walks children and tags, with no closures created for already-hooked frames.
-- Driven from the 0.2s poll so a frame the viewer acquires mid-fight is picked
-- up within a fifth of a second, rather than waiting for a reconcile that will
-- not happen until combat ends.
--
-- The two BUFF viewers only. Essential/Utility items were briefly included,
-- when "Show While Active" was going to borrow their sweep; that could never
-- work (see MirrorOwnsProxy) and the display is an engine-drawn overlay now,
-- so hooking them would install a closure on every cooldown widget in the game
-- for a mirror that always declines.
--
-- Through ForEachViewerItem rather than GetChildren: item frames are pooled
-- and handed out lazily, so a plain child sweep can run before a viewer has
-- acquired any.
local function MirrorAllBuffCooldowns()
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            ForEachViewerItem(viewer, function(child)
                if child and child.cooldownID then
                    MirrorBlizzardCooldown(child)
                end
            end)
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
                        if not BS(child).buffHooked then
                            BS(child).buffHooked = true
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
    { category = 0, viewerType = "cooldown", viewer = "EssentialCooldownViewer" },
    { category = 1, viewerType = "utility",  viewer = "UtilityCooldownViewer"   },
    { category = 2, viewerType = "buff",     viewer = "BuffIconCooldownViewer"  },
    -- Category 3 is "buffbar", not "buff": it is the tracked BARS, and since
    -- 1.74 they get their own group rather than being squeezed onto the buff
    -- icon grid. Everything else about them is identical to category 2, so the
    -- two share every code path except the layout.
    { category = 3, viewerType = "buffbar",  viewer = "BuffBarCooldownViewer"   },
}

-- The player's Cooldown Manager filter, read WITHOUT running any Blizzard Lua.
--
-- READ THIS BEFORE CHANGING IT. There is a way to get this list that looks far
-- more obvious and is catastrophic; it shipped in 1.70 and took three versions
-- to find.
--
-- What the player arranges in Blizzard's Cooldown Manager -- what is hidden,
-- what order things sit in, which trinkets they dragged onto a bar -- exists
-- only in a saved layout. No C_CooldownViewer function exposes it.
-- `GetCooldownViewerCategorySet` returns the raw default set for a category and
-- knows nothing about any of it: hidden entries are moved to the
-- pseudo-categories `HiddenActive` (-1) / `HiddenPassive` (-2), entries flagged
-- `HideByDefault` go the same way before the player has touched anything, and
-- equip-slot entries live in categories that have no viewer at all.
--
-- THE TRAP: `viewer:GetCooldownIDs()` returns exactly the list we want. It is
-- also Lua, so it runs on OUR stack --
-- `CooldownViewerSettings:GetDataProvider():GetOrderedCooldownIDsForCategory()`
-- and through it `CheckBuildDisplayData()`, which REBUILDS `displayData`. Every
-- table it writes is tainted by us from that moment. `/sq cdmtaint` measured it
-- on a live client:
--
--     data provider:    displayData<-Squizzumables
--     display data:     orderedCooldownIDs<-Squizzumables
--                       cooldownInfoByID<-Squizzumables
--                       defaultOrderedCooldownIDs<-Squizzumables
--     first item frame: cooldownID<-Squizzumables
--
-- Those tables are the Cooldown Manager's spine, so afterwards every Blizzard
-- path that read them ran tainted too. One Mythic+ session produced thousands
-- of errors inside Blizzard's own CheckAuraAddedAlertTriggers, RefreshTotemData,
-- GetUnitAuras, CacheChargeValues and ShouldDisplaySpellCooldown -- all their
-- code, all blamed on this addon, none with any of our frames in the traceback.
-- It survived reloads because we re-tainted within seconds of login.
--
-- The reasoning that let it ship: the comment here used to argue the call was
-- safe because no C_CooldownViewer function carries `HasRestrictions`. That flag
-- governs whether a PROTECTED CALL IS REFUSED. It says nothing about TAINT
-- SPREAD, which happens by execution. Two mechanisms, conflated, and the
-- conflation then cited as prior verification. Do not reason from flags here;
-- measure with /sq cdmtaint.
--
-- THE WAY THAT WORKS: do not ask for the list. Blizzard already asked, on its
-- own clean stack, and left the answer lying on the item frames.
--
--     function CooldownViewerMixin:RefreshLayout(cooldownIDs)
--         self.itemFramePool:ReleaseAll();
--         cooldownIDs = cooldownIDs or self:GetCooldownIDs();
--         for i = 1, self:GetItemCount(cooldownIDs) do
--             local itemFrame = self.itemFramePool:Acquire();
--             itemFrame.layoutIndex = i;
--
-- and `RefreshData` then sets each frame's `cooldownID` from `cooldownIDs[layoutIndex]`.
-- So `cooldownID` and `layoutIndex` on the pooled frames ARE the filtered,
-- ordered list -- membership, order, trinkets and all. Reading two plain fields
-- executes no Blizzard Lua and taints nothing. Confirmed against
-- Gethe/wow-ui-source live.
--
-- Three details that make this correct rather than nearly-correct:
--
-- 1. HIDDEN IS NOT RELEASED. A cooldown hidden by Blizzard's own "hide when
--    inactive" keeps its pool frame and is merely not shown; frames are only
--    released wholesale by the next RefreshLayout. So this must enumerate the
--    POOL, never the shown children -- `GetChildren()` or a `:IsShown()` filter
--    would silently drop every inactive cooldown, and only for players using
--    that Blizzard setting. An earlier attempt at this feature did exactly that.
--
-- 2. THE POOL IS PADDED. `GetItemCount` enforces `minimumItemCount = 2`, so a
--    category with fewer than two entries still acquires two frames. Blizzard
--    calls `ClearCooldownID()` on the surplus, so they read nil and skip
--    themselves -- which is why this tests `cooldownID` rather than trusting
--    `layoutIndex` to be dense.
--
-- 3. IT IS LAZY. The pool is empty until Blizzard has built the viewer, which
--    is well after our first discovery pass at login. An empty answer means
--    "not built yet", NOT "the player hid everything", so it falls back to the
--    raw category set. Nothing has to be hooked to recover: `CooldownSetSignature`
--    hashes this list too, so when the pool fills, the signature changes and the
--    standing 2s ticker's `CheckCooldownSetChanged` reconciles. The same path
--    covers the player editing Blizzard's Cooldown Manager options -- that
--    rebuilds the viewer, which changes this list, which changes the signature.
--
--    That costs up to two seconds on a settings edit, and a `hooksecurefunc` on
--    `itemFramePool.Acquire` would make it instant. Deliberately not done: it
--    puts our code inside Blizzard's RefreshLayout call chain, which is the
--    exact neighbourhood that cost 1.70 through 1.72, to save two seconds on a
--    screen the player is already looking at. `hooksecurefunc` is in fact the
--    safe mechanism -- it saves and restores taint around the hook, which is why
--    the item-frame hooks elsewhere in this file measure clean, and it is not
--    the same thing as inserting a closure into a `CallbackRegistry` that
--    Blizzard iterates in a plain loop. Safe and worth it are different
--    questions, and the answer to the second one here is no.
--
-- EllesmereUI reaches the same place from the other end: it re-anchors
-- Blizzard's item frames onto its own bars and parks the rest offscreen, so its
-- filtering is perfect because it never filters -- Blizzard decides which frames
-- exist and it only moves them. That also works, and it is what our Buffs group
-- does; the cost is that Blizzard's icons cannot carry our per-group border,
-- zoom, shape and text styling, which is why the cooldown groups proxy instead.
local function BlizzardFilteredIDs(viewerGlobal)
    local viewer = viewerGlobal and _G[viewerGlobal]
    if type(viewer) ~= "table" then return nil end

    local pool = viewer.itemFramePool
    if type(pool) ~= "table" or type(pool.EnumerateActive) ~= "function" then
        return nil
    end

    -- pcall only because EnumerateActive is Blizzard's iterator and the pool may
    -- not be initialised on an early login. Nothing inside the loop can throw:
    -- both reads are plain field access on a frame.
    local entries = {}
    local ok = pcall(function()
        for item in pool:EnumerateActive() do
            local cdID = item.cooldownID
            local index = item.layoutIndex
            if type(cdID) == "number" and type(index) == "number" then
                entries[#entries + 1] = { id = cdID, index = index }
            end
        end
    end)
    if not ok or #entries == 0 then return nil end

    -- By layoutIndex, which is the player's own arrangement. EnumerateActive
    -- walks a hash table, so its order is arbitrary and would reshuffle our
    -- icons on every pass without this.
    table.sort(entries, function(a, b) return a.index < b.index end)

    local ids, seen = {}, {}
    for _, entry in ipairs(entries) do
        if not seen[entry.id] then
            seen[entry.id] = true
            ids[#ids + 1] = entry.id
        end
    end
    return ids
end

-- Whether the last discovery pass managed to read the pool, per viewer.
-- Reported by /sq cdm: "our groups show more than Blizzard's bars" and "the
-- filter is being honoured but the player hid nothing" look identical on
-- screen, and only this tells them apart.
cdmModule.usedBlizzardFilter = {}

local function DiscoverCooldowns()
    local discovered = {}
    -- Buff entries dropped as duplicates of a cooldown (see below). Kept out of
    -- the registry, but returned: Blizzard still shows them on its buff bar,
    -- so the native buff slots need one for each or they stay Blizzard frames
    -- in the middle of a row of ours.
    local buffExtras = {}
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
    --
    -- Only Essential and Utility are the cooldown side of that divide. This
    -- was `viewerType ~= "buff"` until 1.76, written before 1.74 split tracked
    -- bars out as "buffbar" -- which silently put the bars on the cooldown
    -- side too, so a buff icon sharing a name with a tracked bar was dropped
    -- as a "duplicate" of it.
    local seenCdSpell, seenCdName = {}, {}
    for _, viewerInfo in ipairs(DISCOVER_CATEGORIES) do
        local isCooldownType = (viewerInfo.viewerType == "cooldown"
                                or viewerInfo.viewerType == "utility")

        -- What Blizzard actually put on its own bar, read off the item frames.
        -- The raw category set only when the pool cannot answer, which means
        -- the viewer has not been built yet -- see the note above.
        local catIDs = BlizzardFilteredIDs(viewerInfo.viewer)
        cdmModule.usedBlizzardFilter[viewerInfo.viewer] = (catIDs ~= nil)
        if not catIDs then
            catIDs = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
                and C_CooldownViewer.GetCooldownViewerCategorySet(viewerInfo.category)
        end

        if catIDs then
            for orderIndex, cdID in ipairs(catIDs) do
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if info and info.isKnown then
                    -- spellID is nilable as of 12.1 and really is absent on the
                    -- equip-slot entries (a trinket is identified by its
                    -- inventory slot, not a spell), which the filtered list can
                    -- now hand us. Every use of it below is guarded because
                    -- `seenCdSpell[nil] = true` is not a silent no-op -- it is
                    -- a hard "table index is nil" error that would take the
                    -- whole discovery pass down.
                    local spellID   = info.spellID
                    -- equipSlot is real on 12.1 (Blizzard's own item mixin
                    -- drives a trinket's entire cooldown off it) but the
                    -- language server's bundled annotations predate it, the
                    -- same lag that makes them wrong about spellID being
                    -- non-nilable. Confirmed in Blizzard's generated docs on
                    -- Gethe/wow-ui-source live, 12.1.0 build 69587.
                    ---@diagnostic disable-next-line: undefined-field
                    local equipSlot = info.equipSlot
                    local name = spellID and C_Spell.GetSpellName
                        and C_Spell.GetSpellName(spellID)
                    name = BH.Secrets.SafeString(name, nil)
                    local isDuplicate = (not isCooldownType)
                        and ((spellID and seenCdSpell[spellID])
                             or (name and seenCdName[name]))
                    -- A cooldown-type entry is never a duplicate, so this is
                    -- exactly the old "recorded only when kept" behaviour.
                    if isCooldownType then
                        if spellID then seenCdSpell[spellID] = true end
                        if name then seenCdName[name] = true end
                    end

                    do
                        -- Which spell IDs might carry this cooldown's aura.
                        --
                        -- A tracked buff's aura is very often NOT info.spellID:
                        -- the API hands the alternatives over as overrideSpellID
                        -- and linkedSpellIDs. Reading only spellID is why buff
                        -- icons drew no duration swipe -- the aura lookup missed
                        -- and it fell through to a spell cooldown that a
                        -- buff-only entry does not have.
                        local auraIDs = {}
                        if spellID then auraIDs[#auraIDs + 1] = spellID end
                        if info.overrideSpellID then
                            auraIDs[#auraIDs + 1] = info.overrideSpellID
                        end
                        -- overrideTooltipSpellID deliberately NOT added here.
                        -- Blizzard's GetSpellID prefers it, but this list is
                        -- also what the tracked-buff duration lookup walks, and
                        -- a tooltip override is a display alias rather than a
                        -- promise that an aura exists under that ID. Widening
                        -- it risks the 1.69 buff swipe binding to the wrong
                        -- aura, for no gain: the override and linked IDs below
                        -- already cover the forms a proc actually fires on.
                        if type(info.linkedSpellIDs) == "table" then
                            for _, lid in ipairs(info.linkedSpellIDs) do
                                auraIDs[#auraIDs + 1] = lid
                            end
                        end

                        local record = {
                            cooldownID = cdID,
                            spellID = spellID,
                            equipSlot = equipSlot,
                            viewerType = viewerInfo.viewerType,
                            auraIDs = auraIDs,
                            hasAura = info.hasAura,
                            -- For the native buff slots: which unit the aura
                            -- sits on, and the tooltip override Blizzard's own
                            -- buff item matches as well (kept out of auraIDs
                            -- for the reason given above).
                            selfAura = info.selfAura,
                            tooltipSpellID = info.overrideTooltipSpellID,
                            -- Blizzard's own ordering, so the default
                            -- "assignment" sort lays a group out the way the
                            -- player arranged the matching Blizzard bar.
                            order = orderIndex,
                        }
                        if isDuplicate then
                            buffExtras[cdID] = record
                        else
                            discovered[cdID] = record
                        end
                    end
                end
            end
        end
    end
    return discovered, buffExtras
end

-- ============================================================================
-- Proxy Frame Creation â€” Our own frames that mirror the cooldown icon + sweep.
-- We NEVER write to Blizzard's CDM frame tables to avoid taint.
-- ============================================================================

-- The icon art for a proxy, spell or trinket.
--
-- An equip-slot entry has no spellID to ask, so it goes through ItemUtil the
-- way Blizzard's own item frame does (`CooldownViewerItemDataMixin:GetSpellTexture`
-- prefers the equip-slot texture over any spell texture). Returns nil rather
-- than a placeholder when nothing is available yet, so the existing retry in
-- ApplyProxyVisuals keeps working.
local function ResolveProxyTexture(spellID, equipSlot)
    if equipSlot and ItemUtil and ItemUtil.GetEquipSlotTexture then
        local tex = ItemUtil.GetEquipSlotTexture(equipSlot)
        if tex and not BH.Secrets.IsSecret(tex) then return tex end
    end
    if spellID and C_Spell.GetSpellTexture then
        local tex = C_Spell.GetSpellTexture(spellID)
        if tex and not BH.Secrets.IsSecret(tex) then return tex end
    end
    return nil
end

-- The glows stay on the icons' own strata, high up its frame levels.
--
-- A glow spills past its icon by design (1.4x), so it overlaps whatever sits
-- next to the group. At MEDIUM that is a frame-level contest, and SquizzFrames'
-- resource bar border (MEDIUM, bar level + 4) won it, cutting the top off the
-- glow on an icon row sitting just below the bar.
--
-- 1.77 raised the strata to HIGH instead, and that was too far: HIGH is where
-- the world map lives, so a glow drew over the open map. A big frame level
-- inside MEDIUM beats any ordinary neighbour -- addons stack a handful of
-- levels above their own frame, not hundreds -- while everything in a higher
-- strata, the map included, still covers it.
--
-- Fixed as well as set: a child normally follows its parent when that changes,
-- and PositionFreeIcon re-asserts MEDIUM on the proxy every time a free icon is
-- placed, which would drag the glow straight back down. Blizzard's alert frame
-- (the square-icon glow) is created as a child of the glow frame, so it
-- inherits this too. The glow frames take no mouse input, so nothing under
-- them becomes unclickable.
local GLOW_STRATA = "MEDIUM"
local GLOW_LEVEL  = 300

local function RaiseGlowFrame(f)
    f:SetFrameStrata(GLOW_STRATA)
    f:SetFixedFrameStrata(true)
    f:SetFrameLevel(GLOW_LEVEL)
    f:SetFixedFrameLevel(true)
end

local function CreateProxyIcon(cooldownID, spellID, iconSize, equipSlot)
    local proxy = CreateFrame("Frame", nil, UIParent)
    proxy:SetSize(iconSize, iconSize)
    proxy:SetFrameStrata("MEDIUM")
    proxy.spellID = spellID
    proxy.equipSlot = equipSlot
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
    local texture = ResolveProxyTexture(spellID, equipSlot)
    if texture then
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
    RaiseGlowFrame(glow)
    proxy.GlowFrame = glow
    proxy._glowShowing = false

    -- Proc glow, on its own frame rather than sharing GlowFrame.
    --
    -- ActionButtonSpellAlertManager keys its active-alert table by frame, so
    -- two features glowing the same frame share one entry: whichever finished
    -- first would call HideAlert and take the other's glow down with it. The
    -- "glow when the cooldown comes up" option is ours and times out after two
    -- seconds; the proc glow is Blizzard's and lasts as long as the proc. They
    -- overlap rarely, but when they do neither should cancel the other.
    local procGlow = CreateFrame("Frame", nil, proxy)
    procGlow:SetAllPoints()
    RaiseGlowFrame(procGlow)
    proxy.ProcGlow = procGlow

    -- Active glow, on a third frame for the same reason ProcGlow has a second.
    --
    -- This one is held for as long as the buff is up, so it overlaps both of
    -- the others routinely rather than rarely -- and ActionButtonSpellAlertManager
    -- keys by frame, so sharing would have whichever ended first take the
    -- other down with it.
    --
    -- Deliberately the SELF-DRAWN tier: ns.Glow.Show/Set force it whenever an
    -- anchorTo is passed, giving a pulsing halo in the glow colour rather than
    -- Blizzard's proc art. That is the point -- "the ability is running" has to
    -- read differently at a glance from "the ability just procced".
    local activeGlow = CreateFrame("Frame", nil, proxy)
    activeGlow:SetAllPoints()
    RaiseGlowFrame(activeGlow)
    proxy.ActiveGlow = activeGlow

    -- Default on, so a free-positioned icon -- which never goes through
    -- ApplyProxyVisuals, having no group to read settings from -- still behaves
    -- the way Blizzard's own icons do rather than silently missing both.
    -- viewerType is not known yet at this point; the caller sets it immediately
    -- after, and ApplyProxyVisuals re-derives both flags for grouped icons.
    proxy._procGlowAllowed = true
    proxy._usableTintAllowed = true

    return proxy
end

-- ============================================================================
-- Blizzard parity for cooldown icons: proc glow, usable tint, range tint.
--
-- Everything here mirrors CooldownViewerCooldownItemMixin, which is what
-- Blizzard's Essential and Utility bars run. Ours are proxy frames rather than
-- Blizzard's item frames, so none of it comes for free the way the tracked-buff
-- swipes do -- each piece has to be driven from the same events Blizzard
-- listens to. Verified against Gethe/wow-ui-source live, 12.1.0 build 69587.
--
-- None of these APIs is protected: C_SpellActivationOverlay.IsSpellOverlayed
-- and C_Spell.IsSpellUsable both carry only SecretArguments in the generated
-- docs, no HasRestrictions, so there is no combat-queue or lineage problem
-- here of the kind AddAuraSound has.
-- ============================================================================

-- Blizzard's exact colours, from CooldownViewerConstants.
local TINT_USABLE      = { 1.0,  1.0,  1.0  }
local TINT_NO_MANA     = { 0.5,  0.5,  1.0  }
local TINT_UNUSABLE    = { 0.4,  0.4,  0.4  }
local TINT_OUT_OF_RANGE= { 0.64, 0.15, 0.15 }

-- Cheap enough to call from the update pass: it only reaches the widget when
-- the icon has actually been resized since the last time.
local function ResizeSpellAlert(proxy)
    if not proxy then return end
    local w = proxy:GetWidth()
    if not w or w <= 0 or proxy._alertSizedFor == w then return end
    proxy._alertSizedFor = w
    if proxy.ProcGlow then ns.Glow.Resize(proxy.ProcGlow) end
    if proxy.GlowFrame then ns.Glow.Resize(proxy.GlowFrame) end
    -- The active glow is held for the whole duration of a buff, so it is the
    -- one most likely to still be running when the size slider moves.
    if proxy.ActiveGlow then ns.Glow.Resize(proxy.ActiveGlow) end
end

-- Does this proxy answer to `spellID` for proc purposes?
--
-- Blizzard compares the event's spellID against the item's resolved GetSpellID,
-- which prefers the override and aura IDs over the base spell. We already
-- collect exactly that set as auraSpellIDs (base + override + overrideTooltip +
-- linked), so a proc reported against an overridden form of the spell still
-- finds its icon.
local function ProxyMatchesSpell(proxy, spellID)
    if not proxy or not spellID then return false end
    if proxy.spellID == spellID then return true end
    for _, sid in ipairs(proxy.auraSpellIDs or {}) do
        if sid == spellID then return true end
    end
    return false
end

-- Is this spell lit up by a proc right now?
--
-- Secret probe before the truthiness test, never after: a bare `if value` on a
-- secret is a hard error in its own right, which is the rule that took the buff
-- scan down in 1.69. Unreadable counts as "not procced" -- the quiet direction,
-- a missing glow rather than one stuck on.
--
-- A file-local rather than a closure inside the caller: this runs per spell ID,
-- per icon, per update pass, and allocating a function at each of those is the
-- exact cost that got the old per-comparison pcall wrappers removed.
local function SpellIsOverlayed(spellID)
    if not spellID then return false end
    if not (C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed) then
        return false
    end
    local v = C_SpellActivationOverlay.IsSpellOverlayed(spellID)
    if BH.Secrets.IsSecret(v) then return false end
    return v and true or false
end

local function SetProcGlow(proxy, on, skipBirth)
    if not proxy or not proxy.ProcGlow then return end
    on = on and true or false
    if on == (proxy._procGlowing or false) then return end
    proxy._procGlowing = on
    if on then
        ResizeSpellAlert(proxy)
        ns.Glow.Show(proxy.ProcGlow, nil, skipBirth)
    else
        ns.Glow.Hide(proxy.ProcGlow)
    end
end

-- Ask the client whether this spell is currently procced, rather than waiting
-- for the next event.
--
-- Needed because the events are edge-triggered: a proc that lit up before the
-- icon existed (a reload mid-fight, a group being switched on, a spec change)
-- would never be reflected otherwise. Blizzard does the same thing from
-- RefreshOverlayGlow whenever it rebuilds an item, and passes skipBirth so a
-- glow that was already running does not replay its spawn animation.
local function SyncProcGlow(proxy, allowed)
    if not proxy or not proxy.ProcGlow then return end
    if not allowed then
        SetProcGlow(proxy, false)
        return
    end
    local overlayed = false
    if C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
        for _, sid in ipairs(proxy.auraSpellIDs or {}) do
            if SpellIsOverlayed(sid) then
                overlayed = true
                break
            end
        end
        if not overlayed and SpellIsOverlayed(proxy.spellID) then
            overlayed = true
        end
    end
    local skipBirth = true
    SetProcGlow(proxy, overlayed, skipBirth)
end

-- Usable / out-of-range tint, Blizzard's RefreshIconColor.
--
-- Kept off the desaturation path deliberately: SetDesaturated and
-- SetVertexColor are independent, and the group's own "grey out when ready"
-- option means something different from Blizzard's "grey out while unusable".
-- Both can apply at once, exactly as they do on Blizzard's own icons.
--
-- The last colour applied is cached because this runs on every update pass for
-- every icon, and SetVertexColor on an unchanged colour is still work.
local function ApplyUsableTint(proxy, enabled)
    if not proxy or not proxy.Icon then return end

    local tint = TINT_USABLE
    if enabled and proxy.spellID then
        if proxy._outOfRange then
            tint = TINT_OUT_OF_RANGE
        elseif C_Spell.IsSpellUsable then
            local usable, noMana = C_Spell.IsSpellUsable(LiveSpellID(proxy.spellID))
            -- Secret probe first: a bare truthiness test on a secret is a hard
            -- error, so these cannot simply be believed. Unreadable falls
            -- through to "looks usable", which is the quiet direction -- an
            -- icon at full colour, never a spuriously greyed one.
            if not BH.Secrets.HasAnySecret(usable, noMana) then
                if usable then
                    tint = TINT_USABLE
                elseif noMana then
                    tint = TINT_NO_MANA
                else
                    tint = TINT_UNUSABLE
                end
            end
        end
    end

    if proxy._tint ~= tint then
        proxy._tint = tint
        proxy.Icon:SetVertexColor(tint[1], tint[2], tint[3])
    end
end

local function UpdateProxyCooldown(proxy)
    if not proxy or not proxy.Cooldown then return end

    -- Trinkets and the like: no spell, so the cooldown comes off the inventory
    -- slot. Blizzard reads it exactly this way in
    -- CheckCacheCooldownValuesFromEquippedItem. Through SafeNumber because
    -- these are ordinary numbers that go secret in combat like any other, and
    -- `start + duration` on a secret throws rather than misbehaving.
    if not proxy.spellID then
        if proxy.equipSlot and GetInventoryItemCooldown then
            local start, duration = GetInventoryItemCooldown("player", proxy.equipSlot)
            start = BH.Secrets.SafeNumber(start, nil)
            duration = BH.Secrets.SafeNumber(duration, nil)
            if start and duration then
                proxy.Cooldown:SetReverse(false)
                proxy.Cooldown:SetCooldown(start, duration)
            end
        end
        return
    end

    -- AURA SWEEPS ARE FOR BUFF ENTRIES ONLY.
    --
    -- Both branches below read an AURA and draw its remaining time, then
    -- return. That is right for a tracked buff and wrong for a cooldown entry
    -- whose spell merely happens to apply one: the icon shows the buff's few
    -- seconds and returns, so the real cooldown is never drawn and never gets
    -- its countdown text.
    --
    -- Lay on Hands with Empyreal Ward talented is exactly that (user report,
    -- reproduced 2026-09-17). The talent gives Lay on Hands an 8 second buff
    -- on the target, which reaches auraIDs through overrideSpellID /
    -- linkedSpellIDs -- so a ten minute cooldown rendered as eight seconds of
    -- sweep and then lit back up, with no cooldown text at any point. Untalent
    -- it and the same spell behaves perfectly, which is what made this look
    -- like a per-player mystery for so long.
    --
    -- An Essential/Utility icon shows its COOLDOWN, full stop. Tracking the
    -- buff is what the Buffs and Buff Bars groups are for, and they do it
    -- properly -- through Blizzard's own frames, which survives combat.
    local isBuffEntry = (proxy.viewerType == "buff" or proxy.viewerType == "buffbar")

    -- "Show While Active" on an Essential/Utility icon.
    --
    -- This does NOT look the aura up. The first attempt did -- via the Tracked
    -- Buffs twin's auraInstanceID, then GetPlayerAuraBySpellID -- and it could
    -- not work in combat by construction: an item frame's auraInstanceID is
    -- secret in instanced combat, and GetPlayerAuraBySpellID answers nothing
    -- once auras are secret. Both paths fell through exactly when the feature
    -- mattered, which is what "it doesn't work in combat" was.
    --
    -- Nor is it copied off Blizzard's own active icon, which was the second
    -- attempt. Blizzard does draw exactly this (its
    -- CheckCacheCooldownValuesFromAura gives a self buff precedence over the
    -- spell's cooldown until it is gone), but the values it caches are taken
    -- from the aura and are therefore AURA-aspect secrets, while a numeric
    -- cooldown setter accepts a secret from tainted code only when it carries
    -- the COOLDOWN aspect. Forwarding them raised an error on every refresh.
    --
    -- The COUNTDOWN while active is not drawn here at all: it is an
    -- engine-drawn overlay that covers this icon while the buff is up
    -- (Native:SyncActiveOverlays). This pass therefore keeps drawing the real
    -- cooldown underneath, unchanged and uninterrupted, which is exactly what
    -- should be showing the instant the overlay goes away.
    --
    -- What IS needed here is whether the ability is running, because the glow
    -- and the un-greying are ours. Blizzard's item frame answers that with
    -- cooldownUseAuraDisplayTime, a flag it assigns from plain literals, so it
    -- stays readable in combat when nothing else about the aura does.
    local activeNow = nil
    if not isBuffEntry and proxy._sqShowActiveBuff and proxy.selfAura ~= false then
        local item = cdmModule.viewerItems[proxy.cooldownID]
        if item then activeNow = AuraDisplayActive(item) or nil end
    end
    proxy._sqActiveNow = activeNow

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
    if isBuffEntry and proxy.Cooldown.SetCooldownFromDurationObject and C_UnitAuras
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
    if isBuffEntry and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
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
        -- LiveSpellID for the same reason as the cooldown below: charges live
        -- on the overridden spell when a talent replaces one.
        local spellCharges = C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(LiveSpellID(proxy.spellID))
        local maxCharges = spellCharges and BH.Secrets.SafeNumber(spellCharges.maxCharges, nil)
        local curCharges = spellCharges and BH.Secrets.SafeNumber(spellCharges.currentCharges, nil)
        if maxCharges and curCharges and maxCharges > 1 then
            proxy.Count:SetText(curCharges)
        else
            proxy.Count:SetText("")
        end
    end

    -- Through LiveSpellID: a talent-overridden spell keeps its cooldown on the
    -- replacement, and asking the base one returns nothing at all -- no sweep,
    -- no countdown text. See LiveSpellID for the Lay on Hands case.
    local liveID = LiveSpellID(proxy.spellID)
    local durationObj = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(liveID)
    if durationObj then
        proxy.Cooldown:SetCooldown(0, 0)
        proxy.Cooldown:SetCooldownFromDurationObject(durationObj)
    end
end

-- ============================================================================
-- Text placement, shared by the keybind, the charge count and the cooldown
-- countdown so all three offer the same nine positions and the same offsets.
-- ============================================================================

-- Moved to UI/Widgets.lua when the co-tank tracker wanted the same nine
-- positions. One list rather than two that can drift apart.
local TEXT_POSITION_ITEMS = ns.TEXT_POSITION_ITEMS

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
local PlaceText = ns.PlaceText

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

-- Icon shapes. The shape list, its art and the mask handling live in
-- UI/Shapes.lua (ns.Shapes), shared with the reminder buttons since 1.78; what
-- each image does for a proxy -- mask, swipe, border -- is described there.
local ICON_SHAPES = ns.Shapes.LIST
local SHAPE_FILE  = ns.Shapes.FILE
local SHAPE_GLOW  = ns.Shapes.GLOW
-- For GetBuffPlaceholder, which sits above this point in the file.
cdmModule.shapeFiles = SHAPE_FILE

-- What a square swipe goes back to after a shape. A white square tinted by the
-- swipe colour draws the same as the template's own swipe. Only ever set on a
-- proxy that has been shaped, so one that never was is left exactly as built.
local SQUARE_SWIPE = "Interface\\Buttons\\WHITE8X8"

local function ApplyIconShape(proxy, shape)
    -- Icon and background cut to the shape, or put back square. The mask
    -- handling is shared with the reminder buttons; see ns.Shapes.SetMask.
    ns.Shapes.SetMask(proxy, shape, proxy.Icon, proxy.Bg)
    local file = SHAPE_FILE[shape]

    if file then
        -- Below the background and the icon, so only the rim that sticks out
        -- past them shows. Sized, tinted and shown by ApplyProxyVisuals.
        if not proxy.ShapeBorder then
            proxy.ShapeBorder = proxy:CreateTexture(nil, "BACKGROUND", nil, -8)
        end
        proxy.ShapeBorder:SetTexture(file)
    elseif proxy.ShapeBorder then
        proxy.ShapeBorder:Hide()
    end

    local cd = proxy.Cooldown
    if cd and (file or proxy._sqShapedSwipe) then
        cd:SetSwipeTexture(file or SQUARE_SWIPE)
        -- The edge is the bright line riding the sweep, and it is drawn out to
        -- the frame's own square. Round has a circular edge for exactly this;
        -- every other shape would have the line poking out past its outline,
        -- so they go without.
        if cd.SetUseCircularEdge then cd:SetUseCircularEdge(shape == "round") end
        cd:SetDrawEdge(file == nil or shape == "round")
        if file then proxy._sqShapedSwipe = true end
    end

    -- Both glows follow the shape: Blizzard's alert still plays, with its art
    -- swapped for animated sheets in this shape (see ns.Glow, ApplyAlertArt).
    -- Square keeps Blizzard's art. A glow already running switches at once.
    local glowArt = SHAPE_GLOW[shape]
    ns.Glow.SetShape(proxy.ProcGlow, glowArt)
    ns.Glow.SetShape(proxy.GlowFrame, glowArt)
    ns.Glow.SetShape(proxy.ActiveGlow, glowArt)
end

-- The icon texture and cooldown of a frame we did NOT build.
--
-- Blizzard's own accessor first: CooldownViewerItemMixin:GetIconTexture returns
-- self.Icon, and the buff-bar mixin overrides it with its own. Some item types
-- wrap the texture in a frame, which is why EllesmereUI reaches through
-- frame.Icon.Icon -- same dance here. Returns nil rather than guessing if
-- nothing that accepts a mask turns up.
local function BorrowedIconRegions(child)
    if not child then return nil end
    local icon = child.Icon
    if not icon and child.GetIconTexture then
        local ok, tex = pcall(child.GetIconTexture, child)
        if ok then icon = tex end
    end
    if icon and not icon.AddMaskTexture and icon.Icon then icon = icon.Icon end
    if icon and not icon.AddMaskTexture then icon = nil end
    local cd = child.Cooldown or (child.GetCooldownFrame and child:GetCooldownFrame())
    return icon, cd
end

-- Cut a BORROWED frame to the group's icon shape -- Blizzard's own CDM item, or
-- one of our placeholders, whichever is standing in the slot.
--
-- ApplyIconShape above does this for a proxy, but reaches proxy.Icon / proxy.Bg
-- / proxy.ShapeBorder by name, which a Blizzard item does not have.
--
-- MASKING A FRAME WE DO NOT OWN IS SANCTIONED. AddMaskTexture and
-- RemoveMaskTexture are ordinary region writes, the same class as the font
-- string ApplyKeybindText already puts on these very children. EllesmereUI has
-- masked Blizzard's CDM items -- buff-viewer frames included -- all along
-- (EllesmereUICdmHooks.lua, _AC.SetMask + ApplyExtra, taking frame.Icon and
-- frame.Cooldown straight off the item). The belief that they could not be
-- masked is what left a single group drawing some icons round and some square,
-- decided only by whether an entry happened to get one of our cells -- which is
-- exactly what a user saw on a Death Knight's buff row (2026-09-20).
--
-- No ShapeBorder: that is a proxy-only texture, created at its own sublevel and
-- sized and tinted by ApplyProxyVisuals, with nothing on a Blizzard item to
-- hang it on. Mask and swipe only -- which is what decides the silhouette.
--
-- Passing nil for `shape` is the UNDO, and it is what puts a pooled frame back
-- square before Blizzard gets it again (see ReleaseAll). ns.Shapes.SetMask
-- removes before it adds, so re-applying can never stack two masks.
ApplyShapeToBorrowedChild = function(child, shape, zoom)
    local icon, cd = BorrowedIconRegions(child)
    if not icon then return end
    if shape == "none" then shape = nil end

    -- ICON ZOOM, which a borrowed frame never had.
    --
    -- The art on a spell icon is a square that runs edge to edge, corners and
    -- all, so a round mask cuts straight through the square border baked into
    -- the image. Cropping the outer fraction of the texture is what makes a
    -- shaped icon look deliberate rather than clipped -- the proxy path has
    -- always done it (ApplyProxyVisuals) and so has the placeholder path
    -- (GetBuffPlaceholder), but Blizzard's own frames were left at full coords.
    --
    -- That is also the whole reason the Icon Zoom slider looked broken on the
    -- buff groups (user report 2026-09-20): those groups draw borrowed frames,
    -- and the setting only ever reached proxies and placeholders. It was doing
    -- nothing because nothing was reading it here.
    --
    -- Reset to full coords on the unwind, not left cropped: Blizzard's
    -- RefreshSpellTexture sets the texture but never the coords, so a frame
    -- handed back would keep our crop until it happened to be rebuilt.
    if zoom == nil then zoom = DEFAULT_ICON_ZOOM end
    if shape or child._sqZoomed then
        local z = shape and zoom or 0
        pcall(icon.SetTexCoord, icon, z, 1 - z, z, 1 - z)
        child._sqZoomed = shape and true or nil
    end

    -- BLIZZARD ALREADY MASKS THIS ICON, AND MASKS INTERSECT.
    --
    -- Every CDM item template ships its own MaskTexture -- the rounded square
    -- UI-HUD-CoolDownManager-Mask, setAllPoints, permanently applied to Icon
    -- (CooldownViewer.xml, the <MaskedTextures> block on each item template).
    -- Adding ours does not replace it: the two COMBINE, and the icon comes out
    -- as the intersection -- mostly Blizzard's rounded square, with our circle
    -- biting only where it is tighter.
    --
    -- That is exactly what was seen (2026-09-20): icons still square while the
    -- swipe went round. The swipe looked right because it is not masked at all
    -- -- we substitute its texture outright, so it never meets Blizzard's mask.
    --
    -- So Blizzard's mask comes OFF while ours is on, and goes back when we let
    -- the frame go. They are anonymous XML regions with no parentKey, so they
    -- are found by walking the frame's regions once, then cached per frame.
    local blizz = child._sqBlizzMasks
    if not blizz then
        blizz = {}
        -- Blizzard's SQUARE ICON BORDER, which no mask can ever reach.
        --
        -- Each item template also carries an OVERLAY texture atlassed
        -- UI-HUD-CoolDownManager-IconOverlay, anchored deliberately OUTSIDE the
        -- frame (TOPLEFT -8,7 to BOTTOMRIGHT 8,-7 on the buff-icon template)
        -- and pointedly NOT listed in its <MaskedTextures> -- only Icon is. So
        -- it is not masked by Blizzard's own mask, and it cannot be masked by
        -- ours either: it draws a square outline sitting outside our circle,
        -- which is what was still visible once the icon itself went round
        -- (user report 2026-09-20).
        --
        -- Nothing for it but to hide the texture while a shape is on, and show
        -- it again on the unwind. It is anonymous -- no parentKey -- so it is
        -- found by atlas on the frame's own regions, once, and cached.
        local overlays = {}
        local ok, regions = pcall(function() return { child:GetRegions() } end)
        if ok and regions then
            for _, r in ipairs(regions) do
                local okT, t = pcall(r.GetObjectType, r)
                if okT and t == "MaskTexture" then
                    blizz[#blizz + 1] = r
                elseif okT and t == "Texture" then
                    local okA, atlas = pcall(r.GetAtlas, r)
                    if okA and type(atlas) == "string"
                       and atlas:find("IconOverlay", 1, true) then
                        overlays[#overlays + 1] = r
                    end
                end
            end
        end
        child._sqBlizzMasks = blizz
        child._sqBlizzOverlays = overlays
    end
    for _, o in ipairs(child._sqBlizzOverlays or {}) do
        pcall(o.SetShown, o, not shape)
    end
    for _, m in ipairs(blizz) do
        -- Remove first in BOTH directions: AddMaskTexture is additive, so a
        -- repeated unwind would otherwise stack Blizzard's own mask twice.
        pcall(icon.RemoveMaskTexture, icon, m)
        if not shape then pcall(icon.AddMaskTexture, icon, m) end
    end

    local file = ns.Shapes.SetMask(child, shape, icon)

    -- RE-POINT THE MASK EVERY PASS, AND TO THE FRAME RATHER THAN THE ICON.
    --
    -- ns.Shapes.SetMask anchors the mask once, at creation, to the first region
    -- it is handed (`if not m then ... m:SetAllPoints((...)) end`). That is fine
    -- for a proxy, whose Icon is SetAllPoints on the proxy itself, so the two
    -- rects can never diverge. It is wrong here: these are Blizzard's POOLED
    -- item frames, which it resizes and re-anchors as it reuses them, and which
    -- this layout also resizes to the group's iconSize. A mask left on the rect
    -- the icon happened to have when we first saw it then covers only part of
    -- the icon, and the shape gets cut off flat where the mask runs out -- seen
    -- as a straight left edge on an otherwise round icon (user report
    -- 2026-09-20: Bone Shield and Death and Decay, the two borrowed frames in
    -- a row whose other icons are our own cells and were correctly round).
    --
    -- The frame is the stable rect: we have just set its size, and the shape is
    -- meant to describe the SLOT, not whatever sub-rect the art occupies inside
    -- it. EllesmereUI anchors to a button-sized host for the same reason, and
    -- re-points on every apply rather than only at creation.
    local mask = child._sqMask
    if mask and file then
        mask:ClearAllPoints()
        mask:SetAllPoints(child)
    end

    -- Only ever touched on a frame we have actually shaped, so one that never
    -- was keeps whatever swipe Blizzard gave it.
    if cd and (file or child._sqShapedSwipe) then
        pcall(cd.SetSwipeTexture, cd, file or SQUARE_SWIPE)
        if cd.SetUseCircularEdge then
            pcall(cd.SetUseCircularEdge, cd, shape == "round")
        end
        if cd.SetDrawEdge then
            pcall(cd.SetDrawEdge, cd, file == nil or shape == "round")
        end
        child._sqShapedSwipe = file and true or nil
    end

    shapedBorrowed[child] = file and true or nil
end

-- Put every borrowed frame back square. Called when this module lets go of
-- them; without it the shape rides along to Blizzard's own bar.
local function UnshapeAllBorrowed()
    for child in pairs(shapedBorrowed) do
        ApplyShapeToBorrowedChild(child, nil)
    end
    wipe(shapedBorrowed)
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
    if not proxy._iconSet and proxy.Icon and (proxy.spellID or proxy.equipSlot) then
        local tex = ResolveProxyTexture(proxy.spellID, proxy.equipSlot)
        if tex then
            proxy.Icon:SetTexture(tex)
            proxy._iconSet = true
        end
    end

    -- Blizzard parity: proc glow and the usable/range tint, both per group.
    --
    -- Cached on the proxy as well as applied, because the glow events arrive
    -- outside any layout pass and the handler has no group in hand -- resolving
    -- one there would mean repeating the assignment fallback for every icon on
    -- every proc.
    -- Cooldown-type entries only. Both of these live on
    -- CooldownViewerCooldownItemMixin, which is Essential and Utility;
    -- Blizzard's buff items inherit neither, so applying them to a tracked buff
    -- would not be parity but invention -- and a buff has no meaningful "can
    -- you cast this right now" to colour by in the first place.
    local isCooldownType = (proxy.viewerType ~= "buff")

    local procGlowOn = isCooldownType and (groupData.procGlow ~= false)
    proxy._procGlowAllowed = procGlowOn
    ResizeSpellAlert(proxy)
    SyncProcGlow(proxy, procGlowOn)

    proxy._usableTintAllowed = isCooldownType and (groupData.usableTint ~= false)
    ApplyUsableTint(proxy, proxy._usableTintAllowed)

    -- Cached here for the same reason as the two above: the duration pass runs
    -- per icon with no group in hand. Cooldown-type only -- a tracked buff
    -- already draws its aura's duration, so there is nothing for this to add.
    proxy._sqShowActiveBuff = isCooldownType and groupData.showActiveBuff or nil
    if not proxy._sqShowActiveBuff and proxy.ActiveGlow then
        ns.Glow.Set(proxy.ActiveGlow, false)
        proxy._sqActiveNow = nil
    end

    -- Its own colour, so it does not read as the proc glow. sqGlowColor is the
    -- per-frame override Glow.lua already honours (the nameplate purge glow
    -- uses the same door), so nothing else in the addon follows this.
    if proxy.ActiveGlow then
        local c = ActiveGlowColor(groupData)
        local prev = proxy.ActiveGlow.sqGlowColor
        local changed = not prev or prev[1] ~= c[1] or prev[2] ~= c[2] or prev[3] ~= c[3]
        proxy.ActiveGlow.sqGlowColor = c
        -- A glow is tinted when it STARTS, and this one is held for a whole
        -- buff, so without a restart a colour change would not show up until
        -- the next time the ability was used. The state sync further down
        -- brings it straight back on the same pass when it should be lit.
        if changed then ns.Glow.Set(proxy.ActiveGlow, false) end
    end

    -- Alpha
    local alpha = groupData.alpha or DEFAULT_ALPHA
    proxy:SetAlpha(alpha)

    -- Border visibility. A shaped icon draws its border as ShapeBorder (see
    -- ApplyIconShape), so the square one gives way to it; ShapeBorder itself
    -- is shown after the style block below, which is what creates it.
    local showBorder = groupData.showBorder ~= false
    local shape      = groupData.iconShape or "none"
    local shaped     = SHAPE_FILE[shape] ~= nil
    if proxy.Border then proxy.Border:SetShown(showBorder and not shaped) end

    ApplyKeybindText(proxy, proxy.spellID, groupData)

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

    -- Appended after format, not built into the format string: a value
    -- containing a % would otherwise be read as a directive.
    local sig = ("%d|%.3f|%.2f,%.2f,%.2f,%.2f|%s|%.2f,%.2f,%.2f,%.2f|%s"):format(
        thickness, zoom, bc[1], bc[2], bc[3], bc[4],
        tostring(classCol), bg[1], bg[2], bg[3], bg[4], tostring(bgOn))
        .. "|" .. shape

    if proxy._styleSig ~= sig then
        proxy._styleSig = sig

        -- Shape before the SetTexCoord below, and both inside this block.
        --
        -- Removing a mask registers but does not repaint on its own: the icon
        -- kept rendering round until something else touched the texture. That
        -- is why switching back to square appeared to change only one icon
        -- until an unrelated slider (border opacity) was nudged -- that changed
        -- the signature, which re-ran SetTexCoord, which forced the repaint.
        -- Running the mask change here means the SetTexCoord immediately after
        -- is the repaint.
        ApplyIconShape(proxy, shape)

        if proxy.Icon then
            proxy.Icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
        end

        local r, g, b, a = bc[1], bc[2], bc[3], bc[4]
        if classCol then
            local _, class = UnitClass("player")
            local cc = class and C_ClassColor and C_ClassColor.GetClassColor
                and C_ClassColor.GetClassColor(class)
            if cc then r, g, b = cc.r, cc.g, cc.b end
        end

        if proxy.Border then
            proxy.Border:ClearAllPoints()
            proxy.Border:SetPoint("TOPLEFT", -thickness, thickness)
            proxy.Border:SetPoint("BOTTOMRIGHT", thickness, -thickness)
            proxy.Border:SetBackdrop({
                edgeFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeSize = thickness,
            })
            proxy.Border:SetBackdropBorderColor(r, g, b, a)
        end

        -- The shaped border: the shape itself, grown by the thickness on
        -- every side and tinted, sitting behind the icon.
        if proxy.ShapeBorder then
            proxy.ShapeBorder:ClearAllPoints()
            proxy.ShapeBorder:SetPoint("TOPLEFT", -thickness, thickness)
            proxy.ShapeBorder:SetPoint("BOTTOMRIGHT", thickness, -thickness)
            proxy.ShapeBorder:SetVertexColor(r, g, b, a)
        end

        if proxy.Bg then
            proxy.Bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
            proxy.Bg:SetShown(bgOn)
        end
    end

    if proxy.ShapeBorder then proxy.ShapeBorder:SetShown(showBorder and shaped) end

    -- Cooldown text visibility
    if proxy.Cooldown then
        proxy.Cooldown:SetHideCountdownNumbers(not (groupData.showCooldownText ~= false))
    end

    -- Desaturation: greyscale icon when spell is NOT on cooldown
    if proxy.Icon and proxy.spellID then
        local onCD = false
        -- LiveSpellID: this is the read that decides "grey it out", and on a
        -- talent-overridden spell the base ID reports permanently ready.
        local cdInfo = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(LiveSpellID(proxy.spellID))
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

        -- Two opposite options, and only one can win.
        --
        -- "On cooldown" is Blizzard's own behaviour and what most people mean by
        -- greying an icon out; "when ready" is the inverse, for a group used as
        -- a "these are up" display. They contradict each other, so the settings
        -- UI unticks one when the other is ticked -- but a profile written
        -- before that, or edited by hand, can still hold both. On cooldown wins
        -- there, because it is the one that matches the rest of the UI.
        --
        -- onCD rather than isActive: isActive folds in whether the buff is up,
        -- which for a tracked buff means the icon would grey out exactly when
        -- the buff was active. The question here is only "is the spell on
        -- cooldown".
        --
        -- Running beats on-cooldown. A big cooldown starts its own timer the
        -- moment it is cast, so without this exception the icon greys out at
        -- exactly the moment the ability is doing its work -- which is the
        -- opposite of what the setting is for.
        -- NOT folded in with hasAura, which was the second half of "it doesn't
        -- work in combat": CooldownAuraActive answers from the BUFF viewers,
        -- so for an Essential entry with no tracked-buff twin it reads false
        -- all fight and took the glow and the colour down with it.
        -- _sqActiveNow comes from Blizzard's own never-secret display flag.
        local runningNow = proxy._sqShowActiveBuff and proxy._sqActiveNow and true or false
        if groupData.desaturateOnCooldown then
            proxy.Icon:SetDesaturated(onCD and not runningNow and true or false)
        elseif groupData.desaturateReady then
            proxy.Icon:SetDesaturated(not isActive)
        else
            proxy.Icon:SetDesaturated(false)
        end

        -- Hide until active: only show when on cooldown or buff is active.
        -- Everything shows in unlock mode, so the group is positioned at its
        -- full extent rather than at whatever happens to be on cooldown.
        if groupData.hideUntilActive then
            proxy:SetShown(isActive or cdmModule.previewMode)
        end

        -- Detect state transitions this frame
        local justBecameReady  = not isActive and proxy._wasOnCD
        local justBecameActive = hasAura and not proxy._wasHasAura
        local justStartedCD    = isActive and not proxy._wasOnCD

        -- Held for as long as the ability is running, so this is a state sync
        -- rather than a transition -- Glow.Set is idempotent, and Show
        -- early-returns on an already-glowing frame, so this costs nothing on
        -- the passes where nothing changed.
        --
        -- The third argument is the anchor, and passing it is what forces the
        -- self-drawn halo instead of Blizzard's proc art (ns.Glow.Show). That
        -- is the whole point of a separate glow: "running" must not look like
        -- "procced".
        if proxy.ActiveGlow then
            ns.Glow.Set(proxy.ActiveGlow, runningNow and true or false,
                        proxy.ActiveGlow, true)
        end

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
                local cdInfo = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(LiveSpellID(tracker.spellID))
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

    -- When the set was last seen to change, and when it was last rebuilt.
    --
    -- "the icons are stale" has two very different causes -- the change was
    -- never noticed (signature unchanged), or it was noticed and the rebuild
    -- did not happen or ran too early. A timestamp on each separates them,
    -- which guessing between them repeatedly did not.
    do
        local now = GetTime()
        local function ago(t)
            if not t then return "never" end
            return string.format("%.1fs ago", now - t)
        end
        print(string.format("  cooldown set last changed: %s | last reconcile: %s | spec key: %s",
            ago(cdmModule.lastSetChangeAt), ago(cdmModule.lastReconcileAt),
            tostring(GetSpecKey())))
    end

    -- Whether Blizzard's own filtering is being honoured, per viewer.
    --
    -- "our groups list more than Blizzard's bars" has two completely different
    -- causes -- the filter not being read at all, or being read correctly by a
    -- player who has hidden nothing -- and they look identical on screen. This
    -- is the only thing that separates them, so it is the first question on any
    -- report that a group is showing too much.
    --
    -- honoured=false is expected for a few seconds after login (the viewer pool
    -- is lazy) and a bug if it persists.
    -- Where each group thinks it is, versus where it actually is.
    --
    -- "I moved it and it went back" has at least three separate causes that look
    -- identical on screen: the drag never saved, the drag saved but something
    -- re-positioned the container, or the container is exactly where it should
    -- be and the ICONS are drawing somewhere else (which is possible for a
    -- borrowed group, because those are Blizzard's frames and only their anchors
    -- are ours). saved vs actual separates the first two; holds= separates the
    -- third, since a borrowed group with 0 frames is not re-anchoring anything.
    do
        print("  group positions (saved -> actual, borrowed groups show frame count):")
        -- Fetched here rather than assumed in scope: `specData` is a local in
        -- the reconcile paths, not in this one, and a bare read would be nil
        -- with no error -- reporting "saved=?,?" for every group and hiding the
        -- exact thing this is here to show.
        local posSpecData = GetSpecData()
        for groupName, group in pairs(cdmModule.groups) do
            local gd = posSpecData and posSpecData.groups[groupName]
            local sx, sy = "?", "?"
            if gd and gd.position then
                sx = string.format("%.0f", gd.position.x or 0)
                sy = string.format("%.0f", gd.position.y or 0)
            end
            local ax, ay = "?", "?"
            local shown = "hidden"
            if group.container then
                local cx, cy = group.container:GetCenter()
                local px, py = UIParent:GetCenter()
                if cx and px then
                    ax = string.format("%.0f", cx - px)
                    ay = string.format("%.0f", cy - py)
                end
                shown = group.container:IsShown() and "shown" or "hidden"
            end
            local kind = group.usesBlizzardIcons and "borrowed" or "proxy"
            local held = 0
            if group.usesBlizzardIcons then
                for _, viewerName in ipairs(BORROW_VIEWERS[groupName] or BUFF_VIEWERS) do
                    local viewer = _G[viewerName]
                    if viewer then
                        local ok, children = pcall(function() return { viewer:GetChildren() } end)
                        if ok and children then
                            for _, child in ipairs(children) do
                                if child and child.cooldownID and child:IsShown() then
                                    held = held + 1
                                end
                            end
                        end
                    end
                end
            else
                for _ in pairs(group.members or {}) do held = held + 1 end
            end
            print(string.format("      %-14s saved=%5s,%-6s actual=%5s,%-6s %-8s %-6s holds=%d%s",
                groupName, sx, sy, ax, ay, kind, shown, held,
                (gd and gd.isBarGroup) and " [bars]" or ""))
            if gd and gd.anchorTo and gd.anchorTo ~= "" then
                print(string.format("        anchored to %s (%s) -- its own saved position is ignored",
                    tostring(gd.anchorTo), tostring(gd.anchorPoint)))
            end
        end
    end

    do
        print("  Blizzard CDM filter (false = falling back to the raw category set):")
        for _, viewerInfo in ipairs(DISCOVER_CATEGORIES) do
            local used = cdmModule.usedBlizzardFilter[viewerInfo.viewer]
            local filtered = BlizzardFilteredIDs(viewerInfo.viewer)
            local raw = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
                and C_CooldownViewer.GetCooldownViewerCategorySet(viewerInfo.category)
            print(string.format("      %-24s honoured=%-5s shows %s of %s",
                viewerInfo.viewer, tostring(used and true or false),
                filtered and tostring(#filtered) or "?",
                raw and tostring(#raw) or "?"))
        end
    end

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

local function GetOrCreateProxy(cooldownID, spellID, iconSize, equipSlot)
    local proxy = cdmModule.proxyFrames[cooldownID]
    if proxy then
        proxy:SetSize(iconSize, iconSize)
        proxy.Icon:SetAllPoints()
        proxy.Cooldown:SetAllPoints()
        ResizeSpellAlert(proxy)
        proxy:Show()
        return proxy
    end
    proxy = CreateProxyIcon(cooldownID, spellID, iconSize, equipSlot)
    cdmModule.proxyFrames[cooldownID] = proxy
    UpdateProxyCooldown(proxy)
    return proxy
end

local function DestroyProxy(cooldownID)
    local proxy = cdmModule.proxyFrames[cooldownID]
    if proxy then
        -- Stop the glows before letting go of the frame.
        --
        -- ActionButtonSpellAlertManager holds the glowing frame in its own
        -- activeAlerts table, keyed by frame. Dropping our last reference does
        -- not remove it from there -- WoW cannot destroy a frame, so the entry
        -- and its pooled alert art would simply leak, and a cooldownID recycled
        -- onto a fresh proxy later would leave the old one glowing invisibly
        -- forever.
        SetProcGlow(proxy, false)
        if proxy._glowShowing then
            ns.Glow.Hide(proxy.GlowFrame or proxy)
            proxy._glowShowing = false
        end
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
    -- Unlock mode overrides every situational condition below. It is used out
    -- of combat, in town, with no target -- exactly when a group set to combat
    -- or instances only is hidden -- so without this the player was dragging a
    -- box they could not see, with no idea how its icons would sit. Enable
    -- Group is the one condition kept: that is "I do not want this at all".
    if cdmModule.previewMode then return 1 end
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
        -- Measure the centre offset; do NOT read it off GetPoint().
        --
        -- PositionGroup restores a group with
        -- SetPoint("CENTER", UIParent, "CENTER", x, y), so the saved pair has to
        -- mean "offset of my centre from UIParent's centre" and nothing else.
        -- GetPoint() returns offsets relative to whatever anchor the frame
        -- happens to hold, and StartMoving/StopMovingOrSizing -- with
        -- SetClampedToScreen in play -- can leave that as something other than
        -- CENTER/CENTER. Those numbers were then written straight to the profile
        -- and re-applied as if they were centre offsets, so the group jumped on
        -- the next reconcile.
        --
        -- Measured on a live client: a bar group dropped at centre offset +468
        -- saved as -393, a difference of 861 -- exactly half that player's
        -- UIParent width, which is the fingerprint of an edge anchor being read
        -- as a centre one. It looked like "the drag does not save", and the drag
        -- was saving perfectly; it was saving a number that meant something
        -- else. /sq cdm prints saved and actual side by side for this reason.
        --
        -- GetCenter() is anchor-independent, so this cannot drift again.
        local specData = GetSpecData()
        if specData and specData.groups[groupName] then
            local cx, cy = self:GetCenter()
            local px, py = UIParent:GetCenter()
            if cx and cy and px and py then
                specData.groups[groupName].position = { x = cx - px, y = cy - py }
            end
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
            -- LiveSpellID on both sides, so sort-by-cooldown orders by the
            -- cooldown actually running rather than the base spell's.
            local cdA = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(LiveSpellID(a.proxy.spellID))
            local cdB = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(LiveSpellID(b.proxy.spellID))
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
        -- "assignment" = Blizzard's own order, falling back to cooldownID.
        --
        -- Discovery records the index each cooldown had in the list Blizzard
        -- handed over, which is the order the player arranged in the Cooldown
        -- Manager options. Using it means a group that mirrors one of Blizzard's
        -- bars lays out the same way round, rather than in cooldownID order --
        -- an internal number that has nothing to do with anything the player
        -- can see. cooldownID still breaks ties and still orders anything with
        -- no recorded index, so the sort stays total and stable.
        table.sort(members, function(a, b)
            local ea = cdmModule.registry[a.cdID]
            local eb = cdmModule.registry[b.cdID]
            local oa = ea and ea.order
            local ob = eb and eb.order
            if oa and ob and oa ~= ob then return oa < ob end
            if oa and not ob then return true end
            if ob and not oa then return false end
            return a.cdID < b.cdID
        end)
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
    -- least one empty one. Hide the container instead -- except in unlock mode,
    -- where ShowPreview has just shown it and a relayout must not undo that.
    local isEmpty = (#members == 0)
    group.container:SetShown(not isEmpty or self.previewMode)

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
    self.lastReconcileAt = GetTime()

    -- SetPassThroughButtons (and other protected calls) are banned in combat.
    --
    -- One timer a second, not one per frame. This used to reschedule with a 0
    -- delay, which fires on the very next frame, bails again, and reschedules --
    -- a timer allocated every frame for the entire fight, achieving nothing,
    -- because nothing here can succeed until lockdown ends.
    --
    -- PLAYER_REGEN_ENABLED already schedules a reconcile, so that is the real
    -- path back; this is only a backstop for the case where combat ends without
    -- that event being useful. Reloading mid-combat lands here, which is why the
    -- Cooldown Manager stays absent until the fight ends -- expected, not a bug,
    -- and the first thing to rule out on any "nothing is showing" report.
    if InCombatLockdown() then
        self:ScheduleReconcile(1.0)
        return
    end

    local specData = GetSpecData()
    if not specData then
        -- Retry rather than give up. This is nil only while the profile system
        -- is not up yet, which is a transient early-login state -- but a plain
        -- `return` here meant the module sat dead until something unrelated
        -- happened to schedule another reconcile, which on a quiet login is
        -- never. Nothing on screen and no drag handles is the result.
        self:ScheduleReconcile(0.5)
        return
    end

    if not BH.settings or not BH.settings.cdmEnabled then
        self:ReleaseAll()
        return
    end

    local discovered, buffExtras = DiscoverCooldowns()

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

    -- WHICH GROUPS BORROW BLIZZARD'S FRAMES, decided before discovery is
    -- consulted at all.
    --
    -- This flag used to be set only when an ENTRY of ours landed in a group
    -- (in the loop below, and again for buffExtras), and was never cleared.
    -- Two faults followed, and the second is the one that gets reported:
    --
    --   * STICKY. Once a group had ever held a buff it borrowed forever, so a
    --     custom group kept borrowing after its buffs were moved out of it.
    --   * A built-in buff group whose entries discovery did not hand over --
    --     because they were dropped as same-name duplicates of a cooldown --
    --     never had the flag set at all, so LayoutBorrowedBuffIcons was never
    --     called for it and Blizzard's viewer children were INVISIBLE. Not
    --     mis-styled: absent, while Blizzard was plainly showing them.
    --
    --     Bone Shield on a Death Knight is exactly that (user report
    --     2026-09-20): it is a tracked buff AND a cooldown, so the buff copy
    --     is deduped away (see the "One ability, two categories" note in
    --     DiscoverCooldowns), and the Buffs group then never looked at
    --     Blizzard's viewer. It survived as a BAR only because some other
    --     entry happened to flag that group.
    --
    -- The built-in buff groups ARE "whatever Blizzard is showing" -- that is
    -- their entire definition -- so they borrow whenever borrowing is on,
    -- regardless of what our own discovery found. The registry still decides
    -- whether a buff gets one of our styled cells; it no longer decides
    -- whether the buff is VISIBLE. Those are different questions and conflating
    -- them is what made a display bug out of a bookkeeping one.
    --
    -- Note this covers native mode too: "borrowing" here means the layout walks
    -- Blizzard's viewer children, substituting one of our cells per child where
    -- there is one. Only cdmProxyBuffIcons (proxy buff icons) opts out, and
    -- those entries take the ordinary proxy path below.
    --
    -- Cleared first, so the flag is re-derived every pass instead of latching.
    for _, group in pairs(self.groups) do
        group.usesBlizzardIcons = false
    end
    if BorrowBuffIcons() then
        for _, vt in ipairs({ "buff", "buffbar" }) do
            local builtinName = BUILTIN_FOR_VIEWERTYPE[vt]
            local builtinGroup = builtinName and self.groups[builtinName]
            if builtinGroup then builtinGroup.usesBlizzardIcons = true end
        end
    end

    -- Buff entries each group will draw natively, handed to the native module
    -- once the loop is done (Squizzumables_CDMAuras.lua).
    local nativeByGroup = {}
    -- [cooldownID] = { proxy, groupData, entry } -- the Essential/Utility icons
    -- that want an engine-drawn active overlay. Collected here and handed over
    -- whole, so an icon that stops wanting one is released by its absence.
    local activeWanted = {}

    -- Process each discovered cooldown (pure API data, no frame references)
    for cdID, cdData in pairs(discovered) do
        local existing = self.registry[cdID]
        if existing then
            existing.spellID = cdData.spellID
            existing.equipSlot = cdData.equipSlot
            existing.viewerType = cdData.viewerType
            existing.auraIDs = cdData.auraIDs
            existing.hasAura = cdData.hasAura
            existing.selfAura = cdData.selfAura
            existing.tooltipSpellID = cdData.tooltipSpellID
            existing.order = cdData.order
        else
            self.registry[cdID] = {
                spellID = cdData.spellID,
                equipSlot = cdData.equipSlot,
                cooldownID = cdID,
                viewerType = cdData.viewerType,
                auraIDs = cdData.auraIDs,
                hasAura = cdData.hasAura,
                selfAura = cdData.selfAura,
                tooltipSpellID = cdData.tooltipSpellID,
                order = cdData.order,
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
        if assignment and (entry.viewerType == "buff" or entry.viewerType == "buffbar")
           and BorrowBuffIcons() then
            entry.managed = true
            local group = self.groups[assignment]
            if group then
                -- The buff layout path either way: a natively drawn buff still
                -- takes its slot, and its active state, through the same pass.
                group.usesBlizzardIcons = true
                if self.native and self.native:Handles(entry) then
                    nativeByGroup[assignment] = nativeByGroup[assignment] or {}
                    table.insert(nativeByGroup[assignment], entry)
                end
            end
        -- equipSlot as well as spellID: an equip-slot entry (a trinket) carries
        -- no spellID at all, and reaches a group only because the player
        -- dragged it into Essential or Utility in Blizzard's own settings.
        -- Requiring a spellID here dropped it on the floor, so honouring the
        -- filter would have shown the player one fewer icon than Blizzard does.
        elseif assignment and (entry.spellID or entry.equipSlot) then
            entry.managed = true

            if assignment == "FREE" then
                local proxy = GetOrCreateProxy(cdID, entry.spellID, DEFAULT_ICON_SIZE, entry.equipSlot)
                proxy.auraSpellIDs = entry.auraIDs
                proxy.viewerType = entry.viewerType
                proxy.selfAura = entry.selfAura
                self.freeIcons[cdID] = proxy
                self:PositionFreeIcon(cdID)
            else
                -- Assign to group
                local group = self.groups[assignment]
                if group then
                    local groupData = specData.groups[assignment]
                    local iconSize = groupData and groupData.iconSize or DEFAULT_ICON_SIZE
                    local proxy = GetOrCreateProxy(cdID, entry.spellID, iconSize, entry.equipSlot)
                    proxy.auraSpellIDs = entry.auraIDs
                    proxy.viewerType = entry.viewerType
                    -- Which unit the aura lands on. THE discriminator for
                    -- "Show While Active" -- see UpdateProxyCooldown.
                    proxy.selfAura = entry.selfAura
                    group.members[cdID] = proxy

                    -- "Show While Active": ask for the engine-drawn overlay
                    -- that draws this ability's own buff while it is running.
                    --
                    -- selfAura is checked here as well as at display time, so
                    -- an ability whose buff lands on the TARGET (Lay on Hands
                    -- with Empyreal Ward) never has a slot built for it at
                    -- all, rather than building one that must not be shown.
                    if groupData and groupData.showActiveBuff
                       and entry.viewerType ~= "buff" and entry.viewerType ~= "buffbar"
                       and entry.selfAura ~= false then
                        activeWanted[cdID] = {
                            proxy = proxy, groupData = groupData, entry = entry,
                        }
                    end
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

    -- The buffs discovery kept out of the registry as duplicates of a cooldown.
    -- The borrowed layout has always shown them anyway (it walks every item on
    -- Blizzard's buff bar); natively drawn groups need a slot for each too, or
    -- they stay Blizzard frames among ours -- the stacking buffs in the 1.76
    -- test were exactly these. Always their built-in group, since they are not
    -- offered for custom assignment.
    if self.native then
        for _, extra in pairs(buffExtras or {}) do
            local builtinName = BUILTIN_FOR_VIEWERTYPE[extra.viewerType]
            local builtinGroup = builtinName and self.groups[builtinName]
            if builtinGroup and self.native:Handles(extra) then
                builtinGroup.usesBlizzardIcons = true
                nativeByGroup[builtinName] = nativeByGroup[builtinName] or {}
                table.insert(nativeByGroup[builtinName], extra)
            end
        end
    end

    -- Build or restyle the native buff slots before anything is laid out, so
    -- the layout below finds their cells. Every group is passed through, even
    -- those with nothing native, so one that lost its buffs is released.
    if self.native then self.native:SyncAll(nativeByGroup) end

    -- The active overlays, from the same pass and released the same way: every
    -- icon that still wants one is passed every time, so one whose option was
    -- switched off -- or whose proxy has been rebuilt underneath it -- is torn
    -- down by its absence rather than needing to be noticed.
    if self.native then self.native:SyncActiveOverlays(activeWanted) end

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
                -- Idempotent per frame, so running it at poll rate is cheap.
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

    -- Handle spells that disappeared (talent/spec change removed a spell).
    --
    -- Every group is swept, not just the one named by an explicit assignment.
    -- Reading `specData.assignments` alone stopped being enough the moment the
    -- built-in groups arrived in 1.69: a cooldown with no explicit assignment
    -- falls back to the group for its viewer type, so for most spells the
    -- lookup returned nil and the removal below was skipped entirely.
    --
    -- The proxy was destroyed but its entry stayed in `group.members`, and that
    -- is worse than it sounds, because LayoutGroup does `proxy:SetParent(...)`
    -- on every member it finds. So the next layout pass re-parented and
    -- re-showed the frame that had just been destroyed: the icon vanished on
    -- the talent change and came back a second later. The member count never
    -- changed either, which is why the group did not resize around the gap.
    --
    -- This is the same failure CLAUDE.md already records for
    -- UpdateAllProxyCooldowns. Sweeping every group needs no assignment lookup
    -- at all and cannot drift out of step with the fallback rules again.
    local touchedGroups = {}
    for cdID, entry in pairs(self.registry) do
        if not discovered[cdID] and entry.managed then
            for groupName, group in pairs(self.groups) do
                if group.members and group.members[cdID] then
                    group.members[cdID] = nil
                    touchedGroups[groupName] = true
                end
            end
            self.freeIcons[cdID] = nil
            DestroyProxy(cdID)
            entry.managed = false
        end
    end

    -- Re-lay out whatever just lost an icon. This pass runs after the layout
    -- above, so without it the container keeps the size it was given while the
    -- removed icon was still counted -- a hole in the row until something else
    -- happened to trigger a rebuild.
    for groupName in pairs(touchedGroups) do
        self:LayoutGroup(groupName)
    end
end

-- Schedule a reconcile, never EARLIER than one already pending.
--
-- The delays here are not interchangeable waits, they are statements about how
-- long the game needs before the answer is trustworthy. A spec change asks for
-- 1.0s because the category sets still report the outgoing spec for a moment
-- after the event; a settings edit asks for 0.15s because the data is already
-- correct. The old version cancelled and replaced unconditionally, so a short
-- request landing after a long one won.
--
-- That is exactly what a spec change does. PLAYER_SPECIALIZATION_CHANGED is
-- handled twice -- here, which schedules 1.0s, and in Squizzumables.lua's spec
-- handler, which since 1.70 calls OnProfileChanged and asked for 0.15s. Whichever
-- ran second decided, and when that was the 0.15s one the reconcile fired while
-- the client still reported the old spec, then never ran again because nothing
-- reschedules. The result was the previous spec's cooldowns sitting there until
-- a reload.
--
-- Taking the longer of the two makes the order the events arrive in stop
-- mattering. It stays a debounce -- repeated calls still push the fire time out
-- rather than stacking timers -- it just cannot be pulled forward.
-- `force` overrides that and is for one thing only: the "Refresh Cooldowns"
-- button, where the player has explicitly asked for it now and having the
-- request quietly dropped because some automatic pass was pending would read as
-- the button not working. Do not reach for it on an event path -- that is how
-- the spec-change race gets reintroduced.
local reconcileDueAt = nil
function cdmModule:ScheduleReconcile(delay, force)
    delay = delay or RECONCILE_DEBOUNCE
    local due = GetTime() + delay

    if not force and reconcileTimer and reconcileDueAt and reconcileDueAt > due then
        return
    end

    if reconcileTimer then reconcileTimer:Cancel() end
    reconcileDueAt = due
    reconcileTimer = C_Timer.NewTimer(delay, function()
        reconcileTimer, reconcileDueAt = nil, nil
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
-- The group names are "Essential", "Utility", "Buffs" and "Buff Bars" for the
-- built-ins, or whatever the player called a custom group. Note the space in
-- "Buff Bars": these names are passed through verbatim, and a custom group has
-- always been able to contain one, so nothing here assumes otherwise.
-- The frames are also reachable as
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
-- made inert by clearing BS(f).dimmed; BS(f).applying breaks the recursion from our
-- own SetAlpha call inside the hook.
local function HoldAlphaZero(f)
    if BS(f).alphaHooked then return end
    BS(f).alphaHooked = true
    hooksecurefunc(f, "SetAlpha", function(self, a)
        if BS(self).dimmed and a ~= 0 and not BS(self).applying then
            BS(self).applying = true
            self:SetAlpha(0)
            BS(self).applying = nil
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
    BuffBarCooldownViewer   = "Buff Bars",
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
    if BS(f).origPoints then return end
    local pts = {}
    for i = 1, f:GetNumPoints() do pts[i] = { f:GetPoint(i) } end
    BS(f).origPoints = pts
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
    BS(f).parkGuard = true
    f:ClearAllPoints()
    if groupFrame then
        -- Match position and size, so the viewer's rect is the group's rect and
        -- an addon anchored to either gets the same answer.
        f:SetPoint("TOPLEFT", groupFrame, "TOPLEFT", 0, 0)
        f:SetPoint("BOTTOMRIGHT", groupFrame, "BOTTOMRIGHT", 0, 0)
    else
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", PARK_X, PARK_Y)
    end
    BS(f).parkGuard = nil
end

local function RestoreFramePoints(f)
    if not BS(f).origPoints or InCombatLockdown() then return end
    BS(f).restoring = true
    f:ClearAllPoints()
    for _, p in ipairs(BS(f).origPoints) do
        f:SetPoint(p[1], p[2], p[3], p[4], p[5])
    end
    BS(f).origPoints = nil
    BS(f).restoring = nil
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
    if BS(f).pointHooked then return end
    BS(f).pointHooked = true
    local function QueueRepark(self)
        if not BS(self).dimmed or BS(self).parkGuard or BS(self).restoring
           or BS(self).parkQueued then return end
        BS(self).parkQueued = true
        C_Timer.After(0, function()
            BS(self).parkQueued = nil
            -- Re-park to the same place it was, following or offscreen.
            if BS(self).dimmed then ParkFrame(self, BS(self).followFrame) end
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
                        elseif BS(cdw).mirrorHooked then mirrorTxt = "|cFF33FF33hooked|r"
                        else mirrorTxt = "|cFFFF5555NOT hooked|r" end
                        local proxyTxt = cdmModule.proxyFrames[cdID] and "yes" or "|cFFFF5555none|r"

                        -- Is there a StatusBar of Blizzard's to MIRROR?
                        --
                        -- A tracked bar that is up because of a totem has no aura
                        -- for a slot of ours to bind to, so it cannot be drawn
                        -- natively -- but Blizzard's own bar already holds the
                        -- right fill whatever drives it. Mirroring that bar's
                        -- min/max/value is how EllesmereUI draws every tracked
                        -- bar, and it is why theirs handles Consecration without
                        -- ever reading the totem API. `Bar` is a plain field on
                        -- the item frame there; this reports whether it is one
                        -- here too, which is the whole premise.
                        local barTxt
                        local blzBar = child.Bar
                        if blzBar == nil then barTxt = "|cFFFF5555nil|r"
                        elseif BH.Secrets.IsSecret(blzBar) then barTxt = "|cFFFFD100SECRET|r"
                        else
                            local okType, objType = pcall(blzBar.GetObjectType, blzBar)
                            barTxt = okType and ("|cFF33FF33" .. tostring(objType) .. "|r")
                                or "|cFFFF5555threw|r"
                        end

                        print(("    %s (cd %s, spell %s) IsActive=%s auraInstanceID=%s unit=%s dur=%s tracked=%s mirror=%s proxy=%s Bar=%s"):format(
                            name, tostring(cdID), tostring(sid), activeTxt, iidTxt,
                            tostring(child.auraDataUnit),
                            durTxt,
                            tostring(sid and cdmModule.buffItemForSpell[sid] ~= nil),
                            mirrorTxt, proxyTxt, barTxt))
                    end
                end
            end
        end
    end
    if n == 0 then
        print("|cFFFF5555  no buff viewer children at all -- the viewers have not built their item frames.|r")
    end
end

-- /sq cdmtaint -- has this addon tainted Blizzard's Cooldown Manager?
--
-- Keep this. It is the only thing that has ever answered the question, and it
-- answered it in one run after three rounds of reasoning from documentation got
-- it wrong (see the long note above DiscoverCooldowns). Taint is a runtime
-- property; it appears in no API documentation, and `HasRestrictions` describes
-- a different mechanism entirely. Measure, do not infer.
--
-- `issecurevariable(table, key)` returns `isSecure, taintingAddon`. A field
-- reported insecure and blamed on us means our execution wrote it -- or wrote
-- something Blizzard derived it from -- and every Blizzard code path that
-- later reads it runs tainted. That is what produced thousands of errors per
-- Mythic+ run inside Blizzard's own aura and cooldown code, with nothing of
-- ours anywhere in the traceback.
--
-- Run it after a fresh reload and again after some play. A clean result
-- immediately after login proves nothing on its own: the 1.70 bug took a few
-- seconds to re-establish itself, and the first report from this diagnostic was
-- clean for exactly that reason.
--
-- Unlisted, like the other diagnostics. Any future attempt to follow Blizzard's
-- Cooldown Manager filter must be signed off by this on a live client.
function cdmModule:PrintTaintDiagnostics()
    print("|cFF00FF00Squizzumables CDM taint check|r")
    print("  (insecure + blamed on Squizzumables = we tainted it)")

    -- issecurevariable errors on a nil table, and half of what is probed here
    -- may not exist yet on an early login.
    local function Probe(label, tbl, keys)
        if type(tbl) ~= "table" then
            print(("  %-22s |cFF888888absent|r"):format(label))
            return
        end
        local bad = {}
        for _, key in ipairs(keys) do
            local ok, isSecure, who = pcall(issecurevariable, tbl, key)
            if ok and isSecure == false then
                bad[#bad + 1] = key .. "<-" .. tostring(who or "?")
            end
        end
        if #bad == 0 then
            print(("  %-22s |cFF55FF55clean|r"):format(label))
        else
            print(("  %-22s |cFFFF5555%s|r"):format(label, table.concat(bad, " ")))
        end
    end

    -- Plain field reads throughout: `settings.dataProvider` and
    -- `provider.displayData` are both bare fields, verified in Blizzard's
    -- CooldownViewerSettingsDataProvider on Gethe/wow-ui-source live. The
    -- accessors GetDataProvider/GetDisplayData return exactly those fields and
    -- nothing more, so calling them would buy nothing -- and calling
    -- GetOrderedCooldownIDs* instead would run CheckBuildDisplayData on our
    -- stack and CAUSE the taint this is here to measure. A diagnostic that
    -- dirties its own subject is worse than no diagnostic.
    local settings = _G.CooldownViewerSettings
    Probe("settings frame", settings,
        { "dataProvider", "layouts", "activeLayoutID" })

    local provider = settings and settings.dataProvider
    Probe("data provider", provider,
        { "displayData", "displayDataDirty", "layoutManager" })

    local display = provider and provider.displayData
    Probe("display data", display,
        { "orderedCooldownIDs", "cooldownInfoByID", "defaultOrderedCooldownIDs" })

    for _, viewerInfo in ipairs(ALL_VIEWERS) do
        local viewer = _G[viewerInfo.name]
        Probe(viewerInfo.name, viewer,
            { "itemFramePool", "cooldownIDs", "layoutIndex", "isActive" })

        -- One item frame is enough: they come from a shared pool, so if the
        -- pool was populated on a tainted stack they are all the same.
        if viewer then
            local first
            ForEachViewerItem(viewer, function(item)
                if not first then first = item end
            end)
            Probe("  first item frame", first,
                { "cooldownID", "cooldownInfo", "auraInstanceID", "isOnActualCooldown" })
        end
    end
end

-- Re-mute the item frames of any viewer currently suppressed. Cheap, and it has
-- to keep happening: see MuteViewerItems.
function cdmModule:MuteSuppressedViewerItems()
    for _, name in ipairs(BLIZZARD_VIEWERS) do
        local f = _G[name]
        if f and BS(f).dimmed then MuteViewerItems(f, true) end
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
                BS(f).dimmed = true
                HoldAlphaZero(f)
                HoldParked(f)
                f:SetAlpha(0)
                -- Follow the group that replaced it when there is one and the
                -- option is on, so this viewer stays a valid anchor target.
                local follow = BH.settings.cdmViewersFollowGroups ~= false
                local groupFrame = follow and self:GetGroupFrame(VIEWER_TO_GROUP[name]) or nil
                BS(f).followFrame = groupFrame
                ParkFrame(f, groupFrame)
                if f.EnableMouse then f:EnableMouse(false) end
                if f.EnableMouseMotion then f:EnableMouseMotion(false) end
                MuteViewerItems(f, true)
            elseif BS(f).dimmed then
                -- Clear the flag first: the hook reads it, and leaving it set
                -- would have our own restore immediately undone.
                --
                -- Restores to 1 rather than to whatever the player set in Edit
                -- Mode, because reading that back means calling into Edit Mode's
                -- own mixin and this module does not write to or drive Blizzard
                -- frames. It is self-correcting: the same opacity refresh that
                -- caused this whole problem re-asserts the real value on its
                -- next pass, so a viewer set to e.g. 80% returns there shortly.
                BS(f).dimmed = nil
                BS(f).followFrame = nil
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
    -- Borrowed frames go back square FIRST. These are Blizzard's own pooled
    -- items; a mask left on one rides along to Blizzard's bar and stays there
    -- until a reload, which would be our shape appearing on a UI we no longer
    -- claim to be drawing.
    UnshapeAllBorrowed()

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
    -- Native buff slots off with everything else. Their containers are
    -- switched off, not destroyed (nothing can be), and rebuilt on the next
    -- reconcile.
    if self.native then self.native:ReleaseAll() end

    self.groups = {}
    self.freeIcons = {}
    self.soundTrackers = {}

    -- Give Blizzard's viewers back. Switching this module off must not leave
    -- the player with no cooldown display at all -- that reads as the addon
    -- having broken the game UI, and there is nothing on screen to undo it
    -- from. Reads cdmEnabled, which is already false by the time we get here.
    self:ApplyBlizzardVisibility()
end

-- The active profile changed, so the group layout did too.
--
-- Groups live on the profile as of 1.70, which means switching profile swaps
-- the whole set for a different table -- different names, positions and
-- styling. The cached view has to go first, or the rebuild would read the
-- profile that was just left and write the new layout back into it.
--
-- Containers are NOT destroyed by ReleaseAll, and must not be: they are created
-- once per session and reused, because other addons anchor to them by name and
-- WoW cannot destroy a frame. A group present in one profile and absent from
-- the next simply keeps a hidden, empty container.
function cdmModule:OnProfileChanged()
    self:InvalidateSpecData()

    -- Tear down either way: the profile being loaded may have the module off,
    -- and leaving the previous profile's icons on screen would look like the
    -- setting had not applied.
    self:ReleaseAll()

    if BH.settings and BH.settings.cdmEnabled then
        self:EnsureBuiltinGroups()
        self:ScheduleReconcile(RECONCILE_DEBOUNCE)
    end

    -- The settings panel is built once and refreshed in place, so an open
    -- Cooldowns tab would otherwise keep listing the previous profile's groups
    -- -- and worse, its rows hold a direct reference to the old group tables,
    -- so editing one would write into the profile just left.
    if BH.RebuildCDMTabContent then BH:RebuildCDMTabContent() end
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
                gd.isBarGroup = b.bars or nil
                gd.position = { x = 0, y = b.defaultY }
                -- Centred, like Blizzard's own bars. It also matters more here
                -- than for a custom group: with Hide Until Active the row packs
                -- down to whatever is active, and centred growth keeps that
                -- shrinking row anchored in place instead of having it crawl
                -- sideways as buffs come and go.
                gd.growDirection = "centereddown"
            end
        else
            -- Re-stamp the flags: groups made before 1.69 could share a name
            -- with a built-in, and the tab needs to know not to offer delete.
            -- isBarGroup is re-stamped for the same reason plus one of its own
            -- -- it did not exist before 1.74, so every existing profile's
            -- groups are missing it and the bar group would lay out as a grid.
            specData.groups[b.name].builtin = true
            specData.groups[b.name].isBarGroup = b.bars or nil
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
        -- Grey while on cooldown, which is Blizzard's own behaviour. Off by
        -- default so existing groups look unchanged; the two are mutually
        -- exclusive in the settings UI.
        desaturateOnCooldown = false,
        glowOnReady = false,
        -- Off by default on purpose: this is the behaviour V1.81 removed, and
        -- turning it on for everyone would put an aura's countdown back on a
        -- cooldown icon. See the note in the duration pass for why it is safe
        -- to offer at all now.
        showActiveBuff = false,
        hideOutOfCombat = false,
        -- Blizzard parity, on by default: these are things the Cooldown Manager
        -- already does on its own bars, so a group that replaces one should do
        -- them too rather than needing to be switched on to catch up.
        procGlow = true,
        usableTint = true,
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
                    -- The raw set on purpose, not Blizzard's filtered list.
                    -- This is the assignment page: a spell you have hidden on
                    -- Blizzard's bars is exactly the sort of thing you might
                    -- want in a custom group of your own, so hiding it here
                    -- would take away the only way to ask for it.
                    --
                    -- spellID is nilable (equip-slot entries have none), and
                    -- `seenSpells[nil] = true` is a hard error rather than a
                    -- no-op, so every use of it is guarded.
                    local spellID = info.spellID
                    ---@diagnostic disable-next-line: undefined-field
                    local equipSlot = info.equipSlot
                    local spellName = spellID and C_Spell.GetSpellName
                        and C_Spell.GetSpellName(spellID)
                    if spellName and BH.Secrets.IsSecret(spellName) then
                        spellName = nil
                    end
                    local dupe = (spellID and seenSpells[spellID])
                        or (spellName and seenNames[spellName])
                    if not dupe then
                        if spellID then seenSpells[spellID] = true end
                        if spellName then seenNames[spellName] = true end
                        cooldowns[cdID] = {
                            cooldownID = cdID,
                            spellID = spellID,
                            equipSlot = equipSlot,
                            name = spellName or ("Spell " .. cdID),
                            icon = ResolveProxyTexture(spellID, equipSlot),
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
                -- spellID is nilable as of 12.1; indexing a table with nil
                -- reads fine but assigning to it is a hard error, so both
                -- seen-tables are only written through a guard.
                local spellID = info.spellID
                ---@diagnostic disable-next-line: undefined-field
                local equipSlot = info.equipSlot
                local spellName = spellID and C_Spell.GetSpellName
                    and C_Spell.GetSpellName(spellID)
                if spellName and BH.Secrets.IsSecret(spellName) then spellName = nil end
                local dupe = (spellID and seenSpells[spellID])
                    or (spellName and seenNames[spellName])
                if not dupe then
                    if spellID then seenSpells[spellID] = true end
                    if spellName then seenNames[spellName] = true end
                    buffs[cdID] = {
                        cooldownID = cdID,
                        spellID    = spellID,
                        equipSlot  = equipSlot,
                        name       = spellName or ("Buff " .. cdID),
                        icon       = ResolveProxyTexture(spellID, equipSlot),
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
-- Blizzard parity for the cooldown groups. Same five the Essential and Utility
-- viewers register in CooldownViewerCooldownMixin:OnShow, minus
-- SPELL_UPDATE_COOLDOWN which is already above.
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
eventFrame:RegisterEvent("SPELL_UPDATE_USABLE")
eventFrame:RegisterEvent("SPELL_RANGE_CHECK_UPDATE")
eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("COOLDOWN_VIEWER_TABLE_HOTFIXED")

-- No CooldownViewerSettings.OnDataChanged callback here, deliberately.
--
-- 1.70 registered one (twice, in fact) so that hiding a spell in Blizzard's
-- Cooldown Manager options took it off our bar as well. The goal was right and
-- the mechanism was not: a CallbackRegistry runs every handler for an event in
-- one Lua call chain, so our handler tainted the execution and Blizzard's own
-- handlers for that same event -- CooldownViewerMixin registers RefreshLayout
-- on it -- then ran tainted. This is NOT the same as `hooksecurefunc`, which
-- saves and restores taint around the hook; nothing protects a plain callback
-- table.
--
-- The filter is still followed. `CooldownSetSignature` hashes the item frames
-- Blizzard laid out, so an edit in their options changes the signature and the
-- standing 2s ticker reconciles, with no callback and nothing of ours anywhere
-- near their call chain.
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
    --
    -- BOTH lists, raw and filtered. 1.70 switched this to the filtered list
    -- alone, to match what discovery walks, and that broke spec and talent
    -- changes: the raw category set updates the instant the client knows the new
    -- spells, while the item frames only change once Blizzard has rebuilt the
    -- viewer, which happens on its own schedule. So a talent swap could leave
    -- the filtered list momentarily identical, the signature unchanged, and
    -- OnCooldownSetChanged returning early -- no reconcile, no cache reset, and
    -- the old spec's cooldowns still on screen until a reload.
    --
    -- Raw catches spec and talent changes, filtered catches edits in Blizzard's
    -- Cooldown Manager options that leave the raw set identical. Neither alone
    -- covers both, and a signature that misses a change is silent.
    --
    -- The raw half is sorted (the C API's order carries no meaning); the
    -- filtered half deliberately is not, because that order is the player's own
    -- arrangement and drives our layout, so a pure reorder must register.
    for _, viewerInfo in ipairs(DISCOVER_CATEGORIES) do
        local ok, raw = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, viewerInfo.category)
        if ok and type(raw) == "table" then
            local sorted = {}
            for i = 1, #raw do sorted[i] = raw[i] end
            table.sort(sorted)
            parts[#parts + 1] = viewerInfo.category .. "r:" .. table.concat(sorted, ",")
        end

        local ids = BlizzardFilteredIDs(viewerInfo.viewer)
        if ids then
            parts[#parts + 1] = viewerInfo.category .. "f:" .. table.concat(ids, ",")
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
    cdmModule.lastSetChangeAt = GetTime()

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

-- We listen to the three game events behind Blizzard's
-- "CooldownViewerSettings.OnDataChanged" callback -- COOLDOWN_VIEWER_TABLE_HOTFIXED,
-- PLAYER_PVP_TALENT_UPDATE and SPELLS_CHANGED -- rather than to the callback
-- itself, which is the reverse of what this file used to do.
--
-- Registering on that callback looked like the tidier option, since it is the
-- same signal Blizzard's own viewers rebuild from. The cost is invisible: a
-- CallbackRegistry runs every handler for an event in one Lua call chain, so
-- our handler taints the execution and Blizzard's handlers for the SAME event
-- then run tainted, writing to viewer state they later cannot read. That is
-- the same failure the removed filter support caused, reached by a different
-- road. All three events are registered on eventFrame above and handled below,
-- so nothing is lost: an event handler starts its own clean call chain.

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
    -- Proc glow. Edge-triggered by the client, so these are the whole story
    -- while an icon exists; SyncProcGlow covers the icons that did not.
    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW"
       or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        local spellID = ...
        if BH.Secrets.IsSecret(spellID) then return end
        local show = (event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
        for _, proxy in pairs(cdmModule.proxyFrames) do
            if proxy._procGlowAllowed and ProxyMatchesSpell(proxy, spellID) then
                -- skipBirth false: this IS the fresh proc, so the spawn
                -- animation is the point. Blizzard makes the same distinction
                -- between its event path and its refresh path.
                SetProcGlow(proxy, show, false)
            end
        end
        return
    end
    if event == "SPELL_UPDATE_USABLE" then
        for _, proxy in pairs(cdmModule.proxyFrames) do
            ApplyUsableTint(proxy, proxy._usableTintAllowed)
        end
        return
    end
    if event == "SPELL_RANGE_CHECK_UPDATE" then
        local spellID, inRange, checksRange = ...
        if BH.Secrets.HasAnySecret(spellID, inRange, checksRange) then return end
        for _, proxy in pairs(cdmModule.proxyFrames) do
            if ProxyMatchesSpell(proxy, spellID) then
                proxy._outOfRange = (checksRange == true and inRange == false)
                ApplyUsableTint(proxy, proxy._usableTintAllowed)
            end
        end
        return
    end
    if event == "BAG_UPDATE_COOLDOWN" then
        -- Trinkets: nothing else reports an equip-slot cooldown starting.
        UpdateAllProxyCooldowns()
        return
    end
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
    elseif event == "SPELLS_CHANGED" or event == "COOLDOWN_VIEWER_TABLE_HOTFIXED" then
        cdmModule:ScheduleReconcile(RECONCILE_DEBOUNCE)
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Yours only. This event also fires for group members -- their spec
        -- info arriving when someone joins or the roster refreshes -- and this
        -- branch used to tear every group down for each one. In combat
        -- Reconcile then refuses to rebuild, so the whole Cooldown Manager
        -- vanished for the rest of the fight whenever the group changed
        -- (fixed 1.77). Checked here rather than by RegisterUnitEvent, which
        -- is unverified for this event: if it did not apply, your own spec
        -- change would stop arriving at all.
        local unit = ...
        if not unit or unit == "player" then
            -- Never torn down mid-fight: nothing can be rebuilt until combat
            -- ends. Your own spec cannot change in combat, so this is a guard
            -- rather than a path anything should take; PLAYER_REGEN_ENABLED
            -- carries it out.
            if InCombatLockdown() then
                cdmModule.pendingSpecRelease = true
            else
                -- Spec changed - release all, reload for new spec.
                -- Forced: the category sets can still report the outgoing spec
                -- at the moment this fires, so a signature comparison would see
                -- no change and skip. The ticker's comparison catches the real
                -- set a moment later.
                cdmModule:ReleaseAll()
                OnCooldownSetChanged(SPEC_CHANGE_DEBOUNCE, true)
            end
        end
    elseif event == "TRAIT_CONFIG_UPDATED" or event == "PLAYER_PVP_TALENT_UPDATE" then
        -- A talent or loadout swap keeps the spec but can change which spells
        -- exist and which cooldownIDs the viewer uses for them, so the caches
        -- are just as stale as after a spec change. The proxies are left alone:
        -- Reconcile re-derives them, and ReleaseAll would make every icon
        -- visibly flicker on a change that often alters nothing on screen.
        --
        -- Forced, for the same reason the spec branch above is: the signature is
        -- sampled the instant the event arrives, and neither the category sets
        -- nor Blizzard's rebuilt item frames are necessarily updated by then. An
        -- unchanged signature meant an early return -- no cache reset and no
        -- reconcile scheduled at all -- so a loadout swap could leave the old
        -- talents' cooldowns on screen until a reload. The cost of forcing is
        -- one reconcile that occasionally finds nothing new; the cost of not
        -- forcing is silently missing the change.
        OnCooldownSetChanged(SPEC_CHANGE_DEBOUNCE, true)
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
        -- A spec-change teardown that combat postponed (see that branch).
        if cdmModule.pendingSpecRelease then
            cdmModule.pendingSpecRelease = nil
            cdmModule:ReleaseAll()
            OnCooldownSetChanged(SPEC_CHANGE_DEBOUNCE, true)
        end
        -- Run a full reconcile now that protected calls are allowed again
        cdmModule:ScheduleReconcile(0.1)
    end
end)

-- ============================================================================
-- Initialize â€” Called from PLAYER_LOGIN
-- ============================================================================

-- Shared with Squizzumables_CDMAuras.lua (native buffs). That file is separate
-- to keep this one's main chunk clear of Lua 5.1's 200-local limit, so what it
-- needs from here is handed over explicitly rather than reached as upvalues.
cdmModule.shared = {
    GetSpecData              = GetSpecData,
    PlaceText                = PlaceText,
    SHAPE_FILE               = SHAPE_FILE,
    DEFAULT_ICON_SIZE        = DEFAULT_ICON_SIZE,
    DEFAULT_ALPHA            = DEFAULT_ALPHA,
    DEFAULT_BORDER_THICKNESS = DEFAULT_BORDER_THICKNESS,
    DEFAULT_BORDER_COLOR     = DEFAULT_BORDER_COLOR,
    DEFAULT_ICON_ZOOM        = DEFAULT_ICON_ZOOM,
    DEFAULT_BG_COLOR         = DEFAULT_BG_COLOR,
}

function cdmModule:Initialize()
    -- Ahead of the enabled checks: the hooks have to exist even when the module
    -- is off, or turning it on inside Edit Mode leaves them uninstalled.
    HookEditMode()

    -- Load Blizzard_AuraContainer now, at login and out of combat. Loading an
    -- addon is not documented as combat-safe, and until it is loaded the
    -- native buffs fall back to Blizzard's frames.
    if self.native then self.native:Preload() end

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

-- Unlock mode is showing the drag zones, so nothing may hide a group.
--
-- A borrowed group hides itself when nothing in it is active
-- (LayoutBorrowedBuffIcons' SetShown), and that pass runs on the 0.2s poll --
-- so it re-hid the container a fifth of a second after ShowPreview revealed it,
-- and the drag zone appeared to never exist.
--
-- Tracked BARS are what exposed this: they are procs, so out of combat none of
-- them are up, which is exactly when a player is in unlock mode positioning
-- things. The tell was that the zone appeared if Blizzard's Edit Mode was open
-- at the same time -- Edit Mode force-shows Blizzard's viewers including the
-- inactive bars, which made #shown non-zero and stopped the hide firing.
--
-- The Buffs group had the same latent bug and was simply less likely to be
-- empty. Both branches check this flag.
--
-- The flag also turns the groups into a mock of themselves (1.76): GroupAlpha
-- ignores the combat/instance/target conditions, Hide Until Active shows every
-- icon, and the borrowed buff groups fill each inactive slot with a
-- placeholder. All three are reads of previewMode in the normal layout paths,
-- not a separate preview renderer, so the mock cannot drift from the real
-- layout -- it IS the real layout, with nothing hidden.

-- What normally keeps a group out of sight, for its unlock-mode label. Since
-- the preview shows every group regardless, nothing else on screen would say
-- that the box being placed is only there in combat.
local PREVIEW_CONDITIONS = {
    { "hideOutOfCombat", "combat only" },
    { "onlyInInstances", "instances only" },
    { "hideNoEnemy",     "enemy target only" },
    { "hideNoTarget",    "with a target" },
    { "hideMounted",     "hidden mounted" },
    { "hideInHousing",   "hidden in housing" },
    { "hideUntilActive", "active only" },
}

local function PreviewLabelText(groupName, groupData)
    local notes = {}
    if groupData then
        for _, c in ipairs(PREVIEW_CONDITIONS) do
            if groupData[c[1]] then notes[#notes + 1] = c[2] end
        end
    end
    if #notes == 0 then return groupName end
    return groupName .. "  |cffaaaaaa(" .. table.concat(notes, ", ") .. ")|r"
end

-- Re-run the layout after previewMode flips, so what it gates takes effect
-- now rather than on the next reconcile. Alpha first and unconditionally: it
-- is a plain write to our own container and fine in combat. The layout is
-- not -- leaving unlock mode can happen mid-pull (zoning in force-locks) -- so
-- in combat it goes through the reconcile, which waits for combat to end.
function cdmModule:RefreshPreviewLayout()
    UpdateCombatVisibility()
    if InCombatLockdown() then
        self:ScheduleReconcile(0.1)
        return
    end
    for groupName in pairs(self.groups) do
        self:LayoutGroup(groupName)
    end
end

function cdmModule:ShowPreview()
    self.previewMode = true
    self:RefreshPreviewLayout()
    local specData = GetSpecData()
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
            group.previewLabel:SetText(PreviewLabelText(groupName,
                specData and specData.groups[groupName]))
            group.previewLabel:Show()
        end
    end
end

function cdmModule:HidePreview()
    -- Before the loop: the borrowed-layout poll reads this, and until it is
    -- cleared an empty group stays on screen as a stray box.
    self.previewMode = false
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
    -- Put the conditions back: re-hides combat-only groups, repacks Hide Until
    -- Active, and lets the poll release the mock buff placeholders.
    self:RefreshPreviewLayout()
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

-- Which inner tab each group page was last showing, keyed by group name.
--
-- Kept out here rather than on the widget because ClearCDMPage reparents every
-- child of a page away on each rebuild, and a rebuild happens every time any
-- setting on it changes. Without this the tab would snap back to Layout the
-- instant you ticked anything, which reads as the panel fighting you.
local cdmGroupTab = {}

local function BuildCDMScroller(parent, state)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    ns.TuneScrollStep(scrollFrame)
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    state.content = content
    state.scrollFrame = scrollFrame
    state.parent = parent
end

-- Empty a page for a rebuild: its frames and its bare regions (headers and
-- dividers are font strings and textures straight on the page).
local function ClearCDMPage(page)
    for _, child in pairs({ page:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in pairs({ page:GetRegions() }) do
        region:Hide()
        region:SetParent(nil)
    end
end

-- The manager page's sub-tabs: General for the module switches, then one per
-- built-in group in their declared order, keyed by group name so the rebuild
-- can find each group's page.
--
-- The page used to be the switches with every group's full styling stacked
-- underneath -- several screens of scrolling to reach Buffs, and more again
-- for Buff Bars once that group existed.
local CDM_SUBTAB_DEFS = { { key = "general", label = "General" } }
for _, b in ipairs(BUILTIN_GROUPS) do
    CDM_SUBTAB_DEFS[#CDM_SUBTAB_DEFS + 1] = { key = b.name, label = b.name }
end

function BH:BuildCDMTab(parent)
    -- Sub-tabs rather than one scroller; see CDM_SUBTAB_DEFS. General is the
    -- page everything that is not a group still builds into.
    local pages = ns.SubTabs.Create(parent, CDM_SUBTAB_DEFS)
    cdmTabState.pages = pages
    cdmTabState.content = pages.general
    cdmTabState.parent = parent
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
    ClearCDMPage(content)

    -- The manager page's per-group sub-tabs, rebuilt along with it. The pages
    -- themselves are kept, so the sub-tab you are on stays selected when a
    -- setting change rebuilds everything.
    local groupPages = (mode ~= "custom") and state.pages or nil
    if groupPages then
        for _, b in ipairs(BUILTIN_GROUPS) do
            if groupPages[b.name] then ClearCDMPage(groupPages[b.name]) end
        end
    end

    -- Search files each row under the sub-tab it sits on, so a result can bring
    -- that sub-tab forward -- otherwise it lands on the right page with the row
    -- hidden behind an unselected sub-tab. Only the panel's first build pass is
    -- indexed at all; restored before every return.
    local prevSection = ns.Rows.currentSection
    if groupPages then ns.Rows.currentSection = content.section end

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
        yOffset = yOffset - 24

        local nativeCB = CreateSQCheckbox(content, "Draw Buffs Ourselves", function(checked)
            BH.settings.cdmNativeBuffs = checked
            BH:SaveSettings()
            BH.cdm:ScheduleReconcile()
        end)
        nativeCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        ns.Rows.AddTooltip(nativeCB, "Draw Buffs Ourselves",
            "Draw tracked buffs and buff bars as this addon's own icons and bars, so each group's border, "
         .. "zoom, shape, background and text settings apply to them. The game fills in the sweep, stacks "
         .. "and timer itself, so they keep working in combat.\n\nUntick to go back to borrowing Blizzard's "
         .. "own buff frames, which keep Blizzard's look. Totem-style entries that are not real auras always "
         .. "use Blizzard's frame.")
        nativeCB:SetChecked(BH.settings and BH.settings.cdmNativeBuffs ~= false)
        yOffset = yOffset - 28
    end

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    desc:SetWidth(380)
    desc:SetJustifyH("LEFT")
    desc:SetText(mode == "custom"
        and "Make your own groups and choose which spells go in them. Anything you do not assign stays in one of the three standard groups on the Cooldowns tab."
        or "Essential, Utility, Buffs and Buff Bars mirror Blizzard's own Cooldown Manager categories and fill themselves. Style each one on its own tab above. Requires the Cooldown Manager to be enabled in Edit Mode.")
    desc:SetTextColor(DIM_R, DIM_G, DIM_B)
    yOffset = yOffset - 42

    if not (BH.settings and BH.settings.cdmEnabled) then
        content:SetHeight(math.abs(yOffset) + 20)
        -- A group tab with nothing on it would read as broken, so say why.
        if groupPages then
            for _, b in ipairs(BUILTIN_GROUPS) do
                local page = groupPages[b.name]
                if page then
                    local note = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    note:SetPoint("TOPLEFT", page, "TOPLEFT", leftPad, -14)
                    note:SetWidth(380)
                    note:SetJustifyH("LEFT")
                    note:SetText("Turn on the Cooldown Manager on the General tab to style this group.")
                    note:SetTextColor(DIM_R, DIM_G, DIM_B)
                    page:SetHeight(60)
                end
            end
        end
        ns.Rows.currentSection = prevSection
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
            local page = groupPages and groupPages[groupName]
            if page then
                -- On its own sub-tab, from the top of that page.
                if page.section then ns.Rows.currentSection = page.section end
                -- Tabbed, and the page height is the widget's business from
                -- here: it sizes the page to whichever section is showing, so
                -- setting it again from a returned offset would fight that and
                -- cut the taller sections off.
                self:BuildGroupSection(page, leftPad, -14,
                    groupName, specData.groups[groupName], specData, true)
                ns.Rows.currentSection = content.section
            else
                yOffset = self:BuildGroupSection(content, leftPad, yOffset,
                    groupName, specData.groups[groupName], specData)
            end
        end
    end

    -- ===== DIVIDER =====
    -- Not on the manager's General tab: the groups are on their own tabs now,
    -- so this would sit directly under the divider above.
    if not groupPages then
        CreateSQDivider(content, yOffset)
        yOffset = yOffset - 14
    end

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
    if not groupPages then
        yOffset = yOffset - 6
        CreateSQDivider(content, yOffset)
        yOffset = yOffset - 14
    end

    -- ===== REFRESH BUTTON =====
    local refreshBtn = CreateSQButton(content, "Refresh Cooldowns", 160, 26)
    refreshBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    refreshBtn:SetScript("OnClick", function()
        -- force: an explicit press must not be swallowed by a pending pass.
        BH.cdm:ScheduleReconcile(0, true)
        C_Timer.After(0.3, function() BH:RebuildCDMTabContent() end)
    end)
    yOffset = yOffset - 40

    content:SetHeight(math.abs(yOffset) + 20)
    ns.Rows.currentSection = prevSection
end

-- ============================================================================
-- Group settings, in sections
-- ============================================================================
--
-- One group used to be ~50 controls in a single column: every sizing, colour,
-- text, glow and visibility option stacked end to end. Everything worked --
-- nothing here was dead -- but finding any one of them meant scrolling past
-- forty others, which is indistinguishable from the settings being broken.
--
-- So each group page carries its own strip of sections. The builders below are
-- the sections; each takes the running yOffset and returns it, so the SAME
-- code serves both layouts: a group with a page to itself gets tabs, while the
-- Custom Cooldowns tab -- which stacks several groups in one scroller, where
-- tabs per group would be worse than the column ever was -- gets them one
-- after another under headings.

-- A heading, for the stacked layout only. On a tabbed page the tab is the
-- heading, and a second copy of the same word under it is just noise.
local function SectionHeading(content, indent, yOffset, text)
    local fs = content:CreateFontString(nil, "OVERLAY")
    fs:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    fs:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    fs:SetText(text:upper())
    return yOffset - 18
end

-- Position, offset X and offset Y for one piece of icon text. One helper for
-- all three, so the charge number, the countdown and the keybind behave
-- identically rather than drifting apart.
local function AddTextPlacement(content, indent, yOffset, groupData,
                                label, posKey, oxKey, oyKey, defPos, defX, defY, tip)
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
    return yOffset - 46
end

-- ---------------------------------------------------------------------------
-- Layout: where the group sits, how big it is, and how it grows.
-- ---------------------------------------------------------------------------
local function BuildGroupLayoutSection(content, indent, yOffset, groupName, groupData, specData)
    -- A bar group is sized in two dimensions, so it gets width and height where
    -- an icon group gets one square Icon Size. Same slot on the page either way.
    local isBarGroup = groupData.isBarGroup and true or false
    if isBarGroup then
        local widthSlider = CreateSQSlider(content, "Bar Width", 170, 60, 400, 5)
        widthSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(widthSlider, "Bar Width", "How wide each tracked buff bar is, in pixels.")
        widthSlider:SetValue(groupData.barWidth or DEFAULT_BAR_WIDTH)
        widthSlider:SetAfterValueChanged(function(value)
            groupData.barWidth = value
            BH.cdm:ScheduleReconcile()
        end)
    else
        local sizeSlider = CreateSQSlider(content, "Icon Size", 170, 20, 80, 2)
        sizeSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(sizeSlider, "Icon Size", "Width and height of each cooldown icon in this group, in pixels.")
        sizeSlider:SetValue(groupData.iconSize or DEFAULT_ICON_SIZE)
        sizeSlider:SetAfterValueChanged(function(value)
            groupData.iconSize = value
            BH.cdm:ScheduleReconcile()
        end)
    end

    -- Goes NEGATIVE, which overlaps the icons rather than spacing them.
    --
    -- A shape does not fill its icon's square: the shield is 100 wide by 118
    -- tall and is fitted by its height, so about 7.5% of the icon's width is
    -- empty on each side and two neighbours stand that far apart even at zero.
    -- That gap is the art, not the spacing, so no positive value could ever
    -- close it (user report, shield row at spacing 0). Pulling the squares
    -- into each other is what makes shaped icons touch.
    local spacingSlider = CreateSQSlider(content, "Spacing", 170, -20, 20, 1)
    spacingSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(spacingSlider, "Spacing",
        "Gap between icons in this group, in pixels. Negative values overlap "
        .. "them, which is how shaped icons -- the shield especially -- are "
        .. "brought together: a shape leaves empty space inside its own icon, "
        .. "so at 0 there is still a visible gap.")
    spacingSlider:SetValue(groupData.spacing or DEFAULT_SPACING)
    spacingSlider:SetAfterValueChanged(function(value)
        groupData.spacing = value
        BH.cdm:ScheduleReconcile()
    end)
    yOffset = yOffset - 50

    -- Bars always stack one per row -- that is how Blizzard draws them and how
    -- a name and a timer stay readable -- so Per Row has nothing to say here and
    -- the slot goes to the bar's other dimension instead.
    if isBarGroup then
        local heightSlider = CreateSQSlider(content, "Bar Height", 170, 8, 48, 1)
        heightSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(heightSlider, "Bar Height", "How tall each tracked buff bar is, in pixels.")
        heightSlider:SetValue(groupData.barHeight or DEFAULT_BAR_HEIGHT)
        heightSlider:SetAfterValueChanged(function(value)
            groupData.barHeight = value
            BH.cdm:ScheduleReconcile()
        end)
    else
        local rowSlider = CreateSQSlider(content, "Per Row", 170, 1, 20, 1)
        rowSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(rowSlider, "Per Row", "How many icons before wrapping to the next row or column.")
        rowSlider:SetValue(groupData.perRow or DEFAULT_PER_ROW)
        rowSlider:SetAfterValueChanged(function(value)
            groupData.perRow = value
            BH.cdm:ScheduleReconcile()
        end)
    end

    local alphaSlider = CreateSQSlider(content, "Opacity", 170, 10, 100, 5)
    alphaSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(alphaSlider, "Opacity", "Transparency of this group of icons.")
    alphaSlider:SetValue(math.floor((groupData.alpha or DEFAULT_ALPHA) * 100))
    alphaSlider:SetAfterValueChanged(function(value)
        groupData.alpha = value / 100
        BH.cdm:ScheduleReconcile()
    end)
    yOffset = yOffset - 50

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
    yOffset = yOffset - 32

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
    return yOffset - 46
end

-- ---------------------------------------------------------------------------
-- Appearance: what an icon looks like before anything happens to it.
-- ---------------------------------------------------------------------------
local function BuildGroupLookSection(content, indent, yOffset, groupName, groupData, specData)
    -- Built from ICON_SHAPES, so a new shape is one line there plus its image.
    local shapeItems = {}
    for _, s in ipairs(ICON_SHAPES) do
        shapeItems[#shapeItems + 1] = { text = s.text, value = s.value }
    end
    local shapeDD = CreateSQDropdown(content, "Icon Shape", 160, shapeItems, function(val)
        groupData.iconShape = val
        BH.cdm:ScheduleReconcile()
    end)
    shapeDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    shapeDD:SetSelectedValue(groupData.iconShape or "none")
    ns.Rows.AddTooltip(shapeDD, "Icon Shape",
        "Cuts each icon, its cooldown sweep and its border to a shape. Tracked buffs follow it too while Draw Buffs Ourselves is on; Blizzard's own buff frames keep their look.")
    yOffset = yOffset - 50

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

    local borderCB = CreateSQCheckbox(content, "Show Border", function(checked)
        groupData.showBorder = checked
        BH.cdm:ScheduleReconcile()
    end)
    borderCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(borderCB, "Show Border", "Draw a border around each icon in this group.")
    borderCB:SetChecked(groupData.showBorder ~= false)

    local classColorCB = CreateSQCheckbox(content, "Use Class Colour", function(checked)
        groupData.borderClassColor = checked
        BH.cdm:ScheduleReconcile()
    end)
    classColorCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(classColorCB, "Use Class Colour",
        "Colour the border with your class colour, overriding the colour picked above.")
    classColorCB:SetChecked(groupData.borderClassColor)
    yOffset = yOffset - 32

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

    local bcInit = groupData.borderColor or DEFAULT_BORDER_COLOR
    local borderColorPicker = CreateSQColorPicker(content, "Border Colour",
        bcInit[1], bcInit[2], bcInit[3], bcInit[4], function(r, g, b, a)
            groupData.borderColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    borderColorPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(borderColorPicker, "Border Colour", "Colour of the icon border for this group.")
    yOffset = yOffset - 32

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
    yOffset = yOffset - 32

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
    yOffset = yOffset - 32

    local barBgPad = CreateSQSlider(content, "Group Background Padding", 220, 0, 20, 1)
    barBgPad:SetValue(groupData.barBgPadding or 2)
    barBgPad:SetAfterValueChanged(function(value)
        groupData.barBgPadding = value
        BH.cdm:ScheduleReconcile()
    end)
    barBgPad:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(barBgPad, "Group Background Padding", "How far the panel extends past the icons.")
    return yOffset - 46
end

-- ---------------------------------------------------------------------------
-- Text: the three things that can be written on an icon.
-- ---------------------------------------------------------------------------
local function BuildGroupTextSection(content, indent, yOffset, groupName, groupData, specData)
    local cdTextCB = CreateSQCheckbox(content, "Cooldown Text", function(checked)
        groupData.showCooldownText = checked
        BH.cdm:ScheduleReconcile()
    end)
    cdTextCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(cdTextCB, "Cooldown Text", "Show the remaining cooldown as a number on the icon.")
    cdTextCB:SetChecked(groupData.showCooldownText ~= false)
    yOffset = yOffset - 32

    yOffset = AddTextPlacement(content, indent, yOffset, groupData,
        "Cooldown Text", "cooldownTextPosition",
        "cooldownTextOffsetX", "cooldownTextOffsetY", "CENTER", 0, 0,
        "Where the countdown sits on the icon. Centre leaves the game's own placement alone; "
     .. "any other choice moves the countdown the game draws, which it does not officially "
     .. "support, so it is ignored rather than erroring if a patch stops exposing it.")
    yOffset = yOffset - 6

    local countCB = CreateSQCheckbox(content, "Show Charges", function(checked)
        groupData.showCount = checked
        BH.cdm:ScheduleReconcile()
    end)
    countCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(countCB, "Show Charges",
        "Show the charge or stack number on icons that have one.")
    countCB:SetChecked(groupData.showCount ~= false)
    yOffset = yOffset - 32

    local countSize = CreateSQSlider(content, "Charge Text Size", 220, 6, 24, 1)
    countSize:SetValue(groupData.countSize or 12)
    countSize:SetAfterValueChanged(function(v) groupData.countSize = v; BH.cdm:ScheduleReconcile() end)
    countSize:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(countSize, "Charge Text Size", "Font size of the charge number.")
    yOffset = yOffset - 46

    yOffset = AddTextPlacement(content, indent, yOffset, groupData,
        "Charges", "countPosition", "countOffsetX", "countOffsetY",
        "BOTTOMRIGHT", -1, 1, "Where the charge number sits on the icon.")
    yOffset = yOffset - 6

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
    yOffset = yOffset - 32

    local kbSize = CreateSQSlider(content, "Keybind Text Size", 220, 6, 20, 1)
    kbSize:SetValue(groupData.keybindSize or 10)
    kbSize:SetAfterValueChanged(function(value)
        groupData.keybindSize = value
        BH.cdm:ScheduleReconcile()
    end)
    kbSize:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(kbSize, "Keybind Text Size", "Font size of the keybind text.")
    yOffset = yOffset - 46

    return AddTextPlacement(content, indent, yOffset, groupData,
        "Keybind", "keybindPosition", "keybindOffsetX", "keybindOffsetY",
        "TOPRIGHT", -1, -1, "Where the keybind sits on the icon.")
end

-- ---------------------------------------------------------------------------
-- Behaviour: what the icon does as the ability changes state.
-- ---------------------------------------------------------------------------
local function BuildGroupBehaviourSection(content, indent, yOffset, groupName, groupData, specData)
    local tooltipCB = CreateSQCheckbox(content, "Show Tooltip", function(checked)
        groupData.showTooltip = checked
        BH.cdm:ScheduleReconcile()
    end)
    tooltipCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(tooltipCB, "Show Tooltip", "Show the spell tooltip when hovering an icon in this group.")
    tooltipCB:SetChecked(groupData.showTooltip ~= false)
    yOffset = yOffset - 32

    -- The two desaturate options are opposites, so ticking one unticks the
    -- other. Leaving both on screen and independently settable would allow a
    -- combination that greys the icon in every state, which is not a look
    -- anyone wants and is hard to diagnose from the settings alone.
    local desatCB, desatCdCB

    desatCB = CreateSQCheckbox(content, "Grey Out When Ready", function(checked)
        groupData.desaturateReady = checked
        if checked then
            groupData.desaturateOnCooldown = false
            if desatCdCB then desatCdCB:SetChecked(false) end
        end
        BH.cdm:ScheduleReconcile()
    end)
    desatCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(desatCB, "Grey Out When Ready",
        "Grey the icon out while the ability is READY, so a full-colour icon means it is on "
        .. "cooldown. The inverse of the usual arrangement, for a group used as an \"these are "
        .. "up\" display.")
    desatCB:SetChecked(groupData.desaturateReady)

    desatCdCB = CreateSQCheckbox(content, "Grey Out On Cooldown", function(checked)
        groupData.desaturateOnCooldown = checked
        if checked then
            groupData.desaturateReady = false
            if desatCB then desatCB:SetChecked(false) end
        end
        BH.cdm:ScheduleReconcile()
    end)
    desatCdCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(desatCdCB, "Grey Out On Cooldown",
        "Grey the icon out while the ability is on cooldown, which is what Blizzard's own bars "
        .. "do. Only the cooldown counts here, not whether the buff it applies is up.")
    desatCdCB:SetChecked(groupData.desaturateOnCooldown)
    yOffset = yOffset - 32

    local glowCB = CreateSQCheckbox(content, "Glow On Ready", function(checked)
        groupData.glowOnReady = checked
        BH.cdm:ScheduleReconcile()
    end)
    glowCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(glowCB, "Glow On Ready", "Highlight the icon when the ability comes off cooldown.")
    glowCB:SetChecked(groupData.glowOnReady)

    local activeCB = CreateSQCheckbox(content, "Show While Active", function(checked)
        groupData.showActiveBuff = checked
        BH.cdm:ScheduleReconcile()
    end)
    activeCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(activeCB, "Show While Active",
        "While the ability is running, count down how long is LEFT OF IT instead of its cooldown, "
        .. "keep the icon at full colour, and ring it with a glow distinct from the proc highlight. "
        .. "The real cooldown takes over the moment it ends.\n\nOnly applies to abilities whose buff "
        .. "lands on you -- one that buffs your target keeps showing its cooldown, which is what "
        .. "stops a short buff hiding a long cooldown.\n\nWorks in combat: the active display is the "
        .. "real aura, drawn by the game's own aura engine and shown only while the buff is up, so "
        .. "the cooldown underneath is what is left the moment it ends.")
    activeCB:SetChecked(groupData.showActiveBuff)
    yOffset = yOffset - 32

    local agInit = ActiveGlowColor(groupData)
    local activeGlowPicker = CreateSQColorPicker(content, "Active Glow Colour",
        agInit[1], agInit[2], agInit[3], agInit[4] or 1, function(r, g, b, a)
            groupData.activeGlowColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    activeGlowPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(activeGlowPicker, "Active Glow Colour",
        "Colour of the glow shown by \"Show While Active\". Separate from the proc glow and from "
        .. "Glow On Ready, both of which use your main glow colour, so \"the ability is running\" "
        .. "and \"the ability just lit up\" do not look the same.")
    yOffset = yOffset - 32

    local procCB = CreateSQCheckbox(content, "Proc Glow", function(checked)
        groupData.procGlow = checked
        BH.cdm:ScheduleReconcile()
    end)
    procCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(procCB, "Proc Glow",
        "Show the game's own proc highlight on an icon when the ability lights up, the same animation you get on an action bar and on Blizzard's own cooldown bars.")
    procCB:SetChecked(groupData.procGlow ~= false)

    local usableCB = CreateSQCheckbox(content, "Dim When Unusable", function(checked)
        groupData.usableTint = checked
        BH.cdm:ScheduleReconcile()
    end)
    usableCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(usableCB, "Dim When Unusable",
        "Colour the icon by whether you can cast it right now, exactly as Blizzard's own bars do: dimmed when it is unusable, blue when you lack the power for it, and red when the target is out of range.")
    usableCB:SetChecked(groupData.usableTint ~= false)
    return yOffset - 32
end

-- ---------------------------------------------------------------------------
-- Visibility: when the group is on screen at all.
-- ---------------------------------------------------------------------------
local function BuildGroupVisibilitySection(content, indent, yOffset, groupName, groupData, specData)
    local enableCB = CreateSQCheckbox(content, "Enable Group", function(checked)
        groupData.enabled = checked
        BH.cdm:ScheduleReconcile()
    end)
    enableCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(enableCB, "Enable Group",
        "Show this group at all. Unticking hides it without unassigning anything, which is how you switch off one of the built-in groups you do not want.")
    enableCB:SetChecked(groupData.enabled ~= false)
    yOffset = yOffset - 32

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
    yOffset = yOffset - 32

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
        if (i % 2) == 0 or i == #visRows then yOffset = yOffset - 26 end
    end
    return yOffset - 6
end

-- ---------------------------------------------------------------------------
-- Buffs: only meaningful for a group that holds them. Offered nowhere else,
-- because on any other group every control here would be dead.
-- ---------------------------------------------------------------------------
local function GroupHoldsBuffs(groupName)
    local grp = BH.cdm.groups[groupName]
    return (grp and grp.usesBlizzardIcons)
        or groupName == BUILTIN_FOR_VIEWERTYPE["buff"]
        or groupName == BUILTIN_FOR_VIEWERTYPE["buffbar"]
        or false
end

local function BuildGroupBuffSection(content, indent, yOffset, groupName, groupData, specData)
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
    yOffset = yOffset - 32

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

    -- Only the native bars have a fill of ours to colour; Blizzard's
    -- borrowed bars keep their own.
    if groupData.isBarGroup then
        local bc = groupData.barColor or { 1.0, 0.7, 0.0, 1 }
        local barColorPicker = CreateSQColorPicker(content, "Bar Colour",
            bc[1], bc[2], bc[3], bc[4] or 1, function(r, g, b, a)
                groupData.barColor = { r, g, b, a }
                BH.cdm:ScheduleReconcile()
            end)
        barColorPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(barColorPicker, "Bar Colour",
            "Fill colour of the buff bars. Applies when Draw Buffs Ourselves is on.")
        yOffset = yOffset - 32
    end

    return yOffset
end

-- The sections, in the order they appear. Buffs is last and conditional.
local GROUP_SECTIONS = {
    { key = "layout",     label = "Layout",     build = BuildGroupLayoutSection },
    { key = "look",       label = "Appearance", build = BuildGroupLookSection },
    { key = "text",       label = "Text",       build = BuildGroupTextSection },
    { key = "behaviour",  label = "Behaviour",  build = BuildGroupBehaviourSection },
    { key = "visibility", label = "Visibility", build = BuildGroupVisibilitySection },
    { key = "buffs",      label = "Buffs",      build = BuildGroupBuffSection, buffsOnly = true },
}

--- Build one group's settings.
---
--- `tabbed` means this group has a page to itself, so the sections become a
--- strip of tabs and only one is on screen at a time. Without it the sections
--- are stacked under headings and the running yOffset is returned, which is
--- what the Custom Cooldowns tab needs: it puts several groups in one scroller,
--- where a tab strip per group would be worse than the single column ever was.
function BH:BuildGroupSection(content, leftPad, yOffset, groupName, groupData, specData, tabbed)
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

    local holdsBuffs = GroupHoldsBuffs(groupName)

    if not tabbed then
        -- Stacked, under headings.
        for _, sec in ipairs(GROUP_SECTIONS) do
            if not sec.buffsOnly or holdsBuffs then
                yOffset = SectionHeading(content, indent, yOffset, sec.label)
                yOffset = sec.build(content, indent, yOffset, groupName, groupData, specData)
                yOffset = yOffset - 6
            end
        end

        -- Thin separator
        local sep = content:CreateTexture(nil, "ARTWORK")
        sep:SetHeight(1)
        sep:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        sep:SetPoint("TOPRIGHT", content, "TOPRIGHT", -10, yOffset)
        sep:SetColorTexture(0.25, 0.25, 0.30, 0.5)
        return yOffset - 10
    end

    local defs = {}
    for _, sec in ipairs(GROUP_SECTIONS) do
        if not sec.buffsOnly or holdsBuffs then
            defs[#defs + 1] = { key = sec.key, label = sec.label }
        end
    end

    -- The page owns its own height from here: the widget sets it to whichever
    -- section is showing, so the outer scroller scrolls that section rather
    -- than the sum of all of them.
    local pages = ns.SubTabs.CreateInline(content, defs, yOffset, {
        initial = cdmGroupTab[groupName],
        section = content.section,
        onSelect = function(key) cdmGroupTab[groupName] = key end,
    })

    -- Each section files its rows under its own tab, so a search hit can bring
    -- that tab forward instead of landing on a hidden one.
    local prev = ns.Rows.currentSection
    for _, sec in ipairs(GROUP_SECTIONS) do
        local page = pages[sec.key]
        if page then
            ns.Rows.currentSection = page.section or prev
            -- Indented to line up with the tab labels above it.
            local endY = sec.build(page, 12, -8, groupName, groupData, specData)
            pages.SetPageHeight(sec.key, math.abs(endY))
        end
    end
    ns.Rows.currentSection = prev

    -- The host height is the widget's business now, so there is nothing
    -- meaningful to return; the caller stops using it for a tabbed page.
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
    ns.TuneScrollStep(leftScroll)
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
    ns.TuneScrollStep(rightScroll)
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
