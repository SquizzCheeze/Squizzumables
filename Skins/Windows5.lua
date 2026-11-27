-- Skins/Windows5.lua
-- Batch 5 of the window skins: people. Guild and communities (and the guild's
-- smaller windows), the calendar, inspect, trade, the dressing room, the raid
-- tab, chat channels and the clock / stopwatch.
--
-- Read against ElvUI's skin for each window, behaviour only, on both clients.

local _, ns = ...
local SK = ns.Skins
local Hide = SK.Hide
local FOREVER = ns.BH.IS_FOREVER

local function G(name) return _G[name] end

local function Buttons(...)
    for i = 1, select("#", ...) do SK.Button(select(i, ...)) end
end

local function Hook(obj, method, fn)
    if obj and obj[method] then hooksecurefunc(obj, method, fn) end
end

local function HookGlobal(name, fn)
    if _G[name] then hooksecurefunc(name, fn) end
end

local function HideNamed(...)
    for i = 1, select("#", ...) do Hide(G(select(i, ...))) end
end

local function HideKeys(frame, ...)
    if not frame then return end
    for i = 1, select("#", ...) do Hide(frame[select(i, ...)]) end
end

-- A small window: its art gone, our panel and its controls.
local function Dialog(f)
    if not f then return end
    if f.Header then SK.Strip(f.Header) end
    if f.Selector then SK.Strip(f.Selector) end
    SK.Window(f)
    SK.Auto(f)
end

-- ============================================================================
-- Guild and communities
-- ============================================================================

-- A community in the list down the left: a see-through box, a square icon,
-- green (guild) or blue (Battle.net) when picked.
local function CommunityButton(btn)
    if not btn then return end
    Hide(btn.Background)
    Hide(btn.IconRing)
    if btn.CircleMask and btn.Icon then btn.Icon:RemoveMaskTexture(btn.CircleMask) end
    Hide(btn.CircleMask)
    local b = SK.GetBackdrop(btn) or SK.Backdrop(btn, "panel")
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", btn, "TOPLEFT", 4, -13)
    b:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -8, 8)
    if btn.Icon then
        SK.Icon(btn.Icon)
        btn.Icon:ClearAllPoints()
        btn.Icon:SetPoint("TOPLEFT", 15, -18)
    end
    local hl = btn:GetHighlightTexture()
    if hl then
        hl:SetColorTexture(1, 1, 1, 0.3)
        hl:ClearAllPoints()
        hl:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
        hl:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    end
    local sel = btn.Selection
    if sel then
        local green = btn.Background and btn.Background:GetAtlas() == "communities-nav-button-green-normal"
        local c = green and GREEN_FONT_COLOR or BATTLENET_FONT_COLOR
        sel:SetColorTexture(c.r, c.g, c.b, 0.2)
        sel:ClearAllPoints()
        sel:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
        sel:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    end
end

-- The square tabs down the window's right edge (chat, roster, perks, info).
local function SquareTab(tab)
    if not tab or not SK.Once(tab) then return end
    local icon = tab.Icon
    for _, r in ipairs({ tab:GetRegions() }) do
        if r:IsObjectType("Texture") and r ~= icon then r:SetAlpha(0) end
    end
    if icon then
        local px = SK.Pixel(tab)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", px, -px)
        icon:SetPoint("BOTTOMRIGHT", -px, px)
    end
    local hl = tab:GetHighlightTexture()
    if hl then hl:SetAlpha(1); hl:SetColorTexture(1, 1, 1, 0.15); if icon then hl:SetAllPoints(icon) end end
    local ck = tab.GetCheckedTexture and tab:GetCheckedTexture()
    if ck then ck:SetAlpha(1); ck:SetColorTexture(1, 1, 1, 0.3); if icon then ck:SetAllPoints(icon) end end
    SK.Backdrop(tab, "button")
end

local function GuildCards(cards)
    if not cards then return end
    for _, n in ipairs({ "First", "Second", "Third" }) do
        local c = cards[n .. "Card"]
        if c then
            SK.Strip(c)
            SK.Backdrop(c, "panel")
            SK.Button(c.RequestJoin)
        end
    end
    if cards.PreviousPage then SK.Arrow(cards.PreviousPage, "left") end
    if cards.NextPage then SK.Arrow(cards.NextPage, "right") end
end

local function RequestToJoin(f)
    if not f then return end
    SK.Strip(f)
    SK.Backdrop(f, "panel")
    Hook(f, "Initialize", function(self)
        if not self.SpecsPool then return end
        for btn in self.SpecsPool:EnumerateActive() do
            if btn.Checkbox then SK.Check(btn.Checkbox); btn.Checkbox:SetSize(26, 26) end
        end
    end)
    local mf = f.MessageFrame
    if mf then
        SK.Strip(mf)
        if mf.MessageScroll then
            SK.Strip(mf.MessageScroll)
            SK.Backdrop(mf.MessageScroll, "button")
        end
    end
    Buttons(f.Apply, f.Cancel)
end

-- The hidden border pieces round a guild panel.
local INSET_BORDERS = { "InsetBorderLeft", "InsetBorderRight", "InsetBorderBottomRight", "InsetBorderBottomLeft",
                        "InsetBorderTopRight", "InsetBorderTopLeft", "InsetBorderLeft2", "InsetBorderBottomLeft2",
                        "InsetBorderTopLeft2", "InsetBorderTop" }

