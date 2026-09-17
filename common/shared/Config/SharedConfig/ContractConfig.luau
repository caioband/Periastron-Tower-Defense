--[[
	Os contratos (missoes) do quadro do lobby: quais existem, quanto pagam, quando
	viram e como a descricao aparece.

	**Tres periodos, com a virada em hora fixa (UTC).** O de hora vira na hora cheia,
	o diario a meia-noite UTC e o semanal na segunda 00:00 UTC. A virada e a mesma
	para todo mundo; o **sorteio** e de cada jogador (`ContractService`), e so
	acontece quando o perfil dele ve um periodo novo -- ao entrar, ou numa virada com
	ele online.

	  | Periodo | Contratos por vez |
	  | Hourly  | 2                 |
	  | Daily   | 3                 |
	  | Weekly  | 4                 |

	Contrato nao resgatado ate a virada se perde junto com o periodo.

	**Variacao.** O sorteio tira da urna os contratos do periodo anterior sempre que
	sobra o bastante sem eles; so completa com repetidos quando a conta nao fecha.

	**Cada contrato e uma linha de dados.** O que ele conta e o `Event`, e o resto
	sao filtros sobre o contexto do evento (mapa, dificuldade...). Nada aqui roda
	regra de jogo: quem casa evento com contrato e o `ContractService`, e quem
	dispara os eventos sao os services da partida (`ContractTrackerService`, na Game)
	e o `CrateService` (Lobby).

	  | Campo | O que e |
	  | --- | --- |
	  | `Id` | a chave no perfil. **Nao troque** o de um contrato que ja existe. |
	  | `Text` | a descricao. `{Map}`, `{Difficulty}` e `{Class}` viram o sorteado. |
	  | `Event` | o que conta (ver `Events`) |
	  | `Goal` | ate onde conta |
	  | `Mode` | `Sum` (padrao) soma; `Max` guarda o maior valor; `Distinct` conta valores diferentes |
	  | `Map` / `Difficulty` / `Class` | o evento tem de ser neste; `Random` sorteia um por jogador |
	  | `MinDifficulty` | a dificuldade do evento tem de ser esta ou maior |
	  | `FullHealth` / `WithFriends` | a vitoria tem de ter sido com a base cheia / com amigo na sala |
	  | `Rarity` | a raridade da unidade que saiu da caixa |
	  | `NeedsUnitStat` | so sai para quem tem uma unidade com esse campo no `UnitStats`; aceita uma lista, e basta um deles |
	  | `Format` | `Hours` mostra o progresso em horas (o `Goal` e em segundos) |
	  | `Rewards` | `Cash`, `Shards` e `Crates` (`{ [tier da caixa] = quantas }`, ver `CrateConfig.CRATES`) |
	  | `RewardDifficulty` | com `Difficulty = Random`: a dificuldade para a qual o `Rewards` foi escrito. A recompensa escala para a sorteada na proporcao do premio de uma run (`WinCash` para coins, `WinShards` para shards e caixas, em `ServerScriptService.Config.Difficulty`) |

	**Recompensa que escala e calculada no sorteio** e guardada no slot (`Slot.Rewards`),
	porque o `Config.Difficulty` nao e replicado. A tela e o resgate leem a do slot
	antes da do config.

	**Contrato preso a mapa ou dificuldade trancados nao sai.** O Nightmare de quem
	ainda nao abriu, o Volcano de quem tem duas vitorias: o sorteio pula (ver
	`ContractService`), e o `Random` sorteia so entre os que o jogador ja abriu.
]]

local MapConfig = require(script.Parent.MapConfig)

local ContractConfig = {}

ContractConfig.RANDOM = "Random"

-- A ordem em que as secoes aparecem e em que o servidor as confere.
ContractConfig.KIND_ORDER = { "Hourly", "Daily", "Weekly" }

local HOUR = 3600
local DAY = 24 * HOUR
local WEEK = 7 * DAY

--[[
	`Offset` e onde o primeiro periodo comeca, contado da epoca Unix. O dia 1 de
	janeiro de 1970 foi uma quinta, entao a primeira segunda-feira e quatro dias
	depois -- e a semana dos contratos vira na segunda.
]]
ContractConfig.KINDS = {
	Hourly = { Count = 2, Length = HOUR, Offset = 0 },
	Daily = { Count = 3, Length = DAY, Offset = 0 },
	Weekly = { Count = 4, Length = WEEK, Offset = 4 * DAY },
}

