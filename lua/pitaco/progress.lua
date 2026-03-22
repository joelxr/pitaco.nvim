local M = {}

local progress_state = {
	percentage = nil,
	current_request = 0,
	total_requests = 0,
	running = false,
	message = "",
}

function M.stop()
	progress_state.running = false
	progress_state.percentage = nil
	progress_state.current_request = 0
	progress_state.total_requests = 0
	progress_state.message = ""

	vim.api.nvim_exec_autocmds("User", {
		pattern = "PitacoProgressStop",
		modeline = false,
	})
end

function M.update(message, current_request, total_requests)
	progress_state.running = current_request <= total_requests
	progress_state.percentage = nil
	progress_state.current_request = current_request
	progress_state.total_requests = total_requests
	progress_state.message = message

	vim.api.nvim_exec_autocmds("User", {
		pattern = "PitacoProgressUpdate",
		modeline = false,
		data = {
			message = message,
			current_request = current_request,
			total_requests = total_requests,
			percentage = nil,
			running = progress_state.running,
		},
	})
end

function M.get_state()
	return progress_state
end

return M
