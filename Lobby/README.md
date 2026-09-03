# Lobby

Ver o [README da raiz](../README.md) para a arquitetura, o setup e o que é
compartilhado entre as duas places. Aqui fica só o que é exclusivo deste place.

## O que é só daqui

| Pasta | Vai para | Conteúdo |
|---|---|---|
| `src/ClientBoot/` | `StarterPlayerScripts.Client` | LocalScript de entrada |
| `src/Controllers/` | `Client.Controllers.Lobby` | Cmdr, Crate, HUD, Shop, UILibrary |
| `src/Services/` | `ServerScriptService.Services.Lobby` | Cmdr, Crate, Data, Shop, Summoning, TeleportToGame |
| `src/CmdrDefinitions/` | `ServerScriptService.CmdrDefinitions` | Comandos e tipos do Cmdr |

## Dependências Wally

| Pacote | Versão | Usado por |
|---|---|---|
| `evaera/promise` | 4.0.0 | quase todos os services/controllers |
| `sleitnick/signal` | 2.0.1 | `DataService`, `DataController` |
| `1foreverhd/topbarplus` | 3.4.0 | Satchel |
| `evaera/cmdr` | 1.11.0 | `CmdrService`, `CmdrController` |

Estavam instalados no place mas nenhum script requer, então saíram: `Comm`,
`Component`, `EnumList`, `Input`, `Option`, `Streamable`, `TableUtil`, `Timer`,
`Trove`.

## Fora do repo (fica só no place)

| Item | Por quê |
|---|---|
| `ReplicatedStorage.Shared.Assets` | Models/Parts/Animations, não código |
| `StarterGui.HUD` / `StarterGui.crateui` / `StarterGui.ShopUI` | Instâncias de GUI — para versionar, exporte como `.rbxmx` |
| `ReplicatedStorage.CascadeRuntimeEngine` | Runtime pago do Cascade UI |
| `ReplicatedStorage.CascadeAnimations` | Animações salvas pelo plugin do Cascade (`OpenShop`, `ShopItemContainerShow`) |
| `StarterPlayerScripts.PlayerModule` | Código stock da Roblox |
| `StarterCharacterScripts.Animate` | Código stock da Roblox |
| `ServerStorage.Lunar_VFX_Scripts` | Readme de asset de terceiro |

⚠️ `ReplicatedStorage.Shared` tem um **PackageLink** (é um Roblox Package).
Sincronizar por cima marca o package como modificado no Studio.

## HUD: nível, XP, coins e shards

`HUDController` escreve `StarterGui.HUD.HUDMiddle` a partir da replica do perfil
(`Stats`): `Level`, `ExpAmount`, `CoinAmount.CoinAmountText` (é o `Stats.Cash`) e
`ShardAmount.ShardAmountText`. Escuta o `OnChange` da replica, então qualquer
escrita do servidor em `Stats` — a recompensa de fim de partida, uma compra na loja
— reflete na hora, sem evento próprio.

O **nível não é guardado no perfil**: sai do `Stats.XP` acumulado por
`SharedConfig.LevelConfig:Resolve(xp)`. Não existe perfil com nível e XP fora de
sincronia, e mexer na curva reavalia todo mundo sem migração. A curva é
`floor(BASE_XP * nível^CURVE)` (100 e 1.35), com `MAX_LEVEL = 50` — no máximo o
`ExpAmount` vira `MAX` e a barra fica cheia.

### A barra de XP

`ProgressBarContainer.EXPImage` não é uma barra, é um `ImageLabel` só que troca de
arte. `LevelConfig.BAR_IMAGES` tem uma imagem por faixa de 20% do progresso do nível
atual; progresso exatamente zero (perfil novo, ou logo depois de um level up) usa a
**barra vazia que veio autorada na GUI** — o id dela não está no config, é lido do
próprio `EXPImage` no primeiro bind, então trocar a arte vazia no Studio basta.

As seis imagens (as cinco do config + a vazia) são baixadas assim que o jogador
entra e ficam presas em memória por uma `ScreenGui` desligada, `HUDImageCache`, com
um `ImageLabel` por arte. O `PreloadAsync` sozinho só garante o download; o que
impede o descarte depois é ter uma instância viva apontando para cada uma. A
`ScreenGui` tem `ResetOnSpawn = false` de propósito: o HUD é recriado a cada
respawn (e por isso o bind roda de novo), o cache não.

### Os botões da coluna (Loja, Backpack, Deck)

`HUDButtonController` anima **todo `GuiButton` dentro do `HUDFrame`**, em qualquer
profundidade — hoje cada um mora dentro de um `Wrapper`, e um botão novo entra na
animação só de nascer ali (o `DescendantAdded` fica ligado porque a GUI replica em
pedaços).

| Evento | O que faz |
| --- | --- |
| `MouseEnter` | desliza a `Position` para `X.Scale = 0.3` (`Circular`, 0.28s) e toca `SharedSounds.SFX.UIHover` |
| `MouseLeave` | volta para a posição autorada, lida uma vez no bind |
| `MouseButton1Down` | encolhe o `UIScale` para 0.9 |
| `MouseButton1Up` | volta a escala (`Back`) e toca `SharedSounds.SFX.UIClick` |

