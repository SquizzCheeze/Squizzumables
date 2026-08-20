-- Squizzumables_SpellAlerts.lua
-- "Just For Kel" tab: shows a texture (or animated frame sequence) and plays
-- a sound when a configured spell aura is applied to the player.

local addonName, ns = ...
local BH = ns.BH

-- Shared theme and UI constructors, defined in Squizzumables.lua which loads
-- before this file.
local SQ_COLORS        = ns.SQ_COLORS
local CreateSQButton   = ns.CreateSQButton
local CreateSQSlider   = ns.CreateSQSlider
local CreateSQCheckbox = ns.CreateSQCheckbox
local CreateSQDropdown = ns.CreateSQDropdown
local CreateSQDivider  = ns.CreateSQDivider

-- ============================================================================
-- Alert display frame
-- ============================================================================

local KEL_MEDIA_PATH = "Interface\\AddOns\\Squizzumables\\Media\\"

local alertFrame
local alertTimer
local alertSoundTicker

local function EnsureAlertFrame()
    if alertFrame then return alertFrame end

    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(200, 200)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:EnableMouse(false)
    f:Hide()

    f:SetScript("OnMouseDown", function(self, btn)
        -- Unlock Frames overrides the per-frame lock, so this can be positioned
        -- alongside everything else without unticking its own checkbox first.
        if btn == "LeftButton"
            and (BH.unlockMode or not (BH.settings and BH.settings.kelAlertLocked)) then
            self:StartMoving()
        end
    end)
    f:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        BH:SaveKelAlertPosition()
    end)

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    f.tex = tex

    -- Animation state (set by ShowAlert when frameCount > 1)
    f.anim = {
        active     = false,
        baseName   = "",
        frameCount = 0,
        fps        = 10,
        loop       = true,
        current    = 1,
        elapsed    = 0,
    }

    f:SetScript("OnUpdate", function(self, dt)
        local a = self.anim
        if not a.active then return end
        a.elapsed = a.elapsed + dt
        local frameDur = 1 / math.max(1, a.fps)
        if a.elapsed >= frameDur then
            a.elapsed = a.elapsed - frameDur
            a.current = a.current + 1
            if a.current > a.frameCount then
                if a.loop then
                    a.current = 1
                else
                    -- played through once — stop on last frame
                    a.current = a.frameCount
                    a.active  = false
                    return
                end
            end
            local path = KEL_MEDIA_PATH .. a.baseName
                         .. string.format("_%03d", a.current) .. ".png"
            self.tex:SetTexture(path)
        end
    end)

    alertFrame = f
    BH.kelAlertFrame = f
    return f
end

