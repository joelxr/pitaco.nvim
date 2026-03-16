local M = {}

local VALID_PROVIDERS = {
  openai = true,
  anthropic = true,
  openrouter = true,
  ollama = true,
}

local DEFAULT_MODELS = {
  openai = "gpt-5-mini",
  anthropic = "claude-haiku-4-5",
  openrouter = "openrouter/deepseek/deepseek-chat-v3-0324:free",
  ollama = "llama3.1",
}

local DEFAULT_OLLAMA_URL = "http://localhost:11434"

local function is_non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

local function check_plenary()
  local has_plenary, _ = pcall(require, "plenary")
  if not has_plenary then
    vim.health.error("plenary.nvim is required but not installed")
    return false
  end
  vim.health.ok("plenary.nvim is installed")
  return true
end

local function check_curl()
  local handle = io.popen("curl --version")
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result:match("curl") then
      vim.health.ok("curl is installed")
      return true
    end
  end
  vim.health.error("curl is required but not installed")
  return false
end

local function check_context_engine()
  local command = require("pitaco.config").get_context_cli_command()
  if type(command) == "table" then
    command = command[1]
  end

  if not is_non_empty_string(command) then
    vim.health.warn("Pitaco context engine CLI command is not configured")
    return false
  end

  if vim.fn.executable(command) == 1 then
    vim.health.ok(("Context engine CLI found: %s"):format(command))
    return true
  end

  vim.health.warn(("Context engine CLI not found in PATH: %s"):format(command))
  return false
end

local function check_nui()
  local has_layout, _ = pcall(require, "nui.layout")
  local has_popup, _ = pcall(require, "nui.popup")
  local has_input, _ = pcall(require, "nui.input")

  if has_layout and has_popup and has_input then
    vim.health.ok("nui.nvim is installed")
    return true
  end

  vim.health.warn("nui.nvim is not available; commit UI falls back and :Pitaco models is unavailable")
  return false
end

local function check_provider_config(scope)
  local config = require("pitaco.config")
  local label = scope == nil and "default" or scope
  local provider = config.get_provider(scope)
  if not provider or provider == "" then
    vim.health.warn(("No provider configured for %s scope"):format(label))
    return false
  end

  if not VALID_PROVIDERS[provider] then
    vim.health.error(("Invalid provider configured for %s scope: %s"):format(label, provider))
    vim.health.info("Valid providers: openai, anthropic, openrouter, ollama")
    return false
  end

  vim.health.ok(("Provider configured for %s scope: %s"):format(label, provider))
  return true, provider
end

local function check_model(provider_name, model_value)
  if is_non_empty_string(model_value) then
    vim.health.ok(("%s model configured: %s"):format(provider_name, model_value))
    return true
  end

  local fallback = DEFAULT_MODELS[provider_name]
  if fallback ~= nil then
    vim.health.warn(("%s model not set in setup(); default will be used: %s"):format(provider_name, fallback))
    return false
  end

  vim.health.warn(("%s model is not configured"):format(provider_name))
  return false
end

local function check_api_key(provider_name, env_name)
  if is_non_empty_string(os.getenv(env_name)) then
    vim.health.ok(("%s API key found in $%s"):format(provider_name, env_name))
    return true
  end

  vim.health.warn(("%s API key missing: set $%s"):format(provider_name, env_name))
  return false
end

local function check_ollama_url()
  local url = vim.g.pitaco_ollama_url
  if not is_non_empty_string(url) then
    url = DEFAULT_OLLAMA_URL
    vim.health.warn(("Ollama URL not set in setup(); default will be used: %s"):format(url))
  elseif not url:match("^https?://") then
    vim.health.warn(("Ollama URL looks invalid (expected http/https): %s"):format(url))
  else
    vim.health.ok(("Ollama URL configured: %s"):format(url))
  end

  local handle = io.popen(('curl -fsS --max-time 2 "%s/api/tags"'):format(url))
  if not handle then
    vim.health.warn("Could not run curl to test Ollama endpoint")
    return false
  end

  local result = handle:read("*a")
  local success = handle:close()
  if success and result and result ~= "" then
    vim.health.ok("Ollama endpoint is reachable")
    return true
  end

  vim.health.warn(("Ollama endpoint is not reachable: %s/api/tags"):format(url))
  return false
end

local function check_scope_resolution(scope)
  local config = require("pitaco.config")
  local label = scope == nil and "default" or scope
  local provider = config.get_provider(scope)
  if not VALID_PROVIDERS[provider] then
    return
  end

  local model = config.get_model(provider, scope)
  if is_non_empty_string(model) then
    vim.health.ok(("%s scope resolves to %s / %s"):format(label, provider, model))
  else
    vim.health.warn(("%s scope did not resolve a model"):format(label))
  end
end

local function check_all_provider_setups(selected_provider)
  local config = require("pitaco.config")
  vim.health.start("Provider setup")

  local ready = {
    openai = true,
    anthropic = true,
    openrouter = true,
    ollama = true,
  }

  ready.openai = check_api_key("openai", "OPENAI_API_KEY")

  ready.anthropic = check_api_key("anthropic", "ANTHROPIC_API_KEY")

  ready.openrouter = check_api_key("openrouter", "OPENROUTER_API_KEY")

  ready.ollama = check_ollama_url()

  if selected_provider ~= nil and VALID_PROVIDERS[selected_provider] then
    check_model(selected_provider, config.get_model(selected_provider))
    if ready[selected_provider] then
      vim.health.ok(("Selected provider '%s' looks ready"):format(selected_provider))
    else
      vim.health.warn(("Selected provider '%s' is not fully ready yet"):format(selected_provider))
    end
  end
end

function M.check()
  local config = require("pitaco.config")
  vim.health.start("Pitaco.nvim health check")

  check_plenary()
  check_nui()
  check_curl()
  check_context_engine()
  local _, provider = check_provider_config(nil)
  for _, scope in ipairs(config.list_feature_scopes()) do
    check_provider_config(scope)
  end
  check_all_provider_setups(provider)
  vim.health.start("Resolved model scopes")
  check_scope_resolution(nil)
  for _, scope in ipairs(config.list_feature_scopes()) do
    check_scope_resolution(scope)
  end
end

return M
