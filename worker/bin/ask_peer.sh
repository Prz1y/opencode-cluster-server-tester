#!/bin/bash
# A2A wrapper: delegates to ask_peer.py so the agent can call it via the bash tool.
exec python3 /root/ocws/bin/ask_peer.py "$@"
