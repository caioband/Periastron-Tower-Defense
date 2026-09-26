local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Mexer nas moedas salvas de um jogador: `Stats.Cash` e `Stats.Shards`.

	Escreve moeda num jogador **deste servidor** (`Apply`): é por aqui que o
	`RobuxShopService` credita os packs de coins. Também lê (`Peek`) e semeia o
	`Stats.CoinsEarned`.

	Os comandos `cash` e `shards` do Cmdr não passam mais por aqui: eles alcançam
	jogador fora do servidor, e quem escreve por eles é o `ProfileEditService`.
	**Não apague o `Apply` achando que era só dos comandos** — sem ele o callback do
	pack erra, o recibo volta como `NotProcessedYet` e ninguém recebe as coins.

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
	O valor depois da operacao. Nunca negativo: saldo negativo nao existe em lugar
	nenhum do jogo, e um `remove` grande demais e engano de quem digitou, nao um
	pedido para dever.
]=]
local function applyAction(action : string, current : number, amount : number) : number
	if action == "set" then
		return math.max(amount, 0)
	elseif action == "remove" then
		return math.max(current - amount, 0)
	end

	return math.max(current + amount, 0)
end

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

--[=[
	Aplica `set`, `add` ou `remove` numa moeda e devolve `(anterior, novo)`, ou
	`nil` mais o motivo.

	A leitura e a escrita acontecem dentro do mesmo `Update`, e nao em volta dele:
	e o que garante que o `add` some em cima do valor que esta la agora, e nao no
	que estava quando o comando foi digitado.
]=]
function CurrencyService:Apply(player : Player, stat : string, action : string, amount : number) : (number?, number?, string?)
	if not self.Stats[stat] then
		return nil, nil, string.format("'%s' nao e uma moeda conhecida.", tostring(stat))
	end

	local dataService = self.Services.DataService
	if not dataService then
		return nil, nil, "DataService indisponivel."
	end

	if not (dataService.Profiles and dataService.Profiles[player]) then
		return nil, nil, string.format("o perfil de %s ainda nao carregou.", player.Name)
	end

	local previous, updated = 0, 0

	dataService:Update(player, "Stats", function(stats)
		stats = stats or {}

		previous = stats[stat] or 0
		updated = applyAction(action, previous, amount)
		stats[stat] = updated

		return stats
	end)

	return previous, updated, nil
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
