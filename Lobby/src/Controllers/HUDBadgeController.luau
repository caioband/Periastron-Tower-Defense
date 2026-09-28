local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)

local UIUtil = require(Util.UIUtil)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("HUDBadgeController")

local ContractConfig = SharedConfig.ContractConfig
local RoundCardShopConfig = SharedConfig.RoundCardShopConfig

--[[ CONSTANTS ]]

local HUD_UI_NAME = "HUD"

-- The label name inside each button. It is the same on all: whoever draws a new
-- button with a badge only needs to repeat the name.
local BADGE_NAME = "New"

local WAIT_TIMEOUT = 10

--[[
	How long after the Robux shop is opened its badge comes back.

	It is the only badge that does not respond to a profile fact: it is a reminder, and the
	clock brings it back.
]]
local ROBUX_SECONDS = 300

-- How often the card shop block is checked. The block lasts
-- four hours, so five seconds of delay are noticed by nobody.
local ROTATION_INTERVAL = 5

--[=[
	The five buttons that have a badge, and which column each lives in. `Key` is the
	button's name **and** the badge key: it is what `NoteSeen` receives.

	**`HUDFrame.Shop` is not here on purpose**: the crate shop has no news to announce
	(its shelf is always the same), which is why its button does not even have the `New`
	label drawn.
]=]
local BADGES = {
	{ Key = "Contracts", Column = "HUDLeft" },
	{ Key = "RobuxShop", Column = "HUDLeft" },
	{ Key = "Backpack", Column = "HUDFrame" },
	{ Key = "Deck", Column = "HUDFrame" },
	{ Key = "CardShop", Column = "HUDFrame" },
}

