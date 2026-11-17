# Configuration

`pua converse` (outgoing calls) and `pua listen` (incoming calls) read the same JSON config
file. Every key is optional: a missing key keeps the built-in default. Command-line flags
override the file.

pua uses the first of these that exists:

1. `--config FILE`
2. `$PUA_CONFIG`
3. `~/.config/pua/config.json`
4. Built-in defaults

`pua config show [--config FILE]` prints the resolved settings for both directions, the file
that was used, and warnings for keys pua does not know (typos are reported, not ignored).

## Example

[examples/receptionist.json](../examples/receptionist.json) answers incoming calls after
8 seconds of ringing, takes messages, records each call and shows a notification:

```json
{
  "version": 1,
  "agent": {
    "name": "Jessica",
    "system_prompt_file": "receptionist.txt",
    "greeting": "Hi, you've reached {name}, an AI assistant answering this phone. This call is recorded. Who's calling?",
    "locale": "en-US"
  },
  "engines": { "stt": "apple", "llm": "apple", "tts": "system" },
  "conversation": { "end_of_turn_silence": 0.8, "max_seconds": 180, "hang_up_when_done": true },
  "listen": { "answer_after": 8 },
  "record": { "directory": "~/pua-calls" },
  "hooks": { "call_ended": ["./hooks/notify.sh"] }
}
```

```sh
pua listen --config examples/receptionist.json
```

## Keys

Relative paths start at the folder of the config file; `~` expands to your home folder.

| Key | Type | Default | Flag | Notes |
| --- | --- | --- | --- | --- |
| `version` | number | `1` | | Config format version. pua warns when it is newer than it understands. |
| `agent.name` | string | `Jessica` | `--name` | Replaces `{name}` in the prompt and greeting; labels the agent in transcripts. |
| `agent.system_prompt` | string | built-in, per direction | `--instructions` | The system prompt (persona and task). |
| `agent.system_prompt_file` | path | | `--instructions-file` | Reads the system prompt from a text file. `system_prompt` wins if both are set. |
| `agent.greeting` | string | built-in, per direction | `--greeting`, `--no-greeting` | First line the agent says. `""` for none. |
| `agent.locale` | string | `en-US` | `--locale` | Speech recognition and macOS voice language. |
| `engines.stt` | name | `apple` | `--stt` | Speech recognition engine. |
| `engines.llm` | name | `apple` | `--llm` | Reply model. |
| `engines.tts` | name | `elevenlabs` if `ELEVENLABS_API_KEY` is set, else `system` | `--tts` | Voice. |
| `voice.id` | string | engine default | `--voice` | ElevenLabs voice ID, or a macOS voice identifier for `system`. |
| `voice.model` | string | `eleven_flash_v2_5` | `--tts-model` | ElevenLabs model. |
| `conversation.end_of_turn_silence` | seconds | `0.8` | `--end-silence` | Caller silence that ends their turn (1.3 s while a phrase is unfinished). |
| `conversation.max_seconds` | seconds | `300` | `--max-seconds` | Longest conversation per call. |
| `conversation.hang_up_when_done` | bool | `true` | `--no-hangup` | Hang up after the agent says goodbye. |
| `listen.answer_after` | seconds | `0` | `--answer-after` | Ring time before pua answers, so you can still pick up. Keep it below your carrier's voicemail timeout (often 20–30 s). |
| `listen.max_calls` | number | `0` (no limit) | `--max-calls`, `--once` | Calls to answer before `listen` exits. |
| `record.directory` | path | off | `--record` | Records each call into `<directory>/<yyyyMMdd-HHmmss>-in` or `-out`. `converse --record DIR` writes into `DIR` itself. |
| `hooks.call_ended` | command | | | Runs after each call; see [Hooks](#hooks). |

Engines available in this build: `pua config show` lists them under `engines_available`.
Adding one is described in [CONTRIBUTING.md](../CONTRIBUTING.md).

Secrets never go in the config file. The ElevenLabs key is read from `ELEVENLABS_API_KEY` only.

## Prompts and greetings

Without `system_prompt`, pua picks a prompt by direction:

* **Outgoing** (`converse`): a friendly assistant that placed the call.
* **Incoming** (`listen`): an assistant that answers the phone and talks with the caller about
  anything, says plainly that it has no live information (weather, news), offers to take a
  message for the owner, and never invents details about the owner or promises a callback.

pua always appends its call rules to the system prompt, so a custom prompt does not need them:

> Your replies are spoken aloud on a phone call. Speak naturally, like a person on the phone:
> one or two short sentences per reply, no lists, no markdown, no emoji. Do not greet or introduce
> yourself again, and never repeat an earlier reply: if the caller is confused, say it differently.
> Only when the caller says goodbye or asks to end the call, reply with a short goodbye and put
> [hangup] at the very end. Never write [hangup] in any other reply.

The default greetings say that the caller is talking to an AI, and add "This call is being
recorded." when recording is on. A custom greeting replaces that text: keep both disclosures in
it if you record, and follow your local call-recording laws.

## Recordings

Each recorded call gets a folder:

| File | Contents |
| --- | --- |
| `conversation.wav` | Stereo 48 kHz PCM16: left is the caller, right is the agent |
| `transcript.md` | Readable transcript with reply times |
| `transcript.jsonl` | One turn per line: `t` (seconds from the start), `speaker` (`caller` or `agent`), `text`, `latency_s` |
| `call.json` | The call summary: `reason`, `seconds`, `turns`, `direction`, `engines`, `reply_latency_s`, `caller` (incoming), `files` |

## Hooks

`hooks.call_ended` is a command as an argument list, for example `["./hooks/notify.sh"]` or
`["/usr/bin/say", "call finished"]`. After each call pua starts it with:

* **stdin**: the call summary as JSON, including the full `transcript` array.
* **environment**: `PUA_EVENT=call_ended`, plus `PUA_RECORD_DIR` when the call was recorded.

pua does not wait for the hook between calls, but waits up to 30 s for running hooks when it
exits. Hooks can summarize a message, send it to you, or file it somewhere, without changing
pua. [examples/hooks/notify.sh](../examples/hooks/notify.sh) shows a macOS notification.

## Events

`converse` and `listen` print one JSON object per line on stderr. Each has `event` and `t`
(Unix time). The final summary goes to stdout as JSON.

| Event | When |
| --- | --- |
| `config_warning` | An unknown key or a newer config version |
| `listening` | `listen` is ready for calls |
| `ringing` | An incoming call rings (`caller` is the label macOS shows) |
| `missed`, `answered_elsewhere` | The call stopped ringing before pua answered |
| `route`, `route_restored` | The Phone microphone was switched to PUA Call Mic, then back |
| `answering`, `answered` | pua pressed Accept; the call connected (`via`: `ax` or `callservicesd`) |
| `answer_failed` | The call did not connect within 10 s of pressing Accept |
| `dialed`, `connected` | `converse --dial` placed the call; the far end answered |
| `conversation_ready` | Audio is flowing; lists the engines |
| `heard`, `said` | A caller turn; an agent turn (`latency_s` from the end of the caller's speech) |
| `hung_up` | The agent ended the call |
| `call_finished` | `listen` finished a call (the summary without the transcript) |
| `hook_finished`, `hook_error` | A hook exited, or could not start |
| `stt_error`, `llm_error`, `tts_error`, `listen_error` | A failure; the conversation goes on where it can |
