# Captured agent hook fixtures

The JSON files contain the hook's stdin payload only. Identifiers and home-directory paths are anonymized; keys, value types, nulls, and absent fields are preserved.

## `claude-UserPromptSubmit.json`

- Agent: Claude Code 2.1.306
- Event: `UserPromptSubmit`
- Capture date: 2026-10-22
- Command: `/Users/dev/.local/bin/claude -p --settings <capture dir>/claude-settings.json --permission-mode acceptEdits "Create a file named hello.txt containing hi, then stop."`
- Anonymization: the home folder was replaced with `/Users/dev`; the capture project folder was replaced with `/Users/dev/project-claude`, also in the encoded folder name of `transcript_path`; `session_id` and `prompt_id` were replaced with stable UUID-shaped values; the prompt is the exact trivial prompt sent.

## `claude-Stop.json`

- Agent: Claude Code 2.1.306
- Event: `Stop`
- Capture date: 2026-10-22
- Command: `/Users/dev/.local/bin/claude -p --settings <capture dir>/claude-settings.json --permission-mode acceptEdits "Create a file named hello.txt containing hi, then stop."`
- Anonymization: the home folder was replaced with `/Users/dev`; the capture project folder was replaced with `/Users/dev/project-claude`, also in the encoded folder name of `transcript_path`; the session and prompt identifiers use the same UUID-shaped replacements as the start fixture; the prompt text in the paired run was the exact trivial prompt sent.

## `claude-Notification.json` and `claude-Notification-idle.json`

- Agent: Claude Code 2.1.309
- Event: `Notification`, with `notification_type` `permission_prompt` and `idle_prompt`
- Capture date: 2026-10-23
- Command: interactive `claude --settings <capture dir>/settings.json` in a pseudo-terminal, permission mode `default`, prompt "Run exactly this shell command with the Bash tool: touch x.txt  Then reply done."; the settings sent `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `Notification`, `PostToolUse` and `Stop` to a script that appended stdin to a log.
- Anonymization: the temporary project folder was replaced with `/Users/dev/project-claude`, also in the encoded folder names of `transcript_path` and `scratchpad_dir`; the home folder was replaced with `/Users/dev`; `session_id` and `prompt_id` were replaced with stable UUID-shaped values. Keys, key order and messages are unchanged.
- Observed order: `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `Notification` with `permission_prompt` about 6 seconds later, `PostToolUse`, `Stop`, then `Notification` with `idle_prompt` about 60 seconds after `Stop`.

## `codex-UserPromptSubmit.json` and `codex-Stop.json`

- Agent: Codex CLI 0.163.0
- Events: `UserPromptSubmit`, `Stop`
- Capture date: 2026-10-22
- Command: `codex exec --ignore-user-config --dangerously-bypass-hook-trust --skip-git-repo-check --sandbox workspace-write -C /private/tmp/undoturn-codex-capture/project -c 'hooks.UserPromptSubmit=[{hooks=[{type="command",command="<capture script> UserPromptSubmit"}]}]' -c 'hooks.Stop=[...]' "Create a file named hello.txt containing hi, then stop."`
- Codex wrote compact single-line JSON; the fixtures are pretty-printed with key order kept.
- Anonymization: the home folder was replaced with `/Users/dev`; `session_id` and `turn_id` were replaced with stable UUIDv7-shaped values, also inside `transcript_path`.
- Observed: both payloads carry the same `turn_id`; `cwd` is the realpath (`/private/tmp`, not `/tmp`); the hook process cwd equals `cwd`; empty stdout and exit 0 produced no warning.
- Project `.codex/hooks.json` hooks did not run: Codex loads the project layer only for trusted projects. User-layer hooks (`-c` overrides) ran. Per the Codex docs, a new non-managed hook needs one trust review before it runs; this was not tested.

## `codex-Interrupt.json`

- Agent: Codex CLI 0.163.0
- Event: `Interrupt`
- Capture date: 2026-10-23
- Command: the `codex-Stop.json` command with an `Interrupt` capture hook and the prompt "Run the shell command `sleep 90` and wait for it to finish, then reply done."; SIGINT was sent while `sleep 90` ran.
- Anonymization: the home folder was replaced with `/Users/dev`; `session_id` and `turn_id` were replaced with stable UUIDv7-shaped values, also inside `transcript_path`.
- Observed: Codex printed "turn interrupted", ran the `Interrupt` hook and sent no `Stop`.
## `copilot-userPromptSubmitted.json`, `copilot-preToolUse-*.json`, and `copilot-agentStop.json`