--[[
	O quadro no mapa do lobby: `Workspace.<Model>.<Target>` e o centro do raio que
	abre a `StarterGui.Contracts`, do mesmo jeito que o balcao abre as lojas (ver
	`ProximityPanel`). Um stud a mais que o das lojas: a `TargetPart` fica no chao, e
	a medida e ate o `HumanoidRootPart`, uns tres studs acima dela.
]]
ContractConfig.Board = {
	Model = "ContractsBoard",
	Target = "TargetPart",
	OpenRadius = 6,
	ProximityInterval = 0.2,
	Animation = "OpenShop",
}

--[[
	O reroll de cada aba: um developer product por vez que o jogador rerola, em ordem.
	O primeiro reroll do periodo abre o 1, o segundo o 2, e do 7 em diante fica no
	ultimo da lista.

	A contagem mora no perfil (`Contracts[kind].Rerolls`) e zera sozinha na virada,
	porque o periodo novo nasce sem ela. O reroll sorteia a aba **inteira** de novo --
	inclusive o que ja foi resgatado --, com progresso zerado e evitando os contratos
	que estavam la (ver `ContractService:Reroll`).

	Quem credita e o recibo, no servidor: qualquer um destes produtos rerola a aba
	dele, seja qual for a contagem. O numero so decide qual produto o botao abre.
]]
ContractConfig.Reroll = {
	Button = "RerollDice",

	Products = {
		Hourly = { 3713210488, 3713210581, 3713210596, 3713210618, 3713210662, 3713210676, 3713210698 },
		Daily = { 3713210718, 3713210736, 3713210747, 3713210794, 3713210802, 3713210822, 3713210833 },
		Weekly = { 3713210846, 3713210863, 3713210871, 3713210887, 3713210898, 3713210909, 3713210923 },
	},
}

ContractConfig.Events = {
	Win = "Win",
	WaveReached = "WaveReached",
	Kill = "Kill",
	BossKill = "BossKill",
	Damage = "Damage",
	Stun = "Stun",
	Weather = "Weather",
	MatchCashSpent = "MatchCashSpent",
	MatchCashEarned = "MatchCashEarned",
	MatchTime = "MatchTime",
	Unbox = "Unbox",
	Login = "Login",
}

local E = ContractConfig.Events
local RANDOM = ContractConfig.RANDOM

