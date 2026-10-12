local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local CardConfig = SharedConfig.CardConfig
local MapConfig = SharedConfig.MapConfig
local Mob = SharedConfig.Mob
local RarityConfig = SharedConfig.RarityConfig
local UnitStats = SharedConfig.UnitStats
local WeatherConfig = SharedConfig.WeatherConfig

--[[
	What each Index page lists, in which order, and what the preview says about it.

	It only **reads** the configs that already describe each thing (`UnitStats`,
	`Mob`, `WeatherConfig`, `MapConfig`); the only text written here is the units'
	behavior line, which no config has.

	Descriptions are `RichTextController` markup: `[br]` breaks the line, and the
	words that matter carry a color from `COLORS` (or the game's own palette: rarity
	from `RarityConfig`, unit types and weather numbers from `WeatherConfig.Indicator`). Whether the player discovered an entry is
	not here: that is the profile (`IndexConfig`), read by `IndexController`.

	Each entry is `{ Key, Name, Image?, LockedImage?, PreviewImage? }`. `Key` is the
	same key the profile stores; `Image` is what the item button and the preview show
	for the categories drawn as a picture (and the units that have Index art). An
	entry without `Image` is drawn as its 3D model. `PreviewImage` replaces `Image`
	in the preview only: a map's button shows its Index art, and its preview the
	same picture as the map picker.
]]

local IndexCatalog = {}

--[[ CONSTANTS ]]

--[=[
	The units' names on their art, where it differs from the `UnitStats` key (see
	`CardConfig`: the Rocketeer card belongs to `Rocket`, the Gladiator to `Sword`).
]=]
local UNIT_NAMES = {
	Rocket = "Rocketeer",
	Sword = "Gladiator",
}

--[=[
	The highlight colors, as `r,g,b` for `[color=...]`. The text is white with a dark
	outline on the book's paper, so every color here is bright.
]=]
local COLORS = {
	Cash = "255,215,80",
	Range = "150,200,255",
	Health = "255,110,110",
	Boss = "255,60,60",
	Threshold = "255,180,95",

	Bleed = "235,70,70",
	Fire = "255,125,60",
	Ice = "135,220,255",
	Electric = "255,225,95",
	Magic = "200,130,255",
	Pierce = "150,230,140",

	Slow = "135,220,255",
	Fast = "255,180,95",
	VeryFast = "255,90,90",

	Wins = "255,215,80",
	Weather = "135,220,255",

	Difficulties = {
		Easy = "110,220,110",
		Medium = "255,220,90",
		Hard = "255,150,60",
		Impossible = "255,80,80",
		Nightmare = "190,110,255",
	},
}

-- How far toward white a rarity color goes in the text. See `describeUnit`.
local RARITY_LIGHTEN = 0.35

local function paint(text : string, color : string?) : string
	return if color then `[color={color}]{text}[/color]` else text
end

local function rgb(color : Color3?) : string?
	if not color then return nil end

	return `{math.floor(color.R * 255 + 0.5)},{math.floor(color.G * 255 + 0.5)},{math.floor(color.B * 255 + 0.5)}`
end

--[=[
	A unit type's color: the same one the weather indicator paints the type with
	(`WeatherConfig.Indicator.Colors.Classes`, keyed by the word on screen there).
]=]
local CLASS_WORDS = {
	Melee = "MELEE",
	Ranged = "RANGED",
	Magic = "MAGIC",
	Fire = "FIRE",
	Ice = "ICE",
	Electric = "ELEC",
}

local function classColor(class : string) : string?
	local word = CLASS_WORDS[class]
	return word and WeatherConfig.Indicator.Colors.Classes[word]
end

local C = COLORS

