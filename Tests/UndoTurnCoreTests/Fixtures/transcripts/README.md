# Captured Claude Code transcript tails

Each file holds the last lines of a real Claude Code transcript, from the turn's prompt to the end of the file. Lines were re-serialized as compact JSON with key order kept.

- Agent: Claude Code 2.1.308, interactive session in a terminal.
- Capture date: 2026-10-23.
- Anonymization: the project folder path was replaced with `/Users/dev/project`; `sessionId` and `requestRef` were replaced with stable UUID-shaped values; the `command` of each `hook_success` attachment was replaced with `<hook command>`; the `msg_`, `req_` and `toolu_` identifiers were replaced with numbered placeholders, consistently across lines; thinking `signature` values were emptied; the `api-request` and `api-request-blob` lines were removed.

## `claude-esc-during-reply.jsonl`

- Prompt: "Use the Bash tool to run rm -r tests. Then, with no more tools, write a detailed 1500-word essay on the history of CSS layout."
- Esc was pressed after the Bash tool finished, while Claude wrote the reply.
- Observed: no `Stop` hook ran. The last `user` entry has the text `[Request interrupted by user]` (timestamp 2026-10-23T10:38:34.363Z; the prompt entry is 10:38:25.064Z).

## `claude-esc-during-tool.jsonl`

- Prompt: "Use the Bash tool to run exactly this foreground command, not in the background: python3 -c 'import time; time.sleep(60)' && touch after.txt"
- Esc was pressed while the command ran.
- Observed: no `Stop` hook ran. A `user` entry with a rejected `tool_result` is followed by a `user` entry with the text `[Request interrupted by user for tool use]` (timestamp 2026-10-23T10:45:13.048Z; the prompt entry is 10:44:57.369Z).
