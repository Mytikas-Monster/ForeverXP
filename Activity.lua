-- ForeverXP / Activity.lua
-- Once a second, decides what the player is doing and books the time in the
-- tracker. Also follows walks home (for the Hearthstone check), pulls, dungeon
-- entries and the slow-changing context (gear, bags, quest log, party).
--
-- Activities, in order of precedence:
--   dead      dead or running back as a ghost
--   taxi      on a flight path
--   combat    in combat
--   town      in a rest area, or at a vendor / trainer / AH / mailbox / bank
--   travel    moving out of combat for 20 s or longer without a real stop
--   move      shorter movement (positioning, walking between mobs)
--   downtime  standing still right after a fight (recovering, looting)
--   idle      standing still for 45 s or longer, or flagged AFK
--   pause     any other short stop

local _, ns = ...
local D, T, A = ns.Data, ns.Tracker, ns.API

local Act = {}
ns.Activity = Act

local max, min = math.max, math.min

local POLL_SECONDS = 5
local PULL_SETTLE_SECONDS = 3   -- kill XP can arrive just after combat ends
local MOVE_YARDS = 1.5          -- position change per tick that counts as moving

local st

local function fresh()
    return {
        inCombat = false,
        lastCombatEnd = -1e9,
        moveStreak = 0, moveCounted = 0, streakIsTravel = false,
        stillStreak = 0, pauseCounted = 0, stillIsIdle = false, stillAfterCombat = false,
        townWindow = nil,
        tripSecs = 0, tripHearthReady = false,
        wasAtBind = nil,
        hearthReady = nil, hasHearth = nil,
        pull = nil,
        posX = nil, posY = nil, posMap = nil,
        movingEvent = nil, moveSource = "none",
        inInstance = false,
        sincePoll = POLL_SECONDS,
        ctx = {},
    }
end

----------------------------------------------------------------------------
-- Movement
----------------------------------------------------------------------------

-- Three sources, best first: speed, position change, start/stop events.
local function isMoving()
    local x, y, map = A.Position()
    local moved
    if x then
        if st.posX and st.posMap == map then
            local dx, dy = x - st.posX, y - st.posY
            moved = (dx * dx + dy * dy) > MOVE_YARDS * MOVE_YARDS
        end
        st.posX, st.posY, st.posMap = x, y, map
    else
        st.posX = nil
    end
    local speed = A.Speed()
    if speed then
        st.moveSource = "speed"
        return speed > 0
    end
    if moved ~= nil then
        st.moveSource = "position"
        return moved
    end
    if st.movingEvent ~= nil then
        st.moveSource = "events"
        return st.movingEvent
    end
    return false
end

local function resetStreaks()
    st.moveStreak, st.moveCounted, st.streakIsTravel = 0, 0, false
    st.stillStreak, st.pauseCounted, st.stillIsIdle = 0, 0, false
end

local function movingState(dt, inInstance)
    st.stillStreak, st.pauseCounted, st.stillIsIdle = 0, 0, false
    st.moveStreak = st.moveStreak + dt
    if inInstance then
        return "move"   -- walking through a dungeon is part of the run
    end
    if st.moveStreak >= D.TRAVEL_STREAK_SECONDS then
        if not st.streakIsTravel then
            -- The run turned out to be a long one: its start was travel too.
            T.Reclassify("move", "travel", st.moveCounted)
            st.streakIsTravel, st.moveCounted = true, 0
        end
        return "travel"
    end
    st.moveCounted = st.moveCounted + dt
    return "move"
end

local function stillState(dt, now)
    if st.stillStreak == 0 then
        st.stillAfterCombat = (now - st.lastCombatEnd) <= D.DOWNTIME_WINDOW_SECONDS
    end
    st.stillStreak = st.stillStreak + dt
    if st.stillStreak > D.STILL_GRACE_SECONDS then
        st.moveStreak, st.moveCounted, st.streakIsTravel = 0, 0, false
    end
    if A.AFK() then
        return "idle"
    end
    if st.stillStreak >= D.IDLE_AFTER_SECONDS then
        if not st.stillIsIdle then
            st.stillIsIdle = true
            if not st.stillAfterCombat then
                T.Reclassify("pause", "idle", st.pauseCounted)
            end
            st.pauseCounted = 0
        end
        return "idle"
    end
    if st.stillAfterCombat then
        return "downtime"
    end
    st.pauseCounted = st.pauseCounted + dt
    return "pause"
end

----------------------------------------------------------------------------
-- Pulls
----------------------------------------------------------------------------

local function finalizePull()
    local p = st.pull
    st.pull = nil
    if p and p.solo and p.kills > 0 then
        T.Add("pulls", 1)
        T.Add("pullKills", p.kills)
    end
end

function Act.CombatStart(now)
    if not st then
        return
    end
    finalizePull()
    st.inCombat = true
    local inInstance = A.InInstance()
    st.pull = { kills = 0, solo = not A.InGroup() and not inInstance }
    Act.Worked()
end

function Act.CombatEnd(now)
    if not st then
        return
    end
    st.inCombat = false
    st.lastCombatEnd = now
    if st.pull then
        st.pull.endedAt = now
    end
end

-- Kills the tracker has just classified.
function Act.Kills(n)
    if st and st.pull then
        st.pull.kills = st.pull.kills + n
    end
end

-- In combat now or until two seconds ago: an XP gain is a kill.
function Act.RecentCombat(now)
    return st ~= nil and (st.inCombat or (now - st.lastCombatEnd) <= 2)
end

-- Something productive happened, so the player is not on a walk home.
function Act.Worked()
    if st then
        st.tripSecs = 0
    end
end

function Act.Died()
    local session = T.Session()
    if session and session.insideInstance then
        session.runBack = session.insideInstance
    end
