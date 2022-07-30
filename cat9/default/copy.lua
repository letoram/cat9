local function copy_tbl_ud(cat9, root, job)
	job.dst:write(
	job.src,
		function(ok)
			if not ok then
				job.code = 1
				job.short = "(failed) " .. job.short
			else
				cat9.remove_job(job)
			end
			job.dst:close()
			job.dst = nil
			job.src = nil
			job.check_status = nil
		end
	)
end

local function copy_tbl(cat9, root, job)
	job.data =
	{
		linecount = job.src.linecount,
		bytecount = job.src.bytecount
	}

	for i=1,#job.src do
		table.insert(job.data, job.src[i])
	end

	job.src = nil
	job.dst = nil
	job.check_status = nil
end

local function copy_ud_ud(cat9, root, job)
	local acc = 0
	local progio = root:bgcopy(job.src, job.dst, job.flags)

	if not progio then
		cat9.add_message("copy {...} - copy job rejected (resource exhaustion)")
		return
	end

-- now we can update status, though we don't have the quantities necessarily
	progio:data_handler(
		function()
			local line, alive = progio:read()
			local last = line
			while line and #line > 0 do
				last = line
				line, alive = progio:read()
			end

			local props = string.split(last, ":") -- [status, current, total]
			if #props < 3 then -- unknown format
				return
			end

			local bs = tonumber(props[1])
			local cur = tonumber(props[2])
			local tot = tonumber(props[3])

			if bs < 0 then
				job.bar_color = tui.colors.alert
				job.data = string.format(
					"I/O error at %s / %s", cat9.bytestr(cur), cat9.bytestr(tot))

-- complete
			elseif bs == 0 then
				cat9.remove_job(job)
			else
				local prog = ""
				if tot > 0 then
					prog = string.format("%.2f %%", cur / tot * 100.0)
				end
				job.raw = string.format("read: %s, total: %s %s",
					cat9.bytestr(cur), cat9.bytestr(tot), prog)
				cat9.flag_dirty()
			end

			return alive
		end
	)
	return
end

local function deploy_copy(cat9, root, job)
-- once committed - this is not directly cancellable (currently) without
-- explicitly closing the job src/dst inputs
	if type(job.src) == "userdata" and type(job.dst) == "userdata" then
		return copy_ud_ud(cat9, root, job)
	end

-- simpler, but we have to poll for progress if we want it via some
-- clock timer hooking tick
	if type(job.src) == "table" and type(job.dst) == "userdata" then
		return copy_tbl_ud(cat9, root, job)
	end

-- just a raw data copy
	if type(job.src) == "table" and not job.dst then
		copy_tbl(cat9, root, job)
	end
end

return
function(cat9, root, builtins, suggest)

local function set_clipboard(src)
	if type(src) == "string" then
		root:to_clipboard(src)
	elseif type(src) == "table" then
		root:to_clipboard(table.concat(src, ""))
	else
		cat9.add_message("EIMPL: clipboard binary / file sources")
	end
end

--
-- many possible combinations for this, hence the complexity.
-- src [popts] dst [popts]
--
-- with src or dst referring to :
-- a job(+ range or stream), a clipboard entry, a binary stream,
-- request for picking or a file.
--
-- practically all of these take different paths, different error handling etc.
--
function builtins.copy(src, opt1, opt2, opt3)
	local dst
	local srcarg
	local dstarg
	local srclbl, dstlbl

--
-- the possibles are:
-- src [popts] [dst] [popts]
--
	if type(opt1) == "table" and opt1.parg then
		dst = opt2
		srcarg = opt1
		dstarg = opt3
	else
		dst = opt1
		dstarg = opt2
	end

	local pick_pending_in, pick_pending_out
	local copy_opt = "p"

