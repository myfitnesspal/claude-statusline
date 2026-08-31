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
unset STATUSLINE_MODEL_USAGE_MAX_AGE
unset ANTHROPIC_API_KEY
PASS=0
FAIL=0
SESSION="test-$$"

# The statusline writes a usage snapshot under $HOME/.claude-statusline on every
# render, so the whole suite runs against a throwaway HOME. Without this, 18 test
# invocations append to the developer's real history file, and any mutation-testing
# pass that reverses the append into a truncate destroys it. Nothing here needs the
# real home: the auth fixture comes from STATUSLINE_JSON_PATH, which every test sets.
TEST_HOME="/tmp/claude-statusline-home-$$"
mkdir -p "$TEST_HOME"
export HOME="$TEST_HOME"

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
	rm -rf "/tmp/claude-usage-${SESSION}.json"
	rm -rf "$AUTH_JSON_DIR"
	rm -rf "$TEST_HOME"
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
echo "=== Per-model weekly usage field (the Fable bucket) ==="

# Claude Code caches the whole usage response in ~/.claude.json as
# cachedUsageUtilization, refreshed when a usage fetch succeeds. The per-model weekly
# buckets (/usage's "Current week (Fable)") come from there, read in the same pass
# that reads the auth letter. STATUSLINE_JSON_PATH points that file at a fixture.
#
# The field is a number with no bar of its own, and it sits between the 7d
# percentage and the 7d pace meter, so the meter stays at the section's right edge.

MU_J_DIR="/tmp/claude-statusline-mujson-$$"
mkdir -p "$MU_J_DIR"
MU_J_FIXTURE="$MU_J_DIR/claude.json"

# $1 = age of the cached fetch in seconds, $2 = the limits[] array,
# $3 = accountUuid on the cached block (default matches the logged-in account).
mu_json_write() {
	local age=$1 limits=$2 cached_uuid=${3:-acct-1} fetched
	fetched=$(( ($(date +%s) - age) * 1000 ))
	cat > "$MU_J_FIXTURE" <<EOF
{
  "oauthAccount": { "organizationType": "claude_max", "accountUuid": "acct-1" },
  "cachedUsageUtilization": {
    "fetchedAtMs": ${fetched},
    "accountUuid": "${cached_uuid}",
    "utilization": { "limits": ${limits} }
  }
}
EOF
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
	limits_json | STATUSLINE_JSON_PATH="$MU_J_FIXTURE" bash "$STATUSLINE" | strip_ansi
}

run_limits_raw() {
	limits_json | STATUSLINE_JSON_PATH="$MU_J_FIXTURE" bash "$STATUSLINE"
}

FABLE_ONLY='[{"kind":"weekly_scoped","group":"weekly","percent":50,"resets_at":"2026-09-06T23:00:00Z","scope":{"model":{"display_name":"Fable"}}}]'

# The bucket renders as initial and percentage, with no bar of its own.
reset_state
mu_json_write 60 "$FABLE_ONLY"
out=$(run_limits)
assert_contains "model bucket renders initial and percentage" "$out" "F 50%"
assert_contains "model bucket follows the 7d limit" "$out" "12% · F 50%"
assert_not_contains "model bucket carries no filled bar" "$out" "F 50% █"
assert_not_contains "model bucket carries no empty bar" "$out" "F 50% ░"

# The shared read must still produce the auth letter.
assert_contains "auth letter survives the shared read" "$out" "1M M "

# Each filter needs its own discriminating entry. The session row is model-scoped
# but not weekly, so only the kind check drops it; the weekly_all row is weekly but
# not model-scoped, so only the scope check drops it. With one entry doing both
# jobs, either filter could be deleted and the test would still pass.
reset_state
mu_json_write 60 '[
  {"kind":"session","group":"session","percent":18},
  {"kind":"session_scoped","group":"session","percent":77,"scope":{"model":{"display_name":"Mythos"}}},
  {"kind":"weekly_all","group":"weekly","percent":9},
  {"kind":"weekly_scoped","group":"weekly","percent":4.7,"scope":{"model":{"display_name":"Fable"}}}
]'
out=$(run_limits)
assert_contains "floors the percentage the way /usage does" "$out" "F 4%"
assert_not_contains "no fractional percentage is rendered" "$out" "F 4.7%"
assert_not_contains "drops a model-scoped entry that is not weekly" "$out" "M 77%"
assert_not_contains "drops a non-weekly entry's percentage" "$out" "77%"
# This one pins the BEHAVIOR, not a single mechanism: the jq scope filter and the
# renderer's empty-name guard (which the trailing newline needs anyway) each drop a
# scopeless entry on their own, so deleting either leaves the test green.
assert_not_contains "a weekly entry with no model scope does not render" "$out" "9%"