end

----------------------------------------------------------------------------
-- Dungeons
----------------------------------------------------------------------------

function Act.CheckInstance()
    local session = T.Session()
    if not st or not session then
        return
    end
    local inside = A.InInstance()
    if inside and not st.inInstance then
        local name = A.InstanceName()
        if name then
            local sameRun = session.insideInstance == name or session.runBack == name or A.Dead()
            T.InstanceEntered(name, A.Epoch(), sameRun)
            session.insideInstance = name
            session.runBack = nil
            st.inInstance = true
        end
    elseif not inside and st.inInstance then
        st.inInstance = false
        session.insideInstance = nil
    elseif not inside and session.insideInstance then
        session.insideInstance = nil
    end
end

----------------------------------------------------------------------------
-- Context that changes slowly
----------------------------------------------------------------------------

local function poll()
    local c = st.ctx
    local level = A.Level() or 1
    c.hasShield = A.HasShield()
    c.bagsFree = A.BagsFree()
    st.hasHearth = A.HasHearth()
    c.hasHearth = st.hasHearth
    local grey, red = 0, 0
    if level < D.MAX_LEVEL then
        local greyLevel = D.GreyLevel(level)
        for _, questLevel in ipairs(A.QuestLevels()) do
            if questLevel <= greyLevel then
                grey = grey + 1
            elseif questLevel >= level + 5 then
                red = red + 1
            end
        end
    end
    c.greyQuests, c.redQuests = grey, red
    local partyMax = A.PartyMaxLevel()
    c.partyLevelDiff = partyMax and max(0, partyMax - level) or 0
    local rested = A.Rested()
    if rested == nil then
        c.rested = nil
    else
        c.rested = rested > 0
    end
end

-- A copy of the context for the factor rules.
function Act.Context()
    local out = {}
    if not st then
        return out
    end
    for k, v in pairs(st.ctx) do
        out[k] = v
    end
    local session = T.Session()
    out.hearthReadySecs = session and session.hearthReadySecs or 0
    out.instanceRuns, out.instanceName = T.InstanceRuns()
    return out
end

----------------------------------------------------------------------------
-- Sampling
----------------------------------------------------------------------------

function Act.Sample(dt, now)
    local session = T.Session()
    if not session then
        return
    end
    if not st then
        Act.Reset()
    end

    st.sincePoll = st.sincePoll + dt
    if st.sincePoll >= POLL_SECONDS then
        st.sincePoll = 0
        poll()
    end
    Act.CheckInstance()

    local inInstance = st.inInstance
    local solo = not A.InGroup()
    local resting = A.Resting()
    local moving = isMoving()

    local state
    if A.Dead() then
        state = "dead"
    elseif A.OnTaxi() then
        state = "taxi"
    elseif st.inCombat then
        state = "combat"
    elseif st.townWindow or resting then
        state = "town"
    elseif moving then
        state = movingState(dt, inInstance)
    else
        state = stillState(dt, now)
    end
    if state == "dead" or state == "taxi" or state == "combat" or state == "town" then
        resetStreaks()
    end

    if state == "combat" and solo and not inInstance then
        T.Add("combatSolo", dt)
    end
    if inInstance then
        T.Add("instanceSecs", dt)
    end
    if state == "town" and st.townWindow then
        T.Add("town_" .. st.townWindow, dt)
    end

    -- Hearthstone: note when it is used and how long it has been sitting ready.
    local ready = A.HearthReady()
    if ready ~= nil then
        if st.hearthReady == true and ready == false then
            T.Add("hearthUsed", 1)
            st.tripSecs = 0
        end
        st.hearthReady = ready
        if ready and st.hasHearth == true then
            session.hearthReadySecs = (session.hearthReadySecs or 0) + dt
        else
            session.hearthReadySecs = 0
        end
    end

    -- A walk home: movement with no fighting or XP in between that ends in the
    -- town the Hearthstone is bound to, while the stone was ready the whole way.
    -- (The bind location is the town's name, not the inn's, so arriving in the
    -- town is the signal; inside the inn the subzone has a different name.)
    if state == "travel" or state == "move" or state == "taxi" then
        if st.tripSecs == 0 then
            st.tripHearthReady = st.hearthReady == true
        end
        st.tripSecs = st.tripSecs + dt
    end
    local atBind = A.AtBindLocation()
    if atBind and st.wasAtBind == false then
        if st.tripSecs >= D.TRIP_MIN_SECONDS and st.tripHearthReady and st.hearthReady == true
            and st.hasHearth == true then
            T.Add("hearthMissed", 1)
            T.Add("hearthMissedSecs",
                max(0, min(st.tripSecs, D.HEARTH_TRIP_CAP_SECONDS) - D.HEARTH_CAST_SECONDS))
        end
        st.tripSecs = 0
    end
    st.wasAtBind = atBind

    if st.pull and st.pull.endedAt and now - st.pull.endedAt >= PULL_SETTLE_SECONDS then
        finalizePull()
    end

    T.Tick(dt, state)
    st.state = state
end

----------------------------------------------------------------------------
-- Hooks called from Core
----------------------------------------------------------------------------

function Act.MoveEvent(moving)
    if st then
        st.movingEvent = moving and true or false
    end
end

-- After a loading screen the position jumps; that is not movement.
function Act.Teleported()
    if st then
        st.posX = nil
    end
end

function Act.TownWindow(window)
    if st then
        st.townWindow = window
    end
end

function Act.State()
    return st and st.state or nil
end

function Act.MovementSource()
    return st and st.moveSource or "none"
end

function Act.Reset()
    st = fresh()
    st.inCombat = A.CombatFlag()
    st.wasAtBind = A.AtBindLocation()
    if T.Session() then
        poll()
        st.sincePoll = 0
    end
end
