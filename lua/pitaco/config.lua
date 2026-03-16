local M = {}

local DEFAULT_MODELS = {
	openai = "gpt-5-mini",
	anthropic = "claude-haiku-4-5",
	openrouter = "openrouter/deepseek/deepseek-chat-v3-0324:free",
	ollama = "llama3.1",
}

local function normalize_scope(scope)
	if type(scope) ~= "string" or scope == "" then
		return nil
	end
	return scope
end

local function get_feature_overrides(scope)
	local normalized = normalize_scope(scope)
	if normalized == nil then
		return nil
	end

	local features = vim.g.pitaco_features
	if type(features) ~= "table" then
		return nil
	end

	local overrides = features[normalized]
	if type(overrides) ~= "table" then
		return nil
	end

	return overrides
end

local function non_empty_string(value)
	return type(value) == "string" and value ~= ""
end

local function scope_label(scope)
	return normalize_scope(scope) or "default"
end

local function warn_default_model(provider, scope, message)
	local complaints = vim.g.pitaco_model_complaints
	if type(complaints) ~= "table" then
		complaints = {}
	end

	local key = ("%s:%s"):format(provider, scope_label(scope))
	if complaints[key] then
		return
	end

	vim.fn.confirm(message, "&OK", 1, "Warning")
	complaints[key] = true
	vim.g.pitaco_model_complaints = complaints
end

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
For `line=<num>`, use the exact source line number shown in the numbered current-buffer listing.
Do not count lines from the prompt, headings, diff headers, or repository context blocks.
Choose the smallest relevant line that demonstrates the issue; do not default to the start of a function or block unless that line is itself faulty.
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
- Return only the final answer.
- Do not include reasoning, analysis, thinking, or explanations.
- Output only the subject line, no quotes, no markdown.
- No preamble.
- One line only.
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

function M.get_feature_overrides(scope)
	local overrides = get_feature_overrides(scope)
	if overrides == nil then
		return nil
	end
	return vim.deepcopy(overrides)
end

function M.list_feature_scopes()
	local features = vim.g.pitaco_features
	if type(features) ~= "table" then
		return {}
	end

	local scopes = {}
	for scope, overrides in pairs(features) do
		if type(scope) == "string" and scope ~= "" and type(overrides) == "table" then
			table.insert(scopes, scope)
		end
	end

	table.sort(scopes)
	return scopes
end

function M.get_provider(scope)
	local overrides = get_feature_overrides(scope)
	if overrides ~= nil and non_empty_string(overrides.provider) then
		return overrides.provider
	end
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

function M.get_model(provider, scope)
	local overrides = get_feature_overrides(scope)
	if overrides ~= nil then
		if non_empty_string(overrides.model_id) then
			return overrides.model_id
		end
	end

	if provider == vim.g.pitaco_provider and non_empty_string(vim.g.pitaco_model_id) then
		return vim.g.pitaco_model_id
	end

	local fallback = DEFAULT_MODELS[provider]
	if fallback ~= nil then
		local message
		if normalize_scope(scope) ~= nil then
			message = ("No %s model specified for '%s'. Using default value for now: %s"):format(
				provider,
				scope,
				fallback
			)
		else
			message = ("No %s model specified. Using default value for now: %s"):format(provider, fallback)
		end
		warn_default_model(provider, scope, message)
		return fallback
	end

	return nil
end

function M.get_ollama_url()
	return vim.g.pitaco_ollama_url or "http://localhost:11434"
end

return M
