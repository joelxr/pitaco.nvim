local M = {}

local DEFAULT_MODELS = {
	openai = "gpt-5-mini",
	anthropic = "claude-haiku-4-5",
	openrouter = "openrouter/deepseek/deepseek-chat-v3-0324:free",
	ollama = "llama3.1",
	opencode = "default",
}

local DEFAULT_PROMPT_DIFF_EXCLUDE_FILES = {
	"package-lock.json",
	"npm-shrinkwrap.json",
	"yarn.lock",
	"pnpm-lock.yaml",
	"bun.lock",
	"bun.lockb",
	"Cargo.lock",
	"Gemfile.lock",
	"composer.lock",
	"Podfile.lock",
}

local DEFAULT_AUTO_INDEX_PROJECT_MARKERS = {
	".git",
	"package.json",
	"pyproject.toml",
	"go.mod",
	"Cargo.toml",
	"composer.json",
	"Gemfile",
	"mix.exs",
	"deno.json",
	"deno.jsonc",
}

local BUILTIN_FEATURE_SCOPES = {
	review = true,
	commit = true,
	summary = true,
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

local function get_review_role_overrides(role)
	local overrides = get_feature_overrides("review")
	if overrides == nil then
		return nil
	end

	if role == "reviewer" then
		return overrides
	end

	local nested = overrides[role]
	if type(nested) == "table" then
		return nested
	end

	return nil
end

local function get_ollama_scope_overrides(scope)
	if scope == "review_verifier" then
		return get_review_role_overrides("verifier")
	end

	return get_feature_overrides(scope)
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
Return only raw finding lines.
Do not add any introduction, summary, headings, numbering, bullets, markdown, code fences, or explanatory text before or after the findings.
If there are no findings, return an empty response.
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
Treat the branch diff or file under review as primary evidence. Use repository context only to confirm impact, locate affected callers/tests, or validate a concrete failure mode.
Ignore retrieved matches that only share common words, generic variable names, fixture names, or comments and do not show a real code dependency.
Do not infer new requirements or policies unless they are directly supported by the diff, a direct caller/callee relationship, or nearby tests shown in the prompt.
Do not report a finding that contradicts the visible diff or shown code.
Before claiming that a function name, import, argument list, or API usage is wrong, verify that claim against the actual diff and shown code snippets in the prompt.
If the visible diff or shown code disproves a possible finding, omit it instead of hedging.
When reviewing a diff slice, the changed hunk and focused file excerpt are primary evidence. Use broader repository context only to confirm impact, not to invent issues.
Only report a finding when the shown evidence demonstrates a concrete failure mode in this codebase.
Do not report multiple findings for the same root cause unless different changed files each contain their own concrete fault.
Do not praise the code.
  ]]
	return vim.g.pitaco_system_prompt or default_system_prompt
end

function M.get_review_verifier_system_prompt()
	local default_review_verifier_system_prompt = [[
You are a strict code review verifier.
Evaluate whether the candidate is a real bug using only the shown evidence.
Treat the candidate as a hypothesis, not as evidence.
Be direct. Do not explain your reasoning.

Return exactly one of these formats:
status=confirmed
finding=file=<repo-relative-path> line=<num>: <concise issue and proposed solution>

status=rejected

status=insufficient_evidence

Use `status=confirmed` only for a proven defect.
Use `status=rejected` when the evidence shows there is no bug, or the candidate is docs/style/naming/test-gap feedback.
Use `status=insufficient_evidence` when the claim is plausible but not proven by the shown code and diff.
If the shown code or diff directly contradicts the candidate, return `status=rejected`.
If the candidate only describes correct or intentional code, return `status=rejected`.
Do not add explanations, headings, numbering, bullets, markdown, or any text before or after those lines.
]]
	return vim.g.pitaco_review_verifier_system_prompt or default_review_verifier_system_prompt
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

function M.get_summary_system_prompt()
	local default_summary_system_prompt = [[
You are generating a pull request summary from repository-aware context.
You will receive lightweight repository context, changed-file structure, and the full branch diff against the repository base branch.

Your job is to summarize the intended branch changes for a PR description.

Rules:
- Return only markdown.
- This is not a review. Do not critique the code, suggest improvements, ask questions, or provide example code.
- Do not say context is missing, avoid uncertainty disclaimers, and do not mention what else should be improved.
- Do not include preambles, conclusions, notes, questions, or fenced code blocks.
- Use exactly these top-level sections in this order:
  ## What changed
  ## Why
  ## Risk/Impact
- Under each section, use concise bullet points.
- Be concrete and specific to the actual diff.
- Base the summary primarily on the branch diff. Treat all other context as secondary.
- Focus on intended behavior and meaningful implementation details.
- Mention user-visible, API, data, workflow, or operational impact when relevant.
- Do not mention testing needs, missing tests, recommendations, or follow-up work.
- In `## Risk/Impact`, describe likely behavioral or operational effects of the change itself, not advice about what should be validated.
- If the reason for a change is not explicit, infer cautiously from the diff and context.
- Keep the summary concise but useful for a GitHub PR description.
  ]]
	return vim.g.pitaco_summary_system_prompt or default_summary_system_prompt
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
	return ""
