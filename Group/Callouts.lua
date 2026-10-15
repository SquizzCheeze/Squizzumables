-- Group/Callouts.lua
-- Dungeon callouts: the in-game button frame that sends a prepared message
-- through a secure macro button, and the Callouts options tab.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split), apart
-- from its sounds and sound list going through the core's public wrappers
-- (BH:PlaySound, BH:BuildSoundDropdownItems) instead of the private locals
-- behind them. Everything here is reached at runtime through BH.

local addonName, ns = ...
local BH = ns.BH

local SQ_COLORS        = ns.SQ_COLORS
local ApplySQBackdrop  = ns.ApplySQBackdrop
local SQ_GetClickEdge  = ns.SQ_GetClickEdge
local CreateSQButton   = ns.CreateSQButton
local CreateSQEditBox  = ns.CreateSQEditBox
local CreateSQDropdown = ns.CreateSQDropdown
local CreateSQDivider  = ns.CreateSQDivider

-- ============================================================
-- DUNGEON CALLOUTS — in-game button frame + config tab
-- ============================================================

-- Stored channel -> the slash command the secure macro runs.
--
-- The buttons send through a macro on a SecureActionButtonTemplate, which is
-- what survives taint; see the button construction in
-- UpdateCalloutsButtonFrame. 1.64 briefly swapped this for SendChatMessage and
-- chat channel strings, which was wrong -- SendChatMessage is protected too.
--
-- Say and Yell stay removed. That part of 1.64 was right for its own reasons:
-- Blizzard restricts addon-initiated SAY and YELL inside instances, which is
-- the only place callouts appear.
local CALLOUT_SLASH_MAP = {
    INSTANCE     = "/instance",
    PARTY        = "/party",
    RAID         = "/raid",
    RAID_WARNING = "/rw",
}
local CALLOUT_CHANNEL_ITEMS = {
    { text = "Instance",     value = "INSTANCE"     },
    { text = "Party",        value = "PARTY"        },
    { text = "Raid",         value = "RAID"         },
    { text = "Raid Warning", value = "RAID_WARNING" },
}

function BH:SaveCalloutsFramePosition()
    self:SaveFramePos("calloutsButtonFrame", "calloutsFramePosition")
end
function BH:LoadCalloutsFramePosition()
    self:LoadFramePos("calloutsButtonFrame", "calloutsFramePosition")
end

-- Creates the persistent callout button frame (once at login).
-- Buttons inside it are rebuilt by UpdateCalloutsButtonFrame on zone change.
function BH:BuildCalloutsButtonFrame()
    if self.calloutsButtonFrame then return end
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetSize(144, 40)
    f:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:Hide()

    -- Draggable by the frame itself, not only by its title bar. In unlock
    -- mode the callout buttons and the title bar are muted so the drag can
    -- reach this frame; without these scripts that left it unmovable from
    -- anywhere at all.
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) BH:GridStartMoving(self) end)
    f:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(self)
        BH:SaveCalloutsFramePosition()
    end)
    ApplySQBackdrop(f)
    self.calloutsButtonFrame = f

    local titleBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    titleBar:SetHeight(14)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    titleBar:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 0 })
    titleBar:SetBackdropColor(ns.Theme.RGBA("titleBar"))
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() BH:GridStartMoving(f) end)
    titleBar:SetScript("OnDragStop", function()
        BH:GridStopMoving(f)
        BH:SaveCalloutsFramePosition()
    end)
    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    titleText:SetText("Callouts")
    titleText:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    self.calloutsButtonFrameBtns = {}
end

