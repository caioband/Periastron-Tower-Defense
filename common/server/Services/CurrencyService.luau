local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Mexer nas moedas salvas de um jogador: `Stats.Cash` e `Stats.Shards`.

	É a escrita que o `DataService` já fazia espalhada (`WaveService` creditando o
	fim de round, `ShopService` cobrando um item), reunida num lugar só para quem
	precisa **mandar** um valor — hoje, os comandos `cash` e `shards` do Cmdr.

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

--[=[
	O que os comandos `cash` e `shards` do Cmdr chamam: a operacao aplicada na lista
	inteira de jogadores, ja com a linha que o console imprime.

	Mora aqui, e nao no comando, porque os dois comandos sao a mesma coisa com uma
	chave diferente -- e porque quem sabe o que aconteceu com o perfil e este
	service. O comando fica sendo so o nome, os argumentos e quem chamar.

	A resposta diz o **antes e o depois** de cada um de proposito: `remove` que bate
	no chao e `set` num valor que ja era aquele sao invisiveis sem isso, e os dois
	parecem "o comando nao funcionou".
]=]
function CurrencyService:RunCommand(stat : string, action : string, players : { Player }, amount : number) : string
	if #players == 0 then
		return "Nobody matched."
	end

	local done, failed = {}, {}

	for _, player in players do
		local previous, updated, err = self:Apply(player, stat, action, amount)

		if updated then
			table.insert(done, string.format("%s %d -> %d", player.Name, previous, updated))
		else
			table.insert(failed, string.format("%s (%s)", player.Name, err or "unknown error"))
		end
	end

	local lines = {}

	if #done > 0 then
		table.insert(lines, string.format("%s %s: %s", action, stat, table.concat(done, ", ")))
	end

	if #failed > 0 then
		table.insert(lines, string.format("Skipped %d: %s", #failed, table.concat(failed, ", ")))
	end

	return table.concat(lines, " | ")
end

--[[ CICLO DE VIDA ]]

function CurrencyService:construct()
end

function CurrencyService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function CurrencyService:init()
end

return CurrencyService
