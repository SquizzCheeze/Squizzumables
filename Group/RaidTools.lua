-- Group/RaidTools.lua
-- Raid tools: the world / target marker frames, the pull timer, the battle
-- res counter's frame handling, and the Raid Tools options tab.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split). Loads
-- straight after it, and everything here is reached at runtime through BH --
-- events, slash commands and the options window -- so the move changes no
-- behaviour. The one private value of the core it needs, whether the battle
-- res counter is tracking, comes through BH.BresTrackingActive().

local addonName, ns = ...
local BH = ns.BH

local SQ_COLORS       = ns.SQ_COLORS
local SQ_GetClickEdge = ns.SQ_GetClickEdge
local CreateSQButton  = ns.CreateSQButton

-- ============================================================================
-- Raid Tools Module

-- World marker colors (indices 1-8, matching Blizzard raid marker order)
local WORLD_MARKER_COLORS = {
    [1] = { 1.00, 0.82, 0.00 },  -- Star (Yellow)
    [2] = { 1.00, 0.49, 0.04 },  -- Circle (Orange)
    [3] = { 0.58, 0.51, 0.79 },  -- Diamond (Purple)
    [4] = { 0.12, 1.00, 0.00 },  -- Triangle (Green)
    [5] = { 0.78, 0.78, 0.78 },  -- Moon (Silver)
    [6] = { 0.00, 0.44, 0.87 },  -- Square (Blue)
    [7] = { 0.77, 0.12, 0.23 },  -- Cross (Red)
    [8] = { 1.00, 1.00, 1.00 },  -- Skull (White)
}

-- Target marker icon textures (indices 1-8)
local TARGET_MARKER_TEXTURES = {
    [1] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1", -- Star
    [2] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_2", -- Circle
    [3] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3", -- Diamond
    [4] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4", -- Triangle
    [5] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5", -- Moon
    [6] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6", -- Square
    [7] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7", -- Cross
    [8] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8", -- Skull
}

local function IsLeaderOrAssist()
    if not IsInGroup() then return false end
    if IsInRaid() then
        return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
    end
    return UnitIsGroupLeader("player")
end

function BH:UpdateRaidToolsVisibility()
    if InCombatLockdown() then return end

    local enabled = self.settings and self.settings.raidToolsEnabled
    local preview = self.unlockMode

    if self.markersFrame then
        local inGroup = IsInGroup() or IsInRaid()
        if (enabled and inGroup and (self.settings.raidToolsShowMarkers ~= false)) or preview then
            self.markersFrame:Show()
        else
            self.markersFrame:Hide()
        end
    end
    if self.pullReadyFrame then
        -- In a raid, ready check and pull timer require leader/assist.
        -- In a 5-man party, any member can use ready check.
        local canUse
        if IsInRaid() then
            canUse = IsLeaderOrAssist()
        else
            canUse = IsInGroup()
        end
        if (enabled and canUse and (self.settings.raidToolsShowPullReady ~= false)) or preview then
            self.pullReadyFrame:Show()
        else
            self.pullReadyFrame:Hide()
        end
    end

    -- Preview mode overlays
    if preview then
        -- One call now covers every movable frame: tint, mouse, movable, show.
        -- See MOVABLE_FRAMES for the list and why it is a list.
        self:UpdateFrameLock()
        self:SetAllFramesPreview(true)

        -- Role CC has two toggles rather than one enabled key, so it decides
        -- for itself whether there is anything to preview.
        self:UpdateRoleCCFrame()

        -- Repair shows a sample percentage so the frame is not empty.
        if self.repairReminderFrame and self.repairReminderFrame:IsShown() and self.repairReminderText then
            self.repairReminderText:SetText("REPAIR (15%)")
        end

        -- Frames that draw their own sample content in preview. Showing the
        -- frame is not enough for these -- the death tally would sit there
        -- empty without its placeholder names.
        self:UpdateDeathTallyDisplay()
        if self.UpdateBresCounter then self:UpdateBresCounter() end

        -- Show CDM group previews.
        --
        -- pcall because the unlock control is shown immediately below, and it
        -- is the only way back out of unlock mode: an error raised here would
        -- skip it, leaving the player unlocked with no Done button and no
        -- visible cause. SetUnlockMode has already set self.unlockMode = true by
        -- this point, so its own `if self.unlockMode == on then return end`
        -- guard makes a second attempt a no-op -- the mode sticks until a
        -- reload. Losing the green boxes for one group beats losing the exit.
        if self.cdm and self.cdm.ShowPreview then
            local ok, err = pcall(self.cdm.ShowPreview, self.cdm)
            if not ok then
                print("|cffff6666Squizzumables:|r could not draw the Cooldown Manager "
                    .. "drag regions: " .. tostring(err))
            end
        end

        -- Show the unlock control. It is free-floating and remembers where it
        -- was left: it used to be re-anchored to the options panel every time,
        -- which meant it jumped back beside the panel on each toggle and could
        -- not be parked somewhere out of the way.
        if self.previewControlFrame then
            self:LoadUnlockControlPosition()
            self.previewControlFrame:Show()
        end
    else
        -- Leaving preview: drop every tint, then let each frame's own updater
        -- decide whether it should still be on screen and whether its lock
        -- allows dragging. SetAllFramesPreview(false) only clears the overlays;
        -- it deliberately does not hide or show anything, because that is the
        -- updaters' job.
        self:SetAllFramesPreview(false)

        if self.bresCounterFrame and not BH.BresTrackingActive() then
            self.bresCounterFrame:Hide()
        end
        if self.deathTallyFrame then
            self:UpdateDeathTallyDisplay()
        end

        -- Restore per-frame mouse state from each frame's own lock setting.
        -- Driven from the registry rather than one block per reminder.
        for _, def in ipairs(BH.REMINDERS) do
            local frame = self[def.key .. "ReminderFrame"]
            if frame then
                local locked = self.settings and self.settings[def.key .. "ReminderLocked"]
                frame:EnableMouse(self:ReminderMouseEnabled(locked))
            end
        end
        if self.bresCounterFrame then
            local locked = self.settings and self.settings.bresCounterLocked
            self.bresCounterFrame:EnableMouse(not locked)
        end

        -- Re-evaluate anything preview may have shown or relabelled.
        self:UpdateAllReminders()
        if self.cdm and self.cdm.HidePreview then
            self.cdm:HidePreview()
        end

        self:UpdateFrameLock()
        -- Drag handles follow their frame's lock again.
        if self.markersDragHandle then
            if self.settings and self.settings.raidToolsMarkersLocked then
                self.markersDragHandle:Hide()
            else
                self.markersDragHandle:Show()
            end
        end
        if self.pullReadyDragHandle then
            if self.settings and self.settings.raidToolsPullReadyLocked then
                self.pullReadyDragHandle:Hide()
            else
                self.pullReadyDragHandle:Show()
            end
        end
        -- Hide preview control frame
        if self.previewControlFrame then self.previewControlFrame:Hide() end
    end
