return {
	Name = "gift",
	Aliases = { "giftpass" },
	Description = "Test gifting: sends a gift product from you to a player, skipping the Robux prompt, and logs sender and receiver.",
	Group = "Gifting",
	Args = {
		{
			Type = "playerIds",
			Name = "user",
			Description = "Who receives the gift: username or #UserId, online or not.",
		},

		{
			Type = "giftItem",
			Name = "product",
			Description = "The gift product (GiftConfig item key). Tab completes.",
		},
	},
}