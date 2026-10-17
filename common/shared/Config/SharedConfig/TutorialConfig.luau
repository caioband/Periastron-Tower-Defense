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
	  - `PresetOverrides`: fields written over that preset on the tutorial server
	    (see `TutorialMatchService:GetForcedPreset`), so every service reads them.
	    `WeatherChance = 0` leaves weather to the script, `MobDamage = 0` means
	    escaped enemies never hurt the base, so the tutorial cannot be lost,
	    `MaxWaves = 10` ends the match after wave 10 of the preset's wave table
	    (the win reward is paid in full at that wave), `IntermissionTime = 0`
	    starts wave 1 as soon as the first step is done (that step holds it until
	    then), and `WaveOverrides` replaces whole waves of the table, in the same
	    format as `Config.Waves`.
	  - `Map`: only for Cmdr's fallback teleport; a real run uses the map the
	    player picked at the portal.
	  - `Deck`: the cards this match hands out instead of the player's loadout, in
	    hotbar order (`Unit` is the unit name, `Amount` how many placements). The
	    profile is not touched. `nil` means the player's own loadout.
	  - `AllowedUnits`: `nil` lets every card in the deck be placed.
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
		MaxWaves = 10,
		IntermissionTime = 0,

		WaveOverrides = {
			[1] = {
				{ Entity = "AstralInitiate", Amount = 3, Health = 3, Speed = 3.6, SpawnDelay = 0.7 },
			},

			[10] = {
				{ Entity = "AstralKnight", Amount = 8, Health = 5, Speed = 5.6 },
				{ Entity = "AstralGuardia", Amount = 9, Health = 11, Speed = 2.13 },
				{ Entity = "AstralNecromancer", Amount = 3, Health = 20, Speed = 3.73 },
				{ Entity = "AstralSentry", Amount = 3, Health = 9, Speed = 9.33 },
				{ Entity = "AstralSentinel", Amount = 1, Health = 180, Speed = 1.9 },
			},
		},
	},

	Deck = {
		{ Unit = "Sword", Amount = 1 },
		{ Unit = "Slasher", Amount = 1 },
		{ Unit = "Slingshot", Amount = 2 },
	},
	AllowedUnits = nil,

	KeepShopCalendar = true,
	FreeSpeed = true,
	LockTowerActions = false,
	TowerActionsUntil = "UpgradeTowers",
	WaitForRead = true,
	LockDialog = true,
	MinReadTime = 0.6,

	LockedUntil = {
		{ Button = "Interface.Speed", Step = "UseSpeed2x" },
		{ Button = "Interface.SkipPrompt", Step = "FinishUp" },
	},

	StudioAttribute = "StudioTutorial",

	--[=[
		The script. Each step opens before its wave spawns.

		  - `Wave`: the wave it opens on; `0` is the intermission before wave 1. Two
		    steps on the same wave run one after the other: the second opens as soon
		    as the first is done.
		  - `OnShop`: opens on the first wave the round card shop appears instead.
		  - `OpenShop`: forces the round card shop open on this step's wave.
		  - `OpenDelay`: real seconds after the step's wave starts before it shows up
		    (the wave keeps playing meanwhile).
		  - `Kind`: `Place`, `PlaceRest`, `Speed`, `Buy`, `Use`, `Ready`, `Info`,
		    `Weather`, `Upgrade`, or `Lobby`.
		  - `Hold`: holds its own wave until done. `HoldNext`: holds the **next**
		    wave until done (for steps that let their own wave play).
		  - `TimeScale`: the match clock while the step is on screen: `0` pauses it
		    (TDS-style), below `1` slows it down. Released when the step is done.
		  - `Unit`: for `Place`, the one tower the step accepts; its card is what
		    the highlight (and its pointing finger) lands on.
		  - `Point`: a part name in `Map.PlacementPoints`, `"@Spawn"` for the start of
		    the enemy path, or `"@NearSpawn"` for a free, valid spot beside the start
		    of the path, worked out on the server for the step's `Unit`. `Radius` is
		    the tolerance in studs.
		  - `SnapRadius`: for `Place`, how close (studs) the player has to aim to the
		    arrow for the tower to snap onto the spot under it. Further than that the
		    ghost shows red.
		  - `ArrowOnEquip`: the arrow over the spot only appears once the card has
		    been tapped; until then the hand points at the card.
		  - `Index`: the `SpeedConfig` step a `Speed` step waits for (3 = 2x).
		  - `Card`: the card a `Buy`/`Use` step asks for; `nil` on `Buy` = any card.
		  - `Ensure`: tops up match cash so the step can always be done (the card on
		    `Buy`, the rest of the hand on `PlaceRest`, the cheapest upgrade on
		    `Upgrade`).
		  - `GrantCash`: a flat amount paid once when the step opens.
		  - `ScheduleWeather`: weathers to pick from (filtered by the map's pool),
		    arriving next wave with the usual warning.
		  - `Panel`: for `Weather`, the screen path of the weather popup the hand
		    moves to once the weather button opens it.
		  - `ReadDelay`: for `Info` steps, extra seconds after the dialog closes
		    before the step counts as read (keeps a highlight up a little longer);
		    for `Weather`, how long the popup stays pointed at before it counts.
		  - `AutoComplete`: a fallback, in seconds, that closes an `Info` or
		    `Weather` step if the read never arrives.
		  - `Highlight`: a screen path the highlight (and its pointing finger)
		    wraps; on a `Place` step with a `Unit`, only used if that card is not
		    found.
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
			TimeScale = 0,

			Unit = "Slingshot",
			Point = "@NearSpawn",
			Radius = 12,
			SnapRadius = 10,
			ArrowOnEquip = true,

			Highlight = "Interface.TowerContainer",

			Buttons = { "@Deck" },
			UnlockOnDone = true,

			Lines = {
				"[color=white]Welcome to your first match![/color][pause=0.4] Enemies walk the path towards your base.",
				"[color=white]Tap the [/color][gradient=orange]Slingshot[/gradient][color=white] card, then place it under the arrow.[/color]",
			},
		},

		{
			Id = "UseSpeed2x",
			Wave = 1,
			Kind = "Speed",
			HoldNext = true,
			OpenDelay = 2.5,
			TimeScale = 0.3,

			Index = 3,
			Highlight = "Interface.Speed",

			Buttons = { "Interface.Speed", "@SpeedOptions" },
			UnlockOnDone = true,

			Lines = {
				"[color=white]Here they come![/color][pause=0.3] Want things to move faster?",
				"[color=white]Tap the speed button and pick [/color][gradient=orange]2x[/gradient][color=white] — it's free for this match.[/color]",
			},
		},

		{
			Id = "BuyAnyCard",
			Wave = 2,
			Kind = "Buy",
			Hold = true,
			TimeScale = 0,

			OpenShop = true,
			Ensure = true,
			Highlight = "RoundCardShop.RCSFrame.CardShop",

			Buttons = { "RoundCardShop.RCSFrame.CardShop", "@Offers" },
			UnlockOnDone = true,

			Lines = {
				"[color=white]Round cards just showed up![/color][pause=0.4] Tap the [gradient=green]card shop[/gradient][color=white] on the right.[/color]",
				"[color=white]Cards are one-off boosts for this match — buff towers, slow enemies, earn cash.[/color][pause=0.3] Pick one of the three.",
			},
		},

		{
			Id = "PlaceRest",
			Wave = 2,
			Kind = "PlaceRest",
			Hold = true,
			TimeScale = 0,

			Ensure = true,
			Highlight = "Interface.TowerContainer",

			Buttons = { "@Deck" },
			UnlockOnDone = true,

			Lines = {
				"[color=white]Nice pick![/color][pause=0.3] Now place the [gradient=orange]rest of your towers[/gradient][color=white] anywhere along the path.[/color]",
			},
		},

		{
			Id = "WeatherWarning",
			Wave = 3,
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
			Wave = 4,
			Kind = "Weather",
			Hold = true,
			TimeScale = 0,
			ReadDelay = 4,
			AutoComplete = 120,

			Highlight = "Interface.WeatherButton",
			Panel = "Interface.IndicatorWeather",

			Buttons = { "Interface.WeatherButton" },
			UnlockOnDone = true,

			Lines = {
				"[color=white]Here it is![/color][pause=0.3] Tap the [gradient=orange]weather icon[/gradient][color=white] on the left to see exactly what it does.[/color]",
			},
		},

		{
			Id = "CardTip",
			Wave = 5,
			Kind = "Info",
			Hold = true,
			AutoComplete = 90,

			Lines = {
				"[color=white]The card shop shows up every few waves.[/color][pause=0.3] Cards you buy wait in your hand next to your towers — tap one whenever you want to use it.",
			},
		},

		{
			Id = "UpgradeTowers",
			Wave = 6,
			Kind = "Upgrade",
			Hold = true,
			TimeScale = 0,

			Ensure = true,
			Highlight = "Interface.CardUpgrade.UpgradeCost",

			Buttons = { "Interface.CardUpgrade.UpgradeCost" },
			UnlockOnDone = true,

			Lines = {
				"[color=white]Time to get stronger.[/color][pause=0.3] Click one of your [gradient=green]towers[/gradient][color=white], then hit [/color][gradient=orange]upgrade[/gradient][color=white].[/color]",
			},
		},

		{
			Id = "FinishUp",
			Wave = 9,
			Kind = "Info",
			Hold = true,
			AutoComplete = 90,

			Lines = {
				"[color=white]That's everything you need to know![/color][pause=0.4] One more wave after this one.",
			},
		},

		{
			Id = "BossIncoming",
			Wave = 10,
			Kind = "Info",
			Hold = true,
			AutoComplete = 90,

			Lines = {
				"[color=white]A[/color] [gradient=orange]boss[/gradient] [color=white]is coming![/color][pause=0.4] Its health bar is at the top of the screen — take it down to win!",
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
	The Lobby half after the match: buy the crate, open it, equip what came out.
	It runs once, on the `TutorialDone` ticket the match server sends back.

	  - `ShopButton` / `Item` / `BuyButton`: the shop on the HUD and the crate it
	    sells. Once bought, the shop closes and stays shut for the rest of the flow.
	  - `BackpackButton`, `CrateList`, `CratePrefix`: the backpack and the crate
	    rows inside it.
	  - `OpenOneButton`: the "OPEN 1" button the backpack shows after a crate is
	    picked.
	  - `CrateHighlight`: the glow on the crate that appears in the world.
	  - `RevealHold`: seconds to let the unit reveal play before moving on.
	  - `LoadoutButton`, `InventoryList`, `EquipButton`: the loadout panel, the list
	    of owned units inside it (one row per unit, named after the unit), and the
	    button that equips the selected one.
	  - `LoadoutLines`: `%s` is the unit that came out of the crate.
	  - `WalkInAllow`: `ProximityPanel` names that may still open by walking into
	    them before the purchase. The shop is allowed because the flow sends the
	    player there; after the purchase nothing is.
]=]
TutorialConfig.Lobby = {
	Lines = {
		"[color=white]Nice work![/color][pause=0.4] Let's spend those coins — open the [gold]Shop[/gold].",
	},

	ShopButton = "HUD.HUDFrame.Wrapper.Shop",

	Item = "CrateOfBeginnings",
	BuyButton = "Buy",

	BackpackLines = {
		"[color=white]Your crate is in your[/color] [gradient=orange]Backpack[/gradient][color=white]. Let's open it![/color]",
	},

	BackpackButton = "HUD.HUDFrame.Wrapper.Backpack",

	CrateList = "backpackui.Frame.Backpack.Content.CratesPage.CrateWrapper",
	CratePrefix = "Crate_",

	OpenOneButton = "backpackui.Frame.Backpack.BulkOpen.OpenOne",

	CrateHighlight = {
		Fill = Color3.fromRGB(255, 205, 60),
		Outline = Color3.fromRGB(255, 255, 255),
		FillTransparency = 0.55,
	},

	RevealHold = 2.5,

	LoadoutLines = {
		"[color=white]You got a[/color] [gradient=green]%s[/gradient][color=white]![/color][pause=0.4] Open your [gradient=orange]Loadout[/gradient][color=white] and equip it.[/color]",
	},

	LoadoutButton = "HUD.HUDFrame.Wrapper.Deck",
	InventoryList = "HUD.CardUI.Inventory.ScrollingFrame",
	EquipButton = "HUD.CardUI.SelectionPanel.Container.EquipToggle",

	ClosingLines = {
		"[color=white]That's the end of the tutorial![/color][pause=0.4] You're ready — [gradient=green]have fun[/gradient][color=white] out there![/color]",
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