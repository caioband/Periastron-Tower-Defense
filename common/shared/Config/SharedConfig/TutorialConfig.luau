--[[
	A oferta de tutorial: a primeira coisa que o jogo diz a quem nunca jogou.

	Quem decide que ela é devida é o servidor (`TutorialService`, olhando a chave
	`Tutorial` do perfil); quem a põe na tela é o `TutorialController`, pela caixa de
	fala de sempre. Aqui fica só o que se lê e se ajusta.

	As frases usam a marcação do `RichTextController` — `%s` é o nome do jogador, e
	é o controller que o preenche (escapado, porque nome de jogador é texto de
	jogador).
]]

local TutorialConfig = {}

--[[
	A fonte da oferta.

	Ela vive aqui, e não no `RichTextConfig.Defaults`, porque é escolha **desta**
	tela: o resto do texto rico do jogo continua no padrão do módulo até alguém
	decidir o contrário.
]]
TutorialConfig.Font = "rbxasset://fonts/families/PressStart2P.json"

--[=[
	O que a caixa de fala recebe junto das frases.

	`Size` é a altura da linha na caixa (ver `RichTextConfig.Presets.Dialogue`), e
	aqui ele é menor que o padrão de propósito: a Press Start 2P é quase
	monoespaçada e ocupa perto do dobro da largura por caractere que a fonte de
	antes — no mesmo 24 a saudação passaria do fim da caixa.
]=]
TutorialConfig.Text = {
	Preset = "Dialogue",
	Font = TutorialConfig.Font,
	Size = 20,
}

--[=[
	As opções de **qualquer** fala do tutorial: a fonte e o tamanho de `Text`, mais o
	que a conversa daquele momento pedir (esconder ou não a UI, os botões da
	escolha, o modo automático).

	Existe porque a fonte é a mesma nos três lugares que falam pelo tutorial — a
	oferta no lobby (`TutorialController`), os passos da partida
	(`TutorialStepController`) e a volta depois da vitória (`TutorialShopController`)
	— e eles vivem em places diferentes. Sem isto, trocar a fonte do tutorial seria
	trocá-la em três arquivos e esquecer um.

		dialog:Play(lines, TutorialConfig.Speech({ Auto = true, Blur = false }))

	O que quem chama passa **ganha** do que está em `Text`: a fala que quiser outro
	tamanho pede e recebe.
]=]
function TutorialConfig.Speech(options : { [string] : any }?) : { [string] : any }
	local resolved = table.clone(TutorialConfig.Text)

	for key, value in (options or {}) do
		resolved[key] = value
	end

	return resolved
end

--[[
	Quanto esperar, depois de o servidor mandar, antes de falar.

	O jogador acabou de cair no lobby: tem carregamento de UI, abertura e câmera
	acontecendo. Falar por cima disso é o mesmo que não falar.
]]
TutorialConfig.PromptDelay = 3

