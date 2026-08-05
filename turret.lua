-- ============================================================
-- ECS® Security Systems v16
-- Детектор ставится на 1 блок ВЫШЕ турели
-- 0°=Север, 90°=Восток | формула atan2(dx, -dz)
-- ============================================================

local component = require("component")
local event = require("event")
local term = require("term")
local gpu = component.gpu
local computer = require("computer")
local fs = require("filesystem")
local serialization = require("serialization")

local SCAN_RANGE = 48
local FIRE_COOLDOWN = 0.42
local UPDATE_GUI = 0.25
local COMBAT_EVERY = 0.32
local LOCK_TIME = 2.8
local PREDICTION_TIME = 0.38
local CONFIG_PATH = "/home/turret_cfg.lua"

local yawFine = 0
local pitchSign = 1
local aimHeight = 1.35

local C = {
  bg=0x0A0A14, panel=0x141420, border=0x3A3A60, text=0xD8D8F0,
  yellow=0xFFD700, green=0x22DD55, red=0xFF3344, purple=0xAA55FF,
  gray=0x444455, energy=0xFFCC22, energyBg=0x2A2A18, title=0x00FFBB,
  dark=0x000000, cyan=0x22CCFF, orange=0xFF8800,
}

local turrets, detector = {}, nil
local attackMobs, attackPlayers = true, true
local whitelist = { hellbreez = true }
local running = true
local lastFire, lastCombat, lastDraw = {}, 0, 0
local lastTarget, statusMsg, debugMsg = "—", "", ""
local screenW, screenH = 80, 25
local buttons = {}
local TURRET_POS = nil
local lockedTarget = nil
local previousPos = {}

local function saveConfig()
  local data = {
    turret = TURRET_POS,
    whitelist = whitelist,
    attackMobs = attackMobs,
    attackPlayers = attackPlayers,
    yawFine = yawFine,
    pitchSign = pitchSign,
  }
  local f = io.open(CONFIG_PATH, "w")
  if f then
    f:write(serialization.serialize(data))
    f:close()
  end
end

local function loadConfig()
  if not fs.exists(CONFIG_PATH) then return end
  local f = io.open(CONFIG_PATH, "r")
  if not f then return end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(serialization.unserialize, raw)
  if not ok or type(data) ~= "table" then return end
  TURRET_POS = data.turret or TURRET_POS
  whitelist = data.whitelist or whitelist
  if data.attackMobs ~= nil then attackMobs = data.attackMobs end
  if data.attackPlayers ~= nil then attackPlayers = data.attackPlayers end
  yawFine = data.yawFine or 0
  pitchSign = data.pitchSign or 1
end

local function setResolution()
  local maxW, maxH = gpu.maxResolution()
  screenW, screenH = maxW, maxH
  gpu.setResolution(screenW, screenH)
  pcall(function() gpu.setDepth(8) end)
end

local function fill(x, y, w, h, bg, fg, ch)
  gpu.setBackground(bg or C.bg)
  if fg then gpu.setForeground(fg) end
  gpu.fill(x, y, w, h, ch or " ")
end

local function txt(x, y, str, fg, bg)
  if bg then gpu.setBackground(bg) end
  if fg then gpu.setForeground(fg) end
  gpu.set(x, y, tostring(str))
end

