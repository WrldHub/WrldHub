-- Farm Hub: standalone Roblox client script. Run this entire file together.
-- Features call the game's own client module, so they send the same requests its UI sends.
-- The few controls with dimmed text are saved but not wired to the game.
-- Right Shift hides/shows the window. Settings > Unload stops everything and removes it.

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
local FARM_STEP_INTERVAL = 2          -- seconds between re-pins to the farm spot
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
        ["Bosses.Farm"] = true,
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

-- UI toolkit -------------------------------------------------------------------------

local COLORS = {
    window = Color3.fromRGB(22, 23, 28),
    sidebar = Color3.fromRGB(16, 17, 21),
    card = Color3.fromRGB(30, 31, 38),
    stroke = Color3.fromRGB(46, 48, 58),
    box = Color3.fromRGB(40, 42, 52),
    boxHover = Color3.fromRGB(54, 56, 68),
    off = Color3.fromRGB(68, 70, 82),
    accent = Color3.fromRGB(138, 99, 210),
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
        Text = "Farm Hub",
        TextColor3 = COLORS.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = FONTS.bold,
        TextSize = 18
    }, sidebar)
    new("TextLabel", {
        Position = UDim2.fromOffset(16, 36),
        Size = UDim2.new(1, -32, 0, 16),
        BackgroundTransparency = 1,
        Text = "Right Shift: hide/show",
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
            tabTitle.Text = "Farm Hub"
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
end

local function addTab(name)
    local button = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = COLORS.card,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false
    }, navList)
    round(button, 6)
    local marker = new("Frame", {
        Position = UDim2.fromOffset(0, 8),
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
    new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
        Text = titleText,
        TextColor3 = COLORS.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = FONTS.bold,
        TextSize = 15
    }, section)
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

    local toggle = {}
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
local function addDropdown(section, labelText, key, options, default, onChange)
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
    function dropdown.set(value, silent)
        setSetting(key, value)
        valueLabel.Text = tostring(value)
        if onChange and not silent then
            onChange(value)
        end
    end
    function dropdown.setOptions(newOptions)
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
            hover(optionButton, COLORS.box, COLORS.boxHover)
            connect(optionButton.Activated, function()
                setOpen(false)
                dropdown.set(option)
            end)
        end
        list.Size = UDim2.new(1, 0, 0, math.min(#newOptions, 7) * OPTION_HEIGHT)
        list.CanvasSize = UDim2.fromOffset(0, #newOptions * OPTION_HEIGHT)
    end

    dropdown.setOptions(options)
    valueLabel.Text = tostring(getSetting(key, default))
    connect(button.Activated, function()
        setOpen(not list.Visible)
    end)
    return dropdown
end

local function addSlider(section, labelText, key, minValue, maxValue, default)
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

connect(UserInputService.InputBegan, function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then
        window.Visible = not window.Visible
    end
end)

-- Game access ------------------------------------------------------------------------

-- The game's own client module: Signal sends the same calls the game's UI sends, and Data
-- is the live copy of your save data.
local Omni = require(ReplicatedStorage:WaitForChild("Omni"))
local StarterGui = game:GetService("StarterGui")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")

local RANKS = { "F", "E", "D", "C", "B", "A", "S" }
local RARITIES = { "--", "Common", "Rare", "Epic", "Legendary", "Mythical", "Secret" }
local DUNGEON_ENTRY_GRACE = 75 -- seconds after :00 before assuming you skipped the dungeon
local SHOP_NAME = "Adventurer Shop"
local UPGRADE_GROUP = "Adventurer Upgrades"
local INDEX_DATA_KEYS = {
    Fighters = "Fighter",
    Accessories = "Accessory",
    Weapons = "Weapon",
    Enemies = "Enemy"
}
local SIDE_QUESTS = {
    ["Slayers.QuestCrimsonMoon"] = "Beneath the Crimson Moon",
    ["Sins.QuestGreedOfTheFox"] = "The Greed of the Fox",
    ["Heaven.QuestCaptainsPromise"] = "A Captain's Promise",
    ["Cursed.QuestWeightOfInfinity"] = "The Weight of Infinity"
}

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
            Title = "Farm Hub",
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
            username = "Farm Hub",
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
            and (not enemyName or inst:GetAttribute("EnemyName") == enemyName) then
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
    Culling = { "Culling.Enabled" }
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
    return table.find(settings["Priority.Order"] or {}, name) or math.huge
end

local function equippedFighterIds()
    local ids = {}
    for id in pairs(Omni.Data.Fighters.Equipped or {}) do
        ids[#ids + 1] = id
    end
    return ids
end

-- Fighter dropdowns show "Name #abcd"; this maps those labels back to fighter IDs.
local fighterIdByLabel = {}
local function fighterLabels()
    local labels = {}
    table.clear(fighterIdByLabel)
    for id, fighter in pairs(Omni.Data.Fighters.List or {}) do
        local label = tostring(fighter.Name) .. (fighter.Shiny and " (Shiny)" or "")
            .. " #" .. string.sub(id, -4)
        fighterIdByLabel[label] = id
        labels[#labels + 1] = label
    end
    table.sort(labels)
    table.insert(labels, 1, "--")
    return labels
end

local function selectedFighter(key)
    local id = fighterIdByLabel[S(key)]
    return id, id and Omni.Data.Fighters.List[id]
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
local farmCatalog = { dropdowns = {}, cached = {}, mobs = nil }
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
    local names = mobNames(S("MobFarm.World"))
    local options = #names > 0 and names or { "--" }
    farmCatalog.updateOptions(farmCatalog.mobs, "MobFarm.Mobs", options)
    if not table.find(options, S("MobFarm.Mobs")) then
        -- Do not silently move an active farm onto a different enemy after an update.
        if allToggles["MobFarm.AutoFarm"] then allToggles["MobFarm.AutoFarm"].set(false) end
        farmCatalog.mobs.set(options[1], true)
    end
end
function farmCatalog.refresh()
    local worlds = farmCatalog.discover()
    for key, dropdown in pairs(farmCatalog.dropdowns) do
        local options = table.clone(worlds)
        if key == "Summon.World" then table.insert(options, 1, "Current World") end
        if #options == 0 then options = { "--" } end
        farmCatalog.updateOptions(dropdown, key, options)
        if not table.find(options, S(key)) then
            local toggleKey = key == "MobFarm.World" and "MobFarm.AutoFarm"
                or key == "Bosses.FarmMap" and "Bosses.Farm"
                or key == "Summon.World" and "Summon.AutoSummon"
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
local lastRequestedMap = nil

local worldBoss = {
    name = "World Boss",
    map = WORLD_BOSS_MAP,
    destination = CFrame.new(4354, 41, 4378),
    enabled = false,
    phase = "off"
}
local farmBoss = {
    name = "Boss Farm",
    isFarm = true,
    enabled = false,
    phase = "off"
}
local bosses = { worldBoss, farmBoss }

local function formatTime(seconds)
    seconds = math.max(0, math.ceil(seconds))
    return string.format("%02d:%02d:%02d",
        math.floor(seconds / 3600),
        math.floor(seconds / 60) % 60,
        seconds % 60
    )
end

local function farmCFrame()
    local position = settings["Bosses.FarmPosition"]
    return CFrame.new(position[1], position[2], position[3])
end

local function bossStatus(boss)
    if not boss.enabled then
        return boss.phase == "error" and "Teleport failed. Toggle to retry." or "Stopped"
    end

    local now = os.clock()
    if boss.phase == "teleporting" then
        return "Entering map in: " .. formatTime(boss.teleportAt - now)
    elseif boss.phase == "holding" then
        return boss.bossSeen and "Boss alive, boss farm paused" or "Looking for the boss..."
    elseif boss.phase == "dungeon" then
        return "Waiting for the :00 dungeon to finish"
    elseif boss.phase == "gamemode" then
        return "Paused: in a dungeon/trial"
    elseif boss.phase == "queued" then
        return "Paused for the other teleport..."
    elseif boss.phase == "loading" then
        return "Waiting for your character..."
    elseif boss.isFarm then
        return "Holding the farm spot"
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

-- You are in a gamemode when the game's own data says so, or when a non-world map has a
-- populated folder in Workspace.Server.Teleport.
local function inGamemode()
    if not settings["Bosses.PauseInGamemode"] then return false end
    if currentGamemode() then return true end

    local teleports = serverFolder("Teleport")
    if not teleports then return false end
    for _, folder in ipairs(teleports:GetChildren()) do
        if not WORLD_MAPS[folder.Name] and #folder:GetChildren() > 0 then
            return true
        end
    end
    return false
end

local lastPriorityLeave = 0
local function acquireTeleport(boss)
    boss.phase = "queued"
    while alive and boss.enabled do
        if inGamemode() then
            -- World Boss pulls you out of gamemodes ranked below it in the Priority list.
            local gamemode = currentGamemode()
            local activity = gamemode and activityOf(gamemode)
            if not boss.isFarm and activity and settings["Priority.LeaveForPriority"]
                and activityManaged(activity)
                and priorityRank("World Boss") < priorityRank(activity)
                and os.clock() - lastPriorityLeave > 5 then
                lastPriorityLeave = os.clock()
                logAction("Leave " .. gamemode .. ": World Boss ranks above it")
                fire("Gamemodes", "Leave")
            end
            boss.phase = "gamemode"
            -- Force a map re-entry once the dungeon/trial is over.
            lastRequestedMap = nil
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
    lastRequestedMap = map
    task.wait(TELEPORT_DELAY)
end

local function enterMap(boss)
    boss.phase = "teleporting"
    boss.teleportAt = os.clock() + TELEPORT_DELAY
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
        if not acquireTeleport(boss) then return end

        local success, message = pcall(function()
            enterMap(boss)
            moveCharacter(boss, boss.destination)
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
        while os.clock() - holdStart < WORLD_BOSS_MAX_HOLD do
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

        if busyBoss == boss then busyBoss = nil end
    end
end

local function runBossFarm(boss)
    while alive and boss.enabled do
        if not acquireTeleport(boss) then return end

        local success, message = pcall(function()
            -- Enter the farm map once, and return after World Boss or a dungeon/trial.
            boss.map = settings["Bosses.FarmMap"]
            if lastRequestedMap ~= boss.map then
                enterMap(boss)
            end
            moveCharacter(boss, farmCFrame())
        end)
        if busyBoss == boss then busyBoss = nil end
        if not success then
            failBoss(boss, message)
            return
        end

        boss.phase = "cycling"
        task.wait(FARM_STEP_INTERVAL)
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
        if boss.isFarm then
            runBossFarm(boss)
        else
            runWorldBoss(boss)
        end
    end)
end

-- True while something with a higher claim on your position is active.
local function positionTaken()
    return busyBoss ~= nil or farmBoss.enabled or currentGamemode() ~= nil
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
local fighterDropdowns = {}

local function refreshFighters()
    local labels = fighterLabels()
    for _, dropdown in ipairs(fighterDropdowns) do
        dropdown.setOptions(labels)
    end
end

-- Tabs -------------------------------------------------------------------------------

-- Built inside one function so the tab variables do not count against Luau's limit of 200
-- locals in the main body. Setting keys are unchanged from earlier versions, so saved
-- settings carry over.
local errorLabel
local function buildTabs()
    local tab, section

    -- Bosses
    tab = addTab("Bosses")
    section = addSection(tab, 1, "World Boss")
    worldBoss.toggle = addToggle(section, "Auto World Boss", "Bosses.WorldBoss", false, function(value)
        setBossEnabled(worldBoss, value)
    end)
    worldBoss.statusLabel = addLabel(section, "Stopped", COLORS.accent)
    addLabel(section, "Goes to Sins Kingdom for Demon Melyode as soon as the :00 dungeon is finished "
        .. "(or about a minute after :00 if you did not join it), and pauses the boss farm until "
        .. "the boss is dead.", COLORS.dim)

    section = addSection(tab, 1, "Safety")
    addToggle(section, "Pause bosses in dungeon/trial", "Bosses.PauseInGamemode", true, W)

    section = addSection(tab, 2, "Boss Farm")
    farmBoss.toggle = addToggle(section, "Auto Boss Farm", "Bosses.Farm", false, function(value)
        setBossEnabled(farmBoss, value)
    end)
    farmBoss.statusLabel = addLabel(section, "Stopped", COLORS.accent)
    farmCatalog.dropdowns["Bosses.FarmMap"] = addDropdown(section, "Map", "Bosses.FarmMap", MAP_NAMES, "Cursed Academy", W)
    local position = getSetting("Bosses.FarmPosition", { -2243, 57, 208 })
    if type(position) ~= "table" or #position ~= 3 then
        settings["Bosses.FarmPosition"] = { -2243, 57, 208 }
    end
    local positionLabel = addLabel(section, "", COLORS.text, nil, 13)
    local function renderPosition()
        local saved = settings["Bosses.FarmPosition"]
        positionLabel.Text = string.format("Farm spot: %d, %d, %d", saved[1], saved[2], saved[3])
    end
    renderPosition()
    addButton(section, "Set Spot to My Position", function()
        local root = getRoot()
        if not root then return end
        setSetting("Bosses.FarmPosition", {
            math.floor(root.Position.X + 0.5),
            math.floor(root.Position.Y + 0.5),
            math.floor(root.Position.Z + 0.5)
        })
        renderPosition()
    end)

    -- Farming
    tab = addTab("Farming")
    section = addSection(tab, 1, "Mob Farm")
    addToggle(section, "Auto Farm", "MobFarm.AutoFarm", false, W)
    statusLabels.MobFarm = addLabel(section, "Disabled", COLORS.accent)
    addToggle(section, "Send fighters to closest", "MobFarm.SendToClosest", false, W)
    farmCatalog.dropdowns["MobFarm.World"] = addDropdown(section, "World", "MobFarm.World", MAP_NAMES, "Heaven Island", function()
        farmCatalog.refreshMobs()
    end)
    farmCatalog.mobs = addDropdown(section, "Mob", "MobFarm.Mobs",
        mobNames(getSetting("MobFarm.World", "Heaven Island")), "Hawk Eyes", W)
    addSlider(section, "Distance from mob", "MobFarm.Offset", 0, 15, 3)

    section = addSection(tab, 1, "Summon")
    addToggle(section, "Auto Summon", "Summon.AutoSummon", false, W)
    statusLabels.Summon = addLabel(section, "Disabled", COLORS.accent)
    farmCatalog.dropdowns["Summon.World"] = addDropdown(section, "World", "Summon.World", { "Current World", unpack(MAP_NAMES) }, "Current World", W)
    addDropdown(section, "Star", "Summon.Star", { "Closest" }, "Closest", W)

    section = addSection(tab, 2, "Secret Pity (stars)")
    statusLabels.Pity = addLabel(section, "Loading...", COLORS.text)

    section = addSection(tab, 2, "Priority")
    addToggle(section, "Leave for a higher priority", "Priority.LeaveForPriority", true, W)
    addPriorityList(section, "Priority.Order",
        { "Trial", "Dungeon", "World Boss", "Culling", "Quest", "Mob Farm" }, "Activity to move")

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
    statusLabels.Dungeon = addLabel(section, "", COLORS.accent)
    addDropdown(section, "Difficulty", "Dungeon.Difficulty", DIFFICULTIES, "Easy", W)
    addToggle(section, "Walk to enemies (no teleport)", "Dungeon.WalkToEnemy", false, W)
    addToggle(section, "Auto Leave when cleared", "Dungeon.AutoLeave", false, W)

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

    -- Fighters
    tab = addTab("Fighters")
    section = addSection(tab, 1, "Feed")
    addToggle(section, "Auto Feed", "Feed.AutoFeed", false, W)
    statusLabels.Feed = addLabel(section, "Disabled", COLORS.accent)
    addDropdown(section, "Who to feed", "Feed.Mode", { "Selected Fighters", "Equipped Fighters" },
        "Selected Fighters", W)
    fighterDropdowns[#fighterDropdowns + 1] = addDropdown(section, "Fighter", "Feed.Fighters",
        fighterLabels(), "--", W)
    local foods = { "Cursed Mochi" }
    pcall(function()
        foods = Omni.Shared.FighterFeed.GetFoods()
    end)
    addDropdown(section, "Food", "Feed.Food", foods, "Cursed Mochi", W)
    addNumberBox(section, "Food per feed", "Feed.Amount", 1000)

    section = addSection(tab, 1, "Deconstruct")
    addToggle(section, "Auto Deconstruct", "Deconstruct.AutoDeconstruct", false, W)
    statusLabels.Deconstruct = addLabel(section, "Disabled", COLORS.accent)
    addLabel(section, "Only fighters you set to Auto Deconstruct in the game's star settings, and "
        .. "only if unlocked, unequipped, not in a team and level 1.", COLORS.dim)

    section = addSection(tab, 2, "Talents and Traits")
    fighterDropdowns[#fighterDropdowns + 1] = addDropdown(section, "Fighter to roll on",
        "Lobby.Fighter", fighterLabels(), "--", W)
    statusLabels.Rolls = addLabel(section, "", COLORS.accent)
    addToggle(section, "Auto Talents", "Lobby.AutoTalents", false, W)
    addDropdown(section, "Stop when all talents reach", "Lobby.TalentsStopAt", RANKS, "S", W)
    addToggle(section, "Auto Traits", "Lobby.AutoTraits", false, W)
    addDropdown(section, "Stop at trait", "Lobby.TraitsStopAt", sortedKeys(function()
        return Omni.Shared.Traits.List
    end, "--"), "--", W)

    section = addSection(tab, 2, "Equipment")
    addToggle(section, "Auto Equip Best", "Equipment.AutoEquipBest", false, W)
    addToggle(section, "Auto Evolve Accessories", "Equipment.AutoEvolveAccessories", false, W)

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
    addToggle(section, "Auto Breathings", "Slayers.AutoBreathings", false, W)
    addDropdown(section, "Stop at breathing", "Slayers.StopAt", sortedKeys(function()
        return Omni.Shared.Breathings.List
    end, "--"), "--", W)
    addDropdown(section, "Stop at rarity", "Slayers.Rarity", RARITIES, "--", W)

    section = addSection(tab, 2, "Cursed Academy")
    addToggle(section, "Auto Cursed Technique", "Cursed.AutoCursedTechnique", false, W)

    section = addSection(tab, 2, "Sins Kingdom")
    addToggle(section, "Auto Commandments", "Sins.AutoCommandments", false, W)
    statusLabels.Commandments = addLabel(section, "Disabled", COLORS.accent)

    -- Quests and rewards
    tab = addTab("Quests & Rewards")
    section = addSection(tab, 1, "Quests")
    addToggle(section, "Auto Quest (main and side)", "Quests.AutoQuest", false, W)
    addToggle(section, "Daily Quests", "Quests.Daily", false, W)
    addToggle(section, "Weekly Quests", "Quests.Weekly", false, W)

    section = addSection(tab, 1, "Side Quests")
    addToggle(section, "A Captain's Promise", "Heaven.QuestCaptainsPromise", false, W)
    addToggle(section, "Beneath the Crimson Moon", "Slayers.QuestCrimsonMoon", false, W)
    addToggle(section, "The Weight of Infinity", "Cursed.QuestWeightOfInfinity", false, W)
    addToggle(section, "The Greed of the Fox", "Sins.QuestGreedOfTheFox", false, W)
    addLabel(section, "Accepts and turns these in. The objectives themselves are not automated.", COLORS.dim)

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

    -- Items and shop
    tab = addTab("Items & Shop")
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
            local ok, reason = sendWebhook("Test message from Farm Hub for **" .. player.Name .. "**.", true)
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
    addButton(section, "Stop All Features", function()
        for key, toggle in pairs(allToggles) do
            if settings[key] == true and string.sub(key, 1, 8) ~= "Session."
                and string.sub(key, 1, 8) ~= "Webhook." and string.sub(key, 1, 9) ~= "Shop.Buy."
                and key ~= "Bosses.PauseInGamemode" and key ~= "Priority.LeaveForPriority"
                and key ~= "Culling.TeleportToEnemies" then
                toggle.set(false)
            end
        end
    end)
    addButton(section, "Save Settings", saveSettings)
    addButton(section, "Refresh Fighter Lists", refreshFighters)
    addButton(section, "Unload Hub", function()
        cleanup(true)
    end)
end
buildTabs()
farmCatalog.refresh()

-- Features ---------------------------------------------------------------------------

-- The feature loops live in their own function because Luau allows at most 200 local
-- variables per function, and the hub's main body is close to that.
local function startFeatures()

every("Farming catalog", 5, farmCatalog.refresh)

-- Mob farm: stay next to the chosen mob in the chosen world.
local lastFighterSend = 0
every("Mob Farm", 0.5, function()
    if not S("MobFarm.AutoFarm") then
        setStatus("MobFarm", "Disabled")
        return
    end
    if not WORLD_MAPS[S("MobFarm.World")] or S("MobFarm.Mobs") == "--" then
        setStatus("MobFarm", "Waiting for worlds and mobs to load")
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

    local mob = S("MobFarm.Mobs")
    local target, distance, position = nearestTo(
        findEnemies(serverFolder("Enemies", "Maps", world), mob), root.Position)
    if not target then
        setStatus("MobFarm", "No " .. tostring(mob) .. " found")
        return
    end

    local offset = tonumber(S("MobFarm.Offset")) or 3
    if distance > offset + 5 then
        teleportTo(CFrame.new(position + Vector3.new(0, 3, offset)))
    end
    if S("MobFarm.SendToClosest") and os.clock() - lastFighterSend > 1 then
        lastFighterSend = os.clock()
        task.spawn(pcall, invoke, "Combat", "FighterAttack", target:GetAttribute("EnemyID"), equippedFighterIds())
    end
    setStatus("MobFarm", "Farming " .. tostring(mob))
end)

-- Summon: stand at a star and open it on the game's own cooldown.
local nextStarRoll = 0
every("Summon", 0.3, function()
    if not S("Summon.AutoSummon") then
        setStatus("Summon", "Disabled")
        return
    end
    if positionTaken() or S("MobFarm.AutoFarm") then
        setStatus("Summon", "Paused: another activity has priority")
        return
    end

    local world = S("Summon.World")
    if world == "Current World" then
        world = Omni.Data.Maps.Current
    end
    if not WORLD_MAPS[world] or world == "Lobby" then
        setStatus("Summon", "No star in " .. tostring(world))
        return
    end
    if not ensureMap(world) then
        setStatus("Summon", "Travelling to " .. world)
        return
    end
    local root = getRoot()
    if not root then return end

    local stars = {}
    for _, star in ipairs((serverFolder("Stars") or workspace):GetChildren()) do
        if star.Name == world then
            stars[#stars + 1] = star
        end
    end
    local star, distance = nearestTo(stars, root.Position)
    if not star then
        setStatus("Summon", "No star loaded in " .. world)
        return
    end
    if distance > 8 then
        teleportTo(CFrame.new(star:GetPivot().Position + Vector3.new(0, 3, 6)))
    end
    if os.clock() >= nextStarRoll then
        local speed = playerStat("StarOpenSpeed", 1)
        nextStarRoll = os.clock() + 3.5 / speed + 0.2
        fire("Stars", "Roll", world, playerStat("MaxStarOpens", 1), nextRequest())
    end
    setStatus("Summon", "Opening " .. world .. " star")
end)

-- Gamemodes: join by schedule and priority, fight, and leave at the chosen wave.
local GAMEMODES = {
    Trial = { toggle = "Trial.AutoTrial", scheduled = true },
    Dungeon = { toggle = "Dungeon.AutoDungeon", scheduled = true },
    Culling = { toggle = "Culling.Enabled", scheduled = false }
}

local function gamemodeName(activity)
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
        if activity == "Culling" then return nil end -- The ported coordinator owns leaving and priority pauses.

        -- Wave checks wait until the run has been going long enough for the HUD to refresh.
        local wave, total = readWave()
        if S(activity .. ".AutoLeave") and wave and os.clock() - gamemodeSince > 10 then
            if activity == "Dungeon" then
                if total and total > 0 and wave >= total then
                    leaveGamemode("all rooms cleared")
                    return 5
                end
            elseif wave >= (tonumber(S(activity .. ".Wave")) or math.huge) then
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
local _combatNote = ""
every("Gamemode Combat", 0.4, function()
    local current = currentGamemode()
    local activity = current and activityOf(current)
    if not activity or activity == "Culling" then
        _combatNote = ""
        return 1
    end
    if not (activityManaged(activity)
        or (activity == "Culling" and S("Culling.TeleportToEnemies"))) then
        return 1
    end
    local root, humanoid = getRoot()
    if not root then return nil end

    -- Other players' runs share the folder; SessionID picks out yours.
    local session = Omni.Data.GamemodeSession
    local hasSession = type(session) == "string" and session ~= ""
    local open, shielded = {}, {}
    for _, enemy in ipairs(findEnemies(serverFolder("Enemies", "Gamemodes"))) do
        if not hasSession or enemy:GetAttribute("SessionID") == session then
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
    if not target or distance <= 8 then return nil end
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
        if type(party) ~= "table" then return false end
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
        cullingLobby = includesYou(currentParty)
        if cullingLobby then state.ownsLobby = true end
        return currentParty
    end
    local function higherPriority()
        if not S("Priority.LeaveForPriority") then return nil end
        for _, other in ipairs({"Dungeon", "Trial"}) do
            if S(GAMEMODES[other].toggle) and priorityRank(other) < priorityRank("Culling") and isOpen(other) then return other end
        end
        if worldBoss.enabled and priorityRank("World Boss") < priorityRank("Culling")
            and (busyBoss == worldBoss or worldBoss.phase == "gamemode" or worldBoss.phase == "queued"
                or worldBoss.phase == "teleporting" or worldBoss.phase == "holding") then return "World Boss" end
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
                state.ownsLobby, cullingLobby = false, false
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

-- Rolls: Haki, Cursed Technique, Talents, Traits and Breathings on the game's cooldowns.
local nextRoll = {}
local function rollReady(name)
    return os.clock() >= (nextRoll[name] or 0)
end

local function rankIndex(rank)
    return table.find(RANKS, rank) or 0
end

every("Rolls", 0.25, function()
    local data = Omni.Data
    for name, key in pairs({ Haki = "Heaven.AutoHaki", ["Cursed Technique"] = "Cursed.AutoCursedTechnique" }) do
        if S(key) and rollReady(name) then
            nextRoll[name] = os.clock() + playerStat("GachaCooldown", 1, name) + 0.1
            fire("Gacha", "Roll", name, nil, nextRequest())
        end
    end

    if S("Lobby.AutoTalents") and rollReady("Talents") then
        local id, fighter = selectedFighter("Lobby.Fighter")
        local talents = fighter and fighter.Talents and fighter.Talents.Current
        if not talents then
            setStatus("Rolls", "Pick a fighter for Talents/Traits")
        else
            local goal = rankIndex(S("Lobby.TalentsStopAt"))
            local done = true
            for _, rank in pairs(talents) do
                if rankIndex(rank) < goal then
                    done = false
                end
            end
            if done then
                allToggles["Lobby.AutoTalents"].set(false)
                notify("Talents reached " .. tostring(S("Lobby.TalentsStopAt")) .. ". Auto Talents stopped.")
            else
                nextRoll.Talents = os.clock() + playerStat("GachaCooldown", 1, "Talents") + 0.1
                fire("Gacha", "Roll", "Talents", id, nextRequest())
                setStatus("Rolls", "Rolling talents")
            end
        end
    end

    if S("Lobby.AutoTraits") and rollReady("Traits") then
        local id, fighter = selectedFighter("Lobby.Fighter")
        local trait = fighter and fighter.Trait and fighter.Trait.Current
        if not fighter then
            setStatus("Rolls", "Pick a fighter for Talents/Traits")
        elseif trait and (trait == S("Lobby.TraitsStopAt")
            or (data.Traits and data.Traits.AutoStop and data.Traits.AutoStop[trait])) then
            allToggles["Lobby.AutoTraits"].set(false)
            notify("Trait " .. tostring(trait) .. " rolled. Auto Traits stopped.")
        else
            nextRoll.Traits = os.clock() + playerStat("TraitsCooldown", 2) + 0.2
            fire("Traits", "Spin", id, nextRequest())
            setStatus("Rolls", "Rolling traits")
        end
    end

    if S("Slayers.AutoBreathings") and rollReady("Breathings") then
        local weaponId = data.Weapons.Equipped
        local weapon = weaponId and data.Weapons.List[weaponId]
        if weapon then
            local stopName, stopRarity = S("Slayers.StopAt"), S("Slayers.Rarity")
            local gameStops = data.Breathings and data.Breathings.AutoStop or {}
            local hit = nil
            for _, entry in pairs(weapon.Breathings and weapon.Breathings.Current or {}) do
                if not entry.Locked then
                    local nameMatches = stopName ~= "--" and entry.Name == stopName
                    local rarityMatches = stopRarity ~= "--" and entry.Rarity == stopRarity
                    local wanted = (stopName ~= "--" or stopRarity ~= "--")
                        and (stopName == "--" or nameMatches) and (stopRarity == "--" or rarityMatches)
                    if wanted or (gameStops[entry.Name] and gameStops[entry.Name][entry.Rarity]) then
                        hit = entry
                    end
                end
            end
            if hit then
                allToggles["Slayers.AutoBreathings"].set(false)
                notify(tostring(hit.Rarity) .. " " .. tostring(hit.Name) .. " rolled. Auto Breathings stopped.")
            else
                nextRoll.Breathings = os.clock() + playerStat("BreathingsCooldown", 2) + 0.2
                fire("Breathings", "Spin", weaponId, nextRequest())
            end
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
    if S("Equipment.AutoEquipBest") then
        fire("Fighters", "EquipBest")
        fire("Weapons", "EquipBest")
    end
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

    -- Named side quests: accept and turn in. The objectives themselves are not automated.
    for key, name in pairs(SIDE_QUESTS) do
        if S(key) then
            fire("Quests", "Collect", "Side", name)
            fire("Quests", "Claim", "Side", name)
            task.wait(0.1)
        end
    end
end)

local loadedAt = os.clock()
local lastIndexCount = {}
local function isClaimed(claimed, index)
    return claimed ~= nil and (claimed[index] or claimed[tostring(index)]) == true
end

-- Checked every 5 seconds so a toggle acts almost as soon as it is switched on. Everything
-- here only sends a request when your save data shows something is waiting.
local lastAchievementClaim = -math.huge
every("Rewards", 5, function()
    local data = Omni.Data
    if S("Rewards.AutoAchievement") and os.clock() - lastAchievementClaim > 60 then
        lastAchievementClaim = os.clock()
        fire("Achievements", "ClaimAll")
    end

    if S("Rewards.AutoInbox") then
        local waiting = 0
        for _, message in pairs(data.Inbox and data.Inbox.List or {}) do
            if not message.Claimed then
                waiting = waiting + 1
            end
        end
        if waiting > 0 then
            logAction("Claim " .. waiting .. " inbox message(s)")
            fire("Inbox", "ClaimAll")
            task.wait(2)
        end
    end

    if S("Rewards.AutoDaily") and data.DailyRewards then
        local day = math.floor((workspace:GetServerTimeNow() - (data.DailyRewards.Start or 0)) / 86400) + 1
        for index = 1, math.clamp(day, 0, 30) do
            if not isClaimed(data.DailyRewards.Claimed, index) then
                fire("DailyRewards", "Claim", index)
                task.wait(0.1)
            end
        end
    end

    if S("Rewards.AutoTime") and data.TimeRewards then
        local played = (data.TimeRewards.TimePlayed or 0) + (os.clock() - loadedAt)
        for index, info in pairs(Omni.Shared.TimeRewards) do
            if type(info) == "table" and type(info.Time) == "number" and played >= info.Time
                and not isClaimed(data.TimeRewards.Claimed, index) then
                fire("TimeRewards", "Claim", index)
                task.wait(0.1)
            end
        end
    end

    if S("Rewards.AutoLevelRewards") then
        for _, reward in pairs(Omni.Shared.PlayerLevel.List.Rewards) do
            if reward.Level <= data.Level.Amount and not data.Level.Rewards["Level" .. reward.Level] then
                fire("PlayerLevel", "ClaimReward", reward.Level)
                task.wait(0.1)
            end
        end
    end

    -- Index milestones are not listed client-side, so each unclaimed count up to what you
    -- have discovered is tried once whenever that count changes.
    if S("Rewards.AutoIndex") then
        for section, dataKey in pairs(INDEX_DATA_KEYS) do
            local discovered = 0
            for _ in pairs(data.Index and data.Index[dataKey] or {}) do
                discovered = discovered + 1
            end
            if lastIndexCount[section] ~= discovered then
                lastIndexCount[section] = discovered
                local claimed = data.IndexRewards and data.IndexRewards[section]
                for amount = 1, discovered do
                    if not isClaimed(claimed, amount) then
                        fire("IndexRewards", "Claim", section, amount)
                        task.wait(0.1)
                    end
                end
            end
        end
    end
end)

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

-- Feed: gives the chosen food in fixed portions and backs off when the game refuses.
local feedRefusals = {}
every("Feed", 3, function()
    if not S("Feed.AutoFeed") then
        setStatus("Feed", "Disabled")
        table.clear(feedRefusals)
        return
    end

    local food = S("Feed.Food")
    local available = Omni.Shared.FighterFeed.GetAvailableAmount(food, Omni.Data) or 0
    if available <= 0 then
        setStatus("Feed", "No " .. tostring(food) .. " left")
        return
    end

    local targets = {}
    if S("Feed.Mode") == "Equipped Fighters" then
        targets = equippedFighterIds()
    else
        targets = { (selectedFighter("Feed.Fighters")) }
    end
    if #targets == 0 then
        setStatus("Feed", "Pick a fighter")
        return
    end

    local portion = math.max(1, math.floor(tonumber(S("Feed.Amount")) or 1000))
    local fed = 0
    for _, id in ipairs(targets) do
        if (feedRefusals[id] or 0) < 3 and available > 0 then
            local amount = math.min(portion, available)
            local ok, result = pcall(invoke, "Fighters", "Feed", id, { [food] = amount })
            if ok and result then
                available = available - amount
                fed = fed + 1
                feedRefusals[id] = 0
            else
                feedRefusals[id] = (feedRefusals[id] or 0) + 1
            end
        end
    end
    setStatus("Feed", fed > 0 and ("Fed " .. fed .. " fighter(s)") or "Nothing to feed (max level?)")
end)

every("Deconstruct", 30, function()
    if not S("Deconstruct.AutoDeconstruct") then
        setStatus("Deconstruct", "Disabled")
        return
    end

    local data = Omni.Data
    local inTeam = {}
    for _, team in pairs(data.Fighters.Teams or {}) do
        for id in pairs(team) do
            inTeam[id] = true
        end
    end

    local selection, count = {}, 0
    for id, fighter in pairs(data.Fighters.List) do
        local starSetting = data.Stars and data.Stars.Settings
            and data.Stars.Settings[tostring(fighter.Name) .. (fighter.Shiny and " Shiny" or "")]
        if starSetting and starSetting.State == "Auto Deconstruct"
            and not fighter.Locked and not data.Fighters.Equipped[id] and not inTeam[id]
            and (fighter.Level or 1) <= 1 then
            selection[id] = true
            count = count + 1
        end
    end
    if count > 0 then
        task.spawn(pcall, invoke, "Fighters", "Deconstruct", selection)
    end
    setStatus("Deconstruct", "Last pass: " .. count .. " fighter(s)")
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
    if env.FarmHubCulling then env.FarmHubCulling.token += 1; env.FarmHubCulling = nil end
    env.FarmHubCullingPlayerSlider = nil
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

selectTab(tabs[1])
for _, callback in ipairs(startup) do
    callback()
end
saveSettings()
