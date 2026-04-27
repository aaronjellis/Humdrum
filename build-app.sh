#!/usr/bin/env bash
# Builds Humdrum as a release-ready, Developer-ID-signed, hardened-
# runtime, notarized, stapled .app — then zips it for distribution.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application: <Name> (<TEAMID>)" certificate in
#      your login keychain. Verify with:
#          security find-identity -v -p codesigning
#      The string that starts with "Developer ID Application:" is what
#      goes into SIGN_IDENTITY below. You can either hardcode it here
#      or export SIGN_IDENTITY=... before running.
#
#   2. A notarytool credential profile in your keychain. One-time setup:
#          xcrun notarytool store-credentials humdrum-notary \
#              --apple-id "you@example.com" \
#              --team-id  "YOUR_TEAM_ID" \
#              --password "xxxx-xxxx-xxxx-xxxx"   # app-specific pw
#      (The app-specific password is generated at
#       https://appleid.apple.com → Sign-In & Security → App-Specific.)
#      The profile name can be overridden with NOTARY_PROFILE=... env.
#
#   3. Xcode command-line tools (for codesign / notarytool / stapler /
#      swift). `xcode-select --install` if missing.
#
# Usage:
#     ./build-app.sh                    # full release pipeline
#     ./build-app.sh --skip-notarize    # build + sign only (fast iteration)
#
# Output:
#     Humdrum.app         — the signed, notarized, stapled bundle
#     Humdrum.zip         — ditto-zipped for distribution / upload
set -euo pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
APP_NAME="Humdrum"
BUNDLE_ID="com.aaronellis.humdrum"
APP_DIR="${APP_NAME}.app"
ZIP_PATH="${APP_NAME}.zip"
ENTITLEMENTS="Humdrum.entitlements"

# Developer ID Application identity. Override via env var if you rotate
# certs or have multiple. Leaving it auto-detected is usually fine —
# the script pulls the first "Developer ID Application:" line out of
# the codesigning keychain below.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

# notarytool profile name — see "Prerequisites" block above.
NOTARY_PROFILE="${NOTARY_PROFILE:-humdrum-notary}"

# Which Whisper variants to try to bundle into the .app, in
# folder-name form exactly as they live on Hugging Face.
BUNDLED_MODELS=(
  "openai_whisper-base.en"
)
HF_REPO="https://huggingface.co/argmaxinc/whisperkit-coreml"
BUNDLE_SRC="BundledWhisperModels"   # staging folder, kept across rebuilds

# Flag parsing
SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")"

# --------------------------------------------------------------------------
# Resolve signing identity
# --------------------------------------------------------------------------
resolve_identity() {
  if [ -n "${SIGN_IDENTITY}" ]; then
    echo "==> Using SIGN_IDENTITY from env: ${SIGN_IDENTITY}"
    return 0
  fi
  # Pick the first "Developer ID Application: ..." entry from the
  # codesigning keychain.
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
                    | awk -F\" '/Developer ID Application/ {print $2; exit}')"
  if [ -z "${SIGN_IDENTITY}" ]; then
    echo "ERROR: no 'Developer ID Application: ...' identity found in your login keychain." >&2
    echo "       Add the cert via Xcode → Settings → Accounts → Manage Certificates," >&2
    echo "       or export SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" and rerun." >&2
    exit 1
  fi
  echo "==> Using signing identity: ${SIGN_IDENTITY}"
}

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
resolve_identity
prepare_bundled_models

echo "==> Building ${APP_NAME} (release)…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
if [ ! -x "${BIN_PATH}/${APP_NAME}" ]; then
  echo "Error: expected binary at ${BIN_PATH}/${APP_NAME}" >&2
  exit 1
fi

# --------------------------------------------------------------------------
# Assemble .app
# --------------------------------------------------------------------------
echo "==> Assembling ${APP_DIR}…"
rm -rf "${APP_DIR}" "${ZIP_PATH}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Info.plist"              "${APP_DIR}/Contents/Info.plist"

