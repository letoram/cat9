TODO (for first release)

Job Control:
- [ ] 'on data' hook (trigger jobid data pattern trigger)
- [ ] 'on finished' hook (trigger jobid ok trigger)
- [ ] 'on failed' hook (trigger jobid errc trigger)

CLI help:
- [ ] lastmsg queue rather than one-slot for important bits
- [ ] track most used directories for execution and expose to cd h [set]

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
- [ ] pattern expand from file glob
- [ ] data dependent expand print:
    - [ ] hex
		- [ ] simplified 'in house' vt100

Ui:
- [ ] view #jobid scroll n-step
- [ ] view #jobid wrap
- [ ] view #jobid unwrap
- [ ] histogram viewing mode
- [ ] job history scroll
- [ ] alias
- [ ] history / alias / config persistence
- [ ] format string to prompt
- [ ] format string to job-bar
- [ ] keyboard job selected / stepping (escape out of readline)
