-- CDPulse.lua

local function PrintEnabledMessage()
  DEFAULT_CHAT_FRAME:AddMessage("|cffb026ffCDPulse|r: Enabled. Use /cdp to adjust settings.")
end

-- Retail / Midnight Prepatch
-- Hybrid cooldown pulser for whitelisted spells:
--   - Arms on successful cast (UNIT_SPELLCAST_SUCCEEDED)
--   - Prefers readable cooldown from C_Spell (spell/charges)
--   - If cooldown API lags, falls back to castTime + cached/override duration
--   - Adjusts schedule if the real cooldown becomes readable later
--   - Secret-value safe numeric handling (tostring -> tonumber)
--
-- Slash commands use: /cdp

local ADDON_NAME = ...
local F = CreateFrame("Frame")

F:RegisterEvent("PLAYER_LOGIN")
F:RegisterEvent("PLAYER_ENTERING_WORLD")
F:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
F:RegisterEvent("SPELL_UPDATE_COOLDOWN")
F:RegisterEvent("SPELL_UPDATE_CHARGES")
F:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
F:RegisterEvent("UNIT_AURA")

------------------------------------------------------------
-- Defaults / DB
------------------------------------------------------------

local defaults = {
  whitelist = {},              -- [spellID] = true

  durations = {},              -- persisted per-spell duration cache in seconds
                              -- [spellID] = seconds

  size = 64,
  point = "CENTER",
  relPoint = "CENTER",
  x = 0,
  y = 100,

  pulseDuration = 0.50,
  iconOpacity = 1,

  soundName = "Default",       -- None / Default / LSM sound name
  soundChannel = "Master",
  fallbackSoundKitID = 12867,

  soundEnabled = true,
  spellSounds = {},          -- [spellID] = "None"/"Default"/LSM sound name override


  gcdThreshold = 1.6,

  debug = false,

  locked = true,
  noOverlapAlerts = false,
  sortByName = false,

  -- Pending behavior (API catch-up window; not tied to cooldown length)
  pendingTimeout = 6.0,

  -- If still unreadable after this, use cached/override duration (if available)
  fallbackGrace = 0.4,

  maxPending = 50,
}


------------------------------------------------------------
-- Active-gated spells (cooldown starts when aura ends)
------------------------------------------------------------

-- Some spells (e.g., Druid Prowl, Rogue Stealth) do not begin their cooldown until
-- the aura ends. Cooldown APIs can be protected/secret; aura presence is the
-- reliable signal for "still active, do not arm yet".
local ACTIVE_GATED = {
  [5215] = true,  -- Prowl
  [1784] = true,  -- Stealth (Rogue)
}

local function PlayerHasAuraBySpellID(spellID)
  -- Prefer AuraUtil helper if available
  if AuraUtil and AuraUtil.FindAuraBySpellID then
    return AuraUtil.FindAuraBySpellID(spellID, "player", "HELPFUL") ~= nil
  end
  -- Fallback to C_UnitAuras on newer clients
  if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    return C_UnitAuras.GetPlayerAuraBySpellID(spellID) ~= nil
  end
  return false
end

local function CopyDefaults(dst, src)
  for k, v in pairs(src) do
    if dst[k] == nil then
      if type(v) == "table" then
        dst[k] = {}
        for kk, vv in pairs(v) do dst[k][kk] = vv end
      else
        dst[k] = v
      end
    end
  end
end

local CDP_PREFIX = "|cffb026ffCDPulse|r"

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(CDP_PREFIX .. ": " .. msg)
end


------------------------------------------------------------
-- Secret-safe numbers
------------------------------------------------------------

local function PlainNumber(v)
  if v == nil then return nil end
  local ok, s = pcall(tostring, v)
  if not ok or type(s) ~= "string" then return nil end
  local n = tonumber(s)
  if type(n) ~= "number" then return nil end
  return n
end


