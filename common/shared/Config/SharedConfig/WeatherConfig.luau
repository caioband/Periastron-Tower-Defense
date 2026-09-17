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

		`Damage` multiplica o dano (1.5 = +50%). `AttackSpeed` divide o cooldown, entao
		2 e -50% de cooldown (o dobro de ataques), e nao 1.5.

		Fora isso o Electric ja ganha um bonus passivo enquanto o clima durar, que
		mora em `Effects.Thunder.Units.Electric` — este aqui e o temporario, que so
		entra quando o raio (ou o arco) encosta na unidade.
	]]
	Charge = {
		Damage = 1.5,
		AttackSpeed = 2,
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
	DisplayNames = {},
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
		Neve: além do corte de cadência, congela uma unidade sorteada de tempos em
		tempos (o `SnowService` cuida do compasso). Magic passa ileso pelos dois.
	]]
	Snow = {
		Immune = { Magic = true },
		Units = {
			All = { AttackSpeed = 0.75 },
			Ice = { AttackSpeed = 1.25 },
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
		Tempestade de areia: menos dano e menos alcance para quem depende de ver.
		Magic não depende, e passa ileso.
	]]
	Sandstorm = {
		Immune = { Magic = true },
		Units = {
			All = { Damage = 0.7, Range = 0.7 },
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
