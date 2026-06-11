-- lvim-installer.snapshot: the version-snapshot selector.
-- Lists the switchable snapshot sets (plugin + Mason versions), switches the active one,
-- and restores ONLY the differences — checks out the pinned commit for each changed
-- plugin and reinstalls each changed Mason package. Plugin code already loaded keeps
-- running until a restart; Mason changes apply immediately.
--
---@module "lvim-installer.snapshot"

local pkg = require("lvim-pkg")

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
	local restore = string.format("Restore now  (%d plugins, %d mason)", np, nm)
	local later = "Switch only — apply on restart"
	vim.ui.select({ restore, later, "Cancel" }, {
		prompt = "Restore differences for '" .. name .. "'?",
	}, function(choice)
		if not choice or choice == "Cancel" then
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
	end)
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
	local active = pkg.active_snapshot()
	vim.ui.select(snaps, {
		prompt = "Snapshot — active: " .. active,
		format_item = function(n)
			return (n == active and "● " or "○ ") .. n
		end,
	}, function(name)
		if name then
			M.apply(name)
		end
	end)
end

return M
