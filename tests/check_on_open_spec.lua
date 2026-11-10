-- The panel checks every tab on its first open in a session.
--
-- It used to open with "Outdated 0" everywhere until "Check for updates" was pressed, which read as "all up
-- to date" when it meant "not checked". The first open now runs the catalogue refresh and every update check
-- in the background, once per session, with no progress panel.

local config = require("lvim-installer.config")

--- A fresh copy of the module (the "already checked" flag is per module load), with update_registry stubbed.
---@return table installer, table calls
local function fresh()
    package.loaded["lvim-installer"] = nil
    local installer = require("lvim-installer")
    local calls = {}
    installer.update_registry = function(which, opts)
        calls[#calls + 1] = { which = which, quiet = opts and opts.quiet }
    end
    return installer, calls
end

local function settle()
    vim.wait(200, function()
        return false
    end, 10)
end

describe("lvim-installer: checking every tab on the first open")

it("the first open checks everything, quietly; later opens do not", function()
    local installer, calls = fresh()
    eq(true, installer.check_on_open())
    eq(false, installer.check_on_open(), "once per session")
    settle()
    eq({ { which = "all", quiet = true } }, calls)
end)

it("check_on_open = false turns it off", function()
    local saved = config.check_on_open
    config.check_on_open = false
    local installer, calls = fresh()
    local started = installer.check_on_open()
    config.check_on_open = saved
    settle()
    eq(false, started)
    eq({}, calls)
end)

it("a quiet check opens no progress panel", function()
    package.loaded["lvim-installer"] = nil
    local installer = require("lvim-installer")
    local progress = require("lvim-installer.progress")
    local pkg = require("lvim-pkg")
    local saved = { start = progress.start, check = pkg.check_outdated }
    local panels = 0
    progress.start = function(...)
        panels = panels + 1
        return saved.start(...)
    end
    local checked = false
    pkg.check_outdated = function(cb)
        checked = true
        cb({})
    end
    local ok, err = pcall(function()
        installer.update_registry("plugin", { quiet = true })
        vim.wait(1000, function()
            return checked
        end, 10)
    end)
    progress.start, pkg.check_outdated = saved.start, saved.check
    if not ok then
        error(err, 0)
    end
    eq(true, checked, "the check ran")
    eq(0, panels, "without a panel")
end)

describe("lvim-installer: what needs updating comes first")

it("outdated items lead each section, both parts keep their order", function()
    local browser = require("lvim-installer.browser")
    local list = {
        { name = "a", out = false },
        { name = "b", out = true },
        { name = "c", out = false },
        { name = "d", out = true },
    }
    local got = browser.outdated_first(list, function(it)
        return it.out
    end)
    eq(
        { "b", "d", "a", "c" },
        vim.tbl_map(function(it)
            return it.name
        end, got)
    )
    eq(
        {},
        browser.outdated_first({}, function()
            return true
        end)
    )
end)

describe("lvim-installer: how a dev checkout is shown")

it("marks and words for behind, ahead and dirty", function()
    local browser = require("lvim-installer.browser")
    eq("", browser.local_marks({}))
    eq("↓2 ↑3 ●", browser.local_marks({ behind = 2, ahead = 3, dirty = true }))
    eq("↓?", browser.local_marks({ behind = "?", ahead = 0, dirty = false }))
    eq("local checkout (not checked)", browser.local_status({}))
    eq("level with origin", browser.local_status({ behind = 0, ahead = 0, dirty = false }))
    eq(
        "2 behind origin, 3 not pushed, uncommitted changes",
        browser.local_status({ behind = 2, ahead = 3, dirty = true })
    )
    eq("behind origin (not fetched)", browser.local_status({ behind = "?", ahead = 0, dirty = false }))
end)