local function center(y, str, fg, bg)
  txt(math.floor((screenW - #str) / 2) + 1, y, str, fg, bg)
end

local function box(x, y, w, h, border, bg)
  fill(x, y, w, h, bg or C.panel)
  gpu.setBackground(border or C.border)
  gpu.fill(x, y, w, 1, " ")
  gpu.fill(x, y + h - 1, w, 1, " ")
  gpu.fill(x, y, 1, h, " ")
  gpu.fill(x + w - 1, y, 1, h, " ")
end

local function btn(x, y, w, h, label, active, color)
  local bg = active and (color or C.yellow) or C.gray
  local fg = active and C.dark or C.text
  fill(x, y, w, h, bg, fg)
  txt(x + math.floor((w - #label) / 2), y + math.floor((h - 1) / 2), label, fg, bg)
  return {x = x, y = y, w = w, h = h}
end

local function calibrateBarrel()
  if not detector then return false end
  local players = {}
  pcall(function() players = detector.scanPlayers(6) or {} end)
  if #players == 0 then
    statusMsg = "Встань РОВНО ПОД ствол"
    return false
  end
  table.sort(players, function(a, b) return (a.range or 99) < (b.range or 99) end)
  local p = players[1]

  TURRET_POS = {
    x = p.x or 0,
    y = (p.y or 0) - 1.12,
    z = p.z or 0,
  }

  yawFine = 0
  saveConfig()
  statusMsg = string.format("Ствол: %.2f  %.2f  %.2f", TURRET_POS.x, TURRET_POS.y, TURRET_POS.z)
  return true
end

local function refreshTurrets()
  local found, newList = {}, {}
  for addr in component.list("os_energyturret") do
    found[addr] = true
  end
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
      table.insert(newList, {
        addr = addr,
        proxy = p,
        powered = powered,
        name = "T-" .. addr:sub(1, 6)
      })
      lastFire[addr] = 0
    end
  end
  table.sort(newList, function(a, b) return a.addr < b.addr end)
  turrets = newList
end

local function findDetector()
  local a = component.list("os_entdetector")()
  if a then
    detector = component.proxy(a)
    return true
  end
  return false
end

local function powerTurret(t, on)
  pcall(function()
    if on then
      t.proxy.powerOn()
      os.sleep(0.12)
      pcall(function() t.proxy.extendShaft(2) end)
      os.sleep(0.08)
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
  for _, t in ipairs(turrets) do
    powerTurret(t, on)
  end
end

local function isPlayer(ent)
  if not ent then return false end
  local n = tostring(ent.name or ""):lower()
  if n == "player" or n == "entityplayer" or n == "entityplayermp" then
    return true
  end
  return false
end

local function isItem(name)
  if not name then return true end
  local n = tostring(name):lower()
  if n == "item" or n:find("^item%.") or n:find("entityitem") then
    return true
  end
  return false
end

local function shouldAttack(ent)
  if not ent or not ent.name then return false end
  if isItem(ent.name) then return false end

  local n = tostring(ent.name):lower()
  if whitelist[n] or whitelist[ent.name] then return false end

  if isPlayer(ent) then
    return attackPlayers
  end

  -- всё остальное считаем мобом
  return attackMobs
end

local function getEntities()
  if not detector then return {} end
  local list = {}
  pcall(function()
    for _, e in ipairs(detector.scanEntities(SCAN_RANGE) or {}) do
      if e and e.name and not isItem(e.name) then
        table.insert(list, e)
      end
    end
    for _, p in ipairs(detector.scanPlayers(SCAN_RANGE) or {}) do
      if p then table.insert(list, p) end
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

local function computeAim(ent)
  local name = tostring(ent.name or "unknown")
  local cx = ent.x or 0
  local cy = ent.y or 0
  local cz = ent.z or 0

  local predX, predY, predZ = cx, cy, cz
  local prev = previousPos[name]
  local now = computer.uptime()
  if prev and (now - prev.t) > 0.04 and (now - prev.t) < 1.5 then
    local dt = now - prev.t
    local vx = (cx - prev.x) / dt
    local vy = (cy - prev.y) / dt
    local vz = (cz - prev.z) / dt
    predX = cx + vx * PREDICTION_TIME
    predY = cy + vy * PREDICTION_TIME
    predZ = cz + vz * PREDICTION_TIME
  end
  previousPos[name] = {x = cx, y = cy, z = cz, t = now}

  local dx = predX - TURRET_POS.x
  local dy = (predY + aimHeight) - TURRET_POS.y
  local dz = predZ - TURRET_POS.z

  local distXZ = math.sqrt(dx * dx + dz * dz)
  local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

  local yaw = math.deg(math.atan2(dx, -dz)) + yawFine
  yaw = yaw % 360
  if yaw < 0 then yaw = yaw + 360 end

  local pitch = math.deg(math.atan2(dy, math.max(distXZ, 0.12))) * pitchSign
  pitch = math.max(-45, math.min(90, pitch))

  return yaw, pitch, dist, distXZ
end

local function aimAndFire(t, ent)
  if not t.proxy or not TURRET_POS then return false end

  pcall(function()
    t.proxy.powerOn()
    t.proxy.extendShaft(2)
    t.proxy.setArmed(true)
  end)

  local yaw, pitch, dist = computeAim(ent)

  if dist < 2.0 or dist > SCAN_RANGE + 8 then
    debugMsg = string.format("дист:%.1f", dist)
    return false
  end

  pcall(function() t.proxy.moveTo(yaw, pitch) end)

  local wait, onTarget = 0, false
  while wait < 2.0 do
    pcall(function() onTarget = t.proxy.isOnTarget() end)
    if onTarget then break end
    os.sleep(0.05)
    wait = wait + 0.05
  end

  debugMsg = string.format("y:%.0f(%s) p:%.0f d:%.1f on:%s",
    yaw, dirName(yaw), pitch, dist, tostring(onTarget))

  if not onTarget then
    debugMsg = debugMsg .. " ждём"
    return false
  end

  local now = computer.uptime()
  if (now - (lastFire[t.addr] or 0)) < FIRE_COOLDOWN then
    return false
  end

  local fired = nil
  pcall(function() fired = t.proxy.fire() end)
  lastFire[t.addr] = now
  debugMsg = debugMsg .. " выстр:" .. tostring(fired)
  return fired
end

local function doCombat()
  if not TURRET_POS then
    lastTarget = "под турель → Калибровка"
    return
  end

  local anyOn = false
  for _, t in ipairs(turrets) do
    if t.powered then anyOn = true break end
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

  -- Всегда показываем реальные имена
  local names = {}
  for i = 1, math.min(5, #ents) do
    table.insert(names, tostring(ents[i].name or "?"))
  end
  statusMsg = "Скан: " .. #ents
  if #names > 0 then
    statusMsg = statusMsg .. " → " .. table.concat(names, ", ")
  end

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
        if ddx * ddx + ddz * ddz < 180 then
          target = ent
          lockedTarget.x = ent.x
          lockedTarget.y = ent.y
          lockedTarget.z = ent.z
          break
        end
      end
    end
  end

  if not target then
    table.sort(ents, function(a, b)
      local ap, bp = isPlayer(a), isPlayer(b)
      if ap ~= bp then return ap end
      local da = ((a.x or 0) - TURRET_POS.x)^2 + ((a.z or 0) - TURRET_POS.z)^2
      local db = ((b.x or 0) - TURRET_POS.x)^2 + ((b.z or 0) - TURRET_POS.z)^2
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
    lastTarget = "белый список / фильтр"
    return
  end

  lastTarget = tostring(target.name)
  statusMsg = string.format("Скан: %d | %s", #ents, lastTarget)

  for _, t in ipairs(turrets) do
    if t.powered then
      aimAndFire(t, target)
    end
  end
end

local function drawCard(idx, t, x, y, w, h)
  box(x, y, w, h, C.border, C.panel)
  txt(x + 2, y + 1, t.name, C.yellow, C.panel)
  txt(x + 2, y + 2, t.addr:sub(1, 14), C.gray, C.panel)
  txt(x + 4, y + 4, " ███ ", C.purple, C.panel)
  txt(x + 4, y + 5, " █████ ", C.purple, C.panel)

  if TURRET_POS then
    txt(x + 2, y + 7, string.format("%.1f %.1f %.1f", TURRET_POS.x, TURRET_POS.y, TURRET_POS.z), C.cyan, C.panel)
  else
    txt(x + 2, y + 7, "нет ствола", C.red, C.panel)
  end

  local barW = w - 4
  fill(x + 2, y + 8, barW, 1, C.energyBg)
  fill(x + 2, y + 8, t.powered and math.floor(barW * 0.9) or math.floor(barW * 0.12), 1, C.energy)

  local bOn = btn(x + 2, y + h - 2, 6, 1, "ВКЛ", t.powered, C.yellow)
  local bOff = btn(x + w - 8, y + h - 2, 6, 1, "ВЫКЛ", not t.powered, C.gray)

  buttons["on_" .. idx] = {x = bOn.x, y = bOn.y, w = 6, h = 1, action = function() powerTurret(t, true) end}
  buttons["off_" .. idx] = {x = bOff.x, y = bOff.y, w = 6, h = 1, action = function() powerTurret(t, false) end}
end

local function drawBottom()
  local y = screenH - 2
  fill(1, y, screenW, 2, C.panel)

  local items = {
    {id = "all_on",  label = "Турели ВКЛ",  active = true, col = C.yellow},
    {id = "all_off", label = "Турели ВЫКЛ", active = true, col = C.gray},
    {id = "calib",   label = "Калибровка",  active = true, col = C.green},
    {id = "left",    label = "◀",           active = true, col = C.cyan},
    {id = "right",   label = "▶",           active = true, col = C.cyan},
    {id = "flipP",   label = "Наклон",      active = true, col = C.cyan},
    {id = "mobs",    label = "Мобы",        active = attackMobs, col = C.yellow},
    {id = "players", label = "Игроки",      active = attackPlayers, col = C.yellow},
    {id = "exit",    label = "Выход",       active = true, col = C.red},
  }

  local bx = 2
  for _, it in ipairs(items) do
    local bw = #it.label + 2
    if bx + bw > screenW - 1 then break end
    btn(bx, y, bw, 2, it.label, it.active, it.col)
    buttons[it.id] = {
      x = bx, y = y, w = bw, h = 2,
      action = function()
        if it.id == "all_on" then powerAll(true)
        elseif it.id == "all_off" then powerAll(false)
        elseif it.id == "calib" then calibrateBarrel()
        elseif it.id == "left" then
          yawFine = yawFine - 1.5
          saveConfig()
          statusMsg = "Подстр: " .. string.format("%.1f", yawFine) .. "°"
        elseif it.id == "right" then
          yawFine = yawFine + 1.5
          saveConfig()
          statusMsg = "Подстр: " .. string.format("%.1f", yawFine) .. "°"
        elseif it.id == "flipP" then
          pitchSign = -pitchSign
          saveConfig()
          statusMsg = "Наклон: " .. pitchSign
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

local function drawUI()
  buttons = {}
  fill(1, 1, screenW, screenH, C.bg)
  center(1, "═══ ECS® Security Systems v16 ═══", C.title, C.bg)

  if TURRET_POS then
    txt(2, 2, string.format("Турелей: %d | Ствол: %.2f  %.2f  %.2f | 0°=Север",
      #turrets, TURRET_POS.x, TURRET_POS.y, TURRET_POS.z), C.text, C.bg)
  else
    txt(2, 2, "Встань ПОД турель → [Калибровка]   (детектор должен быть выше)", C.orange, C.bg)
  end

  local cols = math.min(4, math.max(1, #turrets))
  if #turrets == 0 then cols = 1 end
  local cardW = math.floor((screenW - 4 - (cols - 1)) / cols)
  local cardH = 11

  for i, t in ipairs(turrets) do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    local x = 2 + col * (cardW + 1)
    local y = 4 + row * (cardH + 1)
    if y + cardH < screenH - 5 then
      drawCard(i, t, x, y, cardW, cardH)
    end
  end

  txt(2, screenH - 6, "Цель: " .. tostring(lastTarget), C.orange, C.bg)
  txt(2, screenH - 5, statusMsg, C.cyan, C.bg)
  txt(2, screenH - 4, "Отладка: " .. tostring(debugMsg), C.yellow, C.bg)
  drawBottom()
end

local function main()
  setResolution()
  term.clear()
  loadConfig()
  if math.abs(yawFine) > 15 then yawFine = 0 end

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

    local e, _, x, y, button = event.pull(0.05)
    if e == "touch" and button == 0 then
      for _, b in pairs(buttons) do
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
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
  saveConfig()
  term.clear()
  print("Система отключена.")
end

local ok, err = pcall(main)
if not ok then
  term.clear()
  print("Ошибка: " .. tostring(err))
end
