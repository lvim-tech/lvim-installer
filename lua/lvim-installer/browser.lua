-- lvim-installer: the package manager — a dedicated tabs window.
-- Its own lvim-utils popup (separate from lvim-control-center, so it never mixes
-- with the settings tabs).  Tabs mirror how Mason organises things — one per
-- category (LSP / DAP / Linter / Formatter) plus Treesitter (parsers) and Plugins
-- (vim.pack).  Each item row opens an action submenu (install / update / remove /
-- pin); filtering and actions reopen this window only.
--
---@module "lvim-installer.browser"

local pkg = require("lvim-pkg")
local registry = require("lvim-pkg.registry")
local purl = require("lvim-pkg.registry.purl")
local pkg_paths = require("lvim-pkg.paths")
local config = require("lvim-installer.config")
local progress = require("lvim-installer.progress")
local ui_mod = require("lvim-installer.ui")
local M = {}

--- Tab definitions.  Mason tabs filter the registry by category; parser/plugin
--- tabs read their own backends.
---@type table[]
local TABS = {
	{ id = "plugin", kind = "plugin", label = "Plugins", icon = "" },
	{ id = "parser", kind = "parser", label = "Treesitter", icon = "" },
	{ id = "LSP", kind = "mason", category = "LSP", label = "LSP", icon = "" },
	{ id = "DAP", kind = "mason", category = "DAP", label = "DAP", icon = "" },
	{ id = "Linter", kind = "mason", category = "Linter", label = "Linter", icon = "" },
	{ id = "Formatter", kind = "mason", category = "Formatter", label = "Formatter", icon = "" },
	{ id = "snapshot", kind = "snapshot", label = "Snapshots", icon = "" },
}

-- Browse state (persists across the close/reopen cycle).
-- `expanded` holds plugin names whose inline detail is unfolded.
local state = { filter = "", filter_mode = "All", active = "plugin", pending = nil, expanded = {}, git_expanded = {} }

