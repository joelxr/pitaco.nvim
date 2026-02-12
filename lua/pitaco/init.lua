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
	split_threshold = 100,
	commit_keymap = nil,
	commit_system_prompt = nil,
	persist_model_selection = true,
}

function M.setup(opts)
	opts = vim.tbl_deep_extend("force", default_opts, opts or {})
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
	vim.g.pitaco_split_threshold = opts.split_threshold
	vim.g.pitaco_commit_keymap = opts.commit_keymap
	vim.g.pitaco_commit_system_prompt = opts.commit_system_prompt
	vim.g.pitaco_persist_model_selection = opts.persist_model_selection
end

return M
