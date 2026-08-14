local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Util = Shared:WaitForChild("Util")

local CutsceneFormat = require(Util.CutsceneFormat)
local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Player das cutscenes do Moon Animator.

	A leitura do arquivo mora em Shared.Util.CutsceneFormat, que entende tanto a
	árvore de Folders exportada quanto o blob comprimido. Aqui fica só o que
	precisa de instância viva e de frame a frame.

		<NomeDaCena>              Model
		├── SceneReferenceCFrame  Part — o centro de coordenadas da cena. Tudo é
		│                         medido a partir dela, e é ela que vai parar na
		│                         origem passada pra playCutscene
		├── <rig da câmera>       uma Part raiz ligada à CamPart por Motor6D
		├── <rigs dos atores>     os Models que o Moon Animator anima
		├── SceneData             StringValue com o blob, depois do bake
		└── 1, 2, 3, ...          os Folders do save, se ainda não passou no bake

	A câmera sai do rig, não da faixa `CFrame` do item de câmera. Aquela faixa
	guarda CFrames de mundo já bakeados na hora da exportação: se a cena for
	arrastada no Studio, as Parts andam e os valores bakeados ficam pra trás. O
	rig é C1 relativo à Part raiz, então acompanha a cena pra onde ela for.

	Não há AnimationId em lugar nenhum: as juntas são animadas escrevendo C1, do
	mesmo jeito que o Moon Animator faz no editor.
--]]

local DEFAULT_CUTSCENE = "EnterCutscene"
local DEBUG_KEYBIND = Enum.KeyCode.L

local SCENE_REFERENCE = "SceneReferenceCFrame"
local CAMERA_PART = "CamPart"

local SCENE_FPS = 60

-- O Moon Animator usa nomes próprios pra dois estilos, e "Constant" não é um
-- estilo de tween: é degrau, o valor segura até a próxima key.
local CONSTANT_EASE = "Constant"
local EASE_ALIASES = {
	Expo = "Exponential",
	Circ = "Circular",
}

local EASING_STYLES = {}
for _, style in Enum.EasingStyle:GetEnumItems() do
	EASING_STYLES[style.Name] = style
end

local EASING_DIRECTIONS = {}
for _, direction in Enum.EasingDirection:GetEnumItems() do
	EASING_DIRECTIONS[direction.Name] = direction
end

local warnedEases = {}

local CutsceneController = {
	Controllers = {}
}

local function lerpValue(from, to, alpha: number)
	if typeof(from) == "CFrame" then
		return from:Lerp(to, alpha)
	end

	return from + (to - from) * alpha
end

--[[ CENA ]]

function CutsceneController:findMotor(root: Instance, partName: string)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Part1 and descendant.Part1.Name == partName then
			return descendant
		end
	end

	return nil
end

--[[
	Lê a cena uma vez e guarda o resultado: o dado vem do CutsceneFormat, e aqui
	resolvemos as instâncias vivas que ele não pode carregar.
--]]
function CutsceneController:parseScene(asset: Instance)
	local cached = self.scenes[asset]
	if cached then return cached end

	local data, source = CutsceneFormat.Read(asset)
	if not data then return nil end

	local motor = self:findMotor(asset, CAMERA_PART)
	if not motor or not motor.Part0 then return nil end

	local rigs = {}
	for _, entry in data.rigs do
		local rig = asset:FindFirstChild(entry.target) or workspace:FindFirstChild(entry.target)
		if rig and rig:IsA("Model") then
			table.insert(rigs, { rig = rig, joints = entry.joints })
		else
			warn(string.format("[CutsceneController]: Cutscene %q has no rig named %q.", asset.Name, entry.target))
		end
	end

	local scene = {
		cameraMotor = motor,
		cameraKeys = data.camera,
		cameraFov = data.fov,
		rigs = rigs,
		duration = data.lastFrame / SCENE_FPS,
		source = source,
	}

	self.scenes[asset] = scene
	return scene
