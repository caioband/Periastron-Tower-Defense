local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local CardConfig = SharedConfig.CardConfig
local CrateConfig = SharedConfig.CrateConfig
local RarityConfig = SharedConfig.RarityConfig
local IndexConfig = SharedConfig.IndexConfig

local RANDOM = Random.new()

local Framework = Me.new()

--[[ CONSTANTS ]]
local CRATES_FOLDER_NAME = "UnboxingCrates"
local TARGET_PART_NAME = "TargetPart"
local HEAD_PART_NAME = "Head"

--[[
	VFX do estouro e da aura, e o display que fica sobre a cabeça da unidade.

	O estouro é um Emit único que vive só o tempo pedido; a aura fica ligada
	enquanto a unidade estiver em cena, pintada com a cor da raridade dela.
]]
local CRATE_OPEN_VFX_NAME = "CrateOpen"
local UNIT_AURA_VFX_NAME = "CrateUnitAura"
local UNIT_DISPLAY_NAME = "UnitCrateDisplay"

-- Acima do maior Lifetime dos emissores do CrateOpen (o "Pixel smoke" vai até
-- 1s): destruir antes disso mataria as partículas ainda vivas no meio do voo.
local CRATE_OPEN_LIFETIME = 1

-- Quanto a caixa ainda fica no ar depois do estouro. Ela some por baixo do
-- efeito, em vez de o efeito aparecer sobre um lugar já vazio.
local CRATE_BURST_LEAD = 0.2

-- Quantas partículas cada emissor solta no estouro. Um emissor pode pedir outro
-- número com o atributo `EmitCount`, sem precisar mexer aqui.
local CRATE_OPEN_EMIT_COUNT = 16

-- Placement: the crate lands this far in front of the character, on whatever ground
-- the down ray finds. Everything else here is the "that spot is taken" recovery.
local SPAWN_DISTANCE = 7
local GROUND_RAY_UP = 8
local GROUND_RAY_DEPTH = 40
local GROUND_OFFSET = 0.05

-- Ground more than this far above/below the player's own floor is another platform,
-- not a spot to drop a crate on.
local MAX_GROUND_STEP = 8

-- The clearance box is the crate's own bounds, shrunk so it does not trip on the
-- floor it is standing on or on a wall it is merely touching.
local CLEARANCE_SHRINK = Vector3.new(0.3, 0.3, 0.3)

-- Ring sweep used when the ideal spot is blocked. Samples are ordered
-- forward-first (0, +45, -45, +90, ...) so the crate stays in view.
local FALLBACK_RINGS = { 3, 5, 7, 9 }
local FALLBACK_SAMPLES = 8

-- A ring that sweeps all the way behind lands right back on the player (radius equal
-- to SPAWN_DISTANCE at 180 degrees is exactly where they stand), so candidates that
-- close to them are dropped.
local MIN_PLAYER_DISTANCE = 4

-- Unboxings run side by side, so a new crate also has to keep its distance from the
-- ones already playing. Measured against the billboard (5 studs wide), not the crate
-- bounds -- two reels overlapping reads worse than two crates touching.
--
-- Vale contra as aberturas do lobby inteiro, e nao so contra as do jogador local:
-- duas pessoas lado a lado abrindo ao mesmo tempo sao o caso comum de sobreposicao.
local MIN_CRATE_SPACING = 6

-- Past this many at once the ring sweep runs out of spots that respect the spacing
-- above, and crates would start landing on top of each other. Conta as aberturas de
-- todo mundo; a do proprio jogador passa por cima do teto (ver :Open).
local MAX_ACTIVE_UNBOXINGS = 5

local CRATE_CAN_COLLIDE = false

