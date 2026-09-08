local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

--[[
	Os mapas vivem em ServerStorage, nao em ReplicatedStorage.

	Isso muda uma coisa importante para quem for mexer aqui: o cliente nao ve mapa
	nenhum, so o clone que este service coloca em `workspace.Map`. Entao
	`CollectionService:GetTagged("Grid")` no cliente devolve exatamente as parts do
	mapa em jogo — nao mais as dos seis mapas somadas.
]]
local Maps = ServerStorage:WaitForChild("Maps")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local MapConfig = SharedConfig.MapConfig

local PathUtil = require(Shared.Util.PathUtil)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local Framework = Me.new()

local LightingConfig = SharedConfig.LightingConfig
local WeatherConfig = SharedConfig.WeatherConfig

local ExampleService = {
	Services = {
		LightingService = {},
		DataService = {},
		IndexService = {},
	}
}

--[=[
	Espera um service aparecer no loader, com limite.

	`Framework:Get` com yield esperaria para sempre se o service nao existisse, e um
	`init` travado em silencio seria pior do que carregar o mapa sem iluminacao. O
	`Me:Load` fecha em muito menos que isto.
]=]
local function waitForService(name : string, timeout : number?)
	local deadline = os.clock() + (timeout or 5)

	repeat
		local service = Framework:Get(name)
		if service then
			return service
		end
		task.wait()
	until os.clock() >= deadline

	return nil
end

