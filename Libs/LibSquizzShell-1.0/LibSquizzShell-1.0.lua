--[[ LibSquizzShell-1.0

    The options window shared by SquizzFrames and Squizzumables (SquizzFrames
    2.0, phase 3). Each addon embeds a copy; LibStub runs the newest. Change
    both copies byte-identically AND bump MINOR, or the two addons silently run
    whichever copy loaded first (same rule as LibSquizzGrid / LibSquizzTheme).

    WHAT IT DRAWS
      A movable, resizable window in the shared theme (LibSquizzTheme-1.0): a
      title bar (name, search box, the owner's buttons, close), a sidebar of
      named groups, a page header (title and subtitle) and the page itself.

    ADDONS AND WINDOWS ARE SEPARATE
      An addon REGISTERS its pages once:
          lib:RegisterAddon("SquizzFrames", { title = "SquizzFrames", groups = {
              { label = "Frames", pages = {
                  { key = "layout", label = "Party and Raid",
                    subtitle = "Size, growth and look of the group frames",
                    layout = "scroll", height = 1615,   -- or layout = "fill"
                    build = function(host) ... end,      -- once, into `host`
                    onShow = function(host) end,         -- optional, every show
                    onResize = function(host) end },     -- optional, after a resize
              } },
          } })
      A WINDOW shows one or more registered addons:
          local win = lib:CreateWindow({ name = "SquizzFramesOptionsFrame",
              addons = { "SquizzFrames" }, title = "SQUIZZFRAMES", ... })
      A page is built ONCE, the first time any window shows it, and is moved
      (reparented) into whichever window shows it next. So the combined window
      and an addon's own window share one copy of every page and its state.
      With more than one addon, the sidebar gets one titled section per addon.

    SEARCH
      Every page is findable by its label. An addon adds settings to the index
      with lib:AddSearchEntry(addonId, { label, tip, page, path, onSelect });
      a window searches the addons it shows.

    RULES
      * Build pages lazily: nothing is built until a window first shows it.
      * Colours are read from LibSquizzTheme when each region is made; only the
        accent (selected row, active title button) is re-read on change.
      * A "fill" page gets the whole content area and does its own scrolling;
        a "scroll" page is placed in a shared scroll frame at least `height`
        tall (taller if the window is).
]]

local MAJOR, MINOR = "LibSquizzShell-1.0", 4
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.addons = lib.addons or {}   -- [addonId] = spec
lib.order = lib.order or {}     -- addonIds in registration order
lib.index = lib.index or {}     -- [addonId] = { search entries }
lib.windows = lib.windows or {} -- [name] = window

local WHITE = "Interface\\Buttons\\WHITE8X8"
local FONT = "Fonts\\FRIZQT__.TTF"

-- Colours ------------------------------------------------------------------

-- Used only if LibSquizzTheme is missing: Squizz Gold's values.
local FALLBACK = {
    bg = { 0.06, 0.06, 0.08, 0.96 }, titleBar = { 0.10, 0.10, 0.13, 1 },
    border = { 0.25, 0.25, 0.30, 1 }, accent = { 0.78, 0.65, 0.30, 1 },
    text = { 0.90, 0.90, 0.90, 1 }, textDim = { 0.55, 0.55, 0.58, 1 },
    textBright = { 1, 1, 1, 1 }, control = { 0.14, 0.14, 0.17, 1 },
    controlHi = { 0.20, 0.20, 0.24, 1 }, danger = { 0.75, 0.25, 0.25, 1 },
    tabInactive = { 0.08, 0.08, 0.10, 1 },
}

local function Theme()
    return LibStub("LibSquizzTheme-1.0", true)
end

local function RGBA(key)
    local T = Theme()
    if T then return T:RGBA(key) end
    local c = FALLBACK[key] or { 1, 0, 1, 1 }
    return c[1], c[2], c[3], c[4] or 1
end

local function Accent()
    local T = Theme()
    if T and T.AccentRGB then return T:AccentRGB() end
    local c = FALLBACK.accent
    return c[1], c[2], c[3]
end

local function Backdrop(frame, bgKey, borderKey)
    frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    frame:SetBackdropColor(RGBA(bgKey))
    if borderKey then
        frame:SetBackdropBorderColor(RGBA(borderKey))
    else
        frame:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

local function Text(parent, size, colorKey, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(FONT, size or 12, "")
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.8)
    fs:SetTextColor(RGBA(colorKey or "text"))
    return fs
end

-- A flat themed button. btn:SetActive(on) lights it in the accent.
local function Button(parent, label, width, height)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width or 90, height or 22)
    Backdrop(b, "control", "border")
    b.text = Text(b, 11, "text")
    b.text:SetPoint("CENTER")
    b.text:SetText(label or "")
    function b:SetActive(on)
        self.active = on and true or false
        if self.active then
            local r, g, bb = Accent()
            self:SetBackdropColor(r, g, bb, 0.45)
            self.text:SetTextColor(RGBA("textBright"))
        else
            self:SetBackdropColor(RGBA("control"))
            self.text:SetTextColor(RGBA("text"))
        end
    end
    b:SetScript("OnEnter", function(self)
        if self.active then return end
        self:SetBackdropColor(RGBA("controlHi"))
    end)
    b:SetScript("OnLeave", function(self) self:SetActive(self.active) end)
    -- The label is our own FontString, so a caller's SetText (Squizzumables'
    -- "Unlock Frames" / "Lock Frames") is routed to it.
    function b:SetText(t) self.text:SetText(t or "") end
    return b
end

-- Registration ---------------------------------------------------------------

