local M = {}

local function parse_prefix(line)
	local target_file = nil
	local line_num = nil
	local message = nil

	local file_path, file_line, rest = line:match("^file=(.-)%s+line=(%d+):%s*(.+)$")
	if file_path ~= nil then
		return file_path, tonumber(file_line), rest
	end

	local file_path_lines, file_line_lines, rest_lines = line:match("^file=(.-)%s+lines=(%d+)%-%d+:%s*(.+)$")
	if file_path_lines ~= nil then
		return file_path_lines, tonumber(file_line_lines), rest_lines
	end

	local current_line, current_rest = line:match("^line=(%d+):%s*(.+)$")
	if current_line ~= nil then
		return nil, tonumber(current_line), current_rest
	end

	local current_lines, current_lines_rest = line:match("^lines=(%d+)%-%d+:%s*(.+)$")
	if current_lines ~= nil then
		return nil, tonumber(current_lines), current_lines_rest
	end

	return target_file, line_num, message
end

function M.parse_text(text, current_file)
	local lines = vim.split(text or "", "\n")
	local diagnostics = {}

	for _, line in ipairs(lines) do
		local target_file, line_num, message = parse_prefix(line)
		if line_num ~= nil and message ~= nil then
			table.insert(diagnostics, {
				file = target_file or current_file,
				lnum = math.max(line_num - 1, 0),
				col = 0,
				message = message,
				severity = vim.diagnostic.severity.INFO,
				source = "pitaco",
			})
		elseif #diagnostics > 0 then
			diagnostics[#diagnostics].message = diagnostics[#diagnostics].message .. "\n" .. line
		end
	end

	return diagnostics
end

return M
