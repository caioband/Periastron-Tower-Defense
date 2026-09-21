--[[
	Climas.

	Um clima é um Model em `ReplicatedStorage.Shared.Assets.Weathers`:

		Assets.Weathers
		├── Snow                  (Model, tag "AreaWeather")
		│   ├── Part              (Part com os ParticleEmitters)
		│   └── Lighting          (Folder — preset do LightingService)
		└── Rain                  (Model, tags "AreaWeather" + "SkyWeather")
			├── Part              (tag "SkyWeather"  — a camada de nuvem)
			├── Part              (tag "AreaWeather" — a chuva na área jogável)
			└── Lighting          (Folder)

	A **tag** diz como cada Part é encaixada no mapa. Um clima pode ter os dois
	tipos ao mesmo tempo: aí o Model leva as duas tags e **cada Part diz a sua**.
	Clima de um tipo só não precisa marcar nada nas Parts — a tag do Model vale para
	todas elas, que é como os climas antigos continuam funcionando.

	A pasta `Lighting` é um preset no mesmo formato de `Assets.Lighting` (atributos
	= propriedades do Lighting, filhos = instâncias). O `WeatherService` registra
	essa pasta como preset e aplica pelo `LightingService`, então a troca de clima
	entra na mesma transição interpolada de qualquer outra troca de iluminação.

	Fica em `common/` porque as duas places montam o Weathers.
]]

local WeatherConfig = {}

-- Onde os climas moram, a partir de `ReplicatedStorage`.
WeatherConfig.AssetsPath = { "Shared", "Assets", "Weathers" }

--[[
	Como cada Part do clima é encaixada no mapa:

	- `Area`: vira a caixa do mapa. Neblina, neve — coisa que acontece *dentro* da
	  área jogável.
	- `Sky`: fica X e Z do tamanho do mapa e sobe para um offset acima do pico. A
	  altura (Y da Part) é a autorada, porque é a espessura da camada, não a
	  extensão dela.

	As duas valem tanto no **Model** quanto em cada **Part**, e a da Part manda:

	- Model com uma tag só e Parts sem tag: todas as Parts são daquele tipo. É como
	  os climas de um tipo só são autorados, e como todos eram antes de existir
	  clima misto.
	- Model com as duas tags: cada Part precisa dizer a sua, senão não há como
	  adivinhar em qual das duas caixas ela entra — a Part sem tag é recusada com
	  aviso, e o resto do clima entra normalmente.

	Model sem nenhuma das duas tags é recusado inteiro — é mais fácil de achar do
	que um clima que entra e não encaixa em nada.

	As Parts não precisam ter nomes diferentes: o `Rain` tem duas chamadas `Part`, e
	quem as separa é a tag, não o nome.
]]
WeatherConfig.Tags = {
	Area = "AreaWeather",
	Sky = "SkyWeather",
}

-- Quanto o clima de céu sobe acima do pico do mapa. Um Model pode trazer o
-- atributo `HeightOffset` para mandar no seu próprio valor.
WeatherConfig.SkyHeightOffset = 20
WeatherConfig.HeightOffsetAttribute = "HeightOffset"

--[[
	Part que o mapa traz dizendo onde ele fica.

	Quando existe, ela manda — nos dois tipos de clima. É exata e não depende de
	heurística nenhuma: o `Volcano` calculado dá 500x500 porque a água de fundo mora
	dentro do `Terrain` dele, e a caixa autorada tem 147x109.

	Só `Position` e `Size` são lidos; rotação é ignorada de propósito.

	O `BoundsFolders` e o `MaxPartFootprint` abaixo são o plano B, para mapa que
	ainda não tenha a caixa.
]]
WeatherConfig.BoundsPartName = "BoundingBox"

--[[
	Quais subpastas do mapa contam para a caixa.

	Não é o mapa inteiro de propósito. `Locked` guarda o cenário de fundo — um chão
	de 2047 studs no Farm, uma água de 2033x2048 no Mountain — e medir isso junto
	daria uma caixa 10x a área jogável, espalhando as partículas até sumirem. O
	`Terrain` do Farm tem 93x103, e a Part autorada do Snow tem 100x100: é essa a
	escala que os climas foram feitos para cobrir.

	Mapa que não tenha nenhuma destas pastas cai para a caixa do mapa inteiro.

	Vale só para `AreaWeather`. O `SkyWeather` mede o mapa inteiro de propósito:
	a camada de céu cobre tudo que se vê, o chão de fundo incluído.
]]
WeatherConfig.BoundsFolders = { "Terrain", "Path" }

--[[
	Part maior que isto em X ou Z não conta para a caixa.

	As pastas acima não bastam: o `Snowy` tem duas parts `Ice` de 2048x0x2048 dentro
	do próprio `Terrain`, e o `Volcano` guarda a água de 2048x0x2048 lá também (ele
	nem tem `Locked`). São planos de fundo — chão pintado até o horizonte, não área
	jogável — e uma sozinha estica a caixa para 20x o resto do mapa.

	512 separa as duas populações com folga: a maior geometria jogável dos mapas de
	hoje tem ~150 studs, e o menor plano de fundo tem 2048. Sobrando nada depois do
	corte, a caixa é medida de novo sem ele — um mapa pequeno feito de uma part só
	continua funcionando.

	Como o `BoundsFolders`, vale só para `AreaWeather`.
]]
WeatherConfig.MaxPartFootprint = 512

-- Model do mapa carregado, dentro do Workspace.
WeatherConfig.TargetName = "Map"

-- Onde o clone do clima em uso fica pendurado no Workspace.
WeatherConfig.ContainerName = "Weather"

-- Prefixo do preset que o clima registra em `Assets.Lighting`, pelo mesmo motivo
-- do `MapPrefix`: o nome de um clima não pode esbarrar num preset autorado.
WeatherConfig.PresetPrefix = "Weather_"

