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
-- Kelerts: the alerts on a miniature screen
-- ----------------------------------------------------------------------------

-- These alerts are placed ON the screen -- full-screen edge glows, the ( )
-- arcs round the character, the lust image where it was moved to -- so where
-- they sit matters as much as how they look. The preview is the screen scaled
-- down to the column, with the alert drawn and placed in it by the real code
-- (Alerts/Kelerts.lua's BuildAlertParts / PaintAlert, Alerts/CDMAlerts.lua's
-- PaintImage / ImageRect), with a close up above it to make the image out.
-- It follows the page's sub-tab.

-- The close up's largest side, in the column's units.
local CLOSE_UP = 150

drawers.kelerts = {
    build = function(col, host)
        local function Caption(text)
            local fs = host:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetJustifyH("LEFT")
            fs:SetText(text)
            fs:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])
            return fs
        end

        -- Close up: the image itself, big enough to make out. On the
        -- miniature screen a 200px alert is a dozen pixels across (user
        -- screenshot 2026-10-16), which places it but shows nothing of it.
        host.closeCaption = Caption("Close up")
        -- The alert frame is scaled to fit, and a scaled frame's anchor
        -- offsets scale with it, so it sits at 0,0 in an unscaled holder and
        -- the holder is what gets placed.
        local holder = CreateFrame("Frame", nil, host)
        host.closeHolder = holder
        host.closeAlert = BH.NewAlertPreview and BH.NewAlertPreview(holder)
        if host.closeAlert then host.closeAlert:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0) end
        local closeImg = CreateFrame("Frame", nil, host)
        closeImg.tex = closeImg:CreateTexture(nil, "ARTWORK")
        closeImg.tex:SetAllPoints()
        host.closeImg = closeImg

        -- Where it shows: the screen, scaled down to the column.
        host.screenCaption = Caption("On your screen")
        local box = CreateFrame("Frame", nil, host, "BackdropTemplate")
        box:SetClipsChildren(true)
        box:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8", edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 1 })
        box:SetBackdropColor(0.02, 0.02, 0.03, 0.9)
        box:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
        host.box = box

        -- Where the character stands, so the arcs and edge glows read as
        -- being around something.
        local you = box:CreateTexture(nil, "BORDER")
        you:SetColorTexture(1, 1, 1, 0.12)
        you:SetSize(6, 16)
        you:SetPoint("CENTER", box, "CENTER", 0, -6)

        host.alert = BH.NewAlertPreview and BH.NewAlertPreview(box)
        local img = CreateFrame("Frame", nil, box)
        img.tex = img:CreateTexture(nil, "ARTWORK")
        img.tex:SetAllPoints()
        host.img = img

        local note = host:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        note:SetJustifyH("LEFT")
        note:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        host.note = note
    end,

    refresh = function(col, host)
        local box, alert, img = host.box, host.alert, host.img
        local closeAlert, closeImg = host.closeAlert, host.closeImg
        local w, h = UIParent:GetWidth(), UIParent:GetHeight()
        local room = host:GetWidth()
        if not (w > 0 and h > 0 and room > 0 and alert and closeAlert) then return end
        local boxH = room * h / w
        box:SetSize(room, boxH)
        local k = room / w
        local closeMax = math.min(room, CLOSE_UP)
        local sel = BH.kelPages and BH.kelPages.GetSelected and BH.kelPages.GetSelected() or "alerts"

        -- Laid out top to bottom each pass: what shows depends on the sub-tab.
        local y = 0
        local function Place(region, height, gap)
            region:ClearAllPoints()
            region:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
            y = y + height + (gap or 0)
        end
        local function Caption(fs)
            fs:Show()
            Place(fs, fs:GetStringHeight(), 4)
        end

        alert:Hide()
        img:Hide()
        host.closeHolder:Hide()
        closeAlert:Hide()
        closeImg:Hide()
        host.closeCaption:Hide()
        host.screenCaption:Hide()
        box:Hide()

        local text
        if sel == "alerts" and BH.CurrentAlert then
            local a = BH.CurrentAlert()
            -- Repainted only when the look changes: a repaint restarts a
            -- frame sequence from its first frame.
            local sig = tostring(a.texture) .. "|" .. tostring(a.frameCount) .. "|" .. tostring(a.fps)
                .. "|" .. tostring(a.loop) .. "|" .. tostring(a.opacity)
            if alert.sig ~= sig then
                alert.sig = sig
                BH.PaintAlertPreview(alert, a)
                BH.PaintAlertPreview(closeAlert, a)
            end

            Caption(host.closeCaption)
            closeAlert:SetScale(closeMax / 200)   -- the alert frame is 200 x 200
            host.closeHolder:SetSize(closeMax, closeMax)
            Place(host.closeHolder, closeMax, 12)
            host.closeHolder:Show()
            closeAlert:Show()

            Caption(host.screenCaption)
            Place(box, boxH, 10)
            box:Show()
            local point, relPoint, x, y2 = BH.KelAlertAnchor()
            alert:SetScale(math.max(0.01, ((BH.settings and BH.settings.kelAlertScale) or 1) * k))
            alert:ClearAllPoints()
            alert:SetPoint(point, box, relPoint, x, y2)
            alert:Show()
            text = "Test plays it for real; Unlock Frames moves it."
        elseif sel == "buffsounds" and BH.SelectedAlertImage then
            local entry = BH.SelectedAlertImage()
            if entry then
                local sig = BH.AlertImageSignature(entry)
                if img.sig ~= sig then
                    img.sig = sig
                    BH.PaintAlertImage(img.tex, entry)
                    BH.PaintAlertImage(closeImg.tex, entry)
                end
                local fill, iw, ih, x, y2 = BH.AlertImageRect(entry)

                -- A placed image gets a close up too; a full-screen one is
                -- already big enough on the screen below.
                if not fill and iw > 0 and ih > 0 then
                    Caption(host.closeCaption)
                    local fit = math.min(closeMax / iw, closeMax / ih)
                    closeImg:SetSize(iw * fit, ih * fit)
                    Place(closeImg, ih * fit, 12)
                    closeImg:Show()
                end

                Caption(host.screenCaption)
                Place(box, boxH, 10)
                box:Show()
                img:SetScale(math.max(0.01, k))
                img:ClearAllPoints()
                if fill then
                    img:SetSize(w, h)
                    img:SetPoint("CENTER", box, "CENTER", 0, 0)
                else
                    img:SetSize(iw, ih)
                    img:SetPoint("CENTER", box, "CENTER", x, y2)
                end
                img:Show()
                text = "The selected buff's or cooldown's image."
            else
                img.sig = nil
                text = "Select a buff or cooldown with an image to see it here."
            end
        else
            text = "The Death Tally shows where it sits, and can be moved, with Unlock Frames."
        end

        host.note:SetText(text)
        host.note:SetWidth(room)
        Place(host.note, host.note:GetStringHeight())
        host:SetHeight(y + 10)
    end,
}

