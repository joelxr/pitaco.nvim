local M = {}

local function is_enabled()
	return vim.g.pitaco_debug == true
end

local function schedule_log(level, message)
	vim.schedule(function()
		vim.notify(message, level, { title = "pitaco" })
	end)
end

local function truncate(value, max_len)
	if type(value) ~= "string" then
		value = tostring(value)
	end

	if #value <= max_len then
		return value
	end

	return value:sub(1, max_len) .. "...(truncated)"
end

function M.enabled()
	return is_enabled()
end

function M.debug(message)
	if not is_enabled() then
		return
	end

	schedule_log(vim.log.levels.DEBUG, "[debug] " .. message)
end

function M.debug_table(label, value, max_len)
	if not is_enabled() then
		return
	end

	local ok, encoded = pcall(vim.json.encode, value)
	if not ok then
		M.debug(label .. ": <failed to encode: " .. tostring(encoded) .. ">")
		return
	end

	M.debug(label .. ": " .. truncate(encoded, max_len or 600))
end

function M.preview_json(label, json_data, max_len)
	if not is_enabled() then
		return
	end

	M.debug(label .. ": " .. truncate(json_data, max_len or 600))
end

function M.preview_text(label, value, max_len)
	if not is_enabled() then
		return
	end

	M.debug(label .. ": " .. truncate(value, max_len or 300))
end

return M
