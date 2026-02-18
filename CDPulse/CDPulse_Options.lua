--[[
CDPulse_Options.lua
Settings panel UI for CDPulse.
]]

local PANEL_NAME = "|cffb026ffCD|rPulse"
local PAD = 16

-- Defaults for settings that live on the Appearance & Audio tab.
-- These should match the out-of-the-box values a user gets on first install.
local APPEARANCE_DEFAULTS = {
    size = 64,
    iconOpacity = 1,
    point = "CENTER",
    relPoint = "CENTER",
    x = 0,
    y = 120,
    pulseDuration = 1.00,
    locked = true,
    noOverlapAlerts = true,
}

-- EnsureDB is now just a getter since CDPulse.lua initializes everything during ADDON_LOADED
-- CDPulse.lua loads first (TOC order) and its EnsureDB runs before this file's init
local function EnsureDB()
    -- CDPulse.lua's EnsureDB has already run and initialized all defaults
    -- Just return the global with safety check
    if not CDPulseDB then
        CDPulseDB = {}
    end
    return CDPulseDB
end

local function GetLSM()
    if not LibStub then return nil end
    return LibStub("LibSharedMedia-3.0", true)
end

local function GetSpellNameAndIcon(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name then return info.name, info.iconID end
    end
    return nil, nil
end

local function ResolveSpellID(input)
    input = (input or ""):match("^%s*(.-)%s*$")
    if input == "" then return nil end
    local n = tonumber(input)
    if n then return n end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(input)
        if info and info.spellID then return info.spellID end
    end
    return nil
end


-- ============================================================================
-- Class-capable spell cache (spellbook + talent trees + selected PvP talents)
--
-- Why: Spellbook membership alone does NOT include unselected talent spells.
-- The class filter should mean "my class could have this spell".
-- ============================================================================

local classSpellCacheDirty = true
local classSpellIDs
local classSpellNames

local function MarkClassSpellCacheDirty()
    classSpellCacheDirty = true
end

local function SafeAddClassSpell(spellID)
    if type(spellID) ~= "number" or spellID <= 0 then return end
    classSpellIDs[spellID] = true

    -- Name set is optional but helps with spellID variants / overrides.
    if classSpellNames and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name and info.name ~= "" then
            classSpellNames[info.name] = true
        end
    end
end

local function RebuildClassSpellCache()
    classSpellIDs = {}
    classSpellNames = {}

    -- ------------------------------------------------------------------------
    -- Phase 1: Spellbook enumeration
    -- ------------------------------------------------------------------------
    if C_SpellBook
        and C_SpellBook.GetNumSpellBookSkillLines
        and C_SpellBook.GetSpellBookSkillLineInfo
        and C_SpellBook.GetSpellBookItemInfo
        and Enum and Enum.SpellBookSpellBank then

        local bank = Enum.SpellBookSpellBank.Player
        local numLines = C_SpellBook.GetNumSpellBookSkillLines() or 0

        for skillLineIndex = 1, numLines do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(skillLineIndex)
            if info and info.numSpellBookItems and info.itemIndexOffset then
                local startSlot = info.itemIndexOffset + 1
                local endSlot = startSlot + info.numSpellBookItems - 1

                for slot = startSlot, endSlot do
                    local itemType, actionID, spellID = C_SpellBook.GetSpellBookItemInfo(slot, bank)
                    -- spellID may be the overriding spell ID; actionID is the base ID
                    if spellID then SafeAddClassSpell(spellID) end
                    if actionID then SafeAddClassSpell(actionID) end
                end
            end
        end
    end

    -- ------------------------------------------------------------------------
    -- Phase 2: Talent tree enumeration (includes UNSELECTED talents)
    -- ------------------------------------------------------------------------
    local function BuildFromTraits()
        if not C_ClassTalents or not C_ClassTalents.GetActiveConfigID then return end
        if not C_Traits
            or not (C_Traits.GetConfigInfo
                and C_Traits.GetTreeNodes
                and C_Traits.GetNodeInfo
                and C_Traits.GetEntryInfo
                and C_Traits.GetDefinitionInfo) then
            return
        end

        local configID = C_ClassTalents.GetActiveConfigID()
        if not configID then return end

        local configInfo = C_Traits.GetConfigInfo(configID)
        if not configInfo or not configInfo.treeIDs then return end

        for _, treeID in ipairs(configInfo.treeIDs) do
            local nodeIDs = C_Traits.GetTreeNodes(treeID)
            if nodeIDs then
                for _, nodeID in ipairs(nodeIDs) do
                    local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                    if nodeInfo and nodeInfo.entryIDs then
                        for _, entryID in ipairs(nodeInfo.entryIDs) do
                            local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
                            if entryInfo and entryInfo.definitionID then
                                local defInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
                                if defInfo then
                                    SafeAddClassSpell(defInfo.spellID)
                                    SafeAddClassSpell(defInfo.overriddenSpellID)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Guard against early-load nils or future API changes.
    pcall(BuildFromTraits)

    -- ------------------------------------------------------------------------
    -- Phase 3: Selected PvP talents
    -- ------------------------------------------------------------------------
    local function BuildFromPvpTalents()
        if not C_SpecializationInfo
            or not C_SpecializationInfo.GetAllSelectedPvpTalentIDs
            or not C_SpecializationInfo.GetPvpTalentInfo then
            return
        end

        local ids = C_SpecializationInfo.GetAllSelectedPvpTalentIDs()
        if not ids then return end

        for _, talentID in ipairs(ids) do
            local info = C_SpecializationInfo.GetPvpTalentInfo(talentID)
            if info and info.spellID then
                SafeAddClassSpell(info.spellID)
            end
        end
    end

    pcall(BuildFromPvpTalents)

    classSpellCacheDirty = false
end

-- Invalidate cache on talent/spec/spellbook changes.
local classSpellEventFrame = CreateFrame("Frame")
classSpellEventFrame:RegisterEvent("SPELLS_CHANGED")
classSpellEventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
classSpellEventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
classSpellEventFrame:RegisterEvent("TRAIT_TREE_CHANGED")
classSpellEventFrame:RegisterEvent("PLAYER_PVP_TALENT_UPDATE")
classSpellEventFrame:SetScript("OnEvent", function()
    MarkClassSpellCacheDirty()
end)

-- Check if a spell belongs to the player's class (any spec, not just current).
-- Uses a cached lookup built from spellbook + talent trees (+ selected PvP talents).
local function IsSpellForPlayerClass(spellID)
    if not spellID then return false end

    -- Lazy rebuild
    if classSpellCacheDirty or not classSpellIDs then
        RebuildClassSpellCache()
    end

    if classSpellIDs and classSpellIDs[spellID] then
        return true
    end

    -- Robustness: accept spellID variants that share the same spell name.
    if classSpellNames and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name and classSpellNames[info.name] then
            return true
        end
    end

    -- Fallback: old spellbook membership check (fail-open if API missing)
    if C_SpellBook and C_SpellBook.FindSpellBookSlotForSpell then
        local slot = C_SpellBook.FindSpellBookSlotForSpell(
            spellID,
            true,   -- includeHidden
            true,   -- includeFlyouts
            true,   -- includeFutureSpells
            true    -- includeOffSpec
        )
        return slot ~= nil
    end

    -- If we can't evaluate for any reason, don't hide spells unexpectedly.
    return true
end

local function SortWhitelist(db, filterByClass)
    local ids = {}
    for k, enabled in pairs(db.whitelist or {}) do
        if enabled then
            -- Check if this is an item (prefixed with "i:")
            local isItem = type(k) == "string" and k:match("^i:(%d+)")
            local id
            
            if isItem then
                -- Extract item ID from "i:219314"
                id = tonumber(k:match("^i:(%d+)"))
            else
                -- Regular spell ID
                id = tonumber(k)
            end
            
            if id then
                -- Apply class filter only to spells (not items)
                if filterByClass and not isItem then
                    if IsSpellForPlayerClass(id) then
                        ids[#ids + 1] = {id = id, isItem = isItem}
                    end
                else
                    ids[#ids + 1] = {id = id, isItem = isItem}
                end
            end
        end
    end
    if db.sortByName then
        table.sort(ids, function(a, b)
            local na, nb
            if a.isItem then
                na = CDPulse.GetItemNameCached and CDPulse.GetItemNameCached(a.id) or ("Item:" .. a.id)
            else
                na = GetSpellNameAndIcon(a.id) or ""
            end
            if b.isItem then
                nb = CDPulse.GetItemNameCached and CDPulse.GetItemNameCached(b.id) or ("Item:" .. b.id)
            else
                nb = GetSpellNameAndIcon(b.id) or ""
            end
            if na == nb then return a.id < b.id end
            return na < nb
        end)
    else
        table.sort(ids, function(a, b) return a.id < b.id end)
    end
    return ids
end

local DEFAULT_SOUND_NAME = "Default"

local function BuildSoundList(lsm, includeNoneFirst)
    local sounds = {}
    local seen = {}

    local function add(name)
        if not name or name == "" then return end
        if not seen[name] then
            sounds[#sounds + 1] = name
            seen[name] = true
        end
    end

    if includeNoneFirst then
        add("None")
        add(DEFAULT_SOUND_NAME)
    else
        add(DEFAULT_SOUND_NAME)
        add("None")
    end

    if lsm then
        local list = lsm:List("sound") or {}
        for i = 1, #list do
            local name = list[i]
            if name ~= "None" then
                add(name)
            end
        end
    end

    return sounds
end

-- ============================================================================
-- Custom scrollable sound dropdown (replaces UIDropDownMenu for large lists)
-- ============================================================================
local SOUND_POPUP_VISIBLE_ITEMS = 10
local SOUND_POPUP_ITEM_HEIGHT = 18

local SoundPopupFrame
local SoundPopupOverlay

local function EnsureSoundPopup()
    if SoundPopupFrame then return end

    -- Full-screen click-catcher to close when clicking outside
    SoundPopupOverlay = CreateFrame("Frame", nil, UIParent)
    SoundPopupOverlay:SetAllPoints(UIParent)
    SoundPopupOverlay:EnableMouse(true)
    SoundPopupOverlay:SetFrameStrata("DIALOG")
    SoundPopupOverlay:Hide()

    SoundPopupFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    SoundPopupFrame:SetFrameStrata("DIALOG")
    SoundPopupFrame:SetClampedToScreen(true)
    SoundPopupFrame:EnableMouse(true)
    SoundPopupFrame:Hide()

    SoundPopupFrame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    SoundPopupFrame:SetBackdropColor(0.06, 0.06, 0.06, 0.98)

    -- Close popup when clicking outside
    SoundPopupOverlay:SetScript("OnMouseDown", function()
        if SoundPopupFrame and SoundPopupFrame:IsShown() then
            SoundPopupFrame:Hide()
        end
    end)

    SoundPopupFrame:SetScript("OnHide", function()
        if SoundPopupOverlay then SoundPopupOverlay:Hide() end
    end)

    -- Scroll frame (FauxScrollFrame is lightweight + stable for long lists)
    local scroll = CreateFrame("ScrollFrame", nil, SoundPopupFrame, "FauxScrollFrameTemplate")
    SoundPopupFrame.scroll = scroll
    scroll:SetPoint("TOPLEFT", SoundPopupFrame, "TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", SoundPopupFrame, "BOTTOMRIGHT", -24, 6)

    SoundPopupFrame.buttons = {}
    for i = 1, SOUND_POPUP_VISIBLE_ITEMS do
        local b = CreateFrame("Button", nil, SoundPopupFrame)
        b:SetHeight(SOUND_POPUP_ITEM_HEIGHT)
        b:SetPoint("TOPLEFT", SoundPopupFrame, "TOPLEFT", 8, -(8 + (i - 1) * SOUND_POPUP_ITEM_HEIGHT))
        b:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)

        b.highlight = b:CreateTexture(nil, "HIGHLIGHT")
        b.highlight:SetAllPoints()
        b.highlight:SetColorTexture(0.690196, 0.149020, 1.000000, 0.14)

        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", b, "LEFT", 2, 0)
        b.text:SetJustifyH("LEFT")
        b.text:SetWordWrap(false)

        b.check = b:CreateTexture(nil, "OVERLAY")
        b.check:SetTexture("Interface/Buttons/UI-CheckBox-Check")
        b.check:SetSize(14, 14)
        b.check:SetPoint("RIGHT", b, "RIGHT", -2, 0)
        b.check:Hide()

        b:SetScript("OnClick", function(self)
            if SoundPopupFrame and SoundPopupFrame.onSelect and self.value ~= nil then
                SoundPopupFrame.onSelect(self.value)
            end
            if SoundPopupFrame then SoundPopupFrame:Hide() end
        end)

        SoundPopupFrame.buttons[i] = b
    end

    function SoundPopupFrame:Refresh()
        local items = self.items or {}
        local total = #items
        local offset = FauxScrollFrame_GetOffset(self.scroll) or 0

        for i = 1, SOUND_POPUP_VISIBLE_ITEMS do
            local idx = i + offset
            local b = self.buttons[i]
            if idx <= total then
                local name = items[idx]
                b.value = name
                b.text:SetText(name)
                b.check:SetShown(self.selected == name)
                b:Show()
            else
                b.value = nil
                b:Hide()
            end
        end

        FauxScrollFrame_Update(self.scroll, total, SOUND_POPUP_VISIBLE_ITEMS, SOUND_POPUP_ITEM_HEIGHT)
    end

    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, SOUND_POPUP_ITEM_HEIGHT, function()
            if SoundPopupFrame then SoundPopupFrame:Refresh() end
        end)
    end)

    SoundPopupFrame:SetScript("OnMouseWheel", function(_, delta)
        local sf = SoundPopupFrame and SoundPopupFrame.scroll
        if not sf then return end
        local cur = FauxScrollFrame_GetOffset(sf) or 0
        local maxOffset = math.max(0, (#(SoundPopupFrame.items or {}) - SOUND_POPUP_VISIBLE_ITEMS))
        local newOffset = cur - delta
        if newOffset < 0 then newOffset = 0 end
        if newOffset > maxOffset then newOffset = maxOffset end
        FauxScrollFrame_SetOffset(sf, newOffset)
        SoundPopupFrame:Refresh()
    end)
end

local function OpenSoundPopup(anchorFrame, sounds, selected, onSelect)
    EnsureSoundPopup()
    if not SoundPopupFrame then return end

    SoundPopupFrame.items = sounds or {}
    SoundPopupFrame.selected = selected
    SoundPopupFrame.onSelect = onSelect

    -- Fixed height: exactly ~10 items (never extends past screen due to clamping)
    local popupHeight = (SOUND_POPUP_VISIBLE_ITEMS * SOUND_POPUP_ITEM_HEIGHT) + 16
    SoundPopupFrame:SetHeight(popupHeight)

    -- Match the dropdown's visible width so it looks native / aligned
    local w = (anchorFrame and anchorFrame.GetWidth and anchorFrame:GetWidth()) or 180
    if w < 140 then w = 140 end
    SoundPopupFrame:SetWidth(w)

    SoundPopupFrame:ClearAllPoints()

    -- Open down unless we'd go off-screen; then open up.
    local openUp = false
    if anchorFrame and anchorFrame.GetBottom then
        local bottom = anchorFrame:GetBottom() or 0
        if bottom < (popupHeight + 30) then
            openUp = true
        end
    end

    if openUp then
        SoundPopupFrame:SetPoint("BOTTOMLEFT", anchorFrame, "TOPLEFT", 16, 4)
    else
        SoundPopupFrame:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 16, -2)
    end

    -- Show frames first
    SoundPopupOverlay:Show()
    SoundPopupFrame:Show()
    
    -- Reset scroll position AFTER showing (so scrollbar updates correctly)
    local scrollFrame = SoundPopupFrame.scroll
    FauxScrollFrame_SetOffset(scrollFrame, 0)
    
    -- Force scrollbar thumb to update visually
    if scrollFrame.ScrollBar then
        scrollFrame.ScrollBar:SetValue(0)
    end
    
    SoundPopupFrame:Refresh()
end

local function RegisterPanel(panel)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
        CDPulse_SettingsCategory = category
    else
        InterfaceOptions_AddCategory(panel)
    end
end

-- Global refresh function so it can be called from anywhere
local RefreshRows

local function CreateRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(36)

    -- Zebra-striping background (alternating row tint) to improve readability.
    -- This intentionally avoids borders to prevent double-border artifacts.
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    row.bg:SetColorTexture(1, 1, 1, 0) -- set per-row in RefreshRows
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(24, 24)
    row.icon:SetPoint("LEFT", row, "LEFT", 10, 0)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 10, 0)
    row.text:SetJustifyH("LEFT")
    row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.remove:SetSize(72, 22)
    row.remove:SetPoint("RIGHT", row, "RIGHT", -10, 3)
    row.remove:SetText("Remove")
    row.soundDD = CreateFrame("Frame", nil, row, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(row.soundDD, 150)
    row.soundDD:SetPoint("RIGHT", row.remove, "LEFT", -8, -3)
    row.soundPreview = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.soundPreview:SetSize(26, 22)
    row.soundPreview:SetPoint("RIGHT", row.soundDD, "LEFT", -6, 0)
    row.soundPreview:SetText("")
    row.soundPreview.tex = row.soundPreview:CreateTexture(nil, "ARTWORK")
    row.soundPreview.tex:SetSize(16, 16)
    row.soundPreview.tex:SetPoint("CENTER")
    if row.soundPreview.tex.SetAtlas then
        row.soundPreview.tex:SetAtlas("voicechat-icon-speaker")
    else
        row.soundPreview.tex:SetTexture("Interface\\COMMON\\VoiceChat-Speaker")
    end
    row.text:SetPoint("RIGHT", row.soundPreview, "LEFT", -10, 0)
    return row
end

local function CreateOptionsPanel()
    local panel = CreateFrame("Frame", "CDPulseOptionsPanel")
    panel.name = PANEL_NAME
    CDPulseOptionsPanel = panel

    local function ApplyToAddon()
        if CDPulse_ApplySettings then CDPulse_ApplySettings() end
    end

    
    -- Tab system - dynamic tab widths (based on label text) + evenly distributed gaps
    -- Goal: keep the existing left/right margins (PAD), but prevent the long first label
    -- from making the spacing look uneven by sizing each tab to its text width.
    local TEST_BTN_WIDTH = 90
    local TAB_HEIGHT = 24
    local TAB_HPAD_DEFAULT = 14  -- left/right padding inside each tab
    local TAB_HPAD_MIN = 6       -- smallest padding we'll allow if space gets tight
    local MIN_GAP = 4            -- minimum gap between elements

    local tabs, tabFrames, tabIndicators = {}, {}, {}
    local TAB_NAMES = {"Tracked Spells & Items", "Appearance & Audio", "Info"}

    local function MeasureTabWidth(btn, hpad)
        local fs = btn:GetFontString()
        local textW = 0
        if fs then
            textW = fs:GetStringWidth() or 0
        end
        btn:SetWidth(math.ceil(textW + (2 * hpad)))
        btn:SetHeight(TAB_HEIGHT)
    end

    local function SelectTab(index)
        for i = 1, #tabFrames do
            tabFrames[i]:Hide()
            tabIndicators[i]:Hide()
            tabs[i]:SetNormalFontObject("GameFontNormal")
        end
        tabFrames[index]:Show()
        tabIndicators[index]:Show()
        tabs[index]:SetNormalFontObject("GameFontHighlight")
    end

    -- Create tab buttons + frames
    for i, name in ipairs(TAB_NAMES) do
        local btn = CreateFrame("Button", nil, panel)
        btn:SetSize(110, TAB_HEIGHT) -- placeholder; real size is set in LayoutTabs()
        btn:SetNormalFontObject("GameFontNormal")
        btn:SetHighlightFontObject("GameFontHighlight")
        btn:SetText(name)
        btn:SetScript("OnClick", function() SelectTab(i) end)

        -- Temporary anchors; LayoutTabs() will reflow everything
        if i == 1 then
            btn:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -PAD)
        else
            btn:SetPoint("LEFT", tabs[i-1], "RIGHT", 8, 0)
        end
        tabs[i] = btn

        -- Purple indicator line under selected tab
        local indicator = panel:CreateTexture(nil, "ARTWORK")
        indicator:SetColorTexture(0.690196, 0.149020, 1.000000, 1)
        indicator:SetHeight(1.25)
        indicator:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
        indicator:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
        indicator:Hide()
        tabIndicators[i] = indicator

        local frame = CreateFrame("Frame", nil, panel)
        frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -50)
        frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, 0)
        frame:Hide()
        tabFrames[i] = frame
    end

    -- Test Alert button at the very top (right-aligned to preserve right margin)
    local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testBtn:SetSize(TEST_BTN_WIDTH, TAB_HEIGHT)
    testBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -PAD)
    testBtn:SetText("Test Alert")
    testBtn:SetScript("OnClick", function()
        -- Check if there are any spells in the whitelist
        local db = CDPulseDB or {}
        local hasSpells = false
        if db.whitelist then
            for k, v in pairs(db.whitelist) do
                if v then
                    hasSpells = true
                    break
                end
            end
        end

        if not hasSpells then
            -- Show error message
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000CDPulse Error:|r Add a spell to the tracked spells list to test an alert.")
            return
        end

        CDPulse_TestPulse()
    end)

    -- Layout tabs based on real text width so gaps appear visually consistent.
    local function LayoutTabs()
        -- Get actual panel width (fallback if not yet available)
        local panelWidth = panel:GetWidth()
        if not panelWidth or panelWidth <= 0 then
            panelWidth = 700
        end

        -- Lock Test Alert button to the right margin (so right margin stays perfect)
        testBtn:ClearAllPoints()
        testBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -PAD)

        -- Space available between left PAD and the left edge of the test button (excluding gaps)
        local availableWidth = panelWidth - (2 * PAD) - TEST_BTN_WIDTH

        -- Try to fit with default padding; if tight, reduce padding down to TAB_HPAD_MIN
        local hpad = TAB_HPAD_DEFAULT
        local sumTabs = 0

        local function ComputeSumWithPadding(p)
            local s = 0
            for i = 1, #tabs do
                MeasureTabWidth(tabs[i], p)
                s = s + (tabs[i]:GetWidth() or 0)
            end
            return s
        end

        sumTabs = ComputeSumWithPadding(hpad)

        while hpad > TAB_HPAD_MIN do
            local availableForGaps = availableWidth - sumTabs
            local gapCandidate = availableForGaps / (#tabs + 1)
            if gapCandidate >= MIN_GAP then
                break
            end
            hpad = hpad - 2
            sumTabs = ComputeSumWithPadding(hpad)
        end

        local availableForGaps = availableWidth - sumTabs
        local gap = availableForGaps / (#tabs + 1)
        if gap < MIN_GAP then
            gap = MIN_GAP
        end

        -- Position tabs from left margin with computed gap
        tabs[1]:ClearAllPoints()
        tabs[1]:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -PAD)
        for i = 2, #tabs do
            tabs[i]:ClearAllPoints()
            tabs[i]:SetPoint("LEFT", tabs[i-1], "RIGHT", gap, 0)
        end
    end

    -- Reflow on show/resize without clobbering other handlers
    panel:HookScript("OnSizeChanged", function()
        LayoutTabs()
    end)
    panel:HookScript("OnShow", function()
        LayoutTabs()
    end)

    -- Initial layout pass (best effort; will be corrected on show)
    LayoutTabs()

    local spellsFrame, appAudioFrame, infoFrame = tabFrames[1], tabFrames[2], tabFrames[3]

    -- Footer creator (for all tabs)
    local function CreateFooter(parent)
        local footer = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        footer:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 12, 10)
        footer:SetText("Created by: |cffb026ffCree|r")
        return footer
    end


    -- Global footer (outside all tab boxes)
    local FOOTER_GAP = -7

    local footerRegion = CreateFrame("Frame", nil, panel)
    footerRegion:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
    footerRegion:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    footerRegion:SetHeight(28)

    local globalFooter = CreateFooter(footerRegion)

    -- Re-anchor tab frames so all content sits above the global footer
    for i = 1, #tabFrames do
        local frame = tabFrames[i]
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -50)
        frame:SetPoint("BOTTOMLEFT", footerRegion, "TOPLEFT", 0, FOOTER_GAP)
        frame:SetPoint("BOTTOMRIGHT", footerRegion, "TOPRIGHT", -PAD, FOOTER_GAP)
    end

    -- TRACKED SPELLS TAB
    -- Three independent UI boxes:
    --   1) Options row (checkboxes)
    --   2) Table options (add/search)
    --   3) Tracked spells list
    local spellsOptionsContainer = CreateFrame("Frame", nil, spellsFrame, "BackdropTemplate")
    -- Use the same left/right inset so the options row lines up uniformly with the table box.
    spellsOptionsContainer:SetPoint("TOPLEFT", 2, -6)
    spellsOptionsContainer:SetPoint("TOPRIGHT", 0, -6)
    spellsOptionsContainer:SetHeight(44)
    spellsOptionsContainer:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=12, insets={left=2,right=2,top=2,bottom=2}})
    spellsOptionsContainer:SetBackdropColor(0,0,0,0.10)
    spellsOptionsContainer:SetBackdropBorderColor(0.12,0.12,0.12,0.95)

    local spellsTableOptionsContainer = CreateFrame("Frame", nil, spellsFrame, "BackdropTemplate")
