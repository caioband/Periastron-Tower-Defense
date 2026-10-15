--[[
	The tutorial: a guided first playthrough.

	A first-time player lands on the Lobby portal plaza, picks a map through the
	normal portal flow (`MapPick`), and plays a real match on it (`Match`) with
	the script teaching one thing at a time. Winning settles the profile's
	`Tutorial` key; the crate walkthrough (`Lobby`) runs on the way back.

	Lines use `RichTextController` markup; `%s` is the player's name, filled in
	(escaped) by the controller.

	See docs/common/tutorial.md and docs/game/tutorial-match.md.
]]

local TutorialConfig = {}

TutorialConfig.Font = "rbxasset://fonts/families/PressStart2P.json"

TutorialConfig.Text = {
	Preset = "Dialogue",
	Font = TutorialConfig.Font,
	Size = 20,
}

--[=[
	The options for any tutorial dialog: `Text` plus what that moment asks for.
	What the caller passes wins.
]=]
function TutorialConfig.Speech(options : { [string] : any }?) : { [string] : any }
	local resolved = table.clone(TutorialConfig.Text)

	for key, value in (options or {}) do
		resolved[key] = value
	end

	return resolved
end

-- Seconds after the server asks before the first line is spoken: the Lobby is
-- still loading UI and the camera.
TutorialConfig.PromptDelay = 3

--[=[
	The button lock applied on top of every tutorial lock. See
	`ButtonGateController`.
]=]
TutorialConfig.ButtonGate = {
	Always = { "SharedUIs.DialogGUI.Container" },
	Ignore = { "Cmdr", "TouchGui", "MovementButtons" },
	Release = 240,
}

--[=[
	The old Yes/No offer. Only Cmdr's `tutorial` uses it now; accepting starts the
	map pick below instead of teleporting.
]=]
TutorialConfig.Lines = {
	"[color=white]Hello, [/color][gradient=orange]%s[/gradient][pause=0.5][color=white], welcome to [/color][gold]Periastron Tower Defense[/gold]",
	"[color=white]Would you like to play a [/color][gradient=green]Tutorial[/gradient][color=white]?[/color]",
}

TutorialConfig.Buttons = {
	AcceptIndex = 1,
	AcceptText = "SURE!",

	DeclineIndex = 2,
	DeclineText = "NO THANKS",
}

--[=[
	The Lobby half before the match: the player picks a map through the portals.

	  - `SpawnPart`: the marker the player is dropped on when they arrive, searched
	    in depth under `Workspace.Map` (the HUD play button uses the same one).
	  - `SuggestedMap`: the map the highlight lands on in the panel.
	  - `Gui`: screen paths from `PlayerGui`; `%s` in `MapEntry` is the map key.
	  - `Allow` / `Block`: the click whitelist while picking a map. Everything else
	    on screen is unclickable (movement, camera, and Cmdr stay free).
	  - `WaitingAllow`: the whitelist once the portal group is open and counting
	    down: only leaving the group.
	  - `LockRelease`: the lock's last-resort valve, in seconds.
	  - `DisablePrompts`: turns proximity prompts (NPC talk, AFK area, Next Event)
	    off on this client for the whole flow.
	  - `WalkInAllow`: `ProximityPanel` names that may still open by walking into
	    them during the flow. Empty keeps every shop, board and merchant shut;
	    portals are not walk-in panels and always work.
]=]
TutorialConfig.MapPick = {
	SpawnPart = "PortalsTpPart",
	SpawnHeightOffset = 3,
	SuggestedMap = "Farm",

	Lines = {
		"[color=white]Hello, [/color][gradient=orange]%s[/gradient][pause=0.5][color=white], welcome to [/color][gold]Periastron Tower Defense[/gold]!",
		"[color=white]Let's jump straight into a match.[/color][pause=0.4] Walk into a [gradient=green]portal[/gradient] [color=white]and pick a map —[/color] [gradient=green]Farm[/gradient] [color=white]is perfect for your first game.[/color]",
	},

	ChosenLines = {
		"[color=white]Nice pick![/color][pause=0.4] When the timer runs out, you'll head into the match.",
	},

	Gui = {
		MapEntry = "ChooseMaps.Lobby.Scroll.Map_%s",
		Confirm = "ChooseMaps.Lobby.Frame.Confirm",
	},

	Allow = {
		"ChooseMaps",
		"HUD.HUDMiddle.PlayButton",
	},

	Block = {
		"ChooseMaps.Lobby.IncreasePlrs",
		"ChooseMaps.Lobby.LowerPlrs",
	},

	WaitingAllow = {
		"ExitGroupPortal",
	},

	LockRelease = 600,
	DisablePrompts = true,

	WalkInAllow = {},

	PollInterval = 0.25,
}

