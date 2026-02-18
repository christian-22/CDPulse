--[[
CDPulse_Log.lua
Logging infrastructure with searchable UI window.
Format: TIME SEQ LEVEL [SPELL] MESSAGE
]]

local ADDON_NAME = ...
CDPulse_Log = {}
local Log = CDPulse_Log

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

Log.MAX_ENTRIES = 5000

--------------------------------------------------------------------------------
-- Internal State
--------------------------------------------------------------------------------

Log.entries = {}
Log._seq = 0
Log.filterSpellID = nil
Log.filterText = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function getSpellName(spellID)
    return CDPulse.GetSpellNameCached and CDPulse.GetSpellNameCached(spellID) 
           or "?"
end

local function formatTime(t)
    return string.format("%08.2f", t or 0)
end

-- Midnight / 12.x: some values (including strings) can become "secret" and will
-- error when concatenated or table.concat'd. Ensure we never store or render
-- secret-typed values into the log buffer.
local function safeString(v)
    if v == nil then return "" end
    local tv = type(v)
    if tv == "string" then
        -- Secret strings can look like strings but will error when concatenated/concat'd.
        local ok = pcall(function() return table.concat({ v }, "") end)
        return ok and v or "<secret>"
    elseif tv == "number" then
        return tostring(v)
    elseif tv == "boolean" then
        return v and "true" or "false"
    else
        local ok, s = pcall(tostring, v)
        if not ok then return "<unprintable>" end
        local ok2 = pcall(function() return table.concat({ s }, "") end)
        return ok2 and s or "<secret>"
    end
end

local function formatEntry(e)
    -- Format: 00000.00 #00001 INFO  [12345 SpellName] message text here
    local spellPart = ""
    if e.spellID then
        spellPart = string.format("[%d %s] ", e.spellID, getSpellName(e.spellID))
    end
    return string.format("%s #%05d %-5s %s%s",
        formatTime(e.time),
        e.seq,
        e.level,
        spellPart,
        e.msg or ""
    )
end

local function matchesFilter(self, e)
    if self.filterSpellID and e.spellID ~= self.filterSpellID then
        return false
    end
    if self.filterText then
        local haystack = string.lower(formatEntry(e))
        if not string.find(haystack, self.filterText, 1, true) then
            return false
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- Core API
--------------------------------------------------------------------------------

function Log:Init(db)
    self.db = db
end

function Log:IsDebugEnabled()
    local db = self.db or CDPulseDB
    return db and db.debug and true or false
end