--[[
	Mecânica do clima de trovão: de tempos em tempos um raio cai em cima de uma
	unidade posicionada.

	Quem sorteia o alvo e dá o compasso é o `ThunderService` (servidor), para todo
	mundo ver o mesmo raio na mesma unidade. Quem desenha é o `VFXController`, no
	cliente — o módulo `ReplicatedStorage.vfx` só roda lá.
]]
--[[
	Som de fundo por clima, tocado em loop pelo `WeatherController` enquanto ele
	estiver ligado. `Sound` é o nome dentro de `SharedSounds.SFX` (a busca é
	recursiva, então a subpasta não entra no nome).

	Clima que não estiver aqui simplesmente entra sem ambiente.
]]
WeatherConfig.Ambience = {
	Thunder = { Sound = "Thunderstorm", Fade = 2 },
}

-- Key do `PlaySFX` do ambiente: uma só, para um clima derrubar o do anterior.
WeatherConfig.AmbienceKey = "WeatherAmbience"

WeatherConfig.Thunder = {
	-- Nome do Model em `Assets.Weathers` que liga a mecânica.
	Weather = "Thunder",

	-- VFX em `Assets.VFX`: um Attachment (começo do raio) com um Attachment filho
	-- de letra única (o fim). É assim que o addon `LightningBeams` reconhece um raio.
	Asset = "LightningBeam",

	-- Intervalo entre raios.
	Interval = 5,

	--[[
		Chance de o raio escolher uma unidade em vez de um ponto qualquer da caixa.

		É um sistema de pity: cada raio que cai no chão soma `UnitChanceStep`, e o
		primeiro que acerta uma unidade devolve a chance para `UnitChance`. Com os
		valores de hoje a chance sobe 0.15 → 0.30 → … → 1.00, então o sétimo raio é
		garantido. Simulado em 20 mil sequências: média de 2,9 raios até acertar
		(~15s no intervalo de 5s) e pior caso 7 (~35s).

		A chance não sobe quando não há unidade nenhuma no mapa: o pity conta raio que
		*poderia* ter acertado e não acertou, não raio que não tinha alvo.
	]]
	UnitChance = 0.15,
	UnitChanceStep = 0.15,
	MaxUnitChance = 1,

	--[[
		De onde o raio sai, quando não dá para usar a camada de nuvem.

		O normal é a origem ser a própria Part do clima em `workspace.Weather` — o
		raio descendo de onde está a nuvem. Sem ela, cai para esta altura acima do pé
		da unidade.
	]]
	StrikeHeight = 90,

	-- Margem depois do `Duration` do asset antes de destruir o clone.
	Cleanup = 3,

	--[[
		Estouro do raio: um clone de `SharedSounds.SFX.Thunders.Thunder` por queda,
		com fade no fim para a cauda não cortar seca. Sem `Key`, de propósito — dois
		raios seguidos podem se sobrepor.

		O Sound nasce dentro do Attachment da ponta do raio, então é 3D e sai do ponto
		de impacto. `StrikeVolume` existe por causa disso: o asset tem
		`RollOffMinDistance = 10`, e com a câmera de tower defense longe do chão a
		atenuação come boa parte do volume. É o multiplicador para compensar sem
		mexer no asset.
	]]
	StrikeSound = "Thunder",
	StrikeFadeOut = 1,
	StrikeVolume = 1,

	--[[
		O atordoamento que o raio deixa.

		`Direct` e de quem o raio pegou em cheio; `Chain` e de quem levou o arco que
		saltou dele. A diferenca e grande de proposito — 20s tira a unidade da wave
		inteira, e sem um valor bem menor no salto um raio bem colocado apagaria meio
		mapa de uma vez.

		`Radius` e o alcance do salto, medido do pe da unidade atingida. `Hops` e
		quantas vezes o arco pode saltar: 1 significa que so quem esta perto do alvo
		original pega, e ninguem propaga de novo. `MaxTargets` fecha o teto por salto.

		Unidade imune ao clima (ver `Effects.Thunder.Immune`) nao e atordoada nem
		serve de ponte para o arco.
	]]
	Stun = {
		Direct = 20,
		Chain = 5,
		Radius = 12,
		Hops = 1,
		MaxTargets = 4,
	},

	--[[
		O premio de levar um raio, para quem e do tipo `Electric` -- no lugar do
		atordoamento: Electric tocada pelo raio (ou pelo arco) nunca para.

		`Damage` multiplica o dano e `AttackSpeed` a cadencia: 1.5 nos dois e o "+50%
		DMG / +50% SPD (WHEN STRUCK)" que o painel do indicador mostra. Quem divide o
		cooldown pela cadencia e o `UnitUpgradeConfig:GetCooldown`, entao 1.5 aqui e um
		terco de recarga a menos, e nao metade.

		Fora isso o Electric ja ganha um bonus passivo enquanto o clima durar, que
		mora em `Effects.Thunder.Units.Electric` — este aqui e o temporario, que so
		entra quando o raio (ou o arco) encosta na unidade.
	]]
	Charge = {
		Damage = 1.5,
		AttackSpeed = 1.5,
		Duration = 4,
	},
}

--[[ ============================ CLIMA DE PARTIDA ============================ ]]

--[[
	Quais climas cada mapa pode sortear.

	A chave é o nome do mapa em `MapConfig.MAPS` — que é o mesmo nome da pasta em
	`ServerStorage.Maps` — e o valor é a lista de Models de `Assets.Weathers` que
	fazem sentido ali. Neve no deserto e tempestade de areia na caverna não entram
	não por regra de código, mas porque não estão nesta lista.

	Mapa fora daqui (ou com a lista vazia) simplesmente não tem clima: o sorteio de
	cada wave nem chega a rodar. É o comportamento certo para um mapa novo que
	ainda não foi ambientado.
]]
WeatherConfig.MapPools = {
	Farm = { "Fog", "Wind", "Thunder", "Rain" },
	Desert = { "Sandstorm", "Drought" },
	Volcano = { "Drought", "Fog" },
	Cave = { "Fog" },
	SnowyCastle = { "Snow", "Wind", "Fog", "Rain" },
	Mountain = { "Snow", "Wind", "Fog", "Thunder", "Drought", "Rain" },
	Snowy = { "Snow", "Wind", "Fog" },
	Swamp = { "Fog", "Rain" },
	Beach = { "Wind", "Rain", "Thunder", "Drought" },
	["Pale Garden"] = { "Fog", "Rain", "Sandstorm", "Snow", "Thunder", "Wind" },
}

