# Game — "Periastron TD: Main Game"

Ver o [README da raiz](../README.md) para a arquitetura, o setup e o que é
compartilhado entre as duas places. Aqui fica só o que é exclusivo deste place.

## O que é só daqui

| Pasta | Vai para | Conteúdo |
|---|---|---|
| `src/ClientBoot/` | `StarterPlayerScripts.Client` | LocalScript de entrada |
| `src/Controllers/` | `Client.Controllers.Game` | Card, Difficulty, Loading, Mob, Music, Projectile, Ready, Targeting, Tripmine, UILibrary, UnitPlacement, VFX, Wave |
| `src/Services/` | `ServerScriptService.Services.Game` | Collision, Data, Difficulty, Map, Mob, Snow, Thunder, Unit, Wave, WeatherRound |
| `src/CmdrDefinitions/` | `ServerScriptService.CmdrDefinitions.*.Game` | comando `strike` e o tipo `unitName` |

O `Summon` no `ServerScriptService.Config` vem do compartilhado e não é usado aqui
— é pequeno e fica por consistência entre as places. O `Cmdr` do mesmo lugar **é**
usado: o console passou a rodar nas duas places junto com os comandos de Lighting
(ver o README da raiz). Este place traz o `strike` em `src/CmdrDefinitions/`, que
depende do `ThunderService` daqui — comando de service local não pode morar no
compartilhado, ou o Lobby travaria tentando resolver um service que não existe lá.

## Dependências Wally

| Pacote | Versão | Usado por |
|---|---|---|
| `evaera/promise` | 4.0.0 | vários services/controllers |
| `sleitnick/signal` | 2.0.1 | `DataService`, `DataController` |
| `1foreverhd/topbarplus` | 3.4.0 | Satchel |

Estavam instalados no place mas nenhum script requer, então foram movidos para
`ServerStorage._Backup_UnusedCode`: `Knit`, `Comm`, `Component`, `EnumList`,
`Input`, `Option`, `Streamable`, `TableUtil`, `Timer`, `Trove`.

## Fora do repo (fica só no place)

`ReplicatedStorage.Shared.Assets` (~6.500 instâncias: modelos, UI, VFX,
animações), `ServerStorage.Maps` (~25.900 instâncias, seis mapas) e as ScreenGuis
do `StarterGui`. São conteúdo binário, não código — por isso os nós do
`default.project.json` usam `$ignoreUnknownInstances: true`. `ServerStorage` nem
aparece no `default.project.json`: o Rojo só administra o que está declarado,
então a pasta de mapas fica intocada.

Os mapas ficam em `ServerStorage` de propósito — assim não replicam, e o cliente
só conhece o mapa que o `MapService` clonou para `workspace.Map`. Consequência
prática: `CollectionService:GetTagged("Grid")` no cliente devolve exatamente as
parts do caminho em jogo. No servidor, não: lá as 585 parts dos seis mapas
guardados também aparecem, e quem consulta a tag precisa filtrar por
`workspace.Map` (é o que `UnitService:getGridParts` faz).

## Onde pode colocar unidade (tag `Grid`)

As parts com a tag `Grid` são o caminho — trilhos finos (0,25 stud) deitados
sobre o chão do mapa. A regra é uma só: unidade não fica em cima do caminho. O
teste é o mesmo dos dois lados, e é o `Util/PlacementUtil.luau` que garante isso:

```lua
local probeCF, probeSize = PlacementUtil.PathProbe(cf, unitBounds)
-- caixa da unidade + PlacementUtil.PathClearance studs de coluna embaixo dela
```

O cliente usa essa caixa a cada 0,05 s para pintar o fantasma (verde/vermelho) e
o servidor usa a mesma no `PlaceUnit` para aceitar ou recusar — o servidor é a
autoridade, o cliente só evita que o jogador clique num lugar que vai ser negado.

A coluna embaixo (`PathClearance`, 4 studs — a altura do mob mais alto do jogo com
folga) existe por causa de uma brecha: testando só o volume da unidade, qualquer
coisa que a levantasse acima do trilho tirava o caminho de dentro da caixa. Mirar
na quina de uma pedra, num degrau de 25 cm ou na face lateral de um beiral que
paira sobre a trilha dava torre em cima do caminho, aprovada pelos dois lados.

