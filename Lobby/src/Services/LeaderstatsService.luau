local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	O `leaderstats` do lobby: Coins, Wins e Shards na lista de jogadores.

	Os três saem de `Data.Stats`, e nenhum deles é calculado aqui — este service só
	copia o perfil para os `IntValue` que a Roblox desenha. A fonte continua sendo o
	perfil, e quem quiser o número certo lê de lá.

	**Coins é `Stats.Cash`.** O perfil chama de `Cash` e a tela chama de Coins desde
	sempre (é o que o `HUDController` escreve na moeda do HUD); a lista de jogadores
	segue a tela, não o nome da chave. Não é o dinheiro da partida — aquele é o
	`MobService.SessionCash`, que vive só enquanto o round dura e nem chega ao perfil.

	**Por que fica só na Lobby.** Foi onde pediram, e é onde ele faz sentido: na Game
	a lista de jogadores concorre com a partida, e `Wins` nem muda até o fim dela. As
	duas places têm o mesmo perfil, então o dia em que a Game também quiser é mover
	este arquivo para `common/server/Services`.

	**Como ele se mantém em dia.** Toda escrita no perfil passa pelo
	`DataService:Update` — o `Set` da replica só acontece lá dentro —, e ele anuncia
	cada uma no `DataUpdated`. Não há polling: a coluna muda no mesmo instante em que
	o perfil muda, seja uma compra na loja, um summon ou o `cash` do Cmdr.
]]

local FOLDER_NAME = "leaderstats"

-- A chave de `Data` que interessa. As outras escritas (`Units`, `EquippedUnits`…)
-- não mexem em nenhuma das três colunas.
local STATS_KEY = "Stats"

--[[
	Uma linha por coluna, **na ordem em que elas aparecem** na lista de jogadores:
	a Roblox desenha na ordem em que os valores entram na pasta.

	`Name` é o que o jogador lê; `Stat` é a chave em `Data.Stats`.
]]
local ENTRIES = {
	{ Name = "Coins", Stat = "Cash" },
	{ Name = "Wins", Stat = "Wins" },
	{ Name = "Shards", Stat = "Shards" },
}

local LeaderstatsService = {
	Services = {
		DataService = {}
	}
}

--[[ INTERNAL ]]

--[=[
	A pasta do jogador, criada com as três colunas já dentro se ainda não existir.

	Ela é parenteada **por último**, de propósito: a lista de jogadores começa a
	desenhar assim que a pasta aparece, e uma pasta vazia por um frame pisca uma
	linha sem coluna nenhuma.

	A pasta vive no `Player`, que sobrevive ao respawn — então isto roda uma vez por
	jogador, e todo o resto é escrita de valor.
]=]
local function ensureFolder(player : Player) : Folder
	local existing = player:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	for _, entry in ENTRIES do
		local value = Instance.new("IntValue")
		value.Name = entry.Name
		value.Parent = folder
	end

	folder.Parent = player

	return folder
end

--[[ API ]]

--[=[
	Copia as três colunas do perfil aberto. Sem perfil (ainda carregando, ou já
	encerrado) não faz nada — a pasta nem chega a nascer, em vez de nascer com três
	zeros que não são o que o jogador tem.
]=]
function LeaderstatsService:Refresh(player : Player)
	local dataService = self.Services.DataService
	local entry = dataService and dataService.Profiles and dataService.Profiles[player]
	if not entry then
		return
	end

	local stats = entry.Profile.Data.Stats
	if not stats then
		return
	end

	local folder = ensureFolder(player)

	for _, config in ENTRIES do
		local value = folder:FindFirstChild(config.Name)

		--[[
			`IntValue` trunca sozinho, mas silenciosamente: o `math.floor` explícito é
			para o dia em que uma recompensa fracionária aparecer e o número da lista
			divergir do número do HUD sem ninguém entender por quê.
		]]
		if value and value:IsA("IntValue") then
			value.Value = math.floor(stats[config.Stat] or 0)
		end
	end
end

--[[ CICLO DE VIDA ]]

function LeaderstatsService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		warn("[LeaderstatsService]: sem DataService; a lista de jogadores fica sem colunas.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:Refresh(player)
	end)

	dataService.Signals.DataUpdated:Connect(function(player : Player, key : string)
		if key ~= STATS_KEY then
			return
		end

		self:Refresh(player)
	end)

	--[[
		Quem carregou entre o `init` do `DataService` e este `start`.

		A volta vem depois das conexões, e não antes: no meio delas um perfil poderia
		carregar sem sinal ligado para ouvi-lo. Repetir não custa nada — `Refresh` é
		idempotente.
	]]
	for player in dataService.Profiles or {} do
		self:Refresh(player)
	end
end

function LeaderstatsService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function LeaderstatsService:init()
end

return LeaderstatsService