end

function M.get_review_additional_instruction()
	local overrides = get_feature_overrides("review")
	if overrides ~= nil and non_empty_string(overrides.additional_instruction) then
		return overrides.additional_instruction
	end
	return ""
end

function M.get_commit_additional_instruction()
	local overrides = get_feature_overrides("commit")
	if overrides ~= nil and non_empty_string(overrides.additional_instruction) then
		return overrides.additional_instruction
	end
	return ""
end

function M.get_summary_additional_instruction()
	local overrides = get_feature_overrides("summary")
	if overrides ~= nil and non_empty_string(overrides.additional_instruction) then
		return overrides.additional_instruction
	end
	return ""
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

	local seen = {}
	local scopes = {}

	for scope in pairs(BUILTIN_FEATURE_SCOPES) do
		seen[scope] = true
		table.insert(scopes, scope)
	end

	if type(features) ~= "table" then
		table.sort(scopes)
		return scopes
	end

	for scope, overrides in pairs(features) do
		if type(scope) == "string" and scope ~= "" and type(overrides) == "table" then
			if not seen[scope] then
				seen[scope] = true
				table.insert(scopes, scope)
			end
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

function M.get_review_provider(role)
	role = role == "verifier" and "verifier" or "reviewer"
	local overrides = get_review_role_overrides(role)
	if overrides ~= nil and non_empty_string(overrides.provider) then
		return overrides.provider
	end

	if role == "verifier" then
		return M.get_review_provider("reviewer")
	end

	return M.get_provider("review")
end

function M.get_ollama_options(scope)
	local base = type(vim.g.pitaco_ollama_options) == "table" and vim.deepcopy(vim.g.pitaco_ollama_options) or {}
	local overrides = get_ollama_scope_overrides(scope)
	if overrides ~= nil and type(overrides.ollama_options) == "table" then
		base = vim.tbl_deep_extend("force", base, overrides.ollama_options)
	end

	return next(base) ~= nil and base or nil
end

function M.get_ollama_keep_alive(scope)
	local overrides = get_ollama_scope_overrides(scope)
	if overrides ~= nil and overrides.ollama_keep_alive ~= nil then
		return overrides.ollama_keep_alive
	end

	return vim.g.pitaco_ollama_keep_alive
end

function M.get_debug_log_path()
	local configured = vim.g.pitaco_debug_log_path
	if type(configured) == "string" and configured ~= "" then
		return vim.fn.expand(configured)
	end

	return vim.fs.joinpath(vim.fn.stdpath("state"), "pitaco", "debug.log")
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

function M.should_auto_index_on_project_open()
	return vim.g.pitaco_auto_index_on_project_open == true
end

function M.get_auto_index_debounce_ms()
	local value = tonumber(vim.g.pitaco_auto_index_debounce_ms)
	if value == nil or value < 0 then
		return 800
	end
	return math.floor(value)
end

function M.get_auto_index_project_markers()
	local configured = vim.g.pitaco_auto_index_project_markers
	if configured == false then
		return {}
	end

	if type(configured) == "table" then
		return vim.deepcopy(configured)
	end

	return vim.deepcopy(DEFAULT_AUTO_INDEX_PROJECT_MARKERS)
end

function M.get_prompt_diff_exclude_files()
	local configured = vim.g.pitaco_prompt_diff_exclude_files
	if configured == false then
		return {}
	end

	if type(configured) == "table" then
		return vim.deepcopy(configured)
	end

	return vim.deepcopy(DEFAULT_PROMPT_DIFF_EXCLUDE_FILES)
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

function M.get_review_model(provider, role)
	role = role == "verifier" and "verifier" or "reviewer"
	local overrides = get_review_role_overrides(role)
	if overrides ~= nil and non_empty_string(overrides.model_id) then
		return overrides.model_id
	end

	if role == "verifier" then
		local reviewer_provider = M.get_review_provider("reviewer")
		if provider == reviewer_provider then
			return M.get_review_model(provider, "reviewer")
		end
		return M.get_model(provider, "review_verifier")
	end

	return M.get_model(provider, "review")
end

function M.get_ollama_url()
	return vim.g.pitaco_ollama_url or "http://localhost:11434"
end

function M.get_opencode_url()
	return vim.g.pitaco_opencode_url or "http://127.0.0.1:4096"
end

function M.get_opencode_auth()
	local username = vim.g.pitaco_opencode_username
	local password = vim.g.pitaco_opencode_password
	local password_env = vim.g.pitaco_opencode_password_env

	if type(username) ~= "string" or username == "" then
		username = "opencode"
	end

	if type(password) ~= "string" or password == "" then
		if type(password_env) ~= "string" or password_env == "" then
			password_env = "OPENCODE_SERVER_PASSWORD"
		end
		password = os.getenv(password_env)
	end

	if type(password) ~= "string" or password == "" then
		return nil
	end

	return {
		username = username,
		password = password,
	}
end

return M
