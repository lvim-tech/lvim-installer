-- lvim-installer: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place, so every
-- require("lvim-installer.config") reader sees the effective values.
--
---@module "lvim-installer.config"

---@class LvimInstallerConfig
---@field popup_global table   Passed verbatim to lvim-utils.ui.new()
---@field prompt       table   Unified prompt appearance (title_icon, snooze_ms)
---@field progress     table   Progress channel appearance (name, icon, spinner, header_hl)
---@field update_concurrency integer  Plugins updated at once during "Update all"
---@field ensure_installed string[]  Mason tools to install silently at setup (allowlist)
---@field browser     table   The Package Manager panel: `layout` = "area"|"float"|"bottom"

---@type LvimInstallerConfig
return {
    -- Mason tools (LSP / DAP / linter / formatter) to install silently at setup.
    ensure_installed = {},
    -- The Package Manager browser (the tabbed panel) — HOW it opens:
    --   "area"   — the cmdline / minibuffer dock shared by the fzf pickers + LvimLsp nav (grows cmdheight,
    --              chrome/heirline above; the toolbars are C-j/C-k header sectors). DEFAULT.
    --   "float"  — a centred modal window.
    --   "bottom" — a bottom dock floating over the last rows.
    browser = {
        layout = "area",
    },
    prompt = {
        title_icon = "󰏗 ",
        snooze_ms = 5 * 60 * 1000,
    },
    -- How many plugins to update at once during "Update all" (vim.pack has no
    -- concurrency option, so updates run in sequential batches of this size).
    update_concurrency = 4,
    progress = {
        id = "lvim-installer",
        name = "Installer",
        icon = "󰏗",
        header_hl = "LvimNotifyHeaderInfo",
        spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
        icon_ok = "✓",
        icon_error = "✗",
        done_ttl = 4000,
    },
    popup_global = {
        border = { "", "", "", " ", " ", " ", " ", " " },
        position = "editor",
        width = 0.8,
        max_width = 0.8,
        height = "auto",
        max_height = 0.8,
        max_items = 15,
        filetype = "lvim-installer-ui",
        close_keys = { "q", "<Esc>" },
        markview = false,

        icons = {
            bool_on = "󰄬",
            bool_off = "󰍴",
            select = "󰘮",
            number = "󰎠",
            string = "󰬴",
            action = " ",
            spacer = " ",
            expand_closed = " ",
            expand_open = " ",
            multi_selected = "󰄬",
            multi_empty = "󰍴",
            current = "➤",
        },

        labels = {
            navigate = "navigate",
            confirm = "confirm",
            cancel = "cancel",
            close = "close",
            toggle = "toggle",
            cycle = "cycle",
            edit = "edit",
            execute = "execute",
            tabs = "tabs",
        },

        keys = {
            down = "j",
            up = "k",
            confirm = "<CR>",
            cancel = "<Esc>",
            close = "q",
            tabs = { next = "l", prev = "h" },
            select = { confirm = "<CR>", cancel = "<Esc>" },
            multiselect = { toggle = "<Space>", confirm = "<CR>", cancel = "<Esc>" },
            list = { next_option = "<Tab>", prev_option = "<BS>" },
            back = "u",
        },

        highlights = {},
    },
}
