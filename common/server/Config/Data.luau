-- This module lives in ServerScriptService.Config, so the path to the shared
-- config must be absolute: `script.Parent` does not lead to
-- ReplicatedStorage.Shared.Config from here.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedConfig = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SharedConfig")
local ContractConfig = require(SharedConfig:WaitForChild("ContractConfig"))
local CrateConfig = require(SharedConfig:WaitForChild("CrateConfig"))
local DeckConfig = require(SharedConfig:WaitForChild("DeckConfig"))
local IndexConfig = require(SharedConfig:WaitForChild("IndexConfig"))
local RoundCardShopConfig = require(SharedConfig:WaitForChild("RoundCardShopConfig"))

return {
	--[[
		The ProfileStore name. **Changing this resets everyone**: old profiles stay
		in the DataStore under the old key, and nobody reads them anymore; every
		player starts with the `Template` below.

		Every place reads this same line (`DataService` is shared), so they can never
		point at different stores: that would be the same player with one profile in
		each place.
	]]
	PROFILE_KEY = "PROD_KEY_2",
	Template = {
		Stats = {
			Wins = 0,

			--[[
				Wins **per difficulty**, `{ [difficulty] = count }`: what unlocks the
				higher difficulties (see `SharedConfig.DifficultyUnlockConfig`).

				Separate from `Wins` above, which is still the total and is what maps and
				leaderstats read. A total does not work for the lock: someone with 20 wins
				on Easy has shown nothing about Hard.

				It starts **empty**, not with one key per preset: the difficulty list lives
				in the server config (`Config.Difficulty.Order`), and repeating it here
				would be the same list in two places, waiting to drift apart.
				`WaveService` writes it, creating the won difficulty's key on the spot;
				readers treat a missing key as zero. Older profiles get the table through
				DataService's reconcile, so no migration is needed, and they get it empty:
				wins from before this key have no recorded difficulty, and there is
				nowhere to get it from.
			]]
			DifficultyWins = {},

			Cash = 0,

			-- Premium currency. Older profiles get the key through DataService's
			-- reconcile, so no migration is needed.
			Shards = 0,
			XP = 0,

			--[[
				Counters that exist for the Lobby leaderboards (`Config.Leaderboard`).
				None of them changes the game: they only count.

				  - `BoxesOpened`:   crates actually opened (`CrateService:OpenCrate`);
				                     Cmdr's `unbox` only shows the animation and does not count.
				  - `MatchesPlayed`: matches where the player stayed at least
				                     `MIN_MATCH_SECONDS` (`MatchStatsService`, Game).
				  - `TimeInMatches`: seconds inside a running round (same).
				  - `TimePlayed`:    seconds with the profile open, in both places
				                     (`PlaytimeService`).

				Times are in whole **seconds**; `DD:HH:MM` is only for the screen.

				They start at zero for everyone, including existing players: the profile
				never stored any of this, so there is no past to recover. Older profiles
				get the keys through DataService's reconcile.

				**`CoinsEarned` (total coins earned, MOST COINS) is not here on
				purpose.** It has an approximate past: today's balance is the minimum the
				player has earned. If the template carried the key, reconcile would set
				it to zero and nobody could tell an older profile anymore. Without it,
				`CurrencyService` sees the key missing when the profile loads and creates
				it with the current `Cash`, which is zero on a new profile.
				`WaveService:grantReward` adds to it; shop refunds and Cmdr do not count.
			]]
			BoxesOpened = 0,
			MatchesPlayed = 0,
			TimeInMatches = 0,
			TimePlayed = 0,
		},

		Inventory = {
			-- { [Rarity] = amount } for every rarity in CrateConfig.RARITIES
			Crates = CrateConfig.createEmptyCrates(),
		},

		--[[
			The high-rarity unboxing guarantee: `{ [crate] = { [rarity] = openings in
			a row without it } }`. It starts empty and each crate gets its count on its
			first opening. See `ServerScriptService.Config.Crate.PITY_RARITIES`.
		]]
		Pity = {},

		PurchaseHistory = {},

		--[[
			The gamepasses the player owns, `{ [key] = true }`: the
			`SharedConfig.GamepassConfig` key, not Roblox's numeric id.

			**It is not a credit, it is a copy.** `MonetizationService` rewrites the
			whole table on every join from what Roblox answers: a refunded pass
			disappears from here at the next login, and no benefit gets stuck on the
			profile. It exists only so the rest of the game does not have to ask
			Roblox on every crate opened and every round end.

			Older profiles get the key through reconcile, so no migration is needed.
		]]
		Gamepasses = {},

		--[[
			What the player has already discovered, per category (`{ [key] = true }`).

			Structure and rules in `SharedConfig.IndexConfig`; `IndexService` writes
			it. A new category there reaches older profiles through reconcile, so no
			migration is needed.
		]]
		Index = IndexConfig.createEmpty(),
		--[[
			What a new player already owns. Only Common and Rare: starting with two
			Rockets and two Subspace Tripminers put the top of the table in their
			hands, with nothing to earn in the first hour.
		]]
		Units = {
			["Slasher"] = 3,
			["Sword"] = 2,
			["Slingshot"] = 1,
		},

		--[[
			The deck's cards, one name per card and with repeats: two equipped
			Slashers are two "Slasher" entries here. See `SharedConfig.DeckConfig`.
		]]
		EquippedUnits = {},

		--[[
			The round cards the player has unlocked, `{ [Id] = true }`: the `Id` from
			`SharedConfig.RoundCardConfig`.

			**It is not an inventory, it is their pool.** Unlocking puts no card in
			hand: it says that card can come up in the round offer draw, and each use in
			the match is still bought with match cash. `RoundCardShopService` (Lobby)
			writes it on a purchase in the card shop; `CardShopService`'s `_pool`
			(Game) reads it.

			It starts with the starter kit (`RoundCardShopConfig.STARTER_CARDS`), or the
			round offer would never open for newcomers. Older profiles get the key
			through DataService's reconcile, and get it **empty**, because reconcile
			copies the template only where it is missing; `RoundCardStarterService`,
			which runs on every profile open in both places, fills in what is missing.
		]]
		RoundCards = RoundCardShopConfig.createEmpty(),

		--[[
			The card shop's paid reroll: `{ Index, Rolls, Cards }`: the four-hour block,
			how many rerolls were bought in it, and **the drawn cards**.

			The cards are stored, not recomputed: the reroll draw only sweeps what the
			player has yet to unlock, and that list shrinks when they buy. A shelf
			derived from it would rebuild on every purchase, and the sold slot would
			fill with a new card instead of staying `SOLD`. See the
			`RoundCardShopConfig.createEmptyRoll` comment.

			It holds until the rotation rolls over. Nothing deletes the old record: it
			stops applying on its own when the block number changes.
		]]
		RoundCardRoll = RoundCardShopConfig.createEmptyRoll(),

		--[[
			The Lobby board's contracts, per period:
			`{ Hourly|Daily|Weekly = { Period, Slots = { { Id, Params, Progress, Claimed, Seen? } } } }`.

			`Period` is the number of the period in which the slots were drawn
			(`ContractConfig.periodOf`); when the current one differs,
			`ContractService` draws again. `Params` is what the contract's `Random`
			drew (map, difficulty, class), and `Seen` only exists on `Mode = "Distinct"`
			contracts (login days). Structure and rules in `SharedConfig.ContractConfig`.

			It starts with `Period = -1`, which is no period at all: the first load
			draws all three. Older profiles get the key through reconcile.
		]]
		Contracts = ContractConfig.createEmpty(),

		-- How many cards fit in the deck. It lives on the profile because it is meant to
		-- grow with the player; `DeckConfig.DEFAULT_CARD_LIMIT` is only the starting value,
		-- and DataService's reconcile gives the key to profiles older than it.
		CardLimit = DeckConfig.DEFAULT_CARD_LIMIT,

		--[[
			Is the "tutorial" matter settled for this player?

			`false` is the only thing that makes the offer appear in the Lobby, and it
			goes away along **two** paths: winning the 5 waves of the Tutorial map, or
			**declining** the offer. Declining is an answer, not a postponement:
			someone who said "no" is not asked again on every join.

			As a consequence, **abandoning the match midway leaves the key at
			`false`**: a player who accepted and left before the end is asked again and
			restarts from wave 1. That is deliberate: a half-played match state (units
			on the map, card bought, weather active) exists nowhere, and returning to
			wave 3 with an empty map would be worse than restarting.

			Older profiles get the key through DataService's reconcile, and get
			`false`, because there is no way to know who went through a tutorial that
			did not exist. Long-time players get the offer once, and the first answer
			settles it.
		]]
		Tutorial = false,

		--[[
			The Lobby's "your friend is online" suggestion (`FriendInviteService`),
			keyed by the friend's `UserId` **as a string** (a DataStore cannot save
			sparse numeric keys):

			  - `Invited`: `{ [UserId] = times }`, how many times the player clicked
			    `Invite` for that friend on the notification.
			  - `Accepted`: `{ [UserId] = { System, Manual, Total } }`, how many
			    invites from this player that friend accepted (joined the Lobby
			    through): `System` from our notification, `Manual` any other invite
			    (Roblox menu, share link), `Total` both. Written by the server the
			    friend joins, through `ProfileEditService`, even with this player
			    elsewhere or offline.
			  - `Shown`: `{ [UserId] = os.time() }`, when the friend was last
			    suggested; they stay out of the draw for an hour. Expired entries are
			    removed on the next write.

			The draw prefers the most accepted, then the most `Invited`.
			Older profiles get the keys through DataService's reconcile.
		]]
		FriendInvites = {
			Invited = {},
			Accepted = {},
			Shown = {},
		},
	},

	STARTING_CASH = 500,

	--[[
		XP for a full run, scaled by the fraction of waves survived and the
		difficulty's `WinXpMultiplier`.

		**Coins and shards do not go through here.** Each preset carries the full
		number in `Difficulty.Presets[...].WinCash` and `.WinShards`, so what
		Nightmare pays reads directly, and changing how much a difficulty pays means
		changing that number.
	]]
	BASE_WINNING_XP = 200,

	-- Shards only start dropping after this fraction of the run, and then grow along a
	-- curve instead of linearly: it is the expensive currency, so almost all the gain
	-- comes from getting close to the end. With 0.5 and curve 2, leaving at halfway
	-- yields zero and reaching 80% of the run yields ~36% of the total.
	SHARD_WAVE_THRESHOLD = 0.5,
	SHARD_CURVE = 2,

	--[[
		How much of the coins a **defeat** pays: a fifth of what the same waves would
		pay in a victory.

		Losing yields no shards at all, however far the player got: that is not a
		number, it is a rule, and it lives in `computeReward`. Coins stay because the
		lost match was still time played; it just must not compete with finishing the
		run.
	]]
	LOSS_CASH_MULTIPLIER = 0.2,

	-- Fallback: the real wave count comes from the difficulty's `MaxWaves`
	-- (Config/Difficulty.luau). This only applies if a preset does not set the
	-- field; the boss always lands on the last wave, whatever the count.
	MAX_WAVES = 18,
	--[[
		Cash per point of damage, and only for damage that actually landed (see
		`MobService:DamageMob`). Paying the hit's full value paid for overkill: a
		70-damage shot on an enemy with 5 health yielded 70. That made damage two
		thirds of the match economy and grow with enemy health, so the harder the
		preset, the richer the player got. The rest of that income moved to kill
		rewards, in `Config.Wave`.

		The rate is 0.15 rather than 0.3 because the wave spreadsheet has far more
		enemies per wave, so 0.3 per point would double damage income.
	]]
	CASH_PER_DAMAGE = 0.15,

	-- Only apply when the enemy carries no `Reward`; the waves always do.
	CASH_PER_KILL_MIN = 6,
	CASH_PER_KILL_MAX = 12,
	MAX_DATA_TIME_OUT = 20,

	--[[
		What `DataService` does differently in each place. The place is the `Place`
		attribute that each place's Rojo project sets on `ServerScriptService.Services`.

		  - `ReadyTag`: the tag `DataService` puts on the player when their client fires
		    `Loaded`. The Game's services wait on `ClientReady`; the Lobby's `Get` waits
		    on `Loaded`.
		  - `WaitForClient`: `DataService:Get` only hands out the profile after the
		    player has `ReadyTag` (up to `MAX_DATA_TIME_OUT` seconds). With `false`, it
		    answers as soon as the profile is open.

		Who fires `Loaded`: each place's `ClientBoot` in the Lobby and the AFK place,
		`WaveController` in the Game.
	]]
	Places = {
		Lobby = { ReadyTag = "Loaded", WaitForClient = true },
		Game = { ReadyTag = "ClientReady", WaitForClient = false },
		Afk = { ReadyTag = "Loaded", WaitForClient = true },
	},

	--[[
		How long inside a round before it counts toward `Stats.MatchesPlayed`: the
		leaderboard's "(3min+)". Without the floor, joining and leaving a match would
		be the fastest way to climb it.

		It is the **player's** time in the round, not the round's duration: someone
		who joins midway counts from when they joined. It applies to victory, defeat,
		and leaving midway. `TimeInMatches` adds all the time, even from short
		matches.
	]]
	MIN_MATCH_SECONDS = 180,
}
