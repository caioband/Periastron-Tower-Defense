local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local UIAssets = Assets:WaitForChild("UI")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("WeatherFeedbackController")

local WeatherConfig = SharedConfig.WeatherConfig
local CardModifier = SharedConfig.CardModifier

--[[
	The color of the tower a single-target card is about to take. It comes from
	`RoundCardConfig` because it is the same one aiming uses to highlight a card that
	changes no stat (see `RoundCardShopController:_hoverUnit`): a single yellow for
	"this one", wherever it comes from.
]]
local PREVIEW_COLOR = SharedConfig.RoundCardConfig.Targeting.Colors.Unit

--[[
	The billboard's vocabulary: the asset, the Highlight name, the colors, and the icon
	list. It lives in `WeatherConfig` by inheritance (weather was the first thing to
	draw on it), but it applies to both sources. See the header.
]]
local Config = WeatherConfig.Feedback

--[[
	What is affecting a unit, shown above it.

	Every affected unit gets two things:

	- a **Highlight** on the model, light blue when they help and red when they hurt;
	- a **billboard over the head** with one icon per changed stat: damage, range,
	  cooldown, and money.

	## There are three layers, and they multiply

	1. **Weather**, where all of this came from (`WeatherConfig.GetUnitMultiplier`);
	2. **round cards** already used, which left rules on the field (`CardModifier`, the
	   list `CardModifierController` keeps);
	3. **the preview**, a card the player is aiming *now* and has not used yet
	   (`SetPreview`).

	All three enter the same per-stat math, and the icon that lights is the **net
	effect**: a weather giving +30% damage with a card taking 20% lights the buff icon,
	not both at once. Adding icon lists instead of multiplying numbers would make the
	unit show buff and debuff for the same thing side by side, which means nothing.

	The icon order and each icon's name come from `WeatherConfig.Feedback.Stats`, which
	is the billboard's vocabulary, not a weather list. It is the same table weather
	uses, precisely so both sources speak the same language over the same head.

	Only the drawing comes from here: the math uses the same shared functions the server
	uses to apply the real effect. What the player sees and what they get in combat come
	from the same config line.

	Everything lives **inside the unit's model** (the Attachment on the head, the
	Highlight on the model itself), so selling the unit or restarting the round cleans
	it up too, without this controller needing to know. That is also why it looks up
	what it drew by name instead of keeping a table: there is no state to drift from
	what is in the Workspace.

	It is client only. No new event travels: weather changes arrive in
	`WeatherChanged`, the card list in `RoundCardModifiers`, and the rest is shared
	config.

	See docs/game/weather-in-match.md.
]]

local WeatherFeedbackController = {
	Controllers = {
		WeatherController = {},

		-- Keeps the list of cards in effect on the field and builds the `world` that
		-- neighborhood conditions need.
		CardModifierController = {},

		-- Base health, for the card that only applies below 20% of it.
		BaseHealthController = {},
	}
}

--[[
	The units on the map, so a weather change reaches all of them.

	Its own registry instead of reading `UnitPlacementController`'s `createdClasses`:
	that controller calls this one's `Apply`, and requesting it back would close a
	cycle in `Framework:Get`: each would wait for the other to load.

	A destroyed model leaves on the next sweep (`Parent == nil`), so selling and round
	restarts need not notify anything.
]]
WeatherFeedbackController.Units = {} :: { Model }

--[[
	Each model's `unitId`, handed over by `Register`.

	It comes from outside instead of being read from `createdClasses` for the same
	reason as the list above: `UnitPlacementController` calls `Register`, and
	requesting that controller back would close a cycle. It already has the id in hand
	when it registers.

	It serves one purpose, but an essential one: a single-target card (Bloxiade on a
	tower) only lights on the right tower if it can tell which tower is which.
]]
WeatherFeedbackController.UnitIds = {} :: { [Model] : string }

--[[
	Each unit's last drawing, as text.

	The preview is redone **every frame** while the player drags an area card's ring
	across the map, and almost every frame changes nothing: the tower that was inside
	the ring is still inside. Comparing the signature before writing is what turns
	"rewrite every tower's billboard 60 times a second" into "write when one actually
	enters or leaves".

	A destroyed model leaves this table in the same sweep that removes it from `Units`.
]]
WeatherFeedbackController.Signatures = {} :: { [Model] : string }

