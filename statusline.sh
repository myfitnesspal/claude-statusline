#!/usr/bin/env bash
# Claude Code Status Line
# [model] dir | ↑in ↓out ctx | 2h14m:N% 3d5h:N%
#
# Context % is relative to auto-compact threshold, color-coded: green < 50%, yellow 50-79%, red 80%+
# Per-round input is color-coded by % of compact threshold: green < 2%, yellow 2-5%, red > 5%
# Cache hit % is color-coded: green >= 85%, yellow 50-84%, red < 50%
#
# Requires: jq
# Requires: UserPromptSubmit hook running round-reset.sh

input=$(cat)
# Extract all fields in a single jq call (one per line)
_i=0 _f=()
while IFS= read -r _line; do _f[$((_i++))]=$_line; done < <(echo "$input" | jq -r '
	(.context_window.current_usage) as $u |
	(.session_id // "default"),
	(.model.display_name // ""),
	(.workspace.current_dir // .cwd // ""),
	(.workspace.project_dir // ""),
	(.agent.name // ""),
	(.worktree.name // ""),
	(.rate_limits.five_hour.used_percentage // "" | if type == "number" then floor else . end),
	(.rate_limits.five_hour.resets_at // ""),
	(.rate_limits.seven_day.used_percentage // "" | if type == "number" then floor else . end),
	(.rate_limits.seven_day.resets_at // ""),
	(.cost.total_cost_usd // 0),
	(($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)),
	(.context_window.context_window_size // 0),
	($u.cache_read_input_tokens // 0),
	(.cost.total_api_duration_ms // 0)
')
session_id=${_f[0]}  model=${_f[1]}  cwd=${_f[2]}  project_dir=${_f[3]}
agent_name=${_f[4]}  worktree_name=${_f[5]}
limit_5h=${_f[6]}  limit_5h_reset=${_f[7]}  limit_7d=${_f[8]}  limit_7d_reset=${_f[9]}
cost=${_f[10]}  ctx_tokens=${_f[11]}  ctx_max=${_f[12]}  cache_read=${_f[13]}  api_ms=${_f[14]}
STATE_FILE="/tmp/claude-statusline-${session_id}"
NEWROUND_FILE="/tmp/claude-statusline-newround-${session_id}"

# Auto-compact threshold: the token count that triggers compaction.
# If CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is set (e.g. 85), use it as the threshold percentage.
# Otherwise, approximate: contextWindow - COMPACT_OVERHEAD (default 33000).
if [ -n "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}" ]; then
	compact_threshold=$((ctx_max * CLAUDE_AUTOCOMPACT_PCT_OVERRIDE / 100))
else
	compact_overhead=${COMPACT_OVERHEAD:-33000}
	compact_threshold=$((ctx_max - compact_overhead))
fi
[ "$compact_threshold" -le 0 ] && compact_threshold=1


# Colors
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
NORMAL='\033[38;5;245m'
RESET='\033[0m'

# Format tokens as percentage of compact threshold (e.g. "0.6%")
fmt_pct() {
	local n=$1
	local whole=$((n * 100 / compact_threshold))
	local frac=$(( (n * 1000 / compact_threshold) % 10 ))
	printf '%s.%s%%' "$whole" "$frac"
}

# Human-friendly token formatting (1234 -> 1.2k, 200000 -> 200k, 1000000 -> 1M)
fmt_tokens() {
	local n=$1
	if [ "$n" -ge 1000000 ]; then
		local major=$((n / 1000000)) minor=$(( (n % 1000000) / 100000 ))
		if [ "$minor" -eq 0 ]; then printf '%sM' "$major"
		else printf '%s.%sM' "$major" "$minor"; fi
	elif [ "$n" -ge 1000 ]; then
		local major=$((n / 1000)) minor=$(( (n % 1000) / 100 ))
		if [ "$minor" -eq 0 ]; then printf '%sk' "$major"
		else printf '%s.%sk' "$major" "$minor"; fi
	else
		printf '%s' "$n"
	fi
}

# State format: round_start_ctx|last_ctx|round_start_cost|round_cache_read|round_call_tokens
round_start_ctx=$ctx_tokens
last_ctx=$ctx_tokens
round_start_cost=$cost
round_cache_read=0
round_call_tokens=0
if [ -f "$STATE_FILE" ]; then
	IFS='|' read -r round_start_ctx last_ctx round_start_cost round_cache_read round_call_tokens < "$STATE_FILE"
fi

# If UserPromptSubmit hook signaled a new round, use last known ctx as baseline
if [ -f "$NEWROUND_FILE" ]; then
	round_start_ctx=$last_ctx
	round_start_cost=$cost
	round_cache_read=0
	round_call_tokens=0
	rm -f "$NEWROUND_FILE"
fi

# Accumulate cache stats for the round
round_cache_read=$((round_cache_read + cache_read))
round_call_tokens=$((round_call_tokens + ctx_tokens))

# Input delta = context growth since round start (not accumulated per-call)
round_in=$((ctx_tokens - round_start_ctx))
[ "$round_in" -lt 0 ] && round_in=0  # handle compaction

# Save state
echo "${round_start_ctx}|${ctx_tokens}|${round_start_cost}|${round_cache_read}|${round_call_tokens}" > "$STATE_FILE"

# Color for compact percentage (how close to auto-compact trigger)
compact_pct=$((ctx_tokens * 100 / compact_threshold))
if [ "$compact_pct" -ge 80 ]; then
	pct_color="$RED"
elif [ "$compact_pct" -ge 50 ]; then
	pct_color="$YELLOW"
else
	pct_color="$GREEN"
fi

# Color for per-round input (relative to compact threshold: green < 2%, yellow 2-5%, red > 5%)
round_in_pct=$((round_in * 100 / compact_threshold))
if [ "$round_in_pct" -ge 5 ]; then
	in_color="$RED"
elif [ "$round_in_pct" -ge 2 ]; then
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
	printf '%b%s %s%%%b' "$color" "$label" "$pct" "$NORMAL"
}

# Shorten model name, append context size (e.g. "Opus 4.6 (1M context)" -> "O4.6·1M")
short_model="${model%% (*}"
short_model="${short_model/Opus /O}"
short_model="${short_model/Sonnet /S}"
short_model="${short_model/Haiku /H}"
short_model="${short_model} $(fmt_tokens "$ctx_max")"

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
parts="${parts} ${in_color}↑$(fmt_tokens "$round_in") $(fmt_pct "$round_in")${NORMAL} ·"
# Cache hit percentage (accumulated across the round)
if [ "$round_call_tokens" -gt 0 ]; then
	cache_pct=$((round_cache_read * 100 / round_call_tokens))
else
	cache_pct=0
fi
# Color for cache hit rate (inverted: high is good)
if [ "$cache_pct" -ge 85 ]; then
	cache_color="$GREEN"
elif [ "$cache_pct" -ge 50 ]; then
	cache_color="$YELLOW"
else
	cache_color="$RED"
fi
cache_part=""
if [ "$ctx_tokens" -gt 0 ] && [ "$cache_pct" -lt 85 ]; then
	cache_part=" · ${cache_color}${cache_pct}%${NORMAL}"
fi
parts="${parts} ${pct_color}$(fmt_tokens "$ctx_tokens") ${compact_pct}%${NORMAL}${cache_part}"
api_secs=$((api_ms / 1000))
round_cost=$(awk "BEGIN {printf \"%.2f\", $cost - $round_start_cost}")
cost_fmt=$(printf '%s +$%s $%.2f' "$(fmt_duration "$api_secs")" "$round_cost" "$cost")
limit_parts=""
if [ -n "$limit_5h" ]; then
	limit_parts="$(fmt_limit "$limit_5h" "$limit_5h_reset")"
	[ -n "$limit_7d" ] && limit_parts="${limit_parts} · $(fmt_limit "$limit_7d" "$limit_7d_reset")"
	parts="${parts} | ${limit_parts}"
fi
parts="${parts} | ${cost_fmt}${RESET}"
printf '%b' "$parts"
