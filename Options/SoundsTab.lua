-- Options/SoundsTab.lua
-- The Sounds options page: the bundled sounds, and adding your own files from
-- Squizzumables' sound folder (the custom sounds list).
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split). The
-- sound library itself (LibSharedMedia, the custom sound helpers) stays in the
-- core, which plays sounds for every feature; the names this page uses are
-- published there and re-declared below.

local addonName, ns = ...
local BH = ns.BH

local SQ_COLORS        = ns.SQ_COLORS
local CreateSQButton   = ns.CreateSQButton
local CreateSQEditBox  = ns.CreateSQEditBox
local CreateSQDivider  = ns.CreateSQDivider

local CUSTOM_SOUNDS_PATH      = BH.CUSTOM_SOUNDS_PATH
local CustomSoundNameFromFile = BH.CustomSoundNameFromFile
local CustomSoundPath         = BH.CustomSoundPath
local FindCustomSound         = BH.FindCustomSound
local GetLSM                  = BH.GetLSM
local SQ_BUNDLED_SOUNDS       = BH.SQ_BUNDLED_SOUNDS
local StopCustomSoundTest     = BH.StopCustomSoundTest
local PlayCustomSoundTest     = BH.PlayCustomSoundTest

function BH:RefreshCustomSoundsList()
    if not self.customSoundsListFrame then return end

    -- Rows are cached by list position and refilled; removing an entry shifts
    -- everything up by one, so the labels and the remove handler are re-set on
    -- every pass. Only a longer list than we have ever shown allocates.
    self:ResetWidgetCache("customSoundRowCache")

    local sounds = self.settings and self.settings.customSounds or {}
    local rowY = 0
    for i, entry in ipairs(sounds) do
        local rowFrame, isNew = self:AcquireWidget("customSoundRowCache", i, function()
            local f = CreateFrame("Frame", nil, self.customSoundsListFrame)
            f:SetSize(380, 22)

            f.nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            f.nameLabel:SetPoint("LEFT", f, "LEFT", 0, 0)
            f.nameLabel:SetWidth(140)
            f.nameLabel:SetJustifyH("LEFT")
            f.nameLabel:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])

            f.fileLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            f.fileLabel:SetPoint("LEFT", f, "LEFT", 148, 0)
            f.fileLabel:SetWidth(180)
            f.fileLabel:SetJustifyH("LEFT")
            f.fileLabel:SetTextColor(0.5, 0.5, 0.5)

            -- Same speaker button the bundled sounds have. Custom sounds had
            -- none, so checking one worked meant wiring it to an alert first.
            f.playBtn = CreateFrame("Button", nil, f)
            f.playBtn:SetSize(20, 20)
            f.playBtn:SetPoint("LEFT", f, "LEFT", 332, 0)
            local pNorm = f.playBtn:CreateTexture(nil, "BACKGROUND")
            pNorm:SetAllPoints()
            pNorm:SetTexture("Interface\\Common\\VoiceChat-Speaker")
            local pHi = f.playBtn:CreateTexture(nil, "HIGHLIGHT")
            pHi:SetAllPoints()
            pHi:SetTexture("Interface\\Common\\VoiceChat-Speaker")
            pHi:SetAlpha(0.6)
            f.playBtn:SetScript("OnEnter", function() pNorm:SetAlpha(0.7) end)
            f.playBtn:SetScript("OnLeave", function() pNorm:SetAlpha(1.0) end)

            f.removeBtn = CreateSQButton(f, "X", 22, 18, SQ_COLORS.danger)
            f.removeBtn:SetPoint("LEFT", f, "LEFT", 358, 0)
            return f
        end)
        local _ = isNew

        rowFrame:Show()
        rowFrame:SetPoint("TOPLEFT", self.customSoundsListFrame, "TOPLEFT", 0, rowY)
        rowFrame.nameLabel:SetText(entry.name or "")
        -- An entry from before V1.89 still reads the old folder, which the
        -- next addon update will empty. Say so, so it can be moved in time.
        if entry.dir == "media" then
            rowFrame.fileLabel:SetText(entry.file or "")
        else
            rowFrame.fileLabel:SetText((entry.file or "") .. " |cFFFF8844(old folder)|r")
        end

        local path = CustomSoundPath(entry)
        rowFrame.playBtn:SetScript("OnClick", function()
            PlayCustomSoundTest(path)
        end)

        local idx = i
        rowFrame.removeBtn:SetScript("OnClick", function()
            table.remove(self.settings.customSounds, idx)
            self:SaveSettings()
            self:RefreshCustomSoundsList()
            -- Rebuild Items tab so dropdowns reflect removal
            if self.scrollChild then self:RefreshItemList() end
        end)

        rowY = rowY - 24
    end
    self.customSoundsListFrame:SetHeight(math.abs(rowY) + 4)

    -- The list is the last thing on the page, so the page grows with it.
    if self.customSoundsContent and self.customSoundsListTop then
        self.customSoundsContent:SetHeight(math.abs(self.customSoundsListTop) + math.abs(rowY) + 24)
    end
