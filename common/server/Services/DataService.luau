local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

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
local Signal = require(Packages.Signal)

local ProfileStore = require(ServerVendor.ProfileStore)
local Replica = require(ServerVendor.ReplicaServer)

local Framework = Me.new()
local log = Log.new("DataService")

--[[
	What changes between places (`Config.Data.Places`). The place comes from the
	`Place` attribute each Rojo project sets on `ServerScriptService.Services`, not from
	`PlaceId`, so QA copies behave like the place itself.

	An unknown place answers `Get` right away: waiting on a tag that nobody sets would
	hand out no profile at all.
]]
local PLACE_NAME = ServerScriptService:WaitForChild("Services"):GetAttribute("Place")
local PLACE = ServerConfig.Data.Places[PLACE_NAME]
if not PLACE then
	log:Warn(`no Config.Data.Places entry for place '{tostring(PLACE_NAME)}'; Get will not wait for the client.`)
	PLACE = { ReadyTag = "Loaded", WaitForClient = false }
end

local DataService = {
	Signals = {
		PlayerDataLoaded = Signal.new(),

		--[[
			(player, key, value): after every `Update` write.

			`Update` is the only write path to the profile (the replica's `Set` only happens
			in there), so server code that needs to react to a change listens here instead
			of watching the profile. The client does not need this: for it the replica
			already notifies on its own, through `OnChange`.
		]]
		DataUpdated = Signal.new(),
	}
}

