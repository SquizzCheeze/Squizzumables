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

-- ============================================================================
-- Group geometry -- where each icon or bar sits inside a group's container
-- ============================================================================
-- Shared by LayoutGroup (our proxy icons), LayoutBorrowedBuffIcons (Blizzard's
-- buff frames and our placeholders) and the options preview (UI/CDMPreview.lua,
-- through cdmModule.Grid). Before V1.89 the two layout passes each carried
-- their own copy of this maths; one copy is what lets the preview promise to
-- match the real group exactly.
--
-- ONE local on purpose: this file sits about twenty locals short of Lua's
-- 200-per-chunk limit, and a table costs one however much it holds.
local Grid = {}
cdmModule.Grid = Grid

-- Everything about a group's grid that does not depend on which slot is being
-- placed. `vertical` is passed rather than read from groupData because the
-- borrowed-buff layout has only ever laid out horizontally, whatever the
-- Orientation setting says.
function Grid.Icons(count, groupData, vertical)
    local g = {}
    g.size    = groupData.iconSize or DEFAULT_ICON_SIZE
    g.spacing = groupData.spacing or DEFAULT_SPACING
    g.perRow  = groupData.perRow or DEFAULT_PER_ROW
    g.count   = count
    g.vertical = vertical and true or false
    local growDir = groupData.growDirection or DEFAULT_GROW_DIRECTION
    g.centered   = (growDir == "centereddown" or growDir == "centeredup")
    g.centeredUp = (growDir == "centeredup")
    g.colMul, g.rowMul = 1, -1  -- rightdown
    if not g.centered then
        if growDir == "leftdown" then g.colMul, g.rowMul = -1, -1
        elseif growDir == "rightup" then g.colMul, g.rowMul = 1, 1
        elseif growDir == "leftup" then g.colMul, g.rowMul = -1, 1 end
    end
    -- An empty group still measures one icon: floored at one row and column.
    local cols = math.max(1, math.min(count, g.perRow))
    local rows = math.max(1, math.ceil(math.max(count, 1) / g.perRow))
    local step = g.size + g.spacing
    if g.vertical then
        g.width, g.height = rows * step - g.spacing, cols * step - g.spacing
    else
        g.width, g.height = cols * step - g.spacing, rows * step - g.spacing
    end
    return g
end

-- Slot i (1-based) as SetPoint arguments against the container:
-- point, relativePoint, x, y.
--
-- Centred growth measures from the MIDDLE of an edge, so it anchors to that
-- edge's midpoint; anchoring it to a corner once put half the row outside the
-- container (see the note that used to live in LayoutGroup).
function Grid.IconSlot(g, i)
    local col = (i - 1) % g.perRow
    local row = math.floor((i - 1) / g.perRow)
    local step = g.size + g.spacing
    if g.centered then
        local sign = g.centeredUp and 1 or -1
        local itemsThisLine = math.min(g.count - row * g.perRow, g.perRow)
        local lineLen = itemsThisLine * g.size + (itemsThisLine - 1) * g.spacing
        if g.vertical then
            -- Columns march sideways; icons centre vertically.
            local x = (g.size / 2 + row * step) * -sign
            local y = lineLen / 2 - col * step - g.size / 2
            return "CENTER", g.centeredUp and "RIGHT" or "LEFT", x, y
        end
        -- Rows march up or down; icons centre horizontally.
        local x = -lineLen / 2 + col * step + g.size / 2
        local y = (g.size / 2 + row * step) * sign
        return "CENTER", g.centeredUp and "BOTTOM" or "TOP", x, y
    end
    local x, y
    if g.vertical then
        x, y = row * step * g.colMul, col * step * g.rowMul
    else
        x, y = col * step * g.colMul, row * step * g.rowMul
    end
    local anchor = "TOPLEFT"
    if g.colMul < 0 and g.rowMul < 0 then anchor = "TOPRIGHT"
    elseif g.colMul > 0 and g.rowMul > 0 then anchor = "BOTTOMLEFT"
    elseif g.colMul < 0 and g.rowMul > 0 then anchor = "BOTTOMRIGHT" end
    return anchor, anchor, x, y
end

-- Bar groups stack one bar per row -- perRow is an icon idea (see
-- LayoutBorrowedBuffIcons). Growth is only ever up or down.
function Grid.Bars(count, groupData)
    local g = {}
    g.width   = groupData.barWidth  or DEFAULT_BAR_WIDTH
    g.barH    = groupData.barHeight or DEFAULT_BAR_HEIGHT
    g.spacing = groupData.spacing or DEFAULT_SPACING
    local growDir = groupData.growDirection or DEFAULT_GROW_DIRECTION
    g.up = (growDir == "centeredup" or growDir == "rightup" or growDir == "leftup")
    g.height = math.max(count, 1) * (g.barH + g.spacing) - g.spacing
    return g
end

function Grid.BarSlot(g, i)
    local offset = (i - 1) * (g.barH + g.spacing)
    local edge = g.up and "BOTTOM" or "TOP"
    return edge, edge, 0, g.up and offset or -offset
end