Com `AnchorPoint` 0.5 dentro do wrapper (e `X.Scale = 0.5` em repouso), `X.Scale =
0.3` é um quinto da largura para fora da coluna; o Y e os offsets ficam como estão. O `MouseLeave` também solta a escala,
porque soltar o clique fora do botão não dispara o `MouseButton1Up` dele e a escala
ficaria presa no apertado.

Só o visual e o som moram ali. Quem **abre** cada painel continua sendo o controller
dele (`ShopController`, `CrateUIController`, `DeckController`), pelo `Activated` do
mesmo botão — por isso a animação de clique é `Down`/`Up`, que não consome o clique
de ninguém. Esses três procuram o botão pelo nome em qualquer profundidade do
`HUDFrame` (`UIUtil.waitForDescendant`), então mexer nos wrappers no Studio não
quebra o bind.

## leaderstats: Coins, Wins e Shards

O `LeaderstatsService` (`Lobby/src/Services`) põe as três colunas na lista de
jogadores, nesta ordem — a Roblox desenha na ordem em que os valores entram na
pasta. Nada é calculado ali: ele só copia `Data.Stats` para os `IntValue`.

| Coluna | Chave do perfil |
| --- | --- |
| Coins | `Stats.Cash` |
| Wins | `Stats.Wins` |
| Shards | `Stats.Shards` |

**Coins é `Cash`** porque o perfil chama de `Cash` e a tela chama de Coins desde
sempre (é o que o `HUDController` escreve na moeda do HUD) — a lista segue a tela,
não o nome da chave. Não é o dinheiro da partida, que é o `MobService.SessionCash` e
nem chega ao perfil.

**Como fica em dia, sem polling.** Toda escrita no perfil passa pelo
`DataService:Update` — o `Set` da replica só acontece lá dentro —, e ele agora
anuncia cada uma no sinal `DataUpdated` `(player, key, value)`. O service escuta esse
sinal (filtrando `Stats`) e o `PlayerDataLoaded`, então a coluna muda no mesmo
instante em que o perfil muda: uma compra na loja, um summon, o `cash` do Cmdr.

A pasta é parenteada ao `Player` **depois** de os três valores estarem dentro: a
lista começa a desenhar assim que ela aparece, e uma pasta vazia por um frame pisca
uma linha sem coluna nenhuma. Sem perfil aberto a pasta nem nasce, em vez de nascer
com três zeros que não são o que o jogador tem.

Só na Lobby, que foi onde pediram — as duas places têm o mesmo perfil, então o dia
em que a Game também quiser é mover o arquivo para `common/server/Services` (e levar
o `DataUpdated` para o `DataService` de lá, que hoje não tem).

## Painel de mapas: o mapa escolhido

A marca do mapa escolhido é o frame **`CheckMark`** que cada template
`ChooseMaps.Lobby.Scroll.Map` já traz autorado — o `ChooseMapsController` só liga e
desliga o `Visible` dele, e não desenha mais o anel que fazia antes. Template sem
`CheckMark` continua funcionando, só não tem o que acender. O card escolhido também
cresce um pouco (`UIScale`), que é efeito à parte e continua.

