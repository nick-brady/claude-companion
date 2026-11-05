# Claude Companion

Talk to Claude Code instead of typing, and hear it answer. A small, draggable pill with a
voice orb. The orb listens (cool white), thinks (violet) and speaks (warm coral, pulsing
with Claude's actual voice). It morphs into a full window for the transcript, sessions and
settings.

Native Swift/SwiftUI with on-device speech. Nothing leaves the Mac except what goes to
Claude through the `claude` CLI you already use.

## Run

```sh
./run.sh                 # build (release), bundle build/Claude Companion.app, launch
./run.sh selftest        # checks that need no mic/permissions
./run.sh selftest --claude   # + one real claude -p round trip with an image (uses a little quota)
./run.sh demo            # cycle the pill through its states (no mic, no Claude)
```

Requires only the Xcode Command Line Tools (Swift 6.3). No Xcode project.

## Use

| Action | How |
|---|---|
| Talk | **Hold ⌥Space**, speak, release. Or **tap ⌥Space** to go hands-free, then tap again to send. |
| Summon | ⌥Space also glides the pill to your cursor. After ~6 s of quiet it fades and glides back home. |
| Move home | Drag the pill anywhere. Where you drop it becomes home (it snaps gently to edges and center, and is remembered). |
| Expand / collapse | Click the pill, its expand button, or **⌥⇧Space**. Collapse with the button, Esc, or ⌥⇧Space. |
| Point at something | While holding ⌥Space, **circle it with the mouse**. A red ring flashes, and Claude gets a close-up plus the full screen with that area boxed. |
| Drag a region | Crop button: macOS's own drag-to-select. |
| Interrupt | Press ⌥Space while Claude is talking. It stops and listens. |
| Pick the session | Click the session label at the bottom left of the expanded window (a soft green dot means it's connected), or Sessions → **Pin**. ⌘1–9 pin the first nine live sessions. **Follow active** (default, Settings) targets whichever session was most recently active; picking one pins it and stops following. |

## Which session it talks to

1. **Live, push (recommended).** Start Claude Code with `integration/cc-voice` instead of
   `claude`. Your spoken words show up in that terminal as `← companion: …` and Claude
   answers there as usual. Its final message is read aloud. It uses Claude Code's
   **channels** feature (research preview): a local MCP server pushes
   `notifications/claude/channel` events into the session. `cc-voice` passes the MCP
   server and two hooks with `--mcp-config` and `--settings` **for that launch only**, so
   nothing in `~/.claude` is changed. Each launch shows a one-time "development channels"
   warning; pick *I am using this for local development*. Tip: `alias cc-voice=~/Documents/self/claude_companion/integration/cc-voice`.
   Claude also gets three tools: `get_screenshot` (what you attached), `look` (your screen
   right now) and `speak`.
2. **Live, typing into iTerm (fallback).** Sessions → *Find iTerm sessions* lists iTerm2
   tabs that are running `claude`. Pin one, and the app types your words into that tab and
   presses Return. This works with a plain `claude`, but replies are only spoken if the
   session was started with `cc-voice` (the Stop hook). Screenshots are passed as file paths.
   It only types into a tab you pinned, never into a guessed one.
3. **Background.** The app's own `claude -p --input-format stream-json` session (new or
   resumed). It streams and speaks sentence by sentence, but it isn't visible in a terminal.

With nothing pinned (or *Follow active* on), the app uses the most recently active push
session: the last one to fire a hook (a tool call or a finished turn, so sessions you type
into in the terminal count) or to get a message from the app. It falls back to the
background session.

**Channels on a Team plan:** for claude.ai Team and Enterprise orgs, channels are off until
an Owner enables **claude.ai → Organization settings → Claude Code → Channels**
(<https://claude.ai/admin-settings/claude-code>). Until then the MCP tools still load, but
pushed messages are silently dropped. The app detects this: it waits for the channel's
ack, and then for Claude to start (a hook fires). If nothing happens it shows an error with
a **Type it into iTerm instead** button. Settings → *Delivery* → **Type into its iTerm tab**
makes typing the default.

## Voice

Settings → *Respond with voice* (also the speaker button on the pill and in the input bar):
on means replies are read aloud, off means they stay as text. This applies to terminal
sessions (Stop hook) and the background session.

| Engine | Quality | Cost (rough) | Notes |
|---|---|---|---|
| macOS Premium voices | good | free | on-device. Download in System Settings → Accessibility → Spoken Content → System voice → Manage Voices… (Ava, Zoe, Evan, Nathan (Premium); Jamie or Serena (UK); Matilda (AU)) |
| OpenAI gpt-4o-mini-tts | very natural, steerable | ≈ $0.015/min, about $1/hour | **recommended cloud default** |
| ElevenLabs Flash v2.5 | most human | ≈ $5–10/hour on paid plans | lowest latency of the "premium" voices |

Cloud keys are pasted in Settings and stored in the macOS Keychain (service
`com.nickbrady.claudecompanion`), never in files. Only the reply text goes to the provider.
Audio streams as 24 kHz PCM, so speech starts on the first chunk, and the orb follows the
real output level. If the call fails, that sentence is spoken with the macOS voice.

## Permissions (macOS asks the first time; nothing is changed for you)

| Permission | When | Where to grant / fix |
|---|---|---|
| Microphone | first time you talk | System Settings → Privacy & Security → Microphone → Claude Companion |
| Speech Recognition | first time you talk | … → Speech Recognition → Claude Companion (transcription runs on-device when supported) |
| Screen & System Audio Recording | first screenshot / circle | … → Screen & System Audio Recording → enable Claude Companion, then quit and reopen it |
| Automation → iTerm | only when you open Sessions (lists iTerm tabs) or type into one | … → Automation → Claude Companion → iTerm |

### Stable signing (one time, stops repeated permission prompts)

macOS ties privacy permissions to the app's code signature. Ad-hoc signatures change on
every build, so permissions "disappear". To fix it, create a local signing certificate once:

1. Open **Keychain Access** → menu **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `Claude Companion Dev` · Identity Type: **Self Signed Root** · Certificate Type: **Code Signing** → **Create** → **Done**.
3. Run `./run.sh`. The first time, macOS asks whether `codesign` may use the key: click **Always Allow**.
4. In System Settings → Privacy & Security, remove the old Claude Companion entries (Screen
   Recording, Microphone, Speech Recognition) with **−**, then allow again when the app asks.
   From then on, rebuilds keep the permissions.

The certificate is only used locally to sign this app and isn't trusted for anything else.

Accessibility is **not** needed: the hotkeys use Carbon `RegisterEventHotKey`, and cursor
tracking just reads the mouse position. Because the app is ad-hoc signed (there's no
developer certificate on this Mac), macOS may ask again after a rebuild. If Screen Recording
looks enabled but captures fail, toggle it off and on.

## "Claude sees where I'm looking"

| | Drag a region | Circle with the cursor (built) |
|---|---|---|
| Precision | exact | ~bounding box of the loop (+24 pt padding) |
| Flow | separate step, breaks speech | happens *while you talk*, like pointing at a screen for a colleague |
| False positives | none | tuned: needs about 306° of turning within 1.6 s, closed loop, 24–1100 pt; wiggles, lines, scribbles and slow arcs are ignored (see selftest) |
| Permissions | Screen Recording | Screen Recording (cursor tracking needs none) |

Circling is the main gesture and only runs while you hold the talk key (privacy: no
background watching). Drag-region stays as the precise fallback. In "Screen + cursor every
turn" mode, the full screen with a red ring at the cursor is attached when you didn't circle.

## Layout

```
Sources/ClaudeCompanion/
  App.swift            window controller: pill <-> window morph, summon, drag/home, menu bar
  PillView.swift       the pill + caption card
  MainWindow.swift     expanded window: conversation, sessions (pin), settings
  Orb.swift            voice orb + waveform bars
  AppState*.swift      flow: hotkey -> listen -> screenshot -> deliver -> speak
  SpeechInput.swift    SFSpeechRecognizer (on-device)
  SpeechOutput.swift   AVSpeechSynthesizer -> AVAudioEngine (real amplitude drives the orb), markdown -> speech
  ClaudeBridge.swift   background claude -p stream-json session
  LocalServer.swift    127.0.0.1:47823, token-protected, for the channel + hooks
  LiveSessions.swift   live session registry, iTerm AppleScript
  CursorGesture.swift  circle detector
integration/
  cc-voice             launcher (claude + channel + hooks, per launch)
  channel/             MCP channel server (Node, @modelcontextprotocol/sdk)
  hooks/notify-app.sh  Stop / PreToolUse -> app (2 s timeout, never blocks Claude)
```
