# claude-code-statusline

A statusline for [Claude Code](https://claude.com/claude-code).

- Context-window bar with token count
- 5h / 7d / Fable limits live in the [herdr](https://herdr.dev) tab bar instead
  (`herdr/`): one line for the whole account, refreshed every ~15s from `/usage`.
  The statusline blocks that drew them are commented out, not deleted
- Average output speed in tokens/sec, next to the model name — session output
  tokens over the time the API spent generating them; blank until the first API
  call finishes, and starts over after `/clear` or a model switch
- `updated Xs ago` — when the 5h figure last actually moved
- Runs on Linux, macOS, and Windows (Git Bash or WSL) — just `bash`

![screenshot](screenshot.png)

## Requirements

Nothing to install — `bash` plus tools that already ship with the OS. UTF-8
terminal for the `▓▒░` bars.

- **Windows** — Git Bash or WSL. Not `cmd.exe` or PowerShell.
- **macOS** — reset countdown stays blank for a new session's first frames; BSD
  `date` can't parse the text form.

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

### herdr tab bar

```sh
cp herdr/claude-usage.sh herdr/sysload.sh ~/.config/herdr/ && chmod +x ~/.config/herdr/*.sh
```

Merge `herdr/config.toml` into `~/.config/herdr/config.toml`, then
`herdr server reload-config`.
