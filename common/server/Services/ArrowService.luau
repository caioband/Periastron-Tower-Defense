local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	The server side of the guidance arrow.

	The arrow is all client (`ArrowController`): it is decoration, and decoration the
	server replicated would cost network on every spin. Only the position crosses (a
	`Vector3`, which Warp serializes), and each client builds its own.

	It serves what the server knows and the client does not: where the enemy the
	tutorial wants to point at is, which tile the match wants highlighted. The Cmdr
	`arrow` command goes through the same path.

	It lives in `common/` because the model exists in both places.

	See docs/common/ui-guidance.md.
]]

local ArrowService = {
	Services = {}
}

--[[ API ]]

export type PointOptions = {
	Height : number?,
	Spin : number?,
	Amplitude : number?,
	BobSpeed : number?,
	Scale : number?,
}

--[=[
	Points at a position for each player in the list. One arrow per player: sending
	again moves it instead of adding arrows on screen.
]=]
function ArrowService:Point(players : { Player }, position : Vector3, options : PointOptions?)
	for _, player in players do
		Framework:Fire("ArrowPoint", player, position, options)
	end
end

--[=[
	Clears the arrow. It is the same event without a position: the client reads the
	absence as "clear", so there is no second identifier to declare and maintain.
]=]
function ArrowService:Clear(players : { Player })
	for _, player in players do
		Framework:Fire("ArrowPoint", player, false)
	end
end

--[[ LIFECYCLE ]]

function ArrowService:construct()
	-- The event identifier is created on the server: without this empty `Listen`,
	-- the client's `Listen` would wait ten seconds for an event nobody registered,
	-- and take the rest of its `construct` down with it.
	Framework:Listen("ArrowPoint", function() end)
end

function ArrowService:start()
end

function ArrowService:init()
	self:construct()
end

return ArrowService
