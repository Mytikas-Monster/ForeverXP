-- ForeverXP / Data.lua
-- Tunable constants and pure maths: XP curve, baseline pace, grades, ETA.
-- Nothing in here touches the WoW API, so it runs unchanged in the offline tests.

local _, ns = ...
local D = {}
ns.Data = D

D.MAX_LEVEL = 60

-- XP needed to go from level N to N+1. WoW: Forever kept the original curve
-- (total 4,084,700). The live UnitXPMax value is preferred for the current level;
-- this table is only used for levels the player has not reached yet.
D.XP_TO_NEXT = {
    400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600,
    8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,
    25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
    50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700,
    95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500,
    153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800,
}

-- Baseline XP/hour for an average class at an average pace, as {level, xpPerHour}
-- anchors with linear interpolation between them. Calibrated so that the curve
-- reproduces the only published per-bracket pace for Forever (about 150 hours:
-- 1-10 6h, 10-20 14h, 20-30 22h, 30-40 28h, 40-50 36h, 50-60 44h).
-- That figure is a community estimate, not a measured benchmark: retune here.
D.BASELINE_ANCHORS = {
    { 5, 4045 }, { 15, 10191 }, { 25, 14721 }, { 35, 23692 }, { 45, 32280 }, { 55, 40719 },
}

-- How much longer (or shorter) a class takes than the average, same source.
D.CLASS_PACE = {
    WARRIOR = 1.12,
    PRIEST = 1.053, DRUID = 1.053,
    PALADIN = 1.0, SHAMAN = 1.0, WARLOCK = 1.0, ROGUE = 1.0,
    MAGE = 0.92, HUNTER = 0.92,
}

-- Grade = your XP/hour divided by the baseline for your level and class.
D.GRADES = {
    { letter = "S", min = 1.75, r = 1.00, g = 0.82, b = 0.20 },
    { letter = "A", min = 1.35, r = 0.30, g = 0.90, b = 0.35 },
    { letter = "B", min = 1.10, r = 0.55, g = 0.85, b = 0.30 },
    { letter = "C", min = 0.90, r = 0.95, g = 0.90, b = 0.30 },
    { letter = "D", min = 0.70, r = 1.00, g = 0.65, b = 0.20 },
    { letter = "E", min = 0.45, r = 1.00, g = 0.40, b = 0.20 },
    { letter = "F", min = 0.00, r = 0.95, g = 0.20, b = 0.20 },
}

-- Seconds of data needed before a grade is shown.
D.MIN_GRADE_SECONDS = 300

-- Minutes per hour that efficient play still spends on each activity. Only time
-- above the allowance counts as lost.
D.ALLOWANCE = {
    travel = 12,
    taxi = 3,
    town = 4,
    idle = 1,
    downtime = 8,
}

D.TRAVEL_STREAK_SECONDS = 20    -- continuous running longer than this is "travel"
D.IDLE_AFTER_SECONDS = 45       -- standing still longer than this is "idle"
D.TRIP_MIN_SECONDS = 120        -- a walk home shorter than this is not worth a hearth
D.KILL_SECONDS_EXPECTED = 30    -- solo combat seconds per kill for a Warrior
D.KILL_SECONDS_SLOW = 40        -- above this, "slow kills" is reported
D.LOW_MOB_RATIO = 0.70          -- kill XP vs same-level mob below this = mobs too low
D.GOOD_MOB_RATIO = 0.85         -- what mobs 1-2 levels below you give
D.LOW_QUEST_FRACTION = 0.30     -- turn-in below this share of a typical quest = low value
D.LOW_QUEST_MINUTES = 4         -- assumed cost of one low-value quest
D.PROT_LEVEL = 16               -- Shield Block: where Protection starts working
D.HEARTHSTONE_ITEM = 6948
D.HEARTH_CAST_SECONDS = 15      -- cast plus loading screen, subtracted from a saved walk
D.HEARTH_TRIP_CAP_SECONDS = 900 -- one walk home never counts for more than this
D.HEARTH_UNUSED_SECONDS = 3600  -- ready this long while you travel a lot = reminder
D.STILL_GRACE_SECONDS = 3       -- a stop shorter than this does not end a run
D.DOWNTIME_WINDOW_SECONDS = 20  -- standing still this soon after a fight = recovery
D.SINGLE_PULL_RATIO = 1.25      -- kills per pull below this = single-pulling
D.SINGLE_PULL_MIN_PULLS = 8
D.SINGLE_PULL_COST = 0.15       -- share of combat time multi-pulling would save
D.MIN_KILLS_FOR_STATS = 5       -- kills needed before kill speed/XP are judged
D.REPEAT_DUNGEON_RUNS = 3       -- from this run of the same dungeon on, it is a repeat
D.REPEAT_DUNGEON_COST = 0.18    -- extra time per repeat run for the same XP
D.GRIND_QUEST_SHARE = 0.25      -- quest XP share below this = mostly grinding
D.GRIND_COST = 0.13             -- grinding vs questing, measured at level 28
D.HIGH_PARTY_LEVELS = 5         -- party member this far above you cuts your XP
D.SESSION_GAP_SECONDS = 600     -- logged out longer than this starts a new session
D.MAX_TICK_SECONDS = 120        -- longest single step (loading screens) that is counted

