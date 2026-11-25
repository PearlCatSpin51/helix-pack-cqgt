-- Night Rider script
-- menu: FeatherLite (https://github.com/S2kh/FeatherLite)

if game.GameId ~= 10770284142 then return end

local FeatherLite = loadstring(game:HttpGet("https://raw.githubusercontent.com/S2kh/FeatherLite/main/FeatherLite.lua"))()

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local LP = Players.LocalPlayer

local G = getgenv()
if G.FeatherNightRider and G.FeatherNightRider.stop then pcall(G.FeatherNightRider.stop) end
local alive = true
local conns = {}
G.FeatherNightRider = {}

local function req(m) if not m then return nil end local ok, r = pcall(require, m) return ok and r or nil end
local Moto = RS:WaitForChild("Motorcycle", 30)
local Shared = RS:WaitForChild("GameShared", 30)
local Config = req(Moto:WaitForChild("Config", 15))
local Drive = req(Moto.Shared:WaitForChild("Drive", 15))
local BikeClient = req(Moto.Client:WaitForChild("BikeClient", 15))
local Chase = req(Moto.Client:WaitForChild("Chase", 15))
local Cops = req(Moto.Client:WaitForChild("Cops", 15))
local GameConfig = req(Shared:WaitForChild("GameConfig", 15)) or {}
local Remotes = Shared:WaitForChild("Remotes", 15)
local StuntRemote = Remotes and Remotes:WaitForChild("Stunt", 15)
local TrafficHit = Moto:WaitForChild("Remotes", 15) and Moto.Remotes:WaitForChild("TrafficHit", 15)
local Crash = Config and Config.Crash
local MPH = GameConfig.MPH or 0.62636
local STUNTS = GameConfig.Stunts or {}
local MIN_MPH = STUNTS.WheelieMinMph or 60
local CAP_SECONDS = (STUNTS.MaxSeconds or 30) - 0.5

local Window
local F = setmetatable({}, { __index = function(_, k)
    local el = Window and Window.Flags[k]
    if el then return el:Get() end
end })
local function on(sig, fn) local c = sig:Connect(fn) conns[#conns + 1] = c return c end

-- the bike you are riding, nil when walking
local function ride()
    local cur = BikeClient and BikeClient.current and BikeClient.current()
    if cur and not cur.thrown and cur.state and cur.bike and cur.bike.chassis then return cur end
end
local function mphOf(cur) return math.abs(cur.state.speed or 0) * MPH end
local function pitchOf(cur)
    local cf = cur.bike.chassis.CFrame
    local n = cur.state.groundN or Vector3.yAxis
    return math.deg(math.atan2(cf.LookVector:Dot(n), cf.UpVector:Dot(n)))
end

-- Never crash: the game checks Crash.FallOff every frame, so it always reads false while this is on
local NoCrash = { on = false, saved = {} }
function NoCrash.set(v)
    if not Crash or v == NoCrash.on then return end
    NoCrash.on = v
    if v then
        NoCrash.fallOff = rawget(Crash, "FallOff")
        rawset(Crash, "FallOff", nil)
        setmetatable(Crash, {
            __index = function(_, k) if k == "FallOff" then return false end end,
            __newindex = function(t, k, val) if k == "FallOff" then NoCrash.fallOff = val else rawset(t, k, val) end end,
        })
        NoCrash.saved.LoopTime = rawget(Crash, "LoopTime")
        rawset(Crash, "LoopTime", math.huge)
        if Crash.DeathWobble then
            NoCrash.saved.DW = Crash.DeathWobble.Enabled
            Crash.DeathWobble.Enabled = false
        end
    else
        setmetatable(Crash, nil)
        rawset(Crash, "FallOff", NoCrash.fallOff)
        rawset(Crash, "LoopTime", NoCrash.saved.LoopTime)
        if Crash.DeathWobble and NoCrash.saved.DW ~= nil then Crash.DeathWobble.Enabled = NoCrash.saved.DW end
    end
end

local origNamecall
origNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
    if alive and NoCrash.on and not checkcaller() and getnamecallmethod() == "FireServer" then
        if self == StuntRemote and (...) == "knock" then return nil end
        if self == TrafficHit then return nil end
    end
    return origNamecall(self, ...)
end))

