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
	O preco no label do botao `Buy`: `100 Shards`, `1,800 Shards`.

	A moeda vem escrita por extenso, e nao como o `$` que o label esta autorado com:
	o que se paga aqui e Shard, a moeda que so cai para quem termina a partida, e
	confundi-la com a caixa da partida (que e o que um `$` sugere) e o tipo de erro
	que o jogador so descobre depois de clicar.

	O numero entra pelo `UIUtil.formatCommas`, entao a lendaria le `1,800 Shards` e
	nao `1800 Shards`.
]]
module.PRICE_FORMAT = "%s Shards"

module.DEFAULT_BUTTON_TEXT = "BUY"

--[=[
	Fields per item:
		Id            unique, what the client sends to the server on purchase
		Order         top to bottom inside the scrolling frame
		Price         in Shards (the premium currency, Data.Template.Stats.Shards)
		Crate         optional: fills DisplayName/Image/Container from CrateConfig
		              and marks the item as granting that crate
		Amount        how many the purchase grants (defaults to 1)
		DisplayName   optional override of the name shown on the row
		Image         optional override of the icon shown on the row
		ButtonText    optional override of the confirm button label
]=]

--[[
	Preços em shards, calibrados contra o que uma partida rende (60 no Médio, 180 no
	Nightmare): a crate comum sai a cada duas partidas no Médio e a lendária a cada
	dez no Nightmare. Antes o Médio rendia 30 e a lendária custava 1500 — cinquenta
	partidas —, então a loja ficava fora de alcance e o banner era a única rota real
	para unidades novas.
]]
module.ITEMS = {
	{
		Id = "CrateOfBeginnings",
		Order = 1,
		Crate = "Common",
		Price = 100,
	},

	{
		Id = "CrateOfNature",
		Order = 2,
		Crate = "Rare",
		Price = 300,
	},

	{
		Id = "FragmentedCrate",
		Order = 3,
		Crate = "Epic",
		Price = 800,
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
	},
}

export type ShopItem = {
	Id: string,
	Order: number,
	Price: number,
	Amount: number,
	DisplayName: string,
	Image: string,
	ButtonText: string,
	Crate: string?,
	Container: string,
}

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
