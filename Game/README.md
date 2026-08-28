# Game — "Periastron TD: Main Game"

Ver o [README da raiz](../README.md) para a arquitetura, o setup e o que é
compartilhado entre as duas places. Aqui fica só o que é exclusivo deste place.

## O que é só daqui

| Pasta | Vai para | Conteúdo |
|---|---|---|
| `src/ClientBoot/` | `StarterPlayerScripts.Client` | LocalScript de entrada |
| `src/Controllers/` | `Client.Controllers.Game` | Card, Difficulty, Loading, Mob, Music, Projectile, Ready, RoundCardShop, SkipPrompt, Targeting, Tripmine, UILibrary, UnitPlacement, VFX, Wave |
| `src/Services/` | `ServerScriptService.Services.Game` | CardShop, Collision, Data, Difficulty, Map, Mob, Skip, Snow, Thunder, Unit, Wave, WeatherRound |
| `src/CmdrDefinitions/` | `ServerScriptService.CmdrDefinitions.*.Game` | comandos `strike`, `roundcash` e `roundshop` |

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

## Projéteis (`Projectile` no `UnitStats`)

Unidade que atira declara um `Projectile`, e as duas pontas leem a mesma tabela: o
cliente desenha o voo (`ProjectileController`, chamado pelo `Unit:playAttackVisual`) e
o servidor resolve quem levou dano (`UnitService:executeAttack`). **O projétil na tela
nunca decide dano** — ele pode até passar longe que o hit já foi creditado.

### De onde a flecha sai

Do `RootPart` da unidade, por `Unit:projectileOrigin`.

Saía do pivô do modelo **mais dois studs**, e os dois studs eram o bug: as unidades
têm pouco mais de dois studs de altura inteira (o Archer mede 2,26 e o Slingshot
2,07), com o `HumanoidRootPart` no meio do torso, a ~1,15 do chão. Somar dois punha a
origem em 12,15 num boneco que termina em 11,26 — quase um stud **acima da cabeça**.
Era visível no Slingshot e no Archer porque a flecha é fina e o voo é reto; no Rocket
o rastro e a explosão escondiam.

Ler o root também é mais seguro que ler o pivô: `GetPivot` responde pelo `WorldPivot`,
que só coincide com o root enquanto o `PrimaryPart` estiver certo — perdido o
`PrimaryPart`, o modelo passa a responder pelo centro da caixa delimitadora, que muda
de altura conforme a pose da animação. Não há offset nenhum no código de propósito: o
lugar de nascer mais alto (a ponta do arco, a boca do cano) é uma peça no modelo, e
não um número somado que vale para todas as unidades ao mesmo tempo.

### `Subtype = "Piercing"` — a flecha atravessa

Hoje só o Archer. O golpe deixa de ser "o alvo" e passa a ser **a linha** que sai da
unidade, passa por onde o alvo vai estar e segue até o **alcance dela** — não até o
alvo. Quem estiver nessa linha leva o dano cheio, inclusive quem vem atrás.

| Peça | Onde |
| --- | --- |
| quem está na linha | `MobService:GetMobsAlongLine(origin, through, length, width)` |
| o dano | o ramo `pierce` do `executeAttack`, antes do alvo único |
| o desenho | `ProjectileController:_flyThrough` |

### A flecha perde força a cada corpo (`PierceFalloff`)

No Archer, `0.1`: cada inimigo furado leva 10% menos que o anterior. A queda é
**composta**, e não descontada do dano cheio — os 16 saem `16, 14, 13, 12, 10, 9, 9,
8`, então oito em linha somam **91** de dano e não os 128 de oito tiros cheios.

Composta ela nunca chega a zero (uma flecha que furou dez corpos ainda machuca um
pouco), enquanto tirar 10 pontos percentuais de cada vez faria o 11º levar nada e o
12º levar dano negativo. O arredondamento é o mesmo do `getDamage`
(`math.floor(x + 0.5)`) e o piso é 1, para o fim da fila não virar um "0" flutuando na
tela: acertou, tirou vida.

Sem o campo, atravessar é de graça — e era esse o risco: um Archer bem posto num mapa
que enfileira estouraria sozinho o teto de 15 de DPS por 100 de caixa da regra 1 do
`UnitStats`. Com a queda, alinhar mais inimigos continua valendo a pena e para de
escalar reto.

Três decisões que não são detalhe:

- **A conta é no plano, ignorando o Y.** A unidade fica na plataforma e o mob anda no
  chão, então a linha entre os dois desce. Medindo em 3D, um inimigo no caminho ficaria
  "longe da linha" só por estar mais baixo que a torre, e a flecha o atravessaria sem
  tirar vida.
- **A direção é congelada no disparo.** O projétil comum persegue — recalcula o alvo a
  cada quadro e curva atrás dele —, e uma flecha que atravessa não pode: ela curvaria
  para o primeiro inimigo em vez de riscar a linha por onde os outros vão levar dano. O
  `onArrive` sai quando ela **passa** por onde o alvo estava, e não quando ela some.
