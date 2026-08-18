local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)
local LightingUtil = require(Utils.LightingUtil)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.LightingConfig

-- Log da troca: so no Studio, para nao poluir o console de producao. Existe porque
-- "o preset foi aplicado" nao da para conferir olhando o Lighting depois — se um
-- preset nao declara atributo nenhum, o resultado correto e nada mudar.
local IS_STUDIO = RunService:IsStudio()

local function lightingPrint(...)
	if not IS_STUDIO then return end
	print("[LightingService]", ...)
end

--[[
	Troca de preset de Lighting.

	Um preset é uma Folder em `ReplicatedStorage.Shared.Assets.Lighting`: os
	atributos dela viram propriedades do `Lighting`, os filhos viram as instâncias
	dentro dele (Sky, Atmosphere, ColorCorrection…). `Apply` clona a pasta, limpa o
	Lighting e joga o conteúdo do clone lá dentro.

	O corte aqui é seco, de propósito — o servidor é a verdade e quem entra no meio
	da partida tem que receber o estado final direto. Quem suaviza é o
	`LightingController`, no cliente.

		local Lighting = Framework:Get("LightingService")

		Lighting:Apply("Blizzard")        -- transição no tempo padrão
		Lighting:Apply("Foggy", 4)        -- transição de 4s
		Lighting:Apply("Foggy", 0)        -- sem transição

	Fica em `common/` porque as duas places usam.
]]

local LightingService = {
	Services = {},
}

LightingService.Current = nil :: string?
LightingService.Root = nil :: Folder?

-- O preset atual teve o conteúdo trocado por um `Register`: o próximo `Apply`
-- nele tem que valer, em vez de cair no atalho de "já é esse".
LightingService._dirty = false

--[[ MONTAGEM ]]

--[[
	Folder solta dentro do Lighting é preset autorado na place (é assim que a
	Main Game guarda `FoggyLightning` e `BlizzardLightning`). Elas precisam sair de
	lá: o clear do `Apply` levaria as duas junto, e o cliente não conseguiria ler os
	valores de origem da transição de dentro do `Lighting`.
]]
function LightingService:_migrateAuthoredPresets(root: Folder)
	for _, child in Lighting:GetChildren() do
		if not child:IsA("Folder") then continue end
		if child:GetAttribute(Config.KeepAttribute) == true then continue end

		if root:FindFirstChild(child.Name) then
			warn(`[LightingService]: já existe o preset "{child.Name}" em Assets.Lighting; a Folder de mesmo nome dentro do Lighting foi ignorada.`)
			continue
		end

		child.Parent = root
	end
end

--[[
	Monta o preset baseline a partir do Lighting que veio autorado na place: as
	propriedades atuais viram atributos, o que sobrou de filho vira clone dentro
	dele.

	Sem isto a primeira troca não teria de onde tweenar: o cliente lê os valores de
	origem do preset anterior, e antes da primeira chamada não existiria nenhum.
]]
function LightingService:_captureBaseline(root: Folder): string
	local name = Config.BaselineName

	if root:FindFirstChild(name) then
		return name
	end

	local folder = Instance.new("Folder")
	folder.Name = name

	for propertyName, value in LightingUtil.ReadInstance(Lighting) do
		folder:SetAttribute(propertyName, value)
	end

	-- O que é marcado para sobreviver ao clear fica de fora: ele já vai estar lá
	-- quando o baseline for reaplicado, e entrar no preset também viraria duplicata.
	for _, child in Lighting:GetChildren() do
		if child:GetAttribute(Config.KeepAttribute) == true then continue end
		child:Clone().Parent = folder
	end

	folder.Parent = root
	return name
end

function LightingService:_setup()
	if self.Root then return end

	local root = LightingUtil.GetPresetsRoot(true)
	if not root then
		warn("[LightingService]: não consegui criar a pasta de presets; o service fica inerte.")
		return
	end

	self.Root = root
	self:_migrateAuthoredPresets(root)
	self.Current = self:_captureBaseline(root)
end

--[[ API ]]

function LightingService:GetPreset(name: string): Folder?
	self:_setup()

	local root = self.Root
	if not root then return nil end

	local preset = root:FindFirstChild(name)
	if not preset or not preset:IsA("Folder") then
		return nil
	end

	return preset
end

function LightingService:GetCurrent(): string?
	self:_setup()
	return self.Current
end

