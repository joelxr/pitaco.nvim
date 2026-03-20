local M = {}
local file_header_written = false
local file_write_warned = false

local function is_enabled()
	return vim.g.pitaco_debug == true
end

local function debug_log_path()
	local config = require("pitaco.config")
	return config.get_debug_log_path()
end

local function notify_file_write_failure(err)
	if file_write_warned then
		return
	end

	file_write_warned = true
	vim.schedule(function()
		vim.notify("pitaco debug log write failed: " .. tostring(err), vim.log.levels.WARN, { title = "pitaco" })
	end)
end

local function append_file(lines)
	local path = debug_log_path()
	local dir = vim.fn.fnamemodify(path, ":h")
	local ok, err = pcall(function()
		vim.fn.mkdir(dir, "p")

		if not file_header_written then
			vim.fn.writefile({
				("==== Pitaco debug session %s ===="):format(os.date("!%Y-%m-%dT%H:%M:%SZ")),
				("log_path=%s"):format(path),
				"",
			}, path, "a")
			file_header_written = true
		end

		vim.fn.writefile(lines, path, "a")
	end)

	if not ok then
		notify_file_write_failure(err)
	end
end

local function normalize_text(value)
	if value == nil then
		return "<nil>"
	end

	if type(value) ~= "string" then
		value = tostring(value)
	end

	return value
end

local function append_debug_entry(kind, label, value)
	if not is_enabled() then
		return
	end

	local text = normalize_text(value)
	local lines = {
		("[%s] %s %s"):format(os.date("!%Y-%m-%dT%H:%M:%SZ"), kind, label),
	}

	if text == "" then
		table.insert(lines, "<empty>")
	else
		vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
	end

	table.insert(lines, "")
	append_file(lines)
end

local function schedule_log(level, message)
	vim.schedule(function()
		vim.notify(message, level, { title = "pitaco" })
	end)
end

local function emit_debug(message, persist_to_file)
	if not is_enabled() then
		return
	end

	if persist_to_file ~= false then
		append_debug_entry("debug", "message", message)
	end

	schedule_log(vim.log.levels.DEBUG, "[debug] " .. message)
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

function M.path()
	return debug_log_path()
end

function M.debug(message)
	emit_debug(message, true)
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

	append_debug_entry("table", label, encoded)
	emit_debug(label .. ": " .. truncate(encoded, max_len or 600), false)
end

function M.preview_json(label, json_data, max_len)
	if not is_enabled() then
		return
	end

	append_debug_entry("json", label, json_data)
	emit_debug(label .. ": " .. truncate(json_data, max_len or 600), false)
end

function M.preview_text(label, value, max_len)
	if not is_enabled() then
		return
	end

	append_debug_entry("text", label, value)
	emit_debug(label .. ": " .. truncate(value, max_len or 300), false)
end

return M
