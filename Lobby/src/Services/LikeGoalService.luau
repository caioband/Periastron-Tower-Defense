local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local CodesConfig = require(ServerScriptService:WaitForChild("Config"):WaitForChild("Codes"))

--[[ CONFIG ]]
local UNIVERSE_ID = 10340119210 -- the live game's universe id
local RELAY_URL = "https://likegoal.xenixiyo.workers.dev" -- your Cloudflare Worker, no trailing slash

local STEP = 500
local REWARD_CASH = 250
local POLL_SECONDS = 60
local RETRY_SECONDS = 15 -- used while no like count is available at all
local FAR_FUTURE = 4102444800 -- 2100-01-01 UTC, "never expires"

local STORE = DataStoreService:GetDataStore("LikeGoalCodes_v1")
local STATE_KEY = "State"
local MANUAL_KEY = "ManualLikes" -- number you can set by hand if the relay is ever down
local TOPIC = "LikeGoalAdvance"

--[[ STATE ]]
local likesLabel: TextLabel? = nil
local codeLabel: TextLabel? = nil

local state = { Milestone = 0, Codes = {} } -- Codes = array of { Milestone, Code, LiveAt, ExpiredAt? }
local currentLikes: number? = nil
local relayWarned = false

local function codeFor(milestone: number): string
	if milestone < 1000 then
		return `{milestone}LIKES`
	end
	return string.format("%gKLIKES", milestone / 1000) -- 1000 -> 1KLIKES, 1500 -> 1.5KLIKES
end

local function refreshBoard()
	if not likesLabel or not codeLabel then
		return
	end

	local live = "..."
	for _, entry in state.Codes do
		if not entry.ExpiredAt then
			live = entry.Code
		end
	end

	likesLabel.Text = `{currentLikes or "?"}/{state.Milestone + STEP}`
	codeLabel.Text = live
end

-- Pushes the DataStore state into the table CodeService reads from.
local function applyState(newState)
	state = newState

	for _, entry in state.Codes do
		local definition = CodesConfig.Codes[entry.Code]
		local expiresAt = entry.ExpiredAt or FAR_FUTURE

		if definition then
			definition.ExpiresAt = expiresAt
		else
			CodesConfig.Codes[entry.Code] = {
				ExpiresAt = expiresAt,
				Rewards = { Cash = REWARD_CASH },
			}
		end
	end

	refreshBoard()
end

--[[ LIKES ]]
local function fetchLikesFromRelay(): number?
	local url = `{RELAY_URL}/v1/games/votes?universeIds={UNIVERSE_ID}`

	local ok, result = pcall(HttpService.RequestAsync, HttpService, { Url = url, Method = "GET" })
	if not ok or not result.Success then
		if not relayWarned then
			relayWarned = true
			local reason = if ok then `HTTP {result.StatusCode}` else tostring(result)
			warn(`[LikeGoal] relay failed ({reason}); falling back to ManualLikes`)
		end
		return nil
	end

	local decoded, data = pcall(HttpService.JSONDecode, HttpService, result.Body)
	local entry = decoded and data.data and data.data[1]
	if entry and typeof(entry.upVotes) == "number" then
		relayWarned = false
		return entry.upVotes
	end

	if not relayWarned then
		relayWarned = true
		warn("[LikeGoal] relay answered but the response had no upVotes")
	end
	return nil
end

local function fetchLikesFromManual(): number?
	local ok, value = pcall(STORE.GetAsync, STORE, MANUAL_KEY)
	if ok and typeof(value) == "number" then
		return value
	end
	return nil
end

local function fetchLikes(): number?
	return fetchLikesFromRelay() or fetchLikesFromManual()
end

--[[ DATASTORE ]]
local function loadState()
	local ok, saved = pcall(STORE.GetAsync, STORE, STATE_KEY)
	if ok and typeof(saved) == "table" and typeof(saved.Codes) == "table" then
		applyState(saved)
	elseif not ok then
		warn(`[LikeGoal] DataStore read failed: {saved}`)
	end
end

-- Advances to `target` if it is ahead of what is saved. Safe across servers.
local function advanceTo(target: number)
	local advanced = false

	local ok, result = pcall(STORE.UpdateAsync, STORE, STATE_KEY, function(saved)
		saved = saved or { Milestone = 0, Codes = {} }

		if target <= saved.Milestone then
			return nil -- another server already got here
		end

		local now = os.time()

		-- The old code dies in the same write that makes the new one live.
		for _, entry in saved.Codes do
			if not entry.ExpiredAt then
				entry.ExpiredAt = now
			end
		end

		table.insert(saved.Codes, {
			Milestone = target,
			Code = codeFor(target),
			LiveAt = now,
		})
		saved.Milestone = target
		advanced = true

		return saved
	end)

	if not ok then
		warn(`[LikeGoal] DataStore write failed: {result}`)
	end

	if ok and advanced and typeof(result) == "table" then
		applyState(result)
		pcall(MessagingService.PublishAsync, MessagingService, TOPIC, "advance")
	else
		loadState() -- cancelled or failed: take whatever is saved now
	end
end

--[[ SERVICE ]]
local LikeGoalService = {
	Services = {},
}

function LikeGoalService:start()
	local container = Workspace:WaitForChild("LikeGoal")
		:WaitForChild("BoardPart")
		:WaitForChild("Display")
		:WaitForChild("UI")
		:WaitForChild("Frame")
		:WaitForChild("Container")

	likesLabel = container:WaitForChild("Likes")
	codeLabel = container:WaitForChild("CurrentCode"):WaitForChild("Code")

	loadState()

	pcall(function()
		MessagingService:SubscribeAsync(TOPIC, function()
			loadState()
		end)
	end)

	task.spawn(function()
		while true do
			local likes = fetchLikes()
			if likes then
				currentLikes = likes

				local target = math.floor(likes / STEP) * STEP
				if target > state.Milestone then
					advanceTo(target)
				else
					loadState() -- pick up other servers' changes
				end
			end

			refreshBoard()
			task.wait(if likes then POLL_SECONDS + math.random() * 10 else RETRY_SECONDS)
		end
	end)
end

function LikeGoalService:init()
end

return LikeGoalService