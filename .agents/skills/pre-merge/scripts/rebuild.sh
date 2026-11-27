#!/usr/bin/env bash
# Rebuild a rebased branch as a documentation commit then an implementation
# commit for each concern, keeping every file's content exactly as it was.
# Run on the branch, after it was rebased directly onto origin/<base>, with a
# clean working tree.
#
# Usage: rebuild.sh [--wrap '<prefix>'] <base> [--to-docs <path>]...
#                   [--to-impl <path>]... <messages>
#        rebuild.sh [--wrap '<prefix>'] <base> [--to-docs <path>]...
#                   [--to-impl <path>]...
#                   (--concern [--path <path>]... [--rest] <messages>)...
#   <messages> is [--docs-msg <file>] [--impl-msg <file>], or --msg <file> to
#   commit everything the concern holds as one commit.
#   Without --concern, one concern holds every change. With it, each changed
#   file goes to the first concern whose --path names the file or a folder
#   above it, and a file no --path names goes to the one concern that gives
#   --rest or no --path at all. A file no concern takes, or a concern that
#   takes no file, stops the script before anything changes.
#   Within a concern, the documentation bucket takes its changes under docs/
#   plus each --to-docs path, minus each --to-impl path; the implementation
#   bucket takes the rest. Concerns commit in the order given, each one's
#   documentation commit first. A bucket with changes needs its message file
#   (make it with mktemp; it is passed to git commit -F, so backticks stay
#   literal).
#   Only files the branch changed are committed, so untracked files such as
#   linked fixtures never are.
#   Prints pre-rebuild=<sha>, "content identical" and the new commits. If it
#   stops for any reason after pre-rebuild= (a failed commit, content that
#   differs), it prints how to restore and exits non-zero.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
die() { echo "rebuild.sh: $1" >&2; exit "${2:-1}"; }
WRAP=()
if [ "${1:-}" = "--wrap" ]; then
  [ $# -ge 2 ] || usage
  read -r -a WRAP <<<"$2"; shift 2
fi
run() { ${WRAP[@]+"${WRAP[@]}"} "$@"; }

[ $# -ge 1 ] || usage
base=$1; shift
to_docs=() to_impl=()
# Concern i: its message files and its --path list, one path per line.
c_docs=() c_impl=() c_one=() c_paths=() c_has=() c_rest=()
n=0 cur=-1 implicit=
new_concern() {
  c_docs[$n]='' c_impl[$n]='' c_one[$n]='' c_paths[$n]='' c_has[$n]='' c_rest[$n]=''
  cur=$n; n=$((n + 1))
}
while [ $# -gt 0 ]; do
  case "$1" in
    --concern)
      [ -z "$implicit" ] || usage
      new_concern; shift; continue ;;
    --rest)
      { [ "$cur" -ge 0 ] && [ -z "$implicit" ]; } || usage
      c_rest[$cur]=1; shift; continue ;;
  esac
  [ $# -ge 2 ] || usage
  case "$1" in
    --to-docs) to_docs+=("${2%/}") ;;
    --to-impl) to_impl+=("${2%/}") ;;
    --docs-msg|--impl-msg|--msg)
      if [ "$cur" -lt 0 ]; then new_concern; implicit=1; fi
      case "$1" in
        --docs-msg) c_docs[$cur]=$2 ;;
        --impl-msg) c_impl[$cur]=$2 ;;
        --msg) c_one[$cur]=$2 ;;
      esac ;;
    --path)
      { [ "$cur" -ge 0 ] && [ -z "$implicit" ]; } || usage
      c_paths[$cur]="${c_paths[$cur]}${2%/}"$'\n'; c_has[$cur]=1 ;;
    *) usage ;;
  esac
  shift 2
done
[ "$n" -gt 0 ] || new_concern

catchall=-1
for ((i = 0; i < n; i++)); do
  if [ -n "${c_one[$i]}" ] && [ -n "${c_docs[$i]}${c_impl[$i]}" ]; then
    die "concern $((i + 1)): --msg replaces --docs-msg and --impl-msg" 2
  fi
  for m in "${c_docs[$i]}" "${c_impl[$i]}" "${c_one[$i]}"; do
    [ -z "$m" ] || [ -r "$m" ] || die "no message file $m" 2
  done
  if [ -z "${c_has[$i]}" ] || [ -n "${c_rest[$i]}" ]; then
    [ "$catchall" -lt 0 ] || die "more than one concern takes the rest (--rest or no --path)" 2
    catchall=$i
  fi