--[[
	O ritmo do clima dentro da partida.

	A cada wave que começa o `WeatherRoundService` joga um dado. Passando, ele não
	liga o clima na hora: ele **avisa**, e o clima entra `LeadWaves` waves depois.
	As três waves de antecedência são o ponto todo do sistema — o jogador vê o
	aviso, sabe o que vem e tem tempo de trocar o posicionamento antes.

	`Duration` é por quantas waves o clima fica no ar depois de entrar. Sai sozinho
	no começo da wave seguinte à última — com 4, um clima que entra na wave 10 vale
	da 10 à 13 e some na 14.

	`Chance` é só o piso: quem manda é o `WeatherChance` do preset de dificuldade
	(`ServerScriptService.Config.Difficulty`), que sobe do Fácil para o Nightmare.
	Este valor cobre preset sem o campo.

	Enquanto houver clima agendado ou no ar, o dado não é jogado de novo — dois
	climas ao mesmo tempo não existem, e um aviso por cima de outro só confundiria.
]]
WeatherConfig.Round = {
	LeadWaves = 3,
	Duration = 4,
	Chance = 0.15,
	TransitionTime = 3,
}

--[[
	A frase do aviso de clima.

	`Text` leva o nome do clima e quantas waves faltam; `TextOne` existe só para
	não escrever "1 ROUNDS". `DisplayNames` é para quando o nome do Model não for o
	nome que o jogador deve ler.

	O label em si e a animação não estão aqui: são do `WarningConfig`, que o clima
	divide com os outros avisos de tela (hoje, o restart do servidor).
]]
WeatherConfig.Warning = {
	Text = "WARNING! %s COMING IN %d ROUNDS",
	TextOne = "WARNING! %s COMING NEXT ROUND",

	--[[
		O `Snow` do código é a "BLIZZARD" do jogo, e é este o nome que o jogador lê no
		aviso e no painel do indicador. O nome do Model não muda: renomeá-lo levaria
		junto o pool de cada mapa, o comando `weather` e as tabelas de efeito, para o
		jogador ler a mesma palavra que já lia.
	]]
	DisplayNames = {
		Snow = "BLIZZARD",
	},
}

