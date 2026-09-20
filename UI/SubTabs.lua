-- UI/SubTabs.lua
-- A second level of tabs, inside one page of the options panel.
--
-- Some pages have outgrown a single scroll. Raid Tools carried six unrelated
-- sections stacked end to end -- module toggle, frames, pull timer, scale,
-- battle res, target distance, position -- so finding one meant scrolling past
-- five others, and every feature added to it made the rest harder to reach.
-- Splitting a page into sub-tabs keeps each one to a screenful.
--
-- Deliberately NOT a second copy of the main nav. The sidebar is vertical with
-- an accent bar down the left edge; these are horizontal with an underline, so
-- at a glance it is obvious which level of the hierarchy a control belongs to.
--
-- Usage, from a tab builder:
--
--     local pages = ns.SubTabs.Create(parent, {
--         { key = "frames", label = "Frames" },
--         { key = "pull",   label = "Pull Timer" },
--     })
--
--     local y = -14
--     y = y - ns.Rows.Add(pages.frames, y, { … })
--
-- `pages.<key>` is the scroll child for that sub-tab, so the row calls are
-- unchanged apart from which frame they are given. Each page also carries a
-- `section` descriptor, which the builder assigns to ns.Rows.currentSection so
-- search results know which sub-tab a hit lives on and can switch to it --
-- otherwise searching would land on the right page with the row hidden behind
-- an unselected sub-tab, which looks exactly like the search being broken.

local addonName, ns = ...

local SubTabs = {}
ns.SubTabs = SubTabs

local SQ_COLORS = ns.SQ_COLORS

local STRIP_H      = 26   -- height of one row of sub-tab buttons
local BTN_H        = 22
local BTN_PAD_X    = 12   -- padding either side of the label
local BTN_GAP      = 4
local STRIP_INSET  = 12   -- left inset, lining the strip up with row labels

