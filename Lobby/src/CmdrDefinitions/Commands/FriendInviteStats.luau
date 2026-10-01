return {
	Name = "friendinvitestats",
	Aliases = { "invitestats" },
	Description = "Shows the friend invite history in a player's profile: Invite clicks and accepted invites (System, Manual, Total) per friend.",
	Group = "UI",
	Args = {
		{
			Type = "player",
			Name = "player",
			Description = "Whose history to show. Omit for yourself.",
			Optional = true,
		},
	},
}
