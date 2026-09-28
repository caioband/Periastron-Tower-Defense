local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	The server side of the spotlight.

	The highlight is all client (`HighlightController`): the screen is what knows
	where a button is on screen. This service exists so the server can **ask**: the
	Cmdr `highlight` command enters here, and this is where a server-decided tutorial
	step will point at a button when one exists.

	What crosses the network is a **name path** (`"HUD.HUDLeft.Shop"`), not a
	reference: a client UI instance does not exist on the server.

	It lives in `common/` because Cmdr runs in both places.

	See docs/common/ui-guidance.md.
]]

local HighlightService = {
	Services = {}
}

--[[ API ]]

export type ShowOptions = {
	Padding : number?,
	Transparency : number?,
	BlockInput : boolean?,
}

--[=[
	Points each player in the list at the GuiObject at that path.
]=]
function HighlightService:Show(players : { Player }, path : string, options : ShowOptions?)
	for _, player in players do
		Framework:Fire("HighlightShow", player, path, options)
	end
end

--[=[
	Clears the highlight. It is the same event without a path: the client reads the
	absence as "clear", so there is no second event to declare and maintain.
]=]
function HighlightService:Hide(players : { Player })
	for _, player in players do
		Framework:Fire("HighlightShow", player, false)
	end
end

--[[ LIFECYCLE ]]

function HighlightService:construct()
	-- The event identifier is created on the server: without this empty `Listen`,
	-- the client's `Listen` would wait ten seconds for an event nobody registered,
	-- and take the rest of its `construct` down with it.
	Framework:Listen("HighlightShow", function() end)
end

function HighlightService:start()
end

function HighlightService:init()
	self:construct()
end

return HighlightService
