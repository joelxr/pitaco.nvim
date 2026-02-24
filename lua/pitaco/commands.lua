local M = {}

local provider_factory = require("pitaco.providers.factory")
local config = require("pitaco.config")
local utils = require("pitaco.utils")
local requests = require("pitaco.requests")
local fewshot = require("pitaco.fewshot")
local commit = require("pitaco.commit")
local model_picker = require("pitaco.model_picker")
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

function M.models()
	model_picker.open()
end

function M.language(value)
	if value == nil or value == "" then
		local configured = config.get_configured_language()
		local current = config.get_language()
		if current == configured then
			vim.notify("Pitaco language: " .. current .. " (from config)", vim.log.levels.INFO)
		else
			vim.notify(
				"Pitaco language: " .. current .. " (session override, config: " .. configured .. ")",
				vim.log.levels.INFO
			)
		end
		return
	end

	local normalized = vim.trim(value)
	local lower = string.lower(normalized)

	if lower == "default" or lower == "reset" then
		config.clear_session_language()
		vim.notify("Pitaco language reset to config value: " .. config.get_configured_language(), vim.log.levels.INFO)
		return
	end

	local ok = config.set_session_language(normalized)
	if not ok then
		vim.notify("Pitaco language: invalid value", vim.log.levels.ERROR)
		return
	end

	vim.notify("Pitaco session language set to: " .. config.get_language(), vim.log.levels.INFO)
end

return M
