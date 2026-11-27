-- Chat/ChatExtras.lua
-- Two things WindTools added to chat, replaced here:
--   * the chat bar: a strip of buttons over the left chat panel, one per
--     channel, that switch the chat box to that channel (plus a /roll)
--   * item links that show their item level, armour type and slot, and an
--     icon in front of item, spell, achievement, currency and keystone links
--
-- Loaded before Chat/Chat.lua, which adds these pages to its own and calls
-- CX.Apply. Both wait while WindTools' own versions are on, and WindTools'
-- settings are copied over once per profile (cxSeededFromWT). Written from
-- what WindTools' options do, never from its code.
--
-- TAINT NOTE (chat bar): picking a channel from addon code sets the chat box's
-- channel from addon code, which Blizzard counts as an addon touching it. In a
-- key or an encounter (chat messaging lockdown) a message sent on that channel
-- can then be refused, until the channel is picked by typing it (/p). WindTools'
-- bar has the same limit; ours refuses to switch during lockdown at least.
--
-- SECRETS: the link rewriting is a message event filter, which Blizzard only
-- calls when the whole message is readable (see Chat/Messages.lua).

local addonName, ns = ...
local BH = ns.BH

local CX = {}
ns.ChatExtras = CX

local function Settings() return BH.settings or {} end
local function Active() return ns.Chat and ns.Chat.active end

local function WT()
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") then return nil end
    local elv = _G["ElvUI"]
    local E = type(elv) == "table" and elv[1]
    return E and E.db and E.db.WT or nil
end

-- Whether WindTools' own chat bar / chat link is running (so ours waits).
local function WTDoes(what)
    local wt = WT()
    local db = wt and wt.social and wt.social[what]
    return type(db) == "table" and db.enable and true or false
end

local function Apply() if ns.Chat and ns.Chat.Apply then ns.Chat.Apply() end end

local function BarOn(s) return s.cbEnabled end
local function LinksOn(s) return s.clEnabled end

local function WaitNote(name)
    return "\n\nUses Squizzumables Chat, and waits while WindTools' " .. name .. " is on (WindTools > Social)."
end

-- ============================================================================
-- Channels on the bar
-- ============================================================================

local HOME, INST = LE_PARTY_CATEGORY_HOME, LE_PARTY_CATEGORY_INSTANCE

local function Leader()
    return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player") or IsEveryoneAssistant()
end

-- key, setting, slash command, ChatTypeInfo colour, letter, can you talk there
local CHANNELS = {
    { id = "SAY", key = "cbSay", cmd = "s", label = "Say", letter = "S" },
    { id = "YELL", key = "cbYell", cmd = "y", label = "Yell", letter = "Y" },
    { id = "EMOTE", key = "cbEmote", cmd = "e", label = "Emote", letter = "E" },
    { id = "PARTY", key = "cbParty", cmd = "p", label = "Party", letter = "P",
      can = function() return IsInGroup(HOME) end },
    { id = "INSTANCE_CHAT", key = "cbInstance", cmd = "i", label = "Instance", letter = "I",
      can = function() return IsInGroup(INST) end },
    { id = "RAID", key = "cbRaid", cmd = "raid", label = "Raid", letter = "R",
      can = function() return IsInRaid() end },
    { id = "RAID_WARNING", key = "cbRaidWarning", cmd = "rw", label = "Raid Warning", letter = "RW",
      can = function() return IsInRaid() and Leader() end },
    { id = "GUILD", key = "cbGuild", cmd = "g", label = "Guild", letter = "G",
      can = function() return IsInGuild() end },
    { id = "OFFICER", key = "cbOfficer", cmd = "o", label = "Officer", letter = "O",
      can = function() return IsInGuild() and C_GuildInfo.IsGuildOfficer and C_GuildInfo.IsGuildOfficer() end },
}

-- WindTools' defaults, which the user's main profile runs on.
local DEFAULT_ON = { cbSay = true, cbYell = true, cbParty = true, cbInstance = true, cbRaid = true, cbGuild = true }

-- ============================================================================
-- Settings pages
-- ============================================================================

local function ChannelRow(c)
    return { key = c.key, type = "check", default = DEFAULT_ON[c.key] or false, label = c.label, when = BarOn }
