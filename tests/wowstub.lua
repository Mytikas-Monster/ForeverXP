-- Minimal fake of the parts of the WoW client that ForeverXP touches, so the
-- whole addon can be loaded and driven outside the game.
--
--   local world = require("tests.wowstub").install()
--   world.load()                 -- load the addon files in TOC order
--   world.fire("PLAYER_LOGIN")
--   world.advance(60)            -- one simulated minute, one OnUpdate per second

local M = {}

local SECRET = setmetatable({}, {
    __tostring = function() return "<secret>" end,
    __eq = function() error("compared a secret value") end,
    __lt = function() error("compared a secret value") end,
    __le = function() error("compared a secret value") end,
    __add = function() error("arithmetic on a secret value") end,
    __sub = function() error("arithmetic on a secret value") end,
    __mul = function() error("arithmetic on a secret value") end,
    __div = function() error("arithmetic on a secret value") end,
    __index = function() error("indexed a secret value") end,
})
M.SECRET = SECRET

local KNOWN_EVENTS = {
    ADDON_LOADED = true, PLAYER_LOGIN = true, PLAYER_ENTERING_WORLD = true, PLAYER_XP_UPDATE = true,
    PLAYER_LEVEL_UP = true, QUEST_TURNED_IN = true, PLAYER_REGEN_DISABLED = true, PLAYER_REGEN_ENABLED = true,
    PLAYER_DEAD = true, PLAYER_STARTED_MOVING = true, PLAYER_STOPPED_MOVING = true, PLAYER_LOGOUT = true,
    MERCHANT_SHOW = true, MERCHANT_CLOSED = true, TRAINER_SHOW = true, TRAINER_CLOSED = true,
    AUCTION_HOUSE_SHOW = true, AUCTION_HOUSE_CLOSED = true, MAIL_SHOW = true, MAIL_CLOSED = true,
    BANKFRAME_OPENED = true, BANKFRAME_CLOSED = true,
}

local XP_TO_NEXT = {
    400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600,
    8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,
    25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
    50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700,
    95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500,
    153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800,
}

