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

vim.api.nvim_create_user_command("PitacoReview", function(opts)
	commands.review(opts.fargs[1] or "diff")
end, {
	nargs = "?",
	complete = function()
		return { "diff", "file" }
	end,
})

vim.api.nvim_create_user_command("PitacoIndex", function()
	commands.index()
end, {})

-- Main Pitaco command with subcommands
vim.api.nvim_create_user_command("Pitaco", function(opts)
	local action = opts.fargs[1] or "review" -- Default to 'review' if no subcommand is given

	if action == "review" then
		commands.review(opts.fargs[2] or "diff")
	elseif action == "diff" then
		commands.review("diff")
	elseif action == "file" then
		commands.review("file")
	elseif action == "clear" then
		commands.clear()
	elseif action == "clearLine" then
		commands.clear_line()
	elseif action == "health" then
		vim.cmd("checkhealth pitaco")
	elseif action == "index" then
		commands.index()
	elseif action == "comment" then
		commands.comment()
	elseif action == "commit" then
		commands.commit()
	elseif action == "models" then
		commands.models()
	elseif action == "language" then
		commands.language(opts.fargs[2])
	else
		vim.notify("Invalid Pitaco command: " .. action, vim.log.levels.ERROR)
	end
end, {
	nargs = "*", -- Allows for subcommands
	complete = function() -- Autocomplete suggestions
		return {
			"review",
			"diff",
			"file",
			"index",
			"clear",
			"clearLine",
			"health",
			"comment",
			"commit",
			"models",
			"language",
		}
	end,
})
