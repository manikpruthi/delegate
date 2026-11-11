---
name: delegate
description: Act as a manager. Plan, split the work and hand implementation to cheap autonomous workers (any model via Command Code, OpenCode or OpenRouter, alone or as a mixed swarm) that run headless inside an OS-enforced sandbox limited to their own git worktree; then verify, approve access requests, get risky diffs reviewed, and merge. Use when the user says "/delegate" or asks for a worker swarm.
argument-hint: "[@alias[,alias]] <task>"
---

# /delegate — you manage, cheap workers build, a pinned reviewer checks risky diffs

Three roles:
- **Manager** — you, on whatever model this session runs. You plan, write specs, choose models,
  approve access, verify and merge. You do not write the implementation yourself unless a task
  fails twice or needs the whole picture.
- **Workers** — autonomous executors on cheap models: each gets one spec, edits files and runs
  commands on its own, cannot see this conversation, and is jailed to its own git worktree by
  the OS (macOS `sandbox-exec`, Linux `bwrap`). A worker runs on one of three backends:
  `commandcode` (the `cmd` CLI), `opencode` (the `opencode` CLI) or `openrouter` (a built-in
  agent loop that only needs an API key).
- **Reviewer** — `review.sh`: the reviewer model from `config.json`, run headless with a fresh,
  minimal context and no way to change anything. It reviews only high-risk diffs; you only ever
  see its short verdict lines.

**Cost model:** worker runs on flash-class models are cheap (cents per run). Almost all cost is
*your* turns: every wake-up re-reads this whole conversation. So: few tasks, one wait, one merge
call, no reading what a script already checked. A medium reasoning effort is enough for
managing. The reviewer keeps diffs out of your context: a diff you read is re-read on every
later turn, while the reviewer reads it once and hands back ≤ 600 characters per task. Each
reviewer run pays a fixed startup cost, so batching tasks pays that once per batch.

Files in this skill folder (the folder this SKILL.md is in; called `$SKILL` below — use its
absolute path in commands):
- `swarm.sh <repo> <manifest>` — runs all workers in parallel, returns once. **Use this.**
- `worker.sh <model> <repo> <task> <spec>` — one worker (used by swarm.sh).
- `review.sh <repo> <task|taskA+taskB>...` — batches and reviews high-risk tasks in parallel.
- `merge.sh <repo> [--test "<cmd>"] [--drop <name>]... [--unreviewed <name>]... <name>...` —
  review gate, commit, merge, test, clean up.
- `doctor.sh` — checks the setup; `doctor.sh --models` lists the model presets.
- `config.json` — model presets, default, reviewer, trusted roots (made from
  `config.example.json` at install time).
- `risk-patterns.txt` — path/content patterns that mark a task risk=high (editable).
  `reviewer-prompt.md` — the reviewer's whole system prompt.
- `lib.sh`, `dg.py`, `or_agent.py`, `worker.sb` — backend adapters, the OpenRouter agent, the
  macOS sandbox profile. You do not call these.
- `scoreboard.jsonl` — one line per finished task (backend, model, type, status, risk, time,
  tokens) and one `type: review` line per reviewer batch.

If `config.json` is missing or `doctor.sh` reports `not ready`, stop and tell the user to finish
the setup (INSTALL.md in the project this skill came from). Never ask the user to paste an API
key into the chat.

## 0. Pick the model(s) — always first, before any worker starts
1. Run `$SKILL/doctor.sh --models`. Each line is a preset: `ok` or `MISSING`, `@alias`,
   `backend:model-id`, label, `[default]`. `MISSING` presets are unavailable.
2. If the user wrote `@alias` or `@alias1,alias2` (exact match only), use those and skip the
   question. An unknown alias → say so and fall through to step 3. Never fuzzy-match free text
   like "glm 5.3"; several models share that prefix.
3. Otherwise **ask the user before doing anything else**, as a multiple-choice question that
   allows several answers if your harness has one (Claude Code: AskUserQuestion with
   multiSelect). One option per available preset, label = the full `backend:model-id`, with the
   default preset first, marked (Default). The user can pick one model, or several for a mixed
   swarm, or name another one as `backend:model-id` (exact id; `worker.sh` verifies it).
4. If the user asks to add or change a preset, edit `config.json` (exact ids only).
A manifest line can set `effort=` (reasoning effort); otherwise the backend's own default is
used. The `opencode` backend ignores `effort=` and `turns=`.

## 1. Size gate — decide whether to delegate at all
Estimate the work before planning. **Do it solo and tell the user in one line why** when:
- it is small: under ~300 changed lines, or fewer than 3 independent modules/file groups;
- it needs taste or the whole picture: architecture, UI/animation polish, narrative,
  cross-cutting refactors, subtle concurrency/security;
- it is a bug hunt you would have to read the whole codebase for anyway (small repo): finding
  the bugs is the work, the fixes are one-liners.
