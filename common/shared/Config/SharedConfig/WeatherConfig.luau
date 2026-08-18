--[[
	Climas.

	Um clima é um Model em `ReplicatedStorage.Shared.Assets.Weathers`:

		Assets.Weathers
		└── Snow                  (Model, tag "AreaWeather")
			├── Part              (Part com os ParticleEmitters)
			└── Lighting          (Folder — preset do LightingService)

	A **tag** diz como a Part é encaixada no mapa, e a pasta `Lighting` é um preset
	no mesmo formato de `Assets.Lighting` (atributos = propriedades do Lighting,
	filhos = instâncias). O `WeatherService` registra essa pasta como preset e
	aplica pelo `LightingService`, então a troca de clima entra na mesma transição
	interpolada de qualquer outra troca de iluminação.

	Fica em `common/` porque as duas places montam o Weathers.
]]

local WeatherConfig = {}

-- Onde os climas moram, a partir de `ReplicatedStorage`.
WeatherConfig.AssetsPath = { "Shared", "Assets", "Weathers" }

--[[
	Como a Part do clima é encaixada no mapa:

	- `Area`: vira a caixa do mapa. Neblina, neve — coisa que acontece *dentro* da
	  área jogável.
	- `Sky`: fica X e Z do tamanho do mapa e sobe para um offset acima do pico. A
	  altura (Y da Part) é a autorada, porque é a espessura da camada, não a
	  extensão dela.

	Model sem nenhuma das duas tags é recusado — é mais fácil de achar do que um
	clima que entra e não encaixa em nada.
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

-- Nome da Part que leva os emissores. Não achando, vale a primeira BasePart.
WeatherConfig.PartName = "Part"

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
}

return WeatherConfig
