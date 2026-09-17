local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local PortalConfig = SharedConfig.PortalConfig

--[[
	Quem ainda não fez o tutorial recebe a oferta ao cair no lobby.

	O perfil tem uma chave só: `Tutorial`. `false` é "ainda não fez" — e é o que
	todo perfil novo traz, além de todo perfil antigo, que ganha a chave pelo
	reconcile do `DataService`. Este service lê a chave quando o perfil carrega e,
	sendo `false`, manda o `TutorialPrompt` para o cliente; o `TutorialController`
	faz o resto.

	**Recusar não escreve nada.** Quem disse "agora não" continua sem ter feito e
	recebe a oferta de novo na próxima vez que entrar. Quem escreve `true` é o
	`:Complete`, que existe e ainda não é chamado por ninguém: o tutorial em si
	ainda não foi desenhado, e é ele que vai dizer quando acabou.

	**Só no lobby.** O service é `common/` porque o jogo é um universo só, mas
	oferecer tutorial a quem acabou de cair no meio de uma partida seria pior que
	não oferecer. A porta é o `PlaceId` contra o `PortalConfig.LOBBY_PLACE_ID` — o
	mesmo id que o botão "voltar ao lobby" usa.

	> Em place não publicado (um `.rbxl` solto no Studio) o `PlaceId` é 0 e a oferta
	> não sai sozinha. Para ver a fala nesse caso existe o `tutorial` do Cmdr, que
	> entra pelo mesmo `:Prompt`.
]]

local TutorialService = {
	Services = {
		DataService = {}
	}
}

-- A chave no perfil. Uma constante porque ela aparece na leitura e na escrita, e
-- as duas têm de ser a mesma palavra.
local DATA_KEY = "Tutorial"

--[[ INTERNAL ]]

--[=[
	Esta place é o lobby?
]=]
function TutorialService:isLobby() : boolean
	return game.PlaceId == PortalConfig.LOBBY_PLACE_ID
end

--[=[
	Oferece a quem ainda não fez.

	A leitura é pelo `DataService:Get`, que só chama de volta com o perfil aberto e
	a tag `Loaded` posta — ou seja, nunca antes de o cliente ter o que precisa para
	desenhar a fala.
]=]
function TutorialService:offer(player : Player)
	local dataService = self.Services.DataService
	if not dataService then return end

	dataService:Get(player, function(data)
		if data[DATA_KEY] then return end
		if not player.Parent then return end

		self:Prompt({ player })
	end)
end

--[[ API ]]

--[=[
	Manda a oferta, sem olhar o perfil. É por aqui que o `tutorial` do Cmdr entra,
	e é o que permite ver a fala sem zerar a própria data.
]=]
function TutorialService:Prompt(players : { Player })
	for _, player in players do
		Framework:Fire("TutorialPrompt", player)
	end
end

--[=[
	O tutorial começou.

	Hoje só registra: os passos ainda não existem. É o gancho onde eles entram, e é
	o que este service devolve ao `TutorialAnswered` do cliente quando o jogador
	aceita — quem for escrever o tutorial não precisa mexer no diálogo nem no
	controller, só aqui dentro.
]=]
function TutorialService:Start(player : Player)
	print(`[TutorialService]: {player.Name} aceitou o tutorial (os passos ainda nao existem).`)
end

--[=[
	O tutorial acabou: escreve `true` no perfil e a oferta não volta.

	Ninguém chama isto ainda, de propósito — quem termina um tutorial é o tutorial,
	e ele está por fazer. Está escrito agora para a forma da chave e o caminho da
	escrita nascerem junto com a leitura, em vez de serem reinventados depois.
]=]
function TutorialService:Complete(player : Player)
	local dataService = self.Services.DataService
	if not dataService then return end

	dataService:Update(player, DATA_KEY, function()
		return true
	end)
end

--[[ CICLO DE VIDA ]]

function TutorialService:construct()
	-- O identificador do evento nasce no servidor: sem este `Listen` vazio, o
	-- `Listen` do cliente ficaria dez segundos esperando um evento que ninguém
	-- registrou — e levaria junto o resto do `construct` dele. Vale nas duas places,
	-- inclusive na que não oferece tutorial nenhum, porque o controller é comum.
	Framework:Listen("TutorialPrompt", function() end)

	Framework:Listen("TutorialAnswered", function(player : Player, accepted : any)
		if accepted ~= true then
			print(`[TutorialService]: {player.Name} recusou o tutorial.`)

			return
		end

		self:Start(player)
	end)

	if not self:isLobby() then return end

	local dataService = self.Services.DataService
	if not dataService then
		warn("[TutorialService]: sem DataService; a oferta de tutorial nao vai sair.")

		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:offer(player)
	end)

	-- Quem carregou antes deste service subir: o sinal deles já passou.
	for _, player in Players:GetPlayers() do
		self:offer(player)
	end
end

function TutorialService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function TutorialService:init()
end

return TutorialService