- **A mira é a posição prevista** (`PredictPosition`), a mesma que o cliente usou.
  Mirar em onde o mob está agora poria a linha atrás dele.

Se o alvo sair da linha entre a mira e o disparo (ele virou uma esquina durante o
windup), ele leva o tiro assim mesmo: um golpe inteiro perdido por causa de uma curva
seria pior que a imprecisão.

**Isso muda a conta da regra 1 do `UnitStats` quando o mapa enfileira**: o DPS efetivo
do Archer é 8,0 vezes quantos couberem na linha. Contra um inimigo sozinho ele continua
igual ao que era. Se ele virar escolha óbvia em algum mapa, o botão a girar é o
`Damage`, e não o subtipo.

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
| `Info` (a imagem) | `CardConfig.GetIcon`, o retrato da unidade |

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

O `Info` é a moldura que carrega o nome e o nível, e a imagem dela é o **retrato da
unidade** — os ids ficam em `CardConfig.Icons`. Ela é outra arte que a de
`CardConfig.Images`: aquela é a carta inteira da hotbar, esta é só o rosto num
quadrado pequeno. As duas vivem no mesmo módulo porque erram pelo mesmo motivo — a
chave é o nome de `UnitStats`, e não o nome que o jogador lê: o retrato do
**Gladiator** é da unidade `Sword`, e o do **Rocketeer** é da `Rocket`.

Ao contrário do `ClassIcon`, unidade sem retrato **não esconde** o label: o nome e o
nível moram dentro do `Info`, e sumir com a moldura levaria os dois junto. Ela volta
para a arte autorada no StarterGui, lida uma vez no carregamento do módulo e antes de
qualquer troca — sem guardar esse padrão, o card abriria com o rosto da unidade
*anterior*, que é um erro pior porque parece certo. Hoje têm retrato o Slasher, o
Entrepreneur, o Sword e o Rocket; faltam Azure, Slingshot e Subspace Tripminer.

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

## Votação de dificuldade (`StarterGui.Difficulty.DifficultyBoard`)

**O nome da instância do botão é o voto.** O `DifficultyController` varre os
`ImageButton` filhos do board e dispara `SelectDifficulty(child.Name)`; o
`DifficultyService` recusa o que não existir em `DifficultyConfig.Presets`. O mesmo
nome é a chave do `VoteCount` (`votes[name]`) e do destaque de quem você votou.

Ou seja: renomear um botão no Studio troca em que dificuldade ele vota. Os cinco
precisam se chamar exatamente `Easy`, `Medium`, `Hard`, `Impossible` e `Nightmare` —
o texto que o jogador lê fica no `TextLabel` dentro deles e não é olhado por
ninguém.

### O bug que isso já causou

O board vinha com dois botões com o nome trocado, e o par produzia dois sintomas que
pareciam problemas separados:

| Botão (nome) | Label lido | O que acontecia |
| --- | --- | --- |
| `Extreme` | IMPOSSIBLE | `SelectDifficulty("Extreme")` — **recusado**, o voto sumia |
| `Impossible` | NIGHTMARE | `SelectDifficulty("Impossible")` — aceito, mas como Impossible |

Resultado: **Impossible era impossível de votar** (o botão estava vivo, clicava, e o
voto era descartado em silêncio), e **quem votava Nightmare jogava e recebia o prêmio
de Impossible** — 2,75x de cash e 2,5x de shards em vez de 4x e 7,5x, com 30 waves em
vez de 35. `Nightmare` não tinha botão nenhum. Corrigido renomeando as duas
instâncias.

Nada disso deixava rastro: o servidor descarta nome inválido sem log, e o board
continuava com cinco botões acesos. Por isso o `DifficultyController:auditButtons`
agora confere, na primeira vez que um estado chega, se cada botão tem preset do outro
lado e se cada preset tem botão — e avisa no console nos dois casos. A conferência
mora ali, e não no bind, porque a lista de presets é server-side: ela só chega pelo
`state.options` do `DifficultySelection`.

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

