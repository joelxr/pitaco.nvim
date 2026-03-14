local M = {}
local log = require("pitaco.log")
local review = require("pitaco.review")
local review_parser = require("pitaco.review_parser")
local response_utils = require("pitaco.providers.response_utils")

M.name = "anthropic"

function M.get_api_key()
	local key = os.getenv("ANTHROPIC_API_KEY")

	if key ~= nil then
		return key
	end

	local message = "No API key found. Please set the $ANTHROPIC_API_KEY environment variable."
	vim.fn.confirm(message, "&OK", 1, "Warning")
	return nil
end

function M.get_model()
	local config = require("pitaco.config")
	return config.get_anthropic_model()
end

function M.build_chat_request(system_prompt, messages, max_tokens)
	local model = M.get_model()
	local request_table = {
		model = model,
		messages = messages or {},
		max_tokens = max_tokens or 256,
		system = system_prompt or "",
	}

	return vim.json.encode(request_table)
end

function M.prepare_requests(messages, review_mode)
	return review.build_requests(M, messages, review_mode)
end

function M.request(json_data, callback)
	local curl = require("plenary.curl")
	local api_key = M.get_api_key()
	local url = "https://api.anthropic.com/v1/messages"

	if api_key == nil then
		log.debug("anthropic request aborted: missing API key")
		callback(nil, "No API key")
		return
	end

	log.debug(("anthropic request -> %s"):format(url))
	log.preview_json("anthropic request body", json_data)

	curl.post(url, {
		headers = {
			["Content-Type"] = "application/json",
			["anthropic-version"] = "2023-06-01",
			["x-api-key"] = api_key,
		},
		body = json_data,
		timeout = 30000, -- 30s
		callback = function(response)
			log.debug(("anthropic response status=%s"):format(tostring(response.status)))
			log.preview_text("anthropic raw response body", response.body, 500)

			if response.status >= 400 then
				log.debug("anthropic request failed with HTTP error")
				callback(nil, "HTTP error: " .. response.body)
				return
			end

			vim.schedule(function()
				local ok, body = pcall(vim.fn.json_decode, response.body)
				if not ok then
					log.debug("anthropic response JSON decode failed")
					callback(nil, "Failed to decode response: " .. tostring(body))
				else
					log.debug_table("anthropic decoded response", body, 500)
					callback(body, nil)
				end
			end)
		end,
	})
end

function M.parse_response(response)
	local current_file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
	return review_parser.parse_text(M.extract_text(response), current_file)
end

function M.extract_text(response)
	return response_utils.anthropic_text(response)
end

return M
