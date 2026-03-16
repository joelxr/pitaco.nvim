local config = require("pitaco.config")
local context_engine = require("pitaco.context_engine")
local utils = require("pitaco.utils")

local M = {}

local function format_list(items)
	if type(items) ~= "table" or vim.tbl_isempty(items) then
		return "none"
	end

	return table.concat(items, ", ")
end

local function trim_text(value)
	if type(value) ~= "string" then
		return ""
	end

	return vim.trim(value)
end

local function build_numbered_buffer_section(file_chunk)
	return table.concat({
		"Current buffer contents:",
		"The numeric prefix on each line is the real source line number in the file.",
		"Use only those prefixed numbers for `line=<num>` findings.",
		"Do not count lines from the prompt itself.",
		"```text",
		file_chunk,
		"```",
	}, "\n")
end

local function build_project_summary(summary)
	if type(summary) ~= "table" then
		return "Project summary unavailable."
	end

	return table.concat({
		("Repository: %s"):format(summary.repository_name or "unknown"),
		("Indexed files: %s"):format(summary.file_count or 0),
		("Indexed chunks: %s"):format(summary.chunk_count or 0),
		("Languages: %s"):format(format_list(summary.languages)),
		("Top symbols: %s"):format(format_list(summary.top_symbols)),
	}, "\n")
end

local function build_relevant_chunks(chunks)
	if type(chunks) ~= "table" or vim.tbl_isempty(chunks) then
		return "No related code chunks were retrieved."
	end

	local sections = {}
	for _, chunk in ipairs(chunks) do
		table.insert(sections, ("--- %s (%s, score=%.3f) ---\n%s"):format(
			chunk.file or "unknown",
			chunk.symbol or chunk.kind or "chunk",
			tonumber(chunk.score) or 0,
			chunk.code or ""
		))
	end

	return table.concat(sections, "\n\n")
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
			"Focus on high-confidence problems that can cause bugs, regressions, missing edge cases, contract mismatches, broken UX flows, or materially harmful performance behavior.",
			"Avoid nitpicks, naming/style preferences, comment requests, and generic refactor suggestions unless they point to a concrete defect risk.",
			"If there are no meaningful issues, return no findings.",
		}
	end

	return {
		"You are reviewing the full branch diff against the repository base branch from a repository-aware Neovim plugin review workflow.",
		"Focus on problems introduced by the current branch changes, including regressions in changed code and concrete side effects on related repository files.",
		"Every finding in diff mode must be anchored to the actual changed file using `file=<repo-relative-path> line=<num>:`.",
		"Do not use plain `line=` in diff mode.",
		"If you cannot anchor an issue to a specific changed file and line, omit it.",
		"When referring to the current buffer, use the exact source line number shown in the prefixed buffer listing below.",
		"Use the current buffer contents and repository context only to understand the branch diff; findings should stay grounded in the actual changes under review.",
		"Avoid nitpicks, naming/style preferences, comment requests, and generic refactor suggestions unless they point to a concrete defect risk.",
		"If there are no meaningful issues, return no findings.",
	}
end

local function build_user_prompt(review_context, file_chunk, review_mode)
	local review_scope = review_mode == "file" and "entire file" or "branch diff"
	local sections = {
		table.concat(build_prompt_header(review_mode), "\n"),
		"",
		"Project summary:",
		build_project_summary(review_context.project_summary),
		"",
		"Relevant project code:",
		build_relevant_chunks(review_context.relevant_chunks),
		"",
		("Current buffer: %s"):format(review_context.relative_path or utils.get_buf_name(0)),
		("Review scope: %s"):format(review_scope),
	}

	if review_mode == "file" then
		table.insert(sections, ("File under review: %s"):format(review_context.relative_path or utils.get_buf_name(0)))
	end

	table.insert(sections, build_numbered_buffer_section(file_chunk))

	if review_mode == "diff" then
		table.insert(sections, "")
		table.insert(sections, ("Base branch: %s"):format(review_context.base_branch or "unknown"))
		table.insert(sections, "Branch diff:")
		table.insert(sections, trim_text(review_context.git_diff))
	end

	local additional_instruction = trim_text(config.get_review_additional_instruction())
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

function M.build_requests(provider, fewshot_messages, review_mode)
	local buffer_number = utils.get_buffer_number()
	local lines = vim.api.nvim_buf_get_lines(buffer_number, 0, -1, false)
	local mode = review_mode == "file" and "file" or "diff"
	local review_context = context_engine.collect_review_context(buffer_number, mode)
	local diff_text = trim_text(review_context.git_diff)

	if mode == "diff" and diff_text == "" then
		vim.schedule(function()
			local message = review_context.diff_error
				or "Pitaco review diff: no changes found between the current branch state and the base branch"
			vim.notify(message, vim.log.levels.INFO)
		end)
		return {}, 0, #lines
	end

	local file_chunk = utils.prepare_code_snippet(buffer_number, 1, math.max(#lines, 1))
	local messages = vim.deepcopy(fewshot_messages or {})

	table.insert(messages, {
		role = "user",
		content = build_user_prompt(review_context, file_chunk, mode),
	})

	return { provider.build_chat_request(config.get_system_prompt(), messages, 2048) }, 1, #lines
end

return M
