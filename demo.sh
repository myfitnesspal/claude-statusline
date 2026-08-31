#!/usr/bin/env bash
# Render the README's demo block by running statusline.sh against fixed payloads.
#
# WHY THIS EXISTS: the README used to carry a screenshot, which went stale
# invisibly — it advertised a field the script had stopped emitting, and no text
# sweep could reach the claim because it was in pixels. Generating the block means
# a wrong line shows up in a diff and in the test suite.
#
#   bash demo.sh              print the block to stdout
#   bash demo.sh --update     rewrite the block in README.md in place
#
# Output is deterministic: every reset is a fixed offset from now, and fmt_duration
# renders a fixed offset identically whenever it runs. test-statusline.sh compares
# README.md against this output, so drift fails the suite.
#
# The offsets look arbitrary because they are padded OFF the minute and hour
# boundaries on purpose. statusline.sh samples its own `date +%s`, which can land a
# second after this script's, so a boundary value like 14400 or 5400 would render one
# minute lower on some runs and fail the comparison intermittently. Each offset now
# carries at least 30 seconds of slack before its rendering changes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE="$SCRIPT_DIR/statusline.sh"
README="$SCRIPT_DIR/README.md"
MARK_START="<!-- demo:start -->"
MARK_END="<!-- demo:end -->"

# The developer's own shell exports several of these, and Claude Code exports
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE. A README must show DEFAULT behavior, so they are
# cleared here the same way test-statusline.sh clears them.
unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE STATUSLINE_COMPACT_OVERHEAD
unset STATUSLINE_CTX_BAR_WIDTH STATUSLINE_PACE_BAR_WIDTH
unset STATUSLINE_PACE_TOL STATUSLINE_PACE_GAMMA
unset STATUSLINE_PACE_WORK STATUSLINE_PACE_HORIZON_TS
unset STATUSLINE_PACE_SHOW_ON_PACE STATUSLINE_PACE_SHOW_COLD
unset STATUSLINE_MODEL_USAGE_MAX_AGE ANTHROPIC_API_KEY

# Every render appends a usage snapshot under $HOME, so $HOME is a throwaway here.
# Without it, generating the README would write rows into the real history that
# fit-budget.py reads.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/statusline-demo.XXXXXX") || exit 1
SID_PREFIX="demo-$$-"
# statusline.sh fixes its state path at /tmp/claude-statusline-<session_id>, outside
# $WORK, so the trap clears those by prefix too rather than leaking them on a
# mid-run failure.
trap 'rm -rf "$WORK"; rm -f "/tmp/claude-statusline-${SID_PREFIX}"* "/tmp/claude-usage-${SID_PREFIX}"*' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"

now=$(date +%s)

# A ~/.claude.json fixture: one model bucket, $1 seconds old, at $2 percent.
fixture() {
	local age=$1 pct=$2 path=$3
	cat > "$path" <<EOF
{"oauthAccount":{"organizationType":"claude_max","accountUuid":"a1"},
 "cachedUsageUtilization":{"fetchedAtMs":$(( (now - age) * 1000 )),"accountUuid":"a1",
  "utilization":{"limits":[{"kind":"weekly_scoped","percent":${pct},
   "scope":{"model":{"display_name":"Fable"}}}]}}}
EOF
}

# Build the rate_limits fragment: 5h pct/offset, 7d pct/offset. Empty means omit,
# which is what an API-key or 3P-provider session looks like.
limits() {
	printf ',"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}' \
		"$1" "$((now + $2))" "$3" "$((now + $4))"
}

# $1 comment, $2 model display_name, $3 tokens, $4 window, $5 total cost,
# $6 api ms, $7 exceeds_200k, $8 fixture path, $9 round-cost baseline.
render() {
	local comment=$1 model=$2 tok=$3 win=$4 cost=$5 ms=$6 ex=$7 fx=$8 round=$9
	local sid="${SID_PREFIX}$RANDOM"
	printf '6|%s\n' "$round" > "/tmp/claude-statusline-$sid"
	printf '# %s\n' "$comment"
	printf '{"session_id":"%s","model":{"display_name":"%s"},"workspace":{"current_dir":"/x","project_dir":"/x"},"cost":{"total_cost_usd":%s,"total_api_duration_ms":%s},"exceeds_200k_tokens":%s,"context_window":{"current_usage":{"input_tokens":%s},"context_window_size":%s}%s}' \
		"$sid" "$model" "$cost" "$ms" "$ex" "$tok" "$win" "$LIMITS" \
		| STATUSLINE_JSON_PATH="$fx" bash "$STATUSLINE" 2>/dev/null \
		| sed 's/\x1b\[[0-9;]*m//g'
	printf '\n\n'
	rm -f "/tmp/claude-statusline-$sid" "/tmp/claude-usage-$sid.json"
}

fixture 90 4 "$WORK/fresh.json"
fixture 2430 21 "$WORK/aged.json"
fixture 90 63 "$WORK/hot.json"
printf '{"oauthAccount":{"organizationType":"claude_max","accountUuid":"a1"}}\n' > "$WORK/nobucket.json"

emit_block() {
	# 21% used with 477792s left is r=1, so the pace meter is on-pace and hides.
	LIMITS=$(limits 8 14490 21 477792)
	render "typical session on a 200K window: healthy context, on pace so no meter" \
		"Opus 4.6 (200k)" 34000 200000 0.67 1140000 false "$WORK/fresh.json" 0.62

	# 63% used with 420000s left walls well before the reset, so the meter fills hot.
	LIMITS=$(limits 46 5430 63 420000)
	render "loaded 1M session, past the premium-pricing cliff, burning too fast" \
		"Opus 5 (1M context)" 260000 1000000 8.40 2400000 true "$WORK/hot.json" 8.11

	# aged.json is 40 minutes old, well past the 5-minute write throttle and well
	# inside the 1-hour cutoff. It renders identically to a fresh reading, which is
	# the point: the age is not shown, so this line is what a stale-but-accepted
	# bucket looks like.
	LIMITS=$(limits 71 3230 40 500000)
	render "past the 400K retrieval line, with the bucket and the pace meter both up" \
		"Opus 5 (1M context)" 412000 1000000 14.20 3900000 true "$WORK/aged.json" 13.95

	LIMITS=""
	render "no plan rate limits (API key, Bedrock, Vertex): the whole section is absent" \
		"Sonnet 5 (200k)" 18000 200000 0.04 22000 false "$WORK/nobucket.json" 0.02
}

# Trailing blank line from the last render is dropped so the block ends cleanly.
block=$(emit_block)

if [ "${1:-}" != "--update" ]; then
	printf '%s\n' "$block"
	exit 0
fi

if ! grep -qF "$MARK_START" "$README" || ! grep -qF "$MARK_END" "$README"; then
	printf 'demo.sh: %s / %s markers not found in %s\n' "$MARK_START" "$MARK_END" "$README" >&2
	exit 1
fi

# Replace between the markers, keeping the markers and the fence.
tmp="$README.tmp.$$"
BLOCK="$block" awk -v s="$MARK_START" -v e="$MARK_END" '
	$0 == s { print; print "```"; print ENVIRON["BLOCK"]; print "```"; skip = 1; next }
	$0 == e { skip = 0 }
	!skip   { print }
' "$README" > "$tmp" || { rm -f "$tmp"; exit 1; }
mv -f "$tmp" "$README"
printf 'demo.sh: rewrote the demo block in %s\n' "$README" >&2
