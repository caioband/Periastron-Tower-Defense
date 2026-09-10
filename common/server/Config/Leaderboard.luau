--[[
	As leaderboards globais do lobby (`Workspace.Leaderboards`).

	Cada entrada de `Boards` liga um modelo do mapa a um numero do perfil. Quem le
	e o `LeaderboardService` (common): nas duas places ele **grava** o numero de
	cada jogador num OrderedDataStore; na Lobby, onde a pasta existe, ele tambem
	**le** o topo e desenha.

	  - `Model`  -- o nome do modelo dentro de `Workspace.Leaderboards`.
	  - `Store`  -- o sufixo do OrderedDataStore. Trocar zera a board.
	  - `Path`   -- onde o numero mora no perfil (`Data`), chave por chave.
	  - `Format` -- como o numero aparece na linha:
	      "Level"  -- o nivel que o XP da (`LevelConfig:Resolve`)
	      "Number" -- abreviado (`1.25M`, `3.4B`)
	      "Time"   -- segundos em `DD:HH:MM`

	**Por que o HIGHEST LEVEL guarda XP, e nao o nivel.** A ordem e a mesma, e o XP
	desempata: dois jogadores no nivel 50 continuam em ordem de quem jogou mais.

	**O tamanho do jogo nao pesa.** O OrderedDataStore ja guarda as chaves em ordem,
	entao pedir o topo e uma pagina de `TOP` entradas -- o mesmo custo com cem
	jogadores ou com cem milhoes. Nada aqui percorre a store inteira.
]]

return {
	FOLDER_NAME = "Leaderboards",

	-- Quantas linhas cada board mostra. Uma pagina so do `GetSortedAsync`, que
	-- aceita ate 100.
	TOP = 50,

	--[[
		De quanto em quanto tempo cada servidor manda os numeros dos seus jogadores
		(so os que mudaram) e de quanto em quanto tempo o lobby redesenha o topo.

		O limite de escrita e 60 + 10 por jogador por minuto, por servidor. Com 8
		boards e 120s, o pior caso (todas mudaram) sao 4 por jogador por minuto --
		e o normal sao 2, os dois tempos.
	]]
	WRITE_INTERVAL = 120,
	READ_INTERVAL = 120,

	Boards = {
		{ Model = "HighestLevelLB", Store = "XP", Path = { "Stats", "XP" }, Format = "Level" },
		-- O total ganho, e nao o saldo: gastar na loja nao derruba ninguem da board.
		{ Model = "MostCoinsLB", Store = "CoinsEarned", Path = { "Stats", "CoinsEarned" }, Format = "Number" },
		{ Model = "MostMatchesWonLB", Store = "Wins", Path = { "Stats", "Wins" }, Format = "Number" },
		{ Model = "NightmareWinsLB", Store = "NightmareWins", Path = { "Stats", "DifficultyWins", "Nightmare" }, Format = "Number" },
		{ Model = "MostBoxesOpened", Store = "BoxesOpened", Path = { "Stats", "BoxesOpened" }, Format = "Number" },
		{ Model = "MostMatchesPlayedLB", Store = "MatchesPlayed", Path = { "Stats", "MatchesPlayed" }, Format = "Number" },
		{ Model = "MostTimeInMatchesLB", Store = "TimeInMatches", Path = { "Stats", "TimeInMatches" }, Format = "Time" },
		{ Model = "MostTimePlayedLB", Store = "TimePlayed", Path = { "Stats", "TimePlayed" }, Format = "Time" },
	},
}
