local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Signal = require(Packages.Signal)

local Framework = Me.new()
local log = Log.new("WeatherRoundService")

local WeatherConfig = SharedConfig.WeatherConfig
local RoundConfig = WeatherConfig.Round


--[[
	Weather as a match event.

	`WeatherService` (in `common/`) knows how to turn a weather on and off; it knows
	nothing about waves. This service is the other half: it decides **whether**,
	**which**, and **when**, within the round.

	The cycle when a wave starts:

		1. the weather the Weather Report card cleared last wave returns, if it still
		   has time left (see `SkipCurrentWave`);
		2. the weather already active leaves, if its duration is over;
		3. the weather scheduled for this wave comes in;
		4. with nothing scheduled or active, a die is rolled, and if it passes, a
		   weather from the map's pool is chosen and **announced** `LeadWaves` waves
		   ahead.

	Step 1 comes before 2 because both meet in the same case: a card used on a
	weather's last wave has nothing to restore, and step 2 settles it, the same end
	any weather has.

	The warning is the point of the system. Weather never falls by surprise: the
	player sees three waves ahead which weather is coming, and that is what turns
	weather from bad luck into a decision: there is time to sell what will become
	useless and place what will shine.

	A weather is only scheduled if it fits in the match: `wave + LeadWaves` beyond the
	preset's wave count produces no warning, because it would warn about something
	that will not happen.

	One weather at a time, and the die is not even rolled while one is scheduled or
	active. Two overlapping warnings on screen and two sets of multipliers composing
	would be unreadable on both sides.

	**Challenge matches replace the die** (`challengeStep`): the challenge says which
	weather is on for every wave (`ChallengeConfig.weatherAt`), in cycles of weather
	and clear waves. Every weather that starts, including one returning after a clear
	stretch, is announced through the usual warning when it is `LeadWaves` or fewer
	waves away, and the Weather Report card still clears a single wave.

	See docs/game/weather-in-match.md.
]]

--[[
	Nothing here pushes weather into combat.

	`UnitService` reads the weather from `WeatherService` every frame and `MobService`
	checks whether it changed in the same place, so turning the weather on is the only
	step: the effects come in on their own. That is what makes the `weather` command
	produce exactly the same match this service produces.
]]

local WeatherRoundService = {
	Services = {
		WeatherService = {},
		MapService = {},
		WaveService = {},
		DifficultyService = {},
		IndexService = {},
	},

	Signals = {
		--[[
			(weatherName): a round weather went live. Only what actually goes live: the
			warning does not count, and a weather the Weather Report card cleared that
			returns next wave does not either (it is the same weather).
			`ContractTrackerService` listens ("Experience Weathers 60 times").
		]]
		WeatherStarted = Signal.new(),
	},
}

-- The weather live by this service's decision, and the last wave it lasts.
WeatherRoundService.Active = nil :: string?
WeatherRoundService.ActiveUntilWave = nil :: number?

-- The announced weather not yet applied, and the wave it comes in.
WeatherRoundService.Scheduled = nil :: string?
WeatherRoundService.ScheduledWave = nil :: number?

-- The wave whose weather the Weather Report card cleared. See `SkipCurrentWave`.
WeatherRoundService.SkippedWave = nil :: number?

--[[ CHOICE ]]

--[=[
	The loaded map's name.

	It comes from `MapService`, which cloned the folder: it cannot be found by looking
	at `workspace.Map`, because the cloned Model is called "Map" in all of them.
]=]
function WeatherRoundService:GetMapName() : string?
	local mapService = self.Services.MapService
	return mapService and mapService.CurrentMapName or nil
end

