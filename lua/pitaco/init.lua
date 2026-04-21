local M = {}

local DEFAULT_MODELS = {
	openai = "gpt-5-mini",
	anthropic = "claude-haiku-4-5",
	openrouter = "openrouter/deepseek/deepseek-chat-v3-0324:free",
	ollama = "llama3.1",
	opencode = "default",
}

local default_opts = {
	model_id = nil,
	ollama_url = "http://localhost:11434",
	ollama_options = nil,
	ollama_keep_alive = nil,
	opencode_url = "http://127.0.0.1:4096",
	opencode_username = nil,
	opencode_password = nil,
	opencode_password_env = "OPENCODE_SERVER_PASSWORD",
	provider = "anthropic",
	language = "english",
	commit_keymap = nil,
	commit_system_prompt = nil,
	persist_model_selection = true,
	context_enabled = true,
	context_cli_cmd = "pitaco-indexer",
	context_max_chunks = 6,
	context_timeout_ms = 1500,
	context_include_git_diff = true,
	auto_index_on_project_open = false,
	auto_index_debounce_ms = 800,
	auto_index_project_markers = nil,
	prompt_diff_exclude_files = nil,
	debug = false,
	debug_log_path = nil,
	features = {},
}

local function merge_persisted_feature_overrides(features, persisted)
	if type(persisted) ~= "table" then
		return features
	end

	for scope, overrides in pairs(persisted) do
		if type(scope) == "string" and scope ~= "" and type(overrides) == "table" then
			if scope == "review" and type(overrides.verifier) == "table" then
				features.review = features.review or {}
				features.review.verifier = features.review.verifier or {}
				if type(overrides.verifier.provider) == "string" and overrides.verifier.provider ~= "" then
					features.review.verifier.provider = overrides.verifier.provider
				end
				if type(overrides.verifier.model_id) == "string" and overrides.verifier.model_id ~= "" then
					features.review.verifier.model_id = overrides.verifier.model_id
				end
			end

			features[scope] = features[scope] or {}
			if type(overrides.provider) == "string" and overrides.provider ~= "" then
				features[scope].provider = overrides.provider
			end
			if type(overrides.model_id) == "string" and overrides.model_id ~= "" then
				features[scope].model_id = overrides.model_id
			end
		end
	end

	return features
end

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
	if opts.review_verifier_provider ~= nil then
		ensure_scope("review").verifier = ensure_scope("review").verifier or {}
		ensure_scope("review").verifier.provider = opts.review_verifier_provider
	end
	if opts.review_verifier_model_id ~= nil then
		ensure_scope("review").verifier = ensure_scope("review").verifier or {}
		ensure_scope("review").verifier.model_id = opts.review_verifier_model_id
	end

	if opts.commit_provider ~= nil then
		ensure_scope("commit").provider = opts.commit_provider
	end
	if opts.commit_model_id ~= nil then
		ensure_scope("commit").model_id = opts.commit_model_id
	end

	if opts.summary_provider ~= nil then
		ensure_scope("summary").provider = opts.summary_provider
	end
	if opts.summary_model_id ~= nil then
		ensure_scope("summary").model_id = opts.summary_model_id
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
		if type(state.model_id) == "string" and state.model_id ~= "" then
			opts.model_id = state.model_id
		elseif type(state.models) == "table" and type(opts.provider) == "string" and opts.provider ~= "" then
			local legacy_model_id = state.models[opts.provider]
			if type(legacy_model_id) == "string" and legacy_model_id ~= "" then
				opts.model_id = legacy_model_id
			end
		end
		feature_overrides = merge_persisted_feature_overrides(feature_overrides, state.features)
	end

	if opts.model_id == nil or opts.model_id == "" then
		opts.model_id = DEFAULT_MODELS[opts.provider]
	end

	vim.g.pitaco_provider = opts.provider
	vim.g.pitaco_model_id = opts.model_id
	vim.g.pitaco_ollama_url = opts.ollama_url
	vim.g.pitaco_ollama_options = type(opts.ollama_options) == "table" and vim.deepcopy(opts.ollama_options) or nil
	vim.g.pitaco_ollama_keep_alive = opts.ollama_keep_alive
	vim.g.pitaco_opencode_url = opts.opencode_url
	vim.g.pitaco_opencode_username = opts.opencode_username
	vim.g.pitaco_opencode_password = opts.opencode_password
	vim.g.pitaco_opencode_password_env = opts.opencode_password_env
	vim.g.pitaco_language = opts.language
	vim.g.pitaco_commit_keymap = opts.commit_keymap
	vim.g.pitaco_commit_system_prompt = opts.commit_system_prompt
	vim.g.pitaco_persist_model_selection = opts.persist_model_selection
	vim.g.pitaco_context_enabled = opts.context_enabled
	vim.g.pitaco_context_cli_cmd = opts.context_cli_cmd
	vim.g.pitaco_context_max_chunks = opts.context_max_chunks
	vim.g.pitaco_context_timeout_ms = opts.context_timeout_ms
	vim.g.pitaco_context_include_git_diff = opts.context_include_git_diff
	vim.g.pitaco_auto_index_on_project_open = opts.auto_index_on_project_open
	vim.g.pitaco_auto_index_debounce_ms = opts.auto_index_debounce_ms
	vim.g.pitaco_auto_index_project_markers = type(opts.auto_index_project_markers) == "table"
			and vim.deepcopy(opts.auto_index_project_markers)
		or opts.auto_index_project_markers
	vim.g.pitaco_prompt_diff_exclude_files = type(opts.prompt_diff_exclude_files) == "table"
			and vim.deepcopy(opts.prompt_diff_exclude_files)
		or opts.prompt_diff_exclude_files
	vim.g.pitaco_debug = opts.debug
	vim.g.pitaco_debug_log_path = opts.debug_log_path
	vim.g.pitaco_features = feature_overrides

	local group = vim.api.nvim_create_augroup("PitacoReviewRestore", { clear = true })
	local review_renderer = require("pitaco.review_renderer")

	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "TextChanged" }, {
		group = group,
		callback = function(args)
			review_renderer.render_buffer(args.buf)
		end,
	})

	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
		group = group,
		callback = function(args)
			require("pitaco.context_engine").maybe_auto_index(args.buf)
		end,
	})
end

return M
