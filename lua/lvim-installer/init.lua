-- lvim-installer: public API entry point — the UI layer of the ecosystem.
-- Owns the unified install prompt (offered on a filetype's first open) and the
-- package manager window (:LvimInstaller).  All data and install operations are
-- delegated to lvim-pkg; lvim-installer only renders and orchestrates.
--
---@module "lvim-installer"

local pkg = require("lvim-pkg")
local config = require("lvim-installer.config")
local utils = require("lvim-utils.utils")
local highlights = require("lvim-installer.highlights")
local prompt = require("lvim-installer.prompt")
local browser = require("lvim-installer.browser")
local progress = require("lvim-installer.progress")

local M = {}

--- Configure lvim-installer: register the unified prompt and the :LvimInstaller
--- command that opens the package manager.
---@param opts? LvimInstallerConfig
---@return nil
function M.setup(opts)
	-- Merge user overrides into the live config (in place, so require()ers see them).
	utils.merge(config, opts)

	-- Register the named highlight groups (theme-overridable, default-linked).
	highlights.setup()

	-- Offer missing installs (LSP tools + parsers) when a filetype is first seen.
	vim.api.nvim_create_autocmd("FileType", {
		desc = "Offer missing LSP/parser installs (unified prompt)",
		group = vim.api.nvim_create_augroup("lvim_installer", { clear = true }),
		callback = function(args)
			prompt.offer(vim.bo[args.buf].filetype)
		end,
	})

	-- Cover buffers already loaded before the autocmd was registered.
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local ft = vim.bo[buf].filetype
			if ft ~= "" then
				prompt.offer(ft)
			end
		end
	end

	-- :LvimInstaller [lsp|dap|linter|formatter|parsers|plugins] — open the manager at a
	-- specific tab. :LvimInstaller update-registry [mason|ts|all] — force-refresh a
	-- registry catalogue now (ignoring the TTL).
	vim.api.nvim_create_user_command("LvimInstaller", function(cmd)
		local args = cmd.fargs
		if args[1] == "update-registry" then
			M.update_registry(args[2] or "all")
			return
		end
		if args[1] == "snapshot" then
			if args[2] == "save" then
				require("lvim-installer.snapshot").save(args[3])
			else
				require("lvim-installer.snapshot").open()
			end
			return
		end
		local map = {
			lsp = "LSP",
			dap = "DAP",
			linter = "Linter",
			formatter = "Formatter",
			parsers = "parser",
			plugins = "plugin",
		}
		M.open(map[args[1]] or nil)
	end, {
		nargs = "*",
		complete = function(arglead, line)
			local words = vim.split(vim.trim(line), "%s+")
			local function starts(list)
				return vim.tbl_filter(function(x)
					return x:find(arglead, 1, true) == 1
				end, list)
			end
			if words[2] == "update-registry" then
				return starts({ "mason", "ts", "plugin", "all" })
			end
			if words[2] == "snapshot" then
				return starts({ "save" })
			end
			return starts({ "lsp", "dap", "linter", "formatter", "parsers", "plugins", "snapshot", "update-registry" })
		end,
		desc = "Open the lvim package manager / snapshot / update-registry [mason|ts|plugin|all]",
	})

	-- ensure_installed: silently install the configured Mason tools (allowlist) at setup.
	if config.ensure_installed and #config.ensure_installed > 0 then
		local todo = {}
		for _, name in ipairs(config.ensure_installed) do
			if not pkg.is_installed("mason", name) then
				todo[#todo + 1] = name
			end
		end
		if #todo > 0 then
			pkg.install("mason", todo, function() end)
		end
	end
end

--- Refresh registries and recompute state, shown through the install progress panel.
--- Catalogues (Mason / parser) are re-downloaded to our local files; plugin and parser
--- update checks are then run so the "update" markers reflect the fresh data. `which` is
--- one of mason | ts | plugin | all. Plugins have no upstream catalogue — their phase is
--- the git outdated check; Mason's "outdated" is recomputed from the refreshed catalogue
--- on re-render, so it needs no separate check.
---@param which? string
---@return nil
function M.update_registry(which)
	which = which or "all"
	local do_mason = which == "mason" or which == "all"
	local do_ts = which == "ts" or which == "all"
	local do_plugin = which == "plugin" or which == "all"

	local phases = {}
	if do_mason then
		phases[#phases + 1] = "Mason registry"
	end
	if do_ts then
		phases[#phases + 1] = "Parser registry"
	end
	if do_plugin then
		phases[#phases + 1] = "Plugin updates"
	end
	if do_ts then
		phases[#phases + 1] = "Parser updates"
	end
	if #phases == 0 then
		return
	end

	progress.start(phases)
	local results, steps = {}, {}

	local function run(i)
		local step = steps[i]
		if not step then
			progress.done(results, "Registries updated (" .. which .. ")")
			browser.refresh_open()
			return
		end
		step(function()
			run(i + 1)
		end)
	end

	-- Re-download a catalogue (Mason / parser) to our local registry file.
	local function catalogue_step(phase, kind)
		steps[#steps + 1] = function(cont)
			progress.update(phase, "pending", "Downloading\xe2\x80\xa6")
			pkg.update_registry(kind, function()
				progress.update(phase, "ok", "Updated")
				results[phase] = true
				browser.refresh_open()
				cont()
			end, true)
		end
	end

	-- Run an outdated check (plugin / parser), reflecting its done/total as the action.
	local function check_step(phase, fn)
		steps[#steps + 1] = function(cont)
			progress.update(phase, "pending", "Checking\xe2\x80\xa6")
			fn(function(found)
				progress.update(phase, "ok", string.format("%d outdated", #found))
				results[phase] = true
				browser.refresh_open()
				cont()
			end, function(done, total)
				progress.update(phase, "pending", string.format("%d/%d", done, total))
			end)
		end
	end

	if do_mason then
		catalogue_step("Mason registry", "mason")
	end
	if do_ts then
		catalogue_step("Parser registry", "ts")
	end
	if do_plugin then
		check_step("Plugin updates", pkg.check_outdated)
	end
	if do_ts then
		check_step("Parser updates", pkg.check_parsers_outdated)
	end

	run(1)
end

--- Manually offer the unified prompt for `ft` (defaults to the current buffer).
---@param ft? string
---@return nil
function M.offer(ft)
	prompt.offer(ft or vim.bo.filetype)
end

--- Open the package manager window at a specific tab.
---@param tab? "LSP"|"DAP"|"Linter"|"Formatter"|"parser"|"plugin"  Initial tab
---@return nil
function M.open(tab)
	browser.open(tab)
end

return M