--- Build a sub-tab strip and one PLAIN page per entry, inside a page that is
--- already scrolling.
---
--- The difference from Create is the absence of a ScrollFrame, and that is the
--- whole reason this exists: a third level of tabs is wanted on pages that are
--- themselves scroll children, and a ScrollFrame inside a ScrollFrame scrolls
--- badly and swallows the wheel. So these pages are plain frames that are
--- shown and hidden, and the HOST's height follows whichever is showing --
--- the outer scroller then scrolls exactly the visible section rather than the
--- sum of all of them.
---
--- `host` is the frame to build into, `startY` the offset to put the strip at
--- (so a caller can leave a header above it), and `opts.initial` the key to
--- open on -- pass the previously selected one, because a rebuild reparents
--- everything here and the selection would otherwise snap back to the first
--- tab every time any setting changed.
---
--- `opts.section` is the host page's own search descriptor. Each page gets a
--- descriptor of its own that selects the outer sub-tab AND this inner one, so
--- a search hit still lands on something visible.
---
--- Returns a table mapping each key to its page frame, plus `Select(key)`,
--- `GetSelected()` and `SetPageHeight(key, height)` -- call that last one after
--- filling a page, or the host cannot know how tall to be.
function SubTabs.CreateInline(host, defs, startY, opts)
    opts = opts or {}
    local pages, buttons = {}, {}
    local heights = {}
    local selectedKey
    local headerY = math.abs(startY or 0)

    local strip = CreateFrame("Frame", nil, host)
    strip:SetPoint("TOPLEFT", host, "TOPLEFT", 0, startY or 0)
    strip:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, startY or 0)
    strip:SetHeight(STRIP_H)

    local underline = strip:CreateTexture(nil, "ARTWORK")
    underline:SetHeight(1)
    underline:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", 0, 0)
    underline:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT", -10, 0)
    underline:SetColorTexture(SQ_COLORS.border[1], SQ_COLORS.border[2],
                              SQ_COLORS.border[3], 0.5)

    local function ApplyHeight()
        local h = heights[selectedKey] or 0
        host:SetHeight(headerY + STRIP_H + 4 + h + 20)
    end

    local function Select(key)
        selectedKey = key
        for _, def in ipairs(defs) do
            local on = (def.key == key)
            if buttons[def.key] then buttons[def.key]:SetActive(on) end
            if pages[def.key] then pages[def.key]:SetShown(on) end
        end
        ApplyHeight()
    end

    local x, rows = STRIP_INSET, 1
    local availW = 600

    for _, def in ipairs(defs) do
        local btn = CreateFrame("Button", nil, strip, "BackdropTemplate")
        btn:SetHeight(BTN_H)
        btn:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
        btn:SetBackdropColor(0, 0, 0, 0)

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("CENTER", btn, "CENTER", 0, 0)
        label:SetText(def.label or def.key)
        btn.label = label

        local w = math.ceil(label:GetStringWidth()) + BTN_PAD_X * 2
        btn:SetWidth(w)

        if x > STRIP_INSET and (x + w) > availW then
            rows = rows + 1
            x = STRIP_INSET
        end
        btn:SetPoint("TOPLEFT", strip, "TOPLEFT", x, -((rows - 1) * STRIP_H) - 2)
        x = x + w + BTN_GAP

        local marker = btn:CreateTexture(nil, "OVERLAY")
        marker:SetHeight(2)
        marker:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 2, -2)
        marker:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, -2)
        ns.ApplyAccent(marker, "texture", 1)
        marker:Hide()
        btn.marker = marker

        btn:SetScript("OnEnter", function(self)
            if not self.isActive then
                self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2],
                                      SQ_COLORS.controlHi[3], 0.5)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if not self.isActive then self:SetBackdropColor(0, 0, 0, 0) end
        end)

        btn.SetActive = function(self, active)
            self.isActive = active
            if active then
                self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2],
                                      SQ_COLORS.controlHi[3], 0.35)
                self.label:SetTextColor(SQ_COLORS.textBright[1], SQ_COLORS.textBright[2],
                                        SQ_COLORS.textBright[3])
                self.marker:Show()
            else
                self:SetBackdropColor(0, 0, 0, 0)
                self.label:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2],
                                        SQ_COLORS.textDim[3])
                self.marker:Hide()
            end
        end

        btn:SetScript("OnClick", function()
            Select(def.key)
            if opts.onSelect then opts.onSelect(def.key) end
        end)
        buttons[def.key] = btn
    end

    strip:SetHeight(rows * STRIP_H)

    for _, def in ipairs(defs) do
        local page = CreateFrame("Frame", nil, host)
        page:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -4)
        page:SetPoint("TOPRIGHT", strip, "BOTTOMRIGHT", 0, -4)
        page:SetHeight(1)
        page:Hide()

        -- Selecting this page means selecting the tab it lives on too, or a
        -- search hit lands on a page whose own parent tab is not showing.
        local outer = opts.section
        page.section = {
            key    = (outer and outer.key or "") .. "/" .. def.key,
            label  = (outer and (outer.label .. " - ") or "") .. (def.label or def.key),
            select = function()
                if outer and outer.select then outer.select() end
                Select(def.key)
                if opts.onSelect then opts.onSelect(def.key) end
            end,
        }

        pages[def.key] = page
    end

    pages.Select = Select
    pages.GetSelected = function() return selectedKey end
    pages.SetPageHeight = function(key, h)
        heights[key] = h or 0
        if key == selectedKey then ApplyHeight() end
    end

    local want = opts.initial
    if not (want and pages[want]) then want = defs[1] and defs[1].key end
    if want then Select(want) end

    return pages
end

