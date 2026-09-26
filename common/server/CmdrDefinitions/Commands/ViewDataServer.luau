local ServerScriptService = game:GetService("ServerScriptService")

local ServerConfig = require(ServerScriptService:WaitForChild("Config"))
local ProfileStore = require(ServerScriptService:WaitForChild("Vendor"):WaitForChild("ProfileStore"))

--[[
	`viewdata`: lê o perfil salvo de um jogador sem abrir sessão.

	É o `ProfileStore:GetAsync` (modo leitura): não trava o perfil, não salva nada,
	e funciona com o jogador fora do servidor. Serve para olhar uma store velha
	(`PROD_KEY_1`, depois da troca da `PROFILE_KEY`) ou uma versão antiga pela data —
	o DataStore guarda as versões de cada chave por um tempo (hoje, 30 dias), e o
	`VersionQuery` pega a última salva até a data pedida.

	A resposta vai para o console do Cmdr e, inteira, para o log do servidor (F9 →
	Server), que é mais fácil de copiar.
]]

local MAX_DEPTH = 12

local function parseDate(text : string) : number?
	local y, m, d, rest = string.match(text, "^(%d%d%d%d)%-(%d%d?)%-(%d%d?)(.*)$")
	if not y then
		return nil
	end

	local hour, minute = 23, 59
	if rest ~= "" then
		local h, mi = string.match(rest, "^[T ](%d%d?):(%d%d)$")
		if not h then
			return nil
		end
		hour, minute = tonumber(h), tonumber(mi)
	end

	local ok, dateTime = pcall(DateTime.fromUniversalTime, tonumber(y), tonumber(m), tonumber(d), hour, minute, 59)
	return ok and dateTime.UnixTimestampMillis or nil
end

local function formatTime(seconds : number?) : string
	if not seconds or seconds == 0 then
		return "?"
	end
	return DateTime.fromUnixTimestamp(seconds):FormatUniversalTime("YYYY-MM-DD HH:mm", "en-us") .. " UTC"
end

local function formatMillis(millis : number?) : string
	return millis and formatTime(millis // 1000) or "?"
end

-- Dump legível, chaves em ordem, para dar para comparar duas versões a olho.
local function dump(value : any, indent : string, depth : number, out : { string })
	if typeof(value) ~= "table" then
		table.insert(out, typeof(value) == "string" and string.format("%q", value) or tostring(value))
		return
	end

	if next(value) == nil then
		table.insert(out, "{}")
		return
	end

	if depth >= MAX_DEPTH then
		table.insert(out, "{...}")
		return
	end

	local keys = {}
	for key in value do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		if typeof(a) == typeof(b) and (typeof(a) == "number" or typeof(a) == "string") then
			return a < b
		end
		return typeof(a) < typeof(b)
	end)

	local inner = indent .. "  "
	table.insert(out, "{\n")
	for _, key in keys do
		table.insert(out, inner .. tostring(key) .. " = ")
		dump(value[key], inner, depth + 1, out)
		table.insert(out, "\n")
	end
	table.insert(out, indent .. "}")
end

return function(_context, userId : number, storeName : string?, dateText : string?)
	if not storeName or storeName == "" or string.lower(storeName) == "current" then
		storeName = ServerConfig.Data.PROFILE_KEY
	end

	local maxDate
	if dateText and dateText ~= "" then
		maxDate = parseDate(dateText)
		if not maxDate then
			return `Invalid date "{dateText}". Use YYYY-MM-DD or YYYY-MM-DDTHH:MM (UTC).`
		end
	end

	local profileKey = "Player_" .. userId
	local ok, profile = pcall(function()
		-- Template vazio: é leitura, e o que interessa é o que está salvo, não o que
		-- faltaria para o template de hoje. Dentro do pcall porque o `New` erra com
		-- nome de store inválido (vazio ou mais de 50 caracteres).
		local store = ProfileStore.New(storeName, {})

		if maxDate then
			return store:VersionQuery(profileKey, Enum.SortDirection.Descending, nil, maxDate):NextAsync()
		end
		return store:GetAsync(profileKey)
	end)

	if not ok then
		return `Failed to read {storeName}/{profileKey}: {profile}`
	end
	if not profile then
		local when = maxDate and ` up to {formatMillis(maxDate)}` or ""
		return `No saved profile for {profileKey} in store "{storeName}"{when}.`
	end

	local keyInfo = profile.KeyInfo
	local header = table.concat({
		`Store: {storeName}   Key: {profileKey}`,
		`Version saved: {formatMillis(keyInfo and keyInfo.UpdatedTime)}   (version id: {keyInfo and keyInfo.Version or "?"})`,
		`Profile created: {formatTime(profile.FirstSessionTime)}   Sessions: {profile.SessionLoadCount}`,
	}, "\n")

	local out = {}
	dump(profile.Data, "", 0, out)
	local body = table.concat(out)

	print(`[viewdata]\n{header}\n{body}`)

	return `{header}\n{body}`
end
