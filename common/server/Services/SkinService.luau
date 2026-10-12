local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs:WaitForChild("SharedConfig"))
local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Signal = require(Packages.Signal)

local Framework = Me.new()
local log = Log.new("SkinService")

local SkinConfig = SharedConfig.SkinConfig
local KEY = SkinConfig.PROFILE_KEY

local INDEX_CATEGORY = "Skins"
local REQUEST_COOLDOWN = 0.25

--[[
	Unit skins: which ones the player owns and which one each unit wears.

	The profile key (`Skins = { Owned, Equipped }`) is created on load instead of living
	in `Config.Data.Template`, so the data layer did not change. Unknown ids stay in
	`Owned` on purpose: renaming or pulling a skin from `SkinConfig` must not wipe who
	owned it.

	What each player wears is also published on the Player as `EquippedSkins` (JSON),
	because other clients need it to dress that player's units in a match and the
	replica only reaches its owner.

	Owning a skin also discovers it in the Index (`Skins` category), on grant and on
	every profile load, so skins owned before the page existed show up too.
]]

local SkinService = {
	Services = {
		DataService = {},
	},
	Signals = {
		-- (player)
		Changed = Signal.new(),
	},
}

--[[ INTERNAL ]]

function SkinService:_profile(player : Player)
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]

	return entry and entry.Profile.Data or nil
end

function SkinService:_get(player : Player)
	local data = self:_profile(player)
	if not data then
		return nil
	end

	return SkinConfig.sanitize(data[KEY])
end

function SkinService:_publish(player : Player)
	local skins = self:_get(player)
	local equipped = skins and skins.Equipped or {}

	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, equipped)
	player:SetAttribute(SkinConfig.ATTRIBUTE, if ok then encoded else "")
end

-- Writes every owned, known skin into the Index. `IndexService` skips what is already there.
function SkinService:_discover(player : Player)
	local skins = self:_get(player)
	if not skins then
		return
	end

	local ids = {}
	for id in skins.Owned do
		if SkinConfig.Get(id) then
			table.insert(ids, id)
		end
	end

	if #ids == 0 then
		return
	end

	local indexService = Framework:Get("IndexService", false, false)
	if indexService and indexService.UnlockMany then
		indexService:UnlockMany(player, INDEX_CATEGORY, ids)
	end
end

function SkinService:_sync(player : Player)
	if not self:_profile(player) then
		return
	end

	self.Services.DataService:Update(player, KEY, function(current)
		return SkinConfig.sanitize(current)
	end)

	self:_publish(player)
	self:_discover(player)
end

-- Runs `mutate(skins)` inside one profile write. `mutate` returns a reason to refuse.
function SkinService:_write(player : Player, mutate : (any) -> string?) : (boolean, string?)
	if not self:_profile(player) then
		return false, "NotLoaded"
	end

	local reason = nil

	self.Services.DataService:Update(player, KEY, function(current)
		local skins = SkinConfig.sanitize(current)
		reason = mutate(skins)
		return skins
	end)

	self:_publish(player)

	if reason then
		return false, reason
	end

	self.Signals.Changed:Fire(player)
	return true, nil
end

function SkinService:_onRequest(player : Player, id : any, action : string)
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

	Framework:Fire("SkinResult", player, id, action, ok, reason)
end

--[[ API ]]

function SkinService:Owns(player : Player, id : string) : boolean
	local skins = self:_get(player)
	return skins ~= nil and skins.Owned[id] == true
end

function SkinService:GetEquipped(player : Player, unitName : string) : string?
	local skins = self:_get(player)
	return skins and skins.Equipped[unitName] or nil
end

function SkinService:Grant(player : Player, id : string) : (boolean, string?)
	if not SkinConfig.Get(id) then
		return false, "UnknownSkin"
	end

	local ok, reason = self:_write(player, function(skins)
		skins.Owned[id] = true
		return nil
	end)

	if ok then
		self:_discover(player)
	end

	return ok, reason
end

function SkinService:Revoke(player : Player, id : string) : (boolean, string?)
	return self:_write(player, function(skins)
		if not skins.Owned[id] then
			return "NotOwned"
		end

		skins.Owned[id] = nil

		local skin = SkinConfig.Get(id)
		if skin and skins.Equipped[skin.Unit] == id then
			skins.Equipped[skin.Unit] = nil
		end

		return nil
	end)
end

function SkinService:Equip(player : Player, id : any) : (boolean, string?)
	local skin = SkinConfig.Get(id)
	if not skin then
		return false, "UnknownSkin"
	end

	return self:_write(player, function(skins)
		if not skins.Owned[id] then
			return "NotOwned"
		end

		skins.Equipped[skin.Unit] = id
		return nil
	end)
end

function SkinService:Unequip(player : Player, id : any) : (boolean, string?)
	local skin = SkinConfig.Get(id)
	if not skin then
		return false, "UnknownSkin"
	end

	return self:_write(player, function(skins)
		if skins.Equipped[skin.Unit] ~= id then
			return "NotEquipped"
		end

		skins.Equipped[skin.Unit] = nil
		return nil
	end)
end

--[[ LIFECYCLE ]]

function SkinService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		log:Warn("no DataService; skins will not load.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_sync(player)
	end)

	-- Any write to the key (Cmdr, a data reset) republishes what the player wears.
	dataService.Signals.DataUpdated:Connect(function(player : Player, key : string)
		if key == KEY then
			self:_publish(player)
		end
	end)

	for _, player in Players:GetPlayers() do
		self:_sync(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		self.LastRequest[player] = nil
	end)
end

function SkinService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function SkinService:init()
	self.LastRequest = {}

	Framework:Listen("SkinResult", function() end)

	Framework:Listen("RequestEquipSkin", function(player, id)
		self:_onRequest(player, id, "Equip")
	end)

	Framework:Listen("RequestUnequipSkin", function(player, id)
		self:_onRequest(player, id, "Unequip")
	end)
end

return SkinService