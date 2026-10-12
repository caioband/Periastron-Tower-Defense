local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)
local SharedConfig = require(Configs.SharedConfig)

local Framework = Me.new()

local SkinConfig = SharedConfig.SkinConfig
local CardConfig = SharedConfig.CardConfig
local UnitStats = SharedConfig.UnitStats

local CARD_NAME = "Card"
local UNIT_NAME_NAME = "UnitName"

--[=[
	The card art of an equipped skin, in every place.

	`CardConfig.GetImage` and `GetIcon` are wrapped on this client so every caller that
	already asks them (the Loadout, the match hotbar, the upgrade card portrait, the
	round card shop) gets the skin's art for the local player's equipped units without
	being edited. What the player wears comes from their `EquippedSkins` attribute,
	which `SkinService` publishes.

	When it changes, cards already on screen for the affected units are redrawn here,
	since those callers only write the art when a card is created.
]=]
local SkinArtController = {
	Signals = {
		-- (changedUnits : { [string] : true })
		Changed = Signal.new(),
	},
}

--[[ INTERNAL ]]

function SkinArtController:_patch()
	if CardConfig.__SkinPatched then
		return
	end

	CardConfig.__SkinPatched = true

	local getImage = CardConfig.GetImage
	local getIcon = CardConfig.GetIcon

	CardConfig.GetImage = function(unitName)
		local skin = self:GetSkin(unitName)
		return (skin and SkinConfig.nonEmpty(skin.Card)) or getImage(unitName)
	end

	CardConfig.GetIcon = function(unitName)
		local skin = self:GetSkin(unitName)
		return (skin and SkinConfig.nonEmpty(skin.Icon)) or getIcon(unitName)
	end
end

function SkinArtController:_unitOf(image : GuiObject) : string?
	local unit = image:GetAttribute("Unit")
	if typeof(unit) == "string" then
		return unit
	end

	if image.Name ~= CARD_NAME then
		return nil
	end

	local parent = image.Parent
	if parent and UnitStats[parent.Name] then
		return parent.Name
	end

	local label = image:FindFirstChild(UNIT_NAME_NAME)
	if label and label:IsA("TextLabel") and UnitStats[label.Text] then
		return label.Text
	end

	return nil
end

function SkinArtController:_redraw(changed : { [string] : true })
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	for _, descendant in playerGui:GetDescendants() do
		if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			local unit = self:_unitOf(descendant)
			if unit and changed[unit] then
				local image = CardConfig.GetImage(unit)
				if image then
					descendant.Image = image
				end
			end
		end
	end
end

function SkinArtController:_read()
	local previous = self.Equipped
	local current = SkinConfig.decodeEquipped(Players.LocalPlayer:GetAttribute(SkinConfig.ATTRIBUTE))

	local changed = {}
	local any = false

	for unit, id in current do
		if previous[unit] ~= id then
			changed[unit] = true
			any = true
		end
	end

	for unit in previous do
		if current[unit] == nil then
			changed[unit] = true
			any = true
		end
	end

	self.Equipped = current

	if any then
		self:_redraw(changed)
		self.Signals.Changed:Fire(changed)
	end
end

--[[ EXTERNAL ]]

function SkinArtController:GetSkin(unitName : string?)
	if typeof(unitName) ~= "string" then
		return nil
	end

	return SkinConfig.Get(self.Equipped[unitName])
end

function SkinArtController:GetEquippedId(unitName : string) : string?
	return self.Equipped[unitName]
end

function SkinArtController:start()
	local player = Players.LocalPlayer

	self.Maid:GiveTask(player:GetAttributeChangedSignal(SkinConfig.ATTRIBUTE):Connect(function()
		self:_read()
	end))

	self:_read()
end

function SkinArtController:init()
	self.Maid = Maid.new()
	self.Equipped = {}
	self:_patch()
end

return SkinArtController