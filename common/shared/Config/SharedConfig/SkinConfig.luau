local HttpService = game:GetService("HttpService")

local SkinConfig = {}

SkinConfig.PROFILE_KEY = "Skins"
SkinConfig.ATTRIBUTE = "EquippedSkins"
SkinConfig.MODEL_FOLDER = "Skins"

SkinConfig.Skins = {
	AwesomeSkin = {
		Unit = "Sword",
		DisplayName = "Awesome Skin",
		Description = "test skin lol",		
		Image = "rbxassetid://82984850115176",
		Card = "rbxassetid://82984850115176",
		Icon = "rbxassetid://82984850115176",
		Model = "AwesomeSkin",
		Order = 1,
	},
}

function SkinConfig.Get(id : any)
	if typeof(id) ~= "string" then
		return nil
	end

	return SkinConfig.Skins[id]
end

function SkinConfig.createEmpty()
	return { Owned = {}, Equipped = {} }
end

function SkinConfig.sanitize(raw : any)
	local clean = SkinConfig.createEmpty()
	if typeof(raw) ~= "table" then
		return clean
	end

	if typeof(raw.Owned) == "table" then
		for id, owned in raw.Owned do
			if typeof(id) == "string" and owned == true then
				clean.Owned[id] = true
			end
		end
	end

	if typeof(raw.Equipped) == "table" then
		for unitName, id in raw.Equipped do
			local skin = SkinConfig.Get(id)
			if skin and skin.Unit == unitName and clean.Owned[id] then
				clean.Equipped[unitName] = id
			end
		end
	end

	return clean
end

function SkinConfig.ordered() : { string }
	local ids = {}
	for id in SkinConfig.Skins do
		table.insert(ids, id)
	end

	table.sort(ids, function(a, b)
		local orderA = SkinConfig.Skins[a].Order or 0
		local orderB = SkinConfig.Skins[b].Order or 0
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a < b
	end)

	return ids
end

function SkinConfig.decodeEquipped(value : any) : { [string] : string }
	local result = {}
	if typeof(value) ~= "string" or value == "" then
		return result
	end

	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, value)
	if not ok or typeof(decoded) ~= "table" then
		return result
	end

	for unitName, id in decoded do
		local skin = SkinConfig.Get(id)
		if typeof(unitName) == "string" and skin and skin.Unit == unitName then
			result[unitName] = id
		end
	end

	return result
end

function SkinConfig.nonEmpty(value : any) : string?
	return if typeof(value) == "string" and value ~= "" then value else nil
end

return SkinConfig