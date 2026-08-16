local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Signal = require(Packages.Signal)
local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Áudio do jogo, compartilhado pelas duas places. O Package SharedSounds separa
	os dois usos, e o controller trata cada um do jeito que ele pede:

		SoundService.SharedSounds
		├── Musics   uma faixa de cada vez, com fade/crossfade — :Play, :Transition
		└── SFX      efeitos curtos e sobrepostos            — :PlaySFX

	Pode haver subpasta nas duas (Musics.Maps.Forest, SFX.UI.Click...): a busca é
	recursiva e usa só o nome do Sound, então o nome tem que ser único dentro da
	pasta.

	Música toca a própria instância, não um clone: Sound:Play() no cliente não
	replica, e assim o Volume/SoundGroup ajustado no Studio continua valendo. O
	volume que estava lá na primeira vez que a faixa é tocada vira o volume
	"base"; tudo que o controller faz (fade, master, mute, duck) é multiplicador
	em cima dele.

		local Sound = Framework:Get("MusicController")
		Sound:Transition("Snowy", 2)
		Sound:PlaySFX("UnitPlace")

	Volume final de uma faixa = base * (override do :Play) * master * duck, ou 0
	com mute. Qualquer mudança nesses fatores re-aplica em quem já está tocando.

	SFX é o contrário: sempre clone, porque dois tiros podem tocar juntos e o
	original não pode ficar preso num Play. O clone se destrói sozinho no fim.

	Fica em common/ porque o Me varre Controllers.Common nas duas places — o nome
	do módulo precisa ser único entre Common e a pasta da place.
--]]

local SHARED_SOUNDS = "SharedSounds"
local MUSICS_FOLDER = "Musics"
local SFX_FOLDER = "SFX"

-- Tempo dos fades quando quem chama não diz nada.
local DEFAULT_FADE = 1.5
local DEFAULT_VOLUME_FADE = 0.35

-- Quanto esperar pela pasta antes de desistir e avisar. Não pode ser
-- WaitForChild no topo do arquivo: isso travaria o Me:Load() do cliente inteiro.
local FOLDER_TIMEOUT = 15

-- Um SFX que nunca carregou não dispara Ended; sem isso o clone ficaria pra
-- sempre pendurado no pai.
local SFX_FALLBACK_LIFETIME = 15

export type PlayOptions = {
	Fade: number?, -- fade in, em segundos (0 = entra seco)
	Volume: number?, -- multiplicador em cima do volume do Studio
	Looped: boolean?, -- default true
	Speed: number?, -- PlaybackSpeed
	StartTime: number?, -- TimePosition inicial
	Restart: boolean?, -- true = reinicia mesmo se a faixa já for a atual
}

export type PlaylistOptions = {
	Shuffle: boolean?, -- embaralha a ordem (e re-embaralha a cada volta)
	Loop: boolean?, -- default true; false para a fila terminar em silêncio
	Fade: number?,
	Volume: number?,
}

export type SFXOptions = {
	Parent: Instance?, -- Part/Attachment deixa o som 3D; default SoundService (2D)
	Volume: number?, -- multiplicador em cima do volume do Studio
	Speed: number?, -- PlaybackSpeed
	Looped: boolean?, -- exige Key ou Cut pra limpar depois
	Cut: number?, -- corta em N segundos, mesmo que a faixa seja mais longa
	Key: string?, -- só um som vivo por chave: o novo derruba o anterior
}

local MusicController = {}

-- Disparados como (nome, sound). TrackEnded só sai quando a faixa termina
-- sozinha; :Stop() não conta como fim.
MusicController.TrackChanged = Signal.new()
MusicController.TrackEnded = Signal.new()

MusicController.Current = nil :: Sound?
MusicController.CurrentName = nil :: string?

