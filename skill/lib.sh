#!/usr/bin/env bash
# lib.sh — shared helpers for the delegate scripts. Sourced, never run directly.
# Works with macOS's bash 3.2: no associative arrays, no mapfile.
#
# Backends (who runs the model):
#   commandcode  the Command Code CLI (`cmd`)
#   opencode     the OpenCode CLI (`opencode run --standalone`)
#   openrouter   or_agent.py, a built-in agent loop for OpenRouter or any OpenAI-compatible API
#   claude       the Claude Code CLI (`claude -p`), reviewer only

DG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DG_CONFIG="${DELEGATE_CONFIG:-$DG_HERE/config.json}"
DG_ENV_FILE="${DELEGATE_ENV_FILE:-$HOME/.config/delegate/env}"
DG_BOARD="${DELEGATE_SCOREBOARD:-$DG_HERE/scoreboard.jsonl}"
DG_NO=/nonexistent-delegate-path
DG_OS="$(uname -s)"

dg_real()  { python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"; }
dg_json_err() { python3 -c 'import json,sys;print(json.dumps({"error":sys.argv[1]}))' "$1"; }
dg_sha16() { python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'; }
dg_mtime() {
  if [ "$DG_OS" = Darwin ]; then stat -f %m "$1" 2>/dev/null || echo 0
  else stat -c %Y "$1" 2>/dev/null || echo 0; fi
}

# Load KEY=VALUE lines from ~/.config/delegate/env (e.g. OPENROUTER_API_KEY). A variable that
# is already set in the environment wins. The file is read as data, never executed.
dg_load_env() {
  [ -f "$DG_ENV_FILE" ] || return 0
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    k="${k#export }"; k="${k// /}"
    case "$k" in ''|\#*|*[!A-Za-z0-9_]*) continue;; esac
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [ -n "${!k:-}" ] || export "$k=$v"
  done < "$DG_ENV_FILE"
}

# dg_backend_ready <backend> — is the tool for this backend installed / configured?
# On failure prints the reason and returns 1.
dg_backend_ready() {
  case "$1" in
    commandcode) command -v cmd >/dev/null      || { echo "Command Code CLI (cmd) is not installed"; return 1; };;
    opencode)    command -v opencode >/dev/null || { echo "OpenCode CLI (opencode) is not installed"; return 1; };;
    claude)      command -v claude >/dev/null   || { echo "Claude Code CLI (claude) is not installed"; return 1; };;
    openrouter)  [ -n "${OPENROUTER_API_KEY:-}" ] \
                   || { echo "OPENROUTER_API_KEY is not set (export it, or put it in $DG_ENV_FILE)"; return 1; };;
    *) echo "unknown backend: $1"; return 1;;
  esac
}

# dg_model_ok <backend> <model> — exact-id check against what the backend lists.
# On failure prints the reason and returns 1. A model list that cannot be fetched
# (offline, API hiccup) does not fail the check for openrouter; the run itself will.
dg_model_ok() {
  dg_backend_ready "$1" || return 1
  case "$1" in
    commandcode) cmd --list-models 2>/dev/null | awk '{print $1}' | grep -qxF "$2" \
                   || { echo "model not listed by 'cmd --list-models': $2"; return 1; };;
    opencode)    opencode models 2>/dev/null | awk '{print $1}' | grep -qxF "${2%%#*}" \
                   || { echo "model not listed by 'opencode models': ${2%%#*}"; return 1; };;
    openrouter)  python3 "$DG_HERE/dg.py" or-model "$2" || return 1;;
    claude)      :;;
  esac
}

# Folders a backend's own CLI must be able to write (sessions, logs, caches).
dg_state_dirs() {
  case "$1" in
    commandcode) echo "$HOME/.commandcode";;
    opencode)    echo "$HOME/.local/share/opencode"; echo "$HOME/.local/state/opencode";;
  esac
}

dg_sandbox_kind() {
  if [ "$DG_OS" = Darwin ] && command -v sandbox-exec >/dev/null; then echo seatbelt
  elif [ "$DG_OS" = Linux ] && command -v bwrap >/dev/null; then echo bwrap
  elif [ "${DELEGATE_NO_SANDBOX:-}" = 1 ]; then echo none
  fi
}

