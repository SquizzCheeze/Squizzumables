-- ActionBars/ExtraBars.lua
-- The stance bar, pet bar and micro menu, for when Squizzumables' action bars
-- replace ElvUI's. Loaded just BEFORE ActionBars.lua, which adds these tabs to
-- its settings and calls X.Apply / X.Seed; everything here reaches the action
-- bar module through ns.ActionBars at run time.
--
-- These are Blizzard's OWN buttons, moved into our frames (what ElvUI does
-- for the pet bar). Clicking, keybinds (SHAPESHIFTBUTTON, BONUSACTIONBUTTON),
-- autocast on right-click, cooldowns and the checked state all stay
-- Blizzard's code, which goes on updating the buttons because their bars are
-- only hidden (under ns.ActionBars.hider), never stopped. The one thing a
-- hidden bar stops is its OnUpdate, so the pet bar's range check runs here.
--
-- Taint: nothing here writes a field on a Blizzard button (bookkeeping lives
-- in our own tables), and hooks are hooksecurefunc / HookScript only. Moving
-- a button is done out of combat; giving it back needs a reload.

local addonName, ns = ...
local BH = ns.BH
local S = BH.Secrets

local X = {}
ns.ActionBarExtras = X

local KINDS = { "Stance", "Pet", "Micro" }
local INFO = {
    Stance = { label = "Stance Bar", frame = "SquizzumablesStanceBar", max = 10, perRow = 10,
        tip = "Your forms, stances, auras or aspects, whichever your class has.",
        vis = BH.IS_FOREVER and "[vehicleui] hide; show" or "[vehicleui][petbattle] hide; show",
        pos = { point = "BOTTOM", relPoint = "BOTTOM", x = -220, y = 160 } },
    Pet = { label = "Pet Bar", frame = "SquizzumablesPetBar", max = 10, perRow = 10,
        tip = "Your pet's abilities. Right-click one to turn its autocast on or off.",
        vis = (BH.IS_FOREVER and "" or "[petbattle] hide; ") .. "[novehicleui,pet,nooverridebar,nopossessbar] show; hide",
        pos = { point = "BOTTOM", relPoint = "BOTTOM", x = 220, y = 160 } },
    Micro = { label = "Micro Menu", frame = "SquizzumablesMicroBar", max = 16, perRow = 12,
        tip = "The small buttons for your character, talents, collections and the game menu.",
        vis = BH.IS_FOREVER and "show" or "[petbattle] hide; show",
        pos = { point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT", x = -4, y = 4 } },
}

function X.DefaultPosition(k)
    local p = INFO[k] and INFO[k].pos
    return p and { point = p.point, relPoint = p.relPoint, x = p.x, y = p.y } or nil
end

local GROW = {
    { text = "Bottom left (fill right, then up)",  value = "BOTTOMLEFT" },
    { text = "Bottom right (fill left, then up)",  value = "BOTTOMRIGHT" },
    { text = "Top left (fill right, then down)",   value = "TOPLEFT" },
    { text = "Top right (fill left, then down)",   value = "TOPRIGHT" },
}

local recs = {}       -- kind -> { holder, header, backdrop, buttons, ... }
local taken = {}      -- kind -> true once Blizzard's buttons are in our frame
X.recs, X.taken = recs, taken

-- ============================================================================
-- Settings (tabs on the Action Bars page)
-- ============================================================================

X.PAGES = {}
for _, k in ipairs(KINDS) do
    local info, p = INFO[k], "ab" .. k
    local function on(s) return s[p .. "Enabled"] ~= false end
    local rows = {
        { key = p .. "Enabled", type = "check", default = true, label = "Show " .. info.label,
          tip = info.tip .. "\n\nUntick to give it back to Blizzard (after a reload).",
          apply = function(v)
              if not v and taken[k] and ns.ActionBars then ns.ActionBars.AskReload() end
          end },
        { key = p .. "PerRow", type = "slider", default = info.perRow, min = 1, max = info.max, step = 1,
          label = "Buttons per Row", tip = "Buttons in a row before the next row starts.", when = on },
    }
    if k == "Micro" then
        rows[#rows + 1] = { key = p .. "Scale", type = "slider", default = 100, min = 40, max = 150, step = 5,
            label = "Size", tip = "Size of the buttons, in percent of Blizzard's.", when = on }
    else
        rows[#rows + 1] = { key = p .. "Size", type = "slider", default = 30, min = 16, max = 64, step = 1,
            label = "Button Size", tip = "Width and height of each button.", when = on }
    end
    local rest = {
        { key = p .. "Spacing", type = "slider", default = 2, min = 0, max = 20, step = 1,
          label = "Spacing", tip = "Space between buttons.", when = on },
        { key = p .. "Grow", type = "dropdown", default = "BOTTOMLEFT", items = GROW,
          label = "Grow From", tip = "The corner the first button sits in.", when = on },
        { type = "header", label = "BACKGROUND" },
        { key = p .. "Backdrop", type = "check", default = false,
          label = "Background", tip = "A dark background behind the buttons.", when = on },
        { key = p .. "Padding", type = "slider", default = 2, min = 0, max = 20, step = 1,
          label = "Padding", tip = "Space between the background's edge and the buttons.",
          when = function(s) return on(s) and s[p .. "Backdrop"] end },
        { type = "header", label = "VISIBILITY" },
        { key = p .. "Alpha", type = "slider", default = 100, min = 0, max = 100, step = 5,
          label = "Opacity", tip = "How visible the bar is, in percent.", when = on },
        { key = p .. "Mouseover", type = "check", default = false,
          label = "Show on Mouseover", tip = "The bar fades out until you point at it.", when = on },
        { key = p .. "FadeAlpha", type = "slider", default = 0, min = 0, max = 100, step = 5,
          label = "Faded Opacity", tip = "How visible the bar stays while faded, in percent.",
          when = function(s) return on(s) and s[p .. "Mouseover"] end },
        { key = p .. "Visibility", type = "editbox", default = info.vis,
          label = "Visibility Condition",
          tip = "A macro condition deciding when the bar shows. Example: [combat] show; hide", when = on },
    }
    for _, r in ipairs(rest) do rows[#rows + 1] = r end
    X.PAGES[#X.PAGES + 1] = { key = k:lower(), label = info.label, rows = rows }
end

-- ============================================================================
-- Taking Blizzard's buttons
-- ============================================================================

local index = setmetatable({}, { __mode = "k" })   -- button -> slot number

local function SetHotkey(btn)
    local AB = ns.ActionBars
    local s = BH.settings
    local i = index[btn]
    if not (AB and s and i and btn.HotKey) then return end
    local cmd = (btn:GetName() or ""):find("^StanceButton") and "SHAPESHIFTBUTTON" or "BONUSACTIONBUTTON"
    local key = GetBindingKey(cmd .. i)
    if key then
        btn.HotKey:SetText(AB.ShortKey(key))
        btn.HotKey:Show()
    else
        -- What Blizzard's pet range check expects for an unbound button.
        btn.HotKey:SetText(RANGE_INDICATOR)
        btn.HotKey:Hide()
    end
    btn.HotKey:SetAlpha(s.abShowHotkeys == false and 0 or 1)
end

local function MicroButtons()
    local list = {}
    if MicroMenu and MicroMenu.GetChildren then
        for _, c in ipairs({ MicroMenu:GetChildren() }) do
            if c.layoutIndex then list[#list + 1] = c end
        end
        table.sort(list, function(a, b) return rawget(a, "layoutIndex") < rawget(b, "layoutIndex") end)
    end
    return list
end

local queued
local function Queue()
    if queued then return end
    queued = true
    C_Timer.After(0, function()
        queued = false
        if InCombatLockdown() then X.pending = true return end
        if BH.settings then X.Apply(BH.settings) end
    end)
end

local function Rec(k)
    if recs[k] then return recs[k] end
    local AB = ns.ActionBars
    local info = INFO[k]
    local holder = AB.MakeHolder(info.frame .. "Holder", function() AB.SavePosition(k) end)
    -- The micro menu holds no protected buttons, so a plain frame will do.
    local header = k == "Micro" and CreateFrame("Frame", info.frame, UIParent)
        or CreateFrame("Frame", info.frame, UIParent, "SecureHandlerStateTemplate")
    local backdrop = CreateFrame("Frame", nil, header, "BackdropTemplate")
    backdrop:SetAllPoints()
    backdrop:SetFrameLevel(header:GetFrameLevel())
    local rec = { kind = k, holder = holder, header = header, backdrop = backdrop, buttons = {} }
    recs[k] = rec
    BH["actionBar" .. k] = holder
    return rec
end

local function Take(k, rec)
    if taken[k] then return end
    local AB = ns.ActionBars
    if k == "Micro" then
        local list = MicroButtons()
        if #list == 0 then return end
        taken[k] = true
        -- WoW Forever's micro menu draws a bar frame round its buttons
        -- (retail's has none). Emptied, it kept its old size until Edit Mode
        -- next laid it out, leaving a bare border on screen.
        for _, key in ipairs({ "BorderArt", "BackgroundArt" }) do
            local art = rawget(MicroMenu, key)
            if art then art:SetAlpha(0) end
        end
        for _, b in ipairs(list) do
            local w, h = b:GetSize()
            rec.w, rec.h = rec.w or w, rec.h or h
            b:SetParent(rec.header)
            b:HookScript("OnShow", Queue)
            b:HookScript("OnHide", Queue)
        end
        rec.buttons = list
        return
    end
    local bar = k == "Stance" and _G.StanceBar or _G.PetActionBar
    local prefix = k == "Stance" and "StanceButton" or "PetActionButton"
    if not _G[prefix .. "1"] then return end
    taken[k] = true
    -- Hidden, not stopped: its events keep the buttons' icons and cooldowns current.
    if bar then bar:SetParent(AB.hider) end
    for i = 1, INFO[k].max do
        local b = _G[prefix .. i]
        if b then
            index[b] = i
            rec.buttons[#rec.buttons + 1] = b
            b:SetParent(rec.header)
            AB.Look(b)
            if b.UpdateButtonArt then hooksecurefunc(b, "UpdateButtonArt", AB.Look) end
            if b.SetHotkeys then hooksecurefunc(b, "SetHotkeys", SetHotkey) end
        end
    end
end

-- ============================================================================
-- Layout
-- ============================================================================

local function SetVisibility(rec, cond)
    if rec.vis == cond then return end
    if rec.vis then UnregisterStateDriver(rec.header, "visibility") end
    rec.vis = cond
    if cond then RegisterStateDriver(rec.header, "visibility", cond) end
end

local function Hide(rec)
    rec.holder:Hide()
    SetVisibility(rec, nil)
    rec.header:Hide()
end

local function LayoutKind(k, s)
    local AB = ns.ActionBars
    local p = "ab" .. k
    if not (AB.active and s[p .. "Enabled"] ~= false) then
        if recs[k] then Hide(recs[k]) end
        return
    end
    local rec = Rec(k)
    Take(k, rec)
    if not taken[k] then Hide(rec) return end

    local shown = {}
    local forms = k == "Stance" and GetNumShapeshiftForms() or 0
    for i, b in ipairs(rec.buttons) do
        if k == "Micro" then
            if b:IsShown() then shown[#shown + 1] = b end
        elseif k == "Pet" or i <= forms then
            shown[#shown + 1] = b
        end
    end

    local count = #shown
    local slots = math.max(count, 1)
    local perRow = math.max(1, math.min(slots, s[p .. "PerRow"] or INFO[k].perRow))
    local w, h, scale = s[p .. "Size"] or 30, s[p .. "Size"] or 30, 1
    if k == "Micro" then
        w, h = rec.w or 32, rec.h or 40
        scale = (s[p .. "Scale"] or 100) / 100
    end
    local sp = s[p .. "Spacing"] or 2
    local pad = s[p .. "Backdrop"] and (s[p .. "Padding"] or 2) or 0
    local grow = s[p .. "Grow"] or "BOTTOMLEFT"
    local cols, rows = math.min(slots, perRow), math.ceil(slots / perRow)
    local W, H = 2 * pad + cols * w + (cols - 1) * sp, 2 * pad + rows * h + (rows - 1) * sp

    local holder, header = rec.holder, rec.header
    local pos = s[p .. "Position"] or X.DefaultPosition(k)
    holder:ClearAllPoints()
    holder:SetPoint(pos.point or "BOTTOM", UIParent, pos.relPoint or pos.point or "BOTTOM", pos.x or 0, pos.y or 0)
    holder:SetSize(W * scale, H * scale)
    holder:SetFrameStrata(BH.unlockMode and "HIGH" or "LOW")
    holder:EnableMouse(BH.unlockMode and true or false)
    holder:Show()

    header:SetScale(scale)
    header:ClearAllPoints()
    header:SetPoint(grow, holder, grow, 0, 0)
    header:SetSize(W, H)
    header:SetFrameStrata("LOW")
    if s[p .. "Backdrop"] then
        rec.backdrop:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        rec.backdrop:SetBackdropColor(0.06, 0.06, 0.06, s.abBackdropAlpha or 0.8)
        rec.backdrop:SetBackdropBorderColor(0, 0, 0, 1)
    else
        rec.backdrop:SetBackdrop(nil)
    end

    local right = grow:find("RIGHT") and -1 or 1
    local up = grow:find("BOTTOM") and 1 or -1
    local font, flags = AB.ResolveFont(s.abFont), AB.Flags(s)
    for i, b in ipairs(shown) do
        local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
        b:ClearAllPoints()
        b:SetPoint(grow, header, grow, right * (pad + col * (w + sp)), up * (pad + row * (h + sp)))
        if k ~= "Micro" then
            b:SetSize(w, h)
            if b.icon then AB.CropIcon(b.icon, w, h) end
            if b.HotKey then
                b.HotKey:SetFont(font, s.abHotkeySize or 12, flags)
                b.HotKey:ClearAllPoints()
                b.HotKey:SetPoint("TOPRIGHT", -1, -2)
                b.HotKey:SetSize(w - 2, (s.abHotkeySize or 12) + 2)
                b.HotKey:SetJustifyH("RIGHT")
            end
            if b.Count then
                b.Count:SetFont(font, s.abCountSize or 12, flags)
                b.Count:SetAlpha(s.abShowCount == false and 0 or 1)
            end
            if b.cooldown then
                if b.cooldown.SetCountdownFont then b.cooldown:SetCountdownFont("SquizzumablesActionBarCooldownFont") end
                b.cooldown:SetHideCountdownNumbers(s.abCooldownNumbers == false)
            end
            SetHotkey(b)
        end
    end

    local cond = s[p .. "Visibility"]
    if not cond or not cond:match("%S") then cond = "show" end
    if BH.unlockMode then cond = "show"
    elseif k == "Stance" and forms == 0 then cond = "hide" end
    SetVisibility(rec, cond)

    rec.alpha = (s[p .. "Alpha"] or 100) / 100
    rec.mouseover = s[p .. "Mouseover"] and not BH.unlockMode and true or false
    rec.fadeAlpha = math.min(rec.alpha, (s[p .. "FadeAlpha"] or 0) / 100)
    header:SetAlpha(rec.mouseover and rec.fadeAlpha or rec.alpha)
end

-- Out of combat only (ns.ActionBars.Apply sees to that).
function X.Apply(s)
    X.pending = false
    for _, k in ipairs(KINDS) do LayoutKind(k, s) end
end

-- ============================================================================
-- ElvUI's settings, copied once per profile
-- ============================================================================

local ELV = {
    Stance = { db = "stanceBar", frame = "ElvUI_StanceBar", mover = "ShiftAB" },
    Pet    = { db = "barPet",    frame = "ElvUI_BarPet",    mover = "PetAB" },
    Micro  = { db = "microbar",  frame = "ElvUI_MicroBar",  mover = "MicrobarMover" },
}
local CORNERS = { BOTTOMLEFT = true, BOTTOMRIGHT = true, TOPLEFT = true, TOPRIGHT = true }

function X.Seed()
    local s = BH.settings
    local AB = ns.ActionBars
    if not (s and AB) or s.abExtrasSeededFromElvUI then return end
    local E = AB.ElvUI()
    local db = E and E.db and E.db.actionbar
    if type(db) ~= "table" then return end
    s.abExtrasSeededFromElvUI = true
    for k, m in pairs(ELV) do
        local b, p = db[m.db], "ab" .. k
        if type(b) == "table" then
            if b.enabled ~= nil then s[p .. "Enabled"] = b.enabled and true or false end
            if tonumber(b.buttonsPerRow) then s[p .. "PerRow"] = math.max(1, math.min(INFO[k].max, tonumber(b.buttonsPerRow))) end
            local size = tonumber(b.buttonSize)
            if size then
                if k == "Micro" then
                    local native = CharacterMicroButton and CharacterMicroButton:GetWidth()
                    if native and native > 0 then
                        s[p .. "Scale"] = math.max(40, math.min(150, math.floor(size / native * 20 + 0.5) * 5))
                    end
                else
                    s[p .. "Size"] = size
                end
            end
            if tonumber(b.buttonSpacing) then s[p .. "Spacing"] = tonumber(b.buttonSpacing) end
            if b.backdrop ~= nil then s[p .. "Backdrop"] = b.backdrop and true or false end
            if tonumber(b.backdropSpacing) then s[p .. "Padding"] = tonumber(b.backdropSpacing) end
            if CORNERS[b.point] then s[p .. "Grow"] = b.point end
            if b.mouseover ~= nil then s[p .. "Mouseover"] = b.mouseover and true or false end
            if tonumber(b.alpha) then
                if b.mouseover then
                    s[p .. "FadeAlpha"] = 0
                else
                    s[p .. "Alpha"] = math.floor(tonumber(b.alpha) * 100 + 0.5)
                end
            end
            if type(b.visibility) == "string" then s[p .. "Visibility"] = b.visibility:gsub("[\r\n]", " ") end

            local grow = s[p .. "Grow"] or "BOTTOMLEFT"
            local f = _G[m.frame]
            local pos = f and f.GetLeft and f:GetLeft() and AB.CornerOf(f, grow)
            if not pos then
                local mover = E.db.movers and E.db.movers[m.mover]
                if type(mover) == "string" then
                    local pt, _, rel, x, y = strsplit(",", mover)
                    if pt and rel and tonumber(x) and tonumber(y) then
                        pos = { point = pt, relPoint = rel, x = tonumber(x), y = tonumber(y) }
                    end
                end
            end
            if pos then s[p .. "Position"] = pos end
        end
    end
    BH:SaveSettings()
end

-- ============================================================================
-- Events
-- ============================================================================

local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if X.pending then Queue() end
    elseif event == "UPDATE_BINDINGS" then
        for _, k in ipairs({ "Stance", "Pet" }) do
            if taken[k] then
                for _, b in ipairs(recs[k].buttons) do SetHotkey(b) end
            end
        end
    elseif taken.Stance then
        -- UPDATE_SHAPESHIFT_FORMS: a form learned or lost changes the count.
        Queue()
    end
end)
for _, e in ipairs({ "PLAYER_REGEN_ENABLED", "UPDATE_BINDINGS", "UPDATE_SHAPESHIFT_FORMS" }) do
    ev:RegisterEvent(e)
end

-- The pet bar's range check: Blizzard runs it from the bar's OnUpdate, which
-- stops once the bar is hidden.
local elapsedPet = 0
ev:SetScript("OnUpdate", function(_, elapsed)
    elapsedPet = elapsedPet + elapsed
    if elapsedPet < 0.2 then return end
    elapsedPet = 0
    local rec = recs.Pet
    if not (taken.Pet and rec and rec.header:IsVisible() and ActionButton_UpdateRangeIndicator) then return end
    for i, b in ipairs(rec.buttons) do
        local _, _, _, _, _, _, _, checksRange, inRange = GetPetActionInfo(i)
        if not (S.IsSecret(checksRange) or S.IsSecret(inRange)) then
            ActionButton_UpdateRangeIndicator(b, checksRange, inRange)
        end
    end
end)
