# Threat model

This document describes what UndoTurn protects, what it does not protect, and where it writes files. Report a vulnerability as described in `SECURITY.md`.

## Scope

UndoTurn runs as the logged-in user. Agent hooks, the `undoturn` CLI and the menu bar app all use the same user account and the same store. UndoTurn is a recovery tool, not a sandbox and not a backup:

- A process that runs as the same user can read and change the store. UndoTurn can not protect its history from a malicious agent that has full access to the user's files.
- The store is on the same volume as the projects. A disk failure loses both. Use a real backup (for example Time Machine) as well.

## Assets

| Asset | Where |
|---|---|
| Stored file versions, including `.env*` secrets | `<store>/workspaces/<id>/objects/` |
| History: prompts, labels, paths, turn times | `<store>/workspaces/<id>/history.log` |
| Running turn: newest shell command or file path, and the agent's question | `<store>/workspaces/<id>/live`, removed when the turn ends |
| Undo journal and mirror | `<store>/workspaces/<id>/journal`, `mirror` |
| Agent settings, backups and generated hooks | `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.gemini/settings.json`, `~/.cursor/hooks.json`, `~/.factory/settings.json`, `~/.config/devin/config.json`, `~/.copilot/hooks/undoturn.json`, `~/.config/opencode/plugins/undoturn.js`, `~/.pi/agent/extensions/undoturn.ts`, `~/.omp/agent/extensions/undoturn.ts` |

`<store>` is `$UNDOTURN_HOME`, by default `~/Library/Application Support/UndoTurn`.

## Store permissions

- The store folder and each workspace folder have mode `0700`. UndoTurn sets this mode again each time it opens them.
- Stored objects, temporary files, the history log, the journal, the `live` file and `hook-errors.log` have mode `0600`.
- Stored objects and `hook-errors.log` are opened with `O_NOFOLLOW`. A symbolic link put in place of one of them makes the operation fail; UndoTurn does not follow it.
- Object ids are exactly 32 lowercase hexadecimal characters before UndoTurn makes a path from them.

These are POSIX permissions only. UndoTurn does not check ACLs on the store folder.

## Secrets in `.env` files

- The scanner records `.env*` files, also when `.gitignore` ignores them. This lets an undo restore a deleted `.env` file.
- A `.undoturnignore` file in the project root keeps the paths that it matches out of the store, also `.env*` files. The scanner does not look into the folders that it matches. Explicit `undoturn gc` removes stored versions of these paths, also on the history path to `head`. Purging waits while a turn is pending or an undo journal exists; rerun `gc` after it ends. A redirected project root is rejected before its ignore rules are read. A version that a path outside `.undoturnignore` also uses stays. The history keeps the paths and sizes. UndoTurn reads only the root `.undoturnignore`.
- A stored version stays in the store while the history path from the first turn to `head` refers to it. `undoturn gc` removes other versions after 30 days, or the oldest ones when the store passes 5 GiB. The optional service runs ordinary retention at startup and daily. It does not purge historical versions because of `.undoturnignore`; that requires explicit `undoturn gc`. Without the service, collection is manual. Rotating a secret does not remove its older versions.
- To remove all stored versions of one project, select **Delete History…** in the app's Storage window. Without the app, run `undoturn storage remove <project root>`; `undoturn storage` lists the recorded roots. Both refuse while a turn is running and never change the project folder. The project's whole history is lost.
- Settings-hook integrations keep full backup copies (`*.undoturn-backup-<time>`, mode `0600`) when they change an existing settings file. Copilot and generated extension files are UndoTurn-owned files and are not backed up as settings.

## Hook file writes

Each hook process reads at most 1 MiB of JSON from standard input and writes only:

- into `<store>/workspaces/<id>/` of the resolved workspace: objects, history records, the mirror, the `live` file and the lock file;
- `<store>/hook-errors.log`, opened with `O_APPEND | O_NOFOLLOW`, mode `0600`, trimmed when it passes 64 KiB.

The hook never writes into the project. Only `undo`, `redo`, `goto`, `revert`, `restore` and the matching app actions write project files.

`undoturn init` and `undoturn uninstall` update settings-hook files with a backup and atomic replacement. They also write the UndoTurn-owned Copilot hook file and generated Pi/OpenCode/Oh My Pi extension files atomically; the extensions begin with an UndoTurn marker, and install/uninstall refuse foreign files. A harness loads an extension inside its own process: that file executes with the user's rights, as can the agent itself. Its purpose here is to pass the event payload to the local `undoturn hook` process. Review the generated code at its documented path before running an agent if you want to inspect it. Hook commands use the shell-quoted absolute path of the `undoturn` executable. Its parent folders are resolved. A last link named `undoturn`, such as the Homebrew `bin/undoturn`, is kept, so the hooks stay valid after an upgrade. A link with another name is resolved to the binary. `undoturn service install` uses `undoturn-service` next to that path, else next to the resolved binary.

## Threats and controls

