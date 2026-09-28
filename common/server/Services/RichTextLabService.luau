local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	The server side of the rich text workbench.

	The workbench itself is all client (`RichTextLabController`); the server exists
	here for permission: the Cmdr `richtext` command asks it to open, and
	`CmdrService`'s `BeforeRun` decides whether the caller may. A workbench the
	client opened on its own would be a dev screen in any player's hands.

	It lives in `common/` because Cmdr runs in both places.
]]

local RichTextLabService = {
	Services = {}
}

--[[ API ]]

--[=[
	Opens the workbench for everyone in the list, or closes it if already open: the
	command is the same toggle both ways.
]=]
function RichTextLabService:Toggle(players : { Player })
	for _, player in players do
		Framework:Fire("RichTextLabToggle", player)
	end
end

--[[ LIFECYCLE ]]

function RichTextLabService:construct()
	-- The event identifier is created on the server: without this empty `Listen`,
	-- the client's `Listen` would wait ten seconds for an event nobody registered,
	-- and take the rest of its `construct` down with it.
	Framework:Listen("RichTextLabToggle", function() end)
end

function RichTextLabService:start()
end

function RichTextLabService:init()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

return RichTextLabService
