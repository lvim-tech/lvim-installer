-- lvim-installer: install progress panel.
-- Drives a named lvim-hud.notify progress channel: one floating panel showing
-- a braille spinner and per-tool status (pending / ok / fail) plus the latest
-- action line.  Falls back to a single vim.notify summary when lvim-hud is
-- unavailable.
--
-- Each flow gets its OWN session (its own tools/timer and a UNIQUE channel id):
-- the prompt's mason install and an `update-registry` can run at the same time, and a
-- module-level singleton would let one flow's start() wipe the other's rows and its
-- done() stop the shared timer / clear the shared panel mid-install.  A session is
-- returned by `M.start` and threaded through `update` / `done` by the caller.
--
---@module "lvim-installer.progress"

local config = require("lvim-installer.config")
local M = {}

---@return table|nil
local function notify_mod()
    local ok, m = pcall(require, "lvim-hud.notify")
    return ok and m or nil
end

---@return table  Progress appearance config
local function cfg()
    return config.progress
end

-- Monotonic suffix so two concurrent flows register DISTINCT lvim-hud channels
-- (otherwise both would render into the same panel and clobber each other).
local seq = 0

---@class LvimInstallerProgressSession
---@field id    string                                         the lvim-hud channel id (base id + "#" + seq)
---@field tools table<string, { status: string, action: string }>
---@field names string[]                                       sorted tool names, fixed for the session's life
---@field timer uv.uv_timer_t|nil
---@field frame integer

--- Build the panel lines for a session from its current tool states.
---@param s LvimInstallerProgressSession
---@return string[]
local function build_lines(s)
    local c = cfg()
    local spinner = c.spinner[s.frame] or c.spinner[1]
    local lines = {}
    -- `s.names` is pre-sorted once at start (the tool set never changes), so no per-tick sort.
    for _, name in ipairs(s.names) do
        local t = s.tools[name]
        local mark = (t.status == "ok" and c.icon_ok) or (t.status == "fail" and c.icon_error) or spinner
        -- Leading space so the row is not flush against the panel's left edge (matches the
        -- lsp progress panel's " <icon> " layout).
        local line = string.format(" %s %s", mark, name)
        if t.action and t.action ~= "" and t.status == "pending" then
            line = line .. "  — " .. t.action
        end
        lines[#lines + 1] = line
    end
    return lines
end

--- Re-render a session's channel (no-op without lvim-hud).
---@param s LvimInstallerProgressSession
---@return nil
local function render(s)
    local nm = notify_mod()
    if not nm or not nm.progress_update then
        return
    end
    nm.progress_update(s.id, build_lines(s))
end

--- Whether any tool is still animating (pending). A fully settled panel needn't re-render.
---@param s LvimInstallerProgressSession
---@return boolean
local function any_pending(s)
    for _, t in pairs(s.tools) do
        if t.status == "pending" then
            return true
        end
    end
    return false
end

--- Update one tool's status/action (matches lvim-pkg mason on_progress).
---@param s      LvimInstallerProgressSession
---@param name   string
---@param status string  "pending" | "ok" | "fail"
---@param action string
---@return nil
local function session_update(s, name, status, action)
    local t = s.tools[name]
    if not t then
        return
    end
    t.status = status
    t.action = action
    render(s)
end

--- Finalise a session: stop its spinner, show a summary, clear its panel after a delay.
---@param s        LvimInstallerProgressSession
---@param results  table<string, string|true>
---@param summary? string  Custom summary line (defaults to "Installed N tool(s)").
---@return nil
local function session_done(s, results, summary)
    if s.timer then
        s.timer:stop()
        s.timer:close()
        s.timer = nil
    end
    local nm = notify_mod()
    local ok_n, fail_n = 0, 0
    for name, value in pairs(results) do
        if value == true then
            ok_n = ok_n + 1
        else
            fail_n = fail_n + 1
            -- Surface the real failure reason (e.g. the `go install` stderr) instead of a
            -- bare "N failed", so installs are debuggable.
            local emsg = name .. ": " .. tostring(value)
            if nm and nm.notify then
                nm.notify(emsg, vim.log.levels.ERROR)
            else
                vim.notify(emsg, vim.log.levels.ERROR)
            end
        end
    end
    render(s)
    local c = cfg()
    local msg = summary and (summary .. (fail_n > 0 and (", " .. fail_n .. " failed") or ""))
        or string.format("Installed %d tool(s)%s", ok_n, fail_n > 0 and (", " .. fail_n .. " failed") or "")
    local level = fail_n > 0 and vim.log.levels.WARN or vim.log.levels.INFO
    if nm and nm.notify then
        nm.notify(msg, level)
    else
        vim.notify(msg, level)
    end
    vim.defer_fn(function()
        if nm and nm.progress_clear then
            nm.progress_clear(s.id)
        end
        s.tools = {}
    end, c.done_ttl)
end

--- Begin tracking installation of `names`. Returns a session handle whose `update` / `done`
--- operate on THIS flow's panel only (so concurrent flows never clobber each other).
---@param names string[]
---@return { update: fun(name: string, status: string, action: string), done: fun(results: table<string, string|true>, summary?: string) }
function M.start(names)
    seq = seq + 1
    local c = cfg()
    ---@type LvimInstallerProgressSession
    local s = { id = c.id .. "#" .. seq, tools = {}, names = {}, timer = nil, frame = 1 }
    for _, name in ipairs(names) do
        s.tools[name] = { status = "pending", action = "Queued..." }
        s.names[#s.names + 1] = name
    end
    table.sort(s.names)
    -- Register the panel ONCE (not on every render), then draw the first frame.
    local nm = notify_mod()
    if nm and nm.progress_register then
        nm.progress_register(s.id, { name = c.name, icon = c.icon, header_hl = c.header_hl })
    end
    render(s)
    s.timer = vim.uv.new_timer()
    s.timer:start(
        0,
        90,
        vim.schedule_wrap(function()
            -- Only advance + re-render while something is still pending; a settled panel is left alone.
            if not any_pending(s) then
                return
            end
            s.frame = s.frame % #cfg().spinner + 1
            render(s)
        end)
    )
    return {
        update = function(name, status, action)
            session_update(s, name, status, action)
        end,
        done = function(results, summary)
            session_done(s, results, summary)
        end,
    }
end

return M