# The initial comes from the server's display name, uppercased.
reset_state
mu_json_write 60 '[{"kind":"weekly_scoped","percent":30,"scope":{"model":{"display_name":"mythos"}}}]'
out=$(run_limits)
assert_contains "initial is uppercased from the display name" "$out" "M 30%"

# Every model-scoped bucket renders, in the order the file lists them.
reset_state
mu_json_write 60 '[
  {"kind":"weekly_scoped","percent":50,"scope":{"model":{"display_name":"Fable"}}},
  {"kind":"weekly_scoped","percent":20,"scope":{"model":{"display_name":"Opus"}}}
]'
out=$(run_limits)
assert_contains "buckets keep file order" "$out" "F 50% · O 20%"

# The field sits to the LEFT of the pace meter, so the meter keeps the section's
# right edge. Pinned against a pace case the meter tests already fix: at 65% used
# with the window half-elapsed, linear gamma and an 8-cell meter, the meter is three
# filled cells. The Fable percentage must appear between the 7d number and that bar.
reset_state
mu_json_write 60 "$FABLE_ONLY"
out=$(pace_json 65 302400 \
	| STATUSLINE_JSON_PATH="$MU_J_FIXTURE" STATUSLINE_PACE_GAMMA=1 STATUSLINE_PACE_BAR_WIDTH=8 \
	  bash "$STATUSLINE" | strip_ansi)
assert_contains "the bucket sits between the 7d number and the pace meter" "$out" "65% · F 50% ███░░░░░"

# With no bucket the meter still follows the 7d number directly, so the field's
# absence leaves no gap or stray separator.
reset_state
printf '{"oauthAccount":{"organizationType":"claude_max","accountUuid":"acct-1"}}\n' > "$MU_J_FIXTURE"
out=$(pace_json 65 302400 \
	| STATUSLINE_JSON_PATH="$MU_J_FIXTURE" STATUSLINE_PACE_GAMMA=1 STATUSLINE_PACE_BAR_WIDTH=8 \
	  bash "$STATUSLINE" | strip_ansi)
assert_contains "no bucket leaves the meter against the 7d number" "$out" "65% ███░░░░░"

# No cached usage block, no field. A fresh install has none until the first /usage run.
reset_state
printf '{"oauthAccount":{"organizationType":"claude_max","accountUuid":"acct-1"}}\n' > "$MU_J_FIXTURE"
out=$(run_limits)
assert_not_contains "absent cache block hides the field" "$out" "F "
assert_contains "absent cache block still yields the auth letter" "$out" "1M M "

# A cached block with no model-scoped bucket is not a bucket.
reset_state
mu_json_write 60 '[{"kind":"weekly_all","group":"weekly","percent":3}]'
out=$(run_limits)
assert_not_contains "no model-scoped bucket hides the field" "$out" "F "

# The cached block belongs to one account. After an account switch it describes
# someone else's usage, so it is ignored rather than rendered.
reset_state
mu_json_write 60 "$FABLE_ONLY" "other-account"
out=$(run_limits)
assert_not_contains "a cache block from another account is ignored" "$out" "F 50%"

# Staleness follows Claude Code's own two constants for this cache, not a threshold
# of our choosing. It persists a fresh fetch at most every 5 minutes (Ten=300000),
# and its own reader refuses the block past 1 hour (wen=3600000), so a block older
# than an hour is one Claude Code itself would reject.

# Fresh inside the write throttle: the number alone, no age.
reset_state
mu_json_write 120 "$FABLE_ONLY"
out=$(run_limits)
assert_contains "a fetch inside the write throttle renders bare" "$out" "F 50%"
assert_not_contains "no age is shown while fresh" "$out" "F 50% 2m"

reset_state
mu_json_write 240 "$FABLE_ONLY"
out=$(run_limits)
assert_not_contains "4 minutes old is still bare" "$out" "F 50% 4m"

# Past the write throttle the age rides along, so a number that is not current
# cannot read as current.
reset_state
mu_json_write 360 "$FABLE_ONLY"
out=$(run_limits)
assert_contains "6 minutes old shows its age" "$out" "F 50% 6m"

reset_state
mu_json_write 1800 "$FABLE_ONLY"
out=$(run_limits)
assert_contains "30 minutes old shows its age" "$out" "F 50% 30m"

