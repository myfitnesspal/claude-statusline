#!/usr/bin/env bash
# Tests for statusline.sh
# Feeds mock JSON to the statusline and verifies output values and colors.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATUSLINE="$SCRIPT_DIR/statusline.sh"

# Ensure ambient config env vars don't leak into tests (they'd skew default-dependent
# assertions). Tests set what they need explicitly per-run.
unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
unset STATUSLINE_COMPACT_OVERHEAD
unset STATUSLINE_CTX_BAR_WIDTH
unset STATUSLINE_PACE_BAR_WIDTH
unset STATUSLINE_PACE_TOL
unset STATUSLINE_PACE_GAMMA
unset STATUSLINE_PACE_WORK
unset STATUSLINE_PACE_HORIZON_TS
unset STATUSLINE_PACE_SHOW_ON_PACE
unset STATUSLINE_PACE_SHOW_COLD
unset STATUSLINE_MODEL_BAR_WIDTH
unset STATUSLINE_MODEL_USAGE_MAX_AGE
unset STATUSLINE_MODEL_USAGE_CACHE
unset STATUSLINE_MODEL_USAGE_REFRESH
unset STATUSLINE_MODEL_USAGE_TTL
unset STATUSLINE_MODEL_USAGE_REFRESHER
unset STATUSLINE_MODEL_USAGE_FIXTURE
unset STATUSLINE_MODEL_USAGE_FIXTURE_STATUS
unset STATUSLINE_MODEL_USAGE_FIXTURE_RETRY_AFTER
unset ANTHROPIC_API_KEY
PASS=0
FAIL=0
SESSION="test-$$"

# Auth fixtures: statusline reads oauthAccount from STATUSLINE_JSON_PATH.
# Default all tests to a logged-out fixture so the developer's real
# ~/.claude.json doesn't leak into assertions.
AUTH_JSON_DIR="/tmp/claude-statusline-authtest-$$"
mkdir -p "$AUTH_JSON_DIR"
echo '{}' > "$AUTH_JSON_DIR/logged-out.json"
echo '{"oauthAccount":{"organizationType":"claude_enterprise"}}' > "$AUTH_JSON_DIR/enterprise.json"
echo '{"oauthAccount":{"organizationType":"claude_max"}}' > "$AUTH_JSON_DIR/max.json"
echo '{"oauthAccount":{"organizationType":"claude_pro"}}' > "$AUTH_JSON_DIR/pro.json"
echo '{"oauthAccount":{"organizationType":"claude_team"}}' > "$AUTH_JSON_DIR/team.json"
echo '{"oauthAccount":{"organizationType":"console"}}' > "$AUTH_JSON_DIR/console.json"
export STATUSLINE_JSON_PATH="$AUTH_JSON_DIR/logged-out.json"

# Clean up state files on exit
cleanup() {
	rm -f "/tmp/claude-statusline-${SESSION}"
	rm -f "/tmp/claude-statusline-newround-${SESSION}"
	rm -rf "$AUTH_JSON_DIR"
}
trap cleanup EXIT

# Strip ANSI escape codes from output
strip_ansi() {
	sed 's/\x1b\[[0-9;]*m//g'
}

