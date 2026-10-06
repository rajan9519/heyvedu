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

# Building, staging and mounting the DMG each register another copy of the app with Launch
# Services. Duplicates of one bundle ID can hide the installed app from the Apps view, so
# unregister this run's copies on exit, whether or not the run succeeded.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
volume=
unregister_build_copies() {
  "$lsregister" -dump 2>/dev/null \
    | awk '/^path:/ {p = $0} /^identifier:/ && $2 == "com.heyvedu.app" {print p}' \
    | sed -E 's/^path: +//; s/ \(0x[0-9a-f]+\)$//' | sort -u \
    | while IFS= read -r path; do
        if [[ "$path" == "$work/"* || ( -n "$volume" && "$path" == "/Volumes/$volume/"* ) ]]; then
          "$lsregister" -u "$path" 2>/dev/null || true
        fi
      done
}
trap unregister_build_copies EXIT

# Versions are YY.MM.DDNN: the release date plus that day's build count (NN), in the three
# parts Apple allows, used as both the display version and Sparkle's build number. Because
# DDNN compares as one number, later days and later builds of a day always sort higher. NN continues from the latest release in the
# published appcast or in dist/updates (built but not yet uploaded), and restarts at 01 each day.
appcast=dist/updates/appcast.xml
feed_version() { sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p' | head -1; }
# Compares dotted versions numerically, part by part, as Sparkle does. Leading zeros are ignored.
version_gt() {
  local IFS=. i a b
  read -ra a <<< "$1"
  read -ra b <<< "$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    (( 10#${a[i]:-0} > 10#${b[i]:-0} )) && return 0
    (( 10#${a[i]:-0} < 10#${b[i]:-0} )) && return 1
  done
  return 1
}
feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Config/Info.plist)"
http_status="$(curl -sSL --max-time 30 -o "$work/remote-appcast.xml" -w '%{http_code}' "$feed_url")" \
  || http_status=000
case "$http_status" in
  200) previous="$(feed_version < "$work/remote-appcast.xml")" ;;
  404) previous= ;;
  *)
    $unsigned || fail "Could not fetch $feed_url (HTTP $http_status) to choose the next version."
    echo "Warning: could not fetch $feed_url (HTTP $http_status); numbering this test build from 01." >&2
    previous= ;;
esac
if [[ -f "$appcast" ]]; then
  local_previous="$(feed_version < "$appcast")"
  if [[ -n "$local_previous" ]] && { [[ -z "$previous" ]] || version_gt "$local_previous" "$previous"; }; then
    previous="$local_previous"
  fi
fi
today="$(date '+%y.%m.%d')"
nn=01
if [[ "$previous" =~ ^([0-9]{2}\.[0-9]{2})\.([0-9]{2})([0-9]{2})$ ]]; then
  previous_date="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  version_gt "$previous_date" "$today" \
    && fail "The last release ($previous) is dated after today ($today); check the system clock."
  if [[ "$previous_date" == "$today" ]]; then
    (( 10#${BASH_REMATCH[3]} < 99 )) || fail "Already released 99 builds today ($previous)."
    nn="$(printf '%02d' $(( 10#${BASH_REMATCH[3]} + 1 )))"
  fi
fi
version="${today%.*}.${today##*.}$nn"
build="$version"
echo "Version: $version (previous release: ${previous:-none})"

settings=(ENABLE_HARDENED_RUNTIME=YES MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build")
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
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" &&
   "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == "$build" ]] \
  || fail "The built app's Info.plist does not carry version $version."
xcrun lipo "$app/Contents/MacOS/HeyVedu" -verify_arch arm64

# Sparkle installs updates only when the build number grows and the EdDSA signature
# verifies against the key the installed app was built with, so check both up front.
sparkle_bin="$PWD/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
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
  [[ -z "$previous" ]] || version_gt "$build" "$previous" \
    || fail "Build number $build must be greater than the last release's ($previous)."
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

# Finder window layout: a background with a drag arrow, the app on the left and
# Applications on the right. Positions match make-dmg-background.swift.
mkdir -p "$stage/.background"
swift scripts/make-dmg-background.swift "$work/background.png" 1
swift scripts/make-dmg-background.swift "$work/background@2x.png" 2
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" \
  -out "$stage/.background/background.tiff"

name="HeyVedu-$version-arm64$suffix.dmg"
dmg="$work/$name"
volume="HeyVedu $version"
[[ ! -e "/Volumes/$volume" ]] || fail "Eject the mounted \"$volume\" disk image and rerun."
# Build writable first so Finder can save the layout (.DS_Store), then compress.
rw="$work/layout.dmg"
hdiutil create -volname "$volume" -srcfolder "$stage" -fs HFS+ -format UDRW \
  -size "$(( $(du -sm "$stage" | cut -f1) + 20 ))m" "$rw"
device="$(hdiutil attach "$rw" -readwrite -noverify -noautoopen | awk '/Apple_HFS/ {print $1}')"
[[ -n "$device" ]] || fail "Could not mount the writable disk image."
if ! osascript <<EOF
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 640 x 400 content area plus the title bar.
    set bounds of container window to {200, 120, 840, 548}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "HeyVedu.app" to {160, 200}
    set position of item "Applications" to {480, 200}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF
then
  hdiutil detach "$device" -quiet || true
  fail "Finder could not lay out the disk image. Allow your terminal to control Finder in
System Settings > Privacy & Security > Automation, then rerun."
fi
for _ in {1..20}; do [[ -f "/Volumes/$volume/.DS_Store" ]] && break; sleep 0.5; done
[[ -f "/Volumes/$volume/.DS_Store" ]] || fail "Finder did not save the disk image layout."
rm -rf "/Volumes/$volume/.fseventsd"
sync
hdiutil detach "$device" -quiet
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg"
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