function Log:Write(level, spellID, msg)
    level = level or "INFO"
    
    -- Gate DEBUG/TRACE behind debug toggle
    if not self:IsDebugEnabled() and (level == "DEBUG" or level == "TRACE") then
        return
    end
    
    self._seq = self._seq + 1
    local entry = {
        time = GetTime(),
        seq = self._seq,
        level = level,
        spellID = spellID,
        msg = safeString(msg),
    }
    
    self.entries[#self.entries + 1] = entry
    
    -- Trim old entries
    while #self.entries > self.MAX_ENTRIES do
        table.remove(self.entries, 1)
    end
    
    self:_RefreshUI()
end

function Log:WriteAlways(level, spellID, msg)
    -- Bypass debug toggle for critical lifecycle events (INFO/WARN/ERROR).
    -- Still gate DEBUG/TRACE behind the debug toggle to avoid production spam.
    level = level or "INFO"
    if (level == "DEBUG" or level == "TRACE") and not self:IsDebugEnabled() then
        return
    end

    self._seq = self._seq + 1
    local entry = {
        time = GetTime(),
        seq = self._seq,
        level = level,
        spellID = spellID,
        msg = safeString(msg),
    }
    self.entries[#self.entries + 1] = entry
    while #self.entries > self.MAX_ENTRIES do
        table.remove(self.entries, 1)
    end
    self:_RefreshUI()
end

function Log:Clear()
    wipe(self.entries)
    self._seq = 0
    self:_RefreshUI()
end

function Log:GetText()
    local lines = {}
    for i = 1, #self.entries do
        local e = self.entries[i]
        if matchesFilter(self, e) then
            lines[#lines + 1] = formatEntry(e)
        end
    end
    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Filtering
--------------------------------------------------------------------------------

function Log:SetFilterSpellID(id)
    if id == nil or id == "" then
        self.filterSpellID = nil
    else
        self.filterSpellID = tonumber(id)
    end
    self:_RefreshUI()
end

function Log:SetFilterText(text)
    text = tostring(text or ""):match("^%s*(.-)%s*$")
    if text == "" then
        self.filterText = nil
    else
        self.filterText = string.lower(text)
    end
    self:_RefreshUI()
end

function Log:ClearFilters()
    self.filterSpellID = nil
    self.filterText = nil
    if self.frame then
        if self.frame._spellBox then self.frame._spellBox:SetText("") end
        if self.frame._textBox then self.frame._textBox:SetText("") end
    end
    self:_RefreshUI()
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local function CreateLogFrame()
    local f = CreateFrame("Frame", "CDPulseLogFrame", UIParent, "BackdropTemplate")
    f:SetSize(900, 550)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    
    f:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    
    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("CDPulse Log")
    
    -- Close button
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    
    -- Clear button
    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(70, 22)
    clearBtn:SetPoint("TOPRIGHT", -40, -10)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function() Log:Clear() end)
    
    -- Filter row
    local filterHelp = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    filterHelp:SetPoint("TOPLEFT", 12, -36)
    filterHelp:SetText("Filter by SpellID or text. Press Enter to apply.")
    
    local spellLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    spellLabel:SetPoint("TOPLEFT", 12, -56)
    spellLabel:SetText("SpellID:")
    
    local spellBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    spellBox:SetSize(100, 20)
    spellBox:SetPoint("LEFT", spellLabel, "RIGHT", 6, 0)
    spellBox:SetAutoFocus(false)
    spellBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        Log:SetFilterSpellID(self:GetText())
    end)
    f._spellBox = spellBox
    
    local textLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    textLabel:SetPoint("LEFT", spellBox, "RIGHT", 16, 0)
    textLabel:SetText("Search:")
    
    local textBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    textBox:SetSize(200, 20)
    textBox:SetPoint("LEFT", textLabel, "RIGHT", 6, 0)
    textBox:SetAutoFocus(false)
    textBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        Log:SetFilterText(self:GetText())
    end)
    f._textBox = textBox
    
    local applyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    applyBtn:SetSize(60, 20)
    applyBtn:SetPoint("LEFT", textBox, "RIGHT", 8, 0)
    applyBtn:SetText("Apply")
    applyBtn:SetScript("OnClick", function()
        Log:SetFilterSpellID(spellBox:GetText())
        Log:SetFilterText(textBox:GetText())
    end)
    
    local clearFilterBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearFilterBtn:SetSize(80, 20)
    clearFilterBtn:SetPoint("LEFT", applyBtn, "RIGHT", 6, 0)
    clearFilterBtn:SetText("Clear")
    clearFilterBtn:SetScript("OnClick", function() Log:ClearFilters() end)
    
    -- Scroll frame
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -82)
    scroll:SetPoint("BOTTOMRIGHT", -32, 12)
    
    local editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetFontObject("GameFontHighlightSmall")
    editBox:SetWidth(840)
    editBox:SetAutoFocus(false)
    editBox:EnableMouse(true)
    editBox:SetScript("OnEscapePressed", function() f:Hide() end)
    
    scroll:SetScrollChild(editBox)
    f._editBox = editBox
    f._scroll = scroll
    
    f:Hide() -- start hidden so first /cdp log shows it
    return f
end

function Log:_EnsureUI()
    if not self.frame then
        self.frame = CreateLogFrame()
    end
end

function Log:Toggle()
    self:_EnsureUI()
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        -- Sync filter boxes
        if self.frame._spellBox then
            self.frame._spellBox:SetText(self.filterSpellID and tostring(self.filterSpellID) or "")
        end
        if self.frame._textBox then
            self.frame._textBox:SetText(self.filterText or "")
        end
        self.frame:Show()
        self:_RefreshUI()
    end
end

function Log:_RefreshUI()
    if not self.frame or not self.frame:IsShown() then return end
    
    local text = self:GetText()
    self.frame._editBox:SetText(text)
    
    -- Scroll to bottom
    C_Timer.After(0, function()
        if self.frame and self.frame._scroll then
            local scrollBar = self.frame._scroll.ScrollBar
            if scrollBar then
                local _, max = scrollBar:GetMinMaxValues()
                scrollBar:SetValue(max)
            end
        end
    end)
end
