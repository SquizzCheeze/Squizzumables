-- Alerts/KelTab.lua
-- The "Just For Kel" settings tab: the alert list and its editor (trigger,
-- image or animation, sounds, position, test).
--
-- Moved out of Squizzumables_SpellAlerts.lua unchanged in 2.0 phase 2; see
-- Alerts/Kelerts.lua for how the Alerts/ files share names.

local addonName, ns = ...
local BH = ns.BH

local SQ_COLORS        = ns.SQ_COLORS
local CreateSQButton   = ns.CreateSQButton
local CreateSQEditBox  = ns.CreateSQEditBox
local CreateSQSlider   = ns.CreateSQSlider
local CreateSQCheckbox = ns.CreateSQCheckbox
local CreateSQDropdown = ns.CreateSQDropdown
local CreateSQDivider  = ns.CreateSQDivider

local A = ns.Alerts

local ShowAlert                    = A.ShowAlert
local CurrentAlert                 = A.CurrentAlert
local GetOrCreateRandomSoundsTable = A.GetOrCreateRandomSoundsTable

-- ============================================================================
-- Settings tab: "Just For Kel"
-- ============================================================================

function BH:BuildJustForKelTab(parent)
    -- Three unrelated things shared this page: the lust alert, the buff sound
    -- grid and the death tally. `content` is reassigned at each boundary below.
    --
    -- The alert and its frame are one sub-tab, not two. They are the same
    -- feature -- what fires and what it looks like -- and separating them meant
    -- setting up one alert across two tabs.
    local pages = ns.SubTabs.Create(parent, {
        { key = "alerts",     label = "Lust Alert" },
        { key = "buffsounds", label = "CDM Alerts" },
        { key = "deaths",     label = "Death Tally" },
    })
    self.kelPages = pages

    local content = pages.alerts
    ns.Rows.currentSection = content.section

    local leftPad = 14
    local yOffset = -14

    local lustNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lustNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    lustNote:SetWidth(372)
    lustNote:SetJustifyH("LEFT")
    lustNote:SetWordWrap(true)
    lustNote:SetText("A full-screen image and a sound when any lust effect wears off. For a sound or an image on your own buffs, see Buff Alerts.")
    lustNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 34

    -- Alert enable
    local lustEnableCb = CreateSQCheckbox(content, "Enable this alert", function(val)
        CurrentAlert().enabled = val
        BH:SaveSettings()
    end)
    lustEnableCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelLustEnableCb = lustEnableCb
    ns.Rows.AddTooltip(lustEnableCb, "Enable this alert", "Show the image and play the sound when this alert's trigger appears on you.")
    yOffset = yOffset - 26

    -- Lust row 1: Texture · Frames · FPS
    local lTexLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lTexLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    lTexLbl:SetText("Texture:")
    lTexLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lTexEdit = CreateSQEditBox(content, 120, 20, { maxLetters = 128 })
    lTexEdit:SetPoint("LEFT", lTexLbl, "RIGHT", 4, 0)
    local function SaveLustTex(self)
        CurrentAlert().texture = self:GetText()
        BH:SaveSettings()
    end
    lTexEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustTex(self) end)
    lTexEdit.onFocusLost = SaveLustTex
    self.kelLustTexEdit = lTexEdit
    ns.Rows.AddTooltip(lTexEdit, "Alert image", "Base file name of the image in the addon Media folder, without the extension. For an animated sequence use the base name shared by the numbered frames.")

    local lFramesLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lFramesLbl:SetPoint("LEFT", lTexEdit, "RIGHT", 8, 0)
    lFramesLbl:SetText("Frames:")
    lFramesLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lFramesEdit = CreateSQEditBox(content, 34, 20, { numeric = true, justifyH = "CENTER" })
    lFramesEdit:SetPoint("LEFT", lFramesLbl, "RIGHT", 4, 0)
    local function SaveLustFrames(self)
        CurrentAlert().frameCount = math.max(0, tonumber(self:GetText()) or 0)
        BH:SaveSettings()
    end
    lFramesEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustFrames(self) end)
    lFramesEdit.onFocusLost = SaveLustFrames
    self.kelLustFramesEdit = lFramesEdit
    ns.Rows.AddTooltip(lFramesEdit, "Frame count", "How many numbered image files make up the animation. Leave at 1 for a still image.")

    local lFpsLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lFpsLbl:SetPoint("LEFT", lFramesEdit, "RIGHT", 8, 0)
    lFpsLbl:SetText("FPS:")
    lFpsLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lFpsEdit = CreateSQEditBox(content, 28, 20, { numeric = true, justifyH = "CENTER" })
    lFpsEdit:SetPoint("LEFT", lFpsLbl, "RIGHT", 4, 0)
    local function SaveLustFPS(self)
        CurrentAlert().fps = math.max(1, tonumber(self:GetText()) or 10)
        BH:SaveSettings()
    end
    lFpsEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustFPS(self) end)
    lFpsEdit.onFocusLost = SaveLustFPS
    self.kelLustFpsEdit = lFpsEdit
    ns.Rows.AddTooltip(lFpsEdit, "Frames per second", "Playback speed of the animation.")
    yOffset = yOffset - 28

    -- Lust row 2: Duration · Loop
    local lDurLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lDurLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    lDurLbl:SetText("Dur(s):")
    lDurLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lDurEdit = CreateSQEditBox(content, 34, 20, { numeric = true, justifyH = "CENTER" })
    lDurEdit:SetPoint("LEFT", lDurLbl, "RIGHT", 4, 0)
    local function SaveLustDur(self)
        CurrentAlert().duration = math.max(1, tonumber(self:GetText()) or 5)
        BH:SaveSettings()
    end
    lDurEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustDur(self) end)
    lDurEdit.onFocusLost = SaveLustDur
    self.kelLustDurEdit = lDurEdit
    ns.Rows.AddTooltip(lDurEdit, "Duration", "How many seconds the alert stays on screen.")

    local lLoopCb = CreateSQCheckbox(content, "Loop", function(val)
        CurrentAlert().loop = val
        BH:SaveSettings()
    end)
    lLoopCb:SetPoint("LEFT", lDurEdit, "RIGHT", 14, 0)
    self.kelLustLoopCb = lLoopCb
    ns.Rows.AddTooltip(lLoopCb, "Loop", "Repeat the animation for the whole duration instead of playing through once and holding on the last frame.")
    yOffset = yOffset - 28

    -- Lust row 2b: Sound loop
    local lSndLoopCb = CreateSQCheckbox(content, "Loop sound", function(val)
        CurrentAlert().soundLoop = val
        BH:SaveSettings()
    end)
    lSndLoopCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelLustSndLoopCb = lSndLoopCb
    ns.Rows.AddTooltip(lSndLoopCb, "Loop sound",
        "Repeat the alert sound while the alert is on screen.\n\n"
     .. "Only for SHORT sounds. Each repeat starts a new copy of the sound on top of the ones "
     .. "still playing, so a long track (the bundled lust tracks run about 40 seconds) stacks "
     .. "up many copies at once. That drowns everything out, and in a busy fight the game "
     .. "runs out of sound channels and starts cutting sounds off, the alert's included.")

    local lSndLoopIntervalLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lSndLoopIntervalLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 95, yOffset + 3)
    lSndLoopIntervalLbl:SetText("every:")
    lSndLoopIntervalLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lSndLoopIntervalEdit = CreateSQEditBox(content, 34, 20, { justifyH = "CENTER" })
    lSndLoopIntervalEdit:SetPoint("LEFT", lSndLoopIntervalLbl, "RIGHT", 4, 0)
    local function SaveLustSndInterval(self)
        CurrentAlert().soundLoopInterval = math.max(0.5, tonumber(self:GetText()) or 2.0)
        BH:SaveSettings()
    end
    lSndLoopIntervalEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustSndInterval(self) end)
    lSndLoopIntervalEdit.onFocusLost = SaveLustSndInterval
    self.kelLustSndLoopIntervalEdit = lSndLoopIntervalEdit
    ns.Rows.AddTooltip(lSndLoopIntervalEdit, "Sound loop interval", "Seconds between repeats of the looped sound.")

    local lSndLoopSecLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lSndLoopSecLbl:SetPoint("LEFT", lSndLoopIntervalEdit, "RIGHT", 4, 0)
    lSndLoopSecLbl:SetText("sec")
    lSndLoopSecLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 24

    -- Always shown rather than only while the box is ticked: the warning is
    -- most useful BEFORE someone turns it on with a 40 second track.
    local lSndLoopWarn = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lSndLoopWarn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 4, yOffset)
    lSndLoopWarn:SetWidth(372)
    lSndLoopWarn:SetJustifyH("LEFT")
    lSndLoopWarn:SetTextColor(1, 0.7, 0.3)
    lSndLoopWarn:SetText("Loop short sounds only - looping a long track stacks copies of it and can get sounds cut off in busy fights.")
    yOffset = yOffset - 28

    -- Lust row 3: Sound dropdown (full width) · Test
    local lSndLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lSndLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset - 13)
    lSndLbl:SetText("Sound:")
    lSndLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lSndDrop = CreateSQDropdown(content, "", 260, BH:BuildSoundDropdownItems(), function(val)
        CurrentAlert().sound = val
        BH:SaveSettings()
    end)
    lSndDrop:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 62, yOffset - 4)
    self.kelLustSndDrop = lSndDrop
    ns.Rows.AddTooltip(lSndDrop, "Alert sound", "Sound played when the alert fires. Includes the bundled sounds and any you have registered on the Sounds tab.")
    yOffset = yOffset - 30

    -- Lust row 3b: Channel selector + Test button
    local lChanLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lChanLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset - 13)
    lChanLbl:SetText("Channel:")
    lChanLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lChanDrop  -- forward-declared so the Test button closure below can capture it as an upvalue
    local lTestBtn = CreateSQButton(content, "Test", 50, 20)
    lTestBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 372 - 50 + 12, yOffset - 4)
    lTestBtn:SetScript("OnClick", function()
        ShowAlert({
            texture           = lTexEdit:GetText(),
            sound             = lSndDrop:GetSelectedValue() or "None",
            soundChannel      = lChanDrop:GetSelectedValue() or "Master",
            duration          = math.max(1, tonumber(lDurEdit:GetText()) or 5),
            frameCount        = math.max(0, tonumber(lFramesEdit:GetText()) or 0),
            fps               = math.max(1, tonumber(lFpsEdit:GetText()) or 10),
            loop              = lLoopCb:GetChecked(),
            opacity           = (BH.settings and CurrentAlert() and CurrentAlert().opacity) or 1.0,
            soundLoop         = lSndLoopCb:GetChecked(),
            soundLoopInterval = math.max(0.5, tonumber(lSndLoopIntervalEdit:GetText()) or 2.0),
        })
    end)

    lChanDrop = CreateSQDropdown(content, "", 130, {
        { text = "Master",   value = "Master"   },
        { text = "SFX",      value = "SFX"      },
        { text = "Music",    value = "Music"    },
        { text = "Ambience", value = "Ambience" },
        { text = "Dialog",   value = "Dialog"   },
    }, function(val)
        CurrentAlert().soundChannel = val
        BH:SaveSettings()
    end)
    lChanDrop:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 62, yOffset - 4)
    self.kelLustSndChannelDrop = lChanDrop
    ns.Rows.AddTooltip(lChanDrop, "Sound channel", "Which audio channel the alert plays on. Master ignores your in-game sound sliders.")
    yOffset = yOffset - 36

    -- ── RANDOMIZE SOUND ────────────────────────────────────────────────────
    do
        local div = CreateSQDivider(content, yOffset)
        div:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        yOffset = yOffset - 18
    end

    local rsHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rsHdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    rsHdr:SetText("RANDOMIZE SOUND")
    ns.ApplyAccent(rsHdr, "text")
    yOffset = yOffset - 20

    local rsNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rsNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    rsNote:SetWidth(372)
    rsNote:SetJustifyH("LEFT")
    rsNote:SetWordWrap(true)
    rsNote:SetText("Check any sounds below to have this alert play a random pick from them instead of the Sound above. Leave all unchecked (default) to just use the Sound above.")
    rsNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 34

    local rsItems = BH:BuildSoundDropdownItems()
    self.kelLustRandomSoundCbs = {}

    local rsSelectAllBtn = CreateSQButton(content, "Select All", 90, 20)
    rsSelectAllBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    rsSelectAllBtn:SetScript("OnClick", function()
        local rs = GetOrCreateRandomSoundsTable()
        for _, item in ipairs(rsItems) do
            if item.value ~= "None" then
                rs[item.value] = true
                local cb = self.kelLustRandomSoundCbs[item.value]
                if cb then cb:SetChecked(true) end
            end
        end
        BH:SaveSettings()
    end)

    local rsSelectNoneBtn = CreateSQButton(content, "Select None", 90, 20)
    rsSelectNoneBtn:SetPoint("LEFT", rsSelectAllBtn, "RIGHT", 8, 0)
    rsSelectNoneBtn:SetScript("OnClick", function()
        wipe(GetOrCreateRandomSoundsTable())
        for _, cb in pairs(self.kelLustRandomSoundCbs) do
            cb:SetChecked(false)
        end
        BH:SaveSettings()
    end)
    yOffset = yOffset - 28

    for _, item in ipairs(rsItems) do
        if item.value ~= "None" then
            local soundName = item.value
            local cb = CreateSQCheckbox(content, item.text, function(checked)
                local rs = GetOrCreateRandomSoundsTable()
                rs[soundName] = checked and true or nil
                BH:SaveSettings()
            end)
            cb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            self.kelLustRandomSoundCbs[soundName] = cb
            yOffset = yOffset - 20
        end
    end
    yOffset = yOffset - 8

    -- ── ALERT FRAME ────────────────────────────────────────────────────────
    --
    -- A subsection of Lust Alert rather than a sub-tab of its own: it is how
    -- that one alert looks, so splitting them put two halves of the same
    -- setting behind different tabs.
    do
        local div = CreateSQDivider(content, yOffset)
        div:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        yOffset = yOffset - 18
    end

    local afHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    afHdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    afHdr:SetText("ALERT FRAME")
    ns.ApplyAccent(afHdr, "text")
    yOffset = yOffset - 20

    local scaleSlider = CreateSQSlider(content, "Alert Image Scale %", 220, 50, 300, 1)
    scaleSlider:SetAfterValueChanged(function(val)
        BH.settings.kelAlertScale = val / 100
        BH:SaveSettings()
        if BH.kelAlertFrame then BH.kelAlertFrame:SetScale(val / 100) end
    end)
    scaleSlider:SetValue((BH.settings and BH.settings.kelAlertScale or 1.0) * 100)
    scaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelScaleSlider = scaleSlider
    ns.Rows.AddTooltip(scaleSlider, "Alert Image Scale %", "Size of the alert image, as a percentage.")
    yOffset = yOffset - 50

    local opacitySlider = CreateSQSlider(content, "Alert Opacity %", 220, 0, 100, 1)
    opacitySlider:SetAfterValueChanged(function(val)
        CurrentAlert().opacity = val / 100
        BH:SaveSettings()
    end)
    opacitySlider:SetValue(math.floor(((BH.settings and CurrentAlert() and CurrentAlert().opacity) or 1.0) * 100 + 0.5))
    opacitySlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelOpacitySlider = opacitySlider
    ns.Rows.AddTooltip(opacitySlider, "Alert Opacity %", "Transparency of the alert image.")
    yOffset = yOffset - 50

    -- "Lock alert image position" used to live here. The alert is click-through
    -- unconditionally now, so the checkbox had nothing left to control: it is
    -- Unlock Frames that makes the image draggable, and it always did override
    -- this setting anyway. Removed rather than left as a control that does
    -- nothing, and settings.kelAlertLocked went with it. Old profiles may still
    -- carry the key; nothing reads it, which is harmless, so there is nothing
    -- for a migration to repair.

    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.buffsounds
    ns.Rows.currentSection = content.section
    yOffset = -14
    do
        -- No heading here any more: the sub-tab is called Buff Sounds, and
        -- naming the section twice on the same screen is what this tidy-up was
        -- getting rid of.
        local bsNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bsNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        bsNote:SetWidth(372)
        bsNote:SetJustifyH("LEFT")
        bsNote:SetWordWrap(true)
        bsNote:SetText("Your spec's buffs and cooldowns. Click one to give it a sound and an image: a buff when it lands or drops (the image shows while it is up), a cooldown when it is ready or goes on cooldown. All of it works in combat.")
        bsNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        yOffset = yOffset - 44

        local hideBlizz = CreateSQCheckbox(content, "Hide all of Blizzard's spell alerts", function(val)
            BH.settings.kelHideBlizzardAlerts = val and true or false
            BH:SaveSettings()
            BH:RefreshBuffImages()
        end)
        hideBlizz:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        hideBlizz:SetChecked(BH.settings.kelHideBlizzardAlerts == true)
        ns.Rows.AddTooltip(hideBlizz, "Hide all of Blizzard's spell alerts",
            "Hides the art Blizzard draws round the middle of the screen when a proc or buff is up, for every "
            .. "spell. Without this, only the buffs you give an image here have theirs hidden. The game's alert "
            .. "sound still plays; the game's own Spell Alert setting turns that off.")
        yOffset = yOffset - 30

        if not BH.AuraSoundsAvailable() then
            local nope = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            nope:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            nope:SetWidth(372)
            nope:SetJustifyH("LEFT")
            nope:SetWordWrap(true)
            nope:SetText("This client has no C_UnitAuras.AddAuraSound, so buff sounds are unavailable.")
            nope:SetTextColor(SQ_COLORS.danger[1], SQ_COLORS.danger[2], SQ_COLORS.danger[3])
            yOffset = yOffset - 30
        else
            -- The icon grid. Held in a container so the whole thing can be
            -- rebuilt on a spec or talent change without disturbing the rest of
            -- the tab's layout -- which is exactly the bug the CDM sounds tab
            -- had, where the grid was drawn once and never again.
            local grid = CreateFrame("Frame", nil, content)
            grid:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            grid:SetSize(372, 40)
            self.kelBuffGrid = grid
            -- Everything below hangs off the grid's bottom, so it follows the
            -- grid when it grows (cooldowns joined it in 2.0, and a spec
            -- change redraws it); FinishEditor sizes the page the same way.
            self.kelBuffGridTop = math.abs(yOffset)
            self:RebuildBuffSoundGrid()
            yOffset = yOffset - (grid:GetHeight() + 10)

            -- Manual entry, because the grid is built from cast spell IDs and
            -- AddAuraSound wants the ID of the aura that lands. They usually
            -- match for a self-buff and sometimes do not (Blessing of Freedom
            -- casts as 61107 and applies 92824), so there has to be a way to
            -- name the aura directly rather than discovering it does not work.
            local manLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            manLbl:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -10)
            manLbl:SetText("Add by spell ID:")
            manLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

            local manEdit = CreateSQEditBox(content, 80, 20, { numeric = true, maxLetters = 9 })
            manEdit:SetPoint("LEFT", manLbl, "RIGHT", 6, 0)
            self.kelBuffManualEdit = manEdit
            ns.Rows.AddTooltip(manEdit, "Add by spell ID",
                "The spell ID of the aura itself, from its Wowhead URL. Use this for a buff that is not in the list above, or one whose cast and aura have different IDs.")

            local manBtn = CreateSQButton(content, "Add", 50, 22)
            manBtn:SetPoint("LEFT", manEdit, "RIGHT", 6, 0)
            manBtn:SetScript("OnClick", function()
                local id = tonumber(manEdit:GetText())
                if not id then return end
                local store = BH.BuffSounds()
                store[id] = store[id] or { channel = "Master" }
                manEdit:SetText("")
                manEdit:ClearFocus()
                BH.SelectBuffSpell(id)
                BH:SaveSettings()
                BH:RefreshJustForKelTab()
            end)
            yOffset = yOffset - 30

            -- Editor for whichever icon is selected.
            local editor = CreateFrame("Frame", nil, content)
            editor:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -40)
            editor:SetSize(372, 40)
            self.kelBuffEditor = editor
            -- The editor's height follows what the selected buff has turned
            -- on (the image options add rows), so it resizes this page itself
            -- after every rebuild -- sized once here, the new rows were cut off.
            self.kelBuffPage = content
            self:RebuildBuffSoundEditor()
            yOffset = yOffset - (editor:GetHeight() + 12)
        end
    end

    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.deaths
    ns.Rows.currentSection = content.section
    yOffset = -14

    local dtEnableCb = CreateSQCheckbox(content, "Enable M+ Death Tally", function(checked)
        BH.settings.deathTallyEnabled = checked
        BH:SaveSettings()
        if BH.deathTallyFrame then BH:UpdateDeathTallyDisplay() end
    end)
    dtEnableCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelDeathTallyEnableCb = dtEnableCb
    ns.Rows.AddTooltip(dtEnableCb, "Enable M+ Death Tally", "Counts deaths per player for the current Mythic+ key. Starts and resets when a key begins, and can be dismissed with its close button.")
    yOffset = yOffset - 34

    local dtScaleSlider = CreateSQSlider(content, "M+ Death Tally Scale", 300, 50, 200, 5)
    dtScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    dtScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.deathTallyScale = value / 100
        BH:SaveSettings()
        if userInput and BH.deathTallyFrame then
            BH.deathTallyFrame:SetScale(value / 100)
        end
    end)
    self.kelDeathTallyScaleSlider = dtScaleSlider
    ns.Rows.AddTooltip(dtScaleSlider, "M+ Death Tally Scale", "Size of the death tally frame, as a percentage.")
    yOffset = yOffset - 50

    local dtTitleFontSlider = CreateSQSlider(content, "Title Font Size", 300, 8, 24, 1)
    dtTitleFontSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    dtTitleFontSlider:SetAfterValueChanged(function(value)
        BH.settings.deathTallyTitleFontSize = value
        BH:SaveSettings()
        if BH.deathTallyFrame then BH:UpdateDeathTallyDisplay() end
    end)
    self.kelDeathTallyTitleFontSlider = dtTitleFontSlider
    ns.Rows.AddTooltip(dtTitleFontSlider, "Title Font Size", "Size of the death tally heading text.")
    yOffset = yOffset - 50

    local dtRowFontSlider = CreateSQSlider(content, "Row Font Size", 300, 8, 20, 1)
    dtRowFontSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    dtRowFontSlider:SetAfterValueChanged(function(value)
        BH.settings.deathTallyRowFontSize = value
        BH:SaveSettings()
        if BH.deathTallyFrame then BH:UpdateDeathTallyDisplay() end
    end)
    self.kelDeathTallyRowFontSlider = dtRowFontSlider
    ns.Rows.AddTooltip(dtRowFontSlider, "Row Font Size", "Size of the per-player rows in the death tally.")
    yOffset = yOffset - 50

    local dtClassColorCb = CreateSQCheckbox(content, "Class color names", function(checked)
        BH.settings.deathTallyClassColorNames = checked
        BH:SaveSettings()
        if BH.deathTallyFrame then BH:UpdateDeathTallyDisplay() end
    end)
    dtClassColorCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelDeathTallyClassColorCb = dtClassColorCb
    ns.Rows.AddTooltip(dtClassColorCb, "Class color names", "Colour each name in the death tally by that player class.")
    yOffset = yOffset - 26

    local dtHideRealmCb = CreateSQCheckbox(content, "Hide realm names", function(checked)
        BH.settings.deathTallyHideRealm = checked
        BH:SaveSettings()
        if BH.deathTallyFrame then BH:UpdateDeathTallyDisplay() end
    end)
    dtHideRealmCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelDeathTallyHideRealmCb = dtHideRealmCb
    ns.Rows.AddTooltip(dtHideRealmCb, "Hide realm names", "Strip the -Realm suffix from names in the death tally, for cross-realm groups.")
    yOffset = yOffset - 34

    local dtLockCb = CreateSQCheckbox(content, "Lock M+ Death Tally", function(checked)
        BH.settings.deathTallyLocked = checked
        BH:SaveSettings()
        if BH.deathTallyFrame then
            BH.deathTallyFrame:SetMovable(not checked)
            BH.deathTallyFrame:EnableMouse(not checked)
        end
    end)
    dtLockCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelLockDeathTallyCheckbox = dtLockCb
    ns.Rows.AddTooltip(dtLockCb, "Lock M+ Death Tally", "Stops the death tally frame being dragged.")
    yOffset = yOffset - 28

    content:SetHeight(math.abs(yOffset) + 20)
    ns.Rows.currentSection = nil

    -- Only ever read as "has this tab been built yet", so which page it points
    -- at does not matter -- but the first one is the honest answer, and leaving
    -- it as whatever `content` happened to be at the end of the function would
    -- silently follow any future re-ordering of the sub-tabs.
    self.kelTabContent = pages.alerts

    self:RefreshJustForKelTab()
