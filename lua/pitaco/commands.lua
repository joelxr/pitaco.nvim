local M = {}

local provider_factory = require("pitaco.providers.factory")
local config = require("pitaco.config")
local utils = require("pitaco.utils")
local requests = require("pitaco.requests")
local fewshot = require("pitaco.fewshot")
local commit = require("pitaco.commit")
local summary = require("pitaco.summary")
local model_picker = require("pitaco.model_picker")
local context_engine = require("pitaco.context_engine")
local review_runtime = require("pitaco.review_runtime")
local review_store = require("pitaco.review_store")
local review_renderer = require("pitaco.review_renderer")
local review_ui = require("pitaco.review_ui")
local namespace = review_runtime.get_namespace()

local function normalize_scope(scope)
	if type(scope) ~= "string" then
		return nil
	end

	local trimmed = vim.trim(scope)
	if trimmed == "" then
		return nil
	end

	local lowered = trimmed:lower()
	if lowered == "default" or lowered == "base" or lowered == "global" then
		return nil
	end

	return trimmed
end

local function scope_label(scope)
	return normalize_scope(scope) or "default"
end

local function normalize_review_mode(mode)
	if mode == nil or mode == "" then
		return "diff"
	end

	if mode == "diff" or mode == "file" then
		return mode
	end

	vim.notify("Invalid Pitaco review mode: " .. tostring(mode), vim.log.levels.ERROR)
	return nil
end

function M.review(mode)
	local review_mode = normalize_review_mode(mode)
	if review_mode == nil then
		return
	end

	local scope = "review"
	local provider = provider_factory.create_provider(config.get_provider(scope), scope)
	local request_bundle = provider.prepare_requests(fewshot.messages, review_mode)
	requests.make_requests(namespace, provider, request_bundle)
end

function M.index()
	context_engine.index()
end

function M.clear()
	local buffer_number = utils.get_buffer_number()
	local path = vim.api.nvim_buf_get_name(buffer_number)
	local root = context_engine.find_repo_root(path ~= "" and path or vim.fn.getcwd())
	review_store.clear_active_review(root)
	review_renderer.clear_repo(root)
end

function M.clear_line()
	local buffer_number = utils.get_buffer_number()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer_number), ":p")
	local root = context_engine.find_repo_root(path)
	local review, active_entry = review_store.get_active_review(root)
	if review == nil then
		local line_num = vim.api.nvim_win_get_cursor(0)[1]
		vim.diagnostic.set(namespace, buffer_number, {}, { lnum = line_num - 1 })
		return
	end

	local relative_path = review.relative_path or path
	local normalized_root = vim.fn.fnamemodify(root, ":p"):gsub("/+$", "")
	local prefix = normalized_root .. "/"
	if path:sub(1, #prefix) == prefix then
		relative_path = path:sub(#prefix + 1)
	end

	local target_line = vim.api.nvim_win_get_cursor(0)[1]
	local diagnostics = vim.diagnostic.get(buffer_number, { namespace = namespace })
	local ids_to_hide = {}

	for _, diagnostic in ipairs(diagnostics) do
		if diagnostic.lnum + 1 == target_line and diagnostic.user_data and diagnostic.user_data.pitaco_item_id then
			table.insert(ids_to_hide, diagnostic.user_data.pitaco_item_id)
		end
	end

	if vim.tbl_isempty(ids_to_hide) then
		vim.notify("No Pitaco review items found on the current line", vim.log.levels.INFO)
		return
	end

	review_store.hide_items(root, ids_to_hide)
	review_renderer.render_review(review)
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

function M.reviews()
	review_ui.open()
end

function M.models(scope)
	model_picker.open(scope)
end

function M.summary()
	summary.run()
end

function M.info()
	local lines = {
		"Pitaco summary",
		("debug: %s"):format(config.is_debug_enabled() and "enabled" or "disabled"),
		("language: %s"):format(config.get_language()),
	}

	local function append_scope(scope)
		local normalized_scope = normalize_scope(scope)
		local provider = config.get_provider(normalized_scope)
		local model_id = provider and config.get_model(provider, normalized_scope) or nil
		local overrides = config.get_feature_overrides(normalized_scope)
		local note = "active selection"

		if normalized_scope ~= nil then
			if type(overrides) ~= "table" then
				note = "inherits default"
			elseif type(overrides.provider) == "string" and overrides.provider ~= "" then
				if type(overrides.model_id) == "string" and overrides.model_id ~= "" then
					note = "scoped override"
				else
					note = "provider override with default model fallback"
				end
			elseif type(overrides.model_id) == "string" and overrides.model_id ~= "" then
				note = "scoped model override"
			end
		end

		table.insert(
			lines,
			("%s: %s / %s (%s)"):format(scope_label(normalized_scope), provider or "unknown", model_id or "unknown", note)
		)
	end

	append_scope(nil)
	for _, scope in ipairs(config.list_feature_scopes()) do
		append_scope(scope)
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "pitaco" })
end

function M.debug(value)
	if value == nil or value == "" then
		vim.notify(
			("Pitaco debug: %s"):format(config.is_debug_enabled() and "enabled" or "disabled"),
			vim.log.levels.INFO
		)
		return
	end

	local normalized = vim.trim(value):lower()
	if normalized == "on" or normalized == "enable" or normalized == "enabled" or normalized == "true" or normalized == "1" then
		vim.g.pitaco_debug = true
	elseif normalized == "off" or normalized == "disable" or normalized == "disabled" or normalized == "false" or normalized == "0" then
		vim.g.pitaco_debug = false
	elseif normalized == "toggle" then
		vim.g.pitaco_debug = not config.is_debug_enabled()
	else
		vim.notify("Pitaco debug: expected on, off, or toggle", vim.log.levels.ERROR)
		return
	end

	vim.notify(
		("Pitaco debug %s"):format(config.is_debug_enabled() and "enabled" or "disabled"),
		vim.log.levels.INFO
	)
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
