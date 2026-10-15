-- Cooldowns/OptionsTab.lua
-- The CDM options pages: BuildCDMTab (the group list, Cooldown Manager
-- options, per-spec notes) and the per-group settings in sections (layout,
-- appearance, text, glows, visibility, anchoring).
--
-- Moved out of Squizzumables_CDM.lua unchanged in 2.0 phase 2 (the split),
-- which also takes 1,580 lines and a few dozen file-level locals off that
-- file's main chunk -- it was the one nearest Lua's 200-local limit. The
-- module's constants and helpers it uses come through cdmModule.shared (the
-- table that file already hands its siblings) and are re-declared below under
-- the same names, so the moved code is byte-identical.

local addonName, ns = ...
local BH = ns.BH

local CreateSQButton      = ns.CreateSQButton
local CreateSQEditBox     = ns.CreateSQEditBox
local CreateSQSlider      = ns.CreateSQSlider
local CreateSQCheckbox    = ns.CreateSQCheckbox
local CreateSQDropdown    = ns.CreateSQDropdown
local CreateSQDivider     = ns.CreateSQDivider
local CreateSQColorPicker = ns.CreateSQColorPicker

local cdmModule = BH.cdm
local shared    = cdmModule.shared

local GetSpecData              = shared.GetSpecData
local DEFAULT_ICON_SIZE        = shared.DEFAULT_ICON_SIZE
local DEFAULT_ALPHA            = shared.DEFAULT_ALPHA
local DEFAULT_BORDER_THICKNESS = shared.DEFAULT_BORDER_THICKNESS
local DEFAULT_BORDER_COLOR     = shared.DEFAULT_BORDER_COLOR
local DEFAULT_ICON_ZOOM        = shared.DEFAULT_ICON_ZOOM
local DEFAULT_BG_COLOR         = shared.DEFAULT_BG_COLOR
local DEFAULT_BAR_HEIGHT       = shared.DEFAULT_BAR_HEIGHT
local DEFAULT_BAR_WIDTH        = shared.DEFAULT_BAR_WIDTH
local DEFAULT_GROW_DIRECTION   = shared.DEFAULT_GROW_DIRECTION
local DEFAULT_ORIENTATION      = shared.DEFAULT_ORIENTATION
local DEFAULT_PER_ROW          = shared.DEFAULT_PER_ROW
local DEFAULT_SORT             = shared.DEFAULT_SORT
local DEFAULT_SPACING          = shared.DEFAULT_SPACING
local BUILTIN_GROUPS           = shared.BUILTIN_GROUPS
local BUILTIN_FOR_VIEWERTYPE   = shared.BUILTIN_FOR_VIEWERTYPE
local ICON_SHAPES              = shared.ICON_SHAPES
local TEXT_POSITION_ITEMS      = shared.TEXT_POSITION_ITEMS
local ActiveGlowColor          = shared.ActiveGlowColor
local ProcGlowColor            = shared.ProcGlowColor

-- ============================================================================
-- Settings Tab â€” BuildCDMTab (called from Squizzumables.lua)
-- ============================================================================

-- Colours come from the theme (UI/Theme.lua, 2.0). These pages are rebuilt
-- often, so headings take ns.GetAccentColor() as they are drawn rather than
-- registering with ns.ApplyAccent, which would grow its registry on every
-- rebuild. Until 2.0 they used a private gold (0.87, 0.73, 0.37) that ignored
-- the class-colour accent; they now match the rest of the window.


-- Reference to the currently displayed group editor (for refresh)
-- Two pages share one builder.
--
--   "manager" -- the Cooldown Manager proper: the master switch and the three
--                built-in groups (Essential, Utility, Buffs) with their styling.
--   "custom"  -- custom cooldown icons: making your own groups, and assigning
--                individual spells into them or setting them loose.
--
-- Split because they are different jobs. Styling the three standard groups is
-- what most people want and was buried under a group-creation form and a long
-- list of every spell; making custom groups is a deliberate, occasional thing.
-- Parameterised rather than copied so the group section, the reconcile hooks
-- and the refresh path stay single-sourced.
local cdmTabState = {}
local cdmCustomTabState = {}

-- Which inner tab each group page was last showing, keyed by group name.
--
-- Kept out here rather than on the widget because ClearCDMPage reparents every
-- child of a page away on each rebuild, and a rebuild happens every time any
-- setting on it changes. Without this the tab would snap back to Layout the
-- instant you ticked anything, which reads as the panel fighting you.
local cdmGroupTab = {}

local function BuildCDMScroller(parent, state)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    ns.TuneScrollStep(scrollFrame)
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    state.content = content
    state.scrollFrame = scrollFrame
    state.parent = parent
end

