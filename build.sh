#!/usr/bin/env bash
#
#  build.sh — builds VanityMetal.app
#
#  Usage:
#      ./build.sh              build the app bundle
#      ./build.sh --test       run the verification suite first, then build
#      ./build.sh --xctest     run the XCTest suite too (needs full Xcode)
#      ./build.sh --run        build, then launch it
#      ./build.sh --clean      remove build products and start fresh
#
#  Requirements: macOS 12 or newer and the Xcode Command Line Tools.
#  Nothing else — no Homebrew, no CUDA, no Python, no packages to install.
#
set -euo pipefail
cd "$(dirname "$0")"

APP="VanityMetal.app"
BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'
YELLOW=$'\033[33m'; RED=$'\033[31m'; OFF=$'\033[0m'

say()  { printf "%s==>%s %s\n" "$CYAN$BOLD" "$OFF$BOLD" "$1$OFF"; }
warn() { printf "%s!! %s%s\n" "$YELLOW" "$1" "$OFF"; }
die()  { printf "%sxx %s%s\n" "$RED" "$1" "$OFF" >&2; exit 1; }

RUN_TESTS=0; RUN_XCTEST=0; LAUNCH=0
for arg in "$@"; do
  case "$arg" in
    --test)  RUN_TESTS=1 ;;
    --xctest) RUN_XCTEST=1 ;;
    --run)   LAUNCH=1 ;;
    --clean) say "Cleaning"; rm -rf .build "$APP"; exit 0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done

# ---------------------------------------------------------------- preflight
say "Checking the toolchain"

[ "$(uname -s)" = "Darwin" ] || die "VanityMetal builds on macOS only."

if ! command -v swift >/dev/null 2>&1; then
  die "Swift not found. Install the Xcode Command Line Tools with:
       xcode-select --install"
fi

SWIFT_VER=$(swift --version 2>&1 | head -1)
printf "    %s%s%s\n" "$DIM" "$SWIFT_VER" "$OFF"

MACOS_VER=$(sw_vers -productVersion)
MACOS_MAJOR=${MACOS_VER%%.*}
printf "    %smacOS %s%s\n" "$DIM" "$MACOS_VER" "$OFF"
[ "$MACOS_MAJOR" -ge 12 ] || die "macOS 12 (Monterey) or newer is required; this is $MACOS_VER."

ARCH=$(uname -m)
case "$ARCH" in
  arm64) printf "    %sApple silicon — unified memory GPU path%s\n" "$DIM" "$OFF" ;;
  x86_64) printf "    %sIntel Mac — the Metal path works on T2/Iris/Radeon GPUs too%s\n" "$DIM" "$OFF" ;;
esac

# ------------------------------------------------------------------- tests
if [ "$RUN_TESTS" = "1" ]; then
  say "Running the verification suite"
  # Deliberately not `swift test`: XCTest ships with full Xcode, not with the
  # Command Line Tools, and requiring a 10 GB download to check a 7000-line
  # project would be silly. VanityMetalVerify covers the same ground and also
  # cross-checks the Metal kernel against the CPU engine on real key ranges.
  # Tee to a log so the whole run survives terminal scrollback truncation.
  swift run -c release VanityMetalVerify 2>&1 | tee verify-log.txt
  status=${PIPESTATUS[0]}
  printf "%s    full log: verify-log.txt%s\n" "$DIM" "$OFF"
  [ "$status" = "0" ] || exit "$status"
fi

if [ "$RUN_XCTEST" = "1" ]; then
  say "Running the XCTest suite"
  if ! swift test -c debug; then
    warn "swift test needs full Xcode for XCTest. If you only have the Command"
    warn "Line Tools, use ./build.sh --test instead — same coverage, no XCTest."
    exit 1
  fi
fi

# ------------------------------------------------------------------- build
say "Compiling (release)"
swift build -c release --product VanityMetal

BIN_DIR=$(swift build -c release --show-bin-path)
BIN="$BIN_DIR/VanityMetal"
[ -x "$BIN" ] || die "the compiler produced no binary at $BIN"

# ------------------------------------------------------------------ bundle
say "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/VanityMetal"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -d Resources/VanityMetal.iconset ]; then
  if command -v iconutil >/dev/null 2>&1; then
    iconutil -c icns -o "$APP/Contents/Resources/VanityMetal.icns" Resources/VanityMetal.iconset
  else
    warn "iconutil not found — the app will build without its icon."
  fi
fi

# The Metal kernels are compiled at launch from source embedded in the binary,
# so there is nothing else to copy in. That is what makes the bundle portable.

# ------------------------------------------------------------------- sign
say "Signing (ad-hoc)"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    && printf "    %sad-hoc signature applied%s\n" "$DIM" "$OFF" \
    || warn "ad-hoc signing failed; the app still runs, macOS may just ask once."
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

SIZE=$(du -sh "$APP" | cut -f1)
printf "\n%s✓ Built %s (%s)%s\n" "$GREEN$BOLD" "$APP" "$SIZE" "$OFF"
printf "%s  Move it to /Applications, or double-click it where it is.%s\n\n" "$DIM" "$OFF"

if [ "$LAUNCH" = "1" ]; then
  say "Launching"
  open "$APP"
fi