MusicController._Folders = {} :: { [string]: Instance }
MusicController._SFXMaster = 1
MusicController._ActiveSFX = {} :: { [string]: Sound } -- por Key
MusicController._Base = {} :: { [Sound]: number } -- volume original do Studio
MusicController._Override = {} :: { [Sound]: number } -- multiplicador do :Play
MusicController._Fades = {} :: { [Sound]: Tween }
MusicController._Master = 1
MusicController._Duck = 1
MusicController._Muted = false
MusicController._EndedConn = nil :: RBXScriptConnection?
MusicController._Playlist = nil :: { string }?
MusicController._PlaylistIndex = 0
MusicController._PlaylistOptions = nil :: PlaylistOptions?

-- Faixa guardada pelo PushTrack. nil = nada guardado; false = estava em silêncio
-- na hora do push, então o Pop volta pro silêncio.
MusicController._PushedFrom = nil :: (string | boolean)?

--[[ PASTAS ]]

-- Resolve SoundService.SharedSounds.<pasta> só na primeira vez que precisa.
function MusicController:_getFolder(folderName: string): Instance?
	local cached = self._Folders[folderName]
	if cached and cached.Parent then
		return cached
	end

	local sharedSounds = SoundService:WaitForChild(SHARED_SOUNDS, FOLDER_TIMEOUT)
	if not sharedSounds then
		warn(`[MusicController]: SoundService.{SHARED_SOUNDS} não apareceu.`)
		return nil
	end

	local folder = sharedSounds:WaitForChild(folderName, FOLDER_TIMEOUT)
	if not folder then
		warn(`[MusicController]: SoundService.{SHARED_SOUNDS}.{folderName} não apareceu.`)
		return nil
	end

	self._Folders[folderName] = folder
	return folder
end

function MusicController:GetFolder(): Instance?
	return self:_getFolder(MUSICS_FOLDER)
end

function MusicController:GetSFXFolder(): Instance?
	return self:_getFolder(SFX_FOLDER)
end

function MusicController:_find(folder: Instance?, name: string): Sound?
	if not folder then
		return nil
	end

	local sound = folder:FindFirstChild(name, true)
	if sound and sound:IsA("Sound") then
		return sound
	end

	return nil
end

-- Busca recursiva: a faixa pode estar numa subpasta de Musics.
function MusicController:GetTrack(name: string): Sound?
	return self:_find(self:GetFolder(), name)
end

function MusicController:GetSFX(name: string): Sound?
	return self:_find(self:GetSFXFolder(), name)
end

-- Nomes de tudo que dá pra tocar, útil pra playlist/random.
function MusicController:GetTrackNames(): { string }
	local names = {}

	local folder = self:GetFolder()
	if not folder then
		return names
	end

	for _, inst in folder:GetDescendants() do
		if inst:IsA("Sound") then
			table.insert(names, inst.Name)
		end
	end

	return names
end

--[[ VOLUME ]]

function MusicController:_baseVolume(sound: Sound): number
	local base = self._Base[sound]
	if not base then
		base = sound.Volume
		self._Base[sound] = base
	end

	return base
end

function MusicController:_targetVolume(sound: Sound): number
	if self._Muted then
		return 0
	end

	return self:_baseVolume(sound) * (self._Override[sound] or 1) * self._Master * self._Duck
end

--[[
	Descarta o fade que estiver rodando na faixa. Importante antes de tocar de
	novo: um fade de saída ainda pendente chamaria o :Stop dele em cima da faixa
	que acabou de voltar. Tween cancelado não roda o Completed com Completed,
	então o callback do fade antigo morre junto.
]]
function MusicController:_cancelFade(sound: Sound)
	local existing = self._Fades[sound]
	if existing then
		existing:Cancel()
		self._Fades[sound] = nil
	end
end

-- Fade cancelável: um fade novo na mesma Sound descarta o anterior, senão os
-- dois brigam pela propriedade e o volume termina em qualquer lugar.
function MusicController:_fade(sound: Sound, target: number, duration: number?, onComplete: (() -> ())?)
	self:_cancelFade(sound)

	local time = duration or 0
	if time <= 0 then
		sound.Volume = target
		if onComplete then
			onComplete()
		end
		return
	end

	local tween = TweenService:Create(sound, TweenInfo.new(time, Enum.EasingStyle.Linear), { Volume = target })
	self._Fades[sound] = tween

	tween.Completed:Connect(function(state)
		if self._Fades[sound] == tween then
			self._Fades[sound] = nil
		end
		if state == Enum.PlaybackState.Completed and onComplete then
			onComplete()
		end
	end)

	tween:Play()
