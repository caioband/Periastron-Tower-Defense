local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GroupService = game:GetService("GroupService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Util.Log)

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local ProximityPanel = require(Util.ProximityPanel)
local UIUtil = require(Util.UIUtil)

local CodeConfig = SharedConfig.CodeConfig
local CrateConfig = SharedConfig.CrateConfig

local Framework = Me.new()
local log = Log.new("CodeController")

--[[ CONSTANTS ]]

local GUI = CodeConfig.Gui

local HIDE_REASON = "Codes"

local REQUEST_EVENT = "RedeemCode"
local RESULT_EVENT = "CodeRedeemResult"

-- The `UIScale` the button's hover and press need, created when the button has none.
local PRESS_SCALE_NAME = "PressScale"

--[=[
	The codes panel: `StarterGui.SharedUIs.CodesGUI`, opened by the `Code` button on
	the settings panel (`SettingsController` calls `Open`).

	The panel itself (frame, animation, blur, screen request, the X) belongs to
	`ProximityPanel`, with no map spot, the same as the contracts board and the
	settings panel.

	**This controller decides nothing.** It sends the typed text and shows the
	answer; `CodeService` checks the group, the code, its dates, and whether the
	player redeemed it already, and pays. A `NotInGroup` answer carries the group id,
	and the client opens Roblox's join prompt for it.

	The answer goes on the panel's `Text` line: green with the rewards on success,
	red with the reason on failure. Closing the panel puts the authored line back.

	`Redeem` sits next to the panel art, not inside it, so the Lobby's `OpenShop`
	(which grows only the art) would leave it popping in at full size. The button
	follows the art's `UIScale` and transparency through its `Size` instead, which
	leaves its own `UIScale` free for the hover and press feedback.

	See docs/common/codes.md.
]=]
local CodeController = {
	Controllers = {
		InterfaceController = {},
		MusicController = {},
		RichTextController = {},
	},
}

--[[ INTERNAL ]]

local function escape(text : string) : string
	return (string.gsub(text, "[&<>\"']", {
		["&"] = "&amp;",
		["<"] = "&lt;",
		[">"] = "&gt;",
		["\""] = "&quot;",
		["'"] = "&apos;",
	}))
end

local function colored(color : string, text : string) : string
	return `<font color="{color}">{escape(text)}</font>`
end

--- The rewards as one RichText line: coins, shards, then crates in tier order.
local function describeRewards(rewards) : string
	local parts = {}
	local colors = CodeConfig.REWARD_COLORS

	local cash = rewards and rewards.Cash or 0
	if cash > 0 then
		table.insert(parts, colored(colors.Cash, `+{UIUtil.formatCommas(cash)} Coins`))
	end

	local shards = rewards and rewards.Shards or 0
	if shards > 0 then
		table.insert(parts, colored(colors.Shards, `+{UIUtil.formatCommas(shards)} Shards`))
	end

	local crates = rewards and rewards.Crates
	if crates then
		for _, tier in CrateConfig.getOrderedRarities() do
			local amount = crates[tier]
			if amount and amount > 0 then
				local crate = CrateConfig.CRATES[tier]
				table.insert(parts, colored(colors.Crates, `{amount}x {crate and crate.DisplayName or tier}`))
			end
		end
	end

	return table.concat(parts, "  ")
end

--- Writes the feedback line. `color` nil puts the authored line back.
function CodeController:_setFeedback(text : string?, color : Color3?)
	local feedback = self.Feedback
	if not feedback or not feedback.Parent then
		return
	end

	feedback.Text = text or self.FeedbackText
	feedback.TextColor3 = color or self.FeedbackColor
end

function CodeController:_showError(reason : string?, minLevel : number?)
	local message = CodeConfig.Messages[reason or "Unknown"] or CodeConfig.Messages.Unknown
	if reason == "LowLevel" then
		message = string.format(message, if typeof(minLevel) == "number" then tostring(minLevel) else "?")
	end

	self:_setFeedback(escape(message), CodeConfig.ERROR_COLOR)
end

function CodeController:_showSuccess(rewards)
	local line = describeRewards(rewards)
	local text = escape(CodeConfig.SUCCESS_TITLE)

	if line ~= "" then
		text ..= "<br/>" .. line
	end

	self:_setFeedback(text, CodeConfig.SUCCESS_COLOR)
end

--[=[
	Roblox's own join prompt for the group. It yields until the player answers, so it
	runs on its own thread; the feedback line already says why it showed up.
]=]
local function promptGroup(groupId : number)
	task.spawn(function()
		local ok, err = pcall(GroupService.PromptJoinAsync, GroupService, groupId)
		if not ok then
			log:StudioWarn(`could not open the join prompt for group {groupId}: {err}`)
		end
	end)
end

function CodeController:_submit()
	local input = self.Input
	if not input or not input.Parent then
		return
	end

	local text = string.gsub(input.Text, "^%s*(.-)%s*$", "%1")
	if text == "" then
		self:_showError("Empty")
		return
	end

	if self.Pending then
		self:_showError("Busy")
		return
	end

	local now = os.clock()
	if self.LastSent and now - self.LastSent < CodeConfig.CLIENT_COOLDOWN then
		self:_showError("Cooldown")
		return
	end

	self.LastSent = now
	self.RequestId += 1

	local requestId = self.RequestId
	self.Pending = requestId

	-- Frees the button if the answer never comes (the server dropped the request).
	task.delay(CodeConfig.REQUEST_TIMEOUT, function()
		if self.Pending == requestId then
			self.Pending = nil
			self:_showError("Timeout")
		end
	end)

	Framework:Fire(REQUEST_EVENT, requestId, text)
end

function CodeController:_onResult(payload : any)
	if typeof(payload) ~= "table" or payload.Id ~= self.Pending then
		return
	end

	self.Pending = nil

	if payload.Success then
		self:_showSuccess(payload.Rewards)

		if self.Input and self.Input.Parent then
			self.Input.Text = ""
		end

		local music = self.Controllers.MusicController
		if music then
			music:PlaySFX(CodeConfig.SUCCESS_SOUND, { Key = CodeConfig.SUCCESS_SOUND_KEY })
		end

		return
	end

	self:_showError(payload.Reason, payload.MinLevel)

	if payload.Reason == "NotInGroup" and typeof(payload.GroupId) == "number" then
		promptGroup(payload.GroupId)
	end
end

--[=[
	`Redeem` follows the panel art: its `Size` scales with the art's `UIScale` and
	its image fades with the art's `ImageTransparency`. In a place without Cascade
	the whole frame scales instead, the art has no `UIScale`, and nothing is needed.
]=]
local function followPanel(panel : GuiObject, redeem : GuiObject, maid : any)
	local panelScale = panel:FindFirstChildWhichIsA("UIScale")
	if not panelScale then
		return
	end

	local baseSize = redeem.Size

	local function applyScale()
		local scale = panelScale.Scale
		redeem.Size = UDim2.new(
			baseSize.X.Scale * scale, baseSize.X.Offset * scale,
			baseSize.Y.Scale * scale, baseSize.Y.Offset * scale
		)
	end

	maid:GiveTask(panelScale:GetPropertyChangedSignal("Scale"):Connect(applyScale))
	applyScale()

	if not panel:IsA("ImageLabel") or not redeem:IsA("ImageButton") then
		return
	end

	local panelBase = panel.ImageTransparency
	local redeemBase = redeem.ImageTransparency

	local function applyFade()
		local fade = math.clamp((panel.ImageTransparency - panelBase) / math.max(1 - panelBase, 1e-3), 0, 1)
		redeem.ImageTransparency = redeemBase + (1 - redeemBase) * fade
	end

	maid:GiveTask(panel:GetPropertyChangedSignal("ImageTransparency"):Connect(applyFade))
	applyFade()
end

--[=[
	The gold `REDEEM`, written once per copy of the screen, the first time it opens:
	the renderer draws nothing in a box that measures zero, and a closed panel does.
	After that the renderer resizes the text with the box on its own.
]=]
function CodeController:_writeRedeemLabel()
	local label = self.RedeemLabel
	if self.RedeemWritten or not label or not label.Parent then
		return
	end

	self.RedeemWritten = true

	local rich = self.Controllers.RichTextController
	if not rich then
		return
	end

	-- `Fit` yields until the box stops changing size (the end of the open animation).
	task.spawn(function()
		rich:Write(label, CodeConfig.REDEEM_MARKUP, CodeConfig.REDEEM_TEXT_OPTIONS)
	end)
end

--- The content on a new copy of `CodesGUI`.
function CodeController:_onBind(wrapper : GuiObject, panel : GuiObject, maid : any)
	self.Pending = nil
	self.RedeemWritten = false

	local feedback = panel:FindFirstChild(GUI.Feedback)
	if feedback and feedback:IsA("TextLabel") then
		feedback.RichText = true

		self.Feedback = feedback
		self.FeedbackText = feedback.Text
		self.FeedbackColor = feedback.TextColor3
	else
		self.Feedback = nil
		log:StudioWarn(`no {GUI.Panel}.{GUI.Feedback} label in {GUI.ScreenGui} -- redemptions show no feedback.`)
	end

	local input = panel:FindFirstChild(GUI.Input, true)
	if input and input:IsA("TextBox") then
		self.Input = input

		maid:GiveTask(input.FocusLost:Connect(function(enterPressed : boolean)
			if enterPressed then
				self:_submit()
			end
		end))
	else
		self.Input = nil
		log:StudioWarn(`no {GUI.Input} in {GUI.ScreenGui}.{GUI.Wrapper}.{GUI.Panel} -- codes cannot be typed.`)
	end

	local redeem = wrapper:FindFirstChild(GUI.Redeem)
	if not redeem or not redeem:IsA("GuiButton") then
		self.RedeemLabel = nil
		log:StudioWarn(`no {GUI.Wrapper}.{GUI.Redeem} button in {GUI.ScreenGui} -- only Enter redeems.`)
		return
	end

	local label = redeem:FindFirstChild(GUI.RedeemLabel)
	self.RedeemLabel = if label and label:IsA("GuiObject") then label else nil

	if not self.RedeemLabel then
		log:StudioWarn(`no {GUI.Redeem}.{GUI.RedeemLabel} in {GUI.ScreenGui} -- the button has no text.`)
	end

	followPanel(panel, redeem, maid)

	if not redeem:FindFirstChildWhichIsA("UIScale") then
		local scale = Instance.new("UIScale")
		scale.Name = PRESS_SCALE_NAME
		scale.Parent = redeem
	end

	ButtonUtil.bindFeedback(redeem, maid)

	maid:GiveTask(redeem.Activated:Connect(function()
		local music = self.Controllers.MusicController
		if music then
			music:PlaySFX(CodeConfig.CLICK_SOUND)
		end

		self:_submit()
	end))
end

--[[ EXTERNAL ]]

function CodeController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function CodeController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function CodeController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

function CodeController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

function CodeController:construct()
	Framework:Listen(RESULT_EVENT, function(payload : any)
		self:_onResult(payload)
	end)

	local music = self.Controllers.MusicController
	if music then
		music:PreloadSFX({ CodeConfig.SUCCESS_SOUND })
	end

	self.Proximity = ProximityPanel.new({
		Name = "CodeController",
		Folder = GUI.Folder,
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = CodeConfig.OPEN_ANIMATION,
		HideReason = HIDE_REASON,
		InterfaceController = self.Controllers.InterfaceController,

		OnBind = function(_screenGui, wrapper, panel, maid)
			self:_onBind(wrapper, panel, maid)
		end,

		BeforeOpen = function()
			self:_writeRedeemLabel()
		end,
	})

	-- Closing puts the authored line back and empties the box.
	local connection = self.Proximity.Signals.OpenChanged:Connect(function(isOpen : boolean)
		if isOpen then
			return
		end

		self:_setFeedback(nil, nil)

		if self.Input and self.Input.Parent then
			self.Input.Text = ""
		end
	end)

	self.Maid:GiveTask(function()
		connection:Disconnect()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()
end

function CodeController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function CodeController:init()
	self.Maid = Maid.new()

	self.Proximity = nil

	-- The current copy of the screen.
	self.Feedback = nil
	self.FeedbackText = ""
	self.FeedbackColor = Color3.new(1, 1, 1)
	self.Input = nil
	self.RedeemLabel = nil
	self.RedeemWritten = false

	-- The request waiting for an answer, and the counter that names them.
	self.Pending = nil
	self.RequestId = 0
	self.LastSent = nil
end

return CodeController