--[=[
	One short line per unit: how it fights, with the effect words in their colors. A
	unit missing here just shows no line, so a new unit costs one entry, not a crash.
]=]
local UNIT_BEHAVIOR = {
	Archmage = `Casts a three-step combo: a {paint("meteor", C.Fire)} that blasts an area, a {paint("lightning", C.Electric)} beam down a line, then a {paint("teleport", C.Magic)} that sends the target back along the path.`,
	Azure = `Unleashes {paint("four quick strikes", C.Fast)} per attack. Huge damage, but only on enemies that come close.`,
	Electro = `Fires a bolt that {paint("chains", C.Electric)} through up to four enemies, {paint("stunning", C.Electric)} each one for an instant.`,
	Berserker = `Swings a four-hit combo that cleaves nearby enemies and leaves them {paint("bleeding", C.Bleed)}, so they take more damage from everything.`,
	Bonfire = `Channels a {paint("fire beam", C.Fire)} that grows stronger the longer it holds a target. Rests when nothing is in range, and {paint("rain", C.Weather)} puts it out.`,
	Rocket = `Launches rockets from long range that {paint("explode", C.Fire)} on impact, hitting every enemy in the blast.`,
	["Subspace Tripminer"] = `Throws {paint("mines", C.Magic)} onto the path that explode when enemies step on them, hitting harder the longer they charge.`,
	Frostione = `Shoots frost bolts that {paint("slow", C.Ice)} enemies; enough hits {paint("freeze", C.Ice)} them solid.`,
	Entrepreneur = `Does not fight. Earns {paint("cash", C.Cash)} every wave and {paint("boosts the earnings", C.Cash)} of the towers around it.`,
	Slingshot = `A {paint("long-range", C.Range)} shooter that pelts one enemy at a time from afar.`,
	Archer = `Fires arrows that {paint("pierce", C.Pierce)} through every enemy in a line, losing a little damage per body.`,
	Pyre = `Hurls fireballs that set enemies {paint("ablaze", C.Fire)}, burning them over time.`,
	Sword = `A melee fighter that lands {paint("one heavy strike", C.Health)} at a time. Has to stand right next to the path.`,
	Slasher = `Quick melee slashes that make enemies {paint("bleed", C.Bleed)}, so every tower hits them harder.`,
	Cryomancer = `Does not attack. Surrounds itself with a {paint("frigid aura", C.Ice)} that {paint("slows", C.Ice)} every enemy inside it.`,
	Volt = `Quick zaps that leave enemies {paint("static", C.Electric)}, {paint("stunning", C.Electric)} them every few seconds. Other Electric towers hit charged enemies harder.`,
}

-- The difficulty folders in `Mob.Entities`, easiest first: the enemies page order.
local DIFFICULTY_ORDER = { "Easy", "Medium", "Hard", "Impossible", "Nightmare" }

-- `SpeedMultiplier` bands for the enemy's speed word.
local SLOW_BELOW = 0.8
local FAST_FROM = 1.25
local VERY_FAST_FROM = 2

--[[ INTERNAL ]]

--- "KorbloxSkeletonDefender" -> "Korblox Skeleton Defender".
local function splitCamel(name : string) : string
	return (string.gsub(name, "(%l)(%u)", "%1 %2"))
end

--- "BLIZZARD" -> "Blizzard".
local function titleCase(text : string) : string
	return (string.gsub(string.lower(text), "(%a)([%w']*)", function(first, rest)
		return string.upper(first) .. rest
	end))
end

local function percent(fraction : number) : string
	return `{math.floor(math.abs(fraction) * 100 + 0.5)}%`
end

local function weatherName(key : string) : string
	local display = WeatherConfig.Warning.DisplayNames[key]
	return if display then titleCase(display) else key
end

--- The unit's type(s), each in its color: "Melee", "Melee/Fire".
local function classText(class : any) : string?
	if class == nil then return nil end

	local classes = if typeof(class) == "table" then class else { class }
	local painted = {}

	for _, name in classes do
		table.insert(painted, paint(name, classColor(name)))
	end

	return table.concat(painted, "/")
end

--[=[
	The description: the name in bold (in `nameColor`, when it has one), then one
	paragraph per piece. Paragraphs are two `[br]`, not `[br=2]`: the plain version
	the size is measured from turns each `[br]` into one line break.
]=]
local function compose(name : string, nameColor : string?, lines : { string }) : string
	return `[b]{paint(name, nameColor)}[/b][br][br]{table.concat(lines, "[br][br]")}`
end

--[[ ENTRIES ]]

local function unitEntries()
	local entries = {}

	for key, stats in UnitStats do
		if typeof(stats) == "table" and stats.Rarity then
			local pair = CardConfig.IndexImages[key]

			table.insert(entries, {
				Key = key,
				Name = UNIT_NAMES[key] or key,
				Image = pair and pair.Unlocked,
				LockedImage = pair and pair.Locked,
				Order = RarityConfig.getOrder(stats.Rarity) or 0,
				Cost = stats.Cost or 0,
			})
		end
	end

	-- Weakest rarity first, then the cheaper unit.
	table.sort(entries, function(a, b)
		if a.Order ~= b.Order then return a.Order < b.Order end
		if a.Cost ~= b.Cost then return a.Cost < b.Cost end
		return a.Name < b.Name
	end)

	return entries
