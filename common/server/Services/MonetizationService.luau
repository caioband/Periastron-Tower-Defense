local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local MarketplaceService = game:GetService("MarketplaceService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local ServerVendor = ServerScriptService:WaitForChild("Vendor")
local ServerConfigs = ServerScriptService:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local GamepassConfig = SharedConfig.GamepassConfig

local Framework = Me.new()
local log = Log.new("MonetizationService")

--[[
	Purchases and gamepasses.

	The two halves do not look alike: a developer product purchase is an **event**
	that must be credited exactly once (`ProcessReceipt` and `PurchaseHistory` handle
	that), and a gamepass is a **state** the player has or does not have today.

	So a pass never becomes a credit on the profile. What is stored in
	`Data.Gamepasses` is a copy of what Roblox answered, fully rewritten on every
	join: readers do not need to ask again, and a refunded pass disappears on its own
	at the next login instead of leaving an orphaned benefit. The functions in
	`SharedConfig.GamepassConfig` consume it, on both sides, always from the profile.

	See docs/common/gamepasses.md.
]]
local MonetizationService = {
	Services = {
		DataService = {},
	}
}

function MonetizationService:construct()
	--[[
		`or {}` and not `= {}`: services' `start()` calls are `task.spawn`ed in a loop,
		with no guaranteed order, so a service that registers a product in its
		`start()` may get here first. Resetting the table would erase its callback,
		and the purchase would have no one to credit it: a symptom that only shows up
		with real Robux.
	]]
	self.Callbacks = self.Callbacks or {}

	self:_watchPasses()

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not player then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local profileLoaded = false
		self.Services.DataService:Get(player, function()
			profileLoaded = true
		end)
		if not profileLoaded then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local purchaseKey = "P_" .. tostring(receiptInfo.PurchaseId)

		local alreadyGranted = false
		self.Services.DataService:Update(player, "PurchaseHistory", function(history)
			history = history or {}
			alreadyGranted = history[purchaseKey] == true
			return history
		end)
		if alreadyGranted then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		local callback = self.Callbacks[tostring(receiptInfo.ProductId)]
		if not callback then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local granted = false
		local ok = pcall(function()
			granted = callback(player, receiptInfo) ~= false
		end)
		if not ok or not granted then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		self.Services.DataService:Update(player, "PurchaseHistory", function(history)
			history = history or {}
			history[purchaseKey] = true
			return history
		end)

		if not self.Services.DataService:Save(player) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

--[=[
	Sets who credits a developer product. The callback receives `(player,
	receiptInfo)` and returns `false` when it could **not** credit: then the receipt
	comes back as `NotProcessedYet` and Roblox retries later.

	It can be called before this module's `construct` (see the comment there), so the
	table is created by whoever arrives first.
]=]
function MonetizationService:RegisterProduct(productId, callback)
	self.Callbacks = self.Callbacks or {}
	self.Callbacks[tostring(productId)] = callback
end

function MonetizationService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

--[=[
	What triggers the pass check: each player's join, and buying a pass mid-session.

	`PromptGamePassPurchaseFinished` is what makes the pass apply **right away**.
	Without it, a player would buy 2x Coins and only see the effect at the next
	login, which looks like the purchase did not work, and support answers for that.

	The join check waits for the profile (`DataService:Get`) because it writes to it;
	on its own thread, because these are web calls and nothing else needs to wait
	on them.
]=]
function MonetizationService:_watchPasses()
	local function recalibrate(player : Player)
		self.Services.DataService:Get(player, function()
			task.spawn(function()
				self:RecalibratePasses(player)
			end)
		end)
	end

	for _, player in Players:GetPlayers() do
		recalibrate(player)
	end

	Players.PlayerAdded:Connect(recalibrate)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player : Player, gamePassId : number, purchased : boolean)
		if not purchased or not GamepassConfig.keyOfId(gamePassId) then
			return
		end

		task.spawn(function()
			self:RecalibratePasses(player)
		end)
	end)
end

--[=[
	Asks Roblox about a single pass. Returns `nil`, not `false`, when the call failed.

	The difference matters: `false` is "they do not have it" and removes the benefit;
	`nil` is "could not tell", and `RecalibratePasses` keeps what was already stored.
	An API outage must not take away what the player bought.
]=]
function MonetizationService:_ownsPass(Player : Player, gamePassId : number) : boolean?
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(Player.UserId, gamePassId)
	end)

	if not ok then
		log:Warn(string.format(
			"could not check pass %d for %s (%s); keeping what the profile already says.",
			gamePassId, Player.Name, tostring(owns)))
		return nil
	end

	return owns == true
end

--[=[
	Rewrites `Data.Gamepasses` with what Roblox answers now, and publishes on the
	`Player` the attributes for passes that must be seen by **others**.

	It checks one pass at a time because `UserOwnsGamePassAsync` is one web call per
	pass: there are few, and they run on their own thread (see `construct`), so
	nobody waits on this.

	The attribute exists because the profile only replicates to its owner: the VIP
	tag must appear on their chat message on everyone's screen, and a `Player`
	attribute replicates to the whole room. The server still writes it; the client
	only reads.
]=]
function MonetizationService:RecalibratePasses(Player : Player)
	local DataService = self.Services.DataService
	if not DataService or not DataService.Update then
		log:Warn("DataService unavailable; passes cannot be checked.")
		return
	end

	--[[
		The answers are gathered **before** `Update`, not inside it: the `Update`
		callback must not yield (two simultaneous writes would see the same starting
		state), and each `UserOwnsGamePassAsync` yields.
	]]
	local answers = {}
	for key, pass in GamepassConfig.PASSES do
		answers[key] = self:_ownsPass(Player, pass.Id)
	end

	-- Each question is a web call, and the player may have left in between: without
	-- this, `Update` would just warn that the profile is gone, one line per leave.
	if not DataService.Profiles or not DataService.Profiles[Player] then
		return
	end

	local owned

	DataService:Update(Player, "Gamepasses", function(current)
		current = typeof(current) == "table" and current or {}
		owned = {}

		for key in GamepassConfig.PASSES do
			local answer = answers[key]

			-- `nil` means "the call failed": what the profile already said stands.
			if answer == nil then
				owned[key] = current[key] == true or nil
			elseif answer then
				owned[key] = true
			end
		end

		return owned
	end)

	if not owned then
		return
	end

	for key, pass in GamepassConfig.PASSES do
		if pass.ChatTag then
			Player:SetAttribute(GamepassConfig.attributeName(key), owned[key] == true)
		end
	end
end

function MonetizationService:init()

end

return MonetizationService
