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
local snapshot = require("lvim-installer.snapshot")

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

    -- Offer missing installs (LSP tools + parsers) only when a REAL file buffer is shown to the user IN A REAL
    -- WINDOW. "Real" = a normal file buffer (`buftype == ""`; every scratch / preview / terminal buffer has a
    -- non-empty buftype) that is displayed in a NON-preview window. A finder PREVIEW that shows the actual file
    -- buffer (the qf/loc browser's EDITABLE preview is the real buffer, so `buftype == ""` too) lives in a
    -- `previewwindow` — it must NOT prompt; the offer is for files the user actually opened to edit. The window
    -- test is deferred one tick so the buffer has settled into its window(s): a `FileType` during the preview's
    -- `bufload` fires BEFORE its `win_set_buf`, so a synchronous check would miss the preview window.
    local function maybe_offer(buf)
        if not (buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "") then
            return
        end
        local ft = vim.bo[buf].filetype
        if ft == "" then
            return
        end
        vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(buf) then
                return
            end
            for _, w in ipairs(vim.fn.win_findbuf(buf)) do
                if not vim.wo[w].previewwindow then
                    prompt.offer(ft) -- shown in a real window → a file the user opened (offer is deduped + snoozed)
                    return
                end
            end
        end)
    end
    -- FileType covers a fresh open; BufWinEnter covers opening a file the preview already loaded (no new
    -- FileType then). `prompt.offer` dedupes by filetype, so the two triggers can't double-prompt.
    vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
        desc = "Offer missing LSP/parser installs (unified prompt)",
        group = vim.api.nvim_create_augroup("lvim_installer", { clear = true }),
        callback = function(args)
            maybe_offer(args.buf)
        end,
    })

    -- Cover buffers already loaded + shown before the autocmd was registered (real file buffers only — above).
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            maybe_offer(buf)
        end
    end

    -- :LvimInstaller [lsp|dap|linter|formatter|parsers|plugins] — open the manager at a
    -- specific tab. :LvimInstaller update-registry [mason|ts|plugin|all] — refresh the
    -- catalogues and run the update checks (through the progress panel).
    vim.api.nvim_create_user_command("LvimInstaller", function(cmd)
        local args = cmd.fargs
        if args[1] == "update-registry" then
            M.update_registry(args[2] or "all")
            return
        end
        if args[1] == "snapshot" then
            if args[2] == "save" then
                snapshot.save(args[3])
            else
                snapshot.open()
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
        -- A `float`/`area`/`bottom` token (anywhere in the args) overrides the open layout; the other token is
        -- the tab. So `:LvimInstaller float`, `:LvimInstaller plugins float`, `:LvimInstaller float lsp` all work.
        local layouts = { float = true, area = true, bottom = true }
        local tab, layout
        for _, a in ipairs(args) do
            if layouts[a] then
                layout = a
            elseif map[a] then
                tab = map[a]
            end
        end
        M.open(tab, layout)
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
            return starts({
                "lsp",
                "dap",
                "linter",
                "formatter",
                "parsers",
                "plugins",
                "float",
                "area",
                "bottom",
                "snapshot",
                "update-registry",
            })
        end,
        desc = "Open the lvim package manager [tab] [float|area|bottom] / snapshot / update-registry",
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

--- Open the package manager window at a specific tab, in a specific layout.
---@param tab? "LSP"|"DAP"|"Linter"|"Formatter"|"parser"|"plugin"|"snapshot"  Initial tab
---@param layout? "area"|"float"|"bottom"  Overrides config.browser.layout for this session
---@return nil
function M.open(tab, layout)
    browser.open(tab, layout)
end

return M
