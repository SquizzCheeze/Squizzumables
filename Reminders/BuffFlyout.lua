-- Reminders/BuffFlyout.lua
-- WoW Forever: the pick-who grid for single-target class buffs (Mark of the
-- Wild, Power Word: Fortitude, Arcane Intellect).
--
-- The reminder row shows ONE button for these: left-click buffs the next
-- person missing it (you first, then tanks, healers, everyone else) and its
-- count says how many are missing. Right-click opens this grid above or below
-- it: one tile per person, at most MAX_TILES, the last becoming "+N" when more
-- are missing (it buffs the next of them and its tooltip names the rest).
--
-- Secure-frame rules that shaped it:
--   * the grid opens and closes from a SecureHandlerClickTemplate snippet,
--     reached by a "/click" macro on the main button's right click, so it
--     works in combat; RegisterAutoHide closes it once the mouse leaves
--   * who each tile casts on is a unit attribute, which can only change out of
--     combat -- so in combat the grid is the snapshot from the last refresh
--   * tiles are ordinary pooled reminder buttons (BH.CreateButton), so they
--     look like the rest of the row and go back to the same pool

local addonName, ns = ...
local BH = ns.BH

local BF = {}
BH.BuffFlyout = BF

local MAX_TILES = 8
local COLUMNS = 4
local TOGGLE_NAME = "SquizzumablesBuffFlyoutToggle"

local flyout, toggle
local tiles = {}
local wasOpen = false

local function EnsureFrames()
    if flyout then return end
    flyout = CreateFrame("Frame", "SquizzumablesBuffFlyout", UIParent, "SecureHandlerBaseTemplate")
    flyout:SetFrameStrata("HIGH")
    flyout:Hide()
    local bg = flyout:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)

    -- Never seen or hovered: only ever clicked by the main button's macro.
    toggle = CreateFrame("Button", TOGGLE_NAME, UIParent, "SecureHandlerClickTemplate")
    toggle:SetSize(1, 1)
    toggle:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
    toggle:SetAlpha(0)
    toggle:EnableMouse(false)
    -- Both edges, so the /click lands whatever ActionButtonUseKeyDown says.
    toggle:RegisterForClicks("AnyUp", "AnyDown")
    toggle:SetFrameRef("flyout", flyout)
    toggle:SetAttribute("_onclick", [[
        local f = self:GetFrameRef("flyout")
        if f:IsShown() then
            f:Hide()
        else
            f:Show()
            f:RegisterAutoHide(1)
            local a = self:GetFrameRef("anchor")
            if a then f:AddToAutoHide(a) end
        end
    ]])
end

-- Back to the pool, the same way UpdateButtons releases its own buttons.
-- Called at the start of every rebuild (out of combat only).
function BF.Release(pool)
    if flyout then
        wasOpen = flyout:IsShown()
        flyout:Hide()
    end
    for _, btn in ipairs(tiles) do
        btn:Hide()
        btn:ClearAllPoints()
        btn:SetScript("OnUpdate", nil)
        ns.Glow.Hide(btn.glowHost)
        btn.expirationTime = nil
        btn.isCombatBuff = nil
        btn:SetParent(nil)
        table.insert(pool, btn)
    end
    wipe(tiles)
end

local function ShortName(unit)
    if unit == "player" then return "Me" end
    return UnitName(unit) or unit
end