--[=[
	A trava de botões do tutorial, nas duas metades.

	O roteiro aponta uma coisa de cada vez, e **o que ele não aponta não é clicável**:
	quem está aprendendo onde fica o botão de Ready não pode abrir o board de
	dificuldade, vender a torre que o passo acabou de pedir ou pular a wave que o
	passo está esperando. Quem desliga é o `ButtonGateController`; daqui sai só o que
	é do tutorial.

	Cada passo diz o que libera (ver `Buttons` em `Match.Steps`, e o alvo de cada
	tempo do fluxo do lobby). Esta tabela é o que vale **em cima de qualquer passo**.

	> O nome é `ButtonGate`, e não `Buttons`, porque `TutorialConfig.Buttons` já é
	> outra coisa: os dois botões da escolha da oferta. São assuntos diferentes com a
	> mesma palavra, e o segundo a chegar apagaria o primeiro em silêncio.

	  - `Always` — sempre clicável, em todo passo das duas places. Hoje é só a caixa
	    de fala: um botão de escolha que não aceita clique é uma conversa sem saída, e
	    a caixa é a mesma nas duas metades;
	  - `Ignore` — telas em que a trava não pisa, por nome. O destaque já é ignorado
	    sem precisar ser dito. As outras três:

	      `Cmdr` porque trancar o console é trancar a ferramenta com que se destrava o
	      resto;

	      `TouchGui` e `MovementButtons` porque **movimento não é botão do roteiro**. É
	      a mesma linha que faz a trava ser nos botões e não no `BlockInput` do
	      destaque: o jogador continua dono da câmera e das próprias pernas enquanto
	      aprende onde clicar. No celular, andar, correr, dar dash e pular são botões de
	      tela — trancá-los junto seria travar o jogador no lugar, que é exatamente o
	      que se estava evitando;
	  - `Release` — a válvula, em segundos de passo **aberto**. Se a whitelist de um
	    passo não cobrir o botão que ele pede, o jogador ficaria com a tela morta e
	    ninguém para religá-la; passado o prazo a trava cai sozinha e o output diz por
	    quê.

	    Quatro minutos, e é para ser exagerado. Válvula que dispara em partida normal
	    não é válvula, é bug — e o piso não é o tempo que *eu* levo para cumprir o
	    passo, é o que um jogador que nunca viu o jogo leva. O intervalo do preset de
	    tutorial sozinho já são 45s (o passo do Ready fica aberto a contagem inteira
	    mesmo com o clique no primeiro segundo), e 90s morria no meio do passo do
	    Slingshot, com o jogador ainda lendo a fala e procurando o ponto no mapa.

	    Ela só corre enquanto o passo está **aberto**: cumprido o passo, o prazo sai
	    (`HoldRelease`) e a whitelist fica de pé até o passo seguinte — o jogador não
	    está preso, só não tem o que clicar enquanto a wave corre. Passo que precise
	    de outro prazo pede em `ButtonRelease`.
]=]
TutorialConfig.ButtonGate = {
	Always = { "SharedUIs.DialogGUI.Container" },
	Ignore = { "Cmdr", "TouchGui", "MovementButtons" },
	Release = 240,
}

--[=[
	As frases.

	1. Branco, nome em gradiente laranja, meio segundo de espera e o nome do jogo
	   em dourado com brilho.
	2. A pergunta, com "Tutorial" em gradiente verde animado.

	As paletas (`orange`, `green`) e o dourado (`gold`) moram em `RichTextConfig`,
	então mudar a cor da saudação não passa por aqui.
]=]
TutorialConfig.Lines = {
	"[color=white]Hello, [/color][gradient=orange]%s[/gradient][pause=0.5][color=white], welcome to [/color][gold]Periastron Tower Defense[/gold]",
	"[color=white]Would you like to play a [/color][gradient=green]Tutorial[/gradient][color=white]?[/color]",
}

--[=[
	Os dois botões da escolha.

	`AcceptIndex` e `DeclineIndex` são índices de `DialogConfig.Buttons.Names` — na
	caixa de hoje, 1 é o botão da direita e 2 é o da esquerda. Aceitar à direita é o
	que a maioria dos jogos faz, e trocar os dois é trocar os números aqui.

	Eles só aparecem quando a segunda frase termina de ser escrita: escolha no ar
	antes da pergunta ser lida é convite a responder no automático.
]=]
TutorialConfig.Buttons = {
	AcceptIndex = 1,
	AcceptText = "SURE!",

	DeclineIndex = 2,
	DeclineText = "NO THANKS",
}

