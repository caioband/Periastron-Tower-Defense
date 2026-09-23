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

--[[
	A trava de botões: quais `GuiButton` da tela aceitam clique agora.

		local Gate = Framework:Get("ButtonGateController")

		Gate:Lock({
			Allow = { "Interface.ReadyWave", someInstance },
			Block = { "Interface.SkipPrompt" },
			Release = 90,
		})

		Gate:Unlock()

	**A whitelist é fechada e manda nos dois sentidos.** O que não estiver em `Allow`
	(nem for filho ou pai de algo que esteja) para de aceitar clique, hover e navegação
	por controle; o que estiver **passa a aceitar**, mesmo que chegue desligado. Os
	dois são `Active`/`Selectable`, e os dois voltam ao que eram no `Unlock`. Ligar
	também é o que salva a peça clonada de um molde que a trava desligou — ver
	`enforce`. `Block` é a subtração: ele ganha do `Allow`, e é como se tira um botão
	de dentro de um painel inteiro liberado.

	**Filho e pai do alvo entram junto.** Clicar num botão dentro do alvo é clicar no
	alvo, e um wrapper clicável que embala o alvo não pode ficar mudo enquanto o que
	está dentro dele funciona.

	**Por que não o `BlockInput` do destaque.** Ele cobre a tela com quatro frames
	`Active`, e frame `Active` engole *qualquer* input que passe por cima — inclusive
	o arrastar que gira a câmera. O jogador ficava preso olhando para um lado só.
	Aqui a câmera continua livre: o que muda é só o que os botões aceitam.

	**Botão que já estava desligado não é tocado.** `Active = false` de antes quer
	dizer que ele tem outro dono (o `ToggleTower` tranca o upgrade e a venda a partida
	de tutorial inteira), e devolvê-lo ligado no `Unlock` desfaria a trava de outra
	pessoa.

	**Botão fora da tela fica de fora.** Não dá para clicar no que não se vê, e mexer
	no `Active` de uma peça escondida quebra quem a clona — o clone nasce com o estado
	que a trava escreveu no molde. A trava escuta quem está escondendo e refaz a conta
	quando o painel aparece — ver `onScreen` e `watch`.

	**Botão que outro dono religa volta a ser desligado.** Um botão tem mais de um
	dono, e nenhum deles sabe que o tutorial está no ar: o `DifficultyController`
	devolve o `Active` dos degraus quando a votação fecha, o `ReadyController` religa o
	dele a cada intervalo. A trava escuta o `Active` de cada botão que desligou e
	desfaz isso — ver `disable`.

	**Botão que nasce depois entra na conta.** A mesa da loja, a carta que vai para a
	mão, a lista de caixas da mochila: todas nascem com a trava já de pé. O gate
	escuta a `PlayerGui` e reaplica sozinho — quem chamou o `Lock` não precisa saber
	quando a tela terminou de montar.

	**A válvula (`Release`).** Trava existe para o jogador não sair do roteiro, não
	para prendê-lo: se a whitelist do passo estiver errada, o botão certo fica
	desligado e não há ninguém para religá-lo. Passados `Release` segundos a trava cai
	sozinha e o output diz por quê. Quem sabe que a espera é legítima — o passo já foi
	cumprido e o jogador só está vendo a wave correr — chama `:HoldRelease()` e a
	trava fica sem prazo.

	Fica em `common/` porque as duas places têm roteiro que aponta botão.
]]

local ButtonGateController = {
	Controllers = {
		HighlightController = {},
	}
}

-- A trava de pé, como veio no `Lock`. `nil` é tela solta.
ButtonGateController.Spec = nil :: any

--[[
	`[GuiButton] = { Active, Selectable, Connection }` — o que cada botão era antes de
	a trava desligá-lo, e a escuta que o mantém desligado. É esta tabela que o
	`Unlock` desfaz.
]]
ButtonGateController.Saved = {}

-- Sobe a cada `Lock`. A válvula e a varredura atrasada conferem o número antes de
-- mexer na tela: trava nova durante a espera da anterior não pode ser desfeita pela
-- válvula de uma trava que já saiu.
ButtonGateController.Token = 0

--[[
	Sobe a cada `Lock`, a cada `Unlock` e no `HoldRelease`. É o número que a válvula
	confere ao acordar, e é separado do `Token` de propósito: tirar o prazo não pode
	cancelar a varredura atrasada que estiver marcada.
]]
ButtonGateController.ReleaseToken = 0

