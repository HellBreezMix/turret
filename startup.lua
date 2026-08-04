----------------------------------------------------------
-- TurretOS
-- startup.lua
----------------------------------------------------------

local filesystem = require("filesystem")


local path = "/home/TurretOS/main.lua"



if filesystem.exists(path) then

    shell.execute(path)

else

    print(
        "TurretOS не найден"
    )

    print(
        "Ожидается:"
    )

    print(path)

end