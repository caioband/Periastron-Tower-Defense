--[[
	Peças comuns ao `LightingService` (servidor) e ao `LightingController`
	(cliente): achar a pasta de presets, ler valores de um preset e interpolar.

	Ver `SharedConfig.LightingConfig` para o formato de um preset.
]]

local Lighting = game:GetService("Lighting")
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

--[[ O BORRÃO DOS PAINÉIS ]]

--[=[
	O nome do `BlurEffect` que os painéis de UI compartilham.

	**Um só para todos**, e por isso ele é procurado antes de ser criado: o
	`UILibraryController` pendura o mesmo borrão para os painéis dele e as duas lojas
	do lobby o reaproveitam. Dois `BlurEffect` no Lighting somam, e o fundo sairia com
	o dobro do borrão quando dois painéis estivessem abertos.
]=]
LightingUtil.UI_BLUR_NAME = "UIBlur"

--[=[
	O borrão dos painéis, criado na primeira vez que alguém pede.

	Ele nasce (e renasce) com a marca do `KeepAttribute`: sem ela ele é um filho do
	Lighting que não pertence a preset nenhum, e a troca de preset o varreria. A marca
	é (re)escrita sempre, porque a instância pode ter vindo de outro sistema sem ela.
]=]
function LightingUtil.GetUIBlur(): BlurEffect
	local blur = Lighting:FindFirstChild(LightingUtil.UI_BLUR_NAME)

	if not blur or not blur:IsA("BlurEffect") then
		blur = Instance.new("BlurEffect")
		blur.Name = LightingUtil.UI_BLUR_NAME
		blur.Size = 0
		blur.Parent = Lighting
	end

	blur:SetAttribute(Config.KeepAttribute, true)

	return blur
end

--[=[
	Leva o borrão a `size` e devolve o tween, para quem chamou poder cancelá-lo.

	Cancelar é o que faz dois pedidos emendarem: `Tween:Cancel()` não devolve a
	propriedade, então fechar no meio da abertura desce a partir de onde a subida
	chegou em vez de as duas escreverem no mesmo `Size` ao mesmo tempo. Guarde o
	retorno num maid — um tween por painel de cada vez.

	Zerar o borrão quando ele nem existe devolve nil sem criar nada: um painel que
	fecha sem nunca ter aberto (o bind de uma `ScreenGui` nova roda o fechamento) não
	precisa deixar um `BlurEffect` por jogador no Lighting.
]=]
function LightingUtil.TweenUIBlur(size: number, info: TweenInfo): Tween?
	if size <= 0 and not Lighting:FindFirstChild(LightingUtil.UI_BLUR_NAME) then
		return nil
	end

	local tween = TweenService:Create(LightingUtil.GetUIBlur(), info, { Size = size })
	tween:Play()

	return tween
end

return LightingUtil
