local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Assets = Shared:WaitForChild("Assets")

local GameClock = require(Shared.Util.GameClock)
local Me = require(Vendor.Me)

local Framework = Me.new()

local SuffocateAbilityController = {
	Controllers = {
		UnitPlacementController = {},
	},
	Tracks = setmetatable({}, { __mode = "v" }),
}

function SuffocateAbilityController:getTrack(unitId : string, animationName : string)
	local placement = self.Controllers.UnitPlacementController
	local class = placement and placement.classesById[unitId]
	if not class or not class.model or not class.model.Parent then
		return nil
	end

	class.loadedAnimations = class.loadedAnimations or {}

	local track = class.loadedAnimations[animationName]
	if track then
		return track
	end

	local animations = Assets:FindFirstChild("Animations")
	local shared = animations and animations:FindFirstChild(animationName)
	if not (shared and shared:IsA("Animation")) then
		return nil
	end

	local controller = class.model:FindFirstChildWhichIsA("AnimationController")
	local animator = controller and controller:FindFirstChildWhichIsA("Animator")
	if not animator then
		return nil
	end

	track = animator:LoadAnimation(shared)
	class.loadedAnimations[animationName] = track
	return track
end

function SuffocateAbilityController:start()
	for name in self.Controllers do
		self.Controllers[name] = Framework:Get(name)
	end

	Framework:Listen("UnitSuffocate", function(unitId, duration, animationName)
		if typeof(unitId) ~= "string" or typeof(animationName) ~= "string" then
			return
		end

		local track = self:getTrack(unitId, animationName)
		if not track then
			return
		end

		track.Priority = Enum.AnimationPriority.Action4
		track:Play(0.1)
		track:AdjustSpeed(GameClock.GetScale())
		self.Tracks[unitId] = track
	end)

	Framework:Listen("UnitSuffocateEnd", function(unitId)
		local track = self.Tracks[unitId]
		if track then
			track:Stop(0.2)
			self.Tracks[unitId] = nil
		end
	end)
end

function SuffocateAbilityController:init()
end

return SuffocateAbilityController