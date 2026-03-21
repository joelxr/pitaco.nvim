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
	local normalized_relative = normalize_repo_relative_path(relative_path)
	if normalized_root == nil or normalized_relative == nil then
		return normalize_path(relative_path)
	end

	return normalized_root:gsub("/+$", "") .. "/" .. normalized_relative
end

local function to_repo_relative_path(root, path)
	local normalized_root = normalize_path(root)
	local normalized_path = normalize_path(path)
	if normalized_root == nil or normalized_path == nil then
		return normalize_repo_relative_path(path)
	end

	normalized_root = normalized_root:gsub("/+$", "")
	normalized_path = normalized_path:gsub("/+$", ""):gsub("//+", "/")
	local prefix = normalized_root .. "/"
	if normalized_path:sub(1, #prefix) == prefix then
		return normalized_path:sub(#prefix + 1)
	end

	return normalize_repo_relative_path(normalized_path)
end

local function load_line_count(path)
	local normalized = normalize_path(path)
	if normalized == nil or vim.loop.fs_stat(normalized) == nil then
		return 0
	end

	local ok, lines = pcall(vim.fn.readfile, normalized)
	if not ok or type(lines) ~= "table" then
		return 0
	end

	return #lines
end

local function clamp_line(lnum, line_count)
	if line_count <= 0 then
		return 0
	end

	return math.max(0, math.min(lnum, line_count - 1))
end

local function build_changed_map(changed_outline)
	local changed = {}

	for _, entry in ipairs(changed_outline or {}) do
		local relative_path = normalize_repo_relative_path(entry.file)
		if relative_path ~= nil then
			local ranges = {}
			for _, range in ipairs(entry.changedLines or {}) do
				local start_line = tonumber(range.startLine) or 0
				local end_line = tonumber(range.endLine) or start_line
				if start_line > 0 then
					table.insert(ranges, {
						startLine = start_line,
						endLine = math.max(start_line, end_line),
					})
				end
			end
			changed[relative_path] = ranges
		end
	end

	return changed
end

local function is_within_changed_ranges(line_number, ranges)
	for _, range in ipairs(ranges or {}) do
		if line_number >= range.startLine and line_number <= range.endLine then
			return true
		end
	end

	return false
end

local function nearest_changed_line(line_number, ranges)
	local best_line = nil
	local best_distance = nil

	for _, range in ipairs(ranges or {}) do
		local candidate = line_number
		if line_number < range.startLine then
			candidate = range.startLine
		elseif line_number > range.endLine then
			candidate = range.endLine
		end

		local distance = math.abs(candidate - line_number)
		if best_distance == nil or distance < best_distance then
			best_distance = distance
			best_line = candidate
		end
	end

	return best_line
end

local function should_drop_message(message)
	local text = type(message) == "string" and message:lower() or ""
	if text == "" then
		return true
	end

	if text:find("no defect", 1, true) ~= nil then
		return true
	end

	if text:find("no functional defect", 1, true) ~= nil then
		return true
	end

	return false
end

function M.normalize(metadata, diagnostics)
	local normalized = {}
	local dropped = 0
	local changed_map = build_changed_map(metadata and metadata.changed_outline or {})
	local mode = metadata and metadata.mode or nil
	local repo_root = metadata and metadata.repo_root or nil
	local current_file = metadata and metadata.buffer_path or nil

	for _, diagnostic in ipairs(diagnostics or {}) do
		if not should_drop_message(diagnostic.message) then
			local item = vim.deepcopy(diagnostic)
			local keep = true
			local target_path = item.file or current_file

			if type(target_path) == "string" and target_path ~= "" and not target_path:find("^/") then
				target_path = from_repo_relative_path(repo_root, target_path)
			end

			local absolute_path = normalize_path(target_path)
			if absolute_path ~= nil then
				item.absolute_path = absolute_path
				item.file = to_repo_relative_path(repo_root, absolute_path) or item.file
			end

			if mode == "file" and current_file ~= nil then
				item.absolute_path = normalize_path(current_file)
				item.file = to_repo_relative_path(repo_root, current_file) or item.file
			end

			if item.absolute_path ~= nil then
				local line_count = load_line_count(item.absolute_path)
				item.lnum = clamp_line(tonumber(item.lnum) or 0, line_count)

				if mode == "diff" then
					local relative_path = normalize_repo_relative_path(item.file)
					local ranges = changed_map[relative_path]
					if ranges == nil then
						dropped = dropped + 1
						keep = false
					end

					if keep then
						local line_number = (tonumber(item.lnum) or 0) + 1
						if not is_within_changed_ranges(line_number, ranges) then
							local relocated = nearest_changed_line(line_number, ranges)
							if relocated == nil then
								dropped = dropped + 1
								keep = false
							else
								item.lnum = math.max(relocated - 1, 0)
							end
						end
					end
				end
			else
				dropped = dropped + 1
				keep = false
			end

			if keep then
				table.insert(normalized, item)
			end
		else
			dropped = dropped + 1
		end
	end

	return normalized, dropped
end

return M
