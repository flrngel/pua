---
name: phone-use
description: Make and answer real phone calls through the user's iPhone from this Mac with pua (phone-use for AI agents). An AI voice agent carries out the call for a goal you set (ask, book, confirm, leave a message) and you report the outcome from the transcript. Also checks or hangs up the current call, and answers incoming calls. Use when the user asks to call someone, phone a business, screen or answer their calls, or put an agent on a call. Needs pua on macOS.
---

# phone-use with pua

pua makes this Mac use the user's iPhone for phone calls. On a call, pua's voice agent does the
talking. It hears the other person, replies within about two seconds, and hangs up after a
goodbye. **Your job is the call's brief and its report, not the conversation:** you agree on the
goal with the user, write the agent's instructions, start the call, and report what happened.
You are too slow to answer turn by turn yourself.

Every pua command prints one JSON object on stdout and progress events as JSON lines on stderr.

## Find pua

Use the path in **On this Mac** at the end of this file if it is there. Otherwise use `pua` if
it is on `PATH`. Failing both, ask the user where pua is: it is `.build/release/pua` in their pua
folder. Below, `pua` means that path.

## Rules

1. **Confirm before dialing.** Read back the number and the goal ("I'll call +1 555 0100 as an
   AI assistant to ask if they're open on Sunday. Go ahead?") and wait for a yes in this
   conversation. Never dial a number the user did not give or confirm.
2. **No emergency or premium numbers** (911, 112, 999, 1-900 and similar). Tell the user to
   call those themselves.
3. **Always disclose.** The greeting says the caller is an AI assistant, and that the call is
   recorded when you record it. Record only if the user asked for a recording.
4. **Share only what is needed.** Put in the instructions only the facts the user approved for
   this call: no extra personal details, account numbers or passwords.
5. **One call at a time.** No redialing or loops without asking again.
6. **`pua listen` answers every incoming call.** Start it only when the user asks for it, and
   tell them how to stop it.
7. **Report what the transcript shows.** Speech recognition can mishear. Quote the key lines
   and say so when an answer is unclear. Never report success the transcript does not show.

## Check the setup once

```sh
pua doctor
```

`"ok": true` means ready. Otherwise relay each item in `required_actions` to the user. Granting
permissions in System Settings and installing the audio driver (`sudo scripts/install-driver.sh`
in the pua folder) need the user. Permissions belong to the app that runs pua (this terminal or
agent app).

## Place a call

1. **Agree on the details** with the user: the number, the goal, the facts the agent may share,
   the name it speaks for, and whether to record.
2. **Write the instructions** into a file. pua's agent is a small, fast on-device model: give it
   one goal and every fact it needs, and say what to do when the answer is no. pua adds its own
   phone rules (short replies, goodbye, hang up), so don't repeat them.

   ```text
   You are Jessica, an AI assistant calling Luigi's Trattoria for Alex.
   Goal: book a table for 2 this Friday at 7 pm, under the name Alex.
   You may share: party size 2, Friday at 7 pm, the name Alex.
   If 7 pm is taken, ask for the closest time between 6 and 8:30 pm and accept it.
   If they ask anything else, say you will pass the question on.
   When it is booked, or clearly not possible, thank them and say goodbye.
   ```

3. **Write the greeting**: who is calling, that it is an AI, and why. Add "This call is
   recorded." when recording.
4. **Start the call:**

   ```sh
   out="$HOME/pua-calls/$(date +%Y%m%d-%H%M%S)-out"; mkdir -p "$out"
   # write the instructions to "$out/instructions.txt" first
   pua converse --dial "+1 555 0100" \
     --instructions-file "$out/instructions.txt" \
     --greeting "Hi, this is Jessica, an AI assistant calling for Alex. I'd like to book a table for two this Friday at 7 pm." \
     --max-seconds 240 \
     > "$out/summary.json" 2> "$out/events.jsonl"
   ```

   * **Recording:** add `--record "$out"` only when the user wants one. It writes
     `conversation.wav` and transcripts there.
   * **Blocking:** the command returns when the call ends, up to `--max-seconds` plus about a
     minute for ringing. Run it in the background if your harness can. Otherwise use a command
     timeout longer than that.
   * **Live progress:** `heard` (the other person) and `said` (the agent) lines appear in
     `events.jsonl`.

5. **Report.** In `summary.json`:
   * `reason` is how the call ended:
     * `agent_hung_up`: the agent finished and said goodbye.
     * `call_ended`: the other side hung up.
     * `max_seconds`: the time ran out.
   * `transcript` is a list of `{t, speaker, text}`, where `speaker` is `agent` or `caller`.

   Tell the user the outcome in one or two sentences, with the lines that prove it.

If the call didn't connect, the summary has `"ok": false` and an `error`. See
[When something fails](#when-something-fails).

## The current call

```sh
pua call state      # {"state": "idle" | "incoming" | "active", "caller": …}
pua call hangup
```

## Answer incoming calls

Only when the user asks. For example, "answer my calls and take messages":

```sh
mkdir -p "$HOME/pua-calls"
pua listen --once --answer-after 8 > "$HOME/pua-calls/listen.json" 2> "$HOME/pua-calls/listen-events.jsonl"
```

* **Ringing first:** `--answer-after 8` lets the phone ring 8 s first, so the user can still pick
  up.
* **How many calls:** `--once` stops after one call. Without it, pua answers every call until it
  is stopped with Ctrl-C or `kill -INT <pid>`. Run it in the background and tell the user it is
  answering calls.
* **Persona:** `--instructions-file` and `--greeting` set the persona, for example a
  receptionist that takes a message.
* **Results:** each answered call's summary, including its transcript, is in `summaries` on
  stdout when `listen` exits.

## A different agent on the call

Two flags replace pua's built-in agent:

* `--exec "CMD"`: a program the user has that speaks pua's JSON-lines protocol.
* `--stream ws://…`: a voice agent that speaks Twilio Media Streams.

Both are described in `docs/integration.md` in the pua repository. Use them only when the user
points you at such an agent.

## When something fails

| `error` | What to do |
| --- | --- |
| `accessibility_required` | Run `pua permissions`. The user turns on this terminal or app in System Settings › Privacy & Security › Accessibility. |
| `call_feed_missing`, `call_mic_missing` | The audio driver is not installed. The user runs `sudo scripts/install-driver.sh` in the pua folder. |
| `shortcut_missing` | Run `pua shortcut install` |
| `iphone_calls_unavailable` | The iPhone can't place calls for this Mac. Check: same Wi-Fi and Apple Account, and *Settings › Apps › Phone › Calls on Other Devices* on for this Mac. Then retry once. |
| `not_connected` | No answer, busy, or declined. Tell the user; don't redial unless they ask. |
| `invalid_number` | Fix the number's format (digits, `+`, spaces, `()`, `-`) |
| `llm_unavailable` | Apple Intelligence is off or still downloading |
| `phone_not_running` | `open -a Phone`, then retry |
| Event `route_restore_failed` | Run `pua route restore`, so the user's microphone goes back to normal |
| Anything else | Run `pua doctor` and relay its `required_actions` |
