# Sandbox proof

This note was written by a Shep agent running inside a Vercel sandbox — the
`shep:sandbox` execution location, an ephemeral remote machine provisioned from
`sandbox.snapshot` and torn down after the run, so an issue can be worked away
from any local git worktree.

Evidence captured inside the sandbox:

- `uname -srm` → `Linux 6.12.76 x86_64`
- `whoami` → `vercel-sandbox`
- `$HOME` → `/home/vercel-sandbox`
- working directory → `/vercel/sandbox/app`
