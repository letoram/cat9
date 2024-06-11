-- new window requests can add window hints on tabbing, sizing and positions,
-- those are rather annoying to write so have this alias table
local dir_lut =
{
	new = "split",
	tnew = "split-t",
	lnew = "split-l",
	dnew = "split-d",
	vnew = "split-d",
	tab = "tab",
	embed = "embed",
	swallow = "swallow"
}

-- can't (yet) launch shmif- clients directly so start with hard-coded proto
-- since the proto=list to mask out dependencies won't work, compromise might
-- be having this in decode
local mime_direct =
{
	["application/pdf"] = "proto=pdf",
	["application/octet-stream"] = "proto=text",
}

local mime_prefix =
{
	video = "proto=media",
	image = "proto=image",
	text  = "proto=text",
	audio = "proto=media"
}

local function fname_to_decode(cat9, root, dstenv, wdir, fn, closure)
	if cat9.scanner_active then
		cat9.stop_scanner()
	end

	local dir = root:chdir()
	root:chdir(wdir)

	local job =
		cat9.set_scanner(
		{"/usr/bin/env", "/usr/bin/env", "file", "-b", "--mime-type", fn},
		function(res)
			local proto
			if res and res[1] then
				if mime_direct[res[1]] then
					proto = mime_direct[res[1]]
				else
					for k,v in pairs(mime_prefix) do
						if string.sub(res[1], 1, #k) == k then
							proto = v
							break
						end
					end
				end

				if proto then
					dstenv["ARCAN_ARG"] = proto .. ":file=" .. fn
					closure()
				else
					cat9.add_message("open(" .. fn .. ") - unknown type: " .. res[1])
				end
			end
		end
	)

	root:chdir(dir)
end

local embed_handlers = {}
local function spawn_trigger(cat9, root, wndtype, spawn, trigger)
-- the 'embed' spawn method is special as we need to create a control job in
-- order to position and size the embedding
	if spawn then
		cat9.new_window(root, wndtype,
			function(par, wnd)
				if not wnd then
					cat9.add_message("window request rejected")
					return
				end
				local res = trigger(par, wnd)
			end, spawn
		)
	else
		trigger(root, root)
	end
end

return
function(cat9, root, builtins, suggest, views, builtin_cfg)

function embed_handlers.resized(wnd)
	cat9.flag_dirty()
end

local function find_job(wnd)
	for _,v in ipairs(lash.jobs) do
		if v.wnd == wnd then
			return v
		end
	end
end

function embed_handlers.visibility(wnd, visible, focus)
	local job = find_job(wnd)

	if not job or not job.lasthint then
		return
	end

-- this will cause a relayout which will send a new hint
	job:hide(visible)
	if job.lasthint.hidden ~= job.hidden then
		job.lasthint.hidden = job.hidden
		job.wnd:hint(root, job.lasthint)
	end
end

-- asynch query file on the file to figure out which 'proto' type to
-- handover exec/spawn. More oracles are needed here (eg. arcan appl,
-- xdg-open, arcan-wayland, default browser ...)
local function open_string(file, spawn, context)
	local dstenv = {}
	local root = cat9.get_active_root()

	if not spawn then
		spawn = cat9.config.open_spawn_default
	end

	local wdir = context and context.dir or root:chdir()

-- handover to the decoder, create a job for tracking and as anchor if
-- we are supposed to embed
	trigger =
	function(par, wnd)
		local dir = root:chdir()
		root:chdir(wdir)
		local _, _, _, pid = par:phandover(cat9.config.plumber, "", {"afsrv_decode"}, dstenv)

		root:chdir(dir)

		if not pid then
			wnd:close()
			return
		end

		local job =
		{
			pid = pid
		}

		if spawn == "embed" then
			job.wnd = wnd
			wnd:set_handlers(embed_handlers)
		else
			job.hidden = true
		end

		cat9.import_job(job)
		job.collapsed_rows = cat9.config.open_embed_collapsed_rows
		return true
	end

-- fname to decode spawns 'file' -> on result, runs the closure here, that in
-- turn modifies dstenv to match file and then queues the new window and runs
-- 'trigger'.
	fname_to_decode(
	cat9, root, dstenv, wdir, file,
		function()
			spawn_trigger(cat9, root, "handover", spawn, trigger)
		end
	)
end

local function open_internal(mode, context, viewm)
	trigger =
	function(par, wnd)
		local arg = {read_only = true}
		if viewm and viewm == "hex" then
			arg[cat9.config.hex_mode] = true
		end

-- still need to do this as bufferview can't take the
-- datatable as is, internally it would still need to resolve
-- the table so the copy is unavoidable in this form.
		buf = table.concat(context:slice(), "")

		if mode then
			wnd:bufferview(buf, function() wnd:close(); end, arg)
			return
		end

-- slightly more annoying as we need to take control over our
-- window and processing while viewing like this. It is also
-- possibly dangerous as there might be other triggers that
-- would cause open commands etc.
		cat9:block_readline(true)
		local old_reset = cat9.reset
		local old_redraw = cat9.redraw
		cat9.reset = function() end
		cat9.redraw = function() end
		wnd:revert()

		wnd:bufferview(
			buf,
			function()
				cat9:block_readline(false)
				cat9.reset = old_reset
				cat9.redraw = old_redraw
				cat9:reset()
			end,
			arg
		)
		return
	end

	spawn_trigger(cat9, root, "tui", mode, trigger)
end

function suggest.open(args, raw)
	cat9.readline:suggest({}, "substitute", raw)
end

builtins.hint["open"] = "Open a file or object"
function builtins.open(...)
	local opts = {...}
	local spawn = false
	local context = nil
	local terminal = false

-- first see of there is a preference for how it should be opened
	while type(opts[1]) == "string" and #opts > 1 do
		if opts[1] == "terminal" then
			terminal = true
			table.remove(opts, 1)
		else
			spawn = dir_lut[opts[1]]
			if not spawn then
				return false, "open >mode< file : unknown mode (" .. opts[1] .. ")"
			end
			table.remove(opts, 1)
		end
	end

-- if we open a table without an argument, it will be opened 'as is' as an internal window
	if type(opts[1]) == "table" then
		context = opts[1]
		if type(opts[2]) ~= "table" then
			open_internal(spawn, context, opts[2])
			return
		end
	end

-- otherwise expand
	local set = {}
	local ok, msg = cat9.expand_arg(set, opts)
	if not ok then
		return false, msg
	end

-- we don't handle any form of queue or playlist here, the intent for that is to handle through each #1 !!open $arg
	if #set > 1 then
		return false, "open : too many arguments after " .. set[1]
	end

-- if we set term then we use a different plumber to handle the file
	if terminal then

-- sanitize / escape / add path
		set[1] = string.gsub(set[1], "\n", "")

		if string.sub(set[1], 1, 1) ~= "/" then
			if not context then
				set[1] = root:chdir() .. "/" .. set[1]
			else
				set[1] = context.dir .. "/" .. set[1]
			end
		end

		cat9.term_handover(
			spawn or cat9.config.open_spawn_default,
			cat9.config.term_plumber,
			set[1]
		)
		return
	end

-- full open - classify type and hand over to plumber
	open_string(set[1], spawn, context)
end
end
