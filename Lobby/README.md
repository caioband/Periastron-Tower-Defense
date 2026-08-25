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

## Achado

`Shared.Classes.Unit` chama `Framework:Get("ProjectileController")` e
`Framework:Get("VFXController")`, que não existem neste place — retornam `nil`.
(Existem no Game.)
