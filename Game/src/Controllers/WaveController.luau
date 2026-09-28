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

-- Track in SharedSounds.Musics that plays over the map music while the wave has
-- a boss.
local BOSS_MUSIC = "Boss"
local BOSS_MUSIC_FADE = 2

local WaveController = {
	Controllers = {
		UILibraryController = {},
		MusicController = {}
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

	task.spawn(function()
		-- One batch of arrows per route: on a map with a fork both sides are signaled,
		-- or the player only sees one of them. The wait comes before the build so no
		-- side is left out by half-finished replication.
		PathUtil.WaitForNodes(nodesFolder)
		local routes = PathUtil.BuildRoutes(nodesFolder)

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
	self.Controllers.MusicController:PlaySFX("WaveStart")
end

--[[
	Boss music. Push saves what was playing and Pop restores it, so the return gets
	the map music right whatever it is, and back-to-back boss waves do not stack.
]]
function WaveController:setWaveMusic(hasBoss : boolean?)
	local music = self.Controllers.MusicController

	if hasBoss then
		music:PushTrack(BOSS_MUSIC, BOSS_MUSIC_FADE)
	else
		music:PopTrack(BOSS_MUSIC_FADE)
	end
end

function WaveController:OnWave(num, hasBoss)
	self.Controllers.UILibraryController:doComponent("Wave", "set", num)
	self:setWaveMusic(hasBoss)
	self:playWaveSound()

	--[[
		The arrows only run on wave 1.

		They teach the path, and the path does not change from one wave to the next:
		repeated every wave they would just be `getArrowLeadTime` of idle waiting
		before each spawn. The server cuts that wait under the same condition (see
		`WaveService`), so both sides must agree on which wave it is.
	]]
	if num == 1 then
		self:playArrows()
	end
end

function WaveController:construct()
	Framework:Listen("SetWave", function(...) self:OnWave(...) end)

	-- Resets the counter with no sound or arrows: this is not the start of a wave, it
	-- is the previous round's cleanup. The boss music goes too: if the round ended on a
	-- boss wave, the next one starts with the map's.
	Framework:Listen("RoundRestarted", function()
		self.Controllers.UILibraryController:doComponent("Wave", "set", 0)
		self.Controllers.MusicController:PopTrack(BOSS_MUSIC_FADE)
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
