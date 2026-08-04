----------------------------------------------------------
-- TurretOS
-- config.lua
----------------------------------------------------------


----------------------------------------------------------
-- Module path
----------------------------------------------------------

package.path =
    "/home/TurretOS/?.lua;"
    ..
    package.path



local config = {}



----------------------------------------------------------
-- Version
----------------------------------------------------------

config.version = "0.1.0"



----------------------------------------------------------
-- General
----------------------------------------------------------

config.debug = false

config.showUI = true



----------------------------------------------------------
-- Turret settings
----------------------------------------------------------

config.shaftLength = 2


config.loopDelay = 0.05


config.fireDelay = 0.15



----------------------------------------------------------
-- Detector settings
----------------------------------------------------------

config.scan = {


    radius = 32,


    players = true,


    mobs = true,


    passive = false


}



----------------------------------------------------------
-- Whitelist
----------------------------------------------------------

config.whitelist = {


    hellbreez = true,


    lofland = true


}



----------------------------------------------------------
-- Target priority
----------------------------------------------------------

config.priority = {


    players = 100,


    hostile = 50,


    passive = 10


}



----------------------------------------------------------
-- Interface
----------------------------------------------------------

config.ui = {


    title = "TurretOS",


    language = "ru",


    refresh = 0.2


}



----------------------------------------------------------
-- Logs
----------------------------------------------------------

config.logs = {


    enabled = true,


    directory =
        "/home/TurretOS/logs",


    history =
        "/home/TurretOS/logs/history.log",


    kills =
        "/home/TurretOS/logs/kills.log",


    errors =
        "/home/TurretOS/logs/errors.log"


}



----------------------------------------------------------
-- Statistics
----------------------------------------------------------

config.stats = {


    file =
        "/home/TurretOS/stats.dat",


    autosave = 60


}



----------------------------------------------------------
-- GUI colors
----------------------------------------------------------

config.colors = {


    background = 0x1E1E1E,


    panel = 0x2B2B2B,


    border = 0x555555,


    text = 0xFFFFFF,


    green = 0x33CC33,


    yellow = 0xFFFF55,


    orange = 0xFFAA00,


    red = 0xFF4444,


    blue = 0x3399FF


}



----------------------------------------------------------
-- Create directories
----------------------------------------------------------

local filesystem =
    require("filesystem")



if not filesystem.exists(
    config.logs.directory
)
then

    filesystem.makeDirectory(
        config.logs.directory
    )

end



----------------------------------------------------------

return config
