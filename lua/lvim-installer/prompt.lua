-- lvim-installer: the unified install prompt.
-- On a filetype's first open it gathers every missing item from lvim-pkg (LSP
-- tools + treesitter parsers, contributed by lvim-lsp / lvim-ts) and offers them
-- in a tabbed view grouped by category (LSP / DAP / Linter / Formatter /
-- Treesitter), one checkbox per item.  Footer buttons — [a]ll / [s]elected /
-- [c]ancel, fired by their key — install all or only the checked items; the rest
-- of the unchecked Mason tools are declined; skipping (Cancel / q / <Esc>) snoozes.
--
---@module "lvim-installer.prompt"

local state = require("lvim-installer.state")

local pkg = require("lvim-pkg")
local registry = require("lvim-pkg.registry")
local config = require("lvim-installer.config")
local progress = require("lvim-installer.progress")
local ui_mod = require("lvim-installer.ui")
local M = {}

--- Category tabs, in display order. `id` matches the Mason registry category,
--- except "parser" which groups every kind == "parser" item.
local CATS = {
	{ id = "LSP", label = "LSP", icon = "" },
	{ id = "DAP", label = "DAP", icon = "" },
	{ id = "Linter", label = "Linter", icon = "" },
	{ id = "Formatter", label = "Formatter", icon = "" },
	{ id = "parser", label = "Treesitter", icon = "" },
}

--- Resolve which tab an item belongs to (its first matching registry category,
--- or LSP as a fallback for uncategorised Mason tools).
---@param item table  LvimPkgItem (kind = "mason" | "parser")
---@return string  category id
local function category_of(item)
	if item.kind == "parser" then
		return "parser"
	end
	local spec = registry.get(item.name)
	local cats = (spec and spec.categories) or {}
	for _, c in ipairs({ "LSP", "DAP", "Linter", "Formatter" }) do
		if vim.tbl_contains(cats, c) then
			return c
		end
	end
	return "LSP"
end

---@type table<string, boolean>  Filetypes queued for the next flush
local pending = {}
local scheduled = false

--- Queue `ft` for an install prompt, debounced and snooze-aware.
---@param ft string
---@return nil
function M.offer(ft)
	if not ft or ft == "" then
		return
	end
	local snooze = state.snoozed[ft]
	if snooze and vim.uv.now() < snooze then
		return
	end
	pending[ft] = true
	if not scheduled then
		scheduled = true
		vim.defer_fn(function()
			scheduled = false
			M.flush()
		end, 300)
	end
end

--- Open one prompt per pending filetype.
---@return nil
function M.flush()
	local fts = vim.tbl_keys(pending)
	pending = {}
	table.sort(fts)
	for _, ft in ipairs(fts) do
		M.show(ft)
	end
end

--- Show the unified tabbed prompt for a single filetype.
---@param ft string
---@return nil
function M.show(ft)
	local items = pkg.missing_for_ft(ft)
	if #items == 0 then
		return
	end
	local ui = ui_mod.get()
	if not ui then
		return
	end

	-- Bucket the missing items into category tabs.
	local buckets = {}
	for _, item in ipairs(items) do
		local cat = category_of(item)
		buckets[cat] = buckets[cat] or {}
		table.insert(buckets[cat], item)
	end

	-- Captured checkbox rows (the widget toggles row.value in place) → their item.
	local picks = {}

	-- Install the checked (or, when `all`, every) item and dismiss.  The skipped
	-- ones — unchecked on [s]elected — are offered to the decline prompt.
	local function install(all)
		return function(close)
			close(true)
			local chosen, skipped = {}, {}
			for _, p in ipairs(picks) do
				if all or p.row.value then
					chosen[p.item] = true
				else
					skipped[#skipped + 1] = p.item
				end
			end
			M.run_install(items, chosen)
			if #skipped > 0 then
				M.ask_decline(ft, skipped)
			end
		end
	end

	-- One tab per non-empty category, in display order.
	local tabs = {}
	for _, cat in ipairs(CATS) do
		local bucket = buckets[cat.id]
		if bucket and #bucket > 0 then
			local rows = {}
			for _, item in ipairs(bucket) do
				local row = { type = "bool", name = item.name, label = item.label or item.name, value = true }
				table.insert(rows, row)
				table.insert(picks, { row = row, item = item })
			end
			table.insert(tabs, { label = cat.label, icon = cat.icon, rows = rows })
		end
	end

	ui.tabs({
		title = config.prompt.title_icon .. "Install for " .. ft,
		tabs = tabs,
		-- Footer shows only these action buttons, in order (no default nav hints).
		footer_hints = {
			{ key = "a", label = "All" },
			{ key = "s", label = "Selected" },
			{ key = "c", label = "Cancel" },
		},
		-- Their key bindings (fired from anywhere, no navigation needed).
		keymaps = {
			a = { fn = install(true) },
			s = { fn = install(false) },
			-- Cancel installs nothing and offers every item to the decline prompt.
			c = {
				fn = function(close)
					close(true)
					M.ask_decline(ft, items)
				end,
			},
		},
		-- Quick-dismissed with q / <Esc> (not a button): just snooze the ft.
		callback = function(confirmed)
			if not confirmed then
				state.snoozed[ft] = vim.uv.now() + config.prompt.snooze_ms
			end
		end,
	})
end

--- Second prompt (replaces the first): the skipped items were not installed —
--- offer to remember the decline for this filetype, or snooze.
---@param ft      string
---@param skipped table[]  Items that were not installed
---@return nil
function M.ask_decline(ft, skipped)
	local ui = ui_mod.get()
	if not ui then
		return
	end
	local names = {}
	for _, item in ipairs(skipped) do
		names[#names + 1] = item.name
	end
	ui.select({
		title = config.prompt.title_icon .. "Skipped for " .. ft,
		subtitle = table.concat(names, ", "),
		items = { "Don't ask again", "Ask later" },
		callback = function(confirmed, index)
			if confirmed and index == 1 then
				-- Persist the decline so missing_for_ft stops offering these.
				pkg.decline(ft, names)
			else
				-- "Ask later" or dismissed: snooze the ft (temporary).
				state.snoozed[ft] = vim.uv.now() + config.prompt.snooze_ms
			end
		end,
	})
end

--- Install the chosen items, grouped by backend kind. Skipped items are handled
--- separately by the decline prompt, not here.
---@param all    table[]                  Every offered item
---@param chosen table<table, boolean>    item → install?
---@return nil
function M.run_install(all, chosen)
	local by_kind = {}
	for _, item in ipairs(all) do
		if chosen[item] then
			by_kind[item.kind] = by_kind[item.kind] or {}
			table.insert(by_kind[item.kind], item.name)
		end
	end

	if by_kind.parser then
		pkg.install("parser", by_kind.parser, function(err)
			if err then
				return
			end
			-- Parsers are installed now; enable treesitter on open buffers (lvim-ts
			-- runs with auto_install off when the prompt is in charge).
			pcall(function()
				local ts = require("lvim-ts.core.manager")
				for _, buf in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_loaded(buf) then
						ts.activate(buf)
					end
				end
			end)
		end)
	end

	if by_kind.mason then
		progress.start(by_kind.mason)
		-- Suppress lvim-lsp prompts/starts while installing.
		pcall(function()
			pkg.emit("installing", true)
		end)
		pkg.install("mason", by_kind.mason, function(results)
			progress.done(results)
			-- Re-check deps and (re)attach servers whose tools are now present.
			pcall(function()
				pkg.emit("installing", false)
			end)
		end, {
			on_progress = function(name, status, action)
				progress.update(name, status, action)
			end,
		})
	end
end

return M
