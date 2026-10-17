-- Wrld Hub: standalone Roblox client script. Run this entire file together.
-- Only start in the supported Roblox place.
if game.PlaceId ~= 106198175232796 then
    local message = "This script only works in FarmHub's supported game."
    warn("[FastHub] " .. message)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "Wrong game", Text = message, Duration = 6
        })
    end)
    return
end

-- Features call the game's own client module, so they send the same requests its UI sends.
-- The few controls with dimmed text are saved but not wired to the game.
-- Right Shift hides/shows the window by default; change the key in Settings.
-- Settings > Unload stops everything and removes it.

-- Increment the release version when publishing changes to this script.
local SCRIPT_VERSION = "2026.10.18.2"
local SCRIPT_URL = "https://raw.githubusercontent.com/WrldHub/WrldHub/main/FarmHub.lua"
local launchFarmHub
launchFarmHub = function(importedSettings)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")

local player = Players.LocalPlayer
assert(player, "Run this script on a Roblox client.")
local playerGui = player:WaitForChild("PlayerGui")

local INTERVAL = 60 * 60
local TELEPORT_DELAY = 5
local WORLD_BOSS_NAME = "Demon Melyode" -- EnemyName of the world boss
local WORLD_BOSS_MAP = "Sins Kingdom"
local WORLD_BOSS_WINDOW = 15 * 60     -- still go if enabled this soon after the start time
local WORLD_BOSS_MAX_HOLD = 20 * 60   -- safety cap on the pause
local BOSS_APPEAR_TIMEOUT = 15        -- give up if the boss never shows after arriving
local BOSS_GONE_CONFIRM = 3           -- boss must be missing this long to count as dead
local GAMEMODE_EXIT_DELAY = 3         -- seconds to wait after leaving a dungeon/trial
local _COMMANDMENT_INTERVAL = 5
local SAVE_FILE = "FarmHub_settings.json"
-- Any other map with an active teleport folder counts as a dungeon/trial/gamemode.
local WORLD_MAPS = { ["Lobby"] = true }
local MAP_NAMES = {} -- Filled from the game's catalog before the UI is built.
local COMMANDMENTS = {
    "Love", "Truth", "Pacifism", "Patience", "Piety",
    "Purity", "Repose", "Reticence", "Selflessness", "Faith"
}
local DIFFICULTIES = { "Easy", "Medium", "Hard" }

-- Replace any earlier copy of this hub and the older standalone scripts it absorbs.
local env = getgenv and getgenv() or _G
if env.FarmHubUnload then
    pcall(env.FarmHubUnload)
end
env.CommandmentLoop = nil
local oldBossGui = playerGui:FindFirstChild("BossTeleportGui")
if oldBossGui then
    oldBossGui:Destroy()
end

local alive = true
local cleanedUp = false
local connections = {}

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    connections[#connections + 1] = connection
    return connection
end

-- Settings ---------------------------------------------------------------------------

local settings: {[string]: any} = {}
do
    if importedSettings then
        settings = importedSettings
    else
    local ok, raw = pcall(function()
        return readfile(SAVE_FILE)
    end)
    if ok and type(raw) == "string" then
        local decoded, data = pcall(function()
            return HttpService:JSONDecode(raw)
        end)
        if decoded and type(data) == "table" then
            settings = data
        end
    end
    end
end

local function saveSettings()
    pcall(function()
        writefile(SAVE_FILE, HttpService:JSONEncode(settings))
    end)
end

-- Version 2 wired most controls to the game. Anything that was only a saved placeholder
-- before is switched off once so nothing starts acting without being turned on.
if settings._version ~= 2 then
    local keep = {
        ["Bosses.WorldBoss"] = true,
        ["Bosses.PauseInGamemode"] = true,
        ["Sins.AutoCommandments"] = true,
        ["Session.AntiAfk"] = true,
        ["Session.Notifications"] = true,
        ["Priority.LeaveForPriority"] = true
    }
    for key, value in pairs(settings) do
        if value == true and not keep[key] then
            settings[key] = false
        end
    end
    settings._version = 2
end

-- Migrate the previous host/join toggles without enabling a disabled task.
if settings["Culling.Enabled"] == nil then
    settings["Culling.Enabled"] = settings["Culling.AutoCulling"] == true or settings["Culling.AutoJoin"] == true
end
if settings["Culling.Role"] == nil then settings["Culling.Role"] = settings["Culling.AutoJoin"] and "Player" or "Host" end
settings["Culling.AutoCulling"], settings["Culling.AutoJoin"] = false, false

-- Add Dragon Defense without resetting an existing custom priority order.
if type(settings["Priority.Order"]) == "table" and not table.find(settings["Priority.Order"], "Dragon Defense") then
    local order = settings["Priority.Order"]
    table.insert(order, table.find(order, "Quest") or table.find(order, "Mob Farm") or (#order + 1), "Dragon Defense")
end

-- Removed features must not resume from saved settings.
for key in pairs(settings) do
    if type(key) == "string" and (string.sub(key, 1, 11) == "Bosses.Farm"
        or string.sub(key, 1, 7) == "Summon."
        or string.sub(key, 1, 5) == "Feed."
        or string.sub(key, 1, 12) == "Deconstruct."
        or key == "Lobby.Fighter" or key == "Lobby.AutoTalents" or key == "Lobby.AutoTraits"
        or key == "Lobby.TalentsStopAt" or key == "Lobby.TraitsStopAt"
        or key == "Equipment.AutoEquipBest") then
        settings[key] = nil
    end
end

-- The old dungeon option meant "when cleared"; do not reuse it for an early exit.
if settings["Dungeon.Wave"] == nil then
    settings["Dungeon.Wave"] = 26
    settings["Dungeon.AutoLeave"] = false
end

local saveQueued = false
local function setSetting(key, value)
    settings[key] = value
    if saveQueued then return end
    saveQueued = true
    task.delay(1, function()
        saveQueued = false
        if alive then saveSettings() end
    end)
end

local function getSetting(key, default)
    if settings[key] == nil then
        settings[key] = default
    end
    return settings[key]
end

local menuKey = { capturing = false, button = nil, name = "RightShift" }
function menuKey.set(name)
    local ok, key = pcall(function() return Enum.KeyCode[name] end)
    if not ok or not key or key == Enum.KeyCode.Unknown or key == Enum.KeyCode.Escape then
        name = "RightShift"
    end
    menuKey.name = name
    menuKey.capturing = false
    setSetting("Session.MenuKey", name)
end
menuKey.set(getSetting("Session.MenuKey", "RightShift"))

-- UI toolkit -------------------------------------------------------------------------

-- Named profiles stay in this Potassium workspace, scoped to the Roblox account.
local configStore = { file = "FarmHub_configs_" .. player.UserId .. ".json", profiles = {}, bounds = {}, options = {} }
function configStore.copy(value, depth)
    depth = depth or 0
    if depth > 4 then error("Config nesting is too deep") end
    if type(value) == "table" then
        local result, count = {}, 0
        for key, item in pairs(value) do
            count = count + 1
            if count > 256 or (type(key) ~= "string" and type(key) ~= "number") then error("Invalid config table") end
            result[key] = configStore.copy(item, depth + 1)
        end
        return result
    end
    if type(value) == "number" then
        if value ~= value or math.abs(value) == math.huge then error("Invalid number in config") end
    elseif type(value) ~= "string" and type(value) ~= "boolean" then
        error("Unsupported value in config")
    end
    return value
end
function configStore.name(value)
    local name = type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
    assert(#name > 0 and #name <= 48 and not name:find("%c"), "Use a config name with 1-48 characters")
    return name
end
function configStore.snapshot(shared)
    local values = {}
    for key, value in pairs(settings) do
        if type(key) == "string" and key:sub(1, 8) ~= "Configs."
            and key:sub(1, 1) ~= "_" and (not shared or key:sub(1, 8) ~= "Webhook.") then
            values[key] = configStore.copy(value)
        end
    end
    return values
end
function configStore.validate(document)
    assert(type(document) == "table" and document.format == "FarmHubConfig" and document.version == 1,
        "Paste a FarmHub shared config (version 1)")
    assert(type(document.settings) == "table", "Config settings are missing")
    local values, recognized = {}, 0
    for key, value in pairs(document.settings) do
        if type(key) == "string" and key:sub(1, 8) ~= "Configs." and key:sub(1, 1) ~= "_" and settings[key] ~= nil then
            assert(type(value) == type(settings[key]), "Wrong value type for " .. key)
            local copied = configStore.copy(value)
            if key == "MobFarm.Mobs" or key == "Priority.Order" or key == "LevelUpgrades.Order"
                or key == "Slayers.StopAt" or key == "Slayers.Rarity" or key == "Talents.Queue" then
                local seen = {}
                assert(#copied <= 128, "Too many selections")
                for index, name in pairs(copied) do
                    assert(type(index) == "number" and index >= 1 and index <= #copied
                        and type(name) == "string" and not seen[name], "Invalid selections for " .. key)
                    seen[name] = true
                end
            end
            if key == "MobFarm.ByWorld" then
                for world, names in pairs(copied) do
                    assert(type(world) == "string" and type(names) == "table" and #names <= 128, "Invalid world selections")
                    local seen = {}
                    for index, name in pairs(names) do
                        assert(type(index) == "number" and index >= 1 and index <= #names
                            and type(name) == "string" and not seen[name], "Invalid mobs for " .. world)
                        seen[name] = true
                    end
                end
            end
            if key == "Bosses.ReturnSpot" and next(copied) then
                assert(type(copied.map) == "string" and type(copied.cframe) == "table" and #copied.cframe == 12,
                    "Invalid spawn point")
                for i = 1, 12 do assert(type(copied.cframe[i]) == "number", "Invalid spawn coordinates") end
            end
            local limits = configStore.bounds[key]
            if limits then copied = math.clamp(math.floor(copied + 0.5), limits[1], limits[2]) end
            local options = configStore.options[key]
            if type(copied) == "string" and options then
                assert(table.find(options, copied), "Unavailable option for " .. key .. ": " .. copied)
            end
            values[key] = copied
            recognized = recognized + 1
        end
    end
    assert(recognized > 0, "No supported settings in this config")
    return values
end
function configStore.document(name, shared)
    return { format = "FarmHubConfig", version = 1, name = name, settings = configStore.snapshot(shared) }
end
function configStore.persist(profiles)
    writefile(configStore.file, HttpService:JSONEncode({version = 1, profiles = profiles}))
    configStore.profiles = profiles
end
function configStore.save(name, document)
    name = configStore.name(name)
    configStore.validate(document)
    local profiles = table.clone(configStore.profiles)
    profiles[name] = document
    configStore.persist(profiles)
    return name
end
function configStore.import(raw, name)
    assert(type(raw) == "string" and #raw <= 100000, "Config text is too large")
    local document = HttpService:JSONDecode(raw)
    local values = configStore.validate(document)
    name = configStore.name(name ~= "" and name or document.name)
    configStore.save(name, {format = "FarmHubConfig", version = 1, name = name, settings = values})
    return name
end
function configStore.names()
    local names = {}
    for name in pairs(configStore.profiles) do names[#names + 1] = name end
    table.sort(names)
    return #names > 0 and names or {"--"}
end
do
    local ok, raw = pcall(readfile, configStore.file)
    if ok then
        local decoded, library = pcall(HttpService.JSONDecode, HttpService, raw)
        if decoded and type(library) == "table" and library.version == 1 and type(library.profiles) == "table" then
            for name, document in pairs(library.profiles) do
                if type(name) == "string" and type(document) == "table" then configStore.profiles[name] = document end
            end
        end
    end
end

local COLORS = {
    window = Color3.fromRGB(22, 23, 28),
    sidebar = Color3.fromRGB(16, 17, 21),
    card = Color3.fromRGB(30, 31, 38),
    stroke = Color3.fromRGB(46, 48, 58),
    box = Color3.fromRGB(40, 42, 52),
    boxHover = Color3.fromRGB(54, 56, 68),
    off = Color3.fromRGB(68, 70, 82),
    accent = Color3.fromRGB(138, 99, 210),
    star = Color3.fromRGB(245, 196, 66),
    text = Color3.fromRGB(232, 234, 240),
    dim = Color3.fromRGB(150, 155, 172)
}
local FONT = Enum.Font.Gotham
local FONTS = { medium = Enum.Font.GothamMedium, bold = Enum.Font.GothamBold }
local TEXT_SIZE = 13

local layoutCounter = 0
local function new(class, props, parent)
    local inst = Instance.new(class)
    for key, value in pairs(props) do
        inst[key] = value
    end
    if inst:IsA("GuiObject") then
        layoutCounter = layoutCounter + 1
        inst.LayoutOrder = layoutCounter
    end
    inst.Parent = parent
    return inst
end

local function round(target, radius)
    new("UICorner", { CornerRadius = UDim.new(0, radius) }, target)
end

local function hover(button, normal, over)
    connect(button.MouseEnter, function()
        button.BackgroundColor3 = over
    end)
    connect(button.MouseLeave, function()
        button.BackgroundColor3 = normal
    end)
end

local gui = new("ScreenGui", {
    Name = "FarmHubGui",
    ResetOnSpawn = false,
    DisplayOrder = 20,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling
}, playerGui)

-- The window resizes with the game window so it never hangs off the screen, and
-- re-centres whenever the game window changes size.
local window = new("Frame", {
    Name = "Window",
    BackgroundColor3 = COLORS.window,
    BorderSizePixel = 0
}, gui)
do
    local camera = workspace.CurrentCamera
    local function fitWindow()
        local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
        local width = math.clamp(math.floor(viewport.X - 24), 620, 880)
        local height = math.clamp(math.floor(viewport.Y - 24), 400, 560)
        window:SetAttribute("ExpandedSize", Vector2.new(width, height))
        if window:GetAttribute("Minimized") then return end
        window.Size = UDim2.fromOffset(width, height)
        window.Position = UDim2.new(0.5, -math.floor(width / 2), 0.5, -math.floor(height / 2))
    end
    fitWindow()
    if camera then
        connect(camera:GetPropertyChangedSignal("ViewportSize"), fitWindow)
    end
end
round(window, 10)
new("UIStroke", { Color = COLORS.stroke, Thickness = 1 }, window)

-- Left sidebar: title and one navigation button per tab.
local navList
do
    local sidebar = new("Frame", {
        Size = UDim2.new(0, 150, 1, 0),
        BackgroundColor3 = COLORS.sidebar,
        BorderSizePixel = 0
    }, window)
    round(sidebar, 10)
    -- Squares off the sidebar's right-hand corners, which should not be rounded.
    new("Frame", {
        Position = UDim2.new(1, -10, 0, 0),
        Size = UDim2.new(0, 10, 1, 0),
        BackgroundColor3 = COLORS.sidebar,
        BorderSizePixel = 0
    }, sidebar)
    new("TextLabel", {
        Position = UDim2.fromOffset(16, 14),
        Size = UDim2.new(1, -32, 0, 22),
        BackgroundTransparency = 1,
        Text = "Wrld Hub",
        TextColor3 = COLORS.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = FONTS.bold,
        TextSize = 18
    }, sidebar)
    new("TextLabel", {
        Position = UDim2.fromOffset(16, 36),
        Size = UDim2.new(1, -32, 0, 16),
        BackgroundTransparency = 1,
        Name = "MenuKeyHint",
        Text = menuKey.name .. ": hide/show",
        TextColor3 = COLORS.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = FONT,
        TextSize = 11
    }, sidebar)
    navList = new("Frame", {
        Position = UDim2.fromOffset(8, 66),
        Size = UDim2.new(1, -16, 1, -74),
        BackgroundTransparency = 1
    }, sidebar)
    new("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 4)
    }, navList)
end

-- Top bar: shows the open tab's name and is the handle for dragging the window.
local titleBar = new("TextLabel", {
    Name = "TitleBar",
    Position = UDim2.fromOffset(150, 0),
    Size = UDim2.new(1, -150, 0, 46),
    BackgroundTransparency = 1,
    Text = "",
    Active = true
}, window)
local tabTitle = new("TextLabel", {
    Name = "TabTitle",
    Position = UDim2.fromOffset(18, 0),
    Size = UDim2.new(1, -70, 1, 0),
    BackgroundTransparency = 1,
    Text = "",
    TextColor3 = COLORS.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Font = FONTS.bold,
    TextSize = 17
}, titleBar)

local body = new("Frame", {
    Position = UDim2.fromOffset(150, 46),
    Size = UDim2.new(1, -150, 1, -46),
    BackgroundTransparency = 1
}, window)

-- Minimize preserves running features and the button's screen position.
do
    local minimize = new("TextButton", {
        Name = "Minimize", Position = UDim2.new(1, -42, 0, 9),
        Size = UDim2.fromOffset(32, 28), BackgroundColor3 = COLORS.box,
        BorderSizePixel = 0, Text = "-", TextColor3 = COLORS.text,
        Font = FONTS.bold, TextSize = 20, AutoButtonColor = false, ZIndex = 5
    }, window)
    round(minimize, 5)
    hover(minimize, COLORS.box, COLORS.boxHover)
    local savedVisibility, savedTitle = {}, nil
    local function setMinimized(value)
        if not alive or cleanedUp or (window:GetAttribute("Minimized") == true) == value then return end
        local beforeWidth = window.Size.X.Offset
        window:SetAttribute("Minimized", value)
        if value then
            window:SetAttribute("ExpandedSize", Vector2.new(window.Size.X.Offset, window.Size.Y.Offset))
            savedTitle = tabTitle.Text
            for _, child in ipairs(window:GetChildren()) do
                if child:IsA("GuiObject") and child ~= titleBar and child ~= minimize then
                    savedVisibility[child] = child.Visible
                    child.Visible = false
                end
            end
            window.Size = UDim2.fromOffset(280, 46)
            titleBar.Position, titleBar.Size = UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1)
            tabTitle.Text = "Wrld Hub"
        else
            local expanded = window:GetAttribute("ExpandedSize") or Vector2.new(880, 560)
            window.Size = UDim2.fromOffset(expanded.X, expanded.Y)
            titleBar.Position, titleBar.Size = UDim2.fromOffset(150, 0), UDim2.new(1, -150, 0, 46)
            for child, visible in pairs(savedVisibility) do
                if child.Parent == window then child.Visible = visible end
            end
            table.clear(savedVisibility)
            tabTitle.Text = savedTitle or tabTitle.Text
        end
        -- Right-aligned button: move the window by the exact width difference.
        window.Position = UDim2.new(window.Position.X.Scale,
            window.Position.X.Offset + beforeWidth - window.Size.X.Offset,
            window.Position.Y.Scale, window.Position.Y.Offset)
        minimize.Text = value and "+" or "-"
    end
    connect(minimize.Activated, function() setMinimized(window:GetAttribute("Minimized") ~= true) end)
end

-- Favorites: every section card has a star in its title. While the Favorites tab is open
-- the starred cards are moved onto it whole, so every control in them works there; they go
-- back to their own tab when another tab is opened.
local favorites = { sections = {}, tab = nil, empty = nil }

function favorites.saved()
    local saved = settings["Favorites.Sections"]
    if type(saved) ~= "table" then
        saved = {}
        settings["Favorites.Sections"] = saved
    end
    return saved
end

function favorites.count()
    local count = 0
    for _, entry in ipairs(favorites.sections) do
        if favorites.saved()[entry.id] then
            count = count + 1
        end
    end
    return count
end

function favorites.place()
    local tab = favorites.tab
    local showing = tab ~= nil and tab.page.Visible
    local saved, count = favorites.saved(), 0
    for _, entry in ipairs(favorites.sections) do
        local on = saved[entry.id] == true
        entry.star.TextColor3 = on and COLORS.star or COLORS.off
        if on then
            count = count + 1
        end
        entry.frame.Parent = (on and showing) and tab.columns[(count - 1) % 2 + 1] or entry.home
    end
    if favorites.empty then
        favorites.empty.Visible = count == 0
    end
end

function favorites.toggle(id)
    local saved = favorites.saved()
    saved[id] = not saved[id] or nil
    setSetting("Favorites.Sections", saved)
    favorites.place()
end

-- Toggles starred by the first version of Favorites now star the section they sit in.
function favorites.adopt(section, key)
    local old = settings["Favorites.List"]
    local id = section:GetAttribute("FavoriteId")
    if id and type(old) == "table" and table.find(old, key) then
        favorites.saved()[id] = true
    end
end

local tabs = {}
local function selectTab(tab)
    for _, other in ipairs(tabs) do
        local selected = other == tab
        other.page.Visible = selected
        other.button.BackgroundTransparency = selected and 0 or 1
        other.label.TextColor3 = selected and COLORS.text or COLORS.dim
        other.marker.Visible = selected
    end
    tabTitle.Text = tab.name
    favorites.place()
end

local function addTab(name)
    local button = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundColor3 = COLORS.card,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false
    }, navList)
    round(button, 6)
    local marker = new("Frame", {
        Position = UDim2.fromOffset(0, 7),
        Size = UDim2.fromOffset(3, 18),
        BackgroundColor3 = COLORS.accent,
        BorderSizePixel = 0,
        Visible = false
    }, button)
    round(marker, 2)
    local label = new("TextLabel", {
        Position = UDim2.fromOffset(14, 0),
        Size = UDim2.new(1, -14, 1, 0),
        BackgroundTransparency = 1,
        Text = name,
        TextColor3 = COLORS.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = FONTS.medium,
        TextSize = 14
    }, button)

    local page = new("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = COLORS.off,
        CanvasSize = UDim2.new(),
        Visible = false
    }, body)

    local columns = {}
    local function updateCanvas()
        local height = 0
        for _, column in ipairs(columns) do
            height = math.max(height, column.AbsoluteSize.Y)
        end
        page.CanvasSize = UDim2.fromOffset(0, height + 22)
    end
    for index = 1, 2 do
        local column = new("Frame", {
            Size = UDim2.new(0.5, -20, 0, 0),
            Position = UDim2.new((index - 1) * 0.5, index == 1 and 16 or 4, 0, 4),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1
        }, page)
        new("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, 12)
        }, column)
        columns[index] = column
        connect(column:GetPropertyChangedSignal("AbsoluteSize"), updateCanvas)
    end

    local tab = { name = name, button = button, label = label, marker = marker, page = page, columns = columns }
    tabs[#tabs + 1] = tab
    connect(button.Activated, function()
        selectTab(tab)
    end)
    return tab
end

-- A section is a rounded card with a bold title; its controls stack inside it.
local function addSection(tab, columnIndex, titleText)
    local section = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = COLORS.card,
        BorderSizePixel = 0
    }, tab.columns[columnIndex])
    round(section, 8)
    new("UIStroke", { Color = COLORS.stroke, Thickness = 1 }, section)
    new("UIPadding", {
        PaddingTop = UDim.new(0, 10),
        PaddingBottom = UDim.new(0, 12),
        PaddingLeft = UDim.new(0, 12),
        PaddingRight = UDim.new(0, 12)
    }, section)
    new("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 6)
    }, section)
    local title = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
        Text = titleText,
        TextColor3 = COLORS.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Font = FONTS.bold,
        TextSize = 15
    }, section)
    if tab ~= favorites.tab then
        local id = tab.name .. "/" .. titleText
        section:SetAttribute("FavoriteId", id)
        new("UIPadding", { PaddingRight = UDim.new(0, 26) }, title)
        local star = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, 26, 0.5, 0),
            Size = UDim2.fromOffset(24, 24),
            BackgroundTransparency = 1,
            Text = "\u{2605}",
            TextColor3 = COLORS.off,
            Font = FONT,
            TextSize = 16,
            AutoButtonColor = false
        }, title)
        connect(star.Activated, function()
            favorites.toggle(id)
        end)
        favorites.sections[#favorites.sections + 1] = {
            id = id, frame = section, home = tab.columns[columnIndex], star = star
        }
    end
    return section
end

-- Labels grow to fit their text, so status lines can change length freely.
local function addLabel(section, text, color, _, size)
    return new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = color or COLORS.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        Font = FONT,
        TextSize = size or 12
    }, section)
end

local function addSubHeader(section, text)
    local label = addLabel(section, text, COLORS.accent, nil, 13)
    label.Font = FONTS.medium
    return label
end

-- Callbacks for controls that were saved as enabled run once the whole UI exists.
local startup = {}

-- A control with no onChange is saved but not wired to the game, so its text is dimmed.
local allToggles = {}
local function addToggle(section, text, key, default, onChange)
    favorites.adopt(section, key)
    local row = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false
    }, section)
    new("TextLabel", {
        Size = UDim2.new(1, -44, 1, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = onChange and COLORS.text or COLORS.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Font = FONT,
        TextSize = TEXT_SIZE
    }, row)
    local track = new("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(34, 18),
        BorderSizePixel = 0
    }, row)
    round(track, 9)
    local knob = new("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Size = UDim2.fromOffset(14, 14),
        BackgroundColor3 = COLORS.text,
        BorderSizePixel = 0
    }, track)
    round(knob, 7)

    local toggle = {label = text, row = row}
    local function render()
        local on = settings[key] == true
        track.BackgroundColor3 = on and COLORS.accent or COLORS.off
        knob.Position = on and UDim2.new(1, -16, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
    end
    function toggle.set(value, silent)
        setSetting(key, value and true or false)
        render()
        if onChange and not silent then
            onChange(settings[key])
        end
    end

    getSetting(key, default)
    render()
    connect(row.Activated, function()
        toggle.set(not settings[key])
    end)
    if onChange and settings[key] then
        startup[#startup + 1] = function()
            onChange(true)
        end
    end
    allToggles[key] = toggle
    return toggle
end

local function addButton(section, text, onClick)
    local button = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundColor3 = COLORS.box,
        BorderSizePixel = 0,
        Text = text,
        TextColor3 = onClick and COLORS.text or COLORS.dim,
        Font = FONTS.medium,
        TextSize = TEXT_SIZE,
        AutoButtonColor = false
    }, section)
    round(button, 6)
    hover(button, COLORS.box, COLORS.boxHover)
    if onClick then
        connect(button.Activated, onClick)
    end
    return button
end

