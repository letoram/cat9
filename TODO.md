TODO (planned)
p : partial / in progress

CLI help:
- [p] lastmsg queue rather than one-slot for important bits
- [ ] actual helper for keybindings (longpress on ctrl..):
      c+l = reset, d = cancel or delete word, t = swap prev.
			b - left, f = right, k = cut to eol, u = cut to sol, p step hist b
			n - step hist f, a home, e eol, w delete last word, tab completion
  - [ ] show current aliases and custom bindings
- [ ] add suggest-hints to more commands, let config control verbosity

Data Processing:
- [p] Pipelined  | implementation
- [p] Sequenced (a ; b ; c)
- [p] Conditionally sequenced (a && b && c)
- [ ] Pipeline with MiM
- [p] Copy command (job to clip, to file, to ..)
- [p] runner dynamically swap to pick vm/container/...
- [p] descriptor-to-pseudofile substitution for jobs
      eg. diff #0 #1
- [ ] delayed repeat / flush that traps the data (last-elapsed) and then
      pushes it immediately to cut down on refreshes/updates

Exec:
- [p] Open (media, handover exec to afsrv_decode)
  - [ ] .desktop like support for open, scanner for bin folders etc.
  - [ ] -> autodetect arcan appl (lwa)
  - [ ]   -> state scratch folder (tar for state store/restore) + use with browser
	- [ ] -> autodetect qemu use
- [ ] arcan-net integration (scan, ...)
- [ ] env control
  - [ ] as parg (env k1=v1, env k2=v2, ...) cmd1 | cmd2
	- [ ] as context #0 cmd1 | #1 cmd2
- [ ] view filter
  - [ ] sort options (rising, falling, fuzzy, random, ...)
	- [ ] external filter
	- [ ] coroutine processing
- [p] data dependent expand print (view #0 ...)
		- [p] simplified 'in house' vt100
		- [p] pattern match

Builtins-Network:
- [p] Basic wifi bringup (wpa based)
- [ ] Wired
- [ ] VPN
- [ ] Routing
- [ ] Monitors (dhcp, arp, ...)
- [ ] Bluetooth controls via gatt-client (build without shitbus)
- [ ] Some wrapper for blueZ

Builtins-Misc:
- [ ] Debugger
- [ ] QEmu
- [ ] Android/Adb
- [ ] Devtools (git, make, cmake, ...)
- [ ] Distribution specific (void, BSDs..)
- [ ] Durden/Acfgfs (monitor and paths..)

List:
- [x] wrap ls
- [x] check for inotifytools or similar kqueue options
- [x] apply to ls directory
- [x] refresh on changes (with queue + invalidate)
- [ ] register trigger (on-change, ...)
- [ ] keyboard input
- [ ] set actions

Ui:
- [ ] job history scroll
- [ ] embed input routing
- [p] persistence
  - [ ] history
	- [ ] alias / favorites
	- [ ] env
	- [ ] contents
- [ ] keybindings (config =bind symname cmd)
- [ ] per command history
- [ ] mouse select in buffer
- [ ] mouse controls per view
- [p] drag and drop
- [ ] tray integration
- [p] readline suggestions " escaping
- [ ] on builtin validation error, set highlight offset and cursor
- [ ] live-update #0:
      repeat #0 live
			#0 as active context (prompt option)
			cd futurama -- would first execute in the context of #0
			then repeat #0 flush