local function Communities()
    local cf = G("CommunitiesFrame")
    if not cf then return end
    Hide(cf.NineSlice)
    SK.Window(cf)

    local list = G("CommunitiesFrameCommunitiesList")
    if list then
        SK.Strip(list.InsetFrame)
        HideKeys(list, "FilligreeOverlay", "Bg", "TopFiligree", "BottomFiligree")
        SK.ScrollBar(list.ScrollBar)
        SK.Inset(list)
        Hook(list.ScrollBox, "Update", function(box)
            if box.GetView and not box:GetView() then return end
            box:ForEachFrame(CommunityButton)
        end)
    end
    local mixin = _G.CommunitiesListEntryMixin
    if mixin then
        for _, m in ipairs({ "SetAddCommunity", "SetFindCommunity", "SetGuildFinder" }) do
            if mixin[m] then hooksecurefunc(mixin, m, CommunityButton) end
        end
    end
    for _, k in ipairs({ "StreamDropdown", "CommunityMemberListDropdown", "CommunitiesListDropdown", "GuildMemberListDropdown" }) do
        if cf[k] then SK.Dropdown(cf[k]) end
    end

    -- Tabs down the right edge, the hidden ones leaving no gap.
    local tabs = { cf.ChatTab, cf.RosterTab, cf.GuildBenefitsTab, cf.GuildInfoTab, cf.GuildPreferredPlaySettingsTab }
    for _, t in pairs(tabs) do SquareTab(t) end
    Hook(cf, "UpdateCommunitiesTabs", function(self)
        local last
        for _, k in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }) do
            local tab = self[k]
            if tab and tab:IsShown() then
                tab:ClearAllPoints()
                if last then tab:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -1)
                else tab:SetPoint("TOPLEFT", self, "TOPRIGHT", 1, 0) end
                last = tab
            end
        end
    end)
    local pp = cf.GuildPreferredPlaySettingsFrame
    if pp then
        for _, k in ipairs({ "LocaleDropdown", "DatacenterDropdown" }) do if pp[k] then SK.Dropdown(pp[k]) end end
        Buttons(pp.LocaleApplyButton, pp.DatacenterApplyButton)
    end
    if cf.MaximizeMinimizeFrame then SK.Auto(cf.MaximizeMinimizeFrame) end
    SK.Button(cf.InviteButton)
    if cf.AddToChatButton then SK.Arrow(cf.AddToChatButton, "down") end
    local streamMixin = _G.CommunitiesNotificationSettingsStreamEntryMixin
    if streamMixin and streamMixin.SetFilter then
        hooksecurefunc(streamMixin, "SetFilter", function(self)
            for _, k in ipairs({ "ShowNotificationsButton", "HideNotificationsButton" }) do
                local b = self[k]
                if b then b:SetSize(20, 20); SK.Check(b) end
            end
        end)
    end

    local members = cf.MemberList
    if members then
        SK.Strip(members)
        Hide(members.InsetFrame)
        Hide(members.WatermarkFrame)
        local cd = members.ColumnDisplay
        if cd then
            SK.Strip(cd)
            HideKeys(cd, "InsetBorderLeft", "InsetBorderBottomLeft", "InsetBorderTopLeft", "InsetBorderTop")
        end
        if members.ShowOfflineButton then SK.Check(members.ShowOfflineButton); members.ShowOfflineButton:SetSize(25, 25) end
        SK.ScrollBar(members.ScrollBar)
        Hook(members, "RefreshListDisplay", function(self)
            if not self.ColumnDisplay then return end
            for _, c in ipairs({ self.ColumnDisplay:GetChildren() }) do
                if SK.Once(c) then
                    SK.Strip(c)
                    SK.Backdrop(c, "panel")
                end
            end
        end)
    end
    local chat = cf.Chat
    if chat then
        SK.Strip(chat)
        if chat.InsetFrame then SK.Inset(chat.InsetFrame); SK.Backdrop(chat.InsetFrame, "panel") end
        SK.ScrollBar(chat.ScrollBar)
    end
    local eb = cf.ChatEditBox
    if eb then
        SK.EditBox(eb)
        eb:SetSize(120, 20)
        if cf.MaximizeMinimizeFrame then
            Hook(cf.MaximizeMinimizeFrame, "Minimize", function(self)
                local p = self:GetParent()
                local box = p and p.ChatEditBox
                if box then
                    box:SetPoint("BOTTOMLEFT", 10, 6)
                    box:SetPoint("BOTTOMRIGHT", -12, 6)
                end
            end)
        end
    end

    for _, k in ipairs({ "GuildFinderFrame", "CommunityFinderFrame" }) do
        local f = cf[k]
        if f then
            SK.Strip(f)
            Hide(f.InsetFrame)
            RequestToJoin(f.RequestToJoinFrame)
            GuildCards(f.GuildCards)
            GuildCards(f.PendingGuildCards)
            for _, ck in ipairs({ "CommunityCards", "PendingCommunityCards" }) do
                local cc = f[ck]
                if cc then
                    SK.ScrollBar(cc.ScrollBar)
                    SK.EachRow(cc.ScrollBox, function(card)
                        if not SK.Once(card) then return end
                        if card.CircleMask and card.CommunityLogo then card.CommunityLogo:RemoveMaskTexture(card.CircleMask) end
                        HideKeys(card, "CircleMask", "LogoBorder", "Background")
                        if card.CommunityLogo then SK.Icon(card.CommunityLogo) end
                        SK.Button(card)
                    end)
                end
            end
            local search, pending = f.ClubFinderSearchTab, f.ClubFinderPendingTab
            SquareTab(search)
            SquareTab(pending)
            if search and pending then
                search:ClearAllPoints()
                search:SetPoint("TOPLEFT", cf, "TOPRIGHT", 1, 0)
                pending:ClearAllPoints()
                pending:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -1)
            end
        end
    end
    for _, k in ipairs({ "InvitationFrame", "TicketFrame", "ClubFinderInvitationFrame" }) do
        local f = cf[k]
        if f then
            SK.Strip(f)
            Hide(f.InsetFrame)
            if f.CircleMask and f.Icon then f.Icon:RemoveMaskTexture(f.CircleMask) end
            HideKeys(f, "CircleMask", "IconRing")
            if f.Icon then SK.Icon(f.Icon) end
            Buttons(f.AcceptButton, f.DeclineButton, f.ApplyButton)
            SK.Backdrop(f, "button")
        end
    end
    local inv = cf.ClubFinderInvitationFrame
    if inv then
        RequestToJoin(inv.RequestToJoinFrame)
        Dialog(inv.WarningDialog)
    end

    for _, n in ipairs({ "ClubFinderGuildFinderFrame", "ClubFinderCommunityAndGuildFinderFrame" }) do
        local f = G(n)
        if f then
            SK.Strip(f)
            local o = f.OptionsList
            if o then
                for _, d in ipairs({ "ClubFilterDropdown", "ClubSizeDropdown", "SortByDropdown" }) do
                    if o[d] then SK.Dropdown(o[d]) end
                end
                if o.ClubSizeDropdown and o.ClubFilterDropdown then
                    o.ClubSizeDropdown:ClearAllPoints()
                    o.ClubSizeDropdown:SetPoint("LEFT", o.ClubFilterDropdown, "RIGHT", 3, 0)
                end
                if o.SortByDropdown and o.ClubFilterDropdown then
                    o.SortByDropdown:ClearAllPoints()
                    o.SortByDropdown:SetPoint("RIGHT", o.ClubFilterDropdown, "RIGHT", 120, 0)
                end
                if o.SearchBox then
                    o.SearchBox:SetSize(118, 20)
                    SK.EditBox(o.SearchBox)
                end
                if o.Search then
                    o.Search:SetSize(118, 20)
                    SK.Button(o.Search)
                    if o.SearchBox then
                        o.Search:ClearAllPoints()
                        o.Search:SetPoint("TOP", o.SearchBox, "BOTTOM", 1, -3)
                    end
                end
                for _, role in ipairs({ "TankRoleFrame", "HealerRoleFrame", "DpsRoleFrame" }) do
                    local rf = o[role]
                    if rf and rf.Checkbox then
                        SK.Check(rf.Checkbox)
                        rf.Checkbox:SetFrameLevel(rf.Checkbox:GetFrameLevel() + 1)
                    end
                end
            end
        end
    end

    local detail = cf.GuildMemberDetailFrame
    if detail then
        SK.Strip(detail)
        SK.Backdrop(detail, "panel")
        detail:ClearAllPoints()
        detail:SetPoint("TOPLEFT", cf, "TOPRIGHT", -1, -30)
        for _, k in ipairs({ "NoteBackground", "OfficerNoteBackground" }) do
            local nb = detail[k]
            if nb then Hide(nb.NineSlice); SK.Backdrop(nb, "panel") end
        end
        if detail.CloseButton then SK.Close(detail.CloseButton) end
        Buttons(detail.RemoveButton, detail.GroupInviteButton)
        if detail.RemoveButton then
            detail.RemoveButton:ClearAllPoints()
            detail.RemoveButton:SetPoint("BOTTOMLEFT", 10, 4)
        end
        local dd = detail.RankDropdown
        if dd then
            SK.Dropdown(dd)
            if detail.RankLabel then dd:SetPoint("LEFT", detail.RankLabel, "RIGHT", 0, -3) end
        end
    end
    if members and members.InsetFrame then SK.Inset(members.InsetFrame) end
    local control = cf.CommunitiesControlFrame
    if control then
        Buttons(control.GuildControlButton, control.GuildRecruitmentButton, control.CommunitiesSettingsButton)
        if control.CommunitiesSettingsButton then control.CommunitiesSettingsButton:SetSize(129, 19) end
    end

    local benefits = cf.GuildBenefitsFrame
    if benefits then
        HideKeys(benefits, unpack(INSET_BORDERS))
        local function Rewards(box)
            SK.EachRow(box, function(child)
                if not SK.Once(child) or not child.Icon then return end
                local ib = SK.Icon(child.Icon)
                SK.Strip(child, { [child.Icon] = true })
                local b = SK.Backdrop(child, "panel")
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", ib, "TOPLEFT")
                b:SetPoint("BOTTOMLEFT", ib, "BOTTOMLEFT")
                b:SetWidth(child:GetWidth() - 5)
            end)
        end
        if benefits.Perks then
            SK.ScrollBar(benefits.Perks.ScrollBar)
            if SK.ParchmentActive() then
                SK.Strip(benefits.Perks)
                Rewards(benefits.Perks.ScrollBox)
            end
        end
        if benefits.Rewards then
            SK.ScrollBar(benefits.Rewards.ScrollBar)
            if SK.ParchmentActive() then
                Hide(benefits.Rewards.Bg)
                Rewards(benefits.Rewards.ScrollBox)
            end
        end
        local bar = benefits.FactionFrame and benefits.FactionFrame.Bar
        if bar and SK.Once(bar) then
            HideKeys(bar, "Middle", "Right", "Left", "BG", "Shadow")
            if bar.Progress then
                bar.Progress:SetTexture("Interface\\Buttons\\WHITE8x8")
                bar.Progress:ClearAllPoints()
                bar.Progress:SetPoint("TOPLEFT")
                bar.Progress:SetPoint("BOTTOMLEFT")
            end
            SK.Backdrop(bar, "button")
        end
    end

    local details = G("CommunitiesFrameGuildDetailsFrame")
    if details then HideKeys(details, unpack(INSET_BORDERS)) end
    local filters = G("CommunitiesGuildNewsFiltersFrame")
    if filters then Dialog(filters) end
    local news = G("CommunitiesFrameGuildDetailsFrameNews")
    local info = G("CommunitiesFrameGuildDetailsFrameInfo")
    if info then
        if info.DetailsFrame then SK.ScrollBar(info.DetailsFrame.ScrollBar) end
        if info.MOTDScrollFrame then SK.ScrollBar(info.MOTDScrollFrame.ScrollBar) end
    end
    if news then SK.ScrollBar(news.ScrollBar) end
    HookGlobal("GuildNewsButton_SetNews", function(btn) if btn and btn.header then btn.header:SetAlpha(0) end end)
    if info and news then
        if SK.ParchmentActive() then
            SK.Strip(info)
            SK.Strip(news)
            -- Three boxes on the info page, one on the news page, as ElvUI lays them.
            local function Area(parent, x1, y1, x2, y2)
                local f = CreateFrame("Frame", nil, parent)
                f:SetPoint("TOPLEFT", parent, "TOPLEFT", x1, y1)
                f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", x2, y2)
                SK.Backdrop(f, "panel")
                return f
            end
            local challenges = Area(info, 14, -22, 0, 200)
            local motd = Area(info, 14, -158, 0, 118)
            Area(info, 14, -236, -7, 1)
            Area(news, 7, -22, -13, 1)
            HookGlobal("CommunitiesGuildInfoFrame_HideChallenges", function(frame)
                if frame ~= info then return end
                motd:Hide()
                challenges:SetPoint("BOTTOMRIGHT", info, "BOTTOMRIGHT", 0, 118)
                if info.MOTDScrollFrame then info.MOTDScrollFrame:SetHeight(188) end
            end)
        else
            for _, r in ipairs({ info:GetRegions() }) do
                if r:IsObjectType("Texture") and r:GetDrawLayer() == "ARTWORK" then r:SetAlpha(0) end
            end
        end
        local boss = news.BossModel
        if boss then
            SK.Strip(boss)
            SK.Backdrop(boss, "panel")
            if boss.TextFrame then SK.Strip(boss.TextFrame); SK.Backdrop(boss.TextFrame, "panel") end
        end
    end
    SK.Button(cf.GuildLogButton)

    for _, n in ipairs({ "CommunitiesGuildTextEditFrame", "CommunitiesGuildLogFrame" }) do
        local f = G(n)
        if f then
            SK.Strip(f)
            SK.Backdrop(f, "panel")
            SK.Shadow(f)
            local c = f.Container
            if c then
                Hide(c.NineSlice)
                SK.Backdrop(c, "panel")
                if c.ScrollFrame then SK.ScrollBar(c.ScrollFrame.ScrollBar) end
            end
            -- Their close cross and close button carry no names.
            for _, child in ipairs({ f:GetChildren() }) do
                if child:IsObjectType("Button") and not child:GetName() then
                    if child.GetFontString and child:GetFontString() and child:GetFontString():GetText() then
                        SK.Button(child)
                    else
                        SK.Close(child)
                    end
                end
            end
            SK.Auto(f)
        end
    end
    SK.Button(G("CommunitiesGuildTextEditFrameAcceptButton"))

    local rec = cf.RecruitmentDialog
    if rec then
        SK.Strip(rec)
        SK.Backdrop(rec, "panel")
        if rec.RecruitmentMessageFrame then
            SK.Strip(rec.RecruitmentMessageFrame)
            local input = rec.RecruitmentMessageFrame.RecruitmentMessageInput
            if input then
                SK.Strip(input)
                SK.Backdrop(input, "button")
                SK.ScrollBar(input.ScrollBar)
            end
        end
        for _, k in ipairs({ "ShouldListClub", "MaxLevelOnly", "MinIlvlOnly" }) do
            if rec[k] and rec[k].Button then SK.Check(rec[k].Button) end
        end
        if rec.MinIlvlOnly then SK.EditBox(rec.MinIlvlOnly.EditBox) end
        SK.Auto(rec)
    end
    local notes = cf.NotificationSettingsDialog
    if notes then
        if notes.Selector then SK.Strip(notes.Selector); Buttons(notes.Selector.OkayButton, notes.Selector.CancelButton) end
        Dialog(notes)
        local child = notes.ScrollFrame and notes.ScrollFrame.Child
        if child then
            SK.Check(child.QuickJoinButton)
            Buttons(child.AllButton, child.NoneButton)
        end
        if notes.ScrollFrame then SK.ScrollBar(notes.ScrollFrame.ScrollBar) end
    end
    local stream = cf.EditStreamDialog
    if stream then
        Dialog(stream)
        if stream.NameEdit then stream.NameEdit:SetSize(280, 20) end
    end
    local settings = G("CommunitiesSettingsDialog")
    if settings then
        Hide(settings.BG)
        Hide(settings.IconPreviewRing)
        if settings.IconPreview then SK.Icon(settings.IconPreview) end
        for _, k in ipairs({ "CrossFactionToggle", "ShouldListClub", "AutoAcceptApplications", "MaxLevelOnly", "MinIlvlOnly" }) do
            local f = settings[k]
            local cb = f and (f.CheckButton or f.Button)
            if cb then SK.Check(cb) end
        end
        if settings.MinIlvlOnly then SK.EditBox(settings.MinIlvlOnly.EditBox) end
        Dialog(settings)
    end
    local avatar = G("CommunitiesAvatarPickerDialog")
    if avatar then
        if avatar.Selector then SK.Strip(avatar.Selector); Buttons(avatar.Selector.OkayButton, avatar.Selector.CancelButton) end
        Dialog(avatar)
        SK.ScrollBar(avatar.ScrollBar)
    end
    local tickets = G("CommunitiesTicketManagerDialog")
    if tickets then
        local im = tickets.InviteManager
        if im then
            Hide(im.ArtOverlay)
            if im.ColumnDisplay then
                SK.Strip(im.ColumnDisplay)
                HideKeys(im.ColumnDisplay, "InsetBorderLeft", "InsetBorderBottomLeft")
            end
        end
        Dialog(tickets)
    end

    local applicants = cf.ApplicantList
    if applicants then
        SK.Strip(applicants)
        if applicants.ColumnDisplay then SK.Strip(applicants.ColumnDisplay) end
        SK.Backdrop(applicants, "panel", 0, 0, -15, 0)
        SK.ScrollBar(applicants.ScrollBar)
        Hook(applicants, "BuildList", function(self)
            local cd = self.ColumnDisplay
            if not cd then return end
            for _, c in ipairs({ cd:GetChildren() }) do
                if SK.Once(c) then
                    SK.Strip(c)
                    local b = SK.Backdrop(c, "button", 4, -2, 0, 2)
                    local hl = c:GetHighlightTexture()
                    if hl then hl:SetAlpha(1); hl:SetColorTexture(1, 1, 1, 0.25); hl:SetAllPoints(b) end
                end
            end
        end)
    end
    SK.Auto(cf)
