local M = {}

local function load_provider(provider_name)
	if provider_name == "openai" then
		return require("pitaco.providers.openai")
	end

	if provider_name == "anthropic" then
		return require("pitaco.providers.anthropic")
	end

	if provider_name == "openrouter" then
		return require("pitaco.providers.openrouter")
	end

	if provider_name == "ollama" then
		return require("pitaco.providers.ollama")
	end

	error("Invalid provider name: " .. provider_name)
end

function M.create_provider(provider_name, scope)
	local base = load_provider(provider_name)
	if scope == nil or scope == "" then
		return base
	end

	local review = require("pitaco.review")
	local provider = {}
	for key, value in pairs(base) do
		provider[key] = value
	end

	provider.scope = scope
	provider.get_model = function()
		return base.get_model(scope)
	end
	provider.build_chat_request = function(system_prompt, messages, max_tokens)
		return base.build_chat_request(system_prompt, messages, max_tokens, scope)
	end
	provider.prepare_requests = function(messages, review_mode)
		return review.build_requests(provider, messages, review_mode)
	end

	return provider
end

return M
