local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local ShopConfig = SharedConfig.ShopConfig

local Framework = Me.new()

--[=[
	Sells what ShopConfig lists.

	The client only sends an item id -- the price, **which currency it is priced in**,
	what the item grants and whether the player can afford it are all decided here,
	against the profile.
]=]
local ShopService = {
	Services = {
		DataService = {},
		CrateService = {},
	},

	Signals = {
		-- (Player, item : ShopConfig.ShopItem, remaining : number) -- remaining is the
		-- balance of item.Currency after the charge, and not always Shards.
		ItemPurchased = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	Hands the player what the item is worth. Returns false when the item describes a
	reward this service does not know how to grant, so the caller refunds instead of
	charging for nothing.
]=]
function ShopService:_grantItem(Player : Player, item) : boolean
	if item.Crate then
		return self.Services.CrateService:GiveCrates(Player, item.Crate, item.Amount) ~= nil
	end

	warn(string.format("[ShopService]: item %q grants nothing -- give it a Crate in ShopConfig.", tostring(item.Id)))
	return false
end

--[=[
	Devolve o que foi cobrado, na moeda em que foi cobrado.

	`currency` e sempre uma chave de `ShopConfig.CURRENCIES` -- o `resolveItem` ja
	troca uma moeda desconhecida pelo padrao antes de o item chegar aqui, entao o
	refund nao tem como criar um campo que o perfil nao tem.
]=]
function ShopService:_refund(Player : Player, currency : string, amount : number)
	self.Services.DataService:Update(Player, "Stats", function(stats)
		stats = stats or {}
		stats[currency] = (stats[currency] or 0) + amount

		return stats
	end)
end

--[[ EXTERNAL ]]

--[=[
	As chances que a loja publica, por caixa: `{ [Id do item] = { [raridade] = % } }`.

	Sai daqui e nao de um config compartilhado porque as odds sao **do servidor**
	(`ServerScriptService.Config.Crate`) -- o cliente recebe o resultado da conta,
	e nao a tabela que a produz. O que ele recebe ja e a chance real, com a evolucao
	da caixa dentro; ver `Crate.GetDisplayOdds`.

	Item que nao entrega caixa nenhuma fica de fora do mapa, e nao com um mapa vazio:
	quem le sabe distinguir "esta caixa nao tem chance nenhuma" (impossivel) de "este
	item nao e uma caixa".
]=]
function ShopService:GetCrateOdds() : { [string]: { [string]: number } }
	if self.CrateOdds then
		return self.CrateOdds
	end

	local odds = {}

	for _, item in ShopConfig.getItems() do
		if item.Crate then
			local itemOdds = ServerConfig.Crate.GetDisplayOdds(item.Crate)
			if itemOdds then
				odds[item.Id] = itemOdds
			end
		end
	end

	-- Nada aqui muda em tempo de execucao: e config vezes config, e a mesma resposta
	-- vale para todo mundo pelo resto do servidor.
	self.CrateOdds = odds
	return odds
end

--[=[
	Quanto o jogador tem de uma moeda, direto do perfil carregado. `currency` e uma
	chave de `ShopConfig.CURRENCIES`; sem ela, a moeda padrao da loja.

	Devolve nil quando o perfil ainda nao carregou -- que e diferente de zero.
]=]
function ShopService:PeekBalance(Player : Player, currency : string?) : number?
	local profiles = self.Services.DataService.Profiles
	local profile = profiles and profiles[Player]
	if not profile then
		return nil
	end

	local stat = (currency and ShopConfig.CURRENCIES[currency]) or ShopConfig.DEFAULT_CURRENCY
	local stats = profile.Profile.Data.Stats

	return (stats and stats[stat]) or 0
end

--[=[
	Buys one shop item for the player: charges the item's currency and grants the
	reward.

	Returns true on success, or false plus a reason ("UnknownItem", "NotLoaded",
	"NotEnoughCurrency", "GrantFailed"). The check and the charge happen inside a
	single :Update callback, which does not yield -- two clicks landing back to back
	cannot both spend the same balance.
]=]
function ShopService:Purchase(Player : Player, itemId : string?) : (boolean, string?)
	local item = ShopConfig.getItem(itemId)
	if not item then
		warn(string.format("[ShopService]: %s asked for %q, which the shop does not sell.", Player.Name, tostring(itemId)))
		return false, "UnknownItem"
	end

	local DataService = self.Services.DataService
	local profiles = DataService.Profiles

	if not DataService.Update or not profiles or not profiles[Player] then
		warn(string.format("[ShopService]: %s has no profile loaded, ignoring the purchase.", Player.Name))
		return false, "NotLoaded"
	end

	-- Ja e a chave de `Data.Stats`: uma caixa em Coins cobra de `Cash`, que e como o
	-- perfil chama a moeda que a tela chama de Coins.
	local currency = item.Currency

	--[[
		O preco **deste** jogador, com o desconto do VIP ja dentro (`ShopConfig.priceFor`).

		Lido aqui e nao dentro do `Update`: o preco sai de `Data.Gamepasses`, que o
		`Update` de `Stats` nao entrega -- e a mesma conta que o cliente fez para
		escrever o numero no botao, entao o que ele leu e o que ele paga.
	]]
	local price = ShopConfig.priceFor(item, profiles[Player].Profile.Data)

	local charged = false
	local remaining = 0

	DataService:Update(Player, "Stats", function(stats)
		stats = stats or {}

		local owned = stats[currency] or 0
		if owned < price then
			return stats
		end

		remaining = owned - price
		stats[currency] = remaining
		charged = true

		return stats
	end)

	if not charged then
		return false, "NotEnoughCurrency"
	end

	if not self:_grantItem(Player, item) then
		-- The grant is what failed, so hand the money back instead of eating it.
		self:_refund(Player, currency, price)
		return false, "GrantFailed"
	end

	self.Signals.ItemPurchased:Fire(Player, item, remaining)

	return true
end

function ShopService:construct()
	Framework:Listen("RequestBuyShopItem", function(Player : Player, itemId : string)
		local success, reason = self:Purchase(Player, itemId)

		Framework:Fire("ShopPurchaseResult", Player, itemId, success, reason)
	end)

	--[[
		O cliente pede as chances quando liga a loja, em vez de o servidor mandar no
		join: a `ShopUI` e `ResetOnSpawn`, entao o painel e reconstruido a cada
		respawn, e um envio unico no join se perderia na primeira morte. O pedido
		tambem cobre o jogador que entrou antes de o service subir.
	]]
	Framework:Listen("RequestCrateOdds", function(Player : Player)
		Framework:Fire("CrateOdds", Player, self:GetCrateOdds())
	end)
end

function ShopService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function ShopService:init()
	-- The client connects to "ShopPurchaseResult" during its own init, but the server
	-- would only create the event when it first fires it -- and Warp complains that it
	-- "is taking too long to retrieve". Declared here like the other server-only events.
	Framework:Listen("ShopPurchaseResult", function() end)
	Framework:Listen("CrateOdds", function() end)
end

return ShopService