end

SK.Define("communities", Communities)

-- The guild invite popup (with the game) and the guild's own windows.
SK.Define("guild", function()
    local inv = G("GuildInviteFrame")
    if inv then
        Dialog(inv)
        Buttons(G("GuildInviteFrameJoinButton"), G("GuildInviteFrameDeclineButton"))
    end
end)

SK.Define("guildcontrol", function()
    local f = G("GuildControlUI")
    if not f then return end
    Hide(G("GuildControlUIHbar"))
    SK.Window(f)
    if G("GuildControlUICloseButton") then SK.Close(G("GuildControlUICloseButton")) end
    for _, n in ipairs({ "GuildControlUINavigationDropdown", "GuildControlUIRankSettingsFrameRankDropdown",
                         "GuildControlUIRankBankFrameRankDropdown", "GuildControlUIRankDiscordFrameServerDropdown",
                         "GuildControlUIRankDiscordFrameChannelDropdown" }) do
        if G(n) then SK.Dropdown(G(n)) end
    end
    local bank = G("GuildControlUIRankBankFrame")
    if bank then
        SK.Strip(bank)
        local inset = G("GuildControlUIRankBankFrameInset")
        if inset then SK.Inset(inset) end
        local sf = G("GuildControlUIRankBankFrameInsetScrollFrame")
        if sf then SK.Strip(sf); if sf.ScrollBar then SK.ScrollBar(sf.ScrollBar) end end
    end
    -- The ranks list: rank boxes and arrow buttons are made on demand.
    HookGlobal("GuildControlUI_RankOrder_Update", function()
        for i = 1, (GuildControlGetNumRanks and GuildControlGetNumRanks() or 10) do
            local rank = G("GuildControlUIRankOrderFrameRank" .. i)
            if rank and SK.Once(rank) then
                if rank.nameBox then SK.EditBox(rank.nameBox) end
                for _, k in ipairs({ "upButton", "downButton" }) do
                    if rank[k] then SK.Arrow(rank[k], k == "upButton" and "up" or "down") end
                end
                if rank.deleteButton then SK.Close(rank.deleteButton) end
            end
        end
    end)
    HookGlobal("GuildControlUI_BankTabPermissions_Update", function()
        for i = 1, (MAX_BUY_GUILDBANK_TABS or 8) do
            local tab = G("GuildControlBankTab" .. i)
            if tab and SK.Once(tab) then
                SK.Strip(tab)
                local owned = tab.owned
                if owned then
                    if owned.tabIcon then SK.Icon(owned.tabIcon) end
                    if owned.editBox then SK.EditBox(owned.editBox) end
                    for _, k in ipairs({ "viewCB", "depositCB" }) do if owned[k] then SK.Check(owned[k]) end end
                end
                if tab.buy and tab.buy.button then SK.Button(tab.buy.button) end
            end
        end
    end)
    for i = 1, (NUM_RANK_FLAGS or 20) do
        local cb = G("GuildControlUIRankSettingsFrameCheckbox" .. i)
        if cb then SK.Check(cb) end
    end
    SK.Check(G("GuildControlUIRankSettingsFrameOfficerCheckbox"))
    SK.EditBox(G("GuildControlUIRankSettingsFrameGoldBox"))
    SK.Button(G("GuildControlUIRankOrderFrameNewButton"))
    local discord = G("DiscordLinkFrame")
    if discord then
        Dialog(discord)
        SK.Button(G("DiscordLinkFrameButton"))
    end
    SK.Button(G("GuildControlUIRankDiscordFrameChannelButton"))
    SK.Auto(f)
end)

