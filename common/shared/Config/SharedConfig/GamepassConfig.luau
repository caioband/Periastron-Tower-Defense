--[[
	As gamepasses: o id de cada uma e o que ela muda no jogo.

	Fonte unica dos dois lados. O servidor pergunta a Roblox quem tem o que e grava
	no perfil (`MonetizationService:RecalibratePasses`); dai em diante **ninguem mais
	pergunta a Roblox**, e as duas pontas leem a mesma chave `Gamepasses` do perfil
	pelas funcoes daqui de baixo.

	Nada aqui e sigiloso -- os numeros estao escritos na propria pagina da pass, e o
	cliente precisa deles para desenhar o preco com desconto e o teto do deck antes de
	perguntar nada. O que continua sigiloso e o que ja era: as odds das caixas moram
	em `ServerScriptService.Config.Crate`, e a sorte daqui multiplica **aquelas**
	tabelas do lado de la, e nao aqui.

	## Como o perfil guarda

	`Data.Gamepasses` e `{ [chave] = true }` -- a **chave** desta tabela, e nao o id
	numerico. O id e uma coisa da Roblox e muda quando uma pass e recriada; a chave e
	do jogo. Um id trocado e uma linha aqui, e nao uma migracao de perfil.

	Uma pass **nao** e guardada para sempre: o `RecalibratePasses` reescreve a tabela
	inteira a cada entrada, entao um reembolso tira o beneficio no proximo login. E
	por isso que nada aqui e credito -- as passes sao multiplicadores lidos na hora,
	nunca moeda depositada.

	## Como os numeros se combinam

	Cada beneficio e um **multiplicador**, e passes que mexem no mesmo numero se
	multiplicam entre si. Hoje ha uma por beneficio, entao a conta e sempre uma
	multiplicacao so -- mas uma segunda pass de coins amanha entra sem mexer em quem
	le, o que nao aconteceria com um `if` por pass espalhado pelos services.
]]

local RarityConfig = require(script.Parent.RarityConfig)

local module = {}

--[=[
	Uma pass por linha. `Id` e o `GamePassId` da Roblox; o resto e o que ela faz.

	| Campo | O que e |
	| --- | --- |
	| `Id` | o `GamePassId`, o que o `MarketplaceService` pergunta |
	| `DisplayName` | o que o jogador le |
	| `CardBonus` | quantas cartas a mais cabem no deck |
	| `CoinMultiplier` | multiplica os coins da recompensa de fim de partida |
	| `ShardMultiplier` | idem, para shards |
	| `XpMultiplier` | idem, para XP |
	| `CratePriceMultiplier` | multiplica o preco das caixas na loja (0.8 e 20% off) |
	| `LuckMultiplier` | multiplica o peso das raridades boas no sorteio da caixa |
	| `ChatTag` | o rotulo que aparece antes do nome no chat |

	A `Speed` nao tem campo nenhum de beneficio: o que ela libera e um degrau do
	`SpeedConfig`, e quem aponta para ela e o proprio degrau (`Gamepass = "Speed"`).
	Uma pass que so destranca conteudo e assim -- id e nome aqui, a regra onde o
	conteudo mora.

	Campo ausente e "esta pass nao mexe nisso" -- as funcoes abaixo tratam a falta
	como neutro (1 para multiplicador, 0 para bonus). Uma pass nova que so mexa em
	uma coisa e uma linha com um campo.
]=]
module.PASSES = {
	CardSlots = {
		Id = 1966789042,
		DisplayName = "+5 Total Cards",
		CardBonus = 5,
	},

	Luck = {
		Id = 1969136561,
		DisplayName = "+30% Luck",
		LuckMultiplier = 1.3,
	},

	Coins = {
		Id = 1969568499,
		DisplayName = "2x Coins",
		CoinMultiplier = 2,
	},

	Shards = {
		Id = 1970648287,
		DisplayName = "1.5x Shards",
		ShardMultiplier = 1.5,
	},

	Speed = {
		Id = 1970667486,
		DisplayName = "2x Speed",
	},

	VIP = {
		Id = 1953119816,
		DisplayName = "VIP",
		CratePriceMultiplier = 0.8,
		XpMultiplier = 1.25,
		ChatTag = "VIP",
	},
}

--[=[
	A raridade mais baixa que a sorte levanta.

	"Units melhores" e desta para cima: a `Luck` multiplica o peso de Epic, Legendary
	e Cosmic no pool da caixa, e deixa Common e Rare como estao. Como o sorteio
	normaliza pela soma dos pesos, levantar as de cima ja empurra as de baixo para
	baixo -- nao ha um segundo numero para manter em sincronia.
]=]
module.LUCK_MIN_RARITY = "Epic"

