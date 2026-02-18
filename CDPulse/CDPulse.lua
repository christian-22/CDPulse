--[[
CDPulse.lua
Core addon: initialization, events, pulse UI, slash commands.
]]

local ADDON_NAME = ...
CDPulse = CDPulse or {}

local Log = CDPulse_Log
local Engine = CDPulse_Engine

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffb026ffCDPulse|r: " .. tostring(msg))
end

-- Shared spell name cache (used by Engine and Log modules)
local _spellNameCache = {}
local function GetSpellNameCached(spellID)
    if not spellID then return nil end
    if _spellNameCache[spellID] then return _spellNameCache[spellID] end
    
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok and name then
            _spellNameCache[spellID] = name
            return name
        end
    end
    
    local fallback = tostring(spellID)
    _spellNameCache[spellID] = fallback
    return fallback
end

-- Shared item name cache
local _itemNameCache = {}
local function GetItemNameCached(itemID)
    if not itemID then return nil end
    if _itemNameCache[itemID] then return _itemNameCache[itemID] end
    
    -- Try to get item name, but don't cache fallback immediately
    if C_Item and C_Item.GetItemNameByID then
        local ok, name = pcall(C_Item.GetItemNameByID, itemID)
        if ok and name and name ~= "" then
            _itemNameCache[itemID] = name
            return name
        end
    end
    
    -- Item not cached yet - try to load it asynchronously
    if Item and Item.CreateFromItemID then
        local item = Item:CreateFromItemID(itemID)
        if item then
            item:ContinueOnItemLoad(function()
                local loadedName = item:GetItemName()
                if loadedName and loadedName ~= "" then
                    _itemNameCache[itemID] = loadedName
                    -- Trigger UI refresh if options panel is open
                    if CDPulseOptionsPanel and CDPulseOptionsPanel:IsShown() then
                        C_Timer.After(0.1, function()
                            if CDPulse.RefreshOptionsRows then 
                                CDPulse.RefreshOptionsRows() 
                            end
                        end)
                    end
                end
            end)
        end
    end
    
    -- Return nil (not cached fallback) so UI shows "Loading..." or similar
    return nil
end

-- Export for other modules
CDPulse.GetSpellNameCached = GetSpellNameCached
CDPulse.GetItemNameCached = GetItemNameCached

