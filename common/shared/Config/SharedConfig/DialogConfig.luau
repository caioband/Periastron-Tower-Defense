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

--[=[
	O que acontece **atrás** da fala enquanto ela está na tela.

	Os três são pedidos a sistemas que já existem, e não invenção daqui:

	  - `HideOtherUIs` usa o `InterfaceController` — o mesmo "some com o resto" do
	    painel de mapas, da contagem do portal e da cutscene. `HideReason` é o nome
	    do pedido; um `Show` com esse nome desfaz.
	  - `Blur` usa o `UIBlur` compartilhado (`LightingUtil`), o mesmo borrão da loja
	    e dos painéis de proximidade. Um só no Lighting: dois `BlurEffect` somariam.
	  - `Duck` usa o `MusicController:Duck`, que abaixa a música sem mexer no volume
	    que o jogador escolheu. Só a música: os SFX continuam no que estão, senão o
	    próprio som de digitação da fala sairia abafado junto.

	Cada um pode ser desligado por fala (`Blur = false` no `:Play()`), e o que está
	aqui é o padrão de quando ninguém diz nada.

	> O borrão é compartilhado de propósito, e isso tem um preço: fala que fecha
	> enquanto um painel borrado está aberto leva o borrão dele junto. Na prática não
	> acontece, porque a fala esconde os outros painéis — mas é bom saber antes de
	> alguém desligar o `HideOtherUIs`.
]=]
DialogConfig.Background = {
	HideOtherUIs = true,
	HideReason = "Dialog",

	Blur = {
		Enabled = true,

		-- O mesmo 24 do `ProximityPanel`: dois borrões diferentes para a mesma cara
		-- de "tem painel na frente" só fariam a tela piscar entre um e outro.
		Size = 24,

		TweenIn = 0.35,
		TweenOut = 0.25,
		EasingStyle = Enum.EasingStyle.Quad,
		EasingDirection = Enum.EasingDirection.Out,
	},

	Duck = {
		Enabled = true,

		-- Um quarto do volume: a música não some (a fala não é cutscene), só sai da
		-- frente do que está sendo dito.
		Scale = 0.25,

		FadeIn = 0.4,
		FadeOut = 0.8,
	},
}

--[[
	Os dois botões que o designer deixou dentro do `Container`.

	`Names` é a ordem que o código usa: `Dialog:SetButton(1, ...)` mexe no primeiro
	nome da lista. Na tela de hoje o `Button1` é o da **direita** e o `Button2` é o
	da **esquerda** — a posição é do designer, e trocar a ordem aqui é como se
	inverte isso sem mexer em quem chama.

	O texto vai num TextLabel que o controller cria dentro do botão na primeira vez
	que ele é usado: o botão é um ImageButton, não tem texto próprio, e a alternativa
	seria exigir que alguém lembrasse de autorar um label em cada botão novo.
	`Label` é a aparência desse label; `MaxTextSize` existe porque `TextScaled` num
	botão de 169x61 transformaria "OK" numa letra de cartaz.
]]
DialogConfig.Buttons = {
	Names = { "Button1", "Button2" },

	Label = {
		Name = "Label",
		Font = Enum.Font.GothamBold,
		Color = Color3.fromRGB(255, 255, 255),
		MaxTextSize = 26,
		Padding = 10,
	},
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
--[=[
	Os botões que o comando `dialog` acende junto com a fala de teste.

	Só texto: callback não atravessa a rede (é função), então na demo os dois
	funcionam como "continuar" — que é o que um botão sem callback faz. Botão com
	comportamento próprio se monta no cliente, com `Dialog:SetButton`.
]=]
DialogConfig.DemoButtons = {
	{ Text = "YES" },
	{ Text = "NO" },
}

DialogConfig.Demo = {
	"[color=white]Caio is [/color][color=green]a good developer[/color][pause=0.8][color=white] and a [/color][color=blue][wiggle]chill guy[/wiggle][/color]",
	".[pause=0.3].[pause=0.3].[pause=0.3] [color=red][shake]RIGHT?[/shake][/color][event=fim]",
}

return DialogConfig
