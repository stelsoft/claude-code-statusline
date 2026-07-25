# claude-code-statusline

A statusline for [Claude Code](https://claude.com/claude-code).

- Context-window bar with token count
- 5h / 7d rate-limit bars with reset countdown, straight from Claude Code's own
  rate-limit data — same numbers `/usage` shows
- Fable weekly bar, scraped from `/usage` in the background (nothing else carries
  it); hidden when that snapshot reports 0
- `updated Xs ago` — when the 5h figure last actually moved
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
