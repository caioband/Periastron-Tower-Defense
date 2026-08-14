# Periastron Tower Defense

Monorepo das duas places do jogo. O código que as duas usam mora na raiz; cada
place guarda só o que é dela.

```
common/     código first-party compartilhado pelas duas places
vendor/     libs de terceiros (não vêm do Wally)
Game/       place "Periastron TD: Main Game"  — só o que é exclusivo dela
Lobby/      place "Lobby"                     — só o que é exclusivo dela
```

## Setup

```bash
aftman install                      # rojo 7.6.1 + wally
cd Game   && wally install && rojo serve      # ou
cd Lobby  && wally install && rojo serve
```

`Packages/` é gerado pelo Wally dentro de cada place e é gitignorado. Sem
`wally install` o sync quebra.

## Como o compartilhado é montado

Os `default.project.json` das duas places apontam para a raiz com `../`. Onde uma
pasta mistura código comum e código da place, ela vira um Folder com duas
subpastas — o `Me:Load()` varre com `GetDescendants()`, então os módulos carregam
igual e `Framework:Get("NomeDoModulo")` continua funcionando sem mudança.

```
StarterPlayerScripts.Client (LocalScript)   <- <place>/src/ClientBoot
├── Satchel                                 <- common/client/Satchel
└── Controllers
    ├── Common                              <- common/client/Controllers
    └── Game | Lobby                        <- <place>/src/Controllers

ServerScriptService
├── Server (Script)                         <- common/server/Server
├── Config (ModuleScript)                   <- common/server/Config      [SÓ SERVIDOR]
├── Vendor                                  <- vendor/server
├── CmdrDefinitions        (só no Lobby)    <- Lobby/src/CmdrDefinitions
└── Services
    ├── Common                              <- common/server/Services
    └── Game | Lobby                        <- <place>/src/Services

ReplicatedStorage
├── Packages                                <- <place>/Packages   (wally)
├── ReplicaShared                           <- vendor/ReplicaShared
└── Shared
    ├── Vendor                              <- vendor/shared
    ├── Config                              <- common/shared/Config
    ├── Util                                <- common/shared/Util
    ├── Classes                             <- common/shared/Classes
    └── Assets                              (fica só na place — é conteúdo, não código)
```

> ⚠️ Rojo **não faz merge** de `$path` com filhos declarados no mesmo nó — ele cria
> duas instâncias com o mesmo nome. É por isso que `Controllers`/`Services` são
> Folders declarados com duas subpastas, e que `src/ClientBoot/` contém *apenas*
> o `init.client.luau`.

> ⚠️ `$ignoreUnknownInstances` tem default **`true`** em nó sem `$path` e `false`
> em nó com `$path`. Como `Controllers` e `Services` são declarados só com
> `$className`, eles herdariam `true` — o Rojo adicionaria as subpastas novas mas
> **nunca removeria** os scripts antigos soltos, e a place rodaria com as duas
> versões ao mesmo tempo. Por isso os dois nós trazem `"$ignoreUnknownInstances": false`
> explícito. Vale a regra: todo nó container do projeto declara o flag na mão.

## Configuração: o que é replicado e o que não é

Antes, `ReplicatedStorage.Shared.Config.Server` era replicado para todo cliente —
incluindo chave de DataStore, template de perfil, tabelas de wave, odds de summon
e a lista de admins do Cmdr. Isso foi separado:

| | Onde | Conteúdo |
|---|---|---|
| **Servidor** | `ServerScriptService.Config` ← `common/server/Config` | `Data` (PROFILE_KEY + template), `Wave`, `Summon`, `Difficulty`, `Cmdr` (ADMIN_USER_IDS, GROUP_ID, ALLOW_IN_STUDIO) |
| **Compartilhado** | `ReplicatedStorage.Shared.Config` ← `common/shared/Config` | `Client`, `SharedConfig` (UnitStats, UnitAttackConfig, UnitUpgradeConfig, UnitVFXConfig, CrateConfig, MapConfig, PortalConfig, `Mob`, `Cmdr` cosmético) |

Convenção nos scripts de servidor:

