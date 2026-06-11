-- lvim-installer: shared lvim-utils UI instance.
-- Lazily created on first access so lvim-utils is not required at load time.
--
---@module "lvim-installer.ui"

local config = require("lvim-installer.config")

local _instance = nil

--- Returns the shared lvim-utils UI instance (created once via .new()).
--- Returns nil when lvim-utils is unavailable.
---@return table|nil
local function get()
	if _instance then
		return _instance
	end
	local ok, mod = pcall(require, "lvim-utils.ui")
	if not ok then
		return nil
	end
	_instance = mod.new(config.popup_global)
	return _instance
end

--- Invalidate the cached instance so the next get() rebuilds it.
---@return nil
local function reset()
	_instance = nil
end

return { get = get, reset = reset }