-- The crate comes out of the player and flies to the spot the placement resolved,
-- growing on the way. A crate that evolves mid-unboxing does NOT replay this -- it
-- swaps in already grown and already there, so the upgrade reads as the same crate
-- changing rather than a new one dropping in.
local SPAWN_SCALE = 0.01
local SPAWN_TIME = 0.4
local SPAWN_GROW_INFO = TweenInfo.new(SPAWN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Quint rather than Back: an overshoot on the way in would push the crate through the
-- floor it is about to stand on.
local SPAWN_TRAVEL_INFO = TweenInfo.new(SPAWN_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

-- Opening: the crate winds up -- shrinking while it rattles for a couple of seconds --
-- and then bursts past its own size, which is the beat the unit appears on. The rattle
-- runs for as long as the windup tween, so its length is what sets the suspense.
local OPEN_WINDUP_SCALE = 0.85
local OPEN_WINDUP_INFO = TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local OPEN_SHAKE_OFFSET = 0.12
local OPEN_BURST_SCALE = 1.4
local OPEN_BURST_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Reel: REEL_LENGTH entries are cloned out of the authored pool, and the reel stops
-- with WINNER_INDEX centered on the Clipper. The tail after it is what keeps the
-- right half of the billboard filled once it lands.
local REEL_LENGTH = 36
local WINNER_TAIL = 4
local WINNER_INDEX = REEL_LENGTH - WINNER_TAIL

local SPIN_TIME = 4.25
local SPIN_INFO = TweenInfo.new(SPIN_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SETTLE_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

-- How far past the winner the reel rolls before settling back onto it, as a
-- fraction of one entry's width.
local OVERSHOOT_FRACTION = 0.08

-- Tocado cada vez que uma carta cruza o Clipper (SoundService, via MusicController).
local REEL_TICK_SOUND = "UIHover"

-- Beat between a reel landing on an upgrade and the next one starting, so the crate
-- evolving in front of the player reads.
local UPGRADE_PAUSE = 0.6

-- Reveal: the reel holds on the result for a beat, then the crate is destroyed and the
-- unit takes its place, spinning where it stood.
local REVEAL_DELAY = 0.6
local UNIT_SPIN_SPEED = math.rad(45)
local IDLE_ANIMATION_NAME = "Idle"

-- How long the revealed unit stays up before the whole session is cleaned up.
local RESULT_HOLD = 4

-- A unit de cada carta do carretel: uma imagem por cima da arte da carta, na
-- versao liberada ou na silhueta, conforme o Index do jogador (`CardConfig`).
local ENTRY_IMAGE_NAME = "UnitImage"

local UnboxingController = {
	Controllers = {
		-- O Index do jogador (quais units ele ja descobriu) mora no perfil.
		DataController = {},
		-- O tick de cada carta que passa pelo Clipper.
		MusicController = {},
	},

	--[[
		Toda abertura do servidor toca em todas as telas, então os sinais são sobre a
		caixa de qualquer um: `owner` é quem abriu, e é por ele que um ouvinte separa
		a abertura do jogador local das que ele está só assistindo.
	]]
	Signals = {
		-- (result : UnboxingResult, crate : Model, owner : Player)
		UnboxingStarted = Signal.new(),
		-- (result : UnboxingResult, from : string, to : string, crate : Model, owner : Player)
		CrateUpgraded = Signal.new(),
		-- (result : UnboxingResult, entry : GuiObject, crate : Model, owner : Player)
		UnboxingFinished = Signal.new(),
		-- (result : UnboxingResult, unit : Model, owner : Player)
		UnitRevealed = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	Both VFX parts are authored unanchored and colliding, which is fine sitting in
	ReplicatedStorage but not in the world: a clone would fall, and shove whatever
	it touched on the way. Purely decorative, so it also stops answering queries.
]=]
local function prepareVFXPart(part : BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
end

local function flatten(vector : Vector3, fallback : Vector3) : Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 1e-3 then
		return fallback
	end

	return flat.Unit
end

--[=[
	Horizontal center of a GuiObject, in its parent's scale space.
]=]
local function centerOf(gui : GuiObject) : number
	return gui.Position.X.Scale + (0.5 - gui.AnchorPoint.X) * gui.Size.X.Scale
end

--[=[
	Candidate positions in try order: the ideal spot first, then rings of samples
	around it, each ring sweeping outwards from straight ahead.
]=]
local function buildCandidates(idealPosition : Vector3, forward : Vector3) : { Vector3 }
	local candidates = { idealPosition }

	for _, radius in FALLBACK_RINGS do
		for step = 0, FALLBACK_SAMPLES - 1 do
			local sign = (step % 2 == 0) and 1 or -1
			local angle = sign * math.ceil(step / 2) * (math.pi * 2 / FALLBACK_SAMPLES)
			local direction = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(forward)

			table.insert(candidates, idealPosition + direction * radius)
		end
	end

	return candidates
end

--[=[
	A raiz do personagem de quem abriu a caixa -- não a do jogador local.

	É dela que sai a caixa e é na frente dela que ela pousa, em todas as telas: quem
	assiste vê a caixa nascer no dono, e não nos próprios pés.
]=]
function UnboxingController:_getRoot(player : Player) : BasePart?
	local character = player and player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--[=[
	True when the spot is too close to an unboxing that is already playing.

	The spawned crates are non-queryable on purpose (they must not get in the way of
	anything else that raycasts the world), so the spatial query below cannot see them
	-- the sessions themselves are what tracks the occupied spots.
]=]
function UnboxingController:_isSpotTaken(position : Vector3, extents : Vector3) : boolean
	for _, session in self.Sessions do
		if not session.Position then
			continue
		end

		local horizontal = (position - session.Position) * Vector3.new(1, 0, 1)
		if horizontal.Magnitude < MIN_CRATE_SPACING and math.abs(position.Y - session.Position.Y) < extents.Y then
			return true
		end
	end

	return false
end

--[=[
	Raycast params that ignore every character and the crates we spawned ourselves,
	which are handled by _isSpotTaken instead.
]=]
function UnboxingController:_buildFilter() : { Instance }
	local filter = { self.CratesFolder }

	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(filter, player.Character)
		end
	end

	return filter
end

local function findGround(position : Vector3, params : RaycastParams) : RaycastResult?
	local origin = position + Vector3.yAxis * GROUND_RAY_UP
	local direction = Vector3.yAxis * -(GROUND_RAY_UP + GROUND_RAY_DEPTH)

	return workspace:Raycast(origin, direction, params)
end

--[=[
	Finds where the crate goes: in front of the player, standing on the ground, facing
	back at them. The ideal spot is used whenever its volume is empty; otherwise the
	ring sweep looks for a nearby spot that is.
]=]
function UnboxingController:_resolvePlacement(rootPart : BasePart, extents : Vector3) : CFrame
	local forward = flatten(rootPart.CFrame.LookVector, Vector3.zAxis * -1)
	local idealPosition = rootPart.Position + forward * SPAWN_DISTANCE

	local filter = self:_buildFilter()

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = filter
	rayParams.IgnoreWater = true
	rayParams.RespectCanCollide = true

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = filter
	overlapParams.RespectCanCollide = true

	local playerGround = findGround(rootPart.Position, rayParams)
	local referenceY = playerGround and playerGround.Position.Y or rootPart.Position.Y

	local clearanceSize = extents - CLEARANCE_SHRINK
	local firstGrounded : CFrame? = nil

	for _, candidate in buildCandidates(idealPosition, forward) do
		-- The ray is vertical, so the candidate already has the final XZ.
		if ((candidate - rootPart.Position) * Vector3.new(1, 0, 1)).Magnitude < MIN_PLAYER_DISTANCE then
			continue
		end

		local ground = findGround(candidate, rayParams)
		if not ground then
			continue
		end

		if math.abs(ground.Position.Y - referenceY) > MAX_GROUND_STEP then
			continue
		end

		local position = ground.Position + Vector3.yAxis * (extents.Y * 0.5 + GROUND_OFFSET)

		-- Not even as a fallback: landing on another unboxing is worse than clipping
		-- into the scenery.
		if self:_isSpotTaken(position, extents) then
			continue
		end

		local towardPlayer = flatten(rootPart.Position - position, -forward)

		-- The crate models are authored facing +X (that is where the latch is), so the
		-- right vector -- not the look vector -- is what points at the player.
		local cframe = CFrame.fromMatrix(position, towardPlayer, Vector3.yAxis)

		firstGrounded = firstGrounded or cframe

		if #workspace:GetPartBoundsInBox(cframe, clearanceSize, overlapParams) == 0 then
			return cframe
		end
	end

	-- Everything around is occupied: prefer a spot that at least stands on the floor.
	if firstGrounded then
		return firstGrounded
	end

	-- No ground anywhere nearby either: fall back to the player's own feet height.
	local humanoid = rootPart.Parent and rootPart.Parent:FindFirstChildWhichIsA("Humanoid")
	local feetY = rootPart.Position.Y - rootPart.Size.Y * 0.5 - (humanoid and humanoid.HipHeight or 0)
	local position = Vector3.new(idealPosition.X, feetY + extents.Y * 0.5 + GROUND_OFFSET, idealPosition.Z)

	return CFrame.fromMatrix(position, -forward, Vector3.yAxis)
end

--[=[
	Clones the crate model of a rarity and stands it up in the world.

	`cframe` skips the placement search and drops it exactly there -- that is how a
	crate evolves without moving.
]=]
function UnboxingController:_spawnCrate(session, rarity : string, cframe : CFrame?) : Model?
	local modelName = CrateConfig.getModelName(rarity)
	local template = modelName and self.CrateModels:FindFirstChild(modelName)
	if not template or not template:IsA("Model") then
		warn(string.format("[UnboxingController]: No crate model named %q in Assets.CratesModel.", tostring(modelName)))
		return nil
	end

	local rootPart = if cframe then nil else self:_getRoot(session.Owner)
	if not cframe and not rootPart then
		return nil
	end

	local crate = template:Clone()
	for _, descendant in crate:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = CRATE_CAN_COLLIDE
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	local _, extents = crate:GetBoundingBox()
	crate:PivotTo(cframe or self:_resolvePlacement(rootPart :: BasePart, extents))

	crate.Parent = self.CratesFolder
	session.Maid:GiveTask(crate)

	return crate
end

--[=[
	Models cannot be handed to TweenService, so a value object carries the easing and
	drives the model through `apply`.
]=]
local function tweenDriver(valueClass : string, startValue : any, goal : any, info : TweenInfo, apply : (any) -> (), maid) : Tween
	local driver = Instance.new(valueClass)
	driver.Value = startValue

	local connection = driver:GetPropertyChangedSignal("Value"):Connect(function()
		apply(driver.Value)
	end)

	local function stop()
		connection:Disconnect()
		driver:Destroy()
	end

	local tween = TweenService:Create(driver, info, { Value = goal })
	tween.Completed:Once(stop)

	maid:GiveTask(function()
		tween:Cancel()
		stop()
	end)

	tween:Play()
	return tween
end

function UnboxingController:_tweenScale(model : Model, info : TweenInfo, goal : number, maid) : Tween
	return tweenDriver("NumberValue", model:GetScale(), goal, info, function(value : number)
		if model.Parent then
			-- Back easing undershoots, and ScaleTo will not take zero or less.
			model:ScaleTo(math.max(value, SPAWN_SCALE))
		end
	end, maid)
end

function UnboxingController:_tweenPivot(model : Model, info : TweenInfo, goal : CFrame, maid) : Tween
	return tweenDriver("CFrameValue", model:GetPivot(), goal, info, function(value : CFrame)
		if model.Parent then
			model:PivotTo(value)
		end
	end, maid)
end

--[=[
	The crate opening: it shrinks and rattles in place, then bursts past its own size.
	`onComplete` is where the unit takes over.
]=]
function UnboxingController:_playOpenAnimation(session, onComplete : () -> ())
	local crate = session.Crate
	if not crate or not crate.Parent then
		onComplete()
		return
	end

	local baseCFrame = session.CFrame

	local shakeMaid = Maid.new()
	session.Maid:GiveTask(shakeMaid)

	shakeMaid:GiveTask(RunService.RenderStepped:Connect(function()
		if not crate.Parent then
			return
		end

		local offset = Vector3.new(
			RANDOM:NextNumber(-1, 1),
			RANDOM:NextNumber(-1, 1),
			RANDOM:NextNumber(-1, 1)
		) * OPEN_SHAKE_OFFSET

		crate:PivotTo(baseCFrame + offset)
	end))

	local windup = self:_tweenScale(crate, OPEN_WINDUP_INFO, OPEN_WINDUP_SCALE, session.Maid)
	windup.Completed:Once(function(state : Enum.PlaybackState)
		shakeMaid:DoCleaning()

		if session.Closed or state ~= Enum.PlaybackState.Completed or not crate.Parent then
			return
		end

		crate:PivotTo(baseCFrame)

		-- Junto com o início do estufão, não no fim dele: o efeito é o estouro.
		self:_playCrateBurstVFX(session)

		self:_tweenScale(crate, OPEN_BURST_INFO, OPEN_BURST_SCALE, session.Maid)

		--[[
			O prazo conta do estouro, não do fim do estufão: é o estouro que a
			caixa tem que sobreviver. O tween dura menos que `CRATE_BURST_LEAD`,
			então ele termina de qualquer jeito antes daqui — e se a sessão fechar
			no meio, o `Closed` segura.
		]]
		task.delay(CRATE_BURST_LEAD, function()
			if session.Closed then
				return
			end

			onComplete()
		end)
	end)
end

--[=[
	O estouro da caixa: um Emit único de tudo que houver dentro do CrateOpen,
	no CFrame da caixa.

	A part vai para a pasta de unboxings, ao lado da caixa e não dentro dela: a
	caixa é destruída logo depois, e levaria o efeito junto antes da hora. Fica
	solta no CFrame dela, então continua no lugar certo quando a caixa some.
]=]
function UnboxingController:_playCrateBurstVFX(session)
	local crate = session.Crate
	if not crate or not crate.Parent then
		return nil
	end

	local vfx = self.CrateOpenVFX:Clone()
	prepareVFXPart(vfx)
	vfx.CFrame = crate:GetPivot()
	vfx.Parent = self.CratesFolder

	for _, emitter in vfx:GetDescendants() do
		if emitter:IsA("ParticleEmitter") then
			emitter:Emit(emitter:GetAttribute("EmitCount") or CRATE_OPEN_EMIT_COUNT)
		end
	end

	-- No maid também: fechar a sessão antes do prazo não pode deixar o efeito para trás.
	session.Maid:GiveTask(vfx)
	task.delay(CRATE_OPEN_LIFETIME, function()
		vfx:Destroy()
	end)

	return vfx
end

--[=[
	A aura que fica na unidade revelada, na cor da raridade dela.

	Entra como filha da unidade de propósito: o giro do reveal é um `PivotTo` no
	modelo inteiro, então a aura acompanha sem precisar de código próprio, e some
	junto quando a unidade some.
]=]
function UnboxingController:_attachUnitAura(unit : Model, rarity : string?) : BasePart?
	local rootPart = unit.PrimaryPart or unit:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		warn(string.format("[UnboxingController]: %s has no root part for the aura VFX.", unit.Name))
		return nil
	end

	local aura = self.UnitAuraVFX:Clone()
	prepareVFXPart(aura)
	aura.CFrame = rootPart.CFrame

	local color = RarityConfig.getColor(rarity)
	for _, emitter in aura:GetDescendants() do
		if emitter:IsA("ParticleEmitter") then
			emitter.Enabled = true
			if color then
				emitter.Color = ColorSequence.new(color)
			end
		end
	end

	aura.Parent = unit

	return aura
end

--[=[
	O display sobre a cabeça da unidade revelada.

	O template é um Attachment, então a cabeça é pai direto dele e o BillboardGui
	de dentro se ancora sozinho. Os dois rótulos são preenchidos aqui — é para isso
	que eles existem.
]=]
function UnboxingController:_attachUnitDisplay(unit : Model, unitName : string, rarity : string?) : Attachment?
	local head = unit:FindFirstChild(HEAD_PART_NAME)
	if not head or not head:IsA("BasePart") then
		warn(string.format("[UnboxingController]: %s has no %s for the crate display.", unit.Name, HEAD_PART_NAME))
		return nil
	end

	local display = self.UnitDisplayTemplate:Clone()

	local billboard = display:FindFirstChildWhichIsA("BillboardGui")
	if billboard then
		local nameLabel = billboard:FindFirstChild("UnitName")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = unitName
		end

		local rarityLabel = billboard:FindFirstChild("Rarity")
		if rarityLabel and rarityLabel:IsA("TextLabel") then
			local tier = rarity and RarityConfig.TIERS[rarity]
			rarityLabel.Text = tier and tier.DisplayName or (rarity or "")

			local color = RarityConfig.getColor(rarity)
			local stroke = rarityLabel:FindFirstChildOfClass("UIStroke")
			if stroke and color then
				stroke.Color = color
			end
		end
	end

	display.Parent = head

	return display
end

--[=[
	Evolves the crate: same spot, same billboard, heavier model.
]=]
function UnboxingController:_swapCrate(session, crateRarity : string) : Model?
	local crate = self:_spawnCrate(session, crateRarity, session.CFrame)
	if not crate then
		return nil
	end

	local targetPart = crate:FindFirstChild(TARGET_PART_NAME)
	if not targetPart or not targetPart:IsA("BasePart") then
		warn(string.format("[UnboxingController]: %s has no %s.", crate.Name, TARGET_PART_NAME))
		crate:Destroy()
		return nil
	end

	-- The reel lives under the attachment, so moving it over keeps the spin going.
	session.Attachment.Parent = targetPart
	session.Crate:Destroy()
	session.Crate = crate

	return crate
end

--[=[
	Closes the unboxing on the prize: the crate is destroyed so it is not standing in
	the way, and the unit takes its spot, spinning and playing its idle.

	The crate only comes down once the unit is built and ready to be parented, so a
	missing model never leaves the player looking at nothing.
]=]
function UnboxingController:_revealUnit(session, unitName : string) : Model?
	local template = self.UnitModels:FindFirstChild(unitName)
	if not template or not template:IsA("Model") then
		warn(string.format("[UnboxingController]: No unit model named %q in Assets.Units.", tostring(unitName)))
		return nil
	end

	local unit = template:Clone()

	for _, descendant in unit:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	-- Only the root is anchored, exactly how the models are authored: the limbs hang
	-- off it through their Motor6Ds, which is what lets the idle drive them while the
	-- model itself stays put.
	local rootPart = unit.PrimaryPart or unit:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		rootPart.Anchored = true
	end

	-- Stand it where the crate was: same spot, feet on the same ground, facing the
	-- player the way the crate did (the crate faces them with its +X).
	local boundsCFrame, extents = unit:GetBoundingBox()
	local feetOffset = unit:GetPivot().Position.Y - (boundsCFrame.Position.Y - extents.Y * 0.5)

	local crateCFrame = session.CFrame
	local position = Vector3.new(
		crateCFrame.Position.X,
		session.GroundY + feetOffset,
		crateCFrame.Position.Z
	)

	local facing = CFrame.lookAt(position, position + crateCFrame.RightVector)
	unit:PivotTo(facing)

	if session.Crate then
		session.Crate:Destroy()
		session.Crate = nil
	end

	unit.Parent = self.CratesFolder
	session.Unit = unit
	session.Maid:GiveTask(unit)

	--[[
		Os modelos das unidades sao rigs de Motor6D sem Humanoid nenhum -- quem toca
		as faixas delas na partida e um `AnimationController`, criado na hora pela
		classe `Unit`. Aqui e a mesma coisa: procurar um Humanoid so achava nada e
		caia no `warn`, deixando a unidade parada no fim do unboxing.

		A faixa so entra depois do `unit.Parent`: um Animator fora do DataModel nao e
		avaliado, entao tocar antes de a unidade estar em cena nao mexia nada.
	]]
	local idle = unit:FindFirstChild(IDLE_ANIMATION_NAME)

	if idle and idle:IsA("Animation") then
		local animationController = unit:FindFirstChildWhichIsA("AnimationController")
			or unit:FindFirstChildWhichIsA("Humanoid")

		if not animationController then
			animationController = Instance.new("AnimationController")
			animationController.Parent = unit
		end

		local animator = animationController:FindFirstChildWhichIsA("Animator") or Instance.new("Animator")
		animator.Parent = animationController

		local track = animator:LoadAnimation(idle)
		track.Looped = true
		track:Play()

		session.Maid:GiveTask(function()
			track:Stop()
		end)
	else
		warn(string.format("[UnboxingController]: %s has no %s animation.", unitName, IDLE_ANIMATION_NAME))
	end

	-- A raridade sai do próprio catálogo da unidade, não do resultado do roll: é a
	-- raridade dela que a aura e o display anunciam.
	local stats = SharedConfig.UnitStats[unitName]
	local rarity = RarityConfig.resolve(stats and stats.Rarity)
	if not rarity then
		warn(string.format("[UnboxingController]: %s has no valid Rarity in UnitStats.", unitName))
	end

	self:_attachUnitAura(unit, rarity)

	-- A aura e o giro sao a unidade aparecendo, e isso todo mundo ve. O nome e a
	-- raridade dela sao o resultado, e o resultado e de quem abriu.
	if session.IsOwner then
		self:_attachUnitDisplay(unit, unitName, rarity)
	end

	local spin = 0
	session.Maid:GiveTask(RunService.RenderStepped:Connect(function(deltaTime : number)
		spin += deltaTime * UNIT_SPIN_SPEED
		unit:PivotTo(facing * CFrame.Angles(0, spin, 0))
	end))

	return unit
end

--[=[
	Clones the authored attachment into the crate's TargetPart. The attachment already
	carries its own offset, so it lands above the crate on its own.
]=]
function UnboxingController:_attachBillboard(crate : Model, sessionMaid) : Attachment?
	local targetPart = crate:FindFirstChild(TARGET_PART_NAME)
	if not targetPart or not targetPart:IsA("BasePart") then
		warn(string.format("[UnboxingController]: %s has no %s.", crate.Name, TARGET_PART_NAME))
		return nil
	end

	local attachment = self.AttachmentTemplate:Clone()
	attachment.Parent = targetPart
	sessionMaid:GiveTask(attachment)

	return attachment
end

--[[ UNITS NO CARRETEL ]]

--[=[
	O que o jogador ja descobriu em `Index.Units`, direto da replica.

	Perfil que ainda nao chegou vale como "nada descoberto" -- o mesmo acordo do
	`IndexConfig`. Na pratica isso nao acontece na propria caixa (para abrir uma o
	perfil ja carregou), mas o carretel de quem esta so assistindo passa por aqui
	tambem.
]=]
function UnboxingController:_discoveredUnits() : { [string]: boolean }
	local dataController = self.Controllers.DataController
	if not dataController or not dataController.GetReplica then return {} end

	local ok, replica = pcall(function()
		return dataController:GetReplica()
	end)

	if not ok or not replica then return {} end

	return IndexConfig.entriesOf(replica.Data, "Units")
end

--[=[
	A unit da carta, por cima da arte dela.

	Duas artes por unit no `CardConfig`: a liberada e a silhueta. Qual entra e o
	Index do jogador que diz -- e como o par vem pronto do config, "trancada" aqui
	nao passa de escolher o outro id.

	Unit sem par no config nao ganha imagem: a carta fica so com a moldura na cor da
	raridade, que e exatamente como o carretel era antes de existir arte de unit.
]=]
function UnboxingController:_createEntryImage(entry : GuiObject, unitName : string, discovered : boolean)
	local image = CardConfig.GetIndexImage(unitName, discovered)
	if not image then
		return nil
	end

	local label = Instance.new("ImageLabel")
	label.Name = ENTRY_IMAGE_NAME
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Image = image

	-- A carta nao e quadrada e a arte da unit e: `Fit` deixa a proporcao dela em
	-- paz, encaixando pelo lado que aperta primeiro em vez de esticar.
	label.ScaleType = Enum.ScaleType.Fit

	-- Pixel art: sem o `Pixelated` o filtro borra a arte ao escalar, e a carta do
	-- carretel e pequena -- e o resto da UI do jogo ja usa este modo.
	label.ResampleMode = Enum.ResamplerMode.Pixelated
	label.ZIndex = entry.ZIndex + 1
	label.Parent = entry

	return label
end

--[=[
	A face is what one reel entry shows: either a unit rarity, or the crate upgrading.

	`Upgrade` carries the crate it becomes -- the same thing the server rolls -- so an
	entry can be read back off the reel.

	`Unit` e quem aparece em 3D na carta. No filler e uma unit qualquer da raridade
	sorteada; na carta premiada e exatamente a que o servidor deu. Face de upgrade
	nao tem unit -- ali a carta e a caixa evoluindo, e nao uma unit.
]=]
export type ReelFace = {
	Rarity : string?,
	Upgrade : string?,
	Unit : string?,
}

--[=[
	Uma unit qualquer da raridade, para a carta de filler mostrar.

	As units de cada tier saem do proprio `UnitStats` (`getUnitsOfRarity`), que e o
	que o servidor tambem usa para sortear o premio -- entao o carretel mostra o
	mesmo elenco de onde o resultado sai. Raridade sem unit nenhuma devolve nil, e a
	carta fica so com a arte e a cor do tier.
]=]
local function rollFillerUnit(rarity : string) : string?
	local units = RarityConfig.getUnitsOfRarity(rarity)

	if not units or #units == 0 then
		return nil
	end

	return units[RANDOM:NextInteger(1, #units)]
end

--[=[
	Picks a face to show as filler, weighted by RarityConfig.ReelWeight and, for the
	upgrade card, CrateConfig.UPGRADE_REEL_WEIGHT.

	Business rule: a crate only ever shows the upgrade it can actually give, so a
	Legendary crate (which upgrades into nothing) never shows one.

	Filler only -- what the player actually gets was rolled by the server, out of the
	crate pool, and lands on WINNER_INDEX.
]=]
local function rollFillerFace(crateRarity : string) : ReelFace
	local upgradesTo = CrateConfig.getNextRarity(crateRarity)
	local upgradeWeight = upgradesTo and CrateConfig.UPGRADE_REEL_WEIGHT or 0

	local total = upgradeWeight
	for _, rarity in RarityConfig.ORDER do
		total += RarityConfig.TIERS[rarity].ReelWeight or 0
	end

	if total <= 0 then
		return { Rarity = RarityConfig.ORDER[1] }
	end

	local roll = RANDOM:NextNumber(0, total)
	local cumulative = upgradeWeight

	if roll < cumulative then
		return { Upgrade = upgradesTo }
	end

	for _, rarity in RarityConfig.ORDER do
		cumulative += RarityConfig.TIERS[rarity].ReelWeight or 0
		if roll < cumulative then
			return { Rarity = rarity, Unit = rollFillerUnit(rarity) }
		end
	end

	local fallback = RarityConfig.ORDER[1]
	return { Rarity = fallback, Unit = rollFillerUnit(fallback) }
end

--[=[
	Rebuilds the ScrollingFrame contents into a long reel for `crateRarity`, landing on
	`winnerFace`. The entries the designer left in the ScrollingFrame are the art pool
	for rarities; the upgrade cards come from UpgradeCrateUnboxingTemplates.

	A pool entry named after a rarity is used as the template for it, so the pool can
	carry per-tier art later; anything else is interchangeable art and the tint does
	the work. The upgrade cards are authored with their own colours, so those are
	left alone.

	Returns a small handle with everything the spin needs: the frame to move, the
	entries, and a mapping from entry index to the frame position that centers it
	on the Clipper.
]=]
function UnboxingController:_buildReel(session, crateRarity : string, winnerFace : ReelFace)
	local billboard = session.Attachment:FindFirstChildWhichIsA("BillboardGui")
	local frame = billboard and billboard:FindFirstChild("Frame")
	local scrollingFrame = frame and frame:FindFirstChild("ScrollingFrame")

	if not scrollingFrame or not scrollingFrame:IsA("ScrollingFrame") then
		warn("[UnboxingController]: UnboxingAttachment.BillboardGui.Frame.ScrollingFrame is missing.")
		return nil
	end

	-- Captured once per session: on a later stage the ScrollingFrame holds the entries
	-- the previous spin left behind, not the art the designer authored.
	local pool = session.Pool

	if not pool then
		pool = {}
		for _, child in scrollingFrame:GetChildren() do
			if child:IsA("GuiObject") then
				table.insert(pool, child)

				-- Out of the layout, but kept alive as a template for the reel entries.
				child.Parent = nil
				session.Maid:GiveTask(child)
			end
		end

		session.Pool = pool
	else
		for _, child in scrollingFrame:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	if #pool == 0 then
		warn("[UnboxingController]: ScrollingFrame has no entries to build the reel from.")
		return nil
	end

	local layout = scrollingFrame:FindFirstChildWhichIsA("UIListLayout")
	local clipper = frame:FindFirstChild("Clipper")

	-- Entry widths are authored in scale, relative to the ScrollingFrame, and the list
	-- layout padding is what actually spaces them apart.
	local entryWidth = pool[1].Size.X.Scale
	local step = entryWidth + (layout and layout.Padding.Scale or 0)

	local frameWidth = scrollingFrame.Size.X.Scale
	local anchorX = scrollingFrame.AnchorPoint.X
	local targetCenter = clipper and clipper:IsA("GuiObject") and centerOf(clipper) or 0.5

	-- An entry the designer named after a rarity becomes the template for that tier.
	local templates = {}
	for _, entry in pool do
		local named = RarityConfig.resolve(entry.Name)
		if named then
			templates[named] = entry
		end
	end

	local entries = table.create(REEL_LENGTH)
	for index = 1, REEL_LENGTH do
		local face = index == WINNER_INDEX and winnerFace or rollFillerFace(crateRarity)
		local entry

		if face.Upgrade then
			-- The upgrade cards are authored per destination crate, colour included.
			local template = self.UpgradeTemplates:FindFirstChild(face.Upgrade)
			entry = template and template:Clone()
		end

		if not entry then
			local rarity = face.Rarity or RarityConfig.ORDER[1]
			entry = (templates[rarity] or pool[RANDOM:NextInteger(1, #pool)]):Clone()

			local color = RarityConfig.getColor(rarity)
			if color and entry:IsA("ImageLabel") then
				entry.ImageColor3 = color
			elseif color then
				entry.BackgroundColor3 = color
			end
		end

		entry.Name = string.format("ReelEntry_%02d", index)
		entry.LayoutOrder = index
		entry.Visible = true

		-- Keep the sizing of the pool: an upgrade card authored a hair off would
		-- otherwise break the step the spin maths is built on.
		entry.Size = pool[1].Size

		entry:SetAttribute("Rarity", face.Rarity)
		entry:SetAttribute("Upgrade", face.Upgrade)
		entry:SetAttribute("Unit", face.Unit)
		entry.Parent = scrollingFrame

		-- So na tela de quem abriu: nas outras o billboard fica desligado o giro
		-- inteiro, e o Roblox nao desenha nada dele.
		if face.Unit and session.IsOwner then
			self:_createEntryImage(entry, face.Unit, session.Discovered[face.Unit] == true)
		end

		entries[index] = entry
	end

	--[=[
		Frame position (scale) that puts entry `index` right under the Clipper.
	]=]
	local function positionFor(index : number) : number
		local offset = ((index - 1) * step + entryWidth * 0.5) * frameWidth
		return targetCenter + anchorX * frameWidth - offset
	end

	--[=[
		O inverso de `positionFor`: qual carta esta sob o Clipper com o frame em `x`.
		Troca na borda entre duas cartas, que e o instante em que o tick soa.
	]=]
	local function indexAt(x : number) : number
		local offset = (targetCenter + anchorX * frameWidth - x) / frameWidth
		return math.floor(offset / step) + 1
	end

	return {
		ScrollingFrame = scrollingFrame,
		Entries = entries,
		EntryWidth = entryWidth * frameWidth,
		PositionFor = positionFor,
		IndexAt = indexAt,
	}
end

--[=[
	O tick do carretel: um som por carta que cruza o Clipper, do giro ao assentar.

	Uma vez por frame no maximo -- no comeco do giro passam varias cartas num frame
	so, e empilhar um som por carta viraria ruido. So na tela de quem abriu: nas
	outras o carretel gira atras de um billboard desligado.
]=]
function UnboxingController:_trackReelTicks(reel, maid)
	local scrollingFrame = reel.ScrollingFrame
	local lastIndex = reel.IndexAt(scrollingFrame.Position.X.Scale)

	local connection = RunService.RenderStepped:Connect(function()
		local index = reel.IndexAt(scrollingFrame.Position.X.Scale)
		if index == lastIndex then
			return
		end

		lastIndex = index

		local music = self.Controllers.MusicController
		if music then
			music:PlaySFX(REEL_TICK_SOUND)
		end
	end)

	maid:GiveTask(connection)
	return connection
end

function UnboxingController:_spin(reel, sessionMaid, onFinished : (GuiObject) -> (), withTicks : boolean?)
	local scrollingFrame = reel.ScrollingFrame
	local basePosition = scrollingFrame.Position

	local function positionAt(x : number) : UDim2
		return UDim2.new(x, 0, basePosition.Y.Scale, basePosition.Y.Offset)
	end

	local winnerIndex = math.clamp(WINNER_INDEX, 1, #reel.Entries)
	local winnerEntry = reel.Entries[winnerIndex]
	local winnerPosition = reel.PositionFor(winnerIndex)

	scrollingFrame.Position = positionAt(reel.PositionFor(1))

	-- Roll slightly past the winner, then settle back onto it.
	local spin = TweenService:Create(scrollingFrame, SPIN_INFO, {
		Position = positionAt(winnerPosition - reel.EntryWidth * OVERSHOOT_FRACTION),
	})

	local settle = TweenService:Create(scrollingFrame, SETTLE_INFO, {
		Position = positionAt(winnerPosition),
	})

	sessionMaid:GiveTask(function()
		spin:Cancel()
		settle:Cancel()
	end)

	spin.Completed:Once(function(state : Enum.PlaybackState)
		if state ~= Enum.PlaybackState.Completed then
			return
		end

		settle:Play()
	end)

	-- Comeca depois do reposicionamento na primeira carta, para o salto ate ela
	-- nao contar como carta passando.
	local ticks = withTicks and self:_trackReelTicks(reel, sessionMaid)

	settle.Completed:Once(function(state : Enum.PlaybackState)
		if ticks then
			ticks:Disconnect()
		end

		if state ~= Enum.PlaybackState.Completed then
			return
		end

		onFinished(winnerEntry)
	end)

	spin:Play()

	return winnerEntry
end

--[=[
	One unboxing = one session: its own maid, the spot it took, and quem abriu.

	`IsOwner` e o que decide o que essa tela mostra: quem abriu ve o carretel e o nome
	da unidade, quem esta assistindo ve so a caixa, o estouro e o premio.
]=]
function UnboxingController:_openSession(owner : Player)
	self.SessionCount += 1

	local session = {
		Id = self.SessionCount,
		Maid = Maid.new(),
		Position = nil :: Vector3?,
		Closed = false,
		Owner = owner,
		IsOwner = owner == Players.LocalPlayer,

		--[[
			O Index do jogador local, lido uma vez: e ele que decide quais units
			aparecem em silhueta. Uma leitura por sessao, e nao por carta -- a caixa
			aberta agora nao muda o que ele ja descobriu no meio do giro (a unit
			premiada e escrita no perfil pelo servidor, e o carretel dela ja esta
			montado).
		]]
		Discovered = {},
	}

	if session.IsOwner then
		session.Discovered = self:_discoveredUnits()
	end

	table.insert(self.Sessions, session)

	-- Hanging the session maid on the controller maid keeps everything cleaned up if
	-- the controller itself goes away mid-roll.
	self.Maid["Session_" .. session.Id] = session.Maid

	session.Maid:GiveTask(function()
		local index = table.find(self.Sessions, session)
		if index then
			table.remove(self.Sessions, index)
		end
	end)

	return session
end

function UnboxingController:_closeSession(session)
	if session.Closed then
		return
	end

	session.Closed = true
	self.Maid["Session_" .. session.Id] = nil
end

--[[ EXTERNAL ]]

export type UnboxingResult = {
	Crate : string,
	Upgrades : { string },
	Rarity : string,
	Unit : string?,
}

--[=[
	Plays one spin of a session, then hands over to the next stage.

	A stage that lands on an upgrade evolves the crate and lets the pool of the crate
	it became take over -- that is the "a caixa pode evoluir" rule, played out one
	reel at a time. The last stage is always the reward.
]=]
function UnboxingController:_playStage(session, result : UnboxingResult, stages, index : number)
	local stage = stages[index]
	if session.Closed or not stage then
		return
	end

	local reel = self:_buildReel(session, stage.Crate, stage.Face)
	if not reel then
		self:_closeSession(session)
		return
	end

	self:_spin(reel, session.Maid, function(entry : GuiObject)
		if session.Closed then
			return
		end

		if not stage.Face.Upgrade then
			self.Signals.UnboxingFinished:Fire(result, entry, session.Crate, session.Owner)

			-- A beat on the landed reel, the crate cracks open, and the unit takes over.
			task.delay(REVEAL_DELAY, function()
				if session.Closed then
					return
				end

				self:_playOpenAnimation(session, function()
					if session.Closed then
						return
					end

					local unit = result.Unit and self:_revealUnit(session, result.Unit)
					if unit then
						self.Signals.UnitRevealed:Fire(result, unit, session.Owner)
					end

					task.delay(RESULT_HOLD, function()
						self:_closeSession(session)
					end)
				end)
			end)

			return
		end

		task.delay(UPGRADE_PAUSE, function()
			if session.Closed then
				return
			end

			if not self:_swapCrate(session, stage.Face.Upgrade) then
				self:_closeSession(session)
				return
			end

			self.Signals.CrateUpgraded:Fire(result, stage.Crate, stage.Face.Upgrade, session.Crate, session.Owner)
			self:_playStage(session, result, stages, index + 1)
		end)
	end, session.IsOwner)
end

--[=[
	Spawns the crate in front of `owner` and rolls the unboxing reel on top of it,
	landing on `result.Rarity`.

	`result` is what CrateService rolled: the odds live on the server, so this only
	plays what it is told. Unboxings stack -- calling this again while others are
	still rolling starts another one beside them, up to MAX_ACTIVE_UNBOXINGS.

	`owner` e quem abriu a caixa, e o servidor manda a mesma abertura para todo mundo:
	numa tela que nao e a dele, isso aqui roda igual, so sem o carretel e sem o nome da
	unidade. Sem `owner` a abertura e do jogador local -- e como o console pede uma.

	Cada cliente resolve o lugar da caixa por conta propria, a partir do personagem do
	dono. O ponto pode sair um fio diferente de tela para tela (a posicao do personagem
	de outro jogador chega interpolada), e isso e de proposito: o que a cena precisa
	dizer e "a caixa e daquele jogador ali", e nao um centimetro exato.

	Returns false when it could not start (bad result, no character, missing asset,
	or too many already playing).
]=]
function UnboxingController:Open(result : UnboxingResult, owner : Player?) : boolean
	if typeof(result) ~= "table" then
		warn("[UnboxingController]: Open expects the result table rolled by CrateService.")
		return false
	end

	owner = owner or Players.LocalPlayer
	local isOwner = owner == Players.LocalPlayer

	-- The crate the player opened. If it evolved, the reel lands on the upgrade card
	-- and the crate is swapped mid-unboxing, one stage per step.
	local crateRarity = CrateConfig.resolveRarity(result.Crate)
	if not crateRarity then
		warn(string.format("[UnboxingController]: %q is not a valid crate rarity.", tostring(result.Crate)))
		return false
	end

	local winnerRarity = RarityConfig.resolve(result.Rarity)
	if not winnerRarity then
		warn(string.format("[UnboxingController]: %q is not a valid rarity.", tostring(result.Rarity)))
		return false
	end

	--[[
		O teto vale para as caixas dos outros. A que o jogador local abriu e a que ele
		pagou para ver, entao ela entra mesmo com o lobby cheio de abertura -- deixar de
		fora justamente a dele seria o unico caso em que perder a cena importa.
	]]
	if not isOwner and #self.Sessions >= MAX_ACTIVE_UNBOXINGS then
		return false
	end

	-- Personagem do dono, e nao o local: quem assiste pode ver a caixa de alguem que
	-- ainda esta carregando na frente dele.
	if not self:_getRoot(owner :: Player) then
		warn(string.format("[UnboxingController]: %s has no character spawned yet.", (owner :: Player).Name))
		return false
	end

	local session = self:_openSession(owner :: Player)

	local crate = self:_spawnCrate(session, crateRarity)
	if not crate then
		self:_closeSession(session)
		return false
	end

	-- Where the crate ended up is what the next unboxing has to keep away from, and
	-- where the evolved models are dropped as it upgrades.
	session.Crate = crate
	session.CFrame = crate:GetPivot()
	session.Position = session.CFrame.Position

	-- Where the crate is standing, so the unit that replaces it lands on the same floor.
	local _, crateExtents = crate:GetBoundingBox()
	session.GroundY = session.Position.Y - crateExtents.Y * 0.5

	local attachment = self:_attachBillboard(crate, session.Maid)
	if not attachment then
		self:_closeSession(session)
		return false
	end

	session.Attachment = attachment

	-- One spin per upgrade the crate went through, then the spin for the reward.
	local stages = {}
	local stageCrate = crateRarity

	for _, upgradeTo in result.Upgrades or {} do
		local resolvedUpgrade = CrateConfig.resolveRarity(upgradeTo)
		if not resolvedUpgrade then
			warn(string.format("[UnboxingController]: %q is not a valid crate rarity.", tostring(upgradeTo)))
			continue
		end

		table.insert(stages, { Crate = stageCrate, Face = { Upgrade = resolvedUpgrade } })
		stageCrate = resolvedUpgrade
	end

	table.insert(stages, { Crate = stageCrate, Face = { Rarity = winnerRarity, Unit = result.Unit } })

	--[[
		The reel is hidden while the crate grows in: the attachment offset scales with
		the model, so an enabled billboard would climb up along with it.

		Numa tela que nao e a do dono ela nunca chega a ser ligada. O carretel continua
		sendo montado e girado do mesmo jeito -- e o giro dele que marca o tempo de toda
		a abertura, do estufao ao premio --, so que atras de um BillboardGui desligado,
		que o Roblox nao desenha. Um caminho so para as duas telas, e as duas terminam
		no mesmo instante.
	]]
	local billboard = attachment:FindFirstChildWhichIsA("BillboardGui")
	if billboard then
		billboard.Enabled = false
	end

	-- Shrunk and pulled back onto the player before anyone hears about it, so a
	-- listener never catches it full size or already standing on its spot.
	crate:ScaleTo(SPAWN_SCALE)

	-- It leaves the player with the rotation it will land with -- only the position
	-- travels, so it does not spin on the way in and fight the reel that follows.
	local rootPart = self:_getRoot(session.Owner)
	if rootPart then
		crate:PivotTo(session.CFrame.Rotation + rootPart.Position)
		self:_tweenPivot(crate, SPAWN_TRAVEL_INFO, session.CFrame, session.Maid)
	end

	self.Signals.UnboxingStarted:Fire(result, crate, session.Owner)

	local grow = self:_tweenScale(crate, SPAWN_GROW_INFO, 1, session.Maid)
	grow.Completed:Once(function(state : Enum.PlaybackState)
		if session.Closed or state ~= Enum.PlaybackState.Completed then
			return
		end

		-- Both tweens run the same length, but the pivot is snapped so float drift
		-- never leaves the crate a hair off the spot the rest of the flow uses.
		crate:PivotTo(session.CFrame)

		if billboard and session.IsOwner then
			billboard.Enabled = true
		end

		self:_playStage(session, result, stages, 1)
	end)

	return true
end

--[=[
	Tears down every unboxing playing right now: crates, attachments and tweens.
]=]
function UnboxingController:CancelAll()
	for index = #self.Sessions, 1, -1 do
		self:_closeSession(self.Sessions[index])
	end
end

function UnboxingController:construct()
	local Assets = Shared:WaitForChild("Assets")

	local UI = Assets:WaitForChild("UI")

	local VFX = Assets:WaitForChild("VFX")

	self.CrateModels = Assets:WaitForChild("CratesModel")
	self.UnitModels = Assets:WaitForChild("Units")
	self.AttachmentTemplate = UI:WaitForChild("UnboxingAttachment")

	self.CrateOpenVFX = VFX:WaitForChild(CRATE_OPEN_VFX_NAME)
	self.UnitAuraVFX = VFX:WaitForChild(UNIT_AURA_VFX_NAME)
	self.UnitDisplayTemplate = UI:WaitForChild(UNIT_DISPLAY_NAME)

	-- One card per crate an unboxing can evolve into, named after it.
	self.UpgradeTemplates = UI:WaitForChild("UpgradeCrateUnboxingTemplates")

	local folder = Instance.new("Folder")
	folder.Name = CRATES_FOLDER_NAME
	folder.Parent = workspace

	self.CratesFolder = folder
	self.Maid:GiveTask(folder)

	-- The roll itself is server side (CrateService), so this is the only way an
	-- unboxing legitimately starts.
	Framework:Listen("PlayUnboxing", function(result : UnboxingResult, owner : Player)
		self:Open(result, owner)
	end)
end

function UnboxingController:start()

end

function UnboxingController:init()
	self.Maid = Maid.new()

	self.Sessions = {}
	self.SessionCount = 0

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return UnboxingController
