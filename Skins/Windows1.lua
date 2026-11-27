-- Skins/Windows1.lua
-- Batch 1 of the window skins (Skins/Skins.lua is the engine): popups and the
-- game menu, gossip and books, the quest windows, the merchant, mail.
-- Every lookup is guarded, so a piece Blizzard renames or a client lacks is
-- skipped instead of stopping the rest of the window.

local _, ns = ...
local SK = ns.Skins
local Hide = SK.Hide

local function G(name) return _G[name] end

local function Buttons(...)
    for i = 1, select("#", ...) do SK.Button(G(select(i, ...))) end
end

local function HideNamedRegions(...)
    for i = 1, select("#", ...) do Hide(G(select(i, ...))) end
end

local FOREVER = ns.BH.IS_FOREVER

-- A quest-style reward / progress item: icon cropped with a quality border,
-- the name plate gone, the name kept.
local function RewardButton(btn)
    if not btn or not SK.Once(btn) then return end
    Hide(btn.NameFrame or G((btn:GetName() or "") .. "NameFrame"))
    local icon = btn.Icon or G((btn:GetName() or "") .. "IconTexture")
    local border = SK.Icon(icon)
    SK.QualityBorder(btn.IconBorder, border)
    local hl = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if hl and icon then
        hl:SetColorTexture(1, 1, 1, 0.15)
        hl:SetAllPoints(icon)
    end
end

-- ============================================================================
-- Popups and the game menu
-- ============================================================================