> Nem toda carta da mão vem do deck: as compradas na
> [loja de round](#loja-de-cartas-de-round-starterguiroundcardshop) entram por
> `addRound` e ficam no mesmo `self.entries`, sujeitas a este mesmo arco. O que as
> distingue é o `entry.Kind` e o `entry.Unit` vazio — ver
> [A carta na hotbar](#a-carta-na-hotbar).

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
quem está olhando a tela, e não o ritmo da partida — no 2x, cinco segundos parados
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
| 2 | 1,5x | `rbxassetid://106089741438137` |
| 3 | 2x | `rbxassetid://122729764545333` |

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
ao mesmo tempo param os dois no 1,5x, em vez de um empurrar o outro até o 2x. O
`SpeedService` valida o índice (vem pela rede), ignora clique repetido do mesmo
jogador dentro de 0,15s e só então avisa a sala pelo `GameSpeedChanged`. A arte
local só muda com essa confirmação — trocar na hora mostraria 1,5x para quem clicou
enquanto os outros ainda estão no 1x.

O `SpeedService` está na lista de round-scoped do `WaveService`, então **partida
nova começa no 1x**, e não no 2x que alguém deixou ligado na anterior.

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
| `TripmineController` | o arco da mina arremessada, que termina quando o servidor a arma |

### As minas do Subspace Tripminer em velocidade alta

O Tripminer não é uma torre que atira: ele planta minas no caminho. O plantio
(`UnitService:stepTripminer`) e o gatilho (`stepTripmines`) sempre correram no
`GameClock`, mas **duas coisas fora dele** só apareciam acelerado.

#### O gatilho não podia ser um ponto

A mina detonava quando havia um mob a menos de `TriggerRadius` (2,5) **dela naquele
quadro**. Só que um mob anda `CurrentSpeed * dt` por quadro, e o `dt` já vem
multiplicado pela velocidade da partida: acelerado, o passo de um quadro passa do
diâmetro do gatilho e o inimigo atravessa a mina intacto.

O teto de velocidade do jogo é ~57 studs/s (o `CourageBearer`, `SpeedMultiplier` 2,5,
no Nightmare com o `SpeedGrowthCap` e os 2,5x que o gimmick de curva acumula). Contra
os 5 studs de diâmetro do gatilho:

| | passo por quadro | minas atravessadas |
| --- | --- | --- |
| 60 fps, 3x | 2,9 studs | 0% |
| 30 fps, 2x | 3,8 studs | 0% |
| 30 fps, 3x | 5,7 studs | **13%** |
| 20 fps, 3x | 8,6 studs | **42%** |
| 15 fps, 3x | 11,5 studs | **57%** |

(Taxa medida varrendo 200 fases de quadro por cenário — o acerto do teste por ponto
depende de onde o quadro cai em relação à mina, então ele falhava *por sorte*, não
por distância. Mina plantada fora do centro do caminho, que é o caso comum por causa
do desvio perpendicular de até 1,5 stud, falhava ainda mais: 30% já a 30 fps no 3x.)

É o framerate do **servidor**, que cai justamente nas waves grandes — e o 3x é o que a
carta Time Acceleration entrega. Os dois se encontram exatamente onde dói.

A correção é `MobService:GetMobCrossing`: em vez de perguntar quem está perto agora,
pergunta **quem passou perto neste quadro**, testando a distância da mina até o
segmento que o mob percorreu. O `MobService` guarda `mob.LastDistance` no começo de
cada Heartbeat, e a posição anterior é cacheada por quadro pelo mesmo motivo que a
atual — o gatilho roda uma vez por mina, e sem cache a conta viraria minas × mobs.
Zero falhas em toda a tabela acima.

> O raio de dano (`GetMobsInRadius`, 6 studs) continua sendo uma foto do instante da
> explosão, de propósito: com 12 studs de diâmetro ele tem 2,4x mais margem que o
> gatilho, e só um mob a 15 fps no 3x chegaria perto de atravessá-lo. Um respingo é
> uma foto; o gatilho é uma travessia.

#### O arco do arremesso, e quando a mina arma

O `TripmineController` desenhava o voo da mina em `os.clock()`, com 0,35s fixos. Era o
único tempo de gameplay do sistema fora do `GameClock`, e no 3x o windup e a animação
do arremesso encolhiam para um terço enquanto a mina continuava levando os mesmos
0,35s reais no ar — ela boiava enquanto o resto da partida corria.

Junto disso havia um segundo problema, que a velocidade agravava: a mina entrava em
`entry.mines` **no mesmo quadro** em que o cliente começava a desenhar o arco. Ela
passava o voo inteiro armada e invisível no destino, e um mob que cruzasse o ponto
nessa janela via a explosão sair de um lugar onde ainda não havia mina nenhuma.
Acelerado, o mob cobre 3x mais caminho nessa janela.

Agora são dois instantes, os dois no relógio da partida:

1. **fim do windup** (`HitTime`, 1,15s) — a mina sai da mão: sai o `TripmineThrown` e
   o cliente começa o arco;
2. **`ThrowTime` depois** (0,35s) — a mina pousa **e arma**.

O `ThrowTime` vive em `UnitStats["Subspace Tripminer"].Tripmine` e viaja no próprio
evento em vez de o cliente lê-lo do config: assim os dois lados gastam o mesmo número
por construção, e o arco termina no quadro em que o gatilho liga, em qualquer
velocidade. A `pendingMines` só libera a vaga no pouso — mina no ar já conta para o
limite, senão o cooldown de 3s contra windup mais voo deixaria plantar acima dele.

O arco lê o relógio a cada quadro em vez de converter para segundos reais na chamada,
então acelerar a partida **com uma mina no ar** encurta o que falta dela.

#### A mina some depois de explodir?

Sim, em qualquer velocidade — verificado. O `EXPLOSION_LIFETIME` (5s) e as partículas
são **os dois** em tempo real, então a folga entre eles não muda com a velocidade: a
partícula mais longa do asset dura 4s e a limpeza vem 1s depois dela. O
`task.delay` que destrói segura uma referência ao modelo e sempre dispara; o único
caminho que pula o agendamento é o modelo já ter sido destruído antes (venda da
unidade ou reset de round, pelo `clearUnitMines`).

`EXPLOSION_LIFETIME` é o único tempo real que sobrou no arquivo, e é o certo: partícula
não anda no relógio da partida, e acelerar essa limpeza cortaria a fumaça pela metade
no 3x.

O que **muda** com a velocidade é quantos convivem. O plantio custa 3 segundos de
partida, então acelerado ele sai mais vezes por segundo real enquanto a limpeza
continua nos mesmos 5s:

| Velocidade | Planta a cada | Modelos já explodidos vivos |
| --- | --- | --- |
| 1x | 3,0s reais | 1,7 |
| 2x | 1,5s reais | 3,3 |
| 3x | 1,0s reais | 5,0 |

São invisíveis (o `Transparency = 1` entra no mesmo quadro do estouro) e carregam 12
`ParticleEmitter` cada. Um Tripminer nível 5 no 3x chega a ~13 modelos sob o
`workspace.CurrentCamera` — 8 armados mais 5 apagando. É esperado, não vazamento: cada
um tem o seu prazo.

#### A explosão sai no chão, e não no ar

O servidor arma a mina quando ela pousa e o cliente gasta o mesmo `ThrowTime`
desenhando o arco, então no caso normal o voo já acabou quando o `TripmineTriggered`
chega — a latência atrasa os dois lados igualmente e se cancela.

Os dois relógios não viram ao mesmo tempo, porém: trocar a velocidade da partida com
uma mina no ar só chega no cliente uma viagem de rede depois, e nesse intervalo o arco
dele anda mais devagar que o cronômetro do servidor. A mina podia então explodir com o
voo ainda correndo, e como partícula fica onde foi emitida, o estouro aparecia **no
meio do ar**.

O `TripmineController:endArc` fecha isso: o gatilho encerra o arco e põe o modelo no
lugar de descanso antes de emitir. O `clearUnitMines` chama o mesmo, sem o `snap` — o
modelo está indo embora, não há lugar de descanso para ele.

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

## Loja de cartas de round (`StarterGui.RoundCardShop`)

De X em X waves cada jogador recebe uma oferta de **três cartas sorteadas**. A carta
comprada sai do caixa da partida (o `roundcash` do `MobService`, e não o `Cash` do
perfil), vai para a hotbar e vale **um uso**: clicar nela dispara o efeito e a carta
some.

Elas não são cartas de deck. Não passam pelo perfil, não sobrevivem ao round e não
têm nada a ver com o `DeckConfig` — o que elas mexem é no estado da sala: os
inimigos, o relógio e o céu.

| Onde | O quê |
| --- | --- |
| `SharedConfig.RoundCardConfig` | o catálogo, os intervalos por dificuldade, os nomes da GUI e os tempos da animação |
| `Services/CardShopService` | sorteio, cobrança, estoque e os efeitos |
| `Controllers/RoundCardShopController` | tudo o que aparece na tela |

### De quantas em quantas waves

Múltiplo exato do intervalo da dificuldade (`RoundCardConfig.Intervals`), disparado
pelo sinal `WaveStarted` do `WaveService` — a loja entra junto com o contador de
wave, e não quando os mobs nascem.

| Dificuldade | Intervalo | Waves de loja |
| --- | --- | --- |
| Easy | 4 | 4, 8, 12 |
| Medium | 4 | 4, 8, 12, 16, 20 |
| Hard | 5 | 5, 10, 15, 20, 25 |
| Impossible | 6 | 6, 12, 18, 24, 30 |
| Nightmare | 6 | 6, 12, 18, 24, 30 |

Dificuldade mais longa espaça mais de propósito: o Nightmare tem 35 waves contra as
15 do Easy, e um intervalo fixo faria a partida do topo oferecer mais que o dobro de
cartas da de baixo.

**A oferta é por jogador, o efeito é da sala.** O caixa da partida é individual, então
cada um sorteia o seu e compra com o seu dinheiro — mas o Time Stop para os inimigos
de todo mundo. Uma compra por abertura: a oferta fecha para quem comprou.

### As cartas

| Carta | Preço | O que faz | Onde o efeito mora |
| --- | --- | --- | --- |
| **Time Stop** | 350 | congela todos os inimigos por 4s | `MobService:FreezeAll` |
| **Time Acceleration** | 250 | a partida vai a 3x por 15s | `SpeedService:SetOverride` |
| **Weather Report** | 300 | tira o clima por 1 wave | `WeatherRoundService:Suppress` |

Carta nova são duas linhas: uma entrada em `RoundCardConfig.Cards` e uma função em
`CardShopService.Effects` com o nome que estiver em `Effect`. O sorteio **só oferece
carta cujo efeito existe** — entrada com `Effect` errado é descartada com um aviso,
em vez de virar uma carta que o jogador paga e não faz nada.

### O gesto de usar (`Visual`)

Carta com um `Visual` no config toca uma animação no personagem de quem usou, e é
**a animação** que dispara o som e as partículas — não um `task.delay` com o tempo
escrito no código. Hoje só o Time Stop tem:

```lua
Visual = {
    Animation = "rbxassetid://76323247675563",
    Marker = "TimeStop",
    Sound = "TimeStopSFX",      -- em SoundService
    VFX = "PlayerStopTime",     -- em Assets.VFX
}
```

O marcador de keyframe é **um só**, e o que separa as duas metades é o **parâmetro**
dele: `"Sound"` toca `SoundService.TimeStopSFX`, `"VFX"` estoura o asset. Reanimar a
carta no Moon Animator remarca as duas sem passar pelo código, que é o motivo de ser
um marcador com dois parâmetros em vez de dois marcadores com nomes diferentes.

**O clone do VFX nasce no uso, e não no marcador.** Pendurado na `HumanoidRootPart`
ele acompanha o jogador; criá-lo no meio da animação arriscaria o quadro do estouro
chegar antes de o asset estar no lugar. Em troca, quem pendura deve o estouro **ou** a
faxina — por isso o `track.Stopped` recolhe o clone quando a animação termina sem ter
passado pelo marcador (ela não carregou, ou foi cortada porque o jogador morreu).

**O jogador fica ancorado durante o gesto.** A carta para o tempo, e um personagem
andando por baixo da própria pose entregaria que nada parou. Ancorar a
`HumanoidRootPart` basta — o resto do corpo vem pendurado nela —, e o estado anterior
é lido em vez de presumido: devolver um `false` escrito na mão destravaria o que
estivesse ancorado por outro motivo.

Desancorar, recolher o clone e desligar as escutas moram no **mesmo** `finish`, que só
roda uma vez. São três fins possíveis — a animação terminou, foi cortada, ou nunca
tocou — e o jogador precisa ser destravado nos três; deixar o `Anchored = false` em um
caminho só era a maneira de a partida dele acabar ali. Por isso existe também o
`ANCHOR_TIMEOUT` (8 s): animação que não carrega nunca toca e, por isso, nunca
**para**, então o `Stopped` não vem. Preso alguns segundos é um defeito; preso para
sempre acaba a partida. O prazo é folgado de propósito — ele só precisa ser maior que
a animação mais longa que uma carta venha a ter.

A track sobe para `AnimationPriority.Action`: a prioridade vem assada no asset, e uma
exportada como `Idle` ou `Core` empataria com o que o `Animate` padrão já está
tocando — a carta seria usada e o boneco não faria nada.

O `VFXController` ganhou o par `AttachAsset` / `EmitAttached` para isso: pendurar e
estourar deixaram de ser o mesmo instante. O `playFreezeBurst`, que sempre fez as duas
coisas juntas, agora é uma linha em cima desse par.

O gesto sai na confirmação do servidor (`RoundCardUsed`), e não no clique: quem gasta
a carta é ele, e um uso recusado não pode deixar o personagem posando. **Só quem usou
vê o efeito completo** — o evento é individual. A animação replica sozinha, por tocar
no próprio personagem; o som e as partículas ficam no cliente de quem usou.

### O efeito entra junto com o estouro (`EffectDelay`)

O congelamento não cai no clique: ele espera o marcador `VFX`. No Time Stop são
0,917 s de animação antes de os inimigos travarem, e é isso que faz o efeito parecer
consequência do gesto em vez de coincidência.

**O atraso é do servidor, não do cliente.** Quem tem o marcador na mão é quem toca a
animação, mas quem executa efeito é o servidor — deixar o cliente dizer "agora" seria
deixá-lo escolher a hora de congelar a sala inteira, e a regra da seção *O cliente não
decide nada* vale aqui igual. O `CardShopService:Use` roda o efeito num `task.delay`
de `Visual.EffectDelay`; em **tempo real**, não pelo `GameClock`, porque a animação é
um gesto do personagem e não acelera com a partida.

O que **não** espera é o resto: a carta sai da mão e o `RoundCardUsed` dispara na
hora, senão o jogador clicaria de novo achando que o primeiro clique não pegou.

**O número é uma cópia, e cópia envelhece.** Reanimar a carta no Moon Animator move o
marcador e deixa o efeito entrando fora do gesto — sem erro no log, só torto na tela.
Por isso o `CardShopService:_auditEffectDelays` baixa a `KeyframeSequence` de cada
carta com `Visual` quando o servidor sobe, acha o marcador com parâmetro `"VFX"` e
avisa se ele estiver a mais de 0,05 s do `EffectDelay`. É o mesmo remédio do audit dos
nomes dos botões de dificuldade, pelo mesmo motivo: desencontro de config que não
levanta exceção nenhuma.

Ele **só avisa**. Não corrige o número com o que baixou — cronometrar o efeito da sala
por uma chamada web que pode falhar ou demorar seria pior que o desvio que ele pega —,
e falha de download passa calada.

O sorteio é com peso e **sem reposição**: a carta que sai deixa a urna e os pesos das
outras continuam valendo entre si, então uma carta rara não fica mais provável só
porque a comum já saiu. Catálogo menor que três mostra o que tem, em vez de repetir.

#### Time Stop

É o mesmo `StunnedUntil` que o gimmick do boss já usava: o laço do Heartbeat só soma
distância quando o relógio da partida passa dele. Os quatro segundos são de
**partida**, e não de tela — no 2x são dois segundos reais, como todo o resto do
gameplay. É o que faz o congelamento valer o mesmo tanto de caminho andado em
qualquer velocidade.

O `MobService.FreezeUntil` fica guardado no service porque a wave pode continuar
nascendo durante o congelamento: mob que nasce dentro da janela **já nasce parado**,
em vez de o Time Stop virar "para quem já estava no mapa". Dois Time Stops
sobrepostos estendem a janela, e um `FreezeToken` garante que só o último degelo
valha.

#### Time Acceleration

O 3x **não é um degrau** do `SpeedConfig` (que vai até 2x) e não tem arte. Ele entra
como um override: `SpeedService.Override` manda no `GameClock` por cima do degrau,
e a arte do botão `Interface.Speed` continua marcando a velocidade que a sala
escolheu — o botão continua servindo para voltar ao 1x depois.

Os 15 segundos são **reais**, e não de partida: um prazo medido no próprio relógio que
ele acelera duraria 5 segundos de tela. Vencido o prazo, o relógio volta ao degrau que
estiver valendo naquele momento, e não ao que valia na hora da compra — alguém pode
ter clicado no botão no meio.

O override tem o evento próprio `GameSpeedOverride`, separado do `GameSpeedChanged`,
porque as duas coisas convivem: o degrau desenha o botão, o override anda com o
relógio.

#### Weather Report

Limpa o céu e segura o próximo clima por uma wave
(`WeatherRoundService.SuppressedUntilWave`). Enquanto a janela vale, nada entra e
nada é sorteado — e o `ClearActive` roda a cada wave, então um clima ligado na mão
pelo comando `weather` também sai.

O `Clear` do `WeatherService` é chamado direto, e não o `ClearActive` daqui: aquele só
desliga o que o próprio service ligou, e a carta promete tirar a weather, seja de
onde ela vier.

**O aviso na tela não é cancelado.** O clima avisado continua agendado e entra na
primeira wave depois da janela: cancelar seria fazer o jogador pagar por um aviso que
ele viu e depois não aconteceu; adiar é o que a carta diz que faz.

A janela é contada da wave que está no ar. Comprada no meio da wave 5, ela cobre o
resto da 5 e a 6 inteira, e a 7 volta ao normal.

### A animação

1. **O botão entra pela direita.** O `RCSFrame` nasce em `Position.X.Scale = 1` e
   corre até o X que o designer deixou autorado, em `Circular` — ele chega devagar no
   fim, que é o que dá o encaixe na beirada em vez de o botão parar seco.
2. **Encaixado, ele fica balançando.** O `CardShop` sobe `IdleLift` pixels e ginga
   entre `+IdleSwing` e `-IdleSwing` graus, para sempre, num tween só com
   `repeatCount = -1` e `reverses = true`. É chamariz: a oferta vale poucas waves e
   o botão mora na beirada, onde é fácil não ver que ele chegou. O balanço só começa
   **depois** que o deslize termina — gingar durante a entrada faria o botão chegar
   torto.
3. **O clique recolhe o próprio botão e escurece a tela.** O `RCSFrame` volta para
   `X.Scale = 1` (e o `CardShop` desfaz a ginga, voltando à rotação e à altura
   autoradas em `IdleReturn`), o `Background` acende com `BackgroundTransparency` de
   1 até o valor autorado (0.5), e as cartas do jogador no `TowerContainer` apagam
   junto. O botão sai porque ele é o **atalho** para a oferta, e a oferta já está na
   tela inteira.
4. **As cartas caem, uma a cada 0,5s.** Cada `CardTemplate` desce de `DropOffset`
   alturas acima do lugar dele enquanto a **imagem** sai de transparente; só quando
   isso termina é que o conteúdo — título, descrição, preço, contornos, sombra — sobe
   de 1 até o valor autorado. Revelar tudo junto faria o texto aparecer boiando antes
   de existir carta por trás dele.
5. **O clique fora das cartas toca isso ao contrário.** O conteúdo desce de volta ao
   transparente (`CardReveal`) e só então a carta sobe apagando a imagem
   (`CardDrop`), uma a cada `CardExitStagger` — bem mais rápido que a entrada, porque
   aqui não há nada para ler. O escurecido sai em `BackgroundFadeOut`.
6. **A compra recolhe a loja.** O escurecido some na hora — sem fade, porque a compra
   já tem a animação dela.

**O botão é gasto na abertura, e não na compra.** Clicou uma vez, ele não volta nesta
oferta: nem depois do clique fora, nem depois de uma compra recusada, nem quando o
servidor reenvia o estado por outro motivo. Quem o acende de novo é uma oferta com
`token` diferente — a próxima wave de loja da dificuldade (`Intervals`), que é o
mesmo que dizer a próxima vez que o `CardShopService:Open` roda.

Isso mora no `OpenedToken`: o controller guarda o `token` da oferta que o jogador
abriu, e o `_applyState` só chama o `_showFrame` quando o `token` que chegou é outro.
Sair sem comprar continua sendo uma escolha, e não um engano a desfazer.

**Quem escuta o clique fora é o `UserInputService`.** O `Background` parecia o dono
natural do assunto — ele cobre a tela —, mas um `GuiObject` só recebe o clique que
ninguém mais quis: qualquer `ScreenGui` com `DisplayOrder` maior (o HUD, o container
da hotbar) come o clique antes dele, e a loja ficava aberta sem jeito de sair a não
ser comprando. O `UserInputService` vê o clique independentemente de quem o consumiu,
e a loja é modal: clique em lugar nenhum e clique em qualquer outra coisa fecham
igual. O que **não** fecha é o clique numa das três cartas — a carta marca o próprio
`InputObject` e a conferência sai um quadro depois, num `task.defer`, porque a ordem
entre os dois handlers do mesmo evento não é promessa de lugar nenhum.

O `Background` continua `Active`, agora só como barreira: é o que impede que o clique
dado com a loja aberta atravesse a tela e vire uma torre colocada no chão atrás dela.

Nada disso mede retângulo na tela — a conta entre `InputObject.Position` e
`AbsolutePosition` muda com o `IgnoreGuiInset` e com a barra do topo no celular, e a
comparação certa é a do próprio `InputObject`.

Carta que ainda estava caindo entra na saída do mesmo jeito: o atraso que não começou
é cancelado e a queda em andamento é cortada, então ela sobe do ponto onde estava.

As transparências de destino são lidas de **cada clone recém-feito**, antes de
qualquer animação: "voltar ao original" é literal, e repintar a carta no Studio basta.
`GuiObject.Transparency` fica de fora da lista de propósito (é apelido de
`BackgroundTransparency`, e os dois tweens brigariam pela mesma propriedade), e um
`Transparency` que não seja número também — o do `UIGradient` é uma `NumberSequence`.

O `CardWrapper` autorado dentro do `Background.RoundCardShop` **sai da tela** na
primeira vez que é preciso, virando molde — o mesmo que o `Components/Card` faz com o
`CardWrapper` da hotbar. O que fica na fileira é sempre 100% do que o servidor
sorteou.

A hotbar apaga pelo `Card:setHidden`, e não por um `Visible` escrito daqui — ver
[A carta na hotbar](#a-carta-na-hotbar).

### A carta na hotbar

Do lado da loja sai só a **aparência**: um clone do mesmo molde, no tamanho
`UDim2.fromScale(0.128, 1.07)` e **sem a placa de preço** — no deck a carta já foi
paga. A partir do `Card:addRound`, quem cuida dela é o componente `Components/Card`,
e ela vira uma carta da hotbar como qualquer outra: cai no arco, cresce no hover,
empurra e é empurrada pelas vizinhas, apaga quando outra carta é escolhida e ganha o
atalho de teclado da posição dela.

A diferença fica em dois campos do `entry`:

| Campo | Carta de unidade | Carta de round |
| --- | --- | --- |
| `Kind` | `"Unit"` | `"Round"` |
| `Unit` | o nome da unidade | `nil` |

`Unit` vazio é o que tira a carta de round de tudo que é do deck: preço, desconto de
clima, contador, estoque e a noção de "carta escolhida". Todo o resto é o mesmo
código.

**O `entry.Activate`.** O clique e o atalho de teclado deixaram de chamar
`callbackDo(entry.Unit)` e passaram a chamar `entry.Activate()`, que cada origem
preenche: a carta de unidade equipa a unidade, a de round pede o uso ao servidor. Era
isso ou a hotbar passar a saber o que uma carta de loja faz.

**`_isSelected`.** A conta de "esta é a carta na mão" ganhou um `entry.Unit ~= nil`.
Sem essa metade, `nil == nil` daria "escolhida" para **todas** as cartas de round
sempre que não houvesse nenhuma unidade equipada — as três cresceriam para
`SELECTED_SCALE` sozinhas.

**Duas normalizações no `addRound`.** O molde da loja ancora a carta no canto
(`0, 0`) e o da hotbar no centro. Sem trocar isso, a inclinação do arco giraria a
carta em torno do canto superior esquerdo dela, e o crescer do hover a empurraria
para o lado em vez de crescer no lugar.

**A entrada e a saída são as que o componente já tinha.** Ela chega fora da mão e
**sobe** para a vaga (`RESTORE_INFO`, o mesmo caminho de uma carta que voltou a ter
estoque), abrindo espaço nas vizinhas; usada, ela **cai** para fora (`EXIT_INFO`), e
a vaga só fecha quando ela termina de cair — o `entry` sai da lista no fim da queda,
e não no começo, senão o deck se reacomodaria por baixo de uma carta que ainda está
na tela.

**O `clean` poupa as cartas de round.** `set` é "redesenhe a hotbar a partir do
deck", e uma carta comprada não veio do deck: destruí-la ali faria trocar de unidade
no meio da partida evaporar uma carta que o jogador pagou. Elas voltam para a fila
**depois** das de unidade — a ordem dos slots é a do deck —, e o `_reindex` reescreve
o `LayoutOrder` de todo mundo. Quem quer a mão inteira vazia chama `destroy`.

**Esconder a mão é do componente.** Enquanto a aba da loja está aberta, o
`Card:setHidden(true)` apaga todas as cartas sem ninguém perder o lugar: cada `entry`
guarda a intenção em `Present` ("esta carta deveria estar na mão?") e o `hidden` passa
por cima. Escrever `Visible` de fora acenderia de volta, na saída da loja, uma carta
que o deck tinha derrubado por falta de unidade.

Some por dentro, e não pelo `Visible` do `TowerContainer`: quem manda no container é o
`DifficultyController` (a hotbar só aparece com a dificuldade decidida), e duas mãos
no mesmo interruptor acabariam com a hotbar sumindo no meio da partida.

### O cliente não decide nada

O cliente não sorteia, não cobra e não executa efeito nenhum. Ele manda "quero comprar
a carta X da oferta com token T" e "quero usar a carta de id U"; o servidor confere as
duas coisas contra o que ele mesmo guardou.

| Conferência | O que ela pega |
| --- | --- |
| oferta existe | clique depois de a loja ter fechado |
| `Token` bate | clique atrasado numa oferta que a wave seguinte já substituiu |
| carta estava naquela oferta | id trocado na mão |
| dinheiro dá | duas compras no mesmo instante |
| `uid` está com o jogador | uso de carta que já foi gasta |

O `uid` é por compra, e não por carta: a mesma carta pode ser comprada duas vezes em
ofertas diferentes, e usar uma não pode gastar a outra.

A carta **só entra na hotbar quando o `RoundCardBought` confirma**, e só sai quando o
`RoundCardUsed` confirma. Recusada, o `RoundCardState` que chega em seguida devolve a
tela ao que o servidor sabe — e a oferta reaparece. O `RequestRoundCardState` do bind
cobre quem entra no meio de uma oferta aberta ou recarrega a interface: sem ele, as
cartas já compradas sumiriam da hotbar dele.

O `CardShopService` está na lista de round-scoped do `WaveService`: as cartas são de
partida, e não há o que carregar para a próxima nem oferta que sobreviva à tela de
resultado.

### O comando

```
roundshop [players]
```

Abre a oferta na hora, sem esperar a wave certa, e re-sorteia as três cartas. Sem
argumento, para a sala inteira. Aliases: `cardshop`, `rcs`.

### Feito no Studio

O `RoundCardShop` estava com `ResetOnSpawn = true` e `DisplayOrder = 0`. Virou
`false` e `1`: com o reset, a GUI seria recriada a cada respawn e o controller
ficaria segurando um `RCSFrame` que não está mais na tela; com o `DisplayOrder` zero,
o escurecido dividia camada com a `Interface`.

## Bug conhecido (não corrigido)

`src/Controllers/UILibraryController/Components/Wave.luau` → `module:destroy()`
referencia `CardUpgrade`, que não existe nesse arquivo (é uma colagem do
`ToggleTower.luau`). Estoura se `destroy()` for chamado.

## Lixo no Workspace (não tocado)

28 modelos de inimigos/unidades soltos (Azuron x4, Rocketeer x3, Azure x2, sword,
slasher, slingshot, …, ~7.000 instâncias, sem tags) e as ScreenGuis vazias
`Cards` e `Upgrade`.
