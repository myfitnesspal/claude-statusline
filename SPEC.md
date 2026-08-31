# Statusline Specification

## Layout

```
[model] | [context] | [rate limits] | [cost]
```

Example:
```
O4.6 200k | 34k ██░░░░░░ | 2h14m 11% · 3d5h 12% · F 4% | 19m +$0.05 $0.67
```

## Sections

### Section 1: Model identity
`O4.6 200k [auth] [location]`

- Model name abbreviated: Opus->O, Sonnet->S, Haiku->H
- Context window size appended (e.g. 200k, 1M) — detected from JSON `context_window.context_window_size`
- Auth/plan mode as a single uncolored letter. `K` = `ANTHROPIC_API_KEY` in the process env (pay-per-token API billing). Otherwise the letter reflects `oauthAccount.organizationType` in `~/.claude.json`: `M` = `claude_max`, `P` = `claude_pro`, `T` = `claude_team`, `E` = `claude_enterprise`, and `A` = any other non-empty org type (unknown/fallback). Hidden when logged out with no key. The env var wins because Claude Code prefers an approved `ANTHROPIC_API_KEY` over the stored OAuth login; a session where the key is present but was declined at the approval prompt shows `K` anyway (accepted inaccuracy — the payload carries no auth field). `STATUSLINE_JSON_PATH` overrides the credential file location for tests.
- Location shown only when cwd differs from project root, or agent/worktree active
- Subagent mode status (`[sa:on]` green, `[sa:off]` gray) shown only when the subagent-mode script (`~/src/claude-config/hooks/subagent-mode.sh`) is installed. State comes from the per-session file `${SUBAGENT_MODE_STATE_DIR:-/tmp}/claude-subagent-state-<session_id>` (`enabled`/`disabled`); with no state file, the global kill switch `~/src/claude-config/subagents-disabled` means off, else on. `SUBAGENT_MODE_STATE_DIR` exists so tests can isolate the state file; production leaves it unset.

### Section 2: Context health
`34k ██░░░░░░`

- **Total context**: absolute token count colored by retrieval quality thresholds, followed by a **usage bar**. The bar fills to `usable_cap = min(compact_threshold, 400000)` — a full bar is that ceiling (the 400K retrieval red line, or the auto-compact threshold when it binds first). The bar inherits the token-count color (green < 120K, yellow 120-250K, orange 250-400K, red >= 400K) — except **orange also starts at the long-context pricing cliff**: Claude Code's `exceeds_200k_tokens` flag (premium pricing above 200K on 1M-context models) colors the bar orange from the cliff through to red, so orange means "premium pricing and/or retrieval degrading." Overflow marker: a `▶` arrowhead fused to the bar (adds one cell, reading as the bar continuing off-scale), shown only in the **red zone** (>= 400K) and strictly past the ceiling. On a small window the ceiling is the compact threshold (below 400K, so red is unreachable) — the bar just pegs full with no marker, since auto-compact self-heals. Width is `STATUSLINE_CTX_BAR_WIDTH` cells (default 8).
- Output tokens are NOT shown — they aren't in context yet (will fold in on next call)

### Section 3: Rate limits
`2h14m 11% · 3d5h 12% · F 4%`

- 5-hour and 7-day rate limit usage with time until reset
- Dot separator between the two limits
- Color-coded: gray < 50%, yellow 50-79%, red >= 80%
- Only shown when rate limit data is available (Pro/Max subscribers)
- The 7-day limit is followed by a **bidirectional pace meter** (see below): it flags both burning too fast (you'll wall before the window/horizon) and too slow (you'll leave weekly budget unused, which is lost at reset). Hidden when on pace by default, so it only appears when it has something to say.
- **Per-model weekly buckets** are one field each, carrying the model's initial and its weekly percentage and nothing else. `F 4%` is the `Current week (Fable)` row from `/usage`. They sit after the last plan percentage present and before the pace meter, separated from the meter by a dot like every other field boundary in the section, so the meter keeps its right edge. The dot appears only when the meter actually renders: the meter hides whenever the burn is on pace, and a separator keyed to the bucket alone would trail with nothing after it. With a 7-day field that reads as `3d5h 12% · F 4%`; on a payload carrying only `five_hour` the bucket follows the 5-hour percentage instead, which the render deliberately allows because the buckets come from a different source than the payload. They are read from Claude Code's own cached usage response in `~/.claude.json` (see Per-Model Weekly Usage), and the field is absent when the account has no such bucket or the cached reading is over an hour old.

