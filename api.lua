----------------------------------------------------------
-- TurretOS
-- api.lua
--
-- Hardware interface:
-- OpenSecurity Energy Turret
-- OpenSecurity Entity Detector
----------------------------------------------------------

local component = require("component")
local config = require("config")

local api = {}

----------------------------------------------------------
-- Components
----------------------------------------------------------

local turret = nil
local detector = nil


----------------------------------------------------------
-- Initialization
----------------------------------------------------------

function api.init()

    if component.isAvailable("os_energyturret") then
        turret = component.os_energyturret
    else
        return false, "Energy Turret not found"
    end


    if component.isAvailable("os_entdetector") then
        detector = component.os_entdetector
    else
        return false, "Entity Detector not found"
    end


    return true

end


----------------------------------------------------------
-- Turret power
----------------------------------------------------------

function api.powerOn()

    if not turret then
        return false
    end

    local ok, err = pcall(function()

        turret.powerOn()

    end)

    return ok, err

end



function api.powerOff()

    if not turret then
        return false
    end

    local ok, err = pcall(function()

        turret.powerOff()

    end)

    return ok, err

end



function api.isPowered()

    if not turret then
        return false
    end

    local ok, result = pcall(function()

        return turret.isPowered()

    end)


    if ok then
        return result
    end

    return false

end



----------------------------------------------------------
-- Combat mode
----------------------------------------------------------

function api.arm(state)

    if not turret then
        return false
    end


    local ok, err = pcall(function()

        turret.setArmed(state)

    end)


    return ok, err

end



function api.isReady()

    if not turret then
        return false
    end


    local ok, result = pcall(function()

        return turret.isReady()

    end)


    if ok then
        return result
    end


    return false

end



----------------------------------------------------------
-- Shaft
----------------------------------------------------------

function api.extend()

    if not turret then
        return false
    end


    local ok, result = pcall(function()

        return turret.extendShaft(
            config.shaftLength
        )

    end)


    return ok, result

end



function api.getShaftLength()

    if not turret then
        return 0
    end


    local ok, result = pcall(function()

        return turret.getShaftLength()

    end)


    if ok then
        return result
    end


    return 0

end
----------------------------------------------------------
-- Entity Detector
----------------------------------------------------------

function api.scanPlayers()

    if not detector then
        return {}
    end


    local ok, result = pcall(function()

        return detector.scanPlayers()

    end)


    if ok and result then
        return result
    end


    return {}

end



function api.scanEntities()

    if not detector then
        return {}
    end


    local ok, result = pcall(function()

        return detector.scanEntities()

    end)


    if ok and result then
        return result
    end


    return {}

end



----------------------------------------------------------
-- Target processing
----------------------------------------------------------

function api.isWhitelisted(name)

    if not name then
        return false
    end


    return config.whitelist[name] == true

end



----------------------------------------------------------
-- Distance calculation
----------------------------------------------------------

function api.distance(entity)

    if not entity then
        return 9999
    end


    local x = entity.x or 0
    local y = entity.y or 0
    local z = entity.z or 0


    return math.sqrt(
        x * x +
        y * y +
        z * z
    )

end



----------------------------------------------------------
-- Detect all targets
----------------------------------------------------------

function api.getTargets()

    local targets = {}


    ------------------------------------------------------
    -- Players
    ------------------------------------------------------

    if config.scan.players then

        local players = api.scanPlayers()


        for _, player in pairs(players) do


            if not api.isWhitelisted(player.name) then

                player.type = "player"
                player.priority =
                    config.priority.players

                player.distance =
                    api.distance(player)


                table.insert(
                    targets,
                    player
                )

            end

        end

    end



    ------------------------------------------------------
    -- Entities
    ------------------------------------------------------

    if config.scan.mobs then

        local entities = api.scanEntities()


        for _, entity in pairs(entities) do


            entity.type = "mob"


            entity.distance =
                api.distance(entity)


            entity.priority =
                config.priority.hostile


            table.insert(
                targets,
                entity
            )

        end

    end



    return targets

end



----------------------------------------------------------
-- Target sorting
----------------------------------------------------------

function api.sortTargets(targets)

    table.sort(
        targets,
        function(a,b)


            if a.priority ~= b.priority then

                return a.priority > b.priority

            end


            return a.distance < b.distance


        end
    )


    return targets

end



----------------------------------------------------------
-- Get best target
----------------------------------------------------------

function api.getBestTarget()

    local targets =
        api.getTargets()


    if #targets == 0 then
        return nil
    end


    api.sortTargets(targets)


    return targets[1]

end
----------------------------------------------------------
-- Aiming calculations
----------------------------------------------------------

function api.calculateAim(target)

    if not target then
        return nil, nil
    end


    local x = target.x or 0
    local y = target.y or 0
    local z = target.z or 0


    ------------------------------------------------------
    -- Horizontal angle
    ------------------------------------------------------

    local yaw =
        math.deg(
            math.atan2(
                z,
                x
            )
        )


    yaw = yaw + 90


    if yaw < 0 then
        yaw = yaw + 360
    end



    ------------------------------------------------------
    -- Vertical angle
    ------------------------------------------------------

    local distance =
        math.sqrt(
            x * x +
            z * z
        )


    local pitch =
        -math.deg(
            math.atan2(
                y,
                distance
            )
        )


    return yaw, pitch

end



----------------------------------------------------------
-- Move turret
----------------------------------------------------------

function api.moveToTarget(target)

    if not turret or not target then
        return false
    end


    local yaw, pitch =
        api.calculateAim(target)


    if not yaw or not pitch then
        return false
    end



    local ok, err =
        pcall(function()

            turret.moveTo(
                yaw,
                pitch
            )

        end)


    return ok, err

end



----------------------------------------------------------
-- Current position
----------------------------------------------------------

function api.getAngles()

    if not turret then
        return 0,0
    end


    local yaw = 0
    local pitch = 0


    pcall(function()

        yaw =
            turret.getYaw()

        pitch =
            turret.getPitch()

    end)


    return yaw, pitch

end



----------------------------------------------------------
-- Fire
----------------------------------------------------------

function api.fire()

    if not turret then
        return false
    end


    local ok, err =
        pcall(function()

            turret.fire()

        end)


    return ok, err

end



----------------------------------------------------------
-- Full preparation
----------------------------------------------------------

function api.prepare()

    local result, err =
        api.init()


    if not result then
        return false, err
    end



    api.powerOn()

    api.extend()

    api.arm(true)


    return true

end



----------------------------------------------------------
-- Status
----------------------------------------------------------

function api.status()

    return {

        powered =
            api.isPowered(),

        ready =
            api.isReady(),

        shaft =
            api.getShaftLength(),

        yaw,
        pitch =
            api.getAngles()

    }

end



----------------------------------------------------------
-- Debug information
----------------------------------------------------------

function api.debug()

    local status =
        api.status()


    print(
        "Powered:",
        status.powered
    )

    print(
        "Ready:",
        status.ready
    )

    print(
        "Shaft:",
        status.shaft
    )


end



----------------------------------------------------------

return api