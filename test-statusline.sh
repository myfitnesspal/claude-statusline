#!/usr/bin/env bash
# Tests for statusline.sh
# Feeds mock JSON to the statusline and verifies output values and colors.

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
echo "=== Message count ==="

# No messages yet: msg should be hidden
reset_state
out=$(run 100 500 10000 200 200000)
assert_not_contains "zero messages hidden" "$out" "msg"

# After 1 round reset: 1msg shown
echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
out=$(run 100 500 10000 200 200000)
assert_contains "1 message shown" "$out" "1msg"

# After another round reset: 2msg
echo "reset" > "/tmp/claude-statusline-newround-${SESSION}"
out=$(run 100 500 10000 200 200000)
assert_contains "messages accumulate" "$out" "2msg"

# Calls within same round don't increment
out=$(run 100 500 10000 200 200000)
assert_contains "same round stays at 2msg" "$out" "2msg"

echo ""
echo "=== Message count colors ==="

# State format v2: 2|round_start_cost|msg_count|last_ts

# Green: 5 messages
reset_state
echo "2|1.50|5|0" > "/tmp/claude-statusline-${SESSION}"
raw=$(run_raw 100 500 10000 200 200000)
assert_contains "5msg is green" "$raw" $'\033[32m5msg'

# Yellow: 10 messages (boundary)
reset_state
echo "2|1.50|10|0" > "/tmp/claude-statusline-${SESSION}"
raw=$(run_raw 100 500 10000 200 200000)
assert_contains "10msg is yellow" "$raw" $'\033[33m10msg'

# Orange: 18 messages (boundary)
reset_state
echo "2|1.50|18|0" > "/tmp/claude-statusline-${SESSION}"
raw=$(run_raw 100 500 10000 200 200000)
assert_contains "18msg is orange" "$raw" $'\033[38;5;208m18msg'

# Red: 24 messages (boundary)
reset_state
echo "2|1.50|24|0" > "/tmp/claude-statusline-${SESSION}"
raw=$(run_raw 100 500 10000 200 200000)
assert_contains "24msg is red" "$raw" $'\033[31m24msg'

echo ""
echo "=== Cache age timer ==="

# Warm cache (< 3 minutes): hidden
# Set last_ts to now (0 seconds ago)
reset_state
now=$(date +%s)
echo "2|1.50|0|${now}" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000)
assert_not_contains "warm cache hidden (recent)" "$out" "·"
# Verify no duration marker appears in context section
# The only · that should appear is section separators, not in context

# At risk (3-5 minutes): yellow, shown
reset_state
stale_ts=$(($(date +%s) - 240))  # 4 minutes ago
echo "2|1.50|0|${stale_ts}" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000)
assert_contains "at-risk cache shows 4m" "$out" "4m"

# Cold (> 5 minutes): red, shown
reset_state
cold_ts=$(($(date +%s) - 420))  # 7 minutes ago
echo "2|1.50|0|${cold_ts}" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000)
assert_contains "cold cache shows 7m" "$out" "7m"

# Cache age color: at-risk is yellow
reset_state
stale_ts=$(($(date +%s) - 240))
echo "2|1.50|0|${stale_ts}" > "/tmp/claude-statusline-${SESSION}"
raw=$(run_raw 100 500 10000 200 200000)
assert_contains "at-risk cache is yellow" "$raw" $'\033[33m4m'

# Cache age color: cold is red
reset_state
cold_ts=$(($(date +%s) - 420))
echo "2|1.50|0|${cold_ts}" > "/tmp/claude-statusline-${SESSION}"
raw=$(run_raw 100 500 10000 200 200000)
assert_contains "cold cache is red" "$raw" $'\033[31m7m'

# First call of session: no previous timestamp, no cache indicator
reset_state
out=$(run 100 500 10000 200 200000)
assert_not_contains "first call: no cache age" "$out" "0m"

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
echo "=== State format v2 migration ==="

# Old v1 state file (5 fields, no version prefix) should be ignored
reset_state
echo "10600|26000|1.50|11000|12200" > "/tmp/claude-statusline-${SESSION}"
out=$(run 100 500 10000 200 200000 1.50)
# Should reset to defaults: round_start_cost=$cost (1.50), msg_count=0
assert_contains "v1 state: round cost resets" "$out" "+\$0.00"
assert_not_contains "v1 state: no msg shown" "$out" "msg"

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All tests passed!" || exit 1
