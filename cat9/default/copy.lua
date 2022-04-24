local function deploy_copy(cat9, root, job)
-- combinations going in
--
-- src: userdata | table
-- dst: userdata | table
--
-- once committed - this is not directly cancellable (currently) without
-- explicitly closing the job src/dst inputs
--
	if type(job.src) == "userdata" and type(job.dst) == "userdata" then
		local progio = root:bgcopy(job.src, job.dst, job.flags)
		if not progio then
			cat9.add_message("copy {...} - copy job rejected (resource exhaustion)")
			return
		end

		local acc = 0
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
					job.view = job.err_buffer

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

-- simpler, but we have to poll for progress if we want it via some
-- clock timer hooking tick
	if type(job.src) == "table" and type(job.dst) == "userdata" then
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
			end
		)
	end
end

return
function(cat9, root, builtins, suggest)

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
-- src [popts] dst [popts]
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
		srclbl = "(job: " .. tostring(src.id) .. ")"
-- for the time being just assume it's the data..
		src = src.data

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

	elseif type(dst) == "string" then
		if string.sub(dst, 1, 5) == "pick:" then
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
-- same as before, userdata assumed to come from nbio and that's the type we
-- should have dst to so that's fine
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

	if pick_pending_in then
		if type(cat9.resources.bin) == "function" then
			cat9.add_message("picking rejected, already queued")
			return
		elseif type(cat9.resources.bin) == "table" then
			job.src = cat9.resource.bin[2]
			job.short = "copy: [preknown-io] -> " .. dstlbl
			job.raw = job.short
			cat9.resource.bin = nil
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
			cat9.resource.bin = hnd
			table.insert(job.on_destroy,
			function()
				if cat9.resource.bin == hnd then
					cat9.resource.bin = nil
				end
			end)
		end
-- create placeholder job, mark that we are waiting so that gets added to the bchunk hnd,
-- something needs to be done if the job gets forgotten while we are waiting for the pick
-- (reset whatever resources[key] that was used at least).
		root:request_io(pick_pending_in, pick_pending_out)
		cat9.import_job(job)

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

function suggest.copy(args, raw)
	if #args > 3 then
		cat9.add_message("copy src dst >...< - too nay arguments")
		return
	end

	if #args == 2 and type(args[2]) == "string" then
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

end
end
