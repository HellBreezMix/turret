-- ============================================================
-- ECS® Security Systems v30
-- Упрощённая логика + максимальный радиус детектора (64)
--   Мобы   = всё, что не игрок и не предмет
--   Игроки = только по кнопке + белый список
--   Нейтралы полностью убраны
-- ============================================================
local component = require("component")
local event = require("event")
local term = require("term")
local gpu = component.gpu
local computer = require("computer")
local fs = require("filesystem")
local serialization = require("serialization")

local SCAN_RANGE = 64          -- максимум, который разрешает OpenSecurity (1-64)
local FIRE_COOLDOWN = 0.40
local UPDATE_GUI = 0.45
local COMBAT_EVERY = 0.32
local LOCK_TIME = 2.8
local PREDICTION_TIME = 0.35
local CALIB_DELAY = 5.0
local AIM_HEIGHT = 0.9
local CONFIG_PATH = "/home/turret_cfg.lua"

local C = {
  bg         = 0x0A0A12,
  panel      = 0x14141E,
  border     = 0x3A3A55,
  text       = 0xE0E0F0,
  yellow     = 0xFFD700,
  green      = 0x22DD55,
  red        = 0xFF3344,
  purple     = 0xAA44FF,
  gray       = 0x3A3A4A,
  energy     = 0xFFCC22,
  energyBg   = 0x222218,
  title      = 0x00FFBB,
  dark       = 0x000000,
  cyan       = 0x22CCFF,
  orange     = 0xFF8800,
  selected   = 0x1A2540,
  cardBorder = 0x555577,
}

local turrets, detector = {}, nil
local attackMobs, attackPlayers = true, true
local whitelist = { hellbreez = true }
local running = true
local lastFire, lastCombat, lastDraw = {}, 0, 0
local lastTarget, statusMsg, debugMsg = "—", "", ""
local screenW, screenH = 80, 25
local buttons = {}
local selected = 1
local previousPos = {}
local lockedTarget = nil
local calibratingUntil = 0
local mode = "main"

---------------------------------------------------------------
-- Конфиг
---------------------------------------------------------------
local function saveConfig()
  local tdata = {}
  for _, t in ipairs(turrets) do
    tdata[t.addr] = {
      pos = t.pos,
      yawFine = t.yawFine or 0,
      pitchBias = t.pitchBias or 0,
      pitchSign = t.pitchSign or 1,
      name = t.name,
    }
  end
  local data = {
    turrets = tdata,
    whitelist = whitelist,
    attackMobs = attackMobs,
    attackPlayers = attackPlayers,
    selected = selected,
  }
  local f = io.open(CONFIG_PATH, "w")
  if f then f:write(serialization.serialize(data)) f:close() end
end

local function loadConfig()
  if not fs.exists(CONFIG_PATH) then return end
  local f = io.open(CONFIG_PATH, "r")
  if not f then return end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(serialization.unserialize, raw)
  if not ok or type(data) ~= "table" then return end
  whitelist = data.whitelist or whitelist
  if data.attackMobs ~= nil then attackMobs = data.attackMobs end
  if data.attackPlayers ~= nil then attackPlayers = data.attackPlayers end
  selected = data.selected or 1
  _G.__savedTurretData = data.turrets or {}
end

---------------------------------------------------------------
-- Графика
---------------------------------------------------------------
local function setResolution()
  local maxW, maxH = gpu.maxResolution()
  screenW, screenH = maxW, maxH
  gpu.setResolution(screenW, screenH)
  pcall(function() gpu.setDepth(8) end)
end

local function fill(x, y, w, h, bg)
  gpu.setBackground(bg or C.bg)
  gpu.fill(x, y, w, h, " ")
end

local function txt(x, y, str, fg, bg)
  if bg then gpu.setBackground(bg) end
  if fg then gpu.setForeground(fg) end
  gpu.set(x, y, tostring(str or ""))
end

