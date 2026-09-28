--[[
	The match speeds offered by the `Interface.Speed` button.

	One scale per step, plus the button art that shows **the speed the match is at
	now**. Clicking the button opens one clone per remaining step, each with its
	own art; picking one requests that step (see `SpeedController`).

	`SpeedService` (server) owns the value in use; `SpeedController` only draws the
	step the server sent. Both sides read this table, so a new speed is one line
	here: the client gets the art and the server gets the scale from `Steps`.

	`Gamepass` is optional and holds a **key** of `GamepassConfig.PASSES`, not the
	id: a step with a pass shows locked for players without it, and clicking opens
	the purchase prompt instead. The id stays in `GamepassConfig`.

	See docs/game/match-speed.md.
]]

local SpeedConfig = {}

--- The steps, in cycle order.
SpeedConfig.Steps = {
	{ Scale = 1, Image = "rbxassetid://132899761008925" },
	{ Scale = 1.5, Image = "rbxassetid://106089741438137" },
	{ Scale = 2, Image = "rbxassetid://122729764545333", Gamepass = "Speed" },
}

SpeedConfig.DEFAULT_INDEX = 1

--[[ API ]]

--- The step at the index, or the default when the index does not exist.
function SpeedConfig.Get(index : number?)
	return SpeedConfig.Steps[index or 0] or SpeedConfig.Steps[SpeedConfig.DEFAULT_INDEX]
end

function SpeedConfig.GetScale(index : number?) : number
	return SpeedConfig.Get(index).Scale
end

function SpeedConfig.GetImage(index : number?) : string
	return SpeedConfig.Get(index).Image
end

--[=[
	The game pass key the step requires, or nil when it is open to everyone.
]=]
function SpeedConfig.GetGamepass(index : number?) : string?
	local step = SpeedConfig.Steps[index or 0]

	return step and step.Gamepass or nil
end

--[=[
	Whether the index is a real step. The server asks this before accepting what
	the client requested: the request comes over the network, so it can be anything.
]=]
function SpeedConfig.IsValid(index : any) : boolean
	return typeof(index) == "number" and SpeedConfig.Steps[index] ~= nil
end

return SpeedConfig
