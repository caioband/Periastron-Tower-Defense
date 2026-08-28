--[[
	A loja de cartas de round: `StarterGui.RoundCardShop`.

	De X em X waves o botão da loja entra pela direita da tela e oferece **três
	cartas sorteadas** desta tabela. A carta comprada sai do caixa da partida
	(o `roundcash` do `MobService`, e não o `Cash` do perfil), vai para a hotbar
	do jogador e vale **um uso**: clicar nela dispara o efeito e a carta some.

	As cartas são de partida, e não de deck: elas não passam pelo perfil, não
	sobrevivem ao round e não têm nada a ver com o `DeckConfig`. O que elas mexem
	é no estado da sala — os inimigos, o relógio e o céu —, e por isso **quem
	executa o efeito é o servidor** (`CardShopService`): daqui sai só a
	declaração de qual efeito a carta aciona e com que número.

	Este módulo é compartilhado porque as duas pontas precisam dele: o cliente lê
	título, descrição, preço e arte para desenhar a carta; o servidor lê o mesmo
	`Id` para saber o que a compra autoriza e o que o uso executa. Sorteio e
	cobrança acontecem **só no servidor** — o cliente nunca decide qual carta saiu
	nem se o dinheiro deu.
]]

local RoundCardConfig = {}

--[[ ONDE A LOJA MORA NA GUI ]]

--[[
	Os nomes autorados, num lugar só. O controller não procura nada por caminho
	escrito à mão: renomear uma peça no Studio é uma linha aqui.
]]
RoundCardConfig.Gui = {
	ScreenGui = "RoundCardShop",

	-- O botão que fica na beirada da tela, e o `ImageButton` dentro dele.
	Frame = "RCSFrame",
	Button = "CardShop",

	-- O escurecido de tela cheia e a fileira de cartas dentro dele.
	Background = "Background",
	Row = "RoundCardShop",

	-- O molde de uma carta: o wrapper é quem entra no `UIListLayout` da fileira,
	-- e o template é a carta em si (é ele que anima).
	Wrapper = "CardWrapper",
	Card = "CardTemplate",

	Title = "CardTitle",
	Description = "CardDescription",

	-- O preço mora numa placa própria, que sai da carta quando ela vai para a
	-- hotbar: no deck a carta já foi paga.
	Price = "PriceLabel",
	PriceLabel = "CardPrice",
}

--[[ QUANDO A LOJA APARECE ]]

--[[
	De quantas em quantas waves a loja é oferecida, por dificuldade.

	O número é o intervalo, não a wave: com 4, a loja aparece nas waves 4, 8, 12…
	Dificuldade mais longa espaça mais — o Nightmare tem 35 waves contra as 15 do
	Easy, e um intervalo fixo faria a partida do topo ter mais que o dobro de
	cartas da de baixo.

	Preset sem entrada cai no `DefaultInterval`.
]]
RoundCardConfig.Intervals = {
	Easy = 4,
	Medium = 4,
	Hard = 5,
	Impossible = 6,
	Nightmare = 6,
}

RoundCardConfig.DefaultInterval = 4

--- Quantas cartas a loja mostra por oferta.
RoundCardConfig.DrawCount = 3

--[[
	Os **parâmetros** do marcador de keyframe do `Visual` — não são nomes de
	marcador. A animação carrega um marcador só, o que estiver no `Visual.Marker` da
	carta, e o parâmetro dele diz qual metade do gesto dispara.

	Moram aqui porque as duas pontas precisam da mesma palavra: o cliente compara com
	o que o marcador entrega, e o servidor procura por `VFX` na animação quando vai
	conferir o `EffectDelay`.
]]
RoundCardConfig.Markers = {
	Sound = "Sound",
	VFX = "VFX",
}

--[[ ANIMAÇÃO ]]

