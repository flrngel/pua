#!/usr/bin/env python3
"""A pua exec agent with no dependencies: it answers the time and date (a "tool" the built-in
model does not have), echoes anything else, and hangs up when the caller says goodbye.

    pua listen --exec "python3 examples/agents/clock_agent.py"

Protocol (docs/integration.md): pua writes one JSON object per line on stdin; the agent writes
one per line on stdout and flushes. stderr is for logs. Replace `answer()` with your own model,
harness or tools.
"""
import json
import sys
from datetime import datetime


def send(**message):
    print(json.dumps(message), flush=True)


def answer(text):
    """Returns (reply, hang_up)."""
    words = text.lower()
    if any(w in words for w in ("bye", "goodbye", "hang up")):
        return "Thanks for calling. Goodbye!", True
    if "time" in words:
        return f"It's {datetime.now().strftime('%-I:%M %p')}.", False
    if "date" in words or "day" in words:
        return f"Today is {datetime.now().strftime('%A, %B %-d')}.", False
    return f"You said: {text.rstrip('.!?')}. Ask me the time or the date, or say goodbye.", False


for line in sys.stdin:
    msg = json.loads(line)
    kind = msg["type"]
    if kind == "call_start":
        print(f"call from {msg.get('caller') or 'unknown'} ({msg['direction']})", file=sys.stderr, flush=True)
    elif kind == "turn":
        reply, hang_up = answer(msg["text"])
        # Stream the reply in pieces; pua speaks each sentence as soon as it is complete.
        for piece in reply.split(" "):
            send(type="text", text=piece + " ")
        send(type="end_turn", hangup=hang_up)
    elif kind == "call_end":
        print(f"call ended: {msg.get('reason')} after {msg.get('seconds')} s", file=sys.stderr, flush=True)
        break
