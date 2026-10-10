# HeyVedu

Private, push-to-talk dictation for macOS. Hold **Control + Option** (or a
shortcut you choose), speak, and
release to insert polished text into the app you are using.

Speech recognition and the default Vedu Scribe text cleanup run on your Mac. Audio
stays in memory, transcripts are not logged, and the default dictation flow
does not upload your speech or text. The default flow needs an internet
connection only for the initial build and model downloads.

## What it does

- Dictates into almost any app that accepts pasted text.
- Starts listening while you hold **Control + Option** and stops when you
  release it. You can pick another shortcut, such as fn or the right ⌘ key.
- Double-tap the shortcut to dictate hands-free, then press it once more to
  finish.
- Transcribes English speech locally with NVIDIA Parakeet TDT 0.6B v3 through
  FluidAudio and Core ML.
- Removes fillers and false starts, applies self-corrections, and fixes
  punctuation and capitalization.
- Offers local cleanup with Vedu Scribe, HeyVedu's own model (the default), or
  Apple Intelligence.
- Writes names and terms from your personal dictionary exactly as you spell
  them.
- Lets you select any connected microphone and follows device changes.
- Keeps no dictation history and never writes recorded audio to disk.

For example:

> “I want to book a meeting for two, actually no, three PM”  
> becomes “I want to book a meeting for 3 PM.”

## Requirements

- An Apple silicon Mac
- macOS 14 (Sonoma) or later
- Xcode with the macOS 26.4 SDK
- An internet connection for the initial build and first-run model downloads
- About 1.2 GB of free space for the speech and Vedu Scribe models, plus build data

Apple Intelligence cleanup additionally requires macOS 26 or later, a supported
Mac with Apple Intelligence enabled, and its model downloaded. Vedu Scribe does
not require Apple Intelligence.

## Download

