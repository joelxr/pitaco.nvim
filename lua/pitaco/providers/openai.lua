local M = {}
local log = require("pitaco.log")
local review = require("pitaco.review")
local review_parser = require("pitaco.review_parser")
local request_body = require("pitaco.providers.request_body")
local response_utils = require("pitaco.providers.response_utils")

M.name = "openai"

function M.get_api_key()
	local key = os.getenv("OPENAI_API_KEY")

	if key ~= nil then
		return key
	end

	local message = "No API key found. Please set the $OPENAI_API_KEY environment variable."
	vim.fn.confirm(message, "&OK", 1, "Warning")
	return nil
end

function M.get_model(scope)
	local config = require("pitaco.config")
	return config.get_model("openai", scope)
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
	local api_key = M.get_api_key()
	local url = "https://api.openai.com/v1/chat/completions"

	if api_key == nil then
		log.debug("openai request aborted: missing API key")
		callback(nil, "No API key")
		return
	end

	log.debug(("openai request -> %s"):format(url))
	log.preview_json("openai request body", json_data)
	local body_state = request_body.prepare(json_data)

	local ok, request_error = pcall(curl.post, url, {
		headers = {
			["Content-Type"] = "application/json",
			["Authorization"] = "Bearer " .. api_key,
		},
		in_file = body_state.path,
		timeout = 30000,
		callback = function(response)
			request_body.cleanup(body_state)
			log.debug(("openai response status=%s"):format(tostring(response.status)))
			log.preview_text("openai raw response body", response.body, 500)

			if response.status >= 400 then
				log.debug("openai request failed with HTTP error")
				callback(nil, "HTTP error: " .. response.body)
				return
			end

			vim.schedule(function()
				local ok, body = pcall(vim.fn.json_decode, response.body)
				if not ok then
					log.debug("openai response JSON decode failed")
					callback(nil, "Failed to decode response: " .. tostring(body))
				else
					log.debug_table("openai decoded response", body, 500)
					callback(body, nil)
				end
			end)
		end,
	})

	if not ok then
		request_body.cleanup(body_state)
		callback(nil, "Request failed before dispatch: " .. tostring(request_error))
	end
end

function M.parse_response(response, current_file)
	current_file = current_file or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
	return review_parser.parse_text(M.extract_text(response), current_file)
end

function M.extract_text(response)
	return response_utils.choice_message_text(response)
end

return M
