# Contributing to UndoTurn

Thank you for your help. This guide explains how to propose a change.

## Before you start

- For a bug, open an issue with the bug template.
- For a new feature or a design change, open an issue first. Wait for agreement before you write code.

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
- Add a line to `CHANGELOG.md` under `Unreleased` for user-visible changes.
- If you change `docs/GUIDE.md`, run `sh scripts/build-docs.sh` and commit `docs/guide.html` with it. The script needs pandoc 3.8 or later.

## License of contributions

By contributing, you agree that your contribution is licensed under the [Apache License 2.0](LICENSE), as stated in its section 5.

## Code of conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