SK.Define("guildregistrar", function()
    local f = G("GuildRegistrarFrame")
    if not f then return end
    SK.Window(f)
    for _, r in ipairs({ G("GuildRegistrarFrameEditBox") and G("GuildRegistrarFrameEditBox"):GetRegions() or nil }) do
        if r and r:IsObjectType("Texture") then r:SetAlpha(0) end
    end
    SK.EditBox(G("GuildRegistrarFrameEditBox"))
    Buttons(G("GuildRegistrarFrameGoodbyeButton"), G("GuildRegistrarFramePurchaseButton"), G("GuildRegistrarFrameCancelButton"))
    for _, n in ipairs({ "GuildAvailableServicesText", "GuildRegistrarPurchaseText", "AvailableServicesText" }) do
        local t = G(n)
        if t and SK.ParchmentActive() then t:SetTextColor(1, 1, 1) end
    end
    SK.Auto(f)
end)

SK.Define("petition", function()
    local f = G("PetitionFrame")
    if not f then return end
    SK.Window(f)
    SK.Inset(G("PetitionFrameInset"))
    Buttons(G("PetitionFrameSignButton"), G("PetitionFrameRequestButton"), G("PetitionFrameRenameButton"), G("PetitionFrameCancelButton"))
    if SK.ParchmentActive() then
        for _, n in ipairs({ "PetitionFrameCharterTitle", "PetitionFrameCharterName", "PetitionFrameMasterTitle",
                             "PetitionFrameMasterName", "PetitionFrameMemberTitle", "PetitionFrameInstructions" }) do
            local t = G(n)
            if t then t:SetTextColor(1, 1, 1) end
        end
    end
    SK.Auto(f)
end)

