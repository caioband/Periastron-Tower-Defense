local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.DialogConfig

--[[
	O servidor mandando falar.

	A caixa de fala é do cliente (`DialogController`), e quem decide o que ela diz
	quase sempre também é — uma fala de NPC começa num toque, num portal, num botão.
	Este service existe para o outro caso: a fala que o **servidor** provoca, porque
	só ele sabe que ela é devida (um contrato completado, uma wave especial, o
	tutorial da primeira partida).

		DialogService:Send(players, {
			"A wave 8 traz [shake]NEVASCA[/shake].",
		}, { Auto = true })

	Fica em `common/` porque as duas places têm a caixa.
]]

local DialogService = {
	Services = {}
}

--[[ API ]]

export type SendOptions = {
	Auto : boolean?,
	Preset : string?,
	Speed : number?,

	-- Os botões da caixa, só na parte que é dado: texto e visibilidade. O que eles
	-- fazem ao serem clicados é do cliente, porque callback não atravessa a rede.
	Buttons : { { Text : string?, Visible : boolean? } }?,
}

--[=[
	Manda a conversa para quem estiver na lista. `lines` é uma frase ou a lista
	delas, com a marcação do `RichTextController` dentro.

	Sem `players`, fala para o servidor inteiro — é o que o Cmdr usa quando não
	recebe alvo nenhum.
]=]
function DialogService:Send(players : { Player }?, lines : string | { string }, options : SendOptions?)
	local list = if type(lines) == "table" then lines else { lines }
	if #list == 0 then return end

	for _, player in (players or Players:GetPlayers()) do
		Framework:Fire("DialogPlay", player, list, options)
	end
end

--[=[
	A fala de teste do `DialogConfig.Demo`, que é por onde o comando `dialog` do
	Cmdr entra. Vai com os dois botões acesos, para eles serem vistos sem ninguém
	escrever código.

	A cópia é para o config não ser alterado por quem passar um `options` com
	`Buttons` próprio — tabela de config é leitura, e quem a altera de longe estraga
	a sessão inteira.
]=]
function DialogService:SendDemo(players : { Player }?, options : SendOptions?)
	local merged : any = if options then table.clone(options) else {}
	if merged.Buttons == nil then
		merged.Buttons = Config.DemoButtons
	end

	self:Send(players, Config.Demo, merged)
end

--[[ CICLO DE VIDA ]]

function DialogService:construct()
	-- O identificador do evento nasce no servidor: sem este `Listen` vazio, o
	-- `Listen` do cliente ficaria dez segundos esperando um evento que ninguém
	-- registrou — e levaria junto o resto do `construct` dele.
	Framework:Listen("DialogPlay", function() end)
end

function DialogService:start()
end

function DialogService:init()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

return DialogService