# --------------------------------------------------------------------------
# Stage third-party frameworks (Sparkle, etc.) into Contents/Frameworks/
#
# `swift build` resolves XCFramework dependencies at link time but does NOT
# copy them into the .app for you — that's a step Xcode normally handles
# via a "Copy Files" build phase, and SwiftPM's CLI build has no equivalent.
# Without this, the app launches to a dyld crash:
#   Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
#
# SPM stages resolved frameworks under either `PackageFrameworks/` (modern
# toolchain layout) or directly at the bin path root (older layout); we
# accept both. rsync preserves the Versions/Current → A symlink scheme
# that macOS frameworks depend on — a plain `cp -R` would flatten them.
# --------------------------------------------------------------------------
echo "==> Staging third-party frameworks into Contents/Frameworks/…"
mkdir -p "${APP_DIR}/Contents/Frameworks"
shopt -s nullglob
staged_any=0
for fw in "${BIN_PATH}/PackageFrameworks"/*.framework "${BIN_PATH}"/*.framework; do
  [ -d "$fw" ] || continue
  rsync -a "$fw" "${APP_DIR}/Contents/Frameworks/"
  echo "    • $(basename "$fw")"
  staged_any=1
done
shopt -u nullglob
if [ "${staged_any}" -eq 0 ]; then
  echo "    (no frameworks found at ${BIN_PATH} — check that \`swift build\` resolved Sparkle)"
fi

# Add the Frameworks dir to the main binary's runtime search path. SPM's
# default linker flags only set @executable_path as an rpath, which would
# make dyld look in Contents/MacOS/ (wrong). Adding @executable_path/..
# /Frameworks matches Apple's bundle convention. `|| true` because rerunning
# the script after `swift build` reproduces the binary fresh, so the rpath
# add is always needed; but if for some reason it was already there,
# install_name_tool exits non-zero on duplicate and we don't care.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "${APP_DIR}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

# --------------------------------------------------------------------------
# Single-version policy.
#
# `CFBundleShortVersionString` is the version. There is no separate
# auto-bumped build number — `CFBundleVersion` is set to the SAME
# string at build time so macOS's About box (which prints both as
# "Version X (Y)") shows just one value, twice. Bump short version
# in Info.plist when shipping; CI sees the bump and Sparkle picks
# up the higher dotted-component compare.
#
# Big jumps are fine (0.2.0 → 0.234.0 is intentional shorthand for
# "I cut a lot of patches and don't want to baby semver"). What
# matters is monotonic dotted-decimal comparison, which Sparkle
# handles natively.
# --------------------------------------------------------------------------
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_DIR}/Contents/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${SHORT_VERSION}" "${APP_DIR}/Contents/Info.plist"
echo "==> Version stamped: v${SHORT_VERSION}"

# --------------------------------------------------------------------------
# App icon
#
# The source of truth is Resources/AppIcon.iconset/ — a folder of PNGs at
# the sizes/scales macOS expects. `iconutil -c icns` packs them into a
# multi-resolution AppIcon.icns that Finder, Dock, and the About window
# all pull from. If the .iconset doesn't exist (e.g. on a fresh clone
# before Resources/generate_appicon.py has been run), we warn loudly but
# don't abort — the app is still usable, it just gets the generic binary
# icon.
# --------------------------------------------------------------------------
ICONSET_DIR="Resources/AppIcon.iconset"
if [ -d "${ICONSET_DIR}" ]; then
  echo "==> Packing ${ICONSET_DIR} → AppIcon.icns…"
  iconutil -c icns -o "${APP_DIR}/Contents/Resources/AppIcon.icns" "${ICONSET_DIR}"
else
  echo "==> WARNING: ${ICONSET_DIR} missing; app will ship with default icon."
  echo "    Regenerate with:  python3 Resources/generate_appicon.py"
fi

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
# Codesign with Developer ID + hardened runtime.
#
# Order matters: sign nested frameworks/dylibs BEFORE the outer .app so
# outer-bundle validation sees already-signed children. `--deep` still
# helps as a safety net but is deprecated, so we walk the tree ourselves.
# --------------------------------------------------------------------------
echo "==> Codesigning (Developer ID + hardened runtime)…"

# Sign anything executable under Contents/Resources first. SwiftPM's
# *.bundle directories come in two flavors:
#
#   1. Proper bundles with an Info.plist + CFBundleExecutable — these
#      have a Mach-O payload and MUST be signed for hardened runtime.
#   2. Resource-only bundles (e.g. swift-transformers_Hub.bundle) that
#      are just data directories with no Info.plist. codesign barfs on
#      these with "bundle format unrecognized" and aborts the build.
#
# Handle both: sign any dylib/framework unconditionally, and for each
# *.bundle inspect its contents first — no Info.plist means no code,
# so we skip it. Using process substitution (`< <(find ...)`) instead
# of a pipe so the while loop runs in the current shell and set -e /
# pipefail propagate normally.
while IFS= read -r -d '' item; do
  case "$item" in
    *.dylib|*.framework)
      codesign --force --timestamp --options runtime \
        --sign "${SIGN_IDENTITY}" \
        "${item}"
      ;;
    *.bundle)
      if [ -f "${item}/Contents/Info.plist" ] || [ -f "${item}/Info.plist" ]; then
        codesign --force --timestamp --options runtime \
          --sign "${SIGN_IDENTITY}" \
          "${item}"
      else
        echo "    (skip, resource-only bundle) ${item#${APP_DIR}/}"
      fi
      ;;
  esac
done < <(find "${APP_DIR}/Contents/Resources" \
           \( -name '*.dylib' -o -name '*.framework' -o -name '*.bundle' \) \
           -print0)

# Sign everything inside Contents/Frameworks/ — Sparkle specifically ships
# five nested code-bearing artifacts (Autoupdate, Updater.app, Downloader
# .xpc, Installer.xpc, the framework itself) that MUST each carry a valid
# Developer ID signature before the outer framework signature is applied,
# and the outer framework signature must land before we sign the app
# bundle. Walk deepest-first (-depth) so children are signed before their
# parents — codesign seals a bundle's contents at sign time, so a child
# resigned after its parent invalidates the parent's seal.
#
# The case is split into:
#   • known bundle wrappers (.dylib / .framework / .xpc / .app) — sign
#     unconditionally, codesign handles the bundle vs. binary semantics.
#   • bare Mach-O executables (no extension) — Sparkle's `Autoupdate`
#     is the canonical example. Apple's notary rejects these if they
#     carry only the upstream maintainer's signature (or an ad-hoc
#     signature, which is what we shipped before — local builds used
#     `--skip-notarize` so this stayed latent until the first real
#     notary submission). We use `file` to detect Mach-O so we don't
#     try to codesign random text/resources.
while IFS= read -r -d '' item; do
  case "$item" in
    *.dylib|*.framework|*.xpc|*.app)
      codesign --force --timestamp --options runtime \
        --sign "${SIGN_IDENTITY}" \
        "${item}"
      ;;
    *)
      if [ -f "$item" ] && [ -x "$item" ] \
         && file -b "$item" 2>/dev/null | grep -qE '^Mach-O'; then
        codesign --force --timestamp --options runtime \
          --sign "${SIGN_IDENTITY}" \
          "${item}"
      fi
      ;;
  esac
done < <(find "${APP_DIR}/Contents/Frameworks" -depth -print0)

# Sign the main executable explicitly with entitlements so the
# hardened-runtime exceptions in Humdrum.entitlements are applied.
codesign --force --timestamp --options runtime \
  --entitlements "${ENTITLEMENTS}" \
  --sign "${SIGN_IDENTITY}" \
  "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Finally sign the whole .app bundle (outer signature).
codesign --force --timestamp --options runtime \
  --entitlements "${ENTITLEMENTS}" \
  --identifier "${BUNDLE_ID}" \
  --sign "${SIGN_IDENTITY}" \
  "${APP_DIR}"

echo "==> Verifying signature…"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}" 2>&1 | sed 's/^/    /'
codesign -dv --entitlements :- "${APP_DIR}" 2>&1 | sed 's/^/    /'

# --------------------------------------------------------------------------
# Bust macOS icon + LaunchServices caches.
#
# Background: macOS aggressively memoizes app icons in
# ~/Library/Caches/com.apple.iconservices.store and inside the
# LaunchServices database. When you rebuild an .app in place with a
# new AppIcon.icns, Finder + the Dock + the About window may all
# keep showing the old icon for hours/days until those caches roll
# over on their own. This is the single most common reason "my new
# icon isn't showing up."
#
# We:
#   1. `touch` the .app so mtime updates (some cache layers key off it)
#   2. Re-register with LaunchServices (-f) so LSDB picks up the new
#      CFBundleIconFile + Info.plist
#   3. Restart the Dock (cheap, ~1 s glitch) so its icon cache reloads
#
# All three are best-effort; failures are logged but don't abort the
# build because the signed bundle is still valid.
# --------------------------------------------------------------------------
echo "==> Refreshing LaunchServices + Dock icon cache…"
touch "${APP_DIR}" || true
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f -v "${APP_DIR}" >/dev/null 2>&1 || echo "    (lsregister refresh skipped)"
killall Dock 2>/dev/null || true
killall Finder 2>/dev/null || true

# --------------------------------------------------------------------------
# Zip (ditto preserves resource forks, extended attrs, symlinks — the
# only zip format notarytool accepts for an .app).
# --------------------------------------------------------------------------
echo "==> Creating ${ZIP_PATH}…"
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

# --------------------------------------------------------------------------
# Notarize + staple (optional)
# --------------------------------------------------------------------------
if [ "${SKIP_NOTARIZE}" -eq 1 ]; then
  echo
  echo "==> Skipping notarization (--skip-notarize)."
  echo "    The app is signed but Gatekeeper will warn on first launch."
  echo "    Run without --skip-notarize for a shippable build."
  exit 0
fi

echo "==> Submitting to Apple's notary service (this can take a couple of minutes)…"
if ! xcrun notarytool submit "${ZIP_PATH}" \
      --keychain-profile "${NOTARY_PROFILE}" \
      --wait; then
  echo
  echo "ERROR: notarization failed." >&2
  echo "       Pull the full log for the most recent submission with:" >&2
  echo "           xcrun notarytool history --keychain-profile ${NOTARY_PROFILE}" >&2
  echo "           xcrun notarytool log <submission-id> --keychain-profile ${NOTARY_PROFILE}" >&2
  exit 1
fi

echo "==> Stapling the notarization ticket onto ${APP_DIR}…"
xcrun stapler staple "${APP_DIR}"
xcrun stapler validate "${APP_DIR}"

# Re-zip AFTER stapling so the distributable zip contains the ticket.
# (Stapler mutates the .app, which invalidates the earlier zip.)
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

echo
echo "==> Done."
echo "    Signed + notarized + stapled bundle:  ./${APP_DIR}"
echo "    Distributable zip (Gatekeeper-clean): ./${ZIP_PATH}"
echo
echo "    Quick local smoke test — downloads, quarantines, launches:"
echo "        xattr -cr /tmp/${APP_DIR}; cp -R ${APP_DIR} /tmp/ && open /tmp/${APP_DIR}"
echo
echo "    To hand the zip to someone else: they just unzip and drag"
echo "    Humdrum.app into Applications — no right-click-open dance."
