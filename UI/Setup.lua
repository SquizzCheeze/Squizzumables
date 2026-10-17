-- UI/Setup.lua
-- First-run setup (2.0 phase 4, design doc "First-run setup"): four short
-- steps -- your role, a suggested set of extras for it, placing the frames,
-- and picking a theme. A new install gets it in place of the old welcome
-- note; anyone else can run it from the update note's Run Setup button or
-- with /sq setup. Every step can be skipped, and so can the whole thing.
--
-- The suggested set is SUGGESTED, never forced (user decision 2026-10-16): it
-- arrives pre-ticked for the role, every role sees every option, and the
-- player ticks what they want. Consumable and class buff reminders are on
-- for everyone regardless, so they are not part of it.

local addonName, ns = ...
local BH = ns.BH

local Setup = {}
ns.Setup = Setup

local SQ_COLORS = ns.SQ_COLORS

local WIDTH, HEIGHT = 520, 360
local TEXT_W = WIDTH - 44
local STEPS = 4

local ROLES = {
    { key = "HEALER",  label = "Healer" },
    { key = "TANK",    label = "Tank" },
    { key = "DAMAGER", label = "Damage" },
}
local ROLE_NAME = { HEALER = "healer", TANK = "tank", DAMAGER = "damage dealer" }

-- What each role gets pre-ticked (user decisions 2026-10-16). Every role is
-- OFFERED every option -- a damage dealer may well want to know when the tank
-- is crowd controlled -- and only the ticks differ: a healer watches the
-- tank, a tank the healer, and the battle res counter and the M+ death tally
-- suit anyone. ccTank / ccHealer are the Role CC alert's two roles
-- (roleCCAlertTank / healerCCAlertEnabled).
local SUGGESTED = {
    HEALER  = { ccTank = true,  ccHealer = false, bres = true, tally = true },
    TANK    = { ccTank = false, ccHealer = true,  bres = true, tally = true },
    DAMAGER = { ccTank = false, ccHealer = false, bres = true, tally = true },
}

local frame
local state = { step = 1 }

-- The role the current spec plays, as a starting pick.
local function DetectedRole()
    local idx = GetSpecialization and GetSpecialization()
    local role = idx and GetSpecializationRole and GetSpecializationRole(idx)
    if role == "HEALER" or role == "TANK" then return role end
    return "DAMAGER"
end

local function Dim(fs)
    fs:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    return fs
end

local function Text(parent, y, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    fs:SetWidth(TEXT_W)
    fs:SetJustifyH("LEFT")
    fs:SetSpacing(3)
    return fs
end

-- ----------------------------------------------------------------------------
-- Applying the picks
-- ----------------------------------------------------------------------------

-- Write the ticked set into the settings.
local function ApplyPicks()
    local s = BH.settings
    local picks = state.picks
    if not (s and picks) then return end
    s.roleCCAlertTank      = picks.ccTank and true or false
    s.healerCCAlertEnabled = picks.ccHealer and true or false
    s.bresCounterEnabled = picks.bres and true or false
    s.deathTallyEnabled  = picks.tally and true or false
    BH:SaveSettings()

    if BH.RefreshRoleCCWatchList then BH:RefreshRoleCCWatchList() end
    if BH.UpdateRoleCCFrame then BH:UpdateRoleCCFrame() end
    if not s.bresCounterEnabled and BH.bresCounterFrame then BH.bresCounterFrame:Hide() end
    if BH.deathTallyFrame and BH.UpdateDeathTallyDisplay then BH:UpdateDeathTallyDisplay() end
    if ns.Rows then ns.Rows.RefreshAll() end
end

local function Finish()
    if SquizzumablesDB then SquizzumablesDB.setupDone = true end
    if BH.unlockMode then BH:SetUnlockMode(false) end
    frame:Hide()
end

-- ----------------------------------------------------------------------------
-- The steps
-- ----------------------------------------------------------------------------

local Render   -- defined below; the steps redraw through it

local function BuildRoleStep(page)
    local _, class = UnitClass("player")
    local className = (BH.CLASS_NAMES and BH.CLASS_NAMES[class]) or class or "your class"

    local head = Text(page, 0, "GameFontNormalLarge")
    head:SetText("Which role do you play?")
    page.note = Dim(Text(page, -30))

    page.buttons = {}
    for i, role in ipairs(ROLES) do
        local b = ns.CreateSQButton(page, role.label, 140, 30)
        b:SetPoint("TOPLEFT", page, "TOPLEFT", (i - 1) * 156, -96)
        b:SetScript("OnClick", function()
            state.role = role.key
            state.picks = nil   -- a new role brings its own suggestions
            Render()
        end)
        page.buttons[role.key] = b
    end

    page.refresh = function()
        page.note:SetText("Squizzumables picked up that you are playing a " .. className .. ". Pick the role you "
            .. "play most -- it decides what the next step suggests. Class buffs and consumables are "
            .. "covered whatever you pick.")
        local ar, ag, ab = ns.GetAccentColor()
        for key, b in pairs(page.buttons) do
            if key == state.role then
                b.label:SetText("> " .. b.roleLabel .. " <")
                b.label:SetTextColor(ar, ag, ab)
            else
                b.label:SetText(b.roleLabel)
                b.label:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])
            end
        end
    end
    for _, role in ipairs(ROLES) do page.buttons[role.key].roleLabel = role.label end
end

