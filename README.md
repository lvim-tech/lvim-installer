# lvim-installer

The **UI layer** of the LVIM package ecosystem. It owns two things and delegates
everything else to [lvim-pkg](https://github.com/lvim-tech/lvim-pkg):

1. **The unified install prompt** — when a filetype is opened for the first time,
   it offers the LSP servers, debug adapters, linters, formatters and treesitter
   parsers that filetype needs but does not yet have, as a tabbed checklist grouped
   by category. Footer buttons (fired by their key) **install all**, **install only
   the checked**, or **cancel**. Skipped packages can be remembered as **declined**
   for that filetype — persisted in `lvim-pkg`'s database and never re-offered — or
   just snoozed.
2. **The package manager window** (`:LvimInstaller`) — a browsable UI to install,
   update, remove and pin packages, parsers and plugins.

lvim-installer only renders and orchestrates; all data resolution and the actual
install / update / remove work is performed by `lvim-pkg`.

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-installer/blob/main/LICENSE)

## What it manages

The manager has one tab per installable type. The Mason packages are split by
**category** (a package's `categories` field in the Mason registry) — one tab per
category the registry defines, so nothing in the registry is unbrowsable:

| Tab | `:LvimInstaller` arg | What it installs | Backend |
|---|---|---|---|
| **LSP** | `lsp` | Language servers | `mason` |
| **DAP** | `dap` | Debug adapters | `mason` |
| **Linter** | `linter` | Linters | `mason` |
| **Formatter** | `formatter` | Formatters | `mason` |
| **Runtime** | `runtime` | Runtimes / SDK-side helpers | `mason` |
| **Compiler** | `compiler` | Compilers / build tools | `mason` |
| **Treesitter** | `parsers` | Treesitter parsers | `ts` |
| **Plugins** | `plugins` | Neovim plugins (`vim.pack`) | `pack` |

The six Mason tabs share one engine (`lvim-pkg`'s `mason` backend), which
installs from source via npm / pypi / golang / cargo / github — no dependency on
`mason.nvim`.

Per item you can **Install**, **Update**, **Reinstall**, **Remove** and **Pin a
version** (or a git branch / tag / commit for plugins). Failures are surfaced
through the notification history with the real error (e.g. the `go install`
stderr), so installs are debuggable.

The row keys are `i` install, `u` update, `r` reinstall, `d` delete, `b` browse (each also in its
uppercase twin). **`g?`** — or the **`help` chip** on the footer legend — opens the keymap CHEATSHEET,
built from the live `browser.keys` config, so a rebind shows up in it.

## Installation

lvim-installer is the package-manager **UI**. Together with its two required
foundations — [lvim-pkg](https://github.com/lvim-tech/lvim-pkg) (engine) and
[lvim-utils](https://github.com/lvim-tech/lvim-utils) (UI / notify) — these three are
the **bootstrap of the whole ecosystem**: once they load, the manager installs and
manages everything else. Because the ecosystem *is* the package manager (it installs
plugins through Neovim's built-in **`vim.pack`**), you do **not** need an external
plugin manager — the **lvim-installer (recommended)** bootstrap below is the intended one.

### lvim-installer (recommended)

lvim-installer **is** the package manager: once the bootstrap trio loads it installs,
updates, pins and removes every other plugin (and self-updates) from the **Plugins** tab
through Neovim's built-in `vim.pack` (via lvim-pkg) — no external plugin manager needed.
Bootstrap the trio with the **Native (vim.pack)** snippet below, then manage everything
else from the manager:

```vim
:LvimInstaller plugins
```

### Native (vim.pack)

This is the whole package manager — no external plugin manager needed. Bootstrap the
trio in order (`lvim-utils` and `lvim-pkg` are independent and must come before
`lvim-installer`, which requires both); the installer then manages everything else.

```lua
-- In your init.lua. vim.pack.add clones the three on first launch.
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-pkg" },
    { src = "https://github.com/lvim-tech/lvim-installer" },
})

require("lvim-utils").setup() -- UI / notify base
require("lvim-pkg").setup() -- install engine + plugin registry
require("lvim-installer").setup() -- unified prompt + :LvimInstaller command
```

Then open `:LvimInstaller` to install the rest — LSP servers, linters, formatters,
debug adapters, parsers and plugins. The optional domain plugins
([lvim-ls](https://github.com/lvim-tech/lvim-ls),
[lvim-ts](https://github.com/lvim-tech/lvim-ts),
[lvim-lsp](https://github.com/lvim-tech/lvim-lsp)) are added the same way and feed the
first-open prompt.

> For a full distribution-style loader (lazy-loading, version snapshots, build hooks)
> built on this bootstrap, see the `core/pack.lua` pattern in the LVIM IDE config: it
> git-clones the trio on first run (so the first `vim.pack.add` does not reconcile the
> whole lockfile), then drives per-plugin install / build through `:LvimInstaller`.

> When lvim-installer is active, run `lvim-ts` with `auto_install = false` so parsers
> are offered through the prompt instead of installing silently.

## Usage

```vim
:LvimInstaller             " open the manager (last tab)
:LvimInstaller lsp         " open on the LSP tab
:LvimInstaller dap         " open on the DAP tab
:LvimInstaller linter      " open on the Linter tab
:LvimInstaller formatter   " open on the Formatter tab
:LvimInstaller parsers     " open on the Treesitter tab
:LvimInstaller plugins     " open on the Plugins tab

" Layout tokens (default is config.browser.layout). A token can be given alone or
" combined with a tab, in any order — the layout sticks for the rest of the session.
:LvimInstaller float          " a centred floating window
:LvimInstaller area           " the cmdline / minibuffer dock
:LvimInstaller bottom         " a bottom dock over the last rows
:LvimInstaller plugins float  " a tab + a layout (either order works)

:LvimInstaller update-registry          " refresh all catalogues + run all checks (default)
:LvimInstaller update-registry mason    " just the Mason catalogue
:LvimInstaller update-registry ts       " just the treesitter parser registry + parser check
:LvimInstaller update-registry plugin   " just the plugin outdated check
:LvimInstaller update-registry all      " everything (explicit)

:LvimInstaller snapshot                 " open the snapshots tab
:LvimInstaller snapshot save            " save the current state as a snapshot
```

```lua
require("lvim-installer").open("LSP") -- open the manager at a tab
require("lvim-installer").open("plugin", "float") -- open at a tab in a specific layout
require("lvim-installer").offer("go") -- manually offer the prompt for a filetype
```

| Function | Description |
|---|---|
| `setup(opts?)` | Register the unified prompt and the `:LvimInstaller` command. |
| `open(tab?, layout?)` | Open the manager at a tab (`"LSP"` \| `"DAP"` \| `"Linter"` \| `"Formatter"` \| `"parser"` \| `"plugin"` \| `"snapshot"`) in an optional layout (`"float"` \| `"area"` \| `"bottom"`). |
| `offer(ft?)` | Manually offer the prompt for a filetype (default: current buffer). |
| `update_registry(which?)` | Refresh catalogues + run update checks (`mason` \| `ts` \| `plugin` \| `all`; default `all`). |

## Configuration

`setup(opts)` deep-merges into the defaults. The full `LvimInstallerConfig`:

```lua
require("lvim-installer").setup({
    -- Unified first-open prompt appearance / behaviour.
    prompt = {
        title_icon = "󰏗 ",
        snooze_ms = 5 * 60 * 1000, -- snooze duration after a plain skip (q / <Esc>)
        width = 0.9, -- fraction of the screen wide for both prompt popups
    },

    -- The Package Manager panel's border-title: its text and alignment ("left" | "center" | "right").
    -- Layout-independent — float / area / bottom all render it the same (centered by default).
    title = "Package Manager",
    title_pos = "center",

    -- The package-manager browser: how it opens. Its slot size (float width/height, area / bottom height)
    -- comes from the central lvim-utils dock geometry, edited from control-center's "Utils" panel.
    browser = {
        layout = "float", -- "float" (centred modal) | "area" (cmdline/minibuffer dock) | "bottom" (bottom dock)
        -- The browser's row-action keys (each also bound in its UPPERCASE twin, so the shortcut never
        -- depends on Shift) and the cheatsheet chord. The `g?` help window is built from THIS table.
        keys = {
            help = "g?", -- the keymap CHEATSHEET (also a `help` chip on the footer legend)
            reinstall = "r",
            install = "i",
            update = "u",
            delete = "d",
            browse = "b",
        },
    },

    -- Dock integration, namespaced under `dock` (matching lvim-dependencies' config.dock.*).
    dock = {
        -- true = the browser is a full dock-STACK consumer (managed: cyclable <Leader>n/p/x/m, :LvimDock,
        -- one-visible-per-layout, no overlap with other docked UIs); false = geometry-only (still sized + backdropped
        -- by the central dock.slot, but opens standalone, NOT registered in the stack). As a managed consumer the
        -- dock keys the browser per (id, layout), so it can be docked in float, area AND bottom at once — one live
        -- window / one dock entry PER layout — while re-opening the SAME layout just re-shows that one window.
        dock_stack = true,

        -- Per-layout ANCHORED geometry overrides, deep-merged per field over the global
        -- lvim-utils.config.dock.geometry.<layout>; an empty {} inherits the global unchanged. Each layout may carry:
        -- height, height_auto, backdrop = { enabled, mode, dim = { amount }, darken = { amount } }, auto_hide,
        -- keep_focus. FLOAT ALSO: width, width_auto. area / bottom are ALWAYS full-width (width ignored). Applies in
        -- BOTH dock_stack modes.
        force = { float = {}, area = {}, bottom = {} },
    },

    -- Browser tab-bar icons, keyed by tab id (Nerd Font glyphs).
    tab_icons = {
        plugin = "󰏖",
        parser = "󰙅",
        LSP = "󰒋",
        DAP = "󰃤",
        Linter = "󰍉",
        Formatter = "󰉣",
        snapshot = "󰄄",
    },

    -- Per-action icons for the browser's inline action rows, keyed by action label.
    action_icons = { Update = "󰑐", Remove = "󰆴", ["Open source URL"] = "󰏌" },

    -- Per-field icons for the browser's inline detail rows, keyed by field name
    -- (Status, State, Version, Source, Path, Installed, Latest, … — see config.lua for the full set).
    field_icons = { Status = "󰑐", Version = "󰓹", Source = "󰘬", Path = "󰉋" },

    -- Mason tools (LSP / DAP / linter / formatter) to install silently at setup.
    ensure_installed = {}, -- e.g. { "lua_ls", "stylua", "ruff" } (allowlist)

    -- How many plugins to update at once during "Update all" (sequential batches).
    update_concurrency = 4,

    -- The first-start install panel (not the browser).
    bootstrap = {
        close_delay = 4000, -- ms the finished panel stays on screen
        build_timeout = 10 * 60 * 1000, -- ceiling on waiting for an async build hook to report
        build_hint = "compiling native code — this runs once",
    },

    -- Progress panel (driven through lvim-utils.notify).
    progress = {
        id = "lvim-installer",
        name = "Installer",
        icon = "󰏗",
        header_hl = "LvimNotifyHeaderInfo",
        spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
        icon_ok = "󰄬",
        icon_error = "󰅖",
        done_ttl = 4000,
    },

    -- Passed verbatim to lvim-utils.ui.new(): popup geometry, icons, labels, keys.
    popup_global = {
        position = "editor",
        width = 0.8,
        height = "auto",
        close_keys = { "q", "<Esc>" },
        -- icons = { ... }, labels = { ... }, keys = { ... }
    },
})
```

| Section | Responsible for |
|---|---|
| `prompt` | the first-open "missing tools" prompt: title icon, snooze duration, width |
| `browser` | how the manager opens: `layout` (`float` \| `area` \| `bottom`); its size comes from the central lvim-utils dock geometry |
| `dock.dock_stack` | `true` = managed dock-stack consumer (cyclable `<Leader>n/p/x/m`, `:LvimDock`, one-visible-per-layout; keyed per `(id, layout)` so it can be docked in float, area AND bottom at once — one window per layout); `false` = geometry-only standalone (not in the stack) |
| `dock.force` | per-layout anchored geometry overrides (`float`/`area`/`bottom`) deep-merged over the central dock geometry; empty `{}` inherits it. Applies in both `dock_stack` modes |
| `tab_icons` | the browser tab-bar icons, keyed by tab id |
| `action_icons` | the browser's inline action-row icons, keyed by action label |
| `field_icons` | the browser's inline detail-row icons, keyed by field name |
| `update_concurrency` | batch size for "Update all" of plugins |
| `bootstrap` | the first-start install panel: how long the finished panel lingers (`close_delay`), how long the build phase waits for a build hook to report back (`build_timeout`), and the line shown while a native build runs (`build_hint`). The build phase is asynchronous — the panel holds each row at "building …" until the hook answers, and never closes over a running build |
| `progress` | the install progress panel (name, icon, spinner, done timeout) |
| `popup_global` | the manager / prompt window: geometry, icons, labels, key bindings |

## Part of the LVIM ecosystem

- [lvim-pkg](https://github.com/lvim-tech/lvim-pkg) — the engine (data + install operations)
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) — shared UI / notify
- [lvim-ls](https://github.com/lvim-tech/lvim-ls) — LSP engine (supplies per-filetype tool requirements)
- [lvim-ts](https://github.com/lvim-tech/lvim-ts) — treesitter runtime