done

if [ -n "$(run git status --porcelain --untracked-files=no)" ]; then
  die "uncommitted changes; commit or ask first"
fi
run git merge-base --is-ancestor "origin/$base" HEAD \
  || die "HEAD is not on top of origin/$base; rebase first"

pre=$(run git rev-parse HEAD)
changed=$(run git -c core.quotePath=false diff --no-renames --name-only "origin/$base" "$pre")
[ -n "$changed" ] || die "no changes against origin/$base"

in_list() { local x=$1; shift; for p in "$@"; do case "$x" in "$p"|"$p"/*) return 0 ;; esac; done; return 1; }
in_lines() {
  local x=$1 p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$x" in "$p"|"$p"/*) return 0 ;; esac
  done <<<"$2"
  return 1
}

# Changed file k: its concern owner[k] and its bucket kind[k] (d
# documentation, i implementation, a the concern's single commit).
files=() owner=() kind=() unclaimed=
while IFS= read -r f; do
  o=-1
  for ((i = 0; i < n; i++)); do
    if [ -n "${c_has[$i]}" ] && in_lines "$f" "${c_paths[$i]}"; then o=$i; break; fi
  done
  [ "$o" -ge 0 ] || o=$catchall
  if [ "$o" -lt 0 ]; then unclaimed="$unclaimed  $f"$'\n'; continue; fi
  if [ -n "${c_one[$o]}" ]; then
    k=a
  elif { case "$f" in docs/*) true ;; *) false ;; esac || in_list "$f" ${to_docs[@]+"${to_docs[@]}"}; } \
       && ! in_list "$f" ${to_impl[@]+"${to_impl[@]}"}; then
    k=d
  else
    k=i
  fi
  files+=("$f"); owner+=("$o"); kind+=("$k")
done <<<"$changed"
[ -z "$unclaimed" ] || { printf 'rebuild.sh: no concern takes these files:\n%s' "$unclaimed" >&2; exit 2; }

label() { if [ "$n" -gt 1 ]; then echo "concern $(($1 + 1)): "; fi; }
has_kind() {
  local k
  for ((k = 0; k < ${#files[@]}; k++)); do
    if [ "${owner[$k]}" = "$1" ] && [ "${kind[$k]}" = "$2" ]; then return 0; fi
  done
  return 1
}
for ((i = 0; i < n; i++)); do
  has_kind "$i" d || has_kind "$i" i || has_kind "$i" a || die "$(label "$i")takes no changed file" 2
  ! has_kind "$i" d || [ -n "${c_docs[$i]}" ] || die "$(label "$i")documentation changes need --docs-msg" 2
  ! has_kind "$i" i || [ -n "${c_impl[$i]}" ] || die "$(label "$i")implementation changes need --impl-msg" 2
done

commit_bucket() {
  local k list=()
  for ((k = 0; k < ${#files[@]}; k++)); do
    if [ "${owner[$k]}" = "$1" ] && [ "${kind[$k]}" = "$2" ]; then list+=("${files[$k]}"); fi
  done
  [ ${#list[@]} -gt 0 ] || return 0
  run git add -A -- "${list[@]}"
  run git commit -q -F "$3"
}

echo "pre-rebuild=$pre"
done=
trap '[ -n "$done" ] || echo "rebuild.sh: stopped mid-rebuild; nothing pushed. Restore with: git reset --hard $pre" >&2' EXIT
run git reset -q --soft "origin/$base"
run git reset -q
for ((i = 0; i < n; i++)); do
  if [ -n "${c_one[$i]}" ]; then
    commit_bucket "$i" a "${c_one[$i]}"
  else
    commit_bucket "$i" d "${c_docs[$i]}"
    commit_bucket "$i" i "${c_impl[$i]}"
  fi
done

if run git diff --quiet "$pre" HEAD; then
  done=1
  echo "content identical"
  run git log --oneline "origin/$base..HEAD"
else
  echo "rebuild.sh: content differs from $pre" >&2
  exit 1
fi
