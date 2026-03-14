local progress = require("pitaco.progress")
local utils = require("pitaco.utils")
local log = require("pitaco.log")
local context_engine = require("pitaco.context_engine")

local M = {}

function M.make_requests(namespace, provider, requests, starting_request_count, request_index, line_count)
	if #requests == 0 then
    progress.stop()
		return nil
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

	progress.update(
		"Processing request " .. request_index .. " of " .. starting_request_count,
		request_index,
		starting_request_count
	)

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

		if response then
			local parse_ok, diagnostics = pcall(provider.parse_response, response)

			if not parse_ok then
				log.debug_table("analysis response parse failure", response)
				print("Failed to parse response")
				progress.stop()
				return
			end

			log.debug(("Parsed %d diagnostics from provider response"):format(#diagnostics))
			log.debug_table("parsed diagnostics", diagnostics)

			vim.schedule(function()
				local current_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(utils.get_buffer_number()), ":p")
				local current_root = context_engine.find_repo_root(current_path)
				local current_count = 0
				local other_count = 0

				for _, diag in ipairs(diagnostics) do
					local target = diag.file or current_path
					local path = target

					if type(target) == "string" and target ~= "" and not target:find("^/") then
						local base_root = current_root or vim.fn.getcwd()
						path = base_root .. "/" .. target
					end

					local buf = vim.fn.bufadd(path)
					vim.fn.bufload(buf)
					local existing = vim.diagnostic.get(buf, { namespace = namespace }) or {}
					local stored = vim.deepcopy(diag)
					stored.file = nil
					table.insert(existing, stored)
					vim.diagnostic.set(namespace, buf, existing)

					if vim.fn.fnamemodify(path, ":p") == current_path then
						current_count = current_count + 1
					else
						other_count = other_count + 1
					end
				end

				if #diagnostics > 0 then
					local parts = {}
					if current_count > 0 then
						table.insert(parts, ("%d in current file"):format(current_count))
					end
					if other_count > 0 then
						table.insert(parts, ("%d in other files"):format(other_count))
					end
					vim.notify("Pitaco diagnostics: " .. table.concat(parts, ", "), vim.log.levels.INFO)
				end
			end)
		end

		if request_index < starting_request_count + 1 then
			M.make_requests(namespace, provider, requests, starting_request_count, request_index, line_count)
		end
	end)
end

return M
