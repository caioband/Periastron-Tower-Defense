# Lobby

Ver o [README da raiz](../README.md) para a arquitetura, o setup e o que é
compartilhado entre as duas places. Aqui fica só o que é exclusivo deste place.

## O que é só daqui

| Pasta | Vai para | Conteúdo |
|---|---|---|
| `src/ClientBoot/` | `StarterPlayerScripts.Client` | LocalScript de entrada |
| `src/Controllers/` | `Client.Controllers.Lobby` | Cmdr, Crate, UILibrary |
| `src/Services/` | `ServerScriptService.Services.Lobby` | Cmdr, Crate, Data, Summoning, TeleportToGame |
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
| `StarterGui.HUD` / `StarterGui.crateui` | Instâncias de GUI — para versionar, exporte como `.rbxmx` |
| `StarterPlayerScripts.PlayerModule` | Código stock da Roblox |
| `StarterCharacterScripts.Animate` | Código stock da Roblox |
| `ServerStorage.Lunar_VFX_Scripts` | Readme de asset de terceiro |

⚠️ `ReplicatedStorage.Shared` tem um **PackageLink** (é um Roblox Package).
Sincronizar por cima marca o package como modificado no Studio.

## Achado

`Shared.Classes.Unit` chama `Framework:Get("ProjectileController")` e
`Framework:Get("VFXController")`, que não existem neste place — retornam `nil`.
(Existem no Game.)
