-- UI/PreviewColumn.lua
-- The 2.0 options window's preview column (phase 3): a strip down the right of
-- a page showing what its settings do, redrawn four times a second while the
-- page is open, so every control shows up there without knowing the preview
-- exists. The shell (CreateOptionsPanel's NAV table) gives a page one with
-- `preview = "<kind>"` and narrows the page to make room.
--
-- THE RULE, as for the CDM preview (UI/CDMPreview.lua): a preview is drawn by
-- the real code, never a copy. The reminder buttons below are built, dressed,
-- glowed and laid out by Reminders/Helpers.lua's BuildButtonParts /
-- DressButton / GlowButton and BH:LayoutButtons -- only the state is made up.
--
-- 1:1 where it fits: drawn at the size it is on screen, whatever the options
-- window's own scale, and scaled down only when it would not fit the column.

local addonName, ns = ...
local BH = ns.BH

local PreviewColumn = {}
ns.PreviewColumn = PreviewColumn

local SQ_COLORS = ns.SQ_COLORS

PreviewColumn.WIDTH = 230
local PAD = 12
local REFRESH_EVERY = 0.25

local drawers = {}

-- ----------------------------------------------------------------------------
-- Reminder buttons
-- ----------------------------------------------------------------------------

-- What the samples stand for: a flask that is missing, food running low (a
-- live countdown, restarted when it runs out) and your class's raid buff.
local FOOD_LEFT = 272   -- seconds, so the timer reads 4:32 and counts down

local function FirstItem(category)
    local list = BH.defaults and BH.defaults.consumables and BH.defaults.consumables[category]
    return list and list[1]
end

local function ClassBuffSpell()
    local _, class = UnitClass("player")
    local entry = class and BH.defaults and BH.defaults.classBuffs and BH.defaults.classBuffs[class]
    if type(entry) == "table" then
        if entry.spellID then return entry.spellID end
        if entry[1] and entry[1].spellID then return entry[1].spellID end
    end
    return 1459   -- Arcane Intellect, for a class without a raid buff
end

-- Everything that decides how the glow looks. When it changes the glow is
-- stopped and started again, as UpdateButtons does before reusing a button.
local function GlowSignature()
    local s = BH.settings or {}
    local c = s.glowColor or {}
    return tostring(s.glowReminderButtons ~= false) .. (s.buttonGlowStyle or "") .. tostring(s.glowPulse)
        .. (c.r or 1) .. (c.g or 0.82) .. (c.b or 0)
end

drawers.buttons = {
    build = function(col, host)
        local frame = CreateFrame("Frame", nil, host)
        frame:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)   -- re-placed each redraw
        host.frame = frame
        host.samples = {
            { item = FirstItem("flask"), fallback = "Flask" },
            { item = FirstItem("food"), fallback = "Food", left = FOOD_LEFT },
            { spell = ClassBuffSpell() },
        }
        host.buttons = {}
        for i, s in ipairs(host.samples) do
            if s.item then C_Item.RequestLoadItemDataByID(s.item) end
            host.buttons[i] = BH.NewPreviewButton(frame)
        end
        host.started = GetTime()

        local note = host:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        note:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)   -- re-placed each redraw
        note:SetJustifyH("LEFT")
        note:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        note:SetText("A flask missing, food running low and your class buff missing.")
        host.note = note
    end,

    refresh = function(col, host)
        if not (BH.settings and BH.NewPreviewButton) then return end
        local now = GetTime()
        if now - host.started >= FOOD_LEFT then host.started = now end

        local glowSig = GlowSignature()
        local restartGlow = host.glowSig ~= glowSig
        host.glowSig = glowSig

        for i, s in ipairs(host.samples) do
            local btn = host.buttons[i]
            local expires = s.left and (host.started + s.left) or nil
            if s.spell then
                BH.DressPreviewButton(btn, C_Spell.GetSpellTexture(s.spell) or 134400,
                    C_Spell.GetSpellName(s.spell) or "", "spell", s.spell, nil, nil, expires)
            else
                -- The real code finds the label itself once the item is
                -- cached; until then it would start a ticker per redraw, so
                -- the preview hands it a placeholder instead.
                local cached = C_Item.GetItemNameByID(s.item)
                BH.DressPreviewButton(btn, C_Item.GetItemIconByID(s.item) or 134400, cached or s.fallback,
                    "item", s.item, (not cached) and s.fallback or nil, nil, expires)
            end
            if restartGlow then ns.Glow.Hide(btn.glowHost) end
            BH.GlowPreviewButton(btn)
        end

        BH:LayoutButtons(#host.buttons, host.buttons, host.frame)

        -- What is actually drawn, labels and headers included. The layout
        -- sizes its frame to the icons alone, and a label can sit beside them
        -- (vertical, or Label Position Left/Right) or above them -- trusting
        -- the frame size centred a vertical stack and pushed the names off the
        -- column (user screenshot 2026-10-16).
        local frame = host.frame
        local fl, ft = frame:GetLeft(), frame:GetTop()
        local w, h = frame:GetSize()
        local minX, maxX, minY, maxY = 0, w, -h, 0
        if fl and ft then
            local function Grow(region)
                if not (region and region:IsShown()) then return end
                local l, r, t, b = region:GetLeft(), region:GetRight(), region:GetTop(), region:GetBottom()
                if not (l and r and t and b) then return end
                minX, maxX = math.min(minX, l - fl), math.max(maxX, r - fl)
                minY, maxY = math.min(minY, b - ft), math.max(maxY, t - ft)
            end
            for _, btn in ipairs(host.buttons) do
                Grow(btn)
                Grow(btn.label)
                Grow(btn.header)
            end
        end
        local drawnW, drawnH = maxX - minX, maxY - minY

        -- 1:1 with the screen, unless that would overflow the column.
        local scale = UIParent:GetEffectiveScale() / host:GetEffectiveScale()
        local room = host:GetWidth()
        if drawnW > 0 and room > 0 and drawnW * scale > room then scale = room / drawnW end
        frame:SetScale(scale)
        -- Offsets are in the frame's own (scaled) units, the measurements too.
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", host, "TOPLEFT", -minX, -maxY)
        host.note:ClearAllPoints()
        host.note:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -(drawnH * scale) - 10)
        host.note:SetPoint("RIGHT", host, "RIGHT", 0, 0)
        host:SetHeight(drawnH * scale + 40)
    end,
}

