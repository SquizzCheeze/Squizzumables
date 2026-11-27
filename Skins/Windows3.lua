-- Skins/Windows3.lua
-- Batch 3 of the window skins: talents and spellbook, collections, the
-- dungeon journal and achievements. All four load on demand, so each runs
-- when its Blizzard addon loads.

local _, ns = ...
local SK = ns.Skins
local Hide = SK.Hide

local function G(name) return _G[name] end

local function HideKeys(frame, ...)
    if not frame then return end
    for i = 1, select("#", ...) do Hide(frame[select(i, ...)]) end
end

local function HideNamed(...)
    for i = 1, select("#", ...) do Hide(G(select(i, ...))) end
end

-- ============================================================================
-- Talents and spellbook
-- ============================================================================

SK.Define("talents", function()
    local psf = G("PlayerSpellsFrame")
    if not psf then return end
    SK.Window(psf)
    SK.TabSystem(psf.TabSystem)
    SK.MaxMin(psf.MaximizeMinimizeButton or psf.MaxMinButtonFrame)

    -- Specializations: the spec cards come from a pool, so they are done
    -- each time Blizzard lays them out.
    local spec = psf.SpecFrame
    if spec then
        HideKeys(spec, "BlackBG", "Background")
        local function Cards()
            local pool = spec.SpecContentFramePool
            if pool then
                for card in pool:EnumerateActive() do SK.Auto(card) end
            end
            SK.Auto(spec)
        end
        if spec.UpdateSpecFrame then hooksecurefunc(spec, "UpdateSpecFrame", Cards) end
        Cards()
    end

    -- Talents: the tree's own artwork stays (it is the spec's), its frame goes.
    local tf = psf.TalentsFrame
    if tf then
        HideKeys(tf, "BlackBG", "BottomBar", "BackgroundBorder", "DividerHorizontalLeft", "DividerHorizontalRight",
                 "DividerVerticalLeft", "DividerVerticalRight")
        -- On Forever `Background` is the brown base behind the three spec
        -- pictures (the bands above and below them); on retail it is the
        -- spec picture itself, so it stays there.
        if ns.BH.IS_FOREVER then Hide(tf.Background) end
        if tf.LoadSystem and tf.LoadSystem.Dropdown then SK.Dropdown(tf.LoadSystem.Dropdown) end
        if tf.SearchOptionsDropdown then SK.ArrowDropdown(tf.SearchOptionsDropdown) end
        if tf.TabSystem then SK.TabSystem(tf.TabSystem) end

        -- "Unspent Talents": the number in a box, the label beside it.
        for _, k in ipairs({ "ClassCurrencyDisplay", "SpecCurrencyDisplay" }) do
            local c = tf[k]
            if c then
                Hide(c.Border)
                local box = c.CurrentAmountContainer
                if box and SK.Once(box) then
                    SK.Backdrop(box, "button", -2, 2, 2, -2)
                    local amount = box.CurrencyAmount
                    if amount then
                        local font, _, flags = amount:GetFont()
                        if font then amount:SetFont(font, 22, flags) end
                    end
                    local label = c.UnspentLabel or c.CurrencyLabel
                    if label then
                        label:ClearAllPoints()
                        label:SetPoint("RIGHT", box, "LEFT", -8, 0)
                    end
                end
            end
        end

        -- Forever's three spec headers: the divider under each goes, the
        -- points spent sit in a small box.
        local function Headers(frame)
            for _, header in ipairs(frame.treeHeaders or {}) do
                if SK.Once(header) then
                    Hide(header.Divider)
                    local tb = header.TextBackground
                    if tb then
                        tb:SetAlpha(0)
                        local b = SK.Backdrop(tb, "button", 4, -6, -2, 2)
                        b:SetFrameLevel(header:GetFrameLevel() + 1)
                        if header.Text then header.Text:SetParent(b) end
                    end
                end
            end
        end
        if tf.RefreshTreeHeaders then hooksecurefunc(tf, "RefreshTreeHeaders", Headers) end
        Headers(tf)

        SK.TalentNodes(tf)
        if tf.PvPTalentList then
            SK.Strip(tf.PvPTalentList)
            SK.Backdrop(tf.PvPTalentList, "panel")
        end
        if tf.SearchPreviewContainer then SK.Strip(tf.SearchPreviewContainer) end
        SK.Auto(tf)
    end

    -- Spellbook.
    local sb = psf.SpellBookFrame
    if sb then
        HideKeys(sb, "TopBar", "BookBGHalved", "BookBGLeft", "BookBGRight", "BookCornerFlipbook", "Bookmark")
        if sb.HelpPlateButton then Hide(sb.HelpPlateButton.Ring) end
        SK.TabSystem(sb.CategoryTabSystem)
        local paged = sb.PagedSpellsFrame
        if paged then
            if paged.View1 then paged.View1:DisableDrawLayer("OVERLAY") end
            -- Blizzard writes the names in its dark parchment ink, unreadable
            -- on our panel: names white, the lines under them grey, headers gold.
            local function Ink(frame)
                if frame.Name and frame.SubName then
                    frame.Name:SetTextColor(1, 1, 1)
                    frame.SubName:SetTextColor(0.75, 0.75, 0.75)
                    if frame.RequiredLevel then frame.RequiredLevel:SetTextColor(0.75, 0.75, 0.75) end
                elseif frame.Text and frame.Text.SetTextColor then
                    frame.Text:SetTextColor(1, 0.82, 0)
                end
            end
            local function Recolour(self)
                if self.ForEachFrame then self:ForEachFrame(Ink) end
            end
            if paged.DisplayViewsForCurrentPage then hooksecurefunc(paged, "DisplayViewsForCurrentPage", Recolour) end
            Recolour(paged)
            local pc = paged.PagingControls
            if pc then
                if pc.PrevPageButton then SK.Arrow(pc.PrevPageButton, "left") end
                if pc.NextPageButton then SK.Arrow(pc.NextPageButton, "right") end
                if pc.PageText then pc.PageText:SetTextColor(1, 1, 1) end
            end
        end
        local rot = sb.AssistedCombatRotationSpellFrame and sb.AssistedCombatRotationSpellFrame.Button
        if rot and SK.Once(rot) then
            Hide(rot.Border)
            SK.Icon(rot.Icon)
        end
        if sb.SearchPreviewContainer then SK.Strip(sb.SearchPreviewContainer) end
        SK.Auto(sb)
    end

    SK.Auto(psf)

    -- The loadout import box.
    local import = G("ClassTalentLoadoutImportDialog")
    if import then
        Hide(import.Border)
        SK.Window(import)
        local ic = import.ImportControl and import.ImportControl.InputContainer
        if ic then
            SK.Strip(ic)
            Hide(ic.NineSlice)
            SK.Backdrop(ic, "button")
        end
        SK.Auto(import)
    end
    for _, n in ipairs({ "ClassTalentLoadoutCreateDialog", "ClassTalentLoadoutEditDialog" }) do
        local d = G(n)
        if d then
            Hide(d.Border)
            SK.Window(d)
            SK.Auto(d)
        end
    end