-- A escuta da `PlayerGui`, ligada só enquanto há trava de pé.
ButtonGateController.Connection = nil :: RBXScriptConnection?

--[[
	`[Instance] = conexão` — o que está **escondendo** botões agora, e a escuta que
	avisa quando ele aparecer.

	O painel fechado não cria filho nenhum ao abrir (ele só vira `Visible`), então sem
	isto a trava não teria como saber que os botões de dentro dele acabaram de entrar
	na tela. Ver `onScreen` e `watch`.
]]
ButtonGateController.Watched = {}

-- Já há uma varredura marcada para o fim deste quadro? Ver `schedule`.
ButtonGateController.Pending = false

--[[ INTERNAL ]]

--[=[
	Um alvo da whitelist virando instância. Ele vem de três formas:

	  - **caminho de tela** (`"Interface.ReadyWave"`), resolvido pelo
	    `HighlightController:Find` — a mesma busca em profundidade que o `Highlight`
	    do passo usa;
	  - **instância**, para quem já tem a referência na mão e não precisa dar a volta
	    por um caminho;
	  - **função**, para a peça que não tem caminho fixo porque nasce clonada em
	    runtime: a carta na mesa da loja, a caixa na mochila, o que o destaque estiver
	    abraçando agora. Ela pode devolver **uma** instância ou uma lista delas — o
	    menu de velocidade abre um clone por degrau, e os degraus são vários.

	**Tudo é resolvido a cada varredura**, e não uma vez no `Lock`. É o que importa:
	o botão de comprar nasce quando a loja abre, e um alvo resolvido cedo demais
	viraria `nil` para sempre — a whitelist ficaria sem justamente o botão que o passo
	pede. A função existe pelo mesmo motivo e vai mais longe: ela reencontra o alvo
	toda vez, mesmo que ele tenha sido destruído e clonado de novo no meio do passo.
]=]
function ButtonGateController:resolve(entries : { any }?) : { Instance }
	local out = {}

	for _, entry in (entries or {}) do
		if type(entry) == "function" then
			-- Alvo de quem chamou: um erro dentro dele não pode derrubar a varredura e
			-- deixar meia tela trancada.
			local success, found = pcall(entry)

			if not success then
				warn(`[ButtonGateController]: um alvo da whitelist estourou: {found}`)
			elseif typeof(found) == "Instance" then
				if found.Parent then
					table.insert(out, found)
				end
			elseif type(found) == "table" then
				for _, one in found do
					if typeof(one) == "Instance" and one.Parent then
						table.insert(out, one)
					end
				end
			end

			continue
		end

		if typeof(entry) == "Instance" then
			if entry.Parent then
				table.insert(out, entry)
			end

			continue
		end

		if type(entry) ~= "string" then
			continue
		end

		local highlight = self.Controllers.HighlightController
		local found = highlight and highlight:Find(entry)

		if found then
			table.insert(out, found)
		end
	end

	return out
end

--[=[
	As telas que a trava não pisa, por nome.

	O destaque é uma delas sempre: a tela dele não tem botão, mas varrê-la é trabalho
	à toa a cada vez. O resto vem de quem chamou — o Cmdr é o caso de sempre, porque
	trancar o console é trancar a própria ferramenta de destravar.
]=]
function ButtonGateController:ignored(spec : any) : { [string] : boolean }
	local out = { [SharedConfig.HighlightConfig.Gui.Name] = true }

	for _, name in (spec.Ignore or {}) do
		out[name] = true
	end

	return out
end

--[=[
	A tela (`LayerCollector`) em que um botão vive, ou `nil`.
]=]
local function screenOf(instance : Instance) : Instance?
	local current : Instance? = instance

	while current do
		if current:IsA("LayerCollector") then
			return current
		end

		current = current.Parent
	end

	return nil
end