reset_state
mu_json_write 3000 "$FABLE_ONLY"
out=$(run_limits)
assert_contains "50 minutes old still renders, with its age" "$out" "F 50% 50m"

# Past Claude Code's own 1-hour cutoff the field is gone. Showing it would mean
# displaying a number the writer's own reader discards.
reset_state
mu_json_write 5400 "$FABLE_ONLY"
out=$(run_limits)
assert_not_contains "90 minutes old is hidden" "$out" "F 50%"

reset_state
mu_json_write 604800 "$FABLE_ONLY"
out=$(run_limits)
assert_not_contains "a week old is hidden" "$out" "F 50%"

# The cutoff is overridable, for anyone who wants a different tolerance.
reset_state
mu_json_write 1800 "$FABLE_ONLY"
out=$(STATUSLINE_MODEL_USAGE_MAX_AGE=600 run_limits)
assert_not_contains "a tightened cutoff hides sooner" "$out" "F 50%"

reset_state
mu_json_write 5400 "$FABLE_ONLY"
out=$(STATUSLINE_MODEL_USAGE_MAX_AGE=86400 run_limits)
assert_contains "a loosened cutoff shows longer" "$out" "F 50%"

# The color ladder matches the neighbouring limits: gray under 50, yellow 50-79,
# red at 80 and over.
reset_state
mu_json_write 60 '[{"kind":"weekly_scoped","percent":49,"scope":{"model":{"display_name":"Fable"}}}]'
raw=$(run_limits_raw)
assert_contains "under 50% is normal gray" "$raw" $'\033[38;5;245mF 49%'

reset_state
mu_json_write 60 "$FABLE_ONLY"
raw=$(run_limits_raw)
assert_contains "50% is yellow" "$raw" $'\033[33mF 50%'

reset_state
mu_json_write 60 '[{"kind":"weekly_scoped","percent":80,"scope":{"model":{"display_name":"Fable"}}}]'
raw=$(run_limits_raw)
assert_contains "80% is red" "$raw" $'\033[31mF 80%'

# A session with no plan rate limits (API key, Bedrock, Vertex) has no plan buckets
# either, so the whole section stays absent even with a populated cache block.
reset_state
mu_json_write 60 "$FABLE_ONLY"
out=$(mock_json 100 500 10000 200 200000 \
	| STATUSLINE_JSON_PATH="$MU_J_FIXTURE" bash "$STATUSLINE" | strip_ansi)
assert_not_contains "no plan limits hides the model bucket too" "$out" "F 50%"

rm -rf "$MU_J_DIR"

echo ""
echo "=== Usage-history append creates its own directory ==="

# The history append is what fit-budget.py reads. Its directory is not created by
# anything else, so a machine that has never had it silently lost every line: the
# redirection failed, and `2>/dev/null` sat on printf rather than on the redirect,
# so the shell's error went to the terminal on every single render.

MU_H_HOME="/tmp/claude-statusline-histtest-$$"
rm -rf "$MU_H_HOME"
mkdir -p "$MU_H_HOME"

hist_run() {
	mock_json 100 500 10000 200 200000 \
		| env HOME="$MU_H_HOME" STATUSLINE_JSON_PATH="$AUTH_JSON_DIR/logged-out.json" \
		  bash "$STATUSLINE" > /dev/null 2>"$MU_H_HOME/stderr.txt"
}

reset_state
hist_run
if [ -s "$MU_H_HOME/.claude-statusline/usage-history.jsonl" ]; then
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
	echo "FAIL: the first render creates the usage-history file"
fi

hist_err=$(cat "$MU_H_HOME/stderr.txt" 2>/dev/null)
if [ -z "$hist_err" ]; then
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
	echo "FAIL: a render writes nothing to stderr"
	echo "  got: $hist_err"
fi

# Appending, not truncating: a second render adds a line rather than replacing one.
reset_state
hist_run
hist_lines=$( (wc -l < "$MU_H_HOME/.claude-statusline/usage-history.jsonl" 2>/dev/null || echo 0) | tr -d ' ')
if [ "${hist_lines:-0}" -eq 2 ] 2>/dev/null; then
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
	echo "FAIL: the second render appends (expected 2 lines, got ${hist_lines:-0})"
fi

# Each line is the parseable snapshot fit-budget.py expects.
hist_last=$(tail -1 "$MU_H_HOME/.claude-statusline/usage-history.jsonl" 2>/dev/null || echo "")
if printf '%s' "$hist_last" | jq -e '.session_id and .ts and (.cost_usd != null)' >/dev/null 2>&1; then
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
	echo "FAIL: each history line is a parseable snapshot"
	echo "  got: $hist_last"
