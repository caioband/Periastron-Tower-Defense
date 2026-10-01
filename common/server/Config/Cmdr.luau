--[[
	Cmdr (admin console) permission rules: SERVER ONLY.

	This list never reaches the client. `CmdrService:IsAdmin()` is the single source
	of truth: it runs in every command's `BeforeRun` hook and also answers the
	`RequestCmdrAccess` event, which `CmdrController` fires only to decide whether to
	show the console (cosmetic).

	The settings the client needs (activation key and place name) live in
	`ReplicatedStorage.Shared.Config.SharedConfig.Cmdr`.

	See docs/common/admin-commands.md.
]]

return {
	--[[
		[UserId] = true. This list rules: anyone here runs commands on any server,
		published or not.

		The other paths below are shortcuts, and none of them holds on its own in a
		published game: `ALLOW_IN_STUDIO` only exists in Studio, and the owner is
		recognized by the `CreatorType` block in `CmdrService:IsAdmin`.
	]]
	ADMIN_USER_IDS = {
		[46871391] = true,   -- caioband
	},

	--[[
		Minimum rank in the group **that owns the place** to count as the owner.

		This place belongs to a group, not a person: without this, `game.CreatorId` is
		the group id, never a player's, and the owner check passed for nobody. That is
		why commands worked only in Studio and not in the live game.

		255 is the group owner and no one else. Lower it to your admins' rank if you
		want the group leadership to run commands too.
	]]
	CREATOR_GROUP_MIN_RANK = 255,

	-- An extra group, unrelated to the place owner. Leave GROUP_ID nil to turn it off.
	GROUP_ID = nil :: number?,
	GROUP_MIN_RANK = 200,

	--[[
		Commands **every player** may run in the QA environment, keyed by the
		command's `Name`. In QA everyone is a tester, so they can set up the state they
		want to test (coins, shards, units, level, round cash) without an admin.

		QA is its own universe with its own DataStores, so these commands, even aimed
		at another player or an offline profile, never touch a production profile.
		In Production this list does nothing. A command that does not exist in the
		current place (`roundcash` in the Lobby) is simply not offered.

		The environment comes from `Shared.Util.Environment`; see
		docs/common/environments.md.
	]]
	QA_COMMANDS = {
		cash = true,
		shards = true,
		units = true,
		level = true,
		roundcash = true,
		friendinvite = true,
		friendinvitestats = true,
	} :: { [string]: boolean },

	--[[
		Commands allowed for non-admins, by rank in a group.

		**Empty on purpose: outside QA, only admins run commands.** With no command
		accessible, `GetAccessibleCommands` returns an empty list and the console does
		not even appear for them (see `CmdrService`).

		The mechanism stays in place for when it is needed again: the key is the
		command's `Name` (not the alias or the `Group`). `units` shares the "Currency"
		group with `cash` and `shards`, and only it would be allowed. Anyone matching
		here runs that command and no other; admins still run everything.
	]]
	COMMAND_PERMISSIONS = {} :: { [string]: { groupId: number, minRank: number } },

	-- Anyone testing in Studio counts as an admin.
	ALLOW_IN_STUDIO = true,

	-- Built in cmdr command groups that get registered.
	DEFAULT_COMMAND_GROUPS = {
		"DefaultUtil",
		"DefaultAdmin",
		"DefaultDebug",
		"Help",
	},
}
