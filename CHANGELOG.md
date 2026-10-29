# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-29

### Added

- Agents can inspect and restore history through `undoturn mcp`, a stdio MCP server. Moves retain conflict protection and never force writes (ADR 0036).
- `undoturn storage` lists stored histories and reclaimable space; `storage remove <root>` deletes one history without touching project files. Both support JSON.
- `undoturn restore <path…> --at <id>` restores selected files or folders without moving history; `--after` selects the state after the turn. History moves and file restoration support `--dry-run` (ADR 0037).
- First version: turn recording, undo, redo and goto for ten agent CLIs, the `undoturn` CLI, an optional FSEvents service and a menu bar app. See the [README](README.md) and the [user guide](docs/GUIDE.md).
- `undoturn revert <id>` undoes only one turn and keeps the turns after it. The result is a new turn that `undo` can take back (ADR 0029).
- Turns record symbolic links by target, and undo restores them. Links are never followed (ADR 0030).
- Turns record folders with their modes. Undo restores empty folders and removes the folders that a turn made, unless they contain other files (ADR 0031).
- In Claude Code and Codex, the prompt `undoturn undo` or `undoturn redo` runs the command and never reaches the model (ADR 0033).
- Gemini CLI and Cursor prompt hooks also handle exact `undoturn undo` and `undoturn redo` prompts with their native block responses (ADR 0039).
- The menu bar app's **Manage Storage…** window lists each project's history with its turns, last activity and estimated reclaimable space. It deletes one history or all of them, and refuses a project with a running turn (ADR 0032).
- Prompts, replies, commands and agent questions show `[secret]` in place of private keys, known API key formats, `Bearer` credentials, URL passwords and values of names such as `password` or `api_key`. UndoTurn hides them before it stores or shows the text (ADR 0034).
- A `.undoturnignore` file in the project root keeps files out of UndoTurn, also `.env*` files. It uses a subset of the `.gitignore` syntax: `*`, `?`, `**`, `!`, a leading or inner `/` and a trailing `/`. Explicit `undoturn gc` removes copies used only by ignored paths when no turn or restoration is pending (ADR 0035).
- The optional service runs ordinary retention at startup and daily. Busy projects are skipped and incomplete runs are logged. Historical ignored-path purging remains exclusive to explicit `undoturn gc` (ADR 0038).
- Shared recording retains each overlapping session's identity and status. Stale Stop events cannot close another session, and intervening edits become separate between-turns nodes.
- Claude Code, Codex, Gemini and Cursor pre-tool hooks gate recognized destructive commands and create pre-command checkpoints without losing active participants or outside watches.
- Native file/folder Before and After recovery includes previews and per-file results. Selective turn revert is separate from history navigation; native recovery refuses active recording.
- The app can install agent hooks, run setup diagnostics, and show hook failures recorded within the last 24 hours.
- Local packaging scripts produce an unsigned DMG that contains an ad-hoc signed app and bundled CLI/service helpers, plus a SHA-256 sidecar. Developer ID signing and notarization remain outside this build.
- A browser user guide, `docs/guide.html`, generated from `docs/GUIDE.md` by `scripts/build-docs.sh`.

### Fixed

- Correct the documentation of `.env*` files: `.undoturnignore` excludes them, and stored copies are not redacted.
- Place a new menu bar icon toward the right edge to avoid the camera notch, while preserving user-saved positions.
- Replace first-launch Copy Command with native hook installation, using the bundled CLI without requiring a shell `PATH` entry.
- Enforce the timeline's 960×440-point content minimum through SwiftUI sizing constraints so resizing cannot clip the three columns.
- Persist mirror boundary identity and observation time so crash repair and ignore-policy transitions preserve intervening edits without phantom turns.
- Journal completed operations and directory staging; preserve later deletions and permission changes, and restore read-only directory trees before applying final modes.
- Bound participant metadata and both split columns so expanded recording details and historical hook failures remain usable in a 960×620 window.
- Simplify complex parser, recorder, restore, scanner, service, CLI and timeline functions; remove redundant branches and sorting without relaxing lint rules.
- Preserve a continued agent turn when a move fails after appending history but before saving the mirror. Recovery retains later edits and outside-file watches without duplicating the committed turn.
- Detect changes, removal and renaming of `.undoturnignore` even when Git or its own rules hide it. Durable metadata distinguishes old unknown baselines from observed absence without storing rule contents.
- Split history summary and replay validation into bounded functions without changing recorded history or restore behavior.
- Restore splits paths on `/` bytes. A slash followed by a combining mark could hide `..` from validation and let undo write outside the workspace.
- Escape shell quotes by Unicode scalar in resume commands and hook executable paths, including apostrophes followed by combining marks or joiners. Hook ownership parsing uses the same scalar boundaries.
- Render agent replies without active links while preserving inline formatting and visible text.
- Keep hook diagnostics on one physical log line when an outside path contains CRLF.
- Count rejected outside-path walks against the shared 5,000-entry budget. Stop directory enumeration at the limit and identify the limit as per tool call.
- Decode Oh My Pi's hashline and file-edit payloads, including multiple files and rename destinations. Respect `bash.cwd` and skip internal-URL writes before acquiring the history lock.
- Detect Pi versus Oh My Pi at runtime when they share an extension directory. Use the host's tool names and completion event. Stop Oh My Pi hook children after 25 seconds and Pi hook children after 60 seconds.
- Exclude read-only shell operands and search patterns from outside-path collection while retaining output redirections and mutating forms. Keep the operands when output goes to a file or to a command that acts on its input, or when the command redefines a reading command's name. Kept operands use the entry budget after the paths that commands write. Handle line continuations and empty arguments correctly.
- Skip outside-path candidates that the file system refuses as too-long names, such as inline code. These words no longer log a failed hook.
- Remove the temporary files that a killed undo, redo or goto leaves next to the files it was writing. The recovery of the journal now removes them (ADR 0011).
- A hook that waited for a project's lock while its history was deleted takes the lock of the new history folder, so two hooks never write the same history at the same time (ADR 0032).
- A menu bar undo or redo that keeps files shows every kept file in the timeline. When notifications are unavailable, the timeline opens with the report in place of a truncated alert. UndoTurn keeps only the latest report.
- Bind each recovery notification to its exact result, not just its project and turn. An older notification reports that its details are unavailable instead of showing a later undo or redo.
- The turn header scrolls within half the detail pane, so an expanded prompt cannot push the files and diff out of view. A running turn's detail scrolls too.
- Remove **Undo Only This Turn** from the turn's actions menu. **Revert Just This Turn…** is the only selective revert, and it shows a preview and asks for confirmation.
- The **Redo** button after a timeline undo applies only to the project that the undo changed.
- Name the source project and its full path in recovery reports and accessibility announcements, including results that arrive after switching projects.

Malformed hook commands from the previous quoting bug are not automatically removed. Remove those invalid entries manually before reinstalling hooks.

[unreleased]: https://github.com/HugoLopes45/undoturn/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/HugoLopes45/undoturn/releases/tag/v0.1.0
