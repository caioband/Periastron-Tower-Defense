local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	O tempo de jogo no perfil (`Stats.TimePlayed`, em segundos), nas duas places.

	Conta do perfil carregado ate a sessao fechar -- antes disso nao ha onde
	escrever, e a diferenca sao segundos. O teleporte entre Lobby e Game fecha a
	sessao numa place e abre na outra, entao o tempo das duas soma no mesmo numero.

	**Por que escreve de minuto em minuto, e nao so na saida.** A leaderboard le o
	perfil de quem esta no servidor; guardando so na saida, quem fica horas no
	lobby nao se mexeria nela ate ir embora. E um servidor que cai leva no maximo o
	ultimo minuto.

	O resto fracionario nao se perde: `Since` anda so os segundos inteiros que
	foram escritos, e a fracao entra no proximo minuto.
]]

local FLUSH_INTERVAL = 60

local PlaytimeService = {
	Services = {
		DataService = {},
	},

	-- [Player] = `os.clock()` do ultimo segundo ja escrito.
	Since = {},
}

--[[ INTERNAL ]]

function PlaytimeService:_hasProfile(player : Player) : boolean
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles

	return profiles ~= nil and profiles[player] ~= nil
end

function PlaytimeService:_track(player : Player)
	if self.Since[player] == nil then
		self.Since[player] = os.clock()
	end
end

--- Escreve no perfil os segundos inteiros desde a ultima escrita.
function PlaytimeService:_flush(player : Player)
	local since = self.Since[player]
	if not since or not self:_hasProfile(player) then return end

	local seconds = math.floor(os.clock() - since)
	if seconds <= 0 then return end

	self.Since[player] = since + seconds

	self.Services.DataService:Update(player, "Stats", function(stats)
		stats.TimePlayed = (tonumber(stats.TimePlayed) or 0) + seconds
		return stats
	end)
end

--[[ CICLO DE VIDA ]]

function PlaytimeService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		warn("[PlaytimeService]: sem DataService; o tempo de jogo nao vai ser contado.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_track(player)
	end)

	-- Quem carregou antes deste service subir: o sinal deles ja passou.
	for _, player in Players:GetPlayers() do
		if self:_hasProfile(player) then
			self:_track(player)
		end
	end

	-- O ultimo pedaco entra com o perfil ainda aberto, nos dois caminhos de saida.
	if dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player : Player)
			self:_flush(player)
			self.Since[player] = nil
		end)
	end

	-- Limpeza para quem saiu sem perfil aberto (o gancho acima nem roda).
	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self.Since[player] = nil
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)

			for player in self.Since do
				self:_flush(player)
			end
		end
	end)
end

function PlaytimeService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function PlaytimeService:init()
end

return PlaytimeService
