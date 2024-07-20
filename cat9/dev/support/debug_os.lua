return function(root)
local os_support = {}

function os_support.files(pid)
-- for linux it is proc/pid/fds and listing or resolve
-- for openBSD it is fstat -p
end

function os_support.maps(pid)
-- for linux it is parsing proc/pid/maps
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
