-- ================= AutoFarm — Fluent Modded rework + Fusion =================
local Fluent = loadstring(game:HttpGet(
    "https://github.com/StyearX/Fluent-Modded/releases/download/Fluent/FluentPro"
))()

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local remotes = RS:WaitForChild("Remotes")

local BuyDice = remotes:WaitForChild("BuyDice")
local BuyPotion = remotes:WaitForChild("BuyPotion")
local UsePotion = remotes:WaitForChild("UsePotion")
local EquipBest = remotes:FindFirstChild("EquipBest") or remotes:WaitForChild("EquipBest")
local RebirthRemote = remotes:WaitForChild("Rebirth")
local FoodCartRemote = remotes:WaitForChild("FoodCart")
local MerchantRemote = remotes:WaitForChild("Merchant")
local EggInfo = remotes:WaitForChild("EggInfo")
local Dialogue = remotes:WaitForChild("Dialogue")
local PotionUpdater = remotes:FindFirstChild("PotionUpdater")

-- ===== Configuration =====
local BUY_STAND_DURATION = 2
local BUY_FIRE_INTERVAL = 0.5
local TELEPORT_SETTLE_DELAY = 0.5
local SCHEDULER_INTERVAL = 1
local RESTOCK_BUFFER = 2
local FALLBACK_RESTOCK_WAIT = 120
local EQUIP_BEST_SETTLE = 0.5
local EQUIP_BEST_HOLD = 1 -- small delay after equip best fires before the player can be tped back to the previous job (e.g. eggs)
local USE_POTIONS_INTERVAL = 10
local REBIRTH_CHECK_INTERVAL = 2
local REBIRTH_COOLDOWN = 5
local SELL_COOLDOWN = 3

-- Fusion config
local FUSION_CHECK_INTERVAL = 4
local FUSION_WAIT_INTERVAL = 1
local FUSION_MAX_WAIT = 300
local AFTER_CLAIM_COOLDOWN = 2.5
local FUSE_MACHINE_CFRAME = CFrame.new(-104.240242, 1.77263951 + 5, 198.388123)
local MAX_STUCK_RETRIES = 3       -- give up retrying a stuck job after this many failed attempts
local STUCK_RETRY_BACKOFF = 10    -- seconds to wait between stuck-job retries

local DICE_ORDER = {
    "Basic", "Bronze", "Iron", "Silver", "Gold", "Sapphire", "Emerald", "Ruby",
    "Obsidian", "Crystal", "Nebula", "Void", "Celestial", "Abyssal", "Infernal",
    "Ethereal", "Galactic", "Quantum", "Eldritch", "Sovereign", "Arcane",
    "Paradox", "Oblivion", "Singularity", "Transcendent", "Omnipotent",
    "Seraphic", "Valentine",
}
local POTION_ORDER = {
    "Luck I", "Cash I", "Luck II", "Cash II", "Mutation I", "Dice Consumption I",
    "Luck III", "Cash III", "Mutation II", "Godly Cash", "Godly Luck", "Egg Luck I",
    "Dice Consumption II", "Egg Luck II", "Godly Mutation", "Godly Dice Consumption",
    "Godly Egg Luck",
}
local FOOD_ORDER = {"Apple", "Potato", "Carrot", "Loaf", "Fish", "Steak"}
local EXCLUSIVE_ORDER = {"Holy Token", "Rainbow Godly"}

local MERCHANT_CATEGORIES = {
    {name = "Dices", items = DICE_ORDER},
    {name = "Potions", items = POTION_ORDER},
    {name = "Foods", items = FOOD_ORDER},
    {name = "Exclusive", items = EXCLUSIVE_ORDER},
}

local EGG_HOLDER_INDEX = {
    Basic = 1, Forest = 2, Jungle = 3, Beach = 4, Monster = 5,
    Desert = 6, Galaxy = 7, Candy = 8, Lava = 9, Frozen = 10,
}
local EGG_NAMES = {"Basic", "Forest", "Jungle", "Beach", "Monster", "Desert", "Galaxy", "Candy", "Lava", "Frozen"}

