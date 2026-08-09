
--[[
    Paint-by-Number Auto Painter
    -----------------------------
    Finds your own plot's ActivePicture folder, groups unpainted pixels
    (Parts with attribute D == false) by their color number (attribute N),
    fires the SelectNumber remote to pick that color, then walks continuously
    across matching pixels until they're painted (D flips to true), before
    moving to the next number. Repeats until nothing unpainted is left.

    CONTINUOUS MODE (default): the character never stops to wait for a single
    pixel to paint. Movement is paced by the render heartbeat (no fixed sleep
    between steps), and the moment the current pixel is painted it retargets
    immediately rather than on a poll timer — MoveTo is only re-issued when
    the target actually changes, not repeatedly to the same point, since that
    repeated re-issue was itself the source of the old brief stutter. A full
    list re-scan (for a closer/new pixel appearing) is still throttled by
    retargetInterval, since that part is an O(n) scan and worth rate-limiting.

    CONTROLS (run in console):
        PaintBotStop()    -- stops the bot cleanly (cannot be resumed)
        PaintBotPause()   -- pauses in place (can be resumed)
        PaintBotResume()  -- resumes after a pause

    There's also a Start/Stop button on the on-screen progress UI that
    does the same pause/resume toggle as the console functions above.

    FPS: other players' canvases are cleared with a repeating sweep (see
    CONFIG.hideOtherCanvases / canvasScanInterval) so plots/pixels that
    stream in a moment after you join still get caught.

    CONFIG — check these before running
]]

local CONFIG = {
    -- If auto-detection of your plot fails, set your exact in-game
    -- username here (case-sensitive) and re-run.
    plotOwnerName = nil,

    -- CONTINUOUS MODE: keep the character in motion and retarget the nearest
    -- still-unpainted pixel of the current number on a short interval.
    -- When true, paintWaitTimeout is ignored and there is no intentional
    -- stop-and-wait on each pixel. Set false to restore the legacy
    -- "walk → arrive → wait for paint" behaviour.
    continuousMode = true,

    -- How often (seconds) to run a full re-scan of all pixels for this
    -- number to check for a closer/new one, while continuousMode is active.
    -- This does NOT pace movement or MoveTo anymore (that happens every
    -- frame with no artificial delay) — it only throttles the O(n) list
    -- scan, which is the one part that's actually worth rate-limiting.
    -- 0.1–0.2 is a good range.
    retargetInterval = 0.1,

    -- How close (studs, horizontal XZ distance) counts as "arrived" at a pixel.
    -- Only used in legacy (continuousMode = false) mode for the paint-wait gate.
    -- In continuous mode the bot never waits on arrival; this is unused there.
    arriveDistance = 3,

    -- LEGACY ONLY (continuousMode = false): after arriving, how long to wait
    -- for the game to auto-paint (D flips to true) before giving up on this
    -- pixel and moving to the next. Ignored when continuousMode is true.
    paintWaitTimeout = 2,

    -- Delay after firing SelectNumber before starting to walk, to give the
    -- game time to register the color switch
    selectNumberSettleTime = 0.25,

    -- Optional walk speed boost. Set to nil to leave WalkSpeed untouched.
    walkSpeedOverride = nil,

    -- STUCK RECOVERY: how often (seconds) to check whether the character
    -- has actually moved while walking to a pixel
    stuckCheckInterval = 1.0,

    -- If the character has moved less than this many studs since the last
    -- check, it's considered stuck
    stuckMoveThreshold = 1.5,

    -- How many recovery attempts to make on a single pixel before giving
    -- up on it entirely and moving to a different one (it'll be picked up
    -- again on a later pass if still unpainted)
    maxStuckRecoveries = 3,

    -- FAST STALL FIX: humanoid:MoveTo() can silently fail to actually
    -- start the character walking (dropped by the engine right after a
    -- FireServer call, a prior MoveTo, a state transition, etc.). Since
    -- MoveTo is only issued once per target (re-sending it every tick is
    -- what caused the old hitch), a dropped request left the character
    -- standing still doing nothing until the much slower position-based
    -- stuckCheckInterval + full jump/nudge recovery kicked in a second
    -- or more later. This is a much cheaper, faster check: if the
    -- humanoid reports zero MoveDirection for this long while it should
    -- be walking (target set, not already basically on top of it), just
    -- re-send the same MoveTo -- no jump, no nudge, almost free.
    moveDirectionGraceTime = 0.3,

    -- Don't treat MoveDirection==0 as a stall if we're already this close
    -- to the target -- the humanoid naturally stops accelerating/turns
    -- MoveDirection to zero right as it arrives, that's not a problem.
    moveDirectionArriveGuard = 3,

    -- On-screen progress bar
    showProgressUI = true,
    progressUpdateInterval = 0.5,

    -- Order colors are worked through: "ascending" (1->30), "descending"
    -- (30->1), or "random" (shuffled each pass). Can also be changed live
    -- via the buttons on the progress UI.
    drawMode = "ascending",

    -- Persist settings (currently just drawMode) to a file so they survive
    -- rejoining the game. Requires writefile/readfile/isfile support.
    saveConfig = true,
    configFile = "paintbot_config.json",

    -- Anti-AFK: nudges the game whenever Roblox's own idle detector fires,
    -- so the ~20 minute AFK kick doesn't happen during long runs.
    antiAfk = true,

    -- Print progress as it works. In continuous mode, per-pixel walk logs
    -- are throttled so the console isn't spammed every retarget.
    verbose = true,

    -- Default WalkSpeed to apply to the local player once the bot has
    -- started (applies on spawn/respawn too). Set to nil to disable and
    -- rely solely on walkSpeedOverride above.
    defaultPlayerSpeed = 50,

    -- FPS BOOST: destroy the pixel parts belonging to every other plot's
    -- ActivePicture folder (your own plot is left untouched). Runs as a
    -- repeating sweep rather than a single pass, since other plots (and
    -- their pixels) can stream in gradually after you join.
    -- Set to false to leave other canvases alone.
    hideOtherCanvases = true,

    -- How often (seconds) to re-sweep all plots for the above. Keeps
    -- catching neighbors/pixels that stream in after the first pass.
    canvasScanInterval = 1.0,

    -- FREEZE FIX: the sweep above destroys parts in a plain synchronous
    -- loop. Luau only switches threads at yield points, so if a burst of
    -- neighbor pixels streams in at once (walking near several plots,
    -- multiple players loading together, etc.), destroying all of them
    -- in one unbroken loop hogs the whole script's execution slice for
    -- that frame -- including the paint loop's Heartbeat:Wait(), which
    -- can't run until the destroy loop finishes. That's the 2-3s freeze.
    -- This setting yields every N destroys so the sweep spreads across
    -- several frames instead of stalling everything at once.
    canvasClearYieldEvery = 40,
}

