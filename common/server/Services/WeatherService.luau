local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.WeatherConfig

-- Log da troca: só no Studio. Mesmo motivo do LightingService — encaixar a Part
-- num mapa sem `Terrain` produz um resultado legítimo mas surpreendente, e sem os
-- números não dá para saber qual caixa foi medida.
local IS_STUDIO = RunService:IsStudio()

local function weatherPrint(...)
	if not IS_STUDIO then return end
	print("[WeatherService]", ...)
end

--[[
	Clima do mapa em jogo.

	Um clima é um Model em `Assets.Weathers` com uma Part de partículas e uma pasta
	`Lighting`. Este service encaixa a Part no mapa carregado e entrega a pasta ao
	`LightingService`, que é quem muda a iluminação — então o clima herda de graça a
	transição interpolada de lá.

		local Weather = Framework:Get("WeatherService")

		Weather:Apply("Snow")        -- transição no tempo padrão do Lighting
		Weather:Apply("Thunder", 4)  -- em 4s
		Weather:Clear()              -- tira, e devolve a iluminação de antes

	Fica em `common/` porque o Weathers é compartilhado. Na prática só a Game tem
	`workspace.Map`, e sem mapa o `Apply` recusa dizendo isso.
]]

local WeatherService = {
	Services = {
		LightingService = {}
	}
}

WeatherService.Current = nil :: string?
WeatherService.Container = nil :: Folder?

--[[
	Preset de iluminação de antes do clima, para o `Clear` ter para onde voltar.
	Só é gravado na primeira aplicação: trocar de clima não pode fazer o "antes"
	virar o clima anterior.
]]
WeatherService.RestorePreset = nil :: string?

--[[
	Avisa os clientes de qual clima está no ar.

	Quem escuta é o `WeatherController`, para o som de fundo entrar e sair junto —
	as partículas e a iluminação chegam sozinhas (replicação e `LightingApplied`),
	mas áudio é local de cada cliente.
]]
local function broadcastWeather(name: string?)
	for _, player in Players:GetPlayers() do
		Framework:Fire("WeatherChanged", player, name)
	end
end

--[[ CAIXA DO MAPA ]]

--[[
	AABB de uma Part, respeitando a rotação dela.

	`Position ± Size/2` só valeria para Part alinhada aos eixos, e terreno girado é
	comum. A meia-extensão do AABB de uma caixa girada é `|R| * meioTamanho`, que é
	o que as linhas abaixo fazem.
]]
local function partBounds(part: BasePart): (Vector3, Vector3)
	local cf, size = part.CFrame, part.Size
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2

	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()

	local extent = Vector3.new(
		math.abs(r00) * hx + math.abs(r01) * hy + math.abs(r02) * hz,
		math.abs(r10) * hx + math.abs(r11) * hy + math.abs(r12) * hz,
		math.abs(r20) * hx + math.abs(r21) * hy + math.abs(r22) * hz
	)

	return cf.Position - extent, cf.Position + extent
end

--[[
	Menor caixa que cobre as BaseParts de `sources`, descartando as maiores que
	`maxFootprint` em X ou Z. Devolve também quantas foram descartadas.
]]
local function measureIn(sources: { Instance }, maxFootprint: number): (Vector3?, Vector3?, number)
	local minV, maxV
	local skipped = 0

	for _, source in sources do
		for _, descendant in source:GetDescendants() do
			if not descendant:IsA("BasePart") then continue end

			if descendant.Size.X > maxFootprint or descendant.Size.Z > maxFootprint then
				skipped += 1
				continue
			end

			local lo, hi = partBounds(descendant)
			minV = if minV then minV:Min(lo) else lo
			maxV = if maxV then maxV:Max(hi) else hi
		end
	end

	return minV, maxV, skipped
end

