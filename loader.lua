if not game:IsLoaded() then
    game.Loaded:Wait()
end

local BASE = 'https://raw.githubusercontent.com/bunsasss/Buns-hub/main/games/'

local games = {
    [1005157018] = 'kawaiianimerng.lua',
    [1] = 'paintanimegirlbynumber.lua',
}   

local file = games[game.CreatorId]
if file then
    task.wait(math.random())
    loadstring(game:HttpGet(BASE .. file))()
end
