-- Cooldowns/Reconcile.lua
-- The Cooldown Manager's main loop: cdmModule:Reconcile discovers Blizzard's
-- cooldown frames, builds or reuses a proxy for each, sorts them into their
-- groups or places them free, and installs the hooks the alerts and buff
-- mirroring depend on. cdmModule:ScheduleReconcile debounces requests for it.
--
-- Moved out of Squizzumables_CDM.lua unchanged in 2.0 phase 2 (the split).
-- Nothing calls into this code while loading; events, the settings and the
-- other Cooldowns files reach it at runtime through cdmModule (BH.cdm). The
-- module's names it uses come through cdmModule.shared and are re-declared
-- below under the same names, so the moved code is byte-identical.

local addonName, ns = ...
local BH = ns.BH

local cdmModule = BH.cdm
local shared    = cdmModule.shared

local GetSpecData             = shared.GetSpecData
local DEFAULT_ICON_SIZE       = shared.DEFAULT_ICON_SIZE
local RECONCILE_DEBOUNCE      = shared.RECONCILE_DEBOUNCE
local BUILTIN_FOR_VIEWERTYPE  = shared.BUILTIN_FOR_VIEWERTYPE
local DestroyProxy            = shared.DestroyProxy
local GetOrCreateProxy        = shared.GetOrCreateProxy
local CreateGroupContainer    = shared.CreateGroupContainer
local DiscoverCooldowns       = shared.DiscoverCooldowns
local BorrowBuffIcons         = shared.BorrowBuffIcons
local ShowActiveAllowed       = shared.ShowActiveAllowed
local HookBlizzardAlertEvents = shared.HookBlizzardAlertEvents
local HookBlizzardBuffFrames  = shared.HookBlizzardBuffFrames
local ScanBlizzardBuffState   = shared.ScanBlizzardBuffState
local MirrorAllBuffCooldowns  = shared.MirrorAllBuffCooldowns
local UpdateAllProxyCooldowns = shared.UpdateAllProxyCooldowns
local FireCDSounds            = shared.FireCDSounds

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
            existing.spellCategory = cdData.spellCategory
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
                spellCategory = cdData.spellCategory,
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

        -- One group per cooldown: drop it from every group it is no longer
        -- assigned to, BEFORE placing it below.
        --
        -- AssignToGroup only clears the PREVIOUS assignment, and a built-in
        -- member has none -- it sits in Essential/Utility by default, with
        -- assignments[cdID] nil. So moving a default Essential spell into a
        -- custom group left it in Essential's members too. Both groups then
        -- laid out the one shared proxy; the custom group placed it last and
        -- kept it, and Essential kept its slot, drawing an empty gap where the
        -- spell used to be (user screenshot 2026-09-24). Clearing here covers
        -- every route a cooldown can move by, not only that one.
        for otherName, other in pairs(self.groups) do
            if otherName ~= assignment and other.members[cdID] then
                other.members[cdID] = nil
            end
        end
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
            -- Tracked buffs are Blizzard's own icons, one per buff: no copies.
            self.DestroyCopyProxy(cdID)
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
        -- spellCategory: potions and Healthstones, which carry neither until
        -- one is used (Cooldowns/ItemCategories.lua).
        elseif assignment and (entry.spellID or entry.equipSlot or entry.spellCategory) then
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
                       and ShowActiveAllowed(entry) then
                        activeWanted[cdID] = {
                            proxy = proxy, groupData = groupData, entry = entry,
                        }
                    end
                end
            end

            -- "Also in": the spell's second icon, in another group. A copy
            -- shows the cooldown, glows and tints like the original, but gets
            -- no "Show While Active" overlay: that system is keyed one per
            -- spell (activeWanted / Native's activeOverlays) and the
            -- original keeps it. A copy aimed at the spell's own group or a
            -- group that no longer exists is dropped.
            local copyTo = specData.copies and specData.copies[cdID]
            local copyGroup = copyTo and copyTo ~= assignment and self.groups[copyTo]
            local copyData = copyGroup and specData.groups[copyTo]
            if copyGroup and copyData then
                local cp = self.GetOrCreateCopyProxy(cdID, copyTo, entry.spellID,
                    copyData.iconSize or DEFAULT_ICON_SIZE, entry.equipSlot)
                cp.auraSpellIDs = entry.auraIDs
                cp.viewerType = entry.viewerType
                cp.selfAura = entry.selfAura
                copyGroup.members[cdID] = cp
                -- Any other group this spell was copied to before.
                for g in pairs(self.copyProxies[cdID] or {}) do
                    if g ~= copyTo then self.DestroyCopyProxy(cdID, g) end
                end
            else
                self.DestroyCopyProxy(cdID)
            end
        else
            -- Not assigned â€” clean up if previously managed
            if entry.managed then
                DestroyProxy(cdID)
                entry.managed = false
            end
            -- A copy only exists alongside a placed original.
            self.DestroyCopyProxy(cdID)
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
            self.DestroyCopyProxy(cdID)
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

    -- The settings tab's "(N tracked)" labels read the members filled above,
    -- so they follow every reconcile rather than only the moment the tab was
    -- built -- see BH:BuildGroupSection.
    if BH.RefreshCDMCounts then BH:RefreshCDMCounts() end
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
