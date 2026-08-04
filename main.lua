----------------------------------------------------------
-- TurretOS
-- main.lua
--
-- Main control system
----------------------------------------------------------

----------------------------------------------------------
-- Module path
----------------------------------------------------------

package.path =
    "/home/TurretOS/?.lua;"
    ..
    package.path


----------------------------------------------------------
-- Modules
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

local lastSave =
    computer.uptime()


----------------------------------------------------------
-- Initialization
----------------------------------------------------------

local function initialize()

    print("")
    print("========================================")
    print("          TurretOS v" .. config.version)
    print("========================================")
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
            tostring(err)
        )


        print(
            "Ошибка запуска:"
        )


        print(
            tostring(err)
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

            logger.history(
                "Игрок в белом списке: "
                ..
                target.name
            )

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
                (
                    target.name
                    or
                    "unknown"
                )
            )

        end


        currentTarget = target


    end



    return currentTarget

end



----------------------------------------------------------
-- Aiming
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
        (
            target.name
            or
            "unknown"
        )
    )



    return true

end



----------------------------------------------------------
-- Process target
----------------------------------------------------------

local function processTarget(target)

    if not target then
        return
    end



    logger.addDetection()



    if aimAtTarget(target) then


        os.sleep(
            config.fireDelay
        )


        fireAtTarget(target)


    end

end



----------------------------------------------------------
-- Check lost target
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
-- Update
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

    term.setCursor(
        1,
        1
    )

end



local function drawInterface()


    if not config.showUI then
        return
    end



    clearScreen()



    print("========================================")

    print(
        "          TurretOS v"
        ..
        config.version
    )

    print("========================================")

    print("")



    local status =
        api.status()



    print(
        "Питание: "
        ..
        tostring(status.powered)
    )



    print(
        "Готовность: "
        ..
        tostring(status.ready)
    )



    print(
        "Ствол: "
        ..
        tostring(status.shaft)
    )



    print("")

    print(
        "Цель:"
    )



    if currentTarget then

        print(
            currentTarget.name
            or
            "unknown"
        )

        print(
            "Тип: "
            ..
            tostring(
                currentTarget.type
            )
        )

        print(
            "Расстояние: "
            ..
            string.format(
                "%.1f",
                currentTarget.distance
                or
                0
            )
        )


    else

        print(
            "Нет цели"
        )

    end



    print("")



    local stats =
        logger.getStats()



    print(
        "Выстрелов: "
        ..
        stats.shots
    )


    print(
        "Обнаружено: "
        ..
        stats.detected
    )



    print("========================================")

end



----------------------------------------------------------
-- Safe update
----------------------------------------------------------

local function safeUpdate()


    local ok, err =
        pcall(
            update
        )



    if not ok then

        logger.error(
            tostring(err)
        )

    end


end



----------------------------------------------------------
-- Save check
----------------------------------------------------------

local function saveCheck()


    local now =
        computer.uptime()



    if now - lastSave >=
        config.stats.autosave then


        logger.save()



        lastSave =
            now

    end

end



----------------------------------------------------------
-- Shutdown
----------------------------------------------------------

local function shutdown()


    logger.history(
        "Остановка TurretOS"
    )



    logger.save()



    api.arm(false)

    api.powerOff()



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


    if not initialize() then

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



main()
