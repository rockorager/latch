if vim.g.loaded_latch_nvim then
  return
end
vim.g.loaded_latch_nvim = true

local function set_latch_filetype(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name:match("%.latch%.md$") then
    return
  end
  if vim.bo[bufnr].filetype ~= "markdown.latch" then
    vim.bo[bufnr].filetype = "markdown.latch"
  end
end

vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
  pattern = "*.latch.md",
  callback = function(args)
    set_latch_filetype(args.buf)
  end,
})

vim.schedule(function()
  if vim.api.nvim_get_current_buf() ~= 0 then
    set_latch_filetype(0)
  end
end)
