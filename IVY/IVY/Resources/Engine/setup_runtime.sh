#!/bin/bash
# IVY runtime installer.
#
# Creates an isolated Python environment for IVY's local MLX engine:
#   ~/Library/Application Support/IVY/Runtime/venv
# with mlx-lm (LLM), mlx-whisper (speech-to-text) and mlx-audio + misaki (Kokoro TTS).
#
# Run by the IVY setup window when the user clicks "Install runtime"; can also be run
# manually from a terminal. It never touches system Python or global packages.
# Network access: PyPI (packages) and, only if no suitable Python is found, astral.sh (uv).

set -euo pipefail

RUNTIME_DIR="${IVY_RUNTIME_DIR:-$HOME/Library/Application Support/IVY/Runtime}"
VENV="$RUNTIME_DIR/venv"
PACKAGES=("mlx-lm>=0.31" "mlx-whisper>=0.4" "mlx-audio>=0.5" "misaki[en]>=0.9" "numpy" "huggingface_hub")
SPACY_MODEL="en_core_web_sm"

step() { echo "IVY_STEP: $*"; }

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "IVY requires an Apple Silicon Mac (arm64)." >&2
  exit 2
fi

mkdir -p "$RUNTIME_DIR"
export PATH="$RUNTIME_DIR/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

find_python() {
  for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      local path
      path="$(command -v "$candidate")"
      if "$path" -c 'import sys, platform; sys.exit(0 if sys.version_info >= (3, 10) and platform.machine() == "arm64" else 1)' 2>/dev/null; then
        echo "$path"
        return 0
      fi
    fi
  done
  return 1
}

if [[ ! -x "$VENV/bin/python3" ]]; then
  step "Creating Python environment"
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 "$VENV"
  elif PYTHON="$(find_python)"; then
    echo "Using $PYTHON"
    "$PYTHON" -m venv "$VENV"
  else
    step "Installing uv (Python manager) into IVY's runtime folder"
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$RUNTIME_DIR/bin" UV_NO_MODIFY_PATH=1 sh
    "$RUNTIME_DIR/bin/uv" venv --python 3.12 "$VENV"
  fi
fi

step "Installing MLX packages"
if command -v uv >/dev/null 2>&1; then
  uv pip install --python "$VENV/bin/python3" --upgrade "${PACKAGES[@]}" pip
else
  "$VENV/bin/python3" -m pip install --upgrade pip
  "$VENV/bin/python3" -m pip install --upgrade "${PACKAGES[@]}"
fi

step "Installing English text model for Kokoro"
if ! "$VENV/bin/python3" -c "import spacy.util, sys; sys.exit(0 if spacy.util.is_package('$SPACY_MODEL') else 1)" 2>/dev/null; then
  "$VENV/bin/python3" -m spacy download "$SPACY_MODEL" || \
    "$VENV/bin/python3" -m pip install "$SPACY_MODEL@https://github.com/explosion/spacy-models/releases/download/${SPACY_MODEL}-3.8.0/${SPACY_MODEL}-3.8.0-py3-none-any.whl"
fi

step "Verifying runtime"
"$VENV/bin/python3" -c "import mlx.core, mlx_lm, mlx_whisper, mlx_audio, misaki; print('IVY runtime OK')"
