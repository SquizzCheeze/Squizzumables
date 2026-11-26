-- ActionBars/ActionBars.lua
-- Our own action bars, replacing ElvUI's (and Blizzard's). Thirteen bars,
-- numbered as ElvUI numbers them so each one holds the same action slots it
-- does there: bar N shows action page N (bars 1-10 and 13-15; pages 11 and 12
-- are Blizzard's skyriding and vehicle pages, never a bar of their own). Bar 1
-- pages like the main bar: vehicles, override and possess bars, shapeshift
-- forms, the class pages (Cat Form, Stealth, Shadowform...) and Shift-paging.
--
-- The buttons are LibActionButton-1.0 (BSD, Libs/LibActionButton-1.0, the
-- library Bartender and ElvUI build on), so dragging, flyouts, cooldowns,
-- charges, range and usability colouring are its well-tested code. The look
-- (square, cropped icons in a thin black border) and the proc glow are ours:
-- the button is marked MasqueSkinned so LAB leaves its textures alone, and
-- procs come from SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE through ns.Glow,
-- because LAB only draws them with LibButtonGlow, which we don't ship (and
-- CooldownManagerCentered loads the same LAB version first, so editing our
-- copy would change nothing).
--
-- KEYBINDS: each bar reads the binding command that bar answers to in ElvUI
-- (ACTIONBUTTON for bar 1, MULTIACTIONBAR1-7 for the Blizzard bars) and
-- presses its buttons through override bindings, so every key already bound
-- keeps working. Bars 2 and 7-10 have no Blizzard command: they use our own
-- (Bindings.xml, under Squizzumables in the key bindings) and, while ElvUI is
-- loaded, ElvUI's ELVUIBAR commands too. "Copy ElvUI's Keybinds" moves those
-- keys onto ours for good.
--
-- COEXISTENCE: the bars do nothing at all while ElvUI's own action bars are
-- on (E.private.actionbar.enable). Once active they hide Blizzard's main and
-- multi bars (reparented to a hidden frame, events off -- what ElvUI does);
-- the stance, pet and possess bars stay Blizzard's for now. Blizzard's Leave
-- Vehicle button lives inside the main bar, so we draw our own.
--
-- Secure rules: headers are SecureHandlerStateTemplate (paging and
-- visibility are state drivers), so layout, bindings and paging only change
-- out of combat; a change in combat waits for PLAYER_REGEN_ENABLED. Each bar
-- is placed by a plain holder frame (what Edit Mode drags), which the header
-- is anchored to but not parented by.

local addonName, ns = ...
local BH = ns.BH
local S = BH.Secrets

local LAB = LibStub("LibActionButton-1.0", true)
if not LAB then return end

local AB = {}
ns.ActionBars = AB

local NUM_BUTTONS = 12

-- ElvUI's numbering, pages and binding commands.
local BARS = {
    { n = 1,  page = 1,  bind = "ACTIONBUTTON" },
    { n = 2,  page = 2,  bind = "SQUIZZBAR2BUTTON",  elv = "ELVUIBAR2BUTTON" },
    { n = 3,  page = 3,  bind = "MULTIACTIONBAR3BUTTON" },
    { n = 4,  page = 4,  bind = "MULTIACTIONBAR4BUTTON" },
    { n = 5,  page = 5,  bind = "MULTIACTIONBAR2BUTTON" },
    { n = 6,  page = 6,  bind = "MULTIACTIONBAR1BUTTON" },
    { n = 7,  page = 7,  bind = "SQUIZZBAR7BUTTON",  elv = "ELVUIBAR7BUTTON" },
    { n = 8,  page = 8,  bind = "SQUIZZBAR8BUTTON",  elv = "ELVUIBAR8BUTTON" },
    { n = 9,  page = 9,  bind = "SQUIZZBAR9BUTTON",  elv = "ELVUIBAR9BUTTON" },
    { n = 10, page = 10, bind = "SQUIZZBAR10BUTTON", elv = "ELVUIBAR10BUTTON" },
    { n = 13, page = 13, bind = "MULTIACTIONBAR5BUTTON" },
    { n = 14, page = 14, bind = "MULTIACTIONBAR6BUTTON" },
    { n = 15, page = 15, bind = "MULTIACTIONBAR7BUTTON" },
}
AB.BARS = BARS

_G.BINDING_HEADER_SQUIZZUMABLES = "Squizzumables"
for _, def in ipairs(BARS) do
    if def.bind:find("^SQUIZZ") then
        _G["BINDING_HEADER_SQUIZZBAR" .. def.n] = "Action Bar " .. def.n
        for i = 1, NUM_BUTTONS do
            _G["BINDING_NAME_" .. def.bind .. i] = "Action Bar " .. def.n .. " Button " .. i
        end
    end
end

-- Class pages for bar 1 (the game's own: these are the pages Blizzard's main
-- bar switches to). A profile seeded from ElvUI uses ElvUI's instead.
local CLASS_PAGING = BH.IS_FOREVER and {
    DRUID   = "[bonusbar:1,nostealth] 7; [bonusbar:1,stealth] 8; [bonusbar:2] 10; [bonusbar:3] 9; [bonusbar:4] 10;",
    ROGUE   = "[bonusbar:1] 7;",
    WARRIOR = "[bonusbar:1] 7; [bonusbar:2] 8; [bonusbar:3] 9;",
    PRIEST  = "[form:1] 7;",
} or {
    DRUID   = "[bonusbar:1,nostealth] 7; [bonusbar:1,stealth] 8; [bonusbar:2] 10; [bonusbar:3] 9; [bonusbar:4] 10;",
    ROGUE   = "[bonusbar:1] 7;",
    PRIEST  = "[form:1, spec:3] 7;",
    EVOKER  = "[bonusbar:1] 7;",
}

local function Bar1Condition(s)
    local class = select(2, UnitClass("player"))
    local custom = type(s.abPaging) == "table" and s.abPaging[class]
    local classPart = (type(custom) == "string" and custom ~= "") and custom:gsub("[\r\n]", " ")
        or CLASS_PAGING[class] or ""
    return string.format("[overridebar] %d; [vehicleui][possessbar] %d; [shapeshift] %d; "
        .. "[bar:2] 2; [bar:3] 3; [bar:4] 4; [bar:5] 5; [bar:6] 6; [bonusbar:5] 11; %s 1",
        GetOverrideBarIndex(), GetVehicleBarIndex(), GetTempShapeshiftBarIndex(), classPart)
