#!/usr/bin/env bash
#
# Verifies everything VoiceFlow needs is installed and reachable.
# Run this before filing a bug — it checks the same things the app does at launch.

set -uo pipefail

ok=0
fail=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; ok=$((ok + 1)); }
warn() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
info() { printf '    %s\n' "$1"; }

echo
echo "VoiceFlow setup check"
echo "====================="
echo

# --- Platform -----------------------------------------------------------------
echo "Platform"
if [[ "$(uname -s)" == "Darwin" ]]; then
  pass "macOS $(sw_vers -productVersion)"
else
  warn "Not macOS — VoiceFlow is a native macOS app."
fi

if [[ "$(uname -m)" == "arm64" ]]; then
  pass "Apple Silicon (Metal acceleration available)"
else
  info "Intel Mac: transcription runs on CPU and will be slower."
fi

if xcodebuild -version >/dev/null 2>&1; then
  pass "$(xcodebuild -version | head -1)"
else
  warn "Xcode command line tools not found (needed only to build)."
fi
echo

# --- whisper.cpp --------------------------------------------------------------
echo "whisper.cpp"
WHISPER_BIN=""
for dir in /opt/homebrew/bin /usr/local/bin /opt/local/bin; do
  for name in whisper-cli whisper-cpp whisper main; do
    if [[ -x "${dir}/${name}" ]]; then
      WHISPER_BIN="${dir}/${name}"
      break 2
    fi
  done
done

if [[ -n "${WHISPER_BIN}" ]]; then
  pass "Binary: ${WHISPER_BIN}"
else
  warn "No whisper.cpp binary found."
  info "Install it with:  brew install whisper-cpp"
fi

MODEL_DIR="${HOME}/Library/Application Support/VoiceFlow/models"
if compgen -G "${MODEL_DIR}/ggml-*.bin" >/dev/null 2>&1; then
  for model in "${MODEL_DIR}"/ggml-*.bin; do
    pass "Model: $(basename "${model}") ($(du -h "${model}" | cut -f1))"
  done
else
  warn "No Whisper model installed in ${MODEL_DIR}"
  info "Install one with:  ./scripts/download-whisper-model.sh small"
fi
echo

# --- Ollama -------------------------------------------------------------------
echo "Ollama"
ENDPOINT="${VOICEFLOW_OLLAMA_ENDPOINT:-http://localhost:11434}"

if curl --silent --fail --max-time 3 "${ENDPOINT}/api/tags" >/dev/null 2>&1; then
  pass "Server reachable at ${ENDPOINT}"

  TAGS="$(curl --silent --max-time 3 "${ENDPOINT}/api/tags")"
  if grep -q '"qwen3:8b"' <<<"${TAGS}"; then
    pass "Model qwen3:8b is installed"
  else
    warn "Model qwen3:8b is not installed."
    info "Install it with:  ollama pull qwen3:8b"
    info "Installed models:"
    # Extract the "name" values without requiring jq.
    sed -n 's/.*"name":"\([^"]*\)".*/      \1/p' <<<"${TAGS}" | sort -u | head -20
  fi
else
  warn "No Ollama server at ${ENDPOINT}"
  if command -v ollama >/dev/null 2>&1; then
    info "Ollama is installed but not running. Start it with:  ollama serve"
  else
    info "Install it with:  brew install ollama"
  fi
fi
echo

# --- Summary ------------------------------------------------------------------
echo "====================="
if [[ ${fail} -eq 0 ]]; then
  echo "All ${ok} checks passed. You're ready to dictate."
  exit 0
else
  echo "${ok} passed, ${fail} need attention (see above)."
  exit 1
fi
