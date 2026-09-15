--[[
	A loja de cartas de round: `StarterGui.RoundCardShop`.

	De X em X waves o botão da loja entra pela direita da tela e oferece **três
	cartas sorteadas** desta tabela. A carta comprada sai do caixa da partida
	(o `roundcash` do `MobService`, e não o `Cash` do perfil), vai para a hotbar
	do jogador e vale **um uso**: clicar nela dispara o efeito e a carta some.

	As cartas são de partida, e não de deck: elas não passam pelo perfil, não
	sobrevivem ao round e não têm nada a ver com o `DeckConfig`. O que elas mexem
	é no estado da sala — os inimigos, o relógio e o céu —, e por isso **quem
	executa o efeito é o servidor** (`CardShopService`): daqui sai só a
	declaração de qual efeito a carta aciona e com que número.

	Este módulo é compartilhado porque as duas pontas precisam dele: o cliente lê
	título, descrição, preço e arte para desenhar a carta; o servidor lê o mesmo
	`Id` para saber o que a compra autoriza e o que o uso executa. Sorteio e
	cobrança acontecem **só no servidor** — o cliente nunca decide qual carta saiu
	nem se o dinheiro deu.
]]

local RoundCardConfig = {}

--[[ ONDE A LOJA MORA NA GUI ]]

--[[
	Os nomes autorados, num lugar só. O controller não procura nada por caminho
	escrito à mão: renomear uma peça no Studio é uma linha aqui.
]]
RoundCardConfig.Gui = {
	ScreenGui = "RoundCardShop",

	-- O botão que fica na beirada da tela, e o `ImageButton` dentro dele.
	Frame = "RCSFrame",
	Button = "CardShop",

	-- O escurecido de tela cheia e a fileira de cartas dentro dele.
	Background = "Background",
	Row = "RoundCardShop",

	-- O molde de uma carta: o wrapper é quem entra no `UIListLayout` da fileira,
	-- e o template é a carta em si (é ele que anima).
	Wrapper = "CardWrapper",
	Card = "CardTemplate",

	Title = "CardTitle",
	Description = "CardDescription",

	-- O preço mora numa placa própria, que sai da carta quando ela vai para a
	-- hotbar: no deck a carta já foi paga.
	Price = "PriceLabel",
	PriceLabel = "CardPrice",
}

--[[ QUANDO A LOJA APARECE ]]

--[[
	De quantas em quantas waves a loja é oferecida, por dificuldade.

	O número é o intervalo, não a wave: com 4, a loja aparece nas waves 4, 8, 12…
	Dificuldade mais longa espaça mais — o Nightmare tem 35 waves contra as 15 do
	Easy, e um intervalo fixo faria a partida do topo ter mais que o dobro de
	cartas da de baixo.

	Preset sem entrada cai no `DefaultInterval`.
]]
RoundCardConfig.Intervals = {
	Easy = 4,
	Medium = 4,
	Hard = 5,
	Impossible = 6,
	Nightmare = 6,
}

RoundCardConfig.DefaultInterval = 4

--- Quantas cartas a loja mostra por oferta.
RoundCardConfig.DrawCount = 3

--[[
	Os **parâmetros** do marcador de keyframe do `Visual` — não são nomes de
	marcador. A animação carrega um marcador só, o que estiver no `Visual.Marker` da
	carta, e o parâmetro dele diz qual metade do gesto dispara.

	Moram aqui porque as duas pontas precisam da mesma palavra: o cliente compara com
	o que o marcador entrega, e o servidor procura por `VFX` na animação quando vai
	conferir o `EffectDelay`.
]]
RoundCardConfig.Markers = {
	Sound = "Sound",
	VFX = "VFX",
}

--[[ COMO A CARTA É USADA ]]

--[=[
	O tipo de uso de uma carta: o que acontece entre o clique nela e o efeito.

	| Tipo | O clique na hotbar… |
	| --- | --- |
	| `Instant` | já é o uso. A carta some e o efeito entra |
	| `Unit` | pede **uma unidade**: o próximo clique no mapa escolhe a torre |
	| `Area` | pede **um lugar**: um anel segue o ponteiro e o clique confirma |
	| `Move` | pede os dois, nesta ordem: a unidade e para onde ela vai |

	`Move` não é um quarto conceito, é os dois anteriores em fila — é o que o
	Zippers precisa (qual torre, e para onde), e escrevê-lo como um tipo próprio
	evita que a carta tenha que inventar um segundo clique por fora do fluxo.

	Carta sem `Use` é `Instant`: é o que as três cartas originais sempre foram, e
	assim elas continuam valendo sem ganhar um campo que não muda nada.

	**Quem confere é o servidor.** O cliente escolhe o alvo e manda junto com o uso;
	o `CardShopService` recusa alvo que não bate com o tipo da carta — unidade que
	não existe, ponto longe demais, alvo faltando. O tipo aqui é o que a **tela**
	precisa saber para pedir a coisa certa.
]=]
RoundCardConfig.Use = {
	Instant = "Instant",
	Unit = "Unit",
	Area = "Area",
	Move = "Move",
}