end

-- ============================================================================
-- Sounds Tab
-- ============================================================================

function BH:BuildSoundsTab(parent)
    local leftPad = 14

    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    ns.TuneScrollStep(scrollFrame)
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(430, 1)
    scrollFrame:SetScrollChild(content)

    local yOffset = -10

    -- === Bundled Sounds ===
    local bundledTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bundledTitle:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    bundledTitle:SetText("BUNDLED SOUNDS")
    ns.ApplyAccent(bundledTitle, "text")
    yOffset = yOffset - 18

    for _, entry in ipairs(SQ_BUNDLED_SOUNDS) do
        local rowFrame = CreateFrame("Frame", nil, content)
        rowFrame:SetSize(410, 22)
        rowFrame:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)

        local nameLabel = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameLabel:SetPoint("LEFT", rowFrame, "LEFT", 0, 0)
        nameLabel:SetWidth(280)
        nameLabel:SetJustifyH("LEFT")
        nameLabel:SetText(entry.name)
        nameLabel:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])

        local unlockBtn = CreateFrame("Button", nil, rowFrame)
        unlockBtn:SetSize(22, 22)
        unlockBtn:SetPoint("LEFT", rowFrame, "LEFT", 286, 0)
        local pNorm = unlockBtn:CreateTexture(nil, "BACKGROUND")
        pNorm:SetAllPoints()
        pNorm:SetTexture("Interface\\Common\\VoiceChat-Speaker")
        local pHi = unlockBtn:CreateTexture(nil, "HIGHLIGHT")
        pHi:SetAllPoints()
        pHi:SetTexture("Interface\\Common\\VoiceChat-Speaker")
        pHi:SetAlpha(0.6)
        unlockBtn:SetScript("OnEnter", function() pNorm:SetAlpha(0.7) end)
        unlockBtn:SetScript("OnLeave", function() pNorm:SetAlpha(1.0) end)
        local soundFile = entry.file
        unlockBtn:SetScript("OnClick", function()
            PlaySoundFile(CUSTOM_SOUNDS_PATH .. soundFile, "Master")
        end)

        yOffset = yOffset - 26
    end

    -- === Custom Sounds ===
    --
    -- Reworked in V1.89. It used to take a display name AND an exact filename,
    -- forced ".ogg" onto anything else (so "song.mp3" became "song.mp3.ogg"
    -- and could never be found), never checked the file existed, ignored a
    -- duplicate name without a word, and kept the files inside the addon's
    -- own folder, which every addon update empties. Now: type the filename,
    -- Test plays it, Add finds it in either folder (new one first) and names
    -- it from the file unless a name is given.
    yOffset = yOffset - 6
    local csDivider = CreateSQDivider(content, yOffset)
    csDivider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    yOffset = yOffset - 18

    local csTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csTitle:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csTitle:SetText("CUSTOM SOUNDS")
    ns.ApplyAccent(csTitle, "text")
    yOffset = yOffset - 18

    local csHint = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csHint:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csHint:SetWidth(400)
    csHint:SetJustifyH("LEFT")
    csHint:SetWordWrap(true)
    csHint:SetText("Put your .ogg or .mp3 files in |cFFFFFF00Interface\\AddOns\\SquizzumablesMedia\\Sounds\\|r"
        .. " - make the folders if they are not there yet. Addon updates never touch that folder, so your sounds stay put."
        .. "\n\nType the filename (the extension is optional), press Test to hear it, then Add."
        .. " If a file you have just copied in is not found, type /reload and try again.")
    csHint:SetTextColor(0.55, 0.55, 0.55)
    -- Floor on the measurement: a page built before it is first shown can
    -- report a string height of 0, which would put the form on the hint.
    yOffset = yOffset - (math.max(csHint:GetStringHeight(), 64) + 12)

    -- Form: filename first, since that is the one thing that has to be right.
    local csFileHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csFileHdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csFileHdr:SetText("Filename")
    csFileHdr:SetTextColor(0.6, 0.6, 0.6)

    local csNameHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csNameHdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 166, yOffset)
    csNameHdr:SetText("Name (optional)")
    csNameHdr:SetTextColor(0.6, 0.6, 0.6)
    yOffset = yOffset - 16

    local csFileEdit = CreateSQEditBox(content, 160, 20, { maxLetters = 128 })
    csFileEdit:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csFileEdit.placeholder = csFileEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csFileEdit.placeholder:SetPoint("LEFT", csFileEdit, "LEFT", 6, 0)
    csFileEdit.placeholder:SetText("my_sound.mp3")
    csFileEdit.placeholder:SetTextColor(0.4, 0.4, 0.4)

    local csNameEdit = CreateSQEditBox(content, 140, 20, { maxLetters = 64 })
    csNameEdit:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 166, yOffset)
    csNameEdit:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
    csNameEdit.placeholder = csNameEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csNameEdit.placeholder:SetPoint("LEFT", csNameEdit, "LEFT", 6, 0)
    csNameEdit.placeholder:SetPoint("RIGHT", csNameEdit, "RIGHT", -6, 0)
    csNameEdit.placeholder:SetJustifyH("LEFT")
    csNameEdit.placeholder:SetWordWrap(false)
    csNameEdit.placeholder:SetTextColor(0.4, 0.4, 0.4)

    -- The name box shows, greyed out, the name the file would get, so leaving
    -- it empty is visibly a choice rather than a missing field.
    local function RefreshPlaceholders()
        local file = csFileEdit:GetText():match("^%s*(.-)%s*$") or ""
        csFileEdit.placeholder:SetShown(csFileEdit:GetText() == "")
        local derived = (file ~= "") and CustomSoundNameFromFile(file) or ""
        csNameEdit.placeholder:SetText(derived ~= "" and derived or "e.g. My Alert")
        csNameEdit.placeholder:SetShown(csNameEdit:GetText() == "")
    end
    csFileEdit:SetScript("OnTextChanged", RefreshPlaceholders)
    csFileEdit:SetScript("OnShow", RefreshPlaceholders)
    csNameEdit:SetScript("OnTextChanged", RefreshPlaceholders)
    csNameEdit:SetScript("OnShow", RefreshPlaceholders)

    local csTestBtn = CreateSQButton(content, "Test", 44, 22)
    csTestBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 312, yOffset + 1)

    local csAddBtn = CreateSQButton(content, "Add", 50, 22)
    csAddBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 360, yOffset + 1)
    yOffset = yOffset - 26

    -- One line of feedback under the form. Every outcome says something: the
    -- old form's silent failures were the unfriendly part.
    local csStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csStatus:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csStatus:SetWidth(400)
    csStatus:SetJustifyH("LEFT")
    csStatus:SetWordWrap(true)
    csStatus:SetText("")
    local function SetStatus(text, good)
        csStatus:SetText(text or "")
        if good then
            csStatus:SetTextColor(0.4, 0.9, 0.4)
        else
            csStatus:SetTextColor(1, 0.45, 0.35)
        end
    end
    yOffset = yOffset - 30

    local function StatusForFailure(reason, file)
        if reason == "off" then
            return "Game sound is switched off (System > Sound), so the file cannot be checked. Turn it on and try again."
        end
        return "Could not find \"" .. file .. "\" in SquizzumablesMedia\\Sounds\\. Check the spelling, and /reload if you have just copied it in."
    end

    csTestBtn:SetScript("OnClick", function()
        local input = csFileEdit:GetText():match("^%s*(.-)%s*$") or ""
        if input == "" then SetStatus("Type a filename first.") return end
        local dir, fileOrReason = FindCustomSound(input)
        if not dir then
            SetStatus(StatusForFailure(fileOrReason, input))
        elseif dir == "legacy" then
            SetStatus("Found " .. fileOrReason .. " in the old Squizzumables\\Media\\Sounds\\ folder. It works, but the next addon update will delete it - move it to SquizzumablesMedia\\Sounds\\.", false)
        else
            SetStatus("Found " .. fileOrReason .. " - playing.", true)
        end
    end)

    local function AddCustomSound()
        local input = csFileEdit:GetText():match("^%s*(.-)%s*$") or ""
        if input == "" then SetStatus("Type a filename first.") return end

        local dir, fileOrReason = FindCustomSound(input)
        if not dir then
            SetStatus(StatusForFailure(fileOrReason, input))
            return
        end
        local file = fileOrReason

        local label = csNameEdit:GetText():match("^%s*(.-)%s*$") or ""
        if label == "" then label = CustomSoundNameFromFile(file) end
        if label == "" then SetStatus("Give the sound a name.") return end
        local name = "Squizzumables: " .. label

        self.settings.customSounds = self.settings.customSounds or {}
        for _, e in ipairs(self.settings.customSounds) do
            if e.name == name then
                SetStatus("You already have a sound called \"" .. label .. "\". Pick another name.")
                return
            end
        end
        for _, e in ipairs(SQ_BUNDLED_SOUNDS) do
            if e.name == name then
                SetStatus("\"" .. label .. "\" is the name of a bundled sound. Pick another name.")
                return
            end
        end

        local entry = { name = name, file = file }
        if dir == "media" then entry.dir = "media" end
        table.insert(self.settings.customSounds, entry)
        self:SaveSettings()
        local lsm = GetLSM()
        if lsm then
            lsm:Register("sound", name, CustomSoundPath(entry))
        end

        csFileEdit:SetText("")
        csNameEdit:SetText("")
        csFileEdit:ClearFocus()
        csNameEdit:ClearFocus()
        RefreshPlaceholders()
        if dir == "legacy" then
            SetStatus("Added \"" .. label .. "\" from the OLD folder. Move the file to SquizzumablesMedia\\Sounds\\ and add it again, or the next addon update will delete it.", false)
        else
            SetStatus("Added \"" .. label .. "\". It is now in every sound list.", true)
        end
        self:RefreshCustomSoundsList()
        if self.scrollChild then self:RefreshItemList() end
    end
    csAddBtn:SetScript("OnClick", AddCustomSound)
    csFileEdit:SetScript("OnEnterPressed", function(box) box:ClearFocus(); AddCustomSound() end)

    -- The list of sounds already added, last on the page so it can grow.
    local csListTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csListTitle:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csListTitle:SetText("YOUR SOUNDS")
    csListTitle:SetTextColor(0.6, 0.6, 0.6)
    yOffset = yOffset - 18

    local csListFrame = CreateFrame("Frame", nil, content)
    csListFrame:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csListFrame:SetSize(410, 4)
    self.customSoundsListFrame = csListFrame
    self.customSoundsContent = content
    self.customSoundsListTop = yOffset
    self:RefreshCustomSoundsList()

    -- Leaving the tab stops a test that is still playing.
    content:SetScript("OnHide", StopCustomSoundTest)
end