### Personagem no caminho da unidade

Unidade também não nasce dentro de um jogador — nem de outro, nem de você mesmo.
Quem responde é `PlacementUtil.FindBlockingCharacter(cf, unitBounds)`, chamada
pelos dois lados como a do caminho: o cliente pinta o fantasma de vermelho, o
servidor recusa o `PlaceUnit`.

A caixa é a bounding box **cheia** da unidade — o fantasma é desenhado a 80% do
tamanho, mas quem vai ocupar o chão é a unidade inteira. Acessório não conta:
chapéu e asa saem metros fora do corpo e recusariam um lugar que, na tela, está
vazio.

Só personagem de jogador entra na conta. Mob e unidade já colocada também têm
`Humanoid`, mas a unidade já é barrada pela distância mínima entre torres, e o mob
não existe como modelo no servidor (quem clona é o `MobController`, no cliente) —
bloquear mob só no cliente deixaria o fantasma vermelho num lugar que o servidor
aceitaria, que é a divergência que o `PlacementUtil` existe para evitar.

Antes disso dava para empilhar torre em cima de qualquer personagem. O servidor
não olhava personagem nenhum, e no cliente a checagem de obstrução roda sobre a
`HumanoidRootPart` do fantasma (0,8 × 0,8 × 0,4, ainda escalada por 0,8) e ainda
pula a part que o raycast acertou — que, mirando num jogador, é justamente o corpo
dele. Essa checagem antiga continua onde está: é ela que impede o fantasma de
atravessar cenário, e a exceção do raycast é o que evita o chão bloquear tudo.

Duas coisas que **não** são checadas hoje, e valem como aviso:

- **Superfícies acima de 4 studs do caminho** (pontes, telhados, saliências de
  caverna) continuam aceitando unidade. É de propósito: são superfícies do mapa,
  e barrar todas tiraria área construível de verdade — no SnowyCastle, a maior
  parte dos telhados. Se a decisão for barrar, é trocar a coluna finita por um
  raio até o chão.
- **O CFrame vem do cliente.** O servidor confere caminho, personagem, distância
  entre unidades, dinheiro e carta, mas não confere se a unidade está apoiada em
  algo: mirar numa parede ainda deixa a unidade flutuando no ar ao lado dela.

O `raycastGroundY` do `UnitPlacementController` **não** filtra as parts de `Grid`:
elas são o piso visível da trilha. Ignorá-las fazia o raio atravessar o trilho e
parar no bloco de baixo, e uma unidade aceita no ar era desenhada de pé em cima do
caminho — longe do CFrame que o servidor guardou e usa para mirar. O encosta-no-
chão de `replicatePlacedUnit` também tem teto (`MAX_GROUND_SNAP`, 1 stud): ele
existe para corrigir os ~20 cm de diferença entre o fantasma (escala 0,8) e a
unidade de tamanho cheio, não para a unidade mudar de lugar sozinha.

## Card de upgrade (`StarterGui.Interface.CardUpgrade`)

O componente `UILibraryController/Components/ToggleTower.luau` preenche o card da
unidade selecionada. Cada TextLabel do StarterGui já traz o sufixo desenhado
(`DPS`, `COOLDOWN`, `RANGE`, `DMG DONE`) e o componente só troca o número:

| Label | Fonte |
|---|---|
| `Info.UnitName` / `Info.UnitLevel` | nome do modelo e atributo `Upgrades` |
| `UpgradeCost.TextLabel` | `UnitUpgradeConfig:GetCost`, ou `MAX` no último nível |
| `Sell.TextLabel` | `GetInvested` × `SharedConfig.SellRefundRatio` |
| `DamagePerSecond` | `GetDamage` (dano por golpe, com o clima); em unidade de farm, a renda por wave |
| `AttackSpeed` | `GetCooldown`, em segundos |
| `Range` | `GetRange` |
| `DmgDone` | atributo `DamageDone` do modelo |
| `ClassIcon` | `ClassConfig.GetIcon`, pela `Class` da unidade em `UnitStats` |

