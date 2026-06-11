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
			local which = args[2] or "all"
			pkg.update_registry(which, function()
				vim.notify("Registry refreshed (" .. which .. ").", vim.log.levels.INFO)
			end, true)
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
				return starts({ "mason", "ts", "all" })
			end
			return starts({ "lsp", "dap", "linter", "formatter", "parsers", "plugins", "update-registry" })
		end,
		desc = "Open the lvim package manager / update-registry [mason|ts|all]",
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
