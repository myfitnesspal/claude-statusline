#!/usr/bin/env bash
# Tests for statusline.sh
# Feeds mock JSON to the statusline and verifies output values and colors.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATUSLINE="$SCRIPT_DIR/statusline.sh"

# Ensure env vars don't leak into tests
unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
unset COMPACT_OVERHEAD
unset ANTHROPIC_API_KEY
PASS=0
FAIL=0
SESSION="test-$$"

# Auth fixtures: statusline reads oauthAccount from CLAUDE_JSON_PATH.
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
export CLAUDE_JSON_PATH="$AUTH_JSON_DIR/logged-out.json"

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
	cat <<EOF
{
  "session_id": "${SESSION}",
  "model": { "id": "claude-opus-4-6", "display_name": "Opus 4.6 (1M context)" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test", "added_dirs": [] },
  "cost": { "total_cost_usd": ${cost}, "total_duration_ms": 100000, "total_api_duration_ms": ${api_duration_ms} },
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
# full and gets a ▸ overflow marker. Bars pinned to CTX_BAR_WIDTH=10 (one cell
# per 10%) so expected strings are deterministic regardless of the default.

# Bar replaces the numeric percentage.
# 1M window: cap=400000. 130000/400000 = 32% -> 3 cells.
reset_state
out=$(CTX_BAR_WIDTH=10 run 130000 0 0 0 1000000)
assert_contains "context renders a bar" "$out" "███░░░░░░░"
assert_not_contains "percentage number removed" "$out" "32%"

# Denominator scales with window: same tokens, smaller window -> fuller bar.
# 167000 tokens: 200K window cap=167000 -> 100% (full); 1M window cap=400000 -> 41%.
reset_state
out=$(CTX_BAR_WIDTH=10 run 167000 0 0 0 200000)
assert_contains "200K window: full at compact threshold" "$out" "██████████"
reset_state
out=$(CTX_BAR_WIDTH=10 run 167000 0 0 0 1000000)
assert_contains "1M window: same tokens, partial bar" "$out" "████░░░░░░"
assert_not_contains "1M window: not full" "$out" "██████████"

# The overflow marker (▶) is gated on the RED zone (>= 400K) AND strictly past
# the bar ceiling. It fuses to the full bar (no space) and adds one cell of width.

# Exactly at the ceiling (400K on 1M): full red bar, NO marker yet (not past it).
reset_state
out=$(CTX_BAR_WIDTH=10 run 400000 0 0 0 1000000)
assert_contains "at ceiling: full bar" "$out" "██████████"
assert_not_contains "at ceiling: no marker" "$out" "▶"

# Past the ceiling in the red zone: pegged full with the fused ▶ marker.
reset_state
out=$(CTX_BAR_WIDTH=10 run 410000 0 0 0 1000000)
assert_contains "past ceiling (red): full bar + fused marker" "$out" "██████████▶"

# Full bar but NOT red (orange, 399K on 1M): no marker — marker is red-gated.
reset_state
raw=$(CTX_BAR_WIDTH=10 run_raw 399000 0 0 0 1000000)
assert_contains "orange full bar is orange" "$raw" $'\033[38;5;208m399k'
assert_contains "orange full bar is full" "$raw" "██████████"
assert_not_contains "orange full bar: no marker (not red)" "$raw" "▶"

# Small window: ceiling is the compact threshold (< 400K) and 400K is unreachable,
# so overflow pegs the bar full but shows NO marker (yellow, never red).
reset_state
raw=$(CTX_BAR_WIDTH=10 run_raw 180000 0 0 0 200000)
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
out=$(CTX_BAR_WIDTH=10 run 130000 0 0 0 200000)
assert_contains "default denominator: 8-cell bar" "$out" "████████░░"
assert_not_contains "default denominator: no marker" "$out" "▶"
reset_state
out=$(CTX_BAR_WIDTH=10 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 run 130000 0 0 0 200000)
assert_contains "override=50 shrinks denominator, pegs full" "$out" "██████████"
assert_not_contains "override=50: still no marker on small window" "$out" "▶"

# COMPACT_OVERHEAD shifts the denominator too: overhead=100000 on 200K -> cap=100000.
reset_state
out=$(CTX_BAR_WIDTH=10 COMPACT_OVERHEAD=100000 run 130000 0 0 0 200000)
assert_contains "COMPACT_OVERHEAD shrinks denominator, pegs full" "$out" "██████████"

# Override beats COMPACT_OVERHEAD: override=50 (cap=100000) pegs full; overhead=0
# would give cap=200000 -> 65% (a 7-cell bar), so a full bar proves override won.
reset_state
out=$(CTX_BAR_WIDTH=10 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 COMPACT_OVERHEAD=0 run 130000 0 0 0 200000)
assert_contains "override beats COMPACT_OVERHEAD" "$out" "██████████"
assert_not_contains "override beats COMPACT_OVERHEAD (not overhead's bar)" "$out" "███████░░░"

echo ""
echo "=== Bar width knobs ==="

# CTX_BAR_WIDTH changes the context bar length. 32% at width 4 -> 1 cell.
reset_state
out=$(CTX_BAR_WIDTH=4 run 130000 0 0 0 1000000)
assert_contains "CTX_BAR_WIDTH=4 yields a 4-cell bar" "$out" "█░░░"
assert_not_contains "CTX_BAR_WIDTH=4 is not the default width" "$out" "██████████"

# PACE_BAR_WIDTH changes the 7d throttle-meter length. Build a payload with 5h+7d
# limits, window half-elapsed at 50% used -> on pace -> empty meter of the given width.
reset_state
_now=$(date +%s); _r5=$((_now + 3600)); _r7=$((_now + 302400))
_pace_json='{"session_id":"'"${SESSION}"'","model":{"display_name":"Opus 4.6 (1M context)"},"workspace":{"current_dir":"/x","project_dir":"/x"},"cost":{"total_cost_usd":1.50,"total_api_duration_ms":60000},"context_window":{"current_usage":{"input_tokens":10000},"context_window_size":1000000},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":'"${_r5}"'},"seven_day":{"used_percentage":50,"resets_at":'"${_r7}"'}}}'
out=$(echo "$_pace_json" | PACE_BAR_WIDTH=8 bash "$STATUSLINE" | strip_ansi)
assert_contains "PACE_BAR_WIDTH=8 yields an 8-cell meter" "$out" "░░░░░░░░"

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
echo "=== Cache age timer ==="

# Cache age measures IDLE time since the model last hit the API, detected by
# total_api_duration_ms changing between renders. State v4:
#   4|round_start_cost|last_activity_ts|last_api_ms
# The run helper's default api_duration_ms is 60000; the fixtures below match it
# so "no activity" means api_ms unchanged.

# Warm cache: last activity was just now, api_ms unchanged -> hidden.
reset_state
now=$(date +%s)
echo "4|1.50|${now}|60000" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50 60000)
assert_not_contains "warm cache hidden (recent)" "$out" "·"

# At risk (3-5 minutes idle, no new API activity): yellow, shown
reset_state
stale_ts=$(($(date +%s) - 240))  # last activity 4 minutes ago
echo "4|1.50|${stale_ts}|60000" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50 60000)
assert_contains "at-risk cache shows 4m" "$out" "4m"