Delegate when the work is large and splits cleanly: 3+ independent modules, 500+ lines, tests
for many modules, migrations or repetitive edits across many files, or bug hunts in a codebase
too big to read yourself (then each worker **hunts and fixes** its own module; do not pre-read
everything and hand out a suspects list).
The repo must be a git repository with at least one commit and no uncommitted changes to
tracked files (merge.sh refuses otherwise). If it is not, tell the user; do not commit their
work for them without asking.

## 2. Plan, split, and assign models
- Read only what you need to define interfaces and file boundaries.
- **Default to 2–3 tasks** (max 4). Each worker pays a large fixed context cost; fewer, bigger
  tasks are cheaper. Aim for 1–6 files and < ~600 changed lines per task.
- Tasks must **touch disjoint files**. If B needs A's interface, put the signatures in both specs.
- With several models, assign per task:
  - **split** (default): alternate models across tasks.
  - **race**: for one hard or risky task, run the same spec on 2 models (`tag=<alias>`);
    keep the one that passes verification, preferring the smaller clean diff.
  - **route**: once `scoreboard.jsonl` has ≥ 5 rows per model for a task type, give that type to
    the model with the best pass rate, then speed.
- `effort=high` (or lower) on manifest lines for mechanical tasks (renames, boilerplate, simple
  tests): faster, same result.
Tell the user the plan in one line (tasks → models) before starting.

## 3. Write a spec per task (`<repo>/.delegate/specs/<task>.md`)
```
Task: <one sentence>
Context: <relevant design, signatures, conventions, with file paths>
Files allowed: <exact repo-relative paths, comma-separated; globs ok; new files named explicitly>
Do not: <things to leave alone>
Acceptance: <exact command(s) to run and expected result>
Risk: <high|low>   (optional)
```
`Files allowed` is **enforced by the script**: any other changed file turns the result into
`SCOPE_VIOLATION`. Keep it exact. `Risk: high` forces a review; the script also marks a task
risk=high on its own when a changed path or added line matches `risk-patterns.txt` (auth,
crypto/TLS, network parsing, SQL/transactions, deletes, concurrency, credentials), so
`Risk: low` cannot switch that off. The worker script appends the strict working rules (stay in
folder, NEED_ACCESS protocol, no git writes, PASS/FAIL line) itself. `.delegate/` is kept out of
git automatically.

