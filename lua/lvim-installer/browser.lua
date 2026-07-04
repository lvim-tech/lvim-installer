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
local snapshot = require("lvim-installer.snapshot")
local ui_filters = require("lvim-ui.filters")
local surface = require("lvim-ui.surface")
local M = {}

--- Tab definitions.  Mason tabs filter the registry by category; parser/plugin
--- tabs read their own backends.  Tab-bar icons are config-driven (`config.tab_icons`, keyed by `id`).
---@type table[]
local TABS = {
    { id = "plugin", kind = "plugin", label = "Plugins" },
    { id = "parser", kind = "parser", label = "Treesitter" },
    { id = "LSP", kind = "mason", category = "LSP", label = "LSP" },
    { id = "DAP", kind = "mason", category = "DAP", label = "DAP" },
    { id = "Linter", kind = "mason", category = "Linter", label = "Linter" },
    { id = "Formatter", kind = "mason", category = "Formatter", label = "Formatter" },
    -- menu mode: its rows are childless action rows (save + each snapshot) — without it ui.tabs would collapse
    -- them into horizontal footer buttons instead of a vertical list in the body.
    { id = "snapshot", kind = "snapshot", label = "Snapshots", menu = true },
}

-- Browse state (persists across the close/reopen cycle).
-- `expanded` holds plugin names whose inline detail is unfolded.
local state = { filters = {}, filter_modes = {}, active = "plugin", pending = nil, expanded = {}, git_expanded = {} }

--- Per-tab search text and filter mode — a search or mode set on one tab must NOT leak to
--- another (the tabs share one window but distinct catalogues). Keyed by tab id.
---@param tab_id string
---@return string
local function tab_filter(tab_id)
    return state.filters[tab_id] or ""
end

---@param tab_id string
---@return string
local function tab_mode(tab_id)
    return state.filter_modes[tab_id] or "All"
end

-- Forward declaration: the shared in-row spinner used by plugin / mason / parser ops to
-- unify their feedback (a live spinner during the op + a final notification). Defined after
-- find_row (which it needs); referenced earlier by update_action.
---@type fun(rowname: string, verb: string): fun(s: string), fun(msg?: string, level?: integer)
local row_spinner

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
            items[#items + 1] = {
                name = lang,
                kind = "parser",
                desc = "",
                installed = installed[lang],
                version = installed[lang] and pkg.parser_installed_version(lang) or nil,
                outdated = installed[lang] and pkg.parser_outdated(lang) or false,
            }
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

-- Status glyph + highlight groups for a plugin by state. Nerd Font circles (filled =
-- present/loaded, hollow = lazy); the colours come from theme-overridable groups.
---@param info table
---@return string icon, string icon_hl
local function plugin_style(info)
    if info.outdated then
        return "", "LvimInstallerStatusOutdated"
    elseif info.loaded then
        return "", "LvimInstallerStatusLoaded"
    end
    return "", "LvimInstallerStatusLazy"
end

