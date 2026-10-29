#!/bin/sh
# Runs one destructive, shell-only turn with a live agent in a throwaway project, then checks that
# `undoturn undo` restores every file byte for byte and that `undoturn redo` brings the turn back.
# A second turn asks the agent to call the undo tool of `undoturn mcp`, and the same checks run.
# The project has uncommitted work, an untracked file and an ignored `.env`, which git can not restore.
# Hooks load for this run only: your agent settings and your UndoTurn history stay unchanged.
# Pi and Oh My Pi load the extension that `undoturn init` installs into a temporary home.
# Copilot, Droid, Devin and OpenCode install the same way and only record one file-creation turn.
#
# Usage: scripts/agent-drill.sh claude|codex|copilot|droid|devin|opencode|pi|omp [undoturn binary]
set -eu

agent=${1:-}
case $agent in
  claude | codex | copilot | droid | devin | opencode | pi | omp) ;;
  *)
    echo "usage: $0 claude|codex|copilot|droid|devin|opencode|pi|omp [undoturn binary]" >&2
    exit 2
    ;;
esac
if [ "$#" -ge 2 ]; then
  bin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
else
  cd "$(dirname "$0")/.."
  swift build --product undoturn >/dev/null
  bin="$(swift build --show-bin-path)/undoturn"
fi
[ -x "$bin" ] || {
  echo "not an executable: $bin" >&2
  exit 2
}
case $bin in
  *[\'\"\\]*)
    echo "unsupported character in path: $bin" >&2
    exit 2
    ;;
esac
hook="'$bin' hook $agent"

root=$(mktemp -d "${TMPDIR:-/tmp}/undoturn-drill.XXXXXX")
trap 'rm -rf "$root"' EXIT
export UNDOTURN_HOME="$root/store"
project="$root/project"
mkdir -p "$project/src" "$project/tests"
cd "$project"
printf "import { greet } from './util'\nconsole.log(greet('world'))\n" >src/app.ts
printf "export function greet(name: string) { return 'hi ' + name }\n" >src/util.ts
printf "test('greet', () => {})\n" >tests/app.test.ts
printf '# demo\n' >README.md
printf '.env\n' >.gitignore
printf 'API_KEY=local-only\n' >.env
git init -q
git add -A
git -c user.name=drill -c user.email=drill@example.invalid commit -q -m seed
printf '// work in progress, not committed\n' >>src/app.ts
printf 'draft\n' >notes.md

digest() {
  find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16
}
fail() {
  echo "FAIL $agent: $1" >&2
  exit 1
}

case $agent in
  copilot | droid | devin | opencode)
    if [ "$agent" = devin ] && ! command -v devin >/dev/null 2>&1; then
      echo "SKIP devin: CLI not installed"
      exit 0
    fi
    config_home="$root/$agent-home"
    mkdir -p "$config_home"
    HOME="$config_home" "$bin" init --agent "$agent" >/dev/null
    prompt="Use your file-writing tool to create drill.txt containing exactly: drill. Do not use shell. Then reply with exactly: done."
    case $agent in
      copilot)
        COPILOT_HOME="$config_home/.copilot" copilot --trust-folder -C "$project" -p "$prompt" \
          --model auto --allow-all-tools --allow-all-paths
        ;;
      droid)
        droid exec --settings "$config_home/.factory/settings.json" --cwd "$project" \
          --auto low "$prompt"
        ;;
      devin)
        mkdir -p "$project/.devin"
        cp "$config_home/.config/devin/config.json" "$project/.devin/config.json"
        devin -p "$prompt"
        ;;
      opencode)
        OPENCODE_CONFIG_DIR="$config_home/.config/opencode" \
          opencode run --model opencode/beam-free --auto "$prompt"
        ;;
    esac
    [ -f "$project/drill.txt" ] || fail "agent did not create drill.txt"
    [ "$(cat "$project/drill.txt")" = drill ] || fail "agent did not write the requested file contents"
    shown=$("$bin" show 1)
    case $shown in
      *"A drill.txt"*) ;;
      *) fail "turn 1 did not record drill.txt" ;;
    esac
    case $shown in
      *"Reply: "*) ;;
      *) fail "turn 1 did not record the agent's reply" ;;
    esac
    "$bin" list
    printf '%s\n' "$shown"
    echo "PASS $agent: turn=1 files=drill.txt"
    exit 0
    ;;
