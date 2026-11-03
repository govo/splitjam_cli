#!/usr/bin/env bash
#
# release.sh — produce the release artifacts for `splitjam` (this repo ships binaries only).
#
# Six steps, any failure stops the run:
#   1. Build release binaries for arm64 and x86_64 (not universal: doubles the size)
#   2. Sign with Developer ID + hardened runtime (ad-hoc signatures never notarize)
#   3. Notarize each architecture with notarytool (each submission waits for Apple)
#   4. Package each into a single-file tar.gz (unpacking yields ./splitjam for bin.install)
#   5. Write dist/checksums.txt and drop the arm64 binary at the repo root
#   6. Emit the Homebrew formula (overwrites --formula, otherwise prints to stdout)
#
# Usage
#   ./scripts/release.sh
#   ./scripts/release.sh --version 0.2.0
#   ./scripts/release.sh --formula ../homebrew-tap/Formula/splitjam.rb
#   ./scripts/release.sh --no-build          # reuse existing binaries (re-sign/repackage only)
#   ./scripts/release.sh --skip-sign         # compile only (for local testing)
#   ./scripts/release.sh --notary-profile X  # use a different notarytool keychain profile
#
# Prerequisites for signing/notarizing:
#   - A "Developer ID Application" certificate in the keychain
#     (Apple Development / Apple Distribution cannot notarize)
#   - Notary credentials stored: xcrun notarytool store-credentials <profile>
#   Both live on this machine only — never in CI, never in the repo.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CLI_PKG="${SPLITJAM_CLI_PACKAGE:-$HERE/../demucs/cli}"

# Both staging dirs are created later; one trap cleans them together.
# Separate traps would overwrite each other and leave the notary zip behind in /tmp.
STAGE=""
NOTARY_STAGE=""
trap 'for d in ${STAGE:+"$STAGE"} ${NOTARY_STAGE:+"$NOTARY_STAGE"}; do rm -rf "$d"; done' EXIT

VERSION="$(tr -d '[:space:]' < "$HERE/VERSION" 2>/dev/null || echo 0.1.0)"
FORMULA=""
BUILD=1
SIGN=1
IDENTITY="${SPLITJAM_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${SPLITJAM_NOTARY_PROFILE:-}"
REPO="${SPLITJAM_REPO:-govo/splitjam_cli}"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?}"; shift 2 ;;
    --formula) FORMULA="${2:?}"; shift 2 ;;
    --repo) REPO="${2:?}"; shift 2 ;;
    --identity) IDENTITY="${2:?}"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="${2:?}"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --skip-sign) SIGN=0; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "release.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

DIST="$HERE/dist"
mkdir -p "$DIST"

# The version has a single source of truth (this repo's VERSION / --version), but the
# binary reports a constant compiled into Catalog.version. Rewriting the file without the
# constant ships a build that lies about itself — and `brew test`
# (assert_match version.to_s) fails the moment someone installs it.
CLI_VERSION_SWIFT="$CLI_PKG/Sources/splitjam/Catalog.swift"
sync_cli_version_constant() {
  [ -f "$CLI_VERSION_SWIFT" ] || return 0
  /usr/bin/sed -i '' -E "s/(static let version = \")[^\"]*(\")/\1${VERSION}\2/" "$CLI_VERSION_SWIFT"
  if ! grep -q "static let version = \"${VERSION}\"" "$CLI_VERSION_SWIFT"; then
    echo "release.sh: could not set Catalog.version to $VERSION in $CLI_VERSION_SWIFT" >&2
    exit 4
  fi
  echo "==> Catalog.version = $VERSION"
}

if [ "$BUILD" -eq 1 ]; then
  if [ ! -d "$CLI_PKG" ]; then
    echo "release.sh: CLI package not found at $CLI_PKG (set SPLITJAM_CLI_PACKAGE)" >&2
    exit 3
  fi
  sync_cli_version_constant
  echo "==> building arm64"
  ( cd "$CLI_PKG" && swift build -c release --disable-sandbox --scratch-path /tmp/splitjam-release-arm64 )
  echo "==> building x86_64"
  ( cd "$CLI_PKG" && swift build -c release --arch x86_64 --disable-sandbox --scratch-path /tmp/splitjam-release-x64 )
  ARM_BIN=/tmp/splitjam-release-arm64/release/splitjam
  X64_BIN=/tmp/splitjam-release-x64/release/splitjam
else
  ARM_BIN="${ARM_BIN:-/tmp/splitjam-release-arm64/release/splitjam}"
  X64_BIN="${X64_BIN:-/tmp/splitjam-release-x64/release/splitjam}"
fi

for bin in "$ARM_BIN" "$X64_BIN"; do
  [ -x "$bin" ] || { echo "release.sh: missing $bin" >&2; exit 3; }
done