-- the special here is if we should hook and continue streaming (i.e. no bgcopy) or just
-- copy what is collected at the moment, popts are needed to distinguish the two.
	if type(src) == "table" then
		if src.parg then
			cat9.add_message("copy: >src< [opt] dst [opt] - expected job, string or stream for src")
			return
		end

-- get the active data-set, raw versus processed is a thing to consider here - strip
-- escape sequences or not as an example. srcargs (popt) could be used to this effect
		srclbl = "(job: " .. tostring(src.id) .. ")"
		src = src:slice(srcarg)

-- interesting popt: view (err, std), line-ranges, relative lines, keep-on-success
	elseif type(src) == "string" then
		if string.sub(src, 1, 5) == "pick:" then
			local idstr = string.sub(src, 6)
			if #idstr == 0 then
				idstr = "*"
			end
			pick_pending_in = idstr
		else
			srclbl = "file:" .. src
			src = root:fopen(src, "r")

			if not src then
				cat9.add_message("copy: >src< ... - couldn't open " .. srclbl .. " for input")
				return
			end
		end

-- any sort of incoming file stream (bchunk, ...) that might've resolved earlier with $..
-- we don't have a way of tagging the nbio right now, which might be needed.
	elseif type(src) == "userdata" then
		srclbl = "(ext-io)"
	else
		cat9.add_message("copy >src< dst : unknown source type")
	end

	if type(dst) == "table" then
		if dst.inp then
			copy_opt = copy_opt .. "w"
			dst = dst.inp
		else
		end
		dstlbl = "(job)"

	elseif type(dst) == "string" then
		if string.sub(dst, 1, 10) == "clipboard:" then
			set_clipboard(src)
			return

		elseif string.sub(dst, 1, 5) == "pick:" then
			if pick_pending_in then
				cat9.add_message("copy src(pick) dst(pick) : only src or dst can be a pick target")
				return
			end
			local idstr = string.sub(dst, 6)
			if #idstr == 0 then
				idstr = "*"
			end
			pick_pending_out = idstr
		else
			dstlbl = "file: " .. dst
			dst = root:fopen(dst, "w")
-- ignore closing src, GC will do the deed if needed
			if not dst then
				cat9.add_message("copy: src >dst< - couldn't open " .. dstlbl .. " for output")
				return
			end
		end
	elseif type(dst) == "userdata" then
		dstlbl = "(ext-io)"

	elseif type(dst) == "nil" then
		dstlbl = ""
-- just a raw data copy
	else
		cat9.add_message("copy src >dst< : unknown destination type ( " .. type(dst) .. " )")
		return
	end

	local job =
	{
		src = src,
		dst = dst,
		flags = copy_opt,
		check_status = function() return true; end
	}
	local destroy_hook

	if pick_pending_in then
		if type(cat9.resources.bin) == "function" then
			cat9.add_message("picking rejected, already queued")
			return
		elseif type(cat9.resources.bin) == "table" then
			job.src = cat9.resources.bin[2]
			job.short = "copy: [preknown-io] -> " .. dstlbl
			job.raw = job.short
			cat9.resources.bin = nil
			cat9.import_job(job)
			deploy_copy(cat9, root, job)
		else
			job.short = "copy: [waiting for pick] -> " .. dstlbl
			job.raw = job.short
			local hnd =
			function(id, blob)
				job.short = string.format("copy: [picked:%s] -> %s", id, dstlbl)
				job.src = blob
				job.raw = job.short
				cat9.resources.bin = nil
				deploy_copy(cat9, root, job)
			end
-- track and hook like this so forgetting the job won't leave us stalled on picking
			cat9.resources.bin = hnd
			destroy_hook =
				function()
					if cat9.resources.bin == hnd then
						cat9.resources.bin = nil
					end
				end
		end
