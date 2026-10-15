-- Cooldowns/BlizzardViewers.lua
-- Squizzumables and Blizzard's own Cooldown Manager: the public group-frame
-- API (Squizzumables_GetCDMGroupFrame / GetCDMGroupNames), the "hide
-- Blizzard's Cooldown Manager" option (dimming, muting and parking Blizzard's
-- viewers, following Edit Mode), the buff and taint diagnostics, ReleaseAll
-- and the profile-change rebuild.
--
-- Moved out of Squizzumables_CDM.lua unchanged in 2.0 phase 2 (the split).
-- Nothing calls into this code while loading; events, the settings and the
-- other Cooldowns files reach it at runtime through cdmModule (BH.cdm). The
-- module's names it uses come through cdmModule.shared and are re-declared
-- below under the same names, so the moved code is byte-identical. The one
-- name the module needs back, HookEditMode, is published at the bottom.

local addonName, ns = ...
local BH = ns.BH

local cdmModule = BH.cdm
local shared    = cdmModule.shared

local RECONCILE_DEBOUNCE = shared.RECONCILE_DEBOUNCE
local ALL_VIEWERS        = shared.ALL_VIEWERS
local BUFF_VIEWERS       = shared.BUFF_VIEWERS
local BS                 = shared.BS
local containerCache     = shared.containerCache
local ForEachViewerItem  = shared.ForEachViewerItem
local SpellIDForCooldown = shared.SpellIDForCooldown
local BorrowBuffIcons    = shared.BorrowBuffIcons
local UnshapeAllBorrowed = shared.UnshapeAllBorrowed
local DestroyProxy       = shared.DestroyProxy

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

-- The names Squizzumables_GetCDMGroupFrame will currently answer for: the
-- built-ins first in their usual order, then custom groups alphabetically.
-- Only groups whose frame exists this session are listed, so every name
-- returned resolves. A fresh table each call; the caller may keep it.
-- (SquizzFrames builds its "Attach To" dropdowns from this.)
function Squizzumables_GetCDMGroupNames()
    local out, custom = {}, {}
    local builtin = { Essential = 1, Utility = 2, Buffs = 3, ["Buff Bars"] = 4 }
    for name in pairs(containerCache) do
        if builtin[name] then out[#out + 1] = name else custom[#custom + 1] = name end
    end
    table.sort(out, function(a, b) return builtin[a] < builtin[b] end)
    table.sort(custom)
    for _, name in ipairs(custom) do out[#out + 1] = name end
    return out
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

    -- Destroy all proxy frames, copies included
    for cdID, _ in pairs(self.proxyFrames) do
        DestroyProxy(cdID)
    end
    for cdID in pairs(self.copyProxies) do
        self.DestroyCopyProxy(cdID)
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

-- For cdmModule:Initialize, which installs the Edit Mode hooks at login.
shared.HookEditMode = HookEditMode