-- ===== Feature State =====
local state = {
    dice = false, potion = false, merchant = false, foodcart = false,
    usePotions = false, egg = false, eggQuantity = 3, autoEquipBestPet = false,
    rebirth = false, equipBest = false, sell = false, sellThreshold = 30,
    equipBestInterval = 30,
    selectedEgg = "Basic",
    autoCraftGolden = false,
    autoCraftDiamond = false,
}

-- ===== Helpers =====
local function getHRP()
    local char = player.Character or player.CharacterAdded:Wait()
    return char:WaitForChild("HumanoidRootPart")
end

local function getMapShopPart(modelName)
    local mapShop = workspace.Map:FindFirstChild("MapShop")
    if not mapShop then return nil end
    local model = mapShop:FindFirstChild(modelName)
    if not model then return nil end
    return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
end

local function getEggPart(eggName)
    local idx = EGG_HOLDER_INDEX[eggName]
    if not idx then return nil end
    local holders = workspace.Map:FindFirstChild("Island") and workspace.Map.Island:FindFirstChild("EggHolders")
    if not holders then return nil end
    local holder = holders:FindFirstChild(tostring(idx))
    if not holder then return nil end
    return holder:FindFirstChild("Part")
end

local function getMyPlotModel()
    local plotsFolder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Plots")
    if not plotsFolder then return nil end
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        local owner = plot:GetAttribute("Owner") or plot:GetAttribute("owner")
        if owner == player.UserId or tostring(owner) == tostring(player.UserId) then
            return plot
        end
    end
    return nil
end

local function getPlotCFrame()
    local plot = getMyPlotModel()
    if not plot then return nil end
    local part = plot.PrimaryPart or plot:FindFirstChildWhichIsA("BasePart", true)
    if part then return part.CFrame + Vector3.new(0, 3, 0) end
    local spawn = plot:FindFirstChild("Spawn")
    if spawn and spawn:IsA("BasePart") then return spawn.CFrame end
    return nil
end

local function getRestockSeconds(shopName)
    local ok, label = pcall(function()
        return player.PlayerGui.Main.Canvas.MapShops[shopName].Holder.Timer.TextLabel
    end)
    if not ok or not label then return nil end
    local min, sec = label.Text:match("(%d+):(%d+)")
    if not min or not sec then return nil end
    return tonumber(min) * 60 + tonumber(sec)
end

local function getInventoryCount()
    local ok, counter = pcall(function()
        return player.PlayerGui.Main.Canvas.Inventory.MainFrame.Counter
    end)
    if not ok or not counter then return 0 end
    local current = counter.Text:match("(%d+)/")
    return tonumber(current) or 0
end

-- PotionUpdater
local ownedPotionCounts = {}
if PotionUpdater then
    PotionUpdater.OnClientEvent:Connect(function(event, data)
        if event == "Update" and type(data) == "table" then
            for name, info in pairs(data) do
                if type(info) == "table" and info.Owned ~= nil then
                    ownedPotionCounts[name] = tonumber(info.Owned) or 0
                elseif type(info) == "number" then
                    ownedPotionCounts[name] = info
                end
            end
        end
    end)
    pcall(function() PotionUpdater:FireServer("Request") end)
end

local function getOwnedPotions()
    local owned = {}
    for name, count in pairs(ownedPotionCounts) do
        if count > 0 then table.insert(owned, name) end
    end
    if #owned > 0 then return owned end
    local ok, holder = pcall(function()
        return player.PlayerGui.Main.Canvas.Potions.Holder.Holder
    end)
    if ok and holder then
        for _, entry in ipairs(holder:GetChildren()) do
            local nameLabel = entry:FindFirstChild("NameLabel")
            local ownedLabel = entry:FindFirstChild("OwnedLabel")
            if nameLabel and ownedLabel then
                local count = tonumber(ownedLabel.Text:match("(%d+)"))
                if count and count > 0 then table.insert(owned, nameLabel.Text) end
            end
        end
    end
    return owned
