-- Core/CoTank.lua
-- The other tank's debuffs and defensives, in a movable frame.
--
-- WHY THIS IS BUILT THE WAY IT IS
--
-- An addon cannot read another player's auras in combat. They are secret, and
-- as of 12.1 reading one does not return nil, it throws -- which is exactly the
-- wall the Cooldown Manager module documents at length. A co-tank tracker that
-- read aura data would work in the open world and go blank in a raid, which is
-- the only place anyone wants it.
--
-- 12.1 answers this with Blizzard_AuraContainer: a widget where BLIZZARD reads
-- and renders the auras and the addon only configures it. We hand it a unit, a
-- filter and the regions to draw into, and never see an aura ourselves. Nothing
-- is secret to us because nothing reaches us.
--
--     local c = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")
--     c:SetUnit("raid3")
--     c:AddAuraGroup("debuffs", "HARMFUL", { initializeFrame = …, candidateFilters = … })
--     c:SetEnabled(true)
--
-- It is the same bargain as the tracked-buff icons in 1.69 -- give Blizzard the
-- widget, let it drive -- and it survives combat for the same reason.
--
-- THE ASYMMETRY THAT SHAPES THE FILTERS
--
-- Blizzard permits spell ID matching "only for helpful buffs on assistable
-- units, and harmful buffs on non-assistable units". A co-tank is assistable,
-- so:
--
--   * DEBUFFS (harmful, assistable)  -> spell IDs FORBIDDEN. Only the broad
--     flags are available: isBossAura, isBossOrRoleAura, isPriorityAura,
--     canApplyAura, dispel type, maxDuration. So the debuff filter is a set of
--     presets and cannot be a hand-picked list, however much one might want it.
--
--   * DEFENSIVES (helpful, assistable) -> spell IDs PERMITTED. So the
--     defensives list IS a list of spell IDs, and the player writes it. That is
--     better than shipping a table of every tank cooldown per class: it would
--     rot every patch, and the player knows which two or three they care about.
--
-- OTHER THINGS THAT ARE NOT OBVIOUS
--
--   * Adding an aura group gives the container
--     ForbiddenAspect.UntrustedLayoutScriptExecution, so nothing of ours may
--     anchor TO it. Every region anchors to the row frame instead, and the two
--     groups get their own containers so each can be offset independently.
--   * Regions handed over must already be descendants of the aura button
--     (RegionUtil.IsDescendantOf is asserted), so they are built inside
--     initializeFrame rather than in advance.
--   * Blizzard stamps handed-over regions with secret aspects -- Text, Alpha,
--     VertexColor, Shown depending on the element. They can be created, sized
--     and positioned; they can never be read back. Nothing here should try.
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
local NAME_H = 16

local function S()
    return BH.settings or {}
end

-- ============================================================================
-- Filters
-- ============================================================================

-- Debuff presets. Spell IDs are not permitted here (see the header), so these
-- are the axes Blizzard does expose, named for what they mean in play.
local DEBUFF_FILTERS = {
    { text = "Boss debuffs",          value = "boss" },
    { text = "Boss + role debuffs",   value = "bossrole" },
    { text = "Important only",        value = "important" },
    { text = "Dispellable only",      value = "dispel" },
    { text = "Everything",            value = "all" },
}
BH.COTANK_DEBUFF_FILTERS = DEBUFF_FILTERS

local GROWTH = {
    { text = "Down", value = "down" },
    { text = "Up",   value = "up" },
}
BH.COTANK_GROWTH = GROWTH

local BORDER_STYLES = {
    { text = "Off",              value = "off" },
    { text = "Border",           value = "border" },
    { text = "Border + icon",    value = "bordericon" },
    { text = "Corner icon only", value = "icon" },
}
BH.COTANK_BORDER_STYLES = BORDER_STYLES

