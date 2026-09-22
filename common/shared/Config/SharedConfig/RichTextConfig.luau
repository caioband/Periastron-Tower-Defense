--[[
	Texto rico: o vocabulário que o jogo fala.

	Quem escreve texto animado no jogo não escreve tag de biblioteca nenhuma — fala
	este vocabulário, e o `RichTextController` traduz para a tecnologia da vez (hoje
	o HyperText, em `ReplicatedStorage.Shared.Vendor.HyperText`).

	São três tabelas, e é de propósito que as três fiquem no mesmo arquivo: elas são
	o contrato inteiro. Trocar de biblioteca é reescrever a coluna da biblioteca em
	`Aliases`, escrever um backend novo e não tocar em mais nada do jogo.

		Options   — o que dá para pedir de um render (velocidade, cor, fonte...)
		Presets   — combinações batizadas: "Dialogue", "Warning", "Instant"
		Aliases   — a marcação dentro do texto: `[shake]NEVASCA[/shake]`

	**A marcação.** Colchete, não sinal de menor: `[nome]texto[/nome]` para o que
	envolve um trecho, `[nome]` sozinho para o que é um ponto no texto (`[br]`,
	`[pause]`). Alias que aceita valor recebe com `=`: `[color=red]`, `[size=40]`,
	`[pause=1]`. O colchete separa a nossa marcação da do vendor: um `<...>` escrito
	à mão continua chegando cru na biblioteca — é a saída de emergência para o que
	ainda não virou alias, e quem usa sabe que está se amarrando à tecnologia.

	**Por que os dois níveis.** `Options` é o que vale para o render todo e não cabe
	no texto (a fonte, o alinhamento, a velocidade); `Aliases` é o que vale para um
	pedaço e só faz sentido no meio da frase. Texto que vem do servidor ou de
	tradução atravessa a rede como texto — por isso o efeito viaja dentro dele.
]]

local RichTextConfig = {}

--[[
	Ordem de preferência dos backends. O controller tenta de cima para baixo e fica
	no primeiro que carregar.

	`Plain` é o fim da fila e não falha nunca: ele arranca a marcação e escreve o
	texto puro num TextLabel. É o que segura a tela quando o vendor sai do sync ou
	quebra num update da Roblox — aviso feio é melhor que aviso nenhum.
]]
RichTextConfig.Backends = { "HyperText", "Plain" }