Enquanto o painel está aberto o resto da UI do lobby sai da tela — ver
[Quem some da tela, e quando](../README.md#quem-some-da-tela-e-quando) no README da
raiz.

## Deck: inventário, cartas equipadas e detalhe

`StarterGui.HUD.CardUI` é do `DeckController`, e o botão `HUDFrame.Deck` abre e
fecha (o mesmo botão com o painel aberto fecha). A abertura é um tween do `UIScale`
do `CardUI` de 0 até a escala que veio autorada — a escala é lida da GUI no bind,
antes de qualquer animação, então mexer nela no Studio basta.

### Uma carta por clique

O deck é contado em **cartas**, não em unidades. `EquippedUnits` é um array de
**slots** (`SharedConfig.DeckConfig`), um por `CardWrapper` do `EquippedCards`: cada
posição é `{ Unit = nome, Amount = quantidade }` ou `false` quando o slot está vazio.
O array é sempre denso (`MAX_SLOTS` posições), então ele sobrevive à ida e volta do
DataStore sem virar dicionário.

**O slot é fixo.** Tirar a última carta de uma unidade esvazia o slot dela e não mexe
em mais nada — quem está no slot 4 continua no slot 4, e a próxima unidade nova entra
no primeiro buraco, não no fim da fila. (O formato anterior era um array de nomes com
repetição, e o slot saía da ordem de primeira aparição; era isso que fazia a unidade
que acabava puxar todas as seguintes uma casa para trás. Perfil naquele formato
continua sendo lido: o `sanitize` converte, agrupando na ordem em que os nomes
aparecem — que é tudo o que ele dizia sobre slots.)

- clicar numa carta do **inventário** só **seleciona** — mostra os detalhes no
  `SelectionPanel`, e não mexe no deck;
- o **`EquipToggle`** é quem põe carta no deck, uma por clique, na unidade
  selecionada;
- clicar numa carta do **deck** tira uma.

**No PC, o botão direito na carta do inventário é o atalho:** ele seleciona e já
equipa uma carta, sem a ida ao `EquipToggle`. É o mesmo caminho de equipar — os
mesmos três tetos, o mesmo `ErrorLabel` quando um deles bate, a mesma carta voando
até o slot —, só que num clique em vez de dois. O gatilho é o `MouseButton2Click`
do botão da carta, que só existe para o botão direito de verdade: toque e gamepad
continuam com o clique normal, que é só seleção.

O `CardFlip` de `SoundService.SharedSounds.SFX` (pelo `MusicController:PlaySFX`) toca
quando uma carta **muda de lado**, nas duas direções — é o `_launchFlight` que o
dispara, junto com o clone. Selecionar não toca nada, porque nada se move.

O botão é só o `Equip`, no verde autorado, e é ele que equipa a segunda e a terceira
cópia da mesma unidade. Quando não sobra nenhuma — a unidade está inteira no deck —
ele fica **invisível**, porque não há mais o que equipar; desequipar é só pela carta
do deck. Não existe estado vermelho de desequipar no botão.

Três tetos, todos checados no cliente (para o aviso sair na hora) e de novo no
servidor (que é quem decide): as cópias que o jogador tem daquela unidade, o
`CardLimit` do perfil e os seis slots do `EquippedCards` (`DeckConfig.MAX_SLOTS`).
Recusa acende o `ErrorLabel` por alguns segundos — sem slot livre usa o texto
autorado, os outros dois casos têm texto próprio.

`CardsLimit` mostra `cartas/limite` (`7/15`). O limite mora no perfil
(`CardLimit`, começa em `DeckConfig.DEFAULT_CARD_LIMIT`) porque é para crescer com o
jogador; `DeckService:SetLimit` é o caminho para subir o teto, e ele limpa o deck em
seguida para um teto menor não deixar carta sobrando.

### A carta que voa

Toda troca é uma **cópia da carta clicada** que viaja por 0,8 s até o destino: do
inventário para o slot da unidade, ou do slot de volta para o inventário. O clone é
enfeite — os botões dele nascem `Interactable = false` e o `Count` é **destruído**,
porque o número da origem já nasce velho no instante em que o clone sai — e mora no
próprio `CardUI`, com `ZIndex` bem acima dos painéis, porque só de lá dá para cruzar
a lista com rolagem e o quadro do deck. Posição e tamanho viram escala do `CardUI`
(`_rectToScale`), então a viagem funciona em qualquer resolução. O nome também é
reescrito no clone: a origem pode ser um slot escondido, que só vai ser preenchido
quando a carta anterior pousar.

**O lado de onde a carta saiu muda na hora; o lado onde ela vai cair espera o
pouso.** Clicar numa carta do inventário desconta a linha dela na mesma hora (e some
com ela, se era a última cópia), e o slot só troca `EmptyCard` por `Card` quando a
carta chega — junto com o `Count` e o `CardsLimit`, que andam com o deck. Clicar numa
carta equipada é o contrário: o slot e o contador caem na hora, e a linha do
inventário só volta no pouso. A troca em si já está gravada no perfil desde o clique
— a viagem é só a forma de mostrar isso.

Os dois lados são desenhados separadamente (`_renderInventory` e `_renderSlots`,
cada um com o seu maid), e **o que espera é a carta, não o painel**: com uma indo
para o deck e outra voltando para o inventário ao mesmo tempo, cada uma segura só o
próprio slot ou a própria linha, e todo o resto continua respondendo. Quem faz isso
são o `_landedDeck` (o `Projected` sem os equipares que ainda estão no ar, para o
slot só mudar quando a carta dele chegar) e o `_landedTally` (as cartas equipadas
mais as que ainda estão voltando, que só saem da conta do inventário quando pousam).

A linha escondida do inventário é saída normal do render: unidade sem cópia sobrando
mas com carta voltando ganha o wrapper mesmo assim, com a `Card` invisível, e é isso
que abre o buraco na grade onde ela vai pousar. O `_inventoryTarget` só cede um frame
antes de medir, porque o `UIGridLayout` posiciona o wrapper novo no fim do frame.

**Clicar em rajada vale**: cada clique solta mais uma carta, e várias viajam ao mesmo
tempo. Quem decide se o clique vale não é a tela — que está sempre um pouco atrás de
propósito —, e sim o **`Projected`**: o deck contando o que ainda está no ar, ou
seja, o que o servidor já gravou. É dele que sai o slot de destino — o slot da
unidade, se ela já estiver no deck, ou o primeiro livre — e é contra ele que os três
tetos são checados. Sem carta no ar, `Projected` é
ressincronizado com o perfil; uma recusa do servidor desfaz só aquele clique e faz a
carta correspondente sumir no meio do caminho.

Desequipar uma unidade que estava com **todas** as cópias no deck não tem carta de
destino, porque unidade sem cópia sobrando some do inventário. Nesse caso a linha de
destino nasce escondida e já na posição ordenada (o `LayoutOrder` é carimbado pela
ordem da lista a cada redesenho), a grade abre o buraco, e a carta aparece no pouso. O `_ensureInventoryCard` cede um frame de propósito: o `UIGridLayout` só
posiciona o wrapper novo no fim do frame, e sem esperar a carta voaria para onde ele
*estava*.

### A arte da carta é por unidade

A `Card` (do inventário, do slot e do painel de detalhe) é um **ImageLabel**, e a arte
dela é a carta inteira — moldura, ilustração e fundo numa imagem só. Trocar de unidade
é trocar a imagem, e os ids ficam em `SharedConfig.CardConfig`, os mesmos que a hotbar
do Game usa: uma unidade tem uma carta, e as duas places a desenham igual.

Quem escreve é o `writeCardImage`, chamado de três lugares — o `writeCardName` (que
cobre o inventário e os slots de uma vez, já que é ele quem diz de que unidade a carta
é), o `_dressClone` e o painel de detalhe. O clone que voa precisa da escrita própria
pelo mesmo motivo que já precisava do nome: a origem pode estar escondida e ainda
mostrando outra unidade — é o caso do slot que só vai ser preenchido quando a carta
anterior pousar.

Unidade sem id fica com a arte que a GUI trouxe autorada, que hoje é a do Slasher:
carta com a arte errada é melhor do que carta em branco no meio do inventário. Faltam
`Slingshot` e `Subspace Tripminer`, e é uma linha por unidade no config. O
`EmptyCard` do slot livre tem arte própria e não passa por aqui.

### O resto do painel

**O inventário** (`CardUI.Inventory.ScrollingFrame`) tem uma carta por unidade com
cópia sobrando (posse menos equipadas), ordenada da raridade mais alta para a mais
baixa e alfabética dentro da faixa. O `CardWrapper` autorado é o **molde** e some no
bind. Unidade que não existe mais no `UnitStats` fica de fora, com um aviso uma vez
só.

Quando uma linha sai da lista (a unidade acabou), as linhas seguintes **não pulam**
para a célula nova: o wrapper vai instantâneo, como o `UIGridLayout` manda, e a
`Card` de dentro é deslocada pela diferença entre as duas células — de modo a
continuar exatamente onde estava na tela — e volta ao repouso animando
(`_slideCard`). A diferença sai da conta da grade (`_cellOffset`: célula +
espaçamento, preenchendo na horizontal), e não de `AbsolutePosition`: logo depois de
mexer no `LayoutOrder` o valor absoluto ainda é o velho, e esperar um frame para lê-lo
faria a carta piscar na posição nova antes de voltar para animar. A conta vale para a
grade alinhada no topo à esquerda, que é como ela está montada.

A lista é atualizada **no lugar**, nunca refeita: cada linha tem o próprio maid, e o
redesenho só cria a linha que passou a existir, apaga a que não tem mais o que
mostrar e reescreve o contador das que ficam — nome, cor da raridade e conexão do
botão são escritos uma vez, quando a linha nasce. Recriar todos os wrappers a cada
redesenho fazia o inventário **piscar a cada pouso**, porque as cartas eram
destruídas e clonadas de novo e o `AutomaticCanvasSize` da rolagem recalculava junto.
Carta escondida não recebe entrada, então a linha que está só guardando o lugar de um
pouso pode ficar com o clique ligado.

**A animação de abertura** anima a `Card` **dentro** do wrapper, e não o wrapper: quem
coloca o wrapper no lugar é o `UIGridLayout`, e mexer nele brigaria com a grade. Toda
carta sai de `Position = (0, 0)` (o canto do próprio wrapper) com **todos os
descendentes em transparência 1** e cai na posição autorada, devolvendo a
transparência que cada objeto tinha antes do runtime — o alvo do fade é lido do
próprio objeto no bind/clone, então contorno que veio meio apagado volta meio
apagado. Entram escalonadas, com teto de atraso, e o atraso vai no `TweenInfo` em vez
de um `task.delay`. Só na **abertura**: redesenhar com o painel aberto põe as cartas
prontas no lugar.

**Os seis slots** (`CardUI.EquippedCards`) mostram a `Card` quando ocupados e a
`EmptyCard` quando livres. A `EmptyCard` copia a `Rotation` da `Card` do mesmo slot no
bind, então a inclinação que o designer escolher (-4 ou 4) vale para as duas.

**O painel de detalhe** (`SelectionPanel.Container`) só fica visível com uma carta
selecionada — clicar em qualquer carta seleciona (e equipa/desequipa junto). Os
números são os da unidade **sem upgrade e sem clima** (no lobby não existe nem um nem
outro) e usam o mesmo formato do card de upgrade do Game: `X DMG` (ou `$X INCOME`
para Farm), `X.XX COOLDOWN`, `X RANGE`, mais o `ClassIcon` do `ClassConfig`. O
contorno do nome leva a cor da raridade.

`DeckConfig.sanitize` limpa a lista toda vez que alguém a lê: unidade que sumiu do
`UnitStats`, cópia além do que o jogador tem, unidade além do sexto slot e carta além
do `CardLimit` não entram. É o que impede um perfil velho de ficar com uma carta
fantasma equipada para sempre.

O deck vale na partida: o Game monta a hotbar e as contagens de carta a partir de
`EquippedUnits` — ver [A hotbar é o deck montado no
lobby](../Game/README.md#a-hotbar-é-o-deck-montado-no-lobby). Quem nunca montou o seu
joga com um deck automático (`DeckConfig.autoDeck`), que não é gravado.

## As caixas têm nome próprio

Três das quatro caixas foram renomeadas, e o nome novo vale em todo lugar:

| Tier | Era | É |
| --- | --- | --- |
| `Common` | Common Crate | **Crate Of Beginnings** |
| `Rare` | Rare Crate | **Crate Of Nature** |
| `Epic` | Epic Crate | **Fragmented Crate** |
| `Legendary` | Legendary Crate | Legendary Crate |

**A chave da tabela é o tier, e o nome é da caixa** — os dois deixaram de se
parecer, e é de propósito. `CrateConfig.CRATES` continua indexado por
`Common`/`Rare`/`Epic`/`Legendary`, que é o que liga a caixa ao `RarityConfig`, ao
pool de drop e ao `Inventory.Crates` do perfil; mexer nisso pediria migração de
perfil. O que mudou é o `DisplayName` (o que o jogador lê) e o campo novo `Key`.

`Key` é o nome de código da caixa, e ele é **o mesmo em três lugares**: o modelo em
`Assets.CratesModel` que o unboxing gera, o container dela na `ShopUI` e o `Id` do
item no `ShopConfig`. Era só o nome do modelo (`Model`) e virou um campo próprio
quando a loja ganhou um container por caixa — são três coisas que precisam casar, e
um nome só garante que casem. `CrateConfig.getModelName` continua existindo e
devolve o `Key`, então o `UnboxingController` não mudou.

O ícone da backpack também sai do `CrateConfig` (`Image`), como sempre saiu: o
`CrateController` escreve ele no `crateimg` de cada `cratetemplate`. Trocar a arte
de uma caixa é uma linha lá.

## Loja: um container por caixa

A `ShopUI` mudou de dono do desenho. O painel agora é
`ShopUI.Frame.ImageLabel` (era `ShopUI.ImageLabel`), e dentro dele a
`ScrollingFrame` traz **um container autorado por caixa**, com o nome do `Key`:
`CrateOfBeginnings`, `CrateOfNature`, `FragmentedCrate`.

Antes existia um `ShopItemWrapper` autorado que o `ShopController` clonava uma vez
por item. Não serve mais: cada caixa tem ilustração, moldura e cor de linha
próprias, e clonar um template só daria três caixas com a cara da primeira. O
controller passou a **achar** o container pelo nome e escrever nele só o que muda:

```
CrateOfBeginnings          <- item.Container, que é o Key da caixa
├── BoxArt
│   └── TextLabel          <- o DisplayName, em maiúsculas
├── Frame
│   ├── Rarity             <- TEMPLATE daquela caixa (clonado, uma vez por raridade)
│   │   └── RarityTextPercentage
│   └── UIListLayout
└── Buy
    ├── UIScale            <- o hover e o aperto do botão
    ├── TextLabel          <- o Price pelo ShopConfig.PRICE_FORMAT: `50`
    │   └── UIStroke       <- a cor da moeda daquela caixa
    └── ImageLabel         <- o ícone da moeda daquela caixa
        └── UIScale        <- o tamanho do ícone, que muda com a moeda
```

**A linha de raridade é um template por caixa, e não um template global.** A
`Rarity` autorada dentro de cada container é a arte *daquela* caixa — por isso há
uma em cada uma, e por isso elas são imagens diferentes. O bind tira a autorada da
tela (guardando um clone) e devolve uma linha por raridade que a caixa pode dropar,
ordenadas da mais comum em cima para a mais rara embaixo — a ordem é a do
`RarityConfig`, e não a da chance: na caixa lendária a Epic e a Legendary empatam em
40%, e ordenar por número poria as duas na frente da Rare.

**Caixa sem container não aparece**, com um aviso uma vez só. É o caso da Legendary
Crate hoje: ela continua no `ShopConfig`, no inventário, no drop e no unboxing, e o
dia em que um container `LegendaryCrate` for autorado ela volta à loja sem ninguém
mexer em código. O contrário também vale: container que não é de nenhum item fica
escondido, e não destruído — ele é trabalho de designer, e a loja não é dona dele.

### A loja cobra em duas moedas

As caixas deixaram de custar todas em shards:

| Caixa | Custa | Chave em `Data.Stats` |
| --- | ---: | --- |
| Crate Of Beginnings | 50 Coins | `Cash` |
| Crate Of Nature | 200 Coins | `Cash` |
| Fragmented Crate | 4 Shards | `Shards` |
| Legendary Crate | 1.800 Shards | `Shards` |

**A chave é o nome no perfil, e não o nome na tela.** O jogador lê "Coins" e o perfil
guarda `Cash` desde sempre (ver o `LeaderstatsService`) — por isso `ShopConfig.ITEMS`
escreve `Currency = "Cash"` e não `"Coins"`. Escrever a palavra da tela criaria um
`Stats.Coins` fantasma no dia em que o servidor cobrasse por ela. Moeda que
`ShopConfig.CURRENCIES` não conhece cai no padrão (`Shards`) com um aviso, e não vira
`stats[nil]` no servidor: um erro de digitação ali entregaria a caixa de graça.

**O servidor cobra da moeda do item, e devolve na mesma.** O `ShopService` lê
`item.Currency` e desconta dessa chave dentro do mesmo `:Update` que confere o saldo —
dois cliques seguidos não gastam o mesmo dinheiro duas vezes —, e um grant que falha
devolve exatamente o que tirou. A recusa por saldo passou a se chamar
`NotEnoughCurrency` (era `NotEnoughShards`), que é o mesmo vocabulário do
`SummoningService`.

**Na tela, quem traduz a moeda em cor e ícone é o `ShopController`**, na tabela
`CURRENCY_STYLE`:

| Moeda | Contorno do preço | Ícone |
| --- | --- | --- |
| Shards | azul `69,92,241` | `rbxassetid://84637851192567` |
| Coins (`Cash`) | âmbar `211,170,88` | `rbxassetid://94514377432201` |

Isso mora no controller e não no config porque é desenho: o config diz **de onde
cobrar** e a tela diz **com que cara**. E precisa existir porque os três containers
foram autorados quando a loja tinha uma moeda só — os três nascem com o azul e o
ícone da Shard, e sem o `styleBuyButton` a Crate Of Beginnings mostraria um preço em
Coins ao lado do ícone errado. Mudar um preço de moeda continua sendo uma linha no
`ShopConfig`, e nenhum toque em container.

### As chances são as de verdade, e vêm do servidor

As odds continuam sendo **só do servidor** (`ServerScriptService.Config.Crate`): o
cliente pede com `RequestCrateOdds` e recebe `CrateOdds`, um mapa
`{ [Id do item] = { [raridade] = % } }` já calculado. O que atravessa a rede é o
resultado da conta, e não a tabela que a produz.

E o número publicado é a chance **real**, com a evolução da caixa dentro
(`Crate.GetDisplayOdds`). As `POOLS` são a chance depois de a caixa parar de
evoluir, e não a chance de comprar aquela caixa e receber aquela raridade: uma
Crate Of Beginnings vira Crate Of Nature em 25% das aberturas (e dali pode
continuar), então o pool da comum só vale em 75% delas. A diferença não é detalhe:

| Caixa | Common | Rare | Epic | Legendary |
| --- | ---: | ---: | ---: | ---: |
| Crate Of Beginnings | 69,56% | 21,36% | 7,79% | **1,29%** (0,25% no pool cru) |
| Crate Of Nature | 38,25% | 40,45% | 16,89% | 4,41% |
| Fragmented Crate | — | 43% | 44,6% | 12,4% |
| Legendary Crate | — | 20% | 40% | 40% |

A lendária sai **cinco vezes** mais da caixa mais barata do que o pool cru sugere.
Mostrar o pool seria a loja prometer um número que o jogo não entrega, e por isso a
conta mora no config do servidor e não na tela.

Enquanto as odds não chegam, o container fica **sem linha nenhuma** — e não com o
número autorado. Placeholder de designer na tela do jogador é pior do que meio
segundo de espaço vazio.

**O contorno de cada linha é a cor da raridade dela.** O `UIStroke` autorado é o da
*caixa* (preto na Crate Of Nature, verde na Fragmented Crate) e não diz nada sobre a
raridade — as quatro linhas de uma caixa sairiam iguais. No render ele passa a ser a
cor do tier no `RarityConfig`, a mesma que pinta o carretel do unboxing e o nome da
carta no deck, então a linha se lê antes de o jogador chegar no texto:

| | Common | Rare | Epic | Legendary |
| --- | --- | --- | --- | --- |
| Contorno | azul `29,33,250` | verde `31,230,74` | magenta `227,19,255` | âmbar `255,191,51` |

Por cima vem um gradiente vertical de brilho. A divisão de trabalho é o que importa
ali: **o `Color` do `UIStroke` carrega a cor e o `UIGradient` carrega só a luz**, em
cinza (branco em cima, 0.45 embaixo). Como o gradiente multiplica a cor do contorno,
trocar uma raridade de cor continua sendo uma linha no `RarityConfig` e não quatro no
controller. É vertical porque a linha é um retângulo largo e baixo — na horizontal o
gradiente acenderia uma ponta do texto e apagaria a outra.

Quando o template já traz um `UIGradient` autorado (o da Crate Of Beginnings traz), é
ele que é reescrito em vez de um segundo ser criado ao lado: dois `UIGradient` no
mesmo `UIStroke` é a Roblox escolhendo um deles por ordem de árvore.

### Abrir a loja limpa a tela e borra o fundo

Enquanto a loja está aberta ela é a única coisa na frente: o HUD, o botão do portal e
o que mais a lobby tiver saem, e o fundo entra em `BlurSize` 24. Fechar desfaz os dois.

**Quem esconde é o `InterfaceController`**, com um pedido com nome — não é
`Enabled = false` na mão em cada GUI:

```lua
InterfaceController:Hide("Shop", { Except = { "ShopUI" } })
InterfaceController:Show("Shop")
```

É o mesmo mecanismo do painel de mapas e da cutscene (ver [Quem some da tela, e
quando](../README.md#quem-some-da-tela-e-quando)), e é o que faz os pedidos se
sobreporem sem brigar: cada GUI volta ao que o **dono dela** queria quando o último
pedido sai, e não a um valor que a loja tenha chutado. `ScreenGui` marcada com
`IgnoreInterfaceHide` continua de pé — é o flash do portal.

A própria `ShopUI` liga pelo `InterfaceController:SetEnabled`, e não no `Enabled`
direto. O aviso de `Enabled` chega no fim do quadro, e a loja acende no **mesmo**
instante em que o pedido varre as GUIs: escrevendo direto, o pedido ainda leria o
`false` de antes como "o que o dono queria" e apagaria o painel de volta no mesmo
quadro. Todo o liga/desliga da loja passa por um único `_setShopEnabled` por isso.

A tela é devolvida no **começo** do fechamento, e não no fim: o resto da UI e o fundo
voltam atrás do painel, em vez de aparecerem de uma vez depois que ele sai. E o
`_bindUI` devolve também — a `ShopUI` é `ResetOnSpawn`, então morrer com a loja aberta
traz uma cópia nova e zera o estado; sem isso o pedido ficaria de pé com a loja
fechada, e o jogador renasceria sem HUD e com o fundo borrado.

**O blur é o `Lighting.UIBlur`**, o mesmo que o `UILibraryController` já usa nos
painéis dele — dois `BlurEffect` somariam, e o fundo sairia com o dobro do borrão com
os dois abertos. Quem chegar primeiro cria; quem chegar depois acha pelo nome.

Ele nasce com `LightingKeep = true`. Sem essa marca ele é um filho do `Lighting` que
não pertence a preset nenhum: o `LightingService` o varreria na troca de preset, e o
`LightingController` o trataria como efeito de saída — um fantasma dele por cima do
borrão que a loja está usando. O `LightingController` passou a pular esses filhos na
leitura do estado, que é a metade do contrato que faltava (o servidor já pulava).

O tempo do tween sai da própria `OpenShop` (`track.Duration`, 0,25s hoje), então o
borrão entra e sai junto com o painel mesmo que a animação seja re-cronometrada. Um
tween por vez, num maid próprio: fechar no meio da abertura cancela a subida e desce
de onde ela chegou, em vez de duas animações escreverem no mesmo `Size`.

### O botão de compra responde ao ponteiro e ao dedo

O `Buy` cresce para `1.05` com o ponteiro em cima e afunda para `0.93` enquanto está
apertado, no `UIScale` autorado dentro dele. O tempo e a curva são os mesmos dos
botões da HUD (`HUDButtonController`): entrada circular, volta num `Back` que passa um
pouco do ponto — é o que faz o botão parecer que tem peso em vez de só mudar de
tamanho. O aperto é mais suave que o `0.9` da HUD porque lá o botão é um ícone
quadrado e pequeno, e aqui é uma barra larga: o mesmo fator moveria as duas bordas
muito mais longe, e a barra pareceria saltar em vez de afundar.

**O alvo sai do estado inteiro, e não do evento que acabou de chegar** — apertado
vence pousado, que vence parado. Sem isso, soltar o clique com o mouse ainda em cima
devolveria o botão ao tamanho normal em vez do de hover, e a saída seguinte do mouse
não teria nada para desfazer.

O aperto e o soltar são `InputBegan`/`InputEnded` filtrando `MouseButton1` **e**
`Touch`, e não `MouseButton1Down`/`Up`: o mesmo par cobre o clique e o toque, e nenhum
dos dois consome o input, então o `Activated` que faz a compra continua saindo. Duas
coisas que o par sozinho não cobre:

- **Soltar fora do botão.** Arrastar para fora e soltar lá não dispara o `InputEnded`
  dele, e a escala ficaria presa no apertado — por isso o `MouseLeave` também desfaz o
  aperto. É o mesmo cuidado que o `HUDButtonController` toma.
- **Toque não tem hover.** A Roblox manda `MouseEnter` no toque como se fosse mouse,
  então soltar o dedo devolveria o botão ao tamanho de hover por um quadro antes de o
  `MouseLeave` chegar. Um toque que termina limpa os dois estados de uma vez.

Tudo vai no `ItemMaid`, junto do resto do bind do container: um `_render` novo
desconecta os eventos e cancela o tween que estiver no meio, e a escala volta a `1` no
bind seguinte — um painel que fechou com o mouse em cima não reabre com o botão
grande.

### O som da compra é um por moeda

`SoundService.BuySFX` virou uma **pasta**, com um som para cada moeda:

```
SoundService
├── SharedSounds        <- o Package, que as duas places carregam
└── BuySFX              <- solto ao lado dele, só do Lobby
    ├── Coins
    └── Shards
```

Qualquer um dos dois toca no **resultado** que o servidor manda, e não no clique: o
preço, a moeda e a carteira são conferidos lá, e um clique sem saldo não comprou nada.
Qual dos dois toca sai do `ShopConfig` (`BUY_SOUNDS`, no `ShopController`), e não da
rede: o resultado carrega o id do item, e o preço daquele id é público — mandar a
moeda junto só daria ao cliente uma segunda versão de uma coisa que ele já sabe. A
chave é a moeda do perfil e o valor é o nome do `Sound`, que é o nome da tela: a pasta
traz `Coins`, e não `Cash`.

**Toda compra toca do começo.** As duas moedas dividem uma `Key` (`ShopBuy`), e o
`PlaySFX` para e destrói o que estiver tocando nela antes de soltar o clone novo:
comprar de novo no meio do som corta e recomeça, em vez de somar uma segunda cópia por
cima da primeira. Sem `Key` os clones se empilhariam, e a terceira compra seguida sairia
como um borrão em vez de três confirmações.

**Isso não é debounce.** Nada é engolido: toda resposta do servidor tem o seu som, e o
corte é a favor do jogador — o que ele ouve é sempre a compra que ele acabou de fazer.
Sem fade, o clone toca no mesmo quadro em que a resposta chega. E o som é a **primeira**
coisa que acontece com ela: o sinal `PurchaseResult` sai depois, porque quem escuta pode
fazer qualquer coisa e nada disso pode entrar na frente do som.

O que ainda podia atrasar era o **download do áudio no primeiro clique**:
`Sound:Play()` num asset que não chegou não falha, ele espera — e num som que confirma
uma ação essa espera é a resposta inteira. Por isso o `ShopController` chama
`MusicController:PreloadSFX` no `construct`, com os dois nomes de `BUY_SOUNDS`. O
preload roda em thread própria (o `PreloadAsync` cede) e falhar nele não impede o som
de tocar mais tarde — é otimização, não pré-requisito.

O que sobra de atraso é o caminho de rede, e ele é de propósito: o preço e a carteira
são conferidos no servidor, então tocar no clique seria tocar antes de saber se a
compra aconteceu.

Eles moram **soltos na raiz do `SoundService`**, e não dentro do Package
`SharedSounds` — é um efeito só do Lobby, e não vale uma mudança de package que as
duas places carregam. Para eles serem achados, o `MusicController` lê a raiz em **dois
níveis** (`_findLoose`): um `Sound` solto, ou um `Sound` dentro de uma pasta solta.
Antes era só o primeiro nível, e uma pasta chamada `BuySFX` deixaria o efeito mudo —
`PlaySFX("BuySFX")` acharia uma `Folder`, que não é um `Sound`.

**A varredura pula o `SharedSounds`**, e é aí que ela para de ser recursiva: entrar no
Package reencontraria o que a busca na pasta (`SharedSounds.SFX`, que vem primeiro) já
cobre, e um nome repetido nas duas pontas passaria a depender da ordem da árvore.
Entre os soltos vale a mesma regra que já vale dentro do Package: o nome tem que ser
único.

Isso não abre exceção à regra de que nada lê o `SoundService` direto: quem lê a raiz
continua sendo só o `MusicController`, e quem toca continua pedindo pelo nome
(`Sound:PlaySFX("Coins")`).

### O que saiu junto

A animação de item (`ShopItemContainerShow`) saiu com o template. Ela movia
`Position.X.Scale`, e os containers de hoje estão sob um `UIListLayout`, que é quem
manda na posição deles — a faixa não teria efeito nenhum. A `OpenShop` do painel
continua, e o controller **cria o `UIScale`** que ela precisa quando o painel não
traz um autorado (o novo não traz), senão a loja apareceria só por fade, sem
crescer.

**O X mora no `Frame` de fora, e não no painel** — por isso ele é procurado a partir
do wrapper e em profundidade. Buscar só dentro do `ImageLabel` deixaria o botão mudo;
buscar na ScreenGui inteira alcançaria o `Close` do painel antigo, que é irmão dele e
continua na árvore. Fechar na mão não briga com a proximidade: o `_updateProximity`
só age na **travessia**, então o painel não volta no tick seguinte só porque o jogador
continua parado ali — ele volta quando o jogador sair do raio e entrar de novo.

O contador de shards continua **opcional**: o painel novo ainda não tem um, e a loja
não depende dele. Ele é procurado dentro do painel primeiro e só depois na ScreenGui
inteira — o painel antigo (`ShopUI.ImageLabel`, escondido) ainda tem um
`CurrentShards` e vem antes na árvore, então sem essa ordem um contador novo autorado
no painel de hoje perderia para o velho.

## Achado

`Shared.Classes.Unit` chama `Framework:Get("ProjectileController")` e
`Framework:Get("VFXController")`, que não existem neste place — retornam `nil`.
(Existem no Game.)
