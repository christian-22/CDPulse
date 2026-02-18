--[[
CDPulse_Engine.lua
Cooldown and charge completion detection engine.

HOW IT WORKS:
1. When you cast a tracked spell, the engine starts watching for completion
2. It binds to WoW's CooldownFrame system to detect when cooldowns/charges finish
3. When complete, it triggers an alert (the pulse visual + sound)

SPELL LIFECYCLE:
  IDLE       -> Player casts spell
  WATCHING   -> Engine binds to cooldown/charge timer
  READY      -> Timer completes, pulse triggered, back to IDLE

SPECIAL CASES:
- Charged spells: Pulses once per charge gained until all charges restored
- Aura-gated spells: Some spells (like Prowl) apply a buff; pulse waits until buff ends
]]

local ADDON_NAME = ...
CDPulse_Engine = {}
local Engine = CDPulse_Engine

local Log -- Set during Init

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local KIND_COOLDOWN = "CD"
local KIND_CHARGE = "CHARGE"

-- Stop trying to bind after this many seconds (safety valve)
local BIND_TIMEOUT_SECONDS = 60

-- Suppress pulses for this many seconds after init to prevent spurious alerts
-- on login/reload (e.g., cross-character passive timer fires for off-CD spells)
local INIT_GRACE_PERIOD = 2.0

-- Timing windows for detection and debouncing
local CHARGE_NATURAL_PULSE_WINDOW = 0.25  -- Time window to distinguish natural recharge from external grant (increased from 0.10 for lag tolerance)
local AURA_DETECTION_WINDOW = 0.35        -- Time after cast to detect self-buff application
local GATE_REOPEN_DELAY = 0.8             -- Delay before confirming aura truly ended (handles multi-stack aura flicker)

--------------------------------------------------------------------------------
-- Internal State
--------------------------------------------------------------------------------

Engine.records = {}           -- [spellID] = record for each tracked spell
Engine.spellIDToRecord = {}   -- [spellID] = record (includes variant spell IDs)
Engine.nameToRecords = {}     -- [spellName] = { record, ... }
Engine.db = nil


--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

local function safeSpellID(id)
    local n = tonumber(id)
    return (n and n > 0) and n or nil
end

local function safeItemID(id)
    local n = tonumber(id)
    return (n and n > 0) and n or nil
end

local function getSpellName(spellID)
    return CDPulse.GetSpellNameCached and CDPulse.GetSpellNameCached(spellID) 
           or tostring(spellID)
end

local function getItemName(itemID)
    return CDPulse.GetItemNameCached and CDPulse.GetItemNameCached(itemID)
           or tostring(itemID)
end

local function getItemIcon(itemID)
    if not itemID then return 134400 end  -- Default icon
    if C_Item and C_Item.GetItemIconByID then
        local ok, icon = pcall(C_Item.GetItemIconByID, itemID)
        if ok and icon then return icon end
    end
    return 134400
end

local function hasPlayerAura(spellID)
    if not spellID then return false end
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
        return ok and aura ~= nil
    end
    return false
end

-- Aura gate modes: how to handle spells that apply buffs
local GATE_DEFER_PULSE = "defer_pulse"      -- Cooldown runs immediately; hold pulse until aura ends
local GATE_AFTER_AURA  = "after_aura"       -- Cooldown starts after aura ends (e.g., Prowl)

-- Time window after cast to detect if spell applies a self-buff
local AURA_DETECTION_WINDOW = 0.35

-- Delay before confirming an aura-gated spell's aura has truly ended.
-- Covers Blizzard's aura-flicker pattern where multi-stack auras (e.g.,
-- Presence of Mind) briefly disappear and reappear when a stack is consumed.
-- Blizzard's re-application can take over 1 second, so this must be generous.
local GATE_REOPEN_DELAY = 0.8

local function spellHasCharges(spellID)
    if not spellID then return false end
    if C_Spell and C_Spell.GetSpellCharges then
        local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
        return ok and info ~= nil
    end
    return false
end

-- Check if an item is on cooldown and return duration info
local function getItemCooldownDuration(itemID)
    if not itemID or not C_Item or not C_Item.GetItemCooldown then
        return nil
    end
    
    local ok, start, duration, enabled = pcall(C_Item.GetItemCooldown, itemID)
    if not ok or not start or not duration or not enabled then
        return nil
    end
    
    if duration == 0 or not enabled then
        return nil
    end
    
    -- Return start and duration directly (not a duration object)
    -- Items don't have duration objects like spells do
    return start, duration
end

-- Safely read current charge count (pcall-wrapped for Midnight safety).
-- Returns a plain number or nil if the call fails or values are secret.
local function safeGetChargeCount(spellID)
    if not spellID then return nil end
    if not (C_Spell and C_Spell.GetSpellCharges) then return nil end
    local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
    if not ok or not info then return nil end
    local okRead, current = pcall(function() return tonumber(info.currentCharges) end)
    if okRead and current then return current end
    return nil
end

--------------------------------------------------------------------------------
-- Timer Widget Creation
--------------------------------------------------------------------------------

-- Creates an invisible CooldownFrame that fires OnCooldownDone when complete.
-- The widget must be shown (even at alpha=0) for the timer to tick.
local function CreateTimerWidget(rec, kind)
    local widget = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
    widget:SetSize(1, 1)
    widget:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -100, -100)
    widget:SetAlpha(0)
    widget:EnableMouse(false)
    widget:SetHideCountdownNumbers(true)
    widget:SetDrawEdge(false)
    widget:SetDrawBling(false)
    widget:Show()
    
    widget._rec = rec
    widget._kind = kind
    widget._bindToken = nil
    
    widget:SetScript("OnCooldownDone", function(w)
        Engine:_OnTimerComplete(w)
    end)
    
    return widget
end

--------------------------------------------------------------------------------
-- Spell Record Management
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Readiness State Tracking
--------------------------------------------------------------------------------

local function InitReadinessState(rec)
    -- Track last-known readiness for edge detection
    rec.lastCooldownReady = true
    rec.lastGateOpen = true
    rec.lastEffectiveReady = true
    rec.lastPulseTime = 0
    
    -- Whether passive timer is bound (for detecting resets)
    rec.passiveTimerBound = false
end


-- Update gate state and emit pulse when spell becomes fully ready.
-- For GATE_DEFER_PULSE: cooldown runs during aura, pulse held until aura ends.
-- For GATE_AFTER_AURA: aura end unblocks binding, pulse comes from _OnTimerComplete.
local function UpdateEffectiveReadiness(rec, reason)
    if not rec.gateAuraSpellID and not rec.gateMode then return end

    local gateOpen = rec.gateOpen and true or false
    rec.lastGateOpen = gateOpen

    -- For GATE_AFTER_AURA, don't emit from here — just track gate state.
    -- The real cooldown hasn't started until the aura ends, so the pulse
    -- will come from _OnTimerComplete after the actual cooldown finishes.
    if rec.gateMode == GATE_AFTER_AURA then
        return
    end

    -- GATE_DEFER_PULSE: spell is ready when BOTH cooldown is done AND gate is open
    local cooldownReady = rec.lastCooldownReady and true or false
    local nowReady = cooldownReady and gateOpen
    local wasReady = rec.lastEffectiveReady

    if wasReady ~= nowReady then
        rec.lastEffectiveReady = nowReady
        if Engine._enabled and (wasReady == false or wasReady == nil) and nowReady == true then
            Engine:_EmitPulse(rec.spellID, KIND_COOLDOWN, "aura ended", rec.isItem)
        end
    end
end