--[=[
	A mira: o que o jogador vê enquanto a carta espera um alvo.

	O anel é o mesmo modelo que o posicionamento já usa para o alcance de uma torre
	(`Assets.UI.AOE.Ring`), e de propósito: o jogador já aprendeu que aquele
	desenho quer dizer "esta área". Um segundo desenho para a mesma ideia só
	ensinaria a mesma coisa duas vezes.

	**Não há painel nem botão de cancelar.** Quem diz que a mira está aberta é a
	própria carta na hotbar: ela cresce e apaga as vizinhas, exatamente como uma
	carta de unidade equipada. Desistir é clicar nela de novo — a mesma coisa que
	largar uma unidade —, ou Esc no PC.

	As cores separam o que a mira está pedindo: verde é "escolha um lugar" e amarelo
	é "escolha uma torre". O vermelho é o terceiro estado do anel de área, e não uma
	quarta coisa que a mira pede: ele é "aqui não" — o lugar debaixo do cursor encosta
	numa área que **este mesmo jogador** já desenhou, e o clique ali não vale. É o
	mesmo par verde/vermelho do fantasma de uma torre sendo posicionada, e de
	propósito: é a frase que o jogador já sabe ler.

	O segundo passo do Zippers -- a torre já escolhida, faltando o destino -- não tem
	cor aqui porque ele não é uma mira: ele é o posicionamento inteiro, desenhado
	pelo `UnitPlacementController:visualize`, com o fantasma da própria torre em
	verde ou vermelho e o anel do alcance dela. Ver `_beginMovePlacement`.

	O amarelo do `Unit` é o realce que a torre debaixo do ponteiro recebe, e ele vale
	nos dois caminhos: a carta que não mexe em estatística nenhuma (o Zippers) é
	pintada pelo próprio `RoundCardShopController`, e a que mexe é pintada pelo
	`WeatherFeedbackController` junto com os ícones do que ela vai sentir — um realce
	só na torre, senão as duas cores brigariam no mesmo modelo. Por isso a cor mora
	aqui, e os dois a leem daqui.
]=]
RoundCardConfig.Targeting = {
	RingAsset = { "AOE", "Ring" },

	-- A part de dentro do anel cujo diâmetro serve de régua para a escala. O nome
	-- veio assim do Studio, e é o mesmo que o `UnitPlacementController` procura.
	RingPart = "Renge",

	-- Raio do anel de uma carta de área que não declare o seu, em studs.
	DefaultRadius = 6,

	--[[
		O quão longe do centro do mapa um alvo pode estar.

		É o mesmo teto do `PlaceUnit` e existe pelo mesmo motivo: um cliente
		adulterado manda a posição que quiser, e um efeito de área centrado a dez mil
		studs daqui não é jogada, é lixo no estado da sala.
	]]
	MaxDistance = 2000,

	Colors = {
		Area = Color3.fromRGB(120, 235, 140),
		Unit = Color3.fromRGB(255, 215, 60),

		-- O anel de área em cima de outra área do mesmo jogador: aqui não.
		Blocked = Color3.fromRGB(235, 85, 85),
	},
}

--[=[
	O estouro que a torre solta quando uma carta de alvo único encosta nela.

	É o nome de um asset em `Assets.VFX` -- um Attachment de emissores de rajada --,
	pendurado na `HumanoidRootPart` da torre e estourado pelo `VFXController`. Ele é
	o "pegou": a mira já disse qual torre, e sem nada acontecendo no instante do uso
	a carta some da mão e o jogador fica sem saber se ela valeu.

	Quem dispara é o servidor, para todo mundo na sala ver o estouro na mesma torre
	-- do mesmo jeito que o raio e o dinheiro da aura.
]=]
RoundCardConfig.AppliedVFX = "EffectUnitAppliedVFX"

--[=[
	O anel que **fica** no chão depois que a carta de área é usada.

	Não é o mesmo da mira. O da mira é o círculo neutro do posicionamento, que só diz
	"esta área" enquanto o jogador escolhe; este é a arte da carta, um Model por
	efeito em `Assets.VFX.Rings` — o dourado do Robux, o vento do Winds, o azul do
	Celestial. Ele nasce onde o jogador clicou e vive exatamente o tempo do efeito:
	até o fim do round nos cajados de zona, e os segundos da imunidade no Staff of
	Healing.

	`Path` é o caminho a partir de `ReplicatedStorage.Shared.Assets`. `Default` é o
	anel de quem não declara um `Ring` próprio — carta nova de área aparece no chão
	sem precisar de arte nova. `PartSuffix` é como a régua do raio é achada dentro do
	Model: o `Celestial` traz um `Celestial_Ring`, e é o diâmetro **dessa** Part que
	a escala usa.

	A régua é uma Part nomeada, e não a caixa do Model, de propósito: um Model de VFX
	tem emissor de partícula e attachment espalhados, e medir a caixa inteira faria o
	anel encolher só porque alguém arrastou uma faísca para fora dele.
]=]
RoundCardConfig.Rings = {
	Path = { "VFX", "Rings" },
	Default = "Base",
	PartSuffix = "_Ring",

	-- A pasta que o cliente cria no Workspace para guardar os aneis desenhados. Ver
	-- `CardModifierController:_ringContainer`.
	Container = "RoundCardRings",

	-- Quanto o anel leva para crescer até o tamanho dele, em segundos reais.
	Grow = 0.35,
}