end

function BH:UpdateMarkersLayout()
    local mf = self.markersFrame
    if not mf then return end

    local s = self.settings or {}
    local layout = s.raidToolsMarkersLayout or "HORIZONTAL"
    local grow   = s.raidToolsMarkersGrow or "LEFT"

    local markerSize    = 20
    local markerSpacing = 2
    local pad           = 4
    local numBtns       = 9 -- 8 markers + 1 clear per row

    local allBtns = {
        { btns = self.rtWorldMarkerBtns,   clear = self.rtWorldClearBtn },
        { btns = self.rtTargetMarkerBtns,  clear = self.rtTargetClearBtn },
    }

    if layout == "VERTICAL" then
        -- Vertical: each row becomes a column
        -- grow UP: columns go upward from anchor, grow DOWN: columns go downward
        local colWidth  = markerSize + markerSpacing
        local frameW    = 2 * markerSize + markerSpacing + pad * 2
        local frameH    = numBtns * markerSize + (numBtns - 1) * markerSpacing + pad * 2
        mf:SetSize(frameW, frameH)

        for rowIdx, row in ipairs(allBtns) do
            local colOff = pad + (rowIdx - 1) * colWidth
            for i = 1, 8 do
                local btn = row.btns[i]
                if btn then
                    btn:ClearAllPoints()
                    local idx = i
                    if grow == "UP" then idx = 10 - i end  -- reverse order for UP (slots 2-9, clear at 1)
                    btn:SetPoint("TOPLEFT", mf, "TOPLEFT", colOff, -(pad + (idx - 1) * (markerSize + markerSpacing)))
                end
            end
            if row.clear then
                row.clear:ClearAllPoints()
                local clearIdx = 9
                if grow == "UP" then clearIdx = 1 end  -- clear at top for UP (first slot)
                row.clear:SetPoint("TOPLEFT", mf, "TOPLEFT", colOff, -(pad + (clearIdx - 1) * (markerSize + markerSpacing)))
            end
        end
    else
        -- Horizontal
        local rowHeight = markerSize + markerSpacing
        local frameW    = numBtns * markerSize + (numBtns - 1) * markerSpacing + pad * 2
        local frameH    = 2 * markerSize + markerSpacing + pad * 2
        mf:SetSize(frameW, frameH)

        local reversed = (grow == "RIGHT")

        for rowIdx, row in ipairs(allBtns) do
            local rowOff = -(pad + (rowIdx - 1) * rowHeight)
            for i = 1, 8 do
                local btn = row.btns[i]
                if btn then
                    btn:ClearAllPoints()
                    local idx = i
                    if reversed then idx = 10 - i end  -- reverse button order (slots 2-9, clear at 1)
                    btn:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + (idx - 1) * (markerSize + markerSpacing), rowOff)
                end
            end
            if row.clear then
                row.clear:ClearAllPoints()
                local clearIdx = 9
                if reversed then clearIdx = 1 end  -- clear at start for reversed
                row.clear:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + (clearIdx - 1) * (markerSize + markerSpacing), rowOff)
            end
        end
    end

    -- Update drag handle position
    if self.markersDragHandle then
        self.markersDragHandle:ClearAllPoints()
        self.markersDragHandle:SetPoint("BOTTOMLEFT", mf, "TOPLEFT", 0, 2)
    end
end

