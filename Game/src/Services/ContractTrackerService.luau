local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Events = SharedConfig.ContractConfig.Events
local WeatherConfig = SharedConfig.WeatherConfig

--[[
	A partida contada para os contratos: o que acontece no round vira `Record` no
	`ContractService`, com o contexto que os filtros olham (mapa, dificuldade...).

	Este service nao sabe quais contratos o jogador tem. Ele conta **tudo** que um
	contrato poderia pedir, e quem casa evento com contrato e o `ContractService`.
	Contrato novo que so combine eventos que ja existem nao precisa de linha nenhuma
	aqui.

	  | Evento | De onde vem |
	  | --- | --- |
	  | `Kill`, `BossKill`, `Stun`, `Damage` | o placar da partida do `MobService`, lido em lote |
	  | `MatchCashSpent`, `MatchCashEarned` | idem -- o total da partida, para o `Max` |
	  | `WaveReached` | `WaveService.Signals.WaveStarted` |
	  | `Weather` | `WeatherRoundService.Signals.WeatherStarted` |
	  | `Win` | `WaveService.Signals.MatchFinished` |
	  | `MatchTime` | `MatchStatsService.Signals.Closed` |

	**Tudo e do proprio jogador.** Kill, dano e atordoamento sao de quem era a
	unidade; o caixa e o dele. So o clima e a wave sao da sala -- todo mundo que esta
	na partida viveu os dois.

	**O placar e lido, e nao ouvido.** O `MobService` so soma (ver `SessionStats`), e
	este service manda a diferenca desde a ultima leitura a cada `SYNC_INTERVAL`, no
	fim da partida e na saida. Um sinal por golpe seria um evento por dano.

	**A vitoria leva o contexto inteiro:** mapa, dificuldade, se a base terminou
	cheia, se havia amigo na sala e as classes que **todas** as unidades colocadas
	tinham em comum (o "only Fire units"). Unidade vendida no meio conta: ela foi
	usada.
]]

local SYNC_INTERVAL = 3

local ContractTrackerService = {
	Services = {
		ContractService = {},
		DataService = {},
		MapService = {},
		MatchStatsService = {},
		MobService = {},
		UnitService = {},
		WaveService = {},
		WeatherRoundService = {},
	},

	-- [Player] = { Kills, BossKills, Stuns, Damage } -- o que ja foi mandado nesta partida.
	Reported = {},

	-- [Player] = { { classes } } -- as classes de cada unidade colocada nesta partida.
	Placed = {},

	-- ["menor:maior"] = boolean -- amizade entre dois UserIds, perguntada uma vez.
	Friends = {},
}

--[[ INTERNAL ]]

function ContractTrackerService:_record(player : Player, event : string, value : number, context)
	local contracts = self.Services.ContractService
	if contracts and value > 0 then
		contracts:Record(player, event, value, context)
	end
end

--- Mapa e dificuldade da partida de agora. A dificuldade e nil antes da votacao.
function ContractTrackerService:_context()
	local mapService = self.Services.MapService
	local waveService = self.Services.WaveService
	local preset = waveService and waveService.Difficulty

	return {
		Map = mapService and mapService.CurrentMapName or nil,
		Difficulty = preset and preset.Name or nil,
	}
end

--[=[
	Manda a diferenca do placar desde a ultima leitura. Os `Max` vao com o total da
	partida: o `ContractService` so guarda se for maior que o melhor ate aqui.
]=]
function ContractTrackerService:_sync(player : Player)
	local mobService = self.Services.MobService
	if not mobService then return end

	local stats = mobService:GetSessionStats(player.UserId)
	local damage = math.floor(mobService:GetDamageDealt(player.UserId))

	local reported = self.Reported[player]
	if not reported then
		reported = { Kills = 0, BossKills = 0, Stuns = 0, Damage = 0 }
		self.Reported[player] = reported
	end

	local context = self:_context()

	local function send(event : string, field : string, current : number)
		-- Placar menor que o mandado quer dizer que ele zerou por baixo (partida nova).
		local last = reported[field]
		if current < last then
			last = 0
		end

		self:_record(player, event, current - last, context)
		reported[field] = current
	end

	send(Events.Kill, "Kills", stats.Kills)
	send(Events.BossKill, "BossKills", stats.BossKills)
	send(Events.Stun, "Stuns", stats.Stuns)
	send(Events.Damage, "Damage", damage)

	self:_record(player, Events.MatchCashSpent, math.floor(stats.Spent), context)
	self:_record(player, Events.MatchCashEarned, math.floor(stats.Earned), context)
end

function ContractTrackerService:_syncAll()
	for _, player in Players:GetPlayers() do
		self:_sync(player)
	end
end

--- Zera o que e da partida: o placar ja mandado e as unidades colocadas.
function ContractTrackerService:_resetMatch()
	table.clear(self.Reported)
	table.clear(self.Placed)
end

--- As classes que todas as unidades colocadas pelo jogador tem em comum.
function ContractTrackerService:_commonClasses(player : Player) : { [string] : boolean }
	local placed = self.Placed[player]
	if not placed or #placed == 0 then
		return {}
	end

	local common = nil

	for _, classes in placed do
		local set = {}
		for _, class in classes do
			set[class] = true
		end

		if common == nil then
			common = set
		else
			for class in common do
				if not set[class] then
					common[class] = nil
				end
			end
		end
	end

	return common or {}
