#!/usr/bin/env bash
# Tests for statusline.sh context calculations
# Feeds mock JSON to the statusline and verifies output values.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATUSLINE="$SCRIPT_DIR/statusline.sh"
PASS=0
FAIL=0
SESSION="test-$$"

# Clean up state files on exit
cleanup() {
	rm -f "/tmp/claude-statusline-${SESSION}"
	rm -f "/tmp/claude-statusline-newround-${SESSION}"
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

echo ""
echo "=== Compact threshold ==="

# compact_threshold = ctx_max - 33000
# With 200K window: threshold = 167000
# compact_pct = 10600 * 100 / 167000 = 6%
reset_state
out=$(run 100 500 10000 200 200000)
assert_contains "compact_pct with 200K window" "$out" "6%"

# With 1M window: threshold = 967000
# compact_pct = 10600 * 100 / 967000 = 1%
reset_state
out=$(run 100 500 10000 200 1000000)
assert_contains "compact_pct with 1M window" "$out" "1%"

# Higher usage: 500 + 5000 + 160000 = 165500
# compact_pct = 165500 * 100 / 167000 = 99%
reset_state
out=$(run 500 5000 160000 200 200000)
assert_contains "compact_pct near limit" "$out" "99%"

echo ""
echo "=== CLAUDE_AUTOCOMPACT_PCT_OVERRIDE ==="

# With override=85, threshold = 200000 * 85 / 100 = 170000
# ctx_tokens = 10600, compact_pct = 10600 * 100 / 170000 = 6%
reset_state
out=$(CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=85 run 100 500 10000 200 200000)
assert_contains "override 85% with 200K window" "$out" "6%"

# With override=50, threshold = 200000 * 50 / 100 = 100000
# ctx_tokens = 10600, compact_pct = 10600 * 100 / 100000 = 10%
reset_state
out=$(CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 run 100 500 10000 200 200000)
assert_contains "override 50% shifts threshold" "$out" "10%"

# With override=97, threshold = 1000000 * 97 / 100 = 970000
# ctx_tokens = 10600, compact_pct = 10600 * 100 / 970000 = 1%
reset_state
out=$(CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=97 run 100 500 10000 200 1000000)
assert_contains "override 97% with 1M window" "$out" "1%"

# Override takes precedence over COMPACT_OVERHEAD
reset_state
out=$(CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 COMPACT_OVERHEAD=1000 run 100 500 10000 200 200000)
# threshold = 100000 (from override), NOT 199000 (from overhead)
# compact_pct = 10600 * 100 / 100000 = 10%
assert_contains "override beats COMPACT_OVERHEAD" "$out" "10%"

echo ""
echo "=== Per-round input delta ==="

# First call: round_start_ctx = ctx_tokens, so round_in = 0
reset_state
out=$(run 100 500 10000 200 200000)
assert_contains "first call shows zero round delta" "$out" "↑0 0.0%"

# Second call with more tokens: ctx_tokens grows
# Call 1: ctx_tokens = 10600
# Call 2: ctx_tokens = 1000 + 5000 + 20000 = 26000
# round_in = 26000 - 10600 = 15400 = 15.4k
out=$(run 1000 5000 20000 200 200000)
assert_contains "second call shows input delta" "$out" "↑15.4k"

echo ""
echo "=== New round resets ==="

# Signal new round, then call — should reset baseline
# Previous ctx_tokens was 26000 (from state file's last_ctx)
echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
# New call: ctx_tokens = 500 + 3000 + 30000 = 33500
# round_in = 33500 - 26000 = 7500 = 7.5k
out=$(run 500 3000 30000 200 200000)
assert_contains "new round resets baseline" "$out" "↑7.5k"

echo ""
echo "=== Context shrinks after compaction ==="

# After compaction, ctx_tokens drops. round_in should clamp to 0
# Current state has round_start_ctx from previous call
# New call with small ctx: 50 + 200 + 5000 = 5250
echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
out=$(run 50 200 5000 100 200000)
# round_start = last_ctx from state. Now ctx < start, so round_in = 0
# After another call with even less tokens:
out=$(run 10 100 2000 100 200000)
# ctx_tokens = 2110, round_start was 5250, delta is negative, clamped to 0
assert_contains "compaction clamps round_in to 0" "$out" "↑0 0.0%"

echo ""
echo "=== Cache hit percentage ==="

# cache_read = 10000, ctx_tokens = 10600
# cache_pct = 10000 * 100 / 10600 = 94%
# >= 85% so should NOT appear (hidden when healthy)
reset_state
out=$(run 100 500 10000 200 200000)
assert_not_contains "high cache hit hidden" "$out" "94%"

# Low cache: cache_read = 1000, ctx_tokens = 100 + 500 + 1000 = 1600
# cache_pct = 1000 * 100 / 1600 = 62%
# < 85% so should appear
reset_state
out=$(run 100 500 1000 200 200000)
assert_contains "low cache hit shown" "$out" "62%"

# Very low cache: cache_read = 0, ctx_tokens = 100 + 500 + 0 = 600
# cache_pct = 0%
reset_state
out=$(run 100 500 0 200 200000)
assert_contains "zero cache hit shown" "$out" "0%"

# Round-level accumulation: bad cache persists even if next call is good
# Call 1: cache_read=1000, ctx_tokens=1600 (62% per-call)
# Call 2: cache_read=10000, ctx_tokens=10600 (94% per-call — would hide if per-call)
# Round total: cache_read=11000, total=12200, round_cache_pct=90% — hidden (healthy)
reset_state
out=$(run 100 500 1000 200 200000)
assert_contains "round cache: first call bad" "$out" "62%"
out=$(run 100 500 10000 200 200000)
# Round accumulated: 11000/12200 = 90% — healthy, should be hidden
assert_not_contains "round cache: good round hides warning" "$out" "62%"

# Round-level: persistent bad cache across round
# Call 1: cache_read=500, ctx_tokens=1100 (45%)
# Call 2: cache_read=2000, ctx_tokens=3100 (64%)
# Round total: cache_read=2500, total=4200, round_cache_pct=59%
reset_state
out=$(run 100 500 500 200 200000)
assert_contains "round cache: call 1 bad" "$out" "45%"
out=$(run 100 1000 2000 200 200000)
# Per-call would show 64%, but round total is 2500/4200 = 59%
assert_contains "round cache: accumulated across round" "$out" "59%"

# New round resets cache accumulators
echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
out=$(run 100 500 10000 200 200000)
# Fresh round: 10000/10600 = 94% — hidden
assert_not_contains "round cache: reset clears accumulators" "$out" "94%"

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
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All tests passed!" || exit 1
