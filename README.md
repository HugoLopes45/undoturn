<div align="center">

<img src="docs/images/icon.svg" alt="" width="72">

# UndoTurn

**Every prompt is a save point. Undo for coding agents on macOS.**

[Quick start](#quick-start) &nbsp;·&nbsp; [User guide](docs/GUIDE.md) &nbsp;·&nbsp; [How it works](#how-it-works) &nbsp;·&nbsp; [FAQ](#faq)

<sub>One command. One click. Ten agent CLIs. No network, no account, no telemetry.</sub>

[![CI](https://github.com/HugoLopes45/undoturn/actions/workflows/ci.yml/badge.svg)](https://github.com/HugoLopes45/undoturn/actions/workflows/ci.yml)
![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Agents](https://img.shields.io/badge/agents-10%20CLIs-d97757)
![Network](https://img.shields.io/badge/network-none-38d591)
[![License](https://img.shields.io/badge/license-Apache%202.0-1084fe)](LICENSE)
![Status](https://img.shields.io/badge/status-pre--release-orange)
[![PRs](https://img.shields.io/badge/PRs-welcome-38d591)](CONTRIBUTING.md)

<br>

<a href="#quick-start">
  <img src="https://img.shields.io/badge/%E2%AC%87%EF%B8%8F%20%20Build%20from%20source-macOS%2014%2B-1084fe?style=for-the-badge&labelColor=070707" alt="Build UndoTurn from source for macOS 14 or later" height="40">
</a>

<sub>No published release yet &nbsp;·&nbsp; CLI, menu bar app and background service</sub>

<br>
<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/timeline-dark.png">
  <img alt="The UndoTurn timeline: each agent prompt is a turn, with its changed files and a line diff" src="docs/images/timeline-light.png" width="900">
</picture>

</div>

---

> **Status: pre-release.** Recording, undo and the menu bar app support Claude Code, Codex CLI, Gemini CLI, Cursor CLI, GitHub Copilot CLI, Factory Droid, Devin CLI, OpenCode, Pi and Oh My Pi. There is no published release yet: [build from source](#quick-start).

## Why

Your agent works for ten minutes. It touches 40 files. The build breaks, and you do not know which change caused it.

UndoTurn records your project before and after each agent turn. When a turn goes wrong, you go back to the moment before that prompt. You do not need to make a commit, use a stash or read a transcript.

```console
$ undoturn list
#2 *  2026-10-23 09:49  claude  +0 ~0 −5  Clean up the project and remove unus…
#1    2026-10-23 09:49  claude  +1 ~1 −0  Add a health check endpoint

$ undoturn undo
restored: src/health.ts
restored: src/items.ts
restored: src/routes.ts
restored: src/server.ts
restored: tests/items.test.ts
```

The agent "cleaned up" by deleting `src/` and `tests/`. One command brought back all five files.

- **No action from you.** Hooks record each prompt. You do not commit, stash or tag.
- **Shell commands too.** UndoTurn compares the files themselves, so `rm`, `mv` and `sed -i` are undone like any edit.
- **Local only.** Everything stays on your Mac. UndoTurn never writes to `.git` and never makes commits.

## The safety nets you have today

Coding agents are fast and confident. Sometimes they are wrong. They delete a folder during a "cleanup". They rewrite the one file that worked. They run `sed -i` across the whole repository.

| | Git | Claude Code checkpoints | Time Machine | **UndoTurn** |
|---|---|---|---|---|
| A save point at each prompt, with no action from you | No, you make the commits | Yes | No, it runs on a schedule | **Yes** |
| Undoes changes made by shell commands (`rm`, `mv`, `sed -i`) | Only for committed files | Only for files that Claude also edited with its own tools | Only up to the last backup | **Yes** |
| One history for all ten supported agent CLIs | Yes | Claude Code only | Yes | **Yes** |

Codex CLI removed its experimental `/undo` in January 2026 ([openai/codex#8804](https://github.com/openai/codex/issues/8804)). The request to bring it back ([openai/codex#9203](https://github.com/openai/codex/issues/9203)) is still open. UndoTurn gives undo back to Codex, and to all the other agents.

## Features

<table>
<tr>
<td width="50%" valign="top">

### ⏪ Undo the last turn

One command or one click puts back the files from before the prompt. Redo applies it again.

<img src="docs/images/undo-after.jpg" alt="The UndoTurn timeline after an undo: the turn that deleted five files is undone and turn 1 is current" width="100%">

</td>
<td width="50%" valign="top">

### 🌳 History is a tree

If you undo and send a new prompt, the old branch stays. **Go to #N** brings it back.

<img src="docs/images/branch-dark.png" alt="Turn 4, undone, on a side branch, with a Go to #4 button" width="100%">

</td>
</tr>
<tr>
<td width="50%" valign="top">

### ✂️ Revert one turn, restore one file

**Revert Just This Turn…** records an inverse and keeps the later turns. **Restore File or Folder…** selects a recorded version and does not move history.

<img src="docs/images/restore-dark.png" alt="Turn 1 selected, with Go to #1, Revert Just This Turn and Restore File or Folder" width="100%">

</td>
<td width="50%" valign="top">

### 📋 Undo from the menu bar

Undo and redo for each project, recent turns, storage, hook setup and Pause Recording, in one menu.

<img src="docs/images/menu-dark.png" alt="The UndoTurn menu: undo and redo per project, recent turns, Open Timeline, Manage Storage, Install Agent Hooks" width="100%">

</td>
</tr>
</table>

**Also in the box:**

- **Your edits are safe.** If you change a file after a turn and then undo that turn, UndoTurn keeps your version and tells you. Only `--force` overwrites it.
- **Shared intervals.** Prompt boundaries record changes. Overlapping sessions share an interval; intervening edits get separate between-turns nodes.
- **Files outside the project, too.** Paths from mapped file-tool calls and shell commands are candidates, subject to the safety limits in the [guide](docs/GUIDE.md#files-outside-the-project).
- **See exactly what changed.** `undoturn show` and `undoturn diff` in the terminal, or a timeline with line diffs in the menu bar app.
- **An alert on mass deletes.** If a turn removes 50 files or more, or at least 3 files and a quarter of the project, a notification offers an undo.
- **Crash recovery.** A durable journal resumes interrupted recovery and preserves completed operations. File changes and progress records are not atomic against other writers.
- **Targeted prevention.** Claude Code, Codex, Gemini and Cursor pre-tool hooks reject recognized broad deletions, gate destructive Git operations, and checkpoint recognized risky commands. This is not a sandbox; `.git` remains excluded.
- **Fast.** Existing measurement: each Claude/Codex hook adds about 20 ms with the background service and about 35 ms without it (median, 20,000-file project, M1 Max). This does not measure the new integrations, shared recording, or pre-command checkpoints.
- **Small on disk.** UndoTurn stores each file version as an APFS clone. A clone uses almost no space until the original file changes.
- **Agents can undo too.** `undoturn mcp` serves list, diff, undo, redo, goto and revert over MCP.

UndoTurn does not record ignored files, except `.env*` files, which it records unless `.undoturnignore` excludes them. It never records the folders `.git`, `node_modules`, `.build`, `DerivedData` and `Pods`. It does not store a copy of files larger than 50 MiB.

## Works with

<div align="center">

![Claude Code](https://img.shields.io/badge/Claude%20Code-d97757?logo=claude&logoColor=white)
![Codex CLI](https://img.shields.io/badge/Codex%20CLI-000000)
![Gemini CLI](https://img.shields.io/badge/Gemini%20CLI-1a73e8?logo=googlegemini&logoColor=white)
![Cursor CLI](https://img.shields.io/badge/Cursor%20CLI-111111)
![GitHub Copilot CLI](https://img.shields.io/badge/Copilot%20CLI-24292f?logo=githubcopilot&logoColor=white)
![Factory Droid](https://img.shields.io/badge/Factory%20Droid-1f2937)
![Devin CLI](https://img.shields.io/badge/Devin%20CLI-0f766e)
![OpenCode](https://img.shields.io/badge/OpenCode-2b2e3a)
![Pi](https://img.shields.io/badge/Pi-6d28d9)
![Oh My Pi](https://img.shields.io/badge/Oh%20My%20Pi-9333ea)

</div>

| Agent | Turns | Files outside the project | Hook file |
|---|---|---|---|
| Claude Code | Yes | Yes | `~/.claude/settings.json` |
| Codex CLI | Yes | Yes | `~/.codex/hooks.json`; run `/hooks` once to trust it |
| Gemini CLI | Yes | Yes (shell commands) | `~/.gemini/settings.json` |
| Cursor CLI | Yes | Yes (shell commands) | `~/.cursor/hooks.json` |
| GitHub Copilot CLI | Yes | Yes | `~/.copilot/hooks/undoturn.json` |
| Factory Droid | Yes | Yes | `~/.factory/settings.json` |
| Devin CLI | Yes | Yes | `~/.config/devin/config.json` |
| OpenCode | Yes | Yes | `~/.config/opencode/plugins/undoturn.js` |
| Pi | Yes | Yes | `~/.pi/agent/extensions/undoturn.ts` |
| Oh My Pi | Yes | Yes | `~/.omp/agent/extensions/undoturn.ts` |
| Any other command | With `undoturn run -- <command>` | No | None |

Agents with "Yes" for files outside the project also report each command and file edit. While a turn runs, the menu, the timeline and `undoturn list` show the newest one. Claude Code also reports when it waits for your permission or answer.

[`scripts/agent-drill.sh`](scripts/agent-drill.sh) includes a destructive undo/redo check for Claude Code and Codex CLI, plus a one-file recording check for Copilot, Droid, Devin, OpenCode, Pi and Oh My Pi. Each new-agent run uses a temporary UndoTurn store and temporary hook configuration where the CLI supports it.

## Quick start

Requirements: macOS 14 or later, and Xcode 26 or the Swift 6.2 toolchain to build.

```sh
git clone https://github.com/HugoLopes45/undoturn.git
cd undoturn
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/undoturn .build/release/undoturn-service ~/.local/bin/
```

Before `init`, read [Before you record](docs/GUIDE.md#before-you-record). In short: `init` installs hooks for all ten agents in your user account, and `.env*` files are recorded unless `.undoturnignore` excludes them. To install one agent only, use `init --agent <name>`. To try undo and redo first without hooks, follow [Your first undo and redo](docs/GUIDE.md#your-first-undo-and-redo).

Then run `init` once, in a project:

```console
$ cd ~/code/web-app
$ ~/.local/bin/undoturn init
claude: installed
codex: installed
Open Codex and run /hooks once to trust the UndoTurn hook.
gemini: installed
cursor: installed
copilot: installed
droid: installed
devin: installed
opencode: installed
pi: installed
omp: installed
registered workspace: /Users/you/code/web-app
```

That is all. The hooks are global: UndoTurn records each project where an agent works, except your home folder and a few other [refused folders](docs/GUIDE.md#how-undoturn-finds-the-project). Use your agent as usual. When a turn goes wrong:

```sh
undoturn undo
```

`undoturn doctor` checks the installation. The [user guide](docs/GUIDE.md) explains each command, the menu bar app and the background service.

### The menu bar app

Build a local installer with `sh scripts/package-app.sh .build/dist/UndoTurn-local.dmg`, then copy its app to `/Applications`. The package includes the CLI and service helpers. The app and bundled helpers are universal and ad-hoc signed; the DMG is unsigned. These local artifacts are not notarized or a public release. Signed, notarized artifacts come from `scripts/release.sh`. Use a fresh output path for another build. The CLI and app use the same engine and history.

On an empty timeline, choose **Install Agent Hooks…** to select a project. Setup uses the bundled CLI, not your shell's `PATH`.

- Undo and redo for each project from the menu bar. `⌘Z` and `⇧⌘Z` work in the timeline. In the menu, they act on the first listed project that can undo, or redo when no turn is running there.
- A timeline of prompts, labels, changed files and line diffs, with shared participant identities and recording status.
- The running interval: its newest command or file edit. When Claude Code waits for your answer, the menu bar icon shows a dot and a notification tells you.
- **Restore File or Folder…** shows preview counts and per-file results: what was restored, removed, or kept.
- Native recovery requires all recording to stop. There is no force-through action for an active interval.
- **Install Agent Hooks…**, **Check Recording Setup…**, recent hook-failure warnings, Pause Recording and Open at Login.

## How it works

```mermaid
sequenceDiagram
    participant You
    participant Agent
    participant UndoTurn
    participant Files as Project files
    You->>Agent: Prompt
    Agent->>UndoTurn: Hook: the turn starts
    UndoTurn->>Files: Record the files that changed since the last turn
    Agent->>Files: Edits, rm, mv, sed -i
    Agent->>UndoTurn: Hook: the turn ends
    UndoTurn->>Files: Record the result
    You->>UndoTurn: undoturn undo
    UndoTurn->>Files: Put back the files from before the turn
```

1. `undoturn init` installs the settings hooks, Copilot's UndoTurn-owned hook file, or generated Pi/OpenCode/Oh My Pi extension as appropriate; it registers the current project and stores its first state.
2. When you send a prompt, the hook records the files that changed since the last turn. UndoTurn reads `.gitignore`, but it still records `.env*` files, so that an undo can restore a deleted `.env`. `.undoturnignore` excludes them.
3. When the turn ends, the hook records the result. If the hook fails, the agent continues, and `undoturn doctor` reports the error.
4. `undoturn undo` writes back the files from before the turn. It uses a durable journal: after a crash, a recovery-capable operation such as `list` or a normal history move attempts to finish the interrupted recovery under the project lock. A preview refuses unfinished recovery. Deleting the history discards its journal without completing the recovery.

For large projects, `undoturn service install` starts an optional background service. It watches the file system with FSEvents, so that the hook reads only the files that changed.

| Part | Where | What it does |
|---|---|---|
| Engine | [`Sources/UndoTurnCore/`](Sources/UndoTurnCore/) | Scans and records files, keeps the history tree, plans and applies restores, writes the journal, installs agent hooks. |
| CLI | [`Sources/undoturn/`](Sources/undoturn/) | The `undoturn` command: hooks, history moves, storage, `doctor` and the MCP server. |
| Service | [`Sources/UndoTurnService/`](Sources/UndoTurnService/) | The optional background service that watches the file system with FSEvents. |
| Ledger | [`Sources/UndoTurnLedger/`](Sources/UndoTurnLedger/) | Builds the rows, counts and move previews that the app shows. |
| App | [`Sources/UndoTurnApp/`](Sources/UndoTurnApp/) | The menu bar app and the timeline window. |

[docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) tells what UndoTurn stores, where it stores it, and its limits.

## Commands

| Command | What it does |
|---|---|
| `undoturn init` | Add the hooks to all supported agents and register this project |
| `undoturn list` | Show the turns, newest first. `*` marks the current turn |
| `undoturn show 3` | Show the prompt, the agent and the changed files of turn 3 |
| `undoturn diff 3` | Show the line diff of turn 3 |
| `undoturn undo` | Put back the files from before the last turn |
| `undoturn redo` | Apply the undone turn again |
| `undoturn undo` as the prompt in Claude Code, Codex, Gemini CLI or Cursor | Undo without leaving the agent; the hook blocks the prompt |
| `undoturn goto 2` | Move the project to turn 2, also on another branch |
| `undoturn revert 2` | Undo only turn 2 and keep the turns after it |
| `undoturn restore config.json --at 2` | Restore one file as before turn 2 without moving history |
| `undoturn undo --dry-run` | Preview a move without applying changes |
| `undoturn label 2 "works"` | Give turn 2 a name |
| `undoturn pause` / `resume` | Stop and start recording |
| `undoturn run -- make build` | Record one turn around any command |
| `undoturn doctor` | Check the hooks, the store and the recent hook errors |
| `undoturn gc` | Apply age/size retention and explicitly purge versions used only by ignored paths |
| `undoturn service install` | Start the optional background service at login |
| `undoturn mcp` | Serve list, diff, undo, redo, goto and revert to agents over MCP |
| `undoturn storage [list]` | List stored histories and reclaimable space |
| `undoturn storage remove <root>` | Permanently delete one history, never its project files |
| `undoturn uninstall` | Remove the hooks. The history stays |

Add `--json` to `list`, `show`, `diff`, `undo`, `redo`, `goto`, `revert`, `restore`, `storage`, `gc` and `doctor` for scripts. The [user guide](docs/GUIDE.md) gives all the options and exit codes.

## FAQ

**Does UndoTurn replace Git?**
No. Git keeps the history that you decide to keep. UndoTurn protects the minutes between two commits, when an agent changes many files at once.

**Does my code leave my Mac?**
No. UndoTurn has no network code. The history is in `~/Library/Application Support/UndoTurn`, and only your user can read it.

**Does it store my secrets?**
Yes, unless you exclude them. UndoTurn records `.env*` files even when `.gitignore` ignores them, so that an undo can restore them. File copies are not redacted. They stay on your Mac with mode `0600`. To keep them out, list them in `.undoturnignore`. The [threat model](docs/THREAT-MODEL.md) tells how to remove versions already stored.

**How much disk space does it use?**
Each file version is an APFS clone, which uses almost no space until the original file changes. `undoturn gc` removes the stored versions of undone turns and other branches after 30 days. It also removes the oldest of them when the store is larger than 5 GiB. In the menu bar app, **Manage Storage…** estimates the space that deleting each project's history can free, and deletes one history or all of them.

**Does it slow down my agent?**
Earlier measurements on a 20,000-file project and an M1 Max: about 20 ms per Claude Code or Codex hook with the background service, and about 35 ms without it. A turn runs two hooks: one at the prompt and one at the stop. Newer integrations and shared recording have not been measured.

**What if I edit files while the agent works?**
A change made during a turn belongs to that turn. An undo of that turn also undoes your change. A change made after the turn is safe: undo keeps it.

**Is UndoTurn a sandbox or a backup?**
No. UndoTurn is a recovery tool. It can not stop an agent, and its store is on the same disk as your projects. Use Time Machine as well.

## Privacy

UndoTurn has no network code, no account and no telemetry. The history stays in `~/Library/Application Support/UndoTurn`, readable only by your user. UndoTurn never writes to `.git` and never makes commits.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md). Report security problems as described in [SECURITY.md](SECURITY.md).

## License

[Apache License 2.0](LICENSE)

The agent marks in the app use third-party path data. [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists the sources and their licenses. The trademarks belong to their owners.
