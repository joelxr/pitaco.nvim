local Job = require("plenary.job")
local context_engine = require("pitaco.context_engine")
local log = require("pitaco.log")

local M = {}

local MAX_SYMBOLS = 6
local MAX_MATCHES_PER_SYMBOL = 4
local MAX_TOTAL_MATCHES = 12
local MAX_CONSUMER_FILES = 6
local MAX_CONSUMERS_PER_FILE = 4
local MAX_TOTAL_CONSUMERS = 12
local MAX_TEST_GROUPS = 6
local MAX_TEST_MATCHES_PER_GROUP = 4
local MAX_TOTAL_TEST_MATCHES = 12
local SNIPPET_RADIUS = 1
local GENERIC_SYMBOLS = {
	["_"] = true,
	["child"] = true,
	["children"] = true,
	["data"] = true,
	["dataset"] = true,
	["defaultparams"] = true,
	["params"] = true,
	["payload"] = true,
	["proposal"] = true,
	["query"] = true,
	["result"] = true,
	["results"] = true,
	["update"] = true,
	["value"] = true,
}
local GENERIC_SUFFIXES = {
	"item",
	"items",
	"data",
	"result",
	"results",
	"params",
	"payload",
	"query",
	"value",
	"update",
}
local GENERIC_TOKENS = {
	["async"] = true,
	["await"] = true,
	["const"] = true,
	["false"] = true,
	["function"] = true,
	["line"] = true,
	["null"] = true,
	["return"] = true,
	["true"] = true,
	["undefined"] = true,
}

local function trim(value)
	if type(value) ~= "string" then
		return ""
	end

	return vim.trim(value)
end

local function join_lines(lines)
	if type(lines) ~= "table" or vim.tbl_isempty(lines) then
		return ""
	end

	return table.concat(lines, "\n")
end

local function run_job(command, args, cwd, timeout)
	local stdout = {}
	local stderr = {}
	local job = Job:new({
		command = command,
		args = args,
		cwd = cwd,
		on_stdout = function(_, line)
			if line ~= nil and line ~= "" then
				table.insert(stdout, line)
			end
		end,
		on_stderr = function(_, line)
			if line ~= nil and line ~= "" then
				table.insert(stderr, line)
			end
		end,
	})

	local ok, result = pcall(job.sync, job, timeout)
	if not ok then
		return nil, result
	end

	if job.code ~= 0 then
		local stderr_text = join_lines(stderr)
		if stderr_text ~= "" then
			return nil, stderr_text
		end
		return result or stdout, nil
	end

	return result or stdout, nil
end