Download the latest signed and notarized release from
[app.heyvedu.com/download](https://app.heyvedu.com/download), open the disk image, and
drag HeyVedu to Applications. The app checks for updates and installs them itself.

Or install it with [Homebrew](https://brew.sh):

```bash
brew install --cask rajan9519/tap/heyvedu
```

## Install from source

Open `HeyVedu.xcodeproj` in Xcode, select the **HeyVedu** scheme and press ⌘R.
Xcode may ask you to trust the pinned MLX build-tool plugin; review the prompt and
choose **Trust & Enable** to continue.

Debug builds are named **HeyVedu Dev** (bundle ID `com.heyvedu.app.dev`) and run
from Xcode's DerivedData, so they never replace or collide with an installed
HeyVedu. They ask for Microphone and Accessibility separately from the installed app.

Debug builds are ad-hoc signed unless you configure a certificate, and macOS forgets
an ad-hoc app's Accessibility grant after every rebuild. To keep the grants across
rebuilds, sign Debug builds with any certificate you own:

```bash
cp Config/DebugSigning.local.xcconfig.example Config/DebugSigning.local.xcconfig
# set CODE_SIGN_IDENTITY and DEVELOPMENT_TEAM; the file is gitignored
```

To build and launch the same Debug app without Xcode's UI:

```bash
./scripts/run.sh
```

If `xcode-select` points to Command Line Tools instead of Xcode, set
`DEVELOPER_DIR` for that invocation:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/run.sh
```

## Build a DMG release

The release script builds an **Apple silicon (arm64)** DMG for macOS 14 or
later, signs the app and disk image with Developer ID, and notarizes and staples
both. Intel Macs are not supported.

```bash
cp Config/release.env.example Config/release.env
# Fill in your Developer ID identity and Team ID, and store notarization
# credentials in Keychain as described in docs/RELEASING.md.
./scripts/release.sh
```

For a local packaging test without Apple credentials:

```bash
./scripts/release.sh --unsigned
```

Outputs go to `dist/`. The unsigned test image is clearly labeled and is not
ready for public distribution. See [Releasing](docs/RELEASING.md) for complete
signing, Apple ID setup, notarization, and installation verification steps.

## First launch

HeyVedu opens a short welcome guide that walks through the steps below and
a practice dictation. Once you finish it, the HeyVedu window opens, and it
opens again each time you launch the app or click its Dock icon. Closing the
window leaves HeyVedu running in the menu bar. Click **Show Welcome Guide…** on
the window's Home page to see the guide again.

1. Grant **Microphone** access so the app can record while the hotkey is held.
2. Grant **Accessibility** access so it can observe the push-to-talk hotkey and
   paste the result at the cursor.
3. Wait until the menu says **Hold ⌃⌥ to dictate**.

The first launch downloads and prepares two models:

- Parakeet speech recognition: about 600 MB
- Vedu Scribe transcript cleanup: about 560 MB

These downloads come from Hugging Face. They contain model files only; no audio
or transcript is uploaded. Later launches use the cached copies.

You can dictate while Vedu Scribe downloads: HeyVedu pastes the raw transcript
meanwhile and says so once. The menu shows the download's progress, and a
notice appears when cleanup starts working.

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

### Hands-free dictation

For longer dictation, double-tap the shortcut instead of holding it. The
floating indicator shows a lock while HeyVedu keeps listening. Press the
shortcut once more to finish, or press **Escape** to cancel. You can type while
it listens; only Escape cancels. A hands-free recording stops by itself after
10 minutes. Turn off **Double-Tap for Hands-Free** in the menu, or in the
window's Shortcut section, to disable it.

## Settings

Settings live in the HeyVedu window. Click the Dock icon, or choose **Open
HeyVedu…** from the menu-bar icon. Its sidebar has **Home** (status,
permissions and the welcome guide), **General**, **Shortcut**, **Dictionary**
and **Models**. The menu-bar icon keeps quick toggles for cleanup, hands-free
mode and the microphone.

### Dictation shortcut

The default is **⌃⌥**. To change it, open the **Shortcut** section of the window,
click **Change…**, hold the modifier keys you want, and let go. Shortcuts use modifier keys
only. A single key must be fn or a right-hand ⌘, ⌥ or ⌃, because the left-hand
keys start too many other shortcuts.

A shortcut recorded with any right-hand key only responds to the exact keys you
held. For example, **Right ⌥⌘** ignores the left ⌥ and ⌘ keys. A shortcut
recorded with left-hand keys only works with either side's keys.

macOS acts on the fn (🌐) key itself. If you choose fn, set **System Settings
→ Keyboard → Press 🌐 key to** to **Do Nothing**. The Home and Shortcut
sections link there until you do.

### Cleanup engines

| Engine | Where it runs | Notes |
| --- | --- | --- |
| **Vedu Scribe** | On your Mac | Default. HeyVedu's own cleanup model, a Qwen3.5-0.8B fine-tune ([model card](https://huggingface.co/heyvedu/vedu-scribe-0.8b)). English-only; downloads about 560 MB on first use. |
| **Apple Intelligence** | On your Mac | Uses Apple's on-device Foundation Model. Falls back to the raw transcript if the model is unavailable. |

Choose the engine in the window's **General** section. The **Models** section shows
each model's download and lets you start or retry it. Turn off **Clean Up
Transcripts** to paste the raw, locally generated transcript.
If a cleanup engine fails or rejects a result, HeyVedu pastes the raw
transcript instead and tells you why.

### Dictionary

Open the window's **Dictionary** section to list words HeyVedu should always write
your way: names, product terms and jargon. For each word you can add other ways
the transcript writes it under **Also heard as**, one at a time (press Return
after each), such as “hey vedu” or “Hey, we do” for HeyVedu, or “teh” for the.
Because each one is entered separately, an alternative can contain a comma.
Punctuation between words doesn't matter when matching, so “hey we do” also
catches “Hey, we do.”

After cleanup, every match is replaced with your spelling. If a cleanup engine
changes a listed word, HeyVedu pastes the raw transcript for that part instead.
The **Try it** field shows the result on a sample sentence.

The dictionary is saved in `~/Library/Application Support/HeyVedu/Dictionary.json`
and only holds what you type into it.

### Microphone

Choose **System Default** or a specific input device from the **Microphone**
menu, or in the window's General section. If a selected device is missing, HeyVedu falls back to the system
default and shows a notice. If a device disappears while recording, it
processes the audio captured so far.

## Privacy

The fully local path is the default:

```text
Microphone → in-memory audio → on-device Parakeet → on-device Vedu Scribe → paste
```

| Data | Vedu Scribe / cleanup off | Apple Intelligence |
| --- | --- | --- |
| Recorded audio | Memory only; stays on-device | Memory only; stays on-device |
| Speech recognition | On-device | On-device |
| Transcript cleanup | On-device | On-device |
| Dictation history | Not stored | Not stored |
| Personal dictionary | Your words only, on disk | Your words only, on disk |

Text is inserted by briefly placing it on the macOS clipboard, issuing
**Command + V**, and restoring the previous clipboard contents after roughly
half a second. Clipboard managers are asked to treat this entry as transient,
but their behavior is outside the app's control.

Debug builds write timing and error diagnostics to
`~/Library/Logs/HeyVedu/debug.log`. Audio, transcripts, and typed
keys are not written to this log.

## Troubleshooting

### The menu says “Permissions needed”

Open **System Settings → Privacy & Security**, enable HeyVedu under both
**Microphone** and **Accessibility**, then relaunch the app.

### The hotkey stopped working after a rebuild

Ad-hoc signatures can cause macOS to retain a stale Accessibility entry. Quit
HeyVedu, run:

```bash
tccutil reset Accessibility com.heyvedu.app
```

Relaunch the app and grant Accessibility access again.

### A model failed to load

Check the internet connection and available disk space, then click **Retry
Loading Speech Model** when that option appears. For Vedu Scribe, the next
dictation retries its preparation. First-time Core ML
compilation can take longer than later launches.

### Dictation is transcribed but not inserted

Confirm Accessibility access is enabled. The app simulates **Command + V**, so
the target application must accept paste at the current cursor position.

### Apple Intelligence is unavailable

Check that the Mac runs macOS 26 or later and supports Apple Intelligence, that
it is enabled in System Settings, and that the system model has finished
downloading. You can continue
with Vedu Scribe or raw transcripts meanwhile.

### Bluetooth audio starts late

Keep holding the hotkey until the HUD says **Listening**, then begin speaking.
This gives the device time to switch into its microphone profile.

## How it works

HeyVedu records 16 kHz mono audio in memory with AVAudioEngine. FluidAudio
runs Parakeet through Core ML for speech recognition. The selected cleanup
engine normalizes the transcript, personal dictionary replacements are applied,
then the app temporarily uses the clipboard to paste the result into the
frontmost application.

Dependencies and model revisions are pinned in the project. Vedu Scribe files
are also checked against pinned SHA-256 hashes before loading.
When an app update pins a newer model revision, the app downloads it on next use
and deletes the old one.

## Current limitations

- English dictation only
- Apple silicon only
- Signed releases require a Developer ID certificate and notarization credentials
- Shortcuts are modifier keys only; a letter or Space can't be part of one
- Text insertion relies on **Command + V** and may not work in fields that block
  paste
- Restoring the clipboard may not preserve lazily provided clipboard content
  from every application

## License

HeyVedu is licensed under the [GNU General Public License v3.0](LICENSE).
Third-party packages and downloaded models retain their own licenses. Vedu
Scribe is released under Apache-2.0.
