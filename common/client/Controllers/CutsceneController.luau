local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Toca cutscenes montadas no Moon Animator.

	Cada cena é um Model em ReplicatedStorage.Shared.Assets.Cutscenes:

		<NomeDaCena>              Model
		├── SceneReferenceCFrame  Part obrigatória — a cena é plantada onde ela
		│                         estiver; mover ela move a cena inteira
		├── RootPart              Part âncora do rig; define o espaço em que a
		│                         cena foi autorada
		├── CamPart               Part ligado ao RootPart por Motor6D — é o que
		│                         a animação move e o que a câmera segue
		├── AnimSaves             save do Moon Animator com o KeyframeSequence
		│                         da câmera; filho direto da cena
		├── FieldOfView           Folder (opcional)
		│   ├── default           NumberValue com o FOV base da cena
		│   └── Frames            Folder com um NumberValue por frame, nomeados
		│                         0, 1, 2, ...; opcional
		└── Actors                Folder (opcional)
		    └── <ator>            ObjectValue apontando pro rig, ou o Model do
		        └── <anim>        rig. A Animation é filha direta da entrada.

	Rig fora do Workspace entra clonado e sai destruído; rig que já vive no
	mundo é usado no lugar e devolvido à posição no fim.

	A câmera é lida direto do KeyframeSequence em vez de um AnimationId: a
	animação de câmera da EnterCutscene nunca foi publicada, e ler o save evita
	depender de upload. As animações dos atores são AnimationIds normais.

	Tudo é montado em espaço local relativo ao RootPart, então a cena inteira —
	câmera e atores — é plantada num CFrame só: o da SceneReferenceCFrame, ou o
	que for passado pra playCutscene.
--]]

local DEFAULT_CUTSCENE = "EnterCutscene"
local DEBUG_KEYBIND = Enum.KeyCode.L

local SCENE_REFERENCE = "SceneReferenceCFrame"
local ROOT_PART = "RootPart"
local CAMERA_PART = "CamPart"
local ANIM_SAVES = "AnimSaves"
local ACTORS_FOLDER = "Actors"
local FIELD_OF_VIEW_FOLDER = "FieldOfView"
local FOV_FRAMES_FOLDER = "Frames"
local BASE_FOV_VALUE = "default"

local FALLBACK_FOV = 70
-- Frames por segundo em que a faixa de FOV foi exportada (Moon Animator usa 60).
local FOV_TRACK_FPS = 60

local CutsceneController = {
	Controllers = {}
}

--[[
	Onde a cena vai ser plantada. É o CFrame da SceneReferenceCFrame, que toda
	cena precisa ter — mover ela move a cutscene inteira.
--]]
function CutsceneController:readSceneOrigin(asset: Instance)
	local reference = asset:FindFirstChild(SCENE_REFERENCE)
	if not reference then return nil end

	if reference:IsA("BasePart") then return reference.CFrame end
	if reference:IsA("CFrameValue") then return reference.Value end

	return nil
end

--[[
	Acha o save do Moon Animator da câmera.

	A busca é rasa de propósito: rig de ator costuma carregar o próprio AnimSaves
	junto, e uma busca recursiva pegaria a animação do ator no lugar da câmera.
--]]
function CutsceneController:findCameraSequence(asset: Instance)
	local saves = asset:FindFirstChild(ANIM_SAVES)
	local sequence = saves and saves:FindFirstChildWhichIsA("KeyframeSequence")

	return sequence or asset:FindFirstChildWhichIsA("KeyframeSequence")
end

