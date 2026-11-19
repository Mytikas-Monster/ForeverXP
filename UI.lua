-- ForeverXP / UI.lua
-- The window: grade letter, XP per hour, hours to the level cap, level progress
-- and the five largest time losses. Hover the top half for the full breakdown,
-- hover a row for what was measured and what to do about it.

local _, ns = ...
local D, F, Core = ns.Data, ns.Factors, ns.Core

local UI = {}
ns.UI = UI

local floor, max, min = math.floor, math.max, math.min
local format = string.format

local WIDTH, HEIGHT = 270, 236
local MIN_W, MIN_H, MAX_W, MAX_H = 240, 236, 520, 420
local ROWS, ROW_HEIGHT = 5, 19
local WHITE = "Interface\\Buttons\\WHITE8X8"

local window, gradeText, rateText, subText, etaText
local barFill, barText, headerText, grip
local rows = {}
local hover          -- nil, "summary" or a row frame
local last           -- last snapshot

local function colour(r, g, b, text)
    return format("|cff%02x%02x%02x%s|r", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5), text)
end

-- Green through yellow to red as the loss grows.
local function severityColour(minutes)
    local s = F.Severity(minutes)
    if s < 0.5 then
        return 0.45 + s * 1.1, 0.85, 0.30
    end
    return 1.0, 0.85 - (s - 0.5) * 1.3, 0.25
end

local function db()
    return Core.db or {}
end

----------------------------------------------------------------------------
-- Tooltips
----------------------------------------------------------------------------

local function anchorTooltip()
    local tip = _G.GameTooltip
    tip:SetOwner(window, "ANCHOR_NONE")
    tip:ClearAllPoints()
    local centre = window:GetCenter()
    local screen = _G.UIParent:GetWidth() or 0
    local scale = window:GetEffectiveScale() / _G.UIParent:GetEffectiveScale()
    if centre and centre * scale > screen / 2 then
        tip:SetPoint("TOPRIGHT", window, "TOPLEFT", -4, 0)
    else
        tip:SetPoint("TOPLEFT", window, "TOPRIGHT", 4, 0)
    end
    return tip
end

