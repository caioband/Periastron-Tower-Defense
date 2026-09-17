--[[
	A seta que aponta um lugar no mundo: `Shared.Assets.VFX.IndicatorArrow`.

	Quem a coloca e anima é o `ArrowController`. Aqui ficam o caminho do modelo e os
	números do movimento.

	**Não confundir com o `ArrowConfig`** do `SharedConfig`, que é a flecha do Archer
	— projétil, dano, velocidade de voo. Esta aqui não acerta ninguém: ela só aponta.

	O modelo mora no place, não no git (o `Shared.Assets` não é sincronizado pelo
	Rojo, como o `StarterGui` e o `vfx`), e existe nas duas places. Por isso o
	caminho é por nome e resolvido tarde: place sem o modelo não quebra, só não
	aponta nada.
]]

local IndicatorArrowConfig = {}

--[[
	Onde o modelo está, a partir de `ReplicatedStorage.Shared`, e onde as cópias
	vivas ficam penduradas no `Workspace`.

	A pasta no Workspace é criada na primeira seta e não é limpa por ninguém além
	deste controller — ela não entra no `Workspace.Map`, que o `MapService` troca
	entre partidas.
]]
IndicatorArrowConfig.Asset = {
	Path = { "Assets", "VFX" },
	Name = "IndicatorArrow",
}

IndicatorArrowConfig.Container = "Indicators"

--[=[
	O voo da seta.

	`Height` é a **folga entre a ponta da seta e o alvo**, em studs — não a altura do
	pivô. A diferença importa: o pivô do modelo está onde o designer o deixou (hoje,
	na ponta), e o controller mede essa distância sozinho, então mexer no pivô no
	Studio, ou definir um `PrimaryPart`, não muda onde a seta aponta. Zero encosta a
	ponta no alvo.

	`Spin` é em **voltas por segundo** e `Bob.Speed` em **ciclos por segundo**: os
	dois são o que se pensa ao olhar ("uma volta a cada segundo"), e não radianos
	por quadro.

	`Bob.Amplitude` é em studs, de quanto ela sobe e desce a partir da altura.
]=]
IndicatorArrowConfig.Motion = {
	Height = 1.5,

	Spin = 0.35,

	Bob = {
		Amplitude = 0.6,
		Speed = 0.8,
	},
}

--[[
	Tamanho da cópia, em cima do tamanho autorado (o modelo tem 4x7x1 studs). É
	`Model:ScaleTo`, então vale para o modelo inteiro e para o pivô junto.
]]
IndicatorArrowConfig.Scale = 1

return IndicatorArrowConfig