end

-- ===== Pinning System =====
local pinned = false
local pinTarget = nil
-- Mover mutex: only ONE mover (a scheduler action or Auto Equip Best) may
-- hold the pin at a time. Without it, Auto Egg teleports back to the egg
-- right after equip best teleports to the plot, so EquipBest ends up firing
-- while the player is at the egg instead of at the base.
local pinBusy = false

local function pinTo(cframe)
    -- Wait for the current mover to fully finish (pin -> unpin) before
    -- taking over, so equip best completes at the plot first and only then
    -- gets teleported back to whatever job was in progress (e.g. eggs).
    while pinBusy do
        task.wait(0.05)
    end
    pinBusy = true
    pinTarget = cframe
    pinned = true
end

local function unpin()
    pinned = false
    pinTarget = nil
    pinBusy = false
end

RunService.Heartbeat:Connect(function()
    if pinned and pinTarget then
        local ok, hrp = pcall(getHRP)
        if ok then
            hrp.CFrame = pinTarget
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end
    end
end)

-- ===== Buy Actions =====
local function buyDice()
    local part = getMapShopPart("Shop")
    if not part then return end
    pinTo(part.CFrame)
    task.wait(TELEPORT_SETTLE_DELAY)
    local elapsed = 0
    while elapsed < BUY_STAND_DURATION do
        pcall(function() BuyDice:FireServer("BuyBestAvailable") end)
        task.wait(BUY_FIRE_INTERVAL); elapsed = elapsed + BUY_FIRE_INTERVAL
    end
    unpin()
end

local function buyPotion()
    local part = getMapShopPart("PotionShop")
    if not part then return end
    pinTo(part.CFrame)
    task.wait(TELEPORT_SETTLE_DELAY)
    local elapsed = 0
    while elapsed < BUY_STAND_DURATION do
        pcall(function() BuyPotion:FireServer("BuyBestAvailable") end)
        task.wait(BUY_FIRE_INTERVAL); elapsed = elapsed + BUY_FIRE_INTERVAL
    end
    unpin()
end

local function getFoodCartModel()
    local mapShop = workspace.Map:FindFirstChild("MapShop")
    return mapShop and mapShop:FindFirstChild("FoodCart")
end

local function buyFoodCart()
    local cart = getFoodCartModel(); if not cart then return end
    local part = cart.PrimaryPart or cart:FindFirstChildWhichIsA("BasePart", true)
    if not part then return end
    pinTo(part.CFrame)
    task.wait(TELEPORT_SETTLE_DELAY)
    if not getFoodCartModel() then unpin(); return end
    for _, item in ipairs(FOOD_ORDER) do
        pcall(function() FoodCartRemote:FireServer("BuyAll", item) end)
        task.wait(0.15)
    end
    unpin()
end

local function getMerchantModel()
    local mapShop = workspace.Map:FindFirstChild("MapShop")
    return mapShop and mapShop:FindFirstChild("Merchant")
end

local function buyMerchant()
    local model = getMerchantModel(); if not model then return end
    local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
    if not part then return end
    pinTo(part.CFrame)
    task.wait(TELEPORT_SETTLE_DELAY)
    if not getMerchantModel() then unpin(); return end
    for _, cat in ipairs(MERCHANT_CATEGORIES) do
        for _, itemName in ipairs(cat.items) do
            pcall(function() MerchantRemote:FireServer("BuyAll", cat.name, itemName) end)
            task.wait(0.12)
        end
    end
    unpin()
end

