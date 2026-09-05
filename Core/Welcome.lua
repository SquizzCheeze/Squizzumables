-- Core/Welcome.lua
-- The first-run greeting and the "what changed" note after an update.
--
-- One frame serves both: they differ only in their heading and their body, and
-- both are "say this once, then never again".
--
-- The notes below are deliberately a short highlight list rather than the full
-- changelog.txt. An addon cannot read its own text files at runtime, so
-- anything shown in game has to be duplicated in Lua -- and duplicating a
-- 200-line changelog would guarantee the copy rots. A handful of lines per
-- release is worth keeping in step by hand; the full history stays in
-- changelog.txt for anyone who wants it.

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

local SQ_COLORS = ns.SQ_COLORS
local CreateSQButton = ns.CreateSQButton
local ApplySQBackdrop = ns.ApplySQBackdrop

-- Highlights per version, newest first. Keyed by the .toc Version string.
local RELEASE_NOTES = {
    ["1.69"] = {
        "The Earth Shield reminder no longer fires in delves and follower dungeons, where your party is NPCs and there is nobody to shield.",
        "The Earth Shield reminder now checks whether you actually have Elemental Orbit instead of guessing from your own shield.",
        "Cooldown Manager groups can be styled: border thickness and colour (or class colour), icon zoom, and an optional icon background.",
    },
    ["1.68"] = {
        "The Just For Kel alert image is now click-through \226\128\148 it no longer swallows clicks while it is on screen.",
        "Position it with Unlock Frames, like every other frame. The separate lock checkbox has been removed.",
        "Fixed the alert image staying undraggable after using Lock All Frames.",
    },
    ["1.67"] = {
        "Rite of Sanctification and Rite of Adjuration now show for Protection Paladins, not just Holy.",
        "Weapon oil buttons step aside for any Lightsmith Rite, so the two no longer fight over the main-hand slot.",
        "Buff sounds now retry when the game refuses to register them, instead of staying off until you relog.",
    },
    ["1.66"] = {
        "Buff sounds now register correctly when you add or change one during combat \226\128\148 those were being dropped until a reload.",
        "The Mythic+ callout bug turned out to be another addon tainting chat, not this one \226\128\148 removing it fixes them.",
    },
    ["1.65"] = {
        "Reverted the 1.64 callout change \226\128\148 it broke callouts in Mythic+ for setups where they had been working.",
    },
    ["1.64"] = {
        "Fixed dungeon callout buttons doing nothing when clicked in Mythic+.",
        "Fixed buff sounds switching themselves off when the settings were opened with /sq config.",
        "Say and Yell removed from callouts \226\128\148 the game blocks addons from using them in instances.",
    },
    ["1.63"] = {
        "Dungeon callouts now use a dropdown \226\128\148 pick a dungeon, see only its callouts.",
        "This season's Mythic+ dungeons are listed already, so you can write callouts without travelling.",
        "Raids and older dungeons join the list the first time you zone into them.",
    },
    ["1.62"] = {
        "New Buff Sounds grid under Kelerts: your spec's own buffs, a sound when each lands or drops \226\128\148 and these fire in combat.",
        "The lust alert is unchanged. Your other Kelerts moved into the grid, keeping their sounds.",
        "Cooldown Manager sound alerts now follow spec and talent changes without a reload.",
        "The Cooldowns settings tab rebuilds on a spec change instead of showing the old spec.",
    },
    ["1.61"] = {
        "The per-item \"Min\" minutes box now saves when you click away, not only when you press Enter.",
        "Click into a \"Min\" box and scroll to adjust it (Shift for 5 at a time).",
        "Every settings text box redrawn in the addon's own square-bordered style.",
    },
    ["1.60"] = {
        "Cooldown Manager sound alerts now work in combat, including \"when available\".",
        "Death Knights and augment runes are now tracked; healthstones too.",
        "New \"Show in\" settings: choose which content the reminders appear in.",
        "The four \"nothing in bags\" reminders are now one frame.",
        "Settings redesigned: sidebar, search, tooltips on every option.",
        "Reminders that matter mid-fight no longer vanish when combat starts.",
        "Kelerts: add your own, on any buff or debuff you name.",
    },
}