--[=[
	A weather from the current map's pool, or nil when the map has no pool.

	The draw is uniform within the pool. A weather that does not exist in
	`Assets.Weathers` is dropped here instead of failing further on: the pool is
	hand-written config, and a mistyped name is its most likely error.
]=]
function WeatherRoundService:PickWeather() : string?
	local mapName = self:GetMapName()
	local pool = WeatherConfig.GetPool(mapName)
	if #pool == 0 then
		return nil
	end

	local weatherService = self.Services.WeatherService
	local candidates = {}

	for _, name in pool do
		if not weatherService or weatherService:GetWeather(name) then
			table.insert(candidates, name)
		else
			log:StudioWarn(string.format("the pool for '%s' asks for weather '%s', which does not exist in Assets.Weathers.",
				tostring(mapName), name))
		end
	end

	if #candidates == 0 then
		return nil
	end

	return candidates[math.random(1, #candidates)]
end

--[=[
	The warning chance per wave. It comes from the difficulty preset;
	`WeatherConfig.Round` covers presets without the field.
]=]
function WeatherRoundService:GetChance() : number
	local preset = self.Services.DifficultyService and self.Services.DifficultyService:GetSelected()
	return (preset and preset.WeatherChance) or RoundConfig.Chance or 0
end

--[[ WARNING ]]

--[=[
	Sends the warning to everyone.

	`wavesAhead` is computed on the server on purpose: it is what the text shows, and
	letting the client subtract on its own would open room for it to show a different
	number from the one the server will keep.
]=]
function WeatherRoundService:broadcastWarning(weatherName : string, wavesAhead : number)
	--[[
		The target wave goes along with the "how many left".

		The on-screen warning uses the ready number, which is why it exists; the HUD
		indicator, which answers a click **later** (one or two waves later), must redo
		the math with the current wave, and for that it needs the target. Counting on
		its own from `wavesAhead` would go wrong exactly when it matters: this warning
		and the same wave's `SetWave` go out in different events, and the order they
		reach the client is not guaranteed.
	]]
	for _, player in Players:GetPlayers() do
		Framework:Fire("WeatherWarning", player, weatherName, wavesAhead, self.ScheduledWave)
	end
end

--[=[
	Tells clients until which wave the current weather lasts.

	`ActiveUntilWave` is a target wave, and that is what travels, not the "how many
	left". The indicator panel is opened **later**, one or two waves later, and redoes
	the math with the current wave; sending the ready number would give a panel saying
	"ENDS IN 4 WAVES" on the weather's last wave.

	The **name goes along** because this notification and `WeatherChanged` are
	different events and their order is not guaranteed: the name tells the client
	whether the deadline that arrived belongs to the weather it is seeing.

	A clear sky sends both as `nil`, so the client does not keep the deadline of the
	weather that just left.

	`player` restricts to a single player: that is what the request of someone joining
	mid-match needs.
]=]
function WeatherRoundService:broadcastDuration(player : Player?)
	local weatherName = self.Active
	local untilWave = weatherName and self.ActiveUntilWave or nil

	if player then
		Framework:Fire("WeatherDuration", player, weatherName, untilWave)
		return
	end

	for _, target in Players:GetPlayers() do
		Framework:Fire("WeatherDuration", target, weatherName, untilWave)
	end
end

--[[ CYCLE ]]

--[=[
	Removes the weather this service turned on.

	It only touches its own: a weather turned on by hand with the `weather` command is
	not turned off here, because its `Active` is empty.
]=]
function WeatherRoundService:ClearActive()
	if not self.Active then return end

	local previous = self.Active
	self.Active = nil
	self.ActiveUntilWave = nil

	local weatherService = self.Services.WeatherService
	if weatherService then
		weatherService:Clear(RoundConfig.TransitionTime)
	end

	self:broadcastDuration()

	log:Debug(string.format("'%s' ended.", previous))
end

function WeatherRoundService:applyScheduled(waveNumber : number)
	local weatherName = self.Scheduled
	if not weatherName then return end

	self.Scheduled = nil
	self.ScheduledWave = nil

	local weatherService = self.Services.WeatherService
	if not weatherService then return end

	local ok, message = weatherService:Apply(weatherName, RoundConfig.TransitionTime)
	if not ok then
		log:Warn(string.format("could not apply '%s' (%s).", weatherName, tostring(message)))
		return
	end

	self.Active = weatherName
	self.ActiveUntilWave = waveNumber + math.max(1, RoundConfig.Duration or 1) - 1

	self:broadcastDuration()

	log:Debug(string.format("'%s' started on wave %d, until wave %d.", weatherName, waveNumber, self.ActiveUntilWave))

	self.Signals.WeatherStarted:Fire(weatherName)
end

--[=[
	Puts back in the sky the weather the card cleared, when it still had waves ahead.

	Failing here clears `Active`: the weather is not in the sky, and continuing to
	count its waves would have the service promise an end for something that did not
	start, and worse, hold back the next roll until that date.
]=]
function WeatherRoundService:resumeActive(waveNumber : number)
	local weatherName = self.Active
	if not weatherName then return end

	local weatherService = self.Services.WeatherService
	if not weatherService then return end

	local ok, message = weatherService:Apply(weatherName, RoundConfig.TransitionTime)
	if not ok then
		log:Warn(string.format("could not restore '%s' (%s).", weatherName, tostring(message)))

		self.Active = nil
		self.ActiveUntilWave = nil
		self:broadcastDuration()
		return
	end

	self:broadcastDuration()

	log:Debug(string.format("'%s' came back on wave %d, until wave %d.", weatherName, waveNumber, self.ActiveUntilWave or waveNumber))
end

--[=[
	Removes the weather from the sky **for this wave, and only this one**.
	`CardShopService` calls it (the Weather Report card).

	The card is an umbrella for one wave, not a cancellation of the weather: a
	three-wave storm bought on the first wave continues in the other two, and a player
	who wants all three clear buys three cards. Bought on its last wave, the weather
	simply ends there: there is nothing to bring back.

	That is why `Active` and `ActiveUntilWave` are **not** reset, and `ClearActive` is
	not called: `WeatherService`'s `Clear` removes the weather from the sky now, and the
	next wave's `OnWaveStarted` restores it through `resumeActive` if there is time
	left. Resetting the state here would erase exactly the memory that it must return.

	A clear sky returns `false` and nothing happens: there is no weather wave to skip.

	A scheduled weather's warning is not touched either: it comes in on its wave, as
	it would. The card is about the wave in progress, not the future.
]=]
function WeatherRoundService:SkipCurrentWave() : boolean
	local weatherService = self.Services.WeatherService
	if not weatherService or not weatherService:GetCurrent() then
		log:Debug("Weather Report used with the sky already clear: nothing to skip.")
		return false
	end

	local waveService = self.Services.WaveService
	local current = (waveService and waveService.WaveCount) or 0

	self.SkippedWave = current

	weatherService:Clear(RoundConfig.TransitionTime)

	if self.Active and self.ActiveUntilWave and current < self.ActiveUntilWave then
		log:Debug(string.format("'%s' skipped wave %d; back on %d, until %d.",
			self.Active, current, current + 1, self.ActiveUntilWave))
	else
		log:Debug(string.format("clear sky on wave %d.", current))
	end

	return true
end

--[=[
	Puts a weather in the sky right now for `waves` waves (this one included).
	`CardShopService` calls it (the Endless shop's weather cards). It replaces whatever is
	active or announced.
]=]
function WeatherRoundService:Summon(weatherName : string, waves : number?) : (boolean, string?)
	local weatherService = self.Services.WeatherService
	if not weatherService or not weatherService:GetWeather(weatherName) then
		return false, "unknown weather"
	end

	local ok, message = weatherService:Apply(weatherName, RoundConfig.TransitionTime)
	if not ok then
		return false, message
	end

	local waveService = self.Services.WaveService
	local current = (waveService and waveService.WaveCount) or 0

	self.Scheduled = nil
	self.ScheduledWave = nil
	self.SkippedWave = nil

	self.Active = weatherName
	self.ActiveUntilWave = current + math.max(1, waves or 1) - 1

	self:broadcastDuration()
	self.Signals.WeatherStarted:Fire(weatherName)

	return true
end

--[[ CHALLENGES ]]

--[=[
	A challenge match's wave: the challenge decides the weather, not the die.

	The weather for this wave comes from `ChallengeService:GetWeather` (nil on a clear
	wave) and lasts until `GetWeatherEnd`. Changing weather goes through the same
	`Apply` and `WeatherStarted` as a rolled one, so contracts, the Index, and the
	indicator count it the same way. The next weather, when it is a change or comes
	back after clear waves, is announced with the usual warning once it is
	`LeadWaves` or fewer waves away.
]=]
function WeatherRoundService:challengeStep(challengeService, waveNumber : number, maxWaves : number?)
	if self.SkippedWave and waveNumber > self.SkippedWave then
		self.SkippedWave = nil
	end

	local weatherService = self.Services.WeatherService
	if not weatherService then return end

	local weatherName = challengeService:GetWeather(waveNumber)

	if not weatherName then
		self:ClearActive()
	else
		local untilWave = challengeService:GetWeatherEnd(waveNumber) or waveNumber
		if maxWaves then
			untilWave = math.min(untilWave, maxWaves)
		end

		if weatherName ~= self.Active then
			self.Scheduled = nil
			self.ScheduledWave = nil

			local ok, message = weatherService:Apply(weatherName, RoundConfig.TransitionTime)
			if not ok then
				log:Warn(string.format("could not apply challenge weather '%s' (%s).", weatherName, tostring(message)))

				self.Active = nil
				self.ActiveUntilWave = nil
				self:broadcastDuration()
				return
			end

			self.Active = weatherName
			self.ActiveUntilWave = untilWave

			self:broadcastDuration()

			log:Debug(string.format("challenge weather '%s' on wave %d, until wave %d.", weatherName, waveNumber, untilWave))

			self.Signals.WeatherStarted:Fire(weatherName)
		else
			self.ActiveUntilWave = untilWave

			if not weatherService:GetCurrent() then
				self:resumeActive(waveNumber)
			else
				self:broadcastDuration()
			end
		end
	end

	local nextWave, nextWeather = challengeService:GetNextWeather(waveNumber)
	if not nextWave or not nextWeather then return end
	if maxWaves and nextWave > maxWaves then return end

	local lead = math.max(1, RoundConfig.LeadWaves or 1)
	if nextWave - waveNumber > lead or self.ScheduledWave == nextWave then return end

	-- The same weather carrying straight on into the next cycle is not news.
	local continues = weatherName == nextWeather and self.ActiveUntilWave ~= nil and self.ActiveUntilWave + 1 == nextWave
	if continues then return end

	self.Scheduled = nextWeather
	self.ScheduledWave = nextWave

	self:broadcastWarning(nextWeather, nextWave - waveNumber)
	log:Debug(string.format("wave %d: challenge weather '%s' announced for wave %d.", waveNumber, nextWeather, nextWave))
end

--[=[
	A wave's step. Called by `WaveService`'s `WaveStarted` signal.

	Order matters: the old weather leaves and the new one enters **before** the die, so
	the die sees this wave's state and not the previous one's.
]=]
function WeatherRoundService:OnWaveStarted(waveNumber : number, _preset, maxWaves : number)
	local challengeService = Framework:Get("ChallengeService", false, false)
	if challengeService and challengeService:IsActive() then
		self:challengeStep(challengeService, waveNumber, maxWaves)
		return
	end

	--[[
		The wave Weather Report cleared is behind us.

		The weather returns **before** the deadline test just below, not after: if the
		skipped wave was its last, `waveNumber` is already past `ActiveUntilWave`,
		`resumeActive` does not run, and `ClearActive` settles it, which is the normal
		end of any weather, not a special case for the card.
	]]
	if self.SkippedWave and waveNumber > self.SkippedWave then
		self.SkippedWave = nil

		if self.ActiveUntilWave and waveNumber <= self.ActiveUntilWave then
			self:resumeActive(waveNumber)
		end
	end

	if self.ActiveUntilWave and waveNumber > self.ActiveUntilWave then
		self:ClearActive()
	end

	if self.ScheduledWave and waveNumber >= self.ScheduledWave then
		self:applyScheduled(waveNumber)
	end

	-- One weather at a time: neither active nor scheduled.
	if self.Active or self.Scheduled then return end

	local lead = math.max(1, RoundConfig.LeadWaves or 1)
	local targetWave = waveNumber + lead

	-- A warning about something that would not fit in the match is not a warning, it is noise.
	if maxWaves and targetWave > maxWaves then return end

	if math.random() >= self:GetChance() then return end

	local weatherName = self:PickWeather()
	if not weatherName then return end

	self.Scheduled = weatherName
	self.ScheduledWave = targetWave

	self:broadcastWarning(weatherName, lead)
	log:Debug(string.format("wave %d: '%s' announced for wave %d.", waveNumber, weatherName, targetWave))
end

--[=[
	Resets with the round: no previous round's weather stays active, and no schedule
	lands in a match that has not started.
]=]
function WeatherRoundService:ResetRound()
	self.Scheduled = nil
	self.ScheduledWave = nil
	self.SkippedWave = nil
	self:ClearActive()
end

--[[ API ]]

-- The weather this service put live, or nil. It is what combat queries.
function WeatherRoundService:GetActive() : string?
	return self.Active
end

function WeatherRoundService:GetScheduled() : (string?, number?)
	return self.Scheduled, self.ScheduledWave
end

--[[ LIFECYCLE ]]

function WeatherRoundService:construct()
	-- Every player in the match lived through it, so it enters their Index. Only a
	-- weather that went live: the warning alone does not count.
	self.Signals.WeatherStarted:Connect(function(weatherName : string)
		local indexService = self.Services.IndexService
		if not indexService then return end

		for _, player in Players:GetPlayers() do
			indexService:UnlockWeather(player, weatherName)
		end
	end)

	local waveService = self.Services.WaveService
	if not waveService or not waveService.Signals or not waveService.Signals.WaveStarted then
		log:Warn("WaveService has no WaveStarted signal; weather will not start on its own.")
		return
	end

	waveService.Signals.WaveStarted:Connect(function(waveNumber, preset, maxWaves)
		self:OnWaveStarted(waveNumber, preset, maxWaves)
	end)

	-- A player joining mid-match needs to know what is coming, if anything still is.
	Framework:Listen("RequestWeatherWarning", function(player : Player)
		if not self.Scheduled or not self.ScheduledWave then return end

		local waveService = self.Services.WaveService
		local current = waveService and waveService.WaveCount or 0
		local wavesAhead = self.ScheduledWave - current
		if wavesAhead <= 0 then return end

		Framework:Fire("WeatherWarning", player, self.Scheduled, wavesAhead, self.ScheduledWave)
	end)

	-- A player joining in the middle of a storm needs its deadline. A clear sky answers
	-- with `nil`, which is the right answer and not silence.
	Framework:Listen("RequestWeatherDuration", function(player : Player)
		self:broadcastDuration(player)
	end)
end

function WeatherRoundService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function WeatherRoundService:init()
	Framework:Listen("WeatherWarning", function() end)
	Framework:Listen("WeatherDuration", function() end)
end

return WeatherRoundService