SK.Define("tabard", function()
    local f = G("TabardFrame")
    if not f then return end
    SK.Window(f)
    HideNamed("TabardFrameEmblemTopLeft", "TabardFrameEmblemTopRight", "TabardFrameEmblemBottomLeft",
              "TabardFrameEmblemBottomRight", "TabardFrameMoneyBg")
    SK.Inset(G("TabardFrameMoneyInset"))
    SK.Strip(G("TabardFrameCustomizationFrame"))
    Buttons(G("TabardFrameAcceptButton"), G("TabardFrameCancelButton"))
    for i = 1, 5 do
        local c = G("TabardFrameCustomization" .. i)
        if c then
            SK.Strip(c)
            local l, r = G("TabardFrameCustomization" .. i .. "LeftButton"), G("TabardFrameCustomization" .. i .. "RightButton")
            if l then SK.Arrow(l, "left") end
            if r then SK.Arrow(r, "right") end
        end
    end
    local cost = G("TabardFrameCostFrame")
    if cost then SK.Strip(cost) end
    SK.Auto(f)
end)

-- ============================================================================
-- Calendar
-- ============================================================================

local function EventIcon(icon, header)
    if not icon or not SK.Once(icon) then return end
    icon:SetSize(54, 54)
    icon:ClearAllPoints()
    if header then icon:SetPoint("TOPLEFT", header, "TOPLEFT", 15, -20) end
    SK.Icon(icon)
    -- Blizzard re-crops it per event type; keep it square.
    hooksecurefunc(icon, "SetTexCoord", function(self, a)
        if a ~= 0.08 then self:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    end)
end

