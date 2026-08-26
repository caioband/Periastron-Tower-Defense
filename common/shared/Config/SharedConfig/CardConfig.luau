--[[
	A arte da carta de cada unidade, na hotbar da partida.

	O `Card` do `CardWrapper` é um ImageLabel e a arte dele é a **carta inteira** —
	moldura, ilustração e fundo numa imagem só. Por isso a chave aqui é a unidade, e
	não a classe: o `ClassConfig` é o ícone de Melee/Ranged/Magic que entra no card
	de upgrade, uma coisa diferente.

	Quem escreve é o componente `Card`
	(`Game/src/Controllers/UILibraryController/Components`), na mesma passada em que
	ele escreve o nome e o custo — o `CardController` decide *quais* cartas aparecem,
	o componente é quem desenha cada uma.

	> As chaves são os nomes de `UnitStats`, que nem sempre são o nome que o jogador
	> lê na arte: a carta do **Rocketeer** é da unidade `Rocket`, e a do **Gladiator**
	> é da `Sword`. Errar isso não estoura nada — a unidade só fica sem arte própria,
	> que é o sintoma mais difícil de ligar à causa.

	Unidade sem entrada aqui fica com a arte que o `CardWrapper` trouxe autorada do
	StarterGui: carta com a arte errada é melhor do que carta invisível na hotbar.
	Hoje é o caso do `Subspace Tripminer` — e como a arte autorada é a do Slasher,
	ele aparece com a carta dele até o id chegar. É aqui que se conserta, uma linha
	por unidade.
]]

local CardConfig = {}

CardConfig.Images = {
	Slasher = "rbxassetid://75123400726970",
	Rocket = "rbxassetid://109642138105636",
	Entrepreneur = "rbxassetid://130898800672794",
	Sword = "rbxassetid://78316687499130",
	Azure = "rbxassetid://117289931783490",
	Slingshot = "rbxassetid://101061040163272",
}

--[=[
	O `rbxassetid` da carta da unidade, ou `nil` quando ela ainda não tem arte
	própria.
]=]
function CardConfig.GetImage(unitName : string?) : string?
	if not unitName then
		return nil
	end

	return CardConfig.Images[unitName]
end

return CardConfig
