local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.TutorialConfig

--[[
	The tutorial offer on screen.

	The server sends `TutorialPrompt` to players with `Tutorial = false` in their
	profile (see `TutorialService`); the dialog comes from here, through the usual
	box:

		Hello, {name in an orange gradient}, welcome to Periastron Tower Defense
		Would you like to play a Tutorial?

	The second sentence finishes and only then do the two buttons appear: the choice
	comes after the question, not during it. While they are up, clicking empty space
	does not close the box: the answer belongs to the buttons.

	**What happens next is up to subscribers.** The controller answers the server
	(`TutorialAnswered`) and calls whoever subscribed:

		local Tutorial = Framework:Get("TutorialController")

		Tutorial:OnAnswer(function(accepted)
			if accepted then
				Camera:LookAtShop()
			end
		end)

	The tutorial itself runs from the server (`TutorialService:Start` and the
	tutorial match); client-side reactions hang off this hook, and this dialog does
	not change.

	**The controller does not write the profile.** The server does: declining writes
	`Tutorial = true` right away, and accepting sets it when the tutorial match is
	won.

	It lives in `common/` because the controller is the same in both places: the
	server decides the offer only makes sense in the Lobby.

	See docs/common/tutorial.md.
]]

local TutorialController = {
	Controllers = {
		DialogController = {},
		RichTextController = {},
	}
}

TutorialController.Listeners = {}

-- One offer at a time: the entrance's `task.delay` only applies if nobody has
-- answered (or asked for another) while it waited.
TutorialController.Session = 0

--[[ INTERNAL ]]

--[=[
	The sentences with the player's name inside.

	The name goes through `:Escape()` because it is text the player chose: a bracket
	in the name must not become markup, and a `<` must not eat the rest of the
	greeting.
]=]
function TutorialController:lines() : { string }
	local name = self.Controllers.RichTextController:Escape(Player.DisplayName)

	local lines = {}
	for index, line in Config.Lines do
		lines[index] = string.format(line, name)
	end

	return lines
end

--[=[
	The answer: tells the server, calls subscribers, and closes the box.

	It closes **after** telling, not before, so a subscriber can open another dialog
	on top without it being erased by this one closing.
]=]
function TutorialController:answer(accepted : boolean)
	self.Session += 1

	Framework:Fire("TutorialAnswered", accepted)

	for _, listener in self.Listeners do
		task.spawn(listener, accepted)
	end

	self.Controllers.DialogController:Close()
end

--[[ API ]]

--[=[
	Puts the offer on screen now. The server calls this through `TutorialPrompt`, and
	Cmdr's `tutorial` goes through the same path.

	Returns `false` when the dialog box does not exist in this place.
]=]
function TutorialController:Prompt() : boolean
	local dialog = self.Controllers.DialogController

	self.Session += 1
	local session = self.Session

	local buttons = {}
	buttons[Config.Buttons.AcceptIndex] = {
		Text = Config.Buttons.AcceptText,
		Font = Config.Font,
		OnClick = function()
			if self.Session ~= session then return end

			self:answer(true)
		end,
	}
	buttons[Config.Buttons.DeclineIndex] = {
		Text = Config.Buttons.DeclineText,
		Font = Config.Font,
		OnClick = function()
			if self.Session ~= session then return end

			self:answer(false)
		end,
	}

	return dialog:Play(self:lines(), Config.Speech({
		Buttons = buttons,
		ButtonsAtEnd = true,
	}))
end

--[=[
	Calls back with the player's answer (`true` accepted, `false` declined). Returns
	the unsubscribe function.

	It is the hook for a camera, a sound, whatever comes after the question.
]=]
function TutorialController:OnAnswer(callback : (accepted : boolean) -> ()) : () -> ()
	table.insert(self.Listeners, callback)

	return function()
		local index = table.find(self.Listeners, callback)
		if index then
			table.remove(self.Listeners, index)
		end
	end
end

--[[ LIFECYCLE ]]

function TutorialController:construct()
	Framework:Listen("TutorialPrompt", function()
		local session = self.Session

		-- The player just landed in the Lobby: UI is loading, the intro and camera are
		-- running. Talking over that is the same as not talking.
		task.delay(Config.PromptDelay, function()
			if self.Session ~= session then return end

			self:Prompt()
		end)
	end)
end

function TutorialController:start()
end

function TutorialController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return TutorialController