--[[
	The card the player is aiming now, if it affects any unit.

	`Records` is the list of modifiers the card *would* create if used where the cursor
	is: the same records as `RoundCardConfig`, with the zone already filled with the
	map point. `Unit` restricts the preview to a single model, which is the
	single-target card's case: without it, a `Target` record (which has no `UnitId`
	yet) would apply to the whole map.

	Nil when nobody is aiming.
]]
WeatherFeedbackController.Preview = nil

--[[ BILLBOARD ]]

--[=[
	The unit's billboard, creating it the first time.

	Returns `nil` for a unit with no head or without the asset: neither should happen,
	and in both cases the Highlight still goes on alone.
]=]
function WeatherFeedbackController:getBillboard(unitModel : Model) : Instance?
	local head = unitModel:FindFirstChild(Config.HeadName)
	if not head then return nil end

	local existing = head:FindFirstChild(Config.Asset)
	if existing then
		return existing
	end

	local asset = UIAssets:FindFirstChild(Config.Asset)
	if not asset then
		log:StudioWarnOnce(Config.Asset, string.format("could not find '%s' in Assets.UI.", Config.Asset))
		return nil
	end

	local clone = asset:Clone()

	--[[
		The authored `Adornee` points at a head that did not come with the clone, and a
		dead Adornee leaves the billboard without an anchor. Clearing it returns the
		BillboardGui to the Attachment that carries it, the fit the asset already ships.
	]]
	local gui = clone:FindFirstChildWhichIsA("BillboardGui")
	if gui then
		gui.Adornee = nil
	end

	clone.Parent = head

	return clone
end

--[=[
	Lights exactly the icons in `icons` and hides the rest.

	The list order becomes `LayoutOrder`: the asset's labels all start at 0, and on a
	tie `UIListLayout` falls back to alphabetical order, which would put damage after
	cooldown. Writing the order here makes the billboard always read damage, range,
	and cooldown in the same sequence, whether the unit has one icon or three.
]=]
function WeatherFeedbackController:setIcons(billboard : Instance, icons : { string })
	local gui = billboard:FindFirstChildWhichIsA("BillboardGui")
	local frame = gui and gui:FindFirstChildWhichIsA("Frame")
	if not frame then return end

	local wanted = {}
	for index, name in icons do
		wanted[name] = index
	end

	for _, label in frame:GetChildren() do
		if not label:IsA("ImageLabel") then continue end

		local order = wanted[label.Name]
		label.Visible = order ~= nil
		if order then
			label.LayoutOrder = order
			wanted[label.Name] = nil
		end
	end

	-- A request with no label left over: the icon has not been drawn in the asset yet.
	-- The unit keeps the Highlight and the other icons.
	for name in wanted do
		log:StudioWarnOnce(name, string.format("asset '%s' has no '%s' ImageLabel; that icon will not show.",
			Config.Asset, name))
	end
end

function WeatherFeedbackController:clearBillboard(unitModel : Model)
	local head = unitModel:FindFirstChild(Config.HeadName)
	local billboard = head and head:FindFirstChild(Config.Asset)
	if billboard then
		billboard:Destroy()
	end
end

--[[ HIGHLIGHT ]]

--[=[
	Paints the model with the state's color, creating the Highlight the first time.

	A single Highlight, recolored on changes: destroying and recreating it on every
	weather would make the unit blink, and it is the same Highlight that goes from blue
	to red when the weather changes from one that helped to one that hurts.
]=]
function WeatherFeedbackController:setHighlight(unitModel : Model, kind : string)
	-- `Preview` is not a unit state, it is the aim over it: the color comes from
	-- `RoundCardConfig`, not the weather's buff/debuff palette.
	local color = if kind == "Preview" then PREVIEW_COLOR else Config.Highlight[kind]
	if not color then return end

	local highlight = unitModel:FindFirstChild(Config.HighlightName)
	if not highlight then
		highlight = Instance.new("Highlight")
		highlight.Name = Config.HighlightName
		highlight.FillTransparency = Config.Highlight.Transparency
		highlight.OutlineTransparency = Config.Highlight.Transparency
		highlight.Parent = unitModel
	end

	highlight.FillColor = color
	highlight.OutlineColor = color
end

