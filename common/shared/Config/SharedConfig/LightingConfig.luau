--[[
	Presets de Lighting.

	Um preset é uma Folder dentro de `ReplicatedStorage.Shared.Assets.Lighting`:

		Assets.Lighting
		└── Blizzard              (Folder)
			│   atributos: Ambient, Brightness, ClockTime, FogColor, ...
			├── Atmosphere        (Atmosphere)
			├── Sky               (Sky)
			└── ColorCorrection   (ColorCorrectionEffect)

	Os **atributos** da Folder viram propriedades do próprio `Lighting`; os
	**filhos** são as instâncias que vão para dentro dele. O `LightingService`
	troca o conteúdo de uma vez e o `LightingController` transforma a troca em
	transição, interpolando o que dá para interpolar.

	Fica em `common/` porque as duas places usam.
]]

local LightingConfig = {}

-- Onde os presets moram. Caminho a partir de `ReplicatedStorage`; o service cria
-- a pasta se ela não existir.
LightingConfig.PresetsPath = { "Shared", "Assets", "Lighting" }

--[[
	Nome do preset que o service monta na entrada, a partir do Lighting que veio
	autorado na place. Existir garante que toda transição seja preset -> preset:
	o cliente sempre tem de onde ler os valores de origem, mesmo na primeira troca.
]]
LightingConfig.BaselineName = "Default"

--[[
	Preset aplicado assim que o servidor sobe. `nil` = fica com o baseline.

	Cuidado na Game: o `MapService` aplica a pasta `Lighting` do mapa durante o
	carregamento, e o `start` do service roda depois disso — preencher aqui
	sobrescreveria a iluminação do mapa.
]]
LightingConfig.DefaultPreset = nil :: string?

--[[
	Prefixo do preset que o `MapService` registra a partir da pasta `Lighting` do
	mapa. Serve para o nome de um mapa nunca esbarrar num preset autorado à mão:
	`Assets.Lighting.Map_Farm` é claramente do mapa, `Assets.Lighting.Farm` não.
]]
LightingConfig.MapPrefix = "Map_"

--[[
	Filho do Lighting com este atributo em `true` sobrevive ao clear — para algo
	que outro sistema pendurou lá e não faz parte de preset nenhum (um BlurEffect
	de menu, por exemplo).
]]
LightingConfig.KeepAttribute = "LightingKeep"

LightingConfig.Transition = {
	Time = 1.5,
	Style = Enum.EasingStyle.Quad,
	Direction = Enum.EasingDirection.Out,
}

--[[
	Quais propriedades cada classe expõe à transição.

	Roblox não tem reflection em runtime — não dá para perguntar a uma instância
	quais são as propriedades dela — então a lista é na mão. Classe que não estiver
	aqui entra no Lighting normalmente, só não é interpolada: para uma classe nova
	participar da transição, basta acrescentar a entrada.

	`TimeOfDay` está fora de propósito: é o mesmo valor de `ClockTime` em string, e
	as duas juntas só brigariam por quem escreve por último.
]]
LightingConfig.Properties = {
	Lighting = {
		"Ambient",
		"Brightness",
		"ColorShift_Bottom",
		"ColorShift_Top",
		"EnvironmentDiffuseScale",
		"EnvironmentSpecularScale",
		"GlobalShadows",
		"OutdoorAmbient",
		"ShadowSoftness",
		"ClockTime",
		"GeographicLatitude",
		"ExposureCompensation",
		"FogColor",
		"FogEnd",
		"FogStart",
	},

	Atmosphere = {
		"Density",
		"Offset",
		"Color",
		"Decay",
		"Glare",
		"Haze",
	},

	Sky = {
		"CelestialBodiesShown",
		"MoonAngularSize",
		"MoonTextureId",
		"SkyboxBk",
		"SkyboxDn",
		"SkyboxFt",
		"SkyboxLf",
		"SkyboxRt",
		"SkyboxUp",
		"StarCount",
		"SunAngularSize",
		"SunTextureId",
	},

	ColorCorrectionEffect = {
		"Enabled",
		"Brightness",
		"Contrast",
		"Saturation",
		"TintColor",
	},

	BloomEffect = {
		"Enabled",
		"Intensity",
		"Size",
		"Threshold",
	},

	BlurEffect = {
		"Enabled",
		"Size",
	},

	SunRaysEffect = {
		"Enabled",
		"Intensity",
		"Spread",
	},

	DepthOfFieldEffect = {
		"Enabled",
		"FarIntensity",
		"FocusDistance",
		"InFocusRadius",
		"NearIntensity",
	},
}

--[[
	O valor de cada classe que significa "este efeito não está fazendo nada".

	É o que permite uma instância **entrar e sair** interpolando em vez de piscar.
	Trocar de mapa mexe muito mais em quais efeitos existem do que nos valores dos
	que continuam existindo — sem isto, a maior parte da mudança visual é um corte
	seco por mais que o resto esteja interpolando.

	Só entram as propriedades que controlam intensidade. `Atmosphere.Color` não
	precisa estar aqui, por exemplo: com `Density = 0` ela já não pinta nada.

	Classe sem entrada aqui aparece e some de uma vez, e é o certo: `Sky` é textura,
	não tem meio-caminho.
]]
LightingConfig.Neutral = {
	Atmosphere = {
		Density = 0,
		Haze = 0,
		Glare = 0,
	},

	ColorCorrectionEffect = {
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
		TintColor = Color3.new(1, 1, 1),
	},

	BloomEffect = {
		Intensity = 0,
	},

	BlurEffect = {
		Size = 0,
	},

	SunRaysEffect = {
		Intensity = 0,
	},

	DepthOfFieldEffect = {
		FarIntensity = 0,
		NearIntensity = 0,
	},
}

function LightingConfig:GetProperties(className: string): { string }
	return self.Properties[className] or {}
end

--[[
	Cópia de `values` com as propriedades de intensidade zeradas — o ponto de
	partida de quem entra e o ponto de chegada de quem sai. Classe sem neutro volta
	`values` intacto, e aí não sobra nada para interpolar.
]]
function LightingConfig:GetNeutral(className: string, values: { [string]: any }): { [string]: any }
	local neutral = self.Neutral[className]
	if not neutral then
		return values
	end

	local result = table.clone(values)
	for propertyName, value in neutral do
		if result[propertyName] ~= nil then
			result[propertyName] = value
		end
	end

	return result
end

return LightingConfig