end)

-- ============================================================================
-- Collections
-- ============================================================================

-- Toy box and heirloom buttons: the slot ring goes, the icon is squared off.
local function CollectionButton(btn)
    if not btn or not SK.Once(btn) then return end
    local keep = {}
    for _, k in ipairs({ "iconTexture", "iconTextureUncollected", "new", "newGlow", "cooldown" }) do
        if btn[k] then keep[btn[k]] = true end
    end
    local hl = btn.GetHighlightTexture and btn:GetHighlightTexture()
    local push = btn.GetPushedTexture and btn:GetPushedTexture()
    for _, r in ipairs({ btn:GetRegions() }) do
        if r:IsObjectType("Texture") and not keep[r] and r ~= hl and r ~= push then r:SetAlpha(0) end
    end
    local icon = btn.iconTexture
    if icon then
        local border = SK.Icon(icon)
        if btn.iconTextureUncollected then
            btn.iconTextureUncollected:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        if hl then
            hl:SetColorTexture(1, 1, 1, 0.15)
            hl:SetAllPoints(icon)
        end
        if push then
            push:SetColorTexture(1, 1, 1, 0.25)
            push:SetAllPoints(icon)
        end
        return border
    end
end

local function IconsFrame(f)
    if not f or not SK.Once(f) then return end
    SK.Strip(f)
    Hide(f.NineSlice)
    for _, k in ipairs({ "BackgroundTile", "ShadowLineTop", "ShadowLineBottom", "ShadowCornerTopLeft",
                         "ShadowCornerTopRight", "ShadowCornerBottomLeft", "ShadowCornerBottomRight",
                         "ShadowCornerTop", "ShadowCornerBottom", "ShadowCornerLeft", "ShadowCornerRight",
                         "OverlayShadowTop", "OverlayShadowBottom", "OverlayShadowLeft", "OverlayShadowRight" }) do
        Hide(f[k])
    end
    SK.Backdrop(f, "panel")
