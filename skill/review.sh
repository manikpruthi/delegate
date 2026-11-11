#!/usr/bin/env bash
# review.sh — independent review of high-risk delegate tasks by the reviewer model from
# config.json, run headless with a fresh context and no way to change anything. Tasks are
# batched, batches run in parallel, and only short verdict lines come back.
#
# Usage: review.sh <repo> <unit>...
#   unit = a task name (its folder under <repo>/.delegate/, task-tag for race runs), or several
#          joined with + (e.g. api+client) to keep tasks that share interfaces in one batch.
# Reviewer: config.json "reviewer": {"backend", "model", "effort"}; backend is one of
#   claude       claude -p with no CLAUDE.md, skills, plugins, hooks or MCP; Read/Grep/Glob only
#   openrouter   or_agent.py --read-only (read tools only, limited to the repo and worktrees)
#   commandcode, opencode   the CLI inside the write jail with nothing writable but a scratch folder
# Batching: up to DELEGATE_REVIEW_MAX_TASKS (4) tasks and DELEGATE_REVIEW_MAX_LINES (1500) diff
#   lines per batch; a single diff over the line cap gets its own run and is reviewed file by file.
# Env: DELEGATE_REVIEW_BACKEND / _MODEL / _EFFORT override config.json
#      DELEGATE_REVIEW_TIMEOUT (1200 s/batch)  DELEGATE_REVIEW_MAX_TURNS (60)
# Output: per task "APPROVE|CHANGES|ERROR <task>  <up to 3 findings>" (<= 600 chars), at most one
#   "CROSS ..." line per batch, and one COST line per batch.
#   Full review: <repo>/.delegate/<task>/review.md, last line "VERDICT: APPROVE" or "VERDICT: CHANGES".
#   review.sha records the exact diff that was reviewed; merge.sh checks it.
#   diff.patch is refreshed from the worktree (vs its fork point) before the review.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
[ $# -ge 2 ] || { sed -n 2,21p "$0"; exit 2; }
REPO="$(cd "$1" && pwd)" || exit 2; shift
dg_load_env
RES="$(python3 "$HERE/dg.py" reviewer "$DG_CONFIG" 2>&1)" || { echo "STOP: $RES"; exit 3; }
IFS='	' read -r BACKEND MODEL EFFORT <<< "$RES"
WHY="$(dg_backend_ready "$BACKEND")" || { echo "STOP: reviewer backend not ready: $WHY"; exit 3; }
case "$BACKEND" in commandcode|opencode)
  [ -n "$(dg_sandbox_kind)" ] || { echo "STOP: the $BACKEND reviewer needs a sandbox (macOS sandbox-exec, Linux bwrap)"; exit 3; };;
esac
LIMIT="${DELEGATE_REVIEW_TIMEOUT:-1200}"; TURNS="${DELEGATE_REVIEW_MAX_TURNS:-60}"
RUN="$REPO/.delegate/_review.$$"; mkdir -p "$RUN"
trap 'rm -rf "$RUN"' EXIT

# Full change of a task's worktree vs its fork point, junk excluded. Same function in merge.sh.
wt_diff() {  # <repo> <branch> <worktree>
  local base; base="$(git -C "$1" merge-base "$2" HEAD)" || return 1
  ( cd "$3" && git add -A && git diff --cached "$base" -- . \
      ':(exclude,glob)**/__pycache__/**' ':(exclude,glob)**/*.pyc' \
      ':(exclude,glob)**/.DS_Store' ':(exclude,glob)**/.pytest_cache/**'; git reset -q )
}

# ---- 1. refresh diffs and record what is reviewed -----------------------------
for unit in "$@"; do
  IFS='+' read -r -a TS <<< "$unit"
  for t in "${TS[@]}"; do
    M="$REPO/.delegate/$t/meta.json"
    [ -f "$M" ] || { echo "STOP: no $M (run the task with worker.sh / swarm.sh first)"; exit 2; }
    { read -r BR; read -r WT; } < <(python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));print(m["branch"]);print(m["worktree"])' "$M")
    [ -d "$WT" ] || { echo "STOP: worktree missing for $t ($WT)"; exit 2; }
    wt_diff "$REPO" "$BR" "$WT" > "$REPO/.delegate/$t/diff.patch" || { echo "STOP: could not diff $t"; exit 2; }
    dg_sha16 < "$REPO/.delegate/$t/diff.patch" > "$RUN/$t.sha"
    rm -f "$REPO/.delegate/$t/review.md" "$REPO/.delegate/$t/review.sha"
  done
done

