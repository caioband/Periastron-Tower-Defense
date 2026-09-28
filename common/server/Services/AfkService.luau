local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Signal = require(Packages.Signal)
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("AfkService")

local Config = SharedConfig.AfkConfig

--[[
	Who is AFK on this server, in both places.

	`AfkController` decides on the client and sends `AfkChanged(isAfk)` only when
	the state changes. This service keeps it, sets the `Config.Attribute` attribute
	on the `Player`, and fires `Signals.AfkChanged(player, isAfk)` for services that
	react to it (`PlaytimeService` pauses the leaderboard playtime).

	**The client is trusted, on purpose.** Input and window focus do not exist on
	the server, so there is nothing to check the report against. An exploiter can
	stay "active" by never sending the report, but an autoclicker gets the same
	result against any input-based check, so a server-side guard would only add
	cost. Do not use this state for anything an exploiter would profit from beyond
	what they can already fake.

	Every player starts active, which is also what a client that never reports
	looks like.

	See docs/common/afk.md.
]]

local AfkService = {
	Services = {},

	Signals = {
		-- (player : Player, isAfk : boolean)
		AfkChanged = Signal.new(),
	},

	-- [Player] = true while AFK.
	Afk = {},
}

--[[ INTERNAL ]]

function AfkService:_set(player : Player, afk : boolean)
	if self:IsAfk(player) == afk then return end

	self.Afk[player] = if afk then true else nil
	player:SetAttribute(Config.Attribute, if afk then true else nil)

	log:Debug(player.Name, if afk then "is AFK." else "is back.")

	self.Signals.AfkChanged:Fire(player, afk)
end

--[[ PUBLIC ]]

--- Whether the player is AFK right now.
function AfkService:IsAfk(player : Player) : boolean
	return self.Afk[player] == true
end

--[[ LIFECYCLE ]]

function AfkService:construct()
	Framework:Listen("AfkChanged", function(player : Player, afk : any)
		if typeof(afk) ~= "boolean" then return end

		self:_set(player, afk)
	end)

	-- Deferred so `DataService:OnBeforeRelease` hooks can still read the state.
	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self.Afk[player] = nil
		end)
	end)
end

function AfkService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function AfkService:init()
end

return AfkService
