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

local function build_user_prompt(review_context, file_chunk, range_text)
	local sections = {
		"You are reviewing code from a repository-aware Neovim plugin review workflow.",
		"Use the project context to reason about architecture, call flows, conventions, and likely regressions.",
		"You may report issues in the file under review or in other repository files when the context reveals a concrete problem.",
		"If an issue belongs to another file, you must emit `file=<repo-relative-path> line=<num>:`. Never map that issue onto the current file.",
		"If you cannot anchor a cross-file issue to a specific file and line, omit it.",
		"Focus on high-confidence problems that can cause bugs, regressions, missing edge cases, contract mismatches, broken UX flows, or materially harmful performance behavior.",
		"Avoid nitpicks, naming/style preferences, comment requests, and generic refactor suggestions unless they point to a concrete defect risk.",
		"If there are no meaningful issues, return no findings.",
		"",
		"Project summary:",
		build_project_summary(review_context.project_summary),
		"",
		"Relevant project code:",
		build_relevant_chunks(review_context.relevant_chunks),
		"",
		("File under review: %s"):format(review_context.relative_path or utils.get_buf_name(0)),
		("Review scope: %s"):format(range_text),
		file_chunk,
	}

	if trim_text(review_context.git_diff) ~= "" then
		table.insert(sections, "")
		table.insert(sections, "Git diff:")
		table.insert(sections, review_context.git_diff)
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

function M.build_requests(provider, fewshot_messages)
	local buffer_number = utils.get_buffer_number()
	local lines = vim.api.nvim_buf_get_lines(buffer_number, 0, -1, false)
	local review_context = context_engine.collect_review_context(buffer_number)
	local file_chunk = utils.prepare_code_snippet(buffer_number, 1, math.max(#lines, 1))
	local messages = vim.deepcopy(fewshot_messages or {})

	table.insert(messages, {
		role = "user",
		content = build_user_prompt(review_context, file_chunk, "entire file"),
	})

	return { provider.build_chat_request(config.get_system_prompt(), messages, 2048) }, 1, #lines
end

return M
