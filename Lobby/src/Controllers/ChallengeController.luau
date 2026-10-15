local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Util:WaitForChild("Log"))

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local ProximityPanel = require(Util.ProximityPanel)

local ChallengeConfig = SharedConfig.ChallengeConfig
local MapConfig = SharedConfig.MapConfig
local CardConfig = SharedConfig.CardConfig
local UnlockConfig = SharedConfig.DifficultyUnlockConfig

local Framework = Me.new()
local log = Log.new("ChallengeController")

--[[ CONSTANTS ]]

local GUI = {
	ScreenGui = "Challenges",
	Wrapper = "Frame",
	Panel = "MainBoard",
	Templates = "Templates",

	Scrolls = {
		Daily = "DailyScroll",
		Weekly = "WeeklyScroll",
	},

	Card = "Card",
	Map = "Map",
	MapImage = "MapImage",
	MapName = "MapName",
	Bans = "Bans",
	SlotPrefix = "Slot",
	Icon = "Icon",
	Cross = "Cross",
	Gamemode = "Gamemode",
	Play = "Play",
	PlayText = "Text",
}

--[=[
	The board on the Lobby map: `Workspace.WeeklyChallenges.TargetPart` is the center
	of the radius that opens the board, the same as `ContractsBoard`.
]=]
local BOARD = {
	Model = "WeeklyChallenges",
	Target = "TargetPart",
	OpenRadius = 6,
	ProximityInterval = 0.2,
	Animation = "OpenShop",
}

local HIDE_REASON = "Challenges"

local CARD_PREFIX = "Challenge_"

local PLAY_TEXT = "PLAY"
local DONE_TEXT = "DONE"
local LOCKED_TEXT = "LOCKED"

-- What the Play button says for a refused request, for a few seconds.
local REASON_TEXT = {
	Cooldown = "WAIT",
	NotLoaded = "WAIT",
	InGroup = "IN PORTAL",
	Tutorial = "TUTORIAL",
	DifficultyLocked = "LOCKED",
	AllBanned = "NO UNITS",
	TeleportFailed = "FAILED",
	Invalid = "EXPIRED",
}

local REASON_HOLD = 2.5
local LOCKED_TRANSPARENCY = 0.45
local PERIOD_CHECK_INTERVAL = 1

--[=[
	The Lobby challenge board: `StarterGui.Challenges`.

	It opens at the `WeeklyChallenges` model through `ProximityPanel`, like the
	contracts board. Cards are cloned from `Challenges.Templates.Daily/Weekly`, one
	per slot, into each scroll; the authored preview cards are removed on bind.

	**This controller decides nothing.** The challenges themselves come from
	`ChallengeConfig` (the same generation the server runs), completion comes from
	the profile replica (`Data.Challenges`), and Play only sends "kind, slot":
	`ChallengeService` checks everything again and teleports.

	A rollover while the board exists rebuilds the cards for the new period.
]=]
local ChallengeController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},
	},
}

--[[ INTERNAL ]]

function ChallengeController:_board() : BasePart?
	local model = workspace:FindFirstChild(BOARD.Model)
	local target = model and model:FindFirstChild(BOARD.Target)

	if target and target:IsA("BasePart") then
		return target
	end

	if not self.WarnedBoard then
		self.WarnedBoard = true
		log:StudioWarn(`could not find Workspace.{BOARD.Model}.{BOARD.Target}.`)
	end

	return nil
end

function ChallengeController:_data() : any
	local replica = self.Replica
	return replica and replica.Data or nil
end

local function setText(label : Instance?, text : string)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