----------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local SelectNumberEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SelectNumber")

local function log(...)
    if CONFIG.verbose then
        print("[PaintBot]", ...)
    end
end

-- Stop switch
if getgenv().PaintBotRunning then
    getgenv().PaintBotRunning = false
    task.wait(0.3)
end
getgenv().PaintBotRunning = true
getgenv().PaintBotPaused = false

getgenv().PaintBotStop = function()
    getgenv().PaintBotRunning = false
    print("[PaintBot] Stop requested.")
end
getgenv().PaintBotPause = function()
    getgenv().PaintBotPaused = true
    print("[PaintBot] Paused.")
end
getgenv().PaintBotResume = function()
    getgenv().PaintBotPaused = false
    print("[PaintBot] Resumed.")
end

-- Sleeps in short increments while paused, returns early if the bot is
-- stopped entirely so callers can bail out of their own loops.
local function waitWhilePaused()
    while getgenv().PaintBotRunning and getgenv().PaintBotPaused do
        task.wait(0.15)
    end
end

local function findOwnPlot()
    local plotModels = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("PlotModels")
    if not plotModels then
        warn("[PaintBot] Could not find Workspace.Map.PlotModels")
        return nil
    end

    -- 1) Try exact name match (config override or player's own name)
    local tryName = CONFIG.plotOwnerName or LocalPlayer.Name
    local plot = plotModels:FindFirstChild(tryName)
    if plot and plot:FindFirstChild("ActivePicture") then
        log("Found plot by name match:", plot.Name)
        return plot
    end

    -- 2) Fallback: closest plot to the player's character
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        warn("[PaintBot] No character/HumanoidRootPart to use for fallback plot detection")
        return nil
    end

    local best, bestDist = nil, math.huge
    for _, candidate in ipairs(plotModels:GetChildren()) do
        local ap = candidate:FindFirstChild("ActivePicture")
        if ap then
            local base = candidate:FindFirstChild("PersistentParts")
            local refPart = (base and base:FindFirstChild("Base")) or ap:FindFirstChildWhichIsA("Part")
            if refPart then
                local d = (refPart.Position - hrp.Position).Magnitude
                if d < bestDist then
                    bestDist = d
                    best = candidate
                end
            end
        end
    end

    if best then
        log("Found plot by proximity fallback:", best.Name, "(distance:", math.floor(bestDist), "studs)")
    else
        warn("[PaintBot] Could not find any plot with an ActivePicture folder")
    end
    return best
end

local function distanceXZ(a, b)
    local dx, dz = a.X - b.X, a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

