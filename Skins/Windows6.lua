-- Skins/Windows6.lua
-- Batch 6, the rest: the settings window and chat settings, click casting,
-- the addon list, help, error and debug windows, Edit Mode, death recap, the
-- breath / fatigue bars, loss of control, toasts, battleground scores, the
-- vault, landing pages, choices, delves, item windows (sockets, upgrades,
-- scrapping, catalyst), the barber, stables, flight maps, the black market,
-- transmog and housing.
--
-- Read against ElvUI's skin for each window, behaviour only, on both clients.
-- The last few big ones (transmog, housing) get the general pass plus their
-- main controls rather than a hand-placed copy of ElvUI's layout.

local _, ns = ...
local SK = ns.Skins
local Hide = SK.Hide
local FOREVER = ns.BH.IS_FOREVER

local function G(name) return _G[name] end

local function Buttons(...)
    for i = 1, select("#", ...) do SK.Button(select(i, ...)) end
end

local function Hook(obj, method, fn)
    if obj and obj[method] then hooksecurefunc(obj, method, fn) end
end

local function HookGlobal(name, fn)
    if _G[name] then hooksecurefunc(name, fn) end
end

local function HideKeys(frame, ...)
    if not frame then return end
    for i = 1, select("#", ...) do Hide(frame[select(i, ...)]) end
end

-- A window: art gone, our panel, then the general pass over its controls.
local function Plain(f, x1, y1, x2, y2)
    if not f or not SK.Once(f) then return end
    if f.Header then SK.Strip(f.Header) end
    SK.Window(f, x1, y1, x2, y2)
    SK.Auto(f)
end

local function Each(box, fn)
    if box then SK.EachRow(box, fn) end
end

-- ============================================================================
-- Settings window
-- ============================================================================

-- The game / addons tabs across the top: a box under the text, no art.
local function MinimalTab(tab)
    if not tab or not SK.Once(tab) then return end
    SK.Strip(tab)
    tab:SetAlpha(1)
    SK.Backdrop(tab, "panel", 1, -10, -1, -2)
    SK.Hover(tab)
end

local function SettingsDropdown(control)
    if not control then return end
    if control.Dropdown then SK.Dropdown(control.Dropdown) end
    if control.DecrementButton then SK.Arrow(control.DecrementButton, "left") end
    if control.IncrementButton then SK.Arrow(control.IncrementButton, "right") end
end

local function SettingsCheck(cb)
    if not cb or not SK.Once(cb) then return end
    SK.Check(cb)
end

local function ControlGroup(controls)
    if not controls then return end
    for _, child in ipairs({ controls:GetChildren() }) do
        if child.SliderWithSteppers then SK.StepSlider(child.SliderWithSteppers) end
        if child.Checkbox then SettingsCheck(child.Checkbox) end
        if child.Control then SettingsDropdown(child.Control) end
    end
end

local EXPAND = { [true] = "common-button-list-minus", [false] = "common-button-list-plus" }

local function KeybindButtons(row)
    if not row.bindingsPool then return end
    for panel in row.bindingsPool:EnumerateActive() do
        if SK.Once(panel) then Buttons(panel.Button1, panel.Button2) end
        if panel.CustomButton then SK.Button(panel.CustomButton) end
    end
end