-- Plugin row text: name in a fixed column, then load time and/or update marker.
---@param info table
---@param pin table|nil  the stored convention { version, reftype, branch }, or nil
---@return string
local function plugin_label(info, pin)
    local parts = {}
    -- FIXED-WIDTH load-time column (number right-aligned in 6 cells + " ms" = 9), so the tags after it
    -- (local / dep / pinned / update) line up across rows no matter the number's width ("0.77 ms" vs
    -- "12.15 ms"). Reserved with 9 spaces when unloaded so the tag columns still align on those rows.
    if info.loaded and info.time_ms then
        parts[#parts + 1] = string.format("%6.2f ms", info.time_ms)
    else
        parts[#parts + 1] = string.rep(" ", 9)
    end
    if info.dir then
        -- a LOCAL dev clone (dir=): no git remote, so it is skipped by the update check — flag it so the
        -- panel total (incl. these) vs the "Check for updates" count (git-managed only) is self-explanatory.
        parts[#parts + 1] = "󰌹 local"
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
    return (table.concat(parts, "    "):gsub("%s+$", "")) -- drop the reserved column when the row has no tags
end

-- Per-action icon for the inline action rows (4-space indent baked in).
local ACTION_ICON = config.action_icons

-- Per-field icons for the inline detail rows.
local FIELD_ICON = config.field_icons

-- Pad an icon to a fixed display width so every row's text starts at the same column.
local ICON_W = 2
local function cell(glyph)
    glyph = glyph or ""
    return glyph .. string.rep(" ", math.max(0, ICON_W - vim.fn.strdisplaywidth(glyph)))
end

-- Segmented filter modes shown as the top toolbar bar.
local FILTER_MODES = { "All", "Loaded", "Lazy", "Deps", "Outdated", "Up-to-date", "Search" }

--- Whether a plugin item matches a SPECIFIC filter mode (independent of the current mode) — shared by the
--- live filter-bar counts and `passes_filter` below.
---@param item table
---@param mode string
---@param tab_id string
---@return boolean
local function plugin_match(item, mode, tab_id)
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
        local f = tab_filter(tab_id):lower()
        return f == "" or item.name:lower():find(f, 1, true) ~= nil
    end
    return true
end

--- Whether a plugin item passes the active filter mode (and search text).
---@param item   table
---@param tab_id string
---@return boolean
local function passes_filter(item, tab_id)
    return plugin_match(item, tab_mode(tab_id), tab_id)
end

--- Whether a mason / parser item matches a SPECIFIC filter mode — shared by both tabs (same modes); the only
--- difference is how "outdated" is computed, passed as `is_outdated`. Drives the filter-bar counts + filtering.
---@param item table
---@param mode string
---@param tab_id string
---@param is_outdated fun(item): boolean
---@return boolean
local function pkg_match(item, mode, tab_id, is_outdated)
    if mode == "Installed" then
        return item.installed == true
    elseif mode == "Available" then
        return not item.installed
    elseif mode == "Outdated" then
        return is_outdated(item) == true
    elseif mode == "Up-to-date" then
        return item.installed and not is_outdated(item)
    elseif mode == "Search" then
        local f = tab_filter(tab_id):lower()
        return f == "" or item.name:lower():find(f, 1, true) ~= nil
    end
    return true -- All
end

--- Detail fields for a plugin as { field, value } pairs (rendered as inline rows).
---@param info table
---@param pin table|nil  the stored convention { version, reftype, branch }, or nil
---@return table[]
local function plugin_detail_fields(info, pin)
    local state = info.loaded and ("loaded · " .. (info.lazy and "lazy" or "eager")) or "not loaded · lazy"
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
    vim.notify("Fetching refs for " .. name .. "…")
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

        local function finish(ref, conv)
            local err = pkg.plugin_checkout(name, ref)
            if err then
                vim.notify("Checkout failed for " .. name .. ": " .. err, vim.log.levels.ERROR)
            else
                -- A tag or commit is an explicit, fixed version → pin. "Latest" / a branch
                -- tip is "follow latest", so it clears the pin instead of recording one.
                if conv.reftype == "tag" or conv.reftype == "commit" then
                    pkg.pin("plugin", name, conv.version, conv.reftype, conv.branch)
                else
                    pkg.unpin("plugin", name)
                end
                vim.notify(name .. " → " .. ref)
            end
            M.refresh_open()
        end

        local approach_menu, branch_flow, tag_flow

        function branch_flow()
            local default = pkg.plugin_default_branch(name)
            local items, vals, sel = {}, {}, nil
            local function add(b, is_default)
                -- Build ONE combined "(default, current)" suffix ourselves — the branch that is both the repo
                -- default AND the installed one would otherwise stack two suffixes. The select gets
                -- `mark_current = false` below so lvim-utils only FOCUSES `sel`, not re-appends "(current)".
                local is_current = (cur_branch == b)
                local tags = {}
                if is_default then
                    tags[#tags + 1] = "default"
                end
                if is_current then
                    tags[#tags + 1] = "current"
                end
                local it = b .. (#tags > 0 and ("  (" .. table.concat(tags, ", ") .. ")") or "")
                items[#items + 1] = it
                vals[#vals + 1] = b
                if is_current then
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
                title = name .. " — branch",
                items = items,
                current_item = sel,
                mark_current = false, -- the label already carries the combined "(default, current)" marker
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
                        title = name .. " — commit on " .. branch,
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
                title = name .. " — tag",
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
                        title = picked .. " — lock level",
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
                title = "Reinstall " .. name .. " — by",
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
    local _, finish = row_spinner("p_" .. name, "Updating…")
    pkg.plugin_fetch(name, function()
        local pin = pkg.get_pin_full("plugin", name)
        local rt = pin and pin.reftype
        if rt == "tag" and pin.branch then
            local newest = pkg.plugin_resolve_tag(name, pin.branch)
            local cur = pkg.plugin_current(name)
            if newest and (not cur or cur.value ~= newest) then
                local err = pkg.plugin_checkout(name, newest)
                if err then
                    finish("Update failed for " .. name .. ": " .. err, vim.log.levels.ERROR)
                else
                    pkg.pin("plugin", name, newest, "tag", pin.branch)
                    finish(name .. " → " .. newest .. " (newest " .. pin.branch .. ".x)")
                end
            else
                finish(name .. ": already newest in " .. pin.branch .. ".x")
            end
        elseif rt == "branch" then
            local err = pkg.plugin_update_branch(name, pin.version)
            if err then
                finish("Update failed for " .. name .. ": " .. err, vim.log.levels.ERROR)
            else
                pkg.pin("plugin", name, pin.version, "branch", pin.version)
                finish(name .. ": " .. pin.version .. " updated to tip")
            end
        elseif rt == "tag" or rt == "commit" then
            finish(name .. " is fixed (" .. rt .. " " .. tostring(pin.version) .. ") — use Reinstall")
        else
            -- No stored convention (or no pin at all) → live git state. (Previously an early
            -- `if not pin then return` made this branch dead for unpinned plugins, so pressing
            -- Update gave the "Checking…" feedback and then nothing.)
            local cur = pkg.plugin_current(name)
            if cur and cur.kind == "branch" then
                local err = pkg.plugin_update_branch(name, cur.value)
                finish(
                    err and ("Update failed for " .. name .. ": " .. err)
                        or (name .. ": " .. cur.value .. " updated to tip"),
                    err and vim.log.levels.ERROR or nil
                )
            elseif cur and cur.kind == "commit" then
                -- Un-pinned commit → advance on the default branch.
                local default = pkg.plugin_default_branch(name)
                if default then
                    local err = pkg.plugin_update_branch(name, default)
                    finish(
                        err and ("Update failed for " .. name .. ": " .. err) or (name .. ": advanced on " .. default),
                        err and vim.log.levels.ERROR or nil
                    )
                else
                    finish(name .. ": no default branch to advance")
                end
            else
                finish(name .. " is on a fixed tag — use Reinstall to change")
            end
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
                title = "Install " .. name .. " — choose version",
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
---@param action "reinstall"|"delete"|"browse"|"update"
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
            subtitle = { text = "Deletes it from disk (a config plugin returns on next start).", type = "warn" },
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

--- A per-item action toolbar (shown under an expanded plugin / package): the actions as a centered ui.bar of
--- buttons, each with a bracketed shortcut letter ([R]einstall …) and its own accent colour. `specs` =
--- { { label, key, hl, run }, … }. Mirrors the tab toolbars so every button in the browser goes through ui.bar.
---@param name string
---@param specs table[]
---@return table  a `type="bar"` child row
local function item_action_bar(name, specs)
    local items = {}
    for _, s in ipairs(specs) do
        -- Built through the SHARED `surface.button` mapper — the `plain` KIND (no lead badge), so the `key`
        -- letter brackets INSIDE the caption ([R]einstall …) exactly as before; the installer's own accent
        -- colours ride in as the `hl` box override (text box only, no icon box — the bracket takes the text tint).
        items[#items + 1] = surface.button({
            name = s.label,
            key = s.key,
            run = s.run,
            hl = {
                text = {
                    padding = { 1, 1 },
                    normal = s.hl or "LvimInstallerToolbar", -- the button's own accent (inactive)
                    active = s.hl or "LvimInstallerActive",
                    hover = "LvimInstallerToolbarHover", -- the keyboard cursor
                    hover_active = "LvimInstallerToolbarHoverActive", -- the cursor on the applied button
                },
            },
        }, "plain")
    end
    return { type = "bar", name = name, align = "center", child = true, items = items }
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
            flat = true, -- no lead type icon: the row carries its own field icon + label in `icon`
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
                flat = true,
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
                    flat = true,
                    icon = string.rep(" ", 8 + w),
                    label = line,
                    hl = { inactive = "LvimInstallerDetail" },
                }
            end
        end
    end
    -- Per-plugin actions as one centered ui.bar (Reinstall re-picks the version, Update advances; both always
    -- available). The [X] shortcut letters mirror the global r/u/d/b keys.
    local specs = {
        {
            label = "Reinstall",
            key = "R",
            hl = "LvimInstallerActionInstall",
            run = function()
                plugin_action(item.name, "reinstall")
            end,
        },
        {
            label = "Update",
            key = "U",
            hl = "LvimInstallerActionInstall",
            run = function()
                plugin_action(item.name, "update")
            end,
        },
        {
            label = "Delete",
            key = "D",
            hl = "LvimInstallerActionRemove",
            run = function()
                plugin_action(item.name, "delete")
            end,
        },
    }
    if info.src and info.src ~= "-" and vim.ui.open then
        specs[#specs + 1] = {
            label = "Browse",
            key = "B",
            hl = "LvimInstallerActionOpen",
            run = function()
                plugin_action(item.name, "browse")
            end,
        }
    end
    children[#children + 1] = item_action_bar("pa_" .. item.name, specs)
    local sicon, status_hl = plugin_style(info)
    local label = plugin_label(info, item.pin)
    return {
        type = "action",
        name = "p_" .. item.name,
        flat = true, -- no expand caret: the row carries its own status icon + name in `icon`
        icon = "  " .. sicon .. " " .. string.format("%-" .. (w + 4) .. "s", info.name),
        icon_hl = status_hl,
        text_hl = "LvimInstallerParentValue",
        label = label,
        children = children,
        expanded = state.expanded["p_" .. item.name] == true,
    }
end

-- Toolbar button styling: the inactive name on the dim toolbar tint, the active / hover on the accent.
---@return table
local function bar_btn_style()
    return {
        text = {
            padding = { 1, 1 },
            normal = "LvimInstallerToolbar", -- inactive
            active = "LvimInstallerActive", -- the applied filter / selected option
            hover = "LvimInstallerToolbarHover", -- the keyboard cursor (on an inactive button)
            hover_active = "LvimInstallerToolbarHoverActive", -- the cursor ON the applied button
        },
    }
end

--- The filter bar — built through the SHARED filter-group model (lvim-ui.filters), identical to the
--- picker's. Optional `items` + `match(item, mode)` drive a live per-mode COUNT. Activation sets the mode and
--- refreshes ("Search" prompts first).
---@param tab_id string
---@param modes? string[]
---@param items? table[]            the tab's items (for the counts)
---@param match? fun(item, mode): boolean
---@return table  a `type="bar"` row
local function filter_bar(tab_id, modes, items, match)
    local buttons = {}
    for _, mode in ipairs(modes or FILTER_MODES) do
        buttons[#buttons + 1] = { id = mode, label = mode, hl_hover_active = "LvimInstallerToolbarHoverActive" }
    end
    local fb = ui_filters.bar({ { id = "mode", active = tab_mode(tab_id), buttons = buttons } }, {
        count = (items and match) and function(_, b)
            local n = 0
            for _, it in ipairs(items) do
                if match(it, b.id) then
                    n = n + 1
                end
            end
            return n
        end or nil,
        on_select = function(_, id)
            state.filter_modes[tab_id] = id
            if id == "Search" then
                vim.ui.input({ prompt = "Search: ", default = tab_filter(tab_id) }, function(input)
                    if input ~= nil then
                        state.filters[tab_id] = input
                    end
                    M.refresh_open()
                end)
                return
            end
            M.refresh_open()
        end,
        accents = { active = "LvimInstallerActive", inactive = "LvimInstallerToolbar" },
    })
    return { type = "bar", name = "filter", align = "center", items = fb.band.items }
end

--- A generic centered action bar: `{ { label, fn }, … }` → a `type="bar"` row of clickable buttons.
---@param specs table[]
---@return table
local function action_bar(specs)
    local items = {}
    for _, s in ipairs(specs) do
        -- Built through the SHARED `surface.button` mapper — the `plain` KIND (no key, no badge); the toolbar
        -- accent colours (from `bar_btn_style`) ride in as the `hl` box override, so the button is byte-identical.
        items[#items + 1] = surface.button({ name = s[1], run = s[2], hl = bar_btn_style() }, "plain")
    end
    return { type = "bar", name = "actions", align = "center", items = items }
end

--- Rows for the Plugins tab: the filter + action toolbars (centered ui.bar button bars), then Loaded / Lazy
--- sections of expandable plugin rows.
---@param tab table
---@return table[]
local function plugin_rows(tab)
    local items = build_items(tab)
    local rows = {
        filter_bar(tab.id, FILTER_MODES, items, function(it, m)
            return plugin_match(it, m, tab.id)
        end),
        action_bar({
            {
                "Check for updates",
                function()
                    require("lvim-installer").update_registry("plugin")
                end,
            },
            {
                "Update all",
                function()
                    M.update_all()
                end,
            },
        }),
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
    local loaded_items, lazy_items = {}, {}
    for _, item in ipairs(items) do
        if passes_filter(item, tab.id) then
            table.insert(item.loaded and loaded_items or lazy_items, item)
        end
    end
    -- the title counter (visible / total) for this tab
    state.tab_counts = state.tab_counts or {}
    state.tab_counts[tab.id] = { current = #loaded_items + #lazy_items, total = #items }

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
    f[#f + 1] = { "Tracking", item.pinned and ("Pinned → " .. item.pinned) or "Latest" }
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
---@param action "install"|"update"|"delete"|"browse"|"reinstall"
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
            subtitle = { text = "Removes the installed package from disk.", type = "warn" },
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
        M.mason_op(name, true)
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
            suffix = "󰏌" -- 󰏌
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
            flat = true, -- no lead type icon: the row carries its own field icon + label in `icon` (matches Plugins)
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
                flat = true,
                icon = string.rep(" ", 8 + w),
                label = vlines[j],
                hl = { inactive = value_hl },
            }
        end
    end
    -- Action bar mirrors the Plugins tab — a centered ui.bar; the [X] shortcut letters carry the hint.
    local specs
    if item.installed then
        specs = {
            {
                label = "Reinstall",
                key = "R",
                hl = "LvimInstallerActionInstall",
                run = function()
                    mason_action(item.name, "reinstall")
                end,
            },
            {
                label = "Update",
                key = "U",
                hl = "LvimInstallerActionInstall",
                run = function()
                    mason_action(item.name, "update")
                end,
            },
            {
                label = "Delete",
                key = "D",
                hl = "LvimInstallerActionRemove",
                run = function()
                    mason_action(item.name, "delete")
                end,
            },
        }
    else
        specs = {
            {
                label = "Install",
                key = "I",
                hl = "LvimInstallerActionInstall",
                run = function()
                    mason_action(item.name, "install")
                end,
            },
        }
    end
    if mason_homepage(item.name) and vim.ui.open then
        specs[#specs + 1] = {
            label = "Browse",
            key = "B",
            hl = "LvimInstallerActionOpen",
            run = function()
                mason_action(item.name, "browse")
            end,
        }
    end
    children[#children + 1] = item_action_bar("ma_" .. item.name, specs)
    -- Update indicator: installed version differs from the registry's latest.
    local latest = mason_latest(item.spec)
    local outdated = mason_outdated(item)
    local sicon = item.installed and "" or "" -- filled = installed / hollow = available
    local status_hl = (not item.installed and "LvimInstallerStatusLazy")
        or (outdated and "LvimInstallerStatusOutdated")
        or "LvimInstallerStatusLoaded"
    local label = item.version or ""
    if outdated then
        label = label .. "    → " .. latest -- → latest
    end
    if item.pinned then
        label = "󰐃 " .. label -- 󰐃 pinned
    end
    return {
        type = "action",
        name = "mi_" .. item.name,
        flat = true, -- no expand caret: the row carries its own status icon + name in `icon` (matches Plugins)
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
    local items = build_items(tab)
    local rows = {
        filter_bar(
            tab.id,
            { "All", "Installed", "Available", "Outdated", "Up-to-date", "Search" },
            items,
            function(it, m)
                return pkg_match(it, m, tab.id, mason_outdated)
            end
        ),
        action_bar({
            {
                "Check for updates",
                function()
                    require("lvim-installer").update_registry("mason")
                end,
            },
            {
                "Update all",
                function()
                    -- Skip explicitly-pinned packages: a pin means "hold this version", so a bulk update must
                    -- not touch it (use the per-package Update for that).
                    local outdated = {}
                    for _, it in ipairs(build_items(tab)) do
                        if mason_outdated(it) and not pkg.get_pin("mason", it.name) then
                            outdated[#outdated + 1] = it.name
                        end
                    end
                    if #outdated == 0 then
                        vim.notify("lvim-installer: all packages up to date")
                        return
                    end
                    vim.notify(("lvim-installer: updating %d package(s)…"):format(#outdated))
                    pkg.update("mason", outdated, function()
                        vim.notify(("lvim-installer: updated %d package(s)"):format(#outdated))
                        M.refresh_open()
                    end)
                end,
            },
        }),
        { type = "spacer", name = "mtb_gap", label = "" },
    }
    local mode = tab_mode(tab.id)
    local installed, available = {}, {}
    for _, item in ipairs(items) do
        if pkg_match(item, mode, tab.id, mason_outdated) then
            table.insert(item.installed and installed or available, item)
        end
    end
    state.tab_counts = state.tab_counts or {}
    state.tab_counts[tab.id] = { current = #installed + #available, total = #items }
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
            icon = "󰉋", -- 󰉋
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
            subtitle = { text = "Removes the compiled parser.", type = "warn" },
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
        { "Status", item.installed and (item.outdated and "outdated" or "up to date") or "not installed" },
    }
    if item.version and item.version ~= "" then
        fields[#fields + 1] = { "Version", item.version:sub(1, 12) }
    end
    fields[#fields + 1] = { "Path", ppath }
    local popup_w = math.max(40, math.floor(vim.o.columns * 0.9) - 4)
    local maxv = math.max(24, popup_w - (12 + w))
    for i, fv in ipairs(fields) do
        local vlines = wrap_value(fv[2], maxv)
        children[#children + 1] = {
            type = "action",
            name = "td_" .. item.name .. "_" .. i,
            child = true,
            flat = true, -- no lead type icon: the row carries its own field icon + label in `icon` (matches Plugins)
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
                flat = true,
                icon = string.rep(" ", 8 + w),
                label = vlines[j],
                hl = { inactive = "LvimInstallerDetailValue" },
            }
        end
    end
    local specs
    if item.installed then
        specs = {
            {
                label = "Update",
                key = "U",
                hl = "LvimInstallerActionInstall",
                run = function()
                    parser_action(item.name, "install")
                end,
            },
            {
                label = "Delete",
                key = "D",
                hl = "LvimInstallerActionRemove",
                run = function()
                    parser_action(item.name, "delete")
                end,
            },
        }
    else
        specs = {
            {
                label = "Install",
                key = "I",
                hl = "LvimInstallerActionInstall",
                run = function()
                    parser_action(item.name, "install")
                end,
            },
        }
    end
    children[#children + 1] = item_action_bar("ta_" .. item.name, specs)
    local sicon = item.installed and "" or "" -- filled = installed / hollow = available
    local status_hl = (not item.installed and "LvimInstallerStatusLazy")
        or (item.outdated and "LvimInstallerStatusOutdated")
        or "LvimInstallerStatusLoaded"
    return {
        type = "action",
        name = "ti_" .. item.name,
        flat = true, -- no expand caret: the row carries its own status icon + name in `icon` (matches Plugins)
        icon = "  " .. sicon .. " " .. string.format("%-" .. (w + 4) .. "s", item.name),
        icon_hl = status_hl,
        text_hl = item.outdated and "LvimInstallerUpdateMark" or "LvimInstallerParentValue",
        label = item.outdated and "update" or "",
        children = children,
        expanded = state.expanded["ti_" .. item.name] == true,
    }
end

--- Rows for the Treesitter tab: filter bar + collapsible Installed / Available
--- sections of expandable parser rows (same accordion as the other tabs).
---@param tab table
---@return table[]
local function parser_rows(tab)
    local items = build_items(tab)
    local function outd(x)
        return x.outdated
    end
    local rows = {
        filter_bar(
            tab.id,
            { "All", "Installed", "Available", "Outdated", "Up-to-date", "Search" },
            items,
            function(it, m)
                return pkg_match(it, m, tab.id, outd)
            end
        ),
        action_bar({
            {
                "Check for updates",
                function()
                    require("lvim-installer").update_registry("ts")
                end,
            },
            {
                "Update outdated",
                function()
                    local function collect()
                        local names = {}
                        for _, it in ipairs(build_items(tab)) do
                            if it.outdated then
                                names[#names + 1] = it.name
                            end
                        end
                        return names
                    end
                    local function do_update(names)
                        if #names == 0 then
                            vim.notify("lvim-installer: parsers are up to date")
                            M.refresh_open()
                            return
                        end
                        vim.notify(("lvim-installer: updating %d parser(s)…"):format(#names))
                        pkg.update("parser", names, function()
                            vim.notify(("lvim-installer: updated %d parser(s)"):format(#names))
                            M.refresh_open()
                        end)
                    end
                    local names = collect()
                    if #names > 0 then
                        do_update(names)
                    else
                        -- Nothing known yet — check first (like the plugin Update all), then update.
                        vim.notify("lvim-installer: checking parsers for updates…")
                        pkg.check_parsers_outdated(function()
                            do_update(collect())
                        end)
                    end
                end,
            },
        }),
        { type = "spacer", name = "ts_tb_gap", label = "" },
    }
    local mode = tab_mode(tab.id)
    local installed, available = {}, {}
    for _, item in ipairs(items) do
        if pkg_match(item, mode, tab.id, outd) then
            table.insert(item.installed and installed or available, item)
        end
    end
    state.tab_counts = state.tab_counts or {}
    state.tab_counts[tab.id] = { current = #installed + #available, total = #items }
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
            icon = "󰉋", -- 󰉋
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
            flat = true, -- the row's own 󰆓 icon leads; no extra type glyph (matches the plugin tabs)
            label = "󰆓 Save current state…",
            run = function(_, close)
                if close then
                    close()
                end
                snapshot.save()
            end,
        },
        { type = "spacer", name = "sec_snapshots", label = "Active: " .. active },
    }
    if #snaps == 0 then
        -- Explain WHY it's empty (no snapshot files yet) + what a snapshot is and how to make one.
        for i, line in ipairs({
            "",
            "No snapshots yet. A snapshot freezes every plugin's commit and every",
            "Mason package's version into one named set, so you can switch the whole",
            "version set back later (e.g. save “stable” before a big update, then",
            "restore it if something breaks).",
            "",
            "Use 󰆓 Save current state… above to capture the first one.",
        }) do
            rows[#rows + 1] = { type = "spacer", name = "empty_" .. i, label = line }
        end
        return rows
    end
    for _, name in ipairs(snaps) do
        local marker = name == active and " " or " "
        rows[#rows + 1] = {
            type = "action",
            name = "snap_" .. name,
            flat = true, -- the / marker leads; no extra type glyph
            label = marker .. name,
            run = function(_, close)
                if close then
                    close()
                end
                snapshot.apply(name)
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
    -- Every TABS entry is plugin/mason/parser/snapshot, so one of the branches above always returns.
    return {}
end

--- Open (or re-open) the package-manager browser at a specific tab, in a specific layout.
---@param tab_id? string  the tab to open at (e.g. "LSP", "parser", "plugin")
---@param layout? string  "area"|"float"|"bottom" — overrides config.browser.layout for the session
---@return nil
function M.open(tab_id, layout)
    if tab_id then
        state.active = tab_id
    end
    if layout then
        state.layout = layout -- sticky: a per-command override survives pending re-opens this session
    end
    local ui = ui_mod.get()
    if not ui then
        vim.notify("lvim-installer: lvim-utils UI unavailable", vim.log.levels.ERROR)
        return
    end
    local tabs = {}
    local sel = 1
    for i, tab in ipairs(TABS) do
        tabs[#tabs + 1] = { label = tab.label, icon = config.tab_icons[tab.id], menu = tab.menu, rows = rows_for(tab) }
        if tab.id == state.active then
            sel = i
        end
    end
    -- Keep references so async operations (e.g. update progress) can mutate the
    -- live rows and re-render without closing the window.
    state.tabs = tabs
    state.handle = ui.tabs({
        title = "Package Manager",
        -- The title counter (visible / total for the active tab) — the chassis renders it on the top
        -- border (right-aligned, opposite the title); populated by the row builders into state.tab_counts.
        title_count = function()
            return (state.tab_counts or {})[state.active]
        end,
        tabs = tabs,
        -- How the panel opens: a per-command override (`:LvimInstaller area`) → `config.browser.layout` →
        -- "float". "float" = a centred modal; "area" = the cmdline/minibuffer dock shared by the fzf pickers +
        -- LvimLsp nav; "bottom" = a bottom dock.
        layout = state.layout or (config.browser or {}).layout or "float",
        tab_selector = sel,
        -- Tabs are managed only from the header (press "t"); content keys never jump
        -- to or switch tabs.
        lock_tabs = true,
        -- The bottom key-hint LEGEND (panel keys • focused-row keys), same as the control center.
        footer_hints = true,
        -- Use most of the screen — this is a full browser, not a small prompt.
        width = config.browser.width,
        max_width = config.browser.width,
        height = 0.9,
        max_height = 0.9,
        -- (area layout) the docked row budget — taller than ui.tabs' default 16 for this full browser
        area_height = (config.browser or {}).height or 21,
        -- a BG-only cursorline so the active row keeps its per-part colours (no fg wash)
        cursorline_hl = "LvimUiCursorLine",
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

--- Shared in-row spinner for a long operation, with a final notification — the single
--- feedback style used by plugin / mason / parser ops. Animates a braille spinner on the row
--- named `rowname` labelled "<verb>  <status>"; returns (set_status, finish). set_status(s)
--- updates the trailing status text; finish(msg, level) stops the spinner, re-renders the panel
--- and (when msg is given) shows the result notification. Works even when the row is not found
--- (no spinner, but finish still refreshes + notifies).
---@param rowname string
---@param verb string
---@return fun(s: string), fun(msg?: string, level?: integer)
row_spinner = function(rowname, verb)
    local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
    local row = find_row(rowname)
    local fi, status_txt = 1, verb
    local timer = vim.uv.new_timer()
    local done = false
    local function finish(msg, level)
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
        if msg then
            vim.notify(msg, level)
        end
    end
    if row and timer then
        row.icon_hl = "LvimInstallerProgress"
        row.text_hl = "LvimInstallerProgress"
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
    end
    return function(s)
        status_txt = verb .. "  " .. s
    end, finish
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

--- Install or update one Mason package with a live in-popup spinner.
---@param name string
---@param is_update boolean
---@return nil
function M.mason_op(name, is_update)
    local before = pkg.installed_version(name)
    -- No per-step status: a plain spinner keeps mason consistent with the plugin / parser ops
    -- (which are single git/network calls with nothing granular to report).
    local _, finish = row_spinner("mi_" .. name, is_update and "Updating…" or "Installing…")
    pkg.install("mason", { name }, function()
        local after = pkg.installed_version(name)
        local msg
        if is_update then
            if before and after and tostring(before) == tostring(after) then
                msg = name .. ": already the latest version"
            else
                msg = name .. " → " .. tostring(after or "latest")
            end
        else
            msg = name .. ": installed" .. (after and (" " .. tostring(after)) or "")
        end
        finish(msg)
    end)
end

--- Install one Treesitter parser with a live in-popup spinner.
---@param name string
---@return nil
function M.parser_op(name)
    local _, finish = row_spinner("ti_" .. name, "Installing…")
    pkg.install("parser", { name }, function()
        finish(name .. ": parser installed")
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
                { "done", "󰄬", "LvimInstallerStatusLoaded" },
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

    -- Explicitly-pinned plugins (a fixed tag/commit) are held, so a bulk update skips them.
    local function unpinned(names)
        return vim.tbl_filter(function(n)
            return not pkg.get_pin("plugin", n)
        end, names)
    end

    -- Targets: the known-outdated set; if none known, run a check first.
    local targets = {}
    for _, info in ipairs(pkg.plugins()) do
        if info.outdated and not info.dir then
            targets[#targets + 1] = info.name
        end
    end
    targets = unpinned(targets)
    if #targets > 0 then
        run(targets)
    else
        vim.notify("lvim-installer: checking for updates…")
        pkg.check_outdated(function(found)
            run(unpinned(found))
        end)
    end
end

return M
