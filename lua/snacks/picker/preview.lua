---@class snacks.picker.previewers
local M = {}

local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace("snacks.picker.preview")

---@param ctx snacks.picker.preview.ctx
function M.directory(ctx)
  ctx.preview:reset()
  local ls = {} ---@type {file:string, type:"file"|"directory"}[]
  for file, t in vim.fs.dir(ctx.item.file) do
    ls[#ls + 1] = { file = file, type = t }
  end
  vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, vim.split(string.rep("\n", #ls), "\n"))
  vim.bo[ctx.buf].modifiable = false
  table.sort(ls, function(a, b)
    if a.type ~= b.type then
      return a.type == "directory"
    end
    return a.file < b.file
  end)
  for i, item in ipairs(ls) do
    local cat = item.type == "directory" and "directory" or "file"
    local hl = item.type == "directory" and "Directory" or nil
    local path = item.file
    local icon, icon_hl = Snacks.util.icon(path, cat)
    local line = { { icon .. " ", icon_hl }, { path, hl } }
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, i - 1, 0, {
      virt_text = line,
    })
  end
end

---@param ctx snacks.picker.preview.ctx
function M.none(ctx)
  ctx.preview:reset()
  ctx.preview:notify("no preview available", "warn")
end

---@param ctx snacks.picker.preview.ctx
function M.preview(ctx)
  if ctx.item.preview == "file" then
    return M.file(ctx)
  end
  assert(type(ctx.item.preview) == "table", "item.preview must be a table")
  ctx.preview:reset()
  local lines = vim.split(ctx.item.preview.text, "\n")
  vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, lines)
  if ctx.item.preview.ft then
    ctx.preview:highlight({ ft = ctx.item.preview.ft })
  end
  for _, extmark in ipairs(ctx.item.preview.extmarks or {}) do
    local e = vim.deepcopy(extmark)
    e.col, e.row = nil, nil
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, (extmark.row or 1) - 1, extmark.col, e)
  end
  if ctx.item.preview.loc ~= false then
    ctx.preview:loc()
  end
end

---@param ctx snacks.picker.preview.ctx
function M.file(ctx)
  if ctx.item.buf and vim.api.nvim_buf_is_loaded(ctx.item.buf) then
    local name = vim.api.nvim_buf_get_name(ctx.item.buf)
    name = uv.fs_stat(name) and vim.fn.fnamemodify(name, ":t") or name
    ctx.preview:set_title(name)
    vim.api.nvim_win_set_buf(ctx.win, ctx.item.buf)
  else
    local path = Snacks.picker.util.path(ctx.item)
    if not path then
      ctx.preview:notify("Item has no `file`", "error")
      return
    end
    -- re-use existing preview when path is the same
    if path ~= Snacks.picker.util.path(ctx.prev) then
      ctx.preview:reset()

      local name = vim.fn.fnamemodify(path, ":t")
      ctx.preview:set_title(ctx.item.title or name)

      local stat = uv.fs_stat(path)
      if not stat then
        ctx.preview:notify("file not found: " .. path, "error")
        return false
      end
      if stat.type == "directory" then
        return M.directory(ctx)
      end
      local max_size = ctx.picker.opts.previewers.file.max_size or (1024 * 1024)
      if stat.size > max_size then
        ctx.preview:notify("large file > 1MB", "warn")
        return false
      end
      if stat.size == 0 then
        ctx.preview:notify("empty file", "warn")
        return false
      end

      local file = assert(io.open(path, "r"))

      local lines = {}
      for line in file:lines() do
        ---@cast line string
        if #line > ctx.picker.opts.previewers.file.max_line_length then
          line = line:sub(1, ctx.picker.opts.previewers.file.max_line_length) .. "..."
        end
        -- Check for binary data in the current line
        if line:find("[%z\1-\8\11\12\14-\31]") then
          ctx.preview:notify("binary file", "warn")
          return
        end
        table.insert(lines, line)
      end

      file:close()

      vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, lines)
      vim.bo[ctx.buf].modifiable = false
      ctx.preview:highlight({ file = path, ft = ctx.picker.opts.previewers.file.ft, buf = ctx.buf })
    end
  end
  ctx.preview:loc()
end

