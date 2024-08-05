return
function(cat9, root, builtins, suggest, views)

-- ongoing:
--
-- biggest valuable change here would be to modify the merge-set view to only
-- process the visible parts of the set and to adjust the linenumber
-- (job.lineno_offset) as the current cache is just a quick mitigation,
-- currently it builds the complete one which can and will get huge.
--
local errors = {
	not_container = "contain >job< ... referenced job is not a container",
	expected_new = "contain >arg< unknown action, expected: new",
	expected_job = "contain add job1 job2 .. %i is not a valid job reference",
	missing_argument = "contain: missing arguments",
	missing_container = "contain: no active container",
	no_parg = "contain (...) doesn't accept any parsing arguments",
	bad_command = "contain [job] >cmd< unknown command",
	hook_handler = "contain [job] capture: there is already an active capture",
	numarg = "contain [job] %s n1 n2 ..: expected valid capture index"
}

builtins.hint["contain"] = "Manage job containers"

-- state import/export would need to recurse into all jobs supporting it
-- and spawn / create accordingly

local cmds = {}

local function ensure_numarg(job, args, resolve)
	local set = {}

	for _, v in ipairs(args) do
		if type(v) == "table" then
			return false, errors.numarg
		end
		local num = tonumber(v)
		if num == nil or not job.jobs[num] then
			return false, errors.numarg
		end

		table.insert(set, resolve and job.jobs[num] or num)
	end

	return set
end

local function remove_index(set, i)

	for j=#set,1,-1 do
		if set[j] < i then
			break
		elseif set[j] == i then
			table.remove(set, j)
			break
		else
			set[j] = set[j] - 1
		end
	end

end

local function in_set(container, job)
	if not container.active_set then
		return
	end

	for i, _ in ipairs(job.active_set) do
		if job == i then
			return true
		end
	end
end

local function job_for_i(job, i)
	local count = 0
	for _,v in ipairs(job.jobs) do
		if i < count + v.data.linecount then
			return v, count
	end
		count = count + v.data.linecount
	end
end

local function in_set(set, i)
	if set then
		for j=1,#set do
			if set[j] == i then
				return true
			end
		end
	else
	end
end

local function run_hook(job, a, ...)
	local set = cat9.table_copy_shallow(job.hooks[a])
	for _,v in ipairs(set) do
		v(...)
	end
end

local function cont_timer(job)
	if not job.in_container then
		return
	end

	local running = 0
	for i,v in ipairs(job.jobs) do
		if v.pid then
			running = running + 1
		end
	end

	if running > 0 then
		job.container_running = running
	else
-- the regular processing for a job already runs its hooks so we only need for
-- the container itself, only trigger finish if all ok
		if job.container_running ~= running then
			job.container_running = 0
			local ok = true

			for i,v in ipairs(job.jobs) do
				if v.exit and v.exit ~= 0 then
					ok = false
					break
				end
			end

			if ok then
				run_hook(job, "on_finish")
			else
				run_hook(job, "on_fail")
			end
		end
	end

-- rearm the timer
	return true
end

local function mouse_cont(job, btn, ofs, yofs, mods)
	local line_no_click = job.mouse and job.mouse.on_col == 1

	if y_ofs == 0 or (job.active_set and line_no_click) then
		return
	end

