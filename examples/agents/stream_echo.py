#!/usr/bin/env python3
"""A minimal voice agent for `pua stream` / `pua listen --stream`: a WebSocket server that speaks
Twilio Media Streams messages. It repeats each caller phrase back once the caller pauses, and
stops talking as soon as the caller talks over it (`clear`).

    pip install websockets
    python3 examples/agents/stream_echo.py          # ws://127.0.0.1:8765
    pua listen --stream ws://127.0.0.1:8765

Replace the echo with your speech-to-speech model or voice pipeline. Frameworks that already
support Twilio Media Streams (for example Pipecat's TwilioFrameSerializer) work the same way;
see docs/integration.md.
"""
import asyncio
import base64
import json
import math
import sys

import websockets

SILENCE_RMS = 400       # 16-bit RMS below this is a pause
PAUSE_CHUNKS = 35       # 35 x 20 ms = 0.7 s of quiet ends a phrase


def _ulaw_to_linear(byte):
    u = ~byte & 0xFF
    magnitude = ((((u & 0x0F) << 3) + 0x84) << ((u >> 4) & 0x07)) - 0x84
    return -magnitude if u & 0x80 else magnitude


ULAW = [_ulaw_to_linear(b) for b in range(256)]


def rms(ulaw):
    return math.sqrt(sum(ULAW[b] ** 2 for b in ulaw) / max(1, len(ulaw)))


async def call(ws):
    stream_sid, phrase, quiet, speaking = None, bytearray(), 0, False
    async for raw in ws:
        msg = json.loads(raw)
        event = msg["event"]
        if event == "start":
            stream_sid = msg["streamSid"]
            print("call", msg["start"].get("customParameters"), file=sys.stderr)
        elif event == "media":
            ulaw = base64.b64decode(msg["media"]["payload"])
            loud = rms(ulaw) > SILENCE_RMS
            if loud and speaking:               # barge-in: drop what is still queued
                await ws.send(json.dumps({"event": "clear", "streamSid": stream_sid}))
                speaking = False
            if loud or phrase:
                phrase += ulaw
                quiet = 0 if loud else quiet + 1
            if phrase and quiet >= PAUSE_CHUNKS:
                for i in range(0, len(phrase), 160):
                    payload = base64.b64encode(bytes(phrase[i:i + 160])).decode()
                    await ws.send(json.dumps({"event": "media", "streamSid": stream_sid, "media": {"payload": payload}}))
                await ws.send(json.dumps({"event": "mark", "streamSid": stream_sid, "mark": {"name": "echo"}}))
                phrase, quiet, speaking = bytearray(), 0, True
        elif event == "mark":
            speaking = False                    # the echo finished playing
        elif event == "stop":
            print("call ended", file=sys.stderr)
            break


async def main(port):
    async with websockets.serve(call, "127.0.0.1", port):
        print(f"ws://127.0.0.1:{port}", file=sys.stderr)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main(int(sys.argv[1]) if len(sys.argv) > 1 else 8765))
