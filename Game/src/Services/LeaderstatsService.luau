local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	The match `leaderstats`: Damage and Cash in the player list.

	Both belong to the **session**, not the profile: damage is the scoreboard that
	decides the MVP (`MobService.SessionDamage`) and Cash is the round's money
	(`MobService.SessionCash`), the one that buys and sells towers. Neither is saved,
	and both go back to zero when the round restarts.

	> Not to be confused with the Lobby's `leaderstats`, which shows Coins, Wins, and
	> Shards: those are profile values, and `Coins` is the stored `Stats.Cash`. The two
	> columns here die with the server.

	**Why polling here and not in the Lobby.** There every write goes through a funnel
	(`DataService:Update`) and happens once in a while, so a signal per write is exact
	and cheap. Here it is the opposite, for two reasons:

	- **frequency**: damage grows with every hit on every enemy. With AOE and half a
	  dozen towers that is dozens of writes per second, and writing the `IntValue` on
	  every one would replicate far more than the list can show. A read every
	  `REFRESH_INTERVAL` costs two comparisons per player and the column looks the same
	  on screen.
	- **the zeros**: round end clears the scoreboard with `table.clear(SessionDamage)`,
	  which is no write at all: an event-driven display would keep showing the last
	  match's damage. Reading the state, the reset to zero comes for free.

	The write only happens when the value changes, so while idle the service
	replicates nothing.
]]

local FOLDER_NAME = "leaderstats"

--[[
	How often the columns are reread.

	Four times a second: fast enough for the number to look live (the player list is
	not even open all the time) and slow enough for a whole wave's damage to fit in a
	few dozen writes.
]]
local REFRESH_INTERVAL = 0.25

--[[
	One line per column, **in the order they appear** in the player list: Roblox draws
	them in the order the values enter the folder.

	`Read` receives the player and returns the column's number. A new column is one
	line here.
]]
local ENTRIES = {
	{
		Name = "Damage",
		Read = function(self, player : Player) : number
			local mobService = self.Services.MobService

			return mobService and mobService:GetDamageDealt(player.UserId) or 0
		end,
	},

	{
		Name = "Cash",
		Read = function(self, player : Player) : number
			local mobService = self.Services.MobService

			return mobService and mobService:getCash(player) or 0
		end,
	},
}

local LeaderstatsService = {
	Services = {
		MobService = {}
	}
}

--[[ INTERNAL ]]

--[=[
	The player's folder, created with the columns already inside if it does not exist.

	It is parented **last**, on purpose: the player list starts drawing as soon as the
	folder appears, and an empty folder for one frame flashes a row with no columns.

	The folder lives on the `Player`, which survives respawn, so this runs once per
	player, and everything else is value writes.
]=]
local function ensureFolder(player : Player) : Folder
	local existing = player:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	for _, entry in ENTRIES do
		local value = Instance.new("IntValue")
		value.Name = entry.Name
		value.Parent = folder
	end

	folder.Parent = player

	return folder
end

--[[ API ]]

--[=[
	Rereads a player's columns. `IntValue` already truncates, but the explicit
	`math.floor` makes the comparison use the same number that will be written:
	without it, fractional damage would mark "changed" on every hit without the
	column ever changing on screen.
]=]
function LeaderstatsService:Refresh(player : Player)
	if not player.Parent then
		return
	end

	local folder = ensureFolder(player)

	for _, entry in ENTRIES do
		local value = folder:FindFirstChild(entry.Name)
		if not value or not value:IsA("IntValue") then
			continue
		end

		local wanted = math.floor(entry.Read(self, player))
		if value.Value ~= wanted then
			value.Value = wanted
		end
	end
end

function LeaderstatsService:RefreshAll()
	for _, player in Players:GetPlayers() do
		self:Refresh(player)
	end
end

--[[ LIFECYCLE ]]

function LeaderstatsService:construct()
	-- A player joining mid-match already shows up with the columns, even if the
	-- clock's first tick has not come yet.
	Players.PlayerAdded:Connect(function(player : Player)
		self:Refresh(player)
	end)

	self:RefreshAll()

	local elapsed = 0

	RunService.Heartbeat:Connect(function(dt : number)
		elapsed += dt
		if elapsed < REFRESH_INTERVAL then
			return
		end

		elapsed = 0
		self:RefreshAll()
	end)
end

function LeaderstatsService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function LeaderstatsService:init()
end

return LeaderstatsService