-- create placeholder job, mark that we are waiting so that gets added to the bchunk hnd,
-- something needs to be done if the job gets forgotten while we are waiting for the pick
-- (reset whatever resources[key] that was used at least).
		root:request_io(pick_pending_in, pick_pending_out)
		cat9.import_job(job)
		if destroy_hook then
			table.insert(job.hooks.on_destroy, destroy_hook)
		end

	elseif pick_pending_out then
		if type(cat9.resources.bout) == "function" then
			cat9.add_message("picking rejected, already queued")
			return
-- already got something, consume that slot
		elseif type(cat9.resources.bout) == "table" then
			job.dst = cat9.resources.bout[2]
			job.short = "copy: " .. srclbl .. " -> [preknown-io] "
			job.raw = job.short
			cat9.resources.bout = nil
			deploy_copy(cat9, root, job)
		else
			job.short = "copy: " .. srclbl .. " -> [waiting for pick] "
			job.raw = job.short
			cat9.resources.bout =
			function(id, blob)
				job.short = string.format("copy: %s -> [picked]", dstlbl)
				job.raw = job.short
				job.dst = blob
				cat9.resources.bout = nil
				deploy_copy(cat9, root, job)
			end
		end

-- same as for pick_pending_in above
		root:request_io(pick_pending_in, pick_pending_out)
		cat9.import_job(job)
	else
		job.short = "copy: " .. srclbl .. " -> " .. dstlbl
		job.raw = job.short

-- is there a use for re-adding the construction string and a ["repeat"] handler?
-- currently ignored
		cat9.import_job(job)
		deploy_copy(cat9, root, job)
	end
end

local function suggest_for_src(args, raw)
	local set = {}
	local ch = string.sub(args[2], 1, 1)

	if ch and (ch == "." or ch == "/") then
		local argv, prefix, flt, offset =
			cat9.file_completion(args[2], cat9.config.glob.file_argv)
		local cookie = "copy " .. tostring(cat9.idcounter)
		cat9.filedir_oracle(argv, prefix, flt, offset, cookie,
			function(set)
				if flt then
					set = cat9.prefix_filter(set, flt, offset)
				end
				cat9.readline:suggest(set, "word", prefix)
			end
		)
		return
	end

	table.insert(set, "pick:")
	table.insert(set, "./")
	table.insert(set, "/")

	for _,v in ipairs(lash.jobs) do
		if not v.hidden then
			table.insert(set, "#" .. tostring(v.id))
		end
	end

	cat9.readline:suggest(cat9.prefix_filter(set, args[2]), "word")
	return
end

local function parg_count(args)
	local count = 0
	for _, v in ipairs(args) do
		if type(v) == "table" and v.parg then
			count = count + 1
		end
	end
	return count
end

function suggest.copy(args, raw)

-- wait while we are in ( state, further validation here would
-- be to ensure that only numbers and ranges are applied
	if args.in_lpar then
		return
	end

	if #args - parg_count(args) > 3 then
		cat9.add_message("copy src dst >...< - too many arguments")
		return
	end

-- first src
	if #args == 2 then
		if type(args[2]) == "string" then
			suggest_for_src(args, raw)
		end
		return
	end

-- just finished an lpar, so the next will have to be dst,
-- where basically everything is a candidate.
	if #args == 3 and type(args[3]) == "table" and args[3].parg then
		return
	end

-- now dst
	local carg = args[#args]
	if type(carg) ~= "string" then
		return
	end

	local ch = string.sub(carg, 1, 1)
	if ch and (ch == "." or ch == "/") then
		local argv, prefix, flt, offset =
			cat9.file_completion(carg, cat9.config.glob.file_argv)
		local cookie = "copy " .. tostring(cat9.idcounter)
		cat9.filedir_oracle(argv, prefix, flt, offset, cookie,
			function(set)
				if flt then
					set = cat9.prefix_filter(set, flt, offset)
				end
				cat9.readline:suggest(set, "word", prefix)
			end
		)
		return
	end

	local set =
	{
		".",
		"/",
		"pick:",
		"clipboard:",
	}
	cat9.add_job_suggestions(set, false)
	cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
end
end
