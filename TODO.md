TODO (for first release)

Job Control:
- [ ] 'on data' hook (trigger jobid data pattern trigger)
- [ ] 'on finished' hook (trigger jobid ok trigger)
- [ ] 'on failed' hook (trigger jobid errc trigger)

CLI help:
- [p] lastmsg queue rather than one-slot for important bits
- [ ] track most used directories for execution and expose to cd h [set]
- [ ] r for search in word
- [ ] actual helper for keybindings:
      c+l = reset, d = cancel or delete word, t = swap prev.
			b - left, f = right, k = cut to eol, u = cut to sol, p step hist b
			n - step hist f, a home, e eol, w delete last word, tab completion,

Data Processing:
- [ ] Pipelined  |   implementation
- [ ] Sequenced (a ; b ; c)
- [ ] Conditionally sequenced (a && b && c)
- [ ] Pipeline with MiM
- [p] Copy command (job to clip, to file, to ..)

Exec:
- [p] Open (media, handover exec to afsrv_decode)
  - [ ] .desktop like support for open, scanner for bin folders etc.
  - [ ] -> autodetect arcan appl (lwa)
  - [ ]   -> state scratch folder (tar for state store/restore) + use with browser
- [ ] arcan-net integration (scan, ...)
- [ ] env control (env=bla in=#4) action_a | (env=bla2) action_b
      should translate to "take the contents from job 4, map as input
			and run action_a)"

- [ ] data dependent expand print (view #0 ...)
    - [ ] hex
		- [ ] simplified 'in house' vt100
		- [ ] pattern match

Ui:
- [ ] view #jobid scroll n-step
- [ ] view #jobid wrap
- [ ] view #jobid unwrap
- [ ] histogram viewing mode
- [ ] job history scroll
- [ ] alias
- [ ] multicolumn mode (hmm, rowtoid need something)
- [ ] history / alias / config persistence

- [p] format string to job-bar (see stack)
  - [ ] format string to prompt

- [ ] keyboard job selected / stepping (escape out of readline)
- [ ] mouse select in buffer
- [ ] powerline look (U+E0b0)
