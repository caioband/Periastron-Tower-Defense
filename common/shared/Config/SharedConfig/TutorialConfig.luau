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

--[[
	Quanto esperar, depois de o servidor mandar, antes de falar.

	O jogador acabou de cair no lobby: tem carregamento de UI, abertura e câmera
	acontecendo. Falar por cima disso é o mesmo que não falar.
]]
TutorialConfig.PromptDelay = 3

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
		               wave nascer.
		  - `Kind`   — o que o jogador tem de fazer. Hoje só `"Place"`; as próximas
		               fatias trazem `"Buy"` (a carta do RCS), `"Speed"` (o 2x) e o
		               fecho da wave 5.
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
		               sempre.

		A wave 1 pede a **Slingshot**, e ela é a única carta liberada até a wave 5
		(ver `AllowedUnits`): o tutorial ensina clima, loja e velocidade com uma torre
		só na tela, em vez de com um deck que o jogador ainda não sabe montar.
	]=]
	Steps = {
		{
			Id = "PlaceFirst",
			Wave = 1,
			Kind = "Place",
			Hold = true,

			Unit = "Slingshot",
			Point = "1",
			Radius = 3,

			Lines = {
				"[color=white]This is your deck.[/color][pause=0.4] Drag the [gradient=orange]Slingshot[/gradient] onto the marked spot.",
			},
		},

		--[[
			A oferta de cartas de round.

			`OpenShop` força a loja a abrir nesta wave, que de outro jeito seguiria o
			calendário do `RoundCardConfig.IsShopWave`. `Card` é a carta que entra na
			rotação na marra e a única que o passo aceita comprar — as outras duas
			continuam na mesa, visíveis, e recusadas até ele comprar a certa.

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

			Lines = {
				"[color=white]The weather is here — it buffs some enemies and weakens your towers.[/color]",
				"[color=white]Use your[/color] [gradient=green]Weather Report[/gradient] [color=white]to clear it for this wave.[/color]",
			},
		},

		--[[
			O botão de velocidade.

			`Hold` segura a wave 4 até o jogador pôr a partida em 2x — o tempo fica
			parado, como pedido. `Index` é o degrau do `SpeedConfig` (1 = 1x, 2 = 2x), e
			`Highlight` é o caminho da tela, a partir da `PlayerGui`, que o destaque
			abraça.

			Não há nada a liberar: o 2x já é de graça para todo mundo no jogo: o
			`SpeedService:SetIndex` não cobra nem pede gamepass.
		]]
		{
			Id = "UseSpeed",
			Wave = 4,
			Kind = "Speed",
			Hold = true,

			Index = 2,
			Highlight = "Interface.Speed",

			Lines = {
				"[color=white]In a hurry?[/color][pause=0.3] Tap [gradient=orange]2x[/gradient] to speed the match up.",
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

			Points = { "2", "3" },
			Radius = 3,

			Lines = {
				"[color=white]Last wave — and it brings a[/color] [gradient=orange]boss[/gradient][color=white].[/color]",
				"[color=white]Put the rest of your deck on the open spots.[/color]",
			},
		},
	},
}

--[=[
	O passo que acontece **no lobby**, depois da vitória.

	Ele não é gravado em lugar nenhum: o servidor do tutorial embarca `TutorialDone`
	no teleporte de volta, e o lobby aponta a loja naquela sessão. Acontece uma vez,
	logo depois da partida, e some se o jogador sair — que é o comportamento certo
	para um empurrãozinho, não para um marco.

	`Item` é o id do `ShopConfig`: a caixa mais barata. `Highlight` é o caminho do
	botão na `PlayerGui`.
]=]
TutorialConfig.Shop = {
	Highlight = "HUD.HUDFrame.Wrapper.Shop",
	Item = "CrateOfBeginnings",

	Lines = {
		"[color=white]Nice work![/color][pause=0.4] Spend your coins on a [gold]Crate of Beginnings[/gold] over here.",
	},
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
