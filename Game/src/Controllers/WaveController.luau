local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local PathUtil = require(Shared.Util.PathUtil)

local Me = require(Vendor.Me)

local Framework = Me.new()

local ArrowConfig = SharedConfig.ArrowConfig
local ARROW_SPEED = ArrowConfig.Speed
local ARROW_COUNT = ArrowConfig.Count
local ARROW_STAGGER = ArrowConfig.Stagger
local ARROW_Y_OFFSET = ArrowConfig.YOffset
local ARROW_FLIP = false

local WaveController = {
	Controllers = {
		UILibraryController = {}
	}
}

function WaveController:spawnPathArrow(smooth)
	local template = Shared.Assets.Bricks:FindFirstChild("Arrow")
	if not template then return end

	local arrow = template:Clone()
	for _, p in ipairs(arrow:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.CastShadow = false
		end
	end
	arrow.Parent = workspace.CurrentCamera

	local dist = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if not arrow.Parent then
			conn:Disconnect()
			return
		end

		dist += ARROW_SPEED * dt
		if dist >= smooth.length then
			conn:Disconnect()
			arrow:Destroy()
			return
		end

		local pos = PathUtil.GetPositionAtDistance(smooth, dist)
		local ahead = PathUtil.GetPositionAtDistance(smooth, math.min(dist + 1.5, smooth.length))
		local dir = Vector3.new(ahead.X - pos.X, 0, ahead.Z - pos.Z)
		if dir.Magnitude < 1e-3 then
			dir = Vector3.new(0, 0, 1)
		end

		local p = Vector3.new(pos.X, pos.Y + ARROW_Y_OFFSET, pos.Z)
		local cf = CFrame.lookAt(p, p + dir.Unit)
		if ARROW_FLIP then
			cf = cf * CFrame.Angles(0, math.rad(180), 0)
		end
		arrow:PivotTo(cf)
	end)
end

function WaveController:playArrows()
	local pathScriptable = workspace:FindFirstChild("PathScriptable")
	local nodesFolder = pathScriptable and pathScriptable:FindFirstChild("Nodes")
	if not nodesFolder then return end

	-- Uma leva de setas por rota: num mapa com bifurcacao os dois lados sao
	-- sinalizados, senao o jogador so ve um deles.
	local routes = PathUtil.BuildRoutes(nodesFolder)

	task.spawn(function()
		for i = 1, ARROW_COUNT do
			for _, route in routes do
				if route.smooth.length > 0 then
					self:spawnPathArrow(route.smooth)
				end
			end
			if i < ARROW_COUNT then
				task.wait(ARROW_STAGGER)
			end
		end
	end)
end

function WaveController:playWaveSound()
	local sound = game:GetService("SoundService"):FindFirstChild("WaveStart")
	if sound and sound:IsA("Sound") then
		local clone = sound:Clone()
		clone.Parent = game:GetService("SoundService")
		clone:Play()
		clone.Ended:Once(function()
			clone:Destroy()
		end)
		task.delay(10, function()
			if clone and clone.Parent then clone:Destroy() end
		end)
	end
end

function WaveController:OnWave(num)
	self.Controllers.UILibraryController:doComponent("Wave", "set", num)
	self:playWaveSound()
	self:playArrows()
end

function WaveController:construct()
	Framework:Listen("SetWave", function(...) self:OnWave(...) end)

	-- Zera o contador sem som nem setas: nao e o comeco de uma wave, e a limpeza
	-- do round anterior.
	Framework:Listen("RoundRestarted", function()
		self.Controllers.UILibraryController:doComponent("Wave", "set", 0)
	end)

	Framework:Fire("Loaded", true)
end

function WaveController:start()

end

function WaveController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return WaveController