# Generate mock JSON payload
mock_json() {
	local input_tokens=${1:-100}
	local cache_creation=${2:-500}
	local cache_read=${3:-10000}
	local output_tokens=${4:-200}
	local context_window_size=${5:-200000}
	local cost=${6:-1.50}
	local api_duration_ms=${7:-60000}
	local exceeds_200k=${8:-false}
	cat <<EOF
{
  "session_id": "${SESSION}",
  "model": { "id": "claude-opus-4-6", "display_name": "Opus 4.6 (1M context)" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test", "added_dirs": [] },
  "cost": { "total_cost_usd": ${cost}, "total_duration_ms": 100000, "total_api_duration_ms": ${api_duration_ms} },
  "exceeds_200k_tokens": ${exceeds_200k},
  "context_window": {
    "total_input_tokens": 50000,
    "total_output_tokens": 10000,
    "context_window_size": ${context_window_size},
    "current_usage": {
      "input_tokens": ${input_tokens},
      "output_tokens": ${output_tokens},
      "cache_creation_input_tokens": ${cache_creation},
      "cache_read_input_tokens": ${cache_read}
    },
    "used_percentage": 50,
    "remaining_percentage": 50
  }
}
EOF
}

# Run statusline with mock data, return stripped output
run() {
	mock_json "$@" | bash "$STATUSLINE" | strip_ansi
}

# Run statusline with mock data, return raw output with ANSI codes
run_raw() {
	mock_json "$@" | bash "$STATUSLINE"
}

# Build a rate-limit payload for pace-meter tests: 5h at 40% (resets in 1h), and
# 7d at $1% resetting in $2 seconds. Elapsed = 604800 - $2, so the burn-rate
# extrapolation is deterministic.
pace_json() {
	local pct7=$1 reset_off=$2 now r5 r7
	now=$(date +%s); r5=$((now + 3600)); r7=$((now + reset_off))
	printf '{"session_id":"%s","model":{"display_name":"Opus 4.6 (1M context)"},"workspace":{"current_dir":"/x","project_dir":"/x"},"cost":{"total_cost_usd":1.50,"total_api_duration_ms":60000},"context_window":{"current_usage":{"input_tokens":10000},"context_window_size":1000000},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' "$SESSION" "$r5" "$pct7" "$r7"
}

assert_contains() {
	local desc="$1" output="$2" expected="$3"
	if echo "$output" | grep -qF "$expected"; then
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
		echo "FAIL: $desc"
		echo "  expected to contain: $expected"
		echo "  got: $output"
	fi
}

assert_not_contains() {
	local desc="$1" output="$2" unexpected="$3"
	if echo "$output" | grep -qF "$unexpected"; then
		FAIL=$((FAIL + 1))
		echo "FAIL: $desc"
		echo "  expected NOT to contain: $unexpected"
		echo "  got: $output"
	else
		PASS=$((PASS + 1))
	fi
}

# Reset state between test groups
reset_state() {
	rm -f "/tmp/claude-statusline-${SESSION}"
	rm -f "/tmp/claude-statusline-newround-${SESSION}"
}

echo "=== Context token calculation ==="

# ctx_tokens = input + cache_creation + cache_read
# 100 + 500 + 10000 = 10600 = 10.6k
reset_state
out=$(run 100 500 10000 200 200000)
assert_contains "ctx_tokens = input + cache_creation + cache_read" "$out" "10.6k"

# With larger values: 1000 + 5000 + 100000 = 106000 = 106k
reset_state
out=$(run 1000 5000 100000 200 200000)
assert_contains "ctx_tokens sums all input components" "$out" "106k"

# 3-digit k value with non-zero minor: 100 + 500 + 201500 = 202100 = 202k (not 202.1k)
reset_state
out=$(run 100 500 201500 200 1000000)
assert_contains "3-digit k drops decimal" "$out" "202k"
assert_not_contains "3-digit k no decimal shown" "$out" "202.1k"

echo ""
echo "=== Context usage bar ==="

# The context percentage is rendered as a bar scaled to usable_cap =
# min(compact_threshold, 400000). Full bar = the ceiling; past it the bar pegs
# full and gets a ▸ overflow marker. Bars pinned to STATUSLINE_CTX_BAR_WIDTH=10 (one cell
# per 10%) so expected strings are deterministic regardless of the default.

# Bar replaces the numeric percentage.
# 1M window: cap=400000. 130000/400000 = 32% -> 3 cells.
reset_state
out=$(STATUSLINE_CTX_BAR_WIDTH=10 run 130000 0 0 0 1000000)
assert_contains "context renders a bar" "$out" "███░░░░░░░"
assert_not_contains "percentage number removed" "$out" "32%"

# Denominator scales with window: same tokens, smaller window -> fuller bar.
# 167000 tokens: 200K window cap=167000 -> 100% (full); 1M window cap=400000 -> 41%.
reset_state
out=$(STATUSLINE_CTX_BAR_WIDTH=10 run 167000 0 0 0 200000)
assert_contains "200K window: full at compact threshold" "$out" "██████████"
reset_state
out=$(STATUSLINE_CTX_BAR_WIDTH=10 run 167000 0 0 0 1000000)
assert_contains "1M window: same tokens, partial bar" "$out" "████░░░░░░"
assert_not_contains "1M window: not full" "$out" "██████████"

# The overflow marker (▶) is gated on the RED zone (>= 400K) AND strictly past
# the bar ceiling. It fuses to the full bar (no space) and adds one cell of width.

# Exactly at the ceiling (400K on 1M): full red bar, NO marker yet (not past it).
reset_state
out=$(STATUSLINE_CTX_BAR_WIDTH=10 run 400000 0 0 0 1000000)
assert_contains "at ceiling: full bar" "$out" "██████████"
assert_not_contains "at ceiling: no marker" "$out" "▶"

# Past the ceiling in the red zone: pegged full with the fused ▶ marker.
reset_state
out=$(STATUSLINE_CTX_BAR_WIDTH=10 run 410000 0 0 0 1000000)
assert_contains "past ceiling (red): full bar + fused marker" "$out" "██████████▶"

# Full bar but NOT red (orange, 399K on 1M): no marker — marker is red-gated.
reset_state
raw=$(STATUSLINE_CTX_BAR_WIDTH=10 run_raw 399000 0 0 0 1000000)
assert_contains "orange full bar is orange" "$raw" $'\033[38;5;208m399k'
assert_contains "orange full bar is full" "$raw" "██████████"
assert_not_contains "orange full bar: no marker (not red)" "$raw" "▶"

# Small window: ceiling is the compact threshold (< 400K) and 400K is unreachable,
# so overflow pegs the bar full but shows NO marker (yellow, never red).
reset_state
raw=$(STATUSLINE_CTX_BAR_WIDTH=10 run_raw 180000 0 0 0 200000)
assert_contains "small-window overflow is yellow" "$raw" $'\033[33m180k'
assert_contains "small-window overflow pegs full" "$raw" "██████████"
assert_not_contains "small-window overflow: no marker" "$raw" "▶"

echo ""
echo "=== CLAUDE_AUTOCOMPACT_PCT_OVERRIDE ==="

# Override shifts the denominator, seen in the fill level (marker is red-gated, so
# a 200K window never shows one). 130000 tokens on 200K:
#   default cap=167000 -> 77% (8 cells)
#   override=50 -> cap=100000 -> overflow -> pegged full (10 cells), no marker
reset_state
out=$(STATUSLINE_CTX_BAR_WIDTH=10 run 130000 0 0 0 200000)
assert_contains "default denominator: 8-cell bar" "$out" "████████░░"
assert_not_contains "default denominator: no marker" "$out" "▶"
reset_state
out=$(STATUSLINE_CTX_BAR_WIDTH=10 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 run 130000 0 0 0 200000)
assert_contains "override=50 shrinks denominator, pegs full" "$out" "██████████"
assert_not_contains "override=50: still no marker on small window" "$out" "▶"

# STATUSLINE_COMPACT_OVERHEAD shifts the denominator too: overhead=100000 on 200K -> cap=100000.
reset_state
out=$(STATUSLINE_CTX_BAR_WIDTH=10 STATUSLINE_COMPACT_OVERHEAD=100000 run 130000 0 0 0 200000)
assert_contains "STATUSLINE_COMPACT_OVERHEAD shrinks denominator, pegs full" "$out" "██████████"

# Override beats STATUSLINE_COMPACT_OVERHEAD: override=50 (cap=100000) pegs full; overhead=0
# would give cap=200000 -> 65% (a 7-cell bar), so a full bar proves override won.
reset_state
out=$(STATUSLINE_CTX_BAR_WIDTH=10 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 STATUSLINE_COMPACT_OVERHEAD=0 run 130000 0 0 0 200000)
assert_contains "override beats STATUSLINE_COMPACT_OVERHEAD" "$out" "██████████"
assert_not_contains "override beats STATUSLINE_COMPACT_OVERHEAD (not overhead's bar)" "$out" "███████░░░"

echo ""
echo "=== Bar width knobs ==="

# STATUSLINE_CTX_BAR_WIDTH changes the context bar length. 32% at width 4 -> 1 cell.
reset_state
out=$(STATUSLINE_CTX_BAR_WIDTH=4 run 130000 0 0 0 1000000)
assert_contains "STATUSLINE_CTX_BAR_WIDTH=4 yields a 4-cell bar" "$out" "█░░░"
assert_not_contains "STATUSLINE_CTX_BAR_WIDTH=4 is not the default width" "$out" "██████████"

# STATUSLINE_PACE_BAR_WIDTH changes the 7d pace-meter length. Half-elapsed window at
# 50% used -> exactly on pace -> empty meter; STATUSLINE_PACE_SHOW_ON_PACE=true forces
# the otherwise-hidden on-pace bar so its width is visible.
reset_state
out=$(pace_json 50 302400 | STATUSLINE_PACE_SHOW_ON_PACE=true STATUSLINE_PACE_BAR_WIDTH=8 bash "$STATUSLINE" | strip_ansi)
assert_contains "STATUSLINE_PACE_BAR_WIDTH=8 yields an 8-cell meter" "$out" "░░░░░░░░"

echo ""
echo "=== 7d pace meter (gas-pedal urgency) ==="

# Window half-elapsed (302400s left, elapsed 302400). Urgency comes from
# wall = (100-used)*elapsed/used and r = remaining/wall; HOT (r>1) fills from the
# LEFT (yellow->orange->red), COLD (r<1) fills from the RIGHT in blue, on-pace is
# empty. Tests pin STATUSLINE_PACE_GAMMA=1 (linear) so cell counts are exact; STATUSLINE_PACE_TOL=10.
YEL=$'\033[33m'; ORG=$'\033[38;5;208m'; RD=$'\033[31m'; BLU=$'\033[38;5;33m'
pace_lin(){ pace_json "$1" 302400 | STATUSLINE_PACE_GAMMA=1 STATUSLINE_PACE_BAR_WIDTH=8 bash "$STATUSLINE"; }

# On pace: 50% used at half-elapsed -> r=1 -> on pace -> hidden by default.
reset_state
out=$(pace_lin 50 | strip_ansi)
assert_contains "on pace: 7d percent still shown" "$out" "50%"
assert_not_contains "on pace: meter hidden (no empty bar)" "$out" "50% ░"

# STATUSLINE_PACE_SHOW_ON_PACE=true renders the empty on-pace bar instead of hiding it.
reset_state
out=$(pace_json 50 302400 | STATUSLINE_PACE_SHOW_ON_PACE=true STATUSLINE_PACE_GAMMA=1 STATUSLINE_PACE_BAR_WIDTH=8 bash "$STATUSLINE" | strip_ansi)
assert_contains "SHOW_ON_PACE shows the empty on-pace bar" "$out" "50% ░░░░░░░░"

# Dead-band: 52% -> urgency ~76 permille < STATUSLINE_PACE_TOL(100) -> on pace -> hidden.
reset_state
out=$(pace_lin 52 | strip_ansi)
assert_not_contains "within tolerance: meter hidden" "$out" "52% ░"

# Hot, escalating by urgency: 55% -> 1 (yellow), 65% -> 3 (orange), 80% -> 6 (red).
reset_state
raw=$(pace_lin 55); out=$(printf '%s' "$raw" | strip_ansi)
assert_contains "mild hot: 1-cell from left" "$out" "55% █░░░░░░░"
assert_contains "mild hot is yellow" "$raw" "${YEL}█"
reset_state
raw=$(pace_lin 65); out=$(printf '%s' "$raw" | strip_ansi)
assert_contains "moderate hot: 3-cell" "$out" "65% ███░░░░░"
assert_contains "moderate hot is orange" "$raw" "${ORG}███"
reset_state
raw=$(pace_lin 80); out=$(printf '%s' "$raw" | strip_ansi)
assert_contains "severe hot: 6-cell" "$out" "80% ██████░░"
assert_contains "severe hot is red" "$raw" "${RD}██████"

# Cold (leaving budget on the table) is off by default: under-pace shows nothing.
reset_state
out=$(pace_lin 30 | strip_ansi)
assert_not_contains "cold hidden by default (no bar)" "$out" "30% ░"
assert_contains "cold hidden: 7d percent still shown" "$out" "30%"

# With STATUSLINE_PACE_SHOW_COLD=true it renders: fills from the RIGHT in blue, never escalates.
pace_cold(){ pace_json "$1" 302400 | STATUSLINE_PACE_SHOW_COLD=true STATUSLINE_PACE_GAMMA=1 STATUSLINE_PACE_BAR_WIDTH=8 bash "$STATUSLINE"; }
reset_state
raw=$(pace_cold 30); out=$(printf '%s' "$raw" | strip_ansi)
assert_contains "cold (opted in): 4-cell from the right" "$out" "30% ░░░░████"
assert_contains "cold is blue" "$raw" "${BLU}████"
reset_state
out=$(pace_cold 42 | strip_ansi)
assert_contains "mild cold (opted in): 2 cells on the right" "$out" "42% ░░░░░░██"

# No overflow marker even when very hot (clamps at full).
reset_state
out=$(pace_lin 95 | strip_ansi)
assert_contains "very hot: full bar" "$out" "95% ████████"
assert_not_contains "very hot: no overflow marker" "$out" "▶"

# Default gamma (1.5) exercises the integer-sqrt shaping and stays lower: 70% used,
# which is 4 cells linear, becomes 3 cells at the default curve.
reset_state
raw=$(pace_json 70 302400 | STATUSLINE_PACE_BAR_WIDTH=8 bash "$STATUSLINE"); out=$(printf '%s' "$raw" | strip_ansi)
assert_contains "default gamma 1.5: 3-cell (fewer than linear's 4)" "$out" "70% ███░░░░░"
assert_contains "default gamma still orange" "$raw" "${ORG}███"

# Higher gamma keeps the low end flatter still: 70% is 4 cells linear, 2 cells at gamma 2.
reset_state
out=$(pace_json 70 302400 | STATUSLINE_PACE_GAMMA=2 STATUSLINE_PACE_BAR_WIDTH=8 bash "$STATUSLINE" | strip_ansi)
assert_contains "gamma 2 flattens 70% to 2 cells" "$out" "70% ██░░░░░░"
reset_state
out=$(pace_lin 70 | strip_ansi)
assert_contains "linear gamma keeps 70% at 4 cells" "$out" "70% ████░░░░"

echo ""
echo "=== 7d pace is time-aware (same rate, different time left) ==="

# Same 70% used at the same rate, but the horizon changes how much you must fit in.
# To the full reset (302400s away) you'd overshoot -> HOT (4-cell orange, linear).
reset_state
out=$(pace_lin 70 | strip_ansi)
assert_contains "far horizon: hot (overshoot)" "$out" "70% ████░░░░"

# To a near horizon (100000s < the 129600s to your 100% wall) you'd finish ~93% ->
# COLD (you'd leave a little unused) -> 1 cell of blue on the right.
reset_state
_now=$(date +%s)
out=$(pace_json 70 302400 | STATUSLINE_PACE_SHOW_COLD=true STATUSLINE_PACE_HORIZON_TS=$((_now + 100000)) STATUSLINE_PACE_GAMMA=1 STATUSLINE_PACE_BAR_WIDTH=8 bash "$STATUSLINE" | strip_ansi)
assert_contains "near horizon: flips to cold, 1 cell right (cold shown)" "$out" "70% ░░░░░░░█"

# Horizon already passed (coasting) -> meter hidden entirely.
reset_state
_now=$(date +%s)
out=$(pace_json 70 302400 | STATUSLINE_PACE_HORIZON_TS=$((_now - 1000)) STATUSLINE_PACE_BAR_WIDTH=8 bash "$STATUSLINE" | strip_ansi)
assert_contains "coasting: 7d percent still shown" "$out" "70%"
assert_not_contains "coasting: pace meter hidden (no fill)" "$out" "70% █"
assert_not_contains "coasting: no empty meter either" "$out" "70% ░"

# Malformed STATUSLINE_PACE_WORK falls back to judging against the reset (no crash).
reset_state
out=$(pace_json 70 302400 | STATUSLINE_PACE_WORK="garbage" STATUSLINE_PACE_GAMMA=1 STATUSLINE_PACE_BAR_WIDTH=8 bash "$STATUSLINE" | strip_ansi)
assert_contains "bad STATUSLINE_PACE_WORK falls back to reset (4-cell)" "$out" "70% ████░░░░"

# A well-formed STATUSLINE_PACE_WORK renders without error (schedule actually parses).
reset_state
out=$(pace_json 70 302400 | STATUSLINE_PACE_WORK="Mon-Fri 09-18" STATUSLINE_PACE_BAR_WIDTH=8 bash "$STATUSLINE" | strip_ansi)
assert_contains "valid STATUSLINE_PACE_WORK still renders the 7d limit" "$out" "70%"

echo ""
echo "=== 7d pace work horizon computation (pace_horizon) ==="

# horizon = the latest work-active instant at or before the reset. Run the extracted
# function under TZ=UTC with hand-picked epochs whose UTC weekdays are known (epoch 0
# = Thu 1970-01-01). Fixtures: Wed 12:00 = 561600, Fri 18:00 = 756000,
# Thu 15:00 = 658800, Sun 19:00 = 932400, Mon 08:00 = 979200.
sed -n '/^_pace_dow() {/,/^}/p; /^pace_horizon() {/,/^}/p' "$STATUSLINE" > "$AUTH_JSON_DIR/pace_horizon_fns.sh"
source "$AUTH_JSON_DIR/pace_horizon_fns.sh"

h=$(TZ=UTC STATUSLINE_PACE_WORK="Mon-Fri 09-18" pace_horizon 561600 932400)
assert_contains "weekend reset (Sun 19:00) -> Friday 18:00" "$h" "756000"

h=$(TZ=UTC STATUSLINE_PACE_WORK="Mon-Fri 09-18" pace_horizon 561600 658800)
assert_contains "mid-week reset (Thu 15:00, in work hours) -> the reset itself" "$h" "658800"

h=$(TZ=UTC STATUSLINE_PACE_WORK="Mon-Fri 09-18" pace_horizon 561600 979200)
assert_contains "pre-work reset (Mon 08:00) -> prior Friday 18:00" "$h" "756000"

h=$(TZ=UTC STATUSLINE_PACE_WORK="Mon-Fri 9-18" pace_horizon 561600 932400)
assert_contains "single-digit hours parse" "$h" "756000"

h=$(TZ=UTC STATUSLINE_PACE_WORK="Sat-Sun 10-16" pace_horizon 561600 932400)
assert_contains "weekend-worker: Sun 19:00 reset -> Sun 16:00 work-end" "$h" "$((932400 - 3*3600))"

h=$(TZ=UTC STATUSLINE_PACE_WORK="garbage" pace_horizon 561600 932400) || true
if [ -z "$h" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: malformed STATUSLINE_PACE_WORK should yield no horizon (got: $h)"; fi

echo ""
echo "=== Context total color thresholds ==="

# Green: < 120K tokens. input=100, cache_creation=500, cache_read=50000 = 50600
reset_state
raw=$(run_raw 100 500 50000 200 200000)
assert_contains "ctx < 120K is green" "$raw" $'\033[32m50.6k'

# Yellow: 120K-250K. input=1000, cache_creation=5000, cache_read=120000 = 126000
reset_state
raw=$(run_raw 1000 5000 120000 200 1000000)
assert_contains "ctx >= 120K is yellow" "$raw" $'\033[33m126k'

# Orange: 250K-400K. input=1000, cache_creation=5000, cache_read=260000 = 266000
reset_state
raw=$(run_raw 1000 5000 260000 200 1000000)
assert_contains "ctx >= 250K is orange" "$raw" $'\033[38;5;208m266k'

# Red: >= 400K. input=1000, cache_creation=5000, cache_read=400000 = 406000
reset_state
raw=$(run_raw 1000 5000 400000 200 1000000)
assert_contains "ctx >= 400K is red" "$raw" $'\033[31m406k'

# Boundary: exactly 120000 is yellow (not green)
reset_state
raw=$(run_raw 0 0 120000 200 1000000)
assert_contains "ctx == 120K is yellow" "$raw" $'\033[33m120k'

# Boundary: exactly 250000 is orange (not yellow)
reset_state
raw=$(run_raw 0 0 250000 200 1000000)
assert_contains "ctx == 250K is orange" "$raw" $'\033[38;5;208m250k'

# Boundary: exactly 400000 is red (not orange)
reset_state
raw=$(run_raw 0 0 400000 200 1000000)
assert_contains "ctx == 400K is red" "$raw" $'\033[31m400k'

echo ""
echo "=== Long-context premium (>200K) colors orange ==="

# The exceeds_200k_tokens flag (Claude Code's long-context pricing boundary) starts
# orange at the premium cliff instead of waiting for the 250K retrieval threshold.
# 220K on a 1M window: yellow by retrieval, but orange once premium pricing applies.
reset_state
raw=$(run_raw 220000 0 0 200 1000000 1.50 60000 false)
assert_contains "220K without the flag is yellow" "$raw" $'\033[33m220k'
reset_state
raw=$(run_raw 220000 0 0 200 1000000 1.50 60000 true)
assert_contains "220K with premium flag is orange" "$raw" $'\033[38;5;208m220k'

# Orange stays through to red: 300K is orange either way, 450K is red regardless.
reset_state
raw=$(run_raw 300000 0 0 200 1000000 1.50 60000 true)
assert_contains "300K premium: orange" "$raw" $'\033[38;5;208m300k'
reset_state
raw=$(run_raw 450000 0 0 200 1000000 1.50 60000 true)
assert_contains "450K stays red even with premium flag" "$raw" $'\033[31m450k'

# Fallback: with no flag, the 250K retrieval threshold still colors orange.
reset_state
raw=$(run_raw 300000 0 0 200 1000000 1.50 60000 false)
assert_contains "300K without flag: orange by retrieval threshold" "$raw" $'\033[38;5;208m300k'

# 200K-window sessions are unaffected: the flag can't be true (context can't exceed
# the window), so coloring stays green/yellow by retrieval.
reset_state
raw=$(run_raw 150000 0 0 200 200000 1.50 60000 false)
assert_contains "150K on a 200K window is yellow (unchanged)" "$raw" $'\033[33m150k'

echo ""
echo "=== Message count removed ==="

# Message count is no longer displayed, even across round resets.
reset_state
out=$(run 100 500 10000 200 200000)
assert_not_contains "no msg on first call" "$out" "msg"

echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
out=$(run 100 500 10000 200 200000)
assert_not_contains "no msg after 1 round reset" "$out" "msg"

echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
out=$(run 100 500 10000 200 200000)
assert_not_contains "no msg after 2 round resets" "$out" "msg"

# Legacy v2 state carrying a high message count still shows nothing.
reset_state
echo "2|1.50|24|0" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000)
assert_not_contains "legacy v2 msg count not rendered" "$out" "msg"

echo ""
echo "=== Context section has no trailing indicator ==="

# The context section is just the token count and the usage bar — no
# dot-separated suffix. Legacy state files with extra trailing fields are
# ignored and never produce one.
reset_state
echo "5|1.50|$(($(date +%s) - 800))|60000|800" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50 60000)
assert_not_contains "no dot-separated suffix (legacy state)" "$out" "·"
assert_not_contains "no duration suffix (legacy state)" "$out" "13m"