# dg_sandbox_exec <command...> — replace this process with the command, inside a write jail.
# Writable: $DG_SB_WT (worktree), $DG_SB_OUT, $DG_SB_TMP, $DG_SB_GITDIR, DG_SB_EXTRA[0..2]
# (manager-approved), DG_SB_STATE[0..2] (backend state) and a few cache folders.
# Everything else is read-only; ~/.ssh, ~/.gnupg and ~/.aws are not readable either.
dg_sandbox_exec() {
  local p
  case "$(dg_sandbox_kind)" in
    seatbelt)
      exec sandbox-exec -f "$DG_HERE/worker.sb" \
        -D WORKTREE="$DG_SB_WT" -D OUTDIR="$DG_SB_OUT" -D TMP="$DG_SB_TMP" -D GITDIR="$DG_SB_GITDIR" \
        -D EXTRA1="${DG_SB_EXTRA[0]}" -D EXTRA2="${DG_SB_EXTRA[1]}" -D EXTRA3="${DG_SB_EXTRA[2]}" \
        -D STATE1="${DG_SB_STATE[0]}" -D STATE2="${DG_SB_STATE[1]}" -D STATE3="${DG_SB_STATE[2]}" \
        -D HOME="$HOME" "$@";;
    bwrap)   # Linux: experimental, see README "Known limitations"
      local a=(--ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --die-with-parent)
      for p in "$DG_SB_WT" "$DG_SB_OUT" "$DG_SB_TMP" "$DG_SB_GITDIR" "${DG_SB_EXTRA[@]}" "${DG_SB_STATE[@]}" \
               "$HOME/.cache" "$HOME/.npm"; do
        [ -e "$p" ] && a+=(--bind "$p" "$p")
      done
      for p in .ssh .gnupg .aws; do [ -d "$HOME/$p" ] && a+=(--tmpfs "$HOME/$p"); done
      exec bwrap "${a[@]}" "$@";;
    none)
      echo "delegate: DELEGATE_NO_SANDBOX=1, running WITHOUT a sandbox" >&2
      exec "$@";;
    *)
      echo "delegate: no sandbox tool found (macOS: sandbox-exec, Linux: bubblewrap 'bwrap'). Refusing to run." >&2
      exit 97;;
  esac
}

# dg_fill_state <backend> — sets DG_SB_STATE to that backend's state dirs (created if missing).
dg_fill_state() {
  DG_SB_STATE=("$DG_NO" "$DG_NO" "$DG_NO")
  local i=0 d
  while read -r d; do
    [ -n "$d" ] || continue
    mkdir -p "$d" 2>/dev/null; DG_SB_STATE[$i]="$(dg_real "$d")"; i=$((i+1))
  done <<EOF
$(dg_state_dirs "$1")
EOF
}

# dg_build_cmd <backend> <model> <prompt> <prompt-file> <turns> <effort> — sets DG_CMD.
# Extra workspace folders come from the DG_ADD array (may be empty).
dg_build_cmd() {
  local backend="$1" model="$2" prompt="$3" pfile="$4" turns="$5" effort="$6" d
  case "$backend" in
    commandcode)
      DG_CMD=(cmd -p "$prompt" -m "$model")
      [ -n "$effort" ] && DG_CMD+=(--effort "$effort")
      for d in ${DG_ADD[@]+"${DG_ADD[@]}"}; do DG_CMD+=(--add-dir "$d"); done
      DG_CMD+=(--yolo -t --no-session --max-turns "$turns" --output-format json);;
    opencode)
      # --standalone is required: without it the tools run in OpenCode's background service,
      # outside the sandbox. OpenCode has no turn cap; the watchdog timeout covers that.
      DG_CMD=(opencode run --standalone --auto --format json -m "$model" "$prompt");;
    openrouter)
      DG_CMD=(python3 "$DG_HERE/or_agent.py" --model "$model" --prompt-file "$pfile" --max-turns "$turns")
      [ -n "$effort" ] && DG_CMD+=(--effort "$effort")
      for d in ${DG_ADD[@]+"${DG_ADD[@]}"}; do DG_CMD+=(--add-dir "$d"); done;;
    *) echo "delegate: backend '$backend' cannot run workers" >&2; return 1;;
  esac
}
