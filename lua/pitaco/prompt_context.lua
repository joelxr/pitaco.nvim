local M = {}

local function format_list(items)
	if type(items) ~= "table" or vim.tbl_isempty(items) then
		return "none"
	end

	return table.concat(items, ", ")
end

function M.has_project_summary(summary)
	return type(summary) == "table" and (tonumber(summary.file_count) or 0) > 0
end

function M.has_relevant_chunks(chunks)
	return type(chunks) == "table" and not vim.tbl_isempty(chunks)
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
	return table.concat({
		("Repository: %s"):format(summary.repository_name or "unknown"),
		("Indexed files: %s"):format(summary.file_count or 0),
		("Indexed chunks: %s"):format(summary.chunk_count or 0),
		("Languages: %s"):format(format_list(summary.languages)),
		("Top symbols: %s"):format(format_list(summary.top_symbols)),
	}, "\n")
end

function M.build_compact_project_summary(summary)
	return table.concat({
		("Repository: %s"):format(summary.repository_name or "unknown"),
		("Languages: %s"):format(format_list(summary.languages)),
	}, "\n")
end

function M.build_relevant_chunks(chunks)
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

function M.truncate_text(value, max_chars)
	if type(value) ~= "string" then
		return ""
	end

	local text = vim.trim(value)
	if max_chars == nil or max_chars <= 0 or #text <= max_chars then
		return text
	end

	return vim.trim(text:sub(1, max_chars)) .. "\n...(truncated)"
end

function M.truncate_text_middle(value, max_chars)
	if type(value) ~= "string" then
		return ""
	end

	local text = vim.trim(value)
	if max_chars == nil or max_chars <= 0 or #text <= max_chars then
		return text
	end

	local marker = "\n...(truncated middle)...\n"
	local available = max_chars - #marker
	if available <= 20 then
		return M.truncate_text(text, max_chars)
	end

	local head_chars = math.floor(available / 2)
	local tail_chars = available - head_chars
	local tail_start = #text - tail_chars + 1

	return vim.trim(text:sub(1, head_chars)) .. marker .. vim.trim(text:sub(tail_start))
end

function M.build_compact_relevant_chunks(chunks, opts)
	local max_chunks = opts and opts.max_chunks or 2
	local max_chars = opts and opts.max_chars or 1200
	local sections = {}

	for index, chunk in ipairs(chunks or {}) do
		if index > max_chunks then
			break
		end

		table.insert(sections, table.concat({
			("--- %s (%s, score=%.3f) ---"):format(
				chunk.file or "unknown",
				chunk.symbol or chunk.kind or "chunk",
				tonumber(chunk.score) or 0
			),
			M.truncate_text(chunk.code or "", max_chars),
		}, "\n"))
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
			("Changed symbols: %s"):format(#symbols > 0 and table.concat(symbols, "; ") or "none"),
		}, "\n"))
	end

	return table.concat(sections, "\n\n")
end

function M.build_compact_changed_outline(outline_files, opts)
	if type(outline_files) ~= "table" or vim.tbl_isempty(outline_files) then
		return "No compact syntax outline was retrieved for the changed files."
	end

	local max_files = opts and opts.max_files or 8
	local max_symbols = opts and opts.max_symbols or 4
	local sections = {}

	for file_index, entry in ipairs(outline_files) do
		if file_index > max_files then
			break
		end

		local symbols = {}
		for symbol_index, symbol in ipairs(entry.symbols or {}) do
			if symbol_index > max_symbols then
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
			("Changed lines: %s"):format(format_line_ranges(entry.changedLines)),
			("Changed symbols: %s"):format(#symbols > 0 and table.concat(symbols, "; ") or "none"),
		}, "\n"))
	end

	return table.concat(sections, "\n\n")
end

local function build_compact_match_group(label_line, matches, opts)
	local max_matches = opts and opts.max_matches or 2
	local max_chars = opts and opts.max_chars or 180
	local sections = { label_line }

	for index, match in ipairs(matches or {}) do
		if index > max_matches then
			break
		end

		local header = ("%s:%d"):format(match.file or "unknown", tonumber(match.line) or 0)
		local body = M.truncate_text(match.text or match.snippet or "", max_chars)
		table.insert(sections, header .. " " .. body)
	end

	return table.concat(sections, "\n")
end

function M.build_compact_symbol_usages(symbol_usages, opts)
	if type(symbol_usages) ~= "table" or vim.tbl_isempty(symbol_usages) then
		return "No likely downstream usages were retrieved for the changed symbols."
	end

	local max_groups = opts and opts.max_groups or 2
	local sections = {}

	for index, entry in ipairs(symbol_usages) do
		if index > max_groups then
			break
		end
		table.insert(sections, build_compact_match_group(
			("Symbol: %s (%s)"):format(entry.symbol or "unknown", entry.definition_file or "unknown"),
			entry.matches,
			opts
		))
	end

	return table.concat(sections, "\n\n")