--[[ ANIMAÇÃO ]]

--[[
	Os tempos da tela, em segundos reais.

	Nada aqui passa pelo `GameClock`: é tempo de o jogador ler e escolher, e não
	ritmo de partida. Acelerar o jogo para 2x não pode encurtar a leitura de três
	cartas.
]]
RoundCardConfig.Animation = {
	--[[
		O botão entra pela direita: nasce em `HiddenX` (fora da tela) e corre até o
		X que o designer deixou autorado no `RCSFrame`. O `Circular` é o pedido —
		ele chega devagar no fim, que é o que dá o encaixe na beirada.
	]]
	HiddenX = 1,
	SlideIn = 0.5,
	SlideOut = 0.35,
	SlideEasing = Enum.EasingStyle.Circular,

	--[[
		O balanço do botão, enquanto a oferta está de pé e ninguém clicou nele.

		Ele sobe `IdleLift` pixels e fica lá em cima gingando entre `+IdleSwing` e
		`-IdleSwing` graus, gastando `IdleSwingTime` em cada travessia. É chamariz: a
		oferta vale poucas waves e o botão mora na beirada da tela, onde é fácil não
		ver que ele chegou.

		O clique desliga o balanço e devolve o botão ao que está autorado no Studio em
		`IdleReturn` segundos. O alvo da volta é lido do `CardShop` no bind, e não
		escrito aqui: girar ou mover o botão no Studio não deixa ele torto depois da
		primeira loja.
	]]
	IdleSwing = 10,
	IdleSwingTime = 0.9,
	IdleLift = 6,
	IdleLiftTime = 0.35,
	IdleReturn = 0.2,
	IdleEasing = Enum.EasingStyle.Sine,

	-- O escurecido de tela cheia. O alvo é a transparência autorada do
	-- `Background`, e não um valor escrito aqui.
	BackgroundFade = 0.3,

	--[[
		A carta cai de cima: `DropOffset` é medido em alturas da própria carta,
		então mexer no tamanho dela no Studio não deixa a queda curta demais.

		São duas metades, nesta ordem: primeiro a carta desce e a **imagem** dela
		aparece (`CardDrop`); só quando isso termina é que o conteúdo — título,
		descrição, preço, contornos, sombra — sobe de transparente até o valor
		autorado (`CardReveal`). Revelar tudo junto faria o texto aparecer boiando
		antes da carta existir por trás dele.
	]]
	DropOffset = 1.25,
	CardDrop = 0.4,
	CardReveal = 0.3,

	--- O intervalo entre o começo de uma carta e o da seguinte.
	CardStagger = 0.5,

	--[[
		A saída sem compra: o clique fora das cartas toca a entrada ao contrário — o
		conteúdo some primeiro (`CardReveal`) e só então a carta sobe de volta com a
		imagem apagando (`CardDrop`).

		O escalonamento da saída é bem mais curto que o `CardStagger` da entrada
		porque aqui não há nada para ler: o jogador já decidiu que não quer nenhuma
		das três, e a oferta continua de pé no botão da beirada.
	]]
	CardExitStagger = 0.08,
	BackgroundFadeOut = 0.25,

	CardEasing = Enum.EasingStyle.Quad,
	CardDirection = Enum.EasingDirection.Out,
}

--[[
	O tamanho que o wrapper assume ao entrar na hotbar.

	É a única coisa que a carta de round precisa acertar na mão para conviver com
	as de unidade: o molde dela vem da loja, onde a carta é grande, e a vaga na
	hotbar é bem menor. Daí para a frente quem cuida dela é o `Components/Card` —
	posição, arco, escala e ordem da fila saem todas de lá, iguais às outras.
]]
RoundCardConfig.DeckCardSize = UDim2.fromScale(0.128, 1.07)

--[[ AS CARTAS ]]

