local Kind = require("blink.cmp.types").CompletionItemKind

local Source = {}

function Source.new()
  return setmetatable({}, { __index = Source })
end

function Source:enabled()
  return vim.bo.filetype == "markdown.latch"
end

function Source:get_trigger_characters()
  return { "=" }
end

local function id_completion_range(ctx)
  local cursor_col = ctx.cursor[2]
  local before_cursor = ctx.line:sub(1, cursor_col)
  local partial = before_cursor:match("id=([^%s`~]*)$")
  if not partial then
    return nil
  end

  return {
    partial = partial,
    range = {
      start = { line = ctx.cursor[1] - 1, character = cursor_col - #partial },
      ["end"] = { line = ctx.cursor[1] - 1, character = cursor_col },
    },
  }
end

function Source:get_completions(ctx, callback)
  local id_range = id_completion_range(ctx)
  if not id_range then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local items = {}
  for _, id in ipairs(require("latch").patch_ids(ctx.bufnr)) do
    table.insert(items, {
      label = id,
      kind = Kind.Reference,
      detail = "Latch patch id",
      textEdit = {
        newText = id,
        range = id_range.range,
      },
    })
  end

  callback({
    items = items,
    is_incomplete_forward = true,
    is_incomplete_backward = true,
  })
end

return Source