O nome `DamagePerSecond` é só o do label no StarterGui: ele mostra o **dano por
golpe**, e não DPS — quem quiser a conta por segundo tem o cooldown no próprio
card. `UnitUpgradeConfig:GetDPS` continua existindo, mas hoje nenhuma UI o usa.

O `ClassIcon` é a arte da classe da unidade (`Melee`, `Ranged`, `Magic`, `Fire`,
`Ice`, `Electric`). Os ids ficam em `ClassConfig.Icons`, no `SharedConfig` — a
classe em si continua sendo a de `UnitStats[nome].Class`, a mesma que o clima lê,
para a unidade não ter uma classe no card e outra na chuva. Unidade de dois tipos
mostra a **primeira** da lista (é uma casa só na tela), e unidade sem classe — o
`Azure`, que ainda não foi classificada — esconde o label em vez de mostrar um
quadrado vazio. Classe nova é uma linha em `ClassConfig.Icons` e outra em
`WeatherConfig.ClassList`.

Tudo menos o `DmgDone` sai do `UnitUpgradeConfig` — o cliente refaz a mesma conta
do servidor a partir do nível, então não precisa de replicação. O `DmgDone` só o
servidor sabe: `MobService:DamageMob` devolve o dano que de fato entrou no mob,
`UnitService:addDamageDone` acumula em `entry.damageDone` e um flush a cada 0,25 s
manda um lote `unitId -> total` (`UnitDamageStats`) para todos os jogadores —
qualquer um pode selecionar qualquer unidade. Quem entra no meio da partida recebe
o total de todas as unidades junto do `ClientReady`. No cliente, o
`UnitPlacementController` grava o valor no atributo `DamageDone` do modelo, e o
card reage pelo `GetAttributeChangedSignal`.

### Prévia do próximo nível

Dentro de `DamagePerSecond`, `AttackSpeed` e `Range` há um segundo TextLabel
(`DamagePerSecondUpgrade`, `CooldownUpgrade`, `RangeUpgrade`) que mostra o valor
que a unidade vai ter **depois do próximo upgrade** — o jogador vê o que o
dinheiro compra antes de gastar.

Os números saem dos mesmos getters do `UnitUpgradeConfig`, só que com `level + 1`
e com o clima do momento, então a prévia bate com o que o servidor vai usar em
combate. Em unidade de farm, a prévia do `DamagePerSecond` é a renda por wave do
próximo nível, igual ao label de cima.

Quando aparece:

| Aparelho | Comportamento |
|---|---|
| Mouse | só enquanto o ponteiro está sobre `UpgradeCost` (`MouseEnter`/`MouseLeave`) |
| Toque (`PointerUtil.isTouchOnly`) | sempre visível — no celular não existe "pairar por cima" |

No último nível as prévias somem nos dois casos: não há próximo valor para
mostrar, e o `UpgradeCost` ao lado já está escrito `MAX`. Elas nascem invisíveis
no StarterGui, e `destroy()` as apaga junto com o card, para que a próxima
unidade selecionada não abra mostrando os números da anterior.

### Botão de pulo no celular

Enquanto o card está aberto num aparelho de toque, o botão de pulo do Roblox sai
da tela (`ToggleTower:setJumpButtonHidden`) e volta quando o card termina de
sair. O card abre justamente por cima do canto onde o `TouchGui` desenha o
`JumpButton`: com os dois ali, o dedo que ia apertar `SELL` pula.

Só o botão sai — não é `controls:Disable()`, que levaria junto o direcional; o
jogador continua andando com o card aberto.

O `TouchGui` é do Roblox, não nosso: o módulo TouchJump reescreve `Visible`
sozinho (respawn, sentar, voltar a poder pular) e um respawn troca o botão por
outro. Por isso a escondida fica vigiada por `GetPropertyChangedSignal("Visible")`
mais um `PlayerGui.DescendantAdded`, e o que se devolve no fim é o último estado
que o TouchJump pediu — assim o card não acende um botão que o Roblox tinha
apagado de propósito.

### Botão `Priority` — prioridade de alvo

Um clique gira a prioridade da unidade selecionada na ordem do
`SharedConfig.TargetPriority`:

