
--[[
	Odds das crates — SÓ SERVIDOR.

	Mora aqui pelo mesmo motivo que `Summon`: é a chance de drop do jogo, o cliente
	não precisa (nem deve) ler. O que o cliente vê de raridade — nome, cor, ordem —
	está em `ReplicatedStorage.Shared.Config.SharedConfig.RarityConfig`.

	O pool devolve só a RARIDADE. Qual unit sai é sorteado depois, entre as units
	daquela raridade (`RarityConfig.getUnitsOfRarity`) — é de propósito: para incluir
	uma unit nova no drop basta dar uma `Rarity` para ela no UnitStats. Para deixar
	uma de fora sem apagá-la do jogo, veja `EXCLUDED_UNITS` logo abaixo.
]]

local module = {}

--[[
	Units que existem no jogo mas **não saem de caixa nenhuma**.

	Não é o mesmo que apagar a unit: quem já tem continua com ela, ela continua no
	deck, no banner de invocação (`Summon`), nos stats e no balanceamento. O que ela
	perde é só esta porta de entrada.

	Mora aqui, e não em UnitStats, porque é uma regra de **drop** e não uma propriedade
	da unit — a `Rarity` dela continua sendo Legendary, e é isso que a carta, a cor e o
	preço leem. Uma unit exclusiva de evento ou de promoção entra nesta lista no dia em
	que a promoção acabar, e sai dela sem tocar em mais nada.

	As odds publicadas na loja não mudam: elas são **por raridade**, e tirar a Azure não
	tira a chance de lendária — só faz o sorteio cair sempre nas outras duas (Berserker
	e Rocket). A conta de `GetDisplayOdds` continua valendo palavra por palavra.

	⚠️ Esvaziar uma raridade inteira aqui faz o sorteio **descer um degrau** e entregar
	uma unit mais fraca no lugar, com um aviso no output — o mesmo caminho da Cosmic,
	que não tem unit nenhuma. Deixe sempre uma unit sobrando por raridade que o pool
	alcança.
]]
module.EXCLUDED_UNITS = {
	["Azure"] = true,
}

--[[
	Chance (em %) de cada raridade de unit, por crate aberta. Cada linha soma 100.

	A crate comum não alcança Cosmic: o único caminho dela para lá é evoluir antes
	(veja UPGRADES abaixo).

	⚠️ Cosmic está com peso ZERO em todas as linhas porque nenhuma unit tem essa
	raridade no UnitStats. Quando o sorteio caía lá, o servidor descia um degrau e
	só registrava um aviso — ou seja, o prêmio máximo do jogo entregava uma
	lendária repetida, e era 10% da crate lendária (a de 1800 shards). O peso que
	era do Cosmic foi para Legendary. No dia em que existir uma unit Cosmic, basta
	devolver os pesos: 0,5 na rara, 1 na épica e 10 na lendária.
]]
module.POOLS = {
	["Common"] = {
		Common = 80,
		Rare = 15,
		Epic = 4.75,
		Legendary = 0.25,
		Cosmic = 0,
	},

	["Rare"] = {
		Common = 45,
		Rare = 40,
		Epic = 12,
		Legendary = 3,
		Cosmic = 0,
	},

	["Epic"] = {
		Common = 0,
		Rare = 45,
		Epic = 45,
		Legendary = 10,
		Cosmic = 0,
	},

	["Legendary"] = {
		Common = 0,
		Rare = 20,
		Epic = 40,
		Legendary = 40,
		Cosmic = 0,
	},
}

--[[
	Antes de sortear no pool, a crate pode evoluir para a próxima — e aí quem manda
	é o pool da crate evoluída. Chance em %.
]]
module.UPGRADES = {
	["Common"] = { To = "Rare", Chance = 25 },
	["Rare"] = { To = "Epic", Chance = 15 },
	["Epic"] = { To = "Legendary", Chance = 8 },
}

--[[
	Com `true`, a crate que evoluiu rola a evolução dela também: uma Common pode
	encadear até Legendary (25% * 15% * 8% = 0,3%). Com `false`, evolui no máximo um
	degrau — a Common nunca passa de Rare.
]]
module.CHAIN_UPGRADES = true

--[=[
	A chance de cada raridade de unit sair de uma caixa daquele tier, **ja com a
	evolucao dentro** -- e o numero que a loja mostra.

	As `POOLS` la em cima sao a chance depois de a caixa parar de evoluir, e nao a
	chance de comprar aquela caixa e receber aquela raridade. Uma Crate Of Beginnings
	evolui para Crate Of Nature em 25% das aberturas (e dali pode continuar), entao o
	pool da comum vale so em 75% delas. A diferenca nao e detalhe: a lendaria sai a
	0,25% pelo pool e a **1,29%** de verdade, cinco vezes mais.

	Mostrar o pool cru seria a loja prometer um numero que o jogo nao entrega, e por
	isso a conta e feita aqui e nao na tela: **a chance publicada e a chance real**.

	Como a conta anda: cada degrau da corrente leva `1 - chance` da probabilidade que
	sobrou para o tier atual e passa o resto adiante, ate um tier sem evolucao. Com
	`CHAIN_UPGRADES` desligado a corrente para no primeiro degrau, e a funcao segue
	valendo -- ela le a mesma bandeira que o sorteio le.

	Devolve um mapa `{ [raridade] = porcentagem }` somando 100, ou nil para um tier
	que nao existe. Raridade com chance zero (a Cosmic, hoje) sai de fora: linha de
	"0%" na loja e ruido.
]=]
function module.GetDisplayOdds(crateRarity : string) : { [string]: number }?
	local pool = module.POOLS[crateRarity]
	if not pool then
		return nil
	end

	-- Quanto de cada tier a caixa comprada vira, depois de a evolucao rolar.
	local tiers = {}
	local current = crateRarity
	local remaining = 1

	while true do
		local upgrade = module.UPGRADES[current]
		if not upgrade or not module.POOLS[upgrade.To] then
			tiers[current] = (tiers[current] or 0) + remaining
			break
		end

		local chance = math.clamp((upgrade.Chance or 0) / 100, 0, 1)
		tiers[current] = (tiers[current] or 0) + remaining * (1 - chance)
		remaining *= chance
		current = upgrade.To

		if not module.CHAIN_UPGRADES then
			tiers[current] = (tiers[current] or 0) + remaining
			break
		end
	end

	local odds = {}
	for tier, share in tiers do
		for rarity, chance in module.POOLS[tier] do
			odds[rarity] = (odds[rarity] or 0) + share * chance
		end
	end

	for rarity, chance in odds do
		if chance <= 0 then
			odds[rarity] = nil
		end
	end

	return odds
end

return module
