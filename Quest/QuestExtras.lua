-- Quest/QuestExtras.lua
-- The rest of WindTools' Quest section, each piece off by default:
--
--   * Progress: "[30] Steelsnap - Steelsnap's Rib 1/1" in the middle of the
--     screen (or chat) as objectives move, plus accepted / complete lines, in
--     place of Blizzard's plainer objective messages. Optional sounds.
--   * Announce: the same to your party, instance or raid chat, with an
--     on/off tick on the objective tracker's header (WindTools' "switch
--     button"). Never sent while the game blocks addon chat.
--   * Auto Collapse: the tracker folded to its header, hidden or shown per
--     situation (combat, vehicle, resting, dungeon, raid...).
--   * Screenshots: one taken when you earn an achievement.
--
-- Progress works from the quest log itself, compared each time it changes,
-- so it needs no quest lists. WindTools was read for behaviour only.
--
-- Auto Collapse NEVER calls the tracker's own collapse (SetCollapsed). That
-- runs Blizzard's whole tracker update from our code, and the update writes
-- the quest item buttons' questLogIndex attributes; written from addon code
-- they are tainted, and clicking a quest item could then be blocked. It only
-- hides and shows the tracker's section frames (whose OnHide just ends a slide
-- animation), which is legal in combat and touches nothing of Blizzard's.

local addonName, ns = ...
local BH = ns.BH

local QX = {}
ns.QuestExtras = QX

local function Elv()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

local function WTQuest()
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") then return nil end
    local E = Elv()
    local wt = E and E.db and E.db.WT
    return wt and type(wt.quest) == "table" and wt.quest or nil, wt
end

-- Each piece waits while WindTools' own is on.
local function WTOn(key)
    local q = WTQuest()
    local t = q and q[key]
    return type(t) == "table" and t.enable and true or false
end

local settingsView = setmetatable({}, { __index = function(_, k)
    local s = BH.settings
    local v = s and s[k]
    if v == nil and BH.defaultSettings then v = BH.defaultSettings[k] end
    return v
end })
local function Settings() return settingsView end

local function ProgressOn()
    return BH.settings and BH.settings.qpEnabled and not WTOn("progress")
end
local function CollapseOn()
    return BH.settings and BH.settings.ocEnabled and not WTOn("autoCollapse")
end
local function ScreenshotOn()
    return BH.settings and BH.settings.ssEnabled and not WTOn("achievementScreenshot")
end

local function Apply() if QX.Apply then QX.Apply() end end

local function Waiting(key, what)
    return function(v)
        if v and WTOn(key) then
            print(("|cff33cc99Squizzumables:|r WindTools' %s is still on. Turn it off there and this takes over."):format(what))
        end
    end
end

local function Sounds() return BH:BuildSoundDropdownItems() end

local WHERE = {
    { text = "Middle of the screen", value = "SCREEN" },
    { text = "Chat", value = "CHAT" },
    { text = "Both", value = "BOTH" },
}

local STATES = {
    { text = "Leave it", value = "none" },
    { text = "Show", value = "expand" },
    { text = "Fold to the header", value = "collapse" },
    { text = "Hide", value = "hide" },
}

local function StateRow(key, label, default, tip)
    return { key = key, type = "dropdown", default = default, items = STATES, label = label, tip = tip,
             when = function(s) return s.ocEnabled end }
end

-- ============================================================================
-- Settings
-- ============================================================================