-- Ghost traffic: only cop cars stay solid
local origTouchable = Chase and Chase.touchable
if origTouchable then
    Chase.touchable = function(...)
        local list = origTouchable(...)
        if not (alive and F.GhostTraffic) then return list end
        local cops = Chase.cars and Chase.cars() or {}
        local keep = {}
        for _, v in ipairs(list) do
            if v.model and cops[v.model] then keep[#keep + 1] = v end
        end
        return keep
    end
end

-- Perfect wheelie: holds the wheelie at the angle you pick
local Wheel = { lastEnd = 0 }
local origStep = Drive and Drive.step
if origStep then
    Drive.step = function(bike, state, input, dt, ...)
        local cur = alive and F.PerfectWheelie and ride()
        if cur and cur.state == state and type(input) == "table" and cur.wmode and not cur.wExit then
            local deg = pitchOf(cur)
            local chassis = cur.bike.chassis
            local rate = math.deg(chassis.AssemblyAngularVelocity:Dot(chassis.CFrame.RightVector))
            local target = F.WheelieAngle or 45
            local cmd = math.clamp((target - deg) * 3.5 - rate * 0.15, -70, 70)
            input.wheelieRate = math.rad(cmd)
            input.brake, input.rear, input.reverse = 0, 0, false
            local mph = mphOf(cur)
            if mph < MIN_MPH + 6 then
                input.throttle = math.max(input.throttle or 0, math.clamp((MIN_MPH + 8 - mph) / 8, 0.35, 1))
            end
            cur.loopT = 0
        end
        return origStep(bike, state, input, dt, ...)
    end
end

-- the game only pays 30 seconds per wheelie, so long wheelies get cashed in every 30 seconds
local function stuntsLoop()
    if Wheel.fn then return Wheel.fn end
    if os.clock() - (Wheel.scanned or 0) < 2 then return end
    Wheel.scanned = os.clock()
    for _, c in ipairs(getconnections(RunService.RenderStepped)) do
        local f = c.Function
        if f and islclosure(f) then
            local ok, ups = pcall(debug.getupvalues, f)
            if ok and ups and #ups == 20 and ups[1] == BikeClient and ups[13] == StuntRemote
                and type(ups[2]) == "number" and type(ups[3]) == "table" then
                Wheel.fn = f
                return f
            end
        end
    end
end
local function splitStunts()
    local f = stuntsLoop()
    if not f then return end
    local ui = debug.getupvalue(f, 3)
    local wheelieT = debug.getupvalue(f, 2)
    if type(wheelieT) == "number" and wheelieT >= CAP_SECONDS then
        StuntRemote:FireServer("wheelie", wheelieT)
        if ui and ui.endLive then pcall(ui.endLive, "wheelie", true) end
        debug.setupvalue(f, 2, 0)
    end
    local trick, trickT, onWheel = debug.getupvalue(f, 4), debug.getupvalue(f, 6), debug.getupvalue(f, 7)
    if trick and type(trickT) == "number" and trickT >= CAP_SECONDS then
        StuntRemote:FireServer("trick", trickT, trick, onWheel)
        if ui and ui.endLive then pcall(ui.endLive, "trick", true) end
        debug.setupvalue(f, 6, 0)
    end
end

-- starts wheelie mode, same as pressing Space
local function startWheelie(cur)
    cur.wmode = true
    cur.wExit = false
    cur.wT = 0
    cur.wRate = nil
    cur.wRateV = nil
    cur.loopT = 0
    cur.wTarget = Config.Wheelie and Config.Wheelie.ModeStart or 50
end

-- Escape: the game escapes you once the escape meter goes above 1
local function escapeChase()
    local cs = Cops and Cops.state
    if cs and cs.phase == "chase" then
        cs.evade = 5
        return true
    end
end

local wasWheelie = false
-- every frame: auto wheelie, no bust and auto escape
on(RunService.Heartbeat, function()
    if not alive then return end
    local cur = ride()
    if cur then
        if wasWheelie and not cur.wmode then Wheel.lastEnd = os.clock() end
        wasWheelie = cur.wmode == true
        if F.AutoWheelie and not cur.wmode and cur.state.grounded and not cur.state.pickup and not cur.state.crash
            and mphOf(cur) >= MIN_MPH and os.clock() - Wheel.lastEnd > 1
            and not UIS:IsKeyDown(Enum.KeyCode.S) and not UIS:GetFocusedTextBox() then
            startWheelie(cur)
        end
    end
    if F.PerfectWheelie or F.AutoWheelie then pcall(splitStunts) end
    local cs = Cops and Cops.state
    if cs and cs.phase == "chase" then
        if F.NoBust then cs.bust = 0 end
        if F.AutoEscape and (cs.cap or 0) > 0 and (cs.bounty or 0) >= cs.cap then escapeChase() end
    end
end)

-- menu
Window = FeatherLite:Window({ Title = "Night Rider", Folder = "FeatherLite/NightRider", Key = Enum.KeyCode.RightShift })
local gates = {}
local function gate(test, els) gates[#gates + 1] = { test = test, els = els } end

do
    local tab = Window:Tab({ Name = "Bike", Icon = "Player" })
    local crashes = tab:Group("Crashes")
    crashes:Toggle({ Name = "Never crash", Flag = "NeverCrash", Default = false,
        Description = "No falls, wipeouts, loop-outs or knocks. Your combo and lives always stay.",
        Callback = function(v) NoCrash.set(v == true) end })
    crashes:Toggle({ Name = "Ghost traffic", Flag = "GhostTraffic", Default = false,
        Description = "Ride straight through cars." })

    local wheelie = tab:Group("Wheelie")
    wheelie:Toggle({ Name = "Perfect wheelie", Flag = "PerfectWheelie", Default = false,
        Description = "Wheelie mode (Space) holds the angle below forever and stays above 60 mph. Space again or brake ends it." })
    gate("PerfectWheelie", {
        wheelie:Slider({ Name = "Wheelie angle", Flag = "WheelieAngle", Min = 15, Max = 75, Step = 1, Default = 45, Suffix = "°" }),
    })
    wheelie:Toggle({ Name = "Auto wheelie", Flag = "AutoWheelie", Default = false,
        Description = "Pops a wheelie whenever you're above 60 mph. Hold S to stay down." })
end

do
    local tab = Window:Tab({ Name = "Police", Icon = "Combat" })
    local chases = tab:Group("Chases")
    chases:Toggle({ Name = "Never get busted", Flag = "NoBust", Default = false,
        Description = "The bust meter never fills." })
    chases:Toggle({ Name = "Auto escape at max bounty", Flag = "AutoEscape", Default = false,
        Description = "Escapes as soon as the bounty hits the cap for your difficulty." })
    chases:Button({ Name = "Escape now", Callback = function()
        if not escapeChase() and Window then
            Window:Notify({ Title = "Night Rider", Text = "You're not in a chase.", Duration = 3 })
        end
    end })
end

do
    local tab = Window:Tab({ Name = "Misc", Icon = "Misc" })
    local community = tab:Group("Community")
    community:Paragraph({ Title = "Feather Discord", Text = "Found a bug or want a new feature? Join the Discord." })
    community:Button({ Name = "Copy Discord invite", Description = "https://discord.gg/CVqV9YnzUd", Callback = function()
        if setclipboard then
            pcall(setclipboard, "https://discord.gg/CVqV9YnzUd")
            Window:Notify({ Title = "Copied", Text = "Discord invite copied.", Duration = 3 })
        end
    end })
end

task.spawn(function()
    while alive do
        for _, g in ipairs(gates) do
            local onNow = F[g.test] == true
            for _, el in ipairs(g.els) do
                if el and el.SetLocked and (el.Locked == true) == (onNow == true) then pcall(el.SetLocked, el, not onNow) end
            end
        end
        task.wait(0.5)
    end
end)

-- turns everything off when the script is unloaded
local function stop()
    if not alive then return end
    alive = false
    for _, c in ipairs(conns) do pcall(c.Disconnect, c) end
    NoCrash.set(false)
    if origStep then Drive.step = origStep end
    if origTouchable then Chase.touchable = origTouchable end
end
G.FeatherNightRider.stop = function() stop() pcall(Window.Unload, Window) end
Window:OnUnload(stop)