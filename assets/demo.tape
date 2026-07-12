# Live demo recording: issue in, PR out, split screen.
# Left pane: the Shep daemon log. Right pane: the human.
# Regenerate with: vhs assets/demo.tape
# Prereqs: labels created, WORKFLOW.md pointed at this repo with the
# stub agent (see priv/demo/), daemon down, no open shep issues/PRs.
# The daemon pushes over https (SSH agents do not reach nohup daemons):
#   gh auth setup-git
#   git config url."https://github.com/<you>/".insteadOf "git@github.com:<you>/"

Output assets/demo.gif

Set Shell "zsh"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 14
Set Width 1200
Set Height 680
Set Padding 14
Set Margin 16
Set MarginFill "#1e1e2e"
Set BorderRadius 10
Set WindowBar Colorful
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

Hide
Type "tmux kill-session -t rec 2>/dev/null; tmux new-session -d -s rec 'just shep up && exec tail -f .shep/orchestrator.log' \; split-window -h \; attach"
Enter
Sleep 5s
Show

Sleep 1.5s
Type "gh issue create --title 'Add a friendly greeting to PASTURE.md' --body 'Add a greeting line.' --label shep"
Sleep 500ms
Enter
Sleep 11s
Type "gh issue list"
Sleep 300ms
Enter
Sleep 10s
Type "gh pr list"
Sleep 300ms
Enter
Sleep 6s