reset_state
echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50 120000)
assert_not_contains "no dot-separated suffix (new round)" "$out" "·"

echo ""
echo "=== Per-round cost ==="

# First call with cost 1.50
reset_state
out=$(run 100 500 10000 200 200000 1.50)
assert_contains "first call round cost is zero" "$out" "+\$0.00"
assert_contains "total cost shown" "$out" "\$1.50"

# New round, cost now 2.00
echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
out=$(run 100 500 10000 200 200000 2.00)
# round_start_cost = 2.00 (set at round reset), so round_cost = 0
assert_contains "round cost after reset" "$out" "+\$0.00"

# Next call in same round, cost now 2.35
out=$(run 100 500 10000 200 200000 2.35)
assert_contains "round cost accumulates" "$out" "+\$0.35"

echo ""
echo "=== Model name abbreviation ==="

reset_state
out=$(run 100 500 10000 200 200000)
assert_contains "Opus abbreviated to O" "$out" "O4.6"
assert_contains "context size in model name" "$out" "200k"
assert_not_contains "full name not shown" "$out" "Opus"

# 1M context
reset_state
out=$(run 100 500 10000 200 1000000)
assert_contains "1M context shown" "$out" "1M"

echo ""
echo "=== Output tokens removed ==="

# Output tokens should not appear in statusline
reset_state
out=$(run 100 500 10000 200 200000)
assert_not_contains "no output token display" "$out" "↓"