ContractConfig.Contracts = {
	Hourly = {
		{ Id = "H_Win3", Text = "Win 3 games in any map", Event = E.Win, Goal = 3,
			Rewards = { Cash = 250, Shards = 3 } },

		--[[
			Os Ids que citam um mapa ou dificuldade (`H_Win2Castle`, `D_Win3Nightmare`...)
			sao de quando o campo era fixo. Ficaram assim de proposito: o Id e a chave no
			perfil, e troca-lo zeraria o progresso de quem ja tem o contrato.
		]]
		{ Id = "H_Win2Castle", Text = "Win 2 games in {Map}", Event = E.Win, Goal = 2, Map = RANDOM,
			Rewards = { Cash = 200, Shards = 3 } },

		{ Id = "H_Wave15Desert", Text = "Reach Wave 15 on {Map}", Event = E.WaveReached, Goal = 15, Mode = "Max", Map = RANDOM,
			Rewards = { Cash = 150, Shards = 2 } },

		{ Id = "H_Win2Medium", Text = "Win {Difficulty} difficulty twice on any map", Event = E.Win, Goal = 2, Difficulty = RANDOM, RewardDifficulty = "Medium",
			Rewards = { Cash = 250, Shards = 3 } },

		-- "Durante uma partida": o `Max` guarda a melhor partida, e nao a soma delas.
		{ Id = "H_Spend5000", Text = "Spend 5,000 coins during a match", Event = E.MatchCashSpent, Goal = 5000, Mode = "Max",
			Rewards = { Cash = 200, Shards = 3 } },

		{ Id = "H_BeatFarmMedium", Text = "Beat {Map} in Medium difficulty or higher", Event = E.Win, Goal = 1, Map = RANDOM, MinDifficulty = "Medium",
			Rewards = { Cash = 200, Shards = 3 } },

		{ Id = "H_Kill100", Text = "Kill 100 enemies", Event = E.Kill, Goal = 100,
			Rewards = { Cash = 150, Shards = 2 } },

		{ Id = "H_WinFullHealth", Text = "Win with 100% base health", Event = E.Win, Goal = 1, FullHealth = true,
			Rewards = { Cash = 150, Shards = 2 } },

		{ Id = "H_Kill200Volcano", Text = "Kill 200 enemies on {Map}", Event = E.Kill, Goal = 200, Map = RANDOM,
			Rewards = { Cash = 250, Shards = 3 } },

		{ Id = "H_Damage30k", Text = "Deal 30,000 damage", Event = E.Damage, Goal = 30000,
			Rewards = { Cash = 250, Shards = 3 } },

		{ Id = "H_WinFriendsMap", Text = "Win a match in {Map} with 1 or more friends", Event = E.Win, Goal = 1, Map = RANDOM, WithFriends = true,
			Rewards = { Cash = 100, Shards = 3 } },
	},

	Daily = {
		{ Id = "D_Win6", Text = "Win 6 games in any map", Event = E.Win, Goal = 6,
			Rewards = { Cash = 500, Shards = 7 } },

		{ Id = "D_Win6VolcanoMedium", Text = "Win 6 games in {Map} on {Difficulty} difficulty", Event = E.Win, Goal = 6, Map = RANDOM, Difficulty = RANDOM, RewardDifficulty = "Medium",
			Rewards = { Cash = 700, Shards = 9 } },

		-- So quem tem uma unidade que atordoa recebe este: o tranco do Electro (`Stun`) ou
		-- o congelamento do Frostione (`Frost`).
		{ Id = "D_Stun676", Text = "Stun enemies 676 times", Event = E.Stun, Goal = 676, NeedsUnitStat = { "Stun", "Frost" },
			Rewards = { Cash = 800, Shards = 9 } },

		{ Id = "D_Win3Nightmare", Text = "Win 3 games in {Difficulty} mode", Event = E.Win, Goal = 3, Difficulty = RANDOM, RewardDifficulty = "Nightmare",
			Rewards = { Cash = 900, Shards = 8 } },

		-- O caixa da partida, numa partida so (o `Max`), e nao os coins do perfil.
		{ Id = "D_Earn20k", Text = "Earn 20,000 Cash in a single match", Event = E.MatchCashEarned, Goal = 20000, Mode = "Max",
			Rewards = { Cash = 500, Shards = 7 } },

		{ Id = "D_Win6Hard", Text = "Win 6 games in {Difficulty} mode", Event = E.Win, Goal = 6, Difficulty = RANDOM, RewardDifficulty = "Hard",
			Rewards = { Cash = 700, Shards = 8 } },

		{ Id = "D_Kill600", Text = "Kill 600 enemies", Event = E.Kill, Goal = 600,
			Rewards = { Cash = 500, Shards = 7 } },

		{ Id = "D_Win4MapDifficulty", Text = "Win 4 games in {Map} on {Difficulty}", Event = E.Win, Goal = 4, Map = RANDOM, Difficulty = RANDOM, RewardDifficulty = "Medium",
			Rewards = { Cash = 500, Shards = 7 } },

		{ Id = "D_Win5DifficultyFriends", Text = "Win 5 games on {Difficulty} with 1 or more friends", Event = E.Win, Goal = 5, Difficulty = RANDOM, RewardDifficulty = "Medium", WithFriends = true,
			Rewards = { Cash = 400, Shards = 6 } },
	},

	Weekly = {
		{ Id = "W_Win7MapClassNightmare", Text = "Win 7 games in {Map} with only {Class} units in {Difficulty}", Event = E.Win, Goal = 7, Map = RANDOM, Class = RANDOM, Difficulty = RANDOM, RewardDifficulty = "Nightmare",
			Rewards = { Cash = 1000, Crates = { Epic = 8 } } },

		-- Um dia UTC por vez, e so dentro da semana: e preciso entrar nos sete.
		{ Id = "W_Login7", Text = "Log in for 7 days straight", Event = E.Login, Goal = 7, Mode = "Distinct",
			Rewards = { Cash = 777, Shards = 7, Crates = { Common = 7, Rare = 7 } } },

		{ Id = "W_Unbox2Legendary", Text = "Unbox 2 Legendary Cards", Event = E.Unbox, Goal = 2, Rarity = "Legendary",
			Rewards = { Crates = { Epic = 4 } } },

		{ Id = "W_Damage1M", Text = "Deal 1,000,000 damage", Event = E.Damage, Goal = 1000000,
			Rewards = { Cash = 12000 } },

		{ Id = "W_Weather60", Text = "Experience Weathers 60 times", Event = E.Weather, Goal = 60,
			Rewards = { Crates = { Epic = 6 } } },

		{ Id = "W_Boss70", Text = "Defeat 70 bosses", Event = E.BossKill, Goal = 70,
			Rewards = { Shards = 40 } },

		{ Id = "W_Play7Hours", Text = "Play 7 hours worth of matches", Event = E.MatchTime, Goal = 7 * HOUR, Format = "Hours",
			Rewards = { Crates = { Epic = 12 } } },

		{ Id = "W_Win20Map", Text = "Win 20 games in {Map} in any difficulty", Event = E.Win, Goal = 20, Map = RANDOM,
			Rewards = { Crates = { Epic = 8 } } },

		{ Id = "W_UnboxCosmic", Text = "Unbox a Cosmic Card", Event = E.Unbox, Goal = 1, Rarity = "Cosmic",
			Rewards = { Crates = { Epic = 10 } } },
	},
}

