--[[
	The tutorial offer: the first thing the game says to someone who never played.

	The server decides it is due (`TutorialService`, reading the profile's `Tutorial`
	key); `TutorialController` puts it on screen through the usual dialog box. Only
	what is read and tuned lives here.

	The lines use `RichTextController` markup; `%s` is the player's name, filled in
	(escaped) by the controller.

	See docs/common/tutorial.md and docs/game/tutorial-match.md.
]]

local TutorialConfig = {}

--[[
	The offer's font.

	It lives here, not in `RichTextConfig.Defaults`, because it is **this** screen's
	choice: the rest of the game's rich text keeps the module default.
]]
TutorialConfig.Font = "rbxasset://fonts/families/PressStart2P.json"

--[=[
	What the dialog box receives with the lines.

	`Size` is the line height in the box (see `RichTextConfig.Presets.Dialogue`),
	smaller than the default on purpose: Press Start 2P is almost monospaced and
	takes about twice the width per character, so at 24 the greeting would overflow.
]=]
TutorialConfig.Text = {
	Preset = "Dialogue",
	Font = TutorialConfig.Font,
	Size = 20,
}

--[=[
	The options for **any** tutorial dialog: `Text`'s font and size, plus whatever
	that moment's conversation asks for (hiding the UI or not, choice buttons,
	automatic mode).

	It exists because the font is the same in the three places the tutorial speaks
	(the Lobby offer in `TutorialController`, the match steps in
	`TutorialStepController`, and the return after winning in `TutorialShopController`),
	which live in different places. Without it, changing the tutorial font would mean
	three files and forgetting one.

		dialog:Play(lines, TutorialConfig.Speech({ Auto = true, Blur = false }))

	What the caller passes **wins** over `Text`.
]=]
function TutorialConfig.Speech(options : { [string] : any }?) : { [string] : any }
	local resolved = table.clone(TutorialConfig.Text)

	for key, value in (options or {}) do
		resolved[key] = value
	end

	return resolved
end

--[[
	How long to wait, after the server sends it, before speaking.

	The player just arrived in the Lobby: UI loading, the intro, and the camera are
	all happening. Speaking over that is the same as not speaking.
]]
TutorialConfig.PromptDelay = 3

--[=[
	The tutorial button lock, in both halves.

	The script points at one thing at a time, and **what it does not point at is not
	clickable**: a player learning where the Ready button is must not open the
	difficulty board, sell the tower the step just asked for, or skip the wave the
	step is waiting on. `ButtonGateController` does the locking; only the
	tutorial-specific parts live here.

	Each step says what it unlocks (see `Buttons` in `Match.Steps`, and each Lobby
	flow beat's target). This table applies **on top of every step**.

	> It is `ButtonGate`, not `Buttons`, because `TutorialConfig.Buttons` is already
	> something else: the offer's two choice buttons.

	  - `Always`: always clickable, in every step of both places. Today only the
	    dialog box: a choice button that ignores clicks is a conversation with no exit.
	  - `Ignore`: screens the lock never touches, by name. The highlight is ignored
	    without saying so. The other three:

	      `Cmdr`, because locking the console locks the tool that unlocks the rest;

	      `TouchGui` and `MovementButtons`, because **movement is not a script
	      button**. The player keeps control of the camera and their legs while
	      learning where to click; on phones, walking, running, dashing, and jumping
	      are screen buttons, and locking them would freeze the player in place.
	  - `Release`: the valve, in seconds of an **open** step. If a step's whitelist
	    misses the button it asks for, the screen would be dead with nobody to
	    re-enable it; after the deadline the lock drops and a warning says why.

	    Four minutes, deliberately generous. A valve that fires in a normal match is a
	    bug, and the floor is how long a first-time player takes, not a developer. The
	    tutorial preset's intermission alone is 45 s (the Ready step stays open for the
	    whole countdown), and 90 s ran out mid-Slingshot step, with the player still
	    reading and looking for the spot.

	    It only runs while the step is **open**: once done, the deadline stops
	    (`HoldRelease`) and the whitelist stays until the next step. A step that needs
	    another deadline sets `ButtonRelease`.
]=]
TutorialConfig.ButtonGate = {
	Always = { "SharedUIs.DialogGUI.Container" },
	Ignore = { "Cmdr", "TouchGui", "MovementButtons" },
	Release = 240,
}

