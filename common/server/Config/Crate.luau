
--[[
	Odds das crates — SÓ SERVIDOR.

	Mora aqui pelo mesmo motivo que `Summon`: é a chance de drop do jogo, o cliente
	não precisa (nem deve) ler. O que o cliente vê de raridade — nome, cor, ordem —
	está em `ReplicatedStorage.Shared.Config.SharedConfig.RarityConfig`.

	O pool devolve só a RARIDADE. Qual unit sai é sorteado depois, entre as units
	daquela raridade (`RarityConfig.getUnitsOfRarity`) — é de propósito: para incluir
	uma unit nova no drop basta dar uma `Rarity` para ela no UnitStats.
]]

local module = {}

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

return module