---@param cmd string[]
---@param ctx snacks.picker.preview.ctx
---@param opts? {env?:table<string, string>, pty?:boolean, ft?:string}
function M.cmd(cmd, ctx, opts)
  opts = opts or {}
  local buf = ctx.preview:scratch()
  local pty = opts.pty ~= false and not opts.ft
  local killed = false
  local chan = pty and vim.api.nvim_open_term(buf, {}) or nil
  local output = {} ---@type string[]

  ---@param data string
  local function add(data)
    output[#output + 1] = data
    if chan then
      if pcall(vim.api.nvim_chan_send, chan, data) then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("norm! gg")
        end)
      end
    else
      vim.bo[buf].modifiable = true
      local lines = vim.split(table.concat(output, "\n"), "\n")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
    end
  end

  local jid = vim.fn.jobstart(cmd, {
    height = pty and vim.api.nvim_win_get_height(ctx.win) or nil,
    width = pty and vim.api.nvim_win_get_width(ctx.win) or nil,
    pty = pty,
    cwd = ctx.item.cwd or ctx.picker.opts.cwd,
    env = vim.tbl_extend("force", {
      PAGER = "cat",
      DELTA_PAGER = "cat",
    }, opts.env or {}),
    on_stdout = function(_, data)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      add(table.concat(data, "\n"))
    end,
    on_exit = function(_, code)
      if not killed and code ~= 0 then
        Snacks.notify.error(
          ("Terminal **cmd** `%s` failed with code `%d`:\n- `vim.o.shell = %q`\n\nOutput:\n%s"):format(
            cmd,
            code,
            vim.o.shell,
            vim.trim(table.concat(output, ""))
          )
        )
      end
    end,
  })
  if opts.ft then
    ctx.preview:highlight({ ft = opts.ft })
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      killed = true
      vim.fn.jobstop(jid)
      if chan then
        vim.fn.chanclose(chan)
      end
    end,
  })
  if jid <= 0 then
    Snacks.notify.error(("Failed to start terminal **cmd** `%s`"):format(cmd))
  end
end

---@param ctx snacks.picker.preview.ctx
function M.git_show(ctx)
  local native = ctx.picker.opts.previewers.git.native
  local cmd = {
    "git",
    "-c",
    "delta." .. vim.o.background .. "=true",
    "show",
    ctx.item.commit,
  }
  if ctx.item.file then
    cmd[#cmd + 1] = "--"
    cmd[#cmd + 1] = ctx.item.file
  end
  if not native then
    table.insert(cmd, 2, "--no-pager")
  end
  M.cmd(cmd, ctx, { ft = not native and "git" or nil })
end

---@param ctx snacks.picker.preview.ctx
function M.git_diff(ctx)
  local native = ctx.picker.opts.previewers.git.native
  local cmd = {
    "git",
    "-c",
    "delta." .. vim.o.background .. "=true",
    "diff",
    "--",
    ctx.item.file,
  }
  if not native then
    table.insert(cmd, 2, "--no-pager")
  end
  M.cmd(cmd, ctx, { ft = not native and "diff" or nil })
end

---@param ctx snacks.picker.preview.ctx
function M.git_status(ctx)
  local s = vim.trim(ctx.item.status):sub(1, 1)
  if s == "?" then
    M.file(ctx)
  else
    M.git_diff(ctx)
  end
end

---@param ctx snacks.picker.preview.ctx
function M.colorscheme(ctx)
  if not ctx.preview.state.colorscheme then
    ctx.preview.state.colorscheme = vim.g.colors_name or "default"
    ctx.preview.state.background = vim.o.background
    ctx.preview.win:on("WinClosed", function()
      vim.schedule(function()
        if not ctx.preview.state.colorscheme then
          return
        end
        vim.cmd("colorscheme " .. ctx.preview.state.colorscheme)
        vim.o.background = ctx.preview.state.background
      end)
    end, { win = true })
  end
  vim.schedule(function()
    vim.cmd("colorscheme " .. ctx.item.text)
  end)
  Snacks.picker.preview.file(ctx)
end

---@param ctx snacks.picker.preview.ctx
function M.man(ctx)
  M.cmd({ "man", ctx.item.section, ctx.item.page }, ctx, {
    ft = "man",
    env = {
      MANPAGER = ctx.picker.opts.previewers.man_pager or vim.fn.executable("col") == 1 and "col -bx" or "cat",
      MANWIDTH = tostring(ctx.preview.win:dim().width),
      MANPATH = vim.env.MANPATH,
    },
  })
end

return M
