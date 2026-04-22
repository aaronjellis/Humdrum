#!/usr/bin/env bash
# Builds MeetingScribe in release mode and wraps the binary into a proper
# macOS .app bundle so the OS honors Info.plist (microphone permission)
# and gives it a real Dock icon.
#
# Also (optionally) bundles the default "Balanced" Whisper model inside
# the .app so the first launch doesn't require a network download.
#
# Usage: ./build-app.sh
# Output: ./MeetingScribe.app
set -euo pipefail

APP_NAME="MeetingScribe"
BUNDLE_ID="com.aaronellis.meetingscribe"
APP_DIR="${APP_NAME}.app"
ENTITLEMENTS="MeetingScribe.entitlements"

# Which Whisper variants to try to bundle into the .app, in
# folder-name form exactly as they live on Hugging Face.
BUNDLED_MODELS=(
  "openai_whisper-base.en"
)
HF_REPO="https://huggingface.co/argmaxinc/whisperkit-coreml"
BUNDLE_SRC="BundledWhisperModels"   # staging folder, kept across rebuilds

cd "$(dirname "$0")"

# --------------------------------------------------------------------------
# Fetch any missing bundled Whisper models via git-lfs. Skips silently if
# git-lfs isn't installed; the app still works — models just download on
# first use.
# --------------------------------------------------------------------------
prepare_bundled_models() {
  local need_fetch=0
  mkdir -p "${BUNDLE_SRC}"
  for m in "${BUNDLED_MODELS[@]}"; do
    if [ ! -d "${BUNDLE_SRC}/${m}" ]; then
      need_fetch=1
    fi
  done

  if [ "${need_fetch}" -eq 0 ]; then
    echo "==> Bundled models already staged in ./${BUNDLE_SRC}"
    return 0
  fi

  if ! command -v git-lfs >/dev/null 2>&1; then
    echo "==> NOTE: git-lfs not installed; skipping bundled models."
    echo "    App will still work — Whisper models download on first use."
    echo "    To bundle: brew install git-lfs && git lfs install, then rerun."
    return 0
  fi

  echo "==> Fetching Whisper models via git-lfs (one-time; ~145 MB per model)…"
  local tmp
  tmp="$(mktemp -d)"
  (
    cd "${tmp}"
    GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 "${HF_REPO}" repo >/dev/null 2>&1
    cd repo
    for m in "${BUNDLED_MODELS[@]}"; do
      echo "    • ${m}"
      git lfs pull --include "${m}/*" >/dev/null 2>&1
    done
  )
  for m in "${BUNDLED_MODELS[@]}"; do
    if [ -d "${tmp}/repo/${m}" ]; then
      rm -rf "${BUNDLE_SRC}/${m}"
      cp -R "${tmp}/repo/${m}" "${BUNDLE_SRC}/${m}"
    else
      echo "    WARNING: ${m} not found in upstream repo; skipping."
    fi
  done
  rm -rf "${tmp}"
  echo "==> Models staged at ./${BUNDLE_SRC}"
}

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------
prepare_bundled_models

echo "==> Building ${APP_NAME} (release)…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
if [ ! -x "${BIN_PATH}/${APP_NAME}" ]; then
  echo "Error: expected binary at ${BIN_PATH}/${APP_NAME}" >&2
  exit 1
fi

echo "==> Assembling ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Info.plist"              "${APP_DIR}/Contents/Info.plist"

# SPM resource bundles (WhisperKit / FluidAudio ship compile-time
# metadata through these).
shopt -s nullglob
for bundle in "${BIN_PATH}"/*.bundle; do
  cp -R "${bundle}" "${APP_DIR}/Contents/Resources/"
done
shopt -u nullglob

# Bundled Whisper models (if staged)
if [ -d "${BUNDLE_SRC}" ] && [ -n "$(ls -A "${BUNDLE_SRC}" 2>/dev/null || true)" ]; then
  echo "==> Copying bundled Whisper models into the .app…"
  mkdir -p "${APP_DIR}/Contents/Resources/WhisperModels"
  for m in "${BUNDLED_MODELS[@]}"; do
    if [ -d "${BUNDLE_SRC}/${m}" ]; then
      cp -R "${BUNDLE_SRC}/${m}" "${APP_DIR}/Contents/Resources/WhisperModels/${m}"
    fi
  done
fi

chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# --------------------------------------------------------------------------
# Codesign (ad-hoc) with entitlements.
# Deliberately NOT passing --options runtime: ad-hoc + hardened runtime
# often blocks microphone input on Macs.
# --------------------------------------------------------------------------
echo "==> Ad-hoc codesigning with entitlements…"
codesign --force --deep --sign - \
  --identifier "${BUNDLE_ID}" \
  --entitlements "${ENTITLEMENTS}" \
  "${APP_DIR}"

echo "==> Verifying signature…"
codesign -dv --entitlements :- "${APP_DIR}" 2>&1 | sed 's/^/    /'

echo
echo "Done. Launch with:"
echo "  open ./${APP_DIR}"
echo
echo "If macOS does not prompt for Microphone access on first Start,"
echo "reset its cached decision and relaunch:"
echo "  tccutil reset Microphone ${BUNDLE_ID}"
echo "  open ./${APP_DIR}"
