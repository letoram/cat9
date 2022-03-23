return
function(cat9, root, builtins, suggest)

function builtins.copy(src, dst)
-- src addressing modes to consider:
-- #job(lineno,row,out,err)
-- $clipboard
-- $pick("str")

	if type(src) == "table" then

	elseif type(src) == "string" then

-- any sort of incoming file stream
	elseif type(src) == "userdata" then

	else
		cat9.add_message("copy >src< dst : unknown source type")
	end

-- dst addressing modes to consider:
-- #job(in)
	if type(dst) == "table" then

-- this is only ever resolved to file
	elseif type(src) == "userdata" then

	else
		cat9.add_message("copy src >dst. : unknown destination type")
	end

-- #job(l1,l2..l5) [clipboard, #jobid, ./file]
end

end