--[=[
	O que dá para pedir de um render. Tudo opcional; o que não vier fica no valor
	do `Defaults` e, faltando lá também, no padrão do backend.

	`Speed` é em **caracteres por segundo**, não em intervalo — é assim que se
	pensa em máquina de escrever, e é o backend que converte. `Speed = 0` escreve
	tudo de uma vez.
]=]
--[=[
	Como o tamanho da letra sai da **caixa**, e não de um número de pixels.

	Pixel não se traduz entre telas: 12px ocupam um quinto de uma caixa no monitor e
	metade dela no celular, e a mesma frase que cabia some ou estoura. Pedindo `Fit`, o
	controller mede a caixa no instante da escrita e tira dela o tamanho da letra — é
	`Size` calculado, não escrito.

	São duas paredes, e a letra é a menor das duas:

	  1. **a altura** da caixa vezes `TextRatio`, dividida pelas fileiras;
	  2. **a largura** da caixa contra a largura real da frase mais comprida, também
	     dividida pelas fileiras.

	E é por isso que as **fileiras** entram na conta. Uma frase de 32 caracteres numa
	caixa estreita fica minúscula se tiver de caber em uma fileira só — a largura manda,
	e manda pouco. Deixando-a usar duas, a largura disponível dobra e a altura de cada
	fileira cai à metade: onde a caixa é larga e baixa a primeira opção ganha, e onde ela
	é estreita e alta ganha a segunda. O controller experimenta de 1 a `MaxRows` e fica
	com a que der a **letra maior**, que é a definição do que se quer aqui.

	`TextRatio` é a altura da letra como fração da altura da caixa — o que sobra é a
	folga em volta.

	`MinTextSize` é o piso: abaixo dele não se lê, e é melhor a frase estourar a caixa
	(e alguém ver o problema) que virar uma tarja cinza. `MaxTextSize` é o teto, para a
	caixa grande com frase curta não virar letreiro.

	`MaxRows` é quantas fileiras uma frase pode ocupar. 1 é o padrão porque é o que não
	surpreende: caixa de uma linha só. Container que quebra linha (uma fala, um tutorial)
	diz aqui quantas linhas cabem nele.

	`WidthPerChar` é o **plano B**: a largura da frase é medida de verdade
	(`TextService`), e esta estimativa por caractere só entra quando a medida falha (a
	fonte não carregou, a chamada foi recusada). 0.6 é a média de uma fonte
	proporcional; fonte quase monoespaçada (a Press Start 2P) quer 1.

	`Font` é com que fonte a largura é medida, e só vale quando o render não disse a
	dele em `Options.Font`. O valor é o padrão do HyperText — medir numa fonte e desenhar
	noutra dá uma letra do tamanho errado, e este é o único lugar em que o palpite cabe.

	`LayoutTimeout` é quanto se espera a caixa ter tamanho **estável** antes de medir.
	Peça criada agora só mede depois da passada de layout, e medir antes disso congela
	uma letra do tamanho de um valor intermediário. Ver `RichTextController:AwaitLayout`.

	`Debug` acende no output do Studio **qual das duas paredes** mandou no tamanho. Sem
	isso, ajustar uma caixa é tentativa e erro: mexer em `TextRatio` não faz nada quando
	é a largura que limita, e mexer em `MaxRows` não faz nada quando é a altura.
]=]
export type FitOptions = {
	TextRatio : number?,
	MaxRows : number?,
	MinTextSize : number?,
	MaxTextSize : number?,
	WidthPerChar : number?,
	Font : string?,
	LayoutTimeout : number?,
	Debug : boolean?,
}

export type Options = {
	-- Combinação batizada em `Presets`, aplicada por baixo do resto.
	Preset : string?,

	-- Máquina de escrever.
	Speed : number?,
	Sound : (string | number)?,
	SoundVolume : number?,

	-- Aparência.
	Size : number?,

	--[[
		Tira o `Size` da caixa em vez de aceitar o que veio em pixels. `true` usa os
		padrões de `RichTextConfig.Fit`; uma tabela ajusta o que quiser deles.

		Ligado, a escrita **dorme**: ela espera a caixa ter tamanho estável e mede a
		largura da frase numa chamada assíncrona. Quem escreve dentro de um clique já
		está numa thread própria; quem não estiver, que use `task.spawn`.
	]]
	Fit : (boolean | FitOptions)?,

	Color : Color3?,
	Font : string?,
	Weight : Enum.FontWeight?,
	Italic : boolean?,
	Transparency : number?,
	Stroke : { Thickness : number?, Color : Color3?, Transparency : number? }?,
	Shadow : { Color : Color3?, Offset : Vector2? }?,

	-- Entrada de cada caractere: "slide", "bounce", "wiggle", "grow" ou "none".
	Anim : string?,
	AnimDuration : number?,
	AnimLoop : boolean?,

	-- Layout dentro do container.
	Align : Enum.HorizontalAlignment?,
	VerticalAlign : Enum.VerticalAlignment?,
	ZIndex : number?,
	Wrapped : boolean?,

	-- `true` segura a thread de quem chamou até o render acabar.
	Yield : boolean?,
}

--[[
	O que vale para todo render que não pedir diferente.

	Curto de propósito: cada valor aqui é uma decisão que o backend deixaria de
	tomar. `Anim = "none"` porque a maioria das telas quer texto, não animação de
	entrada — quem quer a animação pede o preset.
]]
RichTextConfig.Defaults = {
	Speed = 0,
	Anim = "none",
	Wrapped = true,
} :: Options

