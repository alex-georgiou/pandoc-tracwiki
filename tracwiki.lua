-- tracwiki.lua: pandoc custom writer that renders Trac wiki markup.
--
-- Use:  pandoc --from=markdown -t /path/to/tracwiki.lua input.md
-- or:   pandoc --from=markdown -t tracwiki.lua input.md  (with this file on the
--       pandoc user data directory or given as a path)

local utils = require 'pandoc.utils'

local M = {}

-- Forward declarations for (mutually) recursive renderers.
local inlines            -- inlines <-> M.inline
local renderBlocks       -- M.block <-> renderBlocks
local renderBulletList   -- renderListItem <-> renderBulletList / renderOrderedList
local renderOrderedList
local renderListItem

local function isTracFormat(format)
  local f = format:lower()
  return f == 'trac' or f == 'tracwiki' or f == 'trac_wiki' or f == 'tracweb'
end

local function prefixLines(prefix, text)
  local out = {}
  local stripped = prefix:sub(1, -2)
  local startPos = 1
  while true do
    local nl = text:find('\n', startPos, true)
    if nl == nil then
      local seg = text:sub(startPos)
      table.insert(out, (seg == '') and stripped or (prefix .. seg))
      break
    end
    local seg = text:sub(startPos, nl - 1)
    table.insert(out, (seg == '') and stripped or (prefix .. seg))
    startPos = nl + 1
  end
  return table.concat(out, '\n')
end

local function indentLines(indent, text)
  if text == '' then return '' end
  local out = {}
  local startPos = 1
  while true do
    local nl = text:find('\n', startPos, true)
    local lineSeg
    if nl == nil then
      lineSeg = text:sub(startPos)
      if lineSeg ~= '' then lineSeg = indent .. lineSeg end
      table.insert(out, lineSeg)
      break
    end
    lineSeg = text:sub(startPos, nl - 1)
    if lineSeg ~= '' then lineSeg = indent .. lineSeg end
    table.insert(out, lineSeg)
    startPos = nl + 1
  end
  return table.concat(out, '\n')
end

-- =====================================================================
-- Trac wiki reader
--
-- Use:  pandoc -f tracwiki.lua -t markdown input-(trac).txt
-- The same file also provides the writer, so a single install supports
-- both -f and -t tracwiki.lua.
-- =====================================================================

-- The only reader extension: enabling it auto-links CamelCase words as
-- wiki page links (matching native Trac behaviour).
Extensions = { camelcase = 'disable' }

local CAMELCASE = false

local R = { lines = {}, pos = 1 }