local function SettingsRow(row)
    if row.Checkbox then SettingsCheck(row.Checkbox) end
    if row.Control then SettingsDropdown(row.Control) end
    if row.SliderWithSteppers then SK.StepSlider(row.SliderWithSteppers) end
    if row.Controls then
        for _, c in ipairs(row.Controls) do
            if c.SliderWithSteppers then SK.StepSlider(c.SliderWithSteppers) end
        end
    end
    if row.BaseTab then MinimalTab(row.BaseTab) end
    if row.RaidTab then MinimalTab(row.RaidTab) end
    ControlGroup(row.BaseQualityControls)
    ControlGroup(row.RaidQualityControls)
    if row.PushToTalkKeybindButton then SK.Button(row.PushToTalkKeybindButton) end
    Buttons(row.Button1, row.Button2)
    if not SK.Once(row) then return end
    -- A section box (the graphics page's quality groups).
    if row.NineSlice then
        row.NineSlice:SetAlpha(0)
        SK.Backdrop(row, "panel", 15, -30, -30, -5)
    end
    local btn = row.Button
    if btn then
        if not row.OnExpandedChanged then
            SK.Button(btn)
        else
            -- A collapsible header (key bindings): a flat bar with a plus / minus.
            SK.Strip(btn)
            HideKeys(btn, "Left", "Middle", "Right")
            local b = SK.Backdrop(btn, "button", 2, -1, -2, 3)
            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetColorTexture(0.8, 0.8, 0, 0.6)
            hl:SetBlendMode("ADD")
            hl:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
            hl:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
            local tex = b:CreateTexture(nil, "OVERLAY")
            tex:SetPoint("RIGHT", -10, 0)
            local function Expand(self, expanded)
                tex:SetAtlas(EXPAND[expanded and true or false], true)
                KeybindButtons(self)
            end
            Expand(row, false)
            Hook(row, "EvaluateVisibility", Expand)
        end
    end
    if row.ToggleTest then
        SK.Button(row.ToggleTest)
        local vu = row.VUMeter
        if vu then
            SK.Strip(vu)
            Hide(vu.NineSlice)
            SK.Backdrop(vu, "button", 4, -4, -4, 4)
            if vu.Status then
                vu.Status:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
                vu.Status:ClearAllPoints()
                vu.Status:SetPoint("TOPLEFT", 5, -5)
                vu.Status:SetPoint("BOTTOMRIGHT", -5, 5)
            end
        end
    end
end

local function CategoryRow(row)
    if not SK.Once(row) then return end
    if row.Background then
        row.Background:SetAlpha(0)
        SK.Backdrop(row.Background, "button", 5, -5, -5, 0)
    end
    local toggle = row.Toggle
    if toggle then
        toggle:SetSize(18, 18)
        local function Swap(tex, atlas)
            if atlas == "Options_ListExpand_Right" or atlas == "Options_ListExpand_Right_Expanded" then
                tex:SetAtlas(atlas == "Options_ListExpand_Right" and "common-button-list-plus" or "common-button-list-minus")
            end
        end
        local nt = toggle.GetNormalTexture and toggle:GetNormalTexture()
        if nt then
            Swap(nt, nt:GetAtlas())
            hooksecurefunc(nt, "SetAtlas", Swap)
        end
    end
end

SK.Define("blizzardOptions", function()
    local p = G("SettingsPanel")
    if not p then return end
    SK.Strip(p)
    Hide(p.Bg)
    SK.Backdrop(p, "panel")
    SK.Shadow(p)
    if p.ClosePanelButton then SK.Close(p.ClosePanelButton) end
    SK.EditBox(p.SearchBox)
    Buttons(p.ApplyButton, p.CloseButton)
    MinimalTab(p.GameTab)
    MinimalTab(p.AddOnsTab)
    local cats = p.CategoryList
    if cats then
        local px = SK.Pixel(cats)
        SK.Backdrop(cats, "panel", px, -px, -px, px)
        SK.ScrollBar(cats.ScrollBar)
        Each(cats.ScrollBox, CategoryRow)
    end
    local c = p.Container
    if c then
        local px = SK.Pixel(c)
        SK.Backdrop(c, "panel", px, -px, -px, px)
        local list = c.SettingsList
        if list then
            if list.Header then SK.Button(list.Header.DefaultsButton) end
            SK.ScrollBar(list.ScrollBar)
            Each(list.ScrollBox, SettingsRow)
        end
    end
end)

-- Chat settings (the chat tab's Settings): ElvUI skins it under the same switch.
local function ChatChecks(frame)
    if not frame or not frame.checkBoxTable or not frame.GetName then return end
    local base = frame:GetName() .. "Checkbox"
    for i in ipairs(frame.checkBoxTable) do
        local row = G(base .. i)
        if row and SK.Once(row) then
            SK.Strip(row)
            SK.Check(G(base .. i .. "Check") or row)
            local cc = G(base .. i .. "ColorClasses")
            if cc then SK.Check(cc) end
        end
        -- Tiered lists carry their sub-types as i_1, i_2...
        for j = 1, 10 do
            local sub = G(base .. i .. "_" .. j)
            if not sub then break end
            SK.Check(sub)
        end
    end
end

local function ChatSwatches(frame)
    if not frame or not frame.swatchTable or not frame.GetName then return end
    local base = frame:GetName() .. "Swatch"
    for i in ipairs(frame.swatchTable) do
        local sw = G(base .. i)
        if sw and SK.Once(sw) then
            SK.Strip(sw)
            SK.Backdrop(sw, "panel")
        end
    end
end

SK.DefineLate("blizzardOptions", "Blizzard_ChatFrame", function()
    local f = G("ChatConfigFrame")
    if not f then return end
    if f.Header then SK.Strip(f.Header) end
    SK.Window(f)
    for _, n in ipairs({ "ChatConfigCategoryFrame", "ChatConfigBackgroundFrame", "ChatConfigCombatSettingsFilters",
                         "ChatConfigChatSettingsLeft", "ChatConfigChannelSettingsLeft", "ChatConfigOtherSettingsCombat",
                         "ChatConfigOtherSettingsPVP", "ChatConfigOtherSettingsSystem", "ChatConfigOtherSettingsCreature",
                         "ChatConfigChannelSettingsAvailable", "ChatConfigTextToSpeechChannelSettingsLeft",
                         "CombatConfigColorsUnitColors", "CombatConfigColorsHighlighting", "CombatConfigColorsColorizeUnitName",
                         "CombatConfigColorsColorizeSpellNames", "CombatConfigColorsColorizeDamageNumber",
                         "CombatConfigColorsColorizeDamageSchool", "CombatConfigColorsColorizeEntireLine",
                         "CombatConfigMessageSourcesDoneBy", "CombatConfigMessageSourcesDoneTo" }) do
        local box = G(n)
        if box then
            Hide(box.NineSlice)
            SK.Strip(box)
            SK.Backdrop(box, "panel")
        end
    end
    -- Rows come and go with the window's pages.
    for _, fn in ipairs({ "ChatConfig_UpdateCheckboxes", "ChatConfig_CreateCheckboxes" }) do
        HookGlobal(fn, function(frame) ChatChecks(frame) end)
    end
    HookGlobal("ChatConfig_CreateTieredCheckboxes", function(frame) ChatChecks(frame) end)
    HookGlobal("ChatConfig_UpdateSwatches", ChatSwatches)
    HookGlobal("ChatConfig_CreateColorSwatches", ChatSwatches)
    local tabs = G("ChatConfigFrameChatTabManager")
    if tabs then
        Hook(tabs, "UpdateWidth", function(self)
            if not self.tabPool then return end
            for tab in self.tabPool:EnumerateActive() do
                if SK.Once(tab) then
                    SK.Strip(tab)
                    tab:SetAlpha(1)
                    SK.Backdrop(tab, "panel", 3, -11, -3, 1)
                end
                tab:SetWidth(80)
            end
        end)
    end
    for i = 1, 5 do
        local tab = G("CombatConfigTab" .. i)
        if tab then SK.Tab(tab) end
    end
    SK.Auto(f)
end)

-- ============================================================================
-- Click casting
-- ============================================================================

SK.Define("binding", function()
    local f = G("ClickBindingFrame")
    if not f then return end
    SK.Window(f)
    if f.TutorialButton then
        Hide(f.TutorialButton.Ring)
        f.TutorialButton:SetPoint("TOPLEFT", f, "TOPLEFT", -12, 12)
    end
    Buttons(f.ResetButton, f.AddBindingButton, f.SaveButton)
    SK.ScrollBar(f.ScrollBar)
    Hide(f.ScrollBoxBackground)
    Each(f.ScrollBox, function(row)
        local icon = row.Icon
        if not icon or not SK.Once(row) then return end
        SK.Icon(icon)
        icon:SetPoint("LEFT", 3, 0)
        Hide(row.Background)
        local b = SK.Backdrop(row, "panel")
        if row.DeleteButton then
            SK.Button(row.DeleteButton)
            row.DeleteButton:SetSize(20, 20)
        end
        if row.FrameHighlight then
            row.FrameHighlight:SetColorTexture(1, 1, 1, 0.2)
            row.FrameHighlight:SetAllPoints(b)
        end
        if row.NewOutline then
            row.NewOutline:SetAlpha(0)
            Hook(row, "Init", function(self)
                b:SetBackdropBorderColor(0, self.NewOutline:IsShown() and 0.8 or 0, 0)
            end)
        end
    end)
    local tut = f.TutorialFrame
    if tut then
        Hide(tut.NineSlice)
        Hide(tut.Bg)
        SK.Window(tut)
    end
    local function Portrait(btn, texture)
        if not btn or not btn.Portrait then return end
        SK.Strip(btn, { [btn.Portrait] = true, [btn.Highlight or 0] = true })
        btn.Portrait:SetTexture(texture)
        local border = SK.Icon(btn.Portrait)
        if btn.Highlight then
            btn.Highlight:SetColorTexture(1, 1, 1, 0.25)
            btn.Highlight:SetAllPoints(btn.Portrait)
        end
        Hook(btn, "SetSelectedState", function(_, selected)
            if selected then border:SetBackdropBorderColor(1, 0.8, 0) else border:SetBackdropBorderColor(SK.BorderRGB()) end
        end)
    end
    Portrait(f.PlayerSpellsPortrait, 136830)
    Portrait(f.MacrosPortrait, 136377)
    SK.Check(f.EnableMouseoverCastCheckbox)
    if f.MouseoverCastKeyDropdown then SK.Dropdown(f.MouseoverCastKeyDropdown) end
end)

-- ============================================================================
-- Addon list
-- ============================================================================

SK.Define("addonManager", function()
    local f = G("AddonList")
    if not f then return end
    SK.Window(f)
    Buttons(f.EnableAllButton, f.DisableAllButton, f.OkayButton, f.CancelButton)
    if f.Dropdown then SK.Dropdown(f.Dropdown) end
    SK.ScrollBar(f.ScrollBar)
    if f.ForceLoad then
        SK.Check(f.ForceLoad)
        f.ForceLoad:SetSize(26, 26)
    end
    SK.EditBox(f.SearchBox)
    -- The tick shows the state: gold for this character only, accent for all.
    HookGlobal("AddonList_InitAddon", function(entry, node)
        if SK.Once(entry) then
            SK.Check(entry.Enabled)
            SK.Button(entry.LoadAddonButton)
        end
        local data = node and node.GetData and node:GetData()
        local index = data and data.addonIndex
        local tick = entry.Enabled and entry.Enabled:GetCheckedTexture()
        if not index or not tick then return end
        local char = UnitName("player")
        local state = C_AddOns.GetAddOnEnableState(index, char)
        local _, _, _, _, reason = C_AddOns.GetAddOnInfo(index)
        if reason == "DEP_DISABLED" then
            tick:SetVertexColor(0.6, 0.6, 0.6)
            tick:SetDesaturated(true)
        elseif state == 1 then
            tick:SetVertexColor(1, 0.8, 0.1)
            tick:SetDesaturated(false)
        elseif state == 2 then
            tick:SetVertexColor(SK.AccentRGB())
            tick:SetDesaturated(false)
        end
    end)
end)

-- ============================================================================
-- Help, GM chat, the error and debug windows, event trace
-- ============================================================================

SK.Define("help", function()
    local f = G("HelpFrame")
    if not f then return end
    SK.Strip(f)
    SK.Backdrop(f, "panel", -8, 8, 8, -8)
    SK.Shadow(f)
    if f.CloseButton then SK.Close(f.CloseButton) end
    local browser = G("HelpBrowser")
    if browser then
        if browser.BrowserInset then SK.Strip(browser.BrowserInset); Hide(browser.BrowserInset.NineSlice) end
        SK.Backdrop(browser, "none", -1, 1, 1, -2)
    end
end)

SK.Define("gmChat", function()
    local f = G("GMChatFrame")
    if not f then return end
    f:SetClampRectInsets(0, 0, 0, 0)
    SK.Strip(f)
    SK.Backdrop(f, "panel")
    if f.buttonFrame then f.buttonFrame:Hide() end
    local eb = f.editBox
    if eb then
        eb:SetAltArrowKeyMode(false)
        for _, part in ipairs({ "Right", "Left", "Mid", "FocusRight", "FocusLeft", "FocusMid" }) do Hide(G("GMChatFrameEditBox" .. part)) end
        SK.Backdrop(eb, "button")
        eb:ClearAllPoints()
        eb:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -5)
        eb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, -32)
        local lang = G("GMChatFrameEditBoxLanguage")
        if lang then
            local nt = lang:GetNormalTexture()
            if nt then nt:SetAlpha(0) end
            lang:ClearAllPoints()
            lang:SetPoint("TOPLEFT", eb, "TOPRIGHT", 3, 0)
            lang:SetPoint("BOTTOMRIGHT", eb, "BOTTOMRIGHT", 28, 0)
        end
    end
    local tab = G("GMChatTab")
    if tab then
        SK.Strip(tab, { [G("GMChatTabIcon") or 0] = true })
        local b = SK.Backdrop(tab, "panel")
        b:SetBackdropColor(0, 0.6, 1, 0.3)
        tab:ClearAllPoints()
        tab:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 2)
        tab:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 28)
        local icon = G("GMChatTabIcon")
        if icon then icon:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-Blizz") end
        local close = G("GMChatFrameCloseButton")
        if close then
            close:ClearAllPoints()
            close:SetPoint("RIGHT", tab, -5, 0)
            SK.Close(close)
        end
    end