### Section 4: Cost and timing
`19m +$0.05 $0.67`

- Cumulative API processing time (not wall clock — wall time is useless, you already know when you started)
- Per-round cost delta
- Session total cost

## Key Design Decisions

### Context colored by absolute token thresholds, not compact percentage
The compact percentage tells you when auto-compact fires, but says nothing about retrieval quality. Research (MRCR v2 benchmarks, practitioner needle tests) shows retrieval degrades at specific absolute token thresholds regardless of window size. A 200K session on a 1M window has the same retrieval quality as 200K on a 200K window. The usage is shown as a bar (see below); its color, keyed to absolute token count, carries the retrieval-quality signal while the bar length carries the how-close-to-the-ceiling signal.

### Context usage shown as a bar
The usage percentage is drawn as a fixed-width bar rather than a number. A number invites arithmetic ("42% of what?"); a bar shows headroom at a glance. The bar scales to `usable_cap = min(compact_threshold, 400000)` so a full bar always means "at the wall that binds first" — the 400K retrieval red line on a large window, or the auto-compact threshold on a small one. Color is decoupled from length (absolute token thresholds), so the two degradation signals — retrieval quality and proximity to the ceiling — read independently.

Overflow is marked with a `▶` arrowhead **fused** to the bar (no space), so the bar reads as continuing off-scale; the box keeps its `STATUSLINE_CTX_BAR_WIDTH` blocks and the arrowhead adds one cell. It is gated on the **red retrieval zone** (>= 400K), not merely on passing the bar ceiling: on a large window the ceiling *is* 400K so overflow is inherently red; on a small window the ceiling is the auto-compact threshold (below 400K), and passing it is a routine, self-healing state that doesn't warrant an alarm glyph — the full bar alone signals it. Reserving the marker for the red line keeps it meaning one thing: irreversible retrieval degradation. Bar cells are set by `STATUSLINE_CTX_BAR_WIDTH` (default 8); the 7d pace meter has its own `STATUSLINE_PACE_BAR_WIDTH` (default 8) so the two bars can be tuned independently or matched.

### Per-model buckets are a number, with no bar
An earlier version drew a bar beside the percentage, the way the context field does. It was dropped. The bucket reads as a plan limit and belongs with the 5-hour and 7-day fields, which are numbers alone, so a bar made it look like a different kind of thing. At the percentages these buckets actually sit at, the bar was also empty most of the time and carried no information the number did not.

The field sits between the 7-day percentage and the 7-day pace meter. That leaves the three percentages reading as one run and keeps the meter, the section's only graphical element, at its right edge.

No reset time is shown. The per-model window shares the 7-day window's reset, which the neighbouring field already displays, so a second copy would be the same fact twice.

The color ladder matches `fmt_limit`, because the field is a plan limit and reads alongside the other two.

### Per-model buckets inherit section 3's gate, which is the 5-hour limit
The field renders inside section 3, so it appears only when the payload carries `five_hour`. A session with no plan rate limits (API key, Bedrock, Vertex) has no plan buckets either, so hiding both together is correct rather than incidental.

That gate is `five_hour` alone, not "any plan limit". Measured: a payload carrying `seven_day` without `five_hour` hides the whole section, including the 7-day percentage and any bucket. Whether that combination occurs is unverified — the payload builder spreads the two keys independently, so it is expressible — and no local evidence says it happens.

### Message count removed
An earlier version showed a colored user-message count as a second degradation axis (multi-turn reliability decay). It was dropped: the number wasn't actionable in practice — token volume already carries the "how loaded is this session" signal, and message count added a competing indicator without changing what the user does about it. The per-round cost reset still keys off the same `UserPromptSubmit` marker; only the display and its state field were removed.

### Per-round input delta removed
Per-round input size is not an independent degradation factor. A single turn loading 80K from file reads is healthier than four 20K turns of conversational refinement. What matters is cumulative total tokens and conversational structure, not per-turn volume.

