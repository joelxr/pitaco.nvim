local config = require("pitaco.config")
local prompt_context = require("pitaco.prompt_context")
local review_context_builder = require("pitaco.review_context")
local utils = require("pitaco.utils")

local M = {}

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
		"You are reviewing the full branch diff against the repository base branch from a repository-aware Neovim plugin review workflow.",
		"Focus on problems introduced by the current branch changes, including regressions in changed code and concrete side effects on related repository files.",
		"Every finding in diff mode must be anchored to the actual changed file using `file=<repo-relative-path> line=<num>:`.",
		"Do not use plain `line=` in diff mode.",
		"If you cannot anchor an issue to a specific changed file and line, omit it.",
		"Return only finding lines. Do not add introductions, headings, numbering, bullets, markdown, or blank lines.",
		"Treat the branch diff as primary evidence. Use repository context only to confirm impact or locate affected callers/tests.",
		"Ignore retrieved matches that only share generic names, comments, fixture data, or common words and do not show a real code dependency.",
		"Do not report a claim that contradicts the shown diff or code. Verify import names, function calls, argument lists, and recursion paths against the visible snippets before reporting them.",
		"Use the repository context only to understand the branch diff; findings should stay grounded in the actual changes under review.",
		"Avoid nitpicks, naming/style preferences, comment requests, and generic refactor suggestions unless they point to a concrete defect risk.",
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
		table.insert(sections, prompt_context.build_project_summary(review_context.project_summary))
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
		table.insert(sections, prompt_context.build_changed_outline(review_context.changed_outline))
		if type(review_context.file_consumers) == "table" and not vim.tbl_isempty(review_context.file_consumers) then
			table.insert(sections, "")
			table.insert(sections, "Likely direct consumers of changed files:")
			table.insert(sections, prompt_context.build_file_consumers(review_context.file_consumers))
		end
		if type(review_context.related_tests) == "table" and not vim.tbl_isempty(review_context.related_tests) then
			table.insert(sections, "")
			table.insert(sections, "Likely related tests:")
			table.insert(sections, prompt_context.build_related_tests(review_context.related_tests))
		end
		if type(review_context.symbol_usages) == "table" and not vim.tbl_isempty(review_context.symbol_usages) then
			table.insert(sections, "")
			table.insert(sections, "Likely downstream usages of changed symbols:")
			table.insert(sections, prompt_context.build_symbol_usages(review_context.symbol_usages))
		end
		table.insert(sections, "")
		table.insert(sections, "Branch diff:")
		table.insert(sections, prompt_context.trim_text(review_context.git_diff))
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

function M.build_requests(provider, fewshot_messages, review_mode)
	local buffer_number = utils.get_buffer_number()
	local buffer_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer_number), ":p")
	local lines = vim.api.nvim_buf_get_lines(buffer_number, 0, -1, false)
	local mode = review_mode == "file" and "file" or "diff"
	local review_context = review_context_builder.collect(buffer_number, mode)
	local diff_text = prompt_context.trim_text(review_context.git_diff)

	if review_context.search_error ~= nil then
		vim.schedule(function()
			vim.notify(review_context.search_error, vim.log.levels.WARN)
		end)
	end

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

	local content_source = mode == "diff" and diff_text or table.concat(lines, "\n")
	local repo_root = review_context.root
	local relative_path = review_context.relative_path or utils.get_buf_name(buffer_number)

	return {
		requests = { provider.build_chat_request(config.get_system_prompt(), messages, 2048) },
		request_count = 1,
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
			base_branch = review_context.base_branch,
			changed_outline = review_context.changed_outline,
			merge_base = require("pitaco.context_engine").get_merge_base(repo_root, review_context.base_branch),
			head = require("pitaco.context_engine").get_head_commit(repo_root),
			content_hash = vim.fn.sha256(content_source or ""),
		},
	}
end

return M