-- Parse item ID from either a number or an item link
-- Item links look like: |cff0070dd|Hitem:219314::::::::70:581:::::::|h[Spymaster's Web]|h|r
local function ParseItemID(input)
    if not input then return nil end
    
    -- Try as number first
    local id = tonumber(input)
    if id and id > 0 then return id end
    
    -- Try parsing item link: |Hitem:219314:...
    if type(input) == "string" then
        local linkID = input:match("item:(%d+)")
        if linkID then
            id = tonumber(linkID)
            if id and id > 0 then return id end
        end
    end
    
    return nil
end


--------------------------------------------------------------------------------
-- SavedVariables Defaults
--------------------------------------------------------------------------------

local defaults = {
    whitelist = {},
    
    -- Pulse appearance
    size = 64,
    iconOpacity = 1,
    point = "CENTER",
    relPoint = "CENTER",
    x = 0,
    y = 120,
    pulseDuration = 1.00,
    
    -- Sound
    -- Historical behavior: "Default" is a real choice that maps to a Blizzard UI sound
    -- (not a LibSharedMedia-registered file). Keeping this preserves old saved-vars.
    soundName = "Default",
    soundChannel = "Master",
    -- EXACT legacy "Default" sound from CDPulse-1.2.0
    -- Used when the selected sound is "Default" and also as a safe fallback when a
    -- LibSharedMedia sound can't be resolved.
    fallbackSoundKitID = 12867,
    soundEnabled = true,
    spellSounds = {},
    
    -- Behavior
    locked = true,
    sortByName = true,
    noOverlapAlerts = true,

    -- Zone filter (all enabled by default)
    enabledInWorld = true,
    enabledInDungeons = true,
    enabledInRaids = true,
    enabledInArena = true,

    
    -- Debug
    debug = false,
    
    -- Aura gating: [spellID] = auraSpellID
    gatedAuras = {},
}

-- Generic key normalization (converts numeric keys to strings for consistency)
local function NormalizeTableKeys(tbl)
    if not tbl then return end
    for k, v in pairs(tbl) do
        if type(k) == "number" then
            local sk = tostring(k)
            if tbl[sk] == nil then
                tbl[sk] = v
            end
            tbl[k] = nil
        end
    end
end

local function EnsureDB()
    CDPulseDB = CDPulseDB or {}
    
    -- Validate critical table types before using them
    -- Protects against corrupted SavedVariables
    if type(CDPulseDB.whitelist) ~= "table" then
        if Log then
            Log:WriteAlways("INFO", nil, "Recovered from corrupted whitelist data")
        end
        CDPulseDB.whitelist = {}
    end
    if type(CDPulseDB.spellSounds) ~= "table" then
        if Log then
            Log:WriteAlways("INFO", nil, "Recovered from corrupted spellSounds data")
        end
        CDPulseDB.spellSounds = {}
    end
    if type(CDPulseDB.learnedGates) ~= "table" then
        CDPulseDB.learnedGates = {}
    end
    
    for k, v in pairs(defaults) do
        if CDPulseDB[k] == nil then
            CDPulseDB[k] = type(v) == "table" and {} or v
        end
    end

    -- Normalize legacy numeric keys
    NormalizeTableKeys(CDPulseDB.spellSounds)
    NormalizeTableKeys(CDPulseDB.whitelist)

    -- Keep legacy values as-is. "Default" is a valid selection and should NOT be
    -- replaced (users relied on it in older releases).


    return CDPulseDB
end


--------------------------------------------------------------------------------
-- LibSharedMedia Registration
--------------------------------------------------------------------------------

local function RegisterAddonSounds()
    if not LibStub then return end
    local LSM = LibStub("LibSharedMedia-3.0", true)
    if not LSM then return end
    
    local base = "Interface\\AddOns\\CDPulse\\sounds\\"
    LSM:Register("sound", "CDPulse: RAWN", base .. "RAWN.mp3")
    for i = 1, 11 do
        local key = string.format("SC%02d", i)
        LSM:Register("sound", "CDPulse: " .. key, base .. key .. ".mp3")
    end
end

--------------------------------------------------------------------------------
-- Pulse UI
--------------------------------------------------------------------------------

local pulseFrame
local anchorFrame
local pulseQueue = {}

local function GetSpellIcon(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.iconID then return info.iconID end
    end
    return nil
end

local function CreatePulseFrame()
    local f = CreateFrame("Frame", "CDPulsePulseFrame", UIParent)
    f:SetSize(64, 64)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    f:SetFrameStrata("HIGH")
    f:Hide()
    f:EnableMouse(false)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    
    f:SetScript("OnDragStart", function(self)
        if CDPulseDB and not CDPulseDB.locked then
            self:StartMoving()
        end
    end)
    
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if CDPulseDB then
            local point, _, relPoint, x, y = self:GetPoint(1)
            CDPulseDB.point = point
            CDPulseDB.relPoint = relPoint
            CDPulseDB.x = math.floor(x + 0.5)
            CDPulseDB.y = math.floor(y + 0.5)
        end
        -- Update anchor position
        if anchorFrame and anchorFrame:IsShown() then
            anchorFrame:ClearAllPoints()
            anchorFrame:SetAllPoints(pulseFrame)
        end
    end)
    
    -- Border (dark edge behind the icon)
    local border = f:CreateTexture(nil, "BACKGROUND")
    border:SetColorTexture(0, 0, 0, 1)
    f._border = border

    -- Texture
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f._tex = t
    
    -- Animation
    local ag = f:CreateAnimationGroup()
    local fadeOut = ag:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(0.60)
    fadeOut:SetSmoothing("OUT")
    
    ag:SetScript("OnPlay", function() f:Show() end)
    ag:SetScript("OnFinished", function()
        f:Hide()
        -- Process queue if enabled
        if CDPulseDB and CDPulseDB.noOverlapAlerts and #pulseQueue > 0 then
            local next = table.remove(pulseQueue, 1)
            if next and CDPulse.DoPulseNow then
                CDPulse.DoPulseNow(next.spellID, next.kind, next.isItem)
            end
        end
    end)
    
    f._ag = ag
    f._fadeOut = fadeOut
    
    return f
end

local function ApplyPulseSettings(db)
    if not pulseFrame then pulseFrame = CreatePulseFrame() end
    
    local size = tonumber(db.size) or 64
    pulseFrame:SetSize(size, size)
    pulseFrame:ClearAllPoints()
    pulseFrame:SetPoint(
        db.point or "CENTER",
        UIParent,
        db.relPoint or "CENTER",
        tonumber(db.x) or 0,
        tonumber(db.y) or 120
    )
    
    -- Border fills the full frame; icon is inset to reveal the dark edge.
    -- Inset scales with icon size so the border looks proportional at any size.
    local borderInset = math.max(1, math.floor(size * 0.04 + 0.5))
    pulseFrame._border:ClearAllPoints()
    pulseFrame._border:SetAllPoints(pulseFrame)
    pulseFrame._tex:ClearAllPoints()
    pulseFrame._tex:SetPoint("TOPLEFT", pulseFrame, "TOPLEFT", borderInset, -borderInset)
    pulseFrame._tex:SetPoint("BOTTOMRIGHT", pulseFrame, "BOTTOMRIGHT", -borderInset, borderInset)

    pulseFrame._tex:SetAlpha(tonumber(db.iconOpacity) or 1)
    pulseFrame._fadeOut:SetDuration(tonumber(db.pulseDuration) or 0.60)
    
    -- Lock/unlock
    local locked = (db.locked ~= false)
    pulseFrame:SetMovable(not locked)
    pulseFrame:EnableMouse(not locked)
    
    if anchorFrame then
        if locked then anchorFrame:Hide() else anchorFrame:Show() end
    end
end

local function PlayPulseSound(db, spellID)
    if not db.soundEnabled then return end
    
    local soundName = db.soundName
    
    -- Check for custom sound (try both regular and "i:" prefixed for items)
    local override = nil
    if db.spellSounds then
        -- Try regular spell lookup first
        override = db.spellSounds[tostring(spellID)] or db.spellSounds[spellID]
        
        -- If not found, try item lookup with "i:" prefix
        if not override then
            local itemKey = "i:" .. tostring(spellID)
            override = db.spellSounds[itemKey]
        end
    end
    
    if override and override ~= "" then
        soundName = override
    end
    
    if not soundName or soundName == "None" then return end

    -- "Default" is a Blizzard UI sound (not an LSM file)
    if soundName == "Default" then
        -- Match CDPulse-1.2.0 exactly
        PlaySound(db.fallbackSoundKitID or 12867, db.soundChannel or "Master")
        return
    end

    local channel = db.soundChannel or "Master"

    local path
    
    if LibStub then
        local lsm = LibStub("LibSharedMedia-3.0", true)
        if lsm then
            path = lsm:Fetch("sound", soundName, true)
        end
    end
    
    if path then
        PlaySoundFile(path, channel)
    else
        -- If the selected LSM entry can't be fetched, fall back to the legacy default.
        PlaySound(db.fallbackSoundKitID or 12867, channel)
    end
end

local function DoPulseNow(spellID, kind, isItem)
    local db = CDPulseDB
    if not pulseFrame then pulseFrame = CreatePulseFrame() end
    
    local icon
    if isItem then
        -- Item: use item icon API directly (never treat as spell ID)
        if C_Item and C_Item.GetItemIconByID then
            local ok, itemIcon = pcall(C_Item.GetItemIconByID, spellID)
            if ok and itemIcon then
                icon = itemIcon
            end
        end
    else
        -- Spell: try spell icon first, then item icon as fallback
        icon = GetSpellIcon(spellID)
        if not icon then
            if C_Item and C_Item.GetItemIconByID then
                local ok, itemIcon = pcall(C_Item.GetItemIconByID, spellID)
                if ok and itemIcon then
                    icon = itemIcon
                end
            end
        end
    end
    
    if icon then
        pulseFrame._tex:SetTexture(icon)
    end
    
    ApplyPulseSettings(db)
    pulseFrame._ag:Stop()
    pulseFrame._ag:Play()
    
    PlayPulseSound(db, spellID)
end

CDPulse.DoPulseNow = DoPulseNow

local function DoPulse(spellID, kind, isItem)
    local db = CDPulseDB
    if db and db.noOverlapAlerts and pulseFrame and pulseFrame._ag and pulseFrame._ag:IsPlaying() then
        pulseQueue[#pulseQueue + 1] = { spellID = spellID, kind = kind, isItem = isItem }
        return
    end
    DoPulseNow(spellID, kind, isItem)
end

--------------------------------------------------------------------------------
-- Event Frame
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

local function InitAddon()
    local db = EnsureDB()
    
    RegisterAddonSounds()
    
    Log:Init(db)
    Engine:Init(db)
    Engine:SetPulseHandler(DoPulse)
    Engine:RebuildTrackedSpells("init")
    
    ApplyPulseSettings(db)
    Print("Loaded. Use /cdp or /cdpulse to open settings.")

    
    if Log then
        Log:WriteAlways("INFO", nil, "CDPulse loaded")
    end
end

-- Only these events are relevant for our architecture
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("UNIT_AURA")

eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")  -- For item cooldown tracking

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            self:UnregisterEvent("ADDON_LOADED")
            InitAddon()
        end
        return
    end
    
    if event == "PLAYER_ENTERING_WORLD" then
        -- Reset grace period timer when actually entering world
        -- (ADDON_LOADED fires during loading screen, potentially many seconds before)
        if Engine and Engine._initTime then
            Engine._initTime = GetTime()
            if Log then
                Log:WriteAlways("DEBUG", nil, "Reset grace period timer on world enter")
            end
        end
        -- Re-evaluate zone filter for pulse suppression
        if Engine and Engine._EvaluateZoneEnabled then
            Engine:_EvaluateZoneEnabled()
        end
        return
    end
    
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" then
            Engine:OnPlayerCastSucceeded(spellID)
        end
        return
    end
    
    if event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then
            Engine:OnUnitAura()
        end
        return
    end

    if event == "SPELL_UPDATE_COOLDOWN" or event == "ACTIONBAR_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" then
        Engine:OnCooldownUpdate(event, ...)
        return
    end
    
    if event == "BAG_UPDATE_COOLDOWN" then
        Engine:OnItemCooldownUpdate()
        return
    end
end)

--------------------------------------------------------------------------------
-- Public API (for Options panel)
--------------------------------------------------------------------------------

function CDPulse_ShowAnchor()
    local db = EnsureDB()
    if not pulseFrame then pulseFrame = CreatePulseFrame() end
    
    if not anchorFrame then
        anchorFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        anchorFrame:SetFrameStrata("HIGH")
        anchorFrame:SetBackdrop({
            bgFile = "Interface/Buttons/WHITE8X8",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        anchorFrame:SetBackdropColor(0, 0, 0, 0.15)
        anchorFrame:SetBackdropBorderColor(0.7, 0.7, 0.7, 0.9)
        
        local label = anchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER")
        label:SetText("CDPulse Anchor")
    end
    
    anchorFrame:ClearAllPoints()
    anchorFrame:SetAllPoints(pulseFrame)
    anchorFrame:EnableMouse(true)
    anchorFrame:SetScript("OnMouseDown", function()
        if CDPulseDB and not CDPulseDB.locked then
            pulseFrame:StartMoving()
        end
    end)
    anchorFrame:SetScript("OnMouseUp", function()
        if CDPulseDB and not CDPulseDB.locked then
            pulseFrame:StopMovingOrSizing()
            local point, _, relPoint, x, y = pulseFrame:GetPoint(1)
            CDPulseDB.point = point
            CDPulseDB.relPoint = relPoint
            CDPulseDB.x = math.floor(x + 0.5)
            CDPulseDB.y = math.floor(y + 0.5)
        end
    end)
    
    anchorFrame:Show()
    ApplyPulseSettings(db)
end

function CDPulse_HideAnchor()
    if anchorFrame then anchorFrame:Hide() end
end

function CDPulse_ApplySettings()
    local db = EnsureDB()
    ApplyPulseSettings(db)
    Engine:RebuildTrackedSpells("apply_settings")
end

function CDPulse_TestPulse(spellID)
    local db = EnsureDB()
    if not spellID then
        local testIsItem = false
        for k, enabled in pairs(db.whitelist or {}) do
            if enabled then
                -- Item keys are prefixed with "i:" (e.g., "i:255613")
                local itemIDStr = type(k) == "string" and k:match("^i:(%d+)")
                if itemIDStr then
                    spellID = tonumber(itemIDStr)
                    testIsItem = true
                else
                    spellID = tonumber(k)
                    testIsItem = false
                end
                if spellID then break end
            end
        end
        if not spellID then 
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000CDPulse Error:|r Add a spell to the tracked spells list to test an alert.")
            return false 
        end
        DoPulse(spellID, "TEST", testIsItem)
        return true
    end
    
    DoPulse(tonumber(spellID) or 0, "TEST")
    return true
end

function CDPulse_OpenOptions()
    if Settings and Settings.OpenToCategory then
        Settings.OpenToCategory("CDPulse")
        return
    end
    if InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory("CDPulse")
        InterfaceOptionsFrame_OpenToCategory("CDPulse")
    end
end

--------------------------------------------------------------------------------
-- Slash Commands
--------------------------------------------------------------------------------

-- Options open is protected in combat; defer opening until combat ends.
local _pendingOpenOptions = false
local _combatOpenFrame = CreateFrame("Frame")
local function _OpenOptionsSafely()
    if InCombatLockdown and InCombatLockdown() then
        _pendingOpenOptions = true
        Print("Settings will open after combat ends.")
        _combatOpenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    _pendingOpenOptions = false
    _combatOpenFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
    CDPulse_OpenOptions()
end

_combatOpenFrame:SetScript("OnEvent", function()
    if _pendingOpenOptions then
        _OpenOptionsSafely()
    end
end)

local function ListSpells()
    local db = CDPulseDB
    local count = 0
    
    for k, v in pairs(db.whitelist or {}) do
        if v then
            count = count + 1
            
            -- Check if this is an item (prefixed with "i:")
            local isItem = type(k) == "string" and k:match("^i:(%d+)") ~= nil
            local id
            local name = "Unknown"
            local typeLabel
            
            if isItem then
                -- It's an item
                local itemIDStr = k:match("^i:(%d+)")
                id = tonumber(itemIDStr)
                typeLabel = "Item"
                if id then
                    name = GetItemNameCached(id)
                end
            else
                -- It's a spell
                id = tonumber(k)
                typeLabel = "Spell"
                if id and C_Spell and C_Spell.GetSpellInfo then
                    local info = C_Spell.GetSpellInfo(id)
                    if info and info.name then name = info.name end
                end
            end
            
            local rec = Engine.records and id and Engine.records[id]
            local state = rec and Engine:_GetWatchState(rec) or "NOT_TRACKING"
            
            Print(string.format("[%s] %s (%s ID: %s) - %s",
                rec and "OK" or "!",
                name,
                typeLabel,
                tostring(id or k),
                state))
        end
    end
    
    if count == 0 then
        Print("No tracked spells or items. Use /cdp add <spellID> or /cdp additem <itemID>.")
    end
end

SLASH_CDPULSE1 = "/cdp"
SLASH_CDPULSE2 = "/cdpulse"
SlashCmdList["CDPULSE"] = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^%s*(%S+)%s*(.-)%s*$")
    cmd = cmd and cmd:lower() or ""
    
    if cmd == "" or cmd == "options" then
        _OpenOptionsSafely()
        return
    end
    
    if cmd == "log" then
        local arg1, arg2 = rest:match("^%s*(%S+)%s*(.-)%s*$")
        if arg1 and arg1 ~= "" then
            local a = arg1:lower()
            if a == "off" or a == "clear" then
                Log:ClearFilters()
            elseif a == "search" then
                Log:SetFilterText(arg2)
            else
                local sid = tonumber(arg1)
                if sid then
                    Log:SetFilterSpellID(sid)
                else
                    Log:SetFilterText(rest)
                end
            end
        end
        Log:Toggle()
        return
    end
    
    if cmd == "clearlog" then
        Log:Clear()
        Print("Log cleared.")
        return
    end
    
    if cmd == "debug" then
        CDPulseDB.debug = not CDPulseDB.debug
        Print("Debug logging: " .. (CDPulseDB.debug and "ON" or "OFF"))
        return
    end
    
    if cmd == "add" then
        local id = tonumber(rest)
        local ok, err = Engine:AddSpell(id)
        if ok then
            Print("Added spellID " .. tostring(id))
        else
            Print("Add failed: " .. tostring(err))
        end
        return
    end
    
    if cmd == "additem" then
        local id = ParseItemID(rest)
        if not id then
            Print("Usage: /cdp additem <itemID> or /cdp additem [Item Link]")
            Print("Tip: Shift+click an item to paste its link")
            return
        end
        local ok, err = Engine:AddItem(id)
        if ok then
            local itemName = GetItemNameCached(id)
            Print("Added item: " .. itemName .. " (ID: " .. tostring(id) .. ")")
        else
            Print("Add item failed: " .. tostring(err))
        end
        return
    end
    
    if cmd == "remove" or cmd == "del" then
        local id = tonumber(rest)
        local ok, err = Engine:RemoveSpell(id)
        if ok then
            Print("Removed spellID " .. tostring(id))
        else
            Print("Remove failed: " .. tostring(err))
        end
        return
    end
    
    if cmd == "removeitem" or cmd == "delitem" then
        local id = ParseItemID(rest)
        if not id then
            Print("Usage: /cdp removeitem <itemID> or /cdp removeitem [Item Link]")
            return
        end
        local ok, err = Engine:RemoveItem(id)
        if ok then
            Print("Removed itemID " .. tostring(id))
        else
            Print("Remove item failed: " .. tostring(err))
        end
        return
    end
    
    if cmd == "list" then
        ListSpells()
        return
    end
    
    if cmd == "test" then
        local id = tonumber(rest)
        CDPulse_TestPulse(id)
        return
    end
    
    if cmd == "dump" then
        Engine:DumpState()
        Print("State dumped to log. Use /cdp log to view.")
        return
    end
    
    Print("Commands: /cdp, add <id>, remove <id>, additem <id|link>, removeitem <id|link>, list, test [id], debug, log, clearlog, dump")
end