--[[
	Registra como preset uma Folder que está fora de `Assets.Lighting` — a pasta
	`Lighting` de um mapa em `ServerStorage`, por exemplo.

	O clone para a pasta de presets é o que faz a transição existir: `ServerStorage`
	não replica, então sem isto o cliente não teria de onde ler os valores de
	destino. Devolve o nome com que o preset ficou registrado, para passar ao `Apply`.
]]
function LightingService:Register(folder: Instance, name: string?): string?
	self:_setup()

	local root = self.Root
	if not root then return nil end

	if not folder:IsA("Folder") then
		warn(`[LightingService]: "{folder:GetFullName()}" não é uma Folder; não dá para registrar como preset.`)
		return nil
	end

	local presetName = name or folder.Name

	local existing = root:FindFirstChild(presetName)
	if existing then
		existing:Destroy()
	end

	local clone = folder:Clone()
	clone.Name = presetName
	clone.Parent = root

	if presetName == self.Current then
		self._dirty = true
	end

	return presetName
end

--[[
	Deixa o Lighting igual ao preset e avisa os clientes.

	`transitionTime` só viaja para o cliente — aqui a troca é sempre imediata.
	`0` pede corte seco também no cliente.

	`force` reaplica mesmo que o preset já seja o atual, para quem acabou de mexer
	no conteúdo da pasta e quer ver o resultado (é o que o comando `lighting` faz).
]]
function LightingService:Apply(name: string, transitionTime: number?, force: boolean?): boolean
	local preset = self:GetPreset(name)
	if not preset then
		warn(`[LightingService]: preset "{name}" não existe em Assets.Lighting.`)
		return false
	end

	if name == self.Current and not self._dirty and not force then
		return true
	end
	self._dirty = false

	local clone = preset:Clone()
	if not clone then
		-- `Archivable = false` na pasta faz o Clone devolver nil.
		warn(`[LightingService]: preset "{name}" não é clonável (Archivable = false?); nada foi aplicado.`)
		return false
	end

	local removed = 0
	for _, child in Lighting:GetChildren() do
		if child:GetAttribute(Config.KeepAttribute) ~= true then
			child:Destroy()
			removed += 1
		end
	end

	local added = {}
	for _, child in clone:GetChildren() do
		child.Parent = Lighting
		table.insert(added, `{child.Name} ({child.ClassName})`)
	end
	clone:Destroy()

	-- Propriedade que o preset não declara fica como estava: um preset pode mexer
	-- só na neblina sem ter que repetir a iluminação inteira.
	local written = {}
	for propertyName, value in LightingUtil.ReadPresetAttributes(preset) do
		local ok, err = pcall(function()
			(Lighting :: any)[propertyName] = value
		end)

		if ok then
			table.insert(written, propertyName)
		else
			warn(`[LightingService]: preset "{name}" não conseguiu escrever Lighting.{propertyName}: {err}`)
		end
	end

	--[[
		Vale logar mesmo quando deu tudo certo: sem isto, "aplicou e não mudou nada"
		e "não aplicou" ficam idênticos no console — e um preset sem atributo nenhum
		produz o primeiro caso de forma totalmente legítima.
	]]
	lightingPrint(string.format('preset "%s" aplicado | %d propriedade(s) do Lighting: %s | %d instância(s) dentro: %s | %d removida(s)',
		name,
		#written, #written > 0 and table.concat(written, ", ") or "nenhuma (a pasta não declara atributos)",
		#added, #added > 0 and table.concat(added, ", ") or "nenhuma",
		removed))

	if #written == 0 and #added == 0 then
		warn(`[LightingService]: preset "{name}" está vazio — sem atributos e sem filhos, aplicar não muda nada.`)
	end

	local previous = self.Current
	self.Current = name

	local duration = transitionTime or Config.Transition.Time
	for _, player in Players:GetPlayers() do
		Framework:Fire("LightingApplied", player, previous, name, duration)
	end

	return true
end

--[[ CICLO DE VIDA ]]

function LightingService:construct()
	-- Cliente perguntando com que preset ele deve começar: responde sem transição,
	-- porque o Lighting dele já chegou replicado no estado final.
	Framework:Listen("RequestLighting", function(player)
		local current = self:GetCurrent()
		if not current then return end

		Framework:Fire("LightingApplied", player, current, current, 0)
	end)
end

function LightingService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:_setup()
	self:construct()

	if Config.DefaultPreset then
		self:Apply(Config.DefaultPreset, 0)
	end
end

function LightingService:init()
	Framework:Listen("LightingApplied", function() end)
end

return LightingService
