# 0.1
* handover windows from ! prefix now keep\_alive until WM closes
* latest-job / latest\_job state confusion (@cipharius)
* factory background- job spawning to helper
* builtins now has an overlay set and some commands moved to system
* list builtin added
* wm integration modes have added 'swallow' (s!)
* builtins now have split config files (config/setname.lua)
* json parser helper included in base
* modifier key is now configurable
* added support for chorded inputs
* added 'stash' command for building a set of paths to apply actions to
* drag and drop / file picker actions will now attach to stash if possible
* started migrating 'find' and 'ls' parsing to proper shell based glob for safe 'bad' file name handling
* started adding F1 toggle one-line helpers for command explanation
* started the 'dev' set of builtins with 'scm monitor' as first command for showing repository status of current directory
* added the 'each' builtin for repeating a command, e.g. each #0 !! open new $arg
* added view #job detach as a way of splitting out a view into its own
* added config option for `job_bar_pad` for drawing job bar padded to the entire assigned colrange
* added 'dev' builtin with 'debug' command for debug-adapter-protocol integration