--[=[
	Caixa do mapa: centro, tamanho e uma etiqueta do que foi medido.

	`wholeMap` escolhe o que conta, e a diferença é a própria semântica das tags:

	- **Sky** mede o mapa inteiro, cenário de fundo incluído. A camada de céu cobre
	  tudo que se vê, e o chão pintado até o horizonte faz parte disso — cobrir só a
	  área jogável deixaria uma mancha de 93 studs sobre um mundo visível de 2048. O
	  pico sai daqui também: é "o ponto mais alto do mapa carregado", sem recorte.
	- **Area** mede só `BoundsFolders`, e ainda descarta as parts maiores que
	  `MaxPartFootprint`. Neve e chuva acontecem onde se joga; medir o fundo daria uma
	  caixa 20x maior e espalharia as partículas até sumirem.
]=]
function WeatherService:GetMapBounds(target: Instance, wholeMap: boolean?): (Vector3?, Vector3?, string)
	--[[
		Caixa autorada no mapa manda, nos dois tipos de clima. Ela é exata, enquanto
		medir o mapa depende de adivinhar o que é cenário de fundo — e as duas
		heurísticas abaixo erram justamente nos mapas em que o fundo mora dentro do
		`Terrain` (o `Volcano` calculado dá 500x500; a caixa dele tem 147x109).

		Rotação é ignorada: as caixas são alinhadas aos eixos.
	]]
	local authored = target:FindFirstChild(Config.BoundsPartName)
	if authored and authored:IsA("BasePart") then
		return authored.Position, authored.Size, Config.BoundsPartName
	end

	if wholeMap then
		local minV, maxV = measureIn({ target }, math.huge)
		if not minV or not maxV then
			return nil, nil, "mapa inteiro"
		end

		return (minV + maxV) / 2, maxV - minV, "mapa inteiro"
	end

	local sources = {}
	for _, folderName in Config.BoundsFolders do
		local folder = target:FindFirstChild(folderName)
		if folder then
			table.insert(sources, folder)
		end
	end

	local measured = table.concat(Config.BoundsFolders, "+")
	if #sources == 0 then
		sources = { target }
		measured = target.Name .. " inteiro"
	end

	local minV, maxV, skipped = measureIn(sources, Config.MaxPartFootprint)

	-- Nada de pé depois do corte: um mapa pequeno feito de uma part só ainda tem
	-- que funcionar.
	if not minV or not maxV then
		minV, maxV = measureIn(sources, math.huge)
		measured ..= " (sem corte de fundo)"
	elseif skipped > 0 then
		measured ..= string.format(" (-%d fundo)", skipped)
	end

	if not minV or not maxV then
		return nil, nil, measured
	end

	return (minV + maxV) / 2, maxV - minV, measured
end

--[[ ENCAIXE ]]

function WeatherService:_getPart(model: Model): BasePart?
	local part = model:FindFirstChild(Config.PartName)
	if part and part:IsA("BasePart") then
		return part
	end

	return model:FindFirstChildWhichIsA("BasePart")
end

--[=[
	A Part vem do asset com `CanCollide = true`. Esticada para cobrir o mapa, ela
	viraria uma parede invisível em cima da área jogável — e com `CanQuery` ligado o
	raycast dos passos e a validação de posicionamento de unidade bateriam nela.
]=]
local function makeIntangible(instance: Instance)
	for _, part in instance:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
		end
	end
end

--[=[
	Encaixa a Part do clima na caixa do mapa, do jeito que a tag do Model pedir.
	Devolve uma descrição do que fez, para o log e para a resposta do comando.
]=]
function WeatherService:_fit(model: Model, center: Vector3, size: Vector3): string?
	local part = self:_getPart(model)
	if not part then
		return nil
	end

	if CollectionService:HasTag(model, Config.Tags.Area) then
		part.Size = size
		part.CFrame = CFrame.new(center)

		return string.format("área %.0fx%.0fx%.0f em (%.0f, %.0f, %.0f)",
			size.X, size.Y, size.Z, center.X, center.Y, center.Z)
	end

	if CollectionService:HasTag(model, Config.Tags.Sky) then
		-- A espessura da camada é a autorada; o que acompanha o mapa é X e Z.
		local thickness = part.Size.Y
		local offset = model:GetAttribute(Config.HeightOffsetAttribute) or Config.SkyHeightOffset
		local peak = center.Y + size.Y / 2

		part.Size = Vector3.new(size.X, thickness, size.Z)
		part.CFrame = CFrame.new(center.X, peak + offset, center.Z)

		return string.format("céu %.0fx%.0f (espessura %.0f) em (%.0f, %.0f, %.0f) — centro do mapa, %.0f acima do pico %.0f",
			size.X, size.Z, thickness,
			part.CFrame.Position.X, part.CFrame.Position.Y, part.CFrame.Position.Z,
			offset, peak)
	end

	return nil
end

--[[ API ]]

function WeatherService:GetContainer(): Folder
	local container = self.Container
	if container and container.Parent then
		return container
	end

	container = workspace:FindFirstChild(Config.ContainerName) :: Folder
	if not container then
		local folder = Instance.new("Folder")
		folder.Name = Config.ContainerName
		folder.Parent = workspace
		container = folder
	end

	self.Container = container
	return container
end

function WeatherService:GetRoot(): Folder?
	local current: Instance? = ReplicatedStorage

	for _, name in Config.AssetsPath do
		if not current then return nil end
		current = current:FindFirstChild(name)
	end

	return current :: Folder?
end

