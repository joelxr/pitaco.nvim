local M = {}

local model_state = require("pitaco.model_state")
local progress = require("pitaco.progress")
local curl_json

local PROVIDERS = { "openai", "anthropic", "openrouter", "ollama" }

local DEFAULT_MODELS = {
	openai = "gpt-5-mini",
	anthropic = "claude-haiku-4-5",
	openrouter = "openrouter/deepseek/deepseek-chat-v3-0324:free",
	ollama = "llama3.1",
}

local function is_non_empty_string(value)
	return type(value) == "string" and value ~= ""
end

local function unique_models(models, current_model)
	local seen = {}
	local list = {}

	local function add(model)
		if is_non_empty_string(model) and not seen[model] then
			seen[model] = true
			table.insert(list, model)
		end
	end

	add(current_model)
	for _, model in ipairs(models or {}) do
		add(model)
	end

	return list
end

local function sorted_strings(items)
	table.sort(items, function(a, b)
		return a < b
	end)
	return items
end

local function get_current_model(provider)
	if provider == "openai" then
		return vim.g.pitaco_openai_model_id
	end
	if provider == "anthropic" then
		return vim.g.pitaco_anthropic_model_id
	end
	if provider == "openrouter" then
		return vim.g.pitaco_openrouter_model_id
	end
	if provider == "ollama" then
		return vim.g.pitaco_ollama_model_id
	end
	return nil
end

local function get_provider_status(provider)
	if provider == "openai" then
		return is_non_empty_string(os.getenv("OPENAI_API_KEY")), "OPENAI_API_KEY"
	end
	if provider == "anthropic" then
		return is_non_empty_string(os.getenv("ANTHROPIC_API_KEY")), "ANTHROPIC_API_KEY"
	end
	if provider == "openrouter" then
		return is_non_empty_string(os.getenv("OPENROUTER_API_KEY")), "OPENROUTER_API_KEY"
	end
	if provider == "ollama" then
		local url = vim.g.pitaco_ollama_url or "http://localhost:11434"
		local payload = curl_json(url .. "/api/tags", nil, 2)
		if payload ~= nil then
			return true, "local"
		end
		return false, "ollama_unreachable"
	end
	return false, "unknown"
end