local function DebuffCandidateFilters()
    local s = S()
    local f = {}

    local mode = s.coTankDebuffFilter or "boss"
    if mode == "boss" then
        f.isBossAura = true
    elseif mode == "bossrole" then
        f.isBossOrRoleAura = true
    elseif mode == "important" then
        f.isPriorityAura = true
    elseif mode == "dispel" then
        f.canApplyAura = true
    end
    -- "all" adds nothing.

    -- Any non-nil maxDuration implicitly hides permanent auras, which is the
    -- documented behaviour and exactly what "hide permanent" wants. The ceiling
    -- is deliberately enormous so it excludes nothing else.
    if s.coTankDebuffHidePermanent ~= false then
        f.maxDuration = 86400
    end

    if next(f) == nil then return nil end
    return f
end

-- Parse the user's defensive spell ID list into the map Blizzard wants.
--
-- includeSpellIDs is a MAP of permitted ids, not an array -- an array would
-- silently match nothing, since the lookup is by key.
local function DefensiveCandidateFilters()
    local raw = S().coTankDefSpellIDs
    if type(raw) ~= "string" or raw:match("^%s*$") then
        -- No list means no whitelist, which for helpful auras on another player
        -- would be every buff they have. Show nothing instead: an unfiltered
        -- buff list is noise, not a defensives tracker.
        return { includeSpellIDs = {} }
    end

    local ids = {}
    for token in raw:gmatch("[%d]+") do
        local id = tonumber(token)
        if id then ids[id] = true end
    end
    return { includeSpellIDs = ids }
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
local function RoleOf(unit)
    local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
    if BH.Secrets.IsSecret(role) then return nil end
    return role
end

local function IsTank(unit)
    if not UnitExists(unit) then return false end
    if not UnitIsPlayer(unit) then return false end
    return RoleOf(unit) == "TANK"
end

local function FindCoTanks()
    local tanks = {}
    if not IsInGroup() then return tanks end

    local s = S()
    if not IsInRaid() and s.coTankShowInParty == false then return tanks end
    if s.coTankOnlyIfTank and RoleOf("player") ~= "TANK" then return tanks end

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
-- Aura buttons
-- ============================================================================

local rows = {}

local DISPEL_STYLE_MAP = {
    border     = "Border",
    bordericon = "BorderWithIcon",
    icon       = "Icon",
}

-- Furnish one aura button. Called by Blizzard, through securecallfunction, with
-- the button it just created.
--
-- `kind` is "debuff" or "def", and selects which block of settings applies --
-- the two groups are configured independently, which is the whole reason they
-- get separate containers.
--
-- Everything is parented to the button because the handover asserts it. From
-- the moment a region is handed over Blizzard owns what it displays; this addon
-- only ever decided its size, position and font.
local function MakeInitializer(kind)
    return function(button)
        local s = S()
        local pre = (kind == "def") and "coTankDef" or "coTankDebuff"
        local size = s[pre .. "Size"] or 32

        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        local zoom = (s.coTankIconZoom or 7) / 100
        icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
        button:SetIcon(icon)

        -- Cooldown swipe. Its own countdown numbers are suppressed because the
        -- duration text below is the one we can size and place.
        if s.coTankShowSwipe ~= false then
            local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
            cd:SetAllPoints()
            cd:SetDrawSwipe(true)
            cd:SetDrawEdge(false)
            cd:SetHideCountdownNumbers(true)
            button:SetDurationCooldown(cd)
        end

        -- Countdown text.
        if s.coTankShowCountdown ~= false then
            local dur = button:CreateFontString(nil, "OVERLAY")
            dur:SetFont(BH:CoTankFontPath(),
                s[pre .. "CountdownSize"] or math.max(8, size * 0.38), "OUTLINE")
            dur:SetPoint("CENTER", button, "CENTER",
                s[pre .. "CountdownX"] or 0, s[pre .. "CountdownY"] or 0)
            local c = s.coTankCountdownColor or {}
            dur:SetTextColor(c.r or 1, c.g or 0.82, c.b or 0)
            button:SetDurationText(dur)
        end

        -- Stacks. This is the half of the feature that matters for a co-tank:
        -- the number on a stacking tank debuff is the thing being watched.
        if s.coTankShowStacks ~= false then
            local cnt = button:CreateFontString(nil, "OVERLAY")
            cnt:SetFont(BH:CoTankFontPath(),
                s[pre .. "StackSize"] or math.max(8, size * 0.42), "OUTLINE")
            cnt:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT",
                s[pre .. "StackX"] or -1, s[pre .. "StackY"] or 1)
            local c = s.coTankStackColor or {}
            cnt:SetTextColor(c.r or 1, c.g or 1, c.b or 1)
            button:SetApplicationCount(cnt)
        end

        -- Border coloured by dispel type. Blizzard owns the colour and the
        -- artwork; the style says which of its looks to use.
        local style = DISPEL_STYLE_MAP[s.coTankBorderStyle or "border"]
        if style then
            local border = button:CreateTexture(nil, "OVERLAY")
            border:SetPoint("TOPLEFT", button, "TOPLEFT", -1, 1)
            border:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, -1)
            button:AddDispelTypeTexture(border, {
                style = style,
                showWhenHarmful = true,
                showWhenHelpful = (kind == "def"),
                -- Without this a debuff with no dispel type -- most tank
                -- busters -- would draw no border at all, which reads as the
                -- setting not working.
                showWithoutDispelType = true,
            })
        end
    end