end

function M.build_compact_file_consumers(file_consumers, opts)
	if type(file_consumers) ~= "table" or vim.tbl_isempty(file_consumers) then
		return "No likely direct consumers were retrieved for the changed files."
	end

	local max_groups = opts and opts.max_groups or 3
	local sections = {}

	for index, entry in ipairs(file_consumers) do
		if index > max_groups then
			break
		end
		table.insert(sections, build_compact_match_group(
			("Changed file: %s"):format(entry.file or "unknown"),
			entry.consumers,
			opts
		))
	end

	return table.concat(sections, "\n\n")
end

function M.build_compact_related_tests(related_tests, opts)
	if type(related_tests) ~= "table" or vim.tbl_isempty(related_tests) then
		return "No likely related tests were retrieved for the changed files or symbols."
	end

	local max_groups = opts and opts.max_groups or 2
	local sections = {}

	for index, entry in ipairs(related_tests) do
		if index > max_groups then
			break
		end
		table.insert(sections, build_compact_match_group(entry.label or "Related tests", entry.matches, opts))
	end

	return table.concat(sections, "\n\n")
end

function M.build_symbol_usages(symbol_usages)
	if type(symbol_usages) ~= "table" or vim.tbl_isempty(symbol_usages) then
		return "No likely downstream usages were retrieved for the changed symbols."
	end

	local sections = {}
	for _, entry in ipairs(symbol_usages) do
		local matches = {}
		for _, match in ipairs(entry.matches or {}) do
			local header = ("%s:%d:%d"):format(
				match.file or "unknown",
				tonumber(match.line) or 0,
				tonumber(match.column) or 0
			)
			local body = M.truncate_text(match.snippet or match.text or "", 400)
			table.insert(matches, table.concat({ header, body }, "\n"))
		end

		table.insert(sections, table.concat({
			("Symbol: %s"):format(entry.symbol or "unknown"),
			("Defined in changed file: %s"):format(entry.definition_file or "unknown"),
			(#matches > 0 and table.concat(matches, "\n\n") or "No matches"),
		}, "\n"))
	end

	return table.concat(sections, "\n\n")
end

function M.build_file_consumers(file_consumers)
	if type(file_consumers) ~= "table" or vim.tbl_isempty(file_consumers) then
		return "No likely direct consumers were retrieved for the changed files."
	end

	local sections = {}
	for _, entry in ipairs(file_consumers) do
		local consumers = {}
		for _, match in ipairs(entry.consumers or {}) do
			local header = ("%s:%d:%d"):format(
				match.file or "unknown",
				tonumber(match.line) or 0,
				tonumber(match.column) or 0
			)
			local via = match.candidate and match.candidate ~= "" and ("Matched import path: " .. match.candidate) or nil
			local body = M.truncate_text(match.snippet or match.text or "", 400)
			local parts = { header }
			if via ~= nil then
				table.insert(parts, via)
			end
			table.insert(parts, body)
			table.insert(consumers, table.concat(parts, "\n"))
		end

		table.insert(sections, table.concat({
			("Changed file: %s"):format(entry.file or "unknown"),
			(#consumers > 0 and table.concat(consumers, "\n\n") or "No matches"),
		}, "\n"))
	end

	return table.concat(sections, "\n\n")
end

function M.build_related_tests(related_tests)
	if type(related_tests) ~= "table" or vim.tbl_isempty(related_tests) then
		return "No likely related tests were retrieved for the changed files or symbols."
	end

	local sections = {}
	for _, entry in ipairs(related_tests) do
		local matches = {}
		for _, match in ipairs(entry.matches or {}) do
			local header = ("%s:%d:%d"):format(
				match.file or "unknown",
				tonumber(match.line) or 0,
				tonumber(match.column) or 0
			)
			local via = match.candidate and match.candidate ~= "" and ("Matched test reference: " .. match.candidate) or nil
			local body = M.truncate_text(match.snippet or match.text or "", 400)
			local parts = { header }
			if via ~= nil then
				table.insert(parts, via)
			end
			table.insert(parts, body)
			table.insert(matches, table.concat(parts, "\n"))
		end

		table.insert(sections, table.concat({
			entry.label or "Related tests",
			(#matches > 0 and table.concat(matches, "\n\n") or "No matches"),
		}, "\n"))
	end

	return table.concat(sections, "\n\n")
end

return M
