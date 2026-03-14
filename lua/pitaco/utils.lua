local M = {}

function M.prepare_code_snippet(buf_nr, starting_line_number, ending_line_number)
	local lines = vim.api.nvim_buf_get_lines(buf_nr, starting_line_number - 1, ending_line_number, false)
	if vim.tbl_isempty(lines) then
		return string.format("%02d ", starting_line_number)
	end
	local max_digits = string.len(tostring(#lines + starting_line_number))

	for i, line in ipairs(lines) do
		lines[i] = string.format("%0" .. max_digits .. "d", i - 1 + starting_line_number) .. " " .. line
	end

	local text = table.concat(lines, "\n")
	return text
end

function M.get_buf_name(buf_nr)
	return vim.fn.fnamemodify(vim.fn.bufname(buf_nr), ":t")
end

function M.get_buffer_number()
	return vim.api.nvim_get_current_buf()
end

-- Get the appropriate comment syntax for a filetype
function M.get_comment_syntax(filetype)
	local comment_map = {
		-- C-style languages
		c = "// ",
		cpp = "// ",
		java = "// ",
		javascript = "// ",
		typescript = "// ",
		go = "// ",
		rust = "// ",
		swift = "// ",
		csharp = "// ",

		-- Script languages
		python = "# ",
		ruby = "# ",
		perl = "# ",
		bash = "# ",
		sh = "# ",
		zsh = "# ",

		-- Web languages
		html = "<!-- ",
		xml = "<!-- ",
		css = "/* ",

		-- Lisp-like languages
		lisp = ";; ",
		scheme = ";; ",
		clojure = ";; ",

		-- Others
		lua = "-- ",
		haskell = "-- ",
		sql = "-- ",
		vim = '" ',
		tex = "% ",
		matlab = "% ",
		r = "# ",
		php = "// ",
	}

	-- HTML-style comments need a closing tag
	local html_style = { html = true, xml = true }

	-- CSS-style comments need a closing tag
	local css_style = { css = true }

	local syntax = comment_map[filetype] or "-- " -- Default to Lua-style
	local suffix = ""

	if html_style[filetype] then
		suffix = " -->"
	elseif css_style[filetype] then
		suffix = " */"
	end

	return syntax, suffix
end

return M
