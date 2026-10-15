-- Options/SettingsTab.lua
-- The Settings options page: frame size, layout and grow direction, lock and
-- scale, the class-colour accent, profiles (and their popups), and Reset.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split). It
-- reaches the core only through BH, so nothing needed re-declaring.

local addonName, ns = ...
local BH = ns.BH

local SQ_COLORS        = ns.SQ_COLORS
local ApplySQBackdrop  = ns.ApplySQBackdrop
local CreateSQButton   = ns.CreateSQButton
local CreateSQDropdown = ns.CreateSQDropdown
local CreateSQDivider  = ns.CreateSQDivider

-- ============================================================================
-- Settings Tab Content
-- ============================================================================

-- StaticPopup for New Profile name input
-- 12.x dialogs expose their edit box through GetEditBox(); the old dialog.editBox
-- field no longer exists, so reading it errored and Create appeared to do nothing.
local function CreateProfileFromPopup(name)
    name = name and name:match("^%s*(.-)%s*$") or ""
    if name == "" then return end

    local copyFrom = BH:GetActiveProfileName()
    -- Save current state before copying
    BH:SaveToProfile()
    if BH:CreateProfile(name, copyFrom) then
        BH:SwitchToProfile(name)
        BH:LoadAllFramePositions()
        BH:ApplyAllFrameScales()
        BH:UpdateFrameLock()
        BH:UpdateButtons()
        BH:RefreshSettingsTab()
        print("Squizzumables: Created and switched to profile '" .. name .. "'")
    else
        print("Squizzumables: Profile '" .. name .. "' already exists.")
    end
end

StaticPopupDialogs["SQUIZZUMABLES_NEW_PROFILE"] = {
    text = "Enter a name for the new profile:",
    button1 = "Create",
    button2 = "Cancel",
    hasEditBox = true,
    maxLetters = 32,
    OnAccept = function(dialog)
        local editBox = dialog.GetEditBox and dialog:GetEditBox() or dialog.EditBox or dialog.editBox
        CreateProfileFromPopup(editBox and editBox:GetText())
    end,
    EditBoxOnEnterPressed = function(editBox)
        CreateProfileFromPopup(editBox:GetText())
        editBox:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(editBox)
        editBox:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- After a theme change that is more than the accent (UI/Theme.lua
-- NeedsReload): the accent has already repainted, the panels and borders show
-- after a reload.
StaticPopupDialogs["SQUIZZUMABLES_THEME_RELOAD"] = {
    text = "%s is set. The accent has changed already; the panels and borders change after a reload. Reload now?",
    button1 = "Reload",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- StaticPopup for Delete Profile confirmation
StaticPopupDialogs["SQUIZZUMABLES_DELETE_PROFILE"] = {
    text = "Delete profile '%s'? Characters using this profile will be switched to Default.",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if BH:DeleteProfile(data) then
            -- If we deleted our own active profile, we're now on Default
            BH:LoadFromProfile("Default")
            BH.settings = SquizzumablesDB.settings
            BH.disabled = SquizzumablesDB.disabled
            BH.minDuration = SquizzumablesDB.minDuration
            BH.customItems = SquizzumablesDB.customItems
            BH:LoadAllFramePositions()
            BH:ApplyAllFrameScales()
            BH:UpdateFrameLock()
            BH:UpdateButtons()
            -- Default's Cooldown Manager layout, not the deleted profile's.
            if BH.cdm and BH.cdm.OnProfileChanged then BH.cdm:OnProfileChanged() end
            if BH.ApplyTargetDistance then BH:ApplyTargetDistance() end
            if BH.ApplyCursor then BH:ApplyCursor() end
            -- The new profile may have its own theme (accent repaints live).
            ns.Theme.Apply()
            BH:RefreshSettingsTab()
            print("Squizzumables: Deleted profile '" .. data .. "', switched to Default.")
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Shared modal for both directions: export fills it with a string to copy,
-- import waits for one to be pasted. One frame because the two are the same
-- thing -- a big selectable text box -- and having two would mean two places to
-- get the select-all and focus handling right.
function BH:ShowProfileStringDialog(mode, text)
    local f = self.profileIOFrame
    if not f then
        f = CreateFrame("Frame", "SQUIZZUMABLESProfileIO", UIParent, "BackdropTemplate")
        f:SetSize(520, 260)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(self) self:StartMoving() end)
        f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        ApplySQBackdrop(f, SQ_COLORS.bg, SQ_COLORS.border)
        table.insert(UISpecialFrames, "SQUIZZUMABLESProfileIO")

        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
        ns.ApplyAccent(f.title, "text")

        f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.hint:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
        f.hint:SetWidth(490)
        f.hint:SetJustifyH("LEFT")
        f.hint:SetWordWrap(true)
        f.hint:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

        local scroll = CreateFrame("ScrollFrame", "SQUIZZUMABLESProfileIOScroll", f, "UIPanelScrollFrameTemplate")
        ns.TuneScrollStep(scroll)
        scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -74)
        scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 46)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(460)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)
        f.edit = edit

        f.action = CreateSQButton(f, "Import", 110, 24)
        f.action:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 14)

        local closeBtn = CreateSQButton(f, "Close", 80, 24)
        closeBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 14)
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        self.profileIOFrame = f
    end

    f.edit:SetText(text or "")
    if mode == "export" then
        f.title:SetText("Export Profile")
        f.hint:SetText("Press Ctrl-A then Ctrl-C to copy this string. Anyone with Squizzumables "
            .. "can paste it into Import to get these settings.")
        f.action:Hide()
        -- Select it for them: the first thing anyone does here is select all.
        f.edit:SetFocus()
        f.edit:HighlightText()
    else
        f.title:SetText("Import Profile")
        f.hint:SetText("Paste a Squizzumables profile string here, then choose Import. "
            .. "It is added as a new profile -- nothing you already have is changed.")
        f.action:Show()
        f.action:SetText("Import")
        f.action:SetScript("OnClick", function()
            local data, err = ns.ProfileIO.Decode(f.edit:GetText())
            if not data then
                print("Squizzumables: " .. (err or "Could not read that string."))
                return
            end
            -- Never overwrite an existing profile silently: an import that
            -- quietly replaced the profile you were using would be unrecoverable.
            local name = data.name or "Imported"
            local base, n = name, 2
            while SquizzumablesDB.profiles and SquizzumablesDB.profiles[name] do
                name = base .. " (" .. n .. ")"
                n = n + 1
            end
            local ok, result = ns.ProfileIO.Apply(data, name)
            if not ok then
                print("Squizzumables: " .. tostring(result))
                return
            end
            print("Squizzumables: imported profile '" .. result .. "'. Select it from the Active Profile dropdown to use it.")
            f:Hide()
            BH:RefreshSettingsTab()
        end)
        f.edit:SetFocus()
    end
    f:Show()
