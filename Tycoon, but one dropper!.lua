-- FastHub: Tycoon, but one dropper! Uses the FarmHub menu template.
-- Only start in the supported Roblox place.
if game.PlaceId ~= 109949693269081 then
    local message = "This script only works in Tycoon, but one dropper!."
    warn("[FastHub] " .. message)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "Wrong game", Text = message, Duration = 6
        })
    end)
    return
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local env = getgenv and getgenv() or _G
local previous = env.OneDropperAutoBuy
local saved = previous and {
    factoryObbyEnabled = previous.factoryObbyEnabled ~= false, powerObbyEnabled = previous.powerObbyEnabled ~= false,
    factoryObbyClaims = previous.factoryObbyClaims or 0, powerObbyClaims = previous.powerObbyClaims or 0,
    witchEnabled = previous.witchEnabled ~= false, witchItems = previous.witchItems or {}, witchBought = previous.witchBought or 0,
    crateEnabled = previous.crateEnabled ~= false, cratesCollected = previous.cratesCollected or 0,
    rebirthEnabled = previous.rebirthEnabled ~= false, rebirthsDone = previous.rebirthsDone or 0,
    enabled = previous.enabled, buyEnabled = previous.buyEnabled ~= false,
    candyEnabled = previous.candyEnabled, questsEnabled = previous.questsEnabled,
    achievementsEnabled = previous.achievementsEnabled ~= false, spinEnabled = previous.spinEnabled,
    bought = previous.bought, candyCollected = previous.candyCollected,
    questsClaimed = previous.questsClaimed, spinsUsed = previous.spinsUsed
}
local oldMenu = playerGui:FindFirstChild("OneDropperAutoBuyGui")
local wasMinimized = oldMenu and oldMenu:FindFirstChild("Window") and oldMenu.Window:GetAttribute("Minimized") == true
if previous and previous.Stop then previous.Stop() end
local state = saved or {witchEnabled = true, witchItems = {}, witchBought = 0, crateEnabled = true, cratesCollected = 0, rebirthEnabled = true, rebirthsDone = 0, enabled = true, buyEnabled = true, candyEnabled = true,
    questsEnabled = true, achievementsEnabled = true, spinEnabled = true,
    bought = 0, candyCollected = 0, questsClaimed = 0, spinsUsed = 0}
state.factoryObbyEnabled = state.factoryObbyEnabled ~= false
state.powerObbyEnabled = state.powerObbyEnabled ~= false
state.factoryObbyClaims, state.powerObbyClaims = state.factoryObbyClaims or 0, state.powerObbyClaims or 0
state.obbyStatus = {}
state.alive, state.status = true, "Starting"
env.OneDropperAutoBuy = state
local alive, cleanedUp = true, false
local connections, settings = {}, {}
local remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
local action = remotes:WaitForChild("Action")
local pailData, pailRetry = nil, 0
local rebirthRetry = 0
local crateData, crateRetry = nil, 0
local Halloween = require(game.ReplicatedStorage.Shared.Halloween)
local Gear = require(game.ReplicatedStorage.Shared.Gear)
local HalloweenUI = require(game.ReplicatedStorage.Client.HalloweenUI)
local witchOwned = {}
local function ownedWitchGear()
    for _, value in pairs(getupvalues(HalloweenUI.Init)) do
        if type(value) == "table" and type(value.I) == "table" and type(value.E) == "table" then return value.I end
    end
    return nil
end
local retry = setmetatable({}, {__mode = "k"})
local function formatNumber(value)
    local number = tonumber(value) or 0
    local absolute = math.abs(number)
    if absolute < 1000 then return tostring(math.floor(number)) end
    local suffixes = {"K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc"}
    local tier = math.floor(math.log10(absolute) / 3)
    if tier > #suffixes then return string.format("%.2e", number) end
    local scaled = number / (1000 ^ tier)
    local decimals = math.abs(scaled) >= 100 and 0 or (math.abs(scaled) >= 10 and 1 or 2)
    local rounded = tonumber(string.format("%." .. decimals .. "f", scaled))
    if math.abs(rounded) >= 1000 then
        tier += 1
        scaled /= 1000
        decimals = 2
        if tier > #suffixes then return string.format("%.2e", number) end
    end
    local text = string.format("%." .. decimals .. "f", scaled)
    if decimals > 0 then text = text:gsub("0+$", ""):gsub("%.$", "") end
    return text .. suffixes[tier]
