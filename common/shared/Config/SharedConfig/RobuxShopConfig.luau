--[[
	A loja de Robux do lobby: `StarterGui.ShopUI.RobuxShop`.

	Ela e uma vitrine e nada mais. As seis gamepasses e os tres packs de coins abrem
	o prompt da Roblox, e quem credita e quem sempre creditou: a pass e um **estado**
	que o `MonetizationService` confere na entrada (`RecalibratePasses`), e o pack e um
	**evento** que o `ProcessReceipt` paga uma vez so, pelo `RobuxShopService`.

	Por isso aqui nao ha nada alem de nomes e numeros: o que cada linha da UI vende. O
	beneficio de cada pass continua no `GamepassConfig` -- esta tabela so diz que o
	`GP1` da tela e a pass `VIP` de la, e nunca o que o VIP faz. Duas fontes para a
	mesma coisa e como uma pass ganha um beneficio na loja que ela nao tem no jogo.

	Nada disto e sigiloso: os ids estao na pagina de cada produto, o preco e a Roblox
	quem desenha no prompt, e o cliente precisa dos numeros para abrir a compra. O que
	e sigiloso continua onde estava (ver `ServerScriptService.Config`).
]]

local module = {}

--[=[
	O caminho da UI. O `Wrapper` e a moldura que vai e vem, e o `Panel` e a arte que a
	`OPEN_ANIMATION` anima -- a `ShopUI` carrega tres lojas, e cada uma acende a sua
	(ver `ProximityPanel`).

	As linhas moram em duas `ScrollingFrame` de **mesmo nome** dentro do painel (uma
	das passes, outra dos packs), entao cada linha e procurada pelo nome dela em
	profundidade a partir do painel, e nunca pelo caminho da lista.
]=]
module.Gui = {
	ScreenGui = "ShopUI",
	Wrapper = "RobuxShop",
	Panel = "ImageLabel",

	-- O botao de comprar de uma linha, e o texto dentro dele.
	Buy = "BUY",
}

module.OPEN_ANIMATION = "OpenShop"

--[=[
	O texto do botao. `OWNED` e para a pass que este jogador ja tem -- o botao apaga e
	para de abrir o prompt, do mesmo jeito que o CLAIM de um contrato ja resgatado.

	Pack de coins nao tem estado: ele pode ser comprado de novo quantas vezes quiser.
]=]
module.BUY_TEXT = "BUY"
module.OWNED_TEXT = "OWNED"

--[=[
	As gamepasses da vitrine, uma por linha da UI, na ordem em que o designer as
	desenhou.

	`Frame` e o nome da linha na tela; `Pass` e a chave do `GamepassConfig.PASSES`, de
	onde sai o id que o prompt abre e onde o perfil diz se o jogador ja tem.
]=]
module.PASSES = {
	{ Frame = "GP1", Pass = "VIP" },
	{ Frame = "GP2", Pass = "Shards" },
	{ Frame = "GP3", Pass = "Luck" },
	{ Frame = "GP4", Pass = "CardSlots" },
	{ Frame = "GP5", Pass = "Coins" },
	{ Frame = "GP6", Pass = "Speed" },
}

--[=[
	Os packs de coins, uma linha por developer product.

	`Coins` e o que o servidor deposita no `Stats.Cash` quando o recibo chega. Ele
	**nao** entra no `Stats.CoinsEarned`: a board MOST COINS e o que o jogador ganhou
	jogando, e nao o que ele comprou (ver o `RobuxShopService`).
]=]
module.PACKS = {
	{ Frame = "DEVPROD1", ProductId = 3713311022, Coins = 200 },
	{ Frame = "DEVPROD2", ProductId = 3713311161, Coins = 1400 },
	{ Frame = "DEVPROD3", ProductId = 3713311237, Coins = 7000 },
}

--[=[
	O pack de um `ProductId`, ou nil. E como o recibo volta: ele so diz o numero do
	produto.
]=]
function module.packOfProduct(productId : number?)
	for _, pack in module.PACKS do
		if pack.ProductId == productId then
			return pack
		end
	end

	return nil
end

return module
