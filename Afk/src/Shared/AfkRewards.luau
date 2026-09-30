--[[
	What the AFK area pays for time spent in it. `AfkAreaService` walks this list
	and pays each entry every time the player has been in the area for another
	`Interval` seconds.

	It lives in `ReplicatedStorage.Afk` so the client can read it, for the
	countdown. Nothing in it is secret, and the payout itself is only ever written
	on the server. It stays out of `ReplicatedStorage.Shared` on purpose: that
	folder is a Roblox Package shared with the Lobby and the Game, and this config
	belongs to the AFK place only.

	Each entry:
	  - `Id`:       unique name. The service keeps one paid-count per entry.
	  - `Interval`: seconds in the area between payouts.
	  - `Currency`: the `Data.Stats` key to pay into. It has to be one of
	                `CurrencyService.Stats` ("Cash" is the coins, "Shards").
	  - `Amount`:   what each payout gives.

	To add a reward, add another entry. Nothing else needs to change.
]]

local AfkRewards = {}

--[[
	Player attribute `AfkAreaService` sets to the moment the player's timer started,
	as `workspace:GetServerTimeNow()`. The client reads it to show how long is left
	until the next payout (`AfkAreaController`). It is removed when the player
	stops being tracked.
]]
AfkRewards.EnteredAttribute = "AfkAreaEnteredAt"

AfkRewards.Rewards = {
	{
		Id = "AfkCoins",
		Interval = 300,
		Currency = "Cash",
		Amount = 125,
	},
}

return AfkRewards