--[=[
	A partida de tutorial.

	`Difficulty` é o nome do preset em `ServerScriptService.Config.Difficulty` — ele
	está **fora** do `Order`, então não aparece na votação; quem o impõe é o
	`TutorialMatchService`.

	`Deck` é o que o jogador leva para o mapa, **só nesta partida**: duas Archer e
	uma Slasher, três cartas para os três `PlacementPoints` do mapa. O perfil não é
	tocado — quem entra no tutorial com um deck montado o encontra intacto ao voltar
	ao lobby.

	`Map` é o nome do mapa em `ServerStorage.Maps`, e é o que o Lobby manda no
	TeleportData junto da flag.
]=]
TutorialConfig.Match = {
	Map = "Tutorial",
	Difficulty = "Tutorial",

	--[[
		Uma entrada por carta da hotbar, na ordem em que elas aparecem. É lista, e
		não dicionário, porque `{ Archer = 2 }` não tem ordem — e a hotbar tem.
	]]
	Deck = {
		{ Unit = "Slingshot", Amount = 1 },
		{ Unit = "Archer", Amount = 2 },
	},

	--[=[
		As únicas cartas que a mão aceita durante o tutorial.

		O roteiro inteiro é sobre uma torre só: o jogador coloca a Slingshot na wave
		1 e aprende clima, loja e velocidade com ela na tela. As outras ficam
		trancadas — `Active = false` e apagadas — **até a última wave**, quando o
		passo do fecho (`UnlocksDeck`) solta o deck para ele cobrir o mapa antes do
		chefe.

		A trava vale entre os passos também, e não só enquanto um está aberto: o
		servidor recusa (`CanPlace`) e o cliente nem aceita o clique.
	]=]
	AllowedUnits = { "Slingshot" },

	--[=[
		O roteiro, um passo por wave.

		  - `Wave`   — em qual wave o passo acontece. O servidor o abre **antes** de a
		               wave nascer. **Zero é o intervalo**, o tempo de preparo que
		               corre antes da wave 1: é onde mora o passo do botão de Ready,
		               e é a única wave do roteiro que não nasce ninguém.
		  - `Kind`   — o que o jogador tem de fazer: `"Ready"` (o botão do intervalo),
		               `"Place"`, `"Buy"` (a carta do RCS), `"Use"`, `"Speed"` (o 2x) e
		               `"PlaceRest"`, o fecho da wave 5.
		  - `Hold`   — `true` segura a wave até o passo ser cumprido. É o que impede a
		               wave 1 de nascer com o mapa vazio.
		  - `Unit`   — a única carta que a mão aceita enquanto o passo está aberto. As
		               outras ficam apagadas no cliente **e** recusadas no servidor.
		  - `Point`  — o nome da part em `Map.PlacementPoints` onde a unidade tem de
		               entrar, e `Radius` é a tolerância em studs. O jogador arrasta
		               para perto; não precisa acertar o pixel.

		               **O raio tem de ser menor que a distância entre dois pontos**,
		               que no mapa de hoje é 4.7 studs. Com 10, colocar no ponto 2
		               passava como se fosse o 1 — o passo pedia um lugar e aceitava
		               outro.
		  - `Lines`  — o que a caixa de fala diz ao abrir o passo, com a marcação de
		               sempre. Passo sem fala nenhuma vai direto ao destaque.
		  - `Buttons` — **a whitelist de botões do passo**: o que o jogador pode clicar
		               enquanto ele está aberto. Tudo o que não estiver aqui (nem for
		               filho ou pai de algo que esteja, nem estiver em
		               `TutorialConfig.ButtonGate.Always`) para de aceitar clique.

		               Cada entrada é um caminho de tela a partir da `PlayerGui` — o
		               mesmo de `Highlight` — ou um dos apelidos que o controller
		               resolve na hora, porque a peça só existe em runtime:

		                 `@Highlight` o que o destaque está abraçando agora
		                 `@Deck`      a hotbar inteira (`Interface.TowerContainer`)
		                 `@Card`      a carta de `Unit` na hotbar
		                 `@Hand`      a carta de round `Card` já na mão
		                 `@Offer`     a carta `Card` na mesa da loja

		               **A whitelist sobrevive ao passo**: cumprido ele, ela continua de
		               pé até o passo seguinte abrir. A trava é da partida, como a do
		               deck (`AllowedUnits`) e a do `CanPlace` — sem isso o jogador
		               destravaria a tela inteira no intervalo entre duas waves.

		               Passo sem `Buttons` não tranca nada, e é assim que um roteiro
		               antigo continua funcionando.
		  - `BlockedButtons` — a subtração, para quando a whitelist é um painel inteiro
		               e um botão de dentro dele não pode ser clicado. Ganha do
		               `Buttons`.
		  - `ButtonRelease` — o prazo da válvula **deste** passo, em segundos, quando o
		               de `TutorialConfig.ButtonGate.Release` não serve.
		  - `GrantCash` — quantos de dinheiro o passo **dá** ao abrir, para todo mundo.
		               É presente, e não a rede do `Ensure`: entra inteiro, uma vez por
		               passo, sem olhar quanto o jogador tem. É o que garante que o
		               fecho do roteiro encontre a carteira cheia o bastante para as
		               cartas que ele pede, mesmo depois de a partida inteira ter sido
		               gasta em outra coisa.
		  - `HideDeck` — `true` tira o `Interface.TowerContainer` inteiro da tela enquanto
		               o passo está aberto, e o devolve quando ele fecha. Quem mexe no
		               `Visible` é o `DifficultyController` (`HoldHotbar`).

		A wave 1 pede a **Slingshot**, e ela é a única carta liberada até a wave 5
		(ver `AllowedUnits`): o tutorial ensina clima, loja e velocidade com uma torre
		só na tela, em vez de com um deck que o jogador ainda não sabe montar.
	]=]
	Steps = {
		--[[
			O primeiro passo de todos, e o único que acontece fora de uma wave.

			O intervalo antes da wave 1 já existe para todo mundo — é o tempo de
			preparo, com a contagem e o botão de Ready no canto. O tutorial só o aponta:
			a fala explica o botão, o destaque o abraça (`Interface.ReadyWave`, o
			`ImageButton` que o `ReadyController` monta) e o passo fecha **quando a
			contagem termina** — no tempo dela ou antes, porque todo mundo ficou pronto,
			que numa partida de tutorial é o primeiro clique do jogador.

			Sem `Hold`: quem segura aqui é a própria contagem do intervalo, e o passo
			não tem o que esperar depois dela. Sem `BlockInput` também, como os outros
			passos da partida — apontar o botão não pode tirar do jogador a câmera nem o
			resto do HUD que ele está vendo pela primeira vez.
		]]
		{
			Id = "ClickReady",
			Wave = 0,
			Kind = "Ready",

			Highlight = "Interface.ReadyWave",

			--[[
				O botão de Ready e nada mais.

				O `WeatherButton` fica de fora mesmo sendo inofensivo: o passo manda olhar
				em volta e apertar um botão, e um segundo botão aceso no mesmo canto é
				exatamente a dúvida que o passo existe para não criar. O clima aparece na
				wave 3, com um passo só para ele.
			]]
			Buttons = { "Interface.ReadyWave" },

			--[[
				O `Interface.TowerContainer` inteiro fora da tela enquanto este passo
				está aberto, e de volta quando ele fecha (a contagem acabou). Ainda não há
				o que colocar: as cartas só entram no passo seguinte, na wave 1.
			]]
			HideDeck = true,

			Lines = {
				"[color=white]Take your time to look around.[/color][pause=0.4] When you're set, hit [gradient=green]READY[/gradient][color=white] — the wave starts when the timer runs out.[/color]",
			},
		},

		{
			Id = "PlaceFirst",
			Wave = 1,
			Kind = "Place",
			Hold = true,

			Unit = "Slingshot",
			Point = "1",
			Radius = 3,

			--[[
				Só a carta que o passo pede.

				A hotbar já apaga as outras (`AllowedUnits`), mas apagada e desligada não
				são a mesma coisa: `@Card` é o que garante que o clique numa carta apagada
				não chegue a lugar nenhum. E o par das duas é o que faz a tela dizer a
				mesma coisa que o servidor responderia (`CanPlace`).
			]]
			Buttons = { "@Card" },

			Lines = {
				"[color=white]This is your deck.[/color][pause=0.4] Drag the [gradient=orange]Slingshot[/gradient] onto the marked spot.",
			},
		},

		--[[
			A oferta de cartas de round.

			`OpenShop` é o que abre a loja nesta wave — e **esta é a única wave do
			tutorial em que ela aparece**: o calendário do `RoundCardConfig.IsShopWave`
			não vale aqui (ver `TutorialMatchService:ShopIsScripted`), então a oferta
			não volta sozinha na wave 4 por cima do passo do 2x. `Card` é a carta que
			entra na rotação na marra e a única que o passo aceita comprar — as outras
			duas continuam na mesa, visíveis, e recusadas até ele comprar a certa.

			`Ensure` é a rede contra o beco sem saída: o passo **segura a wave** até a
			compra, e um jogador sem os 300 do Weather Report ficaria preso para
			sempre. Faltando dinheiro, o tutorial completa a diferença — uma vez, e só
			até o preço.

			`ScheduleWeather` agenda um dos três climas para a wave seguinte. Agendar
			aqui, e não lá, é de propósito: é assim que o aviso de clima aparece na
			tela antes de o clima cair, que é a coisa que este passo está ensinando a
			ler.
		]]
		{
			Id = "BuyReport",
			Wave = 2,
			Kind = "Buy",
			Hold = true,

			OpenShop = true,
			Card = "WeatherReport",
			Ensure = true,

			--[[
				O botão que abre a oferta, na beirada da tela
				(`RoundCardConfig.Gui`: tela `RoundCardShop`, frame `RCSFrame`, botão
				`CardShop`). O destaque começa nele; quando a loja abre, ele passa
				sozinho para a carta que o passo exige — ver `awaitCard`.
			]]
			Highlight = "RoundCardShop.RCSFrame.CardShop",

			ScheduleWeather = { "Drought", "Fog", "Rain" },

			--[=[
				O botão que abre a loja **e** a carta que o passo manda comprar.

				Os dois, e não só o que o destaque está apontando no momento: o destaque
				escorrega do botão para a carta quando a loja abre (ver `awaitCard`), e uma
				whitelist que o seguisse deixaria o botão de fechar a loja mudo no meio do
				passo — o jogador abriria a mesa e não teria como sair dela.

				As outras duas cartas da mesa continuam clicáveis de propósito: elas estão
				dentro de `Background.RoundCardShop`, que não está liberado, então o clique
				não passa — mas o `CanBuy` do servidor já recusava, e é ele quem manda. O
				que muda aqui é o jogador não ficar tentando.
			]=]
			Buttons = { "RoundCardShop.RCSFrame.CardShop", "@Offer" },

			Lines = {
				"[color=white]Cards show up between waves.[/color][pause=0.4] Buy the [gradient=green]Weather Report[/gradient] — you'll need it.",
			},
		},

		--[[
			O clima caiu. O passo pede o uso da carta comprada na wave anterior.

			`Hold` aqui **funciona** porque o clima entra antes do portão: quem o
			aplica é o `WeatherRoundService`, no sinal `WaveStarted` que o `setWave`
			dispara — e o portão do tutorial só fecha depois disso. Então a ordem que o
			jogador vê é: o céu vira, a instrução aparece, ele usa a carta, e **só
			então** os inimigos da wave nascem.

			A carta também não pode ser usada antes da hora: enquanto este passo não
			abre, o `CanUse` a recusa (no servidor) e a mão não a aceita (no cliente).
		]]
		{
			Id = "UseReport",
			Wave = 3,
			Kind = "Use",
			Hold = true,

			Card = "WeatherReport",

			-- A carta comprada, que agora está na mão. A hotbar de unidades está vazia
			-- (a Slingshot foi para o mapa na wave 1), então não há mais nada a liberar.
			Buttons = { "@Hand" },

			Lines = {
				"[color=white]The weather is here — it buffs some enemies and weakens your towers.[/color]",
				"[color=white]Use your[/color] [gradient=green]Weather Report[/gradient] [color=white]to clear it for this wave.[/color]",
			},
		},

		--[=[
			O botão de velocidade.

			`Hold` segura a wave 4 até o jogador acelerar a partida — o tempo fica parado,
			como pedido. `Highlight` é o caminho da tela, a partir da `PlayerGui`, que o
			destaque abraça.

			**`Index` é o degrau do `SpeedConfig`, e o degrau 2 é o 1,5x** — não o 2x. A
			ordem lá é `1 = 1x`, `2 = 1,5x`, `3 = 2x`, e é de propósito que o roteiro pare
			no segundo: **o 2x pede gamepass** (`Steps[3].Gamepass = "Speed"`), e um passo
			que segura a wave atrás de uma compra é um beco sem saída para quem não a tem.
			O 1,5x é de graça para todo mundo, e a lição — "dá para acelerar" — é a mesma.

			Trocar este número é trocar a fala junto: ela nomeia o degrau que o destaque
			vai apontar.

			**O menu não é um painel.** O botão clona a si mesmo uma vez por degrau e
			pendura os clones ao lado dele, no mesmo pai — eles não são filhos do botão.
			Por isso a whitelist pede `@SpeedOptions` além do botão: sem isso o menu abre
			e nenhuma opção aceita clique. Quando ele abre, o destaque escorrega do botão
			para o degrau de `Index` (ver `watchSpeedOptions`).
		]=]
		{
			Id = "UseSpeed",
			Wave = 4,
			Kind = "Speed",
			Hold = true,

			Index = 2,
			Highlight = "Interface.Speed",

			Buttons = { "Interface.Speed", "@SpeedOptions" },

			Lines = {
				"[color=white]In a hurry?[/color][pause=0.3] Tap [gradient=orange]1.5x[/gradient] to speed the match up.",
			},
		},

		--[[
			O fecho: o resto do deck no chão, e então o chefe.

			`Kind = "PlaceRest"` é o irmão do `Place` para quando o passo não quer uma
			carta específica num ponto específico, e sim **todas as que sobraram** nos
			**pontos que sobraram**. O passo fecha quando a mão esvazia.

			`Points` são os pontos livres depois da wave 1. Qualquer carta em qualquer
			um deles serve: a lição aqui é cobrir o mapa, não obedecer a um lugar.

			O chefe não precisa ser pedido: `Wave.HasBoss` é `wave >= MaxWaves`, e o
			preset do tutorial tem `MaxWaves = 5` — a wave 5 já nasce com ele. E ele
			nasce fraco pelo mesmo preset (`HealthMultiplier = 0.35`,
			`BossAmountMultiplier = 1`), que é o "com menos vida que o normal" pedido.
		]]
		{
			Id = "PlaceRest",
			Wave = 5,
			Kind = "PlaceRest",
			Hold = true,

			-- É aqui que o resto do deck destranca, e só aqui.
			UnlocksDeck = true,

			--[[
				O dinheiro das cartas que este passo pede.

				Duas Archer a 150 dão exatamente 300 — o passo paga o que ele cobra, e
				o jogador não chega no fecho descobrindo que não tem com que cobrir os
				pontos livres. É soma, não teto: quem economizou a partida inteira fica
				com sobra, e sobra no último passo de uma partida que acaba na wave
				seguinte não desequilibra nada.
			]]
			GrantCash = 300,

			Points = { "2", "3" },
			Radius = 3,

			--[[
				A hotbar inteira, e não uma carta: é o passo que solta o deck
				(`UnlocksDeck`), e a lição aqui é cobrir o mapa com o que se tem. Qual
				carta vale em qual ponto continua sendo conta do `CanPlace`.
			]]
			Buttons = { "@Deck" },

			Lines = {
				"[color=white]Last wave — and it brings a[/color] [gradient=orange]boss[/gradient][color=white].[/color]",
				"[color=white]Put the rest of your deck on the open spots.[/color]",
			},
		},

		--[=[
			O fecho do fecho: a tela de resultado.

			Não tem `Wave` porque não acontece em wave nenhuma — quem o abre é o
			`onRoundEnded`, pelo `BeginFinal`, no mesmo instante em que a tela de
			resultado é mandada. É o único passo do roteiro que vive depois da partida.

			**Sem `Lines`**: a tela de resultado é o que o jogador tem de ler agora, e
			uma caixa de fala por cima dela estaria cobrindo justamente o prêmio que ele
			acabou de ganhar. O passo é só o holofote.

			`HighlightWait` é maior que o padrão porque o botão nasce escondido e entra
			no fim de uma coreografia longa (backdrop, painel, recompensas, barra de XP
			— ver `ResultController`), e o destaque recusa alvo que ainda não está na
			tela. O orçamento é generoso de propósito: errar para mais custa uma espera
			que ninguém vê, e errar para menos custa o passo inteiro.

			Quem tranca o "PLAY AGAIN" ao lado é o `ResultController`: botão é assunto
			de quem é dono da tela, e o tutorial só é perguntado se esta partida é a
			dele.
		]=]
		{
			Id = "BackToLobby",
			Kind = "Lobby",

			Highlight = "ResultScreen.MainScreen.Lobby",
			HighlightWait = 20,

			--[=[
				Só o botão de voltar ao lobby.

				O "PLAY AGAIN" ao lado já é trancado pelo `ResultController` — botão é
				assunto de quem é dono da tela —, e por isso ele nem chega a esta conta: a
				trava não toca em botão que já estava desligado.

				O prazo é o maior do roteiro, e o motivo não é a coreografia longa que faz o
				botão nascer (backdrop, painel, recompensas, barra de XP): é que **este passo
				não tem um seguinte**. Nos outros, uma válvula que dispara cedo demais é
				corrigida pelo passo que abre na wave seguinte e tranca a tela de novo; aqui
				não abre passo nenhum, e o que a válvula soltar fica solto até o teleporte.
				Errar para mais custa nada, e errar para menos custa a tela inteira.
			]=]
			Buttons = { "ResultScreen.MainScreen.Lobby" },
			ButtonRelease = 600,
		},
	},
}