fi

# A failing redirect must stay silent. The file itself is made unwritable, not its
# directory: appending to an existing file needs write permission on the FILE, so a
# read-only directory does not fail the redirect and would not exercise this at all.
# The suppression has to sit on the redirect, since the shell reports the failure,
# not printf.
reset_state
chmod 000 "$MU_H_HOME/.claude-statusline/usage-history.jsonl" 2>/dev/null || true
hist_out=$(mock_json 100 500 10000 200 200000 \
	| env HOME="$MU_H_HOME" STATUSLINE_JSON_PATH="$AUTH_JSON_DIR/logged-out.json" \
	  bash "$STATUSLINE" 2>"$MU_H_HOME/stderr2.txt" | strip_ansi)
chmod 644 "$MU_H_HOME/.claude-statusline/usage-history.jsonl" 2>/dev/null || true
assert_contains "an unwritable history file still renders the line" "$hist_out" "200k |"
hist_err2=$(cat "$MU_H_HOME/stderr2.txt" 2>/dev/null || echo "")
if [ -z "$hist_err2" ]; then
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
	echo "FAIL: a failing history write says nothing on stderr"
	echo "  got: $hist_err2"
fi

# The per-session snapshot write carries the same misplaced-suppression hazard, so
# it gets the same check. A directory standing where the file goes makes the `>`
# redirect fail without touching anything else.
reset_state
rm -f "/tmp/claude-usage-${SESSION}.json"
mkdir -p "/tmp/claude-usage-${SESSION}.json"
hist_out=$(mock_json 100 500 10000 200 200000 \
	| env HOME="$MU_H_HOME" STATUSLINE_JSON_PATH="$AUTH_JSON_DIR/logged-out.json" \
	  bash "$STATUSLINE" 2>"$MU_H_HOME/stderr3.txt" | strip_ansi)
rmdir "/tmp/claude-usage-${SESSION}.json" 2>/dev/null || true
assert_contains "a failing snapshot write still renders the line" "$hist_out" "200k |"
hist_err3=$(cat "$MU_H_HOME/stderr3.txt" 2>/dev/null || echo "")
if [ -z "$hist_err3" ]; then
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
	echo "FAIL: a failing snapshot write says nothing on stderr"
	echo "  got: $hist_err3"
fi

rm -rf "$MU_H_HOME"

echo ""
echo "=== The suite does not write to the real home ==="

# Isolation is a property of the harness, not of test discipline: this asserts the
# throwaway HOME is actually in effect, so a render cannot reach the developer's
# own usage history.
reset_state
out=$(run 100 500 10000 200 200000)
if [ "$HOME" = "$TEST_HOME" ]; then PASS=$((PASS + 1)); else
	FAIL=$((FAIL + 1)); echo "FAIL: the suite must run under a throwaway HOME (got $HOME)"; fi
if [ -s "$TEST_HOME/.claude-statusline/usage-history.jsonl" ]; then
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
	echo "FAIL: renders must land their history under the throwaway HOME"
fi

echo ""
echo "=== Per-model bucket: hostile and malformed cached values ==="

# The cached block is data, not code. Three shapes were reaching the render and
# producing a confident wrong answer rather than an absence.

MU_X_DIR="/tmp/claude-statusline-muhostile-$$"
mkdir -p "$MU_X_DIR"
MU_X_FIXTURE="$MU_X_DIR/claude.json"

# $1 = fetch age in seconds, $2 = the limits[] array (raw JSON).
mu_x_write() {
	local age=$1 limits=$2 fetched
	fetched=$(( ($(date +%s) - age) * 1000 ))
	cat > "$MU_X_FIXTURE" <<EOF
{
  "oauthAccount": { "organizationType": "claude_max", "accountUuid": "acct-1" },
  "cachedUsageUtilization": {
    "fetchedAtMs": ${fetched},
    "accountUuid": "acct-1",
    "utilization": { "limits": ${limits} }
  }
}
EOF
}

run_x() {
	limits_json | STATUSLINE_JSON_PATH="$MU_X_FIXTURE" bash "$STATUSLINE" | strip_ansi
}

# A percent that is not a number must drop the bucket, not render as 0%. Rendering
# 0% invents the most reassuring possible value for a number you throttle against,
# which is the opposite of what every adjacent guard in this file does.
for bad in '"21"' 'null' 'true' '[]'; do
	reset_state
	mu_x_write 60 "[{\"kind\":\"weekly_scoped\",\"percent\":${bad},\"scope\":{\"model\":{\"display_name\":\"Fable\"}}}]"
	out=$(run_x)
	assert_not_contains "percent ${bad} does not render as 0%" "$out" "F 0%"
	assert_not_contains "percent ${bad} renders no bucket at all" "$out" " F "