local floor, max, min = math.floor, math.max, math.min

function D.XPToNext(level)
    return D.XP_TO_NEXT[level] or 0
end

-- Average-class baseline XP/hour at a level.
local function baselineRaw(level)
    local a = D.BASELINE_ANCHORS
    local n = #a
    if level <= a[1][1] then
        local slope = (a[2][2] - a[1][2]) / (a[2][1] - a[1][1])
        return max(a[1][2] * 0.4, a[1][2] + slope * (level - a[1][1]))
    end
    if level >= a[n][1] then
        local slope = (a[n][2] - a[n - 1][2]) / (a[n][1] - a[n - 1][1])
        return a[n][2] + slope * (level - a[n][1])
    end
    for i = 1, n - 1 do
        local lo, hi = a[i], a[i + 1]
        if level <= hi[1] then
            return lo[2] + (hi[2] - lo[2]) * (level - lo[1]) / (hi[1] - lo[1])
        end
    end
    return a[n][2]
end

function D.ClassPace(class)
    return D.CLASS_PACE[class or ""] or 1.0
end

-- Baseline XP/hour for a class at a level (slower classes get a lower bar).
function D.Baseline(level, class)
    return baselineRaw(level) / D.ClassPace(class)
end

-- Returns the grade entry and its index for a performance ratio.
function D.Grade(ratio)
    for i, g in ipairs(D.GRADES) do
        if ratio >= g.min then
            return g, i
        end
    end
    return D.GRADES[#D.GRADES], #D.GRADES
end

function D.GradeByLetter(letter)
    for i, g in ipairs(D.GRADES) do
        if g.letter == letter then
            return g, i
        end
    end
end

-- XP still missing to reach the level cap.
function D.XPRemaining(level, xp, xpMax)
    if level >= D.MAX_LEVEL then
        return 0
    end
    local total = max(0, (xpMax or D.XPToNext(level)) - (xp or 0))
    for l = level + 1, D.MAX_LEVEL - 1 do
        total = total + D.XPToNext(l)
    end
    return total
end

-- Hours to the level cap if the player keeps performing at `ratio` times the
-- baseline. XP/hour rises roughly ninefold between level 5 and 55, so projecting
-- today's flat XP/hour forward would overestimate badly; this walks the curve.
function D.HoursToCap(level, xp, xpMax, ratio, class)
    if level >= D.MAX_LEVEL then
        return 0
    end
    if not ratio or ratio <= 0 then
        return nil
    end
    ratio = max(0.15, min(4, ratio))
    local hours = max(0, (xpMax or D.XPToNext(level)) - (xp or 0)) / (ratio * D.Baseline(level, class))
    for l = level + 1, D.MAX_LEVEL - 1 do
        hours = hours + D.XPToNext(l) / (ratio * D.Baseline(l, class))
    end
    return hours
end

-- Naive estimate: remaining XP at today's flat XP/hour.
function D.HoursToCapFlat(level, xp, xpMax, xpPerHour)
    if level >= D.MAX_LEVEL then
        return 0
    end
    if not xpPerHour or xpPerHour <= 0 then
        return nil
    end
    return D.XPRemaining(level, xp, xpMax) / xpPerHour
end

-- XP a same-level open-world mob gives (original formula).
function D.MobBaseXP(level)
    return 45 + 5 * level
end

-- Rough XP of a quest of the player's own level, used to spot low-value turn-ins.
function D.TypicalQuestXP(level)
    return max(80, 85 * level - 250)
end

-- Highest quest/mob level that is grey (trivial) for a player level.
function D.GreyLevel(level)
    if level <= 5 then
        return 0
    elseif level <= 39 then
        return level - floor(level / 10) - 5
    elseif level <= 59 then
        return level - floor(level / 5) - 1
    end
    return level - 9
end

function D.Comma(n)
    n = floor((n or 0) + 0.5)
    local s = tostring(n)
    local sign = ""
    if s:sub(1, 1) == "-" then
        sign, s = "-", s:sub(2)
    end
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then
        out = out:sub(2)
    end
    return sign .. out
end

-- "12.5 h" under 100 hours, whole hours above.
function D.FormatHours(h)
    if not h then
        return "?"
    end
    if h < 10 then
        return string.format("%.1f h", h)
    end
    return string.format("%d h", floor(h + 0.5))
end
