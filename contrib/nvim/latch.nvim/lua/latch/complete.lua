local M = {}

function M.completefunc(findstart, base)
  return require("latch").completefunc(findstart, base)
end

return M
