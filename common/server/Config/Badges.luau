--[[
	Os badges da Roblox que o jogo entrega. Quem lê é o `BadgeService` (common).

	Cada entrada é `Nome = BadgeId`. O nome é o que o código passa para
	`BadgeService:Award(player, "Nome")`, e o id é o número que aparece em
	create.roblox.com → Badges. O badge tem de ser deste universo, senão o
	`AwardBadge` falha.

	Para um badge novo: crie no site, ponha uma linha aqui e chame o `Award` de onde
	a conquista acontece (as duas places enxergam esta tabela).
]]

return {
	-- Primeira vez no jogo. Dado pelo `WelcomeBadgeService` do Lobby, ao entrar.
	Welcome = 4332443148752915,
}
