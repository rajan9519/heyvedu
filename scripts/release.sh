#!/usr/bin/env bash
# Build an Apple silicon DMG. Public releases require Developer ID + notarization.
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh [--unsigned] [--config PATH]

Default: sign and notarize the app and DMG using Config/release.env.
--unsigned: create an ad-hoc signed DMG for local testing, without credentials.
--config: source a trusted shell configuration file instead of Config/release.env.
Outputs: dist/HeyVedu-VERSION-arm64[-UNSIGNED].dmg and its SHA-256 checksum.
Signed releases also write dist/updates/ (appcast.xml and the DMG) for the update server.
EOF
}

fail() { echo "Error: $*" >&2; exit 1; }
unsigned=false
config=Config/release.env
while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned) unsigned=true; shift ;;
    --config)
      [[ $# -ge 2 ]] || fail "--config needs a path"
      config="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || fail "Run this script on macOS with full Xcode installed."
if [[ -f "$config" ]]; then
  # shellcheck disable=SC1090
  source "$config"
elif ! $unsigned; then
  fail "Copy Config/release.env.example to $config and fill in your signing details."
fi

xcodebuild -version >/dev/null
# Release builds download the cleanup model at the pinned commit; refuse to ship without one.
/usr/bin/grep -A6 'BEGIN PINNED MODEL' HeyVedu/Pipeline/DictationModelBackend.swift \
  | /usr/bin/grep -qE 'revision: "[0-9a-f]{40}"' \
  || fail "Pin the cleanup model first: scripts/pin-cleanup-model.sh COMMIT"
xcrun --find lipo >/dev/null
xcrun metal --version >/dev/null \
  || fail "Install Xcode's Metal toolchain: xcodebuild -downloadComponent MetalToolchain"
if ! $unsigned; then
  [[ "${DEVELOPMENT_TEAM:-}" =~ ^[A-Z0-9]{10}$ && "$DEVELOPMENT_TEAM" != YOUR_TEAM_ID ]] \
    || fail "Set DEVELOPMENT_TEAM to your 10-character Apple Developer Team ID."
  [[ "${SIGNING_IDENTITY:-}" == "Developer ID Application: "* && "$SIGNING_IDENTITY" != *YOUR_* ]] \
    || fail "Set SIGNING_IDENTITY to your installed Developer ID Application certificate."
  [[ "$SIGNING_IDENTITY" == *"($DEVELOPMENT_TEAM)" ]] \
    || fail "The signing identity must belong to DEVELOPMENT_TEAM."
  [[ -n "${NOTARY_PROFILE:-}" ]] || fail "Set NOTARY_PROFILE to your notarytool Keychain profile."
  xcrun --find notarytool >/dev/null
  xcrun --find stapler >/dev/null
  # Check authentication before starting the expensive build.
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null
fi

mkdir -p build/release dist
work="$(mktemp -d "$PWD/build/release/run.XXXXXX")"
echo "Build logs and intermediate artifacts: $work"

settings=(ENABLE_HARDENED_RUNTIME=YES)
[[ -z "${MARKETING_VERSION:-}" ]] || settings+=("MARKETING_VERSION=$MARKETING_VERSION")
[[ -z "${CURRENT_PROJECT_VERSION:-}" ]] || settings+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION")
# Xcode signs embedded code during the build; the distribution signature is applied
# below in dependency order, with a secure timestamp and hardened runtime.
xcodebuild \
  -project HeyVedu.xcodeproj -scheme HeyVedu -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$work/DerivedData" \
  -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  "${settings[@]}" build 2>&1 | tee "$work/build.log"

app="$work/DerivedData/Build/Products/Release/HeyVedu.app"
[[ -d "$app" ]] || fail "Xcode did not produce $app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "Version must contain only numbers and dots."
xcrun lipo "$app/Contents/MacOS/HeyVedu" -verify_arch arm64
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"

# Sparkle installs updates only when the build number grows and the EdDSA signature
# verifies against the key the installed app was built with, so check both up front.
sparkle_bin="$PWD/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
appcast=dist/updates/appcast.xml
if ! $unsigned; then
  [[ -x "$sparkle_bin/sign_update" ]] || fail "Sparkle's tools are missing from $sparkle_bin"
  app_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
  keychain_key="$("$sparkle_bin/generate_keys" -p 2>/dev/null)" \
    || fail "No Sparkle signing key in your Keychain. Run once (and back up the key with -x):
  $sparkle_bin/generate_keys
then put the printed public key in SUPublicEDKey in Config/Info.plist and commit it."
  [[ "$app_key" == "$keychain_key" ]] \
    || fail "SUPublicEDKey in Config/Info.plist does not match the Keychain's Sparkle key ($keychain_key).
Never change the key after shipping: installed apps reject updates signed with another key."
  if [[ -f "$appcast" ]]; then
    previous="$(sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p' "$appcast" | head -1)"
    if [[ -n "$previous" ]] && \
      [[ "$(printf '%s\n%s\n' "$previous" "$build" | sort -V | tail -1)" == "$previous" ]]; then
      fail "Build number $build must be greater than the last release's ($previous); set CURRENT_PROJECT_VERSION."
    fi
  fi
fi

if $unsigned; then
  suffix=-UNSIGNED
else
  suffix=
  sign_code() {
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$1"
  }
  # Sign nested Mach-O files first, then their enclosing bundles, then the app.
  # --deep is used only for verification, never for signing.
  while IFS= read -r -d '' item; do
    if file -b "$item" | /usr/bin/grep -q 'Mach-O'; then
      xcrun lipo "$item" -verify_arch arm64
      sign_code "$item"
    fi
  done < <(find "$app/Contents" -type f -print0)
  while IFS= read -r -d '' item; do
    if [[ -f "$item/Contents/Info.plist" || "$item" == *.framework ]]; then
      sign_code "$item"
    fi
  done < <(find "$app/Contents" -depth -type d \
    \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' \) -print0)
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime \
    --entitlements Config/HeyVedu.entitlements "$app"
  # Notarization rejects debugging entitlements; catch them before uploading.
  if codesign -d --entitlements - --xml "$app" 2>/dev/null | /usr/bin/grep -q get-task-allow; then
    fail "Signed app has com.apple.security.get-task-allow, which notarization rejects."
  fi
fi
codesign --verify --deep --strict --verbose=2 "$app"

notarize() {
  local artifact="$1" label="$2" result status submission submit_exit=0
  result="$work/$label-notary.plist"
  # Persist Apple's response even if submission fails, for diagnosis or resuming.
  # On a timeout notarytool writes the plist to stderr instead of stdout.
  xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout "${NOTARY_TIMEOUT:-2h}" --output-format plist \
    > "$result" 2> "$result.stderr" || submit_exit=$?
  [[ -s "$result" ]] || cp "$result.stderr" "$result"
  # PlistBuddy prints errors to stdout, so discard its output when it fails.
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$result" 2>/dev/null)" || status=
  submission="$(/usr/libexec/PlistBuddy -c 'Print :id' "$result" 2>/dev/null)" || submission=
  if [[ "$status" != Accepted && -n "$submission" && "$submit_exit" -ne 0 ]]; then
    fail "Notarization of $label did not finish in time (submission $submission). Check it with:
  xcrun notarytool wait $submission --keychain-profile $NOTARY_PROFILE
then rerun this script once Apple has accepted it; later submissions are usually faster."
  fi
  if [[ "$status" != Accepted ]]; then
    if [[ -n "$submission" ]]; then
      xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" \
        "$work/$label-notary-log.json" || true
    fi
    fail "Notarization was not accepted (${status:-no status}, exit $submit_exit). See $result and docs/RELEASING.md."
  fi
  [[ "$submit_exit" -eq 0 ]] || fail "Notarytool failed (exit $submit_exit). See $result."
}

if ! $unsigned; then
  # Staple the app before packaging so its ticket survives copying out of the DMG.
  ditto -c -k --keepParent "$app" "$work/HeyVedu-notary.zip"
  notarize "$work/HeyVedu-notary.zip" app
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi

stage="$work/dmg"
mkdir -p "$stage"
ditto "$app" "$stage/HeyVedu.app"
ln -s /Applications "$stage/Applications"
cp LICENSE "$stage/LICENSE.txt"
cat > "$stage/Install.txt" <<'EOF'
HeyVedu — Apple silicon, macOS 26.4 or later

Drag HeyVedu.app to Applications, eject this disk, and open HeyVedu from
Applications. Look for the microphone icon in the menu bar (no Dock icon).
Grant Microphone and Accessibility access when prompted.
The first launch downloads about 2.1 GB of on-device models; allow time for
them to prepare. Hold Control + Option to dictate and release to insert text.

Source code and documentation: https://github.com/rajan9519/heyvedu
EOF

name="HeyVedu-$version-arm64$suffix.dmg"
dmg="$work/$name"
hdiutil create -volname "HeyVedu $version" -srcfolder "$stage" \
  -fs HFS+ -format UDZO "$dmg"
hdiutil verify "$dmg"
if ! $unsigned; then
  codesign --sign "$SIGNING_IDENTITY" --timestamp "$dmg"
  codesign --verify --strict --verbose=2 "$dmg"
  notarize "$dmg" dmg
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

# Publish to dist only after all checks succeed. A failed run keeps its diagnostics.
mv -f "$dmg" "dist/$name"
(cd dist && shasum -a 256 "$name" > "$name.sha256")
echo "Created: $PWD/dist/$name"

if ! $unsigned; then
  # Sparkle's appcast lists only this release; installed apps compare its build number with
  # theirs and download the DMG next to it. Upload the DMG before the appcast.
  feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist")"
  min_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
  enclosure="$("$sparkle_bin/sign_update" "dist/$name")"
  [[ "$enclosure" == *'sparkle:edSignature="'*'length="'* ]] || fail "sign_update failed: $enclosure"
  cat > "$work/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>HeyVedu</title>
    <link>$feed_url</link>
    <item>
      <title>HeyVedu $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="${feed_url%/*}/$name" type="application/x-apple-diskimage" $enclosure/>
    </item>
  </channel>
</rss>
EOF
  # Embeds the feed's EdDSA signature; the app requires it (SURequireSignedFeed).
  "$sparkle_bin/sign_update" "$work/appcast.xml" >/dev/null
  "$sparkle_bin/sign_update" --verify "$work/appcast.xml" >/dev/null
  rm -rf dist/updates
  mkdir -p dist/updates
  cp "dist/$name" "dist/updates/$name"
  mv "$work/appcast.xml" "$appcast"
  echo "Update feed: $PWD/dist/updates (upload $name first, then appcast.xml, to ${feed_url%/*}/)"
fi
if $unsigned; then
  echo "Local test build only: ad-hoc signed, not notarized, and not ready for public distribution."
else
  echo "Developer ID signed, notarized, stapled, and verified."
fi
