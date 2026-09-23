local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local TutorialConfig = SharedConfig.TutorialConfig
local Config = TutorialConfig.Lobby

--[[
	A segunda metade do tutorial, no lobby, depois da vitória.

	É um fluxo de sete tempos, e cada um aponta **a única coisa clicável do
	momento**:

		1. a fala de parabéns;
		2. o botão da loja;
		3. o botão de comprar a Crate of Beginnings, quando a loja abre;
		4. a loja fecha sozinha e o botão da mochila é apontado;
		5. a primeira caixa da mochila, quando ela abre — **um clique só**;
		6. a mochila fecha sozinha e o unboxing roda com a tela trancada;
		7. a fala de despedida.

	**Nada fora do passo é clicável.** Quem desliga é o `ButtonGateController`, o
	mesmo que os passos da partida usam: a cada tempo do fluxo a whitelist é o alvo
	daquele tempo (mais a caixa de fala, que é `TutorialConfig.ButtonGate.Always`), e o
	resto para de aceitar clique. É o que impede o jogador de abrir o deck, entrar num
	portal ou comprar outra caixa no meio do roteiro.

	A trava é nos botões, e **não** no `BlockInput` do destaque, de propósito:
	aquele cobre a tela com frames que engolem qualquer input, inclusive o arrastar
	que gira a câmera — o jogador ficava preso olhando para um lado só. A trava sai
	junto com o fluxo: acabando, sendo interrompido ou o jogador morrendo, o
	`finish` devolve tudo.

	**O servidor é quem começa** (`TutorialShopPrompt`), e é ele quem garante a unit
	épica desta caixa — o cliente não pede raridade nenhuma, e por isso não há como
	forjar uma.

	Fica em `common/` porque o destaque e a caixa de fala são de lá; o fluxo em si só
	existe no lobby, e é o servidor de lá que o dispara.
]]

local TutorialShopController = {
	Controllers = {
		DialogController = {},
		HighlightController = {},
		ButtonGateController = {},

		-- As telas que o fluxo abre e fecha. Nenhuma delas é obrigatória: place sem
		-- alguma delas simplesmente não tem esse passo.
		ShopController = {},
		CrateUIController = {},
		UnboxingController = {},
	}
}

TutorialShopController.Running = false

-- Uma sessão por fluxo: o `while` de cada espera morre quando outra começa (ou
-- quando o fluxo é abortado), em vez de ficar rodando em segundo plano.
TutorialShopController.Session = 0

-- De quanto em quanto tempo uma espera longa se anuncia no output.
local REPORT_INTERVAL = 3

--[[ INTERNAL ]]

--[=[
	Um controller irmão, procurado **na hora do uso**.

	Não dá para resolver tudo no `init`: o `Me:Load` chama o `init` de cada módulo
	no meio da varredura, então quem é carregado depois deste ainda não existe — e
	uma busca sem espera ali devolve `nil` para sempre. Foi exatamente isso que fez
	o fluxo não reagir ao comando: o `ShopController` nunca chegava.

	Esperar também não serve: metade destes controllers é do lobby e não existe na
	Game, e um `Get` com espera ficaria preso para sempre lá. Buscar tarde e guardar
	o que achou resolve os dois casos.
]=]
function TutorialShopController:controller(name : string) : any
	local found = self.Controllers[name]

	if found and type(found) == "table" and next(found) ~= nil then
		return found
	end

	found = Framework:Get(name, false, false)

	if found then
		self.Controllers[name] = found
	end

	return found
end

