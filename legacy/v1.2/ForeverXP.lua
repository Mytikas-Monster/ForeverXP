-- ForeverXP 1.2: Vanilla/Forever-compatible, session-based XP monitoring.
local addon = CreateFrame("Frame")
local window = CreateFrame("Frame", "ForeverXPWindow", UIParent)
window:SetWidth(330)
window:SetHeight(208)
window:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
window:SetMovable(true)
window:SetResizable(true)
window:EnableMouse(true)
window:RegisterForDrag("LeftButton")
if window.SetMinResize then window:SetMinResize(270, 185) end
if window.SetMaxResize then window:SetMaxResize(620, 390) end
if window.SetBackdrop then
  window:SetBackdrop({bgFile="Interface\\Tooltips\\UI-Tooltip-Background", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=12, insets={left=3,right=3,top=3,bottom=3}})
  window:SetBackdropColor(0.04, 0.05, 0.08, 0.94)
end
local title = window:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
title:SetPoint("TOP",window,"TOP",0,-12)
title:SetText("ForeverXP 1.2")
local lines={}
for i=1,7 do
  local line=window:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
  line:SetPoint("TOPLEFT",window,"TOPLEFT",14,-34-(i-1)*22)
  line:SetWidth(300)
  line:SetJustifyH("LEFT")
  lines[i]=line
end
local grip=CreateFrame("Button",nil,window)
grip:SetWidth(18); grip:SetHeight(18)
grip:SetPoint("BOTTOMRIGHT",window,"BOTTOMRIGHT",-4,4)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:EnableMouse(true)
grip:SetScript("OnMouseDown",function() window:StartSizing("BOTTOMRIGHT") end)
grip:SetScript("OnMouseUp",function()
  window:StopMovingOrSizing()
  ForeverXPDB=ForeverXPDB or {}
  ForeverXPDB.width,ForeverXPDB.height=window:GetWidth(),window:GetHeight()
end)
window:SetScript("OnDragStart",function(self) self:StartMoving() end)
window:SetScript("OnDragStop",function(self)
  self:StopMovingOrSizing()
  ForeverXPDB=ForeverXPDB or {}
  local point,_,relativePoint,x,y=self:GetPoint()
  ForeverXPDB.position={point=point,relativePoint=relativePoint,x=x,y=y}
end)
window:SetScript("OnSizeChanged",function(self,w)
  for _,line in ipairs(lines) do line:SetWidth(math.max(240,w-28)) end
end)

local grades={
  {10,10000,7000,5000},{20,22000,16000,11000},
  {30,35000,26000,18000},{40,48000,36000,26000},
  {50,65000,48000,35000},{60,85000,65000,48000}
}
local function grade(xpHour,level)
  local b=grades[6]
  for _,v in ipairs(grades) do if level<=v[1] then b=v;break end end
  if xpHour>=b[2] then return "S" end
  if xpHour>=b[3] then return "A" end
  if xpHour>=b[4] then return "B" end
  if xpHour>=b[4]*0.75 then return "C" end
  if xpHour>=b[4]*0.5 then return "D" end
  if xpHour>=b[4]*0.25 then return "E" end
  return "F"
end
local start,earned,kills,deaths=0,0,0,0
local previousXP,previousMax,previousLevel=0,0,0
local lastGain=0
local noXP,travel,stationary=0,0,0
local function reset()
  start=GetTime()
  earned,kills,deaths,noXP,travel,stationary=0,0,0,0,0,0
  previousXP=UnitXP("player") or 0
  previousMax=UnitXPMax("player") or 0
  previousLevel=UnitLevel("player") or 1
  lastGain=GetTime()
end
local function sampleXP()
  local xp=UnitXP("player") or 0
  local cap=UnitXPMax("player") or 0
  local level=UnitLevel("player") or previousLevel
  local delta=0
  if level>previousLevel then
    -- If several levels are gained in a single event, intermediate level caps
    -- are not available; this handles ordinary single-level progression.
    delta=math.max(0,previousMax-previousXP)+xp
  elseif level==previousLevel and xp>=previousXP then
    delta=xp-previousXP
  end
  if delta>0 then earned=earned+delta;lastGain=GetTime() end
  previousXP,previousMax,previousLevel=xp,cap,level
end
local function update()
  local seconds=math.max(1,GetTime()-start)
  local rate=earned*3600/seconds
  lines[1]:SetText(string.format("XP/hour: %.0f   Grade: %s",rate,grade(rate,UnitLevel("player") or 1)))
  lines[2]:SetText(string.format("XP gained: %d   Session: %.1f min",earned,seconds/60))
  lines[3]:SetText(string.format("Kills: %d   Deaths: %d",kills,deaths))
  lines[4]:SetText("Top 3 measured time signals:")
  local signals={
    {"No-XP time (overlapping)",noXP},
    {"Out-of-combat travel",travel},
    {"Stationary out of combat",stationary}
  }
  table.sort(signals,function(a,b) return a[2]>b[2] end)
  for i=1,3 do
    lines[i+4]:SetText(string.format("%d. %s: %.0f sec",i,signals[i][1],signals[i][2]))
  end
end
addon:RegisterEvent("PLAYER_LOGIN")
addon:RegisterEvent("PLAYER_XP_UPDATE")
addon:RegisterEvent("PLAYER_LEVEL_UP")
addon:RegisterEvent("PLAYER_DEAD")
addon:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
addon:SetScript("OnEvent",function(self,event,...)
  if event=="PLAYER_LOGIN" then
    ForeverXPDB=ForeverXPDB or {}
    reset()
    if ForeverXPDB.width and ForeverXPDB.height then
      window:SetWidth(ForeverXPDB.width);window:SetHeight(ForeverXPDB.height)
    end
    if ForeverXPDB.position then
      local p=ForeverXPDB.position
      window:ClearAllPoints()
      window:SetPoint(p.point or "CENTER",UIParent,p.relativePoint or "CENTER",p.x or 0,p.y or 0)
    end
    if ForeverXPDB.hidden then window:Hide() end
  elseif event=="PLAYER_XP_UPDATE" or event=="PLAYER_LEVEL_UP" then
    sampleXP()
  elseif event=="PLAYER_DEAD" then
    deaths=deaths+1
  elseif event=="COMBAT_LOG_EVENT_UNFILTERED" then
    if CombatLogGetCurrentEventInfo then
      local _,kind,_,sourceGUID=CombatLogGetCurrentEventInfo()
      if kind=="PARTY_KILL" and sourceGUID==UnitGUID("player") then kills=kills+1 end
    end
  end
  if start>0 then update() end
end)
local ticker=0
addon:SetScript("OnUpdate",function(self,dt)
  if start==0 then return end
  ticker=ticker+dt
  if ticker<1 then return end
  local step=ticker;ticker=0
  if GetTime()-lastGain>=30 then noXP=noXP+step end
  if not UnitAffectingCombat("player") then
    if GetUnitSpeed and GetUnitSpeed("player")>0 then travel=travel+step
    else stationary=stationary+step end
  end
  update()
end)
SLASH_FOREVERXP1="/fxp"
SlashCmdList["FOREVERXP"]=function(message)
  message=string.lower(message or "")
  ForeverXPDB=ForeverXPDB or {}
  if message=="reset" then reset();update();print("ForeverXP: session reset")
  elseif message=="hide" then window:Hide();ForeverXPDB.hidden=true
  else window:Show();ForeverXPDB.hidden=false end
end
