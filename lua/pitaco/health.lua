local M = {}

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

local function check_nui()
  local has_nui, _ = pcall(require, "nui")
  if not has_nui then
    vim.health.error("nui.nvim is required but not installed")
    return false
  end
  vim.health.ok("nui.nvim is installed")
  return true
end

local function check_provider_config()
  local provider = require("pitaco.config").get_provider()
  if not provider or provider == "" then
    vim.health.warn("No provider configured in setup()")
    return false
  end
  vim.health.ok(("Provider configured: %s"):format(provider))
  return true
end

function M.check()
  vim.health.start("Pitaco.nvim health check")
  
  check_plenary()
  check_nui()
  check_curl()
  check_provider_config()
end

return M