--[[
	O catálogo.

	Cada entrada é uma carta que pode sair no sorteio:

	| Campo | O que é |
	| --- | --- |
	| `Id` | a chave, e é ela que trafega na rede — o resto é texto de tela |
	| `Title` / `Description` | o que o jogador lê na carta |
	| `Price` | quanto sai do caixa da partida (`roundcash`) |
	| `Weight` | o peso no sorteio; sem ele, 1 |
	| `Use` | o que a carta pede antes de agir (ver `RoundCardConfig.Use`); sem ele, `Instant` |
	| `Effect` | o nome do efeito no `CardShopService.Effects` |
	| `Params` | os números que o efeito lê |
	| `Image` | a arte da carta; sem ela, fica a autorada no `CardTemplate` |
	| `Ring` | o anel que fica no chão nas cartas de área (ver `RoundCardConfig.Rings`) |
	| `Visual` | o que o **personagem** faz ao usar a carta; sem ele, nada acontece |

	O `Visual` é uma animação e o que ela dispara:

	| Campo | O que é |
	| --- | --- |
	| `Animation` | o `AnimationId` que toca no personagem de quem usou |
	| `Marker` | o nome do marcador de keyframe que a animação carrega |
	| `Sound` | o `Sound` em `SoundService` que o marcador `"Sound"` toca |
	| `VFX` | o asset em `Assets.VFX` que o marcador `"VFX"` estoura |
	| `EffectDelay` | em que segundo da animação o **efeito** entra (o instante do marcador `"VFX"`) |
	| `SoundDelay` | em que segundo da animação o **som** entra (o instante do marcador `"Sound"`) |

	**Quem manda no tempo é a animação, e não um `task.delay`.** O mesmo marcador
	dispara as duas coisas, e o que separa uma da outra é o **parâmetro** dele:
	`"Sound"` toca o som, `"VFX"` estoura as partículas. Reanimar a carta no Moon
	Animator remarca os dois sem passar por aqui — e é para isso que o marcador é um
	só com dois parâmetros, em vez de dois marcadores com nomes diferentes.

	`EffectDelay` e `SoundDelay` são as exceções, e são exceções necessárias: **eles
	valem para quem não está tocando a animação**. O marcador só chega em quem
	carregou a track — o servidor não escuta marcador nenhum, e o cliente que está
	*assistindo* o gesto de outro jogador também não. Os dois números são cópias dos
	instantes dos marcadores `"VFX"` e `"Sound"`, e é assim que o congelamento cai
	junto com o estouro (no servidor) e que as partículas e o som saem no mesmo quadro
	nas telas de todo mundo, em vez de saírem no clique.

	Cópia envelhece, então o `CardShopService` confere os dois contra a animação de
	verdade quando sobe e avisa se eles se afastarem — na tela de quem usou a carta
	quem manda continua sendo o marcador, e um desvio aqui apareceria como o som da
	sala saindo fora do gesto do dono.

	Carta nova é uma entrada aqui **mais** uma função no `CardShopService.Effects`
	com o nome que estiver em `Effect`. O sorteio só oferece o que tem efeito do
	outro lado: entrada com `Effect` que não existe é descartada com aviso, em vez
	de virar uma carta que o jogador paga e não faz nada.

	## A maioria das cartas usa o mesmo efeito

	Quase tudo que uma carta de round faz é **deixar uma regra valendo no campo**, e
	essa regra tem uma gramática própria: o `CardModifier`. Por isso a maior parte
	do catálogo tem `Effect = "Modifier"` e descreve em `Params.Modifiers` os
	registros que ela cria — quem os guarda, poda e replica é o
	`CardModifierService`.

	Dentro de `Params`:

	| Campo | O que é |
	| --- | --- |
	| `Modifiers` | a lista de registros do `CardModifier` que a carta cria |
	| `Duration` | por quantos segundos de partida eles valem; sem isso, até o fim do round |
	| `Radius` | o raio do anel, nas cartas de área -- e o alcance do efeito dentro dele |

	Dois campos dos registros são preenchidos **no uso**, e não aqui, porque eles
	dependem do alvo que o jogador escolheu:

	- `Zone = true` vira `{ Position = <onde ele clicou>, Radius = Params.Radius }`;
	- `Target = true` vira `UnitId = <a torre que ele escolheu>`.

	**Carta sem `Duration` dura o round inteiro.** Não é esquecimento: um buff de
	campo comprado com o caixa da partida é uma decisão de build, e um prazo curto
	transformaria toda carta de regra numa versão pior do Bloxy Cola. O prazo existe
	onde ele é a graça da carta — as bebidas, que dobram um número por dez segundos.
]]
RoundCardConfig.Cards = {
	--[[ ============================ AS ORIGINAIS ============================ ]]

	{
		Id = "TimeStop",
		Title = "TIME STOP",
		Description = "Freezes every enemy for 4 seconds",
		Price = 350,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Effect = "TimeStop",
		Params = { Duration = 4 },
		Visual = {
			Animation = "rbxassetid://76323247675563",
			Marker = "TimeStop",
			Sound = "TimeStopSFX",
			VFX = "PlayerStopTime",

			-- Os marcadores estão em 0,917s (`VFX`) e 0,75s (`Sound`) da animação,
			-- que dura 1,317s.
			EffectDelay = 0.917,
			SoundDelay = 0.75,
		},
	},

	{
		Id = "TimeAcceleration",
		Title = "TIME ACCELERATION",
		Description = "Game speed goes to 3x for 15 seconds",
		Price = 250,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://80964149470422",
		Effect = "TimeAcceleration",
		Params = { Scale = 3, Duration = 15 },
	},

	--[[
		Um guarda-chuva para a wave que está no ar, e não o cancelamento do clima.

		Um clima dura várias waves (`RoundConfig.Duration`), e a carta apaga só a de
		agora: comprada na primeira wave de uma nevasca de três, a nevasca volta na
		segunda. Quem quiser as três limpas compra três cartas -- e é isso que separa
		esta carta de 300 de uma que desligasse o clima inteiro, que valeria muito
		mais.

		Comprada na última wave do clima, ele acaba ali e não volta; e com o céu já
		limpo ela não faz nada, porque não há wave de clima para pular.

		Sem `Params`: a única wave que ela conhece é a atual.
	]]
	{
		Id = "WeatherReport",
		Title = "WEATHER REPORT",
		Description = "Clears the weather for the current wave only",
		Price = 300,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://78191968209780",
		Effect = "WeatherReport",
	},

	--[[ ============================= INSTANTÂNEAS ============================= ]]

	--[[
		Caixa na mão. É a única carta que paga mais do que custa, e o preço é o freio:
		400 por 500 são 100 de lucro por uma vaga de oferta e um uso de hotbar. Mexer
		nos dois números juntos é o que mantém a carta uma escolha em vez de um imposto
		para quem não a compra.
	]]
	{
		Id = "MoneyBag",
		Title = "MONEY BAG",
		Description = "Gives you 500 cash",
		Price = 400,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://131268059067009",
		Effect = "GrantCash",
		Params = { Amount = 500 },
	},

	--[[
		O buque para a sala inteira: 15% de cadencia em toda unidade, por 30 segundos
		de partida.

		O prazo e o que a poe na familia das bebidas, e nao na dos cajados: ela e uma
		janela para empurrar uma wave dificil, e nao uma decisao de build. E, como toda
		carta com `Duration`, ela sai do sorteio depois de usada e so volta na abertura
		seguinte da loja (ver `CardShopService:_isTemporary`).
	]]
	{
		Id = "Trumpet",
		Title = "TRUMPET",
		Description = "Every unit attacks 15% faster for 30 seconds",
		Price = 400,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://74040128583244",
		Effect = "Modifier",
		Params = {
			Duration = 30,
			Modifiers = {
				{ Stats = { AttackSpeed = 1.15 } },
			},
		},
	},

	--[[
		O trato do Overcharge: 25% a mais para Electric, 11% a menos para todo o
		resto. Os dois lados são registros separados porque o `Exclude` é o que faz o
		segundo pegar exatamente quem o primeiro não pegou — inclusive uma unidade
		sem classe nenhuma, que leva o corte junto.
	]]
	{
		Id = "Overcharge",
		Title = "OVERCHARGE",
		Description = "Electric units deal +25% damage, every other unit deals -11%",
		Price = 350,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://120364507379076",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Electric" }, Stats = { Damage = 1.25 } },
				{ Classes = { "Electric" }, Exclude = true, Stats = { Damage = 0.89 } },
			},
		},
	},

	--[[
		`Cooldown +1.15x` no pedido original é cadência, e não recarga: o card promete
		três buffs juntos, e aumentar a recarga em 15% seria um nerf escondido no meio
		de dois buffs. `AttackSpeed = 1.15` é o que o jogador lê como "recarrega mais
		rápido" no ícone do card — ver o comentário do `Feedback` no `WeatherConfig`.
	]]
	{
		Id = "WattsUp",
		Title = "WATT'S UP?",
		Description = "Electric units get +15% damage, range and attack speed",
		Price = 400,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://101249133973372",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Electric" }, Stats = { Damage = 1.15, Range = 1.15, AttackSpeed = 1.15 } },
			},
		},
	},

	{
		Id = "PunchLine",
		Title = "PUNCH LINE",
		Description = "Melee units deal +25% damage, but attack 25% slower",
		Price = 300,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://125434264829869",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Melee" }, Stats = { Damage = 1.25, AttackSpeed = 0.75 } },
			},
		},
	},

	{
		Id = "Axecellent",
		Title = "AXECELLENT!",
		Description = "Melee units attack 15% faster, ranged units 15% slower",
		Price = 300,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://132735756087334",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Melee" }, Stats = { AttackSpeed = 1.15 } },
				{ Classes = { "Ranged" }, Stats = { AttackSpeed = 0.85 } },
			},
		},
	},

	--[[
		O corpo a corpo passa a acertar quem vem atrás do alvo. É `Flags`, e não um
		multiplicador: não existe "cortar 30% do de trás" — ou o golpe alcança a
		fileira ou não alcança. Quem lê é o `UnitService:executeAttack`, e o número de
		corpos por golpe está no `Params`.
	]]
	{
		Id = "CleaveItToMe",
		Title = "CLEAVE IT TO ME!",
		Description = "Melee units also hit the enemy behind their target",
		Price = 400,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://134174928139643",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				--[[
					Os números do corte moram no próprio `Flags`, e não numa constante do
					`UnitService`: quem escolhe quantos corpos um corte pega é a carta, e uma
					segunda carta de corte com números próprios não devia ter que mexer no
					combate para existir.

					Dois corpos por golpe, e o segundo leva 30% a menos. A queda existe pelo
					mesmo motivo da flecha do Archer (ver `UnitStats`): acertar dois de graça
					faria o corpo a corpo dobrar de DPS em qualquer mapa que enfileire.

					`Width` é a folga da linha que sai da unidade e passa pelo alvo — a mesma
					ideia do `PierceWidth`, um pouco mais larga porque um golpe de corpo a
					corpo é um arco, e não uma flecha.
				]]
				{ Classes = { "Melee" }, Flags = { Cleave = { Targets = 2, Falloff = 0.3, Width = 3 } } },
			},
		},
	},

	--[[
		Magia que cresce com magia: +0,1% de dano por unidade Magic no mapa. Com dez
		Magic em campo são 1%, com cinquenta são 5% — o `Scaling` é recontado a cada
		quadro de combate, então vender uma torre encolhe o bônus na hora.
	]]
	{
		Id = "Abrakadabra",
		Title = "ABRAKADABRA",
		Description = "Magic units deal +0.1% damage for every magic unit placed",
		Price = 300,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,

		-- Sem `Image`: esta é a única carta nova que não veio com arte, e sem o campo
		-- ela fica com a autorada no `CardTemplate` em vez de sumir da tela.

		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Magic" }, Scaling = { Stat = "Damage", Class = "Magic", Amount = 0.001 } },
			},
		},
	},

	--[[
		Gelo que trabalha melhor sozinho: a unidade Ice sem nenhuma vizinha a até dez
		studs bate 25% mais rápido. A condição é recontada por quadro, então colocar
		uma torre ao lado tira o bônus na hora — e vendê-la devolve.
	]]
	{
		Id = "Iceolated",
		Title = "ICEOLATED",
		Description = "Ice units get +25% attack speed while no other unit is nearby",
		Price = 250,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://89798319191056",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{
					Classes = { "Ice" },
					Condition = "Isolated",
					ConditionRadius = 10,
					Stats = { AttackSpeed = 1.25 },
				},
			},
		},
	},

	--[[
		O contrário do Iceolated: aqui o gelo é bom para ele e ruim para a vizinhança.
		O segundo registro pega quem **não** é Ice e tem um Ice a até dez studs.
	]]
	{
		Id = "IceToMeetYou",
		Title = "ICE TO MEET YOU",
		Description = "Ice units attack 50% faster; units near them attack 50% slower",
		Price = 350,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://105810324385179",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Classes = { "Ice" }, Stats = { AttackSpeed = 1.5 } },
				{
					Classes = { "Ice" },
					Exclude = true,
					Condition = "NearClass",
					ConditionClass = "Ice",
					ConditionRadius = 10,
					Stats = { AttackSpeed = 0.5 },
				},
			},
		},
	},

	--[[
		A lentidão que as unidades de gelo deixam no inimigo pesa 10% a mais.

		É um modificador **global** (sem classe, sem zona, sem unidade): ele não
		descreve a torre, e sim o estado que ela deixou no inimigo — quem o lê é o
		`MobService:ApplySlow`, pelo `CardModifier.Global`.
	]]
	{
		Id = "ChillOut",
		Title = "CHILL OUT",
		Description = "Ice units slow enemies 10% harder",
		Price = 250,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://76479415282650",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Stats = { Slow = 1.1 } },
			},
		},
	},

	-- O outro lado do Chill Out, do lado do fogo: cada tique de queimadura cobra 20%
	-- a mais. Também global, e pelo mesmo motivo.
	{
		Id = "FireHazard",
		Title = "FIRE HAZARD",
		Description = "Burning enemies take +20% burn damage",
		Price = 250,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://107866423132745",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ Stats = { Burn = 1.2 } },
			},
		},
	},

	--[[
		O último suspiro: enquanto a base estiver abaixo de 20% da vida, todo mundo
		bate 20% a mais.

		> ⚠️ O pedido original era "+20% de HP nas unidades". **Unidade não tem vida
		> neste jogo** — nada nunca ataca uma torre, e não há barra para encher. O que
		> a carta faz é o mesmo contrato pelo lado que existe: um bônus de última hora,
		> que só acende quando a partida está por um fio. No dia em que a torre tiver
		> vida, é trocar `Damage` por `Health` nesta linha e mais nada.
	]]
	{
		Id = "NoPainNoGain",
		Title = "NO PAIN, NO GAIN",
		Description = "While the base is under 20% HP, every unit deals +20% damage",
		Price = 250,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://108872703336271",
		Effect = "Modifier",
		Params = {
			Modifiers = {
				{ BaseHealthBelow = 0.2, Stats = { Damage = 1.2 } },
			},
		},
	},

	--[[
		Gelo em todo mundo de uma vez. Durante a neve ele cobra o dobro: a lentidão
		sobe de 50% para 75% e os inimigos ainda ficam quebradiços, levando 20% a mais
		de dano de qualquer fonte.

		A leitura do clima é do servidor, no instante do uso: comprar a carta esperando
		a neve chegar é a jogada, e por isso o bônus é decidido quando ela é usada e
		não quando é comprada.
	]]
	{
		Id = "AzureEverIce",
		Title = "STAFF OF AZURE EVER ICE",
		Description = "Slows every enemy by 50% for 10s -- 75% and brittle during snow",
		Price = 400,
		Weight = 1,
		Use = RoundCardConfig.Use.Instant,
		Image = "rbxassetid://112747378880473",
		Effect = "ChillEnemies",
		Params = {
			Slow = 0.5,
			Duration = 10,

			-- O que muda quando a carta é usada com este clima no ar.
			Weather = "Snow",
			WeatherSlow = 0.75,
			WeatherBrittle = 1.2,
		},
	},

	--[[ ========================== ALVO: UMA UNIDADE ========================== ]]

	{
		Id = "BloxyCola",
		Title = "BLOXY COLA",
		Description = "Doubles one unit's fire rate for 10 seconds",
		Price = 200,
		Weight = 1,
		Use = RoundCardConfig.Use.Unit,
		Image = "rbxassetid://71582562553170",
		Effect = "Modifier",
		Params = {
			Duration = 10,
			Modifiers = {
				{ Target = true, Stats = { AttackSpeed = 2 } },
			},
		},
	},

	{
		Id = "Bloxiade",
		Title = "BLOXIADE",
		Description = "Doubles one unit's damage for 10 seconds",
		Price = 200,
		Weight = 1,
		Use = RoundCardConfig.Use.Unit,
		Image = "rbxassetid://95661475359990",
		Effect = "Modifier",
		Params = {
			Duration = 10,
			Modifiers = {
				{ Target = true, Stats = { Damage = 2 } },
			},
		},
	},

	--[[ ============================ ALVO: UM LUGAR ============================ ]]

	--[[
		Tira o atordoamento de quem está no círculo e deixa essas unidades imunes por
		dez segundos. É a resposta ao trovão e ao congelamento da neve, que são as
		duas coisas que hoje tiram uma torre da wave inteira.

		A imunidade tem prazo de propósito: sem ele, um cajado bem colocado apagaria a
		mecânica do clima para aquele canto do mapa até o fim do round.
	]]
	{
		Id = "StaffOfHealing",
		Title = "STAFF OF HEALING",
		Description = "Clears stun in an area and grants 10s of stun immunity",
		Price = 300,
		Weight = 1,
		Use = RoundCardConfig.Use.Area,
		Image = "rbxassetid://109636982142517",
		Effect = "Cleanse",
		Ring = "Healing",
		Params = {
			Radius = 6,
			Immunity = 10,

			--[[
				Um modificador que não modifica nada.

				Ele existe para uma coisa só: **ser o círculo no chão**. O efeito desta
				carta não é um multiplicador — é o `CleanseUnits`, que acontece num
				instante —, mas a imunidade que ele deixa dura dez segundos, e o jogador
				precisa ver até onde ela chegou e por quanto tempo. Como zona, o anel
				nasce e morre junto com ela sem nenhum caminho de desenho próprio.

				Sem `Stats` e sem `Flags` de propósito: quem lê os multiplicadores passa
				direto por ele.
			]]
			Modifiers = {
				{ Zone = true },
			},
		},
	},

	--[[
		Os três cajados são a mesma ideia: um anel no chão que troca uma coisa por
		outra para quem estiver dentro dele. O primeiro registro é quem a carta
		favorece, o segundo é o pedágio que todo o resto paga — e é o `Exclude` que
		garante que os dois cubram exatamente o mapa inteiro sem sobreposição.

		O anel **fica**: sem `Duration`, ele vale até o fim do round. Onde o jogador o
		desenha é a decisão inteira da carta.
	]]
	{
		Id = "CelestialStaff",
		Title = "CELESTIAL STAFF",
		Description = "Ring of mana: magic units get 1.2x damage and 1.1x fire rate, everyone else is weakened",
		Price = 500,
		Weight = 1,
		Use = RoundCardConfig.Use.Area,
		Image = "rbxassetid://82581504689393",
		Ring = "Celestial",
		Effect = "Modifier",
		Params = {
			Radius = 7,
			Modifiers = {
				{ Zone = true, Classes = { "Magic" }, Stats = { Damage = 1.2, AttackSpeed = 1.1 } },
				{
					Zone = true,
					Classes = { "Magic" },
					Exclude = true,
					Stats = { Damage = 0.8, AttackSpeed = 0.9, Income = 0.9 },
				},
			},
		},
	},

	{
		Id = "RobuxRoyaltyStaff",
		Title = "STAFF OF ROBUX ROYALTY",
		Description = "Ring of Robux: 1.1x hit income and 1.15x eco income, at 0.8x damage and fire rate",
		Price = 450,
		Weight = 1,
		Use = RoundCardConfig.Use.Area,
		Image = "rbxassetid://118780034086303",
		Ring = "Robux",
		Effect = "Modifier",
		Params = {
			Radius = 7,
			Modifiers = {
				{ Zone = true, Stats = { HitIncome = 1.1, Damage = 0.8, AttackSpeed = 0.8 } },

				-- A renda da fazenda por cima do anterior: quem está no anel e é de
				-- renda leva os dois registros, e eles se multiplicam.
				{ Zone = true, Farm = true, Stats = { Income = 1.15 } },
			},
		},
	},

	--[[
		O anel de vento favorece quem tem o símbolo do arco -- que neste jogo é a
		classe `Ranged`, a mesma que o ícone do card desenha (ver `ClassConfig.Icons`).
	]]
	{
		Id = "WindsStaff",
		Title = "STAFF OF THE WINDS",
		Description = "Windy zone: ranged units get 1.1x damage and 1.2x range, everyone else 0.8x damage",
		Price = 450,
		Weight = 1,
		Use = RoundCardConfig.Use.Area,
		Image = "rbxassetid://109862438058085",
		Ring = "Windy",
		Effect = "Modifier",
		Params = {
			Radius = 7,
			Modifiers = {
				{ Zone = true, Classes = { "Ranged" }, Stats = { Damage = 1.1, Range = 1.2 } },
				{ Zone = true, Classes = { "Ranged" }, Exclude = true, Stats = { Damage = 0.8 } },
			},
		},
	},

	--[[ ====================== ALVO: UMA UNIDADE E UM LUGAR ====================== ]]

	--[[
		A única carta que mexe no tabuleiro em vez de nos números. O destino passa
		pelas mesmas conferências de `PlaceUnit` — fora do caminho, longe das outras
		torres, sem ninguém em cima —, e um destino recusado **não gasta a carta**.

		"As mesmas conferências" é literal: escolhida a torre, o segundo passo chama o
		`UnitPlacementController:visualize`, o mesmo fantasma que larga uma torre
		nova. O jogador escolhe o destino vendo o modelo da própria torre em meio-tom,
		verde onde ela cabe e vermelho onde não, com o anel do alcance dela — e gira
		com o R, como giraria uma torre recém-comprada. O fantasma começa no giro que
		a torre já tem, então mudar só de lugar não custa nenhum passo a mais.
	]]
	{
		Id = "Zippers",
		Title = "ZIPPERS",
		Description = "Move one placed unit to any other valid spot",
		Price = 150,
		Weight = 1,
		Use = RoundCardConfig.Use.Move,
		Image = "rbxassetid://137527028552020",
		Effect = "MoveUnit",

		--[[
			Sem `Params`: esta carta não tem área nem número para ajustar. O `Radius`
			que morava aqui media o anel do segundo passo, e quem marca o destino agora
			é o fantasma da torre — o anel que aparece é o do alcance dela, tirado das
			estatísticas da própria unidade.
		]]
	},
}

