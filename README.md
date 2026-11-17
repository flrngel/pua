<div align="center">

# pua

### phone-use for AI agents

AI that answers, dials and talks on real phone calls,<br>
through the iPhone you already have and your Mac.

[Quickstart](#quickstart) · [Hear a call](#hear-a-call) · [Use it from Claude Code or Codex](#use-it-from-claude-code-codex-and-other-agents) · [Connect your agent](docs/integration.md) · [How it works](ANALYSIS.md)

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111111?logo=apple)
![Swift](https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white)
![On-device AI](https://img.shields.io/badge/AI-on--device-6E56CF)
![No telephony provider](https://img.shields.io/badge/telephony%20provider-not%20needed-0A84FF)

</div>

---

## What is phone-use?

AI agents can already operate a computer (*computer-use*) and a web browser (*browser-use*).
**phone-use** is the next step: an AI that can be on a phone call. It picks up when the phone
rings, listens, answers in its own voice, and hangs up when the conversation is over. It can
place calls, too. The *pu* in pua stands for phone-use.

You don't need a phone company account, a calling service or a new number. pua works with your
own iPhone, your own number, and your Mac.

## How it works, in plain words

When your iPhone rings, your Mac can ring too, and you can take the call on the Mac. Apple
calls this *Continuity*. pua runs on the Mac and steps into that call:

```
 the other person ──── your iPhone ── Wi-Fi ──▶ your Mac ──▶ pua ──▶ AI   (pua hears the caller)
                                                 your Mac ◀── pua ◀── AI   (the caller hears the AI)
```

1. **It hears the caller.** pua takes the call's sound before it reaches your speakers and
   hands it to the AI.
2. **It speaks.** pua plays the AI's voice into the call in place of your microphone, so the
   caller hears the AI.
3. **It works the buttons.** pua presses Answer, Call and End for the AI, the way you would.

Nothing is installed on the iPhone. When pua isn't running, your phone and Mac work the way they
always have.

## Hear a call

A real call placed by pua and recorded with it (87 seconds). The AI, "Jessica", ran on the Mac:
Apple's on-device speech recognition and language model, with an ElevenLabs voice.

<audio controls src="docs/demo/conversation.m4a"></audio>

[▶ Listen to the recording (m4a, 87 s)](docs/demo/conversation.m4a)

<details>
<summary>Transcript</summary>

| Time | Speaker | What was said (as recognized) |
| --- | --- | --- |
| 0:00 | Jessica (AI) | Hi, it's Jessica, the AI assistant calling from your Mac through pua. Just so you know, this call is being recorded for a demo. How's your day going? |
| 0:10 | Caller | _"Good. How are you?"_ (missed: the reply came the instant the greeting ended; fixed in 0.3.1) |
| 0:24 | Caller | Are you still |
| 0:27 | Jessica (AI) | Hi there! I'm right here with you, ready to chat. How's your day going? |
| 0:32 | Caller | Good. How are you? But I will ask you again. |
| 0:38 | Jessica (AI) | I'm doing great, thanks for asking! What’s on your mind today? |
| 0:43 | Caller | Well, what is my name? |
| 0:47 | Jessica (AI) | I don’t have a name, but I’m here to help—what’s your favorite thing to do when you’re relaxing? |
| 0:53 | Caller | Oh, and I'm relaxing. I just want to um Take |
| 1:00 | Jessica (AI) | That sounds lovely—how are you finding this quiet time? |
| 1:04 | Caller | I mean, like, I, I just have a quite time during, like, like, 30 minutes before I get to that. So. |
| 1:14 | Jessica (AI) | I totally get that—what kind of things do you usually think about during those quiet moments? |
| 1:20 | Caller | _"I don't know."_ (hung up) |

</details>

## What you can build

| | |
| --- | --- |
| **A receptionist** | It answers when you can't, says it is an AI, takes a message and sends it to you. |
| **A caller** | Your agent dials a number, has the conversation and hands you the transcript. |
| **A test line for voice bots** | Try your voice agent on a real phone call without setting up a calling service. |

## Quickstart

**You need:**

* **A Mac:** macOS 26 or later. The built-in AI needs Apple silicon with Apple Intelligence
  turned on.
* **An iPhone:** signed in to the same Apple Account and on the same Wi-Fi. On it, turn on
  *Settings → Apps → Phone → Calls on Other Devices → (your Mac)*.
* **Apple's free developer tools:** run `xcode-select --install` once.

**Install.** Paste this into Terminal:

```sh
git clone https://github.com/flrngel/pua && cd pua
make                                  # build pua
sudo scripts/install-driver.sh        # add pua's virtual microphone and speaker (asks for your password)
.build/release/pua permissions        # then allow Terminal under Accessibility
.build/release/pua shortcut install   # add the "PUA Dial" shortcut pua uses to place calls
.build/release/pua doctor             # check everything; it tells you what is missing
.build/release/pua skill install      # optional: teach Claude Code, Codex and other agents phone-use
```

macOS will ask for three permissions:

* **Accessibility**, to press the call buttons.
* **System Audio Recording**, to hear the call.
* **Microphone**, for the self-test only.

**Let it answer a call.** Run this, then call your iPhone from another phone:

```sh
.build/release/pua listen --once
```

The Mac rings, pua picks up, and the AI greets the caller. Say "bye" and it hangs up.

**Let it place a call:**

```sh
.build/release/pua converse --dial "+1 555 0100"
```

## Use it from Claude Code, Codex and other agents

AI coding agents learn new abilities from *skills*: short instruction files they read when a
task calls for one. pua ships a **phone-use** skill. Install it with one command:

```sh
.build/release/pua skill install
```

Then start a new session in your agent and ask in plain words:

> Call +1 555 0100 and ask whether they're open this Sunday.

The agent works like an assistant you hand a phone task to:

1. **It checks with you.** It repeats the number and the goal, and waits for your OK.
2. **It briefs the caller.** It writes the voice agent's instructions and its greeting, which
   always says it's an AI.
3. **It places the call.** pua dials, and its voice agent has the conversation.
4. **It reports back.** You get the outcome, with the lines from the transcript that show it.

You can also ask it to check or end the current call, or to answer your calls and take a
message. It only answers calls when you ask.

| | |
| --- | --- |
| Where it installs | `~/.claude/skills/phone-use` (Claude Code), and `~/.agents/skills/phone-use`, the shared folder that Codex, Gemini CLI and other agents read |
| Another folder | `pua skill install --dir ~/.codex/skills` (older Codex), or a project's `.claude/skills` |
| Update | Run `pua skill install` again after updating pua |
| Remove | `pua skill uninstall` |
| Read it | [skills/phone-use/SKILL.md](skills/phone-use/SKILL.md) |

## Connect your agent

pua comes with a small, fast AI that runs on your Mac. For a smarter one, with its own tools,
memory and knowledge, connect your agent in one of three ways:

| If your agent works with… | Use | pua takes care of |
| --- | --- | --- |
| **Text**: most chatbots and agent frameworks | `--exec "your program"` | Hearing the caller, speaking the reply, knowing whose turn it is |
| **Voice**: speech-to-speech models, bots built for Twilio | `--stream ws://…` | Carrying the call's sound to your agent and back |
| **Raw sound** | `pua audio-stream` | Only the sound |

```sh
pua listen --exec "python3 examples/agents/clock_agent.py"
```

That example agent tells callers the time, which the built-in AI can't look up. On a live call
it answered in about 1.5 seconds. The protocols, example agents and a note on Pipecat are in
[docs/integration.md](docs/integration.md).

## Private by default

* **On your Mac:** the built-in AI's speech recognition and language model run on the Mac. The
  conversation does not leave it.
* **Only when you ask:** pua answers calls only while `pua listen` is running, and records only
  when you ask it to (`--record`).
* **Honest with callers:** the AI tells callers it is an AI, and that the call is recorded when
  it is. Keep that if you change the greeting, and follow your local recording laws.
* **You choose what is shared:** with the ElevenLabs voice, only the AI's reply text goes to
  ElevenLabs. A connected agent gets only what you send it.

## Limits today

* **One call at a time,** with the Mac awake and unlocked.
* **Taking turns:** with the built-in AI or `--exec`, the caller can't interrupt the AI
  mid-sentence. `--stream` agents can handle interruptions.
* **The built-in AI is small.** It is quick, but it can't look things up. Connect a stronger agent
  for that.
* **Language:** tested on a Mac set to English.

## Docs

| | |
| --- | --- |
| [Connect your agent](docs/integration.md) | The `--exec` and `--stream` protocols, with example agents |
| [phone-use skill](skills/phone-use/SKILL.md) | What Claude Code, Codex and other agents learn from `pua skill install` |
| [Settings](docs/configuration.md) | Persona, greeting, voice, recording and after-call actions in one file |
| [Commands](docs/cli.md) | Every command and flag |
| [How Mac and iPhone calling works](ANALYSIS.md) | The mechanism, with evidence |
| [Design and verification](docs/analysis/pua-design.md) | Decisions, what was tested on real calls, known gaps |
| [Contributing](CONTRIBUTING.md) | Code map, adding engines, checks that need no phone |

Uninstall: `sudo scripts/uninstall-driver.sh`.
