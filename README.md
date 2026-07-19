# claude-code-statusline

Statusline for [Claude Code](https://claude.com/claude-code): context-window bar, 5h/7d/weekly rate-limit bars, staleness age.

![screenshot](screenshot.png)

## Requirements

None beyond `bash` itself — no `jq`, no `python`. Claude Code feeds the script a JSON blob on stdin (model, context window, rate limits, etc.) and it parses the fields with pure bash string operations. Runs out of the box on Linux, macOS, and Windows (via Git Bash or WSL), including the stock macOS bash 3.2 and BSD `date`/`stat`.

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
