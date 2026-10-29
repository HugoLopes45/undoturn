# UndoTurn user guide

UndoTurn records local file changes around coding-agent turns so you can inspect them and recover recorded versions. The app is called **UndoTurn** and its command is **`undoturn`**.

Recording is not a protection guarantee, a sandbox, or a replacement for Git and an independent backup.

Command examples are recipes; any displayed output is **illustrative**, not a transcript of a verified installation. Turn numbers, times, and available client features depend on your installation.

## Start here

- [Install a locally supplied app](#install).
- [Try your first undo and redo](#your-first-undo-and-redo) without changing agent settings.
- [Connect a real agent](#protect-a-project), after reading the safety section below.
- [Choose a recovery action](#choose-the-right-recovery) after stopping every writer.
- [Troubleshoot missing turns or failures](#troubleshooting).

## Before you record

Read this **before `init`, Install Agent Hooks…, or a real agent's first recorded turn**:

- **File copies are not redacted.** UndoTurn keeps the bytes needed to restore files, including secrets in those files.
- **`.env*` files are recorded even when Git ignores them.** To exclude them, create or update the project's root `.undoturnignore` **before** registration or recording. Excluded files cannot be recovered with UndoTurn.
- **Hooks apply to your user account, not just the selected project.** `init` installs all supported integrations unless you choose `--agent`. Once installed, a supported agent can automatically register another eligible folder. Running `init` in a refused folder can still install global hooks.
- Prompts, paths, labels, session identifiers, available model names and final replies can be stored locally. Known credential shapes in conversation text are redacted, but unrecognized secrets can remain. Notifications can show conversation text and file paths.
- Recording is boundary-based, not continuous. Your edits made while an agent is working can be part of the same turn. Overlapping agents share an interval; changes are not attributed to individual authors.
- **Stop agents, background jobs, generators, and other writers before recovery.** UndoTurn cannot prevent them from writing again. Do not use `--force` as a routine repair step.
- Keep independent backups. A process with your user permissions can read or damage both the project and its local history.

For example, add these rules to an existing `.undoturnignore`, or create that file in the project root. Review the patterns for your project; do not replace unrelated rules:

```gitignore
.env*
secrets/
*.pem
```

This does not modify or sanitize any `.env` file. It changes what future recording may store. Earlier copies remain until explicitly [purged or deleted](#ignored-files). See [What UndoTurn stores](#what-undoturn-stores) for privacy and retention details.

## Concepts

| Term | Meaning |
|---|---|
| Project / workspace | The resolved folder whose files UndoTurn scans. `init`, or the first recorded agent turn or `run`, registers it. |
| Turn | A recorded interval, usually one prompt through the agent's stop event. Numbers such as `#1` are local to a project. A turn with no file changes creates no history node. |
| Current turn / head | The current **history position**, marked `*` by `list`. It does not prove that working files match it: later edits, selective restoration, or kept files can differ. Turn `0` is the baseline before the first turn. |
| Branch | Recording a new change after undo starts a new history branch. The other branch remains available while its file versions are retained. |
| Store / objects | The history and stored file versions, normally in `~/Library/Application Support/UndoTurn`. |
| Shared interval | Overlapping sessions recorded together. Participant identities and statuses are retained, but files have no per-session author attribution. |

At a recording boundary, UndoTurn observes changes since the previous boundary. Changes made between turns become a separate history node with no known author. The agent's interval records the result at its end. Background writes after a turn ends are not immediately a new node; they are observed at the next boundary.

## Install

### Requirements

| Task | Requirement |
|---|---|
| Run the app, CLI, or service | macOS 14 or later; a build for your Mac's architecture |
| Build the Swift package / CLI | Swift 6.2 toolchain and macOS development tools |
| Build or package `UndoTurn.app` | Swift 6.2 plus the **macOS 26 SDK or later**, normally supplied by Xcode 26 or later |

The SDK requirement is for building the app, not a macOS 26 runtime requirement. The app and the CLI archive are universal (arm64 and x86_64).

### Download a release

Each [release](https://github.com/HugoLopes45/undoturn/releases) has:

| File | Contents |
|---|---|
| `UndoTurn.dmg` | The menu bar app, with the CLI and the service in `Contents/Helpers` |
| `undoturn-macos-universal.tar.gz` | The CLI and the service only |
| `SHA256SUMS` | The SHA-256 of each file |

The files are universal, signed with a Developer ID and notarized by Apple. Each file also has a [build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations). To check a download:

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
gh attestation verify UndoTurn.dmg --repo HugoLopes45/undoturn
```

Then install the DMG as described below, or extract the archive and copy `undoturn` and `undoturn-service` to the same stable folder, for example `~/.local/bin`.

### Install a DMG

These steps apply to a release `UndoTurn.dmg` and to a local `UndoTurn-….dmg` that you built from this checkout or that a trusted builder supplied.

1. For a local DMG, confirm who built the image and that it is intended for your Mac. If a `.sha256` file was supplied, compare it with the DMG before opening it. A checksum checks bytes; it does not establish the builder's identity.
2. Open the DMG in Finder. Drag **UndoTurn.app** to **Applications**.
3. Eject the image. Launch `/Applications/UndoTurn.app`, not the copy still on the mounted image.
4. Look for UndoTurn in the macOS menu bar. **It has no Dock icon while its timeline and storage windows are closed.** On a first launch with no projects, the app opens the empty timeline; reopening the installed app also opens the timeline. While the timeline or storage window is open, UndoTurn also shows in the Dock.
5. If the icon is hidden near the notch or by a menu bar utility, make room in the menu bar or reopen the app from Applications. See [Troubleshooting](#troubleshooting).

Installing or opening the app is separate from installing agent hooks. You can complete the isolated drill below before choosing **Install Agent Hooks…**.

### Gatekeeper and trusted builds

A local unsigned DMG with an ad-hoc-signed, unnotarized app may be blocked by Gatekeeper. For a build you trust:

1. Attempt to open the installed app normally and read the exact macOS message.
2. If macOS offers the exception, use **System Settings → Privacy & Security → Open Anyway**, then confirm the named app. The option and wording vary by macOS version and management policy.
3. If the exception is unavailable, contact the builder or your administrator. A damaged signature, unexpected checksum, malware warning, or revoked build is a reason to stop and obtain a trusted replacement, not to bypass the warning.

Do not disable Gatekeeper, remove quarantine recursively, or turn off system security to install UndoTurn. An ad-hoc signature is not a verified publisher identity or notarization.

### Use the bundled CLI

The installed app contains both helpers:

```text
/Applications/UndoTurn.app/Contents/Helpers/undoturn
/Applications/UndoTurn.app/Contents/Helpers/undoturn-service
```

To make the bundled tools available in Terminal:

1. Open the installed app from **Applications**, not the mounted DMG.
2. Choose **Install Command-Line Tools…** in UndoTurn's menu.
3. Select a writable folder on your shell's `PATH`, such as `~/.local/bin` if you already configured it.

The app creates links named `undoturn` and `undoturn-service`. Existing files are not replaced; selecting the same folder again keeps matching links. This action does not install agent hooks, start the service or change shell settings.

Keep the app in its installed location. Replacing it there updates the linked tools; moving or deleting it breaks the links. If the chosen folder is not on `PATH`, add it yourself or use the absolute path below.

You can also use the bundled CLI directly without installing links or changing `PATH`:

```sh
UT="/Applications/UndoTurn.app/Contents/Helpers/undoturn"
"$UT" --version
"$UT" --help
```

Later examples spell the command `undoturn` for readability. If it is not on `PATH`, replace that word with `"$UT"` after setting `UT` as above. Install into a stable location before setting up hooks: hooks store the absolute CLI path. Keep `undoturn-service` beside the CLI.

### Build from source

From the repository root of an existing checkout, build and install the CLI helpers:

```sh
swift build -c release --product undoturn
swift build -c release --product undoturn-service
mkdir -p "$HOME/.local/bin"
cp .build/release/undoturn .build/release/undoturn-service \
  "$HOME/.local/bin/"
```

Use `"$HOME/.local/bin/undoturn"` directly, or add that folder to your shell's `PATH`. Building the CLI alone does not install the menu bar app or agent hooks.

With the app-build requirements above, package a local image:

```sh
sh scripts/package-app.sh .build/dist/UndoTurn-local.dmg
open .build/dist/UndoTurn-local.dmg
```

The package script also writes a `.sha256` file. For an app bundle without a DMG:

```sh
sh scripts/build-app.sh .build/UndoTurn-local.app
```

Both scripts refuse existing output paths. Choose a fresh name for a later build. They do not publish a release or notarize the app. With `UNDOTURN_SIGN_IDENTITY` set, they sign with that Developer ID identity and the hardened runtime. `scripts/release.sh` adds notarization.

## Your first undo and redo

This small drill uses **`run`, not `init`**. It creates a temporary project and an isolated history store. It does not install hooks, edit agent configuration, install a service, or change your usual history. No agent or API access is needed.

Copy the whole block into Terminal. Change only `UT` if your executable is elsewhere. The parentheses keep `UNDOTURN_HOME` local to this drill:

```sh
(
  UT="/Applications/UndoTurn.app/Contents/Helpers/undoturn"
  DEMO="$(mktemp -d /private/tmp/undoturn-demo.XXXXXX)" || exit
  export UNDOTURN_HOME="$DEMO/history"
  printf 'Demo folder: %s\n' "$DEMO"
  mkdir "$DEMO/project" || exit
  cd "$DEMO/project" || exit

  printf 'before\n' > note.txt
  "$UT" run -- /bin/sh -c 'printf "after\n" > note.txt' || exit
  "$UT" list || exit
  "$UT" show 1 || exit
  "$UT" diff 1 || exit

  "$UT" undo --dry-run || exit
  "$UT" undo || exit
  printf 'After undo: '; cat note.txt

  "$UT" redo || exit
  printf 'After redo: '; cat note.txt
  "$UT" list
)
```

Expected observations (not a recorded test transcript):

1. A turn `#1` with agent `run` appears; its diff changes `before` to `after`.
2. The preview reports that `note.txt` would be restored without changing it.
3. After undo, the file reads `before`; after redo, it reads `after`.
4. The final list marks `#1` as the current history position.

**If any step fails or the turn is missing, stop and use [Troubleshooting](#troubleshooting).** `run` returns the child command's exit code; successful execution of the child alone does not prove recording succeeded. Recording failures are reported on stderr.

The demo remains in the printed temporary folder so you can inspect it. The normal app does not show this isolated store. After the block finishes, you may move that exact demo folder to the Trash; it contains both the sample project and its disposable history. Do not delete your normal UndoTurn store as demo cleanup.

This proves neither agent-hook installation nor outside-project coverage. Validate your real agent separately below.

## Protect a project

First review [Before you record](#before-you-record), prepare the project's exclusions, and install the executable in its permanent location.

For a targeted CLI setup, choose the **one agent you use**. For example:

```sh
undoturn -C /absolute/path/to/project init --agent claude
undoturn doctor claude
```

Replace `claude` with a name from the table. `init` installs that account-wide integration, registers the resolved project, and stores a baseline. It cannot recover changes made before that baseline. Plain `undoturn init` installs **all ten** integrations, including settings for agents you may not use.

In the app, **Install Agent Hooks…** selects and registers a project and invokes the bundled CLI's untargeted `init`. It installs all supported agent integrations and does not require a shell command on `PATH`. Use the targeted CLI form if you want only one.

| Agent name | Product | Hook file installed or updated | Setup note |
|---|---|---|---|
| `claude` | Claude Code | `~/.claude/settings.json` | Restart or start a fresh session after setup. |
| `codex` | Codex CLI | `~/.codex/hooks.json` | Open Codex and run `/hooks` once to trust the UndoTurn hook. |
| `gemini` | Gemini CLI | `~/.gemini/settings.json` | Hooks must be enabled; `doctor gemini` reports a disabled setting. |
| `cursor` | Cursor CLI | `~/.cursor/hooks.json` | This integration targets Cursor CLI hook events. |
| `copilot` | Copilot CLI | `~/.copilot/hooks/undoturn.json` | UndoTurn-owned hook file. |
| `droid` | Factory Droid | `~/.factory/settings.json` | See the file-tool limitations below. |
| `devin` | Devin CLI | `~/.config/devin/config.json` | See the working-directory and payload limitations below. |
| `opencode` | OpenCode | `~/.config/opencode/plugins/undoturn.js` | Generated plugin; restart OpenCode after setup. |
| `pi` | Pi | `~/.pi/agent/extensions/undoturn.ts` | Generated extension; restart Pi after setup. |
| `omp` | Oh My Pi | `~/.omp/agent/extensions/undoturn.ts` | Generated extension; restart Oh My Pi, including Orca terminals. |

Settings integrations preserve unrelated settings and write a full backup before changing an existing settings file. The output names that backup. Copilot's dedicated hook file and generated extensions are UndoTurn-owned; installation and removal refuse foreign files rather than overwriting them. Do not delete an agent's whole settings file to repair an integration.

### Check the installation

Use **`doctor <agent>`**, not `doctor --agent <agent>`:

```sh
undoturn doctor claude
undoturn doctor claude --json
```

The agent argument narrows **hook configuration checks**. Store permissions, running turns, pause state, recent hook errors, and service status still concern the shared store. Plain `doctor` checks every integration; missing hooks for deliberately uninstalled agents are not a reason to install them all.

Each text check begins with `ok:`, `problem:`, or `hint:`. Recent hook errors follow, indented, and a final `service:` line gives the service status. Exit `1` means a problem was found. Read every message: a paused state is reported as information and is not by itself a failing health check. **Check Recording Setup…** in the app runs the untargeted doctor and is a configuration check, not a live recording test.

Recent hook failures remain in the 24-hour count after an upgrade or repair. Doctor includes up to the last five recent errors. Compare their timestamps with your new test rather than treating an old warning as a new failure.

### Validate your real agent

A passing isolated `run` drill or doctor result does not establish that a client loads and calls its hooks. After setup:

1. Choose a disposable project with no secrets, not an important working tree. Prepare its `.undoturnignore` before registration. Use `init --agent <name>` for it, or use an eligible folder that your already-installed hook may register automatically.
2. Restart the actual agent in that folder; complete any hook trust or native approval steps. Ask it to create a harmless file such as `hello.txt` containing `hello` and then stop.
3. Wait for the agent to settle. Run `undoturn -C /absolute/path/to/project list`, then `show <id>` and `diff <id>` for the newly listed turn. Confirm the file change is present and that no turn remains running.
4. Stop all other writers. Preview `undo --dry-run`, apply `undo`, then `redo`. Check the file after each operation and read all per-file results.
5. Run `doctor <agent>` again and distinguish new failures from historical ones. If cancellation matters to your workflow, test a harmless cancellation separately; a normal stop is not evidence about interruption handling.

Use the actual ID from `list`, not a number copied from this guide. Delete disposable histories through [Storage](#remove-the-history-of-one-project) when you no longer need them. Hook installation remains account-wide after deleting a test project.

### How UndoTurn finds the project

From the agent's working folder, UndoTurn chooses:

1. The deepest usable registered project containing it.
2. Otherwise, the nearest usable Git root containing it.
3. Otherwise, the working folder itself.

It refuses roots that are your home folder or its ancestors, contain the UndoTurn store, or are inside that store. A fallback folder directly inside your home, without its own Git root, is also refused. Use a dedicated project folder rather than your home, Desktop, or Library as a recording root.

Commands use the current folder unless you specify `-C`:

```sh
undoturn -C /absolute/path/to/project list
```

`-C` selects project resolution; it does not make hook settings project-local. Moving a project changes its path-based history identity. Use the exact stored root when managing the old history; do not assume a moved folder adopts it automatically.

### What each integration records

This is a **source-supported coverage matrix**, not an end-to-end certification of every client version. In-project scans observe eligible files at boundaries even when a pre-tool payload cannot identify an outside path. Installed clients, UI display, approval behavior, cancellation, and extension loading still require local validation.

| Integration | Recorded boundaries and mapped tools | Important limits |
|---|---|---|
| Claude Code | `UserPromptSubmit`, mapped `PreToolUse` shell/file tools, `Stop`; `Notification` supplies agent questions. | Esc, API failures, or a missing stop can leave a turn open. Reinstall older hooks to add `Notification`. |
| Codex CLI | `UserPromptSubmit`, mapped `PreToolUse` shell/patch tools, `Stop`, and `Interrupt`. | `/hooks` trust is required. The client's short stop-hook deadline can be insufficient for a large scan; consider the service. |
| Gemini CLI | `BeforeAgent`, `BeforeTool` for `run_shell_command`, and `AfterAgent`. | Hooks may be disabled. No resume command is provided by UndoTurn. Prompt-block display and interactive approvals need client validation. |
| Cursor CLI | `beforeSubmitPrompt`, `beforeShellExecution`, and `stop`. | Pre-tool outside-path discovery is from shell calls, not every editor operation. Prompt-block display needs client validation. |
| Copilot CLI | `userPromptSubmitted`, `preToolUse` for `bash`/`create`, and `agentStop`. | Stop provides a transcript path; final model/reply are read from it when available. Cancellation closure is not established. |
| Factory Droid | `UserPromptSubmit`, `PreToolUse` for `Execute`/`Create`/`Edit`/`ApplyPatch`, and `Stop`. | `Execute.command` and `Create.file_path` are documented inputs; Edit/ApplyPatch shapes are less certain. Documented cancellation uses `Notification`, not the installed `Stop` event. |
| Devin CLI | `UserPromptSubmit`, `PreToolUse` for `exec`/`write`/`edit`/`apply_patch`, and `Stop`. | Event and `exec.command` mapping is documentation-derived. No common documented `cwd`: the hook process's working folder is used. File-tool fields and cancellation are not fully documented; no resume command is provided. |
| OpenCode | Generated plugin forwards prompts and mapped mutating tools; final reply is cached and `Stop` is sent synchronously at `session.idle`. | Plugin loading and interactive behavior depend on the installed client. Cancellation closure is not established. Hook children have a 60-second bound. |
| Pi | Extension forwards start/tools, caches reply at `agent_end`, and sends `Stop` at `agent_settled`. | The settle event covers aborts. Hook children stop after 60 seconds; a timeout can leave recording incomplete. |
| Oh My Pi | Extension forwards start/tools and sends `Stop` at final `agent_end`; `willContinue: true` does not close the turn. | Hook children stop after 25 seconds, before the host's default 30-second handler deadline. A shorter custom host deadline can still interrupt recording. |

The Pi/Oh My Pi extension detects the running host, including when hosts share extension directories. After an upgrade, reinstall both `pi` and `omp` integrations if you use both, then restart both hosts.

### Pre-command checks

Claude Code, Codex, Gemini, and Cursor have targeted shell pre-command checks. Recognized root-wide deletion patterns are rejected. Recognized destructive Git metadata commands request native confirmation in Claude Code and Cursor; Codex and Gemini deny them because their supported pre-command protocol does not request confirmation. **`.git` is excluded and is not backed up.**

Other recognized risky commands create a checkpoint before execution; participants and outside watches continue across it. Empty checkpoints create no history node. Other integrations record turns but do not have these command guards.

This is bounded payload analysis, not a shell sandbox. Scripts, aliases, variables, changed command implementations, and unmapped routes can evade it. A successful hook does not auto-approve the tool or replace agent-native approval. Skipped or failed hooks, ignored files, paused recording, and files above the size limit do not gain a recovery guarantee.

## Upgrade

Upgrade without deleting your histories:

1. Stop agents and background writers. Finish or investigate running turns and interrupted recovery before replacing executables. Keep an independent copy of important project data and history before a pre-release upgrade.
2. Quit UndoTurn. Replace the app in its stable installed location, or replace **both** CLI and service helpers in their existing folder. Do not delete the history store or run `storage remove` as part of an upgrade.
3. Launch the installed app. Reinstall each integration you use from the **new CLI**, even if its path did not change; generated hooks and event registrations may have changed:

   ```sh
   undoturn -C /absolute/path/to/project init --agent claude
   undoturn doctor claude
   ```

4. If you use the service, run `undoturn service install` from the new CLI and check `undoturn service status`. Installation rewrites the launchd configuration and restarts the service. The service's executable and store paths must match this installation.
5. Restart your agents, complete Codex trust if requested, and repeat the [real-agent validation](#validate-your-real-agent). Check the app's **Open at Login** setting if the app moved.

Keep the same store location and `UNDOTURN_HOME` environment when you intend to retain the same histories. An environment variable set only in Terminal does not automatically configure a Finder-launched app or an agent launched elsewhere. A missing history view may mean the processes are using different stores, not that history was deleted.

Older hook failures remain visible until they age out of the 24-hour window. Retained history is not a promise that every future pre-release build supports every older format; read any migration instructions supplied with that build.

## See what the agent did

### List the turns

```sh
undoturn list
undoturn list --all
```

Illustrative rows:

```text
#2 *  2026-10-23 09:49  claude  +0 ~1 −0  Update the greeting
#1    2026-10-23 09:48  claude  +1 ~0 −0  Add a greeting [stable]
```

Rows show ID, time, agent, added (`+`), modified (`~`) and deleted (`−`) counts, prompt, and optional label. `*` marks the history position. `list` shows its ancestor path and the default redo path; `--all` includes other branches.

While a turn is open, `list` also shows its newest tool action and, for Claude Code, a reported question. A question clears at the next tool action or stop. The app's menu bar glyph gains a dot and it may send a notification. Notification permission and preview settings are controlled by macOS.

### Look at one turn

```sh
undoturn show 2
```

Inspect the parent, agent/session information, prompt, available model/reply, and file changes before selecting a recovery target. Paths outside the project are absolute. Shared intervals expose participants without attributing individual files to them.

### See the line diff

```sh
undoturn diff 2
undoturn diff 2 src/server.ts
```

This compares the turn's recorded Before and After versions; it is not a diff of all current unrecorded edits. Binary, oversized, or missing stored versions may have a summary instead of a line diff. `not stored` means UndoTurn cannot supply those bytes.

### Name a turn

```sh
undoturn label 1 "stable"
undoturn label 1 --clear
```

Labels help locate a useful state. They do not pin its objects against retention or turn it into an independent backup.

## Undo, redo and go to a turn

**First stop every writer.** Preview the operation, read its scope, then apply it and read the per-file report. Keep a separate copy of any unrecorded edit you cannot afford to lose. Recovery is file-version based, not a line-by-line merge.

### Choose the right recovery

Here `12` is an illustrative turn ID, **not a count**. Use IDs from your project's `list`.

| You want to… | Command | History effect |
|---|---|---|
| Undo the latest applied turn | `undoturn undo` | Moves to its parent. |
| Undo turn #12 **and every later applied turn** | `undoturn undo 12` | Moves to the state **before** #12; #12 must be an ancestor of the current position. |
| Reach the state **after** #12, including on another branch | `undoturn goto 12` | Undoes/redoes the route to that position. `goto 0` reaches the initial baseline. |
| Reverse only #12 while keeping later history | `undoturn revert 12` | Applies its nonconflicting inverse as a **new turn**; #12 must be on the applied history path. |
| Recover selected project files/folders, not move history | `undoturn restore config.json src/ --at 12` | Restores their state **before** #12. Add `--after` for the state after it; no new turn or head move. |
| Reapply undone history | `undoturn redo` or `undoturn redo 12` | Applies the next default child, or the descendant route up to #12. Use `goto` for an explicit other branch. |

All five recovery commands accept `--dry-run`. `--force` is deliberately not part of the normal workflow.

### Undo the last turn

```sh
undoturn undo --dry-run
undoturn undo
```

| Per-file result | Meaning |
|---|---|
| `restored: <path>` | Wrote the recorded version. |
| `removed: <path>` | Removed a path absent in the target version. |
| `kept: changed after the turn: <path>` | Current content or relevant mode differs from the expected recorded state. |
| `kept: not stored: <path>` | Required bytes are unavailable, for example above 50 MiB or removed by collection. |
| `kept: a parent folder is a symbolic link or a file: <path>` | UndoTurn refused to write through that parent. |
| `skipped: <path>` | Already matches the desired version; no write was needed. |

A report may contain several kinds of result. Check every affected file, not just the first restored line.

### Undo several turns

`undoturn undo 12` is **not** “undo twelve turns” or “undo only #12.” If the current path is #10 → #11 → #12 → #13, it moves to #11 and reverses #12 and #13 together, subject to per-file checks.

### Undo only one turn

```sh
undoturn revert 12 --dry-run
undoturn revert 12
```

A revert reverses only the selected turn's applicable file versions and records what was applied as a new turn. Later conflicting file versions are kept, not merged. If nothing can be applied, no new turn is created. Undoing the newly created revert can bring the original change back.

A shared interval has no per-file author attribution: revert cannot remove just one participant's work from it.

<a id="your-edits-are-safe"></a>

### Handle conflicts and exit 3

Without force, recovery keeps files that differ from the expected recorded state. This reduces accidental overwrites; it is not a promise that all of your edits are identifiable or recoverable. Edits made during an agent interval belong to that interval too.

**Exit `3` does not roll back the command.** For `undo`, `redo`, and `goto`, history can move to the target even when some files were kept or already matched. A partial revert can create its new turn. Thus the current `*` may no longer describe all working bytes.

After exit `3`:

1. Read the `kept:` and `skipped:` results. Already-matching skips can be harmless; missing stored bytes cannot be repaired with force.
2. Inspect the new history position with `list` and compare the relevant recorded versions with `show`/`diff`.
3. Preserve your current edits elsewhere before manual reconciliation. For specific recorded project versions, consider `restore --at <id>` with a preview.
4. Do not blindly repeat `undo` or add `--force`: the next undo may target a different turn because history already moved.

`--force` permits overwriting later edits and may abandon an open recording interval. Copies saved before a forced overwrite are not a new user-visible turn and may be garbage-collected. They are not a dependable rescue workflow. Force does not restore unavailable objects or make a non-directory/symlink parent safe to traverse.

### Redo

```sh
undoturn redo --dry-run
undoturn redo
```

With no ID, redo chooses the newest child of the current position. `redo 12` requires #12 to descend from the current position. Use `list --all` and `goto <id>` to choose a different branch explicitly.

### Undo from the agent prompt

In Claude Code, Codex, Gemini CLI, or Cursor, the complete prompt `undoturn undo` or `undoturn redo` is intercepted by the prompt hook: it runs locally and blocks submission to the model. A longer prompt such as `please undoturn undo` is not this shortcut. Stop other active work first.

A client can describe the intercepted prompt as “blocked by hook”; that message can contain the local recovery result rather than an error. Gemini and Cursor's interactive display still needs validation in your installed client. Stop hooks do not execute a command merely echoed in the original prompt. This shortcut has no force option.

### Go to any turn

```sh
undoturn goto 12 --dry-run
undoturn goto 12
```

This targets the state **after** #12, not before it. The route may cross branches and affect more than that one turn. Review its file scope. `goto 0` targets the baseline, not an empty project.

### Branches

Undoing and then recording new work creates a branch without deleting the other turns. List branches with `undoturn list --all`; choose a recorded state with `goto <id>`.

Branch visibility does not mean its file copies remain forever. Garbage collection can remove off-current-path objects; moving to an old branch may then report `kept: not stored`.

### Restore selected files without moving history

```sh
undoturn restore config.json src/ --at 12 --dry-run
undoturn restore config.json src/ --at 12
undoturn restore config.json --at 12 --after --dry-run
```

The default selects **Before #12**. `--after` selects **After #12**. A folder includes only recorded descendants. Other files, recorded turns, and the current history position remain unchanged.

Paths are relative to the **project root**, or absolute inside it, even when you use `-C` from a subfolder. Outside-project paths, `..` components, the project root itself, and unknown recorded paths are rejected. Put dash-prefixed names after `--`:

```sh
undoturn restore --at 12 -- --example.txt
```

This still checks conflicts against the current recorded state. An earlier selective restoration can itself count as an intervening edit, so switching Before/After is not necessarily an immediate toggle.

**`undo` does not directly reverse a selective restore.** Use another explicit `restore` for the recorded version you want; inspect and save current work before considering force. At the next recording boundary, selective-restore changes can be recorded as between-turn changes.

### Preview changes

```sh
undoturn undo --dry-run
undoturn restore config.json --at 12 --after --dry-run --json
```

Preview writes no project changes, overwritten-file copies, history record, or restoration journal. Text uses `would restore`, `would remove`, `would keep`, and `would skip`. JSON adds `"dryRun": true` while retaining its normal per-file outcome names.

Preview uses the normal exit meanings: `3` for any kept/skipped files, `4` for nothing to do. It cannot finish an active turn or interrupted restoration, even with `--force`. A preview is not a reservation; another writer can change the files before you apply it.

### Undo while the agent works

Normal recovery refuses an ordinary open turn; the app requires recording to stop. Stop all agents and background jobs, let the client emit its stop/settled event, and inspect `list` again. Pausing alone does not end a turn.

A cancellation or client failure can leave recording open. A later prompt from the same session interrupts its earlier participant, but does not close other active sessions. Do not start unrelated real work merely to clear the warning. Inspect the agent status, recorded interval, and diagnostics first.

The CLI's `--force` can mark active participants interrupted and finalize the interval before recovery. **This can abandon a shared interval too; it does not stop those processes.** The same flag also authorizes overwriting later edits. Use it only after confirming every writer is stopped, preserving current data separately, and deliberately accepting both effects. There is no separate routine “close stale turn safely” command.

The native app never force-closes recording and has no **Anyway** action. MCP has a narrower single-session checkpoint/continuation path described below; it is not permission to recover across other writers.

### Pause recording

```sh
undoturn pause
undoturn resume
```

Pause applies to **all projects in that store**. Hooks start no new turns and register no new projects while paused. A turn that began before the pause is still recorded when it stops. Pause neither stops agents nor erases existing data. Resume explicitly, then confirm the state in doctor or the menu bar app.

## The menu bar app

UndoTurn runs in the menu bar. It shows in the Dock only while its timeline or storage window is open. The app displays the store it was launched with. CLI helpers and installed agent hooks perform recording; quitting the UI does not uninstall hooks or the separate service, but notifications require the app to be running.

### The menu

Click the UndoTurn menu bar icon:

- Projects offer **Undo #N** and **Redo #N**, with a scope summary. Read the result and kept-file report after using them.
- Recent turns open their timeline details. The menu includes every project with a running turn and at most three other projects active in the last seven days. Others are in **More Projects**.
- **Open Timeline** (`⌘T`) opens the history browser.
- **Manage Storage…**, **Install Agent Hooks…**, and **Check Recording Setup…** manage data and setup. The last two invoke the bundled CLI, not a command found through `PATH`.
- **Install Command-Line Tools…** links both bundled tools into a folder you choose. See [Use the bundled CLI](#use-the-bundled-cli).
- **Pause Recording** becomes **Resume Recording** when paused.
- **Open at Login** controls the app's login item. It is separate from the optional launchd service.
- **About UndoTurn** and **Quit UndoTurn** are at the bottom.
- **Recorded hook failures (24h): N** is historical evidence of failures, not a current coverage indicator.

Menu shortcuts `⌘Z` and `⇧⌘Z` are assigned to the first listed eligible project for each action, not necessarily the project you have in mind. Redo skips a running project. Use a named project's action when the destination matters; native recovery still refuses active recording.

### The timeline

1. Select a project in **Projects**.
2. Select a turn in its history tree. Branches and undone turns remain visible.
3. Review its prompt, agent, time, label, changed files, and diff. Shared intervals list participant identities/statuses, not per-file authors.
4. Choose the recovery whose scope you intend:
   - **Undo This Turn** on the current turn moves to its parent.
   - **Go to #N** on another turn moves to the state **after** that turn; it is not a selective restore.
   - **Revert Just This Turn…** reverses an applied turn's nonconflicting changes into a new entry.
   - **Restore File or Folder…** offers **Before #N…** and **After #N…** for a selected project path, without moving history.
5. Review restored/removed/kept counts and expand **File Results** for individual outcomes. Kept files can leave working bytes different from the current history position.

Use the **⋯** menu for **Add Label…** / **Edit Label…**, **Copy Prompt**, and **Copy Resume Command** when available. Gemini and Devin have no UndoTurn resume command. Native recovery refuses active recording; disabled controls or a refusal explain why. There is no force-close option in the app.

The toolbar supplies Undo/Redo actions and the sidebar control. The timeline has a minimum content size of 960 × 440 points so its three columns stay usable.

### Alerts for mass deletes

While running, the app warns when a turn has at least 50 net deleted files, or at least three net deletions accounting for a quarter of the project's pre-turn files. Net deletions subtract created files; folders themselves do not count.

A notification may offer **Undo #N**. It is a history action, not a guarantee that every byte is recoverable. If the history position has changed, the app opens the relevant details rather than blindly undoing a different turn. macOS notification permission and previews control visibility. Agent-question notifications can expose text on the lock screen; review those system settings if needed.

## The background service

The optional service tracks changed paths so hooks can scan less of a large project. Without it, hooks scan the project at recording boundaries. If the service cannot supply trustworthy changes, recording falls back to a full scan; neither mode guarantees all files are recoverable.

```sh
undoturn service install
undoturn service status
```

Installation writes `~/Library/LaunchAgents/io.github.hugolopes45.undoturn.service.plist` with the selected service/store paths. launchd starts it at login and restarts it if it stops. Status is `not installed`, `installed, not running`, or `running`.

Keep the service helper beside the CLI. After replacing or moving helpers, run `service install` again from the intended CLI. To remove the launchd installation:

```sh
undoturn service uninstall
```

This removes the plist and asks launchd to unload the job. A successful exit does not confirm that the service process stopped. To confirm, look for `undoturn-service` in Activity Monitor.

The service also runs ordinary retention at startup when due and daily. This can reduce older branch recovery options; see below. Installing the service is separate from enabling the app's **Open at Login**.

## Storage and disk space

### What UndoTurn stores

The default store is `~/Library/Application Support/UndoTurn`. `UNDOTURN_HOME` selects another store for processes that inherit it; use an absolute folder outside the project. Keep the app, agents, CLI, and service aligned if you intentionally change stores.

Each project has `workspaces/<id>/` containing its root path, file versions in `objects/`, `history.log`, mirror, locks, and any restoration journal. Running-turn metadata includes the latest mapped tool action and agent question and is removed at the end of the turn. The history can contain prompts, labels, paths, timestamps, participants, session/transcript identifiers, model names, and final replies when available. Replies are capped at 4,096 UTF-8 bytes, with `…` marking truncation. The whole transcript is not copied into the store, although supported integrations may read it for metadata.

File versions use APFS clones where supported. Clones share blocks until content changes; plain copies are used when cloning is unsupported or crosses volumes. Files above **50 MiB** are not stored. A path can appear in history with unavailable bytes; its presence is not proof of a usable backup.

Inside the project, symbolic links are recorded by their target text, not by following them. Folders and their modes are recorded too: recovery can restore an empty deleted folder or remove a newly created one, but keeps a folder containing other files. Outside the project, watches record regular files only, not symbolic links or folder metadata.

**Redaction is limited to recognized text shapes.** Private-key blocks, known API-key prefixes, some Bearer/Basic credentials, URL passwords, and values under secret-like names can become `[secret]` in prompts, replies, commands, and agent questions. Unrecognized secrets, labels, paths, and file contents must not be assumed sanitized. Older raw history records are not rewritten merely because a newer viewer redacts displayed text. Rotating a credential does not remove its old file copies.

Store directories use POSIX mode `0700`; stored objects, logs, and journals use `0600`. These are not encryption or isolation from other processes running as you; ACLs are not audited. Treat a copy or backup of the store as sensitive project and conversation data. Agent-native network use and any content you explicitly expose through MCP remain subject to that client's behavior and permissions.

### Ignored files

UndoTurn reads nested `.gitignore` files and `.git/info/exclude`, but not Git's global excludes. **`.env*` files override Git ignores** so they can be recovered, unless the root `.undoturnignore` excludes them. The scanner always skips `.git`, `node_modules`, `.build`, `DerivedData`, and `Pods` directories.

Only the root `.undoturnignore` is used. Its supported Git-style subset includes comments, `!` negation, rooted/slashed and directory patterns, `*`, `?`, `**`, and escaped leading `#`/`!`. It does **not** interpret bracket character classes. A matched directory is not scanned; nested `.undoturnignore` files are not applied.

```gitignore
.env*
secrets/
*.pem
```

Adding exclusions does not retroactively erase earlier bytes. **Explicit `undoturn gc` can permanently purge versions referenced only by now-excluded paths**, even on the current history path. Purging waits while a turn is pending or a restoration journal exists; resolve that state and run it again. Copies also used by another recorded path remain. History keeps path/size metadata; diffs and recovery may then report `not stored`.

To remove an entire project's stored versions and history, use [Delete History… or `storage remove`](#remove-the-history-of-one-project). Do not promise secure erasure from APFS snapshots, Time Machine, or other backups when deleting UndoTurn data. The [threat model](THREAT-MODEL.md) explains the boundaries.

### Free disk space

```sh
undoturn gc
```

Collection removes unprotected stored versions older than 30 days and, when total object sizes across projects exceed 5 GiB, evicts the oldest eligible versions first. Versions needed by the current history path stay protected **except for explicit exclusion purges**. This is not a hard disk quota or a guarantee of 30-day recovery: the size budget can evict eligible versions sooner, and protected history can exceed the budget.

Ordinary retention runs at startup when due and daily while the service runs; otherwise collection is manual. Scheduled retention does not purge old copies just because `.undoturnignore` changed; explicit `gc` is required for that. Busy projects can be skipped and retried later. Incomplete service collections are logged in `<store>/service-errors.log` and do not advance the last-success timestamp. Collection holding a project lock can delay a hook.

Collected turns may still appear in history, but `redo` or `goto` can report `kept: not stored` for their missing objects. Labels do not prevent collection.

### See the space of each project

Choose **Manage Storage…** in the app, or use:

```sh
undoturn storage
undoturn storage list --json
```

Histories are shown largest first, with project root, turn count, last activity, and reclaimable bytes. Running turns and missing project folders are marked. Reclaimable bytes are an estimate, not the apparent total of file sizes: UndoTurn uses the size of unshared blocks where macOS reports it, and the allocated size otherwise.

JSON uses `schemaVersion: 1` and a `projects` array with `root`, `rootExists`, `reclaimableBytes`, `turnCount`, `lastActivity`, and `turnRunning`. `lastActivity` is Unix seconds or `null`. An empty store has an empty array.

### Remove the history of one project

In Storage, **Delete History…** removes a project's stored history; **Delete All History…** removes all histories. The app asks for confirmation and refuses a project with a running turn. Project files are not changed. With hooks still installed, a later agent turn can register the project again.

CLI deletion has **no confirmation prompt**. List first, then deliberately supply the intended root:

```sh
undoturn storage
undoturn storage remove /absolute/path/to/project
```

Use the exact listed root for a missing folder; an existing equivalent path, including `.`, is accepted. An active turn blocks deletion; exit `4` means no history exists for that root. JSON removal reports `root`, `schemaVersion`, and `exitReason` (`completed` or `nothingToDo`).

**Deleting history also deletes its interrupted restoration journal.** It does not finish that recovery: project files remain as the interruption left them. Resolve or investigate interrupted recovery before deleting its history.

Successful removal also retries cleanup from interrupted earlier deletions. A cleanup failure returns exit `1`, even if the requested history is already gone, names the remaining folder, and emits no JSON result. Inspect stderr; the next successful removal retries cleanup. Do not delete unrelated project files to resolve a history-store error.

Settings backups are separate: removing history does not remove the full `*.undoturn-backup-<time>` copies stored beside agent settings.

## Record any command

Wrap a foreground command, such as a generator, with `run`:

```sh
undoturn run -- /bin/sh -c 'printf "generated\n" > generated.txt'
```

No `init` is required; the first `run` registers an eligible project and records a baseline. It brackets the child process with start/stop recording, rather than installing account-wide hooks. It does not synthesize agent pre-tool events for the child, so do not expect automatic outside-project discovery or shell guards from this wrapper.

`run` returns the child's exit status. A failure to launch is `126`, or `127` if the command does not exist. Recording errors are printed to stderr without replacing the child's status. Always inspect history before assuming a successful command has a recoverable turn. Processes the command leaves running can write after the recorded interval has ended.

## Let an agent use UndoTurn

MCP access is optional and separate from recording hooks. Register the stdio server with a client you use; these examples change client configuration:

```sh
claude mcp add -s user undoturn -- \
  /Applications/UndoTurn.app/Contents/Helpers/undoturn mcp
codex mcp add undoturn -- \
  /Applications/UndoTurn.app/Contents/Helpers/undoturn mcp
```

Use the installed executable's actual path. The server resolves the project from its working directory. For a fixed project, register it with `-C /absolute/path/to/project` before `mcp`.

The tools are `list`, `diff`, `undo`, `redo`, `goto`, and `revert`. Ask explicitly, for example: “Use UndoTurn to inspect the last turn before deciding whether to undo it.” Read-only annotations are hints; changing-tool permissions and interactive approvals depend on the client. Interactive permission behavior is not certified here. Exposing MCP makes history content available to the agent; decide whether that is appropriate for the project.

Changing tools refuse shared recording. An eligible single-session turn can be checkpointed and resumed around a move under one lock; later supported tool calls, including outside-file changes, remain recorded in a marked continuation. An empty continuation creates no node and does not block immediate CLI undo/redo. Ordinary pending turns still block normal CLI moves.

MCP moves never use force to overwrite newer edits. Arguments that do not match a tool's input schema are rejected before the turn ends. An unknown or inapplicable turn ID can fail after the current recording boundary is written. Recovery of an interrupted MCP move can resume its recording continuation. Inspect per-file results: a kept/skipped result can accompany a changed history position just as in the CLI. The server implements protocol revisions `2025-11-25` and `2025-06-18`; it is not a network listener or a blanket authorization to modify files.

## Files outside the project

Supported **agent pre-tool hooks** can identify outside files before mapped mutating tools run, then include their changes in the interval. Whole-history recovery can restore recorded outside versions too; `show` lists their absolute paths. Selective `restore` is restricted to project paths.

Coverage is narrower than a full filesystem snapshot:

- Candidates must be under your home folder, `/Volumes`, or `/private/tmp`, and pass the store/project safety filters.
- Each tool call has a shared **5,000-entry collection budget**, including rejected walks. A path that does not fit is not partially recorded. Once exhausted, no new paths are watched for that call; existing watches remain. The next tool call has a fresh budget. Explicit write candidates take priority over precautionary scan operands.
- Shell paths come from parseable command text; scripts, variables, aliases, and unsupported syntax can hide them or produce extra candidates. Mapped file and patch inputs depend on the agent version and payload shape.
- Cursor supplies shell calls. Droid Edit/ApplyPatch and Devin file-tool input shapes are incompletely documented. In-project boundary scans do not fix a missed outside-file candidate.
- An outside path containing an unreadable folder may be rejected and logged. A warning is not evidence that its bytes were captured.

Read-only scans such as `ls`, `grep`, and `find` normally do not make operands candidates when their output reaches neither a file nor a program that can act on it. Operands remain precautionary candidates when output is written to a file, piped to a non-read-only consumer such as `xargs rm`, includes relevant expansions, or a reading-command name is redefined as a function/alias. `/dev/null` and the terminal are not output files for this rule. Redirections and recognized writing forms remain candidates. Too-long filesystem names, such as inline program text, are not usable paths.

For Oh My Pi, shell paths use the `bash` tool's own `cwd` without changing the registered project. Hashline edits include file sections and rename destinations; supported file-edit modes and `apply_patch` are mapped too. Archive/database write selectors identify their container, **not database side files**. Internal URLs such as `agent://` and `xd://` are not filesystem candidates.

Do not test this coverage with valuable outside files. Use a disposable scenario with the actual installed agent and inspect both stored versions before relying on recovery.

## Scripts: JSON and exit codes

`--json` is supported by `list`, `show`, `diff`, `undo`, `redo`, `goto`, `revert`, `restore`, `storage`, `gc`, and `doctor`:

```sh
undoturn list --json
undoturn show 12 --json
undoturn undo --dry-run --json
```

Successful command results and per-file reports go to stdout. Errors remain plain text on stderr, even with `--json`. Do not parse stderr as a JSON document or treat a nonempty JSON report as full recovery success.

Results use `schemaVersion: 1`. Recovery reports include `from`, `to`, `files` (each with `path` and `outcome`), and `exitReason`: `completed`, `keptOrSkipped`, or `nothingToDo`. Previews add `dryRun: true`. Compare the reported positions and inspect every outcome.

`show --json` includes available `model`, `reply`, and `started` fields; `started` is Unix seconds when the log supplies a start time. Older records may lack this optional conversation metadata. Full file versions and transcript data should not be inferred from a metadata field alone.

| Exit code | Meaning |
|---|---|
| `0` | Command completed; still read any informational state such as paused recording. |
| `1` | Error, or doctor found a problem. A filesystem error can follow partial recovery; inspect diagnostics before continuing. |
| `2` | Invalid command or arguments. |
| `3` | Recovery kept or skipped at least one file. **History may already have moved.** Applies to previews too. |
| `4` | Nothing to do, such as no next undo/redo or no history at a requested storage root. |

`run` is the exception: it returns the child status (or launch failure `126`/`127`), not a dedicated recording-success code. A caller should capture it before another shell command overwrites `$?`. MCP communicates through protocol/tool results rather than these process exit codes for each call.

## Troubleshooting

### Find the cause without forcing recovery

| Symptom | What to check or do |
|---|---|
| App opens but there is no Dock icon | Expected while the timeline and storage windows are closed: UndoTurn is a menu bar app. Reopen `/Applications/UndoTurn.app` to show the timeline. Make room near the notch or check menu bar-hiding utilities. |
| `undoturn: command not found` | Choose **Install Command-Line Tools…** and select a writable folder already on your shell's `PATH`. The app does not change `PATH`. Alternatively, use `/Applications/UndoTurn.app/Contents/Helpers/undoturn` by its quoted absolute path. |
| macOS blocks the app | Follow the [trusted-build Gatekeeper workflow](#gatekeeper-and-trusted-builds); do not disable security or remove quarantine indiscriminately. |
| No project or no turns | Check the intended store and `-C` folder, [refused roots](#how-undoturn-finds-the-project), pause state, and `doctor <agent>`. No-change turns produce no node. Verify the actual agent with a harmless edit. |
| `run` succeeded but nothing was recorded | Child success is not recording success. Read stderr, inspect history/store permissions and refused roots, and repeat only in the disposable drill after fixing the cause. |
| Codex records nothing | Run `/hooks` inside Codex to trust UndoTurn; restart the client and perform a harmless real-agent check. |
| Gemini hooks are disabled | If doctor asks for `hooksConfig.enabled: true` in `~/.gemini/settings.json`, review and change that setting without replacing other configuration, then restart Gemini. |
| Untargeted doctor complains about unused agents | Use `doctor <agent>`. Missing deliberately uninstalled integrations are expected; do not install every hook merely to make the global check green. |
| Hook missing or points to a non-executable path | Reinstall that integration with `init --agent <name>` from the intended installed CLI. Restart the agent. After an app move/upgrade, reinstall the service too if used. |
| Setup refuses a foreign hook file | UndoTurn will not overwrite it. Review the named dedicated file and resolve ownership deliberately; do not delete the agent's full configuration or unrelated extensions. |
| Doctor still shows recent failures after a fix | Read timestamps. The last 24 hours include old failures; compare with your latest harmless test. |
| Turn remains running or is older than an hour | Check for active/background sessions and missed stop/cancellation events. Stop writers; inspect the interval before any recovery. Pause does not close it; force is not a routine fix. |
| Recovery exits `3` | Read every kept/skipped result and `list` the new position. Follow [conflict handling](#handle-conflicts-and-exit-3); do not blindly repeat undo. |
| `nothing to undo` | The current history position is at the baseline. Use `list --all` to inspect other branches; it does not mean the project folder should be empty. |
| `kept: not stored` / diff says `not stored` | Bytes may exceed 50 MiB, be unreadable at recording, or have been collected/purged. Force cannot recreate them. Try Git or an independent backup. |
| Parent is now a symlink or regular file | UndoTurn refuses to traverse it, including with force. Inspect the path and intended layout manually; do not replace it blindly. |
| CLI sees history but the app does not | Check that both use the same store. Terminal-only `UNDOTURN_HOME` is not inherited by a normally Finder-launched app. The first-run drill deliberately uses a different store. |
| Service is missing or stopped | Check `service status`, helper placement, and the current installed paths. Reinstall with `service install` if you intend to use it. Recording otherwise falls back to scans. |

### Recover after an interruption

Stop all writers first. Keep the store and restoration journal intact. An applied restoration uses a durable journal; a later recovery-capable operation can finish an interrupted move under the project lock. **Even a normal history read such as `list` can enter recovery**, so do not treat it as a byte-preserving forensic snapshot of an interrupted operation.

A dry run refuses unfinished recovery because completing it would write. Resolve obvious causes such as a full disk or permissions problem, preserve the project/store separately if investigating, then use the intended normal command and inspect the result. If recovery still fails, collect redacted diagnostics before changing journal files. Do not delete the journal or history, run GC to “repair” it, or add force blindly. A filesystem mutation and its progress record are not atomic; concurrent writes and crashes still limit what can be established.

### Ask for help without sharing secrets

Collect a small, reproducible report from a disposable project when possible:

- macOS version, Mac architecture, UndoTurn `--version`, and whether it came from a local DMG or source build;
- the installed executable location, agent/version, and exact command or UI action used;
- exit status and relevant `doctor <agent>` output, including timestamps;
- the relevant kept/skipped lines, whether a turn is pending, and whether the service is running;
- a minimal description of expected versus observed files, without credentials or proprietary content.

Doctor includes recent entries from `<store>/hook-errors.log`. Service diagnostics use `<store>/service-errors.log`; extension failures may also appear in the agent terminal. Review these **before sharing**. Paths, prompts, replies, commands, labels, session IDs, diff contents, and notification screenshots can contain sensitive data even after automatic redaction.

Do not attach a whole history store, object directory, agent settings file, settings backup, or transcript by default. Copy only necessary excerpts and manually redact secrets and personal paths. Describe the local build's provenance separately from its version string; the source may report a development version. Use this repository's issue process for a redacted bug report, and its security-reporting instructions for a suspected vulnerability.

## Uninstall

Remove launch points **while the installed CLI is still available**. Uninstalling hooks alone does not delete history, stop the service, or disable the app's login item.

1. Stop agents and background writers. Finish or investigate running turns and interrupted recovery. If you are keeping history, preserve the complete store rather than selected object files.
2. Turn off **Open at Login** in UndoTurn's menu. If necessary, manage the UndoTurn entry in **System Settings → General → Login Items** (wording may vary).
3. Remove hooks and the optional service using the installed CLI:

   ```sh
   UT="/Applications/UndoTurn.app/Contents/Helpers/undoturn"
   "$UT" uninstall
   "$UT" service uninstall
   ```

   `uninstall --agent <name>` removes only one integration, not the entire setup. A successful `service uninstall` does not confirm that the service process stopped; check Activity Monitor for `undoturn-service`. Exit/restart agents that may still have a generated extension loaded. Remove any MCP registration you added through that client's own configuration controls; `undoturn uninstall` does not remove MCP server entries.
4. Decide whether to **keep history**. Keeping the store is the default; reinstalling binaries does not itself erase it. For deliberate deletion, use **Manage Storage… → Delete History… / Delete All History…**, or list and remove individual roots with `storage remove` while the CLI is present. Deletion is permanent from UndoTurn's perspective and does not change project files. Do not delete a journal whose interrupted recovery you still need.
5. Choose **Quit UndoTurn**, then move `/Applications/UndoTurn.app` to the Trash. Remove the `undoturn` and `undoturn-service` links from the folder you chose in **Install Command-Line Tools…**. Remove only CLI/service copies or links you installed; do not remove unrelated tools.

If you intentionally want to remove all remaining local data after those steps, inspect the known default store or your chosen custom store and move that exact folder to the Trash. This also removes diagnostic logs and residual store state. Do not confuse it with a project folder, and do not use broad recursive deletion commands copied from an example.

Full settings backups beside agent configuration can remain after uninstall and may contain sensitive settings. Review their names before removing them. Do not restore a whole old backup over newer unrelated agent configuration. Copies in Time Machine or other backups are outside UndoTurn's deletion controls.

## Limits

- UndoTurn is **not a sandbox or an independent backup**. Same-user processes can change the store; local disk failure can lose project and history together.
- Recording requires the relevant hook or wrapper to run successfully. Configuration checks and historical warnings are not proof of present or future recovery coverage.
- Recorded intervals are not authorship records. Your edits and overlapping sessions can share a turn; background changes are only observed at a later boundary.
- Ignore rules, missing stop events, unreadable/unstable files, the 50 MiB per-file limit, and retention can leave versions unavailable. `.git` is never backed up by the project scanner.
- Outside coverage depends on mapped payloads, allowed paths, parseable commands, and a bounded collection budget. It is not continuous filesystem monitoring or a full database backup.
- Command checks cover selected patterns in four integrations only. Agent-native approvals remain necessary; scripts and unmapped routes can evade detection.
- Conflict handling is per file, not a content merge. Kept files can coexist with an advanced history position. Force is destructive and does not solve missing bytes or live writers.
- Recovery journals progress, but cannot atomically couple every filesystem mutation to its progress record or prevent another process writing after a check.
- Known-shape redaction is not complete secret detection. File bytes remain exact, and deleting local history does not erase external backups or agent transcripts.
- Client versions, cancellation behavior, generated-plugin loading, and interactive approval/display paths need the [real-agent validation](#validate-your-real-agent), not assumptions from a successful CLI drill.

See [THREAT-MODEL.md](THREAT-MODEL.md) for the security boundaries.

## Command reference

This reference follows the current CLI's source-defined help. Use your installed executable's `--help` to identify differences in another build. IDs are decimal turn numbers without the display `#` prefix; `undo <id>` selects a turn, not a count.

```text
Usage: undoturn <command> [arguments...]

Commands:
  init [--agent <agent>]         Install agent hooks and register this workspace.
  uninstall [--agent <agent>]    Remove agent hooks without deleting history.
  hook <agent>                   Record one agent hook event from standard input.
  hook cursor <start|tool|stop>  Record one Cursor hook event from standard input.
  hook copilot <start|tool|stop>
                                 Record one Copilot hook event from standard input.
  run -- <command> [args...]     Record one turn around a child process.
  list [--all]                   List recorded turns.
  show <id>                      Show one turn and its changes.
  diff <id> [path…]              Show a turn's file diff.
  undo [id] [--force] [--dry-run]
                                 Undo a turn.
  redo [id] [--force] [--dry-run]
                                 Redo a turn.
  goto <id> [--force] [--dry-run]
                                 Move history to a turn.
  revert <id> [--force] [--dry-run]
                                 Undo only one turn and keep the turns after it.
  restore <path…> --at <id> [--after] [--force] [--dry-run]
                                 Restore files without moving history.
  label <id> <text|--clear>      Set or clear a turn label.
  pause                          Pause recording.
  resume                         Resume recording.
  gc                             Apply retention and exclusion rules to stored objects.
  doctor [agent]                 Check the UndoTurn installation.
  service install|uninstall|status
                                 Manage the launchd service.
  mcp                            Serve the history to an agent as MCP tools on stdio.
  storage [list]                 List stored histories and reclaimable bytes.
  storage remove <root>          Permanently delete one history, not its project files.

Agents: claude, codex, gemini, cursor, copilot, droid, devin, opencode, pi, omp

Global options:
  -C <dir>                       Resolve the workspace from <dir>.
  --json                         Print supported command output as JSON.
  -h, --help                     Show this help.
  --version                      Show the version.
```

Agents invoke `hook`; you normally do not run it yourself. `run` requires `--` before the child command. For `diff` and `restore` paths and for ordinary label text, `--` stops option parsing, so later dash-prefixed text is not read as an option. The label text `--clear` stays reserved, even after `--`. `storage remove` refuses a root that begins with `-`, even after `--`; give it the absolute root that `storage` lists. Only the commands listed in [JSON and exit codes](#scripts-json-and-exit-codes) support `--json`.