local function NormalizeEnabled(v)
  if v == nil then return nil end

  -- Never do boolean tests or direct comparisons on potentially "secret" values.
  -- Convert to string via pcall(tostring, ...) and interpret numerically only.
  local ok, s = pcall(tostring, v)
  if not ok then return nil end

  -- NOTE: Even the returned string can be a "secret value" in 12.0+, so avoid
  -- any string comparisons (e.g. s == "true"). Only attempt tonumber safely.
  local ok2, n = pcall(tonumber, s)
  if not ok2 or type(n) ~= "number" then return nil end
  return (n > 0) and 1 or 0
end


local function Now()
  return PlainNumber(GetTime())
end

local function Clamp(v, lo, hi)
  if type(v) ~= "number" then return lo end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

------------------------------------------------------------
-- LibSharedMedia
------------------------------------------------------------

local LSM
local function InitLSM()
  if LibStub then
    LSM = LibStub("LibSharedMedia-3.0", true)
  end
end

local function RegisterBundledSounds()
  if not LSM then return end

  local base = "Interface\\AddOns\\CDPulse\\sounds\\"

  for i = 1, 11 do
    local num = string.format("%02d", i)
    local displayName = "CDPulse: SC " .. num
    local fileName = "SC" .. num .. ".mp3"

    LSM:Register("sound", displayName, base .. fileName)
  end
  LSM:Register("sound", "CDPulse: RAWN", base .. "RAWN.mp3")
end

local function PlayAlertSound(spellID)
  local db = CDPulseDB
  if db.soundEnabled == false then return end

  local channel = db.soundChannel or "Master"

  local chosen = db.soundName
  if spellID and db.spellSounds and db.spellSounds[spellID] then
    chosen = db.spellSounds[spellID]
  end

  if not chosen or chosen == "None" then return end

  if chosen == "Default" then
    if db.fallbackSoundKitID then
      PlaySound(db.fallbackSoundKitID, channel)
    end
    return
  end

  if LSM then
    local path = LSM:Fetch("sound", chosen, true)
    if path then
      PlaySoundFile(path, channel)
      return
    end
  end

  if db.fallbackSoundKitID then
    PlaySound(db.fallbackSoundKitID, channel)
  end
end

------------------------------------------------------------
-- Spell helpers
------------------------------------------------------------

local function RequestSpellData(spellID)
  if C_Spell and C_Spell.RequestLoadSpellData then
    C_Spell.RequestLoadSpellData(spellID)
  end
end

local function GetSpellNameAndIcon(spellID)
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellID)
    if info then return info.name, info.iconID end
  end
  return nil, nil
end

------------------------------------------------------------
-- Cooldown readers
------------------------------------------------------------

local function ReadSpellCooldownPlain(spellID)
  if not (C_Spell and C_Spell.GetSpellCooldown) then return nil, nil, nil end

  local ok, a, b, c = pcall(C_Spell.GetSpellCooldown, spellID)
  if not ok then return nil, nil, nil end

  if type(a) == "table" then
    local cd = a
    local start = cd.startTime
    local dur = cd.duration
    if start == nil and cd.startTimeMS ~= nil then start = cd.startTimeMS / 1000 end
    if dur == nil and cd.durationMS ~= nil then dur = cd.durationMS / 1000 end

    -- Enabled can be 0/1 or boolean depending on build/struct
    local enabled = cd.isEnabled
    if enabled == nil then enabled = cd.enabled end

    return PlainNumber(start), PlainNumber(dur), NormalizeEnabled(enabled)
  end

  -- Legacy returns: start, duration, enabled
  return PlainNumber(a), PlainNumber(b), NormalizeEnabled(c)
end


local function ReadChargeCooldownPlain(spellID)
  if not (C_Spell and C_Spell.GetSpellCharges) then return nil, nil end

  local ok, charges = pcall(C_Spell.GetSpellCharges, spellID)
  if not ok or not charges then return nil, nil end

  local cur = PlainNumber(charges.currentCharges)
  local max = PlainNumber(charges.maxCharges)
  local start = PlainNumber(charges.cooldownStartTime)
  local dur = PlainNumber(charges.cooldownDuration)

  if not cur or not max or max <= 0 then return nil, nil end
  if cur < max and start and dur and dur > 0 then
    return start, dur
  end
  return nil, nil
end