local function openEgg()
    local part = getEggPart(state.selectedEgg)
    if not part then return end
    pinTo(part.CFrame)
    task.wait(TELEPORT_SETTLE_DELAY)

    -- Fire once and inspect the real response so we never blind-spam the
    -- Buy remote; pace the next attempt by the server-reported cooldown.
    local success, result = pcall(function()
        return EggInfo:InvokeServer("Buy", state.selectedEgg, state.eggQuantity)
    end)

    if success and result then
        if result.Success then
            -- Hatch succeeded: re-fire once purely to read back the cooldown
            local ok, res = pcall(function()
                return EggInfo:InvokeServer("Buy", state.selectedEgg, state.eggQuantity)
            end)
            if ok and res and res.Reason == "Cooldown" and res.RetryAfter then
                task.wait(res.RetryAfter + 0.1)
            else
                task.wait(0.85)
            end
        elseif result.Reason == "Cooldown" and result.RetryAfter then
            task.wait(result.RetryAfter + 0.1)
        else
            task.wait(0.85)
        end
    else
        task.wait(0.85)
    end

    unpin()
end

-- ===== Equip & Sell =====
local function equipBest()
    local cf = getPlotCFrame()
    if not cf then return end
    pinTo(cf)
    task.wait(TELEPORT_SETTLE_DELAY)
    pcall(function() EquipBest:FireServer() end)
    task.wait(EQUIP_BEST_SETTLE)
    -- Small delay: keep the player at the plot before the next teleport
    -- (e.g. back to the egg) is allowed, so the equip best takes effect here.
    task.wait(EQUIP_BEST_HOLD)
    unpin()
end

local function sellInventory()
    equipBest()
    local part = getMapShopPart("SellShop")
    if not part then return end
    pinTo(part.CFrame)
    task.wait(TELEPORT_SETTLE_DELAY)
    pcall(function() Dialogue:InvokeServer("SellNpc", 1, "I want to sell my inventory", "preview") end)
    task.wait(1.5)
    pcall(function() Dialogue:InvokeServer("SellNpc", 1, "I want to sell my inventory", "commit") end)
    unpin()
end

-- ===== Fusion System =====
local lastClaimedJobId = nil
local stuckJobRetries = {}         -- [JobId] = retry count, so we don't hammer forever on a job our claim can't actually clear

local function getPlayerState()
    local ok, result = pcall(function()
        return EggInfo:InvokeServer("State")
    end)
    return ok and result or nil
end

local function getFusionState()
    local ok, result = pcall(function()
        return EggInfo:InvokeServer("GetFusionState")
    end)
    return ok and result or nil
end

local function fusePets(petIds, mode)
    local ok, result = pcall(function()
        return EggInfo:InvokeServer("Fuse", {
            PetIds = petIds,
            Mode = mode,
        })
    end)
    if not ok then
        return nil
    end
    return result
end

-- outcome is now actually passed in from the caller (was missing before,
-- which meant this always thought outcome==nil and skipped the Failed path)
local function claimFusion(jobId, outcome)
    if not jobId or jobId == lastClaimedJobId then return nil end

    local result

    if outcome == "Failed" then
        local ok, res = pcall(function()
            return EggInfo:InvokeServer("AcknowledgeFusion", {
                JobId = jobId,
            })
        end)
        if ok then result = res end
    else
        local ok, res = pcall(function()
            return EggInfo:InvokeServer("ClaimFusion", {
                JobId = jobId,
            })
        end)
        if ok then result = res end
    end

    if not result or result.Success == false then
        local ok2, res2 = pcall(function()
            if outcome == "Failed" then
                return EggInfo:InvokeServer("ClaimFusion", { JobId = jobId })
            else
                return EggInfo:InvokeServer("AcknowledgeFusion", { JobId = jobId })
            end
        end)
        if ok2 and res2 then
            result = res2
        end
    end

    -- Only mark as handled if we actually got a successful response — a job that
    -- both methods failed to clear should NOT be silently forgotten, or we'll
    -- just start firing new Fuse attempts that keep bouncing off FusionInProgress.
    if result and result.Success ~= false then
        lastClaimedJobId = jobId
        stuckJobRetries[jobId] = nil
    else
        stuckJobRetries[jobId] = (stuckJobRetries[jobId] or 0) + 1
        if stuckJobRetries[jobId] >= MAX_STUCK_RETRIES then
            lastClaimedJobId = jobId -- stop retrying this specific job, but don't pretend it succeeded
        end
    end

    return result
