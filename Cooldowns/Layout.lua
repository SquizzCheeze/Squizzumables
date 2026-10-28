-- Cooldowns/Layout.lua
-- Where the Cooldown Manager's groups and icons go: anchoring a group to the
-- screen, to another group or to another addon's frame (with the public
-- Squizzumables_RegisterAnchorTarget), laying out the icons inside a group
-- (LayoutGroup), and placing free icons.
--
-- Moved out of Squizzumables_CDM.lua unchanged in 2.0 phase 2 (the split).
-- Nothing calls into this code while loading; the reconcile loop and the
-- settings reach it at runtime through cdmModule (BH.cdm). The module's names
-- it uses come through cdmModule.shared and are re-declared below under the
-- same names, so the moved code is byte-identical.

local addonName, ns = ...
local BH = ns.BH

local cdmModule = BH.cdm
local shared    = cdmModule.shared

local GetSpecData         = shared.GetSpecData
local DEFAULT_ICON_SIZE   = shared.DEFAULT_ICON_SIZE
local DEFAULT_ORIENTATION = shared.DEFAULT_ORIENTATION
local DEFAULT_SORT        = shared.DEFAULT_SORT
local ApplyBarBackground  = shared.ApplyBarBackground
local GroupAlpha          = shared.GroupAlpha
local ApplyProxyVisuals   = shared.ApplyProxyVisuals
local Grid                = shared.Grid
local LiveSpellID         = shared.LiveSpellID
local WouldAnchorLoop     = shared.WouldAnchorLoop

-- ============================================================================
-- Anchoring a group to ANOTHER ADDON'S frame
-- ============================================================================
--
-- anchorTo holds either a group name or "frame:<GlobalFrameName>". The frame
-- form is resolved through _G at placement time, so it works for any addon's
-- named frame -- the curated list below only decides what the dropdown offers,
-- and the "Frame name" box beside it takes anything else (/fstack shows names).
--
-- Kept on cdmModule rather than as file locals: this chunk sits close to Lua's
-- 200-local ceiling (see CLAUDE.md).

-- Offered in the Anchor To dropdown when the frame exists. SquizzFrames' cast
-- bars are named "SquizzFramesCastBar" .. unit with the unit LOWER-case.
cdmModule.EXTERNAL_ANCHORS = {
    { frame = "SquizzFramesCastBarplayer",   text = "SquizzFrames: Player Cast Bar" },
    { frame = "SquizzFramesCastBartarget",   text = "SquizzFrames: Target Cast Bar" },
    { frame = "SquizzFramesCastBarfocus",    text = "SquizzFrames: Focus Cast Bar" },
    { frame = "SquizzFramesUnitFramePlayer", text = "SquizzFrames: Player Frame" },
    { frame = "SquizzFramesUnitFrameTarget", text = "SquizzFrames: Target Frame" },
    { frame = "SquizzFramesUnitFrameFocus",  text = "SquizzFrames: Focus Frame" },
    { frame = "SquizzFramesResourceBar",     text = "SquizzFrames: Resource Bar" },
    { frame = "SquizzFramesResourcePoints",  text = "SquizzFrames: Resource Points" },
    { frame = "SquizzFramesPartyFrame",      text = "SquizzFrames: Party/Raid Frames" },
}

