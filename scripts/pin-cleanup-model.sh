#!/usr/bin/env bash
# Pin the Vedu Scribe model to a Hugging Face commit. Downloads every file at that
# commit, hashes it, and rewrites the pinned block in DictationModelBackend.swift.
#   scripts/pin-cleanup-model.sh COMMIT [REPOSITORY]
# The next app release then downloads this revision and deletes the previous one.
set -euo pipefail

cd "$(dirname "$0")/.."
REVISION="${1:?Usage: scripts/pin-cleanup-model.sh COMMIT [REPOSITORY]}"
REPO="${2:-heyvedu/vedu-scribe-0.8b}"
SWIFT=HeyVedu/Pipeline/DictationModelBackend.swift
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || { echo "Use the full 40-character commit hash, not a branch or tag" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL "https://huggingface.co/api/models/$REPO/tree/$REVISION" -o "$WORK/tree.json"
# The model card and git metadata aren't needed to load the model.
FILES=$(/usr/bin/python3 -c '
import json, sys
for entry in json.load(open(sys.argv[1])):
    if entry["type"] == "file" and entry["path"] not in ("README.md", ".gitattributes"):
        print(entry["path"])
' "$WORK/tree.json")
[[ -n "$FILES" ]] || { echo "No files found at $REPO@$REVISION" >&2; exit 1; }

ENTRIES=""
for name in $FILES; do
  echo "Downloading $name…"
  curl -fL --progress-bar "https://huggingface.co/$REPO/resolve/$REVISION/$name" -o "$WORK/file"
  size=$(stat -f %z "$WORK/file")
  sha=$(shasum -a 256 "$WORK/file" | cut -d' ' -f1)
  ENTRIES+="            .init(name: \"$name\", size: $size,
                  sha256: \"$sha\"),
"
done

BLOCK="    private nonisolated static let model = PinnedModel(
        displayName: \"Vedu Scribe\",
        folder: \"vedu-scribe\",
        repository: \"$REPO\",
        revision: \"$REVISION\",
        files: [
${ENTRIES}        ]
    )" /usr/bin/python3 - "$SWIFT" <<'EOF'
import os, re, sys
path = sys.argv[1]
source = open(path).read()
pattern = r"(// BEGIN PINNED MODEL\n).*?(\n\s*// END PINNED MODEL)"
updated, count = re.subn(pattern, lambda m: m.group(1) + os.environ["BLOCK"] + m.group(2), source, flags=re.S)
if count != 1:
    sys.exit(f"Pinned model markers not found in {path}")
open(path, "w").write(updated)
EOF

echo "Pinned $REPO@$REVISION in $SWIFT. Build, test the download, then commit."
