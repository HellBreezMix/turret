----------------------------------------------------------
-- TurretOS
-- logger.lua
----------------------------------------------------------

local config = require("config")

local logger = {}

----------------------------------------------------------
-- Статистика
----------------------------------------------------------

local stats = {
    shots = 0,
    kills = 0,
    players = 0,
    mobs = 0,
    detected = 0,
    startTime = computer.uptime()
}

----------------------------------------------------------
-- Создание файла
----------------------------------------------------------

local function touch(path)
    local fs = require("filesystem")

    if not fs.exists(path) then
        local file = io.open(path, "w")
        if file then
            file:close()
        end
    end
end

----------------------------------------------------------
-- Инициализация
----------------------------------------------------------

function logger.init()

    touch(config.logs.history)
    touch(config.logs.kills)
    touch(config.logs.errors)

    logger.history("TurretOS запущена")

end

----------------------------------------------------------
-- Время
----------------------------------------------------------

local function timestamp()

    local t = os.date("*t")

    return string.format(
        "%02d:%02d:%02d",
        t.hour,
        t.min,
        t.sec
    )

end

----------------------------------------------------------
-- Запись строки
----------------------------------------------------------

local function write(path, text)

    local file = io.open(path, "a")

    if not file then
        return
    end

    file:write(text .. "\n")

    file:close()

end

----------------------------------------------------------
-- История
----------------------------------------------------------

function logger.history(text)

    local line =
        "[" ..
        timestamp() ..
        "] " ..
        text

    write(config.logs.history, line)

    if config.debug then
        print(line)
    end

end

----------------------------------------------------------
-- Ошибки
----------------------------------------------------------

function logger.error(text)

    local line =
        "[" ..
        timestamp() ..
        "] ERROR: " ..
        text

    write(config.logs.errors, line)

    io.stderr:write(line .. "\n")

end

----------------------------------------------------------
-- Уничтожение цели
----------------------------------------------------------

function logger.kill(target)

    local line =
        "[" ..
        timestamp() ..
        "] " ..
        target

    write(config.logs.kills, line)

    stats.kills = stats.kills + 1

end

----------------------------------------------------------
-- Статистика
----------------------------------------------------------

function logger.addShot()

    stats.shots = stats.shots + 1

end

function logger.addPlayer()

    stats.players = stats.players + 1

end

function logger.addMob()

    stats.mobs = stats.mobs + 1

end

function logger.addDetection()

    stats.detected = stats.detected + 1

end

----------------------------------------------------------
-- Получение статистики
----------------------------------------------------------

function logger.getStats()

    return stats

end

----------------------------------------------------------
-- Сохранение статистики
----------------------------------------------------------

function logger.save()

    local file = io.open(config.stats.file, "w")

    if not file then
        return
    end

    file:write(stats.shots .. "\n")
    file:write(stats.kills .. "\n")
    file:write(stats.players .. "\n")
    file:write(stats.mobs .. "\n")
    file:write(stats.detected .. "\n")

    file:close()

end

----------------------------------------------------------
-- Загрузка статистики
----------------------------------------------------------

function logger.load()

    local file = io.open(config.stats.file, "r")

    if not file then
        return
    end

    stats.shots = tonumber(file:read()) or 0
    stats.kills = tonumber(file:read()) or 0
    stats.players = tonumber(file:read()) or 0
    stats.mobs = tonumber(file:read()) or 0
    stats.detected = tonumber(file:read()) or 0

    file:close()

end

----------------------------------------------------------

return logger