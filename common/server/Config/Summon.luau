
local module = {}

module.BANNERS = {
	"Normal",

}

local Keys = {
	BASIC_DEFAULT_BANNER_KEY = module.BANNERS[1],

}

return {
	BANNERS = {
		[Keys.BASIC_DEFAULT_BANNER_KEY] = {
			DisplayName = "Normal Banner",

			-- Era 100. Com 1000 de caixa por partida no Médio isso dava dez
			-- invocações por partida, e o banner sozinho entregava ~60x mais
			-- lendárias que a loja de shards — a moeda cara comprava o pior
			-- negócio. A 200, são cinco.
			Cost = 200,
			Currency = "Cash",
		},
	},

	-- A raridade de cada unit não fica aqui: ela vem do `Rarity` do UnitStats, que é
	-- a fonte única (os pools das crates leem de lá também). Aqui só o peso no banner.
	ITEMS = {
		--[[
			O banner é a rota barata: ele entrega Common e Rare em volume. As duas
			lendárias caíram de 2% somados para 0,5%, porque quem quer lendária
			deve ir pelas crates — que são a rota de shards, a moeda que só cai
			para quem termina a partida.
		]]
		[Keys.BASIC_DEFAULT_BANNER_KEY] = {
			{ Name = "Slasher", Weight = 50, UnlockedAsRobux = false },
			{ Name = "Sword", Weight = 26, UnlockedAsRobux = false },
			{ Name = "Slingshot", Weight = 15, UnlockedAsRobux = false },
			{ Name = "Entrepreneur", Weight = 6, UnlockedAsRobux = false },
			{ Name = "Subspace Tripminer", Weight = 2.5, UnlockedAsRobux = false },
			{ Name = "Rocket", Weight = 0.4, UnlockedAsRobux = false },
			{ Name = "Azure", Weight = 0.1, UnlockedAsRobux = false },
		},
	},
}
