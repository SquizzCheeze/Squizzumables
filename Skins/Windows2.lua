-- Skins/Windows2.lua
-- Batch 2 of the window skins: the character window, friends, the group
-- finder and PvP. These are big windows made almost entirely of Blizzard's
-- standard controls, so SK.Auto does most of the work and this file only
-- handles what is particular to each.

local _, ns = ...
local SK = ns.Skins
local Hide = SK.Hide

local function G(name) return _G[name] end

local function HideNamed(...)
    for i = 1, select("#", ...) do Hide(G(select(i, ...))) end
end

-- ============================================================================
-- Character
-- ============================================================================

local FOREVER = ns.BH.IS_FOREVER
local WHITE = "Interface\\Buttons\\WHITE8x8"

-- A small flat box behind a stats category title (ElvUI's 150 x 18 strip).
local function CategoryStrip(frame)
    if not frame or not SK.Once(frame) then return end
    Hide(frame.Background)
    local b = SK.Backdrop(frame, "button")
    b:ClearAllPoints()
    b:SetPoint("CENTER")
    b:SetSize(150, 18)
end

-- A soft light band through the middle of a stat row, where Blizzard has its
-- alternating row shade.
local GLOW_FROM, GLOW_TO = CreateColor(0.8, 0.8, 0.8, 0.25), CreateColor(0.8, 0.8, 0.8, 0)
local glows = setmetatable({}, { __mode = "k" })
local function RowGlow(frame)
    if not frame or not frame.Background then return end
    local g = glows[frame]
    if not g then
        Hide(frame.Background)
        local h = frame:GetHeight()
        local l = frame:CreateTexture(nil, "BORDER")
        l:SetSize(80, h > 0 and h or 15)
        l:SetPoint("LEFT", frame, "CENTER")
        l:SetTexture(WHITE)
        l:SetGradient("HORIZONTAL", GLOW_FROM, GLOW_TO)
        local r = frame:CreateTexture(nil, "BORDER")
        r:SetSize(80, h > 0 and h or 15)
        r:SetPoint("RIGHT", frame, "CENTER")
        r:SetTexture(WHITE)
        r:SetGradient("HORIZONTAL", GLOW_TO, GLOW_FROM)
        g = { l, r }
        glows[frame] = g
    end
    local shown = frame.Background:IsShown()
    g[1]:SetShown(shown)
    g[2]:SetShown(shown)
end

-- The equipment swap flyout (Alt over a slot), on both clients.
local function FlyoutButton(btn)
    if not btn or not SK.Once(btn) then return end
    local normal = btn.GetNormalTexture and btn:GetNormalTexture()
    if normal then normal:SetAlpha(0) end
    local icon = btn.icon or btn.Icon
    if icon then
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local px = SK.Pixel(btn)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", px, -px)
        icon:SetPoint("BOTTOMRIGHT", -px, px)
    end
    local hl = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if hl then hl:SetColorTexture(1, 1, 1, 0.15) end
    local push = btn.GetPushedTexture and btn:GetPushedTexture()
    if push then push:SetColorTexture(1, 1, 1, 0.2) end
    local b = SK.Backdrop(btn, "button")
    SK.QualityBorder(btn.IconBorder, b)
end

local function SkinFlyout()
    local fly = G("EquipmentFlyoutFrame")
    if not fly then return end
    Hide(G("EquipmentFlyoutFrameHighlight"))
    local frame = fly.buttonFrame or G("EquipmentFlyoutFrameButtons")
    local function Update()
        if frame then
            SK.Strip(frame)
            for i = 1, (frame.numBGs or 1) do Hide(frame["bg" .. i]) end
            if not SK.GetBackdrop(frame) then SK.Backdrop(frame, "panel", -2, 2, 2, -2) end
        end
        for _, b in ipairs(fly.buttons or {}) do FlyoutButton(b) end
        local nav = fly.NavigationFrame
        if nav and SK.Once(nav) then
            SK.Strip(nav)
            SK.Backdrop(nav, "panel")
            if nav.PrevButton then SK.Arrow(nav.PrevButton, "left") end
            if nav.NextButton then SK.Arrow(nav.NextButton, "right") end
        end
    end
    if EquipmentFlyout_UpdateItems then hooksecurefunc("EquipmentFlyout_UpdateItems", Update) end
end

-- The little arrow buttons beside each Forever slot that open the flyout.
local function PopoutArrow(btn)
    local parent = btn:GetParent()
    local dir = (parent and parent.flyoutDirection) or btn.flyoutDirection
                or (parent and parent.verticalFlyout and "UP") or "RIGHT"
    if btn.flyoutLocked then
        dir = (dir == "RIGHT" and "LEFT") or (dir == "LEFT" and "RIGHT") or (dir == "UP" and "DOWN") or "UP"
    end
    if not SK.GetBackdrop(btn) then SK.Backdrop(btn, "button") end
    if parent then
        if dir == "UP" or dir == "DOWN" then btn:SetWidth(parent:GetWidth()) else btn:SetHeight(parent:GetHeight()) end
    end
    local rot = ({ UP = 0, DOWN = math.pi, LEFT = math.pi / 2, RIGHT = -math.pi / 2 })[dir] or 0
    for _, t in ipairs({ btn:GetNormalTexture(), btn:GetPushedTexture() }) do
        if t then
            t:SetTexture(SK.ARROW)
            t:SetTexCoord(0, 1, 0, 1)
            t:SetRotation(rot)
            t:ClearAllPoints()
            t:SetPoint("CENTER")
            t:SetSize(12, 12)
        end
    end
    local hl = btn:GetHighlightTexture()
    if hl then
        hl:SetColorTexture(1, 1, 1, 0.25)
        hl:SetRotation(0)
        hl:SetAllPoints()
    end
end

-- Forever's list tabs (reputation, currency, skills, statistics) share one
-- shape: headers with a +/- state icon and entries with a coloured bar or an
-- icon.
local function ForeverListRow(row)
    if not SK.Once(row) then return end
    if row.StateIcon then
        local keep = { [row.StateIcon] = true }
        SK.Strip(row, keep)
        SK.Backdrop(row, "button", 0, -1, 0, 1)
        return
    end
    local content = row.Content
    if content then
        local hl = content.BackgroundHighlight
        if hl and hl.TextureRegions then
            for _, r in ipairs(hl.TextureRegions) do r:SetTexture(WHITE) end
        end
        SK.ColoredBar(content.ReputationBar or content.SkillsBar)
        if content.CurrencyIcon then SK.Icon(content.CurrencyIcon) end
    end
end

local function ForeverList(frame)
    if not frame then return end
    if frame.ScrollBox then
        for _, child in ipairs({ frame.ScrollBox:GetChildren() }) do SK.Strip(child) end
        SK.EachRow(frame.ScrollBox, ForeverListRow)
    end
    SK.ScrollBar(frame.ScrollBar)
    SK.Auto(frame)
end

-- CharacterFrameSidePaneTemplate: the detail pane beside a Forever list.
local function SidePane(pane)
    if not pane or not SK.Once(pane) then return end
    SK.Strip(pane)
    Hide(pane.Divider)
    SK.ScrollBar(pane.DescriptionScrollBar)
    local function Rows(self)
        if not self.rowPools then return end
        for row in self.rowPools:EnumerateActive() do
            if row.Background then
                CategoryStrip(row)
            elseif row.IconSlot and SK.Once(row) then
                Hide(row.IconSlot)
                SK.Icon(row.Icon)
            end
        end
    end
    if pane.AcquireRow then hooksecurefunc(pane, "AcquireRow", Rows) end
    Rows(pane)
    SK.Auto(pane)
end

-- The stats lists on Forever (player and pet): scroll boxes of categories and rows.
local function ForeverStats(box)
    if not box then return end
    SK.Strip(box)
    Hide(box.ClassBackground)
    SK.ScrollBar(box.ScrollBar)
    local sb = box.ScrollBox
    if sb then
        if sb.ApplyEdgeFade and sb.ClearAlphaGradient then
            hooksecurefunc(sb, "ApplyEdgeFade", function(self) self:ClearAlphaGradient() end)
        end
        local function Each(self)
            self:ForEachFrame(function(row)
                if row.Title then CategoryStrip(row) else RowGlow(row) end
            end)
        end
        hooksecurefunc(sb, "Update", Each)
        Each(sb)
    end
end

-- Retail's reputation and currency rows.
local function RetailListRow(row)
    if row.Right then SK.ListHeader(row) end
    if not SK.Once(row) then return end
    local content = row.Content
    if content then
        if content.ReputationBar then SK.StatusBar(content.ReputationBar) end
        if content.CurrencyIcon then SK.Icon(content.CurrencyIcon) end
    end
end

local function Slots()
    local items = G("PaperDollItemsFrame")
    if not items then return end
    for _, slot in ipairs({ items:GetChildren() }) do
        if slot:IsObjectType("Button") or slot:IsObjectType("ItemButton") then
            local name = slot:GetName()
            Hide(name and G(name .. "Frame"))
            if slot.BorderFrame then SK.Strip(slot.BorderFrame) end   -- Forever's gear slot ring
            SK.ItemButton(slot)
            local pop = slot.popoutButton
            if pop and not FOREVER and SK.Once(pop) then
                local p = pop:GetPoint()
                pop:ClearAllPoints()
                if p == "TOP" then pop:SetPoint("TOP", slot, "BOTTOM", 0, 2) else pop:SetPoint("LEFT", slot, "RIGHT", -2, 0) end
            end
        end
    end
    if FOREVER and EquipmentFlyoutPopoutButton_RefreshVisualState then
        hooksecurefunc("EquipmentFlyoutPopoutButton_RefreshVisualState", PopoutArrow)
        for _, slot in ipairs({ items:GetChildren() }) do
            if slot.popoutButton then PopoutArrow(slot.popoutButton) end
        end
    end
    -- The slot's own highlight, flat and inside the border.
    if PaperDollItemSlotButton_Update then
        hooksecurefunc("PaperDollItemSlotButton_Update", function(slot)
            local hl = slot.GetHighlightTexture and slot:GetHighlightTexture()
            if hl then
                hl:SetColorTexture(1, 1, 1, 0.25)
                local px = SK.Pixel(slot)
                hl:ClearAllPoints()
                hl:SetPoint("TOPLEFT", px, -px)
                hl:SetPoint("BOTTOMRIGHT", -px, px)
            end
        end)
    end
end

-- The title and equipment set lists in the sidebar.
local function SidebarLists()
    local pd = G("PaperDollFrame")
    if not pd then return end
    local titles, sets = pd.TitleManagerPane, pd.EquipmentManagerPane
    if titles then
        SK.ScrollBar(titles.ScrollBar)
        SK.EachRow(titles.ScrollBox, function(row)
            if SK.Once(row) then row:DisableDrawLayer("BACKGROUND") end
        end)
    end
    if sets then
        SK.ScrollBar(sets.ScrollBar)
        if FOREVER then SK.Strip(sets) end
        SK.EachRow(sets.ScrollBox, function(row)
            if not SK.Once(row) then return end
            if FOREVER then
                for _, r in ipairs({ row:GetRegions() }) do
                    local atlas = r:IsObjectType("Texture") and r:GetAtlas()
                    if atlas == "UI-Character-Info-OutfitCard" or atlas == "UI-Character-Info-OutfitIcon-Frame" then
                        r:SetAlpha(0)
                    end
                end
                SK.Backdrop(row, "panel", 0, 0, -7, 0)
            else
                Hide(row.BgTop)
                Hide(row.BgMiddle)
                Hide(row.BgBottom)
            end
            if row.icon then SK.Icon(row.icon) end
            if row.HighlightBar then
                row.HighlightBar:SetColorTexture(1, 1, 1, 0.25)
                row.HighlightBar:SetDrawLayer("BACKGROUND")
            end
            if row.SelectedBar then
                row.SelectedBar:SetColorTexture(0.8, 0.8, 0.8, 0.25)
                row.SelectedBar:SetDrawLayer("BACKGROUND")
            end
        end)
        for _, k in ipairs({ "EquipSet", "SaveSet", "NewSet" }) do SK.Button(sets[k]) end
        if sets.NewSet then Hide(sets.NewSet.StateTexture) end
    end
    SK.Button(G("PaperDollFrameEquipSet"))
    SK.Button(G("PaperDollFrameSaveSet"))
    local popup = G("GearManagerPopupFrame")
    if popup then
        popup:HookScript("OnShow", function(self)
            if SK.GetBackdrop(self) then return end
            if self.BorderBox then SK.Strip(self.BorderBox) end
            SK.Window(self)
            SK.Auto(self)
        end)
    end
end

-- The small sidebar tabs: stats, titles, sets (and Forever's fourth).
local function SidebarTabs()
    local bar = G("PaperDollSidebarTabs")
    if bar then
        SK.Strip(bar)
        Hide(bar.DecorLeft)
        Hide(bar.DecorRight)
    end
    for i = 1, 4 do
        local tab = G("PaperDollSidebarTab" .. i)
        if tab and SK.Once(tab) then
            local icon = tab.Icon
            if FOREVER then
                for _, r in ipairs({ tab:GetRegions() }) do
                    if r ~= icon and r:IsObjectType("Texture") then r:SetAlpha(0) end
                end
                local ck = tab.GetCheckedTexture and tab:GetCheckedTexture()
                if ck then ck:SetColorTexture(1, 1, 1, 0.3); ck:SetAllPoints(icon) end
                if icon then icon:SetSize(32, 32) end
                local hl = tab.GetHighlightTexture and tab:GetHighlightTexture()
                if hl then hl:SetColorTexture(1, 1, 1, 0.3); hl:SetAllPoints(icon) end
                tab:SetFrameLevel(tab:GetFrameLevel() + 5)
            else
                Hide(tab.TabBg)
                if icon then icon:SetAllPoints() end
                if tab.Highlight then tab.Highlight:SetColorTexture(1, 1, 1, 0.3); tab.Highlight:SetAllPoints() end
                -- Blizzard darkens the tabs that are not open with this.
                if tab.Hider then tab.Hider:SetColorTexture(0, 0, 0, 0.8); tab.Hider:SetAllPoints() end
                if i == 1 then
                    -- The first is the character's portrait: cropped, and kept cropped.
                    local busy = false
                    for _, r in ipairs({ tab:GetRegions() }) do
                        if r:IsObjectType("Texture") then
                            r:SetTexCoord(0.16, 0.86, 0.16, 0.86)
                            hooksecurefunc(r, "SetTexCoord", function(self, x1)
                                if busy or x1 == 0.16 then return end
                                busy = true
                                self:SetTexCoord(0.16, 0.86, 0.16, 0.86)
                                busy = false
                            end)
                        end
                    end
                end
            end
            if icon then
                local px = SK.Pixel(tab)
                local b = SK.Backdrop(tab, "button")
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", icon, "TOPLEFT", -px, px)
                b:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", px, -px)
                if tab.Hider then tab.Hider:SetAllPoints(b) end
            end
        end
    end
end

local function RetailCharacter(cf)
    SK.NumberedTabs(cf, "CharacterFrameTab")
    HideNamed("PaperDollInnerBorderTopLeft", "PaperDollInnerBorderTopRight", "PaperDollInnerBorderBottomLeft",
              "PaperDollInnerBorderBottomRight", "PaperDollInnerBorderLeft", "PaperDollInnerBorderRight",
              "PaperDollInnerBorderTop", "PaperDollInnerBorderBottom", "PaperDollInnerBorderBottom2")
    -- The model keeps its race art, dimmed under a black wash, in a frame.
    local overlay = G("CharacterModelFrameBackgroundOverlay")
    if overlay then overlay:SetColorTexture(0, 0, 0) end
    for _, c in ipairs({ "TopLeft", "TopRight", "BotLeft", "BotRight" }) do
        local bg = G("CharacterModelFrameBackground" .. c)
        if bg then
            bg:SetDesaturated(false)
            hooksecurefunc(bg, "SetDesaturated", function(self, v) if v then self:SetDesaturated(false) end end)
        end
    end
    local scene = G("CharacterModelScene")
    if scene then
        local px = SK.Pixel(scene)
        SK.Backdrop(scene, "none", -px, px, px, -(px * 2))
    end
    SK.Inset(G("CharacterFrameInsetRight"))

    -- Stats.
    local pane = G("CharacterStatsPane")
    if pane then
        SK.Strip(pane)
        Hide(pane.ClassBackground)
        for _, k in ipairs({ "ItemLevelCategory", "AttributesCategory", "EnhancementsCategory" }) do CategoryStrip(pane[k]) end
        local il = pane.ItemLevelFrame
        if il then
            RowGlow(il)
            if il.Value then
                local font, _, flags = il.Value:GetFont()
                if font then il.Value:SetFont(font, 20, flags) end
            end
        end
        if PaperDollFrame_UpdateStats and pane.statsFramePool then
            hooksecurefunc("PaperDollFrame_UpdateStats", function()
                for f in pane.statsFramePool:EnumerateActive() do RowGlow(f) end
            end)
        end
    end

    -- Reputation.
    local rep = G("ReputationFrame")
    if rep then
        SK.Strip(rep)
        SK.ScrollBar(rep.ScrollBar)
        SK.EachRow(rep.ScrollBox, RetailListRow)
        SK.Auto(rep)
        local d = rep.ReputationDetailFrame
        if d then
            SK.Window(d)
            SK.Auto(d)
        end
    end

    -- Currency.
    local tok = G("TokenFrame")
    if tok then
        SK.Strip(tok)
        SK.ScrollBar(tok.ScrollBar)
        SK.EachRow(tok.ScrollBox, RetailListRow)
        SK.Auto(tok)
        local pop = G("TokenFramePopup")
        if pop then
            SK.Window(pop)
            SK.Auto(pop)
            local close = pop["$parent.CloseButton"]
            if close then SK.Close(close) end
            pop:ClearAllPoints()
            pop:SetPoint("TOPLEFT", tok, "TOPRIGHT", 3, -28)
        end
    end
end

local function ForeverCharacter(cf)
    if cf.LeftPaneHost then SK.Strip(cf.LeftPaneHost) end
    local right = cf.RightPaneHost
    if right then
        SK.Strip(right)
        SK.Backdrop(right, "panel", 6, -6, -6, 6)
        Hide(right.StoneBg)
        local divider = right:GetChildren()
        if divider then SK.Strip(divider) end
    end
    -- The toggle that folds the right pane away: an arrow pointing the way it goes.
    local toggle = cf.RightPaneToggleButton
    if toggle then
        SK.Backdrop(toggle, "button")
        SK.Hover(toggle)
        local function Arrow(frame)
            local rot = frame.IsRightPaneCollapsed and frame:IsRightPaneCollapsed() and -math.pi / 2 or math.pi / 2
            for _, t in ipairs({ toggle:GetNormalTexture(), toggle:GetPushedTexture() }) do
                if t then
                    t:SetTexture(SK.ARROW)
                    t:SetTexCoord(0, 1, 0, 1)
                    t:SetRotation(rot)
                    t:ClearAllPoints()
                    t:SetPoint("CENTER")
                    t:SetSize(12, 12)
                end
            end
            local hl = toggle:GetHighlightTexture()
            if hl then hl:SetColorTexture(1, 1, 1, 0.15); hl:SetAllPoints() end
        end
        if cf.UpdateRightPaneToggleButton then hooksecurefunc(cf, "UpdateRightPaneToggleButton", Arrow) end
        Arrow(cf)
    end
    -- The mode tabs down the right edge.
    local tabs = cf.ModeTabs and cf.ModeTabs.Tabs
    if tabs then
        for _, t in ipairs(tabs) do SK.SideTab(t) end
        local function Layout(frame) SK.LayoutSideTabs(frame, tabs) end
        if cf.UpdateTabLayout then hooksecurefunc(cf, "UpdateTabLayout", Layout) end
        Layout(cf)
    end

    local pd = G("PaperDollFrame")
    if pd then Hide(pd.TopBackgroundStripHost) end

    -- The model: a dark wash over the race art, in a frame, with the slot
    -- columns pulled out to the pane's edges round it.
    local scene = G("CharacterModelScene")
    if scene and cf.LeftPaneHost then
        if scene.BackgroundOverlay then scene.BackgroundOverlay:SetColorTexture(0, 0, 0, 0.5) end
        scene:ClearAllPoints()
        scene:SetPoint("TOPLEFT", cf.LeftPaneHost, "TOPLEFT", 46, -31)
        scene:SetPoint("BOTTOMRIGHT", cf.LeftPaneHost, "BOTTOMRIGHT", -46, 46)
        local px = SK.Pixel(scene)
        SK.Backdrop(scene, "none", -px, px, px, -px)
        local tl, tr, bl, br = scene.BackgroundTopLeft, scene.BackgroundTopRight, scene.BackgroundBotLeft, scene.BackgroundBotRight
        if tl and tr and bl and br then
            tl:SetPoint("BOTTOMRIGHT", scene, "BOTTOMRIGHT", -25, 54)
            tr:SetWidth(25)
            tr:SetPoint("BOTTOMRIGHT", scene, "BOTTOMRIGHT", 0, 54)
            bl:SetHeight(54)
            bl:SetPoint("BOTTOMRIGHT", scene, "BOTTOMRIGHT", -25, 0)
            br:SetSize(25, 54)
        end
        local head, hands = G("CharacterHeadSlot"), G("CharacterHandsSlot")
        if head then head:ClearAllPoints(); head:SetPoint("TOPLEFT", cf.LeftPaneHost, "TOPLEFT", 6, -55) end
        if hands then hands:ClearAllPoints(); hands:SetPoint("TOPRIGHT", cf.LeftPaneHost, "TOPRIGHT", -6, -55) end
        local main = G("CharacterMainHandSlot")
        if main and main:GetNumPoints() > 0 then
            local p, rel, rp, x, y = main:GetPoint(1)
            main:SetPoint(p, rel, rp, x, (y or 0) - 24)
        end
        -- The pet's happiness sits in the scene's corner, and only on the pet tab.
        local happy = G("PetPaperDollPetHappinessInfo")
        if happy then
            happy:ClearAllPoints()
            happy:SetPoint("TOPLEFT", scene, "TOPLEFT", 6, -6)
            if happy.UpdateHappiness then
                hooksecurefunc(happy, "UpdateHappiness", function(self)
                    local petBox = G("CharacterStatsPanePetScrollBox")
                    if petBox and not petBox:IsShown() then self:Hide() end
                end)
            end
        end
    end
    SK.ColoredBar(G("PetPaperDollFrameExpBar"))

    ForeverStats(G("CharacterStatsPaneScrollBox"))
    ForeverStats(G("CharacterStatsPanePetScrollBox"))

    -- The list tabs and their side panes.
    local rep = G("ReputationFrame")
    if rep then
        SK.Strip(rep)
        ForeverList(rep)
        local d = rep.ReputationDetailFrame
        SidePane(d)
        if d then SK.ColoredBar(d.StandingBar) end
    end
    local tok = G("TokenFrame")
    if tok then
        SK.Strip(tok)
        ForeverList(tok)
        SidePane(tok.DetailFrame)
    end
    local skills = G("SkillsFrame")
    if skills then
        SK.Strip(skills)
        ForeverList(skills)
        local d = skills.SkillDetailFrame
        SidePane(d)
        if d then SK.ColoredBar(d.RankBar) end
    end
    local pvp = G("PVPRankFrame")
    if pvp then
        if pvp.MainInfoFrame then Hide(pvp.MainInfoFrame.Line) end
        SidePane(pvp.DetailFrame)
        SK.Auto(pvp)
    end
end

SK.Define("character", function()
    local cf = G("CharacterFrame")
    if not cf then return end
    SK.Window(cf)
    Slots()
    SkinFlyout()
    SidebarTabs()
    SidebarLists()
    if FOREVER then ForeverCharacter(cf) else RetailCharacter(cf) end
    SK.Auto(cf)

    -- Moving currency between characters (both clients).
    local log = G("CurrencyTransferLog")
    if log then
        SK.Window(log)
        SK.ScrollBar(log.ScrollBar)
        SK.EachRow(log.ScrollBox, function(row)
            if SK.Once(row) and row.CurrencyIcon then
                SK.Icon(row.CurrencyIcon)
                row.CurrencyIcon:SetSize(16, 16)
            end
        end)
    end
    local menu = G("CurrencyTransferMenu")
    if menu then
        SK.Window(menu)
        SK.Auto(menu)
        local c = menu.Content
        if c then
            for _, k in ipairs({ "SourceBalancePreview", "PlayerBalancePreview" }) do
                local p = c[k]
                if p and p.BalanceInfo then SK.Icon(p.BalanceInfo.CurrencyIcon) end
            end
            if c.AmountSelector and c.AmountSelector.InputBox then
                SK.EditBox(c.AmountSelector.InputBox, 0, -3, -1, 8)
            end
        end
    end
end)

-- Forever's statistics tab is its own Blizzard addon.
SK.DefineLate("character", FOREVER and "Blizzard_Statistics" or nil, function()
    ForeverList(G("StatisticsFrame"))
end)

-- ============================================================================
-- Friends
-- ============================================================================

local BNET_BG = FRIENDS_BNET_BACKGROUND_COLOR

-- The broadcast box's nine border pieces.
local function BroadcastBox(eb)
    if not eb then return end
    for _, k in ipairs({ "BottomBorder", "BottomLeftBorder", "BottomRightBorder", "LeftBorder", "MiddleBorder",
                         "RightBorder", "TopBorder", "TopLeftBorder", "TopRightBorder" }) do
        Hide(eb[k])
    end
    SK.EditBox(eb)
end

-- A friend's row: the summon and invite buttons squared off, the row's
-- highlight flat blue.
local function FriendButton(button)
    if not button or not SK.Once(button) then return end
    local summon = button.summonButton
    if summon then
        Hide(summon.SlotBackground)
        Hide(summon.SlotArt)
        summon:SetSize(24, 24)
        for _, t in ipairs({ summon:GetNormalTexture(), summon:GetPushedTexture(), summon:GetHighlightTexture() }) do
            if t then t:SetTexCoord(0.12, 0.88, 0.12, 0.88); t:ClearAllPoints(); t:SetPoint("TOPLEFT", 1, -1); t:SetPoint("BOTTOMRIGHT", -1, 1) end
        end
        SK.Backdrop(summon, "panel")
    end
    local invite = button.travelPassButton
    if invite then
        invite:SetSize(24, 24)
        if invite.HighlightTexture then
            invite.HighlightTexture:SetColorTexture(1, 1, 1, 0.25)
            invite.HighlightTexture:SetAllPoints()
        end
        SK.Backdrop(invite, "panel")
    end
    local hl = button:GetHighlightTexture()
    if hl then hl:SetColorTexture(0.24, 0.56, 1, 0.2) end
end

-- The social window (SocialUIFrame) that both clients can show in place of
-- the friends window, when the server turns it on.
local socialTabs = {}
local function SocialRow(row)
    if not SK.Once(row) then return end
    if row.CollapseButton then
        -- A collapsible header: Blizzard's plus / minus kept.
        local n = row.GetNormalTexture and row:GetNormalTexture()
        if n then n:SetAlpha(0) end
        local h = row.GetHighlightTexture and row:GetHighlightTexture()
        if h then h:SetAlpha(0) end
        SK.Backdrop(row, "button", 0, -1, 0, 1)
    elseif row.Background then
        Hide(row.Background)
        local b = SK.Backdrop(row, "panel", 0, -1, 0, 1)
        local hl = row:GetHighlightTexture() or row.Highlight
        if hl then hl:SetColorTexture(1, 1, 1, 0.25); hl:SetAllPoints(b) end
        if row.Selected then
            local r, g, bl = SK.AccentRGB()
            row.Selected:SetColorTexture(r, g, bl, 0.25)
            row.Selected:SetAllPoints(b)
        end
        for _, k in ipairs({ "PartyButton", "RAFSummonButton", "AcceptButton" }) do SK.Button(row[k]) end
    end
end

local function SocialContacts(frame)
    if not frame then return end
    SK.Strip(frame)
    SK.Button(frame.ActionButton)
    SK.ScrollBar(frame.ScrollBar)
    SK.EachRow(frame.ScrollBox, SocialRow)
    local bar = frame.FilterBar
    if bar then
        if bar.SearchBar then SK.EditBox(bar.SearchBar) end
        local filter = bar.SearchFilterDropdown
        if filter then
            SK.Dropdown(filter)
            if filter.ResetButton then
                SK.Close(filter.ResetButton)
                filter.ResetButton:ClearAllPoints()
                filter.ResetButton:SetPoint("CENTER", filter, "TOPRIGHT")
            end
        end
    end
    SK.Auto(frame)
end

local function SocialUI()
    local sf = G("SocialUIFrame")
    if not sf then return end
    SK.Window(sf)
    if sf.RefreshTabs then
        hooksecurefunc(sf, "RefreshTabs", function(self)
            wipe(socialTabs)
            for _, data in ipairs(self.availableTabData or {}) do
                local tab = self.GetTabByType and self:GetTabByType(data.tabType)
                if tab then
                    SK.SideTab(tab)
                    socialTabs[#socialTabs + 1] = tab
                end
            end
            SK.LayoutSideTabs(self, socialTabs)
        end)
    end
    local bnet = sf.BattleNetBar
    if bnet then
        SK.Strip(bnet)
        local c = bnet.ControlsContainer
        if c then
            if c.OnlineStatusDropdown then SK.Dropdown(c.OnlineStatusDropdown) end
            local menuBtn = c.BattleNetMenuButton
            if menuBtn and SK.Once(menuBtn) then
                SK.Backdrop(menuBtn, "button")
                SK.Hover(menuBtn)
            end
            if c.PersonalBattleTagDisplay and c.BattleNetBackground then
                local b = SK.Backdrop(c.PersonalBattleTagDisplay, BNET_BG and { BNET_BG.r, BNET_BG.g, BNET_BG.b, BNET_BG.a } or "panel")
                b:ClearAllPoints()
                b:SetAllPoints(c.BattleNetBackground)
                Hide(c.BattleNetBackground)
            end
        end
    end
    for _, k in ipairs({ "BattleNetUnavailableNoticeFrame", "BattleNetBroadcastFrame", "IgnoreListFrame", "RaidInfoFrame" }) do
        local f = sf[k]
        if f then
            SK.Window(f)
            if f.EditBox then BroadcastBox(f.EditBox) end
            SK.Auto(f)
        end
    end
    for _, k in ipairs({ "FriendsList", "RecentAlliesList", "QuickJoinFrame", "FriendRequestsList", "RecruitAFriendFrame" }) do
        SocialContacts(sf[k])
    end
    local raid = sf.RaidFrame
    if raid then
        SK.Auto(raid)
        -- Its player buttons are secure: only out of combat.
        if raid.UpdateContents then
            hooksecurefunc(raid, "UpdateContents", function(self)
                if InCombatLockdown() then return end
                for _, list in ipairs({ self.groups or {}, self.players or {} }) do
                    for _, f in pairs(list) do
                        if SK.Once(f) then
                            SK.Strip(f)
                            SK.Backdrop(f, "panel")
                        end
                    end
                end
            end)
        end
    end
end

SK.Define("friends", function()
    local ff = G("FriendsFrame")
    if not ff then return end
    SK.Window(ff)
    Hide(G("FriendsFrameIcon"))

    -- Bottom tabs (Forever has no Who tab: its who list is in the group finder).
    local list = {}
    for i = 1, 4 do
        local t = G("FriendsFrameTab" .. i)
        if t then
            SK.Tab(t)
            list[#list + 1] = t
        end
    end
    SK.LayoutTabs(ff, list)
    if G("FriendsTabHeader") then SK.TabSystem(G("FriendsTabHeader").TabSystem) end

    -- The Battle.net bar along the top: a flat box in Battle.net blue.
    local bnet = G("FriendsFrameBattlenetFrame")
    if bnet and SK.Once(bnet) then
        SK.Strip(bnet)
        SK.Backdrop(bnet, BNET_BG and { BNET_BG.r, BNET_BG.g, BNET_BG.b, BNET_BG.a } or "panel")
        if bnet.ContactsMenuButton then
            SK.Button(bnet.ContactsMenuButton)
            bnet.ContactsMenuButton:SetSize(31, 31)
        end
        local bc = bnet.BroadcastFrame
        if bc then
            SK.Window(bc)
            BroadcastBox(bc.EditBox)
            SK.Auto(bc)
            bc:ClearAllPoints()
            bc:SetPoint("TOPLEFT", ff, "TOPRIGHT", 3, -1)
        end
        local un = bnet.UnavailableInfoFrame
        if un then
            Hide(un.Bg)
            SK.Window(un)
            un:ClearAllPoints()
            un:SetPoint("TOPLEFT", ff, "TOPRIGHT", 1, -18)
        end
    end

    -- Rows.
    if FriendsFrame_UpdateFriendButton then hooksecurefunc("FriendsFrame_UpdateFriendButton", FriendButton) end
    if FriendsFrame_UpdateFriendInviteButton then
        hooksecurefunc("FriendsFrame_UpdateFriendInviteButton", function(b)
            SK.Button(b.AcceptButton)
            SK.Button(b.DeclineButton)
        end)
    end
    if FriendsFrame_UpdateFriendInviteHeaderButton then
        hooksecurefunc("FriendsFrame_UpdateFriendInviteHeaderButton", function(b)
            if not SK.Once(b) then return end
            b:DisableDrawLayer("BACKGROUND")
            local bd = SK.Backdrop(b, "panel", 2, -2, -2, 2)
            local hl = b:GetHighlightTexture()
            if hl then hl:SetColorTexture(0.24, 0.56, 1, 0.2); hl:SetAllPoints(bd) end
        end)
    end

    -- Ignore list, who list (retail), quick join.
    local ignore = ff.IgnoreListWindow
    if ignore then
        SK.Window(ignore)
        SK.Auto(ignore)
    end
    local who = G("WhoFrame")
    if who then
        SK.Strip(who)
        SK.Inset(G("WhoFrameListInset"))
        local eb = G("WhoFrameEditBox")
        if eb and eb.Backdrop then
            SK.Strip(eb.Backdrop)
            SK.Backdrop(eb.Backdrop, "button")
        end
        for i = 1, 4 do SK.Strip(G("WhoFrameColumnHeader" .. i)) end
    end
    local qj = G("QuickJoinFrame")
    if qj and qj.JoinQueueButton then
        SK.Button(qj.JoinQueueButton)
        qj.JoinQueueButton:SetSize(131, 21)
        qj.JoinQueueButton:ClearAllPoints()
        qj.JoinQueueButton:SetPoint("BOTTOMRIGHT", qj, "BOTTOMRIGHT", -6, 4)
    end

    -- Recruit a friend.
    local raf = G("RecruitAFriendFrame")
    if raf then
        local claim = raf.RewardClaiming
        if claim then
            SK.Strip(claim)
            Hide(claim.Background)
            Hide(claim.Watermark)
            SK.Backdrop(claim, "panel")
            local nr = claim.NextRewardButton
            if nr then
                if nr.CircleMask and nr.Icon then nr.Icon:RemoveMaskTexture(nr.CircleMask) end
                Hide(nr.IconBorder)
                Hide(nr.IconOverlay)
                SK.Icon(nr.Icon)
            end
        end
        local rl = raf.RecruitList
        if rl then
            SK.Strip(rl.Header)
            if rl.ScrollFrameInset then SK.Inset(rl.ScrollFrameInset); SK.Backdrop(rl.ScrollFrameInset, "panel") end
        end
        local splash = raf.SplashFrame
        if splash and SK.ParchmentActive() then
            Hide(splash.PictureFrame)
            for _, k in ipairs({ "Bracket_TopLeft", "Bracket_TopRight", "Bracket_BottomRight", "Bracket_BottomLeft",
                                 "PictureFrame_Bracket_TopLeft", "PictureFrame_Bracket_TopRight",
                                 "PictureFrame_Bracket_BottomRight", "PictureFrame_Bracket_BottomLeft" }) do
                Hide(splash[k])
            end
        end
    end

    SK.Auto(ff)
    for _, n in ipairs({ "AddFriendFrame", "FriendsFriendsFrame", "RecruitAFriendRewardsFrame",
                         "RecruitAFriendRecruitmentFrame", "QuickJoinRoleSelectionFrame" }) do
        local f = G(n)
        if f then
            if f.Border then Hide(f.Border) end
            Hide(f.ScrollFrameBorder)
            Hide(f.Background)
            Hide(f.Watermark)
            SK.Window(f)
            SK.Auto(f)
        end
    end
    SK.Auto(G("AddFriendInfoFrame"))

    SocialUI()
end)

-- ============================================================================
-- Group finder
-- ============================================================================

-- A role's tick box (tank / healer / damage under its icon): small and flat.
local function RoleCheck(role)
    if not role then return end
    local cb = role.checkButton or role.CheckButton
    if not cb then return end
    if cb:GetScale() ~= 1 then cb:SetScale(1) end
    SK.Check(cb)
    cb:SetSize(18, 18)
    local b = SK.GetBackdrop(cb)
    if b then b:ClearAllPoints(); b:SetAllPoints(cb) end
    Hide(role.shortageBorder)
end

-- A reward item beside a dungeon or raid (icon, name plate, count).
local function RewardItem(item)
    if not item or not SK.Once(item) then return end
    local name = item:GetName()
    Hide(item.NameFrame or (name and G(name .. "NameFrame")))
    Hide(item.shortageBorder)
    local icon = item.Icon or (name and G(name .. "IconTexture"))
    if icon then
        local border = SK.Icon(icon)
        SK.QualityBorder(item.IconBorder, border)
    end
end

-- The ready-to-enter dialog: its dungeon picture kept in a frame.
local function ReadyDialog(d)
    if not d or not SK.Once(d) then return end
    Hide(d.bottomArt)
    if d.Border then SK.Strip(d.Border) end
    if d.instanceInfo then Hide(d.instanceInfo.underline) end
    local px = SK.Pixel(d)
    SK.Backdrop(d, "panel")
    if d.background then
        local b = SK.Backdrop(d.background, "none", -px, px, px, -px)
        b:SetFrameLevel(d:GetFrameLevel())
    end
    SK.Shadow(d)
    SK.Auto(d)
end

-- A group-finder category card (dungeons, raids, delves...): flat with its picture.
local function CategoryCard(card)
    if not card or not SK.Once(card) then return end
    if card.Icon then
        card.Icon:SetDrawLayer("BACKGROUND", 2)
        card.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local px = SK.Pixel(card)
        card.Icon:ClearAllPoints()
        card.Icon:SetPoint("TOPLEFT", px, -px)
        card.Icon:SetPoint("BOTTOMRIGHT", -px, px)
    end
    Hide(card.Cover)
    if card.HighlightTexture then card.HighlightTexture:SetColorTexture(1, 1, 1, 0.1) end
    if card.SetPushedTexture and FOREVER then Hide(card:GetPushedTexture()) end
    SK.Backdrop(card, "button")
end

local function PaintCategory(frame, index, categoryID, filters)
    local card = frame.CategoryButtons and frame.CategoryButtons[index]
    if not card then return end
    CategoryCard(card)
    Hide(card.SelectedTexture)
    local b = SK.GetBackdrop(card)
    if b then
        -- The chosen category gets a gold edge, as Blizzard's art had.
        if frame.selectedCategory == categoryID and frame.selectedFilters == filters then
            b:SetBackdropBorderColor(1, 1, 0)
        else
            b:SetBackdropBorderColor(SK.BorderRGB())
        end
    end
end

-- The group buttons down the left of the dungeon finder: a wide flat button
-- with its square icon on the left.
local function GroupButton(btn)
    if not btn or not SK.Once(btn) then return end
    Hide(btn.ring)
    Hide(btn.bg)
    if btn.CircleMask and btn.icon then btn.icon:RemoveMaskTexture(btn.CircleMask) end
    local hl = btn:GetHighlightTexture()
    if hl then hl:SetColorTexture(1, 1, 1, 0.08) end
    SK.Backdrop(btn, "button")
    SK.Hover(btn)
    if btn.icon then
        btn.icon:SetSize(45, 45)
        btn.icon:ClearAllPoints()
        btn.icon:SetPoint("LEFT", 10, 0)
        SK.Icon(btn.icon)
    end
end

local function RetailLFG()
    local pve = G("PVEFrame")
    if not pve then return end
    SK.Window(pve)
    HideNamed("PVEFrameBg", "PVEFrameBlueBg", "PVEFrameTLCorner", "PVEFrameTRCorner", "PVEFrameBRCorner", "PVEFrameBLCorner",
              "PVEFrameLLVert", "PVEFrameRLVert", "PVEFrameBottomLine", "PVEFrameTopLine", "PVEFrameTopFiligree",
              "PVEFrameBottomFiligree", "LFDQueueFrameBackground", "RaidFinderQueueFrameBackground",
              "LFDParentFrameRoleBackground", "RaidFinderFrameRoleBackground", "ScenarioQueueFrameBackground")
    -- Blizzard shows these again on a tab change; an alpha of 0 outlasts that.
    Hide(pve.shadows)
    SK.NumberedTabs(pve, "PVEFrameTab")

    local gf = G("GroupFinderFrame")
    if gf then
        local i = 1
        while gf["groupButton" .. i] do GroupButton(gf["groupButton" .. i]); i = i + 1 end
    end
    for _, n in ipairs({ "LFDQueueFrame", "RaidFinderQueueFrame", "LFDParentFrame", "RaidFinderFrame", "ScenarioQueueFrame" }) do
        SK.Strip(G(n))
    end
    for _, n in ipairs({ "LFDParentFrameInset", "RaidFinderFrameRoleInset", "ScenarioFinderFrameInset", "RaidFinderFrameBottomInset" }) do
        SK.Inset(G(n))
    end
    for _, r in ipairs({ "LFDQueueFrameRoleButton", "RaidFinderQueueFrameRoleButton" }) do
        for _, role in ipairs({ "Tank", "Healer", "DPS", "Leader" }) do RoleCheck(G(r .. role)) end
    end
    for _, n in ipairs({ "LFDQueueFrameRandomScrollFrameChildFrameMoneyReward",
                         "RaidFinderQueueFrameScrollFrameChildFrameMoneyReward",
                         "ScenarioQueueFrameRandomScrollFrameChildFrameMoneyReward" }) do
        RewardItem(G(n))
    end
    if LFGRewardsFrame_SetItemButton then
        hooksecurefunc("LFGRewardsFrame_SetItemButton", function(frame, _, index)
            local n = frame and frame:GetName()
            RewardItem(n and G(n .. "Item" .. index))
        end)
    end
    -- The specific-dungeon lists: a tick per row.
    local function DungeonRows(box)
        SK.EachRow(box, function(row) if row.enableButton then SK.Check(row.enableButton) end end)
    end
    if G("LFDQueueFrameSpecific") then DungeonRows(G("LFDQueueFrameSpecific").ScrollBox) end
    if G("LFDQueueFrameFollower") then DungeonRows(G("LFDQueueFrameFollower").ScrollBox) end
    if G("ScenarioQueueFrameSpecificScrollFrame") then DungeonRows(G("ScenarioQueueFrameSpecificScrollFrame")) end

    -- Premade groups.
    local list = G("LFGListFrame")
    if list then
        for _, k in ipairs({ "CategorySelection", "SearchPanel", "ApplicationViewer", "EntryCreation", "NothingAvailable" }) do
            local panel = list[k]
            if panel then
                Hide(panel.Background)
                SK.Inset(panel.Inset)
                SK.Inset(panel.ResultsInset)
            end
        end
        if LFGListCategorySelection_AddButton then
            hooksecurefunc("LFGListCategorySelection_AddButton", PaintCategory)
        end
        local search = list.SearchPanel
        if search then
            SK.Inset(search.ResultsInset)
            local ac = search.AutoCompleteFrame
            if ac then
                SK.Strip(ac)
                SK.Backdrop(ac, "panel", 0, 3, 6, 3)
            end
            if search.RefreshButton then search.RefreshButton:SetSize(24, 24) end
            if search.FilterButton and search.FilterButton.ResetButton then SK.Close(search.FilterButton.ResetButton) end
            if LFGListSearchPanel_UpdateAutoComplete then
                hooksecurefunc("LFGListSearchPanel_UpdateAutoComplete", function(panel)
                    for _, c in ipairs({ panel.AutoCompleteFrame:GetChildren() }) do
                        if c:IsObjectType("Button") then SK.Button(c) end
                    end
                end)
            end
        end
        local viewer = list.ApplicationViewer
        if viewer then
            if viewer.InfoBackground then
                SK.Backdrop(viewer.InfoBackground, "panel")
                viewer.InfoBackground:SetAlpha(0)
            end
            if viewer.Inset then SK.Inset(viewer.Inset); SK.Backdrop(viewer.Inset, "panel") end
            for _, k in ipairs({ "NameColumnHeader", "RoleColumnHeader", "ItemLevelColumnHeader", "RatingColumnHeader" }) do
                local h = viewer[k]
                if h and SK.Once(h) then
                    SK.Strip(h)
                    SK.Backdrop(h, "button")
                    SK.Hover(h)
                end
            end
            if viewer.RefreshButton then viewer.RefreshButton:SetSize(24, 24) end
        end
        local creation = list.EntryCreation
        local dialog = creation and creation.ActivityFinder and creation.ActivityFinder.Dialog
        if dialog then
            SK.Window(dialog)
            if dialog.BorderFrame then SK.Strip(dialog.BorderFrame) end
            SK.Auto(dialog)
        end
    end
    if LFGListSearchEntry_Update then
        hooksecurefunc("LFGListSearchEntry_Update", function(b) SK.Button(b.CancelButton) end)
    end
    if LFGListApplicationViewer_UpdateApplicant then
        hooksecurefunc("LFGListApplicationViewer_UpdateApplicant", function(b)
            SK.Button(b.DeclineButton)
            SK.Button(b.InviteButton)
            SK.Button(b.InviteButtonSmall)
        end)
    end

    SK.Auto(pve)
    for _, n in ipairs({ "LFGListApplicationDialog", "LFGListInviteDialog", "LFGDungeonReadyStatus",
                         "LFGListCreateRoleDialog", "RolePollPopup", "LFGInvitePopup", "ReadyStatus" }) do
        local f = G(n)
        if f then
            Hide(f.Border)
            SK.Window(f)
            SK.Auto(f)
        end
    end
    local app = G("LFGListApplicationDialog")
    if app then for _, k in ipairs({ "TankButton", "HealerButton", "DamagerButton" }) do RoleCheck(app[k]) end end
    for _, p in ipairs({ "LFGInvitePopupRoleButton", "RolePollPopupRoleButton" }) do
        for _, role in ipairs({ "Tank", "Healer", "DPS" }) do RoleCheck(G(p .. role)) end
    end
    ReadyDialog(G("LFGDungeonReadyDialog"))
    ReadyDialog(G("PVPReadyDialog"))
end

-- Forever's group finder (the classic one, with side tabs) loads on demand.
local function ForeverLFG()
    local parent = G("LFGParentFrame")
    if parent then
        SK.Window(parent)
        Hide(G("LFGParentFramePortrait"))
        local tabs = { parent.ListingTab, parent.BrowsingTab, parent.WhoListingTab }
        for _, t in ipairs(tabs) do SK.SideTab(t) end
        SK.LayoutSideTabs(parent, tabs)
    end
    local listing = G("LFGListingFrame")
    if listing then
        SK.Window(listing)
        if listing.RolesSection then SK.Strip(listing.RolesSection) end
        Hide(listing.DividerFrame)
        local view = listing.ActivityView
        if view then
            Hide(view.BarTop)
            Hide(view.BarMiddle)
            SK.ScrollBar(view.ScrollBar)
            -- Its rows: a check box per activity, the group headers collapsible.
            SK.EachRow(view.ScrollBox, function(row)
                local cb = row.CheckButton
                if cb then SK.Check(cb); cb:SetSize(28, 28) end
            end)
        end
        local comment = G("LFGListingComment")
        if comment then SK.EditBox(comment, -6, 2, 6, -2) end
        SK.Auto(listing)
        if listing.GroupRoleButtons then SK.Auto(listing.GroupRoleButtons) end
    end
    local browse = G("LFGBrowseFrame")
    if browse then
        SK.Window(browse)
        SK.ScrollBar(browse.ScrollBar)
        SK.EachRow(browse.ScrollBox, function(row)
            if not SK.Once(row) then return end
            local bg = row.ResultBG
            if bg then bg:SetAlpha(0) end
            local b = SK.Backdrop(row, row.Selected and "panel" or "button")
            if bg then b:ClearAllPoints(); b:SetAllPoints(bg) end
            if row.Highlight then row.Highlight:SetColorTexture(1, 1, 1, 0.25); row.Highlight:SetAllPoints(b) end
            if row.Selected then
                local r, g, bl = SK.AccentRGB()
                row.Selected:SetColorTexture(r, g, bl, 0.25)
                row.Selected:SetAllPoints(b)
            end
            if row.DataDisplay then SK.Button(row.DataDisplay.DelistButton) end
        end)
        local act = browse.ActivityDropdown
        if act and act.ResetButton then SK.Close(act.ResetButton) end
        if browse.RefreshButton then browse.RefreshButton:SetSize(21, 21) end
        SK.Auto(browse)
    end
    local who = G("LFGWhoListFrame")
    if who then
        SK.Window(who)
        SK.ScrollBar(who.ScrollBar)
        SK.EachRow(who.ScrollBox, function(row)
            if not SK.Once(row) then return end
            Hide(row.Background)
            local b = SK.Backdrop(row, "panel", 0, -1, 0, 1)
            SK.RowHighlights(row, b)
            SK.Button(row.InviteButton)
        end)
        local eb = who.EditBox
        if eb then SK.EditBox(eb) end
        if who.FilterDropdown and who.FilterDropdown.ResetButton then SK.Close(who.FilterDropdown.ResetButton) end
        SK.Auto(who)
    end
end

-- Popups Forever's group finder shares with the PvP queue.
local function ForeverLFGUtil()
    local inv = G("LFGInvitePopup")
    if inv then
        SK.Window(inv)
        SK.Auto(inv)
        for _, role in ipairs({ "Tank", "Healer", "DPS" }) do RoleCheck(G("LFGInvitePopupRoleButton" .. role)) end
    end
    local rs = G("ReadyStatus")
    if rs then
        SK.Window(rs)
        SK.Auto(rs)
    end
    ReadyDialog(G("PVPReadyDialog"))
end

SK.Define("lfg", function()
    if FOREVER then
        local rp = G("RolePollPopup")
        if rp then
            SK.Window(rp)
            SK.Auto(rp)
            for _, role in ipairs({ "Tank", "Healer", "DPS" }) do RoleCheck(G("RolePollPopupRoleButton" .. role)) end
        end
    else
        RetailLFG()
    end
end)
SK.DefineLate("lfg", FOREVER and "Blizzard_GroupFinder_VanillaStyle" or nil, ForeverLFG)
SK.DefineLate("lfg", FOREVER and "Blizzard_LFGUtil" or nil, ForeverLFGUtil)

-- The Mythic+ tab (retail).
SK.DefineLate("lfg", (not FOREVER) and "Blizzard_ChallengesUI" or nil, function()
    local cf = G("ChallengesFrame")
    if not cf then return end
    cf:DisableDrawLayer("BACKGROUND")
    SK.Inset(G("ChallengesFrameInset"))
    local key = G("ChallengesKeystoneFrame")
    if key then
        SK.Window(key)
        SK.Auto(key)
        if key.KeystoneSlot and key.KeystoneSlot.Texture then SK.Icon(key.KeystoneSlot.Texture) end
        if key.Reset then
            hooksecurefunc(key, "Reset", function(self)
                local r = self:GetRegions()
                if r then r:SetAlpha(0) end
                Hide(self.InstructionBackground)
                Hide(self.KeystoneSlotGlow)
                Hide(self.SlotBG)
                Hide(self.KeystoneFrame)
                Hide(self.Divider)
            end)
        end
    end
    if cf.Update then
        hooksecurefunc(cf, "Update", function(self)
            for _, icon in ipairs(self.DungeonIcons or {}) do
                if SK.Once(icon) then
                    local r = icon:GetRegions()
                    if r then r:SetAlpha(0) end
                    if icon.Icon then
                        local px = SK.Pixel(icon)
                        icon.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        icon.Icon:ClearAllPoints()
                        icon.Icon:SetPoint("TOPLEFT", px, -px)
                        icon.Icon:SetPoint("BOTTOMRIGHT", -px, px)
                    end
                    SK.Backdrop(icon, "button")
                end
            end
        end)
    end
    local notice = cf.SeasonChangeNoticeFrame
    if notice then
        SK.Window(notice)
        SK.Auto(notice)
    end
end)

-- ============================================================================
-- PvP (loads with the PvP tab)
-- ============================================================================

-- A queue choice (random battleground, arena 2v2...): a flat button, its
-- selected glow a faint gold, its reward icon squared.
local function QueueButton(bu)
    if not bu or not SK.Once(bu) then return end
    SK.Strip(bu, { [bu.SelectedTexture or 0] = true })
    SK.Backdrop(bu, "button")
    SK.Hover(bu)
    if bu.SelectedTexture then
        bu.SelectedTexture:SetColorTexture(1, 1, 0, 0.1)
        bu.SelectedTexture:SetAllPoints()
    end
    local reward = bu.Reward
    if reward then
        Hide(reward.Border)
        if reward.CircleMask and reward.Icon then reward.Icon:RemoveMaskTexture(reward.CircleMask) end
        SK.Icon(reward.Icon)
        local eb = reward.EnlistmentBonus
        if eb then
            SK.Strip(eb)
            eb:SetSize(20, 20)
            eb:ClearAllPoints()
            eb:SetPoint("TOPRIGHT", 2, 2)
            SK.Backdrop(eb, "button")
            local t = eb:CreateTexture(nil, "ARTWORK")
            t:SetPoint("TOPLEFT", 2, -2)
            t:SetPoint("BOTTOMRIGHT", -2, 2)
            t:SetTexture("Interface\\Icons\\achievement_guildperk_honorablemention_rank2")
            t:SetTexCoord(0.1, 0.9, 0.1, 0.9)
        end
    end
end

local function PvPRole(btn)
    if not btn then return end
    local cb = btn.checkButton
    if cb then
        SK.Check(cb)
        cb:SetFrameLevel(cb:GetFrameLevel() + 1)
    end
    btn:SetSize(40, 40)
    for _, k in ipairs({ "IconPulse", "EdgePulse", "shortageBorder" }) do
        if btn[k] then btn[k]:SetSize(40, 40) end
    end
end

-- A specific battleground in the list.
local function SpecificRow(row)
    if not SK.Once(row) then return end
    SK.Strip(row, { [row.SelectedTexture or 0] = true, [row.Icon or 0] = true })
    local b = SK.Backdrop(row, "button")
    local hl = row:GetHighlightTexture()
    if hl then hl:SetAlpha(1); hl:SetColorTexture(1, 1, 1, 0.1); hl:SetAllPoints(b) end
    if row.SelectedTexture then
        row.SelectedTexture:SetColorTexture(1, 1, 0, 0.1)
        row.SelectedTexture:SetAllPoints(b)
    end
    if row.Icon then
        row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.Icon:SetPoint("TOPLEFT", 5, -3)
    end
end

SK.Define("pvp", function()
    SK.Strip(G("PVPUIFrame"))
    local q = G("PVPQueueFrame")
    if q then
        local i = 1
        while q["CategoryButton" .. i] do
            local b = q["CategoryButton" .. i]
            GroupButton(b)
            Hide(b.Ring)
            Hide(b.Background)
            if b.CircleMask and b.Icon then b.Icon:RemoveMaskTexture(b.CircleMask) end
            if b.Icon then
                b.Icon:SetSize(45, 45)
                b.Icon:ClearAllPoints()
                b.Icon:SetPoint("LEFT", 10, 0)
                SK.Icon(b.Icon)
            end
            i = i + 1
        end
        local inset = q.HonorInset
        if inset then
            Hide(inset.Background)
            Hide(inset.NineSlice)
            SK.Backdrop(inset, "panel")
            local season = inset.RatedPanel and inset.RatedPanel.SeasonRewardFrame
            if season then
                Hide(season.Ring)
                if season.CircleMask and season.Icon then season.Icon:RemoveMaskTexture(season.CircleMask) end
                SK.Icon(season.Icon)
            end
        end
        local pop = q.NewSeasonPopup
        if pop then
            SK.Window(pop)
            SK.Auto(pop)
            local rf = pop.SeasonRewardFrame
            if rf then
                Hide(rf.Ring)
                if rf.CircleMask and rf.Icon then rf.Icon:RemoveMaskTexture(rf.CircleMask) end
                SK.Icon(rf.Icon)
            end
        end
    end

    local honor, conquest, training = G("HonorFrame"), G("ConquestFrame"), G("TrainingGroundsFrame")
    if honor then
        SK.Strip(honor)
        local bonus = honor.BonusFrame
        if bonus then
            SK.Strip(bonus)
            Hide(bonus.ShadowOverlay)
            Hide(bonus.WorldBattlesTexture)
            for _, k in ipairs({ "RandomBGButton", "Arena1Button", "RandomEpicBGButton", "BrawlButton", "BrawlButton2" }) do
                QueueButton(bonus[k])
            end
        end
        SK.ScrollBar(honor.SpecificScrollBar)
        SK.EachRow(honor.SpecificScrollBox, SpecificRow)
    end
    if conquest then
        SK.Strip(conquest)
        Hide(conquest.ShadowOverlay)
        for _, k in ipairs({ "RatedSoloShuffle", "RatedBGBlitz", "Arena2v2", "Arena3v3", "RatedBG" }) do
            QueueButton(conquest[k])
        end
        if conquest.Arena3v3 and conquest.Arena2v2 then
            conquest.Arena3v3:SetPoint("TOP", conquest.Arena2v2, "BOTTOM", 0, -2)
        end
    end
    if training then
        SK.Strip(training)
        local list = training.BonusTrainingGroundList
        if list then
            SK.Strip(list)
            Hide(list.ShadowOverlay)
            Hide(list.WorldBattlesTexture)
            for _, bu in ipairs(list.BonusTrainingGroundButtons or {}) do QueueButton(bu) end
        end
        local spec = training.SpecificTrainingGroundList
        if spec then
            SK.ScrollBar(spec.ScrollBar)
            SK.EachRow(spec.ScrollBox, SpecificRow)
        end
    end
    for _, n in ipairs({ "HonorFrame", "ConquestFrame", "TrainingGroundsFrame" }) do
        local f = G(n)
        if f then
            local rl = f.RoleList
            if rl then PvPRole(rl.TankIcon); PvPRole(rl.HealerIcon); PvPRole(rl.DPSIcon) end
            local bar = f.ConquestBar
            if bar then
                Hide(bar.Border)
                Hide(bar.Background)
                SK.Backdrop(bar, "panel")
                local r = bar.Reward
                if r then
                    Hide(r.Ring)
                    if r.CircleMask and r.Icon then r.Icon:RemoveMaskTexture(r.CircleMask) end
                    r:ClearAllPoints()
                    r:SetPoint("LEFT", bar, "RIGHT", 0, 0)
                    SK.Icon(r.Icon)
                end
            end
            SK.Auto(f)
        end
    end
    local storm = G("PlunderstormFrame")
    if storm then
        SK.Inset(storm.Inset)
        SK.Auto(storm)
    end
    if G("PVPUIFrame") then SK.Auto(G("PVPUIFrame")) end
    local dlg = G("PVPTalentPrestigeLevelDialog")
    if dlg then
        SK.Window(dlg)
        SK.Auto(dlg)
    end
end)