end

-- Re-aplica o volume de tudo que está tocando (depois de mudar master/duck/mute).
function MusicController:_refreshVolumes(fade: number?)
	for sound in self._Base do
		if sound.Parent and (sound.IsPlaying or sound.IsPaused) then
			self:_fade(sound, self:_targetVolume(sound), fade)
		end
	end
end

--[[ REPRODUÇÃO ]]

function MusicController:_clearEnded()
	if self._EndedConn then
		self._EndedConn:Disconnect()
		self._EndedConn = nil
	end
end

function MusicController:_setCurrent(sound: Sound?, name: string?)
	self.Current = sound
	self.CurrentName = name

	if sound and name then
		self.TrackChanged:Fire(name, sound)
	end
end

--[[
	Toca uma faixa. Se ela já for a atual e estiver tocando, não faz nada — a não
	ser com Restart = true. É o que evita o mapa reiniciar a própria música toda
	vez que o servidor reenvia o nome dela.
]]
function MusicController:Play(name: string, options: PlayOptions?): Sound?
	return self:_play(name, options, "user")
end

--[[
	`source` diz quem pediu, e é o que decide o que sobrevive à troca:

		"user"      um :Play na mão — manda mais que tudo, cancela a fila e larga
		            a faixa guardada pelo PushTrack
		"playlist"  o avanço da própria fila, que não pode se cancelar
		"push"/"pop" troca temporária, que não pode apagar o que guardou
]]
function MusicController:_play(name: string, options: PlayOptions?, source: string?): Sound?
	local opts: PlayOptions = options or {}

	local sound = self:GetTrack(name)
	if not sound then
		warn(`[MusicController]: faixa "{name}" não existe em {SHARED_SOUNDS}.{MUSICS_FOLDER}.`)
		return nil
	end

	if sound == self.Current and sound.IsPlaying and not opts.Restart then
		return sound
	end

	if source ~= "playlist" then
		self:_stopPlaylist()
	end

	if source == "user" then
		self._PushedFrom = nil
	end

	if self.Current and self.Current ~= sound then
		self:_stopSound(self.Current, opts.Fade or DEFAULT_FADE)
	end

	self:_clearEnded()
	self:_baseVolume(sound)
	self:_cancelFade(sound)
	self._Override[sound] = opts.Volume

	sound.Looped = if opts.Looped == nil then true else opts.Looped
	sound.PlaybackSpeed = opts.Speed or sound.PlaybackSpeed
	sound.TimePosition = opts.StartTime or 0

	local target = self:_targetVolume(sound)
	local fade = opts.Fade or 0
	sound.Volume = if fade > 0 then 0 else target
	sound:Play()

	if fade > 0 then
		self:_fade(sound, target, fade)
	end

	self._EndedConn = sound.Ended:Connect(function()
		if self.Current ~= sound then
			return
		end
		self.TrackEnded:Fire(name, sound)
		self:_advancePlaylist()
	end)

	self:_setCurrent(sound, name)
	return sound
end

--[[
	Troca de faixa em crossfade: a atual sai enquanto a nova entra, no mesmo
	tempo. Se não há nada tocando, é só um fade in.
]]
function MusicController:Transition(name: string, fadeTime: number?, options: PlayOptions?): Sound?
	local opts: PlayOptions = table.clone(options or {})
	opts.Fade = fadeTime or opts.Fade or DEFAULT_FADE

	local sound = self:GetTrack(name)
	if sound and sound == self.Current and sound.IsPlaying and not opts.Restart then
		return sound
	end

	return self:Play(name, opts)
end