--[=[
	The lines.

	1. White, the name in an orange gradient, half a second's pause, and the game's
	   name in shiny gold.
	2. The question, with "Tutorial" in an animated green gradient.

	The palettes (`orange`, `green`) and the gold (`gold`) live in `RichTextConfig`,
	so changing the greeting's colors does not go through here.
]=]
TutorialConfig.Lines = {
	"[color=white]Hello, [/color][gradient=orange]%s[/gradient][pause=0.5][color=white], welcome to [/color][gold]Periastron Tower Defense[/gold]",
	"[color=white]Would you like to play a [/color][gradient=green]Tutorial[/gradient][color=white]?[/color]",
}

--[=[
	The two choice buttons.

	`AcceptIndex` and `DeclineIndex` are indices of `DialogConfig.Buttons.Names`; in
	today's box, 1 is the right button and 2 the left. Accept on the right is what
	most games do; swapping means swapping the numbers here.

	They only appear when the second line finishes typing: a choice on screen before
	the question is read invites answering on autopilot.
]=]
TutorialConfig.Buttons = {
	AcceptIndex = 1,
	AcceptText = "SURE!",

	DeclineIndex = 2,
	DeclineText = "NO THANKS",
}

--[=[
	The tutorial match.

	`Difficulty` is the preset name in `ServerScriptService.Config.Difficulty`; it is
	**outside** `Order`, so it does not appear in the vote, and `TutorialMatchService`
	imposes it.

	`Deck` is what the player takes to the map, **only in this match**: one Slingshot
	and two Archers, three cards for the map's three `PlacementPoints`. The profile
	is untouched: a player who enters with a built deck finds it intact back in the
	Lobby.

	`Map` is the map name in `ServerStorage.Maps`, and what the Lobby sends in the
	TeleportData with the flag.
]=]
TutorialConfig.Match = {
	Map = "Tutorial",
	Difficulty = "Tutorial",

	--[[
		One entry per hotbar card, in the order they appear. A list, not a dictionary,
		because `{ Archer = 2 }` has no order and the hotbar does.
	]]
	Deck = {
		{ Unit = "Slingshot", Amount = 1 },
		{ Unit = "Archer", Amount = 2 },
	},

	--[=[
		The only cards the hand accepts during the tutorial.

		The whole script is about one tower: the player places the Slingshot on wave 1
		and learns weather, the shop, and speed with it on screen. The others stay
		locked (`Active = false` and dimmed) **until the last wave**, when the closing
		step (`UnlocksDeck`) releases the deck to cover the map before the boss.

		The lock holds between steps too, not only while one is open: the server
		refuses (`CanPlace`) and the client does not accept the click.
	]=]
	AllowedUnits = { "Slingshot" },

	--[=[
		The script, one step per wave.

		  - `Wave`   - which wave the step happens on. The server opens it **before**
		               the wave spawns. **Zero is the intermission** before wave 1:
		               where the Ready button step lives, the only script wave with no
		               spawns.
		  - `Kind`   - what the player must do: `"Ready"` (the intermission button),
		               `"Place"`, `"Buy"` (the RCS card), `"Use"`, `"Speed"`, and
		               `"PlaceRest"`, the wave 5 closer.
		  - `Hold`   - `true` holds the wave until the step is done, so wave 1 does not
		               spawn onto an empty map.
		  - `Unit`   - the only card the hand accepts while the step is open. The others
		               are dimmed on the client **and** refused on the server.
		  - `Point`  - the name of the part in `Map.PlacementPoints` where the unit must
		               go, and `Radius` is the tolerance in studs.

		               **The radius must be smaller than the distance between two
		               points**, 4.7 studs on today's map. With 10, placing on point 2
		               passed as point 1.
		  - `Lines`  - what the dialog box says when the step opens, with the usual
		               markup. A step with no lines goes straight to the highlight.
		  - `Buttons` - **the step's button whitelist**: what the player may click
		               while it is open. Anything not here (and not a parent or child of
		               something here, nor in `TutorialConfig.ButtonGate.Always`) stops
		               accepting clicks.

		               Each entry is a screen path from `PlayerGui` (the same as
		               `Highlight`) or an alias the controller resolves on the spot,
		               because the piece only exists at runtime:

		                 `@Highlight` whatever the highlight wraps right now
		                 `@Deck`      the whole hotbar (`Interface.TowerContainer`)
		                 `@Card`      the `Unit` card in the hotbar
		                 `@Hand`      the round `Card` already in hand
		                 `@Offer`     the `Card` on the shop table

		               **The whitelist outlives the step**: once done, it stays until
		               the next step opens. The lock belongs to the match, like the deck
		               lock (`AllowedUnits`) and `CanPlace`.

		               A step without `Buttons` locks nothing, so old scripts still work.
		  - `BlockedButtons` - a subtraction, for when the whitelist is a whole panel
		               and one button inside it must not be clickable. Wins over
		               `Buttons`.
		  - `ButtonRelease` - **this** step's valve deadline, in seconds, when
		               `TutorialConfig.ButtonGate.Release` does not fit.
		  - `GrantCash` - how much cash the step **gives** when it opens, to everyone. A
		               gift, not the `Ensure` safety net: it comes in whole, once per
		               step, whatever the player has, so the closing step finds enough
		               for the cards it asks for.
		  - `HideDeck` - `true` hides the whole `Interface.TowerContainer` while the step
		               is open and returns it when it closes. `DifficultyController`
		               writes `Visible` (`HoldHotbar`).

		Wave 1 asks for the **Slingshot**, the only card unlocked until wave 5 (see
		`AllowedUnits`): the tutorial teaches weather, the shop, and speed with one
		tower on screen, not a deck the player does not know how to build yet.
	]=]
	Steps = {
		--[[
			The very first step, and the only one outside a wave.

			The intermission before wave 1 exists for everyone (the countdown and the
			Ready button). The tutorial only points at it: the dialog explains the
			button, the highlight wraps it (`Interface.ReadyWave`, the `ImageButton`
			`ReadyController` builds), and the step closes **when the countdown ends**,
			on time or earlier because everyone is ready, which in a tutorial is the
			player's first click.

			No `Hold`: the intermission countdown itself holds here. No `BlockInput`
			either, like the other match steps: pointing at the button must not take the
			camera or the rest of the HUD away.
		]]
		{
			Id = "ClickReady",
			Wave = 0,
			Kind = "Ready",

			Highlight = "Interface.ReadyWave",

			--[[
				The Ready button and nothing else.

				`WeatherButton` stays out even though it is harmless: a second lit button
				in the same corner is exactly the doubt this step exists to avoid. Weather
				comes on wave 3, with a step of its own.
			]]
			Buttons = { "Interface.ReadyWave" },

			--[[
				The whole `Interface.TowerContainer` off screen while this step is open,
				and back when it closes (the countdown ended). There is nothing to place
				yet: cards only come in the next step, on wave 1.
			]]
			HideDeck = true,

			Lines = {
				"[color=white]Take your time to look around.[/color][pause=0.4] When you're set, hit [gradient=green]READY[/gradient][color=white] — the wave starts when the timer runs out.[/color]",
			},
		},

		{
			Id = "PlaceFirst",
			Wave = 1,
			Kind = "Place",
			Hold = true,

			Unit = "Slingshot",
			Point = "1",
			Radius = 3,

			--[[
				Only the card the step asks for.

				The hotbar already dims the others (`AllowedUnits`), but dimmed and
				disabled are not the same: `@Card` makes sure a click on a dimmed card
				goes nowhere, so the screen says the same thing the server would answer
				(`CanPlace`).
			]]
			Buttons = { "@Card" },

			Lines = {
				"[color=white]This is your deck.[/color][pause=0.4] Drag the [gradient=orange]Slingshot[/gradient] onto the marked spot.",
			},
		},

		--[[
			The round card offer.

			`OpenShop` opens the shop on this wave, and **this is the only tutorial wave
			it appears on**: the `RoundCardConfig.IsShopWave` calendar does not apply
			here (see `TutorialMatchService:ShopIsScripted`), so the offer does not come
			back on wave 4 over the speed step. `Card` is forced into the rotation and is
			the only card the step accepts; the other two stay on the table, visible, and
			refused until the right one is bought.

			`Ensure` is the safety net against a dead end: the step **holds the wave**
			until the purchase, and a player without the 300 for Weather Report would be
			stuck forever. If cash is short, the tutorial tops up the difference, once,
			and only up to the price.

			`ScheduleWeather` schedules one of three weathers for the next wave. Scheduling
			here, not there, is on purpose: the weather warning shows before the weather
			arrives, which is what this step teaches the player to read.
		]]
		{
			Id = "BuyReport",
			Wave = 2,
			Kind = "Buy",
			Hold = true,

			OpenShop = true,
			Card = "WeatherReport",
			Ensure = true,

			--[[
				The button that opens the offer, at the screen edge (`RoundCardConfig.Gui`:
				screen `RoundCardShop`, frame `RCSFrame`, button `CardShop`). The highlight
				starts on it; when the shop opens, it moves to the card the step requires;
				see `awaitCard`.
			]]
			Highlight = "RoundCardShop.RCSFrame.CardShop",

			ScheduleWeather = { "Drought", "Fog", "Rain" },

			--[=[
				The button that opens the shop **and** the card the step asks to buy.

				Both, not only what the highlight points at: the highlight slides from the
				button to the card when the shop opens (see `awaitCard`), and a whitelist
				that followed it would leave the close button dead mid-step.

				The other two cards on the table stay unclickable on purpose: they are
				inside `Background.RoundCardShop`, which is not unlocked. The server's
				`CanBuy` already refused them anyway, and it rules; this only stops the
				player from trying.
			]=]
			Buttons = { "RoundCardShop.RCSFrame.CardShop", "@Offer" },

			Lines = {
				"[color=white]Cards show up between waves.[/color][pause=0.4] Buy the [gradient=green]Weather Report[/gradient] — you'll need it.",
			},
		},

		--[[
			The weather arrived. The step asks to use the card bought on the previous wave.

			`Hold` **works** here because the weather enters before the gate:
			`WeatherRoundService` applies it on the `WaveStarted` signal `setWave` fires,
			and the tutorial gate only closes after that. So the player sees: the sky
			changes, the instruction appears, they use the card, and **only then** do
			the wave's enemies spawn.

			The card cannot be used early either: until this step opens, `CanUse` refuses
			it (server) and the hand does not accept it (client).
		]]
		{
			Id = "UseReport",
			Wave = 3,
			Kind = "Use",
			Hold = true,

			Card = "WeatherReport",

			-- The card bought, now in hand. The unit hotbar is empty (the Slingshot went to
			-- the map on wave 1), so there is nothing else to unlock.
			Buttons = { "@Hand" },

			Lines = {
				"[color=white]The weather is here — it buffs some enemies and weakens your towers.[/color]",
				"[color=white]Use your[/color] [gradient=green]Weather Report[/gradient] [color=white]to clear it for this wave.[/color]",
			},
		},

		--[=[
			The speed button.

			`Hold` holds wave 4 until the player speeds up the match. `Highlight` is the
			screen path, from `PlayerGui`, that the highlight wraps.

			**`Index` is the `SpeedConfig` step, and step 2 is 1.5x**, not 2x. The order
			there is `1 = 1x`, `2 = 1.5x`, `3 = 2x`, and the script stops at the second on
			purpose: **2x needs a game pass** (`Steps[3].Gamepass = "Speed"`), and a step
			that holds the wave behind a purchase is a dead end for players without it.
			1.5x is free, and the lesson ("you can speed up") is the same.

			Changing this number means changing the line too: it names the step the
			highlight points at.

			**The menu is not a panel.** The button clones itself once per step and hangs
			the clones next to it, under the same parent; they are not the button's
			children. That is why the whitelist asks for `@SpeedOptions` besides the
			button: without it the menu opens and no option accepts a click. When it
			opens, the highlight slides from the button to step `Index` (see
			`watchSpeedOptions`).
		]=]
		{
			Id = "UseSpeed",
			Wave = 4,
			Kind = "Speed",
			Hold = true,

			Index = 2,
			Highlight = "Interface.Speed",

			Buttons = { "Interface.Speed", "@SpeedOptions" },

			Lines = {
				"[color=white]In a hurry?[/color][pause=0.3] Tap [gradient=orange]1.5x[/gradient] to speed the match up.",
			},
		},

		--[[
			The closer: the rest of the deck on the ground, then the boss.

			`Kind = "PlaceRest"` is `Place`'s sibling for when the step wants **every
			remaining card** on **the remaining points**, not a specific card on a
			specific point. The step closes when the hand is empty.

			`Points` are the free points after wave 1. Any card on any of them works: the
			lesson is covering the map, not obeying a spot.

			The boss needs no request: `Wave.HasBoss` is `wave >= MaxWaves`, and the
			tutorial preset has `MaxWaves = 5`, so wave 5 spawns with it. It spawns weak
			through the same preset (`HealthMultiplier = 0.35`, `BossAmountMultiplier =
			1`).
		]]
		{
			Id = "PlaceRest",
			Wave = 5,
			Kind = "PlaceRest",
			Hold = true,

			-- This is where the rest of the deck unlocks, and only here.
			UnlocksDeck = true,

			--[[
				The cash for the cards this step asks for.

				Two Archers at 150 make exactly 300: the step pays what it charges, so the
				player does not reach the closer finding they cannot cover the free points.
				It adds, not caps: a player who saved all match keeps the extra, and extra
				on the last step of a match that ends next wave unbalances nothing.
			]]
			GrantCash = 300,

			Points = { "2", "3" },
			Radius = 3,

			--[[
				The whole hotbar, not one card: this step releases the deck (`UnlocksDeck`),
				and the lesson is covering the map with what you have. Which card counts on
				which point is still `CanPlace`'s math.
			]]
			Buttons = { "@Deck" },

			Lines = {
				"[color=white]Last wave — and it brings a[/color] [gradient=orange]boss[/gradient][color=white].[/color]",
				"[color=white]Put the rest of your deck on the open spots.[/color]",
			},
		},

		--[=[
			The last step: the result screen.

			No `Wave`, because it happens on no wave: `onRoundEnded` opens it through
			`BeginFinal`, at the same instant the result screen is sent. It is the only
			step that lives after the match.

			**No `Lines`**: the result screen is what the player must read now, and a
			dialog over it would cover the reward they just earned. The step is only the
			spotlight.

			`HighlightWait` is longer than the default because the button spawns hidden and
			enters at the end of a long choreography (backdrop, panel, rewards, XP bar;
			see `ResultController`), and the highlight refuses a target not yet on screen.
			Erring long costs an unseen wait; erring short costs the whole step.

			`ResultController` locks the "PLAY AGAIN" next to it: buttons belong to the
			screen's owner, and the tutorial is only asked whether this match is its own.
		]=]
		{
			Id = "BackToLobby",
			Kind = "Lobby",

			Highlight = "ResultScreen.MainScreen.Lobby",
			HighlightWait = 20,

			--[=[
				Only the back-to-lobby button.

				"PLAY AGAIN" next to it is already locked by `ResultController`, so it never
				enters this math: the lock does not touch a button that was already off.

				The deadline is the longest in the script, and not because of the long
				choreography: **this step has no next one**. Elsewhere, a valve that fires
				too early is corrected by the next step re-locking the screen; here nothing
				opens, and whatever the valve releases stays released until the teleport.
			]=]
			Buttons = { "ResultScreen.MainScreen.Lobby" },
			ButtonRelease = 600,
		},
	},
}

