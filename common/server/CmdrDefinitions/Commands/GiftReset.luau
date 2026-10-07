return {
	Name = "giftreset",
	Aliases = { "resetgifts" },
	Description = "Test cleanup: removes gifted passes and clears the gift tables (inbox, received, outgoing, unseen) of players on this server. QA and Studio only.",
	Group = "Gifting",
	Args = {
		{
			Type = "players",
			Name = "players",
			Description = "Whose gifts to clear. Omit for yourself.",
			Optional = true,
		},
	},
}
