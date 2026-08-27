# Game — "Periastron TD: Main Game"

Ver o [README da raiz](../README.md) para a arquitetura, o setup e o que é
compartilhado entre as duas places. Aqui fica só o que é exclusivo deste place.

## O que é só daqui

| Pasta | Vai para | Conteúdo |
|---|---|---|
| `src/ClientBoot/` | `StarterPlayerScripts.Client` | LocalScript de entrada |
| `src/Controllers/` | `Client.Controllers.Game` | Card, Difficulty, Loading, Mob, Music, Projectile, Ready, SkipPrompt, Targeting, Tripmine, UILibrary, UnitPlacement, VFX, Wave |
| `src/Services/` | `ServerScriptService.Services.Game` | Collision, Data, Difficulty, Map, Mob, Skip, Snow, Thunder, Unit, Wave, WeatherRound |
| `src/CmdrDefinitions/` | `ServerScriptService.CmdrDefinitions.*.Game` | comandos `strike` e `roundcash`, e o tipo `unitName` |

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

## A vida da base no mapa (`BaseHP`)

Cada pasta de mapa em `ServerStorage.Maps` traz na raiz — irmã do `Content`, como a
`BoundingBox` — uma Part **`BaseHP`**: invisível, ancorada e inerte, com um
`BillboardGui` dentro cujo `TextLabel` **`Value`** é onde o número da vida da base
aparece. Os dois nomes estão no `SharedConfig.MapConfig`
(`BASE_HEALTH_PART` / `BASE_HEALTH_LABEL`), porque servidor e cliente precisam do
mesmo.

O `MapService:LoadMap` clona a Part para dentro de `workspace.Map` junto com o resto
do mapa. Sem esse clone o cliente nem saberia que ela existe — mapa mora em
`ServerStorage` e não replica. O clone é forçado a `Anchored` e a
`CanCollide`/`CanQuery`/`CanTouch` desligados: Part solta cairia do mundo levando o
billboard junto, e `CanQuery` ligado a poria no raycast que valida o posicionamento
de unidade, que varre justamente o que está em cima do mapa. A aparência fica a que
veio autorada.

Quem escreve o número é o **`BaseHealthController`**, no cliente, a cada
`UpdateBaseHealth` — o mesmo evento que o `MobController` usa para tremer a tela
quando um inimigo escapa. O controller acha o label procurando um `TextLabel` com o
nome do config entre os descendentes da Part, e caindo no primeiro `TextLabel` que
houver: reorganizar o `Frame` dentro do billboard no Studio não apaga o número.
Como a Part replica antes dos filhos dela, a procura é repetida por alguns quadros
até o billboard chegar.

O `UpdateBaseHealth` só é disparado quando a vida **muda**, e o mapa chega ao cliente
muito antes do primeiro vazamento. Por isso, assim que acha o label, o controller
pede o valor de agora com **`RequestBaseHealth`** (mesmo padrão do `RequestCash`) —
sem esse pedido o billboard ficaria no texto que veio autorado na GUI até um inimigo
passar.

A vida em si continua sendo só do servidor: quem tira é o `MobService:mobEscaped`, no
valor de `MobDamage` da dificuldade, e o teto é o `BaseHealth` dela
(`common/server/Config/Difficulty.luau`).

## Prêmio por wave concluída

Toda wave que termina paga caixa a **todos os jogadores da partida**, e é o único
dinheiro do jogo que não depende do que o jogador fez — não é por dano, nem por
morte, nem de farm. É por a wave ter acabado, então sai igual para todo mundo,
inclusive para quem entrou no meio da partida.

O prêmio é **acumulativo**: cada faixa do `Config.Wave.CASH_TIERS` diz quanto uma
wave soma sobre a anterior, e o valor da wave N é a soma dos passos de todas as waves
até ela.

```lua
Wave.CASH_TIERS = {
    { UpTo = 10, Step = 25 },
    { Step = 50 },
}
```

| Wave | 1 | 2 | 3 | … | 10 | 11 | 12 | … | 25 | 30 | 35 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Prêmio | 25 | 50 | 75 | | 250 | 300 | 350 | | 1.000 | 1.250 | 1.500 |

A última faixa não tem `UpTo` e vale dali em diante — isso importa porque `MaxWaves`
varia por dificuldade e o Nightmare vai até a wave 35.

Quem paga é `WaveService:payWaveCash`, chamado no `runRound` **depois** da checagem de
game over (wave perdida não paga) e **antes** da checagem de vitória (a última wave é
uma wave concluída como as outras).