QX.SETTINGS = ns.Settings.Describe({
    apply = Apply,
    pages = {
        { key = "progress", label = "Progress", rows = {
            { key = "qpEnabled", type = "check", default = false, label = "Quest Progress Messages",
              tip = "\"[30] Steelsnap - Steelsnap's Rib 1/1\" as objectives move on, and a line when a quest is "
                .. "accepted or complete, in place of the game's own objective messages.\n\nWaits while "
                .. "WindTools' Quest Progress is on.",
              apply = Waiting("progress", "Quest Progress") },
            { key = "qpWhere", type = "dropdown", default = "SCREEN", items = WHERE, label = "Show In",
              when = function(s) return s.qpEnabled end },
            { key = "qpHideBlizzard", type = "check", default = true, label = "Hide the Game's Own Messages",
              tip = "\"Steelsnap's Rib: 1/1\" from the game, which these replace.",
              when = function(s) return s.qpEnabled end },
            { key = "qpMaxRequired", type = "slider", default = 75, min = 0, max = 300, step = 5,
              label = "Skip Counts Over",
              tip = "Objectives counting to more than this (\"kill 200\", percentage bars) only show when done, "
                .. "so they don't flood the screen. 0 shows them all.",
              when = function(s) return s.qpEnabled end },
            { type = "header", label = "IN EACH LINE" },
            { key = "qpLevel", type = "check", default = true, label = "Quest Level",
              when = function(s) return s.qpEnabled end },
            { key = "qpLevelHideSame", type = "check", default = true, label = "Not When It's Your Level",
              when = function(s) return s.qpEnabled and s.qpLevel end },
            { key = "qpTag", type = "check", default = true, label = "Quest Type",
              tip = "Elite, Dungeon, Group and so on.", when = function(s) return s.qpEnabled end },
            { key = "qpFrequency", type = "check", default = true, label = "Daily / Weekly",
              when = function(s) return s.qpEnabled end },
            { key = "qpGroup", type = "check", default = true, label = "Suggested Group Size",
              when = function(s) return s.qpEnabled end },
        } },
        { key = "announce", label = "Announce", rows = {
            { key = "qpAnnounce", type = "check", default = false, label = "Announce Quest Progress",
              tip = "To party, instance or raid chat: accepted, objective done, complete. Never while the game "
                .. "blocks addon chat.\n\nWorks with Quest Progress Messages on (Progress tab).",
              when = function(s) return s.qpEnabled end },
            { key = "qpAnnounceDetails", type = "check", default = false, label = "Every Step, Not Just Done",
              tip = "\"Galak Scout slain 6/12\" each time, not only when an objective is done.",
              when = function(s) return s.qpEnabled and s.qpAnnounce end },
            { key = "qpSwitch", type = "check", default = true, label = "On/Off Tick on the Objective Tracker",
              tip = "A small \"Announce\" tick on the tracker's header, to switch announcing without opening "
                .. "this.", when = function(s) return s.qpEnabled end },
        } },
        { key = "sounds", label = "Sounds", rows = {
            { key = "qpSoundAccept", type = "dropdown", default = "None", items = Sounds, label = "Quest Accepted",
              when = function(s) return s.qpEnabled end },
            { key = "qpSoundStep", type = "dropdown", default = "None", items = Sounds, label = "Objective Moves On",
              when = function(s) return s.qpEnabled end },
            { key = "qpSoundObjective", type = "dropdown", default = "None", items = Sounds, label = "Objective Done",
              when = function(s) return s.qpEnabled end },
            { key = "qpSoundComplete", type = "dropdown", default = "None", items = Sounds, label = "Quest Complete",
              when = function(s) return s.qpEnabled end },
        } },
        { key = "collapse", label = "Auto Collapse", rows = {
            { key = "ocEnabled", type = "check", default = false, label = "Fold the Objective Tracker by Situation",
              tip = "The first situation that applies, top to bottom, decides. \"Leave it\" passes on to the next.\n\n"
                .. "Waits while WindTools' Auto Collapse is on.",
              apply = Waiting("autoCollapse", "Auto Collapse") },
            StateRow("ocCombat", "In Combat", "none"),
            StateRow("ocVehicle", "In a Vehicle", "collapse"),
            StateRow("ocResting", "Resting (Inn or City)", "none"),
            { type = "header", label = "WHERE YOU ARE" },
            StateRow("ocDungeon", "Dungeon", "none"),
            StateRow("ocRaid", "Raid", "none"),
            StateRow("ocScenario", "Scenario or Delve", "expand"),
            StateRow("ocBattleground", "Battleground", "collapse"),
            StateRow("ocArena", "Arena", "collapse"),
            StateRow("ocWorld", "Open World", "none"),
            StateRow("ocHousing", "Housing", "expand", "Your neighbourhood and house (retail)."),
            StateRow("ocDefault", "Anywhere Else", "expand"),
        } },
        { key = "screenshot", label = "Screenshots", rows = {
            { key = "ssEnabled", type = "check", default = false, label = "Screenshot on Achievements",
              tip = "Taken a moment after the achievement's banner appears.\n\nWaits while WindTools' "
                .. "Achievement Screenshot is on.",
              apply = Waiting("achievementScreenshot", "Achievement Screenshot") },
            { key = "ssIgnoreAccount", type = "check", default = false, label = "Not for Ones Already Earned on Another Character",
              when = function(s) return s.ssEnabled end },
            { key = "ssShowUI", type = "check", default = true, label = "Show the Interface if It's Hidden",
              tip = "So the banner is in the picture after Alt+Z.", when = function(s) return s.ssEnabled end },
            { key = "ssChat", type = "check", default = true, label = "Say So in Chat",
              when = function(s) return s.ssEnabled end },
        } },
        ns.AchievementTracker.PAGE,
    },
})