end

function BH:BuildSettingsTab(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    ns.TuneScrollStep(scrollFrame)
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    local yOffset = -14
    local leftPad = 14

    -- === Theme Section ===
    -- First on the page and in a section of its own (user request
    -- 2026-10-16): it restyles the whole addon, so it should not read as one
    -- of the button settings below.
    local themeSection = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    themeSection:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    themeSection:SetText("THEME")
    ns.ApplyAccent(themeSection, "text")
    yOffset = yOffset - 18

    local themeNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    themeNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    themeNote:SetWidth(370)
    themeNote:SetJustifyH("LEFT")
    themeNote:SetText("One look for this window and every Squizzumables frame in the game.")
    themeNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 20

    -- The theme picker (2.0 phase 3), replacing the "Use class colour for
    -- headings and accents" checkbox. An accent change repaints live (every
    -- long-lived accent region is registered with ns.ApplyAccent); a preset
    -- with its own panels and borders needs a reload for the rest, so the
    -- player is offered one rather than left with half the UI in the old look.
    local themeItems = {}
    local themeTip = "One look for the options window and every frame in the game."
    for _, key in ipairs(ns.Theme.ORDER) do
        local p = ns.Theme.PRESETS[key]
        themeItems[#themeItems + 1] = { text = p.name, value = key }
        themeTip = themeTip .. "\n\n" .. p.name .. ": " .. p.tip
    end
    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown", label = "Theme", width = 200, items = themeItems,
        tooltip = themeTip,
        get = function() return ns.Theme.PresetKey() end,
        set = function(key)
            local from = ns.Theme.PresetKey()
            if key == from then return end
            ns.Theme.SetPreset(key)
            BH:SaveSettings()
            if ns.Theme.NeedsReload(from, key) then
                StaticPopup_Show("SQUIZZUMABLES_THEME_RELOAD", ns.Theme.PRESETS[key].name)
            end
        end,
    })

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Profiles Section ===
    local profileSection = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profileSection:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    profileSection:SetText("PROFILES")
    ns.ApplyAccent(profileSection, "text")
    yOffset = yOffset - 18

    local profileNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profileNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    profileNote:SetWidth(370)
    profileNote:SetJustifyH("LEFT")
    profileNote:SetText("Per-character settings. Assign a spec-specific profile below to auto-switch on spec change.")
    profileNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 34

    -- Active profile dropdown
    local function GetProfileDropdownItems()
        local items = {}
        for _, name in ipairs(BH:GetProfileList()) do
            table.insert(items, { text = name, value = name })
        end
        return items
    end

    local profileDropdown = CreateSQDropdown(content, "Active Profile", 200, GetProfileDropdownItems(), function(value)
        if value == BH:GetActiveProfileName() then return end
        BH:SwitchToProfile(value)
        BH:LoadAllFramePositions()
        BH:ApplyAllFrameScales()
        BH:UpdateFrameLock()
        BH:UpdateButtons()
        BH:RefreshSettingsTab()
        BH:RefreshItemList()
        BH:RefreshRaidToolsTab()
        BH:RefreshTextRemindersTab()
    end)
    profileDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.profileDropdown = profileDropdown
    ns.Rows.AddTooltip(profileDropdown, "Active Profile", "Which settings profile this character uses. Profiles hold every setting and every frame position, so you can keep one layout for raiding and another for M+.")
    yOffset = yOffset - 50

    -- Spec-specific profile dropdown
    -- Build items: first entry = none (use character-level profile), then all profiles
    local function GetSpecProfileDropdownItems()
        local specIndex = GetSpecialization()
        local specName = "Current Spec"
        if specIndex then
            local _, name = GetSpecializationInfo(specIndex)
            if name then specName = name end
        end
        local items = { { text = "\226\128\148 (use character profile)", value = "" } }
        for _, name in ipairs(BH:GetProfileList()) do
            table.insert(items, { text = name, value = name })
        end
        return items, specName
    end

    local specItems, specName = GetSpecProfileDropdownItems()
    local specProfileDropdown = CreateSQDropdown(content, "Profile for " .. specName, 200, specItems, function(value)
        local profileName = (value and value ~= "") and value or nil
        BH:SetSpecProfile(profileName)
    end)
    specProfileDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    specProfileDropdown:SetSelectedValue(BH:GetSpecProfile() or "")
    self.specProfileDropdown = specProfileDropdown
    ns.Rows.AddTooltip(specProfileDropdown, "Spec Profile", "Override the character profile for this specialisation only. Leave unset to always use the character profile.")
    yOffset = yOffset - 50

    -- Profile action buttons (row)
    local newProfileBtn = CreateSQButton(content, "New", 80, 24)
    newProfileBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    newProfileBtn:SetScript("OnClick", function()
        StaticPopup_Show("SQUIZZUMABLES_NEW_PROFILE")
    end)

    local deleteProfileBtn = CreateSQButton(content, "Delete", 80, 24, SQ_COLORS.danger)
    deleteProfileBtn:SetPoint("LEFT", newProfileBtn, "RIGHT", 6, 0)
    deleteProfileBtn:SetScript("OnClick", function()
        local name = BH:GetActiveProfileName()
        if name == "Default" then
            print("Squizzumables: Cannot delete the Default profile.")
            return
        end
        local popup = StaticPopup_Show("SQUIZZUMABLES_DELETE_PROFILE", name)
        if popup then popup.data = name end
    end)

    local copyToDefaultBtn = CreateSQButton(content, "Copy to Default", 120, 24)
    copyToDefaultBtn:SetPoint("LEFT", deleteProfileBtn, "RIGHT", 6, 0)
    copyToDefaultBtn:SetScript("OnClick", function()
        BH:UpdateDefaultProfile()
        print("Squizzumables: Current settings copied to Default profile.")
    end)
    yOffset = yOffset - 32

    local exportBtn = CreateSQButton(content, "Export", 80, 24)
    exportBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    exportBtn:SetScript("OnClick", function()
        local str, err = ns.ProfileIO.Export()
        if not str then
            print("Squizzumables: " .. (err or "Could not export that profile."))
            return
        end
        BH:ShowProfileStringDialog("export", str)
    end)
    ns.Rows.AddTooltip(exportBtn, "Export",
        "Produces a shareable string for the active profile. Only settings you have changed from "
        .. "the defaults are included, which keeps the string short and means importing it into a "
        .. "newer version picks up any newly added defaults.")

    local importBtn = CreateSQButton(content, "Import", 80, 24)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 6, 0)
    importBtn:SetScript("OnClick", function()
        BH:ShowProfileStringDialog("import", "")
    end)
    ns.Rows.AddTooltip(importBtn, "Import",
        "Paste a profile string from someone else. It always arrives as a new profile, so nothing "
        .. "you already have is overwritten.")
    yOffset = yOffset - 32

    local resetFromDefaultBtn = CreateSQButton(content, "Reset from Default", 140, 24)
    resetFromDefaultBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    resetFromDefaultBtn:SetScript("OnClick", function()
        local defaultProfile = SquizzumablesDB.profiles and SquizzumablesDB.profiles["Default"]
        if not defaultProfile then return end
        -- Overwrite the active profile with Default's data
        local activeName = BH:GetActiveProfileName()
        SquizzumablesDB.profiles[activeName] = CopyTable(defaultProfile)
        BH:LoadFromProfile(activeName)
        BH.settings = SquizzumablesDB.settings
        BH.disabled = SquizzumablesDB.disabled
        BH.minDuration = SquizzumablesDB.minDuration
        BH.customItems = SquizzumablesDB.customItems
        BH:LoadAllFramePositions()
        BH:ApplyAllFrameScales()
        BH:UpdateFrameLock()
        BH:UpdateButtons()
        -- Default's Cooldown Manager layout came across with the CopyTable
        -- above, since it lives on the profile as of 1.70. Rebuild so it shows.
        if BH.cdm and BH.cdm.OnProfileChanged then BH.cdm:OnProfileChanged() end
        if BH.ApplyTargetDistance then BH:ApplyTargetDistance() end
        if BH.ApplyCursor then BH:ApplyCursor() end
        -- The new profile may have its own theme (accent repaints live).
        ns.Theme.Apply()
        BH:RefreshSettingsTab()
        BH:RefreshItemList()
        BH:RefreshRaidToolsTab()
        BH:RefreshTextRemindersTab()
        print("Squizzumables: Reset to Default profile settings.")
    end)
    yOffset = yOffset - 34

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Appearance Section ===
    local sectionLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sectionLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    sectionLabel:SetText("BUTTON APPEARANCE")
    ns.ApplyAccent(sectionLabel, "text")
    yOffset = yOffset - 22

    -- Button Size
    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Button Size",
        width = 300, min = 20, max = 64, step = 2,
        tooltip = "Width and height of each reminder button, in pixels.",
        get = function() return BH.settings.buttonSize or 36 end,
        set = function(value)
            BH.settings.buttonSize = value
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Button Spacing",
        width = 300, min = 5, max = 20, step = 1,
        tooltip = "Gap between reminder buttons, in pixels.",
        get = function() return BH.settings.buttonSpacing or 5 end,
        set = function(value)
            BH.settings.buttonSpacing = value
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Icon Shape",
        width = 160,
        items = ns.Shapes.DropdownItems,
        tooltip = "Cuts each reminder icon to a shape, and the glow follows it. The same shapes as the Cooldown Manager, so the two can match.",
        get = function() return BH.settings.buttonIconShape or "none" end,
        set = function(v)
            BH.settings.buttonIconShape = v
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show Label Text",
        tooltip = "Show the name under each reminder button. Turn off for a more compact row of icons.",
        get = function() return BH.settings.showLabelText and true or false end,
        set = function(v)
            BH.settings.showLabelText = v
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
    })

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Layout Section ===
    local layoutSection = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    layoutSection:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    layoutSection:SetText("LAYOUT")
    ns.ApplyAccent(layoutSection, "text")
    yOffset = yOffset - 22

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Layout Direction",
        width = 160,
        tooltip = "Whether the reminder buttons lay out in a row or a column.",
        items = {
            { text = "Horizontal", value = "HORIZONTAL" },
            { text = "Vertical",   value = "VERTICAL" },
        },
        get = function() return BH.settings.layoutDirection or "HORIZONTAL" end,
        set = function(value)
            BH.settings.layoutDirection = value
            -- Not every grow direction is valid in every layout, so let the
            -- existing validator correct it; the grow row below rebuilds its
            -- own options from this on the refresh that follows.
            BH:ValidateGrowDirection()
            BH:SaveSettings()
            BH:UpdateButtons()
            BH:UpdateFrameAnchor()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Grow Direction",
        width = 160,
        tooltip = "Which way new buttons are added as the number of reminders changes. The opposite "
               .. "edge stays put: growing down keeps the top button where you placed it, growing "
               .. "outward keeps the middle.",
        -- A function, so the options follow the layout above rather than the
        -- layout handler reaching across to rewrite them.
        items = function()
            return BH:GetGrowItemsForLayout(BH.settings.layoutDirection or "HORIZONTAL")
        end,
        get = function() return BH.settings.growDirection end,
        set = function(value)
            BH.settings.growDirection = value
            BH:SaveSettings()
            BH:UpdateButtons()
            BH:UpdateFrameAnchor()
        end,
    })
    -- No Anchor Point control since 2.0: the grow direction decides which
    -- edge stays put (BH:GrowAnchor).

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Lock Frame Position",
        tooltip = "Stops the reminder buttons being dragged. Unlock Frames overrides this while you are positioning things.",
        get = function() return BH.settings.frameLocked and true or false end,
        set = function(v)
            BH.settings.frameLocked = v
            BH:SaveSettings()
            BH:UpdateFrameLock()
        end,
    })

    -- UI/EditMode.lua follows Blizzard's Edit Mode while this is on.
    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Unlock With Blizzard's Edit Mode",
        tooltip = "Opening the game's Edit Mode (Esc > Edit Mode) unlocks every Squizzumables frame too, "
               .. "and closing it locks them again, so everything moves from one place. Unlock Frames "
               .. "works either way.",
        get = function() return BH.settings.followBlizzardEditMode ~= false end,
        set = function(v)
            BH.settings.followBlizzardEditMode = v
            BH:SaveSettings()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "BUTTON TEXT" })

    -- Where the label sits; the X/Y offsets below count from here
    -- (BH.PlaceButtonLabel in Reminders/Helpers.lua).
    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown", label = "Label Position", width = 200,
        items = {
            { text = "Auto",            value = "auto" },
            { text = "Below the icon",  value = "BOTTOM" },
            { text = "Above the icon",  value = "TOP" },
            { text = "Right of the icon", value = "RIGHT" },
            { text = "Left of the icon",  value = "LEFT" },
            { text = "On the icon",     value = "CENTER" },
        },
        tooltip = "Where the name goes on each button. Auto puts it below the icon, or to the right of "
               .. "it in a vertical layout. The X and Y offsets below move it from there. "
               .. "Beside the icon (left or right) in a horizontal row, raise Button Spacing so the "
               .. "names have room.",
        get = function() return BH.settings.buttonLabelAnchor or "auto" end,
        set = function(v)
            BH.settings.buttonLabelAnchor = v
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
        disabled = function() return not BH.settings.showLabelText end,
    })

    -- Six sliders that differ only in label, range and which setting they
    -- write, so they are a table rather than six near-identical blocks.
    for _, s in ipairs({
        { key = "buttonLabelFontSize",  label = "Label Font Size",          min = 6,   max = 24, default = 11,
          tip = "Size of the name text under each button." },
        { key = "buttonTimerFontSize",  label = "Timer Font Size",          min = 6,   max = 24, default = 12,
          tip = "Size of the remaining-time countdown drawn on each button." },
        { key = "buttonCountFontSize",  label = "Count Font Size",          min = 6,   max = 24, default = 11,
          tip = "Size of the bag-quantity number in the corner of each button." },
        { key = "buttonHeaderFontSize", label = "Header Font Size (MH/OH)", min = 6,   max = 24, default = 10,
          tip = "Size of the small header above a button, such as the MH and OH markers on weapon oils." },
        { key = "buttonLabelOffsetX",   label = "Label X Offset",           min = -20, max = 20, default = 0,
          tip = "Move the label left or right from its Label Position." },
        { key = "buttonLabelOffsetY",   label = "Label Y Offset",           min = -20, max = 20, default = 0,
          tip = "Move the label up or down from its Label Position." },
    }) do
        yOffset = yOffset - ns.Rows.Add(content, yOffset, {
            type = "slider",
            label = s.label,
            width = 300, min = s.min, max = s.max, step = 1,
            tooltip = s.tip,
            get = function() return BH.settings[s.key] or s.default end,
            set = function(value)
                BH.settings[s.key] = value
                BH:SaveSettings()
                BH:UpdateButtons()
            end,
            -- The label offsets and font size only matter when labels are on.
            disabled = (s.key:find("Label") ~= nil)
                and function() return not BH.settings.showLabelText end
                or nil,
        })
    end


    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Preview & Reset Section ===
    local toolsSection = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toolsSection:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    toolsSection:SetText("TOOLS")
    ns.ApplyAccent(toolsSection, "text")
    yOffset = yOffset - 24


    -- Reset button
    local resetBtn = CreateSQButton(content, "Reset to Defaults", 140, 26, SQ_COLORS.danger)
    resetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    resetBtn:SetScript("OnClick", function()
        BH.settings.buttonSize = BH.defaultSettings.buttonSize
        BH.settings.buttonSpacing = BH.defaultSettings.buttonSpacing
        BH.settings.frameLocked = BH.defaultSettings.frameLocked
        BH.settings.growDirection = BH.defaultSettings.growDirection
        BH.settings.layoutDirection = BH.defaultSettings.layoutDirection
        BH.settings.showLabelText = BH.defaultSettings.showLabelText
        BH:ResetFramePosition()
        BH:SaveSettings()
        BH:UpdateFrameLock()
        BH:RefreshSettingsTab()
        BH:UpdateButtons()
        BH:UpdateFrameAnchor()
    end)
    yOffset = yOffset - 40

    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "SHOW IN" })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "text",
        label = "Which content the reminders appear in. Everything the addon shows -- buttons and text reminders alike -- is hidden where these are unticked.",
    })

    for _, ct in ipairs(BH.CONTENT_TYPES) do
        yOffset = yOffset - ns.Rows.Add(content, yOffset, {
            type = "check",
            label = ct.label,
            get = function()
                local t = BH.settings and BH.settings.contentTypes
                if t and t[ct.key] ~= nil then return t[ct.key] end
                return ct.default
            end,
            set = function(v)
                BH.settings.contentTypes = BH.settings.contentTypes or {}
                BH.settings.contentTypes[ct.key] = v
                BH:SaveSettings()
                BH:UpdateButtons()
                BH:UpdateAllReminders()
            end,
        })
    end

    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "MISC" })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Glow reminder buttons",
        tooltip = "Glows each reminder button while it is showing, so they catch the eye without you having to look at them.",
        get = function() return BH.settings.glowReminderButtons ~= false end,
        set = function(v)
            BH.settings.glowReminderButtons = v
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Glow style",
        width = 160,
        items = {
            { text = "Animated",     value = "animated" },
            { text = "Pulsing ring", value = "ring" },
        },
        tooltip = "Animated plays the game's proc glow, the same one the Cooldown Manager uses, in the icon's shape. Pulsing ring is a simple fading ring you can tune with the pulse settings below.",
        get = function() return BH.settings.buttonGlowStyle or "animated" end,
        set = function(v)
            BH.settings.buttonGlowStyle = v
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
        disabled = function() return BH.settings.glowReminderButtons == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "color",
        label = "Glow colour",
        tooltip = "Colour of the glow around reminder buttons. The square animated glow keeps the game's own gold; shaped icons and the pulsing ring take this colour.",
        get = function()
            local c = BH.settings.glowColor or {}
            return c.r or 1.0, c.g or 0.82, c.b or 0.0
        end,
        set = function(r, g, b)
            BH.settings.glowColor = { r = r, g = g, b = b }
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
        disabled = function() return BH.settings.glowReminderButtons == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Pulse the glow",
        tooltip = "Fade the pulsing ring in and out. Turn this off for a steady ring instead.",
        get = function() return BH.settings.glowPulse ~= false end,
        set = function(v)
            BH.settings.glowPulse = v
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
        disabled = function()
            return BH.settings.glowReminderButtons == false
                or BH.settings.buttonGlowStyle ~= "ring"
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Pulse speed (seconds)",
        width = 300, min = 0.2, max = 2.0, step = 0.1,
        tooltip = "How long one fade takes. Lower is faster and more urgent.",
        get = function() return BH.settings.glowPulseSpeed or 0.6 end,
        set = function(v)
            BH.settings.glowPulseSpeed = v
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
        disabled = function()
            return BH.settings.glowReminderButtons == false
                or BH.settings.buttonGlowStyle ~= "ring"
                or BH.settings.glowPulse == false
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Pulse depth",
        width = 300, min = 0, max = 90, step = 5,
        tooltip = "How far the glow fades at its dimmest. 0 barely dims; higher fades further out.",
        get = function() return math.floor((1 - (BH.settings.glowMinAlpha or 0.35)) * 100) end,
        set = function(v)
            -- Stored as the alpha it dims *to*, shown as how far it fades --
            -- "more depth" reading as a bigger number is the way round a player
            -- expects.
            BH.settings.glowMinAlpha = 1 - (v / 100)
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
        disabled = function()
            return BH.settings.glowReminderButtons == false
                or BH.settings.buttonGlowStyle ~= "ring"
                or BH.settings.glowPulse == false
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show minimap button",
        tooltip = "A button on the minimap: left-click for settings, right-click to unlock frames, drag to move it round the edge. The addon is also in Blizzard's addon compartment either way.",
        get = function() return not BH.settings.minimapButtonHidden end,
        set = function(v)
            BH.settings.minimapButtonHidden = not v
            BH:SaveSettings()
            BH:UpdateMinimapButton()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Guild Invite on Right-Click",
        tooltip = "Adds a Guild Invite entry to the right-click menu on player names and unit frames.",
        get = function() return BH.settings.guildInviteContextEnabled == true end,
        set = function(v)
            BH.settings.guildInviteContextEnabled = v
            BH:SaveSettings()
        end,
    })

    -- Set scroll child height
    content:SetHeight(math.abs(yOffset) + 20)
