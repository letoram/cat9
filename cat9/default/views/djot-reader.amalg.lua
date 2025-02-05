do
local _ENV = _ENV
package.preload[ "djot" ] = function( ... ) local arg = _G.arg;
--- @module 'djot'
--- Parse and render djot light markup format. See https://djot.net.
---
--- @usage
--- local djot = require("djot")
--- local input = "This is *djot*"
--- local doc = djot.parse(input)
--- -- render as HTML:
--- print(djot.render_html(doc))
---
--- -- render as AST:
--- print(djot.render_ast_pretty(doc))
---
--- -- or in JSON:
--- print(djot.render_ast_json(doc))
---
--- -- alter the AST with a filter:
--- local src = "return { str = function(e) e.text = e.text:upper() end }"
--- -- subordinate modules like filter can be accessed as fields
--- -- and are lazily loaded.
--- local filter = djot.filter.load_filter(src)
--- djot.filter.apply_filter(doc, filter)
---
--- -- streaming parser:
--- for startpos, endpos, annotation in djot.parse_events("*hello there*") do
---   print(startpos, endpos, annotation)
--- end

local unpack = unpack or table.unpack
local Parser = require("djot.block").Parser
local ast = require("djot.ast")
local html = require("djot.html")
local json = require("djot.json")
local filter = require("djot.filter")

--- @class StringHandle
local StringHandle = {}

--- @return (StringHandle)
function StringHandle:new()
  local buffer = {}
  setmetatable(buffer, StringHandle)
  StringHandle.__index = StringHandle
  return buffer
end

