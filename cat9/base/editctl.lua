return
function(cat9, root, config)

-- since this runs in 'focused job input mode' the regular cat9/config/bindings.lua
-- shouldn't be used and we keep the inputs as a separate part of default.lua config
--
-- missing features:
-- =================
--    2. history snapshotting / stepping
--    4. wrapping controls / rendering (affects stepping operations, mainly expand
--                                   cursor to byte and row index)
--
--    5. edit template (line, offset and modify rendering to show as labels)
--
--    6. external highlighter, navigation, suggestion, fold-range resolver
--             with poc for ispell
--
--    7. reflow / reformat visual selection
--
local inputs = {}

-- this set things up for a vim mode, if we have a config for something else,
-- this is where that could be added. We also have dev/diff_match_and_patch support
-- to build from.
--
-- vim notes (remove as they are added):
--  : query for command
--
--  cursor:
--   gj/gk (move cursor for multiline)
--   W forward to start of word with punctuation
--   e end of word
--   E forward to end of word with punctuation
--   b backwards to start of word
--   B backwards to start of word with punctuation
--   ge - backwards to end of word
--   gE - backwards to end of word with punctuation
--   % move to matching character (), {}, []
--   0 start of line
--   ^ first non-blank
--   $ to end of line
--   g_ to last non-blank character
--   gg to first line of the document
--   G to last line of document
--   ngg or nG go to line n
--   gd move to local declaration
--   gD move to global declaration
--   fx jump to next occurence of character x
--   Fx jump to previous occurence of character x
--   Tx jump to after previous occurence of character
--
-- ; repeat previous f/t/F or T
-- , repeat previous f/t/F or T backwards
-- } next paragraph or function
-- { prev paragraph or function
--
-- zz center on screen
-- zt position on top
-- zb position on bottom
--
-- ctrl + b page up
-- ctrl + d page down
-- Ctrl + e y up down line (keep cursor)
-- Ctrl + b f up down page (cursor to last or first)
-- Ctrl + d u cursor and screen up down half page
--
--  insert mode:
--   i before cursor
--   I beginning of line
--   a after cursor
--   A end of line
--   o append with new line below
--   O append with new line above
--   ea append at end of word
--   ctrl + h characterbefore
--   ctrl + w delete word before
--   ctrl + j add a line break
--   ctrl + t indent one
--   ctrl + d de-indent one
--   ctrl + n (autocomplete) insert next match before
--   ctrl + p (autocomplete) insert previous match before
--   ctrl + rx insert reg x
--   ctrl + ox enter normal mode for one command
--   esc / ctrl + c exit insert
--
--  edit mode:
--   r replace single
--   R replace more until esc
--   J join line to current with one space
--   gJ join line to current without space
--   gwip reflow paragraph
--   g~ switch case up
--   cc / S replace entire line
--   c$ / C replace to end
--   ciw replace word
--   wc/ ce replace to end of word
--   u undo
--   U restore (undo) line
--   ctrl + R redo
--   . repeat last
--
--   folding:
--    zo - open
--    zc - close
--    zM - close-all
--    zR - open-all
--    za - toggle
--
--   marking:
--    o - move to end of marked
--    O - move to corner of block
--    aw mark word
--    ab mark block with ()
--    aB mark block with {}
--    ib inner block with ()
--    iB inner block with {}
--    ib inner block with <>
--    > shift mark right
--    < shift mark left
--    y yank
--    d delete
--    ~ switch case
--    u mark to lower
--    U mark to upper
--
--   cut-n-paste:
--    yy line
--    [n]yy n lines
--    yw curor to next word
--    yiw word under cursor
--    yaw word under cursor and space before
--    y$/Y yank to EoL
--    p paste after
--    P paste before
--    gp paste after and leave
--    gP paste before
--    dd delete line
--    2dd delete 2 lines
--    dw delete word
--    diw delete word under
--    daw delete word and space after
--    :a,bd - delete from a, b
--
--    g/{pattern}/d all lines with pattern
--    g!/{pattern}/d all lines not with pattern
--    d$ / D delete to eol
--    x delete char
--
--    indent:
--     >> line one shift
--     << line left one shift
--     >% block () or {} cursor on
--     >ib indent inner ()
--     >at indent block <>
--     n== indent n lines
--     =% re-indent () or {}
--     =iB indent inner with {}
--     gg=G indent everything
--     ]p paste and adjust
--
--    search:
--     /pattern fwd
--     ?pattern back
--    %s/old/new/g
--    %s/old/new/gc (g with confirm)
--    :noh remove highlight
--

