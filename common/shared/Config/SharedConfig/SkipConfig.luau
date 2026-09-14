--[[
	A votação de pular a wave: `StarterGui.Interface.SkipPrompt`.

	O prompt aparece sozinho `OfferDelay` segundos depois de a wave começar e fica
	até ela acabar. Dano de unidade não esconde: a votação é da wave, e não de um
	momento em que a partida parecia travada. Quem decide isso é o `SkipService`;
	quem desenha é o `SkipPromptController`.

	`OfferDelay` é medido em **tempo real**, e não no `GameClock`: ele existe para
	medir a paciência de quem está olhando a tela, e não o ritmo da partida. No 2x
	o jogo anda mais rápido, mas sete segundos continuam sendo sete segundos.

	A animação é a mesma do `WeatherWarning` (ver `WarningConfig`): o prompt desce
	de `SlideOffset` acima do lugar autorado enquanto a transparência de **todos**
	os descendentes cai de 1 até o valor que o designer deixou. Descer até o valor
	autorado, e não até zero, é o que preserva um fundo transparente ou uma sombra
	a 20% — quem for pintado no Studio continua igual na tela.

	Só a Game usa (o Lobby não tem wave), mas o config mora aqui porque o cliente
	precisa dos tempos da animação e dos textos.
]]

local SkipConfig = {}

-- O ImageLabel dentro de `PlayerGui.Interface`.
SkipConfig.Name = "SkipPrompt"

-- Nomes dentro do prompt.
SkipConfig.ConfirmName = "Confirm"
SkipConfig.CancelName = "Cancel"
SkipConfig.CountName = "PlayerCount"

--[[
	Segundos entre a wave começar (o instante em que os mobs dela começam a nascer)
	e o prompt entrar. Se a wave ainda estiver nascendo nessa hora, ele espera o
	último mob -- ver `WaveService:CanSkipWave`.
]]
SkipConfig.OfferDelay = 7

-- De quanto em quanto o servidor confere se já é hora de abrir ou de fechar. Não
-- precisa ser fino: o que ele mede é uma janela de sete segundos.
SkipConfig.PollInterval = 0.25

--[[
	Animação, igual à do aviso do meio da tela. `SlideOffset` é em escala do eixo Y
	da tela, contado para cima do lugar autorado.
]]
SkipConfig.SlideOffset = 0.06
SkipConfig.FadeIn = 0.35
SkipConfig.FadeOut = 0.25

-- O contador do prompt: votos que já entraram sobre votos que faltam.
SkipConfig.CountText = "%d/%d"

--[=[
	Quantos votos fecham a votação, dado quem está no servidor.

	Maioria estrita: um jogador sozinho decide sozinho, dois precisam concordar,
	quatro precisam de três. Um voto a menos que isso deixaria metade da sala
	pulando a wave da outra metade.
]=]
function SkipConfig.RequiredVotes(total : number) : number
	if total <= 0 then
		return 0
	end

	return math.floor(total / 2) + 1
end

return SkipConfig
