-- FastHub: RNG Height. Shared FarmHub/FastHub menu template.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local env = getgenv and getgenv() or _G
local previous = env.HeightRNGAutoRoll
local wasEnabled = not previous or previous.enabled
local previousResponses = previous and previous.responses or 0
local oldMenu = playerGui:FindFirstChild("HeightRNGAutoRollGui")
local wasMinimized = oldMenu and oldMenu:FindFirstChild("Window") and oldMenu.Window:GetAttribute("Minimized") == true
if previous and previous.Stop then previous.Stop() end
if oldMenu and oldMenu.Parent then oldMenu:Destroy() end
local state = {alive = true, enabled = wasEnabled, mode = "Waiting", lucky = 0,
    responses = previousResponses, lastError = nil}
env.HeightRNGAutoRoll = state
local alive, cleanedUp = true, false
local connections, settings = {}, {}
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
    Name = "HeightRNGAutoRollGui",
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
local rolling = addTab("Rolling")
local obby = addTab("Obby")
local options = addTab("Settings")
local section = addSection(main, 1, "Activity")
local activityLabel = addLabel(section, "")
section = addSection(main, 2, "Session Statistics")
local statsLabel = addLabel(section, "")
addButton(section, "Reset Session Statistics", function() state.responses = 0 end)
section = addSection(rolling, 1, "Auto Roll")
local rollToggle = addToggle(section, "Auto Roll · Lucky First", "enabled", state.enabled, function(v)
    state.enabled, state.lastError = v, nil
end)
addLabel(section, "Uses available Lucky Rolls first, then returns to Normal rolls. Uses the game's own roll controls.", COLORS.dim)
local balanceLabel = addLabel(section, "")
section = addSection(obby, 1, "Obby Rewards")
local obbyButton = addButton(section, "Complete Obby & Claim", function() if state.CompleteObby then state.CompleteObby() end end)
local obbyStatus = addLabel(section, "Obby: ready")
addLabel(section, "Returns you afterward and reports whether the Lucky balance increased.", COLORS.dim)
section = addSection(options, 1, "Controls")
menuKey.button = addButton(section, "Menu key: RightShift (click to change)", function()
    menuKey.capturing = true
    menuKey.button.Text = "Press a key (Esc cancels)"
end)
addButton(section, "Pause Auto Roll", function() rollToggle.set(false) end)
addButton(section, "Unload FastHub", function() state.Stop() end)
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
    local mode = state.obbyBusy and "Completing obby" or (state.enabled and ("Mode: " .. state.mode) or "Paused")
    activityLabel.Text = state.lastError and ("Retrying: " .. state.lastError) or mode
    balanceLabel.Text = "Lucky Rolls available: " .. formatNumber(state.lucky)
    statsLabel.Text = "Roll responses received: " .. formatNumber(state.responses)
    miniStatus.Text = mode
end
local function handler(b)
    if not b then return nil end
    for _, connection in ipairs(getconnections(b.Activated)) do
        if connection.Function and connection.Enabled ~= false then return connection.Function end
    end
    return nil
end
local function balance(b, callback)
    local raw = b.Text:gsub("<[^>]+>", "")
    local displayed = tonumber(raw:match("(%d+)%s*$"))
    local internal
    if callback and type(getupvalues) == "function" then
        local ok, values = pcall(getupvalues, callback)
        if ok and type(values[1]) == "function" then
            local good, upvalues = pcall(getupvalues, values[1])
            if good and upvalues[3] == b and type(upvalues[2]) == "number" and upvalues[2] >= 0 then
                internal = math.floor(upvalues[2])
            end
        end
    end
    if displayed and internal then return math.min(displayed, internal) end
    return internal or displayed or 0
