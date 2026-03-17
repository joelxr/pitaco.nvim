local M = {}
local log = require("pitaco.log")
local review = require("pitaco.review")
local review_parser = require("pitaco.review_parser")
local response_utils = require("pitaco.providers.response_utils")

M.name = "ollama"

function M.get_model(scope)
	local config = require("pitaco.config")
	return config.get_model("ollama", scope)
end

function M.build_chat_request(system_prompt, messages, max_tokens, scope)
	local model = M.get_model(scope)
	local final_messages = {}

	if system_prompt ~= nil and system_prompt ~= "" then
		table.insert(final_messages, { role = "system", content = system_prompt })
	end

	for _, message in ipairs(messages or {}) do
		table.insert(final_messages, message)
	end

	local request_table = {
		model = model,
		messages = final_messages,
	}

	if max_tokens ~= nil then
		request_table.max_tokens = max_tokens
	end

	return vim.json.encode(request_table)
end

function M.prepare_requests(messages, review_mode)
	return review.build_requests(M, messages, review_mode)
end

function M.request(json_data, callback)
	local curl = require("plenary.curl")
	local config = require("pitaco.config")
	local url = config.get_ollama_url() .. "/api/chat"

	log.debug(("ollama request -> %s"):format(url))

	-- Parse the JSON data to add stream: false
	local ok, request_data = pcall(vim.fn.json_decode, json_data)
	if ok then
		request_data.stream = false
		json_data = vim.fn.json_encode(request_data)
		log.debug("ollama request stream flag forced to false")
	else
		log.debug("ollama request body decode failed before stream flag update")
	end

	log.preview_json("ollama request body", json_data)

	curl.post(url, {
		headers = {
			["Content-Type"] = "application/json",
		},
		body = json_data,
		timeout = 30000,
		callback = function(response)
			log.debug(("ollama response status=%s"):format(tostring(response.status)))
			log.preview_text("ollama raw response body", response.body, 500)

			if response.status >= 400 then
				log.debug("ollama request failed with HTTP error")
				callback(nil, "HTTP error: " .. response.body)
				return
			end

			vim.schedule(function()
				local ok, body = pcall(vim.fn.json_decode, response.body)
				if not ok then
					log.debug("ollama response JSON decode failed")
					callback(nil, "Failed to decode response: " .. tostring(body))
				else
					log.debug_table("ollama decoded response", body, 500)
					callback(body, nil)
				end
			end)
		end,
	})
end

function M.parse_response(response, current_file)
	current_file = current_file or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
	return review_parser.parse_text(M.extract_text(response), current_file)
end

function M.extract_text(response)
	return response_utils.ollama_text(response)
end

return M
