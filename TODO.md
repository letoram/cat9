TODO (planned)
p : partial / in progress

CLI help:
- [p] lastmsg queue rather than one-slot for important bits
- [x] track most used directories for execution and expose to cd h [set]
- [ ] actual helper for keybindings (longpress on ctrl..):
      c+l = reset, d = cancel or delete word, t = swap prev.
			b - left, f = right, k = cut to eol, u = cut to sol, p step hist b
			n - step hist f, a home, e eol, w delete last word, tab completion,

Data Processing:
- [p] Pipelined  |   implementation
- [p] Sequenced (a ; b ; c)
- [p] Conditionally sequenced (a && b && c)
- [ ] Pipeline with MiM
- [p] Copy command (job to clip, to file, to ..)
- [x] descriptor-to-pseudofile substitution for jobs
      eg. diff #0 #1
- [x] autoprune bad-empty (timer to 0 or ..)

Exec:
- [p] Open (media, handover exec to afsrv_decode)
  - [ ] .desktop like support for open, scanner for bin folders etc.
  - [ ] -> autodetect arcan appl (lwa)
  - [ ]   -> state scratch folder (tar for state store/restore) + use with browser
- [ ] arcan-net integration (scan, ...)
- [ ] env control
  - [ ] as parg (env k1=v1, env k2=v2, ...) cmd1 | cmd2
	- [ ] as context #0 cmd1 | #1 cmd2
- [p] data dependent expand print (view #0 ...)
		- [p] simplified 'in house' vt100
		- [p] pattern match

Ui:
- [x] view #jobid scroll n-step
- [x] view #jobid wrap
- [x] view #jobid unwrap
- [ ] job history scroll
- [x] alias
- [p] multicolumn mode
- [p] persistence
  - [ ] history
	- [ ] alias / favorites
	- [ ] env
	- [ ] contents
- [x] keyboard job selected / stepping (escape out of readline)
- [ ] mouse select in buffer
- [x] line# column in view
