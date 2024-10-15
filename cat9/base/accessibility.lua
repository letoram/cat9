return
function(cat9, root, config)

local a11y_handlers = {}
local a11y_lastmsg = 0
local a11y_now = 0
local a11y_scrolling

-- keep the last n items around to stepping
local a11y_last = ""
local a11y_queue = {}
-- cwd comes from current title
-- same with focused job (which should set title)

-- opt here is reserved for an extra help key press that provides
-- more context as to the current item, ignore for now
local function a11y_buffer(msg, opt)
	if a11y_queue[#a11y_queue] == msg or a11y_last == msg then
		return
	end

	if a11y_queue[#a11y_queue] then
		if string.sub(a11y_queue[#a11y_queue], #msg) == msg then
			a11y_queue[#ally_queue] = msg
			return
		end
	end

-- if the last queued item is a substring of the new one, replace it instead
	table.insert(a11y_queue, msg)
end

function a11y_handlers.recolor(wnd)
	if #a11y_queue == 0 then
		return
	end

	wnd:write_to(0, 0, a11y_last)
	wnd:refresh()
end

local function scroll(wnd)
	local cols, _ = wnd:dimensions()
	local msg = string.sub(a11y_scrolling, 1, cols)
	a11y_scrolling = string.sub(a11y_scrolling, cols)

	if #msg == 0 then
		a11y_scrolling = nil
	else
		wnd:erase()
		wnd:write_to(0, 0, msg)
		wnd:refresh()
		a11y_lastmsg = a11y_now
		return
	end
end

function a11y_handlers.tick(wnd)
	a11y_now = a11y_now + 1
	if a11y_now - a11y_lastmsg < config.a11y_limit then
		return
	end

	if a11y_scrolling then
		scroll(wnd)
		return
	end

	if #a11y_queue > 0 then
		a11y_last = table.remove(a11y_queue, 1)
		if #a11y_last > wnd:dimensions() then
			a11y_scrolling = a11y_last
			scroll(wnd)
			return
		end

		wnd:erase()
		wnd:write_to(0, 0, a11y_last)
		wnd:refresh()
		a11y_lastmsg = a11y_now

-- nothing queued, then check the current prompt and read that out
	elseif #a11y_queue == 0 then
		if cat9.readline then
			local line = cat9.readline:get()
			if line ~= a11y_lastline then
				a11y_buffer(line)
				a11y_lastline = line
				return
			end
		end

-- if the last line doesn't fit, now is the time to scroll onwards with
-- wnd dimensions to make sure all is eventually heard.
	end
end

local function a11y_item(wnd, item, hint)
	a11y_buffer(item, hint)
end

function a11y_handlers.resized(wnd)
	wnd:write_to(0, 0, a11y_last)
	wnd:refresh()
end

if config.accessibility then
	config.readline.item = a11y_item

	root:new_window("accessibility",
		function(wnd, new)
			if not new then
				return
			end

			cat9.a11y = new
			cat9.a11y_buffer = a11y_buffer
			new:set_flags(tui.flags.hide_cursor)

			new:hint({max_cols = 80, max_rows = 1})
			new:set_handlers(a11y_handlers)
		end
	)
end

end
