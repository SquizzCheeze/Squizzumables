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
        Hide(menu.Border)
        if menu.Header then SK.Strip(menu.Header) end
        SK.Backdrop(menu, "panel")
        SK.Shadow(menu)
        local function Skin(self)
            if not self.buttonPool then return end
            for btn in self.buttonPool:EnumerateActive() do SK.Button(btn) end
        end
        if menu.InitButtons then hooksecurefunc(menu, "InitButtons", Skin) end
        Skin(menu)
    end
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

    Hide(G("QuestInfoItemHighlight"))

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

local function MerchantSlot(slot)
    if not slot then return end
    local name = slot:GetName() or ""
    Hide(slot.SlotTexture or G(name .. "SlotTexture"))
    Hide(G(name .. "NameFrame"))
    local btn = slot.ItemButton or G(name .. "ItemButton")
    if btn then SK.ItemButton(btn) end
end

SK.Define("merchant", function()
    local m = G("MerchantFrame")
    if not m then return end
    SK.Window(m)
    for _, n in ipairs({ "MerchantFrameBottomLeftBorder", "BuybackBG" }) do Hide(G(n)) end
    for i = 1, 12 do MerchantSlot(G("MerchantItem" .. i)) end
    MerchantSlot(G("MerchantBuyBackItem"))
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
    for i = 1, 2 do if G("MerchantFrameTab" .. i) then SK.Tab(G("MerchantFrameTab" .. i)) end end
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

-- Inbox rows: the border art gone, the item icon cropped with a quality border.
local function MailRow(row)
    if not row or not SK.Once(row) then return end
    SK.Strip(row)
    SK.Backdrop(row, "panel", 0, 0, 0, 0)
    local btn = row.Button or G((row:GetName() or "") .. "Button")
    if btn then
        Hide(G((btn:GetName() or "") .. "Slot"))
        local border = SK.Icon(btn.Icon)
        SK.QualityBorder(btn.IconBorder, border)
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
        for i = 1, 7 do MailRow(G("MailItem" .. i)) end
        if G("InboxPrevPageButton") then SK.Arrow(G("InboxPrevPageButton"), "left") end
        if G("InboxNextPageButton") then SK.Arrow(G("InboxNextPageButton"), "right") end
        Buttons("OpenAllMail", "SendMailMailButton", "SendMailCancelButton")
        for i = 1, 2 do if G("MailFrameTab" .. i) then SK.Tab(G("MailFrameTab" .. i)) end end

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
        Buttons("OpenMailReplyButton", "OpenMailDeleteButton", "OpenMailCancelButton", "OpenMailReportSpamButton")
        if G("OpenMailLetterButton") then SK.ItemButton(G("OpenMailLetterButton")) end
        for i = 1, 16 do
            local b = G("OpenMailAttachmentButton" .. i)
            if b then SK.ItemButton(b) end
        end
    end
end)
