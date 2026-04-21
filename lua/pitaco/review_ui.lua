local context_engine = require("pitaco.context_engine")
local review_renderer = require("pitaco.review_renderer")
local review_store = require("pitaco.review_store")

local M = {}

local ui_namespace = vim.api.nvim_create_namespace("pitaco-review-ui")
local state_by_buf = {}

local HEADER_INDENT = "  "
local FILE_INDENT = "    "
local PATH_INDENT = "      "
local FINDING_INDENT = "      "
local COMMENT_INDENT = "        "

local function is_floating_window(win)
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return false
	end

	local config = vim.api.nvim_win_get_config(win)
	return config.relative ~= nil and config.relative ~= ""
end

local function find_main_window(fallback)
	if fallback ~= nil and vim.api.nvim_win_is_valid(fallback) and not is_floating_window(fallback) then
		return fallback
	end

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_is_valid(win) and not is_floating_window(win) then
			return win
		end
	end

	return fallback
end

local function current_repo_root()
	local path = vim.api.nvim_buf_get_name(0)
	if path == nil or path == "" then
		path = vim.fn.getcwd()
	end

	if path:match("^%w[%w+.-]*://") then
		path = path:gsub("^%w[%w+.-]*://", "")
	end

	local root = context_engine.find_repo_root(path)
	if root ~= nil and not vim.tbl_isempty(review_store.list_reviews(root)) then
		return root
	end

	local cwd_root = context_engine.find_repo_root(vim.fn.getcwd())
	if cwd_root ~= nil and (root == nil or not vim.tbl_isempty(review_store.list_reviews(cwd_root))) then
		return cwd_root
	end

	return root or cwd_root
end

local function relative_time(iso_timestamp)
	if type(iso_timestamp) ~= "string" or iso_timestamp == "" then
		return "unknown"
	end

	local year, month, day, hour, minute, second =
		iso_timestamp:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)Z$")
	if year == nil then
		return iso_timestamp
	end

	local local_timestamp = os.time({
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = tonumber(hour),
		min = tonumber(minute),
		sec = tonumber(second),
	})
	if local_timestamp == nil then
		return iso_timestamp
	end

	local timezone_offset = os.difftime(
		os.time(os.date("!*t", local_timestamp)),
		os.time(os.date("*t", local_timestamp))
	)
	local timestamp = local_timestamp - timezone_offset

	local diff = math.max(vim.fn.localtime() - timestamp, 0)
	if diff < 60 then
		return "just now"
	end
	if diff < 3600 then
		return ("%dm ago"):format(math.floor(diff / 60))
	end
	if diff < 86400 then
		return ("%dh ago"):format(math.floor(diff / 3600))
	end
	if diff < 604800 then
		return ("%dd ago"):format(math.floor(diff / 86400))
	end
	if diff < 2592000 then
		return ("%dw ago"):format(math.floor(diff / 604800))
	end
	return os.date("%Y-%m-%d", timestamp)
end

local function short_hash(value)
	if type(value) ~= "string" or value == "" then
		return "unknown"
	end

	return value:sub(1, 8)
end

local function model_label(review)
	local model = review.model_id or "unknown-model"
	local provider = review.provider or "unknown-provider"
	return ("%s/%s"):format(provider, model)
end

local function file_label(path)
	if type(path) ~= "string" or path == "" then
		return "unknown"
	end

	return vim.fn.fnamemodify(path, ":t")
end

local function add_highlight(highlights, line, group, col_start, col_end)
	table.insert(highlights, {
		line = line,
		group = group,
		col_start = col_start,
		col_end = col_end,
	})
end

local function apply_highlights(bufnr, highlights)
	vim.api.nvim_buf_clear_namespace(bufnr, ui_namespace, 0, -1)
	for _, item in ipairs(highlights or {}) do
		vim.api.nvim_buf_add_highlight(bufnr, ui_namespace, item.group, item.line - 1, item.col_start, item.col_end)
	end
end

local function wrap_text(text, width)
	local normalized = (text or ""):gsub("\r", ""):gsub("\n", " ")
	local lines = {}
	local current = ""

	for word in normalized:gmatch("%S+") do
		if current == "" then
			current = word
		elseif #current + 1 + #word <= width then
			current = current .. " " .. word
		else
			table.insert(lines, current)
			current = word
		end
	end

	if current ~= "" then
		table.insert(lines, current)
	end

	if vim.tbl_isempty(lines) then
		return { "" }
	end

	return lines
