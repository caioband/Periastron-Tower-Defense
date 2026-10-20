--[[
	Where the maps players build in the Map Editor are stored, read by
	`PlayerMapService` in every place.

	The profile (`Data.Template.PlayerMaps`) keeps only the index: ids, names, and
	the keys of maps the player marked. The content of each map and prefab lives in
	the DataStore below, one key per item, so any place can read a map by its key
	without opening the owner's profile.

	See docs/common/player-maps.md.
]]

return {
	--[[
		The DataStore with the content. **Changing it orphans every saved map**: the
		profiles keep pointing at ids whose content is in the old store.
	]]
	STORE_NAME = "PlayerMaps_v1",

	-- Attempts per DataStore call before giving up, with 1 s, 2 s, ... between them.
	RETRIES = 3,

	-- Largest value written to one key. Roblox refuses anything over 4 MB; the
	-- margin covers what DataStore adds on top of the JSON.
	MAX_VALUE_BYTES = 3_800_000,

	-- Entries in `PlayerMaps.Favorites`. The table lives in the profile, which every
	-- other system shares, so it cannot grow without a cap.
	MAX_FAVORITES = 200,
}
