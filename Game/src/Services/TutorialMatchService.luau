local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("TutorialMatchService")

local Config = SharedConfig.TutorialConfig
local RoundCardConfig = SharedConfig.RoundCardConfig
local DifficultyConfig = ServerConfig.Difficulty
local AnalyticsConfig = ServerConfig.Analytics

-- The same attribute `MapService` reads to choose the map in Studio. It is the
-- tutorial's second door: see `resolve`.
local STUDIO_MAP_ATTRIBUTE = "StudioMap"

--[[
	The intermission's "wave": the Ready button step, which happens **before** the first
	wave spawns.

	The script is indexed by wave, and the intermission has no number, so it takes
	zero, which is what the match has in `WaveCount` while the countdown runs. See
	`BeginIntermission`.
]]
local INTERMISSION_WAVE = 0

--[[
	The tutorial match: what says **this** match is the tutorial, and what it imposes
	for being one.

	**Two doors, and only two.**

	  1. `TeleportData.Tutorial == true`, which is what the Lobby attaches when the
	     player accepts the offer. It is the real door, the one that holds on a
	     published server.
	  2. The `StudioMap = "Tutorial"` attribute on the `ServerStorage.Maps` folder,
	     which is the Studio door: Studio has no TeleportData, and without this there
	     would be no way to rehearse the script.

	Loading the `Tutorial` map **without** either one runs a regular match on it: that
	is how the map is tested (path, nodes, `PlacementPoints`) without the script on
	top. The flag and the map say different things on purpose.

	**What it imposes:**

	  - the difficulty is the `Tutorial` preset and the **vote is skipped**: the match is
	    designed for the player to win, and choosing `Nightmare` in the tutorial would
	    be choosing to lose;
	  - the match deck is `TutorialConfig.Match.Deck` (one Slingshot and two Archers),
	    **without touching the profile**;
	  - the step-by-step script of the 5 waves (`TutorialConfig.Match.Steps`), with the
	    locks each step applies.

	> The answer is decided **once**, on the first question, and cached: a server is a
	> tutorial server or not for its whole life. Asking again every wave would open the
	> door to the match changing nature midway.

	See docs/game/tutorial-match.md.
]]

local TutorialMatchService = {
	Services = {
		UnitService = {},
		SpeedService = {},
		WeatherRoundService = {},
		MobService = {},
		AnalyticsService = {},
	}
}

-- The step open now, and whether it was completed. One step at a time: the script
-- is a queue, not a set.
TutorialMatchService.Step = nil :: any
TutorialMatchService.Done = false

-- Has the deck been unlocked? Becomes `true` on the step that declares `UnlocksDeck`
-- (wave 5), and it is what makes the card lock hold from the start of the match until then.
TutorialMatchService.DeckUnlocked = false

-- Steps already completed, by `Id`. It is what lets a card stay locked until its
-- step opens and unlocked afterward. See `CanUse`.
TutorialMatchService.Completed = {}

-- Steps that already paid their `GrantCash`, by `Id`. Opening the same step twice
-- is possible (the `BeginStep` of a wave that returns after a `StopRound`), and a
-- gift given twice is money from nothing. See `grantCash`.
TutorialMatchService.Granted = {}

-- `nil` while nobody has asked; `true`/`false` after the first answer.
TutorialMatchService.Tutorial = nil :: boolean?

--[[
	Was the match won?

	It only exists for telemetry: the teleport back and a player giving up both leave
	through `PlayerRemoving`, and this boolean tells them apart. See `NoteWon`.
]]
TutorialMatchService.Won = false

-- The wave of the last step opened. It is the number the abandon event carries, and
-- it comes from here instead of `WaveService` to avoid one more dependency.
TutorialMatchService.LastWave = nil :: number?

--[[ INTERNAL ]]

