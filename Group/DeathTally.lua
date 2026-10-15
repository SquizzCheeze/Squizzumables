-- Group/DeathTally.lua
-- The M+ Death Tally: a per-player death counter for the current key.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split). Builds
-- its frame while loading, as it always did -- nothing in the core touches
-- that frame before PLAYER_LOGIN. Its links to the core go through BH: the
-- group unit list (BH.GetGroupUnits) one way, and whether a tally is running
-- (BH.DeathTallyActive, at the end of this file) the other.

local addonName, ns = ...
local BH = ns.BH

local SQ_COLORS = ns.SQ_COLORS

-- ============================================================================
-- M+ Death Tally
-- ============================================================================
-- Self-tracked per-player death counter for the current Mythic+ run. Unlike
-- C_ChallengeMode.GetDeathCount() (a single group-wide total with no
-- per-player breakdown), this attributes each death to the group member who
-- died by polling UnitIsDeadOrGhost() per party/raid unit and edge-detecting
-- the false→true transition (see the ticker below) — not an event, since
-- neither UNIT_DIED nor COMBAT_LOG_EVENT_UNFILTERED proved reliable here.
--
-- Lifecycle: starts tracking (and auto-resets) on CHALLENGE_MODE_START, stops
-- tracking on CHALLENGE_MODE_COMPLETED/RESET. Stopping only stops counting
-- new deaths — the frame is left showing the final tally as a summary until
-- the next key start resets it, rather than hiding immediately.
local deathTallyActive = false
local deathTallyData  = {}   -- [GUID] = { name=, realm=, classFile=, count= }
local deathTallyOrder = {}   -- ordered list of GUIDs (party order), for stable row display
-- Set by the frame's close (X) button; hides the summary early once the group
-- is done with M+. Reset on the next CHALLENGE_MODE_START so the frame always
-- reappears for a new key regardless of whether the last one was dismissed.
local deathTallyManuallyClosed = false

BH.deathTallyFrame = CreateFrame("Frame", "SquizzumablesDeathTallyFrame", UIParent)
BH.deathTallyFrame:SetSize(180, 26)
BH.deathTallyFrame:SetPoint("TOP", UIParent, "TOP", 220, -100)
BH.deathTallyFrame:SetMovable(true)
BH.deathTallyFrame:SetClampedToScreen(true)
BH.deathTallyFrame:EnableMouse(true)
BH.deathTallyFrame:SetFrameStrata("MEDIUM")
BH.deathTallyFrame:SetFixedFrameStrata(true)
BH.deathTallyFrame:RegisterForDrag("LeftButton")
BH.deathTallyFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.deathTallyLocked) or BH.unlockMode then
        BH:GridStartMoving(BH.deathTallyFrame)
        BH.deathTallyFrame:SetUserPlaced(false)
    end
end)
BH.deathTallyFrame:SetScript("OnDragStop", function()
    BH:GridStopMoving(BH.deathTallyFrame)
    BH:SaveDeathTallyPosition()
end)
BH.deathTallyFrame:Hide()

-- Close (X) button: dismiss the summary early once done with M+. Always
-- clickable regardless of the lock setting (lock only affects dragging).
BH.deathTallyCloseBtn = CreateFrame("Button", nil, BH.deathTallyFrame)
BH.deathTallyCloseBtn:SetSize(14, 14)
BH.deathTallyCloseBtn:SetPoint("TOPRIGHT", BH.deathTallyFrame, "TOPRIGHT", 2, 2)
local deathTallyCloseText = BH.deathTallyCloseBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
deathTallyCloseText:SetPoint("CENTER")
deathTallyCloseText:SetText("X")
deathTallyCloseText:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
BH.deathTallyCloseBtn:SetScript("OnEnter", function()
    deathTallyCloseText:SetTextColor(SQ_COLORS.danger[1], SQ_COLORS.danger[2], SQ_COLORS.danger[3])
end)
BH.deathTallyCloseBtn:SetScript("OnLeave", function()
    deathTallyCloseText:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
end)
BH.deathTallyCloseBtn:SetScript("OnClick", function()
    deathTallyManuallyClosed = true
    BH.deathTallyFrame:Hide()
end)

