local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Música do Lobby.

	Toca tudo que estiver em `SoundService.SharedSounds.Musics.Lobby`, em ordem
	aleatória e em fila infinita: entra com fade, e cada faixa que acaba dá lugar
	à próxima em transição. Faixa nova no jogo é só soltar o Sound na pasta — não
	há lista de nomes aqui.

	Quem toca é o MusicController; este controller só resolve *o que* tocar.
	A regra de nunca repetir a faixa que acabou de sair vive lá, no
	`_advancePlaylist`, porque vale para qualquer fila.
]]

local FOLDER = "Lobby"
local FADE = 2

local LobbyMusicController = {
	Controllers = {
		MusicController = {},
	},
}

-- Nomes dos Sounds da pasta, incluindo subpastas.
function LobbyMusicController:getTrackNames(): { string }
	local music = self.Controllers.MusicController

	local musics = music:GetFolder()
	if not musics then
		return {}
	end

	local folder = musics:FindFirstChild(FOLDER)
	if not folder then
		warn(`[LobbyMusicController]: SoundService.SharedSounds.Musics.{FOLDER} não existe.`)
		return {}
	end

	local names = {}
	for _, inst in folder:GetDescendants() do
		if inst:IsA("Sound") then
			table.insert(names, inst.Name)
		end
	end

	return names
end

function LobbyMusicController:play()
	local names = self:getTrackNames()
	if #names == 0 then
		warn(`[LobbyMusicController]: nenhuma música em SoundService.SharedSounds.Musics.{FOLDER}.`)
		return
	end

	--[[
		Shuffle já embaralha na entrada, então a primeira faixa é qualquer uma, e
		re-embaralha a cada volta. Loop mantém a fila viva enquanto o jogador
		estiver no Lobby.
	]]
	self.Controllers.MusicController:PlayPlaylist(names, {
		Shuffle = true,
		Loop = true,
		Fade = FADE,
	})
end

function LobbyMusicController:construct()
	--[[
		Fora da thread do start: `GetFolder` espera a pasta aparecer, e não vale
		segurar o carregamento dos outros controllers por causa disso.
	]]
	task.spawn(function()
		self:play()
	end)
end

--[[
	No `start`, não no `init`: o Me roda os `init` enquanto ainda está requerindo
	os módulos, e `Framework:Get` devolve nil para quem ainda não entrou na lista.
	Quando os `start` rodam, todos já estão carregados.
]]
function LobbyMusicController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	self:construct()
end

function LobbyMusicController:init() end

return LobbyMusicController
