-- Pandoc filter for scripts/build-docs.sh: turns docs/GUIDE.md into the static browser guide.
local repository = 'https://github.com/HugoLopes45/undoturn/blob/main/'
local title
local chapters = pandoc.List()

-- Links stay valid on GitHub and in docs/guide.html: images and anchors are local, other repository files open on GitHub.
local function resolve(target)
  if target:match('^#') or target:match('^%a[%w+.-]*:') or target:match('^//') then
    return target
  end
  local path, fragment = target:match('^([^#?]*)(.*)$')
  if path == 'GUIDE.md' then
    return fragment ~= '' and fragment or '#content'
  end
  if path:match('^images/') then
    return target
  end
  local parts = {}
  for segment in ('docs/' .. path):gmatch('[^/]+') do
    if segment == '..' then
      if #parts == 0 then
        error('link leaves the repository: ' .. target)
      end
      table.remove(parts)
    elseif segment ~= '.' then
      table.insert(parts, segment)
    end
  end
  return repository .. table.concat(parts, '/') .. fragment
end

local function contains_link(inlines)
  local found = false
  pandoc.walk_inline(pandoc.Span(inlines), {
    Link = function()
      found = true
    end,
  })
  return found
end

function Link(link)
  link.target = resolve(link.target)
  return link
end

function Image(image)
  image.src = resolve(image.src)
  return image
end

function Header(header)
  if header.level == 1 then
    if title then
      error('GUIDE.md must have exactly one level-1 heading')
    end
    title = header.content
    return {}
  end
  if header.level == 2 then
    chapters:insert(pandoc.MetaMap({
      id = pandoc.MetaString(header.identifier),
      text = pandoc.MetaInlines(header.content),
    }))
  end
  if not contains_link(header.content) then
    header.content = { pandoc.Link(header.content, '#' .. header.identifier) }
  end
  return header
end

function CodeBlock(block)
  -- A scrollable block must be reachable with the keyboard.
  block.attributes.tabindex = '0'
  return block
end

-- Tables with three or more columns stack on narrow screens: each body cell carries its column label.
-- Explicit roles keep the table semantics that some browsers drop when the CSS changes the display.
function Table(tbl)
  local classes = {}
  local head = tbl.head.rows[1]
  if head and #head.cells >= 3 then
    classes = { 'stack' }
    local labels = head.cells:map(function(cell)
      return pandoc.utils.stringify(cell.contents)
    end)
    tbl.attr.attributes.role = 'table'
    tbl.head.attr.attributes.role = 'rowgroup'
    head.attr.attributes.role = 'row'
    for _, cell in ipairs(head.cells) do
      cell.attr.attributes.role = 'columnheader'
    end
    for _, body in ipairs(tbl.bodies) do
      body.attr.attributes.role = 'rowgroup'
      for _, row in ipairs(body.body) do
        row.attr.attributes.role = 'row'
        for index, cell in ipairs(row.cells) do
          cell.attr.attributes.role = 'cell'
          cell.attr.attributes['data-label'] = labels[index]
        end
      end
    end
  end
  return pandoc.Div({ tbl }, pandoc.Attr('', { 'table-scroll', table.unpack(classes) }, { tabindex = '0' }))
end

function Pandoc(doc)
  if not title then
    error('GUIDE.md needs a level-1 heading')
  end
  doc.meta.title = pandoc.MetaInlines(title)
  doc.meta.chapters = chapters
  return doc
end
