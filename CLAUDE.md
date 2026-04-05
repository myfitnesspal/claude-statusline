# claude-statusline

Custom statusline for Claude Code, displayed via the `StatuslineUpdate` hook.

## Key files
- `statusline.sh` — main statusline script, receives JSON on stdin, outputs one line
- `round-reset.sh` — called by `UserPromptSubmit` hook, marks round boundaries
- `install.sh` — installs hooks into Claude Code settings
- `test-statusline.sh` — tests feeding mock JSON and checking output
- `SPEC.md` — full specification with layout, design decisions, color thresholds, and available JSON fields

## Important context

### Context color thresholds
Total context is colored by absolute token count (Opus 4.6 MRCR retrieval benchmarks), NOT by compact percentage. Green < 120K, yellow 120-250K, orange 250-400K, red >= 400K. The compact percentage is still displayed as informational text.

### Two degradation axes
Token volume degrades retrieval (colored on the token count). User message count degrades multi-turn reliability (colored separately). These are independent — no interaction formula.

### Auto-compact threshold
The compact percentage shown is relative to the auto-compact trigger, NOT the raw context window.
Claude Code computes: `threshold = contextWindow - min(maxOutputTokens, 20000) - 13000`.
We approximate as `ctx_max - 33000` (configurable via `COMPACT_OVERHEAD` env var).

To re-derive if values change, search the binary:
```sh
strings $(which claude) | grep 'autocompact:.*threshold'
strings $(which claude) | grep -oE '.{0,200}IeH.{0,200}'
```
The minified function names (IeH, yU, PYH) will change between versions. Look for the pattern: `tokens=${...} threshold=${...} effectiveWindow=${...}`.

### Cache age replaces cache hit %
Shows time since last API call, predicting whether the ~5 minute prompt cache TTL has expired. Hidden when warm (< 3 minutes). Yellow 3-5 minutes (at risk), red > 5 minutes (cold).

### JSON payload
The statusline hook does NOT receive the `/context` category breakdown (system prompt, tools, messages, etc.). Only aggregate token counts are available. Dump the payload with:
```sh
echo "$input" | jq . > /tmp/claude-statusline-debug.json
```

## Development process
- Red/green TDD: write a failing test first, then implement the fix, then verify the test passes.
- Run tests with `bash test-statusline.sh`

## Style preferences
- Spaces between tokens and percentages (not colons or dots)
- Dot (·) separators between field groups within a section
- Pipe (|) separators between sections
- No labels — use position and color to convey meaning
- Hide fields when they're not actionable (e.g. cache age when warm)
- Model abbreviated: Opus->O, Sonnet->S, Haiku->H
- Token formatting drops trailing `.0` (200k not 200.0k)
- Bash parameter expansion preferred over sed/awk forks
- Run tests with `bash test-statusline.sh`
