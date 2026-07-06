-- lvim-installer: :checkhealth lvim-installer
--
-- Checks the UI layer's foundations: its two hard dependencies (lvim-pkg engine,
-- lvim-utils UI/notify), the built-in vim.pack used to manage plugins, the registered
-- :LvimInstaller command, and the config shape. All install/data work is lvim-pkg's
-- (see :checkhealth lvim-pkg).
--
---@module "lvim-installer.health"

local config = require("lvim-installer.config")

local M = {}

function M.check()
    local h = vim.health
    h.start("lvim-installer")

    -- ── core ──────────────────────────────────────────────────────────────────
    if vim.fn.has("nvim-0.12") == 1 then
        h.ok("Neovim >= 0.12")
    else
        h.error("Neovim >= 0.12 is required (the plugin backend is built on vim.pack)")
    end
    if type(vim.pack) == "table" and type(vim.pack.add) == "function" then
        h.ok("built-in vim.pack available (plugin install / update / remove)")
    else
        h.error("vim.pack not available — Neovim >= 0.12 is required for the plugin backend")
    end

    -- ── hard dependencies ─────────────────────────────────────────────────────
    local ok_pkg, pkg = pcall(require, "lvim-pkg")
    if ok_pkg and type(pkg.install) == "function" then
        h.ok("lvim-pkg found (the engine: data resolution + install operations)")
    else
        h.error("lvim-pkg not found — required: it performs all data + install/update/remove work")
    end
    local ok_utils = pcall(require, "lvim-utils.utils")
    if ok_utils then
        h.ok("lvim-utils found (UI / notify base)")
    else
        h.error("lvim-utils not found — required for the prompt / manager UI and notifications")
    end

    -- ── command ───────────────────────────────────────────────────────────────
    if vim.fn.exists(":LvimInstaller") == 2 then
        h.ok(":LvimInstaller command registered")
    else
        h.warn(":LvimInstaller not registered — call require('lvim-installer').setup()")
    end

    -- ── dock integration ──────────────────────────────────────────────────────
    -- The browser docks through the shared lvim-utils dock stack when `dock_stack` is true (cyclable
    -- <Leader>n/p/x/m, one-visible-per-layout); false = geometry-only standalone. Either way its size comes
    -- from the central dock geometry, so the dock module presence is worth reporting.
    local ok_dock = pcall(require, "lvim-utils.dock")
    if ok_dock then
        h.ok(
            ("dock: lvim-utils.dock found — browser opens %s"):format(
                config.dock.dock_stack ~= false and "as a managed stack consumer (dock_stack=true)"
                    or "standalone (dock_stack=false)"
            )
        )
    else
        h.warn("dock: lvim-utils.dock not found — the browser opens un-managed (no stack cycling)")
    end

    -- ── config shape ──────────────────────────────────────────────────────────
    local ei_ok = type(config.ensure_installed) == "table"
    local uc_ok = type(config.update_concurrency) == "number"
    if ei_ok and uc_ok and type(config.popup_global) == "table" then
        h.ok(
            ("config: ensure_installed=%d tool(s), update_concurrency=%d"):format(
                #config.ensure_installed,
                config.update_concurrency
            )
        )
    else
        h.warn("config: expected ensure_installed:string[], update_concurrency:number, popup_global:table")
    end
end

return M
