# Game — "Periastron TD: Main Game"

Ver o [README da raiz](../README.md) para a arquitetura, o setup e o que é
compartilhado entre as duas places. Aqui fica só o que é exclusivo deste place.

## O que é só daqui

| Pasta | Vai para | Conteúdo |
|---|---|---|
| `src/ClientBoot/` | `StarterPlayerScripts.Client` | LocalScript de entrada |
| `src/Controllers/` | `Client.Controllers.Game` | Card, Difficulty, Loading, Mob, Music, Projectile, Ready, Targeting, Tripmine, UILibrary, UnitPlacement, VFX, Wave |
| `src/Services/` | `ServerScriptService.Services.Game` | Data, Difficulty, Map, Mob, Thunder, Unit, Wave |
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

## Card de upgrade (`StarterGui.Interface.CardUpgrade`)

O componente `UILibraryController/Components/ToggleTower.luau` preenche o card da
unidade selecionada. Cada TextLabel do StarterGui já traz o sufixo desenhado
(`DPS`, `COOLDOWN`, `RANGE`, `DMG DONE`) e o componente só troca o número:

| Label | Fonte |
|---|---|
| `Info.UnitName` / `Info.UnitLevel` | nome do modelo e atributo `Upgrades` |
| `UpgradeCost.TextLabel` | `UnitUpgradeConfig:GetCost`, ou `MAX` no último nível |
| `Sell.TextLabel` | `GetInvested` × `SharedConfig.SellRefundRatio` |
| `DamagePerSecond` | `GetDPS` (dano × hits ÷ cooldown); em unidade de farm, a renda por wave |
| `AttackSpeed` | `GetCooldown`, em segundos |
| `Range` | `GetRange` |
| `DmgDone` | atributo `DamageDone` do modelo |

Tudo menos o `DmgDone` sai do `UnitUpgradeConfig` — o cliente refaz a mesma conta
do servidor a partir do nível, então não precisa de replicação. O `DmgDone` só o
servidor sabe: `MobService:DamageMob` devolve o dano que de fato entrou no mob,
`UnitService:addDamageDone` acumula em `entry.damageDone` e um flush a cada 0,25 s
manda um lote `unitId -> total` (`UnitDamageStats`) para todos os jogadores —
qualquer um pode selecionar qualquer unidade. Quem entra no meio da partida recebe
o total de todas as unidades junto do `ClientReady`. No cliente, o
`UnitPlacementController` grava o valor no atributo `DamageDone` do modelo, e o
card reage pelo `GetAttributeChangedSignal`.

O botão `Priority` continua sem função: não existe sistema de prioridade de alvo
no jogo (o `TargetingController` sempre pega o primeiro mob no alcance), então o
texto `First [V]` segue sendo o placeholder do StarterGui.

## Bug conhecido (não corrigido)

`src/Controllers/UILibraryController/Components/Wave.luau` → `module:destroy()`
referencia `CardUpgrade`, que não existe nesse arquivo (é uma colagem do
`ToggleTower.luau`). Estoura se `destroy()` for chamado.

## Lixo no Workspace (não tocado)

28 modelos de inimigos/unidades soltos (Azuron x4, Rocketeer x3, Azure x2, sword,
slasher, slingshot, …, ~7.000 instâncias, sem tags) e as ScreenGuis vazias
`Cards` e `Upgrade`.
