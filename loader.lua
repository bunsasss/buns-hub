if not game:IsLoaded() then
    game.Loaded:Wait()
end

local BASE = 'https://raw.githubusercontent.com/bunsasss/buns-hub/refs/heads/main/games/'

local games = {
    [104263864475588] = 'kawaiianimerng.lua',
    [129300814231343] = 'animegirlpaintbynumbers.lua',
}   

local file = games[game.CreatorId]
if file then
    task.wait(math.random())
    loadstring(game:HttpGet(BASE .. file))()
end
