return
function(cat9, root, config)

function cat9.make_editable(job, opts)
-- this takes as inner-view, e.g. wrap or crop.
--
-- we overlay an input and click handler that applies input editing actions
-- and match how vim input takes things.
--
-- the option is a template:
--
--  i.e. unmasked and cursor on it enforces a certain validation
--       or completion set.
--
-- other parts is using an external oracle to get completion data,
-- as well as formatting like syntax highlight
--
	job.key_input =
	function(job, sub, keysym, code, mods)
	end

	job.write =
	function(job, ch)
	end

	job.handlers.mouse_button =
	function(job)
	end
end
end