--[=[
	O indicador de clima do HUD: o botão no canto e o painel que ele abre.

	São duas peças **irmãs** na `Interface`, e não uma dentro da outra:

		Interface
		├── WeatherButton        (ImageButton — o ícone do clima, e o interruptor)
		│   └── New              (opcional — o selo de "abre isto aqui")
		└── IndicatorWeather     (o painel, com um UIScale)
			├── WeatherImg       (ImageLabel — o mesmo ícone do botão)
			├── WeatherName      (TextLabel  — o nome do clima)
			├── Duration         (TextLabel  — "WEATHER ENDS IN 3 WAVES")
			└── Container        (UIListLayout — uma linha por efeito)

	O botão é um **interruptor**: aperta e o painel entra crescendo o `UIScale`,
	aperta de novo e ele sai encolhendo. Nenhum tempo de leitura é contado por nós —
	quem fecha é o jogador, quando terminou de ler.

	**Sem clima no ar não há indicador**: o botão some e o painel fecha, mesmo aberto.
	"Céu limpo" não é informação que valha um canto da tela ocupado — o indicador
	existe para as waves em que há o que ler nele.

	**O selo de novidade.** Quem nunca abriu o painel nesta partida não sabe que o
	botão abre coisa alguma, então o `New` — a filha opcional do botão — acende junto
	com ele e **insiste**: aparece em toda tempestade enquanto o painel não for aberto
	uma vez. Aberto, ele se aposenta pelo resto da partida; a partida seguinte começa
	sem essa memória, e o selo volta no primeiro clima dela.

	As linhas do `Container` são escritas pelo `RichTextController`, uma depois da
	outra (ver `Line.Stagger`), e a cor dentro delas é automática: o número entra na
	cor do que ele faz com o jogador, e o tipo de unidade na cor do tipo. Ver `Colors`
	e `Details`.
]=]
WeatherConfig.Indicator = {
	--[[
		Os nomes na árvore, a partir da `PlayerGui`.

		`Line` é o **molde opcional** de uma linha: existindo dentro do `Container`, ele
		é clonado uma vez por efeito e nunca aparece ele mesmo, e é dele que saem o
		tamanho e as margens que o designer desenhou. Não existindo, o controller cria
		um Frame de `Line.HeightScale` da altura do `Container`.

		A tipografia **não** sai do molde em nenhum dos dois casos: ela é do `Text`
		aqui embaixo, porque quem desenha as letras é o renderizador de texto rico, e
		não o TextLabel.
	]]
	Gui = {
		Screen = "Interface",
		Frame = "IndicatorWeather",
		Button = "WeatherButton",

		--[[
			O selo de novidade **dentro** do botão, e é opcional: não existindo, o
			indicador funciona igual e ninguém avisa nada. Quem o acende e o apaga é o
			`WeatherIndicatorController:refreshButton`.
		]]
		New = "New",
		Image = "WeatherImg",
		Name = "WeatherName",
		Duration = "Duration",
		Container = "Container",
		Line = "Line",
	},

	--[[
		O ícone de cada clima, no botão e no painel.

		A chave é o nome do clima como o resto do jogo o escreve (o Model em
		`Assets.Weathers`, o `WeatherConfig.Effects`), e não o nome comercial: o
		"blizzard" do desenho é o `Snow` do código — ver `Warning.DisplayNames`.

		Não há ícone de "sem clima" aqui de propósito: sem clima, o botão some.
	]]
	Icons = {
		Rain = "rbxassetid://137668421407555",
		Wind = "rbxassetid://131735996975678",
		Thunder = "rbxassetid://111534699707977",
		Sandstorm = "rbxassetid://112048992160649",
		Snow = "rbxassetid://138661703410675",
		Fog = "rbxassetid://86004956830955",
		Drought = "rbxassetid://128162722232087",
	},

	--[=[
		A entrada e a saída do painel, escritas no `UIScale` dele.

		O `UIScale` é o autorado, quando existe; sem ele o controller cria um. A
		animação é de escala, e não de posição, justamente por isso: ela funciona em
		qualquer canto em que o painel esteja ancorado, sem o controller ter de saber
		de onde ele deveria vir.

		A entrada passa do ponto e volta (`Back`) e a saída não (`Quad`): o mesmo
		exagero na volta faria o painel parecer que quicou para fora em vez de ter
		sido fechado. A saída também é mais curta — fechar é resposta a um clique, e
		clique esperando animação parece travamento.

		`Open` é o **plano B** da escala de repouso: quem manda é a escala autorada no
		`UIScale` do painel, lida antes de a animação escrever nele. Painel desenhado em
		0.8 abre em 0.8, e não estufa para 1 porque o controller achou que 1 fosse o
		tamanho certo. Este valor cobre o `UIScale` que nasce em zero e o que o
		controller cria.

		**A lista de efeitos não é escrita durante a entrada**, e isso é parte do
		contrato desta animação: o texto rico se dimensiona pelo tamanho que a caixa
		tinha no instante em que ele entrou, e caixa medida no meio do crescimento dá
		linha gigante — ou linha nenhuma, medindo zero. Quem trocar esta animação por
		outra tem de manter isso: ver `writeLinesWhenSettled` no controller.
	]=]
	Scale = {
		Open = 1,
		Closed = 0,
		OpenInfo = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		CloseInfo = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
	},

	--[=[
		Quanto o painel cresce com a tela.

		O tamanho do painel é do designer, e o que está desenhado é em pixels: o mesmo
		painel numa tela de 1080 e numa de 1440 ocupa a mesma quantidade de pixels, e por
		isso **parece menor** na maior — ela tem mais pixels para a mesma área de visão. A
		letra, que sai da caixa medida (ver `Line.TextRatio`), encolhe na mesma proporção.

		A correção é um fator na escala de repouso do `UIScale`:

			fator = clamp(alturaDaTela / ReferenceHeight, Min, Max)

		Tudo dentro do painel cresce junto — a arte, o ícone, os labels e a letra das
		linhas, que é medida da caixa depois de o fator já estar aplicado.

		`Min = 1` é o que segura o celular no lugar: tela menor que a referência **não
		encolhe** o painel, porque lá ele já ocupa a fração certa da tela e encolher o
		deixaria ilegível. `Max` existe porque o fator não pode crescer para sempre: numa
		tela de 4K o painel dobraria de tamanho e passaria a competir com o jogo.

		`ReferenceHeight` é a **altura** da tela em que o painel foi desenhado, em pixels —
		1080 para um monitor 1080p, e não 1920, que é a largura dele. É o erro fácil de
		cometer aqui, e ele é silencioso: referência grande demais joga o fator abaixo de 1
		em qualquer tela, o `Min` o prende em 1, e os dois números param de fazer efeito.

		O valor certo é a altura da tela em que o painel **já está do tamanho que você
		quer**. Se o celular está bom e o monitor está pequeno, a referência é a altura do
		celular — é daí para cima que o painel cresce. O print do Studio (ver
		`indicatorPrint` no controller) mostra a altura de cada tela e o fator que saiu
		dela, que é o jeito de descobrir os dois números em vez de tentar.

		O **botão** não entra nesta conta de propósito: o `UIScale` dele é onde o
		`AnimatedButton` do `UILibraryController` escreve o hover e o aperto, e dois donos
		na mesma propriedade dariam um botão que volta do hover no tamanho errado. Botão
		que precise crescer com a tela cresce pelo `Size` dele, no Studio.
	]=]
	Responsive = {
		ReferenceHeight = 720,

		--[[
			**Hoje desligado** (`Min` e `Max` iguais a 1): o painel está do tamanho certo em
			todas as telas, e o que estava pequeno era a letra dentro dele — que tem a conta
			dela em `Line`. Isto aqui fica como o botão para o dia em que for o painel que
			estiver errado: `Max = 1.5` o deixa crescer até uma vez e meia acima da
			referência.
		]]
		Min = 1,
		Max = 1,
	},

	--[=[
		As linhas do `Container`.

		`Height` é a altura de uma linha em pixels, e vale só para o Frame que o
		controller cria quando não há molde no Studio — com molde, a altura é a dele. O
		espaço entre uma e outra é do `UIListLayout`, que é do designer nos dois casos.

		`Stagger` é o atraso entre o começo de uma linha e o da seguinte. É curto de
		propósito: a lista inteira tem de estar escrita em menos de um segundo, senão
		quem abriu o painel para conferir um número fica esperando a animação em vez de
		lendo.
	]=]
	Line = {
		Stagger = 0.06,

		--[=[
			A altura de uma linha como **fração da altura do `Container`**, e não em pixels:
			vale só para o Frame que o controller cria quando não há molde no Studio, e é
			assim porque pixel não é responsivo — 22px num monitor é um quinto do painel, e
			no celular é metade dele.

			0.2 dá cinco linhas enchendo a caixa, que é o maior clima de hoje (Drought e
			Blizzard). Clima de duas linhas ocupa 40% e o resto sobra, que é o certo: a
			altura de uma linha não pode depender de quantas linhas o clima tem, senão a
			letra muda de tamanho de clima para clima.
		]=]
		HeightScale = 0.2,

		--[=[
			Quanto se espera uma peça ter tamanho **estável** na tela antes de escrever
			nela de qualquer jeito.

			Peça criada agora só mede depois da passada de layout, e escrever antes disso
			é o que fazia a primeira linha sair do tamanho errado. Esgotado o prazo, a
			escrita acontece e o renderizador reclama no output — é a pista de que a peça
			tem tamanho zero autorado ou um pai apagado.
		]=]
		MeasureTimeout = 1,

		--[=[
			O tamanho da letra sai da **caixa medida**, e não de um número de pixels: é o
			que faz a lista se parecer a mesma no monitor e no celular, onde o painel tem
			uma fração dos pixels e uma letra de 12px ocuparia o dobro do espaço relativo.

			`TextRatio` é a altura da letra como fração da altura da linha — o que sobra é a
			folga em volta. `MinTextSize` é o piso: abaixo dele não se lê, e é melhor a linha
			estourar a caixa (e alguém ver o problema) que virar uma tarja cinza.

			`MaxRows` é quantas fileiras uma linha pode ocupar. É o que impede a frase longa
			de ficar minúscula: `+50% ELEC UNIT DMG (WHEN STRUCK)` numa caixa estreita cabe
			em uma fileira só com uma letra que não se lê, e em duas fileiras com o dobro da
			largura disponível — o controller experimenta de 1 a `MaxRows` e fica com a que
			der a **letra maior**. Caixa larga e baixa continua escolhendo uma fileira
			sozinha, porque ali a altura é que limita.

			`WidthPerChar` é o **plano B**: a largura da frase é medida de verdade
			(`TextService`), e esta estimativa por caractere só entra quando a medida falha.
			1 é a medida da Press Start 2P, que é quase monoespaçada.

			A conta vale para a lista inteira, e não por linha: a linha mais comprida manda
			no tamanho de todas, porque lista com uma tipografia por linha parece defeito.
		]=]
		TextRatio = 0.9,
		MaxRows = 2,
		MinTextSize = 6,
		WidthPerChar = 1,

		--[[
			Quanto se espera a tela parar de mudar antes de reescrever a lista na medida
			nova (rotação do celular, arraste da janela). Sem esta pausa, um arraste
			recomeçaria a animação de digitação a cada quadro.
		]]
		ResizeDebounce = 0.2,
	},

	--[=[
		Como as linhas são escritas. Vai inteiro para o `RichTextController`, então
		qualquer opção dele cabe aqui.

		**`Size` não está aqui de propósito**: o tamanho da letra é medido da caixa a
		cada escrita (ver `Line.TextRatio`), e um número fixo aqui seria o mesmo pixel no
		monitor e no celular. Quem quiser letra maior ou menor mexe na proporção, não
		aqui.
	]=]
	Text = {
		Font = "rbxasset://fonts/families/PressStart2P.json",
		Speed = 60,
		Anim = "slide",
		AnimDuration = 0.18,
		Align = Enum.HorizontalAlignment.Left,
		VerticalAlign = Enum.VerticalAlignment.Center,
		Stroke = { Thickness = 0.06, Color = Color3.new(0, 0, 0) },
	},

	--[=[
		Os dois labels do topo do painel: o nome do clima e o prazo.

		Eles são texto comum, e a tipografia deles é do designer — este controller só
		escreve a frase. O que ele faz por responsividade é ligar o `TextScaled` deles e
		**travar o teto no tamanho autorado**, com um `UITextSizeConstraint`: no monitor a
		letra fica do tamanho que foi desenhada, e no celular ela encolhe com o label em
		vez de estourar a caixa.

		Label que já venha com `TextScaled` ligado do Studio não é tocado: aí o designer
		já resolveu o tamanho dele, e o `TextSize` autorado não quer dizer mais nada —
		usá-lo de teto cravaria a letra no 14 que ninguém escolheu.

		`Scale = false` devolve os dois ao que o Studio disser, para o dia em que a arte
		quiser mandar sozinha.
	]=]
	Labels = {
		Scale = true,
		MinTextSize = 6,
	},

	--[[
		A linha do `Duration`: quantas waves o clima ainda vale, contando a que está
		rodando. `EndsOne` existe pelo mesmo motivo do `Warning.TextOne` — para não
		escrever "1 WAVES".

		Clima ligado na mão (o comando `weather`) não tem prazo nenhum, e aí o label
		simplesmente não aparece: melhor um painel sem a linha que uma promessa de fim
		que ninguém vai cumprir.
	]]
	Ends = "WEATHER ENDS IN %d WAVES",
	EndsOne = "WEATHER ENDS IN 1 WAVE",

	--[=[
		As cores dentro de uma linha, em `r,g,b` — o formato que o `[color=...]` do
		texto rico entende.

		`Buff` e `Debuff` pintam **o número**, e não a linha: a frase continua na cor do
		label e só o "+40%" muda de cor, que é o que faz a lista ser lida de relance.
		Quem escolhe entre as duas é o sinal do número, com a exceção que mora no `Kind`
		de `Details`.

		`Classes` pinta a palavra do tipo de unidade, para o jogador achar o que é dele
		na lista sem ler a linha inteira. A chave é a palavra como ela aparece escrita —
		`ELEC`, e não `Electric`.
	]=]
	Colors = {
		Buff = "85,170,255",
		Debuff = "255,80,80",

		Classes = {
			FIRE = "255,125,60",
			ICE = "135,220,255",
			ELEC = "255,225,95",
			MAGIC = "200,130,255",
			MELEE = "255,180,95",
			RANGED = "150,230,140",
		},
	},

	--[=[
		O que cada clima faz, uma linha por efeito, na ordem em que o painel as mostra.

		É o resumo do que está em `WeatherConfig.Effects` — quem mexer nos números de lá
		mexe na linha daqui também, porque não há como derivar uma da outra sem virar
		uma tabela de multiplicadores na cara do jogador. E nem tudo o que o clima faz
		está aqui, de propósito: a imunidade do Magic ao raio, por exemplo, não é uma
		linha — o painel é o que o jogador precisa saber para jogar a wave, e não a
		documentação do clima.

		Cada linha é uma string, ou uma tabela `{ Text = ..., Kind = ... }` quando o
		sinal engana. `Kind` é "Buff" ou "Debuff" e manda na cor de todos os números da
		linha: `+40% ENEMY HP` é um "+" péssimo para o jogador, e pintá-lo de azul
		porque o número cresce seria mentir na única coisa que a cor diz. Número sem
		sinal nenhum (`20s UNIT STUN`) é debuff — é o que os stuns de hoje são.
	]=]
	Details = {
		Rain = {
			"DISABLES FIRE UNITS",
			"-35% UNIT SPD",
			"-25% ICE UNIT COST",
		},

		Thunder = {
			"20s UNIT STUN",
			"+10% ELEC UNIT DMG",
			"+50% ELEC UNIT DMG (WHEN STRUCK)",
			"+50% ELEC UNIT SPD (WHEN STRUCK)",
		},

		Drought = {
			{ Text = "+40% ENEMY HP", Kind = "Debuff" },
			"+30% FIRE UNIT DMG",
			"+20% FIRE UNIT SPD",
			"-60% ICE UNIT DMG",
			"-60% ICE UNIT SPD",
		},

		Snow = {
			"-10s UNIT STUN",
			"-40% UNIT SPD",
			"+25% ICE UNIT DMG",
			"+25% ICE UNIT SPD",
			"MAGIC UNITS ARE IMMUNE",
		},

		Sandstorm = {
			"-30% UNIT DMG",
			"-30% UNIT SPD",
			"MAGIC UNITS ARE IMMUNE",
		},

		Wind = {
			{ Text = "+30% ENEMY SPD", Kind = "Debuff" },
			"+30% MELEE SPD",
		},

		Fog = {
			"-30% UNIT RNG",
			"-45% MAGIC RNG",
		},
	},

	-- Clima sem lista escrita ainda: melhor uma linha honesta que um painel vazio.
	UnknownDetails = { "NO DETAILS ON THIS ONE YET" },
}