--[=[
	The tutorial match.

	  - `Difficulty`: the preset the match imposes (the vote is skipped).
	  - `PresetOverrides`: fields replaced on a copy of that preset, for this match
	    only. `WeatherChance = 0` leaves weather to the script, and `MobDamage = 0`
	    means escaped enemies never hurt the base, so the tutorial cannot be lost.
	  - `Map`: only for Cmdr's fallback teleport; a real run uses the map the
	    player picked at the portal.
	  - `Deck` / `AllowedUnits`: `nil` means the player's own loadout, all of it.
	  - `KeepShopCalendar`: the round card shop is always driven by the tutorial
	    here, so a step can force it open with `OpenShop`. With this `true`, the
	    difficulty's normal shop waves still open on top of that.
	  - `FreeSpeed`: every speed step's game pass counts as owned in this match.
	  - `LockTowerActions`: `true` locks upgrading and selling for the whole match.
	  - `TowerActionsUntil`: the step Id that unlocks upgrading and selling. Until
	    that step opens, both are refused on the server and locked on screen.
	  - `WaitForRead`: step dialogs wait for the player to click through each line
	    instead of advancing on their own.
	  - `LockedUntil`: buttons that stay unclickable until a given step opens, so
	    the player cannot get ahead of the lesson that teaches them. `Button` is a
	    screen path; a frame locks every button inside it.
	  - `StudioAttribute`: in Studio, set this attribute to `true` on
	    `ServerStorage.Maps` to rehearse the script without a teleport.
]=]
TutorialConfig.Match = {
	Map = "Farm",
	Difficulty = "Easy",
	PresetOverrides = {
		WeatherChance = 0,
		MobDamage = 0,
	},

	Deck = nil,
	AllowedUnits = nil,

	KeepShopCalendar = true,
	FreeSpeed = true,
	LockTowerActions = false,
	TowerActionsUntil = "UpgradeTowers",
	WaitForRead = true,

	LockedUntil = {
		{ Button = "Interface.Speed", Step = "UseSpeed2x" },
		{ Button = "Interface.SkipPrompt", Step = "FinishUp" },
	},

	StudioAttribute = "StudioTutorial",

	--[=[
		The script. Each step opens before its wave spawns.

		  - `Wave`: the wave it opens on; `0` is the intermission before wave 1.
		  - `OnShop`: opens on the first wave the round card shop appears instead.
		  - `OpenShop`: forces the round card shop open on this step's wave.
		  - `Kind`: `Place`, `Speed`, `Buy`, `Use`, `Ready`, `Info`, or `Lobby`.
		  - `Hold`: holds its own wave until done. `HoldNext`: holds the **next**
		    wave until done (for intermission steps, whose countdown cannot wait).
		  - `Point`: a part name in `Map.PlacementPoints`, or `"@Spawn"` for the
		    start of the enemy path. `Radius` is the tolerance in studs.
		  - `Index`: the `SpeedConfig` step a `Speed` step waits for (3 = 2x).
		  - `Card`: the card a `Buy`/`Use` step asks for; `nil` on `Buy` = any card.
		  - `Ensure`: tops up match cash so the purchase is always affordable.
		  - `GrantCash`: a flat amount paid once when the step opens.
		  - `ScheduleWeather`: weathers to pick from (filtered by the map's pool),
		    arriving next wave with the usual warning.
		  - `ReadDelay`: for `Info` steps, extra seconds after the dialog closes
		    before the step counts as read (keeps a highlight up a little longer).
		  - `AutoComplete`: a fallback, in seconds, that closes an `Info` step if
		    the read never arrives.
		  - `Highlight`: a screen path the highlight wraps.
		  - `Buttons`: the step's click whitelist (aliases: `@Deck`, `@Card`,
		    `@Hand`, `@Offer`, `@Offers`, `@SpeedOptions`, `@Highlight`).
		  - `UnlockOnDone`: releases the button lock when the step completes.
	]=]
	Steps = {
		{
			Id = "PlaceNearSpawn",
			Wave = 0,
			Kind = "Place",
			HoldNext = true,

			Point = "@Spawn",
			Radius = 25,

			Buttons = { "@Deck" },
			UnlockOnDone = true,

			Lines = {
				"[color=white]Welcome to your first match![/color][pause=0.4] Enemies walk the path towards your base.",
				"[color=white]Drag a tower from your [/color][gradient=orange]loadout[/gradient][color=white] onto the map near where they come in — follow the arrow.[/color]",
			},
		},

		{
			Id = "BuyAnyCard",
			Wave = 2,
			Kind = "Buy",
			Hold = true,

			OpenShop = true,
			Ensure = true,
			Highlight = "RoundCardShop.RCSFrame.CardShop",

			Buttons = { "RoundCardShop.RCSFrame.CardShop", "@Offers" },
			UnlockOnDone = true,

			Lines = {
				"[color=white]Round cards just showed up![/color][pause=0.4] Open the [gradient=green]card shop[/gradient][color=white].[/color]",
				"[color=white]Cards are one-off boosts for this match — buff towers, slow enemies, earn cash.[/color][pause=0.3] Pick any one you like.",
			},
		},

		{
			Id = "UseSpeed2x",
			Wave = 3,
			Kind = "Speed",
			Hold = true,

			Index = 3,
			Highlight = "Interface.Speed",

			Buttons = { "Interface.Speed", "@SpeedOptions" },
			UnlockOnDone = true,

			Lines = {
				"[color=white]You're doing great![/color][pause=0.3] Want things to move faster?",
				"[color=white]Tap the speed button and pick [/color][gradient=orange]2x[/gradient][color=white] — it's free for this match.[/color]",
			},
		},

		{
			Id = "CardTip",
			Wave = 4,
			Kind = "Info",
			Hold = true,
			AutoComplete = 90,

			Lines = {
				"[color=white]The card shop shows up every few waves.[/color][pause=0.3] Cards you buy wait in your hand next to your towers — tap one whenever you want to use it.",
			},
		},

		{
			Id = "UpgradeTowers",
			Wave = 5,
			Kind = "Info",
			Hold = true,
			AutoComplete = 90,

			Lines = {
				"[color=white]Time to get stronger.[/color][pause=0.3] Click one of your towers to [gradient=green]upgrade[/gradient][color=white] it.[/color]",
				"[color=white]You can also[/color] [gradient=orange]sell[/gradient][color=white] a tower there to get some cash back.[/color]",
			},
		},

		{
			Id = "WeatherWarning",
			Wave = 6,
			Kind = "Info",
			Hold = true,
			AutoComplete = 90,

			ScheduleWeather = { "Rain", "Fog", "Wind", "Drought", "Sandstorm", "Snow" },

			Lines = {
				"[color=white]See that warning?[/color][pause=0.3] [gradient=orange]Weather[/gradient][color=white] is coming next wave.[/color]",
				"[color=white]Weather changes the fight — it usually weakens your towers, but some love it.[/color]",
			},
		},

		{
			Id = "WeatherArrived",
			Wave = 7,
			Kind = "Info",
			Hold = true,
			ReadDelay = 5,
			AutoComplete = 90,

			Highlight = "Interface.WeatherButton",

			Lines = {
				"[color=white]Here it is![/color][pause=0.3] Tap the weather icon any time to see exactly what it does.",
			},
		},

		{
			Id = "FinishUp",
			Wave = 9,
			Kind = "Info",
			Hold = true,
			AutoComplete = 90,

			Lines = {
				"[color=white]That's everything you need to know![/color][pause=0.4] Survive every wave to win the match — good luck!",
			},
		},

		{
			Id = "BackToLobby",
			Kind = "Lobby",

			Highlight = "ResultScreen.MainScreen.Lobby",
			HighlightWait = 20,

			Buttons = { "ResultScreen.MainScreen.Lobby" },
			ButtonRelease = 600,
		},
	},
}

