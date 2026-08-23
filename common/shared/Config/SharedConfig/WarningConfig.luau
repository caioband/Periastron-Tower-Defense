--[[
	O aviso grande no meio da tela: `StarterGui.Interface.WeatherWarning`, um
	TextLabel com um UIStroke dentro.

	O nome do label é o do clima por herança — foi para o clima que ele nasceu —,
	mas o label é **um só** e serve a quem precisar de uma frase curta e urgente na
	tela. Hoje são dois donos: o clima que vem vindo (`WeatherWarningController`) e
	o restart do servidor (`ServerRestartController`). Quem os coloca lá é o
	`WarningController`, o único que encosta no label.

	`Label` é a animação: o texto desce de `SlideOffset` acima do destino enquanto a
	transparência (do texto **e** do stroke) cai de 1 para 0, segura `Hold` segundos
	e sai pelo mesmo caminho. O destino é a posição que o designer deixou no
	StarterGui, então mover o label no Studio não exige tocar em código.

	`Priority` resolve os dois donos disputando a tela: um aviso só derruba o que
	estiver no ar se a prioridade dele for maior ou igual. É o que impede um clima
	de apagar o "o servidor vai reiniciar em 1 minuto".

	Fica em `common/` porque o restart acontece nas duas places.
]]

local WarningConfig = {}

WarningConfig.Label = {
	Name = "WeatherWarning",

	SlideOffset = 0.06,
	FadeIn = 0.5,
	Hold = 5,
	FadeOut = 0.4,
}

WarningConfig.Priority = {
	Weather = 1,
	Restart = 2,
}

--[[
	Aviso de restart do servidor.

	`Text` leva quem pediu o restart e quanto falta — "WARNING! SERVER RESTART FOR
	GAME UPDATE IN 2 MINUTES". Faltando menos que `NowThreshold`, ou não vindo
	horário nenhum, vale o `TextNow`, que não promete prazo que não tem.

	`Sources` traduz o `Enum.CloseReason` que o servidor recebeu. É o que separa o
	restart do desenvolvedor (uma atualização do jogo, culpa nossa) do restart da
	própria Roblox (manutenção, moderação, memória) — o jogador merece saber qual
	dos dois é, porque só um deles significa "volte que tem coisa nova".

	`Reminders` são as marcas, em segundos que faltam, em que o aviso volta à tela.
	Um restart é agendado com minutos de antecedência: mostrar uma vez e sumir
	deixaria de fora quem entrou depois ou estava olhando para o mapa. Marca que
	cairia em cima do aviso anterior é descartada pelo controller.
]]
WarningConfig.Restart = {
	Text = "WARNING! SERVER RESTART FOR %s IN %s",
	TextNow = "WARNING! SERVER RESTARTING FOR %s",

	Hold = 8,
	Reminders = { 300, 120, 60, 30, 10 },
	NowThreshold = 5,

	Sources = {
		-- O desenvolvedor: `DeveloperUpdate` é o `UpdatePlace`, `DeveloperShutdown`
		-- é o botão de desligar do painel.
		DeveloperUpdate = "GAME UPDATE",
		DeveloperShutdown = "GAME UPDATE",

		-- A Roblox.
		RobloxMaintenance = "ROBLOX MAINTENANCE",
		Moderation = "MODERATION",
		OutOfMemory = "SERVER MEMORY",
		ServerEmpty = "INACTIVITY",
		Unknown = "MAINTENANCE",
	},
	DefaultSource = "MAINTENANCE",

	--[[
		Como o tempo que falta é escrito. A maior unidade que couber ganha: 90
		segundos vira "2 MINUTES", não "1 MINUTE 30 SECONDS" — é um aviso de uma
		linha, não um cronômetro.
	]]
	Durations = {
		{ Seconds = 3600, One = "%d HOUR", Many = "%d HOURS" },
		{ Seconds = 60, One = "%d MINUTE", Many = "%d MINUTES" },
		{ Seconds = 1, One = "%d SECOND", Many = "%d SECONDS" },
	},
}

--[=[
	O que escrever para um `Enum.CloseReason`.

	Recebe o **nome** do enum (é assim que ele atravessa a rede) e devolve o
	`DefaultSource` para o que não estiver na tabela — motivo novo da Roblox vira um
	aviso genérico em vez de nenhum aviso.
]=]
function WarningConfig.GetRestartSource(sourceName : string?) : string
	local restart = WarningConfig.Restart

	return (sourceName and restart.Sources[sourceName]) or restart.DefaultSource
end

--[=[
	"2 MINUTES", "45 SECONDS", "1 HOUR".

	Arredonda para a unidade mais próxima em vez de truncar: faltando 119 segundos,
	"2 MINUTES" erra por um segundo e "1 MINUTE" erra por cinquenta e nove. Nunca
	desce de 1 — "0 MINUTES" seria mentira nos dois sentidos.
]=]
function WarningConfig.FormatDuration(seconds : number) : string
	local remaining = math.max(seconds, 0)

	for _, duration in WarningConfig.Restart.Durations do
		if remaining < duration.Seconds then continue end

		local amount = math.max(math.floor(remaining / duration.Seconds + 0.5), 1)

		return string.format(if amount == 1 then duration.One else duration.Many, amount)
	end

	-- Menos de um segundo: o `TextNow` é quem deveria ter falado, mas quem chamar
	-- daqui mesmo assim recebe algo legível.
	local last = WarningConfig.Restart.Durations[#WarningConfig.Restart.Durations]

	return string.format(last.One, 1)
end

return WarningConfig
