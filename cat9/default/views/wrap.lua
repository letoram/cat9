return
function(cat9, root, builtins, suggest, views)

-- for each index in fmt within the range start <= n <= stop,
-- slice out msg, add to dst table and inject fmt
local function walk_fmt(dst, msg, start, stop, fmt)
	local last = start

	for i=start,stop do
		if fmt[i] then
			if i > start then
				local pre = string.sub(msg, last, i-1)

				if #pre > 0 then
					table.insert(dst, pre)
					last = i
				end
			end
			table.insert(dst, fmt[i])
		end
	end

	table.insert(dst, string.sub(msg, last, stop))
end

-- greedy / naive / compacting:
local function break_line(dst, msg, prefix, cap, offset, raw, fmt)

-- compact if desired (     ) -> ( ) and tab to two spaces.
-- can't do that (yet) if we have formats as their indices would
-- get out of sync
	if not raw and not fmt then
		msg = string.gsub(msg, "%s+", " ")
		msg = string.gsub(msg, "\t", "  ")
	end

	local len = root:utf8_len(msg)
	local blen = #msg

-- early out, it already fits, still need to apply formatting though
	if len <= cap then
		if not fmt then
			table.insert(dst, msg)
		else
			walk_fmt(dst, msg, 1, #msg, fmt)
		end

		table.insert(dst, "\n")
		return 1
	end

-- better / language specific word-breaking rules go here, for now
-- just step character by character and split when we cross
	local count = 0
	local start = 1
	local pos = 1
	local newl = 0
	local dst_sz = #dst

	while start < blen and start > 0 do
		while count < cap-1 and pos > 0 do
			pos = root:utf8_step(msg, 1, pos)
			count = count + 1
		end

-- broken message or no more characters
		if pos < 0 then
			if start < blen then
				table.insert(dst, string.sub(msg, start))
				table.insert(dst, "\n")
				newl = newl + 1
			end
			start = blen
			break
		end

		table.insert(dst, string.sub(msg, start, pos))
		table.insert(dst, "\n")
		table.insert(dst, prefix)
		newl = newl + 1
		start = root:utf8_step(msg, pos)
		pos = start
		count = 0
	end

-- and return how many lines that were added
	return newl
end

local function slice_view(job, lines)
	local res = {bytecount = 0, linecount = 0}
	local state = job.view_state
	local set = job[state.stream]

	if state.vt100 then
		return cat9.resolve_lines(
		job, res, lines,
			function(i)
				local rc = state.row_cache
				if not i then
					return rc
				end
				if rc[i] then
					return rc[i], #rc[i], 1
				else
					return nil, 0, 0
				end
			end
		)
	end
	return cat9.default_slice(job, lines, set)
end

local function reduce_fmt(job, set, lc, ofs, cols, raw)
	local res = {}
	local state = job.view_state

	local ind = 0

	local dataattr = cat9.config.styles.data
	local lineattr = cat9.config.styles.line_number
	local digits = #tostring(set.linecount)
	local prefix = ""

-- with line-numbers we might want to add padding to the broken line to
-- make that column 'distinct'
	if job.show_line_number then
		prefix = string.rep(" ", digits + 2)
		cols = cols - digits - 2
	end
	local total = 0

-- too compact to fit?
	if cols < 0 then
		return 0
	end

-- prepare to start with new line number
	local dirty_line = true
	table.insert(res, dataattr)

-- wrap, add to set and reduce lc with the number
	for i=1,lc do
		if job.row_offset_relative then
			ind = set.linecount - lc + i + ofs
		else
			ind = ofs
		end

		if ind <= 0 then
			ind = i
		end

		local row = job.data[ind]
		if not row then
			break
		end

-- if we enable state decoding, the wrapping need to process the annotated
-- output while tracking the atttribute correctly as well (transitions to
-- / from altscreen should switch between wrap and crop) and have different
-- semantics
		if state.vt100 then
			local cached = state.row_cache[ind]

			if cached and not (ind == #state.row_cache and #row ~= #cached) then
				row = cached
				attr = state.fmt_cache[ind]
			else
-- if another data filter has been attached ..
				if state.vt100.consume then
					row, attr = state.vt100:consume(row)
					state.row_cache[i] = row
					state.fmt_cache[i] = attr
				end
			end
		end

-- add line number and formatting
		if job.show_line_number and dirty_line then
			table.insert(res, lineattr)
			local num = tostring(ind)
			if #num < digits then
				table.insert(res, string.rep(" ", digits - #num))
			end
			table.insert(res, num)
			table.insert(res, ": ")
			table.insert(res, dataattr)
			dirty_line = false
		end

-- add the final linefeed to indicate that there is actually a newline
		local count = break_line(res, row, prefix, cols, job.col_offset or 0, raw, attr)

		if count > 0 then
			total = total + count
			table.insert(res, dataattr)
			dirty_line = true
		end
	end

	return res, total
end

local
function job_wrap(job, x, y, cols, rows, probe, hidden)
	local state = job.view_state
	local set = job[state.stream]

	if not x or not cols or not rows then
		return set
	end

-- get the number of lines that we can draw
	local lc = set.linecount and set.linecount or 0
	lc = lc > rows and rows or lc

	local ofs = job.row_offset
	if lc >= set.linecount then
		ofs = 0
	end

	if state.cap and state.cap < cols and state.cap > 0 then
		cols = state.cap
	end

-- if set.linecount and presentation offsets are the same as cached,
-- early out - otherwise rebuild the split / absorbed set
	local reduced, count
	if job.wrap_cache and
		job.wrap_cache.col_count == cols and
		job.wrap_cache.bytecount == set.bytecount and
		job.wrap_cache.col_offset == job.col_offset and
		job.wrap_cache.show_line_number == job.show_line_number and
		job.wrap_cache.row_offset == job.row_offset then
		reduced = job.wrap_cache.reduced
		count = job.wrap_cache.count
	else
		reduced, count =
			reduce_fmt(job, set, lc, ofs, cols, false)
		job.wrap_cache = {
			linecount = set.linecount,
			bytecount = set.bytecount,
			col_offset = job.col_offset,
			row_offset = job.row_offset,
			show_line_number = job.show_line_number,
			reduced = reduced,
			count = count,
			col_count = cols
		}
	end

	if probe then
		return count
	end

-- sweep reduced
	local attr
	local cl = 0
	local cx = x + cat9.config.content_offset
	local cy = y
	job.root:cursor_to(cx, cy)

	for _,v in ipairs(reduced) do
		if type(v) == "table" then
			attr = v
		elseif v == "\n" then
			cy = cy + 1
			job.root:cursor_to(cx, cy)
		else
			job.root:write(v, attr)
		end

-- protect against wrapping overflow
		if cy - y > lc then
			break
		end
	end

	return cy - y
end

-- very similar to base/jobctl.lua:raw_view with the main difference being that
-- the set is mapped through the break_line call and out:ed when the linecount
-- cap is exceeded.
function views.wrap(job, suggest, args, raw)
	if not suggest then
		local state = {stream = "data"}

		if not args[2] then
			return
		end

		for _,v in ipairs(args) do
			if v == "vt100" then
				state.vt100 = cat9.vt100_state()
				state.row_cache = {}
				state.fmt_cache = {}

-- need  to swap out slice so we can get the contents post formatting
			elseif v == "err" then
				state.stream = "err_buffer"
			elseif v == "data" then
				state.stream = "data"
			elseif tonumber(v) then
				state.cap = tonumber(v)
			end
		end

		job:set_view(job_wrap, slice_view, state, "wrap")
		return
	end

-- vt100, err and other attributes and column- count can come in any order,
-- we don't yet have the option to hint about args that won't get "expanded"
-- (limitation in readline)
	local set = {"vt100", "err"}
	for i,v in ipairs(args) do
		if v == "vt100" then
			table.remove(set, 1)
			break
		end
	end

	cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
end
end
