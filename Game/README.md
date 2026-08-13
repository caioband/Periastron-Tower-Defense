# Periastron Tower Defense — Game

Código-fonte da place **"Periastron TD: Main Game"**, extraído do Studio e organizado
na mesma arquitetura Rojo usada em [`../Lobby`](../Lobby).

## Setup

```bash
aftman install     # rojo 7.6.1
wally install      # OBRIGATÓRIO: gera ./Packages (Promise, Signal, topbarplus)
rojo serve         # conecta pelo plugin do Rojo no Studio
```

> `Packages/` é gitignorado. Sem `wally install` o sync quebra — nem
> `ReplicatedStorage.Packages` nem o Satchel resolvem.

## Arquitetura

Idêntica à do Lobby. O carregador é o `Me` (`vendor/shared/Me.luau`): `Me.new()`
faz `require` de **todo ModuleScript** dentro de `Services` (server) e
`Controllers` (client), e chama `:init()` e depois `:start()` em cada um.

| No Studio                                | No repo                | Contém                                              |
| ---------------------------------------- | ---------------------- | --------------------------------------------------- |
| `ReplicatedStorage.Shared.Vendor`        | `vendor/shared`        | Me, Warp, Maid, Spring, Observers, ReplicaClient     |
| `ReplicatedStorage.ReplicaShared`        | `vendor/ReplicaShared` | Maid, RateLimit, Remote, Signal (deps do Replica)    |
| `ServerScriptService.Vendor`             | `vendor/server`        | ProfileStore, ReplicaServer                          |
| `ReplicatedStorage.Packages`             | `Packages/` (wally)    | **somente** Promise, Signal, topbarplus              |
| `ReplicatedStorage.Shared.{Config,Util,Classes}` | `src/shared/`  | código compartilhado                                 |
| `ServerScriptService.{Server,Services}`  | `src/server/`          | bootstrap + serviços                                 |
| `StarterPlayer.StarterPlayerScripts.Client` | `src/client/`       | bootstrap + controllers                              |

Convenção de `require` (a mesma dos dois places):

```lua
local Packages = ReplicatedStorage:WaitForChild("Packages")
local ServerVendor = ServerScriptService:WaitForChild("Vendor")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)        -- vendor  -> Shared.Vendor
local Promise = require(Packages.Promise) -- wally   -> Packages
local Replica = require(ServerVendor.ReplicaServer)
```

### Não versionado aqui

`ReplicatedStorage.Shared.Assets` (~8.200 instâncias: modelos, UI, VFX, animações)
e as ScreenGuis de `StarterGui` continuam vivendo só na place — são conteúdo
binário, não código. Por isso todos os nós do `default.project.json` usam
`$ignoreUnknownInstances: true`, e o sync do Rojo não os apaga.

## Diferenças propositais em relação à place

`src/client/Satchel/Packages/topbarplus.luau` é um shim para
`ReplicatedStorage.Packages.topbarplus` (vindo do wally), enquanto a place ainda
carrega o topbarplus vendorizado em `Satchel/Packages/_Index`. É a mesma
readaptação já feita no Lobby — as duas cópias do topbarplus são a 3.4.0,
byte-a-byte idênticas.

## Problemas conhecidos (pré-existentes, não corrigidos)

- `src/server/Server/ExampleService.luau` faz `require(Configs.Shared)`, mas a
  pasta se chama `SharedConfig`. Nunca estoura porque esse módulo não é
  requerido por ninguém — o `Me` só varre `Services/`, não `Server/`. O Lobby
  tem exatamente o mesmo erro no mesmo arquivo.
- `src/client/Controllers/UILibraryController/Components/Wave.luau` →
  `module:destroy()` referencia `CardUpgrade`, que não existe nesse arquivo
  (é uma cópia colada do `ToggleTower.luau`). Estoura se `destroy()` for chamado.
- `ExampleService` / `ExampleController` são scaffolding vazio do framework.
  São carregados pelo `Me` mas não fazem nada. Mantidos porque o Lobby também os tem.
