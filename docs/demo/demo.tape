# Record the README demo.
# Check out this repo at /home/demo/mdsweep (a neutral path, not the
# machine workspace) and rebuild the sample repo so the grades match:
#   sh docs/demo/setup.sh
# Visible commands, in order: scan, archive dry-run, archive --apply,
# quarantine dry-run, quarantine --apply, then undo twice from inside
# the fixture. The second undo restores the archive batch, because
# undo always puts back the newest quarantine or archive batch.

Output docs/demo.gif

Require node

Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 14
Set Width 960
Set Height 430
Set Padding 12
Set Framerate 10
Set TypingSpeed 12ms
Set Theme "Catppuccin Mocha"

Hide
Type "export PS1='$ '"
Enter
Type "cd /home/demo/mdsweep"
Enter
Type "clear"
Enter
Show

Type "node bin/mdsweep.mjs scan docs/demo/fixture"
Enter
Sleep 1.7s

Type "node bin/mdsweep.mjs archive docs/demo/fixture"
Enter
Sleep 2s

Type "node bin/mdsweep.mjs archive docs/demo/fixture --apply"
Enter
Sleep 1.8s

Type "node bin/mdsweep.mjs quarantine docs/demo/fixture"
Enter
Sleep 1.5s

Type "node bin/mdsweep.mjs quarantine docs/demo/fixture --apply"
Enter
Sleep 1.6s

Type "cd docs/demo/fixture"
Enter
Sleep 250ms

Type "node ../../../bin/mdsweep.mjs undo"
Enter
Sleep 1.3s

Type "node ../../../bin/mdsweep.mjs undo"
Enter
Sleep 1.3s