function WeatherService:GetWeather(name: string): Model?
	local root = self:GetRoot()
	if not root then return nil end

	local model = root:FindFirstChild(name)
	if not model or not model:IsA("Model") then
		return nil
	end

	return model
end

function WeatherService:GetNames(): { string }
	local names = {}

	local root = self:GetRoot()
	if not root then
		return names
	end

	for _, model in root:GetChildren() do
		if model:IsA("Model") then
			table.insert(names, model.Name)
		end
	end

	table.sort(names)
	return names
end

function WeatherService:GetCurrent(): string?
	return self.Current
end

--[=[
	Liga o clima no mapa carregado.

	`transitionTime` é repassado ao LightingService; `0` corta seco. Devolve
	`(ok, mensagem)` — a mensagem é o que o comando mostra.
]=]
function WeatherService:Apply(name: string, transitionTime: number?): (boolean, string)
	local model = self:GetWeather(name)
	if not model then
		return false, string.format("o clima '%s' não existe em Assets.Weathers.", name)
	end

	local isArea = CollectionService:HasTag(model, Config.Tags.Area)
	local isSky = CollectionService:HasTag(model, Config.Tags.Sky)
	if not isArea and not isSky then
		return false, string.format("o clima '%s' não tem a tag %s nem %s.", name, Config.Tags.Area, Config.Tags.Sky)
	end

	local target = workspace:FindFirstChild(Config.TargetName)
	if not target then
		return false, string.format("não há nenhum '%s' no Workspace para encaixar o clima.", Config.TargetName)
	end

	-- Sky mede o mapa inteiro, Area só a área jogável. Ver `GetMapBounds`.
	local center, size, measured = self:GetMapBounds(target, isSky)
	if not center or not size then
		return false, string.format("o mapa não tem nenhuma BasePart em %s; não dá para medir a caixa.", measured)
	end

	local clone = model:Clone()
	if not clone then
		return false, string.format("o clima '%s' não é clonável (Archivable = false?).", name)
	end

	local fitted = self:_fit(clone, center, size)
	if not fitted then
		clone:Destroy()
		return false, string.format("o clima '%s' não tem uma Part para encaixar.", name)
	end

	makeIntangible(clone)

	-- Um clima por vez: o anterior sai antes do novo entrar.
	local container = self:GetContainer()
	container:ClearAllChildren()
	clone.Parent = container

	-- A pasta Lighting é opcional: um clima pode ser só partícula.
	local applied = "sem pasta Lighting"
	local lightingFolder = clone:FindFirstChild("Lighting")

	if lightingFolder then
		local LightingService = self.Services.LightingService

		if LightingService and LightingService.Register then
			if not self.Current then
				self.RestorePreset = LightingService:GetCurrent()
			end

			local preset = LightingService:Register(lightingFolder, Config.PresetPrefix .. name)
			if preset and LightingService:Apply(preset, transitionTime) then
				applied = string.format("preset %s", preset)
			else
				applied = "a pasta Lighting falhou (ver o output)"
			end
		else
			applied = "LightingService indisponível"
		end

		-- O `Register` já guardou a cópia dela em `Assets.Lighting`. Efeito de
		-- iluminação dentro de uma Folder no Workspace não faz nada — deixar a
		-- original pendurada no clone só replicaria peso morto.
		lightingFolder:Destroy()
	end

	self.Current = name
	broadcastWeather(name)

	weatherPrint(string.format("'%s' aplicado | caixa de %s: centro %s tamanho %s | %s | %s",
		name, measured, tostring(center), tostring(size), fitted, applied))

	return true, string.format("Weather: %s | %s | %s.", name, fitted, applied)
end

--[=[
	Tira o clima e devolve a iluminação que estava antes dele.
]=]
function WeatherService:Clear(transitionTime: number?): (boolean, string)
	if not self.Current then
		return false, "não há clima ligado."
	end

	local previous = self.Current
	self:GetContainer():ClearAllChildren()
	self.Current = nil
	broadcastWeather(nil)

	local restore = self.RestorePreset
	self.RestorePreset = nil

	if restore then
		local LightingService = self.Services.LightingService
		if LightingService and LightingService.Apply then
			LightingService:Apply(restore, transitionTime)
		end
	end

	weatherPrint(string.format("'%s' removido | iluminação devolvida para %s", previous, restore or "(nada gravado)"))

	return true, string.format("Weather off (era %s; iluminação voltou para %s).", previous, restore or "o que estava")
end

--[[ CICLO DE VIDA ]]

function WeatherService:construct()
	Framework:Listen("RequestWeather", function(player: Player)
		Framework:Fire("WeatherChanged", player, self.Current)
	end)
end

function WeatherService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function WeatherService:init()
	Framework:Listen("WeatherChanged", function() end)
end

return WeatherService