-- Empty a page for a rebuild: its frames and its bare regions (headers and
-- dividers are font strings and textures straight on the page).
local function ClearCDMPage(page)
    for _, child in pairs({ page:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in pairs({ page:GetRegions() }) do
        region:Hide()
        region:SetParent(nil)
    end
end

-- The manager page's sub-tabs: General for the module switches, then one per
-- built-in group in their declared order, keyed by group name so the rebuild
-- can find each group's page.
--
-- The page used to be the switches with every group's full styling stacked
-- underneath -- several screens of scrolling to reach Buffs, and more again
-- for Buff Bars once that group existed.
local CDM_SUBTAB_DEFS = { { key = "general", label = "General" } }
for _, b in ipairs(BUILTIN_GROUPS) do
    CDM_SUBTAB_DEFS[#CDM_SUBTAB_DEFS + 1] = { key = b.name, label = b.name }
end

function BH:BuildCDMTab(parent)
    -- Sub-tabs rather than one scroller; see CDM_SUBTAB_DEFS. General is the
    -- page everything that is not a group still builds into.
    local pages = ns.SubTabs.Create(parent, CDM_SUBTAB_DEFS)
    cdmTabState.pages = pages
    cdmTabState.content = pages.general
    cdmTabState.parent = parent
    -- A 1:1 preview pinned above each group's settings (UI/CDMPreview.lua).
    -- Once, here: the pane lives on the tab, not on the page content the
    -- rebuild below clears.
    if ns.CDMPreview then
        for _, b in ipairs(BUILTIN_GROUPS) do
            ns.CDMPreview.AttachToSubTab(pages[b.name], b.name)
        end
    end
    self:RebuildCDMTabContent()
end

function BH:BuildCustomCooldownsTab(parent)
    BuildCDMScroller(parent, cdmCustomTabState)
    self:RebuildCDMTabContent()
end

-- Rebuilds whichever pages have been built. Callers throughout the module just
-- say "refresh the CDM settings" and should not have to know which tab the
-- player is looking at.
function BH:RebuildCDMTabContent()
    self:RebuildCDMPage(cdmTabState, "manager")
    self:RebuildCDMPage(cdmCustomTabState, "custom")
end

function BH:RebuildCDMPage(state, mode)
    local content = state.content
    if not content then return end
    ClearCDMPage(content)

    -- The manager page's per-group sub-tabs, rebuilt along with it. The pages
    -- themselves are kept, so the sub-tab you are on stays selected when a
    -- setting change rebuilds everything.
    local groupPages = (mode ~= "custom") and state.pages or nil
    if groupPages then
        for _, b in ipairs(BUILTIN_GROUPS) do
            if groupPages[b.name] then ClearCDMPage(groupPages[b.name]) end
        end
    end

    -- Search files each row under the sub-tab it sits on, so a result can bring
    -- that sub-tab forward -- otherwise it lands on the right page with the row
    -- hidden behind an unselected sub-tab. Only the panel's first build pass is
    -- indexed at all; restored before every return.
    local prevSection = ns.Rows.currentSection
    if groupPages then ns.Rows.currentSection = content.section end

    local leftPad = 14
    local yOffset = -14

    -- ===== HEADER =====
    local header = content:CreateFontString(nil, "OVERLAY")
    header:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    header:SetTextColor(ns.GetAccentColor())
    header:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    header:SetText(mode == "custom" and "CUSTOM COOLDOWN ICONS" or "COOLDOWN MANAGER")
    yOffset = yOffset - 16

    -- Spec profile info note
    local specNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    specNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    specNote:SetWidth(380)
    specNote:SetJustifyH("LEFT")
    local _, specName = GetSpecializationInfo(GetSpecialization() or 1)
    local _, className = UnitClass("player")
    specNote:SetText("Spec profile: " .. (className or "?") .. " - " .. (specName or "?") .. " (shared across all characters)")
    specNote:SetTextColor(ns.Theme.RGBA("textDim"))
    yOffset = yOffset - 20

    -- ===== ENABLE CHECKBOX =====
    -- Master switch, on the manager page only. It governs both pages, and two
    -- copies of one setting on two tabs is how they end up disagreeing.
    if mode ~= "custom" then
        local enableCB = CreateSQCheckbox(content, "Enable Cooldown Manager", function(checked)
            BH.settings.cdmEnabled = checked
            BH:SaveSettings()
            if checked then
                BH.cdm:Initialize()
            else
                BH.cdm:ReleaseAll()
            end
            -- Refresh the tab content to show/hide sections
            C_Timer.After(0.1, function() BH:RebuildCDMTabContent() end)
        end)
        enableCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        ns.Rows.AddTooltip(enableCB, "Enable Cooldown Manager", "Master switch for the Cooldown Manager proxy. It mirrors Blizzard's Cooldown Viewer into its own icons without touching Blizzard's frames, so it stays taint-free.")
        enableCB:SetChecked(BH.settings and BH.settings.cdmEnabled)
        yOffset = yOffset - 24

        local hideBlizzCB = CreateSQCheckbox(content, "Hide Blizzard's Cooldown Manager", function(checked)
            BH.settings.cdmHideBlizzard = checked
            BH:SaveSettings()
            BH.cdm:ApplyBlizzardVisibility()
        end)
        hideBlizzCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        ns.Rows.AddTooltip(hideBlizzCB, "Hide Blizzard's Cooldown Manager",
            "Fade out Blizzard's own cooldown bars so only these icons show. They are faded rather than hidden, "
         .. "on purpose: this addon reads live buff state from those frames, and the game stops updating a frame "
         .. "once it is hidden. Unticking brings them straight back, as does switching the Cooldown Manager off.")
        hideBlizzCB:SetChecked(BH.settings and BH.settings.cdmHideBlizzard)
        yOffset = yOffset - 24

        local followCB = CreateSQCheckbox(content, "Keep Blizzard's frames on our groups", function(checked)
            BH.settings.cdmViewersFollowGroups = checked
            BH:SaveSettings()
            BH.cdm:ApplyBlizzardVisibility()
        end)
        followCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        ns.Rows.AddTooltip(followCB, "Keep Blizzard's frames on our groups",
            "Parks each hidden Blizzard bar invisibly on top of the group that replaced it, instead of "
         .. "throwing it off screen.\n\nOnly matters if another addon anchors to EssentialCooldownViewer "
         .. "or one of its siblings: with this on those frames stay where the icons actually are, so such "
         .. "an anchor still lands correctly. Off, they go off screen and anything anchored to them goes too.")
        followCB:SetChecked(BH.settings and BH.settings.cdmViewersFollowGroups ~= false)
        yOffset = yOffset - 24

        local nativeCB = CreateSQCheckbox(content, "Draw Buffs Ourselves", function(checked)
            BH.settings.cdmNativeBuffs = checked
            BH:SaveSettings()
            BH.cdm:ScheduleReconcile()
        end)
        nativeCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        ns.Rows.AddTooltip(nativeCB, "Draw Buffs Ourselves",
            "Draw tracked buffs and buff bars as this addon's own icons and bars, so each group's border, "
         .. "zoom, shape, background and text settings apply to them. The game fills in the sweep, stacks "
         .. "and timer itself, so they keep working in combat.\n\nUntick to go back to borrowing Blizzard's "
         .. "own buff frames, which keep Blizzard's look. Totem-style entries that are not real auras always "
         .. "use Blizzard's frame.")
        nativeCB:SetChecked(BH.settings and BH.settings.cdmNativeBuffs ~= false)
        yOffset = yOffset - 28
    end

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    desc:SetWidth(380)
    desc:SetJustifyH("LEFT")
    desc:SetText(mode == "custom"
        and "Make your own groups and choose which spells go in them. Anything you do not assign stays in one of the three standard groups on the Cooldowns tab."
        or "Essential, Utility, Buffs and Buff Bars mirror Blizzard's own Cooldown Manager categories and fill themselves. Style each one on its own tab above. Requires the Cooldown Manager to be enabled in Edit Mode.")
    desc:SetTextColor(ns.Theme.RGBA("textDim"))
    yOffset = yOffset - 42

    if not (BH.settings and BH.settings.cdmEnabled) then
        content:SetHeight(math.abs(yOffset) + 20)
        -- A group tab with nothing on it would read as broken, so say why.
        if groupPages then
            for _, b in ipairs(BUILTIN_GROUPS) do
                local page = groupPages[b.name]
                if page then
                    local note = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    note:SetPoint("TOPLEFT", page, "TOPLEFT", leftPad, -14)
                    note:SetWidth(380)
                    note:SetJustifyH("LEFT")
                    note:SetText("Turn on the Cooldown Manager on the General tab to style this group.")
                    note:SetTextColor(ns.Theme.RGBA("textDim"))
                    page:SetHeight(60)
                end
            end
        end
        ns.Rows.currentSection = prevSection
        return
    end

    -- ===== DIVIDER =====
    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- ===== CREATE GROUP SECTION =====
    -- Custom page only. This form is the reason the manager page used to open
    -- on a name box instead of the groups the player actually wanted to style.
    if mode == "custom" then
    local groupHeader = content:CreateFontString(nil, "OVERLAY")
    groupHeader:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    groupHeader:SetTextColor(ns.GetAccentColor())
    groupHeader:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    groupHeader:SetText("GROUPS")
    yOffset = yOffset - 22

    -- New Group input row.
    --
    -- This used to be a hand-rolled backdrop frame with a borderless EditBox
    -- floated inside it, repeating the kit's control/border colours as literals.
    -- CreateSQEditBox draws exactly that, so it is one widget now and picks up
    -- the focus highlight the rest of the panel has.
    local inputBox = CreateSQEditBox(content, 220, 24, {
        maxLetters = 20, fontObject = GameFontNormal,
    })
    inputBox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)

    -- Placeholder text
    local placeholder = inputBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    placeholder:SetPoint("LEFT", inputBox, "LEFT", 6, 0)
    placeholder:SetText("Group name...")
    do
        local r, g, b = ns.Theme.RGBA("textDim")
        placeholder:SetTextColor(r, g, b, 0.6)
    end

    inputBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then
            placeholder:Hide()
        else
            placeholder:Show()
        end
    end)

    local addBtn = CreateSQButton(content, "Create", 80, 24)
    addBtn:SetPoint("LEFT", inputBox, "RIGHT", 6, 0)
    addBtn:SetScript("OnClick", function()
        local name = strtrim(inputBox:GetText())
        if name == "" then return end
        -- Sanitize: only alphanumeric and spaces
        name = name:gsub("[^%w ]", "")
        if name == "" then return end
        BH.cdm:CreateGroup(name)
        inputBox:SetText("")
        inputBox:ClearFocus()
        C_Timer.After(0.1, function() BH:RebuildCDMTabContent() end)
    end)
    inputBox:SetScript("OnEnterPressed", function(self)
        addBtn:GetScript("OnClick")()
    end)

    yOffset = yOffset - 34
    end -- mode == "custom"

    -- ===== LIST EXISTING GROUPS =====
    --
    -- Custom Icons (V1.89): each group is laid out like the CDM tab's groups --
    -- sub-tabs for Layout / Appearance / Text / ... -- instead of one long
    -- stack of every section. A tabbed group's height follows its selected
    -- sub-tab, so it cannot sit at a fixed running offset: each group gets its
    -- own host frame, stacked under the one before, and everything below the
    -- groups moves into a tail frame that follows the last of them. The page
    -- height is recomputed whenever a host changes size.
    local pageContent = content
    local customHosts = {}
    local customTop
    local customTail
    local GROUP_GAP = 8
    local function ResizeCustomPage()
        local h = math.abs(customTop or 0)
        for _, host in ipairs(customHosts) do
            h = h + (host:GetHeight() or 0) + GROUP_GAP
        end
        if customTail then h = h + (customTail:GetHeight() or 0) end
        pageContent:SetHeight(h + 20)
    end

    local specData = GetSpecData()
    if specData then
        -- Also here, not just in reconcile: reconcile returns early when the
        -- Cooldown Manager is switched off, and someone opening this tab to
        -- turn it on should still find the three groups waiting rather than an
        -- empty page.
        BH.cdm:EnsureBuiltinGroups(specData)

        -- Each page lists only its own kind: the manager page shows the three
        -- built-ins in their declared order, the custom page shows everything
        -- else, alphabetically. pairs() alone gave an order that changed
        -- between openings, so a group moved around the page on every rebuild.
        local ordered = {}
        if mode == "custom" then
            local builtin = {}
            for _, b in ipairs(BUILTIN_GROUPS) do builtin[b.name] = true end
            for groupName, gd in pairs(specData.groups) do
                if not builtin[groupName] and not gd.builtin then
                    ordered[#ordered + 1] = groupName
                end
            end
            table.sort(ordered)
        else
            for _, b in ipairs(BUILTIN_GROUPS) do
                if specData.groups[b.name] then ordered[#ordered + 1] = b.name end
            end
        end

        if #ordered == 0 and mode == "custom" then
            local none = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            none:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            none:SetWidth(380)
            none:SetJustifyH("LEFT")
            none:SetText("No custom groups yet. Create one above, then assign spells to it below.")
            none:SetTextColor(ns.Theme.RGBA("textDim"))
            yOffset = yOffset - 24
        end

        for _, groupName in ipairs(ordered) do
            local page = groupPages and groupPages[groupName]
            if page then
                -- On its own sub-tab, from the top of that page.
                if page.section then ns.Rows.currentSection = page.section end
                -- Tabbed, and the page height is the widget's business from
                -- here: it sizes the page to whichever section is showing, so
                -- setting it again from a returned offset would fight that and
                -- cut the taller sections off.
                self:BuildGroupSection(page, leftPad, -14,
                    groupName, specData.groups[groupName], specData, true)
                ns.Rows.currentSection = content.section
            else
                local prev = customHosts[#customHosts]
                local host = CreateFrame("Frame", nil, pageContent)
                host.section = pageContent.section
                if prev then
                    host:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -GROUP_GAP)
                    host:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -GROUP_GAP)
                else
                    customTop = yOffset
                    host:SetPoint("TOPLEFT", pageContent, "TOPLEFT", 0, yOffset)
                    host:SetPoint("TOPRIGHT", pageContent, "TOPRIGHT", 0, yOffset)
                end
                host:SetHeight(1)
                customHosts[#customHosts + 1] = host
                -- Tabbed, with the preview under the heading. The inline
                -- sub-tabs size the host to whichever section is showing.
                self:BuildGroupSection(host, leftPad, 0,
                    groupName, specData.groups[groupName], specData, true, true)
                host:SetScript("OnSizeChanged", ResizeCustomPage)
            end
        end
    end

    -- Everything after the groups on Custom Icons is built into a tail that
    -- follows the last group, so a group switching sub-tab moves it instead of
    -- running over it. From here on `content` IS that tail and yOffset counts
    -- from its top; the page's own height is ResizeCustomPage's job.
    if #customHosts > 0 then
        local last = customHosts[#customHosts]
        customTail = CreateFrame("Frame", nil, pageContent)
        customTail.section = pageContent.section
        customTail:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -GROUP_GAP)
        customTail:SetPoint("TOPRIGHT", last, "BOTTOMRIGHT", 0, -GROUP_GAP)
        customTail:SetHeight(1)
        customTail:SetScript("OnSizeChanged", ResizeCustomPage)
        content = customTail
        yOffset = 0
    end

    -- ===== DIVIDER =====
    -- Not on the manager's General tab: the groups are on their own tabs now,
    -- so this would sit directly under the divider above.
    if not groupPages then
        CreateSQDivider(content, yOffset)
        yOffset = yOffset - 14
    end

    -- ===== UNASSIGNED COOLDOWNS =====
    -- Custom page only. This is the long per-spell list, and it is only
    -- meaningful when there is somewhere custom to move a spell to.
    if mode == "custom" then
    local unassignedHeader = content:CreateFontString(nil, "OVERLAY")
    unassignedHeader:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    unassignedHeader:SetTextColor(ns.GetAccentColor())
    unassignedHeader:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    unassignedHeader:SetText("AVAILABLE COOLDOWNS")
    yOffset = yOffset - 22

    local availDesc = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    availDesc:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    availDesc:SetWidth(380)
    availDesc:SetJustifyH("LEFT")
    availDesc:SetText("Assign cooldowns to a group or set as Free to position independently. Also in shows a spell in a second group as well.")
    availDesc:SetTextColor(ns.Theme.RGBA("textDim"))
    yOffset = yOffset - 34 -- two lines

    local cooldowns = BH.cdm:GetAvailableCooldowns()

    -- Group by category
    local categories = {
        { key = "cooldown", label = "ESSENTIAL" },
        { key = "utility",  label = "UTILITY" },
    }
    local byCat = {}
    for _, cat in ipairs(categories) do byCat[cat.key] = {} end
    for cdID, cdInfo in pairs(cooldowns) do
        local cat = cdInfo.viewerType or "cooldown"
        if not byCat[cat] then byCat[cat] = {} end
        table.insert(byCat[cat], cdInfo)
    end
    for _, list in pairs(byCat) do
        table.sort(list, function(a, b) return a.name < b.name end)
    end

    -- Build dropdown items for groups
    local groupItems = { { text = "-- Unassigned --", value = "__NONE__" }, { text = "Free Position", value = "__FREE__" } }
    if specData then
        for gName, _ in pairs(specData.groups) do
            table.insert(groupItems, { text = gName, value = gName })
        end
    end

    local totalCDs = 0
    for _, cat in ipairs(categories) do
        local list = byCat[cat.key]
        if list and #list > 0 then
            totalCDs = totalCDs + #list

            -- Category sub-header
            local catLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            catLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
            catLabel:SetText(cat.label)
            catLabel:SetTextColor(ns.GetAccentColor())
            yOffset = yOffset - 18

            for _, cdInfo in ipairs(list) do
                local row = CreateFrame("Frame", nil, content)
                row:SetSize(380, 36)
                row:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)

                local currentAssignment = specData and specData.assignments[cdInfo.cooldownID]
                local dd = CreateSQDropdown(row, "", 150, groupItems, function(val)
                    if val == "__NONE__" then
                        BH.cdm:UnassignCooldown(cdInfo.cooldownID)
                    elseif val == "__FREE__" then
                        BH.cdm:AssignFree(cdInfo.cooldownID)
                    else
                        BH.cdm:AssignToGroup(cdInfo.cooldownID, val)
                    end
                end)
                dd:SetPoint("TOPLEFT", row, "TOPLEFT", 192, 0)

                -- Icon
                if cdInfo.icon then
                    local icon = row:CreateTexture(nil, "ARTWORK")
                    icon:SetSize(22, 22)
                    icon:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -7)
                    icon:SetTexture(cdInfo.icon)
                    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                end

                -- Spell name
                local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 28, -11)
                nameText:SetWidth(160)
                nameText:SetJustifyH("LEFT")
                nameText:SetText(cdInfo.name)
                nameText:SetTextColor(ns.Theme.RGBA("text"))

                if currentAssignment == "FREE" then
                    dd:SetSelectedValue("__FREE__")
                elseif currentAssignment then
                    dd:SetSelectedValue(currentAssignment)
                else
                    dd:SetSelectedValue("__NONE__")
                end

                -- "Also in": a second icon for this spell in another group
                -- (cdmModule:SetCopy). Offered every group but the one it is
                -- assigned to; the original keeps Show While Active.
                local copyItems = { { text = "None", value = "__NONE__" } }
                if specData then
                    for gName, _ in pairs(specData.groups) do
                        if gName ~= currentAssignment then
                            table.insert(copyItems, { text = gName, value = gName })
                        end
                    end
                end
                local alsoLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                alsoLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 28, -40)
                alsoLabel:SetText("Also in:")
                alsoLabel:SetTextColor(ns.Theme.RGBA("textDim"))
                local copyDD = CreateSQDropdown(row, "", 150, copyItems, function(val)
                    BH.cdm:SetCopy(cdInfo.cooldownID, val ~= "__NONE__" and val or nil)
                end)
                copyDD:SetPoint("TOPLEFT", row, "TOPLEFT", 192, -28)
                local currentCopy = specData and specData.copies and specData.copies[cdInfo.cooldownID]
                copyDD:SetSelectedValue(currentCopy or "__NONE__")
                row:SetHeight(60)

                yOffset = yOffset - 62
            end

            yOffset = yOffset - 4
        end
    end

    if totalCDs == 0 then
        local noneText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        noneText:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        noneText:SetWidth(380)
        noneText:SetJustifyH("LEFT")
        noneText:SetText("No cooldowns found. Enable the Cooldown Manager in Edit Mode and ensure you have known abilities.")
        noneText:SetTextColor(ns.Theme.RGBA("textDim"))
        yOffset = yOffset - 22
    end
    end -- mode == "custom"

    -- ===== DIVIDER =====
    if not groupPages then
        yOffset = yOffset - 6
        CreateSQDivider(content, yOffset)
        yOffset = yOffset - 14
    end

    -- ===== REFRESH BUTTON =====
    local refreshBtn = CreateSQButton(content, "Refresh Cooldowns", 160, 26)
    refreshBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    refreshBtn:SetScript("OnClick", function()
        -- force: an explicit press must not be swallowed by a pending pass.
        BH.cdm:ScheduleReconcile(0, true)
        C_Timer.After(0.3, function() BH:RebuildCDMTabContent() end)
    end)
    yOffset = yOffset - 40

    content:SetHeight(math.abs(yOffset) + 20)
    -- On Custom Icons `content` is the tail by now, so the page itself is
    -- sized from the stacked groups plus the tail. Called directly as well as
    -- from OnSizeChanged, which a frame not yet shown may not fire.
    if customTail then ResizeCustomPage() end
    ns.Rows.currentSection = prevSection
