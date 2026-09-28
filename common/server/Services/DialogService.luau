local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.DialogConfig

--[[
	The server telling the dialog to speak.

	The dialog box belongs to the client (`DialogController`), and the client almost
	always decides what it says too: an NPC line starts with a touch, a portal, a
	button. This service exists for the other case: a line the **server** triggers,
	because only it knows the line is due (a completed contract, a special wave, the
	first match's tutorial).

		DialogService:Send(players, {
			"Wave 8 brings a [shake]BLIZZARD[/shake].",
		}, { Auto = true })

	It lives in `common/` because both places have the box.

	See docs/common/dialog.md.
]]

local DialogService = {
	Services = {}
}

--[[ API ]]

export type SendOptions = {
	Auto : boolean?,
	Preset : string?,
	Speed : number?,

	-- The box's buttons, only the part that is data: text and visibility. What they
	-- do when clicked belongs to the client, because callbacks do not cross the network.
	Buttons : { { Text : string?, Visible : boolean? } }?,
}

--[=[
	Sends the conversation to everyone in the list. `lines` is one sentence or a list
	of them, with `RichTextController` markup inside.

	Without `players`, it speaks to the whole server: that is what Cmdr uses when it
	gets no target.
]=]
function DialogService:Send(players : { Player }?, lines : string | { string }, options : SendOptions?)
	local list = if type(lines) == "table" then lines else { lines }
	if #list == 0 then return end

	for _, player in (players or Players:GetPlayers()) do
		Framework:Fire("DialogPlay", player, list, options)
	end
end

--[=[
	The test line from `DialogConfig.Demo`, which is how the Cmdr `dialog` command
	gets in. It goes with both buttons on, so they can be seen without anyone
	writing code.

	The copy keeps the config from being changed by a caller passing `options` with
	their own `Buttons`: a config table is read-only, and changing it from afar
	breaks the whole session.
]=]
function DialogService:SendDemo(players : { Player }?, options : SendOptions?)
	local merged : any = if options then table.clone(options) else {}
	if merged.Buttons == nil then
		merged.Buttons = Config.DemoButtons
	end

	self:Send(players, Config.Demo, merged)
end

--[[ LIFECYCLE ]]

function DialogService:construct()
	-- The event identifier is created on the server: without this empty `Listen`,
	-- the client's `Listen` would wait ten seconds for an event nobody registered,
	-- and take the rest of its `construct` down with it.
	Framework:Listen("DialogPlay", function() end)
end

function DialogService:start()
end

function DialogService:init()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

return DialogService
