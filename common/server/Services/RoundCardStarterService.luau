local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local RoundCardShopConfig = SharedConfig.RoundCardShopConfig

--[=[
	O kit inicial de cartas de round, garantido em todo perfil aberto.

	O `Data.Template` entrega o `STARTER_CARDS` a quem chega, e só a quem chega: o
	reconcile do `DataService` cria a chave `RoundCards` onde ela falta, mas nunca
	mexe numa que já existe. Sem este service, toda carta acrescentada ao kit valeria
	apenas para contas criadas depois dela -- dois jogadores na mesma sala montariam
	a oferta de round a partir de catálogos diferentes, sem nada na tela dizendo por
	quê.

	Ele escreve **só o que falta**, e só quando falta: o perfil que já está em dia não
	é tocado. Carta que o jogador comprou com shards já está no `RoundCards` dele e
	por isso não aparece na lista -- ninguém é reembolsado nem tem compra desfeita.

	Fica em `common/` porque as duas places abrem perfil: o jogador pode entrar pelo
	lobby ou cair direto numa partida, e a oferta de round é montada na Game a partir
	do que estiver escrito aqui.
]=]
local RoundCardStarterService = {
	Services = {
		DataService = {},
	},
}

--[[ INTERNAL ]]

--[=[
	Escreve no perfil deste jogador as cartas do kit que ainda faltam.

	Roda uma vez por perfil carregado. A lista é conferida de novo **dentro** do
	`Update`, e não só antes dele: entre a leitura e a escrita cabe uma compra na loja
	de cartas do lobby, e o `RoundCards` que vale é o que estiver na mão do callback.
]=]
function RoundCardStarterService:_seed(player : Player)
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]
	local data = entry and entry.Profile and entry.Profile.Data

	if typeof(data) ~= "table" then return end

	local missing = RoundCardShopConfig.missingStarters(data.RoundCards)
	if #missing == 0 then return end

	dataService:Update(player, "RoundCards", function(unlocked)
		if typeof(unlocked) ~= "table" then
			unlocked = {}
		end

		for _, cardId in RoundCardShopConfig.missingStarters(unlocked) do
			unlocked[cardId] = true
		end

		return unlocked
	end)

	print(string.format("[RoundCardStarterService]: %s ganhou o kit que faltava (%s).",
		player.Name, table.concat(missing, ", ")))
end

--[[ CICLO DE VIDA ]]

function RoundCardStarterService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		warn("[RoundCardStarterService]: sem DataService; o kit de perfis antigos nao vai ser escrito.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_seed(player)
	end)

	-- Quem carregou antes deste service subir: o sinal deles ja passou.
	for _, player in Players:GetPlayers() do
		self:_seed(player)
	end
end

function RoundCardStarterService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function RoundCardStarterService:init()
end

return RoundCardStarterService
