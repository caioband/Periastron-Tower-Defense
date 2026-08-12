local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Vendor = ReplicatedStorage:WaitForChild("Vendor")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = Shared:WaitForChild("Assets")
local Animations = Assets:WaitForChild("Animations")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ClientConfig = require(Configs.Client)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Shared.Me)

local Framework = Me.new()

local ExampleController = {
	Controllers = {},
	Animations = {},
}

function ExampleController:createComponents(...)
	for _, component in script.Components:GetChildren() do
		if component:IsA("ModuleScript") then
			local requiredComponent = require(component)
			if requiredComponent and requiredComponent.begin then
				requiredComponent:begin(...)
			end
		end
	end
end

function ExampleController:getAnimation(animationName : string)
	return self.Animations[animationName]
end

function ExampleController:playAnimation(animationName : string, ...)
	return self:getAnimation(animationName):Play(...)
end

function ExampleController:loadAnimations(humanoid : Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = humanoid

	table.clear(self.Animations)
	for _, Animation in Animations:GetChildren() do
		if Animation:IsA("Animation") then
			self.Animations[Animation.Name] = animator:LoadAnimation(Animation)
		end
	end

	print("MovementController {Started}")

	return true
end

function ExampleController:destroyComponents()
	for _, component in script.Components:GetChildren() do
		if component:IsA("ModuleScript") then
			local requiredComponent = require(component)
			if requiredComponent and requiredComponent.stop then
				requiredComponent:stop()
			end
		end
	end

	print("MovementController {Destroyed}")
end

function ExampleController:construct()
	local function onCharacterDo()
		local character = Player.Character or Player.CharacterAdded:Wait()
		local humanoid = character:WaitForChild("Humanoid")

		humanoid.Died:Connect(function()
			self:destroyComponents()
		end)

		self:loadAnimations(humanoid)
		self:createComponents(character)

		local highlight = Instance.new("Highlight")
		highlight.FillTransparency = 1

		highlight.OutlineTransparency = 0
		highlight.OutlineColor = Color3.fromRGB(0, 0, 0)

		highlight.Parent = character
	end

	if Player.Character then
		onCharacterDo()
	end

	Player.CharacterAdded:Connect(onCharacterDo)
end

function ExampleController:start()

end

function ExampleController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	self:construct()
end

return ExampleController
