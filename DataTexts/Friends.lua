-- DataTexts/Friends.lua
-- "Friends: N" -- character friends plus Battle.net friends online.
-- Hover: character friends (level, name, status, zone), then Battle.net
-- friends grouped by what they are playing. World of Warcraft friends on this
-- version of the game show level, character and Battle.net name; hold Shift
-- for their zone and realm (or, for other games, what they're doing).
-- Left-click opens the friends list. Right-click: Invite, Whisper, your own
-- status (available / busy / away) and your Battle.net broadcast.
--
-- The lists are rebuilt only when the tooltip or menu opens; the events just
-- mark them stale and update the count.

local addonName, ns = ...
local BH = ns.BH
local DT = ns.DataTexts
local S = BH.Secrets

local AFK_TAG = " |cffff9900<AFK>|r"
local DND_TAG = " |cffff3333<DND>|r"

-- Battle.net client codes (clientProgram) to names. Anything unknown shows
-- its code.
local CLIENTS = {
    WoW = "World of Warcraft", App = "Battle.net App", BSAp = "Battle.net Mobile",
    WTCG = "Hearthstone", Hero = "Heroes of the Storm", Pro = "Overwatch",
    OSI = "Diablo II", D3 = "Diablo III", Fen = "Diablo IV", ANBS = "Diablo Immortal",
    S1 = "StarCraft", S2 = "StarCraft II", W3 = "Warcraft III", RTRO = "Arcade Collection",
    GRY = "Warcraft Rumble", WLBY = "Crash Bandicoot 4",
    VIPR = "Call of Duty", ODIN = "Call of Duty", AUKS = "Call of Duty", LAZR = "Call of Duty",
    ZEUS = "Call of Duty", FORE = "Call of Duty",
}
local APPS = { App = true, BSAp = true }
local OTHER_WOW = "World of Warcraft (other versions)"

local function Bool(v) return (not S.IsSecret(v)) and v and true or false end

local chars, bnet = {}, {}
local dirty = true

local function Build()
    wipe(chars)
    wipe(bnet)
    dirty = false

    for i = 1, C_FriendList.GetNumFriends() or 0 do
        local f = C_FriendList.GetFriendInfoByIndex(i)
        local name = f and S.SafeString(f.name)
        if name and Bool(f.connected) then
            chars[#chars + 1] = {
                name  = name,
                short = Ambiguate(name, "short"),
                level = S.SafeNumber(f.level, 0),
                class = DT.ClassFile(S.SafeString(f.className)),
                zone  = S.SafeString(f.area, ""),
                afk   = Bool(f.afk), dnd = Bool(f.dnd),
                guid  = S.SafeString(f.guid),
            }
        end
    end

    local function Add(acc, g)
        local client = S.SafeString(g.clientProgram, "")
        local project = S.SafeNumber(g.wowProjectID)
        local entry = {
            bnetID   = acc.bnetAccountID,
            account  = S.SafeString(acc.accountName) or S.SafeString(acc.battleTag, "?"),
            afk      = Bool(acc.isAFK) or Bool(g.isGameAFK),
            dnd      = Bool(acc.isDND) or Bool(g.isGameBusy),
            client   = client,
            char     = S.SafeString(g.characterName),
            realm    = S.SafeString(g.realmName),
            level    = S.SafeNumber(g.characterLevel, 0),
            class    = DT.ClassFile(S.SafeString(g.className)),
            zone     = S.SafeString(g.areaName, ""),
            rich     = S.SafeString(g.richPresence, ""),
            guid     = S.SafeString(g.playerGuid),
            gameID   = g.gameAccountID,
            sameGame = client == "WoW" and project == WOW_PROJECT_ID,
        }
        if client == "WoW" then
            entry.group = entry.sameGame and CLIENTS.WoW or OTHER_WOW
        else
            entry.group = CLIENTS[client] or client
        end
        bnet[#bnet + 1] = entry
    end

    local numBNet = BNGetNumFriends() or 0
    for i = 1, numBNet do
        local acc = C_BattleNet.GetFriendAccountInfo(i)
        local g = acc and acc.gameAccountInfo
        if g and Bool(g.isOnline) then
            local n = C_BattleNet.GetFriendNumGameAccounts(i) or 0
            if n > 1 then
                for j = 1, n do
                    local other = C_BattleNet.GetFriendGameAccountInfo(i, j)
                    if other and Bool(other.isOnline) then Add(acc, other) end
                end
            else
                Add(acc, g)
            end
        end
    end

    table.sort(chars, function(a, b) return a.name < b.name end)
    -- This game first, then other WoW versions, other games, the apps last.
    local function Weight(e)
        if e.sameGame then return 1 end
        if e.client == "WoW" then return 2 end
        if APPS[e.client] then return 4 end
        return 3
    end
    table.sort(bnet, function(a, b)
        local wa, wb = Weight(a), Weight(b)
        if wa ~= wb then return wa < wb end
        if a.group ~= b.group then return a.group < b.group end
        return a.account < b.account
    end)
end

local function Lists()
    if dirty then Build() end
    return chars, bnet
end

local function Hidden(e)
    local s = BH.settings
    if s.dtFriendsHideAFK and e.afk then return true end
    if s.dtFriendsHideDND and e.dnd then return true end
    if e.client then
        if s.dtFriendsHideApp and APPS[e.client] then return true end
        if s.dtFriendsHideOtherGames and e.client ~= "WoW" and not APPS[e.client] then return true end
    end
    return false
end

local function Status(e)
    if e.afk then return AFK_TAG end
    if e.dnd then return DND_TAG end
    return ""
end

local function CharLabel(level, name, class)
    local lr, lg, lb = DT.LevelColor(level)
    local cr, cg, cb = DT.ClassColor(class)
    local lvl = (level and level > 0) and (DT.Hex(lr, lg, lb) .. level .. "|r ") or ""
    return lvl .. DT.Hex(cr, cg, cb) .. name .. "|r"
end

local function OnlineCounts()
    local charOnline = C_FriendList.GetNumOnlineFriends() or 0
    local numBNet, bnetOnline = BNGetNumFriends()
    return charOnline + (bnetOnline or 0), (C_FriendList.GetNumFriends() or 0) + (numBNet or 0)
end

local function OnEnter(_, tt)
    local online, total = OnlineCounts()
    tt:AddDoubleLine("Friends", string.format("%d/%d", online, total), 0.4, 0.78, 1, 0.4, 0.78, 1)
    if online == 0 then
        tt:AddLine("No friends online.", 1, 1, 1)
        return
    end
    local cl, bl = Lists()
    local shift = IsShiftKeyDown()
    local header

    local function Section(name)
        if header == name then return end
        header = name
        tt:AddLine(" ")
        tt:AddLine(name, 0.4, 0.78, 1)
    end

    for _, f in ipairs(cl) do
        if not Hidden(f) then
            Section("Character Friends")
            local zr, zg, zb = DT.ZoneColor(f.zone)
            local grouped = DT.InGroup(f.name) and " |cffaaaaaa*|r" or ""
            tt:AddDoubleLine(CharLabel(f.level, f.short, f.class) .. grouped .. Status(f), f.zone,
                1, 1, 1, zr, zg, zb)
        end
    end

    local myRealm = S.SafeString(GetRealmName())
    for _, e in ipairs(bl) do
        if not Hidden(e) then
            Section(e.group)
            if e.client == "WoW" and e.char and e.char ~= "" then
                local grouped = (e.sameGame and DT.InGroup(e.realm and (e.char .. "-" .. e.realm) or e.char))
                    and " |cffaaaaaa*|r" or ""
                tt:AddDoubleLine(CharLabel(e.level, e.char, e.class) .. grouped .. Status(e), e.account,
                    1, 1, 1, 0.93, 0.93, 0.93)
                if shift then
                    local zr, zg, zb = DT.ZoneColor(e.zone)
                    local same = e.realm and myRealm and e.realm == myRealm
                    local rr, rg, rb = same and 0.3 or 0.65, same and 1 or 0.65, same and 0.3 or 0.65
                    local left = e.sameGame and e.zone or e.rich
                    tt:AddDoubleLine("  " .. (left or ""), e.realm or "", zr, zg, zb, rr, rg, rb)
                end
            else
                tt:AddDoubleLine(e.account .. Status(e), shift and e.rich or "", 0.9, 0.9, 0.9, 0.65, 0.65, 0.65)
            end
        end
    end

    tt:AddLine(" ")
    tt:AddLine("Shift: zones and realms.  Right-click: invite, whisper, status.", 0.6, 0.6, 0.6)
end

StaticPopupDialogs["SQUIZZUMABLES_BN_BROADCAST"] = {
    text = "Your Battle.net broadcast:",
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = 127,
    editBoxWidth = 300,
    OnShow = function(dialog)
        local eb = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
        local _, _, _, current = BNGetInfo()
        if eb then eb:SetText(S.SafeString(current, "")); eb:HighlightText() end
    end,
    OnAccept = function(dialog)
        local eb = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
        if eb then BNSetCustomMessage(eb:GetText() or "") end
    end,
    EditBoxOnEnterPressed = function(eb)
        BNSetCustomMessage(eb:GetText() or "")
        eb:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(eb) eb:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function SetStatus(want)
    local afk, dnd = Bool(UnitIsAFK("player")), Bool(UnitIsDND("player"))
    if want == "available" then
        if afk then C_ChatInfo.SendChatMessage("", "AFK")
        elseif dnd then C_ChatInfo.SendChatMessage("", "DND") end
    elseif want == "dnd" then
        if not dnd then C_ChatInfo.SendChatMessage("", "DND") end
    elseif want == "afk" then
        if not afk then C_ChatInfo.SendChatMessage("", "AFK") end
    end
end

local function OnClick(slot, button)
    if button == "RightButton" then
        local cl, bl = Lists()
        MenuUtil.CreateContextMenu(slot, function(_, root)
            root:CreateTitle("Friends")
            local invite = root:CreateButton("Invite")
            local whisper = root:CreateButton("Whisper")
            if invite.SetScrollMode then invite:SetScrollMode(400) end
            if whisper.SetScrollMode then whisper:SetScrollMode(400) end
            local anyInvite, anyWhisper = false, false

            for _, f in ipairs(cl) do
                local label = CharLabel(f.level, f.short, f.class)
                if not DT.InGroup(f.name) then
                    invite:CreateButton(label, function() DT.Invite(f.name, f.guid) end)
                    anyInvite = true
                end
                whisper:CreateButton(label, function() DT.Whisper(f.name) end)
                anyWhisper = true
            end

            local whispered = {}
            for _, e in ipairs(bl) do
                if e.sameGame and e.char and e.gameID then
                    local full = e.realm and (e.char .. "-" .. e.realm) or e.char
                    if not DT.InGroup(full) then
                        invite:CreateButton(CharLabel(e.level, e.char, e.class) .. " (" .. e.account .. ")",
                            function() DT.InviteBNet(e.gameID, e.guid) end)
                        anyInvite = true
                    end
                end
                if e.bnetID and not whispered[e.bnetID] then
                    whispered[e.bnetID] = true
                    whisper:CreateButton(e.account, function() DT.WhisperBNet(e.account) end)
                    anyWhisper = true
                end
            end
            if not anyInvite then invite:CreateTitle("Nobody to invite") end
            if not anyWhisper then whisper:CreateTitle("Nobody online") end

            local status = root:CreateButton("Your Status")
            status:CreateButton("|cff2bc226Available|r", function() SetStatus("available") end)
            status:CreateButton("|cffe7e716Busy|r", function() SetStatus("dnd") end)
            status:CreateButton("|cffff0000Away|r", function() SetStatus("afk") end)
            root:CreateButton("Battle.net Broadcast", function() StaticPopup_Show("SQUIZZUMABLES_BN_BROADCAST") end)
        end)
        return
    end
    if InCombatLockdown() then return end
    if ToggleFriendsFrame then ToggleFriendsFrame(1) end
end

DT.Register("Friends", {
    label  = "Friends",
    events = { "PLAYER_ENTERING_WORLD", "FRIENDLIST_UPDATE", "BN_FRIEND_ACCOUNT_ONLINE",
        "BN_FRIEND_ACCOUNT_OFFLINE", "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_LIST_SIZE_CHANGED",
        "BN_CONNECTED", "BN_DISCONNECTED", "PLAYER_FLAGS_CHANGED" },
    onEvent = function(event)
        dirty = true
        if event == "PLAYER_ENTERING_WORLD" and C_FriendList.ShowFriends then C_FriendList.ShowFriends() end
        if event ~= "PLAYER_FLAGS_CHANGED" then DT.RefreshTooltip("Friends") end
    end,
    text = function()
        local online = OnlineCounts()
        return DT.Labelled("dtFriendsLabel", "Friends", online)
    end,
    onEnter = OnEnter,
    onClick = OnClick,
})