# Cold (> 5 minutes idle): red, shown
reset_state
cold_ts=$(($(date +%s) - 420))  # last activity 7 minutes ago
echo "4|1.50|${cold_ts}|60000" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50 60000)
assert_contains "cold cache shows 7m" "$out" "7m"

# Anti-flash: last render was long ago, BUT the model just did API work
# (api_ms grew). The gap was busy time, not idle time -> hidden, no flash.
# This is the bug fix: a long turn must not flash a stale indicator at its end.
reset_state
stale_ts=$(($(date +%s) - 240))
echo "4|1.50|${stale_ts}|60000" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50 120000)  # api_ms grew 60000 -> 120000
assert_not_contains "active turn does not flash stale (age hidden)" "$out" "4m"

# Cache age color: at-risk is yellow
reset_state
stale_ts=$(($(date +%s) - 240))
echo "4|1.50|${stale_ts}|60000" > "/tmp/claude-statusline-${SESSION}"
raw=$(run_raw 100 500 10000 200 200000 1.50 60000)
assert_contains "at-risk cache is yellow" "$raw" $'\033[33m4m'

# Cache age color: cold is red
reset_state
cold_ts=$(($(date +%s) - 420))
echo "4|1.50|${cold_ts}|60000" > "/tmp/claude-statusline-${SESSION}"
raw=$(run_raw 100 500 10000 200 200000 1.50 60000)
assert_contains "cold cache is red" "$raw" $'\033[31m7m'