-- Rebuilds callout buttons for the current dungeon.  Must be called OOC.
function BH:UpdateCalloutsButtonFrame()
    if not self.calloutsButtonFrame then return end
    if InCombatLockdown() then return end
    -- Clear previous buttons
    for _, btn in ipairs(self.calloutsButtonFrameBtns or {}) do
        btn:Hide()
        btn:SetParent(nil)
    end
    self.calloutsButtonFrameBtns = {}
    local f = self.calloutsButtonFrame
    -- While frames are unlocked, show this even with no callouts configured for
    -- the current instance, so it can be positioned from anywhere. It is just
    -- its title bar in that state, which is enough to drag.
    local function ShowEmptyIfUnlocked()
        if BH.unlockMode then
            f:SetSize(144, 40)
            f:Show()
        else
            f:Hide()
        end
    end
    local callouts = self.settings and self.settings.dungeonCallouts
    if not callouts then ShowEmptyIfUnlocked(); return end
    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    local matchedGroup = nil
    for _, group in ipairs(callouts) do
        if group.instanceID == instanceID then matchedGroup = group; break end
    end
    if not matchedGroup or not matchedGroup.buttons or #matchedGroup.buttons == 0 then
        ShowEmptyIfUnlocked(); return
    end
    local BTN_H, BTN_W, GAP, TITLE_H = 24, 144, 2, 14
    local yOfs = -(TITLE_H + GAP)
    for _, callout in ipairs(matchedGroup.buttons) do
        -- SecureActionButtonTemplate running a macro, which is the mechanism
        -- that survives taint -- that is what it is for.
        --
        -- 1.64 briefly replaced this with a plain Button calling
        -- SendChatMessage, on the theory that dropping the secure button would
        -- remove the protected surface. It does the opposite. SendChatMessage
        -- carries HasRestrictions too, and from a plain OnClick in a key it is
        -- refused -- ADDON_ACTION_BLOCKED, on a real mouse click, which would
        -- normally be allowed. Being blocked anyway is the tell that the path
        -- is tainted, and a secure button is precisely how you execute an
        -- action from a tainted addon.
        --
        -- HookScript("OnClick") appends an insecure hook that runs AFTER the
        -- secure handler completes -- the documented safe pattern. (SetScript
        -- replaces the handler and taints it.)
        local btn = CreateFrame("Button", nil, f, "SecureActionButtonTemplate")
        btn:SetSize(BTN_W - 4, BTN_H)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", 2, yOfs)
        btn:RegisterForClicks(SQ_GetClickEdge())
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        btn:SetHighlightTexture("Interface\\BUTTONS\\WHITE8X8")
        btn:GetHighlightTexture():SetVertexColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 0.4)
        local slash = CALLOUT_SLASH_MAP[callout.channel] or "/instance"
        btn:SetAttribute("type", "macro")
        -- Placeholders are filled in here, when the button is built -- it is
        -- rebuilt on entering a dungeon and on every edit, so {zone} and
        -- {name} are current (BH:ExpandPlaceholders).
        btn:SetAttribute("macrotext", slash .. " " .. (BH:ExpandPlaceholders(callout.message or "") or ""))
        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetAllPoints()
        lbl:SetText(callout.label or "Callout")
        ns.ApplyAccent(lbl, "text")
        local sndName = callout.sound or "None"
        -- Sound only. The message is sent by the secure macro attribute above,
        -- because SendChatMessage is itself protected -- it carries the same
        -- HasRestrictions flag as AddAuraSound, and calling it from here was
        -- blocked in Mythic+ even on a real mouse click, which normally permits
        -- a protected call. Being refused anyway means the path is tainted.
        --
        -- So the secure button is not the problem and removing it was a
        -- mistake: it is the mechanism that survives taint, which is why it
        -- exists. Something taints this addon during a key; that is the bug,
        -- and this is not the place to work around it.
        btn:HookScript("OnClick", function()
            if sndName ~= "None" then
                BH:PlaySound(sndName)
                -- Broadcast sound to other addon users in the group
                if IsInGroup() then
                    local addonChan = IsInInstance() and "INSTANCE_CHAT" or "PARTY"
                    C_ChatInfo.SendAddonMessage("SQ_CALLOUT", sndName, addonChan)
                end
            end
        end)
        table.insert(self.calloutsButtonFrameBtns, btn)
        yOfs = yOfs - BTN_H - GAP
    end
    local totalH = TITLE_H + GAP + #matchedGroup.buttons * (BTN_H + GAP)
    f:SetSize(BTN_W, totalH)
    f:Show()
end