-- Bind passive timer to detect cooldown resets even when not actively watching
local function TryBindPassiveTimer(rec, force)
    if not rec or not rec.cdWidget then return false end
    if rec.isItem then return false end  -- Don't bind passive timers for items
    if rec.passiveTimerBound and not force then return true end

    -- Try multiple spell IDs to find one with a valid cooldown.
    -- PRIORITY: Override > Primary > ActiveID
    -- This handles both talent overrides (Stealth) and multi-form spells (Alter Time)
    local candidateIDs = {}
    
    -- 1. Try talent override FIRST (if different from primary)
    local overrideID = Engine:_GetOverrideSpell(rec.spellID)
    if overrideID and overrideID ~= rec.spellID then
        table.insert(candidateIDs, overrideID)
    end
    
    -- 2. Try the recorded spell ID (what user is tracking)
    table.insert(candidateIDs, rec.spellID)
    
    -- 3. Try activeSpellID if set and different
    if rec.activeSpellID and rec.activeSpellID ~= rec.spellID and rec.activeSpellID ~= overrideID then
        table.insert(candidateIDs, rec.activeSpellID)
    end
    
    -- 4. Try all registered variant IDs (excluding ones already tried)
    for variantID in pairs(rec.variantSpellIDs) do
        if variantID ~= rec.spellID and variantID ~= rec.activeSpellID and variantID ~= overrideID then
            table.insert(candidateIDs, variantID)
            -- Also check if the variant has an override
            local variantOverride = Engine:_GetOverrideSpell(variantID)
            if variantOverride and variantOverride ~= variantID and variantOverride ~= rec.spellID and variantOverride ~= rec.activeSpellID then
                table.insert(candidateIDs, variantOverride)
            end
        end
    end
    
    -- Try each candidate until we find one with a valid cooldown that binds successfully
    for _, bindID in ipairs(candidateIDs) do
        -- Validation: If we have an activeID (what was cast) and this candidate doesn't match it,
        -- verify the candidate is actually a known spell. This prevents binding to inactive
        -- override IDs like tracking 115191 (Subterfuge) when talent isn't active.
        local needsValidation = (rec.activeSpellID and bindID ~= rec.activeSpellID)
        local isValid = true
        
        if needsValidation and type(IsPlayerSpell) == "function" then
            local ok, known = pcall(IsPlayerSpell, bindID)
            if ok and known == false then
                -- Spell isn't known. Check if it's an active override of another spell we know.
                local isKnownOverride = false
                
                -- Check if this is the override of our primary spell (and different from it)
                local primaryOverride = Engine:_GetOverrideSpell(rec.spellID)
                if primaryOverride == bindID and primaryOverride ~= rec.spellID then
                    isKnownOverride = true
                end
                
                -- Check if this is the override of any variant (and different from it)
                if not isKnownOverride then
                    for variantID in pairs(rec.variantSpellIDs) do
                        local variantOverride = Engine:_GetOverrideSpell(variantID)
                        if variantOverride == bindID and variantOverride ~= variantID then
                            isKnownOverride = true
                            break
                        end
                    end
                end
                
                if not isKnownOverride then
                    isValid = false
                end
            end
        end
        
        if isValid then
            local dur = Engine:_GetCooldownDuration(bindID)
            if dur then
                local ok = pcall(function()
                    rec.cdWidget:SetCooldownFromDurationObject(dur, true)
                end)
                
                if ok then
                    if rec.cdWidget and not rec.cdWidget:IsShown() then
                        rec.cdWidget:Show()
                    end
                    rec.passiveTimerBound = true
                    return true
                end
            end
        end
    end

    return false
end


-- Handle cooldown update events to keep timers in sync
function Engine:OnCooldownUpdate(event, ...)
    if not self.records then return end

    for _, rec in pairs(self.records) do
        if event == "SPELL_UPDATE_COOLDOWN" or event == "ACTIONBAR_UPDATE_COOLDOWN" then
            rec.passiveTimerBound = false
            TryBindPassiveTimer(rec, true)
        elseif not rec.watchToken then
            TryBindPassiveTimer(rec, false)
        end
    end

    -- Detect externally-granted charges (e.g., Time Walk + Alter Time)
    if event == "SPELL_UPDATE_CHARGES" then
        self:_CheckExternalChargeGrants()
    end

    self:_ProcessPendingBinds(event)
end


