--[[
	Numbers of the lobby portals, shared because both sides need them: the client
	uses them to draw the panel and to decide when it is close enough to a portal,
	and the server uses the very same values to validate what the client asks for.

	The instance names below are the ones the map already carries inside every
	`Workspace.Map.Portals.Portal` model -- renaming one there means renaming it here.
]]

local module = {}

--[[ GRUPO ]]

module.MIN_PLAYERS = 1
module.MAX_PLAYERS = 4

--[[ COUNTDOWN ]]

-- Where the countdown starts while the group still has room.
module.COUNTDOWN = 40

-- What is left the moment the group fills up. When someone leaves afterwards the
-- countdown goes back to the long one, minus the time the group spent full -- so a
-- player joining and leaving on repeat cannot hold the portal open forever.
module.FULL_COUNTDOWN = 5

-- How long after the countdown the group is actually sent away. It is the room the
-- cutscene has to play out: the client flashes the screen white when its own scene
-- ends, and the teleport lands on top of that.
module.TELEPORT_DELAY = 5

-- Safety net: if nobody left by now the teleport did not happen, so the members are
-- put back outside the gate and the portal goes back to being free. Keep it well
-- above TELEPORT_DELAY -- reserving a server is a web call.
module.LAUNCH_RESET = 12

-- How fast the white frame goes from invisible to solid at the end of the cutscene.
module.FLASH_TIME = 0.12

-- How many scene frames before the end the flash starts, so the white covers the
-- cutscene instead of blinking after it. The scene runs at 60 fps.
module.FLASH_LEAD_FRAMES = 5

-- Where the group lands: the "Periastron TD: Main Game" place. Public id.
module.GAME_PLACE_ID = 109030368179494

-- The way back: the "Periastron Tower Defense" place, which is the lobby and the
-- start place of the universe. Used by the result screen's "back to lobby".
module.LOBBY_PLACE_ID = 132304466547289

--[[ MUNDO ]]

-- How close the player has to get to PortalEnterCFrame for the portal to answer.
-- Keep it under the distance between PortalEnterCFrame and PortalExitCFrame (10.5
-- studs as the map stands), otherwise leaving a group drops the player right back
-- inside the radius of the portal they just walked out of.
module.PROXIMITY_RADIUS = 8

-- The server accepts a request from slightly further out than the client acts on,
-- so a request sent while walking away does not get thrown out by a stud.
module.REQUEST_TOLERANCE = 1.5

-- Sideways gap between two members standing on the portal pad.
module.MEMBER_SPACING = 3

module.CUTSCENE_NAME = "EnterCutscene"

module.PORTALS_FOLDER = "Portals"
module.ENTER_NAME = "PortalEnterCFrame"
module.EXIT_NAME = "PortalExitCFrame"
module.GATE_NAME = "PlayerGate"
module.BILLBOARD_NAME = "Billboard"
module.CUTSCENE_REFERENCE_NAME = "CutsceneReferenceCFrame"

--[[ BOTÃO DE PLAY ]]

--[=[
	Onde o botão de jogar do HUD (`HUD.HUDMiddle.PlayButton`) larga o jogador: um
	marcador na entrada dos portais, procurado em profundidade sob `Workspace.Map` como
	os marcadores das lojas.

	**O portal mais perto fica a 25,3 studs daqui, portanto fora do `PROXIMITY_RADIUS`
	acima.** É de propósito: o botão leva o jogador até a área, e escolher um portal
	continua sendo andar até ele — é a chegada a pé que abre o painel de mapas, e o
	botão não decide mapa nenhum por ele. Ver `PlayButtonController:TeleportToPortals`.
]=]
module.PLAY_TELEPORT_PART_NAME = "PortalsTpPart"

-- Studs acima do topo do marcador, para o personagem pousar em pé em cima dele em vez
-- de meio enterrado. Mesma folga das lojas — o marcador é autorado igual aos dois
-- delas: mesma peça de 0,75 x 0,5 x 0,75, no ar acima do chão do pátio.
module.PLAY_TELEPORT_HEIGHT_OFFSET = 3

return module
