#!/bin/sh
# Builds, signs, notarizes and staples the release artifacts into .build/release-artifacts/<version>.
# Publishes nothing. Requires a clean work tree and:
#   UNDOTURN_SIGN_IDENTITY  a "Developer ID Application: …" identity in the keychain
#   UNDOTURN_NOTARY_PROFILE a profile saved with `xcrun notarytool store-credentials`
set -eu
cd "$(dirname "$0")/.."

: "${UNDOTURN_SIGN_IDENTITY:?set UNDOTURN_SIGN_IDENTITY to a Developer ID Application identity}"
: "${UNDOTURN_NOTARY_PROFILE:?set UNDOTURN_NOTARY_PROFILE to a notarytool keychain profile}"
identities=$(security find-identity -v -p codesigning)
# Lines read `  1) <40-hex SHA-1> "<name>"`; the identity must equal a name or a SHA-1 exactly.
if ! printf '%s\n' "$identities" | awk -v wanted="$UNDOTURN_SIGN_IDENTITY" '
  $2 ~ /^[0-9A-F]+$/ && length($2) == 40 {
    name = substr($0, index($0, "\"") + 1); sub(/"[^"]*$/, "", name)
    if (name ~ /^Developer ID Application: / && (wanted == name || wanted == $2)) found = 1
  }
  END { exit !found }'; then
  echo "no valid Developer ID Application identity is named or has the SHA-1: $UNDOTURN_SIGN_IDENTITY" >&2
  exit 1
fi
version=$(sed -n 's/.*current = "\([^"]*\)".*/\1/p' Sources/UndoTurnCore/UndoTurnVersion.swift)
case "$version" in
  *-dev*) echo "refusing to release development version $version" >&2; exit 1 ;;
esac
changes=$(git status --porcelain)
if [ -n "$changes" ]; then
  echo "work tree has uncommitted changes; release from a clean commit" >&2
  exit 1
fi
dist="$PWD/.build/release-artifacts/$version"
if [ -e "$dist" ]; then
  echo "release output already exists: $dist" >&2
  exit 1
fi
mkdir -p "$dist"
work=$(mktemp -d "$PWD/.build/UndoTurn-release.XXXXXX")

notarize() {
  if ! result=$(xcrun notarytool submit "$1" --keychain-profile "$UNDOTURN_NOTARY_PROFILE" --wait \
    --output-format json); then
    printf '%s\n' "$result" >&2
    echo "notarytool could not submit $1" >&2
    exit 1
  fi
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

dmg="$dist/UndoTurn.dmg"
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
cp ".build/dist/$cli.tar.gz" "$dist/undoturn-macos-universal.tar.gz"

(cd "$dist" && shasum -a 256 UndoTurn.dmg undoturn-macos-universal.tar.gz >SHA256SUMS)
cat "$dist/SHA256SUMS"
echo "Release artifacts: $dist"
echo "Intermediate files: $work"
