--[[
	A caixa de fala: `StarterGui.SharedUIs.DialogGUI.Container`.

	Quem escreve nela é o `DialogController`, e quem desenha o texto é o
	`RichTextController` — então a fala aceita a marcação de sempre:

		"Bem-vindo ao [color=yellow]Periastron[/color].[pause=.6] Sente-se."

	`Gui` é o caminho por nome em vez de um `WaitForChild` escrito no controller: a
	tela mora no place (o `StarterGui` não é sincronizado pelo Rojo), e renomear um
	frame no Studio tem de ser uma linha aqui, não um erro em runtime.

	Fica em `common/` porque as duas places têm a `SharedUIs`.
]]

local DialogConfig = {}

--[[
	Onde a caixa mora dentro da `PlayerGui`. `Folder` é a `SharedUIs`, que o
	StarterGui copia inteira para cada jogador.
]]
DialogConfig.Gui = {
	Folder = "SharedUIs",
	Screen = "DialogGUI",
	Container = "Container",
}

--[[
	As opções que vão para o `RichTextController` em toda fala. Quem chama o
	`:Play()` pode passar por cima — o preset da fala, o ritmo, a fonte.
]]
DialogConfig.Text = {
	Preset = "Dialogue",
}

--[[
	Como o jogador passa a fala.

	Clique, toque, `E`, espaço, enter e o A do controle — a fala é interrupção, e
	tentar sair dela apertando a tecla errada é frustração barata de evitar.

	`Debounce` existe porque o mesmo clique que termina de escrever a linha chegaria
	milissegundos depois para pular a próxima: sem ele, um clique fecharia a
	conversa inteira.
]]
DialogConfig.Advance = {
	Keys = {
		Enum.KeyCode.E,
		Enum.KeyCode.Space,
		Enum.KeyCode.Return,
		Enum.KeyCode.ButtonA,
	},

	Mouse = true,
	Touch = true,
	Debounce = 0.2,
}

--[[
	Fala em modo automático (`Auto = true` no `:Play()`), que é a que ninguém
	precisa passar: quantos segundos a linha fica na tela depois de terminar de
	escrever.
]]
DialogConfig.AutoHold = 2.5

--[[
	O texto do comando `dialog` do Cmdr.

	Ele é fixo de propósito: serve para ver, numa tela de verdade, a máquina de
	escrever, a cor, a pausa no meio da frase, a ondulação, o tremor e o `[event=]`
	chegando no `OnEvent` — todos de uma vez. Cada entrada é uma linha da conversa.

	A segunda linha começa com três pontos separados por `[pause=0.3]`: é a
	reticência aparecendo no ritmo de quem hesita, e de quebra mostra que a pausa
	vale no meio de uma palavra, não só entre frases.
]]
DialogConfig.Demo = {
	"[color=white]Caio is [/color][color=green]a good developer[/color][pause=0.8][color=white] and a [/color][color=blue][wiggle]chill guy[/wiggle][/color]",
	".[pause=0.3].[pause=0.3].[pause=0.3] [color=red][shake]RIGHT?[/shake][/color][event=fim]",
}

return DialogConfig
