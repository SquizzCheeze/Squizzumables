-- DataTexts/Guild.lua
-- "Guild: N" -- online members (mobile chat counted, as ElvUI does).
-- Hover: guild name and online/total, your rank, the message of the day, then
-- each online member: level, name, status and zone (green when it is your
-- zone). Hold Shift for each member's rank and notes, sorted by rank.
-- Left-click opens the guild window; right-click opens Invite / Whisper menus.
--
-- The roster arrives a moment after C_GuildInfo.GuildRoster() asks for it
-- (GUILD_ROSTER_UPDATE), so hovering asks again and an open tooltip redraws
-- when the answer lands. The game throttles the request itself.
--
-- Names, zones and notes go through BH.Secrets: in a restricted chat state
-- (some instances) they can arrive secret, and a secret member is left out
-- rather than compared or concatenated.

local addonName, ns = ...
local BH = ns.BH
local DT = ns.DataTexts
local S = BH.Secrets

local members = {}
local dirty = true

local AFK_TAG = " |cffff9900<AFK>|r"
local DND_TAG = " |cffff3333<DND>|r"

local function Bool(v) return (not S.IsSecret(v)) and v and true or false end

-- At most one roster request per 15s from us. The tooltip redraws on
-- GUILD_ROSTER_UPDATE, and a redraw that asked again would answer itself
-- in a loop.
local lastRequest = 0
local function RequestRoster()
    if not IsInGuild() then return end
    local now = GetTime()
    if now - lastRequest < 15 then return end
    lastRequest = now
    C_GuildInfo.GuildRoster()
end

local function BuildRoster()
    wipe(members)
    dirty = false
    if not IsInGuild() then return end
    local total = GetNumGuildMembers() or 0
    for i = 1, total do
        local name, rank, rankIndex, level, _, zone, note, officerNote, online, status,
              classFile, _, _, isMobile, _, _, guid = GetGuildRosterInfo(i)
        name = S.SafeString(name)
        local isOnline, mobile = Bool(online), Bool(isMobile)
        if name and (isOnline or mobile) then
            members[#members + 1] = {
                name      = name,
                short     = Ambiguate(name, "short"),
                full      = Ambiguate(name, "none"),
                rank      = S.SafeString(rank, ""),
                rankIndex = S.SafeNumber(rankIndex, 99),
                level     = S.SafeNumber(level, 0),
                zone      = (mobile and not isOnline) and (_G.REMOTE_CHAT or "Mobile") or S.SafeString(zone, ""),
                note      = S.SafeString(note, ""),
                officer   = S.SafeString(officerNote, ""),
                online    = isOnline,
                mobileOnly = mobile and not isOnline,
                status    = S.SafeNumber(status, 0),
                class     = S.SafeString(classFile),
                guid      = S.SafeString(guid),
            }
        end
    end
end

local function Members()
    if dirty then BuildRoster() end
    return members
end

local function SortBy(byRank)
    table.sort(members, function(a, b)
        if byRank and a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
        return a.name < b.name
    end)
end

local function StatusTag(m)
    if m.status == 1 then return AFK_TAG end
    if m.status == 2 then return DND_TAG end
    return ""
end

local function MemberLabel(m)
    local lr, lg, lb = DT.LevelColor(m.level)
    local cr, cg, cb = DT.ClassColor(m.class)
    return DT.Hex(lr, lg, lb) .. m.level .. "|r " .. DT.Hex(cr, cg, cb) .. m.short .. "|r"
end