local function GetCooldownEndTimeFromAPI(spellID)
  -- Prefer charges (more correct for charge spells)
  local cStart, cDur = ReadChargeCooldownPlain(spellID)
  if cStart and cDur then
    return cStart + cDur, cStart, cDur, "charges"
  end

  local sStart, sDur, sEnabled = ReadSpellCooldownPlain(spellID)
  if sEnabled == 0 then
    -- Some spells (e.g., stealth toggles) report enabled=0 while active and only begin cooldown on aura end.
    return nil, sStart, sDur, "spell_active"
  end

  if sStart and sDur then
    return sStart + sDur, sStart, sDur, "spell"
  end

  return nil, nil, nil, nil
end


-- Dynamic GCD detection (avoid guessing a fixed threshold)
local GCD_SPELL_ID = 61304
local gcdCacheUntil = 0
local gcdCached = 1.5

local function GetCurrentGCD()
  local now = Now()
  if not now then return 1.5 end

  if now < gcdCacheUntil then
    return gcdCached
  end

  local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(GCD_SPELL_ID)
  local dur = cd and cd.duration
  dur = PlainNumber(dur)

  if type(dur) == "number" and dur > 0 then
    gcdCached = dur
  else
    -- If unreadable/secret, fall back to 1.5s (won't cause false positives with epsilon below)
    gcdCached = 1.5
  end

  gcdCacheUntil = now + 0.25
  return gcdCached
end

local function IsMeaningfulCooldown(dur)
  if type(dur) ~= "number" then return false end
  local gcd = GetCurrentGCD()
  -- Consider meaningful only if clearly greater than current GCD (+epsilon for float jitter).
  return dur > (gcd + 0.10)
end

------------------------------------------------------------
-- Pulse UI
------------------------------------------------------------

local pulseFrame, iconTex, animGroup
local scaleUp, fadeIn, scaleDown, fadeOut

-- Alert queue state (used when noOverlapAlerts is enabled)
local pulseQueue = {}
local pulsePlaying = false
local PulseSpellNow -- forward declaration for queue callback

local function CreatePulseFrame()
  pulseFrame = CreateFrame("Frame", "CDPulseFrame", UIParent)
  pulseFrame:SetFrameStrata("HIGH")
  pulseFrame:Hide()

  iconTex = pulseFrame:CreateTexture(nil, "ARTWORK")
  iconTex:SetAllPoints(pulseFrame)

  animGroup = pulseFrame:CreateAnimationGroup()

  scaleUp = animGroup:CreateAnimation("Scale")
  scaleUp:SetOrder(1)
  scaleUp:SetScale(1.25, 1.25)

  fadeIn = animGroup:CreateAnimation("Alpha")
  fadeIn:SetOrder(1)
  fadeIn:SetFromAlpha(0)
  fadeIn:SetToAlpha(1)

  scaleDown = animGroup:CreateAnimation("Scale")
  scaleDown:SetOrder(2)
  scaleDown:SetScale(0.8, 0.8)

  fadeOut = animGroup:CreateAnimation("Alpha")
  fadeOut:SetOrder(2)
  fadeOut:SetFromAlpha(1)
  fadeOut:SetToAlpha(0)

  animGroup:SetScript("OnFinished", function()
    pulseFrame:Hide()
    pulseFrame:SetAlpha(1)
    pulseFrame:SetScale(1)

    -- If "Do not overlap alerts" is enabled, play queued pulses consecutively.
    if CDPulseDB and CDPulseDB.noOverlapAlerts and pulseQueue and #pulseQueue > 0 then
      local nextSpellID = table.remove(pulseQueue, 1)
      C_Timer.After(0, function()
        PulseSpellNow(nextSpellID)
      end)
    else
      pulsePlaying = false
      if pulseQueue then
        -- If the option was disabled mid-queue, clear any backlog.
        wipe(pulseQueue)
      end
    end
  end)
end

local function ApplyVisualSettings()
  local db = CDPulseDB

  pulseFrame:ClearAllPoints()
  pulseFrame:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
  pulseFrame:SetSize(db.size, db.size)

  local a = tonumber(db.iconOpacity)
  if a == nil then a = 1 end
  a = Clamp(a, 0.05, 1.00)
  if iconTex then iconTex:SetAlpha(a) end

  local d = tonumber(db.pulseDuration) or 0.60
  d = Clamp(d, 0.10, 2.00)

  scaleUp:SetDuration(d * 0.35)
  fadeIn:SetDuration(d * 0.10)
  scaleDown:SetDuration(d * 0.65)
  fadeOut:SetDuration(d * 0.65)
end

------------------------------------------------------------
-- Anchor / Apply settings exports (used by Options UI)
------------------------------------------------------------

local anchorFrame

local function EnsureAnchor()
  if anchorFrame then return end

  anchorFrame = CreateFrame("Frame", "CDPulseAnchorFrame", UIParent, "BackdropTemplate")
  anchorFrame:SetFrameStrata("DIALOG")
  anchorFrame:SetSize(CDPulseDB.size or 64, CDPulseDB.size or 64)
  anchorFrame:SetPoint(CDPulseDB.point, UIParent, CDPulseDB.relPoint, CDPulseDB.x, CDPulseDB.y)
  anchorFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
  anchorFrame:SetBackdropColor(0, 0.6, 1, 0.15)
  anchorFrame:SetBackdropBorderColor(0, 0.6, 1, 0.9)

  local t = anchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  t:SetPoint("CENTER")
  t:SetText("CDPulse")

  anchorFrame:EnableMouse(true)
  anchorFrame:RegisterForDrag("LeftButton")
  anchorFrame:SetMovable(true)
  anchorFrame:SetClampedToScreen(true)

  anchorFrame:SetScript("OnDragStart", function(self)
    if CDPulseDB.locked then return end
    self:StartMoving()
  end)

  anchorFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint(1)
    CDPulseDB.point = point or "CENTER"
    CDPulseDB.relPoint = relPoint or "CENTER"
    CDPulseDB.x = math.floor((x or 0) + 0.5)
    CDPulseDB.y = math.floor((y or 0) + 0.5)
    ApplyVisualSettings()
  end)

  anchorFrame:Hide()