local function center(y, str, fg, bg)
  txt(math.floor((screenW - #str) / 2) + 1, y, str, fg, bg)
end

local function box(x, y, w, h, border, bg)
  fill(x, y, w, h, bg or C.panel)
  gpu.setBackground(border or C.border)
  gpu.fill(x, y, w, 1, " ")
  gpu.fill(x, y+h-1, w, 1, " ")
  gpu.fill(x, y, 1, h, " ")
  gpu.fill(x+w-1, y, 1, h, " ")
end

local function btn(x, y, w, h, label, active, color)
  local bg = active and (color or C.yellow) or C.gray
  local fg = active and C.dark or C.text
  fill(x, y, w, h, bg)
  local lx = x + math.floor((w - #label) / 2)
  txt(lx, y + math.floor((h-1)/2), label, fg, bg)
  return {x=x, y=y, w=w, h=h}
end

-- Боковой вид турели с длинным стволом
local function drawTurretIcon(x, y, bg)
  gpu.setBackground(bg)

  -- Длинный горизонтальный ствол
  gpu.setForeground(0xCCCCDD)
  gpu.set(x,     y+1, "████████████████")
  gpu.set(x+16,  y+1, "█")

  -- Голова / казённая часть
  gpu.setForeground(0x9999AA)
  gpu.set(x+2,   y,   "████")
  gpu.set(x+1,   y+2, "██████")

  -- Поворотный механизм
  gpu.setForeground(0x666677)
  gpu.set(x+3,   y+3, "████")

  -- Основание
  gpu.setForeground(0x444455)
  gpu.set(x+2,   y+4, "██████")
  gpu.set(x+1,   y+5, "████████")
end

---------------------------------------------------------------
-- Турели
---------------------------------------------------------------
local function refreshTurrets()
  local found, newList = {}, {}
  for addr in component.list("os_energyturret") do found[addr] = true end

  for addr in pairs(found) do
    local old
    for _, t in ipairs(turrets) do
      if t.addr == addr then old = t break end
    end

    if old then
      pcall(function() old.powered = old.proxy.isPowered() end)
      table.insert(newList, old)
    else
      local p = component.proxy(addr)
      local powered = false
      pcall(function() powered = p.isPowered() end)
      local saved = (_G.__savedTurretData or {})[addr] or {}

      table.insert(newList, {
        addr = addr,
        proxy = p,
        powered = powered,
        name = saved.name or ("Турель " .. addr:sub(1, 8)),
        pos = saved.pos,
        yawFine = saved.yawFine or 0,
        pitchBias = saved.pitchBias or 0,
        pitchSign = saved.pitchSign or 1,
      })
      lastFire[addr] = 0
    end
  end

  table.sort(newList, function(a, b) return a.addr < b.addr end)
  turrets = newList
  if selected > #turrets then selected = math.max(1, #turrets) end
  if #turrets >= 1 and selected < 1 then selected = 1 end
end

local function findDetector()
  local a = component.list("os_entdetector")()
  if a then detector = component.proxy(a) return true end
  return false
end

local function getSelected()
  return turrets[selected]
end

local function powerTurret(t, on)
  pcall(function()
    if on then
      t.proxy.powerOn()
      os.sleep(0.07)
      pcall(function() t.proxy.extendShaft(2) end)
      os.sleep(0.04)
      t.proxy.setArmed(true)
    else
      pcall(function() t.proxy.setArmed(false) end)
      pcall(function() t.proxy.powerOff() end)
    end
  end)
  local powered = false
  pcall(function() powered = t.proxy.isPowered() end)
  t.powered = on and powered
end

local function powerAll(on)
  for _, t in ipairs(turrets) do powerTurret(t, on) end
end

---------------------------------------------------------------
-- Калибровка
---------------------------------------------------------------
local function startCalibration()
  local t = getSelected()
  if not t then
    statusMsg = "Сначала выбери турель"
    return
  end
  calibratingUntil = computer.uptime() + CALIB_DELAY
  statusMsg = string.format("Калибровка через %.0f сек — встань под ствол!", CALIB_DELAY)
end

local function finishCalibration()
  local t = getSelected()
  if not t or not detector then
    statusMsg = "Ошибка калибровки"
    calibratingUntil = 0
    return
  end

  local players = {}
  pcall(function() players = detector.scanPlayers(8) or {} end)
  if #players == 0 then
    statusMsg = "Никого не видно под стволом!"
    calibratingUntil = 0
    return
  end

  table.sort(players, function(a, b) return (a.range or 99) < (b.range or 99) end)
  local p = players[1]

  t.pos = {
    x = p.x or 0,
    y = (p.y or 0) + 1.55,
    z = p.z or 0,
  }
  t.yawFine = 0
  t.pitchBias = 0
  saveConfig()
  statusMsg = string.format("%s откалибрована (Y=%.2f)", t.name, t.pos.y)
  calibratingUntil = 0
end

local function resetCalibration()
  local t = getSelected()
  if not t then return end
  t.pos = nil
  t.yawFine = 0
  t.pitchBias = 0
  t.pitchSign = 1
  saveConfig()
  statusMsg = t.name .. " — калибровка сброшена"
end

---------------------------------------------------------------
-- Белый список
---------------------------------------------------------------
local function addToWhitelist()
  term.clear()
  print("Введи ник игрока (пусто = отмена):")
  local name = term.read()
  if name then
    name = name:gsub("%s+", ""):lower()
    if #name > 1 then
      whitelist[name] = true
      saveConfig()
      statusMsg = "Добавлен: " .. name
    end
  end
  term.clear()
end

local function removeFromWhitelist()
  local list = {}
  for name, _ in pairs(whitelist) do table.insert(list, name) end
  table.sort(list)
  if #list == 0 then
    statusMsg = "Список пуст"
    return
  end
  term.clear()
  print("Кого удалить?")
  for i, name in ipairs(list) do print(i .. ". " .. name) end
  print("\nНомер (пусто = отмена):")
  local num = tonumber(term.read())
  if num and list[num] then
    whitelist[list[num]] = nil
    saveConfig()
    statusMsg = "Удалён: " .. list[num]
  end
  term.clear()
end

---------------------------------------------------------------
-- Логика боя (упрощённая)
---------------------------------------------------------------
local function isPlayer(ent)
  if not ent then return false end
  if ent._isPlayer then return true end

  local n = tostring(ent.name or ""):lower()

  if n == "player" or n == "entityplayer" or n == "entityplayermp" then
    return true
  end
  if ent.username or ent.displayName then return true end

  -- Ключевые слова мобов — точно не игрок
  if n:find("zombie") or n:find("skeleton") or n:find("creeper") or
     n:find("spider") or n:find("enderman") or n:find("witch") or
     n:find("slime") or n:find("blaze") or n:find("ghast") or
     n:find("pigman") or n:find("wither") or n:find("guardian") or
     n:find("shulker") or n:find("phantom") or n:find("drowned") or
     n:find("pillager") or n:find("ravager") or n:find("hoglin") or
     n:find("piglin") or n:find("vex") or n:find("vindicator") or
     n:find("evoker") or n:find("illusion") or n:find("stray") or
     n:find("husk") or n:find("silverfish") or n:find("endermite") or
     n:find("cow") or n:find("pig") or n:find("sheep") or n:find("chicken") or
     n:find("rabbit") or n:find("horse") or n:find("villager") or n:find("wolf") or
     n:find("ocelot") or n:find("bat") or n:find("squid") or n:find("golem") then
    return false
  end

  -- Полные имена сущностей
  if n:find("%.") or n:find("entity") then return false end

  -- Простые ники — игроки
  if #n >= 3 then return true end

  return false
end

local function isItem(name)
  if not name then return true end
  local n = tostring(name):lower()
  return n == "item" or n:find("^item%.") or n:find("entityitem") or
         n:find("xp") or n:find("orb") or n:find("arrow") or n:find("fireball")
end

local function shouldAttack(ent)
  if not ent or not ent.name then return false end
  if isItem(ent.name) then return false end

  local n = tostring(ent.name or ""):lower()
  if whitelist[n] or whitelist[ent.name] then return false end
  if ent.username and whitelist[tostring(ent.username):lower()] then return false end
  if ent.displayName and whitelist[tostring(ent.displayName):lower()] then return false end

  -- Игрок → только если включена кнопка "Игроки"
  if isPlayer(ent) then
    return attackPlayers
  end

  -- Всё остальное (любые мобы) → если включена кнопка "Мобы"
  return attackMobs
end

local function getEntities()
  if not detector then return {} end
  local list = {}
  pcall(function()
    for _, e in ipairs(detector.scanEntities(SCAN_RANGE) or {}) do
      if e and e.name and not isItem(e.name) then
        e._isPlayer = false
        table.insert(list, e)
      end
    end
    for _, p in ipairs(detector.scanPlayers(SCAN_RANGE) or {}) do
      if p then
        p._isPlayer = true
        table.insert(list, p)
      end
    end
  end)
  return list
end

local function dirName(yaw)
  yaw = yaw % 360
  if yaw < 0 then yaw = yaw + 360 end
  if yaw >= 315 or yaw < 45 then return "С" end
  if yaw < 135 then return "В" end
  if yaw < 225 then return "Ю" end
  return "З"
end

local function computeAim(t, ent)
  if not t.pos then return nil end
  local name = tostring(ent.name or "unknown")
  local cx, cy, cz = ent.x or 0, ent.y or 0, ent.z or 0

  local predX, predY, predZ = cx, cy, cz
  local prev = previousPos[name]
  local now = computer.uptime()
  if prev and (now - prev.t) > 0.04 and (now - prev.t) < 1.5 then
    local dt = now - prev.t
    predX = cx + ((cx - prev.x) / dt) * PREDICTION_TIME
    predY = cy + ((cy - prev.y) / dt) * PREDICTION_TIME
    predZ = cz + ((cz - prev.z) / dt) * PREDICTION_TIME
  end
  previousPos[name] = {x=cx, y=cy, z=cz, t=now}

  local dx = predX - t.pos.x
  local dy = (predY + AIM_HEIGHT) - t.pos.y
  local dz = predZ - t.pos.z

  local distXZ = math.sqrt(dx*dx + dz*dz)
  local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

  local yaw = math.deg(math.atan2(dx, -dz)) + (t.yawFine or 0)
  yaw = yaw % 360
  if yaw < 0 then yaw = yaw + 360 end

  local pitch = math.deg(math.atan2(dy, math.max(distXZ, 0.12))) * (t.pitchSign or 1)
  pitch = pitch + (t.pitchBias or 0)
  pitch = math.max(-45, math.min(90, pitch))

  return yaw, pitch, dist
end

local function aimAndFire(t, ent)
  if not t.proxy or not t.pos then return false end
  pcall(function()
    t.proxy.powerOn()
    t.proxy.extendShaft(2)
    t.proxy.setArmed(true)
  end)

  local yaw, pitch, dist = computeAim(t, ent)
  if not yaw then return false end
  if dist < 1.8 or dist > SCAN_RANGE + 8 then
    debugMsg = string.format("дист:%.1f", dist)
    return false
  end

  pcall(function() t.proxy.moveTo(yaw, pitch) end)

  local wait, onTarget = 0, false
  while wait < 2.2 do
    pcall(function() onTarget = t.proxy.isOnTarget() end)
    if onTarget then break end
    os.sleep(0.05)
    wait = wait + 0.05
  end

  debugMsg = string.format("%s y:%.0f(%s) p:%.1f d:%.1f %s",
    t.name:sub(1,9), yaw, dirName(yaw), pitch, dist, onTarget and "OK" or "wait")

  if not onTarget then return false end

  local now = computer.uptime()
  if (now - (lastFire[t.addr] or 0)) < FIRE_COOLDOWN then return false end

  local fired = nil
  pcall(function() fired = t.proxy.fire() end)
  lastFire[t.addr] = now
  return fired
end

local function doCombat()
  if calibratingUntil > 0 or mode ~= "main" then return end

  local anyOn = false
  for _, t in ipairs(turrets) do
    if t.powered and t.pos then anyOn = true break end
  end
  if not anyOn then
    lastTarget = "турели выкл / нет калибровки"
    return
  end
  if not (attackMobs or attackPlayers) then
    lastTarget = "атака выкл"
    return
  end

  local ents = getEntities()
  statusMsg = "Скан: " .. #ents

  if #ents == 0 then
    lastTarget = "нет целей"
    lockedTarget = nil
    return
  end

  local now = computer.uptime()
  local target = nil

  if lockedTarget and now < (lockedTarget.lockUntil or 0) then
    for _, ent in ipairs(ents) do
      if shouldAttack(ent) and tostring(ent.name) == lockedTarget.name then
        local ddx = (ent.x or 0) - (lockedTarget.x or 0)
        local ddz = (ent.z or 0) - (lockedTarget.z or 0)
        if ddx*ddx + ddz*ddz < 220 then
          target = ent
          lockedTarget.x, lockedTarget.y, lockedTarget.z = ent.x, ent.y, ent.z
          break
        end
      end
    end
  end

  if not target then
    local ref = nil
    for _, t in ipairs(turrets) do if t.pos then ref = t.pos break end end

    table.sort(ents, function(a, b)
      local ap, bp = isPlayer(a), isPlayer(b)
      if ap ~= bp then return ap end
      if not ref then return false end
      local da = ((a.x or 0)-ref.x)^2 + ((a.z or 0)-ref.z)^2
      local db = ((b.x or 0)-ref.x)^2 + ((b.z or 0)-ref.z)^2
      return da < db
    end)

    for _, ent in ipairs(ents) do
      if shouldAttack(ent) then
        target = ent
        lockedTarget = {
          name = tostring(ent.name),
          x = ent.x, y = ent.y, z = ent.z,
          lockUntil = now + LOCK_TIME
        }
        break
      end
    end
  end

  if not target then
    lastTarget = "фильтр / белый список"
    return
  end

  lastTarget = tostring(target.name)
  for _, t in ipairs(turrets) do
    if t.powered and t.pos then aimAndFire(t, target) end
  end
end

---------------------------------------------------------------
-- Отрисовка
---------------------------------------------------------------
local function drawCard(idx, t, x, y, w, h)
  local isSel = (idx == selected)
  local borderCol = isSel and C.yellow or C.cardBorder
  local bgCol = isSel and C.selected or C.panel

  box(x, y, w, h, borderCol, bgCol)

  local shortName = t.name
  if #shortName > w-4 then shortName = shortName:sub(1, w-5) .. "…" end
  txt(x+2, y+1, shortName, isSel and C.yellow or C.text, bgCol)

  drawTurretIcon(x + math.floor((w-17)/2), y+3, bgCol)

  if not t.pos then
    txt(x+2, y+9, "нет калибровки", C.red, bgCol)
  else
    txt(x+2, y+9, string.format("%.0f %.0f %.0f", t.pos.x, t.pos.y, t.pos.z), C.cyan, bgCol)
  end

  local bOn  = btn(x+2,   y+h-2, 7, 1, "ВКЛ",  t.powered, C.yellow)
  local bOff = btn(x+w-9, y+h-2, 7, 1, "ВЫКЛ", not t.powered, C.gray)

  buttons["on_"..idx]  = {x=bOn.x, y=bOn.y, w=7, h=1, action=function() powerTurret(t,true) end}
  buttons["off_"..idx] = {x=bOff.x,y=bOff.y,w=7, h=1, action=function() powerTurret(t,false) end}

  buttons["sel_"..idx] = {
    x=x, y=y, w=w, h=h-2,
    action=function()
      selected = idx
      statusMsg = "Выбрана: " .. t.name
      saveConfig()
    end
  }
end

local function drawMainBottom()
  local y = screenH - 2
  fill(1, y, screenW, 2, 0x0C0C14)

  local items = {
    {id="on",       label="Турели ВКЛ",     col=C.green},
    {id="off",      label="Турели ВЫКЛ",    col=C.gray},
    {id="calib",    label="Калибровка",     col=C.green},
    {id="reset",    label="Сброс",          col=C.orange},
    {id="wl",       label="Белый список",   col=C.yellow},
    {id="mobs",     label="Мобы",           col=attackMobs and C.yellow or C.gray},
    {id="players",  label="Игроки",         col=attackPlayers and C.yellow or C.gray},
    {id="exit",     label="Выход",          col=C.red},
  }

  local bx = 2
  for _, it in ipairs(items) do
    local bw = #it.label + 2
    if bx + bw > screenW - 1 then break end
    btn(bx, y, bw, 2, it.label, true, it.col)
    buttons[it.id] = {
      x=bx, y=y, w=bw, h=2,
      action=function()
        if it.id == "on" then powerAll(true)
        elseif it.id == "off" then powerAll(false)
        elseif it.id == "calib" then startCalibration()
        elseif it.id == "reset" then resetCalibration()
        elseif it.id == "wl" then mode = "whitelist"
        elseif it.id == "mobs" then
          attackMobs = not attackMobs
          saveConfig()
        elseif it.id == "players" then
          attackPlayers = not attackPlayers
          saveConfig()
        elseif it.id == "exit" then
          running = false
        end
      end
    }
    bx = bx + bw + 1
  end
end

local function drawWhitelistUI()
  buttons = {}
  fill(1, 1, screenW, screenH, C.bg)
  center(1, "═══ Белый список ═══", C.title, C.bg)
  txt(3, 3, "Игроки, которых турели игнорируют:", C.text, C.bg)

  local list = {}
  for name,_ in pairs(whitelist) do table.insert(list, name) end
  table.sort(list)

  if #list == 0 then
    txt(5, 5, "Список пуст", C.gray, C.bg)
  else
    for i, name in ipairs(list) do
      if 4+i < screenH-4 then
        txt(5, 4+i, i..". "..name, C.cyan, C.bg)
      end
    end
  end

  local y = screenH-2
  fill(1, y, screenW, 2, 0x0C0C14)

  local items = {
    {id="add",  label="Добавить", col=C.green},
    {id="rem",  label="Удалить",  col=C.orange},
    {id="back", label="Назад",    col=C.yellow},
  }
  local bx = 3
  for _, it in ipairs(items) do
    local bw = #it.label + 2
    btn(bx, y, bw, 2, it.label, true, it.col)
    buttons[it.id] = {
      x=bx, y=y, w=bw, h=2,
      action=function()
        if it.id=="add" then addToWhitelist()
        elseif it.id=="rem" then removeFromWhitelist()
        elseif it.id=="back" then mode="main" end
      end
    }
    bx = bx + bw + 2
  end
end

local function drawMainUI()
  buttons = {}
  fill(1, 1, screenW, screenH, C.bg)
  center(1, "═══ ECS® Security Systems v30 ═══", C.title, C.bg)

  if calibratingUntil > 0 then
    local left = math.max(0, calibratingUntil - computer.uptime())
    txt(2, 2, string.format(">>> Калибровка через %.1f сек — встань под ствол! <<<", left), C.orange, C.bg)
  else
    local t = getSelected()
    if t then
      if t.pos then
        txt(2, 2, string.format("Выбрана: %s | %.1f %.1f %.1f | yaw:%.1f bias:%.1f",
          t.name, t.pos.x, t.pos.y, t.pos.z, t.yawFine or 0, t.pitchBias or 0), C.text, C.bg)
      else
        txt(2, 2, "Выбрана: " .. t.name .. "  —  нужна калибровка", C.orange, C.bg)
      end
    end
  end

  local cols = math.min(4, math.max(1, #turrets))
  local cardW = math.floor((screenW - 5 - (cols-1)) / cols)
  local cardH = 13

  for i, t in ipairs(turrets) do
    local col = (i-1) % cols
    local row = math.floor((i-1) / cols)
    local x = 2 + col * (cardW + 1)
    local y = 4 + row * (cardH + 1)
    if y + cardH < screenH - 4 then
      drawCard(i, t, x, y, cardW, cardH)
    end
  end

  txt(2, screenH-5, "Цель: " .. tostring(lastTarget), C.orange, C.bg)
  txt(2, screenH-4, statusMsg .. "   " .. tostring(debugMsg), C.cyan, C.bg)
  drawMainBottom()
end

local function drawUI()
  if mode == "whitelist" then
    drawWhitelistUI()
  else
    drawMainUI()
  end
end

---------------------------------------------------------------
-- Главный цикл
---------------------------------------------------------------
local function main()
  setResolution()
  term.clear()
  loadConfig()

  gpu.setBackground(C.bg)
  gpu.setForeground(C.text)

  refreshTurrets()
  if not findDetector() then
    print("Entity Detector не найден!")
    return
  end

  while running do
    local now = computer.uptime()

    if calibratingUntil > 0 and now >= calibratingUntil then
      finishCalibration()
    end

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
      local handled = false
      for id, b in pairs(buttons) do
        if not id:find("^sel_") and x >= b.x and x < b.x+b.w and y >= b.y and y < b.y+b.h then
          b.action()
          handled = true
          break
        end
      end
      if not handled then
        for id, b in pairs(buttons) do
          if id:find("^sel_") and x >= b.x and x < b.x+b.w and y >= b.y and y < b.y+b.h then
            b.action()
            break
          end
        end
      end
      drawUI()
      lastDraw = computer.uptime()
    elseif e == "interrupted" then
      running = false
    end
  end

  powerAll(false)
  saveConfig()
  term.clear()
  print("Система отключена.")
end

local ok, err = pcall(main)
if not ok then
  term.clear()
  print("Ошибка: " .. tostring(err))
end