local function shell_escape(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

curl_json = function(url, headers, timeout)
	local parts = { "curl", "-fsS", "--max-time", tostring(timeout or 3) }
	for _, h in ipairs(headers or {}) do
		table.insert(parts, "-H")
		table.insert(parts, shell_escape(h))
	end
	table.insert(parts, shell_escape(url))

	local command = table.concat(parts, " ")
	local handle = io.popen(command)
	if not handle then
		return nil
	end

	local body = handle:read("*a")
	local ok = handle:close()
	if not ok or not is_non_empty_string(body) then
		return nil
	end

	local parsed_ok, parsed = pcall(vim.json.decode, body)
	if not parsed_ok or type(parsed) ~= "table" then
		return nil
	end

	return parsed
end

local function to_per_million(value)
	local n = tonumber(value)
	if n == nil then
		return nil
	end
	return n * 1000000
end

local function tail_truncate(text, max_len)
	if #text <= max_len then
		return text
	end
	return "..." .. text:sub(#text - max_len + 4)
end

local function display_model_id(provider, model_id)
	local max_len = 44
	if provider == "openrouter" then
		local compact = model_id:gsub("^openrouter/", "")
		return tail_truncate(compact, max_len)
	end

	if #model_id > max_len then
		return model_id:sub(1, max_len - 3) .. "..."
	end

	return model_id
end

local function fetch_openai_models()
	local api_key = os.getenv("OPENAI_API_KEY")
	if not is_non_empty_string(api_key) then
		return {}
	end

	local payload = curl_json("https://api.openai.com/v1/models", {
		"Authorization: Bearer " .. api_key,
	}, 4)
	if payload == nil or type(payload.data) ~= "table" then
		return {}
	end

	local models = {}
	for _, model in ipairs(payload.data) do
		if type(model) == "table" and is_non_empty_string(model.id) then
			local id = model.id
			if id:match("^gpt") or id:match("^o[1345]") then
				table.insert(models, id)
			end
		end
	end

	return sorted_strings(models)
end

local function fetch_anthropic_models()
	local api_key = os.getenv("ANTHROPIC_API_KEY")
	if not is_non_empty_string(api_key) then
		return {}
	end

	local payload = curl_json("https://api.anthropic.com/v1/models", {
		"x-api-key: " .. api_key,
		"anthropic-version: 2023-06-01",
	}, 4)
	if payload == nil or type(payload.data) ~= "table" then
		return {}
	end

	local models = {}
	for _, model in ipairs(payload.data) do
		if type(model) == "table" and is_non_empty_string(model.id) then
			table.insert(models, model.id)
		end
	end

	return sorted_strings(models)
end

local function fetch_openrouter_models()
	local payload = curl_json("https://openrouter.ai/api/v1/models", nil, 4)
	if payload == nil or type(payload.data) ~= "table" then
		return {}
	end

	local models = {}
	for _, model in ipairs(payload.data) do
		if type(model) == "table" and is_non_empty_string(model.id) then
			table.insert(models, model.id)
		end
	end

	return sorted_strings(models)
end

local function fetch_ollama_models()
	local url = vim.g.pitaco_ollama_url or "http://localhost:11434"
	local payload = curl_json(url .. "/api/tags", nil, 4)
	if payload == nil or type(payload.models) ~= "table" then
		return {}
	end

	local models = {}
	for _, model in ipairs(payload.models) do
		if type(model) == "table" then
			local id = model.model or model.name
			if is_non_empty_string(id) then
				table.insert(models, id)
			end
		end
	end

	return sorted_strings(models)
end

local function provider_models(provider, current_model)
	local models = {}
	if provider == "openai" then
		models = fetch_openai_models()
	elseif provider == "anthropic" then
		models = fetch_anthropic_models()
	elseif provider == "openrouter" then
		models = fetch_openrouter_models()
	elseif provider == "ollama" then
		models = fetch_ollama_models()
	end

	if #models == 0 then
		models = { DEFAULT_MODELS[provider] }
	end

	return unique_models(models, current_model)
end

local function fetch_openai_credits()
	local api_key = os.getenv("OPENAI_API_KEY")
	if not is_non_empty_string(api_key) then
		return nil
	end

	local payload = curl_json("https://api.openai.com/dashboard/billing/credit_grants", {
		"Authorization: Bearer " .. api_key,
	}, 4)
	if payload == nil then
		return nil
	end

	local granted = tonumber(payload.total_granted)
	local used = tonumber(payload.total_used)
	if granted == nil and type(payload.grants) == "table" then
		granted = tonumber(payload.grants.total_granted)
		used = tonumber(payload.grants.total_used)
	end

	if granted == nil or used == nil then
		return nil
	end

	return math.max(granted - used, 0)
end

local function fetch_openrouter_credits()
	local api_key = os.getenv("OPENROUTER_API_KEY")
	if not is_non_empty_string(api_key) then
		return nil
	end

	local payload = curl_json("https://openrouter.ai/api/v1/credits", {
		"Authorization: Bearer " .. api_key,
	}, 4)

	if payload == nil or type(payload.data) ~= "table" then
		return nil
	end

	local total_credits = tonumber(payload.data.total_credits)
	local total_usage = tonumber(payload.data.total_usage)
	if total_credits == nil or total_usage == nil then
		return nil
	end

	return math.max(total_credits - total_usage, 0)
end

local function fetch_openrouter_costs()
	local payload = curl_json("https://openrouter.ai/api/v1/models", nil, 4)
	if payload == nil or type(payload.data) ~= "table" then
		return {}
	end

	local costs = {}
	for _, model in ipairs(payload.data) do
		if type(model) == "table" and is_non_empty_string(model.id) and type(model.pricing) == "table" then
			local in_cost = to_per_million(model.pricing.prompt)
			local out_cost = to_per_million(model.pricing.completion)
			if in_cost ~= nil and out_cost ~= nil then
				costs[model.id] = {
					input = in_cost,
					output = out_cost,
				}
			end
		end
	end

	return costs
end

local function build_entries()
	local entries = {}
	local selected_provider = vim.g.pitaco_provider

	local openrouter_balance = fetch_openrouter_credits()
	local openai_balance = fetch_openai_credits()
	local openrouter_costs = fetch_openrouter_costs()

	for _, provider in ipairs(PROVIDERS) do
		local provider_ready, provider_hint = get_provider_status(provider)
		local current_model = get_current_model(provider)
		local models = provider_models(provider, current_model)
		local provider_balance = "-"

		if provider == "openrouter" and openrouter_balance ~= nil then
			provider_balance = string.format("$%.2f", openrouter_balance)
		elseif provider == "openai" and openai_balance ~= nil then
			provider_balance = string.format("$%.2f", openai_balance)
		elseif provider == "ollama" then
			provider_balance = "n/a"
		end

		for _, model_id in ipairs(models) do
			local plan = "unknown"
			local cost = "unknown"
			if provider == "ollama" then
				plan = "local"
				cost = "n/a"
			elseif provider == "openrouter" then
				local pricing = openrouter_costs[model_id]
				if pricing ~= nil then
					if pricing.input == 0 and pricing.output == 0 then
						plan = "free"
					else
						plan = "paid"
					end
					cost = string.format("$%.2f/$%.2f per 1M in/out", pricing.input, pricing.output)
				end
			end

			local is_selected = (selected_provider == provider) and (current_model == model_id)
			local status = provider_ready and "ready" or ("missing " .. provider_hint)
			local display_model = display_model_id(provider, model_id)
			local meta = { status }
			if plan ~= "unknown" then
				table.insert(meta, "plan:" .. plan)
			end
			if cost ~= "unknown" then
				table.insert(meta, "cost:" .. cost)
			end
			if provider_balance ~= "-" then
				table.insert(meta, "bal:" .. provider_balance)
			end
			if is_selected then
				table.insert(meta, "* current")
			end

			local line = string.format("%s/%s | %s", provider, display_model, table.concat(meta, " | "))

			table.insert(entries, {
				provider = provider,
				model_id = model_id,
				display_model = display_model,
				ready = provider_ready,
				status = status,
				plan = plan,
				cost = cost,
				balance = provider_balance,
				selected = is_selected,
				line = line,
				search_text = (provider .. " " .. model_id .. " " .. line):lower(),
			})
		end
	end

	table.sort(entries, function(a, b)
		if a.ready ~= b.ready then
			return a.ready
		end
		if a.provider ~= b.provider then
			return a.provider < b.provider
		end
		return a.model_id < b.model_id
	end)

	return entries
end

local function selected_index(entries)
	for i, entry in ipairs(entries) do
		if entry.selected then
			return i
		end
	end
	return 1
end

local function entry_lines(entry, is_active)
	local marker = is_active and ">" or " "
	local line = string.format("%s %s", marker, entry.line)
	return line
end

local function render_entries(buf, entries, index, query)
	local lines = {
		("Search: %s"):format(query ~= "" and query or "(none)"),
		"",
	}

	if #entries == 0 then
		table.insert(lines, "  No models match your search")
	end

	for i, entry in ipairs(entries) do
		local line = entry_lines(entry, i == index)
		table.insert(lines, line)
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

local function apply_selection(choice)
	if choice == nil then
		return
	end

	vim.g.pitaco_provider = choice.provider
	if choice.provider == "openai" then
		vim.g.pitaco_openai_model_id = choice.model_id
	elseif choice.provider == "anthropic" then
		vim.g.pitaco_anthropic_model_id = choice.model_id
	elseif choice.provider == "openrouter" then
		vim.g.pitaco_openrouter_model_id = choice.model_id
	elseif choice.provider == "ollama" then
		vim.g.pitaco_ollama_model_id = choice.model_id
	end

	if vim.g.pitaco_persist_model_selection ~= false then
		local ok, err = model_state.persist_selection(choice.provider, choice.model_id)
		if not ok then
			vim.notify("Pitaco models: failed to persist selection: " .. tostring(err), vim.log.levels.WARN)
		end
	end

	vim.notify(
		("Pitaco active model: %s (%s)"):format(choice.model_id, choice.provider),
		vim.log.levels.INFO
	)
end

function M.open()
	local ok_popup, Popup = pcall(require, "nui.popup")
	if not ok_popup then
		vim.notify("Pitaco models: nui.nvim is required for model picker", vim.log.levels.ERROR)
		return
	end

	progress.update("Loading models", 0, 1)
	vim.cmd("redraw")
	vim.defer_fn(function()
		local ok_entries, entries = pcall(build_entries)
		progress.stop()
		if not ok_entries then
			vim.notify("Pitaco models: failed to load models", vim.log.levels.ERROR)
			return
		end
		if #entries == 0 then
			vim.notify("Pitaco models: no model entries found", vim.log.levels.WARN)
			return
		end

		local width = math.max(math.floor(vim.o.columns * 0.8), 80)
		local height = math.max(math.floor(vim.o.lines * 0.7), 18)
		local max_height = (#entries) + 4
		height = math.min(height, max_height)

		local popup = Popup({
			enter = true,
			focusable = true,
			border = {
				style = "rounded",
				text = { top = "Pitaco models", top_align = "center" },
			},
			position = "50%",
			size = {
				width = width,
				height = height,
			},
		})

		popup:mount()

		local buf = popup.bufnr
		local win = popup.winid
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].filetype = "pitaco-models"
		vim.wo[win].wrap = false
		vim.wo[win].cursorline = false

		local all_entries = entries
		local filtered_entries = entries
		local query = ""
		local index = selected_index(filtered_entries)

		local function sync_cursor()
			local cursor_line = #filtered_entries == 0 and 3 or (index + 2)
			vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
		end

		local function render()
			render_entries(buf, filtered_entries, index, query)
			sync_cursor()
		end

		local function apply_filter()
			if query == "" then
				filtered_entries = all_entries
			else
				local q = query:lower()
				filtered_entries = {}
				for _, entry in ipairs(all_entries) do
					if entry.search_text:find(q, 1, true) then
						table.insert(filtered_entries, entry)
					end
				end
			end

			index = math.max(1, math.min(index, #filtered_entries))
			if #filtered_entries == 0 then
				index = 1
			end
			render()
		end

		render()

		local function close()
			if popup ~= nil then
				popup:unmount()
				popup = nil
			end
		end

		local function move(delta)
			if #filtered_entries == 0 then
				return
			end
			index = math.max(1, math.min(#filtered_entries, index + delta))
			render()
			if popup ~= nil and popup.winid ~= nil and vim.api.nvim_win_is_valid(popup.winid) then
				sync_cursor()
			end
		end

		local function choose()
			if #filtered_entries == 0 then
				vim.notify("Pitaco models: no entries to select", vim.log.levels.WARN)
				return
			end
			local choice = filtered_entries[index]
			close()
			apply_selection(choice)
		end

		local function search()
			local value = vim.fn.input("Pitaco models search: ", query)
			if value == nil then
				return
			end
			query = vim.trim(value)
			apply_filter()
		end

		local function clear_search()
			if query == "" then
				return
			end
			query = ""
			apply_filter()
		end

		local mapopts = { buffer = buf, nowait = true, silent = true, noremap = true }
		vim.keymap.set("n", "j", function() move(1) end, mapopts)
		vim.keymap.set("n", "<Down>", function() move(1) end, mapopts)
		vim.keymap.set("n", "k", function() move(-1) end, mapopts)
		vim.keymap.set("n", "<Up>", function() move(-1) end, mapopts)
		vim.keymap.set("n", "/", search, mapopts)
		vim.keymap.set("n", "c", clear_search, mapopts)
		vim.keymap.set("n", "<CR>", choose, mapopts)
		vim.keymap.set("n", "q", close, mapopts)
		vim.keymap.set("n", "<Esc>", close, mapopts)
	end, 30)
end

return M