--[[
	O que o clima mostra em cima da unidade afetada.

	Duas coisas, e as duas saem do mesmo cálculo: um Highlight no modelo (azul claro
	quando o clima está ajudando, vermelho quando está atrapalhando) e uma billboard
	na cabeça com um ícone por estatística mexida.

	A arte é o Attachment `Assets.UI.BuffDebuffBillboard`, e dentro de
	`BillboardGui.Frame` mora um ImageLabel por ícone. O asset tem os seis:
	`BuffDamage`/`DebuffDamage`, `BuffRange`/`DebuffRange` e
	`BuffCooldown`/`DebuffCooldown` — as três estatísticas que aparecem na billboard,
	nos dois sentidos. Os labels vêm todos `Visible = true` do Studio, e quem desenha
	liga o do que a unidade está sentindo e **apaga o resto**; nome pedido aqui que
	não exista lá simplesmente não aparece, com um aviso no Studio.

	`Cost` fica de fora de propósito: ele não é um estado da unidade em campo, é o
	preço de colocar uma nova. Quem o mostra é o próprio número da carta na hotbar,
	que já sai com o desconto.

	`AttackSpeed` aparece como **Cooldown** porque é assim que o jogador lê o número
	no card: cadência maior é recarga menor. Por isso `AttackSpeed > 1` acende o
	ícone de *buff* de cooldown, e não o de debuff.
]]
WeatherConfig.Feedback = {
	-- Attachment em `Assets.UI`, clonado para dentro da cabeça da unidade.
	Asset = "BuffDebuffBillboard",

	-- Onde ele é encaixado. Todas as unidades de hoje são modelos de personagem.
	HeadName = "Head",

	--[[
		Nome do Highlight do clima.

		Ele é procurado pelo nome em vez de guardado numa tabela: assim a unidade
		levar `Destroy` (venda, recomeço de round) já limpa tudo, e não sobra
		bookkeeping para desencontrar do que está no Workspace.

		Nome próprio também o mantém fora do caminho dos outros Highlights que a
		unidade recebe — o verde da seleção, o amarelo do atordoamento e o ciano da
		carga do raio.
	]]
	HighlightName = "WeatherHighlight",

	--[[
		Uma linha por ícone da billboard, na ordem em que eles aparecem. `Buff` é o
		label para multiplicador acima de 1 e `Debuff` o de abaixo.

		**Esta lista não é só do clima.** Ela é o vocabulário da billboard, e quem a
		lê são as duas coisas que mexem numa unidade em campo: o clima e as cartas de
		round (ver `CardModifier` e o `WeatherFeedbackController`, que combina as
		duas). Por isso `Income`/`HitIncome` estão aqui mesmo sem nenhum clima
		mexendo em renda — o multiplicador de um clima para uma estatística que ele
		não declara é 1, e a linha simplesmente não acende.

		`Stats` é uma **lista** porque um ícone pode representar mais de uma
		estatística: o dinheiro da unidade sai de dois números — a renda da farm
		(`Income`) e o que o dano dela paga (`HitIncome`) —, e são um ícone só na
		cabeça dela. Os multiplicadores da linha são multiplicados entre si, então o
		que acende é o efeito líquido no bolso do jogador.
	]]
	Stats = {
		{ Stats = { "Damage" }, Buff = "BuffDamage", Debuff = "DebuffDamage" },
		{ Stats = { "Range" }, Buff = "BuffRange", Debuff = "DebuffRange" },
		{ Stats = { "AttackSpeed" }, Buff = "BuffCooldown", Debuff = "DebuffCooldown" },
		{ Stats = { "Income", "HitIncome" }, Buff = "BuffEco", Debuff = "DebuffEco" },
	},

	--[[
		O ícone da unidade **desligada** (`Disable`).

		É o de debuff de cooldown, e não um sétimo desenho: parar de atacar é o
		extremo do que aquele ícone já significa, e a unidade também leva o realce
		vermelho junto. Um ícone próprio pode entrar aqui no dia em que a arte
		existir — muda esta linha e mais nada.
	]]
	Disabled = "DebuffCooldown",

	Highlight = {
		Buff = Color3.fromRGB(120, 200, 255),
		Debuff = Color3.fromRGB(255, 70, 70),
		Transparency = 0.75,
	},
}