spellsTableOptionsContainer:SetPoint("TOPLEFT", spellsOptionsContainer, "BOTTOMLEFT", 0, -10)
spellsTableOptionsContainer:SetPoint("TOPRIGHT", spellsOptionsContainer, "BOTTOMRIGHT", 0, -10)
spellsTableOptionsContainer:SetHeight(44)
spellsTableOptionsContainer:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=12, insets={left=2,right=2,top=2,bottom=2}})
spellsTableOptionsContainer:SetBackdropColor(0,0,0,0.10)
spellsTableOptionsContainer:SetBackdropBorderColor(0.12,0.12,0.12,0.95)

local spellsListContainer = CreateFrame("Frame", nil, spellsFrame, "BackdropTemplate")
spellsListContainer:SetPoint("TOPLEFT", spellsTableOptionsContainer, "BOTTOMLEFT", 0, -10)
spellsListContainer:SetPoint("BOTTOMRIGHT", 0, PAD)
spellsListContainer:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=12, insets={left=2,right=2,top=2,bottom=2}})
spellsListContainer:SetBackdropColor(0,0,0,0.10)
spellsListContainer:SetBackdropBorderColor(0.12,0.12,0.12,0.95)


-- Track mode selection (spell vs item)
local selectedTrackMode = "spell"  -- Default to spell mode

    -- Get player class info for the class filter
    local localizedClass, englishClass = UnitClass("player")

    -- Top control row container (ensures consistent alignment + margins)
    local ROW_H = 22
    local BTN_W = 60
    local GAP_ADD = 4
    local GAP_FEATURE = 40 -- clearer separation between Add and Search
    local GAP_CLEAR = 4

    -- Default "small" width for the Add Spell box (no more class-based sizing)
    local ADD_DEFAULT_W = 120
    local MIN_ADD_W = 90
    local MIN_SEARCH_W = 140

    -- UI-only search query for filtering the rendered list (does not change the whitelist)
    local trackedSearchQuery = ""

    local topRow = CreateFrame("Frame", nil, spellsTableOptionsContainer)
    topRow:ClearAllPoints()
    topRow:SetPoint("LEFT",  spellsTableOptionsContainer, "LEFT",  PAD, 0)
    topRow:SetPoint("RIGHT", spellsTableOptionsContainer, "RIGHT", -PAD, 0)
    topRow:SetPoint("CENTER", spellsTableOptionsContainer, "CENTER", 0, 0)
    topRow:SetHeight(ROW_H)

    local addBox = CreateFrame("EditBox", nil, spellsTableOptionsContainer, "InputBoxTemplate")
    addBox:SetHeight(ROW_H)
    addBox:SetAutoFocus(false)
    addBox:SetTextInsets(2, 8, 0, 0)
    -- Will be positioned after modeDropdown is created
    
    -- Placeholder text for the Add box
    local addPlaceholder = addBox:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    addPlaceholder:SetPoint("LEFT", addBox, "LEFT", 2, 0)
    addPlaceholder:SetJustifyH("LEFT")
    addPlaceholder:SetText("enter spell...")

    -- NOW create mode dropdown (after addPlaceholder exists)
    local modeDropdown = CreateFrame("Frame", nil, spellsTableOptionsContainer, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(modeDropdown, 143)  -- Reduced from 200 to fit text better
    UIDropDownMenu_SetText(modeDropdown, "Add Spell (ID or NAME):")
    
    -- Simple mode popup (2 options only) - NO OVERLAY to avoid double-click issue
    local modeModePopup
    
    local function ShowModePopup()
        if not modeModePopup then
            modeModePopup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            modeModePopup:SetFrameStrata("DIALOG")
            modeModePopup:SetSize(160, 48)  -- Match dropdown width
            modeModePopup:EnableMouse(true)
            modeModePopup:SetBackdrop({
                bgFile = "Interface/Tooltips/UI-Tooltip-Background",
                edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
                tile = true,
                tileSize = 16,
                edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 }
            })
            modeModePopup:SetBackdropColor(0.06, 0.06, 0.06, 0.98)
            
            -- Spell option
            local spellBtn = CreateFrame("Button", nil, modeModePopup)
            spellBtn:SetSize(154, 20)
            spellBtn:SetPoint("TOPLEFT", modeModePopup, "TOPLEFT", 3, -3)
            spellBtn.text = spellBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            spellBtn.text:SetPoint("LEFT", spellBtn, "LEFT", 5, 0)
            spellBtn.text:SetPoint("RIGHT", spellBtn, "RIGHT", -5, 0)
            spellBtn.text:SetJustifyH("LEFT")
            spellBtn.text:SetJustifyV("MIDDLE")  -- Vertical centering
            spellBtn.text:SetText("Add Spell (ID or NAME):")
            spellBtn.highlight = spellBtn:CreateTexture(nil, "HIGHLIGHT")
            spellBtn.highlight:SetAllPoints()
            spellBtn.highlight:SetColorTexture(0.690196, 0.149020, 1.000000, 0.14)
            spellBtn:SetScript("OnClick", function()
                selectedTrackMode = "spell"
                UIDropDownMenu_SetText(modeDropdown, "Add Spell (ID or NAME):")
                addPlaceholder:SetText("enter spell...")
                modeModePopup:Hide()
            end)
            
            -- Item option
            local itemBtn = CreateFrame("Button", nil, modeModePopup)
            itemBtn:SetSize(154, 20)
            itemBtn:SetPoint("TOPLEFT", spellBtn, "BOTTOMLEFT", 0, -2)
            itemBtn.text = itemBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            itemBtn.text:SetPoint("LEFT", itemBtn, "LEFT", 5, 0)
            itemBtn.text:SetPoint("RIGHT", itemBtn, "RIGHT", -5, 0)
            itemBtn.text:SetJustifyH("LEFT")
            itemBtn.text:SetJustifyV("MIDDLE")  -- Vertical centering
            itemBtn.text:SetText("Add Item (ID only):")
            itemBtn.highlight = itemBtn:CreateTexture(nil, "HIGHLIGHT")
            itemBtn.highlight:SetAllPoints()
            itemBtn.highlight:SetColorTexture(0.690196, 0.149020, 1.000000, 0.14)
            itemBtn:SetScript("OnClick", function()
                selectedTrackMode = "item"
                UIDropDownMenu_SetText(modeDropdown, "Add Item (ID only):")
                addPlaceholder:SetText("enter item ID...")
                modeModePopup:Hide()
            end)
            
            -- Close on click outside (without overlay to avoid double-click)
            modeModePopup:SetScript("OnUpdate", function(self)
                if not self:IsMouseOver() and not modeDropdown:IsMouseOver() then
                    -- Check if any child buttons are hovered
                    local anyChildHovered = false
                    for _, child in pairs({self:GetChildren()}) do
                        if child:IsMouseOver() then
                            anyChildHovered = true
                            break
                        end
                    end
                    if not anyChildHovered then
                        self:Hide()
                    end
                end
            end)
        end
        
        -- Position popup
        modeModePopup:ClearAllPoints()
        modeModePopup:SetPoint("TOPLEFT", modeDropdown, "BOTTOMLEFT", 15, 5)
        modeModePopup:Show()
    end
    
    -- Override dropdown button to show our popup
    if modeDropdown and modeDropdown.Button then
        modeDropdown.Button:SetScript("OnClick", function()
            if modeModePopup and modeModePopup:IsShown() then
                modeModePopup:Hide()
            else
                ShowModePopup()
            end
        end)
    end

    -- Position elements
    modeDropdown:ClearAllPoints()
    modeDropdown:SetPoint("LEFT", topRow, "LEFT", -14, -3)  -- Slight vertical adjustment for UIDropDownMenu
    
    addBox:SetPoint("LEFT", modeDropdown, "RIGHT", -6, 3)