-- Runtime group data: { [groupName] = { container, members = { [cdID] = proxy } } }
cdmModule.groups = {}
-- Free icons: { [cooldownID] = proxy }
cdmModule.freeIcons = {}
-- Registry: { [cooldownID] = { spellID, viewerType, managed } }
cdmModule.registry = {}
-- Proxy frames we created: { [cooldownID] = proxyFrame }
cdmModule.proxyFrames = {}
-- A spell's SECOND icon, in its "Also in" group (specData.copies):
-- { [cooldownID] = { [groupName] = proxyFrame } }. Separate from proxyFrames
-- so every existing one-proxy-per-spell path is untouched; the passes that
-- must reach every icon go through cdmModule.ForEachProxy.
cdmModule.copyProxies = {}
-- { [liveSpellID] = true/false }: whether a spell has more than one charge,
-- learned out of combat, so its count can still be shown when the charge
-- info goes secret in combat (see the charge count in the proxy update).
cdmModule.multiCharge = {}
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
    -- { [cooldownID] = groupName }: a SECOND group the spell also shows in
    -- ("Also in"), on top of its assignment. Kept out of assignments and out
    -- of the groups' cooldownIDs lists on purpose -- those mean "this spell
    -- lives here", and deleting a group unassigns everything in its list.
    perSpec.copies = perSpec.copies or {}

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
       or specDataView.freeIcons ~= perSpec.freeIcons
       or specDataView.copies ~= perSpec.copies then
        specDataView = {
            groups = groups,
            assignments = perSpec.assignments,
            freeIcons = perSpec.freeIcons,
            copies = perSpec.copies,
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
local ApplyKeybindText

-- ApplyBarBackground and ApplyShapeToBorrowedChild (with the shapedBorrowed
-- set) live in Cooldowns/TextAndShapes.lua since 2.0 phase 2. That file loads
-- after this one and fills textAndShapes in; these forwarders keep every call
-- here, the shared table and the preview kit unchanged. Nothing calls them
-- while this file loads.
local textAndShapes = {}
cdmModule.textAndShapes = textAndShapes
local function ApplyBarBackground(group, groupData)
    return textAndShapes.ApplyBarBackground(group, groupData)
end
local function ApplyShapeToBorrowedChild(child, shape, zoom)
    return textAndShapes.ApplyShapeToBorrowedChild(child, shape, zoom)
end

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

-- Aura IDs learned from what Blizzard's OWN cooldown item actually matched.
--
-- A "Show While Active" overlay can only light for an aura whose spell ID it
-- was given, and discovery cannot always know that ID in advance: a talent
-- swaps the buff (Avenging Wrath -> Sentinel), or the aura is one of several
-- (Vile Vial of Volatile Venom's use effect, Empowering Venom 1293316, applies
-- a RANDOM secondary-stat buff, each its own spell ID). The icon then glowed,
-- because Blizzard's item knew the ability was running, while its overlay
-- matched nothing and the cooldown showed through (user report 2026-09-26).
--
-- Blizzard's item does find the aura -- it walks its own priority list
-- (CooldownViewerItemDataMixin:GetAssociatedAuraSpellPriority) -- and records
-- the match as item.auraSpellID. That field is a secret in combat and readable
-- out of it, so whenever it is readable and names an ID the overlay does not
-- have, it is saved here and the overlays are rebuilt to include it. Each
-- variant is learned once, the first time it is seen out of combat, and kept
-- for good, so from then on it works in combat too.
--
-- Account-wide and keyed by cooldownID: which aura a spell applies is a fact
-- about the spell, not about a character, spec or profile.
function cdmModule.LearnedAuraIDs(cdID)
    local all = SquizzumablesDB and SquizzumablesDB.cdmLearnedAuras
    return cdID and all and all[cdID] or nil
end

function cdmModule.LearnAuraID(cdID, item)
    if not (cdID and item) or InCombatLockdown() then return end
    local sid = item.auraSpellID
    if sid == nil or BH.Secrets.IsSecret(sid) or type(sid) ~= "number" or sid <= 0 then return end
    if not SquizzumablesDB then return end
    local all = SquizzumablesDB.cdmLearnedAuras or {}
    SquizzumablesDB.cdmLearnedAuras = all
    local set = all[cdID]
    if set and set[sid] then return end
    -- Already one of the entry's own IDs: nothing new to match.
    local entry = cdmModule.registry[cdID]
    if entry then
        if entry.spellID == sid or entry.tooltipSpellID == sid then return end
        for _, id in ipairs(entry.auraIDs or {}) do
            if id == sid then return end
        end
    end
    set = set or {}
    set[sid] = true
    all[cdID] = set
    cdmModule:ScheduleReconcile()
end

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

-- Everything a cooldown transition sets off: its sound and, since 2.0, its
-- image (Cooldown Alerts). The Blizzard hook and both polls all come through
-- here, so a sound and an image on the same event can never be split by the
-- dedupe, which is keyed on spell + event.
local function PlayAlertsFor(cdID, when)
    local spellID = SpellIDForCooldown(cdID) or cdID
    -- Any event ends this spell's "until the next event" images first.
    if BH.CooldownImageEvent then BH:CooldownImageEvent(spellID, when) end
    local sound, image
    for _, alert in ipairs(CollectAlertsFor(cdID)) do
        -- Only ever one sound and one image per event, even if the same spell
        -- ended up with alerts filed under two cooldownIDs.
        if alert.when == when then
            if not sound and alert.type == "Sound" and alert.sound and alert.sound ~= "None" then
                sound = alert
            end
            if not image and alert.image then image = alert end
        end
    end
    if not (sound or image) then return end
    -- Claim only once something would actually be played, so a cooldown with no
    -- alert configured never occupies the dedupe slot.
    if not ClaimAlert(spellID, when) then return end
    if sound and BH.PlaySound then BH:PlaySound(sound.sound) end
    if image and BH.ShowCooldownImage then BH:ShowCooldownImage(spellID, image) end
end
cdmModule.PlayAlertsFor = PlayAlertsFor

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

-- The proc glow's colour, per group. The default is the gold of Blizzard's own
-- proc animation, so a group that never picks one looks as it always did.
local DEFAULT_PROC_GLOW_COLOR = { 1, 0.82, 0, 1 }
local function ProcGlowColor(groupData)
    return (groupData and groupData.procGlowColor) or DEFAULT_PROC_GLOW_COLOR
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
            if not id then return end
            local p = cdmModule.proxyFrames[id]
            if p and p.Cooldown and MirrorOwnsProxy(p) then fn(p, ...) end
            -- And the spell's "Also in" copy, which shows the same cooldown.
            local copies = cdmModule.copyProxies[id]
            if copies then
                for _, cp in pairs(copies) do
                    if cp.Cooldown and MirrorOwnsProxy(cp) then fn(cp, ...) end
                end
            end
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
    bg:SetColorTexture(ns.Theme.RGBA("barBg"))

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

    -- group.previewLook is the options preview (UI/CDMPreview.lua) asking for
    -- this slot drawn as a live buff; it sets the flag per placeholder, so one
    -- preview row can show live and inactive slots side by side.
    local preview = self.previewMode or group.previewLook
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
        -- The timer follows the Text section's countdown size and colour, as
        -- the native bars' duration text does (Squizzumables_CDMAuras.lua Style).
        local customSize = (groupData.cooldownTextSize or 0) > 0 and groupData.cooldownTextSize or nil
        bar.timer:SetFont(PLACEHOLDER_BAR_FONT, customSize or textSize, "OUTLINE")
        local tc = groupData.cooldownTextColor or { 1, 1, 1, 1 }
        bar.timer:SetTextColor(tc[1], tc[2], tc[3], tc[4] or 1)
        local c = groupData.barColor or PLACEHOLDER_BAR_COLOR
        bar.sb:SetStatusBarColor(c[1] or 1, c[2] or 0.7, c[3] or 0, c[4] or 1)

        -- Same rectangle StyleBorder draws for a native bar: the whole frame,
        -- icon included, grown by the thickness on every side.
        if bar.border then
            local thickness = groupData.borderThickness or DEFAULT_BORDER_THICKNESS or 1
            local br, bgc, bb, ba = PlaceholderBorderColor(groupData)
            bar.border:ClearAllPoints()
            -- Border Inside Icon: on the frame's own edge, not grown past it.
            local grow = groupData.borderInside and 0 or thickness
            bar.border:SetPoint("TOPLEFT", ph, "TOPLEFT", -grow, grow)
            bar.border:SetPoint("BOTTOMRIGHT", ph, "BOTTOMRIGHT", grow, -grow)
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
            -- Off with the Text section's Cooldown Text, like a native bar's.
            bar.timer:SetShown(groupData.showCooldownText ~= false)
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
    -- An icon slot drawn as a live buff in the preview wears the live buff
    -- icon's own pieces, styled by the same code (cdmModule.native.Style):
    -- border, shape, background, countdown and stacks. A bare texture here
    -- showed none of them, so the Text and Appearance settings had nothing to
    -- show on the buff groups (user report 2026-10-02). The mock texts are
    -- filled in by UI/CDMPreview.lua. Inactive slots stay bare, as they are live.
    local native = self.native
    local d = ph.previewPieces
    if not isBar and preview and not mirrorSource and native and native.BuildIconPieces then
        if not d then
            d = native.BuildIconPieces(ph)
            ph.previewPieces = d
        end
        d.icon:SetTexture(ph.Icon:GetTexture())
        d.icon:Show()
        d.text:Show()
        native.Style(d, groupData)
        ph.Icon:Hide()
    elseif d then
        d.icon:Hide()
        d.bg:Hide()
        d.border:Hide()
        d.shapeBorder:Hide()
        d.text:Hide()
        d.cooldown:Hide()
        ph.Icon:Show()
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

    -- Blizzard's Edit Mode open while we preview: every slot is a placeholder
    -- of ours. In Edit Mode Blizzard's viewer shows EVERY tracked buff (sample
    -- data, CooldownViewerItemMixin:ShouldBeShown) and keeps laying them out
    -- inside itself -- and that viewer is parked offscreen for Edit Mode (see
    -- ApplyBlizzardVisibility). Taken as active buffs, every slot pointed at a
    -- frame offscreen and the group drew as an empty box, while Unlock Frames
    -- (no buffs up, so all placeholders) drew the full styled mock (user
    -- screenshot 2026-10-17). Placeholders here make the two look the same.
    local blizzEditing = self.previewMode and EditModeManagerFrame
        and EditModeManagerFrame.IsEditModeActive and EditModeManagerFrame:IsEditModeActive() or false

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
                            if child:IsShown() and not blizzEditing then
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
        local g = Grid.Bars(#shown, groupData)
        for i, child in ipairs(shown) do
            child:SetSize(g.width, g.barH)
            child:ClearAllPoints()
            ApplyKeybindText(child, SpellIDForCooldown(child.cooldownID), groupData)
            local point, relPoint, x, y = Grid.BarSlot(g, i)
            child:SetPoint(point, group.container, relPoint, x, y)
        end

        if not InCombatLockdown() then
            group.container:SetSize(g.width, g.height)
        end
        self:SettleNativeCells(groupName, group, shown, idle)
        group.container:SetShown(#shown > 0 or self.previewMode)
        ApplyBarBackground(group, groupData)
        group.container:SetAlpha(GroupAlpha(groupData))
        return
    end

    -- Orientation honoured since V1.89. The Buffs group always offered the
    -- dropdown, but this pass laid out horizontally whatever it said -- which
    -- is why the geometry takes `vertical` as an argument.
    local g = Grid.Icons(#shown, groupData,
        (groupData.orientation or DEFAULT_ORIENTATION) == "vertical")
    local iconSize = g.size

    for i, child in ipairs(shown) do
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
        local point, relPoint, x, y = Grid.IconSlot(g, i)
        child:SetPoint(point, group.container, relPoint, x, y)
    end

    if not InCombatLockdown() then
        group.container:SetSize(g.width, g.height)
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
                            -- Batched: Blizzard calls these on every tracked
                            -- buff item for one aura event, so running the
                            -- pass directly here repeated it per item.
                            local function OnBuffStateChanged()
                                cdmModule.RequestProxyRefresh(true)
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

-- BlizzardFilteredIDs and DiscoverCooldowns live in Cooldowns/Discovery.lua
-- since 2.0 phase 2. That file loads after this one and fills discovery in;
-- these forwarders keep every call site here (the event handler, the shared
-- table) unchanged. Nothing calls them while this file loads.
local discovery = {}
cdmModule.discovery = discovery
local function BlizzardFilteredIDs(viewerGlobal)
    return discovery.BlizzardFilteredIDs(viewerGlobal)
end
local function DiscoverCooldowns()
    return discovery.DiscoverCooldowns()
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
    -- A potion/Healthstone entry (Cooldowns/ItemCategories.lua): no spellID,
    -- no equip slot, and the equip-slot path everywhere -- see EquipSlotCooldown.
    proxy.spellCategory = cdmModule.CategoryForCooldown
        and cdmModule.CategoryForCooldown(cooldownID) or nil

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
    if not texture and proxy.spellCategory then
        -- The potion you carry, not the generic category icon.
        texture = cdmModule.CategoryIcon(proxy.spellCategory)
        proxy._sqCatIcon = texture
    end
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
    -- Not for an equip-slot entry: the spellID a trinket carries is its use
    -- effect, and asking IsSpellUsable about that answers for the spell, not the
    -- item -- see EquipSlotCooldown.
    if enabled and proxy.spellID and not proxy.equipSlot and not proxy.spellCategory then
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

-- An equip-slot entry's cooldown (a trinket), read off the inventory slot the
-- way Blizzard's CheckCacheCooldownValuesFromEquippedItem reads it.
--
-- EQUIP SLOT WINS OVER spellID. Until 1.87 both callers branched on
-- `not proxy.spellID`, on the belief that a trinket entry carries no spell. It
-- can: the spellID is the trinket's use effect (Blizzard's own
-- ShouldDisplaySpellCooldown tests `isOnGCD and self:GetEquipSlot()`, which
-- only makes sense if both are set). Such an entry took the spell path, where
-- the use effect has no cooldown of its own -- so no swipe, never greyed out,
-- while Blizzard's icon showed the item cooldown perfectly.
--
-- Unlike GetSpellCooldown (SecretWhenCooldownsRestricted in the generated
-- docs), the item cooldown APIs carry no secret-return flag, so these should
-- stay readable in combat. SafeNumber anyway: unreadable means "not on
-- cooldown", never an error.
--
-- Returns start, duration, onCD; nil when there is nothing to read.
local function EquipSlotCooldown(proxy)
    -- A potion/Healthstone entry reads its item cooldown the same way, off
    -- whichever item of the category you carry (Cooldowns/ItemCategories.lua).
    if proxy.spellCategory and cdmModule.CategoryCooldown then
        return cdmModule.CategoryCooldown(proxy)
    end
    if not (proxy.equipSlot and GetInventoryItemCooldown) then return nil end
    local start, duration, enable = GetInventoryItemCooldown("player", proxy.equipSlot)
    start = BH.Secrets.SafeNumber(start, nil)
    duration = BH.Secrets.SafeNumber(duration, nil)
    if not (start and duration) then return nil end
    -- enable 0 is a cooldown that has not started yet (it waits for combat to
    -- end); Blizzard draws nothing for it either.
    local enabled = BH.Secrets.SafeNumber(enable, 1) ~= 0
    local onCD = enabled and duration > 1.5 and (start + duration) > GetTime()
    return start, duration, onCD
end

-- May "Show While Active" apply to this entry at all? selfAura false means the
-- spell's aura lands on the target (Lay on Hands with Empyreal Ward), which
-- this display must not show -- see UpdateProxyCooldown.
--
-- NOT for an equip-slot entry. A trinket has no spell to carry that flag, so
-- selfAura false says nothing about where its buff goes, and Blizzard does not
-- consult it either: its item scans player then target for the linked spells
-- (CooldownViewerItemDataMixin:GetAuraData). Honouring it here left trinkets
-- never showing while active (user report 2026-09-22).
local function ShowActiveAllowed(entryOrProxy)
    return entryOrProxy.equipSlot ~= nil or entryOrProxy.selfAura ~= false
end

local function UpdateProxyCooldown(proxy)
    if not proxy or not proxy.Cooldown then return end

    -- Trinkets and the like -- see EquipSlotCooldown for why this is tested
    -- before, and instead of, the spell. Potions and Healthstones too.
    if proxy.equipSlot or proxy.spellCategory then
        local start, duration, onCD = EquipSlotCooldown(proxy)
        proxy.Cooldown:SetReverse(false)
        if onCD then
            proxy.Cooldown:SetCooldown(start, duration)
            -- Nothing reports an item cooldown ENDING (BAG_UPDATE_COOLDOWN
            -- fires as it starts), so without this the swipe ran out on its own
            -- while the icon stayed greyed out until some unrelated refresh.
            -- One timer per end time, however often this pass runs.
            local endsAt = start + duration
            if proxy._sqItemCDEnd ~= endsAt then
                proxy._sqItemCDEnd = endsAt
                C_Timer.After(endsAt - GetTime() + 0.1, function()
                    if proxy._sqItemCDEnd == endsAt then
                        proxy._sqItemCDEnd = nil
                        UpdateAllProxyCooldowns()
                    end
                end)
            end
        else
            proxy.Cooldown:SetCooldown(0, 0)
        end
        -- Still needed on this early return: the glow and the un-greying for
        -- "Show While Active" read it. Same source as the spell path below.
        local activeNow = nil
        if proxy._sqShowActiveBuff then
            local item = cdmModule.viewerItems[proxy.cooldownID]
            if item then activeNow = AuraDisplayActive(item) or nil end
            if activeNow then cdmModule.LearnAuraID(proxy.cooldownID, item) end
            -- Blizzard's Essential item can be as blind to the trinket's buff
            -- as our entry was (see the equip-slot merge at the end of
            -- discovery), so also ask the buff viewer's items, which track it.
            if not activeNow then
                for _, sid in ipairs(proxy.auraSpellIDs or {}) do
                    if CooldownAuraActive(nil, sid) then
                        activeNow = true
                        break
                    end
                end
            end
            -- And learn from the Tracked Buffs item for this trinket as well.
            -- For a random-stat trinket that is the frame that actually binds
            -- the buff -- it is why Tracked Buffs showed the Vial's duration
            -- while the Essential icon could only show its cooldown (user
            -- report 2026-09-26).
            if activeNow then
                for _, sid in ipairs(proxy.auraSpellIDs or {}) do
                    local buffItem = cdmModule.buffItemForSpell[sid]
                    if buffItem then cdmModule.LearnAuraID(proxy.cooldownID, buffItem) end
                end
            end
        end
        proxy._sqActiveNow = activeNow
        return
    end
    if not proxy.spellID then return end

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
    if not isBuffEntry and proxy._sqShowActiveBuff and ShowActiveAllowed(proxy) then
        local item = cdmModule.viewerItems[proxy.cooldownID]
        if item then activeNow = AuraDisplayActive(item) or nil end
        -- Running per Blizzard: learn which aura it matched, so the overlay
        -- can match it too (see cdmModule.LearnAuraID).
        if activeNow then cdmModule.LearnAuraID(proxy.cooldownID, item) end
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
        --
        -- In combat GetSpellCharges is secret (SecretWhenCooldownsRestricted),
        -- so the count used to vanish for the whole fight -- and since spending
        -- a charge usually starts one, it looked like it "never came back"
        -- (user report 2026-10-02). Whether a spell has charges is learned
        -- from a readable pass and remembered (cdmModule.multiCharge); the
        -- count itself goes straight into SetText, which takes a secret
        -- (AllowedWhenTainted) without it ever being read here. A spell first
        -- seen in combat shows no count until the first readable pass.
        local chargeID = LiveSpellID(proxy.spellID)
        local spellCharges = C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(chargeID)
        local maxCharges = spellCharges and BH.Secrets.SafeNumber(spellCharges.maxCharges, nil)
        if maxCharges then cdmModule.multiCharge[chargeID] = maxCharges > 1 end
        if spellCharges and cdmModule.multiCharge[chargeID] then
            proxy.Count:SetText(spellCharges.currentCharges)
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
-- Text placement and icon shapes live in Cooldowns/TextAndShapes.lua since
-- 2.0 phase 2 (its forwarders are with the forward declarations near the top
-- of this file). The four names below are the same ns lookups that file
-- makes, kept for the code here and the shared table; the three forwarders
-- keep the shared-table entries unchanged.
-- ============================================================================

local TEXT_POSITION_ITEMS = ns.TEXT_POSITION_ITEMS
local PlaceText           = ns.PlaceText
local ICON_SHAPES         = ns.Shapes.LIST
local SHAPE_FILE          = ns.Shapes.FILE

local function CooldownCountdownText(cd)
    return textAndShapes.CooldownCountdownText(cd)
end
local function ApplyIconShape(proxy, shape)
    return textAndShapes.ApplyIconShape(proxy, shape)
end
local function UnshapeAllBorrowed()
    return textAndShapes.UnshapeAllBorrowed()
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

-- ApplyProxyVisuals and FireCDSounds (with /sq cdm's PrintSoundDiagnostics)
-- live in Cooldowns/ProxyVisuals.lua since 2.0 phase 2. That file loads
-- after this one and fills proxyVisuals in; these forwarders keep every call
-- site here (UpdateAllProxyCooldowns, the shared table, the preview kit)
-- unchanged. Nothing calls them while this file loads.
local proxyVisuals = {}
cdmModule.proxyVisuals = proxyVisuals
local function ApplyProxyVisuals(proxy, groupData, preview)
    return proxyVisuals.ApplyProxyVisuals(proxy, groupData, preview)
end
local function FireCDSounds()
    return proxyVisuals.FireCDSounds()
end

UpdateAllProxyCooldowns = function()
    cdmModule.ForEachProxy(function(proxy) UpdateProxyCooldown(proxy) end)
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
    -- "Also in" copies: styled by the group they sit in, not the spell's own.
    for _, byGroup in pairs(cdmModule.copyProxies) do
        for groupName, proxy in pairs(byGroup) do
            local groupData = specData.groups[groupName]
            if groupData then
                local wasShown = proxy:IsShown()
                ApplyProxyVisuals(proxy, groupData)
                if groupData.hideUntilActive and proxy:IsShown() ~= wasShown then
                    repack[groupName] = true
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

-- ONE refresh per frame, however many things asked for it.
--
-- The full pass above (every proxy twice over, the sound alerts, and for buff
-- changes a rescan of every Blizzard buff viewer first) was being run straight
-- from three sources: SPELL_UPDATE_COOLDOWN (every GCD, often several in one
-- frame), the player's UNIT_AURA, and a hook on EACH tracked buff item that
-- Blizzard pokes as it processes that same aura event. One aura change could
-- therefore run the whole thing once per tracked buff, plus once more, all in
-- the same frame, allocating fresh tables every time -- the dominant Lua cost
-- of this module in combat. They all come through here now and the pass runs
-- once on the next frame, scan first when any caller asked for one, so the
-- proxies always read the freshly scanned buff state.
--
-- A frame of latency is invisible on a cooldown sweep. It also cannot make a
-- buff read wrongly on appearing: CooldownAuraActive falls through to asking
-- the buff item live whenever the scanned cache has no entry.
--
-- In a do block and on cdmModule: this chunk sits near Lua's 200-local limit.
do
    local pendingScan, pending = false, false
    local runner = CreateFrame("Frame")
    runner:Hide()
    runner:SetScript("OnUpdate", function(self)
        self:Hide()
        local scan = pendingScan
        pendingScan, pending = false, false
        if scan then ScanBlizzardBuffState() end
        UpdateAllProxyCooldowns()
    end)

    function cdmModule.RequestProxyRefresh(withScan)
        if withScan then pendingScan = true end
        if not pending then
            pending = true
            runner:Show()
        end
    end
end

local function GetOrCreateProxy(cooldownID, spellID, iconSize, equipSlot)
    local proxy = cdmModule.proxyFrames[cooldownID]
    if proxy then
        if equipSlot then proxy.equipSlot = equipSlot end
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

-- Copy proxies ("Also in"). On cdmModule inside a do block: this chunk sits
-- against Lua's 200-local limit (see the refresh runner below).
do
    -- Every icon: the spell's own proxy, then its copies. fn(proxy, cdID,
    -- copyGroup) -- copyGroup nil for the primary.
    function cdmModule.ForEachProxy(fn)
        for cdID, proxy in pairs(cdmModule.proxyFrames) do fn(proxy, cdID, nil) end
        for cdID, byGroup in pairs(cdmModule.copyProxies) do
            for groupName, proxy in pairs(byGroup) do fn(proxy, cdID, groupName) end
        end
    end

    function cdmModule.GetOrCreateCopyProxy(cooldownID, groupName, spellID, iconSize, equipSlot)
        local byGroup = cdmModule.copyProxies[cooldownID]
        if not byGroup then
            byGroup = {}
            cdmModule.copyProxies[cooldownID] = byGroup
        end
        local proxy = byGroup[groupName]
        if proxy then
            if equipSlot then proxy.equipSlot = equipSlot end
            proxy:SetSize(iconSize, iconSize)
            proxy.Icon:SetAllPoints()
            proxy.Cooldown:SetAllPoints()
            ResizeSpellAlert(proxy)
            proxy:Show()
            return proxy
        end
        proxy = CreateProxyIcon(cooldownID, spellID, iconSize, equipSlot)
        proxy._sqCopyOf = groupName
        byGroup[groupName] = proxy
        UpdateProxyCooldown(proxy)
        return proxy
    end

    -- Same teardown as DestroyProxy, glows first (see there for why).
    -- groupName nil destroys every copy of the spell.
    function cdmModule.DestroyCopyProxy(cooldownID, groupName)
        local byGroup = cdmModule.copyProxies[cooldownID]
        if not byGroup then return end
        for g, proxy in pairs(byGroup) do
            if groupName == nil or g == groupName then
                SetProcGlow(proxy, false)
                if proxy._glowShowing then
                    ns.Glow.Hide(proxy.GlowFrame or proxy)
                    proxy._glowShowing = false
                end
                proxy:Hide()
                proxy:SetParent(nil)
                local group = cdmModule.groups and cdmModule.groups[g]
                if group and group.members and group.members[cooldownID] == proxy then
                    group.members[cooldownID] = nil
                end
                byGroup[g] = nil
            end
        end
        if not next(byGroup) then cdmModule.copyProxies[cooldownID] = nil end
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
    BH:GridTarget(container) -- others can snap to a group (unlock-mode grid)
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
        BH:GridStartMoving(self)
        self:SetUserPlaced(false)
    end)
    container:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(self)
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


