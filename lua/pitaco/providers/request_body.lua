local M = {}

local function write_temp_file(path, contents)
	local fd = assert(vim.loop.fs_open(path, "w", 384))
	local ok, err = pcall(vim.loop.fs_write, fd, contents, 0)
	vim.loop.fs_close(fd)
	if not ok then
		error(err)
	end
end

function M.prepare(json_data)
	local path = vim.fn.tempname() .. ".json"
	write_temp_file(path, json_data)
	return {
		in_file = path,
		path = path,
	}
end

function M.cleanup(state)
	if type(state) ~= "table" or type(state.path) ~= "string" or state.path == "" then
		return
	end

	pcall(vim.loop.fs_unlink, state.path)
end

return M
