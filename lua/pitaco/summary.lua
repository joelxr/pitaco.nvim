local M = {}

local config = require("pitaco.config")
local context_engine = require("pitaco.context_engine")
local log = require("pitaco.log")
local progress = require("pitaco.progress")
local prompt_context = require("pitaco.prompt_context")
local provider_factory = require("pitaco.providers.factory")

local function split_lines(text)
	return vim.split(text, "\n", { plain = true })
end

local function build_user_prompt(summary_context)
	local sections = {
		"You are preparing a pull request summary for the current branch changes.",
		"Describe what this branch changes, why those changes were made, and the expected risk or impact.",
		"This is not a code review, not a refactor suggestion pass, and not a request for improvements.",
		"Do not offer advice, recommendations, example code, test suggestions, or possible improvements.",
		"Do not say that context is missing or that the diff is hard to determine.",
		"Do not mention your limitations or reasoning process.",
		"Use exactly these top-level markdown sections in this order: `## What changed`, `## Why`, `## Risk/Impact`.",
		"Base the summary primarily on the branch diff and changed-file outline.",
		"Use repository metadata only as lightweight supporting context.",
		"Under each section, use short bullet points grounded first in the actual diff and then in the repository context.",
		"In `## Risk/Impact`, describe likely effects of the change itself. Do not mention test coverage, missing tests, or validation advice.",
		"If a motivation is not explicit, infer the most likely intent from the diff and state it directly.",
		"Do not include any text before `## What changed` or after the `## Risk/Impact` section.",
	}

	if prompt_context.has_project_summary(summary_context.project_summary) then
		table.insert(sections, "")
		table.insert(sections, "Project summary:")
		table.insert(sections, prompt_context.build_project_summary(summary_context.project_summary))
	end

	table.insert(sections, "")
	table.insert(sections, "Summary scope: branch diff")
	table.insert(sections, ("Base branch: %s"):format(summary_context.base_branch or "unknown"))
	table.insert(sections, "Changed code structure:")
	table.insert(sections, prompt_context.build_changed_outline(summary_context.changed_outline))
	table.insert(sections, "")
	table.insert(sections, "Branch diff:")
	table.insert(sections, prompt_context.trim_text(summary_context.git_diff))

	local additional_instruction = prompt_context.trim_text(config.get_summary_additional_instruction())
	if additional_instruction ~= "" then
		table.insert(sections, "")
		table.insert(sections, "Additional instruction:")
		table.insert(sections, additional_instruction)
	end

	local language = config.get_language()
	if language ~= "" and language ~= "english" then
		table.insert(sections, "")
		table.insert(sections, "Write the markdown body in " .. language .. ".")
	end

	return table.concat(sections, "\n")
end

local function sanitize_summary(text)
	local summary = prompt_context.trim_text(text)
	if summary == "" then
		return ""
	end

	summary = summary:gsub("^```[%w_-]*%s*\n", "")
	summary = summary:gsub("\n```%s*$", "")
	summary = prompt_context.trim_text(summary)

	local boilerplate_patterns = {
		"^[Hh]ere'?s the [Pp][Rr] summary:?%s*\n+",
		"^[Hh]ere is the [Pp][Rr] summary:?%s*\n+",
		"^[Bb]elow is the [Pp][Rr] summary:?%s*\n+",
		"^[Pp][Rr] summary:?%s*\n+",
	}

	for _, pattern in ipairs(boilerplate_patterns) do
		summary = summary:gsub(pattern, "")
	end

	local heading_start = summary:find("##%s*What changed")
	if heading_start ~= nil then
		summary = summary:sub(heading_start)
	end

	local required_headings = {
		"## What changed",
		"## Why",
		"## Risk/Impact",
	}

	for _, heading in ipairs(required_headings) do
		if not summary:find(heading, 1, true) then
			return ""
		end
	end

	return prompt_context.trim_text(summary)
end

local function copy_to_clipboard(text)
	local copied = false

	if vim.fn.has("clipboard") == 1 then
		copied = pcall(vim.fn.setreg, "+", text)
		if vim.fn.has("unnamedplus") == 0 then
			pcall(vim.fn.setreg, "*", text)
		end
	end

	return copied
end

local function set_preview_keymaps(buf, win, text)
	local function close_window()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	vim.keymap.set("n", "q", close_window, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "<Esc>", close_window, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "y", function()
		if copy_to_clipboard(text) then
			vim.notify("Pitaco summary copied to clipboard", vim.log.levels.INFO)
		else
			vim.notify("Pitaco summary: clipboard unavailable", vim.log.levels.WARN)
		end
	end, { buffer = buf, nowait = true, silent = true })
end

local function open_summary_modal(text, provider_name, model_id)
	local width = math.max(math.floor(vim.o.columns * 0.8), 60)
	local height = math.max(math.floor(vim.o.lines * 0.7), 16)
	local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
	local col = math.max(math.floor((vim.o.columns - width) / 2), 0)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, split_lines(text))
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"

	local title = ("Pitaco PR Summary (%s/%s)"):format(provider_name or "unknown", model_id or "unknown")
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		border = "rounded",
		title = title,
		title_pos = "center",
	})

	set_preview_keymaps(buf, win, text)
	return buf, win
end

local function summary_progress_message(provider_name, model_id)
	return ("Generating PR summary with %s/%s"):format(provider_name or "unknown", model_id or "unknown")
end

function M.run(opts)
	opts = opts or {}
	local scope = "summary"
	local provider = provider_factory.create_provider(config.get_provider(scope), scope)
	local buffer_number = vim.api.nvim_get_current_buf()
	local summary_context = context_engine.collect_review_context(buffer_number, "diff", {
		base_branch = opts.base_branch,
	})
	local diff_text = prompt_context.trim_text(summary_context.git_diff)

	if summary_context.search_error ~= nil then
		vim.notify(summary_context.search_error, vim.log.levels.WARN)
	end

	if diff_text == "" then
		local message = summary_context.diff_error
			or "Pitaco summary: no changes found between the current branch state and the base branch"
		vim.notify(message, vim.log.levels.INFO)
		return
	end

	local messages = {
		{
			role = "user",
			content = build_user_prompt(summary_context),
		},
	}

	local system_prompt = config.get_summary_system_prompt()
	local request_json = provider.build_chat_request(system_prompt, messages, 1024)
	local provider_name = provider.name
	local model_id = provider.get_model and provider.get_model() or nil

	progress.update(summary_progress_message(provider_name, model_id), 1, 1)
	log.debug(("Dispatching summary request via provider '%s'"):format(provider_name or "unknown"))
	log.preview_json("summary request payload", request_json)

	provider.request(request_json, function(response, error_message)
		vim.schedule(function()
			if error_message ~= nil then
				log.preview_text("summary request error", error_message)
				progress.stop()
				vim.notify("Pitaco summary: " .. error_message, vim.log.levels.ERROR)
				return
			end

			local raw_text = provider.extract_text(response)
			local summary = sanitize_summary(raw_text)
			log.preview_text("summary response text", raw_text)

			if summary == "" then
				progress.stop()
				vim.notify("Pitaco summary: failed to parse summary response", vim.log.levels.ERROR)
				return
			end

			local copied = copy_to_clipboard(summary)
			open_summary_modal(summary, provider_name, model_id)
			progress.stop()

			if copied then
				vim.notify("Pitaco summary ready and copied to clipboard", vim.log.levels.INFO)
			else
				vim.notify("Pitaco summary ready (clipboard unavailable)", vim.log.levels.WARN)
			end
		end)
	end)
end

return M
