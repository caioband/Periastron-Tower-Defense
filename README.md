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
com o atributo `LightingKeep = true` sobrevive ao clear.

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

#### Moedas pelo console

São **três** moedas e duas delas são a mesma conta em lugares diferentes:

| Comando | Mexe em | Onde vive |
|---|---|---|
| `cash` (`money`, `coins`) | `Stats.Cash` do perfil | salvo; é o do lobby, dos summons |
| `shards` (`shard`) | `Stats.Shards` do perfil | salvo; a moeda premium da loja |
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
dizendo como ele encaixa no mapa:

```
Assets.Weathers
├── Snow      (Model, tag "AreaWeather")
│   ├── Part      (os ParticleEmitters)
│   └── Lighting  (Folder — preset, mesmo formato de Assets.Lighting)
└── Thunder   (Model, tag "SkyWeather")
```

`WeatherService` (`common/server/Services`) clona o Model para `workspace.Weather`,
encaixa a `Part` na caixa do mapa carregado e entrega a pasta `Lighting` ao
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
| `Farm` | Fog, Wind, Thunder |
| `Desert` | Sandstorm, Drought |
| `Volcano` | Drought, Fog |
| `Cave` | Fog |
| `SnowyCastle` | Snow, Wind, Fog |
| `Mountain` | Snow, Wind, Fog, Thunder, Drought |
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

Duas regras de precedência valem a pena guardar. **`Units.<Classe>` substitui
`Units.All`** naquela estatística — por isso o Fog escreve 0.55 para Magic em vez de
esperar que 0.7 e 0.55 se multipliquem. E **`Immune` tira a unidade do clima
inteiro**: nem debuff, nem buff da própria classe, nem congelamento, nem raio.

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

Unidade imune ao clima (Magic, nos climas de hoje) não recebe nada — nem billboard,
nem Highlight —, que é o mesmo "fora do clima" que o `Immune` já significa no combate.
Havendo buff e debuff na mesma unidade, o Highlight é **vermelho**: nenhum clima de
hoje faz as duas coisas, mas quando fizer, a perda é o que precisa ser visto de longe.

As duas peças moram **dentro do modelo da unidade**, então vender ou recomeçar o round
limpa junto; o controller as procura pelo nome em vez de guardar numa tabela, e não
existe bookkeeping para desencontrar do que está no Workspace. O Highlight tem nome
próprio (`WeatherHighlight`) para não brigar com os outros que a unidade recebe: o
verde da seleção, o amarelo do atordoamento e o ciano da carga do raio.

Ícone que ainda não exista no asset simplesmente não aparece — a unidade continua com
o Highlight e com os outros ícones, e o Studio avisa uma vez no output.

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

### Quem some da tela, e quando

Três situações pedem a tela para si: o painel de mapas, que quer o lobby só para
ele; a contagem regressiva do portal, que deixa em pé só o botão de sair; e a
cutscene, que quer a tela limpa. Não são um interruptor global — os dois se
sobrepõem (o painel pode estar aberto quando a cena começa) e cada um sai na sua
hora — então quem cuida disso é o `InterfaceController`
(`common/client/Controllers`), com **pedidos com nome**:

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

## Configuração: o que é replicado e o que não é

Antes, `ReplicatedStorage.Shared.Config.Server` era replicado para todo cliente —
incluindo chave de DataStore, template de perfil, tabelas de wave, odds de summon
e a lista de admins do Cmdr. Isso foi separado:

| | Onde | Conteúdo |
|---|---|---|
| **Servidor** | `ServerScriptService.Config` ← `common/server/Config` | `Data` (PROFILE_KEY + template), `Wave`, `Summon`, `Difficulty`, `Cmdr` (ADMIN_USER_IDS, GROUP_ID, ALLOW_IN_STUDIO) |
| **Compartilhado** | `ReplicatedStorage.Shared.Config` ← `common/shared/Config` | `Client`, `SharedConfig` (UnitStats, UnitAttackConfig, UnitUpgradeConfig, UnitVFXConfig, CrateConfig, MapConfig, PortalConfig, FootstepConfig, LightingConfig, RarityConfig, LevelConfig, DeckConfig, `Mob`, `Cmdr` cosmético) |

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