O valor é fixo: não passa pelo `RewardMultiplier` do preset, ao contrário da caixa por
morte. Uma wave paga o mesmo no Fácil e no Nightmare — o que muda entre presets é só
quantas waves existem.

### O que isso faz com a economia

O `Config.Wave` documenta que as recompensas por morte foram calibradas para o Difícil
render **cerca de 9.000 de caixa** ao longo das 25 waves. O prêmio por wave sozinho
soma **11.125** no mesmo trajeto — ou seja, ele mais que dobra a economia da partida,
e é agora a maior fonte de renda do jogo.

| Preset | Waves | Prêmio somado |
|---|---|---|
| Fácil | 15 | 3.375 |
| Normal | 20 | 6.625 |
| Difícil | 25 | 11.125 |
| Insano | 30 | 16.875 |
| Nightmare | 35 | 23.875 |

Mexer nisso é mexer em `CASH_TIERS`, num lugar só.

## Entrepreneur: a farm com aura

O Entrepreneur continua sendo a farm — não ataca, e paga `Farm.Income` **ao dono** no
fim de cada wave. O que ele ganhou foi uma **aura**: toda unidade aliada dentro do
alcance dele leva uma % a mais de caixa em cima do que ela ganhar **por dano e por
morte**. Vale para qualquer dono (a torre do vizinho também rende mais perto da minha
farm), e quem recebe o bônus é o dono *daquela torre*, não o dono da farm.

### O raio é o `Range`, e não um número à parte

O alcance da aura é o `Range` do Entrepreneur lido pelo `UnitUpgradeConfig:GetRange`
— exatamente o mesmo círculo que o jogador vê ao selecionar a farm, clima incluído.
Não existe um `Radius` separado no config de propósito: com dois números, um
inevitavelmente mentiria sobre o outro. Para abrir ou fechar a aura, muda-se o
`Range` em `UnitStats` e o círculo acompanha.

Só a porcentagem mora no config, em `UnitStats.Entrepreneur.Farm.Aura`:

```lua
Aura = { Bonus = 0.15 },   -- +15%
```

`Bonus` é fração somável, e **auras que se sobrepõem somam**: duas farms cobrindo a
mesma torre valem 30%. `BonusPerUpgrade` é quanto cada nível soma — somado, e não
multiplicado como a renda, porque porcentagem em passo redondo (15, 20, 25…) é o que
o card mostra sem casa decimal.

A conta mora em `UnitUpgradeConfig:GetAuraBonus(unitName, level)`, e é ela que o
servidor e o card leem — os dois nunca discordam sobre quanto a aura vale.

Ela é o único getter do `UnitUpgradeConfig` que **não** aceita `weather`. O bônus é
economia, e economia não anda com o clima: é a mesma regra do `Farm.Income`, que o
`payFarmUnits` paga sem clima justamente para a seca não virar bônus de caixa. O
*raio* continua vindo do `GetRange`, esse sim com clima, porque é o círculo desenhado
no chão.

### No card de upgrade

Farm não ataca, então o `AttackSpeed` dela é um número que não quer dizer nada — a
linha é reaproveitada para o bônus, exatamente como o `DamagePerSecond` já era
reaproveitado para a renda. Nenhuma mudança de GUI: o Entrepreneur mostra

```
$60 PER WAVE          (DamagePerSecond)
15% PER UNIT BONUS    (AttackSpeed)
6 RANGE               (Range — o raio da aura)
```

e a **prévia do próximo nível** vem de graça, porque ela usa os mesmos formatadores
com `level + 1` (`20% PER UNIT BONUS` pairando sobre o custo de upgrade, ou sempre
visível no celular). Por nível: 15 / 20 / 25 / 30 / 35 / 40%.

Os dois textos dizem mais do que "INCOME" e "BONUS" diziam, e de propósito:
**"PER WAVE"** porque a frequência é o que decide se a farm se paga (a renda cai no
fim de cada wave, não do round), e **"PER UNIT"** porque o bônus não é um valor que a
farm paga — é uma % em cima do que *cada* unidade dentro do raio já ganha por dano e
por morte. Sem isso escrito, "15%" se lê como algo que sai da própria farm.

Farm sem `Aura` no config volta a mostrar o cooldown — `formatCooldownOrBonus` decide
pela presença do bônus, não pelo nome da unidade.

### O caminho do dinheiro

