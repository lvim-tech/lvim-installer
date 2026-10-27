-- The first-start panel's own decisions, and the configuration it runs on.
--
-- Almost everything this plugin does needs the network (cloning plugins, Mason tools, treesitter
-- parsers) or a UI, and neither belongs in a suite -- so nothing here installs anything. What CAN
-- be stated is the decision the module took over from the host loader: the theme is this module's
-- concern, read from the plain mirror file lvim-colorscheme writes, and a caller that names its
-- own fallbacks still wins. `install` mutates the opts table it is given, which makes that
-- observable without anything being cloned.

local bootstrap = require("lvim-installer.bootstrap")
local config = require("lvim-installer.config")
local state = require("lvim-installer.state")

--- Write (or remove) the theme mirror lvim-colorscheme leaves for readers that load before it.
---@param theme string|nil
local function theme_mirror(theme)
    local dir = vim.fn.stdpath("data") .. "/lvim-colorscheme"
    local path = dir .. "/theme"
    if theme == nil then
        pcall(vim.fn.delete, path)
        return path
    end
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ theme }, path)
    return path
end

describe("lvim-installer: which theme the first-start panel uses")

it("the theme comes from the mirror file, because the colorscheme is not loaded yet", function()
    theme_mirror("lvim-spec-theme")
    local opts = {}
    bootstrap.install({}, opts)
    eq({ "lvim-spec-theme" }, opts.theme_fallbacks, "a loader should not have to know about colorschemes")
    theme_mirror(nil)
end)

it("a caller that names its own fallbacks still wins", function()
    theme_mirror("lvim-spec-theme")
    local opts = { theme_fallbacks = { "mine", "also-mine" } }
    bootstrap.install({}, opts)
    eq({ "mine", "also-mine" }, opts.theme_fallbacks)
    theme_mirror(nil)
end)

it("no mirror file means no fallback is invented", function()
    theme_mirror(nil)
    local opts = {}
    bootstrap.install({}, opts)
    eq(nil, opts.theme_fallbacks, "the panel then uses the editor's default groups, which is honest")
end)

it("an empty mirror file is not a theme name", function()
    theme_mirror("")
    local opts = {}
    bootstrap.install({}, opts)
    eq(nil, opts.theme_fallbacks)
    theme_mirror(nil)
end)

describe("lvim-installer: installing nothing")

it("an empty spec list is a no-op, not an error", function()
    local ok, err = pcall(bootstrap.install, {}, {})
    truthy(ok, tostring(err))
    local ok_nil = pcall(bootstrap.install, nil, {})
    truthy(ok_nil, "a loader with nothing to install must not be a crash")
end)

it("install can be called with no opts at all", function()
    local ok, err = pcall(bootstrap.install, {})
    truthy(ok, tostring(err))
end)

describe("lvim-installer: the configuration it runs on")

it("the bootstrap block carries the waits the panel depends on", function()
    local b = config.bootstrap
    truthy(type(b.close_delay) == "number" and b.close_delay > 0, "the finished panel has to clear")
    truthy(type(b.build_timeout) == "number" and b.build_timeout > 0, "a silent build hook needs a ceiling")
    truthy(
        b.build_timeout > b.close_delay,
        "a build may well outlast the panel's own close delay, so its ceiling must be the larger"
    )
    truthy(type(b.build_hint) == "string" and b.build_hint ~= "", "the one wait that looks like a hang needs a word")
end)

it("the prompt block snoozes for a real interval and fits on the screen", function()
    local p = config.prompt
    truthy(type(p.snooze_ms) == "number" and p.snooze_ms > 0, "a skip that does not snooze re-asks at once")
    truthy(
        type(p.width) == "number" and p.width > 0 and p.width <= 1,
        "a fraction of the screen: " .. tostring(p.width)
    )
end)

it("updates run in batches of a positive whole number", function()
    local n = config.update_concurrency
    truthy(type(n) == "number" and n >= 1 and n % 1 == 0, "vim.pack has no concurrency option: " .. tostring(n))
end)

it("the progress block names a spinner and both outcome icons", function()
    local pr = config.progress
    truthy(type(pr.spinner) == "table" and #pr.spinner > 1, "one frame is not a spinner")
    for i, frame in ipairs(pr.spinner) do
        truthy(type(frame) == "string" and frame ~= "", "spinner frame " .. i)
        eq(1, vim.fn.strchars(frame), "a spinner frame is one character, or the line jitters as it turns")
    end
    truthy(type(pr.icon_ok) == "string" and pr.icon_ok ~= "")
    truthy(type(pr.icon_error) == "string" and pr.icon_error ~= "")
    truthy(pr.icon_ok ~= pr.icon_error, "success and failure must not look the same")
end)

it("every icon table holds non-empty glyphs", function()
    for _, name in ipairs({ "tab_icons", "action_icons", "field_icons" }) do
        local t = config[name]
        truthy(type(t) == "table" and next(t) ~= nil, name .. " is empty")
        for key, glyph in pairs(t) do
            truthy(type(glyph) == "string" and glyph ~= "", ("%s.%s has no glyph"):format(name, tostring(key)))
        end
    end
end)

describe("lvim-installer: the snooze")

it("the snooze table starts empty and is keyed by filetype", function()
    eq("table", type(state.snoozed))
    state.snoozed["lvim-installer-spec-ft"] = vim.uv.now() + 1000
    truthy(state.snoozed["lvim-installer-spec-ft"] > vim.uv.now(), "an expiry in the future suppresses the prompt")
    state.snoozed["lvim-installer-spec-ft"] = nil
end)