-- Picks one random sound name from alert.randomSounds ([name] = true), or nil
-- if that pool is missing/empty (in which case ShowAlert falls back to
-- alert.sound unchanged). Chosen once per ShowAlert call, not re-rolled on
-- sound-loop repeats, so a single alert instance stays consistent.
local function PickRandomSound(alert)
    local pool = alert and alert.randomSounds
    if type(pool) ~= "table" then return nil end
    local names = {}
    for name, checked in pairs(pool) do
        if checked then table.insert(names, name) end
    end
    if #names == 0 then return nil end
    return names[math.random(#names)]
end

local function ShowAlert(alert)
    local f = EnsureAlertFrame()

    -- Stop any running animation
    f.anim.active = false

    local texBase = alert and alert.texture or ""
    local frames  = tonumber(alert and alert.frameCount) or 0

    if texBase ~= "" then
        if frames > 1 then
            -- Animated: start from frame 1
            local path = KEL_MEDIA_PATH .. texBase
                         .. string.format("_%03d", 1) .. ".png"
            f.tex:SetTexture(path)
            f.tex:Show()
            f.anim.baseName   = texBase
            f.anim.frameCount = frames
            f.anim.fps        = math.max(1, tonumber(alert.fps) or 10)
            f.anim.loop       = alert.loop ~= false
            f.anim.current    = 1
            f.anim.elapsed    = 0
            f.anim.active     = true
        else
            -- Static: texture field may include extension or not
            f.tex:SetTexture(KEL_MEDIA_PATH .. texBase)
            f.tex:Show()
        end
    else
        f.tex:Hide()
    end

    local scale = (BH.settings and BH.settings.kelAlertScale) or 1.0
    f:SetScale(scale)
    local opacity = tonumber(alert and alert.opacity)
    f:SetAlpha(opacity and math.max(0, math.min(1, opacity)) or 1.0)

    local snd = PickRandomSound(alert) or (alert and alert.sound) or "None"
    local ch  = (alert and alert.soundChannel) or "Master"
    if alertSoundTicker then alertSoundTicker:Cancel(); alertSoundTicker = nil end
    if BH.PlaySound then BH:PlaySound(snd, ch) end
    if alert and alert.soundLoop and snd ~= "None" then
        local loopInterval = math.max(0.5, tonumber(alert.soundLoopInterval) or 2.0)
        alertSoundTicker = C_Timer.NewTicker(loopInterval, function()
            if BH.PlaySound then BH:PlaySound(snd, ch) end
        end)
    end

    f:Show()
    local dur = math.max(1, tonumber(alert and alert.duration) or 3)
    if alertTimer then alertTimer:Cancel() end
    alertTimer = C_Timer.NewTimer(dur, function()
        f.anim.active = false
        f:Hide()
        alertTimer = nil
        if alertSoundTicker then alertSoundTicker:Cancel(); alertSoundTicker = nil end
    end)
end

-- Expose so the Test button can call it
BH.ShowKelAlert = ShowAlert

-- ============================================================================
-- Position persistence
-- ============================================================================

function BH:SaveKelAlertPosition()
    if not self.kelAlertFrame then return end
    local point, _, relPoint, x, y = self.kelAlertFrame:GetPoint()
    SquizzumablesDB.kelAlertPosition = { point = point, relPoint = relPoint, x = x, y = y }
end

function BH:LoadKelAlertPosition()
    local f = EnsureAlertFrame()
    local pos = SquizzumablesDB and SquizzumablesDB.kelAlertPosition
    if pos then
        f:ClearAllPoints()
        f:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or "CENTER", pos.x or 0, pos.y or 100)
    end
end

-- ============================================================================
-- UNIT_AURA: detect configured spell auras applied to the player
-- Called by the existing UNIT_AURA handler in Squizzumables.lua
-- ============================================================================

-- Sated-like debuffs that are applied to the player after any lust effect.
local LUST_DEBUFF_IDS = {
    [57724]  = true,  -- Sated                   (Heroism)
    [57723]  = true,  -- Exhaustion              (Bloodlust)
    [80354]  = true,  -- Temporal Displacement   (Time Warp)
    [95809]  = true,  -- Insanity                (Ancient Hysteria / Hunter pet)
    [160455] = true,  -- Fatigued                (Hunter pet, variant 1)
    [264689] = true,  -- Fatigued                (Hunter pet, variant 2)
    [390435] = true,  -- Exhaustion              (Evoker Fury / Primal Rage)
    [206151] = true,  -- Temporal Displacement   (Fury of the Aspects)
}

-- Check each known sated-like debuff by spellID directly instead of scanning
-- all auras by index. As of 12.1.0, GetAuraDataByIndex throws a taint error
-- ("Auras cannot be accessed when secret") when auras are secret (in combat,
-- encounters, M+, PvP) — GetUnitAuraBySpellID does not have this problem.
local function HasLustDebuff()
    if C_UnitAuras and C_UnitAuras.GetUnitAuraBySpellID then
        for spellID in pairs(LUST_DEBUFF_IDS) do
            -- Presence check only — nothing is read off the returned table, so
            -- there is no secret field to trip over.
            if BH.Secrets.GetAuraBySpellID("player", spellID, "HARMFUL") then
                return true
            end
        end
    else
        -- Legacy fallback for clients without C_UnitAuras. UnitDebuff was
        -- removed in 12.x, so this branch is unreachable on any client that can
        -- run this addon; kept only so the function degrades rather than errors.
        for i = 1, 40 do
            local _, _, _, _, _, _, _, _, _, spellId = UnitDebuff("player", i)
            spellId = BH.Secrets.SafeNumber(spellId, nil)
            if not spellId then break end
            if LUST_DEBUFF_IDS[spellId] then return true end
        end
    end
    return false
end

local lustWasActive = false

-- Returns a writable randomSounds table for kelLustAlert, creating one if
-- missing. Existing profiles that predate this feature get the default
-- settings' (shared) empty table filled in by the generic deep-merge in
-- LoadSettings — writing into that shared table directly would corrupt the
-- default for every other profile, so swap in a fresh table on first write.
local function GetOrCreateRandomSoundsTable()
    BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
    local rs = BH.settings.kelLustAlert.randomSounds
    if type(rs) ~= "table" or rs == BH.defaultSettings.kelLustAlert.randomSounds then
        rs = {}
        BH.settings.kelLustAlert.randomSounds = rs
    end
    return rs
end


function BH:CheckKelAlerts(unit)
    if unit ~= "player" then return end
    if not self.settings then return end

    -- ── Lust detection ────────────────────────────────────────────────────
    local la = self.settings.kelLustAlert
    if la and la.enabled ~= false then
        local lustNow = HasLustDebuff()
        if lustNow and not lustWasActive and not BH.playerZoning then
            ShowAlert(la)
        end
        lustWasActive = lustNow
    else
        lustWasActive = false
    end
end





-- ============================================================================
-- Settings tab: "Just For Kel"
-- ============================================================================

function BH:BuildJustForKelTab(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    local leftPad = 14
    local yOffset = -14

    -- Section header
    local hdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    hdr:SetText("LUST ALERT")
    ns.ApplyAccent(hdr, "text")
    yOffset = yOffset - 20

    local lustNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lustNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    lustNote:SetWidth(372)
    lustNote:SetJustifyH("LEFT")
    lustNote:SetWordWrap(true)
    lustNote:SetText("Fires when you gain any lust debuff (Sated, Exhaustion, Temporal Displacement, Insanity, Fatigued).")
    lustNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 36

    -- Lust enable
    local lustEnableCb = CreateSQCheckbox(content, "Enable lust alert", function(val)
        BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
        BH.settings.kelLustAlert.enabled = val
        BH:SaveSettings()
    end)
    lustEnableCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelLustEnableCb = lustEnableCb
    ns.Rows.AddTooltip(lustEnableCb, "Enable lust alert", "Shows an image and plays a sound when a Bloodlust-type effect is used on you. Triggers on the Sated/Exhaustion debuff, so it fires for Heroism, Time Warp, Primal Rage and the rest.")
    yOffset = yOffset - 26

    -- Lust row 1: Texture · Frames · FPS
    local lTexLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lTexLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    lTexLbl:SetText("Texture:")
    lTexLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lTexEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    lTexEdit:SetSize(120, 20)
    lTexEdit:SetPoint("LEFT", lTexLbl, "RIGHT", 4, 0)
    lTexEdit:SetAutoFocus(false)
    lTexEdit:SetMaxLetters(128)
    local function SaveLustTex(self)
        BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
        BH.settings.kelLustAlert.texture = self:GetText()
        BH:SaveSettings()
    end
    lTexEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustTex(self) end)
    lTexEdit:SetScript("OnEditFocusLost", SaveLustTex)
    self.kelLustTexEdit = lTexEdit
    ns.Rows.AddTooltip(lTexEdit, "Alert image", "Base file name of the image in the addon Media folder, without the extension. For an animated sequence use the base name shared by the numbered frames.")

    local lFramesLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lFramesLbl:SetPoint("LEFT", lTexEdit, "RIGHT", 8, 0)
    lFramesLbl:SetText("Frames:")
    lFramesLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lFramesEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    lFramesEdit:SetSize(34, 20)
    lFramesEdit:SetPoint("LEFT", lFramesLbl, "RIGHT", 4, 0)
    lFramesEdit:SetAutoFocus(false)
    lFramesEdit:SetNumeric(true)
    local function SaveLustFrames(self)
        BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
        BH.settings.kelLustAlert.frameCount = math.max(0, tonumber(self:GetText()) or 0)
        BH:SaveSettings()
    end
    lFramesEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustFrames(self) end)
    lFramesEdit:SetScript("OnEditFocusLost", SaveLustFrames)
    self.kelLustFramesEdit = lFramesEdit
    ns.Rows.AddTooltip(lFramesEdit, "Frame count", "How many numbered image files make up the animation. Leave at 1 for a still image.")

    local lFpsLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lFpsLbl:SetPoint("LEFT", lFramesEdit, "RIGHT", 8, 0)
    lFpsLbl:SetText("FPS:")
    lFpsLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lFpsEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    lFpsEdit:SetSize(28, 20)
    lFpsEdit:SetPoint("LEFT", lFpsLbl, "RIGHT", 4, 0)
    lFpsEdit:SetAutoFocus(false)
    lFpsEdit:SetNumeric(true)
    local function SaveLustFPS(self)
        BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
        BH.settings.kelLustAlert.fps = math.max(1, tonumber(self:GetText()) or 10)
        BH:SaveSettings()
    end
    lFpsEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustFPS(self) end)
    lFpsEdit:SetScript("OnEditFocusLost", SaveLustFPS)
    self.kelLustFpsEdit = lFpsEdit
    ns.Rows.AddTooltip(lFpsEdit, "Frames per second", "Playback speed of the animation.")
    yOffset = yOffset - 28

    -- Lust row 2: Duration · Loop
    local lDurLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lDurLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    lDurLbl:SetText("Dur(s):")
    lDurLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lDurEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    lDurEdit:SetSize(34, 20)
    lDurEdit:SetPoint("LEFT", lDurLbl, "RIGHT", 4, 0)
    lDurEdit:SetAutoFocus(false)
    lDurEdit:SetNumeric(true)
    local function SaveLustDur(self)
        BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
        BH.settings.kelLustAlert.duration = math.max(1, tonumber(self:GetText()) or 5)
        BH:SaveSettings()
    end
    lDurEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustDur(self) end)
    lDurEdit:SetScript("OnEditFocusLost", SaveLustDur)
    self.kelLustDurEdit = lDurEdit
    ns.Rows.AddTooltip(lDurEdit, "Duration", "How many seconds the alert stays on screen.")

    local lLoopCb = CreateSQCheckbox(content, "Loop", function(val)
        BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
        BH.settings.kelLustAlert.loop = val
        BH:SaveSettings()
    end)
    lLoopCb:SetPoint("LEFT", lDurEdit, "RIGHT", 14, 0)
    self.kelLustLoopCb = lLoopCb
    ns.Rows.AddTooltip(lLoopCb, "Loop", "Repeat the animation for the whole duration instead of playing through once and holding on the last frame.")
    yOffset = yOffset - 28

    -- Lust row 2b: Sound loop
    local lSndLoopCb = CreateSQCheckbox(content, "Loop sound", function(val)
        BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
        BH.settings.kelLustAlert.soundLoop = val
        BH:SaveSettings()
    end)
    lSndLoopCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelLustSndLoopCb = lSndLoopCb
    ns.Rows.AddTooltip(lSndLoopCb, "Loop sound", "Repeat the alert sound while the alert is on screen.")

    local lSndLoopIntervalLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lSndLoopIntervalLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 95, yOffset + 3)
    lSndLoopIntervalLbl:SetText("every:")
    lSndLoopIntervalLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lSndLoopIntervalEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    lSndLoopIntervalEdit:SetSize(34, 20)
    lSndLoopIntervalEdit:SetPoint("LEFT", lSndLoopIntervalLbl, "RIGHT", 4, 0)
    lSndLoopIntervalEdit:SetAutoFocus(false)
    local function SaveLustSndInterval(self)
        BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
        BH.settings.kelLustAlert.soundLoopInterval = math.max(0.5, tonumber(self:GetText()) or 2.0)
        BH:SaveSettings()
    end
    lSndLoopIntervalEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SaveLustSndInterval(self) end)
    lSndLoopIntervalEdit:SetScript("OnEditFocusLost", SaveLustSndInterval)
    self.kelLustSndLoopIntervalEdit = lSndLoopIntervalEdit
    ns.Rows.AddTooltip(lSndLoopIntervalEdit, "Sound loop interval", "Seconds between repeats of the looped sound.")

    local lSndLoopSecLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lSndLoopSecLbl:SetPoint("LEFT", lSndLoopIntervalEdit, "RIGHT", 4, 0)
    lSndLoopSecLbl:SetText("sec")
    lSndLoopSecLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 26

    -- Lust row 3: Sound dropdown (full width) · Test
    local lSndLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lSndLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset - 13)
    lSndLbl:SetText("Sound:")
    lSndLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local lSndDrop = CreateSQDropdown(content, "", 260, BH:BuildSoundDropdownItems(), function(val)
        BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
        BH.settings.kelLustAlert.sound = val
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
            opacity           = (BH.settings and BH.settings.kelLustAlert and BH.settings.kelLustAlert.opacity) or 1.0,
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
        BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
        BH.settings.kelLustAlert.soundChannel = val
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
    rsNote:SetText("Check any sounds below to have the lust alert play a random pick from them instead of the Sound above. Leave all unchecked (default) to just use the Sound above.")
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
        BH.settings.kelLustAlert = BH.settings.kelLustAlert or {}
        BH.settings.kelLustAlert.opacity = val / 100
        BH:SaveSettings()
    end)
    opacitySlider:SetValue(math.floor(((BH.settings and BH.settings.kelLustAlert and BH.settings.kelLustAlert.opacity) or 1.0) * 100 + 0.5))
    opacitySlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelOpacitySlider = opacitySlider
    ns.Rows.AddTooltip(opacitySlider, "Alert Opacity %", "Transparency of the alert image.")
    yOffset = yOffset - 50

    local lockCb = CreateSQCheckbox(content, "Lock alert image position", function(val)
        BH.settings.kelAlertLocked = val
        BH:SaveSettings()
        if BH.kelAlertFrame then BH.kelAlertFrame:EnableMouse(not val) end
    end)
    lockCb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.kelLockCb = lockCb
    ns.Rows.AddTooltip(lockCb, "Lock alert image position", "Stops the alert image being dragged.")
    yOffset = yOffset - 28

    -- ── M+ DEATH TALLY ────────────────────────────────────────────────────
    do
        local div = CreateSQDivider(content, yOffset)
        div:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        yOffset = yOffset - 18
    end

    local dtHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dtHdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    dtHdr:SetText("M+ DEATH TALLY")
    ns.ApplyAccent(dtHdr, "text")
    yOffset = yOffset - 22

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

    self.kelTabContent = content
    content:SetHeight(math.abs(yOffset) + 20)

    self:RefreshJustForKelTab()
end

function BH:RefreshJustForKelTab()
    local content = self.kelTabContent
    if not content then return end

    -- Lust controls
    local la = (BH.settings and BH.settings.kelLustAlert) or {}
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
    if self.kelLockCb then
        self.kelLockCb:SetChecked(BH.settings and BH.settings.kelAlertLocked or false)
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


