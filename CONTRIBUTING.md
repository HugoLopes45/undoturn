# Contributing to UndoTurn

Thank you for your help. This guide explains how to propose a change.

## Before you start

- For a bug, open an issue with the bug template.
- For a new feature or a design change, open an issue first. Wait for agreement before you write code.

## How issues are handled

1. A new issue gets `needs-triage`. The maintainer answers within 7 days.
2. Triage replaces `needs-triage` with one of these labels:
   - `confirmed`: the bug is reproduced, or the feature is accepted. A pull request is welcome.
   - `needs-info`: more information is necessary. Without an answer in 30 days, the issue is closed. It can be reopened.
   - `duplicate`, `invalid` or `wontfix`: the issue is closed with a reason.
3. `area:*` and `agent:*` labels show the part of UndoTurn and the agent. `good first issue` and `help wanted` mark issues for new contributors.
4. `data-loss` marks a confirmed loss of user data. It is fixed before all other work. Report such a problem privately first, as described in [SECURITY.md](SECURITY.md).

Questions and open ideas go to [Discussions](https://github.com/HugoLopes45/undoturn/discussions). An accepted idea becomes an issue.

## Set up

Requirements: macOS 14 or later, Xcode 26 or later (Swift 6.2 or later).

```sh
swift build
swift test
swift format lint --strict --recursive Sources Tests Package.swift
```

To format your changes: `swift format --in-place --recursive Sources Tests Package.swift`.

## Rules for code

- Put logic in `UndoTurnCore`. Keep the CLI and the app thin.
- Write a test first for each new behavior. Use Swift Testing (`import Testing`).
- Never lose user data. When undo is not sure, it keeps the file and reports it.
- Measure before you optimize. Put numbers in the pull request.
- Do not add a dependency without discussion in an issue.

## Pull requests

- One topic per pull request. Keep it small.
- The subject says what changes. The body says why.
- CI must pass: build, tests and format lint.
- If you change hook handling, also run `scripts/agent-drill.sh claude` and `scripts/agent-drill.sh codex`. Each runs one short turn with your agent login and checks undo and redo.
- Add a line to `CHANGELOG.md` under `Unreleased` for user-visible changes. See [Changelog](#changelog).
- If you change `docs/GUIDE.md`, run `sh scripts/build-docs.sh` and commit `docs/guide.html` with it. The script needs pandoc 3.8 or later.

## Changelog

`CHANGELOG.md` follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/).

- Add each user-visible change under `## [Unreleased]`. Use these sections, in this order: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
- Write for users. Say what changes for them, not how the code changes.
- Start the entry with `**Breaking:**` when users must do something, for example reinstall hooks.
- Link the issue at the end of the entry when one exists, for example `(#123)`.
- A change that users cannot notice needs no entry: tests, CI, refactoring or internal documentation. A maintainer adds the `skip-changelog` label to the pull request.
- `sh scripts/changelog.sh check` validates the file. CI runs it, and fails a pull request that changes `Sources/` or `packaging/` without a `CHANGELOG.md` change.

## Releases

For maintainers:

1. Choose the version by Semantic Versioning. Before 1.0.0, a breaking change increments the minor version.
2. On a branch, set the version in `Sources/UndoTurnCore/UndoTurnVersion.swift`. Then run `sh scripts/changelog.sh release X.Y.Z`. It moves `Unreleased` into a release dated today and updates the compare links.
3. Merge the pull request into `main`. Build from that clean commit.
4. With a Developer ID Application identity and an existing notarytool Keychain profile, build locally:

   ```sh
   export UNDOTURN_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
   export UNDOTURN_NOTARY_PROFILE="your-notary-profile"
   sh scripts/release.sh
   ```

5. Check `SHA256SUMS` in `.build/release-artifacts/X.Y.Z`, install the DMG and exercise the app and bundled CLI. The three release assets are `UndoTurn.dmg`, `undoturn-macos-universal.tar.gz` and `SHA256SUMS`. Keep binaries out of Git history.
6. Tag the validated commit: `git tag -a vX.Y.Z -m "UndoTurn X.Y.Z"`, then `git push origin main vX.Y.Z`.
7. Create a draft with the changelog notes and the three files:

   ```sh
   sh scripts/changelog.sh notes X.Y.Z > .build/release-notes.md
   gh release create vX.Y.Z --draft --verify-tag --title "UndoTurn X.Y.Z" \
     --notes-file .build/release-notes.md \
     .build/release-artifacts/X.Y.Z/UndoTurn.dmg \
     .build/release-artifacts/X.Y.Z/undoturn-macos-universal.tar.gz \
     .build/release-artifacts/X.Y.Z/SHA256SUMS
   ```

8. State the build commit and whether the build was local or GitHub-hosted in the release notes. Local builds do not have GitHub provenance attestations.
9. Check the draft and its downloads, then publish it: `gh release edit vX.Y.Z --draft=false --latest`.

To build on GitHub instead, configure the `release` environment with `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`. Run `gh workflow run release.yml --ref vX.Y.Z` on the changelog's UTC release date. The manual workflow checks the tag, builds, tests, signs, notarizes and attests the same three assets, then creates the draft. Do not run both publication paths for the same tag.

## License of contributions

By contributing, you agree that your contribution is licensed under the [Apache License 2.0](LICENSE), as stated in its section 5.

## Code of conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
