#!/usr/bin/env python3
"""make test-flows-e2e: the Flows runner on the real installed Pi, in a pty (flows.md, step 3b).

A fake OpenAI-compatible model server answers with SSE chat-completion chunks and logs every
request body. Pi runs with a temporary HOME and PI_CODING_AGENT_DIR (models.json names the fake
provider, so the children reach it too) and loads only akit-flow.ts. The checks read files, not
the screen: the run record, the child session files, the server's request log and the UI log the
runner writes when AKIT_FLOW_UI_LOG is set.

Proves on real Pi: /flow runs a 2-step flow; each child loads akit-flow-handoff.ts and calls
flow_handoff; the guard blocks a forbidden tool call; the step row is set below the editor; the
alt+1 shortcut opens the step overlay and Esc closes it; built-in keys still work (Enter submits
a prompt, ctrl+d quits) and Pi reports no shortcut conflict.
"""
import http.server
import json
import os
import pty
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
FLOWS = os.path.join(REPO, "AKitCore", "Sources", "AKitRender", "Resources", "flows")


def find_pi():
    """The real node-installed pi: the mise shim fails under a changed HOME."""
    if os.environ.get("PI_BIN"):
        return os.environ["PI_BIN"]
    path = shutil.which("pi")
    if path:
        real = os.path.realpath(path)
        if real.endswith(".js"):
            return real
    base = os.path.expanduser("~/.local/share/mise/installs/node")
    for version in sorted(os.listdir(base), reverse=True) if os.path.isdir(base) else []:
        cli = os.path.join(base, version, "lib", "node_modules", "@earendil-works", "pi-coding-agent", "dist", "bundle", "cli.js")
        if os.path.exists(cli):
            return cli
    sys.exit("make test-flows-e2e: no real pi found; set PI_BIN to Pi's cli.js")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    return port if port != 18765 else free_port()


REQUESTS = []


def text_of(message):
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


def answer(body):
    """The fake model: plan calls bash (its paths rule out bash), then flow_handoff; code calls flow_handoff."""
    messages = body.get("messages", [])
    first_user = next((text_of(m) for m in messages if m.get("role") == "user"), "")
    tools_done = [m for m in messages if m.get("role") == "tool"]
    calls = [c["function"]["name"] for m in messages if m.get("role") == "assistant" for c in (m.get("tool_calls") or [])]
    handoff = {"goal": "g", "done": ["d"], "files": [], "open_questions": [], "notes": "n", "outcome": "done", "reason": ""}
    if 'step "plan"' in first_user:
        if not calls:
            return ("tool", "bash", {"command": "echo forbidden"})
        if "flow_handoff" not in calls:
            return ("tool", "flow_handoff", handoff)
        return ("text", "plan finished", None)
    if 'step "code"' in first_user:
        if "flow_handoff" not in calls:
            return ("tool", "flow_handoff", handoff)
        return ("text", "code finished", None)
    return ("text", "parent reply" if not tools_done else "ok", None)


class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"data": [{"id": "m", "object": "model"}]}).encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        REQUESTS.append(body)
        kind, name, args = answer(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def chunk(delta, finish=None, usage=None):
            data = {"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "m",
                    "choices": [] if usage else [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if usage:
                data["usage"] = usage
            self.wfile.write(f"data: {json.dumps(data)}\n\n".encode())

        if kind == "tool":
            chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": f"call_{len(REQUESTS)}", "type": "function",
                                                        "function": {"name": name, "arguments": json.dumps(args)}}]})
            chunk({}, "tool_calls")
        else:
            chunk({"role": "assistant", "content": name})
            chunk({}, "stop")
        # The parent's own prompt gets other numbers than the children's, so the A7 fixture can
        # tell whose tokens a session file holds.
        parent = any("hello e2e" in text_of(m) for m in body.get("messages", []))
        chunk({}, usage={"prompt_tokens": 777 if parent else 1200, "completion_tokens": 7 if parent else 30,
                         "total_tokens": 784 if parent else 1230})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


