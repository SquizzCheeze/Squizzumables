-- UI/Widgets.lua
-- The addon's hand-rolled widget kit: colour palette, backdrop helper, and the
-- CreateSQ* constructors used to build every options panel in the addon.
--
-- Loads before Squizzumables.lua so the core and the module files can all take
-- local aliases off `ns` rather than reaching for globals. Depends on nothing
-- else in the addon.

local addonName, ns = ...

-- Which mouse edge our secure action buttons should fire on.
--
-- Registering both "AnyDown" and "AnyUp" makes a secure button fire its action
-- twice per physical click; the second attempt lands inside the GCD of the
-- first, which at best wastes a call and at worst eats the click. Blizzard's
-- action buttons pick one edge from the ActionButtonUseKeyDown CVar, so match
-- that and our buttons behave like the player's normal bars.
--
-- Falls back to the "Up" edge, which works regardless of the setting.
-- Pass "Left" for buttons that should only respond to the left mouse button.
local function SQ_GetClickEdge(whichButton)
    local prefix = whichButton == "Left" and "LeftButton" or "Any"
    if GetCVarBool and GetCVarBool("ActionButtonUseKeyDown") then
        return prefix .. "Down"
    end
    return prefix .. "Up"
end

-- Color palette
local SQ_COLORS = {
    bg          = { 0.06, 0.06, 0.08, 0.96 },
    titleBar    = { 0.10, 0.10, 0.13, 1 },
    border      = { 0.25, 0.25, 0.30, 1 },
    accent      = { 0.78, 0.65, 0.30, 1 },     -- warm gold
    accentDim   = { 0.55, 0.45, 0.20, 0.6 },
    text        = { 0.90, 0.90, 0.90, 1 },
    textDim     = { 0.55, 0.55, 0.58, 1 },
    textBright  = { 1, 1, 1, 1 },
    control     = { 0.14, 0.14, 0.17, 1 },
    controlHi   = { 0.20, 0.20, 0.24, 1 },
    danger      = { 0.75, 0.25, 0.25, 1 },
    dangerDim   = { 0.55, 0.20, 0.20, 0.6 },
    section     = { 0.18, 0.18, 0.22, 0.5 },
    tabActive   = { 0.14, 0.14, 0.17, 1 },
    tabInactive = { 0.08, 0.08, 0.10, 1 },
}
-- Helper: create a thin-bordered backdrop on a frame
local function ApplySQBackdrop(frame, bgColor, borderColor)
    if not frame.SetBackdrop then
        Mixin(frame, BackdropTemplateMixin)
    end
    frame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(unpack(bgColor or SQ_COLORS.bg))
    frame:SetBackdropBorderColor(unpack(borderColor or SQ_COLORS.border))
end

-- Helper: styled button
local function CreateSQButton(parent, text, width, height, color)
    color = color or SQ_COLORS.accent
    local dimColor = (color == SQ_COLORS.danger) and SQ_COLORS.dangerDim or SQ_COLORS.accentDim
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width or 100, height or 26)
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
    btn:SetBackdropBorderColor(dimColor[1], dimColor[2], dimColor[3], dimColor[4])
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText(text)
    label:SetTextColor(color[1], color[2], color[3])
    btn.label = label
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 1)
        self:SetBackdropBorderColor(color[1], color[2], color[3], 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        self:SetBackdropBorderColor(dimColor[1], dimColor[2], dimColor[3], dimColor[4])
    end)
    btn.SetText = function(self, t) self.label:SetText(t) end
    btn.GetText = function(self) return self.label:GetText() end
    return btn
end

