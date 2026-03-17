local M = {}

local function format_list(items)
	if type(items) ~= "table" or vim.tbl_isempty(items) then
		return "none"
	end

	return table.concat(items, ", ")
end

function M.trim_text(value)
	if type(value) ~= "string" then
		return ""
	end

	return vim.trim(value)
end

function M.build_numbered_buffer_section(file_chunk)
	return table.concat({
		"Current buffer contents:",
		"The numeric prefix on each line is the real source line number in the file.",
		"Use only those prefixed numbers for `line=<num>` findings.",
		"Do not count lines from the prompt itself.",
		"```text",
		file_chunk,
		"```",
	}, "\n")
end

function M.build_project_summary(summary)
	if type(summary) ~= "table" then
		return "Project summary unavailable."
	end

	return table.concat({
		("Repository: %s"):format(summary.repository_name or "unknown"),
		("Indexed files: %s"):format(summary.file_count or 0),
		("Indexed chunks: %s"):format(summary.chunk_count or 0),
		("Languages: %s"):format(format_list(summary.languages)),
		("Top symbols: %s"):format(format_list(summary.top_symbols)),
	}, "\n")
end

function M.build_relevant_chunks(chunks)
	if type(chunks) ~= "table" or vim.tbl_isempty(chunks) then
		return "No related code chunks were retrieved."
	end

	local sections = {}
	for _, chunk in ipairs(chunks) do
		table.insert(sections, ("--- %s (%s, score=%.3f) ---\n%s"):format(
			chunk.file or "unknown",
			chunk.symbol or chunk.kind or "chunk",
			tonumber(chunk.score) or 0,
			chunk.code or ""
		))
	end

	return table.concat(sections, "\n\n")
end

local function format_line_ranges(ranges)
	if type(ranges) ~= "table" or vim.tbl_isempty(ranges) then
		return "unknown"
	end

	local parts = {}
	for _, range in ipairs(ranges) do
		local start_line = tonumber(range.startLine) or 0
		local end_line = tonumber(range.endLine) or start_line
		if start_line > 0 then
			if end_line > start_line then
				table.insert(parts, ("%d-%d"):format(start_line, end_line))
			else
				table.insert(parts, tostring(start_line))
			end
		end
	end

	return #parts > 0 and table.concat(parts, ", ") or "unknown"
end

function M.build_changed_outline(outline_files)
	if type(outline_files) ~= "table" or vim.tbl_isempty(outline_files) then
		return "No compact syntax outline was retrieved for the changed files."
	end

	local sections = {}
	for _, entry in ipairs(outline_files) do
		local symbols = {}
		for index, symbol in ipairs(entry.symbols or {}) do
			if index > 8 then
				break
			end
			table.insert(symbols, ("%s %s (%d-%d)"):format(
				symbol.kind or "symbol",
				symbol.symbol or "unknown",
				tonumber(symbol.startLine) or 0,
				tonumber(symbol.endLine) or 0
			))
		end

		table.insert(sections, table.concat({
			("File: %s"):format(entry.file or "unknown"),
			("Language: %s"):format(entry.language or "unknown"),
			("Changed lines: %s"):format(format_line_ranges(entry.changedLines)),
			("Imports: %s"):format(format_list(entry.imports)),
			("Exports: %s"):format(format_list(entry.exports)),
			("Changed symbols: %s"):format(#symbols > 0 and table.concat(symbols, "; ") or "none"),
		}, "\n"))
	end

	return table.concat(sections, "\n\n")
end

return M
