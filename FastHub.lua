-- FastHub universal loader. Add supported Roblox places to this table.
local SCRIPT_FILES = {
    [100342593906737] = "RNG%20Height.lua",
    [109949693269081] = "Tycoon%2C%20but%20one%20dropper%21.lua",
    [106198175232796] = "FarmHub.lua",
    [78440417139286] = "Plant%20Incremental.lua"
}
local BASE_URL = "https://raw.githubusercontent.com/WrldHub/WrldHub/main/"
local function notify(message)
    warn("[FastHub] " .. message)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "FastHub", Text = message, Duration = 7
        })
    end)
end

local file = SCRIPT_FILES[game.PlaceId]
if not file then
    notify("FastHub doesn't exist for this game.")
    return
end

local downloaded, source = pcall(function()
    return game:HttpGet(BASE_URL .. file)
end)
if not downloaded or type(source) ~= "string" or source == "" then
    notify("FastHub couldn't download the script. Please try again.")
    return
end
local script, compileError = loadstring(source)
if not script then
    notify("FastHub couldn't load the script.")
    warn("[FastHub] " .. tostring(compileError))
    return
end
local ran, runtimeError = pcall(script)
if not ran then
    notify("FastHub couldn't start the script.")
    warn("[FastHub] " .. tostring(runtimeError))
end
