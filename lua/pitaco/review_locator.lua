local M = {}

local SEARCH_WINDOW = 25

local function clamp(value, minimum, maximum)
	return math.max(minimum, math.min(maximum, value))
end

local function score_candidate(lines, index, anchor)
	if type(anchor) ~= "table" then
		return 0
	end

	local score = 0
	local line = lines[index]
	if line ~= nil and anchor.line ~= nil and line == anchor.line then
		score = score + 4
	end

	local previous = lines[index - 1]
	if previous ~= nil and anchor.before ~= nil and previous == anchor.before then
		score = score + 2
	end

	local next_line = lines[index + 1]
	if next_line ~= nil and anchor.after ~= nil and next_line == anchor.after then
		score = score + 2
	end

	return score
end

local function find_best_match(lines, item, start_index, end_index)
	local anchor = item.anchor
	if type(anchor) ~= "table" or type(anchor.line) ~= "string" or anchor.line == "" then
		return nil
	end

	local best_index = nil
	local best_score = 0

	for index = start_index, end_index do
		local score = score_candidate(lines, index, anchor)
		if score > best_score then
			best_score = score
			best_index = index
		end
	end

	if best_score == 0 then
		return nil
	end

	return best_index, best_score
end

function M.resolve(item, lines)
	if type(item) ~= "table" then
		return 1, "fallback"
	end

	if type(lines) ~= "table" or vim.tbl_isempty(lines) then
		local original_line = tonumber(item.original_line) or 1
		return math.max(original_line, 1), "fallback"
	end

	local original_line = tonumber(item.original_line) or 1
	original_line = clamp(original_line, 1, #lines)

	local anchor = item.anchor or {}
	local original_text = lines[original_line]
	if type(anchor.line) == "string" and anchor.line ~= "" and original_text == anchor.line then
		return original_line, "exact"
	end

	local search_start = clamp(original_line - SEARCH_WINDOW, 1, #lines)
	local search_end = clamp(original_line + SEARCH_WINDOW, 1, #lines)
	local nearby_index = find_best_match(lines, item, search_start, search_end)
	if nearby_index ~= nil then
		return nearby_index, "moved"
	end

	local global_index = find_best_match(lines, item, 1, #lines)
	if global_index ~= nil then
		return global_index, "moved"
	end

	return original_line, "fallback"
end

return M