--[=[
	O botão está **de fato** na tela? Devolve junto **tudo** o que o está escondendo.

	`Visible` é propriedade de cada objeto, e não do que se vê: um botão dentro de um
	painel fechado continua com `Visible = true`. Estar na tela é ele visível **e**
	toda a linhagem visível, até uma `ScreenGui` que por sua vez esteja ligada.

	A lista é de **todos** os que escondem, e não só do mais próximo, e isso não é
	zelo: a hotbar esconde em dois níveis (a carta e o container), e devolvê-los um de
	cada vez perde a corrida. Escutando só a carta, o quadro em que ela reaparece com
	o container ainda fechado gastava o único aviso que havia — o container abria
	depois, sem nada escutando, e a carta ficava clicável fora da whitelist. Com a
	linhagem inteira escutada, qualquer um dos dois refaz a conta.
]=]
local function onScreen(instance : GuiObject) : (boolean, { Instance })
	local hiders = {}

	if not instance.Visible then
		table.insert(hiders, instance)
	end

	local current : Instance? = instance.Parent

	while current do
		if current:IsA("LayerCollector") then
			if not current.Enabled then
				table.insert(hiders, current)
			end

			return #hiders == 0, hiders
		end

		if current:IsA("GuiObject") and not current.Visible then
			table.insert(hiders, current)
		end

		current = current.Parent
	end

	-- Fora de qualquer tela: não está em lugar nenhum que o jogador veja.
	return false, hiders
end

--[=[
	O botão está **dentro** do alvo (ou é ele)? É a conta do `Block`.
]=]
local function contains(target : Instance, button : Instance) : boolean
	return button == target or button:IsDescendantOf(target)
end

--[=[
	O botão faz parte do alvo, em qualquer direção? É a conta do `Allow`.

	Pai conta junto com filho: um `CardWrapper` clicável que embala a carta apontada
	não pode ficar mudo enquanto a carta dentro dele funciona.
]=]
local function touches(target : Instance, button : Instance) : boolean
	return button == target or button:IsDescendantOf(target) or target:IsDescendantOf(button)
end

--[=[
	Devolve um botão ao que ele era e larga a escuta dele.

	**A escuta sai antes** do `Active` voltar, e não depois: ela existe justamente
	para segurar o botão no estado que a trava quer, e devolvê-lo com ela ligada faria
	a trava se reapertar em cima da própria devolução.
]=]
function ButtonGateController:restore(button : GuiButton)
	local state = self.Saved[button]
	if not state then return end

	self.Saved[button] = nil

	if state.Connection then
		state.Connection:Disconnect()
	end

	if button.Parent then
		button.Active = state.Active
		button.Selectable = state.Selectable
	end
end

--[=[
	Põe um botão no estado que a trava quer e o segura lá.

	`want` é `false` para o que a whitelist não cobre e `true` para o que ela cobre —
	**a whitelist manda nos dois sentidos**, e não só em desligar. Ligar parece
	exagero até se ver o que acontece sem isso: o `RoundCardShopController` tira o
	molde de carta da própria tela (`_template` clona o `CardWrapper` autorado e
	destrói o original), e se a trava tiver desligado o molde antes disso o
	`Active = false` viaja no clone. Toda carta da oferta nasce morta, **inclusive a
	que o passo manda comprar** — foi assim que a Weather Report ficou sem clique.
	Trava que só desliga não tem como desfazer isso, porque o estado que ela guardou é
	o do molde, não o do clone que nem existia.

	Quem está na whitelist, então, a trava liga. Se outro dono o tinha desligado de
	propósito, a whitelist ganha: passo que aponta um botão e não deixa clicar nele é
	um passo que não fecha. O estado original fica guardado e volta no `Unlock`, como
	em qualquer outro botão.

	A escuta é o que separa isto de um `Active = false` solto. Um botão tem mais de um
	dono — o `DifficultyController` devolve o `Active` dos degraus quando a votação
	fecha, o `ReadyController` religa o dele a cada intervalo — e nenhum deles sabe que
	o tutorial está no ar. Sem ela, o primeiro que passar abre um buraco na whitelist
	que só uma varredura por acaso fecharia.

	Não há laço: a escuta só age quando o valor está **diferente** do que a trava quer,
	e escrever o valor certo não dispara nada que ela atenda.
]=]
function ButtonGateController:enforce(button : GuiButton, want : boolean)
	local state = self.Saved[button]

	if state then
		if state.Want == want then
			-- Já é nosso e já quer a mesma coisa; a escuta cuida do resto.
			return
		end

		--[[
			A whitelist mudou de opinião sobre este botão de um passo para o outro. O
			estado original é o da primeira vez que o vimos, e é esse que tem de voltar no
			fim — por isso ele é reaproveitado em vez de relido da tela, que agora mostra
			o que **nós** escrevemos.
		]]
		if state.Connection then
			state.Connection:Disconnect()
		end
	else
		state = { Active = button.Active, Selectable = button.Selectable }
	end

	state.Want = want
	self.Saved[button] = state

	state.Connection = button:GetPropertyChangedSignal("Active"):Connect(function()
		if self.Saved[button] ~= state or button.Active == want then return end

		button.Active = want
		button.Selectable = want
	end)

	button.Active = want
	button.Selectable = want
