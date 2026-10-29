# UndoTurn user guide

UndoTurn saves your project files at every prompt you send to a coding agent. Each prompt is a **turn**. When a turn goes wrong, you undo it in the menu bar or with the `undoturn` command. Everything stays on your Mac.

UndoTurn is not a sandbox and not a backup. Keep using Git and Time Machine.

## Start here

1. [Install the app](#install).
2. [Try an undo and a redo](#your-first-undo-and-redo) on a test folder. This changes no agent settings.
3. [Connect your agent](#protect-a-project).
4. [Undo a turn](#undo-redo-and-go-to-a-turn) when you need to.

## Before you record

Read this before you connect an agent:

- **UndoTurn saves exact copies of your files, secrets included.** It also saves `.env*` files that Git ignores, so that an undo can restore them. To keep a file out, list it in a `.undoturnignore` file at the project root **before** the first turn.
- **Hooks apply to your whole user account.** After setup, a connected agent records every project where it works, except [refused folders](#how-undoturn-finds-the-project).
- **Your own edits during a turn belong to that turn.** If you undo the turn, you also undo them.
- **Stop the agent before you undo.** UndoTurn cannot stop a program that writes again after the undo.
- The history keeps prompts, file paths, labels and the agent's final reply. Known secret formats in this text are replaced with `[secret]`. Other secrets can stay. Notifications can show prompts and paths.

Example `.undoturnignore`:

```gitignore
.env*
secrets/
*.pem
```

This file changes only future recording. To remove copies that UndoTurn already saved, see [Ignored files](#ignored-files).

## Install

### Requirements

macOS 14 or later, on Apple silicon or Intel.

### Download a release

Download [UndoTurn for Mac](https://github.com/HugoLopes45/undoturn/releases/latest/download/UndoTurn.dmg). The app includes the command-line tools; you do not need a second download.

If you prefer the command line without the app, follow the [CLI installation steps](https://github.com/HugoLopes45/undoturn#quick-start).

### Install the app

1. Open `UndoTurn.dmg` and drag **UndoTurn.app** to **Applications**.
2. Eject the disk image. Open UndoTurn from **Applications**.
3. Find the UndoTurn icon in the menu bar. UndoTurn shows in the Dock only while its timeline or storage window is open.

If you cannot see the icon, the menu bar may be full or hidden by the notch. Open UndoTurn again from Applications: this opens the timeline.

### Use the command line

To use `undoturn` in Terminal:

1. In the UndoTurn menu, choose **Install Command-Line Tools…**.
2. Select a folder that is on your shell's `PATH`, for example `~/.local/bin`.

UndoTurn adds links named `undoturn` and `undoturn-service` in that folder. It never replaces an existing file and does not change your shell settings. Keep the app in Applications: the links point into it.

Without the links, use the full path:

```sh
/Applications/UndoTurn.app/Contents/Helpers/undoturn --help
```

## Your first undo and redo

This test uses a temporary folder and a separate history. It does not connect an agent and does not change your real history.

Copy the whole block into Terminal:

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

You should see:

1. Turn `#1` from `run`. Its diff changes `before` to `after`.
2. The preview says that `note.txt` would be restored.
3. `After undo: before`, then `After redo: after`.

If a step fails, see [Troubleshooting](#troubleshooting). When you are done, you can move the printed demo folder to the Trash.

## Protect a project

### Connect your agent

**In the app:** choose **Install Agent Hooks…** and select your project. This connects all ten supported agents.

**In Terminal:** connect only the agent you use:

```sh
undoturn -C /path/to/project init --agent claude
undoturn doctor claude
```

`init` registers the project and saves its current state. UndoTurn cannot undo changes made before that moment. `undoturn init` without `--agent` connects all ten agents.

| Agent name | Product | File that UndoTurn changes | After setup |
|---|---|---|---|
| `claude` | Claude Code | `~/.claude/settings.json` | Start a new session. |
| `codex` | Codex CLI | `~/.codex/hooks.json` | Open Codex and run `/hooks` once to trust the UndoTurn hook. |
| `gemini` | Gemini CLI | `~/.gemini/settings.json` | Hooks must be on. `doctor gemini` tells you if they are off. |
| `cursor` | Cursor CLI | `~/.cursor/hooks.json` | Start a new session. |
| `copilot` | Copilot CLI | `~/.copilot/hooks/undoturn.json` | Start a new session. |
| `droid` | Factory Droid | `~/.factory/settings.json` | Start a new session. |
| `devin` | Devin CLI | `~/.config/devin/config.json` | Start a new session. |
| `opencode` | OpenCode | `~/.config/opencode/plugins/undoturn.js` | Restart OpenCode. |
| `pi` | Pi | `~/.pi/agent/extensions/undoturn.ts` | Restart Pi. |
| `omp` | Oh My Pi | `~/.omp/agent/extensions/undoturn.ts` | Restart Oh My Pi. |

UndoTurn keeps your other settings. Before it changes an existing settings file, it saves a full backup beside it and prints the backup name.

### Check the installation

```sh
undoturn doctor claude
```

Write the agent name after `doctor`, not `--agent`. Each line starts with `ok:`, `problem:` or `hint:`. Exit code `1` means a problem. In the app, **Check Recording Setup…** runs the same check for all agents.

The check reads your configuration. To be sure that recording works, do a real test:

1. Open your agent in a test project. Ask it to create a file `hello.txt`.
2. Run `undoturn -C /path/to/project list`. The new turn must be in the list.
3. Run `undoturn undo`, then `undoturn redo`, and look at the file after each command.

### How UndoTurn finds the project

From the agent's working folder, UndoTurn uses the first match:

1. A project that you already registered and that contains the folder.
2. The nearest Git repository that contains the folder.
3. The folder itself.

UndoTurn refuses your home folder, any folder that contains your home folder, and the UndoTurn history folder. It also refuses a folder directly inside your home folder, such as Desktop or Documents, if it is not a Git repository. Use a dedicated project folder.

Commands use the current folder. To use another one, add `-C`:

```sh
undoturn -C /path/to/project list
```

If you move a project folder, UndoTurn starts a new history for the new path.

### Safety checks before commands

In Claude Code, Codex, Gemini CLI and Cursor CLI, UndoTurn checks shell commands before they run:

- It blocks commands that delete the whole project.
- Commands that can destroy Git data need your confirmation in Claude Code and Cursor. Codex and Gemini block them.
- Before other risky commands, it saves a checkpoint.

These checks recognize common forms only. A script or an alias can bypass them. UndoTurn never saves the `.git` folder.

## Upgrade

1. Stop your agents. Quit UndoTurn.
2. Replace the app in Applications. Do not delete the history.
3. Open UndoTurn. Connect your agents again, because the hooks can change between versions:

   ```sh
   undoturn -C /path/to/project init --agent claude
   ```

4. If you use the [background service](#the-background-service), run `undoturn service install` again.
5. Restart your agents. In Codex, run `/hooks` again if it asks.

## See what the agent did

### List the turns

```sh
undoturn list
undoturn list --all
```

```text
#2 *  2026-10-23 09:49  claude  +0 ~1 −0  Update the greeting
#1    2026-10-23 09:48  claude  +1 ~0 −0  Add a greeting [stable]
```

Each row shows the turn number, time, agent, files added (`+`), changed (`~`) and deleted (`−`), the prompt and an optional label. `*` marks the current position in the history. `--all` also shows other [branches](#branches).

While a turn runs, `list` shows the agent's latest action. The menu bar icon gets a dot when Claude Code asks you a question.

### Look at one turn

```sh
undoturn show 2
undoturn diff 2
undoturn diff 2 src/server.ts
```

`show` gives the prompt, the agent, the final reply and the changed files. `diff` shows the line changes of the turn. `not stored` means that UndoTurn has no copy of that file version.

### Name a turn

```sh
undoturn label 1 "stable"
undoturn label 1 --clear
```

A label helps you find a good state. It does not protect the turn from [cleanup](#free-disk-space).

## Undo, redo and go to a turn

**First stop your agents.** Then preview the action, apply it and read the result for each file.

### Choose the right recovery

`12` is a turn number from `undoturn list`, **not a count**.

| You want to… | Command |
|---|---|
| Undo the last turn | `undoturn undo` |
| Go back to before #12, and undo every later turn too | `undoturn undo 12` |
| Undo only #12 and keep the later turns | `undoturn revert 12` |
| Go to the state after #12, also on another branch | `undoturn goto 12` |
| Restore some files as they were before #12, without changing the history | `undoturn restore config.json src/ --at 12` |
| Redo an undone turn | `undoturn redo` |

Add `--dry-run` to any of these commands to see the result without changing files.

### Undo the last turn

```sh
undoturn undo --dry-run
undoturn undo
```

The result has one line per file:

| Result | Meaning |
|---|---|
| `restored: <path>` | UndoTurn wrote the saved version. |
| `removed: <path>` | The file did not exist in that version, so UndoTurn removed it. |
| `kept: changed after the turn: <path>` | Someone changed the file later. UndoTurn kept your version. |
| `kept: not stored: <path>` | UndoTurn has no copy, for example because the file is larger than 50 MiB. |
| `kept: a parent folder is a symbolic link or a file: <path>` | UndoTurn refused to write there. |
| `skipped: <path>` | The file already had the right content. |

### Undo several turns

`undoturn undo 12` does **not** mean "undo 12 turns". If the history is #10 → #11 → #12 → #13, it goes back to #11. That undoes #12 and #13 together.

### Undo only one turn

```sh
undoturn revert 12 --dry-run
undoturn revert 12
```

Revert undoes only the changes of #12 and saves the result as a new turn. If a later turn changed the same file, UndoTurn keeps the later version. To bring the change back, undo the new turn.

<a id="your-edits-are-safe"></a>

### Handle conflicts and exit 3

UndoTurn does not overwrite a file that changed after the turn. It keeps your version and reports `kept:`. The command then exits with code `3`.

**Exit code `3` does not cancel the command.** The history can already be at the new position. Do not repeat `undo`: it would undo another turn. Instead:

1. Read the `kept:` lines.
2. Run `undoturn list` to see where the history is now.
3. Save your own changes, then use `restore --at` to get the saved version of a file.

`--force` overwrites your later changes. Use it only after you save them somewhere else. It cannot bring back a file that UndoTurn did not store.

### Redo

```sh
undoturn redo --dry-run
undoturn redo
```

Redo applies the newest undone turn. `redo 12` goes forward to #12. To choose another branch, use `goto`.

### Undo from the agent prompt

In Claude Code, Codex, Gemini CLI and Cursor CLI, send exactly `undoturn undo` or `undoturn redo` as your prompt. UndoTurn runs it on your Mac and does not send it to the model. The agent can show it as "blocked by hook": that message contains the result.

### Go to any turn

```sh
undoturn goto 12 --dry-run
undoturn goto 12
```

This goes to the state **after** #12. It can undo and redo several turns on the way. `goto 0` goes back to the state before the first turn.

### Branches

If you undo a turn and the agent then makes a new change, the history splits into a new branch. The old turns are not deleted. Use `undoturn list --all` to see them and `goto` to go back to one. After [cleanup](#free-disk-space), an old branch can report `kept: not stored`.

### Restore selected files without moving history

```sh
undoturn restore config.json src/ --at 12 --dry-run
undoturn restore config.json src/ --at 12
undoturn restore config.json --at 12 --after
```

This restores the files as they were **before** #12, or **after** #12 with `--after`. Other files and the history do not change. Paths are relative to the project root. For a file name that starts with `-`, put it after `--`:

```sh
undoturn restore --at 12 -- --example.txt
```

`undo` does not cancel a restore. To go back, run another `restore`.

### Undo while the agent works

UndoTurn refuses to undo while a turn is running. Stop the agent and wait until it finishes, then try again. If a turn stays open after the agent stopped, see [Troubleshooting](#troubleshooting).

### Pause recording

```sh
undoturn pause
undoturn resume
```

Pause stops recording for all projects. A turn that started before the pause is still saved. You can also use **Pause Recording** in the menu.

## The menu bar app

UndoTurn runs in the menu bar. Your agents record turns even when the app is closed. Notifications need the app to run.

### The menu

Click the UndoTurn icon in the menu bar:

- Each project shows **Undo #N** and **Redo #N**, with a summary of the files that change. `⌘Z` and `⇧⌘Z` act on the first project in the list.
- Recent turns open in the timeline. The menu shows projects with a running turn and the three most recent projects of the last seven days. The others are in **More Projects**.
- **Open Timeline** (`⌘T`) opens the history window.
- **Manage Storage…** shows the space used by each project.
- **Install Agent Hooks…** connects your agents. **Check Recording Setup…** checks them.
- **Install Command-Line Tools…** adds `undoturn` to your Terminal. See [Use the command line](#use-the-command-line).
- **Pause Recording** stops recording until you choose **Resume Recording**.
- **Open at Login** starts the app when you log in.
- **Recorded hook failures (24h): N** appears when recording failed in the last 24 hours.

### The timeline

1. Select a project in **Projects**.
2. Select a turn. Undone turns and branches stay visible.
3. Read the prompt, the agent, the changed files and the diff.
4. Choose an action:
   - **Undo This Turn** undoes the current turn.
   - **Go to #N** goes to the state after that turn.
   - **Revert Just This Turn…** undoes only that turn and keeps the later ones.
   - **Restore File or Folder…** restores one path **Before #N** or **After #N**, without changing the history.
5. Read the result. **File Results** lists each file.

The **⋯** menu has **Add Label…**, **Copy Prompt** and **Copy Resume Command**. Gemini and Devin have no resume command. The app never forces an undo while a turn runs.

### Alerts for mass deletes

When the app runs, it warns you if a turn deletes 50 files or more. It also warns if a turn deletes at least 3 files and a quarter of the project. The notification can offer **Undo #N**.

## The background service

The service is optional. It watches which files change, so that large projects record faster. Without it, UndoTurn scans the project at each turn.

```sh
undoturn service install
undoturn service status
undoturn service uninstall
```

The service starts at login. It also cleans up old versions once a day. Install it again after you move or replace the app.

## Storage and disk space

### What UndoTurn stores

The history is in `~/Library/Application Support/UndoTurn`. Only your user account can read it. It contains:

- a copy of each file version, as an APFS clone that uses almost no space until the file changes;
- prompts, labels, file paths, times, agent names and final replies (up to 4 KB).

UndoTurn does not save files larger than 50 MiB, the `.git` folder, or the `node_modules`, `.build`, `DerivedData` and `Pods` folders. File contents are never redacted. Treat a copy of the history as sensitive data.

### Ignored files

UndoTurn skips files that your `.gitignore` files ignore, except `.env*` files. To skip more, add a `.undoturnignore` file at the project root. It uses the `.gitignore` format, except `[abc]` character classes. Only the root file counts.

New rules apply to future turns. To delete copies already saved for the files that you now ignore, run:

```sh
undoturn gc
```

This deletion is permanent, even for the current history. To delete the whole history of a project, see [Remove the history of one project](#remove-the-history-of-one-project).

### Free disk space

```sh
undoturn gc
```

`gc` deletes saved versions that are older than 30 days and not needed by the current history. If the history uses more than 5 GiB, it deletes the oldest of these versions first. The background service runs this cleanup every day. Labels do not protect a turn from cleanup.

### See the space of each project

Choose **Manage Storage…** in the menu, or run:

```sh
undoturn storage
```

Projects are listed from the largest. The size is an estimate of the space that deleting the history would free.

### Remove the history of one project

In **Manage Storage…**, choose **Delete History…** for one project, or **Delete All History…**. The app asks you to confirm. It does not delete a project while a turn runs. Your project files do not change.

In Terminal, there is **no confirmation**:

```sh
undoturn storage
undoturn storage remove /path/to/project
```

Use the exact path that `storage` shows. If the agent works in the project again, UndoTurn starts a new history.

## Record any command

To record a command that is not an agent, for example a code generator:

```sh
undoturn run -- npm run generate
```

`run` saves the files before and after the command, as one turn. It returns the exit code of the command.

## Let an agent use UndoTurn

Your agent can read and undo turns itself through MCP. This is optional. Add UndoTurn to your agent:

```sh
claude mcp add -s user undoturn -- \
  /Applications/UndoTurn.app/Contents/Helpers/undoturn mcp
codex mcp add undoturn -- \
  /Applications/UndoTurn.app/Contents/Helpers/undoturn mcp
```

The agent gets the tools `list`, `diff`, `undo`, `redo`, `goto` and `revert`. Ask it explicitly, for example: "Use UndoTurn to show the last turn before you undo it." The agent can then read your history. MCP actions never force an undo over your changes.

## Files outside the project

When an agent changes a file outside the project, for example in your home folder, UndoTurn can also save it. This works when the agent hook sees the path before the change: in a file tool, or in a simple shell command. UndoTurn saves only regular files under your home folder, `/Volumes` or `/private/tmp`.

An undo restores these files too. `undoturn show` lists them with their full path. `restore` works only inside the project. Do not count on this for important files outside the project.

## Scripts: JSON and exit codes

Add `--json` to `list`, `show`, `diff`, `undo`, `redo`, `goto`, `revert`, `restore`, `storage`, `gc` and `doctor`. Results go to standard output. Errors stay plain text on standard error.

| Exit code | Meaning |
|---|---|
| `0` | Done. |
| `1` | Error, or `doctor` found a problem. |
| `2` | Invalid command or option. |
| `3` | At least one file was kept or skipped. The history may have moved. |
| `4` | Nothing to do, for example nothing to undo. |

`run` returns the exit code of its command instead.

## Troubleshooting

| Problem | What to do |
|---|---|
| No icon in the Dock | This is normal: UndoTurn is a menu bar app. Open it again from Applications to see the timeline. |
| No icon in the menu bar | The menu bar may be full or hidden by the notch. Remove other icons, or open the app from Applications. |
| `undoturn: command not found` | Choose **Install Command-Line Tools…** and select a folder on your `PATH`, or use the full path `/Applications/UndoTurn.app/Contents/Helpers/undoturn`. |
| No turns appear | Run `undoturn doctor <agent>`. Check that recording is not paused and that the project is not a [refused folder](#how-undoturn-finds-the-project). A turn that changes no file does not appear. |
| Codex records nothing | Run `/hooks` in Codex to trust UndoTurn, then restart Codex. |
| Gemini hooks are off | Set `hooksConfig.enabled` to `true` in `~/.gemini/settings.json`, then restart Gemini. |
| `doctor` reports agents you do not use | Use `undoturn doctor <agent>` for your agent only. |
| A hook points to a missing file | You moved or replaced the app. Run `undoturn init --agent <name>` again and restart the agent. |
| `doctor` still shows old failures | It counts failures from the last 24 hours. Look at the times. |
| A turn stays "running" | Stop the agent completely. If the agent crashed, the turn stays open. `undo --force` closes it, but also overwrites your later changes: save them first. |
| Exit code `3` | Read the `kept:` lines. See [Handle conflicts and exit 3](#handle-conflicts-and-exit-3). Do not repeat `undo`. |
| `nothing to undo` | The history is at its start. Run `undoturn list --all` to see other branches. |
| `kept: not stored` | UndoTurn has no copy of that file: it was too large, unreadable or cleaned up. Use Git or your backup. |
| The app and Terminal show different histories | They use different history folders. `UNDOTURN_HOME` set in Terminal does not apply to the app. |
| An undo was interrupted | Stop your agents and free disk space if needed. Run `undoturn list` to finish the interrupted operation, then inspect the files before another recovery. Do not delete files in the history folder. |

To report a bug, give your macOS version, `undoturn --version`, the agent, the command and its output. Remove secrets and private paths first. Do not send your history folder.

## Uninstall

1. Stop your agents.
2. In the UndoTurn menu, turn off **Open at Login**.
3. Remove the hooks and the service:

   ```sh
   UT="/Applications/UndoTurn.app/Contents/Helpers/undoturn"
   "$UT" uninstall
   "$UT" service uninstall
   ```

   If you added UndoTurn to an agent with MCP, remove it in that agent.
4. To delete the history, use **Manage Storage… → Delete All History…**. To keep it, do nothing.
5. Choose **Quit UndoTurn**, then move UndoTurn to the Trash. Delete the `undoturn` and `undoturn-service` links that **Install Command-Line Tools…** created.

The settings backups beside your agent settings files (`*.undoturn-backup-<time>`) stay. Delete them yourself if you do not need them.

## Limits

- UndoTurn is not a sandbox and not a backup. The history is on the same disk as your projects.
- UndoTurn saves your files when a turn starts and ends, not continuously. Two agents that work at the same time share their turns.
- UndoTurn cannot restore a file that it did not store: ignored, larger than 50 MiB, or cleaned up.
- An undo replaces whole files. It does not merge lines.
- Secret redaction recognizes common formats only. File contents are never redacted.

The [threat model](THREAT-MODEL.md) explains the security limits.

## Command reference

This is the output of `undoturn --help`. IDs are turn numbers without the display `#` prefix; `undo <id>` selects a turn, not a count.

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

Agents run `hook` themselves; you do not need it. `run` needs `--` before the command. For a path or a label that starts with `-`, put it after `--`.
