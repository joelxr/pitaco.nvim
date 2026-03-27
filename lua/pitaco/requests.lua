local progress = require("pitaco.progress")
local utils = require("pitaco.utils")
local log = require("pitaco.log")
local context_engine = require("pitaco.context_engine")
local review_diagnostics = require("pitaco.review_diagnostics")
local review_parser = require("pitaco.review_parser")
local review_renderer = require("pitaco.review_renderer")
local review_store = require("pitaco.review_store")
local review_verifier = require("pitaco.review_verifier")

local M = {}

local function run_on_main_loop(fn)
	if vim.in_fast_event() then
		vim.schedule(fn)
		return
	end

	fn()
end

local function dispatch_provider_request(provider, request_json, callback)
	run_on_main_loop(function()
		provider.request(request_json, function(response, error_message)
			run_on_main_loop(function()
				callback(response, error_message)
			end)
		end)
	end)
end

local function progress_message(metadata, current_request, total_requests)
	local provider = metadata.provider or "unknown"
	local model_id = metadata.model_id or "unknown"
	return ("Reviewing %d/%d with %s/%s"):format(current_request or 0, total_requests or 0, provider, model_id)
end

local function verifier_progress_message(metadata, current_request, total_requests)
	local provider = metadata.verifier_provider or "unknown"
	local model_id = metadata.verifier_model_id or "unknown"
	return ("Verifying %d/%d with %s/%s"):format(current_request or 0, total_requests or 0, provider, model_id)
end

local function should_reject_weak_finding(diagnostic)
	local message = type(diagnostic) == "table" and type(diagnostic.message) == "string" and diagnostic.message:lower() or ""
	if message == "" then
		return true
	end

	local reject_patterns = {
		"this is okay",
		"for maintenance",
		"for clarity",
		"may cause confusion",
		"confusion in maintenance",
		"test suite",
		"test case expects",
		"may need to be updated",
		"documentation",
		"jsdoc",
		"doc comment",
		"named inconsistently",
		"naming",
		"style",
		"formatting",
	}

	for _, pattern in ipairs(reject_patterns) do
		if message:find(pattern) ~= nil then
			return true
		end
	end

	return false
end

local function sanitize_verifier_text(text)
	if type(text) ~= "string" then
		return ""
	end

	local trimmed = vim.trim(text)
	if trimmed == "" then
		return ""
	end

	local lines = vim.split(trimmed, "\n", { plain = true })
	local meaningful = {}

	for _, line in ipairs(lines) do
		local current = vim.trim(line)
		if current ~= "" and current ~= "```" and not current:match("^```[%w_-]+$") then
			table.insert(meaningful, current)
		end
	end

	return table.concat(meaningful, "\n")
end

local function is_finding_line(line)
	if type(line) ~= "string" then
		return false
	end

	local trimmed = vim.trim(line)
	if trimmed == "" then
		return true
	end

	return trimmed:match("^file=.-%s+line=%d+:%s*.+$") ~= nil
		or trimmed:match("^file=.-%s+lines=%d+%-%d+:%s*.+$") ~= nil
		or trimmed:match("^line=%d+:%s*.+$") ~= nil
		or trimmed:match("^lines=%d+%-%d+:%s*.+$") ~= nil
end

local function parse_verifier_decision(text)
	local sanitized = sanitize_verifier_text(text)
	if sanitized == "" then
		return {
			status = "empty",
			finding = "",
			raw = "",
		}
	end

	local lines = vim.split(sanitized, "\n", { plain = true })
	local status = nil
	local finding = nil

	for _, line in ipairs(lines) do
		local trimmed = vim.trim(line)
		if trimmed:match("^status=") then
			if status ~= nil then
				return nil, sanitized
			end
			status = trimmed:match("^status=(.+)$")
		elseif trimmed:match("^finding=") then
			if finding ~= nil then
				return nil, sanitized
			end
			finding = trimmed:match("^finding=(.+)$")
		else
			return nil, sanitized
		end
	end

	if status == nil then
		return nil, sanitized
	end

	if status ~= "confirmed" and status ~= "rejected" and status ~= "insufficient_evidence" then
		return nil, sanitized
	end

	if status == "confirmed" then
		if type(finding) ~= "string" or not is_finding_line(finding) then
			return nil, sanitized
		end
	else
		if finding ~= nil then
			return nil, sanitized
		end
	end

	return {
		status = status,
		finding = finding or "",
		raw = sanitized,
	}, nil
end