end

-- ============================================================================
-- Group settings, in sections
-- ============================================================================
--
-- One group used to be ~50 controls in a single column: every sizing, colour,
-- text, glow and visibility option stacked end to end. Everything worked --
-- nothing here was dead -- but finding any one of them meant scrolling past
-- forty others, which is indistinguishable from the settings being broken.
--
-- So each group page carries its own strip of sections. The builders below are
-- the sections; each takes the running yOffset and returns it, so the SAME
-- code serves both layouts: a group with a page to itself gets tabs, while the
-- Custom Cooldowns tab -- which stacks several groups in one scroller, where
-- tabs per group would be worse than the column ever was -- gets them one
-- after another under headings.

-- A heading, for the stacked layout only. On a tabbed page the tab is the
-- heading, and a second copy of the same word under it is just noise.
local function SectionHeading(content, indent, yOffset, text)
    local fs = content:CreateFontString(nil, "OVERLAY")
    fs:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    fs:SetTextColor(ns.GetAccentColor())
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    fs:SetText(text:upper())
    return yOffset - 18
end

-- Position, offset X and offset Y for one piece of icon text. One helper for
-- all three, so the charge number, the countdown and the keybind behave
-- identically rather than drifting apart.
local function AddTextPlacement(content, indent, yOffset, groupData,
                                label, posKey, oxKey, oyKey, defPos, defX, defY, tip)
    local dd = CreateSQDropdown(content, label .. " Position", 160, TEXT_POSITION_ITEMS, function(val)
        groupData[posKey] = val
        BH.cdm:ScheduleReconcile()
    end)
    dd:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    dd:SetSelectedValue(groupData[posKey] or defPos)
    ns.Rows.AddTooltip(dd, label .. " Position", tip)
    yOffset = yOffset - 50

    local sx = CreateSQSlider(content, label .. " Offset X", 220, -30, 30, 1)
    sx:SetValue(groupData[oxKey] or defX)
    sx:SetAfterValueChanged(function(v) groupData[oxKey] = v; BH.cdm:ScheduleReconcile() end)
    sx:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(sx, label .. " Offset X", "Nudge it sideways from that position.")
    yOffset = yOffset - 46

    local sy = CreateSQSlider(content, label .. " Offset Y", 220, -30, 30, 1)
    sy:SetValue(groupData[oyKey] or defY)
    sy:SetAfterValueChanged(function(v) groupData[oyKey] = v; BH.cdm:ScheduleReconcile() end)
    sy:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(sy, label .. " Offset Y", "Nudge it up or down from that position.")
    return yOffset - 46