end
function state.Stop()
    if not state.alive then return end
    state.alive, state.enabled, alive, cleanedUp = false, false, false, true
    for _, c in ipairs(connections) do c:Disconnect() end
    if state.thread and state.thread ~= coroutine.running() then pcall(task.cancel, state.thread) end
    if state.obbyThread then pcall(task.cancel, state.obbyThread) end
    if state.obbyRoot and state.obbyRoot.Parent and state.obbyOrigin then
        state.obbyRoot.CFrame = state.obbyOrigin
    end
    gui:Destroy()
    if env.HeightRNGAutoRoll == state then env.HeightRNGAutoRoll = nil end
end
function state.CompleteObby()
    if state.obbyBusy then return end
    state.obbyBusy = true
    obbyButton.Text = "Completing..."
    state.obbyThread = task.spawn(function()
        local ok, failure = pcall(function()
            local part = workspace:FindFirstChild("LuckyObbyPart", true)
            local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            local gameGui = playerGui:FindFirstChild("HeightRNGGui")
            local lucky = gameGui and gameGui:FindFirstChild("LuckyRollButton")
            assert(part and part:IsA("BasePart"), "Obby finish pad unavailable")
            assert(root and lucky, "Wait for your character and roll buttons")
            state.obbyRoot, state.obbyOrigin = root, root.CFrame
            -- Pause new rolls while measuring the actual reward balance.
            task.wait(4)
            local initial = balance(lucky, handler(lucky))
            obbyStatus.Text = "Obby: collecting reward..."
            root.CFrame = part.CFrame * CFrame.new(0, 3, 0)
            root.AssemblyLinearVelocity = Vector3.zero
            if type(firetouchinterest) == "function" then
                firetouchinterest(root, part, 0)
                task.wait(0.2)
                firetouchinterest(root, part, 1)
            end
            local deadline = os.clock() + 5
            local current = initial
            repeat
                task.wait(0.2)
                current = balance(lucky, handler(lucky))
            until not state.alive or current > initial or os.clock() >= deadline
            obbyStatus.Text = current > initial
                and ("Lucky balance increased by " .. (current - initial))
                or "No reward confirmed; may be on cooldown."
            print("OBBY_COMPLETION_CHECK", initial, current, part:GetAttribute("LuckyCooldownEnd"))
        end)
        if state.obbyRoot and state.obbyRoot.Parent and state.obbyOrigin then
            state.obbyRoot.CFrame = state.obbyOrigin
        end
        state.obbyRoot, state.obbyOrigin = nil, nil
        state.obbyBusy = false
        if state.alive then
            obbyButton.Text = "Complete Obby & Claim"
            if not ok then obbyStatus.Text = tostring(failure) end
        end
    end)
end
local remote = game:GetService("ReplicatedStorage"):FindFirstChild("RollHeight")
if remote and remote:IsA("RemoteEvent") then
    connections[#connections + 1] = remote.OnClientEvent:Connect(function() state.responses += 1 end)
end
state.thread = task.spawn(function()
    while state.alive do
        local ok, failure = pcall(function()
            local gameGui = playerGui:FindFirstChild("HeightRNGGui")
            local normal = gameGui and gameGui:FindFirstChild("RollButton")
            local lucky = gameGui and gameGui:FindFirstChild("LuckyRollButton")
            if not normal or not lucky then state.mode = "Waiting for roll buttons";render();return end
            local luckyCallback = handler(lucky)
            state.lucky = balance(lucky, luckyCallback)
            state.mode = state.lucky > 0 and "Lucky" or "Normal"
            if state.enabled and not state.obbyBusy then
                local selected = state.lucky > 0 and lucky or normal
                local callback = state.lucky > 0 and luckyCallback or handler(normal)
                -- Use the game's own callback, preserving its cooldown and animation gates.
                if selected.Visible and selected.Active and callback then callback() end
            end
            state.lastError = nil
            render()
        end)
        if not ok then state.lastError = tostring(failure);render() end
        task.wait(ok and 0.25 or 1)
    end
end)
render()

selectTab(main)
if wasMinimized then state.SetMinimized(true) end
print("RNG_HEIGHT_FASTHUB_STARTED")
