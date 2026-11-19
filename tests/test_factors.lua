local T = ...
local ns = T.pure()
local F = ns.Factors

-- An hour of efficient solo questing at level 20: nothing should be flagged.
local function sums(overrides)
    local s = {
        secs = 3600,
        t_combat = 2100, combatSolo = 2100,
        t_travel = 600, t_move = 200, t_town = 200, t_downtime = 400, t_pause = 100,
        xp = 16000, xpKill = 9600, xpQuest = 6400, xpKillUnrested = 9600,
        kills = 80, soloKills = 80, soloKillBase = 80 * 130, soloKillExpected = 80 * 145,
        pulls = 32, pullKills = 80,
        questTurnins = 6,
    }
    for k, v in pairs(overrides or {}) do
        s[k] = v
    end
    return s
end

local function ctx(overrides)
    local c = {
        level = 20, class = "WARRIOR", prot = true, hasShield = true, hasHearth = true,
        hearthReadySecs = 0, bagsFree = 12, greyQuests = 0, redQuests = 0, rested = true,
        instanceRuns = 0, partyLevelDiff = 0,
    }
    for k, v in pairs(overrides or {}) do
        c[k] = v
    end
    return c
end

local function find(list, key)
    for i, f in ipairs(list) do
        if f.key == key then
            return f, i
        end
    end
end

local function top(s, c)
    local list = F.Evaluate(s, c)
    return list[1], list
end

