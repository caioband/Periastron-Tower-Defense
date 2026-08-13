local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local CrateConfig = SharedConfig.CrateConfig

local Framework = Me.new()

local CrateService = {
	Services = {
		DataService = {},
	},

	Signals = {
		-- (Player, rarity : string, amount : number, delta : number)
		CrateAmountChanged = Signal.new(),
	},
}

local function clampAmount(amount : number?) : number
	if typeof(amount) ~= "number" or amount ~= amount then
		return 0
	end

	return math.clamp(math.floor(amount), 0, CrateConfig.MAX_CRATES_PER_RARITY)
end

--[=[
	Reads the crates of a player straight from the loaded profile.
	Returns nil when the profile is not loaded yet -- use :GetCrates for the async version.
]=]
function CrateService:PeekCrates(Player : Player) : { [string]: number }?
	local profiles = self.Services.DataService.Profiles
	local profile = profiles and profiles[Player]
	if not profile then
		return nil
	end

	local inventory = profile.Profile.Data.Inventory
	return inventory and inventory.Crates or nil
end

--[=[
	Async read that waits for the profile to be loaded.
]=]
function CrateService:GetCrates(Player : Player, callbackFunc : ({ [string]: number }) -> ())
	self.Services.DataService:Get(Player, function(data)
		data.Inventory = data.Inventory or {}
		data.Inventory.Crates = data.Inventory.Crates or CrateConfig.createEmptyCrates()

		callbackFunc(data.Inventory.Crates)
	end)
end

--[=[
	Sets the crate amount of a single rarity to an absolute value.
	Returns the applied amount, or nil when it failed (bad rarity / profile not loaded).
]=]
function CrateService:SetCrates(Player : Player, rarity : string, amount : number) : number?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		warn(string.format("[CrateService]: %q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local DataService = self.Services.DataService
	if not DataService.Update then
		warn("[CrateService]: DataService is not ready yet, ignoring crate change.")
		return nil
	end

	local targetAmount = clampAmount(amount)
	local previousAmount

	local inventory = DataService:Update(Player, "Inventory", function(currentInventory)
		currentInventory = currentInventory or {}
		currentInventory.Crates = currentInventory.Crates or CrateConfig.createEmptyCrates()

		previousAmount = currentInventory.Crates[resolvedRarity] or 0
		currentInventory.Crates[resolvedRarity] = targetAmount

		return currentInventory
	end)

	if not inventory then
		return nil
	end

	self.Signals.CrateAmountChanged:Fire(Player, resolvedRarity, targetAmount, targetAmount - previousAmount)
	return targetAmount
end

--[=[
	Adds (or removes, with a negative amount) crates of a rarity.
	Returns the resulting amount, or nil when it failed.
]=]
function CrateService:GiveCrates(Player : Player, rarity : string, amount : number?) : number?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		warn(string.format("[CrateService]: %q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local delta = typeof(amount) == "number" and math.floor(amount) or 1
	local crates = self:PeekCrates(Player)
	local currentAmount = crates and crates[resolvedRarity] or 0

	return self:SetCrates(Player, resolvedRarity, currentAmount + delta)
end

function CrateService:construct()

end

function CrateService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function CrateService:init()

end

return CrateService