function BH:CreateRaidToolsFrame()
    if self.markersFrame then return end

    local markerSize = 20
    local markerSpacing = 2
    local pad = 4
    -- 9 buttons per row (8 markers + 1 clear), 2 rows (world + target)
    local rowWidth = 9 * markerSize + 8 * markerSpacing
    local frameWidth = rowWidth + pad * 2
    local frameHeight = 2 * markerSize + markerSpacing + pad * 2

    -- ========================================================================
    -- MARKERS FRAME (world markers + target markers)
    -- ========================================================================
    local mf = CreateFrame("Frame", "SQUIZZUMABLESMarkers", UIParent, "SecureFrameTemplate,BackdropTemplate")
    mf:SetSize(frameWidth, frameHeight)
    mf:SetPoint("BOTTOMRIGHT", UIParent, "CENTER", 0, 0)
    mf:SetFrameStrata("MEDIUM")
    mf:SetMovable(true)
    mf:SetClampedToScreen(true)
    mf:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    mf:SetBackdropColor(ns.Theme.RGBA("panel"))
    mf:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.6)
    mf:EnableMouse(true)
    mf:RegisterForDrag("LeftButton")
    mf:SetScript("OnDragStart", function()
        if not (BH.settings and BH.settings.raidToolsMarkersLocked) or BH.unlockMode then
            BH:GridStartMoving(mf)
            mf:SetUserPlaced(false)
        end
    end)
    mf:SetScript("OnDragStop", function()
        BH:GridStopMoving(mf)
        BH:SaveMarkersPosition()
    end)
    mf:Hide()
    self.markersFrame = mf

    -- Drag handle for markers frame
    local mfDrag = CreateFrame("Frame", nil, mf, "BackdropTemplate")
    mfDrag:SetSize(20, 12)
    mfDrag:SetPoint("BOTTOMLEFT", mf, "TOPLEFT", 0, 2)
    mfDrag:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    mfDrag:SetBackdropColor(ns.Theme.RGBA("handle"))
    mfDrag:SetBackdropBorderColor(ns.Theme.RGBA("handleBorder"))
    mfDrag:EnableMouse(true)
    mfDrag:RegisterForDrag("LeftButton")
    mfDrag:SetScript("OnDragStart", function()
        if not (BH.settings and BH.settings.raidToolsMarkersLocked) or BH.unlockMode then
            BH:GridStartMoving(mf)
            mf:SetUserPlaced(false)
        end
    end)
    mfDrag:SetScript("OnDragStop", function()
        BH:GridStopMoving(mf)
        BH:SaveMarkersPosition()
    end)
    if self.settings and self.settings.raidToolsMarkersLocked then
        mfDrag:Hide()
    end
    self.markersDragHandle = mfDrag

    -- World marker index mapping (Cell addon order)
    local worldMarkerIndices = {5, 6, 3, 2, 7, 1, 4, 8}

    -- World marker buttons (top row)
    self.rtWorldMarkerBtns = {}
    for i = 1, 8 do
        local btn = CreateFrame("Button", "SQUIZZUMABLESWorldMarker" .. i, mf, "SecureActionButtonTemplate, BackdropTemplate")
        btn:SetSize(markerSize, markerSize)
        local c = WORLD_MARKER_COLORS[i]
        btn:SetAttribute("type", "worldmarker")
        btn:SetAttribute("marker", worldMarkerIndices[i])
        btn:RegisterForClicks(SQ_GetClickEdge("Left"))
        btn:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(c[1], c[2], c[3], 0.35)
        btn:SetBackdropBorderColor(0, 0, 0, 0)
        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetSize(markerSize - 4, markerSize - 4)
        tex:SetPoint("CENTER")
        tex:SetColorTexture(c[1], c[2], c[3], 0.8)
        btn.colorTex = tex
        btn:SetScript("OnEnter", function(self) self:SetBackdropColor(c[1], c[2], c[3], 0.6) end)
        btn:SetScript("OnLeave", function(self) self:SetBackdropColor(c[1], c[2], c[3], 0.35) end)
        btn:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + (i - 1) * (markerSize + markerSpacing), -pad)
        self.rtWorldMarkerBtns[i] = btn
    end

    -- Clear-all world marker button
    local clearWM = CreateFrame("Button", "SQUIZZUMABLESWorldMarkerClear", mf, "SecureActionButtonTemplate, BackdropTemplate")
    clearWM:SetSize(markerSize, markerSize)
    clearWM:SetAttribute("type", "worldmarker")
    clearWM:SetAttribute("action", "clear")
    clearWM:RegisterForClicks(SQ_GetClickEdge("Left"))
    clearWM:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    clearWM:SetBackdropColor(ns.Theme.RGBA("panelButton"))
    clearWM:SetBackdropBorderColor(0, 0, 0, 0)
    local clearWMTex = clearWM:CreateTexture(nil, "ARTWORK")
    clearWMTex:SetSize(markerSize - 4, markerSize - 4)
    clearWMTex:SetPoint("CENTER")
    clearWMTex:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
    clearWMTex:SetVertexColor(ns.Theme.RGBA("panelBadIcon"))
    clearWM:SetScript("OnEnter", function(self) self:SetBackdropColor(ns.Theme.RGBA("panelButtonBad")) end)
    clearWM:SetScript("OnLeave", function(self) self:SetBackdropColor(ns.Theme.RGBA("panelButton")) end)
    clearWM:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + 8 * (markerSize + markerSpacing), -pad)
    self.rtWorldClearBtn = clearWM

    -- Target marker buttons (bottom row)
    self.rtTargetMarkerBtns = {}
    for i = 1, 8 do
        local btn = CreateFrame("Button", "SQUIZZUMABLESTargetMarker" .. i, mf, "SecureActionButtonTemplate, BackdropTemplate")
        btn:SetSize(markerSize, markerSize)
        btn:SetAttribute("type1", "raidtarget")
        btn:SetAttribute("action1", "toggle")
        btn:SetAttribute("marker", i)
        btn:RegisterForClicks(SQ_GetClickEdge())
        btn:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(ns.Theme.RGBA("panelButton"))
        btn:SetBackdropBorderColor(0, 0, 0, 0)
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetSize(markerSize - 4, markerSize - 4)
        icon:SetPoint("CENTER")
        icon:SetTexture(TARGET_MARKER_TEXTURES[i])
        btn:SetScript("OnEnter", function(self) self:SetBackdropColor(ns.Theme.RGBA("panelButtonHi")) end)
        btn:SetScript("OnLeave", function(self) self:SetBackdropColor(ns.Theme.RGBA("panelButton")) end)
        btn:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + (i - 1) * (markerSize + markerSpacing), -(pad + markerSize + markerSpacing))
        self.rtTargetMarkerBtns[i] = btn
    end

    -- Clear-all target marker button (matches SquizzUI: type=raidtarget, action=clear-all)
    local clearTM = CreateFrame("Button", "SQUIZZUMABLESTargetMarkerClear", mf, "SecureActionButtonTemplate, BackdropTemplate")
    clearTM:SetSize(markerSize, markerSize)
    clearTM:SetAttribute("type", "raidtarget")
    clearTM:SetAttribute("action", "clear-all")
    clearTM:RegisterForClicks(SQ_GetClickEdge())
    clearTM:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    clearTM:SetBackdropColor(ns.Theme.RGBA("panelButton"))
    clearTM:SetBackdropBorderColor(0, 0, 0, 0)
    local clearTMTex = clearTM:CreateTexture(nil, "ARTWORK")
    clearTMTex:SetSize(markerSize - 4, markerSize - 4)
    clearTMTex:SetPoint("CENTER")
    clearTMTex:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
    clearTMTex:SetVertexColor(ns.Theme.RGBA("panelBadIcon"))
    clearTM:SetScript("OnEnter", function(self) self:SetBackdropColor(ns.Theme.RGBA("panelButtonBad")) end)
    clearTM:SetScript("OnLeave", function(self) self:SetBackdropColor(ns.Theme.RGBA("panelButton")) end)
    clearTM:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + 8 * (markerSize + markerSpacing), -(pad + markerSize + markerSpacing))
    self.rtTargetClearBtn = clearTM

    -- Apply markers layout from settings
    self:UpdateMarkersLayout()



    -- ========================================================================
    -- PULL/READY FRAME (ready check + pull timer) - vertical layout
    -- ========================================================================
    local btnWidth = 90
    local btnHeight = 22
    local btnSpacing = 2
    local prPad = 4
    local prWidth = btnWidth + prPad * 2
    local prHeight = 2 * btnHeight + btnSpacing + prPad * 2

    local prf = CreateFrame("Frame", "SQUIZZUMABLESPullReady", UIParent, "SecureFrameTemplate,BackdropTemplate")
    prf:SetSize(prWidth, prHeight)
    prf:SetPoint("RIGHT", mf, "LEFT", -2, 0)
    prf:SetFrameStrata("MEDIUM")
    prf:SetMovable(true)
    prf:SetClampedToScreen(true)
    prf:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    prf:SetBackdropColor(ns.Theme.RGBA("panel"))
    prf:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.6)
    prf:EnableMouse(true)
    prf:RegisterForDrag("LeftButton")
    prf:SetScript("OnDragStart", function()
        if not (BH.settings and BH.settings.raidToolsPullReadyLocked) or BH.unlockMode then
            BH:GridStartMoving(prf)
            prf:SetUserPlaced(false)
        end
    end)
    prf:SetScript("OnDragStop", function()
        BH:GridStopMoving(prf)
        BH:SavePullReadyPosition()
    end)
    prf:Hide()
    self.pullReadyFrame = prf

    -- Drag handle for pull/ready frame
    local prfDrag = CreateFrame("Frame", nil, prf, "BackdropTemplate")
    prfDrag:SetSize(20, 12)
    prfDrag:SetPoint("BOTTOMLEFT", prf, "TOPLEFT", 0, 2)
    prfDrag:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    prfDrag:SetBackdropColor(ns.Theme.RGBA("handle"))
    prfDrag:SetBackdropBorderColor(ns.Theme.RGBA("handleBorder"))
    prfDrag:EnableMouse(true)
    prfDrag:RegisterForDrag("LeftButton")
    prfDrag:SetScript("OnDragStart", function()
        if not (BH.settings and BH.settings.raidToolsPullReadyLocked) or BH.unlockMode then
            BH:GridStartMoving(prf)
            prf:SetUserPlaced(false)
        end
    end)
    prfDrag:SetScript("OnDragStop", function()
        BH:GridStopMoving(prf)
        BH:SavePullReadyPosition()
    end)
    if self.settings and self.settings.raidToolsPullReadyLocked then
        prfDrag:Hide()
    end
    self.pullReadyDragHandle = prfDrag

    -- Ready Check button
    -- Plain button + OnClick → DoReadyCheck() matches SquizzUI exactly.
    -- DoReadyCheck() is a protected function but is callable from a hardware-event
    -- OnClick handler (player physically clicking the button).
    local readyBtn = CreateFrame("Button", "SQUIZZUMABLESReadyCheck", prf, "BackdropTemplate")
    readyBtn:SetSize(btnWidth, btnHeight)
    readyBtn:RegisterForClicks("LeftButtonDown")
    readyBtn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            DoReadyCheck()
        end
    end)
    readyBtn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    readyBtn:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
    do local ar, ag, ab = ns.GetAccentColor("dim"); readyBtn:SetBackdropBorderColor(ar, ag, ab, 0.6) end
    local readyLabel = readyBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    readyLabel:SetPoint("CENTER")
    readyLabel:SetText("Ready Check")
    ns.ApplyAccent(readyLabel, "text")
    readyBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 1)
        do local ar, ag, ab = ns.GetAccentColor(); self:SetBackdropBorderColor(ar, ag, ab, 1) end
    end)
    readyBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        do local ar, ag, ab = ns.GetAccentColor("dim"); self:SetBackdropBorderColor(ar, ag, ab, 0.6) end
    end)
    readyBtn:SetPoint("TOPLEFT", prf, "TOPLEFT", prPad, -prPad)
    self.rtReadyBtn = readyBtn

    -- Pull Timer button
    local pullBtn = CreateFrame("Button", "SQUIZZUMABLESPullTimer", prf, "BackdropTemplate")
    pullBtn:SetSize(btnWidth, btnHeight)
    pullBtn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    pullBtn:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
    do local ar, ag, ab = ns.GetAccentColor("dim"); pullBtn:SetBackdropBorderColor(ar, ag, ab, 0.6) end
    pullBtn.label = pullBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pullBtn.label:SetPoint("CENTER")
    local pullDuration = (self.settings and self.settings.raidToolsPullTimer) or 10
    pullBtn.label:SetText("Pull " .. pullDuration .. "s")
    ns.ApplyAccent(pullBtn.label, "text")
    pullBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 1)
        do local ar, ag, ab = ns.GetAccentColor(); self:SetBackdropBorderColor(ar, ag, ab, 1) end
    end)
    pullBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        do local ar, ag, ab = ns.GetAccentColor("dim"); self:SetBackdropBorderColor(ar, ag, ab, 0.6) end
    end)
    self.rtPullActive = false
    pullBtn:SetScript("OnClick", function()
        if IsLeaderOrAssist() then
            if BH.rtPullActive then
                C_PartyInfo.DoCountdown(0)
                BH.rtPullActive = false
                local d = (BH.settings and BH.settings.raidToolsPullTimer) or 10
                pullBtn.label:SetText("Pull " .. d .. "s")
            else
                local d = (BH.settings and BH.settings.raidToolsPullTimer) or 10
                C_PartyInfo.DoCountdown(d)
                BH.rtPullActive = true
                pullBtn.label:SetText("Cancel")
                C_Timer.After(d, function()
                    BH.rtPullActive = false
                    if BH.rtPullBtn then
                        local dur = (BH.settings and BH.settings.raidToolsPullTimer) or 10
                        BH.rtPullBtn.label:SetText("Pull " .. dur .. "s")
                    end
                end)
            end
        end
    end)
    pullBtn:SetPoint("TOPLEFT", readyBtn, "BOTTOMLEFT", 0, -btnSpacing)
    self.rtPullBtn = pullBtn

    -- Apply saved scale to frames
    local mScale = (self.settings and self.settings.raidToolsMarkersScale) or 1.0
    local prScale = (self.settings and self.settings.raidToolsPullReadyScale) or 1.0
    mf:SetScale(mScale)
    prf:SetScale(prScale)

    -- ========================================================================
    -- PREVIEW CONTROL FRAME (close/lock buttons - shown during preview mode)
    -- ========================================================================
    local pcf = CreateFrame("Frame", "SQUIZZUMABLESPreviewControl", UIParent, "BackdropTemplate")
    pcf:SetSize(160, 60)
    pcf:SetPoint("TOPLEFT", UIParent, "CENTER", 0, 0)
    pcf:SetFrameStrata("DIALOG")
    pcf:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    pcf:SetBackdropColor(ns.Theme.RGBA("panelSolid"))
    pcf:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
    pcf:EnableMouse(true)
    pcf:SetMovable(true)
    pcf:SetClampedToScreen(true)
    pcf:RegisterForDrag("LeftButton")
    pcf:SetScript("OnDragStart", function() pcf:StartMoving() end)
    pcf:SetScript("OnDragStop", function()
        pcf:StopMovingOrSizing()
        BH:SaveUnlockControlPosition()
    end)

    local pcfTitle = pcf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pcfTitle:SetPoint("TOP", pcf, "TOP", 0, -6)
    pcfTitle:SetText("Frames Unlocked")
    pcfTitle:SetTextColor(ns.Theme.RGBA("panelTitle"))

    local lockBtn = CreateSQButton(pcf, "Lock All", 68, 22)
    lockBtn:SetPoint("BOTTOMLEFT", pcf, "BOTTOMLEFT", 6, 6)
    lockBtn:SetScript("OnClick", function()
        -- Driven off the registries rather than a hand-written list.
        --
        -- It was a hand-written list, and it had fallen behind by five: the
        -- Coach's Whistle, pet, role CC, augment rune and healthstone frames
        -- were never in it, so "Lock All" quietly left them unlocked. Nothing
        -- announced that -- the button said it had locked everything.
        for _, def in ipairs(BH.REMINDERS) do
            BH.settings[def.key .. "ReminderLocked"] = true
        end
        BH.settings.raidToolsMarkersLocked = true
        BH.settings.raidToolsPullReadyLocked = true
        BH.settings.bresCounterLocked = true
        BH.settings.deathTallyLocked = true
        -- No kelAlertLocked here: the Kelert image has no lock setting any
        -- more. It never takes the mouse outside Unlock Frames, so there is
        -- nothing for Lock All to switch off. Do not reintroduce the key --
        -- writing a setting nothing reads is how the bag reminder's toggle
        -- went quietly dead.
        BH.settings.frameLocked = true
        BH:SaveSettings()
        -- Lock CDM groups
        if BH.cdm and BH.cdm.LockAll then
            BH.cdm:LockAll()
        end

        -- Apply to the live frames, from the same list preview mode uses, so a
        -- frame can never be previewable but not lockable.
        for _, def in ipairs(BH.MOVABLE_FRAMES or {}) do
            local f = BH[def.field]
            if f then
                f:SetMovable(false)
                f:EnableMouse(false)
            end
        end
        if BH.kelAlertFrame then
            BH.kelAlertFrame:SetMovable(false)
            BH.kelAlertFrame:EnableMouse(false)
        end
        BH:UpdateFrameLock()
        -- Options panel checkboxes used to be pushed one by one here. Every
        -- lock is a declarative row now and reads its own value back, so the
        -- RefreshAll below covers them -- including any added later.
        ns.Rows.RefreshAll()
        print("Squizzumables: All frames locked")
        -- Locking everything means the player is finished positioning, so leave
        -- unlock mode too. Otherwise the locks appear to do nothing, because
        -- unlock mode overrides them.
        BH:SetUnlockMode(false)
    end)

    local closeBtn = CreateSQButton(pcf, "Done", 68, 22)
    closeBtn:SetPoint("BOTTOMRIGHT", pcf, "BOTTOMRIGHT", -6, 6)
    closeBtn:SetScript("OnClick", function()
        BH:SetUnlockMode(false)
    end)

    pcf:Hide()
    self.previewControlFrame = pcf

