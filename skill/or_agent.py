#!/usr/bin/env python3
"""or_agent.py — a small coding agent for OpenRouter (or any OpenAI-compatible
chat-completions API). Standard library only.

It gives the model a few tools, runs them in the current directory and loops until the
model answers without calling a tool. It has no permission prompts and no sandbox of its
own: worker.sh runs it inside the OS write jail. With --read-only (used for reviews) it
only offers read tools, limited to the current directory and --add-dir folders.

Env:  OPENROUTER_API_KEY   required
      OPENROUTER_BASE_URL  default https://openrouter.ai/api/v1
Output (stdout): one JSON line per event; the last line is the result:
  {"type":"result","finalText":...,"usage":{"inputTokens":n,"outputTokens":n},
   "costUsd":x,"turnLimit":bool,"isError":bool}
Exit: 0 done, 8 turn limit reached, 1 API or setup error.
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

MAX_OUT = 16000
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build", ".delegate"}


def emit(obj):
    print(json.dumps(obj), flush=True)


def clip(s, n=MAX_OUT):
    if len(s) <= n:
        return s
    h = n // 2
    return s[:h] + f"\n... [{len(s) - n} characters cut] ...\n" + s[-h:]


def fn(name, desc, props, required):
    return {"type": "function", "function": {
        "name": name, "description": desc,
        "parameters": {"type": "object", "properties": props, "required": required}}}


S, I, B = {"type": "string"}, {"type": "integer"}, {"type": "boolean"}
READ = fn("read_file", "Read a text file. Returns numbered lines.",
          {"path": S, "offset": {**I, "description": "first line, 1-based (default 1)"},
           "limit": {**I, "description": "max lines (default 400)"}}, ["path"])
TOOLS_WORK = [
    fn("bash", "Run a shell command in the workspace and return its exit code and output. "
               "One-shot commands only: no servers, watch modes or interactive programs.",
       {"command": S, "timeout": {**I, "description": "seconds, default 120, max 600"}}, ["command"]),
    READ,
    fn("write_file", "Create or overwrite a file with the given content.",
       {"path": S, "content": S}, ["path", "content"]),
    fn("edit_file", "Replace old_string with new_string in a file. old_string must match exactly "
                    "once unless replace_all is true.",
       {"path": S, "old_string": S, "new_string": S, "replace_all": B},
       ["path", "old_string", "new_string"]),
]
TOOLS_RO = [
    READ,
    fn("grep", "Search files for a regular expression. Returns path:line:text matches.",
       {"pattern": S, "path": {**S, "description": "file or folder (default .)"},
        "glob": {**S, "description": "only file names matching this, e.g. *.py"}}, ["pattern"]),
    fn("list_files", "List files under a folder, optionally filtered by a file-name glob.",
       {"path": S, "glob": S}, []),
]


class Agent:
    def __init__(self, a):
        self.a = a
        self.cwd = os.path.realpath(os.getcwd())
        self.roots = [self.cwd] + [os.path.realpath(d) for d in a.add_dir]
        self.tin = self.tout = 0
        self.cost = 0.0

    # ---- tools -------------------------------------------------------------
    def path(self, p):
        full = os.path.realpath(os.path.join(self.cwd, os.path.expanduser(p)))
        if self.a.read_only and not any(full == r or full.startswith(r + os.sep) for r in self.roots):
            raise ValueError(f"{p} is outside the folders you may read")
        return full

    def bash(self, command, timeout=120):
        timeout = max(1, min(int(timeout or 120), 600))
        p = subprocess.Popen(["bash", "-c", command], cwd=self.cwd, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            out, _ = p.communicate(timeout=timeout)
            return f"exit code {p.returncode}\n" + clip(out.decode(errors="replace"))
        except subprocess.TimeoutExpired:
            p.kill()
            try:
                out, _ = p.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                out = b""
            return f"TIMEOUT after {timeout}s (killed)\n" + clip(out.decode(errors="replace"))

    def read_file(self, path, offset=1, limit=400):
        offset, limit = max(1, int(offset or 1)), max(1, int(limit or 400))
        with open(self.path(path), errors="replace") as f:
            lines = f.read().splitlines()
        chunk = lines[offset - 1:offset - 1 + limit]
        body = "\n".join(f"{offset + i}\t{l}" for i, l in enumerate(chunk))
        more = len(lines) - (offset - 1 + len(chunk))
        return clip(body) + (f"\n[{more} more lines; total {len(lines)}]" if more > 0 else "")

    def write_file(self, path, content):
        full = self.path(path)
        os.makedirs(os.path.dirname(full) or ".", exist_ok=True)
        with open(full, "w") as f:
            f.write(content)
        return f"wrote {len(content)} characters to {path}"

    def edit_file(self, path, old_string, new_string, replace_all=False):
        full = self.path(path)
        with open(full) as f:
            text = f.read()
        n = text.count(old_string)
        if n == 0:
            return "ERROR: old_string not found (it must match the file exactly, including whitespace)"
        if n > 1 and not replace_all:
            return f"ERROR: old_string matches {n} times; add more context or set replace_all"
        with open(full, "w") as f:
            f.write(text.replace(old_string, new_string) if replace_all
                    else text.replace(old_string, new_string, 1))
        return f"edited {path} ({n if replace_all else 1} replacement{'s' if replace_all and n > 1 else ''})"

    def walk(self, path, glob):
        full = self.path(path or ".")
        if os.path.isfile(full):
            yield full
            return
        for root, dirs, files in os.walk(full):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            for name in sorted(files):
                if not glob or fnmatch.fnmatch(name, glob):
                    yield os.path.join(root, name)

    def grep(self, pattern, path=".", glob=None):
        rx, hits = re.compile(pattern), []
        for f in self.walk(path, glob):
            try:
                with open(f, errors="strict") as fh:
                    for i, line in enumerate(fh, 1):
                        if rx.search(line):
                            hits.append(f"{f}:{i}:{line.rstrip()[:300]}")
                            if len(hits) >= 200:
                                return "\n".join(hits) + "\n[stopped at 200 matches]"
            except (UnicodeDecodeError, OSError):
                continue
        return "\n".join(hits) or "no matches"

    def list_files(self, path=".", glob=None):
        out = []
        for f in self.walk(path, glob):
            out.append(f)
            if len(out) >= 500:
                out.append("[stopped at 500 files]")
                break
        return "\n".join(out) or "no files"

    def call(self, name, raw_args):
        allowed = {t["function"]["name"] for t in self.tools}
        if name not in allowed:
            return f"ERROR: unknown tool {name}"
        try:
            args = json.loads(raw_args or "{}")
        except ValueError as e:
            return f"ERROR: tool arguments are not valid JSON: {e}"
        try:
            return getattr(self, name)(**args)
        except Exception as e:  # report to the model, it can try again
            return f"ERROR: {type(e).__name__}: {e}"

    # ---- API ---------------------------------------------------------------
    def chat(self, messages):
        body = {"model": self.a.model, "messages": messages, "tools": self.tools}
        if self.a.effort:
            body["reasoning"] = {"effort": self.a.effort}
        req = urllib.request.Request(
            self.a.base.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + self.a.key, "Content-Type": "application/json",
                     "X-Title": "delegate"})
        last = ""
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=600) as r:
                    data = json.load(r)
                if data.get("choices"):
                    return data
                last = json.dumps(data.get("error") or data)[:500]
            except urllib.error.HTTPError as e:
                last = f"HTTP {e.code}: {e.read().decode(errors='replace')[:500]}"
                if e.code not in (408, 409, 429, 500, 502, 503, 504):
                    break
            except (urllib.error.URLError, OSError, ValueError) as e:
                last = f"{type(e).__name__}: {e}"
            time.sleep(3 * 2 ** attempt)
        raise RuntimeError(last)

    def run(self, system, prompt):
        self.tools = TOOLS_RO if self.a.read_only else TOOLS_WORK
        messages = [{"role": "system", "content": system}, {"role": "user", "content": prompt}]
        final, nudged, turn_limit = "", False, True
        for turn in range(1, self.a.max_turns + 1):
            data = self.chat(messages)
            u = data.get("usage") or {}
            self.tin += u.get("prompt_tokens") or 0
            self.tout += u.get("completion_tokens") or 0
            self.cost += u.get("cost") or 0
            msg = data["choices"][0].get("message") or {}
            calls = msg.get("tool_calls") or []
            keep = {"role": "assistant", "content": msg.get("content") or ""}
            if calls:
                keep["tool_calls"] = calls
            if msg.get("reasoning_details"):
                keep["reasoning_details"] = msg["reasoning_details"]
            messages.append(keep)
            if not calls:
                final = (msg.get("content") or "").strip()
                if final or nudged:
                    turn_limit = False
                    break
                nudged = True
                messages.append({"role": "user", "content": "Give your final report now."})
                continue
            for c in calls:
                f = c.get("function") or {}
                result = self.call(f.get("name", ""), f.get("arguments"))
                emit({"type": "tool", "turn": turn, "name": f.get("name"),
                      "args": clip(f.get("arguments") or "", 600), "result": clip(str(result), 1200)})
                messages.append({"role": "tool", "tool_call_id": c.get("id"), "content": str(result)})
        return final, turn_limit


def main():
    ap = argparse.ArgumentParser(description="Small coding agent for OpenRouter / OpenAI-compatible APIs.")
    ap.add_argument("--model", required=True)
    ap.add_argument("--prompt-file", required=True)
    ap.add_argument("--system-file", help="replace the built-in system prompt")
    ap.add_argument("--max-turns", type=int, default=80)
    ap.add_argument("--effort", default="", help="reasoning effort, passed through if set")
    ap.add_argument("--read-only", action="store_true", help="read tools only (reviews)")
    ap.add_argument("--add-dir", action="append", default=[], help="extra folder (repeatable)")
    a = ap.parse_args()
    a.key = os.environ.get("OPENROUTER_API_KEY", "")
    a.base = os.environ.get("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
    agent = Agent(a)

    def result(text, turn_limit=False, error=False):
        emit({"type": "result", "finalText": text,
              "usage": {"inputTokens": agent.tin, "outputTokens": agent.tout},
              "costUsd": round(agent.cost, 6) or None, "turnLimit": turn_limit, "isError": error})

    if not a.key:
        result("OPENROUTER_API_KEY is not set", error=True)
        return 1
    with open(a.prompt_file) as f:
        prompt = f.read()
    if a.system_file:
        with open(a.system_file) as f:
            system = f.read()
    else:
        system = ("You are an autonomous coding agent. Your workspace is " + agent.cwd + ". "
                  "Use the tools to read code, edit files and run commands until the task is done; "
                  "relative paths are relative to the workspace. Nobody can answer questions, so "
                  "decide yourself. When you are finished, reply without calling a tool.")
    try:
        final, turn_limit = agent.run(system, prompt)
    except Exception as e:
        print(f"or_agent: {e}", file=sys.stderr)
        result("", error=True)
        return 1
    if turn_limit:
        print("Reached maximum conversation turns", file=sys.stderr)
    result(final, turn_limit=turn_limit)
    return 8 if turn_limit else 0


if __name__ == "__main__":
    sys.exit(main())
