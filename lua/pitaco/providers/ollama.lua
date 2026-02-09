local M = {}

function M.get_model()
	local config = require("pitaco.config")
	return config.get_ollama_model()
end

function M.build_chat_request(system_prompt, messages, max_tokens)
	local model = M.get_model()
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

function M.prepare_requests(messages)
	local config = require("pitaco.config")
	local utils = require("pitaco.utils")
	local buffer_number = utils.get_buffer_number()
	local split_threshold = config.get_split_threshold()
	local language = config.get_language()
	local additional_instruction = config.get_additional_instruction()
	local lines = vim.api.nvim_buf_get_lines(buffer_number, 0, -1, false)
	local model = M.get_model()

	local num_requests = math.ceil(#lines / split_threshold)
	local all_requests = {}

	local messages_with_system_prompt = {
		{
			role = "system",
			content = config.get_system_prompt(),
		},
	}

	for _, message in ipairs(messages) do
		table.insert(messages_with_system_prompt, message)
	end

	local request_table = {
		model = model,
		messages = messages_with_system_prompt,
	}

	for i = 1, num_requests do
		local starting_line_number = (i - 1) * split_threshold + 1
		local text =
			utils.prepare_code_snippet(buffer_number, starting_line_number, starting_line_number + split_threshold - 1)

		if additional_instruction ~= "" then
			text = text .. "\n" .. additional_instruction
		end

		if language ~= "" and language ~= "english" then
			text = text .. "\nRespond only in " .. language .. ", but keep the 'line=<num>:' part in english"
		end

		local temp_request_table = vim.deepcopy(request_table)
		table.insert(temp_request_table.messages, {
			role = "user",
			content = text,
		})

		local request_json = vim.json.encode(temp_request_table)
		all_requests[i] = request_json
	end

	return all_requests, num_requests, #lines
end

function M.request(json_data, callback)
	local curl = require("plenary.curl")
	local config = require("pitaco.config")
	local url = config.get_ollama_url() .. "/api/chat"
	
	-- Parse the JSON data to add stream: false
	local ok, request_data = pcall(vim.fn.json_decode, json_data)
	if ok then
		request_data.stream = false
		json_data = vim.fn.json_encode(request_data)
	end

	curl.post(url, {
		headers = {
			["Content-Type"] = "application/json",
		},
		body = json_data,
		timeout = 30000,
		callback = function(response)
			if response.status >= 400 then
				callback(nil, "HTTP error: " .. response.body)
				return
			end

			vim.schedule(function()
				local ok, body = pcall(vim.fn.json_decode, response.body)
				if not ok then
					callback(nil, "Failed to decode response: " .. tostring(body))
				else
					callback(body, nil)
				end
			end)
		end,
	})
end

function M.parse_response(response)
	local lines = vim.split(response.message.content, "\n")
	local diagnostics = {}
	local suggestions = {}

	for _, line in ipairs(lines) do
		if (string.sub(line, 1, 5) == "line=") or string.sub(line, 1, 6) == "lines=" then
			table.insert(suggestions, line)
		elseif #suggestions > 0 then
			suggestions[#suggestions] = suggestions[#suggestions] .. "\n" .. line
		end
	end

	for _, suggestion in ipairs(suggestions) do
		local line_string = string.sub(suggestion, 6, string.find(suggestion, ":") - 1)
		if string.find(line_string, "-") ~= nil then
			line_string = string.sub(line_string, 1, string.find(line_string, "-") - 1)
		end
		local line_num = tonumber(line_string) or 1

		local message = string.sub(suggestion, string.find(suggestion, ":") + 1)
		if string.sub(message, 1, 1) == " " then
			message = string.sub(message, 2)
		end

		table.insert(diagnostics, {
			lnum = line_num - 1,
			col = 0,
			message = message,
			severity = vim.diagnostic.severity.INFO,
			source = "pitaco",
		})
	end

	return diagnostics
end

function M.extract_text(response)
	if response == nil or response.message == nil then
		return ""
	end

	return response.message.content or ""
end

return M