function M.install(options)
    options = options or {}
    local world = {
        now = 1000, epoch = 1700000000,
        level = options.level or 20, xp = 0, class = options.class or "WARRIOR",
        rested = 0,
        combat = false, dead = false, taxi = false, resting = false, afk = false,
        speed = 0, x = 0, y = 0, map = 0,
        group = false, partyLevels = {},
        instance = false, instanceName = nil,
        hearthStart = 0, hearthDuration = 0, hearthCount = 1,
        bind = "Goldshire", subzone = "Elwynn Forest",
        bagsFree = 20, offhand = 1201, questLevels = {},
        chat = {}, frames = {}, secret = {}, missing = options.missing or {},
        saved = options.saved or {},
    }

    local function widget(kind)
        local w = { kind = kind, scripts = {}, events = {}, shown = true, width = 0, height = 0, children = {} }
        local methods = {}
        function methods:SetScript(name, fn) self.scripts[name] = fn end
        function methods:GetScript(name) return self.scripts[name] end
        function methods:RegisterEvent(event)
            if not KNOWN_EVENTS[event] then
                error("Attempt to register unknown event \"" .. tostring(event) .. "\"")
            end
            self.events[event] = true
        end
        function methods:UnregisterEvent(event) self.events[event] = nil end
        function methods:CreateFontString() local c = widget("FontString"); self.children[#self.children + 1] = c; return c end
        function methods:CreateTexture() local c = widget("Texture"); self.children[#self.children + 1] = c; return c end
        function methods:SetWidth(v) assert(type(v) == "number", "SetWidth needs a number"); self.width = v end
        function methods:SetHeight(v) assert(type(v) == "number", "SetHeight needs a number"); self.height = v end
        function methods:SetSize(a, b) self.width, self.height = a, b end
        function methods:GetWidth() return self.width end
        function methods:GetHeight() return self.height end
        function methods:Show() self.shown = true end
        function methods:Hide() self.shown = false end
        function methods:IsShown() return self.shown end
        function methods:SetText(t) assert(t == nil or type(t) == "string" or type(t) == "number", "SetText needs text"); self.text = t end
        function methods:GetText() return self.text end
        function methods:SetPoint(...) self.point = { ... } end
        function methods:GetPoint() local p = self.point or { "CENTER", nil, "CENTER", 0, 0 }; return p[1], p[2], p[3], p[4], p[5] end
        function methods:ClearAllPoints() self.point = nil end
        function methods:GetCenter() return 100, 100 end
        function methods:GetEffectiveScale() return 1 end
        function methods:SetFont() return true end
        function methods:AddLine(text) assert(type(text) == "string", "AddLine needs text"); self.lines = self.lines or {}; self.lines[#self.lines + 1] = text end
        function methods:AddDoubleLine(a, b)
            assert(type(a) == "string" and type(b) == "string", "AddDoubleLine needs two strings")
            self.lines = self.lines or {}; self.lines[#self.lines + 1] = a .. " | " .. b
        end
        function methods:SetOwner() self.lines = {} end
        function methods:AddMessage(msg) world.chat[#world.chat + 1] = msg end
        return setmetatable(w, { __index = function(_, key)
            local m = methods[key]
            if m then return m end
            -- Any other widget method is accepted and does nothing.
            if type(key) == "string" and key:match("^%u") then
                return function() end
            end
            return nil
        end })
    end

    local function api(name, fn)
        if world.missing[name] then
            return nil
        end
        return function(...)
            if world.secret[name] then
                return SECRET
            end
            return fn(...)
        end
    end

    local G = _G
    G.issecretvalue = function(v) return rawequal(v, SECRET) end
    G.CreateFrame = function(kind, name)
        local f = widget(kind or "Frame")
        f.name = name
        world.frames[#world.frames + 1] = f
        if name then G[name] = f end
        return f
    end
    G.UIParent = widget("Frame"); G.UIParent.width = 1920
    G.GameTooltip = widget("GameTooltip")
    G.DEFAULT_CHAT_FRAME = widget("ChatFrame")
    G.BackdropTemplateMixin = {}
    G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
    G.GameFontNormalHuge = {}
    G.SlashCmdList = {}
    G.GetTime = function() return world.now end
    G.time = function() return world.epoch end
    G.date = function() return "2026-11-10 12:00:00" end
    G.debugstack = function() return "stack" end
    G.GetBuildInfo = function() return "1.60.1", "70500", "Nov 4 2026", 16001 end
    G.UnitXP = api("UnitXP", function() return world.xp end)
    G.UnitXPMax = api("UnitXPMax", function() return XP_TO_NEXT[world.level] or 0 end)
    G.UnitLevel = api("UnitLevel", function(unit)
        if unit == "player" then return world.level end
        local i = tonumber((unit or ""):match("^party(%d)$"))
        return i and world.partyLevels[i] or 0
    end)
    G.UnitClassBase = api("UnitClassBase", function() return world.class, 1 end)
    G.UnitClass = api("UnitClass", function() return "Warrior", world.class, 1 end)
    G.GetXPExhaustion = api("GetXPExhaustion", function() return world.rested > 0 and world.rested or nil end)
    G.UnitAffectingCombat = api("UnitAffectingCombat", function() return world.combat end)
    G.InCombatLockdown = api("InCombatLockdown", function() return world.combat end)
    G.UnitIsDeadOrGhost = api("UnitIsDeadOrGhost", function() return world.dead end)
    G.UnitOnTaxi = api("UnitOnTaxi", function() return world.taxi end)
    G.IsResting = api("IsResting", function() return world.resting end)
    G.UnitIsAFK = api("UnitIsAFK", function() return world.afk end)
    G.GetUnitSpeed = api("GetUnitSpeed", function() return world.speed end)
    G.UnitPosition = api("UnitPosition", function()
        if world.instance then return nil end
        return world.y, world.x, 0, world.map
    end)
    G.IsInGroup = api("IsInGroup", function() return world.group end)
    G.IsInInstance = api("IsInInstance", function()
        if world.instance then return true, "party" end
        return false, "none"
    end)
    G.GetInstanceInfo = api("GetInstanceInfo", function() return world.instanceName or "Eastern Kingdoms", "none" end)
    G.GetBindLocation = api("GetBindLocation", function() return world.bind end)
    G.GetSubZoneText = api("GetSubZoneText", function() return world.subzone end)
    G.GetMinimapZoneText = api("GetMinimapZoneText", function() return world.subzone end)
    G.GetZoneText = api("GetZoneText", function() return "Elwynn Forest" end)
    G.GetRealZoneText = api("GetRealZoneText", function() return "Elwynn Forest" end)
    G.GetInventoryItemID = api("GetInventoryItemID", function(_, slot) if slot == 17 then return world.offhand end end)
    G.C_Container = {
        GetItemCooldown = api("C_Container.GetItemCooldown", function() return world.hearthStart, world.hearthDuration, 1 end),
        GetContainerNumFreeSlots = api("C_Container.GetContainerNumFreeSlots", function(bag)
            return bag == 0 and world.bagsFree or 0
        end),
    }
    G.C_Item = {
        GetItemCount = api("C_Item.GetItemCount", function() return world.hearthCount end),
        GetItemInfoInstant = api("C_Item.GetItemInfoInstant", function(id)
            return id, "Armor", "Shields", id == 1201 and "INVTYPE_SHIELD" or "INVTYPE_WEAPON", 1, 4, 6
        end),
    }
    G.C_QuestLog = {
        GetNumQuestLogEntries = api("C_QuestLog.GetNumQuestLogEntries", function() return #world.questLevels + 1 end),
        GetInfo = api("C_QuestLog.GetInfo", function(i)
            if i == 1 then return { isHeader = true, title = "Zone" } end
            local level = world.questLevels[i - 1]
            return level and { isHeader = false, level = level, questID = 100 + i } or nil
        end),
    }

    -- Deliver an event to every frame registered for it.
    function world.fire(event, ...)
        for _, f in ipairs(world.frames) do
            if f.events[event] and f.scripts.OnEvent then
                f.scripts.OnEvent(f, event, ...)
            end
        end
    end

    -- Advance the clock one second at a time, running OnUpdate handlers.
    function world.advance(seconds, each)
        for _ = 1, seconds do
            world.now = world.now + 1
            world.epoch = world.epoch + 1
            if world.speed > 0 and not world.instance then
                world.x = world.x + world.speed
            end
            if each then each() end
            for _, f in ipairs(world.frames) do
                if f.scripts.OnUpdate then
                    f.scripts.OnUpdate(f, 1)
                end
            end
        end
    end

    -- Give XP the way the client does: update the bar, then fire the event.
    function world.gainXP(amount)
        world.xp = world.xp + amount
        local levelled
        while world.level < 60 and world.xp >= XP_TO_NEXT[world.level] do
            world.xp = world.xp - XP_TO_NEXT[world.level]
            world.level = world.level + 1
            levelled = true
        end
        if levelled then
            world.fire("PLAYER_LEVEL_UP", world.level)
        end
        world.fire("PLAYER_XP_UPDATE", "player")
    end

    function world.enterCombat() world.combat = true; world.fire("PLAYER_REGEN_DISABLED") end
    function world.leaveCombat() world.combat = false; world.fire("PLAYER_REGEN_ENABLED") end

    -- A fight of `seconds` that ends with `kills` kills worth `xpEach`.
    function world.fight(seconds, kills, xpEach)
        world.speed = 0
        world.enterCombat()
        world.advance(seconds)
        for _ = 1, kills or 1 do
            world.gainXP(xpEach or 0)
        end
        world.leaveCombat()
    end

    function world.turnIn(xp)
        world.fire("QUEST_TURNED_IN", 12345, xp, 0)
        world.gainXP(xp)
    end

    -- Load the addon files in TOC order with a shared namespace table.
    function world.load(dir)
        dir = dir or "."
        local ns = {}
        G.ForeverXPDB = world.saved.ForeverXPDB
        G.ForeverXPCharDB = world.saved.ForeverXPCharDB
        for line in io.lines(dir .. "/ForeverXP.toc") do
            local file = line:match("^%s*([%w_]+%.lua)%s*$")
            if file then
                local chunk = assert(loadfile(dir .. "/" .. file))
                chunk("ForeverXP", ns)
            end
        end
        world.ns = ns
        world.fire("ADDON_LOADED", "ForeverXP")
        return ns
    end

    function world.login()
        world.fire("PLAYER_LOGIN")
        world.fire("PLAYER_ENTERING_WORLD", true, false)
    end

    -- What the client would write to disk on logout.
    function world.logout()
        world.fire("PLAYER_LOGOUT")
        return { ForeverXPDB = G.ForeverXPDB, ForeverXPCharDB = G.ForeverXPCharDB }
    end

    return world
end

return M
