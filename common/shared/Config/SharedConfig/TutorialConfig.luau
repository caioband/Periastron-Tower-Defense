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

return TutorialConfig
