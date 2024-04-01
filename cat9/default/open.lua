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
}

local mime_prefix =
{
	video = "proto=media",
	image = "proto=image",
	text  = "proto=text"
}

local function fname_to_decode(cat9, root, dstenv, wdir, fn, closure)
	if cat9.scanner_active then
		cat9.stop_scanner()
	end

	local dir = root:chdir()
	root:chdir(wdir)

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
		root:new_window(wndtype,
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
function(cat9, root, builtins, suggest)

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

function suggest.open(args, raw)
	cat9.readline:suggest({}, "substitute", raw)
end

function builtins.open(file, ...)
	local trigger
	local opts = {...}
	local spawn = false
	local context = nil

	if type(opts[1]) == "table" and opts[1].parg then
		parg = table.remove(opts, 1)
	end

	for _,v in ipairs(opts) do
		if dir_lut[v] then
			spawn = dir_lut[v]
		end
	end

-- if we have parg then slice out and treat as individual files. right now this
-- ignores ranges and so on, though should likely set this up as either a
-- playlist or let the spawn permit multiple, just not have open #0(1-1000) a
-- thousand windows.
	if type(file) == "table" and parg then
		context = file
		local set = file:slice(parg)
		file = set and set[1]
		if file then
			file = string.gsub(file, "\n", "")
		end
	end

	if type(file) == "table" and file.view then
		trigger =
		function(par, wnd)
			local arg = {read_only = true}
			for _,v in ipairs(opts) do
				if v == "hex" then
					arg[cat9.config.hex_mode] = true
				end
			end

			buf = table.concat(file:slice(parg), "")

			if not spawn then
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
			else
				wnd:bufferview(buf,
					function()
						wnd:close()
					end, arg
				)
			end
		end

		spawn_trigger(cat9, root, "tui", spawn, trigger)

	elseif type(file) == "string" then
		open_string(file, spawn, context)
	end
end

end
