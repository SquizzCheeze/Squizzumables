-- Quest/AchievementTracker.lua
-- A panel beside the achievement window listing the achievements you are
-- closest to finishing, off by default:
--
--   * a scan of every category, a little at a time so it never stalls a frame
--   * a threshold ("75% or more done"), search by name / description / reward
--     / achievement or reward item ID, a category filter, "has a reward"
--   * sorted by progress, name or category, either way round
--   * click a row for its description and criteria, middle-click to track it
--     on the objective tracker, right-click to open it in the achievement
--     window, shift-click to link it in chat
--
-- Progress counts partial criteria too (450 of 500 kills is 90% of that
-- criterion), so a one-step "kill 500" achievement shows how close it is.
-- WindTools only counted finished criteria. Criteria this character cannot
-- earn are left out, as WindTools does.
--
-- Retail only: on WoW Forever achievements are Legacy Challenges and there is
-- no achievement window to sit beside. Waits while WindTools' Achievement
-- Tracker is on. WindTools was read for behaviour only.

local addonName, ns = ...
local BH = ns.BH

local AT = {}
ns.AchievementTracker = AT

local ROW_H = 48
local PAD = 4

local function Elv()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

local function WTdb()
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") then return nil end
    local E = Elv()
    local q = E and E.db and E.db.WT and E.db.WT.quest
    local t = type(q) == "table" and q.achievementTracker
    return type(t) == "table" and t or nil
end

local function WTOn()
    local t = WTdb()
    return t and t.enable and true or false
end

local settingsView = setmetatable({}, { __index = function(_, k)
    local s = BH.settings
    local v = s and s[k]
    if v == nil and BH.defaultSettings then v = BH.defaultSettings[k] end
    return v
end })
local function Settings() return settingsView end

local function Active()
    return not BH.IS_FOREVER and BH.settings and BH.settings.atEnabled and not WTOn()
end

-- ============================================================================
-- Settings (a page on the Quests tab; QuestExtras.lua adds it)
-- ============================================================================

AT.PAGE = { key = "achievements", label = "Achievements", rows = {
    { key = "atEnabled", type = "check", default = false, label = "Achievement Tracker",
      tip = "A list beside the achievement window of the achievements you are closest to finishing.\n\n"
          .. "Retail only. Waits while WindTools' Achievement Tracker is on.",
      apply = function(v)
          if v and WTOn() then
              print("|cff33cc99Squizzumables:|r WindTools' Achievement Tracker is still on. Turn it off there and this takes over.")
          end
      end },
    { key = "atThreshold", type = "slider", default = 75, min = 0, max = 100, step = 1,
      label = "Show From (% Done)", when = function(s) return s.atEnabled end,
      tip = "Achievements less done than this are left off the list. The slider on the list itself changes this too." },
    { key = "atWidth", type = "slider", default = 500, min = 350, max = 800, step = 10,
      label = "Width", when = function(s) return s.atEnabled end },
    { key = "atHeight", type = "slider", default = 500, min = 300, max = 900, step = 10,
      label = "Height", when = function(s) return s.atEnabled end },
    { key = "atTooltip", type = "check", default = true, label = "Hints When Hovering a Row",
      when = function(s) return s.atEnabled end },
    { key = "atScanOnShow", type = "check", default = true, label = "Scan When the List First Opens",
      tip = "Otherwise the list stays empty until you press its rescan button.",
      when = function(s) return s.atEnabled end },
    { key = "atScanOnLogin", type = "check", default = false, label = "Scan at Login",
      tip = "So the list is ready the first time you open it. The scan is spread out, but it is a few seconds of work.",
      when = function(s) return s.atEnabled end },
} }

-- ============================================================================
-- Reading achievements
-- ============================================================================