--[=[
	Removes the authored preview cards and clones one card per slot for each kind.
	Runs on bind and on rollover.
]=]
function ChallengeController:_build()
	self.CardMaid:DoCleaning()
	self.Cards = {}
	self.Periods = {}

	local panel, templates = self.Panel, self.Templates
	if not panel or not panel.Parent or not templates then
		return
	end

	for kind, scrollName in GUI.Scrolls do
		local scroll = panel:FindFirstChild(scrollName)
		local template = templates:FindFirstChild(kind)

		if not scroll or not template then
			log:StudioWarn(`missing {GUI.Panel}.{scrollName} or {GUI.Templates}.{kind}; the {kind} section stays empty.`)
			continue
		end

		for _, child in scroll:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		local period = ChallengeConfig.currentPeriod(kind)
		local challenges = ChallengeConfig.generate(kind, period)

		self.Periods[kind] = period

		for _, challenge in challenges do
			local card = template:Clone()
			card.Name = `{CARD_PREFIX}{kind}{challenge.Slot}`
			card.LayoutOrder = challenge.Slot
			card.Visible = true
			card.Parent = scroll

			self.CardMaid:GiveTask(card)

			local body = card:FindFirstChild(GUI.Card)
			local play = body and body:FindFirstChild(GUI.Play)

			if play and play:IsA("GuiButton") then
				self.CardMaid:GiveTask(play.Activated:Connect(function()
					self:_requestPlay(kind, challenge.Slot)
				end))

				ButtonUtil.bindFeedback(play, self.CardMaid)
			end

			table.insert(self.Cards, {
				Kind = kind,
				Challenge = challenge,
				Card = card,
				Body = body,
				Play = play,
			})
		end

		if scroll:IsA("ScrollingFrame") then
			scroll.CanvasSize = UDim2.fromScale(math.max(#challenges, 1), 0)
			scroll.CanvasPosition = Vector2.zero
		end
	end

	self:_render()
end

function ChallengeController:_renderCard(entry)
	local challenge = entry.Challenge
	local body = entry.Body
	if not body then
		return
	end

	local map = body:FindFirstChild(GUI.Map)
	if map then
		local image = map:FindFirstChild(GUI.MapImage)
		if image and image:IsA("ImageLabel") then
			image.Image = MapConfig.getImage(challenge.Map)
		end

		local info = MapConfig.MAPS[challenge.Map]
		setText(map:FindFirstChild(GUI.MapName), string.upper(info and info.DisplayName or challenge.Map))
	end

	local bans = body:FindFirstChild(GUI.Bans)
	if bans then
		local index = 1

		while true do
			local slot = bans:FindFirstChild(GUI.SlotPrefix .. index)
			if not slot then
				break
			end

			local unitName = challenge.Bans[index]
			slot.Visible = unitName ~= nil

			if unitName then
				local icon = slot:FindFirstChild(GUI.Icon)
				if icon and icon:IsA("ImageLabel") then
					icon.Image = CardConfig.GetIcon(unitName) or CardConfig.GetImage(unitName) or ""
				end

				local cross = slot:FindFirstChild(GUI.Cross)
				if cross and cross:IsA("GuiObject") then
					cross.Visible = true
				end
			end

			index += 1
		end
	end

	local mode = string.upper(challenge.Difficulty)
	local modifiers = ChallengeConfig.modifierNames(challenge)
	if #modifiers > 0 then
		mode = `{mode} + {table.concat(modifiers, " + ")}`
	end

	setText(body:FindFirstChild(GUI.Gamemode), mode)

	local play = entry.Play
	if not play then
		return
	end

	local data = self:_data()
	local done = ChallengeConfig.isCompleted(data and data[ChallengeConfig.DATA_KEY], challenge)
	local unlocked = UnlockConfig.isUnlocked(challenge.Difficulty, data and data.Stats)

	local text = if not unlocked then LOCKED_TEXT elseif done then DONE_TEXT else PLAY_TEXT

	local reason = self.Reasons[challenge.Id]
	if reason and os.clock() < reason.Until then
		text = reason.Text
	end

	setText(play:FindFirstChild(GUI.PlayText), text)

	if play:IsA("ImageButton") then
		play.ImageTransparency = if unlocked then 0 else LOCKED_TRANSPARENCY
	end
end

function ChallengeController:_render()
	for _, entry in self.Cards do
		self:_renderCard(entry)
	end
end

function ChallengeController:_requestPlay(kind : string, slot : number)
	Framework:Fire("RequestPlayChallenge", kind, slot)
end

--- Rebuilds the cards when a kind rolled over to a new period.
function ChallengeController:_checkRollover()
	for kind, period in self.Periods do
		if ChallengeConfig.currentPeriod(kind) ~= period then
			self:_build()
			return
		end
	end

	-- Expired refusal texts go back to PLAY / DONE.
	local now = os.clock()
	for id, reason in self.Reasons do
		if now >= reason.Until then
			self.Reasons[id] = nil
			self:_render()
			break
		end
	end
end

function ChallengeController:_onBind(screenGui : ScreenGui, panel : GuiObject)
	self.Panel = panel
	self.Templates = screenGui:FindFirstChild(GUI.Templates)

	if not self.Templates then
		log:StudioWarn(`could not find {GUI.ScreenGui}.{GUI.Templates}.`)
	end

	self:_build()
end

function ChallengeController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_render()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and key ~= ChallengeConfig.DATA_KEY and key ~= "Stats" then
				return
			end

			self:_render()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

function ChallengeController:_watchRollover()
	local clock = 0

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		clock += deltaTime
		if clock < PERIOD_CHECK_INTERVAL then return end

		clock = 0
		self:_checkRollover()
	end))
end

--[[ EXTERNAL ]]

function ChallengeController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function ChallengeController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function ChallengeController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

function ChallengeController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

function ChallengeController:construct()
	Framework:Listen("ChallengePlayResult", function(kind : any, slot : any, ok : boolean, reason : string?)
		if ok or not ChallengeConfig.isKind(kind) then
			return
		end

		local challenge = ChallengeConfig.get(kind, ChallengeConfig.currentPeriod(kind), slot)
		if not challenge then
			return
		end

		self.Reasons[challenge.Id] = {
			Text = REASON_TEXT[reason or ""] or "FAILED",
			Until = os.clock() + REASON_HOLD,
		}

		self:_render()
	end)

	self.Proximity = ProximityPanel.new({
		Name = "ChallengeController",
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = BOARD.Animation,
		HideReason = HIDE_REASON,
		GetReference = function()
			local target = self:_board()
			return target and target.Position or nil
		end,
		Radius = BOARD.OpenRadius,
		Interval = BOARD.ProximityInterval,
		InterfaceController = self.Controllers.InterfaceController,

		OnBind = function(screenGui, _wrapper, panel)
			self:_onBind(screenGui, panel)
		end,

		BeforeOpen = function()
			self:_checkRollover()
			self:_render()
		end,
	})

	self.Maid:GiveTask(function()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()

	self:_watchProfile()
	self:_watchRollover()
end

function ChallengeController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function ChallengeController:init()
	self.Maid = Maid.new()

	-- The cloned cards and their clicks, rebuilt on bind and rollover.
	self.CardMaid = Maid.new()
	self.Maid:GiveTask(self.CardMaid)

	-- { { Kind, Challenge, Card, Body, Play } }
	self.Cards = {}

	-- [kind] = the period the cards were built for.
	self.Periods = {}

	-- [challenge Id] = { Text, Until }: a refused Play, shown briefly on the button.
	self.Reasons = {}

	self.Panel = nil
	self.Templates = nil
	self.Replica = nil
	self.Proximity = nil
	self.WarnedBoard = false
end

return ChallengeController