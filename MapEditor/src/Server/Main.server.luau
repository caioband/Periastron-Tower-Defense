--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)
local Serializer = require(Shared.Serializer)
local MapRules = require(Shared.MapRules)

local Modules = script.Parent
local TemplateBuilder = require(Modules.TemplateBuilder)
local SessionService = require(Modules.SessionService)
local MapStore = require(Modules.MapStore)
local MapValidation = require(Modules.MapValidation)
local PlaytestService = require(Modules.PlaytestService)
local PeriMapAdapter = require(Modules.PeriMapAdapter)
local RateLimiter = require(Modules.RateLimiter)

local Me = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Vendor"):WaitForChild("Me"))
local DataService = Me.new():Get("DataService", false, true)

TemplateBuilder.build()
SessionService.init()
MapStore.init()

local remotes = Shared:FindFirstChild("Remotes")
if remotes then
	remotes:Destroy()
end
remotes = Instance.new("Folder")
remotes.Name = "Remotes"
local Request = Instance.new("RemoteFunction")
Request.Name = "Request"
Request.Parent = remotes
local Push = Instance.new("RemoteEvent")
Push.Name = "Push"
Push.Parent = remotes
remotes.Parent = Shared

local general = RateLimiter.new(Config.REQUEST_RATE, Config.REQUEST_BURST)
local heavy = RateLimiter.new(Config.HEAVY_REQUEST_RATE, Config.HEAVY_REQUEST_BURST)

local HEAVY = {
	Save = true, Load = true, List = true, New = true, Rename = true, Duplicate = true, Delete = true,
	PlaytestStart = true, PrefabSave = true, PrefabDelete = true, PrefabList = true, ImportPeri = true, ExportPeri = true,
}

local function ok(data: any?): { [string]: any }
	return { ok = true, data = data }
end

local function fail(message: string, extra: { [string]: any }?): { [string]: any }
	local out: { [string]: any } = { ok = false, err = message }
	if extra then
		for k, v in extra do
			out[k] = v
		end
	end
	return out
end

local function pusher(player: Player): (string, any) -> ()
	return function(kind: string, data: any)
		if player.Parent then
			Push:FireClient(player, kind, data)
		end
	end
end

local function toast(player: Player, text: string, kind: string?)
	if player.Parent then
		Push:FireClient(player, "Toast", { text = text, kind = kind or "info" })
	end
end

