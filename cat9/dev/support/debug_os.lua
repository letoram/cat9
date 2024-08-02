return function(cat9, root)
local os_support = {}

function os_support.files(pid, closure)
-- for linux it is proc/pid/fds and listing or resolve
-- for openBSD it is fstat -p
	local list = {}

	cat9.add_fglob_job(nil,
		string.format("/proc/%d/fd", pid),
		function(line)
			if not line then
				closure(list)
				return
			end
			if line == "." or line == ".." then
				return
			end

			local path = string.format("/proc/%d/fd/%s", pid, line)
			local ok, kind, meta = root:fstatus(path)

			if meta.link then
				table.insert(list, meta.link)
			end
		end
	)
end

function os_support.maps(pid, closure)
-- for linux it is parsing proc/pid/maps
	local path = string.format("/proc/%d/maps", pid)
	local mapf = root:fopen(path)

	local set = {}
	while true do
		line = mapf:read(false)
		if not line then
			break
		end
		local fields = string.split(line, "%s+")
		local addr = string.split(fields[1], "-")
		local ent =
		{
			perm   = fields[2],
			ofs    = fields[3], -- only makes sense for mmap
			dnode  = fields[4], -- major:minor
			inode  = fields[5],
			file   = fields[6]
		}
		ent.base = addr[1]
		ent.endptr = addr[2]

		table.insert(set, ent)
	end

	set.linecount = #set
	set.bytecount = 0
	closure(set)
-- for openBSD it is procmap
end

function os_support.can_attach()
-- Probe for means that would block ptrace(pid), for linux that is ptrace_scope
-- this should latch into an 'explain' option with more detailed information
-- about what can be done.
--
-- Another option would be to permit builtin [name] [uid] to pick a prefix
-- runner in order to doas / sudo to run commands.
--
	local attach_block = false
	local ro = root:fopen("/proc/sys/kernel/yama/ptrace_scope", "r")
	if ro then
		ro:lf_strip(true)
		local state, _ = ro:read()
		state = tonumber(state)
		if state ~= nil then
			if state ~= 0 then
				attach_block = true
			end
		end

		ro:close()
	else
-- for openBSD this would be kern.global_ptrace
	end

	return attach_block
end

return os_support
end