--[[ API ]]

local byId = {}
for _, card in RoundCardConfig.Cards do
	byId[card.Id] = card
end

--- A carta do `Id`, ou nil. O `Id` vem pela rede, então pode vir qualquer coisa.
function RoundCardConfig.Get(id : any)
	if typeof(id) ~= "string" then
		return nil
	end

	return byId[id]
end

--[=[
	O tipo de uso de uma carta, sempre um dos de `RoundCardConfig.Use`.

	Carta sem o campo — e carta que nem existe, porque o `Id` veio da rede — é
	`Instant`. É o padrão certo nos dois casos: as três cartas originais são
	instantâneas, e um `Id` desconhecido não pode fazer a tela entrar num modo de
	mira do qual o jogador não teria como sair.
]=]
function RoundCardConfig.GetUse(id : any) : string
	local card = RoundCardConfig.Get(id)
	local use = card and card.Use

	return RoundCardConfig.Use[use] or RoundCardConfig.Use.Instant
end

--- O raio do anel desta carta, para a mira e para a zona que ela deixa.
function RoundCardConfig.GetRadius(id : any) : number
	local card = RoundCardConfig.Get(id)
	local radius = card and card.Params and card.Params.Radius

	return radius or RoundCardConfig.Targeting.DefaultRadius