end

local function Bar1MaxPage()
    return math.max(18, GetOverrideBarIndex(), GetVehicleBarIndex(), GetTempShapeshiftBarIndex())
end

local DEFAULT_VISIBILITY = BH.IS_FOREVER and "[vehicleui][overridebar] hide; show"
    or "[vehicleui][petbattle][overridebar] hide; show"
local DEFAULT_VISIBILITY_BAR1 = BH.IS_FOREVER and "show" or "[petbattle] hide; show"

-- ============================================================================
-- Is ElvUI drawing the bars?
-- ============================================================================

local function ElvUI()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

function AB.ElvUIBarsOn()
    local E = ElvUI()
    if not E then return false end
    local p = E.private and E.private.actionbar
    return not (p and p.enable == false)
end

function AB.Wanted()
    return BH.settings and BH.settings.abEnabled and not AB.ElvUIBarsOn() and true or false
end

-- ============================================================================
-- Settings
-- ============================================================================

local function Apply() if AB.Apply then AB.Apply() end end
local function BarOn(n) return function(s) return s["ab" .. n .. "Enabled"] end end

local OUTLINES = {
    { text = "None",          value = "NONE" },
    { text = "Outline",       value = "OUTLINE" },
    { text = "Thick outline", value = "THICKOUTLINE" },
}
local GROW = {
    { text = "Bottom left (fill right, then up)",  value = "BOTTOMLEFT" },
    { text = "Bottom right (fill left, then up)",  value = "BOTTOMRIGHT" },
    { text = "Top left (fill right, then down)",   value = "TOPLEFT" },
    { text = "Top right (fill left, then down)",   value = "TOPRIGHT" },
}
local FLYOUT = {
    { text = "Up", value = "UP" }, { text = "Down", value = "DOWN" },
    { text = "Left", value = "LEFT" }, { text = "Right", value = "RIGHT" },
}
local RANGE = {
    { text = "Whole button", value = "button" },
    { text = "Keybind text only", value = "hotkey" },
}
local STRATAS = {
    { text = "Background", value = "BACKGROUND" }, { text = "Low", value = "LOW" },
    { text = "Medium", value = "MEDIUM" }, { text = "High", value = "HIGH" },
}

local reloadAsked
local function AskReload()
    if reloadAsked then return end
    reloadAsked = true
    StaticPopupDialogs["SQUIZZUMABLES_AB_RELOAD"] = StaticPopupDialogs["SQUIZZUMABLES_AB_RELOAD"] or {
        text = "Blizzard's action bars come back after a reload.",
        button1 = "Reload now", button2 = "Later",
        OnAccept = function() ReloadUI() end,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }
    StaticPopup_Show("SQUIZZUMABLES_AB_RELOAD")
end

local pages = {
    { key = "general", label = "General", rows = {
        { key = "abEnabled", type = "check", default = false,
          label = "Use Squizzumables Action Bars",
          tip = "Replace the action bars with Squizzumables' own: up to 13 bars, each showing the action page "
            .. "it shows in ElvUI, with the same keybinds.\n\nThey stay off while ElvUI's action bars are on: "
            .. "turn those off in ElvUI (ActionBars > Enable) and /reload first. Your ElvUI bars' positions, "
            .. "sizes and settings were copied the first time Squizzumables ran.",
          apply = function(v)
              if v and AB.ElvUIBarsOn() then
                  print("|cff33cc99Squizzumables:|r ElvUI's action bars are still on. Turn them off in ElvUI "
                      .. "(ActionBars > Enable), /reload, and these take over.")
              elseif not v and AB.active then
                  AskReload()
              end
          end },
        { key = "abLocked", type = "check", default = true,
          label = "Lock Action Buttons",
          tip = "Stops spells being dragged off the bars by accident. Hold Shift to drag one anyway." },
        { key = "abTooltips", type = "check", default = true,
          label = "Tooltips", tip = "Hovering a button shows the spell's tooltip." },
        { key = "abRange", type = "dropdown", default = "button", items = RANGE,
          label = "Out of Range", tip = "What turns red when the target is out of range." },
        { key = "abVehicle", type = "check", default = true,
          label = "Leave Vehicle Button",
          tip = "A button to leave a vehicle or a flight path early, placed in Edit Mode. (Blizzard's lives "
            .. "on the main bar, which these replace.)" },
        { key = "abVehicleSize", type = "slider", default = 32, min = 16, max = 64, step = 1,
          label = "Leave Vehicle Size", tip = "Size of the Leave Vehicle button.",
          when = function(s) return s.abVehicle end },
        { type = "header", label = "TEXT" },
        { key = "abFont", type = "dropdown", default = "__default",
          items = function() return BH:BuildFontDropdownItems() end,
          label = "Font", tip = "Font of the keybinds, counts and macro names." },
        { key = "abFontOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES,
          label = "Font Outline", tip = "An outline round the letters." },
        { key = "abShowHotkeys", type = "check", default = true, label = "Show Keybinds",
          tip = "The key each button is bound to, in its top corner." },
        { key = "abHotkeySize", type = "slider", default = 12, min = 6, max = 24, step = 1,
          label = "Keybind Size", tip = "Size of the keybind text.", when = function(s) return s.abShowHotkeys end },
        { key = "abShowCount", type = "check", default = true, label = "Show Counts",
          tip = "How many you carry, or charges left, in the bottom corner." },
        { key = "abCountSize", type = "slider", default = 12, min = 6, max = 24, step = 1,
          label = "Count Size", tip = "Size of the count text.", when = function(s) return s.abShowCount end },
        { key = "abShowMacro", type = "check", default = false, label = "Show Macro Names",
          tip = "A macro's name along the bottom of its button." },
        { key = "abMacroSize", type = "slider", default = 10, min = 6, max = 24, step = 1,
          label = "Macro Name Size", tip = "Size of macro names.", when = function(s) return s.abShowMacro end },
        { type = "header", label = "COOLDOWNS" },
        { key = "abCooldownNumbers", type = "check", default = true, label = "Cooldown Numbers",
          tip = "The time left, counting down on the button." },
        { key = "abCooldownSize", type = "slider", default = 18, min = 8, max = 40, step = 1,
          label = "Cooldown Number Size", tip = "Size of the countdown numbers.",
          when = function(s) return s.abCooldownNumbers end },
        { type = "header", label = "KEYBINDS" },
        { type = "text", label = "Bind keys in the game's Key Bindings, as before. Bars 2 and 7-10 are listed "
            .. "under Squizzumables." },
        { type = "button", label = "Copy ElvUI's Keybinds",
          tip = "Bind the keys you set for ElvUI's bars 2 and 7-10 to the same buttons here, so they keep "
            .. "working once ElvUI is gone. Other keys are left alone.",
          onClick = function() AB.CopyElvUIKeybinds() end },
    } },
}