class Pty:
    def __init__(self, argv, env, cwd):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execve(argv[0], argv, env)
        self.out = b""

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    return
                if not data:
                    return
                self.out += data

    def send(self, data, wait=0.3):
        try:
            os.write(self.fd, data.encode() if isinstance(data, str) else data)
        except OSError:
            sys.exit("Pi exited early; its last output:\n" + self.out.decode("utf-8", "replace")[-3000:])
        self.pump(wait)

    def exited(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            self.pump(0.1)
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return True
        return False


def until(predicate, seconds, term):
    end = time.time() + seconds
    while time.time() < end:
        term.pump(0.2)
        if predicate():
            return True
    return False


def jsonl(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def main():
    pi_cli = find_pi()
    # The real node, not a mise shim (shims fail under the temporary HOME).
    node_bin = os.path.dirname(subprocess.run(["node", "-p", "process.execPath"], capture_output=True, text=True, check=True).stdout.strip())
    version = subprocess.run([pi_cli, "--version"], capture_output=True, text=True,
                             env={**os.environ, "PATH": f"{node_bin}:{os.environ.get('PATH', '')}"}).stdout.strip()
    root = os.path.realpath(tempfile.mkdtemp(prefix="akit-flow-e2e-"))
    failures = []

    def check(ok, what):
        print(("ok    " if ok else "FAIL  ") + what)
        if not ok:
            failures.append(what)

    port = free_port()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Model)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    term = None
    try:
        home = os.path.join(root, "home")
        agent = os.path.join(home, ".pi", "agent")
        project = os.path.join(root, "project")
        os.makedirs(agent)
        os.makedirs(os.path.join(project, ".pi", "flows"))
        with open(os.path.join(agent, "models.json"), "w") as f:
            json.dump({"providers": {"fake": {"baseUrl": f"http://127.0.0.1:{port}/v1", "api": "openai-completions", "apiKey": "fake",
                                               "models": [{"id": "m", "name": "Fake", "contextWindow": 100000, "maxTokens": 4096}]}}}, f)
        with open(os.path.join(agent, "settings.json"), "w") as f:
            json.dump({"lastChangelogVersion": version or "1.0.4", "defaultProvider": "fake", "defaultModel": "m"}, f)
        flow = {"akit-flow-format": 1, "name": "feature", "minPi": "1.0.4", "steps": [
            {"id": "plan", "agent": "planner", "model": "fake/m", "tools": ["read", "bash"], "paths": ["docs/**"]},
            {"id": "code", "agent": "implementer", "model": "fake/m"},
        ]}
        with open(os.path.join(project, ".pi", "flows", "feature.yaml"), "w") as f:
            json.dump(flow, f)
        git_env = {**os.environ, "HOME": home, "GIT_AUTHOR_NAME": "E2E", "GIT_COMMITTER_NAME": "E2E",
                   "GIT_AUTHOR_EMAIL": "e2e@example.com", "GIT_COMMITTER_EMAIL": "e2e@example.com"}
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=project, check=True, env=git_env)
        subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", "init"], cwd=project, check=True, env=git_env)
        ui_log = os.path.join(root, "ui.jsonl")
        env = {**git_env, "PATH": f"{node_bin}:/usr/bin:/bin", "PI_CODING_AGENT_DIR": agent, "TERM": "xterm-256color",
               "PI_OFFLINE": "1", "PI_SKIP_VERSION_CHECK": "1", "AKIT_FLOW_PI": pi_cli, "AKIT_FLOW_UI_LOG": ui_log}
        argv = [pi_cli, "-ne", "-ns", "-e", os.path.join(FLOWS, "akit-flow.ts"), "--model", "fake/m"]
        term = Pty(argv, env, project)
        term.pump(4)

        runs = os.path.join(project, ".pi", "akit-flow", "runs")

        def run_folder():
            names = sorted(os.listdir(runs)) if os.path.isdir(runs) else []
            return os.path.join(runs, names[-1]) if names else None

        def events():
            folder = run_folder()
            return jsonl(os.path.join(folder, "events.jsonl")) if folder else []

        term.send("/flow feature add a CSV export", 0.5)
        term.send("\r", 0.5)
        ended = until(lambda: any(e.get("type") == "run-end" for e in events()), 90, term)
        check(ended, "/flow runs the 2-step flow to its end")
        ev = events()
        ends = [e for e in ev if e.get("type") == "step-end"]
        check([e.get("step") for e in ends] == ["plan", "code"] and all(e.get("outcome") == "done" for e in ends),
              "both steps end done, in order")
        check(next((e.get("stop") for e in ev if e.get("type") == "run-end"), None) == "done", "the run stops as done")
        folder = run_folder() or root
        handoffs = sorted(os.listdir(os.path.join(folder, "handoffs"))) if os.path.isdir(os.path.join(folder, "handoffs")) else []
        check(len([h for h in handoffs if h.endswith(".json")]) == 2, "each child wrote its handoff through flow_handoff")
        check(not any(e.get("rule") in ("handoff-missing", "handoff-fallback") for e in ev), "no handoff fallback or rerun")
        blocked = [e for e in ev if e.get("type") == "deviation" and e.get("action") == "blocked"]
        check(any(e.get("step") == "plan" and e.get("tool") == "bash" and e.get("rule") == "bash" for e in blocked),
              "the guard blocked bash in the plan step on real Pi, logged as a deviation")
        tool_results = [m for r in REQUESTS for m in r.get("messages", []) if m.get("role") == "tool"]
        check(any("AKit flow guard" in text_of(m) for m in tool_results), "the model got the guard's reason as the tool result")
        sessions = os.listdir(os.path.join(folder, "sessions")) if os.path.isdir(os.path.join(folder, "sessions")) else []
        check(len([s for s in sessions if s.endswith(".jsonl")]) >= 2, "children keep their session files")

        ui = jsonl(ui_log)
        widgets = [u for u in ui if u.get("call") == "setWidget" and u.get("lines")]
        check(bool(widgets) and widgets[-1].get("placement") == "belowEditor", "the step row is set below the editor")
        last_row = widgets[-1]["lines"][0] if widgets else ""
        check("1 plan ✓" in last_row and "2 code ✓" in last_row and "⚠ 1" in last_row, f"the row shows both steps done and 1 deviation: {last_row!r}")
        shortcuts = next((u.get("keys") for u in ui if u.get("call") == "shortcuts"), [])
        check("alt+1" in shortcuts, f"step shortcuts registered: {shortcuts}")

        term.send("\x1b1", 1.0)
        check(until(lambda: any(u.get("call") == "overlay" and u.get("state") == "open" and u.get("step") == 1 for u in jsonl(ui_log)), 5, term),
              "alt+1 opens the overlay of step 1")
        opened = next((u for u in jsonl(ui_log) if u.get("call") == "overlay" and u.get("state") == "open"), {})
        check(any("bash" in line for line in opened.get("lines", [])), "the overlay lists the child's tool calls")
        term.send("\x1b", 1.0)
        check(until(lambda: any(u.get("call") == "overlay" and u.get("state") == "closed" for u in jsonl(ui_log)), 5, term),
              "Esc closes the overlay")

        before = len(REQUESTS)
        term.send("hello e2e", 0.5)
        term.send("\r", 0.5)
        check(until(lambda: any("hello e2e" in text_of(m) for r in REQUESTS[before:] for m in r.get("messages", [])), 30, term),
              "Enter (built-in submit) still sends a prompt")
        term.pump(2)
        screen = term.out.decode("utf-8", "replace")
        check("conflicts with built-in" not in screen and "Extension shortcut conflict" not in screen, "Pi reports no shortcut conflict")
        term.send("\x04", 0.5)
        check(term.exited(15), "ctrl+d (built-in exit) still quits Pi")
        term = None
        # AKIT_FLOW_E2E_KEEP=<folder>: keep the parent's session file and the run's child sessions
        # (the A7 fixture, fixtures/flow-runs/a7/). Only session files: no keys or config.
        keep = os.environ.get("AKIT_FLOW_E2E_KEEP")
        if keep and not failures:
            parents = [os.path.join(d, n) for d, _, names in os.walk(os.path.join(agent, "sessions")) for n in names if n.endswith(".jsonl")]
            shutil.rmtree(keep, ignore_errors=True)
            os.makedirs(os.path.join(keep, "children"))
            for path in parents:
                shutil.copy(path, os.path.join(keep, "parent.jsonl"))
            for name in sessions:
                if name.endswith(".jsonl"):
                    shutil.copy(os.path.join(folder, "sessions", name), os.path.join(keep, "children", name))
    finally:
        if term is not None:
            try:
                os.kill(term.pid, signal.SIGKILL)
            except OSError:
                pass
        server.shutdown()
        if failures:
            print(f"kept for inspection: {root}")
        else:
            shutil.rmtree(root, ignore_errors=True)
    print(f"Pi {version}: {'all checks passed' if not failures else f'{len(failures)} check(s) failed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
