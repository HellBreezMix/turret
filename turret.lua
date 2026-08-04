-- ============================================================
--  ECS® Security Systems — Multi-Turret Control v3
--  Отладка наведения + приоритет мобов
-- ============================================================

local component = require("component")
local event     = require("event")
local term      = require("term")
local gpu       = component.gpu
local computer  = require("computer")

-- ===================== НАСТРОЙКИ =====================
local SCAN_RANGE    = 48
local AIM_HEIGHT    = 0.9
local FIRE_COOLDOWN = 0.35
local UPDATE_GUI    = 0.25
local COMBAT_EVERY  = 0.30

-- Смещение турели относительно детектора (блоки)
-- Подгони: встань у детектора и посчитай до ствола турели
local DEFAULT_OFFSET = { x = 0, y = 3, z = 0 }

local TURRET_CONFIG = {
  -- { addr = "fe9adb", x = 0, y = 3, z = 0, name = "Главная" },
}

local C = {
  bg=0x0A0A14, panel=0x141420, border=0x3A3A60, text=0xD8D8F0,
  yellow=0xFFD700, green=0x22DD55, red=0xFF3344, purple=0xAA55FF,
  gray=0x444455, energy=0xFFCC22, energyBg=0x2A2A18, title=0x00FFBB,
  dark=0x000000, cyan=0x22CCFF, orange=0xFF8800,
}

-- ===================== СОСТОЯНИЕ =====================
local turrets, detector = {}, nil
local attackMobs, attackPlayers = true, true
local whitelist = { hellbreez = true }  -- себя не бьём по умолчанию
local running = true
local lastFire, lastCombat, lastDraw = {}, 0, 0
local lastTarget, statusMsg, debugMsg = "—", "", ""
local screenW, screenH = 80, 25
local buttons = {}

-- ===================== УТИЛИТЫ =====================
local function setResolution()
  local maxW, maxH = gpu.maxResolution()
  screenW, screenH = maxW, maxH
  gpu.setResolution(screenW, screenH)
  pcall(function() gpu.setDepth(8) end)
end

local function fill(x,y,w,h,bg,fg,ch)
  gpu.setBackground(bg or C.bg)
  if fg then gpu.setForeground(fg) end
  gpu.fill(x,y,w,h, ch or " ")
end

local function txt(x,y,str,fg,bg)
  if bg then gpu.setBackground(bg) end
  if fg then gpu.setForeground(fg) end
  gpu.set(x,y, tostring(str))
end