--[[
	Monta a trilha da câmera a partir do KeyframeSequence salvo no asset.
	Devolve os keyframes em espaço local e a origem autoral da cena.
--]]
function CutsceneController:buildCameraTrack(asset: Instance)
	local sequence = self:findCameraSequence(asset)
	local rootPart = asset:FindFirstChild(ROOT_PART)
	if not sequence or not rootPart then return nil end

	local motor
	for _, joint in rootPart:GetChildren() do
		if joint:IsA("Motor6D") and joint.Part1 and joint.Part1.Name == CAMERA_PART then
			motor = joint
			break
		end
	end

	if not motor then return nil end

	local inverseC1 = motor.C1:Inverse()

	local keyframes = {}
	for _, keyframe in sequence:GetChildren() do
		local pose = keyframe:IsA("Keyframe") and keyframe:FindFirstChild(CAMERA_PART, true)
		if pose and pose:IsA("Pose") then
			table.insert(keyframes, {
				time = keyframe.Time,
				offset = motor.C0 * pose.CFrame * inverseC1,
			})
		end
	end

	if #keyframes < 2 then return nil end

	table.sort(keyframes, function(a, b) return a.time < b.time end)
	return keyframes, rootPart.CFrame
end

function CutsceneController:sampleCameraTrack(keyframes, elapsed: number)
	if elapsed <= keyframes[1].time then return keyframes[1].offset end

	local last = keyframes[#keyframes]
	if elapsed >= last.time then return last.offset end

	for i = 2, #keyframes do
		local to = keyframes[i]
		if elapsed <= to.time then
			local from = keyframes[i - 1]
			local span = to.time - from.time
			local alpha = span > 0 and (elapsed - from.time) / span or 0
			return from.offset:Lerp(to.offset, alpha)
		end
	end

	return last.offset
end

--[[
	Lê a pasta FieldOfView do asset.
	`default` é o FOV base; os NumberValue numerados dentro de Frames formam a
	faixa por frame. Sem faixa, o FOV fica travado no base durante a cutscene.
--]]
function CutsceneController:readFieldOfView(asset: Instance)
	local folder = asset:FindFirstChild(FIELD_OF_VIEW_FOLDER)
	if not folder then return FALLBACK_FOV, nil end

	local default = folder:FindFirstChild(BASE_FOV_VALUE)
	local baseFov = (default and default:IsA("NumberValue")) and default.Value or FALLBACK_FOV

	local frames = {}
	for _, value in (folder:FindFirstChild(FOV_FRAMES_FOLDER) or folder):GetChildren() do
		local index = tonumber(value.Name)
		if index and value:IsA("NumberValue") then
			table.insert(frames, { index = index, fov = value.Value })
		end
	end

	if #frames < 2 then return baseFov, nil end

	table.sort(frames, function(a, b) return a.index < b.index end)
	return baseFov, frames
end

function CutsceneController:sampleFieldOfView(frames, elapsed: number)
	local frame = elapsed * FOV_TRACK_FPS

	if frame <= frames[1].index then return frames[1].fov end

	local last = frames[#frames]
	if frame >= last.index then return last.fov end

	for i = 2, #frames do
		local to = frames[i]
		if frame <= to.index then
			local from = frames[i - 1]
			local span = to.index - from.index
			local alpha = span > 0 and (frame - from.index) / span or 0
			return from.fov + (to.fov - from.fov) * alpha
		end
	end

	return last.fov
end

--[[
	Coloca um ator em cena.

	ObjectValue: usa o rig que já vive no mundo e devolve ele ao lugar no fim.
	Model: clona o template e joga fora no fim.
	Nos dois casos o rig é posicionado relativo à origem da cena, então mover a
	cena move os atores junto.
--]]
function CutsceneController:playActor(entry: Instance, sessionMaid, origin: CFrame, authoredOrigin: CFrame)
	local rig
	if entry:IsA("ObjectValue") then
		rig = entry.Value
	elseif entry:IsA("Model") then
		rig = entry
	end

	if not rig then return end

	-- Rig guardado junto da cena é template; só o que já vive no mundo é usado
	-- no lugar.
	local isClone = not rig:IsDescendantOf(workspace)
	if isClone then
		rig = rig:Clone()
	end

	local animation = entry:FindFirstChildWhichIsA("Animation")
	if not animation then return end

	local animator = rig:FindFirstChildWhichIsA("Animator", true)
	if not animator then
		local host = rig:FindFirstChildWhichIsA("Humanoid") or rig:FindFirstChildWhichIsA("AnimationController")
		if not host then return end

		animator = Instance.new("Animator")
		animator.Parent = host
	end

	local offset = authoredOrigin:ToObjectSpace(rig:GetPivot())

	if isClone then
		sessionMaid:GiveTask(rig)
		rig.Parent = workspace
	else
		local previousPivot = rig:GetPivot()
		sessionMaid:GiveTask(function()
			rig:PivotTo(previousPivot)
		end)
	end

	rig:PivotTo(origin * offset)

	local track = animator:LoadAnimation(animation)
	track.Looped = false

	sessionMaid:GiveTask(function()
		track:Stop(0)

		-- O Animator para de escrever mas deixa o último Transform aplicado; sem
		-- zerar as juntas o rig congela na pose final da animação.
		for _, joint in rig:GetDescendants() do
			if joint:IsA("Motor6D") then
				joint.Transform = CFrame.identity
			end
		end
	end)

	track:Play(0)
end

function CutsceneController:playActors(asset: Instance, sessionMaid, origin: CFrame, authoredOrigin: CFrame)
	local folder = asset:FindFirstChild(ACTORS_FOLDER)
	if not folder then return end

	for _, entry in folder:GetChildren() do
		self:playActor(entry, sessionMaid, origin, authoredOrigin)
	end
end

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

function CutsceneController:construct()
	self.maid = Maid.new()
	self.player = Players.LocalPlayer
	self.cutsceneActive = false

	self.cutscenes = Shared:WaitForChild("Assets"):WaitForChild("Cutscenes")

	-- Sem isso o primeiro Play paga o download do asset e o ator entra atrasado.
	task.spawn(function()
		local animations = {}
		for _, descendant in self.cutscenes:GetDescendants() do
			if descendant:IsA("Animation") then
				table.insert(animations, descendant)
			end
		end

		if #animations > 0 then
			ContentProvider:PreloadAsync(animations)
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
	`origin` planta a cena em qualquer CFrame; sem ela, a cena vai pra onde a
	SceneReferenceCFrame estiver.
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

	local keyframes, authoredOrigin = self:buildCameraTrack(asset)
	if not keyframes then
		warn(string.format("[CutsceneController]: Cutscene %q has no usable camera track.", name))
		return nil
	end

	local sceneOrigin = origin or self:readSceneOrigin(asset)
	if not sceneOrigin then
		warn(string.format("[CutsceneController]: Cutscene %q has no %s part.", name, SCENE_REFERENCE))
		return nil
	end

	local duration = keyframes[#keyframes].time
	local baseFov, fovFrames = self:readFieldOfView(asset)

	self.cutsceneActive = true

	local sessionMaid = Maid.new()
	self.maid.CurrentCutscene = sessionMaid

	local camera = workspace.CurrentCamera
	local previousCameraType = camera.CameraType
	local previousCameraSubject = camera.CameraSubject
	local previousFieldOfView = camera.FieldOfView

	camera.CameraType = Enum.CameraType.Scriptable

	self:lockControls(sessionMaid)

	-- Os atores entram junto com o primeiro frame da câmera, sem fade.
	self:playActors(asset, sessionMaid, sceneOrigin, authoredOrigin)

	local elapsed = 0
	sessionMaid:GiveTask(RunService.RenderStepped:Connect(function(deltaTime)
		elapsed = math.min(elapsed + deltaTime, duration)
		camera.CFrame = sceneOrigin * self:sampleCameraTrack(keyframes, elapsed)
		camera.FieldOfView = fovFrames and self:sampleFieldOfView(fovFrames, elapsed) or baseFov
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