local function UpdateAddUI()
    local txt = addBox:GetText() or ""
    local hasText = (txt:match("%S") ~= nil)
    if addBox:HasFocus() or hasText then
        addPlaceholder:Hide()
    else
        addPlaceholder:Show()
    end
end


    local addBtn = CreateFrame("Button", nil, spellsTableOptionsContainer, "UIPanelButtonTemplate")
    addBtn:SetSize(BTN_W, ROW_H)
    addBtn:SetPoint("LEFT", addBox, "RIGHT", GAP_ADD, 0)
    addBtn:SetText("Add")

    -- Search box + clear button
    local searchBox = CreateFrame("EditBox", nil, spellsTableOptionsContainer, "InputBoxTemplate")
    searchBox:SetHeight(ROW_H)
    searchBox:SetAutoFocus(false)
    searchBox:SetTextInsets(2, 8, 0, 0)
    -- Leave extra space between the "Add" feature and the "Search" feature
    searchBox:SetPoint("LEFT", addBtn, "RIGHT", GAP_FEATURE, 0)

    local clearBtn = CreateFrame("Button", nil, spellsTableOptionsContainer, "UIPanelButtonTemplate")
    clearBtn:SetSize(BTN_W, ROW_H) -- match Add button size
    clearBtn:SetPoint("RIGHT", topRow, "RIGHT", 0, 0)
    clearBtn:SetText("Clear")
    clearBtn:Disable()

    -- Search box expands to take as much remaining space as possible (within margins)
    searchBox:SetPoint("RIGHT", clearBtn, "LEFT", -GAP_CLEAR, 10)

    -- Placeholder text for the search box
    local searchPlaceholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    searchPlaceholder:SetPoint("LEFT", searchBox, "LEFT", 2, 0)
    searchPlaceholder:SetJustifyH("LEFT")
    searchPlaceholder:SetText("search tracked...")

    local function UpdateSearchUI()
        local txt = searchBox:GetText() or ""
        local hasText = (txt:match("%S") ~= nil)
        if searchBox:HasFocus() or hasText then
            searchPlaceholder:Hide()
        else
            searchPlaceholder:Show()
        end
        if hasText then clearBtn:Enable() else clearBtn:Disable() end
    end

    -- Ensure the Add box stays "small" by default, and shrink it only if needed to keep Search visible.
    local function LayoutTopRow()
        local contW = topRow:GetWidth()
        if not contW or contW <= 0 then return end

        local dropdownW = 160  -- Fixed width of modeDropdown (reduced from 200)

        -- Space available for BOTH input boxes (addBox + searchBox)
        local availableForInputs =
            contW
            - dropdownW
            - (GAP_ADD + GAP_ADD + GAP_FEATURE + GAP_CLEAR) -- dropdown->addBox, addBox->addBtn, addBtn->searchBox, searchBox->clearBtn
            - (BTN_W + BTN_W) -- Add + Clear buttons

        if availableForInputs <= 0 then return end

        local addW = ADD_DEFAULT_W

        -- Try to preserve a reasonable minimum width for the search box.
        local maxAddW = availableForInputs - MIN_SEARCH_W
        if maxAddW < MIN_ADD_W then maxAddW = MIN_ADD_W end

        if addW > maxAddW then addW = maxAddW end
        if addW < MIN_ADD_W then addW = MIN_ADD_W end

        addBox:SetWidth(addW)
        -- searchBox width is driven by anchors (it takes all remaining space).
    end

    spellsTableOptionsContainer:HookScript("OnSizeChanged", LayoutTopRow)
    spellsTableOptionsContainer:HookScript("OnShow", LayoutTopRow)

    -- Initialize layout and placeholder state
    LayoutTopRow()
    UpdateSearchUI()
    UpdateAddUI()

