-- ============================================================
--  ECS Security Systems — Installer
--  HellBreezMix/turret
-- ============================================================

local component  = require("component")
local filesystem = require("filesystem")
local term       = require("term")

local URL          = "https://raw.githubusercontent.com/HellBreezMix/turret/main/turret.lua"
local INSTALL_PATH = "/home/turret.lua"

local function cprint(msg, color)
  if component.isAvailable("gpu") then
    local gpu = component.gpu
    local old = gpu.setForeground(color or 0xFFFFFF)
    print(msg)
    gpu.setForeground(old)
  else
    print(msg)
  end
end

local function fail(msg)
  cprint("[ОШИБКА] " .. msg, 0xFF3333)
  return false
end

local function ok(msg)
  cprint("[OK] " .. msg, 0x22DD55)
end

local function info(msg)
  cprint("[..] " .. msg, 0xFFD700)
end

if not component.isAvailable("internet") then
  return fail("Нет Internet Card!")
end

local internet = require("internet")

term.clear()
cprint("╔══════════════════════════════════════╗", 0x00FFBB)
cprint("║   ECS® Security Systems Installer    ║", 0x00FFBB)
cprint("╚══════════════════════════════════════╝", 0x00FFBB)
print()
info("Источник: HellBreezMix/turret")
info("Установка: " .. INSTALL_PATH)
print()
info("Скачиваю...")

local handle, err = internet.request(URL)
if not handle then
  return fail("Не удалось подключиться: " .. tostring(err))
end

local chunks = {}
local success, reason = pcall(function()
  for chunk in handle do
    table.insert(chunks, chunk)
  end
end)

if not success then
  return fail("Ошибка загрузки: " .. tostring(reason))
end

local content = table.concat(chunks)

if #content < 100 then
  return fail("Файл пустой или 404. Проверь, что turret.lua есть в репо.")
end

local dir = filesystem.path(INSTALL_PATH)
if dir and dir ~= "" and not filesystem.exists(dir) then
  filesystem.makeDirectory(dir)
end

local f, ferr = io.open(INSTALL_PATH, "w")
if not f then
  return fail("Не могу записать файл: " .. tostring(ferr))
end
f:write(content)
f:close()

ok("Установлено: " .. INSTALL_PATH)

-- Ярлык в /bin
local binLink = "/bin/turret"
pcall(function()
  if filesystem.exists(binLink) then
    filesystem.remove(binLink)
  end
  filesystem.link(INSTALL_PATH, binLink)
  ok("Ярлык: /bin/turret")
end)

print()
cprint("Запуск:  turret", 0x00FFBB)
cprint("Готово!", 0x00FFBB)