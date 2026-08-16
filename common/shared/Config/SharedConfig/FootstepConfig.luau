--[[
	Sons de passo, por superfície.

	O jogo é stud: o Material das parts não diz nada sobre o chão, então a
	superfície vem de um atributo posto na própria Part (ou em qualquer pai dela).
	O FootstepController lê esse atributo no que o raio embaixo do pé acertar.

		Part.Surface = "Grass"

	Cada superfície tem uma lista de Ids — as variações. O controller sorteia uma
	a cada passo e evita repetir a anterior, então bastam três ou quatro pra não
	soar mecânico. Superfície sem Id configurado não toca nada (e avisa uma vez
	no Studio).
]]

local FootstepConfig = {}

-- Nome do atributo lido na Part pisada.
FootstepConfig.Attribute = "Surface"

--[[
	Superfície usada quando a Part pisada não tem o atributo em lugar nenhum da
	hierarquia. `nil` = silêncio, de propósito: assim uma part sem atributo fica
	obviamente muda em vez de fingir ser grama.
]]
FootstepConfig.Default = nil :: string?

-- Quanto o raio desce a partir do pé procurando o chão.
FootstepConfig.RayLength = 5

-- Piso geral, multiplicado pelo Volume da superfície.
FootstepConfig.Volume = 0.5

-- Cada passo sorteia um PlaybackSpeed nessa faixa.
FootstepConfig.PitchRange = { 0.94, 1.06 }

-- Trava de segurança contra marcador duplicado ou animação acelerada demais.
FootstepConfig.MinInterval = 0.1

-- Rolloff do som 3D no pé.
FootstepConfig.RollOffMin = 4
FootstepConfig.RollOffMax = 45

--[[
	Uma entrada por superfície. Além de `Ids`, aceita `Volume` e `PitchRange`
	próprios, que substituem os gerais acima.

		Stone = {
			Ids = { "rbxassetid://111", "rbxassetid://222" },
			Volume = 0.8,
			PitchRange = { 0.9, 1.1 },
		},
]]
FootstepConfig.Surfaces = {
	Grass = {
		Ids = {
			"rbxassetid://122259384750055",
			"rbxassetid://79848070365594",
			"rbxassetid://73277262867221",
		},
	},
}

--[[
	Pulo. Mesma forma das superfícies (aceita `Volume` e `PitchRange` próprios) e
	entra no mesmo pré-carregamento, mas não depende do chão: toca no salto,
	qualquer que seja a superfície. Mais de um id vira variação, igual aos passos.
]]
FootstepConfig.Jump = {
	Ids = {
		"rbxassetid://136494849780065",
	},
}

return FootstepConfig