-- Detect externally-granted charges (e.g., Time Walk granting Blink charges
-- via Alter Time return). Compares current charge count against the last
-- snapshot and emits pulses for any unexpected gains.
-- All charge count reads and comparisons are pcall-wrapped for Midnight safety.
--
-- RACE CONDITION: SPELL_UPDATE_CHARGES fires for BOTH natural recharges and
-- external grants. When a natural recharge completes, SPELL_UPDATE_CHARGES
-- often arrives BEFORE OnCooldownDone fires on the chargeWidget. This means
-- we can't simply pulse on any +1 delta — we'd double-pulse every natural
-- recharge.
--
-- SOLUTION: _OnTimerComplete sets rec._chargeNaturalPulseTime when it emits a
-- charge pulse via the natural OnCooldownDone path. If SPELL_UPDATE_CHARGES
-- sees a +1 delta but a natural pulse happened within the same frame window,
-- it was a natural completion, not an external grant.
--
-- When the natural timer is bound (chargeBound=true) and a charge increase
-- is detected that WASN'T from a natural completion, it's an external grant.
-- In that case we emit the pulse AND rebind the chargeWidget (which is now
-- stale — it's still counting down the old recharge that was cut short).
function Engine:_CheckExternalChargeGrants()
    if not self._enabled then return end
    if not self.records then return end

    local now = GetTime()

    for _, rec in pairs(self.records) do
        -- Resolve the spell ID to check charges against
        local checkID = rec.activeSpellID or rec.spellID
        if not spellHasCharges(checkID) then
            checkID = rec.spellID
            if not spellHasCharges(checkID) then
                -- Not a charged spell; check override as last resort
                local overrideID = self:_GetOverrideSpell(rec.spellID)
                if overrideID and overrideID ~= rec.spellID and spellHasCharges(overrideID) then
                    checkID = overrideID
                else
                    -- skip non-charged spells
                end
            end
        end

        if not spellHasCharges(checkID) then
            -- Definitely not a charged spell, nothing to check
        else
            local currentCharges = safeGetChargeCount(checkID)
            if currentCharges == nil then
                -- Can't read charges (secret or error); skip
            else
                local previous = rec.lastKnownCharges

                if previous == nil then
                    -- First observation: just record it, don't pulse
                    rec.lastKnownCharges = currentCharges
                else
                    -- Compare safely via pcall (Midnight: charge counts may be secret)
                    local okCmp, gained = pcall(function()
                        return currentCharges - previous
                    end)

                    if not okCmp or not gained then
                        -- Comparison failed (secret values); update snapshot
                        rec.lastKnownCharges = currentCharges
                    elseif gained > 0 then
                        -- Did the natural OnCooldownDone path already handle this?
                        -- _OnTimerComplete sets _chargeNaturalPulseTime when it emits
                        -- a charge pulse. If that happened very recently (same frame),
                        -- this SPELL_UPDATE_CHARGES is just the natural companion event.
                        local naturalTime = rec._chargeNaturalPulseTime or 0
                        if (now - naturalTime) < CHARGE_NATURAL_PULSE_WINDOW then
                            -- Natural timer just pulsed; this is not an external grant
                            rec.lastKnownCharges = currentCharges
                        else
                            if Log then
                                Log:Write("INFO", rec.spellID,
                                    "External charge grant detected (+" .. tostring(gained)
                                    .. ", now " .. tostring(currentCharges) .. ")")
                            end

                            -- Emit one pulse per gained charge
                            for i = 1, gained do
                                self:_EmitPulse(rec.spellID, KIND_CHARGE, "charge", rec.isItem)
                            end

                            -- The chargeWidget (if bound) is now stale — it's still
                            -- counting down the old recharge that was cut short by
                            -- the external grant. Clear it so it can be rebound to
                            -- the current state.
                            if rec.chargeBound and rec.chargeWidget then
                                rec.chargeWidget:Clear()
                                rec.chargeWidget._bindToken = nil
                                rec.chargeBound = false
                            end

                            -- Check if spell is now at max charges
                            local okMax, atMax = pcall(function()
                                local info = C_Spell.GetSpellCharges(checkID)
                                if info and info.currentCharges and info.maxCharges then
                                    return info.currentCharges >= info.maxCharges
                                end
                                return false
                            end)

                            if okMax and atMax then
                                -- All charges restored: end the watching session
                                rec.chargeSessionActive = false
                                if rec.watchToken then
                                    self:_StopWatching(rec, "external_full")
                                end
                            else
                                -- Still recharging: mark for rebind.
                                -- _ProcessPendingBinds (called after this) will
                                -- rebind chargeWidget to the current recharge.
                                rec.bindStartTime = now
                            end

                            rec.lastKnownCharges = currentCharges
                        end
                    elseif gained < 0 then
                        -- Charges decreased (player cast a charge): update snapshot
                        rec.lastKnownCharges = currentCharges
                    else
                        -- No change
                        rec.lastKnownCharges = currentCharges
                    end
                end
            end
        end
    end
end


local function CreateRecord(spellID, isItem)
    local rec = {
        spellID = spellID,
        spellName = isItem and getItemName(spellID) or getSpellName(spellID),
        
        -- Item tracking fields
        isItem = isItem or false,
        itemID = isItem and spellID or nil,
        
        -- Variant spell IDs (some spells cast with different IDs)
        variantSpellIDs = {},
        
        -- Watching state
        watchToken = nil,           -- nil = idle, number = watching
        watchTokenCounter = 0,      -- Monotonic counter for tokens
        
        -- Timer binding state
        cdBound = false,
        chargeBound = false,
        
        -- Timer widgets
        cdWidget = nil,
        chargeWidget = nil,
        
        -- For charged spells: keep watching until all charges restored
        chargeSessionActive = false,

        -- External charge grant detection
        lastKnownCharges = nil,  -- number|nil: last observed charge count
        
        -- Aura gating (for spells that apply buffs)
        gateAuraSpellID = nil,
        gateMode = nil,             -- GATE_DEFER_PULSE or GATE_AFTER_AURA
        gatePhase = nil,            -- For GATE_AFTER_AURA: 'WAIT_CLOSE'|'WAIT_OPEN'|'WAIT_OPEN_DEBOUNCE'|'READY'
        gateOpen = true,
        gateEverSeen = false,       -- Track if we've ever seen this aura (prevents false triggers)
        pendingPulses = {},
        _gateDebounceToken = 0,     -- Monotonic counter to invalidate stale gate-open timers
        _deferDebouncing = false,   -- true while GATE_DEFER_PULSE is in debounce phase
        _gateOpenedAt = nil,        -- GetTime() when gate opened (for dud detection)

        -- Aura detection window
        detectAuraUntil = nil,
        castTime = 0,
        
        -- Safety timeout for binding
        bindStartTime = nil,
    }
    
    InitReadinessState(rec)

    -- Load persisted gate mode from previous sessions
    if Engine.db and Engine.db.learnedGates then
        local learned = Engine.db.learnedGates[spellID]
        if learned then
            rec.gateModeLearned = learned
            -- Determine which ID carries the aura (base or override)
            local auraID = spellID
            if not hasPlayerAura(spellID) then
                if C_Spell and C_Spell.GetOverrideSpell then
                    local ok, overrideID = pcall(C_Spell.GetOverrideSpell, spellID)
                    if ok and overrideID and overrideID ~= 0 and overrideID ~= spellID then
                        auraID = overrideID
                    end
                end
            end
            rec.gateAuraSpellID = auraID
            rec.gateMode = learned
            rec.gateOpen = not hasPlayerAura(auraID)
            if learned == GATE_AFTER_AURA then
                rec.gatePhase = rec.gateOpen and nil or "WAIT_OPEN"
            end
            if Log then
                Log:Write("DEBUG", spellID, "Loaded persisted gate mode: " .. tostring(learned) .. " (aura on " .. tostring(auraID) .. ")")
            end
        end
    end

    rec.cdWidget = CreateTimerWidget(rec, KIND_COOLDOWN)
    rec.chargeWidget = CreateTimerWidget(rec, KIND_CHARGE)

    -- Bind passive timer for detecting resets
    TryBindPassiveTimer(rec)

    -- Initialize charge snapshot for external grant detection
    rec.lastKnownCharges = safeGetChargeCount(spellID)
    
    return rec
end

local function DestroyRecord(rec)
    if rec.cdWidget then
        rec.cdWidget:SetScript("OnCooldownDone", nil)
        rec.cdWidget:SetParent(nil)      -- Orphan from UIParent
        rec.cdWidget:ClearAllPoints()    -- Release anchor references
        rec.cdWidget:Hide()
        rec.cdWidget = nil
    end
    if rec.chargeWidget then
        rec.chargeWidget:SetScript("OnCooldownDone", nil)
        rec.chargeWidget:SetParent(nil)      -- Orphan from UIParent
        rec.chargeWidget:ClearAllPoints()    -- Release anchor references
        rec.chargeWidget:Hide()
        rec.chargeWidget = nil
    end
end

--------------------------------------------------------------------------------
-- Watch State Management
--------------------------------------------------------------------------------

-- Called when player casts a tracked spell
function Engine:_StartWatching(rec, castSpellID)
    local activeID = safeSpellID(castSpellID) or rec.spellID

    -- For charged spells, don't restart if already watching for charges
    if spellHasCharges(activeID) and rec.chargeSessionActive and rec.watchToken then
        rec.activeSpellID = activeID
        if Log then
            Log:Write("DEBUG", rec.spellID, "Cast detected (charge recharging, watching for next charge)")
        end
        return
    end

    rec.watchTokenCounter = rec.watchTokenCounter + 1
    rec.watchToken = rec.watchTokenCounter
    rec.cdBound = false
    rec.chargeBound = false

    -- Spell is now on cooldown
    rec.lastCooldownReady = false
    rec.lastEffectiveReady = false
    rec.passiveTimerBound = false

    rec.bindStartTime = GetTime()

    -- Track if this is a charged spell
    rec.chargeSessionActive = spellHasCharges(activeID)
    
    rec.pendingPulses = rec.pendingPulses or {}

    -- Handle aura-gated spells
    if rec.gateModeLearned == GATE_AFTER_AURA then
        -- Re-resolve which ID carries the aura. Talent overrides may change it
        -- (e.g., Stealth aura is on 1784 normally but 115191 with Subterfuge).
        local auraID = rec.gateAuraSpellID or rec.spellID
        local overrideID = Engine:_GetOverrideSpell(rec.spellID)
        if overrideID and overrideID ~= rec.spellID then
            auraID = overrideID
        end
        rec.gateAuraSpellID = auraID
        rec.gateMode = GATE_AFTER_AURA
        -- We KNOW this spell applies a self-buff (it's already learned).
        -- The aura may not be visible yet at cast time (race condition),
        -- so always assume gateOpen=false at cast start. OnUnitAura will
        -- open the gate when the aura actually ends.
        rec.gateOpen = false
        rec.gatePhase = "WAIT_OPEN"
        rec.detectAuraUntil = nil
        rec._gateOpenedAt = nil
        rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
    elseif Engine.db and Engine.db.learnedGates and Engine.db.learnedGates[rec.spellID] == GATE_AFTER_AURA then
        -- Record was created before this talent was active, but a previous
        -- session learned the gate mode. Apply it now.
        rec.gateModeLearned = GATE_AFTER_AURA
        -- Determine which ID carries the aura (base or override)
        local auraID = rec.spellID
        local overrideID = Engine:_GetOverrideSpell(rec.spellID)
        if overrideID and overrideID ~= rec.spellID then
            auraID = overrideID
        end
        rec.gateAuraSpellID = auraID
        rec.gateMode = GATE_AFTER_AURA
        -- Always assume aura will be active at cast start (race condition safe)
        rec.gateOpen = false
        rec.gatePhase = "WAIT_OPEN"
        rec.detectAuraUntil = nil
        rec._gateOpenedAt = nil
        rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
        if Log then
            Log:Write("DEBUG", rec.spellID, "Applied persisted gate mode on cast (aura on " .. tostring(auraID) .. ")")
        end
    elseif rec.gateAuraSpellID then
        rec.gateMode = GATE_DEFER_PULSE
        rec.gateOpen = not hasPlayerAura(rec.gateAuraSpellID)
        rec.gatePhase = nil
        rec.detectAuraUntil = nil
        rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
    else
        rec.gateMode = nil
        rec.gateOpen = true
        rec.gatePhase = nil
        -- Watch for self-buff to detect aura-gated spells (fallback learning).
        -- Only the _OnTimerComplete detection window should classify spells as
        -- GATE_AFTER_AURA, because it requires the timer to fire nearly instantly
        -- while the aura is active — which is the actual signal that the cooldown
        -- doesn't start until the aura ends. Checking hasPlayerAura here at cast
        -- time is too aggressive and would misclassify spells like Feint that
        -- have self-buffs but normal cooldowns.
        -- Skip detection window for charged spells - they often have self-buffs
        -- (e.g., Feint) but their charge cooldown runs independently of the buff.
        local isCharged = spellHasCharges(activeID)
        if not isCharged then
            rec.castTime = GetTime()
            rec.detectAuraUntil = rec.castTime + AURA_DETECTION_WINDOW
            -- If a talent override is active, store it as a hint for the detection window
            local overrideID = Engine:_GetOverrideSpell(rec.spellID)
            if overrideID and overrideID ~= rec.spellID then
                rec._overrideAuraID = overrideID
            else
                rec._overrideAuraID = nil
            end
        else
            rec.castTime = nil
            rec.detectAuraUntil = nil
            rec._overrideAuraID = nil
        end
    end

    rec.activeSpellID = activeID

    -- Snapshot charge count for external grant detection
    rec.lastKnownCharges = safeGetChargeCount(activeID) or safeGetChargeCount(rec.spellID)

    -- Clear timer widgets
    if rec.cdWidget then
        rec.cdWidget:Clear()
        rec.cdWidget._bindToken = nil
    end
    if rec.chargeWidget then
        rec.chargeWidget:Clear()
        rec.chargeWidget._bindToken = nil
    end

    if Log then
        local mode = rec.chargeSessionActive and "charges" or "cooldown"
        Log:Write("INFO", rec.spellID, "Cast -> watching " .. mode)
    end
end


-- Called when done watching (timer complete or timeout)
function Engine:_StopWatching(rec, reason)
    if not rec.watchToken then return end
    
    rec.watchToken = nil
    rec.cdBound = false
    rec.chargeBound = false
    rec.chargeSessionActive = false

    -- Keep activeSpellID for charge count snapshot even after watching ends.
    -- It serves as a hint for the last cast variant and has fallback logic in
    -- _CheckExternalChargeGrants if the ID becomes stale (lines 268-280).
    -- This intentional caching helps with spell ID variant resolution.
    local chargeID = rec.activeSpellID or rec.spellID
    rec.lastKnownCharges = safeGetChargeCount(chargeID)

    if Log then
        Log:Write("DEBUG", rec.spellID, "Cleanup: " .. tostring(reason))
    end
end

-- Get current watch state
function Engine:_GetWatchState(rec)
    if not rec.watchToken then
        return "IDLE"
    elseif rec.cdBound or rec.chargeBound then
        return "WATCHING"
    else
        return "BINDING"
    end
end

--------------------------------------------------------------------------------
-- Spell ID Resolution
--------------------------------------------------------------------------------

-- Some spells cast with variant IDs but share a cooldown
function Engine:_ResolveSpellID(rec)
    if rec.activeSpellID then
        -- Check if talent has replaced this spell with a different ID
        local overrideID = self:_GetOverrideSpell(rec.activeSpellID)
        if overrideID and overrideID ~= rec.activeSpellID then
            return overrideID
        end
        return rec.activeSpellID
    end

    -- Try multiple spell IDs to find one with a valid cooldown.
    -- Prioritize the spell that was actually cast.
    local candidateIDs = {}
    
    -- 1. Try talent override of primary spell first
    local overrideID = self:_GetOverrideSpell(rec.spellID)
    if overrideID and overrideID ~= rec.spellID then
        table.insert(candidateIDs, overrideID)
    end
    
    -- 2. Try primary spell ID
    table.insert(candidateIDs, rec.spellID)
    
    -- 3. Try all variant IDs
    for variantID in pairs(rec.variantSpellIDs) do
        table.insert(candidateIDs, variantID)
        -- Also try override of variant
        local variantOverride = self:_GetOverrideSpell(variantID)
        if variantOverride and variantOverride ~= variantID then
            table.insert(candidateIDs, variantOverride)
        end
    end
    
    -- Return first ID that has a cooldown duration and binds successfully
    for _, spellID in ipairs(candidateIDs) do
        local dur = self:_GetCooldownDuration(spellID)
        if dur then
            return spellID
        end
    end

    -- Fallback to primary spell ID even if no cooldown found
    return rec.spellID
end


--------------------------------------------------------------------------------
-- Duration Object Access (NO value reads - only pass to widgets)
--------------------------------------------------------------------------------

-- Resolve talent-replaced spell IDs (e.g. Stealth 1784 -> 115191 via Subterfuge)
function Engine:_GetOverrideSpell(spellID)
    if C_Spell and C_Spell.GetOverrideSpell then
        local ok, overrideID = pcall(C_Spell.GetOverrideSpell, spellID)
        if ok and overrideID and overrideID ~= 0 then
            return overrideID
        end
    end
    return spellID
end

function Engine:_GetCooldownDuration(spellID)
    if C_Spell and C_Spell.GetSpellCooldownDuration then
        local ok, dur = pcall(C_Spell.GetSpellCooldownDuration, spellID)
        if ok then return dur end
    end
    return nil
end

function Engine:_GetChargeDuration(spellID)
    if C_Spell and C_Spell.GetSpellChargeDuration then
        local ok, dur = pcall(C_Spell.GetSpellChargeDuration, spellID)
        if ok then return dur end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Timer Binding
--------------------------------------------------------------------------------

function Engine:_TryBindCooldown(rec)
    if rec.cdBound then return true end
    if not rec.cdWidget then return false end

    -- ITEM TRACKING: Items use different API
    if rec.isItem then
        local start, duration = getItemCooldownDuration(rec.itemID)
        if start and duration then
            if Log then
                Log:Write("DEBUG", rec.itemID, string.format("Item cooldown: start=%.2f, duration=%.2f, now=%.2f, remaining=%.2f", 
                    start, duration, GetTime(), (start + duration) - GetTime()))
            end
            local ok, err = pcall(function()
                rec.cdWidget:SetCooldown(start, duration)
            end)
            
            if ok then
                if rec.cdWidget and not rec.cdWidget:IsShown() then
                    rec.cdWidget:Show()
                end
                rec.cdBound = true
                rec.cdWidget._bindToken = rec.watchToken
                if Log then
                    Log:Write("DEBUG", rec.itemID, "Bound to item cooldown timer (itemID: " .. tostring(rec.itemID) .. ")")
                end
                return true
            else
                if Log then
                    Log:Write("TRACE", rec.itemID, "Item binding failed: " .. tostring(err))
                end
            end
        else
            if Log then
                Log:Write("TRACE", rec.itemID, "No cooldown duration for item " .. tostring(rec.itemID))
            end
        end
        return false
    end

    -- SPELL TRACKING: Continue with existing spell logic
    -- For aura-gated spells, wait until aura ends
    if rec.gateMode == GATE_AFTER_AURA then
        if rec.gatePhase ~= "READY" then
            return false
        end
    end

    local activeID = rec.activeSpellID or self:_ResolveSpellID(rec)

    -- Try multiple spell IDs to find one with a valid cooldown.
    -- PRIORITY: Override > Primary > ActiveID  
    -- This handles both talent overrides (Stealth) and multi-form spells (Alter Time)
    local candidateIDs = {}
    
    -- 1. Try talent override FIRST (if different from primary)
    local overrideID = self:_GetOverrideSpell(rec.spellID)
    if overrideID and overrideID ~= rec.spellID then
        table.insert(candidateIDs, overrideID)
    end
    
    -- 2. Try primary spell ID (what user is tracking)
    table.insert(candidateIDs, rec.spellID)
    
    -- 3. Try activeID if different (what was actually cast)
    if activeID and activeID ~= rec.spellID and activeID ~= overrideID then
        table.insert(candidateIDs, activeID)
    end
    
    -- 4. Try all registered variant IDs (excluding ones already tried)
    for variantID in pairs(rec.variantSpellIDs) do
        if variantID ~= rec.spellID and variantID ~= activeID and variantID ~= overrideID then
            table.insert(candidateIDs, variantID)
            -- Also check if the variant has an override
            local variantOverride = self:_GetOverrideSpell(variantID)
            if variantOverride and variantOverride ~= variantID and variantOverride ~= rec.spellID and variantOverride ~= activeID then
                table.insert(candidateIDs, variantOverride)
            end
        end
    end
    
    if Log then
        local candidateStr = {}
        for i, id in ipairs(candidateIDs) do
            candidateStr[i] = tostring(id)
        end
        Log:Write("TRACE", rec.spellID, "Trying to bind cooldown (activeID=" .. tostring(activeID) .. ", candidates=[" .. table.concat(candidateStr, ", ") .. "])")
    end
    
    -- Try each candidate until we find one with a valid cooldown that binds successfully
    for _, bindID in ipairs(candidateIDs) do
        -- Validation: If we have an activeID (what was cast) and this candidate doesn't match it,
        -- verify the candidate is actually a known spell. This prevents binding to inactive
        -- override IDs like tracking 115191 (Subterfuge) when talent isn't active.
        local needsValidation = (activeID and bindID ~= activeID)
        local isValid = true
        
        if needsValidation and type(IsPlayerSpell) == "function" then
            local ok, known = pcall(IsPlayerSpell, bindID)
            if ok and known == false then
                -- Spell isn't known. Check if it's an active override of another spell we know.
                -- This handles talent overrides like 115191 when Subterfuge IS active.
                local isKnownOverride = false
                
                -- Check if this is the override of our primary spell (and different from it)
                local primaryOverride = self:_GetOverrideSpell(rec.spellID)
                if primaryOverride == bindID and primaryOverride ~= rec.spellID then
                    isKnownOverride = true
                end
                
                -- Check if this is the override of any variant (and different from it)
                if not isKnownOverride then
                    for variantID in pairs(rec.variantSpellIDs) do
                        local variantOverride = self:_GetOverrideSpell(variantID)
                        if variantOverride == bindID and variantOverride ~= variantID then
                            isKnownOverride = true
                            break
                        end
                    end
                end
                
                if not isKnownOverride then
                    isValid = false
                    if Log then
                        Log:Write("TRACE", rec.spellID, "Skipping " .. tostring(bindID) .. " (not known by player, not active override)")
                    end
                end
            end
        end
        
        if isValid then
            local dur = self:_GetCooldownDuration(bindID)
            if dur then
                local ok, err = pcall(function()
                    rec.cdWidget:SetCooldownFromDurationObject(dur, true)
                end)
                
                if ok then
                    if rec.cdWidget and not rec.cdWidget:IsShown() then
                        rec.cdWidget:Show()
                    end
                    rec.cdBound = true
                    rec.cdWidget._bindToken = rec.watchToken
                    if Log then
                        Log:Write("DEBUG", rec.spellID, "Bound to cooldown timer (bindID: " .. tostring(bindID) .. ")")
                    end
                    return true
                else
                    if Log then
                        Log:Write("TRACE", rec.spellID, "Binding failed for " .. tostring(bindID) .. ": " .. tostring(err))
                    end
                end
            else
                if Log then
                    Log:Write("TRACE", rec.spellID, "No cooldown duration for " .. tostring(bindID))
                end
            end
        end
    end

    if Log then
        Log:Write("WARN", rec.spellID, "Failed to bind cooldown: no valid spell ID found")
    end
    return false
end

function Engine:_TryBindCharge(rec)
    if rec.chargeBound then return true end
    if not rec.chargeWidget then return false end

    -- For aura-gated spells, wait until aura ends
    if rec.gateMode == GATE_AFTER_AURA and rec.gatePhase ~= "READY" then
        return false
    end

    local activeID = rec.activeSpellID or self:_ResolveSpellID(rec)

    if not spellHasCharges(activeID) then
        return false
    end

    local dur = self:_GetChargeDuration(activeID)

    if not dur then return false end

    local ok, err = pcall(function()
        rec.chargeWidget:SetCooldownFromDurationObject(dur, true)
    end)

    if ok then
        if rec.chargeWidget and not rec.chargeWidget:IsShown() then
            rec.chargeWidget:Show()
        end
        rec.chargeBound = true
        rec.chargeWidget._bindToken = rec.watchToken
        if Log then
            Log:Write("DEBUG", rec.spellID, "Bound to charge timer")
        end
        return true
    else
        if Log then
            Log:Write("WARN", rec.spellID, "Failed to bind charge: " .. tostring(err))
        end
        return false
    end
end


--------------------------------------------------------------------------------
-- Binding Verification
--------------------------------------------------------------------------------

function Engine:_VerifyBindings(rec)
    local valid = true
    
    -- Check cooldown widget
    if rec.cdBound then
        local w = rec.cdWidget
        if not w then
            if Log then
                Log:Write("TRACE", rec.spellID, "Rebinding cooldown (widget lost)")
            end
            rec.cdBound = false
            valid = false
        elseif w._bindToken ~= rec.watchToken then
            if Log then
                Log:Write("TRACE", rec.spellID, "Rebinding cooldown (stale)")
            end
            rec.cdBound = false
            valid = false
        elseif not w:IsShown() then
            -- Widget may have been hidden; try to show it
            if w._triedShowForToken ~= rec.watchToken then
                w._triedShowForToken = rec.watchToken
                w:Show()
            end

            if not w:IsShown() then
                if Log then
                    Log:Write("TRACE", rec.spellID, "Rebinding cooldown (hidden)")
                end
                rec.cdBound = false
                rec.cdWidget = nil
                valid = false
            end
        end
    end
    
    -- Check charge widget
    if rec.chargeBound then
        local w = rec.chargeWidget
        if not w then
            if Log then
                Log:Write("TRACE", rec.spellID, "Rebinding charge (widget lost)")
            end
            rec.chargeBound = false
            valid = false
        elseif w._bindToken ~= rec.watchToken then
            if Log then
                Log:Write("TRACE", rec.spellID, "Rebinding charge (stale)")
            end
            rec.chargeBound = false
            valid = false
        elseif not w:IsShown() then
            -- Widget may have been hidden; try to show it
            if w._triedShowForToken ~= rec.watchToken then
                w._triedShowForToken = rec.watchToken
                w:Show()
            end

            if not w:IsShown() then
                if Log then
                    Log:Write("TRACE", rec.spellID, "Rebinding charge (hidden)")
                end
                rec.chargeBound = false
                if not rec.chargeWidget then
                    rec.chargeWidget = CreateTimerWidget(rec, KIND_CHARGE)
                end
                if rec.chargeWidget then
                    rec.chargeWidget:Clear()
                    rec.chargeWidget._bindToken = nil
                    if not rec.chargeWidget:IsShown() then
                        rec.chargeWidget:Show()
                    end
                end
                valid = false
            end
        end
    end
    
    return valid
end

--------------------------------------------------------------------------------
-- Timer Complete Handler
--------------------------------------------------------------------------------

function Engine:_OnTimerComplete(widget)
    local rec = widget._rec
    local kind = widget._kind

    if not rec then return end
    
    -- SNAPSHOT all state immediately to guard against race conditions.
    -- If the user casts the spell the instant it comes off cooldown,
    -- _StartWatching may run concurrently and modify rec state.
    -- By capturing everything upfront, we ensure the pulse completes
    -- even if state changes mid-execution.
    local snapshot = {
        spellID = rec.spellID,
        isItem = rec.isItem,
        widgetToken = widget._bindToken,
        watchToken = rec.watchToken,
        lastCooldownReady = rec.lastCooldownReady,
        cdBound = rec.cdBound,
        chargeBound = rec.chargeBound,
        gateAuraSpellID = rec.gateAuraSpellID,
        gateMode = rec.gateMode,
        gateOpen = rec.gateOpen,
        gateModeLearned = rec.gateModeLearned,
        detectAuraUntil = rec.detectAuraUntil,
        activeSpellID = rec.activeSpellID,
        chargeSessionActive = rec.chargeSessionActive,
    }

    local wasReady = nil
    local suppressed = false

    -- Handle cooldown completion
    if kind == KIND_COOLDOWN then
        wasReady = snapshot.lastCooldownReady

        -- Detect aura-gated spells: if timer completes while self-buff is active,
        -- this spell's cooldown actually starts after the buff ends.
        -- Skip for charged spells — they often have self-buffs (e.g., Feint)
        -- but their charge cooldown runs independently of the buff.
        if rec.detectAuraUntil and GetTime() <= rec.detectAuraUntil
           and (not snapshot.gateAuraSpellID) and (not snapshot.gateModeLearned)
           and (not snapshot.chargeSessionActive) then
            -- Check both base and override spell IDs for aura
            local auraID = nil
            if hasPlayerAura(snapshot.spellID) then
                auraID = snapshot.spellID
            else
                -- Check override ID, or use the hint from _StartWatching
                local checkID = rec._overrideAuraID
                if not checkID then
                    local overrideID = Engine:_GetOverrideSpell(snapshot.spellID)
                    if overrideID and overrideID ~= snapshot.spellID then
                        checkID = overrideID
                    end
                end
                if checkID and hasPlayerAura(checkID) then
                    auraID = checkID
                end
            end

            if auraID then
                rec.gateAuraSpellID = auraID
                rec.gateModeLearned = GATE_AFTER_AURA
                rec.gateMode = GATE_AFTER_AURA
                rec.gatePhase = "WAIT_OPEN"
                rec.gateOpen = false
                rec.detectAuraUntil = nil
                rec._overrideAuraID = nil
                rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1

                -- Persist learned gate mode
                if Engine.db then
                    Engine.db.learnedGates = Engine.db.learnedGates or {}
                    Engine.db.learnedGates[snapshot.spellID] = GATE_AFTER_AURA
                end

                if Log then
                    Log:Write("INFO", snapshot.spellID, "Detected aura-gated spell (pulse after aura ends, aura on " .. tostring(auraID) .. ")")
                end

                -- Suppress the pulse. The real cooldown hasn't started yet
                -- (it starts when the aura ends). Do NOT set lastCooldownReady.
                suppressed = true
            elseif rec._overrideAuraID and not snapshot.chargeSessionActive then
                -- Talent override is active but aura isn't visible yet (race
                -- condition: dud timer fired before aura was applied). Suppress
                -- this completion — the detection window is still open and we'll
                -- catch the aura on the next timer fire or via OnUnitAura.
                suppressed = true
                if Log then
                    Log:Write("TRACE", snapshot.spellID, "Override active, waiting for aura to appear...")
                end
            end
        end

        -- For aura-gated spells, suppress pulse while aura is active
        if snapshot.gateMode == GATE_AFTER_AURA and snapshot.gateOpen == false then
            suppressed = true
            -- Do NOT set lastCooldownReady here. For GATE_AFTER_AURA, the real
            -- cooldown hasn't started yet — it starts when the aura ends. These
            -- timer completions are from dud/instant timers, not the real cooldown.
            if Log then
                Log:Write("TRACE", snapshot.spellID, "Cooldown done but aura still active, waiting...")
            end
        else
            rec.lastCooldownReady = true
        end
    end

    -- Emit pulse for cooldown completion
    if self._enabled and kind == KIND_COOLDOWN and (wasReady == false) and (not suppressed) then
        if snapshot.gateMode == GATE_AFTER_AURA then
            -- Check for dud timer after gate open: if the timer completes
            -- very quickly after the gate opened, it means the cooldown
            -- wasn't actually running — stacks likely remain. This handles
            -- multi-stack auras (e.g. Presence of Mind) where Blizzard's
            -- aura re-application takes longer than the debounce window.
            local DUD_AFTER_GATE_THRESHOLD = 1.0
            if rec._gateOpenedAt and (GetTime() - rec._gateOpenedAt) < DUD_AFTER_GATE_THRESHOLD then
                -- False alarm: re-close the gate and go back to waiting.
                rec.gatePhase = "WAIT_OPEN"
                rec.gateOpen = false
                rec.lastCooldownReady = false
                rec._gateOpenedAt = nil
                rec.cdBound = false
                if Log then
                    Log:Write("DEBUG", snapshot.spellID, "Dud timer after gate open — aura stacks likely remain, re-closing gate")
                end
                return
            end
            -- For GATE_AFTER_AURA, the real cooldown just finished (gate is open,
            -- aura already ended). Emit directly — don't go through
            -- UpdateEffectiveReadiness which is for GATE_DEFER_PULSE only.
            self:_EmitPulse(snapshot.spellID, KIND_COOLDOWN, "cooldown", snapshot.isItem)
        elseif snapshot.gateAuraSpellID or snapshot.gateMode then
            UpdateEffectiveReadiness(rec, "timer_complete")
        else
            self:_EmitPulse(snapshot.spellID, KIND_COOLDOWN, "cooldown", snapshot.isItem)
        end

        -- Use snapshot for cleanup check to avoid race with _StartWatching
        if snapshot.watchToken and snapshot.widgetToken == snapshot.watchToken and snapshot.cdBound then
            self:_StopWatching(rec, "done")
        end

        return
    end

    -- If suppressed due to aura gating, stay in WATCHING for aura-end detection.
    -- Don't fall through to _StopWatching — OnUnitAura will call
    -- UpdateEffectiveReadiness when the aura ends, which will emit the pulse.
    if suppressed and kind == KIND_COOLDOWN then
        if kind == KIND_COOLDOWN then rec.cdBound = false end
        return
    end

    
    -- Validate state using snapshot
    if not snapshot.watchToken then
        return
    end
    
    if snapshot.widgetToken ~= snapshot.watchToken then
        return
    end
    
    local wasBound = (kind == KIND_COOLDOWN and snapshot.cdBound) or (kind == KIND_CHARGE and snapshot.chargeBound)
    if not wasBound then
        return
    end
    
    -- Handle aura gating
    if snapshot.gateAuraSpellID then
        local auraActive = hasPlayerAura(snapshot.gateAuraSpellID)
        rec.gateOpen = not auraActive

        if snapshot.gateMode == GATE_AFTER_AURA and auraActive then
            if Log then
                Log:Write("TRACE", snapshot.spellID, "Timer done but aura active, waiting...")
            end
            if kind == KIND_COOLDOWN then rec.cdBound = false end
            if kind == KIND_CHARGE then rec.chargeBound = false end
            return
        end

        if not rec.gateOpen then
            if snapshot.gateMode == GATE_DEFER_PULSE then
                rec.pendingPulses[kind] = (rec.pendingPulses[kind] or 0) + 1
                if Log then
                    Log:Write("DEBUG", snapshot.spellID, "Ready but aura active, queued pulse")
                end
                self:_StopWatching(rec, "gated")
                return
            else
                if kind == KIND_COOLDOWN then rec.cdBound = false end
                if kind == KIND_CHARGE then rec.chargeBound = false end
                return
            end
        end
    end

    -- Emit pulse for charge completion
    if kind == KIND_CHARGE then
        -- Mark that the natural timer path is handling this charge completion.
        -- _CheckExternalChargeGrants uses this to avoid double-pulsing when
        -- SPELL_UPDATE_CHARGES races with OnCooldownDone on the same frame.
        rec._chargeNaturalPulseTime = GetTime()
        self:_EmitPulse(snapshot.spellID, KIND_CHARGE, "charge", snapshot.isItem)
    end

    -- For charged spells, keep watching until all charges are restored
    if kind == KIND_CHARGE then
        local activeID = snapshot.activeSpellID or snapshot.spellID
        local ok, info = pcall(function()
            if C_Spell and C_Spell.GetSpellCharges then
                return C_Spell.GetSpellCharges(activeID)
            end
            return nil
        end)

        -- Update charge snapshot after natural completion
        local afterCount = safeGetChargeCount(activeID)
        if afterCount then
            rec.lastKnownCharges = afterCount
        end

        -- Charge counts may be protected; compare safely
        local moreChargesComing = false
        if ok and info and info.currentCharges and info.maxCharges then
            local okCmp, cmpResult = pcall(function()
                return info.currentCharges < info.maxCharges
            end)
            if okCmp then
                moreChargesComing = (cmpResult == true)
            else
                moreChargesComing = true
            end
        end

        if moreChargesComing then
            rec.chargeBound = false
            rec.bindStartTime = GetTime()
            if Log then
                local okCur, curNum = pcall(function() return tonumber(info.currentCharges) end)
                local okMax, maxNum = pcall(function() return tonumber(info.maxCharges) end)
                if okCur and okMax and curNum and maxNum then
                    Log:Write("DEBUG", snapshot.spellID,
                        string.format("Charge gained (%d/%d), watching for next", curNum, maxNum))
                else
                    Log:Write("DEBUG", snapshot.spellID, "Charge gained, watching for next")
                end
            end
            return
        end

        -- All charges restored
        rec.chargeSessionActive = false
        if Log then
            Log:Write("DEBUG", snapshot.spellID, "All charges restored")
        end
        self:_StopWatching(rec, "full")
        return
    end

    self:_StopWatching(rec, "done")
end


-- Zone filter: evaluate whether pulses should fire in the current zone.
-- Called on PLAYER_ENTERING_WORLD (zone transitions) and from the options UI
-- when the user toggles a zone checkbox.  The result is cached in
-- self._pulsesEnabled so that _EmitPulse only needs a single boolean check.
function Engine:_EvaluateZoneEnabled()
    local db = CDPulseDB or {}
    local _, instanceType = GetInstanceInfo()
    local zoneName
    if instanceType == "party" then
        self._pulsesEnabled = (db.enabledInDungeons ~= false)
        zoneName = "Dungeon"
    elseif instanceType == "raid" then
        self._pulsesEnabled = (db.enabledInRaids ~= false)
        zoneName = "Raid"
    elseif instanceType == "arena" then
        self._pulsesEnabled = (db.enabledInArena ~= false)
        zoneName = "Arena"
    else
        self._pulsesEnabled = (db.enabledInWorld ~= false)
        zoneName = "World"
    end
    if Log then
        Log:Write("INFO", nil, "Zone filter: " .. zoneName .. " (instanceType=" .. tostring(instanceType) .. ") — pulses " .. (self._pulsesEnabled and "ENABLED" or "DISABLED"))
    end
end


function Engine:_EmitPulse(spellID, kind, reason, isItem)
    -- Suppress pulses during the post-init grace period to prevent spurious
    -- alerts from passive timer fires on login/reload (e.g., spells that are
    -- off cooldown on a different character than the one that tracked them).
    if self._initTime and (GetTime() - self._initTime) < INIT_GRACE_PERIOD then
        if Log then
            Log:Write("DEBUG", spellID, "Suppressed pulse during init grace period (" .. tostring(reason) .. ")")
        end
        return
    end

    -- Zone filter: suppress pulses in disabled zone types (cached boolean).
    if self._pulsesEnabled == false then
        if Log then
            Log:Write("INFO", spellID, "Suppressed pulse — zone filter (pulses disabled in current zone)")
        end
        return
    end

    -- Don't pulse for spells the player doesn't know (e.g., after class swap).
    -- However, talent override spell IDs (e.g., 115191 Subterfuge Stealth) may
    -- return false for IsPlayerSpell even though the player has the spell.
    -- In that case, check if any tracked base spell overrides to this ID.
    -- Items are NOT spells: skip the IsPlayerSpell check entirely for them.
    if not isItem and type(IsPlayerSpell) == "function" then
        local okKnown, known = pcall(IsPlayerSpell, spellID)
        if okKnown and known == false then
            -- Check if this is a known override before blocking
            local isKnownOverride = false
            local rec = self.spellIDToRecord and self.spellIDToRecord[spellID] or nil
            if rec then
                -- If the record's base spell is different, check that
                if rec.spellID ~= spellID then
                    local okBase, baseKnown = pcall(IsPlayerSpell, rec.spellID)
                    if okBase and baseKnown then
                        isKnownOverride = true
                    end
                end
                -- If this spell has a gateModeLearned or is being actively watched, trust it
                if rec.gateModeLearned or rec.watchToken then
                    isKnownOverride = true
                end
            end
            if not isKnownOverride then
                return
            end
        end
    end

    -- For equippable items (trinkets, gear), suppress pulse if not currently
    -- equipped. Consumables (potions, etc.) are not equippable and always pulse.
    -- This check lives here rather than at watch-start because equipped state
    -- may not be settled when BAG_UPDATE_COOLDOWN fires (e.g., 30s swap CD).
    if isItem and type(IsEquippableItem) == "function" then
        local okEquippable, equippable = pcall(IsEquippableItem, spellID)
        if okEquippable and equippable then
            local okEquipped, equipped = pcall(IsEquippedItem, spellID)
            if okEquipped and not equipped then
                if Log then
                    Log:Write("DEBUG", spellID, "Suppressed pulse for unequipped equippable item")
                end
                return
            end
        end
    end

    local rec = self.spellIDToRecord and self.spellIDToRecord[spellID] or nil

    -- Charged spells only pulse on charge completion
    if rec and (rec.chargeSessionActive or (type(spellHasCharges) == "function" and spellHasCharges(spellID))) then
        if tostring(kind) ~= "CHARGE" then
            return
        end
        if tostring(reason) ~= "charge" then
            return
        end
    end

    -- Debounce rapid pulses
    local now = GetTime()
    if rec then
        local last = rec.lastPulseTime or 0
        if (now - last) < 0.05 then
            return
        end
        rec.lastPulseTime = now
    end

    if Log then
        Log:Write("INFO", spellID, "READY! (" .. tostring(reason) .. ")")
    end

    if self._pulseHandler then
        local ok, err = pcall(self._pulseHandler, spellID, kind, isItem)
        if not ok and Log then
            Log:Write("ERROR", spellID, "Pulse handler error: " .. tostring(err))
        end
    end
end


--------------------------------------------------------------------------------
-- Pending Binding Processor
--------------------------------------------------------------------------------

function Engine:_ProcessPendingBinds(reason)
    local now = GetTime()

    for _, rec in pairs(self.records) do
        local state = self:_GetWatchState(rec)

        if state == "BINDING" then
            -- Timeout protection
            if rec.bindStartTime and (now - rec.bindStartTime) > BIND_TIMEOUT_SECONDS then
                if Log then
                    Log:Write("WARN", rec.spellID, "Bind timeout - spell may not trigger alerts")
                end
                self:_StopWatching(rec, "timeout")
            else
                local activeID = rec.activeSpellID or rec.spellID
                if spellHasCharges(activeID) then
                    self:_TryBindCharge(rec)
                else
                    self:_TryBindCooldown(rec)
                    self:_TryBindCharge(rec)
                end
            end

        elseif state == "WATCHING" then
            self:_VerifyBindings(rec)
        end
    end
end

--------------------------------------------------------------------------------
-- Cast Event Handler
--------------------------------------------------------------------------------

function Engine:OnPlayerCastSucceeded(castSpellID)
    castSpellID = safeSpellID(castSpellID)
    if not castSpellID then return end
    
    local rec = self.spellIDToRecord[castSpellID]
    
    -- Try matching by spell name if ID not found directly
    if not rec then
        local castName = getSpellName(castSpellID)
        local recList = self.nameToRecords[castName]
        if recList and #recList > 0 then
            rec = recList[1]
            rec.variantSpellIDs[castSpellID] = true
            self.spellIDToRecord[castSpellID] = rec
            if Log then
                Log:Write("DEBUG", rec.spellID, "Registered spell variant ID: " .. tostring(castSpellID))
            end
        end
    end
    
    if not rec then
        return
    end
    
    self:_StartWatching(rec, castSpellID)
end

--------------------------------------------------------------------------------
-- Aura Change Handler
--------------------------------------------------------------------------------

function Engine:OnUnitAura()
    for _, rec in pairs(self.records) do
        -- Check if we're in a detection window waiting for an override aura to appear
        -- Skip for charged spells — they have self-buffs but aren't aura-gated
        if rec._overrideAuraID and rec.detectAuraUntil and not rec.chargeSessionActive then
            if hasPlayerAura(rec._overrideAuraID) then
                rec.gateAuraSpellID = rec._overrideAuraID
                rec.gateModeLearned = GATE_AFTER_AURA
                rec.gateMode = GATE_AFTER_AURA
                rec.gatePhase = "WAIT_OPEN"
                rec.gateOpen = false
                rec.detectAuraUntil = nil
                rec._overrideAuraID = nil
                rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1

                -- Persist learned gate mode
                if Engine.db then
                    Engine.db.learnedGates = Engine.db.learnedGates or {}
                    Engine.db.learnedGates[rec.spellID] = GATE_AFTER_AURA
                end

                if Log then
                    Log:Write("INFO", rec.spellID, "Learned aura-gated spell via UNIT_AURA (aura on " .. tostring(rec.gateAuraSpellID) .. ")")
                end
            end
        end

        if rec.gateAuraSpellID then
            local auraActive = hasPlayerAura(rec.gateAuraSpellID)

            if rec.gateMode == GATE_AFTER_AURA then
                if auraActive then
                    rec.gateOpen = false
                    rec.gateEverSeen = true  -- Mark that we've seen this aura
                    -- Aura is (still or again) active — cancel any pending
                    -- debounce timer by bumping the token.
                    rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
                    if rec.gatePhase == nil then
                        rec.gatePhase = "WAIT_OPEN"
                    elseif rec.gatePhase == "WAIT_CLOSE" then
                        rec.gatePhase = "WAIT_OPEN"
                    elseif rec.gatePhase == "WAIT_OPEN_DEBOUNCE" then
                        -- Aura reappeared during debounce (stack consumed,
                        -- e.g. Presence of Mind 2→1). Revert to WAIT_OPEN.
                        rec.gatePhase = "WAIT_OPEN"
                        if Log then
                            Log:Write("DEBUG", rec.spellID, "Aura reappeared during debounce, staying gated")
                        end
                    end
                else
                    -- Only trigger "aura disappeared" if we've seen the aura before
                    if rec.gateEverSeen and rec.gatePhase == "WAIT_OPEN" then
                        -- Aura just disappeared. Instead of immediately opening
                        -- the gate, enter a debounce phase. Multi-stack auras
                        -- (e.g. Presence of Mind) briefly vanish and reappear
                        -- when a stack is consumed.
                        rec.gatePhase = "WAIT_OPEN_DEBOUNCE"
                        rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
                        local token = rec._gateDebounceToken
                        local spellID = rec.spellID
                        if Log then
                            Log:Write("DEBUG", spellID, "Aura disappeared, debouncing gate (" .. GATE_REOPEN_DELAY .. "s)")
                        end
                        C_Timer.After(GATE_REOPEN_DELAY, function()
                            -- Stale check: token must still match AND spell
                            -- must still be in the debounce phase.
                            if rec._gateDebounceToken ~= token then return end
                            if rec.gatePhase ~= "WAIT_OPEN_DEBOUNCE" then return end
                            -- Confirm the aura is still absent (final safety check)
                            if hasPlayerAura(rec.gateAuraSpellID) then
                                rec.gatePhase = "WAIT_OPEN"
                                rec.gateOpen = false
                                if Log then
                                    Log:Write("DEBUG", spellID, "Debounce expired but aura present, staying gated")
                                end
                                return
                            end
                            -- Aura truly gone — open the gate
                            rec.gatePhase = "READY"
                            rec.gateOpen = true
                            rec._gateOpenedAt = GetTime()
                            if Log then
                                Log:Write("DEBUG", spellID, "Aura ended (confirmed after debounce), now watching cooldown")
                            end
                            -- Try to bind the real cooldown now that gate is open
                            if rec.watchToken and not rec.cdBound then
                                Engine:_TryBindCooldown(rec)
                            end
                            Engine:_ProcessPendingBinds("gate_debounce")
                            UpdateEffectiveReadiness(rec, "gate_debounce")
                        end)
                    elseif rec.gatePhase == "WAIT_OPEN_DEBOUNCE" then
                        -- Still in debounce and aura is still gone — no action
                        -- needed, the timer will handle it.
                    elseif rec.gatePhase == "READY" then
                        rec.gateOpen = true
                    else
                        rec.gateOpen = true
                    end
                end
            else
                -- Defer pulse mode: release pending pulses when aura ends.
                -- Debounce the transition to handle multi-stack aura flicker
                -- (e.g., aura briefly vanishes when a stack is consumed, then
                -- reappears with the remaining stacks).
                if auraActive then
                    -- Aura is (still or again) active — cancel any pending
                    -- debounce and keep the gate closed.
                    rec.gateOpen = false
                    rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
                    if rec._deferDebouncing then
                        rec._deferDebouncing = false
                        if Log then
                            Log:Write("DEBUG", rec.spellID, "Aura reappeared during defer-pulse debounce, staying gated")
                        end
                    end
                elseif not rec.gateOpen and not rec._deferDebouncing then
                    -- Aura just disappeared — start debounce.
                    rec._deferDebouncing = true
                    rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
                    local token = rec._gateDebounceToken
                    local spellID = rec.spellID
                    if Log then
                        Log:Write("DEBUG", spellID, "Aura disappeared (defer-pulse), debouncing (" .. GATE_REOPEN_DELAY .. "s)")
                    end
                    C_Timer.After(GATE_REOPEN_DELAY, function()
                        if rec._gateDebounceToken ~= token then return end
                        if not rec._deferDebouncing then return end
                        rec._deferDebouncing = false
                        -- Confirm the aura is still absent
                        if hasPlayerAura(rec.gateAuraSpellID) then
                            rec.gateOpen = false
                            if Log then
                                Log:Write("DEBUG", spellID, "Defer-pulse debounce expired but aura present, staying gated")
                            end
                            return
                        end
                        -- Aura truly gone — open the gate and release pending pulses
                        rec.gateOpen = true
                        local hasPending = false
                        for kind, count in pairs(rec.pendingPulses) do
                            if count and count > 0 then
                                hasPending = true
                                for i = 1, count do
                                    Engine:_EmitPulse(rec.spellID, kind, "aura ended", rec.isItem)
                                end
                                rec.pendingPulses[kind] = 0
                            end
                        end
                        if hasPending and Log then
                            Log:Write("DEBUG", spellID, "Aura ended (confirmed after debounce), releasing queued pulse")
                        end
                        UpdateEffectiveReadiness(rec, "defer_debounce")
                    end)
                end
                -- If already debouncing and aura still gone, let the timer handle it.
            end
        end
        UpdateEffectiveReadiness(rec, "aura_change")
    end
end

--------------------------------------------------------------------------------
-- Tracked Spell Management
--------------------------------------------------------------------------------

function Engine:RebuildTrackedSpells(reason)
    if not self.db or not self.db.whitelist then
        return
    end
    
    -- Determine which spells and items should be tracked
    local want = {}
    local wantItems = {}
    
    for k, enabled in pairs(self.db.whitelist) do
        if enabled then
            -- Check if this is an item (prefixed with "i:")
            if type(k) == "string" and k:match("^i:(%d+)") then
                local itemIDStr = k:match("^i:(%d+)")
                local id = safeItemID(itemIDStr)
                if id then 
                    wantItems[id] = true
                end
            else
                -- It's a spell
                local id = safeSpellID(k)
                if id then 
                    want[id] = true
                end
            end
        end
    end

    -- Consolidate entries that share the same spell name.
    -- Use the lowest ID as canonical; register others as variants.
    local nameToIDs = {}
    for spellID in pairs(want) do
        local name = getSpellName(spellID)
        if name then
            nameToIDs[name] = nameToIDs[name] or {}
            table.insert(nameToIDs[name], spellID)
        end
    end

    local canonicalIDs = {}   -- [spellID] = true for canonical IDs
    local variantOf = {}      -- [variantID] = canonicalID
    for name, ids in pairs(nameToIDs) do
        if #ids > 1 then
            table.sort(ids)
            local canonical = ids[1]
            canonicalIDs[canonical] = true
            for i = 2, #ids do
                variantOf[ids[i]] = canonical
                want[ids[i]] = nil  -- Don't create a separate record
            end
            if Log then
                local variantStr = {}
                for i = 2, #ids do variantStr[#variantStr + 1] = tostring(ids[i]) end
                Log:Write("DEBUG", canonical, "Consolidated spell name '" .. name .. "': variants " .. table.concat(variantStr, ", "))
            end
        else
            canonicalIDs[ids[1]] = true
        end
    end
    
    -- Remove spells/items no longer wanted
    for spellID, rec in pairs(self.records) do
        local stillWanted = rec.isItem and wantItems[spellID] or want[spellID]
        if not stillWanted then
            if Log then
                Log:Write("INFO", spellID, "Stopped tracking")
            end
            DestroyRecord(rec)
            self.records[spellID] = nil
        end
    end
    
    -- Add newly wanted spells
    for spellID in pairs(want) do
        if not self.records[spellID] then
            local rec = CreateRecord(spellID, false)  -- false = not an item
            
            -- Register consolidated variants
            for variantID, canonicalID in pairs(variantOf) do
                if canonicalID == spellID then
                    rec.variantSpellIDs[variantID] = true
                end
            end

            -- Check for configured aura gating
            if self.db.gatedAuras then
                local gateAura = safeSpellID(self.db.gatedAuras[spellID] or self.db.gatedAuras[tostring(spellID)])
                if gateAura then
                    rec.gateAuraSpellID = gateAura
                    rec.gateMode = GATE_DEFER_PULSE
                    rec.gatePhase = nil
                    rec.gateOpen = not hasPlayerAura(gateAura)
                end
            end
            
            self.records[spellID] = rec
            if Log then
                Log:Write("INFO", spellID, "Now tracking: " .. tostring(rec.spellName))
            end
        end
    end
    
    -- Add newly wanted items
    for itemID in pairs(wantItems) do
        if not self.records[itemID] then
            local rec = CreateRecord(itemID, true)  -- true = is an item
            
            self.records[itemID] = rec
            if Log then
                Log:Write("INFO", itemID, "Now tracking item: " .. tostring(rec.spellName))
            end
        end
    end
    
    -- Rebuild lookup maps
    wipe(self.spellIDToRecord)
    wipe(self.nameToRecords)
    
    for spellID, rec in pairs(self.records) do
        self.spellIDToRecord[spellID] = rec
        
        local name = rec.spellName
        if name then
            self.nameToRecords[name] = self.nameToRecords[name] or {}
            table.insert(self.nameToRecords[name], rec)
        end
        
        -- Register variant spell IDs (includes consolidated duplicates)
        -- Items don't have variants
        if not rec.isItem then
            for variantID in pairs(rec.variantSpellIDs) do
                self.spellIDToRecord[variantID] = rec
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function Engine:Init(db)
    self.db = db
    Log = CDPulse_Log
    self._enabled = true
    self._initTime = GetTime()
    
    if Log then
        Log:WriteAlways("INFO", nil, "Engine initialized")
    end
end

function Engine:SetPulseHandler(fn)
    self._pulseHandler = fn
end

function Engine:AddSpell(spellID)
    spellID = safeSpellID(spellID)
    if not spellID then return false, "invalid spellID" end
    if not self.db then return false, "no database" end
    
    self.db.whitelist = self.db.whitelist or {}
    self.db.whitelist[tostring(spellID)] = true
    
    if Log then
        Log:Write("INFO", spellID, "Added to whitelist")
    end
    
    self:RebuildTrackedSpells("add_spell")
    return true
end

function Engine:AddItem(itemID)
    itemID = safeItemID(itemID)
    if not itemID then return false, "invalid itemID" end
    if not self.db then return false, "no database" end
    
    self.db.whitelist = self.db.whitelist or {}
    -- Store items with "i:" prefix to distinguish from spells
    self.db.whitelist["i:" .. tostring(itemID)] = true
    
    -- Try to get item name (may fail if not cached yet)
    local itemName = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    if not itemName then
        itemName = "Item:" .. tostring(itemID)
    end
    
    if Log then
        Log:Write("INFO", itemID, "Added item to whitelist: " .. itemName)
    end
    
    self:RebuildTrackedSpells("add_item")
    return true
end

function Engine:RemoveSpell(spellID)
    spellID = safeSpellID(spellID)
    if not spellID then return false, "invalid spellID" end
    if not self.db then return false, "no database" end
    if not self.db.whitelist then return false, "no whitelist" end
    
    self.db.whitelist[tostring(spellID)] = nil
    
    if Log then
        Log:Write("INFO", spellID, "Removed from whitelist")
    end
    
    self:RebuildTrackedSpells("remove_spell")
    return true
end

function Engine:RemoveItem(itemID)
    itemID = safeItemID(itemID)
    if not itemID then return false, "invalid itemID" end
    if not self.db then return false, "no database" end
    if not self.db.whitelist then return false, "no whitelist" end
    
    self.db.whitelist["i:" .. tostring(itemID)] = nil
    
    if Log then
        Log:Write("INFO", itemID, "Removed item from whitelist")
    end
    
    self:RebuildTrackedSpells("remove_item")
    return true
end

function Engine:DumpState()
    if not Log then return end
    
    Log:Write("INFO", nil, "--- State Dump ---")
    
    local count = 0
    for spellID, rec in pairs(self.records) do
        count = count + 1
        local state = self:_GetWatchState(rec)
        local status = state
        if state == "IDLE" then
            status = "idle (waiting for cast)"
        elseif state == "BINDING" then
            status = "cast detected, binding..."
        elseif state == "WATCHING" then
            status = "watching for completion"
        end
        Log:Write("INFO", spellID, status)
    end
    
    Log:Write("INFO", nil, string.format("Total tracked: %d", count))
end

-- Handle BAG_UPDATE_COOLDOWN event for item tracking
-- This fires when any item cooldown changes, including when items are used
function Engine:OnItemCooldownUpdate()
    if not self._enabled then return end
    if not self.records then return end
    
    for _, rec in pairs(self.records) do
        if rec.isItem and rec.itemID then
            -- Check if item just went on cooldown
            local start, duration = getItemCooldownDuration(rec.itemID)
            
            -- Defensive: Log when item cooldown unavailable (may be deleted/traded)
            if start and duration then
                if duration > 0 then
                    -- Item is on cooldown
                    if not rec.watchToken then
                        -- Start watching this item
                        if Log then
                            Log:Write("INFO", rec.itemID, "Item used, starting watch (duration: " .. string.format("%.1f", duration) .. "s)")
                        end
                        self:_StartWatching(rec, rec.itemID)
                    end
                end
            elseif Log and not rec._deletionLogged then
                -- Log only once per item when unavailable
                Log:Write("TRACE", rec.itemID, "Item cooldown unavailable (may be deleted or traded)")
                rec._deletionLogged = true
            end
        end
    end
end