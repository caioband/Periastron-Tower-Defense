local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Util = Shared:WaitForChild("Util")

local CutsceneFormat = require(Util.CutsceneFormat)
local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

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

		O centro de coordenadas pode ser o World Pivot do Model em vez da Part: basta
		marcar o atributo UseWorldPivot na cena (ou não ter a Part). Ver
		readSceneReference.

	A câmera sai do rig, não da faixa `CFrame` do item de câmera. Aquela faixa
	guarda CFrames de mundo já bakeados na hora da exportação: se a cena for
	arrastada no Studio, as Parts andam e os valores bakeados ficam pra trás. O
	rig é C1 relativo à Part raiz, então acompanha a cena pra onde ela for.

	Não há AnimationId em lugar nenhum: as juntas são animadas escrevendo C1, do
	mesmo jeito que o Moon Animator faz no editor.
--]]

local DEFAULT_CUTSCENE = "EnterCutscene"

local SCENE_REFERENCE = "SceneReferenceCFrame"
local CAMERA_PART = "CamPart"

-- Nome do pedido ao InterfaceController: enquanto a cena roda, tela limpa.
local HIDE_REASON = "Cutscene"

-- Atributo na cena: liga pra usar o World Pivot do Model como centro, no lugar da
-- Part de referência.
local PIVOT_ATTRIBUTE = "UseWorldPivot"

local SCENE_FPS = 60

local RIG_R6 = "R6"
local RIG_R15 = "R15"

-- O que é vestido de um personagem em outro sem trocar Part nenhuma.
local APPEARANCE_CLASSES = {
	Shirt = true,
	Pants = true,
	ShirtGraphic = true,
	BodyColors = true,
}

-- Attachment que a gente teve que criar no rig leva essa marca, pra sair na volta.
local CREATED_ATTACHMENT = "CutsceneAttachment"

-- Onde procurar o ponto de encaixe quando o rig não tem a Part do personagem de
-- origem: um acessório de R15 preso no LeftUpperArm vai no "Left Arm" de um R6.
local PART_FALLBACKS = {
	UpperTorso = "Torso",
	LowerTorso = "Torso",
	LeftUpperArm = "Left Arm",
	LeftLowerArm = "Left Arm",
	LeftHand = "Left Arm",
	RightUpperArm = "Right Arm",
	RightLowerArm = "Right Arm",
	RightHand = "Right Arm",
	LeftUpperLeg = "Left Leg",
	LeftLowerLeg = "Left Leg",
	LeftFoot = "Left Leg",
	RightUpperLeg = "Right Leg",
	RightLowerLeg = "Right Leg",
	RightFoot = "Right Leg",

	Torso = "UpperTorso",
	["Left Arm"] = "LeftUpperArm",
	["Right Arm"] = "RightUpperArm",
	["Left Leg"] = "LeftUpperLeg",
	["Right Leg"] = "RightUpperLeg",
}

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
	Controllers = {
		InterfaceController = {},
	},

	Signals = {
		-- (frame : number, lastFrame : number, asset : Instance)
		-- Uma vez por frame da cena, com o frame já em número inteiro. Quem quiser
		-- disparar algo perto do fim compara com lastFrame.
		FrameReached = Signal.new(),
	},
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
		lastFrame = data.lastFrame,
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

--[[ APARÊNCIA ]]

--[[
	R6 ou R15, lido das Parts e não do Humanoid — rig de cutscene nem sempre traz um.
	Devolve nil pra Model que não é personagem.
--]]
function CutsceneController:readRigType(rig: Instance): string?
	if rig:FindFirstChild("UpperTorso") or rig:FindFirstChild("LowerTorso") then
		return RIG_R15
	end

	if rig:FindFirstChild("Torso") and rig:FindFirstChild("Head") then
		return RIG_R6
	end

	local humanoid = rig:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		return humanoid.RigType == Enum.HumanoidRigType.R15 and RIG_R15 or RIG_R6
	end

	return nil
end

--[[
	Os rigs de personagem de uma cena. `rigName` filtra por nome, pra cena com mais de
	um ator onde só um é o jogador.

		for _, entry in CutsceneController:getSceneRigs(cena) do
			print(entry.rig.Name, entry.rigType)   --> playerportal R6
		end
--]]
function CutsceneController:getSceneRigs(asset: Instance, rigName: string?)
	local rigs = {}

	for _, descendant in asset:GetDescendants() do
		if not descendant:IsA("Model") then continue end
		if rigName and descendant.Name ~= rigName then continue end

		local rigType = self:readRigType(descendant)
		if not rigType then continue end

		table.insert(rigs, {
			rig = descendant,
			rigType = rigType,
			humanoid = descendant:FindFirstChildWhichIsA("Humanoid"),
		})
	end

	return rigs
