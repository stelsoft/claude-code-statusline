# claude-code-statusline

A statusline for [Claude Code](https://claude.com/claude-code).

- Context-window usage bar with token count and staleness age
- 5h / 7d rate-limit bars with reset countdown
- Runs on Linux, macOS, and Windows (Git Bash or WSL) — just `bash`

![screenshot](screenshot.png)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/stelsoft/claude-code-statusline/main/statusline.sh -o ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```
