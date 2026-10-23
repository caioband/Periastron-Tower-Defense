local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer

--[[
	Points the camera at a random angle every time the character spawns, the first
	spawn and every respawn, in any mode.

	Only the angle changes: the default camera rebuilds its position from the
	current look direction each frame, so the zoom distance the player had stays.

	Deliberately disorienting: the pitch goes from almost straight down to looking
	up past the horizon (the default camera clamps at about 80 degrees either way,
	and pulls in when it would go under the ground), and the yaw always swings at
	least `MIN_YAW_SWING` away from where the camera was facing.
]]
local PITCH_RANGE = { -80, 35 }
local MIN_YAW_SWING = 90

-- How long to wait for the camera to switch to the new character before giving up.
local SUBJECT_TIMEOUT = 5

local SpawnCameraController = {}

local function randomBetween(range : { number }) : number
	return range[1] + math.random() * (range[2] - range[1])
end

function SpawnCameraController:randomize(character : Model)
	local humanoid = character:WaitForChild("Humanoid", SUBJECT_TIMEOUT)
	local root = character:WaitForChild("HumanoidRootPart", SUBJECT_TIMEOUT)
	if not humanoid or not root then return end

	local camera = workspace.CurrentCamera
	local deadline = os.clock() + SUBJECT_TIMEOUT
	while camera.CameraSubject ~= humanoid do
		if os.clock() > deadline or not character.Parent then return end
		RunService.RenderStepped:Wait()
	end

	-- One more frame, so the camera has snapped to the character before we turn it.
	RunService.RenderStepped:Wait()

	-- A cutscene or the tutorial owns a Scriptable camera; leave it alone.
	if camera.CameraType ~= Enum.CameraType.Custom or Player.Character ~= character then return end

	local focus = camera.Focus.Position
	local distance = (camera.CFrame.Position - focus).Magnitude
	local _, currentYaw = camera.CFrame:ToOrientation()
	local swing = randomBetween({ MIN_YAW_SWING, 360 - MIN_YAW_SWING })
	local yaw = currentYaw + math.rad(swing)
	local pitch = math.rad(randomBetween(PITCH_RANGE))

	camera.CFrame = CFrame.new(focus) * CFrame.fromOrientation(pitch, yaw, 0) * CFrame.new(0, 0, distance)
end

function SpawnCameraController:start()
	Player.CharacterAdded:Connect(function(character)
		self:randomize(character)
	end)

	if Player.Character then
		task.spawn(self.randomize, self, Player.Character)
	end
end

function SpawnCameraController:init()
end

return SpawnCameraController
