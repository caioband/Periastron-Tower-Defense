local UIUtil = {}

local SUFFIXES = {"", "K", "M", "B", "T", "Qa", "Qi"}

function UIUtil.formatAbbreviated(num: number): string
	if num < 1000 then return tostring(num) end

	local visibleIdx = math.floor(math.log10(num) / 3)
	local suffixIdx = math.clamp(visibleIdx + 1, 1, #SUFFIXES)
	local suffix = SUFFIXES[suffixIdx]

	local abbreviated = num / (10 ^ (visibleIdx * 3))

	if abbreviated % 1 == 0 then
		return string.format("%d%s", abbreviated, suffix)
	else
		return string.format("%.2f%s", abbreviated, suffix):gsub("%.?0+$", "")
	end
end

function UIUtil.formatCommas(num: number): string
	local formatted = tostring(num)
	local k

	while true do
		formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
		if k == 0 then break end
	end

	return formatted
end

return UIUtil