end
state.FormatNumber = formatNumber
local menuKey = {name = "RightShift", capturing = false}
local function connect(signal, callback)
    local c = signal:Connect(callback)
    connections[#connections + 1] = c
    return c
end
local function setSetting(key, value) settings[key] = value end
local function getSetting(key, default)
    if settings[key] == nil then settings[key] = default end
    return settings[key]
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
local TEXT_SIZE = 14

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
    Name = "OneDropperAutoBuyGui",
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
        Text = "FastHub",
        TextColor3 = COLORS.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = FONTS.bold,
        TextSize = 19
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
        TextSize = 12
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
    TextSize = 18
}, titleBar)

local body = new("Frame", {
    Position = UDim2.fromOffset(150, 46),
    Size = UDim2.new(1, -150, 1, -46),
    BackgroundTransparency = 1
}, window)

local miniActivity
-- Minimize preserves running features and the button's screen position.
do
    local minimize = new("TextButton", {
        Name = "Minimize", Position = UDim2.new(1, -42, 0, 9),
        Size = UDim2.fromOffset(32, 28), BackgroundColor3 = COLORS.box,
        BorderSizePixel = 0, Text = "-", TextColor3 = COLORS.text,
        Font = FONTS.bold, TextSize = 21, AutoButtonColor = false, ZIndex = 5
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
            window.Size = UDim2.fromOffset(280, 78)
            titleBar.Position, titleBar.Size = UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 46)
            tabTitle.Text = "FastHub"
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
        if miniActivity then miniActivity.Visible = value end
    end
    state.SetMinimized = setMinimized
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
        TextSize = 15
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
        TextSize = 16
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
            TextSize = 17,
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
        TextSize = size or 13
    }, section)
end

local function addSubHeader(section, text)
    local label = addLabel(section, text, COLORS.accent, nil, 14)
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

    local toggle = {label = text}
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


miniActivity = new("Frame", {
    Name = "MiniActivity", Position = UDim2.fromOffset(0, 42),
    Size = UDim2.fromOffset(280, 30), BackgroundColor3 = COLORS.card, BackgroundTransparency = 1,
    BorderSizePixel = 0, Visible = false
}, window)
round(miniActivity, 8)

local miniStatus = new("TextLabel", {
    Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -20, 1, 0),
    BackgroundTransparency = 1, Text = "", Font = FONT, TextSize = 13,
    TextColor3 = COLORS.text, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center
}, miniActivity)
local main = addTab("Main")
favorites.tab = addTab("Favorites")
favorites.empty = addLabel(addSection(favorites.tab, 1, "Favorites"), "Star a section to keep it here.", COLORS.dim)
local tycoon = addTab("Tycoon")
local halloween = addTab("Halloween")
local rewards = addTab("Rewards")
local obbies = addTab("Obbies")
local options = addTab("Settings")
local section = addSection(main, 1, "Activity")
local activityLabel = addLabel(section, "Starting")
local balanceLabel = addLabel(section, "")
section = addSection(main, 2, "Session Statistics")
local statsLabel = addLabel(section, "")
addButton(section, "Reset Session Statistics", function()
    state.bought, state.candyCollected, state.questsClaimed, state.spinsUsed, state.rebirthsDone, state.cratesCollected, state.witchBought = 0, 0, 0, 0, 0, 0, 0
end)
section = addSection(tycoon, 1, "Upgrades")
addToggle(section, "Auto Buy Tycoon Upgrades", "buyEnabled", state.buyEnabled, function(v) state.buyEnabled = v end)
addLabel(section, "Buys the cheapest affordable upgrade on your plot, then returns you.", COLORS.dim)
section = addSection(tycoon, 1, "Mystery Crates")
addToggle(section, "Auto Collect Mystery Crates", "crateEnabled", state.crateEnabled, function(v) state.crateEnabled = v end)
addLabel(section, "Collects nearby question-mark crates and returns you afterward.", COLORS.dim)
section = addSection(tycoon, 2, "Rebirth")
addToggle(section, "Auto Rebirth", "rebirthEnabled", state.rebirthEnabled, function(v) state.rebirthEnabled = v end)
addLabel(section, "Rebirths as soon as you have enough cash. Auto Buy continues on the new tycoon.", COLORS.dim)
local rebirthLabel = addLabel(section, "")
section = addSection(halloween, 1, "Candy")
addToggle(section, "Auto Collect Candy Pails", "candyEnabled", state.candyEnabled, function(v) state.candyEnabled = v end)
addLabel(section, "Collects your spawned candy pails and returns you afterward.", COLORS.dim)
section = addSection(halloween, 2, "Witch Shop")
addToggle(section, "Auto Buy Witch Shop Items", "witchEnabled", state.witchEnabled, function(v) state.witchEnabled = v end)
addLabel(section, "Buys selected unowned items with candy, cheapest first. Purchases use the game's normal buy action.", COLORS.dim)
for _, product in ipairs(Halloween.Shop) do
    local id = product.Id
    local definition = Gear.ById[id]
    if state.witchItems[id] == nil then state.witchItems[id] = true end
    addToggle(section, (definition and definition.Name or id) .. " · " .. formatNumber(product.Cost) .. " candy",
        "Witch." .. id, state.witchItems[id], function(v) state.witchItems[id] = v end)
