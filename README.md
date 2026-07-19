# claude-code-statusline

Statusline for [Claude Code](https://claude.com/claude-code): context-window bar, 5h/7d/weekly rate-limit bars, staleness age.

![screenshot](screenshot.png)

## Requirements

- `python3` — Claude Code feeds the statusline script a JSON blob on stdin (model, context window, rate limits, etc.), and the script uses python's stdlib `json` module to pull fields out of it. Preinstalled on macOS and most Linux distros; no third-party packages needed.
  - macOS: preinstalled (or `brew install python`)
  - Linux: usually preinstalled (`apt install python3` / `dnf install python3` / `pacman -S python` if not)
  - Windows: `winget install Python.Python.3` (the script itself is bash, so it runs via Git Bash or WSL — install python wherever that bash runs)

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