--[[
	Os tempos da tela, em segundos reais.

	Nada aqui passa pelo `GameClock`: é tempo de o jogador ler e escolher, e não
	ritmo de partida. Acelerar o jogo para 2x não pode encurtar a leitura de três
	cartas.
]]
RoundCardConfig.Animation = {
	--[[
		O botão entra pela direita: nasce em `HiddenX` (fora da tela) e corre até o
		X que o designer deixou autorado no `RCSFrame`. O `Circular` é o pedido —
		ele chega devagar no fim, que é o que dá o encaixe na beirada.
	]]
	HiddenX = 1,
	SlideIn = 0.5,
	SlideOut = 0.35,
	SlideEasing = Enum.EasingStyle.Circular,

	--[[
		O balanço do botão, enquanto a oferta está de pé e ninguém clicou nele.

		Ele sobe `IdleLift` pixels e fica lá em cima gingando entre `+IdleSwing` e
		`-IdleSwing` graus, gastando `IdleSwingTime` em cada travessia. É chamariz: a
		oferta vale poucas waves e o botão mora na beirada da tela, onde é fácil não
		ver que ele chegou.

		O clique desliga o balanço e devolve o botão ao que está autorado no Studio em
		`IdleReturn` segundos. O alvo da volta é lido do `CardShop` no bind, e não
		escrito aqui: girar ou mover o botão no Studio não deixa ele torto depois da
		primeira loja.
	]]
	IdleSwing = 10,
	IdleSwingTime = 0.9,
	IdleLift = 6,
	IdleLiftTime = 0.35,
	IdleReturn = 0.2,
	IdleEasing = Enum.EasingStyle.Sine,

	-- O escurecido de tela cheia. O alvo é a transparência autorada do
	-- `Background`, e não um valor escrito aqui.
	BackgroundFade = 0.3,

	--[[
		A carta cai de cima: `DropOffset` é medido em alturas da própria carta,
		então mexer no tamanho dela no Studio não deixa a queda curta demais.

		São duas metades, nesta ordem: primeiro a carta desce e a **imagem** dela
		aparece (`CardDrop`); só quando isso termina é que o conteúdo — título,
		descrição, preço, contornos, sombra — sobe de transparente até o valor
		autorado (`CardReveal`). Revelar tudo junto faria o texto aparecer boiando
		antes da carta existir por trás dele.
	]]
	DropOffset = 1.25,
	CardDrop = 0.4,
	CardReveal = 0.3,

	--- O intervalo entre o começo de uma carta e o da seguinte.
	CardStagger = 0.5,

	--[[
		A saída sem compra: o clique fora das cartas toca a entrada ao contrário — o
		conteúdo some primeiro (`CardReveal`) e só então a carta sobe de volta com a
		imagem apagando (`CardDrop`).

		O escalonamento da saída é bem mais curto que o `CardStagger` da entrada
		porque aqui não há nada para ler: o jogador já decidiu que não quer nenhuma
		das três, e a oferta continua de pé no botão da beirada.
	]]
	CardExitStagger = 0.08,
	BackgroundFadeOut = 0.25,

	CardEasing = Enum.EasingStyle.Quad,
	CardDirection = Enum.EasingDirection.Out,
}

--[[
	O tamanho que o wrapper assume ao entrar na hotbar.

	É a única coisa que a carta de round precisa acertar na mão para conviver com
	as de unidade: o molde dela vem da loja, onde a carta é grande, e a vaga na
	hotbar é bem menor. Daí para a frente quem cuida dela é o `Components/Card` —
	posição, arco, escala e ordem da fila saem todas de lá, iguais às outras.
]]
RoundCardConfig.DeckCardSize = UDim2.fromScale(0.128, 1.07)

--[[ AS CARTAS ]]