local function Progress(id)
    local n = GetAchievementNumCriteria(id) or 0
    local lines, sum, count, done = {}, 0, 0, 0
    for i = 1, n do
        local text, _, completed, quantity, req, _, _, _, qString, _, eligible = GetAchievementCriteriaInfo(id, i)
        if eligible ~= false then
            count = count + 1
            local part = 0
            if completed then
                part, done = 1, done + 1
            elseif type(req) == "number" and req > 1 and type(quantity) == "number" then
                part = math.min(quantity / req, 1)
            end
            sum = sum + part
            lines[#lines + 1] = { text = text, completed = completed, quantity = quantity, req = req, qString = qString }
        end
    end
    return { percent = count > 0 and sum / count * 100 or 0, total = count, done = done, lines = lines }, n
end

local results = {}
local scanning, generation = false, 0
local catName, catParent = {}, {}

local frame, toggle

local function CategoryInfo(id)
    if catName[id] == nil then
        local title, parent = GetCategoryInfo(id)
        catName[id] = title or "?"
        catParent[id] = (type(parent) == "number" and parent > 0) and parent or false
    end
    return catName[id], catParent[id]
end

local UpdateView, ShowScanning

function AT.Scan()
    if scanning or BH.IS_FOREVER then return end
    scanning = true
    generation = generation + 1
    local gen = generation
    wipe(results)
    local cats = GetCategoryList() or {}
    local total = 0
    for _, c in ipairs(cats) do total = total + (GetCategoryNumAchievements(c) or 0) end
    local ci, ai, scanned = 1, 0, 0
    local seen, byName = {}, {}

    local function Consider(cat, id, name, _, completed, _, _, _, description, flags, icon, rewardText, isGuild, earnedByMe)
        if not id or seen[id] or not name then return end
        seen[id] = true
        if completed or earnedByMe or isGuild then return end
        if IsAchievementEligible and IsAchievementEligible(id) == false then return end
        local prog, n = Progress(id)
        if n > 0 and prog.total == 0 then return end
        if prog.total > 0 and prog.done >= prog.total then return end
        local lower = name:lower()
        local old = byName[lower]
        if old then
            if prog.percent <= old.progress.percent then return end
            for i, e in ipairs(results) do
                if e == old then table.remove(results, i) break end
            end
        end
        local cname, parent = CategoryInfo(cat)
        local e = {
            id = id, name = name, lower = lower, description = description or "", icon = icon,
            cat = cat, catName = cname, catParent = parent, progress = prog, flags = flags,
            rewardText = (rewardText and rewardText ~= "") and rewardText or nil,
            rewardItem = C_AchievementInfo.GetRewardItemID and C_AchievementInfo.GetRewardItemID(id) or nil,
        }
        byName[lower] = e
        results[#results + 1] = e
    end

    local function Step()
        if gen ~= generation then return end
        local budget = 30
        while budget > 0 do
            local cat = cats[ci]
            if not cat then
                scanning = false
                if frame and frame:IsVisible() then ShowScanning(false); UpdateView() end
                return
            end
            ai = ai + 1
            if ai > (GetCategoryNumAchievements(cat) or 0) then
                ci, ai = ci + 1, 0
            else
                budget, scanned = budget - 1, scanned + 1
                Consider(cat, GetAchievementInfo(cat, ai))
            end
        end
        if frame and frame:IsVisible() then
            frame.scanBar:SetValue(total > 0 and scanned / total * 100 or 0)
            frame.scanText:SetText(("%d / %d"):format(scanned, total))
        end
        C_Timer.After(0, Step)
    end

    if frame and frame:IsVisible() then ShowScanning(true) end
    Step()
end

-- ============================================================================
-- The list
-- ============================================================================

local filters = { pattern = "", cat = nil, rewards = false }
local sortBy, sortDesc = "percent", true

local function Matches(e)
    if filters.rewards and not (e.rewardText or e.rewardItem) then return false end
    if filters.cat and e.cat ~= filters.cat and e.catParent ~= filters.cat then return false end
    if e.progress.percent < (Settings().atThreshold or 75) then return false end
    local p = strtrim(filters.pattern or "")
    if p == "" then return true end
    local num = tonumber(p)
    if num then return num == e.id or num == e.rewardItem end
    p = p:lower()
    for _, field in ipairs({ e.lower, e.description, e.rewardText }) do
        if field and field:lower():find(p, 1, true) then return true end
    end
    return false
end

local function Sorter(a, b)
    local x, y
    if sortBy == "name" then
        x, y = a.lower, b.lower
    elseif sortBy == "category" then
        x, y = a.catName, b.catName
    else
        x, y = a.progress.percent, b.progress.percent
    end
    if x == y then return a.lower < b.lower end
    if sortDesc then return x > y end
    return x < y
end

UpdateView = function()
    if not frame then return end
    local list = {}
    for _, e in ipairs(results) do
        if Matches(e) then list[#list + 1] = e end
    end
    table.sort(list, Sorter)
    for i, e in ipairs(list) do e.last = (i == #list) or nil end
    local dp = CreateDataProvider()
    dp:InsertTable(list)
    frame.scrollBox:SetDataProvider(dp, ScrollBoxConstants.RetainScrollPosition)
    frame.empty:SetShown(#list == 0)
    frame.empty:SetText(#results == 0 and "Nothing scanned yet. Press the rescan button."
        or "Nothing matches. Lower the threshold or clear the search.")
    frame.countText:SetText(#list .. " shown")
end

ShowScanning = function(on)
    frame.scan:SetShown(on)
    frame.body:SetShown(not on)
end

local function ProgressColour(p)
    if p >= 90 then return 0.06, 0.73, 0.51 end
    if p >= 75 then return 0.13, 0.77, 0.37 end
    if p >= 60 then return 0.92, 0.70, 0.03 end
    return 0.98, 0.45, 0.09
end

local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t "
local DASH = "|cff808080-|r "

local function DetailText(e)
    local out = { e.description }
    if #e.progress.lines > 0 then out[#out + 1] = "" end
    for _, l in ipairs(e.progress.lines) do
        local t = l.text or "?"
        if type(l.req) == "number" and l.req > 1 then
            local q = (l.qString and l.qString ~= "") and l.qString or ((l.quantity or 0) .. " / " .. l.req)
            t = t .. " (" .. q .. ")"
        end
        out[#out + 1] = l.completed and (CHECK .. "|cff10b981" .. t .. "|r") or (DASH .. t)
    end
    return table.concat(out, "\n")
end

local function Tracking(id)
    return C_ContentTracking and C_ContentTracking.IsTracking(Enum.ContentTrackingType.Achievement, id)
end

local function ToggleTrack(row)
    local id = row.data.id
    if not C_ContentTracking then return end
    local kind = Enum.ContentTrackingType.Achievement
    if C_ContentTracking.IsTracking(kind, id) then
        C_ContentTracking.StopTracking(kind, id, Enum.ContentTrackingStopType.Manual)
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    else
        local max = Constants.ContentTrackingConsts.MaxTrackedAchievements
        if #C_ContentTracking.GetTrackedIDs(kind) >= max then
            UIErrorsFrame:AddMessage(ACHIEVEMENT_WATCH_TOO_MANY:format(max), 1, 0.1, 0.1, 1)
            return
        end
        if not C_ContentTracking.StartTracking(kind, id) then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end
    end
    row.tracking:SetShown(Tracking(id) and true or false)
end

local function RowTooltip(row)
    if not Settings().atTooltip then return end
    GameTooltip:SetOwner(frame, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
    GameTooltip:SetText(row.data.name, 1, 0.82, 0)
    GameTooltip:AddLine(("%d of %d criteria done"):format(row.data.progress.done, row.data.progress.total), 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: details", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Middle-click: track", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click: open in the achievement window", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Shift-click: link in chat", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function BuildRow(row)
    row.built = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.1, 0.1, 0.1, 0.9)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)

    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetPoint("TOPLEFT", 1, -1)
    row.bar:SetPoint("TOPRIGHT", -1, -1)
    row.bar:SetHeight(ROW_H - 2)
    row.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    row.bar:SetMinMaxValues(0, 100)
    row.bar:SetAlpha(0.22)
    row.bar:EnableMouse(false)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ROW_H - 14, ROW_H - 14)
    row.icon:SetPoint("TOPLEFT", 7, -7)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
    row.pct:SetPoint("TOPRIGHT", -10, -10)
    row.pct:SetJustifyH("RIGHT")

    row.reward = CreateFrame("Frame", nil, row)
    row.reward:SetSize(24, 24)
    row.reward:SetPoint("TOPRIGHT", -74, -12)
    row.reward.tex = row.reward:CreateTexture(nil, "ARTWORK")
    row.reward.tex:SetAllPoints()
    row.reward.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.reward:SetScript("OnEnter", function(self)
        local d = row.data
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if d.rewardItem then GameTooltip:SetItemByID(d.rewardItem) else GameTooltip:SetText(d.rewardText or "", 1, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    row.reward:SetScript("OnLeave", GameTooltip_Hide)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -2)
    row.name:SetPoint("RIGHT", row.reward, "LEFT", -8, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.cat = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.cat:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row.cat:SetPoint("RIGHT", row.name, "RIGHT")
    row.cat:SetJustifyH("LEFT")
    row.cat:SetWordWrap(false)

    row.tracking = row:CreateFontString(nil, "OVERLAY", "GameFontGreenSmall")
    row.tracking:SetPoint("BOTTOM", row, "TOP", 0, -ROW_H + 2)
    row.tracking:SetText("Tracking")

    row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.detail:SetPoint("TOPLEFT", 12, -ROW_H - 4)
    row.detail:SetPoint("RIGHT", -12, 0)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetSpacing(2)

    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnClick", function(self, mouse)
        local d = self.data
        if not d then return end
        if IsModifiedClick("CHATLINK") and mouse == "LeftButton" then
            local link = GetAchievementLink(d.id)
            if link then ChatFrameUtil.InsertLink(link) end
        elseif mouse == "MiddleButton" then
            ToggleTrack(self)
        elseif mouse == "RightButton" then
            if AchievementFrame_SelectAchievement then AchievementFrame_SelectAchievement(d.id) end
        else
            d.expanded = not d.expanded
            if d.expanded then
                self.detail:SetText(DetailText(d))
                d.height = ROW_H + 12 + math.ceil(self.detail:GetStringHeight())
            else
                d.height = nil
            end
            frame.scrollBox:FullUpdate(ScrollBoxConstants.UpdateImmediately)
            if d.last then frame.scrollBox:ScrollToEnd() end
        end
    end)
end

local function InitRow(row, d)
    if not row.built then BuildRow(row) end
    row.data = d
    d.progress = Progress(d.id)
    local p = d.progress.percent
    row.bar:SetStatusBarColor(ProgressColour(p))
    row.bar:SetValue(p)
    row.icon:SetTexture(d.icon)
    row.pct:SetText(math.floor(p) .. "%")
    row.name:SetText(d.name)
    row.cat:SetText(d.catParent and (CategoryInfo(d.catParent) .. " - " .. d.catName) or d.catName)
    row.tracking:SetShown(Tracking(d.id) and true or false)
    row.reward:Hide()
    if d.rewardItem then
        local icon = C_Item.GetItemIconByID(d.rewardItem)
        row.reward.tex:SetTexture(icon or 134400)
        row.reward:Show()
    elseif d.rewardText then
        row.reward.tex:SetTexture(237282)
        row.reward:Show()
    end
    if d.expanded then
        row.detail:SetText(DetailText(d))
        row.detail:Show()
    else
        row.detail:Hide()
    end
end

local function Button(parent, text, w)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetText(text)
    return b
end

local function CategoryMenu(_, root)
    root:CreateRadio("All Categories", function() return filters.cat == nil end,
        function() filters.cat = nil; UpdateView() end)
    root:CreateDivider()
    local top, kids = {}, {}
    for _, id in ipairs(GetCategoryList() or {}) do
        local _, parent = CategoryInfo(id)
        if parent then
            kids[parent] = kids[parent] or {}
            table.insert(kids[parent], id)
        else
            top[#top + 1] = id
        end
    end
    for _, id in ipairs(top) do
        local r = root:CreateRadio(catName[id], function() return filters.cat == id end,
            function() filters.cat = id; UpdateView() end)
        for _, kid in ipairs(kids[id] or {}) do
            r:CreateRadio(catName[kid], function() return filters.cat == kid end,
                function() filters.cat = kid; UpdateView() end)
        end
    end
end

local SORTS = { { "percent", "Progress" }, { "name", "Name" }, { "category", "Category" } }

local function SortMenu(_, root)
    for _, s in ipairs(SORTS) do
        root:CreateRadio(s[2], function() return sortBy == s[1] end, function() sortBy = s[1]; UpdateView() end)
    end
end

local function SetThreshold(v)
    local s = BH.settings
    if not s then return end
    v = math.floor(v + 0.5)
    if s.atThreshold == v then return end
    s.atThreshold = v
    BH:SaveSettings()
    frame.thresholdText:SetText("Show from " .. v .. "%")
    if frame.slider:GetValue() ~= v then frame.slider:SetValue(v) end
    if not frame.pendingView then
        frame.pendingView = true
        C_Timer.After(0.3, function() frame.pendingView = false; UpdateView() end)
    end
end

local function Build()
    if frame or not _G.AchievementFrame then return end
    local af = _G.AchievementFrame
    frame = CreateFrame("Frame", "SquizzumablesAchievementTracker", af, "BackdropTemplate")
    frame:SetPoint("TOPLEFT", af, "TOPRIGHT", 4, 0)
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    frame:SetBackdropColor(0.06, 0.06, 0.06, 0.92)
    frame:SetBackdropBorderColor(0, 0, 0, 1)
    frame:EnableMouse(true)

    -- Body: everything but the scan overlay.
    local body = CreateFrame("Frame", nil, frame)
    body:SetAllPoints()
    frame.body = body

    local search = CreateFrame("EditBox", nil, body, "SearchBoxTemplate")
    search:SetHeight(22)
    search:SetPoint("TOPLEFT", 14, -8)
    search:SetPoint("TOPRIGHT", -10, -8)
    search:SetMaxLetters(50)
    search.Instructions:SetText("Search name, description, reward or ID")
    search:HookScript("OnTextChanged", function(self)
        filters.pattern = self:GetText() or ""
        UpdateView()
    end)

    -- Row 1: threshold slider, All, 95%+, rescan.
    frame.thresholdText = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.thresholdText:SetPoint("TOPLEFT", 12, -38)
    local slider = CreateFrame("Slider", nil, body, "MinimalSliderTemplate")
    slider:SetSize(150, 16)
    slider:SetPoint("TOPLEFT", 12, -52)
    slider:SetMinMaxValues(0, 100)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetScript("OnValueChanged", function(_, v) SetThreshold(v) end)
    frame.slider = slider

    local all = Button(body, "All", 60)
    all:SetPoint("LEFT", slider, "RIGHT", 14, 6)
    all:SetScript("OnClick", function()
        filters.pattern, filters.cat, filters.rewards = "", nil, false
        search:SetText("")
        frame.rewards:SetChecked(false)
        SetThreshold(0)
        UpdateView()
    end)
    local near = Button(body, "95%+", 60)
    near:SetPoint("LEFT", all, "RIGHT", 4, 0)
    near:SetScript("OnClick", function() SetThreshold(95) end)

    local rescan = Button(body, "", 26)
    rescan:SetPoint("TOPRIGHT", -10, -40)
    local ri = rescan:CreateTexture(nil, "OVERLAY")
    ri:SetSize(14, 14)
    ri:SetPoint("CENTER")
    ri:SetTexture("Interface\\Buttons\\UI-RefreshButton")
    rescan:SetScript("OnClick", AT.Scan)
    rescan:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Scan all achievements again", 1, 1, 1)
        GameTooltip:Show()
    end)
    rescan:SetScript("OnLeave", GameTooltip_Hide)

    -- Row 2: category, rewards, sort.
    local cat = CreateFrame("DropdownButton", nil, body, "WowStyle1DropdownTemplate")
    cat:SetWidth(170)
    cat:SetPoint("TOPLEFT", 10, -76)
    cat:SetDefaultText("All Categories")
    cat:SetupMenu(CategoryMenu)

    local rewards = CreateFrame("CheckButton", nil, body, "UICheckButtonTemplate")
    rewards:SetSize(22, 22)
    rewards:SetPoint("LEFT", cat, "RIGHT", 10, 0)
    rewards.Text:SetText("Has a Reward")
    rewards:SetScript("OnClick", function(self)
        filters.rewards = self:GetChecked() and true or false
        UpdateView()
    end)
    frame.rewards = rewards

    local order = Button(body, "", 26)
    order:SetPoint("TOPRIGHT", -10, -76)
    local arrow = order:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(12, 12)
    arrow:SetPoint("CENTER")
    arrow:SetAtlas("common-dropdown-icon-next")
    local function Arrow() arrow:SetRotation(sortDesc and -math.pi / 2 or math.pi / 2) end
    Arrow()
    order:SetScript("OnClick", function()
        sortDesc = not sortDesc
        Arrow()
        UpdateView()
    end)
    local sort = CreateFrame("DropdownButton", nil, body, "WowStyle1DropdownTemplate")
    sort:SetWidth(110)
    sort:SetPoint("RIGHT", order, "LEFT", -4, 0)
    sort:SetupMenu(SortMenu)

    -- The list.
    local box = CreateFrame("Frame", nil, body, "WowScrollBoxList")
    box:SetPoint("TOPLEFT", 8, -106)
    box:SetPoint("BOTTOMRIGHT", -24, 24)
    local bar = CreateFrame("EventFrame", nil, body, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 6, 0)
    local view = CreateScrollBoxListLinearView(PAD, PAD, PAD, PAD, PAD)
    view:SetElementInitializer("Button", InitRow)
    view:SetElementExtentCalculator(function(_, d) return d.height or ROW_H end)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    frame.scrollBox = box

    frame.empty = body:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    frame.empty:SetPoint("CENTER", box, "CENTER")
    frame.empty:SetWidth(300)
    frame.countText = body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.countText:SetPoint("BOTTOMLEFT", 12, 7)

    -- Scan overlay.
    local scan = CreateFrame("Frame", nil, frame)
    scan:SetAllPoints()
    scan:Hide()
    frame.scan = scan
    local label = scan:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("CENTER", 0, 24)
    label:SetText("Scanning achievements")
    frame.scanBar = CreateFrame("StatusBar", nil, scan)
    frame.scanBar:SetSize(260, 16)
    frame.scanBar:SetPoint("CENTER")
    frame.scanBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    frame.scanBar:SetStatusBarColor(ns.Theme.RGBA("accent"))
    frame.scanBar:SetMinMaxValues(0, 100)
    local sbg = frame.scanBar:CreateTexture(nil, "BACKGROUND")
    sbg:SetAllPoints()
    sbg:SetColorTexture(0, 0, 0, 0.6)
    frame.scanText = scan:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.scanText:SetPoint("TOP", frame.scanBar, "BOTTOM", 0, -6)

    frame:SetScript("OnShow", function()
        if scanning then ShowScanning(true) return end
        ShowScanning(false)
        if #results == 0 and Settings().atScanOnShow then AT.Scan() return end
        UpdateView()
    end)

    toggle = Button(af, "Tracker", 70)
    toggle:SetHeight(18)
    toggle:SetPoint("BOTTOMRIGHT", af, "BOTTOMRIGHT", -6, 4)
    toggle:SetFrameLevel(af:GetFrameLevel() + 10)
    toggle:SetScript("OnClick", function()
        local s = BH.settings
        if not s then return end
        s.atHidden = frame:IsShown() and true or nil
        BH:SaveSettings()
        frame:SetShown(not s.atHidden)
    end)
end

function AT.Apply()
    if not Active() then
        if frame then frame:Hide() end
        if toggle then toggle:Hide() end
        return
    end
    Build()
    if not frame then return end
    local s = Settings()
    frame:SetSize(s.atWidth or 500, s.atHeight or 500)
    local v = s.atThreshold or 75
    frame.thresholdText:SetText("Show from " .. v .. "%")
    frame.slider:SetValue(v)
    toggle:Show()
    frame:SetShown(not s.atHidden)
    if frame:IsVisible() and not scanning then
        -- Heights were measured at the old width.
        for _, e in ipairs(results) do
            if e.expanded then e.expanded, e.height = nil, nil end
        end
        UpdateView()
    end
end

-- ============================================================================
-- WindTools' settings, copied once per profile
-- ============================================================================

function AT.Seed()
    local s = BH.settings
    if not s or s.atSeededFromWT then return end
    local t = WTdb()
    if not t then return end
    s.atSeededFromWT = true
    if t.enable then s.atEnabled = true end
    if t.show == false then s.atHidden = true end
    if tonumber(t.width) then s.atWidth = math.max(350, math.min(800, tonumber(t.width))) end
    if tonumber(t.height) then s.atHeight = math.max(300, math.min(900, tonumber(t.height))) end
    if tonumber(t.threshold) then s.atThreshold = math.max(0, math.min(100, tonumber(t.threshold))) end
    if t.tooltip ~= nil then s.atTooltip = t.tooltip and true or false end
    local a = type(t.scan) == "table" and t.scan.automation
    if type(a) == "table" then
        if a.onShow ~= nil then s.atScanOnShow = (a.enable ~= false and a.onShow) and true or false end
        if a.onLogin ~= nil then s.atScanOnLogin = (a.enable ~= false and a.onLogin) and true or false end
    end
    BH:SaveSettings()
end

-- ============================================================================
-- Events
-- ============================================================================

local pendingCriteria
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("ACHIEVEMENT_EARNED")
ev:RegisterEvent("CRITERIA_UPDATE")
ev:SetScript("OnEvent", function(_, event, a1)
    if event == "ADDON_LOADED" then
        if a1 == "Blizzard_AchievementUI" then AT.Apply() end
    elseif event == "PLAYER_LOGIN" then
        C_Timer.After(8, function()
            if Active() and Settings().atScanOnLogin and #results == 0 then AT.Scan() end
        end)
    elseif event == "ACHIEVEMENT_EARNED" then
        for i, e in ipairs(results) do
            if e.id == a1 then
                table.remove(results, i)
                if frame and frame:IsVisible() and not scanning then UpdateView() end
                break
            end
        end
    elseif event == "CRITERIA_UPDATE" then
        if pendingCriteria or not (frame and frame:IsVisible()) or scanning then return end
        pendingCriteria = true
        C_Timer.After(0.5, function()
            pendingCriteria = false
            if frame and frame:IsVisible() and not scanning then
                frame.scrollBox:FullUpdate(ScrollBoxConstants.UpdateImmediately)
            end
        end)
    end
end)