### Round boundaries are set by UserPromptSubmit hook
`round-reset.sh` creates a marker file on each user prompt. The statusline resets round cost when it sees this marker.

### Output tokens are not displayed
Output tokens from the current call aren't in `ctx_tokens` yet — they fold into input on the next call.

## Color Thresholds

| Field | Green | Yellow | Orange | Red |
|-------|-------|--------|--------|-----|
| Context total (tokens) | < 120K | 120-250K | 250-400K (or ≥ 200K premium) | >= 400K |
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
Format (v6): `6|round_start_cost`

- Only the per-round cost baseline is persisted. `round_start_cost` is the session cost at the start of the current round; the per-round delta is `cost - round_start_cost`.
- Version prefix distinguishes formats; unrecognized/old state files are reset on read. `round_start_cost` is field 2 of every prior format (v2-v5), so all legacy state files still yield it on read and their extra trailing fields are ignored.

New-round marker: `/tmp/claude-statusline-newround-{session_id}`
Created by `round-reset.sh` on `UserPromptSubmit` hook, consumed by statusline on next update.

### Usage snapshots

Every render also writes a snapshot of the authoritative rate-limit fields, so a
Bash poll can read live 5h and 7d usage without a statusline hook of its own:

- `/tmp/claude-usage-{session_id}.json`, overwritten per render, is the current
  session's snapshot.
- `~/.claude-statusline/usage-history.jsonl` is the append-only history, tagged with
  `session_id`, which `fit-budget.py` reads to reconstruct account-wide cost across
  concurrent sessions.

`fit-budget.py` skips rows whose `session_id` begins with `test-`. The suite used to
render against the real `$HOME` and wrote hundreds of synthetic rows into this file;
because `fit_window` prefers the widest span, a ten-row synthetic group outranked the
only real window and the 7-day cap came out as `$0`. The suite is isolated now, so
the skip guards against that isolation regressing rather than a live need.

Both writes are best-effort, since a snapshot is not worth a broken status line.
Two details make that true rather than aspirational. The statusline creates
`~/.claude-statusline` itself, because nothing else does, and before it did every
append on a fresh machine failed and `fit-budget.py` had nothing to read. And the
`2>/dev/null` sits on a brace group rather than on `printf`, because a failing
redirection is reported by the shell, not by the command inside it, so the earlier
placement left an error on the terminal at every render while silently losing the
line.

## Per-Model Weekly Usage

The `StatuslineUpdate` payload's `rate_limits` object is built from three sources:
`five_hour`, `seven_day`, and `spend_limit` (gateway sessions only). No per-model
window reaches the hook, so the buckets `/usage` renders as `Current week (Fable)`
are not available from the payload at all.

They are already on disk. Claude Code caches the entire usage response body in
`~/.claude.json` under `cachedUsageUtilization`:

```json
{ "cachedUsageUtilization": {
    "fetchedAtMs": 1788192025425,
    "accountUuid": "…",
    "utilization": { "limits": [
      { "kind": "weekly_scoped", "group": "weekly", "percent": 4,
        "resets_at": "2026-09-06T23:00:00.244199+00:00",
        "scope": { "model": { "display_name": "Fable" } } } ] } } }
```

A per-model bucket is a `limits[]` entry whose `kind` is `weekly_scoped` and which
carries a `scope.model.display_name`. Its `percent` is nominally a 0-100 percentage and
is floored, so the statusline shows the same integer the `/usage` dialog does.

It is not clamped, deliberately. The payload's sibling 5-hour percentage is observed
above 100 on this account (337 of 643 logged rows, maximum 106), so the upstream shape
does not honour the nominal range, and `fmt_limit` does not clamp either. A bucket at
250 renders `F 250%`, which is the truth about that account. A `percent` that is not a
number at all is a different case: the bucket is dropped rather than shown as 0%.

### The file is read once per render

`~/.claude.json` holds two things this statusline needs, the OAuth account's
organization type (the auth letter) and the cached usage response, and it is around
200KB of JSON. One `jq` pass emits both, tagged by line, rather than parsing the
file twice. `STATUSLINE_JSON_PATH` overrides the location, which is how the tests
point it at fixtures.

### A cached block from another account is ignored