end

local function findFusableGroups(playerState, minCount, variantFilter)
    minCount = minCount or 6
    local groups = {}
    local pets = playerState and playerState.Pets
    if not pets then return {} end

    for _, pet in pairs(pets) do
        if type(pet) == "table" and pet.Name and pet.Id
            and not pet.Equipped and not pet.Favorited then
            if not variantFilter or pet.Variant == variantFilter then
                local name = pet.Name
                if not groups[name] then
                    groups[name] = { name = name, ids = {}, count = 0 }
                end
                table.insert(groups[name].ids, pet.Id)
                groups[name].count = groups[name].count + 1
            end
        end
    end

    local fusable = {}
    for _, group in pairs(groups) do
        if group.count >= minCount then
            table.insert(fusable, group)
        end
    end
    table.sort(fusable, function(a, b) return a.count > b.count end)
    return fusable
end

local function teleportToFuseMachine()
    local part = workspace:FindFirstChild("Map")
        and workspace.Map:FindFirstChild("Island")
        and workspace.Map.Island:FindFirstChild("FuseMachine")
        and workspace.Map.Island.FuseMachine:FindFirstChild("Machine")
        and workspace.Map.Island.FuseMachine.Machine:FindFirstChild("Machine Plinth")

    if part and part:IsA("BasePart") then
        pinTo(part.CFrame + Vector3.new(0, 5, 0))
    else
        pinTo(FUSE_MACHINE_CFRAME)
    end
    task.wait(TELEPORT_SETTLE_DELAY)
end

-- Starts a fuse: Golden needs 6 matching Normal pets, Diamond needs just 1 Golden pet.
-- Quick action (teleport, fire, done) — same shape as buyMerchant/buyFoodCart, meant
-- to be called from the unified scheduler below, not as a standalone loop.
local function startFuse(variantFilter, mode)
    local minCount = (mode == "Diamond") and 1 or 6
    local playerState = getPlayerState()
    if not playerState then return false end

    local groups = findFusableGroups(playerState, minCount, variantFilter)
    if #groups == 0 then return false end

    local group = groups[1]

    local petIds = {}
    for i = 1, minCount do
        table.insert(petIds, group.ids[i])
    end

    teleportToFuseMachine()
    local fuseResult = fusePets(petIds, mode)
    unpin()

    if fuseResult and fuseResult.Success ~= false then
        return true
    else
        return false
    end
end

-- Claims a ready job, and if eligible, immediately starts the next fuse before
-- handing control back to the scheduler (per your requested flow).
local function claimAndMaybeRefuse(jobId, outcome)
    teleportToFuseMachine()
    local result = claimFusion(jobId, outcome)
    task.wait(AFTER_CLAIM_COOLDOWN)
    unpin()

    local cleared = result and result.Success ~= false
    if cleared then
        if state.autoCraftGolden then
            startFuse("Normal", "Golden")
        end
        if state.autoCraftDiamond then
            startFuse("Golden", "Diamond")
        end
    end
end