end

--- De quantas em quantas waves a loja aparece nesta dificuldade.
function RoundCardConfig.GetInterval(difficultyName : string?) : number
	local interval = difficultyName and RoundCardConfig.Intervals[difficultyName]

	return interval or RoundCardConfig.DefaultInterval
end

--[=[
	Se esta wave é uma wave de loja.

	Múltiplo exato do intervalo. A wave 0 fica de fora de propósito: ela não é uma
	wave, é o intervalo antes da primeira.
]=]
function RoundCardConfig.IsShopWave(waveNumber : number?, difficultyName : string?) : boolean
	if typeof(waveNumber) ~= "number" or waveNumber < 1 then
		return false
	end

	return waveNumber % RoundCardConfig.GetInterval(difficultyName) == 0
end

--[=[
	Sorteia `count` cartas **sem repetir**, com peso.

	`pool` é a lista de cartas candidatas (o service passa só as que têm efeito
	registrado, e no lobby só as que a loja pode vender). O sorteio é sem reposição:
	a carta que sai é tirada da urna e os pesos das outras continuam valendo entre
	si, então uma carta rara não fica mais provável só porque a comum já saiu.

	Pool menor que `count` devolve a pool inteira embaralhada — três vagas com
	duas cartas no catálogo é melhor mostrar duas do que repetir uma.

	`rng` é um `Random` próprio, e é o que torna um sorteio **reproduzível**: a
	vitrine da loja de cartas do lobby é a mesma para todo mundo durante quatro
	horas, e ela é recalculada do zero em cada servidor a partir da hora (ver
	`RoundCardShopConfig.stockFor`). Sem semente própria isso dependeria do
	`math.random` global, que cada servidor gasta de um jeito diferente — dois
	lobbies abertos ao mesmo tempo venderiam cartas diferentes, e um restart no meio
	do bloco trocaria a vitrine antes da hora.

	Sem `rng`, o sorteio é o de sempre (`math.random`): é o da oferta de round, que
	é por jogador e por wave e não pode ser previsível.
]=]
function RoundCardConfig.Draw(count : number, pool : { any }?, rng : Random?) : { any }
	local candidates = {}
	for _, card in (pool or RoundCardConfig.Cards) do
		table.insert(candidates, card)
	end

	local drawn = {}

	for _ = 1, math.min(count, #candidates) do
		local total = 0
		for _, card in candidates do
			total += math.max(0, card.Weight or 1)
		end

		if total <= 0 then
			break
		end

		local roll = (rng and rng:NextNumber() or math.random()) * total
		local cursor = 0

		for index, card in candidates do
			cursor += math.max(0, card.Weight or 1)

			if roll <= cursor then
				table.insert(drawn, card)
				table.remove(candidates, index)
				break
			end
		end
	end

	return drawn
end

return RoundCardConfig
