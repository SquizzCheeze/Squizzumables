-- Skins/Windows4.lua
-- Batch 4 of the window skins: trade and items. The auction house,
-- professions and crafting orders, the trainer, loot (the window, rolls,
-- bonus rolls, history), bags and bank, the guild bank and macros.
--
-- Read against ElvUI's own skin for each window (behaviour only, none of its
-- code), on retail and Forever alike: every lookup below is guarded, since
-- the two clients build some of these windows differently.

local _, ns = ...
local SK = ns.Skins
local Hide = SK.Hide
local FOREVER = ns.BH.IS_FOREVER

local function G(name) return _G[name] end

local function Buttons(...)
    for i = 1, select("#", ...) do SK.Button(select(i, ...)) end
end

-- Hooks a method if the object has it.
local function Hook(obj, method, fn)
    if obj and obj[method] then hooksecurefunc(obj, method, fn) end
end

local function HookGlobal(name, fn)
    if _G[name] then hooksecurefunc(name, fn) end
end

-- Normal / pushed / highlight art away on a button whose icon carries it.
local function HideStateOf(btn)
    for _, g in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture" }) do
        local t = btn[g] and btn[g](btn)
        if t then t:SetAlpha(0) end
    end
end

-- The usual "the list sits in a see-through box" treatment.
local function ListBox(f, x1, y1, x2, y2)
    if not f then return end
    SK.Strip(f)
    Hide(f.NineSlice)
    Hide(f.BackgroundNineSlice)
    SK.Backdrop(f, "panel", x1, y1, x2, y2)
    if f.ScrollBar then SK.ScrollBar(f.ScrollBar) end
end

-- A see-through box round something already there.
local function Box(f, x1, y1, x2, y2)
    if not f then return end
    SK.Strip(f)
    return SK.Backdrop(f, "panel", x1, y1, x2, y2)
end

-- ============================================================================
-- Auction house
-- ============================================================================

local function ItemDisplay(display)
    if not display or not SK.Once(display) then return end
    SK.Strip(display)
    SK.Backdrop(display, "panel", 3, -3, -3, 0)
    local btn = display.ItemButton
    if btn then
        SK.Slot(btn)
        if btn.Highlight then btn.Highlight:SetColorTexture(1, 1, 1, 0.25) end
    end
end

-- Icons inside a table (search results, your auctions).
local function TableIcons(list)
    local builder = list and list.tableBuilder
    if not builder or not builder.rows then return end
    for _, row in pairs(builder.rows) do
        for _, cell in pairs(row.cells or {}) do
            if cell.Icon and SK.Once(cell) then
                SK.Icon(cell.Icon)
                Hide(cell.IconBorder)
            end
        end
    end
end

local function SellList(list, hasHeader)
    if not list then return end
    SK.Strip(list)
    if list.RefreshFrame and list.RefreshFrame.RefreshButton then
        SK.Button(list.RefreshFrame.RefreshButton)
        list.RefreshFrame.RefreshButton:SetSize(22, 22)
    end
    SK.ScrollBar(list.ScrollBar)
    if hasHeader then
        if list.ScrollBox then SK.Backdrop(list.ScrollBox, "panel") end
        local function Headers(self)
            SK.TableHeaders(self.HeaderContainer)
            TableIcons(self)
        end
        Hook(list, "RefreshScrollFrame", Headers)
    else
        SK.EachRow(list.ScrollBox, function(child)
            if child.Icon and SK.Once(child) then
                SK.Icon(child.Icon)
                Hide(child.IconBorder)
            end
        end)
    end
end

local function MoneyBoxes(m)
    if not m then return end
    for _, k in ipairs({ "GoldBox", "SilverBox", "CopperBox", "gold", "silver", "copper" }) do
        local box = m[k]
        if box then
            box:DisableDrawLayer("BACKGROUND")
            SK.EditBox(box)
        end
    end
end

local function SellFrame(f)
    if not f then return end
    SK.Strip(f)
    ItemDisplay(f.ItemDisplay)
    local d = f.ItemDisplay
    if d then
        local b = SK.GetBackdrop(d)
        if b then b:ClearAllPoints(); b:SetAllPoints(d) end
    end
    if f.QuantityInput then
        SK.EditBox(f.QuantityInput.InputBox)
        SK.Button(f.QuantityInput.MaxButton)
    end
    if f.PriceInput then MoneyBoxes(f.PriceInput.MoneyInputFrame) end
    if f.SecondaryPriceInput then MoneyBoxes(f.SecondaryPriceInput.MoneyInputFrame) end
    if f.Duration and f.Duration.Dropdown then SK.Dropdown(f.Duration.Dropdown) end
    SK.Button(f.PostButton)
    if f.BuyoutModeCheckButton then
        SK.Check(f.BuyoutModeCheckButton)
        f.BuyoutModeCheckButton:SetSize(20, 20)
    end
end