end

--[=[
	Se os dois sao amigos na Roblox. Pergunta uma vez por par e guarda; a pergunta
	cede, entao quem chama esta numa thread propria.
]=]
function ContractTrackerService:_areFriends(a : Player, b : Player) : boolean
	local low, high = math.min(a.UserId, b.UserId), math.max(a.UserId, b.UserId)
	local key = low .. ":" .. high

	local cached = self.Friends[key]
	if cached ~= nil then
		return cached
	end

	local ok, result = pcall(a.IsFriendsWith, a, b.UserId)
	if not ok then
		return false
	end

	self.Friends[key] = result == true
	return result == true
end

function ContractTrackerService:_hasFriendHere(player : Player) : boolean
	for _, other in Players:GetPlayers() do
		if other ~= player and self:_areFriends(player, other) then
			return true
		end
	end

	return false
end

--[=[
	O fim da partida: o placar vai inteiro e, na vitoria, a vitoria com o contexto.

	A vida da base e lida aqui, e nao dentro da thread: a pergunta de amizade cede,
	e no meio dela o round pode ter sido reiniciado com a base cheia de novo.
]=]
function ContractTrackerService:_onMatchFinished(won : boolean, preset)
	self:_syncAll()

	local contracts = self.Services.ContractService

	if not won then
		for _, player in Players:GetPlayers() do
			contracts:Flush(player)
		end

		return
	end

	local mobService = self.Services.MobService
	local fullHealth = mobService ~= nil
		and (mobService.MaxBaseHealth or 0) > 0
		and (mobService.BaseHealth or 0) >= mobService.MaxBaseHealth

	local base = self:_context()
	local difficulty = (preset and preset.Name) or base.Difficulty

	for _, player in Players:GetPlayers() do
		local commonClasses = self:_commonClasses(player)

		task.spawn(function()
			local withFriends = self:_hasFriendHere(player)

			if not player.Parent then return end

			self:_record(player, Events.Win, 1, {
				Map = base.Map,
				Difficulty = difficulty,
				FullHealth = fullHealth,
				WithFriends = withFriends,
				CommonClasses = commonClasses,
			})

			contracts:Flush(player)
		end)
	end
end

--[[ CICLO DE VIDA ]]

function ContractTrackerService:construct()
	local waveService = self.Services.WaveService
	local unitService = self.Services.UnitService
	local weatherService = self.Services.WeatherRoundService
	local matchStats = self.Services.MatchStatsService
	local dataService = self.Services.DataService

	if not waveService or not self.Services.ContractService then
		warn("[ContractTrackerService]: sem WaveService ou ContractService; a partida nao conta para os contratos.")
		return
	end

	waveService.Signals.RoundStarted:Connect(function()
		self:_resetMatch()
	end)

	-- Reset no meio ou fim de round: o que a partida fez ate aqui vai antes de o
	-- placar do `MobService` zerar.
	waveService.Signals.RoundClosed:Connect(function()
		self:_syncAll()
		self:_resetMatch()
	end)

	waveService.Signals.MatchFinished:Connect(function(won : boolean, preset)
		self:_onMatchFinished(won, preset)
	end)

	waveService.Signals.WaveStarted:Connect(function(waveNumber : number, preset)
		local context = self:_context()
		context.Difficulty = (preset and preset.Name) or context.Difficulty

		for _, player in Players:GetPlayers() do
			self:_record(player, Events.WaveReached, waveNumber, context)
		end
	end)

	if weatherService and weatherService.Signals then
		weatherService.Signals.WeatherStarted:Connect(function()
			local context = self:_context()

			for _, player in Players:GetPlayers() do
				self:_record(player, Events.Weather, 1, context)
			end
		end)
	end

	if unitService and unitService.Signals then
		unitService.Signals.UnitPlaced:Connect(function(player : Player, unitName : string)
			local placed = self.Placed[player]
			if not placed then
				placed = {}
				self.Placed[player] = placed
			end

			table.insert(placed, WeatherConfig.GetClasses(unitName))
		end)
	end

	if matchStats and matchStats.Signals then
		matchStats.Signals.Closed:Connect(function(player : Player, seconds : number)
			self:_record(player, Events.MatchTime, seconds, self:_context())
		end)
	end

	-- A ultima leitura de quem sai, com o perfil aberto e antes de o `ContractService`
	-- escrever a fila (ele registra depois, com ordem maior).
	if dataService and dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player : Player)
			self:_sync(player)
			self.Reported[player] = nil
			self.Placed[player] = nil
		end)
	end

	-- A amizade e perguntada na entrada, e nao no fim da partida: a pergunta cede, e
	-- na hora da vitoria a resposta ja esta guardada.
	Players.PlayerAdded:Connect(function(player : Player)
		for _, other in Players:GetPlayers() do
			if other ~= player then
				task.spawn(function()
					self:_areFriends(player, other)
				end)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self.Reported[player] = nil
			self.Placed[player] = nil
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(SYNC_INTERVAL)

			if waveService:IsRoundRunning() then
				self:_syncAll()
			end
		end
	end)
end

function ContractTrackerService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function ContractTrackerService:init()
end

return ContractTrackerService
