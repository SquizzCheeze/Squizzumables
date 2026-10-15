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
        frame:SetPoint("TOP", host, "TOP", 0, 0)
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
        note:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -10)
        note:SetPoint("RIGHT", host, "RIGHT", 0, 0)
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

        -- 1:1 with the screen, unless that would overflow the column.
        local frame = host.frame
        local scale = UIParent:GetEffectiveScale() / host:GetEffectiveScale()
        local w, h = frame:GetSize()
        local room = host:GetWidth()
        if w > 0 and room > 0 and w * scale > room then scale = room / w end
        frame:SetScale(scale)
        host:SetHeight(h * scale + 40)
    end,
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

    local elapsed = REFRESH_EVERY
    col:SetScript("OnShow", function() elapsed = REFRESH_EVERY end)
    col:SetScript("OnUpdate", function(_, e)
        elapsed = elapsed + e
        if elapsed < REFRESH_EVERY then return end
        elapsed = 0
        drawer.refresh(col, host)
    end)
    return col
end