local function AuctionHouse()
    local ah = G("AuctionHouseFrame")
    if not ah then return end
    SK.Window(ah)

    -- Tabs: ElvUI's row, and addons that add their own (Auctionator, TSM) fit in.
    local function Tabs(frame)
        if frame ~= ah or not ah.Tabs then return end
        local last
        for i, tab in ipairs(ah.Tabs) do
            if tab == G("AuctionHouseFrameBuyTab") or tab == G("AuctionHouseFrameSellTab") or tab == G("AuctionHouseFrameAuctionsTab") then
                SK.Tab(tab)
            end
            tab:ClearAllPoints()
            if i == 1 then
                tab:SetPoint("TOPLEFT", ah, "BOTTOMLEFT", -3, 0)
            else
                tab:SetPoint("TOPLEFT", last, "TOPRIGHT", SK.GetBackdrop(tab) and -5 or 0, 0)
            end
            last = tab
        end
    end
    HookGlobal("PanelTemplates_SetNumTabs", Tabs)
    Tabs(ah)

    local bar = ah.SearchBar
    if bar then
        if bar.FilterButton then
            SK.Button(bar.FilterButton)
            if bar.FilterButton.ClearFiltersButton then SK.Close(bar.FilterButton.ClearFiltersButton) end
        end
        SK.Button(bar.SearchButton)
        SK.EditBox(bar.SearchBox)
        if bar.FavoritesSearchButton then
            SK.Button(bar.FavoritesSearchButton)
            bar.FavoritesSearchButton:SetSize(22, 22)
        end
    end
    SK.Strip(ah.MoneyFrameBorder)
    SK.Strip(ah.MoneyFrameInset)
    Hide(ah.MoneyFrameInset and ah.MoneyFrameInset.NineSlice)

    local cats = ah.CategoriesList
    if cats then
        SK.Strip(cats)
        Hide(cats.NineSlice)
        SK.Backdrop(cats, "panel")
        SK.ScrollBar(cats.ScrollBar)
    end
    HookGlobal("AuctionHouseFilterButton_SetUp", function(btn)
        if btn.NormalTexture then btn.NormalTexture:SetAlpha(0) end
        local r, g, b = SK.AccentRGB()
        if btn.SelectedTexture then btn.SelectedTexture:SetColorTexture(r, g, b, 0.25) end
        if btn.HighlightTexture then btn.HighlightTexture:SetColorTexture(1, 1, 1, 0.1) end
    end)

    local browse = ah.BrowseResultsFrame and ah.BrowseResultsFrame.ItemList
    if browse then
        SK.Strip(browse)
        Hide(browse.NineSlice)
        SK.Backdrop(browse, "panel")
        SK.ScrollBar(browse.ScrollBar)
        Hook(browse, "RefreshScrollFrame", function(self)
            SK.TableHeaders(self.HeaderContainer)
            TableIcons(self)
        end)
    end

    local cbuy = ah.CommoditiesBuyFrame
    if cbuy then
        SK.Button(cbuy.BackButton)
        local list = cbuy.ItemList
        if list then
            ListBox(list)
            if list.RefreshFrame then SK.Button(list.RefreshFrame.RefreshButton) end
        end
        local d = cbuy.BuyDisplay
        if d then
            SK.Strip(d)
            if d.QuantityInput then SK.EditBox(d.QuantityInput.InputBox) end
            SK.Button(d.BuyButton)
            ItemDisplay(d.ItemDisplay)
        end
    end

    local ibuy = ah.ItemBuyFrame
    if ibuy then
        SK.Button(ibuy.BackButton)
        if ibuy.BuyoutFrame then SK.Button(ibuy.BuyoutFrame.BuyoutButton) end
        ItemDisplay(ibuy.ItemDisplay)
        local list = ibuy.ItemList
        if list then
            ListBox(list)
            if list.RefreshFrame then SK.Button(list.RefreshFrame.RefreshButton) end
            Hook(list, "RefreshScrollFrame", function(self) SK.TableHeaders(self.HeaderContainer); TableIcons(self) end)
        end
        local bid = ibuy.BidFrame
        if bid then
            SK.Button(bid.BidButton)
            MoneyBoxes(bid.BidAmount)
            if bid.BidButton and bid.BidAmount then
                bid.BidButton:ClearAllPoints()
                if FOREVER and bid.BidAmount.copper then
                    bid.BidButton:SetPoint("LEFT", bid.BidAmount.copper, "RIGHT", 2, 0)
                else
                    bid.BidButton:SetPoint("LEFT", bid.BidAmount, "RIGHT", 2, -2)
                end
            end
        end
    end

    SellFrame(ah.ItemSellFrame)
    if ah.ItemSellFrame then SK.Backdrop(ah.ItemSellFrame, "panel") end
    SellList(ah.ItemSellList, true)
    SellFrame(ah.CommoditiesSellFrame)
    SellList(ah.CommoditiesSellList, true)

    local token = ah.WoWTokenSellFrame
    if token then
        SK.Strip(token)
        if token.ItemDisplay then
            SK.Strip(token.ItemDisplay)
            SK.Backdrop(token.ItemDisplay, "panel")
            if token.ItemDisplay.ItemButton then SK.Slot(token.ItemDisplay.ItemButton) end
        end
        SK.Button(token.PostButton)
        SK.Button(token.DummyRefreshButton)
        if token.DummyItemList then
            ListBox(token.DummyItemList)
            SK.ScrollBar(token.DummyItemList.DummyScrollBar)
        end
    end

    local auctions = G("AuctionHouseFrameAuctionsFrame")
    if auctions then
        SK.Strip(auctions)
        ItemDisplay(auctions.ItemDisplay)
        if auctions.BuyoutFrame then SK.Button(auctions.BuyoutFrame.BuyoutButton) end
        SellList(auctions.CommoditiesList, true)
        SellList(auctions.ItemList, true)
        SellList(auctions.AllAuctionsList, true)
        SellList(auctions.BidsList, true)
        SK.Tab(auctions.AuctionsTab)
        SK.Tab(auctions.BidsTab)
        local summary = auctions.SummaryList
        if summary then
            SellList(summary)
            SK.Backdrop(summary, "panel")
        end
        -- Left where Blizzard puts it: the auctions list hangs off this
        -- button, so anchoring the button to the list is a loop.
        SK.Button(auctions.CancelAuctionButton)
        local bid = auctions.BidFrame
        if bid then
            SK.Button(bid.BidButton)
            MoneyBoxes(bid.BidAmount)
            if FOREVER and bid.BidAmount and bid.BidAmount.copper and bid.BidButton then
                bid.BidButton:ClearAllPoints()
                bid.BidButton:SetPoint("LEFT", bid.BidAmount.copper, "RIGHT", 2, 0)
            end
        end
    end

    local results = ah.WoWTokenResults
    if results then
        SK.Strip(results)
        SK.Button(results.Buyout)
        SK.ScrollBar(results.DummyScrollBar)
        local disp = results.TokenDisplay
        if disp then
            SK.Strip(disp)
            SK.Backdrop(disp, "panel")
            local b = disp.ItemButton and SK.Slot(disp.ItemButton)
            if b then b:SetBackdropBorderColor(0, 0.8, 1) end
        end
        local tut = results.GameTimeTutorial
        if tut then
            SK.Window(tut)
            if tut.RightDisplay then SK.Button(tut.RightDisplay.StoreButton) end
        end
    end

    local dlg = ah.BuyDialog
    if dlg then
        SK.Strip(dlg)
        SK.Backdrop(dlg, "panel")
        Buttons(dlg.BuyNowButton, dlg.CancelButton)
    end
    local multi = G("AuctionHouseMultisellProgressFrame")
    if multi then
        SK.Strip(multi)
        SK.Backdrop(multi, "panel")
        local pb = multi.ProgressBar
        if pb then
            SK.StatusBar(pb)
            if pb.Icon then SK.Icon(pb.Icon) end
        end
        if multi.CancelButton then SK.Close(multi.CancelButton) end
    end
    SK.Auto(ah)
end

SK.Define("auctionhouse", AuctionHouse)

-- ============================================================================
-- Professions and crafting orders
-- ============================================================================

local function NumberBox(box)
    if not box then return end
    box:DisableDrawLayer("BACKGROUND")
    SK.EditBox(box)
    if box.DecrementButton then SK.Arrow(box.DecrementButton, "left") end
    if box.IncrementButton then SK.Arrow(box.IncrementButton, "right") end
end

-- A reagent slot on a recipe: square, quality on the border. The green
-- "+" of an empty optional slot stays.
local function ReagentSlot(button)
    if not button then return end
    Hide(button.CropFrame)
    Hide(button.SlotBackground)
    local hl = button:GetHighlightTexture()
    if hl then hl:SetColorTexture(1, 1, 1, 0.25) end
    local nt = button:GetNormalTexture()
    local plus = nt and nt:GetAtlas() == "ItemUpgrade_GreenPlusIcon"
    if nt then nt:SetAlpha(plus and 1 or 0) end
    local pt = button:GetPushedTexture()
    if pt then pt:SetAlpha(plus and 1 or 0) end
    if SK.Once(button) then
        local icon = button.Icon
        if icon then
            local border = SK.Icon(icon)
            SK.QualityBorder(button.IconBorder, border)
        end
    end
end

local function ItemFlyout(flyout)
    if not flyout or not SK.Once(flyout) then return end
    Hide(flyout.NineSlice)
    SK.Backdrop(flyout, "panel")
    SK.ScrollBar(flyout.ScrollBar)
    if flyout.HideUnownedCheckbox then
        SK.Check(flyout.HideUnownedCheckbox)
        flyout.HideUnownedCheckbox:SetSize(24, 24)
    end
    SK.EachRow(flyout.ScrollBox, function(item)
        if item.NormalTexture then item.NormalTexture:SetAlpha(0) end
        if item.PushedTexture then item.PushedTexture:SetAlpha(0) end
        if SK.Once(item) and item.icon then
            local border = SK.Icon(item.icon)
            SK.QualityBorder(item.IconBorder, border)
            local hl = item:GetHighlightTexture()
            if hl then hl:SetColorTexture(1, 1, 1, 0.25) end
        end
    end)