| Modo | Botão | Escolhe, dentro do alcance |
|---|---|---|
| `Closest` (padrão) | `CLOSEST` | o mob mais perto da unidade |
| `Farthest` | `FARTHEST` | o mob que mais avançou no caminho |
| `Weakest` | `WEAKEST` | o de menor vida atual |
| `Strongest` | `STRONGEST` | o de maior vida atual |

Distância desempata todos os modos — com dois mobs de vida igual no `WEAKEST`, a
unidade fica com o mais perto em vez de trocar de alvo a cada varredura.

#### `FARTHEST` mede o caminho, não a torre

"Mais longe" é do **começo do caminho**: ganha o mob que já andou mais, porque é
ele que está prestes a chegar na base. Antes valia a distância até a própria
unidade, e o alvo acabava sendo o mob na beirada do alcance — quase sempre um
recém-nascido, enquanto o que estava a um passo de sair pelo outro lado passava
batido.

O avanço de um mob é a distância do primeiro node até o node mais perto dele,
andando pelo caminho (`PathUtil.GetNodeProgress`). Distância pelo caminho e não
em linha reta: num mapa que volta perto do spawn, a linha reta diria que o mob
recuou.

A lista de nodes vem de `PathUtil.BuildNodeDistances`, montada sobre as rotas que
o `BuildRoutes` já expande — então subnode (pasta de trecho) e bifurcação entram
prontos, na ordem certa. Um node que aparece em várias rotas entra uma vez só,
com a menor distância entre elas, e é isso que deixa dois mobs em ramos
diferentes comparáveis.

Quem paga a conta:

| Lado | Onde | Posição medida |
|---|---|---|
| Servidor (decide o dano) | `MobService:GetBestMobInRange` | o ponto do caminho em `mob.Distance` |
| Cliente (gira a unidade) | `TargetingController:FindBestTarget` | o pivô do modelo menos o atributo `PathOffsetY` |

O `PathOffsetY` é a metade da altura do mob, gravada pelo `MobController` no
spawn. Sem descontar ela, o cliente mediria do centro do modelo e o servidor do
chão, e os dois escolheriam nodes diferentes perto da metade de cada trecho — a
torre olhando para um mob enquanto o dano vai para outro.

A varredura de nodes só roda no `FARTHEST` (`TargetPriority.UsesPathProgress`) e
o resultado fica em cache por mob por 0,1 s dos dois lados (`NODE_PROGRESS_REFRESH`):
ela é chamada por unidade **e** por mob, e numa wave cheia isso vira o produto dos
dois. Enquanto o caminho não chegou inteiro no cliente não há avanço nenhum, e o
critério cai na regra antiga — o mais distante da torre.

O caminho é o mesmo do upgrade e da venda: o botão manda `SetUnitPriority` com o
**modo de destino** (não "o próximo"), o `UnitService` confere dono e modo,
guarda em `entry.priority`, zera o alvo atual — senão a prioridade nova só valeria
quando o mob de agora saísse do alcance — e devolve `UnitPriorityChanged` para
todos (declarado com `Listen` vazio no topo do `construct` como todo evento
servidor→cliente — ver o README da raiz). O cliente grava no atributo
`TargetPriority` do modelo, e é dele que saem tanto o texto do botão quanto a
escolha do `TargetingController`. Ou seja: o botão nunca mostra uma prioridade que
o servidor não confirmou.

Quem decide o dano é o servidor (`MobService:GetBestMobInRange`); o
`TargetingController` do cliente só gira a unidade para o alvo. Os dois usam a
mesma comparação (`TargetPriority.IsBetter`) para não bater num mob olhando para
outro — a vida de cada mob o cliente lê do atributo `Health` que o `MobController`
mantém no modelo.

Em unidade de farm o botão sai da tela: ela não mira em ninguém. E o `[V]` do
mockup não está ligado — a troca é só por clique.

## Hotbar antes da partida (`StarterGui.Interface.TowerContainer`)

O `TowerContainer` fica escondido enquanto a partida não começou — servidor
esperando todo mundo carregar, votação de dificuldade aberta — e volta quando a
dificuldade é decidida. Quem manda nisso é o `DifficultyController`, o mesmo que
já cuida do `Clock`:

