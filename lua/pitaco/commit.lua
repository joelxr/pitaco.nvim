local M = {}

local provider_factory = require("pitaco.providers.factory")
local config = require("pitaco.config")
local context_engine = require("pitaco.context_engine")
local progress = require("pitaco.progress")
local log = require("pitaco.log")
local response_utils = require("pitaco.providers.response_utils")

local function trim_text(text)
	if vim.trim ~= nil then
		return vim.trim(text)
	end
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_system_output(lines)
	local text = table.concat(lines or {}, "\n")
	return trim_text(text)
end

local function git_systemlist(args)
	local output = vim.fn.systemlist(args)
	return output, vim.v.shell_error
end

local function sanitize_commit_message(text)
	if text == nil then
		return nil
	end

	local first_line = vim.split(text, "\n")[1] or ""
	first_line = trim_text(first_line)

	first_line = first_line:gsub("^git%s+commit%s+-m%s+", "")
	first_line = first_line:gsub("^commit%s+-m%s+", "")
	first_line = first_line:gsub("^-m%s+", "")
	first_line = first_line:gsub("^[Ss]ubject:%s+", "")
	first_line = first_line:gsub("^[Cc]ommit message:%s+", "")

	first_line = first_line:gsub('^"(.*)"$', "%1")
	first_line = first_line:gsub("^'(.*)'$", "%1")
	first_line = first_line:gsub("`", "")
	first_line = trim_text(first_line)

	if first_line == "" then
		return nil
	end

	return first_line
end

local function build_commit_system_prompt()
	local language = config.get_language()
	local prompt = config.get_commit_system_prompt() .. "\n- Write the subject line in " .. language .. "."
	local additional_instruction = config.get_commit_additional_instruction()
	if additional_instruction ~= "" then
		prompt = prompt .. "\n" .. additional_instruction
	end
	return prompt
end

local function should_retry_commit_generation(raw_text, response)
	if trim_text(raw_text or "") ~= "" then
		return false
	end

	return response_utils.choice_finish_reason(response) == "length"
end

local function build_commit_parse_error(response)
	local finish_reason = response_utils.choice_finish_reason(response)
	local reasoning = response_utils.choice_reasoning_text(response)

	if finish_reason == "length" and reasoning ~= "" then
		return "model returned reasoning but no final commit message before reaching max_tokens; try a non-reasoning model for commits"
	end

	if finish_reason == "length" then
		return "model stopped before returning a commit message; try increasing max_tokens or switching commit models"
	end

	if reasoning ~= "" then
		return "model returned reasoning but no final commit message; try a non-reasoning model for commits"
	end

	return "failed to parse commit message"
end

local function commit_progress_message(provider_name, model_id, attempt, total_attempts)
	return ("Generating commit message %d/%d with %s/%s"):format(
		attempt or 0,
		total_attempts or 0,
		provider_name or "unknown",
		model_id or "unknown"
	)
end

local function set_preview_keymaps(buf, win)
	vim.keymap.set("n", "q", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, { buffer = buf, nowait = true })

	vim.keymap.set("n", "<C-d>", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! <C-d>")
			end)
		end
	end, { buffer = buf, nowait = true })

	vim.keymap.set("n", "<C-u>", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! <C-u>")
			end)
		end
	end, { buffer = buf, nowait = true })
end

local function open_preview(lines, opts)
	if lines == nil or #lines == 0 then
		return nil
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	if opts.filetype ~= nil then
		vim.bo[buf].filetype = opts.filetype
	end

	local win = vim.api.nvim_open_win(buf, opts.enter or false, {
		relative = "editor",
		row = opts.row,
		col = opts.col,
		width = opts.width,
		height = opts.height,
		border = "rounded",
		title = opts.title,
		title_pos = "center",
	})

	set_preview_keymaps(buf, win)
	return win
end

local function open_diff_preview(diff_lines, title, layout)
	return open_preview(diff_lines, {
		filetype = "diff",
		title = title or "Pitaco Diff",
		enter = true,
		row = layout.row,
		col = layout.col,
		width = layout.width,
		height = layout.height,
	})
end

