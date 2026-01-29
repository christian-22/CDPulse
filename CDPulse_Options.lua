-- CDPulse_Options.lua (Retail Settings panel)
local PANEL_NAME = "CDPulse"

local RefreshRows -- forward decl for delayed refresh
local function EnsureDB()
  CDPulseDB = CDPulseDB or {}
  CDPulseDB.whitelist = CDPulseDB.whitelist or {}
  CDPulseDB.spellSounds = CDPulseDB.spellSounds or {}

  if CDPulseDB.size == nil then CDPulseDB.size = 64 end
  if CDPulseDB.iconOpacity == nil then CDPulseDB.iconOpacity = 1 end
  if CDPulseDB.point == nil then CDPulseDB.point = "CENTER" end
  if CDPulseDB.relPoint == nil then CDPulseDB.relPoint = "CENTER" end
  if CDPulseDB.x == nil then CDPulseDB.x = 0 end
  if CDPulseDB.y == nil then CDPulseDB.y = 120 end

  if CDPulseDB.pulseDuration == nil then CDPulseDB.pulseDuration = 0.60 end
  if CDPulseDB.sortByName == nil then CDPulseDB.sortByName = true end

  if CDPulseDB.soundName == nil then CDPulseDB.soundName = "None" end
  if CDPulseDB.soundChannel == nil then CDPulseDB.soundChannel = "Master" end
  if CDPulseDB.soundEnabled == nil then CDPulseDB.soundEnabled = true end

  if CDPulseDB.locked == nil then CDPulseDB.locked = true end

  -- gcdThreshold is no longer used (dynamic GCD detection in 12.0+); clean old saved vars.
  if CDPulseDB.gcdThreshold ~= nil then CDPulseDB.gcdThreshold = nil end

  return CDPulseDB
end

local spellDataRequested = {}
local pendingRefresh = false

local function ScheduleRefreshRows()
  if pendingRefresh then return end
  pendingRefresh = true
  if not (C_Timer and C_Timer.After) then
    pendingRefresh = false
    return
  end
  C_Timer.After(0.20, function()
    pendingRefresh = false
    if RefreshRows then RefreshRows() end
  end)
end

local function RequestSpellData(spellID)
  if not spellID then return end
  if spellDataRequested[spellID] then return end
  spellDataRequested[spellID] = true

  if C_Spell and C_Spell.RequestLoadSpellData then
    C_Spell.RequestLoadSpellData(spellID)
    -- Data loads asynchronously; refresh rows shortly.
    ScheduleRefreshRows()
  end
end


local function GetLSM()
  if not LibStub then return nil end
  return LibStub("LibSharedMedia-3.0", true)
end