echo ""
echo "=== Per-round input removed ==="

# Per-round input delta should not appear
reset_state
out=$(run 100 500 10000 200 200000)
assert_not_contains "no round input arrow" "$out" "↑"

echo ""
echo "=== API time ==="

reset_state
# 60000ms = 60s = 1m
out=$(run 100 500 10000 200 200000 1.50 60000)
assert_contains "API time shown" "$out" "1m"

# 3661000ms = 3661s = 1h1m
reset_state
out=$(run 100 500 10000 200 200000 1.50 3661000)
assert_contains "API time hours+minutes" "$out" "1h1m"

echo ""
echo "=== State format migration ==="

# Old v1 state file (5 fields, no version prefix) should be ignored
reset_state
echo "10600|26000|1.50|11000|12200" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50)
# Should reset to defaults: round_start_cost=$cost (1.50)
assert_contains "v1 state: round cost resets" "$out" "+\$0.00"

# Legacy v2 state (2|cost|msg|ts) still yields its round cost after upgrade
reset_state
echo "2|1.20|7|0" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50)
assert_contains "v2 state: round cost from field 2" "$out" "+\$0.30"

# Legacy v5 state (extra trailing fields) still yields its round cost.
reset_state
echo "5|1.10|1700000000|60000|0" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50)
assert_contains "v5 state: round cost from field 2" "$out" "+\$0.40"