end

-- ============================================================================
-- Preview
--
-- Icons we draw ourselves, shown INSTEAD of the real container rather than on
-- top of it. Two reasons it has to work this way:
--
--   * There is no way to ask a container what it is showing. The aura data and
--     the stack count are both secret, so "is it empty right now" cannot be
--     answered -- which rules out drawing placeholders only when it is.
--   * Blizzard's own placeholder source exists (AuraContainerAuraSourceLists
--     .EditMode, which Edit Mode uses for sample auras) but SetUseEditModeSource
--     is on the PRIVATE mixin, not the inbound one an addon may call.
--
-- So it is a layout preview: size, spacing, how many, where the text sits.
-- ============================================================================

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

local PREVIEW_DEF_ICONS = {
    "Interface\\Icons\\Ability_Warrior_ShieldWall",
    "Interface\\Icons\\Spell_Holy_ArdentDefender",
    "Interface\\Icons\\Ability_Druid_Barkskin",
    "Interface\\Icons\\Spell_DeathKnight_IceBoundFortitude",
}

local function UpdatePreviewGroup(row, kind, anchorY)
    local s = S()
    local pre = (kind == "def") and "coTankDef" or "coTankDebuff"
    local store = kind .. "Preview"
    row[store] = row[store] or {}
    local list = row[store]

    local size    = s[pre .. "Size"] or 32
    local spacing = s[pre .. "Spacing"] or 2
    local perRow  = s[pre .. "PerRow"] or 8
    local maxRows = s[pre .. "MaxRows"] or 1
    local count   = perRow * maxRows
    local ox      = s[pre .. "OffsetX"] or 0
    local oy      = s[pre .. "OffsetY"] or 0
    local art     = (kind == "def") and PREVIEW_DEF_ICONS or PREVIEW_ICONS

    for i = 1, count do
        local pi = list[i]
        if not pi then
            pi = CreateFrame("Frame", nil, row)
            local bg = pi:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.15, 0.15, 0.18, 1)
            local tex = pi:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            pi.tex = tex
            local cnt = pi:CreateFontString(nil, "OVERLAY")
            pi.count = cnt
            local dur = pi:CreateFontString(nil, "OVERLAY")
            pi.dur = dur
            list[i] = pi
        end

        local zoom = (s.coTankIconZoom or 7) / 100
        pi.tex:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
        pi.tex:SetTexture(art[((i - 1) % #art) + 1])

        local col = (i - 1) % perRow
        local rowIdx = math.floor((i - 1) / perRow)
        pi:SetSize(size, size)
        pi:ClearAllPoints()
        pi:SetPoint("TOPLEFT", row, "TOPLEFT",
            ox + col * (size + spacing),
            -(anchorY) + oy - rowIdx * (size + spacing))

        pi.count:ClearAllPoints()
        pi.count:SetFont(BH:CoTankFontPath(),
            s[pre .. "StackSize"] or math.max(8, size * 0.42), "OUTLINE")
        pi.count:SetPoint("BOTTOMRIGHT", pi, "BOTTOMRIGHT",
            s[pre .. "StackX"] or -1, s[pre .. "StackY"] or 1)
        local sc = s.coTankStackColor or {}
        pi.count:SetTextColor(sc.r or 1, sc.g or 1, sc.b or 1)
        -- Varying numbers, because the stack count is the point of the feature
        -- and a preview of it all reading "1" shows nothing.
        pi.count:SetText(s.coTankShowStacks ~= false and tostring(((i - 1) % 9) + 1) or "")

        pi.dur:ClearAllPoints()
        pi.dur:SetFont(BH:CoTankFontPath(),
            s[pre .. "CountdownSize"] or math.max(8, size * 0.38), "OUTLINE")
        pi.dur:SetPoint("CENTER", pi, "CENTER",
            s[pre .. "CountdownX"] or 0, s[pre .. "CountdownY"] or 0)
        local cc = s.coTankCountdownColor or {}
        pi.dur:SetTextColor(cc.r or 1, cc.g or 0.82, cc.b or 0)
        pi.dur:SetText(s.coTankShowCountdown ~= false and tostring(((i - 1) % 20) + 4) or "")

        pi:Show()
    end

    for i = count + 1, #list do list[i]:Hide() end
end

local function HidePreview(row)
    for _, key in ipairs({ "debuffPreview", "defPreview" }) do
        for _, pi in ipairs(row[key] or {}) do pi:Hide() end
    end
end

-- ============================================================================
-- Frame
-- ============================================================================

--- Font path for every text element here, from LibSharedMedia when it has one.
function BH:CoTankFontPath()
    local name = S().coTankFont
    if name and LibStub then
        local lsm = LibStub("LibSharedMedia-3.0", true)
        local path = lsm and lsm:Fetch("font", name, true)
        if path then return path end
    end
    return "Fonts\\FRIZQT__.TTF"
end

local function MakeContainer(row, kind)
    -- pcall: this is a widget type the client may one day withdraw, and an
    -- error here would land at login with nothing to explain it.
    local ok, c = pcall(CreateFrame, "AuraContainer", nil, row, "CustomAuraContainerTemplate")
    if not ok or not c then
        BH.coTankUnavailable = true
        return nil
    end
    return c
end

local function BuildRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(240, 64)

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    name:SetJustifyH("LEFT")
    row.name = name

    -- Two containers, both anchored to the row and never to each other. They
    -- are separate so each group keeps its own offset, and they cannot be
    -- anchored to one another anyway once an aura group is added.
    row.debuffs = MakeContainer(row, "debuff")
    row.defensives = MakeContainer(row, "def")
    row.index = index
    return row
end

--- Attach a group to a container. Once only: AddAuraGroup asserts on a repeat
--- key and there is no remove, which is why the size and filter settings say
--- they need a reload.
local function EnsureGroup(row, kind)
    local container = (kind == "def") and row.defensives or row.debuffs
    if not container then return end

    local flag = kind .. "GroupAdded"
    if row[flag] then return end

    local s = S()
    local pre = (kind == "def") and "coTankDef" or "coTankDebuff"
    local size = s[pre .. "Size"] or 32

    local ok, err = pcall(function()
        container:AddAuraGroup(kind, (kind == "def") and "HELPFUL" or "HARMFUL", {
            initializeFrame  = MakeInitializer(kind),
            candidateFilters = (kind == "def") and DefensiveCandidateFilters()
                                                or DebuffCandidateFilters(),
            sortMethod       = AuraContainerSortMethod.Expiration,
            sortDirection    = AuraContainerSortDirection.Normal,
            maxFrameCount    = (s[pre .. "PerRow"] or 8) * (s[pre .. "MaxRows"] or 1),
            layout = {
                elementWidth   = size,
                elementHeight  = size,
                elementSpacing = s[pre .. "Spacing"] or 2,
                lineSpacing    = s[pre .. "Spacing"] or 2,
            },
        })
    end)

    if not ok then
        BH.coTankError = tostring(err)
        return
    end
    row[flag] = true
end

function BH:BuildCoTankFrame()
    if self.coTankFrame then return self.coTankFrame end

    local f = CreateFrame("Frame", "SquizzumablesCoTank", UIParent)
    f:SetSize(240, 200)
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
        rows[i] = BuildRow(f, i)
        rows[i]:Hide()
    end

    self.coTankFrame = f
    return f
end

-- How tall one tank's block is, given the current settings. Computed rather
-- than measured, because the containers refuse untrusted layout once a group
-- is attached and so cannot be asked their size.
local function RowHeight()
    local s = S()
    local h = (s.coTankShowName ~= false) and NAME_H or 0

    local dSize = s.coTankDebuffSize or 32
    local dRows = s.coTankDebuffMaxRows or 1
    h = h + dRows * (dSize + (s.coTankDebuffSpacing or 2))

    if s.coTankDefEnabled then
        local fSize = s.coTankDefSize or 24
        local fRows = s.coTankDefMaxRows or 1
        h = h + fRows * (fSize + (s.coTankDefSpacing or 2))
    end
    return math.max(h, 20)
end

local function PositionRows()
    local s = S()
    local f = BH.coTankFrame
    if not f then return end

    local rowH = RowHeight()
    local gap = s.coTankRowSpacing or 6
    local up = (s.coTankGrowth == "up")

    for i = 1, MAX_ROWS do
        local row = rows[i]
        if row then
            row:SetSize(240, rowH)
            row:ClearAllPoints()
            if up then
                row:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, (i - 1) * (rowH + gap))
            else
                row:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -((i - 1) * (rowH + gap)))
            end

            -- Containers sit below the name, each with its own offset.
            local y = (s.coTankShowName ~= false) and NAME_H or 0
            if row.debuffs then
                row.debuffs:ClearAllPoints()
                row.debuffs:SetPoint("TOPLEFT", row, "TOPLEFT",
                    s.coTankDebuffOffsetX or 0, -(y) + (s.coTankDebuffOffsetY or 0))
            end
            if row.defensives then
                local dy = y + (s.coTankDebuffMaxRows or 1)
                    * ((s.coTankDebuffSize or 32) + (s.coTankDebuffSpacing or 2))
                row.defensives:ClearAllPoints()
                row.defensives:SetPoint("TOPLEFT", row, "TOPLEFT",
                    s.coTankDefOffsetX or 0, -(dy) + (s.coTankDefOffsetY or 0))
            end
        end
    end

    f:SetHeight(MAX_ROWS * (rowH + gap))
end

-- ============================================================================
-- Refresh
-- ============================================================================

local lastTankCount = 0

function BH:UpdateCoTank()
    local f = self.coTankFrame
    if not f then return end

    -- Mouse only while positioning, re-asserted here because the pass that
    -- leaves unlock mode only restores mouse state for BH.REMINDERS frames,
    -- and this is not one. A transparent frame that eats clicks is the 1.68
    -- Just For Kel bug.
    f:EnableMouse(BH.unlockMode and true or false)

    local s = S()
    if not s.coTankEnabled then
        f:Hide()
        return
    end

    PositionRows()

    local showName = s.coTankShowName ~= false
    local nameSize = s.coTankNameSize or 12

    -- Preview replaces the live display rather than sitting alongside it, so
    -- the two can never both be drawn. Unlock mode implies preview: the frame
    -- needs a footprint to drag whether or not a co-tank exists.
    local preview = BH.unlockMode or s.coTankPreview

    if preview then
        local previewRows = math.min(2, MAX_ROWS)
        for i = 1, MAX_ROWS do
            local row = rows[i]
            if row then
                if row.debuffs then row.debuffs:SetEnabled(false) end
                if row.defensives then row.defensives:SetEnabled(false) end
                if i <= previewRows then
                    row:Show()
                    row.name:SetFont(BH:CoTankFontPath(), nameSize, "OUTLINE")
                    row.name:SetText("Co-tank " .. i)
                    row.name:SetShown(showName)
                    UpdatePreviewGroup(row, "debuff", showName and NAME_H or 0)
                    if s.coTankDefEnabled then
                        local dy = (showName and NAME_H or 0)
                            + (s.coTankDebuffMaxRows or 1)
                              * ((s.coTankDebuffSize or 32) + (s.coTankDebuffSpacing or 2))
                        UpdatePreviewGroup(row, "def", dy)
                    else
                        for _, pi in ipairs(row.defPreview or {}) do pi:Hide() end
                    end
                else
                    HidePreview(row)
                    row:Hide()
                end
            end
        end
        f:Show()
        return
    end

    local tanks = FindCoTanks()

    -- "Notify when more co-tanks detected": only on the way up, and only once
    -- per change, or it would fire every roster event for the whole fight.
    if s.coTankNotify and #tanks > MAX_ROWS and #tanks ~= lastTankCount then
        print(("|cffffcc00Squizzumables:|r %d co-tanks in the group; showing the first %d.")
            :format(#tanks, MAX_ROWS))
    end
    lastTankCount = #tanks

    for i = 1, MAX_ROWS do
        local row = rows[i]
        local unit = tanks[i]
        if row then
            HidePreview(row)
            if unit then
                row:Show()
                EnsureGroup(row, "debuff")
                if row.debuffs then
                    row.debuffs:SetUnit(unit)
                    row.debuffs:SetEnabled(true)
                end
                if s.coTankDefEnabled then
                    EnsureGroup(row, "def")
                    if row.defensives then
                        row.defensives:SetUnit(unit)
                        row.defensives:SetEnabled(true)
                    end
                elseif row.defensives then
                    row.defensives:SetEnabled(false)
                end
                -- Straight through to SetText without resolving.
                --
                -- A FontString takes a secret natively, and resolving it first
                -- would turn a name we are allowed to display into a blank on
                -- exactly the content where this matters. Resolve for logic,
                -- pass through for display.
                row.name:SetFont(BH:CoTankFontPath(), nameSize, "OUTLINE")
                row.name:SetText(UnitName(unit))
                row.name:SetShown(showName)
            else
                if row.debuffs then row.debuffs:SetEnabled(false) end
                if row.defensives then row.defensives:SetEnabled(false) end
                row:Hide()
            end
        end
    end

    f:SetShown(#tanks > 0)
end

function BH:ApplyCoTank()
    local s = S()

    if not s.coTankEnabled then
        if self.coTankFrame then
            for i = 1, MAX_ROWS do
                local row = rows[i]
                if row then
                    if row.debuffs then row.debuffs:SetEnabled(false) end
                    if row.defensives then row.defensives:SetEnabled(false) end
                end
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

-- ============================================================================
-- Options helpers
-- ============================================================================

--- Say once that a reload is needed, and only when it actually is.
---
--- Anything baked into an aura button or its group needs one: AddAuraGroup
--- asserts on a repeated key and offers no remove, so a group's filter, sizes
--- and the regions on its buttons are fixed once built. Rather than a reload
--- warning on every such control, this throttles to one message -- half a dozen
--- in a row while adjusting sliders reads as something being broken.
---
--- Silent while previewing, because the preview is ours and redraws at once, so
--- there is nothing waiting on a reload to be seen.
local reloadNoticeAt = 0
function BH:CoTankNeedsReload()
    if not (BH.settings and BH.settings.coTankEnabled) then return end
    if BH.unlockMode or BH.settings.coTankPreview then return end
    local now = GetTime()
    if now - reloadNoticeAt < 20 then return end
    reloadNoticeAt = now
    print("|cffffcc00Squizzumables:|r co-tank icon settings changed -- /reload to apply them to "
        .. "the live display. Preview Layout shows them straight away.")
end

--- The block of size/layout/text rows a group needs, built once and reused for
--- both Debuffs and Defensives.
---
--- `prefix` is the settings prefix ("coTankDebuff" or "coTankDef"), so the two
--- groups stay genuinely independent without the options code being written
--- twice and drifting -- which is what happened to the ten hand-copied reminder
--- gates before they became a table.
function BH:AddCoTankGroupRows(content, yOffset, prefix, disabled, maxSize)
    local used = 0
    local Rows = ns.Rows

    local function num(key, default)
        return function() return BH.settings[prefix .. key] or default end
    end
    local function setNum(key, needsReload)
        return function(v)
            BH.settings[prefix .. key] = v
            BH:SaveSettings()
            BH:UpdateCoTank()
            if needsReload then BH:CoTankNeedsReload() end
        end
    end

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Icon Size", width = 300, min = 12, max = maxSize or 64, step = 1,
        tooltip = "Size of each icon in this group.",
        get = num("Size", 32), set = setNum("Size", true), disabled = disabled,
    })

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Icon Spacing", width = 300, min = 0, max = 20, step = 1,
        tooltip = "Gap between icons.",
        get = num("Spacing", 2), set = setNum("Spacing", true), disabled = disabled,
    })

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Icons Per Row", width = 300, min = 1, max = 20, step = 1,
        tooltip = "How many icons before wrapping to the next line.",
        get = num("PerRow", 8), set = setNum("PerRow", true), disabled = disabled,
    })

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Maximum Rows", width = 300, min = 1, max = 5, step = 1,
        tooltip = "How many lines of icons at most. Rows times icons per row is the total shown.",
        get = num("MaxRows", 1), set = setNum("MaxRows", true), disabled = disabled,
    })

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Offset X", width = 300, min = -300, max = 300, step = 1,
        tooltip = "Moves this group left or right within the frame.",
        get = num("OffsetX", 0), set = setNum("OffsetX", false), disabled = disabled,
    })

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Offset Y", width = 300, min = -300, max = 300, step = 1,
        tooltip = "Moves this group up or down within the frame.",
        get = num("OffsetY", 0), set = setNum("OffsetY", false), disabled = disabled,
    })

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Stack Text Size", width = 300, min = 6, max = 30, step = 1,
        tooltip = "Font size of the stack count on these icons.",
        get = num("StackSize", 13), set = setNum("StackSize", true), disabled = disabled,
    })

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Stack Offset X", width = 300, min = -30, max = 30, step = 1,
        tooltip = "Nudges the stack count horizontally within its icon.",
        get = num("StackX", -1), set = setNum("StackX", true), disabled = disabled,
    })

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Stack Offset Y", width = 300, min = -30, max = 30, step = 1,
        tooltip = "Nudges the stack count vertically within its icon.",
        get = num("StackY", 1), set = setNum("StackY", true), disabled = disabled,
    })

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Countdown Text Size", width = 300, min = 6, max = 30, step = 1,
        tooltip = "Font size of the countdown on these icons.",
        get = num("CountdownSize", 12), set = setNum("CountdownSize", true), disabled = disabled,
    })

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Countdown Offset X", width = 300, min = -30, max = 30, step = 1,
        tooltip = "Nudges the countdown horizontally within its icon.",
        get = num("CountdownX", 0), set = setNum("CountdownX", true), disabled = disabled,
    })

    used = used + Rows.Add(content, yOffset - used, {
        type = "slider", label = "Countdown Offset Y", width = 300, min = -30, max = 30, step = 1,
        tooltip = "Nudges the countdown vertically within its icon.",
        get = num("CountdownY", 0), set = setNum("CountdownY", true), disabled = disabled,
    })

    return used
end

-- Unlisted diagnostic.
function BH:PrintCoTankDiagnostics()
    print("Squizzumables co-tank tracker:")
    print("  enabled:", tostring(S().coTankEnabled))
    if BH.coTankUnavailable then
        print("  |cffff6666AuraContainer could not be created on this client.|r")
    end
    if BH.coTankError then
        print("  last AddAuraGroup error:", BH.coTankError)
    end
    print("  my role:", tostring(RoleOf("player")))
    local tanks = FindCoTanks()
    print(string.format("  co-tanks found: %d", #tanks))
    for _, unit in ipairs(tanks) do
        -- SafeString here, unlike the display path: string.format would throw
        -- on a secret.
        print(string.format("      %s (%s)", unit,
            BH.Secrets.SafeString(UnitName(unit), "<name hidden>")))
    end
    for i = 1, MAX_ROWS do
        local row = rows[i]
        if row then
            print(string.format("      row %d: debuffs=%s/%s defensives=%s/%s",
                i, tostring(row.debuffs ~= nil), tostring(row.debuffGroupAdded == true),
                tostring(row.defensives ~= nil), tostring(row.defGroupAdded == true)))
        end
    end
end