end

local function ensure_expansion(view_state, key, default)
	if view_state.expanded[key] == nil then
		view_state.expanded[key] = default
	end
	return view_state.expanded[key]
end

local function build_review_groups(review)
	local groups = {}
	local ordered = {}

	for _, item in ipairs(review.items or {}) do
		local path = item.file or "unknown"
		if groups[path] == nil then
			groups[path] = {
				path = path,
				items = {},
			}
			table.insert(ordered, groups[path])
		end
		table.insert(groups[path].items, item)
	end

	table.sort(ordered, function(left, right)
		if #left.items ~= #right.items then
			return #left.items > #right.items
		end
		return left.path < right.path
	end)

	for _, group in ipairs(ordered) do
		table.sort(group.items, function(left, right)
			return (left.original_line or 1) < (right.original_line or 1)
		end)
	end

	return ordered
end

local function current_entry(view_state)
	if view_state == nil or view_state.win == nil or not vim.api.nvim_win_is_valid(view_state.win) then
		return nil
	end

	local cursor_line = vim.api.nvim_win_get_cursor(view_state.win)[1]
	for _, entry in ipairs(view_state.entries) do
		if cursor_line >= entry.line_start and cursor_line <= entry.line_end then
			return entry
		end
	end

	return nil
end

local function build_lines(view_state)
	local reviews = review_store.list_reviews(view_state.repo_root)
	local active_entry = review_store.get_active_entry(view_state.repo_root)
	local lines = {
		("Pitaco reviews: %s"):format(view_state.repo_root or "unknown"),
		"",
	}
	local entries = {}
	local highlights = {
		{ line = 1, group = "Title", col_start = 0, col_end = -1 },
	}
	local content_width = math.max((view_state.width or 100) - #COMMENT_INDENT - 4, 30)

	if vim.tbl_isempty(reviews) then
		table.insert(lines, "No stored reviews for this repository.")
		add_highlight(highlights, #lines, "Comment", 0, -1)
		return lines, entries, highlights
	end

	for _, review in ipairs(reviews) do
		local review_key = "review:" .. review.id
		local review_open = ensure_expansion(view_state, review_key, true)
		local is_active = active_entry ~= nil and active_entry.review_id == review.id
		local icon = review_open and "▼" or "▶"
		local header = table.concat({
			icon,
			relative_time(review.created_at),
			model_label(review),
			("git %s"):format(short_hash(review.merge_base)),
			("count %d"):format(tonumber(review.item_count) or #(review.items or {})),
			("mode %s"):format(review.mode or "unknown"),
			("head %s"):format(short_hash(review.head)),
			("status %s"):format(is_active and "active" or "inactive"),
		}, "  ")

		table.insert(lines, HEADER_INDENT .. header)
		local review_line = #lines
		table.insert(entries, {
			line_start = review_line,
			line_end = review_line,
			type = "review",
			review = review,
			key = review_key,
		})
		add_highlight(highlights, review_line, "Identifier", 0, #HEADER_INDENT + 3)
		add_highlight(highlights, review_line, "Special", #HEADER_INDENT + 5, -1)
		local status_text = "status " .. (is_active and "active" or "inactive")
		local status_start = #lines[review_line] - #status_text
		add_highlight(highlights, review_line, is_active and "DiagnosticOk" or "Comment", status_start, -1)

		if review_open then
			for _, group in ipairs(build_review_groups(review)) do
				local file_key = review_key .. ":file:" .. group.path
				local file_open = ensure_expansion(view_state, file_key, true)
				local file_icon = file_open and "▼" or "▶"
				local title = ("%s %s:%d"):format(file_icon, file_label(group.path), tonumber(group.items[1].original_line) or 1)
				local title_line = FILE_INDENT .. title
					table.insert(lines, title_line)
					local file_line = #lines
					add_highlight(highlights, file_line, "Directory", 0, #FILE_INDENT + #title)

					table.insert(lines, PATH_INDENT .. group.path)
					local path_line = #lines
					table.insert(entries, {
						line_start = file_line,
						line_end = path_line,
						type = "file",
						review = review,
						file = group,
						key = file_key,
					})
					add_highlight(highlights, path_line, "Comment", 0, -1)

				if file_open then
					for _, item in ipairs(group.items) do
						local finding_title = ("%sline %d"):format(FINDING_INDENT, tonumber(item.original_line) or 1)
						table.insert(lines, finding_title)
						local start_line = #lines
						add_highlight(highlights, start_line, "LineNr", 0, -1)

						for _, wrapped in ipairs(wrap_text(item.message, content_width)) do
							table.insert(lines, COMMENT_INDENT .. wrapped)
							add_highlight(highlights, #lines, "Normal", 0, -1)
						end

						local end_line = #lines
						table.insert(entries, {
							line_start = start_line,
							line_end = end_line,
							type = "item",
							review = review,
							file = group,
							item = item,
						})
						table.insert(lines, "")
					end
				else
					table.insert(lines, "")
				end
			end
		end

		table.insert(lines, "")
	end

	return lines, entries, highlights
end

local function open_window(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	local width = math.max(90, math.floor(vim.o.columns * 0.85))
	local height = math.max(16, math.floor(vim.o.lines * 0.75))
	local row = math.max(1, math.floor((vim.o.lines - height) / 2))
	local col = math.max(1, math.floor((vim.o.columns - width) / 2))

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "pitaco-review-history"

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = " Pitaco Reviews ",
		title_pos = "center",
		width = width,
		height = height,
		row = row,
		col = col,
	})

	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].breakindent = true
	vim.wo[win].cursorline = true

	return buf, win, width
end

local function close_window(win)
	if win ~= nil and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
end

local function redraw(bufnr)
	local view_state = state_by_buf[bufnr]
	if view_state == nil then
		return
	end

	local lines, entries, highlights = build_lines(view_state)
	view_state.entries = entries
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	apply_highlights(bufnr, highlights)
end

local function activate_entry(bufnr, close_after)
	local view_state = state_by_buf[bufnr]
	local entry = current_entry(view_state)
	if entry == nil then
		return
	end

	local target_win = find_main_window(view_state.previous_win)
	if close_after then
		close_window(view_state.win)
	end

	if entry.type == "review" then
		review_renderer.activate_review(entry.review)
		if target_win ~= nil and vim.api.nvim_win_is_valid(target_win) then
			vim.api.nvim_set_current_win(target_win)
		end
		require("pitaco.log").event("info", "review activated", "Pitaco review activated", false)
		return
	end

	if entry.type == "file" then
		review_renderer.activate_review(entry.review)
		review_renderer.focus_item(entry.review, entry.file.items[1], target_win)
		return
	end

	if entry.type == "item" then
		review_renderer.activate_review(entry.review)
		review_renderer.focus_item(entry.review, entry.item, target_win)
	end
end

local function toggle_entry(bufnr)
	local view_state = state_by_buf[bufnr]
	local entry = current_entry(view_state)
	if entry == nil or entry.key == nil then
		return
	end

	view_state.expanded[entry.key] = not view_state.expanded[entry.key]
	redraw(bufnr)
end

function M.select(bufnr)
	activate_entry(bufnr, true)
end

function M.toggle(bufnr)
	toggle_entry(bufnr)
end

function M.refresh(bufnr)
	redraw(bufnr)
end

function M.open()
	local repo_root = current_repo_root()
	local previous_win = find_main_window(vim.api.nvim_get_current_win())
	local buf, win, width = open_window({ "Loading reviews..." })
	state_by_buf[buf] = {
		repo_root = repo_root,
		win = win,
		width = width,
		previous_win = previous_win,
		entries = {},
		expanded = {},
	}
	redraw(buf)

	vim.keymap.set("n", "q", function()
		close_window(win)
	end, { buffer = buf, silent = true })
	vim.keymap.set("n", "<Esc>", function()
		close_window(win)
	end, { buffer = buf, silent = true })
	vim.keymap.set("n", "<CR>", function()
		M.select(buf)
	end, { buffer = buf, silent = true })
	vim.keymap.set("n", "<Tab>", function()
		M.toggle(buf)
	end, { buffer = buf, silent = true })
	vim.keymap.set("n", "za", function()
		M.toggle(buf)
	end, { buffer = buf, silent = true })
	vim.keymap.set("n", "r", function()
		M.refresh(buf)
	end, { buffer = buf, silent = true })
end

return M