-- Options row (same line)
    local sort = CreateFrame("CheckButton", nil, spellsOptionsContainer, "UICheckButtonTemplate")
    sort:SetPoint("LEFT", spellsOptionsContainer, "LEFT", PAD, 0)
    sort.text = sort:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sort.text:SetPoint("LEFT", sort, "RIGHT", 4, 0)
    sort.text:SetText("Sort by name")

    -- Class filter checkbox with class-colored label
    local classFilter = CreateFrame("CheckButton", nil, spellsOptionsContainer, "UICheckButtonTemplate")
    classFilter:SetPoint("LEFT", sort.text, "RIGHT", 20, 0)
    classFilter.text = classFilter:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    
    -- Color the class name portion of the label
    local classColorText = localizedClass .. " only"
    if C_ClassColor and C_ClassColor.GetClassColor then
        local classColor = C_ClassColor.GetClassColor(englishClass)
        if classColor then
            -- Use WrapTextInColorCode for reliable coloring, only color the class name
            local coloredClassName = classColor:WrapTextInColorCode(localizedClass)
            classColorText = coloredClassName .. " spells only"
        end
    end
    classFilter.text:SetText(classColorText)
    classFilter.text:SetPoint("LEFT", classFilter, "RIGHT", 4, 0)

    -- New (no-behavior-yet) checkbox
    local showSpellIDs = CreateFrame("CheckButton", nil, spellsOptionsContainer, "UICheckButtonTemplate")
    showSpellIDs:SetPoint("LEFT", classFilter.text, "RIGHT", 20, 0)
    showSpellIDs.text = showSpellIDs:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showSpellIDs.text:SetPoint("LEFT", showSpellIDs, "RIGHT", 4, 0)
    showSpellIDs.text:SetText("Show spell & item IDs in tooltips")

    local scrollFrame = CreateFrame("ScrollFrame", nil, spellsListContainer, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", spellsListContainer, "TOPLEFT", PAD, -PAD)
    scrollFrame:SetPoint("BOTTOMRIGHT", spellsListContainer, "BOTTOMRIGHT", -28, PAD)
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(800)  -- Fixed width, will be updated on show
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)
    
    -- Update scrollChild width when scrollFrame is shown/sized
    scrollFrame:HookScript("OnShow", function(self)
        local width = self:GetWidth()
        if width and width > 0 then
            scrollChild:SetWidth(width)
        end
    end)

    local rows = {}
    local ROW_HEIGHT = 36

    local function NormalizeSearchQuery(q)
        q = (q or ""):lower()
        q = q:gsub("^%s+", ""):gsub("%s+$", "")
        return q
    end

    local function ApplySearchFilter(ids, q)
        local nq = NormalizeSearchQuery(q)
        if nq == "" then return ids end
        local out = {}
        local isNum = (nq:match("^%d+$") ~= nil)

        for _, entry in ipairs(ids) do
            local actualID = entry.id or entry  -- Handle both old (number) and new ({id, isItem}) format
            local isItem = entry.isItem or false
            
            if isNum then
                if tostring(actualID):find(nq, 1, true) then
                    table.insert(out, entry)
                end
            else
                local name
                if isItem then
                    name = CDPulse.GetItemNameCached and CDPulse.GetItemNameCached(actualID)
                else
                    name = (C_Spell and C_Spell.GetSpellName) and C_Spell.GetSpellName(actualID) or nil
                end
                if name and name:lower():find(nq, 1, true) then
                    table.insert(out, entry)
                end
            end
        end

        return out
    end

    RefreshRows = function()
        -- Always use the global CDPulseDB directly to ensure we're reading the same data
        local db = CDPulseDB or {}
        db.whitelist = db.whitelist or {}
        db.spellSounds = db.spellSounds or {}
        
        -- Apply class filter if enabled
        local filterByClass = db.classFilterEnabled and true or false
        local sortedIDs = SortWhitelist(db, filterByClass)
        local displayIDs = ApplySearchFilter(sortedIDs, trackedSearchQuery)
        local lsm = GetLSM()
        local sounds = BuildSoundList(lsm, false)
        
        -- Update scrollChild width
        local scrollWidth = scrollFrame:GetWidth()
        if scrollWidth and scrollWidth > 0 then
            scrollChild:SetWidth(scrollWidth)
        end
        
        -- Hide all existing rows first
        for _, row in ipairs(rows) do 
            row:Hide() 
        end
        
        -- Create/update rows for each spell/item
        for i, entry in ipairs(displayIDs) do
            local actualID = entry.id or entry  -- Handle both old (number) and new ({id, isItem}) format
            local isItem = entry.isItem or false
            
            local row = rows[i] or CreateRow(scrollChild)
            rows[i] = row
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(i-1)*ROW_HEIGHT)
            row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
            row:Show()

            -- Zebra striping (alternating row tint).
            -- Keep it subtle so it doesn't fight the container border/background.
            if row.bg then
                if (i % 2) == 0 then
                    row.bg:SetColorTexture(1, 1, 1, 0.035)
                else
                    row.bg:SetColorTexture(1, 1, 1, 0)
                end
            end
            
            local name, icon
            if isItem then
                name = CDPulse.GetItemNameCached and CDPulse.GetItemNameCached(actualID)
                if not name then
                    name = "Loading..."  -- Show loading state instead of Item:ID
                end
                -- Get item icon
                if C_Item and C_Item.GetItemIconByID then
                    local ok, itemIcon = pcall(C_Item.GetItemIconByID, actualID)
                    if ok and itemIcon then
                        icon = itemIcon
                    end
                end
                row.text:SetText(string.format("%s\n|cFFB026FF(Item ID: %d)|r", name, actualID))
            else
                name, icon = GetSpellNameAndIcon(actualID)
                row.text:SetText(string.format("%s\n|cFFB026FF(ID: %d)|r", name or "Unknown", actualID))
            end

            if icon then 
                row.icon:SetTexture(icon)
                row.icon:Show() 
            else 
                row.icon:Hide() 
            end
            
            -- Capture ID in closure
            local capturedID = actualID
            local capturedIsItem = isItem
            
            row.remove:SetScript("OnClick", function()
                if capturedIsItem then
                    -- Remove item with "i:" prefix
                    db.whitelist["i:" .. tostring(capturedID)] = nil
                    db.spellSounds["i:" .. tostring(capturedID)] = nil
                else
                    -- Remove spell (both string + numeric keys for compatibility)
                    db.whitelist[tostring(capturedID)] = nil
                    db.whitelist[capturedID] = nil
                    db.spellSounds[tostring(capturedID)] = nil
                    db.spellSounds[capturedID] = nil
                end
                ApplyToAddon()
                RefreshRows()
            end)
            
            -- Sound dropdown (custom scrollable popup)
            local capturedSounds = sounds
            local function setSoundChoice(sname)
                local key = capturedIsItem and ("i:" .. tostring(capturedID)) or tostring(capturedID)
                db.spellSounds[key] = sname
                UIDropDownMenu_SetText(row.soundDD, sname)

                -- Keep runtime + UI in sync immediately
                ApplyToAddon()
                RefreshRows()
            end

            -- Always set visible text to current selection
            local key = capturedIsItem and ("i:" .. tostring(capturedID)) or tostring(capturedID)
            local selectedSound = db.spellSounds[key] or (db.soundName or DEFAULT_SOUND_NAME)
            UIDropDownMenu_SetText(row.soundDD, selectedSound)

            -- Override default UIDropDownMenu click and show our popup instead
            if row.soundDD and row.soundDD.Button then
                row.soundDD.Button:SetScript("OnClick", function()
                    local cur = db.spellSounds[key] or (db.soundName or DEFAULT_SOUND_NAME)
                    OpenSoundPopup(row.soundDD, capturedSounds, cur, setSoundChoice)
                end)
            end
            
            -- Preview button
            row.soundPreview:SetScript("OnClick", function()
                local sndName = db.spellSounds[key] or db.soundName or DEFAULT_SOUND_NAME or "None"
                if sndName == "None" then return end

                -- "Default" is a Blizzard UI sound (not an LSM file)
                if sndName == "Default" then
                    -- Match CDPulse-1.2.0 exactly
                    PlaySound(db.fallbackSoundKitID or 12867, db.soundChannel or "Master")
                    return
                end

                local path
                if lsm then path = lsm:Fetch("sound", sndName, true) end
                if path then
                    PlaySoundFile(path, db.soundChannel or "Master")
                else
                    PlaySound(db.fallbackSoundKitID or 12867, db.soundChannel or "Master")
                end
            end)
        end
        
        scrollChild:SetHeight(math.max(1, #displayIDs * ROW_HEIGHT))
    end
    
    -- Export RefreshRows for async item name loading (using CDPulse namespace)
    CDPulse.RefreshOptionsRows = RefreshRows

    addBtn:SetScript("OnClick", function()
        local input = addBox:GetText()
        
        if selectedTrackMode == "spell" then
            -- Spell mode: Support ID or name
            local spellID = ResolveSpellID(input)
            if spellID then
                local db = EnsureDB()
                db.whitelist[tostring(spellID)] = true

                -- New tracked spells should default to "Default" sound (legacy behavior)
                if not db.spellSounds then db.spellSounds = {} end
                if db.spellSounds[tostring(spellID)] == nil then
                    local base = db.soundName
                    if not base or base == "" or base == "None" then base = "Default" end
                    db.spellSounds[tostring(spellID)] = base
                end
                addBox:SetText("")
                ApplyToAddon()
                RefreshRows()
            else
                -- Show error if input was provided but couldn't be resolved
                if input and input:match("%S") then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffff0000CDPulse Error:|r Invalid spell name or spell ID.")
                end
            end
        else
            -- Item mode: ID or link only
            if not input or not input:match("%S") then
                return
            end
            
            -- Parse item ID from input (supports both raw ID and item links)
            local itemID = tonumber(input)
            if not itemID then
                -- Try parsing item link
                local linkID = input:match("item:(%d+)")
                itemID = tonumber(linkID)
            end
            
            if itemID and itemID > 0 then
                local ok, err = CDPulse_Engine:AddItem(itemID)
                if ok then
                    addBox:SetText("")
                    ApplyToAddon()
                    RefreshRows()
                else
                    DEFAULT_CHAT_FRAME:AddMessage("|cffff0000CDPulse Error:|r " .. tostring(err))
                end
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000CDPulse Error:|r Invalid item ID or item link.")
            end
        end
    end)
    addBox:SetScript("OnEnterPressed", function() addBtn:Click() end)
addBox:SetScript("OnTextChanged", function() UpdateAddUI() end)
addBox:SetScript("OnEditFocusGained", function() UpdateAddUI() end)
addBox:SetScript("OnEditFocusLost", function() UpdateAddUI() end)
addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); UpdateAddUI() end)


    -- Render-only search filter for the tracked spells list
    searchBox:SetScript("OnTextChanged", function(self)
        trackedSearchQuery = self:GetText() or ""
        UpdateSearchUI()
        RefreshRows()
    end)
    searchBox:SetScript("OnEditFocusGained", function() UpdateSearchUI() end)
    searchBox:SetScript("OnEditFocusLost", function() UpdateSearchUI() end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); UpdateSearchUI() end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); UpdateSearchUI() end)

    clearBtn:SetScript("OnClick", function()
        searchBox:SetText("")
        searchBox:ClearFocus()
        -- OnTextChanged handles RefreshRows + UI state
    end)
    sort:SetScript("OnClick", function()
        local db = EnsureDB()
        db.sortByName = sort:GetChecked() and true or false
        RefreshRows()
    end)
    classFilter:SetScript("OnClick", function()
        local db = EnsureDB()
        db.classFilterEnabled = classFilter:GetChecked() and true or false
        MarkClassSpellCacheDirty()
        RefreshRows()
    end)

    -- Intentionally no functional behavior yet; persist the toggle for future use.
    showSpellIDs:SetScript("OnClick", function()
        local db = EnsureDB()
        db.showSpellIDsInTooltips = showSpellIDs:GetChecked() and true or false
    end)

    -- APPEARANCE & AUDIO TAB (combined)
    -- Layout: "Enabled in" box at top (fixed height), Audio box at bottom (fixed height),
    -- Appearance box fills the remaining space between them.

    -- "Enabled in" box (fixed height, anchored to top)
    local enabledInContainer = CreateFrame("Frame", nil, appAudioFrame, "BackdropTemplate")
    enabledInContainer:SetPoint("TOPLEFT", appAudioFrame, "TOPLEFT", 2, -6)
    enabledInContainer:SetPoint("TOPRIGHT", appAudioFrame, "TOPRIGHT", 0, -6)
    enabledInContainer:SetHeight(44)
    enabledInContainer:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=12, insets={left=2,right=2,top=2,bottom=2}})
    enabledInContainer:SetBackdropColor(0,0,0,0.10)
    enabledInContainer:SetBackdropBorderColor(0.12,0.12,0.12,0.95)

    local enabledInLabel = enabledInContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    enabledInLabel:SetPoint("LEFT", enabledInContainer, "LEFT", PAD, 0)
    enabledInLabel:SetText("Enabled in:")

    local ZONE_CB_GAP = 35  -- even spacing between label→first checkbox and between checkboxes

    local zoneWorld = CreateFrame("CheckButton", nil, enabledInContainer, "UICheckButtonTemplate")
    zoneWorld:SetPoint("LEFT", enabledInLabel, "RIGHT", ZONE_CB_GAP - 15, 0)
    zoneWorld.text = zoneWorld:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    zoneWorld.text:SetPoint("LEFT", zoneWorld, "RIGHT", 4, 0)
    zoneWorld.text:SetText("World")

    local zoneDungeons = CreateFrame("CheckButton", nil, enabledInContainer, "UICheckButtonTemplate")
    zoneDungeons:SetPoint("LEFT", zoneWorld.text, "RIGHT", ZONE_CB_GAP, 0)
    zoneDungeons.text = zoneDungeons:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    zoneDungeons.text:SetPoint("LEFT", zoneDungeons, "RIGHT", 4, 0)
    zoneDungeons.text:SetText("Dungeons")

    local zoneRaids = CreateFrame("CheckButton", nil, enabledInContainer, "UICheckButtonTemplate")
    zoneRaids:SetPoint("LEFT", zoneDungeons.text, "RIGHT", ZONE_CB_GAP, 0)
    zoneRaids.text = zoneRaids:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    zoneRaids.text:SetPoint("LEFT", zoneRaids, "RIGHT", 4, 0)
    zoneRaids.text:SetText("Raids")

    local zoneArena = CreateFrame("CheckButton", nil, enabledInContainer, "UICheckButtonTemplate")
    zoneArena:SetPoint("LEFT", zoneRaids.text, "RIGHT", ZONE_CB_GAP, 0)
    zoneArena.text = zoneArena:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    zoneArena.text:SetPoint("LEFT", zoneArena, "RIGHT", 4, 0)
    zoneArena.text:SetText("Arena")

    local function OnZoneCheckboxClick()
        local db = EnsureDB()
        db.enabledInWorld = zoneWorld:GetChecked() and true or false
        db.enabledInDungeons = zoneDungeons:GetChecked() and true or false
        db.enabledInRaids = zoneRaids:GetChecked() and true or false
        db.enabledInArena = zoneArena:GetChecked() and true or false
        -- Update cached zone state in the engine immediately
        if CDPulse_Engine and CDPulse_Engine._EvaluateZoneEnabled then
            CDPulse_Engine:_EvaluateZoneEnabled()
        end
    end
    zoneWorld:SetScript("OnClick", OnZoneCheckboxClick)
    zoneDungeons:SetScript("OnClick", OnZoneCheckboxClick)
    zoneRaids:SetScript("OnClick", OnZoneCheckboxClick)
    zoneArena:SetScript("OnClick", OnZoneCheckboxClick)

    -- Audio box (fixed height, anchored to bottom)
    local audioContainer = CreateFrame("Frame", nil, appAudioFrame, "BackdropTemplate")
    audioContainer:SetPoint("BOTTOMLEFT", appAudioFrame, "BOTTOMLEFT", 2, PAD)
    audioContainer:SetPoint("BOTTOMRIGHT", appAudioFrame, "BOTTOMRIGHT", 0, PAD)
    audioContainer:SetHeight(80)
    audioContainer:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=12, insets={left=2,right=2,top=2,bottom=2}})
    audioContainer:SetBackdropColor(0,0,0,0.10)
    audioContainer:SetBackdropBorderColor(0.12,0.12,0.12,0.95)

    -- Audio header (inside box, white text)
    local audioHeader = audioContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    audioHeader:SetPoint("TOPLEFT", PAD, -PAD)
    audioHeader:SetText("Audio")
    audioHeader:SetTextColor(1, 1, 1)

    -- Audio row: Enable sound checkbox + Sound Channel label + dropdown (same line)
    local enableSound = CreateFrame("CheckButton", nil, audioContainer, "UICheckButtonTemplate")
    enableSound:SetPoint("TOPLEFT", audioHeader, "BOTTOMLEFT", 0, -8)
    enableSound.text = enableSound:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    enableSound.text:SetPoint("LEFT", enableSound, "RIGHT", 4, 0)
    enableSound.text:SetText("Enable sound")
    local channelLabel = audioContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    channelLabel:SetPoint("LEFT", enableSound.text, "RIGHT", 24, 0)
    channelLabel:SetText("Sound Channel:")
    local channelDD = CreateFrame("Frame", nil, audioContainer, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(channelDD, 160)
    channelDD:SetPoint("LEFT", channelLabel, "RIGHT", -10, -3)
    local CHANNELS = {"Master", "SFX", "Music", "Ambience", "Dialog"}
    local function InitChannelDropdown()
        local db = EnsureDB()
        UIDropDownMenu_Initialize(channelDD, function(_, level)
            for _, ch in ipairs(CHANNELS) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = ch
                info.checked = (db.soundChannel == ch)
                info.func = function() db.soundChannel = ch; UIDropDownMenu_SetText(channelDD, ch) end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        UIDropDownMenu_SetText(channelDD, db.soundChannel or "Master")
    end
    enableSound:SetScript("OnClick", function()
        local db = EnsureDB()
        db.soundEnabled = enableSound:GetChecked() and true or false
        InitChannelDropdown()
    end)

    -- Appearance box (fills space between "Enabled in" and Audio boxes)
    local appearanceContainer = CreateFrame("Frame", nil, appAudioFrame, "BackdropTemplate")
    appearanceContainer:SetPoint("TOPLEFT", enabledInContainer, "BOTTOMLEFT", 0, -10)
    appearanceContainer:SetPoint("RIGHT", appAudioFrame, "RIGHT", 0, 0)
    appearanceContainer:SetPoint("BOTTOM", audioContainer, "TOP", 0, 10)
    appearanceContainer:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=12, insets={left=2,right=2,top=2,bottom=2}})
    appearanceContainer:SetBackdropColor(0,0,0,0.10)
    appearanceContainer:SetBackdropBorderColor(0.12,0.12,0.12,0.95)

    -- Appearance header (inside box, white text — positioned by LayoutAppearance)
    local appHeader = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    appHeader:SetText("Appearance")
    appHeader:SetTextColor(1, 1, 1)

    -- Create all appearance controls (anchors set dynamically by LayoutAppearance)

    -- Queue overlapping alerts (top-most setting)
    local noOverlap = CreateFrame("CheckButton", nil, appearanceContainer, "UICheckButtonTemplate")
    noOverlap.text = noOverlap:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noOverlap.text:SetPoint("LEFT", noOverlap, "RIGHT", 4, 0)
    noOverlap.text:SetText("Queue overlapping alerts")
    noOverlap:SetScript("OnClick", function()
        local db = EnsureDB()
        db.noOverlapAlerts = noOverlap:GetChecked() and true or false
    end)

    -- Lock position
    local lock = CreateFrame("CheckButton", nil, appearanceContainer, "UICheckButtonTemplate")
    lock.text = lock:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lock.text:SetPoint("LEFT", lock, "RIGHT", 4, 0)
    lock.text:SetText("Lock position")
    lock:SetScript("OnClick", function()
        local db = EnsureDB()
        db.locked = lock:GetChecked() and true or false
        ApplyToAddon()
        if db.locked then CDPulse_HideAnchor() else CDPulse_ShowAnchor() end
    end)

    -- Position row
    local posLabel = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    posLabel:SetText("Position:")
    local xLabel = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    xLabel:SetPoint("LEFT", posLabel, "RIGHT", 8, 0)
    xLabel:SetText("X:")
    local xBox = CreateFrame("EditBox", nil, appearanceContainer, "InputBoxTemplate")
    xBox:SetSize(60, 20); xBox:SetPoint("LEFT", xLabel, "RIGHT", 4, 0); xBox:SetAutoFocus(false)
    local yLabel = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    yLabel:SetPoint("LEFT", xBox, "RIGHT", 12, 0)
    yLabel:SetText("Y:")
    local yBox = CreateFrame("EditBox", nil, appearanceContainer, "InputBoxTemplate")
    yBox:SetSize(60, 20); yBox:SetPoint("LEFT", yLabel, "RIGHT", 4, 0); yBox:SetAutoFocus(false)
    local posApplyBtn = CreateFrame("Button", nil, appearanceContainer, "UIPanelButtonTemplate")
    posApplyBtn:SetSize(60, 20)
    posApplyBtn:SetPoint("LEFT", yBox, "RIGHT", 8, 0)
    posApplyBtn:SetText("Apply")

    local function ApplyPosition()
        local db = EnsureDB()
        local x, y = tonumber(xBox:GetText()), tonumber(yBox:GetText())
        if x then db.x = math.floor(x + 0.5) end
        if y then db.y = math.floor(y + 0.5) end
        ApplyToAddon()
    end
    xBox:SetScript("OnEnterPressed", function(s) s:ClearFocus(); ApplyPosition() end)
    yBox:SetScript("OnEnterPressed", function(s) s:ClearFocus(); ApplyPosition() end)
    posApplyBtn:SetScript("OnClick", ApplyPosition)

    -- Sliders
    local SLIDER_INTERNAL_GAP = 12  -- fixed gap between a slider's label and its track
    local function CreateSlider(parent, minVal, maxVal, step)
        local slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
        slider:SetMinMaxValues(minVal, maxVal)
        slider:SetValueStep(step)
        slider:SetObeyStepOnDrag(true)
        slider:SetWidth(200)
        if slider.Low then slider.Low:SetText(tostring(minVal)) end
        if slider.High then slider.High:SetText(tostring(maxVal)) end
        if slider.Text then slider.Text:SetText("") end
        return slider
    end

    local durLabel = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    durLabel:SetText("Fade Duration:")
    local durSlider = CreateSlider(appearanceContainer, 0.1, 2.0, 0.05)
    durSlider:SetPoint("TOPLEFT", durLabel, "BOTTOMLEFT", 0, -SLIDER_INTERNAL_GAP)
    local durValue = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    durValue:SetPoint("LEFT", durSlider, "RIGHT", 8, 0)

    local sizeLabel = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sizeLabel:SetText("Icon Size:")
    local sizeSlider = CreateSlider(appearanceContainer, 32, 512, 1)
    sizeSlider:SetPoint("TOPLEFT", sizeLabel, "BOTTOMLEFT", 0, -SLIDER_INTERNAL_GAP)
    local sizeValue = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sizeValue:SetPoint("LEFT", sizeSlider, "RIGHT", 8, 0)

    local opacityLabel = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    opacityLabel:SetText("Icon Opacity:")
    local opacitySlider = CreateSlider(appearanceContainer, 0.1, 1.0, 0.05)
    opacitySlider:SetPoint("TOPLEFT", opacityLabel, "BOTTOMLEFT", 0, -SLIDER_INTERNAL_GAP)
    local opacityValue = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    opacityValue:SetPoint("LEFT", opacitySlider, "RIGHT", 8, 0)

    durSlider:SetScript("OnValueChanged", function(_, v)
        local db = EnsureDB()
        v = math.floor(v*100+0.5)/100
        db.pulseDuration = v
        durValue:SetText(string.format("%.2f", v))
        ApplyToAddon()
    end)
    sizeSlider:SetScript("OnValueChanged", function(_, v)
        local db = EnsureDB()
        v = math.floor(v+0.5)
        db.size = v
        sizeValue:SetText(tostring(v))
        ApplyToAddon()
    end)
    opacitySlider:SetScript("OnValueChanged", function(_, v)
        local db = EnsureDB()
        v = math.floor(v*100+0.5)/100
        db.iconOpacity = v
        opacityValue:SetText(string.format("%d%%", math.floor(v*100+0.5)))
        ApplyToAddon()
    end)

    -- Reset-to-defaults button
    local resetBtn = CreateFrame("Button", nil, appearanceContainer, "UIPanelButtonTemplate")
    resetBtn:SetSize(260, 34)
    resetBtn:SetText("Reset to default appearance")

    -- Dynamic vertical layout: distribute all 8 appearance groups evenly
    -- Item heights (approximate): header=16, checkbox=26, posRow=20, sliderGroup=44, resetBtn=34
    local ITEM_HEIGHTS = { 16, 26, 26, 20, 44, 44, 44, 34 }
    local TOTAL_ITEM_H = 0
    for _, h in ipairs(ITEM_HEIGHTS) do TOTAL_ITEM_H = TOTAL_ITEM_H + h end

    local function LayoutAppearance()
        local containerH = appearanceContainer:GetHeight()
        if not containerH or containerH <= 0 then return end

        -- Usable region: inside top and bottom padding
        local topPad = PAD
        local bottomPad = PAD
        local usable = containerH - topPad - bottomPad
        if usable <= 0 then return end

        local gapSpace = usable - TOTAL_ITEM_H
        local gap = gapSpace / (#ITEM_HEIGHTS - 1)
        if gap < 2 then gap = 2 end

        local y = -topPad  -- starting Y offset from container top

        -- 1. header
        appHeader:ClearAllPoints()
        appHeader:SetPoint("TOPLEFT", appearanceContainer, "TOPLEFT", PAD, y)
        y = y - ITEM_HEIGHTS[1] - gap

        -- 2. noOverlap
        noOverlap:ClearAllPoints()
        noOverlap:SetPoint("TOPLEFT", appearanceContainer, "TOPLEFT", PAD, y)
        y = y - ITEM_HEIGHTS[2] - gap

        -- 3. lock
        lock:ClearAllPoints()
        lock:SetPoint("TOPLEFT", appearanceContainer, "TOPLEFT", PAD, y)
        y = y - ITEM_HEIGHTS[3] - gap

        -- 4. position row
        posLabel:ClearAllPoints()
        posLabel:SetPoint("TOPLEFT", appearanceContainer, "TOPLEFT", PAD, y)
        y = y - ITEM_HEIGHTS[4] - gap

        -- 5. fade duration (label, slider is anchored 12px below label automatically)
        durLabel:ClearAllPoints()
        durLabel:SetPoint("TOPLEFT", appearanceContainer, "TOPLEFT", PAD, y)
        y = y - ITEM_HEIGHTS[5] - gap

        -- 6. icon size
        sizeLabel:ClearAllPoints()
        sizeLabel:SetPoint("TOPLEFT", appearanceContainer, "TOPLEFT", PAD, y)
        y = y - ITEM_HEIGHTS[6] - gap

        -- 7. icon opacity
        opacityLabel:ClearAllPoints()
        opacityLabel:SetPoint("TOPLEFT", appearanceContainer, "TOPLEFT", PAD, y)
        y = y - ITEM_HEIGHTS[7] - gap

        -- 8. reset button
        resetBtn:ClearAllPoints()
        resetBtn:SetPoint("TOPLEFT", appearanceContainer, "TOPLEFT", PAD, y)
    end

    appearanceContainer:HookScript("OnSizeChanged", LayoutAppearance)
    appearanceContainer:HookScript("OnShow", LayoutAppearance)

    local function SetSliderValueSilently(slider, value)
        local cb = slider:GetScript("OnValueChanged")
        slider:SetScript("OnValueChanged", nil)
        slider:SetValue(value)
        slider:SetScript("OnValueChanged", cb)
    end

    resetBtn:SetScript("OnClick", function()
        local db = EnsureDB()

        -- Reset ONLY the Appearance settings.
        for k, v in pairs(APPEARANCE_DEFAULTS) do
            db[k] = v
        end

        -- Sync UI controls
        lock:SetChecked(db.locked and true or false)
        noOverlap:SetChecked(db.noOverlapAlerts and true or false)
        xBox:SetText(tostring(db.x or 0))
        yBox:SetText(tostring(db.y or 120))

        SetSliderValueSilently(durSlider, db.pulseDuration or 0.60)
        durValue:SetText(string.format("%.2f", db.pulseDuration or 0.60))

        SetSliderValueSilently(sizeSlider, db.size or 64)
        sizeValue:SetText(tostring(db.size or 64))

        SetSliderValueSilently(opacitySlider, db.iconOpacity or 1)
        opacityValue:SetText(string.format("%d%%", math.floor((db.iconOpacity or 1) * 100 + 0.5)))

        ApplyToAddon()
        if db.locked then
            if CDPulse_HideAnchor then CDPulse_HideAnchor() end
        else
            if CDPulse_ShowAnchor then CDPulse_ShowAnchor() end
        end
    end)

    -- INFO TAB
    local infoContainer = CreateFrame("Frame", nil, infoFrame, "BackdropTemplate")
    infoContainer:SetPoint("TOPLEFT", 2, -6)
    infoContainer:SetPoint("BOTTOMRIGHT", 0, PAD)
    infoContainer:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=12, insets={left=2,right=2,top=2,bottom=2}})
    infoContainer:SetBackdropColor(0,0,0,0.10)
    infoContainer:SetBackdropBorderColor(0.12,0.12,0.12,0.95)

    local debugCB = CreateFrame("CheckButton", nil, infoContainer, "UICheckButtonTemplate")
    debugCB:SetPoint("TOPLEFT", PAD, -PAD)
    debugCB.text = debugCB:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    debugCB.text:SetPoint("LEFT", debugCB, "RIGHT", 4, 0)
    debugCB.text:SetText("Debug mode")
    debugCB:SetScript("OnClick", function()
        local db = EnsureDB()
        db.debug = debugCB:GetChecked() and true or false
        local msg = db.debug and "|cffb026ffCDPulse|r: Debug mode enabled." or "|cffb026ffCDPulse|r: Debug mode disabled."
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end)

    local cmdCard = CreateFrame("Frame", nil, infoContainer, "BackdropTemplate")
    cmdCard:SetPoint("TOPLEFT", debugCB, "BOTTOMLEFT", 0, -14)
    cmdCard:SetPoint("RIGHT", -PAD, 0)
    cmdCard:SetHeight(245)
    cmdCard:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=12, insets={left=2,right=2,top=2,bottom=2}})
    cmdCard:SetBackdropColor(0,0,0,0.15)
    cmdCard:SetBackdropBorderColor(0.12,0.12,0.12,0.95)
    local cmdTitle = cmdCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cmdTitle:SetPoint("TOPLEFT", 10, -10)
    cmdTitle:SetText("Slash Commands")
    local cmdText = cmdCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cmdText:SetPoint("TOPLEFT", cmdTitle, "BOTTOMLEFT", 0, -8)
    cmdText:SetPoint("RIGHT", -10, 0)
    cmdText:SetJustifyH("LEFT")
    cmdText:SetJustifyV("TOP")
    cmdText:SetText("/cdpulse - Open settings\n\r/cdp - Open settings\n\r/cdp add <spellID> - Add spell to whitelist\n\r/cdp additem <itemID|link> - Add item to whitelist\n\r/cdp remove <spellID> - Remove spell\n\r/cdp removeitem <itemID|link> - Remove item\n\r/cdp list - List tracked spells & items\n\r/cdp test [spellID] - Test pulse\n\r/cdp debug - Toggle debug logging\n\r/cdp log - Open debug log window (works in combat)\n\r/cdp dump - Dump engine state")

    -- OnShow handler - refresh all state
    panel:SetScript("OnShow", function()
        local db = EnsureDB()
        sort:SetChecked(db.sortByName and true or false)
        classFilter:SetChecked(db.classFilterEnabled and true or false)
        showSpellIDs:SetChecked(db.showSpellIDsInTooltips and true or false)
        RefreshRows()
        lock:SetChecked(db.locked and true or false)
        noOverlap:SetChecked(db.noOverlapAlerts and true or false)
        xBox:SetText(tostring(db.x or 0))
        yBox:SetText(tostring(db.y or 120))
        durSlider:SetValue(db.pulseDuration or 0.60)
        durValue:SetText(string.format("%.2f", db.pulseDuration or 0.60))
        sizeSlider:SetValue(db.size or 64)
        sizeValue:SetText(tostring(db.size or 64))
        opacitySlider:SetValue(db.iconOpacity or 1)
        opacityValue:SetText(string.format("%d%%", math.floor((db.iconOpacity or 1)*100+0.5)))
        enableSound:SetChecked(db.soundEnabled ~= false)
        InitChannelDropdown()
        zoneWorld:SetChecked(db.enabledInWorld ~= false)
        zoneDungeons:SetChecked(db.enabledInDungeons ~= false)
        zoneRaids:SetChecked(db.enabledInRaids ~= false)
        zoneArena:SetChecked(db.enabledInArena ~= false)
        debugCB:SetChecked(db.debug and true or false)
        SelectTab(1)
    end)

    return panel
end

function CDPulse_OpenOptions()
    if InCombatLockdown and InCombatLockdown() then
        return false, "combat"
    end
    if Settings and Settings.OpenToCategory then
        if CDPulse_SettingsCategory and CDPulse_SettingsCategory.GetID then
            pcall(Settings.OpenToCategory, CDPulse_SettingsCategory:GetID())
            return
        end
        pcall(Settings.OpenToCategory, PANEL_NAME)
        return
    end
    if InterfaceOptionsFrame_OpenToCategory and CDPulseOptionsPanel then
        InterfaceOptionsFrame_OpenToCategory(CDPulseOptionsPanel)
        InterfaceOptionsFrame_OpenToCategory(CDPulseOptionsPanel)
    end
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, addonName)
    if addonName == "CDPulse" then
        self:UnregisterEvent("ADDON_LOADED")
        EnsureDB()
        local panel = CreateOptionsPanel()
        RegisterPanel(panel)
    end
end)