# ---- 2. plan batches: writes $RUN/b<k>.prompt, .tasks, .dirs ------------------
NB="$(python3 - "$REPO" "$RUN" "${DELEGATE_REVIEW_MAX_LINES:-1500}" "${DELEGATE_REVIEW_MAX_TASKS:-4}" "$@" <<'PY'
import json, os, sys
repo, run, maxl, maxt = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
units = [u.split("+") for u in sys.argv[5:]]
info = {}
for u in units:
    for t in u:
        d = f"{repo}/.delegate/{t}"
        m = json.load(open(f"{d}/meta.json"))
        info[t] = {"lines": sum(1 for _ in open(f"{d}/diff.patch", errors="replace")),
                   "spec": m.get("spec", ""), "wt": m["worktree"]}
batches = []                                   # list of (tasks, big)
rest = []
for u in units:
    big = [t for t in u if info[t]["lines"] > maxl]
    batches += [([t], True) for t in big]       # oversized diff: own run, file by file
    small = [t for t in u if t not in big]
    if small: rest.append(small)
rest.sort(key=lambda u: -sum(info[t]["lines"] for t in u))
open_b = []                                     # first-fit decreasing, groups never split
for u in rest:
    ul = sum(info[t]["lines"] for t in u)
    for b in open_b:
        if len(b) + len(u) <= maxt and sum(info[t]["lines"] for t in b) + ul <= maxl:
            b.extend(u); break
    else:
        open_b.append(list(u))
batches += [(b, False) for b in open_b]
for k, (ts, big) in enumerate(batches, 1):
    p = [f"Repository: {repo}",
         "Review these tasks as one batch; they were built in parallel and must fit together."
         if len(ts) > 1 else "Review this task.", ""]
    dirs = set()
    for t in ts:
        i = info[t]
        p.append(f"- task {t}: diff {repo}/.delegate/{t}/diff.patch ({i['lines']} lines); "
                 f"spec {i['spec'] or '(none)'}; post-change code in worktree {i['wt']}")
        dirs.add(i["wt"])
        if i["spec"] and not os.path.realpath(i["spec"]).startswith(os.path.realpath(repo) + "/"):
            dirs.add(os.path.dirname(i["spec"]))
    if big:
        p += ["", "This diff is large. Review it file by file: search the patch for '^diff --git' to "
              "list the files, then read the patch one file's line range at a time."]
    open(f"{run}/b{k}.prompt", "w").write("\n".join(p) + "\n")
    open(f"{run}/b{k}.tasks", "w").write("\n".join(ts) + "\n")
    open(f"{run}/b{k}.dirs", "w").write("\n".join(sorted(dirs)) + "\n")
print(len(batches))
PY
)" || { echo "STOP: could not plan batches"; exit 2; }

# ---- 3. run all batches in parallel, one watchdog each -------------------------
run_batch() {  # <k>  — runs the reviewer for batch k in the foreground
  local k="$1" d
  DG_ADD=(); while read -r d; do [ -n "$d" ] && DG_ADD+=("$d"); done < "$RUN/b$k.dirs"
  cd "$REPO" || exit 1
  case "$BACKEND" in
    claude)
      local add=(); for d in ${DG_ADD[@]+"${DG_ADD[@]}"}; do add+=(--add-dir "$d"); done
      local eff=(); [ -n "$EFFORT" ] && eff=(--effort "$EFFORT")
      exec env -u CLAUDE_CODE_EFFORT_LEVEL claude -p --model "$MODEL" ${eff[@]+"${eff[@]}"} \
        --safe-mode --restricted --strict-mcp-config --disable-slash-commands \
        --tools "Read,Grep,Glob" --allowedTools "Read,Grep,Glob" --permission-mode dontAsk \
        --system-prompt-file "$HERE/reviewer-prompt.md" ${add[@]+"${add[@]}"} \
        --max-turns "$TURNS" --no-session-persistence --output-format json < "$RUN/b$k.prompt";;
    openrouter)
      local a=(python3 "$HERE/or_agent.py" --model "$MODEL" --prompt-file "$RUN/b$k.prompt"
               --system-file "$HERE/reviewer-prompt.md" --read-only --max-turns "$TURNS")
      [ -n "$EFFORT" ] && a+=(--effort "$EFFORT")
      for d in ${DG_ADD[@]+"${DG_ADD[@]}"}; do a+=(--add-dir "$d"); done
      exec "${a[@]}" < /dev/null;;
    *)  # commandcode / opencode: no read-only switch we can rely on, so the OS makes it read-only
      local scratch="$RUN/b$k.scratch"; mkdir -p "$scratch/tmp"
      local prompt; prompt="$(cat "$HERE/reviewer-prompt.md"; echo; echo "---"; echo; cat "$RUN/b$k.prompt")"
      printf '%s\n' "$prompt" > "$RUN/b$k.full"
      dg_build_cmd "$BACKEND" "$MODEL" "$prompt" "$RUN/b$k.full" "$TURNS" "$EFFORT" || exit 1
      DG_SB_WT="$(dg_real "$scratch")"; DG_SB_OUT="$DG_SB_WT"; DG_SB_TMP="$DG_SB_WT/tmp"; DG_SB_GITDIR="$DG_NO"
      DG_SB_EXTRA=("$DG_NO" "$DG_NO" "$DG_NO"); dg_fill_state "$BACKEND"
      TMPDIR="$DG_SB_TMP/" dg_sandbox_exec "${DG_CMD[@]}" < /dev/null;;
  esac
}
PIDS=()
for k in $(seq 1 "$NB"); do
  (
    ( run_batch "$k" ) > "$RUN/b$k.json" 2> "$RUN/b$k.err" &
    P=$!; ( sleep "$LIMIT"; kill -TERM "$P" ) 2>/dev/null & W=$!
    S=$(date +%s); wait "$P"; RC=$?; echo $(( $(date +%s) - S )) > "$RUN/b$k.secs"
    pkill -P "$W" 2>/dev/null; kill "$W" 2>/dev/null; wait "$W" 2>/dev/null
    python3 "$HERE/dg.py" parse "$BACKEND" "$RUN/b$k.json" "$RUN/b$k.err" "$RC" > "$RUN/b$k.result"
  ) &
  PIDS+=($!)
