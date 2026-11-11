#!/usr/bin/env python3
"""dg.py — small helpers for the delegate scripts (standard library only).

  dg.py resolve  <config> <alias|backend:model>   -> "backend<TAB>model"
  dg.py presets  <config>                         -> one "alias<TAB>backend<TAB>model<TAB>label<TAB>default" per preset
  dg.py reviewer <config>                         -> "backend<TAB>model<TAB>effort"
  dg.py parse    <backend> <stdout> <stderr> <rc> -> normalized result JSON
  dg.py or-model <model-id>                       -> exit 1 if OpenRouter does not list it
"""
import json
import os
import sys
import urllib.request

WORKER_BACKENDS = ("commandcode", "opencode", "openrouter")
REVIEW_BACKENDS = WORKER_BACKENDS + ("claude",)


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except ValueError as e:
        sys.exit(f"{path} is not valid JSON: {e}")


def resolve(cfg_path, arg):
    presets = load(cfg_path).get("presets", {})
    if arg in presets:
        p = presets[arg]
        backend, model = p.get("backend"), p.get("model")
    elif ":" in arg and arg.split(":", 1)[0] in WORKER_BACKENDS:
        backend, model = arg.split(":", 1)
    else:
        known = ", ".join(sorted(presets)) or "none (no config.json yet)"
        sys.exit(f"unknown model '{arg}'. Use a preset alias ({known}) or backend:model-id "
                 f"with backend one of {', '.join(WORKER_BACKENDS)}")
    if backend not in WORKER_BACKENDS or not model:
        sys.exit(f"preset '{arg}' needs \"backend\" (one of {', '.join(WORKER_BACKENDS)}) and \"model\"")
    print(f"{backend}\t{model}")


def presets(cfg_path):
    cfg = load(cfg_path)
    for alias, p in cfg.get("presets", {}).items():
        print("\t".join([alias, p.get("backend", "?"), p.get("model", "?"), p.get("label") or "-",
                         "default" if alias == cfg.get("default") else "-"]))


def reviewer(cfg_path):
    r = load(cfg_path).get("reviewer", {})
    backend = os.environ.get("DELEGATE_REVIEW_BACKEND") or r.get("backend") or ""
    model = os.environ.get("DELEGATE_REVIEW_MODEL") or r.get("model") or ""
    effort = os.environ.get("DELEGATE_REVIEW_EFFORT") or r.get("effort") or ""
    if backend not in REVIEW_BACKENDS or not model:
        sys.exit("no reviewer configured: set \"reviewer\": {\"backend\": ..., \"model\": ...} in "
                 f"config.json (backend one of {', '.join(REVIEW_BACKENDS)})")
    print(f"{backend}\t{model}\t{effort}")


def parse(backend, out_path, err_path, rc):
    """Turn a backend's raw output into one shape:
    {finalText, usage: {inputTokens, outputTokens}, costUsd, turnLimit, isError}"""
    def read(p):
        try:
            with open(p, errors="replace") as f:
                return f.read()
        except OSError:
            return ""
    out, err, rc = read(out_path), read(err_path), int(rc)
    lines = [l for l in out.splitlines() if l.strip()]
    res = {"finalText": "", "usage": {"inputTokens": None, "outputTokens": None},
           "costUsd": None, "turnLimit": False, "isError": False}

    def last_json():
        try:
            return json.loads(lines[-1]) if lines else {}
        except ValueError:
            return {}

    if backend == "commandcode":
        r = last_json()
        res["finalText"] = r.get("finalText") or ""
        u = r.get("usage") or {}
        res["usage"] = {"inputTokens": u.get("inputTokens"), "outputTokens": u.get("outputTokens")}
        res["turnLimit"] = rc == 8 or "Reached maximum conversation turns" in err
    elif backend == "openrouter":
        r = last_json()
        for k in ("finalText", "usage", "costUsd", "turnLimit", "isError"):
            if k in r:
                res[k] = r[k]
    elif backend == "opencode":
        texts, order, tin, tout, cost = {}, [], 0, 0, 0.0
        for l in lines:
            try:
                e = json.loads(l)
            except ValueError:
                continue
            part = e.get("part") or {}
            if e.get("type") == "text" and part.get("text"):
                mid = part.get("messageID", "")
                if mid not in texts:
                    texts[mid] = []
                    order.append(mid)
                texts[mid].append(part["text"])
            elif e.get("type") == "step_finish":
                t = part.get("tokens") or {}
                c = t.get("cache") or {}
                tin += (t.get("input") or 0) + (c.get("read") or 0) + (c.get("write") or 0)
                tout += (t.get("output") or 0) + (t.get("reasoning") or 0)
                cost += part.get("cost") or 0
            elif e.get("type") == "error":
                res["isError"] = True
        if order:
            res["finalText"] = "\n".join(texts[order[-1]])
        res["usage"] = {"inputTokens": tin or None, "outputTokens": tout or None}
        res["costUsd"] = cost or None
    elif backend == "claude":
        try:
            r = json.loads(out)
        except ValueError:
            r = {}
        res["finalText"] = r.get("result") or ""
        u = r.get("usage") or {}
        res["usage"] = {
            "inputTokens": sum(u.get(k) or 0 for k in
                               ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")),
            "outputTokens": u.get("output_tokens") or 0}
        res["costUsd"] = r.get("total_cost_usd")
        res["isError"] = bool(r.get("is_error"))
    if not res["finalText"] and rc != 0:
        res["isError"] = True
    print(json.dumps(res))


def or_model(model):
    base = os.environ.get("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1").rstrip("/")
    try:
        req = urllib.request.Request(base + "/models", headers={
            "Authorization": "Bearer " + os.environ.get("OPENROUTER_API_KEY", "")})
        with urllib.request.urlopen(req, timeout=20) as r:
            ids = {m.get("id") for m in json.load(r).get("data", [])}
    except Exception as e:  # offline or the endpoint has no /models: let the run decide
        print(f"warning: could not list models at {base} ({e}); not checking '{model}'", file=sys.stderr)
        return
    if model not in ids:
        sys.exit(f"model not listed at {base}/models: {model}")


if __name__ == "__main__":
    cmds = {"resolve": resolve, "presets": presets, "reviewer": reviewer, "parse": parse, "or-model": or_model}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        sys.exit(__doc__)
    try:
        cmds[sys.argv[1]](*sys.argv[2:])
    except TypeError:
        sys.exit(__doc__)
