local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()
local Player = Players.LocalPlayer

--[[
	Passos do jogador, inteiramente no cliente.

	Quem dá o compasso é a animação, não um timer: as animações de Walk e Run
	carregam um Animation Event (KeyframeMarker) chamado "Step", e cada disparo
	dele vira um passo. Assim o som cai junto com o pé na tela em qualquer
	velocidade, e uma animação nova entra no sistema só por ter o marcador — não
	há lista de animações aqui pra manter.

	O marcador pode trazer um valor dizendo o pé ("Left" / "Right"); sem valor, o
	controller alterna sozinho.

	A superfície não vem do Material (o jogo é stud, o Material não significa
	nada): vem do atributo `Surface` da Part que o raio embaixo do pé acertar,
	procurado também nos pais dela — dá pra marcar um modelo inteiro de uma vez.
	Os ids de cada superfície ficam em SharedConfig.FootstepConfig.

	Fica em common/ porque o Me varre Controllers.Common nas duas places.
]]

local Config = SharedConfig.FootstepConfig

local MARKER = "Step"

-- Nomes de pé, em ordem de preferência: R15 primeiro, R6 depois, e o tronco
-- como último recurso (rig custom que não tenha nenhum dos dois).
local FOOT_PARTS = {
	Left = { "LeftFoot", "LeftLowerLeg", "Left Leg", "HumanoidRootPart" },
	Right = { "RightFoot", "RightLowerLeg", "Right Leg", "HumanoidRootPart" },
}

-- Log do marcador: só no Studio, para não poluir o console de produção.
local IS_STUDIO = RunService:IsStudio()

local function stepPrint(...)
	if not IS_STUDIO then return end
	print("[Footstep]", ...)
end

local FootstepController = {
	Controllers = {},
}

FootstepController._maid = nil
FootstepController._character = nil :: Model?
FootstepController._humanoid = nil :: Humanoid?
FootstepController._nextFoot = "Right"
FootstepController._lastStep = 0
FootstepController._lastJump = 0
FootstepController._lastId = {} :: { [string]: string } -- última variação por superfície
FootstepController._warned = {} :: { [string]: boolean }

--[[
	Sons prontos, um por (pé, id). O passo em si não cria nada: só escolhe a
	variação, ajusta pitch/volume e dá Play. Ver `_buildPool`.
]]
FootstepController._pool = {} :: { [string]: { [string]: Sound } }

-- Instâncias que existem só pra segurar os assets no cache do cliente.
FootstepController._warmFolder = nil :: Folder?

--[[
	Tracks que já têm escuta. O Animate padrão carrega a track uma vez e a toca de
	novo a cada vez que o jogador começa a andar, e `AnimationPlayed` dispara em
	toda tocada — sem isto, parar e andar de novo penduraria outra conexão na
	mesma track, e o marcador acabaria disparando N vezes por passo.
]]
FootstepController._boundTracks = setmetatable({}, { __mode = "k" }) :: any

--[[
	Quem pode mandar passo, e desde quando.

	Andar e correr tocam ao mesmo tempo: o `Animate` padrão mantém a walk no ar
	enquanto o Run do MovementController entra por cima (ele nunca para a walk).
	Se as duas animações têm o marcador, cada passo vira dois — em fases
	diferentes, porque as animações têm durações diferentes, então nem o intervalo
	mínimo segura.

	A regra: manda quem começou por último entre as tracks que têm marcador e
	ainda estão tocando. Assim o Run assume ao começar a correr e a walk retoma
	sozinha quando o Run para.
]]
FootstepController._markerTracks = setmetatable({}, { __mode = "k" }) :: any
FootstepController._trackStarted = setmetatable({}, { __mode = "k" }) :: any

--[[ AVISOS ]]

-- Um aviso por superfície por sessão: um passo repete demais pra avisar sempre.
function FootstepController:_warnOnce(key: string, message: string)
	if self._warned[key] then return end
	self._warned[key] = true
	warn(`[FootstepController]: {message}`)