end

function CDPulse_ShowAnchor()
  EnsureAnchor()
  ApplyVisualSettings()
  anchorFrame:Show()
end

function CDPulse_HideAnchor()
  if anchorFrame then anchorFrame:Hide() end
end

function CDPulse_ApplySettings()
  -- called by Options UI
  if pulseFrame then
    ApplyVisualSettings()

  -- If overlap is allowed, clear any queued pulses.
  if not CDPulseDB.noOverlapAlerts then
    pulsePlaying = false
    if pulseQueue then wipe(pulseQueue) end
  end
  end

  EnsureAnchor()
  -- keep anchor in sync (size/pos), but only show when unlocked
  anchorFrame:SetSize(CDPulseDB.size or 64, CDPulseDB.size or 64)
  anchorFrame:ClearAllPoints()
  anchorFrame:SetPoint(CDPulseDB.point, UIParent, CDPulseDB.relPoint, CDPulseDB.x, CDPulseDB.y)

  if CDPulseDB.locked then
    CDPulse_HideAnchor()
  else
    CDPulse_ShowAnchor()
  end
end


PulseSpellNow = function(spellID)
  pulsePlaying = true

  RequestSpellData(spellID)
  local _, icon = GetSpellNameAndIcon(spellID)
  iconTex:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")

  pulseFrame:Show()
  animGroup:Stop()
  animGroup:Play()

  PlayAlertSound(spellID)
end

local function PulseSpell(spellID)
  if CDPulseDB.noOverlapAlerts then
    -- If something is already pulsing, queue this spell instead of interrupting.
    if pulsePlaying or (animGroup and animGroup:IsPlaying()) then
      table.insert(pulseQueue, spellID)
      return
    end
    PulseSpellNow(spellID)
    return
  end

  -- Default behavior: interrupt current pulse with the new one.
  PulseSpellNow(spellID)
end

function CDPulse_TestPulse(spellID)
  local sid = tonumber(spellID)
  if not sid then
    for id, enabled in pairs(CDPulseDB.whitelist or {}) do
      if enabled then sid = id break end
    end
  end
  if not sid then return false end
  PulseSpell(sid) -- local upvalue
  return true
end