The block records the `accountUuid` it describes. After an account switch it
describes someone else's usage, so a mismatch against `oauthAccount.accountUuid`
drops it rather than rendering the wrong numbers.

### The cached block is untrusted data

Every value in `cachedUsageUtilization` is written by another program and can
carry anything the usage endpoint returned. The bucket read therefore treats the
block as hostile input rather than as a trusted local file, on three axes.

**The model name is reduced to one character before it reaches the renderer.**
The `jq` pass emits its facts as one newline-delimited stream of `tag:value`
lines, which the shell loop below it parses by tag. A newline inside
`scope.model.display_name` starts a line that loop reads as another tag, so the
server controls a channel it was never meant to reach. Two demonstrated
consequences: a name of `Fable\norg:claude_enterprise` rewrote the auth letter,
and a name carrying `\nfetched:<recent>` forged the cache timestamp and defeated
the staleness cutoff, using data from the very file it guards.

The fix is `gsub("[^A-Za-z0-9]"; "") | ascii_upcase` followed by `[0:1]`, applied
inside `jq` before the value is emitted. One uppercase alphanumeric character is
all the renderer uses, and no newline, tab, colon, or escape byte survives it.
That closes the channel for this field rather than patching one payload, so a
future edit that loosens the character class, or that moves the sanitization
downstream of the emit, reopens it.

The channel itself is not closed. `organizationType` rides the same stream and
is emitted raw, so a newline in it injects whatever tag the attacker chooses.
Measured 2026-08-31: an `organizationType` of `claude_max\nbucket:Z\t99`
renders `Z 99%` against an empty `limits[]`, and an SGR attribute smuggled the
same way survives the suite's escape-byte check, which strips well-formed
sequences before testing for a stray `ESC`. Closing the channel means either
sanitizing every server-supplied value on it or choosing a delimiter the values
cannot contain.

**A non-numeric percentage drops the bucket instead of defaulting to zero.**
`jq` emits the sentinel `x` when `.percent` is not a number, and the loop's
existing numeric guard then skips that row. Defaulting to `0` would print `F 0%`,
inventing the most reassuring possible value for a number you throttle against.
Rendering nothing is honest, because an absent field reads as "no reading" while
a wrong field reads as a reading.

**A timestamp in the future hides the field.** `fetchedAtMs` is compared against
the render's own clock, and a negative age returns early. Without that check,
clock skew makes the cutoff comparison false, which buys exactly the
reads-as-current outcome that cutoff exists to prevent. The guard is
therefore load-bearing for the staleness policy rather than defensive tidying.

### Staleness follows Claude Code's own read cutoff

The cache can be an hour behind, so this field needs a staleness policy that the
other fields do not. The policy is one threshold, and it comes out of Claude Code's
binary rather than being chosen here, because Claude Code is the writer and its own
reader defines what the block means:

| Constant | Value | Role |
|----------|-------|------|
| `wen` | 3600000 ms (1 hour) | The read cutoff. Its own reader returns null past this, so an older block is one Claude Code itself discards. |

Past `STATUSLINE_MODEL_USAGE_MAX_AGE` (default 3600 seconds, matching `wen`) the
field is hidden, because showing it would mean displaying a number the writer's own
reader rejects. Inside the cutoff the field is the number alone.

A cutoff is required, and that part is a measured failure rather than a preference. A
version with no cutoff displayed 4% while the real bucket sat at 21%, because the
block was 85 minutes old.

An age stamp was tried alongside it, rendering `F 21% 12m` between the 5-minute write
throttle and the cutoff. It was dropped. The same `/usage` run that refreshes the
cache is the one a reader has just made, so in practice the age was within a few
minutes of current almost every time it appeared, and it spent a cell of a
deliberately short line saying so. The cost of dropping it is real and bounded: a
reading up to an hour old now renders identically to a fresh one, and the cutoff is
the only thing standing between the reader and a stale number. That trade was made
deliberately, in favour of the shorter line.

### What refreshes the block, and what that makes this field

Nothing refreshes it in the background. The write happens on one path only, when a
usage fetch succeeds, and that path has exactly two entry points: the `/usage`
command and an SDK `get_usage` request. There is no poller.