-- Helper: styled slider
local function CreateSQSlider(parent, labelText, width, minVal, maxVal, step)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width, 40)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(labelText)
    label:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local valueText = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valueText:SetPoint("TOPRIGHT", 0, 0)
    valueText:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])

    -- Track background
    local track = CreateFrame("Frame", nil, container, "BackdropTemplate")
    track:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
    track:SetSize(width, 6)
    track:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    track:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
    track:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.5)

    local slider = CreateFrame("Slider", nil, container, "BackdropTemplate")
    slider:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 3)
    slider:SetPoint("BOTTOMRIGHT", track, "BOTTOMRIGHT", 0, -3)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetOrientation("HORIZONTAL")

    -- Thumb
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 14)
    thumb:SetColorTexture(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.9)
    slider:SetThumbTexture(thumb)

    -- Fill bar
    local fill = slider:CreateTexture(nil, "ARTWORK")
    fill:SetHeight(4)
    fill:SetPoint("LEFT", track, "LEFT", 1, 0)
    fill:SetColorTexture(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.35)

    slider:SetScript("OnValueChanged", function(self, value, userInput)
        value = math.floor(value / step + 0.5) * step
        valueText:SetText(tostring(math.floor(value)))
        -- Update fill width
        local range = maxVal - minVal
        if range > 0 then
            local pct = (value - minVal) / range
            fill:SetWidth(math.max(1, pct * width))
        end
        if self.onValueChanged then self.onValueChanged(value, userInput) end
    end)

    container.slider = slider
    container.SetValue = function(self, v)
        self.slider:SetValue(v)
    end
    container.GetValue = function(self)
        return self.slider:GetValue()
    end
    container.SetAfterValueChanged = function(self, fn)
        self.slider.onValueChanged = fn
    end
    return container
end

-- Helper: styled checkbox
local function CreateSQCheckbox(parent, labelText, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(250, 22)

    local box = CreateFrame("CheckButton", nil, container)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", 0, 0)

    -- Box background
    local boxBG = box:CreateTexture(nil, "BACKGROUND")
    boxBG:SetAllPoints()
    boxBG:SetColorTexture(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)

    -- Box border
    local boxBorder = CreateFrame("Frame", nil, box, "BackdropTemplate")
    boxBorder:SetAllPoints()
    boxBorder:SetBackdrop({
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    boxBorder:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)

    -- Checkmark
    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetSize(12, 12)
    check:SetPoint("CENTER")
    check:SetColorTexture(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.9)
    box:SetCheckedTexture(check)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", box, "RIGHT", 8, 0)
    label:SetText(labelText)
    label:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])

    box:SetScript("OnClick", function(self)
        if onChange then onChange(self:GetChecked()) end
    end)

    box:SetScript("OnEnter", function(self)
        boxBorder:SetBackdropBorderColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.6)
    end)
    box:SetScript("OnLeave", function(self)
        boxBorder:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
    end)

    container.checkbox = box
    container.SetChecked = function(self, v) self.checkbox:SetChecked(v) end
    container.GetChecked = function(self) return self.checkbox:GetChecked() end
    return container
end

-- Helper: styled color swatch (opens Blizzard ColorPickerFrame)
local function CreateSQColorPicker(parent, labelText, r, g, b, a, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(250, 22)

    local swatch = CreateFrame("Button", nil, container, "BackdropTemplate")
    swatch:SetSize(16, 16)
    swatch:SetPoint("LEFT", 0, 0)
    swatch:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    swatch:SetBackdropColor(r or 0, g or 0, b or 0, 1)
    swatch:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", swatch, "RIGHT", 8, 0)
    label:SetText(labelText)
    label:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])

    swatch:SetScript("OnClick", function()
        local info = {}
        info.r, info.g, info.b = r or 0, g or 0, b or 0
        info.opacity = a or 1
        info.hasOpacity = true
        info.swatchFunc = function()
            local cr, cg, cb = ColorPickerFrame:GetColorRGB()
            local ca = ColorPickerFrame:GetColorAlpha()
            swatch:SetBackdropColor(cr, cg, cb, 1)
            r, g, b, a = cr, cg, cb, ca
            if onChange then onChange(cr, cg, cb, ca) end
        end
        info.opacityFunc = info.swatchFunc
        info.cancelFunc = function(prev)
            swatch:SetBackdropColor(prev.r, prev.g, prev.b, 1)
            r, g, b, a = prev.r, prev.g, prev.b, prev.opacity
            if onChange then onChange(prev.r, prev.g, prev.b, prev.opacity) end
        end
        ColorPickerFrame:SetupColorPickerAndShow(info)
    end)

    swatch:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.6)
    end)
    swatch:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
    end)

    container.swatch = swatch
    container.SetColor = function(self, nr, ng, nb, na)
        r, g, b, a = nr, ng, nb, na
        self.swatch:SetBackdropColor(nr, ng, nb, 1)
    end
    return container