--[[
	As classes que os efeitos enxergam.

	A classe de cada unidade fica em `UnitStats[nome].Class`, que aceita uma string
	ou uma lista — uma unidade pode ser `{"Melee", "Fire"}` e receber os dois lados
	do mesmo clima. Unidade sem `Class` continua funcionando: ela só não entra em
	nenhuma regra por tipo, e leva apenas o que o clima faz com `All`.
]]
WeatherConfig.ClassList = { "Melee", "Ranged", "Magic", "Fire", "Ice", "Electric" }

--[[
	O que cada clima faz.

	Tudo aqui é **multiplicador**: 0.7 é "cai 30%", 1.3 é "sobe 30%". Nunca um
	valor absoluto, para o efeito valer igual numa unidade de nível 0 e numa de
	nível 5.

	- `Units.All` vale para todas as unidades.
	- `Units.<Classe>` vale só para quem tem aquela classe, e **substitui** o `All`
	  naquela estatística. É por isso que o Fog escreve 0.55 para Magic em vez de
	  esperar que 0.7 e 0.55 se multipliquem: o número da classe é o número final.
	  A substituição é **por estatística**: o Ice da chuva escreve só `Cost`, e a
	  cadência dele continua saindo do `All`.
	- `Immune` tira a unidade do clima inteiro — nem debuff, nem buff, nem
	  congelamento, nem raio, nem desligamento.
	- `Disable` **desliga** a unidade: ela para de atacar enquanto o clima durar. É
	  um sim-ou-não por classe, e não um multiplicador, porque não existe "atacar
	  90% menos" — ou a unidade está no combate ou não está.
	- `Mobs` mexe nos inimigos: `Speed` entra na hora (inclusive nos que já estão
	  andando) e `Health` só vale para quem nascer com o clima ligado.

	As estatísticas de unidade são `Damage`, `Range`, `AttackSpeed` e `Cost`.

	`AttackSpeed` acima de 1 é ataque mais rápido — quem divide o cooldown por ela é
	o `UnitUpgradeConfig:GetCooldown`.

	`Cost` é o preço de **colocar** a unidade, e não o dos upgrades: quem o aplica é
	o `UnitUpgradeConfig:GetPlaceCost`, que o servidor cobra e o card mostra. O que a
	unidade vale na venda não muda com ele — ver o comentário do `GetPlaceCost`.
]]
WeatherConfig.Effects = {
	--[[
		Neblina: todo mundo enxerga menos. Magic sofre 1.5x mais o mesmo corte
		(30% * 1.5 = 45%), então o multiplicador dela é 0.55.
	]]
	Fog = {
		Units = {
			All = { Range = 0.7 },
			Magic = { Range = 0.55 },
		},
	},

	-- Vento: empurra o inimigo para a frente e o corpo a corpo para bater mais.
	Wind = {
		Mobs = { Speed = 1.3 },
		Units = {
			Melee = { AttackSpeed = 1.3 },
		},
	},

	--[[
		Seca: inimigo mais gordo, fogo em vantagem e gelo praticamente fora de
		combate — 60% a menos de dano, de cadência e de alcance.
	]]
	Drought = {
		Mobs = { Health = 1.4 },
		Units = {
			Fire = { Damage = 1.3, AttackSpeed = 1.2 },
			Ice = { Damage = 0.4, AttackSpeed = 0.4, Range = 0.4 },
		},
	},

	--[[
		Nevasca (a "BLIZZARD" da tela): além do corte de cadência, congela uma unidade
		sorteada de tempos em tempos (o `SnowService` cuida do compasso). Magic passa
		ileso pelos dois.

		Ice é a única que sai ganhando, e nas duas pontas — 25% de dano e 25% de
		cadência. Como a substituição é por estatística, o `1.25` dela cobre o `0.6`
		do `All`, e a unidade de gelo atira mais rápido na nevasca em vez de menos.
	]]
	Snow = {
		Immune = { Magic = true },
		Units = {
			All = { AttackSpeed = 0.6 },
			Ice = { Damage = 1.25, AttackSpeed = 1.25 },
		},
		Freeze = {
			Interval = 30,
			Duration = 10,

			--[[
				O desenho do congelamento, em `Assets.VFX`: o mesmo `IcedVFX` do
				congelamento do Frostione nos inimigos -- particulas soldadas no corpo
				da unidade e o Highlight dele pintando o modelo inteiro, pelos segundos
				que o servidor aplicou (`VFXController:PlayFreeze`).

				`Freeze` existir e tambem o que diz ao `VFXController` que este
				atordoamento tem desenho proprio: ele nao compara o clima com "Snow",
				ele procura o `Freeze` de quem causou o atordoamento. Clima sem `Freeze`
				— e o raio, e o gimmick de mob — continua so com o realce amarelo, e o
				congelado fica sem ele, para o amarelo nao brigar com o gelo.
			]]
			Asset = "IcedVFX",
		},
	},

	--[[
		Trovão: o raio atordoa quem acerta e salta para quem estiver perto (os
		números estão em `WeatherConfig.Thunder.Stun`). Electric ganha um bônus
		passivo enquanto o clima durar, e quando leva o raio não é atordoada: ganha
		um bem maior e temporário (`WeatherConfig.Thunder.Charge`). Magic não é alvo.
	]]
	Thunder = {
		Immune = { Magic = true },
		Units = {
			Electric = { Damage = 1.1 },
		},
	},

	--[[
		Chuva: apaga o fogo e encharca o resto.

		Unidade `Fire` **desliga** — não é debuff, ela sai do combate enquanto
		chover. As outras batem 35% mais devagar (0.65), e `Magic` sofre 1.5x o mesmo
		corte (52.5%), então o multiplicador dela é 0.475 — a mesma regra do Fog, e o
		motivo de o número da classe ser escrito pronto em vez de composto.

		`Ice` é a única que ganha alguma coisa: colocar custa 25% menos. É um convite
		a trocar o tabuleiro enquanto chove, e não um buff de combate — a cadência
		dela cai igual à de todo mundo, porque `Cost` é a única estatística que a
		linha da classe escreve.
	]]
	Rain = {
		Disable = { Fire = true },
		Units = {
			All = { AttackSpeed = 0.65 },
			Magic = { AttackSpeed = 0.475 },
			Ice = { Cost = 0.75 },
		},
	},

	--[[
		Tempestade de areia: menos dano, menos cadência e menos alcance para quem
		depende de ver. Magic não depende, e passa ileso.
	]]
	Sandstorm = {
		Immune = { Magic = true },
		Units = {
			All = { Damage = 0.7, AttackSpeed = 0.7, Range = 0.7 },
		},
	},
}

