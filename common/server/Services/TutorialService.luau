local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local PortalConfig = SharedConfig.PortalConfig
local Config = SharedConfig.TutorialConfig

--[[
	Quem ainda não fez o tutorial recebe a oferta ao cair no lobby.

	O perfil guarda um booleano: `Tutorial`. `false` é a única coisa que faz a oferta
	aparecer — este service lê a chave quando o perfil carrega e, sendo `false`,
	manda o `TutorialPrompt` para o cliente; o `TutorialController` põe a fala na
	tela.

	**As duas respostas encerram o assunto**, por caminhos diferentes:

	  - **aceitar** teleporta o jogador sozinho para o mapa do tutorial (`:Start`), e
	    a chave vira `true` quando ele vence as 5 waves, lá na outra place
	    (`:Complete`);
	  - **recusar** escreve `true` na hora. Recusa é resposta, não adiamento: quem
	    disse "não" não é perguntado de novo a cada entrada no lobby.

	**Abandonar a partida no meio deixa a chave em `false`** — quem aceitou e saiu
	antes do fim é perguntado de novo e recomeça da wave 1. O estado de meia partida
	não existe em lugar nenhum, e voltar para a wave 3 com o mapa vazio seria pior
	que recomeçar.

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
	O assunto "tutorial" já foi encerrado para este perfil?

	Duas formas passam por aqui. A de hoje é o booleano. A outra é a tabela
	`{ Match, Shop, Crates }`, que esta chave chegou a ser por algumas horas — e que
	o reconcile do `DataService` **não** desfaz sozinho, porque ele só preenche o que
	falta. Ela é lida como encerrada quando a partida tinha sido vencida.

	Sem isto, um perfil daquelas horas seria lido como "já fez" só por a tabela ser
	um valor verdadeiro, e nunca mais receberia a oferta.
]=]
local function isDone(data : any) : boolean
	local stored = data and data[DATA_KEY]

	if typeof(stored) == "table" then
		return stored.Match == true
	end

	return stored == true
end

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
		if isDone(data) then return end
		if not player.Parent then return end

		self:Prompt({ player })
	end)
end

--[=[
	Quem acabou de vencer o tutorial recebe o empurrãozinho da loja.

	O sinal é o `TutorialDone` que o servidor da partida embarcou no teleporte de
	volta — não o perfil. Ele vale para **esta** entrada no lobby e mais nada: sair
	e voltar não traz o apontamento de novo, que é o certo para um empurrão.
]=]
function TutorialService:shopPrompt(player : Player)
	if not self:isLobby() then return end

	local success, joinData = pcall(function()
		return player:GetJoinData()
	end)

	local teleportData = success and typeof(joinData) == "table" and joinData.TeleportData
	if typeof(teleportData) ~= "table" or teleportData.TutorialDone ~= true then
		return
	end

	self:PromptShop({ player })
end

--[=[
	A caixa foi comprada: tira o apontamento da loja.

	Ligado ao sinal `ItemPurchased` do `ShopService` — escutar em vez de enxertar
	deixa a compra sem uma linha de tutorial no meio dela, do mesmo jeito que o
	passo de colocação escuta o `UnitPlaced` em vez de morar dentro do `PlaceUnit`.
]=]
function TutorialService:watchShop()
	if not self:isLobby() then return end

	local shopService = Framework:Get("ShopService", false, false)
	if not shopService or not shopService.Signals or not shopService.Signals.ItemPurchased then
		warn("[TutorialService]: sem o sinal ItemPurchased; o passo da loja nao vai fechar sozinho.")

		return
	end

	shopService.Signals.ItemPurchased:Connect(function(player : Player, item : any)
		if not item or item.Id ~= Config.Lobby.Item then return end

		Framework:Fire("TutorialShopDone", player)
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
	O tutorial começou: manda o jogador para o mapa do tutorial.

	O teleporte leva **duas** coisas: o mapa, que o `MapService` de lá já sabe ler, e
	a flag `Tutorial`, que é o que faz o `TutorialMatchService` impor o preset e o
	roteiro. As duas são necessárias e dizem coisas diferentes — carregar o mapa
	Tutorial sem a flag é uma partida comum nele, que é como se testa o mapa.

	Vai **sozinho**, e não pelo portal: o tutorial é uma partida de um jogador só,
	guiada, e juntar alguém a ela atrapalharia os dois.
]=]
function TutorialService:Start(player : Player)
	local match = Config.Match

	local options = Instance.new("TeleportOptions")
	options.ShouldReserveServer = true
	options:SetTeleportData({
		Map = match.Map,
		Tutorial = true,
	})

	local success, result = pcall(function()
		return TeleportService:TeleportAsync(PortalConfig.GAME_PLACE_ID, { player }, options)
	end)

	if not success then
		warn(`[TutorialService]: nao consegui teleportar {player.Name} para o tutorial: {result}`)

		return false
	end

	return true
