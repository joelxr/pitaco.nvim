-- This is a plugin for the Neovim text editor
-- Author: Joel Xavier Rocha <joelxr@gmail.com>
-- License: MIT
-- Source: https://github.com/joelxr/pitaco

if vim.g.loaded_pitaco then
	return
end

vim.g.loaded_pitaco = true

local pitaco = require("pitaco")

pitaco.setup()

local commands = require("pitaco.commands")

if vim.g.pitaco_commit_keymap ~= nil and vim.g.pitaco_commit_keymap ~= "" then
	vim.keymap.set("n", vim.g.pitaco_commit_keymap, "<cmd>Pitaco commit<CR>", { desc = "Pitaco commit" })
end

-- Main Pitaco command with subcommands
vim.api.nvim_create_user_command("Pitaco", function(opts)
	local action = opts.fargs[1] or "review" -- Default to 'review' if no subcommand is given

	if action == "review" then
		commands.review()
	elseif action == "clear" then
		commands.clear()
	elseif action == "clearLine" then
		commands.clear_line()
	elseif action == "health" then
		vim.cmd("checkhealth pitaco")
	elseif action == "comment" then
		commands.comment()
	elseif action == "commit" then
		commands.commit()
	elseif action == "models" then
		commands.models()
	else
		vim.notify("Invalid Pitaco command: " .. action, vim.log.levels.ERROR)
	end
end, {
	nargs = "*", -- Allows for subcommands
	complete = function() -- Autocomplete suggestions
		return { "review", "clear", "clearLine", "health", "comment", "commit", "models" }
	end,
})