-- Event-driven cache of unpainted pixels. This is the key FPS fix: the old
-- code re-scanned every part in the picture (calling GetAttribute twice per
-- part) up to 10x per second in continuous mode, which is what lagged the
-- game on large canvases. Instead we build the list once, then keep it in
-- sync with cheap attribute-change / child events, so the hot loop never
-- does an O(n) GetAttribute scan.
local function createPixelCache(activePicture)
    local cache = {
        byNumber = {},       -- number -> { [part] = true }  (unpainted only)
        countByNumber = {},  -- number -> count of unpainted
        total = 0,           -- total pixels (painted + unpainted)
        done = 0,            -- painted pixels
        partToNumber = {},   -- part -> number (all parts, for O(1) removal)
    }

    -- A pixel got painted (D flipped to true): move it out of the unpainted set.
    local function onPartPainted(part)
        local n = cache.partToNumber[part]
        if n then
            local set = cache.byNumber[n]
            if set and set[part] then
                set[part] = nil
                cache.countByNumber[n] = cache.countByNumber[n] - 1
                cache.done = cache.done + 1
            end
            -- keep partToNumber[part] so a later removal can still fix done/total
        end
    end

    -- A pixel was removed from the picture entirely.
    local function onPartRemoved(part)
        local n = cache.partToNumber[part]
        if n then
            local set = cache.byNumber[n]
            if set and set[part] then
                -- was unpainted: counted toward total but not done
                set[part] = nil
                cache.countByNumber[n] = cache.countByNumber[n] - 1
                cache.total = cache.total - 1
            else
                -- was already painted: counted toward both total and done
                cache.done = cache.done - 1
                cache.total = cache.total - 1
            end
            cache.partToNumber[part] = nil
        end
    end

    local function addPart(part)
        if not part:IsA("BasePart") then return end
        local n = part:GetAttribute("N")
        if n == nil then return end
        cache.total = cache.total + 1
        cache.partToNumber[part] = n
        if part:GetAttribute("D") == true then
            cache.done = cache.done + 1
        else
            cache.byNumber[n] = cache.byNumber[n] or {}
            cache.byNumber[n][part] = true
            cache.countByNumber[n] = (cache.countByNumber[n] or 0) + 1
        end
        -- When this pixel gets painted, drop it from the cache immediately.
        part:GetAttributeChangedSignal("D"):Connect(function()
            if part:GetAttribute("D") == true then
                onPartPainted(part)
            end
        end)
    end

    -- Initial population
    for _, part in ipairs(activePicture:GetChildren()) do
        addPart(part)
    end

    -- Handle pixels that stream in / get removed later
    activePicture.ChildAdded:Connect(addPart)
    activePicture.ChildRemoved:Connect(onPartRemoved)

    -- Fallback reconciliation: occasionally re-scan to catch anything the
    -- events missed. This is the ONLY remaining O(n) GetAttribute scan and
    -- it runs rarely (every few seconds) instead of 10x per second.
    cache.reconcile = function()
        local byNumber, countByNumber, partToNumber = {}, {}, {}
        local total, done = 0, 0
        for _, part in ipairs(activePicture:GetChildren()) do
            if part:IsA("BasePart") then
                local n = part:GetAttribute("N")
                if n ~= nil then
                    total = total + 1
                    partToNumber[part] = n
                    if part:GetAttribute("D") == true then
                        done = done + 1
                    else
                        byNumber[n] = byNumber[n] or {}
                        byNumber[n][part] = true
                        countByNumber[n] = (countByNumber[n] or 0) + 1
                    end
                end
            end
        end
        cache.byNumber = byNumber
        cache.countByNumber = countByNumber
        cache.partToNumber = partToNumber
        cache.total = total
        cache.done = done
    end

    return cache
end

-- Live scan: all still-unpainted parts for a single number N.
-- skipSet (optional): weak set of parts to ignore this pass (stuck give-ups).
local function gatherRemainingForNumber(activePicture, n, skipSet)
    local remaining = {}
    for _, part in ipairs(activePicture:GetChildren()) do
        if part:IsA("BasePart")
            and part:GetAttribute("N") == n
            and part:GetAttribute("D") == false
            and not (skipSet and skipSet[part]) then
            table.insert(remaining, part)
        end
    end
    return remaining
end

local function findNearestPixel(parts, hrp)
    local nearest, nearestDist = nil, math.huge
    for _, part in ipairs(parts) do
        if part and part.Parent then
            local d = distanceXZ(hrp.Position, part.Position)
            if d < nearestDist then
                nearestDist = d
                nearest = part
            end
        end
    end
    return nearest, nearestDist
end

local function selectNumber(n)
    local okFire, errFire = pcall(function()
        SelectNumberEvent:FireServer(n)
    end)
    if not okFire then
        warn("[PaintBot] Failed to fire SelectNumber:", errFire)
    end
    log("Selected number", n)
    task.wait(CONFIG.selectNumberSettleTime)
end


-- Config save/load (persists drawMode across game rejoins)
local function loadConfig()
    if not CONFIG.saveConfig then return end

    print("[PaintBot][Config] Checking for", CONFIG.configFile)

    local okCheck, exists = pcall(function() return isfile and isfile(CONFIG.configFile) end)
    if not okCheck then
        warn("[PaintBot][Config] isfile() check errored:", exists)
        return
    end
    if not exists then
        print("[PaintBot][Config] No saved config file found (isfile returned false/nil). Using defaults.")
        return
    end

    local okRead, content = pcall(function() return readfile(CONFIG.configFile) end)
    if not okRead then
        warn("[PaintBot][Config] readfile() failed:", content)
        return
    end
    print("[PaintBot][Config] Raw file content:", tostring(content))

    local okDecode, data = pcall(function() return HttpService:JSONDecode(content) end)
    if not okDecode then
        warn("[PaintBot][Config] JSONDecode failed:", data)
        return
    end
    if type(data) ~= "table" or not data.drawMode then
        warn("[PaintBot][Config] Decoded data missing drawMode:", tostring(data))
        return
    end

    getgenv().PaintBotDrawMode = data.drawMode
    print("[PaintBot][Config] Loaded saved drawMode =", data.drawMode)
end

local function saveConfigToFile()
    if not CONFIG.saveConfig then return end
    local data = { drawMode = getgenv().PaintBotDrawMode }
    local okEncode, json = pcall(function() return HttpService:JSONEncode(data) end)
    if not okEncode then
        warn("[PaintBot][Config] JSONEncode failed:", json)
        return
    end
    local okWrite, errWrite = pcall(function() writefile(CONFIG.configFile, json) end)
    if okWrite then
        print("[PaintBot][Config] Saved:", json)
    else
        warn("[PaintBot][Config] writefile() failed:", errWrite)
    end
end