--- Build a sub-tab strip and one scrolling page per entry.
---
--- `defs` is an ordered list of { key, label }. Returns a table mapping each
--- key to its scroll-child frame, plus `Select(key)` and `GetSelected()`.
function SubTabs.Create(parent, defs)
    local pages = {}
    local buttons = {}

    local strip = CreateFrame("Frame", nil, parent)
    strip:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    strip:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    strip:SetHeight(STRIP_H)

    local underline = strip:CreateTexture(nil, "ARTWORK")
    underline:SetHeight(1)
    underline:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", 0, 0)
    underline:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT", 0, 0)
    underline:SetColorTexture(SQ_COLORS.border[1], SQ_COLORS.border[2],
                              SQ_COLORS.border[3], 0.5)

    local selectedKey

    local function Select(key)
        selectedKey = key
        for _, def in ipairs(defs) do
            local on = (def.key == key)
            local btn = buttons[def.key]
            if btn then btn:SetActive(on) end
            local page = pages[def.key]
            -- The scroller, not the scroll child: hiding the child leaves the
            -- scroll frame showing an empty region that still takes the mouse
            -- wheel.
            if page and page.scroller then
                page.scroller:SetShown(on)
            end
        end
    end

    -- Lay the buttons out left to right, wrapping when the strip runs out.
    --
    -- Width comes from the rendered label rather than a fixed number, so a
    -- long sub-tab name is not clipped and a short one does not leave a gap.
    -- The strip grows a row at a time, and the pages start below whatever
    -- height it ended up at.
    local x, rows = STRIP_INSET, 1
    local availW = 620   -- content area is ~638 wide; leave room for the inset

    for _, def in ipairs(defs) do
        local btn = CreateFrame("Button", nil, strip, "BackdropTemplate")
        btn:SetHeight(BTN_H)
        btn:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
        btn:SetBackdropColor(0, 0, 0, 0)

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("CENTER", btn, "CENTER", 0, 0)
        label:SetText(def.label or def.key)
        btn.label = label

        local w = math.ceil(label:GetStringWidth()) + BTN_PAD_X * 2
        btn:SetWidth(w)

        if x > STRIP_INSET and (x + w) > availW then
            rows = rows + 1
            x = STRIP_INSET
        end
        btn:SetPoint("TOPLEFT", strip, "TOPLEFT", x, -((rows - 1) * STRIP_H) - 2)
        x = x + w + BTN_GAP

        local marker = btn:CreateTexture(nil, "OVERLAY")
        marker:SetHeight(2)
        marker:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 2, -2)
        marker:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, -2)
        ns.ApplyAccent(marker, "texture", 1)
        marker:Hide()
        btn.marker = marker

        btn:SetScript("OnEnter", function(self)
            if not self.isActive then
                self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2],
                                      SQ_COLORS.controlHi[3], 0.5)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if not self.isActive then self:SetBackdropColor(0, 0, 0, 0) end
        end)

        btn.SetActive = function(self, active)
            self.isActive = active
            if active then
                self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2],
                                      SQ_COLORS.controlHi[3], 0.35)
                self.label:SetTextColor(SQ_COLORS.textBright[1], SQ_COLORS.textBright[2],
                                        SQ_COLORS.textBright[3])
                self.marker:Show()
            else
                self:SetBackdropColor(0, 0, 0, 0)
                self.label:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2],
                                        SQ_COLORS.textDim[3])
                self.marker:Hide()
            end
        end

        btn:SetScript("OnClick", function() Select(def.key) end)
        buttons[def.key] = btn
    end

    strip:SetHeight(rows * STRIP_H)

    -- One scroller per sub-tab, all filling the area below the strip.
    for _, def in ipairs(defs) do
        local scroller = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
        ns.TuneScrollStep(scroller)
        scroller:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -4)
        scroller:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)
        scroller:Hide()

        local content = CreateFrame("Frame", nil, scroller)
        content:SetWidth(400)
        content:SetHeight(1)
        scroller:SetScrollChild(content)

        content.scroller = scroller

        -- What search needs to reach a row on this sub-tab: a label to show in
        -- the result, and a way to bring the sub-tab to the front. Held as a
        -- closure so Rows never has to know this file exists.
        content.section = {
            key    = def.key,
            label  = def.label or def.key,
            select = function() Select(def.key) end,
        }

        pages[def.key] = content
    end

    pages.Select = Select
    pages.GetSelected = function() return selectedKey end

    if defs[1] then Select(defs[1].key) end

    return pages
end