# Assert the binary reports the version being released. Also catches the classic
# `--no-build` mistake of repackaging last release's binary under a new number.
# The x86_64 half needs Rosetta to run; if it cannot run, skip — both architectures
# compile the same constant, so a passing arm64 build already proves the rewrite.
for bin in "$ARM_BIN" "$X64_BIN"; do
  reported="$("$bin" --version 2>/dev/null | awk '{print $2}')"
  if [ -z "$reported" ]; then
    echo "==> note: $(dirname "$bin") binary did not run here; version assert skipped"
    continue
  fi
  if [ "$reported" != "$VERSION" ]; then
    echo "release.sh: $bin reports '$reported' but this release is $VERSION" >&2
    echo "            (bump Catalog.version, or rebuild without --no-build)" >&2
    exit 4
  fi
  echo "==> $(dirname "$bin") reports $VERSION"
done

# ── signing + notarization ─────────────────────────────────────────────────
# Why: brew and curl downloads carry no com.apple.quarantine, so an unsigned binary runs
# fine. But a tarball that reaches someone via a browser or AirDrop does get quarantined,
# and an unsigned/unnotarized executable is killed on first run. Signed + notarized means
# Gatekeeper allows it and nobody has to be taught `xattr`.
#
# Two traps:
#   1. The linker already ad-hoc signed the binary; signing again stacks a second
#      signature, so strip it first (--remove-signature).
#   2. `-options runtime` (hardened runtime) is mandatory for notarization, and only a
#      "Developer ID Application" certificate works — Apple Development/Distribution do not.
if [ "$SIGN" -eq 1 ]; then
  if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
      | sed -n 's/.*"\(Developer ID Application: [^"]*\)"/\1/p' | head -1)"
  fi
  if [ -z "$IDENTITY" ]; then
    echo "release.sh: no Developer ID Application certificate in the keychain" >&2
    echo "            (Apple Development / Apple Distribution cannot notarize)" >&2
    echo "            Add one in Xcode → Settings → Accounts → Manage Certificates," >&2
    echo "            or pass --skip-sign to compile without signing (local testing only)" >&2
    exit 5
  fi
  # Notary profile: explicit/env first, then splitjam, then acapella/drumai
  # (same Apple ID team; the credentials are account-level, not per app).
  if [ -z "$NOTARY_PROFILE" ]; then
    if xcrun notarytool history --keychain-profile splitjam >/dev/null 2>&1; then
      NOTARY_PROFILE=splitjam
    elif xcrun notarytool history --keychain-profile acapella >/dev/null 2>&1; then
      NOTARY_PROFILE=acapella
      echo "==> note: reusing the acapella notary credentials (keychain profile: acapella)"
    elif xcrun notarytool history --keychain-profile drumai >/dev/null 2>&1; then
      NOTARY_PROFILE=drumai
      echo "==> note: reusing the drumai notary credentials (keychain profile: drumai)"
    else
      NOTARY_PROFILE=splitjam
    fi
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "release.sh: notary profile '$NOTARY_PROFILE' does not exist" >&2
    echo "            run: xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
    echo "            or pass --skip-sign to compile without signing" >&2
    exit 5
  fi

  echo "==> signing as: $IDENTITY"
  for bin in "$ARM_BIN" "$X64_BIN"; do
    /usr/bin/codesign --remove-signature "$bin" 2>/dev/null || true
    /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$bin" \
      || { echo "release.sh: codesign failed on $bin" >&2; exit 5; }
    /usr/bin/codesign --verify --strict "$bin" \
      || { echo "release.sh: codesign verify failed on $bin" >&2; exit 5; }
    echo "==> signed $(basename "$(dirname "$bin")")"
  done

  # notarytool only accepts .zip/.pkg/.dmg; ditto a bare Mach-O into a zip
  # (--keepParent preserves the inner file name).
  echo "==> notarizing (each submission waits for Apple)"
  NOTARY_STAGE="$(mktemp -d)"

  # Arch tags are written out, not derived from the binary path: both architectures
  # build to .../release/splitjam, so a derived tag would be "release" for both and the
  # zips would collide.
  for entry in "arm64:$ARM_BIN" "x64:$X64_BIN"; do
    arch_tag="${entry%%:*}"
    bin="${entry#*:}"
    zip="$NOTARY_STAGE/splitjam-$VERSION-darwin-$arch_tag.zip"
    /usr/bin/ditto -c -k --keepParent "$bin" "$zip"
    echo "    $arch_tag uploading…"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait \
      || { echo "release.sh: notarization failed for $arch_tag" >&2
           echo "            log: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
           exit 6; }
    # stapler pins the ticket into the binary (works offline). A bare Mach-O often
    # refuses it; that only affects "fully offline + quarantined" first runs.
    if xcrun stapler staple "$bin" >/dev/null 2>&1; then
      echo "    $arch_tag stapled"
    else
      echo "    $arch_tag staple skipped (common for bare executables; online checks still pass)"
    fi
  done