--[[
	O catálogo.

	Cada entrada é uma carta que pode sair no sorteio:

	| Campo | O que é |
	| --- | --- |
	| `Id` | a chave, e é ela que trafega na rede — o resto é texto de tela |
	| `Title` / `Description` | o que o jogador lê na carta |
	| `Price` | quanto sai do caixa da partida (`roundcash`) |
	| `Weight` | o peso no sorteio; sem ele, 1 |
	| `Effect` | o nome do efeito no `CardShopService.Effects` |
	| `Params` | os números que o efeito lê |
	| `Image` | a arte da carta; sem ela, fica a autorada no `CardTemplate` |
	| `Visual` | o que o **personagem** faz ao usar a carta; sem ele, nada acontece |

	O `Visual` é uma animação e o que ela dispara:

	| Campo | O que é |
	| --- | --- |
	| `Animation` | o `AnimationId` que toca no personagem de quem usou |
	| `Marker` | o nome do marcador de keyframe que a animação carrega |
	| `Sound` | o `Sound` em `SoundService` que o marcador `"Sound"` toca |
	| `VFX` | o asset em `Assets.VFX` que o marcador `"VFX"` estoura |
	| `EffectDelay` | em que segundo da animação o **efeito** entra (o instante do marcador `"VFX"`) |

	**Quem manda no tempo é a animação, e não um `task.delay`.** O mesmo marcador
	dispara as duas coisas, e o que separa uma da outra é o **parâmetro** dele:
	`"Sound"` toca o som, `"VFX"` estoura as partículas. Reanimar a carta no Moon
	Animator remarca os dois sem passar por aqui — e é para isso que o marcador é um
	só com dois parâmetros, em vez de dois marcadores com nomes diferentes.

	O `EffectDelay` é a exceção, e é uma exceção necessária: **o efeito é do
	servidor**, e ele não escuta marcador de animação nenhum — a animação toca no
	cliente. O número aqui é uma cópia do instante do marcador `"VFX"`, e é assim que
	o congelamento cai junto com o estouro em vez de cair no clique. Cópia envelhece,
	então o `CardShopService` confere as duas contra a animação de verdade quando
	sobe e avisa se elas se afastarem.

	Carta nova é uma entrada aqui **mais** uma função no `CardShopService.Effects`
	com o nome que estiver em `Effect`. O sorteio só oferece o que tem efeito do
	outro lado: entrada com `Effect` que não existe é descartada com aviso, em vez
	de virar uma carta que o jogador paga e não faz nada.
]]
RoundCardConfig.Cards = {
	{
		Id = "TimeStop",
		Title = "TIME STOP",
		Description = "Freezes every enemy for 4 seconds",
		Price = 350,
		Weight = 1,
		Effect = "TimeStop",
		Params = { Duration = 4 },
		Visual = {
			Animation = "rbxassetid://76323247675563",
			Marker = "TimeStop",
			Sound = "TimeStopSFX",
			VFX = "PlayerStopTime",

			-- O marcador `VFX` está em 0,917s da animação (que dura 1,317s).
			EffectDelay = 0.917,
		},
	},

	{
		Id = "TimeAcceleration",
		Title = "TIME ACCELERATION",
		Description = "Game speed goes to 3x for 15 seconds",
		Price = 250,
		Weight = 1,
		Effect = "TimeAcceleration",
		Params = { Scale = 3, Duration = 15 },
	},

	{
		Id = "WeatherReport",
		Title = "WEATHER REPORT",
		Description = "Clears the weather for one full wave",
		Price = 300,
		Weight = 1,
		Effect = "WeatherReport",
		Params = { Waves = 1 },
	},
}

--[[ API ]]

local byId = {}
for _, card in RoundCardConfig.Cards do
	byId[card.Id] = card
end

--- A carta do `Id`, ou nil. O `Id` vem pela rede, então pode vir qualquer coisa.
function RoundCardConfig.Get(id : any)
	if typeof(id) ~= "string" then
		return nil
	end

	return byId[id]
end

--- De quantas em quantas waves a loja aparece nesta dificuldade.
function RoundCardConfig.GetInterval(difficultyName : string?) : number
	local interval = difficultyName and RoundCardConfig.Intervals[difficultyName]

	return interval or RoundCardConfig.DefaultInterval
end

--[=[
	Se esta wave é uma wave de loja.

	Múltiplo exato do intervalo. A wave 0 fica de fora de propósito: ela não é uma
	wave, é o intervalo antes da primeira.
]=]
function RoundCardConfig.IsShopWave(waveNumber : number?, difficultyName : string?) : boolean
	if typeof(waveNumber) ~= "number" or waveNumber < 1 then
		return false
	end

	return waveNumber % RoundCardConfig.GetInterval(difficultyName) == 0
end

--[=[
	Sorteia `count` cartas **sem repetir**, com peso.

	`pool` é a lista de cartas candidatas (o service passa só as que têm efeito
	registrado). O sorteio é sem reposição: a carta que sai é tirada da urna e os
	pesos das outras continuam valendo entre si, então uma carta rara não fica
	mais provável só porque a comum já saiu.

	Pool menor que `count` devolve a pool inteira embaralhada — três vagas com
	duas cartas no catálogo é melhor mostrar duas do que repetir uma.
]=]
function RoundCardConfig.Draw(count : number, pool : { any }?) : { any }
	local candidates = {}
	for _, card in (pool or RoundCardConfig.Cards) do
		table.insert(candidates, card)
	end

	local drawn = {}

	for _ = 1, math.min(count, #candidates) do
		local total = 0
		for _, card in candidates do
			total += math.max(0, card.Weight or 1)
		end

		if total <= 0 then
			break
		end

		local roll = math.random() * total
		local cursor = 0

		for index, card in candidates do
			cursor += math.max(0, card.Weight or 1)

			if roll <= cursor then
				table.insert(drawn, card)
				table.remove(candidates, index)
				break
			end
		end
	end

	return drawn
end

return RoundCardConfig