local function is_identifier_symbol(symbol)
	return type(symbol) == "string" and symbol:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function is_high_signal_symbol(symbol)
	if not is_identifier_symbol(symbol) then
		return false
	end

	local normalized = symbol:lower()
	if #normalized < 4 then
		return false
	end

	for _, suffix in ipairs(GENERIC_SUFFIXES) do
		if normalized ~= suffix and vim.endswith(normalized, suffix) then
			local prefix = normalized:sub(1, #normalized - #suffix)
			if #prefix < 6 then
				return false
			end
		end
	end

	return not GENERIC_SYMBOLS[normalized]
end

local is_test_file

local function extract_changed_symbols(changed_outline)
	local collected = {}
	local seen = {}

	for _, file_entry in ipairs(changed_outline or {}) do
		if not is_test_file(file_entry.file) then
			for _, symbol in ipairs(file_entry.symbols or {}) do
				local name = trim(symbol.symbol)
				if name ~= "" and name ~= "unknown" and is_high_signal_symbol(name) and not seen[name] then
					seen[name] = true
					table.insert(collected, {
						symbol = name,
						file = file_entry.file,
					})
				end
				if #collected >= MAX_SYMBOLS then
					return collected
				end
			end
		end
	end

	return collected
end

local function build_changed_file_set(changed_outline)
	local changed = {}
	for _, file_entry in ipairs(changed_outline or {}) do
		if type(file_entry.file) == "string" and file_entry.file ~= "" then
			changed[file_entry.file] = true
		end
	end
	return changed
end

local function strip_extension(path)
	return (path or ""):gsub("%.[^./]+$", "")
end

local function build_module_candidates(relative_path)
	local candidates = {}
	local seen = {}
	local base = strip_extension(relative_path)

	local function add(value)
		if type(value) ~= "string" or value == "" or seen[value] then
			return
		end
		seen[value] = true
		table.insert(candidates, value)
	end

	add(base)
	add(base:gsub("^server/", ""))

	if base:sub(-6) == "/index" then
		local without_index = base:sub(1, -7)
		add(without_index)
		add(without_index:gsub("^server/", ""))
	end

	local basename = vim.fn.fnamemodify(base, ":t")
	if basename ~= "" then
		add("./" .. basename)
	end

	return candidates
end

local function split_identifier(token)
	local normalized = trim(token)
	if normalized == "" then
		return {}
	end

	normalized = normalized:gsub("([a-z0-9])([A-Z])", "%1 %2")
	normalized = normalized:gsub("[^%w]+", " ")
	local parts = {}
	for _, part in ipairs(vim.split(normalized:lower(), "%s+", { trimempty = true })) do
		if #part >= 3 and not GENERIC_TOKENS[part] then
			table.insert(parts, part)
		end
	end
	return parts
end

local function collect_diff_tokens(diff_text)
	local tokens = {}
	local seen = {}

	local function add(token)
		if type(token) ~= "string" or token == "" or seen[token] or GENERIC_TOKENS[token] then
			return
		end
		if #token < 3 then
			return
		end
		seen[token] = true
		table.insert(tokens, token)
	end

	for _, line in ipairs(vim.split(diff_text or "", "\n", { plain = true })) do
		local prefix = line:sub(1, 1)
		if (prefix == "+" or prefix == "-")
			and not vim.startswith(line, "+++")
			and not vim.startswith(line, "---")
		then
			for _, token in ipairs(split_identifier(line:sub(2))) do
				add(token)
			end
		end
	end

	return tokens
end

local function load_index_chunks(root)
	if type(root) ~= "string" or root == "" then
		return nil
	end

	local path = vim.fs.joinpath(root, ".repo-pitaco", "index", "chunks.json")
	if vim.loop.fs_stat(path) == nil then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or type(lines) ~= "table" then
		return nil
	end

	local payload = table.concat(lines, "\n")
	if payload == "" then
		return nil
	end

	local decoded_ok, decoded = pcall(vim.json.decode, payload)
	if not decoded_ok or type(decoded) ~= "table" then
		return nil
	end

	return decoded
end

local function build_token_set(tokens)
	local token_set = {}
	for _, token in ipairs(tokens or {}) do
		token_set[token] = true
	end
	return token_set
end

local function path_segments(path)
	local segments = {}
	for _, part in ipairs(vim.split(path or "", "/", { trimempty = true })) do
		table.insert(segments, part)
	end
	return segments
end

local function shared_path_prefix_depth(left, right)
	local left_segments = path_segments(left)
	local right_segments = path_segments(right)
	local depth = 0
	local limit = math.min(#left_segments, #right_segments)

	for index = 1, limit do
		if left_segments[index] ~= right_segments[index] then
			break
		end
		depth = depth + 1
	end

	return depth
end

local function best_changed_path_overlap(path, changed_files)
	local best = 0
	for changed_file in pairs(changed_files or {}) do
		best = math.max(best, shared_path_prefix_depth(path, changed_file))
	end
	return best
end

local function score_diff_chunk(chunk, diff_tokens, diff_token_set, changed_files, changed_symbols)
	if type(chunk) ~= "table" then
		return nil
	end

	if changed_files[chunk.file] then
		return nil
	end

	if is_test_file(chunk.file) then
		return nil
	end

	local score = 0
	local haystack = table.concat({
		chunk.file or "",
		chunk.symbol or "",
		chunk.code or "",
		table.concat(chunk.imports or {}, " "),
		table.concat(chunk.exports or {}, " "),
	}, "\n"):lower()

	if type(chunk.symbol) == "string" and changed_symbols[chunk.symbol:lower()] then
		score = score + 3.5
	end

	local path_overlap = best_changed_path_overlap(chunk.file or "", changed_files)
	if path_overlap >= 3 then
		score = score + (path_overlap * 0.75)
	end

	for _, token in ipairs(diff_tokens or {}) do
		if haystack:find(token, 1, true) ~= nil then
			score = score + 0.35
		end
	end

	if type(chunk.symbol) == "string" then
		for _, token in ipairs(split_identifier(chunk.symbol)) do
			if diff_token_set[token] then
				score = score + 0.6
			end
		end
	end

	if score <= 0 then
		return nil
	end

	if path_overlap < 3 and not (type(chunk.symbol) == "string" and changed_symbols[chunk.symbol:lower()]) then
		return nil
	end

	if score < 2.5 then
		return nil
	end

	return score
end

local function collect_diff_relevant_chunks(review_context, limit)
	if type(review_context) ~= "table" or type(review_context.root) ~= "string" then
		return nil
	end

	local chunks = load_index_chunks(review_context.root)
	if type(chunks) ~= "table" or vim.tbl_isempty(chunks) then
		return nil
	end

	local diff_tokens = collect_diff_tokens(review_context.git_diff)
	for _, entry in ipairs(extract_changed_symbols(review_context.changed_outline)) do
		for _, token in ipairs(split_identifier(entry.symbol)) do
			table.insert(diff_tokens, token)
		end
	end

	if vim.tbl_isempty(diff_tokens) then
		return nil
	end

	local changed_files = build_changed_file_set(review_context.changed_outline)
	local changed_symbol_set = {}
	for _, entry in ipairs(extract_changed_symbols(review_context.changed_outline)) do
		changed_symbol_set[entry.symbol:lower()] = true
	end
	local diff_token_set = build_token_set(diff_tokens)
	local scored = {}

	for _, chunk in ipairs(chunks) do
		local score = score_diff_chunk(chunk, diff_tokens, diff_token_set, changed_files, changed_symbol_set)
		if score ~= nil then
			table.insert(scored, {
				id = chunk.id,
				file = chunk.file,
				language = chunk.language,
				kind = chunk.kind,
				symbol = chunk.symbol,
				startLine = chunk.startLine,
				endLine = chunk.endLine,
				score = score,
				code = chunk.code,
				imports = chunk.imports,
				exports = chunk.exports,
			})
		end
	end

	table.sort(scored, function(left, right)
		if left.score ~= right.score then
			return left.score > right.score
		end
		if (left.file or "") ~= (right.file or "") then
			return (left.file or "") < (right.file or "")
		end
		return (tonumber(left.startLine) or 0) < (tonumber(right.startLine) or 0)
	end)

	if #scored > (limit or 4) then
		scored = vim.list_slice(scored, 1, limit or 4)
	end

	return scored
end

is_test_file = function(path)
	return type(path) == "string"
		and (path:match("%.spec%.[^./]+$") ~= nil
			or path:match("%.test%.[^./]+$") ~= nil
			or path:match("__tests__/") ~= nil)
end

local function build_test_candidates(relative_path)
	local candidates = {}
	local seen = {}
	local base = strip_extension(relative_path)
	local basename = vim.fn.fnamemodify(base, ":t")

	local function add(value)
		if type(value) ~= "string" or value == "" or seen[value] then
			return
		end
		seen[value] = true
		table.insert(candidates, value)
	end

	add(base)
	add(base:gsub("^server/", ""))
	if basename ~= "" then
		add(basename)
	end

	return candidates
end

local function parse_match_line(line)
	local file, line_num, column, text = line:match("^([^:]+):(%d+):(%d+):(.*)$")
	if file == nil then
		return nil
	end

	return {
		file = file,
		line = tonumber(line_num),
		column = tonumber(column),
		text = text or "",
	}
end

local function line_has_identifier(text, symbol)
	if type(text) ~= "string" or type(symbol) ~= "string" or text == "" or symbol == "" then
		return false
	end

	local pattern = "%f[%w_]" .. vim.pesc(symbol) .. "%f[^%w_]"
	return text:match(pattern) ~= nil
end

local function is_probably_comment_line(text)
	local trimmed = trim(text)
	return trimmed:match("^//") ~= nil
		or trimmed:match("^/%*") ~= nil
		or trimmed:match("^%*") ~= nil
		or trimmed:match("^#") ~= nil
end

local function is_self_symbol_match(symbol, match)
	if not line_has_identifier(match.text, symbol) then
		return false
	end

	local trimmed = trim(match.text)
	local escaped_symbol = vim.pesc(symbol)
	local patterns = {
		("^const%s+%b{}%s*=%s*require%b()"),
		"^const%s+" .. escaped_symbol .. "%s*=%s*",
		"^function%s+" .. escaped_symbol .. "%s*%(",
		"^async%s+function%s+" .. escaped_symbol .. "%s*%(",
		("^module%.exports%s*=%s*%b{}"),
	}

	for _, pattern in ipairs(patterns) do
		if trimmed:match(pattern) then
			return true
		end
	end

	return false
end

local function is_meaningful_symbol_match(symbol, match, definition_file)
	if type(match) ~= "table" or type(match.text) ~= "string" then
		return false
	end

	if not line_has_identifier(match.text, symbol) then
		return false
	end

	if is_probably_comment_line(match.text) then
		return false
	end

	if type(definition_file) == "string" and match.file == definition_file and is_self_symbol_match(symbol, match) then
		return false
	end

	return true
end

local function read_snippet(root, relative_path, target_line)
	local absolute_path = vim.fs.joinpath(root, relative_path)
	local ok, file_lines = pcall(vim.fn.readfile, absolute_path)
	if not ok or type(file_lines) ~= "table" or vim.tbl_isempty(file_lines) then
		return nil
	end

	local start_line = math.max((target_line or 1) - SNIPPET_RADIUS, 1)
	local end_line = math.min((target_line or 1) + SNIPPET_RADIUS, #file_lines)
	local width = math.max(#tostring(end_line), 2)
	local snippet_lines = {}

	for line_number = start_line, end_line do
		table.insert(snippet_lines, ("%0" .. width .. "d %s"):format(line_number, file_lines[line_number]))
	end

	return table.concat(snippet_lines, "\n")
end

local function collect_symbol_matches(root, symbol, definition_file, changed_files, timeout)
	local args = {
		"--line-number",
		"--column",
		"--no-heading",
		"--color",
		"never",
		"--smart-case",
	}

	if is_identifier_symbol(symbol) then
		table.insert(args, "--word-regexp")
	end

	table.insert(args, symbol)
	table.insert(args, ".")

	local output, error_message = run_job("rg", args, root, timeout)
	if error_message ~= nil then
		return nil, error_message
	end

	local external = {}
	local internal = {}
	for _, line in ipairs(output or {}) do
		local match = parse_match_line(line)
		if match ~= nil then
			match.file = match.file:gsub("^%./", "")
			if is_meaningful_symbol_match(symbol, match, definition_file) then
				match.snippet = read_snippet(root, match.file, match.line)
				if changed_files[match.file] then
					table.insert(internal, match)
				else
					table.insert(external, match)
				end
			end
		end
	end

	local selected = {}
	local function append_matches(source)
		for _, match in ipairs(source) do
			table.insert(selected, match)
			if #selected >= MAX_MATCHES_PER_SYMBOL then
				return true
			end
		end
		return false
	end

	if not append_matches(external) then
		append_matches(internal)
	end

	return selected, nil
end

local function collect_consumer_matches(root, relative_path, changed_files, timeout)
	local matches = {}
	local seen = {}
	local candidates = build_module_candidates(relative_path)

	for _, candidate in ipairs(candidates) do
		local output, error_message = run_job("rg", {
			"--line-number",
			"--column",
			"--no-heading",
			"--color",
			"never",
			"--fixed-strings",
			candidate,
			".",
		}, root, timeout)
		if error_message ~= nil then
			return nil, error_message
		end

		for _, line in ipairs(output or {}) do
			local match = parse_match_line(line)
			if match ~= nil then
				match.file = match.file:gsub("^%./", "")
				local key = ("%s:%s:%s"):format(match.file, match.line or 0, candidate)
				if not seen[key] and match.file ~= relative_path then
					seen[key] = true
					match.snippet = read_snippet(root, match.file, match.line)
					match.candidate = candidate
					match.is_changed_file = changed_files[match.file] == true
					table.insert(matches, match)
				end
			end
		end
	end

	table.sort(matches, function(left, right)
		if left.is_changed_file ~= right.is_changed_file then
			return not left.is_changed_file
		end
		if left.file ~= right.file then
			return left.file < right.file
		end
		return (left.line or 0) < (right.line or 0)
	end)

	if #matches > MAX_CONSUMERS_PER_FILE then
		matches = vim.list_slice(matches, 1, MAX_CONSUMERS_PER_FILE)
	end

	return matches, nil
end

local function collect_test_matches(root, label, candidates, changed_files, timeout)
	local matches = {}
	local seen = {}

	for _, candidate in ipairs(candidates or {}) do
		local output, error_message = run_job("rg", {
			"--line-number",
			"--column",
			"--no-heading",
			"--color",
			"never",
			"--fixed-strings",
			candidate,
			".",
		}, root, timeout)
		if error_message ~= nil then
			return nil, error_message
		end

		for _, line in ipairs(output or {}) do
			local match = parse_match_line(line)
			if match ~= nil then
				match.file = match.file:gsub("^%./", "")
				if is_test_file(match.file) and not changed_files[match.file] then
					local key = ("%s:%s:%s"):format(match.file, match.line or 0, candidate)
					if not seen[key] then
						seen[key] = true
						match.snippet = read_snippet(root, match.file, match.line)
						match.candidate = candidate
						table.insert(matches, match)
					end
				end
			end
		end
	end

	table.sort(matches, function(left, right)
		if left.file ~= right.file then
			return left.file < right.file
		end
		return (left.line or 0) < (right.line or 0)
	end)

	if #matches > MAX_TEST_MATCHES_PER_GROUP then
		matches = vim.list_slice(matches, 1, MAX_TEST_MATCHES_PER_GROUP)
	end

	if vim.tbl_isempty(matches) then
		return nil, nil
	end

	return {
		label = label,
		matches = matches,
	}, nil
end

function M.collect(bufnr, review_mode)
	local review_context = context_engine.collect_review_context(bufnr, review_mode)
	review_context.symbol_usages = {}
	review_context.file_consumers = {}
	review_context.related_tests = {}
	review_context.usage_error = nil

	if review_mode ~= "diff" then
		return review_context
	end

	if vim.fn.executable("rg") ~= 1 then
		review_context.usage_error = "ripgrep is unavailable; skipping changed-symbol usage search"
		return review_context
	end

	if type(review_context.root) ~= "string" or review_context.root == "" then
		return review_context
	end

	local diff_relevant_chunks = collect_diff_relevant_chunks(review_context, 2)
	if type(diff_relevant_chunks) == "table" and not vim.tbl_isempty(diff_relevant_chunks) then
		review_context.relevant_chunks = diff_relevant_chunks
	end

	local changed_symbols = extract_changed_symbols(review_context.changed_outline)
	local changed_files = build_changed_file_set(review_context.changed_outline)
	local total_matches = 0

	if not vim.tbl_isempty(changed_symbols) then
		for _, entry in ipairs(changed_symbols) do
			if total_matches >= MAX_TOTAL_MATCHES then
				break
			end

			local matches, error_message = collect_symbol_matches(
				review_context.root,
				entry.symbol,
				entry.file,
				changed_files,
				1500
			)
			if error_message ~= nil then
				log.debug("review symbol usage search failed: " .. error_message)
				review_context.usage_error = error_message
				break
			end

			if type(matches) == "table" and not vim.tbl_isempty(matches) then
				if total_matches + #matches > MAX_TOTAL_MATCHES then
					matches = vim.list_slice(matches, 1, MAX_TOTAL_MATCHES - total_matches)
				end

				table.insert(review_context.symbol_usages, {
					symbol = entry.symbol,
					definition_file = entry.file,
					matches = matches,
				})
				total_matches = total_matches + #matches
			end
		end
	end

	local total_consumers = 0
	for _, file_entry in ipairs(review_context.changed_outline or {}) do
		if total_consumers >= MAX_TOTAL_CONSUMERS or #review_context.file_consumers >= MAX_CONSUMER_FILES then
			break
		end

		if type(file_entry.file) == "string" and file_entry.file ~= "" then
			local consumers, error_message = collect_consumer_matches(
				review_context.root,
				file_entry.file,
				changed_files,
				1500
			)
			if error_message ~= nil then
				log.debug("review file consumer search failed: " .. error_message)
				review_context.usage_error = review_context.usage_error or error_message
				break
			end

			if type(consumers) == "table" and not vim.tbl_isempty(consumers) then
				if total_consumers + #consumers > MAX_TOTAL_CONSUMERS then
					consumers = vim.list_slice(consumers, 1, MAX_TOTAL_CONSUMERS - total_consumers)
				end

				table.insert(review_context.file_consumers, {
					file = file_entry.file,
					consumers = consumers,
				})
				total_consumers = total_consumers + #consumers
			end
		end
	end

	local total_test_matches = 0
	local related_tests = {}
	local related_test_seen = {}

	local function add_related_test_group(group)
		if group == nil or vim.tbl_isempty(group.matches or {}) then
			return
		end
		if related_test_seen[group.label] then
			return
		end
		if #related_tests >= MAX_TEST_GROUPS or total_test_matches >= MAX_TOTAL_TEST_MATCHES then
			return
		end
		if total_test_matches + #group.matches > MAX_TOTAL_TEST_MATCHES then
			group.matches = vim.list_slice(group.matches, 1, MAX_TOTAL_TEST_MATCHES - total_test_matches)
		end
		related_test_seen[group.label] = true
		total_test_matches = total_test_matches + #group.matches
		table.insert(related_tests, group)
	end

	for _, file_entry in ipairs(review_context.changed_outline or {}) do
		if #related_tests >= MAX_TEST_GROUPS or total_test_matches >= MAX_TOTAL_TEST_MATCHES then
			break
		end

		local path = file_entry.file
		if type(path) == "string" and path ~= "" then
			local group, error_message = collect_test_matches(
				review_context.root,
				("Changed file: %s"):format(path),
				build_test_candidates(path),
				changed_files,
				1500
			)
			if error_message ~= nil then
				log.debug("review related test search failed: " .. error_message)
				review_context.usage_error = review_context.usage_error or error_message
				break
			end
			add_related_test_group(group)
		end
	end

	for _, entry in ipairs(changed_symbols) do
		if #related_tests >= MAX_TEST_GROUPS or total_test_matches >= MAX_TOTAL_TEST_MATCHES then
			break
		end

		local group, error_message = collect_test_matches(
			review_context.root,
			("Changed symbol: %s"):format(entry.symbol),
			{ entry.symbol },
			changed_files,
			1500
		)
		if error_message ~= nil then
			log.debug("review symbol test search failed: " .. error_message)
			review_context.usage_error = review_context.usage_error or error_message
			break
		end
		add_related_test_group(group)
	end

	review_context.related_tests = related_tests

	return review_context
end

return M
