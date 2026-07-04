-- lvim-installer: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place, so every
-- require("lvim-installer.config") reader sees the effective values.
--
---@module "lvim-installer.config"

---@class LvimInstallerConfig
---@field popup_global table   Passed verbatim to lvim-ui.new()
---@field prompt       table   Unified prompt appearance (title_icon, snooze_ms, width)
---@field progress     table   Progress channel appearance (name, icon, spinner, header_hl)
---@field update_concurrency integer  Plugins updated at once during "Update all"
---@field ensure_installed string[]  Mason tools to install silently at setup (allowlist)
---@field browser     table   The Package Manager panel: `layout` = "area"|"float"|"bottom"
---@field tab_icons   table<string,string>  Browser tab-bar icons keyed by tab id (Nerd Font glyphs)
---@field action_icons table<string,string>  Inline action-row icons keyed by action label (Nerd Font glyphs)
---@field field_icons  table<string,string>  Inline detail-row icons keyed by field name (Nerd Font glyphs)

---@type LvimInstallerConfig
return {
    -- Mason tools (LSP / DAP / linter / formatter) to install silently at setup.
    ensure_installed = {},
    -- The Package Manager browser (the tabbed panel) — HOW it opens:
    --   "float"  — a centred modal window (width 0.9 of the screen). DEFAULT.
    --   "area"   — the cmdline / minibuffer dock shared by the fzf pickers + LvimLsp nav (grows cmdheight,
    --              chrome/heirline above; the toolbars are C-j/C-k header sectors).
    --   "bottom" — a bottom dock floating over the last rows.
    browser = {
        layout = "float",
        width = 0.9, -- (float layout) fraction of the screen wide
        -- (area layout) the docked content-row budget — it scrolls past this. ~30% taller than ui.tabs' own
        -- default of 16 rows, since this is a full browser rather than a small prompt.
        height = 21,
    },
    -- Browser tab-bar icons, keyed by tab id. Nerd Font glyphs (verified single-width) — override any to taste.
    tab_icons = {
        plugin = "󰏖",
        parser = "󰙅",
        LSP = "󰒋",
        DAP = "󰃤",
        Linter = "󰍉",
        Formatter = "󰉣",
        snapshot = "󰄄",
    },
    -- Per-action icons for the browser's inline action rows (keyed by action label). Real Nerd glyphs.
    action_icons = { Update = "󰑐", Remove = "󰆴", ["Open source URL"] = "󰏌" },
    -- Per-field icons for the browser's inline detail rows (keyed by field name). Real Nerd glyphs.
    field_icons = {
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
    },
    prompt = {
        title_icon = "󰏗 ",
        snooze_ms = 5 * 60 * 1000,
        width = 0.9, -- fraction of the screen wide for BOTH prompt popups (the install offer + the "skipped" decline)
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
        icon_ok = "󰄬",
        icon_error = "󰅖",
        done_ttl = 4000,
    },
    popup_global = {
        -- Passed verbatim to lvim-ui.new() as per-open DEFAULTS. Only lvim-installer-SPECIFIC values live
        -- here — sizing caps (max_width/max_height), max_items, close_keys, position and markview all come from
        -- the SHARED lvim-utils `config.ui` defaults (the presenters read them), so nothing is duplicated or can
        -- drift. (An earlier `height = "auto"` here — the OLD string size model — reached ui.tabs as
        -- `{ fixed = "auto" }` and crashed `axis_size`; the popups auto-fit their content instead.)
        -- No `width` either: the small child popups (Delete/Reinstall/… confirm menus) AUTO-FIT their content.
        -- The BROWSER passes its own `config.browser.width` and the install/decline prompts force their own size,
        -- so nothing here needs a shared fixed width (a leftover 0.8 only forced the confirm menus too wide).
        filetype = "lvim-installer-ui",

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