--[=[
	The flag the Lobby attached to this player's teleport.
]=]
function TutorialMatchService:teleportedFlag(player : Player) : boolean
	local success, joinData = pcall(function()
		return player:GetJoinData()
	end)

	if not success or typeof(joinData) ~= "table" then
		return false
	end

	local teleportData = joinData.TeleportData
	if typeof(teleportData) ~= "table" then
		return false
	end

	return teleportData.Tutorial == true
end

--[=[
	The Studio attribute, the second door.
]=]
function TutorialMatchService:studioFlag() : boolean
	local maps = ServerStorage:FindFirstChild("Maps")
	if not maps then
		return false
	end

	return maps:GetAttribute(STUDIO_MAP_ATTRIBUTE) == Config.Match.Map
end

--[=[
	Decides, once, whether this server is a tutorial server.

	On a published server the answer comes from TeleportData, which is why it waits for
	the first player: JoinData comes from them, and they only arrive after boot. It is
	the same wait `MapService` does to discover the map, for the same reason.
]=]
function TutorialMatchService:resolve() : boolean
	if self.Tutorial ~= nil then
		return self.Tutorial
	end

	if RunService:IsStudio() and self:studioFlag() then
		self.Tutorial = true

		log:Debug("tutorial match via the StudioMap attribute.")

		return true
	end

	local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()

	self.Tutorial = self:teleportedFlag(player)

	if self.Tutorial then
		log:Debug(`tutorial match via the TeleportData of {player.Name}.`)
	end

	return self.Tutorial
end

--[[ API ]]

--[=[
	Is this match the tutorial?

	**May yield** on the first call on a published server, waiting for the first
	player. Callers inside the round already have a player in the room, so in practice
	it answers immediately.
]=]
function TutorialMatchService:IsTutorial() : boolean
	return self:resolve()
end

--[=[
	The preset this match imposes, or `nil` when it is a regular match.

	`WaveService` uses it to skip the difficulty vote: getting a preset from here, it
	does not even open the vote.
]=]
function TutorialMatchService:GetForcedPreset() : any
	if not self:IsTutorial() then
		return nil
	end

	local name = Config.Match.Difficulty
	local preset = DifficultyConfig.Presets[name]

	if not preset then
		log:StudioWarn(`preset "{name}" does not exist in Config.Difficulty.Presets; the match will vote as usual.`)

		return nil
	end

	return preset
end

--[=[
	This match's deck, or `nil` when it is a regular match: `{ [unit] = count }`, the
	same format `DeckConfig.tally` returns.

	A copy on every call: the receiver changes the table (it becomes the session's card
	count), and the config must not be spent by the match.
]=]
function TutorialMatchService:GetDeck() : { [string] : number }?
	if not self:IsTutorial() then
		return nil
	end

	local counts = {}

	for _, slot in Config.Match.Deck do
		counts[slot.Unit] = (counts[slot.Unit] or 0) + slot.Amount
	end

	return counts
end

--[=[
	The tutorial deck's cards in hotbar order, or `nil` outside it.

	The client hotbar is drawn from the **profile** (`DeckConfig.unitList`), and the
	tutorial deck is not in the profile on purpose. That is why it travels: without this
	list, the server would know the cards and the screen would show none.
]=]
function TutorialMatchService:GetDeckOrder() : { string }?
	if not self:IsTutorial() then
		return nil
	end

	local order = {}

	for _, slot in Config.Match.Deck do
		table.insert(order, slot.Unit)
	end

	return order
end

--[[ THE SCRIPT ]]

--[=[
	This wave's step, if any.
]=]
function TutorialMatchService:StepFor(wave : number) : any
	for _, step in Config.Match.Steps do
		if step.Wave == wave then
			return step
		end
	end

	return nil
end

--[=[
	The map part where the step asks for the unit.

	Read from the **loaded** map (`Workspace.Map`), not `ServerStorage`: the stored copy
	is away from the world, and its position is useless for pointing at anything.
]=]
function TutorialMatchService:pointFor(step : any) : BasePart?
	if not step or not step.Point then
		return nil
	end

	local part = self:pointNamed(step.Point)
	if not part then
		log:StudioWarn(`step "{step.Id}" asks for point "{step.Point}", which does not exist in Map.PlacementPoints.`)
	end

	return part
