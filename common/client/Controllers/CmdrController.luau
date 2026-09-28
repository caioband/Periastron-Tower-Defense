local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local CmdrConfig = SharedConfig.Cmdr

local Framework = Me.new()

local CmdrController = {
	Controllers = {},
}

function CmdrController:construct()
	local Cmdr = require(ReplicatedStorage:WaitForChild("CmdrClient")) :: any
	self.Cmdr = Cmdr

	Cmdr:SetActivationKeys(CmdrConfig.ACTIVATION_KEYS)
	Cmdr:SetPlaceName(CmdrConfig.PLACE_NAME)

	--[=[
		The admin list is NOT replicated: the server decides.

		This is cosmetic: it only hides the console from non-admins. The real
		permission is revalidated by CmdrService's BeforeRun hook on every command,
		so even if an exploiter forces SetEnabled(true) they cannot run anything.

		Until the server's answer arrives, the console stays disabled.
	]=]
	Cmdr:SetEnabled(false)

	local accessible : { [string]: boolean } = {}

	--[=[
		Commands with `ClientRun` (`help`, for example) run entirely on the client and
		never go through the server's BeforeRun. With no hook on the client, Cmdr
		blocks those commands outside Studio ("no BeforeRun hook is configured"), so
		this hook is what enables `help` in the live game.
	]=]
	Cmdr.Registry:RegisterHook("BeforeRun", function(context)
		if not accessible[context.Name] then
			return "You do not have permission to run this command."
		end

		return nil
	end)

	Framework:Listen("CmdrAccess", function(commandNames : { string })
		accessible = {}

		for _, commandName in commandNames do
			accessible[commandName] = true
		end

		self:HideInaccessibleCommands(accessible)
		Cmdr:SetEnabled(next(accessible) ~= nil)
	end)

	Framework:Fire("RequestCmdrAccess")
end

--[=[
	Removes from the LOCAL registry the commands the player cannot run, which removes
	them from `help`, autocomplete, and the `command` type (which read the registry).

	It touches the Cmdr Registry's internal fields (`Commands` and `CommandsArray`),
	because it has no API to unregister. It only affects this client: the server
	keeps everything registered and validates in BeforeRun.
]=]
function CmdrController:HideInaccessibleCommands(accessible : { [string]: boolean })
	local Registry = self.Cmdr.Registry

	for index = #Registry.CommandsArray, 1, -1 do
		if not accessible[Registry.CommandsArray[index].Name] then
			table.remove(Registry.CommandsArray, index)
		end
	end

	-- `Commands` has one entry per name and per alias, all pointing at the object.
	for key, commandObject in Registry.Commands do
		if not accessible[commandObject.Name] then
			Registry.Commands[key] = nil
		end
	end
end

function CmdrController:start()

end

function CmdrController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return CmdrController
