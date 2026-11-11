#!/usr/bin/env bash
# tests/run.sh — offline end-to-end test: swarm -> review -> merge against a mock model API.
# Needs no account, key or network. Uses the openrouter backend pointed at a local mock server,
# so it exercises worktrees, the sandbox, scope and risk checks, the review gate and the merge.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skill"
# Not under the system temp folder: the sandbox lets workers write there, and the escape
# check below needs a target that is outside everything a worker may write.
T="$ROOT/tests/.tmp/run.$$"; mkdir -p "$T"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
has() { if grep -qE -- "$2" <<< "$1"; then ok "$3"; else bad "$3"; echo "$1" | sed 's/^/        /'; fi; }

python3 "$ROOT/tests/mock_openai.py" "$T/port" & MOCK=$!
trap 'kill $MOCK 2>/dev/null; wait $MOCK 2>/dev/null; rm -rf "$T"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/port" ] && break; sleep 0.3; done
export OPENROUTER_BASE_URL="http://127.0.0.1:$(cat "$T/port")" OPENROUTER_API_KEY=test-key
export DELEGATE_CONFIG="$T/config.json" DELEGATE_SCOREBOARD="$T/scoreboard.jsonl" DELEGATE_ENV_FILE="$T/none"
cat > "$T/config.json" <<'EOF'
{ "presets": { "ok":     {"backend": "openrouter", "model": "mock/ok"},
               "escape": {"backend": "openrouter", "model": "mock/escape"},
               "scope":  {"backend": "openrouter", "model": "mock/scope"},
               "risky":  {"backend": "openrouter", "model": "mock/risky"} },
  "default": "ok",
  "reviewer": {"backend": "openrouter", "model": "mock/review"} }
EOF

R="$T/repo"; mkdir -p "$R/.delegate/specs" && cd "$R" && git init -q -b main . \
  && git config user.name "Delegate Test" && git config user.email test@example.invalid \
  && echo "# demo" > README.md && git add README.md && git commit -qm init
spec() {  # <name> <files allowed> [extra line]
  printf 'Task: add %s\nMOCK_NAME: %s\nFiles allowed: %s\nAcceptance: python3 -c "print(1)"\n%s\n' \
    "$1" "$1" "$2" "${3:-}" > "$R/.delegate/specs/$1.md"
}
spec alpha "src/alpha.py"
spec beta  "src/beta.py" "ESCAPE_TARGET: $T/escaped.txt"
spec gamma "src/gamma.py"
spec delta "src/delta_auth.py"
cat > "$R/.delegate/manifest.txt" <<'EOF'
# model  task   spec
ok       alpha  .delegate/specs/alpha.md  type=feature
escape   beta   .delegate/specs/beta.md   type=feature
scope    gamma  .delegate/specs/gamma.md
risky    delta  .delegate/specs/delta.md
nosuch   omega  .delegate/specs/alpha.md
EOF

echo "doctor"
OUT="$("$SKILL/doctor.sh" --models 2>&1)"
has "$OUT" '^ok +@ok +openrouter:mock/ok.*\[default\]' "lists presets and marks the default"

echo "swarm"
OUT="$("$SKILL/swarm.sh" "$R" "$R/.delegate/manifest.txt" 2>&1)"; echo "$OUT" | sed 's/^/    /'
has "$OUT" '^PASS +alpha '                        "plain task passes"
has "$OUT" '^PASS +beta .*blocked_writes=[1-9]'   "write outside the worktree is reported as blocked"
[ ! -e "$T/escaped.txt" ] && ok "sandbox stopped the write outside the worktree" || bad "worker wrote outside its worktree"
has "$OUT" '^SCOPE_VIOLATION +gamma .*README.md'  "file outside 'Files allowed' is a scope violation"
has "$OUT" '^PASS +delta .*REVIEW \(.*auth'       "auth change is marked risk=high"
has "$OUT" '^ERROR +omega .*unknown model'        "unknown alias is an error, not a silent default"
has "$OUT" '^SUMMARY 3/5 PASS, 1 need REVIEW'     "summary line"

echo "merge gate"
OUT="$("$SKILL/merge.sh" "$R" alpha delta 2>&1)"
has "$OUT" '^STOP: delta is risk=high and has no approved review' "unreviewed high-risk task blocks the merge"
[ -z "$(git -C "$R" log --oneline --grep delegate)" ] && ok "nothing merged while the gate is closed" || bad "merged despite gate"

echo "review"
OUT="$("$SKILL/review.sh" "$R" delta 2>&1)"; echo "$OUT" | sed 's/^/    /'
has "$OUT" '^APPROVE +delta'  "reviewer verdict comes back as one line"
has "$OUT" '^COST '           "cost line"

echo "merge"
OUT="$("$SKILL/merge.sh" "$R" --test "python3 -c 'import sys; sys.path.insert(0, \"src\"); import alpha, beta, delta_auth'" --drop gamma alpha beta delta 2>&1)"
echo "$OUT" | sed 's/^/    /'
has "$OUT" '^approved +delta'   "approved review opens the gate"
has "$OUT" '^tests +PASS'       "post-merge test ran"
has "$OUT" '^DONE on main'      "merge finished"
[ -f "$R/src/alpha.py" ] && [ -f "$R/src/beta.py" ] && [ -f "$R/src/delta_auth.py" ] && ok "merged files are on main" || bad "merged files missing"
[ "$(git -C "$R" worktree list | wc -l | tr -d ' ')" = 1 ] && ok "worktrees cleaned up" || bad "worktrees left behind"
[ -z "$(git -C "$R" branch --list 'delegate/*')" ] && ok "branches cleaned up" || bad "branches left behind"
[ "$(wc -l < "$T/scoreboard.jsonl" | tr -d ' ')" = 5 ] && ok "scoreboard has 4 task rows + 1 review row" || bad "scoreboard rows"

echo
echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
