#!/usr/bin/env bash
# merge.sh — commit, merge, test and clean up delegate worktrees in one call.
# Stops at the first error and leaves everything in place (nothing is force-removed
# unless you list it under --drop). Commits use the repository's own git identity.
#
# Usage: merge.sh <repo> [--test "<cmd>"] [--drop <name>]... [--unreviewed <name>]... <name>...
#   <name> = task, or task-tag for race runs (the folder name under <repo>/.delegate/)
#   --test  command run in <repo> after all merges; cleanup only happens if it passes
#   --drop  race losers: worktree and branch deleted without merging (diff.patch is kept)
#   --unreviewed  merge this risk=high task without an approved review (a knowing skip)
# Review gate: a risk=high task (meta.json) is merged only if .delegate/<name>/review.md ends
#   with "VERDICT: APPROVE" and review.sha matches the worktree's current diff. Checked for all
#   tasks before anything is committed or merged.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
die() { echo "STOP: $*"; exit 1; }
[ $# -ge 2 ] || { sed -n 2,14p "$0"; exit 2; }
REPO="$(cd "$1" && pwd)" || exit 2; shift
TEST=""; KEEP=(); DROP=(); UNREV=()
add_keep() { local k; for k in ${KEEP[@]+"${KEEP[@]}"}; do [ "$k" = "$1" ] && return; done; KEEP+=("$1"); }
while [ $# -gt 0 ]; do
  case "$1" in --test) TEST="$2"; shift 2;; --drop) DROP+=("$2"); shift 2;;
               --unreviewed) UNREV+=("$2"); add_keep "$2"; shift 2;; *) add_keep "$1"; shift;; esac
done
PARENT="$(dirname "$REPO")"; BASE="$(basename "$REPO")"
# Full change of a task's worktree vs its fork point, junk excluded. Same function in review.sh.
wt_diff() {  # <repo> <branch> <worktree>
  local base; base="$(git -C "$1" merge-base "$2" HEAD)" || return 1
  ( cd "$3" && git add -A && git diff --cached "$base" -- . \
      ':(exclude,glob)**/__pycache__/**' ':(exclude,glob)**/*.pyc' \
      ':(exclude,glob)**/.DS_Store' ':(exclude,glob)**/.pytest_cache/**'; git reset -q )
}
wt() { echo "$PARENT/.wt-$BASE-$1"; }
clean_junk() { find "$1" \( -name __pycache__ -o -name .pytest_cache \) -prune -exec rm -rf {} + 2>/dev/null
               find "$1" \( -name '*.pyc' -o -name .DS_Store \) -delete 2>/dev/null; }
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || die "$REPO has uncommitted changes to tracked files"
if [ ${#KEEP[@]} -gt 0 ]; then
  [ -n "$(git -C "$REPO" config user.name)" ] && [ -n "$(git -C "$REPO" config user.email)" ] \
    || die "git user.name / user.email are not set for $REPO; the user must set them (git config user.name ...)"
fi
CUR="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"

# 0. review gate (before touching anything)
for n in ${KEEP[@]+"${KEEP[@]}"}; do
  D="$REPO/.delegate/$n"
  RISK="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("risk","low"))' "$D/meta.json" 2>/dev/null)"
  [ "$RISK" = high ] || continue
  skip=""; for u in ${UNREV[@]+"${UNREV[@]}"}; do [ "$u" = "$n" ] && skip=1; done
  if [ -n "$skip" ]; then echo "WARN       $n is risk=high, merging UNREVIEWED (--unreviewed)"; continue; fi
  LAST="$(tail -n 1 "$D/review.md" 2>/dev/null)"
  [ "$LAST" = "VERDICT: CHANGES" ] && die "$n is risk=high and its review says CHANGES; fix and re-review it (findings: $D/review.md)"
  [ "$LAST" = "VERDICT: APPROVE" ] \
    || die "$n is risk=high and has no approved review; run review.sh $REPO $n (or pass --unreviewed $n)"
  W="$(wt "$n")"; [ -d "$W" ] || die "worktree missing for $n ($W)"
  NOW="$(wt_diff "$REPO" "delegate/$n" "$W" | dg_sha16)"
  [ "$NOW" = "$(cat "$D/review.sha" 2>/dev/null)" ] \
    || die "$n changed since its review was approved; run review.sh $REPO $n again"
  echo "approved   $n (risk=high, review matches current diff)"
done

# 1. commit each kept worktree on its branch
for n in ${KEEP[@]+"${KEEP[@]}"}; do
  W="$(wt "$n")"; [ -d "$W" ] || die "worktree missing for $n ($W); recover with: git apply $REPO/.delegate/$n/diff.patch"
  clean_junk "$W"
  if [ -n "$(git -C "$W" status --porcelain)" ]; then
    MODEL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("model",""))' "$REPO/.delegate/$n/meta.json" 2>/dev/null)"
    git -C "$W" add -A && git -C "$W" commit -qm "delegate: $n${MODEL:+ ($MODEL)}" || die "commit failed in $W"
  fi
  [ "$(git -C "$REPO" rev-list --count "$CUR..delegate/$n")" -gt 0 ] || die "delegate/$n has nothing new to merge"
  echo "committed  delegate/$n  $(git -C "$REPO" log -1 --format='%h %s' "delegate/$n")"
done

# 2. merge one at a time
for n in ${KEEP[@]+"${KEEP[@]}"}; do
  if ! git -C "$REPO" merge -q --no-edit "delegate/$n"; then
    git -C "$REPO" merge --abort 2>/dev/null
    die "merge conflict on delegate/$n (aborted; earlier merges stay, worktrees kept)"
  fi
  echo "merged     delegate/$n"
done

# 3. test
if [ -n "$TEST" ]; then
  if (cd "$REPO" && bash -o pipefail -c "$TEST") > "$REPO/.delegate/merge-test.log" 2>&1; then
    echo "tests      PASS ($TEST)"
  else
    tail -n 15 "$REPO/.delegate/merge-test.log"; die "tests failed after merge; worktrees kept. Log: $REPO/.delegate/merge-test.log"
  fi
fi

# 4. clean up (only reached when everything above succeeded)
for n in ${KEEP[@]+"${KEEP[@]}"}; do
  W="$(wt "$n")"; clean_junk "$W"
  git -C "$REPO" worktree remove "$W" && git -C "$REPO" branch -q -d "delegate/$n" && echo "removed    $n" \
    || echo "WARN: could not remove $n cleanly; left in place"
done
for n in ${DROP[@]+"${DROP[@]}"}; do
  W="$(wt "$n")"
  [ -d "$W" ] && git -C "$REPO" worktree remove --force "$W"
  git -C "$REPO" branch -q -D "delegate/$n" 2>/dev/null; echo "dropped    $n (patch kept in .delegate/$n/diff.patch)"
done
echo "DONE on $CUR: $(git -C "$REPO" log -1 --format='%h %s')"