SK.Define("calendar", function()
    local cal = G("CalendarFrame")
    if not cal then return end
    cal:DisableDrawLayer("BORDER")
    SK.Backdrop(cal, "panel")
    SK.Shadow(cal)
    if cal.FilterButton then SK.Dropdown(cal.FilterButton) end
    local close = G("CalendarCloseButton")
    if close then
        SK.Close(close)
        close:SetPoint("TOPRIGHT", cal, "TOPRIGHT", -4, -4)
    end
    for i = 1, 7 do Hide(G("CalendarWeekday" .. i .. "Background")) end
    for _, n in ipairs({ "CalendarViewEventInviteList", "CalendarCreateEventInviteList",
                         "CalendarViewEventDescriptionContainer", "CalendarCreateEventDescriptionContainer" }) do
        local c = G(n)
        if c then
            Hide(c.NineSlice)
            SK.Backdrop(c, "panel")
            if c.ScrollBar then SK.ScrollBar(c.ScrollBar) end
        end
    end
    HideNamed("CalendarCreateEventFrameButtonBackground", "CalendarCreateEventMassInviteButtonBorder",
              "CalendarCreateEventCreateButtonBorder", "CalendarEventPickerFrameButtonBackground",
              "CalendarEventPickerCloseButtonBorder", "CalendarCreateEventRaidInviteButtonBorder",
              "CalendarMonthBackground", "CalendarYearBackground", "CalendarTexturePickerFrameButtonBackground",
              "CalendarTexturePickerAcceptButtonBorder", "CalendarTexturePickerCancelButtonBorder",
              "CalendarClassTotalsButtonBackgroundTop", "CalendarClassTotalsButtonBackgroundMiddle",
              "CalendarClassTotalsButtonBackgroundBottom", "CalendarViewEventDivider", "CalendarCreateEventDivider",
              "CalendarTodayTexture", "CalendarTodayTextureGlow")
    local overlay = G("CalendarFrameModalOverlay")
    if overlay then overlay:SetAlpha(0.25) end
    if G("CalendarPrevMonthButton") then SK.Arrow(G("CalendarPrevMonthButton"), "left") end
    if G("CalendarNextMonthButton") then SK.Arrow(G("CalendarNextMonthButton"), "right") end

    -- The days: see-through boxes, the parchment only with the remover off.
    for i = 1, 42 do
        local day = G("CalendarDayButton" .. i)
        if day then
            local dark = G("CalendarDayButton" .. i .. "DarkFrame")
            if dark then dark:SetAlpha(0.5) end
            if SK.ParchmentActive() then day:DisableDrawLayer("BACKGROUND") end
            local b = SK.Backdrop(day, "none")
            b:SetFrameLevel(day:GetFrameLevel() + 1)
            local hl = day:GetHighlightTexture()
            if hl then
                hl:SetColorTexture(1, 1, 1, 0.3)
                hl:ClearAllPoints()
                hl:SetPoint("TOPLEFT", -1, 1)
                hl:SetPoint("BOTTOMRIGHT")
            end
        end
    end
    local wsel = G("CalendarWeekdaySelectedTexture")
    if wsel then wsel:SetDesaturated(true); wsel:SetVertexColor(1, 1, 1, 0.6) end
    local today = G("CalendarTodayFrame")
    if today then
        local b = SK.Backdrop(today, "none")
        b:SetFrameLevel(today:GetFrameLevel() + 1)
        b:SetBackdropBorderColor(NORMAL_FONT_COLOR:GetRGB())
        b.sqHover = true
        today:SetScript("OnUpdate", nil)
        HookGlobal("CalendarFrame_SetToday", function() today:SetAllPoints() end)
    end

    local create = G("CalendarCreateEventFrame")
    if create then
        SK.Strip(create)
        SK.Backdrop(create, "panel")
        create:SetPoint("TOPLEFT", cal, "TOPRIGHT", 3, -24)
        if create.Header then SK.Strip(create.Header) end
        Buttons(G("CalendarCreateEventCreateButton"), G("CalendarCreateEventMassInviteButton"),
                G("CalendarCreateEventInviteButton"), G("CalendarCreateEventRaidInviteButton"))
        local edit, invite = G("CalendarCreateEventInviteEdit"), G("CalendarCreateEventInviteButton")
        if edit then
            edit:SetWidth(edit:GetWidth() - 2)
            SK.EditBox(edit)
            if invite then invite:SetPoint("TOPLEFT", edit, "TOPRIGHT", 4, 1) end
        end
        SK.EditBox(G("CalendarCreateEventTitleEdit"))
        for _, k in ipairs({ "EventTypeDropdown", "HourDropdown", "MinuteDropdown", "AMPMDropdown", "DifficultyOptionDropdown" }) do
            if create[k] then SK.Dropdown(create[k]) end
        end
        if create.DifficultyOptionDropdown then
            create.DifficultyOptionDropdown:ClearAllPoints()
            create.DifficultyOptionDropdown:SetPoint("TOPLEFT", create, "TOPLEFT", 220, -114)
        end
        if G("CalendarCreateEventCloseButton") then SK.Close(G("CalendarCreateEventCloseButton")) end
        SK.Check(G("CalendarCreateEventLockEventCheck"))
    end
    local title, viewIcon = G("CalendarViewEventTitle"), G("CalendarViewEventIcon")
    local view = G("CalendarViewEventFrame")
    if title and viewIcon then
        title:ClearAllPoints()
        title:SetPoint("TOPLEFT", viewIcon, "TOPRIGHT", 5, 0)
    end
    EventIcon(viewIcon, view and view.HeaderFrame)
    local dateLabel, createIcon = G("CalendarCreateEventDateLabel"), G("CalendarCreateEventIcon")
    if dateLabel and createIcon then
        dateLabel:ClearAllPoints()
        dateLabel:SetPoint("TOPLEFT", createIcon, "TOPRIGHT", 5, 0)
    end
    EventIcon(createIcon, view and view.HeaderFrame)

    -- Class counts down the side.
    local container = G("CalendarClassButtonContainer")
    local first = G("CalendarClassButton1")
    if first and container then first:SetPoint("TOPLEFT", container, "TOPLEFT", 3, 0) end
    local last
    for i, class in ipairs(CLASS_SORT_ORDER or {}) do
        local btn = G("CalendarClassButton" .. i)
        if btn and SK.Once(btn) then
            local nt = btn:GetNormalTexture()
            local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
            if nt and coords then
                local l, r, t, b = unpack(coords)
                nt:SetTexCoord(l + 0.02, r - 0.02, t + 0.02, b - 0.02)
            end
            local first = btn:GetRegions()
            if first and first ~= nt then first:SetAlpha(0) end
            SK.Backdrop(btn, "button")
            btn:SetSize(28, 28)
            local count = G("CalendarClassButton" .. i .. "Count")
            if count then
                count:ClearAllPoints()
                count:SetPoint("BOTTOMRIGHT", 0, 1)
            end
            if last then
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -8)
            end
            last = btn
        end
    end
    local totals = G("CalendarClassTotalsButton")
    if totals then
        SK.Strip(totals)
        SK.Backdrop(totals, "button")
        totals:SetSize(28, 18)
    end

    for _, n in ipairs({ "CalendarTexturePickerFrame", "CalendarMassInviteFrame", "CalendarViewRaidFrame",
                         "CalendarViewHolidayFrame", "CalendarViewEventFrame", "CalendarEventPickerFrame" }) do
        local f = G(n)
        if f then
            SK.Strip(f)
            if f.Header then SK.Strip(f.Header) end
            SK.Backdrop(f, "panel")
            SK.Shadow(f)
            if f.ScrollBar then SK.ScrollBar(f.ScrollBar) end
            if n == "CalendarViewRaidFrame" or n == "CalendarViewHolidayFrame" or n == "CalendarViewEventFrame" then
                f:SetPoint("TOPLEFT", cal, "TOPRIGHT", 3, -24)
            end
        end
    end
    local holiday = G("CalendarViewHolidayFrameModalOverlay")
    if holiday then holiday:SetAlpha(0) end
    SK.Strip(G("CalendarViewEventInviteListSection"))
    for _, n in ipairs({ "CalendarMassInviteCloseButton", "CalendarViewRaidCloseButton", "CalendarViewHolidayCloseButton",
                         "CalendarViewEventCloseButton" }) do
        if G(n) then SK.Close(G(n)) end
    end
    Buttons(G("CalendarTexturePickerAcceptButton"), G("CalendarTexturePickerCancelButton"), G("CalendarMassInviteAcceptButton"),
            G("CalendarViewEventAcceptButton"), G("CalendarViewEventTentativeButton"), G("CalendarViewEventRemoveButton"),
            G("CalendarViewEventDeclineButton"), G("CalendarEventPickerCloseButton"))
    local mass = G("CalendarMassInviteFrame")
    if mass then
        for _, k in ipairs({ "CommunityDropdown", "RankDropdown" }) do if mass[k] then SK.Dropdown(mass[k]) end end
        SK.EditBox(G("CalendarMassInviteMinLevelEdit"))
        SK.EditBox(G("CalendarMassInviteMaxLevelEdit"))
    end
end)

-- The clock and stopwatch.
SK.Define("timemanager", function()
    local f = G("TimeManagerFrame")
    if f then
        SK.Window(f)
        local alarm = G("TimeManagerAlarmTimeFrame")
        if alarm then
            for _, k in ipairs({ "HourDropdown", "MinuteDropdown", "AMPMDropdown" }) do if alarm[k] then SK.Dropdown(alarm[k]) end end
        end
        SK.EditBox(G("TimeManagerAlarmMessageEditBox"))
        for _, n in ipairs({ "TimeManagerAlarmEnabledButton", "TimeManagerMilitaryTimeCheck", "TimeManagerLocalTimeCheck" }) do
            SK.Check(G(n))
        end
        SK.Strip(G("TimeManagerStopwatchFrame"))
        local sw = G("TimeManagerStopwatchCheck")
        if sw and SK.Once(sw) then
            local nt = sw:GetNormalTexture()
            if nt then
                nt:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                local px = SK.Pixel(sw)
                nt:ClearAllPoints()
                nt:SetPoint("TOPLEFT", px, -px)
                nt:SetPoint("BOTTOMRIGHT", -px, px)
            end
            local hl = sw:GetHighlightTexture()
            if hl then hl:SetColorTexture(1, 1, 1, 0.3) end
            SK.Backdrop(sw, "button")
        end
        SK.Auto(f)
    end
    local stop = G("StopwatchFrame")
    if stop and SK.Once(stop) then
        SK.Strip(stop)
        SK.Backdrop(stop, "panel", 0, -17, 0, 2)
        SK.Strip(G("StopwatchTabFrame"))
        if G("StopwatchCloseButton") then SK.Close(G("StopwatchCloseButton")) end
        local reset, play = G("StopwatchResetButton"), G("StopwatchPlayPauseButton")
        if reset then
            SK.Button(reset)
            reset:SetSize(16, 16)
            reset:SetPoint("BOTTOMRIGHT", stop, "BOTTOMRIGHT", -4, 6)
        end
        if play then
            SK.Backdrop(play, "button")
            SK.Hover(play)
            play:SetSize(12, 12)
            if reset then play:SetPoint("RIGHT", reset, "LEFT", -4, 0) end
        end
    end
end)

