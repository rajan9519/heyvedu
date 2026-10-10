# Building and distributing HeyVedu

This workflow produces an **Apple silicon (arm64)** drag-to-Applications DMG.
Intel Macs are not supported. The app still requires **macOS 14 (Sonoma) or later**;
signing and notarization do not change these hardware or OS requirements.

## Prerequisites

- Full Xcode with the macOS 26.4 SDK or newer and its command-line tools selected.
- Xcode's Metal toolchain, required by MLX. If missing, install it with
  `xcodebuild -downloadComponent MetalToolchain` (or Xcode's Components settings).
- Internet access for the pinned Swift packages and Apple's notarization service.
- Membership in the Apple Developer Program for public distribution.
- A **Developer ID Application** certificate and its private key installed in your
  login Keychain. Create the certificate through Xcode's account management or
  the Apple Developer portal. A Developer ID Installer certificate is not needed
  for this DMG because it contains an app, not a `.pkg` installer.

Confirm the tools and signing identity:

```bash
xcodebuild -version
security find-identity -v -p codesigning
```

If necessary, prefix the release command with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Configure signing (placeholders to fill later)

```bash
cp Config/release.env.example Config/release.env
```

Edit the ignored `Config/release.env`:

```bash
DEVELOPMENT_TEAM="YOUR_TEAM_ID"
SIGNING_IDENTITY="Developer ID Application: YOUR_NAME (YOUR_TEAM_ID)"
NOTARY_PROFILE="heyvedu-notary"
```

The Team ID is the 10-character identifier in your Apple Developer membership.
Copy the identity exactly from `security find-identity`. The script sources this
file as shell code, so use only configuration files you trust. Do not commit
certificates, private keys, or passwords.

## Store notarization credentials once

Create an app-specific password for the Apple ID associated with your developer
team at [account.apple.com](https://account.apple.com/). Then run:

```bash
xcrun notarytool store-credentials "heyvedu-notary" \
  --apple-id "YOUR_APPLE_ID@example.com" \
  --team-id "YOUR_TEAM_ID"
```

Enter `YOUR_APP_SPECIFIC_PASSWORD` at the secure prompt. This stores and validates
the credentials in Keychain; the release script uses only the profile name.
Use the same name as `NOTARY_PROFILE` in your config. Your Apple ID and password
do not need to be added to source files.

## Create the update signing key once

HeyVedu updates itself with [Sparkle](https://sparkle-project.org). Every update and the
update feed are signed with an EdDSA key; installed apps accept only updates signed with
the key whose public half they were built with. After the first build has fetched the
Swift packages (`./scripts/run.sh` or `./scripts/release.sh --unsigned`), run:

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

This stores the private key in your login Keychain and prints the public key. Paste it
into `SUPublicEDKey` in `Config/Info.plist` and commit that. Back up the private key
(`generate_keys -x sparkle-private-key.txt`) somewhere safe and never commit it: if it is
lost, installed copies can no longer be updated and users must download a new DMG by hand.
`release.sh` refuses to build when the Keychain key and `Config/Info.plist` disagree.

## Build a public release

```bash
./scripts/release.sh
```

The script:

1. Checks the configuration and notarization authentication.
2. Builds Release for arm64 using the checked-in package versions. It uses the
   same MLX plugin trust flag as `scripts/run.sh`.
3. Checks the executable's architecture, signs nested code before its containing
   app with Developer ID, a secure timestamp, and hardened runtime, then verifies
   the signatures. The app uses `Config/HeyVedu.entitlements` for microphone
   access; it is unsandboxed so global hotkeys and text insertion can work.
4. Submits a ZIP of the app to Apple, requires an `Accepted` result, staples the
   ticket to the app, and checks Gatekeeper acceptance.
5. Creates a compressed DMG with the app and an Applications shortcut, laid out by
   Finder with a drag arrow. macOS asks once to let your terminal control Finder;
   allow it (or later in System Settings > Privacy & Security > Automation).
6. Signs and notarizes the DMG, staples its ticket, and validates it with
   `stapler` and Gatekeeper.
7. Moves the finished image to `dist/HeyVedu-VERSION-arm64.dmg` and writes
   `dist/HeyVedu-VERSION-arm64.dmg.sha256`.
8. Writes the update feed to `dist/updates/`: `appcast.xml`, signed with the Sparkle key,
   and a copy of the DMG it points to.

The app and DMG are submitted separately so both carry their own stapled tickets.
This lets the copied app retain its ticket even after leaving the disk image.
Only distribute the final DMG after the script succeeds.

**Versions are chosen automatically** as `YY.MM.DDNN`: the build date (local time) and
that day's build count, e.g. `26.10.0601` for the first release on 6 October 2026. Day and
count share the last part so the version has the three parts Apple allows; `DDNN` compares
as one number, so later days and later builds of a day always sort higher. The
script fetches the published appcast (`SUFeedURL`) and also reads `dist/updates/appcast.xml`
(built but not uploaded yet), takes the later of the two, and then picks the next number:
`NN` goes up by one for another build on the same day and resets to `01` on a new day. The
same string is used for both the marketing version and the build number Sparkle compares. A
signed release stops if the feed can't be fetched (a 404 counts as "nothing published yet"),
so it never reuses a number. Unsigned test builds fall back to `01`.

## Publish the update

Installed apps read `https://app.heyvedu.com/updates/appcast.xml` (`SUFeedURL` in
`Config/Info.plist`) and download the DMG from the same folder. Upload the contents of
`dist/updates/` there, **the DMG first and `appcast.xml` last**, so no app sees the
feed before its download exists:

```bash
rsync -av dist/updates/HeyVedu-*.dmg SERVER:/var/www/app.heyvedu.com/updates/
rsync -av dist/updates/appcast.xml SERVER:/var/www/app.heyvedu.com/updates/
```

Keep the feed from being cached for long, for example in the `app.heyvedu.com` nginx server:

```nginx
location = /updates/appcast.xml {
    add_header Cache-Control "no-cache";
}
```

## Website download link

The website's download buttons point to `https://app.heyvedu.com/download`, a Cloudflare
Worker ([deploy/download-worker.js](../deploy/download-worker.js)) that reads
`updates/appcast.xml` from the R2 bucket and redirects to the DMG it names. Uploading a
new appcast therefore updates the link; nothing else changes per release.

One-time setup in the Cloudflare dashboard:

1. **Workers & Pages → Create → Create Worker** (Start with Hello World). Name it
   `heyvedu-download` and select **Deploy**.
2. Select **Edit code**, replace the contents with `deploy/download-worker.js`, and select
   **Deploy**.
3. In the Worker, open **Settings → Bindings → Add → R2 bucket**. Set the variable name to
   `BUCKET` and the bucket to `heyvedu`, then **Deploy**.
4. Open **Settings → Domains & Routes → Add → Route**. Choose the `heyvedu.com` zone, enter
   the route `app.heyvedu.com/download`, and save. Other `app.heyvedu.com` paths stay
   served directly from R2.
5. Optionally, disable the `workers.dev` URL on the same page; the route is all that's needed.

Check it: `curl -sI https://app.heyvedu.com/download` returns `302` with a `location` of the
latest DMG. If the appcast is missing or unreadable, it redirects to the website instead.
To change the Worker later, paste the updated file into **Edit code** again.

## Homebrew

`brew install --cask rajan9519/tap/heyvedu` installs from the
[rajan9519/homebrew-tap](https://github.com/rajan9519/homebrew-tap) repository. A scheduled
GitHub Action there reads `updates/appcast.xml` every six hours and bumps the cask's version
and SHA-256 to the DMG it names, so nothing needs doing per release. To publish a release to
Homebrew sooner, run the **Update HeyVedu cask** workflow by hand in that repository's
Actions tab. Because the cask points at `updates/HeyVedu-VERSION-arm64.dmg`, keep the
previous DMG in the bucket until the cask has moved on, or `brew install` fails its download.

How the app updates:

- It checks the feed about once a day, plus whenever the user chooses **Check for
  Updates…** in the menu bar menu.
- A newer build downloads silently in the background. The menu then offers **Restart to
  Update to HeyVedu VERSION**. If the user ignores it, the update installs when HeyVedu
  quits, so the next launch runs the new version.
- Debug builds and `--unsigned` builds never update themselves.

Build logs, notarization responses, the app, and Xcode's dSYM files remain under
`build/release.noindex/run.XXXXXX/`. Keep the dSYMs for crash symbolication. Release builds
do not bundle the speech or Vedu Scribe models; they download on first launch.

## Update the cleanup model

The Vedu Scribe cleanup model is hosted at
[huggingface.co/heyvedu/vedu-scribe-0.8b](https://huggingface.co/heyvedu/vedu-scribe-0.8b).
Each app release pins one exact commit of that repository, together with every file's size
and SHA-256 hash. The app downloads that commit on first use, verifies it, and deletes any
other revision. So an app update that pins a new commit replaces the model automatically,
while older app versions keep the model they were tested with.

To ship a new fine-tune:

1. Test it locally in a Debug build. Debug builds load a linked local model instead of the
   pinned download:

   ```bash
   ./scripts/install-cleanup-model.sh ~/path/to/new-model-folder
   ```

2. Update the model card (`README.md` in the model folder) with the new evaluation results,
   then upload the folder to the same repository:

   ```bash
   hf upload heyvedu/vedu-scribe-0.8b ~/path/to/new-model-folder . --commit-message "Round N"
   ```

3. Copy the full 40-character commit hash from the upload output (or the repository's
   **Files and versions** history) and pin it:

   ```bash
   ./scripts/pin-cleanup-model.sh FULL_COMMIT_HASH
   ```

4. Remove the local link, so the Debug build tests the real download, and try it:

   ```bash
   rm "$HOME/Library/Application Support/HeyVedu/Models/vedu-scribe-dev"
   ```

5. Commit the updated `DictationModelBackend.swift`, bump the app version, and release.

Never delete or rewrite published commits on Hugging Face: installed app versions still
download the commit they pinned. `release.sh` refuses to build until a commit is pinned.

## Test without Apple credentials

```bash
./scripts/release.sh --unsigned
```

This builds and verifies an **ad-hoc signed** image named
`dist/HeyVedu-VERSION-arm64-UNSIGNED.dmg`. It is useful for local packaging tests
but has no Developer ID signature or notarization ticket and is not a public
release. No Apple credentials are required.

## Release verification

On an Apple silicon Mac running macOS 14 (Sonoma) or later:

1. Download the final signed DMG through a browser, so the normal quarantine and
   Gatekeeper checks run. Test on a separate user account or Mac if possible.
2. Open the DMG, drag the app to Applications, eject the disk, and launch the app.
   macOS can show its normal first-launch confirmation; it should not require
   bypassing Gatekeeper or removing quarantine attributes.
3. Grant Microphone and Accessibility access. Wait for the first-run models,
   then check recording, local transcription, cleanup, and pasting into another
   app. Signing does not bypass these privacy permissions.
4. After initial setup, test another launch without an internet connection.

The script checks signatures and tickets, but a packaging build alone does not
verify microphone permissions or actual dictation on another machine.

## If notarization fails or times out

The script stops before publishing a new DMG. Inspect the `app-notary.plist` or
`dmg-notary.plist` response in that run's build directory. Rejected submissions
also have a `*-notary-log.json` file explaining Apple's findings. Correct the
reported signing problem and run the release again.

For a timeout, Apple may still be processing the submission. Use its returned
submission ID to inspect or wait for the result:

```bash
xcrun notarytool info "YOUR_SUBMISSION_ID" --keychain-profile "heyvedu-notary"
xcrun notarytool wait "YOUR_SUBMISSION_ID" --keychain-profile "heyvedu-notary"
xcrun notarytool log "YOUR_SUBMISSION_ID" --keychain-profile "heyvedu-notary" \
  /tmp/heyvedu-notary-log.json
```

Rerun the script once the issue is resolved. It intentionally does not publish
an artifact from a timed-out or rejected run.

See Apple's [distribution packaging guide](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
and [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
for certificate and notarization details.