## 4. Run the swarm — one call, one wait
Write `<repo>/.delegate/manifest.txt`, one line per task (`<model> <task> <spec> [options]`,
model = preset alias or `backend:model-id`):
```
deepseek  importer  .delegate/specs/importer.md  type=feature
or-glm    reports   .delegate/specs/reports.md   type=feature effort=high
or-glm    parser-r  .delegate/specs/parser.md    type=feature tag=glm
deepseek  e2e       .delegate/specs/e2e.md       type=test timeout=1800 idle=600
```
Defaults: `timeout=900` (wall clock) and `idle=300` (no output). Raise them only for tasks with
slow test suites or builds; a stuck worker then still can't block the swarm forever.
`turns=` sets the model's turn budget: 80 by default, 160 for `type=bugfix`, `bughunt` or `review`
(workers on many-item specs use up 80 before they report). Give those tasks `timeout=2700` or
more as well.
Then a **single** shell call, in the background if your harness supports it (Claude Code:
`run_in_background: true`), otherwise with a long enough timeout:
`$SKILL/swarm.sh <repo> <repo>/.delegate/manifest.txt`
Wait for it to finish. Never poll. Output is one short line per worker (details and the
worker's 5-line report only for non-PASS tasks) and a `SUMMARY` line. A PASS line ending in
`REVIEW (<why>)` is risk=high and goes to step 7. If every line is PASS with no `blocked_writes`
and no `REVIEW`, go straight to step 8. Full JSON is in `.delegate/last-swarm.json`; open it
only if you need a field the short lines don't show. `ERROR` means the worker never started
(unknown model, missing key or CLI, no sandbox): fix the cause, do not retry blindly.

## 5. Handle access requests (status `NEED_ACCESS`)
Read `<out>/escalation.json`. Decide yourself; do not ask the user unless rule C applies.
- **A. Auto-approve** when the path is inside the same repo or under a folder listed in
  `config.json` `trusted_roots`, the reason fits the spec, and it is not on the deny list.
  Re-run that task with `allow=<path>[:<path>...]` (max 3) and tell the user in one line what
  you approved and why.
- **B. Always deny**: `~/.ssh`, `~/.gnupg`, `~/.aws`, keychains, `~/.gitconfig`, any
  `.env`/credential/token file, shell rc files, `/System`, `/usr`, `/etc`, `/Library`, other
  users' folders, and anything the spec does not need. Do that part yourself (if appropriate)
  or drop it.
- **C. Ask the user** for anything else.
A read request usually means the spec lacked context — prefer adding that context to the spec.

## 6. Verify (cheaply)
The script already checked: changed files vs `Files allowed`, sandbox escapes, the PASS line.
- Run the **full acceptance / test suite once** after merging (merge.sh `--test` does it).
- **Keep your context small** — every byte you read is re-read on each later turn:
  - PASS tasks: read nothing. Non-PASS: the 5-line report is already in the swarm output;
    `report.txt` holds it too. Open `final.txt` only if the report is not enough.
  - Diffs: `git -C <worktree> diff --stat` first; open the full `diff.patch` (or one file of it)
    only when tests fail. Risky diffs go to the reviewer (step 7), not into your context.
  - Logs: always `tail -n 20` (`events.ndjson`, `stderr.log`, test output); never `cat` them.
  - Bug-hunt notes: read the worker's notes file, not its chat output.
- `SCOPE_VIOLATION` → check `out_of_scope`: if the extra file is harmless and needed, widen the
  spec and re-run; otherwise re-run with a note to leave that file alone.
- `TIMEOUT` (over `timeout=`, default 900 s) or `STALLED` (no output for `idle=`, default
  300 s): the watchdog killed the worker and its child commands; partial work is kept in the
  worktree and `diff.patch`. `tail -n 20` of `events.ndjson`/`stderr.log` shows where it
  hung. Common causes: a command that never exits (server, watch mode, interactive prompt) →
  add "never start servers or watch modes; use one-shot commands" to the spec; task too big →
  split it. Re-run once, on the **other** model if it stalled twice. Then take it over.
- `TURN_LIMIT`: the worker used up its turns before printing PASS/FAIL. Its work is kept. Check
  it yourself (build + tests in the worktree, outside the sandbox); merge if they pass, otherwise
  re-run with `turns=` doubled or split the task.
- `UNKNOWN`: the worker ended without a PASS/FAIL line (often an API error; the report shows
  the end of its stderr). Re-run once.
- Fail → short follow-up spec with the exact error output, re-run that task alone via
  `swarm.sh` with a one-line manifest (compact output; the worktree is reused). After **2 failed
  rounds, do the task yourself**.
- Bug-fix and bug-hunt swarms get a **second round with the models swapped** over the same file
  groups: each worker audits the other model's diff, finishes what is incomplete and writes
  tests the first worker did not think of. A worker's own tests share its blind spots. Add one
  tests worker in that round; it must not edit sources, only report what its tests expose.
- Test commands for `merge.sh --test` run with `pipefail`, so `cmd | tail -n 1` fails when
  `cmd` fails. Still keep the pipeline short; never add `|| true`.
- Bug-hunt tasks: every reported bug needs file:line plus a failing test; the worker's tests
  must fail on the original code. Discard anything unconfirmed; cheap workers invent bugs.

## 7. Review high-risk tasks — one call, one wait
After verification, collect the PASS tasks whose swarm line ends in `REVIEW` (same round) and
run them through the reviewer in a **single** shell call (background if supported):
`$SKILL/review.sh <repo> <task> [<taskA+taskB>] ...`
- Batching is done by the script: all tasks of the round in one reviewer run by default, at most
  4 tasks / ~1,500 diff lines per batch, extra batches run in parallel. Join tasks that share an
  interface with `+` so they always land in the same batch. A single diff over ~1,500 lines gets
  its own run and is reviewed file by file.
- Read **only** its output: one line per task (`APPROVE`/`CHANGES`/`ERROR`, up to 3 findings as
  file:line + problem + fix hint), at most one `CROSS` line per batch, and a `COST` line. Do not
  open `review.md` unless a finding line is too terse to act on.
- `CHANGES` → write a short follow-up spec from the findings, re-run that task with its worker
  (one-line manifest via `swarm.sh`; the re-run deletes the old review), then re-review
  **only the tasks that changed**, batched the same way. After **2 failed review rounds**, fix it
  yourself in the worktree and run `review.sh` once more (or merge it with `--unreviewed`
  and tell the user why).
- `ERROR` (reviewer failed or gave no verdict) → re-run `review.sh` for that task once.
- `CROSS` → the tasks disagree on an interface: fix the spec of the task that is wrong, re-run
  it, re-review both together (`a+b`).
- Low-risk tasks are **not** reviewed; the tests and the swapped-model audit round cover them.

## 8. Merge and clean up — one call
`$SKILL/merge.sh <repo> --test "<full test command>" [--drop <loser>] <task> [<task>...]`
**Review gate:** before touching anything it checks every risk=high task: `review.md` must end
with `VERDICT: APPROVE` and the reviewed diff must still match the worktree, otherwise it prints
`STOP: <task> ...` and merges nothing. `--unreviewed <task>` merges a risk=high task without
review; use it only when the user knowingly skips review, and say so in the report.
It commits each worktree with the repository's own git identity, merges the branches one at a
time into the current branch, runs the tests, and removes worktrees/branches **only if
everything passed**. It never pushes. It stops at the first error and leaves everything in
place. On `STOP: merge conflict` resolve it yourself (or re-run a task on top of the current
branch), on `STOP: tests failed` fix or re-run the culprit, then call merge.sh again with the
remaining tasks. Recovery: each worker's change is also in `<repo>/.delegate/<task>/diff.patch`.
Never hand-roll `git worktree remove --force` or chain cleanup onto a merge.

Report in 2–3 lines: tasks per model, first-time passes, retries, approvals, review verdicts
(and any `--unreviewed` merges), tasks taken back.