end

local function OutputLog(log)
    if not log then return end
    SK.Strip(log)
    Hide(log.Bg)
    SK.Backdrop(log, "panel")
    SK.Shadow(log)
    if log.ClosePanelButton then SK.Close(log.ClosePanelButton) end
    SK.ScrollBar(log.ScrollBar)
    SK.EachRow(log.ScrollBox, function(child)
        local c = child.ItemContainer
        if not c then return end
        if SK.Once(child) then
            local item = c.Item
            if item then
                HideStateOf(item)
                if item.icon then SK.QualityBorder(item.IconBorder, SK.Icon(item.icon)) end
            end
            Hide(c.CritFrame)
            Hide(c.NameFrame)
            Hide(c.BorderFrame)
            Hide(c.HighlightNameFrame)
            Hide(c.PushedNameFrame)
            if c.HighlightNameFrame then SK.Backdrop(c.HighlightNameFrame, "panel") end
        end
        local b = c.HighlightNameFrame and SK.GetBackdrop(c.HighlightNameFrame)
        if b then
            if c.CritFrame and c.CritFrame:IsShown() then b:SetBackdropBorderColor(1, 0.8, 0) else b:SetBackdropBorderColor(SK.BorderRGB()) end
        end
    end)
end

local formHooked = setmetatable({}, { __mode = "k" })
local function SchematicForm(form)
    if not form then return end
    if not formHooked[form] then
        formHooked[form] = true
        Hook(form, "Init", function(self)
            if self.reagentSlotPool then
                for slot in self.reagentSlotPool:EnumerateActive() do ReagentSlot(slot.Button) end
            end
            if self.salvageSlot then ReagentSlot(self.salvageSlot.Button) end
            if self.enchantSlot then ReagentSlot(self.enchantSlot.Button) end
        end)
    end
    SK.Strip(form, { [form.Background or 0] = true, [form.MinimalBackground or 0] = true })
    SK.Backdrop(form, "panel", 1, -1, -1, 1)
    -- The recipe's parchment: gone with the parchment remover, faint otherwise.
    local parchment = SK.ParchmentActive() or not form.Background
    for _, bg in ipairs({ form.Background, form.MinimalBackground }) do
        if parchment then bg:SetAlpha(0) else bg:SetAlpha(0.6) end
    end
    for _, k in ipairs({ "TrackRecipeCheckbox", "AllocateBestQualityCheckbox" }) do
        if form[k] then SK.Check(form[k]); form[k]:SetSize(24, 24) end
    end
    local q = form.QualityDialog
    if q then
        SK.Strip(q)
        Hide(q.Bg)
        SK.Backdrop(q, "panel")
        if q.ClosePanelButton then SK.Close(q.ClosePanelButton) end
        Buttons(q.AcceptButton, q.CancelButton)
        for i = 1, 3 do
            local c = q["Container" .. i]
            if c then
                local b = c.Button
                if b then
                    SK.Strip(b, { [b.Icon or 0] = true })
                    HideStateOf(b)
                    if b.Icon then SK.QualityBorder(b.IconBorder, SK.Icon(b.Icon)) end
                end
                NumberBox(c.EditBox)
            end
        end
    end
    local out = form.OutputIcon
    if out and out.Icon then
        SK.QualityBorder(out.IconBorder, SK.Icon(out.Icon))
        local hl = out:GetHighlightTexture()
        if hl then hl:SetAlpha(0) end
        Hide(out.CircleMask)
        if out.CircleMask then out.Icon:RemoveMaskTexture(out.CircleMask) end
    end
end

-- The skill bar along the top (with its expansion picker).
local function RankBar(bar)
    if not bar or not SK.Once(bar) then return end
    Hide(bar.Border)
    Hide(bar.Background)
    if bar.Fill then
        local px = SK.Pixel(bar)
        SK.Backdrop(bar.Fill, "panel", -px, px, px, -px)
        if bar.overrideWidth then bar.Fill:SetWidth(bar.overrideWidth) end
    end
    local dd = bar.ExpansionDropdownButton
    if dd then
        SK.Button(dd)
        local a = dd:CreateTexture(nil, "OVERLAY")
        a:SetTexture(SK.ARROW)
        a:SetRotation(math.pi)
        a:SetSize(11, 11)
        a:SetPoint("CENTER")
    end
end

local COLLAPSE = { ["Professions-recipe-header-expand"] = "common-button-list-plus",
                   ["Professions-recipe-header-collapse"] = "common-button-list-minus" }

local function RecipeRow(row)
    if not SK.Once(row) then return end
    if row.CollapseIcon or (FOREVER and row.CollapseButton) then
        -- A category: a flat bar, Blizzard's plus/minus kept but plainer.
        if row.CollapseButton then
            SK.Strip(row)
        else
            Hide(row.LeftPiece)
            Hide(row.CenterPiece)
            Hide(row.RightPiece)
            for _, icon in ipairs({ row.CollapseIcon, row.CollapseIconAlphaAdd }) do
                if icon then
                    local function Swap(tex, atlas)
                        local new = COLLAPSE[atlas]
                        if new then tex:SetAtlas(new, true) end
                    end
                    Swap(icon, icon:GetAtlas())
                    hooksecurefunc(icon, "SetAtlas", Swap)
                end
            end
        end
        SK.Backdrop(row, "button", 0, -1, 0, 1)
        local rb = row.RankBar
        if rb then
            Hide(rb.BorderLeft)
            Hide(rb.BorderMid)
            Hide(rb.BorderRight)
            SK.StatusBar(rb)
        end
    elseif row.SkillUps then
        local r, g, b = SK.AccentRGB()
        if row.SelectedOverlay then
            row.SelectedOverlay:SetColorTexture(r, g, b, 0.25)
            row.SelectedOverlay:SetAllPoints()
        end
        if row.HighlightOverlay then
            row.HighlightOverlay:SetColorTexture(1, 1, 1, 0.5)
            row.HighlightOverlay:SetAllPoints()
        end
    end
end

local function RecipeList(list)
    if not list then return end
    SK.Strip(list)
    Hide(list.BackgroundNineSlice)
    SK.Backdrop(list, "panel", 1, -1, -1, 1)
    SK.ScrollBar(list.ScrollBar)
    SK.EditBox(list.SearchBox)
    if list.FilterDropdown then
        SK.Dropdown(list.FilterDropdown)
        if list.FilterDropdown.ResetButton then SK.Close(list.FilterDropdown.ResetButton) end
    end
    SK.EachRow(list.ScrollBox, RecipeRow)
end

-- A profession's spell button in Forever's profession book page.
local function ProfessionButton(btn)
    if not btn or not SK.Once(btn) then return end
    local icon = btn.IconTexture
    if icon then
        if btn.OutlineMask then icon:RemoveMaskTexture(btn.OutlineMask) end
        local px = SK.Pixel(btn)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", px, -px)
        icon:SetPoint("BOTTOMRIGHT", -px, px)
        local border = SK.Icon(icon)
        if btn.highlightTexture and border then btn.highlightTexture:SetAllPoints(icon) end
    end
    Hide(btn.IconTextureOverlay)
    Hide(btn.IconBorder)
    Hook(btn, "UpdateButton", function(self)
        if self.highlightTexture then self.highlightTexture:SetColorTexture(1, 1, 1, 0.25) end
    end)
end

