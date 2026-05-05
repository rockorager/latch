if vim.b.latch_nvim_ftplugin_loaded then
  return
end
vim.b.latch_nvim_ftplugin_loaded = true

require("latch").setup_buffer(0)
