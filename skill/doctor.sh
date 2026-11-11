#!/usr/bin/env bash
# doctor.sh — check that this machine can run /delegate, and list the model presets.
# Read-only: it installs nothing, changes nothing and never prints a key.
#
# Usage: doctor.sh            full check
#        doctor.sh --models   only the preset list (what the manager shows in the model picker)
# Lines: "ok|MISSING|warn  <what>  <detail>". Exit 0 when at least one worker backend, the
# sandbox and a config with one usable preset are in place; 1 otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
dg_load_env
row() { printf '%-8s %-12s %s\n' "$1" "$2" "$3"; }
FAIL=0; BACKENDS=""

presets() {
  local n=0 good=0 alias backend model label def why
  if [ ! -f "$DG_CONFIG" ]; then
    row MISSING config "no $DG_CONFIG — copy config.example.json to config.json and fill in the presets"
    return 1
  fi
  while IFS='	' read -r alias backend model label def; do
    [ -n "$alias" ] || continue
    n=$((n+1)); [ "$label" = - ] && label=""; [ "$def" = - ] && def=""
    if why="$(dg_model_ok "$backend" "$model" 2>&1)"; then
      good=$((good+1)); row ok "@$alias" "$backend:$model${label:+  ($label)}${def:+  [default]}"
    else
      row MISSING "@$alias" "$backend:$model  — $why"
    fi
  done <<EOF
$(python3 "$HERE/dg.py" presets "$DG_CONFIG" 2>&1)
EOF
  [ $n -gt 0 ] || row MISSING config "config.json has no presets"
  [ $good -gt 0 ]
}

if [ "${1:-}" = "--models" ]; then presets; exit $?; fi

echo "delegate doctor — $HERE"
case "$(dg_sandbox_kind)" in
  seatbelt) row ok sandbox "macOS sandbox-exec";;
  bwrap)    row warn sandbox "Linux bubblewrap (experimental, see README)";;
  none)     row warn sandbox "DELEGATE_NO_SANDBOX=1: workers would run with no write jail"; ;;
  *)        row MISSING sandbox "need sandbox-exec (macOS, built in) or bwrap (Linux: install bubblewrap)"; FAIL=1;;
esac
for t in git python3; do
  if command -v $t >/dev/null; then row ok $t "$($t --version 2>&1 | head -n 1)"; else row MISSING $t "install $t"; FAIL=1; fi
done
if [ -n "$(git config --global user.name 2>/dev/null)" ]; then row ok git-identity "set"
else row warn git-identity "git user.name is not set globally; merge.sh needs it set in each repo"; fi

if command -v cmd >/dev/null; then row ok commandcode "cmd $(cmd --version 2>/dev/null | head -n 1)"; BACKENDS="$BACKENDS commandcode"
else row MISSING commandcode "optional worker backend — Command Code CLI (cmd) not found"; fi
if command -v opencode >/dev/null; then row ok opencode "$(opencode --version 2>/dev/null | head -n 1)"; BACKENDS="$BACKENDS opencode"
else row MISSING opencode "optional worker backend — OpenCode CLI (opencode) not found"; fi
if [ -n "${OPENROUTER_API_KEY:-}" ]; then row ok openrouter "OPENROUTER_API_KEY is set"; BACKENDS="$BACKENDS openrouter"
else row MISSING openrouter "optional worker backend — OPENROUTER_API_KEY not set (env or $DG_ENV_FILE)"; fi
[ -n "$BACKENDS" ] || { row MISSING backends "no worker backend available: set up at least one of the three above"; FAIL=1; }

if REV="$(python3 "$HERE/dg.py" reviewer "$DG_CONFIG" 2>&1)"; then
  IFS='	' read -r rb rm re <<< "$REV"
  if why="$(dg_backend_ready "$rb")"; then row ok reviewer "$rb:$rm${re:+ (effort $re)}"
  else row MISSING reviewer "$rb:$rm — $why"; FAIL=1; fi
else
  row MISSING reviewer "$REV"; FAIL=1
fi
echo "presets:"
presets || FAIL=1
if [ $FAIL -eq 0 ]; then echo "RESULT: ready (worker backends:$BACKENDS)"; else echo "RESULT: not ready — fix the MISSING lines that are not marked optional"; fi
exit $FAIL