SK.Define("misc", function()
    for i = 1, 4 do
        local p = G("StaticPopup" .. i)
        if p and SK.Once(p) then
            Hide(p.BG)
            Hide(p.Border)
            SK.Backdrop(p, "panel")
            SK.Shadow(p)
            local bc = p.ButtonContainer
            for b = 1, 4 do SK.Button(bc and bc["Button" .. b] or p["button" .. b]) end
            SK.Button(p.ExtraButton)
            if p.CloseButton then SK.Close(p.CloseButton) end
            if p.EditBox then SK.EditBox(p.EditBox, -2, 0, 2, 0) end
            if p.Dropdown then SK.Dropdown(p.Dropdown) end
            SK.MoneyInput(p.MoneyInputFrame)
            local item = p.ItemFrame
            if item then
                Hide(item.NameFrame)
                if item.Item then SK.ItemButton(item.Item) end
            end
        end
    end

    local menu = G("GameMenuFrame")
    if menu and SK.Once(menu) then
        SK.Strip(menu)
        Hide(menu.Border)
        if menu.Header then
            SK.Strip(menu.Header)
            menu.Header:ClearAllPoints()
            menu.Header:SetPoint("TOP", menu, "TOP", 0, 7)
        end
        SK.Backdrop(menu, "panel")
        SK.Shadow(menu)
        local function Skin(self)
            if not self.buttonPool then return end
            for btn in self.buttonPool:EnumerateActive() do SK.Button(btn, 1, -1, -1, 1) end
        end
        if menu.InitButtons then hooksecurefunc(menu, "InitButtons", Skin) end
        Skin(menu)
    end

    -- Small boxes that pop up round the screen.
    for _, n in ipairs({ "AddonCompartmentFrame", "AutoCompleteBox", "QueueStatusFrame", "OpacityFrame",
                         "BasicMessageDialog", "ReadyCheckFrame", "ReadyCheckListenerFrame", "LFDRoleCheckPopup",
                         "SideDressUpFrame" }) do
        local f = G(n)
        if f then
            Hide(f.StateTexture)
            Hide(f.BGTopLeft)
            Hide(f.BGBottomLeft)
            SK.Window(f)
            SK.Auto(f)
        end
    end
    -- The ready check: its portrait gone, the buttons side by side under the text.
    local rc = G("ReadyCheckFrame")
    if rc then
        Hide(G("ReadyCheckPortrait"))
        local text, yes, no = G("ReadyCheckFrameText"), G("ReadyCheckFrameYesButton"), G("ReadyCheckFrameNoButton")
        if text then
            text:ClearAllPoints()
            text:SetPoint("TOP", 0, -30)
            text:SetWidth(300)
        end
        if yes then yes:ClearAllPoints(); yes:SetPoint("TOPRIGHT", rc, "CENTER", -3, -5) end
        if no then no:ClearAllPoints(); no:SetPoint("TOPLEFT", rc, "CENTER", 3, -5) end
        local listener = G("ReadyCheckListenerFrame")
        local title = listener and listener.TitleContainer
        if title then
            title:ClearAllPoints()
            title:SetPoint("TOPLEFT", 1, -1)
            title:SetPoint("TOPRIGHT", -1, 0)
        end
    end
    for _, role in ipairs({ "Tank", "Healer", "DPS" }) do
        local b = G("LFDRoleCheckPopupRoleButton" .. role)
        if b and b.checkButton then
            SK.Check(b.checkButton)
            b:DisableDrawLayer("OVERLAY")
        end
    end

    -- Splitting a stack: the arrows inside a box either side of the number.
    local split = G("StackSplitFrame")
    if split and SK.Once(split) then
        SK.Strip(split)
        local outer = SK.Backdrop(split, "panel")
        SK.Shadow(split)
        -- An inner box round the number, drawn on our own backdrop so it sits
        -- under the window's text (its colours follow after a /reload).
        local px = SK.Pixel(split)
        local inner = outer:CreateTexture(nil, "ARTWORK")
        inner:SetPoint("TOPLEFT", split, "TOPLEFT", 10, -15)
        inner:SetPoint("BOTTOMRIGHT", split, "BOTTOMRIGHT", -10, 55)
        inner:SetColorTexture(SK.PanelRGBA())
        local br, bg, bb = SK.BorderRGB()
        local function Edge(a, b, across)
            local e = outer:CreateTexture(nil, "OVERLAY")
            e:SetColorTexture(br, bg, bb)
            e:SetPoint(a, inner, a)
            e:SetPoint(b, inner, b)
            if across then e:SetWidth(px) else e:SetHeight(px) end
        end
        Edge("TOPLEFT", "TOPRIGHT", false)
        Edge("BOTTOMLEFT", "BOTTOMRIGHT", false)
        Edge("TOPLEFT", "BOTTOMLEFT", true)
        Edge("TOPRIGHT", "BOTTOMRIGHT", true)
        SK.Button(split.OkayButton or G("StackSplitOkayButton"))
        SK.Button(split.CancelButton or G("StackSplitCancelButton"))
        local left, right = split.LeftButton or G("StackSplitLeftButton"), split.RightButton or G("StackSplitRightButton")
        if left then left:ClearAllPoints(); left:SetPoint("LEFT", inner, "LEFT", 4, 0); SK.Arrow(left, "left") end
        if right then right:ClearAllPoints(); right:SetPoint("RIGHT", inner, "RIGHT", -4, 0); SK.Arrow(right, "right") end
    end

    -- The "return to graveyard" box after a death.
    local ghost = G("GhostFrame")
    if ghost and SK.Once(ghost) then
        HideNamedRegions("GhostFrameLeft", "GhostFrameMiddle", "GhostFrameRight")
        SK.Strip(ghost)
        ghost:ClearAllPoints()
        ghost:SetPoint("TOP", UIParent, "TOP", 0, -200)
        local contents = G("GhostFrameContentsFrame")
        if contents then
            SK.Backdrop(contents, "panel")
            local t, icon = G("GhostFrameContentsFrameText"), G("GhostFrameContentsFrameIcon")
            if t then t:SetPoint("TOPLEFT", 53, 0) end
            if icon then
                icon:SetSize(37, 38)
                icon:ClearAllPoints()
                if t then icon:SetPoint("RIGHT", t, "LEFT", -12, 0) end
                SK.Icon(icon)
            end
        end
    end

    -- The splash screen of what is new, and the cinematic / movie "skip?" boxes.
    local splash = G("SplashFrame")
    if splash then
        if splash.TopCloseButton then SK.Close(splash.TopCloseButton) end
        SK.Button(splash.BottomCloseButton)
    end
    local function CloseDialog(d)
        if not d or not SK.Once(d) then return end
        SK.Strip(d)
        SK.Backdrop(d, "panel")
        local name = d:GetName()
        SK.Button(name and G(name .. "ConfirmButton"))
        SK.Button(name and G(name .. "ResumeButton"))
        if d.Buttons then
            SK.Button(d.Buttons.ConfirmButton)
            SK.Button(d.Buttons.ResumeButton)
        end
    end
    if CinematicFrame_UpdateLettboxForAspectRatio then
        hooksecurefunc("CinematicFrame_UpdateLettboxForAspectRatio", function(f) CloseDialog(f.closeDialog) end)
    end
    local movie = G("MovieFrame")
    if movie and movie.ShowCloseDialog then
        hooksecurefunc(movie, "ShowCloseDialog", function(f) CloseDialog(f.CloseDialog) end)
    end

    -- The old style dropdown lists some addons still use.
    local function DropLists()
        for i = 1, (UIDROPDOWNMENU_MAXLEVELS or 3) do
            local list = G("DropDownList" .. i)
            if list and SK.Once(list) then
                Hide(G("DropDownList" .. i .. "Backdrop"))
                Hide(G("DropDownList" .. i .. "MenuBackdrop"))
                SK.Backdrop(list, "panel")
            end
        end
    end
    DropLists()
    if UIDropDownMenu_CreateFrames then hooksecurefunc("UIDropDownMenu_CreateFrames", DropLists) end
end)

