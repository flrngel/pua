# Put your agent on a phone call

pua handles the phone: dialing, answering, getting audio in and out of the call, switching the
Phone app's microphone, recording, and the after-call hooks. Your agent plugs in at one of three
levels:

| Your agent | Attach with | pua does | Your agent does |
| --- | --- | --- | --- |
| **Text in, text out**: an LLM harness, a tool-using agent, a rules bot | `--exec CMD` | Phone, speech recognition, voice, turn-taking, recording | The replies |
| **A voice agent**: speech-to-speech, its own STT/TTS pipeline, a bot built for Twilio | `--stream URL` | Phone, audio transport, playback queue, recording | All the audio |
| **Anything else** | `pua audio-stream` and `pua call …` | The audio path only | Everything else |

All three work on both kinds of call:

```sh
pua converse --dial "+1 555 0100" --exec "python3 my_agent.py"    # outgoing
pua listen --answer-after 8 --exec "python3 my_agent.py"           # incoming, one call at a time
pua stream ws://127.0.0.1:8765 --dial "+1 555 0100"                # outgoing voice agent
pua listen --stream ws://127.0.0.1:8765                            # incoming voice agent
```

The same keys work in the config file ([configuration.md](configuration.md)), so
`pua listen --config my-agent.json` can carry the agent, the greeting, recording and hooks.

## Text agents: `--exec`

pua starts your program once per call and talks to it in JSON lines over stdin and stdout.
pua does the listening and speaking. Your program only decides what to say, using any model,
memory or tools it likes. That includes live data, which pua's built-in model lacks.

```sh
pua converse --exec "python3 examples/agents/clock_agent.py"
```

[examples/agents/clock_agent.py](../examples/agents/clock_agent.py) answers the time and date,
echoes anything else, and hangs up on "bye". It is 45 lines, standard library only. Replace
its `answer()` with your agent.

In a config file:

```json
{
  "exec": { "command": ["python3", "agents/my_agent.py"], "turn_timeout": 60 },
  "agent": { "greeting": "Hi, you've reached an AI assistant. How can I help?" }
}
```

* `exec.command` is an argument list. A relative program path starts at the config file's
  folder. Setting it selects `engines.llm: "exec"` unless `engines.llm` is set.
* `--exec "CMD"` runs `CMD` through `/bin/sh -c`.

### Lifecycle

1. **Start.** pua starts the program before dialing (`converse`) or while the call rings
   (`listen`), and sends `call_start`. A program that exits right away fails the call before it
   connects.
2. **Greeting.** pua says the greeting (`agent.greeting`) itself, then sends each caller turn as
   `turn`.
3. **Replies.** Your program answers each turn with `text` pieces and one `end_turn`.
4. **End.** When the call ends, pua sends `call_end` and closes stdin. It waits up to 3 s, then
   stops the program.
5. **Not answered.** If the call never connects (missed, or answered elsewhere), the program
   still gets `call_end` with `"reason": "not_answered"`.

### pua → agent (stdin)