end)

local ERROR_ART = { "TopLeft", "TopRight", "Top", "BottomLeft", "BottomRight", "Bottom", "Left", "Right", "TitleBG", "DialogBG" }

-- The Lua error window builds itself on first show.
local function ErrorsFrame(f)
    if not f or not SK.Once(f) then return end
    for _, n in ipairs(ERROR_ART) do Hide(G("ScriptErrorsFrame" .. n)) end
    Hide(f.NineSlice)
    SK.Backdrop(f, "panel")
    SK.Shadow(f)
    if G("ScriptErrorsFrameClose") then SK.Close(G("ScriptErrorsFrameClose")) end
    local sf = f.ScrollFrame
    if sf then
        SK.Backdrop(sf, "button")
        if sf.ScrollBar then
            SK.ScrollBar(sf.ScrollBar)
            sf.ScrollBar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 4, 2)
            sf.ScrollBar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 4, 2)
        end
    end
    Buttons(f.firstButton, f.lastButton, f.Reload, f.Close, f.CloseButton)
    if f.PreviousError then SK.Arrow(f.PreviousError, "left") end
    if f.NextError then SK.Arrow(f.NextError, "right") end
end

local function TableInspector(f)
    if not f or not SK.Once(f) then return end
    SK.Strip(f)
    SK.Backdrop(f, "panel")
    local art = f.ScrollFrameArt
    if art and art.NineSlice then
        art.NineSlice:SetAlpha(0)
        local box = CreateFrame("Frame", nil, art)
        box:SetPoint("TOPLEFT", art, "TOPLEFT", -4, 0)
        box:SetPoint("BOTTOMRIGHT", art, "BOTTOMRIGHT", -8, 0)
        SK.Backdrop(box, "panel")
    end
    if f.LinesScrollFrame then SK.ScrollBar(f.LinesScrollFrame.ScrollBar) end
    if f.CloseButton then SK.Close(f.CloseButton) end
    local up = f.OpenParentButton
    if up then
        up:ClearAllPoints()
        up:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
        SK.Arrow(up, "up")
        up:SetSize(17, 17)
    end
    for _, k in ipairs({ "VisibilityButton", "HighlightButton", "DynamicUpdateButton" }) do
        if f[k] then SK.Check(f[k]); f[k]:SetSize(28, 28) end
    end
    local back, fwd = f.NavigateBackwardButton, f.NavigateForwardButton
    if back then
        back:ClearAllPoints()
        if up then back:SetPoint("LEFT", up, "RIGHT", 2, 0) end
        SK.Arrow(back, "left")
        back:SetSize(17, 17)
    end
    if fwd then
        fwd:ClearAllPoints()
        if back then fwd:SetPoint("LEFT", back, "RIGHT", 2, 0) end
        SK.Arrow(fwd, "right")
        fwd:SetSize(17, 17)
    end
    if f.DuplicateButton and fwd then
        f.DuplicateButton:ClearAllPoints()
        f.DuplicateButton:SetPoint("LEFT", fwd, "RIGHT", 2, 0)
        SK.Button(f.DuplicateButton)
    end
    if f.FilterBox then SK.EditBox(f.FilterBox) end
    if f.TitleButton and f.TitleButton.Text then f.TitleButton.Text:SetTextColor(1, 1, 1) end
end

SK.Define("debug", function()
    local f = G("ScriptErrorsFrame")
    if f then
        if f:IsShown() then ErrorsFrame(f) else f:HookScript("OnShow", ErrorsFrame) end
    end
end)

SK.DefineLate("debug", "Blizzard_DebugTools", function()
    TableInspector(G("TableAttributeDisplay"))
    HookGlobal("DisplayTableInspectorWindow", function()
        for _, child in ipairs({ UIParent:GetChildren() }) do
            if child.LinesScrollFrame and child.OpenParentButton then TableInspector(child) end
        end
    end)
end)