end

local function Paging(p)
    if not p then return end
    if p.PrevPageButton then SK.Arrow(p.PrevPageButton, "left") end
    if p.NextPageButton then SK.Arrow(p.NextPageButton, "right") end
end

-- A mount or pet in the list: a see-through box, the icon square outside it
-- on the left, a gold edge while chosen and the accent colour on hover.
local GOLD = { 1, 0.8, 0.1 }
local function RowEdge(row)
    local b = SK.GetBackdrop(row)
    if not b then return end
    if row:IsMouseOver() then
        b:SetBackdropBorderColor(SK.AccentRGB())
    elseif row.selectedTexture and row.selectedTexture:IsShown() then
        b:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3])
    else
        b:SetBackdropBorderColor(SK.BorderRGB())
    end
end
local function JournalRow(row)
    if not SK.Once(row) then return end
    local icon = row.icon
    local keep = {}
    for _, k in ipairs({ "icon", "petTypeIcon", "factionIcon", "favorite", "iconBorder", "background" }) do
        if row[k] then keep[row[k]] = true end
    end
    SK.Strip(row, keep)
    -- The name strip behind the text stays only as a tint.
    if row.background then row.background:SetAlpha(0) end
    if row.iconBorder then row.iconBorder:SetAlpha(0) end
    local b = SK.Backdrop(row, "panel")
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
    b:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 2)
    if icon then
        icon:SetSize(40, 40)
        icon:ClearAllPoints()
        icon:SetPoint("LEFT", -43, 0)
        local ib = SK.Icon(icon)
        SK.QualityBorder(row.iconBorder, ib)
    end
    if row.petTypeIcon then
        row.petTypeIcon:SetPoint("TOPRIGHT", -1, -1)
        row.petTypeIcon:SetPoint("BOTTOMRIGHT", -1, 1)
    end
    if row.factionIcon then
        row.factionIcon:SetDrawLayer("OVERLAY")
        row.factionIcon:SetPoint("TOPRIGHT", -1, -1)
        row.factionIcon:SetPoint("BOTTOMRIGHT", -1, 1)
    end
    local drag = row.dragButton or row.DragButton
    if drag then
        if drag.ActiveTexture then drag.ActiveTexture:SetColorTexture(0.9, 0.8, 0.1, 0.3) end
        if drag.levelBG then drag.levelBG:SetAlpha(0) end
        local hl = drag:GetHighlightTexture()
        if hl and icon then hl:SetColorTexture(1, 1, 1, 0.25); hl:SetAllPoints(icon) end
    end
    if row.selectedTexture then
        row.selectedTexture:SetAlpha(0)
        row.selectedTexture:HookScript("OnShow", function() RowEdge(row) end)
        row.selectedTexture:HookScript("OnHide", function() RowEdge(row) end)
    end
    row:HookScript("OnEnter", RowEdge)
    row:HookScript("OnLeave", RowEdge)
    RowEdge(row)
