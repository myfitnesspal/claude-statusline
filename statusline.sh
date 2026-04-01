#!/usr/bin/env bash
# Claude Code Status Line
# [model] dir | ↑in ↓out ctx | 2h14m:N% 3d5h:N%
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
# Rate limits (Pro/Max subscribers only)
limit_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' | cut -d. -f1)
limit_5h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
limit_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | cut -d. -f1)
limit_7d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
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

# Format duration from seconds (e.g. 3661 -> "1h1m", 90 -> "1m", 86400 -> "1d")
fmt_duration() {
	local secs=$1
	if [ "$secs" -le 0 ]; then
		printf '<1m'
		return
	fi
	local days=$((secs / 86400))
	local hours=$(( (secs % 86400) / 3600 ))
	local mins=$(( (secs % 3600) / 60 ))
	if [ "$days" -gt 0 ]; then
		printf '%dd%dh' "$days" "$hours"
	elif [ "$hours" -gt 0 ]; then
		printf '%dh%dm' "$hours" "$mins"
	else
		printf '%dm' "$mins"
	fi
}

# Format rate limits with color coding and time remaining
fmt_limit() {
	local pct=$1
	local reset_ts=$2
	if [ -z "$pct" ]; then
		return
	fi
	local color="$GREEN"
	if [ "$pct" -ge 80 ]; then
		color="$RED"
	elif [ "$pct" -ge 50 ]; then
		color="$YELLOW"
	fi
	local label=""
	if [ -n "$reset_ts" ]; then
		local now
		now=$(date +%s)
		local remaining=$((reset_ts - now))
		label=$(fmt_duration "$remaining")
	else
		label="?"
	fi
	printf '%b%s:%s%%%b' "$color" "$label" "$pct" "$NORMAL"
}

# Shorten model name (e.g. "Opus 4.6 (1M context)" -> "Opus 4.6")
short_model=$(echo "$model" | sed 's/ (.*)//')

# Show dir/agent/worktree only when context differs from project root
location=""
[ -n "$agent_name" ] && location="${agent_name}"
[ -n "$worktree_name" ] && location="${location:+${location} }${worktree_name}"
[ "$cwd" != "$project_dir" ] && [ -z "$worktree_name" ] && location="${cwd##*/}"

# Subagent governance status (optional, no-op if not installed)
sa_status=""
if [ -f "$HOME/src/claude-config/hooks/subagent-status.sh" ]; then
	sa_state_file="/tmp/claude-subagent-state-${session_id}"
	if [ -f "$sa_state_file" ]; then
		if grep -q "^disabled$" "$sa_state_file" 2>/dev/null; then
			sa_status="${NORMAL}[sa:off]"
		else
			sa_status="${GREEN}[sa:on]"
		fi
	elif [ -f "$HOME/src/claude-config/subagents-disabled" ]; then
		sa_status="${NORMAL}[sa:off]"
	else
		sa_status="${GREEN}[sa:on]"
	fi
fi

parts="${NORMAL}${short_model}"
[ -n "$location" ] && parts="${parts} ${location}"
[ -n "$sa_status" ] && parts="${parts} ${sa_status}${NORMAL}"
parts="${parts} |"
if [ "$round_in" -gt 0 ] || [ "$round_out" -gt 0 ]; then
	parts="${parts} ${in_color}↑$(fmt_tokens "$round_in") ($(fmt_pct "$round_in"))${NORMAL} ↓$(fmt_tokens "$round_out") ($(fmt_pct "$round_out"))"
fi
parts="${parts} ${pct_color}$(fmt_tokens "$ctx_tokens") (${used_pct}%)${NORMAL}"
cost_fmt=$(printf '$%.2f' "$cost")
limit_parts=""
if [ -n "$limit_5h" ]; then
	limit_parts="$(fmt_limit "$limit_5h" "$limit_5h_reset")"
	[ -n "$limit_7d" ] && limit_parts="${limit_parts} $(fmt_limit "$limit_7d" "$limit_7d_reset")"
	parts="${parts} | ${limit_parts}"
fi
parts="${parts} | ${cost_fmt}${RESET}"
printf '%b' "$parts"
