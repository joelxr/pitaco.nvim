local config = require("pitaco.config")
local log = require("pitaco.log")
local prompt_context = require("pitaco.prompt_context")
local provider_factory = require("pitaco.providers.factory")

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
	local span = math.max(8, tonumber(radius) or 20)
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

	if vim.tbl_isempty(results) then
		return {}
	end

	return results
end

local function candidate_line(diagnostic)
	local file = normalize_relative_path(diagnostic.file)
	local line = (tonumber(diagnostic.lnum) or 0) + 1
	local message = prompt_context.trim_text(diagnostic.message)
	if file == nil or message == "" then
		return ""
	end
	return ("file=%s line=%d: %s"):format(file, line, message)
end

function M.get_provider()
	local provider_name = config.get_review_provider("verifier")
	if type(provider_name) ~= "string" or provider_name == "" then
		return nil
	end

	return provider_factory.create_provider(provider_name, "review_verifier")
end

function M.build_request(provider, metadata, diagnostic)
	local target_file = normalize_relative_path(diagnostic.file or metadata.relative_path)
	local target_path = to_absolute_path(metadata.repo_root, diagnostic.absolute_path or target_file)
	local excerpt = build_numbered_excerpt(target_path, (tonumber(diagnostic.lnum) or 0) + 1, 24)
	local changed_entry = changed_outline_for_file(metadata.changed_outline, target_file)
	local diff_excerpt = diff_block_for_file(metadata.git_diff, target_file)
	local file_consumers = collect_matching_entries(metadata.file_consumers, target_file, 1)
	local related_tests = collect_matching_entries(metadata.related_tests, target_file, 1)
	local symbol_usages = collect_matching_entries(metadata.symbol_usages, target_file, 1)

	local sections = {
		"Candidate finding:",
		candidate_line(diagnostic),
		"",
		"Decision rules:",
		"- Treat the candidate as a hypothesis, not evidence.",
		"- Use only the shown excerpt, diff, and direct consumers/tests/usages below.",
		"- If the shown code or diff directly contradicts the candidate, return `status=rejected`.",
		"- If the candidate merely describes correct or intentional code, return `status=rejected`.",
		"- If the evidence does not prove a concrete bug, return `status=insufficient_evidence`.",
		"- Use `status=confirmed` only for a proven defect anchored to the shown file and line.",
		"- Do not propose fixes, explanations, or extra text outside the required format.",
		"",
		("Review mode: %s"):format(metadata.mode or "unknown"),
		("Target file: %s"):format(target_file or "unknown"),
	}

	if changed_entry ~= nil then
		table.insert(sections, "")
		table.insert(sections, "Changed code structure for target file:")
		table.insert(sections, prompt_context.build_compact_changed_outline({ changed_entry }, {
			max_files = 1,
			max_symbols = 3,
		}))
	end

	if excerpt ~= "" then
		table.insert(sections, "")
		table.insert(sections, "Focused source excerpt:")
		table.insert(sections, "```text")
		table.insert(sections, prompt_context.truncate_text(excerpt, 1400))
		table.insert(sections, "```")
	end

	if diff_excerpt ~= "" then
		table.insert(sections, "")
		table.insert(sections, "Diff excerpt for target file:")
		table.insert(sections, "```diff")
		table.insert(sections, prompt_context.truncate_text(diff_excerpt, 1600))
		table.insert(sections, "```")
	end

	if not vim.tbl_isempty(file_consumers) then
		table.insert(sections, "")
		table.insert(sections, "Likely direct consumers of target file:")
		table.insert(sections, prompt_context.build_compact_file_consumers(file_consumers, {
			max_groups = 1,
			max_matches = 2,
			max_chars = 120,
		}))
	end

	if not vim.tbl_isempty(related_tests) then
		table.insert(sections, "")
		table.insert(sections, "Likely related tests for target file:")
		table.insert(sections, prompt_context.build_compact_related_tests(related_tests, {
			max_groups = 1,
			max_matches = 2,
			max_chars = 120,
		}))
	end

	if not vim.tbl_isempty(symbol_usages) then
		table.insert(sections, "")
		table.insert(sections, "Likely downstream usages of symbols defined in target file:")
		table.insert(sections, prompt_context.build_compact_symbol_usages(symbol_usages, {
			max_groups = 1,
			max_matches = 2,
			max_chars = 120,
		}))
	end

	local verifier_prompt = table.concat(sections, "\n")
	log.preview_text("review verifier prompt", verifier_prompt, 1200)

	return provider.build_chat_request(config.get_review_verifier_system_prompt(), {
		{ role = "user", content = verifier_prompt },
	}, 512, "review_verifier")
end

return M
