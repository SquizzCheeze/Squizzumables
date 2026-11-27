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
        if tf.LoadSystem and tf.LoadSystem.Dropdown then SK.Dropdown(tf.LoadSystem.Dropdown) end
        for _, k in ipairs({ "ClassCurrencyDisplay", "SpecCurrencyDisplay" }) do
            local c = tf[k]
            if c then Hide(c.Border) end
        end
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

SK.Define("collections", function()
    local cj = G("CollectionsJournal")
    if not cj then return end
    SK.Window(cj)

    local toy = G("ToyBox")
    if toy then
        IconsFrame(toy.iconsFrame)
        Paging(toy.PagingFrame)
        if toy.progressBar then SK.StatusBar(toy.progressBar, 0.03, 0.6, 0.03) end
        for i = 1, 18 do CollectionButton(toy.iconsFrame and toy.iconsFrame["spellButton" .. i]) end
    end

    local heir = G("HeirloomsJournal")
    if heir then
        IconsFrame(heir.iconsFrame)
        Paging(heir.PagingFrame)
        if heir.progressBar then SK.StatusBar(heir.progressBar, 0.03, 0.6, 0.03) end
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
        HideKeys(mount, "BottomLeftInset")
        if mount.MountDisplay then
            HideKeys(mount.MountDisplay, "ShadowOverlay", "YesMountsTex", "NoMountsTex")
            SK.Backdrop(mount.MountDisplay, "panel")
        end
        if mount.MountCount then
            SK.Strip(mount.MountCount)
            SK.Backdrop(mount.MountCount, "button")
        end
        SK.Auto(mount)
    end

    local pet = G("PetJournal")
    if pet then
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
            for _, k in ipairs({ "overviewTab", "lootTab", "bossTab", "modelTab" }) do
                local tab = info[k]
                if tab and SK.Once(tab) then
                    SK.Strip(tab)
                    local nt = tab.GetNormalTexture and tab:GetNormalTexture()
                    if nt then nt:SetAlpha(0) end
                    local pt = tab.GetPushedTexture and tab:GetPushedTexture()
                    if pt then pt:SetAlpha(0) end
                    local dt = tab.GetDisabledTexture and tab:GetDisabledTexture()
                    if dt then dt:SetAlpha(0) end
                    SK.Backdrop(tab, "button", 4, -4, -4, 4)
                    SK.Hover(tab)
                end
            end
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

    for i = 1, 3 do
        local tab = G("AchievementFrameTab" .. i)
        if tab then SK.Tab(tab) end
    end
    SK.Auto(af)
end)