end

local function enemyEntries()
	local entries = {}

	for key, entity in Mob.Entities do
		table.insert(entries, {
			Key = key,
			Name = entity.DisplayName or splitCamel(key),
			Folder = entity.Folder,
			Order = table.find(DIFFICULTY_ORDER, entity.Folder) or #DIFFICULTY_ORDER + 1,
			Boss = entity.Boss == true,
			Health = entity.Health or 0,
		})
	end

	-- By difficulty, the boss closing its group, and the sturdier enemy later.
	table.sort(entries, function(a, b)
		if a.Order ~= b.Order then return a.Order < b.Order end
		if a.Boss ~= b.Boss then return b.Boss end
		if a.Health ~= b.Health then return a.Health < b.Health end
		return a.Name < b.Name
	end)

	return entries
end

local function weatherEntries()
	local entries = {}

	for key, image in WeatherConfig.Indicator.Icons do
		table.insert(entries, { Key = key, Name = weatherName(key), Image = image })
	end

	table.sort(entries, function(a, b)
		return a.Name < b.Name
	end)

	return entries
end

local function mapEntries()
	local entries = {}

	for key, map in MapConfig.MAPS do
		table.insert(entries, {
			Key = key,
			Name = map.DisplayName or key,
			Image = map.IndexImage or map.Image,
			PreviewImage = map.Image,
			Wins = map.WinsRequired or 0,
		})
	end

	-- The same order as the map picker: by the wins it asks for.
	table.sort(entries, function(a, b)
		if a.Wins ~= b.Wins then return a.Wins < b.Wins end
		return a.Name < b.Name
	end)

	return entries
end

--[=[
	One entry per skin in `SkinConfig`, in its `Order`. No `Image`: a skin is drawn as
	its 3D model (`Assets.Skins`), the silhouette while not owned.
]=]
local function skinEntries()
	local SkinConfig = SharedConfig.SkinConfig
	local entries = {}

	for _, id in SkinConfig.ordered() do
		local skin = SkinConfig.Skins[id]

		table.insert(entries, {
			Key = id,
			Name = skin.DisplayName or id,
			Unit = skin.Unit,
		})
	end

	return entries
end

local BUILDERS = {
	Units = unitEntries,
	Enemies = enemyEntries,
	Weathers = weatherEntries,
	Maps = mapEntries,
	Skins = skinEntries,
}

--[[ DESCRIPTIONS ]]

local function describeUnit(entry) : string
	local stats = UnitStats[entry.Key] or {}
	local lines = {}

	-- The rarity's own color, a little lighter: Common's deep blue disappears into the
	-- text's dark outline.
	local rarity = RarityConfig.getColor(stats.Rarity)
	local rarityColor = rgb(rarity and rarity:Lerp(Color3.new(1, 1, 1), RARITY_LIGHTEN))

	local header = { paint(tostring(stats.Rarity), rarityColor), classText(stats.Class) }
	table.insert(lines, table.concat(header, " - "))

	local behavior = UNIT_BEHAVIOR[entry.Key]
	if behavior then
		table.insert(lines, behavior)
	end

	table.insert(lines, `Cost: {paint(`${stats.Cost or 0}`, C.Cash)} - Range: {paint(tostring(stats.Range or 0), C.Range)}`)

	return compose(entry.Name, rarityColor, lines)
end

local function gimmickText(gimmick) : string?
	local threshold = paint(`At {percent(gimmick.Threshold or 0.5)} health`, C.Threshold)

	if gimmick.Type == "PerTurnSpeedMultiplier" then
		return if (gimmick.Amount or 0) > 0
			then `{paint("Speeds up", C.Fast)} at every turn of the path.`
			else `Starts {paint("fast", C.Fast)} and {paint("slows down", C.Slow)} at every turn of the path.`
	elseif gimmick.Type == "HealthThresholdStunRandomUnit" then
		return `{threshold}, stops and {paint(`stuns a random unit for {gimmick.StunDuration or 0}s`, C.Electric)}.`
	elseif gimmick.Type == "HealthThresholdRush" then
		return `{threshold}, {paint(`dashes forward for {gimmick.Duration or 0}s`, C.VeryFast)}.`
	end

	return nil
end

local function speedText(multiplier : number) : string
	if multiplier >= VERY_FAST_FROM then return paint("Very fast", C.VeryFast) end
	if multiplier >= FAST_FROM then return paint("Fast", C.Fast) end
	if multiplier < SLOW_BELOW then return paint("Slow", C.Slow) end
	return "Normal"
