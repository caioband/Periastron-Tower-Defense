--[[
	The arrow that points at a place in the world: `Shared.Assets.VFX.IndicatorArrow`.

	`ArrowController` places and animates it; this holds the model path and the
	motion numbers.

	**Not to be confused with `ArrowConfig`** in `SharedConfig`, which is the
	Archer's projectile. This one hits nobody; it only points.

	The model lives in the place, not in git (Rojo does not sync `Shared.Assets`),
	and exists in both places. The path is by name and resolved late, so a place
	without the model does not break; it just points at nothing.

	See docs/common/ui-guidance.md.
]]

local IndicatorArrowConfig = {}

--[[
	Where the model is, from `ReplicatedStorage.Shared`, and where live copies hang
	in the `Workspace`.

	The Workspace folder is created with the first arrow and only this controller
	cleans it. It is not inside `Workspace.Map`, which `MapService` swaps between
	matches.
]]
IndicatorArrowConfig.Asset = {
	Path = { "Assets", "VFX" },
	Name = "IndicatorArrow",
}

IndicatorArrowConfig.Container = "Indicators"

--[=[
	The arrow's motion.

	`Height` is the **gap between the arrow tip and the target**, in studs, not
	the pivot height. The model's pivot is wherever the designer left it (today,
	at the tip), and the controller measures that distance itself, so moving the
	pivot in Studio or setting a `PrimaryPart` does not change where the arrow
	points. Zero touches the target.

	`Spin` is in **turns per second** and `Bob.Speed` in **cycles per second**:
	what you think when looking at it, not radians per frame.

	`Bob.Amplitude` is in studs: how far it rises and falls from the height.
]=]
IndicatorArrowConfig.Motion = {
	Height = 1.5,

	Spin = 0.35,

	Bob = {
		Amplitude = 0.6,
		Speed = 0.8,
	},
}

--[[
	Copy size, on top of the authored size (the model is 4x7x1 studs). It is
	`Model:ScaleTo`, so it applies to the whole model and its pivot.
]]
IndicatorArrowConfig.Scale = 1

--[=[
	The guide arrow (`ArrowController:Guide`): lies flat beside the player and
	points at the target, instead of hanging over it.

	  - `Distance`: studs from the player to the arrow tip.
	  - `Height`: studs above the player's root part (negative is below it).
	  - `Scale`: size on top of the authored one.
	  - `Push`: the nudge towards the target, in studs and cycles per second.
	  - `HideWithin`: the arrow hides once the player is this close to the target.
]=]
IndicatorArrowConfig.Guide = {
	Distance = 7,
	Height = -1.5,
	Scale = 0.8,

	Push = {
		Amplitude = 0.8,
		Speed = 1.2,
	},

	HideWithin = 10,
}

return IndicatorArrowConfig