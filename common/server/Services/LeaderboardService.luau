local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)
local UIUtil = require(Shared.Util.UIUtil)

local Me = require(Vendor.Me)

local Framework = Me.new()

local LeaderboardConfig = ServerConfig.Leaderboard
local LevelConfig = SharedConfig.LevelConfig

--[[
	As leaderboards globais: um OrderedDataStore por board (`Config.Leaderboard`).

	Mora em `common` porque as duas places **gravam**: a Game muda XP, coins,
	vitorias, partidas e tempo em partida; a Lobby muda coins (compras), caixas
	abertas e tempo de jogo. So a Lobby **desenha**, e nao por configuracao: e a
	unica place com `Workspace.Leaderboards`, e sem a pasta a metade de leitura nem
	liga.

	**Gravar.** O perfil continua sendo a fonte; a store e uma copia ordenada dele.
	Cada servidor manda os numeros dos proprios jogadores quando o perfil carrega, a
	cada `WRITE_INTERVAL` e na saida -- e so os que mudaram desde a ultima escrita
	(`Written`). Tudo passa por uma fila (`Pending`) com uma entrada por
	store+jogador: se o numero muda de novo antes de a escrita sair, a entrada e
	substituida, e nao duplicada. A fila respeita o budget de escrita da Roblox e,
	se a store falhar, espera o proximo ciclo em vez de insistir.

	**Ler.** A cada `READ_INTERVAL` a Lobby pede o topo de cada board -- uma pagina
	de `TOP`, que custa o mesmo com cem ou cem milhoes de jogadores na store -- e
	resolve os nomes num lote so (`GetUserInfosByUserIdsAsync`), com cache.

	**Desenhar.** O `Frame` de dentro do `ScrollingFrame` e o molde: sai da tela e
	vira uma linha por posicao. As linhas sao reaproveitadas entre as leituras --
	so o texto muda --, e as que sobram ficam escondidas. A SurfaceGui esta no
	Workspace, entao o que o servidor escreve replica para todo mundo.

	**O nome da store leva o `PROFILE_KEY`.** Trocar a chave zera os perfis, e
	uma leaderboard que continuasse mostrando os numeros de perfis que ninguem mais
	le estaria mentindo.

	Jogador de UserId negativo (os clientes de teste do Studio) nao grava: a store
	e a mesma do jogo, e ele sujaria o topo de verdade.
]]

local WRITE_BUDGET = Enum.DataStoreRequestType.SetIncrementSortedAsync
local READ_BUDGET = Enum.DataStoreRequestType.GetSortedAsync

-- Depois de todo mundo que ainda escreve no perfil na saida -- recompensa de quem
-- sai no meio, o tempo final (ver `DataService:OnBeforeRelease`).
local RELEASE_ORDER = 1

-- Quanto o desligamento espera a fila esvaziar. A Roblox da 30s ao `BindToClose`.
local SHUTDOWN_TIMEOUT = 25

-- Um aviso por store a cada tanto: sem API do Studio ligada, toda chamada falha,
-- e oito boards a cada ciclo enterrariam o resto do output.
local WARN_COOLDOWN = 600

local UNKNOWN_NAME = "???"

local LeaderboardService = {
	Services = {
		DataService = {},
	},

	-- [Store] = OrderedDataStore
	Stores = {},

	-- [UserId] = { [Store] = numero que ja esta na store }. So de quem esta aqui.
	Written = {},

	-- ["Store|UserId"] = { Store, UserId, Value }
	Pending = {},
	Draining = false,

	-- [UserId] = Username
	Names = {},

	-- As boards do mapa (so na Lobby): { Config, List, Template, Rows }
	Boards = {},

	-- [chave] = `os.clock()` do ultimo aviso
	Warned = {},
}

--[[ FORMATO ]]

--- O numero no perfil, como inteiro nao negativo. O que nao for numero vale zero.
local function readPath(data : any, path : { string }) : number
	local node = data
	for _, key in path do
		if typeof(node) ~= "table" then
			return 0
		end

		node = node[key]
	end

	local value = tonumber(node) or 0
	if value ~= value or value == math.huge then
		return 0
	end

	return math.max(0, math.floor(value))
end