-- ============================================================================
-- Inspect
-- ============================================================================

SK.Define("inspect", function()
    local f = G("InspectFrame")
    if not f then return end
    SK.Window(f)
    SK.NumberedTabs(f, "InspectFrameTab")
    local paper = G("InspectPaperDollFrame")
    if paper then SK.Button(paper.ViewButton) end
    local pvp = G("InspectPVPFrame")
    if FOREVER and f.ModeTabs and f.ModeTabs.Tabs then
        for _, t in ipairs(f.ModeTabs.Tabs) do SK.SideTab(t) end
        SK.LayoutSideTabs(f, f.ModeTabs.Tabs)
        if pvp and pvp.MainInfoFrame then Hide(pvp.MainInfoFrame.Line) end
    else
        local talents = G("InspectPaperDollItemsFrame") and G("InspectPaperDollItemsFrame").InspectTalents
        if talents then
            SK.Button(talents)
            talents:ClearAllPoints()
            talents:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -1)
        end
        if pvp then
            if pvp.SmallWreath then
                pvp.SmallWreath:ClearAllPoints()
                pvp.SmallWreath:SetPoint("TOPLEFT", -2, -25)
            end
            for i = 1, 3 do
                local slot = pvp["TalentSlot" .. i]
                if slot and SK.Once(slot) then
                    local icon = slot.Texture
                    SK.Strip(slot, icon and { [icon] = true } or nil)
                    Hide(slot.Border)
                    if icon then SK.Icon(icon) end
                end
            end
        end
    end
    local model = G("InspectModelFrame")
    if model then
        SK.Strip(model, { [model.BackgroundOverlay or 0] = true })
        local px = SK.Pixel(model)
        SK.Backdrop(model, "none", -px, px, px, -(px * 2))
        if model.BackgroundOverlay then model.BackgroundOverlay:SetColorTexture(0, 0, 0, FOREVER and 0.5 or 1) end
    end
    if SK.ParchmentActive() then
        Hide(G("InspectGuildFrameBG"))
        if pvp and not FOREVER then Hide(pvp.BG) end
    end
    HideNamed("InspectModelFrameBorderTopLeft", "InspectModelFrameBorderTopRight", "InspectModelFrameBorderTop",
              "InspectModelFrameBorderLeft", "InspectModelFrameBorderRight", "InspectModelFrameBorderBottomLeft",
              "InspectModelFrameBorderBottomRight", "InspectModelFrameBorderBottom", "InspectModelFrameBorderBottom2")
    -- The race background keeps its colour.
    for _, corner in ipairs({ "TopLeft", "TopRight", "BotLeft", "BotRight" }) do
        local bg = G("InspectModelFrameBackground" .. corner)
        if bg then
            bg:SetDesaturated(false)
            hooksecurefunc(bg, "SetDesaturated", function(self, v) if v then self:SetDesaturated(false) end end)
        end
    end
    local items = G("InspectPaperDollItemsFrame")
    if items then
        for _, slot in ipairs({ items:GetChildren() }) do
            if slot.icon and SK.Once(slot) then
                SK.Strip(slot, { [slot.icon] = true, [slot.IconBorder or 0] = true })
                local px = SK.Pixel(slot)
                slot.icon:ClearAllPoints()
                slot.icon:SetPoint("TOPLEFT", px, -px)
                slot.icon:SetPoint("BOTTOMRIGHT", -px, px)
                local border = SK.Icon(slot.icon)
                SK.QualityBorder(slot.IconBorder, border)
                local hl = slot:GetHighlightTexture()
                if hl then hl:SetAlpha(1); hl:SetColorTexture(1, 1, 1, 0.15); hl:SetAllPoints(slot.icon) end
            end
        end
    end
    SK.Auto(f)
end)

-- ============================================================================
-- Trade
-- ============================================================================

local function TradeItem(item, button, icon, name)
    if not button or not SK.Once(button) then return end
    SK.Strip(button, { [icon or 0] = true, [button.IconBorder or 0] = true })
    local b = SK.Backdrop(button, "button")
    SK.QualityBorder(button.IconBorder, b)
    local hl = button:GetHighlightTexture()
    if hl then hl:SetAlpha(1); hl:SetColorTexture(1, 1, 1, 0.15) end
    -- A see-through strip behind the name.
    if name then
        local strip = CreateFrame("Frame", nil, button)
        strip:SetPoint("TOPLEFT", button, "TOPRIGHT", 4, 0)
        strip:SetPoint("BOTTOMRIGHT", name, "BOTTOMRIGHT", 0, 14)
        strip:SetFrameLevel(math.max(0, button:GetFrameLevel() - 2))
        SK.Backdrop(strip, "panel")
    end
    SK.Strip(item)
    if icon then
        local px = SK.Pixel(button)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", px, -px)
        icon:SetPoint("BOTTOMRIGHT", -px, px)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

SK.Define("trade", function()
    local f = G("TradeFrame")
    if not f then return end
    SK.Window(f)
    local ro = f.RecipientOverlay
    if ro then
        Hide(ro.portrait)
        Hide(ro.portraitFrame)
    end
    Buttons(G("TradeFrameTradeButton"), G("TradeFrameCancelButton"))
    for _, n in ipairs({ "TradeRecipientItemsInset", "TradePlayerItemsInset", "TradePlayerInputMoneyInset",
                         "TradePlayerEnchantInset", "TradeRecipientEnchantInset", "TradeRecipientMoneyInset" }) do
        local inset = G(n)
        if inset then SK.Inset(inset) end
    end
    Hide(G("TradeRecipientMoneyBg"))
    for i = 1, (MAX_TRADE_ITEMS or 7) do
        for _, who in ipairs({ "TradePlayerItem", "TradeRecipientItem" }) do
            local base = who .. i
            TradeItem(G(base), G(base .. "ItemButton"), G(base .. "ItemButtonIconTexture"), G(base .. "NameFrame"))
        end
    end
    -- The "ready" glow: a light green wash.
    for _, n in ipairs({ "TradeHighlightPlayer", "TradeHighlightPlayerEnchant", "TradeHighlightRecipient", "TradeHighlightRecipientEnchant" }) do
        local hl = G(n)
        if hl then
            hl:SetFrameStrata("HIGH")
            for _, part in ipairs({ "Top", "Bottom", "Middle" }) do
                local t = G(n .. part)
                if t then t:SetColorTexture(0, 1, 0, 0.2) end
            end
        end
    end
    SK.MoneyInput(G("TradePlayerInputMoneyFrame"))
    SK.Auto(f)
end)