-- ----------------------------------------------------------------------------
-- Text reminders
-- ----------------------------------------------------------------------------

-- The big text reminders each sub-tab sets up, drawn by the real code
-- (BH.ReminderText, which CreateReminderFrame uses) at their Scale setting
-- relative to each other, shrunk together if the widest would overflow. One
-- turned off is shown faded. Sub-tabs with nothing on screen get a note.
local REMINDERS_ON_TAB = {
    class = { "beacon", "earthShield", "symbiotic", "repair" },
    bags  = { "bags" },
    cc    = { "healerCC" },
}
-- How wide a reminder really draws, unscaled. Its words are usually wider
-- than its frame -- "REMEMBER EARTH SHIELD" at 24pt is well over 320 -- and
-- simply spill past it, on screen as here, so fitting to the frame size let
-- them run off the column (user screenshot 2026-10-16).
--
-- Measured ONCE, on an unscaled copy of the text (item.measure), and kept. The
-- drawn text sits in a frame that is scaled to fit, and a font's measured
-- width shifts with the scale it renders at, so measuring the drawn one fed
-- each redraw's fit into the next measurement: the reminders pulsed small to
-- big and back (user report 2026-10-16).
local function ReminderWidth(item)
    if not item.textW then
        local w = item.measure:GetStringWidth() or 0
        if w <= 0 then return item.def.size[1] end   -- font not ready yet; try next redraw
        item.textW = w
    end
    return math.max(item.def.size[1], item.textW + 8)
end

local NOTHING_ON_SCREEN = {
    sounds = "Instance sounds play a sound only; nothing shows on screen.",
    feast  = "Feast Announce posts in chat and plays the sound set below; nothing shows on screen.",
}

