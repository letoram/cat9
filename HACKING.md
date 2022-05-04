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

Views
=====
To the set of builtins, views can also be added. These are data visualisers that
implement anything above just basic "draw the lastest few entires of data". Adding
a view is just like adding a builtin, with the suggestion that a subdirectory to
the command-set is used:

    default.lua:
		   ...
			 "views/wrap.lua"

and in cat9/default/views/wrap.lua:

    return
		function(cat9, root, builtins, suggest, view)
		    function view.wrap(job, x, y, cols, rows, hidden)
				    return rows
				end
		end

and should return the number of rows consumed to present job.data according to
the view. The builtin 'view' command will then enumerate the set of known views
and let the user toggle between them accordingly.

The corresponding view function will then be called each time the view is to be
drawn, and whenever it is marked as hidden. The function is still expected to
return the number of rows presenting the dataset would consume, in order for
decorations like scrollbars to be accurate.

Job
===
The main data container is that of the job. It is being passed around everywhere
and partially inherited from lash itself should the usershell be swapped out.
The main fields of use in it are:

    collapsed_rows, num : number of rows to show in collapsed form
		line_offset, num : for scrolling
		unbuffered, bool : true if bytes just accumulate
		err_buffer, strtbl : accumulates error output lines
		data, strtbl : n-indices for data as it arrives
		closure, tbl : used to track / chain completion event handlers (internal)
		view, tbl : points to the current active source buffer
		dir, str: working directory
		id, num: numeric id
		hidden, bool: set for background jobs
		short, str: minimal title 'string'

The methods that might be invoked:

    reset() : restore to a clean state

If it is tied to an external living process, the 'pid' field is set
and that is changed to code when the process terminates.

The handlers subtable is used for attaching hooks in other parts:

    on_destroy
		on_finish(ok or errc)
		on_data(line, buffered, eof)

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