SK.Define("eventLog", function()
    local f = G("EventTrace")
    if not f then return end
    SK.Strip(f)
    Hide(f.NineSlice)
    SK.Backdrop(f, "panel")
    SK.Shadow(f)
    if G("EventTraceCloseButton") then SK.Close(G("EventTraceCloseButton")) end
    if G("EventTraceTooltip") then G("EventTraceTooltip"):SetFrameLevel(10) end
    local sub, log, filter = f.SubtitleBar, f.Log, f.Filter
    if sub and sub.OptionsDropdown then SK.Button(sub.OptionsDropdown) end
    local logBar = log and log.Bar
    if logBar and logBar.SearchBox then
        SK.EditBox(logBar.SearchBox)
        logBar.SearchBox:SetHeight(18)
    end
    local filterBar = filter and filter.Bar
    for _, b in pairs({ sub and sub.ViewLog, sub and sub.ViewFilter, logBar and logBar.DiscardAllButton,
                        logBar and logBar.PlaybackButton, logBar and logBar.MarkButton,
                        filterBar and filterBar.DiscardAllButton, filterBar and filterBar.UncheckAllButton,
                        filterBar and filterBar.CheckAllButton }) do
        if b then SK.Strip(b); SK.Button(b) end
    end
    if f.ResizeButton then
        f.ResizeButton:ClearAllPoints()
        f.ResizeButton:SetPoint("BOTTOMRIGHT", 1, -1)
    end
    for _, part in pairs({ log and log.Events, log and log.Search, filter }) do
        if part and part.ScrollBox then
            part.ScrollBox:DisableDrawLayer("BACKGROUND")
            SK.Backdrop(part.ScrollBox, "panel")
            SK.ScrollBar(part.ScrollBar)
            Each(part.ScrollBox, function(row)
                local hide = row.HideButton
                if not hide or not SK.Once(row) then return end
                SK.Close(hide)
                hide:ClearAllPoints()
                hide:SetPoint("LEFT", 3, 0)
                if row.CheckButton then SK.Check(row.CheckButton); row.CheckButton:SetSize(22, 22) end
            end)
        end
    end
end)

-- ============================================================================
-- Edit Mode
-- ============================================================================

local function EditCheck(cb)
    if cb and SK.Once(cb) then SK.Check(cb) end
end

local function EditSlider(holder)
    local s = holder and holder.Slider
    if not s then return end
    SK.StepSlider(s)
    if s.Back then SK.Arrow(s.Back, "left") end
    if s.Forward then SK.Arrow(s.Forward, "right") end
end

SK.Define("editor", function()
    local f = G("EditModeManagerFrame")
    if not f then return end
    SK.Strip(f)
    Hide(f.Border)
    SK.Backdrop(f, "panel")
    SK.Shadow(f)
    if f.CloseButton then SK.Close(f.CloseButton) end
    Buttons(f.RevertAllChangesButton, f.SaveChangesButton)
    if f.LayoutDropdown then SK.Dropdown(f.LayoutDropdown) end
    EditSlider(f.GridSpacingSlider)
    for _, k in ipairs({ "ShowGridCheckButton", "EnableSnapCheckButton", "EnableAdvancedOptionsCheckButton" }) do
        if f[k] then EditCheck(f[k].Button) end
    end
    local acc = f.AccountSettings
    if acc then
        if acc.SettingsContainer then SK.ScrollBar(acc.SettingsContainer.ScrollBar) end
        -- One tick box per frame type, grouped; they exist once the list is built.
        local function Ticks(frame)
            for _, child in ipairs({ frame:GetChildren() }) do
                if child.Button and child.Button:IsObjectType("CheckButton") then EditCheck(child.Button) end
                if child.GetChildren then
                    for _, c2 in ipairs({ child:GetChildren() }) do
                        if c2.Button and c2.Button:IsObjectType("CheckButton") then EditCheck(c2.Button) end
                    end
                end
            end
        end
        Ticks(acc)
        if acc.SettingsContainer then
            local sc = acc.SettingsContainer.ScrollChild or acc.SettingsContainer
            Ticks(sc)
            for _, child in ipairs({ sc:GetChildren() }) do Ticks(child) end
        end
        if acc.Expander then SK.Auto(acc.Expander) end
    end

    local dlg = G("EditModeSystemSettingsDialog")
    if dlg then
        SK.Strip(dlg)
        Hide(dlg.Border)
        SK.Backdrop(dlg, "panel")
        SK.Shadow(dlg)
        if dlg.CloseButton then SK.Close(dlg.CloseButton) end
        local function Dialog()
            if dlg.Buttons then
                for _, b in ipairs({ dlg.Buttons:GetChildren() }) do SK.Button(b) end
            end
            if not dlg.Settings then return end
            for _, row in ipairs({ dlg.Settings:GetChildren() }) do
                if row.Dropdown and SK.Once(row.Dropdown) then SK.Dropdown(row.Dropdown) end
                if row.Slider and row.Slider.Slider then EditSlider(row) end
                if row.Button and row.Button:IsObjectType("CheckButton") then EditCheck(row.Button) end
            end
        end
        Hook(dlg, "UpdateDialog", Dialog)
        Hook(dlg, "UpdateExtraButtons", Dialog)
    end
    for _, n in ipairs({ "EditModeUnsavedChangesDialog", "EditModeLossOfControlDialog" }) do
        local d = G(n)
        if d then
            SK.Strip(d)
            Hide(d.Border)
            SK.Backdrop(d, "panel")
            SK.Auto(d)
        end
    end
    local imp = G("EditModeImportLayoutDialog")
    local new = G("EditModeNewLayoutDialog")
    for _, d in pairs({ imp, new }) do
        if d then
            SK.Strip(d)
            Hide(d.Border)
            SK.Backdrop(d, "panel")
            Buttons(d.AcceptButton, d.CancelButton)
            if d.CharacterSpecificLayoutCheckButton then EditCheck(d.CharacterSpecificLayoutCheckButton.Button) end
            if d.LayoutNameEditBox then SK.EditBox(d.LayoutNameEditBox) end
            if d.ImportBox then
                SK.Strip(d.ImportBox)
                SK.Backdrop(d.ImportBox, "button")
                SK.ScrollBar(d.ImportBox.ScrollBar)
            end
        end
    end
end)

-- ============================================================================
-- Death recap, breath / fatigue bars, loss of control
-- ============================================================================

SK.Define("deathRecap", function()
    local f = G("DeathRecapFrame")
    if not f then return end
    SK.Strip(f)
    SK.Backdrop(f, "panel")
    SK.Shadow(f)
    if f.CloseButton then
        f.CloseButton:SetFrameLevel(5)
        SK.Button(f.CloseButton)
    end
    if f.CloseXButton then SK.Close(f.CloseXButton) end
    SK.ScrollBar(f.ScrollBar)
    Each(f.ScrollBox, function(row)
        local info = row.SpellInfo
        if not info or not SK.Once(info) then return end
        if info.Icon then SK.Icon(info.Icon) end
        Hide(info.IconBorder)
    end)
end)

local function MirrorBar(bar)
    if not bar or not SK.Once(bar) then return end
    local sb = bar.StatusBar
    -- The bar is clipped to a 200x18 strip, so its own rounded ends never show.
    local clip = CreateFrame("Frame", nil, bar)
    clip:SetClipsChildren(true)
    clip:SetPoint("TOPLEFT", 1, -1)
    clip:SetPoint("BOTTOMRIGHT", -1, 1)
    if sb then
        sb:SetParent(clip)
        sb:ClearAllPoints()
        sb:SetSize(204, 22)
        sb:SetPoint("TOP", 0, 2)
        local text = bar.Text
        if text then
            text:SetParent(sb)
            text:ClearAllPoints()
            text:SetPoint("CENTER", sb, 0, 1)
        end
        local timer = sb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        timer:SetPoint("RIGHT", clip, -2, 0)
        local function Tick(_, v)
            v = v or 0
            timer:SetFormattedText("%d:%02d", v / 60, v % 60)
        end
        sb:HookScript("OnValueChanged", Tick)
        Tick(sb, sb:GetValue())
    end
    bar:SetSize(200, 18)
    SK.Strip(bar)
    SK.Backdrop(bar, "panel")
end

