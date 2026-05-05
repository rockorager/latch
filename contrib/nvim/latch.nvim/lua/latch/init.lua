local M = {}

local diagnostic_ns = vim.api.nvim_create_namespace("latch.nvim.diagnostics")

local defaults = {
  latch_cmd = "latch",
  reviewer = nil,
  keymaps = true,
  diagnostics = true,
}

M.config = vim.deepcopy(defaults)

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

local function split_lines(text)
  if text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function buffer_text(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n") .. "\n"
end

local function parse_opening_line(line)
  local marker, info = line:match("^%s*([`~][`~][`~]+)%s*(.-)%s*$")
  if not marker then
    return nil
  end

  local lang, rest = info:match("^(%S+)%s*(.*)$")
  return {
    marker = marker,
    marker_char = marker:sub(1, 1),
    info = info,
    lang = lang,
    rest = rest or "",
  }
end

local function is_closing_line(line, opening)
  local marker = line:match("^%s*([`~]+)%s*$")
  if not marker then
    return false
  end
  if #marker < #opening.marker then
    return false
  end
  for index = 1, #marker do
    if marker:sub(index, index) ~= opening.marker_char then
      return false
    end
  end
  return true
end

local function parse_metadata(rest)
  local entries = {}
  local invalid = {}
  for token in rest:gmatch("%S+") do
    local key, value = token:match("^([^=]+)=(.*)$")
    if key then
      table.insert(entries, { key = key, value = value, token = token })
    else
      table.insert(invalid, token)
    end
  end
  return entries, invalid
end

local function metadata_value(entries, key)
  local value = nil
  for _, entry in ipairs(entries) do
    if entry.key == key then
      value = entry.value
    end
  end
  return value
end

local function collect(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local fences = {}
  local patch_ids = {}
  local patch_id_list = {}

  local line_number = 1
  while line_number <= #lines do
    local opening = parse_opening_line(lines[line_number])
    if opening then
      local close_line = line_number
      while close_line + 1 <= #lines do
        close_line = close_line + 1
        if is_closing_line(lines[close_line], opening) then
          break
        end
      end

      if opening.lang == "diff" or opening.lang == "review" then
        local metadata, invalid_metadata = parse_metadata(opening.rest)
        local id = metadata_value(metadata, "id")
        local fence = {
          lang = opening.lang,
          info = opening.info,
          metadata = metadata,
          invalid_metadata = invalid_metadata,
          id = id,
          start_line = line_number,
          end_line = close_line,
          opening_line = lines[line_number],
        }
        table.insert(fences, fence)
        if opening.lang == "diff" and id and id ~= "" and not patch_ids[id] then
          patch_ids[id] = true
          table.insert(patch_id_list, id)
        end
      end

      line_number = close_line + 1
    else
      line_number = line_number + 1
    end
  end

  table.sort(patch_id_list)
  return {
    fences = fences,
    patch_ids = patch_ids,
    patch_id_list = patch_id_list,
  }
end

local function current_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function nearest_diff_fence(parsed, line)
  local previous = nil
  for _, fence in ipairs(parsed.fences) do
    if fence.lang == "diff" then
      if line >= fence.start_line and line <= fence.end_line then
        return fence
      end
      if fence.end_line < line then
        previous = fence
      end
    end
  end
  return previous
end

local function containing_fence(parsed, line)
  for _, fence in ipairs(parsed.fences) do
    if line >= fence.start_line and line <= fence.end_line then
      return fence
    end
  end
  return nil
end

local function reviewer_value()
  local reviewer = M.config.reviewer
  if type(reviewer) == "function" then
    reviewer = reviewer()
  end
  if reviewer == "" then
    return nil
  end
  return reviewer
end

local function encode_metadata_value(value)
  return tostring(value):gsub("([^%w%._~/%-:@])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
end

local function add_metadata_token(parts, key, value)
  if value == nil or value == "" then
    return
  end
  table.insert(parts, key .. "=" .. encode_metadata_value(value))
end

local function add_metadata_entry(entries, key, value)
  if value == nil or value == "" then
    return
  end
  table.insert(entries, { key = key, value = tostring(value) })
end

local function max_backtick_run(lines)
  local best = 0
  for _, line in ipairs(lines) do
    local current = 0
    for index = 1, #line do
      if line:sub(index, index) == "`" then
        current = current + 1
        if current > best then
          best = current
        end
      else
        current = 0
      end
    end
  end
  return best
end

local function review_marker_len(lines)
  return math.max(3, max_backtick_run(lines) + 1)
end

local function review_info(target_id, metadata)
  local parts = { "review" }
  add_metadata_token(parts, "reviewer", reviewer_value())
  add_metadata_token(parts, "id", target_id)
  for _, entry in ipairs(metadata or {}) do
    add_metadata_token(parts, entry.key, entry.value)
  end
  return table.concat(parts, " ")
end

local function selected_lines(bufnr, opts)
  if not opts or not opts.range or opts.range == 0 then
    return nil
  end
  if not opts.line1 or not opts.line2 or opts.line1 > opts.line2 then
    return nil
  end
  return vim.api.nvim_buf_get_lines(bufnr, opts.line1 - 1, opts.line2, false)
end

local function format_line_range(first, last)
  if not first then
    return nil
  end
  if first == last then
    return tostring(first)
  end
  return string.format("%d-%d", first, last)
end

local function local_diff_line_range(fence, first_line, last_line)
  if not fence or fence.lang ~= "diff" then
    return nil
  end

  local body_first = fence.start_line + 1
  local body_last = fence.end_line - 1
  local first = math.max(first_line, body_first)
  local last = math.min(last_line, body_last)
  if first > last then
    return nil
  end

  return format_line_range(first - fence.start_line, last - fence.start_line)
end

local function selection_reference_metadata(fence, first_line, last_line)
  local metadata = {}
  if not fence or fence.lang ~= "diff" then
    return metadata
  end

  add_metadata_entry(metadata, "part", metadata_value(fence.metadata, "part"))
  add_metadata_entry(metadata, "lines", local_diff_line_range(fence, first_line, last_line))
  return metadata
end

function M.insert_review(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local parsed = collect(bufnr)
  local line = current_line()
  local explicit_id = opts.args ~= "" and opts.args or nil
  if explicit_id and explicit_id:sub(1, 3) == "id=" then
    explicit_id = explicit_id:sub(4)
  end

  local selected = selected_lines(bufnr, opts)
  local anchor_line = selected and opts.line1 or line
  local target_fence = containing_fence(parsed, anchor_line)
  local nearest = nearest_diff_fence(parsed, anchor_line)
  local target_id = explicit_id
  if not target_id and not opts.bang and nearest then
    target_id = nearest.id
  end

  local insert_after = anchor_line
  if target_fence then
    insert_after = target_fence.end_line
  end

  local lines = {}
  local cursor_index = 2
  if selected and #selected > 0 then
    local reference_metadata = selection_reference_metadata(nearest, opts.line1, opts.line2)
    local body = { "```diff" }
    vim.list_extend(body, selected)
    table.insert(body, "```")
    local marker = string.rep("`", review_marker_len(body))
    table.insert(lines, marker .. review_info(target_id, reference_metadata))
    vim.list_extend(lines, body)
    table.insert(lines, "")
    cursor_index = #lines
    table.insert(lines, marker)
  else
    local marker = "```"
    table.insert(lines, marker .. review_info(target_id))
    table.insert(lines, "")
    table.insert(lines, marker)
  end

  local existing_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if insert_after > 0 and vim.trim(existing_lines[insert_after] or "") ~= "" then
    table.insert(lines, 1, "")
    cursor_index = cursor_index + 1
  end
  if insert_after < #existing_lines and vim.trim(existing_lines[insert_after + 1] or "") ~= "" then
    table.insert(lines, "")
  end

  vim.api.nvim_buf_set_lines(bufnr, insert_after, insert_after, false, lines)
  vim.api.nvim_win_set_cursor(0, { insert_after + cursor_index, 0 })
  vim.schedule(function()
    M.refresh(bufnr)
    pcall(vim.cmd, "startinsert")
  end)
end

function M.patch_ids(bufnr)
  return collect(bufnr or vim.api.nvim_get_current_buf()).patch_id_list
end

function M.completefunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col(".") - 1
    local prefix = line:sub(1, col)
    local start_index = prefix:match(".*id=()[^%s`~]*$")
    if not start_index then
      return -2
    end
    return start_index - 1
  end

  local matches = {}
  for _, id in ipairs(M.patch_ids(0)) do
    if id:sub(1, #base) == base then
      table.insert(matches, id)
    end
  end
  return matches
end

function M.complete_patch_ids(arg_lead)
  local matches = {}
  for _, id in ipairs(M.patch_ids(0)) do
    if id:sub(1, #arg_lead) == arg_lead then
      table.insert(matches, id)
    end
  end
  return matches
end

local function open_scratch(title, text, filetype)
  vim.cmd("botright new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype or ""
  vim.api.nvim_buf_set_name(bufnr, title)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, split_lines(text))
  vim.bo[bufnr].modified = false
end

local function run_latch(args, stdin, callback)
  local cmd = { M.config.latch_cmd }
  vim.list_extend(cmd, args)

  if vim.system then
    vim.system(cmd, { stdin = stdin, text = true }, function(result)
      vim.schedule(function()
        callback(result.code or 0, result.stdout or "", result.stderr or "")
      end)
    end)
    return
  end

  local output = vim.fn.system(cmd, stdin)
  callback(vim.v.shell_error, output, "")
end

function M.extract_reviews(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local args = { "review" }
  local filetype = "markdown"
  if opts.bang then
    table.insert(args, "--json")
    filetype = "json"
  end

  run_latch(args, buffer_text(bufnr), function(code, stdout, stderr)
    local output = stdout ~= "" and stdout or stderr
    if output == "" then
      output = code == 0 and "no output\n" or ("latch review failed with exit code " .. code .. "\n")
    end
    if code ~= 0 then
      vim.notify("latch review failed", vim.log.levels.ERROR)
      filetype = ""
    end
    open_scratch("Latch Reviews", output, filetype)
  end)
end

function M.apply(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local target_dir = opts.args ~= "" and opts.args or vim.fn.getcwd()
  local args = { "apply", "--dir", target_dir, "-" }

  run_latch(args, buffer_text(bufnr), function(code, stdout, stderr)
    local output = stdout ~= "" and stdout or stderr
    if code == 0 then
      vim.notify(vim.trim(output), vim.log.levels.INFO)
      return
    end
    vim.notify("latch apply failed", vim.log.levels.ERROR)
    open_scratch("Latch Apply", output, "")
  end)
end

function M.list_ids()
  local ids = M.patch_ids(0)
  if #ids == 0 then
    vim.notify("No Latch patch ids found", vim.log.levels.INFO)
    return
  end
  open_scratch("Latch Patch IDs", table.concat(ids, "\n") .. "\n", "")
end

local function diagnostic_severity(name)
  return vim.diagnostic.severity[name]
end

local function add_diagnostic(diagnostics, fence, severity, message)
  table.insert(diagnostics, {
    lnum = fence.start_line - 1,
    col = 0,
    end_col = #fence.opening_line,
    severity = severity,
    source = "latch.nvim",
    message = message,
  })
end

function M.refresh(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local parsed = collect(bufnr)
  if not M.config.diagnostics then
    vim.diagnostic.reset(diagnostic_ns, bufnr)
    return
  end

  local diagnostics = {}
  local diff_keys = {
    id = true,
    ["depends-on"] = true,
    part = true,
  }

  for _, fence in ipairs(parsed.fences) do
    for _, token in ipairs(fence.invalid_metadata) do
      add_diagnostic(
        diagnostics,
        fence,
        diagnostic_severity("ERROR"),
        string.format("%s metadata %q is not key=value", fence.lang, token)
      )
    end

    if fence.lang == "diff" then
      if not fence.id or fence.id == "" then
        add_diagnostic(diagnostics, fence, diagnostic_severity("ERROR"), "diff fence is missing id=...")
      end
      for _, entry in ipairs(fence.metadata) do
        if not diff_keys[entry.key] then
          add_diagnostic(
            diagnostics,
            fence,
            diagnostic_severity("ERROR"),
            string.format("unsupported diff metadata key %q", entry.key)
          )
        end
      end
    elseif fence.lang == "review" then
      if fence.id == "" then
        add_diagnostic(diagnostics, fence, diagnostic_severity("ERROR"), "review fence has empty id=...")
      elseif fence.id and not parsed.patch_ids[fence.id] then
        add_diagnostic(
          diagnostics,
          fence,
          diagnostic_severity("WARN"),
          string.format("review targets unknown patch id %q", fence.id)
        )
      end
    end
  end

  vim.diagnostic.set(diagnostic_ns, bufnr, diagnostics, {})
end

function M.setup_buffer(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if vim.b[bufnr].latch_nvim_attached then
    return
  end
  vim.b[bufnr].latch_nvim_attached = true

  _G.latch_nvim_completefunc = function(findstart, base)
    return require("latch.complete").completefunc(findstart, base)
  end

  vim.bo[bufnr].completefunc = "v:lua.latch_nvim_completefunc"

  vim.api.nvim_buf_create_user_command(bufnr, "LatchReview", function(opts)
    M.insert_review(opts)
  end, {
    nargs = "?",
    range = true,
    bang = true,
    complete = function(arg_lead)
      return M.complete_patch_ids(arg_lead)
    end,
    desc = "Insert a Latch review fence; with !, do not infer id from nearby diff",
  })

  vim.api.nvim_buf_create_user_command(bufnr, "LatchExtractReviews", function(opts)
    M.extract_reviews(opts)
  end, {
    bang = true,
    desc = "Run latch review on the current buffer; with !, request JSON",
  })

  vim.api.nvim_buf_create_user_command(bufnr, "LatchApply", function(opts)
    M.apply(opts)
  end, {
    nargs = "?",
    complete = "dir",
    desc = "Run latch apply on the current buffer, optionally targeting a directory",
  })

  vim.api.nvim_buf_create_user_command(bufnr, "LatchListIds", function()
    M.list_ids()
  end, {
    desc = "List patch ids in the current Latch document",
  })

  vim.api.nvim_buf_create_user_command(bufnr, "LatchRefresh", function()
    M.refresh(bufnr)
  end, {
    desc = "Refresh Latch diagnostics",
  })

  if M.config.keymaps then
    vim.keymap.set({ "n", "x" }, "<leader>lr", ":LatchReview<CR>", {
      buffer = bufnr,
      silent = true,
      desc = "Latch: insert review fence",
    })
    vim.keymap.set("n", "<leader>lx", ":LatchExtractReviews<CR>", {
      buffer = bufnr,
      silent = true,
      desc = "Latch: extract reviews",
    })
    vim.keymap.set("n", "<leader>lX", ":LatchExtractReviews!<CR>", {
      buffer = bufnr,
      silent = true,
      desc = "Latch: extract reviews as JSON",
    })
  end

  local group = vim.api.nvim_create_augroup("latch_nvim_buffer_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.refresh(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    callback = function()
      vim.diagnostic.reset(diagnostic_ns, bufnr)
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })

  vim.schedule(function()
    M.refresh(bufnr)
  end)
end

return M
