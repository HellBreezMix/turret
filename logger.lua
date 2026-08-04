----------------------------------------------------------
-- TurretOS
-- logger.lua
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

local filesystem = require("filesystem")



local logger = {}



----------------------------------------------------------
-- Statistics
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
-- Create file
----------------------------------------------------------

local function touch(path)


    if not filesystem.exists(path) then


        local file =
            io.open(
                path,
                "w"
            )



        if file then

            file:close()

        end


    end


end



----------------------------------------------------------
-- Initialize
----------------------------------------------------------

function logger.init()


    touch(
        config.logs.history
    )


    touch(
        config.logs.kills
    )


    touch(
        config.logs.errors
    )



    logger.history(
        "TurretOS запущена"
    )


end



----------------------------------------------------------
-- Time
----------------------------------------------------------

local function timestamp()


    local t =
        os.date("*t")



    return string.format(

        "%02d:%02d:%02d",

        t.hour,

        t.min,

        t.sec

    )


end



----------------------------------------------------------
-- Write
----------------------------------------------------------

local function write(path,text)


    local file =
        io.open(
            path,
            "a"
        )



    if not file then

        return

    end



    file:write(
        text
        ..
        "\n"
    )



    file:close()


end



----------------------------------------------------------
-- History
----------------------------------------------------------

function logger.history(text)


    if not config.logs.enabled then

        return

    end



    local line =

        "["

        ..

        timestamp()

        ..

        "] "

        ..

        text




    write(

        config.logs.history,

        line

    )



    if config.debug then

        print(line)

    end


end



----------------------------------------------------------
-- Error
----------------------------------------------------------

function logger.error(text)


    local line =

        "["

        ..

        timestamp()

        ..

        "] ERROR: "

        ..

        text




    write(

        config.logs.errors,

        line

    )



    if config.debug then

        print(line)

    end


end



----------------------------------------------------------
-- Kill log
----------------------------------------------------------

function logger.kill(target)


    local line =

        "["

        ..

        timestamp()

        ..

        "] "

        ..

        target




    write(

        config.logs.kills,

        line

    )



    stats.kills =
        stats.kills + 1


end



----------------------------------------------------------
-- Counters
----------------------------------------------------------

function logger.addShot()

    stats.shots =
        stats.shots + 1

end




function logger.addPlayer()

    stats.players =
        stats.players + 1

end




function logger.addMob()

    stats.mobs =
        stats.mobs + 1

end




function logger.addDetection()

    stats.detected =
        stats.detected + 1

end



----------------------------------------------------------
-- Get stats
----------------------------------------------------------

function logger.getStats()

    return stats

end



----------------------------------------------------------
-- Save
----------------------------------------------------------

function logger.save()


    local file =
        io.open(
            config.stats.file,
            "w"
        )



    if not file then

        return false

    end



    file:write(
        stats.shots
        ..
        "\n"
    )


    file:write(
        stats.kills
        ..
        "\n"
    )


    file:write(
        stats.players
        ..
        "\n"
    )


    file:write(
        stats.mobs
        ..
        "\n"
    )


    file:write(
        stats.detected
        ..
        "\n"
    )



    file:close()



    return true

end



----------------------------------------------------------
-- Load
----------------------------------------------------------

function logger.load()


    local file =
        io.open(
            config.stats.file,
            "r"
        )



    if not file then

        return false

    end




    stats.shots =

        tonumber(
            file:read()
        )
        or
        0



    stats.kills =

        tonumber(
            file:read()
        )
        or
        0




    stats.players =

        tonumber(
            file:read()
        )
        or
        0




    stats.mobs =

        tonumber(
            file:read()
        )
        or
        0




    stats.detected =

        tonumber(
            file:read()
        )
        or
        0




    file:close()



    return true

end



----------------------------------------------------------

return logger