local OPTION_HEIGHT = 26
local function addDropdown(section, labelText, key, options, default, onChange, multiSelect, placeholder)
    if labelText then
        addLabel(section, labelText, COLORS.dim)
    end
    local button = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 28),
        BackgroundColor3 = COLORS.box,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false
    }, section)
    round(button, 6)
    hover(button, COLORS.box, COLORS.boxHover)
    local valueLabel = new("TextLabel", {
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -36, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = COLORS.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Font = FONT,
        TextSize = TEXT_SIZE
    }, button)
    local arrow = new("TextLabel", {
        Position = UDim2.new(1, -26, 0, 0),
        Size = UDim2.fromOffset(18, 28),
        BackgroundTransparency = 1,
        Text = "+",
        TextColor3 = COLORS.dim,
        Font = FONTS.bold,
        TextSize = 15
    }, button)

    -- The option list opens inline under the button and scrolls when it is long.
    local list = new("ScrollingFrame", {
        Size = UDim2.new(1, 0, 0, 0),
        BackgroundColor3 = COLORS.box,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = COLORS.off,
        CanvasSize = UDim2.new(),
        Visible = false
    }, section)
    round(list, 6)
    new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, list)

    local function setOpen(open)
        list.Visible = open
        arrow.Text = open and "-" or "+"
    end

    local dropdown = {}
    local function renderValue()
        local selected = settings[key]
        valueLabel.Text = multiSelect and (#selected > 0 and table.concat(selected, ", ") or placeholder or "Select mobs...")
            or tostring(selected)
        if multiSelect then
            for _, child in ipairs(list:GetChildren()) do
                local option = child:GetAttribute("Option")
                if child:IsA("TextButton") and option then
                    local checked = table.find(selected, option) ~= nil
                    child.Text = (checked and "   [x] " or "   [ ] ") .. option
                    child.TextColor3 = checked and COLORS.accent or COLORS.text
                end
            end
        end
    end
    function dropdown.set(value, silent)
        if multiSelect then
            local values, seen = {}, {}
            for _, name in ipairs(type(value) == "table" and value or { value }) do
                if type(name) == "string" and name ~= "--" and not seen[name] then
                    seen[name] = true
                    values[#values + 1] = name
                end
            end
            value = values
        end
        setSetting(key, value)
        renderValue()
        if onChange and not silent then
            onChange(value)
        end
    end
    function dropdown.setOptions(newOptions)
        configStore.options[key] = table.clone(newOptions)
        for _, child in ipairs(list:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end
        for _, option in ipairs(newOptions) do
            local optionButton = new("TextButton", {
                Size = UDim2.new(1, 0, 0, OPTION_HEIGHT),
                BackgroundColor3 = COLORS.box,
                BorderSizePixel = 0,
                Text = "   " .. tostring(option),
                TextColor3 = COLORS.text,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Font = FONT,
                TextSize = TEXT_SIZE,
                AutoButtonColor = false
            }, list)
            optionButton:SetAttribute("Option", tostring(option))
            hover(optionButton, COLORS.box, COLORS.boxHover)
            connect(optionButton.Activated, function()
                if multiSelect then
                    local selected = table.clone(settings[key])
                    local index = table.find(selected, option)
                    if index then table.remove(selected, index) else selected[#selected + 1] = option end
                    dropdown.set(selected)
                else
                    setOpen(false)
                    dropdown.set(option)
                end
            end)
        end
        list.Size = UDim2.new(1, 0, 0, math.min(#newOptions, 7) * OPTION_HEIGHT)
        list.CanvasSize = UDim2.fromOffset(0, #newOptions * OPTION_HEIGHT)
        if multiSelect then renderValue() end
    end

    getSetting(key, default)
    if multiSelect then dropdown.set(settings[key], true) end
    dropdown.setOptions(options)
    renderValue()
    connect(button.Activated, function()
        setOpen(not list.Visible)
    end)
    return dropdown
end

local function addSlider(section, labelText, key, minValue, maxValue, default)
    configStore.bounds[key] = {minValue, maxValue}
    local header = new("Frame", {
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1
    }, section)
    new("TextLabel", {
        Size = UDim2.new(1, -70, 1, 0),
        BackgroundTransparency = 1,
        Text = labelText,
        TextColor3 = COLORS.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Font = FONT,
        TextSize = 12
    }, header)
    local valueLabel = new("TextLabel", {
        Position = UDim2.new(1, -70, 0, 0),
        Size = UDim2.fromOffset(70, 16),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = COLORS.text,
        TextXAlignment = Enum.TextXAlignment.Right,
        Font = FONTS.medium,
        TextSize = 12
    }, header)

    local bar = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false
    }, section)
    local track = new("Frame", {
        Position = UDim2.new(0, 0, 0.5, -3),
        Size = UDim2.new(1, 0, 0, 6),
        BackgroundColor3 = COLORS.off,
        BorderSizePixel = 0
    }, bar)
    round(track, 3)
    local fill = new("Frame", {
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = COLORS.accent,
        BorderSizePixel = 0
    }, track)
    round(fill, 3)
    local knob = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(12, 12),
        BackgroundColor3 = COLORS.text,
        BorderSizePixel = 0
    }, bar)
    round(knob, 6)

    local function render()
        local value = math.clamp(tonumber(settings[key]) or minValue, minValue, maxValue)
        local alpha = (value - minValue) / (maxValue - minValue)
        fill.Size = UDim2.fromScale(alpha, 1)
        knob.Position = UDim2.fromScale(alpha, 0.5)
        valueLabel.Text = tostring(value) .. " / " .. tostring(maxValue)
    end
    local function setFromX(x)
        local alpha = math.clamp((x - bar.AbsolutePosition.X) / math.max(1, bar.AbsoluteSize.X), 0, 1)
        setSetting(key, math.floor(minValue + alpha * (maxValue - minValue) + 0.5))
        render()
    end

    local sliding = false
    connect(bar.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            setFromX(input.Position.X)
        end
    end)
    connect(UserInputService.InputChanged, function(input)
        if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            setFromX(input.Position.X)
        end
    end)
    connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            sliding = false
        end
    end)

    getSetting(key, default)
    render()
    return {Refresh = render, Bar = bar, ValueLabel = valueLabel}
end

-- Shared look for the number and text entry boxes.
local function addEntryBox(section, labelText, text, placeholder)
    addLabel(section, labelText, COLORS.dim)
    local box = new("TextBox", {
        Size = UDim2.new(1, 0, 0, 28),
        BackgroundColor3 = COLORS.box,
        BorderSizePixel = 0,
        Text = text,
        PlaceholderText = placeholder or "",
        PlaceholderColor3 = COLORS.off,
        TextColor3 = COLORS.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        ClipsDescendants = true,
        Font = FONT,
        TextSize = TEXT_SIZE
    }, section)
    round(box, 6)
    new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, box)
    return box
end

local function addNumberBox(section, labelText, key, default)
    local box = addEntryBox(section, labelText, tostring(getSetting(key, default)))
    connect(box.FocusLost, function()
        local number = tonumber(box.Text)
        if number then
            setSetting(key, number)
        else
            box.Text = tostring(settings[key])
        end
    end)
    return box
end

local function addTextBox(section, labelText, key, default, placeholder, onChange)
    local box = addEntryBox(section, labelText, tostring(getSetting(key, default)), placeholder)
    connect(box.FocusLost, function()
        local text = string.gsub(box.Text, "^%s*(.-)%s*$", "%1")
        box.Text = text
        setSetting(key, text)
        if onChange then
            onChange(text)
        end
    end)
    return box
end

-- A numbered order list with a selector and Move Up / Move Down buttons.
local function addPriorityList(section, key, defaultOrder, selectorLabel)
    local order = getSetting(key, defaultOrder)
    if type(order) ~= "table" or #order ~= #defaultOrder then
        order = table.clone(defaultOrder)
        settings[key] = order
    end

    local listLabel = addLabel(section, "", COLORS.text, nil, 13)
    local function render()
        local lines = {}
        for index, name in ipairs(order) do
            lines[index] = tostring(index) .. ".  " .. name
        end
        listLabel.Text = table.concat(lines, "\n")
    end

    local selectedKey = key .. ".Selected"
    addDropdown(section, selectorLabel, selectedKey, defaultOrder, defaultOrder[1], function() end)
    local function move(delta)
        local from = table.find(order, settings[selectedKey])
        local to = from and from + delta
        if not from or to < 1 or to > #order then return end
        order[from], order[to] = order[to], order[from]
        setSetting(key, order)
        render()
    end
    addButton(section, "Move Up", function()
        move(-1)
    end)
    addButton(section, "Move Down", function()
        move(1)
    end)
    render()
end

-- Window dragging and hide key ---------------------------------------------------------

local dragging = false
local dragInput = nil
local dragStart
local windowStart

connect(titleBar.InputBegan, function(input)
    local inputType = input.UserInputType
    if dragging or (inputType ~= Enum.UserInputType.MouseButton1
        and inputType ~= Enum.UserInputType.Touch) then return end

    dragging = true
    dragInput = input
    dragStart = input.Position
    windowStart = window.Position
end)

connect(UserInputService.InputChanged, function(input)
    if not dragging or not dragInput then return end

    if dragInput.UserInputType == Enum.UserInputType.Touch then
        if input ~= dragInput then return end
    elseif input.UserInputType ~= Enum.UserInputType.MouseMovement then
        return
    end

    local delta = input.Position - dragStart
    window.Position = UDim2.new(
        windowStart.X.Scale, windowStart.X.Offset + delta.X,
        windowStart.Y.Scale, windowStart.Y.Offset + delta.Y
    )
end)

connect(UserInputService.InputEnded, function(input)
    if not dragging or not dragInput then return end
    local mouseReleased = dragInput.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseButton1
    if input ~= dragInput and not mouseReleased then return end

    dragging = false
    dragInput = nil
    dragStart = nil
    windowStart = nil
end)

function menuKey.render()
    local hint = gui:FindFirstChild("MenuKeyHint", true)
    if hint then hint.Text = menuKey.name .. ": hide/show" end
    if menuKey.button then
        menuKey.button.Text = menuKey.capturing and "Press a key (Esc cancels)"
            or ("Menu key: " .. menuKey.name .. " (click to change)")
    end
end
function menuKey.handle(input, processed)
    if UserInputService:GetFocusedTextBox() then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard or input.KeyCode == Enum.KeyCode.Unknown then return end
    if menuKey.capturing then
        if input.KeyCode == Enum.KeyCode.Escape then
            menuKey.capturing = false
        else
            menuKey.set(input.KeyCode.Name)
        end
        menuKey.render()
        return
    end
    if not processed and input.KeyCode.Name == menuKey.name then
        window.Visible = not window.Visible
    end
end
connect(UserInputService.InputBegan, menuKey.handle)

-- Game access ------------------------------------------------------------------------

-- The game's own client module: Signal sends the same calls the game's UI sends, and Data
-- is the live copy of your save data.
local Omni = require(ReplicatedStorage:WaitForChild("Omni"))
local StarterGui = game:GetService("StarterGui")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")

local RARITIES = { "--", "Common", "Rare", "Epic", "Legendary", "Mythical", "Secret" }
local DUNGEON_ENTRY_GRACE = 75 -- seconds after :00 before assuming you skipped the dungeon
local SHOP_NAME = "Adventurer Shop"
local UPGRADE_GROUP = "Adventurer Upgrades"
-- Quest names are discovered from the game. These keys only preserve older saved toggles.
local SIDE_QUESTS = { entries = {}, rows = {}, legacy = {
    ["Beneath the Crimson Moon"] = "Slayers.QuestCrimsonMoon",
    ["The Greed of the Fox"] = "Sins.QuestGreedOfTheFox",
    ["A Captain's Promise"] = "Heaven.QuestCaptainsPromise",
    ["The Weight of Infinity"] = "Cursed.QuestWeightOfInfinity"
} }
function SIDE_QUESTS.discover(catalog)
    local entries = {}
    for id, info in pairs(type(catalog) == "table" and catalog or {}) do
        if type(info) == "table" then
            local name = type(info.Name) == "string" and info.Name or id
            if type(name) == "string" then
                entries[#entries + 1] = { name = name, index = tonumber(info.Index) or math.huge,
                    key = SIDE_QUESTS.legacy[name] or ("SideQuests.Auto." .. name) }
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.index ~= b.index then return a.index < b.index end
        return a.name < b.name
    end)
    return entries
end
function SIDE_QUESTS.refresh()
    if not SIDE_QUESTS.section then return end
    local group = Omni.Shared.Quests.List.Side
    if type(group) ~= "table" or type(group.List) ~= "table" then
        SIDE_QUESTS.info.Text = "Waiting for the game's side quest catalog"
        return
    end
    local entries = SIDE_QUESTS.discover(group.List)
    local present = {}
    SIDE_QUESTS.entries = {}
    SIDE_QUESTS.ordered = entries
    for index, entry in ipairs(entries) do
        present[entry.key] = true
        SIDE_QUESTS.entries[entry.key] = entry.name
        local toggle = SIDE_QUESTS.rows[entry.key]
        if not toggle then
            toggle = addToggle(SIDE_QUESTS.section, entry.name, entry.key, false, function(value)
                if not value then SIDE_QUESTS.active = false end
                SIDE_QUESTS.target = nil
            end)
            SIDE_QUESTS.rows[entry.key] = toggle
        end
        toggle.row.LayoutOrder = 10 + index
    end
    for key, toggle in pairs(SIDE_QUESTS.rows) do
        if not present[key] then
            toggle.row:Destroy()
            if allToggles[key] == toggle then allToggles[key] = nil end
            SIDE_QUESTS.rows[key] = nil
        end
    end
    SIDE_QUESTS.info.Text = tostring(#entries) .. " side quests found. New quests appear automatically."
end

local function S(key)
    return settings[key]
end

-- Marks a control as wired: its feature loop reads the setting every tick.
local function W() end

local function fire(...)
    Omni.Signal:Fire("General", ...)
end

local function invoke(...)
    return Omni.Signal:Invoke("General", ...)
end

local requestCounter = 0
local function nextRequest()
    requestCounter = requestCounter + 1
    return requestCounter
end

local lastError = nil
local featureThreads = {}
local statusLabels = {}

local function setStatus(name, text)
    local label = statusLabels[name]
    if label and label.Text ~= text then
        label.Text = text
    end
end

local function notify(text)
    if not S("Session.Notifications") then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Wrld Hub",
            Text = text,
            Duration = 6
        })
    end)
end

-- Discord webhook ---------------------------------------------------------------------

local httpRequest = request or http_request or (http and http.request)

local function webhookUrl()
    local url = settings["Webhook.Url"]
    if type(url) ~= "string" then return nil end
    -- Only real Discord webhook addresses are ever contacted.
    if string.match(url, "^https://discord%.com/api/webhooks/%d+/[%w_%-]+$")
        or string.match(url, "^https://discordapp%.com/api/webhooks/%d+/[%w_%-]+$")
        or string.match(url, "^https://ptb%.discord%.com/api/webhooks/%d+/[%w_%-]+$")
        or string.match(url, "^https://canary%.discord%.com/api/webhooks/%d+/[%w_%-]+$") then
        return url
    end
    return nil
end

-- Returns true, or false plus a short reason. ping = true mentions you.
local function sendWebhook(text, ping)
    local url = webhookUrl()
    if not url then
        return false, "Paste a Discord webhook URL first"
    end
    if not httpRequest then
        return false, "This executor cannot send web requests"
    end

    local mention = ""
    local allowed: {parse: {string}, users: {string}?} = { parse = {} }
    if ping then
        local userId = string.match(tostring(settings["Webhook.UserId"] or ""), "^%d+$")
        if userId then
            mention = "<@" .. userId .. "> "
            allowed.users = { userId }
        else
            mention = "@everyone "
            allowed = { parse = { "everyone" } }
        end
    end

    local ok, response = pcall(httpRequest, {
        Url = url,
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = HttpService:JSONEncode({
            username = "Wrld Hub",
            content = mention .. text,
            allowed_mentions = allowed
        })
    })
    if not ok then
        return false, "Request failed: " .. tostring(response)
    end
    local code = type(response) == "table" and response.StatusCode or nil
    if code and (code < 200 or code >= 300) then
        return false, "Discord answered with error " .. tostring(code)
    end
    return true
end