drawers.textreminders = {
    build = function(col, host)
        host.items = {}
        for _, keys in pairs(REMINDERS_ON_TAB) do
            for _, key in ipairs(keys) do
                local def = BH.REMINDERS_BY_KEY and BH.REMINDERS_BY_KEY[key]
                if def then
                    -- Scaled inside an unscaled holder: a scaled frame's
                    -- anchor offsets scale with it.
                    local holder = CreateFrame("Frame", nil, host)
                    local f = CreateFrame("Frame", nil, holder)
                    f:SetSize(def.size[1], def.size[2])
                    f:SetPoint("CENTER", holder, "CENTER", 0, 0)
                    BH.ReminderText(f, def)
                    -- The same text on a frame that is never scaled, only for
                    -- measuring (see ReminderWidth).
                    local measureHost = CreateFrame("Frame", nil, host)
                    measureHost:SetSize(1, 1)
                    measureHost:SetAlpha(0)
                    local measure = BH.ReminderText(measureHost, def)
                    holder:Hide()
                    host.items[key] = { def = def, holder = holder, frame = f, measure = measure }
                end
            end
        end
        local note = host:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        note:SetJustifyH("LEFT")
        note:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        host.note = note
    end,

    refresh = function(col, host)
        local room = host:GetWidth()
        if room <= 0 then return end
        local s = BH.settings or {}
        local sel = BH.textReminderPages and BH.textReminderPages.GetSelected
            and BH.textReminderPages.GetSelected() or "class"
        local keys = REMINDERS_ON_TAB[sel] or {}

        for _, item in pairs(host.items) do item.holder:Hide() end

        -- One fit for the whole tab, so their sizes stay true to each other.
        local widest = 0
        for _, key in ipairs(keys) do
            local item = host.items[key]
            if item then
                widest = math.max(widest, ReminderWidth(item) * (s[key .. "ReminderScale"] or 1))
            end
        end
        local fit = (widest > room) and (room / widest) or 1

        local y = 0
        for _, key in ipairs(keys) do
            local item = host.items[key]
            if item then
                local def = item.def
                local scale = (s[key .. "ReminderScale"] or 1) * fit
                local enabledKey = def.enabledKey or (key .. "ReminderEnabled")
                item.frame:SetScale(math.max(0.01, scale))
                item.frame:SetAlpha(s[enabledKey] == false and 0.3 or 1)
                item.holder:SetSize(ReminderWidth(item) * scale, def.size[2] * scale)
                item.holder:ClearAllPoints()
                item.holder:SetPoint("TOP", host, "TOP", 0, -y)
                item.holder:Show()
                y = y + def.size[2] * scale + 6
            end
        end

        local text = NOTHING_ON_SCREEN[sel]
            or ("At their Scale" .. (fit < 1 and ", shrunk together to fit" or "")
                .. ". A faded one is turned off. Unlock Frames moves them.")
        host.note:SetWidth(room)
        host.note:ClearAllPoints()
        host.note:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -(y + (y > 0 and 6 or 0)))
        host.note:SetText(text)
        host:SetHeight(y + host.note:GetStringHeight() + 20)
    end,
}

-- ----------------------------------------------------------------------------
-- Live frames (Raid Tools, Callouts)
-- ----------------------------------------------------------------------------

-- Everything these pages set up is already a frame on the screen -- the
-- marker panel's secure buttons, pull / ready, the battle res counter, the
-- distance readout, the callout buttons -- and Unlock Frames already shows
-- every one of them where it sits, with sample content. A second drawing of
-- them here would be a copy of a 430-line secure builder, and phase 3's one
-- Edit Mode replaces that unlock view anyway; so the column says so and puts
-- the switch next to the settings.
local LIVE_TEXT = {
    raidtools = "The marker panel, pull and ready check, battle res counter and target distance are "
        .. "live frames on your screen. Show them to see every change here as you make it, and to "
        .. "move them. This window stays open; drag it aside if it covers one.",
    callouts = "The callout buttons are a live frame on your screen. Show it to see every change here "
        .. "as you make it, and to move it. This window stays open; drag it aside if it covers it.",
}

local function NewLiveDrawer(kind)
    return {
        build = function(col, host)
            local text = host:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
            text:SetPoint("RIGHT", host, "RIGHT", 0, 0)
            text:SetJustifyH("LEFT")
            text:SetSpacing(3)
            text:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])
            text:SetText(LIVE_TEXT[kind])
            host.text = text

            local btn = ns.CreateSQButton(host, "Show them on screen", 160, 24)
            btn:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -12)
            -- Keeps the options window open: the point is to change settings
            -- while watching the frames.
            btn:SetScript("OnClick", function() BH:SetUnlockMode(not BH.unlockMode, true) end)
            host.btn = btn
            host:SetHeight(140)
        end,
        refresh = function(col, host)
            host.btn:SetText(BH.unlockMode and "Done" or "Show them on screen")
        end,
    }
end
drawers.raidtools = NewLiveDrawer("raidtools")
drawers.callouts  = NewLiveDrawer("callouts")

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
