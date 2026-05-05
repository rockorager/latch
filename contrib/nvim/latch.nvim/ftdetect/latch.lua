vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
  pattern = "*.latch.md",
  callback = function()
    vim.bo.filetype = "markdown.latch"
  end,
})
