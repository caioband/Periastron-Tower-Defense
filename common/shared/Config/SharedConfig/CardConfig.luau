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
	Hoje é o caso do `Subspace Tripminer` e do `Archer` — e como a arte autorada é a
	do Slasher, os dois aparecem com a carta dele até o id chegar. É aqui que se
	conserta, uma linha por unidade.

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

--[[
	O retrato da unidade no card de upgrade — o `Info` de
	`Interface.CardUpgrade`, a moldura onde ficam o nome e o nível.

	É outra arte que a de `Images`: aquela é a carta inteira da hotbar, esta é só o
	rosto, num quadrado pequeno. Elas vivem no mesmo módulo porque são a mesma
	pergunta ("como esta unidade aparece na tela?") e erram pelo mesmo motivo — a
	chave é o nome de `UnitStats`, e não o nome que o jogador lê na arte: o retrato
	do **Gladiator** é da unidade `Sword`, e o do **Rocketeer** é da `Rocket`.

	Unidade sem entrada aqui fica com a arte que o designer deixou autorada no
	`Info` — quem desenha guarda esse padrão e volta para ele. Esconder não é opção
	como no `ClassIcon`: o `Info` carrega o nome e o nível da unidade dentro dele, e
	sumir com a moldura levaria os dois junto.

	Faltam Azure, Slingshot, Subspace Tripminer e Archer. É aqui que se conserta,
	uma linha por unidade.

	O **Berserker** já tem a carta dele em `Images`, mas ainda não o retrato: o id
	aqui é o do Slasher, provisório, e é uma linha para trocar quando a arte do
	quadradinho existir.
]]
CardConfig.Icons = {
	Slasher = "rbxassetid://77799937837921",
	Entrepreneur = "rbxassetid://97283177894419",
	Sword = "rbxassetid://77707891613366",

	-- Provisório: é o retrato do Slasher, e não o dele. Ver a nota acima.
	Berserker = "rbxassetid://77799937837921",
	Rocket = "rbxassetid://119165882760846",
}

--[=[
	O `rbxassetid` do retrato da unidade no card de upgrade, ou `nil` quando ela
	ainda não tem um.
]=]
function CardConfig.GetIcon(unitName : string?) : string?
	if not unitName then
		return nil
	end

	return CardConfig.Icons[unitName]
end

--[[
	A arte da unidade no index, nos dois estados.

	É a terceira arte da mesma pergunta que as outras duas deste módulo ("como esta
	unidade aparece na tela?"), e a única que vem em par: `Unlocked` é a unidade
	como ela é, `Locked` é a silhueta de quem ainda não a descobriu. Quem decide
	qual das duas vale é o `Index` do perfil (`SharedConfig.IndexConfig`) — a arte
	não sabe de nada, ela só tem as duas caras.

	Quem lê hoje é o carretel do unboxing, que mostra o elenco do pool enquanto gira
	e passa preta a unidade que o jogador ainda não viu. Uma tela de index propriamente
	dita lê exatamente daqui também.

	A chave é o nome de `UnitStats`, como nas outras tabelas — o par do **Rocketeer**
	é da unidade `Rocket`, o do **Gladiator** é da `Sword`.

	Unidade sem entrada aqui não recebe imagem nenhuma, e a carta do carretel fica
	só com a moldura na cor da raridade. Hoje é o caso da `Azure`, que também não sai
	de caixa (`ServerScriptService.Config.Crate.EXCLUDED_UNITS`) — quando ela ganhar
	uma porta de entrada, é uma linha aqui.
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
}

--[=[
	A arte de index da unidade no estado pedido, ou `nil` quando ela nao tem par.

	`discovered` e o que o `Index` do perfil responde: verdadeiro mostra a unidade,
	falso mostra a silhueta.
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