```lua
local ServerScriptService = game:GetService("ServerScriptService")

local Configs      = Shared:WaitForChild("Config")            -- replicado
local ServerConfigs = ServerScriptService:WaitForChild("Config") -- só servidor
local ServerVendor  = ServerScriptService:WaitForChild("Vendor")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)
```

Dois consumidores de cliente foram ajustados nessa mudança:

- **`MobController`** (Game) lia `Config.Server.Mob` para escolher a animação de
  andar. `Mob.luau` passou para `SharedConfig` — são stats de apresentação, e o
  cliente já recebe `Speed`/`MaxHealth` de cada mob no pacote de spawn.
- **`CmdrController`** (Lobby) lia `ADMIN_USER_IDS` direto. Agora só as partes
  cosméticas (`ACTIVATION_KEYS`, `PLACE_NAME`) são replicadas, e o console começa
  desabilitado até o servidor responder ao evento `RequestCmdrAccess`. A
  autorização de verdade sempre foi (e continua sendo) o hook `BeforeRun` do
  `CmdrService`.

## Verificação depois de mexer na estrutura

`rojo build` só prova que o projeto monta — **não** pega caminho relativo quebrado.
Módulo que anda de lugar e usa `script.Parent` é a armadilha: o `Config/Data.luau`
fazia `script.Parent.Parent` contando estar em `Shared.Config`, e ao ir para
`ServerScriptService.Config` travou num `WaitForChild` eterno. Como todo Service
requer o config no topo do arquivo, o `Me:Load()` do servidor nunca terminava e
**nenhum** evento do servidor era registrado — o sintoma aparecia no cliente,
dezenas de `Serdes: X is taking too long to retrieve`.

Depois de mover qualquer coisa, dê Play e confira no servidor:

```lua
local Me = require(game.ReplicatedStorage.Shared.Vendor.Me)
local n = 0
for _ in pairs(Me.new().Loaded) do n += 1 end
print("services carregados:", n)   -- Game: 9   Lobby: 9
```

Se vier menos que o esperado, algum módulo travou num `WaitForChild` — procure
por `script.Parent` no que você moveu.

## Libs vendorizadas (`vendor/`)

Não vieram do Wally — foram coladas na mão no place original.

| Lib | Onde | Origem |
|---|---|---|
| Me (framework) | `vendor/shared/Me.luau` | @raiarxyzdev |
| Warp 1.0.14 | `vendor/shared/Warp` | @Eternity_Devs |
| Maid | `vendor/shared/Maid.luau` | Quenty-style |
| Spring (`spr`) | `vendor/shared/Spring.luau` | Fraktality/spr |
| Observers | `vendor/shared/Observers` | sleitnick/observers |
| Replica | `vendor/shared/ReplicaClient.luau`, `vendor/ReplicaShared/`, `vendor/server/ReplicaServer.luau` | MAD STUDIO |
| ProfileStore | `vendor/server/ProfileStore.luau` | MAD STUDIO (loleris) |
| Satchel 1.4.1 | `common/client/Satchel/` | @WinnersTakesAll (MPL-2.0) |

> `ReplicaClient` e `ReplicaServer` fazem `game.ReplicatedStorage.ReplicaShared`
> **hardcoded**. Por isso `vendor/ReplicaShared` é mapeado exatamente nesse
> caminho nas duas places — não renomeie.

## O framework `Me`

`Me.new()` faz `require` de **todo ModuleScript** dentro de
`ServerScriptService.Services` (servidor) e `Client.Controllers` (cliente),
depois chama `:init()` e em seguida `:start()` em cada um. Módulos se enxergam
por nome via `Framework:Get("NomeDoModulo")` — nomes precisam ser únicos entre
`Common` e a pasta da place.

## O que ainda difere entre as places (de propósito)

| Arquivo | Por quê |
|---|---|
| `src/ClientBoot/init.client.luau` | O Lobby dispara `Framework:Fire("Loaded", true)`; no Game quem dispara é o `WaveController`. |
| `src/Services/DataService.luau` | O Lobby espera a tag `Loaded` antes de entregar o perfil; o Game responde direto e tem `:Save()`. |
| `src/Controllers/UILibraryController/` | UIs diferentes. |