-- Poll-based death detection (BigWigs pattern: AnimationGroup ticker instead of
-- OnUpdate). Neither UNIT_DIED nor COMBAT_LOG_EVENT_UNFILTERED are relied on —
-- UNIT_DIED doesn't reliably fire for off-screen party/raid members, and CLEU
-- has been removed from the addon API. Polling UnitIsDeadOrGhost() per group
-- member and edge-detecting the false→true transition needs neither.
do
    local ticker = BH.deathTallyFrame:CreateAnimationGroup()
    ticker:SetLooping("REPEAT")
    BH.deathTallyTicker = ticker
    ticker:SetScript("OnLoop", function()
        BH:PollDeathTally()
    end)
    local anim = ticker:CreateAnimation()
    anim:SetDuration(0.5)
end

BH.deathTallyTitle = BH.deathTallyFrame:CreateFontString(nil, "OVERLAY")
BH.deathTallyTitle:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
BH.deathTallyTitle:SetPoint("TOP", BH.deathTallyFrame, "TOP", 0, 0)
BH.deathTallyTitle:SetText("M+ Death Tally")
BH.deathTallyTitle:SetTextColor(ns.Theme.RGBA("highlight"))

-- Pool of row FontStrings, lazily created/reused as group size changes.
-- Font and position are (re)applied every display update since font size is
-- user-configurable and rows are recycled across different group sizes.
BH.deathTallyRows = {}
local function GetDeathTallyRow(index)
    local row = BH.deathTallyRows[index]
    if not row then
        row = BH.deathTallyFrame:CreateFontString(nil, "OVERLAY")
        BH.deathTallyRows[index] = row
    end
    return row
end

-- Resolve an "aarrggbb" hex color string for a class file token (e.g. "WARRIOR").
-- Falls back to opaque white if unavailable.
local function GetDeathTallyNameColorHex(classFile)
    if classFile and C_ClassColor and C_ClassColor.GetClassColor then
        local color = C_ClassColor.GetClassColor(classFile)
        if color and color.GenerateHexColor then
            return color:GenerateHexColor()
        end
    end
    return "ffffffff"
end

-- Builds the "Name" or "Name-Realm" display string per the hide-realm setting.
local function FormatDeathTallyName(entry)
    if entry.realm and entry.realm ~= "" and not (BH.settings and BH.settings.deathTallyHideRealm) then
        return entry.name .. "-" .. entry.realm
    end
    return entry.name
end

-- Draws one row (name colored by class if enabled, count colored red if > 0)
-- and anchors it below the previous row (or the title for the first row).
local function DrawDeathTallyRow(index, rowFontSize, classColorEnabled, prevAnchor, displayName, classFile, count)
    local row = GetDeathTallyRow(index)
    row:SetFont("Fonts\\FRIZQT__.TTF", rowFontSize, "OUTLINE")
    row:ClearAllPoints()
    row:SetPoint("TOP", prevAnchor, "BOTTOM", 0, -3)
    local nameColor = classColorEnabled and GetDeathTallyNameColorHex(classFile) or "ffffffff"
    local countColor = count > 0 and "ffff5555" or "ffffffff"
    row:SetText(("|c%s%s|r: |c%s%d|r"):format(nameColor, displayName, countColor, count))
    row:Show()
    return row
end