--[=[
	Aponta um alvo e deixa **só ele** clicável.

	A trava é refeita a cada tempo do fluxo, e é isso que cobre os botões que ainda
	não existiam quando o anterior começou — o de comprar nasce com a loja aberta, a
	caixa nasce com a mochila aberta. O gate ainda se reaplica sozinho quando um botão
	novo chega, então a ordem entre "abriu a tela" e "apontei o alvo" deixou de
	importar.

	`nil` tranca a tela inteira e apaga o destaque: é o que o passo do unboxing pede,
	para não haver uma segunda caixa para abrir sem querer.

	O prazo da válvula é o `StallRelease` do config, contado a partir daqui — e como
	o `point` vem sempre um instante antes da espera daquele tempo, ele é o prazo
	daquela espera.
]=]
function TutorialShopController:point(target : GuiObject?)
	local gate = self:controller("ButtonGateController")

	if gate then
		local allow = {}

		if target then
			table.insert(allow, target)
		end

		for _, entry in (TutorialConfig.ButtonGate.Always or {}) do
			table.insert(allow, entry)
		end

		gate:Lock({
			Allow = allow,
			Ignore = TutorialConfig.ButtonGate.Ignore,
			Release = Config.StallRelease,
		})
	end

	local highlight = self:controller("HighlightController")
	if not highlight then return end

	if not target then
		highlight:Hide()

		return
	end

	highlight:Show(target)
end

--[=[
	Espera uma condição virar verdadeira, sem passar do orçamento.

	Devolve `false` quando o tempo acaba **ou** quando outro fluxo começou no meio —
	quem chama trata os dois do mesmo jeito: para de esperar e sai.

	A válvula que solta a trava quando a espera passa do limite **não é daqui**: ela é
	do `ButtonGateController`, armada pelo `point` que vem antes de cada espera (ver
	`Lobby.StallRelease`). Estava aqui antes de os passos da partida precisarem da
	mesma rede, e duas implementações da mesma ideia é uma a mais.
]=]
function TutorialShopController:await(session : number, timeout : number?, condition : () -> boolean, label : string?) : boolean
	local deadline = if timeout then os.clock() + timeout else nil
	local nextReport = os.clock() + REPORT_INTERVAL

	while self.Session == session and self.Running do
		if condition() then
			return true
		end

		if deadline and os.clock() > deadline then
			print(`[DEBUG/TutorialLobby] desisti de esperar: {label or "?"}`)

			return false
		end

		-- Espera que demora vira linha no output: "nada acontece" é o relato mais
		-- difícil de investigar, e o fluxo sabe exatamente o que está esperando.
		if label and os.clock() >= nextReport then
			nextReport = os.clock() + REPORT_INTERVAL

			print(`[DEBUG/TutorialLobby] esperando: {label}`)
		end

		task.wait(Config.PollInterval)
	end

	return false
end

--[=[
	Uma fala, esperando ela fechar para seguir.
]=]
function TutorialShopController:say(session : number, lines : { string }?) : boolean
	local dialog = self:controller("DialogController")
	if not dialog or not lines then
		return true
	end

	local closed = false

	local disconnect
	disconnect = dialog:OnClosed(function()
		if disconnect then
			disconnect()
		end

		closed = true
	end)

	local playing = dialog:Play(lines, TutorialConfig.Speech({
		-- O HUD fica: o passo seguinte aponta um botão dele.
		HideUI = false,
		Blur = false,
		Duck = false,
		Auto = true,
	}))

	--[=[
		Fala que não entrou não pode **parar** o fluxo.

		A espera aqui embaixo não tem prazo: ela roda até o `OnClosed` chegar, e
		`OnClosed` de uma fala que nunca começou não chega nunca. O fluxo ficava parado
		na primeira linha, com a tela trancada no alvo do tempo anterior e nada
		acontecendo — foi assim que o recomeço depois do respawn no lobby morria em
		silêncio.

		Seguir sem ela é o menor dos males: o tempo seguinte aponta o botão da loja, que
		é o que o jogador precisa clicar de qualquer jeito. O output diz o que faltou.
	]=]
	if not playing then
		if disconnect then
			disconnect()
		end

		warn("[TutorialShopController]: a caixa de fala nao entrou; seguindo o fluxo sem ela.")

		return true
	end

	local finished = self:await(session, nil, function()
		return closed
	end)

	-- Espera que acabou sem a fala fechar (outra sessão começou, ou o fluxo foi
	-- abortado) deixa a inscrição para trás: sem isto, cada recomeço empilha mais uma.
	if disconnect then
		disconnect()
	end

	return finished
