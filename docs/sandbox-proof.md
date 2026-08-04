## Reclaiming the workspace

A Shep workspace — whether a local git worktree or a Vercel sandbox — is
reclaimed only when it holds nothing that is not already on a remote: no live
task owns it, its tree is clean, and its HEAD is contained in some remote
branch. That decision is made from git alone, not from an issue label. A label
records only what a tracker believes about the work, whereas git can prove that
no unpushed commit or uncommitted edit would be lost, so deciding from git is
the safer rule.
