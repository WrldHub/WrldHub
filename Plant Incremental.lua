-- FastHub: Plant Incremental collection and seed evolution.
if game.PlaceId~=78440417139286 then
    pcall(function()game:GetService("StarterGui"):SetCore("SendNotification",{Title="FastHub",Text="FastHub doesn't exist for this game.",Duration=6})end)
    return
end
local Players=game:GetService("Players")
local UserInputService=game:GetService("UserInputService")
local player=Players.LocalPlayer
local playerGui=player:WaitForChild("PlayerGui")
local env=getgenv and getgenv()or _G
local previous=env.FastHubPlantIncremental
local saved=previous and table.clone(previous.settings)
local old=previous and previous.gui or playerGui:FindFirstChild("FastHubPlantIncrementalGui")
local wasMinimized=old and old:FindFirstChild("Window")and old.Window:GetAttribute("Minimized")==true
if previous and previous.Stop then previous.Stop()end
local state={alive=true,settings=saved or {},activity="Starting",seedStatus="Waiting",threads={},evolved=0}
env.FastHubPlantIncremental=state
local settings=state.settings
local alive,cleanedUp=true,false
local connections={}
local function connect(signal,callback)
    local c=signal:Connect(callback);connections[#connections+1]=c;return c
end
local function setSetting(key,value)settings[key]=value end
local function getSetting(key,default)if settings[key]==nil then settings[key]=default end;return settings[key]end
local menuKey={name=getSetting("MenuKey","RightShift"),capturing=false}
local data=game.ReplicatedStorage.Data:WaitForChild(player.Name)
local stats=data:WaitForChild("Stats")
local other=data:WaitForChild("Other")
local upgradeDefs=require(game.ReplicatedStorage.Modules.Shared.Upgrades)
local treeDefs=require(game.ReplicatedStorage.Modules.Shared.UpgradeTree)
local paperBoostDefs=require(game.ReplicatedStorage.Modules.Shared.ResearchBoosts)
local researchUpgradeDefs=require(game.ReplicatedStorage.Modules.Shared.ResearchUpgrades)
local researchDefs=require(game.ReplicatedStorage.Modules.Shared.Research)
local petDefs=require(game.ReplicatedStorage.Modules.Shared.Pets)
local soilPending=true
local physicalTree=require(game.ReplicatedStorage.Modules.Shared.Tree)
local seeds=require(game.ReplicatedStorage.Modules.Shared.Seeds).Seeds
local big=require(game.ReplicatedStorage.Modules.Shared.BigNum)
local fw=require(game.ReplicatedStorage.Framework)
local function stat(folder,name,default)local value=folder:FindFirstChild(name);return value and value.Value or default end
local collectedAtStart=stat(other,"Collects",0)
local function getRoot()
    local c=player.Character;local humanoid=c and c:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health>0 then return c:FindFirstChild("HumanoidRootPart")end
end
local function restore()
    if state.root and state.root.Parent and state.origin then state.root.CFrame=state.origin;state.root.AssemblyLinearVelocity=Vector3.zero end
    state.root,state.origin=nil,nil
end
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

local function hover()end

local gui = new("ScreenGui", {
    Name = "FastHubPlantIncrementalGui",
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

state.gui=gui
local main=addTab("Main")
favorites.tab=addTab("Favorites")
favorites.empty=addLabel(addSection(favorites.tab,1,"Favorites"),"Star a section to keep it here.",COLORS.dim)
local collecting=addTab("Farming")
local seedTab=addTab("Seed")
local upgradesTab=addTab("Upgrades")
local treeTab=addTab("Tree")
local grassTab=addTab("Grass")
local researchTab=addTab("Research")
local options=addTab("Settings")
local section=addSection(main,1,"Activity")
local activityLabel=addLabel(section,"Starting")
local cashLabel=addLabel(section,"")
section=addSection(main,2,"Session Statistics")
local sessionLabel=addLabel(section,"")
section=addSection(collecting,1,"Collection")
addToggle(section,"Auto Collect Plants","AutoCollect",true,function()end)
addToggle(section,"Return after collecting","ReturnAfterCollect",false,function()end)
addLabel(section,"Collects nearby spawned plants using the game's normal pickup detection.",COLORS.dim)
section=addSection(seedTab,1,"Seed Evolution")
addToggle(section,"Auto Evolve Seed","AutoEvolve",true,function()end)
addLabel(section,"Buys required seed levels and evolves when affordable. Uses the game's seed upgrade action.",COLORS.dim)
local seedLabel=addLabel(section,"")
section=addSection(treeTab,1,"Tree Zone")
addToggle(section,"Auto Click Tree Multiplier","AutoTreeCombo",true,function()end)
addLabel(section,"Builds and maintains the tree multiplier while you stand inside the tree zone. Plant farming pauses there.",COLORS.dim)
local treeComboLabel=addLabel(section,"")
section=addSection(treeTab,2,"Tree Levels")
addToggle(section,"Auto Upgrade Tree Levels","AutoTreeLevels",true,function()end)
addLabel(section,"Visits the tree upgrade ring when you have enough Water, then returns you.",COLORS.dim)
local treeLevelLabel=addLabel(section,"")
section=addSection(treeTab,1,"Wood Upgrades")
addToggle(section,"Auto Wood Upgrades","AutoWoodUpgrade",true,function()end)
addLabel(section,"Buys affordable, unlocked Wood upgrades using Wood. Stops each upgrade at its cap.",COLORS.dim)
local woodLabel=addLabel(section,"")
section=addSection(upgradesTab,1,"Soil")
addToggle(section,"Auto Convert Cash to Soil","AutoSoilConvert",true,function(value)if value then soilPending=true end end)
addToggle(section,"Prioritize Seed Evolution","SeedPriority",true,function()end)
addLabel(section,"With seed priority on, soil converts once, then after each seed evolution. This leaves time to save cash for the next seed.",COLORS.dim)
addToggle(section,"Auto Buy Soil Upgrades","AutoSoilUpgrade",true,function()end)
local soilLabel=addLabel(section,"")
section=addSection(upgradesTab,2,"Upgrade Tree")
addToggle(section,"Auto Buy Upgrade Tree Nodes","AutoTreeUpgrade",true,function()end)
addLabel(section,"Buys affordable unlocked nodes, one level at a time.",COLORS.dim)
local treeLabel=addLabel(section,"")
section=addSection(upgradesTab,2,"Water")
addToggle(section,"Auto Water Clicker","AutoWaterClick",true,function()end)
addToggle(section,"Auto Buy Water Upgrades","AutoWaterUpgrade",true,function()end)
local waterLabel=addLabel(section,"")
section=addSection(grassTab,1,"Grass Pet")
addToggle(section,"Auto Grass Pet Clicker","AutoGrassClick",true,function()end)
addLabel(section,"Automatically collects Grass from your pet.",COLORS.dim)
local grassClickLabel=addLabel(section,"")
addToggle(section,"Auto Pet Evolve","AutoPetEvolve",true,function()end)
addLabel(section,"Buys required pet levels and evolves when affordable.",COLORS.dim)
local petEvolveLabel=addLabel(section,"")
section=addSection(grassTab,2,"Grass Upgrades")
addToggle(section,"Auto Grass Upgrades","AutoGrassUpgrade",true,function()end)
addLabel(section,"Buys affordable, unlocked Grass upgrades up to their caps.",COLORS.dim)
local grassUpgradeLabel=addLabel(section,"")
section=addSection(researchTab,1,"Paper Boosts")
addToggle(section,"Auto Buy Paper Boosts","AutoPaperBoosts",true,function()end)
local paperBoostLabel=addLabel(section,"")
section=addSection(researchTab,2,"Research Upgrades")
addToggle(section,"Auto Research Upgrades","AutoResearchUpgrades",true,function()end)
local researchUpgradeLabel=addLabel(section,"")
section=addSection(researchTab,1,"Research Level")
addToggle(section,"Auto Upgrade Research Level","AutoResearchLevel",true,function()end)
local researchLevelLabel=addLabel(section,"")
section=addSection(options,1,"Controls")
addToggle(section,"Run Automation","Enabled",true,function(value)if not value then restore()end end)
menuKey.button=addButton(section,"Menu key: "..menuKey.name.." (click to change)",function()
    menuKey.capturing=true;menuKey.button.Text="Press a key (Esc cancels)"
end)
addButton(section,"Stop All Features",function()
    for _,key in ipairs({"AutoCollect","AutoEvolve","AutoSoilConvert","AutoSoilUpgrade","AutoTreeUpgrade","AutoWaterClick","AutoWaterUpgrade","AutoTreeCombo","AutoTreeLevels","AutoWoodUpgrade","AutoGrassClick","AutoGrassUpgrade","AutoPetEvolve","AutoPaperBoosts","AutoResearchUpgrades","AutoResearchLevel"})do allToggles[key].set(false)end
    restore()
end)
addButton(section,"Unload FastHub",function()state.Stop()end)
connect(UserInputService.InputBegan,function(input,processed)
    if UserInputService:GetFocusedTextBox()or input.UserInputType~=Enum.UserInputType.Keyboard then return end
    if menuKey.capturing then
        if input.KeyCode~=Enum.KeyCode.Escape and input.KeyCode~=Enum.KeyCode.Unknown then menuKey.name=input.KeyCode.Name;settings.MenuKey=menuKey.name end
        menuKey.capturing=false
        menuKey.button.Text="Menu key: "..menuKey.name.." (click to change)"
        local hint=gui:FindFirstChild("MenuKeyHint",true);if hint then hint.Text=menuKey.name..": hide/show"end
    elseif not processed and input.KeyCode.Name==menuKey.name then window.Visible=not window.Visible end
end)

local function cashText(value)
    local ok,result=pcall(big.toSuffix,value)
    return ok and tostring(result)or formatNumber(value)
end
local function nextSeedPrice()
    local index=stat(stats,"Seed",1)
    local level=stat(stats,"SeedLevel",0)
    local config=seeds[index]
    if not config then return nil,nil,index end
    local noLevels=player:GetAttribute("AB_NoPlantLevels")==true
    if noLevels or level>=(config.Levels or 0)then return config.EvolvePrice,config,index end
    local ok,price=pcall(config.Price,level)
    return ok and price or nil,config,index
end
local function render()
    if not state.alive then return end
    local active=settings.Enabled and state.activity or "Paused"
    activityLabel.Text=active
    cashLabel.Text="Cash: $"..cashText(stat(stats,"Cash","0")).."\nSoil: "..cashText(stat(stats,"Soil","0")).." · Water: "..cashText(stat(stats,"Water","0"))
    sessionLabel.Text="Plants collected: "..formatNumber(math.max(0,stat(other,"Collects",0)-collectedAtStart))
        .."\nSeed evolutions: "..formatNumber(state.evolved)
    local price,config,index=nextSeedPrice()
    seedLabel.Text="Current seed: "..(config and config.Seed or tostring(index))
        .."\n"..state.seedStatus
        ..(price and ("\nNext step: $"..cashText(price))or "\nMaximum seed reached")
    soilLabel.Text=state.soilStatus or "Waiting"
    treeLabel.Text=state.treeStatus or "Waiting for affordable nodes"
    waterLabel.Text=state.waterStatus or "Waiting for Water unlock"
    treeComboLabel.Text="Multiplier: x"..tostring(stat(data.TempValues,"TreeComboMultiplier",1))
        .."\n"..(stat(data.TempValues,"AttackingTree",false)and "Inside tree zone"or "Waiting for tree zone")
    local treeCost=physicalTree.Pricing(data)
    treeLevelLabel.Text="Tree level: "..stat(stats,"TreeLevel",0).." / "..physicalTree.Max
        .."\nWater needed: "..cashText(big.max(0,big.sub(treeCost,stat(data.Tree,"WaterDeposited","0"))))
        .."\n"..(state.treeLevelStatus or "Waiting for enough Water")
    woodLabel.Text="Wood: "..cashText(stat(stats,"Wood","0")).."\n"..(state.woodStatus or "Waiting for Wood upgrades")
    grassClickLabel.Text="Grass: "..cashText(stat(stats,"Grass","0")).."\n"..(state.grassClickStatus or "Waiting for pet")
    grassUpgradeLabel.Text=state.grassUpgradeStatus or "Waiting for affordable Grass upgrades"
    paperBoostLabel.Text="Paper: "..cashText(stat(stats,"Paper","0")).."\n"..(state.paperBoostStatus or "Waiting")
    researchUpgradeLabel.Text=state.researchUpgradeStatus or "Waiting for research unlocks"
    researchLevelLabel.Text="Research level: "..stat(stats,"ResearchLevel",0).." / "..researchDefs.Max.."\n"..(state.researchLevelStatus or "Waiting")
    local pet=petDefs[stat(stats,"Pet",0)]
    petEvolveLabel.Text="Pet: "..(pet and pet.Name or "Unknown").."\n"..(state.petEvolveStatus or "Waiting")
    miniStatus.Text=active
end
function state.Stop()
    if not state.alive then return end
    state.alive,alive,cleanedUp=false,false,true
    for _,thread in ipairs(state.threads)do if thread~=coroutine.running()then pcall(task.cancel,thread)end end
    for _,c in ipairs(connections)do c:Disconnect()end
    restore()
    if state.treeRoot and state.treeRoot.Parent and state.treeOrigin then state.treeRoot.CFrame=state.treeOrigin end
    gui:Destroy()
    if env.FastHubPlantIncremental==state then env.FastHubPlantIncremental=nil end
end
local previousSeed=stat(stats,"Seed",1)
connect(stats.Seed.Changed,function(value)
    if value>previousSeed then soilPending=true;state.evolved+=value-previousSeed;print("FASTHUB_SEED_EVOLVED",previousSeed,value)end
    previousSeed=value
end)
local retry=setmetatable({},{__mode="k"})
state.threads[#state.threads+1]=task.spawn(function()
    while state.alive do
        local ok,failure=pcall(function()
            if not settings.Enabled then return end
            if state.treeUpgradeBusy then state.activity="Upgrading tree level";return end
            if settings.AutoTreeCombo and stat(data.TempValues,"AttackingTree",false)then
                state.activity="Tree zone: maintaining multiplier";return
            end
            if not settings.AutoCollect then state.activity="Collection disabled";return end
            local root=getRoot()
            if not root then state.activity="Waiting for character";return end
            local map=workspace:FindFirstChild("MapEssentials")
            local folder=map and map:FindFirstChild("Spawned")
            local chosen,dist=nil,math.huge
            if folder then for _,plant in ipairs(folder:GetChildren())do
                if plant:IsA("BasePart")and not plant:GetAttribute("PickedUp")and (retry[plant]or 0)<=os.clock()then
                    local distance=(plant.Position-root.Position).Magnitude
                    if distance<dist then chosen,dist=plant,distance end
                end
            end end
            if not chosen then state.activity="Waiting for plants";return end
            state.activity="Collecting plants"
            retry[chosen]=os.clock()+2
            state.root,state.origin=root,root.CFrame
            root.CFrame=CFrame.new(chosen.Position+Vector3.new(0,3,0));root.AssemblyLinearVelocity=Vector3.zero
            local untilTime=os.clock()+.6
            repeat task.wait(.08)until not state.alive or not settings.Enabled or not settings.AutoCollect
                or not chosen.Parent or chosen:GetAttribute("PickedUp")or os.clock()>=untilTime
            if settings.ReturnAfterCollect or not settings.Enabled then restore()
            else state.root,state.origin=nil,nil end
        end)
        if not ok then restore();state.activity="Retrying: "..tostring(failure)end
        task.wait(.15)
    end
end)
local lastUpgrade=0
state.threads[#state.threads+1]=task.spawn(function()
    while state.alive do
        local ok,failure=pcall(function()
            local price=nextSeedPrice()
            if settings.Enabled and settings.AutoEvolve and price then
                local good,afford=pcall(big.gte,stat(stats,"Cash","0"),price)
                if good and afford and os.clock()-lastUpgrade>=1 then
                    lastUpgrade=os.clock()
                    fw.Network.Fire("UpgradeSeed")
                    state.seedStatus="Upgrading seed"
                else state.seedStatus="Waiting for enough cash"end
            else state.seedStatus=settings.AutoEvolve and "Maximum seed reached"or "Auto evolution disabled"end
            render()
        end)
        if not ok then state.seedStatus="Retrying: "..tostring(failure);pcall(render)end
        task.wait(.25)
    end
end)

local function afford(currency,price)
    local ok,value=pcall(big.gte,stat(stats,currency,"0"),price)
    return ok and value
end
local function callDefinition(fn,arg,default)
    if type(fn)~="function"then return default end
    local ok,value=pcall(fn,arg)
    return ok and value or default
end
local function buyResearchShop(definitions,folderName,remote)
    local folder=data:FindFirstChild(folderName)
    if not folder then return end
    local selected
    for key,definition in pairs(definitions)do
        local value=folder:FindFirstChild(key)
        if value and callDefinition(definition.Unlocked,data,false)
            and value.Value<callDefinition(definition.Cap,data,0)then
            local price=callDefinition(definition.Price,player,nil)
            if price and afford(definition.Currency,price)
                and(not selected or big.lt(price,selected.price))then
                selected={key=key,price=price,display=definition.Display}
            end
        end
    end
    if selected then
        fw.Network.Fire(remote,selected.key,false)
        return (selected.display or selected.key):gsub("<[^>]+>","")
    end
end
local function upgradeCurrency(category)
    local group=upgradeDefs[category]
    local folder=data:FindFirstChild(category.."Upgrades")
    if not group or not folder then return end
    local selected
    for key,definition in pairs(group.Upgrades)do
        local value=folder:FindFirstChild(key)
        local level=value and value.Value or 0
        local unlocked=callDefinition(definition.Unlocked,data,false)
        local cap=callDefinition(definition.Cap,data,0)
        if unlocked and level<cap then
            local info=callDefinition(definition.Info,level,nil)
            if info and info.Price and afford(group.Currency,info.Price)then
                if not selected or big.lt(info.Price,selected.price)then selected={key=key,price=info.Price}end
            end
        end
    end
    if selected then fw.Network.Fire("Upgrade",category,selected.key,false)end
    return selected and selected.key
end
local function upgradeTreeStep()
    local selected
    for key,definition in pairs(treeDefs)do
        local value=data.UpgradeTree:FindFirstChild(key)
        local level=value and value.Value or 0
        if value and callDefinition(definition.Unlocked,data,false)and level<callDefinition(definition.Cap,data,0)then
            local price=callDefinition(definition.Price,player,nil)
            if price and afford(definition.Currency,price)then
                if not selected or big.lt(price,selected.price)then selected={key=key,price=price}end
            end
        end
    end
    if selected then fw.Network.Fire("TreeUpgrade",selected.key,false);state.treeStatus="Buying "..selected.key
    else state.treeStatus="Waiting for affordable unlocked nodes"end
end
state.threads[#state.threads+1]=task.spawn(function()
    while state.alive do
        local ok,failure=pcall(function()
            if not settings.Enabled then return end
            local seedPrice=nextSeedPrice()
            if settings.AutoEvolve and seedPrice and afford("Cash",seedPrice)then return end
            if settings.AutoSoilUpgrade then
                local name=upgradeCurrency("Soil")
                state.soilStatus=name and ("Buying "..name)or "Soil upgrades waiting for currency"
            end
            if settings.AutoTreeUpgrade then upgradeTreeStep()end
            if settings.AutoWaterUpgrade then
                local name=upgradeCurrency("Water")
                state.waterStatus=name and ("Buying "..name)or "Water upgrades waiting for currency"
            end
            if settings.AutoWoodUpgrade then
                local name=upgradeCurrency("Wood")
                state.woodStatus=name and ("Buying "..name)or "Waiting for affordable, unlocked Wood upgrades"
            end
            if settings.AutoGrassUpgrade then
                local name=upgradeCurrency("Grass")
                state.grassUpgradeStatus=name and ("Buying "..name)or "Waiting for affordable, unlocked Grass upgrades"
            end
            if settings.AutoSoilConvert then
                local highest=data.HighestStats:FindFirstChild("HighestSeed")
                local unlocked=highest and highest.Value>=4
                local priority=settings.SeedPriority and settings.AutoEvolve
                if unlocked and afford("Cash",100000)and(not priority or soilPending)then
                    fw.Network.Fire("Soil")
                    soilPending=false
                    state.soilStatus="Converted cash to soil"
                elseif priority and not soilPending then
                    state.soilStatus="Saving cash for seed evolution"
                elseif not unlocked then state.soilStatus="Soil unlocks at seed 4"end
            end
        end)
        if not ok then state.soilStatus="Retrying: "..tostring(failure);print("FASTHUB_UPGRADE_RETRY",failure)end
        task.wait(.75)
    end
end)
state.threads[#state.threads+1]=task.spawn(function()
    while state.alive do
        if settings.Enabled and settings.AutoWaterClick then
            local highest=data.HighestStats:FindFirstChild("HighestSeed")
            if highest and highest.Value>=5 then
                local ok,failure=pcall(fw.Network.Fire,"Water")
                if not ok then state.waterStatus="Retrying: "..tostring(failure)end
            else state.waterStatus="Water unlocks at seed 5"end
        end
        task.wait(.25)
    end
end)

state.threads[#state.threads+1]=task.spawn(function()
    while state.alive do
        if settings.Enabled and settings.AutoTreeCombo and not state.treeUpgradeBusy
            and stat(data.TempValues,"AttackingTree",false)then
            local ok,error=pcall(fw.Network.Fire,"TreeCombo")
            if not ok then state.treeLevelStatus=tostring(error)end
        end
        task.wait(.15)
    end
end)
state.threads[#state.threads+1]=task.spawn(function()
    while state.alive do
        local ok,error=pcall(function()
            if not settings.Enabled or not settings.AutoTreeLevels then return end
            local level=stat(stats,"TreeLevel",0)
            if level>=physicalTree.Max then state.treeLevelStatus="Tree level maxed";return end
            local price=physicalTree.Pricing(data)
            local remaining=big.max(0,big.sub(price,stat(data.Tree,"WaterDeposited","0")))
            if not afford("Water",remaining)then state.treeLevelStatus="Saving Water for next tree level";return end
            local feature=workspace.Features:FindFirstChild("Tree")
            local upgrading=feature and feature:FindFirstChild("Upgrading")
            local ring=upgrading and upgrading:FindFirstChild("Ring")
            local part=ring and ring:FindFirstChild("Main")
            local root=getRoot()
            if not root or not part then return end
            state.treeUpgradeBusy=true
            state.treeRoot,state.treeOrigin=root,root.CFrame
            state.treeLevelStatus="Upgrading tree"
            root.CFrame=part.CFrame*CFrame.new(0,part.Size.Y/2+3,0)
            root.AssemblyLinearVelocity=Vector3.zero
            local deadline=os.clock()+3
            repeat task.wait(.1)until not state.alive or not settings.Enabled or not settings.AutoTreeLevels
                or stat(stats,"TreeLevel",0)>level or os.clock()>=deadline
            if stat(stats,"TreeLevel",0)>level then
                state.treeLevelStatus="Tree upgraded to level "..stat(stats,"TreeLevel",0)
                print("FASTHUB_TREE_LEVEL_CONFIRMED",level,stat(stats,"TreeLevel",0))
            else state.treeLevelStatus="Waiting for upgrade ring response"end
            if state.treeRoot and state.treeRoot.Parent and state.treeOrigin then state.treeRoot.CFrame=state.treeOrigin end
            state.treeRoot,state.treeOrigin=nil,nil
            state.treeUpgradeBusy=false
        end)
        if not ok then
            if state.treeRoot and state.treeRoot.Parent and state.treeOrigin then state.treeRoot.CFrame=state.treeOrigin end
            state.treeRoot,state.treeOrigin=nil,nil
            state.treeUpgradeBusy=false
            state.treeLevelStatus="Retrying: "..tostring(error)
        end
        task.wait(1)
    end
end)
state.threads[#state.threads+1]=task.spawn(function()
    while state.alive do
        if settings.Enabled and settings.AutoGrassClick then
            local ok,failure=pcall(fw.Network.Fire,"CollectGrass")
            state.grassClickStatus=ok and "Clicking grass pet"or ("Retrying: "..tostring(failure))
        else state.grassClickStatus="Grass clicker paused"end
        task.wait(.3)
    end
end)
state.threads[#state.threads+1]=task.spawn(function()
    while state.alive do
        local ok,failure=pcall(function()
            if not settings.Enabled then return end
            if settings.AutoResearchLevel then
                local level=stat(stats,"ResearchLevel",0)
                local price=researchDefs.Prices[level]
                if level>=researchDefs.Max then state.researchLevelStatus="Research level maxed"
                elseif price and afford(researchDefs.Currency,price)then
                    fw.Network.Fire("UpgradeResearch")
                    state.researchLevelStatus="Upgrading research level"
                    return
                else state.researchLevelStatus="Saving Paper for next research level"end
            end
            if settings.AutoResearchUpgrades then
                local name=buyResearchShop(researchUpgradeDefs,"ResearchUpgrades","UpgradeResearchUpgrade")
                state.researchUpgradeStatus=name and ("Buying "..name)or "Waiting for affordable, unlocked research upgrades"
            end
            if settings.AutoPaperBoosts then
                local name=buyResearchShop(paperBoostDefs,"ResearchBoosts","UpgradeResearchBoost")
                state.paperBoostStatus=name and ("Buying "..name)or "Waiting for affordable, unlocked paper boosts"
            end
        end)
        if not ok then state.researchUpgradeStatus="Retrying: "..tostring(failure);warn("FASTHUB_RESEARCH_RETRY",failure)end
        task.wait(1)
    end
end)
state.threads[#state.threads+1]=task.spawn(function()
    while state.alive do
        local ok,failure=pcall(function()
            if not settings.Enabled or not settings.AutoPetEvolve then return end
            local petIndex=stat(stats,"Pet",0)
            local pet=petDefs[petIndex]
            if not pet or not petDefs[petIndex+1]then state.petEvolveStatus="Pet maxed";return end
            local level=stat(stats,"PetLevel",0)
            local evolving=player:GetAttribute("AB_NoPlantLevels")==true or level>=pet.Levels
            local price=evolving and pet.EvolvePrice or callDefinition(pet.Price,player,nil)
            if price and afford("Grass",price)then
                fw.Network.Fire("UpgradePet")
                state.petEvolveStatus=evolving and "Evolving pet"or "Buying pet level"
            else state.petEvolveStatus="Saving Grass: "..(price and cashText(price)or "?")end
        end)
        if not ok then state.petEvolveStatus="Retrying: "..tostring(failure);warn("FASTHUB_PET_RETRY",failure)end
        task.wait(1)
    end
end)
selectTab(main)
if wasMinimized then state.SetMinimized(true)end
render()
print("FASTHUB_PLANT_INCREMENTAL_STARTED")