done

# An absent percent key is the same case.
reset_state
mu_x_write 60 '[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}}}]'
out=$(run_x)
assert_not_contains "an absent percent does not render as 0%" "$out" "F 0%"

# A real number still renders, including one above 100. The code does not clamp,
# and it should not: the payload's own 5-hour percentage is observed above 100.
reset_state
mu_x_write 60 '[{"kind":"weekly_scoped","percent":250,"scope":{"model":{"display_name":"Fable"}}}]'
out=$(run_x)
assert_contains "a percent above 100 renders unclamped" "$out" "F 250%"

# The jq read tags three facts onto one newline-delimited channel, and the model
# name is server-supplied. A newline inside it must not be able to start a line the
# loop reads as another tag.

# Forging the auth letter: the fixture's org is claude_max, so the letter is M.
reset_state
mu_x_write 60 '[{"kind":"weekly_scoped","percent":50,"scope":{"model":{"display_name":"Fable\norg:claude_enterprise\nX"}}}]'
out=$(run_x)
assert_contains "a newline in the model name cannot rewrite the auth letter" "$out" "1M M "
assert_not_contains "the injected org value is not adopted" "$out" "1M E "

# Forging the fetch timestamp defeats BOTH staleness halves at once: the field
# would render, and render with no age label, from a two-hour-old block.
reset_state
stamp_fresh=$(( $(date +%s) - 30 ))
mu_x_write 7200 "[{\"kind\":\"weekly_scoped\",\"percent\":99,\"scope\":{\"model\":{\"display_name\":\"Zed\\nfetched:${stamp_fresh}\\nX\"}}},{\"kind\":\"weekly_scoped\",\"percent\":21,\"scope\":{\"model\":{\"display_name\":\"Fable\"}}}]"
out=$(run_x)
assert_not_contains "a newline in the model name cannot forge the fetch time" "$out" "F 21%"

# An escape byte in the model name must not reach the terminal.
reset_state
mu_x_write 60 '[{"kind":"weekly_scoped","percent":50,"scope":{"model":{"display_name":"[5mZed"}}}]'
raw=$(limits_json | STATUSLINE_JSON_PATH="$MU_X_FIXTURE" bash "$STATUSLINE")
if printf '%s' "$raw" | strip_ansi | grep -q $'\033'; then
	FAIL=$((FAIL + 1))
	echo "FAIL: an escape byte from the model name survives into the rendered line"
else
	PASS=$((PASS + 1))
fi

# The initial is derived from alphanumerics only, so punctuation and separators
# cannot survive into it. A name with no alphanumeric character yields no bucket.
reset_state
mu_x_write 60 '[{"kind":"weekly_scoped","percent":50,"scope":{"model":{"display_name":"---"}}}]'
out=$(run_x)
assert_not_contains "a name with no alphanumeric character renders no bucket" "$out" " 50%"

# A non-string display_name must not take down the whole read. The name reaches a
# jq string function, and an unguarded call on a number aborts the entire jq
# program, which would drop the auth letter with it: the blast radius of a bad
# bucket has to stay inside that bucket.
reset_state
mu_x_write 60 '[{"kind":"weekly_scoped","percent":50,"scope":{"model":{"display_name":7}}}]'
out=$(run_x)
assert_not_contains "a numeric display_name renders no bucket" "$out" " 50%"
assert_contains "a numeric display_name leaves the auth letter intact" "$out" "1M M "

# The same holds when one bucket is malformed and another is fine: the good one
# still renders.
reset_state
mu_x_write 60 '[{"kind":"weekly_scoped","percent":50,"scope":{"model":{"display_name":7}}},{"kind":"weekly_scoped","percent":33,"scope":{"model":{"display_name":"Fable"}}}]'
out=$(run_x)
assert_contains "a malformed sibling does not suppress a good bucket" "$out" "F 33%"

# A future timestamp is not trustworthy. Clock skew must not buy the
# reads-as-current outcome the staleness design exists to prevent.
reset_state
mu_x_write -3600 "$FABLE_ONLY"
out=$(run_x)
assert_not_contains "a fetch timestamp in the future is not treated as current" "$out" "F 50%"

rm -rf "$MU_X_DIR"

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All tests passed!" || exit 1
