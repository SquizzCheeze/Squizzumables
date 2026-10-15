-- Cooldowns/API.lua
-- The Cooldown Manager's outward-facing layer: group management for the
-- settings UI (create, rename, delete, assign, reorder), the cooldown lists
-- the settings show, and the integrations with the addon's preview, Lock All
-- and Reset Positions.
--
-- Moved out of Squizzumables_CDM.lua unchanged in 2.0 phase 2 (the split).
-- Nothing in that file calls into this code while loading, and everything
-- here is reached at runtime through cdmModule (BH.cdm). The module's names it
-- uses come through cdmModule.shared and are re-declared below under the
-- same names, so the moved code is byte-identical.

local addonName, ns = ...
local BH = ns.BH

local cdmModule = BH.cdm
local shared    = cdmModule.shared

local GetSpecData              = shared.GetSpecData
local DEFAULT_ICON_SIZE        = shared.DEFAULT_ICON_SIZE
local DEFAULT_ALPHA            = shared.DEFAULT_ALPHA
local DEFAULT_BORDER_THICKNESS = shared.DEFAULT_BORDER_THICKNESS
local DEFAULT_BORDER_COLOR     = shared.DEFAULT_BORDER_COLOR
local DEFAULT_ICON_ZOOM        = shared.DEFAULT_ICON_ZOOM
local DEFAULT_BG_COLOR         = shared.DEFAULT_BG_COLOR
local DEFAULT_GROW_DIRECTION   = shared.DEFAULT_GROW_DIRECTION
local DEFAULT_ORIENTATION      = shared.DEFAULT_ORIENTATION
local DEFAULT_PER_ROW          = shared.DEFAULT_PER_ROW
local DEFAULT_SORT             = shared.DEFAULT_SORT
local DEFAULT_SPACING          = shared.DEFAULT_SPACING
local BUILTIN_GROUPS           = shared.BUILTIN_GROUPS
local CDM_VIEWERS              = shared.CDM_VIEWERS
local BUFF_VIEWERS             = shared.BUFF_VIEWERS
local DestroyProxy             = shared.DestroyProxy
local ResolveProxyTexture      = shared.ResolveProxyTexture
local UpdateCombatVisibility   = shared.UpdateCombatVisibility

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
    -- And forget every "Also in" copy that pointed here. Their icons are
    -- destroyed before the container goes (below would treat them as the
    -- spells' own proxies and destroy those instead).
    for cdID, target in pairs(specData.copies or {}) do
        if target == groupName then
            specData.copies[cdID] = nil
            self.DestroyCopyProxy(cdID, groupName)
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

-- "Also in": show the spell in a second group as well (groupName), or stop
-- (nil). One copy per spell; the next Reconcile builds or drops the icon.
function cdmModule:SetCopy(cooldownID, groupName)
    local specData = GetSpecData()
    if not specData then return end
    specData.copies = specData.copies or {}
    specData.copies[cooldownID] = groupName
    if not groupName then self.DestroyCopyProxy(cooldownID) end
    self:ScheduleReconcile()
    C_Timer.After(0.2, function() if BH.RebuildCDMTabContent then BH:RebuildCDMTabContent() end end)
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

            -- The shared Edit Mode mover (UI/EditMode.lua), the same box every
            -- other frame gets: named, since several groups on screen at once
            -- are impossible to tell apart otherwise. The arrow keys move the
            -- group's saved centre offset -- the same number its drag saves --
            -- and leave an anchored group alone, as the drag does.
            local name = groupName
            ns.EditMode.Show(group.container,
                PreviewLabelText(groupName, specData and specData.groups[groupName]), {
                nudge = function(dx, dy)
                    local sd = GetSpecData()
                    local gd = sd and sd.groups[name]
                    if not gd or (gd.anchorTo and gd.anchorTo ~= "") then return end
                    local p = gd.position or {}
                    gd.position = { x = (p.x or 0) + dx, y = (p.y or 0) + dy }
                    self:PositionGroup(name)
                end,
            })
        end
    end
end

function cdmModule:HidePreview()
    -- Before the loop: the borrowed-layout poll reads this, and until it is
    -- cleared an empty group stays on screen as a stray box.
    self.previewMode = false
    for groupName, group in pairs(self.groups) do
        ns.EditMode.Hide(group.container)
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