SK.Define("mirrorTimers", function()
    local c = G("MirrorTimerContainer")
    if not c then return end
    Hook(c, "SetupTimer", function(self, timer)
        if self.GetAvailableTimer then MirrorBar(self:GetAvailableTimer(timer)) end
    end)
    for _, child in ipairs({ c:GetChildren() }) do
        if child.StatusBar then MirrorBar(child) end
    end
end)

SK.Define("losscontrol", function()
    local f = G("LossOfControlFrame")
    if not f or not f.Icon then return end
    local box = CreateFrame("Frame", nil, f)
    local px = SK.Pixel(f)
    box:SetPoint("TOPLEFT", f.Icon, "TOPLEFT", -px, px)
    box:SetPoint("BOTTOMRIGHT", f.Icon, "BOTTOMRIGHT", px, -px)
    box:SetFrameLevel(math.max(0, f:GetFrameLevel() - 1))
    SK.Backdrop(box, "button")
    f.Icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    SK.Strip(f, { [f.Icon] = true })
    f:SetSize(f.Icon:GetWidth() + 50, f.Icon:GetWidth() + 50)
    -- Name and countdown stacked under the icon, the swoop animation off.
    Hook(f, "SetUpDisplay", function(self)
        self.Icon:ClearAllPoints()
        self.Icon:SetPoint("CENTER", self, "CENTER", 0, 0)
        if self.AbilityName then
            self.AbilityName:ClearAllPoints()
            self.AbilityName:SetPoint("BOTTOM", self, 0, -28)
            self.AbilityName.scrollTime = nil
        end
        local t = self.TimeLeft
        if t then
            if t.NumberText then
                t.NumberText:ClearAllPoints()
                t.NumberText:SetPoint("BOTTOM", self, 4, -58)
                t.NumberText.scrollTime = nil
            end
            if t.SecondsText then
                t.SecondsText:ClearAllPoints()
                t.SecondsText:SetPoint("BOTTOM", self, 0, -80)
                t.SecondsText.scrollTime = nil
            end
        end
        if self.Anim and self.Anim:IsPlaying() then self.Anim:Stop() end
    end)
end)

-- ============================================================================
-- Toasts (loot won, achievements, new mounts and so on)
-- ============================================================================

-- Every toast type shares one way in. Its art goes, a panel takes its place
-- and the icon gets a square edge; the text and icon stay where Blizzard puts
-- them, which differs per type.
local function IsIconKey(k)
    return type(k) == "string" and (k:find("Icon", 1, true) or k == "icon" or k == "Texture")
end