-- Per-spell sound overrides (used by Options UI)
function CDPulse_SetSpellSound(spellID, soundName)
  if type(spellID) ~= "number" then return end
  CDPulseDB = CDPulseDB or {}
  CDPulseDB.spellSounds = CDPulseDB.spellSounds or {}
  if not soundName or soundName == "" or soundName == "Default" then
    CDPulseDB.spellSounds[spellID] = nil -- use global
  else
    CDPulseDB.spellSounds[spellID] = soundName
  end
end

function CDPulse_GetSpellSound(spellID)
  if not CDPulseDB or not CDPulseDB.spellSounds then return nil end
  return CDPulseDB.spellSounds[spellID]
end


function CDPulse_SetSoundEnabled(enabled)
  CDPulseDB = CDPulseDB or {}
  CDPulseDB.soundEnabled = enabled and true or false
end

function CDPulse_GetSoundEnabled()
  return (CDPulseDB and CDPulseDB.soundEnabled ~= false) and true or false
end






------------------------------------------------------------
-- Tracking (pending + timers + durations)
------------------------------------------------------------

local pending = {}          -- [spellID] = { t = castTime }
local timers = {}           -- [spellID] = timer
local armed = {}            -- [spellID] = endTime
local expected = {}         -- [spellID] = expectedEndTime when using fallback

-- forward declarations (defined later)
local EnsurePendingTicker
local EnsureArmedTicker

local function CancelTimer(spellID)
  local t = timers[spellID]
  if t and t.Cancel then pcall(function() t:Cancel() end) end
  timers[spellID] = nil
  armed[spellID] = nil
  expected[spellID] = nil
end

local function SchedulePulse(spellID, endTime, tag)
  CancelTimer(spellID)

  local now = Now()
  if not now or type(endTime) ~= "number" then return end

  local delay = endTime - now
  if delay < 0 then delay = 0 end

  armed[spellID] = endTime
  timers[spellID] = C_Timer.NewTimer(delay, function()
    PulseSpell(spellID)
    timers[spellID] = nil
    armed[spellID] = nil
    expected[spellID] = nil
  end)

  EnsureArmedTicker()

  if CDPulseDB.debug then
    local name = GetSpellNameAndIcon(spellID)
    Print(("Scheduled %d (%s) in %.3fs [%s]"):format(spellID, name or "?", delay, tag or ""))
  end
end

local function GetOverrideOrCachedDuration(spellID)
  -- persisted cache is in CDPulseDB.durations
  local d = CDPulseDB.durations and CDPulseDB.durations[spellID]
  if type(d) == "number" and d > 0 then return d end
  return nil
end

local function SetCachedDuration(spellID, dur)
  if type(dur) ~= "number" or dur <= 0 then return end
  CDPulseDB.durations = CDPulseDB.durations or {}
  CDPulseDB.durations[spellID] = dur
end

local function ArmFromAPI(spellID, reason)
  local now = Now()
  if not now then return false end

  local endTime, start, dur, source = GetCooldownEndTimeFromAPI(spellID)

  -- Some spells report enabled=0 while the effect is active (cooldown starts later).
  if source == "spell_active" then
    local info = pending[spellID]
    if info then
      info.deferActive = true
      info.activeSince = info.activeSince or now
    end
    return false, "active"
  end

  endTime = PlainNumber(endTime)
  start = PlainNumber(start)
  dur = PlainNumber(dur)

  if not endTime or not start or not dur then
    return false
  end

  if not IsMeaningfulCooldown(dur) then
    return false
  end

  -- Persist duration for future fallback (per-spell)
  SetCachedDuration(spellID, dur)

  if endTime <= now then
    return false
  end

  SchedulePulse(spellID, endTime, (reason or "?") .. ":" .. tostring(source))
  pending[spellID] = nil
  return true
end


local function ArmFromDurationFallback(spellID, castTime, reason)
  local dur = GetOverrideOrCachedDuration(spellID)
  if type(dur) ~= "number" then return false end

  local endTime = castTime + dur
  expected[spellID] = endTime

  SchedulePulse(spellID, endTime, (reason or "?") .. ":dur")
  pending[spellID] = nil
  return true
end

