# Pointer

Point at code anywhere on screen and get it explained, using a prompt you control.

Pointer is a macOS menu-bar app. Press a keybind, a red box appears around your cursor,
scroll to size it, click — the region is captured and sent to Claude or OpenAI with your
chosen prompt, and the explanation streams into a popover under the menu-bar icon.

Because it reads pixels rather than files, it works the same in Terminal, a browser, a PDF,
Xcode, a code review diff, or someone else's screenshare.

```
idle ──[hotkey]──▶ selecting ──[click/⏎]──▶ confirming ──[⏎]──▶ analyzing ──▶ result
                       │                        │                              │
                       └──[esc]──▶ idle         └──[esc]──▶ idle      [History tab]
```

Nothing is ever sent without you confirming it at the preview step.

---

## Setup

### 1. Signing identity (one time)

```bash
./scripts/make-signing-cert.sh
```

This mints a **self-signed** code-signing certificate called `Pointer Dev`. No Apple
account, no paid membership, nothing that expires.

Why it matters: macOS ties the Screen Recording grant to the app's *code identity*. Ad-hoc
signing derives that identity from the binary hash, so **every rebuild would re-prompt for
permission** and leave a stale entry to delete by hand in System Settings. A stable identity
makes the grant stick.

**The first build will show one keychain dialog:**

> "codesign wants to sign using key "Pointer Dev" in your keychain."