--- Build the item list for a tab, each with its kind and installed status.
---@param tab table
---@return table[]
local function build_items(tab)
	local items = {}
	if tab.kind == "mason" then
		-- Registry data only (package info + install method); version from our own
		-- install receipt. No dependency on the mason.nvim plugin.
		for _, spec in ipairs(registry.all()) do
			if vim.tbl_contains(spec.categories or {}, tab.category) then
				local installed = pkg.is_installed("mason", spec.name)
				items[#items + 1] = {
					name = spec.name,
					kind = "mason",
					desc = spec.description or "",
					installed = installed,
					spec = spec,
					version = installed and pkg.installed_version(spec.name) or nil,
					pinned = pkg.get_pin("mason", spec.name),
				}
			end
		end
	elseif tab.kind == "parser" then
		local installed = {}
		for _, lang in ipairs(pkg.installed("parser")) do
			installed[lang] = true
		end
		for _, lang in ipairs(pkg.available("parser")) do
			items[#items + 1] = { name = lang, kind = "parser", desc = "", installed = installed[lang] }
		end
	elseif tab.kind == "plugin" then
		-- Rich, lazy.nvim-style data straight from lvim-pkg (load time, reason,
		-- path, source, version, triggers, deps, outdated). Pins fetched in one query.
		local pins = pkg.pins_full("plugin")
		for _, info in ipairs(pkg.plugins()) do
			items[#items + 1] = {
				name = info.name,
				kind = "plugin",
				installed = true,
				loaded = info.loaded,
				info = info,
				pin = pins[info.name],
			}
		end
	end
	table.sort(items, function(a, b)
		return a.name < b.name
	end)
	return items
end

-- Status glyph + highlight groups for a plugin by state. Geometric circles render
-- in any font; the colours come from theme-overridable groups.
---@param info table
---@return string icon, string icon_hl
local function plugin_style(info)
	if info.outdated then
		return "●", "LvimInstallerStatusOutdated"
	elseif info.loaded then
		return "●", "LvimInstallerStatusLoaded"
	end
	return "○", "LvimInstallerStatusLazy"
end

-- Plugin row text: name in a fixed column, then load time and/or update marker.
---@param info table
---@param pin table|nil  the stored convention { version, reftype, branch }, or nil
---@return string
local function plugin_label(info, pin)
	local parts = {}
	if info.loaded and info.time_ms then
		parts[#parts + 1] = string.format("%.2f ms", info.time_ms)
	end
	if info.dependency then
		parts[#parts + 1] = "dep"
	end
	if pin then
		parts[#parts + 1] = "󰐃 pinned"
	end
	if info.outdated then
		parts[#parts + 1] = "update"
	end
	return table.concat(parts, "    ")
end

-- Per-action icon for the inline action rows (4-space indent baked in).
local ACTION_ICON = { Update = "󰑐", Remove = "󰆴", ["Open source URL"] = "󰏌" }

-- Per-field icons for the inline detail rows.
local FIELD_ICON = {
	Status = "󰑐",
	State = "󰋼",
	["Load time"] = "󰅐",
	Reason = "󰉁",
	Source = "󰘬",
	Path = "󰉋",
	Version = "󰓹",
	Priority = "󰅃",
	Outdated = "󰑐",
	Triggers = "󰉁",
	Deps = "󰌹",
	["Required by"] = "󰌹",
	-- Mason package fields
	Installed = "󰓹",
	Latest = "󰚰",
	Purl = "󰏖",
	Description = "󰈙",
	Homepage = "󰏌",
	Languages = "󰗊",
	Categories = "󰓻",
	Executables = "󰆍",
	Pinned = "󰐃",
	Tracking = "󰊢",
}

-- Pad an icon to a fixed display width so every row's text starts at the same column.
local ICON_W = 2
local function cell(glyph)
	glyph = glyph or ""
	return glyph .. string.rep(" ", math.max(0, ICON_W - vim.fn.strdisplaywidth(glyph)))
end

-- Segmented filter modes shown as the top toolbar bar.
local FILTER_MODES = { "All", "Loaded", "Lazy", "Deps", "Outdated", "Up-to-date", "Search" }

--- Whether a plugin item passes the active filter mode (and search text).
---@param item table
---@return boolean
local function passes_filter(item)
	local mode = state.filter_mode or "All"
	local info = item.info
	if mode == "Loaded" then
		return info.loaded == true
	elseif mode == "Lazy" then
		return not info.loaded
	elseif mode == "Deps" then
		return info.dependency == true
	elseif mode == "Outdated" then
		return info.outdated == true
	elseif mode == "Up-to-date" then
		return not info.outdated
	elseif mode == "Search" then
		local f = (state.filter or ""):lower()
		return f == "" or item.name:lower():find(f, 1, true) ~= nil
	end
	return true
end

--- Detail fields for a plugin as { field, value } pairs (rendered as inline rows).
---@param info table
---@param pin table|nil  the stored convention { version, reftype, branch }, or nil
---@return table[]
local function plugin_detail_fields(info, pin)
	local state = info.loaded and ("loaded \xc2\xb7 " .. (info.lazy and "lazy" or "eager"))
		or "not loaded \xc2\xb7 lazy"
	local f = { { "State", state } }
	if info.time_ms then
		f[#f + 1] = { "Load time", string.format("%.2f ms", info.time_ms) }
	end
	f[#f + 1] = { "Reason", tostring(info.reason) }
	if info.dependency and info.dep_of then
		f[#f + 1] = { "Required by", tostring(info.dep_of) }
	end
	f[#f + 1] = { "Source", tostring(info.src or "-") }
	f[#f + 1] = { "Path", tostring(info.path or "-") }
	local vparts = {}
	if info.branch and info.branch ~= "" then
		vparts[#vparts + 1] = "Branch [" .. info.branch .. "]"
	end
	if info.tag and info.tag ~= "" then
		vparts[#vparts + 1] = "Tag [" .. info.tag .. "]"
	end
	if info.commit and info.commit ~= "" then
		vparts[#vparts + 1] = "Commit [" .. info.commit .. "]"
	end
	if #vparts > 0 then
		f[#f + 1] = { "Version", table.concat(vparts, "  ") }
	end
	-- Installation principle. No pin → "Latest commit" (follows the default branch).
	-- Capitalised to match the Version field ("Tag […] Commit […]").
	local track
	if not pin then
		track = "Latest commit"
	elseif pin.reftype == "branch" then
		track = "Branch → " .. tostring(pin.version)
	elseif pin.reftype == "tag" then
		track = pin.branch and ("Tag → " .. pin.branch .. ".x  (= " .. tostring(pin.version) .. ")")
			or ("Tag → " .. tostring(pin.version))
	elseif pin.reftype == "commit" then
		track = "Commit → " .. tostring(pin.version)
	else
		track = "Latest commit"
	end
	f[#f + 1] = { "Tracking", track }
	if info.priority then
		f[#f + 1] = { "Priority", tostring(info.priority) }
	end
	f[#f + 1] = { "Status", info.outdated and "outdated" or "up to date" }
	if info.triggers and #info.triggers > 0 then
		f[#f + 1] = { "Triggers", table.concat(info.triggers, ", ") }
	end
	if info.dependencies and #info.dependencies > 0 then
		f[#f + 1] = { "Deps", table.concat(info.dependencies, ", ") }
	end
	return f
end

--- Install or update one item, then reopen the browser.
---@param item table
---@param is_update boolean
local function run_op(item, is_update)
	local op = is_update and "update" or "install"
	if item.kind == "mason" then
		progress.start({ item.name })
		pkg[op](item.kind, { item.name }, function(results)
			progress.done(results)
			M.open()
		end, {
			on_progress = function(name, status, action)
				progress.update(name, status, action)
			end,
		})
	else
		pkg[op](item.kind, { item.name }, function()
			M.open()
		end)
	end
end

--- Open the per-item action submenu, then reopen the browser.
---@param item table
local function item_submenu(item)
	local ui = ui_mod.get()
	if not ui then
		return
	end
	local actions = item.installed and { "Update", "Remove", "Pin version…" } or { "Install", "Pin version…" }
	if pkg.get_pin(item.kind, item.name) then
		actions[#actions + 1] = "Unpin"
	end
	ui.select({
		title = item.name,
		items = actions,
		callback = function(confirmed, idx)
			-- select's callback gives the 1-based index, not the label.
			local choice = idx and actions[idx]
			if not confirmed or not choice then
				M.open()
				return
			end
			if choice == "Install" or choice == "Update" then
				run_op(item, choice == "Update")
			elseif choice == "Remove" then
				pkg.remove(item.kind, { item.name }, function()
					M.open()
				end)
			elseif choice == "Unpin" then
				pkg.unpin(item.kind, item.name)
				M.open()
			elseif choice == "Pin version…" then
				vim.ui.input({
					prompt = "Pin " .. item.name .. " to version/commit: ",
					default = pkg.get_pin(item.kind, item.name) or "",
				}, function(version)
					if version and version ~= "" then
						pkg.pin(item.kind, item.name, version)
						run_op(item, true)
					else
						M.open()
					end
				end)
			else
				M.open()
			end
		end,
	})
end

--- An item action row.
---@param tab  table
---@param item table
---@return table
local function item_row(tab, item)
	local pin = pkg.get_pin(item.kind, item.name)
	local icon = item.installed and "" or ""
	return {
		type = "action",
		name = "item_" .. item.name,
		label = string.format("%s %s%s", icon, item.name, pin and ("  [" .. pin .. "]") or ""),
		desc = item.desc,
		run = function(_, close)
			state.active = tab.id
			state.pending = function()
				item_submenu(item)
			end
			if close then
				close()
			end
		end,
	}
end

--- Reinstall flow: chained dropdowns over fresh refs. Stores the full convention.
--- The current choice is pre-selected (marked by the ➤ cursor, no extra text), and
--- each step (except the first) maps Backspace to go back one level (footer hint).
---@param name string
---@param info table
local function reinstall_menu(name, info)
	local ui = ui_mod.get()
	if not ui then
		return
	end
	vim.notify("Fetching refs for " .. name .. "\xe2\x80\xa6")
	pkg.plugin_fetch(name, function()
		local pin = pkg.get_pin_full("plugin", name)
		local git = pkg.plugin_current(name)
		local rt = (pin and pin.reftype) or (git and git.kind)
		local val = (pin and pin.version) or (git and git.value)
		local ctx = pin and pin.branch or nil
		local cur_branch = (rt == "branch" and val) or (rt == "commit" and ctx) or nil
		local cur_commit = (rt == "commit") and val or nil
		local cur_tag = (rt == "tag") and val or nil
		local cur_conv = (rt == "tag") and ctx or nil

		-- Tracking the default branch's tip == "follow latest", so it clears the pin
		-- rather than recording one. Any other choice (tag, commit, non-default branch)
		-- is an explicit pin.
		local default_branch = pkg.plugin_default_branch(name)

		local function finish(ref, conv)
			local err = pkg.plugin_checkout(name, ref)
			if err then
				vim.notify("Checkout failed for " .. name .. ": " .. err, vim.log.levels.ERROR)
			else
				if conv.reftype == "branch" and conv.branch == default_branch then
					pkg.unpin("plugin", name)
				else
					pkg.pin("plugin", name, conv.version, conv.reftype, conv.branch)
				end
				vim.notify(name .. " \xe2\x86\x92 " .. ref)
			end
			M.refresh_open()
		end

		local approach_menu, branch_flow, tag_flow

		function branch_flow()
			local default = pkg.plugin_default_branch(name)
			local items, vals, sel = {}, {}, nil
			local function add(b, is_default)
				local it = b .. (is_default and "  (default)" or "")
				items[#items + 1] = it
				vals[#vals + 1] = b
				if cur_branch == b then
					sel = it
				end
			end
			if default then
				add(default, true)
			end
			for _, b in ipairs(pkg.plugin_branches(name)) do
				if b ~= default then
					add(b, false)
				end
			end
			if #items == 0 then
				vim.notify("No branches for " .. name)
				return
			end
			ui.select({
				title = name .. " \xe2\x80\x94 branch",
				items = items,
				current_item = sel,
				back_key = "<BS>",
				on_back = approach_menu,
				callback = function(c, i)
					if not (c and vals[i]) then
						return
					end
					local branch = vals[i]
					local citems, cvals, csel = {}, {}, nil
					local litem = "Latest  (tip of " .. branch .. ")"
					citems[1], cvals[1] = litem, false
					if rt == "branch" and val == branch then
						csel = litem
					end
					for _, line in ipairs(pkg.plugin_commits(name, branch)) do
						local sha = line:match("^(%S+)")
						citems[#citems + 1] = line
						cvals[#cvals + 1] = sha
						if cur_commit == sha then
							csel = line
						end
					end
					ui.select({
						title = name .. " \xe2\x80\x94 commit on " .. branch,
						items = citems,
						current_item = csel,
						back_key = "<BS>",
						on_back = branch_flow,
						callback = function(c2, j)
							if not c2 then
								return
							end
							if cvals[j] == false then
								finish(branch, { reftype = "branch", version = branch, branch = branch })
							elseif cvals[j] then
								finish(cvals[j], { reftype = "commit", version = cvals[j], branch = branch })
							end
						end,
					})
				end,
			})
		end

		function tag_flow()
			local tags = pkg.plugin_tags(name)
			local tsel = nil
			for _, t in ipairs(tags) do
				if cur_tag == t then
					tsel = t
				end
			end
			ui.select({
				title = name .. " \xe2\x80\x94 tag",
				items = tags,
				current_item = tsel,
				back_key = "<BS>",
				on_back = approach_menu,
				callback = function(c, i)
					if not (c and tags[i]) then
						return
					end
					local picked = tags[i]
					local v = tostring(picked):gsub("^v", "")
					local parts = (v:match("^%d[%d%.]*%d$") or v:match("^%d$")) and vim.split(v, ".", { plain = true })
						or nil
					if not (parts and #parts >= 2) then
						finish(picked, { reftype = "tag", version = picked, branch = nil })
						return
					end
					local labels, ress, prefixes, isc, lw, rw = {}, {}, {}, {}, 0, 0
					for lvl = 1, #parts do
						local prefix = table.concat(vim.list_slice(parts, 1, lvl), ".")
						local resolved = pkg.plugin_resolve_tag(name, prefix)
						local is_cur = (cur_conv and prefix == cur_conv)
							or (not cur_conv and lvl == #parts and cur_tag == picked)
						local label = (lvl < #parts) and ("Newest " .. prefix .. ".x") or ("Exact " .. picked)
						local res = (lvl < #parts) and ("= " .. tostring(resolved)) or ""
						lw = math.max(lw, #label)
						rw = math.max(rw, #res)
						labels[#labels + 1] = label
						ress[#ress + 1] = res
						prefixes[#prefixes + 1] = prefix
						isc[#isc + 1] = is_cur
					end
					local items, lsel = {}, nil
					for k2 = 1, #labels do
						local line = (
							string.format("%-" .. lw .. "s   %-" .. rw .. "s", labels[k2], ress[k2]):gsub("%s+$", "")
						)
						items[#items + 1] = line
						if isc[k2] then
							lsel = line
						end
					end
					ui.select({
						title = picked .. " \xe2\x80\x94 lock level",
						items = items,
						current_item = lsel,
						back_key = "<BS>",
						on_back = tag_flow,
						callback = function(c2, j)
							if not (c2 and prefixes[j]) then
								return
							end
							local resolved = pkg.plugin_resolve_tag(name, prefixes[j]) or picked
							local lock = (j < #prefixes) and prefixes[j] or nil
							finish(resolved, { reftype = "tag", version = resolved, branch = lock })
						end,
					})
				end,
			})
		end

		function approach_menu()
			local b_it, t_it = "Branch + commit", "Tag"
			ui.select({
				title = "Reinstall " .. name .. " \xe2\x80\x94 by",
				items = { b_it, t_it },
				current_item = (rt == "branch" or rt == "commit") and b_it or ((rt == "tag") and t_it or nil),
				callback = function(c, i)
					if not c then
						return
					end
					if i == 1 then
						branch_flow()
					else
						tag_flow()
					end
				end,
			})
		end

		if #pkg.plugin_tags(name) > 0 then
			approach_menu()
		else
			branch_flow()
		end
	end)
end

--- Update a plugin per its stored convention (reftype). Branch → advance to tip;
--- tag lock → newest tag in the prefix; exact tag / fixed commit → frozen. No pin →
--- live git state (branch advances; detached is frozen).
---@param name string
---@param info table
local function update_action(name, info)
	vim.notify("Checking " .. name .. " for updates\xe2\x80\xa6")
	pkg.plugin_fetch(name, function()
		local pin = pkg.get_pin_full("plugin", name)
		if not pin then
			return
		end
		local rt = pin.reftype
		if rt == "tag" and pin.branch then
			local newest = pkg.plugin_resolve_tag(name, pin.branch)
			local cur = pkg.plugin_current(name)
			if newest and (not cur or cur.value ~= newest) then
				local err = pkg.plugin_checkout(name, newest)
				if err then
					vim.notify("Update failed for " .. name .. ": " .. err, vim.log.levels.ERROR)
				else
					pkg.pin("plugin", name, newest, "tag", pin.branch)
					vim.notify(name .. " \xe2\x86\x92 " .. newest .. " (newest " .. pin.branch .. ".x)")
				end
				M.refresh_open()
			else
				vim.notify(name .. ": already newest in " .. pin.branch .. ".x")
			end
			return
		elseif rt == "branch" then
			local err = pkg.plugin_update_branch(name, pin.version)
			if err then
				vim.notify("Update failed for " .. name .. ": " .. err, vim.log.levels.ERROR)
			else
				pkg.pin("plugin", name, pin.version, "branch", pin.version)
				vim.notify(name .. ": " .. pin.version .. " updated to tip")
			end
			M.refresh_open()
			return
		elseif rt == "tag" or rt == "commit" then
			vim.notify(name .. " is fixed (" .. rt .. " " .. tostring(pin.version) .. ") \xe2\x80\x94 use Reinstall")
			return
		end
		-- No stored convention → live git state.
		local cur = pkg.plugin_current(name)
		if cur and cur.kind == "branch" then
			local err = pkg.plugin_update_branch(name, cur.value)
			if not err then
				vim.notify(name .. ": " .. cur.value .. " updated to tip")
			end
			M.refresh_open()
		elseif cur and cur.kind == "commit" then
			-- Un-pinned commit → advance on the default branch.
			local default = pkg.plugin_default_branch(name)
			if default then
				local err = pkg.plugin_update_branch(name, default)
				if not err then
					vim.notify(name .. ": advanced on " .. default)
				end
				M.refresh_open()
			else
				vim.notify(name .. ": no default branch to advance")
			end
		else
			vim.notify(name .. " is on a fixed tag \xe2\x80\x94 use Reinstall to change")
		end
	end)
end

--- Pin menu for a Mason package: a dropdown of available versions (registry latest
--- + version_overrides); picking pins + reinstalls that version.
---@param name string
local function mason_pin_menu(name)
	local ui = ui_mod.get()
	if not ui then
		return
	end
	-- The registry pins one version — use it for the "Latest (…)" label and as the
	-- fallback when the source query fails.
	local registry_latest
	for _, sp in ipairs(registry.all()) do
		if sp.name == name and sp.source then
			registry_latest = (purl.parse(sp.source.id) or {}).version
			break
		end
	end

	-- Ask the source (npm / pypi / github / cargo / golang) for the full version list,
	-- so the user can pick any version — not just the registry's latest. Async.
	pkg.available_versions("mason", name, function(fetched)
		vim.schedule(function()
			local versions = fetched or (registry_latest and { registry_latest }) or {}
			if #versions == 0 then
				vim.notify("No versions available for " .. name)
				return
			end
			if #versions > 40 then
				versions = vim.list_slice(versions, 1, 40) -- keep the dropdown navigable
			end
			local latest = registry_latest or versions[1]

			-- The marker reflects the SNAPSHOT (the chosen version), NOT the installed
			-- one: a pinned package marks its version; an unpinned one (tracking latest)
			-- marks "Latest", even when the installed build equals the latest.
			local pinned = pkg.get_pin("mason", name)
			local items, vals = { "Latest (" .. tostring(latest) .. ")" }, { "__latest__" }
			local sel = (not pinned) and items[1] or nil
			for _, v in ipairs(versions) do
				items[#items + 1] = v
				vals[#vals + 1] = v
				if pinned == v then
					sel = v
				end
			end
			ui.select({
				title = "Install " .. name .. " \xe2\x80\x94 choose version",
				items = items,
				current_item = sel,
				callback = function(confirmed, idx)
					if not confirmed then
						return
					end
					local val = vals[idx]
					if val == "__latest__" then
						pkg.unpin("mason", name) -- latest = no entry in the snapshot
						M.mason_op(name, false)
					elseif val then
						pkg.pin("mason", name, val) -- a concrete version = the pin
						M.mason_op(name, false)
					end
				end,
			})
		end)
	end)
end

--- Run an action on a plugin by name. Shared by the action bar and the R/D/B keys.
---@param name string
---@param action "reinstall"|"delete"|"browse"
local function plugin_action(name, action)
	local info = pkg.plugin_info(name)
	if not info then
		return
	end
	state.active = "plugin"
	if action == "delete" then
		local ui = ui_mod.get()
		if not ui then
			return
		end
		-- select's callback gives the 1-based index, not the label.
		local choices = { "Delete", "Cancel" }
		ui.select({
			title = "Delete " .. name .. "?",
			info = "Deletes it from disk (a config plugin returns on next start).",
			items = choices,
			callback = function(confirmed, idx)
				if confirmed and choices[idx] == "Delete" then
					pkg.remove("plugin", { name }, function(err)
						vim.notify(
							err and ("Delete failed: " .. tostring(err)) or ("Deleted " .. name),
							err and vim.log.levels.ERROR or vim.log.levels.INFO
						)
						M.refresh_open({ keep_position = true })
					end)
				end
			end,
		})
	elseif action == "browse" then
		if info.src and info.src ~= "-" then
			pcall(vim.ui.open, info.src)
		end
	elseif action == "update" then
		update_action(name, info)
	elseif action == "reinstall" then
		reinstall_menu(name, info)
	end
end

--- Extract the plugin name from a row name (plugin / detail / git / action rows).
---@param rowname string|nil
---@return string|nil
local function plugin_from_row(rowname)
	if not rowname then
		return nil
	end
	return rowname:match("^p_(.+)$")
		or rowname:match("^pd_(.+)_%d+$")
		or rowname:match("^pg_(.+)_%d+$")
		or rowname:match("^pa_(.+)$")
end

--- Action label for each shortcut, used to highlight the matching action button.
local ACTION_LABEL = { reinstall = "Reinstall", update = "Update", delete = "Delete", browse = "Browse" }

--- Move the cursor onto a plugin's action bar and make the given button active
--- (so it renders bold). The plugin must be expanded for the bar to be visible.
---@param name string
---@param action string  one of reinstall|update|delete|browse
local function focus_action(name, action)
	local label = ACTION_LABEL[action]
	local function walk(list)
		for _, r in ipairs(list or {}) do
			if r.name == "pa_" .. name then
				r.value = label or r.value
				return true
			end
			if r.children and walk(r.children) then
				return true
			end
		end
	end
	for _, tab in ipairs(state.tabs or {}) do
		walk(tab.rows)
	end
	if state.handle and state.handle.focus then
		state.handle.focus("pa_" .. name)
	end
end

--- Word-wrap `text` to `width` columns (hard-breaking words longer than width,
--- e.g. URLs / purls), returning the list of lines.
---@param text any
---@param width integer
---@return string[]
local function wrap_value(text, width)
	text = tostring(text or "")
	if width < 8 then
		width = 8
	end
	local lines, line = {}, ""
	local function push()
		if line ~= "" then
			lines[#lines + 1] = line
			line = ""
		end
	end
	for word in text:gmatch("%S+") do
		while #word > width do
			push()
			lines[#lines + 1] = word:sub(1, width)
			word = word:sub(width + 1)
		end
		if line == "" then
			line = word
		elseif #line + 1 + #word <= width then
			line = line .. " " .. word
		else
			push()
			line = word
		end
	end
	push()
	if #lines == 0 then
		lines = { "" }
	end
	return lines
end

local function plugin_item_row(tab, item, w)
	local info = item.info
	local children = {}
	-- Detail rows are navigable (type "action") so j/k can reach them. Source / Path
	-- / Version are pressable (open link / open folder / git log) and show a trailing
	-- action icon in a distinct colour.
	local fields = plugin_detail_fields(info, item.pin)
	-- Wrap long values onto continuation lines (so they never overflow the window).
	local popup_w = math.max(40, math.floor(vim.o.columns * 0.9) - 4)
	local maxv = math.max(24, popup_w - (12 + w))
	for i, fv in ipairs(fields) do
		local field = fv[1]
		local run, suffix
		if field == "Source" and info.src and info.src ~= "-" and vim.ui.open then
			suffix = "󰏌"
			run = function()
				pcall(vim.ui.open, info.src)
			end
		elseif field == "Path" and info.path and vim.ui.open then
			suffix = "󰝰"
			run = function()
				pcall(vim.ui.open, info.path)
			end
		elseif field == "Version" then
			suffix = "󰊢"
			run = function()
				state.git_expanded[item.name] = not state.git_expanded[item.name]
				if state.git_expanded[item.name] then
					pkg.load_git_log(item.name, function()
						M.refresh_open()
					end)
				else
					M.refresh_open()
				end
			end
		end
		local vlines = wrap_value(fv[2], maxv)
		-- Link-like fields (Source URL / Path) get the blue link colour.
		local value_hl = ((field == "Source" or field == "Path") and "LvimInstallerLink")
			or ((field == "Version" or field == "Tracking") and "LvimInstallerVersion")
			or (field == "Status" and (info.outdated and "LvimInstallerOutdated" or "LvimInstallerUpToDate"))
			or "LvimInstallerDetailValue"
		children[#children + 1] = {
			type = "action",
			name = "pd_" .. item.name .. "_" .. i,
			child = true,
			icon = "    " .. (FIELD_ICON[field] or "") .. " " .. string.format("%-" .. (w + 2) .. "s", field .. ":"),
			icon_hl = "LvimInstallerDetailLabel",
			label = vlines[1],
			text_hl = value_hl,
			suffix = suffix,
			suffix_hl = suffix and "LvimInstallerActionHint" or nil,
			run = run,
		}
		for j = 2, #vlines do
			children[#children + 1] = {
				type = "spacer",
				name = "pd_" .. item.name .. "_" .. i .. "_w" .. j,
				child = true,
				icon = string.rep(" ", 8 + w),
				label = vlines[j],
				hl = { inactive = value_hl },
			}
		end
		if field == "Version" and state.git_expanded[item.name] then
			local log = pkg.git_log(item.name) or { "loading…" }
			for j, line in ipairs(log) do
				children[#children + 1] = {
					type = "spacer",
					name = "pg_" .. item.name .. "_" .. j,
					child = true,
					icon = string.rep(" ", 8 + w),
					label = line,
					hl = { inactive = "LvimInstallerDetail" },
				}
			end
		end
	end
	-- Per-plugin actions as one centered segmented bar. "Update" when an update is
	-- available, otherwise "Reinstall" (re-sync to the pinned version + build).
	-- Reinstall (re-pick version) and Update (advance) are both always available.
	local actions = { "Reinstall", "Update", "Delete" }
	if info.src and info.src ~= "-" and vim.ui.open then
		actions[#actions + 1] = "Browse"
	end
	local primary = "Reinstall"
	children[#children + 1] = {
		type = "segmented",
		name = "pa_" .. item.name,
		child = true,
		center = true,
		label = "",
		options = actions,
		value = primary,
		active_hl = "LvimInstallerActive",
		-- Box the first letter of each button as the shortcut hint ([R]einstall …).
		bracket_key = true,
		option_hl = {
			Update = "LvimInstallerActionInstall",
			Reinstall = "LvimInstallerActionInstall",
			Delete = "LvimInstallerActionRemove",
			Browse = "LvimInstallerActionOpen",
			Pin = "LvimInstallerActionHint",
		},
		run = function(value, _close, activated)
			if not activated then
				return
			end
			if value == "Delete" then
				plugin_action(item.name, "delete")
			elseif value == "Browse" then
				plugin_action(item.name, "browse")
			elseif value == "Update" then
				plugin_action(item.name, "update")
			else
				plugin_action(item.name, "reinstall")
			end
		end,
	}
	local sicon, status_hl = plugin_style(info)
	local label = plugin_label(info, item.pin)
	return {
		type = "action",
		name = "p_" .. item.name,
		icon = "  " .. sicon .. " " .. string.format("%-" .. (w + 4) .. "s", info.name),
		icon_hl = status_hl,
		text_hl = "LvimInstallerParentValue",
		label = label,
		children = children,
		expanded = state.expanded["p_" .. item.name] == true,
	}
end

--- Rows for the Plugins tab: two centered segmented toolbar bars (filter modes,
--- actions), then Loaded / Lazy sections of expandable plugin rows.
---@param tab table
---@return table[]
local function plugin_rows(tab)
	local rows = {
		{
			type = "segmented",
			name = "filter",
			center = true,
			label = "",
			options = FILTER_MODES,
			value = state.filter_mode or "All",
			text_hl = "LvimInstallerToolbar",
			active_hl = "LvimInstallerActive",
			run = function(value, _close, activated)
				state.filter_mode = value
				if value == "Search" and activated then
					vim.ui.input({ prompt = "Search: ", default = state.filter or "" }, function(input)
						if input ~= nil then
							state.filter = input
						end
						M.refresh_open()
					end)
					return
				end
				M.refresh_open()
			end,
		},
		{
			type = "segmented",
			name = "actions",
			center = true,
			label = "",
			options = { "Check for updates", "Update all" },
			value = "Check for updates",
			text_hl = "LvimInstallerToolbar",
			active_hl = "LvimInstallerActive",
			run = function(value, _close, activated)
				if not activated then
					return
				end
				if value == "Update all" then
					M.update_all()
				else
					vim.notify("lvim-installer: checking for updates…")
					pkg.check_outdated(function(found)
						vim.notify(string.format("lvim-installer: %d plugin(s) have updates", #found))
						M.refresh_open()
					end)
				end
			end,
		},
		{ type = "spacer", name = "tb_gap", label = "" },
	}

	-- Read git tags once (commit/branch are already in the data); refresh on done.
	if not state.tags_requested then
		state.tags_requested = true
		pkg.load_tags(function()
			if state.handle and state.handle.valid() then
				M.refresh_open()
			end
		end)
	end
	local items = build_items(tab)
	local loaded_items, lazy_items = {}, {}
	for _, item in ipairs(items) do
		if passes_filter(item) then
			table.insert(item.loaded and loaded_items or lazy_items, item)
		end
	end

	-- Name column = longest name IN THE SECTION, so the second column (load time /
	-- update) sits exactly 5 past it — same rule across all tabs.
	local function section_w(list)
		local w = 1
		for _, it in ipairs(list) do
			w = math.max(w, vim.fn.strdisplaywidth(it.name))
		end
		return w
	end

	do
		local w = section_w(loaded_items)
		local kids = {}
		for _, item in ipairs(loaded_items) do
			kids[#kids + 1] = plugin_item_row(tab, item, w)
		end
		rows[#rows + 1] = {
			type = "action",
			name = "sec_loaded",
			icon = "󰉋",
			icon_hl = "LvimInstallerSection",
			label = string.format("Loaded (%d)", #kids),
			text_hl = "LvimInstallerSection",
			children = kids,
			expanded = state.expanded["sec_loaded"] ~= false,
		}
	end
	do
		local w = section_w(lazy_items)
		local kids = {}
		for _, item in ipairs(lazy_items) do
			kids[#kids + 1] = plugin_item_row(tab, item, w)
		end
		rows[#rows + 1] = {
			type = "action",
			name = "sec_lazy",
			icon = "󰉋",
			icon_hl = "LvimInstallerSection",
			label = string.format("Lazy (%d)", #kids),
			text_hl = "LvimInstallerSection",
			children = kids,
			expanded = state.expanded["sec_lazy"] ~= false,
		}
	end
	return rows
end

--- Latest version string from a registry spec's source purl.
local function mason_latest(sp)
	local id = sp and sp.source and sp.source.id
	return id and (purl.parse(id) or {}).version
end

--- Whether an installed package has a newer version available than installed.
local function mason_outdated(item)
	local latest = mason_latest(item.spec)
	if not (item.installed and item.version and latest) then
		return false
	end
	local function vnorm(v)
		return (tostring(v or ""):gsub("^v", ""))
	end
	return vnorm(item.version) ~= vnorm(latest)
end

--- Mason package detail fields (registry spec + our install receipt). Mirrors the
--- plugin detail layout: State, Version (Installed + Latest), Tracking, Status.
local function mason_detail_fields(item)
	local sp = item.spec or {}
	local latest = mason_latest(item.spec)
	local f = { { "State", item.installed and "installed" or "not installed" } }
	-- Version: installed + latest (mirrors the plugin "Branch / Tag / Commit" row).
	local vparts = {}
	if item.version and item.version ~= "" then
		vparts[#vparts + 1] = "Installed [" .. item.version .. "]"
	end
	if latest and latest ~= "" then
		vparts[#vparts + 1] = "Latest [" .. latest .. "]"
	end
	if #vparts > 0 then
		f[#f + 1] = { "Version", table.concat(vparts, "  ") }
	end
	-- Tracking: the pinned version, or "Latest" (follows the registry).
	f[#f + 1] = { "Tracking", item.pinned and ("Pinned \xe2\x86\x92 " .. item.pinned) or "Latest" }
	-- Status: up to date / outdated (only meaningful once installed).
	if item.installed then
		f[#f + 1] = { "Status", mason_outdated(item) and "outdated" or "up to date" }
	end
	if sp.source and sp.source.id then
		local purl = sp.source.id
		if item.version then
			purl = purl:gsub("^(.*@)[^@#?]+(.*)$", "%1" .. item.version .. "%2")
		end
		f[#f + 1] = { "Purl", (purl:gsub("%%40", "@")) }
	end
	if sp.description and sp.description ~= "" then
		f[#f + 1] = { "Description", (sp.description:gsub("%s+", " ")) }
	end
	if sp.homepage then
		f[#f + 1] = { "Homepage", sp.homepage }
	end
	if sp.languages and #sp.languages > 0 then
		f[#f + 1] = { "Languages", table.concat(sp.languages, ", ") }
	end
	if sp.categories and #sp.categories > 0 then
		f[#f + 1] = { "Categories", table.concat(sp.categories, ", ") }
	end
	if sp.bin then
		local execs = {}
		for k in pairs(sp.bin) do
			execs[#execs + 1] = k
		end
		table.sort(execs)
		if #execs > 0 then
			f[#f + 1] = { "Executables", table.concat(execs, ", ") }
		end
	end
	return f
end

--- Extract a Mason item name from a row name (mi_/md_/ma_).
local function mason_from_row(rowname)
	if not rowname then
		return nil
	end
	return rowname:match("^mi_(.+)$") or rowname:match("^md_(.+)_%d+$") or rowname:match("^ma_(.+)$")
end

--- Homepage URL for a registry package (for Browse).
local function mason_homepage(name)
	for _, sp in ipairs(registry.all()) do
		if sp.name == name then
			return sp.homepage
		end
	end
end

--- Run an action on a Mason package by name.
---@param name string
---@param action "install"|"update"|"delete"|"browse"
local function mason_action(name, action)
	if action == "browse" then
		local hp = mason_homepage(name)
		if hp then
			pcall(vim.ui.open, hp)
		end
	elseif action == "delete" then
		local ui = ui_mod.get()
		if not ui then
			return
		end
		local choices = { "Delete", "Cancel" }
		ui.select({
			title = "Delete " .. name .. "?",
			info = "Removes the installed package from disk.",
			items = choices,
			callback = function(confirmed, idx)
				if confirmed and choices[idx] == "Delete" then
					pkg.remove("mason", { name }, function(err)
						vim.notify(
							err and ("Delete failed: " .. tostring(err)) or ("Deleted " .. name),
							err and vim.log.levels.ERROR or vim.log.levels.INFO
						)
						M.refresh_open({ keep_position = true })
					end)
				end
			end,
		})
	elseif action == "update" then
		pkg.unpin("mason", name) -- Update = jump to the latest version
		M.mason_op(name, false)
	else -- install / reinstall → choose a version
		mason_pin_menu(name)
	end
end

--- One Mason item as an accordion row: header + detail rows + action bar.
---@param tab table
---@param item table
---@param w integer
---@return table
local function mason_item_row(tab, item, w)
	local children = {}
	local fields = mason_detail_fields(item)
	local fld_outdated = mason_outdated(item)
	-- Wrap long values onto continuation lines (so they never overflow the window).
	local popup_w = math.max(40, math.floor(vim.o.columns * 0.9) - 4)
	local maxv = math.max(24, popup_w - (12 + w))
	for i, fv in ipairs(fields) do
		local field = fv[1]
		local run, suffix
		if field == "Homepage" and vim.ui.open then
			suffix = "\xf3\xb0\x8f\x8c" -- 󰏌
			run = function()
				pcall(vim.ui.open, fv[2])
			end
		end
		local vlines = wrap_value(fv[2], maxv)
		local value_hl = (field == "Homepage" and "LvimInstallerLink")
			or ((field == "Version" or field == "Tracking") and "LvimInstallerVersion")
			or (field == "Status" and (fld_outdated and "LvimInstallerOutdated" or "LvimInstallerUpToDate"))
			or "LvimInstallerDetailValue"
		children[#children + 1] = {
			type = "action",
			name = "md_" .. item.name .. "_" .. i,
			child = true,
			icon = "    " .. (FIELD_ICON[field] or "") .. " " .. string.format("%-" .. (w + 2) .. "s", field .. ":"),
			icon_hl = "LvimInstallerDetailLabel",
			label = vlines[1],
			text_hl = value_hl,
			suffix = suffix,
			suffix_hl = suffix and "LvimInstallerActionHint" or nil,
			run = run,
		}
		for j = 2, #vlines do
			children[#children + 1] = {
				type = "spacer",
				name = "md_" .. item.name .. "_" .. i .. "_w" .. j,
				child = true,
				icon = string.rep(" ", 8 + w),
				label = vlines[j],
				hl = { inactive = value_hl },
			}
		end
	end
	-- Action bar mirrors the Plugins tab. Reinstall = pick a version; Update = jump to
	-- the latest. (No icons; the [X] shortcut letters carry the hint.)
	local actions, primary
	if item.installed then
		actions, primary = { "Reinstall", "Update", "Delete" }, "Reinstall"
	else
		actions, primary = { "Install" }, "Install"
	end
	if mason_homepage(item.name) and vim.ui.open then
		actions[#actions + 1] = "Browse"
	end
	children[#children + 1] = {
		type = "segmented",
		name = "ma_" .. item.name,
		child = true,
		center = true,
		label = "",
		options = actions,
		value = primary,
		active_hl = "LvimInstallerActive",
		bracket_key = true,
		option_hl = {
			Install = "LvimInstallerActionInstall",
			Reinstall = "LvimInstallerActionInstall",
			Update = "LvimInstallerActionInstall",
			Delete = "LvimInstallerActionRemove",
			Browse = "LvimInstallerActionOpen",
		},
		run = function(value, _close, activated)
			if not activated then
				return
			end
			if value == "Delete" then
				mason_action(item.name, "delete")
			elseif value == "Browse" then
				mason_action(item.name, "browse")
			elseif value == "Update" then
				mason_action(item.name, "update")
			elseif value == "Install" then
				mason_action(item.name, "install")
			else
				mason_action(item.name, "reinstall")
			end
		end,
	}
	-- Update indicator: installed version differs from the registry's latest.
	local latest = mason_latest(item.spec)
	local outdated = mason_outdated(item)
	local sicon = item.installed and "\xe2\x97\x8f" or "\xe2\x97\x8b" -- ● / ○
	local status_hl = (not item.installed and "LvimInstallerStatusLazy")
		or (outdated and "LvimInstallerStatusOutdated")
		or "LvimInstallerStatusLoaded"
	local label = item.version or ""
	if outdated then
		label = label .. "    \xe2\x86\x92 " .. latest -- → latest
	end
	if item.pinned then
		label = "\xf3\xb0\x90\x83 " .. label -- 󰐃 pinned
	end
	return {
		type = "action",
		name = "mi_" .. item.name,
		icon = "  " .. sicon .. " " .. string.format("%-" .. (w + 4) .. "s", item.name),
		icon_hl = status_hl,
		text_hl = outdated and "LvimInstallerUpdateMark" or "LvimInstallerParentValue",
		label = label,
		children = children,
		expanded = state.expanded["mi_" .. item.name] == true,
	}
end

--- Rows for a Mason tab: a filter bar, then collapsible Installed / Available
--- sections of expandable package rows (same accordion as the Plugins tab).
---@param tab table
---@return table[]
local function mason_rows(tab)
	local rows = {
		{
			type = "segmented",
			name = "filter",
			center = true,
			label = "",
			options = { "All", "Installed", "Available", "Outdated", "Up-to-date", "Search" },
			value = state.mason_filter_mode or "All",
			text_hl = "LvimInstallerToolbar",
			active_hl = "LvimInstallerActive",
			run = function(value, _close, activated)
				state.mason_filter_mode = value
				if value == "Search" and activated then
					vim.ui.input({ prompt = "Search: ", default = state.filter or "" }, function(input)
						if input ~= nil then
							state.filter = input
						end
						M.refresh_open()
					end)
					return
				end
				M.refresh_open()
			end,
		},
		{
			type = "segmented",
			name = "actions",
			center = true,
			label = "",
			options = { "Check for updates", "Update all" },
			value = "Check for updates",
			text_hl = "LvimInstallerToolbar",
			active_hl = "LvimInstallerActive",
			run = function(value, _close, activated)
				if not activated then
					return
				end
				local outdated = {}
				for _, it in ipairs(build_items(tab)) do
					if mason_outdated(it) then
						outdated[#outdated + 1] = it.name
					end
				end
				if value == "Update all" then
					if #outdated == 0 then
						vim.notify("lvim-installer: all packages up to date")
						return
					end
					vim.notify(("lvim-installer: updating %d package(s)\xe2\x80\xa6"):format(#outdated))
					pkg.update("mason", outdated, function()
						vim.notify(("lvim-installer: updated %d package(s)"):format(#outdated))
						M.refresh_open()
					end)
				else
					vim.notify(("lvim-installer: %d package(s) have updates"):format(#outdated))
					M.refresh_open()
				end
			end,
		},
		{ type = "spacer", name = "mtb_gap", label = "" },
	}
	local items = build_items(tab)
	local mode = state.mason_filter_mode or "All"
	local fl = (state.filter or ""):lower()
	local installed, available = {}, {}
	for _, item in ipairs(items) do
		local pass = (mode == "All")
			or (mode == "Installed" and item.installed)
			or (mode == "Available" and not item.installed)
			or (mode == "Outdated" and mason_outdated(item))
			or (mode == "Up-to-date" and item.installed and not mason_outdated(item))
			or (mode == "Search" and (fl == "" or item.name:lower():find(fl, 1, true) ~= nil))
		if pass then
			table.insert(item.installed and installed or available, item)
		end
	end
	local function section(name, label, list)
		-- Name column = longest name IN THIS SECTION, so the second column sits
		-- exactly 5 past it (a long item in the other section never pushes it).
		local w = 1
		for _, it in ipairs(list) do
			w = math.max(w, vim.fn.strdisplaywidth(it.name))
		end
		local kids = {}
		for _, item in ipairs(list) do
			kids[#kids + 1] = mason_item_row(tab, item, w)
		end
		rows[#rows + 1] = {
			type = "action",
			name = name,
			icon = "\xf3\xb0\x89\x8b", -- 󰉋
			icon_hl = "LvimInstallerSection",
			label = string.format(label, #kids),
			text_hl = "LvimInstallerSection",
			children = kids,
			expanded = state.expanded[name] ~= false,
		}
	end
	section("sec_installed", "Installed (%d)", installed)
	section("sec_available", "Available (%d)", available)
	return rows
end

--- Extract a parser name from a row name (ti_/td_/ta_).
local function parser_from_row(rowname)
	if not rowname then
		return nil
	end
	return rowname:match("^ti_(.+)$") or rowname:match("^td_(.+)_%d+$") or rowname:match("^ta_(.+)$")
end

--- Run an action on a Treesitter parser by name.
---@param name string
---@param action "install"|"update"|"delete"
local function parser_action(name, action)
	if action == "delete" then
		local ui = ui_mod.get()
		if not ui then
			return
		end
		local choices = { "Delete", "Cancel" }
		ui.select({
			title = "Delete parser " .. name .. "?",
			info = "Removes the compiled parser.",
			items = choices,
			callback = function(confirmed, idx)
				if confirmed and choices[idx] == "Delete" then
					pkg.remove("parser", { name }, function(err)
						vim.notify(
							err and ("Delete failed: " .. tostring(err)) or ("Deleted " .. name),
							err and vim.log.levels.ERROR or vim.log.levels.INFO
						)
						M.refresh_open({ keep_position = true })
					end)
				end
			end,
		})
	else -- install / update
		M.parser_op(name)
	end
end

--- One parser as an accordion row: header + a Status/Path detail + action bar.
---@param tab table
---@param item table
---@param w integer
---@return table
local function parser_item_row(tab, item, w)
	local children = {}
	local ppath = pkg_paths.ts() .. "/parser/" .. item.name .. ".so"
	local fields = {
		{ "Status", item.installed and "installed" or "not installed" },
		{ "Path", ppath },
	}
	local popup_w = math.max(40, math.floor(vim.o.columns * 0.9) - 4)
	local maxv = math.max(24, popup_w - (12 + w))
	for i, fv in ipairs(fields) do
		local vlines = wrap_value(fv[2], maxv)
		children[#children + 1] = {
			type = "action",
			name = "td_" .. item.name .. "_" .. i,
			child = true,
			icon = "    " .. (FIELD_ICON[fv[1]] or "") .. " " .. string.format("%-" .. (w + 2) .. "s", fv[1] .. ":"),
			icon_hl = "LvimInstallerDetailLabel",
			label = vlines[1],
			text_hl = "LvimInstallerDetailValue",
		}
		for j = 2, #vlines do
			children[#children + 1] = {
				type = "spacer",
				name = "td_" .. item.name .. "_" .. i .. "_w" .. j,
				child = true,
				icon = string.rep(" ", 8 + w),
				label = vlines[j],
				hl = { inactive = "LvimInstallerDetailValue" },
			}
		end
	end
	local actions = item.installed and { "Update", "Delete" } or { "Install" }
	children[#children + 1] = {
		type = "segmented",
		name = "ta_" .. item.name,
		child = true,
		center = true,
		label = "",
		options = actions,
		value = actions[1],
		active_hl = "LvimInstallerActive",
		bracket_key = true,
		option_hl = {
			Install = "LvimInstallerActionInstall",
			Update = "LvimInstallerActionInstall",
			Delete = "LvimInstallerActionRemove",
		},
		run = function(value, _close, activated)
			if not activated then
				return
			end
			parser_action(item.name, value == "Delete" and "delete" or "install")
		end,
	}
	local sicon = item.installed and "\xe2\x97\x8f" or "\xe2\x97\x8b" -- ● / ○
	local status_hl = item.installed and "LvimInstallerStatusLoaded" or "LvimInstallerStatusLazy"
	return {
		type = "action",
		name = "ti_" .. item.name,
		icon = "  " .. sicon .. " " .. string.format("%-" .. (w + 4) .. "s", item.name),
		icon_hl = status_hl,
		text_hl = "LvimInstallerParentValue",
		label = "",
		children = children,
		expanded = state.expanded["ti_" .. item.name] == true,
	}
end

--- Rows for the Treesitter tab: filter bar + collapsible Installed / Available
--- sections of expandable parser rows (same accordion as the other tabs).
---@param tab table
---@return table[]
local function parser_rows(tab)
	local rows = {
		{
			type = "segmented",
			name = "filter",
			center = true,
			label = "",
			options = { "All", "Installed", "Available", "Outdated", "Up-to-date", "Search" },
			value = state.mason_filter_mode or "All",
			text_hl = "LvimInstallerToolbar",
			active_hl = "LvimInstallerActive",
			run = function(value, _close, activated)
				state.mason_filter_mode = value
				if value == "Search" and activated then
					vim.ui.input({ prompt = "Search: ", default = state.filter or "" }, function(input)
						if input ~= nil then
							state.filter = input
						end
						M.refresh_open()
					end)
					return
				end
				M.refresh_open()
			end,
		},
		{ type = "spacer", name = "ttb_gap", label = "" },
	}
	local items = build_items(tab)
	local mode = state.mason_filter_mode or "All"
	local fl = (state.filter or ""):lower()
	local installed, available = {}, {}
	for _, item in ipairs(items) do
		local pass = (mode == "All")
			or (mode == "Installed" and item.installed)
			or (mode == "Available" and not item.installed)
			or (mode == "Outdated" and mason_outdated(item))
			or (mode == "Up-to-date" and item.installed and not mason_outdated(item))
			or (mode == "Search" and (fl == "" or item.name:lower():find(fl, 1, true) ~= nil))
		if pass then
			table.insert(item.installed and installed or available, item)
		end
	end
	local function section(name, label, list)
		-- Name column = longest name IN THIS SECTION, so the second column sits
		-- exactly 5 past it (a long item in the other section never pushes it).
		local w = 1
		for _, it in ipairs(list) do
			w = math.max(w, vim.fn.strdisplaywidth(it.name))
		end
		local kids = {}
		for _, item in ipairs(list) do
			kids[#kids + 1] = parser_item_row(tab, item, w)
		end
		rows[#rows + 1] = {
			type = "action",
			name = name,
			icon = "\xf3\xb0\x89\x8b", -- 󰉋
			icon_hl = "LvimInstallerSection",
			label = string.format(label, #kids),
			text_hl = "LvimInstallerSection",
			children = kids,
			expanded = state.expanded[name] ~= false,
		}
	end
	section("sec_installed", "Installed (%d)", installed)
	section("sec_available", "Available (%d)", available)
	return rows
end

--- Build the rows for one tab: a filter row, then an Installed section and an
--- Available section (matching how Mason separates the two).
---@param tab table
---@return table[]
--- Rows for the Snapshots tab: one selectable row per snapshot file, the active one
--- marked. Selecting a non-active snapshot switches to it and offers to restore the diff.
---@param tab table
---@return table[]
local function snapshot_rows(tab)
	local snaps = pkg.snapshots()
	local active = pkg.active_snapshot()
	local rows = {
		{
			type = "action",
			name = "snap_save",
			label = "󰆓 Save current state…",
			run = function(_, close)
				if close then
					close()
				end
				require("lvim-installer.snapshot").save()
			end,
		},
		{ type = "spacer", name = "sec_snapshots", label = "Active: " .. active },
	}
	if #snaps == 0 then
		rows[#rows + 1] = { type = "spacer", name = "empty", label = "(no snapshot files found)" }
		return rows
	end
	for _, name in ipairs(snaps) do
		local marker = name == active and "● " or "○ "
		rows[#rows + 1] = {
			type = "action",
			name = "snap_" .. name,
			label = marker .. name,
			run = function(_, close)
				if close then
					close()
				end
				require("lvim-installer.snapshot").apply(name)
			end,
		}
	end
	return rows
end

local function rows_for(tab)
	if tab.kind == "plugin" then
		return plugin_rows(tab)
	elseif tab.kind == "mason" then
		return mason_rows(tab)
	elseif tab.kind == "parser" then
		return parser_rows(tab)
	elseif tab.kind == "snapshot" then
		return snapshot_rows(tab)
	end
	-- (no other flat tabs remain)
	local rows = {
		{
			type = "action",
			name = "filter",
			label = "Filter: " .. (state.filter ~= "" and state.filter or "(all)"),
			run = function(_, close)
				vim.ui.input({ prompt = "Filter: ", default = state.filter }, function(input)
					if input ~= nil then
						state.filter = input
					end
					state.active = tab.id
					state.pending = M.open
					if close then
						close()
					end
				end)
			end,
		},
	}

	-- Split the filtered items into installed / available.
	local f = state.filter:lower()
	local installed, available = {}, {}
	for _, item in ipairs(build_items(tab)) do
		if f == "" or item.name:lower():find(f, 1, true) then
			table.insert(item.installed and installed or available, item)
		end
	end

	rows[#rows + 1] = { type = "spacer", name = "sec_installed", label = string.format("Installed (%d)", #installed) }
	for _, item in ipairs(installed) do
		rows[#rows + 1] = item_row(tab, item)
	end
	rows[#rows + 1] = { type = "spacer", name = "sec_available", label = string.format("Available (%d)", #available) }
	for _, item in ipairs(available) do
		rows[#rows + 1] = item_row(tab, item)
	end
	return rows
end

--- Open (or re-open) the package manager window.
---@param tab_id? string  Initial tab id (e.g. "LSP", "parser", "plugin")
---@return nil
function M.open(tab_id)
	if tab_id then
		state.active = tab_id
	end
	local ui = ui_mod.get()
	if not ui then
		vim.notify("lvim-installer: lvim-utils UI unavailable", vim.log.levels.ERROR)
		return
	end
	local tabs = {}
	local sel = 1
	for i, tab in ipairs(TABS) do
		tabs[#tabs + 1] = { label = tab.label, icon = tab.icon, rows = rows_for(tab) }
		if tab.id == state.active then
			sel = i
		end
	end
	-- Keep references so async operations (e.g. update progress) can mutate the
	-- live rows and re-render without closing the window.
	state.tabs = tabs
	state.handle = ui.tabs({
		title = "Package Manager",
		tabs = tabs,
		tab_selector = sel,
		-- Tabs are managed only from the header (press "t"); content keys never jump
		-- to or switch tabs.
		lock_tabs = true,
		-- Use most of the screen — this is a full browser, not a small prompt.
		width = 0.9,
		max_width = 0.9,
		height = 0.9,
		max_height = 0.9,
		max_items = 40,
		-- Plugin shortcuts: R reinstall/update, D delete, B browse — act on the
		-- plugin under the cursor (the plugin row or any of its detail/action rows).
		on_open = function(buf)
			-- A key may act on a plugin row or a Mason package row; dispatch by which
			-- one is under the cursor.
			local function dispatch(plugin_act, mason_act, parser_act)
				return function()
					local row = state.handle and state.handle.cursor_name and state.handle.cursor_name()
					local pname = plugin_from_row(row)
					if pname and plugin_act then
						focus_action(pname, plugin_act)
						plugin_action(pname, plugin_act)
						return
					end
					local mname = mason_from_row(row)
					if mname and mason_act then
						if state.handle.focus then
							state.handle.focus("ma_" .. mname)
						end
						mason_action(mname, mason_act)
						return
					end
					local tname = parser_from_row(row)
					if tname and parser_act then
						if state.handle.focus then
							state.handle.focus("ta_" .. tname)
						end
						parser_action(tname, parser_act)
					end
				end
			end
			-- Map both cases so the shortcut never depends on Shift.
			local function setkey(keys, fn, desc)
				for _, key in ipairs(keys) do
					vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = desc })
				end
			end
			setkey({ "r", "R" }, dispatch("reinstall", "reinstall", nil), "Reinstall")
			setkey({ "i", "I" }, dispatch(nil, "install", "install"), "Install package")
			setkey({ "u", "U" }, dispatch("update", "update", "update"), "Update")
			setkey({ "d", "D" }, dispatch("delete", "delete", "delete"), "Delete")
			setkey({ "b", "B" }, dispatch("browse", "browse", nil), "Browse homepage / source")
		end,
		callback = function()
			state.handle = nil
			local p = state.pending
			state.pending = nil
			if p then
				vim.schedule(p)
			end
		end,
	})
	-- Cold start: if a catalogue has not loaded yet (empty parser list), fetch it in
	-- the background (TTL-gated) and rebuild the tabs once it lands.
	if #pkg.available("parser") == 0 then
		pkg.update_registry("all", function()
			M.refresh_open()
		end, false)
	end
end

--- Find a top-level row by name across all open tabs (plugin rows live here).
---@param rowname string
---@return table|nil
local function find_row(rowname)
	-- Plugin rows are nested under the section rows, so search children too.
	local function walk(list)
		for _, r in ipairs(list or {}) do
			if r.name == rowname then
				return r
			end
			if r.children then
				local found = walk(r.children)
				if found then
					return found
				end
			end
		end
	end
	for _, tab in ipairs(state.tabs or {}) do
		local found = walk(tab.rows)
		if found then
			return found
		end
	end
	return nil
end

--- Rebuild every tab's rows from fresh data and re-render the open window.
---@return nil
--- Persist the live expanded state of plugin rows (native accordion) so a rebuild
--- does not collapse them.
local function sync_expanded()
	local function walk(list)
		for _, r in ipairs(list or {}) do
			if r.children then
				if r.name then
					state.expanded[r.name] = r.expanded == true
				end
				walk(r.children)
			end
		end
	end
	for _, tab in ipairs(state.tabs or {}) do
		walk(tab.rows)
	end
end

--- Rebuild every tab's rows and re-render in place.
--- By default the cursor follows the same logical row (by name) across the rebuild.
--- With `opts.keep_position` it keeps the screen position instead — so after an
--- uninstall the next row slides under the cursor rather than the cursor chasing the
--- removed item down into the "available" section.
---@param opts? { keep_position?: boolean }
---@return nil
function M.refresh_open(opts)
	opts = opts or {}
	if not (state.handle and state.handle.valid() and state.tabs) then
		return
	end
	sync_expanded()
	local cur, idx
	if opts.keep_position then
		idx = state.handle.cursor_index and state.handle.cursor_index()
	else
		cur = state.handle.cursor_name and state.handle.cursor_name()
	end
	for i, tab in ipairs(TABS) do
		if state.tabs[i] then
			state.tabs[i].rows = rows_for(tab)
		end
	end
	state.handle.recalc()
	if idx and state.handle.focus_index then
		state.handle.focus_index(idx)
	elseif cur and state.handle.focus then
		state.handle.focus(cur)
	end
end

--- Update one plugin with a live in-popup spinner (no separate UI / no reopen).
---@param item table
---@param verb_override? string  Spinner verb (e.g. "Reinstalling…")
---@param op? fun()  The operation to run (defaults to vim.pack update for `item`)
---@return nil
function M.update_plugin(item, verb_override, op)
	local row = find_row("p_" .. item.name)
	if not row then
		return
	end
	-- "Updating…" / "Reinstalling…" — caller may force one (R vs U).
	local verb = verb_override or (item.info and item.info.outdated and "Updating…" or "Reinstalling…")
	row.icon_hl = "LvimInstallerProgress"
	row.text_hl = "LvimInstallerProgress"
	local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
	local fi = 1
	local timer = vim.uv.new_timer()
	local done = false

	local function finish()
		if done then
			return
		end
		done = true
		if timer then
			timer:stop()
			timer:close()
			timer = nil
		end
		pcall(vim.api.nvim_del_augroup_by_name, "lvim_installer_upd_" .. item.name)
		M.refresh_open()
	end

	timer:start(
		0,
		90,
		vim.schedule_wrap(function()
			row.label = frames[fi] .. "  " .. verb
			fi = fi % #frames + 1
			if state.handle and state.handle.valid() then
				state.handle.render()
				pcall(vim.cmd, "redraw")
			else
				finish()
			end
		end)
	)

	-- vim.pack.update(force) applies asynchronously; PackChanged signals completion.
	local grp = vim.api.nvim_create_augroup("lvim_installer_upd_" .. item.name, { clear = true })
	vim.api.nvim_create_autocmd("PackChanged", {
		group = grp,
		callback = function(ev)
			local d = ev.data
			if d and d.spec and d.spec.name == item.name and (d.kind == "update" or d.kind == "install") then
				finish()
			end
		end,
	})
	-- Fallback: a plugin already up to date emits no PackChanged.
	vim.defer_fn(finish, 8000)

	if op then
		op()
	else
		pkg.update("plugin", { item.name }, function() end)
	end
end

--- Install or update one Mason package with a live in-popup spinner.
---@param name string
---@param is_update boolean
---@return nil
function M.mason_op(name, is_update)
	local row = find_row("mi_" .. name)
	if not row then
		return
	end
	local verb = is_update and "Updating\xe2\x80\xa6" or "Installing\xe2\x80\xa6"
	row.icon_hl = "LvimInstallerProgress"
	row.text_hl = "LvimInstallerProgress"
	local frames = {
		"\xe2\xa0\x8b",
		"\xe2\xa0\x99",
		"\xe2\xa0\xb9",
		"\xe2\xa0\xb8",
		"\xe2\xa0\xbc",
		"\xe2\xa0\xb4",
		"\xe2\xa0\xa6",
		"\xe2\xa0\xa7",
		"\xe2\xa0\x87",
		"\xe2\xa0\x8f",
	}
	local fi = 1
	local status_txt = verb
	local timer = vim.uv.new_timer()
	local done = false
	local function finish()
		if done then
			return
		end
		done = true
		if timer then
			timer:stop()
			timer:close()
			timer = nil
		end
		M.refresh_open()
	end
	timer:start(
		0,
		90,
		vim.schedule_wrap(function()
			row.label = frames[fi] .. "  " .. status_txt
			fi = fi % #frames + 1
			if state.handle and state.handle.valid() then
				state.handle.render()
				pcall(vim.cmd, "redraw")
			else
				finish()
			end
		end)
	)
	pkg.install("mason", { name }, function()
		finish()
	end, {
		on_progress = function(n, st, action)
			if n == name and (st or action) then
				status_txt = verb .. "  " .. tostring(st or action)
			end
		end,
	})
end

--- Install one Treesitter parser with a live in-popup spinner.
---@param name string
---@return nil
function M.parser_op(name)
	local row = find_row("ti_" .. name)
	if not row then
		return
	end
	row.icon_hl = "LvimInstallerProgress"
	row.text_hl = "LvimInstallerProgress"
	local frames = {
		"\xe2\xa0\x8b",
		"\xe2\xa0\x99",
		"\xe2\xa0\xb9",
		"\xe2\xa0\xb8",
		"\xe2\xa0\xbc",
		"\xe2\xa0\xb4",
		"\xe2\xa0\xa6",
		"\xe2\xa0\xa7",
		"\xe2\xa0\x87",
		"\xe2\xa0\x8f",
	}
	local fi = 1
	local timer = vim.uv.new_timer()
	local done = false
	local function finish()
		if done then
			return
		end
		done = true
		if timer then
			timer:stop()
			timer:close()
			timer = nil
		end
		M.refresh_open()
	end
	timer:start(
		0,
		90,
		vim.schedule_wrap(function()
			row.label = frames[fi] .. "  Installing\xe2\x80\xa6"
			fi = fi % #frames + 1
			if state.handle and state.handle.valid() then
				state.handle.render()
				pcall(vim.cmd, "redraw")
			else
				finish()
			end
		end)
	)
	pkg.install("parser", { name }, function()
		finish()
	end)
end

--- Plugin-tab index in state.tabs (matches TABS order).
---@return integer|nil
local function plugin_tab_index()
	for i, t in ipairs(TABS) do
		if t.id == "plugin" then
			return i
		end
	end
end

--- Update all outdated plugins (sequential batches of config.update_concurrency)
--- with a live in-popup view: the current batch floats to the top with spinners,
--- then queued, then done — plus a (k/N) counter. No separate UI, no reopen.
---@return nil
function M.update_all()
	local concurrency = math.max(1, config.update_concurrency or 4)

	local function run(targets)
		if not (state.handle and state.handle.valid()) then
			return
		end
		if #targets == 0 then
			vim.notify("lvim-installer: everything is up to date")
			M.refresh_open()
			return
		end
		local ti = plugin_tab_index()
		local total = #targets
		local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
		local fi, k, done, first = 1, 0, false, true
		local pos = 0
		local batch_left = 0
		local timer = vim.uv.new_timer()
		local status = {} -- name → "queued" | "updating" | "done"
		for _, n in ipairs(targets) do
			status[n] = "queued"
		end
		local draw, finish, pump

		-- Build the progress rows: title, then updating (top) / queued / done.
		local function build()
			local r = {
				{
					type = "spacer",
					name = "u_title",
					label = string.format("%s  Updating  (%d/%d)", frames[fi], k, total),
					hl = { inactive = "LvimInstallerSection" },
				},
				{ type = "spacer", name = "u_blank", label = "" },
			}
			local sections = {
				{ "updating", frames[fi], "LvimInstallerAction" },
				{ "queued", "·", "LvimInstallerDetail" },
				{ "done", "✓", "LvimInstallerStatusLoaded" },
			}
			for _, sec in ipairs(sections) do
				for _, n in ipairs(targets) do
					if status[n] == sec[1] then
						r[#r + 1] = {
							type = "spacer",
							name = "u_" .. n,
							label = "  " .. sec[2] .. "  " .. n,
							hl = { inactive = sec[3] },
						}
					end
				end
			end
			return r
		end

		function draw()
			if not (state.handle and state.handle.valid()) then
				return finish()
			end
			if ti and state.tabs[ti] then
				state.tabs[ti].rows = build()
			end
			-- Row count is constant after the first switch, so only recalc once.
			if first then
				first = false
				state.handle.recalc()
			else
				state.handle.render()
			end
		end

		function finish()
			if done then
				return
			end
			done = true
			if timer then
				timer:stop()
				timer:close()
				timer = nil
			end
			pcall(vim.api.nvim_del_augroup_by_name, "lvim_installer_update_all")
			M.refresh_open()
		end

		local function one_done(name)
			if status[name] == "updating" then
				status[name] = "done"
				k = k + 1
				batch_left = batch_left - 1
				if batch_left <= 0 then
					pump()
				end
			end
		end

		function pump()
			if done then
				return
			end
			if k >= total then
				return finish()
			end
			local batch = {}
			while #batch < concurrency and pos < total do
				pos = pos + 1
				local n = targets[pos]
				status[n] = "updating"
				batch[#batch + 1] = n
			end
			if #batch == 0 then
				return
			end
			batch_left = #batch
			local this_pos = pos
			pkg.update("plugin", batch, function() end)
			-- Safety: if a plugin emits no PackChanged, time the batch out.
			vim.defer_fn(function()
				if not done and pos == this_pos and batch_left > 0 then
					for _, n in ipairs(batch) do
						one_done(n)
					end
				end
			end, 30000)
		end

		local grp = vim.api.nvim_create_augroup("lvim_installer_update_all", { clear = true })
		vim.api.nvim_create_autocmd("PackChanged", {
			group = grp,
			callback = function(ev)
				local d = ev.data
				if d and d.spec and (d.kind == "update" or d.kind == "install") then
					one_done(d.spec.name)
				end
			end,
		})

		timer:start(
			0,
			90,
			vim.schedule_wrap(function()
				fi = fi % #frames + 1
				draw()
			end)
		)
		draw()
		pump()
	end

	-- Targets: the known-outdated set; if none known, run a check first.
	local targets = {}
	for _, info in ipairs(pkg.plugins()) do
		if info.outdated and not info.dir then
			targets[#targets + 1] = info.name
		end
	end
	if #targets > 0 then
		run(targets)
	else
		vim.notify("lvim-installer: checking for updates…")
		pkg.check_outdated(function(found)
			run(found)
		end)
	end
end

return M
