# claude-code-statusline

Statusline for [Claude Code](https://claude.com/claude-code): context-window bar, 5h/7d/weekly rate-limit bars, staleness age.

![screenshot](screenshot.png)

## Requirements

- [`jq`](https://jqlang.org/) — Claude Code feeds the statusline script a JSON blob on stdin (model, context window, rate limits, etc.), and the script uses `jq` to pull fields out of it. Not optional; the script won't work without it.
  - macOS: `brew install jq`
  - Linux: `apt install jq` / `dnf install jq` / `pacman -S jq`
  - Windows: `winget install jqlang.jq`, `choco install jq`, or `scoop install jq` (the script itself is bash, so it runs via Git Bash or WSL — install jq wherever that bash runs)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/stelsoft/claude-code-statusline/main/statusline.sh -o ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```