-- ===== Unified Priority Scheduler =====
-- Merchant > FoodCart > Fusion (claim if ready, else start if eligible) >
-- Dice > Potion > Sell > Eggs. This is the ONLY loop that ever moves the
-- character, so there's no more cross-thread pin conflict with fusion.
-- Fusion check/action is quick (teleport, fire, done) so it fits the same
-- "one action per pass" shape as everything else — start a fuse, then this
-- loop naturally resumes dice/potion/etc while it cooks, and only comes
-- back to it once FUSION_CHECK_INTERVAL has passed and it's ready to claim.
local lastMerchant, lastFoodCart = nil, nil
local nextDiceTime, nextPotionTime = 0, 0
local nextFusionCheckTime = 0
task.spawn(function()
    while true do
        local ok = pcall(function()
            local didSomething = false
            local merchant = state.merchant and getMerchantModel()
            local foodcart = state.foodcart and getFoodCartModel()
            local sellReady = state.sell and getInventoryCount() >= state.sellThreshold
            local fusionEnabled = state.autoCraftGolden or state.autoCraftDiamond
            local fusionDue = fusionEnabled and tick() >= nextFusionCheckTime

            if merchant and merchant ~= lastMerchant then
                lastMerchant = merchant; buyMerchant(); didSomething = true
            elseif foodcart and foodcart ~= lastFoodCart then
                lastFoodCart = foodcart; buyFoodCart(); didSomething = true
            elseif fusionDue then
                local fs = getFusionState()
                local fusion = fs and fs.Fusion

                if fusion and fusion.Active and fusion.JobId and fusion.JobId ~= lastClaimedJobId then
                    local ready = fusion.Ready or (fusion.Remaining and fusion.Remaining <= 0)
                    if ready then
                        claimAndMaybeRefuse(fusion.JobId, fusion.Outcome)
                        didSomething = true
                        nextFusionCheckTime = tick() + FUSION_CHECK_INTERVAL
                    else
                        -- still cooking — check back around when it should finish
                        nextFusionCheckTime = tick() + math.min(fusion.Remaining or FUSION_CHECK_INTERVAL, FUSION_CHECK_INTERVAL)
                    end
                else
                    local started = false
                    if state.autoCraftGolden then
                        started = startFuse("Normal", "Golden")
                    end
                    if not started and state.autoCraftDiamond then
                        started = startFuse("Golden", "Diamond")
                    end
                    if started then
                        didSomething = true
                    end
                    nextFusionCheckTime = tick() + FUSION_CHECK_INTERVAL
                end
            elseif state.dice and tick() >= nextDiceTime then
                buyDice()
                local r = getRestockSeconds("Main")
                nextDiceTime = tick() + (r and (r + RESTOCK_BUFFER) or FALLBACK_RESTOCK_WAIT)
                didSomething = true
            elseif state.potion and tick() >= nextPotionTime then
                buyPotion()
                local r = getRestockSeconds("Potion")
                nextPotionTime = tick() + (r and (r + RESTOCK_BUFFER) or FALLBACK_RESTOCK_WAIT)
                didSomething = true
            elseif sellReady then
                sellInventory(); task.wait(SELL_COOLDOWN); didSomething = true
            elseif state.egg then
                openEgg(); didSomething = true
            end

            if not merchant then lastMerchant = nil end
            if not foodcart then lastFoodCart = nil end

            if not didSomething then
                task.wait(SCHEDULER_INTERVAL)
            end
        end)

        if not ok then
            unpin() -- release the pin/mover lock in case the action errored mid-teleport
            task.wait(SCHEDULER_INTERVAL)
        end
    end
end)

-- ===== Rebirth / Equip Loops =====
-- Auto Use Potions
task.spawn(function()
    while true do
        if state.usePotions then
            local owned = getOwnedPotions()
            for _, name in ipairs(owned) do
                pcall(function() UsePotion:FireServer("Use", name, "Max") end)
                task.wait(0.12)
            end
        end
        task.wait(USE_POTIONS_INTERVAL)
    end
end)

-- Auto Rebirth
local function isRebirthReady()
    local ok, btn = pcall(function() return player.PlayerGui.Main.Canvas.Rebirth.MainFrame.Rebirth end)
    if not ok or not btn then return false end
    local color = btn.BackgroundColor3
    return color.G > color.R
end

task.spawn(function()
    while true do
        if state.rebirth then
            local ok, ready = pcall(isRebirthReady)
            if ok and ready then
                RebirthRemote:FireServer()
                task.wait(REBIRTH_COOLDOWN)
            end
        end
        task.wait(REBIRTH_CHECK_INTERVAL)
    end
end)

-- Auto Equip Best
task.spawn(function()
    while true do
        if state.equipBest then
            local ok = pcall(equipBest)
            if not ok then
                unpin() -- release the mover lock if equip best errored mid-teleport
            end
        end
        task.wait(state.equipBestInterval)
    end
end)

