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
export type Options = {
	-- Combinação batizada em `Presets`, aplicada por baixo do resto.
	Preset : string?,

	-- Máquina de escrever.
	Speed : number?,
	Sound : (string | number)?,
	SoundVolume : number?,

	-- Aparência.
	Size : number?,
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
	shiny = { HyperText = { Open = "<shiny=true>", Close = "</shiny>" } },
	fog = { HyperText = { Open = "<fog=true>", Close = "</fog>" } },
	gradient = { HyperText = { Open = "<gradient=true>", Close = "</gradient>" } },

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
