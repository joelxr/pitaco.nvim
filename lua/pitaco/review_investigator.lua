local config = require("pitaco.config")
local prompt_context = require("pitaco.prompt_context")

local M = {}

local function normalize_relative_path(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	local normalized = path:gsub("\\", "/")
	normalized = normalized:gsub("^%./+", "")
	normalized = normalized:gsub("^/+", "")
	return normalized
end

local function to_absolute_path(repo_root, path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	if path:find("^/") then
		return vim.fn.fnamemodify(path, ":p")
	end

	local root = type(repo_root) == "string" and repo_root or vim.fn.getcwd()
	return vim.fn.fnamemodify(root .. "/" .. path, ":p")
end

local function read_file_lines(path)
	local fd = io.open(path, "r")
	if not fd then
		return {}
	end

	local lines = {}
	for line in fd:lines() do
		table.insert(lines, line)
	end
	fd:close()
	return lines
end

local function build_numbered_excerpt(path, center_line, radius)
	local lines = read_file_lines(path)
	if vim.tbl_isempty(lines) then
		return ""
	end

	local target = math.max(1, tonumber(center_line) or 1)
	local span = math.max(24, tonumber(radius) or 80)
	local start_line = math.max(1, target - span)
	local end_line = math.min(#lines, target + span)
	local width = #tostring(end_line)
	local excerpt = {}

	for index = start_line, end_line do
		table.insert(excerpt, string.format("%0" .. width .. "d %s", index, lines[index]))
	end

	return table.concat(excerpt, "\n")
end

local function diff_block_for_file(git_diff, target_file)
	if type(git_diff) ~= "string" or git_diff == "" then
		return ""
	end

	local normalized_target = normalize_relative_path(target_file)
	if normalized_target == nil then
		return ""
	end

	local blocks = {}
	local current = {}
	local capture = false

	for _, line in ipairs(vim.split(git_diff, "\n", { plain = true })) do
		if line:match("^diff %-%-git ") then
			if capture and #current > 0 then
				table.insert(blocks, table.concat(current, "\n"))
			end
			current = { line }
			capture = false

			local old_file, new_file = line:match("^diff %-%-git a/(.-) b/(.-)$")
			if normalize_relative_path(old_file) == normalized_target or normalize_relative_path(new_file) == normalized_target then
				capture = true
			end
		elseif capture then
			table.insert(current, line)
		end
	end

	if capture and #current > 0 then
		table.insert(blocks, table.concat(current, "\n"))
	end

	return table.concat(blocks, "\n\n")
end

local function changed_outline_for_file(changed_outline, target_file)
	local normalized_target = normalize_relative_path(target_file)
	for _, entry in ipairs(changed_outline or {}) do
		if normalize_relative_path(entry.file) == normalized_target then
			return entry
		end
	end
	return nil
end

local function collect_matching_entries(entries, target_file, max_items)
	local normalized_target = normalize_relative_path(target_file)
	local results = {}
	local limit = max_items or 2

	for _, entry in ipairs(entries or {}) do
		local entry_file = normalize_relative_path(entry.file or entry.definition_file)
		if entry_file == normalized_target then
			table.insert(results, entry)
			if #results >= limit then
				break
			end
		end
	end

	return results
end

local function investigation_line(investigation)
	local file = normalize_relative_path(investigation.file)
	local line = (tonumber(investigation.lnum) or 0) + 1
	local message = prompt_context.trim_text(investigation.message)
	if file == nil or message == "" then
		return ""
	end
	return ("file=%s line=%d: %s"):format(file, line, message)
end

function M.build_request(provider, metadata, investigation)
	local target_file = normalize_relative_path(investigation.file or metadata.relative_path)
	local target_path = to_absolute_path(metadata.repo_root, investigation.absolute_path or target_file)
	local excerpt = build_numbered_excerpt(target_path, (tonumber(investigation.lnum) or 0) + 1, 80)
	local changed_entry = changed_outline_for_file(metadata.changed_outline, target_file)
	local diff_excerpt = diff_block_for_file(metadata.git_diff, target_file)
	local file_consumers = collect_matching_entries(metadata.file_consumers, target_file, 2)
	local related_tests = collect_matching_entries(metadata.related_tests, target_file, 2)
	local symbol_usages = collect_matching_entries(metadata.symbol_usages, target_file, 2)

	local sections = {
		"Investigate this suspicious changed area and decide whether it proves a real bug.",
		"",
		"Investigation request:",
		investigation_line(investigation),
		"",
		"Focus on:",
		"- newly added guards, wrappers, returns, or optional checks that may skip existing behavior",
		"- side effects that moved under stricter conditions",
		"- counters, timestamps, DB updates, events, permissions, or authorization state that no longer update",
		"- optional or missing nested data that used to be supported",
		"",
		"Return only final finding lines using the normal review format.",
		"Do not return investigate= lines from this investigation pass.",
		"If the wider evidence does not prove a concrete bug, return an empty response.",
		"",
		("Review mode: %s"):format(metadata.mode or "unknown"),
		("Target file: %s"):format(target_file or "unknown"),
	}

	if changed_entry ~= nil then
		table.insert(sections, "")
		table.insert(sections, "Changed code structure for target file:")
		table.insert(sections, prompt_context.build_compact_changed_outline({ changed_entry }, {
			max_files = 1,
			max_symbols = 6,
		}))
	end

	if excerpt ~= "" then
		table.insert(sections, "")
		table.insert(sections, "Wide source excerpt:")
		table.insert(sections, "```text")
		table.insert(sections, prompt_context.truncate_text_middle(excerpt, 6200))
		table.insert(sections, "```")
	end

	if diff_excerpt ~= "" then
		table.insert(sections, "")
		table.insert(sections, "Full diff for target file:")
		table.insert(sections, "```diff")
		table.insert(sections, prompt_context.truncate_text_middle(diff_excerpt, 6200))
		table.insert(sections, "```")
	end

	if not vim.tbl_isempty(file_consumers) then
		table.insert(sections, "")
		table.insert(sections, "Likely direct consumers of target file:")
		table.insert(sections, prompt_context.build_compact_file_consumers(file_consumers, {
			max_groups = 2,
			max_matches = 3,
			max_chars = 160,
		}))
	end

	if not vim.tbl_isempty(related_tests) then
		table.insert(sections, "")
		table.insert(sections, "Likely related tests for target file:")
		table.insert(sections, prompt_context.build_compact_related_tests(related_tests, {
			max_groups = 2,
			max_matches = 3,
			max_chars = 160,
		}))
	end

	if not vim.tbl_isempty(symbol_usages) then
		table.insert(sections, "")
		table.insert(sections, "Likely downstream usages of changed symbols:")
		table.insert(sections, prompt_context.build_compact_symbol_usages(symbol_usages, {
			max_groups = 2,
			max_matches = 3,
			max_chars = 160,
		}))
	end

	local additional_instruction = prompt_context.trim_text(config.get_review_additional_instruction())
	if additional_instruction ~= "" then
		table.insert(sections, "")
		table.insert(sections, "Additional instruction:")
		table.insert(sections, additional_instruction)
	end

	local messages = {
		{
			role = "user",
			content = table.concat(sections, "\n"),
		},
	}

	return provider.build_chat_request(config.get_system_prompt(), messages, 2048, "review")
end

return M