-- Auto Equip Best Pet
task.spawn(function()
    while true do
        if state.autoEquipBestPet then
            pcall(function() EggInfo:InvokeServer("EquipSort", "Luck") end)
        end
        task.wait(5)
    end
end)

-- ===== Anti-AFK =====
local VirtualUser = game:GetService("VirtualUser")
player.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

-- ===== UI — Fluent Modded =====
local Window = Fluent:CreateWindow({
    Title       = "Buns hub",
    SubTitle    = "Kawaii Anime Rng",
    TabWidth    = 150,
    Size        = UDim2.fromOffset(520, 480),
    Acrylic     = true,
    Theme       = "Cyanic",
    MinimizeKey = Enum.KeyCode.LeftControl,
    Search      = true,
})

-- ===== Main Tab =====
local MainTab = Window:AddTab({ Title = "Main", Icon = "solar/home-bold" })

MainTab:AddToggle("AutoUsePotions", {
    Title = "Auto Use Potions", Default = false,
    Callback = function(v) state.usePotions = v end,
})
MainTab:AddToggle("AutoRebirth", {
    Title = "Auto Rebirth", Default = false,
    Callback = function(v) state.rebirth = v end,
})
MainTab:AddToggle("AutoEquipBest", {
    Title = "Auto Equip Best", Default = false,
    Callback = function(v) state.equipBest = v end,
})
MainTab:AddSlider("EquipBestInterval", {
    Title = "Equip Best Interval (s)", Default = 30, Min = 5, Max = 100, Rounding = 1,
    Callback = function(v) state.equipBestInterval = tonumber(v) or 30 end,
})
MainTab:AddToggle("AutoSell", {
    Title = "Auto Sell", Default = false,
    Callback = function(v) state.sell = v end,
})
MainTab:AddSlider("SellThreshold", {
    Title = "Sell Threshold", Default = 30, Min = 1, Max = 100, Rounding = 1,
    Callback = function(v) state.sellThreshold = tonumber(v) or 30 end,
})

-- ===== Shop Tab =====
local ShopTab = Window:AddTab({ Title = "Shop", Icon = "solar/cart-large-2-bold" })

ShopTab:AddToggle("AutoDice", {
    Title = "Auto Buy Dice", Default = false,
    Callback = function(v) state.dice = v end,
})
ShopTab:AddToggle("AutoPotion", {
    Title = "Auto Buy Potions", Default = false,
    Callback = function(v) state.potion = v end,
})
ShopTab:AddToggle("AutoMerchant", {
    Title = "Auto Merchant", Default = false,
    Callback = function(v) state.merchant = v end,
})
ShopTab:AddToggle("AutoFoodCart", {
    Title = "Auto FoodCart", Default = false,
    Callback = function(v) state.foodcart = v end,
})

-- ===== Eggs Tab =====
local EggTab = Window:AddTab({ Title = "Eggs", Icon = "solar/database-bold" })

EggTab:AddDropdown("EggType", {
    Title = "Egg Type", Values = EGG_NAMES, Default = "Basic", Multi = false,
    Callback = function(v) state.selectedEgg = v end,
})
EggTab:AddDropdown("EggQuantity", {
    Title = "Egg Quantity", Values = {"1", "2", "3", "4", "5"}, Default = "3", Multi = false,
    Callback = function(v) state.eggQuantity = tonumber(v) or 3 end,
})
EggTab:AddToggle("AutoEgg", {
    Title = "Auto Egg", Default = false,
    Callback = function(v) state.egg = v end,
})
EggTab:AddToggle("AutoEquipBestPet", {
    Title = "Auto Equip Best Pet", Default = false,
    Callback = function(v) state.autoEquipBestPet = v end,
})

EggTab:AddToggle("AutoCraftGolden", {
    Title = "Auto Craft Golden", Default = false,
    Callback = function(v) state.autoCraftGolden = v end,
})
EggTab:AddToggle("AutoCraftDiamond", {
    Title = "Auto Craft Diamond", Default = false,
    Callback = function(v) state.autoCraftDiamond = v end,
})

