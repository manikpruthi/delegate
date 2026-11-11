#!/usr/bin/env bash
# swarm.sh — run several delegate workers in parallel and return once, when all are done.
# One background call = one manager wake-up, instead of one per worker.
#
# Usage: swarm.sh <repo> <manifest>
# Manifest: one task per line, '#' comments allowed:
#   <model> <task> <spec-file> [type=feature] [effort=high] [tag=glm] [allow=/abs/path:/abs/path2]
#            [timeout=900] [idle=300]   (seconds; watchdog kills the worker -> TIMEOUT / STALLED)
#            [turns=80]                 (model turn budget; 160 by default for type=bugfix/bughunt/review -> TURN_LIMIT)
#   spec-file may be relative to <repo>.
#   model = preset alias from config.json, or backend:model-id (commandcode:..., opencode:..., openrouter:...).
# Output: one short line per worker (details only for non-PASS), then a SUMMARY line.
#   A PASS line ending in "REVIEW (<why>)" is risk=high: run review.sh on it before merging.
# Full per-worker JSON goes to <repo>/.delegate/last-swarm.json.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -eq 2 ] || { echo "usage: swarm.sh <repo> <manifest>" >&2; exit 2; }
REPO="$(cd "$1" && pwd)" || exit 2; MANIFEST="$2"
[ -f "$MANIFEST" ] || { echo '{"error":"manifest not found"}'; exit 2; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo '{"error":"not a git repository"}'; exit 2; }
git -C "$REPO" rev-parse HEAD >/dev/null 2>&1 || { echo '{"error":"the repository has no commits yet; commit first"}'; exit 2; }
RUN="$REPO/.delegate/_swarm.$$"; mkdir -p "$RUN"
EXCL="$(git -C "$REPO" rev-parse --git-common-dir)"; case "$EXCL" in /*) ;; *) EXCL="$REPO/$EXCL";; esac
mkdir -p "$EXCL/info"; grep -qxF ".delegate/" "$EXCL/info/exclude" 2>/dev/null || echo ".delegate/" >> "$EXCL/info/exclude"

i=0; PIDS=()
while read -r MODEL TASK SPEC REST || [ -n "${MODEL:-}" ]; do
  [ -z "${MODEL:-}" ] && continue; case "$MODEL" in \#*) continue;; esac
  case "$SPEC" in /*) ;; *) SPEC="$REPO/$SPEC";; esac
  TYPE=general; EFFORT=""; TAG=""; ALLOW=""; TMO=""; IDL=""; TRN=""
  for kv in $REST; do
    case "$kv" in type=*) TYPE="${kv#type=}";; effort=*) EFFORT="${kv#effort=}";;
                  tag=*) TAG="${kv#tag=}";; allow=*) ALLOW="${kv#allow=}";;
                  timeout=*) TMO="${kv#timeout=}";; idle=*) IDL="${kv#idle=}";; turns=*) TRN="${kv#turns=}";; esac
  done
  i=$((i+1))
  ( DELEGATE_MAX_TURNS="${TRN:-${DELEGATE_MAX_TURNS:-}}" DELEGATE_TIMEOUT="${TMO:-${DELEGATE_TIMEOUT:-900}}" \
    DELEGATE_IDLE="${IDL:-${DELEGATE_IDLE:-300}}" DELEGATE_TASK_TYPE="$TYPE" DELEGATE_EFFORT="$EFFORT" \
    DELEGATE_RUN_TAG="$TAG" DELEGATE_ALLOW="$ALLOW" \
      "$HERE/worker.sh" "$MODEL" "$REPO" "$TASK" "$SPEC" < /dev/null > "$RUN/$i.json" 2> "$RUN/$i.err"
    echo "$TASK${TAG:+-$TAG}" > "$RUN/$i.name" ) &
  PIDS+=($!)
  sleep 1   # stagger worktree creation (git locks)
done < "$MANIFEST"
[ $i -gt 0 ] || { echo '{"error":"empty manifest"}'; rm -rf "$RUN"; exit 2; }
for p in "${PIDS[@]}"; do wait "$p"; done

python3 - "$RUN" "$i" "$REPO/.delegate/last-swarm.json" <<'PY'
import json, sys
run, n, full = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rows = []
for k in range(1, n + 1):
    txt = open(f"{run}/{k}.json").read().strip().splitlines()
    try:
        r = json.loads(txt[-1])
    except Exception:
        r = {}
    if "status" not in r:      # worker.sh stopped before running the model
        try: name = open(f"{run}/{k}.name").read().strip()
        except Exception: name = f"#{k}"
        r = {"task": name, "status": "ERROR",
             "error": r.get("error") or (open(f"{run}/{k}.err").read() or "no output")[-300:]}
    rows.append(r)
json.dump(rows, open(full, "w"), indent=1)          # everything, for when you need it
# compact view for the manager: one short line per worker, details only when something is wrong
for r in rows:
    m = (r.get("model") or "?").split("/")[-1]
    line = f"{r.get('status','ERROR'):15} {r.get('task')}  {m}  {r.get('seconds','?')}s  {len(r.get('files') or [])} files"
    if r.get("status") != "PASS":
        extra = {k: r[k] for k in ("out_of_scope", "need_access", "error") if r.get(k)}
        if r.get("report"): extra["report"] = r["report"]
        line += "  " + json.dumps(extra)
    if r.get("blocked_writes"):
        line += f"  blocked_writes={r['blocked_writes']}"
    if r.get("status") == "PASS" and r.get("risk") == "high":
        line += f"  REVIEW ({','.join(r.get('risk_why') or [])})"
    print(line)
st = [r.get("status", "ERROR") for r in rows]
rev = sum(1 for r in rows if r.get("status") == "PASS" and r.get("risk") == "high")
cost = sum((r.get("cost_usd") or 0) for r in rows)
print(f"SUMMARY {st.count('PASS')}/{n} PASS{f', {rev} need REVIEW' if rev else ''}, longest {max((r.get('seconds') or 0) for r in rows)}s, "
      f"{sum((r.get('input_tokens') or 0) for r in rows)//1000}k in / {sum((r.get('output_tokens') or 0) for r in rows)//1000}k out"
      f"{f', ${cost:.3f} reported' if cost else ''}. Full JSON: .delegate/last-swarm.json")
PY
rm -rf "$RUN"