-- ----------------------------------------------------------------------------
-- Mouse cursor
-- ----------------------------------------------------------------------------

-- The real cursor is the preview: drawing a second set of rings would mean
-- either a copy of Core/Cursor.lua or rebuilding it around instances. While
-- the page is open the cursor is lifted over the options window (and shown out
-- of combat with Only In Combat on), so every setting shows on it directly.
drawers.cursor = {
    build = function(col, host)
        local text = host:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        text:SetPoint("RIGHT", host, "RIGHT", 0, 0)
        text:SetJustifyH("LEFT")
        text:SetSpacing(3)
        host.text = text
        host:SetHeight(120)
    end,

    refresh = function(col, host)
        local on = BH.CursorPreviewState and BH:CursorPreviewState()
        if on then
            host.text:SetText("Your cursor is the preview: move the mouse over this window and every "
                .. "change shows on it as you make it.\n\nThe global cooldown and cast rings fill when you "
                .. "use an ability or cast.")
            host.text:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])
        else
            host.text:SetText("Turn on Enable Mouse Cursor and your cursor becomes the preview: every "
                .. "change on this page shows on it as you make it.")
            host.text:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        end
    end,

    show = function() if BH.SetCursorPreview then BH:SetCursorPreview(true) end end,
    hide = function() if BH.SetCursorPreview then BH:SetCursorPreview(false) end end,
}

-- ----------------------------------------------------------------------------
-- The column
-- ----------------------------------------------------------------------------

--- A preview column of `kind` on the right of `parent` (the content area), or
--- nil for an unknown kind. Hidden until its page is shown.
function PreviewColumn.Create(parent, kind)
    local drawer = drawers[kind]
    if not drawer then return nil end

    local col = CreateFrame("Frame", nil, parent)
    col:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    col:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    col:SetWidth(PreviewColumn.WIDTH)
    col:Hide()

    local edge = col:CreateTexture(nil, "ARTWORK")
    edge:SetWidth(1)
    edge:SetPoint("TOPLEFT", col, "TOPLEFT", 0, -8)
    edge:SetPoint("BOTTOMLEFT", col, "BOTTOMLEFT", 0, 8)
    edge:SetColorTexture(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.5)

    local title = col:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", col, "TOPLEFT", PAD, -14)
    title:SetText("Preview")
    ns.ApplyAccent(title, "text")

    local sub = col:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    sub:SetText("Changes as you edit.")
    sub:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local host = CreateFrame("Frame", nil, col)
    host:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -16)
    host:SetPoint("RIGHT", col, "RIGHT", -PAD, 0)
    host:SetHeight(1)
    col.host = host
    drawer.build(col, host)

    -- `show`/`hide`, for a drawer that changes something live while its page
    -- is open. OnHide also fires when the whole window closes.
    local elapsed = REFRESH_EVERY
    col:SetScript("OnShow", function()
        elapsed = REFRESH_EVERY
        if drawer.show then drawer.show(col, host) end
    end)
    col:SetScript("OnHide", function()
        if drawer.hide then drawer.hide(col, host) end
    end)
    col:SetScript("OnUpdate", function(_, e)
        elapsed = elapsed + e
        if elapsed < REFRESH_EVERY then return end
        elapsed = 0
        drawer.refresh(col, host)
    end)
    return col
end