--- Register (or re-register) an addon's sidebar groups and pages.
-- Add an addon to lib.order once. Both RegisterAddon and RegisterOpener add
-- it, in either order -- checking only lib.addons let an addon whose opener
-- registered first be added twice, and the combined window listed it twice
-- (user screenshot 2026-10-17).
local function AddToOrder(addonId)
    for _, a in ipairs(lib.order) do
        if a == addonId then return end
    end
    lib.order[#lib.order + 1] = addonId
end

function lib:RegisterAddon(addonId, spec)
    AddToOrder(addonId)
    spec.id = addonId
    lib.addons[addonId] = spec
    spec.pageByKey = {}
    for _, group in ipairs(spec.groups or {}) do
        for _, page in ipairs(group.pages or {}) do
            page.addon = addonId
            page.group = group.label
            spec.pageByKey[page.key] = page
        end
    end
    lib.index[addonId] = lib.index[addonId] or {}
end

--- Add a search entry: { label, tip, page = pageKey, path = "Section > Row",
--- onSelect = function() end }. onSelect runs after the page is shown.
function lib:AddSearchEntry(addonId, entry)
    local list = lib.index[addonId]
    if not list then
        list = {}
        lib.index[addonId] = list
    end
    list[#list + 1] = entry
end

-- Control index ------------------------------------------------------------------
--
-- An addon's widget factories call these as they build a control, so every
-- setting on a page becomes searchable without being described a second time.
-- The owning page is found by walking up the control's parents to a page
-- frame, so it works whenever the control is made: the first build, and every
-- rebuild after (a profile switch rebuilds whole pages). A label seen again in
-- the same section re-points the existing entry at the new frame instead of
-- adding a duplicate. A page registered with autoIndex = false is skipped:
-- one that only builds the section on screen would index whichever section
-- happened to be built, and its entries could point at the wrong one.

lib.pageOfFrame = lib.pageOfFrame or setmetatable({}, { __mode = "k" })

local function OwningPage(frame)
    local f = frame
    for _ = 1, 40 do
        if not f then return nil end
        local page = lib.pageOfFrame[f]
        if page then return page end
        f = f.GetParent and f:GetParent()
    end
end

local function Clean(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

--- A section title on a page: controls made after it are filed under it.
function lib:IndexSection(frame, title)
    local page = OwningPage(frame)
    if page then page.lastSection = Clean(title) end
end

--- For a page that builds ONE of its sections at a time: call before building
--- a section. Controls made after it are filed under `key` (which also dedupes:
--- a control with the same key, section and label is one entry), shown under
--- `label` in results, and picking one calls the page spec's select(scope)
--- to bring that section back before scrolling to the control. Such a page
--- also gives indexAll(), which the window calls once to build every section.
function lib:SetIndexScope(frame, key, label, scope)
    local page = OwningPage(frame)
    if not page then return end
    page.scopeKey, page.scopeLabel, page.scope = key, Clean(label), scope
    page.lastSection = nil
end

--- A control on a page: searchable by its label (and tip), and the result
--- scrolls the page to it.
function lib:IndexControl(frame, label, tip)
    label = Clean(label)
    if not label then return end
    local page = OwningPage(frame)
    if not page or page.autoIndex == false then return end
    page.controls = page.controls or {}
    local key = (page.scopeKey or "") .. "\0" .. (page.lastSection or "") .. "\0" .. label
    local e = page.controls[key]
    if e then
        e.frame = frame
        return
    end
    local path = page.lastSection
    if page.scopeLabel then
        path = page.scopeLabel .. (path and (" > " .. path) or "")
    end
    e = { label = label, tip = Clean(tip), page = page.key, path = path, frame = frame,
          scope = page.scope }
    -- A frame later: the page was just shown (and its section rebuilt, which
    -- re-points e.frame), and the scroll range only catches up once the
    -- client has laid it out.
    e.onSelect = function(win)
        if e.scope ~= nil and page.select then page.select(e.scope) end
        if win then C_Timer.After(0, function() win:RevealControl(e.frame) end) end
    end
    page.controls[key] = e
    lib:AddSearchEntry(page.addon, e)
end

-- Window -----------------------------------------------------------------------

local Window = {}
Window.__index = Window

local SIDEBAR_W = 170
local TITLE_H = 32
local HEADER_H = 46
local ROW_H = 22
local MAX_RESULTS = 10

function lib:CreateWindow(opts)
    if opts.name and lib.windows[opts.name] then return lib.windows[opts.name] end
    local win = setmetatable({ opts = opts, rows = {}, buttons = {} }, Window)
    if opts.name then lib.windows[opts.name] = win end

    local f = CreateFrame("Frame", opts.name, UIParent, "BackdropTemplate")
    win.frame = f
    f:SetSize(opts.width or 900, opts.height or 620)
    f:SetPoint("CENTER")
    f:SetFrameStrata(opts.strata or "DIALOG")
    if opts.level then f:SetFrameLevel(opts.level) end
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetToplevel(true)
    f:EnableMouse(true)
    local minW, minH = opts.minWidth or 760, opts.minHeight or 480
    local maxW, maxH = opts.maxWidth or 1400, opts.maxHeight or 1000
    if f.SetResizeBounds then
        f:SetResizeBounds(minW, minH, maxW, maxH)
    elseif f.SetMinResize then
        f:SetMinResize(minW, minH)
        f:SetMaxResize(maxW, maxH)
    end
    Backdrop(f, "bg", "border")
    f:Hide()
    if opts.name then tinsert(UISpecialFrames, opts.name) end

    win:BuildTitleBar()
    win:BuildSidebar()
    win:BuildContent()
    win:BuildResizeGrip()
    win:BuildCombatHandling()

    f:SetScript("OnHide", function()
        if win.results then win.results:Hide() end
        if lib.OnWindowHidden then lib.OnWindowHidden(win) end
        if opts.onHide then opts.onHide(win) end
    end)
    return win
end

function Window:BuildTitleBar()
    local f, opts = self.frame, self.opts
    local bar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    bar:SetHeight(TITLE_H)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetBackdrop({ bgFile = WHITE })
    bar:SetBackdropColor(RGBA("titleBar"))
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() f:StartMoving() end)
    bar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    self.titleBar = bar

    local title = Text(bar, 13, "textBright")
    title:SetPoint("LEFT", 12, 0)
    title:SetText(opts.title or "")
    local sub = Text(bar, 11, "textDim")
    sub:SetPoint("LEFT", title, "RIGHT", 6, 0)
    sub:SetText(opts.subtitle or "Configuration")

    local line = bar:CreateTexture(nil, "ARTWORK")
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    line:SetHeight(1)
    self.accentLine = line

    local close = CreateFrame("Button", nil, bar)
    close:SetSize(TITLE_H, TITLE_H)
    close:SetPoint("RIGHT", -2, 0)
    local x = Text(close, 13, "textDim")
    x:SetPoint("CENTER")
    x:SetText("X")
    close:SetScript("OnEnter", function() x:SetTextColor(RGBA("danger")) end)
    close:SetScript("OnLeave", function() x:SetTextColor(RGBA("textDim")) end)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Search box, left of close.
    local box = CreateFrame("EditBox", nil, bar, "BackdropTemplate")
    box:SetSize(190, 20)
    box:SetPoint("RIGHT", close, "LEFT", -6, 0)
    Backdrop(box, "control", "border")
    box:SetFont(FONT, 11, "")
    box:SetTextColor(RGBA("text"))
    box:SetTextInsets(6, 6, 0, 0)
    box:SetAutoFocus(false)
    box:SetMaxLetters(40)
    local hint = Text(box, 11, "textDim")
    hint:SetPoint("LEFT", 6, 0)
    hint:SetText("Search settings...")
    box:SetScript("OnEditFocusGained", function() hint:Hide() end)
    box:SetScript("OnEditFocusLost", function(b) if b:GetText() == "" then hint:Show() end end)
    box:SetScript("OnEscapePressed", function(b)
        b:SetText("")
        b:ClearFocus()
        self.results:Hide()
    end)
    box:SetScript("OnTextChanged", function(b) self:UpdateSearch(b:GetText()) end)
    box:SetScript("OnEnterPressed", function(b)
        local first = self.resultRows[1]
        if self.results:IsShown() and first and first:IsShown() then first:Click() end
        b:ClearFocus()
    end)
    self.searchBox = box
    self:BuildResults()

    -- The owner's buttons, right to left from the search box.
    local anchor = box
    for i, spec in ipairs(opts.buttons or {}) do
        local b = Button(bar, spec.label, spec.width or 96, 22)
        b:SetPoint("RIGHT", anchor, "LEFT", -8, 0)
        b:SetScript("OnClick", function(btn) if spec.onClick then spec.onClick(btn, self) end end)
        if spec.tip then
            b:HookScript("OnEnter", function(btn)
                GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
                GameTooltip:SetText(spec.label, 1, 1, 1)
                GameTooltip:AddLine(spec.tip, nil, nil, nil, true)
                GameTooltip:Show()
            end)
            b:HookScript("OnLeave", function() GameTooltip:Hide() end)
        end
        b:SetActive(false)
        self.buttons[spec.key or i] = b
        anchor = b
    end
end

function Window:BuildResults()
    local panel = CreateFrame("Frame", nil, self.frame, "BackdropTemplate")
    panel:SetPoint("TOPRIGHT", self.searchBox, "BOTTOMRIGHT", 0, -4)
    panel:SetWidth(320)
    -- A strata above the window, not just a higher level: pages pin their own
    -- furniture high in the window's strata (Unit Frames' tab strip and
    -- preview sit 50+ levels up, their mocks higher still), and the list was
    -- drawn under them (user screenshot 2026-10-17).
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    Backdrop(panel, "bg", "border")
    panel:Hide()
    self.results = panel
    self.resultRows = {}
    for i = 1, MAX_RESULTS do
        local row = CreateFrame("Button", nil, panel, "BackdropTemplate")
        row:SetHeight(32)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 32)
        row:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * 32)
        row:SetBackdrop({ bgFile = WHITE })
        row:SetBackdropColor(0, 0, 0, 0)
        row.label = Text(row, 12, "text")
        row.label:SetPoint("TOPLEFT", 6, -3)
        row.label:SetPoint("RIGHT", -6, 0)
        row.label:SetJustifyH("LEFT")
        row.path = Text(row, 10, "textDim")
        row.path:SetPoint("BOTTOMLEFT", 6, 3)
        row.path:SetPoint("RIGHT", -6, 0)
        row.path:SetJustifyH("LEFT")
        row:SetScript("OnEnter", function(r)
            local cr, cg, cb = Accent()
            r:SetBackdropColor(cr, cg, cb, 0.25)
        end)
        row:SetScript("OnLeave", function(r) r:SetBackdropColor(0, 0, 0, 0) end)
        row:SetScript("OnClick", function(r)
            panel:Hide()
            self.searchBox:SetText("")
            self.searchBox:ClearFocus()
            local e = r.entry
            if not e then return end
            if not self:OwnsAddon(e.addon) then
                -- Another addon's setting (combined mode): its window takes over.
                lib:HandOff(self, e.addon, e.page, e.onSelect)
                return
            end
            self:ShowPage(e.addon .. ":" .. e.page)
            if e.onSelect then e.onSelect(self) end
        end)
        row:Hide()
        self.resultRows[i] = row
    end
