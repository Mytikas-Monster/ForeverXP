-- Loads the whole addon against the fake client and plays simulated sessions.
local T = ...
local stub = require("tests.wowstub")

local function start(options)
    local world = stub.install(options)
    world.load()
    world.login()
    return world, world.ns
end

local function noErrors(world)
    local errors = _G.ForeverXPDB and _G.ForeverXPDB.errors or {}
    if #errors > 0 then
        error("addon recorded an error: " .. tostring(errors[1].msg), 2)
    end
    for _, line in ipairs(world.chat) do
        if line:find("|cffff5555error|r", 1, true) then
            error("addon printed an error: " .. line, 2)
        end
    end
end

local function find(list, key)
    for _, f in ipairs(list) do
        if f.key == key then
            return f
        end
    end
end

-- Ten minutes of steady solo grinding: 25 s fight, 5 s pause, 150 XP a kill.
local function grind(world, fights, xp)
    for _ = 1, fights or 20 do
        world.fight(25, 1, xp or 150)
        world.advance(5)
    end
end

T.test("loads, registers its events and shows a window", function()
    local world, ns = start()
    T.eq(#ns.Core.unregistered, 0)
    T.ok(#ns.Core.registered >= 20)
    T.ok(_G.ForeverXPWindow, "window exists")
    T.ok(_G.ForeverXPWindow:IsShown())
    T.ok(type(_G.SlashCmdList.FOREVERXP) == "function")
    T.eq(_G.SLASH_FOREVERXP1, "/fxp")
    world.advance(5)
    local s = ns.Core.Snapshot()
    T.eq(s.ready, false)
    T.eq(s.level, 20)
    T.eq(s.class, "WARRIOR")
    T.eq(#s.factors, 0)
    noErrors(world)
end)

T.test("an event the client does not know does not break loading", function()
    local world, ns = start()
    local ok = pcall(ns.Core.frame.RegisterEvent, ns.Core.frame, "COMBAT_LOG_EVENT_UNFILTERED")
    T.eq(ok, false, "the stub rejects unknown events like the client does")
    noErrors(world)
end)

T.test("steady grinding: rate, grade, kill accounting, pulls", function()
    local world, ns = start()
    grind(world, 20)
    world.advance(5)
    local s = ns.Core.Snapshot()
    local w = s.window
    T.eq(w.xp, 3000)
    T.eq(w.kills, 20)
    T.eq(w.soloKills, 20)
    T.eq(w.xpKill, 3000)
    T.eq(w.pulls, 20)
    T.eq(w.pullKills, 20)
    T.near(w.t_combat, 500, 1)
    T.near(w.combatSolo, 500, 1)
    T.near(w.t_downtime, 105, 2)
    T.near(s.rate, 3000 * 3600 / 605, 1)
    T.eq(s.ready, true)
    T.eq(s.grade.letter, "A")           -- 17.9k/h against a par of 11.1k at level 20 = 160%
    T.near(s.baseline, 11122, 10)
    T.ok(s.eta and s.eta > 0 and s.eta < s.etaPar, "faster than par means fewer hours")
    T.ok(s.etaFlat > s.eta, "flat-rate estimate is the pessimistic one")
    noErrors(world)
end)

T.test("a long run becomes the top factor", function()
    local world, ns = start()
    grind(world, 12)
    world.speed = 7
    world.advance(1200)
    world.speed = 0
    world.advance(2)
    local s = ns.Core.Snapshot()
    T.near(s.window.t_travel, 1200, 2)
    T.near(s.window.t_move or 0, 0, 0.001)
    T.eq(s.factors[1].key, "travel")
    T.near(s.factors[1].minutes, 1200 / s.window.secs * 60 - 12, 0.2)
    noErrors(world)
end)

T.test("short repositioning is not travel", function()
    local world, ns = start()
    for _ = 1, 30 do
        world.fight(15, 1, 150)
        world.speed = 7
        world.advance(8)
        world.speed = 0
    end
    local w = ns.Core.Snapshot().window
    T.near(w.t_move, 240, 1)
    T.eq(w.t_travel, nil)
    noErrors(world)
end)

T.test("a brief stop does not break a run, a real stop does", function()
    local world, ns = start()
    world.speed = 7
    world.advance(15)
    world.speed = 0
    world.advance(2)
    world.speed = 7
    world.advance(15)
    local w = ns.Tracker.Window()
    T.near(w.t_travel, 30, 0.001)
    world.speed = 0
    world.advance(10)
    world.speed = 7
    world.advance(10)
    w = ns.Tracker.Window()
    T.near(w.t_travel, 30, 0.001)
    T.near(w.t_move, 10, 0.001)
    noErrors(world)
end)

T.test("standing still: recovery after a fight, idle after 45 s", function()
    local world, ns = start()
    world.advance(120)
    local w = ns.Tracker.Window()
    T.near(w.t_idle, 120, 0.001)
    T.near(w.t_pause or 0, 0, 0.001)
    world.fight(20, 1, 150)
    world.advance(60)
    w = ns.Tracker.Window()
    T.near(w.t_downtime, 44, 1.001)
    T.near(w.t_idle, 120 + 16, 1.001)
    noErrors(world)
end)

T.test("AFK counts as idle at once", function()
    local world, ns = start()
    world.afk = true
    world.advance(20)
    T.near(ns.Tracker.Window().t_idle, 20, 0.001)
    noErrors(world)
end)

T.test("walking home with Hearthstone ready is noticed", function()
    local world, ns = start()
    grind(world, 12)
    world.speed = 7
    world.advance(300)
    world.subzone = "Goldshire"            -- reaching the town is the arrival
    world.advance(10)
    world.resting, world.subzone, world.speed = true, "Lion's Pride Inn", 0
    world.advance(5)
    world.subzone = "Goldshire"            -- stepping back out is not a second one
    world.advance(5)
    local s = ns.Core.Snapshot()
    T.eq(s.window.hearthMissed, 1)
    T.near(s.window.hearthMissedSecs, 285, 6)
    local f = find(s.allFactors, "hearth")
    T.ok(f, "hearth factor listed")
    T.ok(f.detail:find("1 time"), f.detail)
    noErrors(world)
end)

T.test("no Hearthstone blame when it was on cooldown, bound elsewhere, or the walk was short", function()
    local world, ns = start()
    world.hearthStart, world.hearthDuration = world.now, 3600
    grind(world, 12)
    world.speed = 7
    world.advance(300)
    world.resting, world.subzone, world.speed = true, "Goldshire", 0
    world.advance(5)
    T.eq(ns.Tracker.Window().hearthMissed, nil, "on cooldown")

    world = start()
    world.bind = "Lakeshire"
    grind(world, 12)
    world.speed = 7
    world.advance(300)
    world.resting, world.subzone, world.speed = true, "Goldshire", 0
    world.advance(5)
    T.eq(world.ns.Tracker.Window().hearthMissed, nil, "not the bind inn")

    world = start()
    grind(world, 12)
    world.speed = 7
    world.advance(200)
    world.fight(20, 1, 150)
    world.speed = 7
    world.advance(100)
    world.resting, world.subzone, world.speed = true, "Goldshire", 0
    world.advance(5)
    T.eq(world.ns.Tracker.Window().hearthMissed, nil, "a fight on the way resets the walk")
    noErrors(world)
end)

T.test("using the Hearthstone is counted", function()
    local world, ns = start()
    world.advance(10)
    world.hearthStart, world.hearthDuration = world.now, 3600
    world.advance(3)
    T.eq(ns.Tracker.Window().hearthUsed, 1)
    world.advance(100)
    T.eq(ns.Tracker.Session().hearthReadySecs, 0)
    noErrors(world)
end)

T.test("deaths and corpse runs", function()
    local world, ns = start()
    grind(world, 12)
    world.dead = true
    world.fire("PLAYER_DEAD")
    world.speed = 8
    world.advance(180)
    world.dead, world.speed = false, 0
    world.advance(2)
    local s = ns.Core.Snapshot()
    T.eq(s.window.deaths, 1)
    T.near(s.window.t_dead, 180, 1)
    T.eq(s.factors[1].key, "deaths")
    noErrors(world)
end)

T.test("quest turn-ins are quest XP; small ones are low-value", function()
    local world, ns = start()
    world.resting = true
    world.turnIn(1500)
    world.advance(3)
    world.turnIn(100)
    world.advance(3)
    local w = ns.Tracker.Window()
    T.eq(w.xpQuest, 1600)
    T.eq(w.questTurnins, 2)
    T.eq(w.lowQuests, 1)
    T.eq(w.xpKill, nil)
    T.eq(w.kills, nil)
    noErrors(world)
end)

T.test("exploration XP out of combat is neither kill nor quest", function()
    local world, ns = start()
    world.gainXP(70)
    world.advance(3)
    local w = ns.Tracker.Window()
    T.eq(w.xpOther, 70)
    T.eq(w.kills, nil)
    noErrors(world)
end)

T.test("level-ups are counted in full", function()
    local world, ns = start()
    world.xp = 23200 - 100                 -- 100 XP short of level 21
    ns.Core.Reset()
    world.gainXP(300)
    world.advance(3)
    T.eq(world.level, 21)
    T.eq(ns.Tracker.Totals().xp, 300)
    T.eq(ns.Core.Snapshot().level, 21)
    world.gainXP(25000 + 27300 + 50)        -- two more levels in one gain
    world.advance(3)
    T.eq(world.level, 23)
    T.eq(world.xp, 50)
    T.eq(ns.Tracker.Totals().xp, 300 + 25000 + 27300 + 50)
    noErrors(world)
end)

T.test("XPDelta handles a level that lags behind the XP bar", function()
    local world, ns = start()
    T.eq(ns.Core.XPDelta(100, 400, 1, 250, 400, 1), 150)
    T.eq(ns.Core.XPDelta(350, 400, 1, 50, 900, 2), 100)
    T.eq(ns.Core.XPDelta(350, 400, 1, 50, 900, 1), 100)
    T.eq(ns.Core.XPDelta(350, 400, 1, 50, 1400, 3), 50 + 900 + 50)
    T.eq(ns.Core.XPDelta(nil, nil, nil, 50, 900, 2), 0)
    noErrors(world)
end)

T.test("rested state at the time of the kill is used", function()
    local world, ns = start()
    world.rested = 5000
    world.advance(2)
    world.fight(20, 1, 300)
    world.rested = 0
    world.advance(3)
    world.fight(20, 1, 150)
    world.advance(3)
    local w = ns.Tracker.Window()
    T.eq(w.xpKill, 450)
    T.eq(w.xpKillUnrested, 150)
    T.eq(w.soloKillBase, 300)
    noErrors(world)
end)

T.test("town time and what it was spent on", function()
    local world, ns = start()
    world.resting = true
    world.advance(200)
    world.fire("MERCHANT_SHOW")
    world.advance(100)
    world.fire("MERCHANT_CLOSED")
    world.advance(300)
    local s = ns.Core.Snapshot()
    T.near(s.window.t_town, 600, 0.001)
    T.near(s.window.town_vendor, 100, 0.001)
    T.eq(s.factors[1].key, "town")
    T.ok(s.factors[1].detail:find("vendor"), s.factors[1].detail)
    -- A vendor outside a rest area still counts as town time, not idling.
    world.resting = false
    world.fire("TRAINER_SHOW")
    world.advance(60)
    world.fire("TRAINER_CLOSED")
    T.near(ns.Tracker.Window().town_trainer, 60, 0.001)
    T.near(ns.Tracker.Window().t_idle or 0, 0, 0.001)
    noErrors(world)
end)

T.test("flight paths", function()
    local world, ns = start()
    grind(world, 12)
    world.taxi, world.speed = true, 30
    world.advance(400)
    world.taxi, world.speed = false, 0
    world.advance(2)
    local s = ns.Core.Snapshot()
    T.near(s.window.t_taxi, 400, 1)
    T.eq(s.factors[1].key, "taxi")
    noErrors(world)
end)

T.test("dungeon runs: repeats are counted, a corpse run back in is not", function()
    local world, ns = start()
    local function run(seconds)
        world.instance, world.instanceName = true, "The Deadmines"
        world.fire("PLAYER_ENTERING_WORLD", false, false)
        for _ = 1, math.floor(seconds / 40) do
            world.fight(30, 2, 120)
            world.speed = 7
            world.advance(10)
            world.speed = 0
        end
        world.instance = false
        world.fire("PLAYER_ENTERING_WORLD", false, false)
        world.advance(5)
    end
    run(400)
    T.eq(ns.Tracker.InstanceRuns("The Deadmines"), 1)
    -- Wipe: die inside, release, run back in.
    world.instance = true
    world.fire("PLAYER_ENTERING_WORLD", false, false)
    world.advance(5)
    world.fire("PLAYER_DEAD")
    world.dead, world.instance = true, false
    world.fire("PLAYER_ENTERING_WORLD", false, false)
    world.advance(30)
    world.dead, world.instance = false, true
    world.fire("PLAYER_ENTERING_WORLD", false, false)
    world.advance(5)
    world.instance = false
    world.advance(5)
    T.eq(ns.Tracker.InstanceRuns("The Deadmines"), 2, "the wipe run-back did not add a run")
    run(400)
    run(400)
    local s = ns.Core.Snapshot()
    T.eq(s.context.instanceRuns, 4)
    T.eq(s.context.instanceName, "The Deadmines")
    T.ok(s.window.instanceSecs >= 1200)
    T.eq(s.window.t_travel, nil, "walking inside a dungeon is not travel")
    T.eq(s.window.soloKills, nil, "dungeon kills are not judged as solo kills")
    local f = find(s.allFactors, "dungeon")
    T.ok(f, "repeat-dungeon factor listed")
    T.ok(f.detail:find("Run 4 of The Deadmines"), f.detail)
    noErrors(world)
end)

T.test("context checks: shield, bags, quest log, party", function()
    local world, ns = start()
    grind(world, 12)
    world.offhand = nil
    world.bagsFree = 0
    world.questLevels = { 20, 19, 12, 9, 26, 22 }
    world.group, world.partyLevels = true, { 27, 19 }
    world.advance(6)
    local s = ns.Core.Snapshot()
    T.eq(s.context.hasShield, false)
    T.eq(s.context.bagsFree, 0)
    T.eq(s.context.greyQuests, 2)
    T.eq(s.context.redQuests, 1)
    T.eq(s.context.partyLevelDiff, 7)
    for _, key in ipairs({ "noshield", "bags", "quests", "party" }) do
        T.ok(find(s.allFactors, key), key .. " listed")
    end
    _G.SlashCmdList.FOREVERXP("prot off")
    T.eq(find(ns.Core.Snapshot().allFactors, "noshield"), nil)
    noErrors(world)
end)

T.test("session survives a reload and a short logout, not a long one", function()
    local world, ns = start()
    grind(world, 12)
    local xp = ns.Tracker.Totals().xp
    local elapsed = ns.Tracker.Session().elapsed
    local saved = world.logout()
    local epoch = world.epoch

    local again = stub.install({ saved = saved })
    again.epoch = epoch + 120
    again.load()
    again.login()
    T.eq(again.ns.Tracker.Totals().xp, xp)
    T.eq(again.ns.Tracker.Session().elapsed, elapsed)
    again.advance(5)
    T.eq(again.ns.Core.Snapshot().ready, true)
    noErrors(again)
    saved = again.logout()
    epoch = again.epoch

    local later = stub.install({ saved = saved })
    later.epoch = epoch + 3600
    later.load()
    later.login()
    T.eq(later.ns.Tracker.Totals().xp, nil)
    T.eq(later.ns.Tracker.Session().elapsed, 0)
    noErrors(later)
end)

T.test("the saved window position and size from v1.2 are reused", function()
    local world = stub.install({ saved = { ForeverXPDB = {
        height = 204.6, width = 246.6, hidden = false,
        position = { y = -7.6, x = -294.1, point = "TOPRIGHT", relativePoint = "TOPRIGHT" },
    } } })
    world.load()
    world.login()
    local window = _G.ForeverXPWindow
    local point, _, relativePoint, x, y = window:GetPoint()
    T.eq(point, "TOPRIGHT")
    T.eq(relativePoint, "TOPRIGHT")
    T.near(x, -294.1, 0.001)
    T.near(y, -7.6, 0.001)
    T.near(window:GetWidth(), 246.6, 0.001)
    T.ok(window:GetHeight() >= 236, "too-small saved height is raised to the minimum")
    T.ok(window:IsShown())
    noErrors(world)
end)

T.test("slash commands, report and self-test run clean", function()
    local world, ns = start()
    grind(world, 12)
    world.speed = 7
    world.advance(400)
    world.speed = 0
    local slash = _G.SlashCmdList.FOREVERXP
    local before = #world.chat
    slash("report")
    T.ok(#world.chat >= before + 3, "report printed")
    local text = table.concat(world.chat, "\n")
    T.ok(text:find("grade"), "report names the grade")
    T.ok(text:find("to level 60"), "report gives the estimate")
    T.ok(text:find("Travel on foot"), "report lists the top factor")
    slash("selftest")
    text = table.concat(world.chat, "\n")
    T.ok(text:find("UnitXP = ok"), "selftest lists API status")
    T.ok(text:find("movement source = speed"), text)
    T.ok(_G.ForeverXPDB.selftest and #_G.ForeverXPDB.selftest.lines > 20, "selftest stored for reading after a reload")
    slash("hide")
    T.eq(_G.ForeverXPWindow:IsShown(), false)
    T.eq(_G.ForeverXPDB.hidden, true)
    slash("")
    T.eq(_G.ForeverXPWindow:IsShown(), true)
    slash("scale 1.25")
    T.eq(_G.ForeverXPDB.scale, 1.25)
    slash("scale 9")
    T.eq(_G.ForeverXPDB.scale, 1.25)
    slash("lock")
    T.eq(_G.ForeverXPDB.locked, true)
    slash("unlock")
    T.eq(_G.ForeverXPDB.locked, false)
    slash("errors")
    slash("help")
    slash("  REPORT  ")
    slash("reset")
    T.eq(ns.Tracker.Totals().xp, nil)
    _G.ForeverXP_OnAddonCompartmentClick()
    T.eq(_G.ForeverXPWindow:IsShown(), false)
    noErrors(world)
end)

T.test("window text and tooltips", function()
    local world, ns = start()
    world.advance(5)
    local window = _G.ForeverXPWindow
    local function texts()
        local out = {}
        local function walk(w)
            if w.text then
                out[#out + 1] = tostring(w.text)
            end
            for _, child in ipairs(w.children) do
                walk(child)
            end
        end
        walk(window)
        for _, f in ipairs(world.frames) do
            if f ~= window and f.kind == "Frame" and f.shown then
                walk(f)
            end
        end
        return table.concat(out, "\n")
    end
    local early = texts()
    T.ok(early:find("grade in"), early)
    T.ok(early:find("Collecting data"), early)
    grind(world, 12)
    world.speed = 7
    world.advance(600)
    world.speed = 0
    world.advance(2)
    local text = texts()
    T.ok(text:find("XP/h"), text)
    T.ok(text:find("to level 60"), text)
    T.ok(text:find("Level 20"), text)
    T.ok(text:find("Top time losses"), text)
    T.ok(text:find("Travel on foot"), text)
    T.ok(text:find("min/h"), text)
    window.scripts.OnEnter(window)
    local tip = table.concat(_G.GameTooltip.lines, "\n")
    T.ok(tip:find("Par for a level 20 warrior"), tip)
    T.ok(tip:find("At grade A"), tip)
    T.ok(tip:find("XP: kills 100%%"), tip)
    window.scripts.OnLeave(window)
    local hovered
    for _, f in ipairs(world.frames) do
        if f.scripts.OnEnter and f ~= window and f.shown then
            f.scripts.OnEnter(f)
            hovered = true
            break
        end
    end
    T.ok(hovered, "a factor row can be hovered")
    tip = table.concat(_G.GameTooltip.lines, "\n")
    T.ok(tip:find("Travel on foot"), tip)
    T.ok(tip:find("min lost per hour"), tip)
    T.ok(tip:find("Finish every quest"), tip)
    world.advance(3)       -- tooltip refreshes while hovering
    noErrors(world)
end)

T.test("secret values from the client never raise", function()
    local world, ns = start()
    grind(world, 6)
    for _, name in ipairs({
        "UnitXP", "UnitXPMax", "UnitLevel", "UnitClassBase", "GetXPExhaustion", "UnitAffectingCombat",
        "UnitIsDeadOrGhost", "UnitOnTaxi", "IsResting", "UnitIsAFK", "GetUnitSpeed", "UnitPosition",
        "IsInGroup", "IsInInstance", "GetInstanceInfo", "GetBindLocation", "GetSubZoneText",
        "GetMinimapZoneText", "GetZoneText", "GetRealZoneText", "GetInventoryItemID",
        "C_Container.GetItemCooldown", "C_Container.GetContainerNumFreeSlots", "C_Item.GetItemCount",
        "C_Item.GetItemInfoInstant", "C_QuestLog.GetNumQuestLogEntries", "C_QuestLog.GetInfo",
    }) do
        world.secret[name] = true
    end
    world.fight(20, 1, 150)
    world.fire("QUEST_TURNED_IN", stub.SECRET, stub.SECRET, stub.SECRET)
    world.fire("PLAYER_LEVEL_UP", stub.SECRET)
    world.fire("PLAYER_ENTERING_WORLD", false, false)
    world.fire("PLAYER_DEAD")
    world.advance(30)
    _G.SlashCmdList.FOREVERXP("report")
    _G.SlashCmdList.FOREVERXP("selftest")
    T.ok(table.concat(world.chat, "\n"):find("UnitXP = secret"), "selftest reports secrets")
    _G.ForeverXPWindow.scripts.OnEnter(_G.ForeverXPWindow)
    world.secret = {}
    world.advance(10)
    T.ok(ns.Core.Snapshot().rate > 0)
    noErrors(world)
end)

T.test("missing API calls fall back", function()
    local world, ns = start({ missing = {
        GetUnitSpeed = true, UnitIsAFK = true, UnitClassBase = true, GetXPExhaustion = true,
        ["C_Item.GetItemCount"] = true, ["C_QuestLog.GetInfo"] = true,
    } })
    T.eq(ns.Core.Snapshot().class, "WARRIOR")
    world.speed = 7                      -- the stub moves the position with speed
    world.advance(60)
    T.eq(ns.Activity.MovementSource(), "position")
    T.near(ns.Tracker.Window().t_travel, 60, 2)
    T.eq(ns.Core.Snapshot().context.rested, nil)
    _G.SlashCmdList.FOREVERXP("selftest")
    T.ok(table.concat(world.chat, "\n"):find("GetUnitSpeed = missing"))
    noErrors(world)

    world, ns = start({ missing = { GetUnitSpeed = true, UnitPosition = true } })
    world.fire("PLAYER_STARTED_MOVING")
    world.advance(40)
    world.fire("PLAYER_STOPPED_MOVING")
    world.advance(10)
    T.eq(ns.Activity.MovementSource(), "events")
    T.near(ns.Tracker.Window().t_travel, 40, 0.001)
    noErrors(world)
end)

T.test("a loading screen is one capped step and not movement", function()
    local world, ns = start()
    world.advance(5)
    world.now = world.now + 900          -- client frozen for 15 minutes
    world.x = world.x + 5000
    world.fire("PLAYER_ENTERING_WORLD", false, false)
    world.advance(2)
    local s = ns.Tracker.Session()
    T.ok(s.elapsed <= 5 + ns.Data.MAX_TICK_SECONDS + 2, "elapsed " .. s.elapsed)
    T.eq(ns.Tracker.Window().t_travel, nil)
    noErrors(world)
end)

T.test("errors in handlers are stored, printed once and do not propagate", function()
    local world, ns = start()
    local calls = 0
    local function boom()
        calls = calls + 1
        error("kaput")
    end
    T.eq(ns.Core.SafeCall(boom), false)
    T.eq(ns.Core.SafeCall(boom), false)
    T.eq(calls, 2)
    local errors = _G.ForeverXPDB.errors
    T.eq(#errors, 1)
    T.eq(errors[1].count, 2)
    T.ok(errors[1].msg:find("kaput"))
    local printed = 0
    for _, line in ipairs(world.chat) do
        if line:find("kaput") then
            printed = printed + 1
        end
    end
    T.eq(printed, 1)
    _G.SlashCmdList.FOREVERXP("errors clear")
    T.eq(#_G.ForeverXPDB.errors, 0)
end)

T.test("level cap", function()
    local world, ns = start({ level = 60 })
    world.advance(400)
    local s = ns.Core.Snapshot()
    T.eq(s.capped, true)
    T.eq(s.eta, nil)
    _G.SlashCmdList.FOREVERXP("report")
    noErrors(world)
end)
