local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Mexer nas moedas salvas de um jogador: `Stats.Cash` e `Stats.Shards`.

	Hoje sobrou a leitura (`Peek`) e a semente do `Stats.CoinsEarned`. Os comandos
	`cash` e `shards` do Cmdr moraram aqui até precisarem alcançar jogador fora do
	servidor; agora quem escreve por eles é o `ProfileEditService`.

	Não é o dinheiro da partida. Aquele é do `MobService.SessionCash`, vive só
	enquanto o round dura e nem chega ao perfil; quem mexe nele é o `roundcash`, que
	mora na Game junto do service dono dele.

	Fica em `common/` porque as duas places têm perfil aberto — o jogador pode estar
	no lobby ou no meio de uma partida quando o comando roda.
]]

local CurrencyService = {
	Services = {
		DataService = {}
	}
}

-- As chaves de `Data.Stats` que este service aceita mexer. Escrever uma chave que
-- o template não tem criaria um campo fantasma no perfil, que ninguem le.
CurrencyService.Stats = {
	Cash = "Cash",
	Shards = "Shards",
}

--[[ INTERNAL ]]

--[=[
	Cria o `Stats.CoinsEarned` (o total de coins ganhos, da MOST COINS) no perfil
	que ainda nao tem, comecando pelo saldo atual.

	O saldo e o minimo que o jogador ja ganhou, entao e o melhor ponto de partida
	para quem jogava antes da chave existir -- melhor que zero, que o poria atras
	de quem acabou de chegar. Perfil novo tem saldo zero e comeca do zero.

	E por isso que a chave nao esta no template (ver `Config.Data`): o reconcile a
	criaria em zero antes de este service ver que ela faltava. Roda uma vez por
	perfil, e so enquanto a chave nao existe.
]=]
function CurrencyService:_seedCoinsEarned(player : Player)
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]
	local stats = entry and entry.Profile.Data.Stats

	if typeof(stats) ~= "table" or stats.CoinsEarned ~= nil then
		return
	end

	dataService:Update(player, "Stats", function(current)
		if current.CoinsEarned == nil then
			current.CoinsEarned = math.max(0, math.floor(tonumber(current.Cash) or 0))
		end

		return current
	end)
end

--[[ API ]]

--[=[
	Le uma moeda do perfil aberto, ou `nil` se o perfil ainda nao carregou.
]=]
function CurrencyService:Peek(player : Player, stat : string) : number?
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]
	if not entry then
		return nil
	end

	local stats = entry.Profile.Data.Stats

	return (stats and stats[stat]) or 0
end

--[[ CICLO DE VIDA ]]

function CurrencyService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		warn("[CurrencyService]: sem DataService; o CoinsEarned de perfis antigos nao vai ser criado.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_seedCoinsEarned(player)
	end)

	-- Quem carregou antes deste service subir: o sinal deles ja passou.
	for _, player in Players:GetPlayers() do
		self:_seedCoinsEarned(player)
	end
end

function CurrencyService:start()
	-- Com espera: o `construct` agora escuta o `PlayerDataLoaded`, e um DataService
	-- que ainda nao subiu deixaria o perfil antigo sem o `CoinsEarned`.
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function CurrencyService:init()
end

return CurrencyService