`UnitService:getAuraBonus` soma as farms que alcançam a unidade e devolve a fração.
Ela é **congelada no começo do golpe**, junto com o dano e o alcance (`executeAttack`)
— um MultiShot leva quase um segundo do primeiro ao último hit, e vender a farm no
meio não pode fazer os quatro hits do mesmo ciclo renderem diferente. Nas minas do
Tripminer, a distância medida é até a **unidade**, não até a mina: quem precisa estar
perto da farm é a torre.

A fração desce por `MobService:DamageMob(..., cashBonus)` e entra nos dois prêmios,
o de dano e o de morte.

A lista de farms com aura (`AuraSources`) é remontada uma vez por quadro no
`stepCombat`, em vez de mantida na colocação e na venda: o `stepCombat` já varre a
lista inteira todo quadro, então o segundo laço não se mede, e em troca não existe
estado para invalidar quando uma unidade entra, sai, é vendida ou o round recomeça.

### A sobra fracionária é guardada

Os prêmios são inteiros e quase todos pequenos. 15% de um kill de Traveler (3) dá
0,45; 15% do piso de $1 do prêmio por dano dá 0,15. Arredondados na hora, os dois
sumiriam — e a aura pareceria não fazer nada justamente nas waves altas, onde o piso
de $1 domina.

Por isso `MobService:applyCashBonus` guarda a sobra por jogador (`BonusRemainder`) e
paga assim que ela passa de 1. Um bônus pequeno paga devagar em vez de não pagar
nunca, e ao longo de uma wave o total bate com a porcentagem cheia. A sobra é zerada
no recomeço de round e quando o jogador sai.

### O efeito

Cada vez que uma unidade rende a mais, o servidor manda `AuraBonusVFX` com o `unitId`
e o `VFXController:PlayAuraBonus` clona `Assets.VFX.MoneyEntrepreneur` **dentro da
`HumanoidRootPart`** da unidade. O asset é um `Attachment`, então morar numa BasePart
é o que faz o efeito acompanhar o modelo sem weld nenhum — ao contrário do
`VFXController:Play`, que solta o clone no Workspace.

O emit e a faxina são do módulo `ReplicatedStorage.vfx`: os `EmitCount` e `EmitDelay`
vêm autorados no `ParticleEmitter` do asset e é ele quem sabe lê-los, e o
`destroyAfter` sem prazo tira a vida do próprio asset (hoje 0,6 s). Mexer no emitter
no Studio não deixa lixo para trás.

**O efeito é estrangulado por unidade** (`AURA_VFX_COOLDOWN`, 0,35 s). Um MultiShot
são quatro golpes e um AOE é uma chamada de dano por inimigo atingido — sem o
estrangulamento, um Rocket dentro da aura mandaria dez efeitos no mesmo quadro para a
mesma torre. O bônus em si continua valendo em **todos** os golpes; só o dinheirinho
na tela é que espaça.

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

Os atalhos `1`–`6` do `Components/Card.luau` seguem a mesma visibilidade: o
`InputBegan` sai fora quando o `TowerContainer` está invisível, para a hotbar
escondida não continuar equipando unidade por teclado.

### A hotbar é o deck montado no lobby