end

--[[ AMOSTRAGEM ]]

function CutsceneController:easeAlpha(alpha: number, ease: string?)
	if not ease then return alpha end

	local name, direction = string.match(ease, "^([^|]+)|(.+)$")
	name = name or ease

	if name == "Linear" then return alpha end
	if name == CONSTANT_EASE then return 0 end

	local style = EASING_STYLES[EASE_ALIASES[name] or name]
	if not style then
		if not warnedEases[name] then
			warnedEases[name] = true
			warn(string.format("[CutsceneController]: Unknown Moon Animator ease %q, falling back to Linear.", name))
		end
		return alpha
	end

	return TweenService:GetValue(alpha, style, EASING_DIRECTIONS[direction or "In"] or Enum.EasingDirection.In)
end

--[[
	Amostra uma faixa. O cursor só anda pra frente, então o custo por frame é
	constante em vez de varrer a lista inteira.
--]]
function CutsceneController:sampleTrack(track, frame: number)
	local keys = track.keys
	local cursor = track.cursor

	while cursor < #keys and keys[cursor + 1].frame <= frame do
		cursor += 1
	end
	track.cursor = cursor

	local from = keys[cursor]
	local to = keys[cursor + 1]
	if not to or frame <= from.frame then return from.value end

	local span = to.frame - from.frame
	local alpha = span > 0 and (frame - from.frame) / span or 1
	return lerpValue(from.value, to.value, self:easeAlpha(alpha, to.ease))
end

--[[ ATORES ]]

--[[
	Coloca um rig em cena e devolve as juntas prontas pra receber C1 por frame.

	Rig guardado junto da cena é template: entra clonado e sai destruído. Rig que
	já vive no mundo é usado no lugar, com posição e C1 devolvidos no fim.
--]]
function CutsceneController:prepareRig(parsed, sessionMaid, origin: CFrame, reference: CFrame)
	local rig = parsed.rig
	local isClone = not rig:IsDescendantOf(workspace)
	if isClone then
		rig = rig:Clone()
	end

	local motors = {}
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Part1 then
			motors[descendant.Part1.Name] = descendant
		end
	end

	local tracks = {}
	for _, joint in parsed.joints do
		local motor = motors[joint.partName]
		if not motor then continue end

		local restC1 = motor.C1
		sessionMaid:GiveTask(function()
			motor.C1 = restC1
		end)

		table.insert(tracks, { motor = motor, keys = joint.keys, cursor = 1 })
	end

	local offset = reference:ToObjectSpace(rig:GetPivot())

	if isClone then
		sessionMaid:GiveTask(rig)
		rig.Parent = workspace
	else
		local restPivot = rig:GetPivot()
		sessionMaid:GiveTask(function()
			rig:PivotTo(restPivot)
		end)
	end

	rig:PivotTo(origin * offset)
	return tracks
end

--[[ CONTROLE ]]

function CutsceneController:lockControls(sessionMaid)
	local playerScripts = self.player:FindFirstChild("PlayerScripts")
	local playerModuleScript = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not playerModuleScript then return end

	local success, controls = pcall(function()
		return require(playerModuleScript):GetControls()
	end)

	if not success or not controls then return end

	controls:Disable()
	sessionMaid:GiveTask(function()
		controls:Enable()
	end)
end

--[[
	O centro de coordenadas da cena, lido ao vivo: arrastar a cena no Studio move
	essa Part junto com o resto, e a cutscene vai junto.
--]]
function CutsceneController:readSceneReference(asset: Instance)
	local reference = asset:FindFirstChild(SCENE_REFERENCE)
	if not reference then return nil end

	if reference:IsA("BasePart") then return reference.CFrame end
	if reference:IsA("CFrameValue") then return reference.Value end

	return nil
end

