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

## Achado

`Shared.Classes.Unit` chama `Framework:Get("ProjectileController")` e
`Framework:Get("VFXController")`, que não existem neste place — retornam `nil`.
(Existem no Game.)
