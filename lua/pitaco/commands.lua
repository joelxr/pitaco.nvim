local M = {}

local provider_factory = require("pitaco.providers.factory")
local config = require("pitaco.config")
local utils = require("pitaco.utils")
local requests = require("pitaco.requests")
local fewshot = require("pitaco.fewshot")
local commit = require("pitaco.commit")
local namespace = vim.api.nvim_create_namespace("pitaco")

function M.review()
	local provider = provider_factory.create_provider(config.get_provider())
	local all_requests, num_requests, line_count = provider.prepare_requests(fewshot.messages)
	requests.make_requests(namespace, provider, all_requests, num_requests, 0, line_count)
end

function M.clear()
	local buffer_number = utils.get_buffer_number()
	vim.diagnostic.reset(namespace, buffer_number)
end

function M.clear_line()
	local buffer_number = utils.get_buffer_number()
	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	vim.diagnostic.set(namespace, buffer_number, {}, { lnum = line_num - 1 })
end

function M.comment()
	local buffer_number = utils.get_buffer_number()
	local diagnostics = vim.diagnostic.get(buffer_number, { namespace = namespace })

	if #diagnostics == 0 then
		vim.notify("No diagnostics found to comment", vim.log.levels.INFO)
		return
	end

	-- Get filetype for comment syntax
	local filetype = vim.bo[buffer_number].filetype
	local comment_prefix, comment_suffix = utils.get_comment_syntax(filetype)

	-- Sort diagnostics by line number
	table.sort(diagnostics, function(a, b)
		return a.lnum < b.lnum
	end)

	-- Get cursor position
	local cursor_pos = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor_pos[1]

	-- Create comment lines
	local comment_lines = {}

	-- Add header
	table.insert(comment_lines, comment_prefix .. "Pitaco Diagnostics Summary" .. comment_suffix)

	-- Add each diagnostic as a list item
	for _, diag in ipairs(diagnostics) do
		local line_num = diag.lnum + 1 -- Convert to 1-based line numbers for display
		local message = diag.message
		-- Sanitize message by replacing newlines with spaces
		message = message:gsub("\n", " ")
		table.insert(comment_lines, comment_prefix .. "- Line " .. line_num .. ": " .. message .. comment_suffix)
	end

	vim.api.nvim_buf_set_lines(buffer_number, cursor_line, cursor_line, false, comment_lines)

	vim.notify("Added " .. #comment_lines .. " comment lines with diagnostics summary", vim.log.levels.INFO)
end

function M.commit()
	commit.run()
end

return M