local function Toast(frame)
    if not frame or not SK.Once(frame) then return end
    local keep = {}
    local icons = {}
    local function Collect(obj)
        for k, v in pairs(obj) do
            if type(v) == "table" and v.IsObjectType and v:IsObjectType("Texture") and IsIconKey(k)
               and not (type(k) == "string" and (k:find("Border", 1, true) or k:find("Overlay", 1, true) or k:find("Bg", 1, true))) then
                keep[v] = true
                icons[#icons + 1] = v
            end
        end
    end
    Collect(frame)
    for _, k in ipairs({ "lootItem", "Icon", "IconFrame", "RewardFrame" }) do
        local sub = frame[k]
        if type(sub) == "table" and sub.GetObjectType and sub:IsObjectType("Frame") then
            Collect(sub)
            SK.Strip(sub, keep)
        end
    end
    SK.Strip(frame, keep)
    local b = SK.Backdrop(frame, "panel", 8, -8, -8, 8)
    SK.Shadow(b)
    for _, icon in ipairs(icons) do
        if icon:GetWidth() > 8 then
            local border = SK.Icon(icon)
            local item = frame.lootItem or frame
            if item.IconBorder then SK.QualityBorder(item.IconBorder, border) end
        end
    end
end

SK.Define("alertframes", function()
    local af = G("AlertFrame")
    if not af then return end
    Hook(af, "AddAlertFrame", function(_, frame) Toast(frame) end)
    -- The two bonus-roll toasts are plain frames, not from a queue.
    Toast(G("BonusRollLootWonFrame"))
    Toast(G("BonusRollMoneyWonFrame"))
end)

-- ============================================================================
-- Battleground and arena scores
-- ============================================================================

local function Scoreboard(f, close, content, tabGroup, scrollBar, categories)
    if not f or not SK.Once(f) then return end
    SK.Strip(f)
    f:DisableDrawLayer("BORDER")
    SK.Backdrop(f, "panel")
    SK.Shadow(f)
    if content then SK.Strip(content) end
    if categories then SK.Strip(categories) end
    if close then SK.Close(close) end
    SK.ScrollBar(scrollBar)
    for i = 1, 3 do
        local tab = tabGroup and (tabGroup["Tab" .. i] or tabGroup["tab" .. i])
        if tab then SK.Tab(tab) end
    end
end

SK.Define("bgscore", function()
    local sb = G("PVPMatchScoreboard")
    if sb then
        local c = sb.Content
        local tc = c and c.TabContainer
        if tc then Hide(tc.InsetBorderTop) end
        Scoreboard(sb, sb.ClosePanelButton or sb.CloseButton, c, tc and tc.TabGroup, c and c.ScrollBar,
                   FOREVER and c and c.ScrollCategories)
    end
    local res = G("PVPMatchResults")
    if res then
        local c = res.content
        local tc = c and c.tabContainer
        if tc then SK.Strip(tc) end
        Scoreboard(res, res.CloseButton, c, tc and tc.tabGroup, c and c.scrollBar, FOREVER and c and c.scrollCategories)
        local bc = res.buttonContainer
        if bc then Buttons(bc.leaveButton, bc.requeueButton) end
    end
end)

-- ============================================================================
-- Great Vault
-- ============================================================================

SK.Define("weeklyRewards", function()
    local f = G("WeeklyRewardsFrame")
    if not f then return end
    local parchment = SK.ParchmentActive()
    if parchment then
        SK.Strip(f)
        HideKeys(f, "BorderShadow", "BorderContainer", "Background", "NineSlice")
        if f.HeaderFrame then SK.Strip(f.HeaderFrame); SK.Backdrop(f.HeaderFrame, "panel") end
    end
    SK.Backdrop(f, "panel")
    SK.Shadow(f)
    if f.CloseButton then SK.Close(f.CloseButton) end
    SK.Button(f.SelectRewardButton)
    -- The row headers down the left.
    for _, k in ipairs({ "RaidFrame", "MythicFrame", "PVPFrame", "WorldFrame" }) do
        local row = f[k]
        if row and row.Border and row.Background then
            row.Border:SetTexCoord(0.926, 1, 0, 1)
            row.Border:SetPoint("LEFT", row, "RIGHT", 3, 0)
            row.Border:SetSize(25, 137)
            row.Background:SetSize(390, 140)
            row.Background:SetDrawLayer("ARTWORK", 2)
        end
    end
    local epic = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[4]
    local function Item(itemFrame)
        if not itemFrame or not SK.Once(itemFrame) then return end
        itemFrame:DisableDrawLayer("BORDER")
        local b = SK.Backdrop(itemFrame, "panel")
        if epic then b:SetBackdropBorderColor(epic.r, epic.g, epic.b) end
        if itemFrame.Icon then
            itemFrame.Icon:SetPoint("LEFT", 6, 0)
            SK.Icon(itemFrame.Icon)
        end
    end
    for _, act in ipairs(f.Activities or {}) do
        Hide(act.Border)
        if act.ItemFrame then Hook(act.ItemFrame, "SetDisplayedItem", Item) end
    end
    local cons = f.ConcessionFrame
    if cons and cons.UnselectedFrame and parchment then
        local b = SK.Backdrop(cons, "panel")
        cons.SelectedTexture:SetAlpha(0)
        cons.UnselectedFrame:SetAlpha(0)
        Hook(cons, "SetSelectionState", function(self)
            if self.SelectedTexture:IsShown() then b:SetBackdropBorderColor(1, 0.8, 0) else b:SetBackdropBorderColor(SK.BorderRGB()) end
        end)
    end
    Hook(f, "SelectReward", function(self)
        local sel = self.confirmSelectionFrame
        if not sel then return end
        Hide(G("WeeklyRewardsFrameNameFrame"))
        local it = sel.ItemFrame
        if it and it.Icon and SK.Once(it) then SK.QualityBorder(it.IconBorder, SK.Icon(it.Icon)) end
        local also = sel.AlsoItemsFrame
        if also and also.pool then
            for frame in also.pool:EnumerateActive() do
                if frame.Icon and SK.Once(frame) then SK.QualityBorder(frame.IconBorder, SK.Icon(frame.Icon)) end
            end
        end
    end)
end)

-- ============================================================================
-- Landing pages, choices, trait trees, delves
-- ============================================================================

SK.Define("expansionLanding", function()
    local f = G("ExpansionLandingPage")
    if not f then return end
    local function Overlay(self)
        local o = self.overlayFrame
        if not o or not SK.Once(o) then return end
        if SK.ParchmentActive() then
            SK.Strip(o)
            SK.Backdrop(o, "panel")
        end
        if o.CloseButton then SK.Close(o.CloseButton) end
    end
    Hook(f, "RefreshExpansionOverlay", Overlay)
    Overlay(f)
end)

-- Choices with their own big art (the Maw, the cypher picks) keep it.
local CHOICE_KITS = { jailerstower = true, cypherchoice = true, genericplayerchoice = true }

SK.Define("playerChoice", function()
    local f = G("PlayerChoiceFrame")
    if not f then return end
    local box
    Hook(f, "SetupOptions", function(self)
        if SK.Once(self) then
            for _, k in ipairs({ "BlackBackground", "Background", "NineSlice", "BorderOverlay" }) do
                if self[k] then self[k]:SetAlpha(0) end
            end
            if self.Title then self.Title:DisableDrawLayer("BACKGROUND") end
            if self.CloseButton then SK.Close(self.CloseButton) end
            box = SK.Backdrop(self, "panel")
        end
        if self.CloseButton and self.CloseButton.Border then self.CloseButton.Border:SetAlpha(0) end
        local kit = CHOICE_KITS[self.uiTextureKit or ""]
        if box then box:SetShown(not kit) end
        if not self.optionPools or not self.optionFrameTemplate then return end
        for option in self.optionPools:EnumerateActiveByTemplate(self.optionFrameTemplate) do
            local buttons = option.OptionButtonsContainer
            if buttons and buttons.buttonFramePool then
                for bf in buttons.buttonFramePool:EnumerateActive() do
                    if SK.Once(bf) then SK.Button(bf.Button) end
                end
            end
            local rewards = option.Rewards
            if rewards and rewards.rewardsPool then
                for r in rewards.rewardsPool:EnumerateActive() do
                    local item = r.itemButton
                    if item and SK.Once(item) then SK.ItemButton(item) end
                end
            end
            if not kit and SK.ParchmentActive() then
                if option.Background then option.Background:SetAlpha(0) end
                if option.Header and option.Header.Ribbon then option.Header.Ribbon:SetAlpha(0) end
            end
            local widgets = option.WidgetContainer
            if widgets and widgets.widgetFrames then
                for _, w in pairs(widgets.widgetFrames) do
                    if w.Spell and w.Spell.Icon and SK.Once(w.Spell) then
                        SK.Icon(w.Spell.Icon)
                        Hide(w.Spell.IconMask)
                        if w.Spell.Border then w.Spell.Border:SetAlpha(0) end
                    end
                end
            end
        end
    end)
end)

SK.Define("genericTrait", function()
    local f = G("GenericTraitFrame")
    if not f then return end
    if SK.ParchmentActive() then
        for _, k in ipairs({ "Background", "BorderOverlay", "NineSlice" }) do if f[k] then f[k]:SetAlpha(0) end end
    end
    SK.Backdrop(f, "panel")
    SK.Shadow(f)
    if f.CloseButton then SK.Close(f.CloseButton) end
end)

-- The delve pickers are part of the group finder in ElvUI's switches.
local function DelveOptions(slot, rows)
    local o = slot and slot.OptionsList
    if not o then return end
    SK.Strip(o)
    SK.Backdrop(o, "button")
    if rows ~= false then
        Each(o.ScrollBox, function(btn)
            if btn.Icon and SK.Once(btn) then SK.QualityBorder(btn.Border, SK.Icon(btn.Icon)) end
        end)
    end
end

SK.DefineLate("lfg", "Blizzard_DelvesCompanionConfiguration", function()
    local f = G("DelvesCompanionConfigurationFrame")
    if f then
        if f.CloseButton then
            f.CloseButton:ClearAllPoints()
            f.CloseButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -3)
        end
        SK.Window(f)
        SK.Button(f.CompanionConfigShowAbilitiesButton)
        local slots = f.CompanionSlots
        if slots then
            DelveOptions(slots.CompanionCombatRoleSlot, false)
            DelveOptions(slots.CompanionFlavorSlot)
            DelveOptions(slots.CompanionUtilityTrinketSlot)
            DelveOptions(slots.CompanionCombatTrinketSlot)
        end
    end
    local list = G("DelvesCompanionAbilityListFrame")
    if list then
        SK.Window(list)
        if list.DelvesCompanionRoleDropdown then SK.Dropdown(list.DelvesCompanionRoleDropdown) end
        local pc = list.DelvesCompanionAbilityListPagingControls
        if pc then
            if pc.PrevPageButton then SK.Arrow(pc.PrevPageButton, "left") end
            if pc.NextPageButton then SK.Arrow(pc.NextPageButton, "right") end
        end
        Hook(list, "UpdatePaginatedButtonDisplay", function(self)
            for _, b in pairs(self.buttons or {}) do
                if type(b) == "table" and b.Icon and SK.Once(b) then SK.Icon(b.Icon) end
            end
        end)
    end
end)

SK.DefineLate("lfg", "Blizzard_DelvesDifficultyPicker", function()
    local f = G("DelvesDifficultyPickerFrame")
    if not f then return end
    SK.Strip(f)
    SK.Backdrop(f, "panel")
    SK.Shadow(f)
    if f.CloseButton then SK.Close(f.CloseButton) end
    local sf = f.Dropdown or (f.DelveModifiersWidgetContainer and nil)
    if sf then SK.Dropdown(sf) end
    SK.Button(f.EnterDelveButton)
    local rewards = f.DelveRewardsContainerFrame
    if rewards and rewards.ScrollBox then
        Each(rewards.ScrollBox, function(r)
            if not SK.Once(r) then return end
            SK.Backdrop(r, "panel")
            if r.NameFrame then r.NameFrame:SetAlpha(0) end
            if r.Icon then SK.QualityBorder(r.IconBorder, SK.Icon(r.Icon)) end
        end)
    end
end)

-- ============================================================================
-- Item windows: sockets, upgrades, the catalyst, scrapping
-- ============================================================================