local function filterName(player: Player, raw: any): (string?, string?)
	local name = MapRules.sanitizeName(raw)
	if not name then
		return nil, "Enter a name."
	end
	local success, result = pcall(function()
		local filtered = TextService:FilterStringAsync(name, player.UserId)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if success then
		return result, nil
	end
	if RunService:IsStudio() then
		return name, nil
	end
	return nil, "That name could not be checked right now. Try again."
end

local function isDeveloper(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User then
		return player.UserId == game.CreatorId
	end
	local success, rank = pcall(function()
		return player:GetRankInGroup(game.CreatorId)
	end)
	return success and rank >= 254
end

local function saveSession(session: SessionService.Session): (boolean, string?)
	session.map.modified = os.time()
	local saved, err = MapStore.save(session.player, session.map)
	if saved then
		session.dirty = false
		session.savedOnce = true
		session.lastSave = os.clock()
		SessionService.syncMeta(session)
	end
	return saved, err
end

local function needsDiscardConfirm(session: SessionService.Session, payload: any): boolean
	return session.dirty and not (typeof(payload) == "table" and payload.discard == true)
end

local function sanitizePrefab(raw: any): ({ any }?, string?)
	if typeof(raw) ~= "table" or #raw == 0 then
		return nil, "Select something to save as a prefab."
	end
	if #raw > Config.MAX_PREFAB_OBJECTS then
		return nil, string.format("Prefabs can hold at most %d objects.", Config.MAX_PREFAB_OBJECTS)
	end
	local list = {}
	for _, rec in raw do
		local success, _, clean = MapRules.sanitizeRecord(rec)
		if success and clean then
			local def = Catalog.get(clean.t) :: Catalog.Def
			if not Catalog.limit(def) and def.role ~= Catalog.ROLE.Waypoint then
				clean.lk = nil
				table.insert(list, clean)
			end
		end
	end
	if #list == 0 then
		return nil, "Nothing in the selection can be saved as a prefab (markers and waypoints are excluded)."
	end
	return list, nil
end

local handlers: { [string]: (Player, any) -> { [string]: any } } = {}

local function requireSession(player: Player): SessionService.Session?
	return SessionService.get(player)
end

handlers.Enter = function(player)
	if not MapStore.awaitProfile(player) then
		return fail("Your data is still loading. Try again in a moment.")
	end
	local session = SessionService.enter(player, pusher(player))
	task.defer(SessionService.pushSnapshot, session)
	return ok({
		originX = session.origin.X,
		plot = session.plotIndex,
		memoryStorage = MapStore.usingMemory,
		developer = isDeveloper(player),
	})
end

handlers.Exit = function(player)
	local session = requireSession(player)
	if not session then
		return ok()
	end
	PlaytestService.stop(session)
	if session.dirty and session.savedOnce then
		local saved, err = saveSession(session)
		if not saved then
			return fail("Could not save before leaving: " .. tostring(err) .. " Stay in the editor and try saving again.")
		end
	end
	SessionService.exit(player)
	return ok()
end

handlers.Apply = function(player, payload)
	local session = requireSession(player)
	if not session then
		return fail("Not in build mode.")
	end
	if typeof(payload) ~= "table" then
		return fail("Malformed request.")
	end
	local success, err, result = SessionService.applyOps(session, payload.ops)
	if not success then
		return fail(err or "Change rejected.")
	end
	return ok(result)
end

handlers.Validate = function(player)
	local session = requireSession(player)
	if not session then
		return fail("Not in build mode.")
	end
	return ok(MapValidation.run(session))
end

handlers.New = function(player, payload)
	local session = requireSession(player)
	if not session then
		return fail("Not in build mode.")
	end
	if session.mode ~= "Build" then
		return fail("Stop the playtest first.")
	end
	if needsDiscardConfirm(session, payload) then
		return fail("You have unsaved changes.", { confirm = true })
	end
	local name, err = filterName(player, typeof(payload) == "table" and payload.name or "Untitled Map")
	if not name then
		return fail(err or "Invalid name.")
	end
	SessionService.replaceMap(session, Serializer.blankMap(player.UserId, name))
	session.savedOnce = false
	return ok({ id = session.map.id, name = session.map.name })
end

handlers.Save = function(player)
	local session = requireSession(player)
	if not session then
		return fail("Not in build mode.")
	end
	if session.busy then
		return fail("Wait for the map to finish loading.")
	end
	local wait = Config.SAVE_COOLDOWN - (os.clock() - session.lastSave)
	if wait > 0 then
		return fail(string.format("Saved recently. Try again in %d s.", math.ceil(wait)))
	end
	local validation = MapValidation.run(session)
	local saved, err = saveSession(session)
	if not saved then
		return fail(err or "Save failed.")
	end
	return ok({ id = session.map.id, name = session.map.name, validation = validation, memoryStorage = MapStore.usingMemory })
end

handlers.List = function(player)
	local success, result = MapStore.list(player)
	if not success then
		return fail(result :: string)
	end
	local session = requireSession(player)
	return ok({ maps = result, current = session and session.map.id, max = Config.MAX_MAPS_PER_PLAYER })
end

handlers.Load = function(player, payload)
	local session = requireSession(player)
	if not session then
		return fail("Not in build mode.")
	end
	if session.mode ~= "Build" then
		return fail("Stop the playtest first.")
	end
	if typeof(payload) ~= "table" or not MapRules.validId(payload.id) then
		return fail("Invalid map.")
	end
	if os.clock() - session.lastLoad < Config.LOAD_COOLDOWN then
		return fail("Loading too quickly. Wait a moment.")
	end
	if needsDiscardConfirm(session, payload) then
		return fail("You have unsaved changes.", { confirm = true })
	end
	session.lastLoad = os.clock()
	local success, result = MapStore.load(player, payload.id)
	if not success then
		return fail(result :: string)
	end
	local warnings = SessionService.replaceMap(session, result :: Serializer.Map)
	session.savedOnce = true
	return ok({ id = session.map.id, name = session.map.name, warnings = warnings })
end

handlers.Rename = function(player, payload)
	local session = requireSession(player)
	if typeof(payload) ~= "table" or not MapRules.validId(payload.id) then
		return fail("Invalid map.")
	end
	local name, err = filterName(player, payload.name)
	if not name then
		return fail(err or "Invalid name.")
	end
	if session and session.map.id == payload.id then
		session.map.name = name
		SessionService.syncMeta(session)
		if not session.savedOnce then
			return ok({ name = name })
		end
	end
	local success, renameErr = MapStore.rename(player, payload.id, name)
	if not success then
		return fail(renameErr or "Rename failed.")
	end
	return ok({ name = name })
end

handlers.Duplicate = function(player, payload)
	if typeof(payload) ~= "table" or not MapRules.validId(payload.id) then
		return fail("Invalid map.")
	end
	local name, err = filterName(player, payload.name or "Copy")
	if not name then
		return fail(err or "Invalid name.")
	end
	local success, result = MapStore.duplicate(player, payload.id, name)
	if not success then
		return fail(result :: string)
	end
	return ok({ id = (result :: Serializer.Map).id, name = name })
end

handlers.Delete = function(player, payload)
	if typeof(payload) ~= "table" or not MapRules.validId(payload.id) then
		return fail("Invalid map.")
	end
	local success, err = MapStore.delete(player, payload.id)
	if not success then
		return fail(err or "Delete failed.")
	end
	local session = requireSession(player)
	if session and session.map.id == payload.id then
		session.savedOnce = false
		session.dirty = true
		SessionService.syncMeta(session)
	end
	return ok()
end

handlers.PlaytestStart = function(player)
	local session = requireSession(player)
	if not session then
		return fail("Not in build mode.")
	end
	local success, result = PlaytestService.start(session)
	if not success then
		if typeof(result) == "table" then
			return fail(result.reason, { validation = result.validation })
		end
		return fail(result)
	end
	return ok(result)
end

handlers.PlaytestStop = function(player)
	local session = requireSession(player)
	if not session then
		return fail("Not in build mode.")
	end
	PlaytestService.stop(session)
	return ok()
end

handlers.PlaytestWave = function(player)
	local session = requireSession(player)
	if not session then
		return fail("Not in build mode.")
	end
	local success, err = PlaytestService.spawnWave(session)
	if not success then
		return fail(err or "Could not spawn.")
	end
	return ok()
end

handlers.PlaytestTower = function(player, payload)
	local session = requireSession(player)
	if not session then
		return fail("Not in build mode.")
	end
	local success, err = PlaytestService.placeTower(session, typeof(payload) == "table" and payload.position)
	if not success then
		return fail(err or "Cannot place there.")
	end
	return ok()
end

handlers.PrefabList = function(player)
	local success, result = MapStore.loadPrefabs(player)
	if not success then
		return fail(result)
	end
	return ok({ prefabs = result })
end

handlers.PrefabSave = function(player, payload)
	if typeof(payload) ~= "table" then
		return fail("Malformed request.")
	end
	local name, nameErr = filterName(player, payload.name)
	if not name then
		return fail(nameErr or "Invalid name.")
	end
	local objects, err = sanitizePrefab(payload.objects)
	if not objects then
		return fail(err or "Invalid prefab.")
	end
	local saved, list = MapStore.savePrefab(player, name, objects)
	if not saved then
		return fail(list or "Could not save prefab.")
	end
	return ok({ prefabs = list })
end

handlers.PrefabDelete = function(player, payload)
	if typeof(payload) ~= "table" or not MapRules.validId(payload.id) then
		return fail("Invalid prefab.")
	end
	local deleted, list = MapStore.deletePrefab(player, payload.id)
	if not deleted then
		return fail(list or "Could not delete prefab.")
	end
	return ok({ prefabs = list })
end

handlers.ImportList = function(player)
	if not isDeveloper(player) then
		return fail("Developers only.")
	end
	local names = {}
	local imports = ServerStorage:FindFirstChild("MapEditorImports")
	if imports then
		for _, child in imports:GetChildren() do
			table.insert(names, child.Name)
		end
	end
	table.sort(names)
	return ok({ names = names })
end

handlers.ImportPeri = function(player, payload)
	if not isDeveloper(player) then
		return fail("Developers only.")
	end
	local session = requireSession(player)
	if not session then
		return fail("Not in build mode.")
	end
	if session.mode ~= "Build" then
		return fail("Stop the playtest first.")
	end
	if needsDiscardConfirm(session, payload) then
		return fail("You have unsaved changes.", { confirm = true })
	end
	local imports = ServerStorage:FindFirstChild("MapEditorImports")
	local source = imports and typeof(payload) == "table" and typeof(payload.name) == "string" and imports:FindFirstChild(payload.name)
	if not source then
		return fail("No such folder in ServerStorage.MapEditorImports.")
	end
	local map, report = PeriMapAdapter.import(source, player.UserId)
	if not map then
		return fail(report :: string)
	end
	local warnings = SessionService.replaceMap(session, map)
	session.savedOnce = false
	session.dirty = true
	SessionService.syncMeta(session)
	return ok({ report = report, warnings = warnings, id = session.map.id, name = session.map.name })
end

handlers.ExportPeri = function(player, payload)
	if not isDeveloper(player) then
		return fail("Developers only.")
	end
	local session = requireSession(player)
	if not session then
		return fail("Not in build mode.")
	end
	local validation = MapValidation.run(session)
	if #validation.errors > 0 then
		return fail("Fix the blocking errors before exporting.", { validation = validation })
	end
	local name = MapRules.sanitizeName(typeof(payload) == "table" and payload.name or session.map.name) or session.map.id
	local exports = ServerStorage:FindFirstChild("MapEditorExports")
	if not exports then
		exports = Instance.new("Folder")
		exports.Name = "MapEditorExports"
		exports.Parent = ServerStorage
	end
	local previous = (exports :: Instance):FindFirstChild(name)
	if previous then
		previous:Destroy()
	end
	local folder, report = PeriMapAdapter.export(session.map, name, Shared:WaitForChild("Templates"))
	folder.Parent = exports
	return ok({ path = folder:GetFullName(), report = report })
end

Request.OnServerInvoke = function(player: Player, action: any, payload: any)
	if typeof(action) ~= "string" then
		return fail("Malformed request.")
	end
	local handler = handlers[action]
	if not handler then
		return fail("Unknown request.")
	end
	if not general:allow(player.UserId) then
		return fail("Too many requests. Slow down a little.")
	end
	if HEAVY[action] and not heavy:allow(player.UserId) then
		return fail("Please wait a moment before doing that again.")
	end
	local success, result = pcall(handler, player, payload)
	if not success then
		warn(string.format("[MapEditor] %s failed for %s: %s", action, player.Name, tostring(result)))
		return fail("Something went wrong on the server. Your map is unchanged.")
	end
	return result
end

-- Saves still running from a leave, so the shutdown below waits for them.
local pendingLeaveSaves = 0

-- [Player] = true while `leave` runs for them, so the fallback below does not start a
-- second save while the hook's is still in flight.
local leaving: { [Player]: boolean } = {}

--[[
	The leave save writes the map list in the profile, so it has to run while the
	profile is still open: DataService runs this hook right before it ends the
	session, on a normal leave and on shutdown alike. Connecting our own
	PlayerRemoving instead would race DataService's and lose the list update.
]]
local function leave(player: Player)
	if leaving[player] then
		return
	end
	leaving[player] = true
	local session = SessionService.get(player)
	if session then
		PlaytestService.stop(session)
		if session.dirty and session.savedOnce and not session.busy then
			pendingLeaveSaves += 1
			local success, saved, err = pcall(saveSession, session)
			pendingLeaveSaves -= 1
			if not success or not saved then
				warn("[MapEditor] Save on leave failed for " .. player.Name .. ": " .. tostring(if success then err else saved))
			end
		end
		SessionService.exit(player)
	end
	MapStore.forget(player)
	leaving[player] = nil
end

DataService:OnBeforeRelease(leave)

Players.PlayerRemoving:Connect(function(player)
	general:clear(player.UserId)
	heavy:clear(player.UserId)

	-- Without an open profile the hook above never runs (the profile did not load, or
	-- another server took it): close the session here. Deferred, so a profile that is
	-- open goes through the hook first.
	task.defer(function()
		if SessionService.get(player) and not leaving[player] then
			leave(player)
		end
	end)
end)

game:BindToClose(function()
	-- DataService's own BindToClose starts the leave saves; give it a moment, then
	-- keep the server up until they land.
	task.wait(1)
	local deadline = os.clock() + 25
	while pendingLeaveSaves > 0 and os.clock() < deadline do
		task.wait(0.2)
	end
end)

task.spawn(function()
	while true do
		task.wait(Config.AUTOSAVE_INTERVAL)
		for player, session in SessionService.sessions do
			if session.dirty and session.savedOnce and session.mode == "Build" and not session.busy then
				local saved, err = saveSession(session)
				if saved then
					toast(player, "Autosaved.", "info")
				else
					toast(player, "Autosave failed: " .. tostring(err), "error")
				end
			end
		end
	end
end)
