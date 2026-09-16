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
├── CmdrDefinitions
│   ├── Types
│   │   ├── Common                          <- common/server/CmdrDefinitions/Types
│   │   └── Game | Lobby                    <- <place>/src/CmdrDefinitions/Types
│   └── Commands
│       ├── Common                          <- common/server/CmdrDefinitions/Commands
│       └── Game | Lobby                    <- <place>/src/CmdrDefinitions/Commands
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

### Som

`SoundService.SharedSounds` é um Package (não passa pelo Rojo) com `Musics` e
`SFX` dentro. Todo áudio passa pelo `MusicController`
(`common/client/Controllers`), que acha o `Sound` pelo nome em qualquer subpasta
— nada mais lê a raiz do `SoundService` direto.

```lua
local Sound = Framework:Get("MusicController")

Sound:Transition("Snowy", 2)                              -- crossfade de música
Sound:Duck(0.3)                                           -- abaixa pra cutscene, :Unduck() devolve
Sound:PlaySFX("UnitPlace")                                -- efeito 2D
Sound:PlaySFX("SubspaceTripmineSFX", { Parent = root,     -- 3D, e a Key derruba
                                       Key = "Tripmine" })--   o som anterior da mesma chave
Sound:PlaySFX("Thunderstorm", { Looped = true,            -- ambiente: entra com fade
                                Key = "WeatherAmbience",
                                Fade = 2 })
Sound:StopSFX("WeatherAmbience", 2)                       -- e sai com fade
Sound:PlaySFX("Thunder", { FadeOut = 1 })                 -- cauda suavizada no fim
```

`Fade` e `FadeOut` valem para SFX também, não só para música. O `FadeOut` termina
junto com o som (ou com o `Cut`), não depois: num clipe de 3,63s com `FadeOut = 1` o
fade começa em 2,63s. O `StopSFX` sem tempo continua cortando seco — é o que o
`PlaySFX` usa quando a mesma `Key` é reaproveitada, para o som novo entrar na hora.

Música toca a instância original (o volume do Studio é o base; fade, master,
mute e duck multiplicam em cima). SFX sempre toca um clone que se destrói no
fim, pra dois efeitos iguais poderem se sobrepor.

### Passos

`FootstepController` (`common/client/Controllers`) é client-only e roda nas duas
places. Ele não usa timer: quem marca o compasso é um Animation Event
(KeyframeMarker) chamado **`Step`** dentro das animações de Walk e Run. Toda
animação que tiver esse marcador entra no sistema sozinha — não há lista de
animações no código. O marcador pode carregar `"Left"` ou `"Right"` pra fixar o
pé; sem valor, o controller alterna.

A superfície **não** vem do `Material` (o jogo é stud, o Material não diz nada):
vem do atributo `Surface` da Part que o raio embaixo do pé acertar. O atributo é
procurado também nos pais, então dá pra marcar um Model inteiro de uma vez:

```lua
part:SetAttribute("Surface", "Grass")   -- ou no Model que contém as parts
```

Os ids de cada superfície ficam em `SharedConfig.FootstepConfig`, com uma lista
de variações por superfície (sorteia uma por passo, sem repetir a anterior).
Part sem o atributo fica em silêncio de propósito — assim o que falta marcar
aparece, em vez de virar grama por engano.

### Lighting

Um preset é uma Folder em `ReplicatedStorage.Shared.Assets.Lighting`. Os
**atributos** dela são as propriedades do próprio `Lighting`; os **filhos** são as
instâncias que vão para dentro dele:

```
Assets.Lighting
└── Blizzard              (Folder)  atributos: Ambient, Brightness, ClockTime, FogColor…
    ├── Atmosphere        (Atmosphere)
    ├── Sky               (Sky)
    └── ColorCorrection   (ColorCorrectionEffect)
```

`LightingService` (`common/server/Services`) clona a pasta, limpa o `Lighting` e
joga o conteúdo do clone lá dentro. O corte é seco: o servidor é a verdade, e quem
entra no meio da partida tem que receber o estado final direto.

```lua
local LightingService = Framework:Get("LightingService")

LightingService:Apply("Blizzard")       -- transição no tempo padrão
LightingService:Apply("Foggy", 4)       -- transição de 4s
LightingService:Apply("Foggy", 0)       -- sem transição
```

`LightingController` (`common/client/Controllers`) é quem suaviza. No aviso de
troca ele devolve as propriedades ao valor do preset anterior e interpola até o
novo — number, Color3, Vector3, UDim, NumberRange, Rect e CFrame. O que não
interpola (boolean, string, EnumItem, sequences) é corte: **ligar** entra no
começo da transição, **desligar** espera o fim, para o efeito participar dela.

A origem da interpolação é o estado que o próprio controller escreveu por último,
não o que está no `Lighting` na hora: quando o aviso chega, o valor novo já pode
ter replicado por cima. O destino vem da Folder do preset, pela mesma razão.
Transição interrompida no meio congela onde está e vira a origem da seguinte, em
vez de saltar para trás.

Instância que existe nos dois presets **com o mesmo nome e a mesma classe** é
interpolada valor a valor. A que existe só num dos lados **entra e sai
interpolando também**, e não piscando: `LightingConfig.Neutral` diz, por classe,
quais propriedades significam "este efeito não está fazendo nada"
(`BlurEffect.Size = 0`, `Atmosphere.Density = 0`, …). Quem entra começa no neutro e
sobe até o valor do preset; quem sai é recriado como uma cópia local — o servidor já
destruiu a original — que desce até o neutro e é destruída no fim.

Isso pesa mais do que parece: trocar de mapa mexe muito mais em *quais* efeitos
existem do que nos valores dos que continuam existindo. Sem o neutro, a maior parte
da mudança visual de uma troca é corte seco — nas iluminações dos mapas de hoje é a
diferença entre 1 e 7 propriedades interpolando num `Snowy -> Volcano`. Classe sem
neutro (`Sky`) continua entrando de uma vez, que é o certo: textura não tem
meio-caminho.

`SharedConfig.LightingConfig` tem o tempo/easing padrão, a lista de propriedades por
classe e a tabela de neutros. A lista é na mão porque Roblox não tem reflection em
runtime; classe que não estiver lá entra no `Lighting` normalmente, só não é
interpolada. No Studio o controller loga quantas propriedades entraram em cada
transição, porque "interpolou pouco" e "não interpolou" são indistinguíveis na tela.

Duas conveniências: Folder solta dentro do `Lighting` é adotada como preset na
entrada do servidor (é como a Main Game guarda `FoggyLightning` e
`BlizzardLightning` — não precisa mover nada na place), e o que sobrar vira o
preset `Default`, para a primeira troca já ter de onde sair. Filho do `Lighting`
com o atributo `LightingKeep = true` sobrevive ao clear — e as **duas** pontas o
respeitam: o `LightingService` pula esses filhos na varredura, e o
`LightingController` os deixa fora do estado que ele lê para a transição. Sem a
segunda metade, um efeito que não é de preset nenhum (o `UIBlur` que a loja acende
atrás do painel) viraria efeito *de saída* na próxima troca de preset, e um fantasma
dele apareceria por cima do que o painel está usando.

#### Comandos (Cmdr, nas duas places)

```
lighting <preset> [segundos]         troca o preset; tab completa os nomes
                                     segundos omitido = padrão do config, 0 = corte seco
lightinglist                         lista o que existe em Assets.Lighting
weather <clima|off> [segundos]       liga o clima no mapa carregado; off desliga
restartwarning <motivo> [seg]        ensaia o aviso de restart do servidor (não reinicia nada)
cash <ação> <jogadores> <valor>      Cash salvo (Stats.Cash), o do lobby
shards <ação> <jogadores> <valor>    Shards salvos (Stats.Shards)
roundcash <ação> <jogadores> <valor> (só na Game) o dinheiro que paga as torres na partida
strike [unidade]                     (só na Game) derruba um raio numa unidade posicionada
units <ação> <jogadores> <unidade> [qtd]  o inventário salvo de unidades (Units do perfil)
```

**Quem pode rodar comando.** A permissão é do servidor: o hook `BeforeRun` chama
`CmdrService:IsAdmin` a cada comando, e o cliente só usa a mesma resposta para
decidir se mostra o console. Vale, nesta ordem:

| Caminho | Onde se configura |
|---|---|
| Studio | `ALLOW_IN_STUDIO` |
| Lista de ids | `ADMIN_USER_IDS` |
| Dono da place | automático — pessoa, ou rank ≥ `CREATOR_GROUP_MIN_RANK` no grupo dono |
| Grupo extra | `GROUP_ID` + `GROUP_MIN_RANK` |

O caso do **grupo dono** é o que fazia os comandos não funcionarem em jogo: esta
place pertence a um grupo, então `game.CreatorId` é o id do **grupo**, e o teste
antigo (`CreatorType == User and UserId == CreatorId`) não passava para ninguém.
Como `ALLOW_IN_STUDIO` só vale no Studio e a lista de ids estava vazia, o console
funcionava no teste e não em jogo. `CREATOR_GROUP_MIN_RANK` é 255 — o dono do grupo
e mais ninguém; baixe para o rank dos seus admins se quiser incluir a diretoria.

`strike` sem argumento pega qualquer unidade no mapa; com um tipo (`strike Sword`)
sorteia entre as daquele tipo, e diz em quem caiu. Nome com espaço precisa de aspas:
`strike "Subspace Tripminer"`. O autocomplete oferece o catálogo inteiro do
`UnitStats` — quem sabe o que está *posicionado* é o servidor, e ele responde com a
lista real quando não acha nenhuma.

`lightinglist` (alias `lightings`) mostra quantas propriedades e quantas instâncias
cada preset declara, marca o atual com `>` e aponta os vazios — é o jeito rápido de
ver por que um preset "não fez nada". `lighting` (alias `setlighting`) num preset
que já é o atual reaplica de propósito, para testar uma pasta recém-mexida no Studio.

O tipo `lightingPreset` monta o autocomplete lendo `Assets.Lighting` na hora, e não
de uma lista fixa: os presets de mapa só passam a existir depois que o `MapService`
registra o mapa carregado.

> Comando que depende de service de uma place só mora na pasta daquela place — o
> `strike` precisa do `ThunderService`, que só existe na Game, e no Lobby o
> `Framework:Get` com yield ficaria esperando para sempre.

> O Cmdr era só do Lobby. Passou para as duas places nessa mudança:
> `CmdrService` foi para `common/server/Services`, `CmdrController` para
> `common/client/Controllers`, os comandos compartilhados para
> `common/server/CmdrDefinitions`, e o `Game/wally.toml` ganhou a dependência. Os
> comandos de crate (`setcrates`, `unbox`) continuam em `Lobby/src/CmdrDefinitions`,
> que é onde fazem sentido.

#### Inventário de unidades pelo console

```
units <ação> <jogadores> <unidade> [quantidade]
```

Mexe no `Units` do perfil — **quantas** de cada unidade o jogador tem. Aliases:
`unit`, `giveunit`, `inventory`. A ação é a mesma dos comandos de moeda (`set`,
`add`, `remove`, com tab), a quantidade omitida vale 1, e nada desce de zero.

`Units` é o inventário; `EquippedUnits` é quais delas estão nos slots. O comando
mexe só no primeiro **de propósito**: o `DeckConfig.sanitize` roda a cada leitura do
deck e já corta o `Amount` de cada slot pelo que a pessoa possui, então tirar unidade
do inventário esvazia o slot sozinho. Reescrever o deck aqui seria fazer à mão o que
o config já faz sozinho — e em dois lugares que poderiam discordar.

Unidade que chega a zero **sai da tabela** em vez de virar `= 0`: é assim que se
parece o perfil de quem nunca teve aquela unidade, e o `DeckConfig` trata os dois
casos pelo mesmo `owned[unitName] or 0`.

O nome aceita diferença de maiúsculas (`units add me slasher 3` funciona) e a
resposta devolve a grafia oficial. Nome com espaço precisa de aspas:
`units add me "Subspace Tripminer" 3`.

⚠️ **Na Game, o round que já começou não muda.** As cartas da partida são
fotografadas do perfil no `UnitService:initPlayerCards`, que roda no começo do round
— dar unidade no meio de uma wave só aparece no round seguinte, ou depois de um
`ResetRound`. No Lobby o efeito é imediato: o deck lê o perfil a cada mudança da
replica.

O comando mora no `common/` porque as duas places têm `DataService` e as duas leem o
`Units` — o Lobby para montar o deck, a Game para as cartas da partida. Por causa
dele o tipo `unitName` saiu de `Game/src/CmdrDefinitions/Types` para
`common/server/CmdrDefinitions/Types`: ele só lê o `UnitStats`, que é compartilhado,
e o `strike` continua servido pela cópia comum. Com isso o nó `Types/Game` do
`Game/default.project.json` ficaria apontando para uma pasta vazia — que o git não
versiona e o Rojo não encontraria num clone novo —, então saiu junto.

#### Moedas pelo console

São **três** moedas e duas delas são a mesma conta em lugares diferentes:

| Comando | Mexe em | Onde vive |
|---|---|---|
| `cash` (`money`, `coins`) | `Stats.Cash` do perfil | salvo; é o do lobby, dos summons e das caixas baratas |
| `shards` (`shard`) | `Stats.Shards` do perfil | salvo; a moeda premium, das caixas caras |
| `roundcash` (`sessioncash`) | `MobService.SessionCash` | só enquanto o round dura |

A ação é `set`, `add` ou `remove`, e o tab completa — `s`, `a` e `r` já resolvem.
Nenhuma das três desce de zero: `remove` que passaria do fim para em zero, porque
saldo negativo não existe em lugar nenhum do jogo. A resposta do console diz o antes
e o depois de cada jogador, senão um `remove` que bateu no chão e um `set` num valor
que já era aquele pareceriam "o comando não fez nada".

O `cash` e o `shards` escrevem pelo `CurrencyService` (`common/server/Services`), que
lê e escreve dentro do mesmo `DataService:Update` — assim o `add` soma em cima do
valor que está lá agora, e não no que estava quando o comando foi digitado. O
`roundcash` passa pelo `addCash`/`spendCash` do `MobService` em vez de escrever na
tabela, porque são eles que disparam o `UpdateCash`: sem isso o contador na tela
ficaria no valor antigo até a próxima kill.