local function PendingCount()
  local c = 0
  for _ in pairs(pending) do c = c + 1 end
  return c
end

local function ProcessPending(reason)
  local now = Now()
  if not now then return end

  for spellID, info in pairs(pending) do
    local castT = info.t or now
    local age = now - castT

    -- If this spell is active-gated and its aura is still up, do not arm/fallback/timeout.
    if info.waitAura and PlayerHasAuraBySpellID(spellID) then
      local maxActive = 3600 -- safety cap (1 hour)
      local activeSince = info.activeSince or castT
      local activeAge = now - activeSince
      if activeAge > maxActive then
        if CDPulseDB.debug then
          Print(("Pending active(aura) timeout: %d (age %.2fs)"):format(spellID, activeAge))
        end
        pending[spellID] = nil
      end
      -- continue
    else
      info.waitAura = nil

    -- Prefer arming from API if/when readable
    local armed, state = ArmFromAPI(spellID, reason)
    if armed then
      -- armed
    elseif state == "active" then
      -- Spell is active; cooldown has not begun yet. Do not fallback-arm and do not apply the normal timeout.
      local maxActive = 3600 -- safety cap (1 hour) so nothing lives forever if something goes wrong
      local activeSince = info.activeSince or castT
      local activeAge = now - activeSince
      if activeAge > maxActive then
        if CDPulseDB.debug then
          Print(("Pending active timeout: %d (age %.2fs)"):format(spellID, activeAge))
        end
        pending[spellID] = nil
      end
    else
      -- After grace period, arm from duration fallback if we have one
      local grace = tonumber(CDPulseDB.fallbackGrace) or 0.4
      if age >= grace then
        ArmFromDurationFallback(spellID, castT, reason)
      end

      -- Pending timeout: only for "never readable and no duration known"
      local timeout = tonumber(CDPulseDB.pendingTimeout) or 6.0
      if age > timeout then
        if CDPulseDB.debug then
          Print(("Pending timeout: %d (age %.2fs)"):format(spellID, age))
        end
        pending[spellID] = nil
      end
    end
  end
end
end


local function MarkPending(spellID)
  local now = Now()
  if not now then return end

  -- cap pending size
  if PendingCount() >= (tonumber(CDPulseDB.maxPending) or 50) then
    for sid in pairs(pending) do pending[sid] = nil break end
  end

  pending[spellID] = { t = now }

  if CDPulseDB.debug then
    local name = GetSpellNameAndIcon(spellID)
    Print(("Cast -> pending: %d (%s)"):format(spellID, name or "?"))
  end

  EnsurePendingTicker()

  -- try immediately
  ArmFromAPI(spellID, "cast")
end

local function AdjustArmedFromAPI(reason)
  -- If we scheduled from duration fallback and later API becomes readable, adjust schedule.
  for spellID, expEnd in pairs(expected) do
    local endTime, _, dur, source = GetCooldownEndTimeFromAPI(spellID)
    endTime = PlainNumber(endTime)
    dur = PlainNumber(dur)

    if endTime and dur and IsMeaningfulCooldown(dur) then
      SetCachedDuration(spellID, dur)

      if math.abs(endTime - expEnd) > 0.2 then
        if CDPulseDB.debug then
          Print(("Adjust %d: realEnd=%.3f was=%.3f src=%s (%s)"):format(
            spellID, endTime, expEnd, tostring(source), tostring(reason)
          ))
        end
        SchedulePulse(spellID, endTime, "adjust:" .. tostring(source))
        expected[spellID] = endTime
      end
    end
  end
end


