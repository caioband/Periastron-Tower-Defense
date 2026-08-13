
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

	ITEMS = {
		[Keys.BASIC_DEFAULT_BANNER_KEY] = {
			{ Name = "Slasher", Rarity = "Common", Weight = 50, UnlockedAsRobux = false },
			{ Name = "Sword", Rarity = "Uncommon", Weight = 25, UnlockedAsRobux = false },
			{ Name = "Slingshot", Rarity = "Rare", Weight = 14, UnlockedAsRobux = false },
			{ Name = "Entrepreneur", Rarity = "Epic", Weight = 6, UnlockedAsRobux = false },
			{ Name = "Subspace Tripminer", Rarity = "Epic", Weight = 3, UnlockedAsRobux = false },
			{ Name = "Rocket", Rarity = "Legendary", Weight = 1.5, UnlockedAsRobux = false },
			{ Name = "Azure", Rarity = "Legendary", Weight = 0.5, UnlockedAsRobux = false },
		},
	},
}