--[=[
	Um mapa qualquer entre os que o MapConfig oferece e que existem de fato na
	pasta. O config manda porque ele e a unica coisa que o Lobby consegue ler
	sobre mapas — sortear algo fora dele daria um mapa que o portal nao sabe
	mostrar.
]=]
function ExampleService:pickRandomMap() : string?
	local candidates = {}
	for _, name in MapConfig.getOrderedMaps() do
		if Maps:FindFirstChild(name) then
			table.insert(candidates, name)
		end
	end

	-- Config vazio ou defasado: melhor cair para o que existe na pasta do que
	-- nao carregar mapa nenhum.
	if #candidates == 0 then
		warn("[MapService]: nenhum mapa do MapConfig existe em ServerStorage.Maps; sorteando direto da pasta.")
		for _, folder in Maps:GetChildren() do
			table.insert(candidates, folder.Name)
		end
	end

	if #candidates == 0 then
		return nil
	end

	return candidates[math.random(1, #candidates)]
end

--[=[
	O mapa que o grupo escolheu no Lobby, se veio.

	O `PortalService` de la embarca `{ Map = ... }` no TeleportData de uma unica
	chamada de TeleportAsync para o grupo inteiro, entao qualquer jogador do
	servidor carrega a mesma escolha. `resolveMap` valida contra o MapConfig e
	normaliza a caixa; nome desconhecido volta nil e cai no sorteio.
]=]
function ExampleService:getTeleportedMap(player : Player) : string?
	local success, joinData = pcall(function()
		return player:GetJoinData()
	end)

	if not success or typeof(joinData) ~= "table" then
		return nil
	end

	local teleportData = joinData.TeleportData
	if typeof(teleportData) ~= "table" then
		return nil
	end

	local resolved = MapConfig.resolveMap(teleportData.Map)
	if resolved and not Maps:FindFirstChild(resolved) then
		warn(string.format("[MapService]: o Lobby pediu '%s', que o MapConfig conhece mas nao existe em ServerStorage.Maps.", resolved))
		return nil
	end

	return resolved
end

--[=[
	Decide qual mapa carregar.

	No Studio nao existe TeleportData, entao sorteia e segue — sem aviso, para nao
	poluir o output em todo teste. Em servidor de verdade o esperado e vir do
	Lobby; nao vindo, avisa e sorteia.

	Yield: em servidor precisa de um jogador para ler o JoinData, e o primeiro so
	chega depois do boot.
]=]
function ExampleService:resolveStartingMap() : string?
	if RunService:IsStudio() then
		return self:pickRandomMap()
	end

	local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()

	local mapName = self:getTeleportedMap(player)
	if mapName then
		return mapName
	end

	warn("[MapService]: servidor sem TeleportData de mapa valido; sorteando.")
	return self:pickRandomMap()
end

function ExampleService:LoadMap(Name : string)
	local MapInstance = Maps:FindFirstChild(Name)
	if not MapInstance then return end

	self.CurrentMapName = Name

	local MapContent = MapInstance:FindFirstChild("Content")
	if MapContent then
		local Map = MapContent:FindFirstChild("Map")
		local Clone = Map:Clone()
		Clone.Parent = workspace

		--[=[
			A BoundingBox e irma do Content na pasta do mapa, mas quem a consome e o
			WeatherService, que so enxerga o Workspace — entao ela entra junto do mapa.

			Inerte de proposito: `CanQuery` desligado tira ela do raycast dos passos e
			da validacao de posicionamento de unidade, que varrem o que esta em cima do
			mapa.
		]=]
		local Bounds = MapInstance:FindFirstChild(WeatherConfig.BoundsPartName)
		if Bounds and Bounds:IsA("BasePart") then
			local BoundsClone = Bounds:Clone()
			BoundsClone.Anchored = true
			BoundsClone.CanCollide = false
			BoundsClone.CanQuery = false
			BoundsClone.CanTouch = false
			BoundsClone.Transparency = 1
			BoundsClone.Parent = Clone
		else
			warn(string.format("[MapService]: o mapa '%s' nao tem a Part '%s'; o clima vai cair para a caixa calculada.",
				Name, WeatherConfig.BoundsPartName))
		end

		--[=[
			A BaseHP e irma do Content como a BoundingBox, e entra junto do mapa pelo
			mesmo motivo: o billboard dela e o unico lugar onde o jogador ve a vida da
			base, e do mapa o cliente so enxerga o que esta em `workspace.Map`.

			O clone e forcado a ancorado e inerte -- Part solta cairia do mundo levando
			o billboard junto, e `CanQuery` ligado a poria no raycast que valida o
			posicionamento de unidade, que varre justamente o que esta em cima do mapa.
			A aparencia fica a que veio autorada. Quem escreve o numero e o
			`BaseHealthController`, no cliente.
		]=]
		local BaseHP = MapInstance:FindFirstChild(MapConfig.BASE_HEALTH_PART)
		if BaseHP and BaseHP:IsA("BasePart") then
			local BaseHPClone = BaseHP:Clone()
			BaseHPClone.Anchored = true
			BaseHPClone.CanCollide = false
			BaseHPClone.CanQuery = false
			BaseHPClone.CanTouch = false
			BaseHPClone.Parent = Clone
		else
			warn(string.format("[MapService]: o mapa '%s' nao tem a Part '%s'; a vida da base nao vai aparecer em lugar nenhum.",
				Name, MapConfig.BASE_HEALTH_PART))
		end
	end

	local Spawn = MapInstance:FindFirstChild("SpawnLocation")
	if Spawn then
		local SpawnClone = Spawn:Clone()
		SpawnClone.Enabled = true
		SpawnClone.Parent = workspace
	end

	local Nodes = MapInstance:FindFirstChild("Nodes")
	if Nodes then
		local transparency = self.Debug and 0.5 or 1

		for _, Node : Instance in Nodes:GetChildren() do
			local Clone = Node:Clone()

			-- Um node pode ser uma Part (um ponto) ou um Folder com um trecho
			-- inteiro dentro, quando o mapa tem bifurcacao. Folder nao tem
			-- Transparency, entao a propriedade e aplicada nas BaseParts.
			if Clone:IsA("BasePart") then
				Clone.Transparency = transparency
			end
			for _, descendant in Clone:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.Transparency = transparency
				end
			end

			Clone.Parent = workspace.PathScriptable.Nodes
		end

		-- O cliente monta as rotas a partir destes nodes replicados e precisa
		-- saber quando parou de faltar peca. Ver `PathUtil.WaitForNodes`.
		PathUtil.PublishNodeCounts(workspace.PathScriptable.Nodes)
	end

	--[=[
		A iluminacao do mapa passa pelo LightingService.

		`Register` clona a pasta para `Assets.Lighting` antes de aplicar, e esse clone
		e o que faz a transicao existir: os mapas moram em ServerStorage, que nao
		replica, entao sem ele o cliente nao teria de onde ler os valores de destino.

		Mapa sem a pasta fica com a iluminacao autorada na place — o `Snowy` e assim
		hoje, e continua sendo.
	]=]
	local MapLighting = MapInstance:FindFirstChild("Lighting")
	if not MapLighting then
		-- Dito em voz alta porque e indistinguivel de "o service falhou" no console.
		warn(string.format("[MapService]: o mapa '%s' nao tem pasta Lighting; a iluminacao fica a que estava.", Name))
		return
	end

	local LightingService = self.Services.LightingService
	if not LightingService or not LightingService.Register then
		warn("[MapService]: LightingService indisponivel; a iluminacao do mapa nao foi aplicada.")
		return
	end

	local presetName = LightingConfig.MapPrefix .. Name

	-- `registerMapLighting` normalmente ja registrou todo mundo no init; isto cobre
	-- um LoadMap de um mapa que apareceu depois.
	if not LightingService:GetPreset(presetName) then
		presetName = LightingService:Register(MapLighting, presetName) or presetName
	end

	LightingService:Apply(presetName)
end

--[=[
	Registra a pasta `Lighting` de TODOS os mapas como preset, nao so a do mapa
	carregado.

	Os mapas vivem em ServerStorage e nao replicam; o `Register` clona cada pasta
	para `Assets.Lighting`, que e o que faz o cliente enxergar todas. Sem isto o
	comando `lighting` so conseguiria oferecer a do mapa em jogo — e trocar de
	iluminacao para testar exige justamente as outras.

	Sao seis instancias pequenas por mapa; o custo de replicar todas e irrelevante
	perto de poder comparar uma com a outra em jogo.
]=]
function ExampleService:registerMapLighting() : number
	local LightingService = self.Services.LightingService
	if not LightingService or not LightingService.Register then
		return 0
	end

	local registered = 0
	local missing = {}

	for _, map in Maps:GetChildren() do
		local mapLighting = map:FindFirstChild("Lighting")
		if not mapLighting then
			table.insert(missing, map.Name)
			continue
		end

		if LightingService:Register(mapLighting, LightingConfig.MapPrefix .. map.Name) then
			registered += 1
		end
	end

	if #missing > 0 then
		warn(string.format("[MapService]: sem pasta Lighting, ficaram de fora dos presets: %s.", table.concat(missing, ", ")))
	end

	return registered
end

function ExampleService:construct()
	Framework:Listen("RequestMapMusic", function(player : Player)
	--	if not self.CurrentMapName then return end
		-- O nome da faixa, e nao o do mapa: quem procura o Sound do outro lado
		-- procura por nome exato, e nem toda faixa se chama como a pasta do mapa
		-- (ver `MapConfig.getMusic`).
		Framework:Fire("PlayMapMusic", player, MapConfig.getMusic(self.CurrentMapName))
	end)

	self:watchIndex()
end

--[=[
	O mapa deste servidor entra no Index de quem esta jogando.

	"Jogou pela primeira vez" e aqui: o servidor da partida e reservado e ja nasce
	sabendo o mapa (`resolveStartingMap`), entao estar dentro dele **e** jogar --
	nao ha o que esperar de round, e quem sai na primeira wave tambem jogou.

	Preso no `PlayerDataLoaded` e nao no `PlayerAdded` porque o Index e escrita de
	perfil: sem perfil aberto nao ha onde gravar. Os dois lados sao cobertos --
	quem entra depois pelo sinal, quem ja estava dentro pela varredura.
]=]
function ExampleService:watchIndex()
	local dataService = self.Services.DataService
	local indexService = self.Services.IndexService

	if not dataService or not indexService then
		warn("[MapService]: sem DataService/IndexService; o mapa nao entra no Index.")
		return
	end

	local function record(player : Player)
		if not self.CurrentMapName then return end

		indexService:UnlockMap(player, self.CurrentMapName)
	end

	dataService.Signals.PlayerDataLoaded:Connect(record)

	for _, player in Players:GetPlayers() do
		if dataService.Profiles and dataService.Profiles[player] then
			record(player)
		end
	end
end

function ExampleService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function ExampleService:init()

	Framework:Listen("PlayMapMusic", function() end)

	--[[
		O LightingService entra aqui, antes de decidir o mapa, de proposito: esta e a
		ultima hora em que ceder a thread nao custa nada. Depois que o mapa foi
		decidido o LoadMap corre dentro do PlayerAdded e nao pode mais parar (ver
		abaixo), e o `start`, que resolveria as dependencias normalmente, roda depois
		deste `init`.
	]]
	self.Services.LightingService = waitForService("LightingService")
	if not self.Services.LightingService then
		warn("[MapService]: LightingService nao carregou; o mapa vai entrar sem trocar a iluminacao.")
	else
		-- Todos os mapas viram preset, nao so o que vai ser carregado: e o que
		-- permite o comando `lighting` trocar entre as iluminacoes para comparar.
		local registered = self:registerMapLighting()
		print(string.format("[MapService]: %d iluminacao(oes) de mapa registrada(s) em Assets.Lighting.", registered))
	end

	--[[
		Carregado assim que houver como decidir, e nao num nome fixo.

		Em servidor isso espera o primeiro jogador (e de onde vem o JoinData). Nada
		que dependa do mapa corre antes: o `MobService:getRoutes()` so monta o
		caminho na primeira wave, e o `WaveService` nem comeca o round enquanto nao
		houver jogador pronto. A `SpawnLocation` tambem chega a tempo — o LoadMap
		nao tem yield nenhum, entao termina dentro do proprio PlayerAdded, antes de
		o personagem nascer.
	]]
	local mapName = self:resolveStartingMap()
	if not mapName then
		warn("[MapService]: nenhum mapa disponivel para carregar.")
		return
	end

	self:LoadMap(mapName)
	print(string.format("[MapService]: mapa carregado: %s", mapName))
end

return ExampleService
