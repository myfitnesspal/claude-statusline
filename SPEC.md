# Statusline Specification

## Layout

```
[model] | [context] | [rate limits] | [cost]
```

Example:
```
O4.6 200k | ↑15.4k 9.2% · 34k 17% | 2h14m 11% · 3d5h 12% | 19m +$0.05 $0.67
```

## Sections

### Section 1: Model identity
`O4.6 200k [location] [sa:status]`

- Model name abbreviated: Opus->O, Sonnet->S, Haiku->H
- Context window size appended (e.g. 200k, 1M) — detected from JSON `context_window.context_window_size`
- Location shown only when cwd differs from project root, or agent/worktree active
- Subagent governance status shown only when subagent hooks are installed

### Section 2: Context usage
`↑15.4k 9.2% · 34k 17% [cache%]`

- **↑ (round input delta)**: context growth since round start, computed as `ctx_tokens - round_start_ctx`. Only shown when > 0. Percentage is relative to compact threshold.
- **· separator**: dot separates per-round from session-total fields
- **Total context**: absolute token count and percentage of compact threshold
- **Cache hit %**: only shown when < 85% (yellow 50-84%, red < 50%). Hidden when healthy since it's almost always 99%+.
- Output tokens are NOT shown — they aren't in context yet (will fold into ↑ next call)

### Section 3: Rate limits
`2h14m 11% · 3d5h 12%`

- 5-hour and 7-day rate limit usage with time until reset
- Dot separator between the two limits
- Color-coded: green < 50%, yellow 50-79%, red >= 80%
- Only shown when rate limit data is available (Pro/Max subscribers)

### Section 4: Cost and timing
`19m +$0.05 $0.67`

- Cumulative API processing time (not wall clock — wall time is useless, you already know when you started)
- Per-round cost delta
- Session total cost

## Key Design Decisions

### All percentages are relative to compact threshold, not context window
The auto-compact threshold is the actionable limit. Showing `17%` of a 200K window is less useful than showing `20%` of the compaction trigger point. This is why we compute `compact_threshold = ctx_max - 33000`.

### Per-round input uses context delta, not accumulated fresh tokens
Earlier versions accumulated `cache_creation + input_tokens` across API calls. This was wrong — each API call resends the full conversation, so "fresh" tokens get double-counted. The correct metric is `ctx_tokens_now - ctx_tokens_at_round_start`.

### Round boundaries are set by UserPromptSubmit hook
`round-reset.sh` creates a marker file on each user prompt. The statusline reads the last known `ctx_tokens` from state as the baseline for the new round.

### Cache hit % is hidden when healthy
Cache hits are 99%+ during normal operation (prompt prefix caching). Only worth showing when something's wrong (after compaction, cache timeout, first call).

### Output tokens are not displayed
Output tokens from the current call aren't in `ctx_tokens` yet — they fold into input on the next call. Showing them separately was misleading because they don't "add up" with the context total. The ↑ delta already captures everything that grows the context.

## Color Thresholds

| Field | Green | Yellow | Red |
|-------|-------|--------|-----|
| Context % (of compact) | < 50% | 50-79% | >= 80% |
| Per-round input % | < 2% of compact | 2-5% | > 5% |
| Cache hit % | >= 85% (hidden) | 50-84% | < 50% |
| Rate limits | < 50% | 50-79% | >= 80% |

## Available JSON Fields

From the `StatuslineUpdate` hook payload (dumped via `jq . > /tmp/debug.json`):

```json
{
  "session_id": "...",
  "model": { "id": "claude-opus-4-6", "display_name": "Opus 4.6 (1M context)" },
  "workspace": { "current_dir": "...", "project_dir": "...", "added_dirs": [] },
  "cost": {
    "total_cost_usd": 6.26,
    "total_duration_ms": 19561785,
    "total_api_duration_ms": 1149486,
    "total_lines_added": 104,
    "total_lines_removed": 65
  },
  "context_window": {
    "total_input_tokens": 22852,
    "total_output_tokens": 42596,
    "context_window_size": 200000,
    "current_usage": {
      "input_tokens": 1,
      "output_tokens": 54,
      "cache_creation_input_tokens": 257,
      "cache_read_input_tokens": 108402
    },
    "used_percentage": 54,
    "remaining_percentage": 46
  },
  "exceeds_200k_tokens": false,
  "rate_limits": {
    "five_hour": { "used_percentage": 2, "resets_at": 1775260800 },
    "seven_day": { "used_percentage": 13, "resets_at": 1775437200 }
  }
}
```

### Fields NOT available (computed internally by `/context` command)
- Category breakdown (system prompt, tools, messages, skills, memory)
- Autocompact buffer size
- MCP tool token counts
- Per-category token estimates

## State Management

State file: `/tmp/claude-statusline-{session_id}`
Format: `round_start_ctx|last_ctx|round_start_cost`

New-round marker: `/tmp/claude-statusline-newround-{session_id}`
Created by `round-reset.sh` on `UserPromptSubmit` hook, consumed by statusline on next update.

## Auto-Compact Threshold Derivation

Reverse-engineered from Claude Code binary (see CLAUDE.md for re-derivation instructions):

```
threshold = contextWindow - min(maxOutputTokens, 20000) - 13000
```

Approximated as `ctx_max - 33000`. Override with `COMPACT_OVERHEAD` env var.
