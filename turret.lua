-- ============================================================
--  ECS® Security Systems — Multi-Turret Control v2
--  OpenComputers + OpenSecurity
--  Полный экран 3×2 | Рабочее наведение
-- ============================================================

local component = require("component")
local event     = require("event")
local term      = require("term")
local gpu       = component.gpu
local computer  = require("computer")

-- ===================== НАСТРОЙКИ =====================
local SCAN_RANGE    = 48
local AIM_HEIGHT    = 1.0      -- высота прицела (ноги/тело моба)
local FIRE_COOLDOWN = 0.30
local UPDATE_GUI    = 0.20
local COMBAT_EVERY  = 0.25

--[[
  Смещение турели относительно Entity Detector.
  Смотри на постройку: детектор → турель.
  x = восток(+)/запад(-)
  y = вверх(+)/вниз(-)
  z = юг(+)/север(-)
]]
local TURRET_CONFIG = {
  -- Пример: турель на 3 блока выше детектора
  -- { addr = "fe9adb", x = 0, y = 3, z = 0, name = "Главная" },
}

local DEFAULT_OFFSET = { x = 0, y = 3, z = 0 }  -- чаще всего турель выше детектора

local C = {
  bg=0x0A0A14, panel=0x141420, border=0x3A3A60, text=0xD8D8F0,
  yellow=0xFFD700, green=0x22DD55, red=0xFF3344, purple=0xAA55FF,
  gray=0x444455, energy=0xFFCC22, energyBg=0x2A2A18, title=0x00FFBB,
  dark=0x000000, cyan=0x22CCFF, orange=0xFF8800,
}

-- ===================== СОСТОЯНИЕ =====================
local turrets   = {}
local detector  = nil
local attackMobs    = true
local attackPlayers = true
local whitelist     = {}
local running       = true
local lastFire      = {}
local lastCombat    = 0
local lastTarget    = "—"
local screenW, screenH = 80, 25
local buttons = {}
local statusMsg = ""