--[[
	Troca temporária: guarda a faixa que está tocando e entra por cima dela. É o
	caso da música de boss — o :PopTrack devolve a de antes sem quem chamou
	precisar lembrar qual era.

		Music:PushTrack("Boss")   -- wave de boss começou
		Music:PopTrack()          -- wave seguinte sem boss, volta a do mapa

	Push repetido não empilha: o segundo vê que a faixa já é a atual e sai sem
	mexer no que foi guardado, então waves de boss seguidas continuam voltando
	pra música certa. Se não havia nada tocando na hora do push, o Pop volta pro
	silêncio.
]]
function MusicController:PushTrack(name: string, fadeTime: number?, options: PlayOptions?): Sound?
	if self.CurrentName == name then
		return self.Current
	end

	if self._PushedFrom == nil then
		self._PushedFrom = self.CurrentName or false
	end

	local opts: PlayOptions = table.clone(options or {})
	opts.Fade = fadeTime or opts.Fade or DEFAULT_FADE

	return self:_play(name, opts, "push")
end

function MusicController:PopTrack(fadeTime: number?): Sound?
	local previous = self._PushedFrom
	if previous == nil then
		return nil
	end

	self._PushedFrom = nil

	-- false: não tinha música quando o push aconteceu.
	if type(previous) ~= "string" then
		self:Stop(fadeTime or DEFAULT_FADE)
		return nil
	end

	return self:_play(previous, { Fade = fadeTime or DEFAULT_FADE }, "pop")
end

function MusicController:IsPushed(): boolean
	return self._PushedFrom ~= nil
end

--[[
	Fade out + Stop. No fim devolve o volume do Studio e larga o override daquele
	:Play — a instância é compartilhada, então ela tem que voltar exatamente como
	estava (senão a faixa volta muda, ou volta com o volume de outra chamada).
]]
function MusicController:_stopSound(sound: Sound, fadeTime: number?)
	local restore = self:_baseVolume(sound)

	-- Sem fade, o _fade resolve na hora e o callback roda antes de voltar.
	self:_fade(sound, 0, fadeTime, function()
		sound:Stop()
		sound.TimePosition = 0
		sound.Volume = restore
		self._Override[sound] = nil
	end)
end

-- Para a faixa atual. Sem fadeTime, corta seco.
function MusicController:Stop(fadeTime: number?)
	self:_stopPlaylist()
	self:_clearEnded()
	self._PushedFrom = nil

	local current = self.Current
	if not current then
		return
	end

	self:_stopSound(current, fadeTime)
	self:_setCurrent(nil, nil)
end

-- Rede de segurança: para qualquer faixa que este controller tenha tocado.
function MusicController:StopAll(fadeTime: number?)
	self:_stopPlaylist()
	self:_clearEnded()
	self._PushedFrom = nil

	for sound in self._Base do
		if sound.Parent and (sound.IsPlaying or sound.IsPaused) then
			self:_stopSound(sound, fadeTime)
		end
	end

	self:_setCurrent(nil, nil)
end

-- Pausa guardando a posição; :Resume() continua de onde parou.
function MusicController:Pause(fadeTime: number?)
	local current = self.Current
	if not current or not current.IsPlaying then
		return
	end

	if fadeTime and fadeTime > 0 then
		self:_fade(current, 0, fadeTime, function()
			current:Pause()
		end)
	else
		current:Pause()
	end
end

function MusicController:Resume(fadeTime: number?)
	local current = self.Current
	if not current or current.IsPlaying then
		return
	end

	local target = self:_targetVolume(current)
	if fadeTime and fadeTime > 0 then
		current.Volume = 0
		current:Resume()
		self:_fade(current, target, fadeTime)
	else
		current.Volume = target
		current:Resume()
	end
end

function MusicController:TogglePause(fadeTime: number?)
	local current = self.Current
	if not current then
		return
	end

	if current.IsPlaying then
		self:Pause(fadeTime)
	else
		self:Resume(fadeTime)
	end
end

-- Volta do começo sem trocar de faixa.
function MusicController:Restart(fadeTime: number?)
	local current = self.Current
	if not current then
		return
	end

	self:_cancelFade(current)
	current.TimePosition = 0

	if not current.IsPlaying then
		current.Volume = if fadeTime and fadeTime > 0 then 0 else self:_targetVolume(current)
		current:Play()
	end

	if fadeTime and fadeTime > 0 then
		current.Volume = 0
		self:_fade(current, self:_targetVolume(current), fadeTime)
	end