-- Anti-AFK: Roblox's Idled event alone is unreliable in many executors and
-- long sessions (kick still happens ~20 min). We mirror a proven pattern:
-- 1) react immediately when Idled fires
-- 2) also periodically nudge every ~10 min as a hard backup so the idle
--    timer never reaches the kick threshold even if Idled never fires.
local function setupAntiAfk()
    if not CONFIG.antiAfk then return end

    local function nudge()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end

    LocalPlayer.Idled:Connect(function()
        log("Anti-AFK: Idled fired — nudging")
        nudge()
    end)

    -- Backup loop: force activity every 10 minutes regardless of Idled
    task.spawn(function()
        while getgenv().PaintBotRunning do
            task.wait(600) -- 10 minutes
            if not getgenv().PaintBotRunning then break end
            log("Anti-AFK: periodic nudge")
            nudge()
        end
    end)

    log("Anti-AFK armed (Idled + 10 min periodic backup)")
end
setupAntiAfk()

-- Live-adjustable draw mode (buttons on the UI can change this mid-run)
getgenv().PaintBotDrawMode = CONFIG.drawMode
loadConfig()

-- Default speed hookup. This only starts watching for character spawns
-- once armSpeedHook() is called (done from task.spawn below, right after
-- the main bot confirms it has a plot and is starting), so it doesn't do
-- anything before the bot itself is actually running.
local function applySpeed(character)
    local humanoid = character:WaitForChild("Humanoid")
    humanoid.WalkSpeed = CONFIG.defaultPlayerSpeed
end

local function armSpeedHook()
    if not CONFIG.defaultPlayerSpeed then return end
    if LocalPlayer.Character then
        applySpeed(LocalPlayer.Character)
    end
    LocalPlayer.CharacterAdded:Connect(applySpeed)
    log("Default speed hook armed (WalkSpeed =", CONFIG.defaultPlayerSpeed, ")")
end

-- FPS boost: repeatedly sweeps every other plot and destroys whatever is
-- currently inside its ActivePicture folder. A repeating sweep (rather
-- than a one-shot pass + ChildAdded hook) is what actually caught plots
-- and pixels that stream in a moment after you join, in testing.
local function armCanvasClearing(plotModels, ownPlot)
    if not CONFIG.hideOtherCanvases then return end

    local yieldEvery = math.max(1, CONFIG.canvasClearYieldEvery or 40)

    task.spawn(function()
        local firstPass = true
        while getgenv().PaintBotRunning do
            local plotsSeen, plotsWithCanvas, destroyed = 0, 0, 0
            local sinceYield = 0

            for _, candidate in ipairs(plotModels:GetChildren()) do
                plotsSeen = plotsSeen + 1
                if candidate ~= ownPlot then
                    local ap = candidate:FindFirstChild("ActivePicture")
                    if ap then
                        plotsWithCanvas = plotsWithCanvas + 1
                        for _, part in ipairs(ap:GetChildren()) do
                            local ok = pcall(function() part:Destroy() end)
                            if ok then destroyed = destroyed + 1 end

                            -- Yield periodically instead of destroying an
                            -- entire burst in one unbroken loop. This is
                            -- what stops the sweep from stalling the paint
                            -- loop's Heartbeat:Wait() for multiple seconds
                            -- when a lot of neighbor pixels stream in at once.
                            sinceYield = sinceYield + 1
                            if sinceYield >= yieldEvery then
                                sinceYield = 0
                                task.wait()
                                if not getgenv().PaintBotRunning then
                                    return
                                end
                            end
                        end
                    end
                end
            end

            if firstPass then
                log(string.format(
                    "Canvas clearing: saw %d plot(s), %d with a canvas, destroyed %d pixel(s) on first pass",
                    plotsSeen, plotsWithCanvas, destroyed))
                firstPass = false
            end

            task.wait(CONFIG.canvasScanInterval)
        end
    end)
end

