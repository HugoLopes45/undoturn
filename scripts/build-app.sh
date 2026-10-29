#!/bin/sh
# Builds a universal app with its CLI and service. Signs ad hoc unless UNDOTURN_SIGN_IDENTITY names
# a Developer ID Application identity; then it signs with the hardened runtime and a secure timestamp.
# Notarization is done by scripts/release.sh.
set -eu
caller=$(pwd)
cd "$(dirname "$0")/.."

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [output.app]" >&2
  exit 2
fi
app="$PWD/.build/UndoTurn.app"
if [ "$#" -eq 1 ]; then
  case "$1" in
    /*) app=$1 ;;
    *) app="$caller/$1" ;;
  esac
fi
case "$app" in
  *.app) ;;
  *) echo "output must end in .app" >&2; exit 2 ;;
esac
if [ -e "$app" ] || [ -L "$app" ]; then
  echo "output already exists; choose a different app path: $app" >&2
  exit 1
fi
sdk=$(xcrun --sdk macosx --show-sdk-version)
# AppKit gives the macOS 26 design only to binaries stamped with a macOS 26 or later SDK.
if [ "${sdk%%.*}" -lt 26 ]; then
  echo "building UndoTurn.app requires the macOS 26 SDK or later; found $sdk" >&2
  exit 1
fi

identity=${UNDOTURN_SIGN_IDENTITY:--}
if [ "$identity" = - ]; then
  sign() { codesign --sign - --force --timestamp=none "$@"; }
else
  sign() { codesign --sign "$identity" --force --options runtime --timestamp "$@"; }
fi

arch="--arch arm64 --arch x86_64"
# shellcheck disable=SC2086 # $arch holds two separate options.
swift build -c release $arch --product UndoTurnApp
# shellcheck disable=SC2086
swift build -c release $arch --product undoturn
# shellcheck disable=SC2086
swift build -c release $arch --product undoturn-service
# shellcheck disable=SC2086
bin=$(swift build -c release $arch --show-bin-path)
version=$(sed -n 's/.*current = "\([^"]*\)".*/\1/p' Sources/UndoTurnCore/UndoTurnVersion.swift)

mkdir -p "$(dirname "$app")"
bundle=$(mktemp -d "$(dirname "$app")/.UndoTurn-build.XXXXXX")
trap 'echo "Incomplete build retained at: $bundle" >&2' 0
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Helpers" "$bundle/Contents/Resources"
binary="$bundle/Contents/MacOS/UndoTurn"
cp "$bin/UndoTurnApp" "$binary"
cp "$bin/undoturn" "$bin/undoturn-service" "$bundle/Contents/Helpers/"
restamped="$binary.restamped"
xcrun vtool -set-build-version macos 14.0 "$sdk" -replace -output "$restamped" "$binary"
mv "$restamped" "$binary"
sed "s/@VERSION@/${version%%-*}/" packaging/Info.plist >"$bundle/Contents/Info.plist"
cp packaging/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
sign "$bundle/Contents/Helpers/undoturn"
sign "$bundle/Contents/Helpers/undoturn-service"
sign "$bundle"
codesign --verify --strict --deep "$bundle"
if [ -e "$app" ] || [ -L "$app" ]; then
  echo "output appeared during the build; refusing to replace it: $app" >&2
  exit 1
fi
mv "$bundle" "$app"
trap - 0
echo "$app"