# First call of session: no previous timestamp, no cache indicator
reset_state
out=$(run 100 500 10000 200 200000)
assert_not_contains "first call: no cache age" "$out" "0m"

echo ""
echo "=== Cache cold latch (persist through a human turn) ==="

# When a human turn starts with an EXPIRED cache (idle >= 5m), the cold indicator
# must stay visible for the whole turn — the turn's own API activity would
# otherwise reset cache_age to 0 and flash the indicator away. State v5 field 5 is
# the latched idle gap. Fixtures use api_ms=60000 as the pre-turn baseline.

# Turn starts expired (idle 800s = 13m): latched, shown; persists once the model
# starts working in the same turn (api_ms grows -> live cache_age would be 0).
reset_state
_ago=$(($(date +%s) - 800))
echo "5|1.50|${_ago}|60000|0" > "/tmp/claude-statusline-${SESSION}"
echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50 60000)
assert_contains "expired cache shown at turn start" "$out" "13m"
out=$(run 100 500 10000 200 200000 1.50 120000)  # model now active this turn
assert_contains "expired cache persists through the turn" "$out" "13m"

# Next turn starts warm (idle 10s): the stale latch is cleared, indicator hidden.
reset_state
_recent=$(($(date +%s) - 10))
echo "5|1.50|${_recent}|60000|800" > "/tmp/claude-statusline-${SESSION}"
echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50 60000)
assert_not_contains "warm turn clears the cold latch" "$out" "13m"
assert_not_contains "warm turn shows no cache indicator" "$out" "·"

# At-risk (yellow, 240s = 4m) is NOT expired, so it does NOT latch: it shows at
# turn start but clears once the turn's activity resets the idle clock.
reset_state
_ago=$(($(date +%s) - 240))
echo "5|1.50|${_ago}|60000|0" > "/tmp/claude-statusline-${SESSION}"
echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50 60000)
assert_contains "at-risk shown at turn start" "$out" "4m"
out=$(run 100 500 10000 200 200000 1.50 120000)  # activity, not latched
assert_not_contains "at-risk not latched (clears on activity)" "$out" "4m"

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

echo ""
echo "=== Auth mode indicator ==="

# ANTHROPIC_API_KEY set: K shown after model, regardless of login state
reset_state
out=$(ANTHROPIC_API_KEY="sk-ant-test" CLAUDE_JSON_PATH="$AUTH_JSON_DIR/enterprise.json" run 100 500 10000 200 200000)
assert_contains "API key session shows K" "$out" "200k K "

# Enterprise claude.ai login: E
reset_state
out=$(CLAUDE_JSON_PATH="$AUTH_JSON_DIR/enterprise.json" run 100 500 10000 200 200000)
assert_contains "Enterprise login shows E" "$out" "200k E "

# Max subscription: M
reset_state
out=$(CLAUDE_JSON_PATH="$AUTH_JSON_DIR/max.json" run 100 500 10000 200 200000)
assert_contains "Max login shows M" "$out" "200k M "

# Pro subscription: P
reset_state
out=$(CLAUDE_JSON_PATH="$AUTH_JSON_DIR/pro.json" run 100 500 10000 200 200000)
assert_contains "Pro login shows P" "$out" "200k P "

# Team subscription: T
reset_state
out=$(CLAUDE_JSON_PATH="$AUTH_JSON_DIR/team.json" run 100 500 10000 200 200000)
assert_contains "Team login shows T" "$out" "200k T "

# Unknown/other OAuth org (e.g. console): A fallback
reset_state
out=$(CLAUDE_JSON_PATH="$AUTH_JSON_DIR/console.json" run 100 500 10000 200 200000)
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
raw=$(CLAUDE_JSON_PATH="$AUTH_JSON_DIR/enterprise.json" run_raw 100 500 10000 200 200000)
assert_contains "auth letter uncolored" "$raw" "200k E "

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All tests passed!" || exit 1
