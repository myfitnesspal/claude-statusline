# claude-statusline

A two-line status bar for [Claude Code](https://claude.ai/code) that shows context usage, token counts, and session cost.

![demo](demo.gif)

## What it shows

**Line 1 - Session overview:**
- Model name
- Working directory
- Context window usage (color-coded)
- Session cost

**Line 2 - Last round stats:**
- Total context tokens sent to the model
- New tokens added by your prompt (`+N`)
- Output tokens Claude generated

## Color coding

| Indicator | Green | Yellow | Red |
|-----------|-------|--------|-----|
| Context % | < 50% | 50-79% | 80%+ |
| Prompt size (+N) | < 1k tokens | 1-5k tokens | > 5k tokens |

Context % tells you when you're running out of room. Prompt size helps you learn which prompts are expensive (large pastes, file reads, etc.).

## Requirements

- [jq](https://jqlang.github.io/jq/) (`brew install jq`)
- Claude Code v2.1+

## Install

```bash
git clone https://github.com/myfitnesspal/claude-statusline.git ~/.claude-statusline
cd ~/.claude-statusline
./install.sh
```

The install script symlinks `statusline.sh` to `~/.claude/statusline.sh` and prints the settings.json snippet to add.

## Manual install

1. Copy `statusline.sh` to `~/.claude/statusline.sh`
2. Make it executable: `chmod +x ~/.claude/statusline.sh`
3. Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

## Customization

The script uses standard ANSI 256-color codes. Edit the color variables at the top of `statusline.sh`:

```bash
GREEN='\033[32m'       # context/prompt OK
YELLOW='\033[33m'      # context/prompt warning
RED='\033[31m'         # context/prompt critical
NORMAL='\033[38;5;245m' # labels and default text
```

Adjust thresholds in the `if` blocks to match your preferences.

## How it works

Claude Code pipes a JSON object with session data to the statusline script via stdin after each assistant response. The script extracts fields with `jq` and prints formatted output. See the [statusline docs](https://code.claude.com/docs/en/statusline) for all available fields.

## License

MIT
