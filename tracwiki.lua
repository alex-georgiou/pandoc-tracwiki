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

local function renderHeader(header)
  local eq = string.rep('=', header.level)
  local text = inlines(header.content)
  local id = header.identifier or ''
  local out = eq .. ' ' .. text
  if id ~= '' then
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