So the field carries the reading from your last `/usage` run and disappears an hour
later. Running `/usage` is what brings it back.

That bounds what this field can be, and no local source does better:

- The endpoint is rate limited per account on an hours-scale window.
- The rate-limit headers that arrive fresh on every request carry the 5-hour and
  7-day windows only, with no per-model bucket. Claude Code's own fallback path
  confirms this: when a usage fetch fails it reconstructs `five_hour` and
  `seven_day` from those headers and nothing else.
- The only other mirror of the per-model data lives in Claude Code's process memory.

### Why the statusline does not fetch this itself

An earlier version of this feature called `GET /api/oauth/usage` directly, the same
endpoint Claude Code calls. That does not work as a polling source. The endpoint is
rate limited per account on an hours-scale window, and Claude Code's own polling
spends the same budget: measured 2026-08-31, the very first call ever made from this
repo returned `HTTP 429` with `retry-after: 3387`, so the allowance was already gone.
Fetching independently also risks throttling the user's own `/usage` dialog.

Reading `cachedUsageUtilization` removes the whole problem. There is no OAuth token
to handle, no network call in or near the render path, no 429 to back off from, and
no competition for the account's allowance. Claude Code does the fetching, and this
statusline reads what it stored.

## Auto-Compact Threshold Derivation

Reverse-engineered from Claude Code binary (see CLAUDE.md for re-derivation instructions):

```
threshold = contextWindow - min(maxOutputTokens, 20000) - 13000
```

Approximated as `ctx_max - 33000`. Override with `STATUSLINE_COMPACT_OVERHEAD` env var.

## Configuration (env vars)

| Variable | Default | Effect |
|----------|---------|--------|
| `STATUSLINE_COMPACT_OVERHEAD` | 33000 | Tokens subtracted from the window to approximate the auto-compact threshold. |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | unset | Claude Code's own variable (deliberately **not** namespaced): if set (e.g. 75), treats the auto-compact threshold as that percent of the window; wins over `STATUSLINE_COMPACT_OVERHEAD`. Keying off the official var means the bar reflects the same auto-compact override Claude Code is actually using. |
| `STATUSLINE_CTX_BAR_WIDTH` | 8 | Cells in the context usage bar. |
| `STATUSLINE_PACE_BAR_WIDTH` | 8 | Cells in the 7d pace meter. |
| `STATUSLINE_PACE_TOL` | 10 | On-pace dead-band as a percent of urgency (0-100): urgency below it reads as an empty (neutral) meter. |
| `STATUSLINE_PACE_GAMMA` | 1.5 | Response curve above the dead-band. `1` linear; `1.5` (default) / `2` / `3` keep the low end flatter, ramping up only as correcting gets urgent. |
| `STATUSLINE_PACE_SHOW_ON_PACE` | false | When on-pace, the meter is hidden by default so it only appears when it has something to say. Set `true` to always render the empty neutral bar. |
| `STATUSLINE_PACE_SHOW_COLD` | false | The cold (under-pace, "leaving budget unused") side is **off by default** — by default you're only warned about burning too fast. Set `true` to also be warned about under-use. |
| `STATUSLINE_PACE_WORK` | unset | Your weekly work schedule (`"<days> <start>-<end>"` local 24h, e.g. `"Mon-Fri 09-18"`; days a range like `Mon-Fri` or a comma list like `Mon,Wed,Fri`; hours `HH` or `HH:MM`). The 7d pace meter judges pace against your work schedule instead of the reset (see below). Unset = judge to the reset. |
| `STATUSLINE_PACE_HORIZON_TS` | unset | Absolute-epoch override of the computed horizon (advanced / tests). Takes precedence over `STATUSLINE_PACE_WORK`. |
| `STATUSLINE_JSON_PATH` | `~/.claude.json` | Credential file the auth/plan letter reads (tests point it at fixtures). |
| `STATUSLINE_MODEL_USAGE_MAX_AGE` | 3600 | Seconds of age on Claude Code's cached usage reading past which the per-model field is hidden. Default matches Claude Code's own read cutoff (`wen`). |

### 7d pace meter (bidirectional gas-pedal)

