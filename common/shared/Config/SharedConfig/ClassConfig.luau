--[[
	How each unit class looks.

	The **taxonomy** does not start here: `WeatherConfig.ClassList` lists the
	classes, and `UnitStats[name].Class` says each unit's class (a string, or a
	list for a unit with two classes). This module is the other side: what the
	player sees when a class must appear on screen.

	Today the upgrade card's `ClassIcon` (`ToggleTower`) reads it.

	A new class is one line in `Icons` and one in `WeatherConfig.ClassList`; a unit
	without a class (`Azure`, not classified yet) simply has no icon, and the UI
	hides the label instead of showing an empty square.
]]

local WeatherConfig = require(script.Parent.WeatherConfig)

local ClassConfig = {}

--[[
	Icon for each class. Keys are those of `WeatherConfig.ClassList`.

	`Electric` is the lightning bolt: the art came named "Lightning", but the
	in-game class name is `Electric` and it rules here, or the unit would have one
	class for weather and another for the card.
]]
ClassConfig.Icons = {
	Melee = "rbxassetid://121357932673042",
	Ranged = "rbxassetid://88082629531610",
	Magic = "rbxassetid://92693595243994",
	Fire = "rbxassetid://88305366355775",
	Ice = "rbxassetid://133728117619416",
	Electric = "rbxassetid://80013469031768",
}

--[=[
	The class that represents the unit, or `nil` if it has none.

	A unit with two classes has a single icon, the **first** in its `UnitStats`
	list: there is one slot on screen, and whoever writes the config knows which
	one is primary.
]=]
function ClassConfig.GetPrimary(unitName : string?) : string?
	return WeatherConfig.GetClasses(unitName)[1]
end

--[=[
	The `rbxassetid` for the unit's class, or `nil` (no class, or no art yet).
]=]
function ClassConfig.GetIcon(unitName : string?) : string?
	local class = ClassConfig.GetPrimary(unitName)

	return class and ClassConfig.Icons[class]
end

return ClassConfig