end

-- Helper: styled dropdown
local function CreateSQDropdown(parent, labelText, width, items, onSelect)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width, 44)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(labelText)
    label:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetSize(width, 24)
    btn:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
    btn:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)

    local selectedText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    selectedText:SetPoint("LEFT", 8, 0)
    selectedText:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])

    local arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetText("v")
    arrow:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    -- Dropdown menu frame
    local menu = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menu:SetWidth(width)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    menu:SetBackdropColor(SQ_COLORS.bg[1], SQ_COLORS.bg[2], SQ_COLORS.bg[3], 0.98)
    menu:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 1)
    menu:Hide()

    local selectedValue = nil

    local function BuildMenu()
        -- Clear old children
        for _, child in pairs({menu:GetChildren()}) do child:Hide(); child:SetParent(nil) end

        -- Measure the widest label so the background fully encases all text.
        -- 4px left margin + 6px text pad + text + 8px right pad = text + 18px total extra.
        local scratch = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        local maxTextW = 0
        for _, item in ipairs(items) do
            scratch:SetText(item.text)
            local tw = scratch:GetStringWidth()
            if tw > maxTextW then maxTextW = tw end
        end
        scratch:SetText("")
        local menuWidth = math.max(width, maxTextW + 18)
        menu:SetWidth(menuWidth)

        local y = -4
        for _, item in ipairs(items) do
            local opt = CreateFrame("Button", nil, menu)
            opt:SetSize(menuWidth - 8, 20)
            opt:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, y)

            local optBG = opt:CreateTexture(nil, "BACKGROUND")
            optBG:SetAllPoints()
            optBG:SetColorTexture(0, 0, 0, 0)

            local optText = opt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            optText:SetPoint("LEFT", 6, 0)
            optText:SetText(item.text)
            if item.value == selectedValue then
                optText:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
            else
                optText:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])
            end

            opt:SetScript("OnEnter", function() optBG:SetColorTexture(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 1) end)
            opt:SetScript("OnLeave", function() optBG:SetColorTexture(0, 0, 0, 0) end)
            opt:SetScript("OnClick", function()
                selectedValue = item.value
                selectedText:SetText(item.text)
                menu:Hide()
                if onSelect then onSelect(item.value) end
            end)
            y = y - 20
        end
        menu:SetHeight(math.abs(y) + 4)
    end

    btn:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
        else
            BuildMenu()
            menu:Show()
        end
    end)
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.6)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
    end)

    -- Close menu when clicking elsewhere
    local closer = CreateFrame("Button", nil, menu)
    closer:SetAllPoints(UIParent)
    closer:SetFrameStrata("FULLSCREEN")
    closer:SetScript("OnClick", function() menu:Hide(); closer:Hide() end)
    closer:Hide()
    menu:HookScript("OnShow", function() closer:Show() end)
    menu:HookScript("OnHide", function() closer:Hide() end)

    container.btn = btn
    container.label = label
    container.selectedText = selectedText
    container.SetSelectedValue = function(self, val)
        selectedValue = val
        for _, item in ipairs(items) do
            if item.value == val then
                selectedText:SetText(item.text)
                break
            end
        end
    end
    container.GetSelectedValue = function(self) return selectedValue end
    container.SetItems = function(self, newItems)
        items = newItems
    end
    return container
end

-- Helper: section divider line
local function CreateSQDivider(parent, yOffset)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yOffset)
    line:SetColorTexture(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.3)
    return line
end

-- ============================================================================
-- Exports
-- ============================================================================

ns.SQ_COLORS           = SQ_COLORS
ns.ApplySQBackdrop     = ApplySQBackdrop
ns.SQ_GetClickEdge     = SQ_GetClickEdge
ns.CreateSQButton      = CreateSQButton
ns.CreateSQSlider      = CreateSQSlider
ns.CreateSQCheckbox    = CreateSQCheckbox
ns.CreateSQColorPicker = CreateSQColorPicker
ns.CreateSQDropdown    = CreateSQDropdown
ns.CreateSQDivider     = CreateSQDivider