local function try_open_nui_commit_ui(message, diff_lines, title, on_submit, on_cancel)
	local ok_layout, NuiLayout = pcall(require, "nui.layout")
	local ok_popup, NuiPopup = pcall(require, "nui.popup")
	local ok_input, NuiInput = pcall(require, "nui.input")
	if not ok_layout or not ok_popup or not ok_input then
		return false
	end

	local width = math.max(math.floor(vim.o.columns * 0.8), 40)
	local input_height = 3
	local height = math.max(math.floor(vim.o.lines * 0.7), input_height + 6)

	local layout
	local closed = false
	local function finish_cancel()
		if closed then
			return
		end
		closed = true
		if layout ~= nil then
			layout:unmount()
		end
		on_cancel()
	end

	local input = NuiInput({
		border = {
			style = "rounded",
			text = { top = "Commit message", top_align = "center" },
		},
	}, {
		prompt = "> ",
		default_value = message,
		on_submit = function(value)
			if closed then
				return
			end
			closed = true
			if layout ~= nil then
				layout:unmount()
			end
			on_submit(value)
		end,
		on_close = function()
			finish_cancel()
		end,
	})

	local diff_popup = NuiPopup({
		border = {
			style = "rounded",
			text = { top = title or "Pitaco Diff", top_align = "center" },
		},
	})

	layout = NuiLayout({
		relative = "editor",
		position = "50%",
		size = {
			width = width,
			height = height,
		},
	}, NuiLayout.Box({
		NuiLayout.Box(input, { size = input_height }),
		NuiLayout.Box(diff_popup, { grow = 1 }),
	}, { dir = "col" }))

	layout:mount()
	if input ~= nil and input.winid ~= nil and vim.api.nvim_win_is_valid(input.winid) then
		vim.api.nvim_set_current_win(input.winid)
		vim.cmd("startinsert!")
	end

	if diff_lines ~= nil and #diff_lines > 0 then
		vim.api.nvim_buf_set_lines(diff_popup.bufnr, 0, -1, false, diff_lines)
	end
	vim.bo[diff_popup.bufnr].modifiable = false
	vim.bo[diff_popup.bufnr].bufhidden = "wipe"
	vim.bo[diff_popup.bufnr].filetype = "diff"

	vim.keymap.set("n", "q", finish_cancel, { buffer = diff_popup.bufnr, nowait = true, silent = true })
	vim.keymap.set("n", "q", finish_cancel, { buffer = input.bufnr, nowait = true, silent = true })
	vim.keymap.set("n", "<Esc>", finish_cancel, { buffer = diff_popup.bufnr, nowait = true, silent = true })
	vim.keymap.set("n", "<Esc>", finish_cancel, { buffer = input.bufnr, nowait = true, silent = true })
	vim.keymap.set("i", "<C-c>", function()
		finish_cancel()
	end, { buffer = input.bufnr, nowait = true, silent = true })
	vim.keymap.set("i", "<C-q>", function()
		finish_cancel()
	end, { buffer = input.bufnr, nowait = true, silent = true })

	return true
end

local function build_preview_layout()
	local width = math.max(math.floor(vim.o.columns * 0.8), 40)
	local height = math.max(math.floor(vim.o.lines * 0.7), 14)
	local row = math.floor((vim.o.lines - height) / 2) - 1
	local col = math.floor((vim.o.columns - width) / 2)

	return {
		width = width,
		col = math.max(col, 0),
		height = height,
		row = math.max(row, 0),
	}
end

local function close_preview(win)
	if win == nil then
		return
	end

	if type(win) == "table" then
		for _, w in ipairs(win) do
			if vim.api.nvim_win_is_valid(w) then
				vim.api.nvim_win_close(w, true)
			end
		end
		return
	end

	if vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
end

