-- lvim-installer: shared runtime state.
-- Holds the per-filetype snooze table used to suppress re-prompting after the user
-- skips. Config lives in lvim-installer.config (the live table that setup() merges
-- user options into).
--
---@module "lvim-installer.state"

local M = {}

--- ft → expiry timestamp (vim.uv.now() based); set when the user skips a prompt.
---@type table<string, integer>
M.snoozed = {}

return M
