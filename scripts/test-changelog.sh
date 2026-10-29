#!/bin/sh
# Tests scripts/changelog.sh against small changelogs in a temporary folder.
set -u
tool="$(cd "$(dirname "$0")" && pwd)/changelog.sh"
cd "$(mktemp -d)" || exit 1
failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# run <args…>: runs the tool on ./CHANGELOG.md; sets $status and leaves its output in ./out.
run() {
  if sh "$tool" "$@" >out 2>&1; then status=0; else status=1; fi
}

# expect_check <name> <expected exit status>; reads the changelog from stdin.
expect_check() {
  cat >CHANGELOG.md
  run check
  if [ "$status" != "$2" ]; then
    fail "$1: check exited $status, expected $2"
    sed 's/^/  /' out >&2
  fi
}

valid() {
  cat <<'EOF'
# Changelog

Intro.

## [Unreleased]

### Added

- New thing.

## [1.1.0] - 2026-02-01

### Added

- Feature B.

### Fixed

- Bug A.

## [1.0.0] - 2026-01-01

### Added

- Feature A.

[unreleased]: https://example.com/r/compare/v1.1.0...HEAD
[1.1.0]: https://example.com/r/compare/v1.0.0...v1.1.0
[1.0.0]: https://example.com/r/releases/tag/v1.0.0
EOF
}

valid | expect_check "valid changelog" 0
valid | sed 's/^## \[1.0.0\] - 2026-01-01$/## [1.0.0] - 2026-01-01 [YANKED]/' |
  expect_check "yanked release" 0
valid | sed 's/^# Changelog$/# Changes/' | expect_check "wrong title" 1
valid | sed '/^## \[Unreleased\]$/d' | expect_check "missing Unreleased" 1
valid | sed 's/^## \[1.1.0\] - 2026-02-01$/## [1.1.0]/' | expect_check "missing date" 1
valid | sed 's/2026-02-01/2026-2-1/' | expect_check "malformed date" 1
valid | sed 's/^## \[1.1.0\] - 2026-02-01$/## [1.1] - 2026-02-01/; s/^\[1.1.0\]:/[1.1]:/' |
  expect_check "malformed version" 1
valid | sed 's/^## \[1.1.0\]/## [0.9.0]/; s/^\[1.1.0\]:/[0.9.0]:/' |
  expect_check "versions not descending" 1
valid | sed 's/^## \[1.1.0\]/## [1.0.0]/; /^\[1.1.0\]:/d' | expect_check "duplicate version" 1
valid | sed 's/2026-02-01/2025-12-01/' | expect_check "dates not descending" 1
valid | sed 's/^### Fixed$/### Bugfixes/' | expect_check "unknown section" 1
valid | sed 's/^### Fixed$/### Added/' | expect_check "duplicate section" 1
valid | sed 's/^### Added$/### Security/' | expect_check "sections out of order" 1
valid | sed 's/^- Bug A\.$//' | expect_check "empty section" 1
valid | sed '/^## \[1.0.0\]/,/^\[unreleased\]/{/^### Added$/d;/^- Feature A\.$/d;}' |
  expect_check "empty release" 1
valid | sed '/^\[1.0.0\]:/d' | expect_check "missing link" 1
valid | sed '/^\[unreleased\]:/d' | expect_check "missing Unreleased link" 1
valid | sed 's/^\[1.0.0\]: .*$/[1.0.0]:/' | expect_check "empty link" 1
valid | awk '{ print } /^Intro\.$/ { print ""; print "### Added"; print ""; print "- Orphan." }' |
  expect_check "section outside a release" 1

valid >CHANGELOG.md
run check extra
[ "$status" = 1 ] || fail "check rejects extra arguments"

rm -f CHANGELOG.md
run check
[ "$status" = 1 ] || fail "check without CHANGELOG.md fails"
grep -q "CHANGELOG.md" out || fail "check names the missing CHANGELOG.md"

# notes
valid >CHANGELOG.md
run notes 1.1.0
cat >expected <<'EOF'
### Added

- Feature B.

### Fixed

- Bug A.
EOF
if [ "$status" != 0 ] || ! cmp -s out expected; then fail "notes prints the body of one release"; fi
run notes 1.0.0
printf '### Added\n\n- Feature A.\n' >expected
if [ "$status" != 0 ] || ! cmp -s out expected; then fail "notes stops before the links"; fi
run notes 2.0.0
[ "$status" = 1 ] || fail "notes fails for an unknown version"
run notes Unreleased
[ "$status" = 1 ] || fail "notes refuses Unreleased"
run notes
[ "$status" = 1 ] || fail "notes requires a version"

# release
today=$(date +%Y-%m-%d)
valid >CHANGELOG.md
run release 1.2.0
cat >expected <<EOF
# Changelog

Intro.

## [Unreleased]

## [1.2.0] - $today

### Added

- New thing.

## [1.1.0] - 2026-02-01

### Added

- Feature B.

### Fixed

- Bug A.

## [1.0.0] - 2026-01-01

### Added

- Feature A.

[unreleased]: https://example.com/r/compare/v1.2.0...HEAD
[1.2.0]: https://example.com/r/compare/v1.1.0...v1.2.0
[1.1.0]: https://example.com/r/compare/v1.0.0...v1.1.0
[1.0.0]: https://example.com/r/releases/tag/v1.0.0
EOF
if [ "$status" != 0 ] || ! cmp -s CHANGELOG.md expected; then
  fail "release moves Unreleased into a dated release and updates the links"
  sed 's/^/  /' out >&2
  diff expected CHANGELOG.md >&2
fi
run check
[ "$status" = 0 ] || fail "a released changelog passes check"

valid >CHANGELOG.md
run release 1.2.0-beta.1
[ "$status" = 0 ] || fail "release accepts a pre-release version"
grep -q '^\[1.2.0-beta.1\]: https://example.com/r/compare/v1.1.0...v1.2.0-beta.1$' CHANGELOG.md ||
  fail "release links a pre-release"

for version in 1.1.0 1.0.5 1.1 v1.2.0 ""; do
  valid >CHANGELOG.md
  run release ${version:+"$version"}
  [ "$status" = 1 ] || fail "release refuses version '$version'"
  valid | cmp -s - CHANGELOG.md || fail "a refused release '$version' leaves the file unchanged"
done

valid | sed '/^## \[Unreleased\]$/,/^## \[1.1.0\]/{/^### Added$/d;/^- New thing\.$/d;}' >CHANGELOG.md
run release 1.2.0
[ "$status" = 1 ] || fail "release refuses an empty Unreleased section"

cat >CHANGELOG.md <<'EOF'
# Changelog

## [Unreleased]

### Added

- First feature.

[unreleased]: https://example.com/r/commits/HEAD
EOF
run release 0.1.0
cat >expected <<EOF
# Changelog

## [Unreleased]

## [0.1.0] - $today

### Added

- First feature.

[unreleased]: https://example.com/r/compare/v0.1.0...HEAD
[0.1.0]: https://example.com/r/releases/tag/v0.1.0
EOF
if [ "$status" != 0 ] || ! cmp -s CHANGELOG.md expected; then
  fail "release of the first version links its tag"
  sed 's/^/  /' out >&2
  diff expected CHANGELOG.md >&2
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures changelog test(s) failed" >&2
  exit 1
fi
echo "changelog tests passed"