end

--[=[
	A part from `Map.PlacementPoints`, by name.
]=]
function TutorialMatchService:pointNamed(name : string) : BasePart?
	local map = workspace:FindFirstChild("Map")
	local points = map and map:FindFirstChild("PlacementPoints")
	local part = points and points:FindFirstChild(name)

	return if part and part:IsA("BasePart") then part else nil
end

--[=[
	Opens this wave's step: tells the client to show the instruction and locks what the
	step restricts.

	What the client receives is enough to draw: the step type, the allowed card, the
	point's position, and the lines. The **rule** stays here: the client dims the other
	cards as a courtesy, the server refuses them for safety.
]=]
function TutorialMatchService:BeginStep(wave : number)
	if not self:IsTutorial() then return end

	-- A previous wave's step that holds the **next** one (using Weather Report) is
	-- waited for here, before this wave's step opens: one step at a time, and the new
	-- wave does not start on top of a pending task.
	self:awaitPending()

	self:openStep(self:StepFor(wave))
end

--[=[
	Opens the step the script keeps for the end of the match: the results screen's,
	which belongs to no wave.

	`onRoundEnded` calls it, at the same instant the screen is sent. It does not wait for
	a pending step: the match is over, and what was left undone stays undone.
]=]
function TutorialMatchService:BeginFinal()
	if not self:IsTutorial() then return end

	self:openStep(self:finalStep())
end

--[=[
	The end-of-match step, if the script has one.
]=]
function TutorialMatchService:finalStep() : any
	for _, step in Config.Match.Steps do
		if step.Kind == "Lobby" then
			return step
		end
	end

	return nil
end

--[=[
	Puts a step live: stores it, applies what it imposes, and tells the client to draw.

	It is the body `BeginStep` and `BeginFinal` share: they only differ in **which**
	step to look for.
]=]
function TutorialMatchService:openStep(step : any)
	if not step then
		self.Step = nil

		return
	end

	self.Step = step
	self.Done = false
	self.LastWave = step.Wave or self.LastWave

	if step.UnlocksDeck then
		self.DeckUnlocked = true
	end

	self:scheduleWeather(step)
	self:ensureCash(step)
	self:grantCash(step)

	local point = self:pointFor(step)

	-- The wrap-up step points at several places at once: one arrow per free point.
	local positions = nil
	if step.Points then
		positions = {}

		for _, name in step.Points do
			local part = self:pointNamed(name)

			if part then
				table.insert(positions, part.Position)
			end
		end
	end

	log:Debug(string.format("opening step '%s' (%s, %s)%s",
		step.Id,
		if step.Wave then `wave {step.Wave}` else "end of match",
		step.Kind,
		step.Hold and ", holding the wave" or ""))

	-- The cards the script still locks, so the client's hand does not accept the
	-- click of one the server would refuse.
	local locked = {}
	for _, other in Config.Match.Steps do
		if other.Kind == "Use" and other.Card and not self.Completed[other.Id] then
			locked[other.Card] = true
		end
	end

	for _, player in Players:GetPlayers() do
		Framework:Fire("TutorialStep", player, {
			Id = step.Id,
			Kind = step.Kind,
			Unit = step.Unit,
			Card = step.Card,
			Highlight = step.Highlight,
			HighlightWait = step.HighlightWait,
			Position = point and point.Position or nil,
			Positions = positions,
			Lines = step.Lines,
			HideDeck = step.HideDeck,

			Locked = locked,
			AllowedUnits = self:allowedUnits(),

			--[[
				The step's button whitelist. It travels because the client disables buttons:
				buttons are screen, and the screen is the client's.

				This is **not** a game rule: what the server refuses is still refused on the
				server (`CanPlace`, `CanUse`, `CanBuy`, `CanSell`, `CanUpgrade`), and this
				lock is interface courtesy. A tampered client unlocks its own screen and
				gains nothing from it.
			]]
			Buttons = step.Buttons,
			BlockedButtons = step.BlockedButtons,
			ButtonRelease = step.ButtonRelease,
		})
	end
