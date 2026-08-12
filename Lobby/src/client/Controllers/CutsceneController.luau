local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Vendor = ReplicatedStorage:WaitForChild("Vendor")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ClientConfig = require(Configs.Client)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Shared.Me)

local Framework = Me.new()

local CutsceneController = {
	Controllers = {}
}

function CutsceneController:construct()
	self.maid = Maid.new()
	self.camera = workspace.CurrentCamera
	self.player = Players.LocalPlayer
	self.cutsceneActive = false

	self.cutsceneAsset = Shared:WaitForChild("Assets")
		:WaitForChild("Cutscenes")
		:WaitForChild("EnterCutscene")
end

function CutsceneController:start()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.L then
			self:playCutscene()
		end
	end)
end

function CutsceneController:playCutscene()
	print("attempt")
	if self.cutsceneActive then return end
	print("did go")
	local animationObject = self.cutsceneAsset:FindFirstChildWhichIsA("Animation")
	if not animationObject then return end
	print("animation found")
	self.cutsceneActive = true

	local sessionMaid = Maid.new()
	self.maid.CurrentCutscene = sessionMaid

	local modelClone = self.cutsceneAsset:Clone()
	sessionMaid:GiveTask(modelClone)

	modelClone.Parent = workspace

	local animationController = modelClone:WaitForChild("AnimationController")
	local animator = animationController:FindFirstChildWhichIsA("Animator") or Instance.new("Animator", animationController)
	local track = animator:LoadAnimation(animationObject)

	local camPart = modelClone:WaitForChild("CamPart")
	local fovPart = modelClone:WaitForChild("FovPart")
	local rootPart = modelClone:WaitForChild("RootPart")

	local oldCameraType = self.camera.CameraType
	self.camera.CameraType = Enum.CameraType.Scriptable

	print("test?")

	sessionMaid:GiveTask(RunService.RenderStepped:Connect(function()
		self.camera.CFrame = rootPart.CFrame

		local localOffset = rootPart.CFrame:ToObjectSpace(fovPart.CFrame).Position
--		self.camera.FieldOfView = math.clamp(math.abs(localOffset.Z), 1, 120)
	end))

	sessionMaid:GiveTask(function()
		track:Stop()
		self.camera.CameraType = oldCameraType
		self.camera.FieldOfView = 70
		self.cutsceneActive = false
	end)

	track:Play()

	task.spawn(function()
		track.Stopped:Wait()
		if self.maid.CurrentCutscene == sessionMaid then
			self.maid.CurrentCutscene = nil
		end
	end)
end

function CutsceneController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	self:construct()
end

return CutsceneController
