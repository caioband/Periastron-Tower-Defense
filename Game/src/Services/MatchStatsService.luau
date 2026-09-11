local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local Framework = Me.new()

local MIN_MATCH_SECONDS = ServerConfig.Data.MIN_MATCH_SECONDS

--[[
	`Stats.MatchesPlayed` e `Stats.TimeInMatches`: quanto tempo cada jogador passa
	dentro de um round, e quantas partidas passaram de `MIN_MATCH_SECONDS`.

	"Dentro de um round" e o `WaveService` em `Running` -- da espera pelos jogadores
	e da votacao de dificuldade ate a ultima wave. A tela de resultado e o intervalo
	parado em `Idle` nao contam. O tempo e o de verdade (`os.clock`), e nao o do
	`GameClock`: acelerar a partida nao encurta o tempo que o jogador passou nela.

	Cada jogador tem o proprio relogio (`JoinedAt`), que abre quando o round comeca
	ou quando ele entra num round ja rodando, e fecha em um de dois lugares:

	  - o round fechou (`WaveService.Signals.RoundClosed`) -- fim da partida ou reset;
	  - ele saiu, ou o servidor desligou (`DataService:OnBeforeRelease`, com o perfil
	    ainda aberto).

	Fechar e escrever: o tempo vai inteiro para `TimeInMatches`, e se passou do piso
	a partida entra em `MatchesPlayed`. Uma partida so conta uma vez por jogador,
	porque fechar tira o relogio dele -- quem sai e volta para o mesmo round comeca
	um relogio novo, e so conta de novo se ficar outro `MIN_MATCH_SECONDS`.
]]
local MatchStatsService = {
	Services = {
		DataService = {},
		WaveService = {},
	},

	-- [Player] = `os.clock()` de quando ele entrou no round rodando.
	JoinedAt = {},

	Signals = {
		--[[
			(player, seconds) -- o relogio do jogador fechou, com o tempo que ele passou
			naquele round. Dispara antes de o perfil fechar, na saida tambem. Quem escuta
			e o `ContractTrackerService` ("Play 7 hours worth of matches").
		]]
		Closed = Signal.new(),
	},
}

--[[ INTERNAL ]]

function MatchStatsService:_open(player : Player)
	if self.JoinedAt[player] == nil then
		self.JoinedAt[player] = os.clock()
	end
end

--- Fecha o relogio do jogador e escreve o que ele valeu.
function MatchStatsService:_close(player : Player)
	local joinedAt = self.JoinedAt[player]
	if not joinedAt then return end

	self.JoinedAt[player] = nil

	local seconds = math.floor(os.clock() - joinedAt)
	if seconds <= 0 then return end

	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	if not (profiles and profiles[player]) then return end

	self.Signals.Closed:Fire(player, seconds)

	dataService:Update(player, "Stats", function(stats)
		stats.TimeInMatches = (tonumber(stats.TimeInMatches) or 0) + seconds

		if seconds >= MIN_MATCH_SECONDS then
			stats.MatchesPlayed = (tonumber(stats.MatchesPlayed) or 0) + 1
		end

		return stats
	end)
end

function MatchStatsService:_openAll()
	for _, player in Players:GetPlayers() do
		self:_open(player)
	end
end

function MatchStatsService:_closeAll()
	for player in self.JoinedAt do
		self:_close(player)
	end
end

--[[ CICLO DE VIDA ]]

function MatchStatsService:construct()
	local waveService = self.Services.WaveService
	local dataService = self.Services.DataService

	if not waveService then
		warn("[MatchStatsService]: sem WaveService; partidas e tempo em partida nao vao ser contados.")
		return
	end

	waveService.Signals.RoundStarted:Connect(function()
		self:_openAll()
	end)

	waveService.Signals.RoundClosed:Connect(function()
		self:_closeAll()
	end)

	Players.PlayerAdded:Connect(function(player : Player)
		if waveService:IsRoundRunning() then
			self:_open(player)
		end
	end)

	if dataService and dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player : Player)
			self:_close(player)
		end)
	end

	-- Limpeza para quem saiu sem perfil aberto (o gancho acima nem roda).
	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self.JoinedAt[player] = nil
		end)
	end)

	-- O primeiro round comeca no `start` do WaveService, que pode ter rodado antes
	-- deste: o `RoundStarted` dele ja passou.
	if waveService:IsRoundRunning() then
		self:_openAll()
	end
end

function MatchStatsService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function MatchStatsService:init()
end

return MatchStatsService
