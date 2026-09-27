# HeyVedu

Private, push-to-talk dictation for macOS. Hold **Control + Option**, speak, and
release to insert polished text into the app you are using.

Speech recognition runs on your Mac with Parakeet, and the default S1-mini
cleanup engine also runs locally. Audio is kept in memory, transcripts are not
logged, and no dictation data leaves your Mac when using **S1-mini**, **Apple
Intelligence**, or cleanup-disabled mode.

> [!IMPORTANT]
> The optional **Claude Code** and **Codex** cleanup engines send transcript
> text—and any vocabulary supplied to them—to Anthropic and OpenAI,
> respectively. The app labels these options explicitly.

## What it does

- Dictates into almost any app that accepts pasted text.
- Starts listening while you hold **Control + Option** and stops when you
  release it.
- Transcribes English speech locally with NVIDIA Parakeet TDT 0.6B v3 through
  FluidAudio and Core ML.
- Removes fillers and false starts, applies self-corrections, and fixes
  punctuation and capitalization.
- Offers local cleanup with S1-mini by Superwhisper (the default) or Apple
  Intelligence.
- Lets you select any connected microphone and follows device changes.
- Supports a local preferred-spellings vocabulary for Apple Intelligence,
  Claude Code, and Codex cleanup.
- Keeps no dictation history and never writes recorded audio to disk.

For example:

> “I want to book a meeting for two, actually no, three PM”  
> becomes “I want to book a meeting for 3 PM.”

## Requirements

- An Apple silicon Mac
- macOS 26.4 or later
- Xcode with the macOS 26.4 SDK
- An internet connection for the initial build and first-run model downloads
- About 2.1 GB of free space for the speech and S1-mini models, plus build data

Apple Intelligence cleanup additionally requires a supported Mac with Apple
Intelligence enabled and its model downloaded. S1-mini does not require Apple
Intelligence.

## Install from source

There is currently no signed binary release. Clone or download this repository,
then run:

```bash
./scripts/run.sh
```

The script resolves the pinned Swift packages, builds a Debug app into `build/`,
and launches:

```text
build/Build/Products/Debug/HeyVedu.app
```

