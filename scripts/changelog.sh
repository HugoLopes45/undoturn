#!/bin/sh
# Checks and edits CHANGELOG.md in the current folder (Keep a Changelog 1.1.0, SemVer, tags vX.Y.Z).
#   check            validate the format; exit 1 with file:line messages on errors
#   notes <version>  print the body of one release, for the release notes
#   release <version> move Unreleased into "## [<version>] - <today>" and update the links
set -eu

usage() {
  echo "usage: $0 check | notes <version> | release <version>" >&2
  exit 2
}

[ -f CHANGELOG.md ] || {
  echo "no CHANGELOG.md in $PWD" >&2
  exit 1
}

# One awk program for all modes, so check, notes and release parse the file the same way.
run_awk() {
  awk -v mode="$1" -v wanted="${2-}" -v today="${3-}" '
function fail(line, message) {
  printf "CHANGELOG.md:%d: %s\n", line, message > "/dev/stderr"
  errors++
}
function is_version(v) {
  return v ~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$/
}
# Compares two pre-release identifiers by SemVer 2.0.0 rule 11: <0, 0 or >0.
function compare_identifier(a, b,   a_number, b_number) {
  a_number = a ~ /^[0-9]+$/
  b_number = b ~ /^[0-9]+$/
  if (a_number && b_number) return (a + 0) - (b + 0)
  if (a_number) return -1
  if (b_number) return 1
  return a < b ? -1 : (a > b ? 1 : 0)
}
# Compares two SemVer versions: <0, 0 or >0.
function compare_version(a, b,   a_pre, b_pre, a_core, b_core, a_ids, b_ids, n_a, n_b, i, c) {
  a_pre = index(a, "-") ? substr(a, index(a, "-") + 1) : ""
  b_pre = index(b, "-") ? substr(b, index(b, "-") + 1) : ""
  split(index(a, "-") ? substr(a, 1, index(a, "-") - 1) : a, a_core, ".")
  split(index(b, "-") ? substr(b, 1, index(b, "-") - 1) : b, b_core, ".")
  for (i = 1; i <= 3; i++) if (a_core[i] + 0 != b_core[i] + 0) return (a_core[i] + 0) - (b_core[i] + 0)
  if (a_pre == "" || b_pre == "") return (a_pre == "") - (b_pre == "")
  n_a = split(a_pre, a_ids, ".")
  n_b = split(b_pre, b_ids, ".")
  for (i = 1; i <= n_a && i <= n_b; i++) {
    c = compare_identifier(a_ids[i], b_ids[i])
    if (c != 0) return c
  }
  return n_a - n_b
}
function valid_date(d,   month, day) {
  if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return 0
  month = substr(d, 6, 2) + 0
  day = substr(d, 9, 2) + 0
  return month >= 1 && month <= 12 && day >= 1 && day <= 31
}
function end_section() {
  if (section != "" && section_lines == 0) fail(section_line, "section \"" section "\" is empty")
  section = ""
}
function end_release() {
  end_section()
  if (release != "" && release != "Unreleased" && release_lines == 0)
    fail(release_line, "release " release " has no entries")
  release = ""
}
BEGIN {
  rank["Added"] = 1; rank["Changed"] = 2; rank["Deprecated"] = 3
  rank["Removed"] = 4; rank["Fixed"] = 5; rank["Security"] = 6
}
{ lines[NR] = $0 }
NR == 1 && $0 != "# Changelog" { fail(NR, "the first line must be \"# Changelog\"") }
/^\[[^]]+\]:/ {
  if (!in_links) end_release()
  in_links = 1
  label = substr($0, 2, index($0, "]") - 2)
  url = substr($0, index($0, "]:") + 2)
  sub(/^[ \t]+/, "", url)
  if (url == "") fail(NR, "link [" label "] has no URL")
  link[tolower(label)] = url
  link_line[tolower(label)] = NR
  next
}
in_links && $0 != "" { fail(NR, "text after the link references") }
/^## / {
  end_release()
  release_line = NR
  release_lines = 0
  last_rank = 0
  if ($0 == "## [Unreleased]") {
    if (unreleased_line) fail(NR, "a second [Unreleased] heading")
    else if (versions) fail(NR, "[Unreleased] must come before every release")
    unreleased_line = NR
    release = "Unreleased"
    next
  }
  if (!unreleased_line && !versions) fail(NR, "the first release heading must be \"## [Unreleased]\"")
  if ($0 !~ /^## \[[^]]+\] - [^ ]+( \[YANKED\])?$/) {
    fail(NR, "a release heading must read \"## [X.Y.Z] - YYYY-MM-DD\", optionally followed by \" [YANKED]\"")
    release = "?"
    next
  }
  release = substr($0, 5, index($0, "]") - 5)
  date = substr($0, index($0, "] - ") + 4, 10)
  if (!is_version(release)) fail(NR, "\"" release "\" is not a SemVer version")
  if (!valid_date(date)) fail(NR, "\"" date "\" is not a YYYY-MM-DD date")
  if (release in version_line) fail(NR, "version " release " is also on line " version_line[release])
  else if (versions && is_version(release) && is_version(previous) && compare_version(release, previous) >= 0)
    fail(NR, "version " release " must be lower than " previous " above it")
  if (versions && date > previous_date) fail(NR, "date " date " is later than " previous_date " above it")
  version_line[release] = NR
  order[++versions] = release
  previous = release
  previous_date = date
  next
}
/^### / {
  end_section()
  name = substr($0, 5)
  if (release == "") { fail(NR, "section \"" name "\" is outside a release"); next }
  if (!(name in rank)) fail(NR, "unknown section \"" name "\"; use Added, Changed, Deprecated, Removed, Fixed or Security")
  else if (rank[name] <= last_rank) fail(NR, "section \"" name "\" is repeated or out of order (Added, Changed, Deprecated, Removed, Fixed, Security)")
  else last_rank = rank[name]
  section = name
  section_line = NR
  section_lines = 0
  next
}
$0 != "" && release != "" {
  release_lines++
  section_lines++
}
END {
  end_release()
  if (!unreleased_line && !versions) fail(NR, "no \"## [Unreleased]\" heading")
  else if (!("unreleased" in link)) fail(NR, "no [unreleased] link reference")
  for (i = 1; i <= versions; i++)
    if (!(tolower(order[i]) in link)) fail(version_line[order[i]], "no [" order[i] "] link reference")
  if (errors) exit 1

  if (mode == "notes") {
    if (!(wanted in version_line)) { print "no release " wanted " in CHANGELOG.md" > "/dev/stderr"; exit 1 }
    first = version_line[wanted] + 1
    for (last = first; last < NR && lines[last + 1] !~ /^## / && lines[last + 1] !~ /^\[[^]]+\]:/; last++) {}
    while (first <= last && lines[first] == "") first++
    while (last >= first && lines[last] == "") last--
    for (i = first; i <= last; i++) print lines[i]
  }

  if (mode == "release") {
    if (!is_version(wanted)) { print "\"" wanted "\" is not a SemVer version such as 1.2.0" > "/dev/stderr"; exit 1 }
    if (versions && compare_version(wanted, order[1]) <= 0) {
      print "version " wanted " must be higher than the latest release " order[1] > "/dev/stderr"
      exit 1
    }
    for (i = unreleased_line + 1; i <= NR && lines[i] !~ /^## / && lines[i] !~ /^\[[^]]+\]:/; i++)
      if (lines[i] != "") entries++
    if (!entries) { print "the [Unreleased] section is empty; nothing to release" > "/dev/stderr"; exit 1 }
    base = link["unreleased"]
    if (index(base, "/compare/")) base = substr(base, 1, index(base, "/compare/") - 1)
    else if (index(base, "/commits/")) base = substr(base, 1, index(base, "/commits/") - 1)
    else { print "the [unreleased] link must end in /compare/<tag>...HEAD or /commits/HEAD" > "/dev/stderr"; exit 1 }
    for (i = 1; i <= NR; i++) {
      if (i == link_line["unreleased"]) {
        print substr(lines[i], 1, index(lines[i], "]:") + 1) " " base "/compare/v" wanted "...HEAD"
        if (versions) print "[" wanted "]: " base "/compare/v" order[1] "...v" wanted
        else print "[" wanted "]: " base "/releases/tag/v" wanted
        continue
      }
      print lines[i]
      if (i == unreleased_line) { print ""; print "## [" wanted "] - " today }
    }
  }
}' CHANGELOG.md
}

case "${1-}" in
  check)
    [ $# -eq 1 ] || usage
    run_awk check
    ;;
  notes)
    [ $# -eq 2 ] || usage
    run_awk notes "$2"
    ;;
  release)
    [ $# -eq 2 ] || usage
    updated=$(mktemp)
    run_awk release "$2" "$(date +%Y-%m-%d)" >"$updated"
    mv "$updated" CHANGELOG.md
    ;;
  *) usage ;;
esac
