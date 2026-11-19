-- Test runner. From the addon folder:  lua tests/run.lua
-- Needs Lua 5.1 (the version the game embeds).

local passed, failed = 0, {}

local T = {}

function T.ok(cond, msg)
    if not cond then
        error(msg or "expected a true value", 2)
    end
end

function T.eq(actual, expected, msg)
    if actual ~= expected then
        error((msg and msg .. ": " or "") .. "expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

function T.near(actual, expected, tolerance, msg)
    if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
        error((msg and msg .. ": " or "") .. "expected " .. tostring(expected) .. " +/- " .. tostring(tolerance)
            .. ", got " .. tostring(actual), 2)
    end
end

function T.test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
    else
        failed[#failed + 1] = name .. "\n    " .. tostring(err):gsub("\n", "\n    ")
    end
end

-- Load the pure-logic files (no game API) into a fresh namespace.
function T.pure()
    local ns = {}
    for _, file in ipairs({ "Data.lua", "Tracker.lua", "Factors.lua" }) do
        assert(loadfile(file))("ForeverXP", ns)
    end
    return ns
end

for _, file in ipairs({ "tests/test_data.lua", "tests/test_tracker.lua", "tests/test_factors.lua", "tests/test_addon.lua" }) do
    assert(loadfile(file))(T)
end

print(string.format("%d passed, %d failed", passed, #failed))
for _, f in ipairs(failed) do
    print("FAIL " .. f)
end
os.exit(#failed == 0 and 0 or 1)
