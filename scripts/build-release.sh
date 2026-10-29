#!/bin/sh
# Builds the universal undoturn CLI archive, with undoturn-service, and its SHA-256 file in .build/dist.
# Signs ad hoc unless UNDOTURN_SIGN_IDENTITY names a Developer ID Application identity.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64 --product undoturn
swift build -c release --arch arm64 --arch x86_64 --product undoturn-service
bindir=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
version=$(sed -n 's/.*current = "\([^"]*\)".*/\1/p' Sources/UndoTurnCore/UndoTurnVersion.swift)
name="undoturn-$version-macos-universal"
stage=.build/dist/$name

if otool -L "$bindir/undoturn" | grep -q Foundation; then
  echo "undoturn links Foundation; the hook process must not" >&2
  exit 1
fi
# The service needs CoreFoundation for FSEvents, but not Foundation.
if otool -L "$bindir/undoturn-service" | grep -Eq '/Foundation\.framework|libswiftFoundation'; then
  echo "undoturn-service links Foundation" >&2
  exit 1
fi

rm -rf "$stage" ".build/dist/$name.tar.gz"
mkdir -p "$stage"
for tool in undoturn undoturn-service; do
  cp "$bindir/$tool" "$stage/$tool"
  strip -x "$stage/$tool"
  if [ "${UNDOTURN_SIGN_IDENTITY:--}" = - ]; then
    codesign --sign - --force --timestamp=none "$stage/$tool"
  else
    codesign --sign "$UNDOTURN_SIGN_IDENTITY" --force --options runtime --timestamp "$stage/$tool"
  fi
done
cp LICENSE README.md CHANGELOG.md "$stage/"
# Without both settings, macOS tar archives local extended attributes as `._*` entries or as pax headers.
COPYFILE_DISABLE=1 tar --no-xattrs -C .build/dist -czf ".build/dist/$name.tar.gz" "$name"
(cd .build/dist && shasum -a 256 "$name.tar.gz" >"$name.tar.gz.sha256")
for tool in undoturn undoturn-service; do
  printf '%s: %s\n' "$tool" "$(lipo -archs "$stage/$tool")"
done
echo ".build/dist/$name.tar.gz"