local function cursor_byte_index(job, ofs)
	local y = job.row_offset + job.cursor[2]
	local row = job.data[y]
	if not row then
		return -1
	end

	return root:utf8_step(row, job.col_offset + job.cursor[1] + ofs), y, row
end

local function add_history_item_set(job, items)
	local new = {}

	if items[1][1] then
		items = items[1]
	end

	for _, v in ipairs(items) do
		table.insert(new, v)
	end

	new.cursor = {job.cursor[1], job.cursor[2]}
	new.row_offset = job.row_offset
	new.col_offset = job.col_offset

	if job.edit.history.offset > 0 then
		job.edit.history = {}
		job.edit.history.offset = 0
	end

	table.insert(job.edit.history, new)
end

local function add_history_item(job, ...)
	local args = {...}
	add_history_item_set(job, args)
end

local function trigger_mode_swap(job)
	if job.edit.mode_closure then
		job.edit.mode_closure()
		job.edit.mode_closure = nil
	end
	cat9.flag_dirty(job)
end

local function set_input_mode(job)
	trigger_mode_swap(job)
	job.edit.insert = {}
	job.edit.vsel = {}
	job.edit.mode = "insert"
	job.bar_color_selected = config.edit.bar.input
end

local function set_command_mode(job)
	trigger_mode_swap(job)
	job.edit.vsel = {}
	job.edit.command = {}
	job.edit.mode = "command"
	job.bar_color_selected = config.edit.bar.command
end

local function set_append_mode(job)
	trigger_mode_swap(job)
	set_input_mode(job)
	job.bar_color_selected = config.edit.bar.append
	job.cursor[1] = job.cursor[1] + 1
end

local function set_visual_mode(job, mods)
	trigger_mode_swap(job)
	job.edit.vsel = {}
	job.edit.command = {}
	job.edit.mode = "visual"
	job.edit.vrange = {}
	job.edit.vrange.start_row, job.edit.vrange.start_col = job:resolve_cursor()
	job.edit.vrange.stop_row = job.edit.vrange.start_row
	job.edit.vrange.stop_col = job.edit.vrange.start_col

-- three different visual modes:
--  visual line
--  visual block
--  visual char
--
-- these are not implementation wise much difficult, they just apply different
-- conditions to how the cursor moves, selection is still calculated by
-- snapshotting before and after cursor movement and inverting selection status
-- for everything between the two positions.
--
	job.edit.mode_closure =
	function()
		job.edit.lineneav = false
		job.edit.blocknav = false
	end

	if bit.band(mods, tui.modifiers.SHIFT) > 0 then
		job.edit.linenav = true
		job.cursor[1] = 0
		job.col_offset = 0

	elseif bit.band(mods, tui.modifiers.CTRL) > 0 then
		job.edit.blocknav = true
	end

	job.bar_color_selected = config.edit.bar.visual
	cat9.flag_dirty(job)
end

local function set_replace_mode(job)
	trigger_mode_swap(job)
	job.edit.mode = "replace"
	job.edit.replace = {}
	job.bar_color_selected = tui.colors.ref_red
end

inputs[config.edit.input_mode   or tui.keys.I]      = set_input_mode
inputs[config.edit.command_mode or tui.keys.ESCAPE] = set_command_mode
inputs[config.edit.replace_mode or tui.keys.R]      = set_replace_mode
inputs[config.edit.append_mode  or tui.keys.A]      = set_append_mode
inputs[config.edit.visual_mode  or tui.keys.V]      = set_visual_mode

-- call when the underlying data has been modified and we want to redraw,
-- ensures that the cursor is at a mode-apropriate position
local function realign_synch(job)
	local cy = job:resolve_cursor()
	local co = (
		job.edit.mode == "insert" or
		job.edit.mode == "visual"
	) and 1 or 0

	if not job.data[cy] then
		job.cursor[1] = 1

	elseif job.cursor[1] >= job.root:utf8_len(job.data[cy]) + co then
		job.cursor[1] = #job.data[cy] - 1
	end

	if job.cursor[1] < 0 then
		job.cursor[1] = 0
	end