end

--[[
	A face de um personagem. `GetCharacterAppearanceAsync` devolve a Decal solta no
	modelo, o personagem vivo traz ela dentro da Head.
--]]
function CutsceneController:findFace(character: Instance): Decal?
	local head = character:FindFirstChild("Head")
	local decal = head and head:FindFirstChildWhichIsA("Decal")

	return decal or character:FindFirstChildWhichIsA("Decal")
end

--[[
	Copia o rosto: o id da Decal na Head do personagem vai pra Decal na Head do rig.

	É só isso, e serve pros dois tipos — R6 e R15 guardam o rosto do mesmo jeito, numa
	Decal na Head. Devolve a função que põe o id antigo de volta, ou nil quando um dos
	dois lados não tem Decal nenhuma.
--]]
function CutsceneController:copyFace(rig: Model, character: Instance): (() -> ())?
	local sourceFace = self:findFace(character)
	local rigFace = self:findFace(rig)

	if not sourceFace then
		warn(string.format("[CutsceneController]: %q has no face Decal in its Head to copy.", character.Name))
		return nil
	end

	if not rigFace then
		warn(string.format("[CutsceneController]: Rig %q has no face Decal in its Head.", rig.Name))
		return nil
	end

	local previousTexture = rigFace.Texture
	rigFace.Texture = sourceFace.Texture

	return function()
		rigFace.Texture = previousTexture
	end
end

--[[
	O ponto do rig onde um acessório se encaixa.

	Se o rig não tiver esse Attachment — um R6 não tem os pontos todos de um R15 — ele
	é criado a partir do mesmo ponto no personagem de origem, na mesma posição
	relativa, corrigida pela diferença de tamanho entre as duas Parts. Fica marcado
	pra sair depois.
--]]
function CutsceneController:findRigAttachment(rig: Model, name: string, source: Instance?): Attachment?
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("Attachment") and descendant.Name == name and descendant.Parent and descendant.Parent:IsA("BasePart") then
			return descendant
		end
	end

	if not source then return nil end

	for _, descendant in source:GetDescendants() do
		if not descendant:IsA("Attachment") or descendant.Name ~= name then continue end

		local sourcePart = descendant.Parent
		if not sourcePart or not sourcePart:IsA("BasePart") then continue end

		local fallback = PART_FALLBACKS[sourcePart.Name]
		local rigPart = rig:FindFirstChild(sourcePart.Name) or (fallback and rig:FindFirstChild(fallback))
		if not rigPart or not rigPart:IsA("BasePart") then continue end

		local rotation = descendant.CFrame - descendant.CFrame.Position
		local position = descendant.Position * (rigPart.Size / sourcePart.Size)

		local created = Instance.new("Attachment")
		created.Name = name
		created.CFrame = CFrame.new(position) * rotation
		created:SetAttribute(CREATED_ATTACHMENT, true)
		created.Parent = rigPart

		return created
	end

	return nil
end

--[[
	Pendura um acessório num rig. É o que o `AddAccessory` faz, na mão — e na mão
	porque o clone chega com a solda do personagem de origem dentro do Handle, e ela
	aponta pra fora do clone: pro Head do jogador de verdade. Era por isso que o
	acessório "não vinha", ele ia parar na cabeça do personagem, que a cutscene
	esconde.

	`source` é o personagem de onde o acessório saiu, usado só pra achar um ponto de
	encaixe que o rig não tenha.
--]]
function CutsceneController:weldAccessory(rig: Model, accessory: Instance, source: Instance?): boolean
	local handle = accessory:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then return false end

	for _, descendant in handle:GetDescendants() do
		if descendant:IsA("JointInstance") then
			descendant:Destroy()
		end
	end

	handle.Anchored = false
	handle.CanCollide = false
	handle.Massless = true

	local weld = Instance.new("Weld")
	weld.Name = "AccessoryWeld"
	weld.Part0 = handle

	local attachment = handle:FindFirstChildWhichIsA("Attachment")
	local target = attachment and self:findRigAttachment(rig, attachment.Name, source)

	if target then
		weld.Part1 = target.Parent
		weld.C0 = attachment.CFrame
		weld.C1 = target.CFrame
	else
		-- Acessório antigo, sem Attachment: o encaixe vem das propriedades dele.
		local head = rig:FindFirstChild("Head")
		if not head or not head:IsA("BasePart") or not accessory:IsA("Accoutrement") then
			weld:Destroy()
			return false
		end

		weld.Part1 = head
		weld.C0 = accessory.AttachmentPoint
		weld.C1 = CFrame.new(
			accessory.AttachmentPos.X, accessory.AttachmentPos.Y, accessory.AttachmentPos.Z,
			accessory.AttachmentRight.X, accessory.AttachmentUp.X, accessory.AttachmentForward.X,
			accessory.AttachmentRight.Y, accessory.AttachmentUp.Y, accessory.AttachmentForward.Y,
			accessory.AttachmentRight.Z, accessory.AttachmentUp.Z, accessory.AttachmentForward.Z
		)
	end

	weld.Parent = handle
	accessory.Parent = rig

	return true
