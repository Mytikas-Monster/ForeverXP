-- ForeverXP / Core.lua
-- Guarded access to the WoW API, event wiring, saved variables, slash commands
-- and error capture.
--
-- Forever runs on the 12.x client: there is no combat log for addons and some
-- API calls return "secret values" that raise an error when compared or used in
-- arithmetic. Every read therefore goes through ns.API, which turns a missing
-- function, an error or a secret value into nil.

local addonName, ns = ...
local D, T, F = ns.Data, ns.Tracker, ns.Factors

local Core = {}
ns.Core = Core
Core.VERSION = "2.0.0"

local floor, max, min = math.floor, math.max, math.min
local format = string.format

----------------------------------------------------------------------------
-- Output and error capture
----------------------------------------------------------------------------

local PREFIX = "|cff33ccffForeverXP|r: "

local function say(msg)
    local frame = _G.DEFAULT_CHAT_FRAME
    if frame and frame.AddMessage then
        frame:AddMessage(PREFIX .. tostring(msg))
    elseif print then
        print("ForeverXP: " .. tostring(msg))
    end
end
Core.Print = say

local announced = {}

local function onError(err)
    err = tostring(err)
    local db = _G.ForeverXPDB
    if type(db) == "table" then
        db.errors = db.errors or {}
        local list = db.errors
        local found
        for _, e in ipairs(list) do
            if e.msg == err then
                e.count = (e.count or 1) + 1
                e.last = _G.date and _G.date("%Y-%m-%d %H:%M:%S") or ""
                found = true
                break
            end
        end
        if not found then
            if #list >= 25 then
                table.remove(list, 1)
            end
            list[#list + 1] = {
                msg = err,
                count = 1,
                last = _G.date and _G.date("%Y-%m-%d %H:%M:%S") or "",
                stack = _G.debugstack and _G.debugstack(2, 6, 0) or nil,
                version = Core.VERSION,
            }
        end
    end
    if not announced[err] then
        announced[err] = true
        say("|cffff5555error|r " .. err .. " (stored; /fxp errors)")
    end
    return err
end

-- Run fn(a, b, c, d, e) and record any error instead of breaking the caller.
local function safecall(fn, a, b, c, d, e)
    return xpcall(function()
        return fn(a, b, c, d, e)
    end, onError)
end
Core.SafeCall = safecall

----------------------------------------------------------------------------
-- Guarded API
----------------------------------------------------------------------------

local A = {}
ns.API = A

local function isSecret(v)
    local test = _G.issecretvalue
    if test then
        local ok, res = pcall(test, v)
        return ok and res and true or false
    end
    return false
end
A.IsSecret = isSecret

local function clean(v)
    if isSecret(v) then
        return nil
    end
    return v
end

local function scrub(ok, a, b, c, d, e)
    if not ok then
        return nil
    end
    return clean(a), clean(b), clean(c), clean(d), clean(e)
end

