# Statusline Specification

## Layout

```
[model] | [context] | [rate limits] | [cost]
```

Example:
```
O4.6 200k | 34k 17% · 12msg | 2h14m 11% · 3d5h 12% | 19m +$0.05 $0.67
```

With stale cache:
```
O4.6 200k | 34k 17% · 12msg · 7m | 2h14m 11% · 3d5h 12% | 19m +$0.05 $0.67
```

## Sections

### Section 1: Model identity
`O4.6 200k [location] [sa:status]`

- Model name abbreviated: Opus->O, Sonnet->S, Haiku->H
- Context window size appended (e.g. 200k, 1M) — detected from JSON `context_window.context_window_size`
- Location shown only when cwd differs from project root, or agent/worktree active
- Subagent governance status shown only when subagent hooks are installed

### Section 2: Context health
`34k 17% · 12msg · 7m`

- **Total context**: absolute token count colored by retrieval quality thresholds, plus compact threshold percentage (informational — tells you when auto-compact fires)
- **Message count**: user messages in session, colored by multi-turn degradation thresholds. Hidden when 0.
- **Cache age**: time since last API call, predicts whether prompt cache is warm. Hidden when < 3 minutes (cache warm). Shown yellow at 3-5 minutes (at risk), red > 5 minutes (cold, ~5 minute TTL expired).
- Output tokens are NOT shown — they aren't in context yet (will fold in on next call)

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

### Context colored by absolute token thresholds, not compact percentage
The compact percentage tells you when auto-compact fires, but says nothing about retrieval quality. Research (MRCR v2 benchmarks, practitioner needle tests) shows retrieval degrades at specific absolute token thresholds regardless of window size. A 200K session on a 1M window has the same retrieval quality as 200K on a 200K window. The compact percentage is still displayed as informational text.

### Two independent degradation axes
Token volume degrades retrieval accuracy (attention dilution, "lost in the middle" effect). User message count degrades reliability through a different mechanism (accumulated assumptions, wrong-turn lock-in). Research shows 39% average performance drop in multi-turn vs single-turn. These are displayed as separate colored indicators with no interaction formula.

### Per-round input delta removed
Per-round input size is not an independent degradation factor. A single turn loading 80K from file reads is healthier than four 20K turns of conversational refinement. What matters is cumulative total tokens and conversational structure, not per-turn volume.

### Cache age replaces cache hit percentage
A session-averaged cache hit percentage isn't actionable. What matters is whether the cache is warm right now, which predicts whether the next message will be fast and cheap or slow and expensive. The ~5 minute TTL means a simple timer since the last API call is the most predictive signal.

### Round boundaries are set by UserPromptSubmit hook
`round-reset.sh` creates a marker file on each user prompt. The statusline increments the message counter and resets round cost when it sees this marker.

### Output tokens are not displayed
Output tokens from the current call aren't in `ctx_tokens` yet — they fold into input on the next call.

## Color Thresholds

| Field | Green | Yellow | Orange | Red |
|-------|-------|--------|--------|-----|
| Context total (tokens) | < 120K | 120-250K | 250-400K | >= 400K |
| Message count | 0-9 | 10-17 | 18-23 | >= 24 |
| Cache age | < 3m (hidden) | 3-5m | — | > 5m |
| Rate limits | < 50% | 50-79% | — | >= 80% |

### Context threshold rationale
- **Green (< 120K)**: Peak retrieval. ~perfect MRCR. Where most Claude Code sessions land.
- **Yellow (120-250K)**: 93% MRCR. Proactive `/compact` with task-focused instructions worth considering.
- **Orange (250-400K)**: Single-needle retrieval still good, multi-needle starts degrading. Consider starting fresh if context is conversational rather than document-loaded.
- **Red (>= 400K)**: Partial retrieval. Details get hallucinated. Start fresh unless deep debugging where losing context is worse.

### Message count threshold rationale
Narrowing intervals (10, 8, 6) because multi-turn degradation compounds. Based on Microsoft/Salesforce study (Laban et al., May 2025) testing 15 LLMs across 200K+ conversations.

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
Format (v2): `2|round_start_cost|msg_count|last_ts`

- Version prefix `2` distinguishes from old format; old state files are reset on read.
- `last_ts` is the epoch timestamp of the last statusline render, used to compute cache age.

New-round marker: `/tmp/claude-statusline-newround-{session_id}`
Created by `round-reset.sh` on `UserPromptSubmit` hook, consumed by statusline on next update.

## Auto-Compact Threshold Derivation

Reverse-engineered from Claude Code binary (see CLAUDE.md for re-derivation instructions):

```
threshold = contextWindow - min(maxOutputTokens, 20000) - 13000
```

Approximated as `ctx_max - 33000`. Override with `COMPACT_OVERHEAD` env var.
