-- lvim-installer plugin guard.
-- Nothing auto-runs; the user drives everything via require("lvim-installer").setup(opts).
-- This file exists so the plugin manager recognises the plugin without requiring
-- an explicit `main` field.
if vim.g.loaded_lvim_installer then
	return
end
vim.g.loaded_lvim_installer = true