function BH:BuildQuestExtrasTab(parent)
    ns.Settings.Build(QX.SETTINGS, parent)
end

-- ============================================================================
-- Progress
-- ============================================================================

local function Hex(r, g, b, text)
    return ("|cff%02x%02x%02x%s|r"):format(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), text)
end

local function ProgressColour(ratio)
    ratio = math.max(0, math.min(ratio, 1))
    local r = ratio < 0.5 and 1 or (1 - ratio) * 2
    local g = ratio < 0.5 and ratio * 2 or 1
    return r * 0.9 + 0.1, g * 0.9 + 0.1, 0.16
end

local FREQ_DAILY = Enum.QuestFrequency and Enum.QuestFrequency.Daily or 1
local FREQ_WEEKLY = Enum.QuestFrequency and Enum.QuestFrequency.Weekly or 2

local function Snapshot()
    local quests = {}
    local n = C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, n do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and not info.isHidden and info.questID then
            local id = info.questID
            local tag = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(id)
            local objectives = {}
            for j, o in ipairs(C_QuestLog.GetQuestObjectives(id) or {}) do
                objectives[j] = { text = o.text, finished = o.finished,
                                  have = o.numFulfilled, need = o.numRequired }
            end
            quests[id] = {
                id = id, title = info.title, level = info.level, frequency = info.frequency,
                group = info.suggestedGroup, tag = tag and tag.tagName,
                worldQuest = (tag and tag.worldQuestType) or (C_QuestLog.IsWorldQuest and C_QuestLog.IsWorldQuest(id)),
                complete = C_QuestLog.IsComplete(id) and true or false,
                objectives = objectives,
            }
        end
    end
    return quests
end

