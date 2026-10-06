--[[
	Gifting tunables (`GiftService`). Server only.
]]
return {
	-- Between two gift requests from one player. Each request saves the buyer's
	-- profile before the prompt opens, so keep this above ProfileStore's save spacing.
	REQUEST_COOLDOWN = 6,

	-- Between two recipient lookups from one player (web calls).
	LOOKUP_COOLDOWN = 2,

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