--- @param s (string)
function StringHandle:write(s)
  self[#self + 1] = s
end

--- @return (string)
function StringHandle:flush()
  return table.concat(self)
end

--- Parse a djot text and construct an abstract syntax tree (AST)
--- representing the document.
--- @param input (string) input string
--- @param sourcepos (boolean) if true, source positions are included in the AST
--- @param warn (function) function that processes a warning, accepting a warning
--- object with `pos` and `message` fields.
--- @return (AST)
local function parse(input, sourcepos, warn)
  local parser = Parser:new(input, warn)
  return ast.to_ast(parser, sourcepos)
end

--- Parses a djot text and returns an iterator over events, consisting
--- of a start position (bytes), and an position (bytes), and an
--- annotation.
--- @param input (string) input string
--- @param warn (function) function that processes a warning, accepting a warning
--- object with `pos` and `message` fields.
--- @return integer, integer, string an iterator over events.
---
---     for startpos, endpos, annotation in djot.parse_events("hello *world") do
---     ...
---     end
local function parse_events(input, warn)
  return Parser:new(input):events()
end

--- Render a document's AST in human-readable form.
--- @param doc (AST) the AST
--- @return (string) rendered AST
local function render_ast_pretty(doc)
  local handle = StringHandle:new()
  ast.render(doc, handle)
  return handle:flush()
end

--- Render a document's AST in JSON.
--- @param doc (AST) the AST
--- @return (string) rendered AST (JSON string)
local function render_ast_json(doc)
  return json.encode(doc) .. "\n"
end

--- Render a document as HTML.
--- @param doc (AST) the AST
--- @return (string) rendered document (HTML string)
local function render_html(doc)
  local handle = StringHandle:new()
  local renderer = html.Renderer:new()
  renderer:render(doc, handle)
  return handle:flush()
end

--- Render an event as a JSON array.
--- @param startpos (integer) starting byte position
--- @param endpos (integer) ending byte position
--- @param annotation (string) annotation of event
--- @return (string) rendered event (JSON string)
local function render_event(startpos, endpos, annotation)
  return string.format("[%q,%d,%d]", annotation, startpos, endpos)
end

--- Parse a document and render as a JSON array of events.
--- @param input (string) the djot document
--- @param warn (function) function that emits warnings, taking as argumnet
--- an object with fields 'message' and 'pos'
--- @return (string) rendered events (JSON string)
local function parse_and_render_events(input, warn)
  local handle = StringHandle:new()
  local idx = 0
  for startpos, endpos, annotation in parse_events(input, warn) do
    idx = idx + 1
    if idx == 1 then
      handle:write("[")
    else
      handle:write(",")
    end
    handle:write(render_event(startpos, endpos, annotation) .. "\n")
  end
  handle:write("]\n")
  return handle:flush()
end

--- djot version (string)
local version = "0.2.1"

--- @export
local G = {
  parse = parse,
  parse_events = parse_events,
  parse_and_render_events = parse_and_render_events,
  render_html = render_html,
  render_ast_pretty = render_ast_pretty,
  render_ast_json = render_ast_json,
  render_event = render_event,
  version = version
}

-- Lazily load submodules, e.g. djot.filter
setmetatable(G,{ __index = function(t,name)
                             local mod = require("djot." .. name)
                             rawset(t,name,mod)
                             return t[name]
                            end })

return G
end
end

do
local _ENV = _ENV
package.preload[ "djot.ast" ] = function( ... ) local arg = _G.arg;
--- @module 'djot.ast'
--- Construct an AST for a djot document.

--- @class Attributes
--- @field class? string
--- @field id? string

--- @class AST
--- @field t string tag for the node
--- @field s? string text for the node
--- @field c AST[] child node
--- @field alias string
--- @field level integer
--- @field startidx integer
--- @field startmarker string
--- @field styles table
--- @field style_marker string
--- @field attr Attributes
--- @field display boolean
--- @field references table
--- @field footnotes table
--- @field pos? string[]
--- @field destination? string[]

if not utf8 then -- if not lua 5.3 or higher...
  -- this is needed for the __pairs metamethod, used below
  -- The following code is derived from the compat53 rock:
  -- override pairs
  local oldpairs = pairs
  pairs = function(t)
    local mt = getmetatable(t)
    if type(mt) == "table" and type(mt.__pairs) == "function" then
      return mt.__pairs(t)
    else
      return oldpairs(t)
    end
  end
end
local unpack = unpack or table.unpack

local find, lower, sub, rep, format =
  string.find, string.lower, string.sub, string.rep, string.format

-- Creates a sparse array whose indices are byte positions.
-- sourcepos_map[bytepos] = "line:column:charpos"
local function make_sourcepos_map(input)
  local sourcepos_map = {line = {}, col = {}, charpos = {}}
  local line = 1
  local col = 0
  local charpos = 0
  local bytepos = 1

  local byte = string.byte(input, bytepos)
  while byte do
    col = col + 1
    charpos = charpos + 1
    -- get next code point:
    local newbytepos
    if byte < 0xC0 then
      newbytepos = bytepos + 1
    elseif byte < 0xE0 then
      newbytepos = bytepos + 2
    elseif byte < 0xF0 then
      newbytepos = bytepos + 3
    else
      newbytepos = bytepos + 4
    end
    while bytepos < newbytepos do
      sourcepos_map.line[bytepos] = line
      sourcepos_map.col[bytepos] = col
      sourcepos_map.charpos[bytepos] = charpos
      bytepos = bytepos + 1
    end
    if byte == 10 then -- newline
      line = line + 1
      col = 0
    end
    byte = string.byte(input, bytepos)
  end

  sourcepos_map.line[bytepos] = line + 1
  sourcepos_map.col[bytepos] = 1
  sourcepos_map.charpos[bytepos] = charpos + 1

  return sourcepos_map
end

local function add_string_content(node, buffer)
  if node.s then
    buffer[#buffer + 1] = node.s
  elseif node.t == "softbreak" then
    buffer[#buffer + 1] = "\n"
  elseif node.c then
    for i=1, #node.c do
      add_string_content(node.c[i], buffer)
    end
  end
end

local function get_string_content(node)
  local buffer = {};
  add_string_content(node, buffer)
  return table.concat(buffer)
end

local roman_digits = {
  i = 1,
  v = 5,
  x = 10,
  l = 50,
  c = 100,
  d = 500,
  m = 1000 }

local function roman_to_number(s)
  -- go backwards through the digits
  local total = 0
  local prevdigit = 0
  local i=#s
  while i > 0 do
    local c = lower(sub(s,i,i))
    local n = roman_digits[c]
    assert(n ~= nil, "Encountered bad character in roman numeral " .. s)
    if n < prevdigit then -- e.g. ix
      total = total - n
    else
      total = total + n
    end
    prevdigit = n
    i = i - 1
  end
  return total
end

local function get_list_start(marker, style)
  local numtype = string.gsub(style, "%p", "")
  local s = string.gsub(marker, "%p", "")
  if numtype == "1" then
    return tonumber(s)
  elseif numtype == "A" then
    return (string.byte(s) - string.byte("A") + 1)
  elseif numtype == "a" then
    return (string.byte(s) - string.byte("a") + 1)
  elseif numtype == "I" then
    return roman_to_number(s)
  elseif numtype == "i" then
    return roman_to_number(s)
  elseif numtype == "" then
    return nil
  end
end

local ignorable = {
  image_marker = true,
  escape = true,
  blankline = true
}

local function sortedpairs(compare_function, to_displaykey)
  return function(tbl)
    local keys = {}
    local k = nil
    k = next(tbl, k)
    while k do
      keys[#keys + 1] = k
      k = next(tbl, k)
    end
    table.sort(keys, compare_function)
    local keyindex = 0
    local function ordered_next(tabl,_)
      keyindex = keyindex + 1
      local key = keys[keyindex]
      -- use canonical names
      local displaykey = to_displaykey(key)
      if key then
        return displaykey, tabl[key]
      else
        return nil
      end
    end
    -- Return an iterator function, the table, starting point
    return ordered_next, tbl, nil
  end
end

-- provide children, tag, and text as aliases of c, t, s,
-- which we use above for better performance:
local mt = {}
local special = {
    children = 'c',
    text = 's',
    tag = 't' }
local displaykeys = {
    c = 'children',
    s = 'text',
    t = 'tag' }
mt.__index = function(table, key)
  local k = special[key]
  if k then
    return rawget(table, k)
  else
    return rawget(table, key)
  end
end
mt.__newindex = function(table, key, val)
  local k = special[key]
  if k then
    rawset(table, k, val)
  else
    rawset(table, key, val)
  end
end
mt.__pairs = sortedpairs(function(a,b)
    if a == "t" then -- t is always first
      return true
    elseif a == "s" then -- s is always second
      return (b ~= "t")
    elseif a == "c" then -- c only before references, footnotes
      return (b == "references" or b == "footnotes")
    elseif a == "references" then
      return (b == "footnotes")
    elseif a == "footnotes" then
      return false
    elseif b == "t" or b == "s" then
      return false
    elseif b == "c" or b == "references" or b == "footnotes" then
      return true
    else
      return (a < b)
    end
  end, function(k) return displaykeys[k] or k end)


--- Create a new AST node.
--- @param tag (string) tag for the node
--- @return (AST) node (table)
local function new_node(tag)
  local node = { t = tag, c = nil }
  setmetatable(node, mt)
  return node
end

--- Add `child` as a child of `node`.
--- @param node (AST) node parent node
--- @param child (AST) node child node
local function add_child(node, child)
  if (not node.c) then
    node.c = {child}
  else
    node.c[#node.c + 1] = child
  end
end

--- Returns true if `node` has children.
--- @param node (AST) node to check
--- @return (boolean) true if node has children
local function has_children(node)
  return (node.c and #node.c > 0)
end

--- Returns an attributes object.
--- @param tbl (Attributes?) table of attributes and values
--- @return (Attributes) attributes object (table including special metatable for
--- deterministic order of iteration)
local function new_attributes(tbl)
  local attr = tbl or {}
  -- ensure deterministic order of iteration
  setmetatable(attr, {__pairs = sortedpairs(function(a,b) return a < b end,
                                            function(k) return k end)})
  return attr
end

--- Insert an attribute into an attributes object.
--- @param attr (Attributes)
--- @param key (string) key of new attribute
--- @param val (string) value of new attribute
local function insert_attribute(attr, key, val)
  val = val:gsub("%s+", " ") -- normalize spaces
  if key == "class" then
    if attr.class then
      attr.class = attr.class .. " " .. val
    else
      attr.class = val
    end
  else
    attr[key] = val
  end
end

--- Copy attributes from `source` to `target`.
--- @param target (Attributes)
--- @param source (table) associating keys and values
local function copy_attributes(target, source)
  if source then
    for k,v in pairs(source) do
      insert_attribute(target, k, v)
    end
  end
end

--- @param targetnode (AST)
--- @param cs (AST)
local function insert_attributes_from_nodes(targetnode, cs)
  targetnode.attr = targetnode.attr or new_attributes()
  local i=1
  while i <= #cs do
    local x, y = cs[i].t, cs[i].s
    if x == "id" or x == "class" then
      insert_attribute(targetnode.attr, x, y)
    elseif x == "key" then
      local val = {}
      while cs[i + 1] and cs[i + 1].t == "value" do
        val[#val + 1] = cs[i + 1].s:gsub("\\(%p)", "%1")
        -- resolve backslash escapes
        i = i + 1
      end
      insert_attribute(targetnode.attr, y, table.concat(val,"\n"))
    end
    i = i + 1
  end
end

--- @param node (AST)
local function make_definition_list_item(node)
  node.t = "definition_list_item"
  if not has_children(node) then
    node.c = {}
  end
  if node.c[1] and node.c[1].t == "para" then
    node.c[1].t = "term"
  else
    table.insert(node.c, 1, new_node("term"))
  end
  if node.c[2] then
    local defn = new_node("definition")
    defn.c = {}
    for i=2,#node.c do
      defn.c[#defn.c + 1] = node.c[i]
      node.c[i] = nil
    end
    node.c[2] = defn
  end
end

local function resolve_style(list)
  local style = nil
  for k,i in pairs(list.styles) do
    if not style or i < style.priority then
      style = {name = k, priority = i}
    end
  end
  list.style = style.name
  list.styles = nil
  list.start = get_list_start(list.startmarker, list.style)
  list.startmarker = nil
end

local function get_verbatim_content(node)
  local s = get_string_content(node)
  -- trim space next to ` at beginning or end
  if find(s, "^ +`") then
    s = s:sub(2)
  end
  if find(s, "` +$") then
    s = s:sub(1, #s - 1)
  end
  return s
end

local function add_sections(ast)
  if not has_children(ast) then
    return ast
  end
  local newast = new_node("doc")
  local secs = { {sec = newast, level = 0 } }
  for _,node in ipairs(ast.c) do
    if node.t == "heading" then
      local level = node.level
      local curlevel = (#secs > 0 and secs[#secs].level) or 0
      if curlevel >= level then
        while secs[#secs].level >= level do
          local sec = table.remove(secs).sec
          add_child(secs[#secs].sec, sec)
        end
      end
      -- now we know: curlevel < level
      local newsec = new_node("section")
      newsec.attr = new_attributes{id = node.attr.id}
      node.attr.id = nil
      add_child(newsec, node)
      secs[#secs + 1] = {sec = newsec, level = level}
    else
      add_child(secs[#secs].sec, node)
    end
  end
  while #secs > 1 do
    local sec = table.remove(secs).sec
    add_child(secs[#secs].sec, sec)
  end
  assert(secs[1].sec == newast)
  return newast
end


--- Create an abstract syntax tree based on an event
--- stream and references.
--- @param parser (Parser) djot streaming parser
--- @param sourcepos (boolean) if true, include source positions
--- @return table representing the AST
local function to_ast(parser, sourcepos)
  local subject = parser.subject
  local warn = parser.warn
  if not warn then
    warn = function() end
  end
  local sourceposmap
  if sourcepos then
    sourceposmap = make_sourcepos_map(subject)
  end
  local references = {}
  local footnotes = {}
  local identifiers = {} -- identifiers used (to ensure uniqueness)

  -- generate auto identifier for heading
  local function get_identifier(s)
    local base = s:gsub("[][~!@#$%^&*(){}`,.<>\\|=+/?]","")
                  :gsub("^%s+",""):gsub("%s+$","")
                  :gsub("%s+","-")
    local i = 0
    local ident = base
    -- generate unique id
    while ident == "" or identifiers[ident] do
      i = i + 1
      if base == "" then
        base = "s"
      end
      ident = base .. "-" .. tostring(i)
    end
    identifiers[ident] = true
    return ident
  end

  local function format_sourcepos(bytepos)
    if bytepos then
      return string.format("%d:%d:%d", sourceposmap.line[bytepos],
              sourceposmap.col[bytepos], sourceposmap.charpos[bytepos])
    end
  end

  local function set_startpos(node, pos)
    if sourceposmap then
      local sp = format_sourcepos(pos)
      if node.pos then
        node.pos[1] = sp
      else
        node.pos = {sp, nil}
      end
    end
  end

  local function set_endpos(node, pos)
    if sourceposmap and node.pos then
      local ep = format_sourcepos(pos)
      if node.pos then
        node.pos[2] = ep
      else
        node.pos = {nil, ep}
      end
    end
  end

  local blocktag = {
    heading = true,
    div = true,
    list = true,
    list_item = true,
    code_block = true,
    para = true,
    blockquote = true,
    table = true,
    thematic_break = true,
    raw_block = true,
    reference_definition = true,
    footnote = true
  }

  local block_attributes = nil
  local function add_block_attributes(node)
    if block_attributes and blocktag[node.t:gsub("%|.*","")] then
      for i=1,#block_attributes do
        insert_attributes_from_nodes(node, block_attributes[i])
      end
      -- add to identifiers table so we don't get duplicate auto-generated ids
      if node.attr and node.attr.id then
        identifiers[node.attr.id] = true
      end
      block_attributes = nil
    end
  end

  -- two variables used for tight/loose list determination:
  local tags = {} -- used to keep track of blank lines
  local matchidx = 0 -- keep track of the index of the match

  local function is_tight(startidx, endidx, is_last_item)
    -- see if there are any blank lines between blocks in a list item.
    local blanklines = 0
    -- we don't care about blank lines at very end of list
    if is_last_item then
      while tags[endidx] == "blankline" or tags[endidx] == "-list_item" do
        endidx = endidx - 1
      end
    end
    for i=startidx, endidx do
      local tag = tags[i]
      if tag == "blankline" then
        if not ((string.find(tags[i+1], "%+list_item") or
                (string.find(tags[i+1], "%-list_item") and
                 (is_last_item or
                   string.find(tags[i+2], "%-list_item"))))) then
          -- don't count blank lines before list starts
          -- don't count blank lines at end of nested lists or end of last item
          blanklines = blanklines + 1
        end
      end
    end
    return (blanklines == 0)
  end

  local function add_child_to_tip(containers, child)
    if containers[#containers].t == "list" and
        not (child.t == "list_item" or child.t == "definition_list_item") then
      -- close list
      local oldlist = table.remove(containers)
      add_child_to_tip(containers, oldlist)
    end
    if child.t == "list" then
      if child.pos then
        child.pos[2] = child.c[#child.c].pos[2]
      end
      -- calculate tightness (TODO not quite right)
      local tight = true
      for i=1,#child.c do
        tight = tight and is_tight(child.c[i].startidx,
                                     child.c[i].endidx, i == #child.c)
        child.c[i].startidx = nil
        child.c[i].endidx = nil
      end
      child.tight = tight

      -- resolve style if still ambiguous
      resolve_style(child)
    end
    add_child(containers[#containers], child)
  end


  -- process a match:
  -- containers is the stack of containers, with #container
  -- being the one that would receive a new node
  local function handle_match(containers, startpos, endpos, annot)
    matchidx = matchidx + 1
    local mod, tag = string.match(annot, "^([-+]?)(.+)")
    tags[matchidx] = annot
    if ignorable[tag] then
      return
    end
    if mod == "+" then
      -- process open match:
      -- * open a new node and put it at end of containers stack
      -- * depending on the tag name, do other things
      local node = new_node(tag)
      set_startpos(node, startpos)

      -- add block attributes if any have accumulated:
      add_block_attributes(node)

      if tag == "heading" then
         node.level = (endpos - startpos) + 1

      elseif find(tag, "^list_item") then
        node.t = "list_item"
        node.startidx = matchidx -- for tight/loose determination
        local _, _, style_marker = string.find(tag, "(%|.*)")
        local styles = {}
        if style_marker then
          local i=1
          for sty in string.gmatch(style_marker, "%|([^%|%]]*)") do
            styles[sty] = i
            i = i + 1
          end
        end
        node.style_marker = style_marker

        local marker = string.match(subject, "^%S+", startpos)

        -- adjust container stack so that the tip can accept this
        -- kind of list item, adding a list if needed and possibly
        -- closing an existing list

        local tip = containers[#containers]
        if tip.t ~= "list" then
          -- container is not a list ; add one
          local list = new_node("list")
          set_startpos(list, startpos)
          list.styles = styles
          list.attr = node.attr
          list.startmarker = marker
          node.attr = nil
          containers[#containers + 1] = list
        else
          -- it's a list, but is it the right kind?
          local matched_styles = {}
          local has_match = false
          for k,_ in pairs(styles) do
            if tip.styles[k] then
              has_match = true
              matched_styles[k] = styles[k]
            end
          end
          if has_match then
            -- yes, list can accept this item
            tip.styles = matched_styles
          else
            -- no, list can't accept this item ; close it
            local oldlist = table.remove(containers)
            add_child_to_tip(containers, oldlist)
            -- add a new sibling list node with the right style
            local list = new_node("list")
            set_startpos(list, startpos)
            list.styles = styles
            list.attr = node.attr
            list.startmarker = marker
            node.attr = nil
            containers[#containers + 1] = list
          end
        end


      end

      -- add to container stack
      containers[#containers + 1] = node

    elseif mod == "-" then
      -- process close match:
      -- * check end of containers stack; if tag matches, add
      --   end position, pop the item off the stack, and add
      --   it as a child of the next container on the stack
      -- * if it doesn't match, issue a warning and ignore this tag

      if containers[#containers].t == "list" then
        local listnode = table.remove(containers)
        add_child_to_tip(containers, listnode)
      end

      if tag == containers[#containers].t then
        local node = table.remove(containers)
        set_endpos(node, endpos)

        if node.t == "block_attributes" then
          if not block_attributes then
            block_attributes = {}
          end
          block_attributes[#block_attributes + 1] = node.c
          return -- we don't add this to parent; instead we store
          -- the block attributes and add them to the next block

        elseif node.t == "attributes" then
          -- parse attributes, add to last node
          local tip = containers[#containers]
          --- @type AST|false
          local prevnode = has_children(tip) and tip.c[#tip.c]
          if prevnode then
            local endswithspace = false
            if prevnode.t == "str" then
              -- split off last consecutive word of string
              -- to which to attach attributes
              local lastwordpos = string.find(prevnode.s, "[^%s]+$")
              if not lastwordpos then
                endswithspace = true
              elseif lastwordpos > 1 then
                local newnode = new_node("str")
                newnode.s = sub(prevnode.s, lastwordpos, -1)
                prevnode.s = sub(prevnode.s, 1, lastwordpos - 1)
                add_child_to_tip(containers, newnode)
                prevnode = newnode
              end
            end
            if has_children(node) and not endswithspace then
              insert_attributes_from_nodes(prevnode, node.c)
            else
              warn({message = "Ignoring unattached attribute", pos = startpos})
            end
          else
            warn({message = "Ignoring unattached attribute", pos = startpos})
          end
          return -- don't add the attribute node to the tree

        elseif tag == "reference_definition" then
          local dest = ""
          local key
          for i=1,#node.c do
            if node.c[i].t == "reference_key" then
              key = node.c[i].s
            end
            if node.c[i].t == "reference_value" then
              dest = dest .. node.c[i].s
            end
          end
          references[key] = new_node("reference")
          references[key].destination = dest
          if node.attr then
            references[key].attr = node.attr
          end
          return -- don't include in tree

        elseif tag == "footnote" then
          local label
          if has_children(node) and node.c[1].t == "note_label" then
            label = node.c[1].s
            table.remove(node.c, 1)
          end
          if label then
            footnotes[label] = node
          end
          return -- don't include in tree


        elseif tag == "table" then

          -- Children are the rows. Look for a separator line:
          -- if found, make the preceding rows headings
          -- and set attributes for column alignments on the table.

          local i=1
          local aligns = {}
          while i <= #node.c do
            local found, align, _
            if node.c[i].t == "row" then
              local row = node.c[i].c
              for j=1,#row do
                found, _, align = find(row[j].t, "^separator_(.*)")
                if not found then
                  break
                end
                aligns[j] = align
              end
              if found and #aligns > 0 then
                -- set previous row to head and adjust aligns
                local prevrow = node.c[i - 1]
                if prevrow and prevrow.t == "row" then
                  prevrow.head = true
                  for k=1,#prevrow.c do
                    -- set head on cells too
                    prevrow.c[k].head = true
                    if aligns[k] ~= "default" then
                      prevrow.c[k].align = aligns[k]
                    end
                  end
                end
                table.remove(node.c, i) -- remove sep line
                -- we don't need to increment i because we removed ith elt
              else
                if #aligns > 0 then
                  for l=1,#node.c[i].c do
                    if aligns[l] ~= "default" then
                      node.c[i].c[l].align = aligns[l]
                    end
                  end
                end
                i = i + 1
              end
            end
          end

        elseif tag == "code_block" then
          if has_children(node) then
            if node.c[1].t == "code_language" then
              node.lang = node.c[1].s
              table.remove(node.c, 1)
            elseif node.c[1].t == "raw_format" then
              local fmt = node.c[1].s:sub(2)
              table.remove(node.c, 1)
              node.t = "raw_block"
              node.format = fmt
            end
          end
          node.s = get_string_content(node)
          node.c = nil

        elseif find(tag, "^list_item") then
          node.t = "list_item"
          node.endidx = matchidx -- for tight/loose determination

          if node.style_marker == "|:" then
            make_definition_list_item(node)
          end

          if node.style_marker == "|X" and has_children(node) then
            if node.c[1].t == "checkbox_checked" then
              node.checkbox = "checked"
              table.remove(node.c, 1)
            elseif node.c[1].t == "checkbox_unchecked" then
              node.checkbox = "unchecked"
              table.remove(node.c, 1)
            end
          end

          node.style_marker = nil

        elseif tag == "inline_math" then
          node.t = "math"
          node.s = get_verbatim_content(node)
          node.c = nil
          node.display = false
          node.attr = new_attributes{class = "math inline"}

        elseif tag == "display_math" then
          node.t = "math"
          node.s = get_verbatim_content(node)
          node.c = nil
          node.display = true
          node.attr = new_attributes{class = "math display"}

        elseif tag == "imagetext" then
          node.t = "image"

        elseif tag == "linktext" then
          node.t = "link"

        elseif tag == "div" then
          node.c = node.c or {}
          if node.c[1] and node.c[1].t == "class" then
            node.attr = new_attributes(node.attr)
            insert_attribute(node.attr, "class", get_string_content(node.c[1]))
            table.remove(node.c, 1)
          end

        elseif tag == "verbatim" then
          node.s = get_verbatim_content(node)
          node.c = nil

        elseif tag == "url" then
          node.destination = get_string_content(node)

        elseif tag == "email" then
          node.destination = "mailto:" .. get_string_content(node)

        elseif tag == "caption" then
          local tip = containers[#containers]
          local prevnode = has_children(tip) and tip.c[#tip.c]
          if prevnode and prevnode.t == "table" then
            -- move caption in table node
            table.insert(prevnode.c, 1, node)
          else
            warn({ message = "Ignoring caption without preceding table",
                   pos = startpos })
          end
          return

        elseif tag == "heading" then
          local heading_str =
                 get_string_content(node):gsub("^%s+",""):gsub("%s+$","")
          if not node.attr then
            node.attr = new_attributes{}
          end
          if not node.attr.id then  -- generate id attribute from heading
            insert_attribute(node.attr, "id", get_identifier(heading_str))
          end
          -- insert into references unless there's a same-named one already:
          if not references[heading_str] then
            references[heading_str] =
              new_node("reference")
            references[heading_str].destination = "#" .. node.attr.id
          end

        elseif tag == "destination" then
           local tip = containers[#containers]
           local prevnode = has_children(tip) and tip.c[#tip.c]
           assert(prevnode and (prevnode.t == "image" or prevnode.t == "link"),
                  "destination with no preceding link or image")
           prevnode.destination = get_string_content(node):gsub("\r?\n", "")
           return  -- do not put on container stack

        elseif tag == "reference" then
           local tip = containers[#containers]
           local prevnode = has_children(tip) and tip.c[#tip.c]
           assert(prevnode and (prevnode.t == "image" or prevnode.t == "link"),
                 "reference with no preceding link or image")
           if has_children(node) then
             prevnode.reference = get_string_content(node):gsub("\r?\n", " ")
           else
             prevnode.reference = get_string_content(prevnode):gsub("\r?\n", " ")
           end
           return  -- do not put on container stack
        end

        add_child_to_tip(containers, node)
      else
        assert(false, "unmatched " .. annot .. " encountered at byte " ..
                  startpos)
        return
      end
    else
      -- process leaf node:
      -- * add position info
      -- * special handling depending on tag type
      -- * add node as child of container at end of containers stack
      local node = new_node(tag)
      add_block_attributes(node)
      set_startpos(node, startpos)
      set_endpos(node, endpos)

      -- special handling:
      if tag == "softbreak" then
        node.s = nil
      elseif tag == "reference_key" then
        node.s = sub(subject, startpos + 1, endpos - 1)
      elseif tag == "footnote_reference" then
        node.s = sub(subject, startpos + 2, endpos - 1)
      elseif tag == "symbol" then
        node.alias = sub(subject, startpos + 1, endpos - 1)
      elseif tag == "raw_format" then
        local tip = containers[#containers]
        local prevnode = has_children(tip) and tip.c[#tip.c]
        if prevnode and prevnode.t == "verbatim" then
          local s = get_string_content(prevnode)
          prevnode.t = "raw_inline"
          prevnode.s = s
          prevnode.c = nil
          prevnode.format = sub(subject, startpos + 2, endpos - 1)
          return  -- don't add this node to containers
        else
          node.s = sub(subject, startpos, endpos)
        end
      else
        node.s = sub(subject, startpos, endpos)
      end

      add_child_to_tip(containers, node)

    end
  end

  local doc = new_node("doc")
  local containers = {doc}
  for sp, ep, annot in parser:events() do
    handle_match(containers, sp, ep, annot)
  end
  -- close any open containers
  while #containers > 1 do
    local node = table.remove(containers)
    add_child_to_tip(containers, node)
    -- note: doc container doesn't have pos, so we check:
    if sourceposmap and containers[#containers].pos then
      containers[#containers].pos[2] = node.pos[2]
    end
  end
  doc = add_sections(doc)

  doc.references = references
  doc.footnotes = footnotes

  return doc
end

local function render_node(node, handle, indent)
  indent = indent or 0
  handle:write(rep(" ", indent))
  if indent > 128 then
    handle:write("(((DEEPLY NESTED CONTENT OMITTED)))\n")
    return
  end

  if node.t then
    handle:write(node.t)
    if node.pos then
      handle:write(format(" (%s-%s)", node.pos[1], node.pos[2]))
    end
    for k,v in pairs(node) do
      if type(k) == "string" and k ~= "children" and
          k ~= "tag" and k ~= "pos" and k ~= "attr"  and
          k ~= "references" and k ~= "footnotes" then
        handle:write(format(" %s=%q", k, tostring(v)))
      end
    end
    if node.attr then
      for k,v in pairs(node.attr) do
        handle:write(format(" %s=%q", k, v))
      end
    end
  else
    io.stderr:write("Encountered node without tag:\n" ..
                      require'inspect'(node))
    os.exit(1)
  end
  handle:write("\n")
  if node.c then
    for _,v in ipairs(node.c) do
      render_node(v, handle, indent + 2)
    end
  end
end

--- Render an AST in human-readable form, with indentation
--- showing the hierarchy.
--- @param doc (AST) djot AST
--- @param handle (StringHandle) handle to which to write content
local function render(doc, handle)
  render_node(doc, handle, 0)
  if next(doc.references) ~= nil then
    handle:write("references\n")
    for k,v in pairs(doc.references) do
      handle:write(format("  [%q] =\n", k))
      render_node(v, handle, 4)
    end
  end
  if next(doc.footnotes) ~= nil then
    handle:write("footnotes\n")
    for k,v in pairs(doc.footnotes) do
      handle:write(format("  [%q] =\n", k))
      render_node(v, handle, 4)
    end
  end
end

--- @export
return { to_ast = to_ast,
         render = render,
         insert_attribute = insert_attribute,
         copy_attributes = copy_attributes,
         new_attributes = new_attributes,
         new_node = new_node,
         add_child = add_child,
         has_children = has_children }
end
end

do
local _ENV = _ENV
package.preload[ "djot.attributes" ] = function( ... ) local arg = _G.arg;
local find, sub = string.find, string.sub

-- Parser for attributes
-- attributes { id = "foo", class = "bar baz",
--              key1 = "val1", key2 = "val2" }
-- syntax:
--
-- attributes <- '{' whitespace* attribute (whitespace attribute)* whitespace* '}'
-- attribute <- identifier | class | keyval
-- identifier <- '#' name
-- class <- '.' name
-- name <- (nonspace, nonpunctuation other than ':', '_', '-')+
-- keyval <- key '=' val
-- key <- (ASCII_ALPHANUM | ':' | '_' | '-')+
-- val <- bareval | quotedval
-- bareval <- (ASCII_ALPHANUM | ':' | '_' | '-')+
-- quotedval <- '"' ([^"] | '\"') '"'

-- states:
local SCANNING = 0
local SCANNING_ID = 1
local SCANNING_CLASS= 2
local SCANNING_KEY = 3
local SCANNING_VALUE = 4
local SCANNING_BARE_VALUE = 5
local SCANNING_QUOTED_VALUE = 6
local SCANNING_QUOTED_VALUE_CONTINUATION = 7
local SCANNING_ESCAPED = 8
local SCANNING_ESCAPED_IN_CONTINUATION = 9
local SCANNING_COMMENT = 10
local FAIL = 11
local DONE = 12
local START = 13

local AttributeParser = {}

local handlers = {}

handlers[START] = function(self, pos)
  if find(self.subject, "^{", pos) then
    return SCANNING
  else
    return FAIL
  end
end

handlers[FAIL] = function(_self, _pos)
  return FAIL
end

handlers[DONE] = function(_self, _pos)
  return DONE
end

handlers[SCANNING] = function(self, pos)
  local c = sub(self.subject, pos, pos)
  if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
    return SCANNING
  elseif c == '}' then
    return DONE
  elseif c == '#' then
    self.begin = pos
    return SCANNING_ID
  elseif c == '%' then
    self.begin = pos
    return SCANNING_COMMENT
  elseif c == '.' then
    self.begin = pos
    return SCANNING_CLASS
  elseif find(c, "^[%a%d_:-]") then
    self.begin = pos
    return SCANNING_KEY
  else -- TODO
    return FAIL
  end
end

handlers[SCANNING_COMMENT] = function(self, pos)
  local c = sub(self.subject, pos, pos)
  if c == "%" then
    return SCANNING
  elseif c == "}" then
    return DONE
  else
    return SCANNING_COMMENT
  end
end

handlers[SCANNING_ID] = function(self, pos)
  local c = sub(self.subject, pos, pos)
  if find(c, "^[^%s%p]") or c == "_" or c == "-" or c == ":" then
    return SCANNING_ID
  elseif c == '}' then
    if self.lastpos > self.begin then
      self:add_match(self.begin + 1, self.lastpos, "id")
    end
    self.begin = nil
    return DONE
  elseif find(c, "^%s") then
    if self.lastpos > self.begin then
      self:add_match(self.begin + 1, self.lastpos, "id")
    end
    self.begin = nil
    return SCANNING
  else
    return FAIL
  end
end

handlers[SCANNING_CLASS] = function(self, pos)
  local c = sub(self.subject, pos, pos)
  if find(c, "^[^%s%p]") or c == "_" or c == "-" or c == ":" then
    return SCANNING_CLASS
  elseif c == '}' then
    if self.lastpos > self.begin then
      self:add_match(self.begin + 1, self.lastpos, "class")
    end
    self.begin = nil
    return DONE
  elseif find(c, "^%s") then
    if self.lastpos > self.begin then
      self:add_match(self.begin + 1, self.lastpos, "class")
    end
    self.begin = nil
    return SCANNING
  else
    return FAIL
  end
end

handlers[SCANNING_KEY] = function(self, pos)
  local c = sub(self.subject, pos, pos)
  if c == "=" then
    self:add_match(self.begin, self.lastpos, "key")
    self.begin = nil
    return SCANNING_VALUE
  elseif find(c, "^[%a%d_:-]") then
    return SCANNING_KEY
  else
    return FAIL
  end
end

handlers[SCANNING_VALUE] = function(self, pos)
  local c = sub(self.subject, pos, pos)
  if c == '"' then
    self.begin = pos
    return SCANNING_QUOTED_VALUE
  elseif find(c, "^[%a%d_:-]") then
    self.begin = pos
    return SCANNING_BARE_VALUE
  else
    return FAIL
  end
end

handlers[SCANNING_BARE_VALUE] = function(self, pos)
  local c = sub(self.subject, pos, pos)
  if find(c, "^[%a%d_:-]") then
    return SCANNING_BARE_VALUE
  elseif c == '}' then
    self:add_match(self.begin, self.lastpos, "value")
    self.begin = nil
    return DONE
  elseif find(c, "^%s") then
    self:add_match(self.begin, self.lastpos, "value")
    self.begin = nil
    return SCANNING
  else
    return FAIL
  end
end

handlers[SCANNING_ESCAPED] = function(_self, _pos)
  return SCANNING_QUOTED_VALUE
end

handlers[SCANNING_ESCAPED_IN_CONTINUATION] = function(_self, _pos)
  return SCANNING_QUOTED_VALUE_CONTINUATION
end

handlers[SCANNING_QUOTED_VALUE] = function(self, pos)
  local c = sub(self.subject, pos, pos)
  if c == '"' then
    self:add_match(self.begin + 1, self.lastpos, "value")
    self.begin = nil
    return SCANNING
  elseif c == "\n" then
    self:add_match(self.begin + 1, self.lastpos, "value")
    self.begin = nil
    return SCANNING_QUOTED_VALUE_CONTINUATION
  elseif c == "\\" then
    return SCANNING_ESCAPED
  else
    return SCANNING_QUOTED_VALUE
  end
end

handlers[SCANNING_QUOTED_VALUE_CONTINUATION] = function(self, pos)
  local c = sub(self.subject, pos, pos)
  if self.begin == nil then
    self.begin = pos
  end
  if c == '"' then
    self:add_match(self.begin, self.lastpos, "value")
    self.begin = nil
    return SCANNING
  elseif c == "\n" then
    self:add_match(self.begin, self.lastpos, "value")
    self.begin = nil
    return SCANNING_QUOTED_VALUE_CONTINUATION
  elseif c == "\\" then
    return SCANNING_ESCAPED_IN_CONTINUATION
  else
    return SCANNING_QUOTED_VALUE_CONTINUATION
  end
end

function AttributeParser:new(subject)
  local state = {
    subject = subject,
    state = START,
    begin = nil,
    lastpos = nil,
    matches = {}
    }
  setmetatable(state, self)
  self.__index = self
  return state
end

function AttributeParser:add_match(sp, ep, tag)
  self.matches[#self.matches + 1] = {sp, ep, tag}
end

function AttributeParser:get_matches()
  return self.matches
end

-- Feed parser a slice of text from the subject, between
-- startpos and endpos inclusive.  Return status, position,
-- where status is either "done" (position should point to
-- final '}'), "fail" (position should point to first character
-- that could not be parsed), or "continue" (position should
-- point to last character parsed).
function AttributeParser:feed(startpos, endpos)
  local pos = startpos
  while pos <= endpos do
    self.state = handlers[self.state](self, pos)
    if self.state == DONE then
      return "done", pos
    elseif self.state == FAIL then
      self.lastpos = pos
      return "fail", pos
    else
      self.lastpos = pos
      pos = pos + 1
    end
  end
  return "continue", endpos
end

--[[
local test = function()
  local parser = AttributeParser:new("{a=b #ident\n.class\nkey=val1\n .class key2=\"val two \\\" ok\" x")
  local x,y,z = parser:feed(1,56)
  print(require'inspect'(parser:get_matches{}))
end

test()
--]]

return { AttributeParser = AttributeParser }
end
end

do
local _ENV = _ENV
package.preload[ "djot.block" ] = function( ... ) local arg = _G.arg;
local InlineParser = require("djot.inline").InlineParser
local attributes = require("djot.attributes")
local unpack = unpack or table.unpack
local find, sub, byte = string.find, string.sub, string.byte

local Container = {}

function Container:new(spec, data)
  self = spec
  local contents = {}
  setmetatable(contents, self)
  self.__index = self
  if data then
    for k,v in pairs(data) do
      contents[k] = v
    end
  end
  return contents
end

local function get_list_styles(marker)
  if marker == "+" or marker == "-" or marker == "*" or marker == ":" then
    return {marker}
  elseif find(marker, "^[+*-] %[[Xx ]%]") then
    return {"X"} -- task list
  elseif find(marker, "^[(]?%d+[).]") then
    return {(marker:gsub("%d+","1"))}
  -- in ambiguous cases we return two values
  elseif find(marker, "^[(]?[ivxlcdm][).]") then
    return {(marker:gsub("%a+", "i")), (marker:gsub("%a+", "a"))}
  elseif find(marker, "^[(]?[IVXLCDM][).]") then
    return {(marker:gsub("%a+", "I")), (marker:gsub("%a+", "A"))}
  elseif find(marker, "^[(]?%l[).]") then
    return {(marker:gsub("%l", "a"))}
  elseif find(marker, "^[(]?%u[).]") then
    return {(marker:gsub("%u", "A"))}
  elseif find(marker, "^[(]?[ivxlcdm]+[).]") then
    return {(marker:gsub("%a+", "i"))}
  elseif find(marker, "^[(]?[IVXLCDM]+[).]") then
    return {(marker:gsub("%a+", "I"))}
  else -- doesn't match any list style
    return {}
  end
end

---@class Parser
---@field subject string
---@field warn function
---@field matches table
---@field containers table
local Parser = {}

function Parser:new(subject, warn)
  -- ensure the subject ends with a newline character
  if not subject:find("[\r\n]$") then
    subject = subject .. "\n"
  end
  local state = {
    warn = warn or function() end,
    subject = subject,
    indent = 0,
    startline = nil,
    starteol = nil,
    endeol = nil,
    matches = {},
    containers = {},
    pos = 1,
    last_matched_container = 0,
    timer = {},
    finished_line = false,
    returned = 0 }
  setmetatable(state, self)
  self.__index = self
  return state
end

-- parameters are start and end position
function Parser:parse_table_row(sp, ep)
  local orig_matches = #self.matches  -- so we can rewind
  local startpos = self.pos
  self:add_match(sp, sp, "+row")
  -- skip | and any initial space in the cell:
  self.pos = find(self.subject, "%S", sp + 1)
  -- check to see if we have a separator line
  local seps = {}
  local p = self.pos
  local sepfound = false
  while not sepfound do
    local sepsp, sepep, left, right, trailing =
      find(self.subject, "^(%:?)%-%-*(%:?)([ \t]*%|[ \t]*)", p)
    if sepep then
      local st = "separator_default"
      if #left > 0 and #right > 0 then
        st = "separator_center"
      elseif #right > 0 then
        st = "separator_right"
      elseif #left > 0 then
        st = "separator_left"
      end
      seps[#seps + 1] = {sepsp, sepep - #trailing, st}
      p = sepep + 1
      if p == self.starteol then
        sepfound = true
        break
      end
    else
      break
    end
  end
  if sepfound then
    for i=1,#seps do
      self:add_match(unpack(seps[i]))
    end
    self:add_match(self.starteol - 1, self.starteol - 1, "-row")
    self.pos = self.starteol
    self.finished_line = true
    return true
  end
  local inline_parser = InlineParser:new(self.subject, self.warn)
  self:add_match(sp, sp, "+cell")
  local complete_cell = false
  while self.pos <= ep do
    -- parse a chunk as inline content
    local nextbar, _
    while not nextbar do
      _, nextbar = self:find("^[^|\r\n]*|")
      if not nextbar then
        break
      end
      if string.find(self.subject, "^\\", nextbar - 1) then -- \|
        inline_parser:feed(self.pos, nextbar)
        self.pos = nextbar + 1
        nextbar = nil
      else
        inline_parser:feed(self.pos, nextbar - 1)
        if inline_parser:in_verbatim() then
          inline_parser:feed(nextbar, nextbar)
          self.pos = nextbar + 1
          nextbar = nil
        else
          self.pos = nextbar + 1
        end
      end
    end
    complete_cell = nextbar
    if not complete_cell then
      break
    end
    -- add a table cell
    local cell_matches = inline_parser:get_matches()
    for i=1,#cell_matches do
      local s,e,ann = unpack(cell_matches[i])
      if i == #cell_matches and ann == "str" then
        -- strip trailing space
        while byte(self.subject, e) == 32 and e >= s do
          e = e - 1
        end
      end
      self:add_match(s,e,ann)
    end
    self:add_match(nextbar, nextbar, "-cell")
    if nextbar < ep then
      -- reset inline parser state
      inline_parser = InlineParser:new(self.subject, self.warn)
      self:add_match(nextbar, nextbar, "+cell")
      self.pos = find(self.subject, "%S", self.pos)
    end
  end
  if not complete_cell then
    -- rewind, this is not a valid table row
    self.pos = startpos
    for i = orig_matches,#self.matches do
      self.matches[i] = nil
    end
    return false
  else
    self:add_match(self.pos, self.pos, "-row")
    self.pos = self.starteol
    self.finished_line = true
    return true
  end
end

function Parser:specs()
  return {
    { name = "para",
      is_para = true,
      content = "inline",
      continue = function()
        if self:find("^%S") then
          return true
        else
          return false
        end
      end,
      open = function(spec)
        self:add_container(Container:new(spec,
            { inline_parser =
                InlineParser:new(self.subject, self.warn) }))
        self:add_match(self.pos, self.pos, "+para")
        return true
      end,
      close = function()
        self:get_inline_matches()
        local last = self.matches[#self.matches] or {self.pos, self.pos, ""}
        local sp, ep, annot = unpack(last)
        self:add_match(ep + 1, ep + 1, "-para")
        self.containers[#self.containers] = nil
      end
    },

    { name = "caption",
      is_para = false,
      content = "inline",
      continue = function()
        return self:find("^%S")
      end,
      open = function(spec)
        local _, ep = self:find("^%^[ \t]+")
        if ep then
          self.pos = ep + 1
          self:add_container(Container:new(spec,
            { inline_parser =
                InlineParser:new(self.subject, self.warn) }))
          self:add_match(self.pos, self.pos, "+caption")
          return true
        end
      end,
      close = function()
        self:get_inline_matches()
        self:add_match(self.pos - 1, self.pos - 1, "-caption")
        self.containers[#self.containers] = nil
      end
    },

    { name = "blockquote",
      content = "block",
      continue = function()
        if self:find("^%>%s") then
          self.pos = self.pos + 1
          return true
        else
          return false
        end
      end,
      open = function(spec)
        if self:find("^%>%s") then
          self:add_container(Container:new(spec))
          self:add_match(self.pos, self.pos, "+blockquote")
          self.pos = self.pos + 1
          return true
        end
      end,
      close = function()
        self:add_match(self.pos, self.pos, "-blockquote")
        self.containers[#self.containers] = nil
      end
    },

    -- should go before reference definitions
    { name = "footnote",
      content = "block",
      continue = function(container)
        if self.indent > container.indent or self:find("^[\r\n]") then
          return true
        else
          return false
        end
      end,
      open = function(spec)
        local sp, ep, label = self:find("^%[%^([^]]+)%]:%s")
        if not sp then
          return nil
        end
        -- adding container will close others
        self:add_container(Container:new(spec, {note_label = label,
                                                indent = self.indent}))
        self:add_match(sp, sp, "+footnote")
        self:add_match(sp + 2, ep - 3, "note_label")
        self.pos = ep
        return true
      end,
      close = function(_container)
        self:add_match(self.pos, self.pos, "-footnote")
        self.containers[#self.containers] = nil
      end
    },

    -- should go before list_item_spec
    { name = "thematic_break",
      content = nil,
      continue = function()
        return false
      end,
      open = function(spec)
        local sp, ep = self:find("^[-*][ \t]*[-*][ \t]*[-*][-* \t]*[\r\n]")
        if ep then
          self:add_container(Container:new(spec))
          self:add_match(sp, ep, "thematic_break")
          self.pos = ep
          return true
        end
      end,
      close = function(_container)
        self.containers[#self.containers] = nil
      end
    },

    { name = "list_item",
      content = "block",
      continue = function(container)
        if self.indent > container.indent or self:find("^[\r\n]") then
          return true
        else
          return false
        end
      end,
      open = function(spec)
        local sp, ep = self:find("^[-*+:]%s")
        if not sp then
          sp, ep = self:find("^%d+[.)]%s")
        end
        if not sp then
          sp, ep = self:find("^%(%d+%)%s")
        end
        if not sp then
          sp, ep = self:find("^[ivxlcdmIVXLCDM]+[.)]%s")
        end
        if not sp then
          sp, ep = self:find("^%([ivxlcdmIVXLCDM]+%)%s")
        end
        if not sp then
          sp, ep = self:find("^%a[.)]%s")
        end
        if not sp then
          sp, ep = self:find("^%(%a%)%s")
        end
        if not sp then
          return nil
        end
        local marker = sub(self.subject, sp, ep - 1)
        local checkbox = nil
        if self:find("^[*+-] %[[Xx ]%]%s", sp + 1) then -- task list
          marker = sub(self.subject, sp, sp + 4)
          checkbox = sub(self.subject, sp + 3, sp + 3)
        end
        -- some items have ambiguous style
        local styles = get_list_styles(marker)
        if #styles == 0 then
          return nil
        end
        local data = { styles = styles,
                       indent = self.indent }
        -- adding container will close others
        self:add_container(Container:new(spec, data))
        local annot = "+list_item"
        for i=1,#styles do
          annot = annot .. "|" .. styles[i]
        end
        self:add_match(sp, ep - 1, annot)
        self.pos = ep
        if checkbox then
          if checkbox == " " then
            self:add_match(sp + 2, sp + 4, "checkbox_unchecked")
          else
            self:add_match(sp + 2, sp + 4, "checkbox_checked")
          end
          self.pos = sp + 5
        end
        return true
      end,
      close = function(_container)
        self:add_match(self.pos, self.pos, "-list_item")
        self.containers[#self.containers] = nil
      end
    },

    { name = "reference_definition",
      content = nil,
      continue = function(container)
        if container.indent >= self.indent then
          return false
        end
        local _, ep, rest = self:find("^(%S+)")
        if ep and self.starteol == ep + 1 then
          self:add_match(ep - #rest + 1, ep, "reference_value")
          self.pos = ep + 1
          return true
        else
          return false
        end
      end,
      open = function(spec)
        local sp, ep, label, rest = self:find("^%[([^]\r\n]*)%]:[ \t]*(%S*)")
        if ep and self.starteol == ep + 1 then
          self:add_container(Container:new(spec,
             { key = label,
               indent = self.indent }))
          self:add_match(sp, sp, "+reference_definition")
          self:add_match(sp, sp + #label + 1, "reference_key")
          if #rest > 0 then
            self:add_match(ep - #rest + 1, ep, "reference_value")
          end
          self.pos = ep + 1
          return true
        end
      end,
      close = function(_container)
        self:add_match(self.pos, self.pos, "-reference_definition")
        self.containers[#self.containers] = nil
      end
    },

    { name = "heading",
      content = "inline",
      continue = function(container)
        local sp, ep = self:find("^%#+%s")
        if sp and ep and container.level == ep - sp then
          self.pos = ep
          return true
        else
          return false
        end
      end,
      open = function(spec)
        local sp, ep = self:find("^#+")
        if ep and find(self.subject, "^%s", ep + 1) then
          local level = ep - sp + 1
          self:add_container(Container:new(spec, {level = level,
               inline_parser = InlineParser:new(self.subject, self.warn) }))
          self:add_match(sp, ep, "+heading")
          self.pos = ep + 1
          return true
        end
      end,
      close = function(_container)
        self:get_inline_matches()
        local last = self.matches[#self.matches] or {self.pos, self.pos, ""}
        local sp, ep, annot = unpack(last)
        self:add_match(ep + 1, ep + 1, "-heading")
        self.containers[#self.containers] = nil
      end
    },

    { name = "code_block",
      content = "text",
      continue = function(container)
        local char = sub(container.border, 1, 1)
        local sp, ep, border = self:find("^(" .. container.border ..
                                 char .. "*)[ \t]*[\r\n]")
        if ep then
          container.end_fence_sp = sp
          container.end_fence_ep = sp + #border - 1
          self.pos = ep -- before newline
          self.finished_line = true
          return false
        else
          return true
        end
      end,
      open = function(spec)
        local sp, ep, border, ws, lang =
          self:find("^(~~~~*)([ \t]*)(%S*)[ \t]*[\r\n]")
        if not ep then
          sp, ep, border, ws, lang =
            self:find("^(````*)([ \t]*)([^%s`]*)[ \t]*[\r\n]")
        end
        if border then
          local is_raw = find(lang, "^=") and true or false
          self:add_container(Container:new(spec, {border = border,
                                                  indent = self.indent }))
          self:add_match(sp, sp + #border - 1, "+code_block")
          if #lang > 0 then
            local langstart = sp + #border + #ws
            if is_raw then
              self:add_match(langstart, langstart + #lang - 1, "raw_format")
            else
              self:add_match(langstart, langstart + #lang - 1, "code_language")
            end
          end
          self.pos = ep  -- before newline
          self.finished_line = true
          return true
        end
      end,
      close = function(container)
        local sp = container.end_fence_sp or self.pos
        local ep = container.end_fence_ep or self.pos
        self:add_match(sp, ep, "-code_block")
        if sp == ep then
          self.warn({ pos = self.pos, message = "Unclosed code block" })
        end
        self.containers[#self.containers] = nil
      end
    },

    { name = "fenced_div",
      content = "block",
      continue = function(container)
        if self.containers[#self.containers].name == "code_block" then
          return true -- see #109
        end
        local sp, ep, equals = self:find("^(::::*)[ \t]*[\r\n]")
        if ep and #equals >= container.equals then
          container.end_fence_sp = sp
          container.end_fence_ep = sp + #equals - 1
          self.pos = ep -- before newline
          return false
        else
          return true
        end
      end,
      open = function(spec)
        local sp, ep1, equals = self:find("^(::::*)[ \t]*")
        if not ep1 then
          return false
        end
        local clsp, ep = find(self.subject, "^[%w_-]*", ep1 + 1)
        local _, eol = find(self.subject, "^[ \t]*[\r\n]", ep + 1)
        if eol then
          self:add_container(Container:new(spec, {equals = #equals}))
          self:add_match(sp, ep, "+div")
          if ep >= clsp then
            self:add_match(clsp, ep, "class")
          end
          self.pos = eol + 1
          self.finished_line = true
          return true
        end
      end,
      close = function(container)
        local sp = container.end_fence_sp or self.pos
        local ep = container.end_fence_ep or self.pos
        -- check to make sure the match is in order
        self:add_match(sp, ep, "-div")
        if sp == ep then
          self.warn({pos = self.pos, message = "Unclosed div"})
        end
        self.containers[#self.containers] = nil
      end
    },

    { name = "table",
      content = "cells",
      continue = function(_container)
        local sp, ep = self:find("^|[^\r\n]*|")
        local eolsp = ep and find(self.subject, "^[ \t]*[\r\n]", ep + 1);
        if eolsp then
          return self:parse_table_row(sp, ep)
        end
      end,
      open = function(spec)
        local sp, ep = self:find("^|[^\r\n]*|")
        local eolsp = " *[\r\n]" -- make sure at end of line
        if sp and eolsp then
          self:add_container(Container:new(spec, { columns = 0 }))
          self:add_match(sp, sp, "+table")
          if self:parse_table_row(sp, ep) then
            return true
          else
            self.containers[#self.containers] = nil
            return false
          end
        end
     end,
      close = function(_container)
        self:add_match(self.pos, self.pos, "-table")
        self.containers[#self.containers] = nil
      end
    },

    { name = "attributes",
      content = "attributes",
      open = function(spec)
        if self:find("^%{") then
          local attribute_parser =
                  attributes.AttributeParser:new(self.subject)
          local status, ep =
                 attribute_parser:feed(self.pos, self.endeol)
          if status == 'fail' or ep + 1 < self.endeol then
            return false
          else
            self:add_container(Container:new(spec,
                               { status = status,
                                 indent = self.indent,
                                 startpos = self.pos,
                                 slices = {},
                                 attribute_parser = attribute_parser }))
            local container = self.containers[#self.containers]
            container.slices = { {self.pos, self.endeol } }
            self.pos = self.starteol
            return true
          end

        end
      end,
      continue = function(container)
        if self.indent > container.indent then
          table.insert(container.slices, { self.pos, self.endeol })
          local status, ep =
            container.attribute_parser:feed(self.pos, self.endeol)
          container.status = status
          if status ~= 'fail' or ep + 1 < self.endeol then
            self.pos = self.starteol
            return true
          end
        end
        -- if we get to here, we don't continue; either we
        -- reached the end of indentation or we failed in
        -- parsing attributes
        if container.status == 'done' then
          return false
        else -- attribute parsing failed; convert to para and continue
             -- with that
          local para_spec = self:specs()[1]
          local para = Container:new(para_spec,
                        { inline_parser =
                           InlineParser:new(self.subject, self.warn) })
          self:add_match(container.startpos, container.startpos, "+para")
          self.containers[#self.containers] = para
          -- reparse the text we couldn't parse as a block attribute:
          para.inline_parser.attribute_slices = container.slices
          para.inline_parser:reparse_attributes()
          self.pos = para.inline_parser.lastpos + 1
          return true
        end
      end,
      close = function(container)
        local attr_matches = container.attribute_parser:get_matches()
        self:add_match(container.startpos, container.startpos, "+block_attributes")
        for i=1,#attr_matches do
          self:add_match(unpack(attr_matches[i]))
        end
        self:add_match(self.pos, self.pos, "-block_attributes")
        self.containers[#self.containers] = nil
      end
    }
  }
end

function Parser:get_inline_matches()
  local matches =
    self.containers[#self.containers].inline_parser:get_matches()
  for i=1,#matches do
    self.matches[#self.matches + 1] = matches[i]
  end
end

function Parser:find(patt)
  return find(self.subject, patt, self.pos)
end

function Parser:add_match(startpos, endpos, annotation)
  self.matches[#self.matches + 1] = {startpos, endpos, annotation}
end

function Parser:add_container(container)
  local last_matched = self.last_matched_container
  while #self.containers > last_matched or
         (#self.containers > 0 and
          self.containers[#self.containers].content ~= "block") do
    self.containers[#self.containers]:close()
  end
  self.containers[#self.containers + 1] = container
end

function Parser:skip_space()
  local newpos, _ = find(self.subject, "[^ \t]", self.pos)
  if newpos then
    self.indent = newpos - self.startline
    self.pos = newpos
  end
end

function Parser:get_eol()
  local starteol, endeol = find(self.subject, "[\r]?[\n]", self.pos)
  if not endeol then
    starteol, endeol = #self.subject, #self.subject
  end
  self.starteol = starteol
  self.endeol = endeol
end

-- Returns an iterator over events.  At each iteration, the iterator
-- returns three values: start byte position, end byte position,
-- and annotation.
function Parser:events()
  local specs = self:specs()
  local para_spec = specs[1]
  local subjectlen = #self.subject

  return function()  -- iterator

    while self.pos <= subjectlen do

      -- return any accumulated matches
      if self.returned < #self.matches then
        self.returned = self.returned + 1
        return unpack(self.matches[self.returned])
      end

      self.indent = 0
      self.startline = self.pos
      self.finished_line = false
      self:get_eol()

      -- check open containers for continuation
      self.last_matched_container = 0
      local idx = 0
      while idx < #self.containers do
        idx = idx + 1
        local container = self.containers[idx]
        -- skip any indentation
        self:skip_space()
        if container:continue() then
          self.last_matched_container = idx
        else
          break
        end
      end

      -- if we hit a close fence, we can move to next line
      if self.finished_line then
        while #self.containers > self.last_matched_container do
          self.containers[#self.containers]:close()
        end
      end

      if not self.finished_line then
        -- check for new containers
        self:skip_space()
        local is_blank = (self.pos == self.starteol)

        local new_starts = false
        local last_match = self.containers[self.last_matched_container]
        local check_starts = not is_blank and
                            (not last_match or last_match.content == "block") and
                              not self:find("^%a+%s") -- optimization
        while check_starts do
          check_starts = false
          for i=1,#specs do
            local spec = specs[i]
            if not spec.is_para then
              if spec:open() then
                self.last_matched_container = #self.containers
                if self.finished_line then
                  check_starts = false
                else
                  self:skip_space()
                  new_starts = true
                  check_starts = spec.content == "block"
                end
                break
              end
            end
          end
        end

        if not self.finished_line then
          -- handle remaining content
          self:skip_space()

          is_blank = (self.pos == self.starteol)

          local is_lazy = not is_blank and
                          not new_starts and
                          self.last_matched_container < #self.containers and
                          self.containers[#self.containers].content == 'inline'

          local last_matched = self.last_matched_container
          if not is_lazy then
            while #self.containers > 0 and #self.containers > last_matched do
              self.containers[#self.containers]:close()
            end
          end

          local tip = self.containers[#self.containers]

          -- add para by default if there's text
          if not tip or tip.content == 'block' then
            if is_blank then
              if not new_starts then
                -- need to track these for tight/loose lists
                self:add_match(self.pos, self.endeol, "blankline")
              end
            else
              para_spec:open()
            end
            tip = self.containers[#self.containers]
          end

          if tip then
            if tip.content == "text" then
              local startpos = self.pos
              if tip.indent and self.indent > tip.indent then
                -- get back the leading spaces we gobbled
                startpos = startpos - (self.indent - tip.indent)
              end
              self:add_match(startpos, self.endeol, "str")
            elseif tip.content == "inline" then
              if not is_blank then
                tip.inline_parser:feed(self.pos, self.endeol)
              end
            end
          end
        end
      end

      self.pos = self.endeol + 1

    end

    -- close unmatched containers
    while #self.containers > 0 do
      self.containers[#self.containers]:close()
    end
    -- return any accumulated matches
    if self.returned < #self.matches then
      self.returned = self.returned + 1
      return unpack(self.matches[self.returned])
    end

  end

end

return { Parser = Parser,
         Container = Container }
end
end

do
local _ENV = _ENV
package.preload[ "djot.filter" ] = function( ... ) local arg = _G.arg;
--- @module 'djot.filter'
--- Support filters that walk the AST and transform a
--- document between parsing and rendering, like pandoc Lua filters.
---
--- This filter uppercases all str elements.
---
---     return {
---       str = function(e)
---         e.text = e.text:upper()
---        end
---     }
---
--- A filter may define functions for as many different tag types
--- as it likes.  traverse will walk the AST and apply matching
--- functions to each node.
---
--- To load a filter:
---
---     local filter = require_filter(path)
---
--- or
---
---     local filter = load_filter(string)
---
--- By default filters do a bottom-up traversal; that is, the
--- filter for a node is run after its children have been processed.
--- It is possible to do a top-down travel, though, and even
--- to run separate actions on entering a node (before processing the
--- children) and on exiting (after processing the children). To do
--- this, associate the node's tag with a table containing `enter` and/or
--- `exit` functions.  The following filter will capitalize text
--- that is nested inside emphasis, but not other text:
---
---     local capitalize = 0
---     return {
---        emph = {
---          enter = function(e)
---            capitalize = capitalize + 1
---          end,
---          exit = function(e)
---            capitalize = capitalize - 1
---          end,
---        },
---        str = function(e)
---          if capitalize > 0 then
---            e.text = e.text:upper()
---           end
---        end
---     }
---
--- For a top-down traversal, you'd just use the `enter` functions.
--- If the tag is associated directly with a function, as in the
--- first example above, it is treated as an `exit` function.
---
--- It is possible to inhibit traversal into the children of a node,
--- by having the `enter` function return the value true (or any truish
--- value, say `'stop'`).  This can be used, for example, to prevent
--- the contents of a footnote from being processed:
---
---     return {
---       footnote = {
---         enter = function(e)
---           return true
---         end
---        }
---     }
---
--- A single filter may return a table with multiple tables, which will be
--- applied sequentially.

local function handle_node(node, filterpart)
  local action = filterpart[node.t]
  local action_in, action_out
  if type(action) == "table" then
    action_in = action.enter
    action_out = action.exit
  elseif type(action) == "function" then
    action_out = action
  end
  if action_in then
    local stop_traversal = action_in(node)
    if stop_traversal then
      return
    end
  end
  if node.c then
    for _,child in ipairs(node.c) do
      handle_node(child, filterpart)
    end
  end
  if node.footnotes then
    for _, note in pairs(node.footnotes) do
      handle_node(note, filterpart)
    end
  end
  if action_out then
    action_out(node)
  end
end

local function traverse(node, filterpart)
  handle_node(node, filterpart)
  return node
end

--- Apply a filter to a document.
--- @param node document (AST)
--- @param filter the filter to apply
local function apply_filter(node, filter)
  for _,filterpart in ipairs(filter) do
    traverse(node, filterpart)
  end
end

--- Returns a table containing the filter defined in `fp`.
--- `fp` will be sought using `require`, so it may occur anywhere
--- on the `LUA_PATH`, or in the working directory. On error,
--- returns nil and an error message.
--- @param fp path of file containing filter
--- @return the compiled filter, or nil and and error message
local function require_filter(fp)
  local oldpackagepath = package.path
  -- allow omitting or providing the .lua extension:
  local ok, filter = pcall(function()
                         package.path = "./?.lua;" .. package.path
                         local f = require(fp:gsub("%.lua$",""))
                         package.path = oldpackagepath
                         return f
                      end)
  if not ok then
    return nil, filter
  elseif type(filter) ~= "table" then
    return nil,  "filter must be a table"
  end
  if #filter == 0 then -- just a single filter part given
    return {filter}
  else
    return filter
  end
end

--- Load filter from a string, which should have the
--- form `return { ... }`.  On error, return nil and an
--- error message.
--- @param s string containing the filter
--- @return the compiled filter, or nil and and error message
local function load_filter(s)
  local fn, err
  if _VERSION:match("5.1") then
    fn, err = loadstring(s)
  else
    fn, err = load(s)
  end
  if fn then
    local filter = fn()
    if type(filter) ~= "table" then
      return nil,  "filter must be a table"
    end
    if #filter == 0 then -- just a single filter given
      return {filter}
    else
      return filter
    end
  else
    return nil, err
  end
end

--- @export
return {
  apply_filter = apply_filter,
  require_filter = require_filter,
  load_filter = load_filter
}
end
end

do
local _ENV = _ENV
package.preload[ "djot.html" ] = function( ... ) local arg = _G.arg;
local ast = require("djot.ast")
local new_node = ast.new_node
local new_attributes = ast.new_attributes
local add_child = ast.add_child
local unpack = unpack or table.unpack
local insert_attribute, copy_attributes =
  ast.insert_attribute, ast.copy_attributes
local format = string.format
local find, gsub = string.find, string.gsub

-- Produce a copy of a table.
local function copy(tbl)
  local result = {}
  if tbl then
    for k,v in pairs(tbl) do
      local newv = v
      if type(v) == "table" then
        newv = copy(v)
      end
      result[k] = newv
    end
  end
  return result
end

local function to_text(node)
  local buffer = {}
  if node.t == "str" then
    buffer[#buffer + 1] = node.s
  elseif node.t == "nbsp" then
    buffer[#buffer + 1] = "\160"
  elseif node.t == "softbreak" then
    buffer[#buffer + 1] = " "
  elseif node.c and #node.c > 0 then
    for i=1,#node.c do
      buffer[#buffer + 1] = to_text(node.c[i])
    end
  end
  return table.concat(buffer)
end

local Renderer = {}

function Renderer:new()
  local state = {
    out = function(s)
      io.stdout:write(s)
    end,
    tight = false,
    footnote_index = {},
    next_footnote_index = 1,
    references = nil,
    footnotes = nil }
  setmetatable(state, self)
  self.__index = self
  return state
end

Renderer.html_escapes =
   { ["<"] = "&lt;",
     [">"] = "&gt;",
     ["&"] = "&amp;",
     ['"'] = "&quot;" }

function Renderer:escape_html(s)
  if find(s, '[<>&]') then
    return (gsub(s, '[<>&]', self.html_escapes))
  else
    return s
  end
end

function Renderer:escape_html_attribute(s)
  if find(s, '[<>&"]') then
    return (gsub(s, '[<>&"]', self.html_escapes))
  else
    return s
  end
end

function Renderer:render(doc, handle)
  self.references = doc.references
  self.footnotes = doc.footnotes
  if handle then
    self.out = function(s)
      handle:write(s)
    end
  end
  self[doc.t](self, doc)
end


function Renderer:render_children(node)
  -- trap stack overflow
  local ok, err = pcall(function ()
    if node.c and #node.c > 0 then
      local oldtight
      if node.tight ~= nil then
        oldtight = self.tight
        self.tight = node.tight
      end
      for i=1,#node.c do
        self[node.c[i].t](self, node.c[i])
      end
      if node.tight ~= nil then
        self.tight = oldtight
      end
    end
  end)
  if not ok and err:find("stack overflow") then
    self.out("(((DEEPLY NESTED CONTENT OMITTED)))\n")
  end
end

function Renderer:render_attrs(node)
  if node.attr then
    for k,v in pairs(node.attr) do
      self.out(" " .. k .. "=" .. '"' ..
            self:escape_html_attribute(v) .. '"')
    end
  end
  if node.pos then
    local sp, ep = unpack(node.pos)
    self.out(' data-startpos="' .. tostring(sp) ..
      '" data-endpos="' .. tostring(ep) .. '"')
  end
end

function Renderer:render_tag(tag, node)
  self.out("<" .. tag)
  self:render_attrs(node)
  self.out(">")
end

function Renderer:add_backlink(nodes, i)
  local backlink = new_node("link")
  backlink.destination = "#fnref" .. tostring(i)
  backlink.attr = ast.new_attributes({role = "doc-backlink"})
  local arrow = new_node("str")
  arrow.s = "↩︎︎"
  add_child(backlink, arrow)
  if nodes.c[#nodes.c].t == "para" then
    add_child(nodes.c[#nodes.c], backlink)
  else
    local para = new_node("para")
    add_child(para, backlink)
    add_child(nodes, para)
  end
end

function Renderer:doc(node)
  self:render_children(node)
  -- render notes
  if self.next_footnote_index > 1 then
    local ordered_footnotes = {}
    for k,v in pairs(self.footnotes) do
      if self.footnote_index[k] then
        ordered_footnotes[self.footnote_index[k]] = v
      end
    end
    self.out('<section role="doc-endnotes">\n<hr>\n<ol>\n')
    for i=1,#ordered_footnotes do
      local note = ordered_footnotes[i]
      if note then
        self.out(format('<li id="fn%d">\n', i))
        self:add_backlink(note,i)
        self:render_children(note)
        self.out('</li>\n')
      end
    end
    self.out('</ol>\n</section>\n')
  end
end

function Renderer:raw_block(node)
  if node.format == "html" then
    self.out(node.s)  -- no escaping
  end
end

function Renderer:para(node)
  if not self.tight then
    self:render_tag("p", node)
  end
  self:render_children(node)
  if not self.tight then
    self.out("</p>")
  end
  self.out("\n")
end

function Renderer:blockquote(node)
  self:render_tag("blockquote", node)
  self.out("\n")
  self:render_children(node)
  self.out("</blockquote>\n")
end

function Renderer:div(node)
  self:render_tag("div", node)
  self.out("\n")
  self:render_children(node)
  self.out("</div>\n")
end

function Renderer:section(node)
  self:render_tag("section", node)
  self.out("\n")
  self:render_children(node)
  self.out("</section>\n")
end

function Renderer:heading(node)
  self:render_tag("h" .. node.level , node)
  self:render_children(node)
  self.out("</h" .. node.level .. ">\n")
end

function Renderer:thematic_break(node)
  self:render_tag("hr", node)
  self.out("\n")
end

function Renderer:code_block(node)
  self:render_tag("pre", node)
  self.out("<code")
  if node.lang and #node.lang > 0 then
    self.out(" class=\"language-" .. node.lang .. "\"")
  end
  self.out(">")
  self.out(self:escape_html(node.s))
  self.out("</code></pre>\n")
end

function Renderer:table(node)
  self:render_tag("table", node)
  self.out("\n")
  self:render_children(node)
  self.out("</table>\n")
end

function Renderer:row(node)
  self:render_tag("tr", node)
  self.out("\n")
  self:render_children(node)
  self.out("</tr>\n")
end

function Renderer:cell(node)
  local tag
  if node.head then
    tag = "th"
  else
    tag = "td"
  end
  local attr = copy(node.attr)
  if node.align then
    insert_attribute(attr, "style", "text-align: " .. node.align .. ";")
  end
  self:render_tag(tag, {attr = attr})
  self:render_children(node)
  self.out("</" .. tag .. ">\n")
end

function Renderer:caption(node)
  self:render_tag("caption", node)
  self:render_children(node)
  self.out("</caption>\n")
end

function Renderer:list(node)
  local sty = node.style
  if sty == "*" or sty == "+" or sty == "-" then
    self:render_tag("ul", node)
    self.out("\n")
    self:render_children(node)
    self.out("</ul>\n")
  elseif sty == "X" then
    local attr = copy(node.attr)
    if attr.class then
      attr.class = "task-list " .. attr.class
    else
      insert_attribute(attr, "class", "task-list")
    end
    self:render_tag("ul", {attr = attr})
    self.out("\n")
    self:render_children(node)
    self.out("</ul>\n")
  elseif sty == ":" then
    self:render_tag("dl", node)
    self.out("\n")
    self:render_children(node)
    self.out("</dl>\n")
  else
    self.out("<ol")
    if node.start and node.start > 1 then
      self.out(" start=\"" .. node.start .. "\"")
    end
    local list_type = gsub(node.style, "%p", "")
    if list_type ~= "1" then
      self.out(" type=\"" .. list_type .. "\"")
    end
    self:render_attrs(node)
    self.out(">\n")
    self:render_children(node)
    self.out("</ol>\n")
  end
end

function Renderer:list_item(node)
  if node.checkbox then
     if node.checkbox == "checked" then
       self.out('<li class="checked">')
     elseif node.checkbox == "unchecked" then
       self.out('<li class="unchecked">')
     end
  else
    self:render_tag("li", node)
  end
  self.out("\n")
  self:render_children(node)
  self.out("</li>\n")
end

function Renderer:term(node)
  self:render_tag("dt", node)
  self:render_children(node)
  self.out("</dt>\n")
end

function Renderer:definition(node)
  self:render_tag("dd", node)
  self.out("\n")
  self:render_children(node)
  self.out("</dd>\n")
end

function Renderer:definition_list_item(node)
  self:render_children(node)
end

function Renderer:reference_definition()
end

function Renderer:footnote_reference(node)
  local label = node.s
  local index = self.footnote_index[label]
  if not index then
    index = self.next_footnote_index
    self.footnote_index[label] = index
    self.next_footnote_index = self.next_footnote_index + 1
  end
  self.out(format('<a id="fnref%d" href="#fn%d" role="doc-noteref"><sup>%d</sup></a>', index, index, index))
end

function Renderer:raw_inline(node)
  if node.format == "html" then
    self.out(node.s)  -- no escaping
  end
end

function Renderer:str(node)
  -- add a span, if needed, to contain attribute on a bare string:
  if node.attr then
    self:render_tag("span", node)
    self.out(self:escape_html(node.s))
    self.out("</span>")
  else
    self.out(self:escape_html(node.s))
  end
end

function Renderer:softbreak()
  self.out("\n")
end

function Renderer:hardbreak()
  self.out("<br>\n")
end

function Renderer:nbsp()
  self.out("&nbsp;")
end

function Renderer:verbatim(node)
  self:render_tag("code", node)
  self.out(self:escape_html(node.s))
  self.out("</code>")
end

function Renderer:link(node)
  local attrs = new_attributes{}
  if node.reference then
    local ref = self.references[node.reference]
    if ref then
      if ref.attr then
        copy_attributes(attrs, ref.attr)
      end
      insert_attribute(attrs, "href", ref.destination)
    end
  elseif node.destination then
    insert_attribute(attrs, "href", node.destination)
  end
  -- link's attributes override reference's:
  copy_attributes(attrs, node.attr)
  self:render_tag("a", {attr = attrs})
  self:render_children(node)
  self.out("</a>")
end

Renderer.url = Renderer.link

Renderer.email = Renderer.link

function Renderer:image(node)
  local attrs = new_attributes{}
  local alt_text = to_text(node)
  if #alt_text > 0 then
    insert_attribute(attrs, "alt", to_text(node))
  end
  if node.reference then
    local ref = self.references[node.reference]
    if ref then
      if ref.attr then
        copy_attributes(attrs, ref.attr)
      end
      insert_attribute(attrs, "src", ref.destination)
    end
  elseif node.destination then
    insert_attribute(attrs, "src", node.destination)
  end
  -- image's attributes override reference's:
  copy_attributes(attrs, node.attr)
  self:render_tag("img", {attr = attrs})
end

function Renderer:span(node)
  self:render_tag("span", node)
  self:render_children(node)
  self.out("</span>")
end

function Renderer:mark(node)
  self:render_tag("mark", node)
  self:render_children(node)
  self.out("</mark>")
end

function Renderer:insert(node)
  self:render_tag("ins", node)
  self:render_children(node)
  self.out("</ins>")
end

function Renderer:delete(node)
  self:render_tag("del", node)
  self:render_children(node)
  self.out("</del>")
end

function Renderer:subscript(node)
  self:render_tag("sub", node)
  self:render_children(node)
  self.out("</sub>")
end

function Renderer:superscript(node)
  self:render_tag("sup", node)
  self:render_children(node)
  self.out("</sup>")
end

function Renderer:emph(node)
  self:render_tag("em", node)
  self:render_children(node)
  self.out("</em>")
end

function Renderer:strong(node)
  self:render_tag("strong", node)
  self:render_children(node)
  self.out("</strong>")
end

function Renderer:double_quoted(node)
  self.out("&ldquo;")
  self:render_children(node)
  self.out("&rdquo;")
end

function Renderer:single_quoted(node)
  self.out("&lsquo;")
  self:render_children(node)
  self.out("&rsquo;")
end

function Renderer:left_double_quote()
  self.out("&ldquo;")
end

function Renderer:right_double_quote()
  self.out("&rdquo;")
end

function Renderer:left_single_quote()
  self.out("&lsquo;")
end

function Renderer:right_single_quote()
  self.out("&rsquo;")
end

function Renderer:ellipses()
  self.out("&hellip;")
end

function Renderer:em_dash()
  self.out("&mdash;")
end

function Renderer:en_dash()
  self.out("&ndash;")
end

function Renderer:symbol(node)
  self.out(":" .. node.alias .. ":")
end

function Renderer:math(node)
  local math_t = "inline"
  if find(node.attr.class, "display") then
    math_t = "display"
  end
  self:render_tag("span", node)
  if math_t == "inline" then
    self.out("\\(")
  else
    self.out("\\[")
  end
  self.out(self:escape_html(node.s))
  if math_t == "inline" then
    self.out("\\)")
  else
    self.out("\\]")
  end
  self.out("</span>")
end

return { Renderer = Renderer }
end
end

do
local _ENV = _ENV
package.preload[ "djot.inline" ] = function( ... ) local arg = _G.arg;
-- this allows the code to work with both lua and luajit:
local unpack = unpack or table.unpack
local attributes = require("djot.attributes")
local find, byte = string.find, string.byte

-- allow up to 3 captures...
local function bounded_find(subj, patt, startpos, endpos)
  local sp,ep,c1,c2,c3 = find(subj, patt, startpos)
  if ep and ep <= endpos then
    return sp,ep,c1,c2,c3
  end
end

-- General note on the parsing strategy:  our objective is to
-- parse without backtracking. To that end, we keep a stack of
-- potential 'openers' for links, images, emphasis, and other
-- inline containers.  When we parse a potential closer for
-- one of these constructions, we can scan the stack of openers
-- for a match, which will tell us the location of the potential
-- opener. We can then change the annotation of the match at
-- that location to '+emphasis' or whatever.

local InlineParser = {}

function InlineParser:new(subject, warn)
  local state =
    { warn = warn or function() end, -- function to issue warnings
      subject = subject, -- text to parse
      matches = {}, -- table pos : (endpos, annotation)
      openers = {}, -- map from closer_type to array of (pos, data) in reverse order
      verbatim = 0, -- parsing verbatim span to be ended by n backticks
      verbatim_type = nil, -- whether verbatim is math or regular
      destination = false, -- parsing link destination in ()
      firstpos = 0, -- position of first slice
      lastpos = 0,  -- position of last slice
      allow_attributes = true, -- allow parsing of attributes
      attribute_parser = nil,  -- attribute parser
      attribute_start = nil,  -- start of potential attribute
      attribute_slices = nil, -- slices we've tried to parse as attributes
    }
  setmetatable(state, self)
  self.__index = self
  return state
end

function InlineParser:add_match(startpos, endpos, annotation)
  self.matches[startpos] = {startpos, endpos, annotation}
end

function InlineParser:add_opener(name, ...)
  -- 1 = startpos, 2 = endpos, 3 = annotation, 4 = substartpos, 5 = endpos
  --
  -- [link text](url)
  -- ^         ^^
  -- 1,2      4 5  3 = "explicit_link"

  if not self.openers[name] then
    self.openers[name] = {}
  end
  table.insert(self.openers[name], {...})
end

function InlineParser:clear_openers(startpos, endpos)
  -- remove other openers in between the matches
  for _,v in pairs(self.openers) do
    local i = #v
    while v[i] do
      local sp,ep,_,sp2,ep2 = unpack(v[i])
      if sp >= startpos and ep <= endpos then
        v[i] = nil
      elseif (sp2 and sp2 >= startpos) and (ep2 and ep2 <= endpos) then
        v[i][3] = nil
        v[i][4] = nil
        v[i][5] = nil
      else
        break
      end
      i = i - 1
    end
  end
end

function InlineParser:str_matches(startpos, endpos)
  for i = startpos, endpos do
    local m = self.matches[i]
    if m then
      local sp, ep, annot = unpack(m)
      if annot ~= "str" and annot ~= "escape" then
        self.matches[i] = {sp, ep, "str"}
      end
    end
  end
end

local function matches_pattern(match, patt)
  if match then
    return string.find(match[3], patt)
  end
end


function InlineParser.between_matched(c, annotation, defaultmatch, opentest)
  return function(self, pos, endpos)
    defaultmatch = defaultmatch or "str"
    local subject = self.subject
    local can_open = find(subject, "^%S", pos + 1)
    local can_close = find(subject, "^%S", pos - 1)
    local has_open_marker = matches_pattern(self.matches[pos - 1], "^open%_marker")
    local has_close_marker = pos + 1 <= endpos and
                              byte(subject, pos + 1) == 125 -- }
    local endcloser = pos
    local startopener = pos

    if type(opentest) == "function" then
      can_open = can_open and opentest(self, pos)
    end

    -- allow explicit open/close markers to override:
    if has_open_marker then
      can_open = true
      can_close = false
      startopener = pos - 1
    end
    if not has_open_marker and has_close_marker then
      can_close = true
      can_open = false
      endcloser = pos + 1
    end

    if has_open_marker and defaultmatch:match("^right") then
      defaultmatch = defaultmatch:gsub("^right", "left")
    elseif has_close_marker and defaultmatch:match("^left") then
      defaultmatch = defaultmatch:gsub("^left", "right")
    end

    local d
    if has_close_marker then
      d = "{" .. c
    else
      d = c
    end
    local openers = self.openers[d]
    if can_close and openers and #openers > 0 then
       -- check openers for a match
      local openpos, openposend = unpack(openers[#openers])
      if openposend ~= pos - 1 then -- exclude empty emph
        self:clear_openers(openpos, pos)
        self:add_match(openpos, openposend, "+" .. annotation)
        self:add_match(pos, endcloser, "-" .. annotation)
        return endcloser + 1
      end
    end

    -- if we get here, we didn't match an opener
    if can_open then
      if has_open_marker then
        d = "{" .. c
      else
        d = c
      end
      self:add_opener(d, startopener, pos)
      self:add_match(startopener, pos, defaultmatch)
      return pos + 1
    else
      self:add_match(pos, endcloser, defaultmatch)
      return endcloser + 1
    end
  end
end

InlineParser.matchers = {
    -- 96 = `
    [96] = function(self, pos, endpos)
      local subject = self.subject
      local _, endchar = bounded_find(subject, "^`*", pos, endpos)
      if not endchar then
        return nil
      end
      if find(subject, "^%$%$", pos - 2) and
          not find(subject, "^\\", pos - 3) then
        self.matches[pos - 2] = nil
        self.matches[pos - 1] = nil
        self:add_match(pos - 2, endchar, "+display_math")
        self.verbatim_type = "display_math"
      elseif find(subject, "^%$", pos - 1) then
        self.matches[pos - 1] = nil
        self:add_match(pos - 1, endchar, "+inline_math")
        self.verbatim_type = "inline_math"
      else
        self:add_match(pos, endchar, "+verbatim")
        self.verbatim_type = "verbatim"
      end
      self.verbatim = endchar - pos + 1
      return endchar + 1
    end,

    -- 92 = \
    [92] = function(self, pos, endpos)
      local subject = self.subject
      local _, endchar = bounded_find(subject, "^[ \t]*\r?\n",  pos + 1, endpos)
      self:add_match(pos, pos, "escape")
      if endchar then
        -- see if there were preceding spaces
        if #self.matches > 0 then
          local sp, ep, annot = unpack(self.matches[#self.matches])
          if annot == "str" then
            while ep >= sp and
                 (subject:byte(ep) == 32 or subject:byte(ep) == 9) do
              ep = ep -1
            end
            if ep < sp then
              self.matches[#self.matches] = nil
            else
              self:add_match(sp, ep, "str")
            end
          end
        end
        self:add_match(pos + 1, endchar, "hardbreak")
        return endchar + 1
      else
        local _, ec = bounded_find(subject, "^[%p ]", pos + 1, endpos)
        if not ec then
          self:add_match(pos, pos, "str")
          return pos + 1
        else
          self:add_match(pos, pos, "escape")
          if find(subject, "^ ", pos + 1) then
            self:add_match(pos + 1, ec, "nbsp")
          else
            self:add_match(pos + 1, ec, "str")
          end
          return ec + 1
        end
      end
    end,

    -- 60 = <
    [60] = function(self, pos, endpos)
      local subject = self.subject
      local starturl, endurl =
              bounded_find(subject, "^%<[^<>%s]+%>", pos, endpos)
      if starturl then
        local is_url = bounded_find(subject, "^%a+:", pos + 1, endurl)
        local is_email = bounded_find(subject, "^[^:]+%@", pos + 1, endurl)
        if is_email then
          self:add_match(starturl, starturl, "+email")
          self:add_match(starturl + 1, endurl - 1, "str")
          self:add_match(endurl, endurl, "-email")
          return endurl + 1
        elseif is_url then
          self:add_match(starturl, starturl, "+url")
          self:add_match(starturl + 1, endurl - 1, "str")
          self:add_match(endurl, endurl, "-url")
          return endurl + 1
        end
      end
    end,

    -- 126 = ~
    [126] = InlineParser.between_matched('~', 'subscript'),

    -- 94 = ^
    [94] = InlineParser.between_matched('^', 'superscript'),

    -- 91 = [
    [91] = function(self, pos, endpos)
      local sp, ep = bounded_find(self.subject, "^%^([^]]+)%]", pos + 1, endpos)
      if sp then -- footnote ref
        self:add_match(pos, ep, "footnote_reference")
        return ep + 1
      else
        self:add_opener("[", pos, pos)
        self:add_match(pos, pos, "str")
        return pos + 1
      end
    end,

    -- 93 = ]
    [93] = function(self, pos, endpos)
      local openers = self.openers["["]
      local subject = self.subject
      if openers and #openers > 0 then
        local opener = openers[#openers]
        if opener[3] == "reference_link" then
          -- found a reference link
          -- add the matches
          local is_image = bounded_find(subject, "^!", opener[1] - 1, endpos)
                  and not bounded_find(subject, "^[\\]", opener[1] - 2, endpos)
          if is_image then
            self:add_match(opener[1] - 1, opener[1] - 1, "image_marker")
            self:add_match(opener[1], opener[2], "+imagetext")
            self:add_match(opener[4], opener[4], "-imagetext")
          else
            self:add_match(opener[1], opener[2], "+linktext")
            self:add_match(opener[4], opener[4], "-linktext")
          end
          self:add_match(opener[5], opener[5], "+reference")
          self:add_match(pos, pos, "-reference")
          -- convert all matches to str
          self:str_matches(opener[5] + 1, pos - 1)
          -- remove from openers
          self:clear_openers(opener[1], pos)
          return pos + 1
        elseif bounded_find(subject, "^%[", pos + 1, endpos) then
          opener[3] = "reference_link"
          opener[4] = pos  -- intermediate ]
          opener[5] = pos + 1  -- intermediate [
          self:add_match(pos, pos + 1, "str")
          -- remove any openers between [ and ]
          self:clear_openers(opener[1] + 1, pos - 1)
          return pos + 2
        elseif bounded_find(subject, "^%(", pos + 1, endpos) then
          self.openers["("] = {} -- clear ( openers
          opener[3] = "explicit_link"
          opener[4] = pos  -- intermediate ]
          opener[5] = pos + 1  -- intermediate (
          self.destination = true
          self:add_match(pos, pos + 1, "str")
          -- remove any openers between [ and ]
          self:clear_openers(opener[1] + 1, pos - 1)
          return pos + 2
        elseif bounded_find(subject, "^%{", pos + 1, endpos) then
          -- assume this is attributes, bracketed span
          self:add_match(opener[1], opener[2], "+span")
          self:add_match(pos, pos, "-span")
          -- remove any openers between [ and ]
          self:clear_openers(opener[1], pos)
          return pos + 1
        end
      end
    end,


    -- 40 = (
    [40] = function(self, pos)
      if not self.destination then return nil end
      self:add_opener("(", pos, pos)
      self:add_match(pos, pos, "str")
      return pos + 1
    end,

    -- 41 = )
    [41] = function(self, pos, endpos)
      if not self.destination then return nil end
      local parens = self.openers["("]
      if parens and #parens > 0 and parens[#parens][1] then
        parens[#parens] = nil -- clear opener
        self:add_match(pos, pos, "str")
        return pos + 1
      else
        local subject = self.subject
        local openers = self.openers["["]
        if openers and #openers > 0
            and openers[#openers][3] == "explicit_link" then
          local opener = openers[#openers]
          -- we have inline link
          local is_image = bounded_find(subject, "^!", opener[1] - 1, endpos)
                 and not bounded_find(subject, "^[\\]", opener[1] - 2, endpos)
          if is_image then
            self:add_match(opener[1] - 1, opener[1] - 1, "image_marker")
            self:add_match(opener[1], opener[2], "+imagetext")
            self:add_match(opener[4], opener[4], "-imagetext")
          else
            self:add_match(opener[1], opener[2], "+linktext")
            self:add_match(opener[4], opener[4], "-linktext")
          end
          self:add_match(opener[5], opener[5], "+destination")
          self:add_match(pos, pos, "-destination")
          self.destination = false
          -- convert all matches to str
          self:str_matches(opener[5] + 1, pos - 1)
          -- remove from openers
          self:clear_openers(opener[1], pos)
          return pos + 1
        end
      end
    end,

    -- 95 = _
    [95] = InlineParser.between_matched('_', 'emph'),

    -- 42 = *
    [42] = InlineParser.between_matched('*', 'strong'),

    -- 123 = {
    [123] = function(self, pos, endpos)
      if bounded_find(self.subject, "^[_*~^+='\"-]", pos + 1, endpos) then
        self:add_match(pos, pos, "open_marker")
        return pos + 1
      elseif self.allow_attributes then
        self.attribute_parser = attributes.AttributeParser:new(self.subject)
        self.attribute_start = pos
        self.attribute_slices = {}
        return pos
      else
        self:add_match(pos, pos, "str")
        return pos + 1
      end
    end,

    -- 58 = :
    [58] = function(self, pos, endpos)
      local sp, ep = bounded_find(self.subject, "^%:[%w_+-]+%:", pos, endpos)
      if sp then
        self:add_match(sp, ep, "symbol")
        return ep + 1
      else
        self:add_match(pos, pos, "str")
        return pos + 1
      end
    end,

    -- 43 = +
    [43] = InlineParser.between_matched("+", "insert", "str",
                           function(self, pos)
                             return find(self.subject, "^%{", pos - 1) or
                                    find(self.subject, "^%}", pos + 1)
                           end),

    -- 61 = =
    [61] = InlineParser.between_matched("=", "mark", "str",
                           function(self, pos)
                             return find(self.subject, "^%{", pos - 1) or
                                    find(self.subject, "^%}", pos + 1)
                           end),

    -- 39 = '
    [39] = InlineParser.between_matched("'", "single_quoted", "right_single_quote",
                           function(self, pos) -- test to open
                             return pos == 1 or
                               find(self.subject, "^[%s\"'-([]", pos - 1)
                             end),

    -- 34 = "
    [34] = InlineParser.between_matched('"', "double_quoted", "left_double_quote"),

    -- 45 = -
    [45] = function(self, pos, endpos)
      local subject = self.subject
      local nextpos
      if byte(subject, pos - 1) == 123 or
         byte(subject, pos + 1) == 125 then -- (123 = { 125 = })
        nextpos = InlineParser.between_matched("-", "delete", "str",
                           function(slf, p)
                             return find(slf.subject, "^%{", p - 1) or
                                    find(slf.subject, "^%}", p + 1)
                           end)(self, pos, endpos)
        return nextpos
      end
      -- didn't match a del, try for smart hyphens:
      local _, ep = find(subject, "^%-*", pos)
      if endpos < ep then
        ep = endpos
      end
      local hyphens = 1 + ep - pos
      if byte(subject, ep + 1) == 125 then -- 125 = }
        hyphens = hyphens - 1 -- last hyphen is close del
      end
      if hyphens == 0 then  -- this means we have '-}'
        self:add_match(pos, pos + 1, "str")
        return pos + 2
      end
      -- Try to construct a homogeneous sequence of dashes
      local all_em = hyphens % 3 == 0
      local all_en = hyphens % 2 == 0
      while hyphens > 0 do
        if all_em then
          self:add_match(pos, pos + 2, "em_dash")
          pos = pos + 3
          hyphens = hyphens - 3
        elseif all_en then
          self:add_match(pos, pos + 1, "en_dash")
          pos = pos + 2
          hyphens = hyphens - 2
        elseif hyphens >= 3 and (hyphens % 2 ~= 0 or hyphens > 4) then
          self:add_match(pos, pos + 2, "em_dash")
          pos = pos + 3
          hyphens = hyphens - 3
        elseif hyphens >= 2 then
          self:add_match(pos, pos + 1, "en_dash")
          pos = pos + 2
          hyphens = hyphens - 2
        else
          self:add_match(pos, pos, "str")
          pos = pos + 1
          hyphens = hyphens - 1
        end
      end
      return pos
    end,

    -- 46 = .
    [46] = function(self, pos, endpos)
      if bounded_find(self.subject, "^%.%.", pos + 1, endpos) then
        self:add_match(pos, pos +2, "ellipses")
        return pos + 3
      end
    end
  }

function InlineParser:single_char(pos)
  self:add_match(pos, pos, "str")
  return pos + 1
end

-- Reparse attribute_slices that we tried to parse as an attribute
function InlineParser:reparse_attributes()
  local slices = self.attribute_slices
  if not slices then
    return
  end
  self.allow_attributes = false
  self.attribute_parser = nil
  self.attribute_start = nil
  if slices then
    for i=1,#slices do
      self:feed(unpack(slices[i]))
    end
  end
  self.allow_attributes = true
  self.attribute_slices = nil
end

-- Feed a slice to the parser, updating state.
function InlineParser:feed(spos, endpos)
  local special = "[][\\`{}_*()!<>~^:=+$\r\n'\".-]"
  local subject = self.subject
  local matchers = self.matchers
  local pos
  if self.firstpos == 0 or spos < self.firstpos then
    self.firstpos = spos
  end
  if self.lastpos == 0 or endpos > self.lastpos then
    self.lastpos = endpos
  end
  pos = spos
  while pos <= endpos do
    if self.attribute_parser then
      local sp = pos
      local ep2 = bounded_find(subject, special, pos, endpos)
      if not ep2 or ep2 > endpos then
        ep2 = endpos
      end
      local status, ep = self.attribute_parser:feed(sp, ep2)
      if status == "done" then
        local attribute_start = self.attribute_start
        -- add attribute matches
        self:add_match(attribute_start, attribute_start, "+attributes")
        self:add_match(ep, ep, "-attributes")
        local attr_matches = self.attribute_parser:get_matches()
        -- add attribute matches
        for i=1,#attr_matches do
          self:add_match(unpack(attr_matches[i]))
        end
        -- restore state to prior to adding attribute parser:
        self.attribute_parser = nil
        self.attribute_start = nil
        self.attribute_slices = nil
        pos = ep + 1
      elseif status == "fail" then
        self:reparse_attributes()
        pos = sp  -- we'll want to go over the whole failed portion again,
                  -- as no slice was added for it
      elseif status == "continue" then
        if #self.attribute_slices == 0 then
          self.attribute_slices = {}
        end
        self.attribute_slices[#self.attribute_slices + 1] = {sp,ep}
        pos = ep + 1
      end
    else
      -- find next interesting character:
      local newpos = bounded_find(subject, special, pos, endpos) or endpos + 1
      if newpos > pos then
        self:add_match(pos, newpos - 1, "str")
        pos = newpos
        if pos > endpos then
          break -- otherwise, fall through:
        end
      end
      -- if we get here, then newpos = pos,
      -- i.e. we have something interesting at pos
      local c = byte(subject, pos)

      if c == 13 or c == 10 then -- cr or lf
        if c == 13 and bounded_find(subject, "^[%n]", pos + 1, endpos) then
          self:add_match(pos, pos + 1, "softbreak")
          pos = pos + 2
        else
          self:add_match(pos, pos, "softbreak")
          pos = pos + 1
        end
      elseif self.verbatim > 0 then
        if c == 96 then
          local _, endchar = bounded_find(subject, "^`+", pos, endpos)
          if endchar and endchar - pos + 1 == self.verbatim then
            -- check for raw attribute
            local sp, ep =
              bounded_find(subject, "^%{%=[^%s{}`]+%}", endchar + 1, endpos)
            if sp and self.verbatim_type == "verbatim" then -- raw
              self:add_match(pos, endchar, "-" .. self.verbatim_type)
              self:add_match(sp, ep, "raw_format")
              pos = ep + 1
            else
              self:add_match(pos, endchar, "-" .. self.verbatim_type)
              pos = endchar + 1
            end
            self.verbatim = 0
            self.verbatim_type = nil
          else
            endchar = endchar or endpos
            self:add_match(pos, endchar, "str")
            pos = endchar + 1
          end
        else
          self:add_match(pos, pos, "str")
          pos = pos + 1
        end
      else
        local matcher = matchers[c]
        pos = (matcher and matcher(self, pos, endpos)) or self:single_char(pos)
      end
    end
  end
end

  -- Return true if we're parsing verbatim content.
function InlineParser:in_verbatim()
  return self.verbatim > 0
end

function InlineParser:get_matches()
  local sorted = {}
  local subject = self.subject
  local lastsp, lastep, lastannot
  if self.attribute_parser then -- we're still in an attribute parse
    self:reparse_attributes()
  end
  for i=self.firstpos, self.lastpos do
    if self.matches[i] then
      local sp, ep, annot = unpack(self.matches[i])
      if annot == "str" and lastannot == "str" and lastep + 1 == sp then
          -- consolidate adjacent strs
        sorted[#sorted] = {lastsp, ep, annot}
        lastsp, lastep, lastannot = lastsp, ep, annot
      else
        sorted[#sorted + 1] = self.matches[i]
        lastsp, lastep, lastannot = sp, ep, annot
      end
    end
  end
  if #sorted > 0 then
    local last = sorted[#sorted]
    local startpos, endpos, annot = unpack(last)
    -- remove final softbreak
    if annot == "softbreak" then
      sorted[#sorted] = nil
      last = sorted[#sorted]
      if not last then
        return sorted
      end
      startpos, endpos, annot = unpack(last)
    end
    -- remove trailing spaces
    if annot == "str" and byte(subject, endpos) == 32 then
      while endpos > startpos and byte(subject, endpos) == 32 do
        endpos = endpos - 1
      end
      sorted[#sorted] = {startpos, endpos, annot}
    end
    if self.verbatim > 0 then -- unclosed verbatim
      self.warn({ message = "Unclosed verbatim", pos = endpos })
      sorted[#sorted + 1] = {endpos, endpos, "-" .. self.verbatim_type}
    end
  end
  return sorted
end

return { InlineParser = InlineParser }
end
end

do
local _ENV = _ENV
package.preload[ "djot.json" ] = function( ... ) local arg = _G.arg;
-- Modified from
-- json.lua
-- Copyright (c) 2020 rxi
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy of
-- this software and associated documentation files (the "Software"), to deal in
-- the Software without restriction, including without limitation the rights to
-- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
-- of the Software, and to permit persons to whom the Software is furnished to do
-- so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
--
-- Modifications to the original code:
--
-- * Removed JSON decoding code

local json = { _version = "0.1.2" }

-- Encode

local encode

local escape_char_map = {
  [ "\\" ] = "\\",
  [ "\"" ] = "\"",
  [ "\b" ] = "b",
  [ "\f" ] = "f",
  [ "\n" ] = "n",
  [ "\r" ] = "r",
  [ "\t" ] = "t",
}

local escape_char_map_inv = { [ "/" ] = "/" }
for k, v in pairs(escape_char_map) do
  escape_char_map_inv[v] = k
end


local function escape_char(c)
  return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
end


local function encode_nil(val)
  return "null"
end

local function encode_table(val, stack)
  local res = {}
  stack = stack or {}

  -- Circular reference?
  if stack[val] then error("circular reference") end

  stack[val] = true

  if rawget(val, 1) ~= nil or next(val) == nil then
    -- Treat as array -- check keys are valid and it is not sparse
    local n = 0
    for k in pairs(val) do
      if type(k) ~= "number" then
        error("invalid table: mixed or invalid key types")
      end
      n = n + 1
    end
    if n ~= #val then
      error("invalid table: sparse array")
    end
    -- Encode
    for i, v in ipairs(val) do
      table.insert(res, encode(v, stack))
    end
    stack[val] = nil
    return "[" .. table.concat(res, ",") .. "]"

  else
    -- Treat as an object
    for k, v in pairs(val) do
      if type(k) ~= "string" then
        error("invalid table: mixed or invalid key types")
      end
      table.insert(res, encode(k, stack) .. ":" .. encode(v, stack))
    end
    stack[val] = nil
    return "{" .. table.concat(res, ",") .. "}"
  end
end


local function encode_string(val)
  return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end


local function encode_number(val)
  -- Check for NaN, -inf and inf
  if val ~= val or val <= -math.huge or val >= math.huge then
    error("unexpected number value '" .. tostring(val) .. "'")
  end
  return string.format("%.14g", val)
end


local type_func_map = {
  [ "nil"     ] = encode_nil,
  [ "table"   ] = encode_table,
  [ "string"  ] = encode_string,
  [ "number"  ] = encode_number,
  [ "boolean" ] = tostring,
}


encode = function(val, stack)
  local t = type(val)
  local f = type_func_map[t]
  if f then
    return f(val, stack)
  end
  error("unexpected type '" .. t .. "'")
end


function json.encode(val)
  return ( encode(val) )
end

return json
end
end

local djot = require("djot")
local ast = require("djot.ast")
local insert_attribute, copy_attributes =
  ast.insert_attribute, ast.copy_attributes
local emoji -- require this later, only if emoji encountered
local format = string.format
local find, gsub = string.find, string.gsub

-- Produce a copy of a table.
local function copy(tbl)
  local result = {}
  if tbl then
    for k,v in pairs(tbl) do
      local newv = v
      if type(v) == "table" then
        newv = copy(v)
      end
      result[k] = newv
    end
  end
  return result
end

local Renderer = {}

function Renderer:new()
  local state = {
    tight = false,
    footnotes = nil,
    references = nil
  }
  setmetatable(state, self)
  self.__index = self
  return state
end

local function words(s)
  if s then
    local res = {}
    string.gsub(s, "(%S+)", function(x) table.insert(res, x) end)
    return res
  else
    return {}
  end
end

local function to_attr(attr)
  if not attr then
    return nil
  end
  local result = copy(attr)
  result.id = nil
  result.class = nil
  return pandoc.Attr(attr.id or "", words(attr.class), result)
end

function Renderer:with_optional_span(node, f)
  local base = f(self:render_children(node))
  if node.attr then
    return pandoc.Span(base, to_attr(node.attr))
  else
    return base
  end
end

function Renderer:with_optional_div(node, f)
  local base = f(self:render_children(node))
  if node.attr then
    return pandoc.Div(base, to_attr(node.attr))
  else
    return base
  end
end

function Renderer:render_node(node)
  return self[node.tag](self, node)
end

function Renderer:render_children(node)
  local buff = {}
  local inline = false
  if node.children and #node.children > 0 then
    local oldtight
    if node.tight ~= nil then
      oldtight = self.tight
      self.tight = node.tight
    end
    local function integrate_elt(elt)
      if elt.__name == "Inlines" or elt.__name == "Blocks" then
        for i=1,#elt do
          integrate_elt(elt[i])
        end
      else
        buff[#buff + 1] = elt
      end
    end
    for _,child in ipairs(node.children) do
      local elt = self:render_node(child)
      integrate_elt(elt)
    end
    if node.tight ~= nil then
      self.tight = oldtight
    end
  end
  return buff
end

function Renderer:doc(node)
  self.footnotes = node.footnotes
  self.references = node.references
  return pandoc.Pandoc(self:render_children(node))
end

function Renderer:section(node)
  local attrs = to_attr(node.attr)
  table.insert(attrs.classes, 1, "section")
  return pandoc.Div(self:render_children(node), attrs)
end

function Renderer:raw_block(node)
  return pandoc.RawBlock(node.format, node.text)
end

function Renderer:para(node)
  local constructor = pandoc.Para
  if self.tight then
    constructor = pandoc.Plain
  end
  return self:with_optional_div(node, constructor)
end

function Renderer:blockquote(node)
  return self:with_optional_div(node, pandoc.BlockQuote)
end

function Renderer:div(node)
  return pandoc.Div(self:render_children(node), to_attr(node.attr))
end

function Renderer:heading(node)
  return pandoc.Header(node.level,
              self:render_children(node),
              to_attr(node.attr))
end

function Renderer:thematic_break(node)
  if node.attr then
    return pandoc.Div(pandoc.HorizontalRule(), to_attr(node.attr))
  else
    return pandoc.HorizontalRule()
  end
end

function Renderer:code_block(node)
  local attr = copy(to_attr(node.attr))
  if not attr.class then
    attr.class = node.lang
  else
    attr.class = node.lang .. " " .. attr.class
  end
  return pandoc.CodeBlock(node.text:gsub("\n$",""), attr)
end

function Renderer:table(node)
  local rows = {}
  local headers = {}
  local caption = {}
  local aligns = {}
  local widths = {}
  local content = node.c
  for i=1,#content do
    local row = content[i]
    if row.t == "caption" then
      caption = self:render_children(row)
    elseif row.t == "row" then
      local cells = {}
      for j=1,#row.c do
        cells[j] = self:render_node(row.c[j])
        if not aligns[j] then
            local align = row.c[j].align
            if not align then
              aligns[j] = "AlignDefault"
            elseif align == "center" then
                aligns[j] = "AlignCenter"
            elseif align == "left" then
                aligns[j] = "AlignLeft"
            elseif align == "right" then
                aligns[j] = "AlignRight"
            end
            widths[j] = 0
        end
      end
      if row.head then
        headers = cells
      else
        rows[#rows + 1] = cells
      end
    end
  end
  return pandoc.utils.from_simple_table(
           pandoc.SimpleTable(caption, aligns, widths, headers, rows))
end

function Renderer:cell(node)
  return { pandoc.Plain(self:render_children(node)) }
end

function Renderer:list(node)
  local sty = node.style
  if sty == "*" or sty == "+" or sty == "-" then
    return self:with_optional_div(node, pandoc.BulletList)
  elseif sty == "X" then
    return self:with_optional_div(node, pandoc.BulletList)
  elseif sty == ":" then
    return self:with_optional_div(node, pandoc.DefinitionList)
  else
    local start = 1
    local sty = "DefaultStyle"
    local delim = "DefaultDelim"
    if node.start and node.start > 1 then
      start = node.start
    end
    local list_type = gsub(node.style, "%p", "")
    if list_type == "a" then
      sty = "LowerAlpha"
    elseif list_type == "A" then
      sty = "UpperAlpha"
    elseif list_type == "i" then
      sty = "LowerRoman"
    elseif list_type == "I" then
      sty = "UpperRoman"
    end
    local list_delim = gsub(node.style, "%P", "")
    if list_delim == ")" then
      delim = "OneParen"
    elseif list_delim == "()" then
      delim = "TwoParens"
    end
    return self:with_optional_div(node, function(x)
                                    return pandoc.OrderedList(x,
                                       pandoc.ListAttributes(start, sty, delim))
                                    end)
  end
end

function Renderer:list_item(node)
  local children = self:render_children(node)
  if node.checkbox then
     local box = (node.checkbox == "checked" and "☒") or "☐"
     local tag = children[1].tag
     if tag == "Para" or tag == "Plain" then
       children[1].content:insert(1, pandoc.Space())
       children[1].content:insert(1, pandoc.Str(box))
     else
       children:insert(1, pandoc.Para{pandoc.Str(box), pandoc.Space()})
     end
  end
  return children
end

function Renderer:definition_list_item(node)
  local term = self:render_node(node.children[1])
  local defn = self:render_node(node.children[2])
  return { term, defn }
end

function Renderer:term(node)
  return self:render_children(node)
end

function Renderer:definition(node)
  return self:render_children(node)
end

function Renderer:reference_definition()
  return ""
end

function Renderer:footnote_reference(node)
  local label = node.text
  local note = self.footnotes[label]
  if note then
    return pandoc.Note(self:render_children(note))
  else
    io.stderr:write("Note " .. label .. " not found.")
    return pandoc.Str("[^" .. label .. "]")
  end
end

function Renderer:raw_inline(node)
  return pandoc.RawInline(node.format, node.text)
end

function Renderer:str(node)
  -- add a span, if needed, to contain attribute on a bare string:
  if node.attr then
    return pandoc.Span(pandoc.Inlines(node.text), to_attr(node.attr))
  else
    return pandoc.Inlines(node.text)
  end
end

function Renderer:softbreak()
  return pandoc.SoftBreak()
end

function Renderer:hardbreak()
  return pandoc.LineBreak()
end

function Renderer:nbsp()
  return pandoc.Str(" ")
end

function Renderer:verbatim(node)
  return pandoc.Code(node.text, to_attr(node.attr))
end

function Renderer:link(node)
  local attrs = {}
  local dest = node.destination
  if node.reference then
    local ref = self.references[node.reference]
    if ref then
      if ref.attributes then
        attrs = copy(ref.attributes)
      end
      dest = ref.destination
    else
      dest = "#" -- empty href is illegal
    end
  end
  -- link's attributes override reference's:
  copy_attributes(attrs, node.attr)
  local title = attrs.title
  attrs.title = nil
  return pandoc.Link(self:render_children(node), dest,
                     title, to_attr(attrs))
end

function Renderer:image(node)
  local attrs = {}
  local dest = node.destination
  if node.reference then
    local ref = self.references[node.reference]
    if ref then
      if ref.attributes then
        attrs = copy(ref.attributes)
      end
      dest = ref.destination
    else
      dest = "#" -- empty href is illegal
    end
  end
  -- image's attributes override reference's:
  copy_attributes(attrs, node.attr)
  return pandoc.Image(self:render_children(node), dest,
           title, to_attr(attrs))
end

function Renderer:span(node)
  return pandoc.Span(self:render_children(node), to_attr(node.attr))
end

function Renderer:mark(node)
  local attr = copy(node.attr)
  if attr.class then
    attr.class = "mark " .. attr.class
  else
    attr = { class = "mark" }
  end
  return pandoc.Span(self:render_children(node), to_attr(attr))
end

function Renderer:insert(node)
  local attr = copy(node.attr)
  if attr.class then
    attr.class = "insert " .. attr.class
  else
    attr = { class = "insert" }
  end
  return pandoc.Span(self:render_children(node), to_attr(attr))
end

function Renderer:delete(node)
  return self:with_optional_span(node, pandoc.Strikeout)
end

function Renderer:subscript(node)
  return self:with_optional_span(node, pandoc.Subscript)
end

function Renderer:superscript(node)
  return self:with_optional_span(node, pandoc.Superscript)
end

function Renderer:emph(node)
  return self:with_optional_span(node, pandoc.Emph)
end

function Renderer:strong(node)
  return self:with_optional_span(node, pandoc.Strong)
end

function Renderer:double_quoted(node)
  return self:with_optional_span(node,
           function(x) return pandoc.Quoted("DoubleQuote", x) end)
end

function Renderer:single_quoted(node)
  return self:with_optional_span(node,
           function(x) return pandoc.Quoted("SingleQuote", x) end)
end

function Renderer:left_double_quote()
  return "“"
end

function Renderer:right_double_quote()
  return "”"
end

function Renderer:left_single_quote()
  return "‘"
end

function Renderer:right_single_quote()
  return "’"
end

function Renderer:ellipses()
  return "…"
end

function Renderer:em_dash()
  return "—"
end

function Renderer:en_dash()
  return "–"
end

function Renderer:symbol(node)
  return pandoc.Span(":" .. node.alias .. ":",
            pandoc.Attr("",{"symbol"},{["alias"] = node.alias}))
end

function Renderer:math(node)
  local math_type = "InlineMath"
  if find(node.attr.class, "display") then
    math_type = "DisplayMath"
  end
  return pandoc.Math(math_type, node.text)
end

function Reader(input)
  local doc = djot.parse(tostring(input))
  return Renderer:render_node(doc)
end
