local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("SettingsService")

local SettingsConfig = SharedConfig.SettingsConfig

local DATA_KEY = "Settings"
local EVENT = "SettingChanged"

local BUCKET_MAX = 10
local BUCKET_REFILL = 5

local VALID = {}
for _, entry in SettingsConfig.List do
	VALID[entry.Key] = true
end

local SettingsService = {
	Services = {
		DataService = {},
	},
	Buckets = {},
}

function SettingsService:_allow(player : Player) : boolean
	local now = os.clock()
	local bucket = self.Buckets[player]

	if not bucket then
		bucket = { Tokens = BUCKET_MAX, Last = now }
		self.Buckets[player] = bucket
	end

	bucket.Tokens = math.min(BUCKET_MAX, bucket.Tokens + (now - bucket.Last) * BUCKET_REFILL)
	bucket.Last = now

	if bucket.Tokens < 1 then
		return false
	end

	bucket.Tokens -= 1

	return true
end

function SettingsService:Set(player : Player, key : any, value : any) : boolean
	if typeof(key) ~= "string" or not VALID[key] then
		return false
	end

	if typeof(value) ~= "boolean" then
		return false
	end

	local dataService = self.Services.DataService
	if not dataService then
		return false
	end

	dataService:Update(player, DATA_KEY, function(current : any)
		local copy = {}

		if typeof(current) == "table" then
			for savedKey, savedValue in current do
				copy[savedKey] = savedValue
			end
		end

		copy[key] = value

		return copy
	end)

	return true
end

function SettingsService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	Framework:Listen(EVENT, function(player : Player, key : any, value : any)
		if not self:_allow(player) then
			log:Warn(`{player.Name} is changing settings too fast; ignored.`)
			return
		end

		self:Set(player, key, value)
	end)

	Players.PlayerRemoving:Connect(function(player : Player)
		self.Buckets[player] = nil
	end)
end

function SettingsService:init()
end

return SettingsService