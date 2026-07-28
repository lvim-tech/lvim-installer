-- lvim-installer.bootstrap: first-start / missing-plugin install progress.
-- The host loader (lvim-pack) delegates installation here so it never has to build
-- UI itself: require("lvim-installer.bootstrap").install(specs, opts). This module
-- owns the whole experience — detecting what is missing, theming the panel, the live
-- progress float, and the blocking vim.pack.add that drives it.
--
-- vim.pack.add blocks but pumps the event loop (it waits on an async run), so the
-- PackChangedPre/PackChanged autocmds and the spinner timer fire during the call and
-- the panel updates live as each plugin lands.
--
---@module "lvim-installer.bootstrap"

local M = {}

--- Trace one step of the install, when tracing is on (`LVIM_TRACE=1`). Optional: a missing tracer
--- is silence, never an error — this panel must work without the data hub.
---@param fmt string
---@param ... any
---@return nil
local function trace(fmt, ...)
    local ok, t = pcall(require, "lvim-pkg.trace")
    if ok then
        t.log(fmt, ...)
    end
end

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Names of git plugins not yet cloned into the pack opt dir.
---@param specs table[]  vim.pack specs ({ src, name, version })
---@return string[]
local function missing_plugins(specs)
    local opt_dir = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
    local missing = {}
    for _, spec in ipairs(specs) do
        if vim.fn.isdirectory(opt_dir .. spec.name) == 0 then
            missing[#missing + 1] = spec.name
        end
    end
    return missing
end

--- Load lvim-colorscheme early (when already installed) so the panel is themed
--- instead of using native default highlights. The colorschemes to try come from
--- the caller (no theme names are hard-coded). No-op on the first ever install (the
--- colorscheme is not cloned yet), so default groups are used then.
---@param fallbacks string[]|nil  colorschemes to try, in priority order
local function ensure_theme(fallbacks)
    if vim.g.colors_name and tostring(vim.g.colors_name):match("^lvim%-") then
        return -- already themed
    end
    local opt_dir = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
    if vim.fn.isdirectory(opt_dir .. "lvim-colorscheme") == 0 then
        return -- not installed yet → keep default highlights
    end
    pcall(vim.cmd.packadd, "lvim-colorscheme")
    -- Suppress ColorScheme/User autocmds: the real UI config (heirline, etc.) is not
    -- loaded yet, so firing them now errors and aborts startup. We only want the
    -- highlight groups; the real config re-applies the theme (with events) later.
    local save_ei = vim.o.eventignore
    vim.opt.eventignore:append("ColorScheme")
    vim.opt.eventignore:append("User")
    for _, name in ipairs(fallbacks or {}) do
        if type(name) == "string" and name ~= "" and pcall(vim.cmd, "colorscheme " .. name) then
            break
        end
    end
    vim.o.eventignore = save_ei
end

--- lvim-hud.notify available? (the shared progress interface). False on the very
--- first install when lvim-utils itself has not been cloned yet.
---@return table|nil
local function notify_mod()
    local ok, m = pcall(require, "lvim-hud.notify")
    if ok and m and m.progress_register and m.progress_update then
        return m
    end
    return nil
end

--- Build the panel lines + extmarks (shared layout). marks = { row, s, e, hl_group }.
-- One status row: "  <icon> <name>     <text>". Icons (all 3 bytes): ✓ done, ✗ error,
-- spinner active/building, ○ pending. Appends to `lines`/`marks` (marks use 0-based rows).
local function status_row(lines, marks, spin, name, st, text)
    local icon = (st == "done" and "\xe2\x9c\x93")
        or (st == "error" and "\xe2\x9c\x97")
        or ((st == "building" or st == "active") and spin)
        or "\xe2\x97\x8b"
    local row = #lines
    lines[#lines + 1] = "  " .. icon .. " " .. name .. (text and ("     " .. text) or "")
    local icon_hl = (st == "done" and "String")
        or (st == "error" and "DiagnosticError")
        or ((st == "building" or st == "active") and "Constant")
        or "Comment"
    marks[#marks + 1] = { row, 2, 5, icon_hl }
    marks[#marks + 1] = { row, 6, 6 + #name, "LvimBootstrapName" }
end

--- Render the panel. During the clone phase `build` is nil (sliding window of cloning
--- plugins); during the build phase it is { names, status, done, total } and the clone
--- line collapses to its summary while the per-library build progress is shown.
local function build_lines(missing, status, done_count, total, fi, width, build)
    local spin = FRAMES[fi]
    local done = done_count >= total
    local bar_w = width - 4
    local frac = total > 0 and (done_count / total) or 1
    local filled = math.min(bar_w, math.floor(bar_w * frac + 0.5))
    local bar = ("\xe2\x94\x81"):rep(filled) .. ("\xe2\x94\x80"):rep(bar_w - filled)
    local head = done and string.format("  \xe2\x9c\x93 Installed %d plugins", total)
        or string.format("  %s Installing plugins   %d / %d", spin, done_count, total)
    -- No leading blank line: the notify channel already renders its own header row above
    -- these lines, so a blank here would push everything one row down.
    local lines = { head, "  " .. bar }
    local marks = {}
    marks[#marks + 1] = { 0, 2, 5, (done and "DiagnosticHint") or "String" }
    marks[#marks + 1] = { 0, 5, #lines[1], (done and "LvimBootstrapDone") or "LvimBootstrapHead" }
    local fb = 2 + #("\xe2\x94\x81"):rep(filled)
    marks[#marks + 1] = { 1, 2, fb, "Special" }
    marks[#marks + 1] = { 1, fb, #lines[2], "Comment" }

    if not build then
        -- Clone phase: capped sliding window near the frontier.
        local cap = math.max(1, math.min(total, 7))
        local first = math.max(1, math.min(done_count, total - cap + 1))
        for i = first, math.min(first + cap - 1, total) do
            status_row(lines, marks, spin, missing[i], status[missing[i]])
        end
    else
        -- Build phase: the clone summary stays above; the build header follows directly
        -- (no blank separator row, which read as a stray empty line under the bar).
        local bdone = build.done >= build.total
        local bhead = bdone and string.format("  \xe2\x9c\x93 Built %d native libraries", build.total)
            or string.format("  %s Building native libraries   %d / %d", spin, build.done, build.total)
        local hrow = #lines
        lines[#lines + 1] = bhead
        marks[#marks + 1] = { hrow, 2, 5, (bdone and "DiagnosticHint") or "String" }
        marks[#marks + 1] = { hrow, 5, #bhead, (bdone and "LvimBootstrapDone") or "LvimBootstrapHead" }
        for _, n in ipairs(build.names) do
            local st = build.status[n]
            local text = (st == "building" and "building\xe2\x80\xa6") or (st == "error" and "failed") or nil
            status_row(lines, marks, spin, n, st, text)
        end
    end
    return lines, marks
end

--- Render + install through the shared lvim-hud.notify progress panel (one interface).
---@param specs table[]
---@param missing string[]
---@param nm table
local function run_notify(specs, missing, nm, opts)
    local total = #missing
    local status, pending = {}, {}
    for _, n in ipairs(missing) do
        status[n], pending[n] = "pending", true
    end
    -- Which of the missing plugins carry a build hook (reported by the host loader).
    local has_build = {}
    for _, spec in ipairs(specs) do
        if spec.has_build then
            has_build[spec.name] = true
        end
    end
    local done_count, fi = 0, 1

    -- Bold theme groups (rebuilt on ColorScheme, as in the float path).
    local function bold_of(name, src)
        local h = vim.api.nvim_get_hl(0, { name = src, link = false })
        vim.api.nvim_set_hl(0, name, { fg = h.fg, bold = true })
    end
    local function ensure_groups()
        bold_of("LvimBootstrapHead", "Function")
        bold_of("LvimBootstrapDone", "DiagnosticHint")
        bold_of("LvimBootstrapName", "Type")
    end
    ensure_groups()

    nm.progress_register("lvim-bootstrap", {
        name = "Package Manager",
        icon = "\xf3\xb0\x8f\x97",
        header_hl = "LvimNotifyHeaderInfo",
    })

    local function render()
        local lines, marks = build_lines(missing, status, done_count, total, fi, 52)
        nm.progress_update("lvim-bootstrap", lines, marks)
    end
    render()
    -- THE PANEL IS UP. Whoever put something on screen while waiting for it (the loader's phase
    -- window) is told here, so the two never overlap: before this call there is nothing to see,
    -- after it this panel owns the screen.
    trace("panel: first frame")
    if type(opts.on_visible) == "function" then
        pcall(opts.on_visible)
    end

    local grp = vim.api.nvim_create_augroup("lvim_bootstrap_install", { clear = true })
    local function on_pack(active)
        return function(ev)
            local d = ev.data
            if d and d.spec and pending[d.spec.name] and d.kind == "install" then
                if active then
                    status[d.spec.name] = "active"
                else
                    status[d.spec.name] = "done"
                    pending[d.spec.name] = nil
                    done_count = done_count + 1
                end
                render()
            end
        end
    end
    vim.api.nvim_create_autocmd("PackChangedPre", { group = grp, callback = on_pack(true) })
    vim.api.nvim_create_autocmd("PackChanged", { group = grp, callback = on_pack(false) })
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = grp,
        callback = function()
            ensure_groups()
            render()
        end,
    })

    local timer = vim.uv.new_timer()
    if timer then
        timer:start(
            80,
            80,
            vim.schedule_wrap(function()
                fi = fi % #FRAMES + 1
                render()
            end)
        )
    end

    trace("panel: vim.pack.add START (%d specs, %d missing)", #specs, #missing)
    local add_ok, add_err = pcall(vim.pack.add, specs, { load = false, confirm = false })
    trace("panel: vim.pack.add RETURNED (ok=%s)", tostring(add_ok))

    if timer then
        timer:stop()
        timer:close()
        timer = nil
    end
    -- Any plugin whose clone never landed (no PackChanged → still pending) is an error, NOT done:
    -- leaving done_count = total would render "✓ Installed N plugins" over repos that never cloned
    -- and then run build hooks against missing dirs. done_count already counts only the real installs.
    for _, n in ipairs(missing) do
        if pending[n] then
            status[n] = "error"
            pending[n] = nil
        end
    end
    render()
    if not add_ok then
        nm.notify("lvim-installer: install failed — " .. tostring(add_err), vim.log.levels.ERROR)
    end

    -- Build phase: synchronously run each freshly-installed plugin's build hook (the
    -- authors' convention — e.g. blink.cmp's :pwait()) while the panel shows per-library
    -- "building … ✓ / ✗". A spinner timer keeps the panel animating during a build that
    -- pumps the event loop (pwait); render + redraw also bracket each build.
    local build_names = {}
    for _, n in ipairs(missing) do
        -- Only build plugins that actually cloned (status == "done"): a build hook against a repo
        -- that never landed would fail on a missing dir.
        if has_build[n] and status[n] == "done" then
            build_names[#build_names + 1] = n
        end
    end
    if #build_names > 0 and opts and type(opts.build_runner) == "function" then
        local b = { names = build_names, status = {}, done = 0, total = #build_names }
        for _, n in ipairs(build_names) do
            b.status[n] = "pending"
        end
        local function brender()
            local lines, marks = build_lines(missing, status, done_count, total, fi, 52, b)
            nm.progress_update("lvim-bootstrap", lines, marks)
            pcall(vim.cmd, "redraw")
        end
        local btimer = vim.uv.new_timer()
        if btimer then
            btimer:start(
                80,
                80,
                vim.schedule_wrap(function()
                    fi = fi % #FRAMES + 1
                    brender()
                end)
            )
        end
        -- Run the build loop under pcall so that an error out of brender (nm.progress_update) can NOT
        -- skip the btimer teardown below — otherwise a uv timer would keep firing every 80ms forever,
        -- re-raising inside schedule_wrap. Teardown must be unconditional.
        local loop_ok, loop_err = pcall(function()
            for _, n in ipairs(build_names) do
                b.status[n] = "building"
                brender()
                trace("build: %s start", n)
                local pok, rok = pcall(opts.build_runner, n)
                trace("build: %s returned", n)
                b.status[n] = (pok and rok ~= false) and "done" or "error"
                b.done = b.done + 1
                brender()
            end
        end)
        if btimer then
            btimer:stop()
            btimer:close()
            btimer = nil
        end
        if not loop_ok then
            nm.notify("lvim-installer: build phase error — " .. tostring(loop_err), vim.log.levels.ERROR)
        end
    end

    vim.defer_fn(function()
        pcall(vim.api.nvim_del_augroup_by_id, grp)
        nm.progress_clear("lvim-bootstrap")
    end, 4000)
end

--- Specs in the dependency closure of `roots` (transitive via spec.deps). Used to
--- bootstrap the render set (lvim-utils + colorscheme + their deps) before the panel.
---@param specs table[]
---@param roots string[]
---@return table[]
local function closure_specs(specs, roots)
    local by_name = {}
    for _, sp in ipairs(specs) do
        by_name[sp.name] = sp
    end
    local want = {}
    local function visit(name)
        if want[name] or not by_name[name] then
            return
        end
        want[name] = true
        for _, dep in ipairs(by_name[name].deps or {}) do
            visit(dep:match("([^/]+)$"))
        end
    end
    for _, r in ipairs(roots) do
        visit(r)
    end
    local out = {}
    for _, sp in ipairs(specs) do
        if want[sp.name] then
            out[#out + 1] = sp
        end
    end
    return out
end

--- Install all specs via vim.pack, showing a progress panel for the ones still
--- missing. Always calls vim.pack.add (registering every spec); the panel only
--- appears when something needs cloning. Blocks until the install finishes.
---@param specs table[]  vim.pack specs ({ src, name, version })
---@param opts? { theme_fallbacks?: string[], close_delay?: integer, on_visible?: fun() }
---@return nil
function M.install(specs, opts)
    opts = opts or {}
    -- THE THEME IS THIS MODULE'S CONCERN, not the loader's. lvim-colorscheme owns the active theme
    -- and is not loaded yet at install time, so the name is read from the plain mirror file the
    -- colorscheme writes. The host loader used to read it and pass it in — which made a loader know
    -- about colorschemes; `ensure_theme` already owns the theme here, so the default belongs here
    -- too. A caller that names its own fallbacks still wins.
    if opts.theme_fallbacks == nil then
        local mirror = vim.fn.stdpath("data") .. "/lvim-colorscheme/theme"
        if vim.fn.filereadable(mirror) == 1 then
            local lines = vim.fn.readfile(mirror)
            if lines and lines[1] and lines[1] ~= "" then
                opts.theme_fallbacks = { lines[1] }
            end
        end
    end
    if not specs or #specs == 0 then
        return
    end
    trace("install: enter (%d specs)", #specs)
    local missing = missing_plugins(specs)
    trace("install: %d missing", #missing)
    if #missing == 0 then
        -- Nothing to install. `vim.pack.add` here only RECONCILES — it registers the specs with vim.pack for
        -- later update / build management; it is NOT needed to load the plugins (the host packadd's them).
        -- It costs ~25 ms over the full plugin set on EVERY start, so defer it off the hot startup path to
        -- VeryLazy (the installer UI reads lvim-pkg's own registry, not vim.pack, so nothing waits on this).
        vim.api.nvim_create_autocmd("User", {
            pattern = "VeryLazy",
            once = true,
            callback = function()
                pcall(vim.pack.add, specs, { load = false, confirm = false })
            end,
        })
        return
    end
    trace("install: notify_mod() probe")
    local nm = notify_mod()
    trace("install: notify_mod() -> %s", tostring(nm ~= nil))
    if not nm then
        -- First-ever install: the UI itself is not cloned yet. Bootstrap the render set FIRST,
        -- silently, then render the rest through lvim-hud.notify — the "clone the manager first"
        -- model. lvim-hud is an explicit root: `notify_mod()` needs lvim-hud.notify, and the
        -- published lvim-utils spec doesn't necessarily pull it in transitively (without it the
        -- whole first install falls back to the silent path).
        local ui_specs = closure_specs(specs, { "lvim-utils", "lvim-hud", "lvim-colorscheme" })
        if #ui_specs > 0 then
            -- CLONED WITH PLAIN `git`, NOT `vim.pack.add`. This is the FIRST `vim.pack.add` of the
            -- session, and that call reconciles the WHOLE lockfile — so asking it for three plugins
            -- made it think about all sixty-four first: measured at 10.1 s for three clones, while
            -- the real install of the other sixty took 3.2 s right after. The host loader already
            -- fetches its own bootstrap set this way for exactly this reason; the panel's own
            -- render set is the same case one step further in.
            --
            -- `packadd` afterwards is what `load = true` did for us before.
            local opt_dir = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
            trace("install: UI bootstrap clone START (%d specs)", #ui_specs)
            vim.fn.mkdir(opt_dir, "p")
            for _, spec in ipairs(ui_specs) do
                if vim.fn.isdirectory(opt_dir .. spec.name) == 0 then
                    trace("install: clone %s", spec.name)
                    pcall(
                        vim.fn.system,
                        { "git", "clone", "--filter=blob:none", spec.src, opt_dir .. spec.name }
                    )
                end
                pcall(vim.cmd.packadd, spec.name)
            end
            trace("install: UI bootstrap clone RETURNED")
        end
        nm = notify_mod()
        trace("install: notify_mod() after UI -> %s", tostring(nm ~= nil))
    end
    if nm then
        trace("install: ensure_theme START")
        ensure_theme(opts.theme_fallbacks)
        trace("install: ensure_theme DONE")
        run_notify(specs, missing, nm, opts)
    else
        -- Could not bring up lvim-utils — install silently. No separate float, ever.
        vim.pack.add(specs, { load = false, confirm = false })
    end
end

return M
