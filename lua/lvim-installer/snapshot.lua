-- lvim-installer.snapshot: the version-snapshot selector.
-- Lists the switchable snapshot sets (plugin + Mason versions), switches the active one,
-- and restores ONLY the differences — checks out the pinned commit for each changed
-- plugin and reinstalls each changed Mason package. Plugin code already loaded keeps
-- running until a restart; Mason changes apply immediately.
--
---@module "lvim-installer.snapshot"

local pkg = require("lvim-pkg")
local ui_mod = require("lvim-installer.ui")

local M = {}

--- Confirm + apply the restore for the just-activated snapshot `name`.
---@param name string
local function offer_restore(name)
    local diff = pkg.snapshot_diff()
    local np, nm = #diff.plugins, #diff.mason
    if np == 0 and nm == 0 then
        vim.notify("Snapshot: switched to '" .. name .. "' — nothing to restore.", vim.log.levels.INFO)
        return
    end
    local ui = ui_mod.get()
    if not ui then
        vim.notify("lvim-installer: lvim-utils UI unavailable", vim.log.levels.ERROR)
        return
    end
    local restore = string.format("Restore now  (%d plugins, %d mason)", np, nm)
    local later = "Switch only — apply on restart"
    local items = { restore, later }
    ui.select({
        title = "Restore '" .. name .. "'?",
        items = items,
        callback = function(confirmed, idx)
            local choice = idx and items[idx]
            if not confirmed or not choice then
                return
            end
            if choice == later then
                vim.notify("Snapshot: switched to '" .. name .. "'. Restart Neovim to apply.", vim.log.levels.INFO)
                return
            end
            vim.notify("Snapshot: restoring '" .. name .. "'…", vim.log.levels.INFO)
            pkg.snapshot_restore(diff, function()
                local msg = "Snapshot: restored '" .. name .. "'."
                if np > 0 then
                    msg = msg .. " Restart Neovim to load the new plugin versions."
                end
                vim.schedule(function()
                    vim.notify(msg, vim.log.levels.INFO)
                end)
            end)
        end,
    })
end

--- Capture the current state into a snapshot file. Prompts for a name when none given.
---@param name? string
---@return nil
function M.save(name)
    local function do_save(n)
        n = n and vim.trim(n) or ""
        if n == "" then
            return
        end
        vim.notify("Snapshot: saving current state as '" .. n .. "'…", vim.log.levels.INFO)
        local ok, err = pkg.snapshot_save(n)
        if ok then
            vim.notify("Snapshot: saved '" .. n .. "'.", vim.log.levels.INFO)
        else
            vim.notify("Snapshot: save failed — " .. tostring(err), vim.log.levels.ERROR)
        end
    end
    if name and name ~= "" then
        do_save(name)
    else
        require("lvim-ui").input({
            prompt = "Save current state as snapshot",
            callback = function(confirmed, input)
                if confirmed == true and input then
                    do_save(input)
                end
            end,
        })
    end
end

--- Switch the active snapshot to `name` and offer to restore the differences.
--- Shared by the :LvimInstaller snapshot picker and the browser Snapshots tab.
---@param name string
---@return nil
function M.apply(name)
    if name == pkg.active_snapshot() then
        return
    end
    if not pkg.select_snapshot(name) then
        vim.notify("Snapshot: could not switch to '" .. name .. "'.", vim.log.levels.ERROR)
        return
    end
    offer_restore(name)
end

--- Open the snapshot picker: choose a version set; on switch, offer to restore the diff.
---@return nil
function M.open()
    local snaps = pkg.snapshots()
    if #snaps == 0 then
        vim.notify("No snapshots found in the snapshots directory.", vim.log.levels.WARN)
        return
    end
    local ui = ui_mod.get()
    if not ui then
        vim.notify("lvim-installer: lvim-utils UI unavailable", vim.log.levels.ERROR)
        return
    end
    local active = pkg.active_snapshot()
    local SAVE = "󰆓 Save current state…"
    local items = { SAVE }
    for _, name in ipairs(snaps) do
        items[#items + 1] = (name == active and " " or " ") .. name
    end
    ui.select({
        title = "Snapshot — active: " .. active,
        items = items,
        callback = function(confirmed, idx)
            if not confirmed or not idx then
                return
            end
            if idx == 1 then
                M.save()
            else
                M.apply(snaps[idx - 1])
            end
        end,
    })
end

return M
