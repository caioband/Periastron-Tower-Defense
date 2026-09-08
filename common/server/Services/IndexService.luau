local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local IndexConfig = SharedConfig.IndexConfig

local Framework = Me.new()

--[[
	O Index do jogador: quem escreve.

	A estrutura e as regras estao no `SharedConfig.IndexConfig` -- aqui e so a
	porta de escrita, e ela e uma so para as duas places. Cada gatilho chama de
	onde a informacao existe:

	  - unit obtida -> `CrateService` e `SummoningService` (Lobby)
	  - mapa jogado -> `MapService` (Game), que e quem sabe qual mapa entrou
	  - enemies     -> ainda ninguem; a categoria existe vazia de proposito

	**Descobrir e para sempre.** Nada aqui apaga: uma unit vendida continua
	descoberta, porque o Index e memoria do que o jogador ja viu, e nao inventario.

	**O perfil que ja existia tambem conta.** Quando o perfil carrega, as units que
	o jogador ja tem entram no Index de uma vez (`_syncOwnedUnits`). Sem isso, quem
	jogava antes do Index existir comecaria com o catalogo vazio segurando um deck
	cheio -- e cada unit dele so entraria no dia em que ele tirasse outra copia da
	mesma numa caixa.
]]
local IndexService = {
	Services = {
		DataService = {},
	},
}

--[[ INTERNAL ]]

--- O perfil aberto do jogador, ou nil enquanto ele nao carregou.
function IndexService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

--[=[
	Escreve as chaves novas de uma categoria numa passada so.

	Uma escrita por chave custaria uma replicacao por chave, e o caso normal do
	`_syncOwnedUnits` e justamente um punhado de uma vez. Devolve quantas eram
	novas -- zero quer dizer que nada foi escrito, e nada foi replicado.
]=]
function IndexService:_unlock(player : Player, category : string, keys : { string }) : number
	if not IndexConfig.isCategory(category) then
		warn(string.format("[IndexService]: %q nao e uma categoria do Index.", tostring(category)))
		return 0
	end

	local dataService = self.Services.DataService
	if not dataService or not dataService.Update then
		warn("[IndexService]: DataService nao esta pronto; descoberta ignorada.")
		return 0
	end

	local profile = self:_profileOf(player)
	if not profile then
		return 0
	end

	-- Filtra antes de escrever: `Update` replica a chave inteira, entao reescrever
	-- o que ja estava la manda uma replicacao para dizer nada.
	local pending = {}
	for _, key in keys do
		if typeof(key) == "string" and key ~= "" and not IndexConfig.has(profile, category, key) then
			table.insert(pending, key)
		end
	end

	if #pending == 0 then
		return 0
	end

	dataService:Update(player, "Index", function(index)
		index = typeof(index) == "table" and index or IndexConfig.createEmpty()

		local entries = index[category]
		if typeof(entries) ~= "table" then
			entries = {}
			index[category] = entries
		end

		for _, key in pending do
			entries[key] = true
		end

		return index
	end)

	return #pending
end

--[=[
	As units que o jogador ja tem entram no Index quando o perfil carrega.

	So conta copia de verdade (`amount > 0`): uma entrada zerada e uma unit que ele
	teve e nao tem mais -- e essa ja teria sido descoberta no dia em que ele a
	obteve.
]=]
function IndexService:_syncOwnedUnits(player : Player)
	local profile = self:_profileOf(player)
	local units = profile and profile.Units

	if typeof(units) ~= "table" then return end

	local owned = {}
	for unitName, amount in units do
		if typeof(unitName) == "string" and (tonumber(amount) or 0) > 0 then
			table.insert(owned, unitName)
		end
	end

	self:_unlock(player, "Units", owned)
end

--[[ API ]]

--[=[
	Descobre uma chave numa categoria. Devolve `true` so quando ela era nova --
	e por esse retorno que um "novo no index!" na tela sabe que tem o que anunciar.
]=]
function IndexService:Unlock(player : Player, category : string, key : string) : boolean
	return self:_unlock(player, category, { key }) > 0
end

--- Varias chaves de uma vez, numa escrita so. Devolve quantas eram novas.
function IndexService:UnlockMany(player : Player, category : string, keys : { string }) : number
	return self:_unlock(player, category, keys)
end

--- A unit obtida entrou no catalogo do jogador.
function IndexService:UnlockUnit(player : Player, unitName : string) : boolean
	return self:Unlock(player, "Units", unitName)
end

--- O mapa que o jogador acabou de jogar entrou no catalogo dele.
function IndexService:UnlockMap(player : Player, mapName : string) : boolean
	return self:Unlock(player, "Maps", mapName)
end

--- Se o jogador ja descobriu esta chave.
function IndexService:Has(player : Player, category : string, key : string) : boolean
	return IndexConfig.has(self:_profileOf(player), category, key)
end

--[[ CICLO DE VIDA ]]

function IndexService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		warn("[IndexService]: sem DataService; o Index nao vai ser escrito.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_syncOwnedUnits(player)
	end)

	-- Quem ja estava dentro quando este service subiu: o sinal deles ja passou.
	for _, player in Players:GetPlayers() do
		if self:_profileOf(player) then
			self:_syncOwnedUnits(player)
		end
	end
end

function IndexService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function IndexService:init()
end

return IndexService