local function resetLines(text)
  R.lines = {}
  R.pos = 1
  for line in (text .. '\n'):gmatch('(.-)\n') do
    if line:sub(-1) == '\r' then line = line:sub(1, -2) end
    local content = line:match('^%s*(.*)$')
    table.insert(R.lines, { raw = line, indent = #line - #content, content = content })
  end
  while #R.lines > 0 and R.lines[#R.lines].raw == '' do
    R.lines[#R.lines] = nil
  end
end

local function cur() return R.lines[R.pos] end
local function peekLine(n) return R.lines[R.pos + (n or 1)] end

local parseBlocks

-- Parse a fresh set of lines as blocks (used for list items, quotes, ...).
local function runOnLines(entries)
  local savedLines, savedPos = R.lines, R.pos
  R.lines = entries
  R.pos = 1
  local blocks = parseBlocks()
  R.lines, R.pos = savedLines, savedPos
  return blocks
end

local function lineIndent(txt)
  local content = txt:match('^%s*(.*)$')
  return #txt - #content, content
end

-- ---------------------------------------------------------------------
-- Inline parsing
-- ---------------------------------------------------------------------

local function matchAutolink(s, i)
  local p = s:find('https?://', i) or s:find('ftp://', i)
  if not p then return nil end
  if p > 1 and (s:sub(p - 1, p - 1):match('%w') or s:sub(p - 1, p - 1) == ':') then
    return nil
  end
  local en = s:find('%s', p) or (#s + 1)
  local url = s:sub(p, en - 1):gsub("[,.;:!?%'%(%)%[%]]+$", '')
  if url == '' then return nil end
  return p, p + #url
end

local function matchCamel(s, i)
  local p = s:find('[A-Z][a-z]+[A-Z][A-Za-z0-9]*', i)
  if not p then return nil end
  local _, e = s:find('[A-Z][a-z]+[A-Z][A-Za-z0-9]*', p)
  if p > 1 and s:sub(p - 1, p - 1):match('%w') then return nil end
  if e < #s and s:sub(e + 1, e + 1):match('%w') then return nil end
  return p, e
end

local function splitTop(s)
  local parts, depth, buf = {}, 0, {}
  for ch in s:gmatch('.') do
    if ch == '(' or ch == '{' then depth = depth + 1 end
    if ch == ')' or ch == '}' then depth = math.max(0, depth - 1) end
    if ch == ',' and depth == 0 then
      parts[#parts + 1] = table.concat(buf)
      buf = {}
    else
      buf[#buf + 1] = ch
    end
  end
  parts[#parts + 1] = table.concat(buf)
  return parts
end

-- All this machinery is used to turn a Trac `[[Macro(...)]]` argument list
-- into pandoc attributes; unknown `[[Macro(...)]]` are kept as raw trac.
local function emitWords(out, chunk)
  local pos = 1
  while pos <= #chunk do
    local w = chunk:match('^(%S+)', pos)
    if w then
      out[#out + 1] = pandoc.Str(w)
      pos = pos + #w
    else
      w = ''
    end
    if pos <= #chunk then
      local sp = chunk:match('^%s+', pos)
      if sp then
        if sp:find('\n') then
          out[#out + 1] = pandoc.SoftBreak()
        else
          out[#out + 1] = pandoc.Space()
        end
        pos = pos + #sp
      elseif w == '' then
        out[#out + 1] = pandoc.Str(chunk:sub(pos, pos))
        pos = pos + 1
      end
    end
  end
end

local function parseInlines(s)
  if s == nil then return {} end
  if s == '' then return {} end
  local out = {}
  local i, n = 1, #s
  local lastBreak = false
  while i <= n do
    local best, kind = n + 1, nil
    for _, tok in ipairs({ '{{{', '[[', '`', "'''", '**', '//', '__', '~~', ',,', '\\\\', '[', '!', '\\' }) do
      local p = s:find(tok, i, true)
      if p and p < best then best, kind = p, tok end
    end
    local pA = s:find("''", i, true)
    if pA and pA < best then best, kind = pA, "''" end
    local pB = s:find('^', i, true)
    if pB and pB < best then best, kind = pB, '^' end
    local us, ue = matchAutolink(s, i)
    if us and us < best then best, kind = us, 'url' end
    if CAMELCASE then
      local cs, ce = matchCamel(s, i)
      if cs and cs < best then best, kind = cs, 'camel' end
    end

    if best > i then
      emitWords(out, s:sub(i, best - 1))
    end
    if best > n then break end
    i = best

    if kind == 'url' then
      local url = s:sub(i, ue)
      out[#out + 1] = pandoc.Link({ pandoc.Str(url) }, url)
      lastBreak = false
      i = ue + 1
    elseif kind == 'camel' then
      local word = s:sub(i, ce)
      out[#out + 1] = pandoc.Link({ pandoc.Str(word) }, word)
      lastBreak = false
      i = ce + 1
    elseif kind == '\\\\' then
      if #out > 0 and out[#out].t == 'Space' then out[#out] = nil end
      out[#out + 1] = pandoc.LineBreak()
      lastBreak = true
      i = i + 2
    elseif kind == '\\' then
      -- escaped markup character, e.g. \* or 1\. at the start of a line
      local ch = s:sub(i + 1, i + 1)
      if ch == '' then
        out[#out + 1] = pandoc.Str('\\')
        i = i + 1
      else
        out[#out + 1] = pandoc.Str(ch)
        i = i + 2
      end
      lastBreak = false
    elseif kind == '{{{' then
      local close = s:find('}}}', i + 3, true)
      if close then
        out[#out + 1] = pandoc.Code(s:sub(i + 3, close - 1))
        i = close + 3
      else
        out[#out + 1] = pandoc.Str('{{{')
        i = i + 3
      end
      lastBreak = false
    elseif kind == '`' then
      local close = s:find('`', i + 1, true)
      if close then
        out[#out + 1] = pandoc.Code(s:sub(i + 1, close - 1))
        i = close + 1
      else
        out[#out + 1] = pandoc.Str('`')
        i = i + 1
      end
      lastBreak = false
    elseif kind == "'''" then
      local function findClose()
        local close = s:find("'''", i + 3, true)
        while close and s:sub(close + 3, close + 3) == "'" do
          close = s:find("'''", close + 1, true)
        end
        return close
      end
      local close = findClose()
      if close then
        out[#out + 1] = pandoc.Strong(parseInlines(s:sub(i + 3, close - 1)))
        i = close + 3
      else
        out[#out + 1] = pandoc.Str("'''")
        i = i + 3
      end
      lastBreak = false
    elseif kind == '**' then
      local close = s:find('**', i + 2, true)
      local prev = i > 1 and s:sub(i - 1, i - 1) or ''
      local okBound = prev == '' or not (prev:match('%w') or prev == ':')
      if okBound and close then
        out[#out + 1] = pandoc.Strong(parseInlines(s:sub(i + 2, close - 1)))
        i = close + 2
      else
        out[#out + 1] = pandoc.Str('**')
        i = i + 2
      end
      lastBreak = false
    elseif kind == '//' then
      local close = s:find('//', i + 2, true)
      local prev = i > 1 and s:sub(i - 1, i - 1) or ''
      local nextc = s:sub(i + 2, i + 2)
      local okBound = (prev == '' or not (prev:match('%w') or prev == ':')) and nextc ~= '/'
      if okBound and close then
        out[#out + 1] = pandoc.Emph(parseInlines(s:sub(i + 2, close - 1)))
        i = close + 2
      else
        out[#out + 1] = pandoc.Str('//')
        i = i + 2
      end
      lastBreak = false
    elseif kind == "''" then
      local close = s:find("''", i + 2, true)
      if close then
        out[#out + 1] = pandoc.Emph(parseInlines(s:sub(i + 2, close - 1)))
        i = close + 2
      else
        out[#out + 1] = pandoc.Str("''")
        i = i + 2
      end
      lastBreak = false
    elseif kind == '__' then
      local close = s:find('__', i + 2, true)
      if close then
        out[#out + 1] = pandoc.Underline(parseInlines(s:sub(i + 2, close - 1)))
        i = close + 2
      else
        out[#out + 1] = pandoc.Str('__')
        i = i + 2
      end
      lastBreak = false
    elseif kind == '~~' then
      local close = s:find('~~', i + 2, true)
      if close then
        out[#out + 1] = pandoc.Strikeout(parseInlines(s:sub(i + 2, close - 1)))
        i = close + 2
      else
        out[#out + 1] = pandoc.Str('~~')
        i = i + 2
      end
      lastBreak = false
    elseif kind == '\\\\' then
      local ch = s:sub(i + 1, i + 1)
      out[#out + 1] = pandoc.Str(ch == '' and '\\' or ch)
      i = i + (ch == '' and 1 or 2)
      lastBreak = false
    elseif kind == '^' then
      local content = s:sub(i + 1):match('^(%S+)%^')
      if content then
        out[#out + 1] = pandoc.Superscript({ pandoc.Str(content) })
        i = i + 1 + #content + 1
      else
        out[#out + 1] = pandoc.Str('^')
        i = i + 1
      end
      lastBreak = false
    elseif kind == ',,' then
      local close = s:find(',,', i + 2, true)
      if close and close > i + 2 then
        out[#out + 1] = pandoc.Subscript(parseInlines(s:sub(i + 2, close - 1)))
        i = close + 2
      else
        out[#out + 1] = pandoc.Str(',,')
        i = i + 2
      end
      lastBreak = false
    elseif kind == '[[' then
      local close = s:find(']]', i + 2, true)
      if not close then
        out[#out + 1] = pandoc.Str('[[')
        i = i + 2
        lastBreak = false
      else
        local inner = s:sub(i + 2, close - 1)
        local img = inner:match('^Image%((.*)%)$')
        if img then
          local args = splitTop(img)
          local dest = (args[1] or ''):match('^%s*(.-)%s*$')
          local attrs = {}
          for k = 2, #args do
            local key, val = args[k]:match('^%s*(%w+)%s*=%s*(.-)%s*$')
            if key then attrs[key] = val end
          end
          local alt = attrs.alt or ''
          local content = alt ~= '' and parseInlines(alt) or { pandoc.Str(dest) }
          local imgEl = pandoc.Image(content, dest, attrs.title or '')
          local linkTo = attrs.link
          if linkTo and linkTo ~= '' then
            imgEl = pandoc.Link({ imgEl }, linkTo)
          end
          out[#out + 1] = imgEl
          lastBreak = false
        elseif inner:upper() == 'BR' then
          if #out > 0 and out[#out].t == 'Space' then out[#out] = nil end
          out[#out + 1] = pandoc.LineBreak()
          lastBreak = true
        elseif inner:find('|', 1, true) then
          local d, t = inner:match('^(.-)|(.*)$')
          d = d:match('^%s*(.-)%s*$')
          local targ, content
          if d:match('^https?://') or d:match('^ftp://') or d:match('^mailto:') then
            targ = d
            content = parseInlines(t)
          elseif d:match('^wiki:') then
            targ = d:sub(6)
            content = parseInlines(t)
          else
            targ = d
            content = parseInlines(t)
          end
          if #content == 0 then content = { pandoc.Str(d:match('^wiki:(.*)$') or d) } end
          out[#out + 1] = pandoc.Link(content, targ)
          lastBreak = false
        elseif inner:match('^%w+%(') then
          out[#out + 1] = pandoc.RawInline('trac', '[[' .. inner .. ']]')
          lastBreak = false
        else
          local d = inner:match('^%s*(.-)%s*$')
          if d == '' or d:find('%s') then
            out[#out + 1] = pandoc.Str('[[' .. inner .. ']]')
          else
            local targ = d:match('^wiki:(.*)$') or d
            out[#out + 1] = pandoc.Link({ pandoc.Str(d) }, targ)
          end
          lastBreak = false
        end
        i = close + 2
      end
    elseif kind == '[' then
      local close = s:find(']', i + 1, true)
      if not close then
        out[#out + 1] = pandoc.Str('[')
        i = i + 1
        lastBreak = false
      else
        local inner = s:sub(i + 1, close - 1)
        local aid, label = inner:match('^%s*=%s*#(%S+)%s*(.*)$')
        if aid then
          out[#out + 1] = pandoc.Span(parseInlines(label), { identifier = aid })
          lastBreak = false
        else
          local hid, hlabel = inner:match('^#(%S+)%s*(.*)$')
          if hid then
            local content = hlabel ~= '' and parseInlines(hlabel) or { pandoc.Str(hid) }
            out[#out + 1] = pandoc.Link(content, '#' .. hid)
            lastBreak = false
          elseif inner:match('^%s*$') then
            out[#out + 1] = pandoc.Str('[')
            out[#out + 1] = pandoc.Str(']')
            lastBreak = false
          else
            local sp = inner:find('%s')
            local dest = sp and inner:sub(1, sp - 1) or inner
            local text = sp and inner:sub(sp + 1):match('^%s*(.-)%s*$') or nil
            local content = text and parseInlines(text) or { pandoc.Str(dest) }
            if dest:match('^https?://') or dest:match('^ftp://') then
              out[#out + 1] = pandoc.Link(content, dest)
            elseif dest:match('^mailto:') then
              out[#out + 1] = pandoc.Link(content, dest)
            elseif dest:match('^wiki:') then
              out[#out + 1] = pandoc.Link(content, dest:sub(6))
            else
              out[#out + 1] = pandoc.Str(s:sub(i, close))
            end
            lastBreak = false
          end
        end
        i = close + 1
      end
    elseif kind == '!' then
      local tok = s:match('^!(%S*)', i)
      if tok == nil or tok == '' and s:sub(i + 1, i + 1):match('%s') then
        out[#out + 1] = pandoc.Str('!')
        i = i + 1
      else
        out[#out + 1] = pandoc.Str(tok)
        i = i + 1 + #tok
      end
      lastBreak = false
    else
      out[#out + 1] = pandoc.Str(s:sub(i, i))
      i = i + 1
    end
  end
  return out
end

-- ---------------------------------------------------------------------
-- Block parsing
-- ---------------------------------------------------------------------

local knownProcessors = {
  comment = true, div = true, span = true, table = true, tr = true,
  th = true, td = true,
}

local function parseInlinesOrNil(text)
  return parseInlines(text)
end

local ROMAN = { i = 1, v = 5, x = 10, l = 50, c = 100, d = 500, m = 1000 }

local function romanValue(s)
  local t = s:lower()
  local total, prev = 0, 0
  for j = #t, 1, -1 do
    local v = ROMAN[t:sub(j, j)]
    if not v then return nil end
    if v < prev then total = total - v else total = total + v end
    prev = v
  end
  return total
end

local function isListMarker(line)
  if line == nil then return nil end
  local c = line.content
  if c == '*' or c:match('^%*%s') then return 'bullet' end
  local num = c:match('^(%d+)%.%s')
  if num then return 'ordered', tonumber(num), 'decimal' end
  local rmt = c:match('^([iIvVxXlcdm]+)%.%s')
  if rmt and romanValue(rmt) and romanValue(rmt) <= 10 then
    return 'ordered', romanValue(rmt), 'roman'
  end
  local al = c:match('^([%a])%.%s')
  if al then
    local v = string.byte(al:lower()) - string.byte('a') + 1
    return 'ordered', v, 'alpha'
  end
  return nil
end

local function stripListMark(c, kind)
  if kind == 'bullet' then return c:gsub('^%*%s?', '') end
  if kind == 'ordered' then return c:gsub('^%S+%.%s?', '') end
  return c
end

local function isDefTerm(line)
  if line == nil then return false end
  if line.indent > 1 then return false end
  local term, def = line.content:match('^(.-)::%s?(.*)$')
  if not term or term == '' then return false end
  if not def:match('%S') and not line.content:sub(-2) == '::' then return false end
  if term:find('[%[%]%{%}|=%*/%:>]') then return false end
  if not term:match('%w') then return false end
  return true
end

local function isBlockStart(line)
  if line == nil then return false end
  local c = line.content
  if line.indent == 0 then
    if c:sub(1, 3) == '{{{' and not c:find('}}}', 4, true) then return true end
    if c:match('^(=+)%s') then return true end
    if c:match('^%-%-%-%-') and c:match('^%-+$') then return true end
    if c:sub(1, 2) == '||' then return true end
    if c:match('^%>') then return true end
  end
  if isListMarker(line) then return true end
  if isDefTerm(line) then return true end
  return false
end

local function parseCodeBlock()
  local openLine = cur().raw
  R.pos = R.pos + 1
  local body = {}
  while R.pos <= #R.lines do
    local l = R.lines[R.pos]
    if l.indent == 0 and l.content:sub(1, 3) == '}}}' then
      R.pos = R.pos + 1
      break
    end
    table.insert(body, l.raw)
    R.pos = R.pos + 1
  end
  local m = openLine:match('^%{%{%{%s*#!%s*(.-)%s*$')
  if not m and body[1] then
    m = body[1]:match('^#!%s*(.-)%s*$')
    if m then table.remove(body, 1) end
  end
  local bodyText = table.concat(body, '\n')
  if m then
    local name, args = m:match('^(%S+)%s*(.-)%s*$')
    if name == 'comment' then
      return nil
    elseif knownProcessors[name] then
      return pandoc.RawBlock('trac', openLine .. '\n' .. bodyText .. '\n}}}')
    else
      return pandoc.CodeBlock(bodyText, { class = name })
    end
  end
  return pandoc.CodeBlock(bodyText)
end

local function parseHeading()
  local line = cur()
  local eq, rest = line.content:match('^(=+)(.*)$')
  local level = #eq
  R.pos = R.pos + 1
  local s = rest:match('^%s*(.-)%s*$')
  s = s:gsub('=+%s*$', '')
  s = s:match('^%s*(.-)%s*$')
  local id
  local t, idv = s:match('^(.-)%s+#(%S+)$')
  if t then
    s, id = t, idv
  end
  s = s:match('^%s*(.-)%s*$')
  local ils = parseInlines(s)
  if id then
    return pandoc.Header(level, ils, { identifier = id })
  end
  return pandoc.Header(level, ils)
end

local function cellAlign(text)
  local lead = text:match('^%s') ~= nil
  local trail = text:match('%s$') ~= nil
  if lead and not trail then return pandoc.AlignRight end
  if trail and not lead then return pandoc.AlignLeft end
  return pandoc.AlignDefault
end

local function normalizeCell(raw)
  local isHeader = false
  if raw:sub(1, 1) == '=' then
    isHeader = true
    raw = raw:sub(2)
  end
  if isHeader and raw:sub(-1) == '=' then
    raw = raw:sub(1, -2)
  end
  local align = cellAlign(raw)
  local text = raw:match('^%s*(.-)%s*$') or ''
  return { isHeader = isHeader, align = align, text = text }
end

local function cellBlocks(text)
  if text == '' then return pandoc.Blocks{ pandoc.Plain{} } end
  return pandoc.Blocks{ pandoc.Para(parseInlines(text)) }
end

local function parseTable()
  local rawRows = {}
  local rowBuf = {}
  local function flushRow()
    if #rowBuf == 0 then return end
    local seg = table.concat(rowBuf)
    local body = seg:match('^%|%|(.*)$') or seg
    local cells = {}
    for piece in (body .. '||'):gmatch('(.-)||') do
      cells[#cells + 1] = piece
    end
    if seg:sub(-2) == '||' and #cells > 0 and cells[#cells] == '' then
      cells[#cells] = nil
    end
    rawRows[#rawRows + 1] = cells
    rowBuf = {}
  end
  while cur() and cur().indent == 0 and cur().content:sub(1, 2) == '||' do
    local rawline = cur().raw
    R.pos = R.pos + 1
    local continuation = rawline:find('%\\%s*$') ~= nil and rawline:match('%\\%s*$') ~= nil
    local cleaned = rawline:gsub('\\%s*$', '')
    rowBuf[#rowBuf + 1] = cleaned
    if not rawline:match('\\%s*$') then
      flushRow()
    end
  end
  flushRow()

  local rows = {}
  for _, cells in ipairs(rawRows) do
    local norm = {}
    for _, cell in ipairs(cells) do
      norm[#norm + 1] = normalizeCell(cell)
    end
    rows[#rows + 1] = norm
  end
  if #rows == 0 then return pandoc.Div({}) end

  local hasHead = false
  if rows[1] then
    for _, cell in ipairs(rows[1]) do
      if cell.isHeader then hasHead = true end
    end
  end
  local head, bodyRows = {}, {}
  local start = 1
  if hasHead then
    for _, cell in ipairs(rows[1]) do
      head[#head + 1] = cellBlocks(cell.text)
    end
    start = 2
  end
  for ri = start, #rows do
    local rr = {}
    for _, cell in ipairs(rows[ri]) do
      rr[#rr + 1] = cellBlocks(cell.text)
    end
    bodyRows[#bodyRows + 1] = rr
  end
  local numCols = 0
  for _, cells in ipairs(rows) do numCols = math.max(numCols, #cells) end
  local aligns, widths = {}, {}
  for ci = 1, numCols do
    aligns[ci] = pandoc.AlignDefault
    widths[ci] = 0
  end
  if hasHead then
    for ci, cell in ipairs(rows[1]) do aligns[ci] = cell.align end
  elseif #bodyRows > 0 then
    for ci, cell in ipairs(bodyRows[1]) do aligns[ci] = cell.align end
  end
  local simple = pandoc.SimpleTable(pandoc.Inlines({}), aligns, widths, head, bodyRows)
  return pandoc.utils.from_simple_table(simple)
end

local function buildQuoteBlocks(cols, d)
  local blocks = {}
  local para = {}
  local function flushPara()
    if #para > 0 then
      for _, b in ipairs(runOnLines(para)) do blocks[#blocks + 1] = b end
      para = {}
    end
  end
  local i = 1
  while i <= #cols do
    local c = cols[i]
    if c.depth < d then break end
    if c.depth == d then
      if c.text == '' then
        flushPara()
      else
        local ind, content = lineIndent(c.text)
        para[#para + 1] = { raw = c.text, indent = ind, content = content }
      end
      i = i + 1
    else
      flushPara()
      local run = {}
      while i <= #cols and cols[i].depth > d do
        run[#run + 1] = cols[i]
        i = i + 1
      end
      blocks[#blocks + 1] = pandoc.BlockQuote(buildQuoteBlocks(run, d + 1))
    end
  end
  flushPara()
  return blocks
end

local function parseBlockquote()
  local cols = {}
  while cur() and cur().indent == 0 and cur().content:match('^%>') do
    local rest = cur().content
    local depth = 0
    while rest:match('^%>') do
      rest = rest:gsub('^%>%s?', '')
      depth = depth + 1
    end
    rest = rest:gsub('^%s+', '')
    table.insert(cols, { depth = depth, text = rest })
    R.pos = R.pos + 1
  end
  return pandoc.BlockQuote(buildQuoteBlocks(cols, 1))
end

local function parseParagraph()
  local lines = {}
  while cur() do
    local c = cur()
    if c.raw == '' then break end
    if isBlockStart(c) then break end
    table.insert(lines, c)
    R.pos = R.pos + 1
  end
  local quoted = lines[1] and lines[1].indent >= 2 or false
  local parts = {}
  for _, l in ipairs(lines) do
    local text = l.content
    if quoted then text = text:gsub('^  ', '') end
    parts[#parts + 1] = text
  end
  if quoted then
    local entries = {}
    for _, t in ipairs(parts) do
      if t == '' then
        entries[#entries + 1] = { raw = '', indent = 0, content = '' }
      else
        local ind, content = lineIndent(t)
        entries[#entries + 1] = { raw = t, indent = ind, content = content }
      end
    end
    return pandoc.BlockQuote(runOnLines(entries))
  end
  local joined = table.concat(parts, '\n')
  if joined == '' then return nil end
  return pandoc.Para(parseInlines(joined))
end

local function itemBlocks(subs, listIndent, firstText)
  local entries = {}
  if firstText ~= '' then
    entries[#entries + 1] = { raw = firstText, indent = 0, content = firstText }
  end
  for _, s in ipairs(subs) do entries[#entries + 1] = s end
  return runOnLines(entries)
end

local function parseList()
  local kind, startNum, style = isListMarker(cur())
  local listIndent = cur().indent
  local items = {}
  while cur() do
    local k, num, st = isListMarker(cur())
    if not k or k ~= kind or st ~= style or cur().indent ~= listIndent then break end
    local firstText = stripListMark(cur().content, kind)
    R.pos = R.pos + 1
    local subs = {}
    while true do
      local n = cur()
      if not n then break end
      if n.raw == '' then
        local after = peekLine()
        if after and after.raw ~= '' and after.indent > listIndent
          and not isListMarker(after) and not isBlockStart(after) and not isDefTerm(after) then
          table.insert(subs, { raw = '', indent = 0, content = '' })
          R.pos = R.pos + 1
        else
          break
        end
      elseif n.indent <= listIndent then
        break
      else
        table.insert(subs, n)
        R.pos = R.pos + 1
      end
    end
    items[#items + 1] = itemBlocks(subs, listIndent, firstText)
  end
  if kind == 'bullet' then
    return pandoc.BulletList(items)
  end
  return pandoc.OrderedList(items, pandoc.ListAttributes(
    startNum or 1,
    style == 'alpha' and 'LowerAlpha' or style == 'roman' and 'LowerRoman' or 'Decimal',
    'Period'))
end

local function parseDefList()
  local items = {}
  while cur() and isDefTerm(cur()) do
    local termText, firstDef = cur().content:match('^(.-)::%s?(.*)$')
    R.pos = R.pos + 1
    termText = termText:match('^%s*(.-)%s*$')
    local defLines = {}
    if firstDef ~= nil and firstDef:match('%S') then defLines[#defLines + 1] = firstDef end
    while cur() do
      local n = cur()
      if n.raw == '' or n.indent < 2 then break end
      if isDefTerm(n) or isBlockStart(n) then break end
      defLines[#defLines + 1] = n.content:match('^%s*(.-)%s*$')
      R.pos = R.pos + 1
    end
    local defBlocks = { pandoc.Para(parseInlines(table.concat(defLines, ' '))) }
    items[#items + 1] = { parseInlines(termText), { defBlocks } }
  end
  return pandoc.DefinitionList(items)
end

local function parseBlock()
  local c = cur()
  if not c then return nil end
  if c.raw == '' then
    R.pos = R.pos + 1
    return nil
  end
  if c.indent == 0 and c.content:sub(1, 3) == '{{{' and not c.content:find('}}}', 4, true) then
    return parseCodeBlock()
  end
  local eq, rest = c.content:match('^(=+)(.*)$')
  if c.indent == 0 and eq and #eq <= 6 and rest:match('^%s') then
    return parseHeading()
  end
  if c.indent == 0 and c.content:match('^%-%-%-%-') and c.content:match('^%-+$') then
    R.pos = R.pos + 1
    return pandoc.HorizontalRule()
  end
  if c.indent == 0 and c.content:sub(1, 2) == '||' then
    return parseTable()
  end
  if c.indent == 0 and c.content:match('^%>') then
    return parseBlockquote()
  end
  if isListMarker(c) then
    return parseList()
  end
  if isDefTerm(c) then
    return parseDefList()
  end
  return parseParagraph()
end

parseBlocks = function()
  local blocks = {}
  while R.pos <= #R.lines do
    local b = parseBlock()
    if b then blocks[#blocks + 1] = b end
  end
  return blocks
end

function Reader(input, opts)
  local o = opts or {}
  local ext = o.extensions or ''
  CAMELCASE = ext:find('camelcase', 1, true) ~= nil
  resetLines(tostring(input))
  return pandoc.Pandoc(parseBlocks())
end

-- Inline monospace text. Prefer single backticks (as Trac accepts them),
-- fall back to {{{ ... }}} when the text itself contains a backtick.
local function inlineCode(text)
  if text:find('`', 1, true) then
    return '{{{' .. text .. '}}}'
  end
  return '`' .. text .. '`'
end

function M.inline(inline)
  local t = inline.t
  if t == 'Str' then
    return inline.text
  elseif t == 'Space' then
    return ' '
  elseif t == 'SoftBreak' then
    -- Trac treats a paragraph line-wrapping newline as a space.
    return ' '
  elseif t == 'LineBreak' then
    return ' [[BR]]\n'
  elseif t == 'Emph' then
    return "''" .. inlines(inline.content) .. "''"
  elseif t == 'Strong' then
    return "'''" .. inlines(inline.content) .. "'''"
  elseif t == 'Strikeout' then
    return '~~' .. inlines(inline.content) .. '~~'
  elseif t == 'Underline' then
    return '__' .. inlines(inline.content) .. '__'
  elseif t == 'Superscript' then
    return '^' .. inlines(inline.content) .. '^'
  elseif t == 'Subscript' then
    return ',,' .. inlines(inline.content) .. ',,'
  elseif t == 'SmallCaps' or t == 'Quoted' or t == 'Cite' then
    return inlines(inline.content)
  elseif t == 'Span' then
    return inlines(inline.content)
  elseif t == 'Code' then
    return inlineCode(inline.text)
  elseif t == 'Math' then
    if inline.mathtype == 'DisplayMath' then
      return '{{{\n' .. inline.text .. '\n}}}'
    end
    return inlineCode(inline.text)
  elseif t == 'RawInline' then
    if isTracFormat(inline.format) then
      return inline.text
    end
    return nil
  elseif t == 'Link' then
    return M.link(inline)
  elseif t == 'Image' then
    return M.image(inline)
  elseif t == 'Note' then
    -- Trac has no native footnotes; render the note content inline.
    return '(' .. inlines(inline.content) .. ')'
  end
  return nil
end

function M.link(link)
  local dest = link.target or ''
  local text = inlines(link.content)
  if text == '' then text = dest end

  if dest == '' then
    return text
  elseif dest:sub(1, 1) == '#' then
    -- Internal anchor.
    return '[#' .. dest:sub(2) .. ' ' .. text .. ']'
  elseif dest:match('^https?://') or dest:match('^ftp://') then
    if text == dest then
      -- Trac auto-links bare URLs.
      return dest
    end
    return '[' .. dest .. ' ' .. text .. ']'
  elseif dest:match('^mailto:') then
    return '[mailto:' .. dest:sub(8) .. ' ' .. text .. ']'
  else
    -- Relative destination: treat as a wiki page link.
    if text == dest then
      return '[wiki:' .. dest .. ']'
    end
    return '[wiki:' .. dest .. ' ' .. text .. ']'
  end
end

function M.image(image)
  local dest = image.src or ''
  local title = image.title or ''
  local alt = ''
  if image.caption ~= nil then
    alt = utils.stringify(image.caption)
  end
  if alt == '' and image.alt ~= nil then
    alt = utils.stringify(image.alt)
  end

  local params = {}
  if alt ~= '' and alt ~= dest then
    table.insert(params, 'alt=' .. alt)
  end
  if title ~= '' then
    table.insert(params, 'title=' .. title)
  end
  local macro = '[[Image(' .. dest
  if #params > 0 then
    macro = macro .. ', ' .. table.concat(params, ', ')
  end
  return macro .. ')]]'
end

inlines = function(list)
  local out = {}
  for _, inline in ipairs(list) do
    local s = M.inline(inline)
    if s ~= nil and s ~= '' then table.insert(out, s) end
  end
  return table.concat(out, '')
end

-- Render a paragraph/plain block, splitting display math onto its own line so
-- that {{{ ... }}} starts a preformatted block.
local function renderPara(content)
  local mathText = function(text)
    return text:match('^%s*(.-)%s*$')
  end
  local parts = {}
  local acc = {}
  local function flush()
    if #acc > 0 then
      table.insert(parts, inlines(acc))
      acc = {}
    end
  end
  for _, inline in ipairs(content) do
    if inline.t == 'Math' and inline.mathtype == 'DisplayMath' then
      flush()
      table.insert(parts, '{{{\n' .. mathText(inline.text) .. '\n}}}')
    else
      table.insert(acc, inline)
    end
  end
  flush()
  return table.concat(parts, '\n')
end

-- Approximate pandoc's default (non-GFM) auto_identifiers slug algorithm, so
-- that implicit heading ids can be recognized and suppressed.
local function implicitIdentifier(text)
  text = text:lower()
  text = text:gsub('[^%w%s%-%_%.]', '')
  local words = {}
  for w in text:gmatch('%S+') do
    table.insert(words, w)
  end
  local ident = table.concat(words, '-')
  ident = ident:gsub('^[^%a]*', '')
  return (ident ~= '') and ident or 'section'
end

-- Build the set of ids pandoc would auto-generate for the document's headers,
-- mirroring uniqueIdent's duplicate numbering (base, base-1, base-2, ...).
local function implicitHeadingIds(blocks, used)
  for _, block in ipairs(blocks) do
    if block.t == 'Header' then
      local base = implicitIdentifier(utils.stringify(block.content))
      local ident = base
      local n = 1
      while used[ident] do
        ident = base .. '-' .. n
        n = n + 1
      end
      if block.identifier == ident then
        used[block.identifier] = true
      else
        used[ident] = true
      end
    elseif block.t == 'Div' or block.t == 'Figure' then
      implicitHeadingIds(block.content, used)
    elseif block.t == 'BlockQuote' then
      implicitHeadingIds(block.content, used)
    end
  end
end

local implicitIds = {}

local function renderHeader(header)
  local eq = string.rep('=', header.level)
  local text = inlines(header.content)
  local id = header.identifier or ''
  local out = eq .. ' ' .. text
  -- Only emit explicit ids; suppress pandoc's auto-generated ones.
  if id ~= '' and not implicitIds[id] then
    out = out .. ' #' .. id
  end
  return out .. ' ' .. eq
end

local function renderCodeBlock(codeBlock)
  local cls = codeBlock.classes and codeBlock.classes[1] or nil
  local open = '{{{'
  if cls ~= nil then
    open = '{{{#!' .. cls
  end
  return open .. '\n' .. codeBlock.text .. '\n}}}'
end

renderListItem = function(item, depth, marker)
  local itemLines = {}
  local contIndent = string.rep(' ', 3 * depth)
  for i, blk in ipairs(item) do
    local s
    if blk.t == 'Plain' or blk.t == 'Para' then
      s = renderPara(blk.content)
    elseif blk.t == 'BulletList' then
      s = renderBulletList(blk.content, depth + 1)
    elseif blk.t == 'OrderedList' then
      s = renderOrderedList(blk, depth + 1)
    elseif blk.t == 'CodeBlock' then
      s = indentLines(contIndent, renderCodeBlock(blk))
    else
      s = indentLines(contIndent, M.block(blk))
    end
    if i == 1 then
      table.insert(itemLines, marker .. s)
    elseif blk.t == 'BulletList' or blk.t == 'OrderedList' then
      -- Nested lists already carry their own indentation.
      table.insert(itemLines, s)
    else
      table.insert(itemLines, indentLines(contIndent, s))
    end
  end
  return table.concat(itemLines, '\n')
end

renderBulletList = function(items, depth)
  local indent = string.rep(' ', 3 * (depth - 1))
  local out = {}
  for _, item in ipairs(items) do
    table.insert(out, renderListItem(item, depth, indent .. ' * '))
  end
  return table.concat(out, '\n')
end

renderOrderedList = function(list, depth)
  local indent = string.rep(' ', 3 * (depth - 1))
  local start = list.start or 1
  local out = {}
  for i, item in ipairs(list.content) do
    table.insert(out, renderListItem(item, depth, indent .. (start + i - 1) .. '. '))
  end
  return table.concat(out, '\n')
end

local function renderDefinitionList(list)
  local out = {}
  for _, pair in ipairs(list.content) do
    local term = inlines(pair[1])
    local defParts = {}
    for _, def in ipairs(pair[2]) do
      for _, blk in ipairs(def) do
        local s
        if blk.t == 'Plain' or blk.t == 'Para' then
          s = renderPara(blk.content)
        else
          s = M.block(blk)
        end
        table.insert(defParts, s)
      end
    end
    if #defParts == 0 then
      table.insert(out, term .. '::')
    else
      table.insert(out, term .. ':: ' .. defParts[1])
      for i = 2, #defParts do
        table.insert(out, '  ' .. defParts[i])
      end
    end
  end
  return table.concat(out, '\n')
end

local function cellText(cells)
  local parts = {}
  for _, blk in ipairs(cells) do
    local s
    if blk.t == 'Plain' or blk.t == 'Para' then
      s = renderPara(blk.content)
    else
      s = M.block(blk)
    end
    table.insert(parts, s)
  end
  return table.concat(parts, '[[BR]]')
end

local function renderTable(tbl)
  local simple = utils.to_simple_table(tbl)
  local aligns = simple.aligns or {}
  local out = {}
  if simple.headers ~= nil and #simple.headers > 0 then
    local cells = {}
    for i, cell in ipairs(simple.headers) do
      local c = cellText(cell)
      if c ~= '' then
        local align = aligns[i]
        if align == pandoc.AlignLeft then
          -- Text sticks to the left: ||=Title =||
          c = '=' .. c .. ' ='
        elseif align == pandoc.AlignRight then
          -- Text sticks to the right: ||= Title=||
          c = '= ' .. c .. '='
        else
          -- Centered / default: ||=Title=||
          c = '=' .. c .. '='
        end
      end
      table.insert(cells, c)
    end
    table.insert(out, '||' .. table.concat(cells, '||') .. '||')
  end
  for _, rowCells in ipairs(simple.rows) do
    local cells = {}
    for _, cell in ipairs(rowCells) do
      local c = cellText(cell)
      if c == '' then c = ' ' end
      table.insert(cells, ' ' .. c .. ' ')
    end
    table.insert(out, '||' .. table.concat(cells, '||') .. '||')
  end
  return table.concat(out, '\n')
end

function M.block(block)
  local t = block.t
  if t == 'Plain' or t == 'Para' then
    return renderPara(block.content)
  elseif t == 'Header' then
    return renderHeader(block)
  elseif t == 'BlockQuote' then
    return prefixLines('> ', renderBlocks(block.content))
  elseif t == 'BulletList' then
    return renderBulletList(block.content, 1)
  elseif t == 'OrderedList' then
    return renderOrderedList(block, 1)
  elseif t == 'DefinitionList' then
    return renderDefinitionList(block)
  elseif t == 'CodeBlock' then
    return renderCodeBlock(block)
  elseif t == 'RawBlock' then
    if isTracFormat(block.format) then
      return block.text
    end
    return nil
  elseif t == 'HorizontalRule' then
    return '----'
  elseif t == 'Table' then
    return renderTable(block)
  elseif t == 'LineBlock' then
    local parts = {}
    for _, line in ipairs(block.content) do
      table.insert(parts, inlines(line))
    end
    return table.concat(parts, '\n')
  elseif t == 'Div' then
    return renderBlocks(block.content)
  elseif t == 'Figure' then
    -- An image (and optional caption); render the contained image macro.
    return renderBlocks(block.content)
  elseif t == 'Null' then
    return nil
  end
  return nil
end

renderBlocks = function(blocks)
  local out = {}
  for _, block in ipairs(blocks) do
    local s = M.block(block)
    if s ~= nil and s ~= '' then
      table.insert(out, s)
    end
  end
  return table.concat(out, '\n\n')
end

-- A default template must be defined for standalone (-s) mode; pandoc will not
-- wrap the writer output itself, so the title heading is emitted in Writer().
Template = 'tracwiki'

function Writer(doc, opts)
  for k in pairs(implicitIds) do implicitIds[k] = nil end
  implicitHeadingIds(doc.blocks, implicitIds)
  local body = renderBlocks(doc.blocks)
  if opts.template ~= nil and doc.meta ~= nil then
    local title = utils.stringify(doc.meta.title)
    if title ~= '' then
      body = '= ' .. title .. ' =\n\n' .. body
    end
  end
  return body .. '\n'
end

return M