T.test("efficient play raises no factor", function()
    local list = F.Evaluate(sums(), ctx())
    T.eq(#list, 0, list[1] and list[1].key)
end)

T.test("too little data raises no factor", function()
    T.eq(#F.Evaluate(sums({ secs = 200, t_travel = 200 }), ctx()), 0)
    T.eq(#F.Evaluate({}, {}), 0)
    T.eq(#F.Evaluate(nil, nil), 0)
end)

T.test("excessive travel", function()
    local f = top(sums({ t_travel = 1800 }), ctx())
    T.eq(f.key, "travel")
    T.near(f.minutes, 18, 0.01)
    T.eq(f.estimate, false)
    T.ok(f.detail:find("30 min"), f.detail)
end)

T.test("rates are per hour even in a short window", function()
    local f = top({ secs = 600, t_travel = 300 }, ctx())
    T.eq(f.key, "travel")
    T.near(f.minutes, 18, 0.01)
end)

T.test("flight paths, town, idle and recovery use their allowances", function()
    T.near(find(F.Evaluate(sums({ t_taxi = 600 }), ctx()), "taxi").minutes, 7, 0.01)
    local town = find(F.Evaluate(sums({ t_town = 900, town_vendor = 240, town_ah = 400, town_mail = 10 }), ctx()), "town")
    T.near(town.minutes, 11, 0.01)
    T.ok(town.detail:find("vendor 4m 00s"), town.detail)
    T.ok(town.detail:find("auction house"), town.detail)
    T.ok(not town.detail:find("mail"), town.detail)
    T.near(find(F.Evaluate(sums({ t_idle = 600 }), ctx()), "idle").minutes, 9, 0.01)
    T.near(find(F.Evaluate(sums({ t_downtime = 900 }), ctx()), "downtime").minutes, 7, 0.01)
end)

T.test("hearthstone: walked home while it was ready", function()
    local f = find(F.Evaluate(sums({ hearthMissed = 1, hearthMissedSecs = 480 }), ctx()), "hearth")
    T.near(f.minutes, 8, 0.01)
    T.ok(f.detail:find("1 time"), f.detail)
    T.eq(find(F.Evaluate(sums({ hearthMissed = 1, hearthMissedSecs = 480 }), ctx({ hasHearth = false })), "hearth"), nil)
end)

T.test("hearthstone: unused for an hour while travelling a lot", function()
    local list = F.Evaluate(sums({ t_travel = 1320 }), ctx({ hearthReadySecs = 4000 }))
    local f = find(list, "hearth")
    T.near(f.minutes, 2.5, 0.01)
    T.eq(f.estimate, true)
    T.eq(find(F.Evaluate(sums(), ctx({ hearthReadySecs = 4000 })), "hearth"), nil, "no reminder without excess travel")
end)

T.test("deaths", function()
    local f = top(sums({ deaths = 3, t_dead = 540 }), ctx())
    T.eq(f.key, "deaths")
    T.near(f.minutes, 9, 0.01)
    T.ok(f.detail:find("3 deaths"), f.detail)
end)

T.test("slow kills", function()
    local f = top(sums({ combatSolo = 2400, soloKills = 40, soloKillBase = 40 * 130, soloKillExpected = 40 * 145 }), ctx())
    T.eq(f.key, "slowkills")
    T.near(f.minutes, 20, 0.01)
    T.eq(find(F.Evaluate(sums({ combatSolo = 300, soloKills = 4 }), ctx()), "slowkills"), nil, "too few kills to judge")
end)

T.test("mobs too low level", function()
    local f = top(sums({ soloKillBase = 80 * 72.5 }), ctx())
    T.eq(f.key, "lowmobs")
    T.near(f.minutes, 35 * (0.85 - 0.5) / 0.85, 0.01)
    T.ok(f.detail:find("50%%"), f.detail)
end)

T.test("single-pulling is a Protection Warrior check from 16", function()
    local s = sums({ pulls = 40, pullKills = 42 })
    T.near(find(F.Evaluate(s, ctx()), "singlepull").minutes, 5.25, 0.01)
    T.eq(find(F.Evaluate(s, ctx({ level = 12 })), "singlepull"), nil)
    T.eq(find(F.Evaluate(s, ctx({ class = "MAGE" })), "singlepull"), nil)
    T.eq(find(F.Evaluate(s, ctx({ prot = false })), "singlepull"), nil)
    T.eq(find(F.Evaluate(sums({ pulls = 5, pullKills = 5 }), ctx()), "singlepull"), nil, "too few pulls")
end)

T.test("low-value quests", function()
    local f = top(sums({ lowQuests = 3 }), ctx({ greyQuests = 2, redQuests = 1 }))
    T.eq(f.key, "quests")
    T.near(f.minutes, 12 + 1.5 + 0.5, 0.01)
    T.ok(f.detail:find("3 turn%-ins"), f.detail)
    T.ok(f.detail:find("2 grey quests"), f.detail)
    T.ok(f.detail:find("1 red quest in"), f.detail)
    local only = find(F.Evaluate(sums(), ctx({ greyQuests = 10 })), "quests")
    T.near(only.minutes, 3, 0.01)
    T.ok(only.detail:find("^10 grey"), only.detail)
end)

T.test("repeating a dungeon", function()
    local s = sums({ instanceSecs = 1800 })
    T.eq(find(F.Evaluate(s, ctx({ instanceRuns = 2, instanceName = "The Deadmines" })), "dungeon"), nil)
    local f = find(F.Evaluate(s, ctx({ instanceRuns = 4, instanceName = "The Deadmines" })), "dungeon")
    T.near(f.minutes, 30 * 0.36, 0.01)
    T.ok(f.detail:find("Run 4 of The Deadmines"), f.detail)
    T.eq(find(F.Evaluate(sums({ instanceSecs = 100 }), ctx({ instanceRuns = 5 })), "dungeon"), nil, "not inside lately")
end)

T.test("mostly grinding", function()
    local f = find(F.Evaluate(sums({ xpQuest = 800, xpKill = 15200 }), ctx()), "grinding")
    T.near(f.minutes, 60 * 0.13 * (1 - 0.05 / 0.25), 0.01)
    T.eq(find(F.Evaluate(sums({ xpQuest = 800, xpKill = 15200, instanceSecs = 3000 }), ctx()), "grinding"), nil,
        "dungeon time is not grinding")
end)

T.test("no rested XP", function()
    local s = sums({ xpKill = 14400, xpQuest = 1600, xpKillUnrested = 14400 })
    T.near(find(F.Evaluate(s, ctx({ rested = false })), "rested").minutes, 4, 0.01)
    T.eq(find(F.Evaluate(s, ctx({ rested = true })), "rested"), nil)
    T.eq(find(F.Evaluate(s, ctx({ rested = false, })), "rested").estimate, true)
    local unknown = ctx()
    unknown.rested = nil
    T.eq(find(F.Evaluate(s, unknown), "rested"), nil, "unknown rested state is not flagged")
end)

T.test("setup problems", function()
    T.near(find(F.Evaluate(sums(), ctx({ hasShield = false })), "noshield").minutes, 6, 0.01)
    T.eq(find(F.Evaluate(sums(), ctx({ hasShield = false, prot = false })), "noshield"), nil)
    T.eq(find(F.Evaluate(sums(), ctx({ hasShield = false, class = "ROGUE" })), "noshield"), nil)
    local unknown = ctx()
    unknown.hasShield = nil
    T.eq(find(F.Evaluate(sums(), unknown), "noshield"), nil, "unknown gear is not flagged")
    T.near(find(F.Evaluate(sums(), ctx({ level = 12 })), "earlyshield").minutes, 4, 0.01)
    T.eq(find(F.Evaluate(sums(), ctx({ level = 16 })), "earlyshield"), nil)
    T.near(find(F.Evaluate(sums(), ctx({ bagsFree = 0 })), "bags").minutes, 3, 0.01)
    local nobags = ctx()
    nobags.bagsFree = nil
    T.eq(find(F.Evaluate(sums(), nobags), "bags"), nil)
    T.near(find(F.Evaluate(sums(), ctx({ partyLevelDiff = 6 })), "party").minutes, 9, 0.01)
    T.eq(find(F.Evaluate(sums(), ctx({ partyLevelDiff = 4 })), "party"), nil)
end)

T.test("factors are ranked and the top list is capped at five", function()
    local s = sums({ t_travel = 1800, t_taxi = 600, t_town = 900, t_idle = 600, t_downtime = 900, deaths = 2, t_dead = 300, lowQuests = 1 })
    local five, all = F.Top(s, ctx({ bagsFree = 0 }), 5)
    T.eq(#five, 5)
    T.ok(#all >= 7, "all factors are returned as well")
    T.eq(five[1].key, "travel")
    for i = 2, #all do
        T.ok(all[i - 1].minutes >= all[i].minutes, "sorted at " .. i)
    end
    for _, f in ipairs(all) do
        T.ok(f.minutes >= F.MIN_MINUTES)
        T.ok(type(f.name) == "string" and type(f.advice) == "string" and type(f.detail) == "string", f.key)
    end
end)

T.test("other classes get class-neutral advice", function()
    local s = sums({ deaths = 3, t_dead = 540, t_downtime = 1500 })
    local warrior = find(F.Evaluate(s, ctx()), "deaths")
    local mage = find(F.Evaluate(s, ctx({ class = "MAGE" })), "deaths")
    T.ok(warrior.advice:find("Retaliation"), warrior.advice)
    T.ok(not mage.advice:find("Retaliation"), mage.advice)
    T.ok(not find(F.Evaluate(s, ctx({ class = "MAGE" })), "downtime").advice:find("Victory Rush"))
end)

T.test("durations and severity", function()
    T.eq(F.Duration(55), "55s")
    T.eq(F.Duration(250), "4m 10s")
    T.eq(F.Duration(3725), "1h 02m")
    T.eq(F.Duration(nil), "0s")
    T.eq(F.Severity(0), 0)
    T.eq(F.Severity(6), 0.5)
    T.eq(F.Severity(40), 1)
end)