local function BookProfession(f)
    if not f then return end
    RankBar(f.StatusBar)
    local un = f.UnlearnButton
    if un then
        SK.Close(un, 18)
        un:SetHitRectInsets(0, 0, 0, 0)
        local fill = f.StatusBar and f.StatusBar.Fill
        if fill then
            un:ClearAllPoints()
            un:SetPoint("LEFT", fill, "RIGHT", 4, 0)
        end
    end
    for _, b in ipairs(f.spellButtons or {}) do ProfessionButton(b) end
end

local function OrderView(view)
    if not view then return end
    local decline = view.DeclineOrderDialog
    if decline then
        SK.Strip(decline)
        SK.Backdrop(decline, "panel")
        if decline.NoteEditBox then
            SK.Strip(decline.NoteEditBox)
            SK.Backdrop(decline.NoteEditBox, "button")
        end
        Buttons(decline.ConfirmButton, decline.CancelButton)
    end
    RankBar(view.RankBar)
    OutputLog(view.CraftingOutputLog)
    Buttons(view.CreateButton, view.StartRecraftButton, view.CompleteOrderButton)
    local info = view.OrderInfo
    if info then
        Box(info)
        Buttons(info.BackButton, info.StartOrderButton, info.DeclineOrderButton, info.ReleaseOrderButton, info.SocialDropdown)
        if info.NoteBox then SK.Strip(info.NoteBox); SK.Backdrop(info.NoteBox, "panel") end
        local rewards = info.NPCRewardsFrame
        if rewards then
            if rewards.Background then rewards.Background:SetAlpha(0); SK.Backdrop(rewards.Background, "panel") end
            for i = 1, 2 do
                local r = rewards["RewardItem" .. i]
                if r then
                    SK.Strip(r, { [r.Icon or 0] = true })
                    if r.Icon then SK.QualityBorder(r.IconBorder, SK.Icon(r.Icon)) end
                end
            end
        end
    end
    local details = view.OrderDetails
    if details then
        SK.Strip(details, { [details.Background or 0] = true })
        SK.Backdrop(details, "panel")
        if details.Background then details.Background:SetAlpha(0.5) end
        SchematicForm(details.SchematicForm)
        local ff = details.FulfillmentForm
        if ff then
            if ff.NoteEditBox then SK.Strip(ff.NoteEditBox); SK.Backdrop(ff.NoteEditBox, "panel") end
            local icon = ff.ItemIcon
            if icon and icon.Icon then
                SK.QualityBorder(icon.IconBorder, SK.Icon(icon.Icon))
                Hide(icon.CircleMask)
                if icon.CircleMask then icon.Icon:RemoveMaskTexture(icon.CircleMask) end
            end
        end
    end
    if view.ConcentrationDisplay and view.ConcentrationDisplay.Icon then SK.Icon(view.ConcentrationDisplay.Icon) end
end