end

-- === Instance Sound Detection ===
local INSTANCE_SOUNDS = {
    { instanceID = 1209, difficultyID = 23, soundID = 46004 },  -- Skyreach Mythic
}

function BH:CheckInstanceSound()
    if not self.settings or not self.settings.skyreachSoundEnabled then return end
    ---@diagnostic disable-next-line: undefined-global
    local _, _, difficultyID, _, _, _, _, instanceID = GetInstanceInfo()
    for _, entry in ipairs(INSTANCE_SOUNDS) do
        if instanceID == entry.instanceID and difficultyID == entry.difficultyID then
            ---@diagnostic disable-next-line: undefined-global
            PlaySound(entry.soundID, "Master")
            return
        end
    end
end


-- ============================================================================
-- Raid Tools Settings Tab
-- ============================================================================

function BH:BuildRaidToolsTab(parent)
    -- Six unrelated sections in one scroll had become the problem this page
    -- was, so each is now its own sub-tab. `content` is reassigned at every
    -- boundary below; the row calls themselves are unchanged.
    local pages = ns.SubTabs.Create(parent, {
        { key = "general",  label = "General" },
        { key = "pull",     label = "Pull Timer" },
        { key = "scale",    label = "Scale" },
        { key = "bres",     label = "Battle Res" },
        { key = "distance", label = "Target Distance" },
        { key = "position", label = "Position" },
    })

    local content = pages.general
    ns.Rows.currentSection = content.section

    local yOffset = -14
    local leftPad = 14

    -- === Module Toggle ===
    local sectionLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sectionLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    sectionLabel:SetText("MODULE")
    ns.ApplyAccent(sectionLabel, "text")
    yOffset = yOffset - 22

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Enable Raid Tools",
        tooltip = "Master switch for the raid marker and pull timer frames. Turning this off hides both regardless of their own settings.",
        get = function() return BH.settings.raidToolsEnabled ~= false end,
        set = function(v)
            BH.settings.raidToolsEnabled = v
            BH:SaveSettings()
            BH:UpdateRaidToolsVisibility()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "text",
        label = "Two movable frames: a compact markers frame (world + target markers) and a pull/ready frame (ready check + pull timer). Only visible when you are the group leader or assistant.",
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "FRAMES" })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show Markers Frame",
        tooltip = "Shows the world marker and target marker buttons. Only usable while you are group leader or an assistant.",
        get = function() return BH.settings.raidToolsShowMarkers ~= false end,
        set = function(v)
            BH.settings.raidToolsShowMarkers = v
            BH:SaveSettings()
            BH:UpdateRaidToolsVisibility()
        end,
        -- Every frame here is gated on the master switch above, so grey them
        -- out rather than letting the player set something with no effect.
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show Pull/Ready Frame",
        tooltip = "Shows the pull timer and ready check buttons. Only usable while you are group leader or an assistant.",
        get = function() return BH.settings.raidToolsShowPullReady ~= false end,
        set = function(v)
            BH.settings.raidToolsShowPullReady = v
            BH:SaveSettings()
            BH:UpdateRaidToolsVisibility()
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })


    -- === Markers Layout ===
    local layoutLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    layoutLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    layoutLabel:SetText("MARKERS LAYOUT")
    ns.ApplyAccent(layoutLabel, "text")
    yOffset = yOffset - 22

    local function GetMarkersGrowItems()
        if BH.settings.raidToolsMarkersLayout == "VERTICAL" then
            return {
                { text = "Down", value = "DOWN" },
                { text = "Up",   value = "UP" },
            }
        end
        return {
            { text = "Left",  value = "LEFT" },
            { text = "Right", value = "RIGHT" },
        }
    end

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Layout Direction",
        width = 200,
        tooltip = "Whether the marker buttons lay out in a row or a column.",
        items = {
            { text = "Horizontal", value = "HORIZONTAL" },
            { text = "Vertical",   value = "VERTICAL" },
        },
        get = function() return BH.settings.raidToolsMarkersLayout or "HORIZONTAL" end,
        set = function(v)
            BH.settings.raidToolsMarkersLayout = v
            -- The old grow direction may not exist in the new layout, so reset
            -- it. The grow dropdown below rebuilds its own options from this
            -- value on the refresh that follows.
            BH.settings.raidToolsMarkersGrow = (v == "VERTICAL") and "DOWN" or "LEFT"
            BH:SaveSettings()
            BH:UpdateMarkersLayout()
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Grow Direction",
        width = 200,
        tooltip = "Which way the marker buttons extend from their anchor.",
        -- A function, so the options follow the layout above automatically
        -- instead of the layout dropdown having to reach over and rewrite them.
        items = GetMarkersGrowItems,
        get = function() return BH.settings.raidToolsMarkersGrow or "LEFT" end,
        set = function(v)
            BH.settings.raidToolsMarkersGrow = v
            BH:SaveSettings()
            BH:UpdateMarkersLayout()
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    -- Sub-tab boundary: size the page just finished, then move to the next.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.pull
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Countdown Duration (seconds)",
        width = 300, min = 3, max = 30, step = 1,
        tooltip = "How long the pull timer counts down for when you start one.",
        get = function() return BH.settings.raidToolsPullTimer or 10 end,
        set = function(value)
            BH.settings.raidToolsPullTimer = value
            BH:SaveSettings()
            if BH.rtPullBtn and not BH.rtPullActive then
                BH.rtPullBtn.label:SetText("Pull " .. value .. "s")
            end
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show on encounter timeline",
        tooltip = "Adds the pull countdown to Blizzard's encounter timeline, alongside boss abilities. "
               .. "Works for a pull started by anyone in the group, not just your own button. "
               .. "Needs the encounter timeline itself to be turned on in Blizzard's settings.",
        get = function() return BH.settings.timelinePullTimer ~= false end,
        set = function(v)
            BH.settings.timelinePullTimer = v
            BH:SaveSettings()
            if not v and BH.Timeline then BH.Timeline.Stop("pull") end
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "text",
        indent = 18,
        width = 370,
        label = "The timeline may only draw during an encounter, in which case a pre-pull countdown will not appear.",
    })

    -- Sub-tab boundary: size the page just finished, then move to the next.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.scale
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Markers Frame Scale",
        width = 300, min = 50, max = 200, step = 5,
        tooltip = "Size of the marker button frame, as a percentage.",
        get = function() return (BH.settings.raidToolsMarkersScale or 1.0) * 100 end,
        set = function(value, userInput)
            BH.settings.raidToolsMarkersScale = value / 100
            BH:SaveSettings()
            if userInput and BH.markersFrame then
                BH.markersFrame:SetScale(value / 100)
            end
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Pull/Ready Frame Scale",
        width = 300, min = 50, max = 200, step = 5,
        tooltip = "Size of the pull timer and ready check frame, as a percentage.",
        get = function() return (BH.settings.raidToolsPullReadyScale or 1.0) * 100 end,
        set = function(value, userInput)
            BH.settings.raidToolsPullReadyScale = value / 100
            BH:SaveSettings()
            if userInput and BH.pullReadyFrame then
                BH.pullReadyFrame:SetScale(value / 100)
            end
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    -- Sub-tab boundary: size the page just finished, then move to the next.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.bres
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Enable Battle Res Counter",
        tooltip = "Shows how many battle resurrection charges the group has left. Only appears in content that grants charges.",
        get = function() return BH.settings.bresCounterEnabled and true or false end,
        set = function(v)
            BH.settings.bresCounterEnabled = v
            BH:SaveSettings()
            if not v and BH.bresCounterFrame then
                BH.bresCounterFrame:Hide()
            end
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Battle Res Counter Scale",
        width = 300, min = 50, max = 200, step = 5,
        tooltip = "Size of the battle res counter, as a percentage.",
        get = function() return (BH.settings.bresCounterScale or 1.0) * 100 end,
        set = function(value, userInput)
            BH.settings.bresCounterScale = value / 100
            BH:SaveSettings()
            if userInput and BH.bresCounterFrame then
                BH.bresCounterFrame:SetScale(value / 100)
            end
        end,
        disabled = function() return not BH.settings.bresCounterEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Lock Battle Res Counter",
        tooltip = "Stops the battle res counter being dragged.",
        get = function() return BH.settings.bresCounterLocked and true or false end,
        set = function(v)
            BH.settings.bresCounterLocked = v
            BH:SaveSettings()
            if BH.bresCounterFrame then
                BH.bresCounterFrame:SetMovable(not v)
                BH.bresCounterFrame:EnableMouse(not v)
            end
        end,
        disabled = function() return not BH.settings.bresCounterEnabled end,
    })

    -- Sub-tab boundary: size the page just finished, then move to the next.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.distance
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show Target Distance",
        tooltip = "Shows roughly how far away your target is, as movable text. "
            .. "It reads as a band (\"30-35\") rather than a single number because the game gives "
            .. "addons no way to measure distance -- only to ask whether a spell or item would "
            .. "reach. Position it with Unlock Frames.",
        get = function() return BH.settings.targetDistanceEnabled and true or false end,
        set = function(v)
            BH.settings.targetDistanceEnabled = v
            BH:SaveSettings()
            BH:ApplyTargetDistance()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Distance Format",
        width = 160,
        tooltip = "How the estimate reads. The band is the honest one; the other two pick an end of it.",
        items = BH.TARGET_DISTANCE_FORMATS,
        get = function() return BH.settings.targetDistanceFormat or "band" end,
        set = function(value)
            BH.settings.targetDistanceFormat = value
            BH:SaveSettings()
            BH:UpdateTargetDistance()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Text Align",
        width = 160,
        tooltip = "Alignment of the distance text within its frame.",
        items = BH.TARGET_DISTANCE_ALIGNMENTS,
        get = function() return BH.settings.targetDistanceAlign or "CENTER" end,
        set = function(value)
            BH.settings.targetDistanceAlign = value
            BH:SaveSettings()
            BH:ApplyTargetDistanceStyle()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Distance Text Size",
        width = 300, min = 8, max = 48, step = 1,
        tooltip = "Font size of the distance text.",
        get = function() return BH.settings.targetDistanceTextSize or 18 end,
        set = function(value)
            BH.settings.targetDistanceTextSize = value
            BH:SaveSettings()
            BH:ApplyTargetDistanceStyle()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Frame Strata",
        width = 160,
        tooltip = "How far in front of other frames the distance text sits. Raise it if something covers it.",
        items = BH.TARGET_DISTANCE_STRATAS,
        get = function() return BH.settings.targetDistanceStrata or "HIGH" end,
        set = function(value)
            BH.settings.targetDistanceStrata = value
            BH:SaveSettings()
            BH:ApplyTargetDistanceStyle()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "color",
        label = "Distance Text Colour",
        tooltip = "Colour of the distance text.",
        get = function()
            local c = BH.settings.targetDistanceColor or {}
            return c.r or 1, c.g or 1, c.b or 1
        end,
        set = function(r, g, b)
            BH.settings.targetDistanceColor = { r = r, g = g, b = b }
            BH:SaveSettings()
            BH:ApplyTargetDistanceStyle()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Also Show For Friendly Targets",
        tooltip = "Off by default, and it will often read \"?\" when on. The estimate is built from "
            .. "harmful spells and items, and those refuse to answer about a friendly unit -- so "
            .. "there is frequently nothing to go on.",
        get = function() return BH.settings.targetDistanceFriendly and true or false end,
        set = function(v)
            BH.settings.targetDistanceFriendly = v
            BH:SaveSettings()
            BH:UpdateTargetDistance()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    -- Sub-tab boundary: size the page just finished, then move to the next.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.position
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Lock Markers Frame",
        tooltip = "Stops the marker frame being dragged.",
        get = function() return BH.settings.raidToolsMarkersLocked and true or false end,
        set = function(v)
            BH.settings.raidToolsMarkersLocked = v
            BH:SaveSettings()
            if BH.markersFrame then
                BH.markersFrame:SetMovable(not v)
            end
            if BH.markersDragHandle then
                if v then BH.markersDragHandle:Hide() else BH.markersDragHandle:Show() end
            end
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Lock Pull/Ready Frame",
        tooltip = "Stops the pull timer frame being dragged.",
        get = function() return BH.settings.raidToolsPullReadyLocked and true or false end,
        set = function(v)
            BH.settings.raidToolsPullReadyLocked = v
            BH:SaveSettings()
            if BH.pullReadyFrame then
                BH.pullReadyFrame:SetMovable(not v)
            end
            if BH.pullReadyDragHandle then
                if v then BH.pullReadyDragHandle:Hide() else BH.pullReadyDragHandle:Show() end
            end
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })


    local resetBtn = CreateSQButton(content, "Reset Positions", 140, 26)
    resetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    resetBtn:SetScript("OnClick", function()
        if BH.markersFrame then
            BH.markersFrame:ClearAllPoints()
            BH.markersFrame:SetPoint("BOTTOMRIGHT", UIParent, "CENTER", 0, 0)
        end
        if BH.pullReadyFrame then
            BH.pullReadyFrame:ClearAllPoints()
            BH.pullReadyFrame:SetPoint("RIGHT", BH.markersFrame, "LEFT", -2, 0)
        end
        if SquizzumablesDB then
            SquizzumablesDB.markersPosition = nil
            SquizzumablesDB.pullReadyPosition = nil
            SquizzumablesDB.beaconReminderPosition = nil
            SquizzumablesDB.earthShieldReminderPosition = nil
            SquizzumablesDB.repairReminderPosition = nil
            SquizzumablesDB.symbioticReminderPosition = nil
            SquizzumablesDB.bresCounterPosition = nil
            SquizzumablesDB.deathTallyPosition = nil
            SquizzumablesDB.coachWhistleReminderPosition = nil
            SquizzumablesDB.bagsReminderPosition = nil
        end
        if BH.beaconReminderFrame then
            BH.beaconReminderFrame:ClearAllPoints()
            BH.beaconReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
        end
        if BH.earthShieldReminderFrame then
            BH.earthShieldReminderFrame:ClearAllPoints()
            BH.earthShieldReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
        end
        if BH.repairReminderFrame then
            BH.repairReminderFrame:ClearAllPoints()
            BH.repairReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
        end
        if BH.symbioticReminderFrame then
            BH.symbioticReminderFrame:ClearAllPoints()
            BH.symbioticReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
        end
        if BH.coachWhistleReminderFrame then
            BH.coachWhistleReminderFrame:ClearAllPoints()
            BH.coachWhistleReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
        end
        if BH.bresCounterFrame then
            BH.bresCounterFrame:ClearAllPoints()
            BH.bresCounterFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
        end
        if BH.deathTallyFrame then
            BH.deathTallyFrame:ClearAllPoints()
            BH.deathTallyFrame:SetPoint("TOP", UIParent, "TOP", 220, -100)
        end
        if BH.bagsReminderFrame then
            BH.bagsReminderFrame:ClearAllPoints()
            BH.bagsReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 240)
        end
        if BH.healerCCReminderFrame then
            BH.healerCCReminderFrame:ClearAllPoints()
            BH.healerCCReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 360)
        end
        -- Reset CDM group positions
        if BH.cdm and BH.cdm.ResetPositions then
            BH.cdm:ResetPositions()
        end
    end)
    yOffset = yOffset - 40

    content:SetHeight(math.abs(yOffset) + 20)
    ns.Rows.currentSection = nil
end

-- Kept as a thin shim: the Raid Tools rows are declarative now, so each one
-- syncs itself from its own get(). The five call sites elsewhere just want
-- "make the panel match the settings", which RefreshAll does for every tab
-- at once.
function BH:RefreshRaidToolsTab()
    ns.Rows.RefreshAll()
end