end

function MusicController:Seek(timePosition: number)
	local current = self.Current
	if not current then
		return
	end

	current.TimePosition = math.clamp(timePosition, 0, current.TimeLength)
end

function MusicController:SetSpeed(speed: number)
	local current = self.Current
	if current then
		current.PlaybackSpeed = speed
	end
end

--[[ MASTER / MUTE / DUCK ]]

-- Volume geral da música, 0 a 1, multiplicado em cima do volume do Studio.
function MusicController:SetVolume(scale: number, fadeTime: number?)
	self._Master = math.max(scale, 0)
	self:_refreshVolumes(fadeTime or DEFAULT_VOLUME_FADE)
end

function MusicController:GetVolume(): number
	return self._Master
end

function MusicController:Mute(fadeTime: number?)
	if self._Muted then
		return
	end

	self._Muted = true
	self:_refreshVolumes(fadeTime or DEFAULT_VOLUME_FADE)
end

function MusicController:Unmute(fadeTime: number?)
	if not self._Muted then
		return
	end

	self._Muted = false
	self:_refreshVolumes(fadeTime or DEFAULT_VOLUME_FADE)
end

function MusicController:ToggleMute(fadeTime: number?): boolean
	if self._Muted then
		self:Unmute(fadeTime)
	else
		self:Mute(fadeTime)
	end

	return self._Muted
end

function MusicController:IsMuted(): boolean
	return self._Muted
end

--[[
	Abaixa a música temporariamente sem mexer no volume que o jogador escolheu —
	pra cutscene, diálogo, boss spawn. :Unduck() devolve.
]]
function MusicController:Duck(scale: number, fadeTime: number?)
	self._Duck = math.clamp(scale, 0, 1)
	self:_refreshVolumes(fadeTime or DEFAULT_VOLUME_FADE)
end

function MusicController:Unduck(fadeTime: number?)
	self._Duck = 1
	self:_refreshVolumes(fadeTime or DEFAULT_VOLUME_FADE)
end

--[[ FILA ]]

function MusicController:_stopPlaylist()
	self._Playlist = nil
	self._PlaylistIndex = 0
	self._PlaylistOptions = nil
end

function MusicController:_advancePlaylist()
	local list = self._Playlist
	local opts = self._PlaylistOptions
	if not list or not opts then
		return
	end

	local index = self._PlaylistIndex + 1
	if index > #list then
		if opts.Loop == false then
			self:_stopPlaylist()
			self:_setCurrent(nil, nil)
			return
		end

		index = 1
		if opts.Shuffle then
			self:_shuffle(list)
		end
	end

	self._PlaylistIndex = index
	self:_play(list[index], {
		Fade = opts.Fade or DEFAULT_FADE,
		Volume = opts.Volume,
		Looped = false,
		Restart = true,
	}, "playlist")
end

function MusicController:_shuffle(list: { string })
	for i = #list, 2, -1 do
		local j = math.random(i)
		list[i], list[j] = list[j], list[i]
	end
end

--[[
	Toca uma sequência de faixas, avançando sozinha quando cada uma termina.
	Sem `names`, usa tudo que estiver em Musics. Loop = false para a fila acabar
	em silêncio; Shuffle re-embaralha a cada volta.
]]
function MusicController:PlayPlaylist(names: { string }?, options: PlaylistOptions?)
	local opts: PlaylistOptions = options or {}
	local list = if names then table.clone(names) else self:GetTrackNames()

	if #list == 0 then
		warn("[MusicController]: playlist vazia.")
		return
	end

	if opts.Shuffle then
		self:_shuffle(list)
	end

	self._Playlist = list
	self._PlaylistOptions = opts
	self._PlaylistIndex = 0

	self:_advancePlaylist()
end

-- Pula pra próxima da fila na mão.
function MusicController:Next()
	if not self._Playlist then
		return
	end

	self:_advancePlaylist()
end