local function AdjustArmedTimersFromAPI(reason)
  -- For spells already armed from API (not just fallback/expected), reschedule if cooldown end changes.
  -- This covers effects like Outlaw Rogue Restless Blades that reduce cooldowns after the cast.
  local now = Now()
  if not now then return end

  for spellID, oldEnd in pairs(armed) do
    if type(spellID) == "number" and type(oldEnd) == "number" then
      local endTime, _, dur, source = GetCooldownEndTimeFromAPI(spellID)
      endTime = PlainNumber(endTime)
      dur = PlainNumber(dur)

      -- If spell is already ready (or no meaningful cooldown), fire immediately (or clear armed state).
      if endTime and dur and IsMeaningfulCooldown(dur) then
        if endTime <= now then
          -- Ready now; pulse immediately.
          SchedulePulse(spellID, now, "rearm-ready:" .. tostring(source))
        elseif math.abs(endTime - oldEnd) > 0.2 then
          if CDPulseDB.debug then
            Print(("Re-arm %d: realEnd=%.3f was=%.3f src=%s (%s)"):format(
              spellID, endTime, oldEnd, tostring(source), tostring(reason)
            ))
          end
          SchedulePulse(spellID, endTime, "rearm:" .. tostring(source))
        end
      end
    end
  end
end


-- Tickers to make tracking resilient even when cooldown update events are delayed/missed.
do
  local pendingTicker
  local armedTicker

  EnsurePendingTicker = function()
    if pendingTicker then return end
    pendingTicker = C_Timer.NewTicker(0.10, function()
      if next(pending) then
        ProcessPending("ticker")
      else
        pendingTicker:Cancel()
        pendingTicker = nil
      end
    end)
  end

  EnsureArmedTicker = function()
    if armedTicker then return end
    armedTicker = C_Timer.NewTicker(0.33, function()
      if next(armed) or next(expected) then
        AdjustArmedTimersFromAPI("armedTicker")
        AdjustArmedFromAPI("armedTicker")
      else
        armedTicker:Cancel()
        armedTicker = nil
      end
    end)
  end
end



------------------------------------------------------------
-- Slash commands (/cdp)
------------------------------------------------------------

local pendingOpenOptions = false

local function RequestOpenOptionsAfterCombat()
  if pendingOpenOptions then return end
  pendingOpenOptions = true
  -- Settings UI is protected in combat; defer until PLAYER_REGEN_ENABLED.
  Print("Settings will open when combat ends.")
  F:RegisterEvent("PLAYER_REGEN_ENABLED")
end

SLASH_CDP1 = "/cdp"
SlashCmdList["CDP"] = function(msg)
  msg = (msg or ""):match("^%s*(.-)%s*$")
  local cmd, arg = msg:match("^(%S+)%s*(.*)$")
  cmd = (cmd or ""):lower()

  -- Do not allow any /cdp commands in combat; defer opening settings until combat ends.
  if InCombatLockdown and InCombatLockdown() then
    RequestOpenOptionsAfterCombat()
    return
  end


  if cmd == "" then
    if CDPulse_OpenOptions then
      CDPulse_OpenOptions()
      return
    end
    -- fallback
    if Settings and Settings.OpenToCategory then
      pcall(Settings.OpenToCategory, "CDPulse")
      return
    end
    return
  end

  if cmd == "help" then
    -- fall through to help print below
  end

  if cmd == "add" then
    local id = tonumber(arg)
    if not id then Print("Usage: /cdp add <spellID>"); return end
    CDPulseDB.whitelist[id] = true
    RequestSpellData(id)
    Print("Added " .. id)
    return
  end

  if cmd == "remove" or cmd == "del" then
    local id = tonumber(arg)
    if not id then Print("Usage: /cdp remove <spellID>"); return end
    CDPulseDB.whitelist[id] = nil
    pending[id] = nil
    CancelTimer(id)
    Print("Removed " .. id)
    return
  end

  if cmd == "list" then
    Print("Whitelist:")
    local any = false
    for id, enabled in pairs(CDPulseDB.whitelist) do
      if enabled then
        any = true
        local name = GetSpellNameAndIcon(id)
        local p = pending[id] and " [pending]" or ""
        local a = armed[id] and " [armed]" or ""
        local d = GetOverrideOrCachedDuration(id)
        local ds = d and (" [dur " .. string.format("%.1f", d) .. "s]") or " [dur ?]"
        Print((" - %d (%s)%s%s%s"):format(id, name or "?", p, a, ds))
      end
    end
    if not any then Print(" (empty)") end
    return
  end

  if cmd == "debug" then
    CDPulseDB.debug = not CDPulseDB.debug
    Print("debug = " .. tostring(CDPulseDB.debug))
    return
  end

  if cmd == "setdur" then
    local sid, sec = arg:match("^(%d+)%s+(%S+)$")
    sid = tonumber(sid)
    sec = tonumber(sec)
    if not sid or not sec or sec <= 0 then
      Print("Usage: /cdp setdur <spellID> <seconds>")
      return
    end
    CDPulseDB.durations = CDPulseDB.durations or {}
    CDPulseDB.durations[sid] = sec
    Print(("Duration set: %d = %.2fs"):format(sid, sec))
    return
  end

  if cmd == "cleardur" then
    local sid = tonumber(arg)
    if not sid then
      Print("Usage: /cdp cleardur <spellID>")
      return
    end
    if CDPulseDB.durations then
      CDPulseDB.durations[sid] = nil
    end
    Print("Duration cleared: " .. sid)
    return
  end

  if cmd == "test" then
    local sid = tonumber(arg)
    if sid then
      PulseSpell(sid)
      return
    end
    for id, enabled in pairs(CDPulseDB.whitelist) do
      if enabled then PulseSpell(id); return end
    end
    Print("Whitelist empty.")
    return
  end

  Print("Commands:")
  Print("/cdp  (open options)")
  Print("/cdp help")
  Print("/cdp add <spellID>")
  Print("/cdp remove <spellID>")
  Print("/cdp list")
  Print("/cdp setdur <spellID> <seconds>")
  Print("/cdp cleardur <spellID>")
  Print("/cdp test [spellID]")
  Print("/cdp debug")