-- Everyone in the group missing the buff, in buffing order: you, tanks,
-- healers, the rest (group order inside each).
function BF.MissingUnits(checkIDs, unitHasBuff)
    local missing = {}
    if not UnitIsDeadOrGhost("player") and not unitHasBuff("player", checkIDs) then
        missing[1] = "player"
    end
    local others = {}
    local groupSize = GetNumGroupMembers()
    if groupSize > 0 then
        local isRaid = IsInRaid()
        for i = 1, groupSize do
            local unit = isRaid and ("raid" .. i) or ("party" .. i)
            if not UnitIsUnit(unit, "player") and UnitExists(unit)
                and UnitIsPlayer(unit) and UnitIsConnected(unit)
                and not UnitIsDeadOrGhost(unit) and UnitIsVisible(unit)
                and not unitHasBuff(unit, checkIDs) then
                local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
                local rank = (role == "TANK" and 1) or (role == "HEALER" and 2) or 3
                others[#others + 1] = { unit = unit, rank = rank, order = i }
            end
        end
    end
    table.sort(others, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.order < b.order
    end)
    for _, o in ipairs(others) do missing[#missing + 1] = o.unit end
    return missing
end

-- Build the main button's grid. mainBtn is already created and placed in the
-- row by the caller; this wires its right click and lays the tiles out.
function BF.Attach(mainBtn, spellID, icon, missing)
    if InCombatLockdown() or #missing < 2 then return end
    EnsureFrames()

    mainBtn:SetAttribute("type2", "macro")
    mainBtn:SetAttribute("macrotext2", "/click " .. TOGGLE_NAME)
    mainBtn:HookScript("OnEnter", function()
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(#missing .. " missing. Right-click to pick who.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    toggle:SetFrameRef("anchor", mainBtn)

    local shown = math.min(#missing, MAX_TILES)
    local overflow = #missing > MAX_TILES
    for i = 1, shown do
        local unit = missing[i]
        local isOverflow = overflow and i == shown
        local label = isOverflow and ("+" .. (#missing - shown + 1)) or ShortName(unit)
        local tile = BH.CreateButton(0, icon, "Cast on " .. ShortName(unit), "spell", spellID, label, nil, nil)
        tile:SetAttribute("unit", unit)
        tile:SetParent(flyout)
        tile:SetFrameStrata("HIGH")
        if isOverflow then
            local rest = {}
            for j = shown, #missing do rest[#rest + 1] = ShortName(missing[j]) end
            tile:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(#rest .. " more missing")
                GameTooltip:AddLine("Click to buff " .. rest[1] .. ".", 1, 1, 1)
                GameTooltip:AddLine(table.concat(rest, ", "), 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
        end
        tiles[#tiles + 1] = tile
    end

    -- Grid, opening away from the nearer screen edge.
    local cellW = mainBtn:GetWidth() + 4
    local cellH = mainBtn:GetHeight() + 2
    local cols = math.min(COLUMNS, shown)
    local rows = math.ceil(shown / COLUMNS)
    local pad = 4
    flyout:SetParent(mainBtn)
    flyout:SetFrameStrata("HIGH")
    flyout:SetSize(cols * cellW + pad * 2 - 4, rows * cellH + pad * 2 - 2)
    flyout:ClearAllPoints()
    local _, cy = mainBtn:GetCenter()
    local screenH = UIParent:GetHeight() * UIParent:GetEffectiveScale() / mainBtn:GetEffectiveScale()
    local openUp = not cy or cy < screenH / 2
    if openUp then
        flyout:SetPoint("BOTTOM", mainBtn, "TOP", 0, 4)
    else
        flyout:SetPoint("TOP", mainBtn, "BOTTOM", 0, -4)
    end
    for i, tile in ipairs(tiles) do
        local col = (i - 1) % COLUMNS
        local row = math.floor((i - 1) / COLUMNS)
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", flyout, "TOPLEFT", pad + col * cellW, -(pad + row * cellH))
    end

    -- A rebuild while it was open (a buff just landed) keeps it open. Through
    -- the toggle rather than a plain Show, so the auto-hide is registered again.
    if wasOpen then toggle:Click() end
    wasOpen = false
end

-- UpdateButtons holds off rebuilding while a click is under way on a button;
-- the grid's tiles count too.
function BF.IsMouseOver()
    return flyout ~= nil and flyout:IsShown() and flyout:IsMouseOver()
end
