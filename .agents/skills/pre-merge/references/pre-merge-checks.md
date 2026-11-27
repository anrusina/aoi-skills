# Project pre-merge checks (phase 1b)

Run every check the *pre-merge checks* fact lists, in its order, on the
rebased branch, from the worktree, and put each one's result in the phase 5
summary.

A value taken from issue or PR text (a path, a name) goes into a check's
command as an environment variable the command reads, never spliced into the
command itself: issue text is not trusted as shell or make syntax. Put the
value in single quotes, and stop if it holds one:

```bash
TARGET='<value from the issue>' <the check's command, reading $TARGET>
```

## Conditional checks

A check that applies only when the branch touches certain paths (a native
build after a toolchain change, say) runs only when one of them changed:

```bash
git diff --name-only origin/<base>...HEAD
```

Where only some lines of a file count (say, not the version line the bump
writes), look at which lines the branch changed. If nothing on the list is
touched, say so in one line.

## Local suites

Run the command the fact gives. A failure stops the merge, as a gate does.
If a suite reads git-ignored fixtures that live only in the primary
checkout, link each fixture folder the fact names into this worktree first:

```bash
root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
[ -e "<folder>" ] || [ ! -d "$root/<folder>" ] || ln -s "$root/<folder>" "<folder>"
```

If the primary checkout lacks a fixture folder, stop and name it. The merge
waits for a run where the fixtures are, unless the developer says in chat to
merge without them; then record `<suite>: not run (no <folder> on this
machine)` in the PR description and in the summary. Remove each link
(`rm <folder>`, no trailing slash) once the suite has run, or it blocks the
worktree cleanup.

## Checks the developer runs by hand

A workflow started by hand, a test on a device: ask the developer whether it
has passed on this branch, and stop until they confirm.

## Workflows that start by themselves

A workflow that runs on its own when the branch touches certain paths (a
build check on pull requests, say), when one of them changed: after phase
2's push, confirm its run on `<pushed-sha>` passed. Nothing to ask. Wait in
the background where the shell limits long commands:

```bash
gh run list --workflow <workflow file> --commit <pushed-sha> --limit 1 --json databaseId,conclusion
gh run watch <id> --exit-status
```

Only `success` lets the merge go on. Anything else: show the tail of
`gh run view <id> --log-failed` and **stop**. If no run appears within a few
minutes, the push did not start one: stop and ask the developer.

## Version bump

Every merge that changes more than documentation raises the version once
(see below), counted from the version the default
branch holds now, or from the latest release tag's when the *releases* fact
says releases are tagged and that is higher (a hotfix can release a version
the default branch never held).

A documentation-only merge raises nothing: when every changed path is
Markdown or under `docs/`, `.agents/` or `.claude/`, and none is a build
input by the *build-input docs* fact, raise neither the version nor the
build number, and say so in one line.

| Level | When |
|---|---|
| `minor` | the branch name starts `feature-`, or any commit on it is a `feat:` |
| `patch` | anything else: a backward-compatible fix or maintenance |
| `major` | only when the developer asks for it in this run; never inferred |

When the *pre-merge checks* fact gives a rule for the level, it replaces
this table; a developer's ask for `major` in this run still holds. Otherwise
find the commit types with `git log origin/<base>..HEAD --format=%s`. Run the
bump command the fact gives, at that level and counting from
`origin/<base>`, then commit only if a file the bump writes changed (an
untracked fixture link must not count), all in one call:

```bash
<the bump command from the fact, at <level>, from origin/<base>>
if ! git diff --quiet -- <the files the bump writes>; then
  git add -- <the files the bump writes>
  msg=$(mktemp)
  cat > "$msg" <<'MSG_EOF'
[#<issue>] chore: raise the version to <new version>
MSG_EOF
  git commit -q -F "$msg"
  rm -f "$msg"
fi
```

Phase 2 folds this commit into the main issue's concern.

## Other checks that change files

Release notes, a status table: commit them on the branch the same way.

## CI-equivalent run

A workflow that runs the gates on a clean checkout runs on the history
phase 2 pushes, so phase 2 starts it after its push:

1. If every changed path is Markdown, or under `docs/`, `.agents/` or
   `.claude/`, and none is a build input by the *build-input docs* fact,
   skip it and say so in one line.
2. Otherwise phase 2 runs `ci-run.sh` (the command is in SKILL.md). It
   uses the run already on the head commit, or starts one, waits, and
   prints `run=` and `conclusion=` (with the failing steps' log on any
   conclusion but `success`).
3. Only `success` lets the merge go on.
   - `cancelled`: run the script again (it takes the newest run on the head
     commit); if that one was cancelled too, run it once more with `--new`.
     If the run it started is cancelled as well, **stop** and ask the
     developer.
   - Anything else (`failure`, `timed_out`, `startup_failure`,
     `action_required`, …): show the log tail it printed and **stop**. Fix
     it on the branch and re-run `/pre-merge`.
