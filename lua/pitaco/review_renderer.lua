local context_engine = require("pitaco.context_engine")
local review_locator = require("pitaco.review_locator")
local review_runtime = require("pitaco.review_runtime")
local review_store = require("pitaco.review_store")

local M = {}

local function normalize_path(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	return vim.fn.fnamemodify(path, ":p")
end

local function normalize_repo_relative_path(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	local normalized = path:gsub("\\", "/")
	normalized = normalized:gsub("^%./+", "")
	normalized = normalized:gsub("^/+", "")
	return normalized
end

local function from_repo_relative_path(root, relative_path)
	local normalized_root = normalize_path(root)
	relative_path = normalize_repo_relative_path(relative_path)
	if normalized_root == nil or type(relative_path) ~= "string" or relative_path == "" then
		return normalized_root
	end

	return normalized_root .. "/" .. relative_path
end

local function severity_value(label)
	if label == "error" then
		return vim.diagnostic.severity.ERROR
	end
	if label == "warn" then
		return vim.diagnostic.severity.WARN
	end
	if label == "hint" then
		return vim.diagnostic.severity.HINT
	end
	return vim.diagnostic.severity.INFO
end

local function list_open_buffers()
	local buffers = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
			table.insert(buffers, bufnr)
		end
	end
	return buffers
end

local function read_buffer_lines(bufnr, path)
	if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
		return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	end

	local normalized = normalize_path(path)
	if normalized == nil or vim.loop.fs_stat(normalized) == nil then
		return {}
	end

	return vim.fn.readfile(normalized)
end

local function diagnostics_for_file(review, active_entry, relative_path, bufnr)
	local diagnostics = {}
	relative_path = normalize_repo_relative_path(relative_path)
	local path = from_repo_relative_path(review.repo_root, relative_path)
	local lines = read_buffer_lines(bufnr, path)

	for _, item in ipairs(review.items or {}) do
		local item_file = normalize_repo_relative_path(item.file)
		if not review_store.is_hidden(active_entry, item.id) and item_file == relative_path then
			local resolved_line, resolution = review_locator.resolve(item, lines)
			local message = item.message or ""
			if resolution == "fallback" then
				message = "[stale review] " .. message
			end

			table.insert(diagnostics, {
				lnum = math.max(resolved_line - 1, 0),
				col = 0,
				message = message,
				severity = severity_value(item.severity),
				source = item.source or "pitaco",
				user_data = {
					pitaco_review_id = review.id,
					pitaco_item_id = item.id,
					pitaco_resolution = resolution,
				},
			})
		end
	end

	table.sort(diagnostics, function(left, right)
		if left.lnum ~= right.lnum then
			return left.lnum < right.lnum
		end
		return (left.message or "") < (right.message or "")
	end)

	return diagnostics
end

function M.clear_all()
	local namespace = review_runtime.get_namespace()
	for _, bufnr in ipairs(list_open_buffers()) do
		vim.diagnostic.reset(namespace, bufnr)
	end
end

function M.render_buffer(bufnr)
	local namespace = review_runtime.get_namespace()
	if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
	if path == nil or path == "" then
		vim.diagnostic.reset(namespace, bufnr)
		return
	end

	local root = context_engine.find_repo_root(path)
	local review, active_entry = review_store.get_active_review(root)
	if review == nil then
		vim.diagnostic.reset(namespace, bufnr)
		return
	end

	local relative_path = path
	local normalized_root = normalize_path(root)
	if normalized_root ~= nil then
		local prefix = normalized_root:gsub("/+$", "") .. "/"
		if path:sub(1, #prefix) == prefix then
			relative_path = path:sub(#prefix + 1)
		end
	end

	local diagnostics = diagnostics_for_file(review, active_entry, relative_path, bufnr)
	vim.diagnostic.set(namespace, bufnr, diagnostics)
end

function M.render_review(review)
	if type(review) ~= "table" then
		return
	end

	local namespace = review_runtime.get_namespace()
	local active_entry = review_store.get_active_entry(review.repo_root)
	local seen = {}

	for _, item in ipairs(review.items or {}) do
		if type(item.file) == "string" and item.file ~= "" and not seen[item.file] then
			seen[item.file] = true
			local path = from_repo_relative_path(review.repo_root, item.file)
			local bufnr = vim.fn.bufadd(path)
			vim.fn.bufload(bufnr)
			local diagnostics = diagnostics_for_file(review, active_entry, item.file, bufnr)
			vim.diagnostic.set(namespace, bufnr, diagnostics)
		end
	end

	for _, bufnr in ipairs(list_open_buffers()) do
		local buffer_path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
		if buffer_path ~= nil then
			local root = context_engine.find_repo_root(buffer_path)
			if normalize_path(root) == normalize_path(review.repo_root) then
				M.render_buffer(bufnr)
			end
		end
	end
end

function M.activate_review(review)
	if type(review) ~= "table" or type(review.repo_root) ~= "string" then
		return false, "invalid review"
	end

	local ok, error_message = review_store.activate_review(review.repo_root, review.id)
	if not ok then
		return false, error_message
	end

	M.render_review(review)
	return true
end

function M.clear_repo(repo_root)
	local namespace = review_runtime.get_namespace()
	local normalized_root = normalize_path(repo_root)

	for _, bufnr in ipairs(list_open_buffers()) do
		local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
		if path ~= nil and normalize_path(context_engine.find_repo_root(path)) == normalized_root then
			vim.diagnostic.reset(namespace, bufnr)
		end
	end
end

function M.focus_item(review, item, target_win)
	if type(review) ~= "table" or type(item) ~= "table" then
		return
	end

	local path = from_repo_relative_path(review.repo_root, item.file)
	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)

	if target_win ~= nil and vim.api.nvim_win_is_valid(target_win) then
		vim.api.nvim_set_current_win(target_win)
	end

	vim.api.nvim_set_current_buf(bufnr)

	local lines = read_buffer_lines(bufnr, path)
	local resolved_line = review_locator.resolve(item, lines)
	vim.api.nvim_win_set_cursor(0, { resolved_line, 0 })
	M.render_buffer(bufnr)
end

return M