-- Redraws the row list from deathTallyOrder/deathTallyData and resizes the frame.
function BH:UpdateDeathTallyDisplay()
    if not self.deathTallyFrame then return end

    local titleFontSize = (self.settings and self.settings.deathTallyTitleFontSize) or 13
    local rowFontSize   = (self.settings and self.settings.deathTallyRowFontSize) or 12
    self.deathTallyTitle:SetFont("Fonts\\FRIZQT__.TTF", titleFontSize, "OUTLINE")
    local classColorEnabled = not self.settings or self.settings.deathTallyClassColorNames ~= false

    if self.unlockMode then
        local previewEntries = {
            { displayName = "Tankname", classFile = "WARRIOR", count = 0 },
            { displayName = "Healyou",  classFile = "PRIEST",  count = 1 },
            { displayName = "Dpsalot",  classFile = "MAGE",    count = 3 },
        }
        local anchor = self.deathTallyTitle
        for i, e in ipairs(previewEntries) do
            anchor = DrawDeathTallyRow(i, rowFontSize, classColorEnabled, anchor, e.displayName, e.classFile, e.count)
        end
        for i = #previewEntries + 1, #self.deathTallyRows do
            self.deathTallyRows[i]:Hide()
        end
        self.deathTallyFrame:SetHeight(titleFontSize + 12 + #previewEntries * (rowFontSize + 6))
        self.deathTallyFrame:Show()
        self.deathTallyFrame:EnableMouse(true)
        return
    end

    if not self.settings or not self.settings.deathTallyEnabled or deathTallyManuallyClosed then
        self.deathTallyFrame:Hide()
        return
    end

    local shown = 0
    local anchor = self.deathTallyTitle
    for _, guid in ipairs(deathTallyOrder) do
        local entry = deathTallyData[guid]
        if entry then
            shown = shown + 1
            anchor = DrawDeathTallyRow(shown, rowFontSize, classColorEnabled, anchor,
                FormatDeathTallyName(entry), entry.classFile, entry.count)
        end
    end
    for i = shown + 1, #self.deathTallyRows do
        self.deathTallyRows[i]:Hide()
    end

    if shown == 0 then
        self.deathTallyFrame:Hide()
        return
    end

    self.deathTallyFrame:SetHeight(titleFontSize + 12 + shown * (rowFontSize + 6))
    self.deathTallyFrame:Show()
    local locked = self.settings and self.settings.deathTallyLocked
    self.deathTallyFrame:EnableMouse(not locked)
end


-- Adds any currently-present group member not yet tracked, at 0 deaths.
-- wasDead is seeded from their CURRENT state (not false) so a member who is
-- already dead/ghost at sync time (e.g. reload-mid-key, or joining mid-wipe)
-- isn't miscounted as a fresh death on the next poll.
-- Does NOT touch existing entries/counts — safe to call any time roster changes.
function BH:SyncDeathTallyRoster()
    for _, unit in ipairs(BH.GetGroupUnits()) do
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local guid = UnitGUID(unit)
            if guid and not deathTallyData[guid] then
                local name, realm = UnitName(unit)
                local _, classFile = UnitClass(unit)
                if name then
                    deathTallyData[guid] = {
                        name = name, realm = realm, classFile = classFile,
                        count = 0, wasDead = UnitIsDeadOrGhost(unit) and true or false,
                    }
                    table.insert(deathTallyOrder, guid)
                end
            end
        end
    end
end

-- Spirit of Redemption state (see BH:ReconcileDeathTally). On BH rather than
-- in new file-level locals: this file is long enough to mind Lua's 200-local
-- limit. base = GetDeathCount minus our total when the key was picked up;
-- behind = polls the key has been ahead; untilT = GUID -> GetTime() until
-- which a credited priest's flag flip is the same death, not a second.
BH._tallySoR = { base = nil, behind = 0, untilT = {} }

-- Rebuilds the tally from the current party/raid roster with all counts at 0.
function BH:ResetDeathTally()
    wipe(deathTallyData)
    wipe(deathTallyOrder)
    self._tallySoR.base, self._tallySoR.behind = nil, 0
    wipe(self._tallySoR.untilT)
    deathTallyManuallyClosed = false
    self:SyncDeathTallyRoster()
    self:UpdateDeathTallyDisplay()
end

function BH:StartDeathTallyTracking()
    deathTallyActive = true
    self:ResetDeathTally()
    if self.deathTallyTicker then self.deathTallyTicker:Play() end
end

function BH:StopDeathTallyTracking()
    deathTallyActive = false
    if self.deathTallyTicker then self.deathTallyTicker:Stop() end
    -- Leave the frame showing the final tally as a summary; it will be reset
    -- and re-shown on the next CHALLENGE_MODE_START rather than hidden now.
end

-- Polling tick (every 0.5s while active): picks up roster changes, then
-- edge-detects each tracked member's UnitIsDeadOrGhost false→true transition.
function BH:PollDeathTally()
    if not deathTallyActive then return end
    self:SyncDeathTallyRoster()

    local changed = false
    for _, unit in ipairs(BH.GetGroupUnits()) do
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            local entry = guid and deathTallyData[guid]
            if entry then
                local isDead = UnitIsDeadOrGhost(unit) and true or false
                if isDead and not entry.wasDead then
                    -- guid already indexed deathTallyData above, so it is
                    -- not a secret here (an entry exists only for a plain one).
                    ---@diagnostic disable-next-line: secret-table-key
                    if (self._tallySoR.untilT[guid] or 0) > GetTime() then
                        -- Already credited by ReconcileDeathTally when the
                        -- angel form began; this is that death landing.
                        ---@diagnostic disable-next-line: secret-table-key
                        self._tallySoR.untilT[guid] = nil
                    else
                        entry.count = entry.count + 1
                        changed = true
                    end
                end
                entry.wasDead = isDead
            end
        end
    end
    if self:ReconcileDeathTally() then changed = true end

    if changed then self:UpdateDeathTallyDisplay() end
end

-- Spirit of Redemption (user report 2026-10-11). A Holy priest who "dies" turns
-- into an angel instead of a corpse, so UnitIsDeadOrGhost never flips and the
-- poll never sees it -- with Restitution they come back without ever being
-- flagged dead. The KEY still counts it (GetDeathCount, and the time penalty).
-- When the key's count runs ahead of our total for three polls (it can lead by
-- a tick), someone died unseen; with exactly one priest healer in the group
-- that is their Spirit of Redemption, credited to them. If the angel form then
-- ends in a real death within 20 s, the poll treats that flip as the same death.
-- With no lone priest healer the gap is accepted, not guessed at. GetDeathCount
-- is feign-free, so Feign Death stays out. DPSReport does the same
-- (DeathTracker:Reconcile). Returns true when it credited a death.
function BH:ReconcileDeathTally()
    local sor = self._tallySoR
    local active = C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
        and C_ChallengeMode.IsChallengeModeActive()
    if not active then sor.base, sor.behind = nil, 0 return false end
    local ok, kc = pcall(C_ChallengeMode.GetDeathCount)
    if not ok or type(kc) ~= "number" or (issecretvalue and issecretvalue(kc)) then return false end
    local ours = 0
    for _, e in pairs(deathTallyData) do ours = ours + e.count end
    if not sor.base then
        sor.base, sor.behind = kc - ours, 0
        return false
    end
    local extra = kc - sor.base - ours
    if extra <= 0 then
        sor.behind = 0
        if extra < 0 then sor.base = kc - ours end
        return false
    end
    sor.behind = sor.behind + 1
    if sor.behind < 3 then return false end
    sor.behind = 0
    local found
    for _, unit in ipairs(BH.GetGroupUnits()) do
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local _, class = UnitClass(unit)
            local role = UnitGroupRolesAssigned(unit)
            local guid = UnitGUID(unit)
            if class and not (issecretvalue and issecretvalue(class)) and role
               and not (issecretvalue and issecretvalue(role)) and guid
               and not (issecretvalue and issecretvalue(guid))
               and class == "PRIEST" and role == "HEALER" and deathTallyData[guid] then
                if found and found ~= guid then found = false break end
                found = guid
            end
        end
    end
    if found then
        deathTallyData[found].count = deathTallyData[found].count + extra
        sor.untilT[found] = GetTime() + 20
        return true
    end
    sor.base = sor.base + extra
    return false
end


-- Read by the core (reminder gates, the event handler), which cannot see the
-- local above.
function BH.DeathTallyActive() return deathTallyActive end