local function copyTemplateValue(value)
	if typeof(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, childValue in value do
		copy[key] = copyTemplateValue(childValue)
	end

	return copy
end

--[=[
	What a data reset (`ResetOnRelease`) keeps: `PurchaseHistory` is what stops a
	developer product receipt that Roblox replays from paying twice, and `SaveStamp`
	belongs to `Save`. Everything else goes back to `Data.Template`.
]=]
local RESET_KEEP = {
	PurchaseHistory = true,
	SaveStamp = true,
}

--- The profile, back to a new player's: every key but `RESET_KEEP` from the template.
local function resetToTemplate(data, template)
	for key in table.clone(data) do
		if not RESET_KEEP[key] then
			data[key] = nil
		end
	end

	for key, value in template do
		if not RESET_KEEP[key] then
			data[key] = copyTemplateValue(value)
		end
	end
end

local function reconcileTemplate(data, template)
	for key, templateValue in template do
		if data[key] == nil then
			data[key] = copyTemplateValue(templateValue)
		elseif typeof(data[key]) == "table" and typeof(templateValue) == "table" then
			reconcileTemplate(data[key], templateValue)
		end
	end
end

--[=[
	Rewrites old map names (`MapConfig.ALIASES`) in the two places the profile
	saves a map key: `Index.Maps` (discovered maps, and its twin `IndexSeen.Maps`) and each contract slot's drawn
	`Params.Map`. Returns how many entries changed.

	It runs on the raw data, before the replica exists, so nothing downstream
	(`ContractService`'s redraw, the client) ever sees the old name. An already
	discovered current key just absorbs the old one.
]=]
local function migrateMapAliases(data) : number
	local aliases = SharedConfig.MapConfig.ALIASES
	local changed = 0

	-- `IndexSeen` mirrors `Index`, so its map keys follow the same rename.
	for _, root in { data.Index, data.IndexSeen } do
		local maps = typeof(root) == "table" and root.Maps
		if typeof(maps) == "table" then
			for old, current in aliases do
				if maps[old] ~= nil then
					maps[current] = maps[current] or maps[old]
					maps[old] = nil
					changed += 1
				end
			end
		end
	end

	if typeof(data.Contracts) == "table" then
		for _, period in data.Contracts do
			local slots = typeof(period) == "table" and period.Slots
			if typeof(slots) ~= "table" then
				continue
			end

			for _, slot in slots do
				local params = typeof(slot) == "table" and slot.Params
				local current = typeof(params) == "table" and aliases[params.Map]

				if current then
					params.Map = current
					changed += 1
				end
			end
		end
	end

	return changed
end

--[=[
	The profile was taken by another server (or the session dropped) with the player
	still here. From now on nothing they did would be saved (the profile no longer
	belongs to this server), so they are removed, with a message to rejoin.

	What usually takes it is `ProfileEditService`'s short session (an admin command on a
	player who just joined) or the player joining another server before this one
	released the profile.
]=]
local SESSION_LOST_MESSAGE = "Your data was opened somewhere else. Please rejoin."

-- How long `CreatePlayer` waits for `ProfileEditService`'s short session to release
-- the key before trying anyway.
local OFFLINE_SESSION_WAIT = 20

function DataService:construct()
	self.Profiles = {}

	-- `{ [UserId] = true }` while `ProfileEditService` holds the profile of someone
	-- who is not on the server. See `CreatePlayer`.
	self.OfflineSessions = {}
	self.Packages = {
		ReplicaToken = Replica.Token("PlayerData"),
		ProfileManager = ProfileStore.New(
			ServerConfig.Data.PROFILE_KEY,
			ServerConfig.Data.Template
		)
	}
	return true
end

function DataService:CreatePlayer(Player : Player)
	local profileKey = "Player_" .. Player.UserId

	--[[
		ProfileStore refuses to open the same key twice on the same server: if an admin
		command has this player's profile open in a short session, wait for it to close (a
		matter of seconds).
	]]
	local deadline = os.clock() + OFFLINE_SESSION_WAIT
	while self.OfflineSessions[Player.UserId] and os.clock() < deadline do
		task.wait(0.1)
	end

	local Session = self.Packages.ProfileManager:StartSessionAsync(profileKey) :: typeof(ProfileStore.New():StartSessionAsync())

	-- Left while the profile loaded: release immediately, or the session stays stuck
	-- until the server closes and the player cannot join another.
	if Session ~= nil and Player.Parent ~= Players then
		Session:EndSession()
		return
	end

	if Session ~= nil then
		reconcileTemplate(Session.Data, ServerConfig.Data.Template)

		local migrated = migrateMapAliases(Session.Data)
		if migrated > 0 then
			log:Info(string.format("renamed %d old map name(s) in %s's profile.", migrated, Player.Name))
		end

		local ReplicaProfile = Replica.New({
			Token = self.Packages.ReplicaToken,
			Player = Player,
			Data = Session.Data,
			Tags = {
				Player = Player
			},
		})

	--	ReplicaProfile:Subscribe(Player)
		ReplicaProfile:Replicate()
		ReplicaProfile:FireAllClients()

		local entry = {
			Profile = ReplicaProfile,
			Session = Session,

			-- `true` when `Destroy` is what closes it (normal leave), so `OnSessionEnd`
			-- does not mistake it for a taken profile.
			Releasing = false,
		}
		self.Profiles[Player] = entry

		Session.OnSessionEnd:Connect(function()
			if entry.Releasing or self.Profiles[Player] ~= entry then
				return
			end

			-- On shutdown ProfileStore itself closes every session; then `BindToClose`
			-- releases the player, with the leave callbacks running.
			if ProfileStore.IsClosing then
				return
			end

			log:Warn(string.format("the session for %s ended while they were in the server; kicking.", Player.Name))

			self.Profiles[Player] = nil
			entry.Profile:Destroy()
			Player:Kick(SESSION_LOST_MESSAGE)
		end)

		--[[
			Admin edits arriving by message (`ProfileEditService`): those waiting on the
			profile and those that arrive while it is open. `Get` waits because the service
			may not be up yet on the first batch.
		]]
		Session:MessageHandler(function(message, processed)
			if self.Profiles[Player] ~= entry then
				return
			end

			-- Each service ignores messages of another kind, so both can see every one.
			Framework:Get("ProfileEditService", false, true):ApplyMessageToPlayer(Player, message, processed)
			Framework:Get("GiftService", false, true):ApplyMessageToPlayer(Player, message, processed)
		end)

		log:Debug("profile loaded for", Player.Name)
		self.Signals.PlayerDataLoaded:Fire(Player)
	end
end