local function OnEnter(_, tt)
    if not IsInGuild() then
        tt:AddLine("You are not in a guild.", 1, 1, 1)
        return
    end
    RequestRoster()
    local list = Members()
    local shift = IsShiftKeyDown()
    SortBy(shift)

    local total, online = GetNumGuildMembers()
    local guildName, rankName = GetGuildInfo("player")
    guildName = S.SafeString(guildName, "Guild")
    tt:AddDoubleLine(guildName, string.format("%d/%d", online or #list, total or 0),
        0.4, 0.78, 1, 0.4, 0.78, 1)
    rankName = S.SafeString(rankName)
    if rankName then tt:AddLine(rankName, 0.4, 0.78, 1) end

    if BH.settings.dtGuildShowMOTD ~= false then
        local motd = S.SafeString(C_GuildInfo.GetMOTD and C_GuildInfo.GetMOTD())
        if motd and motd ~= "" then
            tt:AddLine(" ")
            tt:AddLine("Message of the day: " .. motd, 0.75, 0.9, 1, true)
        end
    end
    tt:AddLine(" ")

    local limit = BH.settings.dtGuildMaxLines or 30
    for i, m in ipairs(list) do
        if limit > 0 and i > limit then
            tt:AddLine(string.format("and %d more online", #list - limit), 0.75, 0.9, 1)
            break
        end
        local zr, zg, zb = DT.ZoneColor(m.zone)
        local grouped = DT.InGroup(m.full) and " |cffaaaaaa*|r" or ""
        if shift then
            local cr, cg, cb = DT.ClassColor(m.class)
            tt:AddDoubleLine(m.short .. " |cffaaaaaa" .. m.rank .. "|r", m.zone, cr, cg, cb, zr, zg, zb)
            if m.note ~= "" then tt:AddLine("  " .. m.note, 0.75, 0.9, 1, true) end
            if m.officer ~= "" then tt:AddLine("  " .. m.officer, 0.3, 1, 0.3, true) end
        else
            tt:AddDoubleLine(MemberLabel(m) .. grouped .. StatusTag(m), m.zone, 1, 1, 1, zr, zg, zb)
        end
    end

    tt:AddLine(" ")
    tt:AddLine("Shift: ranks and notes.  Right-click: invite or whisper.", 0.6, 0.6, 0.6)
end

local function OnClick(slot, button)
    if button == "RightButton" then
        if not IsInGuild() then return end
        local me = S.SafeString(UnitName("player"))
        local list = Members()
        SortBy(false)
        MenuUtil.CreateContextMenu(slot, function(_, root)
            root:CreateTitle(S.SafeString((GetGuildInfo("player")), "Guild"))
            local invite = root:CreateButton("Invite")
            local whisper = root:CreateButton("Whisper")
            if invite.SetScrollMode then invite:SetScrollMode(400) end
            if whisper.SetScrollMode then whisper:SetScrollMode(400) end
            local anyInvite, anyWhisper = false, false
            for _, m in ipairs(list) do
                if m.short ~= me then
                    local label = MemberLabel(m)
                    if not m.mobileOnly and not DT.InGroup(m.full) then
                        invite:CreateButton(label, function() DT.Invite(m.full, m.guid) end)
                        anyInvite = true
                    end
                    whisper:CreateButton(label, function() DT.Whisper(m.full) end)
                    anyWhisper = true
                end
            end
            if not anyInvite then invite:CreateTitle("Nobody to invite") end
            if not anyWhisper then whisper:CreateTitle("Nobody online") end
        end)
        return
    end
    if InCombatLockdown() then return end
    if ToggleGuildFrame then ToggleGuildFrame() end
end

DT.Register("Guild", {
    label  = "Guild",
    events = { "PLAYER_ENTERING_WORLD", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "GUILD_MOTD" },
    onEvent = function(event)
        dirty = true
        if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_GUILD_UPDATE" then
            RequestRoster()
        elseif event == "GUILD_ROSTER_UPDATE" then
            DT.RefreshTooltip("Guild")
        end
    end,
    onShow = RequestRoster,
    text = function()
        if not IsInGuild() then return DT.Labelled("dtGuildLabel", "Guild", "-") end
        return DT.Labelled("dtGuildLabel", "Guild", #Members())
    end,
    onEnter = OnEnter,
    onClick = OnClick,
})
