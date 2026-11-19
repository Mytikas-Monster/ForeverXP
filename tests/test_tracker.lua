local T = ...

local function fresh()
    local ns = T.pure()
    local tr = ns.Tracker
    tr.Attach(tr.NewSession(0))
    return tr, ns
end

T.test("XP per hour over a steady session", function()
    local tr = fresh()
    for second = 1, 600 do
        tr.Tick(1, "combat")
        if second % 30 == 0 then
            tr.XPGain(100, { now = second, combat = true, solo = true, level = 20 })
        end
    end
    T.eq(tr.Totals().xp, 2000)
    T.eq(tr.Totals().secs, 600)
    T.near(tr.Rate(tr.Totals()), 12000, 0.001)
    T.near(tr.Rate(tr.Window()), 12000, 0.001)
    T.eq(tr.Rate({}), 0)
end)

T.test("the window only covers the last 60 minutes", function()
    local tr = fresh()
    for _ = 1, 3600 do
        tr.Tick(1, "idle")
    end
    for second = 1, 3600 do
        tr.Tick(1, "combat")
        if second % 60 == 30 then
            tr.XPGain(300, { now = second, combat = true })
        end
    end
    local w = tr.Window()
    T.near(tr.Rate(w), 18000, 320)
    T.near(tr.Rate(tr.Totals()), 9000, 1)
    T.ok((w.t_idle or 0) <= 60, "idle hour has rolled out of the window")
    T.eq(tr.Totals().t_idle, 3600)
    local buckets = 0
    for _ in pairs(tr.Session().buckets) do
        buckets = buckets + 1
    end
    T.ok(buckets <= tr.WINDOW_BUCKETS, "old buckets are pruned, have " .. buckets)
end)

T.test("a gain matching a turn-in is quest XP", function()
    local tr = fresh()
    tr.Tick(1, "town")
    tr.QuestTurnIn(100, 500, false)
    tr.XPGain(500, { now = 100.2, combat = true })
    local kills, quests = tr.Resolve(102)
    T.eq(kills, 0)
    T.eq(quests, 1)
    T.eq(tr.Totals().xpQuest, 500)
    T.eq(tr.Totals().questTurnins, 1)
    T.eq(tr.Totals().xpKill, nil)
end)

T.test("a turn-in event arriving after the XP still matches", function()
    local tr = fresh()
    tr.Tick(1, "town")
    tr.XPGain(800, { now = 50, combat = false })
    T.eq(select(2, tr.Resolve(50.5)), 0, "too early to classify")
    tr.QuestTurnIn(50.3, 800, false)
    local _, quests = tr.Resolve(51.1)
    T.eq(quests, 1)
    T.eq(tr.Totals().xpQuest, 800)
end)

T.test("one turn-in claims only one gain; exact amount wins", function()
    local tr = fresh()
    tr.Tick(1, "combat")
    tr.QuestTurnIn(10, 500, false)
    tr.XPGain(140, { now = 10.1, combat = true, solo = true, level = 20 })
    tr.XPGain(500, { now = 10.2, combat = true, solo = true, level = 20 })
    tr.Resolve(20)
    T.eq(tr.Totals().xpQuest, 500)
    T.eq(tr.Totals().xpKill, 140)
    T.eq(tr.Totals().kills, 1)
end)

T.test("kill XP, rested and same-level comparison", function()
    local tr = fresh()
    tr.Tick(1, "combat")
    tr.XPGain(240, { now = 5, combat = true, rested = true, solo = true, level = 20 })
    tr.XPGain(130, { now = 6, combat = true, rested = false, solo = true, level = 20 })
    tr.XPGain(90, { now = 7, combat = true, rested = false, solo = false, level = 20 })
    tr.XPGain(60, { now = 8, combat = true, rested = false, solo = true, instance = true, level = 20 })
    tr.XPGain(45, { now = 9, combat = false })
    local kills = tr.Resolve(20)
    local t = tr.Totals()
    T.eq(kills, 4)
    T.eq(t.xp, 565)
    T.eq(t.xpKill, 520)
    T.eq(t.xpKillUnrested, 280)
    T.eq(t.soloKills, 2)
    T.eq(t.soloKillBase, 250)        -- rested kill counted at half
    T.eq(t.soloKillExpected, 290)    -- 2 x (45 + 5 x 20)
    T.eq(t.xpOther, 45)
end)

T.test("forced resolve flushes pending gains", function()
    local tr = fresh()
    tr.Tick(1, "combat")
    tr.XPGain(100, { now = 5, combat = true })
    T.eq(tr.Resolve(5.1), 0)
    T.eq(tr.Resolve(5.1, true), 1)
end)

T.test("reclassify moves time between activities", function()
    local tr = fresh()
    for _ = 1, 20 do
        tr.Tick(1, "move")
    end
    tr.Reclassify("move", "travel", 20)
    T.eq(tr.Totals().t_move, 0)
    T.eq(tr.Totals().t_travel, 20)
    T.eq(tr.Window().t_travel, 20)
    T.eq(tr.Totals().secs, 20)
end)

T.test("dungeon runs: re-entry after a wipe is the same run", function()
    local tr = fresh()
    T.eq(tr.InstanceEntered("The Deadmines", 100), 1)
    T.eq(tr.InstanceEntered("The Deadmines", 400, true), 1)
    T.eq(tr.InstanceEntered("The Deadmines", 3000), 2)
    T.eq(tr.InstanceEntered("Shadowfang Keep", 6000, true), 1)
    T.eq(tr.InstanceEntered("The Deadmines", 9000), 3)
    local runs, name = tr.InstanceRuns()
    T.eq(runs, 3)
    T.eq(name, "The Deadmines")
    T.eq(tr.InstanceRuns("Shadowfang Keep"), 1)
    T.eq(tr.InstanceRuns("Nowhere"), 0)
    T.eq(tr.InstanceEntered("", 1), 0)
end)

T.test("the session table holds only plain data", function()
    local tr = fresh()
    tr.Tick(30, "combat")
    tr.XPGain(100, { now = 5, combat = true, solo = true, level = 10 })
    tr.Resolve(10)
    tr.InstanceEntered("The Deadmines", 100)
    local function check(v, path)
        local kind = type(v)
        T.ok(kind == "table" or kind == "number" or kind == "string" or kind == "boolean",
            path .. " is a " .. kind)
        if kind == "table" then
            for k, child in pairs(v) do
                T.ok(type(k) == "number" or type(k) == "string", path .. " has a " .. type(k) .. " key")
                check(child, path .. "." .. tostring(k))
            end
        end
    end
    check(tr.Session(), "session")
end)

T.test("nothing happens without a session", function()
    local ns = T.pure()
    local tr = ns.Tracker
    tr.Tick(1, "combat")
    tr.XPGain(100, {})
    tr.QuestTurnIn(1, 100)
    T.eq(tr.Resolve(10), 0)
    T.eq(tr.InstanceEntered("X", 1), 0)
    T.eq(tr.Rate(tr.Window()), 0)
end)
