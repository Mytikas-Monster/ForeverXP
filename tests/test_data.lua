local T = ...
local D = T.pure().Data

T.test("XP curve totals 4,084,700", function()
    local total = 0
    for level = 1, 59 do
        total = total + D.XPToNext(level)
    end
    T.eq(total, 4084700)
    T.eq(D.XPRemaining(1, 0, 400), 4084700)
    T.eq(D.XPRemaining(59, 209000, 209800), 800)
    T.eq(D.XPRemaining(60, 0, 0), 0)
end)

T.test("baseline reproduces the published hours per bracket", function()
    local hours = { 0, 0, 0, 0, 0, 0 }
    for level = 1, 59 do
        local bracket = math.floor(level / 10) + 1
        hours[bracket] = hours[bracket] + D.XPToNext(level) / D.Baseline(level, nil)
    end
    local expected = { 6, 14, 22, 28, 36, 44 }
    for i = 1, 6 do
        T.near(hours[i], expected[i], 0.05, "bracket " .. i)
    end
end)

T.test("hours to cap at par: 150 average, 168 warrior, 138 mage", function()
    T.near(D.HoursToCap(1, 0, 400, 1, nil), 150, 0.2)
    T.near(D.HoursToCap(1, 0, 400, 1, "WARRIOR"), 168, 0.3)
    T.near(D.HoursToCap(1, 0, 400, 1, "MAGE"), 138, 0.3)
    T.eq(D.HoursToCap(60, 0, 0, 1, "WARRIOR"), 0)
    T.eq(D.HoursToCap(30, 0, 47400, 0, "WARRIOR"), nil)
    T.eq(D.HoursToCap(30, 0, 47400, nil, "WARRIOR"), nil)
end)

T.test("hours to cap shrink with a better ratio and with progress", function()
    local slow = D.HoursToCap(30, 0, 47400, 0.8, "WARRIOR")
    local fast = D.HoursToCap(30, 0, 47400, 1.6, "WARRIOR")
    T.near(slow / fast, 2, 0.001)
    T.ok(D.HoursToCap(31, 0, 50800, 1, "WARRIOR") < D.HoursToCap(30, 0, 47400, 1, "WARRIOR"))
    T.ok(D.HoursToCap(30, 40000, 47400, 1, "WARRIOR") < D.HoursToCap(30, 0, 47400, 1, "WARRIOR"))
end)

T.test("flat-rate estimate is much longer than the curve estimate at low level", function()
    local rate = D.Baseline(10, "WARRIOR")
    local flat = D.HoursToCapFlat(10, 0, 7600, rate)
    local curve = D.HoursToCap(10, 0, 7600, 1, "WARRIOR")
    T.ok(flat > curve * 3, "flat " .. flat .. " vs curve " .. curve)
    T.eq(D.HoursToCapFlat(10, 0, 7600, 0), nil)
end)

T.test("grade boundaries", function()
    local cases = {
        { 3.0, "S" }, { 1.75, "S" }, { 1.749, "A" }, { 1.35, "A" }, { 1.349, "B" }, { 1.10, "B" },
        { 1.099, "C" }, { 0.90, "C" }, { 0.899, "D" }, { 0.70, "D" }, { 0.699, "E" }, { 0.45, "E" },
        { 0.449, "F" }, { 0, "F" },
    }
    for _, c in ipairs(cases) do
        T.eq(D.Grade(c[1]).letter, c[2], "ratio " .. c[1])
    end
    local g, index = D.GradeByLetter("A")
    T.eq(g.min, 1.35)
    T.eq(index, 2)
end)

T.test("the one real measurement (level 28) grades sensibly", function()
    local par = D.Baseline(28, "WARRIOR")
    T.near(par, 15547, 30)
    T.eq(D.Grade(18173 / par).letter, "B", "questing only")
    T.eq(D.Grade(26800 / par).letter, "A", "optimal hybrid route")
    T.eq(D.Grade(15780 / par).letter, "C", "solo grind")
end)

T.test("slower classes get a lower bar", function()
    T.ok(D.Baseline(30, "WARRIOR") < D.Baseline(30, "PALADIN"))
    T.ok(D.Baseline(30, "MAGE") > D.Baseline(30, "PALADIN"))
    T.eq(D.Baseline(30, "UNKNOWN"), D.Baseline(30, nil))
    for level = 1, 59 do
        T.ok(D.Baseline(level + 1, nil) > D.Baseline(level, nil), "baseline rises at " .. level)
        T.ok(D.Baseline(level, nil) > 1000)
    end
end)

T.test("grey level thresholds", function()
    T.eq(D.GreyLevel(5), 0)
    T.eq(D.GreyLevel(10), 4)
    T.eq(D.GreyLevel(20), 13)
    T.eq(D.GreyLevel(39), 31)
    T.eq(D.GreyLevel(40), 31)
    T.eq(D.GreyLevel(59), 47)
    T.eq(D.GreyLevel(60), 51)
end)

T.test("number formatting", function()
    T.eq(D.Comma(0), "0")
    T.eq(D.Comma(999), "999")
    T.eq(D.Comma(1000), "1,000")
    T.eq(D.Comma(1234567), "1,234,567")
    T.eq(D.Comma(18449.6), "18,450")
    T.eq(D.Comma(-1234.4), "-1,234")
    T.eq(D.Comma(nil), "0")
    T.eq(D.FormatHours(9.44), "9.4 h")
    T.eq(D.FormatHours(86.6), "87 h")
    T.eq(D.FormatHours(nil), "?")
end)