local BAR_TIPS = {
    [1] = "The main bar: action page 1, paging for vehicles, forms, stealth and Shift-number.",
    [7] = "Action page 7. For a Druid, Rogue, Priest or Evoker this is also a form or stealth page bar 1 "
        .. "switches to, so the two show the same buttons.",
}

for _, def in ipairs(BARS) do
    local n = def.n
    local p = "ab" .. n
    local on = BarOn(n)
    local rows = {
        { key = p .. "Enabled", type = "check", default = n <= 3,
          label = "Show Bar " .. n, tip = BAR_TIPS[n] or ("Shows action page " .. def.page .. ".") },
        { key = p .. "Buttons", type = "slider", default = 12, min = 1, max = NUM_BUTTONS, step = 1,
          label = "Buttons", tip = "How many buttons the bar shows.", when = on },
        { key = p .. "PerRow", type = "slider", default = 12, min = 1, max = NUM_BUTTONS, step = 1,
          label = "Buttons per Row", tip = "Buttons in a row before the next row starts.", when = on },
        { key = p .. "Size", type = "slider", default = 32, min = 16, max = 80, step = 1,
          label = "Button Size", tip = "Width of each button (and height, while Square Buttons is on).", when = on },
        { key = p .. "Square", type = "check", default = true,
          label = "Square Buttons", tip = "Untick to set the height separately; the icon is cropped to fit.",
          when = on },
        { key = p .. "Height", type = "slider", default = 32, min = 12, max = 80, step = 1,
          label = "Button Height", tip = "Height of each button.",
          when = function(s) return on(s) and s[p .. "Square"] == false end },
        { key = p .. "Spacing", type = "slider", default = 2, min = 0, max = 20, step = 1,
          label = "Spacing", tip = "Space between buttons.", when = on },
        { key = p .. "Grow", type = "dropdown", default = "BOTTOMLEFT", items = GROW,
          label = "Grow From", tip = "The corner the first button sits in.", when = on },
        { key = p .. "Flyout", type = "dropdown", default = "UP", items = FLYOUT,
          label = "Flyout Direction", tip = "Which way flyouts (portals, pets, totems) open.", when = on },
        { key = p .. "ShowEmpty", type = "check", default = true,
          label = "Show Empty Buttons", tip = "Empty slots show as dark squares instead of nothing.", when = on },
        { key = p .. "ClickThrough", type = "check", default = false,
          label = "Click Through",
          tip = "The buttons ignore the mouse, so clicks go to whatever is behind. Keybinds still work.", when = on },
        { type = "header", label = "BACKGROUND" },
        { key = p .. "Backdrop", type = "check", default = false,
          label = "Background", tip = "A dark background behind the buttons.", when = on },
        { key = p .. "Padding", type = "slider", default = 2, min = 0, max = 20, step = 1,
          label = "Padding", tip = "Space between the background's edge and the buttons.",
          when = function(s) return on(s) and s[p .. "Backdrop"] end },
        { key = p .. "Strata", type = "dropdown", default = "LOW", items = STRATAS,
          label = "Frame Strata", tip = "How far in front of other frames the bar sits.", when = on },
        { type = "header", label = "VISIBILITY" },
        { key = p .. "Alpha", type = "slider", default = 100, min = 0, max = 100, step = 5,
          label = "Opacity", tip = "How visible the bar is, in percent.", when = on },
        { key = p .. "Mouseover", type = "check", default = false,
          label = "Show on Mouseover", tip = "The bar fades out until you point at it.", when = on },
        { key = p .. "FadeAlpha", type = "slider", default = 0, min = 0, max = 100, step = 5,
          label = "Faded Opacity", tip = "How visible the bar stays while faded, in percent.",
          when = function(s) return on(s) and s[p .. "Mouseover"] end },
        { key = p .. "Visibility", type = "editbox", default = n == 1 and DEFAULT_VISIBILITY_BAR1 or DEFAULT_VISIBILITY,
          label = "Visibility Condition",
          tip = "A macro condition deciding when the bar shows. The default hides it in vehicles and pet "
            .. "battles. Example: [combat] show; hide", when = on },
    }
    pages[#pages + 1] = { key = "bar" .. n, label = "Bar " .. n, rows = rows }
end

-- Stance, Pet and Micro Menu tabs (ExtraBars.lua, loaded just before this).
local X = ns.ActionBarExtras
if X then
    for _, page in ipairs(X.PAGES) do pages[#pages + 1] = page end
end

AB.SETTINGS = ns.Settings.Describe({ master = "abEnabled", apply = Apply, pages = pages })

function BH:BuildActionBarsTab(parent)
    ns.Settings.Build(AB.SETTINGS, parent)
end

-- ============================================================================
-- Buttons
-- ============================================================================

local bars = {}       -- n -> { def, holder, header, buttons, drivers }
local dirty = false   -- a change waited for the end of combat

local function ResolveFont(name)
    if name and name ~= "__default" then
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        local path = lsm and lsm:Fetch("font", name, true)
        if path then return path end
    end
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

local function Flags(s)
    local o = s.abFontOutline or "OUTLINE"
    return o == "NONE" and "" or o
end

local cooldownFont = CreateFont("SquizzumablesActionBarCooldownFont")

local function ButtonConfig(def, i, s)
    local font, flags = ResolveFont(s.abFont), Flags(s)
    local p = "ab" .. def.n
    return {
        outOfRangeColoring = s.abRange or "button",
        tooltip = s.abTooltips == false and "disabled" or "enabled",
        showGrid = s[p .. "ShowEmpty"] ~= false,
        colors = { range = { 0.8, 0.1, 0.1 }, mana = { 0.5, 0.5, 1.0 } },
        hideElements = { macro = not s.abShowMacro, hotkey = s.abShowHotkeys == false, equipped = false,
            border = true, borderIfEmpty = true },
        keyBoundTarget = def.bind .. i,
        flyoutDirection = s[p .. "Flyout"] or "UP",
        cooldownCount = s.abCooldownNumbers ~= false,
        actionButtonUI = true,
        assistedHighlight = true,
        spellCastVFX = true,
        text = {
            hotkey = { font = { font = font, size = s.abHotkeySize or 12, flags = flags }, color = { 1, 1, 1 },
                position = { anchor = "TOPRIGHT", relAnchor = "TOPRIGHT", offsetX = -1, offsetY = -2 },
                justifyH = "RIGHT" },
            count = { font = { font = font, size = s.abCountSize or 12, flags = flags }, color = { 1, 1, 1 },
                position = { anchor = "BOTTOMRIGHT", relAnchor = "BOTTOMRIGHT", offsetX = -1, offsetY = 2 },
                justifyH = "RIGHT" },
            macro = { font = { font = font, size = s.abMacroSize or 10, flags = flags }, color = { 1, 1, 1 },
                position = { anchor = "BOTTOM", relAnchor = "BOTTOM", offsetX = 0, offsetY = 2 },
                justifyH = "CENTER" },
        },
    }
end

-- The ElvUI look: once per button. LAB skips its own texture handling for a
-- MasqueSkinned button, so nothing it does later puts the round art back.
-- Short keybind text: SHIFT-1 -> S-1, ALT-CTRL-MOUSEWHEELUP -> A-C-MWU.
-- LAB shows the raw key unless LibKeyBound is loaded, so each button gets its
-- own GetHotkey (a field on the button wins over LAB's metatable method).
local KEY_SHORT = {
    MOUSEWHEELUP = "MWU", MOUSEWHEELDOWN = "MWD",
    LeftButton = "M1", RightButton = "M2", MiddleButton = "M3",
    SPACE = "Spc", BACKSPACE = "Bs", ESCAPE = "Esc", ENTER = "Ent", TAB = "Tab",
    INSERT = "Ins", DELETE = "Del", HOME = "Hm", END = "End", PAGEUP = "PU", PAGEDOWN = "PD",
    CAPSLOCK = "Cap", NUMLOCK = "NL",
}
local function ShortKey(key)
    if not key or key == "" then return key end
    local mods, base = key:match("^(.-)([^%-]+)$")
    if not base then return key end
    if mods == "" and key:sub(-1) == "-" then return key end   -- the minus key itself
    local short = KEY_SHORT[base]
        or base:match("^BUTTON(%d+)$") and ("M" .. base:match("^BUTTON(%d+)$"))
        or base:match("^NUMPAD(.+)$") and ("N" .. (({ DIVIDE = "/", MULTIPLY = "*", MINUS = "-", PLUS = "+",
            DECIMAL = "." })[base:match("^NUMPAD(.+)$")] or base:match("^NUMPAD(.+)$")))
        or base
    mods = mods:gsub("SHIFT%-", "S-"):gsub("CTRL%-", "C-"):gsub("ALT%-", "A-"):gsub("META%-", "M-")
    return mods .. short
end

local function ShortHotkey(self)
    local key = GetBindingKey(self.config.keyBoundTarget or "")
    if not key and self.sqElvCmd then key = GetBindingKey(self.sqElvCmd) end
    if not key then key = GetBindingKey(("CLICK %s:%s"):format(self:GetName(), self.config.keyBoundClickButton)) end
    return key and ShortKey(key) or nil
end

-- The square look. Also used on Blizzard's own stance and pet buttons
-- (ExtraBars.lua), so it writes no fields on the button: Blizzard's code
-- reads those buttons, and a field we wrote would taint it. Re-run after
-- Blizzard redraws a button's art; the border textures are made once.
local looked = setmetatable({}, { __mode = "k" })

local function Look(btn)
    local normal = btn:GetNormalTexture()
    if normal then normal:SetAlpha(0) end
    if btn.NormalTexture then btn.NormalTexture:SetAlpha(0) end
    if btn.SlotBackground then btn.SlotBackground:SetAlpha(0) end
    if btn.SlotArt then btn.SlotArt:SetAlpha(0) end
    if btn.IconMask and not looked[btn] then btn.icon:RemoveMaskTexture(btn.IconMask) end

    if not looked[btn] then
        looked[btn] = true
        local border = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
        border:SetAllPoints()
        border:SetColorTexture(0, 0, 0, 1)
        local fill = btn:CreateTexture(nil, "BACKGROUND", nil, -7)
        fill:SetPoint("TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMRIGHT", -1, 1)
        fill:SetColorTexture(0.08, 0.08, 0.08, 0.6)
    end
    if btn.AutoCastOverlay then
        btn.AutoCastOverlay:ClearAllPoints()
        btn.AutoCastOverlay:SetPoint("TOPLEFT", 1, -1)
        btn.AutoCastOverlay:SetPoint("BOTTOMRIGHT", -1, 1)
    end

    btn.icon:ClearAllPoints()
    btn.icon:SetPoint("TOPLEFT", 1, -1)
    btn.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    for _, cd in ipairs({ btn.cooldown, btn.chargeCooldown, btn.lossOfControlCooldown }) do
        if cd then
            cd:ClearAllPoints()
            cd:SetPoint("TOPLEFT", 1, -1)
            cd:SetPoint("BOTTOMRIGHT", -1, 1)
            if cd.SetCountdownFont then cd:SetCountdownFont("SquizzumablesActionBarCooldownFont") end
        end
    end
    local function Flat(tex, r, g, b, a)
        if not tex then return end
        tex:SetColorTexture(r, g, b, a)
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", 1, -1)
        tex:SetPoint("BOTTOMRIGHT", -1, 1)
    end
    Flat(btn:GetHighlightTexture(), 1, 1, 1, 0.25)
    Flat(btn:GetPushedTexture(), 0.9, 0.8, 0.1, 0.3)
    Flat(btn:GetCheckedTexture(), 1, 1, 1, 0.25)
    if btn.Flash then
        btn.Flash:ClearAllPoints()
        btn.Flash:SetPoint("TOPLEFT", 1, -1)
        btn.Flash:SetPoint("BOTTOMRIGHT", -1, 1)
    end
    if btn.Border then
        btn.Border:ClearAllPoints()
        btn.Border:SetAllPoints()
    end
end

local function Skin(btn)
    btn.MasqueSkinned = true
    btn.GetHotkey = ShortHotkey
    Look(btn)
end

local function CropIcon(tex, w, h)
    local inset = 0.08
    local range = 1 - 2 * inset
    if w >= h then
        local cut = (range - range * h / w) / 2
        tex:SetTexCoord(inset, 1 - inset, inset + cut, 1 - inset - cut)
    else
        local cut = (range - range * w / h) / 2
        tex:SetTexCoord(inset + cut, 1 - inset - cut, inset, 1 - inset)
    end
end

-- ============================================================================
-- Proc glows
-- ============================================================================

local IsOverlayed = (C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed) or _G.IsSpellOverlayed

local function UpdateGlow(btn)
    if not (btn and ns.Glow) then return end
    local id = btn.GetSpellId and btn:GetSpellId()
    id = S.SafeNumber(id, nil)
    local on = id and IsOverlayed and IsOverlayed(id) and true or false
    if on and btn:IsVisible() then
        if not btn.sqGlowing then ns.Glow.Show(btn) end
    elseif btn.sqGlowing then
        ns.Glow.Hide(btn)
    end
end

local function GlowSpell(spellID, on)
    spellID = S.SafeNumber(spellID, nil)
    if not spellID then return end
    for _, rec in pairs(bars) do
        for _, btn in ipairs(rec.buttons) do
            if btn:IsShown() and S.SafeNumber(btn:GetSpellId(), nil) == spellID then
                if on then ns.Glow.Show(btn) else ns.Glow.Hide(btn) end
            end
        end
    end
end

-- A button's contents changed (page, drag, form): its glow may have too.
LAB.RegisterCallback(AB, "OnButtonUpdate", function(_, btn)
    if btn and btn.sqOwned then UpdateGlow(btn) end
end)

-- ============================================================================
-- Bars
-- ============================================================================

local function DefaultPosition(n)
    local row = ({ [1] = 0, [2] = 1, [3] = 2 })[n] or (n - 1)
    return { point = "BOTTOM", relPoint = "BOTTOM", x = 0, y = 40 + row * 38 }
end

-- A frame's position measured at one of its corners, in UIParent units, so
-- the bar stays put at that corner however its size changes.
function AB.CornerOf(f, point)
    local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not l then return nil end
    local scale = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    l, r, t, b = l * scale, r * scale, t * scale, b * scale
    local x = point:find("LEFT") and l or (r - UIParent:GetWidth())
    local y = point:find("TOP") and (t - UIParent:GetHeight()) or b
    return { point = point, relPoint = point, x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
end

-- n is a bar number, or "Stance" / "Pet" / "Micro" (ExtraBars.lua).
local function SavePosition(n)
    local s = BH.settings
    local rec = bars[n] or (X and X.recs[n])
    if not (rec and s) then return end
    local pos = AB.CornerOf(rec.holder, s["ab" .. n .. "Grow"] or "BOTTOMLEFT")
    if not pos then return end
    s["ab" .. n .. "Position"] = pos
    BH:SaveSettings()
end
AB.SavePosition = SavePosition

local function MakeHolder(name, onStop)
    local holder = CreateFrame("Frame", name, UIParent)
    holder:SetMovable(true)
    holder:SetClampedToScreen(true)
    holder:RegisterForDrag("LeftButton")
    holder:EnableMouse(false)
    holder:SetScript("OnDragStart", function(self)
        if InCombatLockdown() or not BH.unlockMode then return end
        BH:GridStartMoving(self)
    end)
    holder:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(self)
        onStop()
        AB.Apply()
    end)
    return holder
end

-- Shared with ExtraBars.lua.
AB.MakeHolder, AB.AskReload, AB.ElvUI = MakeHolder, AskReload, ElvUI
AB.ShortKey, AB.ResolveFont, AB.Flags = ShortKey, ResolveFont, Flags
AB.Look, AB.CropIcon = Look, CropIcon

local function CreateBar(def)
    local n = def.n
    if bars[n] then return bars[n] end
    local holder = MakeHolder("SquizzumablesActionBar" .. n .. "Holder", function() SavePosition(n) end)
    -- SecureHandlerStateTemplate ALONE: combined with BackdropTemplate, the
    -- second template's OnLoad replaces SecureHandler_OnLoad, the header never
    -- gets WrapScript/Execute, and LAB's CreateButton fails. The background is
    -- a child frame instead.
    local header = CreateFrame("Frame", "SquizzumablesActionBar" .. n, UIParent, "SecureHandlerStateTemplate")
    header:SetAttribute("_onstate-page", [[
        self:SetAttribute("state", newstate)
        control:ChildUpdate("state", newstate)
    ]])
    local backdrop = CreateFrame("Frame", nil, header, "BackdropTemplate")
    backdrop:SetAllPoints()
    backdrop:SetFrameLevel(header:GetFrameLevel())

    local rec = { def = def, holder = holder, header = header, backdrop = backdrop, buttons = {}, drivers = {} }
    local s = BH.settings
    local maxPage = n == 1 and Bar1MaxPage() or def.page
    for i = 1, NUM_BUTTONS do
        local btn = LAB:CreateButton(i, "SquizzumablesActionBar" .. n .. "Button" .. i, header, ButtonConfig(def, i, s))
        btn.sqOwned = true
        btn.sqElvCmd = def.elv and (def.elv .. i) or nil
        if n == 1 then
            for page = 1, maxPage do btn:SetState(page, "action", (page - 1) * NUM_BUTTONS + i) end
        else
            btn:SetState(def.page, "action", (def.page - 1) * NUM_BUTTONS + i)
        end
        Skin(btn)
        rec.buttons[i] = btn
    end
    bars[n] = rec
    BH["actionBar" .. n] = holder
    return rec
end

local function SetDriver(rec, kind, cond)
    if rec.drivers[kind] == cond then return end
    if rec.drivers[kind] then UnregisterStateDriver(rec.header, kind) end
    rec.drivers[kind] = cond
    if cond then RegisterStateDriver(rec.header, kind, cond) end
end

local function GridSize(count, perRow, w, h, sp, pad)
    local cols = math.min(count, perRow)
    local rows = math.ceil(count / perRow)
    return 2 * pad + cols * w + (cols - 1) * sp, 2 * pad + rows * h + (rows - 1) * sp
end

local function BindKeys(rec, count)
    local header = rec.header
    ClearOverrideBindings(header)
    if not AB.active then return end
    local def = rec.def
    local elv = def.elv and ElvUI()
    for i = 1, count do
        local name = rec.buttons[i]:GetName()
        for _, cmd in ipairs({ def.bind .. i, elv and (def.elv .. i) or nil }) do
            for k = 1, select("#", GetBindingKey(cmd)) do
                local key = select(k, GetBindingKey(cmd))
                if key then SetOverrideBindingClick(header, false, key, name, "Keybind") end
            end
        end
    end
end

local function HideBarFrames(rec)
    rec.holder:Hide()
    SetDriver(rec, "visibility", nil)
    rec.header:Hide()
    ClearOverrideBindings(rec.header)
end

local function LayoutBar(def, s)
    local n = def.n
    local p = "ab" .. n
    local rec = CreateBar(def)
    local holder, header = rec.holder, rec.header
    if not (AB.active and s[p .. "Enabled"]) then
        HideBarFrames(rec)
        return
    end

    local count = math.max(1, math.min(NUM_BUTTONS, s[p .. "Buttons"] or 12))
    local perRow = math.max(1, math.min(count, s[p .. "PerRow"] or 12))
    local w = s[p .. "Size"] or 32
    local h = (s[p .. "Square"] == false) and (s[p .. "Height"] or w) or w
    local sp = s[p .. "Spacing"] or 2
    local pad = s[p .. "Backdrop"] and (s[p .. "Padding"] or 2) or 0
    local grow = s[p .. "Grow"] or "BOTTOMLEFT"
    local W, H = GridSize(count, perRow, w, h, sp, pad)

    local pos = s[p .. "Position"] or DefaultPosition(n)
    holder:ClearAllPoints()
    holder:SetPoint(pos.point or "BOTTOM", UIParent, pos.relPoint or pos.point or "BOTTOM", pos.x or 0, pos.y or 0)
    holder:SetSize(W, H)
    -- In Edit Mode the holder sits over the buttons, so a drag moves the bar
    -- instead of picking a spell up.
    holder:SetFrameStrata(BH.unlockMode and "HIGH" or "LOW")
    holder:EnableMouse(BH.unlockMode and true or false)
    holder:Show()

    header:ClearAllPoints()
    header:SetPoint(grow, holder, grow, 0, 0)
    header:SetSize(W, H)
    header:SetFrameStrata(s[p .. "Strata"] or "LOW")
    if s[p .. "Backdrop"] then
        local bd = rec.backdrop
        bd:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        bd:SetBackdropColor(0.06, 0.06, 0.06, s.abBackdropAlpha or 0.8)
        bd:SetBackdropBorderColor(0, 0, 0, 1)
    else
        rec.backdrop:SetBackdrop(nil)
    end

    local right = grow:find("RIGHT") and -1 or 1
    local up = grow:find("BOTTOM") and 1 or -1
    local locked = s.abLocked ~= false
    local clickThrough = s[p .. "ClickThrough"] and true or false
    for i, btn in ipairs(rec.buttons) do
        if i <= count then
            btn:SetSize(w, h)
            CropIcon(btn.icon, w, h)
            local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
            btn:ClearAllPoints()
            btn:SetPoint(grow, header, grow, right * (pad + col * (w + sp)), up * (pad + row * (h + sp)))
            btn:SetAttribute("buttonlock", locked)
            btn:EnableMouse(not clickThrough)
            btn:UpdateConfig(ButtonConfig(def, i, s))
            if btn.Count then btn.Count:SetAlpha(s.abShowCount == false and 0 or 1) end
            btn:Show()
        else
            if btn.sqGlowing then ns.Glow.Hide(btn) end
            btn:Hide()
        end
    end

    SetDriver(rec, "page", n == 1 and Bar1Condition(s) or tostring(def.page))
    local cond = s[p .. "Visibility"]
    if not cond or not cond:match("%S") then cond = "show" end
    SetDriver(rec, "visibility", BH.unlockMode and "show" or cond)
    BindKeys(rec, count)

    rec.alpha = (s[p .. "Alpha"] or 100) / 100
    rec.mouseover = s[p .. "Mouseover"] and not BH.unlockMode and true or false
    rec.fadeAlpha = math.min(rec.alpha, (s[p .. "FadeAlpha"] or 0) / 100)
    header:SetAlpha(rec.mouseover and rec.fadeAlpha or rec.alpha)
    for _, btn in ipairs(rec.buttons) do UpdateGlow(btn) end
end

-- ============================================================================
-- Leave Vehicle button
-- ============================================================================

local vehicle, vehicleHolder

local function UpdateVehicle()
    if not vehicle then return end
    local s = BH.settings
    local can = (CanExitVehicle and CanExitVehicle()) or (UnitOnTaxi and UnitOnTaxi("player"))
    vehicle:SetShown(AB.active and s and s.abVehicle ~= false and (can or BH.unlockMode) and true or false)
end

local function CreateVehicle()
    if vehicle then return end
    vehicleHolder = MakeHolder("SquizzumablesLeaveVehicleHolder", function()
        local f = vehicleHolder
        local x, y = f:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if x and BH.settings then
            BH.settings.abVehiclePosition = { point = "CENTER", relPoint = "CENTER", x = math.floor(x - ux + 0.5), y = math.floor(y - uy + 0.5) }
            BH:SaveSettings()
        end
    end)
    vehicle = CreateFrame("Button", "SquizzumablesLeaveVehicleButton", UIParent)
    vehicle:SetAllPoints(vehicleHolder)
    vehicle:SetFrameStrata("MEDIUM")
    local bg = vehicle:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 1)
    local icon = vehicle:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    icon:SetTexture("Interface\\Vehicles\\UI-Vehicles-Button-Exit-Up")
    icon:SetTexCoord(0.14, 0.86, 0.14, 0.86)
    local hl = vehicle:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(icon)
    hl:SetColorTexture(1, 1, 1, 0.25)
    vehicle:SetScript("OnClick", function()
        if UnitOnTaxi("player") then
            TaxiRequestEarlyLanding()
        else
            VehicleExit()
        end
    end)
    vehicle:SetScript("OnEnter", function(self)
        GameTooltip_SetDefaultAnchor(GameTooltip, self)
        GameTooltip:SetText(UnitOnTaxi("player") and (_G.TAXI_CANCEL or "Request stop") or (_G.LEAVE_VEHICLE or "Leave Vehicle"))
        GameTooltip:Show()
    end)
    vehicle:SetScript("OnLeave", function() GameTooltip:Hide() end)
    BH.leaveVehicleFrame = vehicleHolder
end

local function LayoutVehicle(s)
    if not AB.active or s.abVehicle == false then
        if vehicleHolder then vehicleHolder:Hide() end
        UpdateVehicle()
        return
    end
    CreateVehicle()
    local size = s.abVehicleSize or 32
    local pos = s.abVehiclePosition or { point = "BOTTOM", relPoint = "BOTTOM", x = 220, y = 40 }
    vehicleHolder:ClearAllPoints()
    vehicleHolder:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    vehicleHolder:SetSize(size, size)
    vehicleHolder:SetFrameStrata(BH.unlockMode and "HIGH" or "LOW")
    vehicleHolder:EnableMouse(BH.unlockMode and true or false)
    vehicleHolder:Show()
    UpdateVehicle()
end

-- ============================================================================
-- Blizzard's bars
-- ============================================================================

local blizzHidden = false
local hider = CreateFrame("Frame")
hider:Hide()
AB.hider = hider

-- Reparented under a hidden frame with their events off, as ElvUI does.
-- Coming back needs a reload (AskReload), so this only ever runs one way.
local BLIZZARD_BARS = {
    "MainActionBar", "MultiBarBottomLeft", "MultiBarBottomRight", "MultiBarLeft", "MultiBarRight",
    "MultiBar5", "MultiBar6", "MultiBar7", "OverrideActionBar",
}
local function HideBlizzard()
    if blizzHidden or InCombatLockdown() then return end
    blizzHidden = true
    for _, name in ipairs(BLIZZARD_BARS) do
        local f = _G[name]
        if f then
            f:SetParent(hider)
            f:UnregisterAllEvents()
        end
    end
end

-- ============================================================================
-- Apply
-- ============================================================================

function AB.Apply()
    local s = BH.settings
    if not s then return end
    if InCombatLockdown() then
        dirty = true
        return
    end
    dirty = false
    local wanted = AB.Wanted()
    if wanted then
        AB.active = true
        HideBlizzard()
    elseif AB.active then
        -- Switched off this session: the bars go, Blizzard's return on reload.
        AB.active = false
    end

    local path, size = ResolveFont(s.abFont), s.abCooldownSize or 18
    cooldownFont:SetFont(path, size, Flags(s))

    for _, def in ipairs(BARS) do
        if AB.active or bars[def.n] then LayoutBar(def, s) end
    end
    LayoutVehicle(s)
    if X then X.Apply(s) end
end

-- Edit Mode's arrow-key nudge (MOVABLE_FRAMES in Squizzumables.lua).
function AB.Nudge(n, dx, dy)
    local s = BH.settings
    if not s then return end
    local key = n == "vehicle" and "abVehiclePosition" or ("ab" .. n .. "Position")
    local pos = s[key] or (n == "vehicle" and { point = "BOTTOM", relPoint = "BOTTOM", x = 220, y = 40 })
        or (type(n) == "string" and X and X.DefaultPosition(n)) or DefaultPosition(n)
    s[key] = { point = pos.point, relPoint = pos.relPoint, x = (pos.x or 0) + dx, y = (pos.y or 0) + dy }
    BH:SaveSettings()
    AB.Apply()
end

-- Mouseover fading. Alpha is not protected, so this runs in combat too.
local fader = CreateFrame("Frame")
local fadeElapsed = 0
fader:SetScript("OnUpdate", function(_, elapsed)
    fadeElapsed = fadeElapsed + elapsed
    if fadeElapsed < 0.05 then return end
    local step = fadeElapsed * 4
    fadeElapsed = 0
    for _, list in ipairs({ bars, X and X.recs or {} }) do
        for _, rec in pairs(list) do
            if rec.mouseover and rec.header:IsShown() then
                local over = rec.header:IsMouseOver()
                if not over and SpellFlyout and SpellFlyout:IsShown() and SpellFlyout:IsMouseOver() then over = true end
                local target = over and rec.alpha or rec.fadeAlpha
                local a = rec.header:GetAlpha()
                if a < target then a = math.min(target, a + step)
                elseif a > target then a = math.max(target, a - step) end
                rec.header:SetAlpha(a)
            end
        end
    end
end)

-- ============================================================================
-- ElvUI: settings copied once per profile, keybinds on request
-- ============================================================================

local function ElvPosition(n)
    -- The live bar first: exactly where the player sees it.
    local f = _G["ElvUI_Bar" .. n]
    if f and f.GetLeft and f:GetLeft() then
        return f
    end
    return nil
end

local function SeedFromElvUI()
    local s = BH.settings
    if not s or s.abSeededFromElvUI then return end
    local E = ElvUI()
    local db = E and E.db and E.db.actionbar
    if type(db) ~= "table" then return end
    s.abSeededFromElvUI = true

    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local b1 = db.bar1 or {}
    if b1.hotkeyFont and lsm and lsm:IsValid("font", b1.hotkeyFont) then s.abFont = b1.hotkeyFont
    elseif db.font and lsm and lsm:IsValid("font", db.font) then s.abFont = db.font end
    local outline = b1.hotkeyFontOutline or db.fontOutline
    if outline then s.abFontOutline = (outline == "THICKOUTLINE") and "THICKOUTLINE" or (outline == "NONE" and "NONE" or "OUTLINE") end
    if tonumber(b1.hotkeyFontSize) then s.abHotkeySize = tonumber(b1.hotkeyFontSize) end
    if tonumber(b1.countFontSize) then s.abCountSize = tonumber(b1.countFontSize) end
    if tonumber(b1.macroFontSize) then s.abMacroSize = tonumber(b1.macroFontSize) end
    if b1.hotkeytext ~= nil then s.abShowHotkeys = b1.hotkeytext and true or false end
    if b1.counttext ~= nil then s.abShowCount = b1.counttext and true or false end
    if b1.macrotext ~= nil then s.abShowMacro = b1.macrotext and true or false end
    if db.lockActionBars ~= nil then s.abLocked = db.lockActionBars and true or false end
    if db.useRangeColorText then s.abRange = "hotkey" end
    local cdf = db.cooldown and db.cooldown.fonts
    if type(cdf) == "table" and cdf.enable and tonumber(cdf.fontSize) then s.abCooldownSize = tonumber(cdf.fontSize) end
    if db.transparent then s.abBackdropAlpha = 0.6 end
    if type(b1.paging) == "table" then
        s.abPaging = {}
        for class, cond in pairs(b1.paging) do
            if type(cond) == "string" then s.abPaging[class] = cond end
        end
    end
    local ve = db.vehicleExitButton
    if type(ve) == "table" then
        if ve.enable ~= nil then s.abVehicle = ve.enable and true or false end
        if tonumber(ve.size) then s.abVehicleSize = tonumber(ve.size) end
    end

    for _, def in ipairs(BARS) do
        local n, p = def.n, "ab" .. def.n
        local b = db["bar" .. n]
        if type(b) == "table" then
            s[p .. "Enabled"] = b.enabled and true or false
            if tonumber(b.buttons) then s[p .. "Buttons"] = math.max(1, math.min(NUM_BUTTONS, tonumber(b.buttons))) end
            if tonumber(b.buttonsPerRow) then s[p .. "PerRow"] = math.max(1, math.min(NUM_BUTTONS, tonumber(b.buttonsPerRow))) end
            if tonumber(b.buttonSize) then s[p .. "Size"] = tonumber(b.buttonSize) end
            if b.keepSizeRatio == false then
                s[p .. "Square"] = false
                if tonumber(b.buttonHeight) then s[p .. "Height"] = tonumber(b.buttonHeight) end
            end
            if tonumber(b.buttonSpacing) then s[p .. "Spacing"] = tonumber(b.buttonSpacing) end
            if b.backdrop ~= nil then s[p .. "Backdrop"] = b.backdrop and true or false end
            if tonumber(b.backdropSpacing) then s[p .. "Padding"] = tonumber(b.backdropSpacing) end
            if type(b.point) == "string" then s[p .. "Grow"] = b.point end
            if b.showGrid ~= nil then s[p .. "ShowEmpty"] = b.showGrid and true or false end
            if b.clickThrough ~= nil then s[p .. "ClickThrough"] = b.clickThrough and true or false end
            if b.mouseover ~= nil then s[p .. "Mouseover"] = b.mouseover and true or false end
            if tonumber(b.alpha) then
                if b.mouseover then
                    s[p .. "FadeAlpha"] = 0
                else
                    s[p .. "Alpha"] = math.floor(tonumber(b.alpha) * 100 + 0.5)
                end
            end
            if type(b.visibility) == "string" then s[p .. "Visibility"] = b.visibility:gsub("[\r\n]", " ") end
            if type(b.frameStrata) == "string" then s[p .. "Strata"] = b.frameStrata end
            local fd = b.flyoutDirection
            if fd == "UP" or fd == "DOWN" or fd == "LEFT" or fd == "RIGHT" then s[p .. "Flyout"] = fd end

            -- Position, kept at the bar's growth corner.
            local frame = ElvPosition(n)
            local point = s[p .. "Grow"] or "BOTTOMLEFT"
            if frame then
                local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
                local l, r = frame:GetLeft() * scale, frame:GetRight() * scale
                local t, bo = frame:GetTop() * scale, frame:GetBottom() * scale
                local x = point:find("LEFT") and l or (r - UIParent:GetWidth())
                local y = point:find("TOP") and (t - UIParent:GetHeight()) or bo
                s[p .. "Position"] = { point = point, relPoint = point, x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
            else
                local mover = E.db.movers and E.db.movers["ElvAB_" .. n]
                if type(mover) == "string" then
                    local pt, _, rel, x, y = strsplit(",", mover)
                    if pt and rel and tonumber(x) and tonumber(y) then
                        s[p .. "Position"] = { point = pt, relPoint = rel, x = tonumber(x), y = tonumber(y) }
                    end
                end
            end
        end
    end
    local vf = _G["ElvUI_VehicleLeaveButtonHolder"] or _G["MainMenuBarVehicleLeaveButton"]
    if vf and vf.GetCenter and vf:GetCenter() then
        local x, y = vf:GetCenter()
        local scale = vf:GetEffectiveScale() / UIParent:GetEffectiveScale()
        local ux, uy = UIParent:GetCenter()
        s.abVehiclePosition = { point = "CENTER", relPoint = "CENTER", x = math.floor(x * scale - ux + 0.5), y = math.floor(y * scale - uy + 0.5) }
    end
    BH:SaveSettings()
end

function AB.CopyElvUIKeybinds()
    if InCombatLockdown() then
        print("|cff33cc99Squizzumables:|r keybinds can't be changed in combat.")
        return
    end
    if not ElvUI() then
        print("|cff33cc99Squizzumables:|r ElvUI isn't loaded, so there are no ElvUI keybinds to copy.")
        return
    end
    local moved = 0
    for _, def in ipairs(BARS) do
        if def.elv then
            for i = 1, NUM_BUTTONS do
                local keys = { GetBindingKey(def.elv .. i) }
                for _, key in ipairs(keys) do
                    if SetBinding(key, def.bind .. i) then moved = moved + 1 end
                end
            end
        end
    end
    SaveBindings(GetCurrentBindingSet())
    print(string.format("|cff33cc99Squizzumables:|r %d key%s copied from ElvUI's bars to ours.", moved, moved == 1 and "" or "s"))
end

-- After a profile switch, reset or Edit Mode change too.
function BH:ApplyActionBars()
    SeedFromElvUI()
    if X then X.Seed() end
    AB.Apply()
end

-- ============================================================================
-- Events
-- ============================================================================

local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        BH:ApplyActionBars()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if dirty then AB.Apply() end
    elseif event == "UPDATE_BINDINGS" then
        if not AB.active then return end
        if InCombatLockdown() then dirty = true return end
        local s = BH.settings
        for _, def in ipairs(BARS) do
            local rec = bars[def.n]
            if rec and s["ab" .. def.n .. "Enabled"] then
                BindKeys(rec, math.max(1, math.min(NUM_BUTTONS, s["ab" .. def.n .. "Buttons"] or 12)))
            end
        end
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        GlowSpell(arg1, true)
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        GlowSpell(arg1, false)
    else
        UpdateVehicle()
    end
end)
for _, e in ipairs({
    "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "UPDATE_BINDINGS",
    "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE",
    "UNIT_ENTERED_VEHICLE", "UNIT_EXITED_VEHICLE", "VEHICLE_UPDATE", "UPDATE_BONUS_ACTIONBAR",
    "UPDATE_POSSESS_BAR", "UPDATE_OVERRIDE_ACTIONBAR", "PLAYER_ENTERING_WORLD", "TAXIMAP_CLOSED",
    "PLAYER_CONTROL_GAINED", "PLAYER_CONTROL_LOST",
}) do
    pcall(ev.RegisterEvent, ev, e)
end