function BH:RememberVisitedInstance()
    local name, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
    if not instanceID or instanceID == 0 then return end
    -- Skip the open world and battlegrounds; callouts are for content you
    -- run repeatedly with the same pulls.
    if instanceType ~= "party" and instanceType ~= "raid" and instanceType ~= "scenario" then
        return
    end
    SquizzumablesDB.visitedInstances = SquizzumablesDB.visitedInstances or {}
    -- Re-recorded every visit rather than only when new: an instance can be
    -- renamed between patches, and the stored name is what the dropdown
    -- shows.
    SquizzumablesDB.visitedInstances[instanceID] = name
end

-- Every dungeon worth offering, deduped by instanceID.
--
-- Three sources. The season's Mythic+ list comes from
-- C_ChallengeMode.GetMapTable(), which is live data -- so this refreshes
-- itself when the season rotates and there is nothing to hardcode. The 6th
-- return of GetMapUIInfo is the same number GetInstanceInfo reports as its
-- instanceID, which is what callouts match on (verified in game: Murder Row
-- is challenge map 587, mapID 2813, and standing inside it GetInstanceInfo
-- also says 2813).
--
-- Then anything already configured, so a dungeon keeps its entry after the
-- season moves on, and finally whatever instance the player is standing in,
-- which is the only route for raids and non-seasonal dungeons.
local function CalloutDungeonList()
    local list, seen = {}, {}

    local function Add(instanceID, name, tag)
        if not instanceID or instanceID == 0 or seen[instanceID] then return end
        seen[instanceID] = true
        list[#list + 1] = { instanceID = instanceID, name = name or ("Instance " .. instanceID), tag = tag }
    end

    for _, group in ipairs(BH.settings and BH.settings.dungeonCallouts or {}) do
        Add(group.instanceID, group.name, "saved")
    end

    if C_ChallengeMode and C_ChallengeMode.GetMapTable then
        local ok, maps = pcall(C_ChallengeMode.GetMapTable)
        for _, mapChallengeModeID in ipairs((ok and maps) or {}) do
            local mapName, _, _, _, _, instanceID = C_ChallengeMode.GetMapUIInfo(mapChallengeModeID)
            Add(instanceID, mapName, "season")
        end
    end

    for instanceID, name in pairs(SquizzumablesDB and SquizzumablesDB.visitedInstances or {}) do
        Add(instanceID, name, "visited")
    end

    local hereName, _, _, _, _, _, _, hereID = GetInstanceInfo()
    Add(hereID, hereName, "here")

    table.sort(list, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    return list
end
BH.CalloutDungeonList = CalloutDungeonList

-- The stored group for a dungeon, or nil. Selecting a dungeon deliberately
-- does not create one: browsing the dropdown would otherwise fill the saved
-- settings with empty entries for every dungeon merely looked at. The group
-- is created on the first callout added to it.
function BH.CalloutGroupFor(instanceID)
    for _, group in ipairs(BH.settings and BH.settings.dungeonCallouts or {}) do
        if group.instanceID == instanceID then return group end
    end
    return nil
end

function BH:BuildCalloutsTab(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    ns.TuneScrollStep(scrollFrame)
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    local leftPad = 14
    local yOffset = -14

    local hdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    hdr:SetText("DUNGEON CALLOUTS")
    ns.ApplyAccent(hdr, "text")
    yOffset = yOffset - 16

    local note = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    note:SetWidth(372)
    note:SetJustifyH("LEFT")
    note:SetText("Buttons appear automatically when you enter the matching dungeon. Clicking sends the message and plays the sound. Works in combat and M+.")
    note:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 36

    local dungeonDrop
    local function DungeonDropItems()
        local items = {}
        for _, entry in ipairs(CalloutDungeonList()) do
            local group = BH.CalloutGroupFor(entry.instanceID)
            local count = group and #(group.buttons or {}) or 0
            -- The count is the whole point of the marker: it separates "set up"
            -- from "offered but empty" without opening each one.
            local suffix = (count > 0) and ("  |cff888888(" .. count .. ")|r") or ""
            if entry.tag == "here" then suffix = suffix .. "  |cff888888[here]|r" end
            items[#items + 1] = { text = (entry.name or "?") .. suffix, value = entry.instanceID }
        end
        return items
    end
    BH.CalloutDungeonDropItems = DungeonDropItems

    dungeonDrop = CreateSQDropdown(content, "Dungeon:", 250, DungeonDropItems(), function(val)
        BH.selectedCalloutInstanceID = val
        BH:RefreshCalloutsTab()
    end)
    dungeonDrop:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.calloutsDungeonDrop = dungeonDrop
    ns.Rows.AddTooltip(dungeonDrop, "Dungeon",
        "This season's Mythic+ dungeons, plus any you have already set up and whatever you are standing in. The number is how many callouts it has.")
    yOffset = yOffset - 46

    local addCalloutBtn = CreateSQButton(content, "+ Add Callout", 120, 24)
    addCalloutBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    addCalloutBtn:SetScript("OnClick", function()
        local instanceID = BH.selectedCalloutInstanceID
        if not instanceID then return end
        BH.settings.dungeonCallouts = BH.settings.dungeonCallouts or {}
        local group = BH.CalloutGroupFor(instanceID)
        if not group then
            -- Created here rather than on selection, so the saved list only
            -- ever holds dungeons actually in use.
            local name
            for _, entry in ipairs(CalloutDungeonList()) do
                if entry.instanceID == instanceID then name = entry.name break end
            end
            group = { instanceID = instanceID, name = name, buttons = {} }
            table.insert(BH.settings.dungeonCallouts, group)
        end
        table.insert(group.buttons, { label = "", message = "", channel = "INSTANCE", sound = "None" })
        BH:SaveSettings()
        BH:UpdateCalloutsButtonFrame()
        BH:RefreshCalloutsTab()
    end)
    self.calloutsAddBtn = addCalloutBtn

    local delDungeonBtn = CreateSQButton(content, "Delete Dungeon", 120, 24, SQ_COLORS.danger)
    delDungeonBtn:SetPoint("LEFT", addCalloutBtn, "RIGHT", 8, 0)
    delDungeonBtn:SetScript("OnClick", function()
        local instanceID = BH.selectedCalloutInstanceID
        for i, group in ipairs(BH.settings.dungeonCallouts or {}) do
            if group.instanceID == instanceID then
                table.remove(BH.settings.dungeonCallouts, i)
                break
            end
        end
        BH:SaveSettings()
        BH:UpdateCalloutsButtonFrame()
        BH:RefreshCalloutsTab()
    end)
    self.calloutsDelDungeonBtn = delDungeonBtn
    ns.Rows.AddTooltip(delDungeonBtn, "Delete dungeon",
        "Remove every callout for this dungeon. It stays in the list above if the season still includes it.")
    yOffset = yOffset - 32

    -- The dungeon you are standing in is already in the dropdown, tagged
    -- [here]. This jumps straight to it, which is the common case while
    -- actually running the place and wanting a callout for the pull you just
    -- wiped on.
    local hereBtn = CreateSQButton(content, "+ Add Current Dungeon", 190, 24)
    hereBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    hereBtn:SetScript("OnClick", function()
        local _, _, _, _, _, _, _, iID = GetInstanceInfo()
        if not iID or iID == 0 then return end
        BH.selectedCalloutInstanceID = iID
        BH:RefreshCalloutsTab()
    end)
    hereBtn:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        local dName, _, _, _, _, _, _, iID = GetInstanceInfo()
        if iID and iID ~= 0 then
            GameTooltip:SetText("Select: " .. (dName or "?") .. " (ID: " .. tostring(iID) .. ")")
            GameTooltip:AddLine("Nothing is saved until you add a callout.", 0.7, 0.7, 0.7, true)
        else
            GameTooltip:SetText("Must be inside a dungeon or raid.")
        end
        GameTooltip:Show()
    end)
    hereBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.calloutsHereBtn = hereBtn
    yOffset = yOffset - 32

    -- Dynamic dungeon list (rebuilt by RefreshCalloutsTab)
    local listFrame = CreateFrame("Frame", nil, content)
    listFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
    listFrame:SetWidth(400)
    listFrame:SetHeight(10)
    self.calloutsTabContent = content
    self.calloutsTabListFrame = listFrame
    self.calloutsTabStaticHeight = math.abs(yOffset)
    self:RefreshCalloutsTab()
end

function BH:RefreshCalloutsTab()
    local listFrame = self.calloutsTabListFrame
    local content   = self.calloutsTabContent
    if not listFrame or not content then return end
    -- Clear previous dynamic content
    for _, child in pairs({ listFrame:GetChildren() }) do
        child:Hide(); child:SetParent(nil)
    end

    local leftPad = 14
    local W = 372
    local yOffset = 0

    -- Default the selection rather than showing nothing on first open: the
    -- instance you are standing in if it is one, else the first entry offered.
    local dungeons = BH.CalloutDungeonList and BH.CalloutDungeonList() or {}
    local selected = BH.selectedCalloutInstanceID
    local valid = false
    for _, entry in ipairs(dungeons) do
        if entry.instanceID == selected then valid = true break end
    end
    if not valid then
        local _, _, _, _, _, _, _, hereID = GetInstanceInfo()
        selected = (hereID and hereID ~= 0) and hereID or (dungeons[1] and dungeons[1].instanceID)
        BH.selectedCalloutInstanceID = selected
    end

    if self.calloutsDungeonDrop and BH.CalloutDungeonDropItems then
        self.calloutsDungeonDrop:SetItems(BH.CalloutDungeonDropItems())
        self.calloutsDungeonDrop:SetSelectedValue(selected)
    end

    -- Only the selected dungeon is rendered. Every configured dungeon used to
    -- be stacked into this one scroll, which grew without bound; now the tab is
    -- a fixed height whatever the player has set up.
    local group = selected and BH.CalloutGroupFor and BH.CalloutGroupFor(selected) or nil

    -- Delete only means something once a group exists.
    if self.calloutsDelDungeonBtn then
        self.calloutsDelDungeonBtn:SetAlpha(group and 1 or 0.35)
        self.calloutsDelDungeonBtn:SetEnabled(group and true or false)
    end

    if not selected then
        local none = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        none:SetPoint("TOPLEFT", listFrame, "TOPLEFT", leftPad, yOffset)
        none:SetText("No dungeons available. Enter one, or wait for the season list to load.")
        none:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        listFrame:SetHeight(24)
        content:SetHeight((self.calloutsTabStaticHeight or 0) + 24 + 20)
        return
    end

    if not group or #(group.buttons or {}) == 0 then
        local none = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        none:SetPoint("TOPLEFT", listFrame, "TOPLEFT", leftPad, yOffset)
        none:SetText("No callouts here yet. Add one above.")
        none:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        listFrame:SetHeight(24)
        content:SetHeight((self.calloutsTabStaticHeight or 0) + 24 + 20)
        return
    end

    do
        local groupFrame = CreateFrame("Frame", nil, listFrame)
        groupFrame:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 0, yOffset)
        groupFrame:SetWidth(400)
        local gy = 0

        local div = CreateSQDivider(groupFrame, gy)
        div:SetPoint("TOPLEFT", groupFrame, "TOPLEFT", leftPad, gy)
        gy = gy - 18

        -- Per-callout rows
        for bIdx, callout in ipairs(group.buttons) do
            local rowFrame = CreateFrame("Frame", nil, groupFrame)
            rowFrame:SetPoint("TOPLEFT", groupFrame, "TOPLEFT", leftPad, gy)
            rowFrame:SetSize(W, 56)

            -- Row 1: [Label 86px] [Message 256px] [× 22px]
            local labelEdit = CreateSQEditBox(rowFrame, 86, 20, { maxLetters = 32 })
            labelEdit:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 0, 0)
            labelEdit:SetText(callout.label or "")
            local labelPH = labelEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            labelPH:SetPoint("LEFT", labelEdit, "LEFT", 6, 0)
            labelPH:SetText("Label")
            labelPH:SetTextColor(0.4, 0.4, 0.4)
            labelPH:SetShown(labelEdit:GetText() == "")
            labelEdit:SetScript("OnTextChanged", function(self)
                labelPH:SetShown(self:GetText() == "")
                callout.label = self:GetText()
                BH:SaveSettings(); BH:UpdateCalloutsButtonFrame()
            end)
            labelEdit:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
            labelEdit:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
            labelEdit:SetScript("OnShow", function(s) labelPH:SetShown(s:GetText() == "") end)

            local msgEdit = CreateSQEditBox(rowFrame, 256, 20, { maxLetters = 200 })
            msgEdit:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 92, 0)
            msgEdit:SetText(callout.message or "")
            local msgPH = msgEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            msgPH:SetPoint("LEFT", msgEdit, "LEFT", 6, 0)
            msgPH:SetText("Chat message ({name} and {zone} work)")
            msgPH:SetTextColor(0.4, 0.4, 0.4)
            msgPH:SetShown(msgEdit:GetText() == "")
            msgEdit:SetScript("OnTextChanged", function(self)
                msgPH:SetShown(self:GetText() == "")
                callout.message = self:GetText()
                BH:SaveSettings(); BH:UpdateCalloutsButtonFrame()
            end)
            msgEdit:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
            msgEdit:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
            msgEdit:SetScript("OnShow", function(s) msgPH:SetShown(s:GetText() == "") end)

            local delBtn = CreateSQButton(rowFrame, "×", 22, 20, SQ_COLORS.danger)
            delBtn:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 354, 0)
            -- Captured against the group table rather than its index: only one
            -- group is rendered now, and an index into dungeonCallouts would be
            -- wrong the moment another dungeon is deleted from under it.
            local cb = bIdx
            delBtn:SetScript("OnClick", function()
                table.remove(group.buttons, cb)
                BH:SaveSettings(); BH:UpdateCalloutsButtonFrame(); BH:RefreshCalloutsTab()
            end)

            -- Row 2: [Channel DD 100px] [Sound DD 200px] [▶ 22px]
            local chanDD = CreateSQDropdown(rowFrame, "", 100, CALLOUT_CHANNEL_ITEMS, function(value)
                callout.channel = value
                BH:SaveSettings(); BH:UpdateCalloutsButtonFrame()
            end)
            chanDD:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 0, -24)
            chanDD:SetSelectedValue(callout.channel or "INSTANCE")

            local sndDD = CreateSQDropdown(rowFrame, "", 200, BH:BuildSoundDropdownItems(), function(value)
                callout.sound = value
                BH:SaveSettings(); BH:UpdateCalloutsButtonFrame()
            end)
            sndDD:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 106, -24)
            sndDD:SetSelectedValue(callout.sound or "None")

            local pvBtn = CreateFrame("Button", nil, rowFrame)
            pvBtn:SetSize(22, 22)
            pvBtn:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 312, -28)
            local pvn = pvBtn:CreateTexture(nil, "BACKGROUND")
            pvn:SetAllPoints(); pvn:SetTexture("Interface\\Common\\VoiceChat-Speaker")
            local pvh = pvBtn:CreateTexture(nil, "HIGHLIGHT")
            pvh:SetAllPoints(); pvh:SetTexture("Interface\\Common\\VoiceChat-Speaker"); pvh:SetAlpha(0.6)
            pvBtn:SetScript("OnEnter", function() pvn:SetAlpha(0.7) end)
            pvBtn:SetScript("OnLeave", function() pvn:SetAlpha(1.0) end)
            pvBtn:SetScript("OnClick", function() BH:PlaySound(callout.sound or "None") end)

            gy = gy - 62
        end

        -- No "Add Callout" here any more: there is one in the header, which is
        -- always on screen rather than below however many rows this dungeon has.
        groupFrame:SetHeight(math.abs(gy))
        yOffset = yOffset + gy
    end

    listFrame:SetHeight(math.abs(yOffset) + 10)
    content:SetHeight((self.calloutsTabStaticHeight or 80) + math.abs(yOffset) + 20)
end