local function center(y,str,fg,bg)
  txt(math.floor((screenW - #str)/2)+1, y, str, fg, bg)
end

local function box(x,y,w,h,border,bg)
  fill(x,y,w,h, bg or C.panel)
  gpu.setBackground(border or C.border)
  gpu.fill(x,y,w,1," "); gpu.fill(x,y+h-1,w,1," ")
  gpu.fill(x,y,1,h," "); gpu.fill(x+w-1,y,1,h," ")
end

local function btn(x,y,w,h,label,active,color)
  local bg = active and (color or C.yellow) or C.gray
  local fg = active and C.dark or C.text
  fill(x,y,w,h,bg,fg)
  txt(x + math.floor((w-#label)/2), y + math.floor((h-1)/2), label, fg, bg)
  return {x=x,y=y,w=w,h=h}
end

-- ===================== ТУРЕЛИ =====================
local function getConfigFor(addr)
  for _, cfg in ipairs(TURRET_CONFIG) do
    if cfg.addr and addr:sub(1, #cfg.addr) == cfg.addr then return cfg end
  end
end

local function refreshTurrets()
  local found, newList = {}, {}
  for addr in component.list("os_energyturret") do found[addr] = true end

  for addr in pairs(found) do
    local old
    for _, t in ipairs(turrets) do if t.addr == addr then old = t break end end
    if old then
      pcall(function() old.powered = old.proxy.isPowered() end)
      table.insert(newList, old)
    else
      local p = component.proxy(addr)
      local cfg = getConfigFor(addr)
      local ox = cfg and cfg.x or DEFAULT_OFFSET.x
      local oy = cfg and cfg.y or DEFAULT_OFFSET.y
      local oz = cfg and cfg.z or DEFAULT_OFFSET.z
      local name = cfg and cfg.name or ("T-"..addr:sub(1,6))
      local powered = false
      pcall(function() powered = p.isPowered() end)
      table.insert(newList, {addr=addr, proxy=p, powered=powered, ox=ox, oy=oy, oz=oz, name=name})
      lastFire[addr] = 0
    end
  end
  table.sort(newList, function(a,b) return a.addr < b.addr end)
  turrets = newList
end

local function findDetector()
  local a = component.list("os_entdetector")()
  if a then detector = component.proxy(a) return true end
  return false
end

local function powerTurret(t, on)
  pcall(function()
    if on then
      t.proxy.powerOn()
      os.sleep(0.15)
      pcall(function() t.proxy.extendShaft(2) end)
      os.sleep(0.05)
      t.proxy.setArmed(true)
    else
      t.proxy.setArmed(false)
      t.proxy.powerOff()
    end
  end)
  t.powered = on
end

local function powerAll(on)
  for _, t in ipairs(turrets) do powerTurret(t, on) end
end

-- ===================== ЦЕЛИ =====================
local function isPlayer(ent)
  if not ent then return false end
  if ent.name == "Player" then return true end
  -- ник игрока (не моб)
  if ent.name and not tostring(ent.name):find("%.") and ent.uuid then return true end
  if ent.uuid and #tostring(ent.uuid) > 20 then return true end
  return false
end

local function isItem(name)
  if not name then return true end
  return tostring(name):lower():find("item") ~= nil
end

local function shouldAttack(ent)
  if not ent or not ent.name or isItem(ent.name) then return false end
  local n = tostring(ent.name):lower()
  if whitelist[n] or whitelist[ent.name] then return false end
  if isPlayer(ent) then return attackPlayers end
  return attackMobs
end

local function getEntities()
  if not detector then return {} end
  local list = {}
  pcall(function()
    for _, e in ipairs(detector.scanEntities(SCAN_RANGE) or {}) do
      if e and e.name and not isItem(e.name) then table.insert(list, e) end
    end
    for _, p in ipairs(detector.scanPlayers(SCAN_RANGE) or {}) do
      if p then table.insert(list, p) end
    end
  end)
  return list
end

-- ===================== НАВЕДЕНИЕ =====================
local function aimAndFire(t, ent)
  if not t.powered or not t.proxy then
    debugMsg = "нет proxy/power"
    return false
  end

  local ex, ey, ez = ent.x or 0, ent.y or 0, ent.z or 0
  local dx = ex - t.ox
  local dy = ey - t.oy + AIM_HEIGHT
  local dz = ez - t.oz

  local distXZ = math.sqrt(dx*dx + dz*dz)
  local dist   = math.sqrt(dx*dx + dy*dy + dz*dz)

  if dist < 1.0 then
    debugMsg = "слишком близко "..string.format("%.1f", dist)
    return false
  end
  if dist > SCAN_RANGE + 8 then
    debugMsg = "далеко "..string.format("%.1f", dist)
    return false
  end

  -- Вариант A (стандартный для OpenSecurity)
  local yawA = math.deg(math.atan2(dx, dz))
  if yawA < 0 then yawA = yawA + 360 end
  local pitchA = math.deg(math.atan2(dy, distXZ))
  pitchA = math.max(-45, math.min(90, pitchA))

  -- Вариант B (как на форумах)
  local yawB = math.deg(math.atan2(-dx, dz))
  if yawB < 0 then yawB = yawB + 360 end

  local yaw, pitch = yawA, pitchA

  -- двигаем
  local moved = pcall(function() t.proxy.moveTo(yaw, pitch) end)
  if not moved then
    pcall(function() t.proxy.moveToRadians(math.rad(yaw), math.rad(pitch)) end)
  end

  -- короткая пауза на поворот
  os.sleep(0.12)

  local ready, onTarget, shaft = false, false, 0
  pcall(function() ready = t.proxy.isReady() end)
  pcall(function() onTarget = t.proxy.isOnTarget() end)
  pcall(function() shaft = t.proxy.getShaftLength() end)

  local now = computer.uptime()
  local canFire = (now - (lastFire[t.addr] or 0)) >= FIRE_COOLDOWN

  debugMsg = string.format("yaw:%.0f pit:%.0f rdy:%s tgt:%s sh:%s d:%.1f",
    yaw, pitch, tostring(ready), tostring(onTarget), tostring(shaft), dist)

  -- Стреляем даже если isOnTarget=false (иногда API врёт)
  if canFire then
    -- убедимся что armed + shaft
    pcall(function()
      if shaft < 1 then t.proxy.extendShaft(2) end
      t.proxy.setArmed(true)
    end)

    local fired, ferr = false, nil
    local okf, res1, res2 = pcall(function()
      return t.proxy.fire()
    end)
    if okf then
      fired = res1
      ferr = res2
    end

    lastFire[t.addr] = now
    debugMsg = debugMsg .. " fire:" .. tostring(fired) .. (ferr and (" "..tostring(ferr)) or "")
    return fired
  end
  return false
end

local function doCombat()
  local anyOn = false
  for _, t in ipairs(turrets) do if t.powered then anyOn = true break end end
  if not anyOn then lastTarget = "турели выкл" statusMsg = "" return end
  if not (attackMobs or attackPlayers) then lastTarget = "атака выкл" return end

  local ents = getEntities()
  statusMsg = "Скан: " .. #ents .. " сущ."
  if #ents == 0 then lastTarget = "нет целей" debugMsg = "" return end

  -- приоритет: сначала мобы, потом игроки
  table.sort(ents, function(a, b)
    local ap, bp = isPlayer(a), isPlayer(b)
    if ap ~= bp then return not ap end  -- мобы раньше
    local da = (a.x or 0)^2 + (a.y or 0)^2 + (a.z or 0)^2
    local db = (b.x or 0)^2 + (b.y or 0)^2 + (b.z or 0)^2
    return da < db
  end)

  for _, ent in ipairs(ents) do
    if shouldAttack(ent) then
      lastTarget = tostring(ent.name or "?")
      for _, t in ipairs(turrets) do
        if t.powered then aimAndFire(t, ent) end
      end
      return
    end
  end
  lastTarget = "фильтр/whitelist"
  debugMsg = ""
end

-- ===================== GUI =====================
local function drawCard(idx, t, x, y, w, h)
  box(x, y, w, h, C.border, C.panel)
  txt(x+2, y+1, t.name or ("T-"..t.addr:sub(1,6)), C.yellow, C.panel)
  txt(x+2, y+2, t.addr:sub(1,14), C.gray, C.panel)
  txt(x+4, y+4, "  ███  ", C.purple, C.panel)
  txt(x+4, y+5, " █████ ", C.purple, C.panel)
  txt(x+4, y+6, "  ▀▀▀  ", C.gray, C.panel)
  txt(x+2, y+7, string.format("Δ %d,%d,%d", t.ox, t.oy, t.oz), C.cyan, C.panel)
  local barW = w - 4
  fill(x+2, y+8, barW, 1, C.energyBg)
  fill(x+2, y+8, t.powered and math.floor(barW*0.9) or math.floor(barW*0.12), 1, C.energy)
  local bOn  = btn(x+2,   y+h-2, 6, 1, "ВКЛ",  t.powered, C.yellow)
  local bOff = btn(x+w-8, y+h-2, 6, 1, "ВЫКЛ", not t.powered, C.gray)
  buttons["on_"..idx]  = {x=bOn.x,y=bOn.y,w=6,h=1, action=function() powerTurret(t,true) end}
  buttons["off_"..idx] = {x=bOff.x,y=bOff.y,w=6,h=1, action=function() powerTurret(t,false) end}
end

local function drawBottom()
  local y = screenH - 2
  fill(1, y, screenW, 2, C.panel)
  local items = {
    {id="all_on",  label="Турели ВКЛ",   active=true, col=C.yellow},
    {id="all_off", label="Турели ВЫКЛ",  active=true, col=C.gray},
    {id="add",     label="Белый список", active=true, col=C.yellow},
    {id="mobs",    label="Мобы",         active=attackMobs, col=C.yellow},
    {id="players", label="Игроки",       active=attackPlayers, col=C.yellow},
    {id="exit",    label="Выход",        active=true, col=C.red},
  }
  local bx = 2
  for _, it in ipairs(items) do
    local bw = #it.label + 2
    if bx + bw > screenW - 1 then break end
    btn(bx, y, bw, 2, it.label, it.active, it.col)
    buttons[it.id] = {x=bx,y=y,w=bw,h=2, action=function()
      if it.id=="all_on" then powerAll(true)
      elseif it.id=="all_off" then powerAll(false)
      elseif it.id=="add" then
        term.clear(); term.setCursor(1,1)
        print("Ник в белый список:")
        local n = term.read()
        if n and n:match("%S") then whitelist[n:gsub("%s+",""):lower()] = true end
      elseif it.id=="mobs" then attackMobs = not attackMobs
      elseif it.id=="players" then attackPlayers = not attackPlayers
      elseif it.id=="exit" then running = false
      end
    end}
    bx = bx + bw + 1
  end
end

local function drawUI()
  buttons = {}
  fill(1,1,screenW,screenH, C.bg)
  center(1, "═══ ECS® Security Systems ═══", C.title, C.bg)
  txt(2, 2, string.format("Турелей: %d | Детектор: %s | %dx%d",
    #turrets, detector and "OK" or "НЕТ", screenW, screenH), C.text, C.bg)

  local cols = math.min(4, math.max(1, #turrets))
  if #turrets == 0 then cols = 1 end
  local cardW = math.floor((screenW - 4 - (cols-1)) / cols)
  local cardH = 11
  for i, t in ipairs(turrets) do
    local col = (i-1) % cols
    local row = math.floor((i-1) / cols)
    local x = 2 + col * (cardW + 1)
    local y = 4 + row * (cardH + 1)
    if y + cardH < screenH - 5 then drawCard(i, t, x, y, cardW, cardH) end
  end

  txt(2, screenH-6, "Цель: " .. tostring(lastTarget), C.orange, C.bg)
  txt(2, screenH-5, statusMsg, C.cyan, C.bg)
  txt(2, screenH-4, "DBG: " .. tostring(debugMsg), C.yellow, C.bg)

  local wl = 0; for _ in pairs(whitelist) do wl = wl + 1 end
  txt(screenW-32, screenH-5, string.format("Мобы:%s Игр:%s WL:%d",
    attackMobs and "ON" or "OFF", attackPlayers and "ON" or "OFF", wl), C.text, C.bg)

  drawBottom()
end

-- ===================== MAIN =====================
local function main()
  setResolution()
  term.clear()
  gpu.setBackground(C.bg)
  gpu.setForeground(C.text)

  refreshTurrets()
  if not findDetector() then
    print("Entity Detector не найден!")
    return
  end

  while running do
    local now = computer.uptime()
    if now - lastDraw >= UPDATE_GUI then
      refreshTurrets()
      drawUI()
      lastDraw = now
    end
    if now - lastCombat >= COMBAT_EVERY then
      doCombat()
      lastCombat = now
    end

    local e,_,x,y,button = event.pull(0.05)
    if e == "touch" and button == 0 then
      for _, b in pairs(buttons) do
        if x >= b.x and x < b.x+b.w and y >= b.y and y < b.y+b.h then
          b.action(); drawUI(); break
        end
      end
    elseif e == "interrupted" then
      running = false
    end
  end

  powerAll(false)
  term.clear()
  print("Отключено.")
end

local ok, err = pcall(main)
if not ok then term.clear() print("Ошибка: "..tostring(err)) end