--[=[
	The second half of the tutorial: the part that happens **in the Lobby**, after
	winning.

	It is saved nowhere: the match server embeds `TutorialDone` in the teleport back,
	and the Lobby runs it in that session. It happens once, right after the match, and
	is gone if the player leaves.

	**It is a closed flow**: each beat points at the only clickable thing at that
	moment, enforced by `ButtonGateController`, so a learning player cannot get lost
	and no beat waits for a click the player already made elsewhere.

	Paths are by name from `PlayerGui`, and `HighlightController:Find` walks in depth,
	which is why `HUDFrame.Wrapper.Shop` finds the right wrapper among several
	same-named siblings.
]=]
TutorialConfig.Lobby = {
	Lines = {
		"[color=white]Nice work![/color][pause=0.4] Let's spend those coins — open the [gold]Shop[/gold].",
	},

	-- Beat 1: the shop button in the HUD.
	ShopButton = "HUD.HUDFrame.Wrapper.Shop",

	-- Beat 2: the crate to buy and the buy button **inside** its container.
	Item = "CrateOfBeginnings",
	BuyButton = "Buy",

	-- Beat 3: the backpack, and the crate list inside it. The crate pointed at is the
	-- first in the list, the one the player just bought.
	BackpackButton = "HUD.HUDFrame.Wrapper.Backpack",

	--[[
		The crates' **wrapper**, not the `scrollcrates` around it: `CrateController`
		fills it with one entry per rarity, cloned from `cratetemplate`, which stays
		inside, hidden, so the designer can keep editing it.

		Pointing at the scroll caught the hidden template instead of the player's
		crate: a highlight over something invisible looks like no highlight.
	]]
	CrateList = "crateui.Rectangle.scrollcrates.CrateWrapper",

	--[[
		The prefix of real entries (`Crate_Common`, `Crate_Rare`, ...) that
		`CrateController` uses when cloning the template. Preferring the prefix tells
		the player's crate from the template, even on the frame before the template is
		hidden (`CrateController` hides it at bind, and the flow may get there first).
	]]
	CratePrefix = "Crate_",

	-- The closing line, after the unboxing ends.
	ClosingLines = {
		"[color=white]That's a[/color] [gradient=green]new unit[/gradient][color=white] for your deck.[/color][pause=0.4] You're ready — good luck out there!",
	},

	--[[
		How often the flow checks whether the player did what the beat asked (the shop
		opened, the backpack opened). It waits on people clicking, not animation: a
		fifth of a second is imperceptible and costs nothing.
	]]
	PollInterval = 0.2,

	--[[
		How long to wait for a screen piece that does not exist yet (the buy button
		appears when the shop builds its list, the crate when the backpack opens). On
		timeout, the beat continues without a highlight instead of trapping the player.
	]]
	WaitForUi = 5,

	--[=[
		How many seconds of waiting **with nothing happening** before the flow releases
		the button lock.

		The safety net for "nothing outside the beat is clickable": if the beat does not
		recognize what the player did (the shop opened through an unexpected path, a
		screen was renamed), the lock would become a dead game with the right button
		off and nobody to turn it back on. After the deadline, buttons return (the
		highlight stays) and the player moves on.
	]=]
	StallRelease = 25,
}

--[=[
	The epic unit guarantee for new players.

	Within the profile's **first three** crates opened, one comes out Epic or better.
	It counts `Stats.BoxesOpened`, which already exists and counts real openings (the
	Cmdr `unbox` does not count), so no new profile key.

	The guarantee lands on the third: the first two roll normally, and only when the
	third arrives with no Epic yet is the draw forced. A lucky first crate does not
	"spend" the guarantee, and an unlucky player leaves the three with one.
]=]
TutorialConfig.CrateGuarantee = {
	Crates = 3,
	Rarity = "Epic",
}

return TutorialConfig