end

local function Journal(j, searchBox)
    if not j then return end
    SK.Strip(j)
    if j.ScrollBar then SK.ScrollBar(j.ScrollBar) end
    if j.ScrollBox then SK.EachRow(j.ScrollBox, JournalRow) end
    local filter = j.FilterDropdown
    if filter and searchBox then
        filter:ClearAllPoints()
        filter:SetPoint("LEFT", searchBox, "RIGHT", 5, 0)
        if filter.ResetButton then
            SK.Close(filter.ResetButton)
            filter.ResetButton:ClearAllPoints()
            filter.ResetButton:SetPoint("CENTER", filter, "TOPRIGHT", 0, 0)
        end
    end
end

SK.Define("collections", function()
    local cj = G("CollectionsJournal")
    if not cj then return end
    SK.Window(cj)

    -- Tabs: Forever has the big icon tabs down the side, retail the bottom row.
    local side = cj.TabContainer and cj.TabContainer.Tabs
    if side and ns.BH.IS_FOREVER then
        for _, t in ipairs(side) do SK.SideTab(t) end
        local function Layout() SK.LayoutSideTabs(cj, side) end
        if CollectionsJournal_CheckAndDisplayTabs then hooksecurefunc("CollectionsJournal_CheckAndDisplayTabs", Layout) end
        Layout()
    else
        SK.NumberedTabs(cj, "CollectionsJournalTab")
    end

    local toy = G("ToyBox")
    if toy then
        IconsFrame(toy.iconsFrame)
        Paging(toy.PagingFrame)
        if toy.progressBar then
            Hide(toy.progressBar.border)
            toy.progressBar:DisableDrawLayer("BACKGROUND")
            SK.StatusBar(toy.progressBar, 0.03, 0.6, 0.03)
        end
        for i = 1, 18 do CollectionButton(toy.iconsFrame and toy.iconsFrame["spellButton" .. i]) end
        -- A toy you own gets its quality colour round the icon.
        if ToySpellButton_UpdateButton then
            hooksecurefunc("ToySpellButton_UpdateButton", function(btn)
                local border = btn.iconTexture and SK.GetBackdrop(btn.iconTexture)
                if not border then return end
                local q = btn.itemID and PlayerHasToy(btn.itemID) and C_Item.GetItemQualityByID(btn.itemID)
                local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
                if c then border:SetBackdropBorderColor(c.r, c.g, c.b) else border:SetBackdropBorderColor(SK.BorderRGB()) end
            end)
        end
    end

    local heir = G("HeirloomsJournal")
    if heir then
        IconsFrame(heir.iconsFrame)
        Paging(heir.PagingFrame)
        if heir.progressBar then
            Hide(heir.progressBar.border)
            heir.progressBar:DisableDrawLayer("BACKGROUND")
            SK.StatusBar(heir.progressBar, 0.03, 0.6, 0.03)
        end
        -- Heirloom buttons are pooled and laid out per page.
        local function Buttons()
            if heir.heirloomEntryFrames then
                for _, b in pairs(heir.heirloomEntryFrames) do CollectionButton(b) end
            end
        end
        if heir.LayoutCurrentPage then hooksecurefunc(heir, "LayoutCurrentPage", Buttons) end
        Buttons()
    end

    local mount = G("MountJournal")
    if mount then
        Journal(mount, G("MountJournalSearchBox"))
        local inset = mount.BottomLeftInset
        if inset then
            SK.Inset(inset)
            SK.Backdrop(inset, "panel")
            local slot = inset.SlotButton
            if slot and SK.Once(slot) then
                SK.Strip(slot)
                if slot.ItemIcon then SK.Icon(slot.ItemIcon) end
            end
        end
        for _, n in ipairs({ "MountJournalLeftInset", "MountJournalRightInset" }) do SK.Inset(G(n)) end
        local display = mount.MountDisplay
        if display then
            SK.Strip(display)
            if display.ShadowOverlay then SK.Strip(display.ShadowOverlay) end
            HideKeys(display, "YesMountsTex", "NoMountsTex")
            SK.Backdrop(display, "panel")
            if display.InfoButton and display.InfoButton.Icon then SK.Icon(display.InfoButton.Icon) end
            local scene = display.ModelScene
            if scene and scene.TogglePlayer then
                SK.Check(scene.TogglePlayer)
                scene.TogglePlayer:SetSize(22, 22)
            end
        end
        if mount.MountCount then
            SK.Strip(mount.MountCount)
            SK.Backdrop(mount.MountCount, "button")
        end
        local fav = mount.SummonRandomFavoriteSpellFrame
        if fav and fav.Button then SK.ItemButton(fav.Button) end
        local mb = G("MountJournalMountButton")
        if mb then
            SK.Button(mb)
            local p, rel, rp, x, y = mb:GetPoint()
            if p then mb:SetPoint(p, rel, rp, x, (y or 0) - 3) end
        end
        SK.Auto(mount)
    end

    local pet = G("PetJournal")
    if pet then
        Journal(pet, G("PetJournalSearchBox"))
        SK.Inset(G("PetJournalRightInset"))
        SK.Inset(G("PetJournalLeftInset"))
        local search, left = G("PetJournalSearchBox"), G("PetJournalLeftInset")
        if search and left then
            search:ClearAllPoints()
            search:SetPoint("TOPLEFT", left, "TOPLEFT", 13, -9)
        end
        if pet.FilterDropdown and left then
            pet.FilterDropdown:SetHeight(22)
            pet.FilterDropdown:ClearAllPoints()
            pet.FilterDropdown:SetPoint("TOPRIGHT", left, "TOPRIGHT", -5, -8)
        end
        local rnd = pet.SummonRandomPetSpellFrame
        if rnd and rnd.Button then SK.ItemButton(rnd.Button) end
        if pet.PetCount then
            SK.Strip(pet.PetCount)
            SK.Backdrop(pet.PetCount, "button")
        end
        if G("PetJournalPetCard") then
            SK.Strip(G("PetJournalPetCard"))
            SK.Backdrop(G("PetJournalPetCard"), "panel")
        end
        if G("PetJournalLoadoutBorder") then SK.Strip(G("PetJournalLoadoutBorder")) end
        SK.Auto(pet)
    end

    local wardrobe = G("WardrobeCollectionFrame")
    if wardrobe then
        for i = 1, 2 do if G("WardrobeCollectionFrameTab" .. i) then SK.Tab(G("WardrobeCollectionFrameTab" .. i)) end end
        local items = wardrobe.ItemsCollectionFrame
        if items then
            IconsFrame(items)
            Paging(items.PagingFrame)
        end
        local sets = wardrobe.SetsCollectionFrame
        if sets then
            SK.Inset(sets.LeftInset)
            SK.Inset(sets.RightInset)
            if sets.DetailsFrame then HideKeys(sets.DetailsFrame, "ModelFadeTexture", "IconRowBackground") end
        end
        if wardrobe.progressBar then SK.StatusBar(wardrobe.progressBar, 0.03, 0.6, 0.03) end
        SK.Auto(wardrobe)
    end

    if G("WarbandSceneJournal") then SK.Auto(G("WarbandSceneJournal")) end
    SK.Auto(cj)
end)