-- ===== Settings Tab =====
local SettingsTab = Window:AddTab({ Title = "Settings", Icon = "solar/settings-bold" })

-- ===== Floating Open/Close Icon =====
local FloatingButtonManager = Fluent.FloatingButtonManager

local OpenGui = Instance.new("ScreenGui")
OpenGui.Name = "BunsHubOpenUI"
OpenGui.ResetOnSpawn = false
OpenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
OpenGui.Parent = game:GetService("CoreGui")

local OpenBtn = Instance.new("ImageButton")
OpenBtn.Name = "OpenBtn"
OpenBtn.Size = UDim2.fromOffset(55, 55)
OpenBtn.Position = UDim2.new(0.02, 0, 0.85, 0)
OpenBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
OpenBtn.BackgroundTransparency = 0.15
OpenBtn.Image = "rbxassetid://117032319690583"   -- your ID
OpenBtn.ScaleType = Enum.ScaleType.Fit
OpenBtn.Parent = OpenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = OpenBtn

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(0, 200, 255)
stroke.Thickness = 1.5
stroke.Transparency = 0.4
stroke.Parent = OpenBtn

if FloatingButtonManager then
    FloatingButtonManager:SetLibrary(Fluent)
    FloatingButtonManager:SetFolder("BunsHub/Floating")
    FloatingButtonManager:AddButton("OpenBtn", OpenBtn, false, false)
end

OpenBtn.MouseButton1Click:Connect(function()
    if Window and Window.Minimize then
        Window:Minimize()
    end
end)

-- Drag support
local UserInputService = game:GetService("UserInputService")
local dragging, dragStart, startPos = false, nil, nil

OpenBtn.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = OpenBtn.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

OpenBtn.InputChanged:Connect(function(input)
    if (input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Touch) and dragging then
        local delta = input.Position - dragStart
        OpenBtn.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end)

-- ===== SaveManager / InterfaceManager =====
local SaveManager = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/StyearX/Fluent-modded/main/Addons/SaveManager.lua"
))()
local InterfaceManager = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/StyearX/Fluent-modded/main/Addons/InterfaceManager.lua"
))()

SaveManager:SetLibrary(Fluent)
InterfaceManager:SetLibrary(Fluent)

InterfaceManager:SetFolder("BunsHub")
SaveManager:SetFolder("BunsHub/Config")

InterfaceManager.Settings = {
    Theme       = "Cyanic",
    Acrylic     = true,
    Transparency = true,
    DisableBG   = false,
    Favorites   = {},
    Animated    = true,
    MenuKeybind = "LeftControl",
    Font        = "SourceSans",
}

pcall(function()
    InterfaceManager:SaveSettings()
    Fluent:SetTheme("Cyanic")
    InterfaceManager:ApplyFont("SourceSans")
end)

InterfaceManager:BuildInterfaceSection(SettingsTab)
SaveManager:IgnoreThemeSettings()
SaveManager:LoadAutoloadConfig()

local autoSaveThread
for idx, opt in pairs(SaveManager.Options) do
    if SaveManager.Parser[opt.Type] and not SaveManager.Ignore[idx] then
        local cb = opt.Callback
        opt.Callback = function(v)
            if cb then cb(v) end
            if autoSaveThread then task.cancel(autoSaveThread) end
            autoSaveThread = task.delay(0.5, function()
                pcall(function() SaveManager:Save("AutoSave") end)
            end)
        end
        if opt.OnChanged then
            local old = opt.OnChanged
            opt.OnChanged = function()
                if old then old() end
                pcall(function() SaveManager:Save("AutoSave") end)
            end
        end
    end
end

pcall(function()
    local autoPath = "BunsHub/Config/settings/autoload.txt"
    if not isfile(autoPath) then
        task.delay(1, function()
            pcall(function()
                SaveManager:Save("AutoSave")
                writefile(autoPath, "AutoSave")
            end)
        end)
    end
end)
