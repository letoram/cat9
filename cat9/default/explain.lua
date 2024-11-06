return
function(cat9, root, builtins, suggest, views)

local errors =
{
	no_parg = "explain >...< (opt) args not permitted",
	no_explain = "explain >job< does not come from explain"
}

local function view_explain(job, x, y, cols, rows, probe)
	if probe then
		return job.data.linecount
	end

	return job.data.linecount
end

local function slice_explain(job, lines)
	local res = {bytecount = 0, linecount = 0}

-- produce a version without the formatting
	return cat9.resolve_lines(
		job, res, lines,
		function(i)
			if not i then
				return res
			end

			return nil, 0, 0
		end
	)
end

local function explain(job, args)
-- derive context and question from 'args' and apply to job

-- if the question is in the history, revert to that, otherwise generate anew

-- support external contexts (through config.explain.external) where we just
-- forward and render the results, if there's a pending one
-- (from monitor as that can be noise) then just cancel it.
--
	local cmdtbl = {
		"/usr/bin/man",
		"-T",
		"ascii",
		"ls"
	}

	cmdtbl = "/bin/sh -c /usr/bin/man -T ascii ls"

	local _, out, _, pid = job.root:popen(cmdtbl, "r")
	cat9.add_background_job(out, pid, {lf_strip = true},
		function(inp, code)
			print("done", code, #job.data, job.data.linecount)
			job.data = inp.data
			cat9.flag_dirty(job)
		end
	)
end

local function toggle_monitor(job)
-- sample active builtin scope and current command-line on a timer to figure
-- out what we should ask for resolution of and in what context of discovery
--
-- default for command-line fallback is just man -> wrap through vt100 decode
-- though with others (e.g. README.md) we might want pandoc -> djot -> other
-- renderer.
	job.timer_fn =
	function()
	end
end

function builtins.explain(...)
	local args = {...}
	local djob

-- separate command on job versus creating a new
	if type(args[1]) == "table" then
		if args[1].parg then
			return false, errors.no_parg
		end

		if not args[1].explain then
			return false, errors.no_explain
		end

		djob = table.remove(args[1])
	else
		djob = {
			raw = "",
			short = "Explain",
		}

		cat9.import_job(djob)
		djob:set_view(view_explain, nil, {}, "")
		djob.explain = {}

-- add extra titlebar controls for pausing / stepping history
	end

-- now just work with string commands
	local base = {}
	local ok, msg = cat9.expand_arg(base, args)

-- passive monitor some source
	if base[1] == "monitor" then
		return toggle_monitor(job)
	else
		return explain(djob, base)
	end
end

function suggest.explain(args, raw)
end

end
