--[[
	Redeemable codes: SERVER ONLY.

	It lives here, not in `SharedConfig`, because the list is the secret: a client
	that could read it would see every code, including the ones not announced yet.

	Each entry is keyed by the code in UPPERCASE. What the player types is trimmed and
	uppercased before the lookup, so `release` and ` RELEASE ` both match `RELEASE`.

	  - `ExpiresAt`: required. Unix time (UTC) after which the code stops working.
	  - `StartsAt`: optional. Unix time (UTC) before which the code answers as if it
	    did not exist, so a code can be scheduled ahead of an announcement.
	  - `Rewards`: `{ Cash, Shards, Crates = { [rarity] = amount } }`, paid by
	    `RewardService`. Crate keys are the `CrateConfig.CRATES` rarities
	    (`Common`, `Rare`, `Epic`, `Legendary`).

	Write timestamps with `utc(year, month, day, hour?, minute?)`, which reads as a
	date and cannot be mistaken for local time.

	Each player redeems a code once (`Profile.RedeemedCodes`). There is no global
	use limit. Removing a code from this list only stops new redemptions.

	See docs/common/codes.md.
]]

local function utc(year : number, month : number, day : number, hour : number?, minute : number?) : number
	return DateTime.fromUniversalTime(year, month, day, hour or 0, minute or 0, 0).UnixTimestamp
end

return {
	--[[
		The Roblox group the player must be in to redeem anything: the group that
		owns the experience, in QA and in Production. A player outside it gets the
		join prompt instead (`GroupService:PromptJoinAsync`).
	]]
	GROUP_ID = 660345753,

	-- Seconds between two attempts by the same player, valid or not. It stops
	-- guessing codes by brute force.
	ATTEMPT_COOLDOWN = 2,

	-- Longer input is rejected before the lookup.
	MAX_LENGTH = 32,

	Codes = {
		RELEASE = {
			-- Through October 5, 2026, Brasília time (UTC-3).
			ExpiresAt = utc(2026, 10, 6, 3),
			Rewards = { Cash = 500, Shards = 3 },
		},
	},
}
