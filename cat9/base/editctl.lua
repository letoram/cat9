return
function(cat9, root, config)

-- since this runs in 'focused job input mode' the regular cat9/config/bindings.lua
-- shouldn't be used and we keep the inputs as a separate part of default.lua config
--
-- what would be interesting is to have a scope filter and a widen / step in
-- but we need cooperation with some language oracle and maintain a tmpfile that
-- we can feed it through
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
--   H to top of screen
--   M to middle
--   L to bottom
--   w forward to start of word
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
--   marking:
--    v - start visual, mark
--    V - start linewise visual
--    o - move to end of marked
--    ctrl+v visual block
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

local function set_input_mode(job)
	job.edit.insert = {}
	job.edit.mode = "insert"
	job.bar_color_selected = tui.colors.ref_green
end

local function set_command_mode(job)
	job.edit.command = {}
	job.edit.mode = "command"
	job.bar_color_selected = tui.colors.highlight
end

local function set_append_mode(job)
	set_input_mode(job)
	job.cursor[1] = job.cursor[1] + 1
end

local function set_replace_mode(job)
	job.edit.mode = "replace"
	job.edit.replace = {}
	job.bar_color_selected = tui.colors.ref_red
end

inputs[config.edit.input_mode   or tui.keys.I]      = set_input_mode
inputs[config.edit.command_mode or tui.keys.ESCAPE] = set_command_mode
inputs[config.edit.replace_mode or tui.keys.R]      = set_replace_mode
inputs[config.edit.append_mode  or tui.keys.A]      = set_append_mode

local function cursor_data_index(job)
	return job.row_offset + job.cursor[2], job.col_offset + job.cursor[1]
end

local function cursor_byte_index(job, ofs)
	local y = job.row_offset + job.cursor[2]
	local row = job.data[y]
	if not row then
		return -1
	end

	return root:utf8_step(row, job.col_offset + job.cursor[1] + ofs), y, row
end

-- call when the underlying data has been modified and we want to redraw
local function realign_synch(job)
	local cy = cursor_data_index(job)
	local co = job.edit.mode == "insert" and 1 or 0

	if not job.data[cy] then
		job.cursor[1] = 1
-- should be u8 len, also insert mode needs us to be at the next
	elseif job.cursor[1] >= #job.data[cy] + co then
		job.cursor[1] = #job.data[cy] - 1
	end

	if job.row_offset + job.cursor[2] > job.data.linecount then
		job.cursor[2] = job.data.linecount - job.row_offset
		if job.cursor[2] < 0 then
			job.cursor[2] = 0
		end
	end

	cat9.flag_dirty(job)
end

local function cursor_left_n(job, n)
	while n > 0 do
		if job.cursor[1] > 0 then
			job.cursor[1] = job.cursor[1] - 1
		elseif job.col_offset > 0 then
			job.col_offset = job.col_offset - 1
		else
			break
		end
		n = n - 1
	end
end

local function cursor_right_n(job, n)
	while n > 0 do
		job.cursor[1] = job.cursor[1] + 1
		n = n - 1
	end
end

local function cursor_down_n(job, n)
	local cy = cursor_data_index(job)
	while n > 0 do
		cy = cy + 1
		job.cursor[2] = job.cursor[2] + 1
		if not job.data[cy] then
			cy = cy - 1
			job.cursor[2] = job.cursor[2] - 1
			break
		end
		n = n - 1
	end
end

local function cursor_beg(job, ch)
	job.cursor[1] = 0
	job.col_offset = 0
end

local function cursor_end(job, ch)
	local cy = cursor_data_index(job)
	if not job.data[cy] then
		return
	end

	job.cursor[1] = job.root:utf8_len(job.data[cy])
end

local function cursor_up_n(job, n)
	while n > 0 do
		if job.cursor[2] == 0 then
			break
		end
		job.cursor[2] = job.cursor[2] - 1
		n = n - 1
	end
end

local function delete_rows_up(job, n)
	local row = cursor_data_index(job)
	while n > 0 and job.data[row-1] do
		table.remove(job.data, row - 1)
		n = n - 1
		job.data.linecount = job.data.linecount - 1
	end
	cat9.flag_dirty(job)
end

local function delete_rows_down(job, n)
	local row = cursor_data_index(job)
	while n > 0 and job.data[row] do
		table.remove(job.data, row)
		n = n - 1
		job.data.linecount = job.data.linecount - 1
	end

	cat9.flag_dirty(job)
end

local function cursor_delete_n(job, n)
	local cy, cx = cursor_data_index(job)

	local work = job.data[cy]
	if not work then
		return
	end

-- special case [cx == 0]
	if cx == 0 then
		if cy > 1 then
			job.cursor[1] = job.root:utf8_len(job.data[cy - 1]) + 1
			job.data[cy - 1] = job.data[cy - 1] .. job.data[cy]
			table.remove(job.data, cy)
			job.data.linecount = job.data.linecount - 1
			job.data.bytecount = job.data.bytecount - 1
			cursor_up_n(job, 1)

			cat9.flag_dirty(job)
		end
		return
	end

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
end