end

--[[
	Veste um rig da cena com a aparência de um personagem: roupa, cores de corpo,
	face e acessórios. `source` é o Player (usa o Character dele, ou baixa a aparência
	se ele não tiver um na hora) ou um Model de personagem já pronto.

	Nada de Part é trocado — os MeshParts de pacote de um R15 ficam como estão. Trocar
	Part significaria destruir os Motor6D que a cena anima, e é a junta que carrega a
	animação inteira. Por isso um R15 vestido num rig R6 (ou o contrário) funciona:
	o que viaja é roupa, cor, face e acessório, que valem pros dois.

	Devolve uma função que desfaz tudo — o rig da cena é a instância original, então
	sem desfazer o próximo jogador entra no portal com a roupa do anterior. Chame
	antes do `playCutscene`: depois dele as juntas já foram lidas.
--]]
function CutsceneController:applyCharacter(rig: Model, source: Player | Model): (() -> ())?
	local appearance: Instance? = source :: any
	local temporary = false

	if typeof(source) == "Instance" and source:IsA("Player") then
		appearance = source.Character

		if not appearance then
			local success, result = pcall(function()
				return Players:GetCharacterAppearanceAsync(source.UserId)
			end)

			if not success or not result then
				warn(string.format("[CutsceneController]: Could not read the appearance of %s.", source.Name))
				return nil
			end

			appearance, temporary = result, true
		end
	end

	if not appearance then return nil end

	local restores = {}

	local function detach(instance: Instance)
		local parent = instance.Parent
		instance.Parent = nil

		table.insert(restores, function()
			instance.Parent = parent
		end)
	end

	local function attach(instance: Instance, parent: Instance)
		instance.Parent = parent

		table.insert(restores, function()
			instance:Destroy()
		end)
	end

	-- O que o rig já vestia sai de cena (sem ser destruído) e volta no fim.
	for _, child in rig:GetChildren() do
		if APPEARANCE_CLASSES[child.ClassName] or child:IsA("Accessory") then
			detach(child)
		end
	end

	-- BodyColors escreve a cor dentro das Parts: tirar o objeto depois não devolve o
	-- rig ao que era, então a cor de cada Part vai guardada na mão — e guardada aqui,
	-- antes das novas peças entrarem, pra na volta ser aplicada depois delas saírem.
	if appearance:FindFirstChildOfClass("BodyColors") then
		for _, descendant in rig:GetDescendants() do
			if not descendant:IsA("BasePart") then continue end

			local previous = descendant.Color
			table.insert(restores, function()
				descendant.Color = previous
			end)
		end
	end

	for _, child in appearance:GetChildren() do
		if APPEARANCE_CLASSES[child.ClassName] then
			attach(child:Clone(), rig)
		elseif child:IsA("Accoutrement") then
			local accessory = child:Clone()

			if self:weldAccessory(rig, accessory, appearance) then
				table.insert(restores, function()
					accessory:Destroy()
				end)
			else
				warn(string.format("[CutsceneController]: Could not attach %q to rig %q.", child.Name, rig.Name))
				accessory:Destroy()
			end
		end
	end

	local restoreFace = self:copyFace(rig, appearance)
	if restoreFace then
		table.insert(restores, restoreFace)
	end

	-- Ponto de encaixe que o rig não tinha e teve que ser criado sai junto.
	table.insert(restores, function()
		for _, descendant in rig:GetDescendants() do
			if descendant:IsA("Attachment") and descendant:GetAttribute(CREATED_ATTACHMENT) then
				descendant:Destroy()
			end
		end
	end)

	if temporary then
		appearance:Destroy()
	end

	return function()
		-- Ao contrário: os clones saem antes das cores e das peças originais voltarem.
		for index = #restores, 1, -1 do
			restores[index]()
		end
	end
end

