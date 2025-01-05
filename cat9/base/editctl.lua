return
function(cat9, root, config)

-- since this runs in 'focused job input mode' the regular cat9/config/bindings.lua
-- shouldn't be used and we keep the inputs as a separate part of default.lua config
--
-- what would be interesting is to have a scope filter and a widen / step in
-- but we need cooperation with some language oracle and maintain a tmpfile that
-- we can feed it through
--
-- utf8 challenge is that job.data is in utf8, while cursor is logical screen cell
-- which is a full codepoint.

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
--   ctrl + h delete before
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
end

local function set_command_mode(job)
	job.edit.command = {}
	job.edit.mode = "command"
end

inputs[config.edit.input_mode   or tui.keys.I]      = set_input_mode
inputs[config.edit.command_mode or tui.keys.ESCAPE] = set_command_mode

local function cursor_data_index(job)
	return job.row_offset + job.cursor[2], job.col_offset + job.cursor[1]
end

-- map to view highlight
local function insert_ch(job, ch, advance, leave)
	local row, col = cursor_data_index(job)
	local insert = true

-- unicode fail:
--     to figure out the number of bytes to cursor position
--     root:utf8_len can be used to seek from start to cursor position and
--     step backwards (repeat until a valid length of 1+ is returned)

	if ch == "\n" or ch == "\r" then
		table.insert(job.data, row, "")
		job.data.linecount = job.data.linecount + 1
		job.cursor[2] = job.cursor[2] + 1
		insert = false

		if job.data.invalidate then
			job.data:invalidate(row)
		end

	elseif ch == "\t" then
		ch = job.edit.tab

	elseif ch == "\b" then
-- special case, if we are at cursor:0, remove line and append to previous
-- unless at top, otherwise remove 1
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
	end

	cat9.flag_dirty(job)
end

local function cursor_left_n(job, n)
	while n > 0 do
		if job.cursor[1] > 0 then
			job.cursor[1] = job.cursor[1] - 1
		else
			break
		end
		n = n - 1
	end
end

-- clamping is done at end against actual line data
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

local function command_ch(job, ch)
	if ch == "h" then
		cursor_left_n(job, 1)

	elseif ch == "l" then
		cursor_right_n(job, 1)

	elseif ch == "j" then
		cursor_down_n(job, 1)

	elseif ch == "k" then
		cursor_up_n(job, 1)

	elseif ch == "b" then
		cursor_beg(job)

	elseif ch == "e" then
		cursor_end(job)
	end

	local cy = cursor_data_index(job)
	if not job.data[cy] then
		job.cursor[1] = 0
-- should be u8 len
	elseif job.cursor[1] >= #job.data[cy] then
		job.cursor[1] = #job.data[cy] - 1
	end

	cat9.flag_dirty(job)
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
			return replace_ch(job, ch)
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