-- For other addons: offer one of your frames in the Anchor To dropdown.
--     Squizzumables_RegisterAnchorTarget("MyAddonBar", "MyAddon: Bar")
-- Registering is only about the list; any named frame can already be typed in.
function Squizzumables_RegisterAnchorTarget(frameName, label)
    if type(frameName) ~= "string" or frameName == "" then return end
    for _, e in ipairs(cdmModule.EXTERNAL_ANCHORS) do
        if e.frame == frameName then e.text = label or e.text return end
    end
    cdmModule.EXTERNAL_ANCHORS[#cdmModule.EXTERNAL_ANCHORS + 1] =
        { frame = frameName, text = label or frameName }
end

function cdmModule.ResolveExternalAnchor(frameName)
    local f = frameName and _G[frameName]
    if type(f) ~= "table" or type(f.GetObjectType) ~= "function" then return nil end
    if f.IsForbidden and f:IsForbidden() then return nil end
    return f
end

-- Does `frame`'s anchor chain lead back to `onto`? Anchoring `onto` to `frame`
-- would then be a cycle, which WoW refuses with a hard error. A group-to-group
-- loop is caught by WouldAnchorLoop from saved settings; across addons the only
-- truth is the live geometry, so this walks GetPoint's relative frames.
-- Bounded, and pcall'd per call: a forbidden region in the chain can refuse.
function cdmModule.AnchorDependsOn(frame, onto)
    local queue, seen, head = { frame }, { [frame] = true }, 1
    while queue[head] and head <= 128 do
        local f = queue[head]
        head = head + 1
        if f == onto then return true end
        local okN, n = pcall(f.GetNumPoints, f)
        for i = 1, (okN and n) or 0 do
            local ok, _, rel = pcall(f.GetPoint, f, i)
            -- A nil relativeTo means the parent.
            if ok and rel == nil and f.GetParent then rel = f:GetParent() end
            if ok and type(rel) == "table" and not seen[rel] then
                seen[rel] = true
                queue[#queue + 1] = rel
            end
        end
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

    local target
    local external = targetName and targetName:match("^frame:(.+)$")
    if external then
        target = cdmModule.ResolveExternalAnchor(external)
        if target and (target == container or cdmModule.AnchorDependsOn(target, container)) then
            -- That frame is (eventually) anchored to THIS group. Placing us on
            -- it would be a cycle; stay at our own position instead.
            target = nil
        elseif not target then
            -- Not created yet -- another addon that builds its frames after
            -- ours does. Retry a few times rather than stranding the group at
            -- its free position for the session.
            self._anchorRetries = self._anchorRetries or {}
            local n = (self._anchorRetries[groupName] or 0) + 1
            self._anchorRetries[groupName] = n
            if n <= 10 then
                C_Timer.After(2, function() self:PositionGroup(groupName) end)
            end
        end
        if target and self._anchorRetries then self._anchorRetries[groupName] = nil end
    else
        target = targetName and targetName ~= groupName
                 and not WouldAnchorLoop(specData, groupName, targetName)
                 and self.groups[targetName] and self.groups[targetName].container
                 or nil
    end

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
    local orientation = groupData.orientation or DEFAULT_ORIENTATION
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

    -- Potions and Healthstones you carry none of are hidden and take no slot
    -- (Cooldowns/ItemCategories.lua, CategoryCarried).
    if cdmModule.CategoryCarried then
        local kept = {}
        for _, member in ipairs(members) do
            local p = member.proxy
            if p and p.spellCategory and not cdmModule.CategoryCarried(p.spellCategory) then
                p:Hide()
            else
                kept[#kept + 1] = member
            end
        end
        members = kept
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

    -- Geometry from the shared Grid (top of this file), so the options preview
    -- places its icons with exactly this maths.
    --
    -- Centred growth used to anchor to TOPLEFT/BOTTOMLEFT, which put a centred
    -- row around the container's LEFT EDGE -- half the row outside the frame,
    -- so dragging moved icons nowhere near the drag region and clicks missed.
    -- Grid.IconSlot anchors centred slots to the edge MIDPOINT for that reason.
    local g = Grid.Icons(#members, groupData, orientation == "vertical")
    local fullW, fullH = g.width, g.height

    -- Position each proxy. `slot` counts placed icons, not members, so a nil
    -- proxy leaves no gap -- the same as the old col/row counters did.
    local slot = 0
    for _, member in ipairs(members) do
        local proxy = member.proxy
        if proxy then
            proxy:SetParent(group.container)
            proxy:SetSize(iconSize, iconSize)
            proxy.Icon:SetAllPoints()
            proxy.Cooldown:SetAllPoints()
            proxy:ClearAllPoints()

            slot = slot + 1
            local point, relPoint, xOff, yOff = Grid.IconSlot(g, slot)
            proxy:SetPoint(point, group.container, relPoint, xOff, yOff)
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
                    BH:GridStartMoving(group.container)
                    group.container:SetUserPlaced(false)
                end)
                proxy:SetScript("OnDragStop", function()
                    BH:GridStopMoving(group.container)
                    local sd = GetSpecData()
                    -- Measured with GetCenter, exactly as the container's own
                    -- OnDragStop does (see the long note there). This path
                    -- still read GetPoint(), whose offsets are relative to
                    -- whatever anchor StartMoving left -- the "drag does not
                    -- save" bug that handler was fixed for, alive here for a
                    -- group dragged by one of its icons.
                    if sd and sd.groups[groupName] then
                        local cx, cy = group.container:GetCenter()
                        local px, py = UIParent:GetCenter()
                        if cx and cy and px and py then
                            sd.groups[groupName].position = { x = cx - px, y = cy - py }
                        end
                    end
                end)
                proxy._groupDragSetup = groupName
            end

            -- Apply visual settings
            ApplyProxyVisuals(proxy, groupData)
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
    -- A free potion/Healthstone you carry none of stays hidden, as in a group.
    proxy:SetShown(not (proxy.spellCategory and cdmModule.CategoryCarried
        and not cdmModule.CategoryCarried(proxy.spellCategory)))

    -- Make free proxy icons draggable (safe â€” this is OUR frame, not Blizzard's)
    if not proxy._sqzFreeDrag then
        proxy._sqzFreeDrag = true
        proxy:SetMovable(true)
        proxy:RegisterForDrag("LeftButton")
        proxy:SetScript("OnDragStart", function(self)
            if InCombatLockdown() then return end
            BH:GridStartMoving(self)
            self:SetUserPlaced(false)
        end)
        proxy:SetScript("OnDragStop", function(self)
            BH:GridStopMoving(self)
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
