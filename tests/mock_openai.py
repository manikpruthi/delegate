#!/usr/bin/env python3
"""mock_openai.py — a scripted stand-in for an OpenAI-compatible API, for offline tests.

The "model" id picks a scenario (mock/ok, mock/escape, mock/scope, mock/risky, mock/review);
the step is the number of assistant messages already in the request.
Usage: mock_openai.py <port-file>     (binds a free port on 127.0.0.1 and writes it there)
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = ["mock/ok", "mock/escape", "mock/scope", "mock/risky", "mock/review"]


def call(name, **args):
    return {"tool_calls": [{"id": "c1", "type": "function",
                            "function": {"name": name, "arguments": json.dumps(args)}}]}


def say(text):
    return {"content": text}


def find(pattern, text, default=""):
    m = re.search(pattern, text)
    return m.group(1) if m else default


def respond(model, messages):
    step = sum(1 for m in messages if m["role"] == "assistant")
    prompt = next(m["content"] for m in messages if m["role"] == "user")
    name = find(r"MOCK_NAME: (\S+)", prompt, "x")
    if model == "mock/review":
        tasks = re.findall(r"- task (\S+): diff (\S+)", prompt)
        if step == 0:
            return call("read_file", path=tasks[0][1])
        blocks = "".join(f"<<<REVIEW {t}>>>\nAdds a small module.\nNo blocking issues.\nVERDICT: APPROVE\n<<<END>>>\n\n"
                         for t, _ in tasks)
        verdicts = "".join(f"{t} | APPROVE | -\n" for t, _ in tasks)
        return say(f"{blocks}<<<VERDICTS>>>\n{verdicts}CROSS: none\n<<<END>>>")
    if model == "mock/escape":
        if step == 0:
            target = find(r"ESCAPE_TARGET: (\S+)", prompt)
            return call("bash", command=f"echo pwned > {target}; echo rc=$?")
        step -= 1
    if step == 0:
        path = {"mock/scope": "README.md", "mock/risky": f"src/{name}_auth.py"}.get(model, f"src/{name}.py")
        body = "def check(password):\n    return bool(password)\n" if model == "mock/risky" \
            else f"def {name}():\n    return '{name}'\n"
        return call("write_file", path=path, content=body)
    if step == 1:
        return call("bash", command="python3 -c 'print(1)'")
    return say(f"Added {name}.\nPASS acceptance ran")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send({"data": [{"id": m} for m in MODELS]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        msg = {"role": "assistant", "content": None, **respond(body["model"], body["messages"])}
        self.send({"choices": [{"message": msg}],
                   "usage": {"prompt_tokens": 1000, "completion_tokens": 50, "cost": 0.0001}})


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()
