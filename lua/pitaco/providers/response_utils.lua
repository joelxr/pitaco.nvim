local M = {}

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
	if type(response) ~= "table" or type(response.choices) ~= "table" then
		return ""
	end

	local choice = response.choices[1]
	if type(choice) ~= "table" or type(choice.message) ~= "table" then
		return ""
	end

	return M.join_text(choice.message.content)
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

return M
