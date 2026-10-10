local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local log = Log.new("NextEventController")

--[[
	The "next event" sign in the Lobby: `Workspace.NEXTEVENT`, a part with a
	`BillboardGui` (the event's name and a countdown) and a `ProximityPrompt` that
	opens Roblox's RSVP prompt for the event.

	The event is a Roblox experience event, read by id with
	`SocialService:GetExperienceEventAsync` when the client starts and again every
	`REFRESH_INTERVAL`, so a new title or time shows up without a rejoin. Every
	environment uses the same `EVENT_ID`.

	**The sign only shows before the event starts.** It is hidden while the event is
	loading or could not be read, once it has started (RSVP no longer works then),
	and after it ends. Roblox only answers for events of the current universe, so
	in a universe the event does not belong to (QA, for a Production event) the
	read comes back empty and the sign stays hidden.

	`StartTime` comes as date parts with no time zone in the docs; it is read as UTC.
	Each fetch prints the start it understood (`log:Info`), so the countdown can be
	checked against the event page.

	Everything here is client only: the RSVP prompt can only be opened by the
	player's own client, and the edits to the sign are local.

	Streaming can take the part out of the world and bring it back, so the sign is
	bound every time it appears.

	See docs/lobby/next-event.md.
]]

--[[ CONSTANTS ]]

-- The experience event, the same in every environment.
local EVENT_ID = "2141559620710302327"

local PART_NAME = "NEXTEVENT"
local BILLBOARD_NAME = "BillboardGui"
local PROMPT_NAME = "ProximityPrompt"
local NAME_LABEL = "EventName"
local TIMER_LABEL = "Timer"

-- Seconds between two reads of the event.
local REFRESH_INTERVAL = 5 * 60

local TIMER_FORMAT = "%02d Days : %02d Hours : %02d Minutes : %02d Seconds"

-- The prompt's text once the player is going. The text before is the one
-- authored in Studio.
local NOTIFIED_TEXT = "Notified ✓"

-- Statuses that mean the event will not happen.
local DEAD_STATUSES = {
	Cancelled = true,
	Moderated = true,
	Unpublished = true,
}

local NextEventController = {
	Controllers = {},

	-- The event as last read: `{ Title, StartsAt (Unix seconds), Going }`, or nil.
	Event = nil,

	-- The bound sign: `{ Part, Billboard, Prompt, NameLabel, TimerLabel, ActionText }`.
	Sign = nil,

	-- True while the RSVP prompt is open.
	Prompting = false,
}

--[[ INTERNAL ]]

local function now() : number
	return workspace:GetServerTimeNow()
end

-- `StartTime` / `EndTime` date parts as Unix seconds, read as UTC.
local function toUnix(parts : any) : number?
	if typeof(parts) ~= "table" then return nil end

	local ok, dateTime = pcall(
		DateTime.fromUniversalTime,
		parts.Year, parts.Month, parts.Day,
		parts.Hour or 0, parts.Minute or 0, parts.Second or 0, parts.Millisecond or 0
	)
	if not ok then return nil end

	return dateTime.UnixTimestampMillis / 1000
end

local function nonEmpty(text : any) : string?
	if typeof(text) == "string" and text ~= "" then
		return text
	end

	return nil
end

local function formatRemaining(seconds : number) : string
	seconds = math.max(0, math.floor(seconds))

	return string.format(TIMER_FORMAT, seconds // 86400, (seconds // 3600) % 24, (seconds // 60) % 60, seconds % 60)
end

--[=[
	Reads the event. Returns the parsed event, or nil when there is none to show
	(not found, already started, ended, or cancelled). Errors propagate: the
	caller keeps the previous read on a failed call.
]=]
local function fetch(eventId : string)
	local event = SocialService:GetExperienceEventAsync(eventId)
	if typeof(event) ~= "table" then
		return nil
	end

	local status = if typeof(event.Status) == "EnumItem" then event.Status.Name else nil
	if event.HasStarted or event.HasEnded or (status and DEAD_STATUSES[status]) then
		return nil
	end

	local startsAt = toUnix(event.StartTime)
	if not startsAt then
		log:StudioWarn(`event {eventId} came without a readable StartTime.`)
		return nil
	end

	return {
		Title = nonEmpty(event.DisplayTitle) or nonEmpty(event.Title) or "",
		StartsAt = startsAt,
		Going = event.UserRsvpStatus == Enum.RsvpStatus.Going,
	}
end

--[=[
	Puts the current state on the sign: name, countdown, prompt text, and whether
	it shows at all.
]=]
function NextEventController:_render()
	local sign = self.Sign
	if not sign or not sign.Part.Parent then return end

	local event = self.Event
	local remaining = event and (event.StartsAt - now())
	local visible = remaining ~= nil and remaining > 0

	sign.Billboard.Enabled = visible
	if sign.Prompt then
		sign.Prompt.Enabled = visible
	end

	if not visible then return end

	if sign.NameLabel then
		sign.NameLabel.Text = event.Title
	end
	if sign.TimerLabel then
		sign.TimerLabel.Text = formatRemaining(remaining)
	end
	if sign.Prompt then
		sign.Prompt.ActionText = if event.Going then NOTIFIED_TEXT else sign.ActionText
	end
end

function NextEventController:_refresh(eventId : string)
	local ok, result = pcall(fetch, eventId)
	if not ok then
		log:StudioWarn(`could not read event {eventId}:`, result)
		return
	end

	self.Event = result

	if result then
		local startsAt = DateTime.fromUnixTimestamp(math.floor(result.StartsAt)):ToIsoDate()
		log:Info(`next event "{result.Title}" starts {startsAt} (read as UTC), in {formatRemaining(result.StartsAt - now())}`)
	else
		log:Debug(`event {eventId} is not upcoming; the sign stays hidden.`)
	end

	self:_render()
end

function NextEventController:_promptRsvp(eventId : string)
	if self.Prompting or not self.Event then return end
	self.Prompting = true

	local ok, status = pcall(SocialService.PromptRsvpToEventAsync, SocialService, eventId)
	self.Prompting = false

	if not ok then
		-- Most likely the event started meanwhile: read it again.
		log:StudioWarn("RSVP prompt failed:", status)
		task.spawn(self._refresh, self, eventId)
		return
	end

	if self.Event then
		self.Event.Going = status == Enum.RsvpStatus.Going
	end

	self:_render()
end

function NextEventController:_bind(part : Instance, eventId : string)
	if part.Name ~= PART_NAME then return end

	if self.SignMaid then
		self.SignMaid:DoCleaning()
	end

	local billboard = part:WaitForChild(BILLBOARD_NAME, 10)
	if not billboard or not billboard:IsA("BillboardGui") then
		log:StudioWarn(`{PART_NAME} has no {BILLBOARD_NAME}; the event sign is off.`)
		return
	end

	local prompt = part:FindFirstChild(PROMPT_NAME)
	prompt = if prompt and prompt:IsA("ProximityPrompt") then prompt else nil

	local maid = Maid.new()
	self.SignMaid = maid

	self.Sign = {
		Part = part,
		Billboard = billboard,
		Prompt = prompt,
		NameLabel = billboard:FindFirstChild(NAME_LABEL),
		TimerLabel = billboard:FindFirstChild(TIMER_LABEL),
		ActionText = prompt and prompt.ActionText or "",
	}

	if prompt then
		maid:GiveTask(prompt.Triggered:Connect(function()
			task.spawn(self._promptRsvp, self, eventId)
		end))
	end

	maid:GiveTask(part.AncestryChanged:Connect(function()
		if not part:IsDescendantOf(workspace) then
			maid:DoCleaning()
			if self.Sign and self.Sign.Part == part then
				self.Sign = nil
			end
		end
	end))

	self:_render()
end

--[[ LIFECYCLE ]]

function NextEventController:construct()
	local eventId = EVENT_ID

	workspace.ChildAdded:Connect(function(child)
		self:_bind(child, eventId)
	end)

	local existing = workspace:FindFirstChild(PART_NAME)
	if existing then
		task.spawn(self._bind, self, existing, eventId)
	end

	task.spawn(function()
		while true do
			self:_refresh(eventId)
			task.wait(REFRESH_INTERVAL)
		end
	end)

	task.spawn(function()
		while true do
			self:_render()
			task.wait(1)
		end
	end)
end

function NextEventController:start()
end

function NextEventController:init()
	self:construct()
end

return NextEventController