end

--[[ SUPERFÍCIE ]]

--[[
	Acha o pé pedido no rig. R15 tem LeftFoot/RightFoot, R6 tem "Left Leg"/"Right
	Leg"; se nada disso existir, o passo ainda sai, mas no meio do personagem.
]]
function FootstepController:_getFoot(character: Model, side: string): BasePart?
	for _, name in FOOT_PARTS[side] or {} do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end

	return nil
end

--[[
	Sobe a hierarquia atrás do atributo. Marcar a Part é o caso normal, mas
	marcar o Model/Folder que a contém vale pra um cenário inteiro de uma vez.
]]
function FootstepController:_readSurface(instance: Instance?): string?
	local current = instance

	while current and current ~= workspace do
		local value = current:GetAttribute(Config.Attribute)
		if type(value) == "string" and value ~= "" then
			return value
		end
		current = current.Parent
	end

	return nil
end

-- Raio curto pra baixo, a partir do pé, ignorando o próprio personagem.
function FootstepController:_surfaceUnder(footPart: BasePart, character: Model): (string?, BasePart?)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	-- Chão é o que dá pra pisar: part sem colisão (preview, AOE, decoração) não
	-- deve responder pelo som.
	params.RespectCanCollide = true

	local result = workspace:Raycast(footPart.Position, Vector3.new(0, -Config.RayLength, 0), params)
	if not result then
		return nil, nil
	end

	return self:_readSurface(result.Instance) or Config.Default, result.Instance
end

--[[ CACHE ]]

-- Todos os ids configurados, sem repetir (a mesma variação pode servir a duas
-- superfícies). O pulo entra aqui junto: ele usa o mesmo pool e o mesmo cache.
function FootstepController:_allIds(): { string }
	local seen, list = {}, {}

	local function add(entry)
		for _, id in (entry and entry.Ids) or {} do
			if not seen[id] then
				seen[id] = true
				table.insert(list, id)
			end
		end
	end

	for _, surface in Config.Surfaces do
		add(surface)
	end
	add(Config.Jump)

	return list
end

--[[
	Puxa os assets para o cache do cliente uma vez, na entrada.

	As instâncias daqui nunca tocam: elas existem só para que o download já tenha
	acontecido quando o primeiro passo pedir o som — inclusive depois de morrer,
	já que o pool dos pés é refeito a cada personagem e o cache não.
]]
function FootstepController:_warmCache()
	if self._warmFolder then
		return
	end

	local ids = self:_allIds()
	if #ids == 0 then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "FootstepCache"
	folder.Parent = SoundService
	self._warmFolder = folder

	local sounds = {}
	for _, id in ids do
		local sound = Instance.new("Sound")
		sound.Name = id
		sound.SoundId = id
		sound.Volume = 0
		sound.Parent = folder
		table.insert(sounds, sound)
	end

	-- Yield: fica fora da thread do init.
	task.spawn(function()
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(sounds)
		end)

		if not ok then
			warn(`[FootstepController]: falha ao pré-carregar os passos: {err}`)
			return
		end

		for _, sound in sounds do
			if not sound.IsLoaded then
				self:_warnOnce(`preload:{sound.SoundId}`, `{sound.SoundId} não carregou; passos com essa variação vão sair mudos ou atrasados.`)
			end
		end
	end)
end