--[[
	Os padrões do `Fit`, para o render que pediu `Fit = true` e não quis escolher nada.
	O que vier na chamada entra por cima, campo a campo. Ver o tipo `FitOptions`.
]]
RichTextConfig.Fit = {
	TextRatio = 0.9,
	MaxRows = 1,
	MinTextSize = 6,
	MaxTextSize = math.huge,
	WidthPerChar = 0.6,
	Font = "rbxasset://fonts/families/FredokaOne.json",
	LayoutTimeout = 1,
	Debug = true,
} :: FitOptions

--[[
	Combinações batizadas.

	O nome é o que o código do jogo diz; o conteúdo é ajuste de designer e pode
	mudar aqui sem ninguém ficar sabendo.
]]
RichTextConfig.Presets = {
	-- Texto que só precisa aparecer.
	Instant = {
		Speed = 0,
		Anim = "none",
	},

	-- Aviso curto e urgente, do tamanho do `WarningController`: entra letra a
	-- letra, rápido, com contorno para sobreviver a qualquer fundo.
	Warning = {
		Speed = 45,
		Anim = "slide",
		AnimDuration = 0.35,
		Stroke = { Thickness = 0.04, Color = Color3.new(0, 0, 0) },
		Align = Enum.HorizontalAlignment.Center,
		VerticalAlign = Enum.VerticalAlignment.Center,
	},

	--[[
		Fala de NPC: devagar o bastante para ser lida no ritmo de quem fala.

		`Size` é a altura da linha em pixels **na caixa do tamanho em que ela estava
		quando o texto entrou** — o renderizador guarda esse tamanho como referência
		e reescala o texto junto com a tela, então o número vale para todas as
		resoluções. 24 é o que cabe na `DialogGUI.Container` de hoje (625x287) com
		folga para quatro linhas; 38 já estoura a caixa e parte palavra no meio.
		Caixa de outro tamanho pede outro número, e é aqui que ele se muda.
	]]
	Dialogue = {
		Size = 24,
		Speed = 28,
		Anim = "slide",
		AnimDuration = 0.25,

		-- Centrado nos dois eixos: a fala ocupa a caixa inteira em vez de crescer a
		-- partir do canto de cima, e frase curta não fica boiando no alto.
		Align = Enum.HorizontalAlignment.Center,
		VerticalAlign = Enum.VerticalAlignment.Center,
	},
} :: { [string] : Options }

--[=[
	As paletas que `[gradient=nome]` usa.

	Cor em `r,g,b`, separadas por `;` — é o formato que o HyperText entende, e
	repeti-lo aqui é mais honesto que inventar um nosso e converter no meio do
	caminho. De 1 a 18 cores.

	`MoveSpeed` é quantas voltas completas de cor o gradiente dá por segundo; zero é
	gradiente parado. `MoveDir` ("left" ou "right") e `Rot` (graus) são opcionais.

	O nome é o que o jogo escreve — `[gradient=orange]` —, e é ele que sobrevive a
	uma troca de biblioteca. As cores são ajuste de designer e mudam aqui.
]=]
RichTextConfig.Gradients = {
	-- O do módulo, para quem escreve `[gradient]` sem dizer qual.
	default = { Colors = "85,170,255;255,85,0" },

	orange = { Colors = "255,205,95;255,110,20", MoveSpeed = 0.2 },
	green = { Colors = "165,255,150;35,170,80", MoveSpeed = 0.5 },
	gold = { Colors = "255,240,170;225,165,40", MoveSpeed = 0.3 },
	ice = { Colors = "200,245,255;70,160,255", MoveSpeed = 0.25 },
}

--[=[
	A marcação que o jogo escreve, e no que ela vira em cada backend.

	Cada alias tem uma coluna por backend. A do `Plain` não existe porque o Plain
	apaga tudo — é essa a proposta dele.

	`%s` é onde entra o valor de `[nome=valor]`. Alias com `%s` e sem `Default`
	exige valor; sem `%s`, valor é ignorado. Alias sem `Close` é ponto no texto e
	não se fecha: `[br]`, `[pause=1]`.

	`Converter` é o valor que não é o mesmo nos dois mundos: `"Speed"` é
	caractere por segundo aqui e intervalo em segundos lá dentro. Quem converte é o
	backend, porque a unidade de chegada é dele.

	O valor que o jogador escreve nunca chega aqui — `RichTextController:Escape()`
	existe para nome de jogador e chat, e neutraliza colchete e `<` antes.
]=]
export type Alias = {
	HyperText : { Open : string, Close : string? }?,
	Default : string?,
	Converter : string?,
}

