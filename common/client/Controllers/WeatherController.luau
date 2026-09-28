local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.WeatherConfig

--[[
	Weather audio, on the client.

	Particles and lighting arrive on their own: the first through `workspace.Weather`
	replication, the second through `LightingApplied`. Sound does not: it is local
	to each client, and it is what this controller handles.

	- **ambience**: while the weather is on, the `WeatherConfig.Ambience` loop plays
	  in the background, fading in and out.
	- **crack**: each strike plays its own clone, with a fade at the end so the tail
	  does not cut off abruptly. No `Key`, on purpose: two strikes in a row overlap
	  instead of one cutting off the other.

	The crack is 3D: `VFXController` calls it, passing the Attachment at the bolt's
	tip as the parent, so the sound comes from where the bolt hit instead of playing
	the same in everyone's ear. The audio policy (which sound, which fade) lives
	here; `VFXController` only provides the anchor.

	It lives in `common/`, like `WeatherService`.

	See docs/common/weather.md.
]]

local WeatherController = {
	Controllers = {
		MusicController = {}
	}
}

WeatherController.Current = nil :: string?

--[=[
	The weather this client is seeing, or nil.

	It is the client's source of truth for weather effects: the range
	`TargetingController` uses to look for targets, the circle
	`UnitPlacementController` draws, and the card's numbers all come from here, with
	the `WeatherConfig` multipliers on top. The server does the same math with its
	own value, so both sides show the same number.

	Anything that needs to react to the change (redraw a circle, update a label)
	listens to `WeatherChanged` itself; this method is only for reading the current
	state.
]=]
function WeatherController:GetCurrent() : string?
	return self.Current
end

--[[ AMBIENCE ]]

function WeatherController:_stopAmbience(fade: number?)
	local music = self.Controllers.MusicController
	if not music then return end

	music:StopSFX(Config.AmbienceKey, fade)
end

--[=[
	Switches the background sound to the requested weather's. `nil` turns it off.
]=]
function WeatherController:SetWeather(name: string?)
	if name == self.Current then
		return
	end

	local previous = self.Current
	self.Current = name

	local music = self.Controllers.MusicController
	if not music then return end

	local ambience = name and Config.Ambience[name]

	if not ambience then
		-- A new weather without ambience (or no weather): the current one fades out.
		local outgoing = previous and Config.Ambience[previous]
		self:_stopAmbience(outgoing and outgoing.Fade)
		return
	end

	--[[
		`PlaySFX` with a Key already stops the previous sound, but abruptly. Stopping
		it first with the outgoing weather's fade makes a switch between weathers
		crossfade instead of pop.
	]]
	local outgoing = previous and Config.Ambience[previous]
	if outgoing then
		self:_stopAmbience(outgoing.Fade)
	end

	music:PlaySFX(ambience.Sound, {
		-- The asset does not loop, and a non-looping ambience would end mid-weather.
		Looped = true,
		Key = Config.AmbienceKey,
		Fade = ambience.Fade,
		Volume = ambience.Volume,
	})
end

--[[ CRACK ]]

--[=[
	A strike's crack.

	`parent` is the Attachment at the bolt's tip; the Sound becomes its child and
	comes from the impact point. Without `parent` the sound falls back to 2D: it
	should not happen in the normal flow, but a crack in the ear beats no crack at
	all.
]=]
function WeatherController:PlayStrikeSound(parent: Instance?)
	local music = self.Controllers.MusicController
	if not music then return end

	local thunder = Config.Thunder
	if not thunder.StrikeSound then return end

	music:PlaySFX(thunder.StrikeSound, {
		Parent = parent,
		FadeOut = thunder.StrikeFadeOut,
		Volume = thunder.StrikeVolume,
	})
end

--[[ LIFECYCLE ]]

function WeatherController:construct()
	Framework:Listen("WeatherChanged", function(name: string?)
		self:SetWeather(if typeof(name) == "string" then name else nil)
	end)

	-- Which weather this client joined with: a player arriving mid-storm needs the
	-- ambience playing.
	Framework:Fire("RequestWeather")
end

function WeatherController:start() end

function WeatherController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return WeatherController
