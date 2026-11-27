#!/usr/bin/env bash
# Checks for .agents/skills/pre-merge/scripts/rebuild.sh: builds a throwaway
# repository, rebuilds a branch as one concern and as several, and checks the
# commits, their files and the refusals. Prints one line per failed check and
# exits non-zero when any fails.
#
# Usage: scripts/test-rebuild.sh   (from the repository's top level)
set -euo pipefail

rebuild="$(pwd)/.agents/skills/pre-merge/scripts/rebuild.sh"
[ -x "$rebuild" ] || { echo "run from the repository's top level" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
fails=0
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

g() { git -C "$repo" "$@"; }
msg() { printf '%s\n' "$2" > "$tmp/$1"; echo "$tmp/$1"; }

# A base commit as origin/main, then a branch whose commits mix three
# concerns: the main one (docs/a.md, src/a.txt), a second (docs/b.md,
# src/b/), and skill tooling only (.agents/).
setup() {
  rm -rf "$repo"; mkdir -p "$repo"
  g init -q -b main
  g config user.name test; g config user.email test@example.com
  g config commit.gpgsign false
  mkdir -p "$repo/src"; echo base > "$repo/src/a.txt"
  g add -A; g commit -q -m base
  g update-ref refs/remotes/origin/main HEAD
  g checkout -q -b feature-1/two-concerns
  mkdir -p "$repo/docs" "$repo/src/b" "$repo/.agents"
  echo a > "$repo/docs/a.md"; echo a > "$repo/src/a.txt"
  g add -A; g commit -q -m 'wip a'
  echo b > "$repo/docs/b.md"; echo b > "$repo/src/b/b.txt"; echo shared > "$repo/src/shared.txt"
  g add -A; g commit -q -m 'wip b'
  echo tool > "$repo/.agents/tool.md"
  g add -A; g commit -q -m 'wip tooling'
}
subjects() { g log --reverse --format=%s origin/main..HEAD | tr '\n' '|'; }
files_of() { g show --name-only --format= "$(g log --reverse --format=%H origin/main..HEAD | sed -n "${1}p")" | sort | tr '\n' ' '; }

# 1. One concern, called as before: docs first, then everything else.
setup
(cd "$repo" && "$rebuild" main --docs-msg "$(msg d 'docs one')" --impl-msg "$(msg i 'code one')") >/dev/null \
  || fail "single concern: rebuild failed"
[ "$(subjects)" = "docs one|code one|" ] || fail "single concern: commits are $(subjects)"
[ "$(files_of 1)" = "docs/a.md docs/b.md " ] || fail "single concern: docs commit holds $(files_of 1)"

# 2. Three concerns: docs A, code A, docs B, code B, tooling; the shared file
#    is named by B and by the tooling concern and goes to B, named first.
setup
before=$(g rev-parse HEAD^{tree})
(cd "$repo" && "$rebuild" main \
  --concern --docs-msg "$(msg ad 'docs A')" --impl-msg "$(msg ai 'code A')" \
  --concern --path docs/b.md --path src/b/ --path src/shared.txt \
            --docs-msg "$(msg bd 'docs B')" --impl-msg "$(msg bi 'code B')" \
  --concern --path .agents --path src/shared.txt --msg "$(msg c 'tooling C')") >/dev/null \
  || fail "three concerns: rebuild failed"
[ "$(subjects)" = "docs A|code A|docs B|code B|tooling C|" ] || fail "three concerns: commits are $(subjects)"
[ "$(files_of 2)" = "src/a.txt " ] || fail "three concerns: code A holds $(files_of 2)"
[ "$(files_of 4)" = "src/b/b.txt src/shared.txt " ] || fail "three concerns: code B holds $(files_of 4)"
[ "$(files_of 5)" = ".agents/tool.md " ] || fail "three concerns: tooling C holds $(files_of 5)"
[ "$(g rev-parse HEAD^{tree})" = "$before" ] || fail "three concerns: tree changed"

# 3. The concern taking the rest can still name a shared file, and wins it
#    when it comes first.
setup
(cd "$repo" && "$rebuild" main \
  --concern --rest --path src/shared.txt --docs-msg "$(msg ad 'docs A')" --impl-msg "$(msg ai 'code A')" \
  --concern --path docs/b.md --path src/b --path src/shared.txt \
            --docs-msg "$(msg bd 'docs B')" --impl-msg "$(msg bi 'code B')" \
  --concern --path .agents/ --msg "$(msg c 'tooling C')") >/dev/null \
  || fail "rest with a path: rebuild failed"
[ "$(files_of 2)" = "src/a.txt src/shared.txt " ] || fail "rest with a path: code A holds $(files_of 2)"
[ "$(files_of 4)" = "src/b/b.txt " ] || fail "rest with a path: code B holds $(files_of 4)"

# 4. Refusals leave the branch untouched.
refuses() {
  local name=$1; shift
  setup
  local head; head=$(g rev-parse HEAD)
  if (cd "$repo" && "$rebuild" main "$@") >/dev/null 2>&1; then fail "$name: did not refuse"; fi
  [ "$(g rev-parse HEAD)" = "$head" ] || fail "$name: HEAD moved"
}
refuses "unclaimed file" \
  --concern --path docs --path src --docs-msg "$(msg x1 x)" --impl-msg "$(msg x2 x)"
refuses "missing implementation message" --docs-msg "$(msg x3 x)"
refuses "two concerns taking the rest" \
  --concern --msg "$(msg x4 x)" --concern --path src --rest --msg "$(msg x5 x)"
refuses "concern with no file" \
  --concern --msg "$(msg x6 x)" --concern --path nowhere --msg "$(msg x7 x)"

[ "$fails" -eq 0 ] && echo "rebuild checks passed"
exit $((fails > 0))