function WeatherFeedbackController:clearHighlight(unitModel : Model)
	local highlight = unitModel:FindFirstChild(Config.HighlightName)
	if highlight then
		highlight:Destroy()
	end
end

--[[ THE MATH ]]

--[=[
	Everything a unit's math needs, built once per sweep.

	The `world` (the map's unit list and base health) is expensive to build and the
	same for all units, and so is the card list. Building them per unit would redo the
	whole map once per tower, which is exactly the quadratic loop the preview, running
	every frame, cannot afford.
]=]
function WeatherFeedbackController:_context()
	local weatherController = self.Controllers.WeatherController
	local cards = self.Controllers.CardModifierController

	return {
		Weather = weatherController and weatherController:GetCurrent() or nil,
		Modifiers = cards and cards.Modifiers or nil,
		World = cards and cards:GetWorld() or nil,
		Preview = self.Preview,
	}
end

--[=[
	What this unit's billboard and Highlight should show: `Icons` and `Kind`, or `nil`
	when nothing is affecting it.

	Weather comes in through its function, cards through theirs, and the preview through
	the same function as the cards: all three per stat, multiplied. See the header.

	`Icons` comes out in `Feedback.Stats` order, the same order the billboard shows them.
	Only stats whose net multiplier moved off 1 enter: a weather that only changes
	range lights a single icon.

	`Kind` is **`Debuff` whenever there is a debuff**, even alongside a buff: the player
	finds the buff on the card, but the loss they need to notice from afar to react in
	time. A unit inside a staff's ring is exactly that case: it gains in one stat and
	pays in another.
]=]
function WeatherFeedbackController:_feedback(unitModel : Model, context)
	local unitName = unitModel.Name
	local weather = context.Weather

	--[[
		A unit turned off by weather has its own short answer: what it needs to say is
		"this one is not attacking". No card changes that (doubling a stopped tower's
		damage is still zero), so the math stops here.
	]]
	if weather
		and not WeatherConfig.IsImmune(weather, unitName)
		and WeatherConfig.IsDisabled(weather, unitName)
	then
		return { Icons = { Config.Disabled }, Kind = "Debuff" }
	end

	local unit = {
		UnitId = self.UnitIds[unitModel],
		UnitName = unitName,
		Position = unitModel:GetPivot().Position,
	}

	local preview = context.Preview
	local previewApplies = preview ~= nil and (preview.Unit == nil or preview.Unit == unitModel)

	-- The tower the pointer picked for a single-target card: its highlight is the
	-- aiming yellow, not the blue/red of what it will feel. See the `Kind`
	-- returned at the end.
	local isPreviewTarget = preview ~= nil and preview.Unit == unitModel

	local icons = {}
	local hasDebuff = false

	for _, entry in Config.Stats do
		local multiplier = 1

		for _, stat in entry.Stats do
			multiplier *= WeatherConfig.GetUnitMultiplier(weather, unitName, stat)
			multiplier *= CardModifier.Multiplier(context.Modifiers, stat, unit, context.World)

			if previewApplies then
				multiplier *= CardModifier.Multiplier(preview.Records, stat, unit, context.World)
			end
		end

		if multiplier == 1 then continue end

		if multiplier > 1 then
			table.insert(icons, entry.Buff)
		else
			table.insert(icons, entry.Debuff)
			hasDebuff = true
		end
	end

	--[=[
		The tower under the pointer turns yellow even with no icon.

		The yellow here is not "what it is feeling", it is "this is the one the card
		will take", and that must show before the card is used, even for a card that
		changes none of the billboard's stats. The icons, when there are any, still show
		what is coming.

		A single highlight on the tower, not two: `RoundCardShopController` does not draw
		its own when the card has a preview, precisely so the two colors do not fight
		on the same model.
	]=]
	if isPreviewTarget then
		return {
			Icons = icons,
			Kind = "Preview",
		}
	end

	if #icons == 0 then
		return nil
	end

	return {
		Icons = icons,
		Kind = if hasDebuff then "Debuff" else "Buff",
	}
end

--[[ API ]]

--[=[
	Puts (or removes) a unit's feedback.

	`context` comes from `Refresh` when the sweep covers the whole map; without it, it
	is built here, the single-unit case.

	The signature is compared before any write: rewriting the billboard with the same
	content changes nothing on screen and costs a label sweep per unit per frame while
	the preview is open.
]=]
function WeatherFeedbackController:Apply(unitModel : Model, context)
	if not unitModel or not unitModel.Parent then return end

	local feedback = self:_feedback(unitModel, context or self:_context())

	local signature = if feedback
		then feedback.Kind .. "|" .. table.concat(feedback.Icons, ",")
		else ""

	if self.Signatures[unitModel] == signature then
		return
	end

	self.Signatures[unitModel] = signature

	if not feedback then
		self:clearBillboard(unitModel)
		self:clearHighlight(unitModel)
		return
	end

	local billboard = self:getBillboard(unitModel)
	if billboard then
		self:setIcons(billboard, feedback.Icons)
	end

	self:setHighlight(unitModel, feedback.Kind)
end

--[=[
	Registers a just-placed unit and paints it right away.

	`UnitPlacementController` calls it at the end of `replicatePlacedUnit`: a player
	placing a unit mid-storm (or inside a staff's ring) must see it affected
	immediately, not only at the next weather change.

	The whole map is repainted too, not just it: two cards measure the **neighborhood**
	(Iceolated rewards the lone tower, Ice to Meet You punishes those near ice), so a
	new tower changes what its neighbors are feeling.
]=]
function WeatherFeedbackController:Register(unitModel : Model, unitId : string?)
	if not unitModel then return end

	table.insert(self.Units, unitModel)
	self.UnitIds[unitModel] = unitId

	self:Refresh()
end

--[=[
	Repaints the whole map. It is the step for a weather change, a card used, and each
	preview frame.

	The sweep also drops units that already left the Workspace, which is what keeps
	selling and round restarts from needing to notify anything.
]=]
function WeatherFeedbackController:Refresh()
	local context = self:_context()

	for index = #self.Units, 1, -1 do
		local unitModel = self.Units[index]

		if not unitModel or not unitModel.Parent then
			table.remove(self.Units, index)

			if unitModel then
				self.UnitIds[unitModel] = nil
				self.Signatures[unitModel] = nil
			end

			continue
		end

		self:Apply(unitModel, context)
	end
end

--[=[
	Shows on the units what a card **not yet used** would do to them.

	`records` are the modifiers the card would create, with the zone already filled with
	the map point under the cursor; `unitModel` restricts the preview to a single tower,
	the single-target card's case.

	It is the same drawing as the real effect, on purpose: the player drags the ring
	across the map and reads, over the towers' heads, exactly what will happen to them if
	they release there. A second drawing for "what will happen" would force them to
	learn two languages for the same information.

	Called every frame while aiming is open: `Apply` compares the signature before
	writing, so a frame that changes nothing costs nothing.
]=]
function WeatherFeedbackController:SetPreview(records : { any }?, unitModel : Model?)
	if not records or #records == 0 then
		self:ClearPreview()
		return
	end

	self.Preview = { Records = records, Unit = unitModel }
	self:Refresh()
end

--- Removes the preview and returns units to what they are actually feeling.
function WeatherFeedbackController:ClearPreview()
	if not self.Preview then return end

	self.Preview = nil
	self:Refresh()
end

--[[ LIFECYCLE ]]

function WeatherFeedbackController:construct()
	--[[
		`WeatherController` also listens to this event to store the current weather, and
		the order between the two is not guaranteed. One deferred step is enough:
		`GetCurrent` already answers the new weather when `Refresh` runs.
	]]
	Framework:Listen("WeatherChanged", function()
		task.defer(function()
			self:Refresh()
		end)
	end)

	--[[
		A card entered the field, or one expired. `task.defer` for the same reason as
		weather: `CardModifierController` also listens to this event to store the list,
		and nothing promises the order between the two.
	]]
	Framework:Listen("RoundCardModifiers", function()
		task.defer(function()
			self:Refresh()
		end)
	end)

	--[[
		Base health crossed some threshold: No Pain, No Gain only applies below 20%, and
		it is the only thing that turns a buff on and off without anyone clicking
		anything.

		No "crossed or not" filter: the base only changes when an enemy leaks, and
		`Apply` already bails out on its own when the drawing did not change.
	]]
	Framework:Listen("UpdateBaseHealth", function()
		task.defer(function()
			self:Refresh()
		end)
	end)
end

function WeatherFeedbackController:start()
end

function WeatherFeedbackController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return WeatherFeedbackController