The 7d pace meter is a bidirectional gauge around one target: **use ~100% of the weekly budget by the horizon, without walling first.** Unused 7-day allowance is lost at reset, so both directions are failures worth flagging. Think of it as a gas pedal: it shows how far your foot is from the *cruise* rate that lands you at exactly 100% at the horizon — and how little time is left to move it.

```
wall = (100 - used%) * elapsed / used%     # seconds until you'd hit 100% at the current rate
r    = time-to-horizon / wall              # r=1 on pace, >1 too hot, <1 too cold
```

- **On pace** (`r ≈ 1`): hidden by default (or an empty neutral bar with `STATUSLINE_PACE_SHOW_ON_PACE=true`).
- **Too hot** (`r > 1`, pressing harder than cruise — you'd wall before the horizon): fills from the **left**, escalating **yellow → orange → red**. A full red bar means back off hard; no overflow marker (being further over doesn't change the action).
- **Too cold** (`r < 1`, pressing softer than cruise — you'd reach the horizon with budget unused): fills from the **right** in **blue**. `1/r` is literally "how much harder you'd need to press to not waste." It never escalates — leaving budget on the table is a milder, cliff-free cost. **Off by default** (`STATUSLINE_PACE_SHOW_COLD=true` to enable): under-use nagging is opt-in, since not everyone wants it.

**The fill is urgency, not raw deviation**, which is the key property: it is *time-aware*. The fill is the fraction of your remaining slack you've used up (`(remaining - wall)/remaining` hot, `(wall - remaining)/wall` cold), so it stays near-empty early — when there's plenty of time to correct — and rises toward the horizon. A *steady* off-pace burn (the common case) therefore sits near-empty most of the week and only fills when scaling back or flooring it is actually urgent, rather than parking at a constant fill all week the way a raw-deviation meter would.

`STATUSLINE_PACE_TOL` is the on-pace dead-band (percent of urgency); above it, urgency is shaped by `STATUSLINE_PACE_GAMMA` (`1` linear, `1.5` default and up keep the low end flatter) and mapped to `STATUSLINE_PACE_BAR_WIDTH` cells. Hot color steps at ≥3 cells (orange) and ≥6 (red). When on-pace, the meter is **hidden by default** (`STATUSLINE_PACE_SHOW_ON_PACE=true` to render the empty neutral bar instead) so it only appears when it's saying something. There is deliberately **no "used >= 90% → red" rule**: the urgency subsumes it — 95% used mid-window has an imminent wall (hot), while 95% used near the reset has `r ≈ 1` (on pace, you used it well), which such a rule would have wrongly alarmed.

### 7d pace work schedule

The horizon in that projection is, by default, the account reset. But a work account only needs to last through the work week — off-hours before the reset are free time you won't spend, so judging pace all the way to a Sunday reset over-penalizes a Mon–Fri user.

`STATUSLINE_PACE_WORK` sets the horizon to **the last work-active instant at or before the reset** (computed by `pace_horizon`). The burn *rate* is still measured over the real elapsed window; only the "do I make it in time?" comparison uses this horizon. Concretely:

- Reset in off-hours (Sunday 19:00, Mon–Fri worker) → horizon = the preceding Friday 18:00. Mid-week burning hot it still warns (you'd wall before Friday); later in the week it relaxes (if you'd only wall Saturday you've made it); once Friday 18:00 is behind you, the meter hides (coasting to the reset).
- Reset **inside** work hours (Thursday 15:00) → horizon = the reset itself. You work right up to it, so there is no free slack to discount — the meter behaves exactly as the default. This is the case a fixed weekday deadline got wrong.

Why a schedule and not a single "Fri 18:00" deadline: the weekly reset is **not** a stable wall-clock time (it drifts with the billing cycle). A fixed deadline is only correct while the reset sits on the weekend; the week it drifts mid-work-week, the deadline points at the wrong day and the meter goes dark exactly when usage is highest. Deriving the horizon from the schedule + the actual reset each render is correct for any reset time.

The computation is pure arithmetic: wall-clock components come from the epoch plus the current `date +%z` offset (no `date -r`/`date -d` string parsing), so it is macOS/Linux portable. The offset is sampled once, so DST day-length shifts are approximate (a ~1h error twice a year, immaterial to pace). Malformed `STATUSLINE_PACE_WORK` falls back to judging against the reset.