local function project_immediate_diagnostics(namespace, diagnostics, repo_root)
	local grouped = {}

	for _, diag in ipairs(diagnostics or {}) do
		local path = diag.absolute_path or diag.file
		if type(path) == "string" and path ~= "" and not path:find("^/") then
			path = (repo_root or vim.fn.getcwd()) .. "/" .. path
		end

		if type(path) == "string" and path ~= "" then
			path = vim.fn.fnamemodify(path, ":p")
			grouped[path] = grouped[path] or {}
			table.insert(grouped[path], {
				lnum = diag.lnum or 0,
				col = diag.col or 0,
				message = diag.message or "",
				severity = diag.severity or vim.diagnostic.severity.INFO,
				source = diag.source or "pitaco",
			})
		end
	end

	for path, items in pairs(grouped) do
		local bufnr = vim.fn.bufadd(path)
		vim.fn.bufload(bufnr)
		vim.diagnostic.set(namespace, bufnr, items)
	end
end

function M.make_requests(namespace, provider, request_bundle)
	local requests = vim.deepcopy(request_bundle.requests or {})
	local metadata = request_bundle.metadata or {}
	local starting_request_count = request_bundle.request_count or #requests
	local request_index = 0
	local aggregated = {}
	local reviewer_candidates = {}

	local function append_diagnostics(diagnostics)
		for _, diag in ipairs(diagnostics or {}) do
			local stored = vim.deepcopy(diag)
			local target = diag.file or metadata.buffer_path
			if type(target) == "string" and target ~= "" and not target:find("^/") then
				stored.absolute_path = (metadata.repo_root or vim.fn.getcwd()) .. "/" .. target
			else
				stored.absolute_path = target
			end
			table.insert(aggregated, stored)
		end
	end

	local function append_candidates(diagnostics)
		for _, diagnostic in ipairs(diagnostics or {}) do
			table.insert(reviewer_candidates, vim.deepcopy(diagnostic))
		end
	end

	local function dedupe_candidates(diagnostics)
		local deduped = {}
		local seen = {}

		for _, diagnostic in ipairs(diagnostics or {}) do
			local key = table.concat({
				tostring(diagnostic.file or ""),
				tostring(diagnostic.lnum or 0),
				tostring(diagnostic.message or ""),
			}, "|")

			if not seen[key] then
				seen[key] = true
				table.insert(deduped, diagnostic)
			end
		end

		if #deduped ~= #diagnostics then
			log.debug(("Deduped reviewer candidates from %d to %d"):format(#diagnostics, #deduped))
			log.debug_table("deduped reviewer candidates", deduped)
		end

		return deduped
	end

	local function normalize_with_logging(diagnostics, label)
		log.debug(("Parsed %d diagnostics from %s"):format(#diagnostics, label))
		log.debug_table(("parsed diagnostics (%s)"):format(label), diagnostics)

		local normalized_diagnostics, dropped_count = review_diagnostics.normalize(metadata, diagnostics)
		if dropped_count > 0 then
			log.debug(("Dropped or corrected %d diagnostics during %s normalization"):format(dropped_count, label))
		end
		log.debug_table(("normalized diagnostics (%s)"):format(label), normalized_diagnostics)
		return normalized_diagnostics
	end

	local function filter_weak_findings(diagnostics, label)
		local kept = {}
		local dropped = 0
		for _, diagnostic in ipairs(diagnostics or {}) do
			if should_reject_weak_finding(diagnostic) then
				dropped = dropped + 1
			else
				table.insert(kept, diagnostic)
			end
		end

		if dropped > 0 then
			log.debug(("Rejected %d weak diagnostics during %s filtering"):format(dropped, label))
			log.debug_table(("filtered diagnostics (%s)"):format(label), kept)
		end

		return kept
	end

	local function run_verifier_stage(candidates, done)
		local verifier_provider = review_verifier.get_provider()
		if verifier_provider == nil then
			append_diagnostics(candidates)
			done()
			return
		end

		if #candidates == 0 then
			done()
			return
		end

		local candidate_index = 0
		local total_candidates = #candidates

		local function verify_next()
			candidate_index = candidate_index + 1
			if candidate_index > total_candidates then
				done()
				return
			end

			local candidate = candidates[candidate_index]
			local request_json = review_verifier.build_request(verifier_provider, metadata, candidate)

			log.debug(
				("Dispatching verifier request %d/%d via provider '%s'"):format(
					candidate_index,
					total_candidates,
					verifier_provider.name or "unknown"
				)
			)
			log.preview_json("verifier request payload", request_json)
			progress.update(verifier_progress_message(metadata, candidate_index, total_candidates), candidate_index, total_candidates)

			dispatch_provider_request(verifier_provider, request_json, function(response, error_message)
				if error_message ~= nil then
					log.preview_text("verifier request error", error_message)
					verify_next()
					return
				end

				if response == nil then
					log.debug("verifier request returned nil response without explicit error")
					verify_next()
					return
				end

				local raw_text = verifier_provider.extract_text and verifier_provider.extract_text(response) or ""
				local decision, parse_error_text = parse_verifier_decision(raw_text)
				if decision == nil then
					log.preview_text("verifier response rejected as non-strict", parse_error_text, 800)
					verify_next()
					return
				end

				if decision.status == "empty" then
					log.debug("verifier returned empty response")
					verify_next()
					return
				end

				if decision.status == "rejected" or decision.status == "insufficient_evidence" then
					log.debug("verifier decision: " .. decision.status)
					verify_next()
					return
				end

				local parse_ok, diagnostics = pcall(review_parser.parse_text, decision.finding, metadata.buffer_path)

				if not parse_ok then
					log.debug_table("verifier response parse failure", response)
					verify_next()
					return
				end

				local normalized_diagnostics = normalize_with_logging(diagnostics, "verifier response")
				local filtered_diagnostics = filter_weak_findings(normalized_diagnostics, "verifier response")
				append_diagnostics(filtered_diagnostics)
				verify_next()
			end)
		end

		verify_next()
	end

	local function finish()
		progress.stop()

		vim.schedule(function()
			local current_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(utils.get_buffer_number()), ":p")
			local current_root = context_engine.find_repo_root(current_path)
			local current_count = 0
			local other_count = 0

			for _, diag in ipairs(aggregated) do
				local target = diag.absolute_path or diag.file or current_path
				local path = target

				if type(target) == "string" and target ~= "" and not target:find("^/") then
					local base_root = metadata.repo_root or current_root or vim.fn.getcwd()
					path = base_root .. "/" .. target
				end

				if vim.fn.fnamemodify(path, ":p") == current_path then
					current_count = current_count + 1
				else
					other_count = other_count + 1
				end
			end

			local review, error_message = review_store.create_review(metadata, aggregated)
			if review == nil then
				log.event(
					"error",
					"review persistence failed",
					"Pitaco review persistence failed: " .. tostring(error_message),
					false
				)
				project_immediate_diagnostics(namespace, aggregated, metadata.repo_root)
				return
			end

			project_immediate_diagnostics(namespace, aggregated, metadata.repo_root)

			local activated, activate_error = review_renderer.activate_review(review)
			if not activated then
				log.event(
					"warn",
					"review activation failed",
					"Pitaco review activation failed: " .. tostring(activate_error),
					false
				)
			end

			if #aggregated > 0 then
				local parts = {}
				if current_count > 0 then
					table.insert(parts, ("%d in current file"):format(current_count))
				end
				if other_count > 0 then
					table.insert(parts, ("%d in other files"):format(other_count))
				end
				log.event("info", "review diagnostics summary", "Pitaco diagnostics: " .. table.concat(parts, ", "), false)
			else
				log.event("info", "review diagnostics summary", "Pitaco review completed with no findings", false)
			end
		end)
	end

	local function process_next()
		if #requests == 0 then
			local merged_candidates = dedupe_candidates(reviewer_candidates)
			run_verifier_stage(merged_candidates, finish)
			return
		end

		local request_json = table.remove(requests, 1)
		request_index = request_index + 1

		log.debug(
			("Dispatching analysis request %d/%d via provider '%s'"):format(
				request_index,
				starting_request_count,
				provider.name or "unknown"
			)
		)
		log.preview_json("analysis request payload", request_json)

		progress.update(progress_message(metadata, request_index, starting_request_count), request_index, starting_request_count)

		dispatch_provider_request(provider, request_json, function(response, error_message)
			if error_message ~= nil then
				log.preview_text("analysis request error", error_message)
				log.event("error", "analysis request failure", error_message, false)
				progress.stop()
				return
			end

			if response == nil then
				log.debug("analysis request returned nil response without explicit error")
				progress.stop()
				return
			end

			local parse_ok, diagnostics = pcall(provider.parse_response, response, metadata.buffer_path)

			if not parse_ok then
				log.debug_table("analysis response parse failure", response)
				log.event("error", "analysis response parse failure", "Failed to parse response", false)
				progress.stop()
				return
			end

			local normalized_diagnostics = normalize_with_logging(diagnostics, "reviewer response")
			local filtered_candidates = filter_weak_findings(normalized_diagnostics, "reviewer response")
			append_candidates(filtered_candidates)
			process_next()
		end)
	end

	process_next()
end

return M
