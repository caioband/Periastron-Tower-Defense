--[[
	Peças comuns ao `LightingService` (servidor) e ao `LightingController`
	(cliente): achar a pasta de presets, ler valores de um preset e interpolar.

	Ver `SharedConfig.LightingConfig` para o formato de um preset.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Config = SharedConfig.LightingConfig

local LightingUtil = {}

--[[ PASTA DE PRESETS ]]

--[[
	Acha (servidor) ou espera (cliente) a pasta de presets.

	`create` só é verdadeiro no servidor: `Assets` é conteúdo da place, não passa
	pelo Rojo, então a subpasta `Lighting` pode simplesmente não existir ainda.
]]
function LightingUtil.GetPresetsRoot(create: boolean?, timeout: number?): Folder?
	local current: Instance = ReplicatedStorage

	for _, name in Config.PresetsPath do
		local nextChild = current:FindFirstChild(name)

		if not nextChild and create then
			local folder = Instance.new("Folder")
			folder.Name = name
			folder.Parent = current
			nextChild = folder
		elseif not nextChild then
			nextChild = current:WaitForChild(name, timeout or 30)
		end

		if not nextChild then
			return nil
		end

		current = nextChild
	end

	return current :: Folder
end

--[[ LEITURA ]]

--[[
	Valores das propriedades de uma instância de preset (Sky, Atmosphere, efeito…).

	Lê só o que está listado em `LightingConfig.Properties` para a classe dela; o
	`pcall` cobre propriedade que a engine tenha removido ou trancado numa versão
	nova, sem derrubar a transição inteira por causa de uma.
]]
function LightingUtil.ReadInstance(instance: Instance): { [string]: any }
	local values = {}

	for _, propertyName in Config:GetProperties(instance.ClassName) do
		local ok, value = pcall(function()
			return (instance :: any)[propertyName]
		end)

		if ok then
			values[propertyName] = value
		end
	end

	return values
end

--[[
	Propriedades do próprio Lighting que o preset declara — que são os atributos da
	Folder. Atributo com nome fora da lista de `LightingConfig` é ignorado (pode ser
	anotação de quem montou o preset).
]]
function LightingUtil.ReadPresetAttributes(folder: Instance): { [string]: any }
	local attributes = folder:GetAttributes()
	local values = {}

	for _, propertyName in Config:GetProperties("Lighting") do
		if attributes[propertyName] ~= nil then
			values[propertyName] = attributes[propertyName]
		end
	end

	return values
end

--[[ INTERPOLAÇÃO ]]

--[[
	Tipos que sabem virar meio-caminho. O resto (boolean, string, EnumItem,
	NumberSequence, ColorSequence) não interpola e é aplicado de uma vez — ver
	`LightingController`, que decide o momento do corte.
]]
local INTERPOLATORS: { [string]: (any, any, number) -> any } = {
	number = function(a, b, t)
		return a + (b - a) * t
	end,

	Color3 = function(a, b, t)
		return a:Lerp(b, t)
	end,

	Vector2 = function(a, b, t)
		return a:Lerp(b, t)
	end,

	Vector3 = function(a, b, t)
		return a:Lerp(b, t)
	end,

	CFrame = function(a, b, t)
		return a:Lerp(b, t)
	end,

	UDim2 = function(a, b, t)
		return a:Lerp(b, t)
	end,

	UDim = function(a, b, t)
		return UDim.new(a.Scale + (b.Scale - a.Scale) * t, a.Offset + (b.Offset - a.Offset) * t)
	end,

	NumberRange = function(a, b, t)
		return NumberRange.new(a.Min + (b.Min - a.Min) * t, a.Max + (b.Max - a.Max) * t)
	end,

	Rect = function(a, b, t)
		return Rect.new(a.Min:Lerp(b.Min, t), a.Max:Lerp(b.Max, t))
	end,
}

-- A interpolação só existe entre dois valores do mesmo tipo interpolável.
function LightingUtil.GetInterpolator(from: any, to: any): ((any, any, number) -> any)?
	local fromType = typeof(from)
	if fromType ~= typeof(to) then
		return nil
	end

	return INTERPOLATORS[fromType]
end

-- Curva de easing sem criar Tween: `GetValue` é a mesma conta que o TweenService faz.
function LightingUtil.Ease(alpha: number): number
	return TweenService:GetValue(math.clamp(alpha, 0, 1), Config.Transition.Style, Config.Transition.Direction)
end

return LightingUtil
