local M = {}

local namespace = vim.api.nvim_create_namespace("pitaco")

function M.get_namespace()
	return namespace
end

return M
