local LobbyNPCConfig = {}

LobbyNPCConfig.NodeFolders = { "NPCNodes", "NPCNodesBack" }

LobbyNPCConfig.FriendCount = { Min = 8, Max = 9 }

LobbyNPCConfig.FallbackUserIds = {}

LobbyNPCConfig.Animations = {
	Idle = "rbxassetid://127098135841566",
	Walk = "rbxassetid://114495719891069",
	WalkReferenceSpeed = 12,
	FadeTime = 0.2,
}

LobbyNPCConfig.Movement = {
	WalkSpeed = 8,
	ArriveDistance = 2.5,
	DestinationPauseChance = 0.6,
	IntermediatePauseChance = 0.05,
	PauseTime = { Min = 1.5, Max = 5 },
	MinRouteNodes = 3,
	Spread = 2,
	ReissueInterval = 2,
}

LobbyNPCConfig.Interaction = {
	NoticeRadius = 8,
	ReleaseRadius = 11,
	ResumeDelay = 1.5,
	TurnSpeed = 8,
	PromptText = "Talk to NPC",
	PromptKey = Enum.KeyCode.E,
	TalkDelay = 0.15,
}

LobbyNPCConfig.Bubble = {
	Offset = Vector3.new(0, 1.5, 0),
	Interval = 0.6,
}

LobbyNPCConfig.Display = {
	NameDistance = 40,
	NameColor = "255,210,90",
}

LobbyNPCConfig.Dialog = {
	Blur = false,
}

LobbyNPCConfig.CollisionGroups = {
	NPC = "LobbyNPC",
	Player = "LobbyPlayer",
}

LobbyNPCConfig.Server = {
	SharedFolder = "LobbyNPCs",
	StaffFolder = "Staff",
	TemplateName = "Template",
	WorkspaceTemplate = "npc",
	PlayerFolder = "LobbyNPCTemplates",
	MaxFriendsScanned = 200,
	BuildInterval = 0.15,
	DescriptionCacheSize = 150,
}

LobbyNPCConfig.Staff = {
	{
		Key = "Gode",
		UserId = 1038697440,
		DisplayName = "Gode",
		Lines = {
			{
				"Hey {player}! I'm Gode, the [color=255,150,40]owner[/color] of Periastron TD.",
				"Thanks for playing, it genuinely means a lot.",
			},
			{
				"Owner life is mostly saying [wiggle]\"one more update\"[/wiggle] at 3am.",
				"Go win some matches, I'll be watching the leaderboards.",
			},
			{
				"Yeah, I own this place.[pause=0.5] Please don't tell Caio I said that.",
			},
			{
				"Before you ask:[pause=0.4] no, I can't give you free Robux.",
				"I can give you a [wiggle]really good game[/wiggle] though.",
			},
			{
				"Sometimes I just walk around the lobby to see what everyone's up to.",
				"Nice avatar by the way, {player}.",
			},
		},
	},
	{
		Key = "Caio",
		UserId = 46871391,
		DisplayName = "Caio",
		Lines = {
			{
				"Yo {player}, I'm Caio, [color=60,150,255]one of the devs[/color] on Periastron TD.",
				"If something breaks, it was definitely a feature.",
			},
			{
				"I helped build half the stuff you're walking past right now.",
				"Try Nightmare when you're ready.[pause=0.4] [shake]If[/shake] you're ready.",
			},
			{
				"Dev tip: the weather warnings give you 3 waves of notice. Use them.",
			},
			{
				"Found a bug? Tell us in the Discord.",
				"Found a [shake]really cool[/shake] bug? Maybe keep that one between us.",
			},
			{
				"I play-tested this game so much I dream in tower ranges.",
			},
		},
	},
	{
		Key = "AuthoryI",
		UserId = 4133615556,
		DisplayName = "AuthoryI",
		Lines = {
			{
				"Hi {player}! I'm AuthoryI, [color=170,90,255]one of the scripters[/color] here.",
				"It works on my machine.[pause=0.5] Usually.",
			},
			{
				"I write a lot of the code behind the towers and systems.",
				"If a tower does something weird, I was never here.",
			},
			{
				"Every NPC walking around this lobby? Scripted.[pause=0.4] Including me.",
			},
			{
				"I don't have bugs.[pause=0.4] I have [wiggle]undocumented features[/wiggle].",
			},
			{
				"I Never intentonally code bugs..[pause=0.8]",
				"...totally.",
			},
		},
	},
}

