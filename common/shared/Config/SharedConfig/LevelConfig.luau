--[=[
	The profile's level curve and the art of the HUD XP bar.

	`Stats.XP` in the profile is an accumulated total; the level is never stored,
	always derived from it (`Resolve`). Level and XP can never be out of sync, and
	changing the curve re-evaluates everyone without a migration.

	Match XP comes from `Config.Data.BASE_WINNING_XP` (200 for a full Medium run,
	scaled by the fraction of waves and the difficulty's `WinXpMultiplier`), so
	`BASE_XP = 100` puts the first level at half a match, and the curve opens up
	from there.

	Level drives the deck slots (`DeckConfig.SLOT_UNLOCK_LEVELS`, at 5, 15, and 25)
	and the alternative difficulty unlock path (`DifficultyUnlockConfig`, levels 3,
	6, and 12). Changing the curve moves both, which is why the exponent is the
	knob and not `BASE_XP`: the start stays put and only the middle onward, where
	the grind was, gets shorter.
]=]

local LevelConfig = {}

--[[ CURVE ]]

LevelConfig.MAX_LEVEL = 50

--[=[
	XP to leave level L: floor(BASE_XP * L^CURVE).

	The exponent went from 1.35 to 1.20 so levels come faster. The start does not
	change (L1->2 still costs 100, since 1^x is 1); the rest gets shorter, more and
	more:

	| Leaving level | 1.35 (before) | 1.20 (now) |
	| --- | --- | --- |
	| 1 | 100 | 100 |
	| 5 | 878 | 690 |
	| 10 | 2,239 | 1,585 |
	| 20 | 5,707 | 3,641 |
	| 49 | 19,132 | 10,672 |

	Cumulatively that is ~15% less XP to level 5, ~28% to 15, ~34% to 25 (the last
	deck slot), and ~41% to 50: from ~2,040 to ~1,215 full Medium runs, counting
	only match XP.
]=]
LevelConfig.BASE_XP = 100
LevelConfig.CURVE = 1.20

--[[ BAR ]]

--[=[
	One image per progress band of the current level, in increasing order: each
	entry applies up to its `Threshold`. Below the first (progress exactly zero)
	the bar keeps the empty image authored in the GUI; see `HUDController`, which
	reads it from the ImageLabel instead of repeating the id here.
]=]
LevelConfig.BAR_IMAGES = {
	{ Threshold = 0.2, Image = "rbxassetid://134959500194037" },
	{ Threshold = 0.4, Image = "rbxassetid://114833771984043" },
	{ Threshold = 0.6, Image = "rbxassetid://130493899698635" },
	{ Threshold = 0.8, Image = "rbxassetid://93135811626919" },
	{ Threshold = 1.0, Image = "rbxassetid://135439475286984" },
}

export type LevelState = {
	Level : number,
	XP : number,        -- XP within the current level
	Required : number,  -- XP to the next level (0 at the max)
	Progress : number,  -- 0..1
	IsMax : boolean,
}

--[[ API ]]

--[=[
	How much XP it costs to go from `level` to the next. Zero at the max level.
]=]
function LevelConfig:GetXPForLevel(level : number) : number
	level = math.floor(tonumber(level) or 1)

	if level < 1 or level >= self.MAX_LEVEL then
		return 0
	end

	return math.floor(self.BASE_XP * (level ^ self.CURVE) + 0.5)
end

--[=[
	Splits the profile's accumulated XP into level + progress within it.
]=]
function LevelConfig:Resolve(totalXP : number?) : LevelState
	local remaining = math.max(0, math.floor(tonumber(totalXP) or 0))
	local level = 1

	while level < self.MAX_LEVEL do
		local cost = self:GetXPForLevel(level)
		if remaining < cost then
			break
		end

		remaining -= cost
		level += 1
	end

	local isMax = level >= self.MAX_LEVEL
	local required = isMax and 0 or self:GetXPForLevel(level)

	return {
		Level = level,
		XP = isMax and 0 or remaining,
		Required = required,
		Progress = isMax and 1 or (required > 0 and math.clamp(remaining / required, 0, 1) or 0),
		IsMax = isMax,
	}
end

--[=[
	The image for the band the progress falls in, or nil when progress is zero; the
	caller then uses the authored empty bar.
]=]
function LevelConfig:GetBarImage(progress : number) : string?
	progress = tonumber(progress) or 0

	if progress <= 0 then
		return nil
	end

	for _, entry in self.BAR_IMAGES do
		if progress <= entry.Threshold then
			return entry.Image
		end
	end

	return self.BAR_IMAGES[#self.BAR_IMAGES].Image
end

--[=[
	Every bar id, for the HUD preload.
]=]
function LevelConfig:GetBarImages() : { string }
	local images = {}

	for _, entry in self.BAR_IMAGES do
		table.insert(images, entry.Image)
	end

	return images
end

return LevelConfig
