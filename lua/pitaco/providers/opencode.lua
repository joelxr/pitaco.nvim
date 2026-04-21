local M = {}
local log = require("pitaco.log")
local review = require("pitaco.review")
local review_parser = require("pitaco.review_parser")
local request_body = require("pitaco.providers.request_body")
local response_utils = require("pitaco.providers.response_utils")

M.name = "opencode"

local function trim_trailing_slash(value)
	return tostring(value or ""):gsub("/+$", "")
end

local function headers()
	local config = require("pitaco.config")
	local result = {
		["Content-Type"] = "application/json",
	}
	local auth = config.get_opencode_auth()
	if auth ~= nil and type(vim.base64) == "table" and type(vim.base64.encode) == "function" then
		result["Authorization"] = "Basic " .. vim.base64.encode(auth.username .. ":" .. auth.password)
	end
	return result
end

local function model_config(model_id)
	if type(model_id) ~= "string" or model_id == "" or model_id == "default" then
		return nil
	end

	local provider_id, model = model_id:match("^([^/]+)/(.+)$")
	if provider_id == nil or provider_id == "" or model == nil or model == "" then
		return nil
	end

	return {
		providerID = provider_id,
		modelID = model,
	}
end

local function message_text(messages)
	local parts = {}
	for _, message in ipairs(messages or {}) do
		if type(message) == "table" then
			local role = type(message.role) == "string" and message.role or "user"
			local content = response_utils.join_text(message.content)
			if content ~= "" then
				table.insert(parts, ("<%s>\n%s\n</%s>"):format(role, content, role))
			end
		end
	end
	return table.concat(parts, "\n\n")
end

local function decode_response(provider_name, response, callback)
	log.debug(("%s response status=%s"):format(provider_name, tostring(response.status)))
	log.preview_text(provider_name .. " raw response body", response.body, 500)

	if response.status >= 400 then
		log.debug(provider_name .. " request failed with HTTP error")
		callback(nil, "HTTP error: " .. response.body)
		return false
	end

	local ok, body = pcall(vim.fn.json_decode, response.body)
	if not ok then
		log.debug(provider_name .. " response JSON decode failed")
		callback(nil, "Failed to decode response: " .. tostring(body))
		return false
	end

	log.debug_table(provider_name .. " decoded response", body, 500)
	return body
end

local function post_json(url, body, callback)
	local curl = require("plenary.curl")
	local json_data = vim.json.encode(body)
	local body_state = request_body.prepare(json_data)

	log.debug(("opencode request -> %s"):format(url))
	log.preview_json("opencode request body", json_data)

	local ok, request_error = pcall(curl.post, url, {
		headers = headers(),
		in_file = body_state.path,
		timeout = 120000,
		callback = function(response)
			request_body.cleanup(body_state)
			vim.schedule(function()
				local decoded = decode_response("opencode", response, callback)
				if decoded ~= false then
					callback(decoded, nil)
				end
			end)
		end,
	})

	if not ok then
		request_body.cleanup(body_state)
		callback(nil, "Request failed before dispatch: " .. tostring(request_error))
	end
end

function M.get_model(scope)
	local config = require("pitaco.config")
	if scope == "review_verifier" then
		return config.get_review_model("opencode", "verifier")
	end
	return config.get_model("opencode", scope)
end

function M.build_chat_request(system_prompt, messages, max_tokens, scope)
	local request_table = {
		system = system_prompt or "",
		parts = {
			{
				type = "text",
				text = message_text(messages),
			},
		},
	}

	local model = model_config(M.get_model(scope))
	if model ~= nil then
		request_table.model = model
	end

	return vim.json.encode(request_table)
end

function M.prepare_requests(messages, review_mode)
	return review.build_requests(M, messages, review_mode)
end

function M.request(json_data, callback)
	local config = require("pitaco.config")
	local base_url = trim_trailing_slash(config.get_opencode_url())
	if base_url == "" then
		callback(nil, "OpenCode URL is not configured")
		return
	end

	local ok, request_data = pcall(vim.fn.json_decode, json_data)
	if not ok or type(request_data) ~= "table" then
		callback(nil, "Failed to decode OpenCode request body")
		return
	end

	post_json(base_url .. "/session", { title = "Pitaco" }, function(session, session_error)
		if session_error ~= nil then
			callback(nil, session_error)
			return
		end

		if type(session) ~= "table" or type(session.id) ~= "string" or session.id == "" then
			callback(nil, "OpenCode did not return a session id")
			return
		end

		post_json(base_url .. "/session/" .. session.id .. "/message", request_data, callback)
	end)
end

function M.parse_response(response, current_file)
	current_file = current_file or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
	return review_parser.parse_text(M.extract_text(response), current_file)
end

function M.extract_text(response)
	return response_utils.opencode_text(response)
end

return M