function M.run()
	local scope = "commit"
	local provider = provider_factory.create_provider(config.get_provider(scope), scope)
	local provider_name = provider.name
	local model_id = provider.get_model and provider.get_model() or nil

	local root_lines, root_code = git_systemlist({ "git", "rev-parse", "--show-toplevel" })
	if root_code ~= 0 or #root_lines == 0 then
		vim.notify("Pitaco commit: not a git repository", vim.log.levels.ERROR)
		return
	end

	local repo_root = root_lines[1]
	local staged_lines, staged_code = git_systemlist({ "git", "-C", repo_root, "diff", "--cached", "--no-ext-diff", "--no-color" })
	if staged_code ~= 0 then
		vim.notify("Pitaco commit: failed to read staged diff", vim.log.levels.ERROR)
		return
	end

	local unstaged_lines, unstaged_code = git_systemlist({ "git", "-C", repo_root, "diff", "--no-ext-diff", "--no-color" })
	if unstaged_code ~= 0 then
		vim.notify("Pitaco commit: failed to read unstaged diff", vim.log.levels.ERROR)
		return
	end

	local staged_diff = normalize_system_output(staged_lines)
	local unstaged_diff = normalize_system_output(unstaged_lines)

	if staged_diff == "" and unstaged_diff == "" then
		vim.notify("Pitaco commit: no changes found", vim.log.levels.INFO)
		return
	end

	local diff_for_ai = staged_diff ~= "" and staged_diff or unstaged_diff
	local needs_stage = staged_diff == ""
	local has_unstaged = unstaged_diff ~= ""
	local filtered_diff, excluded_paths = context_engine.filter_prompt_git_diff(diff_for_ai)

	if filtered_diff == "" then
		if #excluded_paths > 0 then
			vim.notify("Pitaco commit: only excluded lockfile changes were found in the prompt diff", vim.log.levels.INFO)
		else
			vim.notify("Pitaco commit: no usable diff remained for commit generation", vim.log.levels.INFO)
		end
		return
	end

	local system_prompt = build_commit_system_prompt()
	local messages = {
		{
			role = "user",
			content = filtered_diff,
		},
	}

	local commit_token_attempts = { 256, 512 }
	local function request_commit_message(attempt)
		local max_tokens = commit_token_attempts[attempt] or commit_token_attempts[#commit_token_attempts]
		progress.update(
			commit_progress_message(provider_name, model_id, attempt, #commit_token_attempts),
			attempt,
			#commit_token_attempts
		)
		local request_json = provider.build_chat_request(system_prompt, messages, max_tokens)
		log.debug(("Dispatching commit request via provider '%s'"):format(provider.name or "unknown"))
		log.preview_json("commit request payload", request_json)

		provider.request(request_json, function(response, error_message)
			vim.schedule(function()
				if error_message ~= nil then
					log.preview_text("commit request error", error_message)
					progress.stop()
					vim.notify("Pitaco commit: " .. error_message, vim.log.levels.ERROR)
					return
				end

				local raw_text = provider.extract_text(response)
				local message = sanitize_commit_message(raw_text)
				log.preview_text("commit response text", raw_text)
				if message == nil and attempt < #commit_token_attempts and should_retry_commit_generation(raw_text, response) then
					log.debug(("Retrying commit generation after empty response (finish_reason=%s, attempt=%d)"):format(
						tostring(response_utils.choice_finish_reason(response)),
						attempt
					))
					request_commit_message(attempt + 1)
					return
				end

				if message == nil then
					progress.stop()
					vim.notify("Pitaco commit: " .. build_commit_parse_error(response), vim.log.levels.ERROR)
					return
				end

				local diff_args = needs_stage and { "git", "-C", repo_root, "diff" }
					or { "git", "-C", repo_root, "diff", "--staged" }

				local diff_lines, diff_code = git_systemlist(diff_args)
				local layout = build_preview_layout()

				local title = needs_stage and "Pitaco Diff (unstaged)" or "Pitaco Diff (staged)"
				local preview_handle = nil

				local function cancel_commit(msg, level)
					close_preview(preview_handle)
					progress.stop()
					vim.notify(msg, level)
				end

				local function proceed_with_message(input)
					if input == nil then
						cancel_commit("Pitaco commit: canceled", vim.log.levels.INFO)
						return
					end

					local edited = trim_text(input)
					if edited == "" then
						cancel_commit("Pitaco commit: empty commit message", vim.log.levels.ERROR)
						return
					end

					message = sanitize_commit_message(edited) or edited

					local message_escaped = message:gsub('"', '\\"')
					local command_lines = {}

					if needs_stage then
						table.insert(command_lines, "git add -A")
					end
					table.insert(command_lines, 'git commit -m "' .. message_escaped .. '"')

					local prompt = "Run:\n" .. table.concat(command_lines, "\n")
					if has_unstaged and not needs_stage then
						prompt = prompt .. "\n\nNote: unstaged changes exist and will not be included."
					end

					local choice = vim.fn.confirm(prompt, "&Yes\n&No", 2)
					if choice ~= 1 then
						cancel_commit("Pitaco commit: canceled", vim.log.levels.INFO)
						return
					end

					if needs_stage then
						vim.fn.system({ "git", "-C", repo_root, "add", "-A" })
						if vim.v.shell_error ~= 0 then
							cancel_commit("Pitaco commit: git add failed", vim.log.levels.ERROR)
							return
						end
					end

					vim.fn.system({ "git", "-C", repo_root, "commit", "-m", message })
					if vim.v.shell_error ~= 0 then
						cancel_commit("Pitaco commit: git commit failed", vim.log.levels.ERROR)
						return
					end

					close_preview(preview_handle)
					progress.stop()
					vim.notify("Pitaco commit: created commit", vim.log.levels.INFO)
				end

				if diff_code == 0 and #diff_lines > 0 then
					local used_nui = try_open_nui_commit_ui(message, diff_lines, title, proceed_with_message, function()
						cancel_commit("Pitaco commit: canceled", vim.log.levels.INFO)
					end)
					if used_nui then
						return
					end

					preview_handle = open_diff_preview(diff_lines, title, layout)
				end

				vim.ui.input({ prompt = "Commit message:", default = message }, proceed_with_message)
			end)
		end)
	end

	request_commit_message(1)
end

return M
