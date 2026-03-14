local Job = require("plenary.job")
local config = require("pitaco.config")
local log = require("pitaco.log")

local M = {}

local function join_lines(lines)
	if type(lines) ~= "table" or vim.tbl_isempty(lines) then
		return ""
	end

	return table.concat(lines, "\n")
end

local function normalize_path(path)
	if path == nil or path == "" then
		return nil
	end

	return vim.fn.fnamemodify(path, ":p")
end

local function to_repo_relative_path(root, absolute_path)
	local normalized_root = normalize_path(root)
	local normalized_path = normalize_path(absolute_path)
	if normalized_root == nil or normalized_path == nil then
		return absolute_path
	end

	normalized_root = normalized_root:gsub("/+$", "")
	normalized_path = normalized_path:gsub("/+$", "")

	local prefix = normalized_root .. "/"
	if normalized_path:sub(1, #prefix) == prefix then
		return normalized_path:sub(#prefix + 1)
	end

	return vim.fn.fnamemodify(normalized_path, ":.")
end

local function get_command_parts()
	local command = config.get_context_cli_command()
	if type(command) == "table" then
		local parts = vim.deepcopy(command)
		local executable = table.remove(parts, 1)
		return executable, parts
	end

	return command, {}
end

local function resolve_executable(executable)
	if type(executable) ~= "string" or executable == "" then
		return nil
	end

	if executable:find("/") then
		return executable
	end

	local resolved = vim.fn.exepath(executable)
	if resolved ~= nil and resolved ~= "" then
		return resolved
	end

	return executable
end

local function run_job(command, args, cwd, timeout)
	local stdout = {}
	local stderr = {}
	local job = Job:new({
		command = command,
		args = args,
		cwd = cwd,
		on_stdout = function(_, line)
			if line ~= nil and line ~= "" then
				table.insert(stdout, line)
			end
		end,
		on_stderr = function(_, line)
			if line ~= nil and line ~= "" then
				table.insert(stderr, line)
			end
		end,
	})

	local ok, result = pcall(job.sync, job, timeout)
	if not ok then
		return nil, result
	end

	if job.code ~= 0 then
		return nil, join_lines(stderr) ~= "" and join_lines(stderr) or join_lines(stdout)
	end

	return result or stdout, nil
end

local function run_cli(args, cwd, timeout)
	local executable, base_args = get_command_parts()
	executable = resolve_executable(executable)
	if type(executable) ~= "string" or executable == "" then
		return nil, "Pitaco context CLI command is not configured"
	end

	local command_args = {}
	for _, value in ipairs(base_args) do
		table.insert(command_args, value)
	end
	for _, value in ipairs(args or {}) do
		table.insert(command_args, value)
	end

	log.debug(("context engine -> %s %s"):format(executable, table.concat(command_args, " ")))
	return run_job(executable, command_args, cwd, timeout)
end

function M.find_repo_root(path)
	local absolute_path = normalize_path(path) or vim.fn.getcwd()
	local start_dir = absolute_path

	if vim.fn.isdirectory(start_dir) == 0 then
		start_dir = vim.fn.fnamemodify(start_dir, ":h")
	end

	local git_root, git_error = run_job(
		"git",
		{ "-C", start_dir, "rev-parse", "--show-toplevel" },
		start_dir,
		config.get_context_timeout_ms()
	)
	if git_error == nil then
		local resolved = join_lines(git_root)
		if resolved ~= "" then
			return normalize_path(resolved)
		end
	end

	local git_entry = vim.fn.finddir(".git", start_dir .. ";")
	if git_entry == "" then
		git_entry = vim.fn.findfile(".git", start_dir .. ";")
	end

	if git_entry ~= "" then
		local resolved = normalize_path(git_entry)
		if resolved ~= nil then
			if resolved:sub(-5) == "/.git" then
				return resolved:sub(1, -6)
			end
			return vim.fn.fnamemodify(resolved, ":h")
		end
	end

	local pitaco_dir = vim.fn.finddir(".repo-pitaco", start_dir .. ";")
	if pitaco_dir ~= "" then
		return vim.fn.fnamemodify(pitaco_dir, ":p:h")
	end

	return start_dir
end

function M.find_base_branch(root)
	if root == nil or root == "" then
		return nil
	end

	for _, candidate in ipairs({ "main", "master" }) do
		local _, local_error = run_job(
			"git",
			{ "-C", root, "show-ref", "--verify", "--quiet", "refs/heads/" .. candidate },
			root,
			config.get_context_timeout_ms()
		)
		if local_error == nil then
			return candidate
		end

		local _, remote_error = run_job(
			"git",
			{ "-C", root, "show-ref", "--verify", "--quiet", "refs/remotes/origin/" .. candidate },
			root,
			config.get_context_timeout_ms()
		)
		if remote_error == nil then
			return "origin/" .. candidate
		end
	end

	return nil
end

local function resolve_merge_base(root, base_branch)
	if root == nil or root == "" or base_branch == nil or base_branch == "" then
		return nil
	end

	local merge_base, merge_base_error = run_job(
		"git",
		{ "-C", root, "merge-base", "HEAD", base_branch },
		root,
		config.get_context_timeout_ms()
	)
	if merge_base_error ~= nil then
		log.debug("git merge-base failed: " .. merge_base_error)
		return nil
	end

	local resolved = join_lines(merge_base)
	if resolved == "" then
		return nil
	end

	return resolved
end

function M.get_file_git_diff(root, relative_path)
	if root == nil or root == "" or relative_path == nil or relative_path == "" then
		return ""
	end

	local unstaged, unstaged_error = run_job(
		"git",
		{ "-C", root, "diff", "--no-ext-diff", "--relative", "--", relative_path },
		root,
		config.get_context_timeout_ms()
	)
	if unstaged_error ~= nil then
		log.debug("git diff unstaged failed: " .. unstaged_error)
	end

	local staged, staged_error = run_job(
		"git",
		{ "-C", root, "diff", "--cached", "--no-ext-diff", "--relative", "--", relative_path },
		root,
		config.get_context_timeout_ms()
	)
	if staged_error ~= nil then
		log.debug("git diff staged failed: " .. staged_error)
	end

	local sections = {}
	local unstaged_text = join_lines(unstaged)
	local staged_text = join_lines(staged)

	if unstaged_text ~= "" then
		table.insert(sections, "Unstaged diff:\n" .. unstaged_text)
	end
	if staged_text ~= "" then
		table.insert(sections, "Staged diff:\n" .. staged_text)
	end

	return table.concat(sections, "\n\n")
end

function M.get_branch_git_diff(root, base_branch)
	local merge_base = resolve_merge_base(root, base_branch)
	if merge_base == nil then
		return "", "Pitaco could not determine the merge base for diff review"
	end

	local branch_diff, branch_diff_error = run_job(
		"git",
		{ "-C", root, "diff", "--no-ext-diff", merge_base, "--" },
		root,
		config.get_context_timeout_ms()
	)
	if branch_diff_error ~= nil then
		log.debug("git branch diff failed: " .. branch_diff_error)
		return "", branch_diff_error
	end

	return join_lines(branch_diff), nil
end

function M.search(root, relative_path, limit)
	local result, error_message = run_cli({
		"search",
		relative_path,
		"--root",
		root,
		"--limit",
		tostring(limit or config.get_context_max_chunks()),
		"--json",
	}, root, config.get_context_timeout_ms())

	if error_message ~= nil then
		return nil, error_message
	end

	local payload = join_lines(result)
	if payload == "" then
		return nil, "Pitaco context engine returned an empty response"
	end

	local ok, decoded = pcall(vim.json.decode, payload)
	if not ok then
		return nil, "Failed to decode Pitaco context search JSON"
	end

	return decoded, nil
end

function M.collect_review_context(bufnr, review_mode)
	if not config.is_context_enabled() then
		return {
			enabled = false,
			root = nil,
			relative_path = nil,
			project_summary = nil,
			relevant_chunks = {},
			git_diff = "",
		}
	end

	local buffer_path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
	if buffer_path == nil or vim.loop.fs_stat(buffer_path) == nil then
		return {
			enabled = false,
			root = nil,
			relative_path = nil,
			project_summary = nil,
			relevant_chunks = {},
			git_diff = "",
		}
	end

	local root = M.find_repo_root(buffer_path)
	local relative_path = to_repo_relative_path(root, buffer_path)
	local search_result, search_error = M.search(root, relative_path, config.get_context_max_chunks())

	if search_error ~= nil then
		log.debug("context search failed: " .. search_error)
	end

	local git_diff = ""
	local base_branch = M.find_base_branch(root)
	local diff_error = nil
	if review_mode == "diff" then
		git_diff, diff_error = M.get_branch_git_diff(root, base_branch)
	elseif config.should_include_git_diff() then
		git_diff = M.get_file_git_diff(root, relative_path)
	end

	if diff_error ~= nil then
		log.debug("context diff failed: " .. diff_error)
	end

	return {
		enabled = search_result ~= nil,
		root = root,
		relative_path = relative_path,
		project_summary = search_result and search_result.summary or nil,
		relevant_chunks = search_result and search_result.results or {},
		search_engine = search_result and search_result.engine or nil,
		base_branch = base_branch,
		git_diff = git_diff,
		diff_error = diff_error,
		search_error = search_error,
	}
end

function M.index()
	local current = vim.api.nvim_buf_get_name(0)
	local root = M.find_repo_root(current ~= "" and current or vim.fn.getcwd())
	local executable, base_args = get_command_parts()
	executable = resolve_executable(executable)
	local args = vim.deepcopy(base_args)

	table.insert(args, "index")
	table.insert(args, "--root")
	table.insert(args, root)
	table.insert(args, "--json")

	if type(executable) ~= "string" or executable == "" then
		vim.notify("Pitaco context CLI command is not configured", vim.log.levels.ERROR)
		return
	end

	if vim.fn.executable(executable) ~= 1 then
		vim.notify("Pitaco context CLI executable not found: " .. executable, vim.log.levels.ERROR)
		return
	end

	local job = Job:new({
		command = executable,
		args = args,
		cwd = root,
		on_exit = function(job, code)
			vim.schedule(function()
				if code ~= 0 then
					local message = join_lines(job:stderr_result())
					if message == "" then
						message = join_lines(job:result())
					end
					vim.notify("Pitaco indexing failed: " .. message, vim.log.levels.ERROR)
					return
				end

				local payload = join_lines(job:result())
				local ok, decoded = pcall(vim.json.decode, payload)
				if not ok then
					vim.notify("Pitaco indexing finished, but the CLI output was invalid JSON", vim.log.levels.WARN)
					return
				end

				vim.notify(
					("Pitaco indexed %d files and %d chunks"):format(decoded.indexed_files or 0, decoded.total_chunks or 0),
					vim.log.levels.INFO
				)
			end)
		end,
	})

	local ok, error_message = pcall(job.start, job)
	if not ok then
		vim.notify("Pitaco indexing failed to start: " .. tostring(error_message), vim.log.levels.ERROR)
		return
	end

	vim.notify("Pitaco indexing started for " .. root, vim.log.levels.INFO)
end

return M
