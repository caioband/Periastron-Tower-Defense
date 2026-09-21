--[=[
	Curva de nivel do perfil e a arte da barra de XP do HUD.

	`Stats.XP` no perfil e um total acumulado — o nivel nao e guardado, e sempre
	derivado dai (`Resolve`). Assim nao existe perfil com nivel e XP fora de sincronia
	e mexer na curva reavalia todo mundo sem migracao.

	O XP por partida sai de `Config.Data.BASE_WINNING_XP` (200 numa run cheia no
	Normal, escalado pela fracao de waves e pelo `WinXpMultiplier` da dificuldade),
	entao `BASE_XP = 100` deixa o primeiro nivel a meia partida e a curva vai abrindo
	dai pra frente.

	Quem depende do nivel: os slots de deck (`DeckConfig.SLOT_UNLOCK_LEVELS`, nos
	niveis 5, 15 e 25) e o caminho alternativo de destravar dificuldade
	(`DifficultyUnlockConfig`, niveis 3, 6 e 12) -- mexer na curva move os dois, e e
	por isso que o expoente e o numero a mexer, e nao o `BASE_XP`: o inicio continua
	no lugar e quem encurta e o meio pra frente, que e onde estava a grind.
]=]

local LevelConfig = {}

--[[ CURVA ]]

LevelConfig.MAX_LEVEL = 50

--[=[
	XP para sair do nivel L: floor(BASE_XP * L^CURVE).

	O expoente desceu de 1.35 para 1.20 para o nivel subir mais rapido. O comeco nao
	muda (L1->2 continua custando 100, porque 1^x e 1 em qualquer expoente); o que
	encurta e o resto, e cada vez mais:

	| Sair do nivel | 1.35 (antes) | 1.20 (agora) |
	| --- | --- | --- |
	| 1 | 100 | 100 |
	| 5 | 878 | 690 |
	| 10 | 2.239 | 1.585 |
	| 20 | 5.707 | 3.641 |
	| 49 | 19.132 | 10.672 |

	No acumulado sao ~15% menos XP ate o nivel 5, ~28% ate o 15, ~34% ate o 25 (o
	ultimo slot de deck) e ~41% ate o 50 -- de ~2.040 para ~1.215 runs cheias no
	Normal, contando so o XP de partida.
]=]
LevelConfig.BASE_XP = 100
LevelConfig.CURVE = 1.20

--[[ BARRA ]]

--[=[
	Uma imagem por faixa de progresso do nivel atual, em ordem crescente: cada
	entrada vale ate o seu `Threshold`. Abaixo da primeira (progresso exatamente
	zero) a barra fica com a imagem vazia que veio autorada na GUI — ver
	`HUDController`, que a le do proprio ImageLabel em vez de repetir o id aqui.
]=]
LevelConfig.BAR_IMAGES = {
	{ Threshold = 0.2, Image = "rbxassetid://134959500194037" },
	{ Threshold = 0.4, Image = "rbxassetid://114833771984043" },
	{ Threshold = 0.6, Image = "rbxassetid://130493899698635" },
	{ Threshold = 0.8, Image = "rbxassetid://93135811626919" },
	{ Threshold = 1.0, Image = "rbxassetid://135439475286984" },
}

export type LevelState = {
	Level : number,
	XP : number,        -- XP dentro do nivel atual
	Required : number,  -- XP para o proximo nivel (0 no maximo)
	Progress : number,  -- 0..1
	IsMax : boolean,
}

--[[ API ]]

--[=[
	Quanto XP custa sair de `level` para o seguinte. Zero no nivel maximo.
]=]
function LevelConfig:GetXPForLevel(level : number) : number
	level = math.floor(tonumber(level) or 1)

	if level < 1 or level >= self.MAX_LEVEL then
		return 0
	end

	return math.floor(self.BASE_XP * (level ^ self.CURVE) + 0.5)
end

--[=[
	Quebra o XP acumulado do perfil em nivel + progresso dentro dele.
]=]
function LevelConfig:Resolve(totalXP : number?) : LevelState
	local remaining = math.max(0, math.floor(tonumber(totalXP) or 0))
	local level = 1

	while level < self.MAX_LEVEL do
		local cost = self:GetXPForLevel(level)
		if remaining < cost then
			break
		end

		remaining -= cost
		level += 1
	end

	local isMax = level >= self.MAX_LEVEL
	local required = isMax and 0 or self:GetXPForLevel(level)

	return {
		Level = level,
		XP = isMax and 0 or remaining,
		Required = required,
		Progress = isMax and 1 or (required > 0 and math.clamp(remaining / required, 0, 1) or 0),
		IsMax = isMax,
	}
end

--[=[
	A imagem da faixa em que o progresso cai, ou nil quando ele e zero — nesse caso
	quem chama usa a barra vazia autorada.
]=]
function LevelConfig:GetBarImage(progress : number) : string?
	progress = tonumber(progress) or 0

	if progress <= 0 then
		return nil
	end

	for _, entry in self.BAR_IMAGES do
		if progress <= entry.Threshold then
			return entry.Image
		end
	end

	return self.BAR_IMAGES[#self.BAR_IMAGES].Image
end

--[=[
	Todos os ids da barra, para o preload do HUD.
]=]
function LevelConfig:GetBarImages() : { string }
	local images = {}

	for _, entry in self.BAR_IMAGES do
		table.insert(images, entry.Image)
	end

	return images
end

return LevelConfig