local function CurrentVersion()
    return (C_AddOns and C_AddOns.GetAddOnMetadata
        and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "?"
end

local frame

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "SquizzumablesWelcome", UIParent, "BackdropTemplate")
    frame:SetSize(460, 320)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    ApplySQBackdrop(frame)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -16)
    frame.title = title

    local body = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    body:SetWidth(424)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetSpacing(4)
    body:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    frame.body = body

    local settingsBtn = CreateSQButton(frame, "Open Settings", 130, 26)
    settingsBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, 16)
    settingsBtn:SetScript("OnClick", function()
        frame:Hide()
        BH:CreateOptionsPanel()
    end)

    local closeBtn = CreateSQButton(frame, "Close", 90, 26)
    closeBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 16)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    return frame
end

local function Show(titleText, bodyText)
    local f = BuildFrame()
    f.title:SetText(titleText)
    f.body:SetText(bodyText)
    f:Show()
end

--- The greeting for someone who has never run the addon.
--
-- No preset to apply: the shipped defaults *are* the sensible preset, and the
-- addon reads the player's class itself. So this explains what will happen and
-- points at the settings, rather than asking questions whose answers it can
-- already work out.
local function ShowFirstRun()
    local _, class = UnitClass("player")
    local className = (BH.CLASS_NAMES and BH.CLASS_NAMES[class]) or class or "your class"

    Show("Welcome to Squizzumables",
        "Squizzumables reminds you about the things that are easy to forget: food, flasks, "
     .. "weapon oils, augment runes, healthstones and your class buffs.\n\n"
     .. "It has picked up that you are playing a " .. className .. " and will watch the buffs "
     .. "that go with it. Reminders appear in dungeons, raids and delves -- not out in the "
     .. "world -- and each one is a button you can click to fix the problem.\n\n"
     .. "Nothing needs configuring to start. When you do want to change something, everything "
     .. "is under /sq config, or the minimap button, and there is a search box at the top.")
end

--- The note after updating.
local function ShowUpdated(version)
    local notes = RELEASE_NOTES[version]
    local body = "Squizzumables has been updated to " .. version .. ".\n\n"
    if notes then
        for _, line in ipairs(notes) do
            body = body .. "- " .. line .. "\n"
        end
        body = body .. "\nThe full changelog is in changelog.txt in the addon folder."
    else
        body = body .. "See changelog.txt in the addon folder for what changed."
    end
    Show("Squizzumables updated", body)
end

-- Decide which, if either, to show.
--
-- Deliberately not tied to LoadSettings: this reads its own key straight off
-- SquizzumablesDB, so it cannot be confused by a profile switch, and a player
-- who resets their settings does not get greeted again.
local function CheckVersion()
    if not SquizzumablesDB then return end
    local version = CurrentVersion()
    local seen = SquizzumablesDB.lastSeenVersion

    if seen == nil then
        -- No record at all. Distinguish a genuinely new install from an upgrade
        -- of a version that predates this file: an existing player already has
        -- settings saved.
        if SquizzumablesDB.settings then
            ShowUpdated(version)
        else
            ShowFirstRun()
        end
    elseif seen ~= version then
        ShowUpdated(version)
    end

    SquizzumablesDB.lastSeenVersion = version
end

-- After PLAYER_LOGIN so settings exist, and on a short delay so the greeting
-- does not land in the middle of the loading screen.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    C_Timer.After(4, CheckVersion)
end)

-- /sq notes re-opens the current release notes on demand.
BH.ShowReleaseNotes = function() ShowUpdated(CurrentVersion()) end
BH.ShowFirstRun = ShowFirstRun
