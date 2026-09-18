--[[
	O destaque: escurece a tela inteira menos um retângulo em volta de um GuiObject.

	A técnica é a do `UIStroke` gigante, que é a que o DevForum converge: um frame
	transparente com um `UIStroke` de espessura absurda pinta **tudo o que está
	fora** dele. O frame vira o buraco do holofote, o `UICorner` arredonda a borda
	de graça, e não há imagem nem quatro máscaras para manter alinhadas.

	Quem desenha é o `HighlightController`. Aqui ficam os números.
]]

local HighlightConfig = {}

--[[
	A tela do destaque, criada em código pelo controller.

	`DisplayOrder` precisa passar das telas do jogo (todas em 0 hoje) e **ficar
	abaixo** de qualquer tela que deva aparecer por cima do escurecimento — a caixa
	de fala, por exemplo, se um passo de tutorial quiser explicar o que está
	destacado. A `DialogGUI` está em 0 hoje; querendo ela por cima, é o
	`DisplayOrder` dela que sobe, não este que desce (senão o destaque volta para
	trás do HUD).

	`IgnoreGuiInset` é `true` para o escurecimento cobrir também a faixa da topbar.
	Isso desalinha o `AbsolutePosition` em 36px — o controller resolve isso medindo,
	não compensando na mão; ver `HighlightController:origin`.
]]
HighlightConfig.Gui = {
	Name = "Highlight",
	DisplayOrder = 5,
	IgnoreGuiInset = true,
}

--[=[
	O buraco.

	`Padding` é a folga de cada lado do alvo (destaque colado no botão parece erro
	de alinhamento) e `Radius` é o `UICorner` — os dois **proporcionais ao alvo**,
	não em pixels fixos.

	O motivo é que pixel não é medida de tamanho aparente: 8px de folga num botão de
	200px no monitor é um detalhe, e no mesmo botão a 60px num celular é um quadro
	em volta dele. `Fraction` é a fração do menor lado do alvo, e `Min`/`Max` são o
	chão e o teto em pixels, para folga nem sumir num ícone minúsculo nem virar
	moldura num painel inteiro.

	Quem passa `Padding = 16` no `:Show()` continua mandando pixel cravado — é a
	saída para o caso em que o proporcional não serve.

	`Thickness` é a espessura do `UIStroke`, em pixels: ele precisa passar da maior
	tela em que o jogo roda, porque é ele que pinta o resto. Dez mil cobre qualquer
	monitor de hoje com folga e não custa nada — a espessura não vira geometria, é
	um contorno.

	`Transparency` é o quanto do jogo continua aparecendo por baixo do escuro: 0 é
	preto sólido, 1 é invisível. Medido na tela do jogo: 0.45 escurece de leve
	demais para um passo de tutorial — o olho não é puxado. 0.35 separa sem apagar o
	cenário, e é o número a mexer se você quiser mais ou menos drama.
]=]
HighlightConfig.Hole = {
	Padding = { Fraction = 0.15, Min = 6, Max = 22 },
	Radius = { Fraction = 0.22, Min = 6, Max = 18 },

	Thickness = 10000,
	Color = Color3.fromRGB(0, 0, 0),
	Transparency = 0.35,
}

--[=[
	As animações.

	`FadeIn`/`FadeOut` são do escurecimento (a transparência do stroke). `Move` é o
	tempo de o buraco escorregar de um alvo para outro quando o destaque troca de
	alvo sem sair da tela — trocar de estalo faria o jogador perder de vista o que
	está sendo apontado.
]=]
HighlightConfig.Tween = {
	FadeIn = 0.25,
	FadeOut = 0.2,
	Move = 0.25,

	EasingStyle = Enum.EasingStyle.Quad,
	EasingDirection = Enum.EasingDirection.Out,
}

--[=[
	O bloqueio de clique. **Desligado por padrão**, e isso é a parte importante.

	O `UIStroke` não recebe input — ele é contorno, não superfície. Quem bloqueia,
	quando se pede bloqueio, são quatro frames invisíveis e `Active` que o controller
	monta em volta do buraco: eles engolem o clique de fora e deixam o miolo livre.

	O padrão é `false` porque destaque não é modal. Um retângulo de luz em cima de
	uma carta não deveria impedir o jogador de **girar a câmera** nem de clicar no
	chão — e foi exatamente o que aconteceu quando o padrão era `true`: o passo que
	manda colocar a unidade bloqueava o clique no mundo que ele mesmo pedia.

	Quem quer o bloqueio pede por chamada — `Highlight:Show(alvo, { BlockInput = true })`
	—, e isso só faz sentido quando o alvo é a **única** coisa clicável do passo: um
	botão de UI, e nunca um lugar do mapa.
]=]
HighlightConfig.BlockInput = false

return HighlightConfig
