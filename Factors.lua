-- ForeverXP / Factors.lua
-- Turns the tracker's sums into slowdown factors. Every factor is expressed in the
-- same unit, estimated minutes lost per hour, so they can be ranked against each
-- other. Pure logic, no WoW API.
--
-- Factors marked `estimate` are rules of thumb from the leveling meta rather than
-- directly measured time; the UI shows them with a "~".

local _, ns = ...
local F = {}
ns.Factors = F

local D = ns.Data
local floor, max, min = math.floor, math.max, math.min
local format = string.format

F.MIN_MINUTES = 0.5   -- anything smaller is not worth a row

local function round(x)
    return floor(x + 0.5)
end

-- Seconds as "4m 10s" / "55s".
local function dur(seconds)
    seconds = max(0, round(seconds or 0))
    if seconds >= 3600 then
        return format("%dh %02dm", floor(seconds / 3600), floor(seconds % 3600 / 60))
    elseif seconds >= 60 then
        return format("%dm %02ds", floor(seconds / 60), seconds % 60)
    end
    return format("%ds", seconds)
end
F.Duration = dur

local function plural(n, one, many)
    return n == 1 and one or many
end

-- Each rule receives (s, c, perHour) where s = sums over the window, c = context,
-- perHour(seconds) = minutes per hour. It returns minutes lost per hour, a detail
-- line and optionally true when the number is an estimate.
local rules = {}