-- ============================================================================
-- Dungeon journal
-- ============================================================================

SK.Define("encounterjournal", function()
    local ej = G("EncounterJournal")
    if not ej then return end
    SK.Window(ej)
    HideNamed("EncounterJournalInsetBotLeftCorner", "EncounterJournalInsetBotRightCorner",
              "EncounterJournalInsetBottomBorder", "EncounterJournalInsetLeftBorder",
              "EncounterJournalInsetRightBorder", "EncounterJournalInstanceSelectBG")
    SK.NavBar(G("EncounterJournalNavBar"))
    local search = ej.searchBox or G("EncounterJournalSearchBox")
    local nav = ej.navBar or G("EncounterJournalNavBar")
    if search and nav then
        search:ClearAllPoints()
        search:SetPoint("TOPLEFT", nav, "TOPRIGHT", 4, 0)
    end

    -- The bottom tabs, in a row with no gaps for the hidden ones.
    local bottom = {}
    for _, n in ipairs({ "EncounterJournalJourneysTab", "EncounterJournalMonthlyActivitiesTab", "EncounterJournalSuggestTab",
                         "EncounterJournalDungeonTab", "EncounterJournalRaidTab", "EncounterJournalLootJournalTab", "TutorialsTab" }) do
        local t = G(n) or ej[n]
        if t then
            SK.Tab(t)
            bottom[#bottom + 1] = t
        end
    end
    local layout = SK.LayoutTabs(ej, bottom)
    if layout then
        if EncounterJournal_OnShow then hooksecurefunc("EncounterJournal_OnShow", layout) end
        for _, fn in ipairs({ "EncounterJournal_CheckAndDisplayTradingPostTab", "EncounterJournal_CheckAndDisplaySuggestedContentTab" }) do
            if _G[fn] then hooksecurefunc(fn, layout) end
        end
    end

    local sel = ej.instanceSelect or G("EncounterJournalInstanceSelect")
    if sel then
        HideKeys(sel, "bg", "evergreenBg")
        -- The instance pictures: a border, the frame art gone.
        SK.EachRow(sel.ScrollBox, function(row)
            if not SK.Once(row) then return end
            local bg = row.bgImage
            if bg then
                bg:SetTexCoord(0.01, 0.99, 0.02, 0.69)
                SK.Backdrop(row, "none", 3, -3, -3, 3)
            end
            local nt = row.GetNormalTexture and row:GetNormalTexture()
            if nt then nt:SetAlpha(0) end
            local pt = row.GetPushedTexture and row:GetPushedTexture()
            if pt then pt:SetAlpha(0) end
            local hl = row.GetHighlightTexture and row:GetHighlightTexture()
            if hl and bg then
                hl:SetColorTexture(1, 1, 1, 0.1)
                hl:SetAllPoints(bg)
            end
            SK.Hover(row)
        end)
    end

    local enc = ej.encounter
    if enc then
        local info = enc.info
        if info then
            HideKeys(info, "instanceTitle", "encounterTitle")
            Hide(G("EncounterJournalEncounterFrameInfoBG"))
            -- Overview / loot / abilities / model: square tabs stacked down
            -- the window's right edge, the shown ones only.
            local infoTabs = {}
            local r, g, b = SK.AccentRGB()
            for _, k in ipairs({ "overviewTab", "lootTab", "bossTab", "modelTab" }) do
                local tab = info[k]
                if tab and SK.Once(tab) then
                    infoTabs[#infoTabs + 1] = tab
                    tab:SetSize(32, 32)
                    local nt = tab.GetNormalTexture and tab:GetNormalTexture()
                    if nt then nt:SetAlpha(0) end
                    local pt = tab.GetPushedTexture and tab:GetPushedTexture()
                    if pt then pt:SetAlpha(0) end
                    local dt = tab.GetDisabledTexture and tab:GetDisabledTexture()
                    if dt then dt:SetAlpha(0) end
                    local bd = SK.Backdrop(tab, "button")
                    local hl = tab:GetHighlightTexture()
                    if hl then
                        hl:SetColorTexture(r, g, b, 0.2)
                        hl:ClearAllPoints()
                        hl:SetPoint("TOPLEFT", bd, "TOPLEFT", 1, -1)
                        hl:SetPoint("BOTTOMRIGHT", bd, "BOTTOMRIGHT", -1, 1)
                    end
                    if tab.selected then tab.selected:SetSize(36, 32) end
                    if tab.unselected then
                        tab.unselected:SetSize(36, 32)
                        tab.unselected:ClearAllPoints()
                        tab.unselected:SetPoint("CENTER")
                    end
                end
            end
            local function Stack()
                local prev
                for _, tab in ipairs(infoTabs) do
                    if tab:IsShown() then
                        tab:ClearAllPoints()
                        if prev then
                            tab:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -1)
                        else
                            tab:SetPoint("TOPLEFT", ej, "TOPRIGHT", 1, 0)
                        end
                        prev = tab
                    end
                end
            end
            if EncounterJournal_DisplayInstance then hooksecurefunc("EncounterJournal_DisplayInstance", Stack) end
            Stack()
        end
        local inst = G("EncounterJournalEncounterFrameInstanceFrame")
        if inst then Hide(G("EncounterJournalEncounterFrameInstanceFrameBG")) end
        Hide(G("EncounterJournalEncounterFrameInfoModelFrameShadow"))
    end

    SK.Auto(ej)
end)

-- ============================================================================
-- Achievements
-- ============================================================================

local function AchievementRow(row)
    if not SK.Once(row) then return end
    HideKeys(row, "Background", "BottomLeftTsunami", "BottomRightTsunami", "TopLeftTsunami", "TopRightTsunami",
             "BottomTsunami1", "TopTsunami1", "TitleBar", "Glow", "NineSlice", "RewardBackground", "GuildCornerL",
             "GuildCornerR", "PlusMinus")
    SK.Backdrop(row, "panel", 1, -1, -1, 1)
    local icon = row.Icon
    if icon then
        HideKeys(icon, "frame", "bling")
        if icon.texture then SK.Icon(icon.texture) end
    end
    if row.Highlight then SK.Strip(row.Highlight) end
    if row.Tracked then SK.Check(row.Tracked) end
    SK.Hover(row)
end

local function CategoryRow(row)
    if not SK.Once(row) then return end
    local btn = row.Button or row
    Hide(btn.Background)
    SK.Backdrop(btn, "button", 0, -1, 0, 1)
    SK.Hover(btn)
end

SK.Define("achievement", function()
    local af = G("AchievementFrame")
    if not af then return end
    SK.Window(af)
    HideNamed("AchievementFrameMetalBorderLeft", "AchievementFrameMetalBorderRight",
              "AchievementFrameMetalBorderBottom", "AchievementFrameMetalBorderTop", "AchievementFrameCategoriesBG",
              "AchievementFrameWaterMark", "AchievementFrameMetalBorderTopLeft", "AchievementFrameMetalBorderTopRight",
              "AchievementFrameMetalBorderBottomLeft", "AchievementFrameMetalBorderBottomRight",
              "AchievementFrameWoodBorderTopLeft", "AchievementFrameWoodBorderTopRight",
              "AchievementFrameWoodBorderBottomLeft", "AchievementFrameWoodBorderBottomRight")
    Hide(af.Background)
    if af.Header then SK.Strip(af.Header) end

    local cats = af.Categories or G("AchievementFrameCategories")
    if cats then
        SK.Strip(cats)
        Hide(cats.NineSlice)
        SK.Backdrop(cats, "panel")
        SK.EachRow(cats.ScrollBox, CategoryRow)
    end

    for _, n in ipairs({ "AchievementFrameAchievements", "AchievementFrameStats", "AchievementFrameComparison" }) do
        local f = G(n)
        if f then
            SK.Strip(f)
            Hide(f.NineSlice)
            if n == "AchievementFrameAchievements" and f.ScrollBox then SK.EachRow(f.ScrollBox, AchievementRow) end
        end
    end
    local summary = G("AchievementFrameSummary")
    if summary then
        SK.Strip(summary)
        Hide(summary.NineSlice)
    end

    -- Bottom tabs in ElvUI's row; the guild tab comes and goes.
    local layout = SK.NumberedTabs(af, "AchievementFrameTab")
    if layout then
        for _, fn in ipairs({ "AchievementFrame_UpdateTabs", "AchievementFrame_SetTabs" }) do
            if _G[fn] then hooksecurefunc(fn, layout) end
        end
    end
    SK.Auto(af)
end)