echo ""
echo "=== Auth mode indicator ==="

# ANTHROPIC_API_KEY set: K shown after model, regardless of login state
reset_state
out=$(ANTHROPIC_API_KEY="sk-ant-test" STATUSLINE_JSON_PATH="$AUTH_JSON_DIR/enterprise.json" run 100 500 10000 200 200000)
assert_contains "API key session shows K" "$out" "200k K "

# Enterprise claude.ai login: E
reset_state
out=$(STATUSLINE_JSON_PATH="$AUTH_JSON_DIR/enterprise.json" run 100 500 10000 200 200000)
assert_contains "Enterprise login shows E" "$out" "200k E "

# Max subscription: M
reset_state
out=$(STATUSLINE_JSON_PATH="$AUTH_JSON_DIR/max.json" run 100 500 10000 200 200000)
assert_contains "Max login shows M" "$out" "200k M "

# Pro subscription: P
reset_state
out=$(STATUSLINE_JSON_PATH="$AUTH_JSON_DIR/pro.json" run 100 500 10000 200 200000)
assert_contains "Pro login shows P" "$out" "200k P "

# Team subscription: T
reset_state
out=$(STATUSLINE_JSON_PATH="$AUTH_JSON_DIR/team.json" run 100 500 10000 200 200000)
assert_contains "Team login shows T" "$out" "200k T "

# Unknown/other OAuth org (e.g. console): A fallback
reset_state
out=$(STATUSLINE_JSON_PATH="$AUTH_JSON_DIR/console.json" run 100 500 10000 200 200000)
assert_contains "Unknown org falls back to A" "$out" "200k A "

# Logged out, no key: indicator hidden
reset_state
out=$(run 100 500 10000 200 200000)
assert_not_contains "logged out hides E" "$out" "200k E "
assert_not_contains "logged out hides A" "$out" "200k A "
assert_not_contains "logged out hides K" "$out" "200k K "
assert_not_contains "logged out hides M" "$out" "200k M "

# Same gray as the rest of section 1: no color escape between model and letter
reset_state
raw=$(STATUSLINE_JSON_PATH="$AUTH_JSON_DIR/enterprise.json" run_raw 100 500 10000 200 200000)
assert_contains "auth letter uncolored" "$raw" "200k E "

echo ""
echo "=== Per-model weekly usage refresher (model-usage-refresh.sh) ==="

# The StatuslineUpdate payload carries only five_hour/seven_day, so the per-model
# weekly buckets (/usage's "Current week (Fable)") come from a separate fetch of
# GET /api/oauth/usage. model-usage-refresh.sh does that fetch out-of-band and
# writes a small cache the statusline reads. STATUSLINE_MODEL_USAGE_FIXTURE
# replaces the network call with a saved response body (tests, debugging).

REFRESHER="$SCRIPT_DIR/model-usage-refresh.sh"
MU_DIR="/tmp/claude-statusline-mutest-$$"
mkdir -p "$MU_DIR"
MU_CACHE="$MU_DIR/model-usage.json"

# A response shaped like the real one. Each of the two filters gets its own
# discriminating entry: the Mythos row is model-scoped but NOT weekly, so only the
# kind check drops it, and the scopeless row is weekly but NOT model-scoped, so
# only the scope check drops it. Without both, one filter covers for the other and
# the test passes with the filter deleted.
cat > "$MU_DIR/usage.json" <<'EOF'
{
  "five_hour": { "utilization": 18, "resets_at": 1788000000 },
  "seven_day": { "utilization": 3, "resets_at": 1788739200 },
  "limits": [
    { "kind": "five_hour", "percent": 18, "resets_at": 1788000000 },
    { "kind": "five_hour_scoped", "percent": 77, "resets_at": 1788000000,
      "scope": { "model": { "display_name": "Mythos" } } },
    { "kind": "weekly_scoped", "percent": 4.7, "resets_at": 1788739200,
      "scope": { "model": { "display_name": "Fable" } } },
    { "kind": "weekly_scoped", "percent": 9, "resets_at": 1788739200, "scope": {} }
  ]
}
EOF

rm -f "$MU_CACHE"
mu_rc=0
STATUSLINE_MODEL_USAGE_CACHE="$MU_CACHE" \
	STATUSLINE_MODEL_USAGE_FIXTURE="$MU_DIR/usage.json" \
	bash "$REFRESHER" >/dev/null 2>&1 || mu_rc=$?
if [ "$mu_rc" -eq 0 ]; then PASS=$((PASS + 1)); else
	FAIL=$((FAIL + 1)); echo "FAIL: refresher exits 0 on a good response (got $mu_rc)"; fi
mu_out=$(cat "$MU_CACHE" 2>/dev/null || echo "NO CACHE")
assert_contains "refresher extracts the Fable bucket name" "$mu_out" '"name":"Fable"'
assert_contains "refresher floors the percentage the way /usage does" "$mu_out" '"pct":4'
assert_not_contains "refresher does not emit a fractional percentage" "$mu_out" '"pct":4.7'
assert_contains "refresher keeps the bucket reset time" "$mu_out" '"resets_at":1788739200'
assert_not_contains "refresher drops a model-scoped entry that is not weekly" "$mu_out" 'Mythos'
assert_not_contains "refresher drops a non-weekly entry's percentage" "$mu_out" '"pct":77'
assert_not_contains "refresher drops weekly entries with no model scope" "$mu_out" '"pct":9'

# ts (data age) and checked_at (last attempt) are separate: the statusline hides a
# stale field on ts and backs off respawning on checked_at.
mu_ts=$(jq -r '.ts // 0' "$MU_CACHE" 2>/dev/null || echo 0)
mu_checked=$(jq -r '.checked_at // 0' "$MU_CACHE" 2>/dev/null || echo 0)
if [ "$mu_ts" = "$mu_checked" ] && [ "$mu_ts" -gt 1700000000 ] 2>/dev/null; then
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
	echo "FAIL: successful refresh stamps ts == checked_at"
	echo "  got ts=$mu_ts checked_at=$mu_checked"
