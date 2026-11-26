-- Chat/Messages.lua
-- Chat stage 2: what happens to the messages themselves. Loaded before
-- Chat/Chat.lua, which puts these pages into its settings and calls in here.
--
-- SECRETS: on 12.x a chat message can arrive secret (encounters, keys) and any
-- Lua edit of it throws. Nearly everything here is a message event filter
-- (ChatFrameUtil.AddMessageEventFilter): Blizzard calls those through
-- securecallfunction and ONLY when every argument is readable (canaccessvalue),
-- so a secret message simply skips them and shows as Blizzard draws it. The
-- one exception is the AddMessage wrapper for short channel names and the
-- timestamp colour, which checks for a secret line itself and passes it through
-- untouched.
--
-- Written from what ElvUI's chat options do, never from its code.

local addonName, ns = ...
local BH = ns.BH
local S = BH.Secrets

local M = {}
ns.ChatMessages = M

local function Active() return ns.Chat and ns.Chat.active end
local function Settings() return BH.settings or {} end
local function Secret(v) return S and S.IsSecret and S.IsSecret(v) end

local MY_GUID

-- ============================================================================
-- Settings pages (Chat/Chat.lua adds them to its own)
-- ============================================================================

local function Sounds() return BH:BuildSoundDropdownItems() end

local function Alert(key, label)
    return { key = key, type = "dropdown", default = "None", items = Sounds, label = label,
        tip = "A sound when someone else writes in " .. label:lower() .. " chat." }
end

M.PAGES = {
    { key = "messages", label = "Messages", rows = {
        { type = "header", label = "LINKS" },
        { key = "chURLs", type = "check", default = true, label = "Clickable Web Links",
          tip = "Web addresses in chat turn into links; click one to copy it." },
        { key = "chHyperlinkHover", type = "check", default = true, label = "Tooltips on Hover",
          tip = "Hovering an item, spell or achievement link in chat shows its tooltip." },
        { type = "header", label = "CHANNELS AND TIME" },
        { key = "chShortChannels", type = "check", default = true, label = "Short Channel Names",
          tip = "[Guild] becomes [G], [Party Leader] [PL], [2. Trade - City] [2] and so on." },
        { key = "chTimeColored", type = "check", default = false, label = "Colour the Timestamps",
          tip = "Timestamps in a colour of their own." },
        { key = "chTimeColor", type = "color", default = { r = 0.7, g = 0.7, b = 0.7 }, label = "Timestamp Colour",
          when = function(s) return s.chTimeColored end },
        { type = "header", label = "NAMES" },
        { key = "chClassMentions", type = "check", default = true, label = "Class-colour Names in Messages",
          tip = "When a message mentions someone in your group, guild or recent chat, their name takes their "
            .. "class colour." },
        { key = "chRoleIcons", type = "check", default = true, label = "Role Icons",
          tip = "Tank, healer and damage icons before the names of people in your group." },
        { type = "header", label = "KEYWORDS" },
        { key = "chKeywords", type = "editbox", default = "%MYNAME%", label = "Keywords",
          tip = "Words to highlight, separated by commas. %MYNAME% is your character's name." },
        { key = "chKeywordColor", type = "color", default = { r = 1, g = 0.82, b = 0 }, label = "Keyword Colour" },
        { key = "chKeywordSound", type = "dropdown", default = "None", items = Sounds, label = "Keyword Sound",
          tip = "A sound when someone else's message has one of your keywords." },
        { type = "header", label = "ALERT SOUNDS" },
        Alert("chAlertWhisper", "Whisper"),
        Alert("chAlertGuild", "Guild"),
        Alert("chAlertOfficer", "Officer"),
        Alert("chAlertParty", "Party"),
        Alert("chAlertRaid", "Raid"),
        Alert("chAlertInstance", "Instance"),
        { key = "chNoAlertInCombat", type = "check", default = false, label = "No Sounds in Combat",
          tip = "Keyword and alert sounds stay quiet while you are in combat." },
        { type = "header", label = "SPAM" },
        { key = "chThrottle", type = "slider", default = 45, min = 0, max = 120, step = 5,
          label = "Hide Repeats For",
          tip = "Seconds during which the same message from the same person in Say, Yell or a channel is "
            .. "hidden. 0 to show every repeat." },
        { key = "chThrottleCombat", type = "check", default = true, label = "Show Repeats in Combat",
          tip = "Don't hide repeats while you are in combat.", when = function(s) return (s.chThrottle or 45) > 0 end },
    } },
    { key = "editbox", label = "Edit Box", rows = {
        { key = "chUseAltKey", type = "check", default = false, label = "Arrow Keys Need Alt",
          tip = "Off: the arrow keys move the cursor and Up/Down go through what you typed before. On: hold Alt "
            .. "for that (so the arrow keys still turn your character)." },
        { key = "chEditHistory", type = "slider", default = 20, min = 0, max = 100, step = 5,
          label = "Remembered Lines",
          tip = "How many lines you typed are kept for Up/Down, across reloads and characters." },
        { key = "chCountChars", type = "check", default = true, label = "Character Count",
          tip = "How many of the 255 characters you have used, at the right of the edit box." },
        { type = "header", label = "SCROLLING" },
        { key = "chScrollLines", type = "slider", default = 3, min = 1, max = 10, step = 1,
          label = "Lines per Mouse Wheel Turn", tip = "How far one turn of the mouse wheel scrolls." },
        { type = "header", label = "COPY" },
        { key = "chCopyButton", type = "check", default = true, label = "Copy Chat Button",
          tip = "A button at the top right of each panel opens that window's text to copy from. Lines that were "
            .. "hidden from add-ons (in an encounter) can't be copied." },
    } },
}