--[[ ============================== CONSULTAS ================================ ]]

local UnitStats = require(script.Parent.UnitStats)

local EMPTY = table.freeze({})

--[=[
	As classes de uma unidade, sempre como lista.

	Aceita `Class = "Melee"` e `Class = {"Melee", "Fire"}` porque a primeira forma é
	a que se escreve em 99% dos casos e a segunda é a que o config precisa suportar.
]=]
function WeatherConfig.GetClasses(unitName : string?) : { string }
	local stats = unitName and UnitStats[unitName]
	local class = stats and stats.Class
	if not class then
		return EMPTY
	end

	if typeof(class) == "string" then
		return { class }
	end

	return class
end

function WeatherConfig.HasClass(unitName : string?, className : string) : boolean
	for _, class in WeatherConfig.GetClasses(unitName) do
		if class == className then
			return true
		end
	end

	return false
end

function WeatherConfig.GetEffects(weatherName : string?)
	if not weatherName then return nil end
	return WeatherConfig.Effects[weatherName]
end

--[=[
	A unidade está fora deste clima?

	Imunidade é total: nem o debuff que todo mundo leva, nem o buff da própria
	classe, nem congelamento ou raio. É o que "não afeta unidades do tipo Magic"
	quer dizer.
]=]
function WeatherConfig.IsImmune(weatherName : string?, unitName : string?) : boolean
	local effects = WeatherConfig.GetEffects(weatherName)
	local immune = effects and effects.Immune
	if not immune then return false end

	for _, class in WeatherConfig.GetClasses(unitName) do
		if immune[class] then
			return true
		end
	end

	return false
