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
    - Queues container mutations during InCombatLockdown(), flushes on PLAYER_REGEN_ENABLED.
]]
---@diagnostic disable: undefined-global

local addonName, ns = ...
local BH = ns.BH

-- Shared UI constructors, defined in Squizzumables.lua which loads before this.
local CreateSQButton   = ns.CreateSQButton
local CreateSQSlider   = ns.CreateSQSlider
local CreateSQCheckbox = ns.CreateSQCheckbox
local CreateSQDropdown = ns.CreateSQDropdown
local CreateSQDivider  = ns.CreateSQDivider

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
    return sd.soundAlerts
end

-- ============================================================================
-- Active Buff Tracking â€” Hook Blizzard's CDM buff frames (read-only, taint-safe)
-- Follows the same approach as CooldownManagerCentered:
-- hooksecurefunc on OnActiveStateChanged / OnUnitAuraAddedEvent / OnUnitAuraRemovedEvent
-- ============================================================================

-- Forward declarations (defined later in the file)
local UpdateAllProxyCooldowns

-- The two buff-type CDM viewers: category 2 = buff icons, category 3 = tracked bars
local BUFF_VIEWERS = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

-- Scan both buff viewers' children visibility to populate activeBuffCooldowns
local function ScanBlizzardBuffFrameVisibility()
    wipe(cdmModule.activeBuffCooldowns)
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            if ok and children then
                for _, child in ipairs(children) do
                    if child and child.cooldownID and child:IsShown() then
                        cdmModule.activeBuffCooldowns[child.cooldownID] = true
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
                    if child and child.cooldownID and not child._sqzBuffHooked then
                        child._sqzBuffHooked = true
                        local function OnBuffStateChanged()
                            ScanBlizzardBuffFrameVisibility()
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
                end
            end
        end
    end
end

-- ============================================================================
-- Cooldown Discovery â€” Pure C_CooldownViewer API, no frame interaction.
-- ============================================================================

