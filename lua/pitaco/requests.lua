local progress = require("pitaco.progress")
local utils = require("pitaco.utils")
local log = require("pitaco.log")

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

			vim.schedule(function()
				local buf = utils.get_buffer_number()
				local existing = vim.diagnostic.get(buf, {namespace = namespace}) or {}
				for _, diag in ipairs(diagnostics) do
					table.insert(existing, diag)
				end
				vim.diagnostic.set(namespace, buf, existing)
			end)
		end

		if request_index < starting_request_count + 1 then
			M.make_requests(namespace, provider, requests, starting_request_count, request_index, line_count)
		end
	end)
end

return M
