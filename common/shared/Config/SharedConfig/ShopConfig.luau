--[[
	Single source of truth for the lobby shop.

	O `ShopController` le isto para preencher a `ShopUI`. **Ele nao cria container
	nenhum**: cada caixa tem o container dela autorado na `ScrollingFrame`, com a
	arte propria, e o codigo so acha o container pelo nome e escreve o que muda --
	o nome, o preco e a lista de raridades. Um item sem container autorado nao
	aparece (e avisa uma vez), e um container sem item na tabela fica escondido.

	Foi uma troca de dono: antes existia um `ShopItemWrapper` autorado que o
	controller clonava por item. Nao serve mais -- cada caixa tem ilustracao,
	moldura e cor de linha diferentes, e clonar um template so daria tres caixas com
	a cara da primeira.

	Crate rows carry only the crate name: o nome, o icone e o **nome do container**
	saem do `CrateConfig`, entao a loja nunca repete o que a caixa ja sabe.

	Nothing here is secret. Granting the item is server side -- the client only
	asks, and ServerScriptService validates the price against the profile. As
	**chances** de cada caixa tambem sao do servidor: elas chegam pelo evento
	`CrateOdds`, e nao desta tabela.
]]

local CrateConfig = require(script.Parent.CrateConfig)

local module = {}

--[[ ANIMATION ]]

--[=[
	Module name inside ReplicatedStorage.CascadeAnimations. `OpenShop` anima duas
	faixas: o `Scale` de um `UIScale` filho e o `ImageTransparency` do painel.

	O `UIScale` e criado pelo controller quando o painel nao tem um autorado --
	sem ele a faixa nao tem onde escrever e a loja so apareceria por fade.

	A animacao de item (`ShopItemContainerShow`) saiu junto com o template: ela
	movia `Position.X.Scale`, e os containers de hoje estao sob um `UIListLayout`,
	que e quem manda na posicao deles. A faixa nao teria efeito nenhum.
]=]
module.OPEN_ANIMATION = "OpenShop"

--[[ PROXIMITY ]]

-- The shop opens when the player walks up to this part and closes when they leave.
-- It lives at Workspace.<REFERENCE_PARENT_NAME>.<REFERENCE_PART_NAME>.
module.REFERENCE_PARENT_NAME = "Map"
module.REFERENCE_PART_NAME = "ShopPartReference"

--[[
	Studs from the part, measured against the HumanoidRootPart.

	Não pode cair abaixo de ~15: o `ShopPartTeleport` fica a 14.5 studs daqui, e o
	botão da HUD conta com o pouso dele estar **dentro** deste raio para a loja abrir
	sozinha. Abaixo disso o botão levaria o jogador até a loja e nada aconteceria.
]]
module.OPEN_RADIUS = 20

-- How often the distance is checked. The radius is wide enough that a fifth of a
-- second is imperceptible and cheaper than measuring every frame.
module.PROXIMITY_INTERVAL = 0.2

--[[ TELEPORT ]]

-- Where the HUD shop button drops the player: a marker part next to the shop, at
-- Workspace.<REFERENCE_PARENT_NAME>.<TELEPORT_PART_NAME>. It sits inside the open
-- radius above, so landing there opens the shop on its own.
module.TELEPORT_PART_NAME = "ShopPartTeleport"

-- Studs above the top of the marker, so the character lands standing on it instead
-- of half sunk into it.
module.TELEPORT_HEIGHT_OFFSET = 3

--[[ ITEMS ]]

--[[
	O preco no label do botao `Buy`: `50`, `1,800`.

	So o numero. A moeda nao vem escrita: o botao carrega o icone dela ao lado (ver
	`CURRENCIES`), e repetir a palavra so roubava largura do numero, que e a unica
	parte que muda de caixa para caixa.

	O numero entra pelo `UIUtil.formatCommas`, entao a lendaria le `1,800` e nao
	`1800`.
]]
module.PRICE_FORMAT = "%s"

module.DEFAULT_BUTTON_TEXT = "BUY"

--[[ CURRENCIES ]]

--[=[
	As moedas que a loja aceita, pela chave que elas tem em `Data.Stats`.

	**O nome da chave e o nome no perfil, e nao o nome na tela**: o jogador le
	"Coins" e o perfil guarda `Cash` desde sempre (ver o `LeaderstatsService`).
	Escrever aqui a palavra da tela criaria um `Stats.Coins` fantasma no dia em que
	o servidor cobrasse por ela.

	Quem pinta o botao com a cor e o icone de cada moeda e o `ShopController` -- isto
	aqui e so o que o servidor precisa saber para cobrar.
]=]
module.CURRENCIES = {
	Shards = "Shards",
	Cash = "Cash",
}

-- Item sem `Currency` cobra em Shards, que era a unica moeda da loja antes de a
-- caixa comum e a de natureza passarem a custar Coins.
module.DEFAULT_CURRENCY = "Shards"

--[=[
	Fields per item:
		Id            unique, what the client sends to the server on purchase
		Order         top to bottom inside the scrolling frame
		Price         how much of Currency the purchase costs
		Currency      optional: a key of CURRENCIES, defaults to DEFAULT_CURRENCY
		Crate         optional: fills DisplayName/Image/Container from CrateConfig
		              and marks the item as granting that crate
		Amount        how many the purchase grants (defaults to 1)
		DisplayName   optional override of the name shown on the row
		Image         optional override of the icon shown on the row
		ButtonText    optional override of the confirm button label
]=]

