local config = require("pitaco.config")
local log = require("pitaco.log")
local prompt_context = require("pitaco.prompt_context")
local review_context_builder = require("pitaco.review_context")
local utils = require("pitaco.utils")

local M = {}

local DIFF_SLICE_FILE_EXCERPT_RADIUS = 40
local DIFF_SLICE_FILE_EXCERPT_MAX_CHARS = 3600
local DIFF_SLICE_MAX_CHARS = 4000

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

local function normalize_relative_path(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	local normalized = path:gsub("\\", "/")
	normalized = normalized:gsub("^%./+", "")
	normalized = normalized:gsub("^/+", "")
	return normalized
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

local function build_numbered_file_excerpt(repo_root, target_file, line_range, radius)
	local normalized_target = normalize_relative_path(target_file)
	if normalized_target == nil then
		return ""
	end

	local root = type(repo_root) == "string" and repo_root or vim.fn.getcwd()
	local absolute_path = vim.fn.fnamemodify(root .. "/" .. normalized_target, ":p")
	local lines = read_file_lines(absolute_path)
	if vim.tbl_isempty(lines) then
		return ""
	end

	local span = math.max(8, tonumber(radius) or 16)
	local start_line = 1
	local end_line = math.min(#lines, 1 + span)

	if type(line_range) == "table" then
		local center_start = math.max(1, tonumber(line_range.startLine) or 1)
		local center_end = math.max(center_start, tonumber(line_range.endLine) or center_start)
		start_line = math.max(1, center_start - span)
		end_line = math.min(#lines, center_end + span)
	end

	local width = #tostring(end_line)
	local excerpt = {}

	for index = start_line, end_line do
		table.insert(excerpt, string.format("%0" .. width .. "d %s", index, lines[index]))
	end

	return table.concat(excerpt, "\n")
end

local function parse_hunk_header(line)
	local new_range = line:match("^@@ %-%d+[, %d]* %+(%d+[,]?%d*) @@")
	if new_range == nil then
		return nil
	end

	local start_line = tonumber((new_range or ""):match("^(%d+)")) or 0
	local line_count = tonumber((new_range or ""):match(",(%d+)$")) or 1
	return {
		startLine = start_line,
		endLine = start_line + math.max(line_count - 1, 0),
	}
end

local function parse_diff_slices(diff_text)
	if type(diff_text) ~= "string" or diff_text == "" then
		return {}
	end

	local slices = {}
	local current_file = nil
	local current_hunk = nil

	local function flush_hunk()
		if current_hunk ~= nil and current_file ~= nil then
			current_hunk.file = current_file
			current_hunk.text = table.concat(current_hunk.lines or {}, "\n")
			table.insert(slices, current_hunk)
		end
		current_hunk = nil
	end

	for _, line in ipairs(vim.split(diff_text, "\n", { plain = true })) do
		local next_file = line:match("^diff %-%-git a/(.-) b/(.-)$")
		if next_file ~= nil then
			flush_hunk()
			local _, right = line:match("^diff %-%-git a/(.-) b/(.-)$")
			current_file = normalize_relative_path(right)
		elseif line:match("^@@ ") then
			flush_hunk()
			local range = parse_hunk_header(line)
			current_hunk = {
				range = range,
				lines = { line },
			}
		elseif current_hunk ~= nil then
			table.insert(current_hunk.lines, line)
		end
	end

	flush_hunk()
	return slices
end

local function is_test_path(path)
	local normalized = normalize_relative_path(path) or ""
	return normalized:match("(^|/)__tests__/") ~= nil
		or normalized:match("(^|/)tests?/") ~= nil
		or normalized:match("%.spec%.") ~= nil
		or normalized:match("%.test%.") ~= nil
end

local function is_low_signal_path(path)
	local normalized = normalize_relative_path(path) or ""
	return normalized:match("^docs?/") ~= nil
		or normalized:match("%.md$") ~= nil
		or normalized:match("package%-lock%.json$") ~= nil
		or normalized:match("pnpm%-lock%.yaml$") ~= nil
		or normalized:match("yarn%.lock$") ~= nil
end

local function prioritized_diff_slices(slices)
	local prioritized = {}
	for index, slice in ipairs(slices or {}) do
		slice._pitaco_original_index = index
		table.insert(prioritized, slice)
	end

	table.sort(prioritized, function(left, right)
		local left_priority = 0
		local right_priority = 0

		if is_test_path(left.file) then
			left_priority = left_priority + 10
		end
		if is_test_path(right.file) then
			right_priority = right_priority + 10
		end
		if is_low_signal_path(left.file) then
			left_priority = left_priority + 20
		end
		if is_low_signal_path(right.file) then
			right_priority = right_priority + 20
		end

		if left_priority ~= right_priority then
			return left_priority < right_priority
		end

		return (left._pitaco_original_index or 0) < (right._pitaco_original_index or 0)
	end)

	return prioritized
end

local function select_diff_slices(slices, max_slices)
	local limit = max_slices
	local selected = {}
	local selected_keys = {}
	local seen_files = {}
	local prioritized = prioritized_diff_slices(slices)

	local function slice_key(slice)
		local range = slice.range or {}
		return table.concat({
			slice.file or "",
			tostring(range.startLine or ""),
			tostring(range.endLine or ""),
			tostring(slice._pitaco_original_index or ""),
		}, ":")
	end

	local function add_slice(slice)
		if limit ~= nil and #selected >= limit then
			return
		end
		local key = slice_key(slice)
		if selected_keys[key] then
			return
		end
		selected_keys[key] = true
		table.insert(selected, slice)
	end

	for _, slice in ipairs(prioritized) do
		if limit ~= nil and #selected >= limit then
			break
		end
		local file = normalize_relative_path(slice.file)
		if file ~= nil and not seen_files[file] and not is_test_path(file) and not is_low_signal_path(file) then
			seen_files[file] = true
			add_slice(slice)
		end
	end

	for _, slice in ipairs(prioritized) do
		if limit ~= nil and #selected >= limit then
			break
		end
		add_slice(slice)
	end

	return selected
end

local function build_prompt_header(review_mode)
	if review_mode == "file" then
		return {
			"You are reviewing the full contents of a file from a repository-aware Neovim plugin review workflow.",
			"Use the project context to reason about architecture, call flows, conventions, and likely regressions.",
			"You may report issues in the file under review or in other repository files when the context reveals a concrete problem.",
			"If an issue belongs to another file, you must emit `file=<repo-relative-path> line=<num>:`. Never map that issue onto the current file.",
			"If you cannot anchor a cross-file issue to a specific file and line, omit it.",
			"For issues in the current file, use the exact source line number shown in the prefixed buffer listing below.",
			"Choose the most specific relevant line. Do not default to the function declaration unless the declaration itself is the problem.",
			"Return only finding lines. Do not add introductions, headings, numbering, bullets, markdown, or blank lines.",
			"Focus on high-confidence problems that can cause bugs, regressions, missing edge cases, contract mismatches, broken UX flows, or materially harmful performance behavior.",
			"Avoid nitpicks, naming/style preferences, comment requests, and generic refactor suggestions unless they point to a concrete defect risk.",
			"If there are no meaningful issues, return no findings.",
		}
	end

	return {
		"You are reviewing a branch diff.",
		"Find concrete bugs or regressions introduced by the shown changes.",
		"Every finding in diff mode must be anchored to the actual changed file using `file=<repo-relative-path> line=<num>:`.",
		"Do not use plain `line=` in diff mode.",
		"If you cannot anchor an issue to a specific changed file and line, omit it.",
		"Return only finding lines. Do not add introductions, headings, numbering, bullets, markdown, or blank lines.",
		"Treat the branch diff as primary evidence. Use repository context only to confirm impact or locate affected callers/tests.",
		"Ignore retrieved matches that only share generic names, comments, fixture data, or common words and do not show a real code dependency.",
		"Treat the shown diff and file excerpt as primary evidence. Use retrieved context only to confirm impact or identify direct callers/tests.",
		"Do not report a claim that contradicts the shown diff or file excerpt.",
		"Before reporting a missing import, wrong function name, wrong argument list, missing await, or wrong API usage, re-check the exact diff and file excerpt. If the shown code contradicts the claim, emit nothing.",
		"Use consumers, tests, and symbol usages only to confirm impact. Do not invent issues from them alone.",
		"Avoid docs, naming, style, comment, or generic refactor feedback.",
		"If there are no meaningful issues, return no findings.",
	}
end

local function build_user_prompt(review_context, file_chunk, review_mode)
	local review_scope = review_mode == "file" and "entire file" or "branch diff"
	local sections = {
		table.concat(build_prompt_header(review_mode), "\n"),
		("Review scope: %s"):format(review_scope),
	}

	if review_mode == "file" then
		table.insert(sections, 2, ("Current buffer: %s"):format(review_context.relative_path or utils.get_buf_name(0)))
	end

	if prompt_context.has_project_summary(review_context.project_summary) then
		table.insert(sections, "")
		table.insert(sections, "Project summary:")
		if review_mode == "diff" then
			table.insert(sections, prompt_context.build_compact_project_summary(review_context.project_summary))
		else
			table.insert(sections, prompt_context.build_project_summary(review_context.project_summary))
		end
	end

	if prompt_context.has_relevant_chunks(review_context.relevant_chunks) then
		table.insert(sections, "")
		table.insert(sections, "Relevant project code:")
		if review_mode == "diff" then
			table.insert(sections, prompt_context.build_compact_relevant_chunks(review_context.relevant_chunks, {
				max_chunks = 2,
				max_chars = 700,
			}))
		else
			table.insert(sections, prompt_context.build_relevant_chunks(review_context.relevant_chunks))
		end
	end

	table.insert(sections, "")

	if review_mode == "file" then
		table.insert(sections, ("File under review: %s"):format(review_context.relative_path or utils.get_buf_name(0)))
		table.insert(sections, prompt_context.build_numbered_buffer_section(file_chunk))
	end

	if review_mode == "diff" then
		table.insert(sections, "")
		table.insert(sections, ("Base branch: %s"):format(review_context.base_branch or "unknown"))
		table.insert(sections, "Changed code structure:")
		table.insert(sections, prompt_context.build_compact_changed_outline(review_context.changed_outline, {
			max_files = 8,
			max_symbols = 3,
		}))
		if type(review_context.file_consumers) == "table" and not vim.tbl_isempty(review_context.file_consumers) then
			table.insert(sections, "")
			table.insert(sections, "Likely direct consumers of changed files:")
			table.insert(sections, prompt_context.build_compact_file_consumers(review_context.file_consumers, {
				max_groups = 3,
				max_matches = 2,
				max_chars = 140,
			}))
		end
		if type(review_context.related_tests) == "table" and not vim.tbl_isempty(review_context.related_tests) then
			table.insert(sections, "")
			table.insert(sections, "Likely related tests:")
			table.insert(sections, prompt_context.build_compact_related_tests(review_context.related_tests, {
				max_groups = 2,
				max_matches = 2,
				max_chars = 140,
			}))
		end
		if type(review_context.symbol_usages) == "table" and not vim.tbl_isempty(review_context.symbol_usages) then
			table.insert(sections, "")
			table.insert(sections, "Likely downstream usages of changed symbols:")
			table.insert(sections, prompt_context.build_compact_symbol_usages(review_context.symbol_usages, {
				max_groups = 2,
				max_matches = 2,
				max_chars = 140,
			}))
		end
		table.insert(sections, "")
		table.insert(sections, "Branch diff:")
		table.insert(sections, prompt_context.truncate_text(prompt_context.trim_text(review_context.git_diff), 5000))
	end

	local additional_instruction = prompt_context.trim_text(config.get_review_additional_instruction())
	if additional_instruction ~= "" then
		table.insert(sections, "")
		table.insert(sections, "Additional instruction:")
		table.insert(sections, additional_instruction)
	end

	local language = config.get_language()
	if language ~= "" and language ~= "english" then
		table.insert(sections, "")
		table.insert(sections, "Respond only in " .. language .. ", but keep the 'line=<num>:' part in english.")
	end

	return table.concat(sections, "\n")
end

local function build_diff_slice_prompt(review_context, slice)
	local sections = {
		table.concat(build_prompt_header("diff"), "\n"),
		"Review scope: diff slice",
		"Return at most 2 findings for this slice.",
		"If the shown changed code appears correct, return an empty response.",
		("Base branch: %s"):format(review_context.base_branch or "unknown"),
		("Changed file: %s"):format(slice.file or "unknown"),
	}

	local file_excerpt = build_numbered_file_excerpt(
		review_context.root,
		slice.file,
		slice.range,
		DIFF_SLICE_FILE_EXCERPT_RADIUS
	)

	table.insert(sections, "")
	table.insert(sections, "Use this order of evidence:")
	table.insert(sections, "1. Diff slice")
	table.insert(sections, "2. Focused file excerpt")
	table.insert(sections, "3. Optional consumers/tests/usages only to confirm impact")
	table.insert(sections, "When a changed condition, guard, return, or wrapper is added, inspect later unchanged lines in the focused excerpt for side effects that may now be skipped.")

	local changed_entry = changed_outline_for_file(review_context.changed_outline, slice.file)
	if changed_entry ~= nil then
		table.insert(sections, "")
		table.insert(sections, "Changed code structure for file:")
		table.insert(sections, prompt_context.build_compact_changed_outline({ changed_entry }, {
			max_files = 1,
			max_symbols = 3,
		}))
	end

	if file_excerpt ~= "" then
		table.insert(sections, "")
		table.insert(sections, "Focused file excerpt:")
		table.insert(sections, "```text")
		table.insert(sections, prompt_context.truncate_text_middle(file_excerpt, DIFF_SLICE_FILE_EXCERPT_MAX_CHARS))
		table.insert(sections, "```")
	end

	local file_consumers = collect_matching_entries(review_context.file_consumers, slice.file, 1)
	if not vim.tbl_isempty(file_consumers) then
		table.insert(sections, "")
		table.insert(sections, "Likely direct consumers of changed file:")
		table.insert(sections, prompt_context.build_compact_file_consumers(file_consumers, {
			max_groups = 1,
			max_matches = 2,
			max_chars = 140,
		}))
	end

	local related_tests = collect_matching_entries(review_context.related_tests, slice.file, 1)
	if not vim.tbl_isempty(related_tests) then
		table.insert(sections, "")
		table.insert(sections, "Likely related tests for changed file:")
		table.insert(sections, prompt_context.build_compact_related_tests(related_tests, {
			max_groups = 1,
			max_matches = 2,
			max_chars = 140,
		}))
	end

	local symbol_usages = collect_matching_entries(review_context.symbol_usages, slice.file, 1)
	if not vim.tbl_isempty(symbol_usages) then
		table.insert(sections, "")
		table.insert(sections, "Likely downstream usages of changed symbols in this file:")
		table.insert(sections, prompt_context.build_compact_symbol_usages(symbol_usages, {
			max_groups = 1,
			max_matches = 2,
			max_chars = 140,
		}))
	end

	table.insert(sections, "")
	table.insert(sections, "Diff slice:")
	table.insert(sections, "```diff")
	table.insert(sections, prompt_context.truncate_text_middle(slice.text or "", DIFF_SLICE_MAX_CHARS))
	table.insert(sections, "```")

	local additional_instruction = prompt_context.trim_text(config.get_review_additional_instruction())
	if additional_instruction ~= "" then
		table.insert(sections, "")
		table.insert(sections, "Additional instruction:")
		table.insert(sections, additional_instruction)
	end

	local language = config.get_language()
	if language ~= "" and language ~= "english" then
		table.insert(sections, "")
		table.insert(sections, "Respond only in " .. language .. ", but keep the `file=<path> line=<num>:` part in english.")
	end

	return table.concat(sections, "\n")
end

local function build_branch_pass_prompt(review_context)
	local sections = {
		table.concat(build_prompt_header("diff"), "\n"),
		"Review scope: branch cross-file pass",
		"Return at most 2 findings for this branch pass.",
		"Focus only on cross-file regressions, broken callers, broken contracts, or interactions that require more than one diff slice to notice.",
		"Do not repeat slice-local issues unless the branch-level evidence proves a separate cross-file defect.",
		"If the branch-level evidence does not prove a concrete cross-file bug, return an empty response.",
		("Base branch: %s"):format(review_context.base_branch or "unknown"),
	}

	if prompt_context.has_project_summary(review_context.project_summary) then
		table.insert(sections, "")
		table.insert(sections, "Project summary:")
		table.insert(sections, prompt_context.build_compact_project_summary(review_context.project_summary))
	end

	table.insert(sections, "")
	table.insert(sections, "Changed code structure:")
	table.insert(sections, prompt_context.build_compact_changed_outline(review_context.changed_outline, {
		max_files = 8,
		max_symbols = 3,
	}))

	if type(review_context.file_consumers) == "table" and not vim.tbl_isempty(review_context.file_consumers) then
		table.insert(sections, "")
		table.insert(sections, "Likely direct consumers of changed files:")
		table.insert(sections, prompt_context.build_compact_file_consumers(review_context.file_consumers, {
			max_groups = 4,
			max_matches = 2,
			max_chars = 120,
		}))
	end

	if type(review_context.related_tests) == "table" and not vim.tbl_isempty(review_context.related_tests) then
		table.insert(sections, "")
		table.insert(sections, "Likely related tests:")
		table.insert(sections, prompt_context.build_compact_related_tests(review_context.related_tests, {
			max_groups = 2,
			max_matches = 2,
			max_chars = 120,
		}))
	end

	table.insert(sections, "")
	table.insert(sections, "Branch diff overview:")
	table.insert(sections, prompt_context.truncate_text(prompt_context.trim_text(review_context.git_diff), 2500))

	local additional_instruction = prompt_context.trim_text(config.get_review_additional_instruction())
	if additional_instruction ~= "" then
		table.insert(sections, "")
		table.insert(sections, "Additional instruction:")
		table.insert(sections, additional_instruction)
	end

	return table.concat(sections, "\n")
end

function M.build_requests(provider, fewshot_messages, review_mode, opts)
	opts = opts or {}
	local buffer_number = utils.get_buffer_number()
	local buffer_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer_number), ":p")
	local lines = vim.api.nvim_buf_get_lines(buffer_number, 0, -1, false)
	local mode = review_mode == "file" and "file" or "diff"
	local review_context = review_context_builder.collect(buffer_number, mode, {
		base_branch = opts.base_branch,
	})
	local diff_text = prompt_context.trim_text(review_context.git_diff)

	if review_context.search_error ~= nil then
		log.event("warn", "review context search error", review_context.search_error, false)
	end

	if mode == "diff" and diff_text == "" then
		local message = review_context.diff_error
			or "Pitaco review diff: no changes found between the current branch state and the base branch"
		log.event("info", "review skipped", message, false)
		return {}, 0, #lines
	end

	local file_chunk = utils.prepare_code_snippet(buffer_number, 1, math.max(#lines, 1))
	local requests = {}

	if mode == "file" then
		local messages = vim.deepcopy(fewshot_messages or {})
		table.insert(messages, {
			role = "user",
			content = build_user_prompt(review_context, file_chunk, mode),
		})
		table.insert(requests, provider.build_chat_request(config.get_system_prompt(), messages, 2048, "review"))
	else
		local max_diff_requests = config.get_review_max_diff_requests()
		local all_slices = parse_diff_slices(review_context.git_diff)
		local slices = select_diff_slices(all_slices, max_diff_requests)
		if max_diff_requests ~= nil and #all_slices > #slices then
			log.debug(("review diff request cap applied: max=%d skipped=%d"):format(max_diff_requests, #all_slices - #slices))
		end
		for index, slice in ipairs(slices) do
			local messages = vim.deepcopy(fewshot_messages or {})
			table.insert(messages, {
				role = "user",
				content = build_diff_slice_prompt(review_context, slice),
			})
			table.insert(requests, provider.build_chat_request(config.get_system_prompt(), messages, 2048, "review"))
		end

		local branch_messages = vim.deepcopy(fewshot_messages or {})
		table.insert(branch_messages, {
			role = "user",
			content = build_branch_pass_prompt(review_context),
		})
		table.insert(requests, provider.build_chat_request(config.get_system_prompt(), branch_messages, 2048, "review"))
	end

	local content_source = mode == "diff" and diff_text or table.concat(lines, "\n")
	local repo_root = review_context.root
	local relative_path = review_context.relative_path or utils.get_buf_name(buffer_number)
	local verifier_provider = config.get_review_provider("verifier")
	local verifier_model = verifier_provider and config.get_review_model(verifier_provider, "verifier") or nil

	return {
		requests = requests,
		request_count = #requests,
		line_count = #lines,
		metadata = {
			id_seed = vim.fn.sha256(table.concat({
				repo_root or "",
				relative_path or "",
				mode,
				content_source,
			}, "|")),
			repo_root = repo_root,
			buffer_path = buffer_path,
			relative_path = relative_path,
			mode = mode,
			provider = provider.name,
			model_id = provider.get_model and provider.get_model() or nil,
			verifier_provider = verifier_provider,
			verifier_model_id = verifier_model,
			base_branch = review_context.base_branch,
			changed_outline = review_context.changed_outline,
			git_diff = review_context.git_diff,
			file_consumers = review_context.file_consumers,
			related_tests = review_context.related_tests,
			symbol_usages = review_context.symbol_usages,
			merge_base = require("pitaco.context_engine").get_merge_base(repo_root, review_context.base_branch),
			head = require("pitaco.context_engine").get_head_commit(repo_root),
			content_hash = vim.fn.sha256(content_source or ""),
		},
	}
end

return M