LobbyNPCConfig.Lines = {
	{
		"Have you tried the [color=255,125,60]Halloween event[/color] yet?",
		"Pumpkins drop in matches, trade them at the spooky shop!",
	},
	{
		"Heads up: [color=135,220,255]BLIZZARD[/color] freezes your towers every so often.",
		"Magic units don't care though.",
	},
	{
		"Rain puts out [color=255,125,60]Fire[/color] units completely.",
		"Bring some Ice if you see it coming.",
	},
	{
		"I finally unlocked Pale Garden.[pause=0.4] Sixteen wins. [wiggle]Sixteen.[/wiggle]",
	},
	{
		"The contracts board has hourly, daily and weekly missions.",
		"Free coins, shards and crates if you check it often.",
	},
	{
		"Level up to unlock more deck slots. The 6th one opens at level 25.",
	},
	{
		"Thunder can stun your towers for 20 seconds!",
		"Electric units actually get stronger when they get hit though.",
	},
	{
		"I pulled a [color=200,130,255]Cosmic[/color] once.[pause=0.5] Once.",
	},
	{
		"Endless mode is where the real grinders hang out.",
		"How far can you get, {player}?",
	},
	{
		"Runes boost your coins, XP and luck for a while.",
		"Check the rune shop round the back.",
	},
	{
		"Fog cuts your tower range. Magic gets hit even harder.",
	},
	{
		"Nightmare only gives you 3 leaks.[pause=0.4] [shake]THREE.[/shake]",
	},
	{
		"Join a portal with friends, it's way easier with a full team.",
	},
	{
		"Nice avatar, {player}.[pause=0.4] Did that cost you all your Robux?",
	},
	{
		"Can I have 1 Robux?[pause=0.6] ...No?[pause=0.4] Worth a shot.",
	},
	{
		"Oof.[pause=0.5] Sorry, old habits.",
	},
	{
		"Brb, my mom's calling me for dinner.[pause=0.6] Jk, I'm an NPC. I don't eat.",
	},
	{
		"Bro I've been AFK in this lobby for like three hours.",
		"Don't tell the AFK area, it gets jealous.",
	},
	{
		"Free Robux?[pause=0.5] [shake]Nope.[/shake] Not falling for that one again.",
	},
	{
		"Trade you my Slasher for your Archmage?[pause=0.6]",
		"...Fair trade, right? [wiggle]Right?[/wiggle]",
	},
	{
		"My Wi-Fi is so bad I lagged into a wall earlier.",
	},
	{
		"I've been walking in circles for ages.[pause=0.4] Literally.",
	},
	{
		"Don't tell anyone, but I still use the classic face.",
	},
	{
		"Who else is grinding for that Cosmic?",
		"Respect the grind, {player}.",
	},
	{
		"Is it just me or is it [wiggle]always[/wiggle] Halloween in here?",
	},
	{
		"Brb, getting snacks.[pause=0.6] ...I'll be right here though. Forever.",
	},
	{
		"gg wp, {player}.[pause=0.4] Wait, we haven't played yet.",
	},
	{
		"Hey {player}! Wanna party up for a Nightmare run?",
		"I'll carry.[pause=0.5] Probably.",
	},
	{
		"I tried to jump but I forgot NPCs can't jump.",
	},
}

LobbyNPCConfig.FriendLines = {
	{
		"Yooo {player}! Fancy seeing you here.",
	},
	{
		"Add me as a friend![pause=0.6] Wait,[pause=0.3] aren't we already friends?",
	},
	{
		"We should actually play together sometime, {player}.",
		"For real this time, not \"next week\".",
	},
	{
		"Remember when we said we'd beat Nightmare?[pause=0.5]",
		"Yeah, me neither.",
	},
	{
		"{player}! You left me on read.[pause=0.5] In my own lobby.",
	},
	{
		"Ayy, it's {player}! Carry me pls.",
	},
}

return LobbyNPCConfig