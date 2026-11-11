#!/usr/bin/env bash
# worker.sh — run one autonomous worker on a task spec, inside an OS-enforced write jail
# (macOS sandbox-exec, Linux bubblewrap) limited to its own git worktree.
#
# Usage: worker.sh <model> <repo-dir> <task-name> <spec-file>
#   model: a preset alias from config.json (e.g. deepseek), or backend:model-id with backend
#          one of commandcode, opencode, openrouter (e.g. openrouter:z-ai/glm-5.3-flash).
#          Exact ids only: no fuzzy matching, no silent default.
# Env:
#   DELEGATE_ALLOW      colon-separated extra paths the manager approved for writing (max 3)
#   DELEGATE_TASK_TYPE  label for the scoreboard (e.g. feature, test, refactor, bughunt)
#   DELEGATE_RUN_TAG    suffix so the same task can race on several models (worktree/branch name)
#   DELEGATE_EFFORT     optional reasoning effort for the model (ignored by the opencode backend)
#   DELEGATE_MAX_TURNS  default 80; 160 for task types bugfix/bughunt/review. Hitting it -> TURN_LIMIT
#                       (the opencode backend has no turn cap; the timeout covers it)
#   DELEGATE_TIMEOUT    wall-clock cap in seconds, default 900 -> status TIMEOUT
#   DELEGATE_IDLE       seconds with no new output before it counts as stuck, default 300 -> STALLED
#   DELEGATE_NO_SANDBOX=1  run without a sandbox when none is available (not recommended)
# Output: one JSON line. Artifacts in <repo>/.delegate/<task>[-tag]/.
# Risk: "risk":"high" when the spec has "Risk: high" or a changed path / added line matches
#   risk-patterns.txt (then review.sh must APPROVE it before merge.sh will merge it).
#   A (re-)run deletes any old review.md, so a new diff always needs a new review.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
[ $# -eq 4 ] || { echo "usage: worker.sh <model> <repo> <task-name> <spec-file>" >&2; exit 2; }
dg_load_env

# ---- resolve backend + model exactly ----------------------------------------
RES="$(python3 "$HERE/dg.py" resolve "$DG_CONFIG" "$1" 2>&1)" || { dg_json_err "$RES"; exit 3; }
BACKEND="${RES%%	*}"; MODEL="${RES#*	}"
WHY="$(dg_model_ok "$BACKEND" "$MODEL" 2>&1)" || { dg_json_err "$WHY"; exit 3; }
[ -n "$(dg_sandbox_kind)" ] || { dg_json_err "no sandbox tool found (macOS: sandbox-exec, Linux: bwrap); set DELEGATE_NO_SANDBOX=1 to run without one"; exit 5; }

REPO="$(dg_real "$2")"; TASK="$3"; SPEC="$(dg_real "$4")"
[ -f "$SPEC" ] || { dg_json_err "spec file not found: $SPEC"; exit 2; }
NAME="$TASK${DELEGATE_RUN_TAG:+-$DELEGATE_RUN_TAG}"
OUT="$REPO/.delegate/$NAME"
WT="$(dirname "$REPO")/.wt-$(basename "$REPO")-$NAME"
BR="delegate/$NAME"
case "${DELEGATE_TASK_TYPE:-}" in bugfix|bughunt|review) DEFTURNS=160;; *) DEFTURNS=80;; esac
TURNS="${DELEGATE_MAX_TURNS:-$DEFTURNS}"
mkdir -p "$OUT/tmp"
rm -f "$OUT/review.md" "$OUT/review.sha"   # a new run invalidates any earlier review
EXCL="$(git -C "$REPO" rev-parse --git-common-dir)"; case "$EXCL" in /*) ;; *) EXCL="$REPO/$EXCL";; esac
mkdir -p "$EXCL/info"; grep -qxF ".delegate/" "$EXCL/info/exclude" 2>/dev/null || echo ".delegate/" >> "$EXCL/info/exclude"

[ -d "$WT" ] || git -C "$REPO" worktree add -q -b "$BR" "$WT" HEAD
WT="$(dg_real "$WT")"
GITDIR="$(git -C "$WT" rev-parse --absolute-git-dir)"

# ---- manager-approved extra paths -------------------------------------------
DG_SB_EXTRA=("$DG_NO" "$DG_NO" "$DG_NO"); DG_ADD=(); i=0
IFS=':' read -r -a ALLOWED <<< "${DELEGATE_ALLOW:-}"
for p in ${ALLOWED[@]+"${ALLOWED[@]}"}; do
  [ -n "$p" ] || continue
  [ $i -lt 3 ] || { dg_json_err "DELEGATE_ALLOW supports at most 3 paths"; exit 4; }
  DG_SB_EXTRA[$i]="$(dg_real "$p")"; DG_ADD+=("${DG_SB_EXTRA[$i]}"); i=$((i+1))
done

PROMPT="$(cat "$SPEC")

Working rules (strict):
- You are an autonomous executor. Your workspace is this directory: $WT
- Stay inside it. Do not read, write, create or delete anything outside it, except reading
  toolchains/system libraries that commands need.${DELEGATE_ALLOW:+ The manager has also approved: ${DELEGATE_ALLOW}}
- Writes outside are blocked by the OS. If the task truly cannot be done without another
  path, STOP and end your reply with this exact line, then nothing else:
  NEED_ACCESS: <absolute path> | <read|write> | <one-sentence reason>
- Change only the files this spec allows. Do not run git commands that write (add, commit,
  checkout, stash, reset); the manager handles git.
- Never start servers, watch modes or anything interactive; use one-shot commands with a
  timeout. You have a hard time limit, so finish and report rather than polishing.
- Run the acceptance command, fix and re-run until it passes (at most 5 attempts).
- Your final reply is read by a busy manager. Keep it to at most 5 short lines: what you
  changed, anything the manager must know (assumptions, things you could not do), and as
  the last line PASS or FAIL plus a short reason (or the NEED_ACCESS line). No code, no
  test logs, no file listings, no recap of the spec."
printf '%s\n' "$PROMPT" > "$OUT/prompt.txt"

dg_build_cmd "$BACKEND" "$MODEL" "$PROMPT" "$OUT/prompt.txt" "$TURNS" "${DELEGATE_EFFORT:-}"
DG_SB_WT="$WT"; DG_SB_OUT="$(dg_real "$OUT")"; DG_SB_TMP="$(dg_real "$OUT/tmp")"; DG_SB_GITDIR="$GITDIR"
dg_fill_state "$BACKEND"

START=$(date +%s)
LIMIT="${DELEGATE_TIMEOUT:-900}"   # wall-clock cap, seconds
IDLE="${DELEGATE_IDLE:-300}"       # no new output for this long = stuck
: > "$OUT/events.ndjson"; : > "$OUT/stderr.log"
set +e
set -m   # the worker gets its own process group, so a kill takes its child commands too
( cd "$WT" && TMPDIR="$OUT/tmp/" dg_sandbox_exec "${DG_CMD[@]}" ) \
  < /dev/null > "$OUT/events.ndjson" 2> "$OUT/stderr.log" &
PID=$!
set +m
KILLED=""
while kill -0 "$PID" 2>/dev/null; do
  sleep 5
  NOW=$(date +%s)
  M1=$(dg_mtime "$OUT/events.ndjson"); M2=$(dg_mtime "$OUT/stderr.log")
  LAST=$(( M1 > M2 ? M1 : M2 ))
  [ "$LAST" -lt "$START" ] && LAST=$START
  if   [ $((NOW - START)) -ge "$LIMIT" ]; then KILLED=TIMEOUT
  elif [ $((NOW - LAST))  -ge "$IDLE"  ]; then KILLED=STALLED; fi
  if [ -n "$KILLED" ]; then
    kill -TERM -- "-$PID" 2>/dev/null; sleep 5; kill -KILL -- "-$PID" 2>/dev/null
    break
  fi
done
wait "$PID" 2>/dev/null; RC=$?
[ -n "$KILLED" ] && RC=124
set -e
SECS=$(( $(date +%s) - START ))

# ---- collect results (outside the sandbox) ----------------------------------
python3 "$HERE/dg.py" parse "$BACKEND" "$OUT/events.ndjson" "$OUT/stderr.log" "$RC" > "$OUT/result.json" || true
git -C "$WT" add -A && git -C "$WT" diff --cached > "$OUT/diff.patch" \
  && git -C "$WT" diff --cached --name-only > "$OUT/files.txt" && git -C "$WT" reset -q

python3 - "$OUT" "$TASK" "$MODEL" "$RC" "$SECS" "$BR" "$WT" "${DELEGATE_TASK_TYPE:-general}" \
         "$DG_BOARD" "$REPO" "$SPEC" "$KILLED" "$HERE/risk-patterns.txt" "$BACKEND" <<'PY'
import fnmatch, json, os, re, sys, time
out, task, model, rc, secs, br, wt, ttype, board, repo, spec, killed, riskfile, backend = sys.argv[1:]
try: r = json.load(open(f"{out}/result.json"))
except Exception: r = {}
text = r.get("finalText", "") or ""
open(f"{out}/final.txt", "w").write(text)
# short report for the manager: last 5 non-empty lines, max 600 chars
lines = [l.strip() for l in text.strip().splitlines() if l.strip()]
report = "\n".join(lines[-5:])[-600:]
open(f"{out}/report.txt", "w").write(report)
need = re.findall(r"^NEED_ACCESS:\s*(.+?)\s*\|\s*(read|write)\s*\|\s*(.+)$", text, re.M)
m = re.findall(r"^\s*\**(PASS|FAIL)\b(.*)$", text, re.M)
status = "NEED_ACCESS" if need else (m[-1][0] if m else "UNKNOWN")
if status == "UNKNOWN" and r.get("turnLimit"):
    status = "TURN_LIMIT"   # ran out of turns before its PASS/FAIL line: the work is kept
if status == "UNKNOWN" and not text:
    try: tail = open(f"{out}/stderr.log", errors="replace").read().strip()[-300:]
    except Exception: tail = ""
    report = report or (f"worker produced no reply (exit {rc}). stderr: {tail}" if tail
                        else f"worker produced no reply (exit {rc})")

# ---- scope check: every changed file must match the spec's "Files allowed" list
JUNK = ("__pycache__/", ".pyc", ".DS_Store", ".pytest_cache/", "node_modules/")
changed = [f for f in open(f"{out}/files.txt").read().split("\n") if f and not any(j in f for j in JUNK)]
sec = re.search(r"^Files allowed:(.*?)(?=^\w[\w ]*:|\Z)", open(spec).read(), re.M | re.S)
allowed = []
if sec:
    body = re.sub(r"\([^)]*\)", " ", sec.group(1))          # drop "(new)" notes
    allowed = [t.strip("`'\",.;") for t in re.split(r"[\s,]+", body) if t.strip("`'\",.;")]
    allowed = [t for t in allowed if ("/" in t or "." in t or "*" in t)]
def ok(f):
    return any(fnmatch.fnmatch(f, a) or (a.endswith("/") and f.startswith(a)) or f == a.lstrip("./")
               for a in allowed)
out_of_scope = [f for f in changed if allowed and not ok(f)]
scope = "unchecked" if not allowed else ("violation" if out_of_scope else "ok")
if out_of_scope and status == "PASS":
    status = "SCOPE_VIOLATION"
if killed:  # watchdog stopped it; partial work stays in the worktree and diff.patch
    status = killed

# ---- risk: spec "Risk: high", or a changed path / added line matching risk-patterns.txt
spec_text = open(spec).read()
why = []
if re.search(r"^Risk:\s*high\b", spec_text, re.M | re.I):
    why.append("spec")
pats = []
try:
    for l in open(riskfile):
        parts = l.strip().split(None, 2)
        if len(parts) == 3 and parts[0] in ("path", "content") and not l.lstrip().startswith("#"):
            try: pats.append((parts[0], parts[1], re.compile(parts[2])))
            except re.error as e: print(f"risk-patterns.txt: bad regex for {parts[1]}: {e}", file=sys.stderr)
except FileNotFoundError:
    pass
added = [l[1:] for l in open(f"{out}/diff.patch", errors="replace")
         if l.startswith("+") and not l.startswith("+++")]
for kind, name, rx in pats:
    if name in why: continue
    if (kind == "path" and any(rx.search(f) for f in changed)) or \
       (kind == "content" and any(rx.search(l) for l in added)):
        why.append(name)
risk = "high" if why else "low"
json.dump({"task": task, "backend": backend, "model": model, "branch": br, "worktree": wt, "spec": spec,
           "risk": risk, "risk_why": why}, open(f"{out}/meta.json", "w"))
if need:
    json.dump([{"path": p, "mode": md, "reason": rs} for p, md, rs in need],
              open(f"{out}/escalation.json", "w"), indent=2)
diff_lines = sum(1 for _ in open(f"{out}/diff.patch", errors="replace"))
BLOCK = ("operation not permitted", "eperm", "read-only file system", "erofs")
blocked = sum(1 for l in open(f"{out}/events.ndjson", errors="ignore") if any(b in l.lower() for b in BLOCK))
u = r.get("usage") or {}
row = {"task": task, "backend": backend, "model": model, "status": status, "exit": int(rc),
       "seconds": int(secs), "branch": br, "worktree": wt, "diff_lines": diff_lines,
       "blocked_writes": blocked, "input_tokens": u.get("inputTokens"),
       "output_tokens": u.get("outputTokens"), "cost_usd": r.get("costUsd"),
       "need_access": [p for p, _, _ in need], "files": changed, "scope": scope,
       "out_of_scope": out_of_scope, "report": report if status != "PASS" else "", "out": out,
       "risk": risk, "risk_why": why}
print(json.dumps(row))
try:
    with open(board, "a") as f:
        f.write(json.dumps({"ts": int(time.time()), "repo": os.path.basename(repo), "type": ttype,
                            **{k: row[k] for k in ("task", "backend", "model", "status", "seconds",
                                                   "diff_lines", "input_tokens", "output_tokens",
                                                   "cost_usd", "risk")}}) + "\n")
except OSError as e:
    print(f"scoreboard not written: {e}", file=sys.stderr)
PY