Quem decide o que entra na hotbar é o **deck** (`EquippedUnits` no perfil, ver
`SharedConfig.DeckConfig` e o [README do Lobby](../Lobby/README.md#deck-inventário-cartas-equipadas-e-detalhe)):
só entra unidade que está num slot, e a quantidade de cada carta é o `Amount`
daquele slot — não o inventário inteiro, como era antes.

- **servidor** (`UnitService:initPlayerCards`): monta `SessionCards` a partir do
  deck. É o `getCardCount` que recusa a colocação, então o deck é o que de fato
  limita a partida.
- **cliente** (`CardController`): monta a hotbar com `DeckConfig.unitList`, na
  ordem dos slots e sem os buracos — slot vazio não vira carta em branco no meio
  da mão. A primeira carta da mão é o primeiro slot ocupado, e assim por diante;
  quem desenha é o componente `Card`, e o `CardController` só diz o que aparece,
  quantas cartas cada uma tem e qual está escolhida.

As duas pontas leem o mesmo perfil pelas mesmas funções, então chegam ao mesmo
deck sem evento novo. Quem **nunca montou deck** recebe um automático
(`DeckConfig.autoDeck`, chamado pelo `resolve`): as unidades mais raras primeiro,
com as cartas distribuídas em rodízio até o `CardLimit`. Sem isso um jogador que
nunca abriu o painel entraria na partida sem carta nenhuma e não conseguiria
colocar nada. O deck automático **não é gravado** — vale só para a sessão.

### A arte da carta é por unidade

O `Card` do `CardWrapper` é um **ImageLabel**, e a arte dele é a carta inteira —
moldura, ilustração e fundo numa imagem só. Os ids ficam em
`SharedConfig.CardConfig`, e quem escreve é o componente `Card`, na mesma passada em
que ele escreve o nome e o custo.

| Unidade (`UnitStats`) | Carta |
| --- | --- |
| `Slasher` | Slasher |
| `Rocket` | Rocketeer |
| `Entrepreneur` | Entrepreneur |
| `Sword` | Gladiator |

A tabela existe porque o nome da unidade nem sempre é o nome que o jogador lê na
arte: a carta do **Rocketeer** é da unidade `Rocket`, e a do **Gladiator** é da
`Sword`. Errar a chave não estoura nada — a unidade só fica sem arte própria, que é
o sintoma mais difícil de ligar à causa.

Unidade sem id fica com a arte que o `CardWrapper` tem autorada no StarterGui:
carta com a arte errada é melhor do que carta invisível na hotbar. Hoje é o caso de
`Slingshot` e `Subspace Tripminer` — e como a arte autorada é a do Slasher, as duas
aparecem com a carta dele até os ids chegarem.

### O arco (`Components/Card.luau`)

O `TowerContainer` não tem mais um `CardN` por slot: ele tem **um** `CardWrapper`
autorado, que é o molde. O componente o tira da tela no primeiro uso e clona um
por unidade do deck, então a hotbar na tela é sempre 100% deck.

Quem espalha os **wrappers** na horizontal é o `UIListLayout` do container. O que
o componente desenha é a posição **Y da carta dentro do wrapper** — e é daí que
sai o arco, de concavidade para baixo. Separar os dois é o que deixa o arco
existir sem brigar com o layout.

A carta cai pelo **quadrado** da distância até o vértice, medido em **alturas de
carta** (`card.Size.Y.Scale`): mexer no tamanho da carta no Studio abre ou fecha o
arco inteiro sozinho. A curva é normalizada pela distância da carta mais longe, de
modo que a da ponta sempre caia `ARC_SPREAD` — sem isso, escolher a primeira carta
de um deck de seis jogaria a última quase uma altura inteira para baixo (o
quadrado de 5), para fora do container.

O **vértice** é o meio do deck: a carta do meio quando o número é ímpar, e as
**duas** do meio quando é par (as duas ficam à mesma distância de `(n+1)/2`, então
sobem juntas).

| Cartas | Y de cada uma |
|---|---|
| 6 (par) | `0.730 0.577 0.500 0.500 0.577 0.730` |
| 5 (ímpar) | `0.730 0.558 0.500 0.558 0.730` |

Medir contra o menor e o maior quadrado da lista resolve os três casos com a mesma
conta. Toda vez que uma carta entra ou sai — e toda vez que a escolha muda — o deck
inteiro se reacomoda; no primeiro desenho a hotbar já nasce montada, sem animação.

A reacomodação inteira dura **`ARC_TOTAL_TIME` (0,3 s)**, do primeiro movimento ao
último, e as cartas não saem todas juntas: uma fatia do tempo
(`ARC_STAGGER_SHARE`, 40%) é gasta escalonando as saídas, da esquerda para a
direita, e o que sobra é a duração de cada uma. Como o intervalo total é sempre a
mesma fatia, o deck de duas cartas e o de seis terminam no mesmo instante — muda só
o quão apertado fica o intervalo entre uma e outra:

| Cartas | Intervalo | Duração de cada | Última termina em |
|---|---|---|---|
| 2 | 0,120 s | 0,180 s | 0,300 s |
| 3 | 0,060 s | 0,180 s | 0,300 s |
| 6 | 0,024 s | 0,180 s | 0,300 s |
| 1 | — | 0,300 s | 0,300 s |

Carta sozinha não tem entre quem escalonar, então o tempo todo vira duração. O
atraso vai no próprio `TweenInfo` e não num `task.delay`: enquanto ele não vence o
tween não escreve nada, e cancelar o tween cancela a espera junto — o que importa
quando uma escolha nova chega no meio da reacomodação anterior.

A **inclinação** sai da mesma distância, só que com sinal e normalizada do mesmo
jeito: quem está à esquerda do vértice tomba para a esquerda, quem está à direita
tomba para a direita, e a carta da ponta chega a `ARC_TILT` (8°, os mesmos do leque
que estava autorado antes). A carta do vértice fica em pé.

#### A escala diz o que está acontecendo com a carta

O `UIScale` de cada carta tem três estados, e o maior deles ganha:

| Estado | Escala |
|---|---|
| parada | 1 |
| **escolhida** (é a que está na mão) | 1,1 |
| debaixo do mouse | 1,2 |

Todas as trocas passam pelo mesmo tween de 0,2 s, então tirar o mouse de uma carta
escolhida desce de 1,2 para 1,1 sem salto, e escolher outra carta troca as duas ao
mesmo tempo. **A escolha não mexe no arco** — o vértice é sempre o meio do deck; é
a escala que mostra qual carta está na mão.

Escolher uma carta toca o `CardFlip` de `SoundService.SharedSounds.SFX` (pelo
`MusicController:PlaySFX`), o mesmo som do painel de deck no lobby. Só quando uma
carta **entra** na mão: largar a unidade passa pelo mesmo caminho com `nil`, e aí
não há carta nenhuma para virar. Não se confunde com o `SelectSound`, que é de
selecionar uma unidade **já colocada no mapa** (`UnitPlacementController:selectUnit`).

Com uma carta escolhida, **as outras apagam um pouco** — elas e tudo o que têm
dentro, mais o contador delas, que mora fora da carta mas é parte dela. O apagar é
uma fração do caminho que falta até a transparência total
(`base + (1 - base) * DIM_AMOUNT`), e não um valor fixo: assim ele se **compõe**
com o que a peça já tinha em vez de atropelar. Uma carta sem estoque já está em
0,25 e vai para 0,51; um botão invisível (1) continua em 1.

Os valores de volta são os que foram lidos do clone recém-feito, antes de qualquer
coisa mexer nele, então "volta ao estado original" é literal — o alvo é sempre o
que o designer deixou no molde, e não um número escrito no código. Quem escreve
transparência é uma função só (`_applyTransparency`), que soma os dois motivos que
existem para uma peça apagar: o estado da carta (sem estoque) e a escolha de outra.
Sem isso os dois se sobrescreveriam.

Como as cartas se sobrepõem bastante, quem cresce também vem para a frente
(`ZIndex`): a que está sob o mouse ganha de todas, e a escolhida fica à frente das
vizinhas — senão ela cresceria por baixo delas.

#### Carta que cresce empurra as vizinhas

Mudar a escala **ou o tamanho** de qualquer carta dispara a reacomodação, e a nova
posição de cada uma leva esse crescimento em conta: a carta que cresceu não sai do
lugar, e a largura que ela ganhou é devolvida em espaço para os dois lados, metade
para cada um (`PUSH_SHARE`). Como o empurrão é simétrico, as pontas andam o mesmo
tanto em direções opostas e a mão continua centrada.

Com seis cartas de 156 px, a segunda sob o mouse (1,2) e a quarta escolhida (1,1):

```
carta 1  escala 1,0   -27,5 px
carta 2  escala 1,2    -9,2 px   <- cresceu
carta 3  escala 1,0    +9,2 px
carta 4  escala 1,1   +18,4 px   <- cresceu
carta 5  escala 1,0   +27,5 px
carta 6  escala 1,0   +27,5 px
```

O deslocamento vai no **offset X da carta**, dentro do wrapper — o `UIListLayout`
continua dono da posição dos wrappers, e não fica sabendo de nada. A largura usada
na conta é a autorada (`Size` contra o wrapper), nunca o `AbsoluteSize`: durante o
tween do hover o absoluto está no meio do caminho, e o empurrão ficaria perseguindo
o próprio efeito. Ler o `Size` na hora é também o que faz mexer no tamanho da carta
reacomodar o deck, e não só mexer na escala.

A reacomodação é sempre a mesma: os 0,3 s escalonados. Trocar de carta escolhida
mexe em duas, mas o deck se reacomoda uma vez só.

#### Os contadores vivem fora das cartas

O `Count` não é mais filho do `Card`: ele mora numa camada única (`CountLayer`), e
por isso todos ficam **no mesmo plano, à frente de todas as cartas**. Enquanto ele
era descendente do card, sumia atrás do card vizinho — a `Interface` é
`ZIndexBehavior.Sibling`, e nesse modo um descendente nunca desenha acima de um
irmão do pai dele, por mais `ZIndex` que se dê a ele.

O vínculo que era de parentesco virou conta, refeita a cada quadro
(`_followCounts`): o centro do contador sai de onde ele estava dentro da carta (lido
do molde), girado pela inclinação dela e medido sobre o **tamanho absoluto** do
card — que já inclui o `UIScale`. Então o contador acompanha o arco, a inclinação e
o crescer do hover sem um quadro de atraso.

A camada é o último filho do `TowerContainer`, e como tal ela também entra no
`UIListLayout`. A largura dela é escolhida para **anular a própria vaga**: com o
espaçamento de −12 px do layout, uma célula de +12 px seguida de −12 px de padding
soma zero. Medido no place: as seis cartas ficam no mesmo pixel com e sem a camada.

As cores do estado normal (contorno do custo, cor do contador) são lidas do molde,
não escritas no código: trocar o roxo no Studio basta. Sem dinheiro para o custo, a
carta fica vermelha (`NoCash`).

#### Carta sem unidade sai da mão

Quando o contador de uma unidade zera, a carta dela **não fica apagada na mão**: ela
cai para fora do deck em 0,5 s (`EXIT_DROP`, medido em alturas de carta, então ela
sai inteira da tela em qualquer resolução). A vaga só fecha **quando ela termina de
cair** — o `_layout` das outras sai do `Completed` do tween, não do clique —, e aí
as cinco restantes se reacomodam no arco pelos 0,3 s de sempre.

Quando a unidade volta a existir, o caminho é o mesmo ao contrário: a vaga reabre na
hora e a carta sobe de onde parou até o lugar dela, também em 0,5 s. Sair acelera
(Quad In) e voltar desacelera (Quad Out).

Carta fora da mão não conta para nada: não ocupa vaga no arco, não ocupa tecla (os
atalhos `1`–`6` numeram o que está na tela) e some junto com o contador dela. Esse
último é fácil de esquecer — o contador mora na camada de cima, não no wrapper,
então esconder o wrapper não o esconde; quem cuida das duas metades é o
`_setPresence`.

Carta que já nasce sem unidade (a mão sendo montada) entra direto no estado de fora,
sem cair — não há de onde cair.

## leaderstats: Damage e Cash

O `LeaderstatsService` (`Game/src/Services`) põe duas colunas na lista de jogadores,
nesta ordem — a Roblox desenha na ordem em que os valores entram na pasta.

| Coluna | De onde vem |
| --- | --- |
| Damage | `MobService.SessionDamage`, o placar que decide o MVP (`GetDamageDealt`) |
| Cash | `MobService.SessionCash`, o dinheiro do round (`getCash`) |

Os dois são **da sessão**, não do perfil: nada disso é salvo, e os dois voltam a zero
quando o round recomeça. Não confundir com o [`leaderstats` da
Lobby](../Lobby/README.md#leaderstats-coins-wins-e-shards), que mostra Coins, Wins e
Shards do perfil — lá `Coins` é o `Stats.Cash` guardado, que é outra moeda.

**Aqui é polling (4 Hz), e na Lobby não.** Lá toda escrita passa por um funil
(`DataService:Update`) e acontece de vez em quando, então um sinal por escrita é
exato e barato. Aqui, dois motivos viram o jogo:

- **frequência** — o dano cresce a cada golpe em cada mob. Com AOE e meia dúzia de
  torres são dezenas de escritas por segundo, e escrever o `IntValue` em todas
  replicaria muito mais do que a lista consegue mostrar.
- **os zeros** — o fim de round limpa o placar com `table.clear(SessionDamage)`, que
  não é escrita nenhuma. Um desenho movido a evento continuaria mostrando o dano da
  partida passada; lendo o estado, a volta ao zero sai de graça.

A escrita só acontece quando o valor muda, então parado o service não replica nada. O
`math.floor` é explícito para a comparação valer sobre o mesmo número que vai ser
escrito — sem ele, um dano fracionário marcaria "mudou" a cada golpe sem a coluna
nunca mudar na tela.

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

## Pular a wave (`StarterGui.Interface.SkipPrompt`)

O prompt de pular **não tem botão para abrir**: ele aparece sozinho quando a partida
trava. O critério é o contato — nenhuma unidade de nenhum jogador encostou em nenhum
mob por `SkipConfig.IdleTime` (5) segundos.

Quem marca o contato é o `MobService:DamageMob`, que é por onde passa **todo** dano do
jogo (torre, tripmine, respingo de área): cada golpe que entra escreve
`MobService.LastContact = os.clock()`. O `SkipService` só lê esse relógio a cada
`PollInterval`. Tempo real, e não `GameClock`: o que se mede aqui é a paciência de
quem está olhando a tela, e não o ritmo da partida — no 1,35x, cinco segundos parados
continuam sendo cinco segundos parados.

A janela recomeça a cada wave (`SpawnWave` também escreve `LastContact`): os mobs
ainda estão a caminho das unidades, e o silêncio da caminhada não é a partida travada.

### Quando o prompt pode aparecer

Além da ociosidade, `WaveService:CanSkipWave()` cobra quatro condições, e todas as
quatro são sobre o laço do round:

| Condição | Por quê |
| --- | --- |
| round `Running`, sem game over | fora disso não há wave para pular |
| `WaveAwaiter` existe | o laço está esperando o fim de **uma wave**, e não no intervalo |
| `MobService.AllMobsSpawned` | pular no meio de um spawn poria duas corotinas de `SpawnWave` no ar |
| `WaveCount < MaxWaves` | a última wave não pula: adiantar a vitória entregaria a partida com inimigos no caminho |

Voltando a haver contato, o prompt sai da tela e **os votos são descartados**: o
motivo de pular deixou de existir, e um voto dado há meia wave não pode fechar a
votação de agora.

### A votação

Maioria estrita de quem está no servidor (`SkipConfig.RequiredVotes`): 1 jogador
decide sozinho, 2 precisam concordar, 4 precisam de 3. O contador da tela mostra
**votos sobre votos necessários** (`1/3`), e não sobre o total de jogadores.

- **Confirm** vota a favor.
- **Cancel** tira o voto e some com o prompt **só para quem clicou**, até a próxima
  votação. Cada abertura vem com um `token` novo do servidor; um token que o cliente
  ainda não dispensou volta a aparecer normalmente.

Fechada a votação, o `WaveService:SkipWave()` dispara o mesmo `Signals.Ended` que o
`MobService` dispara quando o último mob morre. Para o laço do round a wave acabou, e
ela paga como qualquer outra (o dinheiro de wave e a renda das farms). **A diferença
está no mapa, não no código**: os mobs que sobraram continuam andando, continuam
pagando por dano e por morte, e continuam podendo derrubar a base. Pular é trocar
espera por risco, e não por desconto.

Os dois `Ended` não se atrapalham: enquanto a próxima wave não chama `awaitWaveEnd` de
novo ninguém está escutando, e a partir daí o `MobService` só dispara quando **todos**
os mobs vivos morrerem, os que sobraram inclusive.

⚠️ É por causa disso que o `SpawnWave` **não zera** o `ActiveMobCount`. Zerar faria os
mobs que sobraram descontarem da conta da wave nova, e o `Ended` sairia com inimigos
vivos no mapa. O número já é o de mobs vivos: o spawn soma, o `removeMob` subtrai e o
reset de round zera.

### A animação

É a mesma do `WeatherWarning` (ver `WarningConfig`): o prompt desce de `SlideOffset`
acima do lugar autorado enquanto a transparência sobe de 1 até o valor autorado.

**Até o valor autorado, e não até zero.** O `SkipPrompt` tem fundo transparente,
sombra a 20% e imagem opaca no mesmo galho — animar todo mundo para zero pintaria uma
caixa sólida por trás da arte. O `SkipPromptController` lê a transparência de cada
descendente uma vez, no bind, antes de qualquer animação: repintar no Studio basta.
`GuiObject.Transparency` fica de fora da lista de propósito, porque é apelido de
`BackgroundTransparency` e os dois tweens brigariam pela mesma propriedade.

## Velocidade da partida (`StarterGui.Interface.Speed`)

O `ImageButton` `Interface.Speed` acelera a partida. Um clique avança um degrau e
volta ao 1x depois do último; a arte do botão é **a velocidade em que a partida
está agora**, não a próxima.

| Degrau | Escala | Imagem |
| --- | --- | --- |
| 1 | 1x (padrão) | `rbxassetid://132899761008925` |
| 2 | 1,15x | `rbxassetid://106089741438137` |
| 3 | 1,35x | `rbxassetid://122729764545333` |

Os degraus vivem no `SharedConfig.SpeedConfig` — velocidade nova é uma linha lá, e
as duas pontas a leem pela mesma tabela (o cliente pega a arte, o servidor pega a
escala).

O botão tem o mesmo "pop" de clique dos botões do HUD do Lobby (`HUDButtonController`):
encolhe para 0.9 enquanto está apertado (`Circular`) e volta com overshoot (`Back`),
com o `UIClick` saindo na volta. É `MouseButton1Down`/`Up`, e não `Activated`, porque
quem troca a velocidade é o `MouseButton1Click` — a animação não pode consumir o
clique dele. O `UIScale` é criado pelo controller: o `Interface.Speed` não traz um.

**A velocidade é da sala, não de quem clicou.** A simulação inteira (mob andando,
torre atacando, wave nascendo) é do servidor, então ou todos jogam acelerado ou
ninguém joga. Quem clica acelera a partida dos outros junto, e a arte do botão de
todo mundo muda no mesmo instante.

O cliente **pede o degrau que quer**, e não um "avança um": dois jogadores clicando
ao mesmo tempo param os dois no 1,15x, em vez de um empurrar o outro até o 1,35x. O
`SpeedService` valida o índice (vem pela rede), ignora clique repetido do mesmo
jogador dentro de 0,15s e só então avisa a sala pelo `GameSpeedChanged`. A arte
local só muda com essa confirmação — trocar na hora mostraria 1,15x para quem clicou
enquanto os outros ainda estão no 1x.

O `SpeedService` está na lista de round-scoped do `WaveService`, então **partida
nova começa no 1x**, e não no 1,35x que alguém deixou ligado na anterior.

### O relógio da partida (`Shared.Util.GameClock`)

Não existe uma regra de "x2" espalhada pelas durações do jogo. Todo o gameplay já
comparava instantes contra `os.clock()` — `StunnedUntil`, `lastAttack`, `expiresAt`
da carga —, então o que a velocidade troca é a **fonte do "agora"**: o `GameClock`
soma `dt * escala` por Heartbeat, e cooldown, atordoamento, buff e cadência de spawn
encolhem juntos sem ninguém tocar num número de config.

Ele começa em `os.clock()` de propósito: muito código faz `now - (entry.lastAttack
or 0)` contando com um número grande de um lado e zero do outro para dizer "nunca
atacou, pode atacar já". Um relógio começando em zero faria a unidade recém-colocada
esperar um cooldown a mais.

Cada máquina tem a sua cópia, e o `SpeedService` mantém as escalas iguais avisando
todo mundo a cada troca. O cliente precisa da dele porque quem move o modelo do mob
na tela é o `MobController` — ele soma `speed * GameClock.Scaled(dt)`, o mesmo `dt`
acelerado que o `MobService` usa do lado de lá. Sem isso o servidor entregaria o mob
na base com o boneco ainda no meio do caminho.

Quem passou a usar o relógio, e por quê:

| Onde | O que encolhe |
| --- | --- |
| `MobService` | distância andada por quadro, cadência de spawn (`SpawnDelay`), stun de gimmick |
| `UnitService` | cooldown de ataque, windup, `HitInterval`, atordoamento e carga |
| `WaveService` | o respiro entre waves (`WaveInterval`) |
| `ThunderService` / `SnowService` | o intervalo entre raios e entre congelamentos |
| `MobController` | o passo do mob na tela e a velocidade das animações dele |
| `Classes.Unit` | a animação de ataque e as esperas de golpe do lado do cliente |
| `TargetingController` | o cache de progresso no caminho, no mesmo ritmo do servidor |

**O que continua em tempo real, de propósito:**

- **o intervalo antes da wave** (`runIntermission`) — é tempo de o jogador montar a
  defesa, e já tem o botão `ReadyWave` para encurtar;
- **as setas do caminho** (`getArrowLeadTime`) — quem as anima é o `WaveController`,
  em tempo de tela; encurtar só o lado do servidor poria o mob no mapa com a seta
  ainda no meio da rota;
- **VFX, telas de resultado e os estrangulamentos de rede** (flush de dano, VFX da
  aura) — acelerar aquilo não é acelerar a partida, é tirar do jogador o tempo de
  ler.

A renda da farm não entra na conta porque ela é paga **por wave** (`payFarmUnits` no
`Signals.Ended`), e não por segundo: acelerar não imprime dinheiro. As recompensas de
fim de round também são por wave sobrevivida, então acelerar muda o ritmo da partida, não
o que ela paga.

## Bug conhecido (não corrigido)

`src/Controllers/UILibraryController/Components/Wave.luau` → `module:destroy()`
referencia `CardUpgrade`, que não existe nesse arquivo (é uma colagem do
`ToggleTower.luau`). Estoura se `destroy()` for chamado.

## Lixo no Workspace (não tocado)

28 modelos de inimigos/unidades soltos (Azuron x4, Rocketeer x3, Azure x2, sword,
slasher, slingshot, …, ~7.000 instâncias, sem tags) e as ScreenGuis vazias
`Cards` e `Upgrade`.
