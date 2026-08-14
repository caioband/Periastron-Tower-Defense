
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
			Cost = 100,
			Currency = "Cash",
		},
	},

	-- A raridade de cada unit não fica aqui: ela vem do `Rarity` do UnitStats, que é
	-- a fonte única (os pools das crates leem de lá também). Aqui só o peso no banner.
	ITEMS = {
		[Keys.BASIC_DEFAULT_BANNER_KEY] = {
			{ Name = "Slasher", Weight = 50, UnlockedAsRobux = false },
			{ Name = "Sword", Weight = 25, UnlockedAsRobux = false },
			{ Name = "Slingshot", Weight = 14, UnlockedAsRobux = false },
			{ Name = "Entrepreneur", Weight = 6, UnlockedAsRobux = false },
			{ Name = "Subspace Tripminer", Weight = 3, UnlockedAsRobux = false },
			{ Name = "Rocket", Weight = 1.5, UnlockedAsRobux = false },
			{ Name = "Azure", Weight = 0.5, UnlockedAsRobux = false },
		},
	},
}