fi

# A failed fetch must not blank a good cache: the models survive, only checked_at
# moves, so the display degrades by age rather than vanishing on one bad call.
python3 - "$MU_CACHE" <<'PYEOF' 2>/dev/null || true
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["ts"] = d["checked_at"] = 1788000000
json.dump(d, open(p, "w"))
PYEOF
STATUSLINE_MODEL_USAGE_CACHE="$MU_CACHE" \
	STATUSLINE_MODEL_USAGE_FIXTURE="$MU_DIR/does-not-exist.json" \
	bash "$REFRESHER" >/dev/null 2>&1 || true
mu_out=$(cat "$MU_CACHE" 2>/dev/null || echo "NO CACHE")
assert_contains "failed refresh keeps the previous buckets" "$mu_out" '"name":"Fable"'
assert_contains "failed refresh keeps the previous data age" "$mu_out" '"ts":1788000000'
mu_checked=$(jq -r '.checked_at // 0' "$MU_CACHE" 2>/dev/null || echo 0)
if [ "$mu_checked" -gt 1788000000 ] 2>/dev/null; then
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
	echo "FAIL: failed refresh advances checked_at (backoff) without touching ts"
	echo "  got checked_at=$mu_checked"
fi

# An error body (what an expired token returns) is not a usage body: it must leave
# the previous buckets intact rather than parsing to an empty bucket list.
python3 - "$MU_CACHE" <<'SEEDEOF' 2>/dev/null || true
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["ts"] = d["checked_at"] = 1788000000
d["models"] = [{"name": "Fable", "pct": 4, "resets_at": 1788739200}]
json.dump(d, open(p, "w"))
SEEDEOF
echo '{"error":{"type":"authentication_error","message":"invalid bearer token"}}' > "$MU_DIR/error.json"
STATUSLINE_MODEL_USAGE_CACHE="$MU_CACHE" \
	STATUSLINE_MODEL_USAGE_FIXTURE="$MU_DIR/error.json" \
	bash "$REFRESHER" >/dev/null 2>&1 || true
mu_out=$(cat "$MU_CACHE" 2>/dev/null || echo "NO CACHE")
assert_contains "error body keeps the previous buckets" "$mu_out" '"name":"Fable"'
assert_not_contains "error body does not blank the bucket list" "$mu_out" '"models":[]'

# A response carrying no model buckets writes an empty list rather than failing.
echo '{"five_hour":{"utilization":18},"limits":[]}' > "$MU_DIR/empty.json"
rm -f "$MU_CACHE"
STATUSLINE_MODEL_USAGE_CACHE="$MU_CACHE" \
	STATUSLINE_MODEL_USAGE_FIXTURE="$MU_DIR/empty.json" \
	bash "$REFRESHER" >/dev/null 2>&1 || true
mu_out=$(cat "$MU_CACHE" 2>/dev/null || echo "NO CACHE")
assert_contains "no buckets writes an empty list" "$mu_out" '"models":[]'

rm -rf "$MU_DIR"

echo ""
echo "=== Per-model weekly usage bar (the Fable bucket) ==="

# The refresher's cache is rendered as a field in the rate-limits section: the
# model's initial, its weekly percentage, and a bar scaled 0-100% of that bucket.
# The bucket shares the 7d reset, so no reset time is repeated.

MU_R_DIR="/tmp/claude-statusline-murender-$$"
mkdir -p "$MU_R_DIR"
MU_R_CACHE="$MU_R_DIR/model-usage.json"

# Write a cache whose data is $1 seconds old, carrying the models array $2.
mu_cache_write() {
	local age=$1 models=$2 stamp
	stamp=$(( $(date +%s) - age ))
	printf '{"ts":%s,"checked_at":%s,"models":%s}\n' "$stamp" "$stamp" "$models" > "$MU_R_CACHE"
}

# A payload with both rate limits present and the pace meter suppressed: only ~13
# minutes into the 7d window, which is below the extrapolation floor, so a pace bar
# cannot perturb the model-bucket assertions.
limits_json() {
	local now r5 r7
	now=$(date +%s); r5=$((now + 3600)); r7=$((now + 604000))
	printf '{"session_id":"%s","model":{"display_name":"Opus 4.6 (1M context)"},"workspace":{"current_dir":"/x","project_dir":"/x"},"cost":{"total_cost_usd":1.50,"total_api_duration_ms":60000},"context_window":{"current_usage":{"input_tokens":10000},"context_window_size":1000000},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":%s},"seven_day":{"used_percentage":12,"resets_at":%s}}}' "$SESSION" "$r5" "$r7"
}

run_limits() {
	limits_json | STATUSLINE_MODEL_USAGE_CACHE="$MU_R_CACHE" \
		STATUSLINE_MODEL_USAGE_REFRESH=false bash "$STATUSLINE" | strip_ansi
}

run_limits_raw() {
	limits_json | STATUSLINE_MODEL_USAGE_CACHE="$MU_R_CACHE" \
		STATUSLINE_MODEL_USAGE_REFRESH=false bash "$STATUSLINE"
}

# The bucket renders as initial, percentage, bar. 50% of 10 cells = 5 filled.
reset_state
mu_cache_write 60 '[{"name":"Fable","pct":50,"resets_at":1788739200}]'
out=$(STATUSLINE_MODEL_BAR_WIDTH=10 run_limits)
assert_contains "model bucket renders initial, percentage and bar" "$out" "F 50% █████░░░░░"
assert_contains "model bucket follows the 7d limit" "$out" "12% · F 50%"

# The initial comes from the server's display name, uppercased.
reset_state
mu_cache_write 60 '[{"name":"mythos","pct":30,"resets_at":1788739200}]'
out=$(STATUSLINE_MODEL_BAR_WIDTH=10 run_limits)
assert_contains "initial is uppercased from the display name" "$out" "M 30%"

# Every model-scoped bucket renders, in the order the server returned them.
reset_state
mu_cache_write 60 '[{"name":"Fable","pct":50,"resets_at":1788739200},{"name":"Opus","pct":20,"resets_at":1788739200}]'
out=$(STATUSLINE_MODEL_BAR_WIDTH=10 run_limits)
assert_contains "first bucket renders" "$out" "F 50%"
assert_contains "second bucket renders" "$out" "O 20%"
assert_contains "buckets keep server order" "$out" "F 50% █████░░░░░ · O 20% ██░░░░░░░░"

# Bar width honors its own knob, independent of the context and pace bars.
reset_state
mu_cache_write 60 '[{"name":"Fable","pct":50,"resets_at":1788739200}]'
out=$(STATUSLINE_MODEL_BAR_WIDTH=4 run_limits)
assert_contains "model bar width knob applies" "$out" "F 50% ██░░"

# The fill rounds to nearest, matching the context bar: 7% of 8 cells is 0.56, which
# rounds up to one cell rather than truncating to none.
reset_state
mu_cache_write 60 '[{"name":"Fable","pct":7,"resets_at":1788739200}]'
out=$(STATUSLINE_MODEL_BAR_WIDTH=8 run_limits)
assert_contains "fill rounds to nearest, not down" "$out" "F 7% █░░░░░░░"

