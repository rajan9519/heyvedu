# HeyVedu feature plan

Researched October 2026 from each product's website and README. Features are
what each product says it offers; we did not test the apps hands-on.

> **Status:** Phase 1 items 1.1 (configurable hotkey) and 1.2 (hands-free mode)
> are done. **Next: 1.3, the personal dictionary.** See
> [§7 Implementation status](#7-implementation-status-handoff-notes) for what was
> built, where the code is, how it was verified, and notes for the next items.
> Update §7 and this line when you finish a roadmap item.

## 1. What HeyVedu does today

- Fixed push-to-talk on **⌃⌥**, Escape to cancel
- Local Parakeet TDT v3 transcription (English only)
- Local cleanup: Vedu Scribe (default) or Apple Intelligence. Removes fillers,
  applies self-corrections, fixes punctuation
- Microphone picker that follows device changes
- Pastes through the clipboard with ⌘V, then restores the clipboard
- No history, and audio is never written to disk
- Floating HUD, a welcome guide, and Sparkle auto-updates
- Gone as of `f6883a6`: the preferred-spellings vocabulary. Vedu Scribe ignored it.

## 2. Competitor landscape

| App | Model / price | Notable for |
| --- | --- | --- |
| **Wispr Flow** | Cloud only. Free tier, Pro $12–15/mo | Dictionary that learns, snippets, per-app *Styles*, backtracking, list formatting, whisper mode, 100+ languages, dev features (file tagging in Cursor, camelCase), Notetaker, team dictionaries |
| **VoiceInk** | Open source (GPL), paid binaries $25–49 one-time | *Power Mode* (settings per app/site), screen-context awareness, dictionary + smart replace + auto-learn, AI modes (email, notes, rewrite selection), assistant mode, history with search/replay/export, file transcription queue, live partial text, stats dashboard, settings backup |
| **Superwhisper** | Freemium, Pro ~$8.49/mo | Custom modes (formal/casual/legal/chat), *Super Mode* using screen context, vocabulary, translation to English, file transcription, meeting notes |
| **Spokenly** | Free for local models, BYOK, Pro $9.99/mo | Parakeet/Whisper, word replacements, dictionary, spoken punctuation commands, agentic macOS actions, **MCP voice input for Claude Code/Codex/Cursor**, Local Only mode, meeting recording |
| **Hex** | Free, open source | Hold-to-talk **plus double-tap to lock** hands-free, Parakeet v3 via FluidAudio (same stack as us) |
| **Handy** | Free, open source | Hold / toggle modes, Silero VAD, history, dictionary, audio feedback, configurable paste method & delay, overlay position, CLI/Raycast control |
| **FluidVoice** | Free, open source | Live transcription in the notch, Command Mode (launch apps, run Shortcuts), Write Mode (rewrite in place), per-app prompts, opt-in history with export, daily stats |
| **OpenWhispr** | Open source plus cloud | Translation hotkey, file/URL import, voice assistant with screenshot context, edit highlighted text, meetings with local diarization, notes, MCP server |

### Gap matrix

✅ has it · ◐ partly · — missing

| Capability | HeyVedu | Flow | VoiceInk | Superwhisper | Spokenly | Hex | Handy | FluidVoice |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Fully local by default | ✅ | — | ✅ | ◐ | ✅ | ✅ | ✅ | ✅ |
| Custom hotkey | — | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Hands-free / toggle mode | — | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Custom dictionary | — | ✅ | ✅ | ✅ | ✅ | — | ✅ | ◐ |
| Word replacements / snippets | — | ✅ | ✅ | ◐ | ✅ | — | — | — |
| Per-app styles | — | ✅ | ✅ | ✅ | ◐ | — | — | ✅ |
| Edit selected text by voice | — | ✅ | ✅ | ◐ | ◐ | — | — | ✅ |
| Spoken formatting commands | ◐ | ✅ | ◐ | ◐ | ✅ | — | — | — |
| Live partial transcript | — | — | ✅ | — | — | — | — | ✅ |
| History (opt-in) | — | ✅ | ✅ | ✅ | ◐ | — | ✅ | ✅ |
| Usage stats | — | ✅ | ✅ | — | — | — | — | ✅ |
| Languages beyond English | — | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| File transcription | — | — | ✅ | ✅ | ✅ | — | — | — |
| Voice commands / agent actions | — | ◐ | ✅ | — | ✅ | — | — | ✅ |

**Where we stand.** Our privacy story is the strongest of the group: no
history, no network after setup, and our own cleanup model. On the basics we
are behind every free competitor: hotkey choice, hands-free mode, a dictionary
and per-app behaviour. The plan closes those gaps first, then builds on the
local-first strength.

## 3. Principles for choosing

1. **Local stays the default.** Never add an account requirement or a cloud
   path that is on by default.
2. **No history unless the user turns it on.** Anything that remembers text
   must be opt-in, have a retention limit, and stay in RAM or encrypted storage.
3. **Do it deterministically when we can.** The vocabulary removal showed that
   features which depend on a small LLM obeying instructions break silently.
   Prefer ASR-level biasing and rule-based post-processing. Use the model only
   for what rules cannot do.
4. **Keep the hold-to-talk flow fast.** Every feature has to leave dictation
   latency unchanged.

## 4. Roadmap

### Phase 1: parity basics (about 2–4 weeks)

| # | Feature | Why | Implementation notes |
| --- | --- | --- | --- |
| 1.1 | ✅ **Configurable hotkey, including Fn/Globe and right-side modifiers** | It is a listed limitation, and every competitor offers it | Done, modifier-only (see §7). Key+modifier combos such as ⌥Space are not supported yet. The recorder is a standalone window; move it into the Settings window when 1.7 lands |
| 1.2 | ✅ **Hands-free mode: double-tap to lock, tap to stop** | For long dictation. Hex, Handy and Flow all have it | Done (see §7). Still missing: an elapsed timer in the HUD, and auto-stop on silence, which comes with 1.5 |
| 1.3 | **Personal dictionary, rebuilt** | The top request across the category. We just removed ours | (a) Bias the ASR with FluidAudio's `CustomVocabularyContext`, which the pinned checkout already has (CTC keyword boosting). (b) Apply exact replacement rules *after* cleanup so Vedu Scribe cannot drop them (`teh → the`, `hey vedu → HeyVedu`). (c) Mark dictionary terms as protected so the cleanup guard rejects any output that changes them |
| 1.4 | **Paste the last result again, and recover from failed pastes** | Paste fails in fields that block it, and users lose their words | Keep only the last result in memory and clear it after about 5 minutes. Add a menu item and an optional hotkey. When the paste target has no focused text field (checked through AX), show a "Copied, press ⌘V" HUD and leave the text on the clipboard |
| 1.5 | **Voice activity detection: trim silence and auto-stop in hands-free mode** | Lower latency, fewer hallucinations on near-silent clips | FluidAudio `VadManager`. Trim leading and trailing silence before ASR |
| 1.6 | **Audio cues and a better HUD** | Feedback without looking at the HUD. Both Handy and Flow have it | Optional start/stop/cancel sounds, a live input-level meter, and a choice of HUD position, including the notch |
| 1.7 | **Settings window** | The menu is crowded, and phases 1–2 add a lot of settings | SwiftUI `Settings` scene with tabs: General, Hotkey, Dictionary, Apps, Models, Privacy. The menu keeps only status and quick toggles |

### Phase 2: differentiators (about 4–8 weeks)

| # | Feature | Why | Implementation notes |
| --- | --- | --- | --- |
| 2.1 | **App-aware styles (our version of Power Mode)** | Flow, VoiceInk and Superwhisper all sell this | Detect the frontmost bundle ID, plus the browser URL host through AX. Built-in presets: **Chat** (Slack, Messages, WhatsApp: casual, no trailing period), **Email** (Mail, Gmail: sentence case, paragraphs), **Code** (Terminal, Xcode, VS Code, Cursor: no auto-capitalization, keep identifiers, optional raw mode), **Notes**. Phase 2a uses rules only. Phase 2b adds a style token to the Vedu Scribe fine-tune |
| 2.2 | **Spoken formatting and lists** | Flow and Spokenly have it | Deterministic parser for "new line", "new paragraph", "bullet point", "numbered list", "comma", "period", "open quote" and similar. Turn spoken enumerations into lists. Add Vedu Scribe training data for list formatting |
| 2.3 | **Snippets / voice shortcuts** | Flow's snippets. Cheap to build, and people use them every day | Spoken trigger → expansion (email signature, Calendly link, address). Stored locally in an exact-match table that is checked before cleanup |
| 2.4 | **Edit selected text by voice ("Rewrite mode")** | The biggest step up from plain dictation. Flow, VoiceInk and FluidVoice have it | A second hotkey. Read the selection through AX, or ⌘C as a fallback. Speak an instruction ("make it shorter", "translate to Hindi"). Rewrite locally with Apple Intelligence, or with an optional larger local model through MLX (≈3–4B, a separate download). Replace the selection |
| 2.5 | **Languages beyond English** | Every competitor has them. Parakeet v3 already covers 25 European languages | Language picker (auto or fixed). Use Apple Intelligence for non-English cleanup, or cleanup off. Later, train a multilingual Vedu Scribe. Also evaluate FluidAudio's multilingual Nemotron and Cohere models for Hindi and other Indic languages |
| 2.6 | **More robust insertion** | ⌘V does not work in some fields | Insert directly through AX (`kAXSelectedTextAttribute`) when it is supported. Fall back to simulated typing in fields that block paste. Per-app paste delay. Optional "press Return after paste" per app (chat, terminals) |
| 2.7 | **Live partial transcript in the HUD** | Users can see that it is working. VoiceInk and FluidVoice have it | FluidAudio's streaming or sliding-window ASR runs while the user speaks. The final pass is unchanged |

### Phase 3: bigger bets (pick based on user feedback)

| # | Feature | Notes |
| --- | --- | --- |
| 3.1 | **Opt-in local history** | Off by default. Stored in a Keychain-encrypted SQLite database, with retention of 1 day, 7 days or 30 days. Offers copy, re-run cleanup and delete-all. Audio is never kept. This change would require updating the README privacy table |
| 3.2 | **Usage stats without storing text** | Word count, WPM and estimated time saved, kept only as counters. Good for retention and sharing |
| 3.3 | **Dictionary auto-learn** | Detect when the user edits a pasted word right away (AX read-back within a few seconds) and *suggest* adding it. The user must confirm |
| 3.4 | **File transcription** | Drag in audio or video, get text or SRT. Reuses the ASR stack. Separate window |
| 3.5 | **Developer mode** | camelCase/snake_case commands, recognizing filenames from the frontmost IDE window title, and an **MCP server** so Claude Code, Codex and Cursor can ask for voice input (as Spokenly does) |
| 3.6 | **Voice commands** | "Open Safari" or "run Shortcut X" through a command hotkey. Use the Shortcuts integration rather than a free-form agent |
| 3.7 | **Meeting / system-audio capture with diarization** | FluidAudio ships a Diarizer. This is a big scope expansion, so build it only if users ask |

### Not planned

Cloud ASR as a default, accounts and team workspaces, Intel support, Windows,
and mobile apps. These conflict with the product's local, simple positioning or
cost more than they are worth right now.

## 5. Suggested order

1. ~~**1.1 + 1.2** (hotkey, hands-free)~~: done, see §7
2. **1.3** ← **next** (dictionary): the most-requested feature, and it fills the gap from the recent removal
3. **1.7** (settings window): needed before more settings arrive
4. **1.4, 1.5, 1.6**: polish
5. **2.1 + 2.2 + 2.3**: app styles, formatting and snippets share one post-processing pipeline, so build them together
6. **2.4** rewrite mode, then **2.5** languages
7. Phase 3, chosen from user feedback

## 6. Open questions

- Should the larger rewrite model (2.4) be optional, or should we rely on Apple
  Intelligence alone?
- Does opt-in history (3.1) fit the brand, or should "no history, ever" stay a
  selling point?
- Which languages come first after English? Hindi needs a model other than Parakeet v3.

## 7. Implementation status (handoff notes)

Last updated 2026-10-07. **Phase 1 progress: 1.1 and 1.2 are done. Next up: 1.3
(personal dictionary), then 1.7, 1.4, 1.5, 1.6.**

The 1.1/1.2 work is committed on `main` in the commit "Add configurable dictation
shortcut and hands-free mode".

### 1.1 Configurable hotkey: done

What the user sees:
- The menu has one item, **Dictation Shortcut: ⌃⌥…**. It opens a recorder
  window: hold modifier keys, let go, then click **Use Shortcut**. The window
  also has **Reset to ⌃⌥**. The user asked for presets to be removed, so don't
  add a preset picker back.
- Shortcuts are **modifier keys only** (⌃ ⌥ ⇧ ⌘ fn). A non-modifier key in the
  recorder shows an error.
- A single key must be fn or a **right-hand** ⌘/⌥/⌃. Left-hand single keys and
  Shift alone are rejected (`Hotkey.problem`).
- **Side rule:** a shortcut recorded with any right-hand key keeps the exact side
  of every key, so Right ⌥⌘ ignores the left keys. A shortcut recorded with
  left-hand keys only accepts either side, and so does the default ⌃⌥.
- When fn is chosen and macOS still acts on 🌐 (`AppleFnUsageType` ≠ 0 in
  `com.apple.HIToolbox`), both the menu and the recorder link to Keyboard
  settings.
- The status text, the launch hint and onboarding (welcome, permissions,
  practice keycaps, tips) all show the configured hotkey.

Code:
- `HeyVedu/Hotkey/Hotkey.swift` (new): the `Hotkey` model with `modifiers`,
  `leftOnly` and `rightOnly`. Matching uses the device-dependent left/right flag
  bits (`isHeld`, `isPartOfOtherShortcut`). It also has display helpers
  (`symbols`, `spokenName`, `keycaps`) and persistence (`Hotkey.saved` /
  `save()`, a JSON blob under UserDefaults `dictationHotkey`).
- `HeyVedu/Hotkey/HotkeyRecorder.swift` (new): `HotkeyRecorderWindowController`
  plus a SwiftUI view. It suspends the global hotkey while open
  (`controller.hotkeySuspended`).
- `HeyVedu/Hotkey/HotkeyMonitor.swift`: takes a `hotkey` property instead of the
  hard-coded ⌃⌥, and adds `isSuspended` and `reset()`.
- `DictationController`: `hotkey` (persisted, pushed to the monitor),
  `handsFreeEnabled`, `hotkeySuspended`. The monitor property was renamed
  `hotkey` → `hotkeyMonitor`.
- `Onboarding.swift`: `Keycap` is no longer private. The new `HotkeyKeycaps`
  view draws any hotkey.
- `MenuContent` takes a `recordShortcut` closure. `AppDelegate` owns
  `hotkeyRecorder`.

### 1.2 Hands-free mode: done

What the user sees:
- Double-tap the hotkey (second press within 350 ms of a quick tap) and
  recording continues without holding the keys. The HUD shows a red lock and
  "Hands-free — press ⌃⌥ to finish, Esc to cancel".
- The next press of the hotkey finishes; Esc cancels. Other keys typed while
  locked pass through and don't cancel.
- Hands-free recording automatically finishes after **10 minutes**
  (`DictationController.handsFreeLimit`).
- The menu toggle **Double-Tap for Hands-Free** is on by default (UserDefaults
  `handsFreeEnabled`).
- Side effect: with hands-free on, a single quick tap keeps the mic on about
  350 ms longer before the press is discarded.

Code:
- `HotkeyMonitor` phases: `idle → arming → active` (push-to-talk), and
  `arming → tapped → lockHeld → locked → awaitingRelease` (hands-free). There's
  a new `.locked` event. `awaitingRelease` waits until *all* of the hotkey's keys
  are up, so the finishing press can't re-arm.
- `DictationController.handle(.locked)` shows the hands-free HUD and starts the
  limit timer. If the controller is busy or the mic failed, it calls
  `hotkeyMonitor.reset()` so the next press isn't taken as "finish".
  `endHandsFree()` runs on every finish or cancel.
- `RecordingHUD.showRecording(…, handsFree:)` sets `HUDModel.handsFree`, which
  switches the listening icon to `lock.fill`.

### Verification so far

- `xcodebuild` Debug build succeeds.
- A headless harness drove `HotkeyMonitor.handle` with synthetic `CGEventFlags`
  and 22 checks passed. It covered hold and release, single tap, double-tap
  lock and finish, no re-arm, Esc versus typing while locked, shortcut
  cancellation, Right ⌘ versus left ⌘, fn, Right ⌥⌘ versus left or mixed keys,
  and recorder validation. The harness is not in the repo: it compiled copies of
  `Hotkey.swift` and `HotkeyMonitor.swift` with `fileprivate func handle` made
  internal, plus a stub `DebugTrace`. Consider adding a unit-test target.
- **Not yet tried with a real keyboard in the running app.** Before building on
  this, run `./scripts/run.sh` and try: double-tap then tap, Right ⌘ alone while
  using ⌘C, fn with "Press 🌐 key to" changed and unchanged, and the recorder.

### Docs touched

- `README.md`: the intro, "What it does", a "Hands-free dictation" section, a
  "Dictation shortcut" settings section, and the limitations list.
- The website (`index.html`) still says Control + Option, which is still the
  default. It wasn't changed.

### Notes for the next features

- **1.3 Dictionary:** the earlier vocabulary feature was removed in `f6883a6`
  because Vedu Scribe ignored it. Don't route terms through the cleanup prompt
  only. Use FluidAudio's `CustomVocabularyContext`
  (`build/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/`)
  and deterministic post-cleanup replacements.
- **1.7 Settings window:** move the shortcut recorder and hands-free toggle into
  it. The menu should keep only status and quick toggles.
- **1.5 VAD:** use it to add auto-stop on silence for hands-free mode, and to
  trim silence. The first ~0.35 s of a hands-free recording is the double-tap
  itself.

## Sources

- https://tryvoiceink.com · https://tryvoiceink.com/docs · https://github.com/Beingpax/VoiceInk
- https://wisprflow.ai/features · https://wisprflow.ai/pricing
- https://superwhisper.com
- https://spokenly.app
- https://github.com/kitlangton/Hex
- https://github.com/cjpais/Handy
- https://github.com/altic-dev/FluidVoice
- https://github.com/OpenWhispr/openwhispr
- https://www.getvoibe.com/resources/best-free-dictation-apps/