--[=[
	The `New` badges on the buttons in both `StarterGui.HUD` columns.

	Each button has a `New` label inside it, and this controller is the only one that
	writes its `Visible`. One rule per button:

	  - **Contracts**: some contract ready to claim, **or** the contracts reset (one of the
	    periods' `Period` turned over). A pending claim is state, not news: the badge
	    insists until the contract is claimed, even if the player already opened the
	    board. The "reset" clears when the board opens;
	  - **RobuxShop**: comes back five minutes after each opening, and is lit from arrival
	    for a player who has not opened the shop this visit;
	  - **Backpack**: some new crate entered the inventory. Clears when the backpack opens;
	  - **Deck**: some unit the player did not have entered the profile. Clears when the
	    loadout opens;
	  - **CardShop**: the storefront's four-hour block turned over. Clears when the shop
	    opens.

	**Opening the panel clears almost every badge** (`NoteSeen`, called by each panel the
	instant it comes in): the opening has happened, and the player has seen what was new:
	the crate on the shelf, the card in the loadout, the board redrawn, the storefront
	changed. Whatever arrives **after** the look lights up again, through the same
	`OnChange`.

	The exception is the contracts' pending claim: that is state, not news. It insists
	until the contract is claimed, even with the board already opened, and the profile
	clears it.

	**The state belongs to the Lobby visit** and lives only here: none of it goes to the
	profile. Returning from a match is a new visit, and whatever still applies lights up
	again, which is no loss, because the three real sources of news (crate bought, crate
	opened, contract claimed) happen **inside** the Lobby, in front of the player.

	The HUD is `ResetOnSpawn`, so the engine replaces it on every respawn: the bind runs
	again on the new copy and the state is rewritten on it.

	See docs/lobby/hud.md.
]=]
local HUDBadgeController = {
	Controllers = {
		DataController = {},
	},
}

-- `[Key] = that button's New label`, in the current HUD copy.
HUDBadgeController.Labels = {}

--[[ INTERNAL ]]

--- The counts of a profile table (`{ [key] = number }`), copied.
local function countsOf(source : any) : { [string] : number }
	local counts = {}

	if typeof(source) ~= "table" then
		return counts
	end

	for key, value in source do
		local amount = tonumber(value)

		if typeof(key) == "string" and amount then
			counts[key] = amount
		end
	end

	return counts
end

--- Each contract type's `Period`, `{ Hourly|Daily|Weekly = number }`.
local function periodsOf(source : any) : { [string] : number }
	local periods = {}

	if typeof(source) ~= "table" then
		return periods
	end

	for kind, section in source do
		local period = typeof(section) == "table" and tonumber(section.Period)

		if typeof(kind) == "string" and period then
			periods[kind] = period
		end
	end

	return periods
end

--- The replica's `Data`, or nil until it arrives.
function HUDBadgeController:_data() : any
	local replica = self.Replica

	return replica and replica.Data or nil
end

--[=[
	Is some contract ready to claim?

	Read from the profile on every refresh, not stored: it is state, and the claim undoes
	it through the same `OnChange` that would bring any other change.
]=]
function HUDBadgeController:_hasClaimable() : boolean
	local data = self:_data()
	local contracts = data and data.Contracts

	if typeof(contracts) ~= "table" then
		return false
	end

	for _, section in contracts do
		local slots = typeof(section) == "table" and section.Slots

		if typeof(slots) == "table" then
			for _, slot in slots do
				if typeof(slot) == "table" and not slot.Claimed then
					local definition = ContractConfig.get(slot.Id)

					if definition and ContractConfig.isComplete(definition, slot) then
						return true
					end
				end
			end
		end
	end

	return false
end

--- Must this button's badge be lit now?
function HUDBadgeController:_isOn(key : string) : boolean
	if key == "Contracts" then
		return self.ContractsReset or self:_hasClaimable()
	elseif key == "RobuxShop" then
		return self.RobuxDue
	elseif key == "Backpack" then
		return next(self.NewCrates) ~= nil
	elseif key == "Deck" then
		return next(self.NewUnits) ~= nil
	elseif key == "CardShop" then
		return self.CardShopReset
	end

	return false
end

--- Writes the state into the current HUD copy's labels.
function HUDBadgeController:_refresh()
	for key, label in self.Labels do
		label.Visible = self:_isOn(key)
	end
end

--[=[
	Binds to a HUD copy: finds the five labels and writes the state into them.

	A button missing from that copy is just left out; the others keep working. The warning
	is per key, not per copy: the HUD is born again on every respawn and the output would
	fill up.
]=]
function HUDBadgeController:_bindHud(screenGui : ScreenGui)
	--[[
		The current copy. The lookups below wait, and respawn may replace the HUD in the
		middle of them: one returning from an old copy checks the number before writing,
		instead of storing a label that already went to the garbage.
	]]
	self.HudToken += 1
	local token = self.HudToken

	self.Labels = {}

	for _, entry in BADGES do
		task.spawn(function()
			local column = screenGui:WaitForChild(entry.Column, WAIT_TIMEOUT)
			if not column then
				self:_warnOnce(entry.Key, `could not find {HUD_UI_NAME}.{entry.Column}`)

				return
			end

			--[[
				The button is inside a `Wrapper`, and `WaitForChild` only looks at direct
				children: it is the same `waitForDescendant` the panel controllers use to find
				their button, and for the same reason: changing the wrappers in Studio must not
				break the bind.
			]]
			local button = UIUtil.waitForDescendant(column, entry.Key, WAIT_TIMEOUT)
			if not button or not button:IsA("GuiButton") then
				self:_warnOnce(entry.Key, `could not find button {entry.Key} in {entry.Column}`)

				return
			end

			local label = button:WaitForChild(BADGE_NAME, WAIT_TIMEOUT)
			if not label or not label:IsA("GuiObject") then
				self:_warnOnce(entry.Key, `button {entry.Key} has no {BADGE_NAME} label`)

				return
			end

			if self.HudToken ~= token then return end

			self.Labels[entry.Key] = label
			label.Visible = self:_isOn(entry.Key)
		end)
	end
end

function HUDBadgeController:_warnOnce(key : string, message : string)
	if self.Warned[key] then return end

	self.Warned[key] = true
	log:StudioWarn(`{message}; that badge will not light up.`)
end

function HUDBadgeController:_observeUI()
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

--[=[
	The profile snapshot on arrival.

	**Nothing the player already has is news**: the badge is about what changed while they
	are here. That is why the snapshot is taken before the first `OnChange` arrives, and
	comparisons are always against it.
]=]
function HUDBadgeController:_snapshot()
	local data = self:_data()

	self.Crates = countsOf(data and data.Inventory and data.Inventory.Crates)
	self.Units = countsOf(data and data.Units)
	self.Periods = periodsOf(data and data.Contracts)
end

--[=[
	The profile changed: what went up lights a badge, what was spent clears it.

	A single pass, and no question about **which** path changed: the replica's `OnChange`
	arrives for any write, and comparing the whole profile with the snapshot is cheaper
	than matching a path per source, and does not miss a write that comes by a path other
	than the expected one.
]=]
function HUDBadgeController:_onProfileChanged()
	local data = self:_data()
	if not data then return end

	--[[
		A crate that came in is news; a rarity's crate that ran out leaves the count, or the
		badge would insist on a crate that is no longer there. Both come from the same
		comparison because they are the same math in opposite directions.

		What really clears the badge is the backpack opening (`NoteSeen`); this only avoids
		leaving orphaned news behind.
	]]
	local crates = countsOf(data.Inventory and data.Inventory.Crates)
	for rarity, amount in crates do
		local before = self.Crates[rarity] or 0

		if amount > before then
			self.NewCrates[rarity] = true
		elseif amount < before then
			self.NewCrates[rarity] = nil
		end
	end
	self.Crates = crates

	--[[
		Only a unit they **did not have** counts: the third Slasher from a crate changes
		nothing in the loadout they already know.
	]]
	local units = countsOf(data.Units)
	for name, amount in units do
		if amount > 0 and (self.Units[name] or 0) <= 0 then
			self.NewUnits[name] = true
		end
	end
	self.Units = units

	--[[
		The contracts' period turned over: the board has new contracts. It is the profile's
		`Period`, not the clock, because what matters is the draw **already saved**: a badge
		lit on a board that has not changed yet would send the player to a board identical to
		the one they saw.
	]]
	local periods = periodsOf(data.Contracts)
	for kind, period in periods do
		local before = self.Periods[kind]

		if before ~= nil and period ~= before then
			self.ContractsReset = true
		end
	end
	self.Periods = periods

	self:_refresh()
end

function HUDBadgeController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_snapshot()
		self:_refresh()

		local connection = replica:OnChange(function()
			self:_onProfileChanged()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[=[
	The card storefront block turning over.

	The block is clock math (`RoundCardShopConfig.rotationIndex`), so checking the number
	here avoids depending on the stock the server sends: the badge is about the storefront
	having changed, and it changes at the same time for everyone.
]=]
function HUDBadgeController:_watchRotation()
	self.Rotation = RoundCardShopConfig.rotationIndex()

	local clock = 0

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		clock += deltaTime
		if clock < ROTATION_INTERVAL then return end

		clock = 0

		local index = RoundCardShopConfig.rotationIndex()
		if index == self.Rotation then return end

		self.Rotation = index
		self.CardShopReset = true

		self:_refresh()
	end))