--[[
	**A loja cobra em duas moedas, e nao mais so em shards.**

	As duas primeiras caixas passaram a custar Coins (`Stats.Cash`), que e o que o
	jogador acumula jogando, e as duas de baixo continuam em Shards. E o degrau que
	faltava: com tudo em shards, a caixa comum concorria com a lendária pela mesma
	carteira, e quem quisesse a lendária nao tinha razao nenhuma para comprar as
	outras.

	Os precos sao contra o que uma run **completa** paga hoje (ver `WinCash` e
	`WinShards` em `Config.Difficulty`): 100 coins e 1 shard no Facil, 900 coins e 5
	shards no Nightmare. Nessa escala, a Crate Of Beginnings sai a cada meia run no
	Facil e a Fragmented Crate a cada run no Nightmare.

	**A lendária esta fora de escala.** Os 1800 shards dela sao de quando uma run
	pagava 60 shards no Médio; com 5 no Nightmare, sao 360 partidas. Ela nao aparece
	na loja hoje (nao ha container `LegendaryCrate` autorado), entao o numero nao
	chega a nenhum jogador -- mas ele precisa ser repreçado antes de ela voltar.
]]
module.ITEMS = {
	{
		Id = "CrateOfBeginnings",
		Order = 1,
		Crate = "Common",
		Price = 50,
		Currency = "Cash",
	},

	{
		Id = "CrateOfNature",
		Order = 2,
		Crate = "Rare",
		Price = 200,
		Currency = "Cash",
	},

	{
		Id = "FragmentedCrate",
		Order = 3,
		Crate = "Epic",
		Price = 4,
		Currency = "Shards",
	},

	--[[
		A lendaria continua a venda na tabela e **fica de fora da tela**: a
		`ScrollingFrame` so tem container autorado para as tres de cima, e o
		controller so desenha caixa que tem container.

		Ela nao foi removida daqui de proposito -- ela existe no inventario, no drop e
		no unboxing, e o dia em que um container `LegendaryCrate` for autorado ela
		volta a aparecer sem ninguem mexer em codigo.
	]]
	{
		Id = "LegendaryCrate",
		Order = 4,
		Crate = "Legendary",
		Price = 1800,
		Currency = "Shards",
	},
}

export type ShopItem = {
	Id: string,
	Order: number,
	Price: number,
	Currency: string,
	Amount: number,
	DisplayName: string,
	Image: string,
	ButtonText: string,
	Crate: string?,
	Container: string,
}

--[=[
	A moeda que o item cobra, ja como chave de `Data.Stats`.

	Uma moeda que a tabela nao conhece cai no padrao com um aviso, em vez de virar
	`stats[nil]` no servidor: um erro de digitacao aqui cobraria de um campo que o
	perfil nao tem, e a caixa sairia de graca.
]=]
local function resolveCurrency(item): string
	local currency = item.Currency
	if currency == nil then
		return module.DEFAULT_CURRENCY
	end

	if not module.CURRENCIES[currency] then
		warn(`[ShopConfig]: item '{item.Id}' prices in unknown currency '{currency}', falling back to {module.DEFAULT_CURRENCY}.`)
		return module.DEFAULT_CURRENCY
	end

	return module.CURRENCIES[currency]
end

--[=[
	Resolves one raw entry into the row the UI renders. Returns nil (and warns)
	when the entry points at a crate that does not exist, so a typo drops a single
	row instead of breaking the whole shop.
]=]
local function resolveItem(item): ShopItem?
	local displayName = item.DisplayName
	local image = item.Image
	local crate = nil
	local container = item.Container

	if item.Crate then
		crate = CrateConfig.resolveRarity(item.Crate)
		if not crate then
			warn(`[ShopConfig]: item '{item.Id}' points at unknown crate '{item.Crate}'.`)
			return nil
		end

		local crateInfo = CrateConfig.CRATES[crate]
		displayName = displayName or crateInfo.DisplayName
		image = image or crateInfo.Image

		-- O container e o `Key` da caixa: um nome so para o modelo, para o container
		-- e para o `Id` daqui. Ver o comentario de `CRATES` no `CrateConfig`.
		container = container or crateInfo.Key
	end

	return {
		Id = item.Id,
		Order = item.Order or 0,
		Price = item.Price or 0,
		Currency = resolveCurrency(item),
		Amount = item.Amount or 1,
		DisplayName = displayName or item.Id,
		Image = image or "",
		ButtonText = item.ButtonText or module.DEFAULT_BUTTON_TEXT,
		Crate = crate,
		Container = container or item.Id,
	}
end

--[=[
	Every item the shop shows, already resolved and sorted by Order.
]=]
function module.getItems(): { ShopItem }
	local items = {}

	for _, item in module.ITEMS do
		local resolved = resolveItem(item)
		if resolved then
			table.insert(items, resolved)
		end
	end

	table.sort(items, function(a, b)
		return a.Order < b.Order
	end)

	return items
end

--[=[
	Returns the resolved item with that Id, or nil when the shop has no such item.
	The server uses this to price a purchase request.
]=]
function module.getItem(id: string?): ShopItem?
	if typeof(id) ~= "string" then
		return nil
	end

	for _, item in module.ITEMS do
		if item.Id == id then
			return resolveItem(item)
		end
	end

	return nil
end

return module
