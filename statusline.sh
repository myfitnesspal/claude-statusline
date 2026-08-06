#!/usr/bin/env bash
# Claude Code Status Line
# [model] | [context] | [rate limits] | [cost]
#
# Context total colored by absolute token thresholds (retrieval quality):
#   green < 120K, yellow 120-250K, orange 250-400K, red >= 400K
# Message count colored by multi-turn degradation thresholds:
#   green < 10, yellow 10-17, orange 18-23, red >= 24
# Cache age shown when >= 3 minutes since last API call (yellow 3-5m, red > 5m)
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
	(.cost.total_api_duration_ms // 0)
')
session_id=${_f[0]}  model=${_f[1]}  cwd=${_f[2]}  project_dir=${_f[3]}
agent_name=${_f[4]}  worktree_name=${_f[5]}
limit_5h=${_f[6]}  limit_5h_reset=${_f[7]}  limit_7d=${_f[8]}  limit_7d_reset=${_f[9]}
cost=${_f[10]}  ctx_tokens=${_f[11]}  ctx_max=${_f[12]}  api_ms=${_f[13]}
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
ORANGE='\033[38;5;208m'
RED='\033[31m'
NORMAL='\033[38;5;245m'
RESET='\033[0m'

# Human-friendly token formatting (1234 -> 1.2k, 200000 -> 200k, 1000000 -> 1M)
fmt_tokens() {
	local n=$1
	if [ "$n" -ge 1000000 ]; then
		local major=$((n / 1000000)) minor=$(( (n % 1000000) / 100000 ))
		if [ "$minor" -eq 0 ]; then printf '%sM' "$major"
		else printf '%s.%sM' "$major" "$minor"; fi
	elif [ "$n" -ge 1000 ]; then
		local major=$((n / 1000)) minor=$(( (n % 1000) / 100 ))
		if [ "$minor" -eq 0 ] || [ "$major" -ge 100 ]; then printf '%sk' "$major"
		else printf '%s.%sk' "$major" "$minor"; fi
	else
		printf '%s' "$n"
	fi
}

# State format v2: version|round_start_cost|msg_count|last_ts
round_start_cost=$cost
msg_count=0
last_ts=0
if [ -f "$STATE_FILE" ]; then
	IFS='|' read -r _ver _rsc _mc _lt < "$STATE_FILE"
	if [ "$_ver" = "2" ]; then
		round_start_cost=$_rsc
		msg_count=${_mc:-0}
		last_ts=${_lt:-0}
	fi
fi

# If UserPromptSubmit hook signaled a new round, reset round metrics
if [ -f "$NEWROUND_FILE" ]; then
	round_start_cost=$cost
	msg_count=$((msg_count + 1))
	rm -f "$NEWROUND_FILE"
fi

# Cache age: seconds since last statusline render
now=$(date +%s)
cache_age=0
if [ "$last_ts" -gt 0 ]; then
	cache_age=$((now - last_ts))
fi

# Save state
echo "2|${round_start_cost}|${msg_count}|${now}" > "$STATE_FILE"

# Usage snapshot for programmatic reads (agent self-throttling). Authoritative rate-limit
# fields come straight from Claude Code's statusline input; persisted here each render so a
# Bash poll can read live 5h/7d usage % + reset times. Written to a stable, session-scoped path.
# Also APPENDED (tagged with session_id) to a persistent history so account-wide cost can be
# reconstructed across concurrent sessions = Sum of each session's latest cost -> a
# contamination-free budget fit (see fit-budget.py). cost_usd is PER-SESSION; the % are account-wide.
usage_json=$(printf '{"five_hour_pct":%s,"five_hour_reset":"%s","seven_day_pct":%s,"seven_day_reset":"%s","cost_usd":%s,"ctx_tokens":%s,"ts":%s,"session_id":"%s"}' \
	"${limit_5h:-null}" "${limit_5h_reset}" "${limit_7d:-null}" "${limit_7d_reset}" "${cost:-0}" "${ctx_tokens:-0}" "${now}" "${session_id}")
printf '%s\n' "$usage_json" > "/tmp/claude-usage-${session_id}.json" 2>/dev/null
printf '%s\n' "$usage_json" >> "$HOME/.claude-statusline/usage-history.jsonl" 2>/dev/null

# Color for total context: absolute token thresholds (retrieval quality)
usable_cap=$((compact_threshold < 400000 ? compact_threshold : 400000))
compact_pct=$((ctx_tokens * 100 / usable_cap))
if [ "$ctx_tokens" -ge 400000 ]; then
	ctx_color="$RED"
elif [ "$ctx_tokens" -ge 250000 ]; then
	ctx_color="$ORANGE"
elif [ "$ctx_tokens" -ge 120000 ]; then
	ctx_color="$YELLOW"
else
	ctx_color="$GREEN"
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
	local color="$NORMAL"
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

# Auth/plan mode letter, shown after the model. K = ANTHROPIC_API_KEY in env
# (pay-per-token API billing). Otherwise the letter reflects the OAuth account's
# organizationType: M = Max, P = Pro, T = Team, E = Enterprise. A = any other
# non-empty org type (unknown/fallback). Hidden when logged out with no key.
# The env var wins because Claude Code prefers an approved ANTHROPIC_API_KEY
# over the stored OAuth login.
# CLAUDE_JSON_PATH overrides the credential file location (tests).
auth_letter=""
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
	auth_letter="K"
else
	claude_json="${CLAUDE_JSON_PATH:-$HOME/.claude.json}"
	if [ -f "$claude_json" ]; then
		org_type=$(jq -r 'if .oauthAccount then (.oauthAccount.organizationType // "unknown") else "" end' "$claude_json" 2>/dev/null)
		case "$org_type" in
			claude_max) auth_letter="M" ;;
			claude_pro) auth_letter="P" ;;
			claude_team) auth_letter="T" ;;
			claude_enterprise) auth_letter="E" ;;
			"") auth_letter="" ;;
			*) auth_letter="A" ;;
		esac
	fi
