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

## What it manages

The manager has one tab per installable type. The Mason packages are split by
**category** (a package's `categories` field in the Mason registry), so LSP
servers, debug adapters, linters and formatters each get their own tab and
`:LvimInstaller` argument:

| Tab | `:LvimInstaller` arg | What it installs | Backend |
|---|---|---|---|
| **LSP** | `lsp` | Language servers | `mason` |
| **DAP** | `dap` | Debug adapters | `mason` |
| **Linter** | `linter` | Linters | `mason` |
| **Formatter** | `formatter` | Formatters | `mason` |
| **Treesitter** | `parsers` | Treesitter parsers | `ts` |
| **Plugins** | `plugins` | Neovim plugins (`vim.pack`) | `pack` |

The four Mason tabs share one engine (`lvim-pkg`'s `mason` backend), which
installs from source via npm / pypi / golang / cargo / github — no dependency on
`mason.nvim`.

Per item you can **Install**, **Update**, **Reinstall**, **Remove** and **Pin a
version** (or a git branch / tag / commit for plugins). Failures are surfaced
through the notification history with the real error (e.g. the `go install`
stderr), so installs are debuggable.

## Installation

lvim-installer is the package-manager **UI**. Together with its two required
foundations — [lvim-pkg](https://github.com/lvim-tech/lvim-pkg) (engine) and
[lvim-utils](https://github.com/lvim-tech/lvim-utils) (UI / notify) — these three
are the **bootstrap of the whole ecosystem**: once they load, the manager installs
and manages everything else.

Because the ecosystem *is* the package manager (it installs plugins through
Neovim's built-in **`vim.pack`**), you do **not** need an external plugin manager.
Just clone the three with `vim.pack` and call their `setup()`.

### Bootstrap (vim.pack)

In your `init.lua`. `vim.pack.add` clones the three on first launch; the `setup()`
calls bring the manager online. Load order matters — `lvim-utils` and `lvim-pkg`
are independent and must come before `lvim-installer`, which requires both.

```lua
vim.pack.add({
  "https://github.com/lvim-tech/lvim-utils",
  "https://github.com/lvim-tech/lvim-pkg",
  "https://github.com/lvim-tech/lvim-installer",
})

require("lvim-utils").setup()      -- UI / notify base
require("lvim-pkg").setup()        -- install engine + plugin registry
require("lvim-installer").setup()  -- unified prompt + :LvimInstaller command
```

That is the entire package manager. Open `:LvimInstaller` to install the rest —
LSP servers, linters, formatters, debug adapters, parsers and plugins.

The optional domain plugins ([lvim-ls](https://github.com/lvim-tech/lvim-ls),
[lvim-ts](https://github.com/lvim-tech/lvim-ts),
[lvim-lsp](https://github.com/lvim-tech/lvim-lsp)) are added the same way and feed
the first-open prompt — they are **not** required for the manager itself.

> When lvim-installer is active, run `lvim-ts` with `auto_install = false` so
> parsers are offered through the prompt instead of installing silently.

### LVIM IDE

lvim-installer ships with LVIM IDE (which performs the bootstrap above for you). To
override its options, add to your user module (`lua/modules/user/init.lua`):

```lua
modules["lvim-tech/lvim-installer"] = {
  dependencies = { "lvim-tech/lvim-pkg", "lvim-tech/lvim-utils" },
  opts = {
    -- see Configuration
  },
}
```

## Usage

```vim
:LvimInstaller             " open the manager (last tab)
:LvimInstaller lsp         " open on the LSP tab
:LvimInstaller dap         " open on the DAP tab
:LvimInstaller linter      " open on the Linter tab
:LvimInstaller formatter   " open on the Formatter tab
:LvimInstaller parsers     " open on the Treesitter tab
:LvimInstaller plugins     " open on the Plugins tab

:LvimInstaller update-registry          " force-refresh both catalogues now
:LvimInstaller update-registry mason    " just the Mason catalogue
:LvimInstaller update-registry ts       " just the treesitter parser registry
```

```lua
require("lvim-installer").open("LSP")    -- open the manager at a tab
require("lvim-installer").offer("go")    -- manually offer the prompt for a filetype
```

| Function | Description |
|---|---|
| `setup(opts?)` | Register the unified prompt and the `:LvimInstaller` command. |
| `open(tab?)` | Open the manager at a tab: `"LSP"` \| `"DAP"` \| `"Linter"` \| `"Formatter"` \| `"parser"` \| `"plugin"`. |
| `offer(ft?)` | Manually offer the prompt for a filetype (default: current buffer). |

## Configuration

`setup(opts)` deep-merges into the defaults. The full `LvimInstallerConfig`:

```lua
require("lvim-installer").setup({
  -- Unified first-open prompt appearance / behaviour.
  prompt = {
    title_icon = "󰏗 ",
    snooze_ms  = 5 * 60 * 1000,   -- snooze duration after a plain skip (q / <Esc>)
  },

  -- Mason tools (LSP / DAP / linter / formatter) to install silently at setup.
  ensure_installed = {},   -- e.g. { "lua_ls", "stylua", "ruff" } (allowlist)

  -- How many plugins to update at once during "Update all" (sequential batches).
  update_concurrency = 4,

  -- Progress panel (driven through lvim-utils.notify).
  progress = {
    id = "lvim-installer", name = "Installer", icon = "󰏗",
    header_hl  = "LvimNotifyHeaderInfo",
    spinner    = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    icon_ok    = "✓",
    icon_error = "✗",
    done_ttl   = 4000,
  },

  -- Passed verbatim to lvim-utils.ui.new(): popup geometry, icons, labels, keys.
  popup_global = {
    position = "editor", width = 0.8, height = "auto",
    close_keys = { "q", "<Esc>" },
    -- icons = { ... }, labels = { ... }, keys = { ... }
  },
})
```

| Section | Responsible for |
|---|---|
| `prompt` | the first-open "missing tools" prompt: title icon, snooze duration |
| `update_concurrency` | batch size for "Update all" of plugins |
| `progress` | the install progress panel (name, icon, spinner, done timeout) |
| `popup_global` | the manager / prompt window: geometry, icons, labels, key bindings |

## Part of the LVIM ecosystem

- [lvim-pkg](https://github.com/lvim-tech/lvim-pkg) — the engine (data + install operations)
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) — shared UI / notify
- [lvim-ls](https://github.com/lvim-tech/lvim-ls) — LSP engine (supplies per-filetype tool requirements)
- [lvim-ts](https://github.com/lvim-tech/lvim-ts) — treesitter runtime