--[=[
	O atributo que o servidor escreve no `Player` para cada pass que tem `ChatTag`.

	O perfil so replica para o dono dele, entao ele nao serve para o chat: o rotulo do
	VIP tem de aparecer na mensagem **dos outros**, na tela de todo mundo. Atributo de
	`Player` replica para a sala inteira, e continua sendo o servidor quem escreve.
]=]
module.TAG_ATTRIBUTE_PREFIX = "Pass_"

--[=[
	O nome do atributo de uma pass. `VIP` vira `Pass_VIP`.
]=]
function module.attributeName(key : string) : string
	return module.TAG_ATTRIBUTE_PREFIX .. key
end

--[=[
	A pass de um id, ou nil. E como o `MonetizationService` volta do
	`PromptGamePassPurchaseFinished`, que so diz o numero.
]=]
function module.keyOfId(gamePassId : number?) : string?
	for key, pass in module.PASSES do
		if pass.Id == gamePassId then
			return key
		end
	end

	return nil
end

--[=[
	As passes que o perfil declara: `{ [chave] = true }`.

	Perfil que ainda nao carregou (ou que e de antes da chave) vale como "nenhuma", e
	nao como erro: sem pass o jogador joga o jogo base, que e o comportamento certo
	enquanto o dado nao chegou.
]=]
function module.ownedOf(profile : any) : { [string]: boolean }
	local owned = typeof(profile) == "table" and profile.Gamepasses

	return typeof(owned) == "table" and owned or {}
end

--[=[
	Se este perfil tem a pass.
]=]
function module.owns(profile : any, key : string) : boolean
	return module.ownedOf(profile)[key] == true
end

--[=[
	O produto de um campo multiplicador entre as passes que o perfil tem.

	E o motor de todos os multiplicadores abaixo: campo ausente vale 1, entao uma pass
	que nao mexe naquele numero nao entra na conta, e duas que mexem se multiplicam.
]=]
local function product(profile : any, field : string) : number
	local owned = module.ownedOf(profile)
	local total = 1

	for key, pass in module.PASSES do
		local factor = owned[key] == true and pass[field]

		if typeof(factor) == "number" and factor > 0 then
			total *= factor
		end
	end

	return total
end

--[=[
	A soma de um campo de bonus entre as passes que o perfil tem. Campo ausente vale
	zero -- bonus se somam, multiplicadores se multiplicam.
]=]
local function sum(profile : any, field : string) : number
	local owned = module.ownedOf(profile)
	local total = 0

	for key, pass in module.PASSES do
		local bonus = owned[key] == true and pass[field]

		if typeof(bonus) == "number" then
			total += bonus
		end
	end

	return total
end

--[=[
	Quantas cartas a mais este perfil pode equipar. Ver `DeckConfig.limitFor`.
]=]
function module.cardBonus(profile : any) : number
	return math.floor(sum(profile, "CardBonus"))
end

--- Multiplica os coins da recompensa de fim de partida.
function module.coinMultiplier(profile : any) : number
	return product(profile, "CoinMultiplier")
end

--- Multiplica os shards da recompensa de fim de partida.
function module.shardMultiplier(profile : any) : number
	return product(profile, "ShardMultiplier")
end

--- Multiplica o XP da recompensa de fim de partida.
function module.xpMultiplier(profile : any) : number
	return product(profile, "XpMultiplier")
end

--- Multiplica o preco das caixas na loja. 0.8 e "20% de desconto".
function module.cratePriceMultiplier(profile : any) : number
	return product(profile, "CratePriceMultiplier")
end

--[=[
	Multiplica o peso das raridades a partir de `LUCK_MIN_RARITY` no sorteio da caixa.
	Sem a pass, 1 -- e o sorteio sai exatamente como sairia sem este arquivo existir.
]=]
function module.luckMultiplier(profile : any) : number
	return product(profile, "LuckMultiplier")
end

--[=[
	Se a sorte levanta esta raridade.

	Raridade que o `RarityConfig` nao conhece nao e levantada: e mais seguro pagar o
	peso normal do que multiplicar um tier que ninguem sabe o que e.
]=]
function module.isLuckyRarity(rarity : string?) : boolean
	local order = RarityConfig.getOrder(rarity)
	local minimum = RarityConfig.getOrder(module.LUCK_MIN_RARITY)

	return order ~= nil and minimum ~= nil and order >= minimum
end

--[=[
	O rotulo de chat deste perfil, ou nil quando ele nao tem nenhuma pass com rotulo.

	Com mais de uma, ganha a **primeira em ordem alfabetica de chave** -- e so para a
	escolha ser estavel; hoje so o VIP tem rotulo.
]=]
function module.chatTagOf(owned : { [string]: boolean }?) : string?
	local passes = typeof(owned) == "table" and owned or {}

	local keys = {}
	for key in module.PASSES do
		table.insert(keys, key)
	end
	table.sort(keys)

	for _, key in keys do
		local pass = module.PASSES[key]

		if passes[key] == true and typeof(pass.ChatTag) == "string" then
			return pass.ChatTag
		end
	end

	return nil
end

return module
