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
Total context is colored by absolute token count (Opus 4.6 MRCR retrieval benchmarks), NOT by compact percentage. Green < 120K, yellow 120-250K, orange 250-400K, red >= 400K. Usage is drawn as a bar (`ctx_bar`) scaled to `usable_cap = min(compact_threshold, 400000)`; a full bar is that ceiling. Overflow adds a `▶` arrowhead fused to the bar (adds one cell), gated on the red zone (>= 400K) and strictly past the ceiling — small windows peg full with no marker (their ceiling is the compact threshold, never red). Bar color inherits the token-count color, so length (proximity to ceiling) and color (retrieval quality) are independent signals. Width knobs: `CTX_BAR_WIDTH` (default 8), `PACE_BAR_WIDTH` for the 7d meter (default 8).

### Auto-compact threshold
The percentage shown is relative to whichever limit binds first: the 400K retrieval quality ceiling (red threshold) or the auto-compact trigger — `min(compact_threshold, 400000)`.
Claude Code computes auto-compact threshold: `contextWindow - min(maxOutputTokens, 20000) - 13000`.
We approximate as `ctx_max - 33000` (configurable via `COMPACT_OVERHEAD` env var).
On a 200K window, compaction (~167K) is the binding constraint. On a 1M window, the 400K quality ceiling binds.

To re-derive if values change, search the binary:
```sh
strings $(which claude) | grep 'autocompact:.*threshold'
strings $(which claude) | grep -oE '.{0,200}IeH.{0,200}'
```
The minified function names (IeH, yU, PYH) will change between versions. Look for the pattern: `tokens=${...} threshold=${...} effectiveWindow=${...}`.

### Cache age replaces cache hit %
Shows idle time since the last API call, predicting whether the ~5 minute prompt cache TTL has expired. Hidden when warm (< 3 minutes). Yellow 3-5 minutes (at risk), red > 5 minutes (cold).

Measured from the last API activity, not the last render — `last_activity_ts` advances only when `total_api_duration_ms` grows between renders. This is deliberate: a render also fires at turn end, so a render-to-render timer counted a long busy turn as idle and flashed a stale indicator for one frame as the turn finished. A separate turn-*start* flash (the indicator clearing the instant a returning user's turn does its first API call) is handled by `cold_latch`: a turn that starts with an expired cache holds the cold indicator (red, frozen) for the whole turn. See SPEC.md "Cache age replaces cache hit percentage" and state format v5.

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
- Token formatting drops trailing `.0` (200k not 200.0k) and decimals at 3+ digits (202k not 202.1k)
- Bash parameter expansion preferred over sed/awk forks
- Run tests with `bash test-statusline.sh`
