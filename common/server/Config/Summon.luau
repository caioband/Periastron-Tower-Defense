
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

			-- Not 100: with Medium's 1000 cash per match, that meant ten
			-- summons per match, and the banner alone delivered ~60x more
			-- Legendaries than the shards shop, so the expensive currency bought
			-- the worse deal. At 200, it is five.
			Cost = 200,
			Currency = "Cash",
		},
	},

	-- Each unit's rarity does not live here: it comes from `UnitStats`' `Rarity`, the
	-- single source (crate pools read it too). Here there is only the banner weight.
	ITEMS = {
		--[[
			The banner is the cheap route: it delivers Common and Rare in volume. The
			two Legendaries dropped from 2% combined to 0.5%, because players who want
			a Legendary should go through crates, the shards route, a currency that
			only drops for players who finish the match.
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