end

--[[ EXTERNAL ]]

--[=[
	This button's panel was opened.

	Each of the five panels calls it the instant it opens: `BeforeOpen` in the three that
	are `ProximityPanel`s, `_setOpen` in the backpack and the loadout, which open through
	their own button. Opening is what clears the badge: the player already saw the news,
	and insisting after that only teaches them to ignore the red dot.

	Whatever **comes in after** the look lights up again on its own: the backpack and
	loadout news are reset here, not turned off, so the next crate or the next unit
	restores the badge through the same `OnChange` that lit it the first time.
]=]
function HUDBadgeController:NoteSeen(key : string)
	if key == "Contracts" then
		-- A pending claim is not cleared by being seen: it goes away when the contract
		-- is claimed, through the profile itself.
		self.ContractsReset = false
	elseif key == "Backpack" then
		table.clear(self.NewCrates)
	elseif key == "Deck" then
		table.clear(self.NewUnits)
	elseif key == "CardShop" then
		self.CardShopReset = false
	elseif key == "RobuxShop" then
		self.RobuxDue = false

		-- The token kills the previous opening's deadline: someone who opens twice in a minute
		-- waits five minutes from the **last** one, and does not see the badge come back midway.
		self.RobuxToken += 1
		local token = self.RobuxToken

		task.delay(ROBUX_SECONDS, function()
			if self.RobuxToken ~= token then return end

			self.RobuxDue = true

			self:_refresh()
		end)
	else
		return
	end

	self:_refresh()
end

function HUDBadgeController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:_observeUI()
	self:_watchProfile()
	self:_watchRotation()
end

function HUDBadgeController:init()
	self.Maid = Maid.new()

	-- Goes up on every HUD copy. See `_bindHud`.
	self.HudToken = 0

	self.Replica = nil

	-- The profile snapshot on arrival: nothing already here is news.
	self.Crates = {}
	self.Units = {}
	self.Periods = {}

	-- The current news, by rarity and by unit.
	self.NewCrates = {}
	self.NewUnits = {}

	self.ContractsReset = false
	self.CardShopReset = false

	-- The Robux shop starts lit: someone who just arrived has not opened it this visit.
	self.RobuxDue = true
	self.RobuxToken = 0

	self.Rotation = nil

	-- The missing-piece warning is per key, not per HUD copy.
	self.Warned = {}
end

return HUDBadgeController