--- Segundos em `DD:HH:MM`. Os dias nao param no 99: 120 dias sao `120:00:00`.
local function formatTime(seconds : number) : string
	local minutes = seconds // 60

	return string.format("%02d:%02d:%02d", minutes // 1440, (minutes // 60) % 24, minutes % 60)
end

local function formatValue(format : string, value : number) : string
	if format == "Level" then
		return tostring(LevelConfig:Resolve(value).Level)
	elseif format == "Time" then
		return formatTime(value)
	end

	return (UIUtil.formatAbbreviated(value))
end

local function setText(row : Instance, name : string, text : string)
	local label = row:FindFirstChild(name)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

--[[ INTERNAL ]]

function LeaderboardService:_warn(key : string, message : string)
	local last = self.Warned[key]
	if last and os.clock() - last < WARN_COOLDOWN then
		return
	end

	self.Warned[key] = os.clock()
	warn("[LeaderboardService]: " .. message)
end

function LeaderboardService:_storeOf(storeKey : string) : OrderedDataStore?
	local store = self.Stores[storeKey]
	if store then
		return store
	end

	local name = string.format("%s_LB_%s", ServerConfig.Data.PROFILE_KEY, storeKey)
	local ok, result = pcall(DataStoreService.GetOrderedDataStore, DataStoreService, name)
	if not ok then
		self:_warn("store:" .. storeKey, string.format("nao abriu a store %q (%s).", name, tostring(result)))
		return nil
	end

	self.Stores[storeKey] = result
	return result
end

function LeaderboardService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

--[[ GRAVAR ]]

--[=[
	Poe na fila os numeros do jogador que mudaram desde a ultima escrita.

	Na primeira vez da sessao nao ha `Written` para comparar, entao vai tudo -- menos
	os zeros, que e o que a store ja diz de quem nunca pontuou.
]=]
function LeaderboardService:_collect(player : Player)
	local userId = player.UserId
	if userId <= 0 then return end

	local data = self:_profileOf(player)
	if not data then return end

	local written = self.Written[userId]
	if not written then
		written = {}
		self.Written[userId] = written
	end

	local queued = false
	for _, board in LeaderboardConfig.Boards do
		local value = readPath(data, board.Path)
		local last = written[board.Store]

		if value ~= last and not (last == nil and value == 0) then
			self.Pending[board.Store .. "|" .. userId] = {
				Store = board.Store,
				UserId = userId,
				Value = value,
			}
			queued = true
		end
	end

	if queued then
		self:_drain()
	end
end

--[=[
	Esvazia a fila numa thread so. Chamar de novo com ela rodando nao faz nada: o
	que entrou na fila no meio do caminho sai na mesma volta.

	Uma escrita que falha volta para a fila (a nao ser que um numero mais novo ja
	tenha tomado o lugar dela) e a volta para: a store fora do ar nao melhora em um
	segundo, e insistir so gastaria o budget. O proximo ciclo tenta de novo.
]=]
function LeaderboardService:_drain()
	if self.Draining then return end
	self.Draining = true

	task.spawn(function()
		while true do
			local key, job = next(self.Pending)
			if not key then
				break
			end

			if DataStoreService:GetRequestBudgetForRequestType(WRITE_BUDGET) < 1 then
				task.wait(1)
				continue
			end

			self.Pending[key] = nil

			local store = self:_storeOf(job.Store)
			local ok, err = false, "store indisponivel"
			if store then
				ok, err = pcall(store.SetAsync, store, tostring(job.UserId), job.Value)
			end

			if ok then
				local written = self.Written[job.UserId]
				if written then
					written[job.Store] = job.Value
				end
			else
				if self.Pending[key] == nil then
					self.Pending[key] = job
				end

				self:_warn("write:" .. job.Store, string.format("escrita em %s falhou (%s).", job.Store, tostring(err)))
				break
			end
		end

		self.Draining = false
	end)
end

--[[ LER E DESENHAR ]]

--- Liga cada board do config ao modelo dela no mapa. Devolve se ha alguma.
function LeaderboardService:_bindBoards() : boolean
	local folder = workspace:FindFirstChild(LeaderboardConfig.FOLDER_NAME)
	if not folder then
		return false
	end

	for _, config in LeaderboardConfig.Boards do
		local model = folder:FindFirstChild(config.Model)
		local main = model and model:FindFirstChild("Main")
		local surface = main and main:FindFirstChildWhichIsA("SurfaceGui")
		local list = surface and surface:FindFirstChildWhichIsA("ScrollingFrame")
		local template = list and list:FindFirstChildWhichIsA("Frame")

		if not template then
			warn(string.format(
				"[LeaderboardService]: %s.%s sem Main > SurfaceGui > ScrollingFrame > Frame; board ignorada.",
				LeaderboardConfig.FOLDER_NAME, config.Model))
			continue
		end

		-- O molde sai da tela: fica so como fonte das linhas.
		template.Parent = nil

		table.insert(self.Boards, {
			Config = config,
			List = list,
			Template = template,
			Rows = {},
		})
	end

	return #self.Boards > 0
end

--- O topo de uma board, do maior para o menor, sem os zeros.
function LeaderboardService:_fetch(config) : { { UserId : number, Value : number } }?
	local store = self:_storeOf(config.Store)
	if not store then return nil end

	while DataStoreService:GetRequestBudgetForRequestType(READ_BUDGET) < 1 do
		task.wait(1)
	end

	local ok, result = pcall(function()
		return store:GetSortedAsync(false, LeaderboardConfig.TOP, 1):GetCurrentPage()
	end)

	if not ok then
		self:_warn("read:" .. config.Store, string.format("leitura de %s falhou (%s).", config.Store, tostring(result)))
		return nil
	end

	local entries = {}
	for _, item in result do
		local userId = tonumber(item.key)
		if userId then
			table.insert(entries, { UserId = userId, Value = tonumber(item.value) or 0 })
		end
	end

	return entries
end

--[=[
	Os nomes de quem aparece no topo. Quem esta no servidor sai do `Player`; o
	resto vai num lote so para o `UserService`, e fica em cache -- o topo muda
	pouco entre uma leitura e outra.

	Se o lote inteiro falhar, cai para um pedido por jogador. Um id que nem assim
	resolve (conta apagada) aparece como `???` e e tentado de novo na proxima volta.
]=]
function LeaderboardService:_resolveNames(entries)
	local missing = {}

	for _, entry in entries do
		local userId = entry.UserId
		if not self.Names[userId] then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				self.Names[userId] = player.Name
			else
				table.insert(missing, userId)
			end
		end
	end

	if #missing == 0 then return end

	local ok, infos = pcall(UserService.GetUserInfosByUserIdsAsync, UserService, missing)
	if ok then
		for _, info in infos do
			self.Names[info.Id] = info.Username
		end

		return
	end

	for _, userId in missing do
		local found, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
		if found then
			self.Names[userId] = name
		end
	end
end

function LeaderboardService:_render(board, entries)
	self:_resolveNames(entries)

	for rank, entry in entries do
		local row = board.Rows[rank]
		if not row then
			row = board.Template:Clone()
			row.Name = string.format("Rank%02d", rank)
			row.LayoutOrder = rank
			row.Parent = board.List
			board.Rows[rank] = row
		end

		setText(row, "Position", string.format("%dº", rank))
		setText(row, "Username", self.Names[entry.UserId] or UNKNOWN_NAME)
		setText(row, "Value", formatValue(board.Config.Format, entry.Value))
		row.Visible = true
	end

	for rank = #entries + 1, #board.Rows do
		board.Rows[rank].Visible = false
	end
end

function LeaderboardService:_refreshBoards()
	for _, board in self.Boards do
		local entries = self:_fetch(board.Config)
		if entries then
			self:_render(board, entries)
		end
	end
end

--[[ CICLO DE VIDA ]]

function LeaderboardService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		warn("[LeaderboardService]: sem DataService; nada vai para as leaderboards.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_collect(player)
	end)

	-- O retrato final, com o perfil ainda aberto e depois de quem escreve na saida.
	if dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player : Player)
			self:_collect(player)
			self.Written[player.UserId] = nil
		end, RELEASE_ORDER)
	end

	-- Quem carregou antes deste service subir: o sinal deles ja passou.
	for _, player in Players:GetPlayers() do
		self:_collect(player)
	end

	task.spawn(function()
		while true do
			task.wait(LeaderboardConfig.WRITE_INTERVAL)

			for _, player in Players:GetPlayers() do
				self:_collect(player)
			end
		end
	end)

	--[[
		O desligamento: os `Destroy` do DataService poem o retrato final de cada um na
		fila (o gancho acima), e isto segura o servidor ate ela esvaziar. O `_collect`
		daqui cobre quem ainda nao foi liberado quando este callback rodou.
	]]
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			self:_collect(player)
		end

		local deadline = os.clock() + SHUTDOWN_TIMEOUT
		repeat
			self:_drain()
			task.wait(0.5)
		until os.clock() >= deadline or (next(self.Pending) == nil and not self.Draining)
	end)

	if self:_bindBoards() then
		task.spawn(function()
			while true do
				self:_refreshBoards()
				task.wait(LeaderboardConfig.READ_INTERVAL)
			end
		end)
	end
end

function LeaderboardService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function LeaderboardService:init()
end

return LeaderboardService
