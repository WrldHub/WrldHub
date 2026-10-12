-- Height RNG auto-roll for the current client. Lucky Rolls take priority.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local env = getgenv and getgenv() or _G
if env.HeightRNGAutoRoll and env.HeightRNGAutoRoll.Stop then env.HeightRNGAutoRoll.Stop() end
local oldGui = playerGui:FindFirstChild("HeightRNGAutoRollGui")
if oldGui then oldGui:Destroy() end

local state = {alive = true, enabled = true, mode = "Waiting", lucky = 0, responses = 0, lastError = nil}
env.HeightRNGAutoRoll = state
local gui = Instance.new("ScreenGui")
gui.Name = "HeightRNGAutoRollGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
gui.Parent = playerGui
local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(250, 212)
frame.Position = UDim2.fromOffset(12, 80)
frame.BackgroundColor3 = Color3.fromRGB(22, 23, 28)
frame.BorderSizePixel = 0
frame.Parent = gui
local corner = Instance.new("UICorner");corner.CornerRadius = UDim.new(0, 8);corner.Parent = frame
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 0, 24)
title.Position = UDim2.fromOffset(10, 6)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextColor3 = Color3.fromRGB(232, 234, 240)
title.Text = "Auto Roll · Lucky first"
title.Parent = frame
local label = title:Clone()
label.Position = UDim2.fromOffset(10, 32)
label.Size = UDim2.new(1, -20, 0, 42)
label.TextSize = 12
label.Font = Enum.Font.Gotham
label.TextWrapped = true
label.Parent = frame
local function button(text, x, width)
    local b = Instance.new("TextButton")
    b.Position = UDim2.fromOffset(x, 84)
    b.Size = UDim2.fromOffset(width, 32)
    b.BackgroundColor3 = Color3.fromRGB(138, 99, 210)
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 12
    b.Text = text
    b.Parent = frame
    local c = Instance.new("UICorner");c.CornerRadius = UDim.new(0, 5);c.Parent = b
    return b
end
local toggle = button("Pause", 10, 108)
local stop = button("Stop & Remove", 128, 112)
local obbyButton = button("Complete Obby & Claim", 10, 230)
obbyButton.Position = UDim2.fromOffset(10, 124)
local obbyStatus = label:Clone()
obbyStatus.Position = UDim2.fromOffset(10, 160)
obbyStatus.Size = UDim2.new(1, -20, 0, 42)
obbyStatus.Text = "Obby: ready"
obbyStatus.Parent = frame
local connections = {}
local function render()
    if not state.alive then return end
    label.Text = state.lastError and ("Retrying: " .. state.lastError)
        or ((state.enabled and ("Mode: " .. state.mode) or "Paused") .. "\nLucky Rolls available: " .. state.lucky)
    toggle.Text = state.enabled and "Pause" or "Resume"
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
    state.alive, state.enabled = false, false
    for _, c in ipairs(connections) do c:Disconnect() end
    if state.thread and state.thread ~= coroutine.running() then pcall(task.cancel, state.thread) end
    if state.obbyThread then pcall(task.cancel, state.obbyThread) end
    if state.obbyRoot and state.obbyRoot.Parent and state.obbyOrigin then
        state.obbyRoot.CFrame = state.obbyOrigin
    end
    gui:Destroy()
    if env.HeightRNGAutoRoll == state then env.HeightRNGAutoRoll = nil end
end
connections[#connections + 1] = toggle.Activated:Connect(function()
    state.enabled = not state.enabled
    state.lastError = nil
    render()
end)
connections[#connections + 1] = stop.Activated:Connect(state.Stop)
connections[#connections + 1] = obbyButton.Activated:Connect(function()
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
end)
title.Active = true
local dragging, dragInput, dragStart, windowStart = false, nil, nil, nil
connections[#connections + 1] = title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging, dragInput, dragStart, windowStart = true, input, input.Position, frame.Position
    end
end)
connections[#connections + 1] = UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and not (input.UserInputType == Enum.UserInputType.Touch and input == dragInput) then return end
    local delta = input.Position - dragStart
    frame.Position = UDim2.new(windowStart.X.Scale, windowStart.X.Offset + delta.X,
        windowStart.Y.Scale, windowStart.Y.Offset + delta.Y)
end)
connections[#connections + 1] = UserInputService.InputEnded:Connect(function(input)
    if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging, dragInput = false, nil
    end
end)
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
print("HEIGHT_AUTO_ROLL_STARTED_LUCKY_PRIORITY")