end

--[=[
	Opens the intermission step: the script's first, the Ready button's.

	`WaveService` calls it **before** the countdown starts: the dialog comes in while
	the clock is still full, and when it closes the button is already on screen for the
	highlight to hug.

	Outside a tutorial match, and for a script without a step for wave zero, it does
	nothing, like the rest of the API here.
]=]
function TutorialMatchService:BeginIntermission()
	self:BeginStep(INTERMISSION_WAVE)
end

--[=[
	The intermission countdown ended: closes the Ready step.

	"Ended" is the end of `runIntermission`, which comes both ways: the clock ran out,
	or everyone got ready before it, which in a tutorial match is the player clicking
	the button the step just pointed at. Both mean the same thing to the script: wave 1
	is coming, and its step is next.
]=]
function TutorialMatchService:NoteIntermissionEnd()
	local step = self.Step

	if step and step.Kind == "Ready" then
		self:CompleteStep()
	end
end

--[=[
	Waits for a previous wave's step that asked to hold the next one (`HoldNext`).
]=]
function TutorialMatchService:awaitPending()
	local step = self.Step

	while step and step.HoldNext and not self.Done and self.Step == step do
		task.wait(0.2)
		step = self.Step
	end
end

--[=[
	Schedules the weather the step asks for on the next wave.

	It goes through the same `Scheduled`/`ScheduledWave` as the normal roll, not a
	parallel path: that way the weather warning shows on screen through the usual code,
	which is exactly what this tutorial step teaches the player to read.
]=]
function TutorialMatchService:scheduleWeather(step : any)
	if not step.ScheduleWeather or #step.ScheduleWeather == 0 then return end

	local weather = self.Services.WeatherRoundService
	if not weather then return end

	local name = step.ScheduleWeather[math.random(1, #step.ScheduleWeather)]

	weather.Scheduled = name
	weather.ScheduledWave = step.Wave + 1

	weather:broadcastWarning(name, 1)

	log:Debug(`"{name}" scheduled for wave {step.Wave + 1}.`)
end

--[=[
	The safety net against a dead end: a step that **requires** a purchase and holds the
	wave must not find a player without money.

	It tops up only the difference, and only up to the price: it is not a gift, it is
	the guarantee that the script does not get stuck. Outside a step with `Ensure`,
	nobody gets anything.
]=]
function TutorialMatchService:ensureCash(step : any)
	if not step.Ensure or not step.Card then return end

	local mobService = self.Services.MobService
	if not mobService then return end

	local card = RoundCardConfig.Get(step.Card)
	local price = card and math.max(0, card.Price or 0) or 0
	if price <= 0 then return end

	for _, player in Players:GetPlayers() do
		local missing = price - (mobService:getCash(player) or 0)

		if missing > 0 then
			mobService:addCash(player, missing)

			log:Debug(`topped up {missing} so {player.Name} can buy "{step.Card}".`)
		end
	end
end

--[=[
	The money the step **gives** when it opens.

	It is the other side of `ensureCash`: that one tops up the difference to a card's
	price, this one hands over the full amount without asking how much the player has.
	The script's wrap-up asks for it: it tells the player to cover the free points and
	so must guarantee the change for the cards still in hand.

	It pays once per step: `Granted` stores the `Id` because the same step may be opened
	again, and a repeated gift would be money born from nothing.
]=]
function TutorialMatchService:grantCash(step : any)
	local amount = step.GrantCash
	if not amount or amount <= 0 then return end

	if self.Granted[step.Id] then return end

	local mobService = self.Services.MobService
	if not mobService then return end

	self.Granted[step.Id] = true

	for _, player in Players:GetPlayers() do
		mobService:addCash(player, amount)
	end

	log:Debug(`gave {amount} cash on step "{step.Id}".`)
end

--[=[
	Holds the wave while its step is not completed.

	`WaveService` calls it after announcing the wave number and before the enemies
	spawn. A step without `Hold` holds nothing: the dialog appears and the wave runs over
	it, which is right for an instruction that requires no action.

	The loop checks the step's generation, not a loose boolean: a `StopRound` in the
	middle of the tutorial closes the step, and the wait must die with it.
]=]
function TutorialMatchService:AwaitStep(wave : number)
	local step = self.Step
	if not step or step.Wave ~= wave or not step.Hold then
		return
	end

	while self.Step == step and not self.Done do
		-- The room's step is state, not an event: reading the value avoids grafting
		-- code onto `SpeedService` to notify the tutorial.
		if step.Kind == "Speed" then
			local speed = self.Services.SpeedService

			if speed and speed:GetIndex() >= (step.Index or 2) then
				self:CompleteStep()

				break
			end
		end

		task.wait(0.2)
	end
end

--[=[
	Does this player still have a unit card in hand?

	Read from `UnitService`, which counts the session's cards: the profile count does not
	work, because the tutorial deck does not come from it.
]=]
function TutorialMatchService:handIsEmpty(player : Player) : boolean
	local unitService = self.Services.UnitService
	if not unitService then
		return true
	end

	local cards = unitService.SessionCards and unitService.SessionCards[player.UserId]
	if not cards then
		return true
	end

	for _, count in cards do
		if count > 0 then
			return false
		end
	end

	return true
end

--[=[
	The step was completed: notifies the client and releases the wave.
]=]
function TutorialMatchService:CompleteStep()
	local step = self.Step
	if not step or self.Done then return end

	self.Done = true
	self.Completed[step.Id] = true

	log:Debug(`step "{step.Id}" completed; the wave is released.`)

	local analytics = self.Services.AnalyticsService

	for _, player in Players:GetPlayers() do
		--[[
			The onboarding funnel uses **the step's `Id`** as the name, so the script and the
			`ServerConfig.Analytics` list need no translation table between them.

			The end-of-match step is left out: it is not a task the player completes, and the
			Lobby records the return to the Lobby, through the teleport ticket.
		]]
		if analytics and step.Kind ~= "Lobby" then
			analytics:LogFunnelStep(player, step.Id)
		end

		Framework:Fire("TutorialStepDone", player, step.Id)
	end
end

--[=[
	Must the card shop open on this wave?

	The normal calendar is `RoundCardConfig.IsShopWave`; in the tutorial it **does not
	count** (see `ShopIsScripted`) and the shop only opens on the waves the script
	declares.
]=]
function TutorialMatchService:ShouldOpenShop(wave : number) : boolean
	if not self:IsTutorial() then
		return false
	end

	local step = self:StepFor(wave)

	return step ~= nil and step.OpenShop == true
end

--[=[
	In the tutorial the shop is scripted: only the step's `OpenShop` opens it.

	`RoundCardConfig`'s calendar has a fixed interval (4 waves for the tutorial preset,
	which has no entry of its own in `Intervals`), so wave 4 would open the shop on its
	own, in the middle of the 2x step: an offer the script did not ask for, over an
	instruction pointing at another corner of the screen, with cards the next step does
	not even allow using. The shop lesson was already given on wave 2, and it is given
	**once**.

	It applies both ways: this question is what silences the calendar in the tutorial,
	and `ShouldOpenShop` is what makes the script speak.
]=]
function TutorialMatchService:ShopIsScripted() : boolean
	return self:IsTutorial()
end

--[=[
	The card this wave's step plants in the rotation, if any.
]=]
function TutorialMatchService:ForcedCard(wave : number) : string?
	if not self:IsTutorial() then
		return nil
	end

	local step = self:StepFor(wave)

	return step and step.Kind == "Buy" and step.Card or nil
end

--[=[
	Is this purchase allowed now?

	With a purchase step open, only its card. The other two stay on the table and
	refused: the player sees they exist, and learns which one the step wants.
]=]
function TutorialMatchService:CanBuy(cardId : string) : boolean
	local step = self.Step

	if not step or step.Kind ~= "Buy" or self.Done then
		return true
	end

	return cardId == step.Card
end

--[=[
	The units the hand accepts now: `{ [name] = true }`, or `nil` when the deck is
	unlocked.

	Outside a tutorial match it returns `nil`: the normal game locks nothing.
]=]
function TutorialMatchService:allowedUnits() : { [string] : boolean }?
	if not self:IsTutorial() or self.DeckUnlocked then
		return nil
	end

	local list = Config.Match.AllowedUnits
	if not list or #list == 0 then
		return nil
	end

	local allowed = {}
	for _, unitName in list do
		allowed[unitName] = true
	end

	return allowed
end

--[=[
	The use step that asks for this card, if the script has one.
]=]
function TutorialMatchService:useStepFor(cardId : string) : any
	for _, step in Config.Match.Steps do
		if step.Kind == "Use" and step.Card == cardId then
			return step
		end
	end

	return nil
end

--[=[
	Can this card be used yet?

	A card the script regulates stays **locked until its step opens**: Weather Report is
	bought on wave 2 and is for wave 3, and spending it before the weather exists loses
	the card and the lesson together: the player would be stuck in a step asking for a
	card they no longer have.

	A card the script does not mention always passes; a completed step also unlocks.
]=]
function TutorialMatchService:CanUse(cardId : string) : boolean
	if not self:IsTutorial() then
		return true
	end

	local step = self:useStepFor(cardId)
	if not step then
		return true
	end

	if self.Step == step and not self.Done then
		return true
	end

	return self.Completed[step.Id] == true
end

--[=[
	A purchase happened. Closes the purchase step that asked for this card.
]=]
function TutorialMatchService:NoteBuy(cardId : string)
	local step = self.Step

	if step and step.Kind == "Buy" and step.Card == cardId then
		self:CompleteStep()
	end
end

--[=[
	A use happened. Closes the use step that asked for this card.
]=]
function TutorialMatchService:NoteUse(cardId : string)
	local step = self.Step

	if step and step.Kind == "Use" and step.Card == cardId then
		self:CompleteStep()
	end
end

--[=[
	The tutorial match was won.

	`WaveService` calls it, in the same branch that writes the win to the profile. It is
	only for telemetry: without it, the teleport back would look like a player giving
	up: both leave through `PlayerRemoving`.
]=]
function TutorialMatchService:NoteWon()
	self.Won = true
end

--[=[
	Is upgrading a unit allowed now?

	**In the tutorial match, never**, and not only while a step is open.

	Two reasons, both holding for the whole match: the money is counted for the deck
	(`StartingCash` covers the three towers, and an upgrade along the way leaves the
	wrap-up step without money to buy the other two), and the script already teaches
	four things: placing, buying, using a card, and speeding up. Upgrading towers is
	the lesson of the first real match.

	The button stays on screen, locked (`ToggleTower`): the player sees it exists. This
	is what refuses it, because the client does not police itself.

	Outside a tutorial match it returns `true`: the normal game locks nothing.
]=]
function TutorialMatchService:CanUpgrade() : boolean
	return not self:IsTutorial()
end

--[=[
	Is selling a unit allowed now?

	**In the tutorial match, never**, for the same reason as `CanUpgrade` plus one of
	its own: selling undoes a step the script already counted as done. Wave 1's
	Slingshot is the tower the player learns weather, the shop, and speed with; without
	it on the ground, the next three lessons happen on an empty map, and the card that
	returns to the hand has no step asking for it again.

	The button stays on screen, locked (`ToggleTower`). This is what refuses it.
]=]
function TutorialMatchService:CanSell() : boolean
	return not self:IsTutorial()
end

--[=[
	Is this placement allowed now?

	`true` when no placement step is open: outside the script, the tutorial does not
	interfere. With a step open, only the requested card passes, and only near the
	requested point: it is the half of the rule that does not depend on the client
	behaving.
]=]
function TutorialMatchService:CanPlace(unitName : string, cf : CFrame) : boolean
	--[[
		The deck lock holds for the whole match until the wrap-up step, not only while a
		step is open: between wave 1 and 5 there is no placement step, and without this
		the player would put the Archers on the map in the first intermission.
	]]
	local allowed = self:allowedUnits()
	if allowed and not allowed[unitName] then
		return false
	end

	local step = self.Step
	if not step or self.Done then
		return true
	end

	-- The wrap-up step accepts any card, but only on the remaining points: wave 5's
	-- lesson is covering the map, not obeying a spot.
	if step.Kind == "PlaceRest" then
		for _, name in (step.Points or {}) do
			local part = self:pointNamed(name)

			if part and (cf.Position - part.Position).Magnitude <= (step.Radius or 10) then
				return true
			end
		end

		return false
	end

	if step.Kind ~= "Place" then
		return true
	end

	if step.Unit and unitName ~= step.Unit then
		return false
	end

	local point = self:pointFor(step)
	if not point then
		-- A point that does not exist on the map must not become a lock: the step already
		-- warned in the output, and trapping the player over it would turn a setup
		-- mistake into a stuck match.
		return true
	end

	return (cf.Position - point.Position).Magnitude <= (step.Radius or 10)
end

--[[ TELEMETRY ]]

--[=[
	Who entered the tutorial match, and who left it before winning.

	Connected once, and **only** when the server resolved as a tutorial server (see
	`construct`): a regular match does not pay for this listener.

	The server is reserved and the match is single player, but the step is per player:
	anyone arriving here through a path other than the offer's teleport enters the
	funnel the same way.
]=]
function TutorialMatchService:watchPlayers()
	local analytics = self.Services.AnalyticsService
	if not analytics then return end

	local function joined(player : Player)
		analytics:LogFunnelStep(player, "MatchJoined")
	end

	for _, player in Players:GetPlayers() do
		joined(player)
	end

	Players.PlayerAdded:Connect(joined)

	--[[
		Leaving without having won is abandonment, and it is exactly what the funnel does
		not count: someone who gives up on wave 3 and someone who drops from a bad
		connection stop at the same step, and neither leaves a trace on the profile (the
		key stays `false`, on purpose).

		The teleport back after winning also leaves through here; `Won` tells them apart.
	]]
	Players.PlayerRemoving:Connect(function(player : Player)
		if self.Won then return end

		local step = self.Step

		analytics:LogEvent(player, AnalyticsConfig.Events.Abandoned, self.LastWave or 0, {
			step and step.Id or "None",
		})
	end)
end

--[[ LIFECYCLE ]]

function TutorialMatchService:construct()
	-- The identifiers are created on the server: without these empty `Listen`s, the client
	-- would wait ten seconds for events nobody registered.
	Framework:Listen("TutorialStep", function() end)
	Framework:Listen("TutorialStepDone", function() end)
	Framework:Listen("TutorialDeck", function() end)

	-- Resolves off the first round's path: the wait for the first player happens here,
	-- on its own thread, not inside `runRound`.
	task.spawn(function()
		if not self:resolve() then return end

		self:watchPlayers()
	end)

	local unitService = self.Services.UnitService
	if not unitService then return end

	-- The placement that passed all of `UnitService`'s checks (ours included) is
	-- the one that completes the step. Listening to the signal, instead of grafting
	-- more code onto `PlaceUnit`, keeps the tutorial rule off the hot path of the
	-- match.
	unitService.Signals.UnitPlaced:Connect(function(player : Player, unitName : string)
		local step = self.Step
		if not step then return end

		if step.Kind == "Place" and (not step.Unit or step.Unit == unitName) then
			self:CompleteStep()

			return
		end

		-- The wrap-up ends when the hand empties: with cards left there are still points to
		-- cover, and the step keeps asking.
		if step.Kind == "PlaceRest" and self:handIsEmpty(player) then
			self:CompleteStep()
		end
	end)
end

function TutorialMatchService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function TutorialMatchService:init()
end

return TutorialMatchService