-- ============================================================================
-- Event Handling
-- ============================================================================

local eventFrame = CreateFrame("Frame")
-- Exported only so Squizzumables_StackDiag.lua can wrap this handler from
-- outside; nothing else reads it. Remove alongside that file.
cdmModule.eventFrame = eventFrame

eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
-- A charge spent or regained: the count must follow even when no cooldown
-- event comes with it (it "never came back" after one was used).
eventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
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
            -- The CDM Alerts grid lists this spec's cooldowns, and was drawn
            -- when the tab was built. Rebuilding only the editor would leave
            -- the grid showing the previous spec's spells -- the old "spec
            -- changed and nothing updated" report, since the grid is the part
            -- you look at.
            if BH.RebuildBuffSoundGrid then BH:RebuildBuffSoundGrid() end
            if BH.RebuildBuffSoundEditor then BH:RebuildBuffSoundEditor() end
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
        -- ForEachProxy: an "Also in" copy lights up with its original.
        cdmModule.ForEachProxy(function(proxy)
            if proxy._procGlowAllowed and ProxyMatchesSpell(proxy, spellID) then
                -- skipBirth false: this IS the fresh proc, so the spawn
                -- animation is the point. Blizzard makes the same distinction
                -- between its event path and its refresh path.
                SetProcGlow(proxy, show, false)
            end
        end)
        return
    end
    if event == "SPELL_UPDATE_USABLE" then
        cdmModule.ForEachProxy(function(proxy)
            ApplyUsableTint(proxy, proxy._usableTintAllowed)
        end)
        return
    end
    if event == "SPELL_RANGE_CHECK_UPDATE" then
        local spellID, inRange, checksRange = ...
        if BH.Secrets.HasAnySecret(spellID, inRange, checksRange) then return end
        cdmModule.ForEachProxy(function(proxy)
            if ProxyMatchesSpell(proxy, spellID) then
                proxy._outOfRange = (checksRange == true and inRange == false)
                ApplyUsableTint(proxy, proxy._usableTintAllowed)
            end
        end)
        return
    end
    if event == "BAG_UPDATE_COOLDOWN" then
        -- Trinkets: nothing else reports an equip-slot cooldown starting.
        -- Batched: it fires in bursts alongside SPELL_UPDATE_COOLDOWN.
        cdmModule.RequestProxyRefresh()
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
    if event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" then
        -- Next frame, batched with anything else that asks this frame -- this
        -- event commonly fires several times in one frame on a single cast.
        cdmModule.RequestProxyRefresh()
    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then
            -- Hooking stays immediate: a buff item the pool hands out for this
            -- very aura needs its hooks before Blizzard next pokes it. Only the
            -- scan and the proxy pass are batched.
            HookBlizzardBuffFrames()
            HookBlizzardAlertEvents()
            cdmModule.RequestProxyRefresh(true)
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
    -- Also for Cooldowns/OptionsTab.lua (2.0 split), the CDM settings pages,
    -- which re-declares these under the same names. None is reassigned.
    DEFAULT_BAR_HEIGHT       = DEFAULT_BAR_HEIGHT,
    DEFAULT_BAR_WIDTH        = DEFAULT_BAR_WIDTH,
    DEFAULT_GROW_DIRECTION   = DEFAULT_GROW_DIRECTION,
    DEFAULT_ORIENTATION      = DEFAULT_ORIENTATION,
    DEFAULT_PER_ROW          = DEFAULT_PER_ROW,
    DEFAULT_SORT             = DEFAULT_SORT,
    DEFAULT_SPACING          = DEFAULT_SPACING,
    BUILTIN_GROUPS           = BUILTIN_GROUPS,
    BUILTIN_FOR_VIEWERTYPE   = BUILTIN_FOR_VIEWERTYPE,
    ICON_SHAPES              = ICON_SHAPES,
    TEXT_POSITION_ITEMS      = TEXT_POSITION_ITEMS,
    ActiveGlowColor          = ActiveGlowColor,
    ProcGlowColor            = ProcGlowColor,
    -- And for Cooldowns/API.lua (2.0 split): group management, the cooldown
    -- lists for the settings, preview, lock and reset integration.
    CDM_VIEWERS              = CDM_VIEWERS,
    BUFF_VIEWERS             = BUFF_VIEWERS,
    DestroyProxy             = DestroyProxy,
    ResolveProxyTexture      = ResolveProxyTexture,
    UpdateCombatVisibility   = UpdateCombatVisibility,
    -- And for Cooldowns/Layout.lua (2.0 split): group anchoring, layout and
    -- free icons. GroupAlpha is forward-declared and assigned at load (above
    -- this table), so its real value lands here; ApplyBarBackground is the
    -- forwarder into Cooldowns/TextAndShapes.lua.
    ApplyBarBackground       = ApplyBarBackground,
    GroupAlpha               = GroupAlpha,
    ApplyProxyVisuals        = ApplyProxyVisuals,
    Grid                     = Grid,
    LiveSpellID              = LiveSpellID,
    WouldAnchorLoop          = WouldAnchorLoop,
    -- And for Cooldowns/Reconcile.lua (2.0 split): the main loop.
    -- UpdateAllProxyCooldowns is forward-declared and assigned at load (above
    -- this table), so its real value lands here.
    RECONCILE_DEBOUNCE       = RECONCILE_DEBOUNCE,
    GetOrCreateProxy         = GetOrCreateProxy,
    CreateGroupContainer     = CreateGroupContainer,
    DiscoverCooldowns        = DiscoverCooldowns,
    BorrowBuffIcons          = BorrowBuffIcons,
    ShowActiveAllowed        = ShowActiveAllowed,
    HookBlizzardAlertEvents  = HookBlizzardAlertEvents,
    HookBlizzardBuffFrames   = HookBlizzardBuffFrames,
    ScanBlizzardBuffState    = ScanBlizzardBuffState,
    MirrorAllBuffCooldowns   = MirrorAllBuffCooldowns,
    UpdateAllProxyCooldowns  = UpdateAllProxyCooldowns,
    FireCDSounds             = FireCDSounds,
    -- And for Cooldowns/BlizzardViewers.lua (2.0 split): the public group
    -- frame API, hiding Blizzard's viewers, diagnostics, ReleaseAll. That file
    -- hands HookEditMode back as shared.HookEditMode for Initialize.
    ALL_VIEWERS              = ALL_VIEWERS,
    BS                       = BS,
    containerCache           = containerCache,
    ForEachViewerItem        = ForEachViewerItem,
    UnshapeAllBorrowed       = UnshapeAllBorrowed,
    -- And for Cooldowns/ProxyVisuals.lua (2.0 split): ApplyProxyVisuals,
    -- FireCDSounds, the sound diagnostics. ApplyKeybindText is forward-declared
    -- and assigned at load (above this table), so its real value lands here.
    GetSpecKey               = GetSpecKey,
    GetCDMSoundAlerts        = GetCDMSoundAlerts,
    BORROW_VIEWERS           = BORROW_VIEWERS,
    DISCOVER_CATEGORIES      = DISCOVER_CATEGORIES,
    BlizzardFilteredIDs      = BlizzardFilteredIDs,
    ApplyIconShape           = ApplyIconShape,
    CooldownCountdownText    = CooldownCountdownText,
    ApplyKeybindText         = ApplyKeybindText,
    SetProcGlow              = SetProcGlow,
    SyncProcGlow             = SyncProcGlow,
    ResizeSpellAlert         = ResizeSpellAlert,
    RaiseGlowFrame           = RaiseGlowFrame,
    ApplyUsableTint          = ApplyUsableTint,
    EquipSlotCooldown        = EquipSlotCooldown,
    SpellIDForCooldown       = SpellIDForCooldown,
    CooldownActiveFromViewer = CooldownActiveFromViewer,
    CooldownAuraActive       = CooldownAuraActive,
    CollectAlertsFor         = CollectAlertsFor,
    PlayAlertsFor            = PlayAlertsFor,
}

