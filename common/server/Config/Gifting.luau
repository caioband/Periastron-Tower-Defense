--[[
	Gifting tunables (`GiftService`). Server only.
]]
return {
	-- Between two gift requests from one player. Each request saves the buyer's
	-- profile before the prompt opens, so keep this above ProfileStore's save spacing.
	REQUEST_COOLDOWN = 6,

	-- Between two recipient lookups from one player (web calls, and a DataStore
	-- read for a recipient who is not on this server).
	LOOKUP_COOLDOWN = 3,

	-- How long a lookup's answer is reused for the same recipient (any asker).
	LOOKUP_CACHE_SECONDS = 10,

	-- Lookups stop (answering `ServiceUnavailable`) while the server's DataStore
	-- GetAsync budget is under this: profile loads and saves come first.
	LOOKUP_MIN_BUDGET = 40,

	-- While a gift's purchase prompt is open (no answer from Roblox yet), the
	-- buyer cannot start another gift of the same item. Closing the prompt frees
	-- it at once; this is only the fallback when that answer never comes.
	PROMPT_LOCK = 120,

	-- After Roblox says the gift was bought, until its receipt is paid out, the
	-- buyer cannot start another gift of the same item: the new intent would
	-- replace the one the pending receipt still needs. A fallback, not the norm.
	PAID_LOCK = 86400,

	--[[
		Coins the recipient gets instead when a pass gift arrives and they already
		own the pass (two gifts racing, or a gift that fell back to a buyer who owns
		it). Keyed by the pass key. `0` or missing = no compensation, only a warning.
		Fill with roughly what the gift product costs.
	]]
	DUPLICATE_COINS = {
		VIP = 0,
		Shards = 0,
		Luck = 0,
		CardSlots = 0,
		Coins = 0,
		Speed = 0,
	},

	-- Unclaimed gifts one player may have. Only enforced when a gift STARTS: a paid
	-- gift is never refused at receipt time.
	MAX_INBOX = 25,

	-- Claimed gift ids kept for dedupe, and unseen toasts kept for the UI.
	RECEIVED_CAP = 300,
	UNSEEN_CAP = 20,

	-- Only friends of the buyer can be gifted.
	FRIENDS_ONLY = false,

	-- A claim that could not complete (e.g. currency not ready) is retried.
	DELIVER_RETRY_DELAY = 15,
	DELIVER_MAX_ATTEMPTS = 3,

	-- How long the offline short session waits for the profile. Giving up loses
	-- nothing: the message is already queued and applies on the next join.
	OFFLINE_SESSION_TIMEOUT = 15,
}