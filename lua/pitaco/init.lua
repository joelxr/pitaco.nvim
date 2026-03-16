local M = {}

local default_opts = {
	anthropic_model_id = "claude-haiku-4-5",
	openai_model_id = "gpt-5-mini",
	openrouter_model_id = "openrouter/deepseek/deepseek-chat-v3-0324:free",
	ollama_model_id = "llama3.1",
	ollama_url = "http://localhost:11434",
	provider = "anthropic",
	language = "english",
	additional_instruction = nil,
	review_additional_instruction = nil,
	commit_additional_instruction = nil,
	commit_keymap = nil,
	commit_system_prompt = nil,
	persist_model_selection = true,
	context_enabled = true,
	context_cli_cmd = "pitaco-indexer",
	context_max_chunks = 6,
	context_timeout_ms = 1500,
	context_include_git_diff = true,
	debug = false,
	features = {},
}

local function extract_feature_overrides(opts)
	local features = vim.deepcopy(opts.features or {})

	local function ensure_scope(scope)
		features[scope] = features[scope] or {}
		return features[scope]
	end

	if opts.review_provider ~= nil then
		ensure_scope("review").provider = opts.review_provider
	end
	if opts.review_model_id ~= nil then
		ensure_scope("review").model_id = opts.review_model_id
	end
	if opts.review_openai_model_id ~= nil then
		ensure_scope("review").openai_model_id = opts.review_openai_model_id
	end
	if opts.review_anthropic_model_id ~= nil then
		ensure_scope("review").anthropic_model_id = opts.review_anthropic_model_id
	end
	if opts.review_openrouter_model_id ~= nil then
		ensure_scope("review").openrouter_model_id = opts.review_openrouter_model_id
	end
	if opts.review_ollama_model_id ~= nil then
		ensure_scope("review").ollama_model_id = opts.review_ollama_model_id
	end

	if opts.commit_provider ~= nil then
		ensure_scope("commit").provider = opts.commit_provider
	end
	if opts.commit_model_id ~= nil then
		ensure_scope("commit").model_id = opts.commit_model_id
	end
	if opts.commit_openai_model_id ~= nil then
		ensure_scope("commit").openai_model_id = opts.commit_openai_model_id
	end
	if opts.commit_anthropic_model_id ~= nil then
		ensure_scope("commit").anthropic_model_id = opts.commit_anthropic_model_id
	end
	if opts.commit_openrouter_model_id ~= nil then
		ensure_scope("commit").openrouter_model_id = opts.commit_openrouter_model_id
	end
	if opts.commit_ollama_model_id ~= nil then
		ensure_scope("commit").ollama_model_id = opts.commit_ollama_model_id
	end

	return features
end

function M.setup(opts)
	opts = vim.tbl_deep_extend("force", default_opts, opts or {})
	local feature_overrides = extract_feature_overrides(opts)
	if opts.persist_model_selection ~= false then
		local state = require("pitaco.model_state").load()
		if type(state.provider) == "string" and state.provider ~= "" then
			opts.provider = state.provider
		end
		if type(state.models) == "table" then
			opts.openai_model_id = state.models.openai or opts.openai_model_id
			opts.anthropic_model_id = state.models.anthropic or opts.anthropic_model_id
			opts.openrouter_model_id = state.models.openrouter or opts.openrouter_model_id
			opts.ollama_model_id = state.models.ollama or opts.ollama_model_id
		end
	end

	vim.g.pitaco_provider = opts.provider
	vim.g.pitaco_anthropic_model_id = opts.anthropic_model_id
	vim.g.pitaco_openrouter_model_id = opts.openrouter_model_id
	vim.g.pitaco_ollama_model_id = opts.ollama_model_id
	vim.g.pitaco_ollama_url = opts.ollama_url
	vim.g.pitaco_openai_model_id = opts.openai_model_id
	vim.g.pitaco_language = opts.language
	vim.g.pitaco_additional_instruction = opts.additional_instruction
	vim.g.pitaco_review_additional_instruction = opts.review_additional_instruction
	vim.g.pitaco_commit_additional_instruction = opts.commit_additional_instruction
	vim.g.pitaco_commit_keymap = opts.commit_keymap
	vim.g.pitaco_commit_system_prompt = opts.commit_system_prompt
	vim.g.pitaco_persist_model_selection = opts.persist_model_selection
	vim.g.pitaco_context_enabled = opts.context_enabled
	vim.g.pitaco_context_cli_cmd = opts.context_cli_cmd
	vim.g.pitaco_context_max_chunks = opts.context_max_chunks
	vim.g.pitaco_context_timeout_ms = opts.context_timeout_ms
	vim.g.pitaco_context_include_git_diff = opts.context_include_git_diff
	vim.g.pitaco_debug = opts.debug
	vim.g.pitaco_features = feature_overrides
end

return M
