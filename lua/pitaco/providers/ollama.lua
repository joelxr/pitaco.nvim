local M = {}
local log = require("pitaco.log")
local review = require("pitaco.review")
local review_parser = require("pitaco.review_parser")
local request_body = require("pitaco.providers.request_body")
local response_utils = require("pitaco.providers.response_utils")

M.name = "ollama"

local function summarize_context_usage(body, request_data)
	if type(body) ~= "table" then
		return nil
	end

	local prompt_eval_count = tonumber(body.prompt_eval_count)
	if prompt_eval_count == nil then
		return nil
	end

	local num_ctx = nil
	if type(request_data) == "table" and type(request_data.options) == "table" then
		num_ctx = tonumber(request_data.options.num_ctx)
	end

	if num_ctx == nil or num_ctx <= 0 then
		return ("ollama context usage: prompt_eval_count=%d"):format(prompt_eval_count)
	end

	local pct = (prompt_eval_count / num_ctx) * 100
	return ("ollama context usage: %d/%d tokens (%.1f%%)"):format(prompt_eval_count, num_ctx, pct)
end

function M.get_model(scope)
	local config = require("pitaco.config")
	if scope == "review_verifier" then
		return config.get_review_model("ollama", "verifier")
	end
	return config.get_model("ollama", scope)
end

function M.build_chat_request(system_prompt, messages, max_tokens, scope)
	local config = require("pitaco.config")
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

	local keep_alive = config.get_ollama_keep_alive(scope)
	if keep_alive ~= nil then
		request_table.keep_alive = keep_alive
	end

	local ollama_options = config.get_ollama_options(scope)
	if type(ollama_options) == "table" then
		request_table.options = ollama_options
	end

	if max_tokens ~= nil then
		request_table.max_tokens = max_tokens
	end

	return vim.json.encode(request_table)
end

function M.prepare_requests(messages, review_mode, opts)
	return review.build_requests(M, messages, review_mode, opts)
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
	local body_state = request_body.prepare(json_data)

	local ok, request_error = pcall(curl.post, url, {
		headers = {
			["Content-Type"] = "application/json",
		},
		in_file = body_state.path,
		timeout = 30000,
		callback = function(response)
			request_body.cleanup(body_state)
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
					local usage_summary = summarize_context_usage(body, request_data)
					if usage_summary ~= nil then
						log.debug(usage_summary)
					end
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
	return response_utils.ollama_text(response)
end

return M