esac
# The log proves that the agent called the tool. Codex forwards only allow-listed variables to MCP servers.
cat >"$root/mcp.sh" <<EOF
#!/bin/sh
tee -a '$root/mcp.log' | UNDOTURN_HOME='$UNDOTURN_HOME' '$bin' mcp
EOF
chmod +x "$root/mcp.sh"
case $agent in
  claude)
    handler="{\"hooks\": [{\"type\": \"command\", \"command\": \"$hook\"}]}"
    cat >"$root/settings.json" <<EOF
{
  "sandbox": {"enabled": true, "autoAllowBashIfSandboxed": true},
  "hooks": {
    "UserPromptSubmit": [$handler],
    "Stop": [$handler],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "$hook"}]}]
  }
}
EOF
    ;;
  codex)
    # `--ignore-user-config` still loads ~/.codex/hooks.json, and the trust bypass would run those hooks.
    mkdir "$root/codex"
    ln -s "${CODEX_HOME:-$HOME/.codex}/auth.json" "$root/codex/auth.json"
    ;;
  pi)
    HOME="$root/pi-home" "$bin" init --agent pi >/dev/null
    printf 'export default function (pi) {\n  pi.registerMcpServer("undoturn", { command: "%s", exposure: "direct" });\n}\n' \
      "$root/mcp.sh" >"$root/mcp.ts"
    ;;
  omp)
    HOME="$root/omp-home" "$bin" init --agent omp >/dev/null
    # omp runs follow-up turns (advisor, auto-continue) on its default role, not on --model.
    printf 'enabledModels:\n  - opencode-go/beam-free\nmodelRoles:\n  default: opencode-go/beam-free\n' \
      >"$root/omp-drill.yml"
    mkdir .omp
    printf '{"mcpServers": {"undoturn": {"command": "%s"}}}\n' "$root/mcp.sh" >.omp/mcp.json
    ;;
esac
run_turn() {
  case $agent in
    claude)
      claude -p --setting-sources project --settings "$root/settings.json" --strict-mcp-config \
        --mcp-config "{\"mcpServers\": {\"undoturn\": {\"command\": \"$root/mcp.sh\"}}}" \
        --model haiku --allowedTools mcp__undoturn__undo --disallowedTools Edit Write NotebookEdit \
        --no-session-persistence -- "$1"
      ;;
    codex)
      handler="[{hooks=[{type=\"command\",command=\"$hook\"}]}]"
      CODEX_HOME="$root/codex" codex exec --ephemeral --dangerously-bypass-hook-trust --skip-git-repo-check \
        --sandbox workspace-write -c approval_policy=never -C "$project" \
        -c "hooks.UserPromptSubmit=$handler" -c "hooks.Stop=$handler" \
        -c "hooks.PreToolUse=[{matcher=\"Bash\",hooks=[{type=\"command\",command=\"$hook\"}]}]" \
        -c "mcp_servers.undoturn.command=\"$root/mcp.sh\"" \
        -c 'mcp_servers.undoturn.tools.undo.approval_mode="approve"' \
        "$1"
      ;;
    pi)
      pi --print --no-session --no-extensions -e builtin:mcp -e "$root/mcp.ts" \
        -e "$root/pi-home/.pi/agent/extensions/undoturn.ts" --model opencode-go/beam-free "$1"
      ;;
    omp)
      omp --no-session --no-extensions --config "$root/omp-drill.yml" \
        -e "$root/omp-home/.omp/agent/extensions/undoturn.ts" \
        --model opencode-go/beam-free --auto-approve -p "$1"
      ;;
  esac
}

before=$(digest)
# `rm -r`, not `rm -rf`: Codex rejects `rm -rf` when approval_policy is never.
run_turn "Use only shell commands, no file editing tools. In the current folder, run exactly: rm -r tests && mv src/util.ts src/helpers.ts && sed -i '' 's/greet/welcome/g' src/app.ts && rm .env notes.md && printf 'broken\n' > README.md. Then reply done."

# A failed step stops the `&&` chain, and a partial turn would still pass the undo check.
{ [ ! -e tests ] && [ ! -e .env ] && [ ! -e notes.md ] && [ ! -e src/util.ts ] && [ -f src/helpers.ts ] &&
  grep -q welcome src/app.ts && [ "$(cat README.md)" = broken ]; } || fail "the agent did not run the whole command"
after=$(digest)
"$bin" list
"$bin" undo
[ "$(digest)" = "$before" ] || fail "undo did not restore the files from before the turn"
"$bin" redo >/dev/null
[ "$(digest)" = "$after" ] || fail "redo did not bring back the files of the turn"
run_turn "Call the undo tool of the undoturn MCP server once, with no arguments. Use no other tool. Then reply done."
grep -Eqs '"name": *"undo"' "$root/mcp.log" || fail "the agent did not call the undo tool of the MCP server"
[ "$(digest)" = "$before" ] || fail "the MCP undo tool did not restore the files from before the turn"
"$bin" redo >/dev/null
[ "$(digest)" = "$after" ] || fail "redo after the MCP undo did not bring back the files of the turn"
echo "PASS $agent: CLI and agent MCP undo restored all files ($before), redo brought the turn back ($after)"