-- ============================================================================
-- Text helpers: protect links, textures and colour codes while rewriting
-- ============================================================================

local function Rewrite(msg, fn)
    local stash = {}
    local function keep(x)
        stash[#stash + 1] = x
        return "\001" .. #stash .. "\002"
    end
    local text = msg:gsub("|H.-|h.-|h", keep):gsub("|T.-|t", keep):gsub("|A.-|a", keep)
        :gsub("|K.-|k", keep):gsub("|c%x%x%x%x%x%x%x%x", keep):gsub("|cn[^:]*:", keep):gsub("|r", keep)
    text = fn(text, keep)
    -- Restored twice: a kept piece can hold an earlier placeholder.
    for _ = 1, 2 do
        text = text:gsub("\001(%d+)\002", function(n) return stash[tonumber(n)] end)
    end
    return text
end

local function Hex(c)
    local function B(v) return math.floor((v or 1) * 255 + 0.5) end
    return string.format("|cff%02x%02x%02x", B(c.r), B(c.g), B(c.b))
end

-- ============================================================================
-- Names: who is who (class colours, roles)
-- ============================================================================

local classOf = {}  -- lowercased short name -> class file
local roleOf = {}   -- GUID -> role

local function ShortLower(name)
    if not name or Secret(name) then return nil end
    return (name:match("^([^%-]+)") or name):lower()
end

local function NoteRoster()
    wipe(roleOf)
    local prefix, n = IsInRaid() and "raid" or "party", GetNumGroupMembers()
    local units = { "player" }
    for i = 1, n do units[#units + 1] = prefix .. i end
    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local guid, name, role = UnitGUID(unit), UnitName(unit), UnitGroupRolesAssigned(unit)
            local _, class = UnitClass(unit)
            if guid and role and canaccessvalue(guid) and canaccessvalue(role) then
                if role ~= "NONE" then roleOf[guid] = role end
            end
            local key = ShortLower(name)
            if key and class and not Secret(class) then classOf[key] = class end
        end
    end
end

local function NoteGuild()
    if not IsInGuild() then return end
    for i = 1, GetNumGuildMembers() do
        local name, _, _, _, _, _, _, _, _, _, class = GetGuildRosterInfo(i)
        local key = ShortLower(name)
        if key and class then classOf[key] = class end
    end
end

local function NoteAuthor(guid)
    if not guid or guid == "" or Secret(guid) then return end
    local _, class, _, _, _, name = GetPlayerInfoByGUID(guid)
    local key = ShortLower(name)
    if key and class then classOf[key] = class end
end

local ROLE_ICON = { TANK = "INLINE_TANK_ICON", HEALER = "INLINE_HEALER_ICON", DAMAGER = "INLINE_DAMAGER_ICON" }

local function SenderFilter(event, name, ...)
    if not (Active() and Settings().chRoleIcons ~= false) then return nil end
    local guid = select(12, ...)
    if not guid or Secret(guid) then return nil end
    local role = roleOf[guid]
    local icon = role and canaccessvalue(role) and _G[ROLE_ICON[role]]
    if not icon then return nil end
    return (icon:gsub(":16:16", ":12:12")) .. name
end

-- ============================================================================
-- The message filter
-- ============================================================================

local SOUND_KEY = {
    CHAT_MSG_WHISPER = "chAlertWhisper", CHAT_MSG_BN_WHISPER = "chAlertWhisper",
    CHAT_MSG_GUILD = "chAlertGuild", CHAT_MSG_OFFICER = "chAlertOfficer",
    CHAT_MSG_PARTY = "chAlertParty", CHAT_MSG_PARTY_LEADER = "chAlertParty",
    CHAT_MSG_RAID = "chAlertRaid", CHAT_MSG_RAID_LEADER = "chAlertRaid", CHAT_MSG_RAID_WARNING = "chAlertRaid",
    CHAT_MSG_INSTANCE_CHAT = "chAlertInstance", CHAT_MSG_INSTANCE_CHAT_LEADER = "chAlertInstance",
}
local THROTTLED = { CHAT_MSG_SAY = true, CHAT_MSG_YELL = true, CHAT_MSG_CHANNEL = true }

local EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM", "CHAT_MSG_CHANNEL", "CHAT_MSG_COMMUNITIES_CHANNEL",
}

-- A message is filtered once per window showing it; decisions and sounds go
-- by line ID so they happen once.
local lineDone = {}   -- lineID -> "hide" | "show"
local lastSaid = {}   -- author..message -> time
local lastSound = 0

local function Keywords(s)
    local list = {}
    local me = UnitName("player")
    for word in tostring(s.chKeywords or "%MYNAME%"):gmatch("[^,]+") do
        word = word:match("^%s*(.-)%s*$")
        if word == "%MYNAME%" then word = me end
        if word and word ~= "" then list[word:lower()] = true end
    end
    return list
end

local function PlayOnce(lineID, sound, s)
    if not sound or sound == "None" then return end
    if s.chNoAlertInCombat and InCombatLockdown() then return end
    local now = GetTime()
    if now - lastSound < 1 then return end
    lastSound = now
    BH:PlaySound(sound, "Master")
end

local URL_PATTERNS = {
    "https?://[^%s\001]+",
    "www%.[%w%-]+%.[^%s\001]+",
    "%d+%.%d+%.%d+%.%d+:?%d*/?[^%s\001]*",
}

local function MessageFilter(_, event, msg, author, ...)
    if not Active() or type(msg) ~= "string" then return false end
    local s = Settings()
    local lineID, guid = select(9, ...), select(10, ...)
    local mine = guid and guid == MY_GUID
    NoteAuthor(guid)

    local first = lineID and not lineDone[lineID]
    if lineID and lineDone[lineID] == "hide" then return true end

    -- Repeats in Say, Yell and channels.
    local wait = s.chThrottle or 45
    if first and THROTTLED[event] and wait > 0 and not mine
        and not (s.chThrottleCombat ~= false and InCombatLockdown()) then
        local key = tostring(author) .. "\001" .. msg
        local now = GetTime()
        if lastSaid[key] and now - lastSaid[key] < wait then
            lineDone[lineID] = "hide"
            return true
        end
        lastSaid[key] = now
    end

    local words = Keywords(s)
    local keyHex = Hex(s.chKeywordColor or { r = 1, g = 0.82, b = 0 })
    local hit = false
    local newMsg = Rewrite(msg, function(text, keep)
        if s.chURLs ~= false then
            for _, pat in ipairs(URL_PATTERNS) do
                text = text:gsub(pat, function(url)
                    return keep("|cff149bfd|Haddon:squizzumables:url:" .. url .. "|h[" .. url .. "]|h|r")
                end)
            end
        end
        return text:gsub("[%w\128-\255']+", function(word)
            if word:match("^%d+$") then return nil end
            local lower = word:lower()
            if words[lower] then
                hit = true
                return keyHex .. word .. "|r"
            end
            if s.chClassMentions ~= false then
                local class = classOf[lower] or classOf[(lower:gsub("'s$", ""))]
                local c = class and C_ClassColor and C_ClassColor.GetClassColor(class)
                if c then return c:WrapTextInColorCode(word) end
            end
            return nil
        end)
    end)

    if first then
        lineDone[lineID] = "show"
        if not mine then
            if hit then PlayOnce(lineID, s.chKeywordSound, s) end
            local alert = SOUND_KEY[event]
            if alert and not hit then PlayOnce(lineID, s[alert], s) end
        end
    end
    return false, newMsg, author, ...
end

-- Clicking one of our web links: a box with it selected, ready to copy.
StaticPopupDialogs["SQUIZZUMABLES_CHAT_URL"] = {
    text = "Copy the link (Ctrl+C):",
    button1 = CLOSE or "Close",
    hasEditBox = true, editBoxWidth = 320,
    OnShow = function(self, url)
        local eb = self.GetEditBox and self:GetEditBox() or self.editBox
        eb:SetText(url or "")
        eb:SetFocus()
        eb:HighlightText()
    end,
    EditBoxOnEscapePressed = function(eb) eb:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

local function OnLinkClicked(_, link)
    if type(link) ~= "string" or Secret(link) then return end
    local url = link:match("^addon:squizzumables:url:(.+)$")
    if url then StaticPopup_Show("SQUIZZUMABLES_CHAT_URL", nil, nil, url) end
end

-- ============================================================================
-- Short channel names and timestamp colour (AddMessage wrapper)
-- ============================================================================

local SHORT = {
    GUILD = "G", OFFICER = "O", PARTY = "P", PARTY_LEADER = "PL", PARTY_GUIDE = "PG",
    RAID = "R", RAID_LEADER = "RL", RAID_WARNING = "RW",
    INSTANCE_CHAT = "I", INSTANCE_CHAT_LEADER = "IL",
}
local shortByText = {}   -- "[Guild]" -> "[G]", read from the game's own (localised) strings
for kind, short in pairs(SHORT) do
    local fmt = _G["CHAT_" .. kind .. "_GET"]
    local label = type(fmt) == "string" and fmt:match("|h(%[.-%])|h")
    if label then shortByText[label] = "[" .. short .. "]" end
end

local originals = setmetatable({}, { __mode = "k" })

local function Shorten(msg, s)
    if s.chShortChannels ~= false then
        msg = msg:gsub("(|Hchannel:[^|]+|h)(%[.-%])(|h)", function(open, label, close)
            local short = shortByText[label] or label:match("^%[(%d+)%. ") and ("[" .. label:match("^%[(%d+)") .. "]")
            return open .. (short or label) .. close
        end)
    end
    if s.chTimeColored and ChatFrameUtil.GetTimestampFormat() then
        msg = msg:gsub("^(%d+:%d+:?%d*%s?[AaPp]?[Mm]?%s?)", function(stamp)
            return Hex(s.chTimeColor or {}) .. stamp .. "|r"
        end, 1)
    end
    return msg
end

local function Wrap(chat)
    if originals[chat] then return end
    local add = chat.AddMessage
    originals[chat] = add
    chat.AddMessage = function(self, msg, ...)
        if Active() and type(msg) == "string" and not Secret(msg) then
            local s = Settings()
            if s.chShortChannels ~= false or s.chTimeColored then
                local ok, out = pcall(Shorten, msg, s)
                if ok then msg = out end
            end
        end
        return add(self, msg, ...)
    end
end

-- ============================================================================
-- Per chat window
-- ============================================================================

local hooked = setmetatable({}, { __mode = "k" })
local counters = setmetatable({}, { __mode = "k" })

local LINK_TOOLTIP = { item = true, spell = true, achievement = true, quest = true, currency = true,
    enchant = true, talent = true, instancelock = true, mount = true, battlepet = true, keystone = true,
    transmogappearance = true, unit = false }

local function UpdateCount(eb)
    local fs = counters[eb]
    if not fs then return end
    local s = Settings()
    local text = eb:GetText() or ""
    if not Active() or s.chCountChars == false or text == "" then
        fs:SetText("")
        return
    end
    fs:SetText(strlenutf8(text) .. "/255")
end

function M.StyleChat(chat, s)
    local eb = chat.editBox
    if eb then
        eb:SetAltArrowKeyMode(s.chUseAltKey and true or false)
        if eb.SetHistoryLines then eb:SetHistoryLines(math.max(1, s.chEditHistory or 20)) end
    end
    if s.chShortChannels ~= false or s.chTimeColored then Wrap(chat) end

    if hooked[chat] then return end
    hooked[chat] = true

    chat:HookScript("OnHyperlinkEnter", function(self, link)
        if not (Active() and Settings().chHyperlinkHover ~= false) then return end
        if type(link) ~= "string" or Secret(link) then return end
        local kind = link:match("^(%a+):")
        if not (kind and LINK_TOOLTIP[kind]) or InCombatLockdown() then return end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Show() else GameTooltip:Hide() end
    end)
    chat:HookScript("OnHyperlinkLeave", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)

    -- More than one line per wheel turn (Blizzard scrolls one).
    chat:HookScript("OnMouseWheel", function(self, delta)
        local n = Active() and (Settings().chScrollLines or 3) or 1
        if n <= 1 or IsShiftKeyDown() or IsControlKeyDown() then return end
        for _ = 2, n do
            if delta > 0 then self:ScrollUp() else self:ScrollDown() end
        end
    end)

    if eb then
        local fs = eb:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("RIGHT", eb, "RIGHT", -6, 0)
        counters[eb] = fs
        eb:HookScript("OnTextChanged", UpdateCount)
        hooksecurefunc(eb, "AddHistoryLine", function(_, line) M.RememberLine(line) end)
    end
end

-- ============================================================================
-- Typed lines, kept across reloads (account-wide)
-- ============================================================================

local replaying

local function History()
    if not SquizzumablesDB then return nil end
    SquizzumablesDB.chatTyped = SquizzumablesDB.chatTyped or {}
    return SquizzumablesDB.chatTyped
end

function M.RememberLine(line)
    if replaying or not Active() or type(line) ~= "string" or Secret(line) or line == "" then return end
    local h, keep = History(), Settings().chEditHistory or 20
    if not h then return end
    if h[#h] ~= line then h[#h + 1] = line end
    while #h > keep do table.remove(h, 1) end
end

local function Replay()
    local h = History()
    if not h or #h == 0 then return end
    replaying = true
    for _, name in ipairs(CHAT_FRAMES or {}) do
        local eb = _G[name] and _G[name].editBox
        if eb then
            for _, line in ipairs(h) do eb:AddHistoryLine(line) end
        end
    end
    replaying = false
end

-- ============================================================================
-- Copy chat
-- ============================================================================

local copyFrame

local function CopyFrame()
    if copyFrame then return copyFrame end
    local f = CreateFrame("Frame", "SquizzumablesChatCopy", UIParent, "BackdropTemplate")
    f:SetSize(620, 380)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
    f:SetBackdropBorderColor(0, 0, 0, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -26)
    scroll:SetPoint("BOTTOMRIGHT", -30, 10)
    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(570)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(eb)
    f.editBox, f.scroll = eb, scroll
    tinsert(UISpecialFrames, "SquizzumablesChatCopy")
    f:Hide()
    copyFrame = f
    return f
end

local function Plain(text)
    text = text:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|K.-|k", "?")
        :gsub("|H.-|h(.-)|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]*:", ""):gsub("|r", "")
    return text
end

function M.Copy(chat)
    if not chat then return end
    local lines, hidden = {}, 0
    for i = 1, chat:GetNumMessages() do
        local text = chat:GetMessageInfo(i)
        if type(text) == "string" and not Secret(text) then
            lines[#lines + 1] = Plain(text)
        else
            hidden = hidden + 1
        end
    end
    if hidden > 0 then lines[#lines + 1] = "(" .. hidden .. " lines were hidden from add-ons and can't be copied)" end
    local f = CopyFrame()
    f:Show()
    f.editBox:SetText(table.concat(lines, "\n"))
    C_Timer.After(0, function() f.scroll:SetVerticalScroll(f.scroll:GetVerticalScrollRange()) end)
end

local copyButtons = {}

-- Called by Chat.lua's Apply with its two panels and the windows they hold.
function M.Apply(s, panels, windowFor)
    for side, panel in pairs(panels) do
        local b = copyButtons[side]
        if not b then
            b = CreateFrame("Button", nil, panel)
            b:SetSize(16, 16)
            b:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
            b:GetNormalTexture():SetVertexColor(0.8, 0.8, 0.8)
            b:SetHighlightTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up", "ADD")
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText("Copy Chat")
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", GameTooltip_Hide)
            b:SetScript("OnClick", function() M.Copy(windowFor(side)) end)
            copyButtons[side] = b
        end
        b:ClearAllPoints()
        b:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -5, -6)
        b:SetFrameLevel(panel:GetFrameLevel() + 20)
        b:SetFrameStrata("MEDIUM")
        b:SetShown(s.chCopyButton ~= false and windowFor(side) ~= nil)
    end
    for eb in pairs(counters) do UpdateCount(eb) end
end

-- ============================================================================
-- ElvUI's message settings, copied once per profile
-- ============================================================================

local ALERT_FROM_ELV = { WHISPER = "chAlertWhisper", GUILD = "chAlertGuild", OFFICER = "chAlertOfficer",
    PARTY = "chAlertParty", RAID = "chAlertRaid", INSTANCE = "chAlertInstance" }

function M.Seed(E)
    local s = BH.settings
    if not s or s.chMsgSeededFromElvUI then return end
    local db = E and E.db and E.db.chat
    if type(db) ~= "table" then return end
    s.chMsgSeededFromElvUI = true
    local function Bool(key, elv) if db[elv] ~= nil then s[key] = db[elv] and true or false end end
    Bool("chURLs", "url")
    Bool("chHyperlinkHover", "hyperlinkHover")
    Bool("chShortChannels", "shortChannels")
    Bool("chTimeColored", "useCustomTimeColor")
    Bool("chClassMentions", "classColorMentionsChat")
    Bool("chRoleIcons", "lfgIcons")
    Bool("chNoAlertInCombat", "noAlertInCombat")
    Bool("chThrottleCombat", "enableCombatRepeat")
    Bool("chUseAltKey", "useAltKey")
    Bool("chCountChars", "countCharacters")
    if db.hideCopyButton ~= nil then s.chCopyButton = not db.hideCopyButton end
    local tc = db.customTimeColor
    if type(tc) == "table" and tc.r then s.chTimeColor = { r = tc.r, g = tc.g, b = tc.b } end
    if tonumber(db.throttleInterval) then s.chThrottle = tonumber(db.throttleInterval) end
    if tonumber(db.editboxHistorySize) then s.chEditHistory = tonumber(db.editboxHistorySize) end
    if tonumber(db.numScrollMessages) then s.chScrollLines = tonumber(db.numScrollMessages) end
    -- ElvUI's own default keyword is its name; anything else was picked.
    if type(db.keywords) == "string" and db.keywords ~= "ElvUI" then s.chKeywords = db.keywords end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local function Sound(v) return type(v) == "string" and (v == "None" or (lsm and lsm:IsValid("sound", v))) and v or nil end
    s.chKeywordSound = Sound(db.keywordSound) or s.chKeywordSound
    if type(db.channelAlerts) == "table" then
        for elv, key in pairs(ALERT_FROM_ELV) do
            s[key] = Sound(db.channelAlerts[elv]) or s[key]
        end
    end
    BH:SaveSettings()
end

-- ============================================================================
-- Setup
-- ============================================================================

for _, event in ipairs(EVENTS) do ChatFrameUtil.AddMessageEventFilter(event, MessageFilter) end
if ChatFrameUtil.AddSenderNameFilter then ChatFrameUtil.AddSenderNameFilter(SenderFilter) end
EventRegistry:RegisterCallback("SetItemRef", OnLinkClicked, M)

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_ROLES_ASSIGNED")
ev:RegisterEvent("GUILD_ROSTER_UPDATE")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        MY_GUID = UnitGUID("player")
        NoteRoster()
        C_Timer.After(1, function() if Active() then Replay() end end)
    elseif event == "GUILD_ROSTER_UPDATE" then
        NoteGuild()
    else
        NoteRoster()
    end
end)

-- Old line decisions are only needed for a moment.
C_Timer.NewTicker(60, function()
    wipe(lineDone)
    local now, wait = GetTime(), (Settings().chThrottle or 45)
    for key, t in pairs(lastSaid) do
        if now - t > wait then lastSaid[key] = nil end
    end
end)