end

--[=[
	Fica de olho num ancestral que está escondendo botões.

	É o par do `onScreen`. Um painel que abre não cria filho nenhum — ele só vira
	`Visible` —, e o `DescendantAdded` não tem o que avisar: sem esta escuta, os
	botões que acabaram de entrar na tela ficariam clicáveis até alguém criar um botão
	em algum lugar.

	Uma escuta por ancestral, e não por botão: é um punhado de painéis contra dezenas
	de botões, e o que interessa é o momento em que o painel aparece.
]=]
function ButtonGateController:watch(hiders : { Instance })
	for _, hider in hiders do
		if self.Watched[hider] then
			continue
		end

		local property = if hider:IsA("LayerCollector") then "Enabled" else "Visible"

		self.Watched[hider] = hider:GetPropertyChangedSignal(property):Connect(function()
			self:schedule()
		end)
	end
end

--[=[
	Larga todas as escutas de visibilidade.
]=]
function ButtonGateController:unwatch()
	for _, connection in self.Watched do
		connection:Disconnect()
	end

	table.clear(self.Watched)
end

--[=[
	Aplica a trava que está de pé: desliga o que sobra, devolve o que voltou a ser
	permitido e deixa o resto como está.

	A diferença é calculada em vez de a tela ser destravada e travada de novo: o
	segundo jeito passa por um instante com tudo ligado, e uma varredura que acontece
	no meio de um clique deixaria o clique passar.
]=]
function ButtonGateController:apply()
	local spec = self.Spec
	if not spec then return end

	local allow = self:resolve(spec.Allow)
	local block = self:resolve(spec.Block)
	local ignored = self:ignored(spec)

	-- `[GuiButton] = Active que a trava quer`. `nil` é "não é assunto meu".
	local wanted = {}

	for _, instance in PlayerGui:GetDescendants() do
		if not instance:IsA("GuiButton") then
			continue
		end

		local screen = screenOf(instance)
		if screen and ignored[screen.Name] then
			continue
		end

		--[=[
			Botão fora da tela fica de fora da conta, nos dois sentidos.

			Não dá para clicar no que não se vê, então trancá-lo não compra nada — e mexer
			nele **custa**: a tela que clona uma peça escondida leva no clone o `Active`
			que a trava escreveu no molde, e o dono do molde não tem como saber disso.
			Ligar também sairia errado, e por um motivo mais imediato: a carta da hotbar
			fica desligada enquanto a fala do passo está na tela, e acendê-la ali seria
			deixar arrastar antes de o jogador terminar de ler.

			Quem está escondendo o botão passa a ser escutado, porque painel que abre não
			cria filho nenhum: a conta é refeita quando ele aparecer.
		]=]
		local visible, hiders = onScreen(instance)
		if not visible then
			self:watch(hiders)

			continue
		end

		local permitted = false
		for _, target in allow do
			if touches(target, instance) then
				permitted = true
				break
			end
		end

		-- O `Block` ganha do `Allow`: é assim que se libera um painel inteiro e se tira
		-- um botão de dentro dele.
		if permitted then
			for _, target in block do
				if contains(target, instance) then
					permitted = false
					break
				end
			end
		end

		--[[
			Botão que a whitelist não cobre e que **já** estava desligado tem outro dono — o
			`ToggleTower` tranca o upgrade e a venda a partida de tutorial inteira. Tomá-lo
			aqui faria o `Unlock` religá-lo, e a trava do outro sairia sem ele saber.

			O que a whitelist cobre é tomado de qualquer jeito, ligado ou desligado: ali a
			trava manda nos dois sentidos (ver `enforce`).
		]]
		if permitted or instance.Active then
			wanted[instance] = permitted
		end
	end

	-- O que saiu da conta (o botão sumiu da tela, ou deixou de ser assunto) volta ao
	-- que era.
	for button in self.Saved do
		if wanted[button] ~= nil and button.Parent then
			continue
		end

		self:restore(button)
	end

	for button, want in wanted do
		self:enforce(button, want)
	end
end