| Threat | Control | Reference |
|---|---|---|
| A hook starts in the home folder, `/Users`, `~/Library` or the store, and records far too much, or records the store itself | Roots that contain the home folder, contain the store, or are inside the store are refused. A folder directly inside the home folder without `.git` is refused. A refused root records nothing | `Sources/UndoTurnCore/Workspace.swift` |
| An agent replaces a parent folder with a symbolic link, so an undo writes outside the project | Restore walks parent folders with `openat` and `O_NOFOLLOW` from the workspace root. Such files are kept, also with `--force` | `Sources/UndoTurnCore/UndoEngine.swift` |
| A file is swapped while UndoTurn stores it | Clones use `CLONE_NOFOLLOW`. The copy fallback compares the stat key before and after the copy | `Sources/UndoTurnCore/ObjectStore.swift` |
| A crash or full disk stops an undo after some files | Durable journal. Recovery-capable operations, such as `list` or a normal history move, attempt to finish the interrupted recovery under the project lock. A preview refuses instead. Deleting the history discards the journal without completing the recovery. See the first known limit | `Sources/UndoTurnCore/Journal.swift`, `Sources/UndoTurnCore/UndoEngine.swift`, `Sources/UndoTurnCore/Session.swift`, `Sources/UndoTurnCore/Storage.swift` |
| The user edits a file after the turn, then undoes the turn | The file is kept and listed in the report | `Sources/UndoTurnCore/RestorePlanner.swift` |
| An unreadable file or a non-UTF-8 `.gitignore` stops recording | An unreadable file is recorded as not stored. Ignore-file lines that are not valid UTF-8 are skipped. `doctor` shows hook errors | `Sources/UndoTurnCore/Recorder.swift`, `IgnoreRules.swift` |
| A prompt, reply, command or agent question contains a credential | Known credential shapes become `[secret]` before UndoTurn stores, shows or cuts the text (ADR 0034) | `Sources/UndoTurnCore/Secrets.swift` |
| A prompt, file name or diff line contains terminal escape sequences | The CLI escapes C0 and C1 control characters and DEL in all recorded text. Prompts can not add colors | `Sources/undoturn/Output.swift` |
| A project path or session id places shell syntax outside a copied resume command's quotes | Resume commands and hook executable paths escape apostrophe scalars, including those inside combined characters. Hook ownership parsing also uses scalar boundaries | `Sources/UndoTurnLedger/ResumeCommand.swift`, `Sources/UndoTurnCore/AgentSettings.swift` |
| An outside path contains CR or LF and forges another hook-log line | Log text replaces each CR and LF scalar with a space, including CRLF pairs | `Sources/undoturn/Output.swift` |
| An agent reply contains a Markdown link to a local file or custom URL scheme | The app removes link attributes before rendering the reply. Text and inline formatting remain visible | `Sources/UndoTurnApp/TurnConversationViews.swift` |
| A hook payload injects history records | The JSON writer escapes control characters and line separators; the reader rejects duplicate keys and deep nesting | `Sources/UndoTurnCore/JSON.swift` |
| A tool call changes files outside the project | Only paths under the home folder, `/Volumes` or `/private/tmp` are recorded. A path that contains the project or is inside the store is refused and logged. The walk skips the store. A shared 5,000-entry budget bounds directory enumeration and includes rejected walks. Over-budget paths are not partially recorded. A path that contains an unreadable folder is not recorded and is logged | `Sources/UndoTurnCore/OutsidePaths.swift`, `Sources/UndoTurnCore/Recorder.swift` |
| A mapped shell tool requests a broad deletion or destructive Git operation | Pre-tool hooks reject recognized root-wide deletions. Recognized destructive Git metadata operations require confirmation where supported, otherwise they are denied. Other recognized risky commands trigger a checkpoint. These checks do not back up `.git` or sandbox the command | `GUIDE.md` |

## Known limits

- Another process can change a file between its check and write. Recovery does not lock project files against other writers. Durable progress records prevent replaying completed operations, but a crash between a filesystem mutation and its progress record remains ambiguous.
- Recording failures are reported in `hook-errors.log`, `undoturn doctor`, and a native warning for failures recorded within the last 24 hours. The warning is historical evidence, not a live protection guarantee.
- Outside paths and command risks are inferred from mapped tool-call payloads. Scripts, variables, aliases, unsupported payloads, and other execution routes can evade detection.
- Reading commands such as `grep` and `find` add no candidates when their output reaches no file and no command that acts on it. A command found through a changed `PATH` with a reading command's name is not detected.
- Background commands can write after their turn ends. The next recording boundary captures intervening changes in a separate between-turns node, without author attribution. This is not continuous recording. Writes during a later shared interval belong to that interval, not to a proven individual author.
- Credential redaction finds known shapes only. A password in a sentence, or a key without a known prefix, is stored and shown. `history.log` lines written before redaction keep the original text on disk.
- A question notification shows the agent's message and its newest command or file path, which can contain a secret that redaction does not find. macOS shows it as its Show Previews setting allows, also on the lock screen.