SK.Define("socket", function()
    local f = G("ItemSocketingFrame")
    if not f then return end
    SK.Window(f)
    Hide(G("ItemSocketingFramePortrait"))
    local sf = G("ItemSocketingScrollFrame")
    if sf then
        SK.Strip(sf)
        SK.Backdrop(sf, "panel")
        SK.ScrollBar(sf.ScrollBar)
    end
    local desc = G("ItemSocketingDescription")
    if desc then SK.Strip(desc) end
    SK.Button(G("ItemSocketingSocketButton") or f.SocketingContainer and f.SocketingContainer.ApplySocketsButton)
    -- The sockets: square, the gem's colour on the edge.
    HookGlobal("ItemSocketingFrame_Update", function()
        local list = f.SocketingContainer and f.SocketingContainer.SocketFrames
        for _, s in ipairs(list or {}) do
            if SK.Once(s) then
                SK.Strip(s, { [s.icon or s.Icon or 0] = true, [s.Shine or 0] = true })
                local icon = s.icon or s.Icon
                if icon then
                    local px = SK.Pixel(s)
                    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    icon:ClearAllPoints()
                    icon:SetPoint("TOPLEFT", px, -px)
                    icon:SetPoint("BOTTOMRIGHT", -px, px)
                end
                SK.Backdrop(s, "button")
            end
        end
    end)
    SK.Auto(f)
end)

SK.Define("itemUpgrade", function()
    local f = G("ItemUpgradeFrame")
    if not f then return end
    SK.Window(f)
    Hide(G("ItemUpgradeFrameBg"))
    Hide(G("ItemUpgradeFramePortrait"))
    SK.Strip(G("ItemUpgradeFramePlayerCurrenciesBorder"))
    SK.Button(G("ItemUpgradeFrameUpgradeButton") or f.UpgradeButton)
    local btn = f.UpgradeItemButton
    if btn and SK.Once(btn) then
        SK.Strip(btn, { [btn.icon or 0] = true })
        HideKeys(btn, "ButtonFrame")
        local icon = btn.icon
        if icon then SK.QualityBorder(btn.IconBorder, SK.Icon(icon)) end
        local hl = btn:GetHighlightTexture()
        if hl then hl:SetColorTexture(1, 1, 1, 0.25) end
    end
    if f.UpgradeCostFrame then SK.Strip(f.UpgradeCostFrame) end
    if f.ItemInfo and f.ItemInfo.Dropdown then SK.Dropdown(f.ItemInfo.Dropdown) end
    if f.UpgradeItemButton and SK.ParchmentActive() then
        HideKeys(f, "TopBG", "BottomBG")
    end
    for _, k in ipairs({ "LeftPreviewFrame", "RightPreviewFrame" }) do
        local p = f[k]
        if p then
            SK.Strip(p)
            SK.Backdrop(p, "panel")
        end
    end
    SK.Auto(f)
end)

SK.Define("itemInteraction", function()
    local f = G("ItemInteractionFrame")
    if not f then return end
    SK.Window(f)
    local slot = f.ItemSlot
    if slot and SK.Once(slot) then
        SK.Strip(slot, { [slot.Icon or 0] = true })
        if slot.Icon then
            slot.Icon:ClearAllPoints()
            slot.Icon:SetPoint("CENTER")
            SK.Icon(slot.Icon)
        end
        Hide(slot.GlowOverlay)
    end
    local btn = f.ButtonFrame
    if btn then
        SK.Strip(btn, { [btn.MoneyFrame or 0] = true })
        SK.Button(btn.ActionButton)
        if btn.Currency and btn.Currency.Icon then SK.Icon(btn.Currency.Icon) end
    end
    Hide(f.Background)
    SK.Auto(f)
end)

SK.Define("scrapping", function()
    local f = G("ScrappingMachineFrame")
    if not f then return end
    SK.Window(f)
    SK.Button(f.ScrapButton)
    local items = f.ItemSlots
    if items then
        SK.Strip(items)
        local function Slots()
            if not items.scrapButtons then return end
            for btn in items.scrapButtons:EnumerateActive() do
                if SK.Once(btn) then
                    SK.Strip(btn, { [btn.Icon or 0] = true })
                    if btn.Icon then SK.QualityBorder(btn.IconBorder, SK.Icon(btn.Icon)) end
                end
            end
        end
        Slots()
        f:HookScript("OnShow", Slots)
    end
    SK.Auto(f)
end)

-- ============================================================================
-- The barber
-- ============================================================================

SK.Define("barber", function()
    local f = G("BarberShopFrame")
    if f then
        Buttons(G("BarberShopFrameOkayButton") or f.AcceptButton, G("BarberShopFrameCancelButton") or f.CancelButton,
                G("BarberShopFrameResetButton") or f.ResetButton)
    end
end)

SK.DefineLate("barber", "Blizzard_CharacterCustomize", function()
    local c = G("CharCustomizeFrame")
    if not c then return end
    if c.SmallButtons then
        for _, k in ipairs({ "ResetCameraButton", "ZoomOutButton", "ZoomInButton", "RotateLeftButton", "RotateRightButton" }) do
            local b = c.SmallButtons[k]
            if b and SK.Once(b) then
                SK.Strip(b, { [b.Icon or 0] = true })
                SK.Backdrop(b, "button")
                SK.Hover(b)
            end
        end
    end
    SK.Button(c.RandomizeAppearanceButton)
    -- The option rows (dropdowns with arrows, sliders) appear as categories load.
    Hook(c, "AddMissingOptions", function(self)
        if not self.selectionPopoutPool then return end
        for popout in self.selectionPopoutPool:EnumerateActive() do
            if SK.Once(popout) then
                local p = popout.SelectionPopoutButton or popout.Button
                if p then SK.Button(p) end
                if popout.DecrementButton then SK.Arrow(popout.DecrementButton, "left") end
                if popout.IncrementButton then SK.Arrow(popout.IncrementButton, "right") end
            end
        end
        if self.sliderPool then
            for s in self.sliderPool:EnumerateActive() do
                if s.Slider and SK.Once(s) then SK.StepSlider(s) end
            end
        end
    end)
end)

-- ============================================================================
-- Stables
-- ============================================================================

SK.Define("stable", function()
    local f = G("StableFrame")
    if f then
        SK.Window(f)
        SK.Button(f.StableTogglePetButton)
        SK.Button(f.ReleasePetButton)
        local list = f.StabledPetList
        if list then
            SK.Strip(list)
            if list.ListCounter then SK.Strip(list.ListCounter); SK.Backdrop(list.ListCounter, "panel") end
            SK.EditBox(list.FilterBar and list.FilterBar.SearchBox)
            if list.FilterBar and list.FilterBar.FilterDropdown then SK.Dropdown(list.FilterBar.FilterDropdown) end
            if list.ScrollBar then SK.ScrollBar(list.ScrollBar) end
            Each(list.ScrollBox, function(btn)
                if not SK.Once(btn) then return end
                if btn.Background then btn.Background:SetAlpha(0) end
                if btn.Portrait and btn.Portrait.Icon then SK.Icon(btn.Portrait.Icon) end
                if btn.Portrait then Hide(btn.Portrait.Border) end
                SK.Backdrop(btn, "button")
                SK.RowHighlights(btn)
            end)
        end
        local model = f.PetModelScene
        if model then
            SK.Strip(model)
            if model.PetInfo then SK.Strip(model.PetInfo) end
            if model.AbilitiesList then SK.Strip(model.AbilitiesList) end
        end
        local active = f.ActivePetList
        if active then
            for _, b in ipairs({ active:GetChildren() }) do
                if b.Icon and SK.Once(b) then
                    SK.Strip(b, { [b.Icon] = true })
                    SK.Icon(b.Icon)
                end
            end
            if active.BeastMasterSecondaryPetButton then SK.Button(active.BeastMasterSecondaryPetButton) end
        end
        SK.Auto(f)
    end
    -- Forever's stable is the older one: stabled slots and the current pet.
    local old = G("PetStableFrame")
    if old and not f then
        SK.Window(old)
        for _, n in ipairs({ "PetStableFrameInset", "PetStableLeftInset", "PetStableBottomInset" }) do
            if G(n) then SK.Inset(G(n)) end
        end
        Hide(G("PetStableFrameModelBg"))
        Buttons(G("PetStablePurchaseButton"))
        if G("PetStablePrevPageButton") then SK.Arrow(G("PetStablePrevPageButton"), "left") end
        if G("PetStableNextPageButton") then SK.Arrow(G("PetStableNextPageButton"), "right") end
        for _, n in ipairs({ "PetStableCurrentPet", "PetStableSelectedPetIcon" }) do
            local b = G(n)
            if b then SK.ItemButton(b) end
        end
        for i = 1, (NUM_PET_ACTIVE_SLOTS or 5) do
            local b = G("PetStableActivePet" .. i)
            if b then SK.ItemButton(b) end
        end
        for i = 1, (NUM_PET_STABLE_SLOTS or 10) do
            local b = G("PetStableStabledPet" .. i)
            if b then SK.ItemButton(b) end
        end
        local diet = G("PetStableDietTexture")
        if diet then SK.Icon(diet) end
        SK.Auto(old)
    end
end)

