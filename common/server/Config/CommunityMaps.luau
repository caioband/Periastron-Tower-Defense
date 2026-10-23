--[[
	The community catalog: maps players published from the Map Editor, listed in the
	Lobby's `ChooseMaps.CommunityMaps` panel.

	The map content stays where `Config.PlayerMaps` puts it; this only adds what other
	players see of a map (name, author, description, counters) and the orderings the
	panel sorts by.

	See docs/common/community-maps.md.
]]

return {
	--[[
		The DataStore with one entry per published map, under the map's own key
		(`PlayerMapService.MapKey`), plus the `CATALOG_KEY` entry used by search.
		Each sortable counter also has an OrderedDataStore named
		`<STORE_NAME>_<Stat>`. **Changing it empties the catalog.**
	]]
	STORE_NAME = "CommunityMaps_v1",

	-- The entry with every published map's name and author, which search reads.
	CATALOG_KEY = "catalog",

	--[[
		The counters a map carries, which are also what the panel sorts by. The
		Lobby's `CommunityMapsController` lists the same names in its filter buttons:
		a name the server does not know falls back to `DEFAULT_STAT`.
	]]
	STATS = { "Likes", "Visits", "Favorites", "Plays" },

	-- The order a list opens with.
	DEFAULT_STAT = "Likes",
	DEFAULT_ASCENDING = false,

	-- Maps per page sent to the client.
	PAGE_SIZE = 20,

	-- How long a sorted listing and a map's entry are reused before being read
	-- again. Shared by every player on the server.
	QUERY_CACHE_TIME = 60,
	META_CACHE_TIME = 60,

	-- How often the likes, visits, and favorites counted on this server are written.
	-- They add up in memory in between, so a popular map is not one write per click.
	FLUSH_INTERVAL = 30,

	-- Attempts per DataStore call before giving up, with 1 s, 2 s, ... between them.
	RETRIES = 3,

	-- Entries in `PlayerMaps.Likes`. It lives in the profile, so it needs a cap.
	MAX_LIKES = 1000,

	-- Longest text accepted in the search box and as a map description.
	MAX_SEARCH_LENGTH = 40,
	MAX_DESCRIPTION_LENGTH = 200,

	-- Search answers at most this many maps.
	MAX_SEARCH_RESULTS = 100,

	-- Requests a player may have waiting on the DataStore at once.
	MAX_PENDING_REQUESTS = 2,

	--[[
		Whether playing and editing community maps works in Production too. Off: only
		the QA universe opens community groups and sends players to the Map Editor
		(which Production does not have yet).
	]]
	PRODUCTION_ENABLED = false,

	--[[
		A match on a community map pays this fraction of the coins, shards, and XP, and
		counts for no win, leaderboard, contract, event pumpkin, or Index entry: anyone
		can publish an easy map, so it must not be a farm. See docs/game/community-matches.md.
	]]
	REWARD_MULTIPLIER = 0,
}
