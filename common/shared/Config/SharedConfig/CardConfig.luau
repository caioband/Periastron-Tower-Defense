--[[
	Each unit's card art in the match hotbar.

	The `CardWrapper`'s `Card` is an ImageLabel whose art is the **whole card**:
	frame, illustration, and background in one image. So the key is the unit, not
	the class; `ClassConfig` is the Melee/Ranged/Magic icon on the upgrade card,
	a different thing.

	The `Card` component (`Game/src/Controllers/UILibraryController/Components`)
	writes it in the same pass as the name and cost; `CardController` decides
	*which* cards appear.

	> Keys are `UnitStats` names, which are not always the name on the art: the
	> **Rocketeer** card belongs to `Rocket`, and the **Gladiator** to `Sword`. A
	> wrong key breaks nothing; the unit just lacks its own art, which is the
	> hardest symptom to trace back.

	A unit without an entry keeps the art authored on the `CardWrapper` in
	StarterGui: a card with the wrong art is better than an invisible card.
]]

local CardConfig = {}

CardConfig.Images = {
	Slasher = "rbxassetid://75123400726970",
	Rocket = "rbxassetid://109642138105636",
	Entrepreneur = "rbxassetid://130898800672794",
	Sword = "rbxassetid://78316687499130",

	Berserker = "rbxassetid://100567564561177",
	Azure = "rbxassetid://117289931783490",
	Slingshot = "rbxassetid://101061040163272",
	Archer = "rbxassetid://95837523891408",
	["Subspace Tripminer"] = "rbxassetid://106851377383587",
	Electro = "rbxassetid://105460799994551",
	Frostione = "rbxassetid://119338340194654",
	Archmage = "rbxassetid://137825632441679",
	Pyre = "rbxassetid://111515366066023",
	Bonfire = "rbxassetid://139271145798062",
	Cryomancer = "rbxassetid://109821143712853",
	Vindicator = "rbxassetid://130740288231397",

}

--[=[
	The unit's card `rbxassetid`, or `nil` when it has no art of its own yet.
]=]
function CardConfig.GetImage(unitName : string?) : string?
	if not unitName then
		return nil
	end

	return CardConfig.Images[unitName]
end

--[[
	The unit's portrait on the upgrade card: the `Info` of `Interface.CardUpgrade`,
	the frame that holds the name and level.

	It is different art from `Images`: that is the whole hotbar card, this is just
	the face in a small square. They live in the same module because they answer
	the same question ("how does this unit look on screen?") and go wrong the same
	way: the key is the `UnitStats` name, not the name on the art (the
	**Gladiator** portrait belongs to `Sword`, the **Rocketeer** to `Rocket`).

	A unit without an entry keeps the art authored on `Info`; the UI keeps that
	default and falls back to it. Hiding is not an option as with `ClassIcon`:
	`Info` holds the unit's name and level.

	The Azure is missing. Fix it here, one line per unit.
]]
CardConfig.Icons = {
	Slasher = "rbxassetid://77799937837921",
	Entrepreneur = "rbxassetid://97283177894419",
	Sword = "rbxassetid://77707891613366",
	Berserker = "rbxassetid://122236769508129",
	Rocket = "rbxassetid://119165882760846",

	Electro = "rbxassetid://97063910778003",
	Frostione = "rbxassetid://73183225566473",
	Slingshot = "rbxassetid://121913498884239",
	Pyre = "rbxassetid://116877116738728",
	["Subspace Tripminer"] = "rbxassetid://130513046357852",
	Archmage = "rbxassetid://114668138717801",
	Archer = "rbxassetid://111421285376457",
	Bonfire = "rbxassetid://116877116738728", -- TODO: Replace with actual art
	Vindicator = "rbxassetid://77799937837921" -- TODO: Replace with actual art

}

--[=[
	The `rbxassetid` of the unit's upgrade card portrait, or `nil` when it has none.
]=]
function CardConfig.GetIcon(unitName : string?) : string?
	if not unitName then
		return nil
	end

	return CardConfig.Icons[unitName]
end

--[[
	The unit's index art, in both states.

	The third art for the same question as the other two in this module, and the
	only one in a pair: `Unlocked` is the unit as it is, `Locked` is the silhouette
	for a player who has not discovered it. The profile's `Index`
	(`SharedConfig.IndexConfig`) decides which applies; the art knows nothing.

	Today the unboxing reel reads it, showing the pool's cast while it spins and
	blacking out units the player has not seen. An index screen would read from
	here too.

	The key is the `UnitStats` name, as in the other tables (the **Rocketeer** pair
	belongs to `Rocket`, the **Gladiator** to `Sword`).

	A unit without an entry gets no image, and its reel card keeps only the frame
	in its rarity color. Today that is the `Azure`, which also does not drop from
	crates (`ServerScriptService.Config.Crate.EXCLUDED_UNITS`).
]]
CardConfig.IndexImages = {
	Archer = { Locked = "rbxassetid://121305756386879", Unlocked = "rbxassetid://126669235258665" },
	Sword = { Locked = "rbxassetid://98510105775698", Unlocked = "rbxassetid://125051466447818" },
	["Subspace Tripminer"] = { Locked = "rbxassetid://98826991396331", Unlocked = "rbxassetid://112061750256135" },
	Slasher = { Locked = "rbxassetid://85390408287558", Unlocked = "rbxassetid://117122566419692" },
	Slingshot = { Locked = "rbxassetid://115704584760654", Unlocked = "rbxassetid://92341340394555" },
	Rocket = { Locked = "rbxassetid://115737289351232", Unlocked = "rbxassetid://138706217718590" },
	Berserker = { Locked = "rbxassetid://113406675089719", Unlocked = "rbxassetid://136437855682464" },
	Entrepreneur = { Locked = "rbxassetid://114643462066100", Unlocked = "rbxassetid://96216096014823" },
	Electro = { Locked = "rbxassetid://83094354840437", Unlocked = "rbxassetid://82433128727107" },
	Frostione = { Locked = "rbxassetid://80161422857290", Unlocked = "rbxassetid://131404225317311" },
	Archmage = { Locked = "rbxassetid://125536412737882", Unlocked = "rbxassetid://140669373263625" },
	Pyre = { Locked = "rbxassetid://99768598031119", Unlocked = "rbxassetid://130443019837476" },
	Bonfire = { Locked = "rbxassetid://95440009266771", Unlocked = "rbxassetid://133228010596030" },
	Cryomancer = { Locked = "rbxassetid://88227960714771", Unlocked = "rbxassetid://88118640086913" },
	Vindicator = { Locked = "rbxassetid://83846373389394", Unlocked = "rbxassetid://83026555203229" },

}

--[=[
	The unit's index art in the requested state, or `nil` when it has no pair.

	`discovered` is what the profile's `Index` answers: true shows the unit, false
	shows the silhouette.
]=]
function CardConfig.GetIndexImage(unitName : string?, discovered : boolean?) : string?
	if not unitName then
		return nil
	end

	local pair = CardConfig.IndexImages[unitName]
	if not pair then
		return nil
	end

	return if discovered then pair.Unlocked else pair.Locked
end

return CardConfig
