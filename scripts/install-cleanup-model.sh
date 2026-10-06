#!/usr/bin/env bash
# Test a locally trained MLX model in a Debug build before uploading it to Hugging Face.
# Symlinks it (no copy) into Application Support; Debug builds load it instead of the
# pinned download. Remove the link to go back: rm "$HOME/Library/Application Support/HeyVedu/Models/vedu-scribe-dev"
#   scripts/install-cleanup-model.sh [model-folder]
set -euo pipefail

MODEL="${1:-$HOME/dev/local-dictation-cleanup-training/models/qwen35_08b_dictation_r3s6400_attn8}"
MODEL="$(cd "$MODEL" && pwd)"
for file in config.json tokenizer.json tokenizer_config.json chat_template.jinja model.safetensors; do
  [[ -f "$MODEL/$file" ]] || { echo "Missing $MODEL/$file" >&2; exit 1; }
done

DEST="$HOME/Library/Application Support/HeyVedu/Models/vedu-scribe-dev"
mkdir -p "$(dirname "$DEST")"
[[ -L "$DEST" || ! -e "$DEST" ]] || { echo "$DEST exists and is not a symlink; remove it first" >&2; exit 1; }
ln -sfn "$MODEL" "$DEST"
echo "Linked $DEST -> $MODEL"
echo "Restart a Debug build of HeyVedu (if running) and pick \"Vedu Scribe\" under On-Device Cleanup."
