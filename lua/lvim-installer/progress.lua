-- lvim-installer: install progress panel.
-- Drives a named lvim-utils.notify progress channel: one floating panel showing
-- a braille spinner and per-tool status (pending / ok / fail) plus the latest
-- action line.  Falls back to a single vim.notify summary when lvim-utils is
-- unavailable.
--
---@module "lvim-installer.progress"

local config = require("lvim-installer.config")
local M = {}

---@return table|nil
local function notify_mod()
    local ok, m = pcall(require, "lvim-utils.notify")
    return ok and m or nil
end

---@return table  Progress appearance config
local function cfg()
    return config.progress
end

---@type table<string, { status: string, action: string }>
local tools = {}
---@type uv.uv_timer_t|nil
local timer = nil
local frame = 1

--- Build the panel lines from the current tool states.
---@return string[]
local function build_lines()
    local c = cfg()
    local spinner = c.spinner[frame] or c.spinner[1]
    local names = vim.tbl_keys(tools)
    table.sort(names)
    local lines = {}
    for _, name in ipairs(names) do
        local t = tools[name]
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

--- Re-render the progress channel (no-op without lvim-utils).
local function render()
    local nm = notify_mod()
    if not nm or not nm.progress_update then
        return
    end
    local c = cfg()
    if nm.progress_register then
        nm.progress_register(c.id, { name = c.name, icon = c.icon, header_hl = c.header_hl })
    end
    nm.progress_update(c.id, build_lines())
end

--- Begin tracking installation of `names`.
---@param names string[]
---@return nil
function M.start(names)
    tools = {}
    for _, name in ipairs(names) do
        tools[name] = { status = "pending", action = "Queued..." }
    end
    frame = 1
    render()
    if not timer then
        timer = vim.uv.new_timer()
        timer:start(
            0,
            90,
            vim.schedule_wrap(function()
                frame = frame % #cfg().spinner + 1
                render()
            end)
        )
    end
end

--- Update one tool's status/action (matches lvim-pkg mason on_progress).
---@param name   string
---@param status string  "pending" | "ok" | "fail"
---@param action string
---@return nil
function M.update(name, status, action)
    local t = tools[name]
    if not t then
        return
    end
    t.status = status
    t.action = action
    render()
end

--- Finalise: stop the spinner, show a summary, clear the panel after a delay.
---@param results table<string, string|true>
---@param summary? string  Custom summary line (defaults to "Installed N tool(s)").
---@return nil
function M.done(results, summary)
    if timer then
        timer:stop()
        timer:close()
        timer = nil
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
    render()
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
            nm.progress_clear(c.id)
        end
        tools = {}
    end, c.done_ttl)
end

return M