function CutsceneController:construct()
	self.maid = Maid.new()
	self.player = Players.LocalPlayer
	self.cutsceneActive = false
	self.scenes = {}

	self.cutscenes = Shared:WaitForChild("Assets"):WaitForChild("Cutscenes")

	-- Adianta a leitura pra primeira cutscene não pagar o parse.
	task.spawn(function()
		for _, asset in self.cutscenes:GetChildren() do
			self:parseScene(asset)
			task.wait()
		end
	end)
end

function CutsceneController:start()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == DEBUG_KEYBIND then
			self:playCutscene()
		end
	end)
end

function CutsceneController:stopCutscene()
	self.maid.CurrentCutscene = nil
end

--[[
	Toca uma cutscene e devolve a duração dela, ou nil se não deu pra tocar.
	`origin` é onde a SceneReferenceCFrame vai parar; sem ela, a cena toca onde
	estiver montada.
--]]
function CutsceneController:playCutscene(cutsceneName: string?, origin: CFrame?)
	if self.cutsceneActive then return nil end

	-- construct() pode ainda estar esperando os Assets replicarem.
	if not self.cutscenes then return nil end

	local name = cutsceneName or DEFAULT_CUTSCENE
	local asset = self.cutscenes:FindFirstChild(name)
	if not asset then
		warn(string.format("[CutsceneController]: No cutscene named %q in Assets.Cutscenes.", name))
		return nil
	end

	local scene = self:parseScene(asset)
	if not scene then
		warn(string.format("[CutsceneController]: Cutscene %q has no data or no rig driving a %q part.", name, CAMERA_PART))
		return nil
	end

	local reference = self:readSceneReference(asset)
	if not reference then
		warn(string.format("[CutsceneController]: Cutscene %q has no %s part.", name, SCENE_REFERENCE))
		return nil
	end

	self.cutsceneActive = true

	local sessionMaid = Maid.new()
	self.maid.CurrentCutscene = sessionMaid

	local camera = workspace.CurrentCamera
	local previousCameraType = camera.CameraType
	local previousCameraSubject = camera.CameraSubject
	local previousFieldOfView = camera.FieldOfView

	camera.CameraType = Enum.CameraType.Scriptable

	self:lockControls(sessionMaid)

	local sceneOrigin = origin or reference

	-- A câmera é a Part1 do Motor6D: Part0 * C0 * Transform * C1:Inverse(), com
	-- Transform parado. Tudo antes do C1 é constante, então resolve uma vez só.
	local motor = scene.cameraMotor
	local cameraBase = sceneOrigin * reference:ToObjectSpace(motor.Part0.CFrame * motor.C0)

	local cameraTrack = { keys = scene.cameraKeys, cursor = 1 }
	local fovTrack = scene.cameraFov and { keys = scene.cameraFov, cursor = 1 }

	local jointTracks = {}
	for _, parsed in scene.rigs do
		for _, track in self:prepareRig(parsed, sessionMaid, sceneOrigin, reference) do
			table.insert(jointTracks, track)
		end
	end

	local duration = scene.duration
	local elapsed = 0

	sessionMaid:GiveTask(RunService.RenderStepped:Connect(function(deltaTime)
		elapsed = math.min(elapsed + deltaTime, duration)
		local frame = elapsed * SCENE_FPS

		camera.CFrame = cameraBase * self:sampleTrack(cameraTrack, frame):Inverse()

		if fovTrack then
			camera.FieldOfView = self:sampleTrack(fovTrack, frame)
		end

		for _, track in jointTracks do
			track.motor.C1 = self:sampleTrack(track, frame)
		end
	end))

	sessionMaid:GiveTask(function()
		camera.CameraType = previousCameraType
		camera.CameraSubject = previousCameraSubject
		camera.FieldOfView = previousFieldOfView
		self.cutsceneActive = false
	end)

	task.delay(duration, function()
		if self.maid.CurrentCutscene == sessionMaid then
			self.maid.CurrentCutscene = nil
		end
	end)

	return duration
end

function CutsceneController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	self:construct()
end

return CutsceneController