end

--[=[
	Abre a **segunda parte** — a que acontece no lobby depois da partida: a fala e o
	destaque no botão da loja, que fecham quando a caixa é comprada.

	Normalmente quem a dispara é o bilhete `TutorialDone` do teleporte de volta (ver
	`shopPrompt`). Por aqui ela abre sem bilhete nenhum, que é o que o comando
	`tutorialshop` precisa: testar esse passo sem ter de vencer as cinco waves antes.
]=]
function TutorialService:PromptShop(players : { Player })
	local crateService = Framework:Get("CrateService", false, false)
	local guarantee = Config.CrateGuarantee

	for _, player in players do
		--[[
			A caixa que o fluxo manda comprar vem com unit épica garantida. A marca é
			posta **aqui**, no servidor, quando o passo abre: o cliente nunca pede
			raridade, então não há como forjar uma abrindo outra caixa.
		]]
		if crateService and crateService.ForceRarity and guarantee then
			crateService:ForceRarity(player, guarantee.Rarity)
		end

		Framework:Fire("TutorialShopPrompt", player)
	end
end

--[=[
	Devolve o jogador ao estado de quem nunca viu o tutorial.

	É ferramenta de teste: o assunto se encerra na primeira resposta — vencer **ou**
	recusar —, e sem isto conferir a oferta uma segunda vez exigiria apagar o perfil.

	Reabre a fala na hora quando ele está no lobby, que é o que quem está testando
	quer ver e é o que o `PlayerDataLoaded` faria na próxima entrada. Não mexe em
	mais nada: unidades, coins e crates continuam onde estavam.
]=]
function TutorialService:Reset(player : Player)
	local dataService = self.Services.DataService
	if not dataService then
		return false
	end

	dataService:Update(player, DATA_KEY, function()
		return false
	end)

	if self:isLobby() then
		self:Prompt({ player })
	end

	return true
end

--[=[
	Encerra o assunto: a oferta não volta mais para este jogador.

	Os dois caminhos que chamam isto dizem coisas diferentes para o jogador e a
	mesma coisa para o perfil — venceu as 5 waves, ou respondeu que não quer. A
	chave não guarda **qual** dos dois foi, de propósito: nada no jogo pergunta isso,
	e uma chave que responde mais do que se pergunta é uma chave que vai ficar
	errada.
]=]
function TutorialService:MarkDone(player : Player)
	local dataService = self.Services.DataService
	if not dataService then return end

	dataService:Update(player, DATA_KEY, function()
		return true
	end)
end

--[=[
	A partida de tutorial foi vencida. Chamado da outra place, no fim das 5 waves.
]=]
function TutorialService:Complete(player : Player)
	self:MarkDone(player)
end

--[[ CICLO DE VIDA ]]

function TutorialService:construct()
	-- O identificador do evento nasce no servidor: sem este `Listen` vazio, o
	-- `Listen` do cliente ficaria dez segundos esperando um evento que ninguém
	-- registrou — e levaria junto o resto do `construct` dele. Vale nas duas places,
	-- inclusive na que não oferece tutorial nenhum, porque o controller é comum.
	Framework:Listen("TutorialPrompt", function() end)
	Framework:Listen("TutorialShopPrompt", function() end)
	Framework:Listen("TutorialShopDone", function() end)

	Framework:Listen("TutorialAnswered", function(player : Player, accepted : any)
		if accepted ~= true then
			-- Recusar é resposta, e resposta encerra: quem disse "não" não é
			-- perguntado de novo toda vez que entra no lobby.
			self:MarkDone(player)

			return
		end

		self:Start(player)
	end)

	if not self:isLobby() then return end

	self:watchShop()

	local dataService = self.Services.DataService
	if not dataService then
		warn("[TutorialService]: sem DataService; a oferta de tutorial nao vai sair.")

		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:offer(player)
		self:shopPrompt(player)
	end)

	-- Quem carregou antes deste service subir: o sinal deles já passou.
	for _, player in Players:GetPlayers() do
		self:offer(player)
		self:shopPrompt(player)
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