function cdmModule:Initialize()
    -- Ahead of the enabled checks: the hooks have to exist even when the module
    -- is off, or turning it on inside Edit Mode leaves them uninstalled.
    -- (Published by Cooldowns/BlizzardViewers.lua, which loads after this file.)
    self.shared.HookEditMode()

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
-- Cooldown alert storage, for the CDM Alerts editor (Alerts/CDMAlerts.lua)
--
-- The CDM Sounds page that used to live here was replaced in 2.0 by one CDM
-- Alerts page shared with buffs (user decision 2026-10-15): one grid, one
-- editor layout, images for both. The editor lives with the buff one; this is
-- just its way into the per-spec alert store, which stays local to this file.
-- ============================================================================

--- The alert list for a cooldown, keyed by spell (AlertKey). With `create`,
--- an empty list is made when there is none. Also returns the store and key,
--- so a caller can drop an emptied list.
function cdmModule.AlertListFor(cdID, create)
    local store = GetCDMSoundAlerts()
    local key = cdmModule.AlertKey(cdID)
    if create and not store[key] then store[key] = {} end
    return store[key], store, key
end

-- ============================================================================
-- Options preview kit (UI/CDMPreview.lua)
-- ============================================================================
-- The preview draws a group with the REAL builders and stylers, never copies
-- of them -- the rule that keeps SquizzFrames' previews honest. Assembled at
-- the very end of the file because several of these are forward-declared
-- locals assigned further up, and a table captures the value at assignment.
-- Fields on an existing table, so this costs the chunk no locals.
cdmModule.PreviewKit = {
    CreateProxyIcon           = CreateProxyIcon,
    ApplyProxyVisuals         = ApplyProxyVisuals,
    SetProcGlow               = SetProcGlow,
    ApplyKeybindText          = ApplyKeybindText,
    ApplyShapeToBorrowedChild = ApplyShapeToBorrowedChild,
    ApplyBarBackground        = ApplyBarBackground,
    SpellIDForCooldown        = SpellIDForCooldown,
    GetSpecData               = GetSpecData,
    DEFAULT_ICON_ZOOM         = DEFAULT_ICON_ZOOM,
}