end

-- Search the addons this window shows. Label matches rank first, then matches
-- on the section a control sits under (the Frame Opacity sliders are labelled
-- "Party Frames", "Raid Frames"..., so "opacity" only matches their section --
-- user report 2026-10-17), then tip matches.
function Window:Search(query)
    query = (query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then return {} end
    local strong, mid, weak = {}, {}, {}
    -- This window's addons, and while combined every other addon with an
    -- opener: a result from one of those hands over to its window.
    local searched, seen = {}, {}
    for _, a in ipairs(self.opts.addons or {}) do searched[#searched + 1] = a; seen[a] = true end
    if lib.combined then
        for _, a in ipairs(lib.order) do
            if not seen[a] and lib.openers[a] then searched[#searched + 1] = a end
        end
    end
    for _, addonId in ipairs(searched) do
        local spec = lib.addons[addonId]
        -- An addon with its own search (Squizzumables: fuzzy, sub-tab aware)
        -- answers for itself: spec.search(query) returns entries { label,
        -- path, page, onSelect(win) }, ranked already, ahead of the rest.
        if spec and spec.search then
            local ok, list = pcall(spec.search, query)
            for _, r in ipairs(ok and list or {}) do
                if r.page and spec.pageByKey[r.page] then
                    strong[#strong + 1] = { addon = addonId, page = r.page, label = r.label,
                        path = r.path or spec.pageByKey[r.page].label, onSelect = r.onSelect }
                end
            end
        end
        if spec then
            for _, group in ipairs(spec.groups or {}) do
                for _, page in ipairs(group.pages or {}) do
                    if page.label:lower():find(query, 1, true) then
                        strong[#strong + 1] = { addon = addonId, page = page.key,
                            label = page.label, path = (spec.title or addonId) .. " > " .. group.label }
                    end
                end
            end
            -- Pages whose searchable things change while the window is open
            -- (Indicators: custom indicators come and go) give a search(add)
            -- function, asked afresh on every search. Each entry: label, path,
            -- tip, onSelect(win); the page itself is shown first.
            local live = {}
            for _, group in ipairs(spec.groups or {}) do
                for _, page in ipairs(group.pages or {}) do
                    if page.search then
                        page.search(function(e)
                            e.page = page.key
                            live[#live + 1] = e
                        end)
                    end
                end
            end
            local entries = {}
            for _, e in ipairs(lib.index[addonId] or {}) do entries[#entries + 1] = e end
            for _, e in ipairs(live) do entries[#entries + 1] = e end
            for _, e in ipairs(entries) do
                local page = spec.pageByKey[e.page]
                if page then
                    local hit = {
                        addon = addonId, page = e.page, label = e.label, onSelect = e.onSelect,
                        path = page.label .. (e.path and (" > " .. e.path) or ""),
                    }
                    if e.label and e.label:lower():find(query, 1, true) then
                        strong[#strong + 1] = hit
                    elseif e.path and e.path:lower():find(query, 1, true) then
                        mid[#mid + 1] = hit
                    elseif e.tip and e.tip:lower():find(query, 1, true) then
                        weak[#weak + 1] = hit
                    end
                end
            end
        end
    end
    for _, m in ipairs(mid) do strong[#strong + 1] = m end
    for _, w in ipairs(weak) do strong[#strong + 1] = w end
    return strong
end

function Window:UpdateSearch(query)
    local results = self:Search(query)
    local shown = 0
    for i, row in ipairs(self.resultRows) do
        local e = results[i]
        if e then
            row.entry = e
            row.label:SetText(e.label)
            row.path:SetText(e.path or "")
            row:Show()
            shown = i
        else
            row.entry = nil
            row:Hide()
        end
    end
    if shown == 0 then
        self.results:Hide()
    else
        self.results:SetHeight(shown * 32 + 8)
        self.results:Show()
    end
end

function Window:BuildSidebar()
    local f = self.frame
    local side = CreateFrame("Frame", nil, f, "BackdropTemplate")
    side:SetPoint("TOPLEFT", 1, -1 - TITLE_H)
    side:SetPoint("BOTTOMLEFT", 1, 1)
    side:SetWidth(SIDEBAR_W)
    side:SetBackdrop({ bgFile = WHITE })
    side:SetBackdropColor(RGBA("tabInactive"))
    local edge = side:CreateTexture(nil, "OVERLAY")
    edge:SetWidth(1)
    edge:SetPoint("TOPRIGHT")
    edge:SetPoint("BOTTOMRIGHT")
    local br, bg, bb = RGBA("border")
    edge:SetColorTexture(br, bg, bb, 0.5)
    self.sidebar = side
    self:LayoutSidebar()
end

-- The sidebar's rows, rebuilt when combined mode changes. Its own addon(s) in
-- full; while combined (/squizz), every OTHER addon with an opener follows as a
-- single row naming it -- a click hands over to that addon's window (see
-- lib:HandOff), which lists its own pages in full and this addon as one row.
-- So each window keeps its own pages and none is ever built twice.
function Window:LayoutSidebar()
    local side = self.sidebar
    if self.rowsHost then
        self.rowsHost:Hide()
        self.rowsHost:SetParent(nil)
    end
    local host = CreateFrame("Frame", nil, side)
    host:SetAllPoints(side)
    self.rowsHost = host
    self.rows = {}
    local combined = lib.combined and true or false
    self.sidebarCombined = combined

    local others = {}
    if combined then
        for _, id in ipairs(lib.order) do
            local own = false
            for _, a in ipairs(self.opts.addons or {}) do if a == id then own = true end end
            if not own and lib.openers[id] and lib.addons[id] then others[#others + 1] = id end
        end
    end

    local y = -10
    local many = #(self.opts.addons or {}) > 1 or #others > 0
    for _, addonId in ipairs(self.opts.addons or {}) do
        local spec = lib.addons[addonId]
        if spec then
            if many then
                local h = Text(host, 13, "textBright")
                h:SetPoint("TOPLEFT", 12, y)
                h:SetText(spec.title or addonId)
                y = y - 22
            end
            for _, group in ipairs(spec.groups or {}) do
                local gh = Text(host, 10, "textDim")
                gh:SetPoint("TOPLEFT", 12, y)
                gh:SetText((group.label or ""):upper())
                y = y - 18
                for _, page in ipairs(group.pages or {}) do
                    local row = CreateFrame("Button", nil, host, "BackdropTemplate")
                    row:SetHeight(ROW_H)
                    row:SetPoint("TOPLEFT", 6, y)
                    row:SetPoint("TOPRIGHT", -6, y)
                    row:SetBackdrop({ bgFile = WHITE })
                    row:SetBackdropColor(0, 0, 0, 0)
                    local bar = row:CreateTexture(nil, "OVERLAY")
                    bar:SetPoint("TOPLEFT")
                    bar:SetPoint("BOTTOMLEFT")
                    bar:SetWidth(3)
                    bar:Hide()
                    row.bar = bar
                    row.label = Text(row, 12, "text")
                    row.label:SetPoint("LEFT", 12, 0)
                    row.label:SetText(page.label)
                    local id = addonId .. ":" .. page.key
                    row:SetScript("OnClick", function() self:ShowPage(id) end)
                    row:SetScript("OnEnter", function(r)
                        if r.selected then return end
                        r:SetBackdropColor(RGBA("controlHi"))
                    end)
                    row:SetScript("OnLeave", function(r)
                        if r.selected then return end
                        r:SetBackdropColor(0, 0, 0, 0)
                    end)
                    self.rows[id] = row
                    y = y - ROW_H - 2
                end
                y = y - 8
            end
            y = y - 6
        end
    end

    -- The other addons, one row each (combined mode only).
    for _, addonId in ipairs(others) do
        local spec = lib.addons[addonId]
        local row = CreateFrame("Button", nil, host, "BackdropTemplate")
        row:SetHeight(ROW_H + 4)
        row:SetPoint("TOPLEFT", 6, y)
        row:SetPoint("TOPRIGHT", -6, y)
        row:SetBackdrop({ bgFile = WHITE })
        row:SetBackdropColor(RGBA("control"))
        local label = Text(row, 13, "textBright")
        label:SetPoint("LEFT", 8, 0)
        label:SetText(spec.title or addonId)
        local arrow = Text(row, 13, "textDim")
        arrow:SetPoint("RIGHT", -8, 0)
        arrow:SetText(">")
        row:SetScript("OnEnter", function(r) r:SetBackdropColor(RGBA("controlHi")) end)
        row:SetScript("OnLeave", function(r) r:SetBackdropColor(RGBA("control")) end)
        row:SetScript("OnClick", function() lib:HandOff(self, addonId) end)
        y = y - ROW_H - 10
    end
    if self.current then self:HighlightRow(self.current.addon .. ":" .. self.current.key) end
end

function Window:HighlightRow(id)
    local r, g, b = Accent()
    for rowId, row in pairs(self.rows) do
        row.selected = (rowId == id)
        if row.selected then
            row:SetBackdropColor(r, g, b, 0.14)
            row.bar:SetColorTexture(r, g, b, 1)
            row.bar:Show()
            row.label:SetTextColor(RGBA("textBright"))
        else
            row:SetBackdropColor(0, 0, 0, 0)
            row.bar:Hide()
            row.label:SetTextColor(RGBA("text"))
        end
    end
    if self.accentLine then self.accentLine:SetColorTexture(r, g, b, 0.5) end
end

function Window:BuildContent()
    local f = self.frame
    local area = CreateFrame("Frame", nil, f)
    area:SetPoint("TOPLEFT", self.sidebar, "TOPRIGHT", 0, 0)
    area:SetPoint("BOTTOMRIGHT", -1, 1)
    self.content = area

    local header = CreateFrame("Frame", nil, area)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    header:SetHeight(HEADER_H)
    self.pageTitle = Text(header, 15, "textBright")
    self.pageTitle:SetPoint("TOPLEFT", 14, -10)
    self.pageSub = Text(header, 11, "textDim")
    self.pageSub:SetPoint("TOPLEFT", self.pageTitle, "BOTTOMLEFT", 0, -3)
    local rule = header:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("BOTTOMLEFT", 10, 0)
    rule:SetPoint("BOTTOMRIGHT", -10, 0)
    rule:SetHeight(1)
    local br, bg, bb = RGBA("border")
    rule:SetColorTexture(br, bg, bb, 0.5)

    local body = CreateFrame("Frame", nil, area)
    body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 4, -4)
    body:SetPoint("BOTTOMRIGHT", -4, 4)
    self.body = body

    -- The PREVIEW COLUMN down the right, for pages that give preview(column).
    -- Each such page builds its preview ONCE into its own child of this
    -- column; only the current page's is shown. While the column is up, the
    -- page area beside it (`main`) stops short of it. Pages that pin their own
    -- furniture walk up to `main` (page -> scrollChild -> scrollFrame -> main),
    -- so anything they anchor there stops at the column too.
    local col = CreateFrame("Frame", nil, body, "BackdropTemplate")
    col:SetPoint("TOPRIGHT")
    col:SetPoint("BOTTOMRIGHT")
    col:SetWidth(self.opts.previewWidth or 250)
    col:SetBackdrop({ bgFile = WHITE })
    col:SetBackdropColor(RGBA("tabInactive"))
    col:Hide()
    local colTitle = Text(col, 12, "textBright")
    colTitle:SetPoint("TOPLEFT", 10, -8)
    colTitle:SetText("Preview")
    local colSub = Text(col, 10, "textDim")
    colSub:SetPoint("TOPLEFT", colTitle, "BOTTOMLEFT", 0, -2)
    colSub:SetText("changes as you edit")
    local colHost = CreateFrame("Frame", nil, col)
    colHost:SetPoint("TOPLEFT", 0, -40)
    colHost:SetPoint("BOTTOMRIGHT")
    self.previewCol, self.previewHost = col, colHost
    self.previewTitle, self.previewSub = colTitle, colSub

    local main = CreateFrame("Frame", nil, body)
    main:SetPoint("TOPLEFT")
    main:SetPoint("BOTTOMRIGHT")
    self.main = main

    -- "fill" pages: the whole page area.
    local fill = CreateFrame("Frame", nil, main)
    fill:SetAllPoints()
    fill:Hide()
    self.fillHost = fill

    -- "scroll" pages: one shared scroll frame.
    local sf = CreateFrame("ScrollFrame", nil, main)
    sf:SetPoint("TOPLEFT")
    sf:SetPoint("BOTTOMRIGHT", -14, 0)
    local bar = CreateFrame("Slider", nil, main, "BackdropTemplate")
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 0)
    bar:SetWidth(8)
    bar:SetOrientation("VERTICAL")
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(20)
    bar:SetObeyStepOnDrag(true)
    bar:SetBackdrop({ bgFile = WHITE })
    bar:SetBackdropColor(RGBA("control"))
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(8, 30)
    local tr, tg, tb = RGBA("controlHi")
    thumb:SetColorTexture(tr, tg, tb, 1)
    bar:SetThumbTexture(thumb)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(1, 1)
    sf:SetScrollChild(child)
    sf:SetScript("OnScrollRangeChanged", function(_, _, yrange) bar:SetMinMaxValues(0, yrange or 0) end)
    bar:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(_, delta)
        local lo, hi = bar:GetMinMaxValues()
        bar:SetValue(math.max(lo, math.min(hi, bar:GetValue() - delta * 30)))
    end)
    self.scrollFrame, self.scrollBar, self.scrollChild = sf, bar, child
end

function Window:BuildResizeGrip()
    local f = self.frame
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(f:GetFrameLevel() + 20)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        local page = self.current
        if not page then return end
        self:ShowPage(page.addon .. ":" .. page.key)
        if page.onResize then page.onResize(page.frame) end
    end)
end

function Window:BuildCombatHandling()
    local f, mode = self.frame, self.opts.combat or "fade"
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function(frame, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if mode == "hide" then
                -- Not a close: combined mode outlives the fight.
                if frame:IsShown() then
                    frame.sqWasShown = true
                    lib.handingOff = true
                    frame:Hide()
                    lib.handingOff = false
                end
            else
                frame:SetAlpha(0.5)
            end
        else
            if mode == "hide" then
                if frame.sqWasShown then frame.sqWasShown = nil; frame:Show() end
            else
                frame:SetAlpha(1)
            end
        end
    end)
end

-- Resolve "addon:key" or a bare key (first addon that has it).
function Window:OwnsAddon(addonId)
    for _, a in ipairs(self.opts.addons or {}) do
        if a == addonId then return true end
    end
    return false
end

-- Only this window's own pages: another addon's page is never shown here (it
-- belongs in that addon's window -- see ShowPage and lib:HandOff).
function Window:FindPage(id)
    if not id then return nil end
    local addonId, key = id:match("^([^:]+):(.+)$")
    if addonId then
        if not self:OwnsAddon(addonId) then return nil end
        local spec = lib.addons[addonId]
        return spec and spec.pageByKey[key]
    end
    for _, a in ipairs(self.opts.addons or {}) do
        local spec = lib.addons[a]
        if spec and spec.pageByKey[id] then return spec.pageByKey[id] end
    end
end

function Window:FirstPage()
    for _, a in ipairs(self.opts.addons or {}) do
        local spec = lib.addons[a]
        local g = spec and spec.groups and spec.groups[1]
        if g and g.pages and g.pages[1] then return g.pages[1] end
    end
end

function Window:ShowPage(id)
    -- Another addon's page: its own window shows it, while combined.
    local foreign = type(id) == "string" and id:match("^([^:]+):")
    if foreign and not self:OwnsAddon(foreign) then
        if lib.combined then lib:HandOff(self, foreign, id:match("^[^:]+:(.+)$")) end
        return
    end
    local page = self:FindPage(id) or self:FirstPage()
    if not page then return end
    local isFill = page.layout == "fill"
    local host = isFill and self.fillHost or self.scrollChild

    -- Hide whatever else is showing in THIS window.
    for _, a in ipairs(self.opts.addons or {}) do
        local spec = lib.addons[a]
        for _, p in pairs(spec and spec.pageByKey or {}) do
            if p ~= page and p.frame and p.frame:GetParent() and
               (p.frame:GetParent() == self.fillHost or p.frame:GetParent() == self.scrollChild) then
                p.frame:Hide()
            end
        end
    end

    self:ApplyPreview(page)
    self.fillHost:SetShown(isFill)
    self.scrollFrame:SetShown(not isFill)
    self.scrollBar:SetShown(not isFill)

    if not isFill then
        local h = math.max(page.height or 400, self.scrollFrame:GetHeight())
        self.scrollChild:SetSize(math.max(1, self.scrollFrame:GetWidth()), h)
    end

    if not page.frame then
        self:BuildPage(page, host)
    elseif page.frame:GetParent() ~= host then
        page.frame:SetParent(host)
        page.frame:ClearAllPoints()
        page.frame:SetAllPoints(host)
    end
    page.frame:Show()
    self.current = page

    self.pageTitle:SetText(page.title or page.label or "")
    self.pageSub:SetText(page.subtitle or "")
    self:HighlightRow(page.addon .. ":" .. page.key)
    self:ScrollToTop()
    if page.onShow then page.onShow(page.frame) end
    if self.opts.onShowPage then self.opts.onShowPage(page.key, page.addon, page) end
end

-- Show `page`'s preview in the column (building it the first time), or hide
-- the column for a page without one, and size the page area to match.
function Window:ApplyPreview(page)
    if self.shownPreview and self.shownPreview ~= page.previewFrame then
        self.shownPreview:Hide()
        self.shownPreview = nil
    end
    self.main:ClearAllPoints()
    self.main:SetPoint("TOPLEFT", self.body, "TOPLEFT")
    if not page.preview then
        self.previewCol:Hide()
        self.main:SetPoint("BOTTOMRIGHT", self.body, "BOTTOMRIGHT")
        return
    end
    local w = self.opts.previewWidth or 250
    self.main:SetPoint("BOTTOMRIGHT", self.body, "BOTTOMRIGHT", -(w + 6), 0)
    self.previewCol:Show()
    -- previewTitle = false: the page draws its own heading (Squizzumables'
    -- PreviewColumn), so ours steps aside and the host takes the whole column.
    local titled = page.previewTitle ~= false
    self.previewTitle:SetShown(titled)
    self.previewSub:SetShown(titled)
    self.previewHost:ClearAllPoints()
    self.previewHost:SetPoint("TOPLEFT", self.previewCol, "TOPLEFT", 0, titled and -40 or 0)
    self.previewHost:SetPoint("BOTTOMRIGHT", self.previewCol, "BOTTOMRIGHT")
    local pf = page.previewFrame
    if not pf then
        pf = CreateFrame("Frame", nil, self.previewHost)
        pf:SetAllPoints(self.previewHost)
        page.previewFrame = pf
        page.preview(pf)
    elseif pf:GetParent() ~= self.previewHost then
        pf:SetParent(self.previewHost)
        pf:ClearAllPoints()
        pf:SetAllPoints(self.previewHost)
    end
    pf:Show()
    self.shownPreview = pf
end

-- Build one page into `host` (hidden), registering its frame so the controls
-- it makes can find their page (see IndexControl).
--
-- The page frame is HIDDEN before build() runs, always. Builders may pin
-- furniture outside their own frame (Unit Frames' and Tank Tracker's tab strip
-- and preview pane) and tie it to the page's OnShow/OnHide, showing it at once
-- if the page is already shown. Built shown and hidden afterwards, inside a
-- window that is not yet visible, that Hide() fires no OnHide, so the
-- furniture stayed up over every other page (user screenshot 2026-10-17).
-- The caller Show()s the page when it actually wants it on screen.
function Window:BuildPage(page, host)
    local pf = CreateFrame("Frame", nil, host)
    pf:SetAllPoints(host)
    pf:Hide()
    page.frame = pf
    lib.pageOfFrame[pf] = page
    if page.build then page.build(pf) end
end

--- Build every page this window shows that has not been built yet, hidden,
--- so search can find settings on pages nobody has opened. 1.x built every
--- page on first open anyway, so this costs what it always did.
function Window:BuildAllPages(order)
    -- `order` (optional): "addon:key" ids to build FIRST, in that order --
    -- Squizzumables' builders lean on each other in an order that is not the
    -- sidebar's. Everything else follows in sidebar order.
    local pages = {}
    for _, id in ipairs(order or {}) do
        local p = self:FindPage(id)
        if p then pages[#pages + 1] = p end
    end
    for _, addonId in ipairs(self.opts.addons or {}) do
        local spec = lib.addons[addonId]
        for _, group in ipairs(spec and spec.groups or {}) do
            for _, page in ipairs(group.pages or {}) do pages[#pages + 1] = page end
        end
    end
    for _, page in ipairs(pages) do
        if not page.frame then
            local host = page.layout == "fill" and self.fillHost or self.scrollChild
            -- At the width the page will really have: with its preview
            -- column up, if it has one. Built at full width, text sized
            -- from the host's width ran under the column and was cut
            -- off (Unit Frames' notes, user screenshot 2026-10-17).
            self:ApplyPreview(page)
            if page.layout ~= "fill" then
                local h = math.max(page.height or 400, self.scrollFrame:GetHeight())
                self.scrollChild:SetSize(math.max(1, self.scrollFrame:GetWidth()), h)
            end
            self:BuildPage(page, host)
            if page.indexAll then page.indexAll(page.frame) end
        end
    end
    -- Leave the column as the page actually on screen wants it (none yet on
    -- first open: ShowPage sets it when the window opens).
    if self.current then
        self:ApplyPreview(self.current)
    else
        if self.shownPreview then self.shownPreview:Hide(); self.shownPreview = nil end
        self.previewCol:Hide()
        self.main:ClearAllPoints()
        self.main:SetPoint("TOPLEFT", self.body, "TOPLEFT")
        self.main:SetPoint("BOTTOMRIGHT", self.body, "BOTTOMRIGHT")
    end
end

--- Scroll the current page so `frame` is near the top, and flash it.
function Window:RevealControl(frame)
    if not frame or not frame.GetTop then return end
    local page = self.current
    if page and page.layout ~= "fill" and self.scrollChild:GetTop() and frame:GetTop() then
        local offset = self.scrollChild:GetTop() - frame:GetTop() - 24
        local lo, hi = self.scrollBar:GetMinMaxValues()
        self.scrollBar:SetValue(math.max(lo, math.min(hi, offset)))
    end
    if not self.flash then
        local fl = CreateFrame("Frame", nil, self.frame)
        local tex = fl:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        fl.tex = tex
        local ag = fl:CreateAnimationGroup()
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(0.6)
        a:SetToAlpha(0)
        a:SetDuration(1.2)
        ag:SetScript("OnFinished", function() fl:Hide() end)
        fl.ag = ag
        self.flash = fl
    end
    local fl = self.flash
    local r, g, b = Accent()
    fl.tex:SetColorTexture(r, g, b, 1)
    fl:SetParent(frame)
    fl:ClearAllPoints()
    fl:SetPoint("TOPLEFT", frame, "TOPLEFT", -4, 4)
    fl:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 4, -4)
    fl:SetFrameLevel(frame:GetFrameLevel() + 10)
    fl:Show()
    fl.ag:Stop()
    fl.ag:Play()
end

--- Repaint what follows the accent (the selected sidebar row, the title
--- line). For a theme change, or each tick of Rainbow.
function Window:RefreshAccent()
    if self.current then self:HighlightRow(self.current.addon .. ":" .. self.current.key) end
end

function Window:ScrollToTop()
    if self.scrollBar then self.scrollBar:SetValue(0) end
    if self.scrollFrame then self.scrollFrame:SetVerticalScroll(0) end
end

function Window:CurrentPage()
    return self.current and self.current.key, self.current and self.current.addon
end

--- Show the window on `id` (or the page it was last on, or the first page).
function Window:Open(id)
    -- The sidebar lists the other addons only while combined.
    if self.sidebarCombined ~= (lib.combined and true or false) then self:LayoutSidebar() end
    self.frame:Show()
    self.frame:Raise()
    local cur = self.current
    self:ShowPage(id or (cur and (cur.addon .. ":" .. cur.key)))
end

function Window:Toggle(id)
    if self.frame:IsShown() then self.frame:Hide() else self:Open(id) end
end

-- ---------------------------------------------------------------------------
-- The combined window (/squizz)
--
-- With both addons installed, /squizz opens ONE window for both. It is not a
-- third window holding everyone's pages -- pages pin furniture to the window
-- that built them and some exist once only -- but the addons' own windows
-- working as one: while combined, each window's sidebar lists the other
-- addons as a row, its search covers them, and choosing one of theirs hands
-- over to that addon's window at the same place and size (lib:HandOff). Only
-- one is ever shown. Closing it (X, Escape) ends combined mode, so /sf and /sq
-- open each addon's window on its own again.
--
-- Each addon registers an opener at load:
--   lib:RegisterOpener("SquizzFrames", {
--       open  = function(pageId, show) ... return window end, -- build; show if asked
--       slash = function(msg) ... return handled end,         -- optional: /squizz <msg>
--   })
-- ---------------------------------------------------------------------------

lib.openers = lib.openers or {}

function lib:RegisterOpener(addonId, opener)
    lib.openers[addonId] = opener
    AddToOrder(addonId)
end

local function WindowOf(addonId)
    local op = lib.openers[addonId]
    return op and op.open and op.open(nil, false)
end

--- Swap from `from` to `addonId`'s window (on `key`, if given), at the same
--- place and size, then call after(win) if given.
function lib:HandOff(from, addonId, key, after)
    local win = WindowOf(addonId)
    if not win or win == from then return end
    local f, t = from.frame, win.frame
    if f:IsShown() and f:GetLeft() then
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", f:GetLeft(), f:GetTop())
        t:SetSize(f:GetWidth(), f:GetHeight())
    end
    lib.handingOff = true
    f:Hide()
    lib.handingOff = false
    -- Through the addon's opener, not win:Open directly: an addon may do work
    -- on opening (Squizzumables refreshes its pages' values first).
    lib.openers[addonId].open(key and (addonId .. ":" .. key) or nil, true)
    if after then after(win) end
end

--- /squizz: toggle the combined window. An addon's opener may claim a
--- subcommand first (Squizzumables: /squizz cdms).
function lib:OpenCombined(msg)
    msg = msg or ""
    -- Build every addon's window (hidden) first: the sidebar lists them and
    -- the search reads their indexes, which fill as their pages are built.
    local ids = {}
    for _, a in ipairs(lib.order) do
        if lib.openers[a] then ids[#ids + 1] = a end
    end
    if #ids == 0 then return end

    lib.combined = #ids > 1
    for _, a in ipairs(ids) do WindowOf(a) end
    -- Laid out again once every addon is registered: a window built before
    -- the next addon's pages existed would otherwise not list it.
    for _, a in ipairs(ids) do
        local w = WindowOf(a)
        if w then w:LayoutSidebar() end
    end

    -- One of the windows is already up: /squizz again closes it if it is the
    -- combined window, and otherwise turns it into the combined window right
    -- where it is (its sidebar gains the other addons) rather than opening a
    -- second window beside it.
    if msg == "" then
        for _, a in ipairs(ids) do
            local w = WindowOf(a)
            if w and w.frame:IsShown() then
                if w.sidebarCombined and lib.combined then
                    w.frame:Hide()
                else
                    w:Open()
                end
                return
            end
        end
    end
    for _, a in ipairs(ids) do
        local op = lib.openers[a]
        if msg ~= "" and op.slash and op.slash(msg) then return end
    end
    local first = lib.openers[ids[1]]
    first.open(nil, true)
end

-- One Edit Mode for every addon while combined (user request 2026-10-17):
-- either window's Edit Mode button switches them all, on if none is on and
-- off otherwise. Each opener may give editMode(on) and isEditing(); an addon
-- without them is left alone. Outside combined mode each button only drives
-- its own addon.
function lib:ToggleCombinedEdit()
    local any = false
    for _, op in pairs(lib.openers) do
        if op.isEditing and op.isEditing() then any = true end
    end
    local on = not any
    lib.combinedEdit = on
    for _, op in pairs(lib.openers) do
        if op.editMode then op.editMode(on) end
    end
end

-- Closing a window (not handing over) ends combined mode -- and the shared
-- Edit Mode, if the combined window's button turned it on.
lib.OnWindowHidden = function()
    if lib.handingOff then return end
    if lib.combined and lib.combinedEdit then
        for _, op in pairs(lib.openers) do
            if op.editMode then op.editMode(false) end
        end
    end
    lib.combinedEdit = false
    lib.combined = false
end

SLASH_SQUIZZSHELL1 = "/squizz"
SlashCmdList.SQUIZZSHELL = function(msg) lib:OpenCombined(msg) end