| Momento | Sinal | Hotbar |
|---|---|---|
| cliente carregou, round não começou | — (estado inicial do `construct`) | escondida |
| votação aberta | `DifficultySelection` com `locked = nil` | escondida |
| votação encerrada | `DifficultySelection` com `locked` / `DifficultyLocked` | visível |
| `ResetRound` (jogar de novo) | `DifficultySelection` com `locked = nil` | escondida |

`locked` é o campo do estado que diz se já há dificuldade escolhida — o `active`
não serve para isso, porque ele também é `false` no intervalo entre os rounds.

Quem entra no meio de um round já em andamento recebe o estado de uma vez só:
`DifficultyService:syncPlayer` espera a tag `ClientReady` (posta pelo
`DataService` quando o cliente dispara `Loaded`) e manda um `DifficultySelection`
para esse jogador. Sem isso a votação nunca falaria com ele — ela só transmite
enquanto está aberta — e a hotbar dele ficaria escondida a partida inteira.

Os atalhos `1`–`5` do `Components/Card.luau` seguem a mesma visibilidade: o
`InputBegan` sai fora quando o `TowerContainer` está invisível, para a hotbar
escondida não continuar equipando unidade por teclado.

## Recompensa de quem sai antes do fim

Sair no meio da partida — fechando o jogo ou porque o servidor está desligando —
paga a recompensa proporcional às waves sobrevividas. É a mesma
`WaveService:computeReward` do fim de round, então a conta é uma só: quem sai na
wave 18 de 20 leva quase tudo, quem sai na 2 leva quase nada, e wave 0 (votação
de dificuldade, intervalo) não paga nada.

Com o preset padrão (Medium, 20 waves):

| Saiu na wave | Coins | Shards | XP |
|---|---|---|---|
| 1 | 50 | 0 | 10 |
| 10 | 500 | 0 | 100 |
| 15 | 750 | 15 | 150 |
| 20 | 1000 | 60 | 200 |

Shards só entram depois do `SHARD_WAVE_THRESHOLD` (metade da partida) e daí
seguem a curva — a moeda cara continua concentrada em quem chega perto do fim.

### Por que o gancho fica no `DataService`

Quem chama o `WaveService:GrantLeaveReward` é o `DataService`, por
`OnBeforeRelease`, e não um `PlayerRemoving` do próprio `WaveService`. Dois
motivos:

- **Ordem.** Os dois services escutam `PlayerRemoving`, e a ordem entre eles não
  é garantida. Crédito escrito depois do `EndSession` vai para um perfil já
  fechado e se perde.
- **Desligamento.** No shutdown quem roda é o `BindToClose` do `DataService`, que
  chama `Destroy` para cada jogador; `PlayerRemoving` não é confiável ali.

Como todo caminho de saída passa pelo `Destroy`, o gancho cobre os dois casos de
uma vez. Cada callback roda em `pcall`: um erro ali não pode impedir a sessão de
fechar, senão o perfil fica preso e o jogador não entra em outro servidor.

### Pagar uma vez só

O `WaveService.PaidRewards` guarda quanto cada `UserId` já recebeu no round, e o
`grantReward` paga só a diferença. É o que faz a recompensa de saída conviver com
a de fim de round em dois casos:

- quem sai no instante exato do fim seria pago pelo `onRoundEnded` **e** pela
  saída;
- quem sai na wave 19 e volta para o mesmo round levaria as duas recompensas
  cheias.

Com o desconto, o total de quem entra e sai no meio nunca passa do que recebeu
quem ficou o round inteiro. O ledger zera no `StartRound` e no `ResetRound`.

## Bug conhecido (não corrigido)

`src/Controllers/UILibraryController/Components/Wave.luau` → `module:destroy()`
referencia `CardUpgrade`, que não existe nesse arquivo (é uma colagem do
`ToggleTower.luau`). Estoura se `destroy()` for chamado.

## Lixo no Workspace (não tocado)

28 modelos de inimigos/unidades soltos (Azuron x4, Rocketeer x3, Azure x2, sword,
slasher, slingshot, …, ~7.000 instâncias, sem tags) e as ScreenGuis vazias
`Cards` e `Upgrade`.
