local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs:WaitForChild("SharedConfig"))
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Signal = require(Packages.Signal)

local Framework = Me.new()
local log = Log.new("NametagService")

local NametagConfig = SharedConfig.NametagConfig

local KEY = NametagConfig.PROFILE_KEY
local STATS_KEY = "Stats"
local REQUEST_COOLDOWN = 0.25

--[[
	Nametags: which ones the player owns and which one they wear.

	Same shape as `SkinService`. The profile key (`Nametags = { Owned, Equipped }`) is
	created on load. Unknown ids stay in `Owned` so pulling a nametag from config never
	wipes ownership.

	A nametag is available when it is `Free`, owned, or has an `UnlockLevel` the
	player's level reaches. Level nametags are never written to `Owned`: like the level
	itself they are derived from `Stats.XP`, so they follow the curve and Cmdr `level`
	without a migration, and dropping below the level takes them off.

	Every client draws every player's tag, and the replica only reaches its owner, so
	this publishes on the Player:
	  `EquippedNametag`: the equipped id, "" for the default
	  `Level`: resolved from `Stats.XP` through `LevelConfig`

	It also hides Roblox's default name and health bar on every character.
]]

local NametagService = {
	Services = {
		DataService = {},
	},
	Signals = {
		Changed = Signal.new(),
	},
}

--[[ INTERNAL ]]

function NametagService:_profile(player : Player)
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]

	return entry and entry.Profile.Data or nil
end

function NametagService:_level(player : Player) : number
	return NametagConfig.LevelOf(self:_profile(player))
end

function NametagService:_get(player : Player)
	local data = self:_profile(player)
	if not data then
		return nil
	end

	return NametagConfig.sanitize(data[KEY], NametagConfig.LevelOf(data))
end

function NametagService:_publish(player : Player)
	local nametags = self:_get(player)
	local equipped = nametags and nametags.Equipped or ""

	if player:GetAttribute(NametagConfig.ATTRIBUTE) ~= equipped then
		player:SetAttribute(NametagConfig.ATTRIBUTE, equipped)
	end
end

function NametagService:_publishLevel(player : Player)
	local data = self:_profile(player)
	if not data then
		return
	end

	local level = NametagConfig.LevelOf(data)
	if player:GetAttribute(NametagConfig.LEVEL_ATTRIBUTE) ~= level then
		player:SetAttribute(NametagConfig.LEVEL_ATTRIBUTE, level)
	end
end

function NametagService:_sync(player : Player)
	if not self:_profile(player) then
		return
	end

	local level = self:_level(player)

	self.Services.DataService:Update(player, KEY, function(current)
		return NametagConfig.sanitize(current, level)
	end)

	self:_publishLevel(player)
	self:_publish(player)
end

function NametagService:_write(player : Player, mutate : (any, number) -> string?) : (boolean, string?)
	if not self:_profile(player) then
		return false, "NotLoaded"
	end

	local level = self:_level(player)
	local reason = nil

	self.Services.DataService:Update(player, KEY, function(current)
		local nametags = NametagConfig.sanitize(current, level)
		reason = mutate(nametags, level)
		return nametags
	end)

	self:_publish(player)

	if reason then
		return false, reason
	end

	self.Signals.Changed:Fire(player)
	return true, nil
end

function NametagService:_onRequest(player : Player, id : any, action : string)
	local now = os.clock()
	if now - (self.LastRequest[player] or 0) < REQUEST_COOLDOWN then
		return
	end
	self.LastRequest[player] = now

	local ok, reason
	if action == "Equip" then
		ok, reason = self:Equip(player, id)
	else
		ok, reason = self:Unequip(player, id)
	end

	Framework:Fire("NametagResult", player, id, action, ok, reason)
end

local function hideDefault(character : Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
end

local function watchCharacters(player : Player)
	if player.Character then
		task.spawn(hideDefault, player.Character)
	end

	player.CharacterAdded:Connect(hideDefault)
end

--[[ API ]]

function NametagService:Owns(player : Player, id : string) : boolean
	local nametags = self:_get(player)
	return NametagConfig.IsAvailable(id, nametags and nametags.Owned, self:_level(player))
end

function NametagService:GetEquipped(player : Player) : string
	local nametags = self:_get(player)
	return nametags and nametags.Equipped or NametagConfig.DEFAULT
end

function NametagService:Grant(player : Player, id : string) : (boolean, string?)
	if not NametagConfig.Get(id) then
		return false, "UnknownNametag"
	end

	return self:_write(player, function(nametags)
		nametags.Owned[id] = true
		return nil
	end)
end

function NametagService:Revoke(player : Player, id : string) : (boolean, string?)
	return self:_write(player, function(nametags, level)
		if not nametags.Owned[id] then
			return "NotOwned"
		end

		nametags.Owned[id] = nil

		if nametags.Equipped == id and not NametagConfig.IsAvailable(id, nametags.Owned, level) then
			nametags.Equipped = nil
		end

		return nil
	end)
end

function NametagService:Equip(player : Player, id : any) : (boolean, string?)
	if not NametagConfig.Get(id) then
		return false, "UnknownNametag"
	end

	return self:_write(player, function(nametags, level)
		if not NametagConfig.IsAvailable(id, nametags.Owned, level) then
			return if NametagConfig.UnlockLevelOf(id) then "Locked" else "NotOwned"
		end

		nametags.Equipped = id
		return nil
	end)
end

function NametagService:Unequip(player : Player, id : any) : (boolean, string?)
	if not NametagConfig.Get(id) then
		return false, "UnknownNametag"
	end

	return self:_write(player, function(nametags)
		if nametags.Equipped ~= id then
			return "NotEquipped"
		end

		nametags.Equipped = nil
		return nil
	end)
end

--[[ LIFECYCLE ]]

function NametagService:construct()
	for _, player in Players:GetPlayers() do
		watchCharacters(player)
	end

	Players.PlayerAdded:Connect(watchCharacters)

	Players.PlayerRemoving:Connect(function(player)
		self.LastRequest[player] = nil
	end)

	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; nametags will not load.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_sync(player)
	end)

	dataService.Signals.DataUpdated:Connect(function(player : Player, key : string)
		if key == KEY then
			self:_publish(player)
		elseif key == STATS_KEY then
			self:_publishLevel(player)
			self:_publish(player)
		end
	end)

	for _, player in Players:GetPlayers() do
		self:_sync(player)
	end
end

function NametagService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function NametagService:init()
	self.LastRequest = {}

	Framework:Listen("NametagResult", function() end)

	Framework:Listen("RequestEquipNametag", function(player, id)
		self:_onRequest(player, id, "Equip")
	end)

	Framework:Listen("RequestUnequipNametag", function(player, id)
		self:_onRequest(player, id, "Unequip")
	end)
end

return NametagService