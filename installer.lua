----------------------------------------------------------
-- TurretOS Installer
-- installer.lua
----------------------------------------------------------

local filesystem = require("filesystem")
local shell = require("shell")


local VERSION = "0.1.0"


----------------------------------------------------------
-- Repository
----------------------------------------------------------

local REPO =
"https://raw.githubusercontent.com/HellBreezMix/turret/main/"



----------------------------------------------------------
-- Paths
----------------------------------------------------------

local INSTALL_DIR =
"/home/TurretOS"


local files = {

    "main.lua",
    "api.lua",
    "logger.lua",
    "config.lua"

}



----------------------------------------------------------
-- Helpers
----------------------------------------------------------

local function printLine(text)

    print(
        "[TurretOS] "
        ..
        text
    )

end



local function download(file)

    local url =
        REPO
        ..
        file


    local path =
        INSTALL_DIR
        ..
        "/"
        ..
        file



    printLine(
        "Загрузка "
        ..
        file
    )


    local command =
        "wget -f "
        ..
        url
        ..
        " "
        ..
        path



    local result =
        shell.execute(command)



    return result

end



----------------------------------------------------------
-- Banner
----------------------------------------------------------

print(
[[
====================================
        TurretOS Installer
====================================

Версия: ]]
..
VERSION
..
[[

]]
)



----------------------------------------------------------
-- Create directory
----------------------------------------------------------

if not filesystem.exists(
    INSTALL_DIR
) then

    printLine(
        "Создание папки"
    )


    filesystem.makeDirectory(
        INSTALL_DIR
    )

end



----------------------------------------------------------
-- Download files
----------------------------------------------------------

for _, file in ipairs(files) do

    local ok =
        download(file)


    if not ok then

        printLine(
            "Ошибка загрузки: "
            ..
            file
        )

        return

    end

end



----------------------------------------------------------
-- Startup
----------------------------------------------------------

local startup =
[[
------------------------------------------------
-- TurretOS Startup
------------------------------------------------

shell.execute("/home/TurretOS/main.lua")
]]


local file =
io.open(
"/home/startup.lua",
"w"
)


if file then

    file:write(
        startup
    )

    file:close()

    printLine(
        "Автозапуск установлен"
    )

end



----------------------------------------------------------
-- Finish
----------------------------------------------------------

print(
[[
====================================

TurretOS установлен!

Запуск:
lua /home/TurretOS/main.lua

Перезагрузка:
reboot

====================================
]]
)