-- ============================================================================
-- Gossip and books
-- ============================================================================

SK.Define("gossip", function()
    local parchment = SK.ParchmentActive()
    local gossip = G("GossipFrame")
    if gossip then
        SK.Window(gossip, nil, nil, nil, nil, (not parchment and gossip.Background) and { [gossip.Background] = true } or nil)
        local panel = gossip.GreetingPanel
        if panel then
            if parchment then SK.Strip(panel) end
            SK.Button(panel.GoodbyeButton)
            SK.ScrollBar(panel.ScrollBar)
        end
        -- The friendship bar's notches as thin black lines.
        local bar = gossip.FriendshipStatusBar
        if bar then
            for i = 1, 4 do
                local notch = bar["Notch" .. i]
                if notch then
                    notch:SetColorTexture(0, 0, 0)
                    notch:SetSize(1, 16)
                end
            end
        end
    end

    local book = G("ItemTextFrame")
    if book then
        -- The page and its material corners stay unless the parchment goes.
        local keep
        if not parchment then
            keep = {}
            for _, n in ipairs({ "ItemTextFramePageBg", "ItemTextMaterialTopLeft", "ItemTextMaterialTopRight",
                                 "ItemTextMaterialBotLeft", "ItemTextMaterialBotRight" }) do
                if G(n) then keep[G(n)] = true end
            end
        end
        SK.Window(book, nil, nil, nil, nil, keep)
        SK.ScrollFrame(G("ItemTextScrollFrame"))
        if G("ItemTextStatusBar") then SK.StatusBar(G("ItemTextStatusBar")) end
        if G("ItemTextPrevPageButton") then SK.Arrow(G("ItemTextPrevPageButton"), "left") end
        if G("ItemTextNextPageButton") then SK.Arrow(G("ItemTextNextPageButton"), "right") end
    end
end)

-- ============================================================================
-- Quest windows
-- ============================================================================

