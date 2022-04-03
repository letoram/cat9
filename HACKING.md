Organisation
============

    cat9/base - support functions to help with builtins
	  cat9/base/ioh.lua - input event handlers, anything key/mouse goes here
		cat9/base/jobctl.lua - process lifecycle, reading / buffering / writing
		cat9/base/layout.lua - drawing / window management / prompt
		cat9/base/misc.lua - support functions
		cat9/default.lua - loader for standard builtin- functions
		cat9/default/... - builtin functions picked by cat9/default.lua

Builtins
========
To add a new builtin, create a new file in the suitable subfolder, cat9/default
for ones useful at startup - or a complete set:

    echo "return {\"mycmd.lua\"} > cat9/myset.lua
		mkdir cat9/myset
		echo "return function(cat9, root, builtins, suggest)\nend" > cat9/myset/mycmd.lua

modify cat9/myset/mycmd.lua so that the returned function modifies the builtins
and suggest tables provided as arguments to fit the command to provide. It is
advised to keep this clean and have a 1 file to 1 command file system layout.

Other
=====
Lash itself comes with some minor support functions, the one of the most
utility here is:

    lash.tokenize\_command(str) -> tokens, errmsg, errofs, typetable

It operates in either a simplified or a full mode, where the full mode is intended
more for complete expression evaluation (a=1+2/myfun(myfun2(1, "hi", "there"))) style
and the simple mode (used here) masks out some operators and treat them as strings.

Where each member of tokens are [1] : type, [2] : typedata, [3] pos.
See base/parse.lua for more advanced use of it.

The source-code to lash, as well as the documentation on how the Lua bindings for
the tui API works can be found at:

    https://github.com/letoram/tui-bindings

These bindings can also be used to run lash without the afsrv\_terminal chainloader,
which might make it easier to debug lower level problems. Simply build them as you
any other lua bindings, and run the examples/lash.lua script.