If `xcode-select` points to Command Line Tools instead of Xcode, set
`DEVELOPER_DIR` for that invocation:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/run.sh
```

You can also open `HeyVedu.xcodeproj` in Xcode, select the
**HeyVedu** scheme, and run it. Xcode may ask you to trust the pinned MLX
build-tool plugin; review the prompt and choose **Trust & Enable** to continue.

## First launch

HeyVedu is a menu-bar app, so it does not appear in the Dock. Look for
the microphone icon in the menu bar.

1. Grant **Microphone** access so the app can record while the hotkey is held.
2. Grant **Accessibility** access so it can observe the push-to-talk hotkey and
   paste the result at the cursor.
3. Wait until the menu says **Hold ⌃⌥ to dictate**.

The first launch downloads and prepares two models:

- Parakeet speech recognition: about 600 MB
- S1-mini transcript cleanup: about 1.5 GB

These downloads come from Hugging Face. They contain model files only; no audio
or transcript is uploaded. Later launches use the cached copies.

Because source builds are ad-hoc signed, macOS may forget the Accessibility
grant after rebuilding. See [Troubleshooting](#troubleshooting) if the hotkey
stops working.

## Use it

1. Put the text cursor where the dictation should appear.
2. Hold **Control + Option** together. Wait for the floating indicator to say
   **Listening** before speaking, especially with Bluetooth microphones.
3. Speak, then release both keys.
4. HeyVedu transcribes, optionally cleans the text, and pastes it at the
   cursor.

Press **Escape** while recording to cancel. A quick tap shorter than about 0.2
seconds, another key pressed with the chord, or an added modifier is treated as
a keyboard shortcut and discarded. New dictations are ignored while the
previous one is being processed.

## Settings

Click the menu-bar icon to configure the app.

### Cleanup engines

| Engine | Where it runs | Notes |
| --- | --- | --- |
| **S1-mini by Superwhisper** | On your Mac | Default; English-only; choose Casual, Semi-casual, Semi-formal, or Formal style. Does not use the vocabulary list. |
| **Apple Intelligence** | On your Mac | Uses Apple's on-device Foundation Model. Falls back to the raw transcript if the model is unavailable. |
| **Claude Code** | Anthropic's service via the local `claude` CLI | Optional; requires Claude Code to be installed and authenticated. Sends transcript text and configured vocabulary to Anthropic. |
| **Codex** | OpenAI's service via the local `codex` CLI | Optional; requires Codex to be installed and authenticated. Sends transcript text and configured vocabulary to OpenAI. Each dictation uses an ephemeral CLI session. |

The menu shows Claude Code and Codex when their respective CLIs are installed;
when both are present, you can choose either one.

Turn off **Clean Up Transcripts** to paste the raw, locally generated transcript.
If a cleanup engine fails or rejects a result, HeyVedu pastes the raw
transcript instead and tells you why.

### Vocabulary

Choose **Edit Vocabulary…** to add preferred spellings for names, products, and
jargon. The list is stored locally at:

```text
~/Library/Application Support/HeyVedu/vocabulary.json
```

Vocabulary is used by Apple Intelligence, Claude Code, and Codex. S1-mini currently
ignores it.

### Microphone

Choose **System Default** or a specific input device from the **Microphone**
menu. If a selected device is missing, HeyVedu falls back to the system
default and shows a notice. If a device disappears while recording, it
processes the audio captured so far.

## Privacy

The fully local path is the default:

```text
Microphone → in-memory audio → on-device Parakeet → on-device S1-mini → paste
```

| Data | S1-mini / cleanup off | Apple Intelligence | Claude Code | Codex |
| --- | --- | --- | --- | --- |
| Recorded audio | Memory only; stays on-device | Memory only; stays on-device | Memory only; stays on-device | Memory only; stays on-device |
| Speech recognition | On-device | On-device | On-device | On-device |
| Transcript cleanup | On-device | On-device | Sent to Anthropic | Sent to OpenAI |
| Preferred vocabulary | Local file; unused by S1-mini | Local file and on-device prompt | Local file and sent to Anthropic as cleanup instructions | Local file and sent to OpenAI as cleanup instructions |
| Dictation history | Not stored | Not stored | Not stored by HeyVedu; Anthropic's service terms apply to requests | Codex runs with ephemeral sessions; OpenAI's service terms apply to requests |

Text is inserted by briefly placing it on the macOS clipboard, issuing
**Command + V**, and restoring the previous clipboard contents after roughly
half a second. Clipboard managers are asked to treat this entry as transient,
but their behavior is outside the app's control.

Debug builds write timing and error diagnostics to
`~/Library/Logs/HeyVedu/debug.log`. Audio, transcripts, vocabulary, and
typed keys are not written to this log.

## Troubleshooting

### The menu says “Permissions needed”

Open **System Settings → Privacy & Security**, enable HeyVedu under both
**Microphone** and **Accessibility**, then relaunch the app.

### The hotkey stopped working after a rebuild

Ad-hoc signatures can cause macOS to retain a stale Accessibility entry. Quit
HeyVedu, run:

```bash
tccutil reset Accessibility com.rajan.heyvedu
```

Relaunch the app and grant Accessibility access again.

### A model failed to load

Check the internet connection and available disk space, then click **Retry
Loading Speech Model** when that option appears. For S1-mini, switching the
cleanup engine away and back retries its preparation. First-time Core ML
compilation can take longer than later launches.

### Dictation is transcribed but not inserted

Confirm Accessibility access is enabled. The app simulates **Command + V**, so
the target application must accept paste at the current cursor position.

### Apple Intelligence is unavailable

Check that the Mac supports Apple Intelligence, that it is enabled in System
Settings, and that the system model has finished downloading. You can continue
with S1-mini or raw transcripts meanwhile.

### Bluetooth audio starts late

Keep holding the hotkey until the HUD says **Listening**, then begin speaking.
This gives the device time to switch into its microphone profile.

## How it works

HeyVedu records 16 kHz mono audio in memory with AVAudioEngine. FluidAudio
runs Parakeet through Core ML for speech recognition. The selected cleanup
engine normalizes the transcript, then the app temporarily uses the clipboard
to paste the result into the frontmost application.

Dependencies and model revisions are pinned in the project. S1-mini model files
are also checked against pinned SHA-256 hashes before loading.

## Current limitations

- English dictation only
- Apple silicon only
- Source build; no notarized installer yet
- The global hotkey is fixed to **Control + Option**
- Text insertion relies on **Command + V** and may not work in fields that block
  paste
- Restoring the clipboard may not preserve lazily provided clipboard content
  from every application
- S1-mini does not use custom vocabulary

## License

HeyVedu is licensed under the [GNU General Public License v3.0](LICENSE).
Third-party packages and downloaded models retain their own licenses. S1-mini
is provided by Superwhisper under its published model license.