Click **Always Allow** (not "Allow"). That's the only interactive step, and it never comes
back. If you'd rather pre-authorize it, run this yourself — it needs your login password, so
it has to be you typing it:

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "<your login password>" ~/Library/Keychains/login.keychain-db
```

<details>
<summary>Keychain Access route instead (if the script gives you trouble)</summary>

**Keychain Access → Certificate Assistant → Create a Certificate**

- Name: `Pointer Dev`
- Identity Type: **Self Signed Root**
- Certificate Type: **Code Signing**

Then re-run `./build.sh`.
</details>

`codesign` reporting `CSSMERR_TP_NOT_TRUSTED` for this certificate is **expected and
harmless** — trust affects verification output, not the ability to sign or the stability of
the identity. Run `./scripts/make-signing-cert.sh --trust` if you want it clean anyway
(it opens a password dialog).

### 2. Build

```bash
./build.sh
```

Compiles, assembles `Pointer.app`, signs it, and installs to `/Applications`. Use
`--no-install` to leave it in `./dist`, `--debug` for a debug build. If the `Pointer Dev`
identity is missing, the build falls back to ad-hoc signing with a warning rather than
failing.

```bash
open /Applications/Pointer.app
```

### 3. Grant Screen Recording

Pointer reads the pixels inside the box you draw, so macOS requires Screen Recording
access. **It is the only permission Pointer needs** — no Accessibility, no Input Monitoring.

The first capture attempt offers to open System Settings. After granting, macOS requires a
relaunch; the prompt has a "Relaunch Now" button.

### 4. Add an API key

Menu-bar icon → right-click → **Settings… → Provider**. Keys are stored per provider in the
login Keychain, never in `config.json`, so you can keep both and switch freely. An exported
`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` is used as a fallback if no key is stored.

---

## Using it

| Action | Key |
|---|---|
| Start a selection | your chord (customizable) |
| Taller / shorter box | scroll up / down |
| Wider / narrower box | scroll left / right, or `⇧`+scroll |
| Fine 1pt adjustment | `⌥`+scroll |
| Capture | click, or `⏎` — works with the hotkey chord still held |
| Cancel | `esc`, or a plain right-click |
| Send for analysis | `⏎`, or the Analyze button |
| Discard without sending | `esc` |

The box size you settle on **persists**, so once it fits your editor's font you don't redo
it. Left-click the menu-bar icon for the popover (result + history); right-click for the menu
(capture, default prompt, settings, quit).

Pressing the keybind again while a result is still on screen starts the next capture and
dismisses the old one — you never have to close the popover first. A finished analysis is
already saved to History; one still streaming is cancelled.

Every analyzed snippet is saved with its thumbnail, prompt, response, and model, searchable
under the **History** tab.

---

## Configuration

`~/.config/pointer/config.json` — hot-reloaded on save, so you can edit it by hand while the
app is running.

| Key | Default | Notes |
|---|---|---|
| `provider` | `anthropic` | `anthropic` or `openai` |
| `anthropicModel` | `claude-opus-5` | Cheaper vision-capable: `claude-sonnet-5` ($3/$15 per Mtok), `claude-haiku-4-5` ($1/$5) |
| `openaiModel` | `gpt-4.1-mini` | Any vision-capable chat model |
| `anthropicThinking` | `adaptive` | `adaptive`, `disabled`, or `""` to omit. **Model-gated** — see below |
| `anthropicEffort` | `low` | `low`/`medium`/`high`/`xhigh`/`max`, or `""`. **Model-gated** |
| `maxTokens` | `2048` | Covers thinking **plus** the answer on Claude Opus 5 |
| `hotkey` | `⌃⌥⌘C` | `{keyCode, modifiers}`; use the recorder in Settings |
| `exclusiveHotkey` | `false` | See "Hotkey trade-off" below |
| `boxSize` | `900×320` | Points; updated whenever you resize a selection |
| `scrollStep` | `10` | Points per wheel click |
| `invertScrollResize` | `false` | Flip resize direction if it feels backwards |
| `historyLimit` | `200` | Oldest entries pruned beyond this |
| `debugDumpCaptures` | `false` | Writes each capture to `~/Library/Caches/pointer/last-capture.png` |
| `prompts` / `activePromptId` | 3 built-ins | Your prompt library |

History lives in `~/Library/Application Support/Pointer/history/` as one PNG plus one JSON
per entry.

### Model-gated fields

`anthropicThinking` and `anthropicEffort` are **rejected by older models**. If you switch
`anthropicModel` to `claude-haiku-4-5`, clear both to `""` or requests will fail with a 400.
They're config fields rather than hardcoded precisely so that's an edit, not a rebuild.

### Cost

The confirm step shows an estimated token count and, for models with published pricing, a
rough per-capture cost. At the default 900×320 box that's around 1.5k image tokens. Because
every capture is explicitly confirmed, nothing is spent by accident.

---

## Two trade-offs worth knowing

### The hotkey

The right way for a Mac app to own a global keybind is `RegisterEventHotKey`: the OS
matches the chord itself and tells the app "your hotkey fired" — no permission needed,
because the app never observes the keyboard; it fires in every app state; and the
keystroke is consumed so it never leaks into the frontmost app.

The macOS 26 SDK **removed the Carbon hot-key declarations from its headers** (taking the
`HotKey` / `MASShortcut` libraries with them), but the implementations still ship in
`Carbon.framework` for binary compatibility. Pointer resolves the symbols at runtime with
`dlsym` and fails soft: if a future macOS finally deletes them, the app still launches and
falls back to the polling path below.

If registration ever fails (a future macOS deleting the implementation), Pointer falls
back to polling `CGEventSource.keyState` on a strict background timer. That fallback has a
known OS limit, verified on macOS 26: key state for non-modifier keys is blanked when the
querying app is not the active one — that's what the Input Monitoring permission gates — so
it only sees the chord while Pointer itself is frontmost. The log says which path is live
(`carbon hotkey registered` vs `falling back to polling`).

The keybind is never gated on app state: pressing it while a selection, confirmation, or
result is on screen tears that down and starts fresh.

**Exclusive hotkey** in Settings switches to a `CGEventTap` (needs Accessibility). With the
Carbon path working it's largely redundant — both consume the keystroke — and it stays off
by default.

### Capture excludes Pointer's own windows

The obvious capture call, `SCScreenshotManager.captureImage(in:)`, grabs everything on
screen — which would include Pointer's red box and its own result popover, so the model
would end up reading our overlay and its previous answer back out of the screenshot.
Pointer filters by display while excluding its own application, and orders the overlay out
before capturing, so what gets sent is exactly what was underneath.

---

## Troubleshooting

**Screen Recording keeps re-prompting after every build.** You're signing ad-hoc. Run
`./scripts/make-signing-cert.sh`, then delete the stale Pointer entries under System
Settings → Privacy & Security → Screen Recording and grant once more.

**Build says "Could not sign with 'Pointer Dev' — fell back to ad-hoc".** The one-time
keychain dialog wasn't answered. Re-run `./build.sh`, watch for it, click **Always Allow**.

**Reply comes back empty.** On Claude Opus 5 thinking is on by default and `maxTokens` caps
thinking *plus* the answer. Raise `maxTokens`, or lower `anthropicEffort`.

**400 error after changing model.** Clear `anthropicThinking` and `anthropicEffort` — see
"Model-gated fields".

**Scroll resizes the wrong way.** Set `invertScrollResize` to `true`. Direction already
accounts for the system "natural scrolling" setting; this covers devices where it still
feels inverted.

**The captured image looks wrong.** Turn on `debugDumpCaptures` and inspect
`~/Library/Caches/pointer/last-capture.png` — that's exactly what was sent.

**The keybind did nothing.** Pointer traces every step of the hotkey → selection → capture
path to the unified log, so you don't have to guess which one stopped:

```bash
/usr/bin/log show --predicate 'subsystem == "com.kavi.pointer"' --last 10m --style compact
```

Use the full `/usr/bin/log` path — zsh has a `log` builtin that shadows it and fails with
"too many arguments". A healthy capture logs `hotkey fired (carbon)` → `overlay up` →
`captured NNN×NNNpt`; whichever line is missing is where it stopped, and the guard that
swallowed it logs its own reason.

---

## Development

```bash
swift build                 # compile
./build.sh --no-install     # bundle into ./dist without installing
```

The streaming path can be exercised without an API key or Screen Recording permission by
pointing it at a local fake server:

```bash
POINTER_ANTHROPIC_BASE_URL=http://127.0.0.1:8765 \
  ANTHROPIC_API_KEY=dummy \
  "$(swift build --show-bin-path)/Pointer" --selftest-stream
```

It prints the assembled text and exits non-zero on failure — useful for checking request
shape and SSE parsing after changes. Set `POINTER_SELFTEST_PROVIDER=openai` and
`POINTER_OPENAI_BASE_URL` for the OpenAI path.

With `debugDumpCaptures` on, the selection flow can also be driven headless via distributed
notifications (`com.kavi.pointer.debug.begin` / `.commit` / `.cancel`), so "the keybind did
nothing" reports can be reproduced and watched in the unified log without anyone at the
keyboard. The triggers are inert while the flag is off.

### Layout

| File | Responsibility |
|---|---|
| `AppDelegate.swift` | Menu-bar item, menu, wiring between the pieces |
| `AppState.swift` | The idle → confirming → analyzing → result state machine |
| `HotKey.swift` | Global keybind (polling by default, event tap opt-in) |
| `SelectionOverlay.swift` | Per-display overlay windows, red box, scroll-to-resize |
| `ScreenCapture.swift` | Region capture excluding our own windows |
| `Providers.swift` | Streaming Anthropic + OpenAI clients, cost estimation |
| `History.swift` | Snippet persistence, search, pruning |
| `Settings.swift` | Config load/save with debounce and live file watching |
| `Keychain.swift` | Per-provider API key storage |
| `PopoverController.swift`, `Views.swift`, `SettingsView.swift` | UI |
