# Development environment conventions

Shared conventions for my development environment. This file is imported by
`~/.claude/CLAUDE.md`, so it applies in every repo.

## Git

- Read-only git commands are always allowed — run them freely without asking:
  `git status`, `git diff`, `git log`, `git show`, `git branch`, `git blame`,
  `git remote -v`, etc.
- Do NOT run git write commands. No `git add`, `git commit`, `git push`,
  `git merge`, `git rebase`, `git checkout` / `git switch`, `git reset`,
  `git stash`, and no branch or tag creation. I run those myself.
- When work is ready to commit, stop and tell me what to stage — suggest a
  commit message if it helps, but leave the command to me.