-- Pieces before the title, coloured and plain.
local function Prefix(q, plain)
    local s = Settings()
    local parts = {}
    local function add(text, r, g, b) parts[#parts + 1] = plain and text or Hex(r, g, b, text) end
    if s.qpLevel ~= false and q.level and q.level > 0
        and not (s.qpLevelHideSame ~= false and q.level == UnitLevel("player")) then
        add("[" .. q.level .. "]", 0.93, 0.36, 0.78)
    end
    if s.qpGroup ~= false and q.group and q.group > 1 then add("[" .. q.group .. "]", 0.98, 0.45, 0.52) end
    if s.qpTag ~= false and q.tag then add("[" .. q.tag .. "]", 0.22, 0.74, 0.97) end
    if s.qpFrequency ~= false then
        if q.frequency == FREQ_DAILY then add("[" .. DAILY .. "]", 0.13, 0.83, 0.93)
        elseif q.frequency == FREQ_WEEKLY then add("[" .. WEEKLY .. "]", 0.18, 0.83, 0.75) end
    end
    return #parts > 0 and (table.concat(parts, " ") .. " ") or ""
end

-- "Galak Scout slain: 6/12" -> "Galak Scout slain"
local function ObjectiveName(o)
    local text = o.text or ""
    text = text:gsub(" |A:.-|a", "")
    text = text:gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub(":?%s*%d+%s*/%s*%d+%s*$", "")
    return text
end

local lastSound = {}
local function Sound(key)
    local name = Settings()[key]
    if not name or name == "None" then return end
    local now = GetTime()
    if lastSound[key] and now - lastSound[key] < 0.5 then return end
    lastSound[key] = now
    BH:PlaySound(name)
end

local function Show(text)
    local where = Settings().qpWhere or "SCREEN"
    if where ~= "CHAT" and UIErrorsFrame then
        UIErrorsFrame:AddMessage(text, 1, 1, 1, 1)
    end
    if where ~= "SCREEN" then
        DEFAULT_CHAT_FRAME:AddMessage(text)
    end
end

local function Announce(text)
    local s = Settings()
    if not s.qpAnnounce then return end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return end
    local channel = BH:GetAnnounceChannel({ party = "PARTY", instance = "INSTANCE_CHAT", raid = "RAID" })
    if not channel or channel == "NONE" then return end
    pcall(C_ChatInfo.SendChatMessage, text, channel)
end

local function Link(q)
    return GetQuestLink and GetQuestLink(q.id) or ("[" .. (q.title or "") .. "]")
end

local TITLE = { 0.98, 0.75, 0.14 }

local function Accepted(q)
    Show(Prefix(q) .. Hex(TITLE[1], TITLE[2], TITLE[3], q.title) .. " - " .. Hex(0.38, 0.65, 0.98, "Quest Accepted"))
    Announce(Prefix(q, true) .. Link(q) .. " accepted")
    Sound("qpSoundAccept")
end

local function Completed(q)
    Show(Prefix(q) .. Hex(TITLE[1], TITLE[2], TITLE[3], q.title) .. " - " .. Hex(0.29, 0.87, 0.5, "Quest Complete"))
    Announce(Prefix(q, true) .. Link(q) .. " complete")
    Sound("qpSoundComplete")
end

local function Stepped(q, o)
    local name = ObjectiveName(o)
    local count = o.have .. "/" .. o.need
    local r, g, b = ProgressColour(o.need > 0 and o.have / o.need or 1)
    Show(Prefix(q) .. Hex(TITLE[1], TITLE[2], TITLE[3], q.title) .. " - " .. name .. " " .. Hex(r, g, b, count))
    if o.finished then
        Announce(Prefix(q, true) .. Link(q) .. " " .. name .. " " .. count .. " (done)")
        Sound("qpSoundObjective")
    else
        if Settings().qpAnnounceDetails then Announce(Prefix(q, true) .. Link(q) .. " " .. name .. " " .. count) end
        Sound("qpSoundStep")
    end
end

local cache
local ready -- false for the first seconds after login: the log fills in then
local turnedIn = {}

local function Compare()
    if not ProgressOn() then cache = nil return end
    local now = Snapshot()
    if not cache or not ready then cache = now return end
    local maxReq = Settings().qpMaxRequired or 75
    for id, q in pairs(now) do
        local before = cache[id]
        if not before then
            if not q.worldQuest and not turnedIn[id] then Accepted(q) end
        elseif not before.complete then
            if q.complete then
                Completed(q)
            else
                for j, o in ipairs(q.objectives) do
                    local p = before.objectives[j]
                    if p and o.have and p.have and o.have > p.have and o.need and o.need > 0
                        and (o.finished or maxReq == 0 or o.need <= maxReq) then
                        Stepped(q, o)
                    end
                end
            end
        end
    end
    cache = now
end

-- World quests leave the log the moment they finish, so "complete" is caught
-- from the turn-in instead.
local function TurnedIn(id)
    turnedIn[id] = true
    local q = cache and cache[id]
    if q and q.worldQuest and not q.complete and ProgressOn() and ready then Completed(q) end
end

-- The game's own objective messages, blanked while ours are on. They are
-- global strings the client formats its messages from; the originals are kept
-- and put back.
local BLIZZ_KEYS = { "ERR_QUEST_ADD_ITEM_SII", "ERR_QUEST_ADD_FOUND_SII", "ERR_QUEST_ADD_KILL_SII",
                     "ERR_QUEST_UNKNOWN_COMPLETE", "ERR_QUEST_OBJECTIVE_COMPLETE_S" }
local blizzOriginal
local function BlizzardMessages()
    local hide = ProgressOn() and Settings().qpHideBlizzard ~= false
    if hide then
        if not blizzOriginal then
            blizzOriginal = {}
            for _, k in ipairs(BLIZZ_KEYS) do blizzOriginal[k] = _G[k] end
        end
        for _, k in ipairs(BLIZZ_KEYS) do _G[k] = "" end
    elseif blizzOriginal then
        for _, k in ipairs(BLIZZ_KEYS) do _G[k] = blizzOriginal[k] end
        blizzOriginal = nil
    end
end

-- ============================================================================
-- Announce tick on the tracker header
-- ============================================================================

local tick
local function UpdateTick()
    local header = _G.ObjectiveTrackerFrame and _G.ObjectiveTrackerFrame.Header
    local want = ProgressOn() and Settings().qpSwitch ~= false
    if not want then
        if tick then tick:Hide() end
        return
    end
    if not header then return end
    if not tick then
        tick = CreateFrame("CheckButton", nil, header, "UICheckButtonTemplate")
        tick:SetSize(20, 20)
        tick.label = tick:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tick.label:SetPoint("RIGHT", tick, "LEFT", 0, 1)
        tick.label:SetText("Announce")
        tick:SetHitRectInsets(-tick.label:GetStringWidth() - 2, 0, 0, 0)
        tick:SetScript("OnClick", function(self)
            BH.settings.qpAnnounce = self:GetChecked() and true or false
            BH:SaveSettings()
        end)
        tick:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("Announce quest progress")
            GameTooltip:AddLine("To party, instance or raid chat.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        tick:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    tick:ClearAllPoints()
    local anchor = header.MinimizeButton
    if anchor then
        tick:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
    else
        tick:SetPoint("RIGHT", header, "RIGHT", -24, 0)
    end
    tick:SetChecked(Settings().qpAnnounce and true or false)
    tick:Show()
end

-- ============================================================================
-- Auto Collapse
-- ============================================================================

local INSTANCE_KEYS = {
    none = "ocWorld", pvp = "ocBattleground", arena = "ocArena", party = "ocDungeon", raid = "ocRaid",
    scenario = "ocScenario", neighborhood = "ocHousing", interior = "ocHousing",
}

local function WantedState()
    local s = Settings()
    local function pick(key)
        local v = s[key]
        if v and v ~= "none" then return v end
    end
    local v = UnitAffectingCombat("player") and pick("ocCombat")
        or (UnitInVehicle and UnitInVehicle("player")) and pick("ocVehicle")
        or IsResting() and pick("ocResting")
    if v then return v end
    local _, instanceType = IsInInstance()
    local key = INSTANCE_KEYS[instanceType or "none"]
    return (key and pick(key)) or pick("ocDefault") or "none"
end

local folded -- "collapse" / "hide" / "keystone" while we have folded it, else nil
local savedAlpha
-- Tweaks' "Collapse Objectives in Mythic+" folds through here too
-- (QX.SetKeystoneFold): everything but the scenario section (the key's
-- timer). It used to call the tracker's own SetCollapsed, which wrote
-- isCollapsed from addon code; Blizzard's ForceExpand reads it when the key
-- timer starts, and the whole scenario update then ran tainted
-- (GetAuraDataByIndex refused in MawBuffs, user report 2026-11-27).
local keystoneFold = false

local function SetButtonsMouse(header, on)
    for _, key in ipairs({ "MinimizeButton", "FilterButton" }) do
        local b = header and header[key]
        if b and b.EnableMouse then b:EnableMouse(on) end
    end
end

-- Our state laid over whatever Blizzard just laid out.
local function Fold()
    local tracker = _G.ObjectiveTrackerFrame
    if not (tracker and folded) then return end
    if EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive() then return end
    -- A module mid-slide is skipped: its OnHide would run EndSlide, which
    -- then writes slide state from our code (taint). The next update folds it.
    local keep = folded == "keystone" and _G.ScenarioObjectiveTracker or nil
    for _, m in ipairs(tracker.modules or {}) do
        if m ~= keep and not m.slideInfo then m:Hide() end
    end
    -- Only the bottom edge, as Blizzard's own update moves it; its other
    -- anchors come from the XML and are left alone.
    local bottom = (keep and keep:IsShown() and keep:GetContentsHeight() > 0) and keep or tracker.Header
    if tracker.NineSlice and bottom then
        tracker.NineSlice:SetPoint("BOTTOM", bottom, "BOTTOM", 0, -(tracker.bottomModulePadding or 10))
    end
    if folded == "hide" then
        if not savedAlpha then savedAlpha = tracker:GetAlpha() end
        tracker:SetAlpha(0)
        SetButtonsMouse(tracker.Header, false)
    end
end

local function Unfold()
    local tracker = _G.ObjectiveTrackerFrame
    if not tracker then return end
    if savedAlpha then
        tracker:SetAlpha(savedAlpha)
        savedAlpha = nil
        SetButtonsMouse(tracker.Header, true)
    end
    if not folded then return end
    folded = nil
    -- Back to what Blizzard laid out: sections with something in them, unless
    -- the tracker is collapsed by its own button.
    local last
    local collapsed = tracker.IsCollapsed and tracker:IsCollapsed()
    for _, m in ipairs(tracker.modules or {}) do
        if not collapsed and m.GetContentsHeight and m:GetContentsHeight() > 0 then
            m:Show()
            last = m
        end
    end
    if tracker.NineSlice then
        tracker.NineSlice:SetPoint("BOTTOM", last or tracker.Header, "BOTTOM", 0, -(tracker.bottomModulePadding or 10))
    end
end

local hookedTracker
local function UpdateCollapse()
    local tracker = _G.ObjectiveTrackerFrame
    if not tracker then return end
    if not hookedTracker and tracker.Update then
        hookedTracker = true
        hooksecurefunc(tracker, "Update", Fold)
    end
    local state = CollapseOn() and WantedState() or "none"
    if keystoneFold and state ~= "hide" then state = "keystone" end
    if state == "collapse" or state == "hide" or state == "keystone" then
        if folded ~= state then
            Unfold()
            folded = state
        end
        Fold()
    elseif folded or savedAlpha then
        Unfold()
    end
end

function QX.SetKeystoneFold(on)
    on = on and true or false
    if on == keystoneFold then return end
    keystoneFold = on
    UpdateCollapse()
end

-- ============================================================================
-- Achievement screenshots
-- ============================================================================

local shooting
local function TakeScreenshot() _G.Screenshot() end

local function Screenshot(alreadyEarnedOnAccount)
    if not ScreenshotOn() or shooting then return end
    local s = Settings()
    if alreadyEarnedOnAccount and s.ssIgnoreAccount then return end
    shooting = true
    -- The banner slides in over about a second; several achievements at
    -- once get one picture.
    C_Timer.After(1.5, function()
        local hidden = s.ssShowUI ~= false and not UIParent:IsShown()
        if hidden then UIParent:Show() end
        RunNextFrame(function()
            TakeScreenshot()
            if s.ssChat ~= false then print("|cff33cc99Squizzumables:|r screenshot taken.") end
            shooting = false
        end)
    end)
end

-- ============================================================================
-- Apply
-- ============================================================================

function QX.Apply()
    BlizzardMessages()
    if ProgressOn() and not cache then cache = Snapshot() end
    if not ProgressOn() then cache = nil end
    UpdateTick()
    UpdateCollapse()
    ns.AchievementTracker.Apply()
end

-- ============================================================================
-- WindTools' Quest settings, copied once per profile
-- ============================================================================

local function ValidSound(name)
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    return type(name) == "string" and lsm and lsm:IsValid("sound", name) and name or nil
end

local function Seed()
    local s = BH.settings
    if not s or s.qxSeededFromWT then return end
    local q, wt = WTQuest()
    if not q then return end
    s.qxSeededFromWT = true

    local p = q.progress
    if type(p) == "table" then
        if p.enable then s.qpEnabled = true end
        if tonumber(p.disableIfRequiredOver) then s.qpMaxRequired = tonumber(p.disableIfRequiredOver) end
        if type(p.level) == "table" and p.level.hideOnCharacterLevel ~= nil then
            s.qpLevelHideSame = p.level.hideOnCharacterLevel and true or false
        end
        local fx = p.soundEffects
        if type(fx) == "table" and fx.enable then
            local function snd(sub, key)
                local t = fx[sub]
                if type(t) == "table" and t.enable then s[key] = ValidSound(t.sound) or s[key] end
            end
            snd("accept", "qpSoundAccept")
            snd("objectiveProgress", "qpSoundStep")
            snd("partialComplete", "qpSoundObjective")
            snd("fullyComplete", "qpSoundComplete")
        end
    end
    local a = type(wt) == "table" and type(wt.announcement) == "table" and wt.announcement or nil
    if a and a.enable and type(a.quest) == "table" and a.quest.enable then
        s.qpAnnounce = not a.quest.paused
        if a.quest.includeDetails ~= nil then s.qpAnnounceDetails = a.quest.includeDetails and true or false end
    end
    if type(q.switchButtons) == "table" and q.switchButtons.enable ~= nil then
        s.qpSwitch = q.switchButtons.enable and true or false
    end

    local c = q.autoCollapse
    if type(c) == "table" then
        if c.enable then s.ocEnabled = true end
        local map = { combat = "ocCombat", vehicle = "ocVehicle", resting = "ocResting", outOfInstance = "ocWorld",
                      battleground = "ocBattleground", arena = "ocArena", dungeon = "ocDungeon", raid = "ocRaid",
                      scenario = "ocScenario", neighborhood = "ocHousing", default = "ocDefault" }
        for from, to in pairs(map) do
            local v = c[from]
            if v == "none" or v == "expand" or v == "collapse" or v == "hide" then s[to] = v end
        end
    end

    local ss = q.achievementScreenshot
    if type(ss) == "table" then
        if ss.enable then s.ssEnabled = true end
        if ss.ignoreEarnedBefore ~= nil then s.ssIgnoreAccount = ss.ignoreEarnedBefore and true or false end
        if ss.forceShowUI ~= nil then s.ssShowUI = ss.forceShowUI and true or false end
        if ss.chatMessage ~= nil then s.ssChat = ss.chatMessage and true or false end
    end
    BH:SaveSettings()
end

function BH:ApplyQuestExtras()
    Seed()
    ns.AchievementTracker.Seed()
    QX.Apply()
end

-- ============================================================================
-- Events
-- ============================================================================

local pending
local function CompareSoon()
    if pending then return end
    pending = true
    C_Timer.After(0.2, function()
        pending = false
        Compare()
    end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE", "QUEST_TURNED_IN",
                     "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_UPDATE_RESTING",
                     "ZONE_CHANGED_NEW_AREA", "UNIT_ENTERED_VEHICLE", "UNIT_EXITED_VEHICLE",
                     "ACHIEVEMENT_EARNED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if event == "PLAYER_LOGIN" then
        BH:ApplyQuestExtras()
        C_Timer.After(5, function()
            cache = ProgressOn() and Snapshot() or nil
            ready = true
        end)
    elseif event == "QUEST_LOG_UPDATE" then
        if ProgressOn() then CompareSoon() end
    elseif event == "QUEST_TURNED_IN" then
        TurnedIn(a1)
    elseif event == "ACHIEVEMENT_EARNED" then
        Screenshot(a2)
    elseif event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" then
        if (not canaccessvalue or canaccessvalue(a1)) and a1 == "player" then UpdateCollapse() end
    else
        UpdateCollapse()
        if event == "PLAYER_ENTERING_WORLD" then UpdateTick() end
    end
end)