--[=[
	A segunda metade do tutorial: a que acontece **no lobby**, depois da vitória.

	Ela não é gravada em lugar nenhum — o servidor da partida embarca `TutorialDone`
	no teleporte de volta, e o lobby a roda naquela sessão. Acontece uma vez, logo
	depois da partida, e some se o jogador sair. É um empurrãozinho, não um marco.

	**É um fluxo fechado**: cada passo aponta a única coisa clicável do momento, e o
	destaque entra com `BlockInput` — os quatro frames em volta do buraco engolem
	tudo o que estiver fora dele. Quem está aprendendo não tem como se perder no meio
	do caminho, e não existe passo esperando por um clique que o jogador já deu em
	outro lugar.

	Os caminhos são de nome, a partir da `PlayerGui`, e o `HighlightController:Find`
	anda em profundidade — por isso `HUDFrame.Wrapper.Shop` acha o wrapper certo
	entre os vários irmãos de mesmo nome.
]=]
TutorialConfig.Lobby = {
	Lines = {
		"[color=white]Nice work![/color][pause=0.4] Let's spend those coins — open the [gold]Shop[/gold].",
	},

	-- Passo 1: o botão da loja no HUD.
	ShopButton = "HUD.HUDFrame.Wrapper.Shop",

	-- Passo 2: a caixa a comprar e o botão de compra **dentro** do container dela.
	Item = "CrateOfBeginnings",
	BuyButton = "Buy",

	-- Passo 3: a mochila, e a lista de caixas dentro dela. A caixa apontada é a
	-- primeira da lista — é a que o jogador acabou de comprar.
	BackpackButton = "HUD.HUDFrame.Wrapper.Backpack",

	--[[
		O **wrapper** das caixas, e não o `scrollcrates` que o embala: é ele que o
		`CrateController` enche com uma entrada por raridade, clonadas do
		`cratetemplate` — que fica ali dentro, escondido, para o designer poder
		continuar editando.

		Apontar o scroll pegava o molde escondido em vez da caixa do jogador: um
		destaque em cima de algo invisível parece destaque nenhum.
	]]
	CrateList = "crateui.Rectangle.scrollcrates.CrateWrapper",

	--[[
		O prefixo das entradas de verdade (`Crate_Common`, `Crate_Rare`, ...), que o
		`CrateController` usa ao clonar o molde. Preferir o prefixo é o que separa a
		caixa do jogador do molde, mesmo no quadro em que o molde ainda não foi
		escondido — o `CrateController` o esconde no bind, e o fluxo pode chegar lá
		antes.
	]]
	CratePrefix = "Crate_",

	-- A fala do fim, depois de o unboxing terminar.
	ClosingLines = {
		"[color=white]That's a[/color] [gradient=green]new unit[/gradient][color=white] for your deck.[/color][pause=0.4] You're ready — good luck out there!",
	},

	--[[
		De quanto em quanto tempo o fluxo confere se o jogador fez o que o passo
		pedia (a loja abriu, a mochila abriu). É espera de gente clicando, não de
		animação: um quinto de segundo é imperceptível para ele e não custa nada.
	]]
	PollInterval = 0.2,

	--[[
		Quanto esperar por uma peça de tela que ainda não existe — o botão de comprar
		aparece quando a loja monta a lista, a caixa aparece quando a mochila abre.
		Estourando, o passo segue sem destaque em vez de travar o jogador.
	]]
	WaitForUi = 5,

	--[=[
		Quantos segundos de espera **sem nada acontecer** antes de o fluxo soltar a
		trava dos botões.

		É a rede de segurança do "não deixe clicar em nada fora do passo": se o passo
		não reconhecer o que o jogador fez — a loja que abriu por um caminho que o
		fluxo não esperava, uma tela que mudou de nome —, a trava viraria um jogo
		morto, com o botão certo desligado e ninguém para religá-lo. Passado o prazo,
		os botões voltam (o destaque fica) e o jogador segue a vida.
	]=]
	StallRelease = 25,
}

--[=[
	A garantia de unit épica para quem está começando.

	Dentro das **três primeiras** caixas abertas na vida do perfil, uma vem Epic ou
	melhor. A conta é o `Stats.BoxesOpened`, que já existe e já conta abertura de
	verdade (o `unbox` do Cmdr não entra) — nenhuma chave nova no perfil.

	A garantia cai na terceira: as duas primeiras rolam normal, e é só quando a
	terceira chega sem nenhuma Epic ter saído que o sorteio é forçado. Assim quem tem
	sorte na primeira não "gasta" a garantia, e quem não tem sai das três com uma.
]=]
TutorialConfig.CrateGuarantee = {
	Crates = 3,
	Rarity = "Epic",
}

return TutorialConfig
