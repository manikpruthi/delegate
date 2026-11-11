# Install guide for AI agents

You are an AI coding agent and your user asked you to set up `delegate` from this repository.
Follow these steps in order. They are written so you can do the mechanical parts yourself and
know exactly where you must stop and ask the user.

## Ground rules

- **Ask before you install anything.** Never install a CLI, a package or a system tool without
  the user saying yes to that specific thing.
- **Never handle secrets.** Do not ask the user to paste an API key into the chat, do not read
  key files, do not print keys. When a key is needed, give the user the command to run
  themselves (step 3).
- **Do not log in for the user.** `cmd login`, `opencode auth login` and `claude` logins are
  interactive; the user runs them.
- Do not change anything outside the skill's target folder and `~/.config/delegate/`.
- If a step fails, show the user the exact output and stop. Do not work around it.

## 1. Check the platform

| Need | Check | If missing |
|---|---|---|
| macOS, or Linux with bubblewrap | `uname -s`; on Linux `command -v bwrap` | Linux: ask the user to install `bubblewrap` with their package manager. Windows is not supported (WSL2 counts as Linux). |
| git | `git --version` | ask the user to install it |
| Python 3.8+ | `python3 --version` | ask the user to install it |
| git identity | `git config --global user.name` and `user.email` | ask the user to set them; do not invent values |

Linux support is experimental (the author tested on macOS). Tell the user that if they are on Linux.

## 2. Choose the worker backend(s)

Workers can run on any of three backends. One is enough; several can be mixed in one swarm.
Check which the user already has, then **ask the user which they want to use**:

| Backend | Already set up when | To set it up (the user does this) |
|---|---|---|
| `openrouter` | `OPENROUTER_API_KEY` is set, or `~/.config/delegate/env` has it | Create a key at https://openrouter.ai/keys, then step 3. Needs no extra software. |
| `commandcode` | `command -v cmd` works and `cmd status` shows a login | Install Command Code (https://commandcode.ai), then `cmd login` |
| `opencode` | `command -v opencode` works and `opencode models` lists models | Install OpenCode (https://opencode.ai), then `opencode auth login` |

If none is set up, recommend `openrouter`: it needs only a key.

## 3. OpenRouter key (only if the user chose `openrouter`)

The scripts read `OPENROUTER_API_KEY` from the environment, or from `~/.config/delegate/env`.
Give the user these commands to run **in their own terminal** (not through you), then wait for
them to say it is done:

```bash
mkdir -p ~/.config/delegate && chmod 700 ~/.config/delegate
```

```bash
read -rsp "OpenRouter API key: " k && printf 'OPENROUTER_API_KEY=%s\n' "$k" > ~/.config/delegate/env && chmod 600 ~/.config/delegate/env && unset k
```

To use another OpenAI-compatible endpoint instead of OpenRouter, the user can add
`OPENROUTER_BASE_URL=https://.../v1` to the same file.

## 4. Copy the skill and create config.json

1. Pick the target folder for the agent the user will run `/delegate` from (the manager):

   | Manager agent | Target folder |
   |---|---|
   | Claude Code | `~/.claude/skills/delegate` |
   | OpenCode | `~/.config/opencode/skills/delegate` |
   | Command Code | `~/.commandcode/skills/delegate` |
   | Other | any folder the agent loads skills from, or any folder at all; then the user starts a task with "read `<folder>/SKILL.md` and follow it" |

   If that folder already exists, tell the user and ask before overwriting; `install.sh` keeps
   an existing `config.json`, `risk-patterns.txt` and `scoreboard.jsonl`.

2. Run `./install.sh <target-folder>` from this repository.

3. Build `<target-folder>/config.json` from `config.example.json`:
   - List the models each chosen backend really offers: `cmd --list-models`,
     `opencode models`, or `curl -s https://openrouter.ai/api/v1/models` (public, no key).
   - **Ask the user which models they want as workers** (suggest 2–3 cheap, fast coding models
     that support tool calling; show prices if the list has them). The ids in
     `config.example.json` are examples and may be out of date. Use exact ids only.
   - Write one preset per choice: `"alias": {"backend": "...", "model": "<exact id>", "label": "..."}`.
     Short aliases; the user types them as `@alias`. Set `"default"` to the one the user prefers.
     OpenCode ids have the form `provider/model`.
   - **Ask the user which model should review risky changes**, and set `"reviewer"`. It should
     be stronger than the workers. Options: `{"backend": "claude", "model": "<Claude model id>",
     "effort": "medium"}` if the Claude Code CLI is installed (best isolation), or any model on
     `openrouter`, `commandcode` or `opencode`.
   - Optionally ask for `"trusted_roots"`: folders (e.g. `~/Projects`) inside which the manager
     may approve a worker's request for extra write access without asking. Default `[]`.

## 5. Verify

Run `<target-folder>/doctor.sh`. It must end with `RESULT: ready`. `MISSING` lines marked
"optional" for backends the user did not choose are fine. Then, from this repository:

```bash
./tests/run.sh
```

It runs the whole flow (swarm, sandbox, review gate, merge) against a local mock model, with no
network and no cost, and must end with `0 failed`.

## 6. Tell the user

Report in a few lines: where the skill is installed, which backends and presets are configured,
which model reviews, and how to use it:

```
/delegate <task>              asks which model(s) to use
/delegate @alias <task>       uses that preset
/delegate @a,b <task>         mixed swarm
```

Also tell them: workers can read most of the disk and reach the network (the sandbox limits
writes, and blocks reading `~/.ssh`, `~/.gnupg` and `~/.aws`), so they should not point
workers at repositories whose contents must not be sent to the model provider.

## Updating and uninstalling

- Update: `git pull` in this repository, then `./install.sh <target-folder>` again.
- Uninstall: delete the target folder and, if it was created, `~/.config/delegate/`. Only do
  this when the user asks, and confirm the paths with them first.
