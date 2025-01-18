---@class snacks.picker.highlight
local M = {}

---@param opts? {buf?:number, code?:string, ft?:string, lang?:string, file?:string}
function M.get_highlights(opts)
  opts = opts or {}
  local source = assert(opts.buf or opts.code, "buf or code is required")
  assert(not (opts.buf and opts.code), "only one of buf or code is allowed")

  local ret = {} ---@type table<number, snacks.picker.Extmark[]>

  local ft = opts.ft
    or (opts.buf and vim.bo[opts.buf].filetype)
    or (opts.file and vim.filetype.match({ filename = opts.file, buf = 0 }))
    or vim.bo.filetype
  local lang = opts.lang or vim.treesitter.language.get_lang(ft)
  local parser ---@type vim.treesitter.LanguageTree?
  if lang then
    local ok = false
    if opts.buf then
      ok, parser = pcall(vim.treesitter.get_parser, opts.buf, lang)
    else
      ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
    end
    parser = ok and parser or nil
  end

  if parser then
    parser:parse(true)
    parser:for_each_tree(function(tstree, tree)
      if not tstree then
        return
      end
      local query = vim.treesitter.query.get(tree:lang(), "highlights")
      -- Some injected languages may not have highlight queries.
      if not query then
        return
      end

      for capture, node, metadata in query:iter_captures(tstree:root(), source) do
        ---@type string
        local name = query.captures[capture]
        if name ~= "spell" then
          local range = { node:range() } ---@type number[]
          local multi = range[1] ~= range[3]
          local text = multi
              and vim.split(vim.treesitter.get_node_text(node, source, metadata[capture]), "\n", { plain = true })
            or {}
          for row = range[1] + 1, range[3] + 1 do
            local first, last = row == range[1] + 1, row == range[3] + 1
            local end_col = last and range[4] or #(text[row - range[1]] or "")
            end_col = multi and first and end_col + range[2] or end_col
            ret[row] = ret[row] or {}
            table.insert(ret[row], {
              col = first and range[2] or 0,
              end_col = end_col,
              priority = (tonumber(metadata.priority or metadata[capture] and metadata[capture].priority) or 100),
              conceal = metadata.conceal or metadata[capture] and metadata[capture].conceal,
              hl_group = "@" .. name .. "." .. lang,
            })
          end
        end
      end
    end)
  end

  --- Add buffer extmarks
  if opts.buf then
    local extmarks = vim.api.nvim_buf_get_extmarks(opts.buf, -1, 0, -1, { details = true })
    for _, extmark in pairs(extmarks) do
      local row = extmark[2] + 1
      ret[row] = ret[row] or {}
      local e = extmark[4]
      if e then
        e.sign_name = nil
        e.sign_text = nil
        e.ns_id = nil
        e.end_row = nil
        e.col = extmark[3]
        if e.virt_text_pos and not vim.tbl_contains({ "eol", "overlay", "right_align", "inline" }, e.virt_text_pos) then
          e.virt_text = nil
          e.virt_text_pos = nil
        end
        table.insert(ret[row], e)
      end
    end
  end

  return ret
end

---@param line snacks.picker.Highlight[]
function M.offset(line)
  local offset = 0
  for _, t in ipairs(line) do
    if type(t[1]) == "string" then
      if t.virtual then
        offset = offset + vim.api.nvim_strwidth(t[1])
      else
        offset = offset + #t[1]
      end
    end
  end
  return offset
end

---@param line snacks.picker.Highlight[]
---@param item snacks.picker.Item
---@param text string
---@param opts? {hl_group?:string, lang?:string}
function M.format(item, text, line, opts)
  opts = opts or {}
  local offset = M.offset(line)
  local highlights = M.get_highlights({ code = text, ft = item.ft, lang = opts.lang or item.lang, file = item.file })[1]
    or {}
  for _, extmark in ipairs(highlights) do
    extmark.col = extmark.col + offset
    extmark.end_col = extmark.end_col + offset
    line[#line + 1] = extmark
  end
  line[#line + 1] = { text, opts.hl_group }
end

---@param line snacks.picker.Highlight[]
---@param patterns table<string,string>
function M.highlight(line, patterns)
  local offset = M.offset(line)
  local text ---@type string?
  for i = #line, 1, -1 do
    if type(line[i][1]) == "string" then
      text = line[i][1]
      break
    end
  end
  if not text then
    return
  end
  offset = offset - #text
  for pattern, hl in pairs(patterns) do
    local from, to, match = text:find(pattern)
    while from do
      if match then
        from, to = text:find(match, from, true)
      end
      table.insert(line, {
        col = offset + from - 1,
        end_col = offset + to,
        hl_group = hl,
      })
      from, to = text:find(pattern, to + 1)
    end
  end
end

---@param line snacks.picker.Highlight[]
function M.markdown(line)
  M.highlight(line, {
    ["`.-`"] = "SnacksPickerCode",
    ["%*.-%*"] = "SnacksPickerItalic",
    ["%*%*.-%*%*"] = "SnacksPickerBold",
  })
end

---@param prefix string
---@param links? table<string, string>
function M.winhl(prefix, links)
  links = links or {}
  local winhl = {
    NormalFloat = "",
    FloatBorder = "Border",
    FloatTitle = "Title",
    FloatFooter = "Footer",
    CursorLine = "CursorLine",
  }
  local ret = {} ---@type string[]
  local groups = {} ---@type table<string, string>
  for k, v in pairs(winhl) do
    groups[v] = links[k] or (prefix == "SnacksPicker" and k or ("SnacksPicker" .. v))
    ret[#ret + 1] = ("%s:%s%s"):format(k, prefix, v)
  end
  Snacks.util.set_hl(groups, { prefix = prefix, default = true })
  return table.concat(ret, ",")
end

---@param line snacks.picker.Highlight[]
---@param opts? {offset?:number}
function M.to_text(line, opts)
  local offset = opts and opts.offset or 0
  local ret = {} ---@type snacks.picker.Extmark[]
  local col = offset
  local parts = {} ---@type string[]
  for _, text in ipairs(line) do
    if type(text[1]) == "string" then
      ---@cast text snacks.picker.Text
      if text.virtual then
        table.insert(ret, {
          col = col,
          virt_text = { { text[1], text[2] } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
        parts[#parts + 1] = string.rep(" ", vim.api.nvim_strwidth(text[1]))
      else
        table.insert(ret, {
          col = col,
          end_col = col + #text[1],
          hl_group = text[2],
          field = text.field,
        })
        parts[#parts + 1] = text[1]
      end
      col = col + #parts[#parts]
    else
      text = vim.deepcopy(text)
      ---@cast text snacks.picker.Extmark
      -- fix extmark col and end_col
      text.col = text.col + offset
      if text.end_col then
        text.end_col = text.end_col + offset
      end
      table.insert(ret, text)
    end
  end
  return table.concat(parts), ret
end

return M
