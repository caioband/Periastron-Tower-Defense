local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local ProximityPanel = require(Util.ProximityPanel)
local UIUtil = require(Util.UIUtil)

local ContractConfig = SharedConfig.ContractConfig
local CrateConfig = SharedConfig.CrateConfig

local Framework = Me.new()
local log = Log.new("ContractController")

local BOARD = ContractConfig.Board

--[[ CONSTANTS ]]

--[=[
	The UI path: `Contracts.Frame.MainBoard.ScrollingFrame`, with a header + frame pair per
	period. The header carries the `Timer`; the frame carries the authored `TaskFrame`,
	which is the **template** for that section's rows: each section has its own art, so
	the template is per section, not a single one.
]=]
local GUI = {
	ScreenGui = "Contracts",
	Wrapper = "Frame",
	Panel = "MainBoard",
	List = "ScrollingFrame",

	Sections = {
		Hourly = { Header = "Hourly", Frame = "HourlyFrame" },
		Daily = { Header = "Daily", Frame = "DailyFrame" },
		Weekly = { Header = "Weekly", Frame = "WeeklyFrame" },
	},

	Timer = "Timer",
	Template = "TaskFrame",
	Task = "Task",
	Claim = "ClaimButton",
	Paper = "TaskPaper",
	Rewards = "RewardsContainer",

	-- The `TaskPaper` stamp, hidden until the slot is claimed.
	Claimed = "Claimed",

	Coin = "CoinAmount",
	CoinText = "CoinAmountText",
	Shard = "ShardAmount",
	ShardText = "ShardAmountText",

	-- The generic text for rewards that are not coins or shards (the crates). One
	-- per crate: the authored one takes the first, and clones of it take the others.
	Other = "OtherReward",
}

--[=[
	The HUD button that takes the player to the board: `HUD.HUDLeft.Wrapper.Contracts`, in
	the left column. The name is looked up by depth inside the column, as in the shops, so
	changing the wrappers in Studio does not break the bind.

	Only the click lives here. The button's grow and sink belong to
	`HUDButtonController`, which animates every `GuiButton` in both columns.
]=]
local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDLeft"
local HUD_BUTTON_NAME = "Contracts"

local CHARACTER_ROOT = "HumanoidRootPart"

local WAIT_TIMEOUT = 10

local ROW_PREFIX = "Contract_"
local OTHER_CLONE_PREFIX = "OtherReward_"

local HIDE_REASON = "Contracts"

local CLAIM_TEXT = "CLAIM"
local CLAIMED_TEXT = "CLAIMED"

-- The button for a slot that cannot be claimed yet (incomplete or already claimed) is
-- dimmed, not hidden: the row's art was drawn with it in place.
local DISABLED_TRANSPARENCY = 0.55

-- The art for a button ready to claim. Otherwise it returns to the authored image
-- on the template's `ClaimButton`.
local CLAIM_READY_IMAGE = "rbxassetid://87113976488534"

-- The claim sound: the shop purchase's `Coins`, in `SoundService.BuySFX`.
local CLAIM_SOUND = "Coins"
local CLAIM_SOUND_KEY = "ContractClaim"

local TIMER_INTERVAL = 1

--[=[
	The Lobby contract board: `StarterGui.Contracts`.

	It opens when the player reaches `Workspace.ContractsBoard.TargetPart` and closes when
	they leave: the same panel as the shops, through `ProximityPanel`.

	**This controller decides nothing.** Contracts, progress, and "already claimed" arrive
	through the profile replica (`Data.Contracts`), and CLAIM only sends "slot N of period
	X". `ContractService` draws, counts, and pays; the button lighting up here is only a
	reading of the same profile, and the server checks again.

	Each section's countdown comes from the server time (`GetServerTimeNow`) and
	`ContractConfig`, not from a number the server sends: rollover is at a fixed hour, and
	both ends reach the same instant without coordinating.

	See docs/common/contracts.md.
]=]
local ContractController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},
		MusicController = {},

		-- The HUD button's `New` badge: the board opening clears it. See
		-- `BeforeOpen` in `construct`.
		HUDBadgeController = {},
	},
}

--[[ INTERNAL ]]

local function formatAmount(value : number) : string
	return UIUtil.formatCommas(math.floor(value))
end

--- The replica's `Contracts`, or nil until it arrives.
function ContractController:_contracts()
	local replica = self.Replica
	local data = replica and replica.Data

	return data and data.Contracts or nil
end