local function shares(sums, fields)
    local parts = {}
    local total = 0
    for _, f in ipairs(fields) do
        total = total + max(0, sums[f[1]] or 0)
    end
    if total <= 0 then
        return nil
    end
    for _, f in ipairs(fields) do
        local pct = Core.Percent(max(0, sums[f[1]] or 0), total)
        if pct >= 1 then
            parts[#parts + 1] = format("%s %d%%", f[2], pct)
        end
    end
    return table.concat(parts, " · ")
end

local TIME_FIELDS = {
    { "t_combat", "combat" }, { "t_travel", "travel" }, { "t_move", "moving" }, { "t_taxi", "flying" },
    { "t_town", "town" }, { "t_downtime", "recovery" }, { "t_pause", "stops" }, { "t_idle", "idle" },
    { "t_dead", "dead" },
}
local XP_FIELDS = { { "xpKill", "kills" }, { "xpQuest", "quests" }, { "xpOther", "other" } }

local function showSummary()
    local s = last
    if not s then
        return
    end
    local tip = anchorTooltip()
    tip:AddLine("ForeverXP " .. Core.VERSION, 0.2, 0.8, 1)
    tip:AddDoubleLine("Session", F.Duration(s.elapsed), 1, 1, 1, 1, 1, 1)
    tip:AddDoubleLine("XP/hour, last 60 min", D.Comma(s.rate), 1, 1, 1, 1, 1, 1)
    tip:AddDoubleLine("XP/hour, whole session", D.Comma(s.sessionRate), 1, 1, 1, 1, 1, 1)
    tip:AddDoubleLine(format("Par for a level %d %s", s.level, s.class and s.class:lower() or "character"),
        D.Comma(s.baseline), 1, 1, 1, 1, 1, 1)
    if s.ready then
        tip:AddDoubleLine("Your pace", format("%d%% of par = %s", floor(s.ratio * 100 + 0.5), s.grade.letter),
            1, 1, 1, s.grade.r, s.grade.g, s.grade.b)
        if s.nextGrade then
            tip:AddDoubleLine("Grade " .. s.nextGrade.letter .. " starts at",
                D.Comma(s.nextGrade.min * s.baseline) .. " XP/h", 1, 1, 1, 0.8, 0.8, 0.8)
        end
    else
        tip:AddLine(format("Grade after %s more of play.", F.Duration(s.waitSeconds)), 0.8, 0.8, 0.8)
    end
    if not s.capped then
        tip:AddLine(" ")
        tip:AddLine(format("Hours to level %d", D.MAX_LEVEL), 1, 0.82, 0)
        if s.eta then
            tip:AddDoubleLine("At your pace", D.FormatHours(s.eta), 1, 1, 1, 1, 1, 1)
        end
        tip:AddDoubleLine("At par (grade C)", D.FormatHours(s.etaPar), 1, 1, 1, 0.8, 0.8, 0.8)
        tip:AddDoubleLine("At grade A", D.FormatHours(s.etaA), 1, 1, 1, 0.8, 0.8, 0.8)
        if s.etaFlat then
            tip:AddDoubleLine("If XP/hour never grew", D.FormatHours(s.etaFlat), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
        end
    end
    local w = s.window
    local xpLine, timeLine = shares(w, XP_FIELDS), shares(w, TIME_FIELDS)
    if xpLine or timeLine then
        tip:AddLine(" ")
        tip:AddLine("Last 60 minutes", 1, 0.82, 0)
        if xpLine then
            tip:AddLine("XP: " .. xpLine, 1, 1, 1, true)
        end
        if timeLine then
            tip:AddLine("Time: " .. timeLine, 1, 1, 1, true)
        end
        tip:AddLine(format("Kills %d · quests %d · deaths %d",
            w.kills or 0, w.questTurnins or 0, w.deaths or 0), 1, 1, 1)
    end
    tip:AddLine(" ")
    tip:AddLine("Par is a community estimate of average leveling pace, not a measured benchmark.",
        0.6, 0.6, 0.6, true)
    tip:AddLine("Drag to move, corner to resize. /fxp help", 0.6, 0.6, 0.6, true)
    tip:Show()
end

local function showFactor(row)
    local f = row.factor
    if not f then
        return
    end
    local tip = anchorTooltip()
    local r, g, b = severityColour(f.minutes)
    tip:AddLine(f.name, 1, 0.82, 0)
    tip:AddLine(format("%s%.0f min lost per hour%s", f.estimate and "about " or "", f.minutes,
        f.estimate and " (estimate)" or ""), r, g, b)
    if f.detail then
        tip:AddLine(f.detail, 1, 1, 1, true)
    end
    if f.advice then
        tip:AddLine(" ")
        tip:AddLine(f.advice, 0.6, 0.9, 0.6, true)
    end
    tip:Show()
end

local function refreshTooltip()
    if hover == "summary" then
        showSummary()
    elseif hover then
        showFactor(hover)
    end
end

local function hideTooltip()
    hover = nil
    _G.GameTooltip:Hide()
end

----------------------------------------------------------------------------
-- Position, size, lock
----------------------------------------------------------------------------

local function savePosition()
    local point, _, relativePoint, x, y = window:GetPoint(1)
    if point then
        db().position = { point = point, relativePoint = relativePoint, x = x, y = y }
    end
    db().width, db().height = window:GetWidth(), window:GetHeight()
end

local function startMoving()
    if not db().locked then
        window:StartMoving()
    end
end

local function stopMoving()
    window:StopMovingOrSizing()
    savePosition()
end

function UI.ApplyLock()
    if grip then
        if db().locked then
            grip:Hide()
        else
            grip:Show()
        end
    end
end

function UI.ApplyScale()
    if window then
        window:SetScale(max(0.5, min(2, tonumber(db().scale) or 1)))
    end
end

function UI.Show(show)
    if not window then
        return
    end
    db().hidden = not show
    if show then
        window:Show()
        UI.Refresh()
    else
        window:Hide()
    end
end

function UI.Toggle()
    if window then
        UI.Show(not window:IsShown())
    end
end

----------------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------------

local function fontString(parent, template, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", template)
    fs:SetJustifyH(justify or "LEFT")
    if fs.SetWordWrap then
        fs:SetWordWrap(false)
    end
    return fs
end

local function createRow(index)
    local row = _G.CreateFrame("Frame", nil, window)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", window, "TOPLEFT", 10, -112 - (index - 1) * (ROW_HEIGHT + 2))
    row:SetPoint("RIGHT", window, "RIGHT", -10, 0)
    row:EnableMouse(true)
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", startMoving)
    row:SetScript("OnDragStop", stopMoving)
    row:SetScript("OnEnter", function(self)
        hover = self
        showFactor(self)
    end)
    row:SetScript("OnLeave", hideTooltip)

    local back = row:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints(row)
    back:SetColorTexture(1, 1, 1, 0.05)

    local bar = row:CreateTexture(nil, "BORDER")
    bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    bar:SetWidth(1)
    bar:SetColorTexture(1, 1, 1, 0.25)
    row.bar = bar

    local value = fontString(row, "GameFontHighlightSmall", "RIGHT")
    value:SetPoint("RIGHT", row, "RIGHT", -5, 0)
    value:SetWidth(74)
    row.value = value

    local name = fontString(row, "GameFontHighlightSmall", "LEFT")
    name:SetPoint("LEFT", row, "LEFT", 5, 0)
    name:SetPoint("RIGHT", value, "LEFT", -4, 0)
    row.name = name

    return row
end

function UI.Create()
    if window then
        return
    end
    local saved = db()
    window = _G.CreateFrame("Frame", "ForeverXPWindow", _G.UIParent,
        _G.BackdropTemplateMixin and "BackdropTemplate" or nil)
    UI.window = window
    window:SetWidth(max(MIN_W, min(MAX_W, tonumber(saved.width) or WIDTH)))
    window:SetHeight(max(MIN_H, min(MAX_H, tonumber(saved.height) or HEIGHT)))
    window:SetFrameStrata("MEDIUM")
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:SetResizable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    if window.SetResizeBounds then
        window:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    else
        if window.SetMinResize then
            window:SetMinResize(MIN_W, MIN_H)
        end
        if window.SetMaxResize then
            window:SetMaxResize(MAX_W, MAX_H)
        end
    end
    if window.SetBackdrop then
        window:SetBackdrop({
            bgFile = WHITE,
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        window:SetBackdropColor(0.04, 0.05, 0.08, 0.92)
        window:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
    end

    local p = saved.position
    window:ClearAllPoints()
    if type(p) == "table" and p.point then
        window:SetPoint(p.point, _G.UIParent, p.relativePoint or p.point, tonumber(p.x) or 0, tonumber(p.y) or 0)
    else
        window:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 0)
    end

    window:SetScript("OnDragStart", startMoving)
    window:SetScript("OnDragStop", stopMoving)
    window:SetScript("OnEnter", function()
        hover = "summary"
        showSummary()
    end)
    window:SetScript("OnLeave", hideTooltip)

    -- Grade letter.
    gradeText = window:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    gradeText:SetPoint("TOPLEFT", window, "TOPLEFT", 10, -10)
    gradeText:SetWidth(56)
    gradeText:SetHeight(54)
    gradeText:SetJustifyH("CENTER")
    local fontFile = _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    if not pcall(gradeText.SetFont, gradeText, fontFile, 46, "OUTLINE") then
        gradeText:SetFontObject(_G.GameFontNormalHuge)
    end

    rateText = fontString(window, "GameFontNormalLarge")
    rateText:SetPoint("TOPLEFT", window, "TOPLEFT", 72, -12)
    rateText:SetPoint("RIGHT", window, "RIGHT", -10, 0)
    rateText:SetTextColor(1, 1, 1)

    subText = fontString(window, "GameFontHighlightSmall")
    subText:SetPoint("TOPLEFT", rateText, "BOTTOMLEFT", 0, -3)
    subText:SetPoint("RIGHT", window, "RIGHT", -10, 0)
    subText:SetTextColor(0.75, 0.75, 0.75)

    etaText = fontString(window, "GameFontNormal")
    etaText:SetPoint("TOPLEFT", subText, "BOTTOMLEFT", 0, -4)
    etaText:SetPoint("RIGHT", window, "RIGHT", -10, 0)

    -- Level progress bar.
    local barBack = window:CreateTexture(nil, "ARTWORK")
    barBack:SetPoint("TOPLEFT", window, "TOPLEFT", 10, -72)
    barBack:SetPoint("RIGHT", window, "RIGHT", -10, 0)
    barBack:SetHeight(14)
    barBack:SetColorTexture(1, 1, 1, 0.08)
    UI.barBack = barBack

    barFill = window:CreateTexture(nil, "ARTWORK", nil, 1)
    barFill:SetPoint("TOPLEFT", barBack, "TOPLEFT", 0, 0)
    barFill:SetPoint("BOTTOMLEFT", barBack, "BOTTOMLEFT", 0, 0)
    barFill:SetWidth(1)
    barFill:SetColorTexture(0.45, 0.25, 0.75, 0.9)

    barText = fontString(window, "GameFontHighlightSmall", "CENTER")
    barText:SetPoint("LEFT", barBack, "LEFT", 4, 0)
    barText:SetPoint("RIGHT", barBack, "RIGHT", -4, 0)

    headerText = fontString(window, "GameFontNormalSmall")
    headerText:SetPoint("TOPLEFT", window, "TOPLEFT", 10, -94)
    headerText:SetPoint("RIGHT", window, "RIGHT", -10, 0)

    for i = 1, ROWS do
        rows[i] = createRow(i)
    end

    grip = _G.CreateFrame("Button", nil, window)
    grip:SetWidth(16)
    grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -3, 3)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        if not db().locked then
            window:StartSizing("BOTTOMRIGHT")
        end
    end)
    grip:SetScript("OnMouseUp", function()
        window:StopMovingOrSizing()
        savePosition()
        UI.Refresh()
    end)
    window:SetScript("OnSizeChanged", function()
        if last then
            UI.Render(last)
        end
    end)

    UI.ApplyScale()
    UI.ApplyLock()
    if saved.hidden then
        window:Hide()
    else
        window:Show()
    end
    UI.Refresh()
end

----------------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------------

function UI.Render(s)
    last = s
    -- Grade and headline.
    if s.ready then
        gradeText:SetText(s.grade.letter)
        gradeText:SetTextColor(s.grade.r, s.grade.g, s.grade.b)
        subText:SetText(format("%d%% of par · session %s", floor(s.ratio * 100 + 0.5), D.Comma(s.sessionRate)))
    else
        gradeText:SetText("-")
        gradeText:SetTextColor(0.5, 0.5, 0.5)
        subText:SetText(format("grade in %s", F.Duration(s.waitSeconds)))
    end
    rateText:SetText(D.Comma(s.rate) .. " XP/h")

    if s.capped then
        etaText:SetText(format("Level %d reached", D.MAX_LEVEL))
    elseif s.eta then
        etaText:SetText(format("~%s to level %d", D.FormatHours(s.eta), D.MAX_LEVEL))
    else
        etaText:SetText(format("~%s to %d at par", D.FormatHours(s.etaPar), D.MAX_LEVEL))
    end

    -- Level progress.
    local fraction = 0
    if s.xpMax and s.xpMax > 0 then
        fraction = max(0, min(1, s.xp / s.xpMax))
    end
    local barWidth = (UI.barBack:GetWidth() or 0)
    barFill:SetWidth(max(1, barWidth * fraction))
    if s.capped then
        barText:SetText(format("Level %d", s.level))
    else
        barText:SetText(format("Level %d · %d%% · %s to go", s.level, floor(fraction * 100 + 0.5),
            D.Comma(max(0, s.xpMax - s.xp))))
    end

    -- Factors.
    local factors = s.factors or {}
    if not s.ready then
        headerText:SetText("Collecting data...")
    elseif #factors == 0 then
        headerText:SetText("Nothing significant is slowing you down")
    else
        headerText:SetText("Top time losses, last 60 min")
    end
    local rowWidth = rows[1]:GetWidth() or 0
    local scaleTo = max(12, factors[1] and factors[1].minutes or 0)
    for i = 1, ROWS do
        local row, f = rows[i], factors[i]
        row.factor = f
        if f then
            local r, g, b = severityColour(f.minutes)
            row.name:SetText(f.name)
            row.value:SetText(colour(r, g, b, format("%s%.0f min/h", f.estimate and "~" or "", f.minutes)))
            row.bar:SetColorTexture(r, g, b, 0.28)
            row.bar:SetWidth(max(1, rowWidth * min(1, f.minutes / scaleTo)))
            row:Show()
        else
            row:Hide()
        end
    end
    if hover and hover ~= "summary" and not hover.factor then
        hideTooltip()
    end
    refreshTooltip()
end

function UI.Refresh()
    if not window or not window:IsShown() then
        return
    end
    UI.Render(Core.Snapshot())
end