-- ============================================================================
-- Dressing room
-- ============================================================================

SK.Define("dressingroom", function()
    local f = G("DressUpFrame")
    if not f then return end
    SK.Window(f)
    if f.MaximizeMinimizeFrame then SK.Auto(f.MaximizeMinimizeFrame) end
    local reset, cancel = G("DressUpFrameResetButton"), G("DressUpFrameCancelButton")
    Buttons(reset, cancel, f.LinkButton, f.ToggleCustomSetDetailsButton)
    local toggle = f.ToggleCustomSetDetailsButton
    if toggle and SK.Once(toggle) then
        local t = toggle:CreateTexture(nil, "ARTWORK")
        t:SetTexture(1392954)
        t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local px = SK.Pixel(toggle)
        t:SetPoint("TOPLEFT", px, -px)
        t:SetPoint("BOTTOMRIGHT", -px, px)
    end
    local sel = f.SetSelectionPanel
    if sel then
        SK.Strip(sel)
        SK.Backdrop(sel, "panel")
        SK.ScrollBar(sel.ScrollBar)
        SK.EachRow(sel.ScrollBox, function(btn)
            if not SK.Once(btn) then return end
            if btn.Icon then SK.QualityBorder(btn.IconBorder, SK.Icon(btn.Icon)) end
            Hide(btn.BackgroundTexture)
            if btn.SelectedTexture then btn.SelectedTexture:SetColorTexture(1, 0.8, 0, 0.25) end
            if btn.HighlightTexture then btn.HighlightTexture:SetColorTexture(1, 1, 1, 0.25) end
        end)
    end
    if f.ModelBackground then f.ModelBackground:SetDrawLayer("BACKGROUND", 1) end
    if f.LinkButton then
        f.LinkButton:SetSize(110, 22)
        f.LinkButton:ClearAllPoints()
        f.LinkButton:SetPoint("BOTTOMLEFT", 4, 4)
    end
    if cancel then cancel:SetPoint("BOTTOMRIGHT", -4, 4) end
    if reset and cancel then reset:SetPoint("RIGHT", cancel, "LEFT", -3, 0) end
    local custom = f.CustomSetDropdown
    if custom then
        SK.Dropdown(custom)
        SK.Button(custom.SaveButton)
    end
    local details = f.CustomSetDetailsPanel
    if details then
        details:DisableDrawLayer("BACKGROUND")
        details:DisableDrawLayer("OVERLAY")
        SK.Backdrop(details, "panel")
        if details.ClassBackground then details.ClassBackground:SetAllPoints() end
        Hook(details, "Refresh", function(self)
            if not self.slotPool then return end
            for slot in self.slotPool:EnumerateActive() do
                local border = slot.Icon and SK.GetBackdrop(slot.Icon)
                if not border and slot.Icon then
                    Hide(slot.IconBorder)
                    border = SK.Icon(slot.Icon)
                end
                if border then
                    if not slot.slotState and not slot.isHiddenVisual and slot.transmogID and slot.Name then
                        border:SetBackdropBorderColor(slot.Name:GetTextColor())
                    else
                        border:SetBackdropBorderColor(SK.BorderRGB())
                    end
                end
            end
        end)
        Hook(f, "ConfigureSize", function(self)
            local p = self.CustomSetDetailsPanel
            if p then
                p:ClearAllPoints()
                p:SetPoint("TOPLEFT", self, "TOPRIGHT", 4, 0)
            end
        end)
    end
    SK.Auto(f)
end)

-- ============================================================================
-- Raid tab (in the friends window) and the raid info list
-- ============================================================================

SK.Define("nonraid", function()
    for _, n in ipairs({ "RaidInfoFrame", "RaidInfoInstanceLabel", "RaidInfoIDLabel" }) do SK.Strip(G(n)) end
    Buttons(G("RaidFrameConvertToRaidButton"), G("RaidFrameRaidInfoButton"))
    local info = G("RaidInfoFrame")
    if info then
        if info.Header then SK.Strip(info.Header) end
        SK.Backdrop(info, "panel")
        SK.Shadow(info)
        if G("RaidInfoCloseButton") then SK.Close(G("RaidInfoCloseButton")) end
        SK.ScrollBar(info.ScrollBar)
        SK.Auto(info)
    end
    SK.Check(G("RaidFrameAllAssistCheckButton"))
end)

SK.Define("raid", function()
    for g = 1, (MAX_RAID_GROUPS or 8) do
        local grp = G("RaidGroup" .. g)
        if grp then
            SK.Strip(grp)
            for j = 1, 5 do
                local slot = G("RaidGroup" .. g .. "Slot" .. j)
                if slot then
                    SK.Strip(slot)
                    SK.Backdrop(slot, "panel")
                end
            end
        end
    end
    for i = 1, (MAX_RAID_GROUPS or 8) * 5 do
        local b = G("RaidGroupButton" .. i)
        if b and SK.Once(b) then
            SK.Strip(b)
            SK.Backdrop(b, "button")
            SK.Hover(b)
        end
    end
end)

-- ============================================================================
-- Chat channels
-- ============================================================================

SK.Define("channels", function()
    local f = G("ChannelFrame")
    if not f then return end
    SK.Window(f)
    SK.Button(f.SettingsButton)
    SK.Button(f.NewButton)
    if f.NewButton then
        f.NewButton:ClearAllPoints()
        f.NewButton:SetPoint("BOTTOMLEFT", f, 4, 4)
    end
    if f.ChannelRoster then SK.ScrollBar(f.ChannelRoster.ScrollBar) end
    local list = f.ChannelList
    if list then
        SK.ScrollBar(list.ScrollBar)
        if list.ScrollBar then list.ScrollBar:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 0, 15) end
    end
    local popup = G("CreateChannelPopup")
    if popup then
        Dialog(popup)
        Buttons(popup.OKButton, popup.CancelButton)
        SK.EditBox(popup.Name)
        SK.EditBox(popup.Password)
    end
    local voice = G("VoiceChatPromptActivateChannel")
    if voice then Dialog(voice) end
    -- Channel group headers, made per header from a mixin.
    local mixin = _G.ChannelButtonHeaderMixin
    if mixin and mixin.Update then
        hooksecurefunc(mixin, "Update", function(header)
            local r, g, b = SK.AccentRGB()
            if header.HighlightTexture then
                header.HighlightTexture:SetColorTexture(r, g, b, 0.25)
                header.HighlightTexture:SetAllPoints()
            end
            if header.NormalTexture then header.NormalTexture:SetAlpha(0) end
            if not SK.GetBackdrop(header) then SK.Backdrop(header, "button") end
        end)
    end
    SK.Auto(f)
end)
