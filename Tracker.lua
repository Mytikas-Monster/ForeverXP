-- ForeverXP / Tracker.lua
-- Session accounting: a rolling window of one-minute buckets holding seconds per
-- activity, XP by source and event counters. Pure logic, no WoW API, so the
-- session table can live directly in SavedVariables and survive a /reload.

local _, ns = ...
local T = {}
ns.Tracker = T

T.BUCKET_SECONDS = 60
T.WINDOW_BUCKETS = 60
T.QUEST_MATCH_SECONDS = 1.5   -- XP gain this close to a turn-in is quest XP
T.RESOLVE_DELAY = 1.0         -- wait this long so a late turn-in event can still match

local floor = math.floor

local session            -- the attached session table
local pending = {}       -- XP gains waiting to be classified
local questEvents = {}   -- recent turn-ins, for matching

function T.NewSession(epoch)
    return {
        version = 1,
        startedAt = epoch or 0,
        lastSeen = epoch or 0,
        elapsed = 0,        -- tracked (logged-in) seconds
        buckets = {},       -- [minuteIndex] = { field = number }
        totals = {},        -- whole-session sums of the same fields
        instanceRuns = {},  -- [instanceName] = { count, lastAt }
    }
end

function T.Attach(s)
    session = s
    s.buckets = s.buckets or {}
    s.totals = s.totals or {}
    s.instanceRuns = s.instanceRuns or {}
    s.elapsed = s.elapsed or 0
    pending = {}
    questEvents = {}
    return s
end

function T.Session()
    return session
end

local function currentIndex()
    return floor(session.elapsed / T.BUCKET_SECONDS)
end

local function currentBucket()
    local idx = currentIndex()
    local b = session.buckets[idx]
    if not b then
        b = {}
        session.buckets[idx] = b
        local oldest = idx - T.WINDOW_BUCKETS + 1
        for k in pairs(session.buckets) do
            if k < oldest then
                session.buckets[k] = nil
            end
        end
    end
    return b
end

-- Add to a field in the current bucket and in the session totals.
function T.Add(field, amount)
    if not session or not amount or amount == 0 then
        return
    end
    local b = currentBucket()
    b[field] = (b[field] or 0) + amount
    session.totals[field] = (session.totals[field] or 0) + amount
end

-- Advance the clock by dt seconds spent in `state` ("combat", "travel", ...).
function T.Tick(dt, state)
    if not session or dt <= 0 then
        return
    end
    T.Add("secs", dt)
    if state then
        T.Add("t_" .. state, dt)
    end
    session.elapsed = session.elapsed + dt
end

-- Move seconds from one activity to another (used when a short run turns out
-- to be the start of a long one).
function T.Reclassify(fromState, toState, seconds)
    if seconds and seconds > 0 then
        T.Add("t_" .. fromState, -seconds)
        T.Add("t_" .. toState, seconds)
    end
end

-- Sums of every field over the rolling window.
function T.Window()
    local w = {}
    if not session then
        return w
    end
    local oldest = currentIndex() - T.WINDOW_BUCKETS + 1
    for idx, b in pairs(session.buckets) do
        if idx >= oldest then
            for field, v in pairs(b) do
                w[field] = (w[field] or 0) + v
            end
        end
    end
    return w
end

function T.Totals()
    return session and session.totals or {}
end

-- XP per hour over a set of sums (window or totals).
function T.Rate(sums)
    local secs = sums.secs or 0
    if secs < 1 then
        return 0
    end
    return (sums.xp or 0) * 3600 / secs
end

-- Record an XP gain. ctx: now, combat (in or just out of combat), rested, solo,
-- instance, level. The total is counted at once; the source is decided later by
-- Resolve so that a turn-in event arriving just after the XP still matches.
function T.XPGain(amount, ctx)
    if not session or not amount or amount <= 0 then
        return
    end
    T.Add("xp", amount)
    pending[#pending + 1] = { amount = amount, ctx = ctx or {} }
end

-- Record a quest turn-in.
function T.QuestTurnIn(now, xpReward, lowValue)
    if not session then
        return
    end
    T.Add("questTurnins", 1)
    if lowValue then
        T.Add("lowQuests", 1)
    end
    if xpReward and xpReward > 0 then
        questEvents[#questEvents + 1] = { now = now, xp = xpReward }
    end
end

-- Index of an unused turn-in close in time to the gain. With exact set, only a
-- turn-in whose reward equals the gain; otherwise the nearest one.
local function matchQuest(gain, exact)
    local best, bestDelta
    for i, q in ipairs(questEvents) do
        local delta = math.abs((gain.ctx.now or 0) - q.now)
        if not q.used and delta <= T.QUEST_MATCH_SECONDS and (not exact or q.xp == gain.amount) then
            if not bestDelta or delta < bestDelta then
                best, bestDelta = i, delta
            end
        end
    end
    return best
end

-- Classify pending gains that are old enough (or all of them when force is set).
-- Returns the number of kills and quest gains resolved.
function T.Resolve(now, force)
    local kills, quests = 0, 0
    if not session then
        return kills, quests
    end
    local keep, due = {}, {}
    for _, gain in ipairs(pending) do
        if not force and now - (gain.ctx.now or now) < T.RESOLVE_DELAY then
            keep[#keep + 1] = gain
        else
            due[#due + 1] = gain
        end
    end
    -- Exact reward matches first, so a kill a moment before a turn-in cannot
    -- take the turn-in away from the gain that really belongs to it.
    for pass = 1, 2 do
        for _, gain in ipairs(due) do
            if not gain.quest then
                local qi = matchQuest(gain, pass == 1)
                if qi then
                    questEvents[qi].used = true
                    gain.quest = true
                end
            end
        end
    end
    for _, gain in ipairs(due) do
        local ctx = gain.ctx
        if gain.quest then
            T.Add("xpQuest", gain.amount)
            quests = quests + 1
        elseif ctx.combat then
            T.Add("xpKill", gain.amount)
            T.Add("kills", 1)
            kills = kills + 1
            if not ctx.rested then
                T.Add("xpKillUnrested", gain.amount)
            end
            if ctx.solo and not ctx.instance then
                T.Add("soloKills", 1)
                T.Add("soloKillBase", ctx.rested and gain.amount / 2 or gain.amount)
                T.Add("soloKillExpected", ns.Data.MobBaseXP(ctx.level or 1))
            end
        else
            T.Add("xpOther", gain.amount)
        end
    end
    pending = keep
    -- Drop turn-ins that can no longer match anything.
    local live = {}
    for _, q in ipairs(questEvents) do
        if now - q.now <= 10 then
            live[#live + 1] = q
        end
    end
    questEvents = live
    return kills, quests
end

-- Count a dungeon entry. sameRun marks a re-entry that continues the current run
-- (corpse run back in after a wipe, /reload inside). Returns the run count for
-- that instance this session.
function T.InstanceEntered(name, now, sameRun)
    if not session or not name or name == "" then
        return 0
    end
    local run = session.instanceRuns[name]
    if not run then
        run = { count = 0, lastAt = now }
        session.instanceRuns[name] = run
    end
    if not (sameRun and run.count > 0) then
        run.count = run.count + 1
    end
    run.lastAt = now
    session.lastInstance = name
    return run.count
end

function T.InstanceRuns(name)
    name = name or (session and session.lastInstance)
    local run = session and name and session.instanceRuns[name]
    return run and run.count or 0, name
end