# A low percentage still shows the number even when the bar rounds to empty: the
# number carries precision the bar cannot.
reset_state
mu_cache_write 60 '[{"name":"Fable","pct":4,"resets_at":1788739200}]'
out=$(STATUSLINE_MODEL_BAR_WIDTH=8 run_limits)
assert_contains "low percentage keeps its number" "$out" "F 4% ░░░░░░░░"

# No cache, no field. Nothing to say, so nothing is shown.
reset_state
rm -f "$MU_R_CACHE"
out=$(run_limits)
assert_not_contains "no cache hides the field" "$out" "F "

# An empty bucket list is not a bucket: the field stays hidden.
reset_state
mu_cache_write 60 '[]'
out=$(run_limits)
assert_not_contains "empty bucket list hides the field" "$out" "F "

# Data older than the max age is hidden rather than shown wrong. A refresher that
# has been failing for hours must not leave a confident stale number on screen.
reset_state
mu_cache_write 7200 '[{"name":"Fable","pct":50,"resets_at":1788739200}]'
out=$(STATUSLINE_MODEL_USAGE_MAX_AGE=3600 run_limits)
assert_not_contains "stale data is hidden" "$out" "F 50%"

reset_state
mu_cache_write 1800 '[{"name":"Fable","pct":50,"resets_at":1788739200}]'
out=$(STATUSLINE_MODEL_USAGE_MAX_AGE=3600 run_limits)
assert_contains "data within the max age is shown" "$out" "F 50%"

# The color ladder matches the neighbouring limits: gray under 50, yellow 50-79,
# red at 80 and over.
reset_state
mu_cache_write 60 '[{"name":"Fable","pct":49,"resets_at":1788739200}]'
raw=$(run_limits_raw)
assert_contains "under 50% is normal gray" "$raw" $'\033[38;5;245mF 49%'

reset_state
mu_cache_write 60 '[{"name":"Fable","pct":50,"resets_at":1788739200}]'
raw=$(run_limits_raw)
assert_contains "50% is yellow" "$raw" $'\033[33mF 50%'

reset_state
mu_cache_write 60 '[{"name":"Fable","pct":80,"resets_at":1788739200}]'
raw=$(run_limits_raw)
assert_contains "80% is red" "$raw" $'\033[31mF 80%'

# A session with no plan rate limits (API key, Bedrock, Vertex) has no plan buckets
# either, so the whole section stays absent even with a cache present.
reset_state
mu_cache_write 60 '[{"name":"Fable","pct":50,"resets_at":1788739200}]'
out=$(mock_json 100 500 10000 200 200000 \
	| STATUSLINE_MODEL_USAGE_CACHE="$MU_R_CACHE" STATUSLINE_MODEL_USAGE_REFRESH=false \
	  bash "$STATUSLINE" | strip_ansi)
assert_not_contains "no plan limits hides the model bucket too" "$out" "F 50%"

rm -rf "$MU_R_DIR"

echo ""
echo "=== Per-model usage auto-refresh spawn ==="

# Nothing else drives the refresher, so the statusline spawns it detached when the
# cache goes stale. The spawn must never delay or alter a render.

MU_S_DIR="/tmp/claude-statusline-muspawn-$$"
mkdir -p "$MU_S_DIR"
MU_S_CACHE="$MU_S_DIR/model-usage.json"
MU_S_SENTINEL="$MU_S_DIR/spawned"

# A stub standing in for model-usage-refresh.sh: it records that it ran.
cat > "$MU_S_DIR/stub.sh" <<'EOF'
#!/usr/bin/env bash
date +%s >> "$MU_SPAWN_SENTINEL"
EOF
chmod +x "$MU_S_DIR/stub.sh"

# Write a cache whose checked_at is $1 seconds old.
mu_spawn_cache() {
	local age=$1 stamp
	stamp=$(( $(date +%s) - age ))
	printf '{"ts":%s,"checked_at":%s,"models":[{"name":"Fable","pct":4,"resets_at":1788739200}]}\n' \
		"$stamp" "$stamp" > "$MU_S_CACHE"
}

# The spawn is detached, so poll briefly rather than assuming it has landed.
mu_spawned() {
	local i=0
	while [ "$i" -lt 40 ]; do
		[ -s "$MU_S_SENTINEL" ] && return 0
		sleep 0.05
		i=$((i + 1))
	done
	return 1
}

run_spawn() {
	limits_json | env MU_SPAWN_SENTINEL="$MU_S_SENTINEL" \
		STATUSLINE_MODEL_USAGE_CACHE="$MU_S_CACHE" \
		STATUSLINE_MODEL_USAGE_REFRESHER="$MU_S_DIR/stub.sh" \
		"$@" bash "$STATUSLINE" | strip_ansi
}

# No cache at all: the first render is what bootstraps the fetch.
reset_state
rm -f "$MU_S_CACHE" "$MU_S_SENTINEL"
out=$(run_spawn)
if mu_spawned; then PASS=$((PASS + 1)); else
	FAIL=$((FAIL + 1)); echo "FAIL: missing cache spawns the refresher"; fi

# Stale attempt: past the TTL, try again.
reset_state
rm -f "$MU_S_SENTINEL"
mu_spawn_cache 600
out=$(run_spawn STATUSLINE_MODEL_USAGE_TTL=300)
if mu_spawned; then PASS=$((PASS + 1)); else
	FAIL=$((FAIL + 1)); echo "FAIL: attempt older than the TTL spawns the refresher"; fi
assert_contains "a spawning render still shows the cached bucket" "$out" "F 4%"

# Fresh attempt: no spawn. Renders happen many times a second, so a fresh cache
# must not fire a fetch per render.
reset_state
rm -f "$MU_S_SENTINEL"
mu_spawn_cache 60
out=$(run_spawn STATUSLINE_MODEL_USAGE_TTL=300)
if mu_spawned; then
	FAIL=$((FAIL + 1)); echo "FAIL: a fresh attempt must not spawn the refresher"
else PASS=$((PASS + 1)); fi

# The network call is opt-out: setting the switch to false stops the spawn while
# still rendering whatever the cache already holds.
reset_state
rm -f "$MU_S_SENTINEL"
mu_spawn_cache 600
out=$(run_spawn STATUSLINE_MODEL_USAGE_TTL=300 STATUSLINE_MODEL_USAGE_REFRESH=false)
if mu_spawned; then
	FAIL=$((FAIL + 1)); echo "FAIL: STATUSLINE_MODEL_USAGE_REFRESH=false must stop the spawn"
else PASS=$((PASS + 1)); fi
assert_contains "refresh disabled still renders the cache" "$out" "F 4%"

# Stale DATA with a fresh ATTEMPT: the field hides (data too old) and no spawn
# fires (we just tried). The two timestamps are read independently.
reset_state
rm -f "$MU_S_SENTINEL"
stamp_now=$(date +%s)
printf '{"ts":%s,"checked_at":%s,"models":[{"name":"Fable","pct":4,"resets_at":1788739200}]}\n' \
	"$((stamp_now - 7200))" "$stamp_now" > "$MU_S_CACHE"
