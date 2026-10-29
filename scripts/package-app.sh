#!/bin/sh
# Builds a local drag-to-Applications disk image, without notarizing or publishing it.
# Release artifacts come from scripts/release.sh.
set -eu
caller=$(pwd)
cd "$(dirname "$0")/.."

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [output.dmg]" >&2
  exit 2
fi
version=$(sed -n 's/.*current = "\([^"]*\)".*/\1/p' Sources/UndoTurnCore/UndoTurnVersion.swift)
output="$PWD/.build/dist/UndoTurn-$version.dmg"
if [ "$#" -eq 1 ]; then
  case "$1" in
    /*) output=$1 ;;
    *) output="$caller/$1" ;;
  esac
fi
case "$output" in
  *.dmg) ;;
  *) echo "output must end in .dmg" >&2; exit 2 ;;
esac
if [ -e "$output" ] || [ -L "$output" ] || [ -e "$output.sha256" ] || [ -L "$output.sha256" ]; then
  echo "output already exists; choose a different disk image path: $output" >&2
  exit 1
fi
mkdir -p .build "$(dirname "$output")"
stage=$(mktemp -d "$PWD/.build/UndoTurn-package.XXXXXX")
sh scripts/build-app.sh "$stage/UndoTurn.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname UndoTurn -srcfolder "$stage" -format UDZO "$output"
(cd "$(dirname "$output")" && shasum -a 256 "$(basename "$output")" >"$(basename "$output").sha256")
printf '%s\n' "$output" "Local app: $stage/UndoTurn.app" "Local build only: not notarized."
