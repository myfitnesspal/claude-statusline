#!/usr/bin/env bash
# Claude Code Status Line
# Line 1: [model] dir | $cost
# Line 2: ctx: N% | in: Nk (N.N%) | out: Nk (N.N%) (per-round, monotonically growing)
#
# Context % is color-coded: green < 50%, yellow 50-79%, red 80%+
# Per-round input is color-coded: green < 1k, yellow 1-5k, red > 5k
#
# Requires: jq
# Requires: UserPromptSubmit hook running round-reset.sh

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // "default"')
STATE_FILE="/tmp/claude-statusline-${session_id}"
NEWROUND_FILE="/tmp/claude-statusline-newround-${session_id}"

# Extract fields
model=$(echo "$input" | jq -r '.model.display_name // ""')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // ""')
agent_name=$(echo "$input" | jq -r '.agent.name // empty')
worktree_name=$(echo "$input" | jq -r '.worktree.name // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

# Current context window size (total tokens in context right now)
ctx_tokens=$(echo "$input" | jq -r '
	((.context_window.current_usage.input_tokens // 0) +
	(.context_window.current_usage.cache_creation_input_tokens // 0) +
	(.context_window.current_usage.cache_read_input_tokens // 0))
')

# Max context window (derived from current usage and percentage)
if [ "$used_pct" -gt 0 ]; then
	ctx_max=$((ctx_tokens * 100 / used_pct))
else
	ctx_max=0
fi

# Per-call tokens
call_fresh=$(echo "$input" | jq -r '
	(.context_window.current_usage.cache_creation_input_tokens // 0) +
	(.context_window.current_usage.input_tokens // 0)
')
call_out=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0')

# Colors
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
NORMAL='\033[38;5;245m'
RESET='\033[0m'

# Format tokens as percentage of context window (e.g. "0.6%")
fmt_pct() {
	local n=$1
	if [ "$ctx_max" -le 0 ]; then
		printf '?%%'
		return
	fi
	local whole=$((n * 100 / ctx_max))
	local frac=$(( (n * 1000 / ctx_max) % 10 ))
	printf '%s.%s%%' "$whole" "$frac"
}

# Human-friendly token formatting (1234 -> 1.2k, 53412 -> 53.4k)
fmt_tokens() {
	local n=$1
	if [ "$n" -ge 1000000 ]; then
		printf '%s.%sM' "$((n / 1000000))" "$(( (n % 1000000) / 100000 ))"
	elif [ "$n" -ge 1000 ]; then
		printf '%s.%sk' "$((n / 1000))" "$(( (n % 1000) / 100 ))"
	else
		printf '%s' "$n"
	fi
}

# State format: round_in_accum|round_out_accum
round_in=0
round_out=0
if [ -f "$STATE_FILE" ]; then
	IFS='|' read -r round_in round_out < "$STATE_FILE"
fi

# If UserPromptSubmit hook signaled a new round, reset accumulators
if [ -f "$NEWROUND_FILE" ]; then
	round_in=0
	round_out=0
	rm -f "$NEWROUND_FILE"
fi

# Accumulate this call's tokens
round_in=$((round_in + call_fresh))
round_out=$((round_out + call_out))

# Save state
echo "${round_in}|${round_out}" > "$STATE_FILE"

# Color for used_percentage
if [ "$used_pct" -ge 80 ]; then
	pct_color="$RED"
elif [ "$used_pct" -ge 50 ]; then
	pct_color="$YELLOW"
else
	pct_color="$GREEN"
fi

# Color for per-round input
if [ "$round_in" -ge 20000 ]; then
	in_color="$RED"
elif [ "$round_in" -ge 5000 ]; then
	in_color="$YELLOW"
else
	in_color="$GREEN"
fi

# Format cost
cost_fmt=$(printf '$%.2f' "$cost")

# Line 1: persistent info
# Single line: model dir | ctx: 53.4k (7%) | in: 1.2k | out: 354 | $2.50
# Shorten model name (e.g. "Opus 4.6 (1M context)" -> "Opus 4.6")
short_model=$(echo "$model" | sed 's/ (.*)//')

# Show dir/agent/worktree only when context differs from project root
location=""
[ -n "$agent_name" ] && location="${agent_name}"
[ -n "$worktree_name" ] && location="${location:+${location} }${worktree_name}"
[ "$cwd" != "$project_dir" ] && [ -z "$worktree_name" ] && location="${cwd##*/}"

parts="${NORMAL}${short_model}"
[ -n "$location" ] && parts="${parts} ${location}"
if [ "$round_in" -gt 0 ] || [ "$round_out" -gt 0 ]; then
	parts="${parts} | ${in_color}↑$(fmt_tokens "$round_in") $(fmt_pct "$round_in")${NORMAL} ↓$(fmt_tokens "$round_out") $(fmt_pct "$round_out")"
fi
parts="${parts} ${pct_color}$(fmt_tokens "$ctx_tokens") (${used_pct}%)${NORMAL}"
parts="${parts} | ${cost_fmt}${RESET}"
printf '%b' "$parts"
