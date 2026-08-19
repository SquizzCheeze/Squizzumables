-- UI/Rows.lua
-- Declarative option rows.
--
-- The options panel used to be built imperatively: create a widget, position it
-- with hand-tracked yOffset arithmetic, stash it on BH under a unique name, and
-- then remember to add a matching line to that tab's Refresh function to push
-- the current value back into it. Ten tabs of that produced ~700 lines of
-- boilerplate, 34 stored widget handles, and three Refresh functions that had
-- to be kept in sync by hand -- a setting whose Refresh line was forgotten
-- simply showed a stale value after a profile switch, silently.
--
-- Here a row is data instead. It declares how to read and write its value, so:
--
--   * it positions itself and reports the height it used, so callers never do
--     yOffset arithmetic
--   * it can refresh itself, so the per-tab Refresh functions and the stored
--     widget handles both disappear
--   * it can grey itself out when a `disabled` predicate says so, which the old
--     code had no mechanism for at all
--   * it registers itself for search, so every option is findable by name
--
-- Usage:
--     local y = 0
--     y = y - Rows.Add(content, y, {
--         type = "check",
--         label = "Enable Beacon Reminder",
--         tooltip = "Shows a reminder when your beacon is missing.",
--         get = function() return BH.settings.beaconReminderEnabled ~= false end,
--         set = function(v) BH.settings.beaconReminderEnabled = v end,
--     })

local addonName, ns = ...

local Rows = {}
ns.Rows = Rows

local SQ_COLORS        = ns.SQ_COLORS
local CreateSQCheckbox = ns.CreateSQCheckbox
local CreateSQSlider   = ns.CreateSQSlider
local CreateSQDropdown = ns.CreateSQDropdown
local CreateSQButton   = ns.CreateSQButton
local CreateSQDivider  = ns.CreateSQDivider

-- Layout constants. Every row reports its own height from here, so changing a
-- spacing value re-flows the whole panel instead of requiring 200 edits.
local ROW_H = {
    check   = 34,
    slider  = 50,
    dropdown= 34,
    button  = 36,
    header  = 22,
    divider = 18,
    spacer  = 14,
    text    = 28,
}
Rows.HEIGHTS = ROW_H

local LEFT_PAD = 14

-- ============================================================================
-- Refresh registry
--
-- Each row registers a closure that pushes the current stored value back into
-- the widget. Rows.RefreshAll() runs them all, which is what a profile switch
-- needs. This replaces BH:RefreshSettingsTab, BH:RefreshRaidToolsTab and
-- BH:RefreshTextRemindersTab, each of which was a hand-maintained if-chain.
-- ============================================================================

local refreshers = {}