end

-- Get grow direction dropdown items for a layout
function BH:GetGrowItemsForLayout(layout)
    if layout == "VERTICAL" then
        return {
            { text = "Up", value = "UP" },
            { text = "Down", value = "DOWN" },
        }
    else
        return {
            { text = "Left", value = "LEFT" },
            { text = "Right", value = "RIGHT" },
            { text = "Outward", value = "OUTWARD" },
        }
    end
end

-- Auto-correct grow direction when layout changes
function BH:ValidateGrowDirection()
    local layout = self.settings.layoutDirection or "HORIZONTAL"
    local grow = self.settings.growDirection or "RIGHT"
    if layout == "VERTICAL" then
        if grow == "LEFT" or grow == "OUTWARD" then
            self.settings.growDirection = "DOWN"
        elseif grow == "RIGHT" then
            self.settings.growDirection = "DOWN"
        end
    else
        if grow == "UP" then
            self.settings.growDirection = "LEFT"
        elseif grow == "DOWN" then
            self.settings.growDirection = "RIGHT"
        end
    end
end

-- Refresh settings tab values to match current settings
function BH:RefreshSettingsTab()
    if not self.settings then return end
    -- Every option row syncs itself from its own get(). What is left here is
    -- the two profile dropdowns, whose *item lists* change as profiles are
    -- created and deleted, and the unlock button caption.
    ns.Rows.RefreshAll()

    if self.profileDropdown then
        local items = {}
        for _, name in ipairs(self:GetProfileList()) do
            table.insert(items, { text = name, value = name })
        end
        self.profileDropdown:SetItems(items)
        self.profileDropdown:SetSelectedValue(self:GetActiveProfileName())
    end

    if self.specProfileDropdown then
        local specIndex = GetSpecialization()
        local specName = "Current Spec"
        if specIndex then
            local _, name = GetSpecializationInfo(specIndex)
            if name then specName = name end
        end
        local specItems = { { text = "\226\128\148 (use character profile)", value = "" } }
        for _, name in ipairs(self:GetProfileList()) do
            table.insert(specItems, { text = name, value = name })
        end
        self.specProfileDropdown.label:SetText("Profile for " .. specName)
        self.specProfileDropdown:SetItems(specItems)
        self.specProfileDropdown:SetSelectedValue(self:GetSpecProfile() or "")
    end

    if self.unlockBtn then
        self.unlockBtn:SetText(self.unlockMode and "Lock Frames" or "Unlock Frames")
    end
end
