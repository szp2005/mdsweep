# Record the README demo.
# Rebuild the sample repo first so the grades match this GIF:
#   sh docs/demo/setup.sh
# Visible commands, in order: scan, quarantine dry-run, quarantine --apply,
# then undo from inside the fixture.

Output docs/demo.gif

Require node

Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 15
Set Width 960
Set Height 400
Set Padding 12
Set Framerate 10
Set TypingSpeed 18ms
Set Theme "Catppuccin Mocha"

Hide
Type "export PS1='$ '"
Enter
Type "clear"
Enter
Show

Type "node bin/mdsweep.mjs scan docs/demo/fixture"
Enter
Sleep 3s

Type "node bin/mdsweep.mjs quarantine docs/demo/fixture"
Enter
Sleep 2.4s

Type "node bin/mdsweep.mjs quarantine docs/demo/fixture --apply"
Enter
Sleep 2.6s

Type "cd docs/demo/fixture"
Enter
Sleep 400ms

Type "node ../../../bin/mdsweep.mjs undo"
Enter
Sleep 2.2s