local function pickNextNumber(numbers)
    local mode = getgenv().PaintBotDrawMode or "ascending"
    if mode == "descending" then
        local best = numbers[1]
        for _, n in ipairs(numbers) do
            if n > best then best = n end
        end
        return best
    elseif mode == "random" then
        return numbers[math.random(#numbers)]
    else
        local best = numbers[1]
        for _, n in ipairs(numbers) do
            if n < best then best = n end
        end
        return best
    end
end

-- ===== UI theme + small helpers (keeps the widget code below short) =====
local THEME = {
    bg        = Color3.fromRGB(24, 24, 27),
    titlebar  = Color3.fromRGB(32, 32, 36),
    accent    = Color3.fromRGB(0, 255, 140),
    danger    = Color3.fromRGB(255, 70, 70),
    chipOff   = Color3.fromRGB(50, 50, 55),
    barBg     = Color3.fromRGB(45, 45, 50),
    text      = Color3.fromRGB(235, 235, 240),
    subtext   = Color3.fromRGB(170, 170, 180),
}

local function corner(inst, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 8)
    c.Parent = inst
    return c
end

local function stroke(inst, color, thickness)
    local s = Instance.new("UIStroke")
    s.Color = color or Color3.fromRGB(0, 0, 0)
    s.Thickness = thickness or 1
    s.Transparency = 0.5
    s.Parent = inst
    return s
end

-- Small flat button factory. opts: {size, bg, textColor, textSize, bold}
local function makeButton(parent, text, opts)
    opts = opts or {}
    local btn = Instance.new("TextButton")
    btn.Size = opts.size or UDim2.new(1, 0, 0, 26)
    btn.BackgroundColor3 = opts.bg or THEME.chipOff
    btn.BackgroundTransparency = opts.transparency or 0.15
    btn.AutoButtonColor = false
    btn.Text = text
    btn.Font = opts.bold == false and Enum.Font.Gotham or Enum.Font.GothamBold
    btn.TextSize = opts.textSize or 13
    btn.TextColor3 = opts.textColor or THEME.text
    btn.Parent = parent
    corner(btn, opts.radius or 6)
    return btn
end

-- Makes `frame` draggable by pressing/dragging on `handle` (mouse + touch)
local function makeDraggable(handle, frame)
    local UserInputService = game:GetService("UserInputService")
    local dragging, dragInput, dragStart, startPos

    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    handle.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

local ProgressLabel, ProgressBarFill, ControlButton

local function refreshControlButton()
    if not ControlButton then return end
    if getgenv().PaintBotPaused then
        ControlButton.Text = "Start"
        ControlButton.BackgroundColor3 = THEME.accent
        ControlButton.TextColor3 = Color3.fromRGB(10, 10, 10)
    else
        ControlButton.Text = "Stop"
        ControlButton.BackgroundColor3 = THEME.danger
        ControlButton.TextColor3 = Color3.new(1, 1, 1)
    end
end

local function createProgressUI()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "PaintBotProgressUI"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

    -- Main window
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 240, 0, 178)
    frame.Position = UDim2.new(0.5, -120, 0, 20)
    frame.BackgroundColor3 = THEME.bg
    frame.Parent = screenGui
    corner(frame, 10)
    stroke(frame, Color3.new(0, 0, 0), 1)

    -- Title bar (drag handle)
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 32)
    titleBar.BackgroundColor3 = THEME.titlebar
    titleBar.Parent = frame
    corner(titleBar, 10)
    -- square off the bottom corners of the title bar so it doesn't look pill-shaped
    local titleBarMask = Instance.new("Frame")
    titleBarMask.Size = UDim2.new(1, 0, 0, 10)
    titleBarMask.Position = UDim2.new(0, 0, 1, -10)
    titleBarMask.BackgroundColor3 = THEME.titlebar
    titleBarMask.BorderSizePixel = 0
    titleBarMask.Parent = titleBar

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(1, -40, 1, 0)
    titleLabel.Position = UDim2.new(0, 12, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "PaintBot"
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 14
    titleLabel.TextColor3 = THEME.text
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Parent = titleBar

    makeDraggable(titleBar, frame)

    -- Minimized "reopen" tab, shown only while the menu is closed
    local reopenTab = makeButton(screenGui, "≡ Menu", {
        size = UDim2.new(0, 70, 0, 26),
        bg = THEME.bg,
        textSize = 12,
    })
    reopenTab.Position = UDim2.new(0.5, -35, 0, 20)
    reopenTab.Visible = false
    stroke(reopenTab, Color3.new(0, 0, 0), 1)

    local function setMenuOpen(open)
        frame.Visible = open
        reopenTab.Visible = not open
    end
    reopenTab.MouseButton1Click:Connect(function()
        setMenuOpen(true)
    end)

    local closeButton = makeButton(titleBar, "X", {
        size = UDim2.new(0, 22, 0, 22),
        bg = Color3.fromRGB(60, 60, 66),
        textSize = 13,
    })
    closeButton.Position = UDim2.new(1, -28, 0.5, -11)
    closeButton.MouseButton1Click:Connect(function()
        setMenuOpen(false)
    end)

    -- Content area
    local content = Instance.new("Frame")
    content.Size = UDim2.new(1, -20, 1, -42)
    content.Position = UDim2.new(0, 10, 0, 38)
    content.BackgroundTransparency = 1
    content.Parent = frame

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.Padding = UDim.new(0, 8)
    layout.Parent = content

    ProgressLabel = Instance.new("TextLabel")
    ProgressLabel.Size = UDim2.new(1, 0, 0, 16)
    ProgressLabel.BackgroundTransparency = 1
    ProgressLabel.TextColor3 = THEME.subtext
    ProgressLabel.Font = Enum.Font.Gotham
    ProgressLabel.TextSize = 12
    ProgressLabel.TextXAlignment = Enum.TextXAlignment.Left
    ProgressLabel.Text = "0% (0/0)"
    ProgressLabel.LayoutOrder = 1
    ProgressLabel.Parent = content

    local barBG = Instance.new("Frame")
    barBG.Size = UDim2.new(1, 0, 0, 12)
    barBG.BackgroundColor3 = THEME.barBg
    barBG.LayoutOrder = 2
    barBG.Parent = content
    corner(barBG, 6)

    ProgressBarFill = Instance.new("Frame")
    ProgressBarFill.Size = UDim2.new(0, 0, 1, 0)
    ProgressBarFill.BackgroundColor3 = THEME.accent
    ProgressBarFill.Parent = barBG
    corner(ProgressBarFill, 6)

    -- Draw mode row
    local modeRow = Instance.new("Frame")
    modeRow.Size = UDim2.new(1, 0, 0, 26)
    modeRow.BackgroundTransparency = 1
    modeRow.LayoutOrder = 3
    modeRow.Parent = content

    local modeLayout = Instance.new("UIListLayout")
    modeLayout.FillDirection = Enum.FillDirection.Horizontal
    modeLayout.Padding = UDim.new(0, 6)
    modeLayout.Parent = modeRow

    local modeButtons = {}
    local function setActiveMode(mode)
        getgenv().PaintBotDrawMode = mode
        saveConfigToFile()
        for m, btn in pairs(modeButtons) do
            btn.BackgroundColor3 = (m == mode) and THEME.accent or THEME.chipOff
            btn.TextColor3 = (m == mode) and Color3.fromRGB(10, 10, 10) or THEME.text
        end
    end

    local modes = {"ascending", "descending", "random"}
    local labels = {ascending = "Asc", descending = "Desc", random = "Random"}
    for _, mode in ipairs(modes) do
        local btn = makeButton(modeRow, labels[mode], {
            size = UDim2.new(1 / 3, -4, 1, 0),
            textSize = 12,
        })
        modeButtons[mode] = btn
        btn.MouseButton1Click:Connect(function()
            setActiveMode(mode)
        end)
    end
    setActiveMode(getgenv().PaintBotDrawMode or "ascending")

    -- Start/Stop (pause/resume) button
    ControlButton = makeButton(content, "Stop", {
        size = UDim2.new(1, 0, 0, 30),
        textSize = 13,
    })
    ControlButton.LayoutOrder = 4
    ControlButton.MouseButton1Click:Connect(function()
        if getgenv().PaintBotPaused then
            getgenv().PaintBotResume()
        else
            getgenv().PaintBotPause()
        end
        refreshControlButton()
    end)

    refreshControlButton()
end

local function updateProgressUI(cache)
    if not ProgressLabel or not ProgressBarFill then return end

    local total = cache.total
    local done = cache.done

    local pct = total > 0 and math.floor((done / total) * 100) or 0
    local statusSuffix = getgenv().PaintBotPaused and "  ·  Paused" or ""
    ProgressLabel.Text = string.format("%d%% (%d/%d)%s", pct, done, total, statusSuffix)
    ProgressBarFill.Size = UDim2.new(pct / 100, 0, 1, 0)
    refreshControlButton()
end

local function attemptUnstick(humanoid, hrp, targetPos)
    log("Stuck detected, attempting recovery...")
    -- Jump in place first, sometimes enough to pop free of geometry
    humanoid.Jump = true
    task.wait(0.2)

    -- Nudge toward a small random offset near current position to break
    -- out of a bad pathing lock, then re-issue the real move
    local nudge = hrp.Position + Vector3.new(
        (math.random() - 0.5) * 6,
        0,
        (math.random() - 0.5) * 6
    )
    humanoid:MoveTo(nudge)
    task.wait(0.5)

    humanoid:MoveTo(targetPos)
end

-- Returns true if the part is still a valid unpainted target.
local function isPixelStillOpen(part)
    return part ~= nil
        and part.Parent ~= nil
        and part:GetAttribute("D") ~= true
end

----------------------------------------------------------------
-- LEGACY walk-to-one-pixel (used only when continuousMode = false)
----------------------------------------------------------------
local function walkToPixel(part, humanoid, hrp, expectedMode)
    humanoid:MoveTo(part.Position)
    local waited = 0

    local lastCheckPos = hrp.Position
    local lastCheckTime = tick()
    local stuckRecoveries = 0

    while getgenv().PaintBotRunning do
        if getgenv().PaintBotPaused then
            -- Hold position while paused; don't count this time against
            -- the walk timeout or the stuck-recovery clock.
            waitWhilePaused()
            if not getgenv().PaintBotRunning then
                return false
            end
            humanoid:MoveTo(part.Position)
            lastCheckPos = hrp.Position
            lastCheckTime = tick()
        else
            if expectedMode and getgenv().PaintBotDrawMode ~= expectedMode then
                return false -- mode changed mid-walk, abandon this pixel immediately
            end
            if waited >= 10 then
                return false
            end
            if not part or not part.Parent then
                return true -- disappeared/painted and cleaned up
            end
            if part:GetAttribute("D") == true then
                return true
            end
            if distanceXZ(hrp.Position, part.Position) <= CONFIG.arriveDistance then
                -- arrived, give the game a moment to auto-paint
                local paintWaited = 0
                while getgenv().PaintBotRunning and paintWaited < CONFIG.paintWaitTimeout do
                    if getgenv().PaintBotPaused then
                        waitWhilePaused()
                    end
                    if expectedMode and getgenv().PaintBotDrawMode ~= expectedMode then
                        return false
                    end
                    if not part.Parent or part:GetAttribute("D") == true then
                        return true
                    end
                    task.wait(0.1)
                    paintWaited = paintWaited + 0.1
                end
                return part.Parent == nil or part:GetAttribute("D") == true
            end

            -- Stuck check: has the character actually moved recently?
            if tick() - lastCheckTime >= CONFIG.stuckCheckInterval then
                local moved = distanceXZ(hrp.Position, lastCheckPos)
                if moved < CONFIG.stuckMoveThreshold then
                    stuckRecoveries = stuckRecoveries + 1
                    if stuckRecoveries > CONFIG.maxStuckRecoveries then
                        log("Gave up on this pixel after", stuckRecoveries, "stuck recoveries")
                        return false
                    end
                    attemptUnstick(humanoid, hrp, part.Position)
                end
                lastCheckPos = hrp.Position
                lastCheckTime = tick()
            end

            task.wait(0.1)
            waited = waited + 0.1
        end
    end
    return false
end

----------------------------------------------------------------
-- CONTINUOUS MODE: keep moving across all pixels of number N.
-- Never stops to wait for a paint confirmation, and never sleeps
-- a fixed amount between steps — the loop is paced by the render
-- heartbeat (RunService.Heartbeat) instead of task.wait, and it
-- only re-issues MoveTo when the target actually changes. The old
-- version re-sent MoveTo to the *same* point every single tick,
-- which is what produced the little hitch after each pixel — the
-- humanoid briefly resets its walk state every time MoveTo fires,
-- even to a point it's already walking toward.
--
-- Full re-scans of the pixel list (CONFIG.retargetInterval) are
-- still throttled, since that's an O(n) walk over every part in
-- the picture and doesn't need to run every frame. But noticing
-- that the *current* target got painted or removed is checked
-- every frame (just one attribute read), so the bot snaps to the
-- next pixel the instant the current one is done, not up to
-- retargetInterval seconds later.
----------------------------------------------------------------
local function paintNumberContinuous(n, cache, humanoid, hrp, expectedMode)
    local skipSet = {} -- parts we gave up on this pass (stuck); retried next number cycle
    local currentTarget = nil
    local stuckRecoveries = 0
    local lastCheckPos = hrp.Position
    local lastCheckTime = tick()
    local lastLogTime = 0
    local lastRemainingLog = -1
    local rescanInterval = CONFIG.retargetInterval or 0.1
    local lastRescanTime = 0
    local notMovingSince = nil
    local graceTime = CONFIG.moveDirectionGraceTime or 0.3
    local arriveGuard = CONFIG.moveDirectionArriveGuard or 3
    local reconcileInterval = 3.0
    local lastReconcileTime = 0

    log("Continuous paint starting for N=" .. tostring(n))

    while getgenv().PaintBotRunning do
        -- Pause: freeze in place, reset stuck clock on resume
        if getgenv().PaintBotPaused then
            waitWhilePaused()
            if not getgenv().PaintBotRunning then
                return
            end
            lastCheckPos = hrp.Position
            lastCheckTime = tick()
            notMovingSince = nil
            if currentTarget and isPixelStillOpen(currentTarget) then
                humanoid:MoveTo(currentTarget.Position)
            end
        end

        -- Fast check: is a dropped/never-started MoveTo leaving us idle?
        -- This is independent of (and much quicker than) the position-based
        -- stuck check below, which only samples once a second.
        if currentTarget ~= nil and not getgenv().PaintBotPaused then
            local distToTarget = distanceXZ(hrp.Position, currentTarget.Position)
            if distToTarget > arriveGuard and humanoid.MoveDirection.Magnitude < 0.05 then
                if not notMovingSince then
                    notMovingSince = tick()
                elseif tick() - notMovingSince >= graceTime then
                    humanoid:MoveTo(currentTarget.Position)
                    notMovingSince = tick() -- give the reissue its own grace window
                end
            else
                notMovingSince = nil
            end
        end

        if not getgenv().PaintBotRunning then
            return
        end

        -- Draw mode changed mid-color — abandon immediately so outer loop re-picks
        if expectedMode and getgenv().PaintBotDrawMode ~= expectedMode then
            log("Mode changed mid-color -- switching immediately")
            return
        end

        -- Cheap every-frame check: is the pixel we're currently walking to
        -- still open? This is a single attribute read, not a list scan, so
        -- doing it every frame costs nothing and means we react the instant
        -- it flips rather than waiting on the next scan tick.
        local targetLost = currentTarget ~= nil and not isPixelStillOpen(currentTarget)
        local dueForRescan = (tick() - lastRescanTime) >= rescanInterval

        -- Rare fallback: re-sync the cache from the live tree every few
        -- seconds in case an attribute change event was missed. This is the
        -- ONLY remaining O(n) GetAttribute scan and it runs ~0.3x/sec instead
        -- of 10x/sec, so it's effectively free.
        if tick() - lastReconcileTime >= reconcileInterval then
            lastReconcileTime = tick()
            cache.reconcile()
        end

        if currentTarget == nil or targetLost or dueForRescan then
            lastRescanTime = tick()

            -- Build the candidate list from the cache (O(1) lookup, no scan).
            local remaining = {}
            local set = cache.byNumber[n]
            if set then
                for part in pairs(set) do
                    if not (skipSet and skipSet[part]) then
                        table.insert(remaining, part)
                    end
                end
            end
            if #remaining == 0 then
                -- If we only emptied the list because of skips, clear skips once
                -- and retry anything still actually unpainted before giving up.
                if next(skipSet) ~= nil then
                    local anyLeft = {}
                    local set2 = cache.byNumber[n]
                    if set2 then
                        for part in pairs(set2) do
                            table.insert(anyLeft, part)
                        end
                    end
                    if #anyLeft > 0 then
                        skipSet = {}
                        stuckRecoveries = 0
                        remaining = anyLeft
                    else
                        break
                    end
                else
                    break
                end
            end

            local nearest, nearestDist = findNearestPixel(remaining, hrp)
            if not nearest then
                break
            end

            -- Only touch MoveTo when the target actually changes. Re-sending
            -- MoveTo to the same point every tick is what caused the stutter,
            -- so a same-target rescan now leaves movement completely alone.
            if nearest ~= currentTarget then
                currentTarget = nearest
                stuckRecoveries = 0
                lastCheckPos = hrp.Position
                lastCheckTime = tick()
                notMovingSince = nil
                humanoid:MoveTo(currentTarget.Position)

                -- Throttled log: at most once per ~1.5s, or when remaining count drops
                local now = tick()
                if now - lastLogTime >= 1.5 or #remaining ~= lastRemainingLog then
                    log(string.format(
                        "N=%s  target dist=%d  remaining=%d",
                        tostring(n), math.floor(nearestDist), #remaining))
                    lastLogTime = now
                    lastRemainingLog = #remaining
                end
            end
        end

        -- Stuck check (same recovery logic as before — on give-up we skip
        -- this pixel and immediately retarget the next nearest instead of
        -- blocking in a paint-wait loop).
        if tick() - lastCheckTime >= CONFIG.stuckCheckInterval then
            local moved = distanceXZ(hrp.Position, lastCheckPos)
            if moved < CONFIG.stuckMoveThreshold then
                stuckRecoveries = stuckRecoveries + 1
                if stuckRecoveries > CONFIG.maxStuckRecoveries then
                    log("Skipping stuck pixel N=" .. tostring(n) .. " after", stuckRecoveries, "recoveries")
                    skipSet[currentTarget] = true
                    currentTarget = nil
                    stuckRecoveries = 0
                else
                    local targetPos = currentTarget and currentTarget.Position or hrp.Position
                    attemptUnstick(humanoid, hrp, targetPos)
                end
            end
            lastCheckPos = hrp.Position
            lastCheckTime = tick()
        end

        -- Paced by the render heartbeat instead of a fixed task.wait sleep —
        -- this is what removes the "pause": the loop simply runs again next
        -- frame (~1/60s), same as any live gameplay logic would.
        RunService.Heartbeat:Wait()
    end

    log("Finished continuous pass for N=" .. tostring(n))
end

----------------------------------------------------------------
-- LEGACY per-pixel loop for one number (continuousMode = false)
----------------------------------------------------------------
local function paintNumberLegacy(n, activePicture, humanoid, hrp, expectedMode)
    while getgenv().PaintBotRunning do
        waitWhilePaused()
        if not getgenv().PaintBotRunning then
            break
        end

        if getgenv().PaintBotDrawMode ~= expectedMode then
            log("Mode changed mid-color -- switching immediately")
            break
        end

        local remaining = gatherRemainingForNumber(activePicture, n, nil)
        if #remaining == 0 then
            break
        end

        local nearest, nearestDist = findNearestPixel(remaining, hrp)
        if nearest then
            log("Walking to pixel N=" .. tostring(n) .. " at distance " .. math.floor(nearestDist))
            local success = walkToPixel(nearest, humanoid, hrp, expectedMode)
            if not success then
                log("Timed out / gave up on a pixel, moving on")
            end
        end
    end
end

task.spawn(function()
    local plot = findOwnPlot()
    if not plot then
        warn("[PaintBot] Aborting - no plot found. Set CONFIG.plotOwnerName manually and retry.")
        getgenv().PaintBotRunning = false
        return
    end

    local activePicture = plot:FindFirstChild("ActivePicture")
    if not activePicture then
        warn("[PaintBot] Plot has no ActivePicture folder")
        getgenv().PaintBotRunning = false
        return
    end

    armCanvasClearing(plot.Parent, plot)

    -- Build the event-driven pixel cache once. All subsequent scans (number
    -- grouping, progress, continuous retargeting) read from this instead of
    -- re-scanning the whole picture with GetAttribute calls every frame.
    local cache = createPixelCache(activePicture)

    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:WaitForChild("HumanoidRootPart")

    if CONFIG.walkSpeedOverride then
        humanoid.WalkSpeed = CONFIG.walkSpeedOverride
    end

    if CONFIG.showProgressUI then
        createProgressUI()
        task.spawn(function()
            while getgenv().PaintBotRunning do
                updateProgressUI(cache)
                task.wait(CONFIG.progressUpdateInterval)
            end
            -- final update so it shows 100% / final state before stopping
            updateProgressUI(cache)
        end)
    end

    armSpeedHook()

    log("Starting. Scanning for unpainted pixels...")
    if CONFIG.continuousMode then
        log("Continuous mode ON (retarget every", CONFIG.retargetInterval, "s)")
    else
        log("Legacy mode ON (arrive + paint-wait)")
    end

    while getgenv().PaintBotRunning do
        waitWhilePaused()
        if not getgenv().PaintBotRunning then
            break
        end

        -- Refresh character refs in case of respawn mid-run
        char = LocalPlayer.Character
        if char then
            humanoid = char:FindFirstChildOfClass("Humanoid") or humanoid
            hrp = char:FindFirstChild("HumanoidRootPart") or hrp
        end

        -- Build the list of numbers that still have unpainted pixels from
        -- the cache (O(1) per number, no full scan).
        local numbers = {}
        for num, count in pairs(cache.countByNumber) do
            if count > 0 then
                table.insert(numbers, num)
            end
        end

        if #numbers == 0 then
            log("No unpainted pixels found. Picture appears complete!")
            break
        end

        local n = pickNextNumber(numbers)
        local workingMode = getgenv().PaintBotDrawMode
        selectNumber(n)

        -- Keep working this number until no unpainted pixels with it remain,
        -- OR until the draw mode changes (then abandon and re-pick immediately)
        if CONFIG.continuousMode then
            paintNumberContinuous(n, cache, humanoid, hrp, workingMode)
        else
            paintNumberLegacy(n, activePicture, humanoid, hrp, workingMode)
        end
    end

    log("Finished (or stopped).")
    getgenv().PaintBotRunning = false
end)
