local commands =
{
	'cd.lua',
	'config.lua',
	'copy.lua',
	'forget.lua',
	'open.lua',
	'term.lua',
	'signal.lua',
	'view.lua',
	'repeat.lua',
	'env.lua'
}

return
function(cat9, root, builtin, suggest)
	for _,v in ipairs(commands) do
		local fptr, msg = loadfile(lash.scriptdir .. "/cat9/default/" .. v)
		if fptr then
			pcall(fptr(), cat9, root, builtin, suggest)
		end
	end
end
