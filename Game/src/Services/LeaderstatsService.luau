local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	O `leaderstats` da partida: Damage e Cash na lista de jogadores.

	Os dois são da **sessão**, não do perfil: o dano é o placar que decide o MVP
	(`MobService.SessionDamage`) e o Cash é o dinheiro do round
	(`MobService.SessionCash`), aquele que compra e vende torre. Nenhum dos dois é
	salvo, e os dois voltam a zero quando o round recomeça.

	> Não confundir com o `leaderstats` da Lobby, que mostra Coins, Wins e Shards —
	> aquilo é perfil, e `Coins` é o `Stats.Cash` guardado. As duas colunas daqui
	> morrem com o servidor.

	**Por que aqui é polling, e na Lobby não.** Lá toda escrita passa por um funil
	(`DataService:Update`) e acontece de vez em quando, então um sinal por escrita é
	exato e barato. Aqui é o contrário, por dois motivos:

	- **frequência**: o dano cresce a cada golpe em cada mob. Com AOE e meia dúzia de
	  torres são dezenas de escritas por segundo, e escrever o `IntValue` em todas
	  replicaria muito mais do que a lista consegue mostrar. Uma leitura a cada
	  `REFRESH_INTERVAL` custa duas comparações por jogador e a coluna fica igual na
	  tela.
	- **os zeros**: o fim de round limpa o placar com `table.clear(SessionDamage)`,
	  que não é escrita nenhuma — um desenho movido a evento continuaria mostrando o
	  dano da partida passada. Lendo o estado, a volta ao zero sai de graça.

	A escrita só acontece quando o valor muda, então parado o service não replica
	nada.
]]

local FOLDER_NAME = "leaderstats"

--[[
	De quanto em quanto tempo as colunas são relidas.

	Quatro vezes por segundo: rápido o bastante para o número parecer ao vivo — a
	lista de jogadores nem fica aberta o tempo todo — e devagar o bastante para o
	dano de uma wave inteira caber em poucas dezenas de escritas.
]]
local REFRESH_INTERVAL = 0.25

--[[
	Uma linha por coluna, **na ordem em que elas aparecem** na lista de jogadores: a
	Roblox desenha na ordem em que os valores entram na pasta.

	`Read` recebe o jogador e devolve o número da coluna. Column nova é uma linha
	aqui.
]]
local ENTRIES = {
	{
		Name = "Damage",
		Read = function(self, player : Player) : number
			local mobService = self.Services.MobService

			return mobService and mobService:GetDamageDealt(player.UserId) or 0
		end,
	},

	{
		Name = "Cash",
		Read = function(self, player : Player) : number
			local mobService = self.Services.MobService

			return mobService and mobService:getCash(player) or 0
		end,
	},
}

local LeaderstatsService = {
	Services = {
		MobService = {}
	}
}

--[[ INTERNAL ]]

--[=[
	A pasta do jogador, criada com as colunas já dentro se ainda não existir.

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
	Relê as colunas de um jogador. `IntValue` já trunca, mas o `math.floor` explícito
	deixa a comparação valer sobre o mesmo número que vai ser escrito — sem ele, um
	dano fracionário marcaria "mudou" a cada golpe sem a coluna nunca mudar na tela.
]=]
function LeaderstatsService:Refresh(player : Player)
	if not player.Parent then
		return
	end

	local folder = ensureFolder(player)

	for _, entry in ENTRIES do
		local value = folder:FindFirstChild(entry.Name)
		if not value or not value:IsA("IntValue") then
			continue
		end

		local wanted = math.floor(entry.Read(self, player))
		if value.Value ~= wanted then
			value.Value = wanted
		end
	end
end

function LeaderstatsService:RefreshAll()
	for _, player in Players:GetPlayers() do
		self:Refresh(player)
	end
end

--[[ CICLO DE VIDA ]]

function LeaderstatsService:construct()
	-- Quem entra no meio da partida já aparece com as colunas, mesmo que o primeiro
	-- tique do relógio ainda não tenha vindo.
	Players.PlayerAdded:Connect(function(player : Player)
		self:Refresh(player)
	end)

	self:RefreshAll()

	local elapsed = 0

	RunService.Heartbeat:Connect(function(dt : number)
		elapsed += dt
		if elapsed < REFRESH_INTERVAL then
			return
		end

		elapsed = 0
		self:RefreshAll()
	end)
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