local function awaitPlayerTag(player: Player, tagName: string): boolean
	if CollectionService:HasTag(player, tagName) then return true end

	local signal = CollectionService:GetInstanceAddedSignal(tagName)
	local thread = coroutine.running()

	local connection
	connection = signal:Connect(function(instance)
		if instance == player then
			connection:Disconnect()
			task.spawn(thread, true)
		end
	end)
	task.delay(ServerConfig.Data.MAX_DATA_TIME_OUT, function()
		if connection and connection.Connected then
			connection:Disconnect()
			task.spawn(thread, false)
		end
	end)

	return coroutine.yield()
end

--[=[
	Calls `callbackFunc(data)` once the player's profile is open. Where the place has
	`WaitForClient` (`Config.Data.Places`), it also waits for the client to fire
	`Loaded`; without it, a profile that is already open is handed out on the spot.
	Gives up silently after `MAX_DATA_TIME_OUT` seconds.
]=]
function DataService:Get(Player : Player, callbackFunc)
	local function deliver()
		if PLACE.WaitForClient and not awaitPlayerTag(Player, PLACE.ReadyTag) then
			return
		end

		if self.Profiles[Player] then
			callbackFunc(self.Profiles[Player].Profile.Data)
		end
	end

	if self.Profiles[Player] then
		if PLACE.WaitForClient then
			task.spawn(deliver)
		else
			deliver()
		end
		return
	end

	local waitConnection
	waitConnection = self.Signals.PlayerDataLoaded:Connect(function(player)
		if player == Player then
			waitConnection:Disconnect()
			waitConnection = nil

			deliver()
		end
	end)

	task.delay(ServerConfig.Data.MAX_DATA_TIME_OUT, function()
		if waitConnection ~= nil then
			waitConnection:Disconnect()
			waitConnection = nil
		end
	end)
end

--[=[
	Registers something to happen with the profile still open, right before the session
	closes: for example, crediting the reward of a player who leaves mid-round.

	Every exit path goes through `Destroy`: the `PlayerRemoving` of a player who leaves
	and the server shutdown's `BindToClose`. Registering here covers both at once and does
	not depend on the order in which services connected their own `PlayerRemoving`:
	anything written after `EndSession` would be lost.

	`order` (0 by default) is for code that needs to **read** the profile after everyone
	else that still writes to it: they run lowest to highest, in registration order within
	the same number. `LeaderboardService` uses 1 to get the profile with the leave reward
	and `PlaytimeService`'s final playtime already in.
]=]
function DataService:OnBeforeRelease(callback : (Player) -> (), order : number?)
	if not self.BeforeRelease then
		self.BeforeRelease = {}
	end

	table.insert(self.BeforeRelease, {
		Callback = callback,
		Order = order or 0,
		Index = #self.BeforeRelease + 1,
	})

	table.sort(self.BeforeRelease, function(a, b)
		if a.Order ~= b.Order then
			return a.Order < b.Order
		end

		return a.Index < b.Index
	end)
end

function DataService:Destroy(Player : Player)
	local entry = self.Profiles[Player]
	if not entry then return end

	-- One pcall per callback: an error in any of them must not stop the session from
	-- closing, or the profile stays stuck and the player cannot join another server.
	for _, hook in self.BeforeRelease or {} do
		local ok, err = pcall(hook.Callback, Player)
		if not ok then
			log:Warn(string.format("leave callback failed for %s: %s", Player.Name, tostring(err)))
		end
	end

	-- After the leave callbacks, so nothing they write (playtime, the leave reward)
	-- lands on top of the fresh profile. See `ResetOnRelease`.
	if entry.ResetPending then
		resetToTemplate(entry.Session.Data, ServerConfig.Data.Template)
		log:Info(string.format("reset %s's profile to the template.", Player.Name))
	end

	entry.Releasing = true
	entry.Session:EndSession()
	entry.Profile:Destroy()
	self.Profiles[Player] = nil
end