-- map to view highlight
local function insert_ch(job, ch, advance, leave)
	local row, col = cursor_data_index(job)
	local bv = string.byte(ch, 1)

	local insert = true
	local consume = false

-- unicode fail:
--     to figure out the number of bytes to cursor position
--     root:utf8_len can be used to seek from start to cursor position and
--     step backwards (repeat until a valid length of 1+ is returned)

	if ch == "\n" or ch == "\r" then
		local bi = cursor_byte_index(job, -1)
		local bd = cursor_byte_index(job, 0)
		local ti = ""

		if bi > 1 then
			ti = string.sub(job.data[row], bd)
			job.data[row] = string.sub(job.data[row], 1, bi)
			table.insert(job.data, row + 1, ti)
		else
			table.insert(job.data, row, "")
		end
		job.cursor[2] = job.cursor[2] + 1
		job.data.linecount = job.data.linecount + 1
		cursor_beg(job)

		insert = false
		consume = true

		if job.data.invalidate then
			job.data:invalidate(row)
		end

	elseif ch == "\t" then
		ch = job.edit.tab

-- this will resolve to tui.keys.BACKSPACE in the keysym handler
	elseif ch == "\b" or bv == 27 then
		return false
	end

	if insert then
		job.data[row] =
			string.sub(job.data[row], 1, col) ..
			ch ..
			string.sub(job.data[row], col+1)
		job.cursor[1] = job.cursor[1] + #ch

		if job.data.invalidate then
			job.data:invalidate(row)
		end
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
	job.data[ind] = string.sub(job.data[ind], 1, beg - 1)
end

local function delete_cursor_to(job, ofs)
	local beg, ind, row = cursor_byte_index(job, 0)
	if beg < 0 then
		return
	end
	job.data[ind] = string.sub(row, 1, beg - 1) .. string.sub(row, ofs)
end

local function is_word_ch(ch)
	return ch == string.upper(ch)
end

local function get_next_word(job)
	local beg, ind, row = cursor_byte_index(job, 0)
	local in_word
	local steps = 0

	stop = cat9.each_ch(row,
		function(ch, pos)
			steps = steps + 1
			if in_word == nil then
				in_word = is_word_ch(ch)
			elseif in_word ~= is_word_ch(ch) then
				return true
			end
		end,
		_, beg
	)

	return stop, steps
end

inputs[tui.keys.UP   ] = function(job) cursor_up_n(job,    1) end
inputs[tui.keys.DOWN ] = function(job) cursor_down_n(job,  1) end
inputs[tui.keys.LEFT ] = function(job) cursor_left_n(job,  1) end
inputs[tui.keys.RIGHT] = function(job) cursor_right_n(job, 1) end
inputs[tui.keys.BACKSPACE] =
function(job)
	if job.edit.mode == "insert" then
		cursor_delete_n(job, 1)
	end
	cursor_left_n(job, 1)
	return true
end

local function command_ch(job, ch)
	if ch == "h" then
		cursor_left_n(job, 1)
		job.edit.command = {}

	elseif ch == "l" then
		cursor_right_n(job, 1)
		job.edit.command = {}

	elseif ch == "j" then
		cursor_down_n(job, 1)
		job.edit.command = {}

	elseif ch == "k" then
		cursor_up_n(job, 1)
		job.edit.command = {}

	elseif ch == "b" then
		cursor_beg(job)
		job.edit.command = {}

	elseif ch == "e" then
		cursor_end(job)
		job.edit.command = {}

	elseif ch == "w" then
-- step word or delete word
		local ofs, steps = get_next_word(job)

		if ofs then
			if job.edit.command[1] == "d" then
				delete_cursor_to(job, ofs)
			else
				cursor_right_n(job, steps - 1)
			end
		else
			if job.edit.command[1] == "d" then
				delete_cursor_end(job)
			else
				cursor_beg(job)
				cursor_down_n(job, 1)
			end
		end
		job.edit.command = {}

	elseif ch == "d" then
		if job.edit.command[1] == "d" then
			job.edit.command = {}
			delete_rows_down(job, 1)
		else
			job.edit.command[1] = "d"
		end
	else
		return false
	end

	realign_synch(job)
	return true
end

function cat9.make_editable(job, opts)
	if job.block_edit then
		cat9.add_message("job is not editable")
		return
	end

	job.edit = {
		mode = "command",
		command = {},
		tab = "  "
	}

-- option:
--
--    fixed-lines,
--    template,
--    external highlighter,
--    external completion

-- this takes as inner-view, e.g. wrap or crop.
--
-- we overlay an input and click handler that applies input editing actions
-- and match how vim input takes things.
--
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
			inputs[keysym](job, mods)
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
			return insert_ch(job, ch)
		elseif job.edit.mode == "command" then
			return command_ch(job, ch)
		elseif job.edit.mode == "replace" then
			return -- replace_ch(job, ch)
		end
	end

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
