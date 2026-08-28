#!/usr/bin/env python3
"""A2A ask_peer: send a machine-parsed JSON request to a peer worker's opencode agent.
Usage:
  ask_peer.py --peer wk-2 --task TASK-ID --intent query --subject "one line" --depth 1 --body "full message"
Prints the peer's reply text to stdout. Never exits non-zero on A2A errors (model must see the error text).
"""
import argparse
import base64
import datetime
import json
import os
import sys
import urllib.request
import urllib.error

CFG = "/root/ocws/oc_tasks/a2a/peers.json"
STATE = "/root/ocws/oc_tasks/a2a/sessions.json"
LEDGER = "/root/ocws/oc_tasks/journal/a2a.jsonl"


def fail(msg):
    print("A2A failed: " + msg)
    sys.exit(0)


def http(url, password, method="GET", payload=None, timeout=180):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("content-type", "application/json")
    req.add_header("authorization", "Basic " + base64.b64encode(("opencode:" + password).encode()).decode())
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode() or "{}")


def extract_assistant_text(obj):
    texts = []

    def walk(node):
        if isinstance(node, list):
            for x in node:
                walk(x)
        elif isinstance(node, dict):
            info = node.get("info")
            if isinstance(info, dict) and info.get("role") == "assistant" and isinstance(node.get("parts"), list):
                for p in node["parts"]:
                    if isinstance(p, dict) and p.get("type") == "text" and isinstance(p.get("text"), str):
                        texts.append(p["text"])
            if node.get("role") == "assistant" and isinstance(node.get("parts"), list):
                for p in node["parts"]:
                    if isinstance(p, dict) and p.get("type") == "text" and isinstance(p.get("text"), str):
                        texts.append(p["text"])
            for v in node.values():
                walk(v)

    walk(obj)
    return texts[-1] if texts else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--peer", required=True)
    ap.add_argument("--task", required=True)
    ap.add_argument("--intent", required=True, choices=["query", "request", "report"])
    ap.add_argument("--subject", required=True)
    ap.add_argument("--depth", type=int, required=True)
    ap.add_argument("--body", required=True)
    args = ap.parse_args()

    try:
        cfg = json.load(open(CFG))
    except Exception as e:
        return fail("config unreadable: %s" % e)
    self_id = cfg.get("self", "?")
    peer = cfg.get("peers", {}).get(args.peer)
    if not peer:
        return fail("unknown peer %r; known: %s" % (args.peer, ", ".join(cfg.get("peers", {}))))
    if args.peer == self_id:
        return fail("cannot ask yourself")
    if args.depth >= 2:
        return fail("A2A depth limit reached (depth>=2): answer from local knowledge instead")

    base = peer["url"].rstrip("/")
    pw = peer["password"]

    try:
        sessions = json.load(open(STATE))
    except Exception:
        sessions = {}
    sid = sessions.get(args.peer)
    reused = True
    if not sid:
        try:
            created = http(base + "/session", pw, "POST", {}, 15)
        except Exception as e:
            return fail("peer session create: %s" % e)
        sid = created.get("id")
        if not sid:
            return fail("peer session create: no id")
        sessions[args.peer] = sid
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        json.dump(sessions, open(STATE, "w"), indent=2)
        reused = False

    envelope = (
        "[A2A] "
        + json.dumps({
            "v": 1, "from": self_id, "task": args.task, "depth": args.depth,
            "intent": args.intent, "subject": args.subject, "body": args.body,
        }, ensure_ascii=False)
        + '\nYou are answering a peer agent, not a human. Reply with STRICT JSON only, no prose outside JSON: {"status":"answered|partial|refused","body":"<your answer>","evidence":["<file path or command output snippet>"]}'
    )

    t0 = datetime.datetime.utcnow()
    try:
        sent = http(base + "/session/%s/message" % sid, pw, "POST",
                    {"parts": [{"type": "text", "text": envelope}]}, 180)
    except Exception as e:
        ledger({"ts": t0.isoformat() + "Z", "dir": "out", "from": self_id, "to": args.peer,
                "task": args.task, "intent": args.intent, "subject": args.subject,
                "depth": args.depth, "status": "error", "error": str(e)})
        return fail("peer message post: %s" % e)

    reply = extract_assistant_text(sent)
    if not reply:
        try:
            hist = http(base + "/session/%s/message" % sid, pw, "GET", None, 15)
            reply = extract_assistant_text(hist)
        except Exception:
            pass
    if not reply:
        return fail("peer returned no text (session %s)" % sid)

    status = "unknown"
    import re
    m = re.search(r'"status"\s*:\s*"([^"]+)"', reply)
    if m:
        status = m.group(1)
    ms = int((datetime.datetime.utcnow() - t0).total_seconds() * 1000)
    ledger({"ts": t0.isoformat() + "Z", "dir": "out", "from": self_id, "to": args.peer,
            "task": args.task, "intent": args.intent, "subject": args.subject,
            "depth": args.depth, "status": status, "ms": ms, "session": sid, "reused": reused})

    print("Peer %s replied in %dms (session %s%s):\n%s" % (args.peer, ms, sid, ", reused" if reused else ", new", reply))


def ledger(entry):
    try:
        os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
        with open(LEDGER, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


if __name__ == "__main__":
    main()