-- check so we are within the visible range of the job still
	if job.cursor[2] > job.region[4] - job.region[2] + 2 then
		job.cursor[2] = job.region[4] - 2
	end

-- if the job add some padding that doesn't correspond to actual data
-- in the job, step until we realign
	cy = job:resolve_cursor()

	while not job.data[cy] do
		job.cursor[2] = job.cursor[2] - 1
		cy = job:resolve_cursor()
	end

	cat9.flag_dirty(job)
end

local function cursor_end(job, ch)
	local cy = job:resolve_cursor(job)
	if not job.data[cy] then
		return
	end

	job.cursor[1] = job.root:utf8_len(job.data[cy])
end

local function cursor_up_n(job, n)
	while n > 0 do
		if job.cursor[2] <= job.edit.scroll_ofs and job.row_offset > 1 then
			job.row_offset = job.row_offset - 1
		elseif job.cursor[2] == 0 then
			break
		else
			job.cursor[2] = job.cursor[2] - 1
		end
		n = n - 1
	end
end

local function cursor_left_n(job, n, wrap)
	if job.edit.linenav then
		return
	end

	while n > 0 do
-- simple step
		if job.cursor[1] > 0 then
			job.cursor[1] = job.cursor[1] - 1
			n = n - 1
-- or scroll leftwise rather than move the cursor
		elseif job.col_offset > 0 then
			job.col_offset = job.col_offset - 1
			n = n - 1

-- if we are at edge and permit wrap, move up one and go to end of row
		elseif wrap then
			if job.cursor[2] > 0 then
				cursor_up_n(job, 1)
				cursor_end(job)

-- wrap at top is no-op (unless one wants wraparound to end)
			else
				break
			end

-- already at edge
		else
			break
		end

	end
end

local function cursor_right_n(job, n)
	if job.edit.linenav then
		return
	end

	while n > 0 do
		job.cursor[1] = job.cursor[1] + 1
		n = n - 1
	end
end

local function cursor_down_n(job, n)
	local cy = job:resolve_cursor()
-- if cursor at scroll bound, (region[4] - region[2] - pad)
-- then invoke scroll through the view implementation
	local page_size = job.region[4] - job.region[2] - 2

	while n > 0 do
		if (job.cursor[2] + 1 > page_size - job.edit.scroll_ofs) and
			(job.data.linecount - cy > page_size) then
			cat9.parse_string(false, "view #csel scroll +1")
		else
			job.cursor[2] = job.cursor[2] + 1
		end

-- if we land outside existing data (external source removing)
-- try and sweep back to valid location
		cy = job:resolve_cursor()
		while cy > 0 and not job.data[cy] do
			job.cursor[2] = job.cursor[2] - 1
			cy = job:resolve_cursor()
		end
		n = n - 1
	end
end

local function cursor_beg(job, ch)
	job.cursor[1] = 0
	job.col_offset = 0
end

local function delete_rows_up(job, n)
	local row = job:resolve_cursor()
	local items = {}

	while n > 0 and job.data[row-1] do
		table.insert(items, {
			insert = table.remove(job.data, row - 1),
			line = row - 1
		})

		n = n - 1
		job.data.linecount = job.data.linecount - 1
	end

	add_history_item_set(job, items)
	cat9.flag_dirty(job)
end

local function delete_rows_down(job, n)
	local row = job:resolve_cursor()
	local items = {}

	while n > 0 and job.data[row] do
		table.insert(items, {
			insert = table.remove(job.data, row),
			line = row
		})
		n = n - 1
		job.data.linecount = job.data.linecount - 1
	end

	add_history_item_set(job, items)
	cat9.flag_dirty(job)
end

local function cursor_delete_n(job, n)
	local cy, cx = job:resolve_cursor()

	local work = job.data[cy]
	if not work then
		return
	end

