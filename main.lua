----------------------------------------------------------
-- TurretOS
-- main.lua
--
-- Main control system
----------------------------------------------------------

local config = require("config")
local api = require("api")
local logger = require("logger")


----------------------------------------------------------
-- Variables
----------------------------------------------------------

local running = true

local currentTarget = nil

local lastShot = 0


----------------------------------------------------------
-- Initialization
----------------------------------------------------------

local function initialize()

    print("")
    print("==============================")
    print("        TurretOS v1.0")
    print("==============================")
    print("")


    logger.init()

    logger.load()


    logger.history(
        "Инициализация системы"
    )


    local ok, err =
        api.prepare()


    if not ok then

        logger.error(
            err
        )

        print(
            "Ошибка запуска:"
        )

        print(
            err
        )

        return false

    end


    logger.history(
        "Турель готова к работе"
    )


    return true

end



----------------------------------------------------------
-- Target validation
----------------------------------------------------------

local function validateTarget(target)

    if not target then
        return false
    end


    if target.name then

        if api.isWhitelisted(
            target.name
        ) then

            return false

        end

    end


    return true

end



----------------------------------------------------------
-- Target selection
----------------------------------------------------------

local function selectTarget()

    local target =
        api.getBestTarget()


    if not target then

        currentTarget = nil

        return nil

    end



    if validateTarget(target) then


        if currentTarget ~= target then

            logger.history(
                "Новая цель: "
                ..
                (target.name or "unknown")
            )


        end


        currentTarget = target

    end


    return currentTarget

end
----------------------------------------------------------
-- Aiming and firing
----------------------------------------------------------

local function aimAtTarget(target)

    if not target then
        return false
    end


    local ok, err =
        api.moveToTarget(target)


    if not ok then

        logger.error(
            "Ошибка наведения: "
            ..
            tostring(err)
        )

        return false

    end


    return true

end



----------------------------------------------------------
-- Fire control
----------------------------------------------------------

local function canFire()

    local now =
        computer.uptime()


    if now - lastShot <
        config.fireDelay then

        return false

    end


    return true

end



local function fireAtTarget(target)

    if not target then
        return false
    end


    if not api.isReady() then

        logger.history(
            "Турель не готова"
        )

        return false

    end



    if not canFire() then
        return false
    end



    local ok, err =
        api.fire()


    if not ok then

        logger.error(
            "Ошибка выстрела: "
            ..
            tostring(err)
        )

        return false

    end



    lastShot =
        computer.uptime()


    logger.addShot()


    logger.history(
        "Выстрел по: "
        ..
        (target.name or "unknown")
    )


    return true

end



----------------------------------------------------------
-- Target processing
----------------------------------------------------------

local function processTarget(target)

    if not target then

        return

    end



    logger.addDetection()



    local aimed =
        aimAtTarget(target)


    if not aimed then

        return

    end



    os.sleep(
        config.fireDelay
    )



    fireAtTarget(target)

end



----------------------------------------------------------
-- Target lost check
----------------------------------------------------------

local function checkTarget()

    if not currentTarget then
        return
    end


    local targets =
        api.getTargets()


    for _, target in pairs(targets) do

        if target.name ==
            currentTarget.name then

            return

        end

    end



    logger.history(
        "Цель потеряна"
    )


    currentTarget = nil

end



----------------------------------------------------------
-- Main cycle
----------------------------------------------------------

local function update()

    checkTarget()


    local target =
        selectTarget()


    if target then

        processTarget(target)

    end

end
----------------------------------------------------------
-- Interface
----------------------------------------------------------

local function clearScreen()

    term.clear()
    term.setCursor(1,1)

end



local function printLine(text)

    print(
        tostring(text)
    )

end



local function drawInterface()

    if not config.showUI then
        return
    end


    clearScreen()



    printLine(
        "========================================"
    )

    printLine(
        "              TurretOS v"
        ..
        config.version
    )

    printLine(
        "========================================"
    )


    local status =
        api.status()



    printLine("")


    printLine(
        "Статус:"
    )


    if status.powered then

        printLine(
            "  Питание: ВКЛ"
        )

    else

        printLine(
            "  Питание: ВЫКЛ"
        )

    end



    if status.ready then

        printLine(
            "  Готовность: ГОТОВА"
        )

    else

        printLine(
            "  Готовность: НЕТ"
        )

    end



    printLine(
        "  Ствол: "
        ..
        tostring(status.shaft)
    )



    printLine("")

    printLine(
        "Текущая цель:"
    )


    if currentTarget then


        printLine(
            "  Имя: "
            ..
            (
                currentTarget.name
                or
                "Неизвестно"
            )
        )


        printLine(
            "  Тип: "
            ..
            (
                currentTarget.type
                or
                "?"
            )
        )


        printLine(
            "  Расстояние: "
            ..
            string.format(
                "%.1f",
                currentTarget.distance
                or
                0
            )
            ..
            " м"
        )


    else


        printLine(
            "  Нет цели"
        )


    end



    printLine("")


    local stats =
        logger.getStats()



    printLine(
        "Статистика:"
    )


    printLine(
        "  Выстрелов: "
        ..
        stats.shots
    )


    printLine(
        "  Уничтожено: "
        ..
        stats.kills
    )


    printLine(
        "  Обнаружено: "
        ..
        stats.detected
    )



    printLine("")


    local yaw, pitch =
        api.getAngles()



    printLine(
        "Наведение:"
    )


    printLine(
        "  YAW: "
        ..
        math.floor(yaw)
        ..
        "°"
    )


    printLine(
        "  PITCH: "
        ..
        math.floor(pitch)
        ..
        "°"
    )



    printLine("")


    printLine(
        "========================================"
    )

end



----------------------------------------------------------
-- Safe main update
----------------------------------------------------------

local function safeUpdate()

    local ok, err =
        pcall(function()

            update()

        end)


    if not ok then

        logger.error(
            tostring(err)
        )

    end


end
----------------------------------------------------------
-- Runtime control
----------------------------------------------------------

local lastSave =
    computer.uptime()



local function saveCheck()

    local now =
        computer.uptime()


    if now - lastSave >=
        config.stats.autosave then


        logger.save()


        lastSave =
            now


        logger.history(
            "Статистика сохранена"
        )

    end

end



----------------------------------------------------------
-- Shutdown
----------------------------------------------------------

local function shutdown()

    logger.history(
        "Завершение работы TurretOS"
    )


    logger.save()


    api.arm(false)


    api.powerOff()


    print("")

    print(
        "TurretOS остановлена"
    )

end



----------------------------------------------------------
-- Main loop
----------------------------------------------------------

local function run()

    while running do


        safeUpdate()


        drawInterface()


        saveCheck()


        os.sleep(
            config.loopDelay
        )


    end

end



----------------------------------------------------------
-- Start
----------------------------------------------------------

local function main()

    local ok =
        initialize()



    if not ok then

        return

    end



    local event =
        require("event")



    event.listen(
        "interrupted",
        function()

            running = false

        end
    )



    run()



    shutdown()

end



----------------------------------------------------------
-- Launch
----------------------------------------------------------

main()