--[[
	Veste de uma vez todos os rigs de uma cena (ou só o de nome `rigName`) e devolve
	uma função que desfaz tudo.
--]]
function CutsceneController:dressScene(asset: Instance, source: Player | Model, rigName: string?): () -> ()
	local restores = {}

	for _, entry in self:getSceneRigs(asset, rigName) do
		local restore = self:applyCharacter(entry.rig, source)
		if restore then
			table.insert(restores, restore)
		end
	end

	return function()
		for _, restore in restores do
			restore()
		end
	end
end

--[[ CONTROLE ]]

--[[
	Tira o mundo da frente enquanto a cena toca: billboard e highlight desligados,
	personagem invisível. Nada disso sai do cliente — `Enabled` e
	`LocalTransparencyModifier` escritos aqui não replicam — e tudo volta ao que era
	no cleanup do sessionMaid.
--]]
function CutsceneController:hideWorld(sessionMaid)
	local function hideGui(instance: Instance)
		if not instance:IsA("BillboardGui") and not instance:IsA("Highlight") then return end
		if not instance.Enabled then return end

		instance.Enabled = false
		sessionMaid:GiveTask(function()
			if instance.Parent then
				instance.Enabled = true
			end
		end)
	end

	for _, descendant in workspace:GetDescendants() do
		hideGui(descendant)
	end

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then continue end

		for _, descendant in character:GetDescendants() do
			-- A face é Decal: esconder só as Parts deixaria ela flutuando.
			if descendant:IsA("BasePart") or descendant:IsA("Decal") then
				local previous = descendant.LocalTransparencyModifier
				descendant.LocalTransparencyModifier = 1

				sessionMaid:GiveTask(function()
					descendant.LocalTransparencyModifier = previous
				end)
			else
				hideGui(descendant)
			end
		end
	end
end

--[[
	Tira a interface da frente enquanto a cena toca — as GUIs do jogo e as da própria
	Roblox, chat e topbar incluídos.

	A interface volta com a **cena**, e não com a câmera: quem recebe é sempre o
	sessionMaid, mesmo no `holdCamera`, onde o controle do personagem fica preso mais
	tempo. Acabou a cena, acabou o motivo de a tela estar limpa. No portal isso cai
	atrás do flash branco, que a essa altura já está cobrindo tudo.

	Não é `Enabled = false` na mão em cada uma: quem faz isso é o InterfaceController,
	que é o mesmo que o painel de mapas usa. Sem esse meio de campo os dois se
	desfariam — fechar o painel devolveria a interface no meio da cutscene.

	ScreenGui marcada com `IgnoreInterfaceHide` fica: é o caso do flash branco do
	portal, que nasce no fim da cena justamente para cobrir a tela.
--]]
function CutsceneController:hideInterface(sessionMaid)
	local InterfaceController = self.Controllers.InterfaceController
	if not InterfaceController then return end

	InterfaceController:Hide(HIDE_REASON, { HideCore = true })
	sessionMaid:GiveTask(function()
		InterfaceController:Show(HIDE_REASON)
	end)
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

--[[
	O centro de coordenadas da cena, lido ao vivo: arrastar a cena no Studio move a
	referência junto com o resto, e a cutscene vai junto.

	São dois modos:

	- **Part** (padrão): a `SceneReferenceCFrame`.
	- **World Pivot**: o pivô do próprio Model, o que a ferramenta Editar Pivô do
	  Studio move. Liga marcando o atributo `UseWorldPivot` na cena — ou simplesmente
	  não tendo a Part.

	O pivô só é confiável quando é de verdade: `GetPivot()` cai no centro da bounding
	box quando o Model não tem `WorldPivot` definido nem `PrimaryPart`, e esse centro
	anda junto com os rigs, ou seja, muda de uma tocada pra outra. Numa cena que vai
	de pivô, defina o pivô na mão no Studio ou deixe uma PrimaryPart.
--]]
function CutsceneController:readSceneReference(asset: Instance)
	if asset:GetAttribute(PIVOT_ATTRIBUTE) ~= true then
		local reference = asset:FindFirstChild(SCENE_REFERENCE)

		if reference then
			if reference:IsA("BasePart") then return reference.CFrame end
			if reference:IsA("CFrameValue") then return reference.Value end
		end
	end

	if asset:IsA("PVInstance") then
		return asset:GetPivot()
	end

	return nil
end