SK.Define("quest", function()
    local parchment = SK.ParchmentActive()
    local quest = G("QuestFrame")
    if quest then
        SK.Window(quest)
        for _, n in ipairs({ "QuestFrameDetailPanel", "QuestFrameGreetingPanel", "QuestFrameProgressPanel",
                             "QuestFrameRewardPanel" }) do
            local panel = G(n)
            if panel and parchment then SK.Strip(panel) end
        end
        for _, n in ipairs({ "QuestDetailScrollFrame", "QuestGreetingScrollFrame", "QuestProgressScrollFrame",
                             "QuestRewardScrollFrame" }) do
            SK.ScrollFrame(G(n))
        end
        Buttons("QuestFrameAcceptButton", "QuestFrameDeclineButton", "QuestFrameCompleteButton",
                "QuestFrameCompleteQuestButton", "QuestFrameGoodbyeButton", "QuestFrameGreetingGoodbyeButton")
        Hide(G("QuestGreetingFrameHorizontalBreak"))
        for i = 1, 6 do RewardButton(G("QuestProgressItem" .. i)) end
    end

    -- The NPC's model and speech beside the window.
    local scene = G("QuestModelScene")
    if scene and SK.Once(scene) then
        SK.Strip(scene)
        Hide(scene.BorderFrame)
        SK.Backdrop(scene, "panel")
        local text = scene.ModelTextFrame
        if text then
            SK.Strip(text)
            SK.Backdrop(text, "panel")
        end
        SK.ScrollFrame(G("QuestNPCModelTextScrollFrame"))
    end

    -- A quest opened from the log.
    local popup = G("QuestLogPopupDetailFrame")
    if popup then
        local keep
        if not parchment then
            keep = {}
            for _, k in ipairs({ "Bg", "SealMaterialBG", "MaterialTopLeft", "MaterialTopRight", "MaterialBotLeft",
                                 "MaterialBotRight" }) do
                if popup[k] then keep[popup[k]] = true end
            end
        end
        SK.Window(popup, nil, nil, nil, nil, keep)
        SK.ScrollFrame(popup.ScrollFrame or G("QuestLogPopupDetailFrameScrollFrame"))
        for _, k in ipairs({ "AbandonButton", "TrackButton", "ShareButton" }) do SK.Button(popup[k]) end
    end

    -- The chosen reward: Blizzard's glow becomes a plain gold edge.
    local chosen = G("QuestInfoItemHighlight")
    if chosen and SK.Once(chosen) then
        SK.Strip(chosen)
        chosen:SetSize(142, 40)
        local b = SK.Backdrop(chosen, "none")
        b:SetFrameLevel(chosen:GetFrameLevel() + 1)
        b:SetBackdropBorderColor(1, 1, 0)
    end

    -- The other rewards (experience, money, honour, a title...).
    for _, f in ipairs({ G("QuestInfoRewardsFrame"), G("MapQuestInfoRewardsFrame") }) do
        if f then
            for _, k in ipairs({ "HonorFrame", "XPFrame", "SkillPointFrame", "ArtifactXPFrame", "TitleFrame",
                                 "WarModeBonusFrame", "MoneyFrame" }) do
                RewardButton(f[k])
            end
        end
    end
    local title = G("QuestInfoPlayerTitleFrame")
    if title then
        Hide(title.FrameLeft)
        Hide(title.FrameCenter)
        Hide(title.FrameRight)
        if title.Icon then SK.Icon(title.Icon) end
    end
    RewardButton(G("QuestInfoSkillPointFrame"))

    -- Reward buttons are made as quests need them.
    local function Rewards(frame)
        if frame and frame.RewardButtons then
            for _, b in pairs(frame.RewardButtons) do RewardButton(b) end
        end
    end
    if QuestInfo_GetRewardButton then
        hooksecurefunc("QuestInfo_GetRewardButton", function(frame, index)
            local b = frame and frame.RewardButtons and frame.RewardButtons[index]
            if b then RewardButton(b) end
        end)
    end
    Rewards(G("QuestInfoRewardsFrame"))
    Rewards(G("MapQuestInfoRewardsFrame"))
end)

-- ============================================================================
-- Merchant
-- ============================================================================

-- One item for sale: a see-through box round icon, name and price.
local function MerchantSlot(slot, x1, y1, x2, y2)
    if not slot or not SK.Once(slot) then return end
    local name = slot:GetName() or ""
    Hide(slot.SlotTexture or G(name .. "SlotTexture"))
    Hide(G(name .. "NameFrame"))
    SK.Strip(slot)
    SK.Backdrop(slot, "panel", x1 or -3, y1 or 2, x2 or 2, y2 or -3)
    local btn = slot.ItemButton or G(name .. "ItemButton")
    if btn then
        SK.ItemButton(btn)
        if btn.IconOverlay then
            local px = SK.Pixel(btn)
            btn.IconOverlay:ClearAllPoints()
            btn.IconOverlay:SetPoint("TOPLEFT", px, -px)
            btn.IconOverlay:SetPoint("BOTTOMRIGHT", -px, px)
        end
    end
    for j = 1, (MAX_ITEM_COST or 3) do
        local t = G(name .. "AltCurrencyFrameItem" .. j .. "Texture")
        if t then t:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    end
end

