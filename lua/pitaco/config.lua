local M = {}

function M.get_system_prompt()
	local default_system_prompt = [[
You are an expert code reviewer.
You will receive repository context, relevant project code chunks, a file under review, and sometimes a git diff.
Your job is to find real problems that could cause bugs, broken behavior, incorrect data, regressions, security issues, poor UX outcomes, or materially harder maintenance.
Use the broader repository context to reason about the actual behavior of the code, not just local style.

Prioritize findings in this order:
1. correctness and regression risks
2. state management or async flow bugs
3. missing error handling or edge cases
4. contract mismatches with other parts of the codebase
5. performance issues that can materially affect the user or system
6. maintainability issues only when they are likely to cause future defects

Do not report:
- naming preferences
- formatting or style opinions
- requests for comments or docs
- generic "consider refactoring" advice
- speculative concerns without a concrete failure mode
- minor readability issues unless they are likely to cause mistakes

Only report a finding if you can explain:
- what can go wrong
- why it can go wrong in this codebase
- the likely impact

Prefer fewer, higher-confidence findings over many weak ones.
If there are no meaningful issues, return no findings.
You may report findings in the file under review or in other repository files when the repository context reveals a real issue.
Never attach an issue from repository context to the current file unless the problem is actually in the current file.
If a problem is in another file, you must use that file's repo-relative path and line number.
If you cannot name the exact other file and line, omit the finding.
For findings in the file under review, use exactly: line=<num>: <issue and proposed solution>.
For findings in other files, use exactly: file=<repo-relative-path> line=<num>: <issue and proposed solution>.
Do not use plain `line=` for issues that belong to another file.
Do not report repository-level or architectural concerns without anchoring them to a specific file and line.
Each finding must stay on a single line.
Do not praise the code.
  ]]
	return vim.g.pitaco_system_prompt or default_system_prompt
end

function M.get_commit_system_prompt()
	local default_commit_system_prompt = [[
You are a Git commit message generator.
Given a git diff, write a concise commit subject line.
Rules:
- Output only the subject line, no quotes, no markdown.
- Use imperative mood.
- Keep it between 50 and 72 characters.
- No trailing period.
  ]]
	return vim.g.pitaco_commit_system_prompt or default_commit_system_prompt
end

function M.get_language()
	local language = vim.g.pitaco_session_language or vim.g.pitaco_language
	if language == nil or language == "" then
		return "english"
	end
	return language
end

function M.get_configured_language()
	local language = vim.g.pitaco_language
	if language == nil or language == "" then
		return "english"
	end
	return language
end

function M.set_session_language(language)
	if type(language) ~= "string" then
		return false
	end

	local trimmed = vim.trim(language)
	if trimmed == "" then
		return false
	end

	vim.g.pitaco_session_language = trimmed
	return true
end

function M.clear_session_language()
	vim.g.pitaco_session_language = nil
end

function M.get_additional_instruction()
	return vim.g.pitaco_additional_instruction or ""
end

function M.get_review_additional_instruction()
	local instruction = vim.g.pitaco_review_additional_instruction
	if instruction == nil or instruction == "" then
		return M.get_additional_instruction()
	end
	return instruction
end

function M.get_commit_additional_instruction()
	return vim.g.pitaco_commit_additional_instruction or ""
end

function M.get_provider()
	return vim.g.pitaco_provider
end

function M.is_debug_enabled()
	return vim.g.pitaco_debug == true
end

function M.is_context_enabled()
	return vim.g.pitaco_context_enabled ~= false
end

function M.get_context_cli_command()
	return vim.g.pitaco_context_cli_cmd or "pitaco-indexer"
end

function M.get_context_max_chunks()
	return vim.g.pitaco_context_max_chunks or 6
end

function M.get_context_timeout_ms()
	return vim.g.pitaco_context_timeout_ms or 1500
end

function M.should_include_git_diff()
	return vim.g.pitaco_context_include_git_diff ~= false
end

function M.get_openai_model()
	local model = vim.g.pitaco_openai_model_id

	if model ~= nil then
		return model
	end

	if vim.g.pitaco_model_id_complained == nil then
		local message = "No model specified. Please set openai_model_id in the setup table. Using default value for now"
		vim.fn.confirm(message, "&OK", 1, "Warning")
		vim.g.pitaco_model_id_complained = 1
	end

	return "gpt-4.1-mini"
end

function M.get_openrouter_model()
	local model = vim.g.pitaco_openrouter_model_id

	if model ~= nil then
		return model
	end

	if vim.g.pitaco_openrouter_model_id_complained == nil then
		local message =
			"No OpenRouter model specified. Please set openrouter_model_id in the setup table. Using default value for now"
		vim.fn.confirm(message, "&OK", 1, "Warning")
		vim.g.pitaco_openrouter_model_id_complained = 1
	end

	return "openrouter/deepseek/deepseek-chat-v3-0324:free"
end

function M.get_ollama_model()
	local model = vim.g.pitaco_ollama_model_id

	if model ~= nil then
		return model
	end

	if vim.g.pitaco_ollama_model_id_complained == nil then
		local message = "No Ollama model specified. Using default llama3"
		vim.fn.confirm(message, "&OK", 1, "Warning")
		vim.g.pitaco_ollama_model_id_complained = 1
	end

	return "llama3.1"
end

function M.get_ollama_url()
	return vim.g.pitaco_ollama_url or "http://localhost:11434"
end

function M.get_anthropic_model()
	local model = vim.g.pitaco_anthropic_model_id

	if model ~= nil then
		return model
	end

	if vim.g.pitaco_anthropic_model_id_complained == nil then
		local message =
			"No Anthropic model specified. Please set anthropic_model_id in the setup table. Using default value for now"
		vim.fn.confirm(message, "&OK", 1, "Warning")
		vim.g.pitaco_anthropic_model_id_complained = 1
	end

	return "claude-haiku-4-5"
end

return M
