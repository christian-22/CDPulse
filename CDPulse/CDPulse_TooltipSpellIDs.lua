--[[
CDPulse_TooltipSpellIDs.lua
Optional module: Adds "Spell ID: <id>" and "Item ID: <id>" to tooltips when enabled.
Designed to be decoupled from the rest of the addon.
]]

local ADDON_NAME = ...

local PURPLE_R, PURPLE_G, PURPLE_B = 0.690196, 0.149020, 1.000000  -- #b026ff

local function IsEnabled()
    return CDPulseDB and CDPulseDB.showSpellIDsInTooltips == true
end

local function EnsureClearHook(tooltip)
    if tooltip.__cdpSpellIdClearHook then return end
    tooltip.__cdpSpellIdClearHook = true

    tooltip:HookScript("OnTooltipCleared", function(tip)
        tip.__cdpSpellIdLastSpellID = nil
        tip.__cdpItemIdLastItemID = nil
    end)
end

local function TryGetSpellIDFromTooltip(tooltip, data)
    -- Prefer tooltip:GetSpell(); it works for spell tooltips and most aura tooltips.
    if tooltip and tooltip.GetSpell then
        local ok, _, _, sid = pcall(tooltip.GetSpell, tooltip)
        if ok and type(sid) == "number" then
            -- Verify it's not a secret value by trying to use it
            local okUse, val = pcall(tonumber, sid)
            if okUse and val then return val end
        end
    end

    -- Fallbacks for TooltipDataProcessor payloads.
    if data then
        local spellID = data.spellID or data.id
        if type(spellID) == "number" then
            local okUse, val = pcall(tonumber, spellID)
            if okUse and val then return val end
        end
        if type(spellID) == "string" then
            local n = tonumber(spellID)
            if n then return n end
        end

        if type(data.hyperlink) == "string" then
            local n = tonumber(string.match(data.hyperlink, "spell:(%d+)"))
            if n then return n end
        end
    end

    return nil
end

local function AddSpellIdLine(tooltip, spellID)
    if not tooltip or type(spellID) ~= "number" then return end

    -- spellID may be a Midnight secret value (wrapped number that throws on
    -- comparison or arithmetic). Guard every operation that touches it.
    local okCheck, valid = pcall(function() return spellID > 0 end)
    if not okCheck or not valid then return end

    EnsureClearHook(tooltip)

    -- Dedupe: tooltips refresh frequently while hovering.
    local okCmp, same = pcall(function() return tooltip.__cdpSpellIdLastSpellID == spellID end)
    if okCmp and same then return end
    tooltip.__cdpSpellIdLastSpellID = spellID

    local okFmt, line = pcall(string.format, "Spell ID: %d (CDPulse)", spellID)
    if not okFmt or not line then return end

    tooltip:AddLine(line, PURPLE_R, PURPLE_G, PURPLE_B)
    tooltip:Show()
end

-- Add item ID line to tooltip
local function AddItemIdLine(tooltip, itemID)
    if not tooltip or type(itemID) ~= "number" then return end

    local okCheck, valid = pcall(function() return itemID > 0 end)
    if not okCheck or not valid then return end

    EnsureClearHook(tooltip)

    -- Dedupe: use separate key for items
    local okCmp, same = pcall(function() return tooltip.__cdpItemIdLastItemID == itemID end)
    if okCmp and same then return end
    tooltip.__cdpItemIdLastItemID = itemID

    local okFmt, line = pcall(string.format, "Item ID: %d (CDPulse)", itemID)
    if not okFmt or not line then return end

    tooltip:AddLine(line, PURPLE_R, PURPLE_G, PURPLE_B)
    tooltip:Show()
end

-- Try to extract item ID from tooltip
local function TryGetItemIDFromTooltip(tooltip)
    if not tooltip then return nil end
    
    -- Try tooltip:GetItem() for item tooltips
    if tooltip.GetItem then
        local ok, _, itemLink = pcall(tooltip.GetItem, tooltip)
        if ok and itemLink and type(itemLink) == "string" then
            -- Extract from item link: |Hitem:219314:...
            local id = tonumber(itemLink:match("item:(%d+)"))
            if id and id > 0 then
                return id
            end
        end
    end
    
    return nil
end

local function OnSpellTooltipProcessed(tooltip, data)
    if not IsEnabled() then return end

    local spellID = TryGetSpellIDFromTooltip(tooltip, data)
    if spellID then
        AddSpellIdLine(tooltip, spellID)
    end
end

local function OnItemTooltipProcessed(tooltip, data)
    if not IsEnabled() then return end
    
    local itemID = TryGetItemIDFromTooltip(tooltip)
    if itemID and itemID > 0 then
        AddItemIdLine(tooltip, itemID)
    end
end

local function RegisterTooltipDataProcessor()
    if not TooltipDataProcessor or not TooltipDataProcessor.AddTooltipPostCall then
        return false
    end
    if not Enum or not Enum.TooltipDataType then
        return false
    end

    local function tryRegister(typeKey, callback)
        local dt = Enum.TooltipDataType[typeKey]
        if dt ~= nil then
            TooltipDataProcessor.AddTooltipPostCall(dt, callback)
            return true
        end
        return false
    end

    -- Register spell tooltips with spell callback
    local ok = false
    ok = tryRegister("Spell", OnSpellTooltipProcessed) or ok
    ok = tryRegister("UnitAura", OnSpellTooltipProcessed) or ok

    -- Some builds may expose slightly different keys for spells
    ok = tryRegister("Aura", OnSpellTooltipProcessed) or ok
    ok = tryRegister("UnitBuff", OnSpellTooltipProcessed) or ok
    ok = tryRegister("UnitDebuff", OnSpellTooltipProcessed) or ok
    
    -- Register item tooltips with item callback
    ok = tryRegister("Item", OnItemTooltipProcessed) or ok

    return ok
end

local function RegisterFallbackHooks()
    if not GameTooltip then return end

    if GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetSpell", function(tip)
            if not IsEnabled() then return end
            local spellID = TryGetSpellIDFromTooltip(tip, nil)
            if spellID then AddSpellIdLine(tip, spellID) end
        end)

        -- Not all builds fire this reliably for every aura source, but it's a decent fallback.
        GameTooltip:HookScript("OnTooltipSetUnitAura", function(tip)
            if not IsEnabled() then return end
            local spellID = TryGetSpellIDFromTooltip(tip, nil)
            if spellID then AddSpellIdLine(tip, spellID) end
        end)
        
        -- Hook for item tooltips
        GameTooltip:HookScript("OnTooltipSetItem", function(tip)
            if not IsEnabled() then return end
            local itemID = TryGetItemIDFromTooltip(tip)
            if itemID and itemID > 0 then 
                AddItemIdLine(tip, itemID) 
            end
        end)
    end
end

-- Initialize immediately; this module is safe even if CDPulseDB isn't populated yet.
if not RegisterTooltipDataProcessor() then
    RegisterFallbackHooks()
end
