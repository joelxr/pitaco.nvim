local M = {}

local function first_choice(response)
	if type(response) ~= "table" or type(response.choices) ~= "table" then
		return nil
	end

	local choice = response.choices[1]
	if type(choice) ~= "table" then
		return nil
	end

	return choice
end

local function append_text(parts, value)
	if type(value) ~= "string" then
		return
	end

	local trimmed = vim.trim(value)
	if trimmed == "" then
		return
	end

	table.insert(parts, trimmed)
end

local function collect_text(parts, value)
	if type(value) == "string" then
		append_text(parts, value)
		return
	end

	if type(value) ~= "table" then
		return
	end

	for _, item in ipairs(value) do
		if type(item) == "string" then
			append_text(parts, item)
		elseif type(item) == "table" then
			append_text(parts, item.text)
			append_text(parts, item.content)
			append_text(parts, item.value)
		end
	end
end

function M.join_text(value)
	local parts = {}
	collect_text(parts, value)
	return table.concat(parts, "\n")
end

function M.choice_message_text(response)
	local choice = first_choice(response)
	if type(choice) ~= "table" or type(choice.message) ~= "table" then
		return ""
	end

	return M.join_text(choice.message.content)
end

function M.choice_finish_reason(response)
	local choice = first_choice(response)
	if type(choice) ~= "table" or type(choice.finish_reason) ~= "string" then
		return nil
	end

	return choice.finish_reason
end

function M.choice_reasoning_text(response)
	local choice = first_choice(response)
	if type(choice) ~= "table" then
		return ""
	end

	if type(choice.message) == "table" then
		local message_reasoning = M.join_text(choice.message.reasoning)
		if message_reasoning ~= "" then
			return message_reasoning
		end
	end

	return M.join_text(choice.reasoning)
end

function M.anthropic_text(response)
	if type(response) ~= "table" then
		return ""
	end

	return M.join_text(response.content)
end

function M.ollama_text(response)
	if type(response) ~= "table" or type(response.message) ~= "table" then
		return ""
	end

	return M.join_text(response.message.content)
end

function M.opencode_text(response)
	if type(response) ~= "table" then
		return ""
	end

	if type(response.info) == "table" and response.info.structured_output ~= nil then
		local ok, encoded = pcall(vim.json.encode, response.info.structured_output)
		if ok then
			return encoded
		end
	end

	if type(response.parts) ~= "table" then
		return ""
	end

	local parts = {}
	for _, part in ipairs(response.parts) do
		if type(part) == "table" then
			if part.type == "text" then
				append_text(parts, part.text)
			elseif part.type ~= "reasoning" then
				append_text(parts, part.text)
				append_text(parts, part.content)
			end
		end
	end

	return table.concat(parts, "\n")
end

return M
