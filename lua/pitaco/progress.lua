local M = {}

local progress_state = {
	percentage = nil,
	current_request = 0,
	total_requests = 0,
	running = false,
	message = "",
}

local function emit_user_autocmd(pattern, data)
	local opts = {
		pattern = pattern,
		modeline = false,
		data = data,
	}

	if vim.in_fast_event() then
		vim.schedule(function()
			vim.api.nvim_exec_autocmds("User", opts)
		end)
		return
	end

	vim.api.nvim_exec_autocmds("User", opts)
end

function M.stop()
	progress_state.running = false
	progress_state.percentage = nil
	progress_state.current_request = 0
	progress_state.total_requests = 0
	progress_state.message = ""

	emit_user_autocmd("PitacoProgressStop")
end

function M.update(message, current_request, total_requests)
	progress_state.running = current_request <= total_requests
	progress_state.percentage = nil
	progress_state.current_request = current_request
	progress_state.total_requests = total_requests
	progress_state.message = message

	emit_user_autocmd("PitacoProgressUpdate", {
		message = message,
		current_request = current_request,
		total_requests = total_requests,
		percentage = nil,
		running = progress_state.running,
	})
end

function M.get_state()
	return progress_state
end

return M