fi

# 7d throttle meter, appended to the 7d limit — a bounded heat bar. EMPTY = your
# current average burn still reaches reset (sustainable, all good); it FILLS as you'd
# wall earlier; FULL = walling now. Ease off (or get 5h-blocked) and it drains as the
# clock catches up to your usage. Non-linear by design (heat = 100 - runway, and
# runway = time-to-wall / time-left is hyperbolic): near-empty while you have days of
# runway, climbing fast only as the wall approaches. Grey when cool, yellow warming,
# red when >half full or >=90% used. Hidden the window's first ~8h.
fmt_pace() {
	local pct=$1
	local reset_ts=$2
	[ -z "$pct" ] && return
	[ -z "$reset_ts" ] && return
	[ "$pct" -le 0 ] && return
	local now window remaining elapsed wall runway heat cells filled i bar color
	now=$(date +%s)
	window=604800
	remaining=$((reset_ts - now))
	[ "$remaining" -le 0 ] && return
	[ "$remaining" -gt "$window" ] && remaining=$window
	elapsed=$((window - remaining))
	[ "$elapsed" -lt $((window / 20)) ] && return   # <~8.4h in: not enough to extrapolate
	wall=$(( (100 - pct) * elapsed / pct ))          # secs until used%=100 at avg rate
	runway=$(( 100 * wall / remaining ))
	[ "$runway" -gt 100 ] && runway=100
	heat=$((100 - runway))
	cells=5
	filled=$(( (heat * cells + 50) / 100 ))
	[ "$filled" -gt "$cells" ] && filled=$cells
	bar=""
	i=0
	while [ "$i" -lt "$cells" ]; do
		if [ "$i" -lt "$filled" ]; then bar="${bar}█"; else bar="${bar}░"; fi
		i=$((i + 1))
	done
	color="$NORMAL"
	if [ "$pct" -ge 90 ] || [ "$heat" -gt 50 ]; then
		color="$RED"
	elif [ "$heat" -gt 0 ]; then
		color="$YELLOW"
	fi
	printf '%b %s%b' "$color" "$bar" "$NORMAL"
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

# Message count color (multi-turn degradation)
if [ "$msg_count" -ge 24 ]; then
	msg_color="$RED"
elif [ "$msg_count" -ge 18 ]; then
	msg_color="$ORANGE"
elif [ "$msg_count" -ge 10 ]; then
	msg_color="$YELLOW"
else
	msg_color="$GREEN"
fi
msg_part=""
if [ "$msg_count" -gt 0 ]; then
	msg_part=" · ${msg_color}${msg_count}msg${NORMAL}"
fi

# Cache age indicator (hidden when warm < 3 minutes)
cache_part=""
if [ "$cache_age" -ge 300 ]; then
	cache_part=" · ${RED}$(fmt_duration "$cache_age")${NORMAL}"
elif [ "$cache_age" -ge 180 ]; then
	cache_part=" · ${YELLOW}$(fmt_duration "$cache_age")${NORMAL}"
fi

parts="${NORMAL}${short_model}"
[ -n "$auth_letter" ] && parts="${parts} ${auth_letter}"
[ -n "$location" ] && parts="${parts} ${location}"
[ -n "$sa_status" ] && parts="${parts} ${sa_status}${NORMAL}"
parts="${parts} |"
parts="${parts} ${ctx_color}$(fmt_tokens "$ctx_tokens") ${compact_pct}%${NORMAL}${msg_part}${cache_part}"
api_secs=$((api_ms / 1000))
round_cost=$(awk "BEGIN {printf \"%.2f\", $cost - $round_start_cost}")
cost_fmt=$(printf '%s +$%s $%.2f' "$(fmt_duration "$api_secs")" "$round_cost" "$cost")
limit_parts=""
if [ -n "$limit_5h" ]; then
	limit_parts="$(fmt_limit "$limit_5h" "$limit_5h_reset")"
	[ -n "$limit_7d" ] && limit_parts="${limit_parts} · $(fmt_limit "$limit_7d" "$limit_7d_reset")$(fmt_pace "$limit_7d" "$limit_7d_reset")"
	parts="${parts} | ${limit_parts}"
fi
parts="${parts} | ${cost_fmt}${RESET}"
printf '%b' "$parts"