-- Uma faixa aleatória, sem fila.
function MusicController:PlayRandom(names: { string }?, options: PlayOptions?): Sound?
	local list = names or self:GetTrackNames()
	if #list == 0 then
		return nil
	end

	return self:Play(list[math.random(#list)], options)
end

--[[ SFX ]]

--[[
	Toca um efeito de SoundService.SharedSounds.SFX. Sempre num clone, que se
	destrói quando acaba — dois efeitos iguais podem se sobrepor sem um cortar o
	outro, e o Sound original nunca fica preso tocando.

		Sound:PlaySFX("UnitPlace")                                  -- 2D
		Sound:PlaySFX("Explosion", { Parent = mine.PrimaryPart })   -- 3D, no lugar
		Sound:PlaySFX("Beep", { Key = "Tripmine" })                 -- derruba o anterior

	Com Looped, passe Key ou Cut: sem um dos dois nada limpa o clone depois.
]]
function MusicController:PlaySFX(name: string, options: SFXOptions?): Sound?
	local opts: SFXOptions = options or {}

	local template = self:GetSFX(name)
	if not template then
		warn(`[MusicController]: SFX "{name}" não existe em {SHARED_SOUNDS}.{SFX_FOLDER}.`)
		return nil
	end

	if opts.Key then
		self:StopSFX(opts.Key)
	end

	local sound = template:Clone()
	sound.Volume = template.Volume * (opts.Volume or 1) * self._SFXMaster
	sound.PlaybackSpeed = opts.Speed or template.PlaybackSpeed
	sound.Looped = if opts.Looped == nil then template.Looped else opts.Looped
	sound.Parent = opts.Parent or SoundService
	sound:Play()

	if opts.Key then
		self._ActiveSFX[opts.Key] = sound
	end

	local function cleanup()
		if opts.Key and self._ActiveSFX[opts.Key] == sound then
			self._ActiveSFX[opts.Key] = nil
		end
		if sound.Parent then
			sound:Destroy()
		end
	end

	if opts.Cut then
		task.delay(opts.Cut, function()
			if sound.Parent then
				sound:Stop()
			end
			cleanup()
		end)
	elseif not sound.Looped then
		sound.Ended:Once(cleanup)

		-- TimeLength só é confiável depois do som carregar; 0 significa que ainda
		-- não deu, então cai no tempo fixo.
		local lifetime = if sound.TimeLength > 0
			then sound.TimeLength / math.max(sound.PlaybackSpeed, 0.01) + 1
			else SFX_FALLBACK_LIFETIME
		task.delay(lifetime, cleanup)
	end

	return sound
end

-- Para o SFX que estiver vivo naquela Key (o de Looped mais longo, geralmente).
function MusicController:StopSFX(key: string)
	local sound = self._ActiveSFX[key]
	if not sound then
		return
	end

	self._ActiveSFX[key] = nil

	if sound.Parent then
		sound:Stop()
		sound:Destroy()
	end
end

-- Volume geral dos efeitos, separado do da música. Vale pros próximos :PlaySFX.
function MusicController:SetSFXVolume(scale: number)
	self._SFXMaster = math.max(scale, 0)
end

function MusicController:GetSFXVolume(): number
	return self._SFXMaster
end

--[[ ESTADO ]]

function MusicController:IsPlaying(name: string?): boolean
	local current = self.Current
	if not current then
		return false
	end

	if name and self.CurrentName ~= name then
		return false
	end

	return current.IsPlaying
end

function MusicController:GetCurrent(): (string?, Sound?)
	return self.CurrentName, self.Current
end

--[[ COMPATIBILIDADE / EVENTOS ]]

-- O nome antigo, mantido pra não quebrar quem já chamava.
function MusicController:playMusic(name: string)
	self:Play(name, { Fade = DEFAULT_FADE })
end

-- Chamado pelo LoadingController do Game quando a tela de load sai.
function MusicController:OnLoadingComplete()
	Framework:Fire("RequestMapMusic")
end

function MusicController:construct()
	-- Só o Game responde: o MapService devolve o nome do mapa carregado.
	Framework:Listen("PlayMapMusic", function(name: string)
		if type(name) ~= "string" then
			return
		end
		self:Transition(name)
	end)
end

function MusicController:start() end

function MusicController:init()
	self:construct()
end

return MusicController