-- Every join/leave/start the hub decides on is written to FarmHub_log.txt with its reason.
local actionLog = {}
local function logAction(text)
    actionLog[#actionLog + 1] = os.date("%H:%M:%S") .. "  " .. text
    while #actionLog > 200 do
        table.remove(actionLog, 1)
    end
    pcall(function()
        writefile("FarmHub_log.txt", table.concat(actionLog, "\n"))
    end)
end

-- Runs fn forever on its own thread. fn may return a number to override the next wait.
local function every(name, interval, fn)
    featureThreads[#featureThreads + 1] = task.spawn(function()
        while alive do
            local ok, result = pcall(fn)
            if not ok then
                lastError = name .. ": " .. tostring(result)
            end
            task.wait(ok and tonumber(result) or interval)
        end
    end)
end

local function sortedKeys(source, placeholder)
    local keys = {}
    pcall(function()
        for key in pairs(source()) do
            if type(key) == "string" then
                keys[#keys + 1] = key
            end
        end
    end)
    table.sort(keys)
    if placeholder then
        table.insert(keys, 1, placeholder)
    end
    return keys
end

local function getRoot()
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if root and (not humanoid or humanoid.Health > 0) then
        return root, humanoid, character
    end
    return nil, nil, nil
end

local function teleportTo(destination)
    local root, _, character = getRoot()
    if not root then return false end
    character:PivotTo(destination)
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    return true
end

local function serverFolder(...)
    local current = workspace:FindFirstChild("Server")
    for _, name in ipairs({ ... }) do
        if not current then return nil end
        current = current:FindFirstChild(name)
    end
    return current
end

-- Live enemies are parts carrying EnemyID/EnemyName attributes. Dead ones are skipped.
local function findEnemies(folder, enemyName)
    local result = {}
    if not folder then return result end
    for _, inst in ipairs(folder:GetDescendants()) do
        if inst:IsA("BasePart") and inst:GetAttribute("EnemyID") ~= nil
            and not inst:GetAttribute("Died")
            and (not enemyName or inst:GetAttribute("EnemyName") == enemyName
                or (type(enemyName) == "table" and enemyName[inst:GetAttribute("EnemyName")])) then
            result[#result + 1] = inst
        end
    end
    return result
end

-- Enemies walk around while their part stays put, so ask the game where each one really is.
local function enemyPosition(enemy)
    local position = enemy.Position
    pcall(function()
        local cframe = Omni.Utils.Enemies.GetPosition(enemy:GetAttribute("EnemyID"))
        if typeof(cframe) == "CFrame" then
            position = cframe.Position
        end
    end)
    return position
end

local function nearestTo(instances, position)
    local best, bestDistance, bestPosition = nil, math.huge, nil
    for _, inst in ipairs(instances) do
        local where
        if not inst:IsA("BasePart") then
            where = inst:GetPivot().Position
        elseif inst:GetAttribute("EnemyID") ~= nil then
            where = enemyPosition(inst)
        else
            where = inst.Position
        end
        local distance = (where - position).Magnitude
        if distance < bestDistance then
            best, bestDistance, bestPosition = inst, distance, where
        end
    end
    return best, bestDistance, bestPosition
end

local function playerStat(name, default, ...)
    local value = default
    local extra = { ... }
    pcall(function()
        local result = Omni.Utils.PlayerStats[name](Omni.Data, Omni.Instance, unpack(extra))
        if type(result) == "number" and result > 0 then
            value = result
        end
    end)
    return value
end

local function currentGamemode()
    local gamemode = Omni.Data.Gamemode
    return type(gamemode) == "string" and gamemode or nil
end

local ACTIVITIES = { "Trial", "Dungeon", "Culling" }
local function activityOf(gamemode)
    if gamemode == "Dragon Defense" then return "DragonDefense" end
    for _, activity in ipairs(ACTIVITIES) do
        if string.sub(gamemode, 1, #activity) == activity then
            return activity
        end
    end
    return nil
end

-- The hub only ever leaves a gamemode it is running for you, never one you joined yourself.
local ACTIVITY_TOGGLES = {
    Trial = { "Trial.AutoTrial" },
    Dungeon = { "Dungeon.AutoDungeon" },
    Culling = { "Culling.Enabled" },
    DragonDefense = { "DragonDefense.Enabled" }
}
local function activityManaged(activity)
    for _, key in ipairs(ACTIVITY_TOGGLES[activity] or {}) do
        if settings[key] then
            return true
        end
    end
    return false
end

-- Position in the Priority list; lower numbers win.
local function priorityRank(name)
    if name == "DragonDefense" then name = "Dragon Defense" end
    return table.find(settings["Priority.Order"] or {}, name) or math.huge
end

local function equippedFighterIds()
    local ids = {}
    for id in pairs(Omni.Data.Fighters.Equipped or {}) do
        ids[#ids + 1] = id
    end
    return ids
end

local function mobNames(world)
    local names, seen = {}, {}
    local function add(name)
        if type(name) == "string" and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    pcall(function()
        for key, info in pairs(Omni.Shared.Enemies.List[world] or {}) do
            add(type(info) == "table" and type(info.Name) == "string" and info.Name or key)
        end
    end)
    for _, enemy in ipairs(findEnemies(serverFolder("Enemies", "Maps", world))) do
        add(enemy:GetAttribute("EnemyName"))
    end
    table.sort(names)
    return names
end

-- Discover regular worlds from the game, including worlds not visited/unlocked yet.
-- The Maps folder is deliberately separate from Gamemodes and Training.
local hubMain = { labels = {}, target = nil, targetWorld = nil, rotation = 0,
    updateBusy = false, updateText = "Checking GitHub...", updateSource = nil, newer = false }
-- Live client performance. RenderStepped samples the actual rendered frame rate.
hubMain.performance = {frames = 0, elapsed = 0, longest = 0, fps = nil, frameMs = nil,
    stats = game:GetService("Stats"), capStatus = "Unlimited", originalCap = nil, capApplied = false,
    focused = true, choice = nil, focusQuery = type(iswindowactive) == "function" and iswindowactive
        or type(isrbxactive) == "function" and isrbxactive or nil}
if hubMain.performance.focusQuery then
    local ok, focused = pcall(hubMain.performance.focusQuery)
    if ok and type(focused) == "boolean" then hubMain.performance.focused = focused end
end
if type(getfpscap) == "function" then
    local ok, cap = pcall(getfpscap)
    if ok and type(cap) == "number" then hubMain.performance.originalCap = cap end
end
function hubMain.frame(delta)
    if type(delta) ~= "number" or delta <= 0 or delta ~= delta or delta == math.huge then return end
    local p = hubMain.performance
    p.frames += 1
    p.elapsed += delta
    p.longest = math.max(p.longest, delta)
    if p.elapsed >= 1 then
        p.fps = math.floor(p.frames / p.elapsed + 0.5)
        p.frameMs = p.elapsed * 1000 / p.frames
        p.worstMs = p.longest * 1000
        p.frames, p.elapsed, p.longest = 0, 0, 0
    end
end
function hubMain.setFpsLimit(choice)
    local p = hubMain.performance
    p.choice = choice
    local selectedCap = choice == "15" and 15 or choice == "60" and 60 or 0
    local cap = p.focused and selectedCap or 30
    local description = p.focused and (selectedCap == 0 and "Unlimited" or tostring(selectedCap))
        or ("30 (background; focused: " .. (selectedCap == 0 and "Unlimited" or tostring(selectedCap)) .. ")")
    if type(setfpscap) ~= "function" then
        p.capStatus = "FPS limiter is unavailable in this executor"
    else
        local ok, failure = pcall(setfpscap, cap)
        if ok then p.capApplied = true end
        p.capStatus = ok and ("FPS limit: " .. description)
            or ("Could not set FPS limit: " .. tostring(failure))
    end
    if hubMain.labels.fpsSetting then hubMain.labels.fpsSetting.Text = p.capStatus end
end
function hubMain.setFocused(focused)
    if type(focused) ~= "boolean" or focused == hubMain.performance.focused then return end
    hubMain.performance.focused = focused
    hubMain.setFpsLimit(S("Session.FpsLimit") or hubMain.performance.choice or "60")
end
function hubMain.checkFocus()
    local query = hubMain.performance.focusQuery
    if query then
        local ok, focused = pcall(query)
        if ok then hubMain.setFocused(focused) end
    end
end
function hubMain.renderPerformance()
    if not hubMain.labels.performance then return end
    local p = hubMain.performance
    local pingOk, ping = pcall(function()
        return p.stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    local memoryOk, memory = pcall(p.stats.GetTotalMemoryUsageMb, p.stats)
    local camera = workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize
    hubMain.labels.performance.Text = "FPS: " .. (p.fps and tostring(p.fps) or "sampling...")
        .. "\nPing: " .. (pingOk and type(ping) == "number" and string.format("%.0f ms", ping) or "unavailable")
        .. "\nClient memory: " .. (memoryOk and type(memory) == "number" and string.format("%.0f MB", memory) or "unavailable")
        .. "\nPlayers: " .. #Players:GetPlayers() .. " / " .. Players.MaxPlayers
        .. "\n" .. p.capStatus
end

function hubMain.sum(values)
    local total = 0
    for _, value in pairs(values or {}) do if type(value) == "number" then total += value end end
    return total
end
function hubMain.claimed(data)
    local result = {}
    local function scan(prefix, values)
        for key, value in pairs(values or {}) do
            if value == true then result[prefix .. tostring(key)] = true end
        end
    end
    scan("Achievement:", data.Achievements)
    scan("Level:", data.Level and data.Level.Rewards)
    scan("Daily:" .. tostring(data.DailyRewards and data.DailyRewards.Start) .. ":", data.DailyRewards and data.DailyRewards.Claimed)
    scan("Time:" .. tostring(data.TimeRewards and data.TimeRewards.ResetAt) .. ":", data.TimeRewards and data.TimeRewards.Claimed)
    for section, values in pairs(data.IndexRewards or {}) do scan("Index:" .. section .. ":", values) end
    for id, message in pairs(data.Inbox and data.Inbox.List or {}) do
        if message.Claimed then result["Inbox:" .. id] = true end
    end
    return result
end
function hubMain.resetStats()
    local data = Omni.Data
    local stats = data.Profile and data.Profile.Stats or {}
    hubMain.session = {owner = player.UserId, start = workspace:GetServerTimeNow(),
        kills = 0, damage = 0, rewards = 0, entered = 0, ended = 0, items = 0,
        lastKills = tonumber(stats["Defeated Enemies"]) or hubMain.sum(data.Index and data.Index.Enemy),
        lastDamage = tonumber(stats["Damage Dealt"]) or 0,
        lastItems = hubMain.sum(data.Index and data.Index.Item),
        seen = hubMain.claimed(data),
        mode = data.Gamemode, sessionId = data.GamemodeSession}
    env.FarmHubSessionStats = hubMain.session
end
if type(env.FarmHubSessionStats) == "table" and env.FarmHubSessionStats.owner == player.UserId then
    hubMain.session = env.FarmHubSessionStats
else
    hubMain.resetStats()
end
function hubMain.sample(data)
    local session = hubMain.session
    local stats = data.Profile and data.Profile.Stats or {}
    local kills = tonumber(stats["Defeated Enemies"]) or hubMain.sum(data.Index and data.Index.Enemy)
    local damage = tonumber(stats["Damage Dealt"]) or 0
    local items = hubMain.sum(data.Index and data.Index.Item)
    session.kills += math.max(0, kills - session.lastKills)
    session.damage += math.max(0, damage - session.lastDamage)
    session.items += math.max(0, items - session.lastItems)
    session.lastKills, session.lastDamage, session.lastItems = kills, damage, items
    for key in pairs(hubMain.claimed(data)) do
        if not session.seen[key] then session.rewards += 1; session.seen[key] = true end
    end
    if data.Gamemode ~= session.mode or (data.Gamemode and data.GamemodeSession ~= session.sessionId) then
        if session.mode then session.ended += 1 end
        if data.Gamemode then session.entered += 1 end
        session.mode, session.sessionId = data.Gamemode, data.GamemodeSession
    end
end
function hubMain.health(enemy)
    local data = enemy:FindFirstChild("Data")
    local health = data and data:FindFirstChild("Health")
    return health and tonumber(health.Value) or math.huge
end
function hubMain.pick(enemies, position, names, mode, finish)
    local candidates = {}
    for _, enemy in ipairs(enemies) do
        if not enemy:GetAttribute("Died") and hubMain.health(enemy) > 0 then candidates[#candidates + 1] = enemy end
    end
    if hubMain.target and table.find(candidates, hubMain.target)
        and (finish or mode == "Rotate Types") then return hubMain.target end
    local pool = candidates
    if mode == "Bosses First" then
        local bosses = {}
        for _, enemy in ipairs(candidates) do
            local difficulty = enemy:GetAttribute("Difficulty")
            if difficulty == "Boss" or difficulty == "Secret" or difficulty == "World Boss"
                or enemy:GetAttribute("Boss") == true then bosses[#bosses + 1] = enemy end
        end
        if #bosses > 0 then pool = bosses end
    elseif mode == "Rotate Types" and #names > 0 then
        for offset = 1, #names do
            local index = ((hubMain.rotation + offset - 1) % #names) + 1
            local group = {}
            for _, enemy in ipairs(candidates) do
                if enemy:GetAttribute("EnemyName") == names[index] then group[#group + 1] = enemy end
            end
            if #group > 0 then pool = group; hubMain.rotation = index; break end
        end
    end
    local best, bestHealth, bestDistance = nil, math.huge, math.huge
    for _, enemy in ipairs(pool) do
        local distance = (enemyPosition(enemy) - position).Magnitude
        local hp = hubMain.health(enemy)
        local health = mode == "Lowest Health" and hp
            or mode == "Highest Health" and (hp < math.huge and -hp or math.huge) or 0
        if health < bestHealth or (health == bestHealth and distance < bestDistance) then
            best, bestHealth, bestDistance = enemy, health, distance
        end
    end
    return best
end
function hubMain.versionNewer(remote, localVersion)
    local a, b = {}, {}
    for part in remote:gmatch("%d+") do a[#a + 1] = tonumber(part) end
    for part in localVersion:gmatch("%d+") do b[#b + 1] = tonumber(part) end
    for i = 1, math.max(#a, #b) do
        if (a[i] or 0) ~= (b[i] or 0) then return (a[i] or 0) > (b[i] or 0) end
    end
    return false
end
function hubMain.updateLabel()
    if alive and hubMain.labels.update then
        hubMain.labels.update.Text = "Installed: " .. SCRIPT_VERSION .. "\n" .. hubMain.updateText
    end
end
function hubMain.checkUpdate()
    if hubMain.updateBusy then return end
    hubMain.updateBusy = true
    hubMain.updateText = "Checking GitHub..."
    hubMain.updateLabel()
    local thread = task.spawn(function()
        local ok, source = pcall(function() return game:HttpGet(SCRIPT_URL .. "?t=" .. os.time()) end)
        if not alive then return end
        local version = ok and type(source) == "string" and source:match('local SCRIPT_VERSION = "([^"]+)"')
        if version then
            hubMain.newer = hubMain.versionNewer(version, SCRIPT_VERSION)
            hubMain.updateSource = source
            hubMain.updateText = hubMain.newer and ("New version available: " .. version .. ". Click Reload from GitHub.")
                or ("Up to date. GitHub: " .. version)
        else
            hubMain.updateSource, hubMain.newer = nil, false
            hubMain.updateText = "Could not check GitHub. Click Check for Updates to retry."
        end
        hubMain.updateBusy = false
        hubMain.updateLabel()
    end)
    featureThreads[#featureThreads + 1] = thread
end
function hubMain.reload()
    if hubMain.updateBusy then return end
    hubMain.updateBusy = true
    hubMain.updateText = "Fetching and checking the latest script..."
    hubMain.updateLabel()
    local thread = task.spawn(function()
        local ok, result = pcall(function()
            local source = game:HttpGet(SCRIPT_URL .. "?t=" .. os.time())
            assert(type(source) == "string" and source:find("FarmHub", 1, true), "Invalid GitHub response")
            local compiled, failure = loadstring(source)
            assert(compiled, failure)
            if not alive then return end
            saveSettings()
            env.FarmHubUnload()
            compiled()
        end)
        if alive then
            hubMain.updateBusy = false
            hubMain.updateText = ok and "Reload requested." or ("Reload failed; your hub is still running. " .. tostring(result))
            hubMain.updateLabel()
        end
    end)
    featureThreads[#featureThreads + 1] = thread
end
local farmCatalog = { dropdowns = {}, cached = {}, mobs = nil, world = nil }
function farmCatalog.remember()
    local memory = getSetting("MobFarm.ByWorld", {})
    if not farmCatalog.world then return end
    local selected, old = S("MobFarm.Mobs"), memory[farmCatalog.world]
    local changed = not old or #old ~= #selected
    if not changed then for i, name in ipairs(selected) do if old[i] ~= name then changed = true; break end end end
    if changed then
        memory[farmCatalog.world] = table.clone(selected)
        setSetting("MobFarm.ByWorld", memory)
    end
end
function farmCatalog.switchWorld(world)
    if world == farmCatalog.world then return end
    local memory = getSetting("MobFarm.ByWorld", {})
    if farmCatalog.world then
        memory[farmCatalog.world] = table.clone(S("MobFarm.Mobs"))
    elseif memory[world] == nil then
        memory[world] = table.clone(S("MobFarm.Mobs"))
    end
    farmCatalog.world = world
    hubMain.target, hubMain.targetWorld, hubMain.rotation = nil, world, 0
    farmCatalog.mobs.set(table.clone(memory[world] or {}), true)
    setSetting("MobFarm.ByWorld", memory)
end
function farmCatalog.discover()
    local names, seen, order = {}, {}, {}
    local function add(name, index)
        if type(name) ~= "string" or name == "" or name == "Lobby" then return end
        if type(index) == "number" then order[name] = index end
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    pcall(function()
        for key, info in pairs(Omni.Shared.Maps.List) do
            add(key, type(info) == "table" and info.Index or nil)
        end
    end)
    pcall(function()
        for world, enemies in pairs(Omni.Shared.Enemies.List) do
            if type(enemies) == "table" then add(world) end
        end
    end)
    local maps = serverFolder("Enemies", "Maps")
    if maps then
        for _, folder in ipairs(maps:GetChildren()) do add(folder.Name) end
    end
    table.sort(names, function(a, b)
        local ai, bi = order[a] or math.huge, order[b] or math.huge
        return ai < bi or (ai == bi and a < b)
    end)
    -- Keep existing data if a catalog temporarily becomes unavailable during travel.
    if #names > 0 then
        table.clear(MAP_NAMES)
        table.clear(WORLD_MAPS)
        WORLD_MAPS.Lobby = true
        for _, name in ipairs(names) do
            MAP_NAMES[#MAP_NAMES + 1] = name
            WORLD_MAPS[name] = true
        end
    end
    return MAP_NAMES
end
function farmCatalog.updateOptions(dropdown, key, options)
    local previous = farmCatalog.cached[key]
    local changed = not previous or #previous ~= #options
    if not changed then
        for i, value in ipairs(options) do
            if previous[i] ~= value then changed = true; break end
        end
    end
    if changed then
        dropdown.setOptions(options)
        farmCatalog.cached[key] = table.clone(options)
    end
end
function farmCatalog.refreshMobs()
    if not farmCatalog.mobs then return end
    farmCatalog.switchWorld(S("MobFarm.World"))
    local names = mobNames(S("MobFarm.World"))
    farmCatalog.updateOptions(farmCatalog.mobs, "MobFarm.Mobs", names)
    local selected = S("MobFarm.Mobs")
    local valid = {}
    for _, name in ipairs(selected) do
        if table.find(names, name) then valid[#valid + 1] = name end
    end
    if #valid ~= #selected then
        -- Retain every valid selection; removed mobs never select unrelated targets.
        farmCatalog.mobs.set(valid, true)
        if #valid == 0 and allToggles["MobFarm.AutoFarm"] then
            allToggles["MobFarm.AutoFarm"].set(false)
        end
    end
    farmCatalog.remember()
end
function farmCatalog.refresh()
    local worlds = farmCatalog.discover()
    for key, dropdown in pairs(farmCatalog.dropdowns) do
        local options = table.clone(worlds)
        if #options == 0 then options = { "--" } end
        farmCatalog.updateOptions(dropdown, key, options)
        if not table.find(options, S(key)) then
            local toggleKey = "MobFarm.AutoFarm"
            if toggleKey and allToggles[toggleKey] then
                allToggles[toggleKey].set(false)
            end
            dropdown.set(options[1], true)
        end
    end
    farmCatalog.refreshMobs()
end
farmCatalog.discover()

-- Boss teleports ---------------------------------------------------------------------

local busyBoss = nil

local worldBoss = {
    name = "World Boss",
    map = WORLD_BOSS_MAP,
    destination = CFrame.new(4354, 41, 4378),
    enabled = false,
    phase = "off"
}
local bosses = { worldBoss }

local function formatTime(seconds)
    seconds = math.max(0, math.ceil(seconds))
    return string.format("%02d:%02d:%02d",
        math.floor(seconds / 3600),
        math.floor(seconds / 60) % 60,
        seconds % 60
    )
end

local function bossStatus(boss)
    if not boss.enabled then
        return boss.phase == "error" and "Teleport failed. Toggle to retry." or "Stopped"
    end

    local now = os.clock()
    if boss.phase == "teleporting" then
        return "Entering map in: " .. formatTime(boss.teleportAt - now)
    elseif boss.phase == "returning" then
        return "Returning to your spawn point..."
    elseif boss.phase == "holding" then
        return boss.bossSeen and "Boss alive, farming paused" or "Looking for the boss..."
    elseif boss.phase == "dungeon" then
        return "Waiting for the :00 dungeon to finish"
    elseif boss.phase == "gamemode" then
        return "Paused: in a dungeon/trial"
    elseif boss.phase == "queued" then
        return "Paused for the other teleport..."
    elseif boss.phase == "loading" then
        return "Waiting for your character..."

    end
    return "Next run: " .. formatTime((boss.nextRun or now) - now)
end

local function stopBoss(boss)
    boss.enabled = false
    boss.phase = "off"

    local worker = boss.worker
    boss.worker = nil
    if worker and worker ~= coroutine.running()
        and coroutine.status(worker) ~= "dead" then
        task.cancel(worker)
    end

    if busyBoss == boss then
        busyBoss = nil
    end
end

local function getCharacter(boss)
    while alive and boss.enabled do
        local root, _, character = getRoot()
        if root and character.Parent then
            return character, root
        end
        task.wait(0.1)
    end
    return nil, nil
end

-- Teleport markers can outlive a run or belong to a party lobby. Only the game's
-- current gamemode proves that this player is still in a dungeon/trial.
local function inGamemode()
    if not settings["Bosses.PauseInGamemode"] then return false end
    return currentGamemode() ~= nil
end

local lastPriorityLeave = 0
local function acquireTeleport(boss)
    boss.phase = "queued"
    while alive and boss.enabled do
        if inGamemode() then
            -- World Boss pulls you out of gamemodes ranked below it in the Priority list.
            local gamemode = currentGamemode()
            local activity = gamemode and activityOf(gamemode)
            if activity and settings["Priority.LeaveForPriority"]
                and activityManaged(activity)
                and priorityRank("World Boss") < priorityRank(activity)
                and os.clock() - lastPriorityLeave > 5 then
                lastPriorityLeave = os.clock()
                logAction("Leave " .. gamemode .. ": World Boss ranks above it")
                fire("Gamemodes", "Leave")
            end
            boss.phase = "gamemode"
            -- Force a map re-entry once the dungeon/trial is over.
            boss.gamemodeClearAt = os.clock() + GAMEMODE_EXIT_DELAY
        elseif boss.gamemodeClearAt and os.clock() < boss.gamemodeClearAt then
            boss.phase = "gamemode"
        elseif busyBoss then
            boss.phase = "queued"
        else
            break
        end
        task.wait(0.1)
    end
    if not alive or not boss.enabled then return false end
    busyBoss = boss
    return true
end

-- Sends the game's own map teleport and waits for the map to load.
local function requestMap(map)
    fire("Maps", "Teleport", map)
    task.wait(TELEPORT_DELAY)
end

local function enterMap(boss)
    boss.phase = "teleporting"
    boss.teleportAt = os.clock() + TELEPORT_DELAY
    logAction(boss.name .. " teleport requested: " .. boss.map)
    requestMap(boss.map)
end

local function moveCharacter(boss, destination)
    boss.phase = "loading"
    local character, root = getCharacter(boss)
    if not character then return false end

    character:PivotTo(destination)
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    return true
end

local function failBoss(boss, message)
    warn(boss.name .. " teleport failed: " .. tostring(message))
    stopBoss(boss)
    boss.phase = "error"
    boss.toggle.set(false, true)
end

-- Workspace.Server.WorldBosses only holds a permanent marker part, so the live boss is
-- looked up among the enemy parts instead.
local function worldBossPresent()
    for _, enemy in ipairs(findEnemies(serverFolder("Enemies", "WorldBosses"))) do
        if enemy:GetAttribute("EnemyName") == WORLD_BOSS_NAME
            or enemy:GetAttribute("MapName") == WORLD_BOSS_MAP then
            return true
        end
    end
    return false
end

local bossReturn = { label = nil }
function bossReturn.capture()
    if currentGamemode() then return nil end
    local root = getRoot()
    local map = Omni.Data.Maps and Omni.Data.Maps.Current
    if not root or type(map) ~= "string" or not WORLD_MAPS[map] then return nil end
    return {map = map, cframe = {root.CFrame:GetComponents()}}
end
function bossReturn.saved()
    local spot = getSetting("Bosses.ReturnSpot", {})
    if type(spot) ~= "table" or type(spot.map) ~= "string" or not WORLD_MAPS[spot.map]
        or type(spot.cframe) ~= "table" or #spot.cframe ~= 12 then return nil end
    for i = 1, 12 do
        local n = spot.cframe[i]
        if type(n) ~= "number" or n ~= n or math.abs(n) == math.huge then return nil end
    end
    return spot
end
function bossReturn.render()
    if not bossReturn.label then return end
    local spot = bossReturn.saved()
    bossReturn.label.Text = spot and string.format("Spawn point: %s (%.1f, %.1f, %.1f)",
        spot.map, spot.cframe[1], spot.cframe[2], spot.cframe[3])
        or "No spawn point set. Set it while standing at your AFK spot."
end
function bossReturn.setHere()
    local spot = bossReturn.capture()
    if not spot then
        notify("Set your spawn point outside a gamemode, with your character loaded.")
        return false
    end
    setSetting("Bosses.ReturnSpot", spot)
    bossReturn.render()
    notify("Spawn point saved in " .. spot.map)
    return true
end
function bossReturn.restore(boss)
    if not S("Bosses.ReturnAfterBoss") then return false, "return disabled" end
    local spot = bossReturn.saved() or boss.returnSpot
    if not spot then return false, "no return point available" end
    if not alive or not boss.enabled or currentGamemode() then return false, "another activity is active" end
    boss.phase = "returning"
    logAction("World Boss returning to spawn point: " .. spot.map)
    if Omni.Data.Maps.Current ~= spot.map then requestMap(spot.map) end
    local deadline = os.clock() + 10
    while alive and boss.enabled and not currentGamemode() and os.clock() < deadline do
        if Omni.Data.Maps.Current == spot.map and getRoot() then
            if teleportTo(CFrame.new(unpack(spot.cframe))) then
                logAction("World Boss returned to spawn point: " .. spot.map)
                notify("Returned to your spawn point.")
                boss.returnSpot = nil
                return true
            end
        end
        task.wait(0.1)
    end
    return false, currentGamemode() and "another activity took priority" or "map or character did not load"
end
-- Capture the current AFK position once when first adding this feature.
if not bossReturn.saved() then
    local spot = bossReturn.capture()
    if spot then setSetting("Bosses.ReturnSpot", spot) end
end

local function runWorldBoss(boss)
    local handledHour = nil
    while alive and boss.enabled do
        local now = os.time()
        local hour = math.floor(now / INTERVAL)
        local elapsed = now % INTERVAL

        -- Sleep until the next spawn if this one is done or the window has passed.
        if hour == handledHour or elapsed >= WORLD_BOSS_WINDOW then
            boss.phase = "waiting"
            boss.nextRun = os.clock() + (INTERVAL - elapsed)
            task.wait(INTERVAL - elapsed)
            continue
        end

        handledHour = hour
        boss.nextRun = os.clock() + (INTERVAL - elapsed)

        -- Go once the :00 dungeon is done: wait while its entry may still be open and
        -- while you are inside it. If you never joined, go when the entry closes.
        boss.phase = "dungeon"
        logAction("World Boss waiting for dungeon exit / entry window to close")
        local wasInDungeon = false
        while alive and boss.enabled do
            local gamemode = currentGamemode()
            local inDungeon = gamemode ~= nil and activityOf(gamemode) == "Dungeon"
            wasInDungeon = wasInDungeon or inDungeon
            if not inDungeon and (wasInDungeon or os.time() % INTERVAL >= DUNGEON_ENTRY_GRACE) then
                break
            end
            task.wait(0.5)
        end
        if wasInDungeon then
            task.wait(GAMEMODE_EXIT_DELAY)
        end
        logAction("World Boss dungeon wait complete; current gamemode: " .. tostring(currentGamemode()))
        if not acquireTeleport(boss) then return end

        boss.returnSpot = boss.returnSpot or bossReturn.saved() or bossReturn.capture()
        local success, message = pcall(function()
            enterMap(boss)
            moveCharacter(boss, boss.destination)
            logAction("World Boss teleport completed: " .. tostring(boss.destination.Position))
        end)
        if not success then
            failBoss(boss, message)
            return
        end

        -- Keep the teleport lock until the boss is gone so the boss farm stays paused.
        boss.phase = "holding"
        boss.bossSeen = false
        local holdStart = os.clock()
        local lastSeen = nil
        while alive and boss.enabled and os.clock() - holdStart < WORLD_BOSS_MAX_HOLD do
            if worldBossPresent() then
                if not boss.bossSeen then
                    notify("World boss found. Other teleports are paused.")
                end
                lastSeen = os.clock()
                boss.bossSeen = true
            elseif lastSeen then
                if os.clock() - lastSeen >= BOSS_GONE_CONFIRM then break end
            elseif os.clock() - holdStart >= BOSS_APPEAR_TIMEOUT then
                break
            end
            local gamemode = currentGamemode()
            if gamemode then
                -- A higher-priority gamemode took over: come back for the boss afterwards.
                -- Anything else (such as one you joined yourself) ends this hour's attempt.
                local activity = activityOf(gamemode)
                if activity and priorityRank(activity) < priorityRank("World Boss") then
                    handledHour = nil
                end
                logAction("World Boss hold ended: you entered " .. gamemode)
                break
            end
            task.wait(0.5)
        end

        if alive and boss.enabled and not currentGamemode() and busyBoss == boss then
            local ok, returned, reason = pcall(bossReturn.restore, boss)
            if not ok then
                lastError = "World Boss return: " .. tostring(returned)
                logAction(lastError)
            elseif not returned and S("Bosses.ReturnAfterBoss") then
                logAction("World Boss return skipped: " .. tostring(reason))
            end
        end
        if busyBoss == boss then busyBoss = nil end
    end
end

local function setBossEnabled(boss, value)
    if not alive then return end
    if not value then
        stopBoss(boss)
        return
    end
    if boss.enabled then return end

    boss.enabled = true
    boss.phase = "queued"
    boss.worker = task.defer(function()
        runWorldBoss(boss)
    end)
end

-- True while something with a higher claim on your position is active.
local function positionTaken()
    return busyBoss ~= nil or currentGamemode() ~= nil
end

-- Goes to a world map if you are not already there. Returns true once you are in it.
local function ensureMap(map)
    local maps = Omni.Data.Maps
    if maps and maps.Current == map then return true end
    requestMap(map)
    return false
end

-- Session helpers --------------------------------------------------------------------

-- The game runs its own idle timer: after 15 minutes without a key or mouse press it
-- rejoins the server, which also removes this hub. Anti AFK therefore does three things:
-- every minute sends real input (a click at the top-right screen corner and/or a jump, plus an unused
-- key), switches the game's idle rejoin off as a backstop, and answers Roblox's own
-- 20-minute idle check.
local ANTI_AFK_KEY = Enum.KeyCode.F15
-- One pixel left and one pixel down from the current viewport's top-right corner.
local function antiAfkClickPoint()
    local camera = workspace.CurrentCamera
    if not camera then return nil, nil end
    local width, height = math.floor(camera.ViewportSize.X), math.floor(camera.ViewportSize.Y)
    if width < 1 or height < 1 then return nil, nil end
    return width - 1, math.min(1, height - 1)
end

local function antiAfkPulse(VirtualInputManager)
    local method = settings["Session.AntiAfkMethod"] or "Click + Jump"
    VirtualInputManager:SendKeyEvent(true, ANTI_AFK_KEY, false, game)
    task.wait(0.05)
    VirtualInputManager:SendKeyEvent(false, ANTI_AFK_KEY, false, game)

    if string.find(method, "Click", 1, true) then
        local x, y = antiAfkClickPoint()
        if x ~= nil then
            VirtualInputManager:SendMouseMoveEvent(x, y, game)
            task.wait(0.05)
            VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
            task.wait(0.05)
            VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
        end
    end
    if string.find(method, "Jump", 1, true) then
        task.wait(0.1)
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
        task.wait(0.1)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
    end
end
local antiAfkConnection = nil
local antiAfkThread = nil
local gameAntiAfk, originalReconnect = nil, nil

local function restoreGameAntiAfk()
    if gameAntiAfk and originalReconnect then
        gameAntiAfk.Reconnect = originalReconnect
    end
    gameAntiAfk, originalReconnect = nil, nil
end

local function setAntiAfk(value)
    if antiAfkConnection then
        antiAfkConnection:Disconnect()
        antiAfkConnection = nil
    end
    if antiAfkThread then
        task.cancel(antiAfkThread)
        antiAfkThread = nil
    end
    restoreGameAntiAfk()
    if not value or not alive then return end

    antiAfkConnection = player.Idled:Connect(function()
        VirtualUser:CaptureController()
        local x, y = antiAfkClickPoint()
        if x ~= nil then VirtualUser:ClickButton2(Vector2.new(x, y)) end
    end)

    pcall(function()
        local module = require(player.PlayerScripts.Omni.Scripts.Player.AntiAfk)
        if type(module) == "table" and type(module.Reconnect) == "function" then
            gameAntiAfk, originalReconnect = module, module.Reconnect
            module.Reconnect = function() end
        end
    end)

    antiAfkThread = task.spawn(function()
        local VirtualInputManager = game:GetService("VirtualInputManager")
        while alive do
            local ok, message = pcall(antiAfkPulse, VirtualInputManager)
            if not ok then
                lastError = "Anti AFK: " .. tostring(message)
            end
            task.wait(60)
        end
    end)
end

-- Disconnect ping. The game shows an error message when the connection drops; the webhook
-- goes out through the executor, so it still sends after the game connection is gone.
-- If the internet itself is down the ping is kept in a file and retried every few seconds,
-- and a hub that loads later (after the game rejoins) sends whatever is still waiting.
local PENDING_PING_FILE = "FarmHub_pending_ping.json"
local RETRY_INTERVAL = 5
local pendingPing = nil
local lastDisconnectPing = -math.huge

local function savePendingPing()
    pcall(function()
        writefile(PENDING_PING_FILE, pendingPing and HttpService:JSONEncode(pendingPing) or "")
    end)
end

local function pendingPingText(ping)
    local text = string.format("**%s** was disconnected from the game at %s.",
        tostring(ping.name), os.date("%H:%M:%S", ping.time))
    if ping.reason and ping.reason ~= "" then
        text = text .. " Reason: " .. ping.reason
    end
    local late = os.time() - ping.time
    if late > 20 then
        text = text .. string.format(" (Sent %s late, at %s: the internet was down or the game had to rejoin.)",
            late >= 120 and (math.floor(late / 60) .. " minutes") or (late .. " seconds"),
            os.date("%H:%M:%S"))
    end
    return text
end

local function retryPendingPing()
    task.spawn(function()
        local mine = pendingPing
        while mine and pendingPing == mine do
            if sendWebhook(pendingPingText(mine), true) then
                if pendingPing == mine then
                    pendingPing = nil
                    savePendingPing()
                end
                return
            end
            task.wait(RETRY_INTERVAL)
        end
    end)
end

local function pingDisconnect(reason)
    if not alive or not S("Webhook.PingDisconnect") then return end
    if pendingPing or os.clock() - lastDisconnectPing < 60 then return end
    lastDisconnectPing = os.clock()
    pendingPing = { time = os.time(), name = player.Name, reason = reason }
    savePendingPing()
    retryPendingPing()
end

-- A ping left over from before the game rejoined: send it now.
task.defer(function()
    local ok, raw = pcall(function()
        return readfile(PENDING_PING_FILE)
    end)
    if not ok or type(raw) ~= "string" or raw == "" then return end
    local decoded, ping = pcall(function()
        return HttpService:JSONDecode(raw)
    end)
    if not decoded or type(ping) ~= "table" or type(ping.time) ~= "number" then return end
    -- Anything older than a day is dropped instead of pinging you about old news.
    if os.time() - ping.time > 86400 or not S("Webhook.PingDisconnect") then
        pcall(writefile, PENDING_PING_FILE, "")
        return
    end
    pendingPing = ping
    retryPendingPing()
end)

connect(GuiService.ErrorMessageChanged, function()
    local message = ""
    pcall(function()
        message = GuiService:GetErrorMessage()
    end)
    if message ~= "" then
        pingDisconnect(message)
    end
end)
pcall(function()
    connect(game:GetService("NetworkClient").ChildRemoved, function()
        pingDisconnect("connection to the server was lost")
    end)
end)

connect(GuiService.ErrorMessageChanged, function()
    if not alive or not S("Session.AutoReconnect") then return end
    task.wait(5)
    pcall(function()
        TeleportService:Teleport(game.PlaceId, player)
    end)
end)

-- Every 15 minutes the game asks Roblox to show its "follow this event" prompt. Blocking
-- swaps the game's own prompt function for one that does nothing; unblocking puts it back.
local eventPopup: {module: any?, original: any?} = {}
local function setEventPopupBlocked(value)
    if eventPopup.module and eventPopup.original then
        eventPopup.module.PromptToFollow = eventPopup.original
    end
    eventPopup.module, eventPopup.original = nil, nil
    if not value or not alive then return end

    local ok, message = pcall(function()
        local module = require(player.PlayerScripts.Omni.Scripts.Social.Events)
        assert(type(module) == "table" and type(module.PromptToFollow) == "function",
            "the game's event prompt was not found")
        eventPopup.module, eventPopup.original = module, module.PromptToFollow
        module.PromptToFollow = function() end
    end)
    if not ok then
        lastError = "Block event popup: " .. tostring(message)
    end
end

local cleanup
function hubMain.number(value)
    local ok, result = pcall(function() return Omni.Utils.Number:Format(value) end)
    return ok and tostring(result) or tostring(math.floor(value))
end
function hubMain.eventTimer(activity)
    local name = activity .. " " .. tostring(S(activity .. ".Difficulty"))
    local info = Omni.Shared.Gamemodes.List[name]
    if not info or type(info.OpenTimes) ~= "table" then return activity .. ": unavailable" end
    local elapsed = workspace:GetServerTimeNow() % 3600
    local wait = math.huge
    for _, minute in pairs(info.OpenTimes) do
        local since = (elapsed - minute * 60) % 3600
        if since < (info.EnterTime or 60) then return activity .. ": entry open" end
        wait = math.min(wait, 3600 - since)
    end
    return activity .. ": " .. (wait < math.huge and formatTime(wait) or "no schedule")
end
function hubMain.render()
    if not hubMain.labels.activity then return end
    hubMain.sample(Omni.Data)
    local mode = currentGamemode()
    local activity = "Idle"
    if mode then
        activity = mode
        local family = activityOf(mode)
        if family and statusLabels[family] then activity ..= "\n" .. statusLabels[family].Text end
        pcall(function()
            local hud = Omni.Interface.HUD.Gamemode
            if hud.Visible then activity ..= "\nWave / rooms: " .. hud.Information.Wave.Value.Text end
        end)
    elseif busyBoss then
        activity = busyBoss == worldBoss and ("World Boss\n" .. bossStatus(worldBoss)) or "Collecting lobby chests"
    elseif S("MobFarm.AutoFarm") then
        activity = "Mob Farm\n" .. statusLabels.MobFarm.Text
    elseif SIDE_QUESTS.active then
        activity = "Side Quest\n" .. statusLabels.SideQuests.Text
    elseif S("DragonDefense.Enabled") then
        activity = "Dragon Defense\n" .. statusLabels.DragonDefense.Text
    elseif S("Culling.Enabled") then
        activity = "Culling\n" .. statusLabels.Culling.Text
    elseif worldBoss.enabled then
        activity = "World Boss\n" .. bossStatus(worldBoss)
    end
    hubMain.labels.activity.Text = "Activity: " .. activity
    hubMain.labels.world.Text = "Current world: " .. tostring(Omni.Data.Maps and Omni.Data.Maps.Current or "Loading")
    local bossTimer = worldBoss.phase == "holding" and "World Boss: active"
        or ("World Boss: " .. formatTime(INTERVAL - workspace:GetServerTimeNow() % INTERVAL))
    hubMain.labels.events.Text = bossTimer .. "\n" .. hubMain.eventTimer("Dungeon") .. "\n" .. hubMain.eventTimer("Trial")
    local session = hubMain.session
    local elapsed = math.max(0, workspace:GetServerTimeNow() - session.start)
    hubMain.labels.stats.Text = "Session time: " .. formatTime(elapsed)
        .. "\nEnemies defeated: " .. hubMain.number(session.kills)
        .. "\nDamage dealt: " .. hubMain.number(session.damage)
        .. "\nRuns entered / ended: " .. session.entered .. " / " .. session.ended
        .. "\nRewards confirmed: " .. session.rewards
        .. "\nItems received: " .. hubMain.number(session.items)
    hubMain.renderPerformance()
    hubMain.updateLabel()
end
-- Tabs -------------------------------------------------------------------------------

-- Built inside one function so the tab variables do not count against Luau's limit of 200
-- locals in the main body. Setting keys are unchanged from earlier versions, so saved
-- settings carry over.
local errorLabel
-- Dragon City helpers -------------------------------------------------------------------

hubMain.RARITY_RANK = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5,
    Mythical = 6, Secret = 7, Exclusive = 8 }
hubMain.incubatorIds = {}
hubMain.incubatorSkip = {}
-- Labels end in "#" plus the start of the fighter ID. The level in front changes as the
-- fighter trains, so saved queue entries are matched by that ID tag, not the whole label.
function hubMain.labelTag(label)
    return type(label) == "string" and string.match(label, "#(%S+)$") or nil
end
function hubMain.fighterLabel(id, fighter)
    local info = Omni.Shared.Fighters.List[fighter.Name]
    local level, slotted = fighter.Level or 1, false
    pcall(function()
        local incubator = Omni.Shared.Incubator
        local slot = incubator.GetFighterSlot(Omni.Data, id)
        if slot then
            slotted = true
            level = incubator.EstimateExp(Omni.Data, slot, workspace:GetServerTimeNow())
        end
    end)
    return string.format("%s%s %s Lv %d%s #%s", fighter.Name, fighter.Shiny and " Shiny" or "",
        info and info.Rarity or "?", level, slotted and " (in slot)" or "", string.sub(id, 1, 6))
end
-- Fighters that can still level up, best first. Queued fighters always stay listed.
function hubMain.incubatorOptions()
    local entries, queued = {}, {}
    hubMain.incubatorLabels = {}
    for _, label in ipairs(settings["Dragon.IncubatorQueue"] or {}) do
        local tag = hubMain.labelTag(label)
        if tag then queued[tag] = true end
    end
    pcall(function()
        local fighters = Omni.Shared.Fighters
        for id, fighter in pairs(Omni.Data.Fighters.List) do
            local info = fighters.List[fighter.Name]
            if info then
                local label = hubMain.fighterLabel(id, fighter)
                local tag = hubMain.labelTag(label)
                hubMain.incubatorIds[tag] = id
                hubMain.incubatorLabels[tag] = label
                if queued[tag] or (fighter.Level or 1) < fighters.GetFighterMaxLevel(fighter, Omni.Data) then
                    entries[#entries + 1] = { label = label, rank = hubMain.RARITY_RANK[info.Rarity] or 0,
                        shiny = fighter.Shiny and 1 or 0 }
                end
            end
        end
    end)
    table.sort(entries, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        if a.shiny ~= b.shiny then return a.shiny > b.shiny end
        return a.label < b.label
    end)
    local labels = {}
    for i, entry in ipairs(entries) do labels[i] = entry.label end
    if #labels == 0 then labels[1] = "--" end
    return labels
end
-- Every boost and reward Shenron can offer, in a sensible default order.
function hubMain.wishDefaults()
    local preferred = { "Secret Potion", "Potara", "Shiny Potion", "Mythical Potion", "Free Gems",
        "+2.5 Luck", "2x Drops", "+2.5 Gacha Luck" }
    local names = {}
    pcall(function()
        local wish = Omni.Shared.DragonWish
        for _, name in ipairs(wish.GetOrderedBoosts()) do names[#names + 1] = name end
        for _, reward in ipairs(wish.Rewards) do names[#names + 1] = reward.Name end
    end)
    local order = {}
    for _, name in ipairs(preferred) do
        if table.find(names, name) then order[#order + 1] = name end
    end
    for _, name in ipairs(names) do
        if not table.find(order, name) then order[#order + 1] = name end
    end
    return order
end

-- Manual rolls for a pinned weapon; locked entries count toward the three-breathing goal.
hubMain.tripleWeaponIds = {}
function hubMain.breathingCount(weapon)
    local count, locked = 0, 0
    for _, entry in pairs(weapon and weapon.Breathings and weapon.Breathings.Current or {}) do
        if type(entry) == "table" and type(entry.Name) == "string" and entry.Name ~= "" then
            count += 1
            if entry.Locked then locked += 1 end
        end
    end
    return count, locked
end
function hubMain.tripleWeaponOptions()
    local labels = {"Game Menu Selection", "Equipped Weapon"}
    local weapons = {}
    hubMain.tripleWeaponIds = {}
    for id, weapon in pairs(Omni.Data.Weapons.List or {}) do
        if weapon.Name ~= "Melee" then
            local label = tostring(weapon.Name) .. " Lv " .. tostring(weapon.Level or 1) .. " #" .. string.sub(id, 1, 8)
            weapons[#weapons + 1] = label
            hubMain.tripleWeaponIds[label] = id
        end
    end
    table.sort(weapons)
    for _, label in ipairs(weapons) do labels[#labels + 1] = label end
    return labels
end
function hubMain.tripleSelectedWeapon()
    local choice = S("Slayers.TripleWeapon")
    if choice == "Equipped Weapon" then return Omni.Data.Weapons.Equipped end
    if choice ~= "Game Menu Selection" then return hubMain.tripleWeaponIds[choice] end
    local ok, ui = pcall(require, player.PlayerScripts.Omni.Scripts.Interface.Breathings)
    if ok and type(ui.RefreshUI) == "function" and type(getupvalues) == "function" then
        for _, value in pairs(getupvalues(ui.RefreshUI)) do
            if type(value) == "string" and Omni.Data.Weapons.List[value] then return value end
        end
    end
    return nil
end
function hubMain.stopTriple(message)
    hubMain.tripleId, hubMain.triplePending = nil, nil
    settings["Slayers.TriplePinnedId"] = nil
    if allToggles["Slayers.RollUntilThree"] then allToggles["Slayers.RollUntilThree"].set(false, true) end
    setStatus("TripleBreathings", message)
end
function hubMain.startTriple(value)
    hubMain.triplePending = nil
    if not value then hubMain.tripleId = nil;settings["Slayers.TriplePinnedId"] = nil;setStatus("TripleBreathings", "Stopped");return end
    local id = S("Slayers.TriplePinnedId") or hubMain.tripleSelectedWeapon()
    local weapon = id and Omni.Data.Weapons.List[id]
    if not weapon then hubMain.stopTriple("Select a weapon first");return end
    hubMain.tripleId, hubMain.tripleRolls = id, 0
    settings["Slayers.TriplePinnedId"] = id
    if allToggles["Slayers.AutoBreathings"] then allToggles["Slayers.AutoBreathings"].set(false) end
    pcall(function()
        local ui = require(player.PlayerScripts.Omni.Scripts.Interface.Breathings)
        ui.CancelAuto()
    end)
    local count = hubMain.breathingCount(weapon)
    if count >= 3 then
        hubMain.stopTriple(tostring(weapon.Name) .. " already has 3 breathings; no rolls spent")
    else
        setStatus("TripleBreathings", "Rolling " .. tostring(weapon.Name) .. ": " .. count .. "/3 breathings")
    end
end

-- Multi-choice filters apply to unlocked results only.
function hubMain.breathSelection(value)
    local result, seen = {}, {}
    if type(value) == "string" then value = {value} end
    for _, name in ipairs(type(value) == "table" and value or {}) do
        if type(name) == "string" and name ~= "--" and not seen[name] then
            seen[name] = true
            result[#result + 1] = name
        end
    end
    return result
end
settings["Slayers.StopAt"] = hubMain.breathSelection(settings["Slayers.StopAt"])
settings["Slayers.Rarity"] = hubMain.breathSelection(settings["Slayers.Rarity"])
function hubMain.breathMatch(entry, names, rarities, gameStops)
    if type(entry) ~= "table" or entry.Locked then return false end
    if #names == 0 and #rarities == 0 then
        return gameStops and gameStops[entry.Name] and gameStops[entry.Name][entry.Rarity] == true or false
    end
    return (#names == 0 or table.find(names, entry.Name) ~= nil)
        and (#rarities == 0 or table.find(rarities, entry.Rarity) ~= nil)
end
function hubMain.stopAutoBreathings(message)
    hubMain.autoBreathingId, hubMain.autoBreathingPending = nil, nil
    settings["Slayers.BreathingPinnedId"] = nil
    if allToggles["Slayers.AutoBreathings"] then allToggles["Slayers.AutoBreathings"].set(false, true) end
    setStatus("AutoBreathings", message)
end
function hubMain.startAutoBreathings(value)
    hubMain.autoBreathingPending = nil
    if not value then
        hubMain.autoBreathingId = nil
        settings["Slayers.BreathingPinnedId"] = nil
        setStatus("AutoBreathings", "Stopped")
        return
    end
    if S("Slayers.RollUntilThree") then hubMain.stopTriple("Stopped: Auto Breathings enabled") end
    local id = S("Slayers.BreathingPinnedId") or hubMain.tripleSelectedWeapon()
    if not id or not Omni.Data.Weapons.List[id] then
        hubMain.stopAutoBreathings("Select a weapon first")
        return
    end
    hubMain.autoBreathingId, hubMain.autoBreathingRolls = id, 0
    settings["Slayers.BreathingPinnedId"] = id
    pcall(function()
        local ui = require(player.PlayerScripts.Omni.Scripts.Interface.Breathings)
        ui.CancelAuto()
    end)
    setStatus("AutoBreathings", "Checking unlocked breathings on " .. tostring(Omni.Data.Weapons.List[id].Name))
end

-- Talent queue IDs stay stable when a fighter's level or displayed stats change.
hubMain.talentIds, hubMain.talentLabels, hubMain.talentStats = {}, {}, {}
function hubMain.talentSource()
    return Omni.Shared.Gacha.List.Talents.Source.Talents
end
function hubMain.talentUnitOptions()
    local entries = {}
    hubMain.talentIds, hubMain.talentLabels = {}, {}
    for id, fighter in pairs(Omni.Data.Fighters.List or {}) do
        local tag = string.sub(id, 1, 8)
        local label = tostring(fighter.Name) .. (fighter.Shiny and " Shiny" or "")
            .. " Lv " .. tostring(fighter.Level or 1) .. " #" .. tag
        hubMain.talentIds[tag], hubMain.talentLabels[tag] = id, label
        entries[#entries + 1] = label
    end
    table.sort(entries)
    return entries
end
function hubMain.talentRankOptions()
    local entries, options = {}, {"Ignore"}
    for rank, info in pairs(hubMain.talentSource().Ranks) do
        entries[#entries + 1] = {name=rank,index=info.Index or 0}
    end
    table.sort(entries, function(a,b)return a.index<b.index end)
    for _, entry in ipairs(entries) do options[#options + 1] = entry.name end
    return options
end
function hubMain.talentEvaluation(fighter, goals)
    local source, remaining, reached, blocked, chosen = hubMain.talentSource(), {}, {}, {}, 0
    local talents = fighter.Talents or {}
    local current, locked = talents.Current or {}, talents.Locked or {}
    for stat, goal in pairs(goals) do
        if goal ~= "Ignore" and source.Ranks[goal] then
            chosen += 1
            local rank = source.Ranks[current[stat]]
            if rank and rank.Index >= source.Ranks[goal].Index then
                if not locked[stat] then reached[#reached + 1] = stat end
            else
                remaining[#remaining + 1] = stat
                if locked[stat] then blocked[#blocked + 1] = stat end
            end
        end
    end
    table.sort(reached);table.sort(remaining);table.sort(blocked)
    return chosen, remaining, reached, blocked
end
function hubMain.stopTalents(message)
    hubMain.talentPending = nil
    if allToggles["Talents.Enabled"] then allToggles["Talents.Enabled"].set(false, true) end
    setStatus("Talents", message)
end
function hubMain.startTalents(value)
    hubMain.talentPending, hubMain.talentCurrent, hubMain.talentRolls = nil, nil, 0
    if not value then setStatus("Talents", "Stopped");return end
    pcall(function()
        local ui = require(player.PlayerScripts.Omni.Scripts.Interface.Gacha.Talents)
        ui.CancelAuto()
    end)
    setStatus("Talents", "Checking queued units")
end
function hubMain.refreshTalentQueue()
    if not hubMain.talentQueue then return end
    local options = hubMain.talentUnitOptions()
    farmCatalog.updateOptions(hubMain.talentQueue, "Talents.Queue", options)
    local refreshed, changed = {}, false
    for index, label in ipairs(S("Talents.Queue") or {}) do
        local current = hubMain.talentLabels[hubMain.labelTag(label)] or label
        refreshed[index] = current
        if current ~= label then changed = true end
    end
    if changed then hubMain.talentQueue.set(refreshed, true) end
end

local function buildTabs()
    local tab, section
    -- Main
    hubMain.tab = addTab("Main")
    section = addSection(hubMain.tab, 1, "Activity Dashboard")
    hubMain.labels.activity = addLabel(section, "Activity: loading...", COLORS.accent)
    hubMain.labels.world = addLabel(section, "Current world: loading...", COLORS.text)
    section = addSection(hubMain.tab, 1, "Next Events")
    hubMain.labels.events = addLabel(section, "Loading timers...", COLORS.text)
    section = addSection(hubMain.tab, 1, "Stats")
    hubMain.labels.performance = addLabel(section, "Measuring performance...", COLORS.text)
    section = addSection(hubMain.tab, 2, "Session Statistics")
    hubMain.labels.stats = addLabel(section, "Starting session...", COLORS.text)
    addLabel(section, "Counts confirmed changes since starting this hub. Runs ended include manual and automatic exits.", COLORS.dim)
    addButton(section, "Reset Session Statistics", function()
        hubMain.resetStats()
        hubMain.render()
    end)
    section = addSection(hubMain.tab, 2, "Updates")
    hubMain.labels.update = addLabel(section, "", COLORS.accent)
    hubMain.updateLabel()
    addButton(section, "Check for Updates", hubMain.checkUpdate)
    addButton(section, "Reload from GitHub", hubMain.reload)
    addLabel(section, "Reload saves your settings and replaces the old hub. Session statistics are retained.", COLORS.dim)

    -- Favorites (starred sections are moved here while this tab is open)
    favorites.tab = addTab("Favorites")
    favorites.empty = addSection(favorites.tab, 1, "No favorites yet")
    addLabel(favorites.empty, "Click the star in the corner of any section on another tab to pin "
        .. "the whole section here. Click the star again to remove it.", COLORS.dim)

    -- Bosses
    tab = addTab("Bosses")
    section = addSection(tab, 1, "World Boss")
    worldBoss.toggle = addToggle(section, "Auto World Boss", "Bosses.WorldBoss", false, function(value)
        setBossEnabled(worldBoss, value)
    end)
    worldBoss.statusLabel = addLabel(section, "Stopped", COLORS.accent)
    addLabel(section, "Goes to Sins Kingdom for Demon Melyode as soon as the :00 dungeon is finished "
        .. "(or about a minute after :00 if you did not join it), and pauses farming until "
        .. "the boss is dead.", COLORS.dim)

    section = addSection(tab, 2, "Spawn Point")
    addToggle(section, "Return after World Boss", "Bosses.ReturnAfterBoss", true, W)
    bossReturn.label = addLabel(section, "", COLORS.accent)
    bossReturn.render()
    addButton(section, "Set Spawn Point to My Position", bossReturn.setHere)
    addLabel(section, "Saves your world, position and facing direction. Returns here after the boss dies or the encounter times out.", COLORS.dim)

    section = addSection(tab, 1, "Safety")
    addToggle(section, "Pause bosses in dungeon/trial", "Bosses.PauseInGamemode", true, W)

    -- Farming
    tab = addTab("Farming")
    section = addSection(tab, 1, "Mob Farm")
    addToggle(section, "Auto Farm", "MobFarm.AutoFarm", false, W)
    statusLabels.MobFarm = addLabel(section, "Disabled", COLORS.accent)
    addToggle(section, "Send fighters to target", "MobFarm.SendToClosest", false, W)
    farmCatalog.dropdowns["MobFarm.World"] = addDropdown(section, "World", "MobFarm.World", MAP_NAMES, "Heaven Island", function()
        farmCatalog.refreshMobs()
    end)
    farmCatalog.mobs = addDropdown(section, "Mobs (select multiple)", "MobFarm.Mobs",
        mobNames(getSetting("MobFarm.World", "Heaven Island")), { "Hawk Eyes" }, farmCatalog.remember, true)
    addDropdown(section, "Targeting mode", "MobFarm.TargetMode",
        {"Closest", "Lowest Health", "Highest Health", "Bosses First", "Rotate Types"}, "Closest", W)
    addToggle(section, "Finish current target before switching", "MobFarm.FinishTarget", true, W)
    addLabel(section, "Tick any mobs to farm. Targets the closest selected mob; untick to remove.", COLORS.dim)
    addSlider(section, "Distance from mob", "MobFarm.Offset", 0, 15, 3)

    section = addSection(tab, 2, "Secret Pity (stars)")
    statusLabels.Pity = addLabel(section, "Loading...", COLORS.text)

    section = addSection(tab, 2, "Priority")
    addToggle(section, "Leave for a higher priority", "Priority.LeaveForPriority", true, W)
    addPriorityList(section, "Priority.Order",
        { "Trial", "Dungeon", "World Boss", "Culling", "Dragon Defense", "Quest", "Mob Farm" }, "Activity to move")

    -- Gamemodes
    tab = addTab("Gamemodes")
    section = addSection(tab, 1, "Trial")
    addToggle(section, "Auto Trial", "Trial.AutoTrial", false, W)
    statusLabels.Trial = addLabel(section, "", COLORS.accent)
    addDropdown(section, "Difficulty", "Trial.Difficulty", DIFFICULTIES, "Easy", W)
    addToggle(section, "Walk to enemies (no teleport)", "Trial.WalkToEnemy", false, W)
    addToggle(section, "Auto Leave at wave", "Trial.AutoLeave", false, W)
    addSlider(section, "Leave at wave", "Trial.Wave", 0, 100, 26)

    section = addSection(tab, 1, "Dungeon")
    addToggle(section, "Auto Dungeon", "Dungeon.AutoDungeon", false, W)
    addLabel(section, "Fights enemies, approaches available doors and opens them after the room is cleared.", COLORS.dim)
    statusLabels.Dungeon = addLabel(section, "", COLORS.accent)
    addDropdown(section, "Difficulty", "Dungeon.Difficulty", DIFFICULTIES, "Easy", W)
    addToggle(section, "Walk to enemies (no teleport)", "Dungeon.WalkToEnemy", false, W)
    addToggle(section, "Auto Leave at wave", "Dungeon.AutoLeave", false, W)
    addSlider(section, "Leave at wave", "Dungeon.Wave", 1, 100, 26)

    section = addSection(tab, 2, "Culling Game")
    statusLabels.Culling = addLabel(section, "Disabled", COLORS.accent)
    addDropdown(section, "Mode", "Culling.Role", {"Host", "Player"}, "Host", W)
    addToggle(section, "Enable Culling Game", "Culling.Enabled", false, W)
    addDropdown(section, "Difficulty", "Culling.Difficulty", DIFFICULTIES, "Medium", W)
    do
        local playerSlider = addSlider(section, "Players needed (including you)", "Culling.StartPlayers", 1, 4, 2)
        env.FarmHubCullingPlayerSlider = playerSlider
    end
    addTextBox(section, "Player mode: host username / user ID", "Culling.Host", "", "Blank = any public lobby")
    addLabel(section, "Host starts alone after 60s with no joins. Player count stays at 1 until you change it.", COLORS.dim)
    addToggle(section, "Teleport + auto attack", "Culling.TeleportToEnemies", true, W)
    addToggle(section, "Auto Leave at wave", "Culling.AutoLeave", false, W)
    addNumberBox(section, "Leave when this wave begins", "Culling.Wave", 6)
    addLabel(section, "Teleports once above each enemy. Minis first while the boss is shielded. Settings stay editable.", COLORS.dim)

    section = addSection(tab, 2, "Dragon Defense")
    statusLabels.DragonDefense = addLabel(section, "Disabled", COLORS.accent)
    addDropdown(section, "Mode", "DragonDefense.Role", {"Host", "Player"}, "Host", W)
    addToggle(section, "Auto Dragon Defense", "DragonDefense.Enabled", false, W)
    addDropdown(section, "Difficulty", "DragonDefense.Difficulty", DIFFICULTIES, "Easy", W)
    do
        local playerSlider = addSlider(section, "Players needed (including you)", "DragonDefense.StartPlayers", 1, 10, 1)
        env.FarmHubDragonDefensePlayerSlider = playerSlider
    end
    addTextBox(section, "Player mode: host username / user ID", "DragonDefense.Host", "", "Blank = any public lobby")
    addToggle(section, "Teleport + auto attack", "DragonDefense.TeleportToEnemies", true, W)
    addToggle(section, "Auto Leave at wave", "DragonDefense.AutoLeave", false, W)
    addSlider(section, "Leave when this wave begins", "DragonDefense.Wave", 1, 50, 50)
    addLabel(section, "Uses the Culling party flow. Host costs 1 Saiyan Key per run; up to 10 players. "
        .. "Completes all 50 waves unless leave-wave is enabled, then repeats. Follows moving enemies and pauses mob farming. "
        .. "Turn this on to farm Ball 7 while Dragon Ball farming handles the other balls.", COLORS.dim)

    -- Worlds
    tab = addTab("Worlds")
    section = addSection(tab, 1, "Lobby")
    addToggle(section, "Auto Claim Chests", "Lobby.AutoChests", false, W)
    statusLabels.Chests = addLabel(section, "Disabled", COLORS.accent)
    addToggle(section, "Auto Upgrade", "Lobby.AutoUpgrade", false, W)
    addDropdown(section, "Upgrade to buy", "Lobby.Upgrades", sortedKeys(function()
        return Omni.Shared.Upgrade.List[UPGRADE_GROUP].Upgrades
    end), "Drops", W)

    section = addSection(tab, 1, "Heaven Island")
    addToggle(section, "Auto Haki", "Heaven.AutoHaki", false, W)
    addToggle(section, "Auto Pick Up Fruits", "Heaven.AutoPickUpFruits", false, W)
    addToggle(section, "Auto Prestige", "Heaven.AutoPrestige", false, W)

    section = addSection(tab, 2, "Slayers Village")
    addToggle(section, "Auto Progression", "Slayers.AutoProgression", false, W)
    hubMain.tripleDropdown = addDropdown(section, "Weapon to roll", "Slayers.TripleWeapon",
        hubMain.tripleWeaponOptions(), "Game Menu Selection", function()
            if S("Slayers.RollUntilThree") then hubMain.stopTriple("Weapon changed; enable again to start") end
            if S("Slayers.AutoBreathings") then hubMain.stopAutoBreathings("Weapon changed; enable again to start") end
        end)
    addButton(section, "Refresh weapon list", function()
        hubMain.tripleDropdown.setOptions(hubMain.tripleWeaponOptions())
    end)
    addDropdown(section, "Desired breathings (select multiple)", "Slayers.StopAt", sortedKeys(function()
        return Omni.Shared.Breathings.List
    end), {}, W, true, "Any breathing")
    do
        local rarities = {}
        for _, rarity in ipairs(RARITIES) do if rarity ~= "--" then rarities[#rarities + 1] = rarity end end
        addDropdown(section, "Desired rarities (select multiple)", "Slayers.Rarity", rarities, {}, W, true, "Any rarity")
    end
    addToggle(section, "Auto Breathings", "Slayers.AutoBreathings", false, hubMain.startAutoBreathings)
    statusLabels.AutoBreathings = addLabel(section, "Stopped", COLORS.accent)
    addLabel(section, "Manually spins the chosen weapon until an unlocked breathing matches your selected breathing and rarity. "
        .. "Locked breathings are preserved and never trigger the stop. An empty list means any.", COLORS.dim)
    addSubHeader(section, "Roll until three breathings")
    addToggle(section, "Roll Until 3 Breathings", "Slayers.RollUntilThree", false, hubMain.startTriple)
    statusLabels.TripleBreathings = addLabel(section, "Stopped", COLORS.accent)
    addLabel(section, "Stops at any 3 breathings, including locked ones. This separate mode ignores the filters above.", COLORS.dim)

    section = addSection(tab, 2, "Cursed Academy")
    addToggle(section, "Auto Cursed Technique", "Cursed.AutoCursedTechnique", false, W)

    section = addSection(tab, 2, "Sins Kingdom")
    addToggle(section, "Auto Commandments", "Sins.AutoCommandments", false, W)
    statusLabels.Commandments = addLabel(section, "Disabled", COLORS.accent)

    section = addSection(tab, 1, "Dragon City: Incubator")
    addToggle(section, "Auto Incubator", "Dragon.AutoIncubator", false, W)
    statusLabels.Incubator = addLabel(section, "Disabled", COLORS.accent)
    hubMain.incubatorQueue = addDropdown(section, "Queue (incubated in the order you tick them)",
        "Dragon.IncubatorQueue", hubMain.incubatorOptions(), {}, W, true, "Pick fighters...")
    addNumberBox(section, "Take out at level (0 = max level)", "Dragon.IncubatorTarget", 0)
    addToggle(section, "Fill from inventory when the queue is done", "Dragon.IncubatorFill", false, W)
    addToggle(section, "Auto Upgrade slots with Yen", "Dragon.IncubatorUpgrade", false, W)
    addLabel(section, "Puts the next queued fighter in each free slot and takes it out at the target level. "
        .. "Fill picks the best unequipped fighter that is not maxed (highest rarity, Shiny first).", COLORS.dim)

    section = addSection(tab, 2, "Dragon City: Dragon Balls")
    addToggle(section, "Auto Farm Dragon Balls", "Dragon.AutoBalls", false, W)
    statusLabels.DragonBalls = addLabel(section, "Disabled", COLORS.accent)
    addToggle(section, "Auto Summon Shenron", "Dragon.AutoSummon", false, W)
    statusLabels.DragonWish = addLabel(section, "", COLORS.accent)
    addPriorityList(section, "Dragon.WishOrder", hubMain.wishDefaults(), "Wish to move")
    addLabel(section, "Hunts only the enemies whose ball you are missing (Secret and Boss first) and pauses "
        .. "Mob Farm meanwhile. Ball 7 drops from Dragon Defense; enable it in Gamemodes to farm that ball. "
        .. "Shenron's offer is answered with the highest wish in this list.", COLORS.dim)

    -- Quests and rewards
    tab = addTab("Quests & Rewards")
    section = addSection(tab, 1, "Quests")
    addToggle(section, "Auto Quest (main and side)", "Quests.AutoQuest", false, W)
    addToggle(section, "Daily Quests", "Quests.Daily", false, W)
    addToggle(section, "Weekly Quests", "Quests.Weekly", false, W)

    section = addSection(tab, 1, "Side Quests")
    SIDE_QUESTS.section = section
    SIDE_QUESTS.info = addLabel(section, "Finding side quests...", COLORS.dim)
    SIDE_QUESTS.info.LayoutOrder = 1
    addLabel(section, "Accepts selected quests, farms their required bosses, and claims completed rewards. Bosses and gamemodes take priority.", COLORS.dim).LayoutOrder = 2
    statusLabels.SideQuests = addLabel(section, "Select a side quest", COLORS.accent)
    statusLabels.SideQuests.LayoutOrder = 3
    SIDE_QUESTS.refresh()

    section = addSection(tab, 1, "Rewards")
    addToggle(section, "Auto Index", "Rewards.AutoIndex", false, W)
    addToggle(section, "Auto Achievement", "Rewards.AutoAchievement", false, W)
    addToggle(section, "Auto Level Rewards", "Rewards.AutoLevelRewards", false, W)
    addToggle(section, "Auto Daily", "Rewards.AutoDaily", false, W)
    addToggle(section, "Auto Time", "Rewards.AutoTime", false, W)
    addToggle(section, "Auto Inbox", "Rewards.AutoInbox", false, W)

    section = addSection(tab, 2, "Level Upgrades")
    addToggle(section, "Auto Upgrade", "LevelUpgrades.AutoUpgrade", false, W)
    addPriorityList(section, "LevelUpgrades.Order",
        { "Fighter Damage", "Yen", "Luck", "Drops" }, "Stat to move")
    addNumberBox(section, "Fighter Damage target", "LevelUpgrades.FighterDamageTarget", 1)
    addNumberBox(section, "Yen target", "LevelUpgrades.YenTarget", 2)
    addNumberBox(section, "Luck target", "LevelUpgrades.LuckTarget", 3)
    addNumberBox(section, "Drops target", "LevelUpgrades.DropsTarget", 4)

    -- Talents
    tab = addTab("Talents")
    section = addSection(tab, 1, "Unit Queue")
    hubMain.talentQueue = addDropdown(section, "Units (processed in the order you select them)", "Talents.Queue",
        hubMain.talentUnitOptions(), {}, W, true, "Select units...")
    addButton(section, "Refresh unit list", hubMain.refreshTalentQueue)
    addToggle(section, "Auto Talent", "Talents.Enabled", false, hubMain.startTalents)
    statusLabels.Talents = addLabel(section, "Stopped", COLORS.accent)
    addLabel(section, "Finishes one unit's rank goals before moving to the next. Locks stats that reach their goals, "
        .. "preserves your existing locks, and stops when the queue is complete or Talent Tokens run out.", COLORS.dim)
    section = addSection(tab, 2, "Minimum Talent Ranks")
    do
        local fields = {}
        for stat, info in pairs(hubMain.talentSource().List) do
            fields[#fields + 1] = {name=stat,index=info.Index or 0,default=info.EndRank or "S"}
        end
        table.sort(fields, function(a,b)return a.index<b.index end)
        for _, field in ipairs(fields) do
            hubMain.talentStats[#hubMain.talentStats + 1] = field.name
            addDropdown(section, field.name, "Talents.Goal." .. field.name, hubMain.talentRankOptions(), field.default, W)
        end
    end
    addLabel(section, "Ignore leaves a stat out of the goal. If an existing lock is below your target, "
        .. "unlock that stat yourself before starting. One stat stays unlocked, as required by the game.", COLORS.dim)

    -- Items and shop
    tab = addTab("Items & Shop")
    section = addSection(tab, 1, "Accessories")
    addToggle(section, "Auto Evolve Accessories", "Equipment.AutoEvolveAccessories", false, W)
    section = addSection(tab, 1, "Potions")
    addToggle(section, "Auto Drink", "Potions.AutoDrink", false, W)
    addDropdown(section, "Potion (-- drinks every kind)", "Potions.Selected", sortedKeys(function()
        return Omni.Shared.Potions.List
    end, "--"), "--", W)

    section = addSection(tab, 1, "Sacred Artefacts")
    addToggle(section, "Auto Upgrade Artefacts", "Artefacts.AutoUpgrade", false, W)
    statusLabels.Artefacts = addLabel(section, "Disabled", COLORS.accent)

    section = addSection(tab, 2, SHOP_NAME)
    addToggle(section, "Auto Buy ticked items", "Shop.AutoBuy", false, W)
    statusLabels.Shop = addLabel(section, "Disabled", COLORS.accent)
    addButton(section, "Refresh Shop", function()
        local ok, reason = pcall(function()
            local price = Omni.Shared.Merchant.GetRestockPrice(SHOP_NAME)
            local owned = Omni.Shared.Upgrade.GetPriceAmount(Omni.Data, price)
            if owned < price.Amount then
                setStatus("Shop", "Refresh needs " .. commas(price.Amount) .. " " .. price.Name)
                return
            end
            Omni.Signal:FireSelf("Interface", "Confirmation", "Start", {
                Title = "Refresh Adventurer Shop",
                Description = "Spend " .. commas(price.Amount) .. " " .. price.Name .. " to refill every item?",
                ConfirmText = "Refresh",
                CancelText = "Cancel",
                Callback = function()
                    fire("Merchant", "RestockAll", SHOP_NAME)
                    setStatus("Shop", "Shop refresh requested")
                end
            })
        end)
        if not ok then setStatus("Shop", "Refresh failed: " .. tostring(reason)) end
    end)
    addSubHeader(section, "Items to buy")
    local products = {}
    pcall(function()
        for name, info in pairs(Omni.Shared.Merchant.List[SHOP_NAME].Products) do
            products[#products + 1] = { name = name, index = info.Index or 0 }
        end
    end)
    table.sort(products, function(a, b)
        return a.index < b.index
    end)
    for _, product in ipairs(products) do
        addToggle(section, product.name, "Shop.Buy." .. product.name, false, W)
    end

    -- Webhook
    tab = addTab("Webhook")
    section = addSection(tab, 1, "Discord Webhook")
    addTextBox(section, "Webhook URL", "Webhook.Url", "", "https://discord.com/api/webhooks/...")
    addTextBox(section, "Your Discord user ID (for the ping)", "Webhook.UserId", "", "e.g. 123456789012345678")
    addLabel(section, "Leave the user ID empty to ping @everyone in that channel instead.", COLORS.dim)
    local testLabel
    addButton(section, "Send Test Message", function()
        testLabel.Text = "Sending..."
        task.spawn(function()
            local ok, reason = sendWebhook("Test message from Wrld Hub for **" .. player.Name .. "**.", true)
            testLabel.Text = ok and "Test sent. Check your Discord channel." or tostring(reason)
        end)
    end)
    testLabel = addLabel(section, "", COLORS.accent)

    section = addSection(tab, 2, "Ping me when")
    addToggle(section, "I get disconnected", "Webhook.PingDisconnect", true, W)
    addToggle(section, "I roll a Secret", "Webhook.PingSecret", true, W)
    statusLabels.Webhook = addLabel(section, "", COLORS.accent)

    -- Settings
    tab = addTab("Settings")
    section = addSection(tab, 1, "Session")
    local fpsDefault = hubMain.performance.originalCap == 15 and "15"
        or hubMain.performance.originalCap == 60 and "60" or "Unlimited"
    addDropdown(section, "FPS limit", "Session.FpsLimit", {"15", "60", "Unlimited"}, fpsDefault, hubMain.setFpsLimit)
    hubMain.labels.fpsSetting = addLabel(section, "", COLORS.dim)
    hubMain.setFpsLimit(getSetting("Session.FpsLimit", fpsDefault))
    addLabel(section, "Background windows use 30 FPS. Focusing Roblox restores your selected limit.", COLORS.dim)
    addToggle(section, "Anti AFK", "Session.AntiAfk", true, setAntiAfk)
    addDropdown(section, "Anti AFK method (every minute)", "Session.AntiAfkMethod",
        { "Click + Jump", "Click", "Jump" }, "Click + Jump", W)
    addToggle(section, "Auto Reconnect", "Session.AutoReconnect", false, W)
    addToggle(section, "Notifications", "Session.Notifications", true, W)
    addToggle(section, "Block Roblox event popup", "Session.BlockEventPopup", true, setEventPopupBlocked)

    section = addSection(tab, 1, "Status")
    errorLabel = addLabel(section, "No worker errors", COLORS.accent)
    addLabel(section, "Every join, leave, purchase and upgrade the hub makes is written to "
        .. "FarmHub_log.txt in your Potassium workspace folder.", COLORS.dim)

    section = addSection(tab, 2, "Controls")
    menuKey.button = addButton(section, "", function()
        menuKey.capturing = not menuKey.capturing
        menuKey.render()
    end)
    menuKey.render()
    addButton(section, "Stop All Features", function()
        for key, toggle in pairs(allToggles) do
            if settings[key] == true and string.sub(key, 1, 8) ~= "Session."
                and string.sub(key, 1, 8) ~= "Webhook." and string.sub(key, 1, 9) ~= "Shop.Buy."
                and key ~= "Bosses.PauseInGamemode" and key ~= "Bosses.ReturnAfterBoss" and key ~= "Priority.LeaveForPriority"
                and key ~= "Culling.TeleportToEnemies" and key ~= "DragonDefense.TeleportToEnemies" then
                toggle.set(false)
            end
        end
    end)
    addButton(section, "Save Settings", saveSettings)
    addButton(section, "Unload Hub", function()
        cleanup(true)
    end)
    section = addSection(tab, 2, "Configs")
    do
        local nameBox = addEntryBox(section, "Config name", "", "e.g. Boss farming")
        local savedDropdown = addDropdown(section, "Saved configs", "Configs.Selected",
            configStore.names(), "--", W)
        local textBox = addEntryBox(section, "Share / import text", "", "Paste a shared FarmHub config here")
        textBox.Size = UDim2.new(1, 0, 0, 90)
        textBox.MultiLine = true
        textBox.TextWrapped = true
        textBox.TextYAlignment = Enum.TextYAlignment.Top
        local status = addLabel(section, "Named configs are saved locally for this Roblox account.", COLORS.dim)
        local function run(action)
            local ok, result = pcall(action)
            status.Text = ok and result or ("Config: " .. tostring(result))
            status.TextColor3 = ok and COLORS.accent or COLORS.dim
        end
        local function selectSaved(name)
            savedDropdown.setOptions(configStore.names())
            savedDropdown.set(name, true)
            nameBox.Text = name
        end
        addButton(section, "Save Config", function()
            run(function()
                local name = configStore.name(nameBox.Text)
                configStore.save(name, configStore.document(name, false))
                selectSaved(name)
                return "Saved " .. name
            end)
        end)
        addButton(section, "Load Config", function()
            run(function()
                local name = settings["Configs.Selected"]
                local document = assert(configStore.profiles[name], "Select a saved config first")
                local values = configStore.validate(document)
                local merged = configStore.copy(settings)
                for key, value in pairs(values) do merged[key] = value end
                merged["Configs.Selected"] = name
                task.defer(function()
                    cleanup(true)
                    launchFarmHub(merged)
                end)
                return "Loading " .. name
            end)
        end)
        addButton(section, "Share Config", function()
            run(function()
                local name = nameBox.Text:match("^%s*(.-)%s*$")
                if name == "" then name = "Shared config" end
                name = configStore.name(name)
                local raw = HttpService:JSONEncode(configStore.document(name, true))
                textBox.Text = raw
                local copied = type(setclipboard) == "function" and pcall(setclipboard, raw)
                return copied and "Current config copied. Webhook settings excluded."
                    or "Current config is in the text box; copy it to share. Webhook settings excluded."
            end)
        end)
        addButton(section, "Import Config", function()
            run(function()
                local name = configStore.import(textBox.Text, nameBox.Text:match("^%s*(.-)%s*$"))
                selectSaved(name)
                return "Imported " .. name .. ". Click Load Config to apply it."
            end)
        end)
        addLabel(section, "Share exports your current settings. Import saves a named config; Load applies it.", COLORS.dim)
    end
    settings["Favorites.List"] = nil
end
buildTabs()
farmCatalog.refresh()

-- Features ---------------------------------------------------------------------------

-- The feature loops live in their own function because Luau allows at most 200 local
-- variables per function, and the hub's main body is close to that.
local function startFeatures()

every("Side quest catalog", 5, SIDE_QUESTS.refresh)
every("Farming catalog", 5, farmCatalog.refresh)
connect(RunService.RenderStepped, hubMain.frame)
connect(UserInputService.WindowFocusReleased, function() hubMain.setFocused(false) end)
connect(UserInputService.WindowFocused, function() hubMain.setFocused(true) end)
hubMain.checkFocus()
every("Window focus", 1, hubMain.checkFocus)
every("Main dashboard", 1, hubMain.render)
hubMain.checkUpdate()

-- Mob farm: stay next to the chosen mob in the chosen world.
local lastFighterSend = 0
-- Side quests use the live quest missions and enemy catalog, including future worlds.
function SIDE_QUESTS.enemyWorld(mission)
    for _, field in ipairs({"MapName", "World", "Map"}) do
        if type(mission[field]) == "string" and WORLD_MAPS[mission[field]] then return mission[field] end
    end
    for world, enemies in pairs(Omni.Shared.Enemies.List or {}) do
        if WORLD_MAPS[world] and type(enemies) == "table" then
            for id, enemy in pairs(enemies) do
                if type(enemy) == "table" and (id == mission.Name or enemy.Name == mission.Name) then return world end
            end
        end
    end
end
SIDE_QUESTS.retry = {}
every("Side quest objectives", 0.5, function()
    SIDE_QUESTS.active = false
    local questSystem, data = Omni.Shared.Quests, Omni.Data
    local side = data.Quests and data.Quests.List and data.Quests.List.Side
    if not side then return end
    local chosen, info, saved
    local selected, completed = 0, 0
    for _, entry in ipairs(SIDE_QUESTS.ordered or {}) do
        if S(entry.key) then
            selected += 1
            local definition = questSystem.List.Side.List[entry.name]
            local progress = side.List and side.List[entry.name]
            if definition then
                local maximum = tonumber(definition.MaximumCompletions)
                local finished = progress and progress.Claimed == true
                    and (not maximum or (progress.Completions or 1) >= maximum)
                if finished then completed += 1
                elseif not chosen then chosen, info, saved = entry, definition, progress end
            end
        end
    end
    if not chosen then
        SIDE_QUESTS.target = nil
        setStatus("SideQuests", selected == 0 and "Select a side quest" or "All selected side quests completed")
        return
    end
    local name = chosen.name
    local canAccept, reason = questSystem.CanCollectQuest(name, "Side", data)
    if canAccept then
        if os.clock() >= (SIDE_QUESTS.retry[name] or 0) then
            SIDE_QUESTS.retry[name] = os.clock() + 3
            fire("Quests", "Collect", "Side", name)
        end
        setStatus("SideQuests", "Accepting " .. name)
        return
    end
    if not saved or saved.Available ~= true or saved.Claimed == true then
        setStatus("SideQuests", name .. ": " .. tostring(reason or "Waiting for quest unlock"))
        return
    end
    local fraction, missions = questSystem.GetQuestProgress(name, "Side", data)
    if (tonumber(fraction) or 0) >= 1 then
        if os.clock() >= (SIDE_QUESTS.retry[name .. "/claim"] or 0) then
            SIDE_QUESTS.retry[name .. "/claim"] = os.clock() + 3
            fire("Quests", "Claim", "Side", name)
            logAction("Side quest: claim " .. name)
        end
        setStatus("SideQuests", "Claiming " .. name)
        return
    end
    if positionTaken() then
        setStatus("SideQuests", name .. ": paused for boss or gamemode")
        return
    end
    local mission
    for index, objective in ipairs(info.Missions or {}) do
        if (tonumber(missions and missions[index]) or 0) < 1 then mission = objective; break end
    end
    if not mission or mission.Type ~= "Kill" or type(mission.Name) ~= "string" then
        setStatus("SideQuests", name .. ": remaining objective needs manual completion")
        return
    end
    local world = SIDE_QUESTS.enemyWorld(mission)
    if not world then
        setStatus("SideQuests", name .. ": waiting for enemy world data")
        return
    end
    if not Omni.Utils.PlayerStats.OwnsMap(world, data) then
        setStatus("SideQuests", name .. ": unlock " .. world .. " first")
        return
    end
    SIDE_QUESTS.active = true
    if not ensureMap(world) then
        setStatus("SideQuests", "Travelling to " .. world .. " for " .. mission.Name)
        return
    end
    local root = getRoot()
    if not root then setStatus("SideQuests", "Waiting for character"); return end
    local target = SIDE_QUESTS.target
    if not target or not target.Parent or target:GetAttribute("Died")
        or target:GetAttribute("EnemyName") ~= mission.Name or hubMain.health(target) <= 0 then
        target = hubMain.pick(findEnemies(serverFolder("Enemies", "Maps", world), mission.Name),
            root.Position, {mission.Name}, "Bosses First", true)
        SIDE_QUESTS.target = target
    end
    if not target then
        setStatus("SideQuests", name .. ": waiting for " .. mission.Name .. " to spawn")
        return
    end
    local position = enemyPosition(target)
    if (position - root.Position).Magnitude > 8 then
        teleportTo(CFrame.new(position + Vector3.new(0, 3, 4)))
    end
    setStatus("SideQuests", name .. ": fighting " .. mission.Name .. " (" .. math.floor((fraction or 0) * 100) .. "%)")
    if target:GetAttribute("Shielded") then return end
    Omni.Scripts.General.Combat.Attack()
    if os.clock() - (SIDE_QUESTS.lastFighters or 0) >= 1 and not SIDE_QUESTS.fighterBusy then
        local available = {}
        for id, enemyId in pairs(Omni.Utils.PlayerStats.GetFighterTargets(data, Omni.Instance)) do
            if enemyId == "" then available[#available + 1] = id end
        end
        if #available > 0 then
            SIDE_QUESTS.lastFighters, SIDE_QUESTS.fighterBusy = os.clock(), true
            featureThreads[#featureThreads + 1] = task.spawn(function()
                if alive and S(chosen.key) and target.Parent and not target:GetAttribute("Died") then
                    pcall(invoke, "Combat", "FighterAttack", target:GetAttribute("EnemyID"), available)
                end
                SIDE_QUESTS.fighterBusy = false
            end)
        end
    end
end)

every("Mob Farm", 0.5, function()
    if not S("MobFarm.AutoFarm") then
        setStatus("MobFarm", "Disabled")
        return
    end
    if SIDE_QUESTS.active then
        setStatus("MobFarm", "Paused: Side Quest")
        return
    end
    if hubMain.dragonFarming or (hubMain.dragonTrip or 0) > os.clock() then
        setStatus("MobFarm", "Paused: Dragon City task")
        return
    end
    if not WORLD_MAPS[S("MobFarm.World")] or #S("MobFarm.Mobs") == 0 then
        setStatus("MobFarm", "Select a world and at least one mob")
        return
    end
    if positionTaken() then
        setStatus("MobFarm", "Paused: boss or gamemode has priority")
        return
    end

    local world = S("MobFarm.World")
    if not ensureMap(world) then
        setStatus("MobFarm", "Travelling to " .. world)
        return
    end
    local root = getRoot()
    if not root then return end

    local selected = {}
    for _, name in ipairs(S("MobFarm.Mobs")) do selected[name] = true end
    if hubMain.targetWorld ~= world then
        hubMain.target, hubMain.targetWorld, hubMain.rotation = nil, world, 0
    end
    local target = hubMain.pick(findEnemies(serverFolder("Enemies", "Maps", world), selected), root.Position,
        S("MobFarm.Mobs"), S("MobFarm.TargetMode"), S("MobFarm.FinishTarget"))
    hubMain.target = target
    if not target then
        setStatus("MobFarm", "Waiting for selected mobs to spawn")
        return
    end
    local position = enemyPosition(target)
    local distance = (position - root.Position).Magnitude

    local offset = tonumber(S("MobFarm.Offset")) or 3
    if distance > offset + 5 then
        teleportTo(CFrame.new(position + Vector3.new(0, 3, offset)))
    end
    if S("MobFarm.SendToClosest") and os.clock() - lastFighterSend > 1 then
        lastFighterSend = os.clock()
        task.spawn(pcall, invoke, "Combat", "FighterAttack", target:GetAttribute("EnemyID"), equippedFighterIds())
    end
    setStatus("MobFarm", "Farming " .. tostring(target:GetAttribute("EnemyName"))
        .. " (" .. #S("MobFarm.Mobs") .. " selected)")
end)

-- Dragon City: run a request at one of its interaction points.
-- The request is tried from anywhere first; the trip only happens when the game refuses it.
-- Returns the request's result, and whether it was already tried standing at the point.
function hubMain.atDragonPrompt(promptName, request)
    if SIDE_QUESTS.active then return nil, false end
    local ok, result = pcall(request)
    if ok and result then return result, false end
    if positionTaken() then return nil, false end
    hubMain.dragonTrip = os.clock() + 20
    if not ensureMap("Dragon City") then return nil, false end
    local part = serverFolder("ProximityPrompts", "Dragon City", promptName)
    if not part then return nil, false end
    teleportTo(part.CFrame + Vector3.new(0, 3, 0))
    task.wait(1)
    ok, result = pcall(request)
    return ok and result or nil, true
end

-- Incubator: keep every slot training the next queued fighter until it reaches the target level.
every("Incubator", 5, function()
    if hubMain.incubatorQueue then
        farmCatalog.updateOptions(hubMain.incubatorQueue, "Dragon.IncubatorQueue", hubMain.incubatorOptions())
        -- Swap saved entries for their current labels so the shown level stays up to date.
        local queue, current, changed = S("Dragon.IncubatorQueue") or {}, {}, false
        for i, label in ipairs(queue) do
            local fresh = hubMain.incubatorLabels[hubMain.labelTag(label)] or label
            current[i] = fresh
            if fresh ~= label then changed = true end
        end
        if changed then hubMain.incubatorQueue.set(current, true) end
    end
    if not S("Dragon.AutoIncubator") then
        setStatus("Incubator", "Disabled")
        return
    end
    local incubator, fighters, data = Omni.Shared.Incubator, Omni.Shared.Fighters, Omni.Data
    local now = workspace:GetServerTimeNow()
    local function targetFor(fighter)
        local maxLevel = fighters.GetFighterMaxLevel(fighter, data)
        local target = tonumber(S("Dragon.IncubatorTarget")) or 0
        if target <= 0 or target > maxLevel then target = maxLevel end
        return target
    end

    local lines, free, busy = {}, {}, {}
    local slots = incubator.GetSlots(data)
    for index = 1, #slots do
        local id, fighter = incubator.GetSlotFighter(data, index)
        if fighter then
            busy[id] = true
            local level, exp = incubator.EstimateExp(data, index, now)
            local target = targetFor(fighter)
            if level >= target then
                local removed = hubMain.atDragonPrompt("Incubator Interface", function()
                    invoke("Incubator", "TakeOut", index)
                    task.wait(0.5)
                    return incubator.GetSlotFighter(Omni.Data, index) == nil
                end)
                if removed then
                    logAction("Incubator: took " .. fighter.Name .. " out of slot " .. index .. " at level " .. level)
                    busy[id] = nil
                    free[#free + 1] = index
                else
                    lines[#lines + 1] = string.format("Slot %d: taking out %s (Lv %d)", index, fighter.Name, level)
                end
            else
                local needed, rate = -(exp or 0), incubator.GetEffectiveRate(data, index)
                for nextLevel = level + 1, target do
                    needed = needed + (fighters.GetNeededExpForLevel(nextLevel, fighter, data) or 0)
                end
                lines[#lines + 1] = string.format("Slot %d (Lv %d): %s Lv %d/%d%s", index, slots[index].Level,
                    fighter.Name, level, target, rate > 0 and (", " .. formatTime(needed / rate) .. " left") or "")
            end
        else
            free[#free + 1] = index
        end
    end

    local function usable(id)
        local fighter = id and data.Fighters.List[id]
        return fighter and not busy[id] and (hubMain.incubatorSkip[id] or 0) < os.clock()
            and incubator.CanPlace(data, id) and (fighter.Level or 1) < targetFor(fighter)
    end
    local function nextFighter()
        for _, label in ipairs(S("Dragon.IncubatorQueue") or {}) do
            local id = hubMain.incubatorIds[hubMain.labelTag(label)]
            if usable(id) then return id end
        end
        if not S("Dragon.IncubatorFill") then return nil end
        local best, bestScore = nil, -1
        for id, fighter in pairs(data.Fighters.List) do
            local info = fighters.List[fighter.Name]
            if info and usable(id) then
                local score = (hubMain.RARITY_RANK[info.Rarity] or 0) * 1000
                    + (fighter.Shiny and 100 or 0) + (fighter.Level or 1)
                if score > bestScore then best, bestScore = id, score end
            end
        end
        return best
    end
    for _, index in ipairs(free) do
        local id = nextFighter()
        if not id then
            lines[#lines + 1] = string.format("Slot %d: empty (queue done)", index)
        else
            local fighter = data.Fighters.List[id]
            local placed, triedThere = hubMain.atDragonPrompt("Incubator Interface", function()
                return invoke("Incubator", "Place", index, id) == true
            end)
            if placed then
                busy[id] = true
                logAction("Incubator: placed " .. fighter.Name .. " (Lv " .. tostring(fighter.Level or 1)
                    .. ") in slot " .. index)
                lines[#lines + 1] = string.format("Slot %d: placed %s", index, fighter.Name)
            else
                if triedThere then hubMain.incubatorSkip[id] = os.clock() + 120 end
                lines[#lines + 1] = string.format("Slot %d: placing %s...", index, fighter.Name)
            end
        end
    end

    if S("Dragon.IncubatorUpgrade") then
        for index = 1, #slots do
            local level = slots[index].Level
            local price = incubator.GetUpgradePrice(level)
            if price and (data.Yen or 0) >= price.Amount then
                local upgraded = hubMain.atDragonPrompt("Incubator Interface", function()
                    return invoke("Incubator", "Upgrade", index) == true
                end)
                if upgraded then
                    logAction("Incubator: upgraded slot " .. index .. " to level " .. (level + 1))
                end
                break
            end
        end
    end
    setStatus("Incubator", #lines > 0 and table.concat(lines, "\n") or "No incubator slots yet")
end)

-- Dragon Balls: hunt the Dragon City enemies whose ball is still missing.
every("Dragon Balls", 0.5, function()
    if SIDE_QUESTS.active then
        hubMain.dragonFarming = false
        setStatus("DragonBalls", "Paused: Side Quest")
        return
    end
    if not S("Dragon.AutoBalls") then
        hubMain.dragonFarming = false
        setStatus("DragonBalls", "Disabled")
        return
    end
    local wish, data = Omni.Shared.DragonWish, Omni.Data
    local wanted, names, missing = {}, {}, 0
    for index, ball in ipairs(wish.Balls) do
        if not wish.IsBallOwned(data, index) then
            missing = missing + 1
            if ball.Difficulty ~= "Gamemode" and not wanted[ball.Enemy] then
                wanted[ball.Enemy] = true
                names[#names + 1] = ball.Enemy
            end
        end
    end
    local owned = #wish.Balls - missing
    if #names == 0 then
        hubMain.dragonFarming = false
        setStatus("DragonBalls", missing == 0 and "All Dragon Balls collected"
            or "Only Ball 7 is missing: it drops from Dragon Defense")
        return
    end
    if positionTaken() then
        hubMain.dragonFarming = false
        setStatus("DragonBalls", "Paused: boss or gamemode has priority")
        return
    end
    hubMain.dragonFarming = true
    if not ensureMap("Dragon City") then
        setStatus("DragonBalls", "Travelling to Dragon City")
        return 2
    end
    local root = getRoot()
    if not root then return end
    local target = hubMain.pick(findEnemies(serverFolder("Enemies", "Maps", "Dragon City"), wanted),
        root.Position, names, "Bosses First", true)
    hubMain.target, hubMain.targetWorld = target, "Dragon City"
    if not target then
        setStatus("DragonBalls", string.format("Waiting for %s (%d/%d balls)",
            table.concat(names, ", "), owned, #wish.Balls))
        return
    end
    local position = enemyPosition(target)
    if (position - root.Position).Magnitude > 8 then
        teleportTo(CFrame.new(position + Vector3.new(0, 3, 3)))
    end
    if os.clock() - (hubMain.dragonSend or 0) > 1 then
        hubMain.dragonSend = os.clock()
        task.spawn(pcall, invoke, "Combat", "FighterAttack", target:GetAttribute("EnemyID"), equippedFighterIds())
    end
    setStatus("DragonBalls", string.format("Hunting %s (%d/%d balls)",
        tostring(target:GetAttribute("EnemyName")), owned, #wish.Balls))
end)

-- Shenron: summon once all balls are in and take the highest-ranked wish on offer.
every("Dragon Wish", 10, function()
    if not S("Dragon.AutoSummon") then
        setStatus("DragonWish", "")
        return
    end
    local wish = Omni.Shared.DragonWish
    if not wish.HasAllBalls(Omni.Data) then
        if not (hubMain.lastWish and statusLabels.DragonWish.Text == hubMain.lastWish) then
            setStatus("DragonWish", string.format("Summon waits for all balls (%d/%d)",
                wish.GetOwnedCount(Omni.Data), #wish.Balls))
        end
        return
    end
    local options = hubMain.atDragonPrompt("DragonWish Interface", function()
        local result = invoke("DragonWish", "Summon")
        return type(result) == "table" and type(result.Options) == "table" and #result.Options > 0
            and result.Options or nil
    end)
    if not options then
        setStatus("DragonWish", "Summoning Shenron at the altar...")
        return
    end
    local order = S("Dragon.WishOrder") or {}
    local bestIndex, bestRank = 1, math.huge
    for index, option in ipairs(options) do
        local rank = table.find(order, option.Name) or math.huge
        if rank < bestRank then bestIndex, bestRank = index, rank end
    end
    local choice = options[bestIndex]
    local text = tostring(choice.Name) .. ((choice.Amount or 1) > 1 and (" x" .. tostring(choice.Amount)) or "")
    local ok, result = pcall(invoke, "DragonWish", "Choose", bestIndex)
    if ok and type(result) == "table" and result.Success == true then
        logAction("Dragon Wish: chose " .. text)
        notify("Shenron granted " .. text)
        hubMain.lastWish = "Last wish: " .. text
        setStatus("DragonWish", hubMain.lastWish)
    else
        local message = ok and type(result) == "table" and result.Message or result
        setStatus("DragonWish", "Wish failed: " .. tostring(message))
    end
end)

-- Gamemodes: join by schedule and priority, fight, and leave at the chosen wave.
local GAMEMODES = {
    Trial = { toggle = "Trial.AutoTrial", scheduled = true },
    Dungeon = { toggle = "Dungeon.AutoDungeon", scheduled = true },
    Culling = { toggle = "Culling.Enabled", scheduled = false },
    DragonDefense = { toggle = "DragonDefense.Enabled", scheduled = false }
}

GAMEMODES["Dragon Defense"] = GAMEMODES.DragonDefense

local function gamemodeName(activity)
    if activity == "DragonDefense" then return "Dragon Defense" end
    if activity == "Culling" then
        return S("Culling.Gamemode")
    end
    return activity .. " " .. tostring(S(activity .. ".Difficulty"))
end

local function gamemodeInfo(name)
    local list = Omni.Shared.Gamemodes.List
    return list and list[name]
end

-- OpenTimes are minutes past the hour; entry stays open for EnterTime seconds.
local function schedule(info)
    if type(info.OpenTimes) ~= "table" then return false, nil end
    local enterTime = info.EnterTime or 60
    local now = workspace:GetServerTimeNow() % 3600
    local nextOpen = math.huge
    for _, minute in pairs(info.OpenTimes) do
        local since = (now - minute * 60) % 3600
        if since < enterTime then
            return true, enterTime - since
        end
        nextOpen = math.min(nextOpen, 3600 - since)
    end
    return false, nextOpen
end

local function isOpen(activity)
    local info = gamemodeInfo(gamemodeName(activity))
    return info ~= nil and schedule(info) == true
end

-- The HUD keeps its old text between runs, so it is only trusted while it is showing.
local function readWave()
    local current, total
    pcall(function()
        local hud = Omni.Interface.HUD.Gamemode
        if not hud.Visible then return end
        local text = hud.Information.Wave.Value.Text
        local a, b = string.match(text, "^(%d+)/(%d*)")
        current, total = tonumber(a), tonumber(b)
    end)
    return current, total
end

local function leaveGamemode(reason)
    notify("Leaving gamemode: " .. reason)
    logAction("Leave " .. tostring(currentGamemode()) .. ": " .. reason)
    fire("Gamemodes", "Leave")
end

local lastJoinAttempt = 0
local gamemodeSeen = nil
local gamemodeSince = 0
local cullingLobby = false -- true while you are sitting in a Culling lobby
every("Gamemodes", 1, function()
    for _, activity in ipairs({ "Trial", "Dungeon" }) do
        local name = gamemodeName(activity)
        local info = gamemodeInfo(name)
        if not info then
            setStatus(activity, name .. " is not in the game")
        else
            local open, seconds = schedule(info)
            setStatus(activity, string.format(open and "Open | closes: %ds" or "Closed | next: %ds",
                seconds or 0))
        end
    end
    local order = S("Priority.Order")
    local current = currentGamemode()
    if current ~= gamemodeSeen then
        gamemodeSeen = current
        gamemodeSince = os.clock()
        logAction(current and ("Entered " .. current) or "Left gamemode")
    end
    if current then
        local activity = activityOf(current)
        if not activity or not activityManaged(activity) then return nil end
        if activity == "Culling" or activity == "DragonDefense" then return nil end -- The ported coordinator owns leaving and priority pauses.

        -- Wave checks wait until the run has been going long enough for the HUD to refresh.
        local wave, total = readWave()
        if S(activity .. ".AutoLeave") and wave and os.clock() - gamemodeSince > 10 then
            if wave >= (tonumber(S(activity .. ".Wave")) or math.huge) then
                leaveGamemode("wave " .. wave .. " reached")
                return 5
            end
        end

        if S("Priority.LeaveForPriority") then
            for _, other in ipairs(order) do
                if other == activity then break end
                local config = GAMEMODES[other]
                if config and config.scheduled and S(config.toggle) and isOpen(other) then
                    leaveGamemode(other .. " is open")
                    return 3
                end
            end
        end

        return nil
    end

    if os.clock() - lastJoinAttempt < 5 then return nil end
    for _, activity in ipairs(order) do
        local config = GAMEMODES[activity]
        -- While World Boss has you, only activities ranked above it may take over.
        local blocked = busyBoss == worldBoss and priorityRank(activity) > priorityRank("World Boss")
        if config and S(config.toggle) and not blocked then
            if config.scheduled and isOpen(activity) then
                lastJoinAttempt = os.clock()
                logAction("Join " .. gamemodeName(activity) .. ": entry is open")
                if cullingLobby then
                    fire("Parties", "Leave")
                    task.wait(0.5)
                end
                task.spawn(pcall, invoke, "Gamemodes", "Join", gamemodeName(activity))
                return 3
            end
        end
    end
    return nil
end)

-- In-run positioning: keep you on an enemy of your own run. A shielded boss cannot be hurt,
-- so while one is shielded the minions are targeted first.
-- Dungeon doors now require an explicit prompt interaction with two indices.
local dungeonDoors = {session = nil, retryAt = setmetatable({}, {__mode = "k"}), emptySince = nil,
    message = "Waiting for room data"}
function dungeonDoors.owned(prompt, current, session, map)
    local node, knownMap, knownSession = prompt, false, false
    if map and prompt:IsDescendantOf(map) then knownMap = true end
    while node and node ~= workspace do
        local tag = node:GetAttribute("SessionID") or node:GetAttribute("GamemodeSession")
        if tag ~= nil then
            if tag ~= session then return false end
            knownSession = true
        end
        local owner = node:GetAttribute("OwnerID")
        if owner ~= nil and owner ~= player.UserId and not knownSession then return false end
        if node.Name == session then knownSession = true end
        if node.Name == current then knownMap = true end
        node = node.Parent
    end
    return knownSession or knownMap
end
function dungeonDoors.candidates(current, session, root)
    local client = workspace:FindFirstChild("Client")
    local maps = client and client:FindFirstChild("Maps")
    local map = maps and maps:FindFirstChild(current)
    local rooms, cleared
    if map then
        pcall(function()
            local state = Omni.Utils.StateManager.Get(map)
            if state then
                rooms = state:GetState("Rooms")
                cleared = state:GetState("ClearedRooms")
            end
        end)
    end
    local candidates, seen = {}, {}
    local function collect(folder)
        if not folder then return end
        for _, prompt in ipairs(folder:GetDescendants()) do
            if prompt:IsA("ProximityPrompt") and prompt.Enabled and not seen[prompt] then
                seen[prompt] = true
                local part = prompt.Parent
                local callback = prompt:GetAttribute("Callback") or prompt.Name
                local parentCallback = part and (part:GetAttribute("Callback") or part.Name)
                local room, child = prompt:GetAttribute("RoomIndex"), prompt:GetAttribute("ChildIndex")
                if part and part:IsA("BasePart") and (callback == "Open Dungeon Door" or parentCallback == "Open Dungeon Door")
                    and type(room) == "number" and type(child) == "number"
                    and dungeonDoors.owned(prompt, current, session, map) then
                    local roomInfo = type(rooms) == "table" and (rooms[tostring(room)] or rooms[room])
                    local ready = type(cleared) ~= "table" or cleared[tostring(room)] == true or cleared[room] == true
                        or (type(roomInfo) == "table" and roomInfo.Type == "Start")
                    if ready and (type(rooms) ~= "table" or roomInfo) then
                        candidates[#candidates + 1] = {prompt = prompt, part = part, room = room, child = child,
                            distance = (root.Position - part.Position).Magnitude}
                    end
                end
            end
        end
    end
    collect(map)
    collect(serverFolder("ProximityPrompts"))
    table.sort(candidates, function(a, b) return a.distance < b.distance end)
    return candidates
end
function dungeonDoors.step(current, session, root, humanoid)
    if not S("Dungeon.AutoDungeon") or activityOf(current) ~= "Dungeon" or currentGamemode() ~= current then return end
    if type(session) ~= "string" or session == "" or Omni.Data.GamemodeSession ~= session then
        dungeonDoors.message = "Waiting for dungeon session"; return
    end
    if dungeonDoors.session ~= session then
        dungeonDoors.session = session
        dungeonDoors.retryAt = setmetatable({}, {__mode = "k"})
        dungeonDoors.emptySince = nil
    end
    local now = os.clock()
    dungeonDoors.emptySince = dungeonDoors.emptySince or now
    if now - dungeonDoors.emptySince < 0.6 then dungeonDoors.message = "Waiting for room spawns"; return end
    local wave = readWave()
    if S("Dungeon.AutoLeave") and wave and wave >= (tonumber(S("Dungeon.Wave")) or math.huge) then
        dungeonDoors.message = "Waiting to leave at selected wave"; return
    end
    local doors = dungeonDoors.candidates(current, session, root)
    local door
    for _, candidate in ipairs(doors) do
        if now >= (dungeonDoors.retryAt[candidate.prompt] or 0) then door = candidate; break end
    end
    if not door then dungeonDoors.message = #doors > 0 and "Waiting for door confirmation" or "Waiting for an available door"; return end
    if door.distance > math.max(1, door.prompt.MaxActivationDistance - 1) then
        dungeonDoors.message = "Moving to dungeon door"
        if S("Dungeon.WalkToEnemy") and humanoid then
            humanoid:MoveTo(door.part.Position)
        else
            teleportTo(CFrame.new(door.part.Position + Vector3.new(0, 1, 0)))
        end
        return
    end
    if not alive or currentGamemode() ~= current or Omni.Data.GamemodeSession ~= session or not door.prompt.Enabled then return end
    dungeonDoors.retryAt[door.prompt] = now + 2
    dungeonDoors.message = "Opening dungeon door"
    local ok, opened = pcall(invoke, "Gamemodes", "OpenDoor", door.room, door.child)
    if not ok then
        dungeonDoors.message = "Door request failed; retrying"
        logAction("Dungeon door failed: " .. tostring(opened))
    elseif opened == true then
        dungeonDoors.message = "Door opened; waiting for enemies"
        dungeonDoors.emptySince = now
        logAction("Dungeon door opened: room " .. door.room .. ", door " .. door.child)
    else
        dungeonDoors.message = "Door not ready; retrying"
    end
end

local _combatNote = ""
every("Gamemode Combat", 0.4, function()
    local current = currentGamemode()
    local activity = current and activityOf(current)
    if not activity or activity == "Culling" or activity == "DragonDefense" then
        hubMain.combatTarget = nil
        dungeonDoors.emptySince = nil
        _combatNote = ""
        return 1
    end
    if not (activityManaged(activity)
        or (activity == "Culling" and S("Culling.TeleportToEnemies"))) then
        hubMain.combatTarget = nil
        return 1
    end
    local root, humanoid = getRoot()
    if not root then return nil end

    -- Other players' runs share the folder; SessionID picks out yours.
    local session = Omni.Data.GamemodeSession
    local hasSession = type(session) == "string" and session ~= ""
    local open, shielded = {}, {}
    for _, enemy in ipairs(findEnemies(serverFolder("Enemies", "Gamemodes"))) do
        if (not hasSession or enemy:GetAttribute("SessionID") == session) and hubMain.health(enemy) > 0 then
            if enemy:GetAttribute("Shielded") then
                shielded[#shielded + 1] = enemy
            else
                open[#open + 1] = enemy
            end
        end
    end

    if #shielded > 0 then
        _combatNote = #open > 0 and " | boss shielded: killing minions" or " | boss shielded: waiting for minions"
    else
        _combatNote = ""
    end

    local target, distance, position = nearestTo(#open > 0 and open or shielded, root.Position)
    hubMain.combatTarget = target
    if not target then
        if activity == "Dungeon" then
            dungeonDoors.step(current, session, root, humanoid)
            setStatus("Dungeon", "In " .. current .. " | " .. dungeonDoors.message)
        end
        return nil
    end
    dungeonDoors.emptySince = nil
    if activity == "Dungeon" then setStatus("Dungeon", "In " .. current .. " | Fighting " .. tostring(target:GetAttribute("EnemyName"))) end
    if distance <= 8 then return nil end
    if S(activity .. ".WalkToEnemy") and humanoid then
        humanoid:MoveTo(position)
    else
        teleportTo(CFrame.new(position + Vector3.new(0, 3, 4)))
    end
    return nil
end)

-- BEGIN_PORTED_CULLING
do
local function runAutomation(api, settings)
    local MODE = "Culling Game"
    local cycles = 0

    local function countMembers(party)
        local seen, count, includesYou = {}, 0, false
        for _, id in ipairs(party.MemberOrder or {}) do
            local key = tostring(id)
            if not seen[key] then
                seen[key] = true
                count = count + 1
            end
            if key == tostring(api.userId) then includesYou = true end
        end
        return count, includesYou
    end

    local function ownLobby(party)
        if type(party) ~= "table" or party.GamemodeName ~= MODE then return false end
        local _, includesYou = countMembers(party)
        return includesYou and tostring(party.Leader) == tostring(api.userId)
    end

    local function session()
        local data = api.data()
        if data.Gamemode == MODE and data.GamemodeSession ~= nil
            and data.GamemodeSession ~= false and data.GamemodeSession ~= "" then
            return tostring(data.GamemodeSession)
        end
        return nil
    end

    local function report(message, members, wave)
        api.report(message, {members = members, wave = wave, cycles = cycles})
    end

    local function send(section, action, ...)
        if not api.alive() then return false end
        api.fire(section, action, ...)
        return true
    end

    local function waitFor(predicate, seconds, failure)
        local deadline = api.now() + seconds
        while api.alive() do
            local value = predicate()
            if value then return value end
            if api.now() >= deadline then error(failure, 0) end
            if not api.sleep(0.2) then return nil end
        end
        return nil
    end

    local function matchesHost(party)
        if type(party) ~= "table" or party.ID == nil then return false end
        if party.GamemodeName and party.GamemodeName ~= MODE then return false end
        if tostring(party.Leader) == tostring(api.userId) then return false end
        return settings.hostUserId == nil or tostring(party.Leader) == tostring(settings.hostUserId)
    end

    local function waitForHost(partyId)
        local missingSince = nil
        while api.alive() do
            local activeSession = session()
            if activeSession then return activeSession end
            local party = api.party()
            if party then
                local members, includesYou = countMembers(party)
                if not includesYou or party.ID ~= partyId or not matchesHost(party) then
                    error("Your party/host changed. Stop, leave that party, and try again.", 0)
                end
                missingSince = nil
                report("Joined " .. (party.Difficulty or MODE) .. " lobby. Waiting for the host to start...", members, 0)
            else
                missingSince = missingSince or api.now()
                -- Party removal can arrive before the match data when the host starts.
                if api.now() - missingSince >= 5 then return nil end
                report("Lobby changed. Waiting for the match or the host's next lobby...", 0, 0)
            end
            if not api.sleep(0.2) then return nil end
        end
        return nil
    end

    local function joinPlayerLobby()
        local attemptedAt = {}
        while api.alive() do
            local activeSession = session()
            if activeSession then return activeSession end
            local party = api.party()
            if party then
                local _, includesYou = countMembers(party)
                if not includesYou or not matchesHost(party) then
                    error("Leave your current party first, or choose its host in Player mode.", 0)
                end
                activeSession = waitForHost(party.ID)
                if activeSession then return activeSession end
            else
                report(settings.hostUserId and "Looking for the selected host's public lobby..."
                    or "Looking for an open Culling Game lobby...", 0, 0)
                local lobbies = api.browse()
                if not api.alive() then return nil end
                -- A lobby or session may have arrived while Browse was in flight.
                activeSession = session()
                if activeSession then return activeSession end
                if not api.party() then
                    local candidates = {}
                    for _, lobby in pairs(lobbies) do
                        local members = type(lobby) == "table" and countMembers(lobby) or 0
                        local capacity = type(lobby) == "table" and (tonumber(lobby.MaxMembers) or api.maxMembers) or 0
                        if matchesHost(lobby) and members < capacity
                            and (lobby.Visibility == nil or lobby.Visibility == "Public")
                            and api.now() - (attemptedAt[tostring(lobby.ID)] or -math.huge) >= 5 then
                            table.insert(candidates, lobby)
                        end
                    end
                    table.sort(candidates, function(left, right) return tostring(left.ID) < tostring(right.ID) end)
                    local target = candidates[1]
                    if target then
                        api.checkEntry("Player")
                        report("Joining the host's Culling Game lobby...", countMembers(target), 0)
                        attemptedAt[tostring(target.ID)] = api.now()
                        if not send("Parties", "Join", target.ID) then return nil end
                        local deadline = api.now() + 10
                        while api.alive() and api.now() < deadline do
                            activeSession = session()
                            if activeSession then return activeSession end
                            local joined = api.party()
                            if joined then
                                local _, includesYou = countMembers(joined)
                                if not includesYou or joined.ID ~= target.ID or not matchesHost(joined) then
                                    error("You joined a different party. Check the selected host.", 0)
                                end
                                activeSession = waitForHost(joined.ID)
                                if activeSession then return activeSession end
                                break
                            end
                            if not api.sleep(0.2) then return nil end
                        end
                    end
                end
            end
            if not api.sleep(2) then return nil end
        end
        return nil
    end

    while api.alive() do
        if api.refreshSettings then api.refreshSettings(settings) end
        local activeSession = session()
        if not activeSession then
            local mode = api.data().Gamemode
            if mode and mode ~= "" and mode ~= MODE then
                error("Leave your current gamemode, then press Start again.", 0)
            end
            if settings.role == "Player" then
                api.checkEntry("Player")
                activeSession = joinPlayerLobby()
                if not activeSession then return end
            else
                api.checkEntry("Host")
                local party = api.party()
                if party and not ownLobby(party) then
                    error("Leave your current party first. You must host the Culling Game lobby.", 0)
                end

                if not party then
                    report("Creating a public Culling Game lobby...", 0, 0)
                    if not send("Parties", "Create", MODE) then return end
                    party = waitFor(function()
                        local candidate = api.party()
                        if candidate and not ownLobby(candidate) then
                            error("You joined a different party. Stop and leave it before trying again.", 0)
                        end
                        return candidate
                    end, 20, "Lobby creation was not confirmed. Check the game's notification and entry requirements.")
                    if not party then return end
                end

                local partyId = party.ID
                if settings.requiredPlayers > (tonumber(party.MaxMembers) or api.maxMembers) then
                    error("Selected player count exceeds this lobby's capacity.", 0)
                end
                local function sameLobby()
                    local latest = api.party()
                    if not ownLobby(latest) or latest.ID ~= partyId then
                        error("The lobby was closed, you left, or you are no longer the host.", 0)
                    end
                    return latest
                end

                report("Applying " .. settings.difficulty .. " difficulty and public visibility...", countMembers(party), 0)
                if party.Difficulty ~= settings.difficulty then
                    if not send("Parties", "SetDifficulty", settings.difficulty) then return end
                end
                if party.Visibility ~= "Public" then
                    if not send("Parties", "SetVisibility", "Public") then return end
                end
                party = waitFor(function()
                    local latest = sameLobby()
                    return latest.Difficulty == settings.difficulty and latest.Visibility == "Public" and latest
                end, 12, "The server did not confirm the difficulty/public setting. Check the game's notification.")
                if not party then return end

                local soloSince, waitingTarget = nil, settings.requiredPlayers
                while api.alive() do
                    party = sameLobby()
                    local members = countMembers(party)
                    local required = settings.requiredPlayers
                    if required ~= waitingTarget then
                        soloSince, waitingTarget = nil, required
                    end
                    if members >= required then break end
                    local countdown = ""
                    if required >= 2 and members == 1 then
                        soloSince = soloSince or api.now()
                        local remaining = math.max(0, 60 - (api.now() - soloSince))
                        if remaining <= 0 then
                            if not api.alive() then return end
                            if api.setRequiredPlayers then api.setRequiredPlayers(1)
                            else settings.requiredPlayers = 1 end
                            report("No one joined for 1 minute. Player requirement set to 1; starting solo.", members, 0)
                            break
                        end
                        countdown = " | Solo start in " .. math.ceil(remaining) .. "s"
                    else
                        soloSince = nil
                    end
                    report("Waiting for players: " .. members .. " / " .. required .. " (including you)" .. countdown, members, 0)
                    if not api.sleep(0.2) then return end
                end
                if not api.alive() then return end

                party = sameLobby()
                if party.Difficulty ~= settings.difficulty or party.Visibility ~= "Public" then
                    error("Lobby settings changed. Stop, check them, and press Start again.", 0)
                end
                api.checkEntry("Host")
                report("Starting " .. settings.difficulty .. " Culling Game...", countMembers(party), 0)
                if not send("Parties", "Start") then return end
                activeSession = waitFor(session, 25,
                    "The match did not start. Check the game's notification; no duplicate Start was sent.")
                if not activeSession then return end
            end
        end

        local lastWaveRead = api.now()
        while api.alive() and session() == activeSession do
            local wave = api.wave(activeSession)
            if type(wave) == "number" then
                lastWaveRead = api.now()
                report(settings.role == "Player" and "In Culling Game - Player"
                    or "In Culling Game - " .. settings.difficulty, nil, wave)
                if settings.autoLeave and wave >= settings.leaveWave then
                    report("Reached wave " .. wave .. ". Leaving the match...", nil, wave)
                    if not send("Gamemodes", "Leave") then return end
                    local left = waitFor(function()
                        return session() ~= activeSession
                    end, 25, "Leaving was not confirmed. Automation stopped; check the game.")
                    if not left then return end
                    break
                end
            else
                report("Waiting for the match's wave counter...", nil, nil)
                if api.now() - lastWaveRead > 30 then
                    error("The wave counter is unavailable. Automation stopped.", 0)
                end
            end
            if api.step and api.alive() and session() == activeSession then api.step(activeSession) end
            if not api.sleep(0.2) then return end
        end
        if not api.alive() then return end
        cycles = cycles + 1
        report(settings.role == "Player" and "Match ended. Looking for the host again in 3 seconds..."
            or "Match ended. Creating the next lobby in 3 seconds...", 0, 0)
        if not api.sleep(3) then return end
    end
end

local function pickTarget(candidates, collectChests)
    local best, bestRank = nil, math.huge
    for _, enemy in ipairs(candidates) do
        if not enemy.dead and (collectChests or not enemy.chest) then
            local rank = (enemy.chest and 0 or 1) * 1000000 + enemy.distance
            if rank < bestRank then best, bestRank = enemy, rank end
        end
    end
    return best
end

local function pickCullingTarget(current, candidates)
    local minis, bosses = {}, {}
    for _, enemy in ipairs(candidates) do
        if not enemy.dead and enemy.alive ~= false and not enemy.shielded then
            table.insert(enemy.boss and bosses or minis, enemy)
        end
    end
    local pool = #minis > 0 and minis or bosses
    -- Use the fresh candidate so a newly applied shield is never cached away.
    for _, enemy in ipairs(pool) do
        if current and enemy.id == current.id and enemy.object == current.object then return enemy end
    end
    return pickTarget(pool, true)
end


    local state: {[string]: any} = {cycles = 0, token = 0, worker = nil, ownsRun = false, ownsLobby = false}
    env.FarmHubCulling = state
    local currentParty, received = nil, false
    local parties = Omni.Scripts.General.Parties
    local function includesYou(party)
        if type(party) ~= "table" or party.GamemodeName ~= "Culling Game" then return false end
        for _, id in ipairs(party.MemberOrder or {}) do if tostring(id) == tostring(player.UserId) then return true end end
        return false
    end
    connect(parties.SyncEvent, function(party)
        received = true
        if includesYou(party) then currentParty = party
        elseif currentParty and type(party) == "table" and party.ID == currentParty.ID then currentParty = nil end
    end)
    local function clearParty(id)
        received = true
        if currentParty and currentParty.ID == id then currentParty = nil end
    end
    for _, event in ipairs({parties.LeftEvent, parties.DisbandedEvent, parties.KickedEvent}) do
        if event then connect(event, clearParty) end
    end
    local controller
    pcall(function() controller = require(player.PlayerScripts.Omni.Scripts.Interface.Gamemodes.Controller) end)
    local function partySnapshot()
        if not received and controller and type(getupvalues) == "function" then
            for _, callback in ipairs({controller.OnSync, controller.OnLeft}) do
                if type(callback) == "function" then
                    for _, value in pairs(getupvalues(callback)) do
                        if includesYou(value) then currentParty = value end
                    end
                end
            end
        end
        hubMain.partyLobbies = hubMain.partyLobbies or {}
        hubMain.partyLobbies["Culling"] = includesYou(currentParty)
        cullingLobby = hubMain.partyLobbies.Culling == true or hubMain.partyLobbies.DragonDefense == true
        if includesYou(currentParty) then state.ownsLobby = true end
        return currentParty
    end
    local function higherPriority()
        if not S("Priority.LeaveForPriority") then return nil end
        for _, other in ipairs({"Dungeon", "Trial"}) do
            if S(GAMEMODES[other].toggle) and priorityRank(other) < priorityRank("Culling") and isOpen(other) then return other end
        end
        if S("DragonDefense.Enabled") and priorityRank("DragonDefense") < priorityRank("Culling") then return "DragonDefense" end
        if worldBoss.enabled and priorityRank("World Boss") < priorityRank("Culling")
            and (busyBoss == worldBoss or worldBoss.phase == "gamemode" or worldBoss.phase == "queued"
                or worldBoss.phase == "teleporting" or worldBoss.phase == "holding"
                or worldBoss.phase == "returning") then return "World Boss" end
        return nil
    end
    local function wave(sessionId)
        local client = workspace:FindFirstChild("Client")
        local maps = client and client:FindFirstChild("Maps")
        local map = maps and maps:FindFirstChild("Culling Game")
        local sessions = map and map:FindFirstChild("GamemodeSessions")
        local holder = sessions and sessions:FindFirstChild(sessionId)
        if not holder or not holder:FindFirstChild("StateManager") then return nil end
        local manager = Omni.Utils.StateManager.Get(holder)
        if not manager then return nil end
        local value = manager:GetState("CurrentWave")
        return tonumber(value)
    end
    local function combat(sessionId, active)
        if not active() or Omni.Data.GamemodeSession ~= sessionId or Omni.Data.Gamemode ~= "Culling Game" then return end
        if not S("Culling.TeleportToEnemies") then state.target = nil; return end
        local root, _, character = getRoot()
        if not root then return end
        if state.session ~= sessionId then state.session, state.target, state.positioned = sessionId, nil, nil end
        local candidates = {}
        for _, enemy in ipairs(game:GetService("CollectionService"):GetTagged("Enemy")) do
            if enemy.Parent and enemy:GetAttribute("Gamemode") == "Culling Game" and enemy:GetAttribute("SessionID") == sessionId
                and not enemy:GetAttribute("Died") then
                local data = enemy:FindFirstChild("Data")
                local health = data and data:FindFirstChild("Health")
                local hp = health and tonumber(health.Value)
                if not hp or hp > 0 then
                    local cf = Omni.Utils.Enemies.GetPosition(enemy:GetAttribute("EnemyID"))
                    if typeof(cf) == "CFrame" then
                        table.insert(candidates, {id = enemy:GetAttribute("EnemyID"), object = enemy, cf = cf, alive = true,
                            shielded = enemy:GetAttribute("Shielded") == true,
                            boss = enemy:GetAttribute("Difficulty") == "Boss" or enemy:GetAttribute("Difficulty") == "Secret"
                                or enemy:GetAttribute("Shielded") == true,
                            distance = (cf.Position - root.Position).Magnitude})
                    end
                end
            end
        end
        -- The original picker calls pickTarget only after retaining a living current target.
        state.target = pickCullingTarget(state.target, candidates)
        local target = state.target
        if not target then state.combat = "Waiting for minis / an unshielded enemy"; return end
        if state.positioned ~= target.object or state.character ~= character then
            local position = (target.cf * CFrame.new(0, 0, 4)).Position + Vector3.new(0, 5, 0)
            local facing = Vector3.new(target.cf.LookVector.X, 0, target.cf.LookVector.Z)
            if facing.Magnitude < 0.001 then facing = Vector3.new(0, 0, -1) end
            if teleportTo(CFrame.lookAt(position, position + facing.Unit)) then
                state.positioned, state.character = target.object, character
            end
        end
        if not active() or target.object:GetAttribute("Shielded") then return end
        state.combat = "Attacking " .. tostring(target.object:GetAttribute("EnemyName"))
        Omni.Scripts.General.Combat.Attack()
        if os.clock() - (state.lastFighters or 0) >= 1 and not state.fighterBusy then
            local available = {}
            for id, enemyId in pairs(Omni.Utils.PlayerStats.GetFighterTargets(Omni.Data, Omni.Instance)) do
                if enemyId == "" then table.insert(available, id) end
            end
            if #available > 0 then
                state.lastFighters, state.fighterBusy = os.clock(), true
                local thread = task.spawn(function()
                    if active() and target.object.Parent and not target.object:GetAttribute("Died")
                        and not target.object:GetAttribute("Shielded") then pcall(invoke, "Combat", "FighterAttack", target.id, available) end
                    state.fighterBusy = false
                end)
                featureThreads[#featureThreads + 1] = thread
            end
        end
    end
    local function run(token)
        local function active()
            return alive and state.token == token and S("Culling.Enabled") and not higherPriority()
                and (not currentGamemode() or currentGamemode() == "Culling Game")
        end
        local liveSettings: {[string]: any} = {}
        setmetatable(liveSettings, {__index = function(_, key)
            if key == "requiredPlayers" then return math.clamp(tonumber(S("Culling.StartPlayers")) or 2, 1, 4) end
            if key == "autoLeave" then return S("Culling.AutoLeave") end
            if key == "leaveWave" then return math.max(1, tonumber(S("Culling.Wave")) or 6) end
            return nil
        end})
        local function refresh()
            liveSettings.role, liveSettings.difficulty = S("Culling.Role"), S("Culling.Difficulty")
            liveSettings.hostUserId = nil
            local text = tostring(S("Culling.Host") or ""):match("^%s*(.-)%s*$"):gsub("^@", "")
            if liveSettings.role == "Player" and text ~= "" then
                local id = tonumber(text)
                if not id then
                    for _, candidate in ipairs(Players:GetPlayers()) do if candidate.Name:lower() == text:lower() then id = candidate.UserId; break end end
                    id = id or Players:GetUserIdFromNameAsync(text)
                end
                assert(id and id > 0 and id % 1 == 0 and id ~= player.UserId, "Player mode needs a valid friend's username/user ID.")
                liveSettings.hostUserId = id
            end
        end
        local function guardedSleep(seconds)
            local deadline = os.clock() + seconds
            while active() and os.clock() < deadline do task.wait(math.min(0.1, deadline - os.clock())) end
            return active()
        end
        local info = assert(gamemodeInfo("Culling Game"), "Culling Game unavailable")
        runAutomation({userId = player.UserId, maxMembers = info.MaxPartyMembers or 4, alive = active, now = os.clock,
            refreshSettings = refresh,
            setRequiredPlayers = function(count)
                setSetting("Culling.StartPlayers", count)
                if env.FarmHubCullingPlayerSlider then env.FarmHubCullingPlayerSlider.Refresh() end
            end,
            data = function() return Omni.Data end, party = partySnapshot,
            wave = wave, sleep = guardedSleep,
            step = function(sessionId) state.ownsRun = true; combat(sessionId, active) end,
            checkEntry = function(role)
                assert(Omni.Utils.PlayerStats.OwnsMap(info.MapName, Omni.Data), "Unlock " .. info.MapName .. " first.")
                if role == "Host" then
                    local price = Omni.Shared.Gamemodes.GetPrice(info)
                    if price then
                        local amount = Omni.Shared.Gamemodes.GetPriceAmount(Omni.Data, price)
                        assert(type(amount) ~= "number" or amount >= price.Amount, "Not enough " .. tostring(price.Name))
                    end
                end
            end,
            browse = function()
                local result = invoke("Parties", "Browse", "Culling Game")
                assert(type(result) == "table", "Could not read public lobbies")
                return result
            end,
            fire = function(section, action, ...)
                if active() then
                    if section == "Parties" and (action == "Create" or action == "Join") then state.ownsLobby = true end
                    if section == "Parties" and action == "Start" then state.ownsRun = true end
                    logAction("Culling " .. section .. "/" .. action)
                    fire(section, action, ...)
                end
            end,
            report = function(message, update)
                state.message = message
                state.members, state.wave = update.members or state.members, update.wave or state.wave
                if update.cycles and update.cycles > (state.reportedCycles or 0) then
                    state.cycles += update.cycles - (state.reportedCycles or 0)
                    state.reportedCycles = update.cycles
                end
                setStatus("Culling", message .. " | Wave: " .. tostring(state.wave or 0) .. " | Completed: " .. state.cycles)
            end}, liveSettings)
    end
    every("Culling coordinator", 0.2, function()
        local reason = higherPriority()
        local enabled = S("Culling.Enabled")
        local mode = currentGamemode()
        if not enabled or reason or (mode and mode ~= "Culling Game") then
            state.token += 1
            if state.worker and coroutine.status(state.worker) ~= "dead" then pcall(task.cancel, state.worker) end
            state.worker = nil
            state.target, state.positioned = nil, nil
            if mode == "Culling Game" and state.ownsRun then
                if os.clock() - (state.leaveAt or -math.huge) >= 5 then
                    state.leaveAt = os.clock()
                    leaveGamemode(reason and (reason .. " has priority") or "Culling disabled")
                end
            elseif state.ownsLobby and includesYou(currentParty) then
                state.ownsLobby = false
                hubMain.partyLobbies = hubMain.partyLobbies or {}
                hubMain.partyLobbies["Culling"] = false
                cullingLobby = hubMain.partyLobbies.Culling == true or hubMain.partyLobbies.DragonDefense == true
                fire("Parties", "Leave")
                currentParty = nil
            end
            setStatus("Culling", reason and ("Paused for " .. reason .. "; resumes in a new lobby")
                or (enabled and ("Paused: " .. tostring(mode)) or "Disabled"))
            return
        end
        if state.leaveAt and mode == "Culling Game" then return end
        state.leaveAt = nil
        if state.worker and coroutine.status(state.worker) ~= "dead" then return end
        state.token += 1
        state.reportedCycles = 0
        state.target, state.positioned = nil, nil
        local token = state.token
        state.worker = task.spawn(function()
            local ok, failure = pcall(run, token)
            if not ok and alive and state.token == token then
                lastError = "Culling: " .. tostring(failure)
                state.message = lastError
                allToggles["Culling.Enabled"].set(false)
                setStatus("Culling", lastError)
            end
        end)
        featureThreads[#featureThreads + 1] = state.worker
    end)
end
-- END_PORTED_CULLING

-- BEGIN_PORTED_DRAGON_DEFENSE
do
local function runAutomation(api, settings)
    local MODE = "Dragon Defense"
    local cycles = 0

    local function countMembers(party)
        local seen, count, includesYou = {}, 0, false
        for _, id in ipairs(party.MemberOrder or {}) do
            local key = tostring(id)
            if not seen[key] then
                seen[key] = true
                count = count + 1
            end
            if key == tostring(api.userId) then includesYou = true end
        end
        return count, includesYou
    end

    local function ownLobby(party)
        if type(party) ~= "table" or party.GamemodeName ~= MODE then return false end
        local _, includesYou = countMembers(party)
        return includesYou and tostring(party.Leader) == tostring(api.userId)
    end

    local function session()
        local data = api.data()
        if data.Gamemode == MODE and data.GamemodeSession ~= nil
            and data.GamemodeSession ~= false and data.GamemodeSession ~= "" then
            return tostring(data.GamemodeSession)
        end
        return nil
    end

    local function report(message, members, wave)
        api.report(message, {members = members, wave = wave, cycles = cycles})
    end

    local function send(section, action, ...)
        if not api.alive() then return false end
        api.fire(section, action, ...)
        return true
    end

    local function waitFor(predicate, seconds, failure)
        local deadline = api.now() + seconds
        while api.alive() do
            local value = predicate()
            if value then return value end
            if api.now() >= deadline then error(failure, 0) end
            if not api.sleep(0.2) then return nil end
        end
        return nil
    end

    local function matchesHost(party)
        if type(party) ~= "table" or party.ID == nil then return false end
        if party.GamemodeName and party.GamemodeName ~= MODE then return false end
        if tostring(party.Leader) == tostring(api.userId) then return false end
        return settings.hostUserId == nil or tostring(party.Leader) == tostring(settings.hostUserId)
    end

    local function waitForHost(partyId)
        local missingSince = nil
        while api.alive() do
            local activeSession = session()
            if activeSession then return activeSession end
            local party = api.party()
            if party then
                local members, includesYou = countMembers(party)
                if not includesYou or party.ID ~= partyId or not matchesHost(party) then
                    error("Your party/host changed. Stop, leave that party, and try again.", 0)
                end
                missingSince = nil
                report("Joined " .. (party.Difficulty or MODE) .. " lobby. Waiting for the host to start...", members, 0)
            else
                missingSince = missingSince or api.now()
                -- Party removal can arrive before the match data when the host starts.
                if api.now() - missingSince >= 5 then return nil end
                report("Lobby changed. Waiting for the match or the host's next lobby...", 0, 0)
            end
            if not api.sleep(0.2) then return nil end
        end
        return nil
    end

    local function joinPlayerLobby()
        local attemptedAt = {}
        while api.alive() do
            local activeSession = session()
            if activeSession then return activeSession end
            local party = api.party()
            if party then
                local _, includesYou = countMembers(party)
                if not includesYou or not matchesHost(party) then
                    error("Leave your current party first, or choose its host in Player mode.", 0)
                end
                activeSession = waitForHost(party.ID)
                if activeSession then return activeSession end
            else
                report(settings.hostUserId and "Looking for the selected host's public lobby..."
                    or "Looking for an open Dragon Defense lobby...", 0, 0)
                local lobbies = api.browse()
                if not api.alive() then return nil end
                -- A lobby or session may have arrived while Browse was in flight.
                activeSession = session()
                if activeSession then return activeSession end
                if not api.party() then
                    local candidates = {}
                    for _, lobby in pairs(lobbies) do
                        local members = type(lobby) == "table" and countMembers(lobby) or 0
                        local capacity = type(lobby) == "table" and (tonumber(lobby.MaxMembers) or api.maxMembers) or 0
                        if matchesHost(lobby) and members < capacity
                            and (lobby.Visibility == nil or lobby.Visibility == "Public")
                            and api.now() - (attemptedAt[tostring(lobby.ID)] or -math.huge) >= 5 then
                            table.insert(candidates, lobby)
                        end
                    end
                    table.sort(candidates, function(left, right) return tostring(left.ID) < tostring(right.ID) end)
                    local target = candidates[1]
                    if target then
                        api.checkEntry("Player")
                        report("Joining the host's Dragon Defense lobby...", countMembers(target), 0)
                        attemptedAt[tostring(target.ID)] = api.now()
                        if not send("Parties", "Join", target.ID) then return nil end
                        local deadline = api.now() + 10
                        while api.alive() and api.now() < deadline do
                            activeSession = session()
                            if activeSession then return activeSession end
                            local joined = api.party()
                            if joined then
                                local _, includesYou = countMembers(joined)
                                if not includesYou or joined.ID ~= target.ID or not matchesHost(joined) then
                                    error("You joined a different party. Check the selected host.", 0)
                                end
                                activeSession = waitForHost(joined.ID)
                                if activeSession then return activeSession end
                                break
                            end
                            if not api.sleep(0.2) then return nil end
                        end
                    end
                end
            end
            if not api.sleep(2) then return nil end
        end
        return nil
    end

    while api.alive() do
        if api.refreshSettings then api.refreshSettings(settings) end
        local activeSession = session()
        if not activeSession then
            local mode = api.data().Gamemode
            if mode and mode ~= "" and mode ~= MODE then
                error("Leave your current gamemode, then press Start again.", 0)
            end
            if settings.role == "Player" then
                api.checkEntry("Player")
                activeSession = joinPlayerLobby()
                if not activeSession then return end
            else
                api.checkEntry("Host")
                local party = api.party()
                if party and not ownLobby(party) then
                    error("Leave your current party first. You must host the Dragon Defense lobby.", 0)
                end

                if not party then
                    report("Creating a public Dragon Defense lobby...", 0, 0)
                    if not send("Parties", "Create", MODE) then return end
                    party = waitFor(function()
                        local candidate = api.party()
                        if candidate and not ownLobby(candidate) then
                            error("You joined a different party. Stop and leave it before trying again.", 0)
                        end
                        return candidate
                    end, 20, "Lobby creation was not confirmed. Check the game's notification and entry requirements.")
                    if not party then return end
                end

                local partyId = party.ID
                if settings.requiredPlayers > (tonumber(party.MaxMembers) or api.maxMembers) then
                    error("Selected player count exceeds this lobby's capacity.", 0)
                end
                local function sameLobby()
                    local latest = api.party()
                    if not ownLobby(latest) or latest.ID ~= partyId then
                        error("The lobby was closed, you left, or you are no longer the host.", 0)
                    end
                    return latest
                end

                report("Applying " .. settings.difficulty .. " difficulty and public visibility...", countMembers(party), 0)
                if party.Difficulty ~= settings.difficulty then
                    if not send("Parties", "SetDifficulty", settings.difficulty) then return end
                end
                if party.Visibility ~= "Public" then
                    if not send("Parties", "SetVisibility", "Public") then return end
                end
                party = waitFor(function()
                    local latest = sameLobby()
                    return latest.Difficulty == settings.difficulty and latest.Visibility == "Public" and latest
                end, 12, "The server did not confirm the difficulty/public setting. Check the game's notification.")
                if not party then return end

                local soloSince, waitingTarget = nil, settings.requiredPlayers
                while api.alive() do
                    party = sameLobby()
                    local members = countMembers(party)
                    local required = settings.requiredPlayers
                    if required ~= waitingTarget then
                        soloSince, waitingTarget = nil, required
                    end
                    if members >= required then break end
                    local countdown = ""
                    if required >= 2 and members == 1 then
                        soloSince = soloSince or api.now()
                        local remaining = math.max(0, 60 - (api.now() - soloSince))
                        if remaining <= 0 then
                            if not api.alive() then return end
                            if api.setRequiredPlayers then api.setRequiredPlayers(1)
                            else settings.requiredPlayers = 1 end
                            report("No one joined for 1 minute. Player requirement set to 1; starting solo.", members, 0)
                            break
                        end
                        countdown = " | Solo start in " .. math.ceil(remaining) .. "s"
                    else
                        soloSince = nil
                    end
                    report("Waiting for players: " .. members .. " / " .. required .. " (including you)" .. countdown, members, 0)
                    if not api.sleep(0.2) then return end
                end
                if not api.alive() then return end

                party = sameLobby()
                if party.Difficulty ~= settings.difficulty or party.Visibility ~= "Public" then
                    error("Lobby settings changed. Stop, check them, and press Start again.", 0)
                end
                api.checkEntry("Host")
                report("Starting " .. settings.difficulty .. " Dragon Defense...", countMembers(party), 0)
                if not send("Parties", "Start") then return end
                activeSession = waitFor(session, 25,
                    "The match did not start. Check the game's notification; no duplicate Start was sent.")
                if not activeSession then return end
            end
        end

        local lastWaveRead = api.now()
        while api.alive() and session() == activeSession do
            local wave = api.wave(activeSession)
            if type(wave) == "number" then
                lastWaveRead = api.now()
                report(settings.role == "Player" and "In Dragon Defense - Player"
                    or "In Dragon Defense - " .. settings.difficulty, nil, wave)
                if settings.autoLeave and wave >= settings.leaveWave then
                    report("Reached wave " .. wave .. ". Leaving the match...", nil, wave)
                    if not send("Gamemodes", "Leave") then return end
                    local left = waitFor(function()
                        return session() ~= activeSession
                    end, 25, "Leaving was not confirmed. Automation stopped; check the game.")
                    if not left then return end
                    break
                end
            else
                report("Waiting for the match's wave counter...", nil, nil)
                if api.now() - lastWaveRead > 30 then
                    error("The wave counter is unavailable. Automation stopped.", 0)
                end
            end
            if api.step and api.alive() and session() == activeSession then api.step(activeSession) end
            if not api.sleep(0.2) then return end
        end
        if not api.alive() then return end
        cycles = cycles + 1
        report(settings.role == "Player" and "Match ended. Looking for the host again in 3 seconds..."
            or "Match ended. Creating the next lobby in 3 seconds...", 0, 0)
        if not api.sleep(3) then return end
    end
end

local function pickTarget(candidates, collectChests)
    local best, bestRank = nil, math.huge
    for _, enemy in ipairs(candidates) do
        if not enemy.dead and (collectChests or not enemy.chest) then
            local rank = (enemy.chest and 0 or 1) * 1000000 + enemy.distance
            if rank < bestRank then best, bestRank = enemy, rank end
        end
    end
    return best
end

local function pickDragonDefenseTarget(current, candidates)
    local minis, bosses = {}, {}
    for _, enemy in ipairs(candidates) do
        if not enemy.dead and enemy.alive ~= false and not enemy.shielded then
            table.insert(enemy.boss and bosses or minis, enemy)
        end
    end
    local pool = #minis > 0 and minis or bosses
    -- Use the fresh candidate so a newly applied shield is never cached away.
    for _, enemy in ipairs(pool) do
        if current and enemy.id == current.id and enemy.object == current.object then return enemy end
    end
    return pickTarget(pool, true)
end


    local state: {[string]: any} = {cycles = 0, token = 0, worker = nil, ownsRun = false, ownsLobby = false}
    env.FarmHubDragonDefense = state
    local currentParty, received = nil, false
    local parties = Omni.Scripts.General.Parties
    local function includesYou(party)
        if type(party) ~= "table" or party.GamemodeName ~= "Dragon Defense" then return false end
        for _, id in ipairs(party.MemberOrder or {}) do if tostring(id) == tostring(player.UserId) then return true end end
        return false
    end
    connect(parties.SyncEvent, function(party)
        received = true
        if includesYou(party) then currentParty = party
        elseif currentParty and type(party) == "table" and party.ID == currentParty.ID then currentParty = nil end
    end)
    local function clearParty(id)
        received = true
        if currentParty and currentParty.ID == id then currentParty = nil end
    end
    for _, event in ipairs({parties.LeftEvent, parties.DisbandedEvent, parties.KickedEvent}) do
        if event then connect(event, clearParty) end
    end
    local controller
    pcall(function() controller = require(player.PlayerScripts.Omni.Scripts.Interface.Gamemodes.Controller) end)
    local function partySnapshot()
        if not received and controller and type(getupvalues) == "function" then
            for _, callback in ipairs({controller.OnSync, controller.OnLeft}) do
                if type(callback) == "function" then
                    for _, value in pairs(getupvalues(callback)) do
                        if includesYou(value) then currentParty = value end
                    end
                end
            end
        end
        hubMain.partyLobbies = hubMain.partyLobbies or {}
        hubMain.partyLobbies["DragonDefense"] = includesYou(currentParty)
        cullingLobby = hubMain.partyLobbies.Culling == true or hubMain.partyLobbies.DragonDefense == true
        if includesYou(currentParty) then state.ownsLobby = true end
        return currentParty
    end
    local function higherPriority()
        if not S("Priority.LeaveForPriority") then return nil end
        for _, other in ipairs({"Dungeon", "Trial"}) do
            if S(GAMEMODES[other].toggle) and priorityRank(other) < priorityRank("DragonDefense") and isOpen(other) then return other end
        end
        if S("Culling.Enabled") and priorityRank("Culling") < priorityRank("DragonDefense") then return "Culling" end
        if worldBoss.enabled and priorityRank("World Boss") < priorityRank("DragonDefense")
            and (busyBoss == worldBoss or worldBoss.phase == "gamemode" or worldBoss.phase == "queued"
                or worldBoss.phase == "teleporting" or worldBoss.phase == "holding"
                or worldBoss.phase == "returning") then return "World Boss" end
        return nil
    end
    local function wave(sessionId)
        local client = workspace:FindFirstChild("Client")
        local maps = client and client:FindFirstChild("Maps")
        local map = maps and maps:FindFirstChild("Dragon Defense")
        local sessions = map and map:FindFirstChild("GamemodeSessions")
        local holder = sessions and sessions:FindFirstChild(sessionId)
        if not holder or not holder:FindFirstChild("StateManager") then return nil end
        local manager = Omni.Utils.StateManager.Get(holder)
        if not manager then return nil end
        local value = manager:GetState("CurrentWave")
        return tonumber(value)
    end
    local function combat(sessionId, active)
        if not active() or Omni.Data.GamemodeSession ~= sessionId or Omni.Data.Gamemode ~= "Dragon Defense" then return end
        if not S("DragonDefense.TeleportToEnemies") then state.target = nil; return end
        local root, _, character = getRoot()
        if not root then return end
        if state.session ~= sessionId then state.session, state.target, state.positioned = sessionId, nil, nil end
        local candidates = {}
        for _, enemy in ipairs(game:GetService("CollectionService"):GetTagged("Enemy")) do
            if enemy.Parent and enemy:GetAttribute("Gamemode") == "Dragon Defense" and enemy:GetAttribute("SessionID") == sessionId
                and not enemy:GetAttribute("Died") then
                local data = enemy:FindFirstChild("Data")
                local health = data and data:FindFirstChild("Health")
                local hp = health and tonumber(health.Value)
                if not hp or hp > 0 then
                    local cf = Omni.Utils.Enemies.GetPosition(enemy:GetAttribute("EnemyID"))
                    if typeof(cf) == "CFrame" then
                        table.insert(candidates, {id = enemy:GetAttribute("EnemyID"), object = enemy, cf = cf, alive = true,
                            shielded = enemy:GetAttribute("Shielded") == true,
                            boss = enemy:GetAttribute("Difficulty") == "Boss" or enemy:GetAttribute("Difficulty") == "Secret"
                                or enemy:GetAttribute("Shielded") == true,
                            distance = (cf.Position - root.Position).Magnitude})
                    end
                end
            end
        end
        -- The original picker calls pickTarget only after retaining a living current target.
        state.target = pickDragonDefenseTarget(state.target, candidates)
        local target = state.target
        if not target then state.combat = "Waiting for minis / an unshielded enemy"; return end
        if state.positioned ~= target.object or state.character ~= character
            or (target.cf.Position - root.Position).Magnitude > 10 then
            local position = (target.cf * CFrame.new(0, 0, 4)).Position + Vector3.new(0, 5, 0)
            local facing = Vector3.new(target.cf.LookVector.X, 0, target.cf.LookVector.Z)
            if facing.Magnitude < 0.001 then facing = Vector3.new(0, 0, -1) end
            if teleportTo(CFrame.lookAt(position, position + facing.Unit)) then
                state.positioned, state.character = target.object, character
            end
        end
        if not active() or target.object:GetAttribute("Shielded") then return end
        state.combat = "Attacking " .. tostring(target.object:GetAttribute("EnemyName"))
        Omni.Scripts.General.Combat.Attack()
        if os.clock() - (state.lastFighters or 0) >= 1 and not state.fighterBusy then
            local available = {}
            for id, enemyId in pairs(Omni.Utils.PlayerStats.GetFighterTargets(Omni.Data, Omni.Instance)) do
                if enemyId == "" then table.insert(available, id) end
            end
            if #available > 0 then
                state.lastFighters, state.fighterBusy = os.clock(), true
                local thread = task.spawn(function()
                    if active() and target.object.Parent and not target.object:GetAttribute("Died")
                        and not target.object:GetAttribute("Shielded") then pcall(invoke, "Combat", "FighterAttack", target.id, available) end
                    state.fighterBusy = false
                end)
                featureThreads[#featureThreads + 1] = thread
            end
        end
    end
    local function run(token)
        local function active()
            return alive and state.token == token and S("DragonDefense.Enabled") and not higherPriority()
                and (not currentGamemode() or currentGamemode() == "Dragon Defense")
        end
        local liveSettings: {[string]: any} = {}
        setmetatable(liveSettings, {__index = function(_, key)
            if key == "requiredPlayers" then return math.clamp(tonumber(S("DragonDefense.StartPlayers")) or 1, 1, 10) end
            if key == "autoLeave" then return S("DragonDefense.AutoLeave") end
            if key == "leaveWave" then return math.max(1, tonumber(S("DragonDefense.Wave")) or 6) end
            return nil
        end})
        local function refresh()
            liveSettings.role, liveSettings.difficulty = S("DragonDefense.Role"), S("DragonDefense.Difficulty")
            liveSettings.hostUserId = nil
            local text = tostring(S("DragonDefense.Host") or ""):match("^%s*(.-)%s*$"):gsub("^@", "")
            if liveSettings.role == "Player" and text ~= "" then
                local id = tonumber(text)
                if not id then
                    for _, candidate in ipairs(Players:GetPlayers()) do if candidate.Name:lower() == text:lower() then id = candidate.UserId; break end end
                    id = id or Players:GetUserIdFromNameAsync(text)
                end
                assert(id and id > 0 and id % 1 == 0 and id ~= player.UserId, "Player mode needs a valid friend's username/user ID.")
                liveSettings.hostUserId = id
            end
        end
        local function guardedSleep(seconds)
            local deadline = os.clock() + seconds
            while active() and os.clock() < deadline do task.wait(math.min(0.1, deadline - os.clock())) end
            return active()
        end
        local info = assert(gamemodeInfo("Dragon Defense"), "Dragon Defense unavailable")
        runAutomation({userId = player.UserId, maxMembers = info.MaxPartyMembers or 4, alive = active, now = os.clock,
            refreshSettings = refresh,
            setRequiredPlayers = function(count)
                setSetting("DragonDefense.StartPlayers", count)
                if env.FarmHubDragonDefensePlayerSlider then env.FarmHubDragonDefensePlayerSlider.Refresh() end
            end,
            data = function() return Omni.Data end, party = partySnapshot,
            wave = wave, sleep = guardedSleep,
            step = function(sessionId) state.ownsRun = true; combat(sessionId, active) end,
            checkEntry = function(role)
                assert(Omni.Utils.PlayerStats.OwnsMap(info.MapName, Omni.Data), "Unlock " .. info.MapName .. " first.")
                if role == "Host" then
                    local price = Omni.Shared.Gamemodes.GetPrice(info)
                    if price then
                        local amount = Omni.Shared.Gamemodes.GetPriceAmount(Omni.Data, price)
                        assert(type(amount) ~= "number" or amount >= price.Amount, "Not enough " .. tostring(price.Name))
                    end
                end
            end,
            browse = function()
                local result = invoke("Parties", "Browse", "Dragon Defense")
                assert(type(result) == "table", "Could not read public lobbies")
                return result
            end,
            fire = function(section, action, ...)
                if active() then
                    if section == "Parties" and (action == "Create" or action == "Join") then state.ownsLobby = true end
                    if section == "Parties" and action == "Start" then state.ownsRun = true end
                    logAction("DragonDefense " .. section .. "/" .. action)
                    fire(section, action, ...)
                end
            end,
            report = function(message, update)
                state.message = message
                state.members, state.wave = update.members or state.members, update.wave or state.wave
                if update.cycles and update.cycles > (state.reportedCycles or 0) then
                    state.cycles += update.cycles - (state.reportedCycles or 0)
                    state.reportedCycles = update.cycles
                end
                setStatus("DragonDefense", message .. " | Wave: " .. tostring(state.wave or 0) .. " | Completed: " .. state.cycles)
            end}, liveSettings)
    end
    every("DragonDefense coordinator", 0.2, function()
        local reason = higherPriority()
        local enabled = S("DragonDefense.Enabled")
        local mode = currentGamemode()
        if not enabled or reason or (mode and mode ~= "Dragon Defense") then
            state.token += 1
            if state.worker and coroutine.status(state.worker) ~= "dead" then pcall(task.cancel, state.worker) end
            state.worker = nil
            state.target, state.positioned = nil, nil
            if mode == "Dragon Defense" and state.ownsRun then
                if os.clock() - (state.leaveAt or -math.huge) >= 5 then
                    state.leaveAt = os.clock()
                    leaveGamemode(reason and (reason .. " has priority") or "Dragon Defense disabled")
                end
            elseif state.ownsLobby and includesYou(currentParty) then
                state.ownsLobby = false
                hubMain.partyLobbies = hubMain.partyLobbies or {}
                hubMain.partyLobbies["DragonDefense"] = false
                cullingLobby = hubMain.partyLobbies.Culling == true or hubMain.partyLobbies.DragonDefense == true
                fire("Parties", "Leave")
                currentParty = nil
            end
            setStatus("DragonDefense", reason and ("Paused for " .. reason .. "; resumes in a new lobby")
                or (enabled and ("Paused: " .. tostring(mode)) or "Disabled"))
            return
        end
        if state.leaveAt and mode == "Dragon Defense" then return end
        state.leaveAt = nil
        if state.worker and coroutine.status(state.worker) ~= "dead" then return end
        state.token += 1
        state.reportedCycles = 0
        state.target, state.positioned = nil, nil
        local token = state.token
        state.worker = task.spawn(function()
            local ok, failure = pcall(run, token)
            if not ok and alive and state.token == token then
                lastError =  "Dragon Defense: " .. tostring(failure)
                state.message = lastError
                allToggles["DragonDefense.Enabled"].set(false)
                setStatus("DragonDefense", lastError)
            end
        end)
        featureThreads[#featureThreads + 1] = state.worker
    end)
end
-- END_PORTED_DRAGON_DEFENSE

-- Rolls: Haki, Cursed Technique, Talents, Traits and Breathings on the game's cooldowns.
local nextRoll = {}
local function rollReady(name)
    return os.clock() >= (nextRoll[name] or 0)
end

every("Talent queue catalog", 5, hubMain.refreshTalentQueue)
every("Talent queue", 0.25, function()
    if not S("Talents.Enabled") then return end
    local queue, goals = S("Talents.Queue") or {}, {}
    if #queue == 0 then hubMain.stopTalents("Select at least one unit");return end
    for _, stat in ipairs(hubMain.talentStats) do goals[stat] = S("Talents.Goal." .. stat) or "Ignore" end
    local id, fighter, remaining, reached, blocked
    local completed, missing, seen = 0, 0, {}
    for _, label in ipairs(queue) do
        local candidateId = hubMain.talentIds[hubMain.labelTag(label)]
        local candidate = candidateId and Omni.Data.Fighters.List[candidateId]
        if not candidate then missing += 1
        elseif not seen[candidateId] then
            seen[candidateId] = true
            local count, todo, ready, locked = hubMain.talentEvaluation(candidate, goals)
            if count == 0 then hubMain.stopTalents("Choose a minimum rank for at least one stat");return end
            if #todo == 0 then completed += 1
            elseif not fighter then id,fighter,remaining,reached,blocked=candidateId,candidate,todo,ready,locked end
        end
    end
    if not fighter then
        hubMain.stopTalents("Queue complete: " .. completed .. " unit(s)" .. (missing>0 and ("; " .. missing .. " missing unit(s) skipped") or ""))
        return
    end
    if #blocked > 0 then
        hubMain.stopTalents(tostring(fighter.Name) .. ": unlock " .. table.concat(blocked,", ") .. " to reach its goal")
        return
    end
    local data, info = Omni.Data, Omni.Shared.Gacha.List.Talents
    local price = info.Price
    local balance = price.Type=="Item" and (data.Items.List[price.Name] or 0) or Omni.Shared.Upgrade.GetPriceAmount(data,price)
    local signature = game:GetService("HttpService"):JSONEncode(fighter.Talents and fighter.Talents.Current or {})
    local pending = hubMain.talentPending
    if pending then
        local old = data.Fighters.List[pending.id]
        local updated = old and game:GetService("HttpService"):JSONEncode(old.Talents and old.Talents.Current or {})
        if balance < pending.balance or updated ~= pending.signature then
            hubMain.talentPending = nil
            hubMain.talentNextAt = os.clock() + playerStat("GachaCooldown",1,"Talents") + .25
        elseif os.clock()-pending.at>10 then hubMain.stopTalents("Talent roll was not confirmed; stopped")end
        return
    end
    if os.clock() < (hubMain.talentNextAt or 0) then return end
    local ui = require(player.PlayerScripts.Omni.Scripts.Interface.Gacha.Talents)
    local locked = fighter.Talents and fighter.Talents.Locked or {}
    local unlocked = 0
    for stat in pairs(hubMain.talentSource().List) do if not locked[stat] then unlocked+=1 end end
    ui.SelectFighter(id)
    if #reached>0 and unlocked>1 then
        local stat = reached[1]
        ui.ToggleLock(stat)
        hubMain.talentNextAt = os.clock() + .6
        setStatus("Talents", tostring(fighter.Name) .. ": locking " .. stat .. " at its goal")
        return
    end
    if unlocked==0 then hubMain.stopTalents("All stats are locked on " .. tostring(fighter.Name));return end
    if balance < price.Amount * unlocked then hubMain.stopTalents("Not enough " .. tostring(price.Name) .. "; stopped");return end
    hubMain.talentCurrent = id
    hubMain.talentPending = {id=id,balance=balance,signature=signature,at=os.clock()}
    hubMain.talentRolls = (hubMain.talentRolls or 0) + 1
    ui.Roll()
    setStatus("Talents", "Unit " .. (completed+1) .. "/" .. (#queue-missing) .. ": " .. tostring(fighter.Name)
        .. " | Remaining: " .. table.concat(remaining,", ") .. " | Rolls: " .. hubMain.talentRolls)
end)

every("Three breathings", 0.25, function()
    if not S("Slayers.RollUntilThree") then return end
    local id = hubMain.tripleId
    local data = Omni.Data
    local weapon = id and data.Weapons.List[id]
    if not weapon then hubMain.stopTriple("Selected weapon is unavailable");return end
    local count, locked = hubMain.breathingCount(weapon)
    if count >= 3 then
        local message = tostring(weapon.Name) .. ": 3 breathings reached after " .. tostring(hubMain.tripleRolls or 0) .. " rolls. Stopped."
        hubMain.stopTriple(message)
        notify(message)
        return
    end
    if locked >= count and count > 0 then hubMain.stopTriple("Unlock at least one breathing before rolling");return end
    local price = Omni.Shared.Breathings.Price
    local balance = price.Type == "Item" and (data.Items.List[price.Name] or 0)
        or Omni.Shared.Upgrade.GetPriceAmount(data, price)
    local pending = hubMain.triplePending
    if pending then
        if balance < pending.balance or (weapon.Breathings and weapon.Breathings.Current) ~= pending.current then
            hubMain.triplePending = nil
            nextRoll.Breathings = os.clock() + playerStat("BreathingsCooldown", 2) + 0.25
        elseif os.clock() - pending.at > 10 then
            hubMain.stopTriple("No roll confirmation received; stopped")
        end
        return
    end
    if not rollReady("Breathings") then return end
    if balance < price.Amount then hubMain.stopTriple("Not enough " .. tostring(price.Name) .. "; stopped");return end
    hubMain.triplePending = {balance = balance, current = weapon.Breathings and weapon.Breathings.Current, at = os.clock()}
    hubMain.tripleRolls = (hubMain.tripleRolls or 0) + 1
    nextRoll.Breathings = os.clock() + playerStat("BreathingsCooldown", 2) + 0.25
    fire("Breathings", "Spin", id, nextRequest())
    setStatus("TripleBreathings", tostring(weapon.Name) .. ": " .. count .. "/3 breathings | Rolls: " .. hubMain.tripleRolls)
end)

every("Auto breathing results", 0.25, function()
    if not S("Slayers.AutoBreathings") or S("Slayers.RollUntilThree") then return end
    local data = Omni.Data
    local id = hubMain.autoBreathingId
    local weapon = id and data.Weapons.List[id]
    if not weapon then hubMain.stopAutoBreathings("Selected weapon is unavailable");return end
    local names = hubMain.breathSelection(S("Slayers.StopAt"))
    local rarities = hubMain.breathSelection(S("Slayers.Rarity"))
    local gameStops = data.Breathings and data.Breathings.AutoStop or {}
    local hasStop = #names > 0 or #rarities > 0
    if not hasStop then
        for _, list in pairs(gameStops) do
            if type(list) == "table" then for _, wanted in pairs(list) do if wanted == true then hasStop = true end end end
        end
    end
    if not hasStop then hubMain.stopAutoBreathings("Select at least one desired breathing or rarity");return end
    local unlocked, locked, hit = 0, 0, nil
    for _, entry in pairs(weapon.Breathings and weapon.Breathings.Current or {}) do
        if type(entry) == "table" and entry.Name then
            if entry.Locked then locked += 1 else unlocked += 1 end
            if hubMain.breathMatch(entry, names, rarities, gameStops) then hit = entry end
        end
    end
    if hit then
        local message = tostring(hit.Rarity) .. " " .. tostring(hit.Name) .. " matched on " .. tostring(weapon.Name) .. ". Stopped."
        hubMain.stopAutoBreathings(message)
        notify(message)
        return
    end
    if unlocked == 0 and locked > 0 then hubMain.stopAutoBreathings("All breathings are locked; unlock one to roll");return end
    local price = Omni.Shared.Breathings.Price
    local balance = price.Type == "Item" and (data.Items.List[price.Name] or 0)
        or Omni.Shared.Upgrade.GetPriceAmount(data, price)
    local pending = hubMain.autoBreathingPending
    if pending then
        if balance < pending.balance or (weapon.Breathings and weapon.Breathings.Current) ~= pending.current then
            hubMain.autoBreathingPending = nil
            nextRoll.Breathings = os.clock() + playerStat("BreathingsCooldown", 2) + .25
        elseif os.clock() - pending.at > 10 then hubMain.stopAutoBreathings("No roll confirmation received; stopped") end
        return
    end
    if not rollReady("Breathings") then return end
    if balance < price.Amount then hubMain.stopAutoBreathings("Not enough " .. tostring(price.Name) .. "; stopped");return end
    hubMain.autoBreathingPending = {balance=balance,current=weapon.Breathings and weapon.Breathings.Current,at=os.clock()}
    hubMain.autoBreathingRolls = (hubMain.autoBreathingRolls or 0) + 1
    nextRoll.Breathings = os.clock() + playerStat("BreathingsCooldown", 2) + .25
    fire("Breathings", "Spin", id, nextRequest())
    setStatus("AutoBreathings", tostring(weapon.Name) .. ": " .. locked .. " locked, " .. unlocked .. " unlocked | Rolls: " .. hubMain.autoBreathingRolls)
end)

every("Rolls", 0.25, function()
    local data = Omni.Data
    for name, key in pairs({ Haki = "Heaven.AutoHaki", ["Cursed Technique"] = "Cursed.AutoCursedTechnique" }) do
        if S(key) and rollReady(name) then
            nextRoll[name] = os.clock() + playerStat("GachaCooldown", 1, name) + 0.1
            fire("Gacha", "Roll", name, nil, nextRequest())
        end
    end


end)

-- Upgrades that cost currency: one attempt per tick, only while below the cap.
local lastPrestige = 0
every("Upgrades", 2, function()
    local data = Omni.Data
    if S("Lobby.AutoUpgrade") then
        local name = S("Lobby.Upgrades")
        local info = Omni.Shared.Upgrade.List[UPGRADE_GROUP].Upgrades[name]
        local level = data.Upgrade and data.Upgrade[UPGRADE_GROUP] and data.Upgrade[UPGRADE_GROUP][name] or 0
        if info and (not info.MaxLevel or level < info.MaxLevel) then
            fire("Upgrade", "Upgrade", UPGRADE_GROUP, name)
        end
    end

    if S("Slayers.AutoProgression") then
        local name = "Slayer Progression"
        local info = Omni.Shared.Progression.List[name]
        local level = data.Progression and data.Progression.List and data.Progression.List[name] or 0
        if info and level < (info.MaxLevel or math.huge) then
            fire("Progression", "Upgrade", name)
        end
    end

    if S("Heaven.AutoPrestige") and os.clock() - lastPrestige > 30 then
        lastPrestige = os.clock()
        fire("Prestige", "Prestige")
    end

    if S("LevelUpgrades.AutoUpgrade") then
        local points = Omni.Shared.PlayerLevel.GetAvailablePoints(data)
        if type(points) == "number" and points > 0 then
            for _, stat in ipairs(S("LevelUpgrades.Order")) do
                local target = tonumber(S("LevelUpgrades." .. string.gsub(stat, " ", "") .. "Target")) or 0
                local level = data.Level.Stats and data.Level.Stats[stat] or 0
                if level < target then
                    fire("PlayerLevel", "UpgradeStat", stat, math.min(points, target - level))
                    break
                end
            end
        end
    end
end)

-- Commandments: checks every second using the game's own "can upgrade" rule and upgrades
-- the moment one is ready, instead of blindly sending all ten every few seconds.
local commandmentLevels = {}
every("Commandments", 1, function()
    if not S("Sins.AutoCommandments") then
        setStatus("Commandments", "Disabled")
        return
    end

    local data = Omni.Data
    local profession = Omni.Shared.Profession
    local closestText, closestFraction = nil, -1
    local maxed, total = 0, 0
    for _, name in ipairs(COMMANDMENTS) do
        total = total + 1
        local level = profession.GetCurrentLevel("Commandments", name, data)
        if commandmentLevels[name] and level > commandmentLevels[name] then
            notify(name .. " upgraded to level " .. level)
            logAction("Commandment " .. name .. " reached level " .. level)
        end
        commandmentLevels[name] = level

        local nextLevel = profession.GetLevelInformation("Commandments", name, level + 1)
        local needed = nextLevel and nextLevel.Requirement and nextLevel.Requirement.Amount
        if not needed then
            maxed = maxed + 1
        elseif profession.CanUpgrade("Commandments", name, data) then
            fire("Profession", "Upgrade", "Commandments", name)
            closestText, closestFraction = "Upgrading " .. name, math.huge
            task.wait(0.3)
        elseif profession.IsUnlocked("Commandments", name, data) then
            local progress = profession.GetCurrentProgress("Commandments", name, data)
            local fraction = progress / needed
            if fraction > closestFraction then
                closestFraction = fraction
                closestText = string.format("Next: %s lv %d, %d%% (%s/%s)", name, level,
                    math.floor(fraction * 100), tostring(math.floor(progress)), tostring(math.ceil(needed)))
            end
        end
    end
    setStatus("Commandments", maxed == total and "All commandments maxed"
        or closestText or "No commandment unlocked yet")
end)

-- Lobby chests: each has a 24 hour cooldown and must be claimed from next to it, so when one
-- is ready the hub makes a short trip to the Lobby and then returns to the map you were in.
local chestLock = {}
local chestRetryAt = {}

local function instancePosition(inst)
    if inst:IsA("BasePart") then
        return inst.Position
    elseif inst:IsA("Model") then
        return inst:GetPivot().Position
    end
    local part = inst:FindFirstChildWhichIsA("BasePart", true) or inst:FindFirstAncestorWhichIsA("BasePart")
    if part then
        return part.Position
    end
    local model = inst:FindFirstAncestorWhichIsA("Model")
    return model and model:GetPivot().Position
end

local function findChest(name)
    local label = name .. " Chest"
    for _, folderName in ipairs({ "Chests", "ProximityPrompts" }) do
        local folder = serverFolder(folderName)
        if folder then
            local direct = folder:FindFirstChild(name) or folder:FindFirstChild(label)
            if direct then return direct end
            for _, inst in ipairs(folder:GetDescendants()) do
                if inst.Name == label then return inst end
                for _, value in pairs(inst:GetAttributes()) do
                    if value == label then return inst end
                end
            end
        end
    end
    return nil
end

every("Chests", 30, function()
    if not S("Lobby.AutoChests") then
        setStatus("Chests", "Disabled")
        return
    end

    local data = Omni.Data
    local chests = Omni.Shared.Chests
    local now = workspace:GetServerTimeNow()
    local ready, soonest = {}, math.huge
    for name in pairs(chests.List) do
        if chests.MeetsRequirement(data, name) then
            local remaining = chests.GetRemaining(data, name, now)
            if remaining > 0 then
                soonest = math.min(soonest, remaining)
            elseif os.clock() >= (chestRetryAt[name] or 0) then
                ready[#ready + 1] = name
            end
        end
    end
    if #ready == 0 then
        setStatus("Chests", soonest < math.huge and ("Next chest in " .. formatTime(soonest))
            or "No chest available")
        return
    end
    if busyBoss ~= nil or currentGamemode() then
        setStatus("Chests", "Chest ready: waiting for the boss or gamemode to finish")
        return 5
    end

    -- Hold the teleport lock for the trip so the boss and farm loops do not pull you back.
    busyBoss = chestLock
    local returnMap = data.Maps and data.Maps.Current
    local ok, message = pcall(function()
        setStatus("Chests", "Going to the Lobby")
        requestMap("Lobby")
        for _, name in ipairs(ready) do
            chestRetryAt[name] = os.clock() + 600
            local chest = findChest(name)
            local position = chest and instancePosition(chest)
            if position then
                teleportTo(CFrame.new(position + Vector3.new(0, 4, 5)))
                task.wait(0.75)
            end
            logAction("Claim " .. name .. " chest" .. (position and "" or " (chest not found, claiming from spawn)"))
            fire("Chests", "Claim", name)
            task.wait(1.25)
        end
        if returnMap and returnMap ~= "Lobby" then
            requestMap(returnMap)
        end
    end)
    if busyBoss == chestLock then
        busyBoss = nil
    end
    if not ok then
        error(message, 0)
    end
    return 10
end)

every("Equipment", 30, function()
    if S("Equipment.AutoEvolveAccessories") then
        fire("Accessories", "EvolveAll")
    end
end)

-- Potions: drink when you own one and it has not been drunk within its duration.
local lastDrink = {}
every("Potions", 10, function()
    if not S("Potions.AutoDrink") then return end
    local data = Omni.Data
    local active = {}
    pcall(function()
        active = Omni.Shared.Potions.GetActive(data) or {}
    end)
    local running = data.Commerce and data.Commerce.Potions or {}

    for name, info in pairs(Omni.Shared.Potions.List) do
        local selected = S("Potions.Selected")
        local owned = data.Items.List[name] or 0
        local duration = type(info) == "table" and info.Duration or 600
        if (selected == "--" or selected == name) and owned > 0
            and not active[name] and not running[name]
            and os.clock() - (lastDrink[name] or -math.huge) > duration then
            lastDrink[name] = os.clock()
            task.spawn(pcall, invoke, "Marketplace", "UsePotion", name, false)
            task.wait(0.5)
        end
    end
end)

every("Quests", 60, function()
    local list = Omni.Data.Quests and Omni.Data.Quests.List
    if not list then return end

    local categories = {}
    if S("Quests.AutoQuest") then
        categories.Main = true
        categories.Side = true
    end
    categories.Daily = S("Quests.Daily") or nil
    categories.Weekly = S("Quests.Weekly") or nil

    for category in pairs(categories) do
        for name, quest in pairs(list[category] and list[category].List or {}) do
            if quest.Available and not quest.Claimed then
                fire("Quests", "Claim", category, name)
                task.wait(0.1)
            end
        end
    end

    -- Selected side quests are handled by the dedicated objective worker.
end)

-- Match the game's own reward UI checks. Each family runs independently so one
-- missing data table cannot prevent the other rewards from being checked.
local rewardChecks = { retryAt = {}, handlers = {} }
function rewardChecks.isClaimed(claimed, index)
    return type(claimed) == "table"
        and (claimed[index] == true or claimed[tostring(index)] == true)
end
function rewardChecks.claim(toggle, tag, system, action, ...)
    if not alive or not S(toggle) then return end
    local now = os.clock()
    if now < (rewardChecks.retryAt[tag] or 0) then return end
    -- Retry an unconfirmed claim after 15 seconds, even if progress is unchanged.
    rewardChecks.retryAt[tag] = now + 15
    fire(system, action, ...)
    task.wait(0.1)
end
rewardChecks.handlers["Rewards.AutoAchievement"] = function(data)
    local catalog = Omni.Shared.Achievements
    if type(data.Achievements) ~= "table" then return end
    for _, list in pairs(catalog.List) do
        for _, info in pairs(list) do
            if data.Achievements[info.Name] ~= true
                and select(3, catalog.GetProgress(data, info)) == 1 then
                rewardChecks.claim("Rewards.AutoAchievement", "Achievements", "Achievements", "ClaimAll")
                return
            end
        end
    end
end
rewardChecks.handlers["Rewards.AutoInbox"] = function(data)
    for _, message in pairs(data.Inbox and data.Inbox.List or {}) do
        if type(message) == "table" and message.Claimed ~= true then
            rewardChecks.claim("Rewards.AutoInbox", "Inbox", "Inbox", "ClaimAll")
            return
        end
    end
end
rewardChecks.handlers["Rewards.AutoDaily"] = function(data)
    local daily = data.DailyRewards
    if not daily or type(daily.Start) ~= "number" then return end
    -- A new player with Start == 0 can claim only day 1.
    local day = daily.Start == 0 and 1
        or math.floor((workspace:GetServerTimeNow() - daily.Start) / 86400) + 1
    for index, info in pairs(Omni.Shared.DailyRewards) do
        if type(index) == "number" and type(info) == "table" and index <= day
            and not rewardChecks.isClaimed(daily.Claimed, index) then
            rewardChecks.claim("Rewards.AutoDaily", "Daily:" .. daily.Start .. ":" .. index,
                "DailyRewards", "Claim", index)
        end
    end
end
rewardChecks.handlers["Rewards.AutoTime"] = function(data)
    local timed = data.TimeRewards
    if not timed or type(timed.TimePlayed) ~= "number" then return end
    -- TimePlayed is already updated by the game; adding os.clock would double-count it.
    for index, info in pairs(Omni.Shared.TimeRewards) do
        if type(info) == "table" and type(info.Time) == "number"
            and timed.TimePlayed >= info.Time
            and not rewardChecks.isClaimed(timed.Claimed, index) then
            rewardChecks.claim("Rewards.AutoTime", "Time:" .. tostring(timed.ResetAt) .. ":" .. index,
                "TimeRewards", "Claim", index)
        end
    end
end
rewardChecks.handlers["Rewards.AutoLevelRewards"] = function(data)
    local level = data.Level
    if not level or type(level.Amount) ~= "number" then return end
    for _, info in pairs(Omni.Shared.PlayerLevel.List.Rewards) do
        if info.Level <= level.Amount and not (level.Rewards and level.Rewards["Level" .. info.Level] == true) then
            rewardChecks.claim("Rewards.AutoLevelRewards", "Level:" .. info.Level,
                "PlayerLevel", "ClaimReward", info.Level)
        end
    end
end
rewardChecks.handlers["Rewards.AutoIndex"] = function(data)
    if type(data.Index) ~= "table" or type(data.IndexRewards) ~= "table" then return end
    local catalog = Omni.Shared.Index
    for section, group in pairs(catalog.Rewards) do
        local discovered = catalog.GetDiscoveredAmount(section, data)
        for _, info in pairs(group.List) do
            if info.Amount <= discovered and not catalog.IsRewardClaimed(section, info.Amount, data) then
                rewardChecks.claim("Rewards.AutoIndex", "Index:" .. section .. ":" .. info.Amount,
                    "IndexRewards", "Claim", section, info.Amount)
            end
        end
    end
end
for toggle, check in pairs(rewardChecks.handlers) do
    every(toggle, 5, function()
        if S(toggle) then check(Omni.Data) end
    end)
end

every("Fruits", 2, function()
    if not S("Heaven.AutoPickUpFruits") then return end
    local fruits = serverFolder("Fruits")
    if not fruits then return end
    for _, inst in ipairs(fruits:GetDescendants()) do
        local fruitId = inst:GetAttribute("FruitID")
        if typeof(fruitId) == "string" and (not inst:IsA("ProximityPrompt") or inst.Enabled) then
            fire("Fruits", "Collect", fruitId)
        end
    end
end)

local function withCommas(number)
    local text = tostring(math.floor(number + 0.5))
    local formatted, count = text, 0
    repeat
        formatted, count = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
    until count == 0
    return formatted
end

-- Secret pity. Stars have no guaranteed Secret; instead each star multiplies the Secret
-- chance every N opens without one. The chance shown comes from the game's own preview
-- with your current luck applied.
every("Pity", 3, function()
    local data = Omni.Data
    local stats = Omni.Utils.PlayerStats
    local luck = stats.Luck(data, Omni.Instance)
    local multipliers = {
        Mythical = stats.RarityChance(data, nil, "Mythical"),
        Secret = stats.RarityChance(data, nil, "Secret")
    }
    local opensPerSecond = playerStat("MaxStarOpens", 1) / (3.5 / playerStat("StarOpenSpeed", 1))

    local lines = {}
    for _, map in ipairs(MAP_NAMES) do
        local info = Omni.Shared.Stars.List[map]
        if info then
            local key = "Star_" .. map
            local state = Omni.Shared.SoftPity.GetState(data, key)
            local preview = Omni.Shared.Stars.GetPreview(info, luck, data.Pity and data.Pity[key],
                state, data, multipliers)
            local secretName, chance = "?", nil
            for name, group in pairs(preview and preview.Groups or {}) do
                if group == "Secret" then
                    secretName = name
                    chance = preview.Chances[name] and preview.Chances[name].Chance
                end
            end

            local config = nil
            for _, entry in pairs(info.SoftPity or {}) do
                if entry.Name == "Secret" then
                    config = entry
                end
            end
            local counter = type(state) == "table" and state.Secret or 0

            if chance and chance > 0 then
                local oneIn = 100 / chance
                lines[#lines + 1] = string.format("%s (%s): 1 in %s, ~%s of opening", map, secretName,
                    withCommas(oneIn), formatTime(oneIn / opensPerSecond))
            else
                lines[#lines + 1] = map .. ": chance unavailable"
            end
            if config then
                local stage = math.floor(counter / config.Amount)
                lines[#lines + 1] = string.format("  %s opens, boost x%.2f, next at %s", withCommas(counter),
                    config.Multiplier ^ stage, withCommas((stage + 1) * config.Amount))
            else
                lines[#lines + 1] = "  no soft pity on this star"
            end
            lines[#lines + 1] = ""
        end
    end
    setStatus("Pity", table.concat(lines, "\n"))
end)

-- Sacred Artefacts: upgrade any unlocked artefact you can afford, one per check.
every("Artefacts", 3, function()
    if not S("Artefacts.AutoUpgrade") then
        setStatus("Artefacts", "Disabled")
        return
    end

    local data = Omni.Data
    local artefacts = Omni.Shared.SacredArtefacts
    local waiting = nil
    local allMaxed = true
    for name in pairs(artefacts.List) do
        if artefacts.IsUnlocked(name, data) and not artefacts.IsMaxed(name, data) then
            allMaxed = false
            local level = artefacts.GetCurrentLevel(name, data)
            local nextLevel = artefacts.GetLevelInformation(name, level + 1)
            local price = nextLevel and nextLevel.Price
            if price and price.Type == "Item" then
                local owned = data.Items.List[price.Name] or 0
                if owned >= price.Amount then
                    logAction(string.format("Upgrade artefact %s to level %d", name, level + 1))
                    fire("SacredArtefacts", "Upgrade", name)
                    setStatus("Artefacts", "Upgrading " .. name .. " to level " .. (level + 1))
                    return
                elseif not waiting or price.Amount - owned < waiting.missing then
                    waiting = { name = name, price = price, owned = owned, missing = price.Amount - owned }
                end
            end
        end
    end
    if waiting then
        setStatus("Artefacts", string.format("Next: %s needs %s %s (have %s)", waiting.name,
            withCommas(waiting.price.Amount), waiting.price.Name, withCommas(waiting.owned)))
    else
        setStatus("Artefacts", allMaxed and "Every unlocked artefact is maxed" or "Nothing to upgrade")
    end
end)

-- Adventurer Shop: buy the ticked items whenever they are in stock and affordable.
local shopRetryAt = {}
local shopExpectedStock = {}
every("Shop", 10, function()
    if not S("Shop.AutoBuy") then
        setStatus("Shop", "Disabled")
        return
    end

    local data = Omni.Data
    local shop = Omni.Shared.Merchant.List[SHOP_NAME]
    local stockData = data.Merchant and data.Merchant[SHOP_NAME] or {}
    local bought, refused = 0, nil
    for name, info in pairs(shop and shop.Products or {}) do
        local price = info.Price
        local stock = stockData[name] and stockData[name].Stock or 0
        -- A purchase that left the stock unchanged was refused: back off for 5 minutes.
        if shopExpectedStock[name] and stock > shopExpectedStock[name] then
            shopRetryAt[name] = os.clock() + 300
            refused = name
        end
        shopExpectedStock[name] = nil

        if S("Shop.Buy." .. name) and stock > 0 and price and price.Type == "Item"
            and os.clock() >= (shopRetryAt[name] or 0) then
            local owned = data.Items.List[price.Name] or 0
            local amount = math.min(stock, math.floor(owned / math.max(price.Amount, 1)))
            if amount >= 1 then
                logAction(string.format("Buy %dx %s from %s", amount, name, SHOP_NAME))
                fire("Merchant", "Buy", SHOP_NAME, name, amount)
                shopExpectedStock[name] = stock - amount
                bought = bought + amount
                task.wait(0.4)
            end
        end
    end

    if bought > 0 then
        setStatus("Shop", "Bought " .. bought .. " item(s)")
    elseif refused then
        setStatus("Shop", "The shop refused " .. refused .. ". Retrying in 5 minutes.")
    else
        setStatus("Shop", "Waiting for stock or shards")
    end
end)

-- Secret rolls: watches your fighter index and inventory for new Secret-rarity fighters.
local secretCounts = nil
local knownFighterIds = nil
every("Secret Watch", 1, function()
    local data = Omni.Data
    local fighterInfo = Omni.Shared.Fighters.List
    local index = data.Index and data.Index.Fighter or {}

    local newById = {}
    local ids = {}
    for id, fighter in pairs(data.Fighters.List or {}) do
        ids[id] = true
        local info = fighterInfo[fighter.Name]
        if knownFighterIds and not knownFighterIds[id] and info and info.Rarity == "Secret" then
            local entry = newById[fighter.Name] or { count = 0, shiny = false }
            entry.count = entry.count + 1
            entry.shiny = entry.shiny or fighter.Shiny == true
            newById[fighter.Name] = entry
        end
    end

    local counts = {}
    for name, info in pairs(fighterInfo) do
        if type(info) == "table" and info.Rarity == "Secret" then
            counts[name] = index[name] or 0
            local fromIndex = secretCounts and (counts[name] - (secretCounts[name] or 0)) or 0
            local fromIds = newById[name] and newById[name].count or 0
            local gained = math.max(fromIndex, fromIds)
            if gained > 0 then
                local shiny = newById[name] and newById[name].shiny
                local text = string.format("**%s** rolled a SECRET: **%s%s**%s (total rolled: %d)",
                    player.Name, shiny and "Shiny " or "", name,
                    gained > 1 and (" x" .. gained) or "", counts[name])
                logAction("Secret rolled: " .. name)
                notify("Secret rolled: " .. name)
                if S("Webhook.PingSecret") then
                    task.spawn(sendWebhook, text, true)
                end
            end
        end
    end
    secretCounts = counts
    knownFighterIds = ids

    setStatus("Webhook", webhookUrl() and "Webhook set. Watching for Secret rolls and disconnects."
        or "No valid Discord webhook URL yet.")
end)

end
startFeatures()

-- Lifecycle --------------------------------------------------------------------------

local function unload()
    cleanup(true)
end

cleanup = function(removeGui)
    if cleanedUp then return end
    cleanedUp = true
    if hubMain.performance.capApplied and hubMain.performance.originalCap ~= nil and type(setfpscap) == "function" then
        pcall(setfpscap, hubMain.performance.originalCap)
    end
    if env.FarmHubCulling then env.FarmHubCulling.token += 1; env.FarmHubCulling = nil end
    env.FarmHubCullingPlayerSlider = nil
    if env.FarmHubDragonDefense then env.FarmHubDragonDefense.token += 1; env.FarmHubDragonDefense = nil end
    env.FarmHubDragonDefensePlayerSlider = nil
    saveSettings()
    alive = false

    for _, boss in ipairs(bosses) do
        stopBoss(boss)
    end
    for _, thread in ipairs(featureThreads) do
        if thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
            pcall(task.cancel, thread)
        end
    end
    if antiAfkConnection then
        antiAfkConnection:Disconnect()
        antiAfkConnection = nil
    end
    if antiAfkThread then
        pcall(task.cancel, antiAfkThread)
        antiAfkThread = nil
    end
    restoreGameAntiAfk()
    if eventPopup.module and eventPopup.original then
        eventPopup.module.PromptToFollow = eventPopup.original
    end
    -- Stops this copy's retry loop; an unsent ping stays in its file for the next hub.
    pendingPing = nil

    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    connections = {}
    dragging = false
    dragInput = nil
    if env.FarmHubUnload == unload then
        env.FarmHubUnload = nil
    end

    if removeGui then
        gui:Destroy()
    end
end

env.FarmHubUnload = unload

connect(gui.Destroying, function()
    cleanup(false)
end)

-- Update the status lines independently of the feature loops.
local updateElapsed = 0
connect(RunService.Heartbeat, function(deltaTime)
    if not alive then return end
    updateElapsed = updateElapsed + deltaTime
    if updateElapsed < 0.2 then return end
    updateElapsed = 0

    for _, boss in ipairs(bosses) do
        boss.statusLabel.Text = bossStatus(boss)
    end
    errorLabel.Text = lastError and ("Last error: " .. lastError) or "No worker errors"
end)

-- Main is the starting page; config loads return to Settings.
selectTab(hubMain.tab)
if importedSettings then
    for _, tab in ipairs(tabs) do
        if tab.name == "Settings" then selectTab(tab); break end
    end
end
for _, callback in ipairs(startup) do
    callback()
end
saveSettings()
end
launchFarmHub()