--[=[
	Marks the profile to go back to `Data.Template` when the session closes (QA's
	`datareset`). Returns `false` when the profile is not open.

	It happens on release, not now, because the other services keep state read from
	the profile when it loaded (contracts drawn, the Index synced, the leaderstats):
	resetting under them would leave the server out of step with the data. The caller
	kicks the player, and the next join loads the clean profile like a new player's.
]=]
function DataService:ResetOnRelease(Player : Player) : boolean
	local entry = self.Profiles[Player]
	if not entry then return false end

	entry.ResetPending = true
	return true
end

function DataService:Update(Player : Player, Key : string, callbackFunc)
	if not self.Profiles[Player] then
		log:Warn(string.format("attempted to update data for %s, but the profile is not loaded.", Player.Name))
		return
	end

	local replicaProfile = self.Profiles[Player].Profile
	local currentData = replicaProfile.Data[Key]

	local editedData = callbackFunc(currentData)
	if editedData == nil then
		log:Warn(string.format("update callback for %s returned nil; keeping the existing data.", Key))
		return currentData
	end

	replicaProfile:Set({Key}, editedData)
	self.Signals.DataUpdated:Fire(Player, Key, editedData)

	return editedData
end

--[=[
	Saves the profile now, instead of waiting for ProfileStore's autosave, and
	**yields until that save is on disk**. Returns `true` once it is, `false` when there
	is no open profile, or when the save did not land within `Config.Data.SAVE_TIMEOUT`.

	`MonetizationService`'s `ProcessReceipt` needs this: it only returns
	`PurchaseGranted` after what was bought is **on disk**. Without it, a server crashing
	between the purchase and the autosave would charge the player and lose the delivery,
	and `PurchaseHistory`, which keeps the purchase from being credited twice, goes with
	it. On `false` the receipt comes back as `NotProcessedYet` and Roblox retries, which
	beats confirming a delivery that was not saved.

	`Session:Save()` alone does not wait: it starts the save on its own thread and
	returns. And `OnAfterSave` alone does not prove anything either, since a save that
	was already in flight (an autosave) may have read the data before this call's
	changes. So each call stamps the data (`SaveStamp`) before asking for the save, and
	only a save whose stored copy carries that stamp, or a later one, counts.

	Every place needs it: developer products are sold in the Lobby too (the card shop
	reroll is one), and without this method `ProcessReceipt` would error in here and no
	purchase would be credited.
]=]
function DataService:Save(Player : Player) : boolean
	local entry = self.Profiles[Player]
	if not entry then return false end

	local session = entry.Session
	if not session:IsActive() then return false end

	local stamp = (tonumber(session.Data.SaveStamp) or 0) + 1
	session.Data.SaveStamp = stamp

	local thread = coroutine.running()
	local result : boolean? = nil
	local waiting = false
	local connection

	local function finish(saved : boolean)
		if result ~= nil then return end
		result = saved
		connection:Disconnect()

		if waiting then
			task.spawn(thread, saved)
		end
	end

	-- The release save on leave also fires this, with the stamp in: a player who
	-- leaves mid-wait still answers `true`.
	connection = session.OnAfterSave:Connect(function(saved)
		if typeof(saved) == "table" and (tonumber(saved.SaveStamp) or 0) >= stamp then
			finish(true)
		end
	end)

	task.delay(ServerConfig.Data.SAVE_TIMEOUT, finish, false)

	if not pcall(session.Save, session) then
		finish(false)
	end

	-- A mock store may answer without yielding: then it is already settled.
	if result ~= nil then
		return result
	end

	waiting = true
	return coroutine.yield()
end

function DataService:init()
	self:construct()

	local serverMaid = Maid.new()
	for _, player in Players:GetPlayers() do
		self:CreatePlayer(player)
	end

	serverMaid:GiveTask(Players.PlayerAdded:Connect(function(player)
		self:CreatePlayer(player)
	end))

	serverMaid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		self:Destroy(player)
	end))

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			task.spawn(function()
				self:Destroy(player)
			end)
		end
		task.wait(2)
		serverMaid:DoCleaning()
	end)

	Framework:Listen("Loaded", function(Player : Player)
		Player:AddTag(PLACE.ReadyTag)
	end)
end

function DataService:start()

end

return DataService