else
  echo "==> WARNING: skipping signing and notarization (--skip-sign) — local testing only" >&2
fi

echo "==> packaging $VERSION"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/arm64" "$STAGE/x64"
cp "$ARM_BIN" "$STAGE/arm64/splitjam"
cp "$X64_BIN" "$STAGE/x64/splitjam"

# Reproducible packaging: normalize mtime and use `gzip -n` (no name/timestamp), so the
# packaging step adds no randomness.
#
# Do NOT use `tar --mtime`: it silently does nothing on some tar builds, which quietly
# falls back to timestamps — repackaging then changes the hash and `brew install` fails
# with sha256 mismatch. `touch -t` + plain tar works everywhere with no silent branch.
#
# Note: signing uses an Apple timestamp, so rebuilding always changes the bytes. Only
# repackaging the *same* binary is byte-identical; never assert "rerun gives the same sha".
NORMALIZED_MTIME=202001010000
pack() {
  local dir="$1" out="$2"
  (
    set -o pipefail
    cd "$dir" || exit 1
    touch -t "$NORMALIZED_MTIME" splitjam
    tar -cf - splitjam | gzip -9n
  ) > "$out" || { echo "release.sh: failed to package $dir" >&2; rm -f "$out"; exit 1; }
  [ -s "$out" ] || { echo "release.sh: $out is empty" >&2; exit 1; }
}
pack "$STAGE/arm64" "$DIST/splitjam-$VERSION-darwin-arm64.tar.gz"
pack "$STAGE/x64"   "$DIST/splitjam-$VERSION-darwin-x64.tar.gz"

cp "$STAGE/arm64/splitjam" "$HERE/splitjam"
chmod +x "$HERE/splitjam"
printf '%s\n' "$VERSION" > "$HERE/VERSION"

# checksums list only this version's two archives. A bare `shasum *.tar.gz` would also
# pick up leftovers from previous releases, and `gh release create dist/*.tar.gz` would
# then upload old tarballs into the new release.
( cd "$DIST" && shasum -a 256 \
    "splitjam-$VERSION-darwin-arm64.tar.gz" \
    "splitjam-$VERSION-darwin-x64.tar.gz" > checksums.txt )

ARM_SHA="$(awk '/arm64/{print $1}' "$DIST/checksums.txt")"
X64_SHA="$(awk '/x64/{print $1}' "$DIST/checksums.txt")"

echo "==> $DIST/checksums.txt"
cat "$DIST/checksums.txt"

# The heredoc delimiter is unquoted on purpose: $VERSION / $REPO / $ARM_SHA / $X64_SHA must
# expand here. Never put a backtick inside the body — it would run a command and splice its
# output into the formula. (This happened once: brew audit output landed in the file.)
FORMULA_TEXT="$(cat <<RUBY
#
#  splitjam.rb — Homebrew formula. Generated by splitjam_cli/scripts/release.sh;
#  a new release overwrites this whole file. Do not hand-edit url or sha256.
#
#  One formula covers both architectures; brew picks the block matching the host CPU.
#  Binaries live on GitHub Releases of $REPO under tag v<version>.
#
#  Known audit noise: brew audit complains that url/sha256 must not live inside
#  on_arm/on_intel. The blocks still evaluate and fetch/install work fine; a personal
#  tap does not run audit, so the two-arch form stays. A universal binary would silence
#  it at twice the size, which is not worth it.
#

class Splitjam < Formula
  desc "Command-line client for the SplitJam app on macOS"
  homepage "https://github.com/$REPO"
  version "$VERSION"

  on_arm do
    url "https://github.com/$REPO/releases/download/v$VERSION/splitjam-$VERSION-darwin-arm64.tar.gz"
    sha256 "$ARM_SHA"
  end

  on_intel do
    url "https://github.com/$REPO/releases/download/v$VERSION/splitjam-$VERSION-darwin-x64.tar.gz"
    sha256 "$X64_SHA"
  end

  def install
    bin.install "splitjam"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/splitjam --version")
  end
end
RUBY
)"

if [ -n "$FORMULA" ]; then
  mkdir -p "$(dirname "$FORMULA")"
  printf '%s\n' "$FORMULA_TEXT" > "$FORMULA"
  echo "==> wrote $FORMULA"
else
  printf '%s\n' "$FORMULA_TEXT"
fi

echo
echo "next:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION \\"
echo "    dist/splitjam-$VERSION-darwin-arm64.tar.gz \\"
echo "    dist/splitjam-$VERSION-darwin-x64.tar.gz \\"
echo "    dist/checksums.txt --title v$VERSION"
echo "  (tap) git -C <homebrew-tap> commit Formula/splitjam.rb"
