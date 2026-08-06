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
`O4.6 200k [auth] [location] [sa:status]`

- Model name abbreviated: Opus->O, Sonnet->S, Haiku->H
- Context window size appended (e.g. 200k, 1M) — detected from JSON `context_window.context_window_size`
- Auth/plan mode as a single uncolored letter. `K` = `ANTHROPIC_API_KEY` in the process env (pay-per-token API billing). Otherwise the letter reflects `oauthAccount.organizationType` in `~/.claude.json`: `M` = `claude_max`, `P` = `claude_pro`, `T` = `claude_team`, `E` = `claude_enterprise`, and `A` = any other non-empty org type (unknown/fallback). Hidden when logged out with no key. The env var wins because Claude Code prefers an approved `ANTHROPIC_API_KEY` over the stored OAuth login; a session where the key is present but was declined at the approval prompt shows `K` anyway (accepted inaccuracy — the payload carries no auth field). `CLAUDE_JSON_PATH` overrides the credential file location for tests.
- Location shown only when cwd differs from project root, or agent/worktree active
- Subagent governance status shown only when subagent hooks are installed

### Section 2: Context health
`34k ██████░░░░ · 7m`

- **Total context**: absolute token count colored by retrieval quality thresholds, followed by a **usage bar**. The bar fills to `usable_cap = min(compact_threshold, 400000)` — a full bar is that ceiling (the 400K retrieval red line, or the auto-compact threshold when it binds first). Past the ceiling the bar pegs full and gains a `▸` overflow marker. The bar inherits the token-count color (green < 120K, yellow 120-250K, orange 250-400K, red >= 400K), so on a small window a full/overflow bar can be non-red (the ceiling is the compact threshold, below 400K). Width is `CTX_BAR_WIDTH` cells (default 10).
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
The compact percentage tells you when auto-compact fires, but says nothing about retrieval quality. Research (MRCR v2 benchmarks, practitioner needle tests) shows retrieval degrades at specific absolute token thresholds regardless of window size. A 200K session on a 1M window has the same retrieval quality as 200K on a 200K window. The usage is shown as a bar (see below); its color, keyed to absolute token count, carries the retrieval-quality signal while the bar length carries the how-close-to-the-ceiling signal.

### Context usage shown as a bar
The usage percentage is drawn as a fixed-width bar rather than a number. A number invites arithmetic ("42% of what?"); a bar shows headroom at a glance. The bar scales to `usable_cap = min(compact_threshold, 400000)` so a full bar always means "at the wall that binds first" — the 400K retrieval red line on a large window, or the auto-compact threshold on a small one. Overflow past the ceiling pegs the bar full and adds a `▸` marker so the over-limit state stays visible instead of saturating silently. Color is decoupled from length (absolute token thresholds), so the two degradation signals — retrieval quality and proximity to the ceiling — read independently. Bar cells are set by `CTX_BAR_WIDTH` (default 10); the 7d throttle meter has its own `PACE_BAR_WIDTH` (default 5) so the two bars can be tuned independently or matched.

### Message count removed
An earlier version showed a colored user-message count as a second degradation axis (multi-turn reliability decay). It was dropped: the number wasn't actionable in practice — token volume already carries the "how loaded is this session" signal, and message count added a competing indicator without changing what the user does about it. The per-round cost reset still keys off the same `UserPromptSubmit` marker; only the display and its state field were removed.

### Per-round input delta removed
Per-round input size is not an independent degradation factor. A single turn loading 80K from file reads is healthier than four 20K turns of conversational refinement. What matters is cumulative total tokens and conversational structure, not per-turn volume.

### Cache age replaces cache hit percentage
A session-averaged cache hit percentage isn't actionable. What matters is whether the cache is warm right now, which predicts whether the next message will be fast and cheap or slow and expensive. The ~5 minute TTL means a timer since the last API call is the most predictive signal.

The age is measured from the last **API activity**, not the last render. The statusline re-renders at the end of a turn too, so a render-to-render timer counted a long busy turn as idle cooling time — the indicator flashed stale for one frame right as a turn finished, then cleared on the next render. Instead, `last_activity_ts` only advances when `cost.total_api_duration_ms` grew since the previous render (the model actually hit the API). While the model works, `api_ms` climbs and the age stays 0; it accumulates only during genuine idle. A missing baseline (fresh state or a legacy-format upgrade) counts as activity so the session starts warm rather than falsely stale.

### Round boundaries are set by UserPromptSubmit hook
`round-reset.sh` creates a marker file on each user prompt. The statusline resets round cost when it sees this marker.

### Output tokens are not displayed
Output tokens from the current call aren't in `ctx_tokens` yet — they fold into input on the next call.

## Color Thresholds

| Field | Green | Yellow | Orange | Red |
|-------|-------|--------|--------|-----|
| Context total (tokens) | < 120K | 120-250K | 250-400K | >= 400K |
| Cache age | < 3m (hidden) | 3-5m | — | > 5m |
| Rate limits | < 50% | 50-79% | — | >= 80% |

### Context threshold rationale
- **Green (< 120K)**: Peak retrieval. ~perfect MRCR. Where most Claude Code sessions land.
- **Yellow (120-250K)**: 93% MRCR. Proactive `/compact` with task-focused instructions worth considering.
- **Orange (250-400K)**: Single-needle retrieval still good, multi-needle starts degrading. Consider starting fresh if context is conversational rather than document-loaded.
- **Red (>= 400K)**: Partial retrieval. Details get hallucinated. Start fresh unless deep debugging where losing context is worse.

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
Format (v4): `4|round_start_cost|last_activity_ts|last_api_ms`

- Version prefix distinguishes formats; unrecognized/old state files are reset on read.
- Legacy formats are still read for graceful in-session upgrade: v3 `3|round_start_cost|last_ts` (its `last_ts` is treated as `last_activity_ts`), and v2 `2|round_start_cost|msg_count|last_ts` (the dropped message count sat between `round_start_cost` and `last_ts`).
- `last_activity_ts` is the epoch timestamp of the render at which the model last hit the API; `last_api_ms` is the `total_api_duration_ms` seen then. Together they let the next render tell busy time from idle time when computing cache age.

New-round marker: `/tmp/claude-statusline-newround-{session_id}`
Created by `round-reset.sh` on `UserPromptSubmit` hook, consumed by statusline on next update.

## Auto-Compact Threshold Derivation

Reverse-engineered from Claude Code binary (see CLAUDE.md for re-derivation instructions):

```
threshold = contextWindow - min(maxOutputTokens, 20000) - 13000
```

Approximated as `ctx_max - 33000`. Override with `COMPACT_OVERHEAD` env var.

## Configuration (env vars)

| Variable | Default | Effect |
|----------|---------|--------|
| `COMPACT_OVERHEAD` | 33000 | Tokens subtracted from the window to approximate the auto-compact threshold. |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | unset | If set (e.g. 75), treats the auto-compact threshold as that percent of the window; wins over `COMPACT_OVERHEAD`. |
| `CTX_BAR_WIDTH` | 10 | Cells in the context usage bar. |
| `PACE_BAR_WIDTH` | 5 | Cells in the 7d throttle meter. |
| `CLAUDE_JSON_PATH` | `~/.claude.json` | Credential file the auth/plan letter reads (tests point it at fixtures). |
