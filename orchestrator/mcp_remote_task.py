#!/usr/bin/env python3
"""oc-cluster MCP stdio server.

Exposes the cluster task dispatcher as a native opencode tool:
  remote_task(worker, task, prompt, wait_seconds)

Runs INSIDE WSL (python3 stdlib only); opencode spawns it via
  wsl.exe -d <distro> -- python3 -u orchestrator/mcp_remote_task.py
Protocol: MCP 2024-11-05, newline-delimited JSON-RPC 2.0 over stdio.
"""
import json
import os
import subprocess
import sys
import tempfile

ROOT_WSL = "/mnt/d/opencode_trem/oc-cluster"
SCRIPT = ROOT_WSL + "/scripts/dispatch_task.sh"

TOOL = {
    "name": "remote_task",
    "description": (
        "Dispatch a task to an oc-cluster worker agent (opencode serve on a lab machine). "
        "Creates a session, sends the prompt, blocks until the agent finishes, returns its "
        "reply text plus tool-call trace and token usage. Use worker='list' to enumerate workers."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "worker": {"type": "string", "description": "Worker name (e.g. wk-71) or 'list'"},
            "task": {"type": "string", "description": "Short task id for tracing (prepended to the prompt)"},
            "prompt": {"type": "string", "description": "Full task prompt text for the worker agent"},
            "wait_seconds": {"type": "number", "description": "Max seconds to wait for completion (default 300)"},
        },
        "required": ["worker"],
    },
}


def dispatch(name, prompt_path, wait):
    cmd = ["bash", SCRIPT, name, prompt_path, str(wait)]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=wait + 120)
        return p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return "", "dispatch timed out after %ss" % (wait + 120), 124


def tool_call(args):
    worker = args.get("worker", "list")
    wait = args.get("wait_seconds", 300)
    try:
        wait = min(max(int(wait), 10), 1800)
    except (TypeError, ValueError):
        wait = 300

    if worker == "list":
        out, err, rc = dispatch("list", "", 10)
        return "Registered workers (NAME IP):\n" + (out or err)

    prompt = args.get("prompt")
    if not prompt:
        return "ERROR: prompt is required (or use worker='list')"
    task = args.get("task")
    if task:
        prompt = "[task: %s]\n%s" % (task, prompt)

    fd, pf = tempfile.mkstemp(prefix="oc_mcp_prompt_", suffix=".txt")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(prompt)
    try:
        out, err, rc = dispatch(worker, pf, wait)
    finally:
        try:
            os.unlink(pf)
        except OSError:
            pass

    text = (out or "").strip()
    if rc != 0 and err:
        text += "\n[stderr] " + err.strip()[:500]
    if len(text) > 12000:
        text = text[:12000] + "\n...[truncated]"
    return text or "(no output)"


def send(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(msg):
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "oc-remote-task", "version": "1.0.0"},
        }})
    elif method == "notifications/initialized":
        pass
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [TOOL]}})
    elif method == "tools/call":
        args = (msg.get("params") or {}).get("arguments") or {}
        try:
            text = tool_call(args)
            send({"jsonrpc": "2.0", "id": mid,
                  "result": {"content": [{"type": "text", "text": text}]}})
        except Exception as e:  # noqa: BLE001 - report errors to the client
            send({"jsonrpc": "2.0", "id": mid,
                  "result": {"content": [{"type": "text", "text": "ERROR: %s" % e}],
                             "isError": True}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid,
              "error": {"code": -32601, "message": "method not found: %s" % method}})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle(msg)


if __name__ == "__main__":
    main()