-- ===================== УТИЛИТЫ =====================
local function setResolution()
  -- Берём МАКСИМАЛЬНОЕ разрешение GPU+экрана — весь 3×2
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
  gpu.fill(x,y,w,1," ")
  gpu.fill(x,y+h-1,w,1," ")
  gpu.fill(x,y,1,h," ")
  gpu.fill(x+w-1,y,1,h," ")
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
    if cfg.addr and (addr:sub(1, #cfg.addr) == cfg.addr or cfg.addr == addr) then
      return cfg
    end
  end
  return nil
end

local function refreshTurrets()
  local found = {}
  for addr in component.list("os_energyturret") do
    found[addr] = true
  end
  local newList = {}
  for addr in pairs(found) do
    local existing = nil
    for _, t in ipairs(turrets) do
      if t.addr == addr then existing = t; break end
    end
    if existing then
      local powered = false
      pcall(function() powered = existing.proxy.isPowered() end)
      existing.powered = powered
      table.insert(newList, existing)
    else
      local p = component.proxy(addr)
      local cfg = getConfigFor(addr)
      local ox = (cfg and cfg.x) or DEFAULT_OFFSET.x
      local oy = (cfg and cfg.y) or DEFAULT_OFFSET.y
      local oz = (cfg and cfg.z) or DEFAULT_OFFSET.z
      local name = (cfg and cfg.name) or ("T-" .. addr:sub(1,6))
      local powered = false
      pcall(function() powered = p.isPowered() end)
      table.insert(newList, {
        addr=addr, proxy=p, powered=powered,
        ox=ox, oy=oy, oz=oz, name=name
      })
      lastFire[addr] = 0
    end
  end
  table.sort(newList, function(a,b) return a.addr < b.addr end)
  turrets = newList
end

local function findDetector()
  local addr = component.list("os_entdetector")()
  if addr then detector = component.proxy(addr); return true end
  return false
end

local function powerTurret(t, on)
  pcall(function()
    if on then
      t.proxy.powerOn()
      os.sleep(0.1)
      t.proxy.setArmed(true)
      pcall(function() t.proxy.extendShaft(2) end)
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
  if ent.uuid and #tostring(ent.uuid) > 20 then return true end
  return false
end

local function isItem(name)
  if not name then return true end
  name = tostring(name):lower()
  return name:find("item") ~= nil
end

local function shouldAttack(ent)
  if not ent or not ent.name or isItem(ent.name) then return false end
  if isPlayer(ent) then
    if whitelist[ent.name] then return false end
    return attackPlayers
  end
  return attackMobs
end

local function getEntities()
  if not detector then return {} end
  local list = {}
  pcall(function()
    local ents = detector.scanEntities(SCAN_RANGE)
    if type(ents) == "table" then
      for _, e in ipairs(ents) do
        if e and e.name and not isItem(e.name) then
          table.insert(list, e)
        end
      end
    end
    local players = detector.scanPlayers(SCAN_RANGE)
    if type(players) == "table" then
      for _, p in ipairs(players) do
        if p then table.insert(list, p) end
      end
    end
  end)
  return list
end

-- ===================== НАВЕДЕНИЕ (исправленное) =====================
local function aimAndFire(t, ent)
  if not t.powered or not t.proxy then return false end

  -- координаты сущности от детектора
  local ex = ent.x or 0
  local ey = ent.y or 0
  local ez = ent.z or 0

  -- вектор от турели к цели
  local dx = ex - t.ox
  local dy = ey - t.oy + AIM_HEIGHT
  local dz = ez - t.oz

  local distXZ = math.sqrt(dx*dx + dz*dz)
  local dist   = math.sqrt(dx*dx + dy*dy + dz*dz)
  if dist < 1.5 or dist > SCAN_RANGE + 5 then return false end

  -- Yaw: 0 = юг в Minecraft? В OpenSecurity:
  -- обычно 0° = север, по часовой. atan2(dx, dz) даёт угол от +Z
  local yaw = math.deg(math.atan2(-dx, dz))
  if yaw < 0 then yaw = yaw + 360 end

  local pitch = math.deg(math.atan2(dy, distXZ))
  pitch = math.max(-45, math.min(90, pitch))

  -- наведение
  local okMove = pcall(function()
    t.proxy.moveTo(yaw, pitch)
  end)
  if not okMove then
    -- запасной вариант в радианах
    pcall(function()
      t.proxy.moveToRadians(math.rad(yaw), math.rad(pitch))
    end)
  end

  -- ждём наведения (коротко)
  local waited = 0
  while waited < 0.4 do
    local onTarget = false
    pcall(function() onTarget = t.proxy.isOnTarget() end)
    if onTarget then break end
    os.sleep(0.05)
    waited = waited + 0.05
  end

  local ready = false
  pcall(function() ready = t.proxy.isReady() end)

  local now = computer.uptime()
  if ready and (now - (lastFire[t.addr] or 0)) >= FIRE_COOLDOWN then
    local fired = false
    pcall(function()
      fired = t.proxy.fire()
    end)
    lastFire[t.addr] = now
    return fired
  end
  return false
end

local function doCombat()
  local anyOn = false
  for _, t in ipairs(turrets) do
    if t.powered then anyOn = true; break end
  end
  if not anyOn then
    lastTarget = "турели выкл"
    return
  end
  if not (attackMobs or attackPlayers) then
    lastTarget = "атака выкл"
    return
  end

  local ents = getEntities()
  if #ents == 0 then
    lastTarget = "нет целей"
    statusMsg = "Скан: 0 сущностей"
    return
  end

  -- ближайшая
  table.sort(ents, function(a,b)
    local da = (a.x or 0)^2 + (a.y or 0)^2 + (a.z or 0)^2
    local db = (b.x or 0)^2 + (b.y or 0)^2 + (b.z or 0)^2
    return da < db
  end)

  statusMsg = "Скан: " .. #ents .. " сущ."

  for _, ent in ipairs(ents) do
    if shouldAttack(ent) then
      local name = tostring(ent.name or "?")
      lastTarget = name
      for _, t in ipairs(turrets) do
        if t.powered then
          aimAndFire(t, ent)
        end
      end
      return
    end
  end
  lastTarget = "все в белом списке / фильтр"
end

-- ===================== GUI =====================
local function drawCard(idx, t, x, y, w, h)
  box(x, y, w, h, C.border, C.panel)
  local title = t.name or ("T-"..t.addr:sub(1,6))
  txt(x+2, y+1, title, C.yellow, C.panel)
  txt(x+2, y+2, t.addr:sub(1,14), C.gray, C.panel)
  txt(x+4, y+4, "  ███  ", C.purple, C.panel)
  txt(x+4, y+5, " █████ ", C.purple, C.panel)
  txt(x+4, y+6, "  ▀▀▀  ", C.gray,  C.panel)
  txt(x+2, y+7, string.format("Δ %d,%d,%d", t.ox, t.oy, t.oz), C.cyan, C.panel)
  local barW = w - 4
  fill(x+2, y+8, barW, 1, C.energyBg)
  fill(x+2, y+8, t.powered and math.floor(barW*0.9) or math.floor(barW*0.12), 1, C.energy)
  local bOn  = btn(x+2,   y+h-2, 6, 1, "ВКЛ",  t.powered,     C.yellow)
  local bOff = btn(x+w-8, y+h-2, 6, 1, "ВЫКЛ", not t.powered, C.gray)
  buttons["on_"..idx]  = {x=bOn.x,  y=bOn.y,  w=6,h=1, action=function() powerTurret(t,true)  end}
  buttons["off_"..idx] = {x=bOff.x, y=bOff.y, w=6,h=1, action=function() powerTurret(t,false) end}
end

local function drawBottom()
  local y = screenH - 2
  fill(1, y, screenW, 2, C.panel)
  local items = {
    {id="all_on",  label="Турели ВКЛ",      active=true,          col=C.yellow},
    {id="all_off", label="Турели ВЫКЛ",     active=true,          col=C.gray},
    {id="add",     label="Белый список",    active=true,          col=C.yellow},
    {id="mobs",    label="Мобы",            active=attackMobs,    col=C.yellow},
    {id="players", label="Игроки",          active=attackPlayers, col=C.yellow},
    {id="exit",    label="Выход",           active=true,          col=C.red},
  }
  local bx = 2
  for _, it in ipairs(items) do
    local bw = #it.label + 2
    if bx + bw > screenW - 1 then break end
    btn(bx, y, bw, 2, it.label, it.active, it.col)
    buttons[it.id] = {x=bx,y=y,w=bw,h=2, action=function()
      if it.id == "all_on"  then powerAll(true)
      elseif it.id == "all_off" then powerAll(false)
      elseif it.id == "add" then
        term.clear(); term.setCursor(1,1)
        print("Ник в белый список (Enter = отмена):")
        local n = term.read()
        if n and n:match("%S") then whitelist[n:gsub("%s+","")] = true end
      elseif it.id == "mobs"    then attackMobs    = not attackMobs
      elseif it.id == "players" then attackPlayers = not attackPlayers
      elseif it.id == "exit"    then running = false
      end
    end}
    bx = bx + bw + 1
  end
end

local function drawUI()
  buttons = {}
  fill(1,1,screenW,screenH, C.bg)
  center(1, "═══ ECS® Security Systems ═══", C.title, C.bg)
  txt(2, 2, string.format("Турелей: %d  |  Детектор: %s  |  Радиус: %d  |  %dx%d",
    #turrets, detector and "OK" or "НЕТ", SCAN_RANGE, screenW, screenH), C.text, C.bg)

  local cols = math.min(4, math.max(1, #turrets))
  if #turrets == 0 then cols = 1 end
  local cardW = math.floor((screenW - 4 - (cols-1)*1) / cols)
  local cardH = 11
  local startY = 4

  for i, t in ipairs(turrets) do
    local col = (i-1) % cols
    local row = math.floor((i-1) / cols)
    local x = 2 + col * (cardW + 1)
    local y = startY + row * (cardH + 1)
    if y + cardH < screenH - 4 then
      drawCard(i, t, x, y, cardW, cardH)
    end
  end

  if #turrets == 0 then
    center(10, "Турели не найдены!", C.red, C.bg)
  end

  -- статус боя
  txt(2, screenH-5, "Цель: " .. tostring(lastTarget), C.orange, C.bg)
  txt(2, screenH-4, statusMsg, C.cyan, C.bg)

  local wl = 0; for _ in pairs(whitelist) do wl = wl + 1 end
  txt(screenW - 35, screenH-4, string.format("Мобы:%s Игроки:%s WL:%d",
    attackMobs and "ON" or "OFF",
    attackPlayers and "ON" or "OFF", wl), C.text, C.bg)

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
    print("ОШИБКА: Entity Detector не найден!")
    print("Поставь os_entdetector рядом / через адаптер.")
    return
  end

  -- авто-включение турелей при старте (можно убрать)
  -- powerAll(true)

  local lastDraw = 0
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

    local e, _, x, y, button = event.pull(0.05)
    if e == "touch" and button == 0 then
      for _, b in pairs(buttons) do
        if x >= b.x and x < b.x+b.w and y >= b.y and y < b.y+b.h then
          b.action()
          drawUI()
          break
        end
      end
    elseif e == "interrupted" then
      running = false
    end
  end

  powerAll(false)
  term.clear()
  print("Система безопасности отключена.")
end

local ok, err = pcall(main)
if not ok then
  term.clear()
  print("Ошибка: " .. tostring(err))
end
