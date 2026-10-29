#!/bin/sh
# Builds, signs, notarizes and staples the release artifacts into .build/release/<version>.
# Publishes nothing. Requires a clean work tree and:
#   UNDOTURN_SIGN_IDENTITY  a "Developer ID Application: …" identity in the keychain
#   UNDOTURN_NOTARY_PROFILE a profile saved with `xcrun notarytool store-credentials`
set -eu
cd "$(dirname "$0")/.."

: "${UNDOTURN_SIGN_IDENTITY:?set UNDOTURN_SIGN_IDENTITY to a Developer ID Application identity}"
: "${UNDOTURN_NOTARY_PROFILE:?set UNDOTURN_NOTARY_PROFILE to a notarytool keychain profile}"
case "$UNDOTURN_SIGN_IDENTITY" in
  "Developer ID Application:"* | [0-9A-F][0-9A-F][0-9A-F][0-9A-F]*) ;;
  *) echo "UNDOTURN_SIGN_IDENTITY must be a Developer ID Application identity or its SHA-1" >&2; exit 2 ;;
esac
if ! security find-identity -v -p codesigning | grep -Fq "$UNDOTURN_SIGN_IDENTITY"; then
  echo "no valid code signing identity matches: $UNDOTURN_SIGN_IDENTITY" >&2
  exit 1
fi
version=$(sed -n 's/.*current = "\([^"]*\)".*/\1/p' Sources/UndoTurnCore/UndoTurnVersion.swift)
case "$version" in
  *-dev*) echo "refusing to release development version $version" >&2; exit 1 ;;
esac
if [ -n "$(git status --porcelain)" ]; then
  echo "work tree has uncommitted changes; release from a clean commit" >&2
  exit 1
fi
dist="$PWD/.build/release/$version"
if [ -e "$dist" ]; then
  echo "release output already exists: $dist" >&2
  exit 1
fi
mkdir -p "$dist"
work=$(mktemp -d "$PWD/.build/UndoTurn-release.XXXXXX")

notarize() {
  result=$(xcrun notarytool submit "$1" --keychain-profile "$UNDOTURN_NOTARY_PROFILE" --wait \
    --output-format json)
  printf '%s\n' "$result"
  status=$(printf '%s' "$result" | plutil -extract status raw -o - -)
  if [ "$status" != Accepted ]; then
    id=$(printf '%s' "$result" | plutil -extract id raw -o - -)
    echo "notarization of $1 ended with status $status." >&2
    echo "Details: xcrun notarytool log $id --keychain-profile $UNDOTURN_NOTARY_PROFILE" >&2
    exit 1
  fi
}

app="$dist/UndoTurn.app"
sh scripts/build-app.sh "$app"
ditto -c -k --keepParent "$app" "$work/UndoTurn.zip"
notarize "$work/UndoTurn.zip"
xcrun stapler staple "$app"
spctl --assess --type execute -vv "$app"

dmg="$dist/UndoTurn-$version.dmg"
mkdir "$work/dmg"
ditto "$app" "$work/dmg/UndoTurn.app"
ln -s /Applications "$work/dmg/Applications"
hdiutil create -volname UndoTurn -srcfolder "$work/dmg" -format UDZO "$dmg"
codesign --sign "$UNDOTURN_SIGN_IDENTITY" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature -vv "$dmg"

# Command-line binaries cannot carry a stapled ticket; Gatekeeper checks their ticket online.
sh scripts/build-release.sh
cli="undoturn-$version-macos-universal"
ditto -c -k --keepParent ".build/dist/$cli" "$work/cli.zip"
notarize "$work/cli.zip"
cp ".build/dist/$cli.tar.gz" "$dist/"

(cd "$dist" && shasum -a 256 "UndoTurn-$version.dmg" "$cli.tar.gz" >SHA256SUMS)
cat "$dist/SHA256SUMS"
echo "Release artifacts: $dist"
echo "Intermediate files: $work"