-- special case [cx == 0]
	if cx == 0 then
		if cy > 1 then
			job.cursor[1] = job.root:utf8_len(job.data[cy - 1]) + 1
			local old = job.data[cy - 1]

			job.data[cy - 1] = job.data[cy - 1] .. job.data[cy]

			add_history_item(job,
				{replace = old, line = cy - 1},
				{insert = table.remove(job.data, cy), line = cy}
			)

			job.data.linecount = job.data.linecount - 1
			job.data.bytecount = job.data.bytecount - 1
			cursor_up_n(job, 1)

			cat9.flag_dirty(job)
		end

		return
	end

	local row = job.data[cy]
	while n > 0 and job.data[cy] do
		local beg = cursor_byte_index(job, -2)
		local cur = cursor_byte_index(job, 0)

		if beg > 0 then
			if cur > 0 then
				job.data[cy] = string.sub(work, 1, beg) .. string.sub(work, cur)
			end
			cat9.flag_dirty(job)
		elseif cur > 0 then
			job.data[cy] = string.sub(work, cur)
		end

		n = n - 1
	end

	add_history_item(job, {replace = row, line = cy})
end

--
-- temporary for debugging the undo feature
--
local function dump_undo(job)
	if true then
		return
	end

	print("offset", job.edit.history.offset, "count", #job.edit.history)
	for i=#job.edit.history,1,-1 do
		local item = job.edit.history[i]
		for _, item in ipairs(item) do
			if item.remove then
				print(i, "remove", item.line)
			end
			if item.insert then
				print(i, "insert", item.line, item.insert)
			end
			if item.replace then
				print(i, "replace", item.line, item.replace)
			end
		end
	end
end

local function process_undo(job)
	dump_undo(job, "pre")
	local ui = job.edit.history.offset
	local item = job.edit.history[#job.edit.history - ui]
	if not item then
		return
	end

-- each item is a set of patches,
--
-- e.g. start-row, remove or insert at byte offset and should be created as the
-- inverse of the operation that preceeded it.
--
-- then when applying it we invert that again and add back into the history at
-- the offset we are at.
--
-- this format is wasteful-ish in that it tracks single character edits as full
-- line replacements.
--
--
	local revert = {
		cursor = {job.cursor[1], job.cursor[2]},
		row_offset = job.row_offset,
		col_offset = job.col_offset
	}

	for i,v in ipairs(item) do
		if v.remove then
			table.insert(revert, {
				insert = table.remove(job.data, v.line),
				line = v.line
			})
			job.data.linecount = job.data.linecount - 1
		end

		if v.insert then
			table.insert(revert, {
				remove = true,
				line = v.line
			})
			table.insert(job.data, v.line, v.insert)
			job.data.linecount = job.data.linecount + 1
		end

		if v.replace then
			table.insert(revert, {
				replace = job.data[v.line],
				line = v.line
			})
			job.data[v.line] = v.replace
		end
	end

	job.cursor = item.cursor
	job.row_offset = item.row_offset
	job.col_offset = item.col_offset

	job.edit.history[#job.edit.history - ui] = revert
	job.edit.history.offset = ui + 1

	dump_undo(job, "post")
	cat9.flag_dirty(job)
end

local function process_revert(job)
	if job.edit.history.offset == 0 then
		return
	end

	job.edit.history.offset = job.edit.history.offset - 1
	process_undo(job)
	job.edit.history.offset = job.edit.history.offset - 1
end

-- map to view highlight
local function insert_ch(job, ch, track)
	local row, col = job:resolve_cursor()
	local bv = string.byte(ch, 1)

	local insert = true
	local consume = false

	if ch == "\n" or ch == "\r" then
		local bi = cursor_byte_index(job, -1)
		local bd = cursor_byte_index(job, 0)
		local ti = ""

-- break up line
		if bi > 1 then
			local old = job.data[row]
			ti = string.sub(old, bd)
			job.data[row] = string.sub(old, 1, bi)
			table.insert(job.data, row + 1, ti)

			if track then
				add_history_item(job,
					{line = row, replace = old}, {line = row + 1, remove = row})
			end

		else
			table.insert(job.data, row, "")

			if track then
				add_history_item(job, {line = row, remove = true})
			end
		end

		job.cursor[2] = job.cursor[2] + 1
		job.data.linecount = job.data.linecount + 1
		cursor_beg(job)

		insert = false
		consume = true

	elseif ch == "\t" then
		ch = job.edit.tab

-- this will resolve to tui.keys.BACKSPACE in the keysym handler
	elseif ch == "\b" or bv == 27 then
		return false
	end

	if insert then
		add_history_item(job, {line = row, replace = job.data[row]})
		job.data[row] =
			string.sub(job.data[row], 1, col) ..
			ch ..
			string.sub(job.data[row], col+1)
		job.cursor[1] = job.cursor[1] + root.utf8_len(ch)

		consume = true
	end

	cat9.flag_dirty(job)
	return consume
end

local function delete_cursor_end(job)
	local beg, ind, row = cursor_byte_index(job, 0)
	if beg < 0 then
		return
	end
	add_history_item(job, {line = ind, replace = job.data[ind]})
	job.data[ind] = string.sub(job.data[ind], 1, beg - 1)
end

local function delete_cursor_to(job, ofs)
	local beg, ind, row = cursor_byte_index(job, 0)
	if beg < 0 then
		return
	end
	add_history_item(job, {line = ind, replace = job.data[ind]})
	job.data[ind] = string.sub(row, 1, beg - 1) .. string.sub(row, ofs)
end

local function is_word_ch(ch)
	return string.match(ch, "%w") ~= nil
end

local function get_next_word(job, dir)
	local beg, ind, row = cursor_byte_index(job, 0)
	local in_word
	local steps = 0

-- special case, jump up one
	if dir < 0 and beg == 1 and ind > 1 then
		ind = ind - 1
		row = job.data[ind]
		beg = #row - 1
	end

	stop = cat9.each_ch(row,
		function(ch, pos)
			steps = steps + 1
			if in_word == nil then
				in_word = is_word_ch(ch)
			elseif in_word ~= is_word_ch(ch) then
				return true
			end
		end,
		function()
		end, beg, dir
	)

	return stop, steps
end

local function cursor_word(job, step)
-- step word or delete word
	local ofs, steps = get_next_word(job, step)

	if ofs then
		if step < 0 then
			cursor_left_n(job, steps - 1, true)
		end

		if job.edit.command[1] == "d" then
			delete_cursor_to(job, ofs)
		else
			if step > 0 then
				cursor_right_n(job, steps)
			end
		end
	else
		if job.edit.command[1] == "d" then
			delete_cursor_end(job)
		else
			cursor_beg(job)
			if step > 0 then
				cursor_down_n(job, 1)
			end
		end
	end
end

local function cursor_paste(job, before)
	if not job.edit.yank_buffer then
		return
	end

	if before and job.cursor[1] > 0 then
		job.cursor[1] = job.cursor[1] - 1
	end

-- just iterate and simulate character insertion, for undo history to do this
-- atomically we don't want each insertion to actually register but rather save
-- the pre-state and the post-state.
	for _, v in ipairs(job.edit.yank_buffer) do
		cat9.each_ch(v,
			function(ch)
				insert_ch(job, ch)
			end,
			function()
			end
		)
		if job.edit.yank_buffer.multiline then
			insert_ch(job, "\n")
		end
	end
end

local function process_delete(job)
	if job.edit.command[1] == "d" then
		job.edit.command = {}
		delete_rows_down(job, 1)
	else
		job.edit.command[1] = "d"
	end
	return true
end

local function process_yank(job)
	if job.edit.command[1] == "y" then
	else
		job.edit.command[1] = "y"
	end
	return true
end

local function slice_row(row, start, stop)
	local count = stop - start
	local res = {}

	cat9.each_ch(row,
		function(ch)
			table.insert(res, ch)
			count = count - 1
			return count == 0
		end,
		function()
		end,
		start[1] + 1
	)
	return table.concat(res, "")
end

local function vsel_to_yank(job, new)
	local rows = {multiline = #job.edit.vsel > 1}

	for _,v in ipairs(job.edit.vsel) do
		if v.row then
			table.insert(rows, job.data[v])
		else
			for _, set in ipairs(job.edit.vsel[v]) do
				table.insert(rows, slice_row(job.data[v], set[1], set[2]))
			end

			table.insert(rows, row)
		end
	end

	cat9.add_message(tostring(#rows) .. " lines yanked")
	job.edit.yank_buffer = rows
end

local function cursor_vcenter(job)
	local page_size = job.region[4] - job.region[2] - 2
	job.cursor[2] = math.floor(page_size * 0.5)
end

local function cursor_top(job)
	if job.row_offset > 1 then
		job.cursor[2] = job.edit.scroll_ofs
	else
		job.cursor[2] = 0
	end
end

local function cursor_bottom(job)
	local page_size = job.region[4] - job.region[2] - 2

	if page_size >= job.data.linecount - job.row_offset then
		job.cursor[2] = job.data.linecount - job.row_offset
	else
		job.cursor[2] = page_size - job.edit.scroll_ofs
	end
end

inputs[tui.keys.UP   ] = "k"
inputs[tui.keys.DOWN ] = "j"
inputs[tui.keys.LEFT ] = "h"
inputs[tui.keys.RIGHT] = "l"
inputs[tui.keys.BACKSPACE] =
function(job)
	if job.edit.mode == "insert" then
		cursor_delete_n(job, 1)
	end
	cursor_left_n(job, 1)
	return true
end

local command_map =
{
	h     = {cursor_left_n ,   1, flush  = true,  realign = true},
	l     = {cursor_right_n,   1, flush  = true,  realign = true},
	j     = {cursor_down_n ,   1, flush  = true,  realign = true},
	k     = {cursor_up_n   ,   1, flush  = true,  realign = true},
  ["0"] = {cursor_beg    , nil, flush  = true,  realign = true},
	["$"] = {cursor_end    , nil, flush  = true,  realign = true},
  w     = {cursor_word   ,   1, flush  = true,  realign = true},
	b     = {cursor_word   ,  -1, flush  = true,  realign = true},
	p     = {cursor_paste,   nil, flush  = true,  realign = true},
	P     = {cursor_paste,  true, flush  = true,  realign = true},
	M     = {cursor_vcenter, nil, flush  = true,  realign = true},
	H     = {cursor_top,     nil, flush  = true,  realign = true},
	L     = {cursor_bottom,  nil, flush  = true,  realign = true},
	y     = {process_yank,   nil, flush  = false, realign = false, buffer = true},
	d     = {process_delete, nil, flush  = false, realign = true,  buffer = true},
	u     = {process_undo,   nil, flush  = true,  realign = true},
	r     = {process_revert, nil, flush  = true,  realign = true}
}

local function command_ch(job, ch)
	local cmd = command_map[ch]
	if not cmd then
		return false
	end

	if cmd.buffer then
		cmd[1](job, ch)
	else
		cmd[1](job, cmd[2])
	end

	if cmd.flush then
		job.edit.command = {}
	end

	if cmd.realign then
		realign_synch(job)
	end
	return true
end

local function convert_cursor_to_vsel(job)
	local set = {}
	local start_row = job.edit.vrange.start_row
	local start_col = job.edit.vrange.start_col
	local stop_row = job.edit.vrange.stop_row
	local stop_col = job.edit.vrange.stop_col

	local function add_partial(ind, start, stop)
		if stop < 0 then -- edge condition for empty lines
			stop = 0
		end

		if start == stop then
			return
		end

		set[ind] = { start < stop and {start, stop} or {stop, start} }
	end

	if start_row < stop_row then
-- first fill cursor to end
		add_partial(start_row, start_col, root:utf8_len(job.data[start_row]))

-- then add each line as full, mark full rows as that as a minor optimization
		for i=start_row+1,stop_row do
			if i == stop_row then
				add_partial(i, 0, stop_col)
			else
				set[i] = {row = true}
			end
		end

	elseif start_row > stop_row then
		for i=start_row-1,stop_row,-1 do
			if i == stop_row then
				add_partial(i, stop_col, root:utf8_len(job.data[i]))
			else
				set[i] = {row = true}
			end
		end
	else
		add_partial(start_row, start_col, stop_col)
	end

	job.edit.vsel = set
end

-- cursor manipulation commands
local visual_cmd_map = {"h", "l", "j", "k", "b", "e", "w"}
local function visual_ch(job, ch)

-- implement by forwarding certain navigation commands (which respect block/line)
-- and remember both the cursor position and the offsets (to handle scrolling)
--
-- then we compare the deltas and generate the vsel from that (which is used for
-- the yank/modify operations as well as the write_override that shows the selection)
--
	if table.find_i(visual_cmd_map, ch) then
		command_ch(job, ch)

-- explicitly force a redraw as resolving the cache for cursor to data index
-- mapping across folds is done at raw_view stage.
		if #job.folds > 0 then
			cat9.redraw()
		end

-- did we grow ( > stop), shrink ( < stop) or invert direction ( < start )?
		local row, col = job:resolve_cursor()
		if job.edit.vrange.stop_row == row and job.edit.vrange.stop_col == col then
			return
		end

		job.edit.vrange.stop_row = row
		job.edit.vrange.stop_col = col

-- applying cursor delta to vsel rather than calculating is much less wasteful,
-- but also a lot more corner-casey so go with the naive approach for now.
		convert_cursor_to_vsel(job)
		cat9.flag_dirty(job)

-- other controls:
-- toggle skip for gaps, switch to block, yank to new job
	elseif ch == "y" or ch == "Y" then
		vsel_to_yank(job, ch == "Y")
		set_command_mode(job)

	elseif ch == "v" then
		set_command_mode(job)
		return
	end
end

local function editctl_write(job, cx, y, row, set, ind, _, selected, cols, match_index)
-- first apply the regular- style write
	job.root:write_to(cx, y, row, job:attr_lookup(set, ind, 0, job.selections[ind]))

	local function apply_range(start, stop)
		for i=start, stop do
			local _, attr = job.root:get(cx + i, y, false)

-- handle both indexed and explicit colors
			if attr.fc then
				attr.bc = config.edit.select.bc
				else
					attr.br = config.edit.select.br
					attr.bg = config.edit.select.bg
					attr.bb = config.edit.select.bb
				end

				attr.border_down = config.edit.select.border_down
				job.root:write_to(cx + i, y, attr)
		end
	end

-- now override attribute for cells that match our index range
	if job.edit.vsel[ind] then
		if job.edit.vsel[ind].row then
			apply_range(0, root:utf8_len(row))
		else
			for _,v in ipairs(job.edit.vsel[ind]) do
				apply_range(v[1], v[2])
			end
		end
	end
end

function cat9.make_editable(job, opts)
	if job.block_edit then
		cat9.add_message("job is not editable")
		return
	end

-- toggle off
	if job.edit then
		local restore = job.edit.restore
		job.edit = nil
		job.key_input = restore.key_input
		job.write = restore.write
		job.write_override = restore.write_override
		job.handlers.mouse_button = restore.mouse_button
		job.handlers.toggle_selected = restore.toggle_selected

-- here we'd really need / want nbio based communication between a threaded VM
-- instance or process so that this isn't blocking and we can do this to large
-- sources ...
		if opts.diff and restore.history then
			local t1 = table.concat(job.data, "\n")
			local t2 = table.concat(restore.history, "\n")

			local patch = cat9.diff.patch_make(t1, t2)

			if patch then
				cat9.patch_job(job, patch)
			else
				cat9.add_message("couldn't produce diff")
			end
		end

		if opts.revert and restore.history then
			job.data = restore.history
			cat9.flag_dirty(job)
		end

		return
	end

	job.edit = {
		mode = "command",
		command = {},
		tab = "  ",
		scroll_ofs = 4,
		history = {offset = 0},
		vsel = {
		},
		restore = {
			key_input = job.key_input,
			write = job.write,
			write_override = job.write_override,
			mouse_button = job.handlers.mouse_button,
			toggle_selected = job.handlers.toggle_selected
		}
	}

-- make a copy of the dataset unless it exceeds some upper bounds in order to
-- produce diffs and revert
	if job.data.bytecount < config.edit.snapshot_size then
		local hd = {}
		for i=1, job.data.linecount do
			table.insert(hd, job.data[i])
		end
		hd.linecount = job.data.linecount
		hd.bytecount = job.data.bytecount
		job.edit.restore.history = hd
	end

-- the option is for a template:
--
--  i.e. unmasked and cursor on it enforces a certain validation
--       or completion set.
--
-- other parts is using an external oracle to get completion data,
-- as well as formatting like syntax highlight
--
	job.key_input =
	function(job, sub, keysym, code, mods)
		if inputs[keysym] then
			if type(inputs[keysym]) == "string" then
				job:write(inputs[keysym])
			else
				inputs[keysym](job, mods)
			end

			realign_synch(job)
			return true
		end
	end

	job.write =
	function(job, ch)
		if #ch == 0 then
			return false
		end

		if job.edit.mode == "insert" then
			return insert_ch(job, ch, true)
		elseif job.edit.mode == "command" then
			return command_ch(job, ch)
		elseif job.edit.mode == "replace" then
			return -- replace_ch(job, ch)
		elseif job.edit.mode == "visual" then
			return visual_ch(job, ch)
		end
	end

	job.write_override = editctl_write

	job.handlers.mouse_button =
	function(job)
	end

	job.handlers.toggle_selected =
	function(job, on)
		if job.edit.mode == "insert" then
		else
		end
	end
end
end
