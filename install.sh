#!/usr/bin/env bash
# install.sh — copy the delegate skill into an agent's skills folder and run the setup check.
# It only copies files. It installs no software, asks for no keys and never overwrites an
# existing config.json or scoreboard.jsonl.
#
# Usage: ./install.sh [target-dir]
#   target-dir defaults to ~/.claude/skills/delegate (Claude Code). Other agents:
#     OpenCode       ~/.config/opencode/skills/delegate
#     Command Code   ~/.commandcode/skills/delegate
#     anything else  any folder; then tell the agent to read <folder>/SKILL.md
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skill"
DEST="${1:-$HOME/.claude/skills/delegate}"
mkdir -p "$DEST"
for f in SKILL.md worker.sh swarm.sh review.sh merge.sh doctor.sh lib.sh dg.py or_agent.py \
         worker.sb reviewer-prompt.md config.example.json; do
  cp "$SRC/$f" "$DEST/$f"
done
# risk-patterns.txt is meant to be edited: keep the user's copy if there is one
[ -f "$DEST/risk-patterns.txt" ] || cp "$SRC/risk-patterns.txt" "$DEST/risk-patterns.txt"
chmod +x "$DEST"/*.sh "$DEST"/*.py
echo "Installed to $DEST"
if [ -f "$DEST/config.json" ]; then echo "Kept existing $DEST/config.json"
else echo "Next: create $DEST/config.json from config.example.json (see INSTALL.md, step 4)"; fi
echo
"$DEST/doctor.sh" || true