SK.Define("merchant", function()
    local m = G("MerchantFrame")
    if not m then return end
    SK.Window(m)
    for _, n in ipairs({ "MerchantFrameBottomLeftBorder", "BuybackBG" }) do Hide(G(n)) end
    for i = 1, math.max(MERCHANT_ITEMS_PER_PAGE or 10, BUYBACK_ITEMS_PER_PAGE or 12) do MerchantSlot(G("MerchantItem" .. i)) end
    MerchantSlot(G("MerchantBuyBackItem"), -6, 6, 6, -6)
    for _, n in ipairs({ "MerchantMoneyInset", "MerchantExtraCurrencyInset" }) do SK.Inset(G(n)) end
    for _, n in ipairs({ "MerchantMoneyBg", "MerchantExtraCurrencyBg" }) do SK.Strip(G(n)) end
    if G("MerchantPrevPageButton") then
        SK.Strip(G("MerchantPrevPageButton"))
        SK.Arrow(G("MerchantPrevPageButton"), "left")
    end
    if G("MerchantNextPageButton") then
        SK.Strip(G("MerchantNextPageButton"))
        SK.Arrow(G("MerchantNextPageButton"), "right")
    end
    SK.NumberedTabs(m, "MerchantFrameTab")
    if m.FilterDropdown then SK.Dropdown(m.FilterDropdown) end
    -- The square repair and junk buttons: their empty-slot ring goes, the
    -- icon stays.
    for _, n in ipairs({ "MerchantSellAllJunkButton", "MerchantRepairAllButton", "MerchantRepairItemButton",
                         "MerchantGuildBankRepairButton" }) do
        local b = G(n)
        if b and SK.Once(b) then
            for _, r in ipairs({ b:GetRegions() }) do
                if r:IsObjectType("Texture") and r:GetDrawLayer() == "BACKGROUND" and r ~= b.Icon then r:SetAlpha(0) end
            end
            SK.Backdrop(b, "button")
            SK.Hover(b)
        end
    end
end)

-- ============================================================================
-- Mail
-- ============================================================================

-- Inbox rows: the border art gone (one box round the whole list), the
-- item icon square with a quality border.
local function MailRow(row)
    if not row or not SK.Once(row) then return end
    SK.Strip(row)
    local btn = row.Button or G((row:GetName() or "") .. "Button")
    if btn then
        Hide(G((btn:GetName() or "") .. "Slot"))
        local icon = btn.Icon
        if icon then
            local px = SK.Pixel(btn)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            icon:ClearAllPoints()
            icon:SetPoint("TOPLEFT", px, -px)
            icon:SetPoint("BOTTOMRIGHT", -px, px)
        end
        local hl = btn.GetHighlightTexture and btn:GetHighlightTexture()
        if hl then hl:SetColorTexture(1, 1, 1, 0.15); if icon then hl:SetAllPoints(icon) end end
        local ck = btn.GetCheckedTexture and btn:GetCheckedTexture()
        if ck then ck:SetColorTexture(1, 1, 1, 0.25); if icon then ck:SetAllPoints(icon) end end
        local b = SK.Backdrop(btn, "button")
        SK.QualityBorder(btn.IconBorder, b)
    end
end

-- Send attachments: the item's icon is the button's own normal texture, so
-- only the empty-slot background goes.
local function SendAttachment(btn)
    if not btn or not SK.Once(btn) then return end
    local keep = { [btn.IconBorder or 0] = true, [btn.IconOverlay or 0] = true, [btn.IconOverlay2 or 0] = true }
    for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture" }) do
        local t = btn[getter](btn)
        if t then keep[t] = true end
    end
    for _, r in ipairs({ btn:GetRegions() }) do
        if r:IsObjectType("Texture") and not keep[r] then r:SetAlpha(0) end
    end
    local b = SK.Backdrop(btn, "button")
    SK.QualityBorder(btn.IconBorder, b)
end