| `type` | Fields | When |
| --- | --- | --- |
| `call_start` | `direction` (`incoming` or `outgoing`), `caller` (incoming: the name or number macOS shows; outgoing: the dialed number; may be null), `agent_name`, `instructions` (pua's system prompt plus call rules; use or ignore), `greeting` (what pua says first, or null), `locale`, `recording` | Once, first |
| `turn` | `id`, `text` (the caller's finished turn, as recognized) | Each caller turn |
| `call_end` | The call summary: `reason`, `seconds`, `turns`, `transcript`, `reply_latency_s`, … (as in [configuration.md](configuration.md#recordings)) | Once, last |

### agent → pua (stdout)

| `type` | Fields | Effect |
| --- | --- | --- |
| `text` | `text` | A piece of the reply to the current turn. pua speaks each sentence as soon as it is complete. |
| `end_turn` | `hangup` (optional bool) | Ends the reply. Required for every turn. With `hangup: true`, pua hangs up after speaking it. |
| `say` | `text` | Speak without being asked, when the caller is quiet. For example: "I found it" after a slow tool call. |
| `hangup` | | End the call once anything queued has been said |
| `error` | `message` | The current reply failed. pua says a short apology and keeps the call going. |
| `log` | `message` | Becomes an `agent_log` event on pua's stderr |

Rules:

* **Framing.** One JSON object per line. Flush after each line.
* **Logs.** Lines on your stderr become `agent_log` events.
* **Turn-taking is pua's.** pua decides when the caller has finished (`end_of_turn_silence`,
  0.8 s). It does not send the next turn while the agent is speaking.
* **Timeout.** A turn without `end_turn` within `exec.turn_timeout` (60 s, `--turn-timeout`)
  counts as an `error`.
* **Slow tools.** Send a short first sentence ("Let me check.") right away, then the rest. The
  caller hears the first sentence while your tool runs.
* **Interruptions.** The caller cannot interrupt the agent here. If your agent needs that, use
  `--stream`.

### Skeleton

```python
import json, sys

def send(**m): print(json.dumps(m), flush=True)

for line in sys.stdin:
    msg = json.loads(line)
    if msg["type"] == "call_start":
        history = [{"role": "system", "content": msg["instructions"]}]
    elif msg["type"] == "turn":
        history.append({"role": "user", "content": msg["text"]})
        reply = my_agent(history)              # your model, harness, tools
        history.append({"role": "assistant", "content": reply})
        send(type="text", text=reply)
        send(type="end_turn", hangup="goodbye" in reply.lower())
    elif msg["type"] == "call_end":
        break
```

## Voice agents: `--stream`

pua bridges the call to a WebSocket server that speaks the
[Twilio Media Streams](https://www.twilio.com/docs/voice/media-streams/websocket-messages)
protocol (bidirectional streams). pua plays Twilio's part: for each call it connects to your
URL, sends the caller's audio and plays whatever you send back. Your agent owns turn-taking,
interruptions and the voice. Agents and frameworks built to take Twilio calls only need pua's
URL.

```sh
pip install websockets
python3 examples/agents/stream_echo.py                       # ws://127.0.0.1:8765
pua stream ws://127.0.0.1:8765 --dial "+1 555 0100"
```

[examples/agents/stream_echo.py](../examples/agents/stream_echo.py) repeats each caller phrase
back after a pause and stops talking when the caller talks over it.

In a config file: `"stream": { "url": "ws://127.0.0.1:8765", "hang_up_on_close": true }`.

### pua → server

| `event` | Contents |
| --- | --- |
| `connected` | `protocol`, `version` |
| `start` | `streamSid`, `start.callSid`, `start.accountSid`, `start.tracks` (`["inbound"]`), `start.mediaFormat` (`audio/x-mulaw`, 8000 Hz, 1 channel), `start.customParameters` (`direction`, and `caller` when known) |
| `media` | `media.payload`: base64 μ-law 8 kHz, 160 bytes (20 ms) per message; `media.track`, `media.chunk`, `media.timestamp` (ms since start) |
| `mark` | `mark.name`, sent back once the audio you queued before that mark has played |
| `stop` | The call ended (the caller hung up, `--max-seconds`, or Ctrl-C) |

Every message carries `streamSid` and a `sequenceNumber`.

### server → pua

| `event` | Effect |
| --- | --- |
| `media` | `media.payload`: base64 μ-law 8 kHz, any length. Queued and played in order. |
| `mark` | `mark.name`: pua returns it when the audio queued before it has played. Use it to know what the caller actually heard. |
| `clear` | Drops all queued audio at once (for when the caller interrupts); pending marks come back right away |

Hang up by closing the WebSocket. pua then ends the call, unless `stream.hang_up_on_close` is
`false` or you passed `--no-hangup`. When the call ends first, pua sends `stop` and closes the
socket.

### Differences from Twilio

| | Twilio | pua |
| --- | --- | --- |
| `streamSid`, `callSid`, `accountSid` | Real IDs | Random per call, in the same format |
| REST API (hang up, redirect, play) | Yes | None. Close the socket to hang up. |
| `dtmf` events | Yes | Not sent |
| `customParameters` | From TwiML `<Parameter>` | `direction`, `caller` |
| Audio | 8 kHz μ-law | The same; pua converts from and to the Mac's 48 kHz |

### Pipecat

Pipecat's [Twilio serializer](https://docs.pipecat.ai/server/utilities/serializers/twilio)
speaks this protocol. Follow Pipecat's
[Twilio WebSocket guide](https://docs.pipecat.ai/guides/telephony/twilio-websockets), point pua
at your bot's WebSocket URL, and turn off the serializer's automatic hang-up. That hang-up calls
Twilio's REST API, which pua does not have; pua hangs up when the bot closes the socket. Not yet
tested with pua:

```python
serializer = TwilioFrameSerializer(
    stream_sid=stream_sid,                          # from pua's "start" message
    params=TwilioFrameSerializer.InputParams(auto_hang_up=False),
)
```

## Raw audio: `audio-stream`

For full control, run pua as a child process:

* **Audio.** Write PCM16 little-endian, 48 kHz mono to `pua audio-stream --route`'s stdin (the
  caller hears it). Read the caller from its stdout.
* **Events.** JSON lines on stderr.
* **Call control.** Use the call commands; each prints JSON:

  ```sh
  pua call dial NUMBER
  pua call answer --wait 30
  pua call state
  pua call hangup
  pua route setup     # route restore puts the microphone back
  ```

The [README](../README.md#use) lists the flags and events.

## Watching calls

Whichever agent you attach:

* **Events.** `converse`, `stream` and `listen` print events as JSON lines on stderr:
  `ringing`, `answered`, `heard`, `said`, `agent_log`, `stream_ready`, `call_finished`, ….
* **Hooks.** `hooks.call_ended` receives the summary (and the transcript, for `--exec` and the
  built-in agent) on stdin after every call.

The full event list is in [configuration.md](configuration.md#events).