--[[
	Um Sound pronto por (pé, id), pendurado no próprio pé.

	Pendurado no pé porque o som é 3D e tem que acompanhar o personagem; um por
	id porque trocar o SoundId de uma instância na hora do passo traria de volta
	a espera de carregamento que este pool existe para eliminar.
]]
function FootstepController:_buildPool(character: Model)
	self._pool = {}

	local ids = self:_allIds()
	if #ids == 0 then
		return
	end

	local created = {}

	for side in FOOT_PARTS do
		local footPart = self:_getFoot(character, side)
		if footPart then
			local bySide = {}
			self._pool[side] = bySide

			for _, id in ids do
				local sound = Instance.new("Sound")
				sound.Name = `Footstep_{side}`
				sound.SoundId = id
				sound.RollOffMinDistance = Config.RollOffMin
				sound.RollOffMaxDistance = Config.RollOffMax
				sound.Parent = footPart
				bySide[id] = sound
				table.insert(created, sound)
			end
		end
	end

	-- Os assets já vieram no `_warmCache`, então isto resolve do cache e serve só
	-- para garantir que estas instâncias estejam prontas antes do primeiro passo.
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(created)
		end)
	end)
end

--[[ SOM ]]

-- Sorteia uma variação evitando repetir a anterior daquela superfície.
function FootstepController:_pickId(surfaceName: string, ids: { string }): string?
	if #ids == 0 then
		return nil
	end
	if #ids == 1 then
		return ids[1]
	end

	local chosen = ids[math.random(#ids)]
	if chosen == self._lastId[surfaceName] then
		-- Uma re-tentativa basta: com N >= 2 ela já cai em outra na prática, e
		-- não vale travar num loop por causa de um passo.
		chosen = ids[math.random(#ids)]
	end

	self._lastId[surfaceName] = chosen
	return chosen
end

--[[
	Toca o passo numa instância que já existe e já está carregada.

	Criar o Sound na hora do passo era o que tirava o som do lugar: um SoundId
	recém-atribuído carrega de forma assíncrona, então o `:Play()` não soa quando
	é chamado, e sim quando o asset termina de chegar. Enquanto o primeiro
	carregava, os passos seguintes iam se acumulando — e todos soavam juntos no
	instante em que o carregamento terminava. Daí o atraso em relação ao print e
	os passos empilhados.
]]
--[[
	Toca uma entrada de config (superfície ou pulo) numa instância do pool.

	`key` é só a identidade da entrada: serve para a memória de "qual variação saiu
	da última vez" e para os avisos não se misturarem.
]]
function FootstepController:_playFrom(entry, key: string, side: string)
	local id = self:_pickId(key, entry.Ids or {})
	if not id then
		self:_warnOnce(`ids:{key}`, `"{key}" não tem nenhum id configurado.`)
		return
	end

	local sound = self._pool[side] and self._pool[side][id]
	if not sound or not sound.Parent then
		self:_warnOnce(`pool:{id}`, `sem som pronto para {id} no pé {side}; não tocou.`)
		return
	end

	local range = entry.PitchRange or Config.PitchRange
	sound.Volume = (entry.Volume or 1) * Config.Volume
	sound.PlaybackSpeed = range[1] + math.random() * (range[2] - range[1])

	-- Mesma instância podendo ser repedida antes de acabar: volta pro começo em
	-- vez de ignorar o Play. Como os pés alternam e as variações não repetem, na
	-- prática cada instância só é reusada muito depois do clipe ter acabado.
	sound.TimePosition = 0
	sound:Play()

	if IS_STUDIO and not sound.IsLoaded then
		self:_warnOnce(`notloaded:{id}`, `{id} ainda não estava carregado; o som pode sair atrasado.`)
	end
end

function FootstepController:_playStep(surfaceName: string, side: string)
	local surface = Config.Surfaces[surfaceName]
	if not surface then
		self:_warnOnce(`surface:{surfaceName}`, `superfície "{surfaceName}" não existe em SharedConfig.FootstepConfig.Surfaces.`)
		return
	end

	self:_playFrom(surface, surfaceName, side)
end

--[[ PASSO ]]

--[[
	Toca o passo do chão que estiver embaixo do pé pedido. Caminho comum do
	marcador de animação e da aterrissagem.
]]
function FootstepController:_stepOnSurface(side: string)
	local character = self._character
	if not character or not character.Parent then
		return
	end

	local footPart = self:_getFoot(character, side)
	if not footPart then
		return
	end

	local surfaceName, hitPart = self:_surfaceUnder(footPart, character)
	if not surfaceName then
		if IS_STUDIO and hitPart then
			self:_warnOnce(
				`untagged:{hitPart:GetFullName()}`,
				`{hitPart:GetFullName()} não tem o atributo "{Config.Attribute}"; passo silencioso.`
			)
		end
		return
	end

	self:_playStep(surfaceName, side)
end

-- Consome o próximo pé da alternância.
function FootstepController:_takeFoot(preferred: string?): string
	local side = preferred
	if side ~= "Left" and side ~= "Right" then
		side = self._nextFoot
	end

	self._nextFoot = if side == "Left" then "Right" else "Left"
	return side :: string
end

--[[
	Trava compartilhada por marcador e aterrissagem: sem ela, cair já andando
	tocaria o passo da aterrissagem e o do marcador seguinte quase juntos.
]]
function FootstepController:_canStep(): boolean
	local now = os.clock()
	local sinceLast = now - self._lastStep

	if sinceLast < Config.MinInterval then
		-- Vale saber: se aparecer muito, é marcador duplicado na animação (ou duas
		-- tracks tocando a mesma animação), não problema de som.
		stepPrint(string.format("passo ignorado: %.0fms desde o anterior, mínimo é %.0fms",
			sinceLast * 1000, Config.MinInterval * 1000))
		return false
	end

	self._lastStep = now
	return true
end

--[[
	Um disparo do marcador "Step".

	`markerValue` é o valor que o marcador carrega na animação, se tiver: "Left"
	ou "Right" fixam o pé. Sem valor, alterna — o que já cobre uma caminhada
	normal, onde os marcadores vêm um de cada lado.
]]
function FootstepController:_onStep(markerValue: string?)
	local character = self._character
	local humanoid = self._humanoid
	if not character or not character.Parent or not humanoid then
		return
	end

	-- No ar não há passo: pulo e queda podem cruzar o fim de uma caminhada.
	if humanoid.FloorMaterial == Enum.Material.Air then
		return
	end

	if not self:_canStep() then
		return
	end

	self:_stepOnSurface(self:_takeFoot(markerValue))
end

--[[
	Aterrissagem: o mesmo som de passo, do chão em que caiu.

	Não passa pela checagem de `FloorMaterial`: no quadro em que o `Landed`
	dispara ela ainda pode estar em `Air`, e aí o som da queda sumiria. Quem diz
	onde pisou é o raio embaixo do pé, que a essa altura já alcança o chão.
]]
function FootstepController:_onLanded()
	local character = self._character
	if not character or not character.Parent then
		return
	end

	if not self:_canStep() then
		return
	end

	local side = self:_takeFoot(nil)
	stepPrint("aterrissou | pé", side)
	self:_stepOnSurface(side)
end

--[[
	Pulo.

	Fora da trava dos passos de propósito: quem pula andando acabou de dar um
	passo, e a trava comeria o som do salto. A trava daqui é só contra o estado
	`Jumping` ser reentrado no mesmo salto.

	Também não consome a alternância dos pés — pular não é pisar — e não olha a
	superfície: o som do salto é o mesmo em qualquer chão.
]]
function FootstepController:_onJumped()
	local character = self._character
	if not character or not character.Parent then
		return
	end

	if not Config.Jump then
		return
	end

	local now = os.clock()
	if now - self._lastJump < Config.MinInterval then
		return
	end
	self._lastJump = now

	stepPrint("pulou")
	self:_playFrom(Config.Jump, "Jump", self._nextFoot)
end

--[[ CICLO DE VIDA ]]

--[[
	Se esta track é a que manda no passo agora: a última a começar, entre as que
	têm marcador e continuam tocando. Sem nenhuma tocando, ela mesma assume.
]]
function FootstepController:_ownsSteps(track: AnimationTrack): boolean
	local owner, startedAt = nil, -math.huge

	for other in self._markerTracks do
		if other.IsPlaying then
			local at = self._trackStarted[other] or 0
			if at > startedAt then
				owner, startedAt = other, at
			end
		end
	end

	return owner == nil or owner == track
end

function FootstepController:_bindTrack(track: AnimationTrack)
	local maid = self._maid
	if not maid then return end

	-- Antes do dedupe: `AnimationPlayed` dispara a cada tocada da mesma track, e
	-- é justamente isso que marca o "começou agora".
	self._trackStarted[track] = os.clock()

	if self._boundTracks[track] then return end
	self._boundTracks[track] = true

	local animationId = track.Animation and track.Animation.AnimationId or "?"

	-- Track sem o marcador simplesmente nunca dispara: não custa nada conectar
	-- em todas e deixar a própria animação dizer se tem passo ou não.
	maid:GiveTask(track:GetMarkerReachedSignal(MARKER):Connect(function(value: string?)
		self._markerTracks[track] = true

		if not self:_ownsSteps(track) then
			stepPrint(string.format("marcador de %s ignorado: outra animação com marcador começou depois e está tocando", track.Name))
			return
		end

		stepPrint(string.format(`marcador "{MARKER}" disparou | animação %s (%s) | valor %s | %.0fms desde o anterior`,
			track.Name, animationId, value or "(sem valor)", (os.clock() - self._lastStep) * 1000))
		self:_onStep(value)
	end))
end

function FootstepController:_bindCharacter(character: Model)
	if self._maid then
		self._maid:DoCleaning()
	end

	local maid = Maid.new()
	self._maid = maid
	-- Personagem novo, tracks novas: as antigas morreram com o Animator anterior.
	self._boundTracks = setmetatable({}, { __mode = "k" }) :: any
	self._markerTracks = setmetatable({}, { __mode = "k" }) :: any
	self._trackStarted = setmetatable({}, { __mode = "k" }) :: any

	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end

	local animator = humanoid:WaitForChild("Animator", 10)
	if not animator or not animator:IsA("Animator") then
		return
	end

	self._character = character
	self._humanoid = humanoid
	self._nextFoot = "Right"

	-- Antes de ligar as escutas: quando o primeiro marcador disparar, o som já
	-- tem que estar pendurado no pé e pronto.
	self:_buildPool(character)

	-- O Walk vem do Animate padrão e o Run vem do MovementController: os dois
	-- passam pelo mesmo Animator, então uma escuta só cobre ambos.
	maid:GiveTask(animator.AnimationPlayed:Connect(function(track)
		self:_bindTrack(track)
	end))

	-- Quem já estava tocando quando o personagem apareceu.
	for _, track in animator:GetPlayingAnimationTracks() do
		self:_bindTrack(track)
	end

	-- Cair também é pisar; e o salto tem som próprio.
	maid:GiveTask(humanoid.StateChanged:Connect(function(_, newState)
		if newState == Enum.HumanoidStateType.Landed then
			self:_onLanded()
		elseif newState == Enum.HumanoidStateType.Jumping then
			self:_onJumped()
		end
	end))

	-- O pool morre junto com os pés; a tabela é que precisa ser largada, senão
	-- ficaria apontando para Sounds de um personagem que não existe mais.
	maid:GiveTask(function()
		self._character = nil
		self._humanoid = nil
		self._pool = {}
	end)
end

function FootstepController:construct()
	-- Uma vez por sessão, e antes do primeiro personagem: o cache do cliente
	-- sobrevive a morte e respawn, o pool dos pés não.
	self:_warmCache()

	local function onCharacter(character: Model)
		self:_bindCharacter(character)
	end

	if Player.Character then
		task.spawn(onCharacter, Player.Character)
	end

	Player.CharacterAdded:Connect(onCharacter)

	Player.CharacterRemoving:Connect(function()
		if self._maid then
			self._maid:DoCleaning()
			self._maid = nil
		end
	end)
end

function FootstepController:start() end

function FootstepController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	self:construct()
end

return FootstepController
