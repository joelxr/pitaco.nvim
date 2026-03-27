local Job = require("plenary.job")
local config = require("pitaco.config")
local log = require("pitaco.log")
local progress = require("pitaco.progress")

local M = {}
local MAX_OUTLINE_FILES = 8
local auto_indexed_roots = {}
local auto_index_timers = {}
local external_index_watchers = {}
local external_index_notifications = {}

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

local function read_json_file(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	local fd = vim.loop.fs_open(path, "r", 384)
	if fd == nil then
		return nil
	end

	local stat = vim.loop.fs_fstat(fd)
	if stat == nil or stat.size == nil then
		vim.loop.fs_close(fd)
		return nil
	end

	local data = vim.loop.fs_read(fd, stat.size, 0)
	vim.loop.fs_close(fd)
	if type(data) ~= "string" or data == "" then
		return nil
	end

	local ok, decoded = pcall(vim.json.decode, data)
	if not ok or type(decoded) ~= "table" then
		return nil
	end

	return decoded
end

local function process_is_alive(pid)
	pid = tonumber(pid)
	if pid == nil or pid <= 0 then
		return false
	end

	local ok, err = pcall(vim.loop.kill, pid, 0)
	if ok then
		return true
	end

	return type(err) == "string" and err:match("EPERM") ~= nil
end

local function index_paths(root)
	root = normalize_path(root)
	if root == nil then
		return nil
	end

	local index_dir = vim.fs.joinpath(root, ".repo-pitaco", "index")
	return {
		index_dir = index_dir,
		lock_path = vim.fs.joinpath(index_dir, "index.lock"),
		status_path = vim.fs.joinpath(index_dir, "index.status.json"),
	}
end

local function stop_external_index_watcher(root)
	local watcher = external_index_watchers[root]
	if watcher == nil then
		return
	end

	watcher:stop()
	watcher:close()
	external_index_watchers[root] = nil
end

local function notify_external_index_running(root)
	if external_index_notifications[root] then
		return
	end

	external_index_notifications[root] = true
	vim.notify("Pitaco index already running in another session", vim.log.levels.INFO)
end

local function clear_external_index_notification(root)
	external_index_notifications[root] = nil
end

local function update_progress_from_status(status)
	progress.update(
		status.message or "Indexing repository",
		tonumber(status.current) or 0,
		tonumber(status.total) or 1
	)
end

local function index_complete_message(indexed_files, total_chunks)
	indexed_files = tonumber(indexed_files) or 0
	total_chunks = tonumber(total_chunks) or 0
	return ("Pitaco indexed %d/%d files and %d chunks"):format(indexed_files, indexed_files, total_chunks)
end

local function attach_external_index(root, status_path, pid)
	root = normalize_path(root)
	status_path = status_path or (index_paths(root) and index_paths(root).status_path) or nil
	if root == nil or status_path == nil then
		return false
	end

	stop_external_index_watcher(root)
	notify_external_index_running(root)

	local function handle_status(status, lock_alive)
		if type(status) ~= "table" then
			if lock_alive then
				progress.update("Indexing repository", 0, 1)
			end
			return
		end

		if status.result == "failed" then
			progress.stop()
			stop_external_index_watcher(root)
			clear_external_index_notification(root)
			vim.notify("Pitaco indexing failed: " .. (status.error or status.message or "unknown error"), vim.log.levels.ERROR)
			return
		end

		if status.result == "completed" and not lock_alive then
			progress.stop()
			stop_external_index_watcher(root)
			clear_external_index_notification(root)
			vim.notify(index_complete_message(status.indexed_files or status.current, status.total_chunks), vim.log.levels.INFO)
			return
		end

		update_progress_from_status(status)
	end

	local function poll()
		local alive = process_is_alive(pid)
		local status = read_json_file(status_path)

		if not alive and status == nil then
			progress.stop()
			stop_external_index_watcher(root)
			clear_external_index_notification(root)
			return
		end

		handle_status(status, alive)
	end

	poll()

	local timer = vim.loop.new_timer()
	external_index_watchers[root] = timer
	timer:start(500, 500, vim.schedule_wrap(function()
		poll()
	end))
	return true
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

function M.get_merge_base(root, base_branch)
	return resolve_merge_base(root, base_branch)
end

function M.get_head_commit(root)
	if root == nil or root == "" then
		return nil
	end

	local head_lines, head_error = run_job(
		"git",
		{ "-C", root, "rev-parse", "HEAD" },
		root,
		config.get_context_timeout_ms()
	)
	if head_error ~= nil then
		log.debug("git rev-parse HEAD failed: " .. head_error)
		return nil
	end

	local resolved = join_lines(head_lines)
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

local function parse_hunk_start(value)
	local start_line = tonumber((value or ""):match("^(%d+)")) or 0
	local line_count = tonumber((value or ""):match(",(%d+)$")) or 1
	if line_count < 0 then
		line_count = 0
	end

	return start_line, line_count
end

local function push_changed_range(file_map, current_file, start_line, line_count)
	if current_file == nil or current_file == "" or start_line <= 0 then
		return
	end

	local entry = file_map[current_file]
	if entry == nil then
		entry = {
			file = current_file,
			changedLines = {},
		}
		file_map[current_file] = entry
	end

	table.insert(entry.changedLines, {
		startLine = start_line,
		endLine = start_line + math.max(line_count - 1, 0),
	})
end

local function parse_changed_files(diff_text)
	if type(diff_text) ~= "string" or diff_text == "" then
		return {}
	end

	local files_by_path = {}
	local current_file = nil

	for _, line in ipairs(vim.split(diff_text, "\n", { plain = true })) do
		local next_file = line:match("^%+%+%+ b/(.+)$")
		if next_file ~= nil then
			if next_file == "/dev/null" then
				current_file = nil
			else
				current_file = next_file
				if files_by_path[current_file] == nil then
					files_by_path[current_file] = {
						file = current_file,
						changedLines = {},
					}
				end
			end
		else
			local new_hunk = line:match("^@@ %-%d+[,]?%d* %+(%d+[,]?%d*) @@")
			if new_hunk ~= nil then
				local start_line, line_count = parse_hunk_start(new_hunk)
				push_changed_range(files_by_path, current_file, start_line, line_count)
			end
		end
	end

	local files = vim.tbl_values(files_by_path)
	table.sort(files, function(left, right)
		if #left.changedLines ~= #right.changedLines then
			return #left.changedLines > #right.changedLines
		end
		return left.file < right.file
	end)

	if #files > MAX_OUTLINE_FILES then
		files = vim.list_slice(files, 1, MAX_OUTLINE_FILES)
	end

	return files
end

local function starts_with(value, prefix)
	return value:sub(1, #prefix) == prefix
end

local function path_matches_excluded_file(path, excluded_files)
	if type(path) ~= "string" or path == "" or type(excluded_files) ~= "table" then
		return false
	end

	for _, candidate in ipairs(excluded_files) do
		if type(candidate) == "string" and candidate ~= "" then
			local suffix = "/" .. candidate
			if path == candidate or path:sub(-#suffix) == suffix then
				return true
			end
		end
	end

	return false
end

local function extract_diff_path(header_line, block_lines)
	local left_path, right_path = header_line:match("^diff %-%-git a/(.-) b/(.-)$")
	if right_path ~= nil and right_path ~= "/dev/null" then
		return right_path
	end
	if left_path ~= nil and left_path ~= "/dev/null" then
		return left_path
	end

	for _, line in ipairs(block_lines or {}) do
		local plus_path = line:match("^%+%+%+ b/(.+)$")
		if plus_path ~= nil and plus_path ~= "/dev/null" then
			return plus_path
		end

		local minus_path = line:match("^%-%-%- a/(.+)$")
		if minus_path ~= nil and minus_path ~= "/dev/null" then
			return minus_path
		end
	end

	return nil
end

function M.filter_prompt_git_diff(diff_text)
	if type(diff_text) ~= "string" or diff_text == "" then
		return "", {}
	end

	local excluded_files = config.get_prompt_diff_exclude_files()
	if vim.tbl_isempty(excluded_files) then
		return diff_text, {}
	end

	local kept_blocks = {}
	local excluded_paths = {}
	local current_block = nil
	local current_path = nil

	local function flush_block()
		if current_block == nil or vim.tbl_isempty(current_block) then
			return
		end

		if not path_matches_excluded_file(current_path, excluded_files) then
			table.insert(kept_blocks, table.concat(current_block, "\n"))
			return
		end

		if current_path ~= nil and current_path ~= "" then
			table.insert(excluded_paths, current_path)
		end
	end

	for _, line in ipairs(vim.split(diff_text, "\n", { plain = true })) do
		if starts_with(line, "diff --git ") then
			flush_block()
			current_block = { line }
			current_path = extract_diff_path(line, current_block)
		elseif current_block ~= nil then
			table.insert(current_block, line)
			if current_path == nil then
				current_path = extract_diff_path("", current_block)
			end
		else
			table.insert(kept_blocks, line)
		end
	end

	flush_block()

	if #excluded_paths > 1 then
		table.sort(excluded_paths)
	end

	return vim.trim(table.concat(kept_blocks, "\n")), excluded_paths
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

local function has_indexed_context(search_result)
	if type(search_result) ~= "table" then
		return false
	end

	local summary = search_result.summary
	if type(summary) == "table" and (tonumber(summary.file_count) or 0) > 0 then
		return true
	end

	return type(search_result.results) == "table" and not vim.tbl_isempty(search_result.results)
end

function M.outline(root, changed_files)
	if type(changed_files) ~= "table" or vim.tbl_isempty(changed_files) then
		return { files = {} }, nil
	end

	local files_json = vim.json.encode(changed_files)
	local result, error_message = run_cli({
		"outline",
		"--root",
		root,
		"--files-json",
		files_json,
		"--json",
	}, root, config.get_context_timeout_ms())

	if error_message ~= nil then
		return nil, error_message
	end

	local payload = join_lines(result)
	if payload == "" then
		return nil, "Pitaco context outline returned an empty response"
	end

	local ok, decoded = pcall(vim.json.decode, payload)
	if not ok then
		return nil, "Failed to decode Pitaco context outline JSON"
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
	if search_error == nil and not has_indexed_context(search_result) then
		search_error = "Pitaco context index missing or empty for this repository; run :Pitaco index"
	end

	if search_error ~= nil then
		log.debug("context search failed: " .. search_error)
	end

	local git_diff = ""
	local base_branch = M.find_base_branch(root)
	local diff_error = nil
	local changed_outline = nil
	local outline_error = nil
	if review_mode == "diff" then
		local raw_git_diff
		raw_git_diff, diff_error = M.get_branch_git_diff(root, base_branch)
		git_diff = raw_git_diff
		if raw_git_diff ~= "" then
			git_diff = M.filter_prompt_git_diff(raw_git_diff)
			if git_diff == "" and diff_error == nil then
				diff_error = "Pitaco: only excluded lockfile changes were found in the branch diff"
			end
		end
	elseif config.should_include_git_diff() then
		git_diff = M.get_file_git_diff(root, relative_path)
	end

	if diff_error ~= nil then
		log.debug("context diff failed: " .. diff_error)
	end

	if review_mode == "diff" and git_diff ~= "" then
		local changed_files = parse_changed_files(git_diff)
		if not vim.tbl_isempty(changed_files) then
			changed_outline, outline_error = M.outline(root, changed_files)
			if outline_error ~= nil then
				log.debug("context outline failed: " .. outline_error)
			else
				log.debug_table("context outline files", changed_outline, 800)
			end
		end
	end

	return {
		enabled = search_result ~= nil and search_error == nil,
		root = root,
		relative_path = relative_path,
		project_summary = search_error == nil and search_result and search_result.summary or nil,
		relevant_chunks = search_error == nil and search_result and search_result.results or {},
		search_engine = search_result and search_result.engine or nil,
		base_branch = base_branch,
		git_diff = git_diff,
		changed_outline = changed_outline and changed_outline.files or {},
		diff_error = diff_error,
		outline_error = outline_error,
		search_error = search_error,
	}
end

function M.index()
	return M.index_root(nil)
end

function M.index_root(root, opts)
	opts = opts or {}
	local current = vim.api.nvim_buf_get_name(0)
	root = normalize_path(root) or M.find_repo_root(current ~= "" and current or vim.fn.getcwd())
	clear_external_index_notification(root)
	stop_external_index_watcher(root)
	local executable, base_args = get_command_parts()
	executable = resolve_executable(executable)
	local args = vim.deepcopy(base_args)

	table.insert(args, "index")
	table.insert(args, "--root")
	table.insert(args, root)
	table.insert(args, "--json")
	table.insert(args, "--progress")

	if type(executable) ~= "string" or executable == "" then
		if opts.session_key ~= nil then
			auto_indexed_roots[opts.session_key] = nil
		end
		vim.notify("Pitaco context CLI command is not configured", vim.log.levels.ERROR)
		return
	end

	if vim.fn.executable(executable) ~= 1 then
		if opts.session_key ~= nil then
			auto_indexed_roots[opts.session_key] = nil
		end
		vim.notify("Pitaco context CLI executable not found: " .. executable, vim.log.levels.ERROR)
		return
	end

	local stderr_lines = {}
	local active_lock = nil

	local function update_index_progress(line)
		if type(line) ~= "string" or line == "" then
			return
		end

		local ok, payload = pcall(vim.json.decode, line)
		if not ok or type(payload) ~= "table" then
			table.insert(stderr_lines, line)
			return
		end

		if payload.kind == "lock" and payload.status == "active" then
			active_lock = payload
			return
		end

		if payload.kind ~= "progress" then
			table.insert(stderr_lines, line)
			return
		end

		update_progress_from_status(payload)
	end

	local job = Job:new({
		command = executable,
		args = args,
		cwd = root,
		on_stderr = function(_, line)
			vim.schedule(function()
				update_index_progress(line)
			end)
		end,
		on_exit = function(job, code)
			vim.schedule(function()
				if active_lock ~= nil then
					if opts.session_key ~= nil then
						auto_indexed_roots[opts.session_key] = true
					end
					local attached = attach_external_index(root, active_lock.status_path, active_lock.pid)
					if not attached then
						progress.stop()
						vim.notify("Pitaco index already running in another session", vim.log.levels.INFO)
					end
					return
				end

				progress.stop()

				if code ~= 0 then
					if opts.session_key ~= nil then
						auto_indexed_roots[opts.session_key] = nil
					end
					local message = join_lines(stderr_lines)
					if message == "" then
						message = join_lines(job:stderr_result())
					end
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

				vim.notify(index_complete_message(decoded.indexed_files, decoded.total_chunks), vim.log.levels.INFO)
			end)
		end,
	})

	local ok, error_message = pcall(job.start, job)
	if not ok then
		if opts.session_key ~= nil then
			auto_indexed_roots[opts.session_key] = nil
		end
		vim.notify("Pitaco indexing failed to start: " .. tostring(error_message), vim.log.levels.ERROR)
		return
	end

	progress.update("Scanning repository", 0, 1)
	if opts.notify_start ~= false then
		vim.notify("Pitaco indexing started for " .. root, vim.log.levels.INFO)
	end
end

local function has_project_marker(path)
	local markers = config.get_auto_index_project_markers()
	if vim.tbl_isempty(markers) then
		return nil
	end

	local found = vim.fs.find(markers, {
		path = path,
		upward = true,
		stop = vim.loop.os_homedir(),
		type = "file",
		limit = 1,
	})
	if #found > 0 then
		return vim.fn.fnamemodify(found[1], ":h")
	end

	found = vim.fs.find(markers, {
		path = path,
		upward = true,
		stop = vim.loop.os_homedir(),
		type = "directory",
		limit = 1,
	})
	if #found > 0 then
		return found[1]
	end

	return nil
end

local function stop_auto_index_timer(root)
	local timer = auto_index_timers[root]
	if timer == nil then
		return
	end

	timer:stop()
	timer:close()
	auto_index_timers[root] = nil
end

function M.maybe_auto_index(bufnr)
	if not config.should_auto_index_on_project_open() then
		return
	end

	bufnr = bufnr or 0
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	if vim.bo[bufnr].buftype ~= "" then
		return
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if type(path) ~= "string" or path == "" then
		return
	end

	local absolute_path = normalize_path(path)
	if absolute_path == nil then
		return
	end

	local search_path = vim.fn.isdirectory(absolute_path) == 1 and absolute_path or vim.fn.fnamemodify(absolute_path, ":h")
	local root = normalize_path(has_project_marker(search_path))
	if root == nil or root == "" then
		return
	end

	if auto_indexed_roots[root] then
		return
	end

	stop_auto_index_timer(root)
	local debounce_ms = config.get_auto_index_debounce_ms()
	local timer = vim.loop.new_timer()
	auto_index_timers[root] = timer
	timer:start(debounce_ms, 0, vim.schedule_wrap(function()
		stop_auto_index_timer(root)
		if auto_indexed_roots[root] then
			return
		end
		auto_indexed_roots[root] = true
		M.index_root(root, {
			notify_start = false,
			session_key = root,
		})
	end))
end

return M
