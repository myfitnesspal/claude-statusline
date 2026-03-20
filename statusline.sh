#!/usr/bin/env bash
# Claude Code Status Line
# Line 1: [model] dir | ctx: N% | $cost
# Line 2: ctx: Nk (+Nk) | out: N
#
# Context % is color-coded: green < 50%, yellow 50-79%, red 80%+
# Prompt size (+N) is color-coded: green < 1k, yellow 1-5k, red > 5k
#
# Requires: jq

input=$(cat)

# Extract fields
model=$(echo "$input" | jq -r '.model.display_name // ""')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
dir="${cwd##*/}"
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
uncached=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
out_tokens=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0')

# Colors
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
NORMAL='\033[38;5;245m'
RESET='\033[0m'

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

# Color for used_percentage
if [ "$used_pct" -ge 80 ]; then
	pct_color="$RED"
elif [ "$used_pct" -ge 50 ]; then
	pct_color="$YELLOW"
else
	pct_color="$GREEN"
fi

# Color for cache_creation (prompt size)
if [ "$cache_create" -ge 5000 ]; then
	new_color="$RED"
elif [ "$cache_create" -ge 1000 ]; then
	new_color="$YELLOW"
else
	new_color="$GREEN"
fi

# Format cost
cost_fmt=$(printf '$%.2f' "$cost")

# Total context = cache_read + cache_create + uncached input
ctx_total=$((cache_read + cache_create + uncached))

# Line 1: persistent info
printf '%b' "${NORMAL}[$model] $dir | ${pct_color}ctx: ${used_pct}%${NORMAL} | ${NORMAL}${cost_fmt}${RESET}"
echo

# Line 2: last round token stats (skip if no API call yet)
if [ "$ctx_total" -gt 0 ]; then
	printf '%b' "${NORMAL}ctx: $(fmt_tokens "$ctx_total") (${new_color}+$(fmt_tokens "$cache_create")${NORMAL}) | out: $(fmt_tokens "$out_tokens")${RESET}"
fi