-- Call a possibly missing function; errors and secret values come back as nil.
local function try(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    return scrub(pcall(fn, ...))
end
A.Try = try

local function num(v)
    if type(v) == "number" then
        return v
    end
    return nil
end

function A.Now()
    return num(try(_G.GetTime)) or 0
end

function A.Epoch()
    return num(try(_G.time)) or 0
end

function A.XP()
    return num(try(_G.UnitXP, "player")), num(try(_G.UnitXPMax, "player"))
end

function A.Level()
    return num(try(_G.UnitLevel, "player"))
end

function A.Class()
    local class = try(_G.UnitClassBase, "player")
    if type(class) ~= "string" then
        local _, file = try(_G.UnitClass, "player")
        class = file
    end
    return type(class) == "string" and class or nil
end

-- Rested XP remaining: number (0 when none), or nil when unknown.
function A.Rested()
    if type(_G.GetXPExhaustion) ~= "function" then
        return nil
    end
    local ok, v = pcall(_G.GetXPExhaustion)
    if not ok or isSecret(v) then
        return nil
    end
    return num(v) or 0
end

function A.Dead()
    return try(_G.UnitIsDeadOrGhost, "player") and true or false
end

function A.OnTaxi()
    return try(_G.UnitOnTaxi, "player") and true or false
end

function A.Resting()
    return try(_G.IsResting) and true or false
end

function A.AFK()
    return try(_G.UnitIsAFK, "player") and true or false
end

function A.CombatFlag()
    local v = try(_G.UnitAffectingCombat, "player")
    if v == nil then
        v = try(_G.InCombatLockdown)
    end
    return v and true or false
end

function A.InGroup()
    return try(_G.IsInGroup) and true or false
end

-- true plus the instance type when inside a dungeon or raid.
function A.InInstance()
    local inside, kind = try(_G.IsInInstance)
    if inside and (kind == "party" or kind == "raid") then
        return true, kind
    end
    return false, kind
end

function A.InstanceName()
    local name = try(_G.GetInstanceInfo)
    return type(name) == "string" and name or nil
end

-- Movement speed in yards per second, or nil when the client does not tell.
function A.Speed()
    return num(try(_G.GetUnitSpeed, "player"))
end

-- World position (x, y, map/instance id), or nil (always nil inside instances).
function A.Position()
    local y, x, _, map = try(_G.UnitPosition, "player")
    if num(x) and num(y) then
        return x, y, map
    end
    return nil
end

local function itemCooldown(id)
    local container = _G.C_Container
    local fn = (container and container.GetItemCooldown) or (_G.C_Item and _G.C_Item.GetItemCooldown)
        or _G.GetItemCooldown
    return try(fn, id)
end

-- true/false when the Hearthstone cooldown is known, nil otherwise.
function A.HearthReady()
    local start, duration = itemCooldown(D.HEARTHSTONE_ITEM)
    start, duration = num(start), num(duration)
    if not start or not duration then
        return nil
    end
    if start <= 0 or duration <= 1.5 then
        return true
    end
    return (start + duration - A.Now()) <= 0
end

-- true/false when known, nil otherwise.
function A.HasHearth()
    local fn = (_G.C_Item and _G.C_Item.GetItemCount) or _G.GetItemCount
    local count = num(try(fn, D.HEARTHSTONE_ITEM))
    if not count then
        return nil
    end
    return count > 0
end

function A.BindLocation()
    local v = try(_G.GetBindLocation)
    return type(v) == "string" and v ~= "" and v or nil
end

-- True when the player stands in the area the Hearthstone is bound to.
function A.AtBindLocation()
    local bind = A.BindLocation()
    if not bind then
        return false
    end
    for _, fn in ipairs({ _G.GetSubZoneText, _G.GetMinimapZoneText, _G.GetZoneText, _G.GetRealZoneText }) do
        local v = try(fn)
        if type(v) == "string" and v == bind then
            return true
        end
    end
    return false
end

-- Total free bag slots, or nil when unknown.
function A.BagsFree()
    local container = _G.C_Container
    local fn = (container and container.GetContainerNumFreeSlots) or _G.GetContainerNumFreeSlots
    if type(fn) ~= "function" then
        return nil
    end
    local total, known = 0, false
    for bag = 0, 4 do
        local free = num(try(fn, bag))
        if free then
            total = total + free
            known = true
        end
    end
    return known and total or nil
end

-- true = shield in the off hand, false = no shield, nil = unknown.
function A.HasShield()
    if type(_G.GetInventoryItemID) ~= "function" then
        return nil
    end
    local ok, id = pcall(_G.GetInventoryItemID, "player", 17)
    if not ok or isSecret(id) then
        return nil
    end
    if not id then
        return false
    end
    local fn = (_G.C_Item and _G.C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    local _, _, _, equipLoc = try(fn, id)
    if type(equipLoc) ~= "string" then
        return nil
    end
    return equipLoc == "INVTYPE_SHIELD"
end

-- Levels of the quests in the log, as a list of numbers.
function A.QuestLevels()
    local levels = {}
    local log = _G.C_QuestLog
    if log and log.GetNumQuestLogEntries and log.GetInfo then
        local count = num(try(log.GetNumQuestLogEntries)) or 0
        for i = 1, min(count, 80) do
            local info = try(log.GetInfo, i)
            if type(info) == "table" and not info.isHeader and not info.isHidden and not info.isTask then
                local level = num(clean(info.difficultyLevel))
                if not level or level <= 0 then
                    level = num(clean(info.level))
                end
                if level and level > 0 then
                    levels[#levels + 1] = level
                end
            end
        end
    elseif _G.GetNumQuestLogEntries and _G.GetQuestLogTitle then
        local count = num(try(_G.GetNumQuestLogEntries)) or 0
        for i = 1, min(count, 80) do
            local _, level, _, isHeader = try(_G.GetQuestLogTitle, i)
            if not isHeader and num(level) and level > 0 then
                levels[#levels + 1] = level
            end
        end
    end
    return levels
end

-- Highest level among party members, or nil when solo/unknown.
function A.PartyMaxLevel()
    if not A.InGroup() then
        return nil
    end
    local best
    for i = 1, 4 do
        local level = num(try(_G.UnitLevel, "party" .. i))
        if level and level > 0 and (not best or level > best) then
            best = level
        end
    end
    return best
end

----------------------------------------------------------------------------
-- Saved variables and session
----------------------------------------------------------------------------

local db, chardb
local playerLevel, playerClass = 1, nil
local prevXP, prevMax, prevLevel
local lastRested            -- rested state sampled before the latest XP gain
local started = false

local function initDB()
    _G.ForeverXPDB = type(_G.ForeverXPDB) == "table" and _G.ForeverXPDB or {}
    _G.ForeverXPCharDB = type(_G.ForeverXPCharDB) == "table" and _G.ForeverXPCharDB or {}
    db, chardb = _G.ForeverXPDB, _G.ForeverXPCharDB
    db.errors = type(db.errors) == "table" and db.errors or {}
    if db.scale == nil then
        db.scale = 1
    end
    if db.prot == nil then
        db.prot = true
    end
    db.version = Core.VERSION
    Core.db, Core.chardb = db, chardb
end

local function newSession()
    local s = T.NewSession(A.Epoch())
    chardb.session = s
    T.Attach(s)
    return s
end

local function loadSession()
    local s = chardb.session
    local now = A.Epoch()
    if type(s) ~= "table" or s.version ~= 1 or type(s.buckets) ~= "table"
        or now - (s.lastSeen or 0) > D.SESSION_GAP_SECONDS then
        s = newSession()
    else
        T.Attach(s)
    end
    s.lastSeen = now
    return s
end

function Core.Reset()
    newSession()
    local xp, xpMax = A.XP()
    prevXP, prevMax, prevLevel = xp, xpMax, A.Level() or playerLevel
    if ns.Activity then
        ns.Activity.Reset()
    end
    if ns.UI then
        ns.UI.Refresh()
    end
end

----------------------------------------------------------------------------
-- XP tracking
----------------------------------------------------------------------------

local function refreshPlayer()
    local level = A.Level()
    if level and level > 0 then
        playerLevel = max(playerLevel, level)
    end
    playerClass = playerClass or A.Class()
end

-- XP gained since the last sample, level-ups included.
function Core.XPDelta(oldXP, oldMax, oldLevel, xp, xpMax, level)
    if not (oldXP and oldMax and xp and xpMax) then
        return 0
    end
    local levels = (level or 0) - (oldLevel or 0)
    if levels <= 0 and xpMax == oldMax then
        return max(0, xp - oldXP)
    end
    -- Level-up: the rest of the old level, whole levels skipped, the new bar.
    local delta = max(0, oldMax - oldXP) + xp
    if levels > 1 and oldLevel then
        for l = oldLevel + 1, level - 1 do
            delta = delta + D.XPToNext(l)
        end
    end
    return delta
end

local function sampleXP()
    local xp, xpMax = A.XP()
    if not xp or not xpMax then
        return
    end
    local level = A.Level() or playerLevel
    -- The level can lag one event behind the XP bar: a changed bar size or a bar
    -- that went backwards means a level-up either way.
    if prevXP and prevMax and (xpMax ~= prevMax or xp < prevXP) and level <= (prevLevel or level) then
        level = (prevLevel or level) + 1
    end
    local delta = Core.XPDelta(prevXP, prevMax, prevLevel, xp, xpMax, level)
    if delta > 0 then
        local act = ns.Activity
        local now = A.Now()
        local inInstance = A.InInstance()
        T.XPGain(delta, {
            now = now,
            combat = act and act.RecentCombat(now) or false,
            rested = lastRested and true or false,
            solo = not A.InGroup(),
            instance = inInstance,
            level = prevLevel or level,
        })
        if act then
            act.Worked()
        end
    end
    prevXP, prevMax, prevLevel = xp, xpMax, level
    playerLevel = max(playerLevel, level)
    local rested = A.Rested()
    if rested ~= nil then
        lastRested = rested > 0
    end
end

----------------------------------------------------------------------------
-- Snapshot for the UI and the report
----------------------------------------------------------------------------

-- Everything the display needs, computed from the tracker.
function Core.Snapshot()
    refreshPlayer()
    local session = T.Session()
    local window, totals = T.Window(), T.Totals()
    local xp, xpMax = A.XP()
    local level = playerLevel
    local snap = {
        level = level,
        class = playerClass,
        xp = xp or 0,
        xpMax = xpMax or D.XPToNext(level),
        window = window,
        totals = totals,
        elapsed = session and session.elapsed or 0,
        rate = T.Rate(window),
        sessionRate = T.Rate(totals),
        capped = level >= D.MAX_LEVEL,
    }
    snap.baseline = D.Baseline(level, playerClass)
    snap.ratio = snap.baseline > 0 and snap.rate / snap.baseline or 0
    snap.ready = (window.secs or 0) >= D.MIN_GRADE_SECONDS
    snap.waitSeconds = max(0, D.MIN_GRADE_SECONDS - (window.secs or 0))
    if snap.ready then
        snap.grade = D.Grade(snap.ratio)
        local _, index = D.Grade(snap.ratio)
        snap.gradeIndex = index
        snap.nextGrade = index > 1 and D.GRADES[index - 1] or nil
    end
    if not snap.capped then
        if snap.ready and snap.rate > 0 then
            snap.eta = D.HoursToCap(level, snap.xp, snap.xpMax, snap.ratio, playerClass)
            snap.etaFlat = D.HoursToCapFlat(level, snap.xp, snap.xpMax, snap.rate)
        end
        snap.etaPar = D.HoursToCap(level, snap.xp, snap.xpMax, 1, playerClass)
        snap.etaA = D.HoursToCap(level, snap.xp, snap.xpMax, D.GradeByLetter("A").min, playerClass)
    end
    local ctx = ns.Activity and ns.Activity.Context() or {}
    ctx.level, ctx.class, ctx.prot = level, playerClass, db and db.prot
    snap.context = ctx
    snap.factors, snap.allFactors = F.Top(window, ctx, 5)
    return snap
end

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------

local frame = _G.CreateFrame("Frame")
Core.frame = frame
local handlers = {}
Core.registered, Core.unregistered = {}, {}

local function register(event, fn)
    handlers[event] = fn
    -- Registering an event the client does not know raises an error.
    local ok = pcall(frame.RegisterEvent, frame, event)
    if ok then
        Core.registered[#Core.registered + 1] = event
    else
        Core.unregistered[#Core.unregistered + 1] = event
    end
end

local accumulator, lastTick = 0, nil

local function tick()
    local now = A.Now()
    local dt = lastTick and (now - lastTick) or 0
    lastTick = now
    if dt <= 0 then
        return
    end
    dt = min(dt, D.MAX_TICK_SECONDS)
    local session = T.Session()
    if not session then
        return
    end
    session.lastSeen = A.Epoch()
    ns.Activity.Sample(dt, now)
    local kills = T.Resolve(now)
    if kills > 0 then
        ns.Activity.Kills(kills)
    end
    local rested = A.Rested()
    if rested ~= nil then
        lastRested = rested > 0
    end
    if ns.UI then
        ns.UI.Refresh()
    end
end

local function start()
    if started then
        return
    end
    started = true
    initDB()
    refreshPlayer()
    loadSession()
    local xp, xpMax = A.XP()
    prevXP, prevMax, prevLevel = xp, xpMax, A.Level() or playerLevel
    local rested = A.Rested()
    if rested ~= nil then
        lastRested = rested > 0
    end
    ns.Activity.Reset()
    lastTick = A.Now()
    if ns.UI then
        ns.UI.Create()
    end
    frame:SetScript("OnUpdate", function(_, elapsed)
        accumulator = accumulator + (elapsed or 0)
        if accumulator < 1 then
            return
        end
        accumulator = 0
        safecall(tick)
    end)
end

register("ADDON_LOADED", function(name)
    if name == addonName then
        initDB()
    end
end)

register("PLAYER_LOGIN", start)

register("PLAYER_ENTERING_WORLD", function()
    if not started then
        return
    end
    refreshPlayer()
    -- Returning from a loading screen: do not count a position jump as movement.
    ns.Activity.Teleported()
    ns.Activity.CheckInstance()
end)

register("PLAYER_XP_UPDATE", function(unit)
    if started and (unit == nil or unit == "player") then
        sampleXP()
    end
end)

register("PLAYER_LEVEL_UP", function(level)
    if type(level) == "number" then
        playerLevel = max(playerLevel, level)
    end
end)

register("QUEST_TURNED_IN", function(_, xpReward)
    if not started then
        return
    end
    xpReward = num(xpReward) or 0
    local low = xpReward > 0 and playerLevel < D.MAX_LEVEL
        and xpReward < D.LOW_QUEST_FRACTION * D.TypicalQuestXP(playerLevel)
    T.QuestTurnIn(A.Now(), xpReward, low)
    ns.Activity.Worked()
end)

register("PLAYER_REGEN_DISABLED", function()
    if started then
        ns.Activity.CombatStart(A.Now())
    end
end)

register("PLAYER_REGEN_ENABLED", function()
    if started then
        ns.Activity.CombatEnd(A.Now())
    end
end)

register("PLAYER_DEAD", function()
    if started then
        T.Add("deaths", 1)
        ns.Activity.Died()
    end
end)

register("PLAYER_STARTED_MOVING", function()
    if started then
        ns.Activity.MoveEvent(true)
    end
end)

register("PLAYER_STOPPED_MOVING", function()
    if started then
        ns.Activity.MoveEvent(false)
    end
end)

local townWindows = {
    MERCHANT_SHOW = "vendor", MERCHANT_CLOSED = false,
    TRAINER_SHOW = "trainer", TRAINER_CLOSED = false,
    AUCTION_HOUSE_SHOW = "ah", AUCTION_HOUSE_CLOSED = false,
    MAIL_SHOW = "mail", MAIL_CLOSED = false,
    BANKFRAME_OPENED = "bank", BANKFRAME_CLOSED = false,
}
for event, window in pairs(townWindows) do
    register(event, function()
        if started then
            ns.Activity.TownWindow(window or nil)
        end
    end)
end

register("PLAYER_LOGOUT", function()
    local session = T.Session()
    if session then
        T.Resolve(A.Now(), true)
        session.lastSeen = A.Epoch()
    end
end)

-- Event arguments can be secret values too; handlers only ever see clean ones.
frame:SetScript("OnEvent", function(_, event, a, b, c, d, e)
    local fn = handlers[event]
    if fn then
        safecall(fn, clean(a), clean(b), clean(c), clean(d), clean(e))
    end
end)

----------------------------------------------------------------------------
-- Report, self-test, slash commands
----------------------------------------------------------------------------

local function percent(part, whole)
    if not whole or whole <= 0 then
        return 0
    end
    return floor((part or 0) / whole * 100 + 0.5)
end
Core.Percent = percent

function Core.Report()
    local s = Core.Snapshot()
    if not s.ready then
        say(format("collecting data, %s to go.", F.Duration(s.waitSeconds)))
        return
    end
    say(format("grade |cffffffff%s|r - %s XP/h over the last hour (%d%% of par %s), session %s XP/h.",
        s.grade.letter, D.Comma(s.rate), floor(s.ratio * 100 + 0.5), D.Comma(s.baseline), D.Comma(s.sessionRate)))
    if s.capped then
        say("level cap reached.")
    elseif s.eta then
        say(format("about %s to level %d at this pace (%s at grade A).",
            D.FormatHours(s.eta), D.MAX_LEVEL, D.FormatHours(s.etaA)))
    end
    if #s.factors == 0 then
        say("nothing significant is slowing you down.")
    end
    for i, f in ipairs(s.factors) do
        say(format("%d. %s: %s%.0f min/h. %s", i, f.name, f.estimate and "~" or "", f.minutes, f.detail or ""))
    end
end

-- Reports which API calls and events the live client really provides. The result
-- is also stored in the saved variables so it can be read after a /reload.
function Core.SelfTest()
    local results = {}
    local function probe(name, fn, ...)
        local status
        if type(fn) ~= "function" then
            status = "missing"
        else
            local ok, v = pcall(fn, ...)
            if not ok then
                status = "error: " .. tostring(v)
            elseif isSecret(v) then
                status = "secret"
            else
                status = "ok (" .. tostring(v) .. ")"
            end
        end
        results[#results + 1] = name .. " = " .. status
    end
    local container, item, log = _G.C_Container, _G.C_Item, _G.C_QuestLog
    probe("UnitXP", _G.UnitXP, "player")
    probe("UnitXPMax", _G.UnitXPMax, "player")
    probe("UnitLevel", _G.UnitLevel, "player")
    probe("UnitClassBase", _G.UnitClassBase, "player")
    probe("GetXPExhaustion", _G.GetXPExhaustion)
    probe("UnitAffectingCombat", _G.UnitAffectingCombat, "player")
    probe("UnitIsDeadOrGhost", _G.UnitIsDeadOrGhost, "player")
    probe("UnitOnTaxi", _G.UnitOnTaxi, "player")
    probe("IsResting", _G.IsResting)
    probe("UnitIsAFK", _G.UnitIsAFK, "player")
    probe("GetUnitSpeed", _G.GetUnitSpeed, "player")
    probe("UnitPosition", _G.UnitPosition, "player")
    probe("IsInGroup", _G.IsInGroup)
    probe("IsInInstance", _G.IsInInstance)
    probe("GetInstanceInfo", _G.GetInstanceInfo)
    probe("GetBindLocation", _G.GetBindLocation)
    probe("GetSubZoneText", _G.GetSubZoneText)
    probe("C_Container.GetItemCooldown", container and container.GetItemCooldown, D.HEARTHSTONE_ITEM)
    probe("C_Item.GetItemCount", item and item.GetItemCount, D.HEARTHSTONE_ITEM)
    probe("C_Container.GetContainerNumFreeSlots", container and container.GetContainerNumFreeSlots, 0)
    probe("GetInventoryItemID", _G.GetInventoryItemID, "player", 17)
    probe("C_QuestLog.GetNumQuestLogEntries", log and log.GetNumQuestLogEntries)
    probe("C_QuestLog.GetInfo", log and log.GetInfo, 1)
    results[#results + 1] = "derived: hearthReady = " .. tostring(A.HearthReady())
        .. ", hasHearth = " .. tostring(A.HasHearth())
        .. ", atBind = " .. tostring(A.AtBindLocation())
        .. ", hasShield = " .. tostring(A.HasShield())
        .. ", bagsFree = " .. tostring(A.BagsFree())
        .. ", questLevels = " .. tostring(#A.QuestLevels())
    results[#results + 1] = "movement source = " .. tostring(ns.Activity and ns.Activity.MovementSource())
    results[#results + 1] = "events ok = " .. #Core.registered
        .. ", unknown = " .. (#Core.unregistered > 0 and table.concat(Core.unregistered, " ") or "none")
    local build = { try(_G.GetBuildInfo) }
    results[#results + 1] = "client = " .. tostring(build[1]) .. " build " .. tostring(build[2])
        .. " interface " .. tostring(build[4])
    if db then
        db.selftest = { at = _G.date and _G.date("%Y-%m-%d %H:%M:%S") or "", version = Core.VERSION, lines = results }
    end
    say("self-test (" .. Core.VERSION .. ")")
    for _, line in ipairs(results) do
        say("  " .. line)
    end
end

local function help()
    say("version " .. Core.VERSION .. " commands:")
    say("  /fxp - show or hide the window")
    say("  /fxp report - print grade, estimate and top factors to chat")
    say("  /fxp reset - start a new session")
    say("  /fxp lock - lock or unlock the window position")
    say("  /fxp scale 0.5-2 - window scale")
    say("  /fxp prot on|off - Protection Warrior specific checks")
    say("  /fxp selftest - show which game API calls work on this client")
    say("  /fxp errors - show stored Lua errors (/fxp errors clear)")
end

local function slash(msg)
    if not started then
        start()
    end
    msg = tostring(msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    local ui = ns.UI
    if cmd == "" or cmd == "toggle" then
        ui.Toggle()
    elseif cmd == "show" then
        ui.Show(true)
    elseif cmd == "hide" then
        ui.Show(false)
    elseif cmd == "reset" then
        Core.Reset()
        say("new session started.")
    elseif cmd == "report" then
        Core.Report()
    elseif cmd == "lock" or cmd == "unlock" then
        if cmd == "unlock" then
            db.locked = false
        else
            db.locked = not db.locked
        end
        ui.ApplyLock()
        say(db.locked and "window locked." or "window unlocked.")
    elseif cmd == "scale" then
        local value = tonumber(arg)
        if value and value >= 0.5 and value <= 2 then
            db.scale = value
            ui.ApplyScale()
            say(format("scale set to %.2f.", value))
        else
            say("usage: /fxp scale 0.5-2")
        end
    elseif cmd == "prot" then
        if arg == "on" or arg == "off" then
            db.prot = arg == "on"
        else
            db.prot = not db.prot
        end
        say("Protection Warrior checks " .. (db.prot and "on." or "off."))
    elseif cmd == "selftest" then
        Core.SelfTest()
    elseif cmd == "errors" then
        if arg == "clear" then
            db.errors = {}
            say("stored errors cleared.")
        elseif #db.errors == 0 then
            say("no stored errors.")
        else
            for i, e in ipairs(db.errors) do
                say(format("%d. (x%d, %s) %s", i, e.count or 1, e.last or "", e.msg or ""))
            end
        end
    else
        help()
    end
end
Core.Slash = slash

_G.SLASH_FOREVERXP1 = "/fxp"
_G.SLASH_FOREVERXP2 = "/foreverxp"
if _G.SlashCmdList then
    _G.SlashCmdList["FOREVERXP"] = function(msg)
        safecall(slash, msg)
    end
end

-- Addon compartment (minimap dropdown) entry, named in the TOC.
function _G.ForeverXP_OnAddonCompartmentClick()
    safecall(slash, "")
end