RichTextConfig.Aliases = {
	--[[ ESTILO ]]

	b = { HyperText = { Open = "<weight=bold>", Close = "</weight>" } },
	i = { HyperText = { Open = "<italic=true>", Close = "</italic>" } },
	u = { HyperText = { Open = "<underline=true>", Close = "</underline>" } },
	s = { HyperText = { Open = "<strike=true>", Close = "</strike>" } },

	color = { HyperText = { Open = "<color=%s>", Close = "</color>" } },
	size = { HyperText = { Open = "<size=%s>", Close = "</size>" } },
	font = { HyperText = { Open = "<font=%s>", Close = "</font>" } },
	trans = { HyperText = { Open = "<trans=%s>", Close = "</trans>" } },

	stroke = { HyperText = { Open = "<stroke=true>", Close = "</stroke>" } },
	shadow = { HyperText = { Open = "<shadow=true>", Close = "</shadow>" } },
	mark = { HyperText = { Open = "<mark=true>", Close = "</mark>" } },

	--[[ EFEITO ]]

	-- Tremor curto e violento — dano, perigo, coisa quebrando.
	shake = { HyperText = { Open = "<shake=true loop=true dur=.4>", Close = "</shake>" } },

	--[[
		Ondulação contínua — coisa mágica, flutuante.

		`amp` é a altura da onda como fração do tamanho da letra, e é ela que faz o
		efeito ser leve ou circense: o padrão do módulo (.3) sacode a frase inteira.
		.1 com `rot=false` deixa a linha ondulando sem as letras se inclinarem — o
		texto continua legível enquanto se mexe, que é o ponto de usar isso numa
		fala.
	]]
	wiggle = { HyperText = { Open = "<anim=wiggle loop=true amp=.1 rot=false>", Close = "</anim>" } },

	rainbow = { HyperText = { Open = "<rainbow=true>", Close = "</rainbow>" } },
	fog = { HyperText = { Open = "<fog=true>", Close = "</fog>" } },

	-- Faíscas em cima do texto. O valor é a cor delas: um atalho do módulo
	-- (`[shiny=yellow]`) ou `r,g,b`.
	shiny = { HyperText = { Open = "<shiny=true color=%s>", Close = "</shiny>" }, Default = "white" },

	-- Gradiente por paleta batizada em `RichTextConfig.Gradients`.
	gradient = {
		HyperText = { Open = "<gradient=true %s>", Close = "</gradient>" },
		Default = "default",
		Converter = "Gradient",
	},

	-- Dourado com brilho: a cor da letra e a faísca de uma vez, porque as duas
	-- juntas é que fazem o efeito — só a cor é texto amarelo, só a faísca é
	-- purpurina no escuro.
	gold = {
		HyperText = {
			Open = "<color=255,205,70><shiny=true color=255,240,175 rate=1.5>",
			Close = "</shiny></color>",
		},
	},

	--[[ RITMO E PONTUAÇÃO ]]

	-- Quebra de linha. O `\n` cru é ignorado pelo HyperText de propósito.
	br = { HyperText = { Open = "<br=%s>" }, Default = "1" },

	-- Pausa no meio da digitação, em segundos.
	pause = { HyperText = { Open = "<wait=%s>" }, Default = "0.4" },

	-- Velocidade daqui para frente, em caracteres por segundo. O backend converte.
	speed = { HyperText = { Open = "<interval=%s>", Close = "</interval>" }, Converter = "Speed" },

	-- Imagem inline pelo id do asset.
	img = { HyperText = { Open = "<img=%s>" } },

	-- Marca no texto que dispara `handle:OnEvent(nome)` quando a digitação chega
	-- nela. É como a fala sincroniza som e câmera com a própria frase.
	event = { HyperText = { Open = "<renderEvent=%s>" } },
} :: { [string] : Alias }

return RichTextConfig