end

-- ---------------------------------------------------------------------------
-- Layout: where the group sits, how big it is, and how it grows.
-- ---------------------------------------------------------------------------
local function BuildGroupLayoutSection(content, indent, yOffset, groupName, groupData, specData)
    -- A bar group is sized in two dimensions, so it gets width and height where
    -- an icon group gets one square Icon Size. Same slot on the page either way.
    local isBarGroup = groupData.isBarGroup and true or false
    if isBarGroup then
        local widthSlider = CreateSQSlider(content, "Bar Width", 170, 60, 400, 5)
        widthSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(widthSlider, "Bar Width", "How wide each tracked buff bar is, in pixels.")
        widthSlider:SetValue(groupData.barWidth or DEFAULT_BAR_WIDTH)
        widthSlider:SetAfterValueChanged(function(value)
            groupData.barWidth = value
            BH.cdm:ScheduleReconcile()
        end)
    else
        local sizeSlider = CreateSQSlider(content, "Icon Size", 170, 20, 80, 2)
        sizeSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(sizeSlider, "Icon Size", "Width and height of each cooldown icon in this group, in pixels.")
        sizeSlider:SetValue(groupData.iconSize or DEFAULT_ICON_SIZE)
        sizeSlider:SetAfterValueChanged(function(value)
            groupData.iconSize = value
            BH.cdm:ScheduleReconcile()
        end)
    end

    -- Goes NEGATIVE, which overlaps the icons rather than spacing them.
    --
    -- A shape does not fill its icon's square: the shield is 100 wide by 118
    -- tall and is fitted by its height, so about 7.5% of the icon's width is
    -- empty on each side and two neighbours stand that far apart even at zero.
    -- That gap is the art, not the spacing, so no positive value could ever
    -- close it (user report, shield row at spacing 0). Pulling the squares
    -- into each other is what makes shaped icons touch.
    local spacingSlider = CreateSQSlider(content, "Spacing", 170, -20, 20, 1)
    spacingSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(spacingSlider, "Spacing",
        "Gap between icons in this group, in pixels. Negative values overlap "
        .. "them, which is how shaped icons -- the shield especially -- are "
        .. "brought together: a shape leaves empty space inside its own icon, "
        .. "so at 0 there is still a visible gap.")
    spacingSlider:SetValue(groupData.spacing or DEFAULT_SPACING)
    spacingSlider:SetAfterValueChanged(function(value)
        groupData.spacing = value
        BH.cdm:ScheduleReconcile()
    end)
    yOffset = yOffset - 50

    -- Bars always stack one per row -- that is how Blizzard draws them and how
    -- a name and a timer stay readable -- so Per Row has nothing to say here and
    -- the slot goes to the bar's other dimension instead.
    if isBarGroup then
        local heightSlider = CreateSQSlider(content, "Bar Height", 170, 8, 48, 1)
        heightSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(heightSlider, "Bar Height", "How tall each tracked buff bar is, in pixels.")
        heightSlider:SetValue(groupData.barHeight or DEFAULT_BAR_HEIGHT)
        heightSlider:SetAfterValueChanged(function(value)
            groupData.barHeight = value
            BH.cdm:ScheduleReconcile()
        end)
    else
        local rowSlider = CreateSQSlider(content, "Per Row", 170, 1, 20, 1)
        rowSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(rowSlider, "Per Row", "How many icons before wrapping to the next row or column.")
        rowSlider:SetValue(groupData.perRow or DEFAULT_PER_ROW)
        rowSlider:SetAfterValueChanged(function(value)
            groupData.perRow = value
            BH.cdm:ScheduleReconcile()
        end)
    end

    local alphaSlider = CreateSQSlider(content, "Opacity", 170, 10, 100, 5)
    alphaSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(alphaSlider, "Opacity", "Transparency of this group of icons.")
    alphaSlider:SetValue(math.floor((groupData.alpha or DEFAULT_ALPHA) * 100))
    alphaSlider:SetAfterValueChanged(function(value)
        groupData.alpha = value / 100
        BH.cdm:ScheduleReconcile()
    end)
    yOffset = yOffset - 50

    local orientItems = {
        { text = "Horizontal", value = "horizontal" },
        { text = "Vertical",   value = "vertical" },
    }
    local orientDD = CreateSQDropdown(content, "Orientation", 170, orientItems, function(val)
        groupData.orientation = val
        BH.cdm:ScheduleReconcile()
    end)
    orientDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(orientDD, "Orientation", "Whether this group lays out horizontally or vertically.")
    orientDD:SetSelectedValue(groupData.orientation or DEFAULT_ORIENTATION)

    local growItems = {
        { text = "Right & Down", value = "rightdown" },
        { text = "Left & Down",  value = "leftdown" },
        { text = "Right & Up",   value = "rightup" },
        { text = "Left & Up",    value = "leftup" },
        { text = "Centered & Down", value = "centereddown" },
        { text = "Centered & Up",   value = "centeredup" },
    }
    local growDD = CreateSQDropdown(content, "Growth", 170, growItems, function(val)
        groupData.growDirection = val
        BH.cdm:ScheduleReconcile()
    end)
    growDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(growDD, "Growth", "Which way the group extends from its anchor as icons are added.")
    growDD:SetSelectedValue(groupData.growDirection or DEFAULT_GROW_DIRECTION)
    yOffset = yOffset - 50

    local sortItems = {
        { text = "Assignment Order", value = "assignment" },
        { text = "Spell Name",      value = "name" },
        { text = "Cooldown Left",    value = "cooldown" },
    }
    local sortDD = CreateSQDropdown(content, "Sort By", 170, sortItems, function(val)
        groupData.sortBy = val
        BH.cdm:ScheduleReconcile()
    end)
    sortDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(sortDD, "Sort By", "Order the icons within this group.")
    sortDD:SetSelectedValue(groupData.sortBy or DEFAULT_SORT)
    yOffset = yOffset - 50

    local lockCB = CreateSQCheckbox(content, "Lock (click-through)", function(checked)
        groupData.locked = checked
        local group = BH.cdm.groups[groupName]
        if group and group.container then
            group.container:EnableMouse(not checked)
            -- Keep proxies mouse-enabled for tooltips; use pass-through buttons for click-through
            for _, proxy in pairs(group.members or {}) do
                proxy:EnableMouse(true)
                if checked then
                    proxy:SetPassThroughButtons("LeftButton", "RightButton", "MiddleButton", "Button4", "Button5")
                else
                    proxy:SetPassThroughButtons()
                end
            end
        end
    end)
    lockCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(lockCB, "Lock (click-through)", "Stops the group being dragged and lets mouse clicks pass through to whatever is behind it. Tooltips still work.")
    lockCB:SetChecked(groupData.locked)
    yOffset = yOffset - 32

    -- Anchor this group to another, so a stack of bars can be positioned by
    -- moving only the one at the top of the chain.
    local anchorItems = { { text = "Screen (free)", value = "" } }
    for otherName in pairs(specData.groups) do
        if otherName ~= groupName then
            anchorItems[#anchorItems + 1] = { text = otherName, value = otherName }
        end
    end
    table.sort(anchorItems, function(a, b) return a.value < b.value end)

    -- Other addons' frames, after the groups: the curated list where the frame
    -- exists, and whatever frame the group is set to now even when it is not
    -- on that list (typed into the Frame Name box below) or not loaded yet.
    local function BuildExternalItems(items)
        local listed = {}
        for _, e in ipairs(cdmModule.EXTERNAL_ANCHORS) do
            if cdmModule.ResolveExternalAnchor(e.frame) then
                items[#items + 1] = { text = e.text, value = "frame:" .. e.frame }
                listed["frame:" .. e.frame] = true
            end
        end
        local cur = groupData.anchorTo
        if type(cur) == "string" and cur:match("^frame:") and not listed[cur] then
            items[#items + 1] = { text = "Frame: " .. cur:sub(7), value = cur }
        end
        return items
    end
    BuildExternalItems(anchorItems)

    local anchorDD = CreateSQDropdown(content, "Anchor To", 160, anchorItems, function(val)
        groupData.anchorTo = val
        BH.cdm:ScheduleReconcile()
    end)
    anchorDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    anchorDD:SetSelectedValue(groupData.anchorTo or "")
    ns.Rows.AddTooltip(anchorDD, "Anchor To",
        "Attach this group to another one, or to another addon's frame (a SquizzFrames "
     .. "cast bar, say), so moving that moves this with it. "
     .. "An anchored group cannot be dragged -- it is positioned by whatever it follows. "
     .. "Anchoring two groups to each other is ignored rather than allowed to break the layout.")

    local sideItems = {
        { text = "Below", value = "below" },
        { text = "Above", value = "above" },
        { text = "Left",  value = "left"  },
        { text = "Right", value = "right" },
    }
    local sideDD = CreateSQDropdown(content, "Side", 110, sideItems, function(val)
        groupData.anchorPoint = val
        BH.cdm:ScheduleReconcile()
    end)
    sideDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    sideDD:SetSelectedValue(groupData.anchorPoint or "below")
    ns.Rows.AddTooltip(sideDD, "Side", "Which side of the anchor group this one sits on.")
    yOffset = yOffset - 50

    -- Any other addon's frame, by its global name. The dropdown only offers
    -- frames we know about; this takes the rest.
    local nameLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    nameLabel:SetText("Or anchor to a frame by name")
    local nameBox = CreateSQEditBox(content, 220, 20, { maxLetters = 128 })
    nameBox:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset - 16)
    local nameStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameStatus:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
    nameStatus:SetTextColor(ns.Theme.RGBA("textDim"))
    nameBox:SetScript("OnEnterPressed", function(self)
        local name = strtrim(self:GetText() or "")
        self:ClearFocus()
        if name == "" then return end
        if not cdmModule.ResolveExternalAnchor(name) then
            nameStatus:SetText("No frame called " .. name)
            return
        end
        groupData.anchorTo = "frame:" .. name
        local items = { { text = "Screen (free)", value = "" } }
        for otherName in pairs(specData.groups) do
            if otherName ~= groupName then
                items[#items + 1] = { text = otherName, value = otherName }
            end
        end
        table.sort(items, function(a, b) return a.value < b.value end)
        anchorDD:SetItems(BuildExternalItems(items))
        anchorDD:SetSelectedValue(groupData.anchorTo)
        nameStatus:SetText("Anchored")
        self:SetText("")
        BH.cdm:ScheduleReconcile()
    end)
    ns.Rows.AddTooltip(nameBox, "Frame Name",
        "The global name of any frame, from any addon. Type /fstack and hover the frame "
     .. "to find it, then press Enter here. If that frame is itself attached to this "
     .. "group, the anchor is ignored rather than allowed to loop.")
    yOffset = yOffset - 46

    local axSlider = CreateSQSlider(content, "Anchor Offset X", 220, -200, 200, 1)
    axSlider:SetValue(groupData.anchorX or 0)
    axSlider:SetAfterValueChanged(function(value)
        groupData.anchorX = value
        BH.cdm:ScheduleReconcile()
    end)
    axSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(axSlider, "Anchor Offset X", "Nudge this group sideways from its anchor.")
    yOffset = yOffset - 46

    local aySlider = CreateSQSlider(content, "Anchor Offset Y", 220, -200, 200, 1)
    aySlider:SetValue(groupData.anchorY or -4)
    aySlider:SetAfterValueChanged(function(value)
        groupData.anchorY = value
        BH.cdm:ScheduleReconcile()
    end)
    aySlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(aySlider, "Anchor Offset Y", "Nudge this group up or down from its anchor.")
    return yOffset - 46
end

-- ---------------------------------------------------------------------------
-- Appearance: what an icon looks like before anything happens to it.
-- ---------------------------------------------------------------------------
local function BuildGroupLookSection(content, indent, yOffset, groupName, groupData, specData)
    -- Built from ICON_SHAPES, so a new shape is one line there plus its image.
    local shapeItems = {}
    for _, s in ipairs(ICON_SHAPES) do
        shapeItems[#shapeItems + 1] = { text = s.text, value = s.value }
    end
    local shapeDD = CreateSQDropdown(content, "Icon Shape", 160, shapeItems, function(val)
        groupData.iconShape = val
        BH.cdm:ScheduleReconcile()
    end)
    shapeDD:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    shapeDD:SetSelectedValue(groupData.iconShape or "none")
    ns.Rows.AddTooltip(shapeDD, "Icon Shape",
        "Cuts each icon, its cooldown sweep and its border to a shape. Tracked buffs follow it too while Draw Buffs Ourselves is on; Blizzard's own buff frames keep their look.")
    yOffset = yOffset - 50

    local zoomSlider = CreateSQSlider(content, "Icon Zoom %", 220, 0, 20, 1)
    zoomSlider:SetValue(math.floor(((groupData.iconZoom or DEFAULT_ICON_ZOOM) * 100) + 0.5))
    zoomSlider:SetAfterValueChanged(function(value)
        groupData.iconZoom = value / 100
        BH.cdm:ScheduleReconcile()
    end)
    zoomSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(zoomSlider, "Icon Zoom %",
        "How much is cropped from each edge of the icon art. Higher values trim the default border off the artwork.")
    yOffset = yOffset - 46

    local borderCB = CreateSQCheckbox(content, "Show Border", function(checked)
        groupData.showBorder = checked
        BH.cdm:ScheduleReconcile()
    end)
    borderCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(borderCB, "Show Border", "Draw a border around each icon in this group.")
    borderCB:SetChecked(groupData.showBorder ~= false)

    local classColorCB = CreateSQCheckbox(content, "Use Class Colour", function(checked)
        groupData.borderClassColor = checked
        BH.cdm:ScheduleReconcile()
    end)
    classColorCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(classColorCB, "Use Class Colour",
        "Colour the border with your class colour, overriding the colour picked above.")
    classColorCB:SetChecked(groupData.borderClassColor)
    yOffset = yOffset - 32

    local thickSlider = CreateSQSlider(content, "Border Thickness", 220, 0, 4, 1)
    thickSlider:SetValue(groupData.borderThickness or DEFAULT_BORDER_THICKNESS)
    thickSlider:SetAfterValueChanged(function(value)
        groupData.borderThickness = value
        BH.cdm:ScheduleReconcile()
    end)
    thickSlider:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(thickSlider, "Border Thickness",
        "How heavy the border around each icon is, in pixels. 0 removes it without unticking Show Border.")
    yOffset = yOffset - 46

    local bcInit = groupData.borderColor or DEFAULT_BORDER_COLOR
    local borderColorPicker = CreateSQColorPicker(content, "Border Colour",
        bcInit[1], bcInit[2], bcInit[3], bcInit[4], function(r, g, b, a)
            groupData.borderColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    borderColorPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(borderColorPicker, "Border Colour", "Colour of the icon border for this group.")

    local insideCB = CreateSQCheckbox(content, "Border Inside Icon", function(checked)
        groupData.borderInside = checked
        BH.cdm:ScheduleReconcile()
    end)
    insideCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(insideCB, "Border Inside Icon",
        "Draw the border over the icon's own edge instead of around the outside. The group then takes up "
        .. "exactly its icons' size, so a bar matched to its width (SquizzFrames' cast bar or resource bar "
        .. "\"Match width\") lines up with the border's outer edge instead of falling short by the border.")
    insideCB:SetChecked(groupData.borderInside)
    yOffset = yOffset - 32

    local bgCB = CreateSQCheckbox(content, "Icon Background", function(checked)
        groupData.bgEnabled = checked
        BH.cdm:ScheduleReconcile()
    end)
    bgCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(bgCB, "Icon Background",
        "Draw a filled square behind each icon. Mainly useful with Hide Until Active, so the group keeps a visible footprint while its icons are hidden.")
    bgCB:SetChecked(groupData.bgEnabled)

    local bgInit = groupData.bgColor or DEFAULT_BG_COLOR
    local bgColorPicker = CreateSQColorPicker(content, "Background Colour",
        bgInit[1], bgInit[2], bgInit[3], bgInit[4], function(r, g, b, a)
            groupData.bgColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    bgColorPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(bgColorPicker, "Background Colour", "Colour and opacity of the icon background.")
    yOffset = yOffset - 32

    local barBgCB = CreateSQCheckbox(content, "Group Background", function(checked)
        groupData.barBgEnabled = checked
        BH.cdm:ScheduleReconcile()
    end)
    barBgCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(barBgCB, "Group Background",
        "A panel behind the whole group rather than behind each icon. It grows and shrinks with the row, "
     .. "including as a Hide Until Active group packs down.")
    barBgCB:SetChecked(groupData.barBgEnabled)

    local barBgInit = groupData.barBgColor or { 0, 0, 0, 0.4 }
    local barBgPicker = CreateSQColorPicker(content, "Group Background Colour",
        barBgInit[1], barBgInit[2], barBgInit[3], barBgInit[4], function(r, g, b, a)
            groupData.barBgColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    barBgPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(barBgPicker, "Group Background Colour", "Colour and opacity of the group panel.")
    yOffset = yOffset - 32

    local barBgPad = CreateSQSlider(content, "Group Background Padding", 220, 0, 20, 1)
    barBgPad:SetValue(groupData.barBgPadding or 2)
    barBgPad:SetAfterValueChanged(function(value)
        groupData.barBgPadding = value
        BH.cdm:ScheduleReconcile()
    end)
    barBgPad:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(barBgPad, "Group Background Padding", "How far the panel extends past the icons.")
    return yOffset - 46
end

-- ---------------------------------------------------------------------------
-- Text: the three things that can be written on an icon.
-- ---------------------------------------------------------------------------
local function BuildGroupTextSection(content, indent, yOffset, groupName, groupData, specData)
    local cdTextCB = CreateSQCheckbox(content, "Cooldown Text", function(checked)
        groupData.showCooldownText = checked
        BH.cdm:ScheduleReconcile()
    end)
    cdTextCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(cdTextCB, "Cooldown Text", "Show the remaining cooldown as a number on the icon.")
    cdTextCB:SetChecked(groupData.showCooldownText ~= false)

    local cdColor = groupData.cooldownTextColor or { 1, 1, 1, 1 }
    local cdPicker = CreateSQColorPicker(content, "Cooldown Text Colour",
        cdColor[1], cdColor[2], cdColor[3], cdColor[4] or 1, function(r, g, b, a)
            groupData.cooldownTextColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    cdPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(cdPicker, "Cooldown Text Colour", "Colour of the cooldown countdown.")
    yOffset = yOffset - 32

    local cdSize = CreateSQSlider(content, "Cooldown Text Size", 220, 0, 32, 1)
    cdSize:SetValue(groupData.cooldownTextSize or 0)
    cdSize:SetAfterValueChanged(function(v)
        groupData.cooldownTextSize = v
        BH.cdm:ScheduleReconcile()
    end)
    cdSize:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(cdSize, "Cooldown Text Size",
        "Font size of the cooldown countdown. 0 keeps the game's own size, which grows and shrinks with the icon.")
    yOffset = yOffset - 46

    yOffset = AddTextPlacement(content, indent, yOffset, groupData,
        "Cooldown Text", "cooldownTextPosition",
        "cooldownTextOffsetX", "cooldownTextOffsetY", "CENTER", 0, 0,
        "Where the countdown sits on the icon. Centre leaves the game's own placement alone; "
     .. "any other choice moves the countdown the game draws, which it does not officially "
     .. "support, so it is ignored rather than erroring if a patch stops exposing it.")
    yOffset = yOffset - 6

    local countCB = CreateSQCheckbox(content, "Show Charges", function(checked)
        groupData.showCount = checked
        BH.cdm:ScheduleReconcile()
    end)
    countCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(countCB, "Show Charges",
        "Show the charge or stack number on icons that have one.")
    countCB:SetChecked(groupData.showCount ~= false)

    local cntColor = groupData.countColor or { 1, 1, 1, 1 }
    local cntPicker = CreateSQColorPicker(content, "Charge Text Colour",
        cntColor[1], cntColor[2], cntColor[3], cntColor[4] or 1, function(r, g, b, a)
            groupData.countColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    cntPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(cntPicker, "Charge Text Colour", "Colour of the charge or stack number.")
    yOffset = yOffset - 32

    local countSize = CreateSQSlider(content, "Charge Text Size", 220, 6, 24, 1)
    countSize:SetValue(groupData.countSize or 12)
    countSize:SetAfterValueChanged(function(v) groupData.countSize = v; BH.cdm:ScheduleReconcile() end)
    countSize:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(countSize, "Charge Text Size", "Font size of the charge number.")
    yOffset = yOffset - 46

    yOffset = AddTextPlacement(content, indent, yOffset, groupData,
        "Charges", "countPosition", "countOffsetX", "countOffsetY",
        "BOTTOMRIGHT", -1, 1, "Where the charge number sits on the icon.")
    yOffset = yOffset - 6

    local kbCB = CreateSQCheckbox(content, "Show Keybind", function(checked)
        groupData.showKeybind = checked
        BH.cdm:ScheduleReconcile()
    end)
    kbCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(kbCB, "Show Keybind",
        "Show the key that casts each ability on its icon.\n\n"
     .. "Read from your action bars, so an ability that is not on a bar has no key to show. "
     .. "It deliberately does not follow bar swaps from stealth, druid forms or dragonriding: "
     .. "a keybind that rewrites itself every time you shapeshift is less use than a steady one.")
    kbCB:SetChecked(groupData.showKeybind)

    local kbColor = groupData.keybindColor or { 1, 1, 1, 0.9 }
    local kbPicker = CreateSQColorPicker(content, "Keybind Colour",
        kbColor[1], kbColor[2], kbColor[3], kbColor[4], function(r, g, b, a)
            groupData.keybindColor = { r, g, b, a }
            BH.cdm:ScheduleReconcile()
        end)
    kbPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(kbPicker, "Keybind Colour", "Colour of the keybind text.")
    yOffset = yOffset - 32

    local kbSize = CreateSQSlider(content, "Keybind Text Size", 220, 6, 20, 1)
    kbSize:SetValue(groupData.keybindSize or 10)
    kbSize:SetAfterValueChanged(function(value)
        groupData.keybindSize = value
        BH.cdm:ScheduleReconcile()
    end)
    kbSize:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(kbSize, "Keybind Text Size", "Font size of the keybind text.")
    yOffset = yOffset - 46

    return AddTextPlacement(content, indent, yOffset, groupData,
        "Keybind", "keybindPosition", "keybindOffsetX", "keybindOffsetY",
        "TOPRIGHT", -1, -1, "Where the keybind sits on the icon.")
end

-- ---------------------------------------------------------------------------
-- Behaviour: what the icon does as the ability changes state.
-- ---------------------------------------------------------------------------
local function BuildGroupBehaviourSection(content, indent, yOffset, groupName, groupData, specData)
    local tooltipCB = CreateSQCheckbox(content, "Show Tooltip", function(checked)
        groupData.showTooltip = checked
        BH.cdm:ScheduleReconcile()
    end)
    tooltipCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(tooltipCB, "Show Tooltip", "Show the spell tooltip when hovering an icon in this group.")
    tooltipCB:SetChecked(groupData.showTooltip ~= false)
    yOffset = yOffset - 32

    -- The two desaturate options are opposites, so ticking one unticks the
    -- other. Leaving both on screen and independently settable would allow a
    -- combination that greys the icon in every state, which is not a look
    -- anyone wants and is hard to diagnose from the settings alone.
    local desatCB, desatCdCB

    desatCB = CreateSQCheckbox(content, "Grey Out When Ready", function(checked)
        groupData.desaturateReady = checked
        if checked then
            groupData.desaturateOnCooldown = false
            if desatCdCB then desatCdCB:SetChecked(false) end
        end
        BH.cdm:ScheduleReconcile()
    end)
    desatCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(desatCB, "Grey Out When Ready",
        "Grey the icon out while the ability is READY, so a full-colour icon means it is on "
        .. "cooldown. The inverse of the usual arrangement, for a group used as an \"these are "
        .. "up\" display.")
    desatCB:SetChecked(groupData.desaturateReady)

    desatCdCB = CreateSQCheckbox(content, "Grey Out On Cooldown", function(checked)
        groupData.desaturateOnCooldown = checked
        if checked then
            groupData.desaturateReady = false
            if desatCB then desatCB:SetChecked(false) end
        end
        BH.cdm:ScheduleReconcile()
    end)
    desatCdCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(desatCdCB, "Grey Out On Cooldown",
        "Grey the icon out while the ability is on cooldown, which is what Blizzard's own bars "
        .. "do. Only the cooldown counts here, not whether the buff it applies is up.")
    desatCdCB:SetChecked(groupData.desaturateOnCooldown)
    yOffset = yOffset - 32

    local glowCB = CreateSQCheckbox(content, "Glow On Ready", function(checked)
        groupData.glowOnReady = checked
        BH.cdm:ScheduleReconcile()
    end)
    glowCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(glowCB, "Glow On Ready", "Highlight the icon when the ability comes off cooldown.")
    glowCB:SetChecked(groupData.glowOnReady)

    -- "Show While Active" and its colour mean nothing on the built-in buff
    -- groups: it is applied to cooldown-type icons only (see
    -- proxy._sqShowActiveBuff), and a tracked buff already shows its duration.
    -- Offering it there got it ticked on Buffs instead of Essential, which
    -- reads as the feature not working (2026-09-22). Custom groups keep it:
    -- they can mix cooldowns and buffs.
    local buffOnlyGroup = groupName == BUILTIN_FOR_VIEWERTYPE["buff"]
        or groupName == BUILTIN_FOR_VIEWERTYPE["buffbar"]
    if buffOnlyGroup then
        yOffset = yOffset - 32
    else
        local activeCB = CreateSQCheckbox(content, "Show While Active", function(checked)
            groupData.showActiveBuff = checked
            BH.cdm:ScheduleReconcile()
        end)
        activeCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
        ns.Rows.AddTooltip(activeCB, "Show While Active",
            "While the ability is running, count down how long is LEFT OF IT instead of its cooldown, "
            .. "keep the icon at full colour, and ring it with a glow distinct from the proc highlight. "
            .. "The real cooldown takes over the moment it ends.\n\nOnly applies to abilities whose buff "
            .. "lands on you -- one that buffs your target keeps showing its cooldown, which is what "
            .. "stops a short buff hiding a long cooldown.\n\nWorks in combat: the active display is the "
            .. "real aura, drawn by the game's own aura engine and shown only while the buff is up, so "
            .. "the cooldown underneath is what is left the moment it ends.")
        activeCB:SetChecked(groupData.showActiveBuff)
        yOffset = yOffset - 32

        local agInit = ActiveGlowColor(groupData)
        local activeGlowPicker = CreateSQColorPicker(content, "Active Glow Colour",
            agInit[1], agInit[2], agInit[3], agInit[4] or 1, function(r, g, b, a)
                groupData.activeGlowColor = { r, g, b, a }
                BH.cdm:ScheduleReconcile()
            end)
        activeGlowPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(activeGlowPicker, "Active Glow Colour",
            "Colour of the glow shown by \"Show While Active\". Separate from the proc glow and from "
            .. "Glow On Ready, both of which use your main glow colour, so \"the ability is running\" "
            .. "and \"the ability just lit up\" do not look the same.")
        yOffset = yOffset - 32
    end

    -- Proc Glow and Dim When Unusable are cooldown-only for the same reason
    -- Show While Active is (ApplyProxyVisuals' isCooldownType): Blizzard's buff
    -- items have neither a proc highlight nor a "can you cast this". Offering
    -- them on the buff groups only invited them to be ticked where they do
    -- nothing, which is how Show While Active got turned on in the wrong place.
    if not buffOnlyGroup then
        local procCB = CreateSQCheckbox(content, "Proc Glow", function(checked)
            groupData.procGlow = checked
            BH.cdm:ScheduleReconcile()
        end)
        procCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(procCB, "Proc Glow",
            "Highlight an icon when the ability lights up, the same moment Blizzard's own bars and your action bars do.")
        procCB:SetChecked(groupData.procGlow ~= false)

        local usableCB = CreateSQCheckbox(content, "Dim When Unusable", function(checked)
            groupData.usableTint = checked
            BH.cdm:ScheduleReconcile()
        end)
        usableCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
        ns.Rows.AddTooltip(usableCB, "Dim When Unusable",
            "Colour the icon by whether you can cast it right now, exactly as Blizzard's own bars do: dimmed when it is unusable, blue when you lack the power for it, and red when the target is out of range.")
        usableCB:SetChecked(groupData.usableTint ~= false)
        yOffset = yOffset - 32

        local pgInit = ProcGlowColor(groupData)
        local procGlowPicker = CreateSQColorPicker(content, "Proc Glow Colour",
            pgInit[1], pgInit[2], pgInit[3], pgInit[4] or 1, function(r, g, b, a)
                groupData.procGlowColor = { r, g, b, a }
                BH.cdm:ScheduleReconcile()
            end)
        procGlowPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(procGlowPicker, "Proc Glow Colour",
            "Colour of the proc glow, defaulting to the gold of the game's own. The glow is drawn by "
            .. "this addon in your icon's shape, square included, so the colour applies whatever shape "
            .. "the group uses.")
        yOffset = yOffset - 32
    end
    -- Each row closes itself above, so a buff group's section simply ends after
    -- Glow On Ready rather than leaving the gap its hidden rows used to fill.
    return yOffset
end

-- ---------------------------------------------------------------------------
-- Visibility: when the group is on screen at all.
-- ---------------------------------------------------------------------------
local function BuildGroupVisibilitySection(content, indent, yOffset, groupName, groupData, specData)
    local enableCB = CreateSQCheckbox(content, "Enable Group", function(checked)
        groupData.enabled = checked
        BH.cdm:ScheduleReconcile()
    end)
    enableCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(enableCB, "Enable Group",
        "Show this group at all. Unticking hides it without unassigning anything, which is how you switch off one of the built-in groups you do not want.")
    enableCB:SetChecked(groupData.enabled ~= false)
    yOffset = yOffset - 32

    local combatCB = CreateSQCheckbox(content, "Hide Out of Combat", function(checked)
        groupData.hideOutOfCombat = checked
        BH.cdm:ScheduleReconcile()
    end)
    combatCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(combatCB, "Hide Out of Combat", "Only show this group while you are in combat.")
    combatCB:SetChecked(groupData.hideOutOfCombat)

    local activeOnlyCB = CreateSQCheckbox(content, "Hide Until Active", function(checked)
        groupData.hideUntilActive = checked
        BH.cdm:ScheduleReconcile()
    end)
    activeOnlyCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(activeOnlyCB, "Hide Until Active", "Only show an icon once its ability is on cooldown or its buff is active.")
    activeOnlyCB:SetChecked(groupData.hideUntilActive)
    yOffset = yOffset - 32

    -- Visibility conditions. All default off, so a group shows everywhere
    -- unless told otherwise.
    local visRows = {
        { key = "hideMounted",     label = "Hide While Mounted",
          tip = "Hide this group while you are on a mount." },
        { key = "onlyInInstances", label = "Only In Instances",
          tip = "Only show this group in a dungeon, raid, delve, scenario or battleground." },
        { key = "hideInHousing",   label = "Hide In Housing",
          tip = "Hide this group while you are inside your house or on your plot." },
        { key = "hideNoTarget",    label = "Hide Without A Target",
          tip = "Hide this group whenever you have nothing targeted." },
        { key = "hideNoEnemy",     label = "Hide Without An Enemy",
          tip = "Hide this group unless your target is something you can attack." },
    }
    for i, row in ipairs(visRows) do
        local cb = CreateSQCheckbox(content, row.label, function(checked)
            groupData[row.key] = checked
            BH.cdm:ScheduleReconcile()
        end)
        -- Two columns, same as the toggles above.
        local col = ((i - 1) % 2 == 0) and indent or (indent + 190)
        cb:SetPoint("TOPLEFT", content, "TOPLEFT", col, yOffset)
        ns.Rows.AddTooltip(cb, row.label, row.tip)
        cb:SetChecked(groupData[row.key])
        if (i % 2) == 0 or i == #visRows then yOffset = yOffset - 26 end
    end
    return yOffset - 6
end

-- ---------------------------------------------------------------------------
-- Buffs: only meaningful for a group that holds them. Offered nowhere else,
-- because on any other group every control here would be dead.
-- ---------------------------------------------------------------------------
local function GroupHoldsBuffs(groupName)
    local grp = BH.cdm.groups[groupName]
    return (grp and grp.usesBlizzardIcons)
        or groupName == BUILTIN_FOR_VIEWERTYPE["buff"]
        or groupName == BUILTIN_FOR_VIEWERTYPE["buffbar"]
        or false
end

local function BuildGroupBuffSection(content, indent, yOffset, groupName, groupData, specData)
    local alwaysCB = CreateSQCheckbox(content, "Always Show Buffs", function(checked)
        groupData.showInactiveBuffs = checked
        BH.cdm:ScheduleReconcile()
    end)
    alwaysCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(alwaysCB, "Always Show Buffs",
        "Keep a slot for every tracked buff, showing a dimmed placeholder while it is not up, "
     .. "instead of the row shrinking to only the active ones.")
    alwaysCB:SetChecked(groupData.showInactiveBuffs)

    local desatBuffCB = CreateSQCheckbox(content, "Grey Out Inactive", function(checked)
        groupData.desaturateInactiveBuffs = checked
        BH.cdm:ScheduleReconcile()
    end)
    desatBuffCB:SetPoint("TOPLEFT", content, "TOPLEFT", indent + 190, yOffset)
    ns.Rows.AddTooltip(desatBuffCB, "Grey Out Inactive",
        "Draw those placeholders in greyscale. Untick to keep them in colour and rely on the "
     .. "dimming alone.")
    desatBuffCB:SetChecked(groupData.desaturateInactiveBuffs ~= false)
    yOffset = yOffset - 32

    local phAlpha = CreateSQSlider(content, "Inactive Buff Opacity %", 220, 5, 100, 5)
    phAlpha:SetValue(math.floor(((groupData.inactiveBuffAlpha or 0.45) * 100) + 0.5))
    phAlpha:SetAfterValueChanged(function(value)
        groupData.inactiveBuffAlpha = value / 100
        BH.cdm:ScheduleReconcile()
    end)
    phAlpha:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
    ns.Rows.AddTooltip(phAlpha, "Inactive Buff Opacity %",
        "How visible the placeholder for a buff that is not up should be.")
    yOffset = yOffset - 46

    -- Only the native bars have a fill of ours to colour; Blizzard's
    -- borrowed bars keep their own.
    if groupData.isBarGroup then
        local bc = groupData.barColor or { 1.0, 0.7, 0.0, 1 }
        local barColorPicker = CreateSQColorPicker(content, "Bar Colour",
            bc[1], bc[2], bc[3], bc[4] or 1, function(r, g, b, a)
                groupData.barColor = { r, g, b, a }
                BH.cdm:ScheduleReconcile()
            end)
        barColorPicker:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        ns.Rows.AddTooltip(barColorPicker, "Bar Colour",
            "Fill colour of the buff bars. Applies when Draw Buffs Ourselves is on.")
        yOffset = yOffset - 32
    end

    return yOffset
end

-- The sections, in the order they appear. Buffs is last and conditional.
local GROUP_SECTIONS = {
    { key = "layout",     label = "Layout",     build = BuildGroupLayoutSection },
    { key = "look",       label = "Appearance", build = BuildGroupLookSection },
    { key = "text",       label = "Text",       build = BuildGroupTextSection },
    { key = "behaviour",  label = "Behaviour",  build = BuildGroupBehaviourSection },
    { key = "visibility", label = "Visibility", build = BuildGroupVisibilitySection },
    { key = "buffs",      label = "Buffs",      build = BuildGroupBuffSection, buffsOnly = true },
}

--- Build one group's settings.
---
--- `tabbed` means this group has a page to itself, so the sections become a
--- strip of tabs and only one is on screen at a time. Without it the sections
--- are stacked under headings and the running yOffset is returned, which is
--- what the Custom Cooldowns tab needs: it puts several groups in one scroller,
--- where a tab strip per group would be worse than the single column ever was.
-- `inlinePreview`: draw the group's preview under its heading. The Custom
-- Icons page wants that; the CDM tab pins one above each sub-tab instead.
-- Redraw every built-in group's "(N tracked)" label from its live members.
-- Called at the end of each Reconcile. Cheap -- one members walk per built-in
-- group -- and each updater is pcall'd so a label on a torn-down page cannot
-- take the reconcile with it.
function BH:RefreshCDMCounts()
    for _, update in pairs(self.cdmCountUpdaters or {}) do pcall(update) end
end

function BH:BuildGroupSection(content, leftPad, yOffset, groupName, groupData, specData, tabbed, inlinePreview)
    local indent = leftPad + 10

    -- Group name header row with delete button
    local groupRow = CreateFrame("Frame", nil, content)
    groupRow:SetSize(380, 24)
    groupRow:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)

    local gLabel = groupRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gLabel:SetPoint("LEFT", 4, 0)
    gLabel:SetText(groupName)
    gLabel:SetTextColor(ns.Theme.RGBA("text"))

    -- Assigned count
    local countLabel = groupRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countLabel:SetPoint("LEFT", gLabel, "RIGHT", 8, 0)
    -- A built-in group fills itself from Blizzard's Cooldown Manager, so its
    -- own cooldownIDs list stays empty and this always read "0 assigned"
    -- (user report 2026-09-24). Count what the group actually holds instead --
    -- the same list the preview draws. Custom groups keep counting their own
    -- assignments, which is exactly what they are.
    --
    -- A LIVE count, not one computed at build time. The panel is built once
    -- (on first open) and only rebuilt by a profile or spec change or its own
    -- controls, while a built-in group's members are filled by Reconcile. A
    -- build that ran before the first reconcile -- or a rebuild that landed
    -- mid-way through one -- froze the label at "(0 tracked)" for the rest of
    -- the session, however full the group actually was (user report
    -- 2026-09-26, after 1.89's fix had made the number right only at build
    -- time). So it is recomputed whenever the group's page is shown and after
    -- every reconcile (BH:RefreshCDMCounts). Keyed by group name, so a rebuild
    -- replaces the updater rather than piling new ones up.
    if groupData.builtin then
        local function UpdateCount()
            local held = #BH.cdm:PreviewMembers(groupName).items
            countLabel:SetText("(" .. held .. " tracked)")
        end
        UpdateCount()
        BH.cdmCountUpdaters = BH.cdmCountUpdaters or {}
        BH.cdmCountUpdaters[groupName] = UpdateCount
        groupRow:SetScript("OnShow", UpdateCount)
    else
        local assignedCount = groupData.cooldownIDs and #groupData.cooldownIDs or 0
        countLabel:SetText("(" .. assignedCount .. " assigned)")
    end
    countLabel:SetTextColor(ns.Theme.RGBA("textDim"))

    -- The frame name other addons anchor to.
    --
    -- Shown because the alternative is asking: an addon that anchors by typing
    -- a frame name cannot call our Lua accessor, and the obvious guess --
    -- EssentialCooldownViewer -- is Blizzard's frame, which this addon parks
    -- offscreen when "Hide Blizzard's Cooldown Manager" is on. Anchoring to
    -- that drags the anchored frame off with it, which is a confusing way to
    -- find out you picked the wrong frame.
    local anchorLabel = groupRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    anchorLabel:SetPoint("LEFT", countLabel, "RIGHT", 8, 0)
    anchorLabel:SetText("SQZ_CDMGroup_" .. groupName)
    anchorLabel:SetTextColor(ns.GetAccentColor())
    ns.Rows.AddTooltip(anchorLabel, "Anchor name",
        "The frame name to give another addon that anchors to this group.\n\n"
     .. "Do not use Blizzard's EssentialCooldownViewer or similar: those are separate frames, "
     .. "and with Hide Blizzard's Cooldown Manager on they are parked far offscreen, which "
     .. "takes anything anchored to them along too.")

    -- Delete button. Not offered for the three built-in groups: they are
    -- recreated on the next reconcile anyway, so a Delete that visibly does
    -- nothing is worse than no button. Their contents can still be emptied by
    -- reassigning spells elsewhere.
    if not groupData.builtin then
        local delBtn = CreateSQButton(groupRow, "Delete", 60, 20, {0.75, 0.25, 0.25, 1})
        delBtn:SetPoint("RIGHT", groupRow, "RIGHT", 0, 0)
        delBtn:SetScript("OnClick", function()
            BH.cdm:DeleteGroup(groupName)
            C_Timer.After(0.1, function() BH:RebuildCDMTabContent() end)
        end)
    end

    yOffset = yOffset - 28

    -- Custom Icons: a preview under each group's heading (the Cooldowns tab
    -- pins one above each sub-tab instead -- see BuildCDMTab).
    if (inlinePreview or not tabbed) and ns.CDMPreview then
        yOffset = ns.CDMPreview.PlaceInline(content, groupName, leftPad, yOffset)
    end

    local holdsBuffs = GroupHoldsBuffs(groupName)

    if not tabbed then
        -- Stacked, under headings.
        for _, sec in ipairs(GROUP_SECTIONS) do
            if not sec.buffsOnly or holdsBuffs then
                yOffset = SectionHeading(content, indent, yOffset, sec.label)
                yOffset = sec.build(content, indent, yOffset, groupName, groupData, specData)
                yOffset = yOffset - 6
            end
        end

        -- Thin separator
        local sep = content:CreateTexture(nil, "ARTWORK")
        sep:SetHeight(1)
        sep:SetPoint("TOPLEFT", content, "TOPLEFT", indent, yOffset)
        sep:SetPoint("TOPRIGHT", content, "TOPRIGHT", -10, yOffset)
        sep:SetColorTexture(0.25, 0.25, 0.30, 0.5)
        return yOffset - 10
    end

    local defs = {}
    for _, sec in ipairs(GROUP_SECTIONS) do
        if not sec.buffsOnly or holdsBuffs then
            defs[#defs + 1] = { key = sec.key, label = sec.label }
        end
    end

    -- The page owns its own height from here: the widget sets it to whichever
    -- section is showing, so the outer scroller scrolls that section rather
    -- than the sum of all of them.
    local pages = ns.SubTabs.CreateInline(content, defs, yOffset, {
        initial = cdmGroupTab[groupName],
        section = content.section,
        onSelect = function(key) cdmGroupTab[groupName] = key end,
    })

    -- Each section files its rows under its own tab, so a search hit can bring
    -- that tab forward instead of landing on a hidden one.
    local prev = ns.Rows.currentSection
    for _, sec in ipairs(GROUP_SECTIONS) do
        local page = pages[sec.key]
        if page then
            ns.Rows.currentSection = page.section or prev
            -- Indented to line up with the tab labels above it.
            local endY = sec.build(page, 12, -8, groupName, groupData, specData)
            pages.SetPageHeight(sec.key, math.abs(endY))
        end
    end
    ns.Rows.currentSection = prev

    -- The host height is the widget's business now, so there is nothing
    -- meaningful to return; the caller stops using it for a tabbed page.
    return yOffset
end