local function OrderHeaders(page)
    local builder = page and page.tableBuilder
    if not builder or not builder.GetColumns then return end
    local cols = builder:GetColumns()
    for i, col in ipairs(cols) do
        local h = col:GetHeaderFrame()
        if h then
            local b = SK.GetBackdrop(h)
            if not b then
                h:DisableDrawLayer("BACKGROUND")
                b = SK.Backdrop(h, "panel")
                local hl = h:GetHighlightTexture()
                if hl then hl:SetColorTexture(1, 1, 1, 0.1); hl:SetAllPoints(b) end
            end
            SK.Backdrop(h, "panel", 0, 0, i < #cols and -5 or 0, -2)
        end
    end
end

local function Professions()
    local pf = G("ProfessionsFrame")
    if not pf then return end
    SK.Window(pf)
    local page = pf.CraftingPage
    if page then
        SK.Strip(page)
        Buttons(page.CreateButton, page.CreateAllButton, page.ViewGuildCraftersButton)
        if page.ConcentrationDisplay and page.ConcentrationDisplay.Icon then SK.Icon(page.ConcentrationDisplay.Icon) end
        SK.EditBox(page.MinimizedSearchBox)
        SchematicForm(page.SchematicForm)
        NumberBox(page.CreateMultipleInputBox)
        if page.TutorialButton then Hide(page.TutorialButton.Ring) end
        RankBar(page.RankBar)
        local link = page.LinkButton
        if link then
            if not FOREVER then
                local n, p = link:GetNormalTexture(), link:GetPushedTexture()
                if n then n:SetTexCoord(0.25, 0.7, 0.37, 0.75) end
                if p then p:SetTexCoord(0.25, 0.7, 0.45, 0.8) end
                local h = link:GetHighlightTexture()
                if h then h:SetAlpha(0) end
            end
            SK.Backdrop(link, "button")
            link:SetSize(17, 14)
        end
        local guild = page.GuildFrame
        if guild then
            Box(guild)
            Box(guild.Container)
        end
        for _, n in ipairs({ "Prof0ToolSlot", "Prof0Gear0Slot", "Prof0Gear1Slot", "Prof1ToolSlot", "Prof1Gear0Slot",
                             "Prof1Gear1Slot", "CookingToolSlot", "CookingGear0Slot", "FishingToolSlot" }) do
            local b = page[n]
            if b then
                SK.Strip(b, { [b.icon or 0] = true })
                SK.ItemButton(b)
            end
        end
        RecipeList(page.RecipeList)
        OutputLog(page.CraftingOutputLog)
    end

    -- Tabs: Forever's big side tabs, retail's bottom row.
    if FOREVER and pf.rightProfessionTabs then
        local function Side(self)
            local list = { self.ProfessionsOverviewTab }
            for _, t in ipairs(self.rightProfessionTabs or {}) do list[#list + 1] = t end
            for _, t in ipairs(list) do SK.SideTab(t) end
            SK.LayoutSideTabs(self, list)
        end
        Side(pf)
        Hook(pf, "RefreshRightTabs", Side)
    else
        local ts = pf.TabSystem
        if ts then
            for _, tab in ipairs({ ts:GetChildren() }) do SK.Tab(tab) end
            ts.spacing = -5
            if ts.MarkDirty then ts:MarkDirty() end
            ts:ClearAllPoints()
            ts:SetPoint("TOPLEFT", pf, "BOTTOMLEFT", -3, 0)
        end
        SK.MaxMin(pf.MaximizeMinimize)
    end

    local spec = pf.SpecPage
    if spec and not FOREVER then
        Buttons(spec.ViewTreeButton, spec.UnlockTabButton, spec.ApplyButton, spec.ViewPreviewButton,
                spec.BackToFullTreeButton, spec.BackToPreviewButton)
        SK.Strip(spec.PanelFooter)
        local tree = spec.TreeView
        if tree then
            SK.Strip(tree, { [tree.Background or 0] = true })
            SK.Backdrop(tree, "panel", -1, 1, -41, -1)
            if tree.Background then
                tree.Background:SetTexCoord(0.02, 0.98, 0.02, 0.98)
                tree.Background:SetAlpha(SK.ParchmentActive() and 0 or 0.6)
            end
        end
        Hook(spec, "UpdateTabs", function(self)
            if not self.tabsPool then return end
            for tab in self.tabsPool:EnumerateActive() do SK.Tab(tab) end
        end)
        local dv = spec.DetailedView
        if dv then
            Box(dv, -1, 1, 1, -1)
            Buttons(dv.UnlockPathButton, dv.SpendPointsButton)
            if dv.UnspentPoints and dv.UnspentPoints.Icon then SK.Icon(dv.UnspentPoints.Icon) end
        end
    end

    local orders = pf.OrdersPage
    if orders and not FOREVER then
        OrderView(orders.OrderView)
        local b = orders.BrowseFrame
        if b then
            for _, k in ipairs({ "PublicOrdersButton", "NpcOrdersButton", "GuildOrdersButton", "PersonalOrdersButton" }) do SK.Tab(b[k]) end
            Box(b.OrdersRemainingDisplay)
            if b.FavoritesSearchButton then b.FavoritesSearchButton:SetSize(22, 22) end
            Buttons(b.SearchButton, b.FavoritesSearchButton)
            if b.BackButton then
                SK.Strip(b.BackButton)
                SK.Arrow(b.BackButton, "left")
            end
            RecipeList(b.RecipeList)
            if b.OrderList then
                SK.Strip(b.OrderList)
                SK.ScrollBar(b.OrderList.ScrollBar)
            end
            OrderHeaders(orders)
            Hook(orders, "SetupTable", OrderHeaders)
        end
    end

    if FOREVER then
        local book = pf.BookPage and pf.BookPage.ProfessionsContentFrame
        if book then
            for _, k in ipairs({ "PrimaryProfession1", "PrimaryProfession2", "SecondaryProfession1", "SecondaryProfession2", "SecondaryProfession3" }) do
                BookProfession(book[k])
            end
        end
    end

    local inspect = G("InspectRecipeFrame")
    if inspect then
        SK.Window(inspect)
        SchematicForm(inspect.SchematicForm)
        SK.Auto(inspect)
    end
    -- The pick-a-reagent flyout, made on demand.
    HookGlobal("OpenProfessionsItemFlyout", function(_, owner)
        if not owner then return end
        for _, c in ipairs({ owner:GetChildren() }) do
            if c.InitializeContents then ItemFlyout(c) end
        end
    end)
    SK.Auto(pf)
end

SK.Define("tradeskill", Professions)

-- The customer side of crafting orders (retail).
SK.Define("craftorders", function()
    local f = G("ProfessionsCustomerOrdersFrame")
    if not f then return end
    SK.Window(f)
    for _, tab in ipairs({ f.BrowseTab, f.OrdersTab }) do SK.Tab(tab) end
    if f.BrowseTab and f.OrdersTab then
        f.BrowseTab:ClearAllPoints()
        f.BrowseTab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", -3, 0)
        f.OrdersTab:ClearAllPoints()
        f.OrdersTab:SetPoint("TOPLEFT", f.BrowseTab, "TOPRIGHT", -5, 0)
    end
    SK.Strip(f.MoneyFrameBorder)
    SK.Strip(f.MoneyFrameInset)
    local browse = f.BrowseOrders
    if browse then
        local bar = browse.SearchBar
        if bar then
            SK.EditBox(bar.SearchBox)
            Buttons(bar.SearchButton, bar.FavoritesSearchButton)
            if bar.FilterDropdown then SK.Dropdown(bar.FilterDropdown) end
        end
        if browse.CategoryList then ListBox(browse.CategoryList) end
        local rl = browse.RecipeList
        if rl then
            SK.Strip(rl)
            SK.ScrollBar(rl.ScrollBar)
            Hook(rl, "RefreshScrollFrame", function(self) if self.HeaderContainer then SK.TableHeaders(self.HeaderContainer) end end)
        end
    end
    local form = f.Form
    if form then
        SK.Button(form.BackButton)
        if form.TrackRecipeCheckbox then SK.Check(form.TrackRecipeCheckbox.Checkbox or form.TrackRecipeCheckbox) end
        Box(form.LeftPanelBackground)
        Box(form.RightPanelBackground)
        local pb = form.PaymentContainer
        if pb then
            Buttons(pb.ListOrderButton, pb.CancelOrderButton)
            if pb.NoteEditBox then SK.Strip(pb.NoteEditBox); SK.Backdrop(pb.NoteEditBox, "panel") end
            if pb.TipMoneyInputFrame then MoneyBoxes(pb.TipMoneyInputFrame) end
            if pb.DurationDropdown then SK.Dropdown(pb.DurationDropdown) end
        end
        local out = form.OutputIcon
        if out and out.Icon then SK.QualityBorder(out.IconBorder, SK.Icon(out.Icon)) end
        Hook(form, "Init", function(self)
            if self.reagentSlotPool then
                for slot in self.reagentSlotPool:EnumerateActive() do ReagentSlot(slot.Button) end
            end
        end)
        SK.Auto(form)
    end
    local my = f.MyOrdersPage
    if my then
        SK.Strip(my)
        if my.RefreshButton then SK.Button(my.RefreshButton) end
        if my.OrderList then
            SK.Strip(my.OrderList)
            SK.ScrollBar(my.OrderList.ScrollBar)
        end
        OrderHeaders(my)
        Hook(my, "SetupTable", OrderHeaders)
    end
    HookGlobal("OpenProfessionsItemFlyout", function(_, owner)
        if not owner then return end
        for _, c in ipairs({ owner:GetChildren() }) do
            if c.InitializeContents then ItemFlyout(c) end
        end
    end)
    SK.Auto(f)
end)

-- The profession book (retail's tab of spells for each profession).
SK.Define("profbook", function()
    local book = G("ProfessionsBookFrame")
    if not book then return end
    SK.Window(book)
    Hide(G("ProfessionsBookPage1"))
    Hide(G("ProfessionsBookPage2"))
    for _, n in ipairs({ "PrimaryProfession1", "PrimaryProfession2", "SecondaryProfession1", "SecondaryProfession2", "SecondaryProfession3" }) do
        local f = G(n)
        if f then
            Hide(f.missingHeader)
            Hide(f.missingText)
            for _, r in ipairs({ f:GetRegions() }) do
                if r:IsObjectType("Texture") and r ~= f.icon and r ~= (f.statusBar and f.statusBar.Fill) then r:SetAlpha(0) end
            end
            if f.icon then
                f.icon:SetDesaturated(false)
                SK.Icon(f.icon)
            end
            if f.statusBar then SK.StatusBar(f.statusBar, 0, 0.86, 0) end
            if f.unlearn then SK.Close(f.unlearn) end
            for i = 1, 2 do
                local b = f["SpellButton" .. i] or G(n .. "SpellButton" .. ((i == 1) and "Top" or "Bottom"))
                if b and SK.Once(b) then
                    local icon = b.IconTexture or G(b:GetName() .. "IconTexture")
                    if icon then SK.Icon(icon) end
                    Hide(b.NormalTexture or b:GetNormalTexture())
                end
            end
        end
    end
    SK.Auto(book)
end)

-- ============================================================================
-- Trainer
-- ============================================================================

SK.Define("trainer", function()
    local f = G("ClassTrainerFrame")
    if not f then return end
    SK.Window(f)
    SK.Strip(G("ClassTrainerFrameSkillStepButton"))
    SK.Inset(G("ClassTrainerFrameBottomInset"))
    Hide(G("ClassTrainerFramePortrait"))
    SK.Button(G("ClassTrainerTrainButton"))
    SK.ScrollBar(f.ScrollBar)
    if f.FilterDropdown then SK.Dropdown(f.FilterDropdown) end
    local step = G("ClassTrainerFrameSkillStepButton")
    if step then
        SK.Backdrop(step, "button")
        if step.icon then SK.Icon(step.icon, false) end
        if step.selectedTex then step.selectedTex:SetColorTexture(1, 1, 1, 0.3) end
        local hl = G("ClassTrainerFrameSkillStepButtonHighlight")
        if hl then hl:SetColorTexture(1, 1, 1, 0.3) end
    end
    local bar = G("ClassTrainerStatusBar")
    if bar then
        SK.StatusBar(bar)
        if bar.rankText then
            bar.rankText:ClearAllPoints()
            bar.rankText:SetPoint("CENTER", bar, "CENTER")
        end
    end
    local money = (FOREVER and f.money) or G("ClassTrainerFrameMoneyFrame")
    if money then SK.Backdrop(money, "panel", -4, 4, 4, -4) end
    if f.trainingPoints then SK.Backdrop(f.trainingPoints, "panel", -4, 4, 4, -4) end

    -- Each skill: its icon square, a see-through box beside it.
    local r, g, b = SK.AccentRGB()
    SK.EachRow(f.ScrollBox, function(row)
        if not SK.Once(row) then return end
        if not row.icon then
            -- Forever's category headers.
            SK.Strip(row)
            SK.Backdrop(row, "button", 0, -1, 0, 1)
            return
        end
        SK.Icon(row.icon)
        local box = SK.Backdrop(row, "panel")
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 1, 0)
        box:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 253, 0)
        if row.name then row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2) end
        if row.money then row.money:SetPoint("TOPRIGHT", row, "TOPRIGHT", 5, -8) end
        HideStateOf(row)
        Hide(row.disabledBG)
        if row.selectedTex then
            row.selectedTex:SetAllPoints(box)
            row.selectedTex:SetColorTexture(r, g, b, 0.25)
        end
    end)
    SK.Auto(f)
end)