function Rows.RegisterRefresh(fn)
    if type(fn) == "function" then
        refreshers[#refreshers + 1] = fn
    end
end

function Rows.RefreshAll()
    for i = 1, #refreshers do
        local ok, err = pcall(refreshers[i])
        -- A single broken row must not stop the rest of the panel refreshing.
        if not ok then
            geterrorhandler()(err)
        end
    end
end

-- ============================================================================
-- Search index
--
-- Rows register their label and tooltip as they are built. The search UI reads
-- this to offer jump-to-setting. Kept deliberately dumb -- just a flat list --
-- because the whole panel is only ~100 rows.
-- ============================================================================

local searchIndex = {}
Rows.searchIndex = searchIndex

-- Set by the panel while it builds a page, so rows know where they live without
-- every call site having to pass it. Holds the page descriptor
-- { key, label, frame, build } -- key to switch to it, label to name it in
-- results. nil outside a build pass, which is what stops stray widgets built
-- later from being indexed against the wrong category.
Rows.currentPage    = nil
Rows.currentSection = nil

function Rows.RegisterSearchEntry(label, tooltip, frame)
    if not label or label == "" or not Rows.currentPage then return end
    searchIndex[#searchIndex + 1] = {
        label   = label,
        tooltip = tooltip,
        page    = Rows.currentPage,
        section = Rows.currentSection,
        frame   = frame,
    }
end

function Rows.ClearSearchIndex()
    wipe(searchIndex)
end

-- ============================================================================
-- Shared behaviour
-- ============================================================================

-- The checkbox, slider and dropdown constructors return a container Frame whose
-- interactive part is a child (container.checkbox / .slider / .btn). The
-- container itself has no mouse enabled, so tooltips and disabling have to be
-- applied to that child or they do nothing at all. Buttons are their own
-- interactive widget, so they are returned as-is.
local function InteractiveOf(widget)
    return widget.checkbox or widget.slider or widget.btn or widget
end

local function AttachTooltip(widget, label, tooltip)
    if not tooltip then return end
    local target = InteractiveOf(widget)
    if not target.HookScript then return end
    -- HookScript rather than SetScript: the widget constructors already install
    -- their own OnEnter for hover highlighting, and replacing it would break it.
    target:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label or "")
        GameTooltip:AddLine(tooltip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    target:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- ----------------------------------------------------------------------------
-- Bridge for tabs not yet migrated to declarative rows.
--
-- Those tabs build their widgets imperatively, so they get none of a row's
-- behaviour for free. Two pieces of it are worth having without a full
-- migration, because they are what the settings search and the tooltips need:
--
--   * search indexing, which the CreateSQ* constructors now do automatically
--     using the label they are already given -- no call site has to change
--   * a tooltip, which needs text that only exists where the option is written,
--     so it is added explicitly with Rows.AddTooltip
--
-- A tab that is later migrated to Rows.Add gets both from the row spec and
-- these calls come out again.
-- ----------------------------------------------------------------------------

-- Attach a tooltip to an already-built widget.
function Rows.AddTooltip(widget, label, tooltip)
    if widget and tooltip then
        AttachTooltip(widget, label, tooltip)
        -- Re-index with the tooltip text so search can match on it too.
        for i = 1, #searchIndex do
            if searchIndex[i].frame == widget then
                searchIndex[i].tooltip = tooltip
                return widget
            end
        end
    end
    return widget
end

-- Grey out and stop interaction when spec.disabled() is true. Re-evaluated on
-- every refresh, so a row can depend on another row's value.
local function ApplyDisabled(widget, spec)
    if not spec.disabled then return end
    local isDisabled = spec.disabled() and true or false
    -- Alpha on the container so the label dims with the control.
    if widget.SetAlpha then widget:SetAlpha(isDisabled and 0.35 or 1) end
    local target = InteractiveOf(widget)
    if target.EnableMouse then target:EnableMouse(not isDisabled) end
    if target.SetEnabled then target:SetEnabled(not isDisabled) end
end

-- Wire a row: position it, attach the tooltip, index it for search, and
-- register the closure that syncs widget <- stored value.
local function Finish(widget, parent, y, spec, sync)
    widget:SetPoint("TOPLEFT", parent, "TOPLEFT", spec.indent or LEFT_PAD, y)
    AttachTooltip(widget, spec.label, spec.tooltip)
    Rows.RegisterSearchEntry(spec.label, spec.tooltip, widget)
    local function refresh()
        if sync then sync() end
        ApplyDisabled(widget, spec)
    end
    Rows.RegisterRefresh(refresh)
    refresh()
    widget.sqRefresh = refresh
    return widget
end

-- ============================================================================
-- Row types
-- ============================================================================

local builders = {}

builders.check = function(parent, y, spec)
    local cb = CreateSQCheckbox(parent, spec.label, function(checked)
        if spec.set then spec.set(checked and true or false) end
        if spec.after then spec.after() end
        -- Other rows may depend on this one.
        Rows.RefreshAll()
    end)
    return Finish(cb, parent, y, spec, function()
        if spec.get then cb:SetChecked(spec.get() and true or false) end
    end)
end

builders.slider = function(parent, y, spec)
    local s = CreateSQSlider(parent, spec.label, spec.width or 300,
                             spec.min or 0, spec.max or 100, spec.step or 1)
    s:SetAfterValueChanged(function(value, userInput)
        if spec.set then spec.set(value, userInput) end
        if spec.after then spec.after(value, userInput) end
    end)
    return Finish(s, parent, y, spec, function()
        if spec.get then s:SetValue(spec.get()) end
    end)
end

builders.dropdown = function(parent, y, spec)
    local items = spec.items
    if type(items) == "function" then items = items() end
    local dd = CreateSQDropdown(parent, spec.label or "", spec.width or 220, items or {}, function(value)
        if spec.set then spec.set(value) end
        if spec.after then spec.after(value) end
        Rows.RefreshAll()
    end)
    return Finish(dd, parent, y, spec, function()
        if spec.get then dd:SetSelectedValue(spec.get()) end
    end)
end

builders.button = function(parent, y, spec)
    local b = CreateSQButton(parent, spec.label, spec.width or 140, spec.height or 26, spec.color)
    b:SetScript("OnClick", function()
        if spec.onClick then spec.onClick() end
    end)
    return Finish(b, parent, y, spec, nil)
end

-- A section title. Indexed for search too, so "reminders" finds the section.
builders.header = function(parent, y, spec)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", spec.indent or LEFT_PAD, y)
    fs:SetText(spec.label)
    ns.ApplyAccent(fs, "text")
    Rows.RegisterSearchEntry(spec.label, spec.tooltip, fs)
    return fs
end

-- Explanatory paragraph under a header.
builders.text = function(parent, y, spec)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", spec.indent or LEFT_PAD, y)
    fs:SetWidth(spec.width or 380)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetText(spec.label)
    fs:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    return fs
end

builders.divider = function(parent, y, spec)
    return CreateSQDivider(parent, y)
end

builders.spacer = function() return nil end

-- Add one row. Returns the height it consumed, so callers advance by that
-- rather than tracking magic numbers:  y = y - Rows.Add(content, y, spec)
function Rows.Add(parent, y, spec)
    local build = builders[spec.type]
    if not build then
        geterrorhandler()("Squizzumables: unknown option row type '" .. tostring(spec.type) .. "'")
        return 0
    end
    build(parent, y, spec)
    return spec.height and (spec.height + 8) or (ROW_H[spec.type] or 30)
end

-- Add a list of rows in order, returning the total height consumed.
function Rows.AddAll(parent, y, specs)
    local used = 0
    for i = 1, #specs do
        local spec = specs[i]
        -- A spec may be conditional: skip it entirely when `shown` says no.
        if not spec.shown or spec.shown() then
            used = used + Rows.Add(parent, y - used, spec)
        end
    end
    return used
end

-- ============================================================================
-- Settings search
--
-- With ~100 options spread over ten categories, finding one by memory is the
-- slowest part of using the panel. Every option widget registers its label as
-- it is built (see IndexForSearch in UI/Widgets.lua), so all this needs is
-- scoring and a way to jump to the result.
-- ============================================================================

-- Subsequence match with a substring boost. Cheap enough to run over the whole
-- index on every keystroke -- no need for anything cleverer at this size.
--
-- Returns a score (higher is better) or nil for no match.
function Rows.FuzzyScore(haystack, needle)
    if not haystack or not needle or needle == "" then return nil end
    haystack, needle = haystack:lower(), needle:lower()

    -- An exact substring always beats a scattered subsequence, and an earlier
    -- one beats a later one.
    local at = haystack:find(needle, 1, true)
    if at then return 10000 - at end

    local hLen, nLen = #haystack, #needle
    local hi, ni = 1, 1
    local firstMatch, lastMatch, run, score = nil, nil, 0, 0
    while hi <= hLen and ni <= nLen do
        if haystack:byte(hi) == needle:byte(ni) then
            firstMatch = firstMatch or hi
            lastMatch = hi
            run = run + 1
            score = score + run     -- reward tight clusters: a run of k scores 1+2+..+k
            ni = ni + 1
        else
            run = 0
        end
        hi = hi + 1
    end
    if ni <= nLen then return nil end       -- not every character found, in order

    -- Reject matches so scattered they are noise. Without this, a long enough
    -- label makes almost any short query findable somewhere inside it. The
    -- slack keeps genuine abbreviations alive.
    if (lastMatch - firstMatch + 1) > nLen + 8 then return nil end
    return score
end

-- Best matches for a query, ordered. Searches the option label first and falls
-- back to the tooltip text, so "durability" finds the repair threshold even
-- though the word is not in its label.
function Rows.Search(query, maxResults)
    local results = {}
    if not query or query:match("^%s*$") then return results end
    query = query:match("^%s*(.-)%s*$")

    for i = 1, #searchIndex do
        local entry = searchIndex[i]
        local score = Rows.FuzzyScore(entry.label, query)
        if not score and entry.tooltip then
            local tipScore = Rows.FuzzyScore(entry.tooltip, query)
            -- A tooltip hit is a weaker signal than a label hit, so it always
            -- sorts below one.
            if tipScore then score = tipScore - 20000 end
        end
        if score then
            results[#results + 1] = { entry = entry, score = score }
        end
    end

    table.sort(results, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return (a.entry.label or "") < (b.entry.label or "")
    end)

    if maxResults and #results > maxResults then
        for i = #results, maxResults + 1, -1 do results[i] = nil end
    end
    return results
end

-- Scroll a row into view inside whatever scroll frame contains it.
local function ScrollIntoView(frame)
    if not frame or not frame.GetParent then return end
    -- Walk up until the parent is a ScrollFrame; the frame we are holding at
    -- that point is the scroll child, which is what offsets are measured from.
    local child, parent = frame, frame:GetParent()
    while parent do
        if parent.GetObjectType and parent:GetObjectType() == "ScrollFrame" then
            local childTop, frameTop = child:GetTop(), frame:GetTop()
            if childTop and frameTop then
                local range = parent:GetVerticalScrollRange() or 0
                -- Leave a little headroom so the row is not flush to the edge.
                local target = math.max(0, math.min(childTop - frameTop - 40, range))
                parent:SetVerticalScroll(target)
            end
            return
        end
        child, parent = parent, parent:GetParent()
    end
end

-- Briefly highlight a row so the eye can find it after a jump.
local function FlashRow(frame)
    if not frame or not frame.CreateTexture then return end
    local glow = frame.sqSearchGlow
    if not glow then
        glow = frame:CreateTexture(nil, "BACKGROUND")
        glow:SetPoint("TOPLEFT", frame, "TOPLEFT", -4, 2)
        glow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 4, -2)
        frame.sqSearchGlow = glow

        local anim = glow:CreateAnimationGroup()
        local fade = anim:CreateAnimation("Alpha")
        fade:SetFromAlpha(0.55)
        fade:SetToAlpha(0)
        fade:SetDuration(1.6)
        anim:SetScript("OnFinished", function() glow:Hide() end)
        glow.anim = anim
    end
    local r, g, b = ns.GetAccentColor()
    glow:SetColorTexture(r, g, b, 0.55)
    glow:Show()
    glow.anim:Stop()
    glow.anim:Play()
end

-- Switch to a result's category, scroll to it and flash it.
function Rows.JumpTo(entry)
    if not entry then return end
    local BH = ns.BH
    if entry.page and entry.page.key and BH and BH.switchTab then
        BH.switchTab(entry.page.key)
    end
    -- One frame later: the page has to be shown before its scroll geometry and
    -- the row's position are meaningful.
    C_Timer.After(0, function()
        ScrollIntoView(entry.frame)
        FlashRow(entry.frame)
    end)
end
