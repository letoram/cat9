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
	embed = "embed"
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

local function fname_to_decode(cat9, dstenv, fn, closure)
	if cat9.scanner_active then
		cat9.stop_scanner()
	end

	cat9.set_scanner(
		{"/usr/bin/file", "file", "-b", "--mime-type", fn}, "open" .. fn,
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
end

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
				return trigger(par, wnd)
			end, spawn
		)
		return false

-- it is now in the hand of the display server
	else
		cat9.readline = nil
		trigger(root, root)
		return true
	end
end

return
function(cat9, root, builtins, suggest)

function suggest.open(args, raw)
	cat9.readline:suggest({}, "substitute", raw)
end

function builtins.open(file, ...)
	local trigger
	local opts = {...}
	local spawn = false
	local spawn_suffix = ""

	for _,v in ipairs(opts) do
		if dir_lut[v] then
			spawn = dir_lut[v]
		elseif v == "sync" then
			spawn_suffix = "-sync"
		end
	end

	if type(file) == "table" and file.data then
		trigger =
		function(par, wnd)
			local arg = {read_only = true}
			for _,v in ipairs(opts) do
				if v == "hex" then
					arg[cat9.config.hex_mode] = true
				end
			end
			wnd:revert()
			buf = table.concat(file:view(), "")

			if not spawn then
				wnd:bufferview(buf, cat9.reset, arg)
			else
				wnd:bufferview(buf,
					function()
						wnd:close()
					end, arg
				)
			end
		end

		spawn = spawn and spawn or "split"
		spawn_trigger(cat9, root, "tui", spawn .. spawn_suffix, trigger)

-- asynch query file on the file to figure out which 'proto' type to handover
-- exec/spawn. More oracles are needed here (eg. arcan appl, xdg-open,
-- arcan-wayland, default browser ...)
	elseif type(file) == "string" then
		local dstenv = {}

		if not spawn then
			spawn = cat9.config.open_spawn_default
		end

-- handover to the decoder, create a job for tracking and as anchor if we are
-- supposed to embed
		trigger =
		function(par, wnd)
			local _, _, _, pid = par:phandover("/usr/bin/afsrv_decode", "", {}, dstenv)
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
		cat9, dstenv, file,
			function()
				spawn_trigger(cat9, root, "handover", spawn .. spawn_suffix, trigger)
			end
		)
		return
	end
end

end