end

local function describeEnemy(entry) : string
	local entity = Mob.Entities[entry.Key] or {}
	local lines = {}

	local difficulty = paint(tostring(entity.Folder), C.Difficulties[entity.Folder])
	local header = if entity.Boss then `{paint("Boss", C.Boss)} of {difficulty}` else `Found on {difficulty}`
	table.insert(lines, header)
	table.insert(lines, `Base HP: {paint(tostring(entity.Health or 0), C.Health)} - Speed: {speedText(entity.SpeedMultiplier or 1)}`)

	if entity.Element then
		table.insert(lines, `Element: {paint(entity.Element, classColor(entity.Element))}`)
	end

	-- Positive is damage blocked, negative is extra damage taken.
	if typeof(entity.Resist) == "table" then
		local resists, weak = {}, {}

		for class, fraction in entity.Resist do
			if fraction > 0 then
				table.insert(resists, `{paint(class, classColor(class))} {percent(fraction)}`)
			elseif fraction < 0 then
				table.insert(weak, paint(class, classColor(class)))
			end
		end

		table.sort(resists)
		table.sort(weak)

		if #resists > 0 then table.insert(lines, `Resists: {table.concat(resists, ", ")}`) end
		if #weak > 0 then table.insert(lines, `Weak to: {table.concat(weak, ", ")}`) end
	end

	for _, gimmick in entity.Gimmicks or {} do
		local text = gimmickText(gimmick)
		if text then
			table.insert(lines, text)
		end
	end

	return compose(entry.Name, if entity.Boss then C.Boss else C.Difficulties[entity.Folder], lines)
end

--- The same effect lines, and colors, as the in-match weather indicator.
local function describeWeather(entry) : string
	local lines = {}

	for _, line in WeatherConfig.Indicator.Details[entry.Key] or WeatherConfig.Indicator.UnknownDetails do
		if typeof(line) == "table" then
			table.insert(lines, WeatherConfig.MarkupDetail(line.Text, line.Kind))
		else
			table.insert(lines, WeatherConfig.MarkupDetail(line))
		end
	end

	return compose(entry.Name, C.Weather, { table.concat(lines, "[br]") })
end

local function describeMap(entry) : string
	local lines = {}

	table.insert(lines, if entry.Wins > 0 then `Unlocks at {paint(`{entry.Wins} wins`, C.Wins)}.` else `Open from the {paint("start", C.Wins)}.`)

	local pool = WeatherConfig.MapPools[entry.Key]
	if pool and #pool > 0 then
		local names = {}
		for _, key in pool do
			table.insert(names, paint(weatherName(key), C.Weather))
		end

		table.insert(lines, `Weathers: {table.concat(names, ", ")}`)
	end

	return compose(entry.Name, nil, lines)
end

--- The unit the skin belongs to, in its rarity's color, its own description, and where to equip it.
local function describeSkin(entry) : string
	local skin = SharedConfig.SkinConfig.Get(entry.Key) or {}
	local stats = UnitStats[entry.Unit] or {}
	local rarity = RarityConfig.getColor(stats.Rarity)
	local rarityColor = rgb(rarity and rarity:Lerp(Color3.new(1, 1, 1), RARITY_LIGHTEN))
	local unitName = UNIT_NAMES[entry.Unit] or tostring(entry.Unit)

	local lines = {
		`Skin for the {paint(unitName, rarityColor)}`,
	}

	if typeof(skin.Description) == "string" and skin.Description ~= "" then
		table.insert(lines, skin.Description)
	end

	table.insert(lines, `Changes the tower's model and card art. Equip it from the {paint("Backpack", C.Cash)}.`)

	return compose(entry.Name, C.Magic, lines)
end

local DESCRIBERS = {
	Units = describeUnit,
	Enemies = describeEnemy,
	Weathers = describeWeather,
	Maps = describeMap,
	Skins = describeSkin,
}

--[[ API ]]

--- The category's entries, in page order. Built once: the configs do not change at runtime.
local cache = {}

function IndexCatalog.entries(category : string) : { any }
	if not cache[category] then
		local builder = BUILDERS[category]
		cache[category] = if builder then builder() else {}
	end

	return cache[category]
end

--- The preview's description for an entry, as `RichTextController` markup.
function IndexCatalog.describe(category : string, entry) : string
	local describer = DESCRIBERS[category]
	return if describer then describer(entry) else `[b]{entry.Name}[/b]`
end

return IndexCatalog