-- ============================================================================
-- Loot
-- ============================================================================

local function LootRow(row)
    local item = row.Item
    if item then
        if SK.Once(item) then
            local icon = item.icon
            if icon then
                local px = SK.Pixel(item)
                icon:ClearAllPoints()
                icon:SetPoint("TOPLEFT", px, -px)
                icon:SetPoint("BOTTOMRIGHT", -px, px)
                SK.Icon(icon)
            end
            local hl = item:GetHighlightTexture()
            if hl then hl:SetColorTexture(1, 1, 1, 0.15) end
        end
        if item.NormalTexture then item.NormalTexture:SetAlpha(0) end
        Hide(item.IconBorder)
        -- The border takes the item name's colour, which is its quality.
        local border = item.icon and SK.GetBackdrop(item.icon)
        if border and row.Text then border:SetBackdropBorderColor(row.Text:GetVertexColor()) end
    end
    if row.NameFrame and SK.Once(row.NameFrame) then
        SK.Strip(row.NameFrame)
        local b = SK.Backdrop(row.NameFrame, "panel")
        b:SetFrameLevel(2)
    end
    Hide(row.IconQuestTexture)
    Hide(row.BorderFrame)
    Hide(row.HighlightNameFrame)
    Hide(row.PushedNameFrame)
end

local function RollFrame(f)
    if not f or not SK.Once(f) then return end
    Hide(f.Background)
    Hide(f.Border)
    SK.Backdrop(f, "panel")
    SK.Shadow(f)
    local icon = f.IconFrame
    if icon then
        Hide(icon.Border)
        if icon.Icon then SK.Icon(icon.Icon) end
    end
    if f.Timer then
        Hide(f.Timer.Background)
        SK.StatusBar(f.Timer, SK.AccentRGB())
    end
    -- The icon's edge in the item's quality colour.
    f:HookScript("OnShow", function(self)
        local border = self.IconFrame and self.IconFrame.Icon and SK.GetBackdrop(self.IconFrame.Icon)
        if not border or not self.rollID then return end
        local _, _, _, quality = GetLootRollItemInfo(self.rollID)
        local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
        if c then border:SetBackdropBorderColor(c.r, c.g, c.b) else border:SetBackdropBorderColor(SK.BorderRGB()) end
    end)
end

SK.Define("loot", function()
    local lf = G("LootFrame")
    if lf then
        SK.Window(lf)
        Hide(lf.Bg)
        if lf.ClosePanelButton then SK.Close(lf.ClosePanelButton) end
        SK.EachRow(lf.ScrollBox, LootRow)
    end

    local hist = G("GroupLootHistoryFrame")
    if hist then
        SK.Window(hist)
        Hide(hist.Bg)
        local dd = hist.EncounterDropdown
        if dd then
            SK.Dropdown(dd)
            dd:ClearAllPoints()
            dd:SetPoint("TOP", -6, -32)
        end
        local t = hist.Timer
        if t then
            SK.Strip(t)
            SK.Backdrop(t, "panel")
            if t.Fill then
                t.Fill:SetTexture("Interface\\Buttons\\WHITE8x8")
                t.Fill:SetVertexColor(SK.AccentRGB())
            end
        end
        if hist.ClosePanelButton then SK.Close(hist.ClosePanelButton) end
        SK.ScrollBar(hist.ScrollBar)
        SK.EachRow(hist.ScrollBox, function(row)
            local item = row.Item
            if not item then return end
            -- Housing items carry a wooden frame on the icon; that one goes.
            local ov = item.IconOverlay
            if ov then
                local atlas = ov:GetAtlas()
                ov:SetAlpha((atlas and atlas:find("housing-item-wood-frame", 1, true)) and 0 or 1)
            end
            if not SK.Once(row) then return end
            if row.BackgroundArtFrame then
                SK.Strip(row.BackgroundArtFrame)
                SK.Backdrop(row.BackgroundArtFrame, "panel")
            end
            SK.Strip(item, { [item.icon or 0] = true, [item.IconOverlay or 0] = true })
            if item.icon then SK.QualityBorder(item.IconBorder, SK.Icon(item.icon)) end
        end)
        local rb = hist.ResizeButton
        if rb and SK.Once(rb) then
            SK.Strip(rb)
            SK.Backdrop(rb, "button")
            rb:ClearAllPoints()
            rb:SetPoint("TOP", hist, "BOTTOM", 0, -2)
            rb:SetSize(hist:GetWidth(), 19)
            local text = rb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            text:SetPoint("CENTER")
            text:SetText("v v v v")
        end
    end

    local ml = G("MasterLooterFrame")
    if ml then
        SK.Strip(ml)
        Hide(ml.NineSlice)
        SK.Backdrop(ml, "panel")
        HookGlobal("MasterLooterFrame_Show", function()
            local item = ml.Item
            if item and item.Icon then
                SK.Strip(item, { [item.Icon] = true })
                local border = SK.Icon(item.Icon)
                local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[(lf and lf.selectedQuality) or 1]
                if border and c then border:SetBackdropBorderColor(c.r, c.g, c.b) end
            end
            for _, c in ipairs({ ml:GetChildren() }) do
                if c:IsObjectType("Button") and not c:GetName() then
                    if c:GetPushedTexture() then SK.Close(c) elseif SK.Once(c) then SK.Backdrop(c, "button"); SK.Hover(c) end
                end
            end
        end)
    end

    for i = 1, (NUM_GROUP_LOOT_FRAMES or 4) do RollFrame(G("GroupLootFrame" .. i)) end

    local bonus = G("BonusRollFrame")
    if bonus and SK.Once(bonus) then
        SK.Strip(bonus)
        SK.Backdrop(bonus, "panel")
        SK.Shadow(bonus)
        Hide(bonus.SpecRing)
        local prompt = bonus.PromptFrame
        if prompt then
            if prompt.Icon then SK.Icon(prompt.Icon) end
            if prompt.Timer then
                prompt.Timer:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
                prompt.Timer:SetStatusBarColor(SK.AccentRGB())
                local px = SK.Pixel(prompt.Timer)
                SK.Backdrop(prompt.Timer, "button", -px, px, px, -px)
            end
        end
        if bonus.BlackBackgroundHoist then Hide(bonus.BlackBackgroundHoist.Background) end
        if bonus.SpecIcon then SK.Icon(bonus.SpecIcon) end
    end
end)

