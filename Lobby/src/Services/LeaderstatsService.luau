local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("LeaderstatsService")

--[[
	The Lobby `leaderstats`: Coins, Wins, and Shards in the player list.

	All three come from `Data.Stats`, and none is computed here: this service only copies
	the profile into the `IntValue`s Roblox draws. The profile is still the source, and
	anyone who wants the right number reads it there.

	**Coins is `Stats.Cash`.** The profile calls it `Cash` and the screen calls it Coins
	(it is what `HUDController` writes on the HUD currency); the player list follows the
	screen, not the key name. It is not match money: that is `MobService.SessionCash`,
	which only lives while the round lasts and never reaches the profile.

	**Why Lobby only.** It is where it makes sense: in Game the player list competes with
	the match, and `Wins` does not even change until it ends. Both places have the same
	profile, so the day Game wants it too, move this file to `common/server/Services`.

	**How it stays up to date.** Every profile write goes through `DataService:Update`
	(the replica's `Set` only happens in there), and it announces each one in
	`DataUpdated`. There is no polling: the column changes the instant the profile does,
	whether a shop purchase, a summon, or Cmdr's `cash`.

	See docs/lobby/hud.md.
]]

local FOLDER_NAME = "leaderstats"

-- The `Data` key that matters. Other writes (`Units`, `EquippedUnits`…)
-- touch none of the three columns.
local STATS_KEY = "Stats"

--[[
	One line per column, **in the order they appear** in the player list: Roblox draws
	them in the order the values enter the folder.

	`Name` is what the player reads; `Stat` is the key in `Data.Stats`.
]]
local ENTRIES = {
	{ Name = "Coins", Stat = "Cash" },
	{ Name = "Wins", Stat = "Wins" },
	{ Name = "Shards", Stat = "Shards" },
}

local LeaderstatsService = {
	Services = {
		DataService = {}
	}
}

--[[ INTERNAL ]]

--[=[
	The player's folder, created with the three columns already inside if it does not
	exist.

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
	Copies the three columns from the open profile. With no profile (still loading, or
	already closed) it does nothing: the folder is not even created, instead of being
	created with three zeros that are not what the player has.
]=]
function LeaderstatsService:Refresh(player : Player)
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]
	if not entry then
		return
	end

	local stats = entry.Profile.Data.Stats
	if not stats then
		return
	end

	local folder = ensureFolder(player)

	for _, config in ENTRIES do
		local value = folder:FindFirstChild(config.Name)

		--[[
			`IntValue` truncates on its own, but silently: the explicit `math.floor` is for
			the day a fractional reward appears and the list's number diverges from the HUD's
			with nobody understanding why.
		]]
		if value and value:IsA("IntValue") then
			value.Value = math.floor(stats[config.Stat] or 0)
		end
	end
end

--[[ LIFECYCLE ]]

function LeaderstatsService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; the player list has no columns.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:Refresh(player)
	end)

	dataService.Signals.DataUpdated:Connect(function(player : Player, key : string)
		if key ~= STATS_KEY then
			return
		end

		self:Refresh(player)
	end)

	--[[
		Players who loaded between `DataService`'s `init` and this `start`.

		The sweep comes after the connections, not before: between them a profile could
		load with no signal connected to hear it. Repeating costs nothing: `Refresh` is
		idempotent.
	]]
	for player in dataService.Profiles or {} do
		self:Refresh(player)
	end
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
