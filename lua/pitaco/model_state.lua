local M = {}

local FILE_NAME = "pitaco-model-state.json"

local function state_file_path()
	local state_dir = vim.fn.stdpath("state")
	return state_dir .. "/" .. FILE_NAME
end

local function read_json_file(path)
	local fd = io.open(path, "r")
	if not fd then
		return {}
	end

	local content = fd:read("*a")
	fd:close()
	if content == nil or content == "" then
		return {}
	end

	local ok, decoded = pcall(vim.json.decode, content)
	if not ok or type(decoded) ~= "table" then
		return {}
	end

	return decoded
end

local function write_json_file(path, payload)
	local encoded = vim.json.encode(payload)
	local parent = vim.fn.fnamemodify(path, ":h")
	vim.fn.mkdir(parent, "p")

	local fd, err = io.open(path, "w")
	if not fd then
		return false, err
	end

	fd:write(encoded)
	fd:close()
	return true
end

local function model_var_name(provider)
	if provider == "openai" then
		return "pitaco_openai_model_id"
	end
	if provider == "anthropic" then
		return "pitaco_anthropic_model_id"
	end
	if provider == "openrouter" then
		return "pitaco_openrouter_model_id"
	end
	if provider == "ollama" then
		return "pitaco_ollama_model_id"
	end
	return nil
end

function M.load()
	return read_json_file(state_file_path())
end

function M.save(state)
	return write_json_file(state_file_path(), state)
end

function M.apply(selection)
	if type(selection) ~= "table" then
		return false, "invalid selection"
	end

	if type(selection.provider) == "string" and selection.provider ~= "" then
		vim.g.pitaco_provider = selection.provider
	end

	if type(selection.models) == "table" then
		for provider, model in pairs(selection.models) do
			local var_name = model_var_name(provider)
			if var_name ~= nil and type(model) == "string" and model ~= "" then
				vim.g[var_name] = model
			end
		end
	end

	return true
end

function M.persist_selection(provider, model_id)
	local state = M.load()
	state.models = state.models or {}
	state.provider = provider
	state.models[provider] = model_id
	state.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
	return M.save(state)
end

function M.state_path()
	return state_file_path()
end

return M