SK.Define("mail", function()
    local mail = G("MailFrame")
    if mail then
        SK.Window(mail)
        Hide(G("InboxFrameBg"))
        SK.Strip(G("InboxFrame"))
        SK.Inset(G("MailFrameInset"))
        for i = 1, (INBOXITEMS_TO_DISPLAY or 7) do MailRow(G("MailItem" .. i)) end
        local first, last = G("MailItem1"), G("MailItem" .. (INBOXITEMS_TO_DISPLAY or 7))
        local inbox = G("InboxFrame")
        if inbox and first and last then
            local b = SK.Backdrop(inbox, "panel")
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", first, "TOPLEFT")
            b:SetPoint("BOTTOMRIGHT", last, "BOTTOMRIGHT")
        end
        -- Page buttons: Forever keeps them on the inbox and labels them.
        local prev = (inbox and inbox.PrevPageButton) or G("InboxPrevPageButton")
        local nextB = (inbox and inbox.NextPageButton) or G("InboxNextPageButton")
        if prev then SK.HideTexts(prev); SK.Arrow(prev, "left") end
        if nextB then SK.HideTexts(nextB); SK.Arrow(nextB, "right") end
        if not FOREVER then
            if prev then prev:SetPoint("BOTTOMLEFT", 30, 100) end
            if nextB then nextB:SetPoint("BOTTOMRIGHT", -80, 100) end
        end
        Buttons("OpenAllMail", "SendMailMailButton", "SendMailCancelButton")
        SK.NumberedTabs(mail, "MailFrameTab")
        SK.Radio(G("SendMailSendMoneyButton"))
        SK.Radio(G("SendMailCODButton"))
        local sendMoney, money = G("SendMailSendMoneyButton"), G("SendMailMoney")
        if sendMoney and money then
            sendMoney:ClearAllPoints()
            sendMoney:SetPoint("TOPRIGHT", money, "TOPRIGHT", 30, 8)
        end
        local mb, cb = G("SendMailMailButton"), G("SendMailCancelButton")
        if mb and cb then mb:SetPoint("RIGHT", cb, "LEFT", -2, 0) end
        -- The letter text in white on the dark page.
        for _, f in ipairs({ "MailTextFontNormal", "InvoiceTextFontNormal" }) do
            local font = G(f)
            if font then font:SetTextColor(1, 1, 1) end
        end

        -- Sending.
        for _, n in ipairs({ "SendMailHorizontalBarLeft", "SendMailHorizontalBarLeft2", "SendStationeryBackgroundLeft",
                             "SendStationeryBackgroundRight" }) do
            Hide(G(n))
        end
        SK.ScrollFrame(G("SendMailScrollFrame"))
        if G("SendMailScrollFrame") then SK.Backdrop(G("SendMailScrollFrame"), "panel", -4, 4, 4, -4) end
        if G("SendMailNameEditBox") then SK.EditBox(G("SendMailNameEditBox")) end
        if G("SendMailSubjectEditBox") then SK.EditBox(G("SendMailSubjectEditBox")) end
        SK.MoneyInput(G("SendMailMoney"))
        SK.Inset(G("SendMailMoneyInset"))
        SK.Strip(G("SendMailMoneyBg"))
        local sendFrame = G("SendMailFrame")
        local atts = sendFrame and sendFrame.SendMailAttachments
        if atts then
            for _, b in ipairs(atts) do SendAttachment(b) end
        else
            for i = 1, 16 do SendAttachment(G("SendMailAttachment" .. i)) end
        end
    end

    -- Reading.
    local open = G("OpenMailFrame")
    if open then
        SK.Window(open)
        for _, n in ipairs({ "OpenMailHorizontalBarLeft", "OpenStationeryBackgroundLeft",
                             "OpenStationeryBackgroundRight", "OpenMailArithmeticLine" }) do
            Hide(G(n))
        end
        SK.ScrollFrame(G("OpenMailScrollFrame"))
        if G("OpenMailScrollFrame") then SK.Backdrop(G("OpenMailScrollFrame"), "panel", -4, 4, 4, -4) end
        SK.Inset(G("OpenMailFrameInset"))
        Buttons("OpenMailReplyButton", "OpenMailDeleteButton", "OpenMailCancelButton", "OpenMailReportSpamButton")
        local reply, del, cancel = G("OpenMailReplyButton"), G("OpenMailDeleteButton"), G("OpenMailCancelButton")
        if reply and del then reply:SetPoint("RIGHT", del, "LEFT", -2, 0) end
        if del and cancel then del:SetPoint("RIGHT", cancel, "LEFT", -2, 0) end
        if G("OpenMailLetterButton") then SK.ItemButton(G("OpenMailLetterButton")) end
        if G("OpenMailMoneyButton") then SK.ItemButton(G("OpenMailMoneyButton")) end
        for i = 1, 16 do
            local b = G("OpenMailAttachmentButton" .. i)
            if b then SK.ItemButton(b) end
        end
    end
end)
