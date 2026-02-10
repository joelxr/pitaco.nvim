local M = {}

function M.get_system_prompt()
	local default_system_prompt = [[
You must detect issues in the code snippet and help to avoid bugs with your review and suggestions, go step by step in the provided code snippet
to understand the problem and suggest a solution.
Some examples of issues to consider:
- Accessing a variable that is not defined
- Using a variable before it is defined
- Wrong usage of a function
- Infinite loops
- Heavy calls to database or IO in a loop
- Code that is not optimized for performance
You must identify any readability issues in the code snippet.
Some readability issues to consider:
- Unclear naming
- Unclear purpose
- Redundant or obvious comments
- Lack of comments
- Long or complex one liners
- Too much nesting
- Long variable names
- Inconsistent naming and code style
- Code repetition
- Suggest always early returns
- Suggest simpler conditionals on if-else statements
- Check typos and selling of variables, functions, etc.
You may identify additional problems. The user submits a small section of code from a larger file.
Only list lines with readability issues, in the format line=<num>: <issue and proposed solution>
Your commentary must fit on a single line
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
	return vim.g.pitaco_language
end

function M.get_additional_instruction()
	return vim.g.pitaco_additional_instruction or ""
end

function M.get_split_threshold()
	return vim.g.pitaco_split_threshold
end

function M.get_provider()
	return vim.g.pitaco_provider
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
