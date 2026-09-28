local RunService = game:GetService("RunService")

--[[
	The match clock: the usual `os.clock()`, but running at the speed chosen on
	the `Interface.Speed` button.

	There is no "x2" rule spread across the game's durations. Gameplay compares
	instants against a clock (`StunnedUntil`, `lastAttack`, a charge's
	`expiresAt`), so swapping the source of "now" for a faster one shrinks
	cooldowns, stuns, buffs, and spawn cadence together without touching config.

	**It starts at `os.clock()` on purpose.** Code like
	`now - (entry.lastAttack or 0)` relies on a large number on one side and zero
	on the other to mean "never attacked, may attack now"; a clock starting at
	zero would make a new unit wait one extra cooldown.

	**Each machine has its own copy.** `SpeedService` keeps the scales in sync by
	broadcasting every change. The client needs it because `MobController` moves
	enemy models at the same pace as the distance the server is adding.

	**What does NOT go through here:** screen time, not match time (the
	intermission, path arrows, VFX, result screens).

	See docs/game/match-speed.md.
]]

local GameClock = {}

-- Smallest accepted scale. `Wait` waits for the clock to pass an instant; with a
-- zero scale that instant never comes and the wait hangs.
local MIN_SCALE = 0.01

local scale = 1
local now = os.clock()

RunService.Heartbeat:Connect(function(dt : number)
	now += dt * scale
end)

--[[ API ]]

--- The match "now", used instead of `os.clock()`.
function GameClock.Now() : number
	return now
end

function GameClock.GetScale() : number
	return scale
end

function GameClock.SetScale(newScale : number?)
	scale = math.max(MIN_SCALE, newScale or 1)
end

--- A Heartbeat `dt` converted to match time.
function GameClock.Scaled(dt : number) : number
	return dt * scale
end

--[=[
	`task.wait`, in match time.

	The wait is re-checked against the clock every frame instead of being
	converted to real seconds at the call, so changing speed during a 3 s wait
	shortens what is left of it.

	Yields at least one frame, like `task.wait()`.
]=]
function GameClock.Wait(duration : number?) : number
	local deadline = now + (duration or 0)

	repeat
		RunService.Heartbeat:Wait()
	until now >= deadline

	return now
end

--- `task.delay`, in match time.
function GameClock.Delay(duration : number?, callback : () -> ()) : thread
	return task.spawn(function()
		GameClock.Wait(duration)
		callback()
	end)
end

return GameClock