end

--[=[
	A unidade está **desligada** por este clima?

	Desligada é sim-ou-não: ela para de atacar enquanto o clima durar, e nenhum
	multiplicador tem como dizer isso. Quem faz valer é o `UnitService`, que pula a
	unidade no laço de ataque; o resto (alcance, dano, cadência) continua sendo
	calculado normalmente e simplesmente não é usado.

	Imunidade vence: `Immune` tira a unidade do clima inteiro, e "inteiro" inclui
	não ser desligada.
]=]
function WeatherConfig.IsDisabled(weatherName : string?, unitName : string?) : boolean
	local effects = WeatherConfig.GetEffects(weatherName)
	local disable = effects and effects.Disable
	if not disable then return false end

	if WeatherConfig.IsImmune(weatherName, unitName) then return false end

	for _, class in WeatherConfig.GetClasses(unitName) do
		if disable[class] then
			return true
		end
	end

	return false
end

--[=[
	Multiplicador do clima para uma estatística de unidade (`Damage`, `Range`,
	`AttackSpeed` ou `Cost`). Sem clima, clima desconhecido ou unidade imune,
	devolve 1.

	A regra de precedência está no comentário de `Effects`: o valor da classe
	substitui o de `All`, e duas classes que mexam na mesma estatística se
	multiplicam entre si.
]=]
function WeatherConfig.GetUnitMultiplier(weatherName : string?, unitName : string?, stat : string) : number
	local effects = WeatherConfig.GetEffects(weatherName)
	local units = effects and effects.Units
	if not units then return 1 end

	if WeatherConfig.IsImmune(weatherName, unitName) then return 1 end

	local multiplier = 1
	local fromClass = false

	for _, class in WeatherConfig.GetClasses(unitName) do
		local entry = units[class]
		local value = entry and entry[stat]
		if value then
			multiplier *= value
			fromClass = true
		end
	end

	if fromClass then
		return multiplier
	end

	local all = units.All
	return (all and all[stat]) or 1
end

-- Multiplicador do clima para uma estatística de inimigo (`Speed` ou `Health`).
function WeatherConfig.GetMobMultiplier(weatherName : string?, stat : string) : number
	local effects = WeatherConfig.GetEffects(weatherName)
	local mobs = effects and effects.Mobs
	return (mobs and mobs[stat]) or 1
end

-- Os climas que um mapa pode sortear. Mapa sem pool devolve lista vazia.
function WeatherConfig.GetPool(mapName : string?) : { string }
	local pool = mapName and WeatherConfig.MapPools[mapName]
	return pool or EMPTY
end

--[[
	Nome que o aviso mostra. Sem entrada em `DisplayNames`, é o nome do Model em
	caixa alta.
]]
function WeatherConfig.GetDisplayName(weatherName : string) : string
	return WeatherConfig.Warning.DisplayNames[weatherName] or string.upper(weatherName)
end

return WeatherConfig