out=$(run_spawn STATUSLINE_MODEL_USAGE_TTL=300 STATUSLINE_MODEL_USAGE_MAX_AGE=3600)
assert_not_contains "stale data hides even with a fresh attempt" "$out" "F 4%"
if mu_spawned; then
	FAIL=$((FAIL + 1)); echo "FAIL: a fresh attempt must not spawn even when the data is stale"
else PASS=$((PASS + 1)); fi

rm -rf "$MU_S_DIR"

echo ""
echo "=== Per-model usage: the endpoint's retry-after is binding ==="

# The usage endpoint rate-limits per account on an hours-scale window and Claude
# Code's own /usage polling shares that budget, so a 429 with a retry-after of
# roughly an hour is a normal outcome. The refresher records when the server said
# to come back, and the spawn gate refuses to call before then.

MU_A_DIR="/tmp/claude-statusline-muafter-$$"
mkdir -p "$MU_A_DIR"
MU_A_CACHE="$MU_A_DIR/model-usage.json"
REFRESHER="$SCRIPT_DIR/model-usage-refresh.sh"

cat > "$MU_A_DIR/usage.json" <<'EOF'
{ "five_hour": { "utilization": 18 },
  "limits": [ { "kind": "weekly_scoped", "percent": 4, "resets_at": 1788739200,
                "scope": { "model": { "display_name": "Fable" } } } ] }
EOF
echo '{"error":{"type":"rate_limit_error","message":"Rate limited. Please try again later."}}' \
	> "$MU_A_DIR/throttled.json"

# Seed a good cache, then get throttled.
rm -f "$MU_A_CACHE"
STATUSLINE_MODEL_USAGE_CACHE="$MU_A_CACHE" \
	STATUSLINE_MODEL_USAGE_FIXTURE="$MU_A_DIR/usage.json" \
	bash "$REFRESHER" >/dev/null 2>&1 || true
STATUSLINE_MODEL_USAGE_CACHE="$MU_A_CACHE" \
	STATUSLINE_MODEL_USAGE_FIXTURE="$MU_A_DIR/throttled.json" \
	STATUSLINE_MODEL_USAGE_FIXTURE_STATUS=429 \
	STATUSLINE_MODEL_USAGE_FIXTURE_RETRY_AFTER=3387 \
	bash "$REFRESHER" >/dev/null 2>&1 || true

mu_a_retry=$(jq -r '.retry_after // 0' "$MU_A_CACHE" 2>/dev/null || echo 0)
mu_a_expected=$(( $(date +%s) + 3387 ))
if [ "$mu_a_retry" -gt $((mu_a_expected - 60)) ] && [ "$mu_a_retry" -lt $((mu_a_expected + 60)) ] 2>/dev/null; then
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
	echo "FAIL: a 429 records retry_after as an absolute epoch"
	echo "  expected near $mu_a_expected, got $mu_a_retry"
fi
mu_a_out=$(cat "$MU_A_CACHE" 2>/dev/null || echo "NO CACHE")
assert_contains "a 429 keeps the previous buckets" "$mu_a_out" '"name":"Fable"'

# A later success clears the deadline, so one throttled hour does not park the
# refresher forever.
STATUSLINE_MODEL_USAGE_CACHE="$MU_A_CACHE" \
	STATUSLINE_MODEL_USAGE_FIXTURE="$MU_A_DIR/usage.json" \
	bash "$REFRESHER" >/dev/null 2>&1 || true
mu_a_retry=$(jq -r '.retry_after // 0' "$MU_A_CACHE" 2>/dev/null || echo 0)
if [ "$mu_a_retry" -eq 0 ] 2>/dev/null; then PASS=$((PASS + 1)); else
	FAIL=$((FAIL + 1)); echo "FAIL: a success clears retry_after (got $mu_a_retry)"; fi

# A non-200 never reaches the parse, even when its body would parse cleanly. The
# fixture here is a VALID usage body naming a different bucket, so a status check
# that does not fire is visible: the cache would flip from Fable to Mythos.
cat > "$MU_A_DIR/wrong-bucket.json" <<'EOF'
{ "five_hour": { "utilization": 18 },
  "limits": [ { "kind": "weekly_scoped", "percent": 90, "resets_at": 1788739200,
                "scope": { "model": { "display_name": "Mythos" } } } ] }
EOF
STATUSLINE_MODEL_USAGE_CACHE="$MU_A_CACHE" \
	STATUSLINE_MODEL_USAGE_FIXTURE="$MU_A_DIR/wrong-bucket.json" \
	STATUSLINE_MODEL_USAGE_FIXTURE_STATUS=500 \
	bash "$REFRESHER" >/dev/null 2>&1 || true
mu_a_out=$(cat "$MU_A_CACHE" 2>/dev/null || echo "NO CACHE")
assert_contains "a 500 keeps the previous buckets" "$mu_a_out" '"name":"Fable"'
assert_not_contains "a 500 body is never parsed into the cache" "$mu_a_out" 'Mythos'

# The spawn gate honors the deadline: past the TTL but inside retry_after, no call.
MU_A_SENTINEL="$MU_A_DIR/spawned"
cat > "$MU_A_DIR/stub.sh" <<'EOF'
#!/usr/bin/env bash
date +%s >> "$MU_SPAWN_SENTINEL"
EOF
chmod +x "$MU_A_DIR/stub.sh"

mu_a_spawned() {
	local i=0
	while [ "$i" -lt 40 ]; do
		[ -s "$MU_A_SENTINEL" ] && return 0
		sleep 0.05
		i=$((i + 1))
	done
	return 1
}

run_after() {
	limits_json | env MU_SPAWN_SENTINEL="$MU_A_SENTINEL" \
		STATUSLINE_MODEL_USAGE_CACHE="$MU_A_CACHE" \
		STATUSLINE_MODEL_USAGE_REFRESHER="$MU_A_DIR/stub.sh" \
		"$@" bash "$STATUSLINE" | strip_ansi
}

reset_state
rm -f "$MU_A_SENTINEL"
printf '{"ts":%s,"checked_at":%s,"retry_after":%s,"models":[{"name":"Fable","pct":4,"resets_at":1788739200}]}\n' \
	"$(( $(date +%s) - 60 ))" "$(( $(date +%s) - 6000 ))" "$(( $(date +%s) + 1800 ))" > "$MU_A_CACHE"
out=$(run_after STATUSLINE_MODEL_USAGE_TTL=900)
if mu_a_spawned; then
	FAIL=$((FAIL + 1)); echo "FAIL: an unexpired retry_after must block the spawn"
else PASS=$((PASS + 1)); fi
assert_contains "a blocked spawn still renders the cache" "$out" "F 4%"

# Once the deadline has passed, the TTL governs again.
reset_state
rm -f "$MU_A_SENTINEL"
printf '{"ts":%s,"checked_at":%s,"retry_after":%s,"models":[{"name":"Fable","pct":4,"resets_at":1788739200}]}\n' \
	"$(( $(date +%s) - 60 ))" "$(( $(date +%s) - 6000 ))" "$(( $(date +%s) - 10 ))" > "$MU_A_CACHE"
out=$(run_after STATUSLINE_MODEL_USAGE_TTL=900)
if mu_a_spawned; then PASS=$((PASS + 1)); else
	FAIL=$((FAIL + 1)); echo "FAIL: an expired retry_after lets the TTL govern again"; fi

rm -rf "$MU_A_DIR"

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All tests passed!" || exit 1