end

--[=[
	Este elemento está **de fato** na tela?

	`Visible` é propriedade de cada objeto, não do que se vê: um botão dentro de um
	painel fechado continua com `Visible = true`, e o `AbsoluteSize` dele continua
	valendo. Foi assim que a prova de tela do passo 2 se deu por cumprida com a loja
	fechada — o fluxo pulou o clique no botão da loja e foi destacar o de comprar
	dentro de um painel que ninguém tinha aberto.

	Estar na tela é o objeto visível **e** toda a linhagem dele visível, até a
	`ScreenGui`, que por sua vez tem de estar ligada.
]=]
function TutorialShopController:onScreen(instance : GuiObject?) : boolean
	if not instance or not instance.Visible then
		return false
	end

	local current : Instance? = instance.Parent

	while current do
		if current:IsA("LayerCollector") then
			return current.Enabled
		end

		if current:IsA("GuiObject") and not current.Visible then
			return false
		end

		current = current.Parent
	end

	return false
end

--[=[
	O botão de comprar a caixa do tutorial, dentro da loja.

	Procurado pelo **id do item**, que é como o `ShopController` nomeia o container
	de cada caixa, e então o botão de compra dentro dele.
]=]
function TutorialShopController:buyButton() : GuiObject?
	local shop = PlayerGui:FindFirstChild("ShopUI")
	local container = shop and shop:FindFirstChild(Config.Item, true)
	local button = container and container:FindFirstChild(Config.BuyButton, true)

	return if button and button:IsA("GuiObject") then button else nil
end

