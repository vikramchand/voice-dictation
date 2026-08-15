#!/usr/bin/env bash
#
# Downloads a whisper.cpp GGML model into the location VoiceFlow reads by default:
#
#     ~/Library/Application Support/VoiceFlow/models/ggml-<model>.bin
#
# Usage:
#     ./scripts/download-whisper-model.sh [model]
#
# Models, smallest first. Larger is more accurate and slower:
#     tiny  base  small  medium  large-v3-turbo
#
# `small` is the default: on Apple Silicon it is accurate enough for dictation
# and still transcribes a short utterance in well under a second.

set -euo pipefail

MODEL="${1:-small}"
DEST_DIR="${HOME}/Library/Application Support/VoiceFlow/models"
DEST="${DEST_DIR}/ggml-${MODEL}.bin"
BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

VALID_MODELS=(tiny tiny.en base base.en small small.en medium medium.en large-v3 large-v3-turbo)

is_valid=false
for candidate in "${VALID_MODELS[@]}"; do
  if [[ "${candidate}" == "${MODEL}" ]]; then
    is_valid=true
    break
  fi
done

if [[ "${is_valid}" != true ]]; then
  echo "Unknown model: ${MODEL}" >&2
  echo "Choose one of: ${VALID_MODELS[*]}" >&2
  exit 1
fi

if [[ -f "${DEST}" ]]; then
  echo "Already present: ${DEST}"
  echo "Delete it first if you want to re-download."
  exit 0
fi

mkdir -p "${DEST_DIR}"

echo "Downloading ggml-${MODEL}.bin ..."
echo "  from ${BASE_URL}/ggml-${MODEL}.bin"
echo "  to   ${DEST}"
echo

# Download to a temporary name so an interrupted transfer can't leave a partial
# file that looks installed to the app.
TMP="${DEST}.partial"
trap 'rm -f "${TMP}"' EXIT

curl --fail --location --progress-bar --output "${TMP}" \
  "${BASE_URL}/ggml-${MODEL}.bin"

mv "${TMP}" "${DEST}"
trap - EXIT

echo
echo "Installed: ${DEST}"
echo "Select it in VoiceFlow under Settings -> Speech."