end

local barRows = {
    { key = "cbEnabled", type = "check", default = false, label = "Show the Chat Bar",
      tip = "A strip of buttons over the left chat panel, one for each channel. Click one to start a message "
        .. "there, keeping what you have typed. Place it with Edit Mode." .. WaitNote("Chat Bar") },
    { key = "cbStyle", type = "dropdown", default = "BLOCK", label = "Style", when = BarOn,
      items = { { text = "Coloured blocks", value = "BLOCK" }, { text = "Letters", value = "TEXT" } },
      tip = "Blocks in each channel's chat colour, or the channel's letter." },
    { key = "cbWidth", type = "slider", default = 40, min = 4, max = 100, step = 1, label = "Button Width", when = BarOn },
    { key = "cbHeight", type = "slider", default = 5, min = 2, max = 40, step = 1, label = "Button Height", when = BarOn },
    { key = "cbSpacing", type = "slider", default = 5, min = 0, max = 20, step = 1, label = "Spacing", when = BarOn },
    { key = "cbVertical", type = "check", default = false, label = "Vertical", when = BarOn },
    { key = "cbAutoHide", type = "check", default = false, label = "Only Channels You Can Use", when = BarOn,
      tip = "Hide Party out of a group, Guild with no guild, and so on." },
    { key = "cbMouseOver", type = "check", default = false, label = "Only Show on Mouse-over", when = BarOn },
    { key = "cbFontSize", type = "slider", default = 12, min = 8, max = 24, step = 1, label = "Letter Size",
      when = function(s) return s.cbEnabled and s.cbStyle == "TEXT" end },
    { type = "header", label = "BUTTONS" },
}
for _, c in ipairs(CHANNELS) do barRows[#barRows + 1] = ChannelRow(c) end
barRows[#barRows + 1] = { key = "cbRoll", type = "check", default = true, label = "Roll", when = BarOn,
    tip = "Rolls 1-100." }
barRows[#barRows + 1] = { key = "cbCommunity", type = "editbox", default = "", label = "Community Channel",
    when = BarOn, tip = "The full name of a community channel to add a button for. Leave empty for none." }

local linkRows = {
    { key = "clEnabled", type = "check", default = false, label = "Add Details to Links",
      tip = "Item links in chat show their item level (and, for armour and weapons, what kind and which "
        .. "slot), and links get an icon in front." .. WaitNote("Chat Link") },
    { key = "clLevel", type = "check", default = true, label = "Item Level", when = LinksOn,
      tip = "For gear only, as the item's tooltip shows it." },
    { key = "clSlot", type = "check", default = true, label = "Armour Type and Slot", when = LinksOn,
      tip = "Plate Chest, Ring, Staff..." },
    { key = "clIcon", type = "check", default = true, label = "Icons", when = LinksOn,
      tip = "In front of item, spell, achievement, currency and keystone links." },
    { key = "clIconSize", type = "slider", default = 16, min = 10, max = 32, step = 1, label = "Icon Size",
      when = function(s) return s.clEnabled and s.clIcon ~= false end },
}

-- Chat/Chat.lua unpacks ns.ChatMessages.PAGES at the end of its own pages.
local pages = ns.ChatMessages and ns.ChatMessages.PAGES
if pages then
    pages[#pages + 1] = { key = "chatbar", label = "Chat Bar", rows = barRows }
    pages[#pages + 1] = { key = "chatlinks", label = "Links", rows = linkRows }
end

-- ============================================================================
-- The chat bar
-- ============================================================================

local bar, mover
local buttons = {}

local function EditBox()
    return (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox) or _G.ChatFrame1EditBox
end

local function OpenWith(cmd)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        UIErrorsFrame:AddMessage("Pick the channel by typing it while chat is locked down.", 1, 0.3, 0.3)
        return
    end
    local eb = EditBox()
    local typed = eb and eb:GetText() or ""
    if type(typed) ~= "string" or not canaccessvalue(typed) then typed = "" end
    -- What was typed after an earlier slash command is kept, the command dropped.
    typed = typed:gsub("^/%S+%s*", "")
    ChatFrameUtil.OpenChat("/" .. cmd .. " " .. typed, DEFAULT_CHAT_FRAME)
end

local function CommunityChannel(name)
    if not (name and name ~= "") then return nil end
    local list = { GetChannelList() }
    -- GetChannelList: id, name, disabled, ...
    for i = 1, #list, 3 do
        local id, chName = list[i], list[i + 1]
        local club = type(chName) == "string" and chName:match("^Community:(%d+):")
        local info = club and C_Club.GetClubInfo(club)
        if info and info.name == name then return id end
    end
    return nil
end

local function FadeTo(a)
    if not bar then return end
    if (Settings()).cbMouseOver and not BH.unlockMode then bar:SetAlpha(a) end
end

local function SavePosition()
    local s = BH.settings
    if not (s and bar and bar:GetLeft()) then return end
    local scale = bar:GetEffectiveScale() / UIParent:GetEffectiveScale()
    s.cbPosition = { point = "BOTTOMLEFT", relPoint = "BOTTOMLEFT",
        x = math.floor(bar:GetLeft() * scale + 0.5), y = math.floor(bar:GetBottom() * scale + 0.5) }
    BH:SaveSettings()
end

local function Bar()
    if bar then return bar end
    bar = CreateFrame("Frame", "SquizzumablesChatBar", UIParent)
    bar:SetFrameStrata("LOW")
    bar:SetFrameLevel(5)
    bar:SetMovable(true)
    bar:SetClampedToScreen(true)
    bar:EnableMouse(true)
    bar:SetScript("OnEnter", function() FadeTo(1) end)
    bar:SetScript("OnLeave", function() FadeTo(0) end)

    mover = CreateFrame("Frame", "SquizzumablesChatBarMover", UIParent)
    mover:SetAllPoints(bar)
    mover:SetFrameStrata("HIGH")
    mover:RegisterForDrag("LeftButton")
    mover:SetScript("OnDragStart", function()
        if InCombatLockdown() or not BH.unlockMode then return end
        BH:GridStartMoving(bar)
    end)
    mover:SetScript("OnDragStop", function()
        BH:GridStopMoving(bar)
        SavePosition()
        Apply()
    end)
    mover:Hide()
    BH.chatBarMover = mover
    return bar
end

local function Button(id)
    local b = buttons[id]
    if b then return b end
    b = CreateFrame("Button", nil, Bar())
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.block = b:CreateTexture(nil, "ARTWORK")
    b.block:SetPoint("TOPLEFT", 1, -1)
    b.block:SetPoint("BOTTOMRIGHT", -1, 1)
    b.edge = b:CreateTexture(nil, "BACKGROUND")
    b.edge:SetAllPoints()
    b.edge:SetColorTexture(0, 0, 0, 1)
    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetPoint("CENTER")
    b:SetScript("OnEnter", function(self)
        FadeTo(1)
        local r, g, bl = ns.Theme.RGBA("accent")
        self.edge:SetColorTexture(r, g, bl, 1)
        GameTooltip:SetOwner(self, "ANCHOR_TOP", 0, 6)
        GameTooltip:SetText(self.title or "")
        for _, line in ipairs(self.tips or {}) do GameTooltip:AddLine(line, 1, 1, 1) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        FadeTo(0)
        self.edge:SetColorTexture(0, 0, 0, 1)
        GameTooltip:Hide()
    end)
    buttons[id] = b
    return b
end

local function ChannelColour(id)
    local info = ChatTypeInfo and ChatTypeInfo[id]
    if info and info.r then return info.r, info.g, info.b end
    return 1, 1, 1
end

local function FontPath(s)
    local name = s.chFont
    if name and name ~= "__default" then
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        local path = lsm and lsm:Fetch("font", name, true)
        if path then return path end
    end
    return STANDARD_TEXT_FONT
end

local function Dress(b, s, r, g, bl, letter)
    if s.cbStyle == "TEXT" then
        b.block:Hide()
        b.edge:SetShown(false)
        b.text:SetFont(FontPath(s), s.cbFontSize or 12, "OUTLINE")
        b.text:SetTextColor(r, g, bl)
        b.text:SetText(letter)
        b.text:Show()
    else
        b.block:SetColorTexture(r, g, bl, 1)
        b.block:Show()
        b.edge:Show()
        b.text:Hide()
    end
end

local function LayoutBar(s)
    local list = {}
    for _, c in ipairs(CHANNELS) do
        local on = s[c.key]
        if on == nil then on = DEFAULT_ON[c.key] end
        if on and not (s.cbAutoHide and c.can and not c.can()) then list[#list + 1] = c end
    end
    for _, c in ipairs(CHANNELS) do
        local b = Button(c.id)
        b.title = c.label
        b.tips = nil
        b:SetScript("OnClick", function(_, mouse) if mouse == "LeftButton" then OpenWith(c.cmd) end end)
        local r, g, bl = ChannelColour(c.id)
        Dress(b, s, r, g, bl, c.letter)
        b:Hide()
    end
    local community = s.cbCommunity
    if type(community) == "string" and community ~= "" then
        local b = Button("COMMUNITY")
        b.title = community
        b.tips = { "Left-click: write there" }
        b:SetScript("OnClick", function(_, mouse)
            if mouse ~= "LeftButton" then return end
            local id = CommunityChannel(community)
            if id then
                OpenWith(tostring(id))
            else
                print("|cff33cc99Squizzumables:|r No community channel called " .. community .. ". Use its full name.")
            end
        end)
        local r, g, bl = ChannelColour("CHANNEL")
        Dress(b, s, r, g, bl, "C")
        list[#list + 1] = { id = "COMMUNITY" }
    elseif buttons.COMMUNITY then
        buttons.COMMUNITY:Hide()
    end
    if s.cbRoll ~= false then
        local b = Button("ROLL")
        b.title = "Roll"
        b.tips = { "Left-click: roll 1-100" }
        b:SetScript("OnClick", function(_, mouse) if mouse == "LeftButton" then RandomRoll(1, 100) end end)
        Dress(b, s, 1, 0.82, 0, "|TInterface\\Buttons\\UI-GroupLoot-Dice-Up:0|t")
        list[#list + 1] = { id = "ROLL" }
    elseif buttons.ROLL then
        buttons.ROLL:Hide()
    end

    local w, h, gap = s.cbWidth or 40, s.cbHeight or 5, s.cbSpacing or 5
    if s.cbStyle == "TEXT" then h = math.max(h, (s.cbFontSize or 12) + 4) end
    local x, y = 0, 0
    for _, c in ipairs(list) do
        local b = buttons[c.id]
        b:SetSize(w, h)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", bar, "TOPLEFT", x, y)
        b:Show()
        if s.cbVertical then y = y - h - gap else x = x + w + gap end
    end
    local n = math.max(#list, 1)
    if s.cbVertical then
        bar:SetSize(w, n * h + (n - 1) * gap)
    else
        bar:SetSize(n * w + (n - 1) * gap, h)
    end
end

local function ApplyBar(s, panels)
    if not (Active() and s.cbEnabled and not WTDoes("chatBar")) then
        if bar then bar:Hide() end
        if mover then mover:Hide() end
        return
    end
    Bar()
    LayoutBar(s)
    bar:ClearAllPoints()
    local pos = s.cbPosition
    if pos then
        bar:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    elseif panels and panels.Left then
        bar:SetPoint("BOTTOMLEFT", panels.Left, "TOPLEFT", 6, 3)
    else
        bar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 10, 200)
    end
    bar:SetAlpha((s.cbMouseOver and not BH.unlockMode) and 0 or 1)
    bar:Show()
    mover:SetShown(BH.unlockMode and true or false)
    mover:EnableMouse(BH.unlockMode and true or false)
end

function CX.Nudge(dx, dy)
    local s = BH.settings
    if not (s and bar and bar:GetLeft()) then return end
    if not s.cbPosition then SavePosition() end
    local pos = s.cbPosition
    s.cbPosition = { point = pos.point, relPoint = pos.relPoint, x = (pos.x or 0) + dx, y = (pos.y or 0) + dy }
    BH:SaveSettings()
    Apply()
end

-- ============================================================================
-- Links
-- ============================================================================

local MATCH_LEVEL = ITEM_LEVEL and ITEM_LEVEL:gsub("%%d", "(%%d+)")
local MATCH_LEVEL_ALT = ITEM_LEVEL_ALT and ITEM_LEVEL_ALT:gsub("%%d(%s?)%(%%d%)", "%%d+%1%%((%%d+)%%)")
local MATCH_MIN = ITEM_MIN_LEVEL and ITEM_MIN_LEVEL:gsub("%%d", "(%%d+)")

local function LevelFromText(text)
    if type(text) ~= "string" or not canaccessvalue(text) then return nil end
    local v = MATCH_LEVEL_ALT and text:match(MATCH_LEVEL_ALT)
    if not v and MATCH_LEVEL and not (MATCH_MIN and text:match(MATCH_MIN)) then v = text:match(MATCH_LEVEL) end
    return tonumber(v)
end

-- The level the item's tooltip shows (upgrades and scaling included).
local levelCache = {}
local function ItemLevel(link)
    if levelCache[link] then return levelCache[link] end
    local data = C_TooltipInfo and C_TooltipInfo.GetHyperlink and C_TooltipInfo.GetHyperlink(link)
    local level
    for _, line in ipairs(data and data.lines or {}) do
        level = LevelFromText(line.leftText) or LevelFromText(line.rightText)
        if level then break end
    end
    -- Not cached until the tooltip knows (an uncached item comes back empty).
    if level then levelCache[link] = level end
    return level or (C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link))
end

local ARMOUR_SLOTS = { INVTYPE_HEAD = true, INVTYPE_SHOULDER = true, INVTYPE_CHEST = true, INVTYPE_ROBE = true,
    INVTYPE_WRIST = true, INVTYPE_HAND = true, INVTYPE_WAIST = true, INVTYPE_LEGS = true, INVTYPE_FEET = true }

local function Icon(tex, s)
    if not tex then return "" end
    local size = s.clIconSize or 16
    return "|T" .. tex .. ":" .. size .. ":" .. size .. ":0:0:64:64:5:59:5:59|t "
end

local function ItemLink(link, s)
    local itemID, _, subType, equipLoc, icon, classID = C_Item.GetItemInfoInstant(link)
    if not itemID then return link end
    local gear = equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
    local level, slot
    if gear and s.clLevel ~= false then level = ItemLevel(link) end
    if gear and s.clSlot ~= false then
        local where = _G[equipLoc]
        if classID == Enum.ItemClass.Armor and ARMOUR_SLOTS[equipLoc] and subType and subType ~= "" then
            slot = subType .. " " .. (where or "")
        elseif classID == Enum.ItemClass.Weapon then
            slot = subType or where
        else
            slot = where
        end
    end
    local prefix = level and slot and (level .. " " .. slot) or level or slot
    if prefix then link = link:gsub("|h%[(.-)%]|h", "|h[" .. prefix .. ": %1]|h", 1) end
    if s.clIcon ~= false then link = Icon(icon, s) .. link end
    return link
end

local function WithIcon(tex, link, s)
    if s.clIcon == false or not tex then return link end
    return Icon(tex, s) .. link
end

local function LinkFilter(_, _, msg, ...)
    local s = Settings()
    if not (Active() and s.clEnabled) or type(msg) ~= "string" or WTDoes("chatLink") then return false end
    if not canaccessvalue(msg) then return false end
    msg = msg:gsub("(|Hitem:%d+:.-|h.-|h)", function(link) return ItemLink(link, s) end)
    msg = msg:gsub("(|Hkeystone:%d+:(%d+):.-|h.-|h)", function(link, mapID)
        local tex = C_ChallengeMode and C_ChallengeMode.GetMapUIInfo and select(4, C_ChallengeMode.GetMapUIInfo(tonumber(mapID)))
        return WithIcon(tex, link, s)
    end)
    msg = msg:gsub("(|Hspell:(%d+):.-|h.-|h)", function(link, id)
        return WithIcon(C_Spell.GetSpellTexture(tonumber(id)), link, s)
    end)
    msg = msg:gsub("(|Hachievement:(%d+):.-|h.-|h)", function(link, id)
        return WithIcon(select(10, GetAchievementInfo(tonumber(id))), link, s)
    end)
    msg = msg:gsub("(|Hcurrency:(%d+):.-|h.-|h)", function(link, id)
        local info = C_CurrencyInfo.GetCurrencyInfo(tonumber(id))
        return WithIcon(info and info.iconFileID, link, s)
    end)
    return false, msg, ...
end

local LINK_EVENTS = { "CHAT_MSG_ACHIEVEMENT", "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM",
    "CHAT_MSG_CHANNEL", "CHAT_MSG_COMMUNITIES_CHANNEL", "CHAT_MSG_EMOTE", "CHAT_MSG_GUILD",
    "CHAT_MSG_GUILD_ACHIEVEMENT", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_LOOT",
    "CHAT_MSG_OFFICER", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_RAID_WARNING", "CHAT_MSG_SAY", "CHAT_MSG_TRADESKILLS", "CHAT_MSG_WHISPER",
    "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_YELL" }
for _, event in ipairs(LINK_EVENTS) do ChatFrameUtil.AddMessageEventFilter(event, LinkFilter) end

-- ============================================================================
-- Apply, WindTools copy
-- ============================================================================

function CX.Apply(s, panels)
    ApplyBar(s, panels)
end

local FROM_WT = { SAY = "cbSay", YELL = "cbYell", EMOTE = "cbEmote", PARTY = "cbParty", INSTANCE = "cbInstance",
    RAID = "cbRaid", RAID_WARNING = "cbRaidWarning", GUILD = "cbGuild", OFFICER = "cbOfficer" }

function CX.Seed()
    local s = BH.settings
    local wt = WT()
    if not (s and wt and wt.social) or s.cxSeededFromWT then return end
    s.cxSeededFromWT = true
    local b = wt.social.chatBar
    if type(b) == "table" then
        s.cbEnabled = b.enable and true or false
        if b.style == "TEXT" or b.style == "BLOCK" then s.cbStyle = b.style end
        if tonumber(b.buttonWidth) then s.cbWidth = tonumber(b.buttonWidth) end
        if tonumber(b.buttonHeight) then s.cbHeight = tonumber(b.buttonHeight) end
        if tonumber(b.spacing) then s.cbSpacing = tonumber(b.spacing) end
        s.cbVertical = b.orientation == "VERTICAL"
        s.cbAutoHide = b.autoHide and true or false
        s.cbMouseOver = b.mouseOver and true or false
        if type(b.font) == "table" and tonumber(b.font.size) then s.cbFontSize = tonumber(b.font.size) end
        local ch = type(b.channels) == "table" and b.channels or {}
        for wtKey, key in pairs(FROM_WT) do
            if type(ch[wtKey]) == "table" and ch[wtKey].enable ~= nil then s[key] = ch[wtKey].enable and true or false end
        end
        if type(ch.roll) == "table" and ch.roll.enable ~= nil then s.cbRoll = ch.roll.enable and true or false end
        if type(ch.community) == "table" and ch.community.enable and type(ch.community.name) == "string" then
            s.cbCommunity = ch.community.name
        end
        -- Where WindTools' mover left it.
        local E = _G["ElvUI"] and _G["ElvUI"][1]
        local m = E and E.db and E.db.movers and E.db.movers.WTChatBarMover
        if type(m) == "string" then
            local pt, _, rel, x, y = strsplit(",", m)
            if pt and rel and tonumber(x) and tonumber(y) then
                s.cbPosition = { point = pt, relPoint = rel, x = tonumber(x), y = tonumber(y) }
            end
        end
    end
    local l = wt.social.chatLink
    if type(l) == "table" then
        s.clEnabled = l.enable and true or false
        if l.level ~= nil then s.clLevel = l.level and true or false end
        if l.armorCategory ~= nil or l.weaponCategory ~= nil then
            s.clSlot = (l.armorCategory or l.weaponCategory) and true or false
        end
        if l.icon ~= nil then s.clIcon = l.icon and true or false end
        if tonumber(l.iconHeight) then s.clIconSize = tonumber(l.iconHeight) end
    end
    BH:SaveSettings()
end

-- Group and guild changes for "Only Channels You Can Use".
local ev = CreateFrame("Frame")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_GUILD_UPDATE")
local pending
ev:SetScript("OnEvent", function()
    local s = Settings()
    if not (bar and s.cbEnabled and s.cbAutoHide) or pending then return end
    pending = true
    C_Timer.After(0.2, function()
        pending = false
        ApplyBar(Settings(), ns.Chat and ns.Chat.panels)
    end)
end)