-- Build a sound list for dropdowns. For per-spell rows, "Default" means use global selection.
local function BuildSoundList(lsm, includeNoneFirst)
  local sounds = {}
  if includeNoneFirst then
    sounds[#sounds + 1] = "None"
    sounds[#sounds + 1] = "Default"
  else
    sounds[#sounds + 1] = "Default"
    sounds[#sounds + 1] = "None"
  end

  if lsm then
    local list = lsm:List("sound") or {}
    for i = 1, #list do
      local name = list[i]
      if name ~= "None" and name ~= "Default" then
        sounds[#sounds + 1] = name
      end
    end
  end
  return sounds
end


local function GetSpellNameAndIcon(spellID)
  -- Prefer modern API (Retail 12.0+)
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellID)
    if info and info.name then return info.name, info.iconID end
  end

  -- Legacy fallback (only if available in this client)
  if type(GetSpellInfo) == "function" then
    local name, _, icon = GetSpellInfo(spellID)
    return name, icon
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

local function SortWhitelist(db)
  local ids = {}
  for k, enabled in pairs(db.whitelist or {}) do
    if enabled then
      local id = tonumber(k)
      if id then ids[#ids + 1] = id end
    end
  end

  if db.sortByName then
    table.sort(ids, function(a, b)
      local na = GetSpellNameAndIcon(a) or ""
      local nb = GetSpellNameAndIcon(b) or ""
      if na == nb then return a < b end
      return na < nb
    end)
  else
    table.sort(ids)
  end

  return ids
end

local function RegisterPanel(panel)
  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
    CDPulse_SettingsCategory = category
  else
    InterfaceOptions_AddCategory(panel)
  end
end

local function SetSliderLabels(slider, lowText, highText)
  if slider.Low then slider.Low:SetText(lowText or "") end
  if slider.High then slider.High:SetText(highText or "") end
  if slider.Text then slider.Text:SetText("") end
end

local function CreateRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(36)

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(24, 24)
  row.icon:SetPoint("LEFT", row, "LEFT", 10, 0)

  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.text:SetPoint("LEFT", row.icon, "RIGHT", 10, 0)
  row.text:SetJustifyH("LEFT")

  row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  row.remove:SetSize(72, 22)
  if PixelUtil and PixelUtil.SetPoint then
    PixelUtil.SetPoint(row.remove, "RIGHT", row, "RIGHT", -10, 3)
  else
    row.remove:SetPoint("RIGHT", row, "RIGHT", -10, 3)
  end
  row.remove:SetText("Remove")

  row.soundDD = CreateFrame("Frame", nil, row, "UIDropDownMenuTemplate")
  UIDropDownMenu_SetWidth(row.soundDD, 150)
  UIDropDownMenu_SetText(row.soundDD, "")
  row.soundDD:SetPoint("RIGHT", row.remove, "LEFT", -8, -3)

  -- Speaker preview button (left of dropdown) - clearly pressable
  row.soundPreview = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  row.soundPreview:SetSize(26, 22)
  row.soundPreview:SetPoint("RIGHT", row.soundDD, "LEFT", -6, 0)
  row.soundPreview:SetText("")

  row.soundPreview.tex = row.soundPreview:CreateTexture(nil, "ARTWORK")
  row.soundPreview.tex:SetSize(16, 16)
  row.soundPreview.tex:SetPoint("CENTER", row.soundPreview, "CENTER", 0, 0)
  if row.soundPreview.tex.SetAtlas then
    row.soundPreview.tex:SetAtlas("voicechat-icon-speaker")
  else
    row.soundPreview.tex:SetTexture("Interface\\COMMON\\VoiceChat-Speaker")
  end

  row.soundPreview:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Preview sound", 1, 1, 1)
    GameTooltip:AddLine("Plays the selected sound for this spell.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  row.soundPreview:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Ensure the spell name never collides with the sound controls
  row.text:SetPoint("RIGHT", row.soundPreview, "LEFT", -10, 0)

  return row
end

local function CreateDropdown(parent, labelText, width)
  local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  label:SetText(labelText)

  local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
  UIDropDownMenu_SetWidth(dd, width or 220)
  UIDropDownMenu_SetText(dd, "")

  return label, dd
end

local function CreateOptionsPanel()
  local panel = CreateFrame("Frame", "CDPulseOptionsPanel")
  panel.name = PANEL_NAME

  -- globals used by /cdp to open this panel
  CDPulseOptionsPanel = panel

  local function ApplyToAddon()
    if CDPulse_ApplySettings then CDPulse_ApplySettings() end
  end

  ----------------------------------------------------------
  -- Header
  ----------------------------------------------------------
  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("CDPulse Settings")

  local testPulseBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  testPulseBtn:SetSize(120, 26)
  testPulseBtn:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
  testPulseBtn:SetText("Test Alert")

  testPulseBtn:SetScript("OnClick", function()
    local ok = false
    if CDPulse_TestPulse then ok = CDPulse_TestPulse(nil) end
    if not ok then
      UIErrorsFrame:AddMessage("CDPulse: Whitelist is empty. Add a spell first.", 1, 0.2, 0.2)
    end
  end)

  ----------------------------------------------------------
  -- Tabs
  ----------------------------------------------------------
  local TAB_H = 24
  local tabBar = CreateFrame("Frame", nil, panel)
  tabBar:SetPoint("TOPLEFT", testPulseBtn, "BOTTOMLEFT", 0, -16)
  tabBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -12)
  tabBar:SetHeight(TAB_H)

  local content = CreateFrame("Frame", nil, panel)
  content:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -16)
  content:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -16, 16)

  local tabs = {}
  local frames = {}

  local PAD = 16  -- left/right padding inside tab containers

  local function SelectTab(which)
  if PanelTemplates_SetTab then
    PanelTemplates_SetTab(panel, which)
  end
  for i = 1, #frames do
    frames[i]:SetShown(i == which)
  end
end

local function CreateTabButton(i, text, prev)
  local b = CreateFrame("Button", panel:GetName() .. "Tab" .. i, panel, "PanelTabButtonTemplate")
  b:SetID(i)
  b:SetText(text)

  -- Make them read visually like real tabs
  if PanelTemplates_TabResize then
    PanelTemplates_TabResize(b, 0, nil, 36)
  end

  if prev then
    b:SetPoint("LEFT", prev, "RIGHT", 6, 0)
  else
    b:SetPoint("LEFT", tabBar, "LEFT", 0, 0)
  end

  b:SetScript("OnClick", function(self)
    SelectTab(self:GetID())
  end)
  tabs[i] = b

  local f = CreateFrame("Frame", nil, content)
  f:SetAllPoints(content)
  f:Hide()
  frames[i] = f

  return b, f
end


local tab1, spellsFrame = CreateTabButton(1, "Spells", nil)
local tab2, appearanceFrame = CreateTabButton(2, "Appearance", tab1)
local tab3, audioFrame = CreateTabButton(3, "Audio", tab2)
local tab4, infoFrame = CreateTabButton(4, "Info", tab3)

if PanelTemplates_SetNumTabs then
  PanelTemplates_SetNumTabs(panel, 4)
end

  ----------------------------------------------------------
  -- Spells tab
  ----------------------------------------------------------

  -- Container (dark background for this tab)
  local spellsContainer = CreateFrame("Frame", nil, spellsFrame, "BackdropTemplate")
  spellsContainer:SetPoint("TOPLEFT", spellsFrame, "TOPLEFT", 0, -6)
  spellsContainer:SetPoint("BOTTOMRIGHT", spellsFrame, "BOTTOMRIGHT", 0, 0)
  spellsContainer:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
  spellsContainer:SetBackdropColor(0, 0, 0, 0.10)
  spellsContainer:SetBackdropBorderColor(0.12, 0.12, 0.12, 0.95)

-- Footer: Created by (shown on every tab)
local spellsContainerFooter = spellsContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
spellsContainerFooter:SetPoint("BOTTOMLEFT", spellsContainer, "BOTTOMLEFT", 12, 10)
spellsContainerFooter:SetText("Created by: |cffffd100Cree|r")

  local sort = CreateFrame("CheckButton", nil, spellsContainer, "UICheckButtonTemplate")
  sort:SetPoint("TOPLEFT", spellsContainer, "TOPLEFT", PAD, -12)
  sort.text = sort:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  sort.text:SetPoint("LEFT", sort, "RIGHT", 4, 0)
  sort.text:SetText("Sort alphabetically")

  local wlLabel = spellsContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  wlLabel:SetPoint("TOPLEFT", sort, "BOTTOMLEFT", 0, -12)
  wlLabel:SetText("Tracked Spells")

  local inputBox = CreateFrame("EditBox", nil, spellsContainer, "InputBoxTemplate")
  inputBox:SetSize(260, 26)
  if PixelUtil and PixelUtil.SetPoint then
    PixelUtil.SetPoint(inputBox, "TOPLEFT", wlLabel, "BOTTOMLEFT", 6, -6)
  else
    if PixelUtil and PixelUtil.SetPoint then
    PixelUtil.SetPoint(inputBox, "TOPLEFT", wlLabel, "BOTTOMLEFT", 6, -6)
  else
    inputBox:SetPoint("TOPLEFT", wlLabel, "BOTTOMLEFT", 6, -6)
  end
  end
  inputBox:SetAutoFocus(false)

  local addBtn = CreateFrame("Button", nil, spellsContainer, "UIPanelButtonTemplate")
  addBtn:SetSize(80, 26)
  addBtn:SetPoint("LEFT", inputBox, "RIGHT", 10, 0)
  addBtn:SetText("Add")

  local refreshBtn = CreateFrame("Button", nil, spellsContainer, "UIPanelButtonTemplate")
  refreshBtn:SetSize(160, 26)
  refreshBtn:SetPoint("LEFT", addBtn, "RIGHT", 10, 0)
  refreshBtn:SetText("Refresh")

  local inputHint = spellsContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  inputHint:SetPoint("TOPLEFT", inputBox, "BOTTOMLEFT", -3, -4)
  inputHint:SetText("Enter spellID (recommended) or spell name (best-effort).")

  -- List container (fills remaining space)
  local listFrame = CreateFrame("Frame", nil, spellsContainer, "BackdropTemplate")
  listFrame:SetPoint("TOPLEFT", inputHint, "BOTTOMLEFT", -3, -10)
  listFrame:SetPoint("BOTTOMRIGHT", spellsContainer, "BOTTOMRIGHT", -PAD, PAD + 24)
  listFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
  listFrame:SetBackdropColor(0, 0, 0, 0.15)
  listFrame:SetBackdropBorderColor(0.12, 0.12, 0.12, 0.95)

  local ROW_HEIGHT = 36
  local MAX_ROWS = 20
  local VISIBLE_ROWS = 10  -- recalculated dynamically based on available height

  local scroll = CreateFrame("ScrollFrame", "CDPulseWhitelistScrollFrame", listFrame, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 0, -2)
  scroll:SetPoint("BOTTOMRIGHT", listFrame, "BOTTOMRIGHT", -26, 2)

  local rows = {}
  for i = 1, MAX_ROWS do
    local row = CreateRow(listFrame)
    row:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 4, -((i - 1) * ROW_HEIGHT) - 4)
    row:SetPoint("TOPRIGHT", listFrame, "TOPRIGHT", -30, -((i - 1) * ROW_HEIGHT) - 4)
    rows[i] = row
  end

  local function RecalcVisibleRows()
    local h = listFrame:GetHeight() or 0
    -- padding: top/bottom margins inside listFrame
    local usable = h - 10
    local count = math.floor(usable / ROW_HEIGHT)
    if count < 1 then count = 1 end
    if count > MAX_ROWS then count = MAX_ROWS end
    VISIBLE_ROWS = count
  end

  local allIds = {}

  RefreshRows = function()
    RecalcVisibleRows()
    local db = EnsureDB()

    -- Info tab state
    if debugCB then debugCB:SetChecked(db.debug == true) end
    allIds = SortWhitelist(db)

    local offset = FauxScrollFrame_GetOffset(scroll)
    for i = 1, MAX_ROWS do
      local index = offset + i
      local spellID = allIds[index]
      local row = rows[i]

      if i > VISIBLE_ROWS then
        if row.soundDD then row.soundDD:Hide() end
        if row.soundPreview then row.soundPreview:Hide() end
        row:Hide()
      elseif spellID then
        local sid = spellID
        RequestSpellData(spellID)
        local name, icon = GetSpellNameAndIcon(spellID)
        if not name then ScheduleRefreshRows() end
        row.icon:SetTexture(icon or "Interface\Icons\INV_Misc_QuestionMark")
        row.text:SetText(string.format("%s  (ID: %d)", name or "Unknown", spellID))
        row.remove:SetScript("OnClick", function()
          db.whitelist[sid] = nil
          if CDPulse_RefreshActionMap then CDPulse_RefreshActionMap() end
          RefreshRows()
        end)
        row:Show()

        -- Per-spell sound dropdown (uses global if set to "Default")
        local lsm = GetLSM()
        local sounds = BuildSoundList(lsm)

        local current = (db.spellSounds and db.spellSounds[sid]) or "Default"
        UIDropDownMenu_Initialize(row.soundDD, function(_, level)
          local info = UIDropDownMenu_CreateInfo()
          info.keepShownOnClick = false
          for i = 1, #sounds do
            local name = sounds[i]
            info.text = name
            info.checked = (current == name)
            info.func = function()
              current = name
              db.spellSounds = db.spellSounds or {}
              if name == "Default" or name == "" or name == nil then
                db.spellSounds[sid] = nil
              else
                db.spellSounds[sid] = name
              end
              UIDropDownMenu_SetText(row.soundDD, current)

-- Speaker preview button: play the effective sound for this spell (works immediately on load)
if row.soundPreview then
  row.soundPreview:SetScript("OnClick", function()
    local db = EnsureDB()
    if db.soundEnabled == false then return end
    local lsm = GetLSM()

    local sel = (db.spellSounds and db.spellSounds[sid]) or "Default"
    if sel == "Default" then sel = db.soundName or "Default" end
    if not sel or sel == "None" then return end

    if sel == "Default" then
      if db.fallbackSoundKitID then
        PlaySound(db.fallbackSoundKitID, db.soundChannel or "Master")
      end
      return
    end

    if lsm then
      local path = lsm:Fetch("sound", sel, true)
      if path then
        PlaySoundFile(path, db.soundChannel or "Master")
      end
    end
  end)
end

        if CDPulse_SetSpellSound then
                -- keep addon-side DB in sync if it exposes helpers
                CDPulse_SetSpellSound(sid, (name == "Default") and "Default" or name)
              end
            end
            UIDropDownMenu_AddButton(info, level)
          end
        end)
        UIDropDownMenu_SetText(row.soundDD, current)

-- Speaker preview button: play the effective sound for this spell (works immediately on load)
if row.soundPreview then
  row.soundPreview:SetScript("OnClick", function()
    local db = EnsureDB()
    if db.soundEnabled == false then return end
    local lsm = GetLSM()

    local sel = (db.spellSounds and db.spellSounds[sid]) or "Default"
    if sel == "Default" then sel = db.soundName or "Default" end
    if not sel or sel == "None" then return end

    if sel == "Default" then
      if db.fallbackSoundKitID then
        PlaySound(db.fallbackSoundKitID, db.soundChannel or "Master")
      end
      return
    end

    if lsm then
      local path = lsm:Fetch("sound", sel, true)
      if path then
        PlaySoundFile(path, db.soundChannel or "Master")
      end
    end
  end)
end

        if row.soundPreview then row.soundPreview:Show() end
        row.soundDD:Show()

      else
        if row.soundDD then row.soundDD:Hide() end
        if row.soundPreview then row.soundPreview:Hide() end
        row:Hide()
      end
    end

    FauxScrollFrame_Update(scroll, #allIds, VISIBLE_ROWS, ROW_HEIGHT)
  end

  scroll:SetScript("OnVerticalScroll", function(_, offset)
    FauxScrollFrame_OnVerticalScroll(scroll, offset, ROW_HEIGHT, RefreshRows)
  end)


  listFrame:SetScript("OnSizeChanged", function()
    RefreshRows()
  end)

  scroll:SetScript("OnShow", function()
    RefreshRows()
  end)

  local function DoAddFromInput()
    local db = EnsureDB()
    local text = inputBox:GetText() or ""
    local spellID = ResolveSpellID(text)

    if not spellID then
      UIErrorsFrame:AddMessage("CDPulse: Could not resolve. Use a spellID (recommended).", 1, 0.2, 0.2)
      return
    end

    db.whitelist[spellID] = true
    RequestSpellData(spellID)

    if CDPulse_RefreshActionMap then CDPulse_RefreshActionMap() end

    inputBox:SetText("")
    RefreshRows()

    UIErrorsFrame:AddMessage("CDPulse: Added " .. spellID, 0.2, 1.0, 0.2)
  end

  addBtn:SetScript("OnClick", DoAddFromInput)
  inputBox:SetScript("OnEnterPressed", DoAddFromInput)

  refreshBtn:SetScript("OnClick", function()
    if CDPulse_RefreshActionMap then CDPulse_RefreshActionMap() end
    RefreshRows()
    UIErrorsFrame:AddMessage("CDPulse: Refreshed action map.", 0.2, 1.0, 0.2)
  end)

  sort:SetScript("OnClick", function()
    local db = EnsureDB()
    db.sortByName = sort:GetChecked() and true or false
    RefreshRows()
  end)

  ----------------------------------------------------------
  -- Appearance tab
  ----------------------------------------------------------

  -- Container (dark background for this tab)
  local appearanceContainer = CreateFrame("Frame", nil, appearanceFrame, "BackdropTemplate")
  appearanceContainer:SetPoint("TOPLEFT", appearanceFrame, "TOPLEFT", 0, -6)
  appearanceContainer:SetPoint("BOTTOMRIGHT", appearanceFrame, "BOTTOMRIGHT", 0, 0)
  appearanceContainer:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
  appearanceContainer:SetBackdropColor(0, 0, 0, 0.10)
  appearanceContainer:SetBackdropBorderColor(0.12, 0.12, 0.12, 0.95)

-- Footer: Created by (shown on every tab)
local appearanceContainerFooter = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
appearanceContainerFooter:SetPoint("BOTTOMLEFT", appearanceContainer, "BOTTOMLEFT", 12, 10)
appearanceContainerFooter:SetText("Created by: |cffffd100Cree|r")


  local lock = CreateFrame("CheckButton", nil, appearanceContainer, "UICheckButtonTemplate")
  lock:SetPoint("TOPLEFT", appearanceContainer, "TOPLEFT", PAD, -12)
  lock.text = lock:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  lock.text:SetPoint("LEFT", lock, "RIGHT", 4, 0)
  lock.text:SetText("Lock (Unlock + Left Click to drag)")

  
  local noOverlap = CreateFrame("CheckButton", nil, appearanceContainer, "UICheckButtonTemplate")
  noOverlap:SetPoint("TOPLEFT", lock, "BOTTOMLEFT", 0, -8)
  noOverlap.text = noOverlap:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  noOverlap.text:SetPoint("LEFT", noOverlap, "RIGHT", 4, 0)
  noOverlap.text:SetText("Do not overlap alerts")

local posLabel = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  posLabel:SetPoint("TOPLEFT", noOverlap, "BOTTOMLEFT", 0, -14)
  posLabel:SetText("Position (relative to screen center)")

  local xBox = CreateFrame("EditBox", nil, appearanceContainer, "InputBoxTemplate")
  xBox:SetSize(80, 24)
  xBox:SetPoint("TOPLEFT", posLabel, "BOTTOMLEFT", 0, -6)
  xBox:SetAutoFocus(false)
  xBox:SetNumeric(true)

  local xLbl = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  xLbl:SetPoint("LEFT", xBox, "RIGHT", 6, 0)
  xLbl:SetText("X")

  local yBox = CreateFrame("EditBox", nil, appearanceContainer, "InputBoxTemplate")
  yBox:SetSize(80, 24)
  yBox:SetPoint("LEFT", xLbl, "RIGHT", 14, 0)
  yBox:SetAutoFocus(false)
  yBox:SetNumeric(true)

  local yLbl = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  yLbl:SetPoint("LEFT", yBox, "RIGHT", 6, 0)
  yLbl:SetText("Y")

  local posApply = CreateFrame("Button", nil, appearanceContainer, "UIPanelButtonTemplate")
  posApply:SetSize(80, 24)
  posApply:SetPoint("LEFT", yLbl, "RIGHT", 14, 0)
  posApply:SetText("Apply")

  local durLabel = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  durLabel:SetPoint("TOPLEFT", xBox, "BOTTOMLEFT", 0, -18)
  durLabel:SetText("Pulse Duration (seconds)")

  local durSlider = CreateFrame("Slider", nil, appearanceContainer, "OptionsSliderTemplate")
  durSlider:SetPoint("TOPLEFT", durLabel, "BOTTOMLEFT", 0, -6)
  durSlider:SetMinMaxValues(0.10, 2.00)
  durSlider:SetValueStep(0.05)
  durSlider:SetObeyStepOnDrag(true)
  durSlider:SetWidth(260)
  SetSliderLabels(durSlider, "0.10", "2.00")

  local durValue = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  durValue:SetPoint("LEFT", durSlider, "RIGHT", 12, 0)

  local sizeLabel = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  sizeLabel:SetPoint("TOPLEFT", durSlider, "BOTTOMLEFT", 0, -18)
  sizeLabel:SetText("Icon Size")

  local sizeSlider = CreateFrame("Slider", nil, appearanceContainer, "OptionsSliderTemplate")
  sizeSlider:SetPoint("TOPLEFT", sizeLabel, "BOTTOMLEFT", 0, -6)
  sizeSlider:SetMinMaxValues(8, 512)
  sizeSlider:SetValueStep(1)
  sizeSlider:SetObeyStepOnDrag(true)
  sizeSlider:SetWidth(260)
  SetSliderLabels(sizeSlider, "8", "512")

  local sizeValue = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sizeValue:SetPoint("LEFT", sizeSlider, "RIGHT", 12, 0)


local opacityLabel = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
opacityLabel:SetPoint("TOPLEFT", sizeSlider, "BOTTOMLEFT", 0, -18)
opacityLabel:SetText("Icon Opacity")

local opacitySlider = CreateFrame("Slider", nil, appearanceContainer, "OptionsSliderTemplate")
opacitySlider:SetPoint("TOPLEFT", opacityLabel, "BOTTOMLEFT", 0, -6)
opacitySlider:SetMinMaxValues(0.05, 1.00)
opacitySlider:SetValueStep(0.05)
opacitySlider:SetObeyStepOnDrag(true)
opacitySlider:SetWidth(260)
SetSliderLabels(opacitySlider, "5%", "100%")

local opacityValue = appearanceContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
opacityValue:SetPoint("LEFT", opacitySlider, "RIGHT", 12, 0)
  lock:SetScript("OnClick", function()
    local db = EnsureDB()
    db.locked = lock:GetChecked() and true or false
    ApplyToAddon()
    if db.locked then
      if CDPulse_HideAnchor then CDPulse_HideAnchor() end
    else
      if CDPulse_ShowAnchor then CDPulse_ShowAnchor() end
    end
  end)

  noOverlap:SetScript("OnClick", function()
    local db = EnsureDB()
    db.noOverlapAlerts = noOverlap:GetChecked() and true or false
    ApplyToAddon()
  end)

posApply:SetScript("OnClick", function()
    local db = EnsureDB()
    local x = tonumber(xBox:GetText())
    local y = tonumber(yBox:GetText())
    if x == nil or y == nil then
      UIErrorsFrame:AddMessage("CDPulse: Invalid X/Y values.", 1, 0.2, 0.2)
      return
    end
    db.point = "CENTER"
    db.relPoint = "CENTER"
    db.x = math.floor(x + 0.5)
    db.y = math.floor(y + 0.5)
    ApplyToAddon()
  end)

  durSlider:SetScript("OnValueChanged", function(_, value)
    local db = EnsureDB()
    value = math.floor(value * 100 + 0.5) / 100
    db.pulseDuration = value
    durValue:SetText(string.format("%.2f", value))
    ApplyToAddon()
  end)

  sizeSlider:SetScript("OnValueChanged", function(_, value)
    local db = EnsureDB()
    value = math.floor(value + 0.5)
    db.size = value
    sizeValue:SetText(tostring(value))
    ApplyToAddon()
  end)


opacitySlider:SetScript("OnValueChanged", function(_, value)
  local db = EnsureDB()
  value = math.floor((value * 100) + 0.5) / 100
  db.iconOpacity = value
  opacityValue:SetText(string.format("%d%%", math.floor(value * 100 + 0.5)))
  ApplyToAddon()
end)


  ----------------------------------------------------------
-- Audio tab
----------------------------------------------------------

-- Container (dark background for this tab)
local audioContainer = CreateFrame("Frame", nil, audioFrame, "BackdropTemplate")
audioContainer:SetPoint("TOPLEFT", audioFrame, "TOPLEFT", 0, -6)
audioContainer:SetPoint("BOTTOMRIGHT", audioFrame, "BOTTOMRIGHT", 0, 0)
audioContainer:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
audioContainer:SetBackdropColor(0, 0, 0, 0.10)
audioContainer:SetBackdropBorderColor(0.12, 0.12, 0.12, 0.95)

-- Footer: Created by (shown on every tab)
local audioContainerFooter = audioContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
audioContainerFooter:SetPoint("BOTTOMLEFT", audioContainer, "BOTTOMLEFT", 12, 10)
audioContainerFooter:SetText("Created by: |cffffd100Cree|r")



local enableSound = CreateFrame("CheckButton", nil, audioContainer, "UICheckButtonTemplate")
enableSound:SetPoint("TOPLEFT", audioContainer, "TOPLEFT", PAD, -12)
enableSound.text = enableSound:CreateFontString(nil, "OVERLAY", "GameFontNormal")
enableSound.text:SetPoint("LEFT", enableSound, "RIGHT", 4, 0)
enableSound.text:SetText("Enable sound")

local channelLabel, channelDD = CreateDropdown(audioContainer, "Sound Channel", 160)
channelLabel:SetPoint("TOPLEFT", enableSound, "BOTTOMLEFT", -2, -14)
channelDD:SetPoint("TOPLEFT", channelLabel, "BOTTOMLEFT", -16, -6)

local CHANNELS = { "Master", "SFX", "Music", "Ambience", "Dialog" }
local function InitChannelDropdown()
  local db = EnsureDB()
  UIDropDownMenu_Initialize(channelDD, function(_, level)
    local info = UIDropDownMenu_CreateInfo()
    for i = 1, #CHANNELS do
      local ch = CHANNELS[i]
      info.text = ch
      info.checked = (db.soundChannel == ch)
      info.func = function()
        db.soundChannel = ch
        UIDropDownMenu_SetText(channelDD, ch)
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)

  UIDropDownMenu_SetText(channelDD, db.soundChannel or "Master")
  if db.soundEnabled == false then
    UIDropDownMenu_DisableDropDown(channelDD)
  else
    UIDropDownMenu_EnableDropDown(channelDD)
  end
end

enableSound:SetScript("OnClick", function()
  local db = EnsureDB()
  db.soundEnabled = enableSound:GetChecked() and true or false
  if CDPulse_SetSoundEnabled then CDPulse_SetSoundEnabled(db.soundEnabled) end
  InitChannelDropdown()
  RefreshRows()
end)
  
----------------------------------------------------------
-- Info tab
----------------------------------------------------------

local infoContainer = CreateFrame("Frame", nil, infoFrame, "BackdropTemplate")
infoContainer:SetPoint("TOPLEFT", infoFrame, "TOPLEFT", 0, -6)
infoContainer:SetPoint("BOTTOMRIGHT", infoFrame, "BOTTOMRIGHT", 0, 0)
infoContainer:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
infoContainer:SetBackdropColor(0, 0, 0, 0.10)
infoContainer:SetBackdropBorderColor(0.12, 0.12, 0.12, 0.95)

-- Footer: Created by (shown on every tab)
local infoContainerFooter = infoContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
infoContainerFooter:SetPoint("BOTTOMLEFT", infoContainer, "BOTTOMLEFT", 12, 10)
infoContainerFooter:SetText("Created by: |cffffd100Cree|r")



local debugCB = CreateFrame("CheckButton", nil, infoContainer, "UICheckButtonTemplate")
debugCB:SetPoint("TOPLEFT", infoContainer, "TOPLEFT", PAD, -12)
debugCB.text = debugCB:CreateFontString(nil, "OVERLAY", "GameFontNormal")
debugCB.text:SetPoint("LEFT", debugCB, "RIGHT", 4, 0)
debugCB.text:SetText("Debug mode")

-- Sync checkbox with saved variable on creation and whenever the Info tab is shown
do
  local db = EnsureDB()
  debugCB:SetChecked(db.debug == true)
end
infoFrame:HookScript("OnShow", function()
  local db = EnsureDB()
  debugCB:SetChecked(db.debug == true)
end)


debugCB:SetScript("OnClick", function()
    local db = EnsureDB()
    local enabled = debugCB:GetChecked() and true or false
    db.debug = enabled
    ApplyToAddon()
    local msg = enabled and "|cffb026ffCDPulse|r: Debug mode enabled." or "|cffb026ffCDPulse|r: Debug mode disabled."
    if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
      _G.DEFAULT_CHAT_FRAME:AddMessage(msg)
    else
      print(msg)
    end
  end)

local cmdCard = CreateFrame("Frame", nil, infoContainer, "BackdropTemplate")
cmdCard:SetPoint("TOPLEFT", debugCB, "BOTTOMLEFT", 0, -14)
cmdCard:SetPoint("TOPRIGHT", infoContainer, "TOPRIGHT", -PAD, -50)
cmdCard:SetHeight(260)
cmdCard:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
cmdCard:SetBackdropColor(0, 0, 0, 0.15)
cmdCard:SetBackdropBorderColor(0.12, 0.12, 0.12, 0.95)

local cmdTitle = cmdCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
cmdTitle:SetPoint("TOPLEFT", cmdCard, "TOPLEFT", 10, -10)
cmdTitle:SetText("Slash commands")

local cmdText = cmdCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
cmdText:SetPoint("TOPLEFT", cmdTitle, "BOTTOMLEFT", 0, -8)
cmdText:SetPoint("TOPRIGHT", cmdCard, "TOPRIGHT", -10, -34)
cmdText:SetJustifyH("LEFT")
cmdText:SetJustifyV("TOP")

cmdText:SetText(
    "/cdp  - Open CDPulse settings\n\r" ..
    "/cdp help  - Show this help list\n\r" ..
    "/cdp add <spellID>  - Add a spell to the whitelist\n\r" ..
    "/cdp remove <spellID>  - Remove a spell from the whitelist (alias: /cdp del)\n\r" ..
    "/cdp list  - Print whitelisted spells (with pending/armed state + duration info)\n\r" ..
    "/cdp setdur <spellID> <seconds>  - Override/cache a cooldown duration (used if API is unreadable)\n\r" ..
    "/cdp cleardur <spellID>  - Clear a duration override for that spell\n\r" ..
    "/cdp test [spellID]  - Test alert; if spellID omitted, uses the first whitelisted spell\n\r" ..
    "/cdp debug  - Toggle debug logging in chat"
  )

panel:SetScript("OnShow", function()
    local db = EnsureDB()

    -- Spells tab state
    sort:SetChecked(db.sortByName and true or false)
    RefreshRows()

    -- Appearance tab state
    lock:SetChecked(db.locked and true or false)
    noOverlap:SetChecked(db.noOverlapAlerts and true or false)

    durSlider:SetValue(db.pulseDuration or 0.50)
    durValue:SetText(string.format("%.2f", db.pulseDuration or 0.50))

    sizeSlider:SetValue(db.size or 64)
    sizeValue:SetText(tostring(db.size or 64))

    opacitySlider:SetValue(db.iconOpacity or 1)
    opacityValue:SetText(string.format("%d%%", math.floor((db.iconOpacity or 1) * 100 + 0.5)))

    xBox:SetText(tostring(db.x or 0))
    yBox:SetText(tostring(db.y or 100))

    -- Audio tab state
    enableSound:SetChecked(db.soundEnabled ~= false)
    InitChannelDropdown()

    -- default tab
    SelectTab(1)
  end)

  return panel
end


function CDPulse_OpenOptions()
  -- Retail Settings (Dragonflight+ / The War Within)
  if Settings and Settings.OpenToCategory then
    if CDPulse_SettingsCategory and CDPulse_SettingsCategory.GetID then
      pcall(Settings.OpenToCategory, CDPulse_SettingsCategory:GetID())
      return
    end
    pcall(Settings.OpenToCategory, PANEL_NAME)
    return
  end

  -- Legacy Interface Options
  if InterfaceOptionsFrame_OpenToCategory and CDPulseOptionsPanel then
    InterfaceOptionsFrame_OpenToCategory(CDPulseOptionsPanel)
    InterfaceOptionsFrame_OpenToCategory(CDPulseOptionsPanel) -- called twice due to Blizzard bug
  end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
  EnsureDB()
  local panel = CreateOptionsPanel()
  RegisterPanel(panel)
end)