done
for p in "${PIDS[@]}"; do wait "$p"; done

# ---- 4. split replies into review.md files, print verdict lines ----------------
python3 - "$REPO" "$RUN" "$NB" "$MODEL" "$DG_BOARD" "$BACKEND" <<'PY'
import json, os, re, sys, time
repo, run, nb, model, board, backend = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
cost_lines = []
for k in range(1, nb + 1):
    tasks = open(f"{run}/b{k}.tasks").read().split()
    secs = (open(f"{run}/b{k}.secs").read().strip() if os.path.exists(f"{run}/b{k}.secs") else "?")
    try:
        r = json.load(open(f"{run}/b{k}.result"))
        text = r.get("finalText") or ""
    except Exception:
        r, text = {}, ""
    if not text or r.get("isError"):
        err = (open(f"{run}/b{k}.err", errors="replace").read() or text or "no output").strip()[-200:]
        for t in tasks:
            print(f"ERROR    {t}  reviewer failed (batch {k}): {err}"[:600])
        continue
    blocks = {m.group(1): m.group(2).strip()
              for m in re.finditer(r"<<<REVIEW\s+(\S+?)>>>\s*\n(.*?)<<<END>>>", text, re.S)}
    summ = {}
    cross = ""
    vm = re.search(r"<<<VERDICTS>>>\s*\n(.*?)<<<END>>>", text, re.S)
    for l in (vm.group(1).splitlines() if vm else []):
        l = l.strip()
        if l.upper().startswith("CROSS:"):
            cross = l[6:].strip()
        elif "|" in l:
            parts = [x.strip() for x in l.split("|", 2)]
            if len(parts) == 3: summ[parts[0]] = parts[2]
    verdicts = {}
    for t in tasks:
        body = blocks.get(t, "")
        lines = [x for x in body.splitlines() if x.strip()]
        last = lines[-1].strip() if lines else ""
        mv = re.fullmatch(r"\**VERDICT:\s*(APPROVE|CHANGES)\**", last)
        d = f"{repo}/.delegate/{t}"
        if mv:
            v = mv.group(1)
            open(f"{d}/review.md", "w").write("\n".join(lines[:-1]).rstrip() + f"\n\nVERDICT: {v}\n")
            os.replace(f"{run}/{t}.sha", f"{d}/review.sha")
        else:
            v = "ERROR"
            if body: open(f"{d}/review.md", "w").write(body + "\n")   # no verdict line: merge stays blocked
        verdicts[t] = v
        find = summ.get(t, "-") if v != "ERROR" else "no verdict in reviewer reply"
        print(f"{v:8} {t}  {find}"[:600])
    if cross and not cross.lower().startswith("none"):
        print(f"CROSS    {'+'.join(tasks)}  {cross}"[:600])
    u = r.get("usage") or {}
    tin, tout = u.get("inputTokens") or 0, u.get("outputTokens") or 0
    cost = r.get("costUsd")
    lines_n = sum(sum(1 for _ in open(f"{repo}/.delegate/{t}/diff.patch", errors="replace")) for t in tasks)
    cost_lines.append(f"batch{k} {len(tasks)} tasks/{lines_n} lines {tin//1000}k in/{tout//1000}k out "
                      f"{f'${cost:.3f} ' if cost is not None else ''}{secs}s")
    try:
        with open(board, "a") as f:
            f.write(json.dumps({"ts": int(time.time()), "repo": os.path.basename(repo), "type": "review",
                                "task": "+".join(tasks), "backend": backend, "model": model,
                                "status": " ".join(f"{t}:{v}" for t, v in verdicts.items()),
                                "seconds": int(secs) if secs.isdigit() else None, "diff_lines": lines_n,
                                "input_tokens": tin, "output_tokens": tout, "cost_usd": cost}) + "\n")
    except OSError:
        pass
if cost_lines:
    print("COST     " + "; ".join(cost_lines) + ". Full reviews: .delegate/<task>/review.md")
PY
