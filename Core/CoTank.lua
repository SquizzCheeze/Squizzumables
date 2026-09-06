-- Core/CoTank.lua
-- The other tank's debuffs, in a movable frame.
--
-- WHY THIS IS BUILT THE WAY IT IS
--
-- An addon cannot read another player's auras in combat. They are secret, and
-- as of 12.1 reading one does not return nil, it throws -- which is exactly the
-- wall the Cooldown Manager module documents at length. A co-tank tracker that
-- read aura data would therefore work in the open world and go blank in a raid,
-- which is the only place anyone wants it.
--
-- 12.1 answers this with Blizzard_AuraContainer: a widget where BLIZZARD reads
-- and renders the auras and the addon only configures it. We hand it a unit and
-- a filter, hand it the regions to draw into, and never see an aura ourselves.
-- Nothing is secret to us because nothing reaches us.
--
--     local c = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")
--     c:SetUnit("raid3")
--     c:AddAuraGroup("debuffs", "HARMFUL", { initializeFrame = …, candidateFilters = … })
--     c:SetEnabled(true)
--
-- It is the same bargain as the tracked-buff icons in 1.69 -- give Blizzard the
-- widget, let it drive -- and it survives combat for the same reason.
--
-- FOUR THINGS THAT ARE NOT OBVIOUS AND COST A WRONG DESIGN EACH
--
-- 1. Spell ID filtering is NOT available here. Blizzard's own validator says
--    spell ID matching "is only permitted for helpful buffs on assistable
--    units, and harmful buffs on non-assistable units" -- a co-tank is an
--    assistable unit and we want their harmful auras, which is the one
--    combination excluded. So "show only these five tank busters" cannot be
--    built. What is available is isBossAura, isPriorityAura, dispel type and
--    duration, and isBossAura is the one that separates tank busters from noise.
--
-- 2. Once an aura group is added the container gains
--    ForbiddenAspect.UntrustedLayoutScriptExecution, and our frames can no
--    longer anchor TO it. So every region here anchors to the row frame, never
--    to the container, and the row's height is computed rather than measured.
--
-- 3. Regions handed over must already be descendants of the aura button
--    (RegionUtil.IsDescendantOf is asserted), so they are created inside
--    initializeFrame parented to the button rather than made in advance.
--
-- 4. Blizzard stamps the handed-over regions with secret aspects -- Text and
--    Shown on the stack count. We can create and position them; we cannot read
--    them back. Nothing here should ever try.
--
-- Verified against Gethe/wow-ui-source live, 12.1.0 build 69587
-- (Blizzard_AuraContainer/*). Not derived from any other addon.

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

-- Rows are built once and reused. Three covers a raid running three tanks, and
-- building them up front means nothing has to create a frame mid-combat, where
-- it would be refused.
local MAX_ROWS = 3

local DEFAULT_ICON_SIZE = 32
local DEFAULT_MAX_ICONS = 8
local ROW_GAP = 6
local NAME_H = 14

-- What the container is allowed to show. Spell IDs are not an option here (see
-- the header), so these are the useful axes that remain.
local FILTERS = {
    { text = "Boss debuffs only", value = "boss" },
    { text = "All debuffs",       value = "all" },
    { text = "Dispellable only",  value = "dispel" },
}
BH.COTANK_FILTERS = FILTERS

local function CandidateFiltersFor(mode)
    if mode == "all" then
        return nil
    elseif mode == "dispel" then
        -- No includeDispelTypes list: naming types would mean keeping a list of
        -- them current, and "has any dispel type at all" is what dispellable
        -- means. canApplyAura is the closest honest proxy the API offers.
        return { canApplyAura = true }
    end
    return { isBossAura = true }
end

-- ============================================================================
-- Finding the other tanks
-- ============================================================================

-- UnitGroupRolesAssigned is flagged SecretWhenUnitIdentityRestricted, which
-- sounds fatal for Mythic+ and reads that way at first. It is not: the
-- predicate is defined as secret "when the unit isn't player-controlled or in
-- the party/raid", and a co-tank is in the group by definition. So this answers
-- normally in combat, in keys and in raid.
--
-- The secret probe is still here rather than assumed, because the rule in
-- CLAUDE.md is that the probe comes first and a bare comparison on a secret is
-- a hard error, not a wrong answer.
local function IsTank(unit)
    if not UnitExists(unit) then return false end
    if not UnitIsPlayer(unit) then return false end
    local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
    if BH.Secrets.IsSecret(role) then return false end
    return role == "TANK"
end

local function FindCoTanks()
    local tanks = {}
    if not IsInGroup() then return tanks end

    local n = GetNumGroupMembers() or 0
    if IsInRaid() then
        for i = 1, n do
            local unit = "raid" .. i
            if not UnitIsUnit(unit, "player") and IsTank(unit) then
                tanks[#tanks + 1] = unit
            end
        end
    else
        for i = 1, n - 1 do
            local unit = "party" .. i
            if IsTank(unit) then
                tanks[#tanks + 1] = unit
            end
        end
    end
    return tanks
end

-- ============================================================================
-- Frame
-- ============================================================================

local rows = {}

-- Furnish one aura button. Called by Blizzard, through securecallfunction, with
-- the button it just created.
--
-- Everything made here is parented to the button because the handover asserts
-- it (see note 3 in the header). The regions are then given away: from that
-- point Blizzard sets the texture, the stack count and the cooldown, and this
-- addon must not touch them again.
local function InitializeAuraButton(button)
    local size = (BH.settings and BH.settings.coTankIconSize) or DEFAULT_ICON_SIZE

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    button:SetIcon(icon)

    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cd:SetAllPoints()
    cd:SetDrawSwipe(true)
    cd:SetDrawEdge(false)
    button:SetDurationCooldown(cd)

    -- Stacks. This is the half of the feature that matters for a co-tank: the
    -- number on a stacking tank debuff is the thing being watched for.
    local count = button:CreateFontString(nil, "OVERLAY")
    count:SetFont("Fonts\\FRIZQT__.TTF", math.max(8, size * 0.42), "OUTLINE")
    count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    count:SetJustifyH("RIGHT")
    button:SetApplicationCount(count)
end

-- ============================================================================
-- Preview
--
-- Icons we draw ourselves, shown instead of the real container rather than on
-- top of it. Two reasons it has to work this way:
--
--   * There is no way to ask the container what it is showing. The aura data is
--     secret and so is the stack count, so "is it empty right now" is not a
--     question that can be answered -- which rules out drawing placeholders
--     only when it happens to be empty.
--   * Blizzard's own placeholder source exists (AuraContainerAuraSourceLists
--     .EditMode, used by Edit Mode to show sample auras) but SetUseEditModeSource
--     lives on the PRIVATE mixin, not the inbound one an addon can call. So the
--     real widget cannot be asked to show samples.
--
-- So preview disables the containers and shows this instead. It is a layout
-- preview -- size, spacing, how many, where the names sit -- which is what is
-- actually needed to position the thing.
-- ============================================================================

-- Long-standing icon art, picked for looking like tank debuffs rather than for
-- meaning anything. A colour block sits behind each so a missing file shows a
-- sized square instead of nothing.
local PREVIEW_ICONS = {
    "Interface\\Icons\\Ability_Warrior_Sunder",
    "Interface\\Icons\\Spell_Shadow_ShadowWordPain",
    "Interface\\Icons\\Spell_Fire_Immolation",
    "Interface\\Icons\\Ability_Creature_Poison_06",
    "Interface\\Icons\\Ability_Warrior_BloodBath",
    "Interface\\Icons\\Spell_Shadow_AbominationExplosion",
    "Interface\\Icons\\Ability_Rogue_Bloodsplatter",
    "Interface\\Icons\\Spell_Nature_CorrosiveBreath",
}

local function UpdatePreviewRow(row, size, count)
    row.previewIcons = row.previewIcons or {}

    for i = 1, count do
        local pi = row.previewIcons[i]
        if not pi then
            pi = CreateFrame("Frame", nil, row)

            local bg = pi:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.15, 0.15, 0.18, 1)

            local tex = pi:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            tex:SetTexture(PREVIEW_ICONS[((i - 1) % #PREVIEW_ICONS) + 1])
            pi.tex = tex

            local cnt = pi:CreateFontString(nil, "OVERLAY")
            cnt:SetPoint("BOTTOMRIGHT", pi, "BOTTOMRIGHT", -1, 1)
            cnt:SetJustifyH("RIGHT")
            pi.count = cnt

            row.previewIcons[i] = pi
        end

        pi:SetSize(size, size)
        pi:ClearAllPoints()
        pi:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * (size + 2), -NAME_H)
        pi.count:SetFont("Fonts\\FRIZQT__.TTF", math.max(8, size * 0.42), "OUTLINE")
        -- Varying numbers rather than all the same: the stack count is the
        -- point of this feature, so the preview should show it doing something.
        pi.count:SetText(tostring(((i - 1) % 9) + 1))
        pi:Show()
    end

    for i = count + 1, #row.previewIcons do
        row.previewIcons[i]:Hide()
    end
end

local function HidePreviewRow(row)
    for _, pi in ipairs(row.previewIcons or {}) do pi:Hide() end
end

local function BuildRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(200, DEFAULT_ICON_SIZE + NAME_H)

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    name:SetJustifyH("LEFT")
    row.name = name

    -- The container is a sibling of the label, both anchored to the row.
    -- Anchoring the label to the container would work right up until the first
    -- aura group is added, at which point the container refuses untrusted
    -- layout and the label would silently stop moving.
    local ok, container = pcall(CreateFrame, "AuraContainer", nil, row,
                                "CustomAuraContainerTemplate")
    if not ok or not container then
        -- Degrade to nothing rather than erroring at login. If the widget type
        -- is ever withdrawn this is the line that says so.
        BH.coTankUnavailable = true
        return row
    end

    container:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -NAME_H)
    row.container = container
    row.index = index
    return row
end

--- Apply the aura group to a row's container. Done once per row, because
--- AddAuraGroup asserts if the key already exists and there is no remove.
local function EnsureAuraGroup(row)
    if not row.container or row.groupAdded then return end

    local s = BH.settings or {}
    local size = s.coTankIconSize or DEFAULT_ICON_SIZE

    local ok, err = pcall(function()
        row.container:AddAuraGroup("debuffs", "HARMFUL", {
            initializeFrame  = InitializeAuraButton,
            candidateFilters = CandidateFiltersFor(s.coTankFilter or "boss"),
            sortMethod       = AuraContainerSortMethod.Expiration,
            sortDirection    = AuraContainerSortDirection.Normal,
            maxFrameCount    = s.coTankMaxIcons or DEFAULT_MAX_ICONS,
            layout = {
                elementWidth   = size,
                elementHeight  = size,
                elementSpacing = 2,
                lineSpacing    = 2,
            },
        })
    end)

    if not ok then
        BH.coTankError = tostring(err)
        return
    end
    row.groupAdded = true
end

function BH:BuildCoTankFrame()
    if self.coTankFrame then return self.coTankFrame end

    local f = CreateFrame("Frame", "SquizzumablesCoTank", UIParent)
    f:SetSize(220, (DEFAULT_ICON_SIZE + NAME_H + ROW_GAP) * MAX_ROWS)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self2)
        if InCombatLockdown() then return end
        self2:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self2)
        self2:StopMovingOrSizing()
        BH:SaveCoTankPosition()
    end)
    f:Hide()

    for i = 1, MAX_ROWS do
        local row = BuildRow(f, i)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 0,
                     -((i - 1) * (DEFAULT_ICON_SIZE + NAME_H + ROW_GAP)))
        row:Hide()
        rows[i] = row
    end

    self.coTankFrame = f
    return f
end

-- ============================================================================
-- Refresh
-- ============================================================================

local function ShouldShow()
    local s = BH.settings
    if not s or not s.coTankEnabled then return false end
    if BH.unlockMode then return true end
    return true
end

function BH:UpdateCoTank()
    local f = self.coTankFrame
    if not f then return end

    -- Mouse only while positioning, re-asserted here for the same reason the
    -- target distance readout does it: the pass that leaves unlock mode only
    -- restores mouse state for BH.REMINDERS frames, and this is not one.
    f:EnableMouse(BH.unlockMode and true or false)

    if not ShouldShow() then
        f:Hide()
        return
    end

    local s = self.settings or {}
    local showName = s.coTankShowName ~= false
    local size = s.coTankIconSize or DEFAULT_ICON_SIZE
    local maxIcons = s.coTankMaxIcons or DEFAULT_MAX_ICONS

    -- Preview replaces the live display rather than sitting alongside it, so
    -- the two can never both be drawn. Unlock mode implies preview: the frame
    -- needs a footprint to drag whether or not a co-tank happens to exist.
    local preview = BH.unlockMode or s.coTankPreview

    if preview then
        -- Two rows, not one: a raid runs two or three tanks and the vertical
        -- stacking is the part that affects where the frame can go.
        local PREVIEW_ROWS = math.min(2, MAX_ROWS)
        for i = 1, MAX_ROWS do
            local row = rows[i]
            if row then
                if row.container then row.container:SetEnabled(false) end
                if i <= PREVIEW_ROWS then
                    row:Show()
                    row.name:SetText("Co-tank " .. i)
                    row.name:SetShown(showName)
                    UpdatePreviewRow(row, size, maxIcons)
                else
                    HidePreviewRow(row)
                    row:Hide()
                end
            end
        end
        f:Show()
        return
    end

    local tanks = FindCoTanks()

    for i = 1, MAX_ROWS do
        local row = rows[i]
        local unit = tanks[i]
        if row then
            HidePreviewRow(row)
            if unit then
                row:Show()
                if row.container then
                    EnsureAuraGroup(row)
                    row.container:SetUnit(unit)
                    row.container:SetEnabled(true)
                end
                -- Straight through to SetText without resolving.
                --
                -- A FontString takes a secret natively, and resolving it first
                -- would turn a name we are allowed to display into a blank on
                -- exactly the content where this matters. Resolve for logic,
                -- pass through for display.
                row.name:SetText(UnitName(unit))
                row.name:SetShown(showName)
            else
                if row.container then row.container:SetEnabled(false) end
                row:Hide()
            end
        end
    end

    f:SetShown(#tanks > 0)
end

--- Start or stop the module, matching the setting.
function BH:ApplyCoTank()
    local s = self.settings or {}

    if not s.coTankEnabled then
        if self.coTankFrame then
            for i = 1, MAX_ROWS do
                if rows[i] and rows[i].container then rows[i].container:SetEnabled(false) end
            end
            self.coTankFrame:Hide()
        end
        return
    end

    self:BuildCoTankFrame()
    self:LoadCoTankPosition()
    self:UpdateCoTank()
end

-- ============================================================================
-- Events
-- ============================================================================

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_ROLES_ASSIGNED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")

ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(3, function()
            if BH.ApplyCoTank then BH:ApplyCoTank() end
        end)
        return
    end
    if BH.UpdateCoTank then BH:UpdateCoTank() end
end)

-- Unlisted diagnostic: who was found, and whether the container came up at all.
function BH:PrintCoTankDiagnostics()
    print("Squizzumables co-tank tracker:")
    print("  enabled:", tostring(BH.settings and BH.settings.coTankEnabled))
    if BH.coTankUnavailable then
        print("  |cffff6666AuraContainer could not be created on this client.|r")
    end
    if BH.coTankError then
        print("  last AddAuraGroup error:", BH.coTankError)
    end
    local tanks = FindCoTanks()
    print(string.format("  co-tanks found: %d", #tanks))
    for _, unit in ipairs(tanks) do
        -- SafeString for the print, unlike the display above: this is going
        -- through string.format, which would throw on a secret.
        print(string.format("      %s (%s)", unit,
            BH.Secrets.SafeString(UnitName(unit), "<name hidden>")))
    end
    for i = 1, MAX_ROWS do
        local row = rows[i]
        if row then
            print(string.format("      row %d: container=%s group=%s",
                i, tostring(row.container ~= nil), tostring(row.groupAdded == true)))
        end
    end
end
