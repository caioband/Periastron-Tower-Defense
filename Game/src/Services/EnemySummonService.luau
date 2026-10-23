local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Settings = require(ServerScriptService:WaitForChild("Config"):WaitForChild("EnemySummon"))
local GameClock = require(Shared.Util.GameClock)
local Me = require(Vendor.Me)

local Framework = Me.new()

local POLL_INTERVAL = 0.1

local function fireAll(event : string, ...)
	for _, player in Players:GetPlayers() do
		Framework:Fire(event, player, ...)
	end
end

--[[
	Enemies that summon others on a timer: the Fall PART 1 necromancers. The numbers
	live in `Config.EnemySummon`.
]]
local EnemySummonService = {
	Services = {
		MobService = {},
	},

	-- mob record -> the match-clock time of its next cast.
	NextCastAt = setmetatable({}, { __mode = "k" }),
	EnemySet = {},
}

function EnemySummonService:isAlive(mobId : string, mob) : boolean
	return self.Services.MobService.ActiveMobs[mobId] == mob
end

function EnemySummonService:playCast(mobId : string, mob, castTime : number)
	if Settings.StopWhileCasting and castTime > 0 then
		mob.StunnedUntil = math.max(mob.StunnedUntil or 0, GameClock.Now() + castTime)
		fireAll("UpdateMobSpeed", mobId, 0)
	end

	if Settings.EnemyAnim then
		fireAll("MobPlayAnim", mobId, Settings.EnemyAnim)
	end

	if Settings.CastVFX and castTime > 0 then
		fireAll("SuffocateCastVFX", mobId, Settings.CastVFX, Settings.CastPart or "Right Arm", castTime)
	end
end

function EnemySummonService:summon(mobId : string, mob)
	local pool = Settings.Pool
	if #pool == 0 then return end

	local mobService = self.Services.MobService
	local spacing = Settings.Spacing or 0

	for index = 1, Settings.Count or 1 do
		local entityName = pool[math.random(1, #pool)]
		local distance = (mob.Distance or 0) - spacing * (index - 1)

		mobService:SpawnOnPath(entityName, mob.RouteIndex, distance, mob, Settings.Reward)
	end
end

function EnemySummonService:cast(mobId : string, mob)
	local castTime = math.max(0, Settings.CastTime or 0)

	self:playCast(mobId, mob, castTime)

	GameClock.Delay(castTime, function()
		if not self:isAlive(mobId, mob) then return end

		self:summon(mobId, mob)

		if (mob.StunnedUntil or 0) <= GameClock.Now() then
			fireAll("UpdateMobSpeed", mobId, mob.CurrentSpeed)
		end
	end)
end

function EnemySummonService:step()
	local mobService = self.Services.MobService
	if not mobService or not mobService.ActiveMobs then return end

	local now = GameClock.Now()
	local interval = math.max(0.1, Settings.Interval or 10)

	for mobId, mob in mobService.ActiveMobs do
		if self.EnemySet[mob.Name] and mob.Health > 0 then
			local nextAt = self.NextCastAt[mob]

			if not nextAt then
				self.NextCastAt[mob] = now + interval

			-- A stunned or frozen caster holds its cast until it can move again.
			elseif now >= nextAt and (mob.StunnedUntil or 0) <= now then
				self.NextCastAt[mob] = now + interval
				self:cast(mobId, mob)
			end
		end
	end
end

function EnemySummonService:ResetRound()
	table.clear(self.NextCastAt)
end

function EnemySummonService:start()
	for name in self.Services do
		self.Services[name] = Framework:Get(name)
	end

	for _, enemy in Settings.Enemies do
		self.EnemySet[enemy] = true
	end

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt : number)
		elapsed += dt
		if elapsed < POLL_INTERVAL then return end
		elapsed = 0

		self:step()
	end)
end

function EnemySummonService:init()
end

return EnemySummonService
