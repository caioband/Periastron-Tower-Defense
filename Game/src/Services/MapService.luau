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

local ExampleService = {
	Services = {}
}

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

	local Lighting = MapInstance:FindFirstChild("Lighting")
	if Lighting then

		for _, Inst in game.Lighting:GetChildren() do
			Inst:Destroy()
		end

		for _, Instance in Lighting:GetChildren() do
			local Clone = Instance:Clone()
			Clone.Parent = game.Lighting
		end
	end


end

function ExampleService:construct()
	Framework:Listen("RequestMapMusic", function(player : Player)
	--	if not self.CurrentMapName then return end
		Framework:Fire("PlayMapMusic", player, self.CurrentMapName)
	end)
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
