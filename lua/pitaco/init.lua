local M = {}

local default_opts = {
	anthropic_model_id = "claude-3-5-haiku-latest",
	openai_model_id = "gpt-4.1-mini",
	openrouter_model_id = "openrouter/deepseek/deepseek-chat-v3-0324:free",
	ollama_model_id = "llama3.1",
	ollama_url = "http://localhost:11434",
	provider = "anthropic",
	language = "english",
	additional_instruction = nil,
	split_threshold = 100,
	commit_keymap = nil,
	commit_system_prompt = nil,
}

function M.setup(opts)
	opts = vim.tbl_deep_extend("force", default_opts, opts or {})
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
end

return M
