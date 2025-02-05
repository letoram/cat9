return
function(cat9, root, builtins, suggest, _, builtin_cfg)

local cmds = {}

local function spawn_monitor()
	local job = {
		timeline = {},
		raw = "Social:Monitor",
		short = "Social:Monitor",
		sources = {}
	}

	cat9.import_job(job)
	cat9.social_monitor = job
end

builtins.hint.monitor = "Create a job tracking social flows"

local monitor

function builtins.monitor()
	if not cat9.social_monitor then
		spawn_monitor()
	else
		return false, errors.got_monitor
	end
end

end