--[[ INDICE ]]

local byId = {}
local kindOf = {}

for kind, list in ContractConfig.Contracts do
	for _, definition in list do
		assert(byId[definition.Id] == nil, `[ContractConfig]: Id repetido '{definition.Id}'.`)
		byId[definition.Id] = definition
		kindOf[definition.Id] = kind
	end
end

--[[ API ]]

function ContractConfig.get(id : string?) : any?
	return id and byId[id] or nil
end

function ContractConfig.kindOf(id : string?) : string?
	return id and kindOf[id] or nil
end

function ContractConfig.isKind(kind : any) : boolean
	return typeof(kind) == "string" and ContractConfig.KINDS[kind] ~= nil
end

--- O periodo em que `now` (segundos Unix) cai.
function ContractConfig.periodOf(kind : string, now : number) : number
	local info = ContractConfig.KINDS[kind]

	return math.floor((now - info.Offset) / info.Length)
end

--- Quando o periodo termina, em segundos Unix.
function ContractConfig.endsAt(kind : string, period : number) : number
	local info = ContractConfig.KINDS[kind]

	return (period + 1) * info.Length + info.Offset
end

--[=[
	O `Contracts` de um perfil novo. `Period = -1` nao e periodo nenhum, entao o
	primeiro carregamento sorteia os tres.
]=]
function ContractConfig.createEmpty()
	local contracts = {}

	for _, kind in ContractConfig.KIND_ORDER do
		contracts[kind] = { Period = -1, Slots = {} }
	end

	return contracts
end

--- O valor de um campo que pode ser `Random`: o sorteado no slot, ou o fixo.
function ContractConfig.resolve(definition, slot, field : string) : any?
	local value = definition[field]

	if value == RANDOM then
		return slot and slot.Params and slot.Params[field] or nil
	end

	return value
end

local function commas(value : number) : string
	local formatted = tostring(math.floor(value))
	local count

	repeat
		formatted, count = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
	until count == 0

	return formatted
end

local function formatAmount(definition, value : number) : string
	if definition.Format == "Hours" then
		-- Uma casa, para baixo: 6,99 horas nao podem aparecer como "7/7".
		local hours = math.floor(value / HOUR * 10) / 10
		local text = string.format("%.1f", hours)

		return (string.gsub(text, "%.0$", ""))
	end

	return commas(value)
end

--[=[
	A descricao com o sorteado no lugar e o progresso no fim:
	`Win 4 games in Volcano on Hard (1/4)`.
]=]
function ContractConfig.describe(definition, slot) : string
	local text = definition.Text

	text = string.gsub(text, "{Map}", function()
		local map = ContractConfig.resolve(definition, slot, "Map")
		local entry = map and MapConfig.MAPS[map]

		return entry and entry.DisplayName or tostring(map or "?")
	end)

	text = string.gsub(text, "{Difficulty}", function()
		return tostring(ContractConfig.resolve(definition, slot, "Difficulty") or "?")
	end)

	text = string.gsub(text, "{Class}", function()
		return tostring(ContractConfig.resolve(definition, slot, "Class") or "?")
	end)

	local progress = math.min(definition.Goal, (slot and slot.Progress) or 0)

	return string.format("%s (%s/%s)", text, formatAmount(definition, progress), formatAmount(definition, definition.Goal))
end

--[=[
	O developer product do proximo reroll da aba, dado quantos o jogador ja fez neste
	periodo. Passou do fim da lista, fica no ultimo.
]=]
function ContractConfig.rerollProduct(kind : string, rerolls : number?) : number?
	local products = ContractConfig.Reroll.Products[kind]
	if not products or #products == 0 then return nil end

	local index = math.clamp(math.floor(tonumber(rerolls) or 0) + 1, 1, #products)

	return products[index]
end

--- Se o progresso do slot ja chegou no objetivo.
function ContractConfig.isComplete(definition, slot) : boolean
	return definition ~= nil and slot ~= nil and (slot.Progress or 0) >= definition.Goal
end

--- Tempo em `HH:MM:SS`, com as horas passando de 24 (a semana mostra `167:59:59`).
function ContractConfig.formatRemaining(seconds : number) : string
	seconds = math.max(0, math.floor(seconds))

	return string.format("%02d:%02d:%02d", seconds // HOUR, (seconds // 60) % 60, seconds % 60)
end

return ContractConfig