- Agent: GitHub Copilot CLI, version reported as 1.0.103; the capture command was run with `/opt/homebrew/bin/copilot`.
- Events: `userPromptSubmitted`, `preToolUse` (both `bash` and `create` tools), `agentStop`.
- Capture date: 2026-10-23.
- Command: `copilot --trust-folder -C /tmp/cap/project -p "Run the shell command \`echo hi > shell.txt\`, then create a file named hello.txt containing hi with your file tool, then reply with exactly: done" --allow-all-tools --allow-all-paths`
- Hook config: invocation user's `COPILOT_HOME=/tmp/cap/copilot`; hook file `/tmp/cap/copilot/hooks/capture.json`. Start and pre-tool handlers ran `sleep 3` before copying stdin to the capture log.
- Anonymization: `/tmp/cap` was replaced with `/tmp/cap` (disposable path retained); `sessionId` was replaced with a stable UUID-shaped value; timestamps and all other payload fields/types were retained.
- Follow-up live probe: `assistant.message` transcript records have top-level `type` and `data`; the final answer is `data.content` when `data.phase == "final_answer"`, with `data.model` and `data.providerId`. The Stop hook's own payload does not include reply/model. No transcript fixture is included; decoding is covered by a synthetic transcript test.

## Pi and Oh My Pi live extension captures

- `pi-UserPromptSubmit.json`: Pi 1.4.0, captured 2026-10-23 with `pi --print --no-session --no-extensions --model opencode-go/beam-free -e /tmp/probe/pi/undoturn.ts` and the trivial shell/file prompt; session ID normalized.
- `pi-PreToolUse-bash.json`: Pi 1.4.0, captured 2026-10-23 by the same live extension run; native bash input retained, session ID normalized.
- `pi-PreToolUse-write.json`: Pi 1.4.0, captured 2026-10-23 by the same live extension run; native write input retained, session ID normalized.
- `pi-Stop.json`: Pi 1.4.0, captured 2026-10-23 by the same live extension run; final assistant text and model retained, session ID normalized.
- `omp-UserPromptSubmit.json`: Oh My Pi 18.12.6, captured 2026-10-23 with `omp --no-session --no-extensions -e /tmp/probe/omp/undoturn.ts --model opencode-go/beam-free --auto-approve -p` and the trivial shell/file prompt; session ID normalized.
- `omp-PreToolUse-bash.json`: Oh My Pi 18.12.6, captured 2026-10-23 by the same live extension run; native bash input retained, session ID normalized.
- `omp-PreToolUse-write.json`: Oh My Pi 18.12.6, captured 2026-10-23 by the same live extension run; native write input retained, session ID normalized.
- `omp-Stop-intermediate.json`: Oh My Pi 18.12.6, captured 2026-10-23 by the same live extension run; preserves an earlier Stop callback with no reply field, session ID normalized.
- `omp-Stop.json`: Oh My Pi 18.12.6, captured 2026-10-23 by the same live extension run; final assistant text and model retained, session ID normalized.

OMP's shell redirection attempt was blocked by the harness, so its run created `hello.txt` but not `shell.txt`; two `agent_end` Stop callbacks were observed.

## OpenCode 1.19.4 live plugin captures

- `opencode-UserPromptSubmit.json`: OpenCode 1.19.4, captured 2026-10-23 with the project-local `.opencode/plugins/undoturn.js` and `opencode run --model opencode/beam-free --auto`; session ID normalized, native prompt text retained.
- `opencode-PreToolUse-bash.json`: OpenCode 1.19.4, captured by the same live plugin run; native bash args retained, session ID normalized.
- `opencode-PreToolUse-write.json`: OpenCode 1.19.4, captured by the same live plugin run; native write args retained, session ID normalized.
- `opencode-Stop.json`: exact canonical `Stop` payload received by a temporary UndoTurn-hook stub during a live `message.updated` experiment; session ID normalized.

- A temporary synchronous-send experiment gated on the completed assistant `message.updated`, cached text from `message.part.updated`, and deleted the active marker before sending; it produced one Stop and no later Stop from session-idle/status events. The hook took 3.06 s. This proves only that completion-event variant.
- The checked-in template caches the completed assistant response and synchronously sends Stop once at `session.idle`; this exact branch has not been live-tested, and TUI behavior is unverified. The asynchronous and detached variants did not deliver Stop before `opencode run` exited. Interrupted, repeated-prompt and multi-part-text behavior remain unproven.

## Devin docs-derived hook payloads

- `devin-doc-UserPromptSubmit.json`, `devin-doc-PreToolUse-exec.json`, and `devin-doc-Stop.json` are documentation-derived examples, not live captures. They use the exact documented common fields (`session_id`, `prompt_id`), event names, prompt field, `exec` tool name and `tool_input.command`, and Stop field from [Devin CLI lifecycle hooks](https://docs.devin.ai/cli/extensibility/hooks/lifecycle-hooks).
- Devin's cited hook docs do not document a common `cwd`; the tests supply the CLI's actual working directory as the fallback.
- These fixtures do not establish the input shapes for Devin's `write`, `edit`, or `apply_patch` tools.