end

function BH:RefreshJustForKelTab()
    -- Every edit in this tab routes back through here, so this is the one place
    -- that catches all of them. Deliberately ahead of the early return: the
    -- registrations must follow the settings even when the tab has never been
    -- built.
    self:RefreshAuraSoundRegistrations("Kelerts tab refresh")

    local content = self.kelTabContent
    if not content then return end

    -- The buff grid is spec- and talent-derived, so it has to be redrawn rather
    -- than left as it was built. This is the mistake the CDM sounds tab made:
    -- its grid was populated once at construction and never again, so a spec
    -- change left it showing spells the player no longer had.
    self:RebuildBuffSoundGrid()
    self:RebuildBuffSoundEditor()

    -- The lust alert is the only one left, so CurrentAlert() always resolves to
    -- it and there is no selector, name or trigger to keep in sync.
    local la = (BH.settings and CurrentAlert()) or {}

    if self.kelLustEnableCb   then self.kelLustEnableCb:SetChecked(la.enabled ~= false) end
    if self.kelLustTexEdit    then self.kelLustTexEdit:SetText(la.texture or "") end
    if self.kelLustFramesEdit then self.kelLustFramesEdit:SetText(tostring(la.frameCount or 0)) end
    if self.kelLustFpsEdit    then self.kelLustFpsEdit:SetText(tostring(la.fps or 10)) end
    if self.kelLustDurEdit    then self.kelLustDurEdit:SetText(tostring(la.duration or 5)) end
    if self.kelLustLoopCb     then self.kelLustLoopCb:SetChecked(la.loop ~= false) end
    if self.kelLustSndDrop              then self.kelLustSndDrop:SetSelectedValue(la.sound or "None") end
    if self.kelLustSndChannelDrop       then self.kelLustSndChannelDrop:SetSelectedValue(la.soundChannel or "Master") end
    if self.kelLustSndLoopCb            then self.kelLustSndLoopCb:SetChecked(la.soundLoop or false) end
    if self.kelLustSndLoopIntervalEdit  then self.kelLustSndLoopIntervalEdit:SetText(tostring(la.soundLoopInterval or 2.0)) end
    if self.kelLustRandomSoundCbs then
        local rs = la.randomSounds
        for soundName, cb in pairs(self.kelLustRandomSoundCbs) do
            cb:SetChecked(type(rs) == "table" and rs[soundName] or false)
        end
    end

    -- Alert frame controls
    if self.kelScaleSlider then
        self.kelScaleSlider:SetValue(math.max(50, math.min(300, (BH.settings and BH.settings.kelAlertScale or 1.0) * 100)))
    end
    if self.kelOpacitySlider then
        self.kelOpacitySlider:SetValue(math.floor(((la.opacity) or 1.0) * 100 + 0.5))
    end
    -- M+ Death Tally controls
    if self.kelDeathTallyEnableCb then
        self.kelDeathTallyEnableCb:SetChecked(BH.settings and BH.settings.deathTallyEnabled ~= false)
    end
    if self.kelDeathTallyScaleSlider then
        self.kelDeathTallyScaleSlider:SetValue((BH.settings and BH.settings.deathTallyScale or 1.0) * 100)
    end
    if self.kelDeathTallyTitleFontSlider then
        self.kelDeathTallyTitleFontSlider:SetValue((BH.settings and BH.settings.deathTallyTitleFontSize) or 13)
    end
    if self.kelDeathTallyRowFontSlider then
        self.kelDeathTallyRowFontSlider:SetValue((BH.settings and BH.settings.deathTallyRowFontSize) or 12)
    end
    if self.kelDeathTallyClassColorCb then
        self.kelDeathTallyClassColorCb:SetChecked(BH.settings and BH.settings.deathTallyClassColorNames ~= false)
    end
    if self.kelDeathTallyHideRealmCb then
        self.kelDeathTallyHideRealmCb:SetChecked(BH.settings and BH.settings.deathTallyHideRealm ~= false)
    end
    if self.kelLockDeathTallyCheckbox then
        self.kelLockDeathTallyCheckbox:SetChecked(BH.settings and BH.settings.deathTallyLocked or false)
    end

end