-- ============================================================================
-- Bags and bank (Blizzard's own; most of you use a bag addon)
-- ============================================================================

local function BagItem(btn)
    if not btn or not SK.Once(btn) then return end
    local icon = btn.icon
    local keep = {}
    for _, k in ipairs({ "icon", "UpgradeIcon", "JunkIcon", "ItemContextOverlay", "IconQuestTexture", "searchOverlay",
                         "NewItemTexture", "BattlepayItemTexture", "IconOverlay", "IconOverlay2" }) do
        if btn[k] then keep[btn[k]] = true end
    end
    for _, r in ipairs({ btn:GetRegions() }) do
        if r:IsObjectType("Texture") and not keep[r] then r:SetAlpha(0) end
    end
    if FOREVER and btn.EmptyBagIcon then btn.EmptyBagIcon:SetAlpha(0) end
    if icon then
        local px = SK.Pixel(btn)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", px, -px)
        icon:SetPoint("BOTTOMRIGHT", -px, px)
    end
    if btn.searchOverlay then btn.searchOverlay:SetColorTexture(0, 0, 0, 0.8) end
    if btn.IconQuestTexture then btn.IconQuestTexture:SetAllPoints(icon or btn) end
    local hl = btn:GetHighlightTexture()
    if hl then hl:SetAlpha(1); hl:SetColorTexture(1, 1, 1, 0.15) end
    local push = btn:GetPushedTexture()
    if push then push:SetAlpha(1); push:SetColorTexture(1, 1, 1, 0.2) end
    local b = SK.Backdrop(btn, "button")
    SK.QualityBorder(btn.IconBorder, b)
end

local function Container(c)
    if not c or not SK.Once(c) then return end
    SK.Strip(c)
    SK.Furniture(c)
    Hide(c.Bg)
    SK.Backdrop(c, "panel")
    SK.Shadow(c)
    if c.CloseButton then SK.Close(c.CloseButton) end
    local p = c.PortraitButton
    if p then
        SK.Strip(p)
        if p.Highlight then p.Highlight:SetAlpha(0) end
    end
    if c.MoneyFrame and c.MoneyFrame.Border then SK.Strip(c.MoneyFrame.Border) end
    Hook(c, "UpdateItems", function(self)
        if self.EnumerateValidItems then
            for _, btn in self:EnumerateValidItems() do BagItem(btn) end
        end
    end)
end

local function SortButton(btn)
    if not btn or not SK.Once(btn) then return end
    SK.Strip(btn)
    HideStateOf(btn)
    SK.Backdrop(btn, "button")
    SK.Hover(btn)
    local t = btn:CreateTexture(nil, "ARTWORK")
    t:SetTexture("Interface\\Icons\\INV_Pet_Broom")
    t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local px = SK.Pixel(btn)
    t:SetPoint("TOPLEFT", px, -px)
    t:SetPoint("BOTTOMRIGHT", -px, px)
end

SK.Define("bags", function()
    for i = 1, (NUM_CONTAINER_FRAMES or 13) do Container(G("ContainerFrame" .. i)) end
    Container(G("ContainerFrameCombinedBags"))
    SK.EditBox(G("BagItemSearchBox"))
    SK.EditBox(G("BankItemSearchBox"))
    SortButton(G("BagItemAutoSortButton"))
    local tokens = G("BackpackTokenFrame")
    if tokens then
        SK.Strip(tokens)
        Hook(tokens, "Update", function(self)
            for _, t in ipairs(self.Tokens or {}) do
                if t.Icon and SK.Once(t) then
                    SK.Icon(t.Icon)
                    t.Icon:SetSize(14, 14)
                    if t.Count then
                        t.Count:ClearAllPoints()
                        t.Count:SetPoint("RIGHT", t.Icon, "LEFT", -3, 0)
                    end
                end
            end
        end)
    end

    local bank = G("BankFrame")
    if bank then
        SK.Window(bank)
        Hide(bank.Background)
        if FOREVER then
            Hook(bank, "RefreshPageTabs", function(self)
                if not self.bankPageTabPool then return end
                local list = {}
                for tab in self.bankPageTabPool:EnumerateActive() do
                    SK.SideTab(tab)
                    list[#list + 1] = tab
                end
                table.sort(list, function(a, b)
                    if a.bankType ~= b.bankType then return (a.bankType or 0) < (b.bankType or 0) end
                    return (a.pageNumber or 0) < (b.pageNumber or 0)
                end)
                SK.LayoutSideTabs(self, list)
            end)
            Hook(bank, "RefreshBagButtons", function(self)
                if not self.itemButtonBagPool then return end
                for btn in self.itemButtonBagPool:EnumerateActive() do SK.Slot(btn) end
            end)
        else
            local ts = bank.TabSystem
            if ts then
                for _, tab in ipairs(ts.tabs or {}) do SK.Tab(tab) end
                ts.spacing = -5
                if ts.MarkDirty then ts:MarkDirty() end
                ts:ClearAllPoints()
                ts:SetPoint("TOPLEFT", bank, "BOTTOMLEFT", -4, -1)
            end
        end
        local panel = G("BankPanel")
        if panel then
            SK.Strip(panel)
            Hide(panel.EdgeShadows)
            local m = panel.MoneyFrame
            if m then
                Buttons(m.DepositButton, m.WithdrawButton)
                Hide(m.Border)
            end
            if FOREVER then
                SK.Button(panel.PurchaseButton)
            elseif panel.AutoDepositFrame then
                SK.Button(panel.AutoDepositFrame.DepositButton)
                SK.Check(panel.AutoDepositFrame.IncludeReagentsCheckbox)
            end
            SortButton(panel.AutoSortButton)
            local pp = panel.PurchasePrompt
            if pp then
                SK.Strip(pp)
                if pp.TabCostFrame then SK.Button(pp.TabCostFrame.PurchaseButton) end
                if not FOREVER then SK.Backdrop(pp, "panel", 8, 2, -6, 2) end
            end
            local tabDone = {}
            local function BankTab(tab)
                if not tab or tabDone[tab] then return end
                tabDone[tab] = true
                if tab.Icon then SK.Icon(tab.Icon) end
                SK.Tab(tab)
                if tab.SelectedTexture then tab.SelectedTexture:SetColorTexture(1, 1, 1, 0.25) end
                Hide(tab.Border)
            end
            BankTab(panel.PurchaseTab)
            if not FOREVER then
                Hook(panel, "RefreshBankTabs", function(self)
                    if not self.bankTabPool then return end
                    for tab in self.bankTabPool:EnumerateActive() do BankTab(tab) end
                end)
            end
            Hook(panel, "GenerateItemSlotsForSelectedTab", function(self)
                if not self.itemButtonPool then return end
                for item in self.itemButtonPool:EnumerateActive() do
                    if SK.Once(item) then
                        Hide(item.Background)
                        if FOREVER then HideStateOf(item) end
                        local icon = item.icon
                        SK.Strip(item, {
                            [icon or 0] = true, [item.IconQuestTexture or 0] = true, [item.searchOverlay or 0] = true,
                            [item.ItemContextOverlay or 0] = true, [item.UpgradeIcon or 0] = true, [item.JunkIcon or 0] = true,
                        })
                        if icon then
                            local px = SK.Pixel(item)
                            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                            icon:ClearAllPoints()
                            icon:SetPoint("TOPLEFT", px, -px)
                            icon:SetPoint("BOTTOMRIGHT", -px, px)
                        end
                        local hl = item:GetHighlightTexture()
                        if hl then hl:SetAlpha(1); hl:SetColorTexture(1, 1, 1, 0.15) end
                        local b = SK.Backdrop(item, "button")
                        SK.QualityBorder(item.IconBorder, b)
                    end
                end
            end)
            if panel.TabSettingsMenu then
                panel.TabSettingsMenu:HookScript("OnShow", function(self) SK.IconSelector(self) end)
            end
        end
    end
end)

-- ============================================================================
-- Guild bank
-- ============================================================================

SK.Define("gbank", function()
    local f = G("GuildBankFrame")
    if not f then return end
    SK.Window(f)
    SK.Strip(f.MoneyFrameBG)
    Hide(f.Emblem)
    Buttons(f.DepositButton, f.WithdrawButton, G("GuildBankInfoSaveButton"), f.BuyInfo and f.BuyInfo.PurchaseButton)
    if f.WithdrawButton and f.DepositButton then f.WithdrawButton:SetPoint("RIGHT", f.DepositButton, "LEFT", -2, 0) end
    local info = G("GuildBankInfoScrollFrame")
    if info then
        SK.Strip(info)
        local gi = G("GuildBankInfo")
        if gi then info:SetPoint("TOPLEFT", gi, "TOPLEFT", -10, 12) end
        info:SetWidth(info:GetWidth() - 8)
    end
    local black = f.BlackBG
    local bb = black and SK.Backdrop(black, "panel", 4, 0, -3, 3)
    local function Bar(sb)
        if not sb then return end
        SK.ScrollBar(sb)
        if bb then
            sb:ClearAllPoints()
            sb:SetPoint("TOPRIGHT", bb, -8, -4)
            sb:SetPoint("BOTTOMRIGHT", bb, -8, 4)
        end
    end
    if f.Log then Bar(f.Log.ScrollBar) end
    if info then Bar(info.ScrollBar) end

    for i = 1, (MAX_GUILDBANK_TABS or 8) do
        local tab = G("GuildBankTab" .. i)
        if tab then
            SK.Strip(tab)
            local btn = tab.Button
            if btn and SK.Once(btn) then
                local icon = btn.IconTexture
                SK.Strip(btn, icon and { [icon] = true } or nil)
                if icon then
                    local px = SK.Pixel(btn)
                    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    icon:ClearAllPoints()
                    icon:SetPoint("TOPLEFT", px, -px)
                    icon:SetPoint("BOTTOMRIGHT", -px, px)
                end
                local hl = btn:GetHighlightTexture()
                if hl then hl:SetAlpha(1); hl:SetColorTexture(1, 1, 1, 0.3) end
                local ck = btn:GetCheckedTexture()
                if ck then ck:SetAlpha(1); ck:SetColorTexture(1, 1, 1, 0.3) end
                SK.Backdrop(btn, "button")
            end
        end
    end
    for i = 1, 7 do
        local col = f["Column" .. i]
        if col then
            SK.Strip(col)
            for x = 1, 14 do
                local btn = col["Button" .. x]
                if btn then
                    SK.Strip(btn, { [btn.icon or 0] = true, [btn.IconBorder or 0] = true, [btn.searchOverlay or 0] = true })
                    SK.ItemButton(btn)
                end
            end
        end
    end
    local list = {}
    for i = 1, 4 do
        local tab = G("GuildBankFrameTab" .. i)
        if tab then SK.Tab(tab); list[#list + 1] = tab end
    end
    SK.LayoutTabs(f, list)
    local search = G("GuildItemSearchBox")
    if search then
        Hide(search.searchIcon)
        SK.EditBox(search)
    end
    local limit = f.LimitLabel or G("GuildBankLimitLabel")
    if limit and f.TabLimitBG then Hide(f.TabLimitBG) end
    local popup = G("GuildBankPopupFrame")
    if popup then popup:HookScript("OnShow", function(self) SK.IconSelector(self, f) end) end
    SK.Auto(f)
end)

-- ============================================================================
-- Macros
-- ============================================================================

SK.Define("macro", function()
    local f = G("MacroFrame")
    if not f then return end
    SK.Window(f)
    SK.Strip(G("MacroFrameTextBackground"))
    local tb = G("MacroFrameTextBackground")
    if tb then SK.Backdrop(tb, "panel", 6, -3, -3, 6) end
    SK.Strip(G("MacroFrameScrollFrame"))
    local sf = G("MacroFrameScrollFrame")
    if sf and sf.ScrollBar then SK.ScrollBar(sf.ScrollBar) end
    SK.Strip(f.MacroSelector)
    if f.MacroSelector then
        SK.Backdrop(f.MacroSelector, "panel")
        SK.ScrollBar(f.MacroSelector.ScrollBar)
        SK.EachRow(f.MacroSelector.ScrollBox, function(btn)
            if not SK.Once(btn) then return end
            local icon = btn.Icon
            SK.Strip(btn, icon and { [icon] = true } or nil)
            if icon then
                local px = SK.Pixel(btn)
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                icon:ClearAllPoints()
                icon:SetPoint("TOPLEFT", px, -px)
                icon:SetPoint("BOTTOMRIGHT", -px, px)
            end
            local hl = btn:GetHighlightTexture()
            if hl then hl:SetAlpha(1); hl:SetColorTexture(1, 1, 1, 0.3) end
            local ck = btn:GetCheckedTexture()
            if ck then ck:SetAlpha(1); ck:SetColorTexture(1, 1, 1, 0.3) end
            -- Raised so its box sits above the list's own.
            btn:SetFrameLevel(btn:GetFrameLevel() + 1)
            SK.Backdrop(btn, "button")
        end)
    end
    local sel = G("MacroFrameSelectedMacroButton")
    if sel then
        sel:DisableDrawLayer("BACKGROUND")
        SK.ItemButton(sel)
    end
    -- The account / character tabs are plain buttons across the top.
    for _, n in ipairs({ "MacroSaveButton", "MacroCancelButton", "MacroDeleteButton", "MacroNewButton", "MacroExitButton",
                         "MacroEditButton", "MacroFrameTab1", "MacroFrameTab2" }) do
        local b = G(n)
        if b then
            SK.Strip(b)
            SK.Button(b)
        end
    end
    local new, exit = G("MacroNewButton"), G("MacroExitButton")
    if new and exit then
        new:ClearAllPoints()
        new:SetPoint("RIGHT", exit, "LEFT", -2, 0)
    end
    local t1, t2 = G("MacroFrameTab1"), G("MacroFrameTab2")
    if t1 and t2 then
        t1:SetHeight(22)
        t2:SetHeight(22)
        t1:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -39)
        t2:SetPoint("LEFT", t1, "RIGHT", 4, 0)
        if t1.Text then t1.Text:SetAllPoints(t1) end
        if t2.Text then t2.Text:SetAllPoints(t2) end
    end
    local edit = G("MacroEditButton")
    if edit and sel then
        edit:ClearAllPoints()
        edit:SetPoint("BOTTOMLEFT", sel, "BOTTOMRIGHT", 10, 0)
    end
    local popup = G("MacroPopupFrame")
    if popup then popup:HookScript("OnShow", function(self) SK.IconSelector(self, f) end) end
    SK.Auto(f)
end)