--[=[
	Marca uma varredura para o fim do quadro.

	Uma loja que abre põe três cartas na tela em três `DescendantAdded` seguidos, e
	varrer a `PlayerGui` inteira três vezes seria pagar o mesmo preço três vezes pelo
	mesmo resultado. O `defer` junta o lote.
]=]
function ButtonGateController:schedule()
	if self.Pending then return end

	self.Pending = true

	local token = self.Token

	task.defer(function()
		self.Pending = false

		if self.Token ~= token or not self.Spec then return end

		self:apply()
	end)
end

--[=[
	Liga a válvula: passado o prazo, a trava cai e o output explica.
]=]
function ButtonGateController:armRelease(seconds : number?)
	if type(seconds) ~= "number" or seconds <= 0 then
		return
	end

	local token = self.ReleaseToken

	task.delay(seconds, function()
		if self.ReleaseToken ~= token or not self.Spec then return end

		warn(string.format(
			"[ButtonGateController]: a trava de botoes esta de pe ha %.0fs sem ninguem soltar; devolvendo a tela. "
				.. "Se o passo nao acabou, a whitelist dele nao cobre o botao que ele pede.",
			seconds
		))

		self:Unlock()
	end)
end

--[[ API ]]

--[=[
	Tranca a tela, deixando clicável só o que `Allow` disser.

		Gate:Lock({
			Allow = { "Interface.ReadyWave", "SharedUIs.DialogGUI.Container" },
			Block = { "Interface.SkipPrompt" },
			Ignore = { "Cmdr" },
			Release = 90,
		})

	`Allow` e `Block` aceitam caminho de tela (a partir da `PlayerGui`, como o
	`Highlight` do passo), a instância direto, ou uma função que devolve a instância —
	esta última para a peça clonada em runtime, que é reencontrada a cada varredura.
	Ver `resolve`.

	Chamar com a trava de pé **troca** a whitelist sem devolver a tela no meio: o que
	continua proibido continua desligado, e só a diferença se mexe. É o que impede a
	tela de piscar toda clicável entre um passo e o seguinte.
]=]
function ButtonGateController:Lock(spec : any)
	if type(spec) ~= "table" then return end

	self.Token += 1
	self.ReleaseToken += 1
	self.Spec = spec

	-- As escutas são refeitas pela varredura: o que esconde um botão muda de uma
	-- whitelist para a seguinte.
	self:unwatch()

	if not self.Connection then
		--[[
			A mesa da loja, a carta que vai para a mão, a lista de caixas: todas nascem
			com a trava já de pé, e sem esta escuta nasceriam clicáveis. É filtrado por
			`GuiButton` antes de marcar a varredura porque `DescendantAdded` na
			`PlayerGui` dispara para cada `UIStroke` e cada `TextLabel` de cada tela.
		]]
		self.Connection = PlayerGui.DescendantAdded:Connect(function(instance)
			if instance:IsA("GuiButton") then
				self:schedule()
			end
		end)
	end

	self:apply()
	self:armRelease(spec.Release)
end

--[=[
	Devolve a tela: cada botão volta ao `Active` e ao `Selectable` que tinha.
]=]
function ButtonGateController:Unlock()
	self.Token += 1
	self.ReleaseToken += 1
	self.Spec = nil

	if self.Connection then
		self.Connection:Disconnect()
		self.Connection = nil
	end

	self:unwatch()

	for button in self.Saved do
		self:restore(button)
	end

	table.clear(self.Saved)
end

--[=[
	Tira o prazo da válvula sem soltar a trava.

	É o que o passo cumprido chama. A válvula existe para o passo que **não
	reconheceu** o que o jogador fez; passo que já foi cumprido não pode ser
	destravado por ela — a wave está correndo, não há o que clicar, e devolver a tela
	ali seria soltar o jogador no meio do roteiro por ele ter esperado.
]=]
function ButtonGateController:HoldRelease()
	if not self.Spec then return end

	-- O número novo é o que faz a válvula marcada no `Lock` desistir quando acordar.
	self.ReleaseToken += 1
end

--[=[
	Reaplica a trava que está de pé. Serve para quem mexeu na tela por fora e quer a
	conta refeita agora, em vez de no próximo botão que nascer.
]=]
function ButtonGateController:Refresh()
	if not self.Spec then return end

	self:apply()
end

function ButtonGateController:IsLocked() : boolean
	return self.Spec ~= nil
end

--[[ CICLO DE VIDA ]]

function ButtonGateController:start()
end

function ButtonGateController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
end

return ButtonGateController
