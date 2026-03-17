local M = {}

local FILE_NAME = "pitaco-reviews.json"
local SCHEMA_VERSION = 1

local function state_file_path()
	return vim.fn.stdpath("state") .. "/" .. FILE_NAME
end

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

local function to_repo_relative_path(root, absolute_path)
	local normalized_root = normalize_path(root)
	local normalized_path = normalize_path(absolute_path)
	if normalized_root == nil or normalized_path == nil then
		return normalize_repo_relative_path(absolute_path) or absolute_path
	end

	normalized_root = normalized_root:gsub("/+$", "")
	normalized_path = normalized_path:gsub("/+$", "")

	local prefix = normalized_root .. "/"
	if normalized_path:sub(1, #prefix) == prefix then
		return normalized_path:sub(#prefix + 1)
	end

	return normalize_repo_relative_path(normalized_path) or normalized_path
end

local function from_repo_relative_path(root, relative_path)
	local normalized_root = normalize_path(root)
	if normalized_root == nil then
		return relative_path
	end

	relative_path = normalize_repo_relative_path(relative_path)
	if type(relative_path) ~= "string" or relative_path == "" then
		return normalized_root
	end

	return normalized_root .. "/" .. relative_path
end

local function read_json_file(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end

	local content = fd:read("*a")
	fd:close()
	if content == nil or content == "" then
		return nil
	end

	local ok, decoded = pcall(vim.json.decode, content)
	if not ok or type(decoded) ~= "table" then
		return nil
	end

	return decoded
end

local function write_json_file(path, payload)
	local encoded = vim.json.encode(payload)
	local parent = vim.fn.fnamemodify(path, ":h")
	vim.fn.mkdir(parent, "p")

	local fd, err = io.open(path, "w")
	if not fd then
		return false, err
	end

	fd:write(encoded)
	fd:close()
	return true
end

local function ensure_state_shape(state)
	state = type(state) == "table" and state or {}
	state.version = SCHEMA_VERSION
	state.reviews = type(state.reviews) == "table" and state.reviews or {}
	state.active = type(state.active) == "table" and state.active or {}
	return state
end

local function load_lines_for_file(path)
	local normalized = normalize_path(path)
	if normalized == nil or vim.loop.fs_stat(normalized) == nil then
		return {}
	end

	return vim.fn.readfile(normalized)
end

local function severity_label(severity)
	if severity == vim.diagnostic.severity.ERROR then
		return "error"
	end
	if severity == vim.diagnostic.severity.WARN then
		return "warn"
	end
	if severity == vim.diagnostic.severity.HINT then
		return "hint"
	end
	return "info"
end

local function capture_anchor(path, line_number)
	local lines = load_lines_for_file(path)
	if vim.tbl_isempty(lines) then
		return {
			line = nil,
			before = nil,
			after = nil,
		}
	end

	local index = math.max(1, math.min(line_number, #lines))
	return {
		line = lines[index],
		before = index > 1 and lines[index - 1] or nil,
		after = index < #lines and lines[index + 1] or nil,
	}
end

function M.load()
	return ensure_state_shape(read_json_file(state_file_path()))
end

function M.save(state)
	state = ensure_state_shape(state)
	state.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
	return write_json_file(state_file_path(), state)
end

function M.list_reviews(repo_root)
	local state = M.load()
	local reviews = {}
	local normalized_root = normalize_path(repo_root)

	for _, review in ipairs(state.reviews) do
		if normalized_root == nil or normalize_path(review.repo_root) == normalized_root then
			table.insert(reviews, vim.deepcopy(review))
		end
	end

	table.sort(reviews, function(left, right)
		return (left.created_at or "") > (right.created_at or "")
	end)

	return reviews
end

function M.get_review(review_id)
	if type(review_id) ~= "string" or review_id == "" then
		return nil
	end

	local state = M.load()
	for _, review in ipairs(state.reviews) do
		if review.id == review_id then
			return vim.deepcopy(review)
		end
	end

	return nil
end

function M.save_review(review)
	if type(review) ~= "table" or type(review.id) ~= "string" or review.id == "" then
		return false, "invalid review"
	end

	local state = M.load()
	local replaced = false

	for index, existing in ipairs(state.reviews) do
		if existing.id == review.id then
			state.reviews[index] = review
			replaced = true
			break
		end
	end

	if not replaced then
		table.insert(state.reviews, 1, review)
	end

	return M.save(state)
end

function M.create_review(metadata, diagnostics)
	if type(metadata) ~= "table" then
		return nil, "invalid metadata"
	end

	local repo_root = normalize_path(metadata.repo_root)
	local created_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local diagnostics_list = type(diagnostics) == "table" and diagnostics or {}
	local items = {}

	for index, diagnostic in ipairs(diagnostics_list) do
		local absolute_path = diagnostic.absolute_path
			or from_repo_relative_path(repo_root, diagnostic.file or metadata.relative_path or metadata.buffer_path)
		local relative_path = normalize_repo_relative_path(to_repo_relative_path(repo_root, absolute_path))
		local original_line = (tonumber(diagnostic.lnum) or 0) + 1
		local item_id = vim.fn.sha256(table.concat({
			metadata.id_seed or "",
			relative_path or "",
			tostring(original_line),
			diagnostic.message or "",
			tostring(index),
		}, "|"))

		table.insert(items, {
			id = item_id,
			file = relative_path,
			original_line = original_line,
			message = diagnostic.message or "",
			severity = severity_label(diagnostic.severity),
			source = diagnostic.source or "pitaco",
			anchor = capture_anchor(absolute_path, original_line),
		})
	end

	local review = {
		id = vim.fn.sha256(table.concat({
			repo_root or "",
			metadata.mode or "",
			metadata.provider or "",
			metadata.model_id or "",
			metadata.head or "",
			metadata.merge_base or "",
			metadata.content_hash or "",
			created_at,
		}, "|")),
		created_at = created_at,
		repo_root = repo_root,
		mode = metadata.mode,
		provider = metadata.provider,
		model_id = metadata.model_id,
		head = metadata.head,
		merge_base = metadata.merge_base,
		base_branch = metadata.base_branch,
		content_hash = metadata.content_hash,
		relative_path = metadata.relative_path,
		item_count = #items,
		items = items,
	}

	local ok, error_message = M.save_review(review)
	if not ok then
		return nil, error_message
	end

	return review
end

function M.get_active_entry(repo_root)
	local normalized_root = normalize_path(repo_root)
	if normalized_root == nil then
		return nil
	end

	local state = M.load()
	local entry = state.active[normalized_root]
	if type(entry) ~= "table" or type(entry.review_id) ~= "string" or entry.review_id == "" then
		return nil
	end

	entry.hidden_item_ids = type(entry.hidden_item_ids) == "table" and entry.hidden_item_ids or {}
	return entry
end

function M.get_active_review(repo_root)
	local entry = M.get_active_entry(repo_root)
	if entry == nil then
		return nil, nil
	end

	return M.get_review(entry.review_id), entry
end

function M.activate_review(repo_root, review_id)
	local normalized_root = normalize_path(repo_root)
	if normalized_root == nil then
		return false, "invalid repo root"
	end

	local state = M.load()
	state.active[normalized_root] = {
		review_id = review_id,
		hidden_item_ids = {},
		updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	return M.save(state)
end

function M.clear_active_review(repo_root)
	local normalized_root = normalize_path(repo_root)
	if normalized_root == nil then
		return false, "invalid repo root"
	end

	local state = M.load()
	state.active[normalized_root] = nil
	return M.save(state)
end

function M.hide_items(repo_root, item_ids)
	local normalized_root = normalize_path(repo_root)
	if normalized_root == nil then
		return false, "invalid repo root"
	end

	local state = M.load()
	local entry = state.active[normalized_root]
	if type(entry) ~= "table" then
		return false, "no active review"
	end

	entry.hidden_item_ids = type(entry.hidden_item_ids) == "table" and entry.hidden_item_ids or {}
	local hidden = {}
	for _, id in ipairs(entry.hidden_item_ids) do
		hidden[id] = true
	end
	for _, id in ipairs(item_ids or {}) do
		if type(id) == "string" and id ~= "" and not hidden[id] then
			table.insert(entry.hidden_item_ids, id)
			hidden[id] = true
		end
	end

	state.active[normalized_root] = entry
	return M.save(state)
end

function M.is_hidden(active_entry, item_id)
	if type(active_entry) ~= "table" or type(active_entry.hidden_item_ids) ~= "table" then
		return false
	end

	for _, hidden_id in ipairs(active_entry.hidden_item_ids) do
		if hidden_id == item_id then
			return true
		end
	end

	return false
end

function M.state_path()
	return state_file_path()
end

return M