--[=[
	The Lobby half after the match: open the shop, buy the crate, open it.
	It runs once, on the `TutorialDone` ticket the match server sends back.

	`WalkInAllow`: `ProximityPanel` names that may still open by walking into them
	during this flow. The shop stays allowed because the flow sends the player there.
]=]
TutorialConfig.Lobby = {
	Lines = {
		"[color=white]Nice work![/color][pause=0.4] Let's spend those coins — open the [gold]Shop[/gold].",
	},

	ShopButton = "HUD.HUDFrame.Wrapper.Shop",

	Item = "CrateOfBeginnings",
	BuyButton = "Buy",

	BackpackButton = "HUD.HUDFrame.Wrapper.Backpack",

	CrateList = "backpackui.Frame.Backpack.Content.CratesPage.CrateWrapper",
	CratePrefix = "Crate_",

	ClosingLines = {
		"[color=white]That's a[/color] [gradient=green]new unit[/gradient][color=white] for your deck.[/color][pause=0.4] You're ready — good luck out there!",
	},

	WalkInAllow = { "ShopController" },

	PollInterval = 0.2,
	WaitForUi = 5,
	StallRelease = 25,
}

--[=[
	Within the profile's first three crates, one comes out Epic or better.
]=]
TutorialConfig.CrateGuarantee = {
	Crates = 3,
	Rarity = "Epic",
}
 
return TutorialConfig