--[=[
	A primeira caixa da mochila — a que o jogador acabou de comprar.

	"Primeira" é a de menor `LayoutOrder`, e não a primeira da lista de filhos: a
	ordem dos filhos é a de criação e quem manda na tela é o layout.

	**Só entra botão visível.** O wrapper guarda uma entrada por raridade, e o
	`CrateController` só mostra as que o jogador tem — mais o `cratetemplate`, o
	molde, que fica lá escondido para o designer editar. Sem o filtro, o destaque ia
	parar em cima de algo invisível, que é o mesmo que não aparecer.

	**`Active` não entra na conta**, e isso é uma pedra em que já tropecei: o passo
	anterior deixa todo botão fora dele desligado, e as caixas da mochila estão
	nesse "fora dele". Exigir `Active` aqui era procurar um alvo que a minha própria
	trava tinha acabado de esconder — o passo esperava cinco segundos e desistia sem
	destaque nenhum. Quem destranca é o `point`, logo depois desta busca.
]=]
function TutorialShopController:firstCrate() : GuiObject?
	local highlight = self:controller("HighlightController")
	local list = highlight and highlight:Find(Config.CrateList)
	if not list then
		return nil
	end

	local prefix = Config.CratePrefix
	local best, bestOrder = nil, math.huge
	local fallback, fallbackOrder = nil, math.huge

	for _, child in list:GetDescendants() do
		if not child:IsA("GuiButton") or not child.Visible then
			continue
		end

		local order = child.LayoutOrder

		-- Entrada de verdade tem o prefixo; o molde não. Sem prefixo declarado, vale
		-- qualquer botão visível.
		if not prefix or string.sub(child.Name, 1, #prefix) == prefix then
			if order < bestOrder then
				best, bestOrder = child, order
			end
		elseif order < fallbackOrder then
			fallback, fallbackOrder = child, order
		end
	end

	return best or fallback
end

--[=[
	Devolve a tela: nenhum destaque, nenhuma trava.
]=]
function TutorialShopController:finish()
	self.Running = false

	local gate = self:controller("ButtonGateController")
	if gate then
		gate:Unlock()
	end

	local highlight = self:controller("HighlightController")
	if highlight then
		highlight:Hide()
	end
end

--[=[
	O fluxo inteiro, de cima a baixo.

	Escrito como uma sequência, e não como um punhado de callbacks, porque é isso
	que ele é: cada passo só faz sentido depois do anterior, e o `await` é o que
	transforma "o jogador clicou" em uma linha de código.

	Ele é partido em duas metades pela **compra**, e a fratura é ali por causa do
	respawn: morrer no lobby destrói a `HUD`, a `ShopUI` e a `crateui` (todas têm
	`ResetOnSpawn`), e o fluxo tem de recomeçar em algum lugar. Antes da compra,
	recomeçar do zero não custa nada — o jogador só tinha clicado num botão. Depois
	dela, recomeçar seria mandá-lo comprar uma caixa que ele já comprou, então a volta
	é pela segunda metade. Ver `onRespawn`.
]=]
function TutorialShopController:run(session : number, fromCrate : boolean?)
	if fromCrate then
		return self:runCrate(session)
	end

	if not self:runShop(session) then
		return
	end

	self:runCrate(session)
end

--[=[
	A primeira metade: a fala, o botão da loja e a compra da caixa.

	Devolve `false` quando o fluxo morreu no meio — outra sessão começou, ou uma
	espera desistiu.
]=]
function TutorialShopController:runShop(session : number) : boolean
	local highlight = self:controller("HighlightController")

	-- 1. a fala
	if not self:say(session, Config.Lines) then return false end

	-- 2. o botão da loja, até ela abrir
	local shopButton = highlight and highlight:Find(Config.ShopButton)
	print(`[DEBUG/TutorialLobby] passo 2: botao da loja = {shopButton and shopButton:GetFullName() or "NAO ACHEI"}`)

	self:point(shopButton)

	--[[
		O controller é procurado **a cada volta**, e não guardado antes do laço: se
		ele ainda não tivesse carregado quando o fluxo começou, a condição seria
		falsa para sempre e o passo travaria em silêncio.
	]]
	--[[
		"A loja abriu" é perguntado ao controller **e** conferido na tela.

		O controller responde pelo painel de proximidade, e o painel pode abrir por
		caminhos que ele não acompanha. Como a trava desliga tudo o que não é o alvo,
		um "não abriu" errado deixaria o botão de comprar desligado para sempre.

		O segundo testemunho é o botão de comprar **na tela** — e "na tela" quer
		dizer a linhagem inteira visível (ver `onScreen`), não o `Visible` do próprio
		botão: esse continua ligado dentro de um painel fechado, e conferi-lo sozinho
		fazia o passo se dar por cumprido antes de o jogador clicar em nada.
	]]
	if not self:await(session, nil, function()
		local shop = self:controller("ShopController")
		if shop and shop:IsOpen() then
			return true
		end

		return self:onScreen(self:buyButton())
	end, "a loja abrir") then
		return false
	end

	-- 3. o botão de comprar, até a compra acontecer
	self:await(session, Config.WaitForUi, function()
		return self:buyButton() ~= nil
	end, "o botao de comprar aparecer")

	local buy = self:buyButton()
	print(`[DEBUG/TutorialLobby] passo 3: botao de compra = {buy and buy:GetFullName() or "NAO ACHEI"}`)

	self:point(buy)

	if not self:await(session, nil, function()
		return self.Bought == true
	end, "a compra da caixa") then
		return false
	end

	return true
end

--[=[
	A segunda metade: a caixa comprada saindo da mochila, e a despedida.

	É por aqui que o fluxo volta quando o jogador morre **depois** de ter comprado.
]=]
function TutorialShopController:runCrate(session : number)
	local highlight = self:controller("HighlightController")

	-- 4. a loja fecha sozinha e a mochila é apontada
	local shop = self:controller("ShopController")
	if shop and shop:IsOpen() then
		shop:Close()
	end

	self:point(highlight and highlight:Find(Config.BackpackButton))

	if not self:await(session, nil, function()
		local backpack = self:controller("CrateUIController")
		if backpack and backpack:IsOpen() then
			return true
		end

		-- O mesmo segundo testemunho da loja: a caixa **na tela** é a mochila aberta,
		-- diga o controller o que disser.
		return self:onScreen(self:firstCrate())
	end, "a mochila abrir") then
		return
	end

	-- 5. a primeira caixa, até ela sair da mochila (foi aberta)
	self:await(session, Config.WaitForUi, function()
		return self:firstCrate() ~= nil
	end, "a primeira caixa aparecer na mochila")

	local crate = self:firstCrate()

	do
		local highlight = self:controller("HighlightController")
		local list = highlight and highlight:Find(Config.CrateList)
		local visiveis = 0

		if list then
			for _, c in list:GetDescendants() do
				if c:IsA("GuiButton") and c.Visible then visiveis += 1 end -- `Active` fica fora: a trava do passo anterior o desliga
			end
		end

		print(string.format("[DEBUG/TutorialLobby] passo 5: lista=%s botoes visiveis=%d escolhida=%s",
			list and list:GetFullName() or "NAO ACHEI", visiveis,
			crate and `{crate.Name} (ordem {crate.LayoutOrder})` or "NENHUMA"))
	end

	self:point(crate)

	--[[
		**Uma caixa, um clique.**

		Esperar o unboxing terminar com o botão ainda destacado e clicável era um
		convite: o jogador tem mais caixas, o botão continua lá, e ele abre três
		enquanto a primeira ainda está rodando. O passo escuta a **ativação** do
		botão e fecha no primeiro clique — daí em diante nada é clicável (o
		`point(nil)` tranca tudo) até o unboxing acabar.
	]]
	local clicked = false
	local connection = if crate and crate:IsA("GuiButton")
		then crate.Activated:Connect(function()
			clicked = true
		end)
		else nil

	local advanced = self:await(session, nil, function()
		return clicked or self.Unboxed == true or crate == nil or not crate.Parent
	end, "o clique na caixa")

	if connection then
		connection:Disconnect()
	end

	if not advanced then
		return
	end

	-- Da primeira caixa até o fim do unboxing, a tela inteira fica trancada: não há
	-- segunda caixa para abrir sem querer.
	self:point(nil)

	-- 6. a mochila sai da frente do unboxing
	local backpack = self:controller("CrateUIController")
	if backpack and backpack:IsOpen() then
		backpack:Close()
	end

	-- 7. o unboxing termina e a fala de despedida fecha o tutorial
	local unboxed = self:await(session, nil, function()
		return self.Unboxed == true
	end, "o unboxing terminar")

	--[[
		O último passo do funil de onboarding sai daqui, e não do `:finish()`: aquele
		roda também quando o fluxo aborta (`:Stop`, ou um `await` que voltou falso), e
		"abriu a caixa" tem de querer dizer que a caixa abriu.

		Quem confere se este jogador é um que terminou o tutorial de verdade — e não
		alguém rodando o `tutorialshop` do Cmdr — é o servidor.
	]]
	if unboxed then
		Framework:Fire("TutorialShopFinished")
	end

	self:say(session, Config.ClosingLines)
	self:finish()
end

--[[ API ]]

--[=[
	Começa o fluxo. Chamar de novo reinicia do primeiro passo — é o que o
	`tutorialshop` do Cmdr faz quando alguém quer ver de novo.

	`fromCrate` entra pela segunda metade, com a compra dada por feita. É por onde o
	respawn volta quando o jogador já tinha comprado a caixa (ver `onRespawn`), e é
	também o que impede o recomeço de pedir uma segunda compra.
]=]
function TutorialShopController:Start(fromCrate : boolean?)
	self:hookUnboxing()

	self.Session += 1
	local session = self.Session

	self.Running = true
	self.Unboxed = false

	-- Recomeço pela segunda metade não desfaz a compra: ela aconteceu, e o servidor
	-- não a faria de novo.
	self.Bought = fromCrate == true

	print(string.format("[DEBUG/TutorialLobby] comecando o fluxo | dialogo=%s destaque=%s loja=%s mochila=%s unboxing=%s",
		tostring(self:controller("DialogController") ~= nil),
		tostring(self:controller("HighlightController") ~= nil),
		tostring(self:controller("ShopController") ~= nil),
		tostring(self:controller("CrateUIController") ~= nil),
		tostring(self:controller("UnboxingController") ~= nil)))

	task.spawn(function()
		self:run(session, fromCrate)

		if self.Session == session then
			self:finish()
		end
	end)
end

--[=[
	O jogador morreu no meio do fluxo.

	No lobby **toda** `ScreenGui` tem `ResetOnSpawn`: a `HUD`, a `ShopUI`, a
	`crateui`. A tela em que o fluxo estava apontando deixou de existir, e as
	referências que ele tinha na mão viraram lixo — inclusive a caixa cujo clique ele
	estava esperando, que é uma instância e não uma condição.

	Por isso a volta é um recomeço, e onde ele recomeça depende do que já foi feito:

	  - **sem a compra**, do primeiro tempo. O jogador só tinha clicado num botão, e
	    refazer isso não custa nada;
	  - **com a compra**, da segunda metade. Mandá-lo comprar de novo uma caixa que
	    ele já tem seria um passo que nunca fecha — o servidor não vende duas vezes.

	Fluxo parado não reage: morrer fora do tutorial da loja é morrer, e nada mais.
]=]
function TutorialShopController:onRespawn()
	if not self.Running then return end

	local bought = self.Bought == true

	print(`[DEBUG/TutorialLobby] respawn no meio do fluxo; recomecando {bought and "pela caixa" or "do inicio"}.`)

	--[[
		A tela nova ainda não chegou quando o `CharacterAdded` dispara: o
		`ResetOnSpawn` reclona a `StarterGui` depois dele. As esperas do fluxo já
		procuram cada peça com orçamento próprio, então basta sair da frente do quadro
		do nascimento — quem espera de verdade é o `await`.
	]]
	task.defer(function()
		if not self.Running then return end

		self:Start(bought)
	end)
end

--[=[
	Liga o aviso de fim de unboxing, uma vez.
]=]
function TutorialShopController:hookUnboxing()
	if self.UnboxingHooked then return end

	local unboxing = self:controller("UnboxingController")
	local signal = unboxing and unboxing.Signals and unboxing.Signals.UnboxingFinished
	if not signal then return end

	self.UnboxingHooked = true

	signal:Connect(function()
		self.Unboxed = true
	end)
end

--[=[
	Aborta o que estiver em curso e devolve a tela.
]=]
function TutorialShopController:Stop()
	self.Session += 1
	self:finish()
end

function TutorialShopController:IsRunning() : boolean
	return self.Running
end

--[[ CICLO DE VIDA ]]

function TutorialShopController:construct()
	Framework:Listen("TutorialShopPrompt", function()
		self:Start()
	end)

	-- Ver `onRespawn`: no lobby o respawn leva a tela inteira embora.
	Player.CharacterAdded:Connect(function()
		self:onRespawn()
	end)

	-- A compra: quem avisa é o servidor, pelo mesmo evento que já fechava o passo
	-- antigo.
	Framework:Listen("TutorialShopDone", function()
		self.Bought = true
	end)

	--[[
		O unboxing pode ainda não ter carregado quando este `construct` roda (ver
		`controller`), então a inscrição é feita na primeira vez que o fluxo começa —
		e uma vez só.
	]]
	self.UnboxingHooked = false
end

function TutorialShopController:start()
end

function TutorialShopController:init()
	self:construct()
end

return TutorialShopController
