local progress = require("pitaco.progress")
local utils = require("pitaco.utils")
local log = require("pitaco.log")
local context_engine = require("pitaco.context_engine")
local review_diagnostics = require("pitaco.review_diagnostics")
local review_renderer = require("pitaco.review_renderer")
local review_store = require("pitaco.review_store")

local M = {}

local function progress_message(metadata)
	local provider = metadata.provider or "unknown"
	local model_id = metadata.model_id or "unknown"
	return ("Reviewing with %s/%s"):format(provider, model_id)
end

local function project_immediate_diagnostics(namespace, diagnostics, repo_root)
	local grouped = {}

	for _, diag in ipairs(diagnostics or {}) do
		local path = diag.absolute_path or diag.file
		if type(path) == "string" and path ~= "" and not path:find("^/") then
			path = (repo_root or vim.fn.getcwd()) .. "/" .. path
		end

		if type(path) == "string" and path ~= "" then
			path = vim.fn.fnamemodify(path, ":p")
			grouped[path] = grouped[path] or {}
			table.insert(grouped[path], {
				lnum = diag.lnum or 0,
				col = diag.col or 0,
				message = diag.message or "",
				severity = diag.severity or vim.diagnostic.severity.INFO,
				source = diag.source or "pitaco",
			})
		end
	end

	for path, items in pairs(grouped) do
		local bufnr = vim.fn.bufadd(path)
		vim.fn.bufload(bufnr)
		vim.diagnostic.set(namespace, bufnr, items)
	end
end

function M.make_requests(namespace, provider, request_bundle)
	local requests = vim.deepcopy(request_bundle.requests or {})
	local metadata = request_bundle.metadata or {}
	local starting_request_count = request_bundle.request_count or #requests
	local request_index = 0
	local aggregated = {}

	local function finish()
		progress.stop()

		vim.schedule(function()
			local current_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(utils.get_buffer_number()), ":p")
			local current_root = context_engine.find_repo_root(current_path)
			local current_count = 0
			local other_count = 0

			for _, diag in ipairs(aggregated) do
				local target = diag.absolute_path or diag.file or current_path
				local path = target

				if type(target) == "string" and target ~= "" and not target:find("^/") then
					local base_root = metadata.repo_root or current_root or vim.fn.getcwd()
					path = base_root .. "/" .. target
				end

				if vim.fn.fnamemodify(path, ":p") == current_path then
					current_count = current_count + 1
				else
					other_count = other_count + 1
				end
			end

			local review, error_message = review_store.create_review(metadata, aggregated)
			if review == nil then
				vim.notify("Pitaco review persistence failed: " .. tostring(error_message), vim.log.levels.ERROR)
				project_immediate_diagnostics(namespace, aggregated, metadata.repo_root)
				return
			end

			project_immediate_diagnostics(namespace, aggregated, metadata.repo_root)

			local activated, activate_error = review_renderer.activate_review(review)
			if not activated then
				vim.notify("Pitaco review activation failed: " .. tostring(activate_error), vim.log.levels.WARN)
			end

			if #aggregated > 0 then
				local parts = {}
				if current_count > 0 then
					table.insert(parts, ("%d in current file"):format(current_count))
				end
				if other_count > 0 then
					table.insert(parts, ("%d in other files"):format(other_count))
				end
				vim.notify("Pitaco diagnostics: " .. table.concat(parts, ", "), vim.log.levels.INFO)
			else
				vim.notify("Pitaco review completed with no findings", vim.log.levels.INFO)
			end
		end)
	end

	local function process_next()
		if #requests == 0 then
			finish()
			return
		end

		local request_json = table.remove(requests, 1)
		request_index = request_index + 1

		log.debug(
			("Dispatching analysis request %d/%d via provider '%s'"):format(
				request_index,
				starting_request_count,
				provider.name or "unknown"
			)
		)
		log.preview_json("analysis request payload", request_json)

		progress.update(progress_message(metadata), request_index, starting_request_count)

		provider.request(request_json, function(response, error_message)
			if error_message ~= nil then
				log.preview_text("analysis request error", error_message)
				print(error_message)
				progress.stop()
				return
			end

			if response == nil then
				log.debug("analysis request returned nil response without explicit error")
				progress.stop()
				return
			end

			local parse_ok, diagnostics = pcall(provider.parse_response, response, metadata.buffer_path)

			if not parse_ok then
				log.debug_table("analysis response parse failure", response)
				print("Failed to parse response")
				progress.stop()
				return
			end

			log.debug(("Parsed %d diagnostics from provider response"):format(#diagnostics))
			log.debug_table("parsed diagnostics", diagnostics)

			local normalized_diagnostics, dropped_count = review_diagnostics.normalize(metadata, diagnostics)
			if dropped_count > 0 then
				log.debug(("Dropped or corrected %d diagnostics during anchor normalization"):format(dropped_count))
			end
			log.debug_table("normalized diagnostics", normalized_diagnostics)

			for _, diag in ipairs(normalized_diagnostics) do
				local stored = vim.deepcopy(diag)
				local target = diag.file or metadata.buffer_path
				if type(target) == "string" and target ~= "" and not target:find("^/") then
					stored.absolute_path = (metadata.repo_root or vim.fn.getcwd()) .. "/" .. target
				else
					stored.absolute_path = target
				end
				table.insert(aggregated, stored)
			end

			process_next()
		end)
	end

	process_next()
end

return M
