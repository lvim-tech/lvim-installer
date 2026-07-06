-- lvim-installer: named highlight groups.
-- Colours come from the shared lvim-utils palette (colors)
-- via a build() factory and are registered through lvim-utils.highlight, exactly
-- like the other lvim-tech plugins (lvim-lsp, lvim-utils). This way every group
-- follows the active lvim-colorscheme palette: re-applied on ColorScheme and
-- rebuilt whenever the palette is synced (colors.on_change).
--
---@module "lvim-installer.highlights"

local colors = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")
local M = {}

--- Build the group → opts map from the CURRENT palette. A function (not a static
--- table) so it re-reads c.* on every call and picks up palette swaps.
---@return table<string, table>
local function build()
    local c = colors
    return {
        -- Toolbar buttons — THREE distinct states: INACTIVE (dim, not selected), HOVER (the keyboard cursor),
        -- ACTIVE (the applied button; set below). Picker-style hierarchy.
        -- The LvimLsp diagnostics "Workspace" (scope) button style — a BLUE family: dim-blue inactive,
        -- blue-bold active AND hover (the cursor = the accent, like the scope button), and the cursor ON the
        -- active button on a subtle 0.3 BLUE BG TINT.
        LvimInstallerToolbar = { fg = c.blend(c.blue, c.bg, 0.6) }, -- inactive: dim blue (mtint blue 0.6)
        LvimInstallerToolbarHover = { fg = c.blue, bold = true }, -- hover: blue bold (the cursor = the accent)
        LvimInstallerToolbarHoverActive = { fg = c.blue, bg = c.blend(c.blue, c.bg, 0.3), bold = true },
        LvimInstallerToolbarIcon = { fg = c.orange },
        -- Section headers ("Loaded (n)" / "Lazy (n)")
        LvimInstallerSection = { fg = c.blue },
        -- Plugin name, by state
        LvimInstallerPluginLoaded = { fg = c.fg },
        LvimInstallerPluginLazy = { fg = c.comment },
        LvimInstallerPluginOutdated = { fg = c.orange },
        -- Plugin status dot, by state
        LvimInstallerStatusLoaded = { fg = c.green },
        LvimInstallerStatusLazy = { fg = c.comment },
        LvimInstallerStatusOutdated = { fg = c.orange },
        -- Parent-row value (plugin load time / mason version) — yellow
        LvimInstallerParentValue = { fg = c.yellow },
        -- Update marker on a parent value when an update is available
        LvimInstallerUpdateMark = { fg = c.orange },
        -- Inline detail rows: field icon + label vs the value
        LvimInstallerDetail = { fg = c.comment },
        LvimInstallerDetailLabel = { fg = c.cyan },
        LvimInstallerDetailValue = { fg = c.purple },
        -- Link-like values (Source URL / Path) — blue
        LvimInstallerLink = { fg = c.blue },
        -- Version / Tracking values — magenta
        LvimInstallerVersion = { fg = c.magenta },
        -- Status value: up to date (green) vs outdated (red)
        LvimInstallerUpToDate = { fg = c.green },
        LvimInstallerOutdated = { fg = c.red },
        -- Inline action rows
        LvimInstallerAction = { fg = c.blue },
        LvimInstallerActionIcon = { fg = c.orange },
        -- Per-button action colours
        LvimInstallerActionInstall = { fg = c.green },
        LvimInstallerActionRemove = { fg = c.red },
        LvimInstallerActionOpen = { fg = c.blue },
        LvimInstallerActionHint = { fg = c.cyan },
        -- Active toolbar button (the APPLIED filter / selected option): blue + bold — the Workspace-button
        -- accent (same hue as the dim inactive + the hover cursor).
        LvimInstallerActive = { fg = c.blue, bold = true },
        -- A plugin row while it is updating / reinstalling
        LvimInstallerProgress = { fg = c.red },
    }
end

M.build = build

--- Register the groups from the current palette and keep them in sync: re-applied
--- on ColorScheme and rebuilt whenever the lvim-utils palette changes.
---@return nil
function M.setup()
    -- lvim-utils is a declared HARD dependency (required at the top of this file), so there is no
    -- fallback path — the highlight API is always present here.
    -- force = true: nothing else defines LvimInstaller* groups, so forcing keeps them correct across
    -- palette swaps (a stale registry entry can't shadow the freshly-built colours).
    hl.register(build(), true)
    hl.setup()
    colors.on_change(function()
        hl.register(build(), true)
    end)
end

return M
