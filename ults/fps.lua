-- =================================================================
-- CONFIG
-- =================================================================
local CONFIG = {
    TargetFPS      = 60,    -- FPS cap (set higher if your PC can handle it)
    LowQuality     = true,  -- Lowers Roblox graphics quality level (no effect on gameplay)
    NoShadows      = true,  -- Turns off global shadows + part shadow casting
    FlatWater      = true,  -- Removes water waves/reflections (terrain only)
    HideParticles  = false, -- Disables particles/trails/beams (visual only, but some games use them as indicators)
}

-- =================================================================
-- FPS BOOST (single function)
-- =================================================================
local function boostFPS()
    local Lighting = game:GetService("Lighting")
    local Terrain = workspace:FindFirstChildOfClass("Terrain")

    -- FPS cap
    if setfpscap then
        pcall(setfpscap, CONFIG.TargetFPS)
    end

    -- Safe rendering flags (only if your executor supports them)
    if setfflag then
        pcall(function()
            setfflag("DFIntTaskSchedulerTargetFps", tostring(CONFIG.TargetFPS))
            setfflag("FFlagDisablePostFx", "True")
        end)
    end

    -- Graphics quality
    if CONFIG.LowQuality then
        pcall(function()
            settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
        end)
    end

    -- Shadows
    if CONFIG.NoShadows then
        pcall(function() Lighting.GlobalShadows = false end)
        for _, v in ipairs(workspace:GetDescendants()) do
            if v:IsA("BasePart") then
                v.CastShadow = false
            end
        end
        workspace.DescendantAdded:Connect(function(v)
            if v:IsA("BasePart") then
                v.CastShadow = false
            end
        end)
    end

    -- Water
    if CONFIG.FlatWater and Terrain then
        pcall(function()
            Terrain.WaterWaveSize = 0
            Terrain.WaterWaveSpeed = 0
            Terrain.WaterReflectance = 0
        end)
    end

    -- Optional: particles
    if CONFIG.HideParticles then
        local function hide(v)
            if v:IsA("ParticleEmitter") or v:IsA("Trail") or v:IsA("Beam") then
                v.Enabled = false
            end
        end
        for _, v in ipairs(workspace:GetDescendants()) do hide(v) end
        workspace.DescendantAdded:Connect(hide)
    end
end

boostFPS()