-- What a group would show, in the order it would show it, for the preview.
--
-- Returns { borrowed = bool, items = { {cdID, spellID, equipSlot, viewerType} } }.
-- A proxy group lists its members in Blizzard's (assignment) order -- the
-- default sort; name and cooldown sorts depend on live state, so the preview
-- keeps assignment order for those too. A borrowed group lists every buff its
-- viewers track, which is the full row unlock mode would show.
function cdmModule:PreviewMembers(groupName)
    local out = { borrowed = false, items = {} }
    local group = self.groups[groupName]
    if not group then
        -- No live group (the module is off, or it has not reconciled yet).
        -- Still say what KIND of group it is, so an empty Buff Bars previews
        -- as bars rather than as icons.
        out.borrowed = BORROW_VIEWERS[groupName] ~= nil
        return out
    end

    if group.usesBlizzardIcons then
        out.borrowed = true
        local seen = {}
        for _, viewerName in ipairs(BORROW_VIEWERS[groupName] or BUFF_VIEWERS) do
            local viewer = _G[viewerName]
            if viewer then
                local ok, children = pcall(function() return { viewer:GetChildren() } end)
                if ok and children then
                    for _, child in ipairs(children) do
                        local cdID = child and child.cooldownID
                        if cdID and not seen[cdID] then
                            seen[cdID] = true
                            out.items[#out.items + 1] = {
                                cdID = cdID, spellID = SpellIDForCooldown(cdID),
                                viewerType = "buff",
                            }
                        end
                    end
                end
            end
        end
        table.sort(out.items, function(a, b) return a.cdID < b.cdID end)
        return out
    end

    for cdID, proxy in pairs(group.members or {}) do
        out.items[#out.items + 1] = {
            cdID = cdID, spellID = proxy.spellID, equipSlot = proxy.equipSlot,
            spellCategory = proxy.spellCategory,
            viewerType = proxy.viewerType,
        }
    end
    local registry = self.registry or {}
    table.sort(out.items, function(a, b)
        local ea, eb = registry[a.cdID], registry[b.cdID]
        local oa, ob = ea and ea.order, eb and eb.order
        if oa and ob and oa ~= ob then return oa < ob end
        if oa and not ob then return true end
        if ob and not oa then return false end
        return a.cdID < b.cdID
    end)
    return out
end
