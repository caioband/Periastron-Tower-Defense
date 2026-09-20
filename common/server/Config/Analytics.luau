--[[
	A telemetria do jogo — SOMENTE SERVIDOR.

	A API de analytics da Roblox só responde a chamada de **servidor** e em place
	**publicada**: nada daqui precisa chegar ao cliente, e por isso o arquivo mora
	em `ServerScriptService.Config` junto da chave do DataStore e da lista de
	admins, e não na `SharedConfig`.

	Quem lê é o `AnalyticsService` (`common/server/Services`), que é o único lugar
	do jogo que toca a `game:GetService("AnalyticsService")`.
]]

return {
	--[[
		O **funil de onboarding**: o caminho do jogador novo, da oferta de tutorial
		no lobby até a caixa aberta na volta.

		`LogOnboardingFunnelStepEvent` é o tipo certo para uma conversão que acontece
		**uma vez por jogador** — a mesma coisa que a chave `Tutorial` do perfil diz.
		Ele não pede `funnelSessionId`, e é isso que deixa o funil atravessar Lobby →
		Game → Lobby sem um id viajando no `TeleportData`. A Roblox conta só a
		primeira vez de cada passo por usuário, então refazer o tutorial pelo
		`tutorialreset` não infla o painel.
	]]
	Funnel = {
		--[=[
			**A ordem É o número do passo**: o índice na lista vira o `step` que a
			Roblox recebe. Passo novo entra no fim, ou o painel passa a comparar
			números que querem dizer outra coisa do que queriam ontem.

			Do quarto ao nono, o nome é **o mesmo `Id`** do passo em
			`TutorialConfig.Match.Steps` — assim o `CompleteStep` manda `step.Id`
			direto, sem uma tabela de tradução no meio que possa ficar para trás
			quando o roteiro mudar.
		]=]
		Onboarding = {
			"PromptShown",   -- 1  a oferta apareceu no lobby
			"Accepted",      -- 2  clicou em SURE!
			"MatchJoined",   -- 3  caiu no servidor da partida de tutorial

			"ClickReady",    -- 4  \
			"PlaceFirst",    -- 5   |
			"BuyReport",     -- 6   |  os passos do roteiro, por `Id`
			"UseReport",     -- 7   |
			"UseSpeed",      -- 8   |
			"PlaceRest",     -- 9  /

			"MatchWon",      -- 10 venceu as 5 waves
			"BackToLobby",   -- 11 voltou ao lobby com o bilhete `TutorialDone`
			"CrateBought",   -- 12 comprou a Crate of Beginnings
			"CrateOpened",   -- 13 abriu a caixa: o fim do tutorial
		},
	},

	--[[
		Os eventos avulsos, que são o que o funil **não** sabe dizer.

		`Declined` separa "respondeu que não" de "ignorou a caixa de fala": as duas
		coisas param no passo 1 do funil, e são decisões diferentes.

		`Abandoned` é a partida largada no meio — que deixa a chave do perfil em
		`false` e hoje não tem registro nenhum. O valor do evento é a wave em que ele
		estava.
	]]
	Events = {
		Declined = "TutorialDeclined",
		Abandoned = "TutorialAbandoned",
	},
}