-- need to wrap selectedjob and root for responses to route correctly
-- with csel, crow
	local aj = (job.active_set and #job.active_set == 1) and job.jobs[job.active_set[1]] or nil
	if aj and aj.handlers.mouse_button then
		local oldroot = aj.root
		aj.root = job.root
		cat9.selectedjob = aj
		local rv = aj.handlers.mouse_button(aj, btn, ofs, yofs, mods)
		cat9.selectedjob = job
		aj.root = oldroot
		return rv
	end
end

local function container_changed(job)
	if #job.jobs > 0 then
		local hdr_attr = {fc = tui.colors.highlight, bc = tui.colors.highlight}
		local sel_attr = {fc = tui.colors.text, bc = tui.colors.ref_red}
		job.selected_bar = {
			{"Status"},
			m1 = {
				string.format("#%d contain #%d show", job.id, job.id)
			},
			m2 = {
				""
			}
		}
		for i=1,#job.jobs do
			table.insert(job.selected_bar, {
				in_set(job.active_set, i) and sel_attr or hdr_attr,
				tostring(i),
				hdr_attr
			})
			table.insert(job.selected_bar.m1,
				tostring(string.format("#%d contain #%d show %d", job.id, job.id, i)))
			table.insert(job.selected_bar.m2,
				tostring(string.format("#%d contain #%d show flip %d", job.id, job.id, i)))
		end
	else
		job.selected_bar = nil
	end

	job.container_cache = nil
	job.show_line_number = job.active_set ~= nil
	cat9.flag_dirty(job)
end

local function valid_contain_candidate(v)
	if v.jobs or v.hidden then
		return false
	end
	return true
end

local function add_job(container, job)
	if not valid_contain_candidate(job) then
		return
	end

	cat9.activevisible = cat9.activevisible - 1
	job.hidden = true
	job.old_protected = job.protected -- save so we can restore on release
	job.protected = true

	if cat9.latestjob == job then
		cat9.latestjob = container
	end

	if job.pid then
		container.container_running = container.container_running + 1
	end

	table.insert(container.jobs, job)
	container_changed(container)
end

function cmds.release(job, args)
	local args, msg = ensure_numarg(job, args, true)
	if not args then
		return false, string.format(msg, "release")
	end

	for i=#job.jobs,1,-1 do
		for _,v in ipairs(args) do
			if v == job.jobs[i] then

				if job.active_set then
					remove_index(job.active_set, i)
				end

				local ent = table.remove(job.jobs, i)
				ent.hidden = false
				cat9.activevisible = cat9.activevisible + 1
				break
			end
		end
	end

	container_changed(job)
end

function cmds.forget(job, args)
	local args, msg = ensure_numarg(job, args, true)
	if not args then
		return false, string.format(msg, "forget")
	end

-- behave as release + calling forget
	for i=#job.jobs,1,-1 do
		for _,v in ipairs(args) do
			if v == job.jobs[i] then
				if job.active_set then
					remove_index(job.active_set, i)
				end

				local job = table.remove(job.jobs, i)
				job.hidden = false
				job.protected = false
				cat9.parse_string(string.format("forget #%d", job.id))
				break
			end
		end
	end
end

function cmds.capture(hookjob, args)
	if hookjob.in_capture then
		cat9.hook_import_job()
		hookjob.short = "Contain"
		hookjob.in_capture = false
		return
	end

	if cat9.import_hook then
		return false, errors.hook_handler
	end

	local job_capture =
	function(job)
		if not job then
			return
		end

-- don't want to capture background jobs or ones with a different root or
		if job.hidden or job.root ~= root then
			return
		end

		add_job(hookjob, job)
	end

	hookjob.short = "Contain (Capturing)"
	hookjob.in_capture = true
	cat9.hook_import_job(job_capture)
end

function cmds.add(job, args)
	for i,v in ipairs(args) do
		if type(v) ~= "table" or v.parg then
			return false, string.format(errors.expected_job, i)
		end
	end

-- tracking history for latestjob and switching back to that would likely
-- just yield the contain capture and make deletion of it more harmful
	if cat9.latestjob == job then
		cat9.latestjob = nil
	end

	for i,v in ipairs(args) do
		add_job(job, v)
	end
end

function cmds.show(job, args)
	local flip = false
	local set = {}

	local toggle
	if type(args[1]) == "string" and args[1] == "flip" then
		set = job.active_set and job.active_set or {}
		flip = args[1] == "flip"
		table.remove(args, 1)
	end

	local args, msg = ensure_numarg(job, args)
	if not args then
		return false, string.format(msg, "set")
	end

	if #args == 0 then
		job.active_set = nil
		container_changed(job)
		return
	end

	local in_set = function(val)
		for i,v in ipairs(set) do
			if v == val then
				return i
			end
		end
	end

	for _,v in ipairs(args) do
		local ind = in_set(v)
		if ind and flip then
			table.remove(set, ind)
		elseif not ind then
			table.insert(set, v)
		end
	end

	if #set == 0 then
		job.active_set = nil
	else
		job.active_set = set
	end

	container_changed(job)
	cat9.flag_dirty(job)
end

local function write_cont(job, x, y, row, set, ind, col, selected, cols)
	local fmt

-- We would never actually arrive here with an active set as the chaining
-- would call fmt_job with the job of the child which in turn would get
-- the override.
	if not job.active_set then
		local ent = set.jobs[ind]
		if ent.pid then
			fmt = cat9.config.styles.data
		elseif ent.exit then
			if ent.exit == 0 then
				fmt = cat9.config.styles.ok_line
			else
				fmt = cat9.config.styles.error_line
			end
		end
	elseif #job.active_set == 1 then
		local cj = job.jobs[job.active_set[1]]
		if cj.write_override then
			cj:write_override(x, y, row, set, ind, col, selected, cols)
			return
		end
-- we shouldn't be getting here with active_set == 1 as that chains into
-- view() which would then call the regular handler which, in turn, calls
-- into override on the right job.
	end
	job.root:write_to(x, y, row, fmt)
end

local function get_merged(job)
	local res = {}

-- the merge set building can be really expensive, so only do when it
-- is needed and cache after building
	local cache = job.container_cache
	if cache then
		for _,v in ipairs(job.active_set) do
			local cj = job.jobs[v]
			if cache.meta[v].bytecount ~= cj.data.bytecount or
				cache.meta[v].linecount ~= cj.data.linecount then
				job.container_cache = nil
			end
		end
	end

	if cache then
		return cache
	end

	res = {
		bytecount = 0,
		linecount = 0,
		meta = {}
	}

-- the better option would be to fetch only the active number of rows, account
-- for row-offset and then adjust line-numbering to match
	local count = 1
	for _,v in ipairs(job.active_set) do
		local cj = job.jobs[v]
		res.meta[v] = {bytecount = cj.data.bytecount, linecount = cj.data.linecount}
		for _, v in ipairs(cj.data) do
			table.insert(res, v)
			res.bytecount = res.bytecount + #v
		end
	end

	res.linecount = #res
	job.container_cache = res

	return res
end

local function view_cont(job, x, y, cols, rows, probe)
	if not job.active_set then
		if probe then
			return #job.jobs
		end

		local set = {linecount = #job.jobs, jobs = {}}
		local bc = 0

		for i,v in ipairs(job.jobs) do
			local pref, sz_pref = cat9.sz_to_human(v.data.bytecount)
			pref = string.format("\tLines: %d\tBytes: %.0f%s\tErrors: %d",
				v.data.linecount, sz_pref, pref, #v.err_buffer)
-- show possible actions on mouse over
-- should have a better shorten than just sub, take cols into account
			local dstr
			if (v.exit or v.pid) then
				local pc = ""
				if v.pid or v.exit then
					pc = tostring(v.pid or v.exit)
				end
				dstr = string.format("%d(%s -> %s):\t", i, string.sub(v.short, 1, 10), pc)
			else
				dstr = string.format("%d(%s):\t", i, v.short)
			end
			table.insert(set, dstr .. pref)
			table.insert(set.jobs, v)
		end

		return cat9.view_fmt_job(job, set, x, y, cols, rows, probe)
	end

-- for single view we could / should just forward to the job itself (if it has
-- an override) or the default fallback. the problem with that is that job bar
-- extensions should then also be added, but we are running out of space and
-- the draw_job_header would then need to be added within the container.
--
-- Since we chain into the view of the child, we also need to swap out its
-- root for our own as we can run detached in a different window as well as
-- synch the mouse to match what is on us.
	if #job.active_set == 1 then
		local cj = job.jobs[job.active_set[1]]
		local old_root = cj.root
		cj.root = job.root
		cj.mouse = job.mouse
		local ret = cj:view(x, y, cols, rows, probe)
		cj.root = old_root
		return ret
	end

-- for merged we build the set from the active ones and then forward
-- to the default view_fmt_job
	if probe then
		local sum = 0
		for _,v in ipairs(job.active_set) do
			sum = sum + job.jobs[v].data.linecount
		end
		return sum
	end

	local set = get_merged(job)
	return cat9.view_fmt_job(job, set, x, y, cols, rows, probe)
end

local function run_on_set(job, method, ...)
	local fail = {}

	if job.active_set then
		for _,v in ipairs(job.active_set) do
			local ci = job.jobs[v]
			if ci[method] then
				ci[method](ci, ...)
			else
				table.insert(fail, tostring(v))
			end
		end
	else
		for i,v in ipairs(job.jobs) do
			if v[method] then
				v[method](v, ...)
			else
				table.insert(fail, tostring(i))
			end
		end
	end

	return fail
end

local function repeat_cont(job, input)
	local fail = run_on_set(job, "repeat", input)

	if #fail > 0 then
		cat9.add_message(
			table.concat(fail, ", ") .. " doesn't support repeating")
	end
end

local function redraw_cont(job, over, selected)
	if job.active_set and #job.active_set == 1 then
		local cj = job.jobs[job.active_set[1]]
		if cj.redraw then
			return cj:redraw(over, selected)
		end
	end
--	job.root:cursor_to(0, job.region[2] + job.cursor[2] + 1)
end

local function reset_cont(job)
	local fail = run_on_set(job, "reset")
	if #fail > 0 then
		cat9.add_message(
			table.concat(fail, ", ") .. " doesn't support resetting")
	end
end

local function slice_cont(job, lines)
	if not job.active_set then
-- might want to return a summary of the bound jobs
		return {linecount = 0, bytecount = 0}
	end

	local res = {}

-- line arguments isn't guaranteed to be linear, there should be a good caching
-- strategy or a range-tree if #jobs gets high enough but that is less of a
-- concern now. We should also recurse the slice down to the individual jobs
-- with modified offsets / destinations.
	return cat9.resolve_lines(job, res, lines,
		function(i)
			if not i then
				if #job.jobs == 1 then
					local job = job.jobs[1]
					return job.data, job.data.linecount, job.data.bytecount
				end
				local set = {bytecount = 0}
				for _,v in ipairs(job.jobs) do
					for _,v in ipairs(v.data) do
						table.insert(set, v)
						set.bytecount = set.bytecount + #v
					end
				end
				set.linecount = #set
				return set, set.linecount, set.bytecount
			else
				local job, new_i = job_for_i(job, i)
				if not job then
					return nil, 0, 0
				else
					return job.data[new_i], 1, #job.data[new_i]
				end
			end
		end
	)
end

function builtins.contain(...)
	local args = {...}

	local container

	if type(args[1]) == "table" then
		if args[1].parg then
			return false, errors.no_parg
		end

		if not args[1].jobs then
			return false, errors.not_container
		end

		container = table.remove(args, 1)
	end

-- no container specified, try to create a new one
	if not container and (args[1] == "capture" or args[1] == "new") then
		if args[1] == "capture" then
			for _, v in ipairs(cat9.activejobs) do
				if v.in_capture then
					return false, errors.hook_handler
				end
			end
		end

		local job = {
			raw = "",
			short = "Contain",
			slice = slice_cont,
			["repeat"] = repeat_cont,
			reset = reset_cont,
			redraw = redraw_cont,
			jobs = {},
			write_override = write_cont,
			check_status = cat9.always_active,
			handlers = {mouse_button = mouse_cont}
		}
		cat9.import_job(job)
		job.reset = reset_cont

-- mark the job as dead for the refresh timer
		table.insert(
			job.hooks.on_destroy,
			function()
				job.in_container = false
				if job.in_capture then
					job.in_capture = false
					cat9.hook_import_job()
				end
			end
		)

-- track completion status based on jobs running
		job.in_container = true
		job.container_running = 0
		table.insert(
			cat9.timers, function()
				return cont_timer(job)
			end
		)

		job:set_view(view_cont, slice_cont, {}, "")
		if args[1] == "new" then
			return
		end
		container = job
	end

	if not container then
		for i=#cat9.activejobs,1,-1 do
			if cat9.activejobs[i].jobs then
				container = cat9.activejobs[i]
				break
			end
		end
	end

	if not container then
		return false, errors.missing_container
	end

	if not cmds[args[1]] then
		return false, errors.bad_command
	end

	return cmds[table.remove(args, 1)](container, args)
end

function suggest.contain(args, raw)
	if #args <= 2 and #raw <= 6 then
		return
	end

	local in_capture = false
	for _,v in ipairs(lash.jobs) do
		if v.jobs and v.in_capture then
			in_capture = true
			break
		end
	end

	if #args == 2 then
		local set = {
			title = "contain action",
			"new",
			hint = {
				capture = "Spawn a container capturing new jobs",
				new = "Create a new container"
			}
		}
		cat9.add_job_suggestions(set, false,
		function(v)
			return v.jobs ~= nil
		end)

		if not in_capture then
			table.insert(set, 2, "capture")
		end

		cat9.readline:suggest(cat9.prefix_filter(set, args[2]), "word")
		return true
	end

	if type(args[2]) ~= "table" or not args[2].jobs then
		cat9.add_message("capture >job< .. is not a valid capture job reference")
		return false, 7
	end

	local set = {
		title = "container command",
		hint = {
			add = "Attach a job",
			release = "Release an attached job",
			show = "Change the visible active set of attached jobs",
			forget = "Forget an attached job"
		}
	}

	if not args[4] then
		if #args[2].jobs > 0 then
			table.insert(set, "release")
			table.insert(set, "show")
			table.insert(set, "forget")
		end

		if args[2].in_capture then
			table.insert(set, "capture")
			set.hint.capture = "Disable capturing"
		end

		if not in_capture then
			table.insert(set, "capture")
			set.hint.capture = "Start cpturing"
		end

		local valid_jobs
		for _,v in ipairs(lash.jobs) do
			if not v.hidden and not v.jobs then
				valid_jobs = true
				break
			end
		end

		if valid_jobs then
			table.insert(set, "add")
		end

		cat9.readline:suggest(cat9.prefix_filter(set, args[3]), "word")
		return true
	end

-- add command should only show possible jobs and ignore duplicates
	if args[3] == "add" then
		local known = {}

		if #args >= 5 then
			for i=4,#args-1 do
				if type(args[i]) ~= "table" or args[i].parg then
					cat9.add_message("contain #cjob add .. only accepts #jobs")
					return false
				end
				known[args[i].id] = true
			end
		end

		local set = {
			title = "#job to contain",
			hint = {}
		}

		for i=1,#lash.jobs do
			local job = lash.jobs[i]
			if not known[job.id] and not job.hidden and not job.jobs then
				table.insert(set, "#" .. tostring(job.id))
				table.insert(set.hint, job.short or "")
			end
		end

		cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
		return true
	end

	if #args[2].jobs == 0 then
		cat9.add_message(raw .. " container is empty")
		return false
	end

	if args[3] ~= "release" and args[3] ~= "show" and args[3] ~= "forget" then
		cat9.add_message("contain #job >cmd< ... unknown command")
		return false
	end

	local set = {
		title = "contained ID to " .. args[3],
		hint = {}
	}

	local known = {}
	if #args >= 5 then
		for i=4,#args-1 do
			known[args[i]] = true
		end
	end

	for i=1,#args[2].jobs do
		if not known[tostring(i)] then
			table.insert(set, tostring(i))
			table.insert(set.hint, args[2].jobs[i].short or "")
		end
	end

	cat9.readline:suggest(cat9.prefix_filter(set, args[#args]), "word")
end
end