--[[
	Leva a cena inteira pra `origin`: quem vai parar lá é a referência da cena (a Part
	ou o World Pivot), o resto acompanha. Devolve o pivô de onde a cena saiu, pra quem
	chamou poder colocá-la de volta, ou nil se a cena não tem referência nenhuma.
--]]
function CutsceneController:placeScene(asset: PVInstance, origin: CFrame): CFrame?
	local reference = self:readSceneReference(asset)
	if not reference then return nil end

	local previousPivot = asset:GetPivot()
	asset:PivotTo(origin * reference:ToObjectSpace(previousPivot))

	return previousPivot
end

function CutsceneController:construct()
	self.maid = Maid.new()
	self.player = Players.LocalPlayer
	self.cutsceneActive = false
	self.cameraHold = nil
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
end

function CutsceneController:stopCutscene()
	self.maid.CurrentCutscene = nil
end

--[[
	Devolve a câmera e o controle que o `holdCamera` segurou. Sem hold em andamento
	não faz nada, então pode ser chamado por garantia.
--]]
function CutsceneController:releaseCamera()
	local hold = self.cameraHold
	if not hold then return end

	self.cameraHold = nil
	hold:DoCleaning()
end

--[[
	Se a câmera está parada no fim de uma cena esperando alguém devolvê-la.
--]]
function CutsceneController:isCameraHeld(): boolean
	return self.cameraHold ~= nil
end

--[[
	Toca uma cutscene e devolve a duração dela, ou nil se não deu pra tocar.

	`cutscene` é o nome da cena dentro de Assets.Cutscenes ou a própria instância —
	quem já tirou a cena da ReplicatedStorage (o portal leva a original pro mundo)
	passa ela direto. `origin` é onde a referência da cena vai parar; sem ela, a cena
	toca onde estiver montada.

	`holdCamera` deixa a câmera onde a cena terminou, em Scriptable e no CFrame do
	último frame, com o controle do personagem ainda preso. É pra quem vai tirar o
	jogador do lugar logo depois (o portal, atrás do flash) e não quer a câmera
	voltando pro ombro dele no meio. Chame `releaseCamera` pra desfazer — no portal
	isso só acontece se o teleporte falhar.
--]]
function CutsceneController:playCutscene(cutscene: (string | Instance)?, origin: CFrame?, holdCamera: boolean?)
	if self.cutsceneActive then return nil end

	local asset, name
	if typeof(cutscene) == "Instance" then
		asset, name = cutscene, cutscene.Name
	else
		-- construct() pode ainda estar esperando os Assets replicarem.
		if not self.cutscenes then return nil end

		name = cutscene or DEFAULT_CUTSCENE
		asset = self.cutscenes:FindFirstChild(name)
	end

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
		warn(string.format("[CutsceneController]: Cutscene %q has neither a %s part nor a pivot to measure from.", name, SCENE_REFERENCE))
		return nil
	end

	self.cutsceneActive = true

	local sessionMaid = Maid.new()
	self.maid.CurrentCutscene = sessionMaid

	-- Segurar a câmera significa que ela não é devolvida no fim da cena: o controle
	-- do mundo e o que a câmera está olhando ficam de posse do holdMaid, que só é
	-- aberto por releaseCamera.
	local holdMaid = holdCamera and Maid.new() or nil
	if holdMaid then
		self:releaseCamera()
		self.cameraHold = holdMaid
	end

	local camera = workspace.CurrentCamera
	local previousCameraType = camera.CameraType
	local previousCameraSubject = camera.CameraSubject
	local previousFieldOfView = camera.FieldOfView

	camera.CameraType = Enum.CameraType.Scriptable

	self:lockControls(holdMaid or sessionMaid)
	self:hideInterface(sessionMaid)
	self:hideWorld(sessionMaid)

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
	local lastFrame = scene.lastFrame
	local elapsed = 0
	local firedFrame = -1

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

		-- Um aviso por frame da cena, não por frame de render.
		local reached = math.floor(frame)
		if reached > firedFrame then
			firedFrame = reached
			self.Signals.FrameReached:Fire(reached, lastFrame, asset)
		end
	end))

	sessionMaid:GiveTask(function()
		self.cutsceneActive = false

		if holdMaid then
			-- A cena acabou mas a câmera fica: parada no último frame, que é o que o
			-- portal quer atrás do flash. Quem devolve é releaseCamera.
			camera.CFrame = cameraBase * self:sampleTrack(cameraTrack, lastFrame):Inverse()

			holdMaid:GiveTask(function()
				camera.CameraType = previousCameraType
				camera.CameraSubject = previousCameraSubject
				camera.FieldOfView = previousFieldOfView
			end)

			return
		end

		camera.CameraType = previousCameraType
		camera.CameraSubject = previousCameraSubject
		camera.FieldOfView = previousFieldOfView
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
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return CutsceneController