-- ============================================================================
-- Flight maps
-- ============================================================================

SK.Define("taxi", function()
    local f = G("TaxiFrame")
    if not f then return end
    SK.Window(f)
    Hide(G("TaxiPortrait"))
    local route = G("TaxiRouteMap")
    if route then SK.Backdrop(route, "none") end
    if G("TaxiCloseButton") then SK.Close(G("TaxiCloseButton")) end
end)

SK.DefineLate("taxi", "Blizzard_FlightMap", function()
    local f = G("FlightMapFrame")
    if not f then return end
    SK.Window(f)
    Hide(G("FlightMapFramePortrait"))
    if G("FlightMapFrameCloseButton") then SK.Close(G("FlightMapFrameCloseButton")) end
    if f.BorderFrame then
        SK.Strip(f.BorderFrame)
        Hide(f.BorderFrame.NineSlice)
    end
end)

-- ============================================================================
-- Black market
-- ============================================================================

SK.Define("bmah", function()
    local f = G("BlackMarketFrame")
    if not f then return end
    SK.Window(f)
    HideKeys(f, "Inset", "MoneyFrameBorder")
    for _, k in ipairs({ "ColumnName", "ColumnLevel", "ColumnType", "ColumnDuration", "ColumnHighBidder", "ColumnCurrentBid" }) do
        local col = f[k]
        if col then
            SK.Strip(col)
            SK.Backdrop(col, "panel", 0, 0, -2, 0)
        end
    end
    if f.CloseButton then SK.Close(f.CloseButton) end
    SK.Button(f.BidButton)
    SK.ScrollBar(f.ScrollBar)
    SK.EditBox(G("BlackMarketBidPriceGold"))
    if G("BlackMarketBidPriceGold") then G("BlackMarketBidPriceGold"):SetHeight(16) end
    local hot = f.HotDeal
    if hot then
        SK.Strip(hot)
        if hot.Item then SK.ItemButton(hot.Item) end
    end
    Each(f.ScrollBox, function(row)
        if not SK.Once(row) then return end
        SK.Strip(row, { [row.Selection or 0] = true })
        local item = row.Item
        if item then
            SK.Strip(item, { [item.IconTexture or 0] = true })
            if item.IconTexture then SK.QualityBorder(item.IconBorder, SK.Icon(item.IconTexture)) end
        end
        local r, g, b = SK.AccentRGB()
        if row.Selection then row.Selection:SetColorTexture(r, g, b, 0.25) end
        local hl = row:GetHighlightTexture()
        if hl then hl:SetColorTexture(1, 1, 1, 0.15) end
    end)
end)

-- ============================================================================
-- Transmog and housing: the general pass over their big windows
-- ============================================================================

SK.Define("transmogrify", function()
    local f = G("TransmogFrame")
    if not f then return end
    SK.Window(f)
    if f.WardrobeCollection and f.WardrobeCollection.TabHeaders then
        for _, t in ipairs({ f.WardrobeCollection.TabHeaders:GetChildren() }) do SK.Tab(t) end
    end
    SK.Auto(f)
end)

local HOUSING = {
    "HousingDashboardFrame", "HouseFinderFrame", "HouseListFrame", "HousingBulletinBoardFrame", "HousingHouseSettingsFrame",
    "HousingCornerstoneHouseInfoFrame", "HousingCornerstonePurchaseFrame", "HousingCornerstoneVisitorFrame",
    "HousingCreateGuildNeighborhoodFrame", "HousingModelPreviewFrame", "HousingBlueprintExportFrame",
    "HousingBlueprintImportFrame", "HousingCharterRequestSignatureDialog", "AbandonHouseConfirmationDialog",
    "BuyHouseConfirmationDialog", "MoveHouseConfirmationDialog", "NeighborhoodChangeNameDialog",
}

-- Housing is a dozen small addons; each window is skinned as its addon loads.
local function Housing()
    for _, n in ipairs(HOUSING) do Plain(G(n)) end
end

SK.Define("housing", Housing)
for _, addon in ipairs({ "Blizzard_HousingHouseFinder", "Blizzard_HousingBulletinBoard", "Blizzard_HousingHouseSettings",
                         "Blizzard_HousingCornerstone", "Blizzard_HousingCreateNeighborhood", "Blizzard_HousingModelPreview",
                         "Blizzard_HousingBlueprint", "Blizzard_HousingCharter" }) do
    SK.DefineLate("housing", addon, Housing)
end

-- ============================================================================
-- Older content: one general pass each
-- ============================================================================

-- Windows for expansions past: their own art goes, our panel and controls
-- go on, nothing is hand-placed. Each has its own switch.
local LEGACY = {
    { "adventureMap", "AdventureMapQuestChoiceDialog" },
    { "alliedRaces", "AlliedRacesFrame" },
    { "animaDiversion", "AnimaDiversionFrame" },
    { "archaeology", "ArchaeologyFrame" },
    { "artifact", "ArtifactFrame" },
    { "azerite", "AzeriteEmpoweredItemUI" },
    { "azeriteEssence", "AzeriteEssenceUI" },
    { "azeriteRespec", "AzeriteRespecFrame" },
    { "chromieTime", "ChromieTimeFrame" },
    { "contribution", "ContributionCollectionFrame" },
    { "covenantPreview", "CovenantPreviewFrame" },
    { "covenantRenown", "CovenantRenownFrame" },
    { "covenantSanctum", "CovenantSanctumFrame" },
    { "garrison", "GarrisonLandingPage" },
    { "islandQueue", "IslandsQueueFrame" },
    { "obliterum", "ObliterumForgeFrame" },
    { "orderhall", "OrderHallTalentFrame" },
    { "runeforge", "RuneforgeFrame" },
    { "soulbinds", "SoulbindViewer" },
    { "torghastLevelPicker", "TorghastLevelPickerFrame" },
    { "subscriptionInterstitial", "SubscriptionInterstitialFrame" },
}
for _, e in ipairs(LEGACY) do
    local name = e[2]
    SK.Define(e[1], function() Plain(G(name)) end)
end
