#!/usr/bin/env bash
# Render checks for .agents/skills/setup-skills/scripts/setup.sh: renders a
# few skills from this checkout with a sample profile into a temporary
# project and checks the facts blocks and allowed-tools. Prints one line per
# failed check and exits non-zero when any fails.
#
# Usage: scripts/test-setup.sh   (from the repository's top level)
set -euo pipefail

root=$(pwd)
setup="$root/.agents/skills/setup-skills/scripts/setup.sh"
skills="$root/.agents/skills"
[ -x "$setup" ] || { echo "run from the repository's top level" >&2; exit 2; }

proj=$(mktemp -d)
trap 'rm -rf "$proj"' EXIT
mkdir -p "$proj/.agents"

# The profile exercises: a blank line inside a | block followed by more
# facts; a gate run bare (a make target); a wrapped tool written bare; the
# wrapper's own tool; a step with a trailing comment.
cat > "$proj/.agents/skills-profile.md" <<'EOF'
---
kind: managed
source: anrusina/aoi-skills
ref: main
skills: [commit, start-task, pre-merge]
assets: [flutter]
wrapped-tools: [flutter, dart]
facts:
  repo: acme/widgets
  base: main
  wrapper: mise exec --
  gates: [make check]
  format-fix: dart format lib test
  setup:
    - mise install
    - flutter pub get  # once pubspec.yaml exists

  dependency-policy: |
    First paragraph of the policy.

    Second paragraph of the policy.

  milestones: |
    Active: v1. Backlog: Later.
  pre-merge-checks: none
---
EOF

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
has() { grep -qF -- "$2" "$1" || fail "$3"; }
hasnt() { if grep -qF -- "$2" "$1"; then fail "$3"; fi; }

cd "$proj"
for s in commit start-task pre-merge; do
  "$setup" render .agents/skills-profile.md "$skills" "$s" >/dev/null
done
commit=.agents/skills/commit/SKILL.md
start=.agents/skills/start-task/SKILL.md
pre=.agents/skills/pre-merge/SKILL.md

# A blank line inside a block keeps the block whole and ends nothing.
has "$commit" "First paragraph of the policy." "commit: dependency policy, first paragraph"
has "$commit" "Second paragraph of the policy." "commit: dependency policy lost the paragraph after a blank line"
has "$start" "Active: v1. Backlog: Later." "start-task: milestones read as none after a blank line in an earlier block"

# allowed-tools: written as the agent runs each command.
has "$commit" "  - Bash(make check)" "commit: a make gate must stay bare"
hasnt "$commit" "Bash(mise exec -- make check)" "commit: a make gate was wrapped"
has "$commit" "  - Bash(mise exec -- dart format lib test)" "commit: a wrapped-tool format fix must be wrapped"
has "$start" "  - Bash(mise install)" "start-task: the wrapper's own tool must stay bare"
hasnt "$start" "Bash(mise exec -- mise install)" "start-task: the wrapper's own tool was wrapped"
has "$start" "  - Bash(mise exec -- flutter pub get)" "start-task: a setup step lost its wrapper or kept its comment"
hasnt "$start" "# once pubspec.yaml exists)" "start-task: a trailing comment reached allowed-tools"
has "$pre" "  - Bash(make check)" "pre-merge: a make gate must stay bare"

# No generic placeholder survives in the rendered blocks.
for f in "$commit" "$start" "$pre"; do
  hasnt "$f" "*shared*" "$f: a shared row was left unrendered"
done

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "test-setup: all checks passed"