`restartwarning` (alias `testrestart`) entra pelo mesmo caminho do evento da engine,
então o que aparece na tela é exatamente o que apareceria no dia — ver
[Aviso de restart do servidor](#aviso-de-restart-do-servidor). O motivo é um nome de
`Enum.CloseReason` e o tab completa; `seg` omitido são 5 minutos.

### Weather

Um clima é um Model em `ReplicatedStorage.Shared.Assets.Weathers`, com uma **tag**
dizendo como cada Part dele encaixa no mapa:

```
Assets.Weathers
├── Snow      (Model, tag "AreaWeather")
│   ├── Part      (os ParticleEmitters)
│   └── Lighting  (Folder — preset, mesmo formato de Assets.Lighting)
├── Thunder   (Model, tag "SkyWeather")
└── Rain      (Model, tags "AreaWeather" + "SkyWeather")
    ├── Part      (tag "SkyWeather"  — a camada de nuvem)
    ├── Part      (tag "AreaWeather" — a chuva na área jogável)
    └── Lighting  (Folder)
```

`WeatherService` (`common/server/Services`) clona o Model para `workspace.Weather`,
encaixa **cada Part** na caixa do mapa carregado e entrega a pasta `Lighting` ao
`LightingService` — então a troca de clima entra na **mesma transição interpolada**
de qualquer outra troca de iluminação, de graça.

```lua
local WeatherService = Framework:Get("WeatherService")

WeatherService:Apply("Snow")        -- transição no tempo padrão
WeatherService:Apply("Thunder", 4)  -- em 4s
WeatherService:Clear()              -- tira, e devolve a iluminação de antes
```

| Tag | O que faz com a `Part` |
|---|---|
| `AreaWeather` | vira a caixa inteira — `Size` e `Position` |
| `SkyWeather` | X e Z do tamanho da caixa; centro em X/Z, e Y no topo dela + `SkyHeightOffset`. A altura da Part é a autorada, porque é a espessura da camada |

**Um clima pode ser dos dois tipos.** A chuva tem uma camada de nuvem no céu e a
chuva caindo dentro da área jogável, e as duas medem caixas diferentes do mapa (o
céu mede o mapa inteiro, a área só `Terrain`+`Path`). Quando isso acontece, o Model
leva as duas tags e **cada Part diz a sua** — as duas do `Rain` se chamam `Part`, e
quem as separa é a tag, não o nome. As caixas são medidas no máximo uma vez por
tipo, então um clima de um tipo só continua custando uma varredura.

Clima de um tipo só não precisa marcar nada nas Parts: a tag do Model vale para
todas elas, que é como os climas antigos continuam funcionando sem serem
reautorados. Já num clima de dois tipos, Part sem tag é recusada com aviso (não há
como adivinhar em qual das duas caixas ela entra) e o resto do clima entra normal —
meio clima na tela é mais fácil de diagnosticar do que nenhum.

O offset do céu sai de `WeatherConfig.SkyHeightOffset` (20), e um Model pode trazer
o atributo `HeightOffset` para mandar no seu próprio valor. Vale saber na hora de
ajustar: as partículas do Thunder têm `Drag = 12` contra `Accel.Y = -15`, ou seja
velocidade terminal de ~1.2 studs/s — a camada praticamente não cai, fica onde o
offset colocar.

#### Áudio

As partículas e a iluminação chegam ao cliente sozinhas — as primeiras pela
replicação de `workspace.Weather`, a segunda pelo `LightingApplied`. Som não: é
local de cada cliente, e quem cuida é o `WeatherController`
(`common/client/Controllers`), escutando o `WeatherChanged` que o `Apply`/`Clear`
transmitem.

- **ambiente**: enquanto o clima estiver ligado, o loop de `WeatherConfig.Ambience`
  toca ao fundo pelo `MusicController`, entrando e saindo com fade. Hoje só o
  `Thunder` tem um (`Thunderstorm`, fade de 2s). Trocar de um clima com ambiente
  para outro cruza os dois fades em vez de estalar.
- **estouro do raio**: cada queda toca um clone próprio de `Thunder`, com
  `FadeOut = 1` para a cauda não cortar seca. Sem `Key`, de propósito — dois raios
  seguidos se sobrepõem em vez de um derrubar o outro. O Sound nasce **dentro do
  Attachment da ponta do raio**, então é 3D e sai do ponto de impacto: quem chama é
  o `VFXController`, que é quem tem a âncora; a política de áudio (qual som, qual
  fade, qual volume) fica no `WeatherController`. `StrikeVolume` existe porque o
  asset tem `RollOffMinDistance = 10` e a câmera de tower defense fica longe do
  chão — é o multiplicador para compensar sem mexer no asset.

  O clone do som morre junto com o beam, e o beam só é destruído em `Duration +
  Cleanup` (8s) contra os 3,63s do estouro — sobra folga de 4,4s.

O ambiente é forçado a `Looped = true`: o asset não vem em loop, e sem isso ele
acabaria no meio do clima. Em loop ele nunca agenda o próprio fim — só sai pelo
`StopSFX(AmbienceKey, fade)`.

O clima é servidor-autoritativo: o clone vive em `workspace.Weather` e replica para
todo mundo, um por vez. Ao entrar, toda BasePart do clone vira intangível
(`CanCollide`, `CanQuery` e `CanTouch` desligados) — os assets vêm com
`CanCollide = true`, e uma Part esticada para cobrir o mapa viraria uma parede
invisível, além de sujar o raycast dos passos e a validação de posicionamento.

O `Clear` devolve a iluminação que estava antes do **primeiro** clima, não a do
clima anterior — trocar de Snow para Thunder e desligar volta para a iluminação do
mapa, não para a do Snow.

#### Clima na partida (Game)

O `WeatherService` sabe ligar e desligar um clima, mas não sabe nada de waves. Quem
decide **se**, **qual** e **quando**, dentro do round, é o `WeatherRoundService`
(`Game/src/Services`).

A cada wave que começa ele faz três coisas, nesta ordem:

1. tira o clima que estava no ar, se a duração dele acabou;
2. liga o clima que estava agendado para esta wave;
3. não havendo nada agendado nem no ar, joga um dado — e passando, escolhe um clima
   do pool do mapa e **avisa** para `LeadWaves` waves à frente.

O aviso é o ponto do sistema. O clima nunca cai de surpresa: o jogador vê três waves
antes o que vem, e é isso que transforma o clima de azar em decisão — dá tempo de
vender o que vai ficar inútil e posicionar o que vai brilhar.

Só existe um clima por vez, e o dado nem é jogado enquanto houver um agendado ou no
ar. Um clima que cairia depois da última wave do preset não vira aviso nenhum.

**Duração** (`WeatherConfig.Round.Duration`): o clima fica no ar por 4 waves e sai
sozinho no começo da quinta — entrando na wave 10, ele vale da 10 à 13 e some na 14.
Enquanto ele durar o dado não é jogado, então o próximo aviso só pode sair da wave em
que o anterior saiu.

**Pool por mapa** (`WeatherConfig.MapPools`). A chave é o nome do mapa em
`MapConfig.MAPS`; mapa fora da tabela simplesmente não tem clima.

| Mapa | Climas |
| --- | --- |
| `Farm` | Fog, Wind, Thunder, Rain |
| `Desert` | Sandstorm, Drought |
| `Volcano` | Drought, Fog |
| `Cave` | Fog |
| `SnowyCastle` | Snow, Wind, Fog, Rain |
| `Mountain` | Snow, Wind, Fog, Thunder, Drought, Rain |
| `Snowy` | Snow, Wind, Fog |

**Chance por dificuldade** (`WeatherChance`, em `Config.Difficulty`): 10% no Fácil,
15% no Médio, 22% no Difícil, 30% no Impossível e 40% no Nightmare. Como o dado só é
jogado com o céu livre, o número não é "quantas waves têm clima": é a pressa com que
o próximo aparece depois que o anterior sai.

**O aviso na tela** é `StarterGui.Interface.WeatherWarning`, um TextLabel com um
UIStroke. O `WeatherWarningController` só monta a frase; quem a anima é o
`WarningController` (ver [Aviso de restart do servidor](#aviso-de-restart-do-servidor),
que divide o mesmo label). Quem entra no meio da partida pede o aviso pendente com
`RequestWeatherWarning`.

#### Classes e efeitos de clima

Cada unidade tem uma `Class` em `UnitStats` — `Melee`, `Ranged`, `Magic`, `Fire`,
`Ice` ou `Electric` (aceita lista, para unidade de dois tipos). É o único lugar onde
a classe é escrita; quem lê é o `WeatherConfig`.

| Unidade | Classe |
| --- | --- |
| Entrepreneur | Melee |
| Rocket | Ranged |
| Slasher | Melee |
| Slingshot | Ranged |
| Subspace Tripminer | Magic |
| Sword | Melee |
| Azure | — (ainda sem classificar) |

Unidade sem `Class` continua funcionando: ela só não entra em nenhuma regra por tipo
e leva apenas o que o clima faz com `All`.

Os efeitos vivem em `WeatherConfig.Effects` e são **sempre multiplicadores** (0.7 é
"cai 30%"), nunca valores absolutos — assim o efeito vale igual numa unidade de
nível 0 e numa de nível 5.

| Clima | Efeito |
| --- | --- |
| **Fog** | alcance de todas as unidades × 0.7. Magic sofre 1.5x mais o mesmo corte (45%), então × 0.55 |
| **Wind** | velocidade dos inimigos × 1.3; velocidade de ataque de Melee × 1.3 |
| **Drought** | vida dos inimigos × 1.4; Fire ganha 30% de dano e 20% de cadência; Ice perde 60% de dano, cadência e alcance |
| **Snow** | cadência de todas × 0.75 (Ice × 1.25) e uma unidade congelada por 10s a cada 30s. Magic é imune |
| **Thunder** | o raio atordoa; Electric ganha 10% de dano passivo e carga ao ser atingido. Magic é imune |
| **Sandstorm** | dano e alcance de todas × 0.7. Magic é imune |
| **Rain** | **desliga** todas as unidades Fire; cadência de todas × 0.65 (Magic × 0.475). Colocar uma unidade Ice custa 25% menos |

Duas regras de precedência valem a pena guardar. **`Units.<Classe>` substitui
`Units.All`** naquela estatística — por isso o Fog escreve 0.55 para Magic em vez de
esperar que 0.7 e 0.55 se multipliquem. A substituição é **por estatística**: o Ice
da chuva escreve só `Cost`, e a cadência dele continua saindo do `All`. E **`Immune`
tira a unidade do clima inteiro**: nem debuff, nem buff da própria classe, nem
congelamento, nem raio, nem desligamento.

**`Disable` não é multiplicador.** A chuva desliga o Fire: a unidade para de atacar
enquanto o clima durar, e quem faz valer é o `UnitService`, que a pula no laço de
ataque. Não existe "atacar 90% menos" — ou a unidade está no combate ou não está —,
e por isso é um sim-ou-não por classe. Não é atordoamento: não tem prazo, não acende
o realce amarelo e não pode ser encurtado; ela volta quando o clima sair.

**`Cost` é o preço de colocar**, e entra pelo `UnitUpgradeConfig:GetPlaceCost` — o
mesmo que o servidor cobra em `PlaceUnit` e que a carta da hotbar mostra, para não
haver um preço na tela e outro na conta. Trocar de clima reescreve o preço de todas
as cartas (`Card.refreshWeather`), inclusive quem estava em vermelho por falta de
caixa.

> **A venda não segue o desconto.** O servidor guarda no `entry.invested` o preço de
> **tabela**, mesmo tendo cobrado menos, porque é do `GetInvested` que os dois lados
> tiram o valor de venda e o cliente não sabe quanto cada unidade custou de fato (o
> `invested` não é replicado). Guardar o preço descontado faria o card prometer uma
> devolução e a venda dar outra. Na prática o desconto continua sendo só vantagem:
> comprar por 75 e vender por 50 nunca é lucro.

Os multiplicadores entram no `UnitUpgradeConfig`, e não em cada chamador: todos os
getters aceitam um `weather` opcional no fim.

```lua
UnitUpgradeConfig:GetRange("Slingshot", 0)          -- 12
UnitUpgradeConfig:GetRange("Slingshot", 0, "Fog")   -- 8.4
UnitUpgradeConfig:GetCooldown("Slasher", 0, "Wind") -- 0.85 / 1.3
```

Concentrar a conta ali é o que faz servidor e cliente concordarem: o alcance que o
`UnitService` usa para procurar alvo, o círculo que o `UnitPlacementController`
desenha no chão e os números do card saem todos da mesma função. Se o clima entrasse
só no combate, o jogador veria um círculo que não corresponde ao que a unidade
alcança.

Ninguém empurra o clima para o combate. O `UnitService` lê o clima do
`WeatherService` uma vez por quadro e o `MobService` confere no mesmo lugar se ele
mudou — então ligar o clima é o único passo, e o comando `weather` produz exatamente
a mesma partida que o round produz. No cliente a fonte é o
`WeatherController:GetCurrent()`, e quem precisa redesenhar (círculo de alcance,
card) escuta o próprio `WeatherChanged`.

A vida dos inimigos é a exceção que só vale no spawn: mudar `MaxHealth` no meio da
caminhada significaria curar o mob ou matá-lo na hora. A velocidade, essa sim, entra
na hora — inclusive nos que já estão andando, senão dois mobs iguais andariam em
ritmos diferentes na mesma wave. E a renda da fazenda fica de fora de propósito: ela
não é dano, e o corte da tempestade de areia mexeria na economia em vez de no
combate.

#### Congelamento da neve

Enquanto o `Snow` estiver no ar, o `SnowService` (`Game/src/Services`) sorteia uma
unidade a cada 30s e a congela por 10s. Congelar é o mesmo atordoamento do raio
(`UnitService:StunUnit`) — quem é imune ao clima fica **fora do sorteio**, e não
"é sorteado e não congela", senão um mapa cheio de Magic passaria waves sem nada
acontecer.

O `UnitStunned` leva um terceiro argumento, `source`: o clima que causou o
atordoamento. O `VFXController` procura o `Effects.<clima>.Freeze` do `source` em vez
de comparar o nome com `"Snow"`, então o raio e o gimmick de mob caem fora sozinhos e
ficam só com o realce amarelo do `UnitPlacementController`.

**O desenho é o mesmo do congelamento do Frostione nos inimigos**: `Freeze.Asset` é o
`IcedVFX`, tocado pelo `VFXController:playModelStatus` — a mesma função do gelo e do
fogo nos inimigos. As partículas vão para a `HumanoidRootPart` soldadas no `Torso`, e
o Highlight do asset muda para a raiz do modelo da unidade, pintando o corpo inteiro.
O congelado **não** ganha o realce amarelo, para as duas cores não se misturarem.

A duração que vale é a que o servidor **de fato aplicou** (chega no próprio
`UnitStunned`), não o `Freeze.Duration` do config: o prazo maior manda em `StunUnit`.
No fim os emissores desligam, o Highlight sai na hora e a Part só é destruída depois
do rabo das últimas partículas. Congelar de novo quem já está congelado troca o
desenho em vez de empilhar dois, e vender a unidade limpa tudo junto com o modelo. O
Staff of Healing apaga antes da hora pelo `StopFreeze` (`stopModelStatus`).

#### Buff e debuff na unidade

Toda unidade que o clima mexe mostra isso em cima dela, e as duas peças saem do mesmo
cálculo (`WeatherConfig.GetUnitFeedback`):

- **Highlight** no modelo — azul claro (`120, 200, 255`) quando o clima está
  ajudando, vermelho (`255, 70, 70`) quando está atrapalhando. Os dois com
  transparência 0.75, de preenchimento e de contorno.
- **Billboard na cabeça** (`Assets.UI.BuffDebuffBillboard`, um Attachment com um
  `BillboardGui`) com um ícone por estatística mexida, na ordem dano → alcance →
  cooldown.

Quem desenha é o `WeatherFeedbackController` (`Game/src/Controllers`), no cliente. Ele
não decide nada: a lista de ícones e a cor vêm do `WeatherConfig`, a mesma config de
onde o servidor tira os multiplicadores que aplica no combate. O que o jogador vê e o
que ele leva no combate saem da mesma linha.

| Estatística | Multiplicador > 1 | Multiplicador < 1 |
| --- | --- | --- |
| `Damage` | `BuffDamage` | `DebuffDamage` |
| `Range` | `BuffRange` | `DebuffRange` |
| `AttackSpeed` | `BuffCooldown` | `DebuffCooldown` |

`AttackSpeed` aparece como **cooldown** porque é assim que o card mostra o número:
cadência maior é recarga menor, então `AttackSpeed > 1` acende o ícone de *buff*.

O asset tem os seis, e os labels vêm todos `Visible = true` do Studio: quem desenha
liga o do que a unidade está sentindo e **apaga o resto**. `Cost` fica de fora da
billboard de propósito — ele não é um estado da unidade em campo, é o preço de
colocar uma nova, e quem o mostra é o próprio número da carta na hotbar, que já sai
com o desconto.

**Unidade desligada** (o Fire na chuva) tem resposta própria e curta: um ícone só, o
`DebuffCooldown`, mais o Highlight vermelho. O que ela precisa comunicar é "esta não
está atacando", e não em quanto cada estatística mexeu — os números dela continuam
existindo, só não são usados por ninguém enquanto o clima durar, e mostrá-los
sugeriria uma unidade meio funcionando. O ícone é o de cooldown porque parar de
atacar é o extremo do que ele já significa; um desenho próprio entra numa linha do
config (`Feedback.Disabled`) no dia em que a arte existir.

Unidade imune ao clima (Magic, nos climas de hoje) não recebe nada — nem billboard,
nem Highlight —, que é o mesmo "fora do clima" que o `Immune` já significa no combate.
Havendo buff e debuff na mesma unidade, o Highlight é **vermelho**: nenhum clima de
hoje faz as duas coisas, mas quando fizer, a perda é o que precisa ser visto de longe.

As duas peças moram **dentro do modelo da unidade**, então vender ou recomeçar o round
limpa junto; o controller as procura pelo nome em vez de guardar numa tabela, e não
existe bookkeeping para desencontrar do que está no Workspace. O Highlight tem nome
próprio (`WeatherHighlight`) para não brigar com os outros que a unidade recebe: o
verde da seleção, o amarelo do atordoamento e o ciano da carga do raio.

Nome de ícone pedido pelo config que não exista no asset simplesmente não aparece — a
unidade continua com o Highlight e com os outros ícones, e o Studio avisa uma vez no
output.

#### Raios (Thunder)

Com o clima `Thunder` ligado cai um raio a cada `Interval` (5s). Onde ele cai é
sorteado: ou em cima de uma unidade posicionada, ou num ponto qualquer dentro da
`BoundingBox` do mapa. Quem dá o compasso e sorteia é o `ThunderService`
(`Game/src/Services`); quem desenha é o `VFXController`, no cliente.

A chance de acertar unidade é um **pity**: começa em `UnitChance` (0.15), sobe
`UnitChanceStep` a cada raio que cai no chão e volta ao piso quando um acerta. Como
a escada é 0.15 → 0.30 → … → 1.00, o sétimo raio é garantido. Simulado em 20 mil
sequências: média de 2,9 raios até acertar (~15s) e pior caso 7 (~35s). Sem isso,
chance fixa baixa deixaria passar a partida inteira sem um raio em unidade, e chance
fixa alta viraria metralhadora nas torres.

A chance não sobe quando não há unidade nenhuma no mapa — o pity conta raio que
*poderia* ter acertado e não acertou. E o clima sendo desligado zera tudo: relógio e
pity voltam ao começo.

O ponto no chão sorteia X e Z dentro da caixa e tira o Y de um raycast para baixo,
porque o terreno tem altura variável e largar o raio no fundo da caixa o deixaria
enterrado nas partes altas. Medido no `Farm`: 400 sorteios, todos acharam chão, com
Y variando de 6.5 a 33.0 e nenhum fora da caixa. A própria `BoundingBox` não
atrapalha a consulta porque o `LoadMap` a clona com `CanQuery` desligado.

A divisão é obrigatória por dois motivos: `ReplicatedStorage.vfx` **se recusa a
rodar fora do cliente**, e sortear no servidor é o que faz todos verem o mesmo raio
no mesmo lugar — com cada cliente sorteando o seu, dois jogadores lado a lado veriam
raios diferentes.

O evento manda a posição e, quando o alvo é uma unidade, o `unitId` junto. O cliente
prefere o `unitId`: ele mede o pé pela caixa real do modelo, enquanto o servidor só
conhece o CFrame de posicionamento. A posição é o alvo do raio no chão, e o fallback
de quando o modelo ainda não replicou.

O asset (`Assets.VFX.LightningBeam`) é um **Attachment** (o começo do raio) com um
Attachment filho **`B`** (o fim) — é por ter um filho de letra única que o addon
`LightningBeams` o reconhece como raio. Posicionar os dois pelo `WorldPosition`
basta: a posição relativa do filho se recalcula sozinha, e como nenhum deles tem
BasePart de ancestral, o mundo é o próprio referencial.

- **fim** (`B`): o pé da unidade — centro da base da caixa dela, não o `GetPivot`,
  que cairia no meio do corpo.
- **começo**: a altura da Part do clima em `workspace.Weather`, para o raio descer
  de onde está a nuvem. Sem clima ligado, `StrikeHeight` acima do pé.

Duas coisas do módulo que valem saber. O asset vem com `EmitRepeat = -1`, que é como
o plugin marca a prévia em loop — o `emit` acaba tratando -1 como "não repete", mas
o controller passa `EmitRepeat = 0` na mão em vez de depender disso. E o
`maxLifetime` do módulo daria zero aqui, porque os ParticleEmitters são criados pelo
addon em runtime e não existem no asset: a vida do clone sai do atributo `Duration`
dele mais `Cleanup`.

O raio não tira vida: ele **atordoa**. Quem leva em cheio para por `Stun.Direct`
(20s — a wave inteira), e o choque **salta** para quem estiver dentro de
`Stun.Radius` (12 studs), que para por `Stun.Chain` (5s). A diferença entre os dois
prazos é grande de propósito: um raio bem colocado tem que doer, não apagar meio
mapa. `Hops` é quantas camadas o salto pode andar (1 hoje) e `MaxTargets` fecha o
teto por camada; cada unidade é tocada uma vez só por descarga.

`Electric` é a exceção que faz o clima valer a pena para alguém: além dos 10% de
dano passivos enquanto o trovão durar, levar o raio (ou o salto) a **carrega** com
+50% de dano e +50% de cadência por `Charge.Duration` (10s). O buff temporário mora
em `entry.Charge`, por fora do `UnitUpgradeConfig` — o config só conhece números que
valem para todo mundo, e a carga é estado de partida de uma unidade específica.
Recarregar antes de acabar renova o prazo em vez de empilhar.

Unidade imune ao trovão (Magic) **sai do sorteio** do raio do clima em vez de ser
sorteada e ignorada — deixá-la no bolo estragaria o pity, porque cada raio gasto
nela contaria como acerto e a chance voltaria ao piso sem nada acontecer na tela. O
comando `strike` continua alcançando qualquer unidade, porque testar o visual numa
Magic é legítimo.

No cliente, `UnitStunned` pinta a unidade de amarelo e `UnitCharged` de ciano — as
duas coisas vêm do mesmo raio e acontecem lado a lado, e sem separar as cores uma
Electric carregada pareceria congelada. Os saltos são desenhados com o mesmo asset
do raio (`VFXController:spawnBeam`), ligando o meio do corpo de uma unidade ao da
outra, e sem estouro próprio: o do raio principal já está tocando.

Para testar sem esperar o intervalo, o comando `strike` chama o
`ThunderService:strikeUnit` direto — força acerto em unidade, sem passar pelo
sorteio do pity.

#### A caixa do mapa

Cada mapa traz uma Part **`BoundingBox`** (irmã de `Content`) dizendo onde ele fica,
e ela manda nos dois tipos de clima. Só `Position` e `Size` são lidos — as caixas são
alinhadas aos eixos, rotação é ignorada.

Ela é irmã de `Content`, mas quem a consome é o `WeatherService`, que só enxerga o
Workspace — então o `LoadMap` a clona para dentro de `workspace.Map`, inerte
(`CanQuery` desligado, para não aparecer no raycast dos passos nem na validação de
posicionamento de unidade).

Mapa sem a caixa cai para medir a geometria, e aí valem `BoundsFolders`
(`Terrain` + `Path`, para o `Locked` de cenário não entrar) e `MaxPartFootprint`
(512 studs, porque o `Snowy` tem dois planos `Ice` de 2048x2048 dentro do próprio
`Terrain` e o `Volcano` guarda a água lá). É plano B: as heurísticas erram feio
justamente nesses dois — o `Volcano` calculado dá 500x500 contra os 147x109 da caixa
autorada.

A caixa respeita rotação: a meia-extensão do AABB de uma Part girada é
`|R| * meioTamanho`, e não `Size/2`.

#### Mapas (Game)

`MapService:LoadMap` aplica a pasta `Lighting` do mapa por aqui, em vez de limpar o
`Lighting` na mão:

```lua
local preset = LightingService:Register(MapLighting, LightingConfig.MapPrefix .. Name)
LightingService:Apply(preset)
```

`Register` existe por causa da replicação: os mapas moram em `ServerStorage`, que
não replica, então a pasta é clonada para `Assets.Lighting` (virando `Map_Farm`,
`Map_Cave`, …) antes de ser aplicada — sem esse clone o cliente não teria de onde
ler os valores de destino da transição. Mapa sem a pasta fica com a iluminação
autorada na place.

O `init` registra a pasta de **todos** os mapas, não só a do que vai ser carregado
(`MapService:registerMapLighting`). São seis instâncias pequenas por mapa, e é o que
permite o `lighting` trocar entre as iluminações para comparar uma com a outra em
jogo — com só a do mapa em curso registrada, não haveria para onde ir.

Uma pasta com **zero atributos** é legítima, e aí o resultado correto é as
propriedades do `Lighting` não mudarem — só as instâncias trocam, que é o mesmo que
o `LoadMap` fazia antes. Para um mapa definir a iluminação inteira, é pôr os
atributos na pasta dele. Como "aplicou e não mudou nada" e "não aplicou" ficariam
idênticos no console, o `Apply` loga no Studio quantas propriedades e quantas
instâncias entraram, o `LoadMap` avisa quando o mapa não tem a pasta, e o
`lightinglist` mostra o mesmo de dentro do jogo.

Dois detalhes de nomenclatura nas pastas dos mapas. Os nomes divergem entre eles
(`Blur [Realism Mod]` num, `Blur` noutro, `SunRays` vs `SunRays [Realism Mod]`) e a
interpolação casa por nome — com o neutro isso não é mais um corte, mas o efeito
some até zero e o outro sobe do zero em vez de um virar o outro direto. Padronizar
os nomes deixa a transição mais curta e mais bonita. E vários trazem **dois** filhos
chamados `Atmosphere`; o segundo é ignorado, aqui e pela própria engine — quem vale
é o primeiro.

### Controles: mouse e toque (Game)

Todo o apontar do jogo — o fantasma da unidade, a seleção de uma torre já
colocada, o hover de mob — passava direto por `UserInputService:GetMouseLocation()`
e só aceitava `Enum.UserInputType.MouseButton1`. Num celular nenhum dos dois
existe: sem mouse aquela chamada não acompanha nada (fica em `(0,0)` ou congelada
no último ponto tocado) e o toque chega como `Enum.UserInputType.Touch`. O sistema
de posicionamento não funcionava no mobile — não por conforto, mas porque *nada*
acontecia ao tocar a tela.

`common/shared/Util/PointerUtil.luau` põe os dois aparelhos atrás da mesma porta:

| | PC | Celular |
|---|---|---|
| `getScreenPosition()` | cursor agora | último ponto tocado (`nil` antes do 1º toque) |
| `onPointerAction(cb)` | botão esquerdo descendo | toque curto e parado (≤20px, ≤0.6s) |
| `isTouchOnly()` | `false` | `true` |

O limite de movimento no toque é o que separa **apontar** de **girar a câmera**:
no celular arrastar a tela é como o jogador olha em volta, e um arrasto não pode
virar um clique no mundo. PC com tela sensível ao toque continua contando como PC.

O fluxo de posicionamento diverge de propósito entre os dois:

- **PC** — igual a sempre: o fantasma segue o cursor, `R` gira, clique confirma.
- **Celular** — o toque no mapa só **move** o fantasma; quem confirma é um painel
  (`ROTATE` / `PLACE` / `CANCEL`) que o `UnitPlacementController` monta em código
  no canto direito. Confirmar no próprio toque seria pior que não ter nada: o dedo
  tapa justamente o ponto onde a unidade vai nascer, e a torre sairia sem o jogador
  ver o círculo de alcance nem a cor do fantasma. O botão `COLOCAR` acompanha a cor
  do fantasma (verde/cinza), porque sem cursor pairando ele é o único aviso de que
  ali não dá.

O painel é criado só quando `PointerUtil.isTouchOnly()` e morre junto com o Maid do
posicionamento, pelos dois caminhos de saída (confirmar e cancelar). O canto
escolhido é o direito: o inferior-esquerdo é o direcional de movimento do Roblox e
o centro de baixo é a barra de cartas.

As medidas são todas em escala, com `UISizeConstraint` e `UITextSizeConstraint` só
para os extremos: a mesma medida em offset que dá um botão confortável num tablet
vira um alvo minúsculo num celular estreito. O piso de 190px de altura no painel é o
que garante ~49px por botão, que é o alvo de toque confortável numa tela deitada.

#### Precisão do toque

Duas coisas fazem o toque cair perto — mas não em cima — do dedo, e as duas estão
corrigidas:

- **Espaço de coordenada.** `InputObject.Position` vem no espaço da interface, que
  começa embaixo da barra superior do Roblox; `Camera:ViewportPointToRay` conta do
  topo real da janela, porque o 3D é desenhado por trás da barra também. A diferença
  é a GuiInset (~36px verticais) — e é só isso que separava o toque do alvo, já que
  `GetMouseLocation()` sempre veio no espaço do raio. Em vez de somar 36 na mão (o
  valor muda com a barra escondida, com tela cheia e entre aparelhos), o
  `PointerUtil` **mede**: uma moldura de tamanho zero num `ScreenGui` com
  `IgnoreGuiInset` fica no canto de cima da janela inteira, e a `AbsolutePosition`
  dela é a origem do espaço do raio. Funciona sem depender de qual convenção a
  engine usa.
- **O lerp do fantasma.** O que ia ao servidor era o `ghostCF`, que persegue a mira
  por interpolação e quase nunca está exatamente onde ela aponta. Quem passou pelo
  teste de caminho e de sobreposição foi o **alvo** (`targetCF`), e agora é ele que
  é enviado — o lerp fica só na aparência. No mouse a diferença era invisível (o
  cursor fica parado e o fantasma alcança antes do clique); no toque o jogador toca
  e já aperta `COLOCAR`, com o fantasma ainda a caminho, e a unidade nascia no meio
  do trajeto.

Duas armadilhas de UI que o toque expõe e que foram corrigidas junto:

- **`MouseButton1Up` não é clique.** Se o dedo escorrega para fora do botão antes
  de soltar, o `Up` nunca chega — a ação se perde e a animação de aperto fica
  travada. Ação agora sai do `Activated` (`UILibraryController.addClickAnimation`,
  vender e melhorar no `ToggleTower`), e a volta visual é vigiada pelo
  `UserInputService.InputEnded`, que vê o dedo sair de qualquer lugar da tela.
- **Hover não existe no toque.** `MouseEnter` às vezes dispara sem o `MouseLeave`
  correspondente e o botão fica crescido para sempre; `addHoverAnimation` sai fora
  no celular.

`MobController:startHoverLoop` também sai fora: sem mouse ele só gastaria um
raycast a cada 0.05s para nunca encontrar mob nenhum.

#### O que bloqueia o posicionamento

O cliente pinta o fantasma de verde ou vermelho e o servidor aceita ou recusa, e os
dois têm que responder igual — fantasma verde com o servidor recusando (ou o
contrário) é a divergência que o `PlacementUtil` existe para evitar. São quatro
testes, na ordem:

1. **Caminho** — `GetPartsInPart` nas parts com a tag `Grid`, na caixa da unidade
   esticada `PathClearance` studs para baixo.
2. **Obstrução genérica** (só no cliente) — qualquer part do mundo dentro da
   `PrimaryPart` do fantasma. Acessório nunca aparece aqui: o `CollisionService`
   desliga o `CanQuery` de todos eles.
3. **Personagem** — `PlacementUtil.FindBlockingCharacter`, na bounding box cheia da
   unidade.
4. **Distância mínima** para outra unidade já posicionada.

**Personagem nenhum entra no teste 2**, e é a correção que importa lembrar: quem
responde por personagem é o teste 3, que usa a caixa da unidade inteira (mais
estrita, então o corpo continua bloqueando) e **pula acessório de propósito** —
chapéu e asa saem metros fora do corpo, e sem essa regra o jogador via o
posicionamento recusado por um lugar que, na tela, está vazio. O teste 2 não tinha
essa regra: o chapéu de quem passasse perto pintava o fantasma de vermelho num lugar
que o servidor aprovaria, porque no servidor o único teste de personagem é o 3.

O raycast do chão continua excluindo só o fantasma e o próprio jogador: mirar em cima
de outro jogador ainda apoia o fantasma nele, e é o teste 3 que pinta aquilo de
vermelho.

#### O fantasma não colide com nada

São três cuidados, e o primeiro é o que resolve de verdade:

1. **Grupo de colisão `PlacementGhost`.** As parts do fantasma entram num grupo
   declarado não-colidível com todos os outros — e com ele mesmo, para dois fantasmas
   não se esbarrarem. Part que não colide com nada não colide com nada, dê o Humanoid
   o que der. Quem registra é o `CollisionService` (`Game/src/Services`), porque
   `PhysicsService:RegisterCollisionGroup` só roda no servidor; o registro replica e o
   `UnitPlacementController` só atribui. O nome do grupo mora no `PlacementUtil`, que
   os dois lados já requerem.
2. **`CanCollide = false`** em cada part, como sempre — hoje é o plano B, para o caso
   de o registro não ter acontecido.
3. **`EvaluateStateMachine = false`** no Humanoid, **antes** de parentear no
   workspace.

O terceiro existe porque é o Humanoid quem manda na colisão de um personagem: ao
entrar num estado novo (Running, Landed…) ele religa o `CanCollide` do torso, e a
entrada no workspace é justamente o que dispara a primeira avaliação. Era isso que
fazia o fantasma empurrar o jogador e travar quem passasse perto, apesar do item 2.

E o Humanoid **tem** que ficar: por um
[bug antigo da engine](https://devforum.roblox.com/t/highlight-does-not-work-with-transparency-on-non-humanoid-models/2731329),
`Highlight` não renderiza em part transparente quando o modelo não tem Humanoid — e o
fantasma é meio transparente por natureza. Sem Humanoid o Highlight some, e com ele o
verde/vermelho que diz se dá para colocar ali. A Roblox chegou a corrigir e reverteu
de propósito (quebrava jogos com gatilho invisível), então o Humanoid é o workaround
oficial mesmo.

> ⚠️ **Nada além do fantasma pode entrar no `PlacementGhost`.** As perguntas de
> posicionamento são feitas com `OverlapParams` no grupo `Default`, e é o grupo do
> *params* que vale, não o da part consultada — por isso o fantasma no grupo novo não
> muda nenhuma resposta. Mas part **do mundo** dentro dele fica invisível para essas
> perguntas: seria terreno que o fantasma atravessa sem nunca ficar vermelho.

**O personagem tem grupo próprio, `Character`.** Toda BasePart de todo personagem de
jogador entra nele — corpo, acessório e o que mais nascer no modelo depois, porque o
`CollisionService` deixa um `DescendantAdded` ligado (os acessórios chegam depois do
`CharacterAdded`, e sem o sinal o chapéu ficaria no `Default`). O grupo é registrado
**antes** da volta que declara o fantasma não-colidível com todos, senão ele nasceria
colidindo com o fantasma — grupo novo nasce colidindo com os existentes, e é isso que
vale conferir no dia em que aparecer um terceiro grupo.

**E acessório não é consultável.** A mesma volta desliga o `CanQuery` de toda part de
todo acessório. Grupo de colisão resolve física, e acessório nunca foi problema de
física: o problema dele é ser uma part *consultável* que sai metros fora do corpo —
chapéu e asa entravam nos `GetPartsInPart` do posicionamento e recusavam lugares que,
na tela, estão vazios. Desligar na própria part faz a regra valer para **qualquer**
consulta do jogo, não só para as que se lembrarem de filtrar acessório na mão. A
pergunta é a mesma do `FindBlockingCharacter`,
`FindFirstAncestorOfClass("Accessory")`, só que feita uma vez na part em vez de a cada
consulta — e nenhuma consulta de hoje precisa enxergá-los.

Não que o fantasma esbarrasse no jogador antes: ele já não colidia com `Default`,
onde o personagem vivia. O que muda é que "personagem não esbarra no fantasma" virou
um par nomeado em vez de consequência da volta. Do resto o personagem continua
participando igual — mapa, unidades posicionadas e os outros personagens —, e as
perguntas de posicionamento também: o `FindBlockingCharacter` consulta no `Default`,
com quem o grupo novo colide, então o jogador em pé no lugar continua bloqueando.

#### O card de upgrade: abre crescendo e o jogador escolhe onde ele fica

O `CardUpgrade` (`ToggleTower`, em `Game/src/Controllers/UILibraryController/Components`)
não entra mais deslizando de fora da tela. Ele **cresce no lugar**: o `UIScale` que
mora dentro dele vai de `0` a `1` no `Enum.EasingStyle.Elastic` quando uma unidade é
selecionada, e volta de `1` a `0` ao desselecionar — `EasingDirection.Out` na abertura
(o exagero acontece no fim, o card passa um pouco do tamanho e assenta) e `In` no
fechamento (uma esticada e some). O card só sai da tela (`Visible = false`) quando o
tween termina; se outra unidade for selecionada no meio, o tween antigo é **cancelado**
e o `Completed` chega como `Cancelled`, então o fechamento interrompido não apaga o
card que a nova seleção acabou de abrir.

A troca de animação não foi capricho: ela é o que **libera a posição**. O card agora é
arrastável com o mouse ou com o dedo, pegando por qualquer ponto dele — fundo, textos
ou os próprios botões (`Sell`, `UpgradeCost`, `Priority`), que precisam entrar na lista
porque engolem a entrada antes de ela chegar ao card. Onde o jogador soltar é onde o
card abre daí em diante, para todas as unidades, pelo resto da sessão. Uma animação que
nasce fora da tela e volta a um ponto fixo desfaria essa escolha a cada seleção.

Os detalhes que fazem isso funcionar nos dois aparelhos:

- **Clique não é arrasto.** Só depois de 6px de movimento aquilo vira um arrasto — dedo
  nenhum fica perfeitamente parado, e o `VENDER` não pode falhar porque o toque
  escorregou dois pixels. Na volta, o clique que fecha o arrasto ainda chega nos botões:
  uma janela de 0.15s engole esse clique, senão arrastar o card pelo `VENDER` venderia a
  unidade.
- **Quem escuta o movimento é o `UserInputService`, não o card.** O ponteiro sai de cima
  do card o tempo todo enquanto arrasta, e os eventos do próprio card parariam de chegar
  exatamente aí. No toque o `InputObject` é o mesmo do começo ao fim, e comparar por
  identidade é o que impede um segundo dedo na tela de sequestrar o arrasto; no mouse o
  movimento chega como `MouseMovement`, um objeto diferente do botão que segura o card.
  O `WindowFocusReleased` também solta, senão um alt-tab no meio do arrasto deixaria o
  card colado no ponteiro.
- **O cache é em escala, não em pixels.** A conta do arrasto é toda em pixels
  (`AbsolutePosition` já é o canto de cima do card, porque o `AnchorPoint` é `0,0`),
  com o card preso dentro do retângulo do `ScreenGui`, e só no fim vira escala — assim
  o card continua no mesmo canto da tela se a janela mudar de tamanho ou o aparelho
  girar. A posição vive na sessão do cliente; sair do jogo devolve o card ao lugar do
  layout.
- **`CardUpgrade.Active = true`.** Um `ImageLabel` só recebe entrada com isso ligado. De
  quebra o card passa a engolir o clique: apertar nele não vaza mais para o mundo atrás,
  que era o que desselecionava a unidade no meio de um arrasto.

**Unidade de outro jogador abre o card sem os botões.** `Sell`, `UpgradeCost` e
`Priority` só aparecem para o dono — o servidor já recusa os três de quem não é
(`UnitService`), e o que eles faziam na tela alheia era prometer uma ação que nunca
ia acontecer. O resto do card continua inteiro: nome, nível, stats, prioridade atual
e dano feito são justamente o que interessa olhar na unidade do outro. A prévia do
próximo nível sai junto, senão no celular (onde ela aparece sem hover) sobrariam os
números de um upgrade que não está mais no card.

Quem responde é o atributo `Owned`, que o `UnitPlacementController` escreve no modelo
ao replicar a unidade — o mesmo caminho do nível e da prioridade, então o card não
precisa perguntar a controller nenhuma quem é o dono. Sem o atributo a resposta é
não, de propósito.

### Quem some da tela, e quando

Quatro situações pedem a tela para si: o painel de mapas, que quer o lobby só para
ele; a loja, que borra o fundo e fica sozinha na frente; a contagem regressiva do
portal, que deixa em pé só o botão de sair; e a cutscene, que quer a tela limpa. Não
são um interruptor global — eles se sobrepõem (o painel pode estar aberto quando a
cena começa) e cada um sai na sua hora — então quem cuida disso é o
`InterfaceController` (`common/client/Controllers`), com **pedidos com nome**:

```lua
InterfaceController:Hide("ChooseMaps", { Except = { "ChooseMaps" } })
InterfaceController:Show("ChooseMaps")
```

Uma `ScreenGui` fica desligada enquanto **algum** pedido a esconder, e volta ao que
o dono dela queria quando o último sai. "O que o dono queria" é lido ao vivo: o
controller acompanha o `Enabled` de cada GUI da `PlayerGui`, e se alguém ligar uma
GUI escondida no meio de um pedido, o valor novo é guardado e ela continua desligada
— quando o pedido sair é esse valor que volta. É o que permite cada controller
continuar mexendo na própria GUI como sempre, sem saber que existe um pedido em
curso.

O que o controller escreve não entra nessa conta, e separar as duas coisas tem uma
armadilha: o aviso de `Enabled` chega **no fim do frame**
(`SignalBehavior.Deferred`), muito depois de uma flag ligada em volta da escrita ter
sido baixada. Com a flag, o `false` que o controller forçava voltava para ele como
se fosse o dono da GUI pedindo — e aí não sobrava estado nenhum para restaurar,
nada voltava. Por isso o eco é **contado** (`entry.Pending`), um por escrita, e não
sinalizado.

- **Painel de mapas** (`ChooseMapsController`): pede no `Open` com `Except` nele
  mesmo, devolve no começo do `Close` — a UI do lobby volta enquanto o painel ainda
  está sumindo, em vez de aparecer de estalo depois. O `_bindUI` devolve também, para
  o respawn com o painel aberto não deixar o lobby escondido sem nada para fechar.
- **Contagem do portal** (`PortalController:_onGroupChanged`): pede assim que o
  jogador entra num grupo, com `Except` no `ExitGroupPortal` — durante a contagem a
  loja, o deck e o resto da lobby saem, e fica só o botão de desistir. O pedido é
  devolvido quando o jogador **sai do grupo**, e não quando a contagem zera: aos zero
  a cutscene assume por cima, e é este pedido por baixo dela que impede a lobby de
  reaparecer entre o fim da cena e o teleporte. Falhando o teleporte, o portal devolve
  o grupo (`_abortLaunch`) e é essa devolução que traz a interface de volta.
- **Cutscene** (`CutsceneController:hideInterface`): pede sem exceção nenhuma e com
  `HideCore`, que leva junto a interface da própria Roblox (chat, playerlist, mochila
  e topbar). Sai com a **cena**, não com a câmera: mesmo no `holdCamera` — onde o
  controle do personagem fica preso até o `releaseCamera` — a interface volta quando
  a cena acaba. No portal isso cai atrás do flash branco, que a essa altura já está
  cobrindo a tela.

#### GUI que muda junto com um pedido

`Desired` é descoberto **escutando** o `Enabled` de cada GUI, e esse aviso é
`Deferred`: ele chega no fim do frame, não na hora da escrita. Entre uma coisa e
outra o valor guardado aqui ainda é o antigo — e um `Hide`/`Show` que caia nessa
janela varre todas as GUIs (`_applyAll`) e reaplica o valor velho por cima do que o
dono acabou de escrever.

Para quase toda GUI isso nunca acontece: ela muda por conta própria, longe de
qualquer pedido. Para a que muda **junto** com um pedido é o caso normal — o botão de
sair do portal acende no mesmo instante em que a contagem esconde a lobby, e o painel
de mapas se desliga 0.18s depois de devolver a tela, tempo de sobra para a contagem
começar. Escrevendo direto no `Enabled`, o botão sumia ao entrar no portal e o painel
voltava vazio depois.

Para esses casos existe o `SetEnabled`, que escreve o `Desired` na hora e aplica:

```lua
InterfaceController:SetEnabled(screenGui, true)
```

Não substitui o `Enabled` direto no caso geral — é para quem escreve perto de um
pedido. Hoje usam o `PortalController` (`_setExitVisible`, nas três transições do
botão) e o `ChooseMapsController` (as duas pontas do painel). Uma GUI que este
controller ainda não acompanha leva a escrita direta, e o `_track` que vier depois lê
justamente esse valor como o que o dono queria — o que cobre o respawn, já que todas
as `ScreenGui` da lobby são `ResetOnSpawn`.

A exceção é por **atributo**, não por lista: `ScreenGui` com `IgnoreInterfaceHide`
nunca é escondida. Existe por causa do flash branco do portal, que nasce dentro da
cutscene justamente para cobrir o teleporte — sem a marca ele nasceria desligado.

### O aviso grande no meio da tela

`StarterGui.Interface.WeatherWarning` é um TextLabel só, e hoje dois donos escrevem
nele: o clima que vem vindo e o restart do servidor. Quem encosta no label é o
`WarningController` (`common/client/Controllers`) — os donos mandam a frase pronta:

```lua
WarningController:Show("WARNING! SERVER RESTART FOR GAME UPDATE IN 2 MINUTES", {
	Priority = WarningConfig.Priority.Restart,
	Hold = 8,
})
```

A animação é a de sempre: o texto desce de `SlideOffset` acima do destino enquanto a
transparência do texto **e do stroke** cai de 1 para 0 — a impressão é a de a frase
se formando no lugar —, segura `Hold` e sai pelo mesmo caminho. O destino é a posição
autorada no StarterGui, então mover o label no Studio não exige tocar em código. O
stroke entra junto de propósito: só o texto aparecendo deixaria o contorno sólido por
trás de uma letra invisível.

**Prioridade** é o que resolve os dois donos disputando o label. Um aviso derruba o
que estiver no ar quando empata ou ganha em prioridade (`Weather` = 1, `Restart` = 2)
e é recusado quando perde — o clima da wave 8 não apaga "o servidor vai reiniciar em
1 minuto". O `Hide` aceita a mesma prioridade como "limpe só o que for meu": é assim
que o `RoundRestarted` limpa o aviso de clima sem levar o de restart junto.

O label e os tempos moram em `WarningConfig.Label`; o `WeatherConfig.Warning` ficou
só com as frases do clima.

### Aviso de restart do servidor

Quando a Roblox marca o fim deste servidor — atualização publicada, manutenção,
moderação, memória —, `game.ServerRestartScheduled` dispara **no servidor** com
`restartTime` (um `DateTime`) e `source` (um `Enum.CloseReason`). O
`ServerRestartService` (`common/`) repassa isso para os clientes e o
`ServerRestartController` escreve no label acima:

```
WARNING! SERVER RESTART FOR GAME UPDATE IN 2 MINUTES
WARNING! SERVER RESTART FOR ROBLOX MAINTENANCE IN 45 SECONDS
WARNING! SERVER RESTARTING FOR MODERATION            (faltando menos de 5s)
```

O motivo vira texto por `WarningConfig.Restart.Sources`, que é onde se separa o
restart **do desenvolvedor** (`DeveloperUpdate`, `DeveloperShutdown` → "GAME UPDATE")
do restart **da Roblox** (`RobloxMaintenance`, `Moderation`, `OutOfMemory`,
`ServerEmpty`, `Unknown`). Motivo que a engine invente amanhã cai no `DefaultSource`
em vez de virar aviso nenhum.

**O que atravessa a rede são os segundos que faltam, não o horário.** O `restartTime`
é UTC e o relógio da máquina do jogador não é confiável — hora errada no Windows
mostraria "restart em 3 horas". A subtração é feita no servidor e refeita a cada
envio, então quem entra dois minutos depois recebe dois minutos a menos; o cliente
ancora o prazo em `os.clock()`, que é monótono.

**O aviso volta.** Um restart é marcado com minutos de antecedência e uma frase de 8
segundos no meio de uma wave se perde, então `WarningConfig.Restart.Reminders`
(5min, 2min, 1min, 30s, 10s) traz o aviso de volta com o número novo. Marca que
cairia em cima do aviso anterior é descartada. Quem entra depois do agendamento pede
o pendente com `RequestServerRestart`, igual ao clima.

> O evento é da engine e não dá para ensaiar de verdade — a única forma de vê-lo é
> publicar uma atualização. Por isso existe o `restartwarning` do Cmdr, que entra
> pelo mesmo `ServerRestartService:Schedule` sem nada ser realmente agendado.

## Unidades

### O golpe em quatro tempos (Berserker)

O ataque de uma unidade é sempre um pedido só do servidor: ele marca o
`lastAttack`, espera o windup (`HitTime` do passo, em `UnitAttackConfig`) e cobra
os `Hits` do `UnitStats`, um a cada `HitInterval`. É espaçamento **regular** — o
Azure bate quatro vezes de 0,25 em 0,25s —, e o combo do Berserker não cabe nele:
os quatro golpes dele saem em 0,4333s, 1,2667s, 2,3833s e 2,5667s da animação
`Attack`, ou seja 0,83s, depois 1,12s, depois 0,18s. Os dois últimos quase se
encostam — é o par rápido que fecha o combo.

Para isso o passo aceita `HitTimes`, uma lista de instantes no lugar do
`HitTime`:

```lua
["Berserker"] = {
    AttackSequence = {
        { Animation = "Attack", HitTimes = { 0.4333, 1.2667, 2.3833, 2.5667 }, Duration = 2.9 },
    },
},
```

Com a lista no passo, é ela quem manda: o número de acertos é o tamanho dela e os
intervalos são as diferenças entre os instantes — o `HitTime` e o `HitInterval`
daquela unidade ficam de fora da conta. O `Hits` do `UnitStats` continua tendo que
bater com `#HitTimes`, porque é dele que sai o DPS que o card mostra.

**Os números são os marcadores `Hit` da animação, copiados na mão.** É a mesma
regra do `HitTime` do Archer e pelo mesmo motivo: quem cobra o dano é o servidor,
que não tem `AnimationTrack` nenhuma para escutar. Mexeu o marcador no Moon
Animator, mexe aqui junto — inclusive o `Duration`, que é a duração do arquivo.

**O cooldown conta a animação inteira.** O `Cooldown` do `UnitStats` sempre foi do
início de um golpe ao início do seguinte, então "3 segundos parado depois de
terminar a animação" é a soma dos dois: `2.9 + 3 = 5.9`. Não existe campo de
recuperação separado — a janela de 5,9s é a mesma que o servidor manda no
`swingWindow`, e é ela que faz o cliente **não** espremer a animação (2,9s cabem
folgados em 5,9s), que é o que deixa os 3s de recuperação visíveis na tela.

O `Duration` existe para o caso contrário. Se uma carta de `AttackSpeed` apertar o
ciclo abaixo dos 2,9s da animação, o cliente encolhe o gesto para ele caber
(`Unit:playAttackVisual`) e o servidor encolhe os instantes pelo mesmo fator
(`UnitService:executeAttack`) — sem isso o fim do combo sairia depois de o golpe
seguinte já ter começado, com o boneco no meio de outra animação.

> Por isso o Berserker é a única unidade corpo a corpo sem `CooldownMultiplier` no
> `UnitUpgradeConfig`: a recuperação é a identidade dela, e upgrade nela compra
> dano, não cadência. Os 10% por nível que o Sword e o Slasher têm comeriam os 3s
> parados até 0,58s no nível máximo.

### A área que enfraquece a cada golpe: `HitFalloff`

Cada um dos quatro golpes do Berserker é uma **área de raio 3**, e cada um bate
menos que o anterior:

```lua
AOE = { Radius = 3 },
HitFalloff = 0.1,
```

O `AOE` já existia (é o do Rocket). O campo novo é o `HitFalloff`, e ele é **a
perda de um golpe para o seguinte** — não a perda contra o dano cheio:

| Golpe | Fração do cheio | Dano (base 35) |
| --- | --- | --- |
| 1º (0,4333s) | 100% | 35 |
| 2º (1,2667s) | 90% | 32 |
| 3º (2,3833s) | 81% | 28 |
| 4º (2,5667s) | 72,9% | 26 |

É o que impede que quatro áreas seguidas sejam simplesmente quatro vezes o golpe:
o combo vale **3,44 golpes cheios**, e não 4.

A queda é **por golpe, e não por alvo** — é a diferença entre ela e o
`Projectile.PierceFalloff` da flecha do Archer, que desconta a cada corpo furado
dentro de um tiro só. Aqui todo mundo que estiver na área do segundo golpe leva os
mesmos 32; o que muda de um golpe para o outro é quanto aquele golpe vale.

É **composta**, como a da flecha e pelo mesmo motivo: o terceiro golpe tira 90% do
segundo, e não 80% do cheio, então ela nunca chega a zero — descontar 10 pontos
percentuais de cada vez faria o 11º golpe não machucar e o 12º curar. O
arredondamento acontece uma vez só, na hora de cobrar, e não a cada degrau: em cada
um ele acumularia o erro do arredondamento ao longo do combo. O piso é 1, como no
resto do arquivo.

O campo é genérico: vale para qualquer unidade de vários `Hits`, com os golpes
espaçados por `HitInterval` ou por `HitTimes`. Sem o campo, todos os golpes do
ciclo valem igual — que é como o Azure continua batendo.

### O fogo que não acumula (Pyre)

A primeira unidade `Fire`, Rare: tiro único com o `PyreProjectile`, 15 de dano, e o
acerto deixa o alvo queimando — 3 de dano a cada 0,5s por 10s
(`UnitStats.Pyre.Burn`, executado pelo `MobService:ApplyBurn`).

**A queimadura não acumula nem renova.** Acerto em quem já queima — do mesmo Pyre ou
de outro — só dá o dano do tiro: nem soma tique, nem recomeça o prazo
(`mob.BurningUntil`). O fogo novo só acende depois de o anterior apagar. Os tiques
cobram em nome de quem acendeu.

O desenho é o `Assets.VFX.BurningVFX`: o servidor avisa pelo `MobBurning` só quando
acende fogo novo, e o `VFXController:PlayBurning` solda o asset no inimigo e passa o
Highlight dele para a raiz do modelo — o mesmo caminho do congelamento do Frostione
(`playMobStatus`).

Cada tique avisa a tela pelo `MobBurnTick` (número de dano e barra de vida no
`MobController`): o `DamageMob` não fala com o cliente, e sem esse evento o fogo tirava
vida sem nada aparecer.

Custo (150), alcance (10) e cooldown (2,1s, logo acima da animação de 2,033s) são
provisórios. A queimadura não cresce com upgrade nem clima; só a carta Fire Hazard
mexe nela.

### O raio que salta (Electro)

A quarta forma de um golpe acertar mais de um alvo, e a única sem queda de dano. As
outras três medem quem entra: a **área** pega quem está dentro do raio, a flecha
`Piercing` e o corte do Cleave pegam quem está na **linha**. A corrente do Electro
não mede nada — ela anda:

```lua
["Electro"] = {
    Damage = 18,
    Cooldown = 2.5,                                -- fixo, o upgrade nao mexe
    Chain = { Targets = 4, Radius = 8 },
    Stun  = { Duration = 0.3, MaxDuration = 0.5 }, -- sobe ate 0,5 no maximo
}
```

O primeiro elo é o alvo que a prioridade da torre escolheu. Daí em diante o raio pula
para o inimigo mais próximo **do último tocado** que ainda não está na corrente e está
a no máximo `Radius` dele, até `Targets` inimigos ou até não haver mais ninguém ao
alcance do último salto (`MobService:GetChainTargets`).

**O raio é medido de cada inimigo, e não da unidade** — é o que separa a corrente de
uma área. Três saltos de 8 studs chegam a 24 studs da unidade, que tem alcance 10:
quanto melhor o mapa enfileira, mais longe a corrente vai. A contrapartida é que ela
morre num buraco — inimigo isolado a 35 studs do anterior não recebe o salto, mesmo
sobrando elo.

**Não há queda por inimigo.** O quarto leva os mesmos 18 do primeiro, e é a única
forma de acerto múltiplo do jogo assim (a flecha tem `PierceFalloff`, o corte tem
`Falloff`, o combo tem `HitFalloff`). O preço disso está no `Targets` e no `Cooldown` —
é neles que se mexe se a unidade ficar forte demais, e não numa queda que ela não tem.

**Ela vende alcance de golpe, não dano por alvo.** 4 × 18 a cada 2,5s dão 28,8 de DPS
com a corrente cheia, 9,6 por 100 de caixa — dentro do teto da regra 1 de `UnitStats`.
Contra um alvo sozinho são 7,2 de DPS (2,4 por 100), e aí ela é das piores da tabela.

Em cima disso vem o tranco: cada elo **para no lugar** por 0,3s. Não é lentidão, e a
diferença é de mecanismo e não de intensidade:

| | O que faz | Onde mora |
| --- | --- | --- |
| `Stun` | tira o inimigo do laço de movimento — parado de vez | `MobService:StunMob` |
| `Slow` | mexe na velocidade com que ele anda | `MobService:ApplySlow` |

Os dois são campos genéricos que qualquer unidade pode declarar, aplicados pelo
`creditDamage` a cada elo que levou dano. **O Electro declara só o `Stun`** — o inimigo
para e volta a andar no ritmo de sempre. O `Burn` é do Pyre (ver abaixo), e o `Slow`
direto continua sem dono — o Frostione usa a lentidão por dentro do `ApplyFrost`.

O tranco vai de 0,3s parado num ciclo de 2,5s no nível 0 (12% do caminho que os quatro
andariam) a 0,5s no nível máximo (20%). Isso ainda é tropeço, não controle — quem para
inimigo de verdade é o Time Stop, e custa uma carta. O número que separa uma coisa da
outra é o `Stun.Duration`: subir o tranco para perto do ciclo inteiro vira "a fila anda
quando o Electro deixa", que é outra unidade.

**O cooldown é fixo; o upgrade compra dano, alcance e tranco.** O Electro não tem
`CooldownMultiplier`, e o tranco sobe em linha reta (`UnitUpgradeConfig:GetStunDuration`,
que lê o `Stun.MaxDuration`):

| Nível | 0 | 1 | 2 | 3 | 4 | 5 |
| --- | --- | --- | --- | --- | --- | --- |
| Tranco | 0,30 | 0,34 | 0,38 | 0,42 | 0,46 | 0,50 |

O `creditDamage` e o `ChainLightning` (o realce amarelo) leem o mesmo
`GetStunDuration` com o nível da unidade, então o inimigo fica amarelo exatamente o
tempo em que está parado, em qualquer nível.

O realce amarelo dura exatamente o tranco. É curto de propósito — ele é o estado, e
sobreviver ao próprio motivo faria o jogador achar que o inimigo continua preso.

**O desenho sai do servidor, no frame do marcador.** O `HitTime = 1.05` do
`UnitAttackConfig` é o marcador `Hit` da animação `Attack` (1,6667s), e é o windup do
`executeAttack`: na mesma linha em que a corrente cobra dano, o servidor dispara
`ChainLightning` com os elos na ordem do salto. Deixar o cliente escolher os alvos
poria o raio em inimigos que não levaram nada.

O evento é escutado por dois controllers, como o `UnitStunned`:

| Quem | O que faz |
| --- | --- |
| `VFXController` | um arco da unidade até o 1º elo, e de cada elo para o seguinte |
| `MobController` | o realce amarelo em cada inimigo, enquanto o tranco durar |

O arco é o mesmo asset do raio do clima (`WeatherConfig.Thunder.Asset`, pelo
`spawnBeam`) — é o mesmo addon desenhando a mesma coisa, e os dois se parecem de
propósito. As pontas usam o modelo do inimigo quando ele já replicou, e não a posição
que veio no evento: o cliente simula o andar dos mobs por conta própria, então a
posição do servidor já está alguns quadros atrás na hora de desenhar.

**O impacto é mais baixo que o do clima, e é a única diferença entre os dois.** Onde o
raio bate é o Attachment da ponta do asset que manda, e ele vem autorado como um raio
caindo do céu: tag `CraterVFX` com 40 detritos, mais `CameraShake` e `ImpactFrames`.
Numa corrente isso sai **por elo** — quatro pontas no mesmo quadro seriam quatro
tremores de câmera, quatro impact frames e 160 detritos a cada golpe, a partida
inteira. O `spawnBeam` aceita um `impact` opcional, e só a corrente manda um
(`CHAIN_IMPACT`, no `VFXController`): a cratera fica, menor (6 detritos num raio de 3,
com pouco mais da metade do tamanho autorado), e o tremor e o impact frame saem. Os dois saem por **apagar** o atributo, que é como o
addon desliga (`if not attr then return end`) — zerá-lo continuaria ligando o efeito.
A mexida é sempre no clone; o asset fica intacto e o raio do clima continua chegando
inteiro.

O realce é o mesmo amarelo da unidade atordoada (`255, 200, 60`), e é ele que faz a
lentidão aparecer — sem ele o jogador veria o raio e não teria como ligar uma coisa à
outra.

**Ela é a primeira unidade `Electric` do roster**, então três coisas que já existiam
passaram a ter dono: o bônus passivo de +10% de dano no clima de trovão
(`Effects.Thunder.Units.Electric`), a carga temporária de quem leva um raio em cheio
(`Thunder.Charge`) e as cartas de round Overcharge e a de +15% para Electric.

## Cartas de round

De X em X waves a loja da beirada oferece três cartas sorteadas. O catálogo inteiro
mora em `RoundCardConfig.Cards`, e cada entrada diz três coisas que o resto do
sistema lê: **como ela é usada**, **o que ela faz** e **qual é a arte dela**.

**O sorteio não varre o catálogo, varre o que o jogador destravou.** As cartas são
compradas na loja de cartas do lobby (ver [A loja de cartas do lobby](#a-loja-de-cartas-do-lobby)),
e o que ele destravou mora em `Data.RoundCards`. Antes o `CardShopService._pool`
oferecia as vinte e tantas cartas a todo mundo na primeira partida — e a loja do
lobby não teria o que vender. Hoje são dois filtros em fila:

| Filtro | Onde | Corta |
| --- | --- | --- |
| efeito registrado | `CardShopService:_pool` | carta cujo `Effect` não existe em `Effects` — para ninguém |
| carta destravada | `CardShopService:_poolFor` | carta que **este** jogador não comprou no lobby |
| carta descansando | `CardShopService:_poolFor` | carta de prazo que ele usou na abertura passada |
| carta gasta | `CardShopService:_poolFor` | carta de uma vez só que ele já comprou nesta partida |

Jogador sem nenhuma carta destravada não recebe oferta, e a dele é apagada em vez de
deixada como estava: sem isso ele ficaria com a oferta da wave de loja anterior na
tela, e o `Token` novo faria cada clique nela ser recusado como "oferta vencida".
Perfil que ainda não carregou conta como vazio — liberar tudo enquanto o dado não
chegou daria uma oferta que o jogador não pagou.

Perfil novo nasce com seis destravadas (`RoundCardShopConfig.STARTER_CARDS`): as três
instantâneas originais — Time Stop, Time Acceleration, Weather Report — mais Trumpet,
Bloxy Cola e Bloxiade. Sem elas a oferta de round simplesmente nunca abriria para quem
acabou de chegar, e ele não teria como ligar isso a uma loja do lobby que ainda não
visitou — é o mesmo motivo pelo qual o `Units` do template já entrega Slasher, Sword e
Slingshot. As três últimas entraram para o kit ter uma carta de alvo: sem nenhuma,
`Use.Unit` só seria descoberto depois de uma compra de shards às cegas. Esvaziar a
lista fecha a oferta para quem nunca comprou nada: é uma linha, e é uma decisão de
design.

**O kit é retroativo**, e é a única parte dele que precisa de código: o reconcile do
`DataService` cria a chave `RoundCards` onde ela falta, mas não mexe numa que já
existe, então uma carta acrescentada à lista valeria só para contas criadas depois
dela. Quem escreve o que falta é o `RoundCardStarterService` (`common/server/Services`,
porque as duas places abrem perfil), a cada `PlayerDataLoaded`, e só quando falta —
quem já comprou uma delas com shards não é tocado nem reembolsado.

### As cartas de prazo descansam

**Carta cujo efeito vence sozinho sai do sorteio dela por uma abertura.** Usada a
oferta da wave 4, ela não pode ser sorteada na da wave 8 e volta na da 12; o
`CardShopService:_rest` escreve `Token + 1` em `Resting[userId][cardId]` e o
`_poolFor` corta enquanto a abertura de agora não passar desse número. É por jogador,
como a pool: quem não usou continua podendo sorteá-la.

Quem conta como "de prazo" é o próprio config — `Params.Duration` maior que zero
(`_isTemporary`) —, e não uma lista escrita à mão: carta nova com prazo já nasce
descansando, e uma que perca o prazo num ajuste de balanceamento para de descansar no
mesmo commit. Hoje são seis: Time Stop, Time Acceleration, Trumpet, Azure Ever Ice,
Bloxy Cola e Bloxiade. O Staff of Healing fica **de fora** apesar dos dez segundos de
imunidade dele, porque o número dele se chama `Params.Immunity`.

O descanso é contado em aberturas da loja, e não em waves nem em segundos: numa
dificuldade de intervalo 6 ele é mais longo que numa de 4, o que é o certo — o que é
escasso é a oferta, e não o relógio. Nada disso aparece na tela: de uma oferta de três
cartas não dá para deduzir quais não foram sorteadas, e a carta volta sozinha.

### As cartas que empilham são de uma vez só

**Carta que empilha em cima de si mesma sai da mesa do jogador na compra e não volta
nesta partida.** São três condições ao mesmo tempo (`CardShopService:_isStacking`), e
todas saem do próprio config:

1. o efeito é uma **regra no campo** (`Effect = "Modifier"`) — e a lista do
   `CardModifierService` aceita duas cópias do mesmo registro, que se multiplicam;
2. ela **não tem prazo**, então a regra vale até o fim do round;
3. ela **não desenha área**, então o que ela muda é o mapa inteiro.

As três juntas são o único caso em que recomprar a mesma carta é sempre a melhor
jogada possível: Overcharge duas vezes é 1.56x de dano em Electric, três vezes é 1.95x,
e nada freava isso. As outras já se resolvem sozinhas — a de prazo vence, a de área
esbarra no chão (duas do mesmo jogador não podem se tocar) e a que não é `Modifier` não
empilha regra nenhuma: Money Bag dá dinheiro, Zippers move uma torre, Weather Report
limpa o céu de uma wave. Essas três continuam repetíveis.

São onze hoje: Overcharge, Watts Up, Punch Line, Axecellent, Cleave It To Me,
Abrakadabra, Iceolated, Ice To Meet You, Chill Out, Fire Hazard e No Pain No Gain.

**A marca é posta na compra, e não no uso** (`_spend`, chamado do `Buy`): a carta
comprada é uma decisão já tomada, mesmo que passe a wave inteira na hotbar. Sem isso o
jogador guardaria três cópias do Overcharge na mão e as usaria de uma vez, que é
exatamente o empilhamento que a regra tira do jogo. O `Use` remarca por garantia, para
o caso de uma carta ter chegado à mão por fora da loja.

Vale a partida, e não o perfil: a próxima começa com o catálogo inteiro na pool de cada
um, como o caixa e a hotbar. A consequência esperada é que **a pool encolhe conforme a
build é montada** — quem destravou poucas cartas e comprou as que empilham pode ficar
com uma oferta de menos de três (o `Draw` já devolve o que houver) ou sem oferta
nenhuma. O kit inicial não tem nenhuma delas, então quem acabou de chegar nunca fica
sem loja.

### O tipo de uso

`Use` diz o que a carta pede entre o clique na hotbar e o efeito:

| `Use` | O clique na hotbar… | Exemplo |
| --- | --- | --- |
| `Instant` | já é o uso | Time Stop, Money Bag, Trumpet |
| `Unit` | pede uma torre; o próximo clique no mapa escolhe | Bloxy Cola, Bloxiade |
| `Area` | pede um lugar; um anel segue o ponteiro | os cajados, Staff of Healing |
| `Move` | pede os dois, nesta ordem: a torre e o destino | Zippers |

Carta sem `Use` é `Instant` — é o que as três cartas originais sempre foram.

**Uma carta em mira é uma carta na mão**, e a hotbar a desenha como desenha uma
unidade equipada: ela cresce (`setSelectedRound`) e as vizinhas apagam. Não há
painel nem botão de cancelar — o feedback é a própria carta, e desistir é clicar
nela de novo, igual a largar uma unidade (Esc também serve, no PC). O botão
direito ficou de fora de propósito: no PC ele é a câmera, e quem gira a tela
procurando onde pôr o anel cancelaria a carta sem querer.

Enquanto a mira dura, **o clique no mundo pertence à carta**: o
`RoundCardShopController` tranca a seleção de torre do `UnitPlacementController`
(`setPointerLocked`, que larga o fantasma, a torre selecionada e a carta de unidade
equipada) e a destranca quando a mira acaba, de que jeito for. Sem isso o mesmo
clique escolheria o alvo *e* abriria o card de upgrade daquela torre — e o fantasma
de uma unidade equipada disputaria o mesmo clique.

A carta só é gasta quando o servidor confirma o uso, e **um alvo recusado não gasta
a compra**: o `CardShopService:Use` confere o alvo *antes* de tirar a carta da mão.

### O que a carta faz

Quase tudo que uma carta faz é **deixar uma regra valendo no campo**, e essa regra
tem gramática própria: o `SharedConfig.CardModifier`. Por isso são sete efeitos no
`CardShopService.Effects` para as duas dezenas de cartas do catálogo — a maioria
usa `Effect = "Modifier"` e descreve em `Params.Modifiers` os registros que cria:

```lua
-- Electric bate 25% mais; todo o resto, 11% menos.
Params = {
    Modifiers = {
        { Classes = { "Electric" }, Stats = { Damage = 1.25 } },
        { Classes = { "Electric" }, Exclude = true, Stats = { Damage = 0.89 } },
    },
},
```

Um registro filtra por classe (`Classes` / `Exclude`), por tipo (`Farm`), por
unidade (`Target = true`, preenchido com a torre escolhida), por área
(`Zone = true`, preenchido com onde o jogador desenhou o anel) ou pela vizinhança
(`Condition = "Isolated"` / `"NearClass"`, recontada a cada quadro de combate).
`Duration` dá prazo em tempo de partida; **sem ele, a regra vale até o fim do
round**.

Carta nova que só mexa em números não precisa de código nenhum: ela é uma entrada
no `RoundCardConfig` e mais nada.

**Quem guarda a lista é o `CardModifierService`**, e é ele quem a poda e a replica
inteira aos clientes (`RoundCardModifiers`). O cliente precisa dela para duas
coisas que só existem na tela: desenhar o anel dos cajados no chão e mostrar o
alcance **de verdade** no círculo de seleção e no card — as duas pela mesma função
que o servidor usa, e não por uma segunda conta que possa divergir dela.

O combate lê os multiplicadores uma vez por quadro
(`UnitService:refreshCardModifiers`), e não uma vez por pergunta: duas das
condições varrem a vizinhança inteira para responder, e perguntar por unidade e por
estatística multiplicaria essa varredura por cinco.

### Os dois anéis

São desenhos diferentes para momentos diferentes, e é de propósito:

- **o da mira** é o círculo neutro do posicionamento (`Assets.UI.AOE.Ring`), colorido
  pelo tipo de alvo. Ele só existe entre o clique na carta e o clique no mapa, e diz
  "esta área";
- **o do chão** é a arte da carta (`Assets.VFX.Rings`, escolhida pelo campo `Ring`
  dela — `Celestial`, `Robux`, `Windy`, `Healing`, ou `Base` para quem não declara).
  Ele nasce onde o jogador clicou, **com o mesmo raio que ele viu na mira**, e vive o
  tempo do efeito.

O raio sai da mesma `Zone` que o servidor replica, então os dois nunca discordam. A
escala do Model é medida pela Part `<nome>_Ring` de dentro dele, e não pela caixa do
Model: um Model de VFX tem emissor e attachment espalhados, e medir a caixa inteira
faria o anel encolher só porque alguém arrastou uma faísca para fora dele.

O Staff of Healing não deixa zona nenhuma — o efeito dele acontece num instante —,
mas a **imunidade** que ele dá dura dez segundos. Por isso ele declara um
modificador sem `Stats` nenhum: ele não modifica nada, ele *é* o anel, e nasce e
morre junto com a imunidade que representa.

### O buff e o debuff em cima da unidade

O que uma carta faz com uma torre aparece **na torre**: o mesmo Highlight e a mesma
billboard na cabeça que o clima já usava (`WeatherFeedbackController`). O
vocabulário — asset, cores e a lista de ícones — é `WeatherConfig.Feedback.Stats`,
que deixou de ser "os ícones do clima" e passou a ser "os ícones da billboard":
dano, alcance, cooldown e **dinheiro** (`BuffEco` / `DebuffEco`, que cobre `Income`
e `HitIncome` num ícone só, porque para o jogador é um número só — o do bolso).

São três camadas e elas **se multiplicam**, por estatística:

1. o clima;
2. as cartas já usadas (a lista do `CardModifierController`);
3. a **prévia** — uma carta que está sendo mirada agora e ainda não foi usada.

O ícone que acende é o do efeito líquido: neblina (0.7 de alcance) com o Staff of
the Winds (1.2) dá 0.84 e acende `DebuffRange`, e não os dois ícones lado a lado.
`Kind` é `Debuff` sempre que houver um debuff junto, que é o caso normal de quem
está dentro do anel de um cajado — ganha numa coisa, paga em outra.

**A torre sob o ponteiro fica amarela** enquanto uma carta procura alvo, e é um
realce só: quem o pinta é o `WeatherFeedbackController` (junto com os ícones do que
ela vai sentir) nas cartas que mexem em estatística, e o próprio
`RoundCardShopController` nas que não mexem — o Zippers. A cor mora em
`Targeting.Colors.Unit`, e os dois a leem de lá. Dois Highlights no mesmo modelo
deixariam as duas cores brigando.

**Duas áreas do mesmo jogador não podem se tocar.** O anel da mira fica vermelho
(`Targeting.Colors.Blocked`) onde ele encostaria numa área que aquele jogador já
desenhou, e ali o clique não vale — a carta continua na mão e a mira aberta, como no
clique no céu. A conta é a distância entre os centros contra a soma dos raios, ignorando
o `Y` (o anel é um círculo no chão, e o mapa tem altura), e ela existe em dois lugares
de propósito: o `CardModifierController:FindZoneOverlap` pinta, o
`CardModifierService:FindZoneOverlap` recusa o uso. As duas leem a mesma lista
replicada, então não existe lugar verde onde o clique não valha.

Sem a regra, empilhar três cajados no mesmo punhado de torres multiplicava os três
buffs no mesmo lugar e a decisão que a carta vende — *onde* desenhar o anel — deixava
de existir: o melhor lugar era sempre o lugar do anel anterior. **Só as áreas do próprio
jogador contam**: numa sala de quatro, negar o chão por causa do cajado de outro tiraria
do mapa os poucos pontos que valem a pena para quem chegou depois.

Quem sabe de quem é a área é o `OwnerUserId` que o `CardModifierService:Apply` guarda
no modificador — ele não muda nada do que o modificador faz, e existe só para esta
pergunta. Zona vencida não segura lugar: a leitura passa pelo `GetActive`, que poda o
que expirou.

No instante em que a carta encosta na torre, ela solta o `AppliedVFX`
(`Assets.VFX.EffectUnitAppliedVFX`), pendurado na `HumanoidRootPart` dela e
estourado pelo `VFXController`. Quem dispara é o servidor, para todo mundo na sala
ver o estouro na mesma torre — e só depois de o efeito ter dado certo, senão o
estouro prometeria uma coisa que não aconteceu.

**A prévia é o ponto.** Arrastando o anel de uma carta de área pelo mapa, cada torre
que ele alcança acende com o que ela vai sentir, e apaga quando o anel sai de cima
dela; numa carta de alvo único é a torre sob o ponteiro que acende. É o mesmo
desenho do efeito de verdade, de propósito — a decisão "onde ponho o cajado" é
tomada olhando o mapa, e não relendo a descrição da carta.

A varredura roda a cada quadro enquanto a mira estiver aberta, e por isso ela é
barata de propósito: o `world` é montado uma vez por varredura (e não por torre), o
anel só refaz a prévia quando anda mais de `PREVIEW_STEP`, e cada torre compara uma
assinatura antes de reescrever a billboard.

### Duas cartas ainda não fazem nada

`Chill Out` (+10% na lentidão do gelo) e `Fire Hazard` (+20% no dano de
queimadura) são multiplicadores globais que o `MobService` lê (`ApplySlow`,
`ApplyBurn`). Hoje a lentidão é a dos acúmulos do Frostione e a queimadura é a do
Pyre, então as duas já valem.

## A loja de cartas do lobby

`StarterGui.ShopUI.RCSS`, do `RoundCardShopController` (Lobby) e do
`RoundCardShopService` (Lobby). Ela vende **acesso** às cartas de round: a compra
escreve o `Id` em `Data.RoundCards` e é essa tabela que a oferta de round sorteia
lá dentro. Comprar é destravar — usar continua sendo comprar de novo, na partida,
com o caixa da partida.

Ela abre por proximidade, igual à de caixas, pelos marcadores
`ShopCardPartReference` e `ShopCardPartTeleport` (hoje dentro de
`Map.Deco.Houses.CardShop`, achados em profundidade sob `Workspace.Map`). O raio é o
mesmo balcão de 5 studs, e o pouso está a 18,8 studs dele — portanto **fora** do
raio, exatamente como na loja de caixas: `TeleportToShop` abre o painel na mão e
marca a entrada, para que andar embora feche do mesmo jeito.

Quem chama o teleporte é o botão `CardShop` da HUD (`HUD.HUDFrame.Wrapper.CardShop`),
irmão do `Shop` que faz o mesmo pela loja de caixas. O clique é a única coisa que o
`RoundCardShopController` liga nele: **o crescer e o afundar do botão são do
`HUDButtonController`**, que liga todo `GuiButton` debaixo do `HUDFrame` — botão novo
na HUD entra na animação dos outros sem uma linha de código.

### A vitrine é de cada jogador, e sai da hora

Três cartas por bloco de quatro horas, **sorteadas por jogador**: dois amigos no mesmo
lobby veem ofertas diferentes. E **nada disso é guardado** — o bloco vem de `os.time()`
(`rotationIndex`) e as três cartas são recalculadas dele mais o `UserId`, com um
`Random` semeado (`stockFor`). Foi para isso que o `RoundCardConfig.Draw` ganhou um
terceiro parâmetro `rng`: sem semente própria o sorteio dependeria do `math.random`
global, que cada servidor gasta de um jeito diferente, e a mesma pessoa veria cartas
diferentes em cada lobby.

O que é de todo mundo é o **relógio**. Os blocos caem em 00:00, 04:00, 08:00… UTC, e é
por isso que o `ResetText` continua querendo dizer alguma coisa: as vitrines são
pessoais, mas todas viram no mesmo instante. A contagem é escrita de segundo em segundo
contra o `ResetsAt` que o **servidor** mandou — só ele concorda com o bloco em que a
vitrine foi sorteada.

**Isso só funciona porque a pool não muda.** O sorteio varre o catálogo inteiro,
inclusive as cartas que o jogador já destravou — são elas que aparecem com o véu `SOLD`.
Uma pool que encolhesse a cada compra faria a vitrine se remontar sozinha; é exatamente
o que acontecia com o reroll, e é por isso que **ele** é gravado e ela não.

As duas parcelas da semente (bloco e jogador) **têm de ter multiplicadores diferentes**
(`ROTATION_SEED` e `PLAYER_SEED`). Com a mesma constante nas duas, bloco e jogador viram
intercambiáveis dentro da soma e a vitrine de alguém hoje seria a de outro alguém
amanhã. Foi um bug de verdade na primeira versão do reroll — ver abaixo.

Consequências que valem lembrar:

- um servidor que sobe no meio do bloco chega na mesma vitrine para cada jogador;
- não há DataStore nenhum para uma coisa que a hora e o dono já respondem;
- **mudar a ordem das entradas em `RoundCardConfig.Cards` muda a vitrine de todo
  mundo.** Não é um problema, é só o que acontece quando o catálogo muda.

O que o servidor guarda por bloco é só `{ Index, ResetsAt }` (`GetBlock`); as cartas
saem do `GetStockFor`, por jogador.

Quando o bloco vira, o servidor empurra a vitrine nova para quem está no lobby
(`_watchRotation`, que dorme até o reset em vez de checar a cada segundo). O cliente
também pede sozinho quando a contagem dele chega a zero, e as duas coisas juntas são
de propósito: o empurrão cobre quem está com a loja aberta na hora da troca, e o
pedido cobre a diferença de relógio entre as duas pontas.

### O reroll troca as três cartas daquele jogador

O dado (`RCSS.ImageLabel.RerollDice`) abre o developer product **3712166271**
("Reroll Card Shop", 14 Robux). Quem compra troca as três cartas na hora.

Como a vitrine já é de cada um, o reroll não precisa inventar nada — ele só muda a
**origem** das três cartas: em vez de saírem do sorteio do bloco, passam a sair do que
ficou gravado no perfil, até o bloco virar.

A contagem do `ResetText` **não muda** com o reroll: ela é o relógio da rotação, e é
exatamente quando a prateleira paga expira e o jogador volta ao sorteio do bloco novo.
Um reroll compra cartas, não tempo.

**A prateleira sorteada é gravada** em `Data.RoundCardRoll`:
`{ Index, Rolls, Cards }` — o bloco, quantos rerolls foram comprados nele e os `Id`
das cartas. O registro velho não precisa ser apagado: ele deixa de valer sozinho
quando o número do bloco muda.

Gravar foi uma correção, e vale saber de quê. A primeira versão não guardava as
cartas: ela as recalculava de uma semente feita de (bloco, jogador, nº de rerolls),
para a prateleira se reconstruir igual em qualquer servidor sem ocupar espaço no
perfil. Só que o sorteio do reroll varre **só o que falta ao jogador destravar**, e
essa pool encolhe quando ele compra — inclusive quando compra uma carta da própria
prateleira rerolada. Recalculando, a vaga vendida se enchia com uma carta nova em vez
de ficar `SOLD`:

```
prateleira paga : WindsStaff, NoPainNoGain, Trumpet
comprou WindsStaff
recalculada     : RobuxRoyaltyStaff, NoPainNoGain, Trumpet   <- vaga recarregada
```

Um reroll só dava acesso ao catálogo inteiro, uma compra de cada vez. (A vitrine
normal não tem esse problema mesmo sendo calculada: ela sorteia do catálogo inteiro, que
não muda quando o jogador compra.) **Uma prateleira é um resultado, e não uma fórmula** — a fórmula tinha um ingrediente que o próprio
jogador mexe. Três strings no perfil são mais simples do que qualquer semente, e é por
isso que o sorteio do reroll (`drawReroll`) usa `math.random` puro: o que ele devolve
é gravado, então não precisa ser reproduzível, precisa ser imprevisível.

**O reroll evita carta já vendida, em melhor esforço.** Um reroll pago que devolvesse
três cartas que o jogador já tem seria Robux por nada
(`RoundCardShopConfig.REROLL_EXCLUDES_UNLOCKED`). O `splitByUnlocked` parte o catálogo
em duas pools disjuntas — o que falta e o que ele já tem — e o `drawReroll` enche as três
vagas com a primeira, só completando com a segunda quando faltam menos de três cartas:

| Cartas que ele já tem | Vitrine do reroll |
| --- | --- |
| 0 a 21 | 3 cartas, nenhuma `SOLD` |
| 22 | 3 cartas, 1 `SOLD` |
| 23 | 3 cartas, 2 `SOLD` |
| 24 (tudo) | botão desligado; não chega a sortear |

Completar em vez de encurtar é de propósito: três vagas com uma `SOLD` é uma vitrine, e
duas cartas num painel de três é uma vitrine quebrada. E quando não falta **nada** o
botão fica desligado — a hora de impedir uma compra inútil é antes do prompt, porque
depois do recibo a Roblox já cobrou.

O caminho da compra não passa por evento nenhum de "quero rerolar":

1. o cliente clica e chama `MarketplaceService:PromptProductPurchase`;
2. a Roblox cobra e manda o recibo para o servidor;
3. o `ProcessReceipt` do `MonetizationService` acha o callback registrado pelo
   `RoundCardShopService` e chama `Reroll(player)`;
4. `Reroll` sobe o contador do bloco e manda a prateleira nova pelo `RoundCardStock`.

Um pedido do cliente só poderia abrir o prompt (que ele já abre sozinho) ou creditar
sem pagamento — e a única prova de que houve pagamento é o recibo. `Reroll` devolve
`false` quando não deu para escrever no perfil, e aí o receipt volta como
`NotProcessedYet`: a Roblox tenta de novo mais tarde em vez de dar por entregue uma
compra que não aconteceu.

No cliente, o redesenho compara `Index` **e** `Rolls`. Um reroll não muda o bloco, e
comparando só o índice as cartas pagas chegariam sem serem desenhadas.

**Perfil ainda carregando não é "não rerolou".** O cliente pede a vitrine quando a
`ShopUI` monta, e isso acontece antes de o `StartSessionAsync` voltar. Enquanto o
`GetStockFor` respondia o sorteio do bloco nessa janela, o reroll parecia não persistir:
o cliente guardava a resposta errada, o retry dele encerrava (recebeu algo) e a
prateleira paga só reaparecia no reroll seguinte — embora estivesse gravada no perfil o
tempo todo. (Hoje o `GetStockFor` também precisa do perfil para a vitrine **normal**,
já que ela depende do `UserId`, então a guarda vale para os dois caminhos.)

Hoje `GetStockFor` devolve `nil` sem perfil e ninguém responde por adivinhação. Os dois
lados da corrida estão cobertos: o `RequestRoundCardStock` passa pelo `DataService:Get`
e responde **quando** o perfil chega, e o `PlayerDataLoaded` empurra a vitrine sozinho
para cobrir o pedido que se perdeu inteiro (o cliente pode ligar a loja antes de o
service registrar o `Listen`, e o retry dele tem teto). A loja abre vazia por um
segundo em vez de abrir com a prateleira errada e ficar nela.

Uma vitrine rerolada pode ter **menos de três cartas**, quando faltavam menos que isso
para o jogador destravar — a global sempre tem três. O cliente desenha quantas vierem.

### Dois consertos que o primeiro dev product do jogo exigiu

O reroll é o **primeiro** developer product vendido no jogo, e o caminho dele estava
quebrado em dois pontos que nunca tinham sido exercitados:

- **`DataService:Save` não existia no Lobby.** O `ProcessReceipt` chama
  `DataService:Save(player)` antes de devolver `PurchaseGranted`, e só a Game tinha o
  método. Como o reroll é do Lobby, o `ProcessReceipt` erraria ali dentro: nenhuma
  compra seria creditada, e a Roblox retentaria o recibo para sempre. O método foi
  transplantado da Game (mesmo formato de `Profiles[Player]`).
- **`RegisterProduct` dependia da ordem de boot.** Ele escrevia em `self.Callbacks`,
  que o `construct` do `MonetizationService` criava com `= {}`. Os `start()` dos
  services são `task.spawn`ados num laço sem ordem garantida, então um service que
  registrasse um produto antes teria o callback apagado — ou erraria, com a tabela
  ainda nil. Agora os dois lados usam `or {}`.

Nenhum dos dois dava sintoma antes porque não havia produto para vender.

### `SOLD` é o que este jogador já tem

A vitrine é a mesma para todo mundo, então o que muda de jogador para jogador não é
quais cartas aparecem, é quais delas ele já destravou: essas ficam com o véu
`SoldFrame` aceso e o botão `Buy` inativo. O véu acompanha o `RoundCards` da
**replica**, e não a resposta da compra — a mesma escrita que o servidor acabou de
fazer já chega pelo perfil, e acender nos dois lugares daria duas fontes para o mesmo
estado. Comprar com a loja aberta só acende o véu: a fileira não é redesenhada,
senão as três cartas cairiam de novo na frente de quem acabou de clicar numa delas.

Junto com o véu, **o título e a descrição da carta apagam**. O véu é um escurecido com
`SOLD` escrito por cima, e o texto da carta atravessava os dois — a descrição encavalava
no `SOLD` e o painel virava um borrão de letras. Uma carta já destravada não precisa se
explicar: o que ela é o jogador já sabe, e o que importa ali é que ela não está à venda.

É `Visible`, e não transparência: a revelação da carta (`UIUtil.applyFades`) escreve nas
transparências dessas mesmas labels, e as duas brigariam pela mesma propriedade.
`Visible` esconde por fora e deixa a animação rodar por baixo sem saber de nada.

### Preço

De 4 a 8 shards, **escritos carta a carta** em `RoundCardShopConfig.PRICES` — uma
linha por carta do catálogo, agrupadas pelo que custam. Mexer no preço de uma carta é
mexer no número dela ali, e mais nada.

Os números de hoje seguem o que a carta custa em caixa dentro da partida (o `Price`
dela no `RoundCardConfig`, de 150 a 500): o que é caro no round é caro para destravar.
Isso é de onde a primeira versão da tabela saiu, e não uma regra que o código imponha
— qualquer número pode ser mudado sozinho. A distribuição atual é um sino: uma carta
em cada ponta (Zippers em 4, Celestial Staff em 8) e o miolo entre 5 e 7.

`MIN_PRICE`/`MAX_PRICE` não decidem preço nenhum; eles **prendem** o que está escrito.
Um `12` digitado por engano vira 8 e um `0` vira 4, então a loja nunca chega ao jogador
fora da escala combinada.

Carta que exista no `RoundCardConfig` e não tenha linha na tabela não quebra a loja:
`priceOf` estica o custo de partida dela na faixa e devolve um número plausível. É uma
rede, e não o caminho — carta nova merece uma linha decidida por quem está balanceando.

O número vai para `Card.Buy.TextLabel` pelo mesmo `PRICE_FORMAT` da loja de caixas
(só o número; o ícone da shard e a cor do contorno já estão autorados no botão,
porque esta loja cobra numa moeda só).

### As duas lojas dividem a `ShopUI`

`ShopUI.Frame` é a loja de caixas e `ShopUI.RCSS` é a de cartas — irmãs na mesma
`ScreenGui`. Por isso **nenhuma das duas manda no `Enabled` sozinha**: quem diz qual
painel está na tela é o `Visible` do wrapper de cada uma, e o `_setShopEnabled` de
cada controller pergunta ao outro (`IsOpen`) antes de apagar a ScreenGui das duas.

Antes disso o `ShopController` acendia o wrapper dele uma vez no bind e nunca mais
apagava — o que hoje poria as duas lojas na tela sempre que qualquer uma abrisse.
Esse era o problema real; a pergunta ao vizinho é a rede de segurança em volta dele.

Pela proximidade as duas não chegam a se cruzar: os balcões estão a **274 studs** um
do outro e os raios são de 5, e enquanto uma loja está aberta o `Hide` esconde a HUD
inteira — o botão que levaria ao outro balcão nem fica clicável. A guarda existe para
quem abre um painel **sem** passar por um balcão, já que `Open` é público.

### O que as duas lojas passaram a compartilhar

A segunda loja não copiou a primeira; o que era comum saiu para `common/shared/Util`:

| Módulo | O que é | Quem usa |
| --- | --- | --- |
| `ButtonUtil.bindFeedback` | o peso do botão de comprar (cresce no hover, afunda no aperto) | as duas lojas |
| `MarkerUtil` | achar um marcador sob `Workspace.<mapa>` em profundidade, com cache e aviso único; ler o pivot e a meia altura dele | as duas lojas |
| `LightingUtil.GetUIBlur` / `.TweenUIBlur` | o `UIBlur` **único** do Lighting, com a marca do `LightingKeep` | as duas lojas e o `UILibraryController` |
| `UIUtil.captureFades` / `.applyFades` | ler as transparências autoradas de um clone e levá-las de 1 até lá | a loja de cartas do lobby e a de round (Game) |

O `UIUtil` é o que atravessa as duas places: a carta que cai e se revela na loja do
lobby é a mesma animação da carta da oferta de round, então a varredura de
propriedades de transparência é uma só. O controller da Game guarda um embrulho de
quatro linhas em cima dela, porque só ele precisa das duas curvas (a entrada chega
desacelerando, a saída sai acelerando).

Cada carta da vitrine é um clone do `CardWrapper` autorado, e é a `Card` **dentro**
do wrapper que anima: o wrapper é quem ocupa a vaga no `UIListLayout`, então a carta
se mexe à vontade sem o layout arrastá-la de volta a cada quadro. Os tempos são os do
`RoundCardConfig.Animation`, os mesmos da oferta de round.

### Eventos

| Evento | Direção | Para quê |
| --- | --- | --- |
| `RequestRoundCardStock` | cliente → servidor | pede a vitrine (com reenvio, ver abaixo) |
| `RoundCardStock` | servidor → cliente | `{ Index, ResetsAt, Cards = { { Id, Price } } }` |
| `RequestBuyRoundCard` | cliente → servidor | `cardId` |
| `RoundCardPurchaseResult` | servidor → cliente | `cardId, success, reason` |

O reroll não tem evento próprio de propósito — ver o caminho da compra acima.

`reason` é um de `NotLoaded`, `NotInStock`, `AlreadyOwned`, `NotEnoughCurrency`,
`GrantFailed`. Nenhum deles é erro de programa: são as maneiras de o pedido estar
velho ou repetido — o clique duplo, a vitrine que virou entre o desenho e o clique,
o evento mandado à mão.

A cobrança confere a vitrine **daquele jogador** na hora atual — `GetStockFor`, e não
`GetStock`: quem rerolou está olhando para outra prateleira, e conferir contra a global
recusaria justamente as cartas que ele pagou para ver. (E não o `priceOf` direto, senão
o catálogo inteiro estaria à venda para quem mandasse o evento na mão), cobra dentro de
um único `:Update` de `Stats` — que não cede o controle, então dois cliques não gastam
o mesmo saldo — e confere a posse **de novo** dentro da escrita de `RoundCards`, para
que dois cliques no mesmo quadro não paguem duas vezes pela mesma carta. O que falhar
depois da cobrança é devolvido.

## O cadeado das dificuldades

Fácil e Médio são de todo mundo. As três de cima abrem por **uma** de duas coisas — o
que vier primeiro:

| Dificuldade | Vitórias | ou Nível |
| --- | --- | --- |
| Hard | 4 no Medium | 3 |
| Impossible | 4 no Hard | 6 |
| Nightmare | 6 no Impossible | 12 |

As duas fontes medem coisas diferentes, e é por isso que são duas. As vitórias na
dificuldade de baixo dizem que o jogador **dá conta** dela, e é o caminho curto de quem
está jogando bem. O nível é a rede: XP cai em derrota e em run abandonada, então quem
perde muito mas joga muito também chega — só vitória prenderia o jogador ruim no Medium
para sempre.

Repare que `Wins` conta a dificuldade **de baixo**, e não a que está sendo destravada:
não há como ganhar no Nightmare antes de ele abrir. Isso faz o lado das vitórias ser
sequencial (para as 6 do Impossible foi preciso antes destravar o Impossible), enquanto
o lado do nível pode pular degraus.

A tabela mora em `SharedConfig.DifficultyUnlockConfig`, e não junto dos presets em
`Config.Difficulty` (que é só do servidor): nada nela é sigiloso, e o cliente precisa
dela para desenhar o cadeado antes de perguntar qualquer coisa. Mesmo arranjo do
`MapConfig`.

**Onde ficam as vitórias.** `Stats.Wins` continua sendo o total — é o que o leaderstats
e o cadeado dos mapas leem. O cadeado daqui lê `Stats.DifficultyWins`
(`{ [dificuldade] = quantas }`), escrito pelo `WaveService` no mesmo `:Update` da
vitória. Um total não serviria: 20 vitórias no Easy não dizem nada sobre o Hard. A
tabela nasce vazia e ganha a chave da dificuldade na primeira vitória nela — a lista de
presets é do config do servidor, e copiá-la para dentro do perfil seria a mesma lista em
dois lugares. Perfil antigo recebe a tabela pelo reconcile, e a recebe **vazia**: as
vitórias de antes desta chave não têm dificuldade registrada. O nível não é guardado em
lugar nenhum — sai do `Stats.XP` pelo `LevelConfig:Resolve`.

**A conta vale nas duas pontas.** O `DifficultyController` esconde o `Locked` de cada
botão, devolve o `Active`/`AutoButtonColor` que a arte autorou e escreve o que falta no
rótulo (`Locked.Time`: "4 more wins in Medium or Level 3"); o `DifficultyService`
recusa o voto com a mesma função. As duas são necessárias: o voto é um nome, e um nome é
o que qualquer cliente pode mandar — bastaria um voto forjado para arrastar a sala
inteira para o Nightmare.

Enquanto a réplica não chega, tudo aparece trancado. É o mesmo chute seguro dos mapas:
errar para o outro lado abriria o Nightmare por um instante e o fecharia na cara do
jogador quando o perfil chegasse.

Botão sem frame `Locked` na arte é um botão sempre aberto — é assim que Easy e Medium se
declaram, sem precisar de entrada em config nenhum.

## Configuração: o que é replicado e o que não é

Antes, `ReplicatedStorage.Shared.Config.Server` era replicado para todo cliente —
incluindo chave de DataStore, template de perfil, tabelas de wave, odds de summon
e a lista de admins do Cmdr. Isso foi separado:

| | Onde | Conteúdo |
|---|---|---|
| **Servidor** | `ServerScriptService.Config` ← `common/server/Config` | `Data` (PROFILE_KEY + template), `Wave`, `Summon`, `Difficulty`, `Cmdr` (ADMIN_USER_IDS, GROUP_ID, ALLOW_IN_STUDIO) |
| **Compartilhado** | `ReplicatedStorage.Shared.Config` ← `common/shared/Config` | `Client`, `SharedConfig` (UnitStats, UnitAttackConfig, UnitUpgradeConfig, UnitVFXConfig, CrateConfig, MapConfig, PortalConfig, FootstepConfig, LightingConfig, RarityConfig, LevelConfig, DifficultyUnlockConfig, DeckConfig, RoundCardConfig, RoundCardShopConfig, CardModifier, `Mob`, `Cmdr` cosmético, `GamepassConfig`) |

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

## Gamepasses

Cinco passes, e nenhuma delas é código espalhado: o catálogo inteiro é
`SharedConfig.GamepassConfig`, e cada benefício é um número num campo.

| Pass | Id | O que faz | Onde entra |
| --- | ---: | --- | --- |
| `CardSlots` | 1966789042 | +5 cartas no deck | `DeckConfig.limitFor` |
| `Luck` | 1969136561 | +30% no peso de Epic+ no unboxing | `CrateService:_rollRarity` |
| `Coins` | 1969568499 | 2x coins de fim de partida | `WaveService:rewardsFor` |
| `Shards` | 1970648287 | 1,5x shards de fim de partida | `WaveService:rewardsFor` |
| `VIP` | 1953119816 | 20% off nas caixas, 1,25x XP, tag no chat | `ShopConfig.priceFor`, `WaveService:rewardsFor`, `PlayerChatController` |

### A pass é estado, e não crédito

É a regra que decide todo o resto. Uma compra de developer product é um **evento**
que precisa ser creditado uma vez só — é o que o `ProcessReceipt` e o
`PurchaseHistory` fazem. Uma gamepass é um **estado**: o jogador tem ou não tem, hoje.

Por isso **nada de gamepass é gravado como valor no perfil**. Os +5 cartas não vão
para o `CardLimit`; eles somam na leitura (`DeckConfig.limitFor`). Escrever no perfil
seria crédito, e crédito não volta: quem pedisse reembolso ficaria com o teto alto
para sempre, e um segundo login somaria outros cinco.

O que fica gravado é uma **cópia** do que a Roblox respondeu, em `Data.Gamepasses`:

```lua
Gamepasses = { VIP = true, Coins = true }
```

A chave é a do `GamepassConfig`, e **não** o id numérico — o id é da Roblox e muda
quando uma pass é recriada; a chave é do jogo. Um id trocado é uma linha no config,
e não uma migração de perfil.

O `MonetizationService:RecalibratePasses` reescreve a tabela **inteira** a cada
entrada, então uma pass reembolsada some sozinha no próximo login. A cópia existe só
para o resto do jogo não perguntar à Roblox a cada caixa aberta e a cada fim de round.

**Falha de API não apaga pass.** O `_ownsPass` devolve `nil` — e não `false` — quando
a chamada estoura, e `nil` mantém o que o perfil já dizia. `false` é "ele não tem";
uma queda da API não pode tirar do jogador o que ele comprou.

**A pass vale na hora.** O `PromptGamePassPurchaseFinished` recalibra na compra: sem
ele o jogador compraria o 2x Coins e só veria efeito no próximo login, o que parece a
compra não ter funcionado.

### Os números se multiplicam, e ninguém escreve `if`

Cada benefício é um campo no catálogo, e as funções do `GamepassConfig` varrem as
passes que o perfil tem: multiplicadores se multiplicam entre si, bônus se somam.
Campo ausente é neutro. Hoje há uma pass por benefício, então toda conta é uma
multiplicação só — mas uma segunda pass de coins amanhã entra **sem tocar em quem
lê**, o que não aconteceria com um `if` por pass espalhado pelos services.

### A sorte levanta as de cima e não mexe nas de baixo

A `Luck` multiplica o peso de Epic, Legendary e Cosmic no pool da caixa (o piso é
`GamepassConfig.LUCK_MIN_RARITY`) e deixa Common e Rare como estão. Como o sorteio
normaliza pela soma dos pesos, subir as de cima já empurra as de baixo para baixo —
mexer nos dois lados seria dois números para manter em sincronia. Medido em 300 mil
aberturas por linha:

| Caixa | Epic+ sem pass | Epic+ com a pass |
| --- | ---: | ---: |
| Crate Of Beginnings | 4,94% | 6,36% |
| Crate Of Nature | 15,11% | 18,62% |
| Fragmented Crate | 55,00% | 61,41% |
| Legendary Crate | 80,02% | 83,85% |

O ganho **relativo** encolhe conforme a caixa já é boa (+29% na comum, +5% na
lendária), e isso é aritmética de peso normalizado, não um teto escrito em lugar
nenhum: quando Epic+ já é 80% do bolo, não há muito para onde subir.

As odds publicadas na loja **não mudam**: `Crate.GetDisplayOdds` continua sendo o pool
cru, que é o que o jogador *sem* pass recebe. Uma pass que melhora o que ela promete
não torna o número da loja mentira.

### O preço na tela é o preço cobrado

`ShopConfig.priceFor(item, profile)` é chamado dos dois lados — o `ShopService` para
cobrar e o `ShopController` para escrever no botão. É a mesma conta, e não duas que
alguém precisa lembrar de manter iguais.

Ele arredonda **ao mais próximo**, com piso de 1. Não para cima: a Fragmented Crate
custa 4 shards, e 20% dela é 0,8 — arredondando para cima o VIP pagaria os mesmos 4 e
veria a pass não funcionar justamente na caixa do meio da loja.

| Caixa | Normal | VIP |
| --- | ---: | ---: |
| Crate Of Beginnings | 50 coins | 40 |
| Crate Of Nature | 200 coins | 160 |
| Fragmented Crate | 4 shards | 3 |
| Legendary Crate | 1800 shards | 1440 |

### A recompensa é uma base da partida vezes um multiplicador de cada um

`computeReward` continua sendo **uma** conta para a sala inteira: ela sai das waves
sobrevividas e da dificuldade, que são da partida e não de ninguém. O que é de cada
um é o multiplicador, e ele entra depois, no `rewardsFor` — duas pessoas na mesma run
terminam com números diferentes sem que a run tenha duas contas.

O `RoundReward` que vai para a tela leva o número **já multiplicado**: o jogador lê o
que de fato entrou na carteira dele.

### A tag do chat é atributo, e não perfil

A réplica do perfil só chega ao dono dela, então ela não serve para o chat: o `[VIP]`
tem de aparecer na mensagem **dos outros**, na tela de todo mundo. O
`MonetizationService` publica um atributo `Pass_<chave>` no `Player` para cada pass
com `ChatTag`, e atributo de `Player` replica para a sala inteira — continua sendo o
servidor quem escreve.

O `TextChatService.OnIncomingMessage` do `PlayerChatController` é quem põe a tinta.
Ele é client-side por natureza (só decora o que já chegou) e não decide nada: a
pergunta à Roblox foi feita no servidor, uma vez.

**Ainda não há loja de gamepass.** Nada aqui abre um prompt de compra — as passes
funcionam para quem já as tem, e o `PromptGamePassPurchaseFinished` cobre a compra
feita por fora (página da experiência). A vitrine é trabalho à parte.

## Leaderboards globais (`Workspace.Leaderboards`, Lobby)

Oito boards no mapa do lobby, cada uma um modelo com `Main > SurfaceGui >
ScrollingFrame > Frame`. O `Frame` é o **molde**: o servidor o tira da tela e
clona uma linha por posição (`Position` = `1º`, `Username`, `Value`), até o top 50.
Quem faz tudo é o `LeaderboardService` (`common/server/Services`); a lista de
boards fica em `Config.Leaderboard` (servidor).

| Modelo | Número do perfil | Formato |
| --- | --- | --- |
| `HighestLevelLB` | `Stats.XP` (mostra o nível) | `25` |
| `MostCoinsLB` | `Stats.CoinsEarned` (total ganho, não o saldo) | `1.25M` |
| `MostMatchesWonLB` | `Stats.Wins` | `1.25M` |
| `NightmareWinsLB` | `Stats.DifficultyWins.Nightmare` | `1.25M` |
| `MostBoxesOpened` | `Stats.BoxesOpened` | `1.25M` |
| `MostMatchesPlayedLB` | `Stats.MatchesPlayed` | `1.25M` |
| `MostTimeInMatchesLB` | `Stats.TimeInMatches` (segundos) | `DD:HH:MM` |
| `MostTimePlayedLB` | `Stats.TimePlayed` (segundos) | `DD:HH:MM` |

A HIGHEST LEVEL guarda o **XP**, e não o nível: a ordem é a mesma, e o XP desempata
quem já está no nível máximo.

### Um OrderedDataStore por board

O perfil continua sendo a fonte; a store é uma cópia ordenada dele, com o UserId
como chave. Pedir o topo é **uma página** do `GetSortedAsync(false, 50, 1)` — o
mesmo custo com mil ou com um bilhão de jogadores na store, porque ela já guarda as
chaves em ordem. Nada percorre a store inteira. O `1` do fim tira quem está em zero
(coins gastos até o fim, por exemplo).

O nome de cada store é `<PROFILE_KEY>_LB_<Store>`: trocar a `PROFILE_KEY` zera os
perfis **e** as boards juntos, em vez de deixar o topo mostrando números de perfis
que ninguém mais lê.

### Quem grava, e quando

As duas places gravam (a Game muda XP, coins, vitórias e partidas; a Lobby muda
coins, caixas e tempo), então o service é `common`. Cada servidor manda os números
dos próprios jogadores:

- quando o perfil carrega (tudo que não for zero);
- a cada `WRITE_INTERVAL` (120s), **só o que mudou** desde a última escrita;
- na saída e no desligamento, pelo `DataService:OnBeforeRelease`.

Tudo passa por uma fila com uma entrada por store+jogador: um número que muda de
novo antes de a escrita sair substitui a entrada, e não duplica. A fila respeita o
budget de escrita da Roblox (60 + 10 por jogador por minuto) e, se a store falhar,
espera o próximo ciclo. O `BindToClose` segura o servidor até ela esvaziar (25s no
máximo).

Jogador de UserId negativo (cliente de teste do Studio) não grava: a store é a do
jogo, e ele sujaria o topo de verdade.

### Quem lê

Só onde existe `Workspace.Leaderboards` — hoje, a Lobby. A cada `READ_INTERVAL`
(120s) ela lê as oito boards, resolve os nomes num lote só
(`UserService:GetUserInfosByUserIdsAsync`, com cache) e reescreve o texto das
linhas. As linhas são reaproveitadas entre leituras, e as que sobram ficam
escondidas. A SurfaceGui está no Workspace, então o que o servidor escreve replica
para todo mundo.

### Os quatro contadores novos

Nascem em **zero para todo mundo**, inclusive para quem já jogava: o perfil nunca
guardou nada disso. Perfil antigo ganha as chaves pelo reconcile.

| Chave | Quem escreve | Regra |
| --- | --- | --- |
| `BoxesOpened` | `CrateService:OpenCrate` (Lobby) | caixa gasta e rolada; o `unbox` do Cmdr não conta |
| `TimePlayed` | `PlaytimeService` (common) | do perfil carregado até a saída, nas duas places; escreve de minuto em minuto |
| `TimeInMatches` | `MatchStatsService` (Game) | tempo real com o `WaveService` em `Running`, da espera pelos jogadores à última wave |
| `MatchesPlayed` | `MatchStatsService` (Game) | +1 quando o tempo do jogador naquele round passa de `Data.MIN_MATCH_SECONDS` (180s) — vitória, derrota ou saída no meio |

O `MatchStatsService` abre um relógio por jogador no `WaveService.Signals.RoundStarted`
(ou quando ele entra num round rodando) e fecha no `RoundClosed` — fim da partida ou
reset no meio — ou na saída. Fechar tira o relógio, então uma partida conta uma vez
por jogador.

### A ordem dos ganchos de saída

`OnBeforeRelease(callback, order)` agora existe nos dois `DataService`, e o `order`
(0 por padrão) decide quem roda primeiro. O `LeaderboardService` registra com `1`
para tirar o retrato final **depois** de quem ainda escreve no perfil na saída — a
recompensa de quem sai no meio (`WaveService`), o último minuto do
`PlaytimeService`, o relógio do `MatchStatsService`. Sem o número, a ordem seria a
de quem subiu primeiro no `Me`, que não é garantida.

### MOST COINS é o total ganho

`Stats.CoinsEarned` só sobe: gastar na loja não derruba ninguém da board. Quem
soma é quem **dá** coins: o `WaveService:grantReward` (recompensa de partida) e o
`ContractService` (resgate de contrato), junto com o `Cash`. Estorno de compra
(`ShopService`, `RoundCardShopService`) e o `cash` do Cmdr mexem só no saldo.

A chave **não está no template**, e é de propósito. Quem jogava antes dela já
ganhou pelo menos o saldo que tem, então o `CurrencyService` (common), ao ver a
chave faltando no perfil que carregou, a cria com o `Cash` atual — perfil novo tem
saldo zero e começa do zero. Com a chave no template, o reconcile a criaria em
zero antes, e não daria mais para saber quem era perfil antigo.

## Painel por proximidade (`Shared.Util.ProximityPanel`, Lobby)

A loja de caixas, a loja de cartas e o quadro de contratos são o mesmo painel:
abre quando o jogador chega num ponto do mapa, fecha quando ele sai, entra pela
`OpenShop` do Cascade, borra o fundo e esconde o resto da UI pelo
`InterfaceController`. Esse bloco era copiado em cada controller; hoje é o
`ProximityPanel`, e o controller entra só com o conteúdo:

```lua
self.Proximity = ProximityPanel.new({
	Name = "ContractController",
	ScreenGui = "Contracts", Wrapper = "Frame", Panel = "MainBoard",
	Animation = "OpenShop",
	HideReason = "Contracts",
	GetReference = function() return target.Position end,
	Radius = 6,
	InterfaceController = self.Controllers.InterfaceController,
	OnBind = function(screenGui, wrapper, panel, maid) ... end, -- cada cópia nova da ScreenGui
	BeforeOpen = function() ... end,                            -- logo antes de entrar
	CanDisable = function() return true end,                    -- ScreenGui dividida (a ShopUI)
})
self.Proximity:Start()
```

- **Só a travessia age.** Fechar no X parado ali não reabre no tick seguinte; o
  painel volta quando o jogador sai e entra de novo. `EnterRange()` é para o
  teleporte da HUD: marca a entrada e abre, senão a saída nunca aconteceria.
- **A moldura (`Wrapper`) é quem vai e vem**, e não a ScreenGui. A `ShopUI` carrega
  as duas lojas; o `CanDisable` de cada uma devolve false com a vizinha aberta, e o
  fechamento apaga só a moldura.
- **Cópia nova nasce apagada e devolve a tela** — morrer com o painel aberto não
  deixa o jogador sem HUD.
- O Cascade é procurado na primeira vez que um painel liga, e não no topo do
  módulo: a Game também monta o `Shared.Util` e não tem o runtime.

## Contratos (`StarterGui.Contracts`, Lobby)

O quadro abre na `Workspace.ContractsBoard.TargetPart` (`ContractConfig.Board`).
Tem três seções, cada uma com a contagem até a virada:

| Período | Contratos | Vira em (UTC) |
| --- | --- | --- |
| Hourly | 2 | toda hora cheia |
| Daily | 3 | meia-noite |
| Weekly | 4 | segunda 00:00 |

A lista, o que cada contrato conta e quanto paga ficam em
`SharedConfig.ContractConfig`, um contrato por linha. A descrição sai com o
progresso no fim: `Win 4 games in Volcano on Hard (1/4)`.

### Quem faz o quê

| Peça | Place | O quê |
| --- | --- | --- |
| `ContractService` | common | sorteia na virada, anota o progresso, escreve em lote, resgata e paga |
| `ContractTrackerService` | Game | transforma a partida em eventos (`Record`) |
| `CrateService` | Lobby | o evento `Unbox`, com a raridade da unidade que saiu |
| `ContractController` | Lobby | desenha o quadro a partir da replica e manda o CLAIM |

O perfil guarda `Data.Contracts = { Hourly|Daily|Weekly = { Period, Slots } }`.
Cada slot tem `{ Id, Params, Progress, Claimed }`, e `Seen` para o login.

### Sorteio

- **Por jogador, na virada.** A cada 2s (e quando o perfil carrega), cada período
  é comparado com o de agora; o que virou é sorteado de novo. Contrato não resgatado
  se perde junto.
- **Variação.** Os contratos do período anterior vão para o fim da urna: só
  voltam quando não sobram novos suficientes. Com as listas de hoje, isso nunca
  acontece para quem já abriu tudo.
- **Cadeados.** Contrato preso a mapa ou dificuldade que o jogador ainda não abriu
  não sai (o Volcano de quem tem duas vitórias, o Nightmare de quem é nível 1), e o
  `Random` sorteia só entre os abertos. O `D_Stun676` só sai para quem tem unidade
  que atordoa (`NeedsUnitStat = "Stun"`), e o `{Class}` só entre as classes que o
  jogador tem.

### O que conta

Tudo é **do próprio jogador**: kill, dano e atordoamento são de quem era a
unidade, e o caixa é o dele. Só o clima e a wave são da sala.

| Evento | Fonte |
| --- | --- |
| `Win` | `WaveService.Signals.MatchFinished`, com mapa, dificuldade, base cheia, amigo na sala e as classes que **todas** as unidades colocadas tinham em comum |
| `Kill`, `BossKill`, `Stun`, `Damage` | `MobService.SessionStats` (e o `SessionDamage`), lidos a cada 3s |
| `MatchCashSpent`, `MatchCashEarned` | idem, com `Mode = "Max"`: a melhor partida, e não a soma |
| `WaveReached` | `WaveService.Signals.WaveStarted` (`Max`) |
| `Weather` | `WeatherRoundService.Signals.WeatherStarted` — só o clima que entra, e não o aviso |
| `MatchTime` | `MatchStatsService.Signals.Closed` (segundos) |
| `Unbox` | `CrateService:OpenCrate` — o `unbox` do Cmdr e o summon não contam |
| `Login` | o dia UTC em que o jogador está online, marcado a cada tick (`Distinct`) |

- **"With only {Class} units"**: vale se todas as unidades colocadas na partida
  tinham aquela classe, inclusive as vendidas. Unidade sem classe quebra a condição.
- **"With 1 or more friends"**: amigo na Roblox na mesma partida. A pergunta é feita
  quando o jogador entra no servidor, e fica guardada até a vitória.

### Escrita em lote e resgate

`Record` só anota numa fila por jogador. O `Flush` escreve tudo num `Update` de
`Contracts` a cada 2s, no fim da partida e na saída. Cada entrada lembra o período
e o `Id` do slot, então progresso de um contrato que venceu não cai no que tomou o
lugar dele.

O CLAIM manda só `(período, slot)`. O servidor escreve a fila, confere se o slot
está completo e não foi pago, marca e paga, sem nada que ceda no meio. Dois
cliques não pagam duas vezes. A recompensa soma `Cash` (e `CoinsEarned`),
`Shards` e caixas (pelo `CrateService:GiveCrates`).

Na UI, coin e shard usam as linhas autoradas do `RewardsContainer`, e cada caixa
vira um texto `8x Fragmented Crate` na `OtherReward`, clonada quando há mais de uma.

## Evento novo do servidor para o cliente precisa ser declarado

O identificador de um evento do Warp nasce no **servidor**. Quando o cliente faz
`Framework:Listen("X")` e o servidor ainda não conhece `X`, o `Serdes.increment`
do cliente **cede a thread por 10 segundos** esperando o atributo aparecer, avisa
`Serdes: X is taking too long to retrieve` e devolve `nil`. Como `construct()` é
uma função só, todo `Listen` **depois** daquela linha fica esperando junto — o
sintoma não é o evento novo não funcionar, é o resto do controller sumir.

Por isso todo evento que só o servidor dispara tem um `Listen` vazio no service
dono dele, no começo do `construct` (ver `UnitService`, `MobService`,
`WeatherService`):

```lua
Framework:Listen("UnitPriorityChanged", function() end)   -- só para existir
```

Evento que o **cliente** dispara não precisa: quem escuta é o servidor, e é ele
que cria o identificador ao registrar o `Listen` de verdade.

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