end
local witchLabel = addLabel(section, "")
section = addSection(rewards, 1, "Quest Rewards")
addToggle(section, "Auto Claim Daily & Weekly Quests", "questsEnabled", state.questsEnabled, function(v) state.questsEnabled = v end)
addToggle(section, "Auto Claim Achievements", "achievementsEnabled", state.achievementsEnabled, function(v) state.achievementsEnabled = v end)
section = addSection(rewards, 2, "Lucky Wheel")
addToggle(section, "Auto Use Available Spins", "spinEnabled", state.spinEnabled, function(v) state.spinEnabled = v end)
addLabel(section, "Uses free and already available spins when ready.", COLORS.dim)
local wheelLabel = addLabel(section, "")
section = addSection(obbies, 1, "Factory Tower")
addToggle(section, "Auto Factory Tower Reward", "factoryObbyEnabled", state.factoryObbyEnabled, function(v) state.factoryObbyEnabled = v end)
addLabel(section, "20 minutes of cash + 2x cash for 10 minutes. Repeats when the 20-minute cooldown ends.", COLORS.dim)
local factoryObbyLabel = addLabel(section, "")
section = addSection(obbies, 2, "Power Plant")
addToggle(section, "Auto Power Plant Reward", "powerObbyEnabled", state.powerObbyEnabled, function(v) state.powerObbyEnabled = v end)
addLabel(section, "30 minutes of cash + 2x cash for 15 minutes. Repeats when the 30-minute cooldown ends.", COLORS.dim)
local powerObbyLabel = addLabel(section, "")
addLabel(section, "Visits each reward when ready, then returns you to your previous position.", COLORS.dim)
section = addSection(options, 1, "Controls")
addToggle(section, "Run Automation", "enabled", state.enabled, function(v) state.enabled = v end)
menuKey.button = addButton(section, "Menu key: RightShift (click to change)", function()
    menuKey.capturing = true
    menuKey.button.Text = "Press a key (Esc cancels)"
end)
addButton(section, "Stop All Features", function()
    for _, key in ipairs({"factoryObbyEnabled", "powerObbyEnabled", "buyEnabled", "witchEnabled", "crateEnabled", "rebirthEnabled", "candyEnabled", "questsEnabled", "achievementsEnabled", "spinEnabled"}) do
        state[key] = false
        allToggles[key].set(false)
    end
end)
addButton(section, "Unload Hub", function() state.Stop() end)
connect(UserInputService.InputBegan, function(input, processed)
    if UserInputService:GetFocusedTextBox() or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    if menuKey.capturing then
        if input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode ~= Enum.KeyCode.Unknown then menuKey.name = input.KeyCode.Name end
        menuKey.capturing = false
        menuKey.button.Text = "Menu key: " .. menuKey.name .. " (click to change)"
        local hint = gui:FindFirstChild("MenuKeyHint", true)
        if hint then hint.Text = menuKey.name .. ": hide/show" end
    elseif not processed and input.KeyCode.Name == menuKey.name then window.Visible = not window.Visible end
end)
local function render()
    if not state.alive then return end
    miniStatus.Text = state.nextCost and ("Next upgrade: $" .. formatNumber(state.nextCost)) or "Next upgrade: —"
    activityLabel.Text = (state.enabled and state.status or "Paused") .. "\n" .. (state.rewardStatus or "Watching for rewards")
    balanceLabel.Text = "Cash: $" .. formatNumber(player:GetAttribute("Cash"))
        .. "\nCandy: " .. formatNumber(player:GetAttribute("Candy"))
    statsLabel.Text = "Upgrades bought: " .. formatNumber(state.bought) .. "\nPail candy collected: " .. formatNumber(state.candyCollected)
        .. "\nQuest / achievement claims: " .. formatNumber(state.questsClaimed) .. "\nSpins used: " .. formatNumber(state.spinsUsed)
        .. "\nMystery crates: " .. formatNumber(state.cratesCollected)
    witchLabel.Text = (state.witchStatus or "Waiting for candy") .. "\nItems bought: " .. formatNumber(state.witchBought)
    rebirthLabel.Text = "Current rebirths: " .. formatNumber(player:GetAttribute("Rebirths"))
        .. "\nCash: $" .. formatNumber(player:GetAttribute("Cash"))
        .. " / $" .. formatNumber(player:GetAttribute("RebirthCost"))
        .. "\nRebirths this session: " .. formatNumber(state.rebirthsDone)
    local function obbyText(attribute, key, count)
        local seconds = math.max(0, math.ceil((player:GetAttribute(attribute) or 0) - workspace:GetServerTimeNow()))
        return (seconds > 0 and string.format("Next reward: %d:%02d", seconds // 60, seconds % 60) or "Reward ready")
            .. "\n" .. (state.obbyStatus[key] or "Waiting") .. "\nRewards claimed: " .. formatNumber(count)
    end
    factoryObbyLabel.Text = obbyText("ObbyNext", "factory", state.factoryObbyClaims)
    powerObbyLabel.Text = obbyText("PowerNext", "power", state.powerObbyClaims)
    local remaining = math.max(0, (player:GetAttribute("WheelNext") or 0) - math.floor(workspace:GetServerTimeNow()))
    wheelLabel.Text = "Available spins: " .. formatNumber(player:GetAttribute("WheelSpins"))
        .. "\nNext free spin: " .. (remaining == 0 and "Ready" or string.format("%d:%02d", remaining // 60, remaining % 60))
end
local function restore()
    if state.root and state.root.Parent and state.origin then
        state.root.CFrame = state.origin
        state.root.AssemblyLinearVelocity = Vector3.zero
    end
    state.root, state.origin = nil, nil
end

function state.Stop()
    if not state.alive then return end
    state.alive, state.enabled, alive, cleanedUp = false, false, false, true
    for _, c in ipairs(connections) do c:Disconnect() end
    for _, thread in ipairs({state.thread, state.rewardThread}) do if thread then pcall(task.cancel, thread) end end
    restore()
    gui:Destroy()
    if env.OneDropperAutoBuy == state then env.OneDropperAutoBuy = nil end
end
connections[#connections + 1] = remotes.Net.OnClientEvent:Connect(function(kind, data)
    if kind == "Crate" and type(data) == "table" then crateData = data;crateRetry = 0 end
    if kind == "CrateGone" and type(data) == "table" then
        if data.Got then
            state.cratesCollected += 1
            state.rewardStatus = "Mystery crate collected"
            print("AUTO_MYSTERY_CRATE_CONFIRMED", data.Id)
        end
        if not crateData or not data.Id or crateData.Id == data.Id then crateData = nil end
        render()
    end
    if kind == "Pail" and type(data) == "table" then pailData = data;pailRetry = 0 end
    if kind == "PailGone" and type(data) == "table" then
        if data.Got and type(data.Got) == "number" then
            state.candyCollected += data.Got
            state.rewardStatus = "Collected +" .. formatNumber(data.Got) .. " candy"
            print("AUTO_CANDY_CONFIRMED", data.Got)
        end
        if not pailData or not data.Id or pailData.Id == data.Id then pailData = nil end
        render()
    end
end)
local obbyRetry = {}
local obbyDefinitions = {
    {id="factory", name="Factory Tower", enabled="factoryObbyEnabled", attribute="ObbyNext",
        model="Obby", dropper="GoldenDropper", counter="factoryObbyClaims"},
    {id="power", name="Power Plant", enabled="powerObbyEnabled", attribute="PowerNext",
        model="PowerPlant", dropper="DiamondDropper", counter="powerObbyClaims"}
}
local function collectObby(root)
    for _,definition in ipairs(obbyDefinitions) do
        local now = workspace:GetServerTimeNow()
        if not state[definition.enabled] then
            state.obbyStatus[definition.id] = "Disabled"
        elseif (player:GetAttribute(definition.attribute) or 0) > now then
            state.obbyStatus[definition.id] = "Waiting for cooldown"
        elseif os.clock() >= (obbyRetry[definition.id] or 0) then
            local world = workspace:FindFirstChild("World")
            local model = world and world:FindFirstChild(definition.model)
            local dropper = model and model:FindFirstChild(definition.dropper)
            local target = dropper and dropper:FindFirstChild("Reward")
            if not target or not target:IsA("BasePart") then
                state.obbyStatus[definition.id] = "Waiting for reward area"
            else
                obbyRetry[definition.id] = os.clock() + 15
                state.status = "Collecting " .. definition.name .. " reward"
                state.obbyStatus[definition.id] = "Collecting reward"
                state.root, state.origin = root, root.CFrame
                local before = player:GetAttribute(definition.attribute) or 0
                root.CFrame = target.CFrame * CFrame.new(0, 2, 0)
                root.AssemblyLinearVelocity = Vector3.zero
                if type(firetouchinterest) == "function" then
                    firetouchinterest(root, target, 0)
                    task.wait(.15)
                    if root.Parent and target.Parent then firetouchinterest(root, target, 1) end
                end
                local deadline = os.clock() + 2
                repeat task.wait(.1) until not state.alive or not state.enabled or not state[definition.enabled]
                    or not root.Parent or (player:GetAttribute(definition.attribute) or 0) > before or os.clock() >= deadline
                if (player:GetAttribute(definition.attribute) or 0) > before then
                    state[definition.counter] += 1
                    state.obbyStatus[definition.id] = "Reward collected"
                    print("FASTHUB_OBBY_REWARD_CONFIRMED", definition.name, player:GetAttribute(definition.attribute))
                else
                    state.obbyStatus[definition.id] = "Reward pending; retrying shortly"
                end
                restore()
                return true
            end
        end
    end
    return false
end

local function collectPail(root)
    if not state.candyEnabled or workspace:GetAttribute("HalloweenOn") ~= true or os.clock() < pailRetry then return false end
    local model = workspace:FindFirstChild("CandyPail")
    if not model then return false end
    local position = pailData and pailData.Pos
    if typeof(position) ~= "Vector3" then
        local smallest
        for _, part in ipairs(model:GetChildren()) do
            if part:IsA("BasePart") and (not smallest or part.Size.Magnitude < smallest.Size.Magnitude) then smallest = part end
        end
        if not smallest then return false end
        position = smallest.Position
    end
    pailRetry = os.clock() + 10
    state.status = "Collecting Halloween candy"
    state.root, state.origin = root, root.CFrame
    render()
    root.CFrame = CFrame.new(position + Vector3.new(0, 2, 0))
    root.AssemblyLinearVelocity = Vector3.zero
    local deadline = os.clock() + 6
    repeat task.wait(0.15) until not state.alive or not state.enabled or not state.candyEnabled
        or not model.Parent or os.clock() >= deadline
    restore()
    return true
end
local function collectCrate(root)
    if not state.crateEnabled or os.clock() < crateRetry then return false end
    local model = workspace:FindFirstChild("MysteryCrate")
    if not model then return false end
    local position = crateData and crateData.Pos
    if typeof(position) ~= "Vector3" then
        for _, part in ipairs(model:GetChildren()) do
            if part:IsA("BasePart") and part:FindFirstChildOfClass("BillboardGui") then position = part.Position;break end
        end
    end
    if typeof(position) ~= "Vector3" then return false end
    crateRetry = os.clock() + 10
    state.status = "Collecting mystery crate"
    state.root, state.origin = root, root.CFrame
    render()
    root.CFrame = CFrame.new(position + Vector3.new(0, 2, 0))
    root.AssemblyLinearVelocity = Vector3.zero
    local deadline = os.clock() + 6
    repeat task.wait(0.15) until not state.alive or not state.enabled or not state.crateEnabled
        or not model.Parent or os.clock() >= deadline
    restore()
    return true
end
state.rewardThread = task.spawn(function()
    while state.alive do
        local ok, failure = pcall(function()
            if not state.enabled or player:GetAttribute("Loaded") ~= true then return end
            if state.witchEnabled and workspace:GetAttribute("HalloweenOn") == true then
                local inventory = ownedWitchGear()
                if inventory then
                    local candidates = {}
                    for _, product in ipairs(Halloween.Shop) do
                        if state.witchItems[product.Id] and inventory[product.Id] == nil and not witchOwned[product.Id] then
                            candidates[#candidates + 1] = product
                        end
                    end
                    table.sort(candidates, function(a, b) return a.Cost < b.Cost end)
                    local selected = candidates[1]
                    if not selected then state.witchStatus = "Selected shop items owned"
                    elseif (player:GetAttribute("Candy") or 0) < selected.Cost then
                        state.witchStatus = "Next item: " .. (Gear.ById[selected.Id].Name or selected.Id)
                            .. " · " .. formatNumber(selected.Cost) .. " candy"
                    else
                        local result = action:InvokeServer("HalloweenBuy", selected.Id)
                        if result and result.ok then
                            witchOwned[selected.Id] = true
                            state.witchBought += 1
                            state.witchStatus = "Bought " .. (Gear.ById[selected.Id].Name or selected.Id)
                            state.rewardStatus = state.witchStatus
                            print("AUTO_WITCH_BUY_CONFIRMED", selected.Id)
                        else state.witchStatus = result and result.msg or "Shop purchase pending" end
                        task.wait(1)
                    end
                else state.witchStatus = "Waiting for gear inventory" end
            end
            if state.spinEnabled and ((player:GetAttribute("WheelSpins") or 0) > 0
                or (player:GetAttribute("WheelNext") or 0) <= math.floor(workspace:GetServerTimeNow())) then
                local result = action:InvokeServer("Spin")
                if result and result.ok then
                    state.spinsUsed += 1
                    state.rewardStatus = "Free wheel spin claimed"
                    print("AUTO_WHEEL_CONFIRMED", game:GetService("HttpService"):JSONEncode(result))
                else state.rewardStatus = result and result.msg or "Wheel not ready" end
                task.wait(1)
            end
            if (state.questsEnabled or state.achievementsEnabled) and state.enabled then
                local view = action:InvokeServer("Quests")
                if view and view.ok then
                    for _, group in ipairs({"Daily", "Weekly", "Ach"}) do
                        for _, quest in ipairs(view[group] or {}) do
                            if not state.alive or not state.enabled then return end
                            if ((group == "Ach" and state.achievementsEnabled) or (group ~= "Ach" and state.questsEnabled))
                                and not quest.Claimed and type(quest.Prog) == "number" and type(quest.Goal) == "number"
                                and quest.Prog >= quest.Goal then
                                task.wait(0.5)
                                local result = action:InvokeServer("ClaimQuest", group, quest.Key)
                                if result and result.ok then
                                    state.questsClaimed += 1
                                    state.rewardStatus = "Claimed " .. (quest.Text or quest.Key)
                                    print("AUTO_QUEST_CONFIRMED", group, quest.Key)
                                else state.rewardStatus = result and result.msg or "Quest claim pending" end
                                render()
                            end
                        end
                    end
                end
            end
        end)
        if not ok then state.rewardStatus = "Rewards retry: " .. tostring(failure) end
        render()
        task.wait(8)
    end
end)
state.thread = task.spawn(function()
    while state.alive do
        if state.enabled then
            local ok, failure = pcall(function()
                local folder = workspace:FindFirstChild("Tycoons")
                local id = player:GetAttribute("PlotId")
                local plot = id and folder and folder:FindFirstChild("Plot" .. tostring(id))
                local pads = plot and plot:FindFirstChild("Pads")
                if not plot or plot:GetAttribute("OwnerId") ~= player.UserId or not pads then
                    state.status = "Waiting for your tycoon"; return
                end
                local character = player.Character
                local root = character and character:FindFirstChild("HumanoidRootPart")
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                if not root or not humanoid or humanoid.Health <= 0 then state.status = "Waiting for character"; return end
                if collectObby(root) then return end
                if collectCrate(root) then return end
                if collectPail(root) then return end
                local rebirthCost = player:GetAttribute("RebirthCost")
                if state.rebirthEnabled and type(rebirthCost) == "number" and rebirthCost > 0
                    and (player:GetAttribute("Cash") or 0) >= rebirthCost and os.clock() >= rebirthRetry then
                    rebirthRetry = os.clock() + 3
                    state.status = "Rebirthing"
                    render()
                    local before = player:GetAttribute("Rebirths") or 0
                    local result = action:InvokeServer("Rebirth")
                    if result and result.ok then
                        local deadline = os.clock() + 2
                        repeat task.wait(0.1) until not state.alive or (player:GetAttribute("Rebirths") or 0) > before or os.clock() >= deadline
                        state.rebirthsDone += 1
                        state.status = "Rebirth complete"
                        print("AUTO_REBIRTH_CONFIRMED", before, player:GetAttribute("Rebirths"))
                        table.clear(retry)
                    else state.status = result and result.msg or "Rebirth pending" end
                    return
                end
                if not state.buyEnabled then state.status = "Auto Buy disabled"; return end
                local cash = player:GetAttribute("Cash") or 0
                local selected, cheapest = nil, math.huge
                for _, pad in ipairs(pads:GetChildren()) do
                    local item, price = pad:GetAttribute("Item"), pad:GetAttribute("Price")
                    if pad:IsA("BasePart") and type(item) == "string"
                        and item ~= "Group" and type(price) == "number" and price >= 0
                        and (pad:GetAttribute("BuildT") or 0) <= workspace:GetServerTimeNow() then
                        cheapest = math.min(cheapest, price)
                        if price <= cash and (retry[pad] or 0) <= os.clock()
                            and (not selected or price < selected:GetAttribute("Price")) then selected = pad end
                    end
                end
                state.nextCost = cheapest < math.huge and cheapest or nil
                if not selected then
                    state.status = cheapest < math.huge and ("Waiting for cash · next $" .. formatNumber(cheapest))
                        or "All available upgrades purchased"
                    return
                end
                local item = selected:GetAttribute("Item")
                local owned = player:GetAttribute("Owned") or 0
                retry[selected] = os.clock() + 4
                state.status = "Buying " .. item
                render()
                state.root, state.origin = root, root.CFrame
                root.CFrame = selected.CFrame * CFrame.new(0, selected.Size.Y / 2 + humanoid.HipHeight + root.Size.Y / 2 + 0.15, 0)
                root.AssemblyLinearVelocity = Vector3.zero
                if type(firetouchinterest) == "function" then
                    firetouchinterest(root, selected, 0)
                    task.wait(0.15)
                    if selected.Parent then firetouchinterest(root, selected, 1) end
                end
                local deadline = os.clock() + 1.5
                repeat task.wait(0.1) until not state.alive or not state.enabled
                    or selected.Parent ~= pads or (player:GetAttribute("Owned") or 0) > owned
                    or os.clock() >= deadline
                if selected.Parent ~= pads or (player:GetAttribute("Owned") or 0) > owned then
                    state.bought += 1
                    state.status = "Bought " .. item
                    print("TYCOON_AUTO_BUY_CONFIRMED", item, state.bought)
                else state.status = "Purchase pending · retrying shortly" end
                restore()
            end)
            if not ok then restore();state.status = "Retrying: " .. tostring(failure) end
        end
        render()
        task.wait(0.5)
    end
end)
render()

selectTab(main)
if wasMinimized then state.SetMinimized(true) end
print("TYCOON_FARMHUB_MENU_STARTED")