local function DiscoverCooldowns()
    local discovered = {}
    for _, viewerInfo in ipairs(CDM_VIEWERS) do
        local catIDs = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
            and C_CooldownViewer.GetCooldownViewerCategorySet(viewerInfo.category)
        if catIDs then
            for _, cdID in ipairs(catIDs) do
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if info and info.isKnown then
                    discovered[cdID] = {
                        cooldownID = cdID,
                        spellID = info.spellID,
                        viewerType = viewerInfo.viewerType,
                    }
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

    -- Icon texture
    local iconTex = proxy:CreateTexture(nil, "ARTWORK")
    iconTex:SetAllPoints()
    local texture = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)
    if texture and not BH.Secrets.IsSecret(texture) then
        iconTex:SetTexture(texture)
    end
    iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    proxy.Icon = iconTex

    -- Border (1px edge using BackdropTemplate â€” does NOT cover the icon)
    local borderFrame = CreateFrame("Frame", nil, proxy, "BackdropTemplate")
    borderFrame:SetPoint("TOPLEFT", -1, 1)
    borderFrame:SetPoint("BOTTOMRIGHT", 1, -1)
    borderFrame:SetBackdrop({
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    borderFrame:SetBackdropBorderColor(0, 0, 0, 0.9)
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

    -- Check if this spell has an active buff on the player
    local auraData = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
        and C_UnitAuras.GetPlayerAuraBySpellID(proxy.spellID)

    if auraData and auraData.duration and auraData.duration > 0 and auraData.expirationTime then
        -- Buff is active â€” show buff duration sweep instead of spell cooldown
        local startTime = auraData.expirationTime - auraData.duration
        proxy.Cooldown:SetReverse(true)
        proxy.Cooldown:SetCooldown(startTime, auraData.duration)

        -- Show stack count
        if proxy.Count then
            if auraData.applications and auraData.applications > 1 then
                proxy.Count:SetText(auraData.applications)
            else
                proxy.Count:SetText("")
            end
        end
        return
    end

    -- No active buff â€” show normal spell cooldown
    proxy.Cooldown:SetReverse(false)
    if proxy.Count then
        -- Show spell charges if applicable
        local spellCharges = C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(proxy.spellID)
        if spellCharges and spellCharges.maxCharges > 1 then
            proxy.Count:SetText(spellCharges.currentCharges)
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

-- Apply per-group visual settings to a proxy frame
local function ApplyProxyVisuals(proxy, groupData)
    if not proxy or not groupData then return end

    -- Alpha
    local alpha = groupData.alpha or DEFAULT_ALPHA
    proxy:SetAlpha(alpha)

    -- Border visibility
    local showBorder = groupData.showBorder ~= false
    if proxy.Border then proxy.Border:SetShown(showBorder) end

    -- Cooldown text visibility
    if proxy.Cooldown then
        proxy.Cooldown:SetHideCountdownNumbers(not (groupData.showCooldownText ~= false))
    end

    -- Desaturation: greyscale icon when spell is NOT on cooldown
    if proxy.Icon and proxy.spellID then
        local onCD = false
        local cdInfo = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(proxy.spellID)
        if cdInfo then
            -- cdInfo fields may be secret
            local start = cdInfo.startTime
            local dur = cdInfo.duration
            if start and dur then
                local startOK = not BH.Secrets.IsSecret(start)
                local durOK = not BH.Secrets.IsSecret(dur)
                if startOK and durOK and dur > 1.5 then
                    onCD = true
                end
            end
        end

        -- Check if buff is active via Blizzard CDM frame tracking (CMC-style)
        local hasAura = cdmModule.activeBuffCooldowns[proxy.cooldownID] or false

        local isActive = onCD or hasAura

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

        -- Glow when CD finishes (group setting)
        if justBecameReady and groupData.glowOnReady and ActionButton_ShowOverlayGlow then
            ActionButton_ShowOverlayGlow(proxy.GlowFrame or proxy)
            proxy._glowShowing = true
            C_Timer.After(2, function()
                if proxy._glowShowing then
                    ActionButton_HideOverlayGlow(proxy.GlowFrame or proxy)
                    proxy._glowShowing = false
                end
            end)
        end

        -- Per-cooldown sound alerts (CDM Sounds tab settings)
        local justAuraRemoved = not hasAura and proxy._wasHasAura
        if justBecameReady or justBecameActive or justStartedCD or justAuraRemoved then
            local alerts = GetCDMSoundAlerts()[proxy.cooldownID]
            if alerts then
                for _, alert in ipairs(alerts) do
                    local fire = (alert.when == "available" and justBecameReady)
                              or (alert.when == "active"    and justBecameActive)
                              or (alert.when == "start"     and justStartedCD)
                              or (alert.when == "applied"   and justBecameActive)
                              or (alert.when == "removed"   and justAuraRemoved)
                    if fire and alert.type == "Sound" and alert.sound
                       and alert.sound ~= "None" and BH.PlaySound
                       and not BH.suppressBuffSounds then
                        BH:PlaySound(alert.sound)
                    end
                end
            end
        end

        proxy._wasOnCD    = isActive
        proxy._wasHasAura = hasAura
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
    for cdID, alerts in pairs(soundAlerts) do
        repeat
            if not alerts or #alerts == 0 then break end
            -- Skip if in a named group — ApplyProxyVisuals handles it there
            local assignment = specData and specData.assignments[cdID]
            if assignment and assignment ~= "FREE" then break end
            -- Initialise a minimal tracker on first encounter
            if not cdmModule.soundTrackers[cdID] then
                local info = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
                           and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if not (info and info.spellID) then break end
                cdmModule.soundTrackers[cdID] = { spellID = info.spellID }
            end
            local tracker = cdmModule.soundTrackers[cdID]
            -- Current cooldown state
            local onCD = false
            local cdInfo = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(tracker.spellID)
            if cdInfo then
                local start, dur = cdInfo.startTime, cdInfo.duration
                if start and dur then
                    local ok = not (BH.Secrets.HasAnySecret(start, dur))
                    if ok and dur > 1.5 then onCD = true end
                end
            end
            local hasAura  = cdmModule.activeBuffCooldowns[cdID] or false
            local isActive = onCD or hasAura
            -- Transitions
            local justBecameReady  = not isActive and tracker._wasOnCD
            local justBecameActive = hasAura and not tracker._wasHasAura
            local justStartedCD    = isActive and not tracker._wasOnCD
            local justAuraRemoved  = not hasAura and tracker._wasHasAura
            if (justBecameReady or justBecameActive or justStartedCD or justAuraRemoved) and BH.PlaySound then
                for _, alert in ipairs(alerts) do
                    local fire = (alert.when == "available" and justBecameReady)
                              or (alert.when == "active"    and justBecameActive)
                              or (alert.when == "start"     and justStartedCD)
                              or (alert.when == "applied"   and justBecameActive)
                              or (alert.when == "removed"   and justAuraRemoved)
                    if fire and alert.type == "Sound" and alert.sound
                       and alert.sound ~= "None"
                       and not BH.suppressBuffSounds then
                        BH:PlaySound(alert.sound)
                    end
                end
            end
            tracker._wasOnCD    = isActive
            tracker._wasHasAura = hasAura
        until true
    end
end

UpdateAllProxyCooldowns = function()
    for _, proxy in pairs(cdmModule.proxyFrames) do
        UpdateProxyCooldown(proxy)
    end
    -- Also update visuals (desaturation state changes with cooldown)
    local specData = GetSpecData()
    if not specData then return end
    for cdID, proxy in pairs(cdmModule.proxyFrames) do
        local assignment = specData.assignments[cdID]
        if assignment and assignment ~= "FREE" then
            local groupData = specData.groups[assignment]
            if groupData then
                ApplyProxyVisuals(proxy, groupData)
            end
        end
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

local function CreateGroupContainer(groupName, position, iconSize)
    local container = CreateFrame("Frame", "SQZ_CDMGroup_" .. groupName, UIParent)
    container:SetSize(DEFAULT_ICON_SIZE, DEFAULT_ICON_SIZE) -- Will be resized on layout
    container:SetPoint("CENTER", UIParent, "CENTER", position.x or 0, position.y or 0)
    container:SetFrameStrata("MEDIUM")
    container:SetMovable(true)
    container:SetClampedToScreen(true)
    container:EnableMouse(true)
    container:RegisterForDrag("LeftButton")

    container:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then return end
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

-- ============================================================================
-- Group Layout â€” Position icons within a group container
-- ============================================================================

function cdmModule:LayoutGroup(groupName)
    local group = self.groups[groupName]
    if not group or not group.container then return end

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
                -- Centered horizontally, grow rows up or down
                local rowDir = centeredUp and 1 or -1
                local itemsInRow = math.min(#members - row * perRow, perRow)
                local rowW = itemsInRow * iconSize + (itemsInRow - 1) * spacing
                if orientation == "vertical" then
                    local itemsInCol = math.min(#members - row * perRow, perRow)
                    local colH2 = itemsInCol * iconSize + (itemsInCol - 1) * spacing
                    xOff = row * (iconSize + spacing) * rowDir
                    yOff = -colH2 / 2 + col * (iconSize + spacing) + iconSize / 2
                    local anchor = centeredUp and "BOTTOMLEFT" or "TOPLEFT"
                    proxy:SetPoint("CENTER", group.container, anchor, xOff + iconSize / 2, yOff * -1)
                else
                    xOff = -rowW / 2 + col * (iconSize + spacing) + iconSize / 2
                    yOff = row * (iconSize + spacing) * rowDir
                    local anchor = centeredUp and "BOTTOMLEFT" or "TOPLEFT"
                    proxy:SetPoint("CENTER", group.container, anchor, xOff, yOff)
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

    -- Resize container to fit all icons
    if not InCombatLockdown() then
        group.container:SetSize(fullW, fullH)
    else
        table.insert(self.pendingMutations, function()
            if group.container then
                group.container:SetSize(fullW, fullH)
            end
        end)
    end

    -- Combat visibility
    if groupData.hideOutOfCombat and not isInCombat then
        group.container:SetAlpha(0)
    else
        group.container:SetAlpha(1)
    end
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
        else
            self.registry[cdID] = {
                spellID = cdData.spellID,
                cooldownID = cdID,
                viewerType = cdData.viewerType,
                managed = false,
            }
        end

        local entry = self.registry[cdID]

        -- Check assignment
        local assignment = specData.assignments[cdID]
        if assignment and entry.spellID then
            entry.managed = true

            if assignment == "FREE" then
                local proxy = GetOrCreateProxy(cdID, entry.spellID, DEFAULT_ICON_SIZE)
                self.freeIcons[cdID] = proxy
                self:PositionFreeIcon(cdID)
            else
                -- Assign to group
                local group = self.groups[assignment]
                if group then
                    local groupData = specData.groups[assignment]
                    local iconSize = groupData and groupData.iconSize or DEFAULT_ICON_SIZE
                    local proxy = GetOrCreateProxy(cdID, entry.spellID, iconSize)
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

    -- Layout all groups
    for groupName, _ in pairs(self.groups) do
        self:LayoutGroup(groupName)
    end

    -- Hook Blizzard buff frames and scan active state (CMC-style)
    HookBlizzardBuffFrames()
    ScanBlizzardBuffFrameVisibility()

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
end

-- ============================================================================
-- Group Management API â€” Used by settings UI
-- ============================================================================

function cdmModule:CreateGroup(groupName)
    local specData = GetSpecData()
    if not specData then return end
    if specData.groups[groupName] then return end -- Already exists

    specData.groups[groupName] = {
        cooldownIDs = {},
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
    }

    self:ScheduleReconcile()
end

function cdmModule:DeleteGroup(groupName)
    local specData = GetSpecData()
    if not specData then return end

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

eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("UNIT_AURA")

-- Update combat visibility for all groups
local function UpdateCombatVisibility()
    local specData = GetSpecData()
    if not specData then return end
    for groupName, group in pairs(cdmModule.groups) do
        if group.container then
            local groupData = specData.groups[groupName]
            if groupData and groupData.hideOutOfCombat and not isInCombat then
                group.container:SetAlpha(0)
            else
                group.container:SetAlpha(1)
            end
        end
    end
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "SPELL_UPDATE_COOLDOWN" then
        -- Update proxy cooldown sweeps immediately
        UpdateAllProxyCooldowns()
    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then
            ScanBlizzardBuffFrameVisibility()
            HookBlizzardBuffFrames()
            UpdateAllProxyCooldowns()
        end
    elseif event == "SPELLS_CHANGED" then
        cdmModule:ScheduleReconcile(RECONCILE_DEBOUNCE)
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Spec changed â€” release all, reload for new spec
        cdmModule:ReleaseAll()
        cdmModule:ScheduleReconcile(SPEC_CHANGE_DEBOUNCE)
    elseif event == "PLAYER_REGEN_DISABLED" then
        isInCombat = true
        UpdateCombatVisibility()
    elseif event == "PLAYER_REGEN_ENABLED" then
        isInCombat = false
        UpdateCombatVisibility()
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
        end
    end
end

function cdmModule:HidePreview()
    for groupName, group in pairs(self.groups) do
        if group.previewOverlay then
            group.previewOverlay:Hide()
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

local ACCENT_R, ACCENT_G, ACCENT_B = 0.87, 0.73, 0.37
local TEXT_R, TEXT_G, TEXT_B = 0.90, 0.90, 0.90
local DIM_R, DIM_G, DIM_B = 0.55, 0.55, 0.58

-- Reference to the currently displayed group editor (for refresh)
local cdmTabState = {}

function BH:BuildCDMTab(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    cdmTabState.content = content
    cdmTabState.scrollFrame = scrollFrame
    cdmTabState.parent = parent

    self:RebuildCDMTabContent()
end

function BH:RebuildCDMTabContent()
    local content = cdmTabState.content
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
    header:SetText("COOLDOWN MANAGER")
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
    enableCB:SetChecked(BH.settings and BH.settings.cdmEnabled)
    yOffset = yOffset - 28

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    desc:SetWidth(380)
    desc:SetJustifyH("LEFT")
    desc:SetText("Reparent Blizzard's Cooldown Manager icons into custom groups or position them freely. Requires the Cooldown Manager to be enabled in Edit Mode.")
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
    local groupHeader = content:CreateFontString(nil, "OVERLAY")
    groupHeader:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    groupHeader:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
    groupHeader:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    groupHeader:SetText("GROUPS")
    yOffset = yOffset - 22

    -- New Group input row
    local inputBG = CreateFrame("Frame", nil, content, "BackdropTemplate")
    inputBG:SetSize(220, 24)
    inputBG:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    inputBG:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    inputBG:SetBackdropColor(0.14, 0.14, 0.17, 1)
    inputBG:SetBackdropBorderColor(0.25, 0.25, 0.30, 1)

    local inputBox = CreateFrame("EditBox", nil, inputBG)
    inputBox:SetPoint("TOPLEFT", 6, -4)
    inputBox:SetPoint("BOTTOMRIGHT", -6, 4)
    inputBox:SetFontObject(GameFontNormal)
    inputBox:SetTextColor(TEXT_R, TEXT_G, TEXT_B)
    inputBox:SetAutoFocus(false)
    inputBox:SetMaxLetters(20)

    -- Placeholder text
    local placeholder = inputBG:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    placeholder:SetPoint("LEFT", inputBox, "LEFT", 0, 0)
    placeholder:SetText("Group name...")
    placeholder:SetTextColor(DIM_R, DIM_G, DIM_B, 0.6)

    inputBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then
            placeholder:Hide()
        else
            placeholder:Show()
        end
    end)
    inputBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local addBtn = CreateSQButton(content, "Create", 80, 24)
    addBtn:SetPoint("LEFT", inputBG, "RIGHT", 6, 0)
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

    -- ===== LIST EXISTING GROUPS =====
    local specData = GetSpecData()
    if specData then
        for groupName, groupData in pairs(specData.groups) do
            yOffset = self:BuildGroupSection(content, leftPad, yOffset, groupName, groupData, specData)
        end
    end

    -- ===== DIVIDER =====
    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- ===== UNASSIGNED COOLDOWNS =====
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

    -- Delete button
    local delBtn = CreateSQButton(groupRow, "Delete", 60, 20, {0.75, 0.25, 0.25, 1})
    delBtn:SetPoint("RIGHT", groupRow, "RIGHT", 0, 0)
    delBtn:SetScript("OnClick", function()
        BH.cdm:DeleteGroup(groupName)
        C_Timer.After(0.1, function() BH:RebuildCDMTabContent() end)
    end)

    yOffset = yOffset - 28

    -- ===== ROW 1: Icon Size + Spacing =====
    local sizeSlider = CreateSQSlider(content, "Icon Size", 170, 20, 80, 2)
    sizeSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    sizeSlider:SetValue(groupData.iconSize or DEFAULT_ICON_SIZE)
    sizeSlider:SetAfterValueChanged(function(value)
        groupData.iconSize = value
        BH.cdm:ScheduleReconcile()
    end)

    local spacingSlider = CreateSQSlider(content, "Spacing", 170, 0, 20, 1)
    spacingSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    spacingSlider:SetValue(groupData.spacing or DEFAULT_SPACING)
    spacingSlider:SetAfterValueChanged(function(value)
        groupData.spacing = value
        BH.cdm:ScheduleReconcile()
    end)
    yOffset = yOffset - 50

    -- ===== ROW 2: Per Row + Alpha =====
    local rowSlider = CreateSQSlider(content, "Per Row", 170, 1, 20, 1)
    rowSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    rowSlider:SetValue(groupData.perRow or DEFAULT_PER_ROW)
    rowSlider:SetAfterValueChanged(function(value)
        groupData.perRow = value
        BH.cdm:ScheduleReconcile()
    end)

    local alphaSlider = CreateSQSlider(content, "Opacity", 170, 10, 100, 5)
    alphaSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
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
    lockCB:SetChecked(groupData.locked)

    local tooltipCB = CreateSQCheckbox(content, "Show Tooltip", function(checked)
        groupData.showTooltip = checked
        BH.cdm:ScheduleReconcile()
    end)
    tooltipCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    tooltipCB:SetChecked(groupData.showTooltip ~= false)
    yOffset = yOffset - 24

    local borderCB = CreateSQCheckbox(content, "Show Border", function(checked)
        groupData.showBorder = checked
        BH.cdm:ScheduleReconcile()
    end)
    borderCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    borderCB:SetChecked(groupData.showBorder ~= false)

    local cdTextCB = CreateSQCheckbox(content, "Cooldown Text", function(checked)
        groupData.showCooldownText = checked
        BH.cdm:ScheduleReconcile()
    end)
    cdTextCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    cdTextCB:SetChecked(groupData.showCooldownText ~= false)
    yOffset = yOffset - 24

    local desatCB = CreateSQCheckbox(content, "Desaturate When Ready", function(checked)
        groupData.desaturateReady = checked
        BH.cdm:ScheduleReconcile()
    end)
    desatCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    desatCB:SetChecked(groupData.desaturateReady)

    local glowCB = CreateSQCheckbox(content, "Glow On Ready", function(checked)
        groupData.glowOnReady = checked
        BH.cdm:ScheduleReconcile()
    end)
    glowCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    glowCB:SetChecked(groupData.glowOnReady)
    yOffset = yOffset - 24

    local combatCB = CreateSQCheckbox(content, "Hide Out of Combat", function(checked)
        groupData.hideOutOfCombat = checked
        BH.cdm:ScheduleReconcile()
    end)
    combatCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    combatCB:SetChecked(groupData.hideOutOfCombat)

    local activeOnlyCB = CreateSQCheckbox(content, "Hide Until Active", function(checked)
        groupData.hideUntilActive = checked
        BH.cdm:ScheduleReconcile()
    end)
    activeOnlyCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    activeOnlyCB:SetChecked(groupData.hideUntilActive)
    yOffset = yOffset - 28

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
-- Type / When / Sound Alert dropdowns + Add Alert button on the right.
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
    active    = "Active",
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
    leftPanel:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    leftPanel:SetWidth(180)

    local leftHdr = leftPanel:CreateFontString(nil, "OVERLAY")
    leftHdr:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    leftHdr:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
    leftHdr:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 8, -10)
    leftHdr:SetText("COOLDOWNS")

    local leftScroll = CreateFrame("ScrollFrame", nil, leftPanel, "UIPanelScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT",     leftHdr,   "BOTTOMLEFT", 0,   -6)
    leftScroll:SetPoint("BOTTOMRIGHT", leftPanel,  "BOTTOMRIGHT", -22, 4)

    local leftContent = CreateFrame("Frame", nil, leftScroll)
    leftContent:SetWidth(150)
    leftScroll:SetScrollChild(leftContent)
    cdmSoundsState.leftContent = leftContent

    -- ── Vertical divider ──────────────────────────────────────────────────
    local divider = parent:CreateTexture(nil, "ARTWORK")
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT",    parent, "TOPLEFT",    182, -4)
    divider:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 182,  4)
    divider:SetColorTexture(0.25, 0.25, 0.30, 0.8)

    -- ── Right panel (alert editor) ────────────────────────────────────────
    local rightPanel = CreateFrame("Frame", nil, parent)
    rightPanel:SetPoint("TOPLEFT",     parent, "TOPLEFT",     186, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT",  -1, 0)

    local rightScroll = CreateFrame("ScrollFrame", nil, rightPanel, "UIPanelScrollFrameTemplate")
    rightScroll:SetPoint("TOPLEFT",     rightPanel, "TOPLEFT",     0,   0)
    rightScroll:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -22, 4)

    local rightContent = CreateFrame("Frame", nil, rightScroll)
    rightContent:SetWidth(240)
    rightScroll:SetScrollChild(rightContent)
    cdmSoundsState.rightContent = rightContent

    self:PopulateCDMSoundsLeft()
    self:RebuildCDMSoundsRight()
end

function BH:PopulateCDMSoundsLeft()
    local content = cdmSoundsState.leftContent
    if not content then return end

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
    local byCat = { cooldown = {}, utility = {}, buff = {} }
    for _, cdInfo in pairs(cooldowns) do
        local cat = cdInfo.viewerType or "cooldown"
        if byCat[cat] then
            table.insert(byCat[cat], cdInfo)
        end
    end
    for _, buffInfo in pairs(buffCooldowns) do
        table.insert(byCat.buff, buffInfo)
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
            lbl:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
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
                end

                -- Hover highlight
                local hl = btn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(1, 1, 1, 0.25)

                -- Selection border (accent-coloured overlay)
                local sel = btn:CreateTexture(nil, "OVERLAY")
                sel:SetPoint("TOPLEFT",     -1,  1)
                sel:SetPoint("BOTTOMRIGHT",  1, -1)
                sel:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.75)
                sel:SetDrawLayer("OVERLAY", 1)
                if cdmSoundsState.selectedCooldownID == cdInfo.cooldownID then
                    sel:Show()
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
    subLabel:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)

    yOff = yOff - 44

    -- ── Divider ───────────────────────────────────────────────────────────
    local div1 = content:CreateTexture(nil, "ARTWORK")
    div1:SetHeight(1)
    div1:SetPoint("TOPLEFT",  content, "TOPLEFT",  lp,  yOff)
    div1:SetPoint("TOPRIGHT", content, "TOPRIGHT", -lp, yOff)
    div1:SetColorTexture(0.3, 0.3, 0.35, 0.8)
    yOff = yOff - 10

    -- ── Type ──────────────────────────────────────────────────────────────
    local typeLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    typeLbl:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
    typeLbl:SetText("Type")
    typeLbl:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
    yOff = yOff - 2

    local typeDD = CreateSQDropdown(content, "", 200, {
        { text = "Sound", value = "Sound" },
    }, function(val)
        cdmSoundsState.newAlertType = val
    end)
    typeDD:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff - 4)
    typeDD:SetSelectedValue(cdmSoundsState.newAlertType or "Sound")
    yOff = yOff - 34

    -- ── When ──────────────────────────────────────────────────────────────
    local whenLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    whenLbl:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
    whenLbl:SetText("When")
    whenLbl:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
    yOff = yOff - 2

    local isBuff = cdInfo.viewerType == "buff"
    local whenItems
    if isBuff then
        whenItems = {
            { text = "On Aura Applied", value = "applied" },
            { text = "On Aura Removed", value = "removed" },
        }
    else
        whenItems = {
            { text = "Available",   value = "available" },
            { text = "Active",      value = "active"    },
            { text = "On Cooldown", value = "start"     },
        }
    end
    local buffWhens = { applied = true, removed = true }
    local cdWhens   = { available = true, active = true, start = true }
    local defaultWhen
    if isBuff then
        defaultWhen = buffWhens[cdmSoundsState.newAlertWhen] and cdmSoundsState.newAlertWhen or "applied"
    else
        defaultWhen = cdWhens[cdmSoundsState.newAlertWhen] and cdmSoundsState.newAlertWhen or "available"
    end
    local whenDD = CreateSQDropdown(content, "", 200, whenItems, function(val)
        cdmSoundsState.newAlertWhen = val
    end)
    whenDD:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff - 4)
    whenDD:SetSelectedValue(defaultWhen)
    cdmSoundsState.newAlertWhen = defaultWhen
    yOff = yOff - 34

    -- ── Sound Alert ───────────────────────────────────────────────────────
    local soundLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    soundLbl:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
    soundLbl:SetText("Sound Alert")
    soundLbl:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
    yOff = yOff - 2

    local soundDD = CreateSQDropdown(content, "", 200, BH:BuildSoundDropdownItems(), function(val)
        cdmSoundsState.newAlertSound = val
    end)
    soundDD:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff - 4)
    soundDD:SetSelectedValue(cdmSoundsState.newAlertSound or "None")
    yOff = yOff - 34

    -- ── Add Alert button (red, like Blizzard's) ───────────────────────────
    local addBtn = CreateSQButton(content, "Add Alert", 110, 24, { 0.55, 0.15, 0.15, 1 })
    addBtn:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
    addBtn:SetScript("OnClick", function()
        local alertType  = cdmSoundsState.newAlertType  or "Sound"
        local alertWhen  = cdmSoundsState.newAlertWhen  or "available"
        local alertSound = cdmSoundsState.newAlertSound or "None"
        if not alertSound or alertSound == "None" then return end

        local soundAlerts = GetCDMSoundAlerts()
        if not soundAlerts[cdID] then soundAlerts[cdID] = {} end
        table.insert(soundAlerts[cdID], {
            type  = alertType,
            when  = alertWhen,
            sound = alertSound,
        })
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
    local alerts = soundAlerts[cdID] or {}

    if #alerts == 0 then
        local noAlertsTxt = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        noAlertsTxt:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
        noAlertsTxt:SetText("No alerts added yet.")
        noAlertsTxt:SetTextColor(DIM_R, DIM_G, DIM_B)
        yOff = yOff - 20
    else
        for idx, alert in ipairs(alerts) do
            local rowBG = CreateFrame("Frame", nil, content, "BackdropTemplate")
            rowBG:SetSize(200, 28)
            rowBG:SetPoint("TOPLEFT", content, "TOPLEFT", lp, yOff)
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
                if sa[cdID] then
                    table.remove(sa[cdID], capturedIdx)
                    if #sa[cdID] == 0 then sa[cdID] = nil end
                end
                BH:RebuildCDMSoundsRight()
            end)

            yOff = yOff - 32
        end
    end

    content:SetHeight(math.abs(yOff) + 20)
end