local function BuildSetStep(page)
    page.head = Text(page, 0, "GameFontNormalLarge")
    page.note = Dim(Text(page, -30))

    local function Check(y, label, field)
        local cb = ns.CreateSQCheckbox(page, label, function(v)
            state.picks[field] = v and true or false
        end)
        cb:SetPoint("TOPLEFT", page, "TOPLEFT", 0, y)
        cb:SetWidth(TEXT_W)
        return cb
    end
    page.ccTank   = Check(-86,  "Role CC alert: tell me when a tank is crowd controlled", "ccTank")
    page.ccHealer = Check(-116, "Role CC alert: tell me when a healer is crowd controlled", "ccHealer")
    page.bres     = Check(-146, "Battle res counter: charges left in a Mythic+ key or a raid", "bres")
    page.tally    = Check(-176, "M+ death tally: who died how often in the current key", "tally")

    page.refresh = function()
        state.picks = state.picks or CopyTable(SUGGESTED[state.role])
        page.head:SetText("Suggested for a " .. ROLE_NAME[state.role])
        page.note:SetText("Ticked for your role -- tick or untick anything you like. All of it can be "
            .. "changed later in the settings.")
        page.ccTank:SetChecked(state.picks.ccTank)
        page.ccHealer:SetChecked(state.picks.ccHealer)
        page.bres:SetChecked(state.picks.bres)
        page.tally:SetChecked(state.picks.tally)
    end
end

local function BuildPlaceStep(page)
    local head = Text(page, 0, "GameFontNormalLarge")
    head:SetText("Put things where you want them")
    local note = Dim(Text(page, -30))
    note:SetText("Unlock the frames to see every reminder, the raid tools and your Cooldown Manager groups, and "
        .. "drag them into place. Click one to select it and nudge it with the arrow keys. The game's own "
        .. "Edit Mode (Esc > Edit Mode) unlocks them too.")

    local b = ns.CreateSQButton(page, "Unlock Frames", 160, 28)
    b:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -112)
    b:SetScript("OnClick", function()
        BH:SetUnlockMode(not BH.unlockMode)
        page.refresh()
    end)
    page.refresh = function()
        b:SetText(BH.unlockMode and "Lock Frames" or "Unlock Frames")
    end
end

local function BuildReadyStep(page)
    local head = Text(page, 0, "GameFontNormalLarge")
    head:SetText("You're set")
    local note = Dim(Text(page, -30))
    note:SetText("Reminders appear in dungeons, raids and delves, and each one is a button you can click to "
        .. "fix the problem. Everything is under /sq or the minimap button, with a search box at the "
        .. "top.\n\nLast thing: pick a look. The theme changes this window and every Squizzumables frame.")

    local b = ns.CreateSQButton(page, "Choose a Theme", 160, 28)
    b:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -132)
    b:SetScript("OnClick", function()
        Finish()
        BH:CreateOptionsPanel()
        if BH.switchTab then BH.switchTab("settings") end   -- the theme is at its top
    end)
    page.refresh = function() end
end

-- ----------------------------------------------------------------------------
-- The window
-- ----------------------------------------------------------------------------

local function Build()
    if frame then return frame end

    frame = CreateFrame("Frame", "SquizzumablesSetup", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    ns.ApplySQBackdrop(frame)
    -- Shares the login notes queue with the other Squizz addons, so it never
    -- draws through another addon's update note (Core/Welcome.lua).
    if BH.NotesHidden then frame:HookScript("OnHide", BH.NotesHidden) end

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -16)
    title:SetText("Squizzumables setup")
    ns.ApplyAccent(title, "text")

    frame.stepLabel = Dim(frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
    frame.stepLabel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -22, -20)

    frame.pages = {}
    local builders = { BuildRoleStep, BuildSetStep, BuildPlaceStep, BuildReadyStep }
    for i, build in ipairs(builders) do
        local page = CreateFrame("Frame", nil, frame)
        page:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -56)
        page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 56)
        page:Hide()
        build(page)
        frame.pages[i] = page
    end

    local skip = ns.CreateSQButton(frame, "Skip Setup", 110, 26)
    skip:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 22, 16)
    skip:SetScript("OnClick", Finish)
    ns.Rows.AddTooltip(skip, "Skip Setup", "Close setup and keep the settings as they are. /sq setup runs it again.")

    local nextBtn = ns.CreateSQButton(frame, "Next", 100, 26)
    nextBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 16)
    nextBtn:SetScript("OnClick", function()
        if state.step == 2 then ApplyPicks() end
        if state.step >= STEPS then Finish() return end
        state.step = state.step + 1
        Render()
    end)
    frame.nextBtn = nextBtn

    local backBtn = ns.CreateSQButton(frame, "Back", 90, 26)
    backBtn:SetPoint("RIGHT", nextBtn, "LEFT", -8, 0)
    backBtn:SetScript("OnClick", function()
        state.step = math.max(1, state.step - 1)
        Render()
    end)
    frame.backBtn = backBtn

    return frame
end

Render = function()
    for i, page in ipairs(frame.pages) do
        page:SetShown(i == state.step)
        if i == state.step and page.refresh then page.refresh() end
    end
    frame.stepLabel:SetText(("Step %d of %d"):format(state.step, STEPS))
    frame.backBtn:SetShown(state.step > 1)
    frame.nextBtn:SetText(state.step >= STEPS and "Finish" or "Next")
end

--- Open setup from the start. `queued`: the automatic first-run showing, which
--- waits behind another Squizz addon's note rather than drawing over it.
function Setup.Show(queued)
    Build()
    state.step = 1
    state.role = DetectedRole()
    state.picks = nil
    Render()
    if queued and BH.PresentNotesFrame then
        BH.PresentNotesFrame(frame, true)
    else
        frame:Show()
        frame:Raise()
    end
end

BH.ShowSetup = Setup.Show