end

------------------------------------------------------------
-- Events
------------------------------------------------------------

F:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    CDPulseDB = CDPulseDB or {}
    CopyDefaults(CDPulseDB, defaults)

    -- Ensure tables exist
    CDPulseDB.whitelist = CDPulseDB.whitelist or {}
    CDPulseDB.durations = CDPulseDB.durations or {}
    CDPulseDB.spellSounds = CDPulseDB.spellSounds or {}

    InitLSM()
    RegisterBundledSounds()
    CreatePulseFrame()
    ApplyVisualSettings()

    Print("Loaded. Use /cdp")

    return
  end

  if event == "PLAYER_ENTERING_WORLD" then
    -- clear pending only (keep persisted durations)
    pending = {}
    return
  end

  if event == "PLAYER_REGEN_ENABLED" then
    if pendingOpenOptions then
      pendingOpenOptions = false
      F:UnregisterEvent("PLAYER_REGEN_ENABLED")
      -- Sanity: only open if we're truly out of combat
      if not (InCombatLockdown and InCombatLockdown()) then
        if CDPulse_OpenOptions then
          pcall(CDPulse_OpenOptions)
        end
      end
    end
    return
  end

  if event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, _, spellID = ...
    if unit ~= "player" then return end
    if not spellID then return end
    if CDPulseDB.whitelist[spellID] ~= true then return end

    RequestSpellData(spellID)

    -- Active-gated spells (Prowl/Stealth): cooldown starts when aura ends.
    if ACTIVE_GATED[spellID] and PlayerHasAuraBySpellID(spellID) then
      MarkPending(spellID)
      if pending and pending[spellID] then
        pending[spellID].waitAura = true
        pending[spellID].activeSince = pending[spellID].activeSince or Now() or GetTime()
      end
      return
    end

    MarkPending(spellID)
    return
  end

  
  if event == "UNIT_AURA" then
    local unit = ...
    if unit ~= "player" then return end

    -- When an active-gated aura ends, its cooldown begins; re-resolve pending.
    for spellID in pairs(ACTIVE_GATED) do
      local info = pending and pending[spellID]
      if info and info.waitAura then
        if not PlayerHasAuraBySpellID(spellID) then
          info.waitAura = nil
          -- Kick resolution immediately; pending ticker will handle the rest.
          MarkPending(spellID)
        end
      end
    end
    return
  end

if event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" or event == "ACTIONBAR_UPDATE_COOLDOWN" then
    if next(pending) then
      ProcessPending(event)
    end
    if next(expected) then
      AdjustArmedFromAPI(event)
    end
    if next(armed) then
      AdjustArmedTimersFromAPI(event)
    end
    return
  end
end)