# Periastron Tower Defense — Lobby

Código do place **Lobby**, extraído do Roblox Studio e organizado para Rojo + Wally.

## Setup

```bash
rokit install        # (ou aftman install)
wally install        # cria Packages/ com Promise, Signal e topbarplus
rojo serve           # conecta pelo plugin do Rojo no Studio
```

## Estrutura

| Pasta | Vai para | O que é |
|---|---|---|
| `src/shared/` | `ReplicatedStorage.Shared` | Config, Util e Classes |
| `src/server/Server/` | `ServerScriptService.Server` | Script de entrada do servidor |
| `src/server/Services/` | `ServerScriptService.Services` | Serviços carregados pelo `Me` |
| `src/client/` | `StarterPlayer.StarterPlayerScripts.Client` | LocalScript de entrada + Controllers + Satchel |
| `vendor/shared/` | `ReplicatedStorage.Shared.Vendor` | Libs de terceiros que não estão no Wally + o framework `Me` |
| `vendor/ReplicaShared/` | `ReplicatedStorage.ReplicaShared` | Parte compartilhada do Replica (caminho fixo, não mover) |
| `vendor/server/` | `ServerScriptService.Vendor` | ProfileStore e ReplicaServer |
| `Packages/` | `ReplicatedStorage.Packages` | Gerado pelo `wally install` (gitignorado) |

## Dependências

**Wally** (`wally.toml`) — só o que o código realmente usa:

| Pacote | Versão | Usado por |
|---|---|---|
| `evaera/promise` | 4.0.0 | quase todos os services/controllers |
| `sleitnick/signal` | 2.0.1 | `DataService`, `DataController` |
| `1foreverhd/topbarplus` | 3.4.0 | Satchel |

Estavam instalados no place mas **nenhum script first-party requer**, então saíram:
`Comm`, `Component`, `EnumList`, `Input`, `Option`, `Streamable`, `TableUtil`, `Timer`, `Trove`.

**Vendorizados** (não vieram do Wally no place — foram colados na mão):

| Lib | Onde | Origem |
|---|---|---|
| Me (framework) | `vendor/shared/Me.luau` | @raiarxyzdev |
| Warp 1.0.14 | `vendor/shared/Warp` | @Eternity_Devs |
| Maid | `vendor/shared/Maid.luau` | Quenty-style |
| Spring (`spr`) | `vendor/shared/Spring.luau` | Fraktality/spr |
| Observers | `vendor/shared/Observers` | sleitnick/observers |
| Replica | `vendor/shared/ReplicaClient.luau`, `vendor/ReplicaShared/`, `vendor/server/ReplicaServer.luau` | MAD STUDIO |
| ProfileStore | `vendor/server/ProfileStore.luau` | MAD STUDIO (loleris) |
| Satchel 1.4.1 | `src/client/Satchel/` | @WinnersTakesAll (MPL-2.0) |

> `ReplicaClient` e `ReplicaServer` fazem `game.ReplicatedStorage.ReplicaShared` **hardcoded**.
> Por isso `vendor/ReplicaShared` é mapeado exatamente nesse caminho — não renomeie.

## Readaptações feitas na extração

O `Me` não é pacote Wally, então saiu de `ReplicatedStorage.Packages` (pasta que o
`wally install` sobrescreve) e foi para `ReplicatedStorage.Shared.Vendor.Me`. As libs
vendorizadas saíram de `Packages` pelo mesmo motivo e foram para o mesmo
`ReplicatedStorage.Shared.Vendor`.

```lua
-- antes
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Me    = require(Packages.Me)
local Maid  = require(Packages.Maid)
local Warp  = require(Packages.Warp)

-- depois
local Packages = ReplicatedStorage:WaitForChild("Packages")   -- wally
local Shared   = ReplicatedStorage:WaitForChild("Shared")     -- codigo do jogo
local Vendor   = Shared:WaitForChild("Vendor")                -- vendorizado

local Me    = require(Vendor.Me)
local Maid  = require(Vendor.Maid)
local Warp  = require(Vendor.Warp)
local Promise = require(Packages.Promise)                     -- continua no wally
```

No servidor, `ServerScriptService.Packages` virou `ServerScriptService.Vendor`
(`ProfileStore`, `ReplicaServer`).

Dentro do Satchel, `Packages/topbarplus` era o link do Wally para o `_Index` local;
agora aponta para `ReplicatedStorage.Packages.topbarplus` (o do `wally.toml`).

## Antes do primeiro sync — limpar o place

O `default.project.json` usa `$ignoreUnknownInstances: true` para não apagar os
assets/GUI que não estão no repo. O efeito colateral é que as cópias antigas
**não** são removidas sozinhas. Antes de sincronizar, apague no Studio:

- `ReplicatedStorage.Packages` inteira (o `wally install` recria a parte que importa)
- `ReplicatedStorage.ReplicaShared`
- `ServerScriptService.Packages`
- `ServerScriptService.Server`, `ServerScriptService.Services`
- `StarterPlayer.StarterPlayerScripts.Client`

Se `ProfileStore`/`ReplicaServer` ficarem duplicados (velho + novo), você terá
**duas instâncias de estado** rodando ao mesmo tempo — session lock e replicação
vão brigar entre si.

## O que ficou de fora do repo (de propósito)

| Item | Por quê |
|---|---|
| `ReplicatedStorage.Shared.Assets` | São Models/Parts/Animations, não código. Continuam no place. |
| `StarterGui.HUD` / `StarterGui.crateui` | Instâncias de GUI. O script `HUD.BackpackToggle` está em `src/startergui/HUD/` mas **não** é mapeado pelo Rojo — a ScreenGui vive no place. Para versionar, exporte como `.rbxmx`. |
| `StarterPlayerScripts.PlayerModule` | Código stock da Roblox. |
| `StarterCharacterScripts.Animate` | Código stock da Roblox. |
| `ServerStorage.Lunar_VFX_Scripts` | Readme de asset de terceiro. |
| `Shared.Classes.Unit.Attacks` | Pasta vazia, sem referências no código. |

⚠️ `ReplicatedStorage.Shared` tem um **PackageLink** (é um Roblox Package). Sincronizar
por cima vai marcar o package como modificado no Studio.

## Achados durante a extração

- `ServerScriptService.Server.ExampleService` (`src/server/Server/ExampleService.luau`)
  é código morto: está fora de `Services`, então o `Me:Load()` nunca o carrega, e ele
  requer `Configs.Shared` — módulo que não existe (o certo é `Configs.SharedConfig`).
  Foi portado verbatim, com um comentário no topo.
- `Shared.Classes.Unit` chama `Framework:Get("ProjectileController")` e
  `Framework:Get("VFXController")`, que não existem neste place — retornam `nil`.