function ContractController:_board() : BasePart?
	local model = workspace:FindFirstChild(BOARD.Model)
	local target = model and model:FindFirstChild(BOARD.Target, true)

	if target and target:IsA("BasePart") then
		return target
	end

	if not self.WarnedBoard then
		self.WarnedBoard = true
		log:StudioWarn(`no {BOARD.Model}.{BOARD.Target} in Workspace -- the board never opens.`)
	end

	return nil
end

--[=[
	Writes the rewards into the row's `RewardsContainer`. Coins and shards are the two
	authored ones, and hide when the contract does not pay that currency; each crate is a
	line of text (`8x Fragmented Crate`), in `CrateConfig` order.
]=]
local function writeRewards(row : Instance, rewards)
	local container = row:FindFirstChild(GUI.Rewards, true)
	if not container then return end

	local coin = container:FindFirstChild(GUI.Coin)
	if coin and coin:IsA("GuiObject") then
		local cash = rewards.Cash or 0
		coin.Visible = cash > 0
		coin.LayoutOrder = 1

		local label = coin:FindFirstChild(GUI.CoinText)
		if label and label:IsA("TextLabel") then
			label.Text = formatAmount(cash)
		end
	end

	local shard = container:FindFirstChild(GUI.Shard)
	if shard and shard:IsA("GuiObject") then
		local shards = rewards.Shards or 0
		shard.Visible = shards > 0
		shard.LayoutOrder = 2

		local label = shard:FindFirstChild(GUI.ShardText)
		if label and label:IsA("TextLabel") then
			label.Text = formatAmount(shards)
		end
	end

	-- The clones from a previous write leave first: the row is reused.
	for _, child in container:GetChildren() do
		if string.sub(child.Name, 1, #OTHER_CLONE_PREFIX) == OTHER_CLONE_PREFIX then
			child:Destroy()
		end
	end

	local other = container:FindFirstChild(GUI.Other)
	if not other or not other:IsA("TextLabel") then return end

	local lines = {}
	for _, tier in CrateConfig.getOrderedRarities() do
		local amount = rewards.Crates and rewards.Crates[tier]
		if amount and amount > 0 then
			local crate = CrateConfig.CRATES[tier]
			table.insert(lines, string.format("%dx %s", amount, crate and crate.DisplayName or tier))
		end
	end

	other.Visible = #lines > 0

	for index, text in lines do
		local label = other
		if index > 1 then
			label = other:Clone()
			label.Name = OTHER_CLONE_PREFIX .. index
			label.Parent = container
		end

		label.Text = text
		label.LayoutOrder = 2 + index
	end
end

--[=[
	The button according to the slot: lit, and with the ready art (`CLAIM_READY_IMAGE`),
	only when it can be claimed. The authored image and transparency are stored the first
	time, so the button can return to them.
]=]
local function writeClaim(entry, complete : boolean, claimed : boolean)
	local button = entry.Claim
	if not button then return end

	local canClaim = complete and not claimed
	button.Active = canClaim
	button.AutoButtonColor = canClaim

	if button:IsA("ImageButton") then
		button.Image = if canClaim then CLAIM_READY_IMAGE else entry.ClaimImageId
		button.ImageTransparency = if canClaim then entry.ClaimImage else DISABLED_TRANSPARENCY
	end

	local label = entry.ClaimLabel
	if label then
		label.Text = if claimed then CLAIMED_TEXT else CLAIM_TEXT
		label.TextTransparency = if canClaim then entry.ClaimText else DISABLED_TRANSPARENCY
	end

	if entry.ClaimedFrame then
		entry.ClaimedFrame.Visible = claimed
	end
end

--[=[
	One row per slot. Rows are clones of the section's template and are reused between
	writes; leftovers (a period with fewer slots, which does not happen today) stay hidden.
]=]
function ContractController:_renderSection(kind : string)
	local section = self.Sections[kind]
	if not section or not section.Template then return end

	local contracts = self:_contracts()
	local bucket = contracts and contracts[kind]
	local slots = bucket and bucket.Slots or {}

	for index, slot in slots do
		local definition = ContractConfig.get(slot.Id)
		local entry = section.Rows[index]

		if not entry then
			local row = section.Template:Clone()
			row.Name = ROW_PREFIX .. index
			row.LayoutOrder = index
			row.Parent = section.Frame

			local claim = row:FindFirstChild(GUI.Claim, true)
			local claimLabel = claim and claim:FindFirstChildWhichIsA("TextLabel")

			-- The stamp lives in `TaskPaper`, but the lookup covers the whole row: each
			-- section nests the paper its own way.
			local claimedFrame = row:FindFirstChild(GUI.Claimed, true)

			entry = {
				Row = row,
				Task = row:FindFirstChild(GUI.Task, true),
				Claim = claim,
				ClaimLabel = claimLabel,
				ClaimedFrame = claimedFrame and claimedFrame:IsA("GuiObject") and claimedFrame or nil,
				ClaimImage = claim and claim:IsA("ImageButton") and claim.ImageTransparency or 0,
				ClaimImageId = claim and claim:IsA("ImageButton") and claim.Image or "",
				ClaimText = claimLabel and claimLabel.TextTransparency or 0,
			}

			if claim and claim:IsA("GuiButton") then
				self.RowMaid:GiveTask(claim.Activated:Connect(function()
					self:_requestClaim(kind, index)
				end))

				ButtonUtil.bindFeedback(claim, self.RowMaid)
			end

			section.Rows[index] = entry
		end

		entry.Row.Visible = definition ~= nil

		if definition then
			if entry.Task and entry.Task:IsA("TextLabel") then
				entry.Task.Text = ContractConfig.describe(definition, slot)
			end

			-- The slot carries the reward when it follows the drawn difficulty.
			writeRewards(entry.Row, slot.Rewards or definition.Rewards or {})
			writeClaim(entry, ContractConfig.isComplete(definition, slot), slot.Claimed == true)
		end
	end

	for index = #slots + 1, #section.Rows do
		section.Rows[index].Row.Visible = false
	end
end

function ContractController:_render()
	for _, kind in ContractConfig.KIND_ORDER do
		self:_renderSection(kind)
	end
end

function ContractController:_updateTimers()
	local now = workspace:GetServerTimeNow()

	for kind, section in self.Sections do
		local label = section.Timer
		if label and label.Parent then
			local period = ContractConfig.periodOf(kind, now)
			label.Text = ContractConfig.formatRemaining(ContractConfig.endsAt(kind, period) - now)
		end
	end
end

--[=[
	The claim request. It only goes out with the button lit, but the server checks
	everything again: what arrives here is a click, not a decision.
]=]
function ContractController:_requestClaim(kind : string, index : number)
	local contracts = self:_contracts()
	local slot = contracts and contracts[kind] and contracts[kind].Slots[index]
	local definition = slot and ContractConfig.get(slot.Id)

	if not definition or slot.Claimed or not ContractConfig.isComplete(definition, slot) then
		return
	end

	Framework:Fire("ClaimContract", kind, index)
end

--[=[
	Opens the tab's reroll prompt, on the product the profile's count calls for
	(`ContractConfig.rerollProduct`).

	The client **opens** the purchase and credits nothing: the receipt rerolls, in
	`ContractService`, and the new tab arrives through the replica. Canceling the prompt
	does nothing. No debounce, like the card shop reroll: `PromptProductPurchase` does not
	stack windows.
]=]
function ContractController:_promptReroll(kind : string)
	local contracts = self:_contracts()
	if not contracts then return end

	local bucket = contracts[kind]
	local productId = ContractConfig.rerollProduct(kind, bucket and bucket.Rerolls)
	if not productId then return end

	MarketplaceService:PromptProductPurchase(Players.LocalPlayer, productId)
end

--[=[
	The content on a new copy of `Contracts`: finds the three sections and takes each one's
	template off the screen. The panel itself (frame, animation, blur, proximity) belongs
	to `ProximityPanel`.
]=]
function ContractController:_onBind(panel : GuiObject)
	local list = panel:WaitForChild(GUI.List, 10)

	if not list then
		log:StudioWarn(`could not find {GUI.ScreenGui}.{GUI.Wrapper}.{GUI.Panel}.{GUI.List}.`)
		return
	end

	self.RowMaid:DoCleaning()
	self.Sections = {}

	for kind, names in GUI.Sections do
		local frame = list:FindFirstChild(names.Frame)
		local header = list:FindFirstChild(names.Header)
		local template = frame and frame:FindFirstChild(GUI.Template)

		if not template then
			log:StudioWarn(`no {names.Frame}.{GUI.Template} in {GUI.List} -- the {kind} section stays empty.`)
		else
			-- The template leaves the screen and stays only as the source for rows.
			template.Parent = nil
		end

		local timer = header and header:FindFirstChild(GUI.Timer)

		-- The header's reroll die. The click lives in `RowMaid`, like the rows':
		-- a new copy of `Contracts` hooks up its own buttons.
		local reroll = header and header:FindFirstChild(ContractConfig.Reroll.Button)
		if reroll and reroll:IsA("GuiButton") then
			self.RowMaid:GiveTask(reroll.Activated:Connect(function()
				self:_promptReroll(kind)
			end))

			ButtonUtil.bindFeedback(reroll, self.RowMaid)
		elseif header then
			log:StudioWarn(`no {ContractConfig.Reroll.Button} in {names.Header} -- the {kind} reroll does nothing.`)
		end

		self.Sections[kind] = {
			Frame = frame,
			Template = template,
			Timer = timer and timer:IsA("TextLabel") and timer or nil,
			Rows = {},
		}
	end

	self:_render()
	self:_updateTimers()
end

--[=[
	Hooks up the HUD button that takes the player to the board.

	Its own maid: `HUD` and `Contracts` are different `ScreenGui`s and the engine rebuilds
	them at different times (the HUD on every respawn), so one's bind must not disconnect
	the other's; `ProximityPanel` follows `Contracts`.
]=]
function ContractController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, WAIT_TIMEOUT)
	local button = hudFrame and UIUtil.waitForDescendant(hudFrame, HUD_BUTTON_NAME, WAIT_TIMEOUT)

	if not button or not button:IsA("GuiButton") then
		if not self.WarnedButton then
			self.WarnedButton = true
			log:StudioWarn(`could not find {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		end

		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:TeleportToBoard()
	end))
end

--- The HUD, through the button that goes to the board.
function ContractController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == HUD_UI_NAME then
			self:_bindHud(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

function ContractController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_render()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and key ~= "Contracts" then
				return
			end

			self:_render()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

function ContractController:_watchTimers()
	local clock = 0

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		clock += deltaTime
		if clock < TIMER_INTERVAL then return end

		clock = 0
		self:_updateTimers()
	end))
end

--[[ EXTERNAL ]]

function ContractController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function ContractController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function ContractController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

function ContractController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

--[=[
	Drops the player on the board's `TargetPart`.

	The client owns its own character, so moving it here is enough: the server sees the
	new position through the usual replication.

	The landing is **inside** the radius, because the landing part is the reference itself.
	Even so the opening is done by hand, through `EnterRange`: the measurement only runs
	every `ProximityInterval`, and this way the board opens with the teleport, with the
	entry marked, so walking away closes it the same way.
]=]
function ContractController:TeleportToBoard() : boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild(CHARACTER_ROOT)

	if not root then
		return false
	end

	local target = self:_board()
	if not target then
		return false
	end

	character:PivotTo(target.CFrame * CFrame.new(0, target.Size.Y / 2 + BOARD.TeleportHeightOffset, 0))

	-- Without this the player keeps the velocity they had and slides off the board.
	root.AssemblyLinearVelocity = Vector3.zero

	if self.Proximity then
		self.Proximity:EnterRange()
	end

	return true
end

function ContractController:construct()
	Framework:Listen("ContractClaimResult", function(_kind, _index, success : boolean, reason : string?)
		if success then
			local music = self.Controllers.MusicController
			if music then
				music:PlaySFX(CLAIM_SOUND, { Key = CLAIM_SOUND_KEY })
			end
		elseif reason then
			log:Debug(`claim refused ({reason}).`)
		end
	end)

	local music = self.Controllers.MusicController
	if music then
		music:PreloadSFX({ CLAIM_SOUND })
	end

	self.Proximity = ProximityPanel.new({
		Name = "ContractController",
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

		OnBind = function(_screenGui, _wrapper, panel)
			self:_onBind(panel)
		end,

		BeforeOpen = function()
			self:_render()
			self:_updateTimers()

			--[[
				The board was read: the "contracts reset" badge ends here. The pending-claim one
				does **not**: that one goes away when the contract is claimed, and the profile
				itself clears it.
			]]
			local badges = self.Controllers.HUDBadgeController
			if badges then
				badges:NoteSeen(HUD_BUTTON_NAME)
			end
		end,
	})

	self.Maid:GiveTask(function()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()

	self:_observeUI()
	self:_watchProfile()
	self:_watchTimers()
end

function ContractController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function ContractController:init()
	self.Maid = Maid.new()

	-- The drawn rows and their clicks, per copy of `Contracts`.
	self.RowMaid = Maid.new()
	self.Maid:GiveTask(self.RowMaid)

	-- [kind] = { Frame, Template, Timer, Rows = { { Row, Task, Claim, ... } } }
	self.Sections = {}

	-- The HUD button's click, which the engine rebuilds on every respawn.
	self.HudMaid = Maid.new()
	self.Maid:GiveTask(self.HudMaid)

	self.Replica = nil
	self.Proximity = nil
	self.WarnedBoard = false
	self.WarnedButton = false
end

return ContractController