-- `generic` is the advice shown to classes other than Warrior, where the main
-- advice names Warrior abilities.
local function rule(key, name, advice, fn, generic)
    rules[#rules + 1] = { key = key, name = name, advice = advice, fn = fn, generic = generic }
end

rule("travel", "Travel on foot / mount",
    "Finish every quest in an area before you leave it, hand quests in in batches, and plan a loop instead of out-and-back trips. There is no mount before 40, so each detour costs double.",
    function(s, c, perHour)
        local m = perHour(s.t_travel or 0)
        return m - D.ALLOWANCE.travel,
            format("%d min of every hour spent running (efficient play: about %d).", round(m), D.ALLOWANCE.travel)
    end)

rule("taxi", "Long flight paths",
    "Clear a zone before you fly out and combine trainer, bank and auction trips with a zone change you need anyway.",
    function(s, c, perHour)
        local m = perHour(s.t_taxi or 0)
        return m - D.ALLOWANCE.taxi,
            format("%d min of every hour on a flight path (efficient play: about %d).", round(m), D.ALLOWANCE.taxi)
    end)

rule("hearth", "Hearthstone not used",
    "Hearthstone is on a 1 hour cooldown: spend it on the longest walk back of each hour, and re-bind it at the inn of the hub you are questing from.",
    function(s, c, perHour)
        if c.hasHearth == false then
            return 0
        end
        local missed = s.hearthMissed or 0
        if missed > 0 then
            return perHour(s.hearthMissedSecs or 0),
                format("Walked back to your inn %d %s with Hearthstone off cooldown (%s on foot).",
                    missed, plural(missed, "time", "times"), dur(s.hearthMissedSecs or 0))
        end
        local ready = c.hearthReadySecs or 0
        local travelExcess = perHour(s.t_travel or 0) - D.ALLOWANCE.travel
        if ready >= D.HEARTH_UNUSED_SECONDS and travelExcess > 0 then
            return min(3, travelExcess * 0.25),
                format("Hearthstone has been ready for %s while you travel more than average.", dur(ready)), true
        end
        return 0
    end)

rule("town", "Too long in town",
    "Sell, repair and train in one pass. Train every second level, and leave the auction house and mailbox for the end of the session.",
    function(s, c, perHour)
        local m = perHour(s.t_town or 0)
        local parts = {}
        local function part(field, label)
            local v = s[field] or 0
            if v >= 30 then
                parts[#parts + 1] = label .. " " .. dur(v)
            end
        end
        part("town_vendor", "vendor")
        part("town_trainer", "trainer")
        part("town_ah", "auction house")
        part("town_mail", "mail")
        part("town_bank", "bank")
        local detail = format("%d min of every hour in towns and inns (efficient play: about %d).",
            round(m), D.ALLOWANCE.town)
        if #parts > 0 then
            detail = detail .. " Of that: " .. table.concat(parts, ", ") .. "."
        end
        return m - D.ALLOWANCE.town, detail
    end)

rule("idle", "Idle / AFK",
    "Standing still outside town is the cheapest time to win back. Log out at an inn for breaks so the time builds rested XP instead.",
    function(s, c, perHour)
        local m = perHour(s.t_idle or 0)
        return m - D.ALLOWANCE.idle,
            format("%d min of every hour standing still out of combat.", round(m))
    end)

rule("downtime", "Recovery between pulls",
    "Use Victory Rush after every kill (heals 10% from level 20), bandage instead of eating, press Bloodrage as you charge rather than waiting for rage, and keep Shield Block up so you lose less health. Start the next pull at about 60% health.",
    function(s, c, perHour)
        local m = perHour(s.t_downtime or 0)
        return m - D.ALLOWANCE.downtime,
            format("%d min of every hour standing still right after a fight (efficient play: about %d).",
                round(m), D.ALLOWANCE.downtime)
    end,
    "Bandage instead of eating where you can, start the next pull before you are full, and fight mobs 1-2 levels below you so each fight costs less health and mana.")

rule("deaths", "Deaths and corpse runs",
    "Pull 2-3 mobs, not 4 or more, and fight mobs 1-2 levels below you. Keep Retaliation and Shield Wall for pulls that go wrong, and Hamstring and run early instead of dying.",
    function(s, c, perHour)
        local deaths = s.deaths or 0
        local dead = s.t_dead or 0
        if deaths == 0 and dead < 10 then
            return 0
        end
        return perHour(dead),
            format("%d %s, %s dead or running back.", deaths, plural(deaths, "death", "deaths"), dur(dead))
    end,
    "Pull fewer mobs at once, fight mobs 1-2 levels below you, and leave early when a pull goes wrong: a corpse run costs more than a retreat.")

rule("slowkills", "Slow kills",
    "Protection damage comes from your shield and attack power: keep the shield and one-hander current, open with Charge, then Shield Block into Revenge on every block, Thunder Clap on 2+ mobs. Mobs above your level are much slower in Forever.",
    function(s, c, perHour)
        local kills = s.soloKills or 0
        local combat = s.combatSolo or 0
        if kills < D.MIN_KILLS_FOR_STATS then
            return 0
        end
        local perKill = combat / kills
        if perKill <= D.KILL_SECONDS_SLOW then
            return 0
        end
        return perHour((perKill - D.KILL_SECONDS_EXPECTED) * kills),
            format("%d s of combat per kill over %d solo kills (expected: about %d s).",
                round(perKill), kills, D.KILL_SECONDS_EXPECTED)
    end,
    "Keep your weapon current, train new ranks, and fight mobs 1-2 levels below you: mobs above your level are much slower in Forever.")

rule("lowmobs", "Mobs too low level",
    "The best kill XP per minute is on mobs 1-2 levels below you. Green-to-grey mobs die fast but pay much less: move on to the next area.",
    function(s, c, perHour)
        local kills = s.soloKills or 0
        local expected = s.soloKillExpected or 0
        if kills < D.MIN_KILLS_FOR_STATS or expected <= 0 then
            return 0
        end
        local ratio = (s.soloKillBase or 0) / expected
        if ratio >= D.LOW_MOB_RATIO then
            return 0
        end
        local share = (D.GOOD_MOB_RATIO - ratio) / D.GOOD_MOB_RATIO
        return perHour(s.combatSolo or 0) * share,
            format("Your solo kills give %d%% of the XP of a same-level mob (mobs 1-2 levels below you give about %d%%).",
                round(ratio * 100), round(D.GOOD_MOB_RATIO * 100)), true
    end)

rule("singlepull", "Pulling one mob at a time",
    "From 16 on Protection is built for 2-3 mobs at once: more blocks mean more Revenge and more rage, and Thunder Clap hits them all. Charge one, gather a second and third, then stop at 3.",
    function(s, c, perHour)
        if c.class ~= "WARRIOR" or not c.prot or (c.level or 1) < D.PROT_LEVEL then
            return 0
        end
        local pulls = s.pulls or 0
        local kills = s.pullKills or 0
        if pulls < D.SINGLE_PULL_MIN_PULLS then
            return 0
        end
        local ratio = kills / pulls
        if ratio >= D.SINGLE_PULL_RATIO then
            return 0
        end
        return perHour(s.combatSolo or 0) * D.SINGLE_PULL_COST,
            format("%.1f kills per pull over %d pulls (aim for 2-3).", ratio, pulls), true
    end)

rule("quests", "Low-value quests",
    "Drop grey quests, skip long errands that pay little, and leave red quests until you are within 2-3 levels. Quests at or just below your level pay the most per minute.",
    function(s, c, perHour)
        local low = s.lowQuests or 0
        local grey = c.greyQuests or 0
        local red = c.redQuests or 0
        local minutes = perHour(low * D.LOW_QUEST_MINUTES * 60) + min(3, grey * 0.75) + min(2, red * 0.5)
        if minutes <= 0 then
            return 0
        end
        local parts = {}
        if low > 0 then
            parts[#parts + 1] = format("%d turn-%s paid under %d%% of a normal quest for your level",
                low, plural(low, "in", "ins"), round(D.LOW_QUEST_FRACTION * 100))
        end
        if grey > 0 then
            parts[#parts + 1] = format("%d grey %s in your log", grey, plural(grey, "quest", "quests"))
        end
        if red > 0 then
            parts[#parts + 1] = format("%d red %s in your log", red, plural(red, "quest", "quests"))
        end
        local detail = table.concat(parts, "; ") .. "."
        return minutes, detail:sub(1, 1):upper() .. detail:sub(2), true
    end)

rule("dungeon", "Repeating the same dungeon",
    "The fastest route is questing plus one run of each dungeon with all its quests picked up first. A second run only pays with a fast group; after that go back to questing.",
    function(s, c, perHour)
        local runs = c.instanceRuns or 0
        local inside = s.instanceSecs or 0
        if runs < D.REPEAT_DUNGEON_RUNS or inside < 300 then
            return 0
        end
        local share = min(0.5, D.REPEAT_DUNGEON_COST * (runs - D.REPEAT_DUNGEON_RUNS + 1))
        return perHour(inside) * share,
            format("Run %d of %s this session.", runs, c.instanceName or "this dungeon"), true
    end)

rule("grinding", "Mostly grinding, few quests",
    "Questing is the base of the fastest route in Forever: in the level 28 test grinding gave about 13% less XP per hour than questing. Kill what your quests need and what is on the way, then move on.",
    function(s, c, perHour)
        local xp = s.xp or 0
        local secs = s.secs or 0
        if xp <= 0 or secs < 1200 or (s.kills or 0) < 20 then
            return 0
        end
        if (s.instanceSecs or 0) > secs * 0.5 then
            return 0
        end
        local share = (s.xpQuest or 0) / xp
        if share >= D.GRIND_QUEST_SHARE then
            return 0
        end
        return 60 * D.GRIND_COST * (1 - share / D.GRIND_QUEST_SHARE),
            format("Only %d%% of your XP came from quests.", round(share * 100)), true
    end)

rule("rested", "No rested XP",
    "Rested XP doubles kill XP. Always log out in an inn or a city (5% of a level per 8 hours, up to 1.5 levels), and save the bonus for stretches where you kill a lot.",
    function(s, c, perHour)
        local xp = s.xp or 0
        local kill = s.xpKill or 0
        if c.rested ~= false or xp <= 0 or kill <= 0 then
            return 0
        end
        local killShare = kill / xp
        if killShare < 0.5 or (s.xpKillUnrested or 0) < kill * 0.8 then
            return 0
        end
        return min(4, 6 * killShare),
            format("No rested bonus, and %d%% of your XP is from kills.", round(killShare * 100)), true
    end)

rule("noshield", "No shield equipped",
    "Protection needs a one-hander and a shield: Shield Block, Revenge and your rage from blocks all depend on it. Buy or quest for a current shield.",
    function(s, c)
        if c.class ~= "WARRIOR" or not c.prot or (c.level or 1) < D.PROT_LEVEL or c.hasShield ~= false then
            return 0
        end
        return 6, format("Level %d Warrior without a shield in the off hand.", c.level or 0), true
    end)

rule("earlyshield", "Shield before level 16",
    "Before Shield Block at 16 a two-hander with Arms talents kills faster. Switch to one-hander and shield, and respec to Protection, at 16.",
    function(s, c)
        if c.class ~= "WARRIOR" or not c.prot or (c.level or 1) >= D.PROT_LEVEL or (c.level or 1) < 6
            or c.hasShield ~= true then
            return 0
        end
        return 4, format("Level %d with a shield equipped.", c.level or 0), true
    end)

rule("bags", "Bags full",
    "With no free bag slot you leave loot and quest items on the ground. Vendor on your next pass through town and buy bigger bags when you can.",
    function(s, c)
        if c.bagsFree ~= 0 then
            return 0
        end
        return 3, "No free bag slots.", true
    end)

rule("party", "Grouped with a much higher level",
    "XP is split by level, and a party member far above you takes most of it (a much higher one reduces it to nothing). Group with players within a few levels.",
    function(s, c)
        local diff = c.partyLevelDiff or 0
        if diff < D.HIGH_PARTY_LEVELS then
            return 0
        end
        return min(15, 3 + diff), format("A party member is %d levels above you.", diff), true
    end)

-- Evaluate all rules. sums: window sums from the tracker. ctx: level, class, prot,
-- hasShield, hasHearth, hearthReadySecs, bagsFree, greyQuests, redQuests, rested,
-- instanceRuns, instanceName, partyLevelDiff.
-- Returns factors sorted by minutes lost per hour, largest first.
function F.Evaluate(sums, ctx)
    local out = {}
    sums = sums or {}
    ctx = ctx or {}
    local secs = sums.secs or 0
    if secs < D.MIN_GRADE_SECONDS then
        return out
    end
    local function perHour(seconds)
        return seconds / secs * 60
    end
    for _, r in ipairs(rules) do
        local minutes, detail, estimate = r.fn(sums, ctx, perHour)
        if minutes and minutes >= F.MIN_MINUTES then
            out[#out + 1] = {
                key = r.key,
                name = r.name,
                minutes = minutes,
                detail = detail,
                advice = (ctx.class ~= "WARRIOR" and r.generic) or r.advice,
                estimate = estimate and true or false,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.minutes ~= b.minutes then
            return a.minutes > b.minutes
        end
        return a.key < b.key
    end)
    return out
end

-- The n largest factors.
function F.Top(sums, ctx, n)
    local all = F.Evaluate(sums, ctx)
    local top = {}
    for i = 1, min(n or 5, #all) do
        top[i] = all[i]
    end
    return top, all
end

-- 0..1 severity for colouring a row.
function F.Severity(minutes)
    return max(0, min(1, (minutes or 0) / 12))
end
